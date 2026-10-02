#include "AethelnCharacterMovementComponent.h"

#include "GameFramework/Character.h"
#if WITH_DEV_AUTOMATION_TESTS
#include "AethelnPlayerCharacter.h"
#include "Components/BoxComponent.h"
#include "Engine/CollisionProfile.h"
#include "Engine/Engine.h"
#include "Engine/GameInstance.h"
#include "Engine/World.h"
#include "Interfaces/MovementBaseInterface.h"
#include "Misc/AutomationTest.h"
#endif

namespace
{
	// Numerical tolerance (about 0.6 degrees) that keeps pure strafes from reading as
	// backpedal after network yaw and acceleration quantization. Not a gameplay tuning value.
	constexpr float BackpedalDotTolerance = 0.01f;

	class FSavedMove_Aetheln : public FSavedMove_Character
	{
	public:
		typedef FSavedMove_Character Super;

		virtual void Clear() override
		{
			Super::Clear();
			bSavedWantsToSprint = false;
		}

		virtual void SetMoveFor(
			ACharacter* Character,
			float InDeltaTime,
			FVector const& NewAccel,
			FNetworkPredictionData_Client_Character& ClientData) override
		{
			Super::SetMoveFor(Character, InDeltaTime, NewAccel, ClientData);
			const UAethelnCharacterMovementComponent* Movement =
				Character->GetCharacterMovement<UAethelnCharacterMovementComponent>();
			bSavedWantsToSprint = Movement != nullptr && Movement->bWantsToSprint;
		}

		// The base CanCombineWith compares GetCompressedFlags, and replay applies these
		// flags through MoveAutonomous, so neither needs an override here.
		virtual uint8 GetCompressedFlags() const override
		{
			uint8 Flags = Super::GetCompressedFlags();
			if (bSavedWantsToSprint)
			{
				Flags |= FLAG_Custom_0;
			}
			return Flags;
		}

	private:
		bool bSavedWantsToSprint = false;
	};

	class FNetworkPredictionData_Client_Aetheln : public FNetworkPredictionData_Client_Character
	{
	public:
		explicit FNetworkPredictionData_Client_Aetheln(const UCharacterMovementComponent& ClientMovement)
			: FNetworkPredictionData_Client_Character(ClientMovement)
		{
		}

		virtual FSavedMovePtr AllocateNewMove() override
		{
			return FSavedMovePtr(new FSavedMove_Aetheln());
		}
	};
}

float UAethelnCharacterMovementComponent::SelectGroundMaxSpeed(
	bool bSprintAllowed,
	bool bBackpedaling,
	float WalkSpeed,
	float InSprintSpeed)
{
	return bSprintAllowed && !bBackpedaling
		? InSprintSpeed
		: WalkSpeed;
}

float UAethelnCharacterMovementComponent::GetMaxSpeed() const
{
	const float BaseMaxSpeed = Super::GetMaxSpeed();
	if (MovementMode != MOVE_Walking || IsCrouching())
	{
		return BaseMaxSpeed;
	}
	return SelectGroundMaxSpeed(
		bWantsToSprint && !Acceleration.IsNearlyZero(),
		IsBackpedaling(),
		BaseMaxSpeed,
		SprintSpeed);
}

bool UAethelnCharacterMovementComponent::IsBackpedaling() const
{
	// The server has already applied this move's control rotation, so prediction and
	// authority derive backpedal from the same inputs. It is never a client claim.
	const float ControlYaw = CharacterOwner != nullptr
		? CharacterOwner->GetControlRotation().Yaw
		: 0.0f;
	const FVector ControlForward = FRotator(0.0f, ControlYaw, 0.0f).Vector();
	return (Acceleration.GetSafeNormal2D() | ControlForward) < -BackpedalDotTolerance;
}

