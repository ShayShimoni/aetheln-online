#pragma once

/*
 * Loopback move/response harness for the dodge movement tests (#18 P2) and the
 * GameTests dodge authority tests (#18 P3). Test-only: compiled only with
 * WITH_DEV_AUTOMATION_TESTS and holds no UCLASS, so UHT never sees it.
 */
#if WITH_DEV_AUTOMATION_TESTS
#include "AethelnCharacterMovementComponent.h"
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

		/** BeforePossess lets a caller attach real PlayerStates before possession grants and initializes them. */
		explicit FLoopback(TFunction<void(APlayerController& ClientController, APlayerController& ServerController)> BeforePossess = nullptr)
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
			if (BeforePossess) { BeforePossess(*ClientController, *ServerController); }
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
#endif
