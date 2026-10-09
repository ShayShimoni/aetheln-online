#include "AethelnCharacterMovementComponent.h"

#if WITH_DEV_AUTOMATION_TESTS
#include "AethelnPlayerCharacter.h"
#include "Components/BoxComponent.h"
#include "Components/CapsuleComponent.h"
#include "Engine/CollisionProfile.h"
#include "Engine/Engine.h"
#include "Engine/GameInstance.h"
#include "Engine/LocalPlayer.h"
#include "Engine/World.h"
#include "GameFramework/PlayerController.h"
#include "GameFramework/WorldSettings.h"
#include "Misc/AutomationTest.h"
#include "Serialization/BitReader.h"
#include "Serialization/BitWriter.h"
#include "Serialization/ObjectAndNameAsStringProxyArchive.h"

namespace AethelnDodgeTests
{
	constexpr float StepSeconds = 1.0f / 30.0f;
	constexpr float PositionTolerance = 0.5f;

	struct FPacket
	{
		TArray<uint8> Bytes;
		int64 BitCount = 0;
		float NewTimeStamp = 0.0f;
		float OldTimeStamp = 0.0f;
		uint8 OldCompressedFlags = 0;
		bool bHasOld = false;
		bool bSerialized = false;
	};

	/** Fixture values only; this never grants or selects a production dodge. */
	struct FTestDodgeAuthority : IAethelnMovementActionAuthority
	{
		FAethelnDodgeMovementDefinition Definition;
		TArray<FAethelnDodgeStartRequest> Requests;
		bool bPredict = true;
		bool bAccept = true;
		virtual FAethelnDodgeMovementDefinition GetDodgeMovementDefinition() const override { return Definition; }
		virtual bool CanPredictDodge() const override { return bPredict; }
		virtual bool TryAuthorizeDodge(const FAethelnDodgeStartRequest& Request) override
		{
			Requests.Add(Request);
			return bAccept && Request.bMovementAllowsStart && Request.ContentVersion == Definition.ContentVersion;
		}
	};

	struct FResponsePacket
	{
		TArray<uint8> Bytes;
		int64 BitCount = 0;
	};

	/** Real CMC simulation/ack/replay, with delivery scripted instead of a net driver. */
	struct FLoopback
	{
		UWorld* World = nullptr;
		UGameInstance* GameInstance = nullptr;
		AAethelnPlayerCharacter* Client = nullptr;
		TOptional<ENetRole> ClientRoleBeforeOverride;
		AAethelnPlayerCharacter* Server = nullptr;
		APlayerController* ClientController = nullptr;
		APlayerController* ServerController = nullptr;
		UAethelnCharacterMovementComponent* ClientMovement = nullptr;
		UAethelnCharacterMovementComponent* ServerMovement = nullptr;
		TArray<FPacket> Packets;
		int32 CorrectionCount = 0;
		int32 ReplayedCorrectionCount = 0;
		bool bSerializationSucceeded = true;
		FTestDodgeAuthority ClientAuthority;
		FTestDodgeAuthority ServerAuthority;
		UBoxComponent* FloorBox = nullptr;
		AAethelnPlayerCharacter* Proxy = nullptr;
		TOptional<ENetRole> ProxyRoleBeforeOverride;
		FVector ObserverReceivedLocation = FVector::ZeroVector;
		FVector ObserverReceivedVelocity = FVector::ZeroVector;

		FLoopback()
		{
			if (GEngine == nullptr) { return; }
			World = UWorld::CreateWorld(EWorldType::Game, false);
			if (World == nullptr) { return; }
			FWorldContext& Context = GEngine->CreateNewWorldContext(EWorldType::Game);
			GameInstance = NewObject<UGameInstance>(GEngine);
			Context.OwningGameInstance = GameInstance;
			World->SetGameInstance(GameInstance);
			Context.SetCurrentWorld(World);
			GameInstance->Init();
			World->InitializeActorsForPlay(FURL());
			World->BeginPlay();
			AActor* Floor = World->SpawnActor<AActor>();
			UBoxComponent* Box = NewObject<UBoxComponent>(Floor);
			Box->SetBoxExtent(FVector(10000.0f, 10000.0f, 50.0f));
			Box->SetRelativeLocation(FVector(0.0f, 0.0f, -50.0f));
			Box->SetMobility(EComponentMobility::Static);
			Box->SetCollisionProfileName(UCollisionProfile::BlockAll_ProfileName);
			Floor->SetRootComponent(Box);
			Box->RegisterComponent();
			FloorBox = Box;
			FActorSpawnParameters Spawn;
			Spawn.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
			Client = World->SpawnActor<AAethelnPlayerCharacter>(AAethelnPlayerCharacter::StaticClass(), FVector(0.0f, 0.0f, 100.0f), FRotator::ZeroRotator, Spawn);
			Server = World->SpawnActor<AAethelnPlayerCharacter>(AAethelnPlayerCharacter::StaticClass(), FVector(0.0f, 0.0f, 100.0f), FRotator::ZeroRotator, Spawn);
			ClientController = World->SpawnActor<APlayerController>();
			ServerController = World->SpawnActor<APlayerController>();
			if (Client == nullptr || Server == nullptr || ClientController == nullptr || ServerController == nullptr) { return; }
			ClientController->Possess(Client);
			ServerController->Possess(Server);
			ClientController->Player = NewObject<ULocalPlayer>(GEngine);
			ClientController->AcknowledgedPawn = Client;
			ServerController->AcknowledgedPawn = Server;
			Client->SetReplicates(true);
			Server->SetReplicates(true);
			Server->SetAutonomousProxy(true);
			ClientRoleBeforeOverride = Client->GetLocalRole();
			Client->SetRole(ROLE_AutonomousProxy);
			ClientMovement = Client->GetCharacterMovement<UAethelnCharacterMovementComponent>();
			ServerMovement = Server->GetCharacterMovement<UAethelnCharacterMovementComponent>();
			for (AAethelnPlayerCharacter* Character : {Client, Server})
			{
				Character->GetCapsuleComponent()->SetCollisionResponseToChannel(ECC_Pawn, ECR_Ignore);
				Character->GetCharacterMovement()->SetMovementMode(MOVE_Walking);
			}
			ClientMovement->TestMoveCapture = [this](const FSavedMove_Character* New, const FSavedMove_Character* Pending, const FSavedMove_Character* Old)
			{
				FCharacterNetworkMoveDataContainer& Data = ClientMovement->TestGetNetworkMoveDataContainer();
				Data.ClientFillNetworkMoveData(New, Pending, Old);
				FPacket Packet;
				Packet.NewTimeStamp = New->TimeStamp;
				Packet.bHasOld = Old != nullptr;
				Packet.OldTimeStamp = Old != nullptr ? Old->TimeStamp : 0.0f;
				Packet.OldCompressedFlags = Old != nullptr ? Old->GetCompressedFlags() : 0;
				FBitWriter Writer(0, true);
				// The one-world archive resolves real floor/base references by object path.
				// All CMC fields still use their actual packed Serialize implementations.
				FObjectAndNameAsStringProxyArchive Archive(Writer, false);
				Packet.bSerialized = Data.Serialize(*ClientMovement, Archive, nullptr) && !Writer.IsError();
				Packet.BitCount = Writer.GetNumBits();
				Packet.Bytes.Append(Writer.GetData(), static_cast<int32>(Writer.GetNumBytes()));
				bSerializationSucceeded &= Packet.bSerialized;
				Packets.Add(MoveTemp(Packet));
			};
		}

		~FLoopback()
		{
			if (ClientMovement != nullptr) { ClientMovement->TestDodgeAuthority = nullptr; }
			if (ServerMovement != nullptr) { ServerMovement->TestDodgeAuthority = nullptr; }
			if (ClientMovement != nullptr) { ClientMovement->TestDodgeGroundDepartureCapture = nullptr; }
			if (ServerMovement != nullptr) { ServerMovement->TestDodgeGroundDepartureCapture = nullptr; }
			if (ClientMovement != nullptr) { ClientMovement->TestMoveCapture = nullptr; }
			// Restore the spawned actors' roles before their authority-owned controller teardown.
			if (Client != nullptr && ClientRoleBeforeOverride.IsSet()) { Client->SetRole(ClientRoleBeforeOverride.GetValue()); }
			if (Proxy != nullptr && ProxyRoleBeforeOverride.IsSet()) { Proxy->SetRole(ProxyRoleBeforeOverride.GetValue()); }
			if (World != nullptr) { World->EndPlay(EEndPlayReason::Quit); }
			if (GameInstance != nullptr) { GameInstance->Shutdown(); }
			if (World != nullptr)
			{
				World->DestroyWorld(false);
				if (GEngine != nullptr) { GEngine->DestroyWorldContext(World); }
			}
		}

		bool IsValid() const
		{
			return ClientMovement != nullptr && ServerMovement != nullptr
				&& Client->GetLocalRole() == ROLE_AutonomousProxy
				&& Server->GetLocalRole() == ROLE_Authority && Server->GetRemoteRole() == ROLE_AutonomousProxy
				&& ClientController->AcknowledgedPawn == Client && ClientController->Player != nullptr
				&& ServerController->AcknowledgedPawn == Server;
		}

		void EnableDodge(bool bAccept = true, float Distance = 120.0f, float Duration = 0.21f)
		{
			ClientAuthority.Definition.Distance = Distance;
			ClientAuthority.Definition.MoveDuration = Duration;
			ClientAuthority.Definition.ContentVersion = 7;
			ServerAuthority.Definition = ClientAuthority.Definition;
			ServerAuthority.bAccept = bAccept;
			ClientMovement->TestDodgeAuthority = &ClientAuthority;
			ServerMovement->TestDodgeAuthority = &ServerAuthority;
		}