FNetworkPredictionData_Client* UAethelnCharacterMovementComponent::GetPredictionData_Client() const
{
	if (ClientPredictionData == nullptr)
	{
		UAethelnCharacterMovementComponent* MutableThis =
			const_cast<UAethelnCharacterMovementComponent*>(this);
		MutableThis->ClientPredictionData = new FNetworkPredictionData_Client_Aetheln(*this);
	}
	return ClientPredictionData;
}

void UAethelnCharacterMovementComponent::UpdateFromCompressedFlags(uint8 Flags)
{
	Super::UpdateFromCompressedFlags(Flags);
	bWantsToSprint = (Flags & FSavedMove_Character::FLAG_Custom_0) != 0;
}

bool UAethelnCharacterMovementComponent::ClientUpdatePositionAfterServerUpdate()
{
	// Replay applies each saved move's flags; restore the live input intent afterwards,
	// as the engine does for crouch, because sprint input is edge triggered.
	const bool bRealWantsToSprint = bWantsToSprint;
	const bool bReplayed = Super::ClientUpdatePositionAfterServerUpdate();
	bWantsToSprint = bRealWantsToSprint;
	return bReplayed;
}

#if WITH_DEV_AUTOMATION_TESTS
namespace AethelnMovementNetTests
{
	constexpr float MoveDeltaTime = 1.0f / 60.0f;
	constexpr float SpeedTolerance = 0.5f;

	/** Engine-only copy of the spike test world bootstrap (GameCore cannot use GameCombat). */
	struct FTestWorld
	{
		UWorld* World = nullptr;
		UGameInstance* GameInstance = nullptr;

		FTestWorld()
		{
			World = UWorld::CreateWorld(EWorldType::Game, false);
			if (World == nullptr || GEngine == nullptr)
			{
				return;
			}
			FWorldContext& WorldContext = GEngine->CreateNewWorldContext(EWorldType::Game);
			GameInstance = NewObject<UGameInstance>(GEngine);
			WorldContext.OwningGameInstance = GameInstance;
			World->SetGameInstance(GameInstance);
			WorldContext.SetCurrentWorld(World);
			GameInstance->Init();
			World->InitializeActorsForPlay(FURL());
			World->BeginPlay();
		}

		~FTestWorld()
		{
			if (GameInstance != nullptr)
			{
				GameInstance->Shutdown();
			}
			if (World != nullptr)
			{
				World->DestroyWorld(false);
				if (GEngine != nullptr && GameInstance != nullptr)
				{
					GEngine->DestroyWorldContext(World);
				}
			}
		}

		/** Spawns a static floor whose top is Z=0 and a POC character standing on it. No controller, so control yaw is zero and forward is +X. */
		AAethelnPlayerCharacter* SpawnGroundedCharacter(const FVector& Location) const
		{
			if (GameInstance == nullptr)
			{
				return nullptr;
			}
			AActor* Floor = World->SpawnActor<AActor>();
			UBoxComponent* Box = NewObject<UBoxComponent>(Floor);
			Box->SetBoxExtent(FVector(100000.0f, 100000.0f, 50.0f));
			Box->SetRelativeLocation(FVector(0.0f, 0.0f, -50.0f));
			Box->SetMobility(EComponentMobility::Static);
			Box->SetCollisionProfileName(UCollisionProfile::BlockAll_ProfileName);
			Floor->SetRootComponent(Box);
			Box->RegisterComponent();

			FActorSpawnParameters SpawnParameters;
			SpawnParameters.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
			AAethelnPlayerCharacter* Character = World->SpawnActor<AAethelnPlayerCharacter>(
				AAethelnPlayerCharacter::StaticClass(),
				Location,
				FRotator::ZeroRotator,
				SpawnParameters);
			if (Character != nullptr)
			{
				// Without a controller PhysWalking zeroes velocity unless this is set.
				Character->GetCharacterMovement()->bRunPhysicsWithNoController = true;
				Character->GetCharacterMovement()->SetMovementMode(MOVE_Walking);
			}
			return Character;
		}
	};

