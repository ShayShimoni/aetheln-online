#include "AethelnCharacterMovementComponent.h"

#include "GameFramework/Character.h"
#if WITH_DEV_AUTOMATION_TESTS
#include "AethelnPlayerCharacter.h"
#include "Components/BoxComponent.h"
#include "Engine/CollisionProfile.h"
#include "Engine/Engine.h"
#include "Engine/GameInstance.h"
#include "Engine/World.h"
#include "GameFramework/PlayerController.h"
#include "Interfaces/MovementBaseInterface.h"
#include "Misc/AutomationTest.h"
#endif

namespace
{
	// Deliberately loose numeric epsilon on the dot of move direction and control forward (about
	// 0.6 degrees, far above network yaw and acceleration quantization) so pure strafes never read
	// as backpedal or forward. Not a tuning value.
	constexpr float DirectionDotTolerance = 0.01f;

	class FSavedMove_Aetheln : public FSavedMove_Character
	{
	public:
		typedef FSavedMove_Character Super;

		virtual void Clear() override
		{
			Super::Clear();
			bSavedWantsToSprint = false;
			bSavedWantsAimSteering = false;
			bSavedAimTrackedJump = false;
			SavedAimTrackedJumpYawOffset = 0.0f;
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
			bSavedWantsAimSteering = Movement != nullptr && Movement->bWantsAimSteering;
			// Start-of-move jump state, restored before this move is replayed. Moves combine only with equal
			// flags and no movement-mode change, where the state this move reads is unchanged, so CombineWith
			// needs no rollback of it.
			bSavedAimTrackedJump = Movement != nullptr && Movement->bAimTrackedJump;
			SavedAimTrackedJumpYawOffset = Movement != nullptr ? Movement->AimTrackedJumpYawOffset : 0.0f;
		}

		virtual void PrepMoveFor(ACharacter* Character) override
		{
			Super::PrepMoveFor(Character);
			if (UAethelnCharacterMovementComponent* Movement =
				Character->GetCharacterMovement<UAethelnCharacterMovementComponent>())
			{
				Movement->bAimTrackedJump = bSavedAimTrackedJump;
				Movement->AimTrackedJumpYawOffset = SavedAimTrackedJumpYawOffset;
			}
		}

		virtual void PostUpdate(ACharacter* Character, EPostUpdateMode PostUpdateMode) override
		{
			// The engine rewrites SavedControlRotation with the live rotation after a replay too; keep the
			// recorded one so a later correction replays this move with the same yaw.
			const FRotator RecordedControlRotation = SavedControlRotation;
			Super::PostUpdate(Character, PostUpdateMode);
			if (PostUpdateMode == PostUpdate_Replay)
			{
				SavedControlRotation = RecordedControlRotation;
			}
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
			if (bSavedWantsAimSteering)
			{
				Flags |= FLAG_Custom_1;
			}
			return Flags;
		}