		bool Warm()
		{
			Predict();
			return Packets.Num() > 0 && Deliver(Packets.Last());
		}

		void Predict(const FVector& Acceleration = FVector::ZeroVector, float Delta = StepSeconds)
		{
			World->Tick(LEVELTICK_TimeOnly, Delta);
			// Request a packet each test step without changing the global combining CVar.
			ClientMovement->GetPredictionData_Client_Character()->ClientUpdateRealTime = World->GetRealTimeSeconds() - 1.0f;
			ClientMovement->TestReplicateMove(Delta, Acceleration);
		}

		bool Deliver(const FPacket& Packet, bool bRespond = true)
		{
			FBitReader Reader(const_cast<uint8*>(Packet.Bytes.GetData()), Packet.BitCount);
			FObjectAndNameAsStringProxyArchive Archive(Reader, false);
			FCharacterNetworkMoveDataContainer& Data = ServerMovement->TestGetNetworkMoveDataContainer();
			const bool bDecoded = Data.Serialize(*ServerMovement, Archive, nullptr) && !Reader.IsError();
			bSerializationSucceeded &= bDecoded;
			if (!bDecoded) { return false; }
			// Bypass only outbound response pacing, not move validation or simulation.
			ServerMovement->GetPredictionData_Server_Character()->LastUpdateTime = World->GetTimeSeconds();
			ServerMovement->ServerMove_HandleMoveData(Data);
			return !bRespond || Respond();
		}

		bool CaptureResponse(FResponsePacket& Packet, bool bUnresolvedRelativeBase = false)
		{
			FClientAdjustment& Adjustment = ServerMovement->GetPredictionData_Server_Character()->PendingAdjustment;
			if (Adjustment.TimeStamp <= 0.0f) { return false; }
			FCharacterMoveResponseDataContainer& Out = ServerMovement->TestGetMoveResponseDataContainer();
			Out.ServerFillResponseData(*ServerMovement, Adjustment);
			if (bUnresolvedRelativeBase)
			{
				Out.bHasBase = true;
				Out.ClientAdjustment.bBaseRelativePosition = true;
				Out.ClientAdjustment.NewMovementBasePhysicsObjectOwner = nullptr;
			}
			CorrectionCount += Out.IsCorrection() ? 1 : 0;
			FBitWriter Writer(0, true);
			FObjectAndNameAsStringProxyArchive Save(Writer, false);
			const bool bEncoded = Out.Serialize(*ServerMovement, Save, nullptr) && !Writer.IsError();
			bSerializationSucceeded &= bEncoded;
			if (!bEncoded) { return false; }
			Packet.Bytes.Append(Writer.GetData(), static_cast<int32>(Writer.GetNumBytes()));
			Packet.BitCount = Writer.GetNumBits();
			return true;
		}

		bool DeliverResponse(const FResponsePacket& Packet)
		{
			FBitReader Reader(const_cast<uint8*>(Packet.Bytes.GetData()), Packet.BitCount);
			FObjectAndNameAsStringProxyArchive Load(Reader, false);
			FCharacterMoveResponseDataContainer& In = ClientMovement->TestGetMoveResponseDataContainer();
			const bool bDecoded = In.Serialize(*ClientMovement, Load, nullptr) && !Reader.IsError();
			bSerializationSucceeded &= bDecoded;
			if (!bDecoded) { return false; }
			ClientMovement->ClientHandleMoveResponse(In);
			ReplayedCorrectionCount += ClientMovement->TestReplayCorrection() ? 1 : 0;
			return true;
		}

		bool Respond()
		{
			FResponsePacket Packet;
			if (!CaptureResponse(Packet) || !DeliverResponse(Packet)) { return false; }
			ServerMovement->GetPredictionData_Server_Character()->PendingAdjustment.TimeStamp = 0.0f;
			return true;
		}

		void AddWall(float X)
		{
			AActor* Wall = World->SpawnActor<AActor>();
			UBoxComponent* Box = NewObject<UBoxComponent>(Wall);
			Box->SetBoxExtent(FVector(10.0f, 1000.0f, 200.0f));
			Box->SetWorldLocation(FVector(X, 0.0f, 100.0f));
			Box->SetMobility(EComponentMobility::Static);
			Box->SetCollisionProfileName(UCollisionProfile::BlockAll_ProfileName);
			Wall->SetRootComponent(Box);
			Box->RegisterComponent();
		}

		void AddStep(bool bSlope)
		{
			AActor* Step = World->SpawnActor<AActor>();
			UBoxComponent* Box = NewObject<UBoxComponent>(Step);
			Box->SetBoxExtent(FVector(25.0f, 1000.0f, 10.0f));
			Box->SetWorldLocation(FVector(70.0f, 0.0f, 10.0f));
			if (bSlope) { Box->SetWorldRotation(FRotator(10.0f, 0.0f, 0.0f)); }
			Box->SetMobility(EComponentMobility::Static);
			Box->SetCollisionProfileName(UCollisionProfile::BlockAll_ProfileName);
			Step->SetRootComponent(Box);
			Box->RegisterComponent();
		}

		bool CreateObserver()
		{
			if (Proxy == nullptr)
			{
				FActorSpawnParameters Spawn;
				Spawn.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
				Proxy = World->SpawnActor<AAethelnPlayerCharacter>(AAethelnPlayerCharacter::StaticClass(), Server->GetActorLocation() - FVector(500.0f, 0.0f, 0.0f), FRotator::ZeroRotator, Spawn);
				if (Proxy == nullptr) { return false; }
				ProxyRoleBeforeOverride = Proxy->GetLocalRole();
				Proxy->SetRole(ROLE_SimulatedProxy);
				Proxy->GetCapsuleComponent()->SetCollisionResponseToChannel(ECC_Pawn, ECR_Ignore);
			}
			return Proxy->GetLocalRole() == ROLE_SimulatedProxy;
		}