	UAethelnCharacterMovementComponent* GetMovement(const AAethelnPlayerCharacter* Character)
	{
		return Character != nullptr
			? Cast<UAethelnCharacterMovementComponent>(Character->GetCharacterMovement())
			: nullptr;
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnMovementNetSavedMoveSprintFlagTest,
	"Aetheln.Movement.Net.SavedMoveSprintFlag",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementNetSavedMoveSprintFlagTest::RunTest(const FString& Parameters)
{
	using namespace AethelnMovementNetTests;
	const FTestWorld TestWorld;
	AAethelnPlayerCharacter* ClientCharacter =
		TestWorld.SpawnGroundedCharacter(FVector(0.0f, 0.0f, 100.0f));
	AAethelnPlayerCharacter* ServerCharacter =
		TestWorld.SpawnGroundedCharacter(FVector(0.0f, 500.0f, 100.0f));
	UAethelnCharacterMovementComponent* ClientMovement = GetMovement(ClientCharacter);
	UAethelnCharacterMovementComponent* ServerMovement = GetMovement(ServerCharacter);
	TestNotNull(TEXT("POC character uses the project movement component"), ClientMovement);
	TestNotNull(TEXT("Second POC character uses the project movement component"), ServerMovement);
	if (ClientMovement == nullptr || ServerMovement == nullptr)
	{
		return false;
	}

	FNetworkPredictionData_Client_Character* ClientData =
		static_cast<FNetworkPredictionData_Client_Character*>(ClientMovement->GetPredictionData_Client());
	const FVector Accel(ClientMovement->GetMaxAcceleration(), 0.0f, 0.0f);
	constexpr int32 SprintFlag = FSavedMove_Character::FLAG_Custom_0;

	ClientMovement->bWantsToSprint = true;
	FSavedMovePtr SprintMove = ClientData->AllocateNewMove();
	SprintMove->SetMoveFor(ClientCharacter, MoveDeltaTime, Accel, *ClientData);
	SprintMove->PostUpdate(ClientCharacter, FSavedMove_Character::PostUpdate_Record);
	FSavedMovePtr SecondSprintMove = ClientData->AllocateNewMove();
	SecondSprintMove->SetMoveFor(ClientCharacter, MoveDeltaTime, Accel, *ClientData);
	ClientMovement->bWantsToSprint = false;
	FSavedMovePtr WalkMove = ClientData->AllocateNewMove();
	WalkMove->SetMoveFor(ClientCharacter, MoveDeltaTime, Accel, *ClientData);

	const uint8 SprintFlags = SprintMove->GetCompressedFlags();
	const uint8 WalkFlags = WalkMove->GetCompressedFlags();
	TestEqual(TEXT("Sprint intent packs into custom flag 0"), SprintFlags & SprintFlag, SprintFlag);
	TestEqual(TEXT("Walk intent leaves custom flag 0 clear"), WalkFlags & SprintFlag, 0);
	TestFalse(
		TEXT("Moves with different sprint intent never combine"),
		SprintMove->CanCombineWith(WalkMove, ClientCharacter, 1.0f));
	TestTrue(
		TEXT("Moves with the same sprint intent may still combine"),
		SprintMove->CanCombineWith(SecondSprintMove, ClientCharacter, 1.0f));

	ServerMovement->UpdateFromCompressedFlags(SprintFlags);
	TestTrue(TEXT("Server restores sprint intent from the received flags"), ServerMovement->bWantsToSprint);
	ServerMovement->UpdateFromCompressedFlags(WalkFlags);
	TestFalse(TEXT("Server clears sprint intent when the flag is absent"), ServerMovement->bWantsToSprint);

	SprintMove->Clear();
	TestEqual(TEXT("Cleared pooled move forgets sprint intent"), SprintMove->GetCompressedFlags() & SprintFlag, 0);

	// The player released sprint after this move was saved; replay must not leave it latched.
	ClientMovement->bWantsToSprint = false;
	ClientData->SavedMoves.Add(SecondSprintMove);
	ClientData->bUpdatePosition = true;
	TestTrue(TEXT("Correction replays the unacknowledged sprint move"), ClientMovement->ClientUpdatePositionAfterServerUpdate());
	TestFalse(TEXT("Replay restores the live sprint intent afterwards"), ClientMovement->bWantsToSprint);
	ClientData->SavedMoves.Reset();
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnMovementNetServerSpeedClampTest,
	"Aetheln.Movement.Net.ServerSpeedClamp",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementNetServerSpeedClampTest::RunTest(const FString& Parameters)
{
	using namespace AethelnMovementNetTests;
	const FTestWorld TestWorld;
	AAethelnPlayerCharacter* Character =
		TestWorld.SpawnGroundedCharacter(FVector(0.0f, 0.0f, 100.0f));
	UAethelnCharacterMovementComponent* Movement = GetMovement(Character);
	TestNotNull(TEXT("POC character uses the project movement component"), Movement);
	if (Movement == nullptr)
	{
		return false;
	}

	const float WalkSpeed = Movement->MaxWalkSpeed;
	const float SprintSpeed = Movement->SprintSpeed;
	// An oversized client acceleration is clamped by the server like any other input.
	const FVector OversizedForwardAccel(1000000.0f, 0.0f, 0.0f);
	float TimeStamp = 0.0f;
	// MoveAutonomous is protected; this lambda shares the friend test's access.
	auto RunAuthorityMoves = [Movement, &TimeStamp](int32 MoveCount, uint8 CompressedFlags, const FVector& Accel)
	{
		float PeakSpeed = 0.0f;
		for (int32 Index = 0; Index < MoveCount; ++Index)
		{
			TimeStamp += MoveDeltaTime;
			Movement->MoveAutonomous(TimeStamp, MoveDeltaTime, CompressedFlags, Accel);
			PeakSpeed = FMath::Max(PeakSpeed, static_cast<float>(Movement->Velocity.Size2D()));
		}
		return PeakSpeed;
	};

	const float PeakSprintSpeed = RunAuthorityMoves(
		1, FSavedMove_Character::FLAG_Custom_0, OversizedForwardAccel);
	TestTrue(TEXT("Authority simulation stays grounded on the test floor"), Movement->IsMovingOnGround());
	const float SustainedPeakSprintSpeed = FMath::Max(
		PeakSprintSpeed,
		RunAuthorityMoves(119, FSavedMove_Character::FLAG_Custom_0, OversizedForwardAccel));
	TestTrue(TEXT("Sprinting authority stays grounded"), Movement->IsMovingOnGround());
	TestNearlyEqual(
		TEXT("Server sprint converges to the provisional sprint speed"),
		static_cast<float>(Movement->Velocity.Size2D()), SprintSpeed, SpeedTolerance);
	TestTrue(
		TEXT("Server sprint never exceeds the provisional sprint speed"),
		SustainedPeakSprintSpeed <= SprintSpeed + SpeedTolerance);

	Movement->StopMovementImmediately();
	const float PeakWalkSpeed = RunAuthorityMoves(120, 0, OversizedForwardAccel);
	TestNearlyEqual(
		TEXT("Server walk converges to walk speed without the sprint flag"),
		static_cast<float>(Movement->Velocity.Size2D()), WalkSpeed, SpeedTolerance);
	TestTrue(
		TEXT("Server walk never exceeds walk speed without the sprint flag"),
		PeakWalkSpeed <= WalkSpeed + SpeedTolerance);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnMovementNetInvalidSprintRejectedTest,
	"Aetheln.Movement.Net.InvalidSprintRejected",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementNetInvalidSprintRejectedTest::RunTest(const FString& Parameters)
{
	using namespace AethelnMovementNetTests;
	const FTestWorld TestWorld;
	AAethelnPlayerCharacter* Character =
		TestWorld.SpawnGroundedCharacter(FVector(0.0f, 0.0f, 100.0f));
	UAethelnCharacterMovementComponent* Movement = GetMovement(Character);
	TestNotNull(TEXT("POC character uses the project movement component"), Movement);
	if (Movement == nullptr)
	{
		return false;
	}

	const float WalkSpeed = Movement->MaxWalkSpeed;
	const float SprintSpeed = Movement->SprintSpeed;
	const float MaxAccel = Movement->GetMaxAcceleration();
	constexpr uint8 SprintFlag = FSavedMove_Character::FLAG_Custom_0;
	float TimeStamp = 0.0f;
	// MoveAutonomous is protected; this lambda shares the friend test's access.
	auto RunAuthorityMoves = [Movement, &TimeStamp](int32 MoveCount, uint8 CompressedFlags, const FVector& Accel)
	{
		float PeakSpeed = 0.0f;
		for (int32 Index = 0; Index < MoveCount; ++Index)
		{
			TimeStamp += MoveDeltaTime;
			Movement->MoveAutonomous(TimeStamp, MoveDeltaTime, CompressedFlags, Accel);
			PeakSpeed = FMath::Max(PeakSpeed, static_cast<float>(Movement->Velocity.Size2D()));
		}
		return PeakSpeed;
	};

	// No controller: control yaw is zero, so -X is backward and +Y is lateral.
	const float PeakBackwardSpeed =
		RunAuthorityMoves(60, SprintFlag, FVector(-MaxAccel, 0.0f, 0.0f));
	TestTrue(TEXT("Server received the backward sprint request"), Movement->bWantsToSprint);
	TestEqual(TEXT("Backward sprint request is simulated at walk speed"), Movement->GetMaxSpeed(), WalkSpeed);
	TestTrue(TEXT("Backward sprint request never exceeds walk speed"), PeakBackwardSpeed <= WalkSpeed + SpeedTolerance);

	Movement->StopMovementImmediately();
	RunAuthorityMoves(1, SprintFlag, FVector(0.0f, MaxAccel, 0.0f));
	TestEqual(TEXT("Lateral sprint remains allowed"), Movement->GetMaxSpeed(), SprintSpeed);

	Movement->Acceleration = FVector::ZeroVector;
	TestEqual(TEXT("Sprint request without acceleration grants no sprint speed"), Movement->GetMaxSpeed(), WalkSpeed);

	Movement->SetMovementMode(MOVE_Falling);
	Movement->Acceleration = FVector(MaxAccel, 0.0f, 0.0f);
	TestEqual(TEXT("Sprint request while falling adds no speed"), Movement->GetMaxSpeed(), Movement->MaxWalkSpeed);

	Movement->SetMovementMode(MOVE_Walking);
	Movement->StopMovementImmediately();
	RunAuthorityMoves(60, 0, FVector(MaxAccel, 0.0f, 0.0f));
	TestTrue(TEXT("Walking authority stays grounded"), Movement->IsMovingOnGround());
	const FVector ServerLocation = Character->GetActorLocation();
	// A client that predicted sprint without sending the flag runs one move ahead by the speed difference.
	const FVector SprintPredictedLocation =
		ServerLocation + FVector((SprintSpeed - WalkSpeed) * MoveDeltaTime, 0.0f, 0.0f);
	FMovementBaseInterfaceData MovementBase;
	TestFalse(
		TEXT("Matching client location is accepted"),
		Movement->ServerExceedsAllowablePositionError(
			TimeStamp, MoveDeltaTime, FVector::ZeroVector, ServerLocation, ServerLocation,
			&MovementBase, NAME_None, Movement->PackNetworkMovementMode()));
	TestTrue(
		TEXT("Client location implying unflagged sprint distance is corrected"),
		Movement->ServerExceedsAllowablePositionError(
			TimeStamp, MoveDeltaTime, FVector::ZeroVector, SprintPredictedLocation, SprintPredictedLocation,
			&MovementBase, NAME_None, Movement->PackNetworkMovementMode()));
	return true;
}
#endif