	private:
		bool bSavedWantsToSprint = false;
		bool bSavedWantsAimSteering = false;
		bool bSavedAimTrackedJump = false;
		float SavedAimTrackedJumpYawOffset = 0.0f;
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
	const bool bBackpedaling = IsBackpedaling();
	const float GroundMaxSpeed = SelectGroundMaxSpeed(
		bWantsToSprint && !Acceleration.IsNearlyZero(),
		bBackpedaling,
		BaseMaxSpeed,
		SprintSpeed);
	if (!bBackpedaling)
	{
		return GroundMaxSpeed;
	}
	// The engine caps speed at GetMaxSpeed() x AnalogInputModifier; keep that product at or below
	// the backpedal speed. The POC client already scales backward input by BackpedalSpeedScale, so
	// its cap is unchanged (standalone feel identical); full-magnitude backward input is held to it too.
	const float BackpedalScale = FMath::Clamp(BackpedalSpeedScale, 0.0f, 1.0f);
	return GroundMaxSpeed * FMath::Min(1.0f, BackpedalScale / FMath::Max(AnalogInputModifier, UE_SMALL_NUMBER));
}

bool UAethelnCharacterMovementComponent::IsBackpedaling() const
{
	// Never a client claim: judged from the move's acceleration against the move's control yaw.
	const FVector ControlForward = FRotator(0.0f, GetSimulatedControlYaw(), 0.0f).Vector();
	return (Acceleration.GetSafeNormal2D() | ControlForward) < -DirectionDotTolerance;
}

float UAethelnCharacterMovementComponent::GetSimulatedControlYaw() const
{
	// Correction replay runs with the live control rotation; judge a replayed move by the yaw it
	// was recorded with. The server has already applied the move's control rotation.
	if (const FSavedMove_Character* ReplayedMove = GetCurrentReplayedSavedMove())
	{
		return ReplayedMove->SavedControlRotation.Yaw;
	}
	return CharacterOwner != nullptr
		? CharacterOwner->GetControlRotation().Yaw
		: 0.0f;
}

UAethelnCharacterMovementComponent::FJumpTakeoff UAethelnCharacterMovementComponent::CalculateJumpTakeoff(
	const FVector& MoveAcceleration,
	float MaxAcceleration,
	float ControlYaw,
	float TakeoffSpeed,
	bool bAimSteering)
{
	FJumpTakeoff Takeoff;
	const FVector PlanarAcceleration(MoveAcceleration.X, MoveAcceleration.Y, 0.0f);
	if (MaxAcceleration <= UE_SMALL_NUMBER || PlanarAcceleration.IsNearlyZero())
	{
		return Takeoff;
	}
	Takeoff.bHasMoveInput = true;
	// Acceleration carries the analog magnitude, including the client's backpedal input shaping.
	Takeoff.HorizontalVelocity =
		(PlanarAcceleration / MaxAcceleration).GetClampedToMaxSize(1.0f) * TakeoffSpeed;
	const float ForwardDot =
		PlanarAcceleration.GetSafeNormal() | FRotator(0.0f, ControlYaw, 0.0f).Vector();
	const bool bBackpedaling = ForwardDot < -DirectionDotTolerance;
	const bool bPureLateral = FMath::Abs(ForwardDot) <= DirectionDotTolerance;
	const bool bCameraFacing = bBackpedaling || (bAimSteering && !bPureLateral);
	Takeoff.FacingYaw = bCameraFacing
		? ControlYaw
		: PlanarAcceleration.Rotation().Yaw;
	Takeoff.bAimTracked = bAimSteering && bPureLateral;
	return Takeoff;
}

bool UAethelnCharacterMovementComponent::DoJump(bool bReplayingMoves, float DeltaTime)
{
	// Read before Super switches to falling, so the takeoff keeps this move's sprint or backpedal cap.
	const bool bGroundTakeoff = IsMovingOnGround();
	const float TakeoffSpeed = GetMaxSpeed();
	if (!Super::DoJump(bReplayingMoves, DeltaTime))
	{
		return false;
	}
	if (!bGroundTakeoff)
	{
		return true;
	}
	const float ControlYaw = GetSimulatedControlYaw();
	const FJumpTakeoff Takeoff = CalculateJumpTakeoff(
		Acceleration,
		GetMaxAcceleration(),
		ControlYaw,
		TakeoffSpeed,
		bWantsAimSteering);
	if (Takeoff.bHasMoveInput)
	{
		// AirControl is zero, so this velocity holds for the whole jump.
		Velocity.X = Takeoff.HorizontalVelocity.X;
		Velocity.Y = Takeoff.HorizontalVelocity.Y;
		CharacterOwner->SetActorRotation(
			FRotator(0.0f, Takeoff.FacingYaw, 0.0f),
			ETeleportType::TeleportPhysics);
	}
	bAimTrackedJump = Takeoff.bAimTracked;
	AimTrackedJumpYawOffset = static_cast<float>(FRotator::NormalizeAxis(Takeoff.FacingYaw - ControlYaw));
	return true;
}

void UAethelnCharacterMovementComponent::ConfigureRotationMode(
	UCharacterMovementComponent& Movement,
	bool bFalling,
	bool bAimSteering,
	bool bBackpedaling,
	bool bTrackedJump)
{
	const bool bCameraFacing = bFalling
		? bAimSteering && !bTrackedJump
		: bAimSteering || bBackpedaling;
	Movement.bOrientRotationToMovement = !bFalling && !bCameraFacing;
	Movement.bUseControllerDesiredRotation = bCameraFacing;
}

void UAethelnCharacterMovementComponent::PhysicsRotation(float DeltaTime)
{
	if (!HasValidData() || (CharacterOwner->GetController() == nullptr && !bRunPhysicsWithNoController))
	{
		return;
	}
	// Chosen from this move's state on the owning client, in replay and on the server alike. The flags
	// are still written each move because the locomotion Animation Blueprint reads bOrientRotationToMovement.
	const bool bFalling = IsFalling();
	bAimTrackedJump = bAimTrackedJump && bFalling;
	ConfigureRotationMode(*this, bFalling, bWantsAimSteering, IsBackpedaling(), bAimTrackedJump);
	const float ControlYaw = GetSimulatedControlYaw();
	const float CurrentYaw = static_cast<float>(UpdatedComponent->GetComponentRotation().Yaw);
	if (bAimTrackedJump)
	{
		// While aim is held the sideways body turns with camera yaw; otherwise it holds and the offset
		// follows, so re-aiming mid-air resumes from the held facing.
		if (bWantsAimSteering)
		{
			MoveUpdatedComponent(
				FVector::ZeroVector,
				FRotator(0.0f, FRotator::NormalizeAxis(ControlYaw + AimTrackedJumpYawOffset), 0.0f),
				false);
		}
		else
		{
			AimTrackedJumpYawOffset = static_cast<float>(FRotator::NormalizeAxis(CurrentYaw - ControlYaw));
		}
		return;
	}
	if (!bUseControllerDesiredRotation)
	{
		Super::PhysicsRotation(DeltaTime);
		return;
	}
	// The engine's controller-desired path would read the live control rotation, which correction
	// replay must not use; turn toward this move's control yaw at the same rate instead.
	const float TargetYaw = static_cast<float>(FRotator::NormalizeAxis(ControlYaw));
	if (!FMath::IsNearlyEqual(CurrentYaw, TargetYaw, 1e-3f))
	{
		MoveUpdatedComponent(
			FVector::ZeroVector,
			FRotator(0.0f, FMath::FixedTurn(CurrentYaw, TargetYaw, static_cast<float>(GetDeltaRotation(DeltaTime).Yaw)), 0.0f),
			false);
	}
}

void UAethelnCharacterMovementComponent::ControlledCharacterMove(const FVector& InputVector, float DeltaSeconds)
{
	// The engine checks jump input before it applies this move's acceleration, so a takeoff would read
	// the previous move. Apply it first; Super recomputes the same value. MoveAutonomous does the same.
	Acceleration = ScaleInputAcceleration(ConstrainInputAcceleration(InputVector));
	AnalogInputModifier = ComputeAnalogInputModifier();
	Super::ControlledCharacterMove(InputVector, DeltaSeconds);
}

void UAethelnCharacterMovementComponent::MoveAutonomous(
	float ClientTimeStamp,
	float DeltaTime,
	uint8 CompressedFlags,
	const FVector& NewAccel)
{
	if (HasValidData())
	{
		Acceleration = ConstrainInputAcceleration(NewAccel).GetClampedToMaxSize(GetMaxAcceleration());
		AnalogInputModifier = ComputeAnalogInputModifier();
	}
	Super::MoveAutonomous(ClientTimeStamp, DeltaTime, CompressedFlags, NewAccel);
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
	bWantsAimSteering = (Flags & FSavedMove_Character::FLAG_Custom_1) != 0;
}

bool UAethelnCharacterMovementComponent::ClientUpdatePositionAfterServerUpdate()
{
	// Replay applies each saved move's flags; restore the live input intent afterwards,
	// as the engine does for crouch, because sprint and aim input are edge triggered.
	const bool bRealWantsToSprint = bWantsToSprint;
	const bool bRealWantsAimSteering = bWantsAimSteering;
	const bool bReplayed = Super::ClientUpdatePositionAfterServerUpdate();
	bWantsToSprint = bRealWantsToSprint;
	bWantsAimSteering = bRealWantsAimSteering;
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
	// Runs on a standalone authority pawn: valid in Development, but the engine's checkSlow
	// role/net-mode asserts in GetPredictionData_Client_Character would fire in a Debug build.
	ClientMovement->bWantsToSprint = false;
	ClientData->SavedMoves.Add(SecondSprintMove);
	ClientData->bUpdatePosition = true;
	TestTrue(TEXT("Correction replays the unacknowledged sprint move"), ClientMovement->ClientUpdatePositionAfterServerUpdate());
	TestFalse(TEXT("Replay restores the live sprint intent afterwards"), ClientMovement->bWantsToSprint);
	ClientData->SavedMoves.Reset();

	// Aim steering uses custom flag 1 the same way, and each move keeps its start-of-move jump tracking state.
	constexpr int32 AimFlag = FSavedMove_Character::FLAG_Custom_1;
	ClientMovement->bWantsAimSteering = true;
	ClientMovement->bAimTrackedJump = true;
	ClientMovement->AimTrackedJumpYawOffset = 90.0f;
	FSavedMovePtr AimMove = ClientData->AllocateNewMove();
	AimMove->SetMoveFor(ClientCharacter, MoveDeltaTime, Accel, *ClientData);
	ClientMovement->bWantsAimSteering = false;
	ClientMovement->bAimTrackedJump = false;
	ClientMovement->AimTrackedJumpYawOffset = 0.0f;
	FSavedMovePtr FreeMove = ClientData->AllocateNewMove();
	FreeMove->SetMoveFor(ClientCharacter, MoveDeltaTime, Accel, *ClientData);
	TestEqual(TEXT("Aim intent packs into custom flag 1"), AimMove->GetCompressedFlags() & AimFlag, AimFlag);
	TestEqual(TEXT("No aim intent leaves custom flag 1 clear"), FreeMove->GetCompressedFlags() & AimFlag, 0);
	TestFalse(
		TEXT("Moves with different aim intent never combine"),
		AimMove->CanCombineWith(FreeMove, ClientCharacter, 1.0f));
	ServerMovement->UpdateFromCompressedFlags(AimMove->GetCompressedFlags());
	TestTrue(TEXT("Server restores aim intent from the received flags"), ServerMovement->bWantsAimSteering);
	ServerMovement->UpdateFromCompressedFlags(FreeMove->GetCompressedFlags());
	TestFalse(TEXT("Server clears aim intent when the flag is absent"), ServerMovement->bWantsAimSteering);

	AimMove->PrepMoveFor(ClientCharacter);
	TestTrue(TEXT("Preparing a replay restores the move's tracked-jump state"), ClientMovement->bAimTrackedJump);
	TestEqual(TEXT("Preparing a replay restores the move's tracking offset"), ClientMovement->AimTrackedJumpYawOffset, 90.0f);
	AimMove->Clear();
	TestEqual(TEXT("Cleared pooled move forgets aim intent"), AimMove->GetCompressedFlags() & AimFlag, 0);
	AimMove->PrepMoveFor(ClientCharacter);
	TestFalse(TEXT("Cleared pooled move forgets the tracked-jump state"), ClientMovement->bAimTrackedJump);
	TestEqual(TEXT("Cleared pooled move forgets the tracking offset"), ClientMovement->AimTrackedJumpYawOffset, 0.0f);
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
	const float BackpedalSpeed = WalkSpeed * Movement->BackpedalSpeedScale;
	const float PeakShapedBackwardSpeed =
		RunAuthorityMoves(60, 0, FVector(-MaxAccel * Movement->BackpedalSpeedScale, 0.0f, 0.0f));
	TestNearlyEqual(
		TEXT("Client-shaped backpedal input still converges to the backpedal speed"),
		static_cast<float>(Movement->Velocity.Size2D()), BackpedalSpeed, SpeedTolerance);
	TestTrue(TEXT("Client-shaped backpedal never exceeds the backpedal speed"), PeakShapedBackwardSpeed <= BackpedalSpeed + SpeedTolerance);

	Movement->StopMovementImmediately();
	const float PeakBackwardSpeed =
		RunAuthorityMoves(60, SprintFlag, FVector(-MaxAccel, 0.0f, 0.0f));
	TestTrue(TEXT("Server received the backward sprint request"), Movement->bWantsToSprint);
	TestNearlyEqual(
		TEXT("Full-magnitude backward sprint request is held to the backpedal speed"),
		static_cast<float>(Movement->Velocity.Size2D()), BackpedalSpeed, SpeedTolerance);
	TestTrue(TEXT("Full-magnitude backward sprint request never exceeds the backpedal speed"), PeakBackwardSpeed <= BackpedalSpeed + SpeedTolerance);

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
	// Engine threshold check only: a one-move offset of the sprint/walk speed difference exceeds it.
	const FVector SprintPredictedLocation =
		ServerLocation + FVector((SprintSpeed - WalkSpeed) * MoveDeltaTime, 0.0f, 0.0f);
	FMovementBaseInterfaceData MovementBase;
	TestFalse(
		TEXT("Matching client location is accepted"),
		Movement->ServerExceedsAllowablePositionError(
			TimeStamp, MoveDeltaTime, FVector::ZeroVector, ServerLocation, ServerLocation,
			&MovementBase, NAME_None, Movement->PackNetworkMovementMode()));
	TestTrue(
		TEXT("Engine position-error threshold rejects a one-move sprint/walk speed-difference offset"),
		Movement->ServerExceedsAllowablePositionError(
			TimeStamp, MoveDeltaTime, FVector::ZeroVector, SprintPredictedLocation, SprintPredictedLocation,
			&MovementBase, NAME_None, Movement->PackNetworkMovementMode()));
	return true;
}

/**
 * A predicting client driven through the POC input entry points and ControlledCharacterMove, and a
 * server copy fed only what the client's saved move carries (compressed flags, rounded acceleration
 * and control rotation) through MoveAutonomous. Neither has a remote connection; this isolates the
 * shared simulation code. A simulated proxy receives the server's replicated movement after each move,
 * as a remote player's copy does.
 */
struct FAethelnMovementNetPredictionPair
{
	AAethelnPlayerCharacter* Client = nullptr;
	AAethelnPlayerCharacter* Server = nullptr;
	AAethelnPlayerCharacter* Proxy = nullptr;
	APlayerController* ServerController = nullptr;
	UAethelnCharacterMovementComponent* ClientMovement = nullptr;
	UAethelnCharacterMovementComponent* ServerMovement = nullptr;
	FVector ServerOffset = FVector::ZeroVector;
	FVector ProxyOffset = FVector::ZeroVector;
	float TimeStamp = 0.0f;
	float MaxYawError = 0.0f;
	float MaxProxyYawError = 0.0f;
	bool bAcceptedEveryMove = true;

