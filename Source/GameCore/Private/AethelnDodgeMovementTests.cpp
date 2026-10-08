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

	/** Real CMC simulation/ack/replay, with delivery scripted instead of a net driver. */
	struct FLoopback
	{
		UWorld* World = nullptr;
		UGameInstance* GameInstance = nullptr;
		AAethelnPlayerCharacter* Client = nullptr;
		AAethelnPlayerCharacter* Server = nullptr;
		APlayerController* ClientController = nullptr;
		APlayerController* ServerController = nullptr;
		UAethelnCharacterMovementComponent* ClientMovement = nullptr;
		UAethelnCharacterMovementComponent* ServerMovement = nullptr;
		TArray<FPacket> Packets;
		int32 CorrectionCount = 0;
		int32 ReplayedCorrectionCount = 0;
		bool bSerializationSucceeded = true;

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
			if (ClientMovement != nullptr) { ClientMovement->TestMoveCapture = nullptr; }
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

		void Predict(const FVector& Acceleration = FVector::ZeroVector)
		{
			World->Tick(LEVELTICK_TimeOnly, StepSeconds);
			// Request a packet each test step without changing the global combining CVar.
			ClientMovement->GetPredictionData_Client_Character()->ClientUpdateRealTime = World->GetRealTimeSeconds() - 1.0f;
			ClientMovement->TestReplicateMove(StepSeconds, Acceleration);
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

		bool Respond()
		{
			FClientAdjustment& Adjustment = ServerMovement->GetPredictionData_Server_Character()->PendingAdjustment;
			if (Adjustment.TimeStamp <= 0.0f) { return false; }
			FCharacterMoveResponseDataContainer& Out = ServerMovement->TestGetMoveResponseDataContainer();
			Out.ServerFillResponseData(*ServerMovement, Adjustment);
			CorrectionCount += Out.IsCorrection() ? 1 : 0;
			FBitWriter Writer(0, true);
			FObjectAndNameAsStringProxyArchive Save(Writer, false);
			const bool bEncoded = Out.Serialize(*ServerMovement, Save, nullptr) && !Writer.IsError();
			FBitReader Reader(Writer.GetData(), Writer.GetNumBits());
			FObjectAndNameAsStringProxyArchive Load(Reader, false);
			FCharacterMoveResponseDataContainer& In = ClientMovement->TestGetMoveResponseDataContainer();
			const bool bDecoded = bEncoded && In.Serialize(*ClientMovement, Load, nullptr) && !Reader.IsError();
			bSerializationSucceeded &= bDecoded;
			if (!bDecoded) { return false; }
			ClientMovement->ClientHandleMoveResponse(In);
			ReplayedCorrectionCount += ClientMovement->TestReplayCorrection() ? 1 : 0;
			Adjustment.TimeStamp = 0.0f;
			return true;
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
#endif
