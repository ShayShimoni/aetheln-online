#include "AethelnSpikeMovementComponent.h"

#include "AethelnObservability.h"
#include "AethelnObservabilitySubsystem.h"
#include "AethelnSpikeCharacter.h"
#include "Engine/Engine.h"
#include "Engine/GameInstance.h"
#include "Engine/World.h"
#include "GameFramework/Character.h"
#include "Interfaces/MovementBaseInterface.h"

uint64 UAethelnSpikeMovementComponent::MakeMovementSequence(float TimeStamp)
{
	if (!FMath::IsFinite(TimeStamp) || TimeStamp <= 0.0f)
	{
		return 1;
	}
	return FMath::Max<uint64>(1, static_cast<uint64>(FMath::RoundToInt64(static_cast<double>(TimeStamp) * 1000000.0)));
}

bool UAethelnSpikeMovementComponent::ShouldEmitServerMovementRejection(bool bExceedsAllowablePositionError)
{
	return bExceedsAllowablePositionError;
}

void UAethelnSpikeMovementComponent::MoveAutonomous(
	float ClientTimeStamp,
	float DeltaTime,
	uint8 CompressedFlags,
	const FVector& NewAccel)
{
	Super::MoveAutonomous(ClientTimeStamp, DeltaTime, CompressedFlags, NewAccel);
	if (CharacterOwner != nullptr && CharacterOwner->HasAuthority() && !NewAccel.IsNearlyZero())
	{
		EmitMovementObservation(false, false, ClientTimeStamp);
	}
}

bool UAethelnSpikeMovementComponent::ServerExceedsAllowablePositionError(
	float ClientTimeStamp,
	float DeltaTime,
	const FVector& Accel,
	const FVector& ClientWorldLocation,
	const FVector& RelativeClientLocation,
	FMovementBaseInterfaceData* ClientMovementBaseInterfaceData,
	FName ClientBaseBoneName,
	uint8 ClientMovementMode)
{
	const bool bExceedsAllowablePositionError = Super::ServerExceedsAllowablePositionError(
		ClientTimeStamp,
		DeltaTime,
		Accel,
		ClientWorldLocation,
		RelativeClientLocation,
		ClientMovementBaseInterfaceData,
		ClientBaseBoneName,
		ClientMovementMode);
	if (ShouldEmitServerMovementRejection(bExceedsAllowablePositionError))
	{
		EmitMovementObservation(false, true, ClientTimeStamp);
	}
	return bExceedsAllowablePositionError;
}

void UAethelnSpikeMovementComponent::OnClientCorrectionReceived(
	FNetworkPredictionData_Client_Character& ClientData,
	float TimeStamp,
	FVector NewLocation,
	FVector NewVelocity,
	FMovementBaseInterfaceData* NewMovementBaseInterfaceData,
	FName NewBaseBoneName,
	bool bHasBase,
	bool bBaseRelativePosition,
	uint8 ServerMovementMode,
	FVector ServerGravityDirection)
{
	Super::OnClientCorrectionReceived(
		ClientData,
		TimeStamp,
		NewLocation,
		NewVelocity,
		NewMovementBaseInterfaceData,
		NewBaseBoneName,
		bHasBase,
		bBaseRelativePosition,
		ServerMovementMode,
		ServerGravityDirection);
	EmitMovementObservation(true, false, TimeStamp);
}