	FAethelnMovementNetPredictionPair(const AethelnMovementNetTests::FTestWorld& TestWorld, const FVector& Location)
	{
		Client = TestWorld.SpawnGroundedCharacter(Location);
		Server = TestWorld.SpawnGroundedCharacter(Location + FVector(500.0f, 0.0f, 0.0f));
		Proxy = TestWorld.SpawnGroundedCharacter(Location - FVector(500.0f, 0.0f, 0.0f));
		if (Client == nullptr || Server == nullptr || Proxy == nullptr)
		{
			return;
		}
		Proxy->SetRole(ROLE_SimulatedProxy);
		ProxyOffset = Proxy->GetActorLocation() - Server->GetActorLocation();
		FActorSpawnParameters SpawnParameters;
		SpawnParameters.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
		APlayerController* PlayerController = TestWorld.World->SpawnActor<APlayerController>(
			APlayerController::StaticClass(), FVector::ZeroVector, FRotator::ZeroRotator, SpawnParameters);
		ServerController = TestWorld.World->SpawnActor<APlayerController>(
			APlayerController::StaticClass(), FVector::ZeroVector, FRotator::ZeroRotator, SpawnParameters);
		if (PlayerController == nullptr || ServerController == nullptr)
		{
			return;
		}
		// The client needs a controller for the POC input path; the server copy's controller receives the
		// client's control rotation each move, as ServerMove does.
		PlayerController->Possess(Client);
		ServerController->Possess(Server);
		ClientMovement = AethelnMovementNetTests::GetMovement(Client);
		ServerMovement = AethelnMovementNetTests::GetMovement(Server);
		ServerOffset = Server->GetActorLocation() - Client->GetActorLocation();
	}

	bool IsValid() const
	{
		return ClientMovement != nullptr && ServerMovement != nullptr
			&& Client->GetController() != nullptr && Server->GetController() != nullptr;
	}

