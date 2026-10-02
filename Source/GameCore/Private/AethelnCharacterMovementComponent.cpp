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
	const FJumpTakeoff Takeoff = CalculateJumpTakeoff(
		Acceleration,
		GetMaxAcceleration(),
		GetSimulatedControlYaw(),
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
	return true;
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
	// Runs on a standalone authority pawn: valid in Development, but the engine's checkSlow
	// role/net-mode asserts in GetPredictionData_Client_Character would fire in a Debug build.
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
 * server copy fed only what the client's saved move carries (flags and rounded acceleration) through
 * MoveAutonomous. Neither has a remote connection; this isolates the shared simulation code.
 */
struct FAethelnMovementNetPredictionPair
{
	AAethelnPlayerCharacter* Client = nullptr;
	AAethelnPlayerCharacter* Server = nullptr;
	UAethelnCharacterMovementComponent* ClientMovement = nullptr;
	UAethelnCharacterMovementComponent* ServerMovement = nullptr;
	FVector ServerOffset = FVector::ZeroVector;
	float TimeStamp = 0.0f;

	FAethelnMovementNetPredictionPair(const AethelnMovementNetTests::FTestWorld& TestWorld, const FVector& Location)
	{
		Client = TestWorld.SpawnGroundedCharacter(Location);
		Server = TestWorld.SpawnGroundedCharacter(Location + FVector(500.0f, 0.0f, 0.0f));
		if (Client == nullptr || Server == nullptr)
		{
			return;
		}
		FActorSpawnParameters SpawnParameters;
		SpawnParameters.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
		APlayerController* PlayerController = TestWorld.World->SpawnActor<APlayerController>(
			APlayerController::StaticClass(), FVector::ZeroVector, FRotator::ZeroRotator, SpawnParameters);
		if (PlayerController == nullptr)
		{
			return;
		}
		// The client needs a controller for the POC input path; the server copy keeps control yaw zero without one.
		PlayerController->Possess(Client);
		ClientMovement = AethelnMovementNetTests::GetMovement(Client);
		ServerMovement = AethelnMovementNetTests::GetMovement(Server);
		ServerOffset = Server->GetActorLocation() - Client->GetActorLocation();
	}

	bool IsValid() const
	{
		return ClientMovement != nullptr && ServerMovement != nullptr && Client->GetController() != nullptr;
	}

	/** One frame of client input and prediction, then the matching server move. Returns true when the server accepts the client location. */
	bool Step(const FVector2D& MoveInput, bool bPressJump, bool bSprint)
	{
		Client->ReceiveSprintIntent(bSprint);
		Client->ReceiveMoveInput(MoveInput);
		if (bPressJump)
		{
			Client->ReceiveJumpStarted();
		}
		// The saved move reads these after the jump check, which never clears them.
		uint8 Flags = 0;
		if (Client->bPressedJump)
		{
			Flags |= FSavedMove_Character::FLAG_JumpPressed;
		}
		if (ClientMovement->bWantsToSprint)
		{
			Flags |= FSavedMove_Character::FLAG_Custom_0;
		}
		TimeStamp += AethelnMovementNetTests::MoveDeltaTime;
		ClientMovement->ControlledCharacterMove(ClientMovement->ConsumeInputVector(), AethelnMovementNetTests::MoveDeltaTime);
		ServerMovement->MoveAutonomous(
			TimeStamp,
			AethelnMovementNetTests::MoveDeltaTime,
			Flags,
			ClientMovement->RoundAcceleration(ClientMovement->Acceleration));
		const FVector ClientLocation = Client->GetActorLocation() + ServerOffset;
		FMovementBaseInterfaceData MovementBase;
		return !ServerMovement->ServerExceedsAllowablePositionError(
			TimeStamp, AethelnMovementNetTests::MoveDeltaTime, ClientMovement->Acceleration, ClientLocation, ClientLocation,
			&MovementBase, NAME_None, ClientMovement->PackNetworkMovementMode());
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
 */
struct FAethelnMovementNetJumpReplayScenario
{
	static bool Run(FAutomationTestBase& Test, int32 ReplayCount)
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

		const FVector ForwardAccel = RecordedControlRotation.Vector() * ReferenceMovement->GetMaxAcceleration();
		TimeStamp += MoveDeltaTime;
		ReferenceMovement->MoveAutonomous(
			TimeStamp, MoveDeltaTime, FSavedMove_Character::FLAG_JumpPressed | FSavedMove_Character::FLAG_Custom_0, ForwardAccel);
		Test.TestTrue(
			TEXT("First pass launches forward at sprint speed"),
			Horizontal(ReferenceMovement->Velocity).Equals(
				RecordedControlRotation.Vector() * ReferenceMovement->SprintSpeed, SpeedTolerance));

		const FVector ReplayStartLocation = Replayed->GetActorLocation();
		FNetworkPredictionData_Client_Character* ClientData = ReplayedMovement->GetPredictionData_Client_Character();
		ReplayedMovement->bWantsToSprint = true;
		Replayed->Jump();
		FSavedMovePtr JumpMove = ClientData->AllocateNewMove();
		JumpMove->SetMoveFor(Replayed, MoveDeltaTime, ForwardAccel, *ClientData);
		JumpMove->PostUpdate(Replayed, FSavedMove_Character::PostUpdate_Record);
		ReplayedController->SetControlRotation(RecordedControlRotation + FRotator(0.0f, 180.0f, 0.0f));
		for (int32 Replay = 0; Replay < ReplayCount; ++Replay)
		{
			if (Replay > 0)
			{
				// Each correction replays from the server state, here the grounded pre-jump state.
				Replayed->SetActorLocation(ReplayStartLocation);
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
#endif