void UAethelnSpikeMovementComponent::EmitMovementObservation(
	bool bCorrection,
	bool bServerRejected,
	float TimeStamp) const
{
	const UWorld* World = GetWorld();
	UGameInstance* GameInstance = World != nullptr ? World->GetGameInstance() : nullptr;
	UAethelnObservabilitySubsystem* Subsystem = GameInstance != nullptr
		? GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>()
		: nullptr;
	if (Subsystem == nullptr)
	{
		return;
	}

	FAethelnObservabilityEvent Event;
	Event.Category = bServerRejected
		? EAethelnObservabilityCategory::Rejection
		: (bCorrection
			? EAethelnObservabilityCategory::Correction
			: EAethelnObservabilityCategory::Movement);
	Event.SubjectCategory = EAethelnObservabilityCategory::Movement;
	Event.SafeReason = bServerRejected || bCorrection
		? EAethelnSafeReason::Corrected
		: EAethelnSafeReason::Accepted;
	Event.DiagnosticCode = bServerRejected
		? EAethelnDiagnosticCode::ValidationFailed
		: EAethelnDiagnosticCode::None;
	FAethelnObservabilityEventContext Context;
	if (const AAethelnSpikeCharacter* SpikeCharacter = Cast<AAethelnSpikeCharacter>(CharacterOwner))
	{
		Context.ConnectionPseudonym = SpikeCharacter->GetObservabilityConnectionPseudonym();
	}
	Context.Sequence = MakeMovementSequence(TimeStamp);
	Subsystem->EmitEvent(Event, Context);

	FAethelnMetricSample Metric;
	Metric.Metric = bServerRejected
		? EAethelnMetricKind::RejectionCount
		: (bCorrection ? EAethelnMetricKind::CorrectionCount : EAethelnMetricKind::EventCount);
	Metric.Category = EAethelnObservabilityCategory::Movement;
	Metric.Reason = Event.SafeReason;
	Metric.Value = 1;
	Subsystem->EmitMetric(Metric);
}