	void SetControlYaw(float Yaw)
	{
		Client->GetController()->SetControlRotation(FRotator(0.0f, Yaw, 0.0f));
	}

	/** One frame of client input and prediction, then the matching server move. Returns true when the server accepts the client location. */
	bool Step(const FVector2D& MoveInput, bool bPressJump, bool bSprint, bool bAimSteering = false)
	{
		Client->ReceiveAimSteeringIntent(bAimSteering);
		Client->ReceiveSprintIntent(bSprint);
		Client->ReceiveMoveInput(MoveInput);
		if (bPressJump)
		{
			Client->ReceiveJumpStarted();
		}
		// The flags the client's real saved move would send for this frame.
		FNetworkPredictionData_Client_Character* ClientData = ClientMovement->GetPredictionData_Client_Character();
		const FSavedMovePtr SavedMove = ClientData->AllocateNewMove();
		SavedMove->SetMoveFor(Client, AethelnMovementNetTests::MoveDeltaTime, FVector::ZeroVector, *ClientData);
		const uint8 Flags = SavedMove->GetCompressedFlags();
		TimeStamp += AethelnMovementNetTests::MoveDeltaTime;
		ClientMovement->ControlledCharacterMove(ClientMovement->ConsumeInputVector(), AethelnMovementNetTests::MoveDeltaTime);
		ServerController->SetControlRotation(Client->GetControlRotation());
		ServerMovement->MoveAutonomous(
			TimeStamp,
			AethelnMovementNetTests::MoveDeltaTime,
			Flags,
			ClientMovement->RoundAcceleration(ClientMovement->Acceleration));
		const FVector ClientLocation = Client->GetActorLocation() + ServerOffset;
		FMovementBaseInterfaceData MovementBase;
		const bool bAccepted = !ServerMovement->ServerExceedsAllowablePositionError(
			TimeStamp, AethelnMovementNetTests::MoveDeltaTime, ClientMovement->Acceleration, ClientLocation, ClientLocation,
			&MovementBase, NAME_None, ClientMovement->PackNetworkMovementMode());
		bAcceptedEveryMove &= bAccepted;
		MaxYawError = FMath::Max(MaxYawError, YawError());

		// What the server would replicate this frame, applied through the stock simulated-proxy path, then one
		// frame of the proxy's own movement tick (SimulatedTick), which must not change the replicated facing.
		Server->GatherCurrentMovement();
		FRepMovement ReplicatedMovement = Server->GetReplicatedMovement();
		ReplicatedMovement.Location += ProxyOffset;
		Proxy->SetReplicatedMovement(ReplicatedMovement);
		Proxy->OnRep_ReplicatedMovement();
		Proxy->GetCharacterMovement()->TickComponent(AethelnMovementNetTests::MoveDeltaTime, LEVELTICK_All, nullptr);
		MaxProxyYawError = FMath::Max(
			MaxProxyYawError,
			FMath::Abs(FRotator::NormalizeAxis(Proxy->GetActorRotation().Yaw - Client->GetActorRotation().Yaw)));
		return bAccepted;
	}

	void Steps(int32 Count, const FVector2D& MoveInput, bool bAimSteering)
	{
		for (int32 Index = 0; Index < Count; ++Index)
		{
			Step(MoveInput, false, false, bAimSteering);
		}
	}

	float VelocityError() const
	{
		return static_cast<float>((ClientMovement->Velocity - ServerMovement->Velocity).Size());
	}

	float YawError() const
	{
		return FMath::Abs(FRotator::NormalizeAxis(Client->GetActorRotation().Yaw - Server->GetActorRotation().Yaw));
	}
};

namespace AethelnMovementNetTests
{
	// Numeric comparison epsilon for yaw snapped in the shared simulation; not a tuning value.
	constexpr float YawTolerance = 0.5f;