		bool ObserveServer()
		{
			if (Proxy == nullptr) { return false; }
			Server->GatherCurrentMovement();
			Proxy->TestSetReplicatedMovementMode(ServerMovement->PackNetworkMovementMode());
			Proxy->SetReplicatedMovement(Server->GetReplicatedMovement());
			Proxy->OnRep_ReplicatedMovement();
			// Capture the effect before a simulated tick can move an old velocity by itself.
			ObserverReceivedLocation = Proxy->GetActorLocation();
			ObserverReceivedVelocity = Proxy->GetCharacterMovement()->Velocity;
			Proxy->GetCharacterMovement()->TickComponent(StepSeconds, LEVELTICK_All, nullptr);
			return Proxy->GetLocalRole() == ROLE_SimulatedProxy;
		}
	};
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnMovementLoopbackTransportTest,
	"Aetheln.Movement.Net.LoopbackTransport", EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementLoopbackTransportTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDodgeTests;
	FLoopback Pair;
	TestTrue(TEXT("Real client/server roles, players and acknowledged pawns"), Pair.IsValid());
	if (!Pair.IsValid()) { return false; }
	Pair.Predict();
	TestEqual(TEXT("Engine emits a packed move"), Pair.Packets.Num(), 1);
	if (Pair.Packets.Num() != 1) { return false; }
	TestTrue(TEXT("Packed move goes through the real received-move handler and response"), Pair.Deliver(Pair.Packets.Last()));
	TestEqual(TEXT("Positive control: exactly one received move simulated"), Pair.ServerMovement->TestReceivedMoveCount, 1);
	TestTrue(TEXT("Actual response acknowledges a saved move"), Pair.ClientMovement->GetPredictionData_Client_Character()->LastAckedMove.IsValid());
	const FPacket First = Pair.Packets.Last();
	Pair.Deliver(First, false);
	TestEqual(TEXT("Duplicate timestamp simulates nothing"), Pair.ServerMovement->TestReceivedMoveCount, 1);
	Pair.ServerController->AcknowledgedPawn = nullptr;
	Pair.Predict();
	Pair.Deliver(Pair.Packets.Last(), false);
	TestEqual(TEXT("Unacknowledged pawn consumes a timestamp but simulates nothing"), Pair.ServerMovement->TestReceivedMoveCount, 1);
	Pair.ServerController->AcknowledgedPawn = Pair.Server;
	Pair.Predict(FVector::ForwardVector * Pair.ClientMovement->GetMaxAcceleration());
	Pair.Deliver(Pair.Packets.Last());
	TestEqual(TEXT("Acknowledged pawn resumes actual simulation"), Pair.ServerMovement->TestReceivedMoveCount, 2);
	TestTrue(TEXT("All move and response packing succeeded"), Pair.bSerializationSucceeded);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnMovementLoopbackCorrectionTest,
	"Aetheln.Movement.Net.LoopbackCorrectionReplay", EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementLoopbackCorrectionTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDodgeTests;
	FLoopback Pair;
	TestTrue(TEXT("Loopback roles and acknowledgement are valid"), Pair.IsValid());
	if (!Pair.IsValid()) { return false; }
	Pair.Predict();
	if (Pair.Packets.Num() != 1 || !Pair.Deliver(Pair.Packets.Last()))
	{
		AddError(TEXT("Warm move must be captured, simulated and acknowledged"));
		return false;
	}
	const FVector Acceleration = FVector::ForwardVector * Pair.ClientMovement->GetMaxAcceleration();
	Pair.Predict(Acceleration);
	const FPacket Earlier = Pair.Packets.Last();
	Pair.Predict(Acceleration);
	const FPacket Later = Pair.Packets.Last();
	TestEqual(TEXT("Future moves really remain in the client saved list"), Pair.ClientMovement->GetPredictionData_Client_Character()->SavedMoves.Num(), 2);
	Pair.ServerMovement->GetPredictionData_Server_Character()->bForceClientUpdate = true;
	TestTrue(TEXT("Earlier received move creates and delivers a real forced correction"), Pair.Deliver(Earlier));
	TestEqual(TEXT("Engine correction is delivered exactly once"), Pair.CorrectionCount, 1);
	TestEqual(TEXT("Actual accepted correction replays the still-unacknowledged future move"), Pair.ReplayedCorrectionCount, 1);
	TestEqual(TEXT("Correction acknowledges only the earlier move"), Pair.ClientMovement->GetPredictionData_Client_Character()->SavedMoves.Num(), 1);
	TestTrue(TEXT("Later immutable packet is independently delivered"), Pair.Deliver(Later));
	TestEqual(TEXT("Positive control: warm, earlier and later moves actually simulate"), Pair.ServerMovement->TestReceivedMoveCount, 3);
	TestTrue(TEXT("Client converges after native correction and replay"), Pair.Client->GetActorLocation().Equals(Pair.Server->GetActorLocation(), PositionTolerance));
	TestTrue(TEXT("Corrected/replayed velocity matches authority"), Pair.ClientMovement->Velocity.Equals(Pair.ServerMovement->Velocity, PositionTolerance));
	TestFalse(TEXT("Server clears received data outside the delivery boundary"), Pair.ServerMovement->TestGetCurrentNetworkMoveData() != nullptr);
	TestTrue(TEXT("Both packed paths succeed"), Pair.bSerializationSucceeded);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnMovementLoopbackForcedUpdateTest,
	"Aetheln.Movement.Net.LoopbackForcedUpdate", EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementLoopbackForcedUpdateTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDodgeTests;
	FLoopback Pair;
	TestTrue(TEXT("Loopback roles and acknowledgement are valid"), Pair.IsValid());
	if (!Pair.IsValid()) { return false; }
	Pair.Predict();
	if (Pair.Packets.Num() != 1 || !Pair.Deliver(Pair.Packets.Last()))
	{
		AddError(TEXT("Warm move must be captured, simulated and acknowledged"));
		return false;
	}
	Pair.Predict();
	const FPacket Late = Pair.Packets.Last();
	FNetworkPredictionData_Server_Character* ServerData = Pair.ServerMovement->GetPredictionData_Server_Character();
	const float Before = ServerData->CurrentClientTimeStamp;
	TestTrue(TEXT("No received move data surrounds the forced update"), Pair.ServerMovement->TestGetCurrentNetworkMoveData() == nullptr);
	TestTrue(TEXT("Real authority remote-autonomous forced update runs"), Pair.ServerMovement->ForcePositionUpdate(StepSeconds));
	TestTrue(TEXT("Engine advances client timestamp across the forced interval"), ServerData->CurrentClientTimeStamp > Before && FMath::IsNearlyEqual(ServerData->CurrentClientTimeStamp, Late.NewTimeStamp));
	TestEqual(TEXT("Forced movement is not counted as a received move"), Pair.ServerMovement->TestReceivedMoveCount, 1);
	TestTrue(TEXT("ForcePositionUpdate leaves received move data null"), Pair.ServerMovement->TestGetCurrentNetworkMoveData() == nullptr);
	TestTrue(TEXT("Late captured move decodes and reaches the timestamp verifier"), Pair.Deliver(Late, false));
	TestEqual(TEXT("Late move inside forced interval is dropped without simulation"), Pair.ServerMovement->TestReceivedMoveCount, 1);
	Pair.Predict();
	TestTrue(TEXT("A newer move resumes processing and acknowledgement"), Pair.Deliver(Pair.Packets.Last()));
	TestEqual(TEXT("Positive control: exactly one newer received move simulates"), Pair.ServerMovement->TestReceivedMoveCount, 2);
	TestTrue(TEXT("All force-profile transport serialization succeeds"), Pair.bSerializationSucceeded);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnMovementLoopbackImportantResendTest,
	"Aetheln.Movement.Net.LoopbackImportantResend", EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementLoopbackImportantResendTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDodgeTests;
	FLoopback Pair;
	TestTrue(TEXT("Loopback roles and acknowledgement are valid"), Pair.IsValid());
	if (!Pair.IsValid()) { return false; }
	Pair.Predict();
	if (Pair.Packets.Num() != 1 || !Pair.Deliver(Pair.Packets.Last()))
	{
		AddError(TEXT("Warm move must create the real LastAckedMove"));
		return false;
	}
	Pair.ClientMovement->bWantsToSprint = true;
	Pair.ClientMovement->bWantsAimSteering = true;
	Pair.Predict();
	const FPacket Lost = Pair.Packets.Last();
	const FSavedMovePtr Important = Pair.ClientMovement->GetPredictionData_Client_Character()->SavedMoves.Last();
	TestTrue(TEXT("Existing flag change is natively important relative to the actual ack"), Important->IsImportantMove(Pair.ClientMovement->GetPredictionData_Client_Character()->LastAckedMove));
	Pair.ClientMovement->bWantsToSprint = false;
	Pair.ClientMovement->bWantsAimSteering = false;
	Pair.Predict();
	TestFalse(TEXT("Native selection excludes the last saved move"), Pair.Packets.Last().bHasOld);
	Pair.Predict();
	const FPacket Resend = Pair.Packets.Last();
	TestTrue(TEXT("Engine selects its oldest unacknowledged important move"), Resend.bHasOld);
	TestEqual(TEXT("Resent old move is the lost flag timestamp"), Resend.OldTimeStamp, Lost.NewTimeStamp);
	TestTrue(TEXT("Both existing custom flags remain in the old payload"), (Resend.OldCompressedFlags & (FSavedMove_Character::FLAG_Custom_0 | FSavedMove_Character::FLAG_Custom_1)) == (FSavedMove_Character::FLAG_Custom_0 | FSavedMove_Character::FLAG_Custom_1));
	TestTrue(TEXT("Immutable old/new packet goes through the real received handler"), Pair.Deliver(Resend));
	TestEqual(TEXT("Positive control: warm move plus old and new both simulate"), Pair.ServerMovement->TestReceivedMoveCount, 3);
	TestEqual(TEXT("Counter stores exactly the three actually simulated flags"), Pair.ServerMovement->TestReceivedMoveFlags.Num(), 3);
	if (Pair.ServerMovement->TestReceivedMoveFlags.Num() == 3)
	{
		TestEqual(TEXT("Received old move preserves its flags through serialization"), Pair.ServerMovement->TestReceivedMoveFlags[1], Resend.OldCompressedFlags);
		TestEqual(TEXT("Received new move clears the edge flags"), Pair.ServerMovement->TestReceivedMoveFlags[2], static_cast<uint8>(0));
	}
	TestEqual(TEXT("Ack of new packet clears the old saved move through engine logic"), Pair.ClientMovement->GetPredictionData_Client_Character()->SavedMoves.Num(), 0);
	TestTrue(TEXT("Resend path converges on server"), Pair.Client->GetActorLocation().Equals(Pair.Server->GetActorLocation(), PositionTolerance));
	TestTrue(TEXT("Old/new packet serialization succeeded"), Pair.bSerializationSucceeded);
	return true;
}
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDodgeFlagRoundTripTest,
	"Aetheln.Movement.Net.DodgeFlagRoundTrip", EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDodgeFlagRoundTripTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDodgeTests;
	FLoopback Pair;
	if (!Pair.IsValid()) { AddError(TEXT("Real loopback must initialize")); return false; }
	Pair.EnableDodge();
	Pair.Predict();
	TestTrue(TEXT("Warm move creates a real acknowledgement"), Pair.Deliver(Pair.Packets.Last()));
	TestTrue(TEXT("Local gate accepts the fixture definition"), Pair.ClientMovement->RequestDodge());
	Pair.ClientMovement->bWantsToSprint = true;
	Pair.ClientMovement->bWantsAimSteering = true;
	Pair.Predict(FVector::ForwardVector * Pair.ClientMovement->GetMaxAcceleration());
	const FSavedMovePtr Start = Pair.ClientMovement->GetPredictionData_Client_Character()->SavedMoves.Last();
	TestTrue(TEXT("Captured start carries Custom_2"), (Start->GetCompressedFlags() & FSavedMove_Character::FLAG_Custom_2) != 0);
	TestTrue(TEXT("Start is important relative to the actual acknowledgement"), Start->IsImportantMove(Pair.ClientMovement->GetPredictionData_Client_Character()->LastAckedMove));
	Pair.ClientMovement->bWantsToSprint = false;
	Pair.ClientMovement->bWantsAimSteering = false;
	Pair.Predict();
	TestEqual(TEXT("Next captured move clears Custom_2"), static_cast<uint8>(Pair.ClientMovement->GetPredictionData_Client_Character()->SavedMoves.Last()->GetCompressedFlags() & FSavedMove_Character::FLAG_Custom_2), static_cast<uint8>(0));
	TestFalse(TEXT("Start cannot combine with its neighbor"), Start->CanCombineWith(Pair.ClientMovement->GetPredictionData_Client_Character()->SavedMoves.Last(), Pair.Client, 1.0f));
	Pair.Predict();
	TestTrue(TEXT("Native old-important selection resends the start"), Pair.Packets.Last().bHasOld);
	TestTrue(TEXT("Real server restores serialized start and version"), Pair.Deliver(Pair.Packets.Last()));
	TestEqual(TEXT("Received start authorizes exactly once"), Pair.ServerAuthority.Requests.Num(), 1);
	if (Pair.ServerAuthority.Requests.Num() != 1 || Pair.ServerMovement->TestReceivedMoveFlags.Num() != 3) { return false; }
	TestEqual(TEXT("Immutable old payload retains fixture content version"), Pair.ServerAuthority.Requests[0].ContentVersion, Pair.ServerAuthority.Definition.ContentVersion);
	TestEqual(TEXT("Warm, resent old and new are genuinely simulated"), Pair.ServerMovement->TestReceivedMoveCount, 3);
	TestEqual(TEXT("Old payload preserves sprint, aim and dodge together"), static_cast<uint8>(Pair.ServerMovement->TestReceivedMoveFlags[1] & (FSavedMove_Character::FLAG_Custom_0 | FSavedMove_Character::FLAG_Custom_1 | FSavedMove_Character::FLAG_Custom_2)), static_cast<uint8>(FSavedMove_Character::FLAG_Custom_0 | FSavedMove_Character::FLAG_Custom_1 | FSavedMove_Character::FLAG_Custom_2));
	FLoopback Consecutive;
	if (!Consecutive.IsValid()) { return false; }
	Consecutive.EnableDodge(); Consecutive.Warm();
	Consecutive.ClientMovement->bWantsToSprint = true;
	Consecutive.ClientMovement->bWantsAimSteering = true;
	Consecutive.Client->Jump();
	Consecutive.ClientMovement->TestSetDodgeIntent(7); Consecutive.Predict();
	const FSavedMovePtr First = Consecutive.ClientMovement->GetPredictionData_Client_Character()->SavedMoves.Last();
	Consecutive.Client->StopJumping();
	Consecutive.ClientMovement->TestSetDodgeIntent(8); Consecutive.Predict();
	const FSavedMovePtr Second = Consecutive.ClientMovement->GetPredictionData_Client_Character()->SavedMoves.Last();
	TestFalse(TEXT("Consecutive identical flagged starts still never combine"), First->CanCombineWith(Second, Consecutive.Client, 1.0f));
	TestTrue(TEXT("Second identical start remains explicitly important"), Second->IsImportantMove(First));
	// Exercise all three persistent payload slots through the actual container serializer.
	FCharacterNetworkMoveDataContainer& Out = Consecutive.ClientMovement->TestGetNetworkMoveDataContainer();
	Out.ClientFillNetworkMoveData(Second.Get(), First.Get(), First.Get());
	FBitWriter Writer(0, true); FObjectAndNameAsStringProxyArchive Save(Writer, false);
	TestTrue(TEXT("New/pending/old custom payload serializes"), Out.Serialize(*Consecutive.ClientMovement, Save, nullptr) && !Writer.IsError());
	FBitReader Reader(Writer.GetData(), Writer.GetNumBits()); FObjectAndNameAsStringProxyArchive Load(Reader, false);
	FCharacterNetworkMoveDataContainer& In = Consecutive.ServerMovement->TestGetNetworkMoveDataContainer();
	TestTrue(TEXT("New/pending/old custom payload decodes"), In.Serialize(*Consecutive.ServerMovement, Load, nullptr) && !Reader.IsError());
	TestTrue(TEXT("Both optional slots survived packing"), In.bHasPendingMove && In.bHasOldMove);
	TestEqual(TEXT("New slot retains its flags"), In.GetNewMoveData()->CompressedMoveFlags, Second->GetCompressedFlags());
	TestEqual(TEXT("Pending slot retains its flags"), In.GetPendingMoveData()->CompressedMoveFlags, First->GetCompressedFlags());
	TestEqual(TEXT("Old slot retains its flags"), In.GetOldMoveData()->CompressedMoveFlags, First->GetCompressedFlags());
	TestTrue(TEXT("Saved accepted displacement preserves the original jump input bit"), (First->GetCompressedFlags() & FSavedMove_Character::FLAG_JumpPressed) != 0);
	TestEqual(TEXT("New slot retains its independent version"), Consecutive.ServerMovement->TestGetDodgeMoveContentVersion(*In.GetNewMoveData()), 8u);
	TestEqual(TEXT("Pending slot retains version"), Consecutive.ServerMovement->TestGetDodgeMoveContentVersion(*In.GetPendingMoveData()), 7u);
	TestEqual(TEXT("Old slot retains version"), Consecutive.ServerMovement->TestGetDodgeMoveContentVersion(*In.GetOldMoveData()), 7u);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDodgeDisplacementParityTest,
	"Aetheln.Movement.Net.DodgeDisplacementParity", EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDodgeDisplacementParityTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDodgeTests;
	for (int32 Mode = 0; Mode < 4; ++Mode)
	for (const FVector& Input : {FVector::ForwardVector, FVector::RightVector, FVector(1.0f, 1.0f, 0.0f).GetSafeNormal(), -FVector::ForwardVector, FVector::ZeroVector})
	{
		FLoopback Pair;
		if (!Pair.IsValid()) { return false; }
		Pair.EnableDodge();
		TestTrue(TEXT("Warm floor/ack positive control"), Pair.Warm());
		TestTrue(TEXT("Observer exists before the start"), Pair.CreateObserver());
		if (Pair.Proxy == nullptr) { return false; }
		const FVector UnupdatedObserverLocation = Pair.Proxy->GetActorLocation();
		TestFalse(TEXT("Without replication the preexisting observer differs from authority"), UnupdatedObserverLocation.Equals(Pair.Server->GetActorLocation(), PositionTolerance));
		TestTrue(TEXT("Initial actual OnRep receives the earlier stationary baseline"), Pair.ObserveServer());
		TestTrue(TEXT("OnRep itself moves the capsule before any simulated tick"), Pair.ObserverReceivedLocation.Equals(Pair.Server->GetActorLocation(), PositionTolerance));
		TestFalse(TEXT("Baseline receipt changes the preexisting observer location"), Pair.ObserverReceivedLocation.Equals(UnupdatedObserverLocation, PositionTolerance));
		Pair.ClientMovement->bWantsToSprint = (Mode & 1) != 0;
		Pair.ClientMovement->bWantsAimSteering = (Mode & 2) != 0;
		Pair.ClientController->SetControlRotation(FRotator(0.0f, 90.0f, 0.0f));
		Pair.ServerController->SetControlRotation(FRotator(0.0f, 90.0f, 0.0f));
		const FVector Start = Pair.Client->GetActorLocation();
		TestTrue(TEXT("Fixture start passes local gate"), Pair.ClientMovement->RequestDodge());
		for (int32 Move = 0; Move < 7; ++Move)
		{
			const FVector ChangingInput = Move == 0 ? Input : -Input;
			Pair.Predict(ChangingInput * Pair.ClientMovement->GetMaxAcceleration() * (Mode == 3 ? 0.25f : 1.0f));
			TestTrue(TEXT("Each actual move is delivered"), Pair.Deliver(Pair.Packets.Last()));
			TestTrue(TEXT("Preexisting observer consumes each actual movement update"), Pair.ObserveServer());
			TestTrue(TEXT("OnRep location receipt matches the current authority before tick"), Pair.ObserverReceivedLocation.Equals(Pair.Server->GetActorLocation(), PositionTolerance));
			TestTrue(TEXT("OnRep velocity receipt matches current authority"), Pair.ObserverReceivedVelocity.Equals(Pair.ServerMovement->Velocity, PositionTolerance));
			if (Move == 0)
			{
				TestTrue(TEXT("First active receipt has nonzero displacement velocity"), Pair.ObserverReceivedVelocity.Size2D() > PositionTolerance);
				TestFalse(TEXT("First active receipt advances the earlier observer baseline"), Pair.ObserverReceivedLocation.Equals(Start, PositionTolerance));
			}
		}
		const FVector Direction = Input.IsNearlyZero() ? -FVector::RightVector : Input;
		TestTrue(TEXT("Authored distance uses fixed input or opposite camera direction"), (Pair.Client->GetActorLocation() - Start).Equals(Direction * Pair.ClientAuthority.Definition.Distance, PositionTolerance));
		TestTrue(TEXT("Authority path equals prediction"), Pair.Client->GetActorLocation().Equals(Pair.Server->GetActorLocation(), PositionTolerance));
		TestEqual(TEXT("Positive delivery control including warm"), Pair.ServerMovement->TestReceivedMoveCount, 8);
		TestEqual(TEXT("Only one start authorizes"), Pair.ServerAuthority.Requests.Num(), 1);
		TestFalse(TEXT("Fractional final step ends displacement"), Pair.ClientMovement->GetDodgeState().bInProgress);
		TestTrue(TEXT("Preexisting observer endpoint converges through OnRep and simulated tick"), Pair.Proxy->GetActorLocation().Equals(Pair.Server->GetActorLocation(), PositionTolerance));
	}
	for (const TArray<float>& Partition : {TArray<float>{0.07f, 0.07f, 0.10f}, TArray<float>{0.05f, 0.05f, 0.05f, 0.09f}})
	{
		FLoopback Pair;
		if (!Pair.IsValid()) { return false; }
		Pair.EnableDodge(); Pair.Warm();
		const FVector Start = Pair.Client->GetActorLocation();
		Pair.ClientMovement->RequestDodge();
		for (float Delta : Partition) { Pair.Predict(FVector::ForwardVector * Pair.ClientMovement->GetMaxAcceleration(), Delta); TestTrue(TEXT("Partitioned real delivery"), Pair.Deliver(Pair.Packets.Last())); }
		TestTrue(TEXT("Different partitions cover only remaining terminal interval"), FMath::IsNearlyEqual(static_cast<float>(Pair.Client->GetActorLocation().X - Start.X), Pair.ClientAuthority.Definition.Distance, PositionTolerance));
		TestTrue(TEXT("Partitioned authority converges"), Pair.Client->GetActorLocation().Equals(Pair.Server->GetActorLocation(), PositionTolerance));
		TestEqual(TEXT("All partitioned moves simulate"), Pair.ServerMovement->TestReceivedMoveCount, Partition.Num() + 1);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDodgeCorrectionReplayTest,
	"Aetheln.Movement.Net.DodgeCorrectionReplay", EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDodgeCorrectionReplayTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDodgeTests;
	FLoopback Pair;
	if (!Pair.IsValid()) { return false; }
	Pair.EnableDodge();
	Pair.Predict(); Pair.Deliver(Pair.Packets.Last());
	Pair.ClientMovement->RequestDodge();
	Pair.Predict(); const FPacket Start = Pair.Packets.Last();
	Pair.Predict(); const FPacket Future = Pair.Packets.Last();
	Pair.ClientController->SetControlRotation(FRotator(0.0f, 135.0f, 0.0f));
	Pair.ServerMovement->GetPredictionData_Server_Character()->bForceClientUpdate = true;
	TestTrue(TEXT("Start creates an actual pending correction"), Pair.Deliver(Start, false));
	const FAethelnDodgeMovementState AtAdjustment = Pair.ServerMovement->GetDodgeState();
	const float AdjustmentTime = Pair.ServerMovement->GetPredictionData_Server_Character()->PendingAdjustment.TimeStamp;
	TestTrue(TEXT("Forced update advances live state after pending adjustment"), Pair.ServerMovement->ForcePositionUpdate(StepSeconds));
	TestTrue(TEXT("Live elapsed advanced"), Pair.ServerMovement->GetDodgeState().Elapsed > AtAdjustment.Elapsed);
	TestEqual(TEXT("Pending timestamp remains the original positional snapshot"), Pair.ServerMovement->GetPredictionData_Server_Character()->PendingAdjustment.TimeStamp, AdjustmentTime);
	FResponsePacket Unresolved;
	TestTrue(TEXT("Malformed-base correction still packs the real custom snapshot"), Pair.CaptureResponse(Unresolved, true));
	const float BeforeUnresolved = Pair.ClientMovement->GetDodgeState().Elapsed;
	AddExpectedMessagePlain(TEXT("ClientAdjustPosition_Implementation could not resolve the new relative movement base actor"), ELogVerbosity::Warning, EAutomationExpectedMessageFlags::Contains, 1);
	TestTrue(TEXT("Unresolved relative-base response reaches actual engine rejection"), Pair.DeliverResponse(Unresolved));
	TestEqual(TEXT("Rejected base correction never restores dodge state"), Pair.ClientMovement->GetDodgeState().Elapsed, BeforeUnresolved);
	FResponsePacket Early;
	TestTrue(TEXT("Pending-bound real response is captured after live advancement"), Pair.CaptureResponse(Early));
	TestTrue(TEXT("Accepted real correction restores and replays dodge"), Pair.DeliverResponse(Early));
	Pair.ServerMovement->GetPredictionData_Server_Character()->PendingAdjustment.TimeStamp = 0.0f;
	TestTrue(TEXT("Replayed elapsed equals advanced authority, not later live snapshot plus replay"), FMath::IsNearlyEqual(Pair.ClientMovement->GetDodgeState().Elapsed, Pair.ServerMovement->GetDodgeState().Elapsed));
	TestEqual(TEXT("Definition version survives immutable response"), Pair.ClientMovement->GetDodgeState().ContentVersion, Pair.ServerAuthority.Definition.ContentVersion);
	TestEqual(TEXT("Distance survives immutable response"), Pair.ClientMovement->GetDodgeState().Distance, Pair.ServerAuthority.Definition.Distance);
	TestEqual(TEXT("Duration survives immutable response"), Pair.ClientMovement->GetDodgeState().MoveDuration, Pair.ServerAuthority.Definition.MoveDuration);
	TestTrue(TEXT("Future packet inside forced interval is genuinely dropped"), Pair.Deliver(Future, false));
	TestEqual(TEXT("Forced interval and late packet do not invent received simulation"), Pair.ServerMovement->TestReceivedMoveCount, 2);
	Pair.Predict(); TestTrue(TEXT("Newer received move converges after changed live yaw"), Pair.Deliver(Pair.Packets.Last()));
	TestTrue(TEXT("Direction survives correction rather than live yaw"), Pair.ClientMovement->GetDodgeState().Direction.Equals(-FVector::ForwardVector));
	TestTrue(TEXT("Replayed endpoint converges"), Pair.Client->GetActorLocation().Equals(Pair.Server->GetActorLocation(), PositionTolerance));
	TestEqual(TEXT("Start is not reauthorized by replay"), Pair.ServerAuthority.Requests.Num(), 1);
	const FAethelnDodgeMovementState BeforeDuplicate = Pair.ClientMovement->GetDodgeState();
	TestTrue(TEXT("Duplicate older response decodes but engine ignores its acknowledged timestamp"), Pair.DeliverResponse(Early));
	TestEqual(TEXT("Duplicate accepted-old response cannot reset elapsed"), Pair.ClientMovement->GetDodgeState().Elapsed, BeforeDuplicate.Elapsed);
	Pair.Predict(); const FPacket Next = Pair.Packets.Last();
	Pair.Predict(); const FPacket NextFuture = Pair.Packets.Last();
	Pair.ServerMovement->GetPredictionData_Server_Character()->bForceClientUpdate = true;
	TestTrue(TEXT("Second actual pending correction"), Pair.Deliver(Next, false));
	FResponsePacket Newer;
	TestTrue(TEXT("Second immutable correction capture"), Pair.CaptureResponse(Newer));
	TestTrue(TEXT("Second correction invokes real replay"), Pair.DeliverResponse(Newer));
	Pair.ServerMovement->GetPredictionData_Server_Character()->PendingAdjustment.TimeStamp = 0.0f;
	const float BeforeStale = Pair.ClientMovement->GetDodgeState().Elapsed;
	TestTrue(TEXT("Delayed stale response follows a newer accepted correction"), Pair.DeliverResponse(Early));
	TestEqual(TEXT("Delayed stale correction leaves current state untouched"), Pair.ClientMovement->GetDodgeState().Elapsed, BeforeStale);
	TestTrue(TEXT("Future movement after repeated replay converges"), Pair.Deliver(NextFuture));
	TestTrue(TEXT("Repeated correction endpoint parity"), Pair.Client->GetActorLocation().Equals(Pair.Server->GetActorLocation(), PositionTolerance));
	TestEqual(TEXT("Warm plus four received nonforced moves really simulated"), Pair.ServerMovement->TestReceivedMoveCount, 5);
	TestEqual(TEXT("Both accepted corrections actually replayed future saved moves"), Pair.ReplayedCorrectionCount, 2);
	FLoopback ReplayStart;
	if (!ReplayStart.IsValid()) { return false; }
	ReplayStart.EnableDodge();
	ReplayStart.Predict();
	ReplayStart.ServerMovement->GetPredictionData_Server_Character()->bForceClientUpdate = true;
	TestTrue(TEXT("Correction preceding the start is genuinely created"), ReplayStart.Deliver(ReplayStart.Packets.Last(), false));
	FResponsePacket BeforeStart;
	TestTrue(TEXT("Pre-start correction is immutable"), ReplayStart.CaptureResponse(BeforeStart));
	ReplayStart.ClientMovement->RequestDodge(); ReplayStart.Predict();
	const FPacket NeutralStart = ReplayStart.Packets.Last();
	ReplayStart.ClientController->SetControlRotation(FRotator(0.0f, 135.0f, 0.0f));
	TestTrue(TEXT("Pre-start correction replays the unacknowledged flagged neutral move"), ReplayStart.DeliverResponse(BeforeStart));
	TestTrue(TEXT("Replayed start derives neutral direction from its saved yaw"), ReplayStart.ClientMovement->GetDodgeState().Direction.Equals(-FVector::ForwardVector));
	ReplayStart.ServerMovement->GetPredictionData_Server_Character()->PendingAdjustment.TimeStamp = 0.0f;
	TestTrue(TEXT("Real flagged start then reaches authority"), ReplayStart.Deliver(NeutralStart));
	TestEqual(TEXT("Replay never asks server authority before receipt"), ReplayStart.ServerAuthority.Requests.Num(), 1);
	TestTrue(TEXT("Start replay and server derive the same path"), ReplayStart.Client->GetActorLocation().Equals(ReplayStart.Server->GetActorLocation(), PositionTolerance));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDodgeRefusedRollsBackTest,
	"Aetheln.Movement.Net.DodgeRefusedRollsBack", EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDodgeRefusedRollsBackTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDodgeTests;
	for (bool bWall : {false, true})
	{
		FLoopback Pair;
		if (!Pair.IsValid()) { return false; }
		Pair.EnableDodge(false); Pair.Warm();
		if (bWall) { Pair.AddWall(Pair.Client->GetCapsuleComponent()->GetScaledCapsuleRadius() + 10.0f); }
		const FVector Initial = Pair.Client->GetActorLocation();
		Pair.ClientMovement->RequestDodge();
		Pair.Predict(FVector::ForwardVector * Pair.ClientMovement->GetMaxAcceleration()); const FPacket Start = Pair.Packets.Last();
		TestTrue(TEXT("Prediction really started before refusal"), Pair.ClientMovement->GetDodgeState().bInProgress);
		if (!bWall) { TestTrue(TEXT("Prediction really displaced before refusal"), Pair.Client->GetActorLocation().X > Initial.X + PositionTolerance); }
		else { TestTrue(TEXT("Wall case has equal positions despite active prediction"), Pair.Client->GetActorLocation().Equals(Pair.Server->GetActorLocation(), PositionTolerance)); }
		Pair.Predict();
		TestTrue(TEXT("Future move really remains saved before correction"), Pair.ClientMovement->GetPredictionData_Client_Character()->SavedMoves.Num() >= 2);
		TestTrue(TEXT("Refusal produces a real acknowledgement/correction"), Pair.Deliver(Start));
		TestFalse(TEXT("Authoritative refusal removes predicted displacement"), Pair.ClientMovement->GetDodgeState().bInProgress);
		TestEqual(TEXT("Exactly one correction for refused start, including equal-position state"), Pair.CorrectionCount, 1);
		TestEqual(TEXT("Future replay cannot recommit the acknowledged start"), Pair.ServerAuthority.Requests.Num(), 1);
		TestEqual(TEXT("Refusal acknowledges only the delivered start"), Pair.ClientMovement->GetPredictionData_Client_Character()->LastAckedMove->TimeStamp, Start.NewTimeStamp);
		TestEqual(TEXT("Ordinary future move remains saved after refusal replay"), Pair.ClientMovement->GetPredictionData_Client_Character()->SavedMoves.Num(), 1);
		// Replay advances the owner beyond the server's acknowledged start. Compare
		// positions only after the existing fresh successor brings authority up to it.
		Pair.Predict(); TestTrue(TEXT("Fresh next packet remains converged"), Pair.Deliver(Pair.Packets.Last()));
		TestTrue(*FString::Printf(TEXT("Refused path converges (wall=%d client=%s server=%s)"), bWall, *Pair.Client->GetActorLocation().ToString(), *Pair.Server->GetActorLocation().ToString()), Pair.Client->GetActorLocation().Equals(Pair.Server->GetActorLocation(), PositionTolerance));
		TestEqual(TEXT("Fresh nonflagged move does not create a second rejection correction"), Pair.CorrectionCount, 1);
		TestEqual(TEXT("Positive count: warm, refused start, fresh successor"), Pair.ServerMovement->TestReceivedMoveCount, 3);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDodgeDeliveryConditionsTest,
	"Aetheln.Movement.Net.DodgeDeliveryConditions", EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDodgeDeliveryConditionsTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDodgeTests;
	for (bool bDelay : {false, true})
	{
		FLoopback Pair;
		if (!Pair.IsValid()) { return false; }
		Pair.EnableDodge(); Pair.Warm();
		Pair.ClientMovement->RequestDodge(); Pair.Predict(); const FPacket Start = Pair.Packets.Last();
		if (bDelay) { Pair.World->Tick(LEVELTICK_TimeOnly, 0.1f); }
		TestEqual(TEXT("Undelivered queue has no simulated start"), Pair.ServerMovement->TestReceivedMoveCount, 1);
		TestTrue(TEXT("Normal/delayed immutable start is processed"), Pair.Deliver(Start));
		Pair.Deliver(Start, false);
		TestEqual(TEXT("Duplicate packet never authorizes twice"), Pair.ServerAuthority.Requests.Num(), 1);
		TestEqual(TEXT("Duplicate packet never simulates twice"), Pair.ServerMovement->TestReceivedMoveCount, 2);
		Pair.Predict(); Pair.Deliver(Pair.Packets.Last()); Pair.Deliver(Start, false);
		TestEqual(TEXT("Older reordered move is dropped after newer receipt"), Pair.ServerMovement->TestReceivedMoveCount, 3);
		TestEqual(TEXT("Older reorder never authorizes twice"), Pair.ServerAuthority.Requests.Num(), 1);
	}
	{
		FLoopback Pair;
		if (!Pair.IsValid()) { return false; }
		Pair.EnableDodge(); Pair.Warm(); Pair.ClientMovement->RequestDodge(); Pair.Predict();
		const FPacket Lost = Pair.Packets.Last();
		Pair.Predict(); Pair.Predict();
		TestTrue(TEXT("Lost first copy is genuinely selected by native old resend"), Pair.Packets.Last().bHasOld && Pair.Packets.Last().OldTimeStamp == Lost.NewTimeStamp);
		TestTrue(TEXT("Old/new packet really reaches server"), Pair.Deliver(Pair.Packets.Last()));
		Pair.Deliver(Lost, false);
		TestEqual(TEXT("Loss profile simulates warm, old and new only"), Pair.ServerMovement->TestReceivedMoveCount, 3);
		TestEqual(TEXT("Old resend commits only the one received flag"), Pair.ServerAuthority.Requests.Num(), 1);
	}
	{
		FLoopback Pair;
		if (!Pair.IsValid()) { return false; }
		Pair.EnableDodge(); Pair.Warm(); Pair.ClientMovement->RequestDodge(); Pair.Predict();
		Pair.Predict();
		TestFalse(TEXT("Native first successor excludes still-last important start"), Pair.Packets.Last().bHasOld);
		TestTrue(TEXT("Lost-all-start-copies profile delivers a nonflagged successor"), Pair.Deliver(Pair.Packets.Last()));
		TestEqual(TEXT("Warm and nonflagged successor actually simulate"), Pair.ServerMovement->TestReceivedMoveCount, 2);
		TestEqual(TEXT("No received flag means no authority call"), Pair.ServerAuthority.Requests.Num(), 0);
		TestFalse(TEXT("Correction resolves never-simulated predicted start"), Pair.ClientMovement->GetDodgeState().bInProgress);
		Pair.Predict(); Pair.Deliver(Pair.Packets.Last());
		TestEqual(TEXT("Ack removes lost start before later resend can exist"), Pair.ServerAuthority.Requests.Num(), 0);
		TestEqual(TEXT("Fresh successor positive control"), Pair.ServerMovement->TestReceivedMoveCount, 3);
	}
	{
		FLoopback Pair;
		if (!Pair.IsValid()) { return false; }
		Pair.EnableDodge(); Pair.Warm(); Pair.ClientMovement->RequestDodge(); Pair.Predict();
		auto* Data = Pair.ServerMovement->GetPredictionData_Server_Character();
		const float OriginalMaxDelta = Data->MaxMoveDeltaTime;
		Data->MaxMoveDeltaTime = 0.0f; // Fixture-only engine delta clamp; timestamp is still genuinely newer.
		TestTrue(TEXT("Zero-delta flagged packet reaches engine handler"), Pair.Deliver(Pair.Packets.Last()));
		TestEqual(TEXT("Zero positive physics delta simulates nothing"), Pair.ServerMovement->TestReceivedMoveCount, 1);
		TestEqual(TEXT("Zero-delta flag never calls authority"), Pair.ServerAuthority.Requests.Num(), 0);
		Data->MaxMoveDeltaTime = OriginalMaxDelta;
		Pair.Predict(); Pair.Deliver(Pair.Packets.Last());
		TestEqual(TEXT("Restored engine delta resumes actual simulation"), Pair.ServerMovement->TestReceivedMoveCount, 2);
	}
	{
		FLoopback Pair;
		if (!Pair.IsValid()) { return false; }
		Pair.EnableDodge(); Pair.Warm(); Pair.ClientMovement->RequestDodge(); Pair.Predict(); Pair.Deliver(Pair.Packets.Last());
		Pair.ClientMovement->TestSetDodgeIntent(7); Pair.Predict(); Pair.Deliver(Pair.Packets.Last());
		TestEqual(TEXT("Mid-dodge flagged received move still calls authority once"), Pair.ServerAuthority.Requests.Num(), 2);
		if (Pair.ServerAuthority.Requests.Num() != 2) { return false; }
		TestFalse(TEXT("Mid-dodge request carries false movement-start predicate"), Pair.ServerAuthority.Requests.Last().bMovementAllowsStart);
		const float BeforeForce = Pair.ServerMovement->GetDodgeState().Elapsed;
		Pair.ServerMovement->ForcePositionUpdate(StepSeconds);
		TestTrue(TEXT("Forced update advances existing displacement"), Pair.ServerMovement->GetDodgeState().Elapsed > BeforeForce);
		TestEqual(TEXT("Force is not a received move"), Pair.ServerMovement->TestReceivedMoveCount, 3);
		TestEqual(TEXT("Force does not reauthorize last received flag"), Pair.ServerAuthority.Requests.Num(), 2);
		Pair.Predict(); Pair.Deliver(Pair.Packets.Last(), false); // Inside forced interval, genuinely dropped.
		Pair.Predict(); Pair.Deliver(Pair.Packets.Last());
		TestEqual(TEXT("Only newer post-force packet resumes simulation"), Pair.ServerMovement->TestReceivedMoveCount, 4);
		TestTrue(TEXT("Forced profile converges when newer response arrives"), Pair.Client->GetActorLocation().Equals(Pair.Server->GetActorLocation(), PositionTolerance));
	}
	for (int32 Case = 0; Case < 4; ++Case)
	{
		FLoopback Pair;
		if (!Pair.IsValid()) { return false; }
		Pair.EnableDodge(Case != 3); Pair.Warm(); Pair.ClientMovement->RequestDodge(); Pair.Predict();
		const FPacket Start = Pair.Packets.Last();
		if (Case == 0) { Pair.ServerMovement->ForcePositionUpdate(StepSeconds); }
		if (Case == 1) { Pair.ServerController->AcknowledgedPawn = nullptr; }
		if (Case == 2) { Pair.ServerMovement->SetMovementMode(MOVE_Falling); }
		TestTrue(TEXT("Profile packet decodes and reaches actual handler"), Pair.Deliver(Start, Case >= 2));
		const int32 ExpectedMoves = Case < 2 ? 1 : 2;
		const int32 ExpectedCalls = Case < 2 ? 0 : 1;
		TestEqual(TEXT("Late/unacknowledged/airborne/refused actual simulation counts"), Pair.ServerMovement->TestReceivedMoveCount, ExpectedMoves);
		TestEqual(TEXT("Late/unacknowledged/airborne/refused authority counts"), Pair.ServerAuthority.Requests.Num(), ExpectedCalls);
		TestFalse(TEXT("No refused/dropped start activates on server"), Pair.ServerMovement->GetDodgeState().bInProgress);
		if (Case == 1) { Pair.ServerController->AcknowledgedPawn = Pair.Server; }
		if (Case == 3)
		{
			Pair.ServerAuthority.bAccept = true;
			Pair.ServerMovement->ForcePositionUpdate(StepSeconds); Pair.ServerMovement->ForcePositionUpdate(StepSeconds);
			TestEqual(TEXT("Refusal followed by silence makes no later authorization"), Pair.ServerAuthority.Requests.Num(), 1);
			TestEqual(TEXT("Silence creates no received simulation"), Pair.ServerMovement->TestReceivedMoveCount, 2);
			TestFalse(TEXT("Later eligibility cannot resurrect the consumed flag"), Pair.ServerMovement->GetDodgeState().bInProgress);
		}
		if (Case < 2)
		{
			Pair.Predict(); Pair.Deliver(Pair.Packets.Last());
			TestEqual(TEXT("Newer acknowledged successor resumes actual simulation"), Pair.ServerMovement->TestReceivedMoveCount, 2);
			TestEqual(TEXT("Successor cannot resurrect dropped flag"), Pair.ServerAuthority.Requests.Num(), 0);
		}
	}
	for (int32 Case = 0; Case < 3; ++Case)
	{
		FLoopback Pair;
		if (!Pair.IsValid()) { return false; }
		Pair.EnableDodge(); Pair.Warm();
		TestTrue(TEXT("A queued press is accepted while prediction is ready"), Pair.ClientMovement->RequestDodge());
		UPlayer* OriginalPlayer = Pair.ClientController->Player;
		if (Case == 0) { Pair.ClientController->AcknowledgedPawn = nullptr; }
		if (Case == 1) { Pair.ClientController->Player = nullptr; }
		if (Case == 2) { Pair.Client->SetReplicateMovement(false); }
		TestFalse(TEXT("Unack/null-player/nonreplicating client local gate refuses"), Pair.ClientMovement->RequestDodge());
		const int32 PacketsBefore = Pair.Packets.Num();
		Pair.Predict();
		TestEqual(TEXT("Unreadied prediction captures no outbound move"), Pair.Packets.Num(), PacketsBefore);
		TestFalse(TEXT("Unreadied path leaves no predicted displacement"), Pair.ClientMovement->GetDodgeState().bInProgress);
		TestEqual(TEXT("Unreadied path calls no server authority"), Pair.ServerAuthority.Requests.Num(), 0);
		TestEqual(TEXT("Only warm received move exists"), Pair.ServerMovement->TestReceivedMoveCount, 1);
		TestTrue(TEXT("Unreadied path preserves the uncaptured queued press"), Pair.ClientMovement->bWantsToDodge);
		TestEqual(TEXT("Uncaptured queued press preserves its content version"), Pair.ClientMovement->GetDodgeRequestContentVersion(), 7u);
		Pair.ClientController->Player = OriginalPlayer; Pair.ClientController->AcknowledgedPawn = Pair.Client; Pair.Client->SetReplicateMovement(true);
		Pair.Predict();
		TestEqual(TEXT("Restored readiness captures the queued press exactly once"), Pair.Packets.Num(), PacketsBefore + 1);
		TestTrue(TEXT("Captured queued press actually predicts displacement"), Pair.ClientMovement->GetDodgeState().bInProgress);
		TestTrue(TEXT("Restored queued press is delivered through the actual handler"), Pair.Deliver(Pair.Packets.Last()));
		TestEqual(TEXT("Restored queued press authorizes exactly once"), Pair.ServerAuthority.Requests.Num(), 1);
		TestEqual(TEXT("Warm and restored start actually simulate"), Pair.ServerMovement->TestReceivedMoveCount, 2);
		TestFalse(TEXT("Successful capture consumes the one-move queued flag"), Pair.ClientMovement->bWantsToDodge);
		Pair.Predict(); Pair.Deliver(Pair.Packets.Last());
		TestEqual(TEXT("Successor does not recommit the restored press"), Pair.ServerAuthority.Requests.Num(), 1);
		TestEqual(TEXT("Successor reaches actual simulation"), Pair.ServerMovement->TestReceivedMoveCount, 3);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDodgeGroundAndCollisionTest,
	"Aetheln.Movement.Net.DodgeGroundAndCollision", EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDodgeGroundAndCollisionTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDodgeTests;
	{
		FLoopback Pair;
		if (!Pair.IsValid()) { return false; }
		Pair.Warm();
		TestFalse(TEXT("No production authority means no dodge"), Pair.ClientMovement->RequestDodge());
		Pair.Client->ReceiveDodgePressed();
		TestFalse(TEXT("Receiver without authority sets no flag"), Pair.ClientMovement->bWantsToDodge);
		Pair.Client->Jump(); Pair.Predict(); Pair.Deliver(Pair.Packets.Last());
		TestTrue(TEXT("Absent dodge retains actual ordinary client jump"), Pair.ClientMovement->IsFalling());
		TestTrue(TEXT("Absent dodge retains actual ordinary server jump"), Pair.ServerMovement->IsFalling());
		TestEqual(TEXT("Ordinary jump actually reaches server"), Pair.ServerMovement->TestReceivedMoveCount, 2);
		TestFalse(TEXT("No authority cannot create displacement"), Pair.ServerMovement->GetDodgeState().bInProgress);
	}
	{
		FLoopback Pair;
		if (!Pair.IsValid()) { return false; }
		Pair.EnableDodge(); Pair.Warm();
		Pair.ClientAuthority.bPredict = false; Pair.Client->ReceiveDodgePressed();
		TestFalse(TEXT("Receiver respects the authority's local gate"), Pair.ClientMovement->bWantsToDodge);
		Pair.ClientAuthority.bPredict = true; Pair.Client->ReceiveDodgePressed();
		TestTrue(TEXT("Receiver forwards a locally allowed press"), Pair.ClientMovement->bWantsToDodge);
		Pair.ClientMovement->bWantsToDodge = false;
		Pair.ClientMovement->SetMovementMode(MOVE_Falling);
		TestFalse(TEXT("Airborne local start is refused"), Pair.ClientMovement->RequestDodge());
		Pair.ClientMovement->SetMovementMode(MOVE_Walking);
		for (int32 Invalid = 0; Invalid < 3; ++Invalid)
		{
			const FAethelnDodgeMovementDefinition Before = Pair.ClientAuthority.Definition;
			if (Invalid == 0) { Pair.ClientAuthority.Definition.Distance = 0.0f; }
			if (Invalid == 1) { Pair.ClientAuthority.Definition.MoveDuration = 0.0f; }
			if (Invalid == 2) { Pair.ClientAuthority.Definition.ContentVersion = 0; }
			TestFalse(TEXT("Unset movement definition never predicts"), Pair.ClientMovement->RequestDodge());
			Pair.ClientAuthority.Definition = Before;
		}
	}
	for (bool bAccept : {true, false})
	{
		FLoopback Pair;
		if (!Pair.IsValid()) { return false; }
		Pair.EnableDodge(bAccept); Pair.Warm();
		Pair.ClientMovement->RequestDodge(); Pair.Client->Jump(); Pair.Predict(FVector::ForwardVector * Pair.ClientMovement->GetMaxAcceleration());
		const FPacket Start = Pair.Packets.Last();
		TestTrue(TEXT("Simultaneous local accepted prediction suppresses jump"), Pair.ClientMovement->IsWalking());
		TestTrue(TEXT("Actual saved move retains the original jump input"), (Pair.ClientMovement->GetPredictionData_Client_Character()->SavedMoves.Last()->GetCompressedFlags() & FSavedMove_Character::FLAG_JumpPressed) != 0);
		if (!bAccept) { Pair.Predict(); }
		TestTrue(TEXT("Simultaneous inputs reach actual received simulation"), Pair.Deliver(Start));
		TestEqual(TEXT("Simultaneous start asks authority once"), Pair.ServerAuthority.Requests.Num(), 1);
		if (!bAccept)
		{
			TestTrue(TEXT("Refused dodge preserves server jump"), Pair.ServerMovement->IsFalling());
			TestTrue(TEXT("Refused jump correction/replay restores falling owner"), Pair.ClientMovement->IsFalling());
			TestFalse(TEXT("Refusal does not restore saved displacement"), Pair.ClientMovement->GetDodgeState().bInProgress);
			continue;
		}
		TestTrue(TEXT("Accepted server start suppresses same-move jump"), Pair.ServerMovement->IsWalking());
		Pair.Client->StopJumping();
		for (int32 Move = 1; Move < 6; ++Move) { Pair.Predict(); Pair.Deliver(Pair.Packets.Last()); }
		TestTrue(TEXT("Dodge remains active before partial terminal move"), Pair.ClientMovement->GetDodgeState().bInProgress);
		Pair.Client->Jump(); Pair.Predict(); Pair.Deliver(Pair.Packets.Last());
		TestFalse(TEXT("Terminal fractional integration ends dodge"), Pair.ClientMovement->GetDodgeState().bInProgress);
		TestTrue(TEXT("Jump is still refused on the partially active terminal move"), Pair.ClientMovement->IsWalking() && Pair.ServerMovement->IsWalking());
		Pair.Client->StopJumping(); Pair.Client->Jump(); Pair.Predict(); Pair.Deliver(Pair.Packets.Last());
		TestTrue(TEXT("A new jump after displacement ends is ordinary"), Pair.ClientMovement->IsFalling() && Pair.ServerMovement->IsFalling());
		TestEqual(TEXT("All accepted-path moves including warm actually simulate"), Pair.ServerMovement->TestReceivedMoveCount, 9);
	}
	for (int32 Surface = 0; Surface < 4; ++Surface)
	{
		FLoopback Pair;
		if (!Pair.IsValid()) { return false; }
		Pair.EnableDodge(true, Surface == 1 ? 240.0f : 120.0f);
		if (Surface == 1)
		{
			// The standalone loopback has no GameMode to dispatch actor BeginPlay.
			Pair.World->GetWorldSettings()->NotifyBeginPlay();
			// CMC StartFalling suppresses editor departure until the world has
			// begun play and reached one second. Advance only the fixture clock.
			const int32 StartupTicks = FMath::CeilToInt(1.0f / StepSeconds) + 1;
			for (int32 Tick = 0; Tick < StartupTicks; ++Tick)
			{
				Pair.World->Tick(LEVELTICK_TimeOnly, StepSeconds);
			}
			TestTrue(TEXT("Ledge fixture passed the engine's editor falling startup grace"), Pair.World->HasBegunPlay() && Pair.World->GetTimeSeconds() >= 1.0f);
		}
		Pair.Warm();
		if (Surface == 0) { Pair.AddWall(80.0f); }
		if (Surface == 1) { Pair.FloorBox->SetBoxExtent(FVector(80.0f, 10000.0f, 50.0f)); }
		if (Surface >= 2) { Pair.AddStep(Surface == 3); }
		const FVector Start = Pair.Client->GetActorLocation();
		float MaxHeight = static_cast<float>(Start.Z);
		FVector ClientDepartureLocation = FVector::ZeroVector;
		FVector ServerDepartureLocation = FVector::ZeroVector;
		FVector ClientDepartureVelocity = FVector::ZeroVector;
		FVector ServerDepartureVelocity = FVector::ZeroVector;
		bool bCapturedClientDeparture = false;
		bool bCapturedServerDeparture = false;
		if (Surface == 1)
		{
			Pair.ClientMovement->TestDodgeGroundDepartureCapture = [&](const FVector& Location, const FVector& Velocity)
			{
				if (!bCapturedClientDeparture)
				{
					ClientDepartureLocation = Location;
					ClientDepartureVelocity = FVector(Velocity.X, Velocity.Y, 0.0f);
					bCapturedClientDeparture = true;
				}
				TestFalse(TEXT("Ground departure ends owner dodge before ordinary falling"), Pair.ClientMovement->GetDodgeState().bInProgress);
			};
			Pair.ServerMovement->TestDodgeGroundDepartureCapture = [&](const FVector& Location, const FVector& Velocity)
			{
				if (!bCapturedServerDeparture)
				{
					ServerDepartureLocation = Location;
					ServerDepartureVelocity = FVector(Velocity.X, Velocity.Y, 0.0f);
					bCapturedServerDeparture = true;
				}
				TestFalse(TEXT("Ground departure ends server dodge before ordinary falling"), Pair.ServerMovement->GetDodgeState().bInProgress);
			};
		}
		Pair.ClientMovement->RequestDodge();
		for (int32 Move = 0; Move < 7; ++Move)
		{
			Pair.Predict(FVector::ForwardVector * Pair.ClientMovement->GetMaxAcceleration()); Pair.Deliver(Pair.Packets.Last());
			MaxHeight = FMath::Max(MaxHeight, static_cast<float>(Pair.Client->GetActorLocation().Z));
		}
		TestTrue(TEXT("Engine wall/ledge/step/slope behavior has prediction parity"), Pair.Client->GetActorLocation().Equals(Pair.Server->GetActorLocation(), PositionTolerance));
		TestFalse(TEXT("All terrain cases end displacement"), Pair.ClientMovement->GetDodgeState().bInProgress);
		TestEqual(TEXT("Every terrain case delivers seven real moves plus warm"), Pair.ServerMovement->TestReceivedMoveCount, 8);
		TestEqual(TEXT("Terrain never reauthorizes a start"), Pair.ServerAuthority.Requests.Num(), 1);
		if (Surface < 2)
		{
			const FVector AuthoredEndpoint = Surface == 1 ? ClientDepartureLocation : Pair.Client->GetActorLocation();
			TestTrue(TEXT("Wall or ledge shortens authored horizontal path"), (Surface == 0 || bCapturedClientDeparture) && AuthoredEndpoint.X - Start.X < Pair.ClientAuthority.Definition.Distance - PositionTolerance);
		}
		if (Surface == 1)
		{
			TestTrue(*FString::Printf(TEXT("Leaving the actual floor changes to falling (client=%s mode=%d server=%s mode=%d)"), *Pair.Client->GetActorLocation().ToString(), static_cast<int32>(Pair.ClientMovement->MovementMode), *Pair.Server->GetActorLocation().ToString(), static_cast<int32>(Pair.ServerMovement->MovementMode)), Pair.ClientMovement->IsFalling() && Pair.ServerMovement->IsFalling());
			TestTrue(TEXT("Both grounded copies reached actual departure"), bCapturedClientDeparture && bCapturedServerDeparture);
			TestTrue(TEXT("Authored ledge endpoint has prediction parity before ordinary falling"), ClientDepartureLocation.Equals(ServerDepartureLocation, PositionTolerance));
			TestTrue(TEXT("Ordinary falling retains nonzero departure momentum"), ClientDepartureVelocity.SizeSquared2D() > 0.0 && ServerDepartureVelocity.SizeSquared2D() > 0.0);
			TestTrue(TEXT("Ended dodge adds no further horizontal displacement velocity in air"), FVector(Pair.ClientMovement->Velocity.X, Pair.ClientMovement->Velocity.Y, 0.0f).Equals(ClientDepartureVelocity, PositionTolerance) && FVector(Pair.ServerMovement->Velocity.X, Pair.ServerMovement->Velocity.Y, 0.0f).Equals(ServerDepartureVelocity, PositionTolerance));
			TestTrue(TEXT("Ordinary gravity acts after ground departure"), Pair.ClientMovement->Velocity.Z < 0.0 && Pair.ServerMovement->Velocity.Z < 0.0);
		}
		if (Surface >= 2) { TestTrue(TEXT("Actual step/ramp raised the capsule"), MaxHeight > Start.Z + 5.0f); TestTrue(TEXT("Engine keeps valid terrain walking"), Pair.ClientMovement->IsWalking()); }
		Pair.ClientMovement->TestDodgeGroundDepartureCapture = nullptr;
		Pair.ServerMovement->TestDodgeGroundDepartureCapture = nullptr;
	}
	{
		FLoopback Pair;
		if (!Pair.IsValid()) { return false; }
		Pair.EnableDodge(); Pair.Warm(); Pair.AddWall(Pair.Client->GetCapsuleComponent()->GetScaledCapsuleRadius() + 10.0f);
		Pair.ClientMovement->RequestDodge(); Pair.Predict(FVector::ForwardVector * Pair.ClientMovement->GetMaxAcceleration()); Pair.Deliver(Pair.Packets.Last());
		TestTrue(TEXT("Both sides have active displacement against equal-position wall"), Pair.ClientMovement->GetDodgeState().bInProgress && Pair.ServerMovement->GetDodgeState().bInProgress);
		Pair.ClientMovement->EndDodgeForAuthority();
		TestTrue(TEXT("Client cannot apply the authoritative end"), Pair.ClientMovement->GetDodgeState().bInProgress);
		Pair.ServerMovement->EndDodgeForAuthority(); Pair.ServerMovement->EndDodgeForAuthority();
		TestTrue(TEXT("Server end requests correction even without positional error"), Pair.ServerMovement->GetPredictionData_Server_Character()->bForceClientUpdate);
		Pair.Predict(); Pair.Deliver(Pair.Packets.Last());
		TestFalse(TEXT("Owner restores the ended authoritative state"), Pair.ClientMovement->GetDodgeState().bInProgress);
		TestEqual(TEXT("Idempotent server end yields one actual correction"), Pair.CorrectionCount, 1);
		TestEqual(TEXT("Server end calls no authorization"), Pair.ServerAuthority.Requests.Num(), 1);
		Pair.Predict(); Pair.Deliver(Pair.Packets.Last());
		TestEqual(TEXT("Future normal move sends no repeated end correction"), Pair.CorrectionCount, 1);
		TestEqual(TEXT("End control proves warm/start/end/future all simulated"), Pair.ServerMovement->TestReceivedMoveCount, 4);
	}
	return true;
}
#endif