#if WITH_DEV_AUTOMATION_TESTS
#include "Misc/AutomationTest.h"

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnSpikeMovementObservabilityContractTest,
	"Aetheln.Observability.Movement.AuthorityAndCorrectionSeams",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnSpikeMovementObservabilityContractTest::RunTest(const FString& Parameters)
{
	TestEqual(TEXT("Zero movement timestamp retains a valid sequence"), UAethelnSpikeMovementComponent::MakeMovementSequence(0.0f), static_cast<uint64>(1));
	TestEqual(TEXT("Movement timestamp maps to a stable microsecond sequence"), UAethelnSpikeMovementComponent::MakeMovementSequence(1.25f), static_cast<uint64>(1250000));
	TestEqual(TEXT("Repeated movement timestamp remains correlatable"), UAethelnSpikeMovementComponent::MakeMovementSequence(1.25f), UAethelnSpikeMovementComponent::MakeMovementSequence(1.25f));
	TestTrue(TEXT("Authoritative position error maps to a movement rejection observation"), UAethelnSpikeMovementComponent::ShouldEmitServerMovementRejection(true));
	TestFalse(TEXT("Accepted authoritative movement does not emit a rejection"), UAethelnSpikeMovementComponent::ShouldEmitServerMovementRejection(false));

	UWorld* World = UWorld::CreateWorld(EWorldType::Game, false);
	TestNotNull(TEXT("Movement observability runtime world was created"), World);
	TestNotNull(TEXT("Engine exists for movement observability runtime world"), GEngine);
	if (World == nullptr || GEngine == nullptr)
	{
		if (World != nullptr)
		{
			World->DestroyWorld(false);
		}
		return false;
	}

	FWorldContext& WorldContext = GEngine->CreateNewWorldContext(EWorldType::Game);
	UGameInstance* GameInstance = NewObject<UGameInstance>(GEngine);
	TestNotNull(TEXT("Movement observability game instance was created"), GameInstance);
	if (GameInstance == nullptr)
	{
		World->DestroyWorld(false);
		GEngine->DestroyWorldContext(World);
		return false;
	}
	WorldContext.OwningGameInstance = GameInstance;
	World->SetGameInstance(GameInstance);
	WorldContext.SetCurrentWorld(World);
	GameInstance->Init();
	World->InitializeActorsForPlay(FURL());
	World->BeginPlay();

	auto DestroyTestWorld = [World, GameInstance]()
	{
		GameInstance->Shutdown();
		World->DestroyWorld(false);
		GEngine->DestroyWorldContext(World);
	};

	UAethelnObservabilitySubsystem* Subsystem = GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>();
	TSharedPtr<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe> Sink =
		MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(16);
	TestNotNull(TEXT("Movement runtime owns the observability subsystem"), Subsystem);
	if (Subsystem == nullptr
		|| !Subsystem->SetRuntimeContext(
			EAethelnFlowKind::PrototypeAuthority,
			TEXT("run-movement-runtime"),
			TEXT("instance-movement-runtime"),
			TEXT("connection-movement-runtime"))
		|| !Subsystem->SetTestSink(Sink))
	{
		DestroyTestWorld();
		return false;
	}

	FActorSpawnParameters SpawnParameters;
	SpawnParameters.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
	AAethelnSpikeCharacter* Character = World->SpawnActor<AAethelnSpikeCharacter>(
		AAethelnSpikeCharacter::StaticClass(),
		FVector::ZeroVector,
		FRotator::ZeroRotator,
		SpawnParameters);
	UAethelnSpikeMovementComponent* Movement = Character != nullptr
		? Cast<UAethelnSpikeMovementComponent>(Character->GetCharacterMovement())
		: nullptr;
	TestNotNull(TEXT("Runtime character uses the spike movement component"), Movement);
	if (Movement == nullptr)
	{
		DestroyTestWorld();
		return false;
	}
	Character->SetObservabilityConnectionPseudonym(TEXT("connection-movement-runtime"));

	Movement->MoveAutonomous(1.0f, 0.016f, 0, FVector(100.0f, 0.0f, 0.0f));
	FMovementBaseInterfaceData MovementBase;
	const FVector RejectedClientLocation = Character->GetActorLocation() + FVector(100000.0f, 0.0f, 0.0f);
	const bool bServerRejected = Movement->ServerExceedsAllowablePositionError(
		2.0f,
		0.016f,
		FVector::ZeroVector,
		RejectedClientLocation,
		RejectedClientLocation,
		&MovementBase,
		NAME_None,
		Movement->PackNetworkMovementMode());
	FNetworkPredictionData_Client_Character ClientData(*Movement);
	Movement->OnClientCorrectionReceived(
		ClientData,
		3.0f,
		Character->GetActorLocation(),
		Movement->Velocity,
		&MovementBase,
		NAME_None,
		false,
		false,
		Movement->PackNetworkMovementMode(),
		FVector(0.0f, 0.0f, -1.0f));

	TestTrue(TEXT("Actual server position-error path rejects an impossible client location"), bServerRejected);
	TestTrue(TEXT("Actual movement and correction emissions drain"), Subsystem->WaitForIdleForTests());
	const TArray<FAethelnObservabilityEvent> Events = Sink->GetEvents();
	TestEqual(TEXT("Three actual movement seams emit three events"), Events.Num(), 3);
	int32 AcceptedMovementCount = 0;
	int32 ServerRejectionCount = 0;
	int32 ClientCorrectionCount = 0;
	for (const FAethelnObservabilityEvent& Event : Events)
	{
		AcceptedMovementCount += Event.Category == EAethelnObservabilityCategory::Movement ? 1 : 0;
		ServerRejectionCount += Event.Category == EAethelnObservabilityCategory::Rejection
			&& Event.SubjectCategory == EAethelnObservabilityCategory::Movement ? 1 : 0;
		ClientCorrectionCount += Event.Category == EAethelnObservabilityCategory::Correction
			&& Event.SubjectCategory == EAethelnObservabilityCategory::Movement ? 1 : 0;
	}
	TestEqual(TEXT("MoveAutonomous emits one accepted movement event"), AcceptedMovementCount, 1);
	TestEqual(TEXT("Server error emits one movement rejection envelope"), ServerRejectionCount, 1);
	TestEqual(TEXT("Client correction callback emits one movement correction"), ClientCorrectionCount, 1);
	const TArray<FAethelnMetricSample> Metrics = Sink->GetMetrics();
	TestEqual(TEXT("Three actual movement seams emit three metrics"), Metrics.Num(), 3);
	for (const FAethelnMetricSample& Metric : Metrics)
	{
		TestEqual(TEXT("Every movement seam increments its metric by one"), Metric.Value, static_cast<int64>(1));
	}

	Subsystem->ResetSink();
	Subsystem->ResetRuntimeContext();
	DestroyTestWorld();
	return true;
}
#endif