	FVector Horizontal(const FVector& Vector)
	{
		return FVector(Vector.X, Vector.Y, 0.0f);
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnMovementNetJumpTakeoffParityTest,
	"Aetheln.Movement.Net.JumpTakeoffParity",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementNetJumpTakeoffParityTest::RunTest(const FString& Parameters)
{
	using namespace AethelnMovementNetTests;
	const FTestWorld TestWorld;
	FAethelnMovementNetPredictionPair Pair(TestWorld, FVector(0.0f, 0.0f, 100.0f));
	TestTrue(TEXT("Client and server POC characters are set up"), Pair.IsValid());
	if (!Pair.IsValid())
	{
		return false;
	}

	const float WalkSpeed = Pair.ClientMovement->MaxWalkSpeed;
	// Control yaw is zero on both, so +X is forward and +Y is right.
	const FVector2D Right(1.0f, 0.0f);
	const FVector2D Left(-1.0f, 0.0f);
	bool bServerAcceptedEveryMove = true;
	float MaxVelocityError = 0.0f;
	float MaxYawError = 0.0f;
	auto Step = [&Pair, &bServerAcceptedEveryMove, &MaxVelocityError, &MaxYawError](
		const FVector2D& MoveInput, bool bPressJump)
	{
		bServerAcceptedEveryMove &= Pair.Step(MoveInput, bPressJump, false);
		MaxVelocityError = FMath::Max(MaxVelocityError, Pair.VelocityError());
		MaxYawError = FMath::Max(MaxYawError, Pair.YawError());
	};

	for (int32 Index = 0; Index < 30; ++Index)
	{
		Step(Right, false);
	}
	TestTrue(TEXT("Client runs right on the ground"), Pair.ClientMovement->IsMovingOnGround());
	Step(Right, true);
	TestTrue(TEXT("First jump takes off"), Pair.ClientMovement->IsFalling());

	// Airborne: switch to left and press jump before landing; the landing buffer fires the rejump.
	bool bLanded = false;
	bool bRejumped = false;
	FVector ClientTakeoffVelocity = FVector::ZeroVector;
	FVector ServerTakeoffVelocity = FVector::ZeroVector;
	float ClientTakeoffYaw = 0.0f;
	float ServerTakeoffYaw = 0.0f;
	for (int32 Index = 0; Index < 120 && !bRejumped; ++Index)
	{
		Step(Index < 40 ? Right : Left, Index == 40);
		bLanded |= Pair.ClientMovement->IsMovingOnGround();
		if (bLanded && Pair.ClientMovement->IsFalling())
		{
			bRejumped = true;
			ClientTakeoffVelocity = Pair.ClientMovement->Velocity;
			ServerTakeoffVelocity = Pair.ServerMovement->Velocity;
			ClientTakeoffYaw = Pair.Client->GetActorRotation().Yaw;
			ServerTakeoffYaw = Pair.Server->GetActorRotation().Yaw;
		}
	}
	TestTrue(TEXT("Client landed from the first jump"), bLanded);
	TestTrue(TEXT("Buffered rejump fired after landing"), bRejumped);
	TestTrue(
		TEXT("Client rejump launches left at walk speed"),
		Horizontal(ClientTakeoffVelocity).Equals(FVector(0.0f, -WalkSpeed, 0.0f), SpeedTolerance));
	TestTrue(
		TEXT("Server simulates the same rejump takeoff velocity"),
		(ClientTakeoffVelocity - ServerTakeoffVelocity).Size() <= SpeedTolerance);
	TestTrue(
		TEXT("Client rejump faces the new travel direction"),
		FMath::Abs(FRotator::NormalizeAxis(ClientTakeoffYaw + 90.0f)) <= YawTolerance);
	TestTrue(
		TEXT("Server rejump faces the same direction"),
		FMath::Abs(FRotator::NormalizeAxis(ServerTakeoffYaw - ClientTakeoffYaw)) <= YawTolerance);

	for (int32 Index = 0; Index < 20; ++Index)
	{
		Step(Left, false);
	}
	TestTrue(TEXT("Server accepts every predicted client location (no correction)"), bServerAcceptedEveryMove);
	TestTrue(TEXT("Predicted and server velocity never diverge"), MaxVelocityError <= SpeedTolerance);
	TestTrue(TEXT("Predicted and server facing never diverge"), MaxYawError <= YawTolerance);

	// A sprint jump pressed on the very first movement frame launches at sprint speed on both.
	FAethelnMovementNetPredictionPair SprintPair(TestWorld, FVector(0.0f, 5000.0f, 100.0f));
	TestTrue(TEXT("Sprint client and server POC characters are set up"), SprintPair.IsValid());
	if (!SprintPair.IsValid())
	{
		return false;
	}
	for (int32 Index = 0; Index < 10; ++Index)
	{
		SprintPair.Step(FVector2D::ZeroVector, false, false);
	}
	TestTrue(TEXT("Sprint client settles on the ground"), SprintPair.ClientMovement->IsMovingOnGround());
	const bool bSprintMoveAccepted = SprintPair.Step(FVector2D(0.0f, 1.0f), true, true);
	TestTrue(
		TEXT("First-frame sprint jump launches forward at sprint speed"),
		Horizontal(SprintPair.ClientMovement->Velocity).Equals(
			FVector(SprintPair.ClientMovement->SprintSpeed, 0.0f, 0.0f), SpeedTolerance));
	TestTrue(TEXT("Server simulates the same first-frame sprint jump"), SprintPair.VelocityError() <= SpeedTolerance);
	TestTrue(TEXT("Server accepts the first-frame sprint jump location"), bSprintMoveAccepted);
	return true;
}


/**
 * A forward sprint jump simulated once by an authority reference, and the same move recorded by a
 * second character at a non-zero control yaw, then replayed ReplayCount times after the camera
 * turned around. Judging the move by the live yaw would call it a backpedal (walk cap, camera facing).
 * The aimed variant records a forward-diagonal aim jump instead and releases aim before the replay:
 * both passes must face the recorded camera yaw, not the diagonal travel direction.
 */
struct FAethelnMovementNetJumpReplayScenario
{
	static bool Run(FAutomationTestBase& Test, int32 ReplayCount, bool bAimed = false)
	{
		using namespace AethelnMovementNetTests;
		const FTestWorld TestWorld;
		AAethelnPlayerCharacter* Reference = TestWorld.SpawnGroundedCharacter(FVector(0.0f, 0.0f, 100.0f));
		AAethelnPlayerCharacter* Replayed = TestWorld.SpawnGroundedCharacter(FVector(500.0f, 0.0f, 100.0f));
		FActorSpawnParameters SpawnParameters;
		SpawnParameters.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
		APlayerController* ReferenceController = TestWorld.World != nullptr
			? TestWorld.World->SpawnActor<APlayerController>(
				APlayerController::StaticClass(), FVector::ZeroVector, FRotator::ZeroRotator, SpawnParameters)
			: nullptr;
		APlayerController* ReplayedController = TestWorld.World != nullptr
			? TestWorld.World->SpawnActor<APlayerController>(
				APlayerController::StaticClass(), FVector::ZeroVector, FRotator::ZeroRotator, SpawnParameters)
			: nullptr;
		UAethelnCharacterMovementComponent* ReferenceMovement = GetMovement(Reference);
		UAethelnCharacterMovementComponent* ReplayedMovement = GetMovement(Replayed);
		Test.TestNotNull(TEXT("Reference POC character uses the project movement component"), ReferenceMovement);
		Test.TestNotNull(TEXT("Replayed POC character uses the project movement component"), ReplayedMovement);
		Test.TestNotNull(TEXT("Reference character has a player controller"), ReferenceController);
		Test.TestNotNull(TEXT("Replayed character has a player controller"), ReplayedController);
		if (ReferenceMovement == nullptr || ReplayedMovement == nullptr
			|| ReferenceController == nullptr || ReplayedController == nullptr)
		{
			return false;
		}
		ReferenceController->Possess(Reference);
		ReplayedController->Possess(Replayed);
		// Non-zero, so a saved move that kept a cleared (zero) yaw could not pass by accident.
		const FRotator RecordedControlRotation(0.0f, 90.0f, 0.0f);
		ReferenceController->SetControlRotation(RecordedControlRotation);
		ReplayedController->SetControlRotation(RecordedControlRotation);

		float TimeStamp = 0.0f;
		for (int32 Index = 0; Index < 10; ++Index)
		{
			TimeStamp += MoveDeltaTime;
			ReferenceMovement->MoveAutonomous(TimeStamp, MoveDeltaTime, 0, FVector::ZeroVector);
			ReplayedMovement->MoveAutonomous(TimeStamp, MoveDeltaTime, 0, FVector::ZeroVector);
		}
		Test.TestTrue(TEXT("Both characters settle on the ground"),
			ReferenceMovement->IsMovingOnGround() && ReplayedMovement->IsMovingOnGround());

		const FVector MoveDirection = RecordedControlRotation.RotateVector(
			bAimed ? FVector(UE_INV_SQRT_2, UE_INV_SQRT_2, 0.0f) : FVector::ForwardVector);
		const FVector MoveAccel = MoveDirection * ReferenceMovement->GetMaxAcceleration();
		TimeStamp += MoveDeltaTime;
		ReferenceMovement->MoveAutonomous(
			TimeStamp,
			MoveDeltaTime,
			FSavedMove_Character::FLAG_JumpPressed
				| (bAimed ? FSavedMove_Character::FLAG_Custom_1 : FSavedMove_Character::FLAG_Custom_0),
			MoveAccel);
		Test.TestTrue(
			TEXT("First pass launches along the held direction at its speed cap"),
			Horizontal(ReferenceMovement->Velocity).Equals(
				MoveDirection * (bAimed ? ReferenceMovement->MaxWalkSpeed : ReferenceMovement->SprintSpeed), SpeedTolerance));
		Test.TestTrue(
			TEXT("First pass faces the recorded camera yaw"),
			FMath::Abs(FRotator::NormalizeAxis(
				Reference->GetActorRotation().Yaw - RecordedControlRotation.Yaw)) <= YawTolerance);

		const FVector ReplayStartLocation = Replayed->GetActorLocation();
		const FRotator ReplayStartRotation = Replayed->GetActorRotation();
		Test.TestTrue(
			TEXT("Each replay starts away from the takeoff yaw, so a replay that never sets facing fails"),
			FMath::Abs(FRotator::NormalizeAxis(ReplayStartRotation.Yaw - RecordedControlRotation.Yaw)) > YawTolerance);
		FNetworkPredictionData_Client_Character* ClientData = ReplayedMovement->GetPredictionData_Client_Character();
		ReplayedMovement->bWantsToSprint = !bAimed;
		ReplayedMovement->bWantsAimSteering = bAimed;
		Replayed->Jump();
		FSavedMovePtr JumpMove = ClientData->AllocateNewMove();
		JumpMove->SetMoveFor(Replayed, MoveDeltaTime, MoveAccel, *ClientData);
		JumpMove->PostUpdate(Replayed, FSavedMove_Character::PostUpdate_Record);
		ReplayedController->SetControlRotation(RecordedControlRotation + FRotator(0.0f, 180.0f, 0.0f));
		// The player released sprint and aim after the move was recorded.
		ReplayedMovement->bWantsToSprint = false;
		ReplayedMovement->bWantsAimSteering = false;
		for (int32 Replay = 0; Replay < ReplayCount; ++Replay)
		{
			if (Replay > 0)
			{
				// Each correction replays from the server state, here the grounded pre-jump state.
				Replayed->SetActorLocationAndRotation(ReplayStartLocation, ReplayStartRotation);
				ReplayedMovement->Velocity = FVector::ZeroVector;
				ReplayedMovement->SetMovementMode(MOVE_Walking);
				Replayed->ResetJumpState();
			}
			ClientData->SavedMoves.Reset();
			ClientData->SavedMoves.Add(JumpMove);
			ClientData->bUpdatePosition = true;
			Test.TestTrue(
				FString::Printf(TEXT("Correction %d replays the jump move"), Replay + 1),
				ReplayedMovement->ClientUpdatePositionAfterServerUpdate());
			Test.TestTrue(
				FString::Printf(TEXT("Correction %d replay launches at the first-pass takeoff velocity"), Replay + 1),
				(ReplayedMovement->Velocity - ReferenceMovement->Velocity).Size() <= SpeedTolerance);
			Test.TestTrue(
				FString::Printf(TEXT("Correction %d replay snaps facing to the first-pass yaw"), Replay + 1),
				FMath::Abs(FRotator::NormalizeAxis(
					Replayed->GetActorRotation().Yaw - Reference->GetActorRotation().Yaw)) <= YawTolerance);
		}
		Test.TestFalse(TEXT("Replay restores the live sprint intent"), ReplayedMovement->bWantsToSprint);
		Test.TestFalse(TEXT("Replay restores the live aim-steering intent"), ReplayedMovement->bWantsAimSteering);
		ClientData->SavedMoves.Reset();
		return true;
	}
};

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnMovementNetJumpTakeoffReplayTest,
	"Aetheln.Movement.Net.JumpTakeoffReplay",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementNetJumpTakeoffReplayTest::RunTest(const FString& Parameters)
{
	return FAethelnMovementNetJumpReplayScenario::Run(*this, 1);
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnMovementNetJumpTakeoffRepeatedReplayTest,
	"Aetheln.Movement.Net.JumpTakeoffRepeatedReplay",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementNetJumpTakeoffRepeatedReplayTest::RunTest(const FString& Parameters)
{
	// A move still unacknowledged after one correction is replayed again by the next one.
	return FAethelnMovementNetJumpReplayScenario::Run(*this, 2);
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnMovementNetAimJumpTakeoffReplayTest,
	"Aetheln.Movement.Net.AimJumpTakeoffReplay",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementNetAimJumpTakeoffReplayTest::RunTest(const FString& Parameters)
{
	return FAethelnMovementNetJumpReplayScenario::Run(*this, 2, true);
}

namespace AethelnMovementNetTests
{
	const FVector2D MoveRight(1.0f, 0.0f);
	const FVector2D MoveBack(0.0f, -1.0f);
	const FVector2D MoveForwardRight(UE_INV_SQRT_2, UE_INV_SQRT_2);

	void TestYaw(FAutomationTestBase& Test, const TCHAR* What, float Actual, float Expected)
	{
		Test.TestTrue(
			FString::Printf(TEXT("%s (actual %.1f, expected %.1f)"), What, Actual, Expected),
			FMath::Abs(FRotator::NormalizeAxis(Actual - Expected)) <= YawTolerance);
	}

	void TestFacingParity(FAutomationTestBase& Test, const FAethelnMovementNetPredictionPair& Pair)
	{
		Test.TestTrue(TEXT("Server accepts every predicted client location (no correction)"), Pair.bAcceptedEveryMove);
		Test.TestTrue(
			FString::Printf(TEXT("Server facing matches the owning client on every move (worst %.1f deg)"), Pair.MaxYawError),
			Pair.MaxYawError <= YawTolerance);
		Test.TestTrue(
			FString::Printf(TEXT("Simulated proxy facing matches the owning client on every move (worst %.1f deg)"), Pair.MaxProxyYawError),
			Pair.MaxProxyYawError <= YawTolerance);
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnMovementNetAimJumpFacingParityTest,
	"Aetheln.Movement.Net.AimJumpFacingParity",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementNetAimJumpFacingParityTest::RunTest(const FString& Parameters)
{
	using namespace AethelnMovementNetTests;
	const FTestWorld TestWorld;
	FAethelnMovementNetPredictionPair Pair(TestWorld, FVector(0.0f, 0.0f, 100.0f));
	TestTrue(TEXT("Client and server POC characters are set up"), Pair.IsValid());
	if (!Pair.IsValid())
	{
		return false;
	}
	Pair.Steps(10, FVector2D::ZeroVector, true);
	Pair.Step(MoveForwardRight, true, false, true);
	TestTrue(TEXT("Aimed forward-diagonal jump takes off"), Pair.ClientMovement->IsFalling());
	TestYaw(*this, TEXT("Client aimed diagonal takeoff faces the camera"), Pair.Client->GetActorRotation().Yaw, 0.0f);
	TestYaw(*this, TEXT("Server aimed diagonal takeoff faces the camera"), Pair.Server->GetActorRotation().Yaw, 0.0f);
	// Airborne camera turn, then landing and aimed running with the camera turned.
	Pair.SetControlYaw(20.0f);
	Pair.Steps(90, MoveForwardRight, true);
	TestTrue(TEXT("Client landed"), Pair.ClientMovement->IsMovingOnGround());
	TestYaw(*this, TEXT("Client ends facing the turned camera"), Pair.Client->GetActorRotation().Yaw, 20.0f);
	TestFacingParity(*this, Pair);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnMovementNetReticleSteeringParityTest,
	"Aetheln.Movement.Net.ReticleSteeringParity",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementNetReticleSteeringParityTest::RunTest(const FString& Parameters)
{
	using namespace AethelnMovementNetTests;
	const FTestWorld TestWorld;
	FAethelnMovementNetPredictionPair Pair(TestWorld, FVector(0.0f, 0.0f, 100.0f));
	TestTrue(TEXT("Client and server POC characters are set up"), Pair.IsValid());
	if (!Pair.IsValid())
	{
		return false;
	}
	Pair.SetControlYaw(60.0f);
	Pair.Steps(60, MoveRight, true);
	TestYaw(*this, TEXT("Client reticle strafe faces the camera"), Pair.Client->GetActorRotation().Yaw, 60.0f);
	Pair.SetControlYaw(-45.0f);
	Pair.Steps(30, MoveRight, true);
	TestYaw(*this, TEXT("Client reticle strafe follows the turned camera"), Pair.Client->GetActorRotation().Yaw, -45.0f);
	TestFacingParity(*this, Pair);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnMovementNetBackpedalFacingParityTest,
	"Aetheln.Movement.Net.BackpedalFacingParity",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementNetBackpedalFacingParityTest::RunTest(const FString& Parameters)
{
	using namespace AethelnMovementNetTests;
	const FTestWorld TestWorld;
	FAethelnMovementNetPredictionPair Pair(TestWorld, FVector(0.0f, 0.0f, 100.0f));
	TestTrue(TEXT("Client and server POC characters are set up"), Pair.IsValid());
	if (!Pair.IsValid())
	{
		return false;
	}
	// Without aim steering, running faces travel and S backpedals facing the camera.
	Pair.Steps(30, MoveRight, false);
	TestYaw(*this, TEXT("Client free run faces travel"), Pair.Client->GetActorRotation().Yaw, 90.0f);
	Pair.Steps(30, MoveBack, false);
	TestYaw(*this, TEXT("Client backpedal faces the camera"), Pair.Client->GetActorRotation().Yaw, 0.0f);
	TestFacingParity(*this, Pair);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnMovementNetAirborneAimTrackingParityTest,
	"Aetheln.Movement.Net.AirborneAimTrackingParity",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementNetAirborneAimTrackingParityTest::RunTest(const FString& Parameters)
{
	using namespace AethelnMovementNetTests;
	const FTestWorld TestWorld;
	FAethelnMovementNetPredictionPair Pair(TestWorld, FVector(0.0f, 0.0f, 100.0f));
	TestTrue(TEXT("Client and server POC characters are set up"), Pair.IsValid());
	if (!Pair.IsValid())
	{
		return false;
	}
	Pair.Steps(10, FVector2D::ZeroVector, true);
	Pair.Step(MoveRight, true, false, true);
	TestYaw(*this, TEXT("Client pure-lateral aimed takeoff faces travel"), Pair.Client->GetActorRotation().Yaw, 90.0f);
	// Airborne camera turns rotate the sideways body by the same delta without redirecting velocity,
	// here past the +/-180 yaw boundary.
	Pair.SetControlYaw(100.0f);
	Pair.Steps(5, MoveRight, true);
	TestTrue(TEXT("Still airborne while tracking"), Pair.ClientMovement->IsFalling());
	TestYaw(*this, TEXT("Client airborne body tracks the camera turn"), Pair.Client->GetActorRotation().Yaw, -170.0f);
	TestYaw(*this, TEXT("Server airborne body tracks the camera turn"), Pair.Server->GetActorRotation().Yaw, -170.0f);
	Pair.SetControlYaw(-40.0f);
	Pair.Step(MoveRight, false, false, true);
	TestYaw(*this, TEXT("Client airborne body tracks a turn back across zero"), Pair.Client->GetActorRotation().Yaw, 50.0f);
	TestTrue(
		TEXT("Airborne tracking never redirects the locked takeoff velocity"),
		Horizontal(Pair.ClientMovement->Velocity).Equals(FVector(0.0f, Pair.ClientMovement->MaxWalkSpeed, 0.0f), SpeedTolerance));
	Pair.Steps(90, MoveRight, true);
	TestTrue(TEXT("Client landed"), Pair.ClientMovement->IsMovingOnGround());
	TestFacingParity(*this, Pair);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnMovementNetAimTrackingReplayTest,
	"Aetheln.Movement.Net.AimTrackingReplay",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementNetAimTrackingReplayTest::RunTest(const FString& Parameters)
{
	using namespace AethelnMovementNetTests;
	const FTestWorld TestWorld;
	AAethelnPlayerCharacter* Character = TestWorld.SpawnGroundedCharacter(FVector(0.0f, 0.0f, 100.0f));
	FActorSpawnParameters SpawnParameters;
	SpawnParameters.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
	APlayerController* Controller = TestWorld.World != nullptr
		? TestWorld.World->SpawnActor<APlayerController>(
			APlayerController::StaticClass(), FVector::ZeroVector, FRotator::ZeroRotator, SpawnParameters)
		: nullptr;
	UAethelnCharacterMovementComponent* Movement = GetMovement(Character);
	TestNotNull(TEXT("POC character uses the project movement component"), Movement);
	TestNotNull(TEXT("POC character has a player controller"), Controller);
	if (Movement == nullptr || Controller == nullptr)
	{
		return false;
	}
	Controller->Possess(Character);

	// An aimed pure-right takeoff at camera yaw 0: the body faces travel (90) and then tracks camera turns.
	const FVector RightAccel = FVector::RightVector * Movement->GetMaxAcceleration();
	float TimeStamp = 0.0f;
	for (int32 Index = 0; Index < 10; ++Index)
	{
		TimeStamp += MoveDeltaTime;
		Movement->MoveAutonomous(TimeStamp, MoveDeltaTime, 0, FVector::ZeroVector);
	}
	TimeStamp += MoveDeltaTime;
	Movement->MoveAutonomous(
		TimeStamp, MoveDeltaTime, FSavedMove_Character::FLAG_JumpPressed | FSavedMove_Character::FLAG_Custom_1, RightAccel);
	TestTrue(TEXT("Aimed lateral jump takes off aim tracked"), Movement->IsFalling() && Movement->bAimTrackedJump);

	// Record the airborne moves as a predicting client does: aim held at camera 30, released at 60, re-pressed at 100.
	FNetworkPredictionData_Client_Character* ClientData = Movement->GetPredictionData_Client_Character();
	ClientData->SavedMoves.Reset();
	const FVector AirborneStartLocation = Character->GetActorLocation();
	const FVector AirborneStartVelocity = Movement->Velocity;
	const float PhaseControlYaws[] = {30.0f, 60.0f, 100.0f};
	const bool bPhaseAims[] = {true, false, true};
	for (int32 Phase = 0; Phase < 3; ++Phase)
	{
		Controller->SetControlRotation(FRotator(0.0f, PhaseControlYaws[Phase], 0.0f));
		Movement->bWantsAimSteering = bPhaseAims[Phase];
		for (int32 Index = 0; Index < 5; ++Index)
		{
			FSavedMovePtr Move = ClientData->AllocateNewMove();
			Move->SetMoveFor(Character, MoveDeltaTime, RightAccel, *ClientData);
			TimeStamp += MoveDeltaTime;
			Movement->MoveAutonomous(TimeStamp, MoveDeltaTime, Move->GetCompressedFlags(), RightAccel);
			Move->PostUpdate(Character, FSavedMove_Character::PostUpdate_Record);
			ClientData->SavedMoves.Add(Move);
		}
	}
	TestTrue(TEXT("Still airborne after the recorded moves"), Movement->IsFalling());
	const float FirstPassYaw = Character->GetActorRotation().Yaw;
	// 0 + 90 while aimed at 30 gives 120; released at 60 holds 120 (offset 60); re-pressed at 100 gives 160.
	TestYaw(*this, TEXT("First pass resumes tracking from the held facing after re-aim"), FirstPassYaw, 160.0f);

	// A correction back to the first recorded move after the client predicted a landing (tracking state
	// cleared), with the live camera and aim since changed.
	Character->SetActorLocation(AirborneStartLocation);
	Movement->Velocity = AirborneStartVelocity;
	Movement->bAimTrackedJump = false;
	Movement->AimTrackedJumpYawOffset = 0.0f;
	Controller->SetControlRotation(FRotator(0.0f, -90.0f, 0.0f));
	Movement->bWantsAimSteering = false;
	ClientData->bUpdatePosition = true;
	TestTrue(TEXT("Correction replays the airborne moves"), Movement->ClientUpdatePositionAfterServerUpdate());
	TestYaw(
		*this,
		TEXT("Replay across aim release and re-press ends with the first-pass (server) facing"),
		Character->GetActorRotation().Yaw,
		FirstPassYaw);
	ClientData->SavedMoves.Reset();
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnMovementNetFacingSpoofBoundedTest,
	"Aetheln.Movement.Net.FacingSpoofBounded",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementNetFacingSpoofBoundedTest::RunTest(const FString& Parameters)
{
	using namespace AethelnMovementNetTests;
	const FTestWorld TestWorld;
	AAethelnPlayerCharacter* Character = TestWorld.SpawnGroundedCharacter(FVector(0.0f, 0.0f, 100.0f));
	FActorSpawnParameters SpawnParameters;
	SpawnParameters.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
	APlayerController* Controller = TestWorld.World != nullptr
		? TestWorld.World->SpawnActor<APlayerController>(
			APlayerController::StaticClass(), FVector::ZeroVector, FRotator::ZeroRotator, SpawnParameters)
		: nullptr;
	UAethelnCharacterMovementComponent* Movement = GetMovement(Character);
	TestNotNull(TEXT("POC character uses the project movement component"), Movement);
	TestNotNull(TEXT("POC character has a player controller"), Controller);
	if (Movement == nullptr || Controller == nullptr)
	{
		return false;
	}
	Controller->Possess(Character);

	// The server derives facing only from the move's flags, acceleration and control rotation.
	constexpr uint8 AimFlag = FSavedMove_Character::FLAG_Custom_1;
	const float MaxTurnPerMove = Movement->RotationRate.Yaw * MoveDeltaTime + YawTolerance;
	float TimeStamp = 0.0f;
	float MaxTurn = 0.0f;
	// MoveAutonomous is protected; this lambda shares the friend test's access.
	auto RunAuthorityMoves = [Movement, Character, &TimeStamp, &MaxTurn](int32 MoveCount, uint8 Flags, const FVector& Accel)
	{
		float PeakSpeed = 0.0f;
		for (int32 Index = 0; Index < MoveCount; ++Index)
		{
			const float YawBefore = Character->GetActorRotation().Yaw;
			TimeStamp += MoveDeltaTime;
			Movement->MoveAutonomous(TimeStamp, MoveDeltaTime, Flags, Accel);
			MaxTurn = FMath::Max(MaxTurn, FMath::Abs(FRotator::NormalizeAxis(Character->GetActorRotation().Yaw - YawBefore)));
			PeakSpeed = FMath::Max(PeakSpeed, static_cast<float>(Movement->Velocity.Size2D()));
		}
		return PeakSpeed;
	};
	RunAuthorityMoves(10, 0, FVector::ZeroVector);
	Controller->SetControlRotation(FRotator(0.0f, 180.0f, 0.0f));
	RunAuthorityMoves(30, 0, FVector::ZeroVector);
	TestYaw(*this, TEXT("Without the aim flag a turned camera never turns an idle body"), Character->GetActorRotation().Yaw, 0.0f);
	RunAuthorityMoves(30, AimFlag, FVector::ZeroVector);
	TestYaw(*this, TEXT("The aim flag turns the idle body to the camera"), Character->GetActorRotation().Yaw, 180.0f);
	TestTrue(TEXT("The aim flag turns the body no faster than the rotation rate"), MaxTurn <= MaxTurnPerMove);

	// The aim flag buys no speed: an oversized aimed request is held to walk speed forward and to the
	// backpedal speed backward, although the body faces the camera either way.
	const FVector OversizedForwardAccel = FRotator(0.0f, 180.0f, 0.0f).Vector() * 1000000.0f;
	const float PeakAimedForwardSpeed = RunAuthorityMoves(60, AimFlag, OversizedForwardAccel);
	TestTrue(TEXT("Aimed forward request never exceeds walk speed"), PeakAimedForwardSpeed <= Movement->MaxWalkSpeed + SpeedTolerance);
	Movement->StopMovementImmediately();
	const float PeakAimedBackwardSpeed = RunAuthorityMoves(60, AimFlag, -OversizedForwardAccel);
	TestTrue(
		TEXT("Aimed backward request never exceeds the backpedal speed"),
		PeakAimedBackwardSpeed <= Movement->MaxWalkSpeed * Movement->BackpedalSpeedScale + SpeedTolerance);
	TestYaw(*this, TEXT("Aimed backward movement still faces the camera"), Character->GetActorRotation().Yaw, 180.0f);
	TestTrue(TEXT("Aimed authority stays grounded"), Movement->IsMovingOnGround());

	// A free (non-aimed) lateral takeoff, then the aim flag mid-air: rate-limited camera facing, never a tracking snap.
	const FVector RightAccel = FRotator(0.0f, 180.0f, 0.0f).RotateVector(FVector::RightVector) * Movement->GetMaxAcceleration();
	RunAuthorityMoves(1, FSavedMove_Character::FLAG_JumpPressed, RightAccel);
	TestTrue(TEXT("Free lateral jump takes off"), Movement->IsFalling());
	TestYaw(*this, TEXT("Free lateral takeoff faces travel"), Character->GetActorRotation().Yaw, -90.0f);
	MaxTurn = 0.0f;
	Controller->SetControlRotation(FRotator(0.0f, 45.0f, 0.0f));
	RunAuthorityMoves(5, AimFlag, RightAccel);
	TestTrue(TEXT("Still airborne"), Movement->IsFalling());
	TestTrue(TEXT("The aim flag after a free takeoff turns the airborne body no faster than the rotation rate"), MaxTurn <= MaxTurnPerMove);
	return true;
}
#endif
