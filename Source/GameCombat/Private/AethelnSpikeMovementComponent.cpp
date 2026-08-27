#include "AethelnSpikeMovementComponent.h"

#include "AethelnObservability.h"
#include "AethelnObservabilitySubsystem.h"
#include "AethelnSpikeCharacter.h"
#include "Engine/GameInstance.h"
#include "Engine/World.h"
#include "GameFramework/Character.h"

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
	return true;
}
#endif
