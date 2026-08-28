#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnNetworkSpikeGameMode.h"

#include "AethelnSpikeAuthorityComponent.h"
#include "AethelnSpikeCharacter.h"
#include "AethelnSpikeEnemy.h"
#include "Engine/Engine.h"
#include "Engine/World.h"
#include "GameFramework/PlayerController.h"
#include "Misc/AutomationTest.h"
#include "Misc/OutputDevice.h"
#include "Misc/OutputDeviceRedirector.h"

namespace AethelnNetworkSpikeGameModeTests
{
	class FScopedDisconnectLogCapture final : public FOutputDevice
	{
	public:
		FScopedDisconnectLogCapture()
		{
			if (GLog != nullptr)
			{
				GLog->AddOutputDevice(this);
				bRegistered = true;
			}
		}

		virtual ~FScopedDisconnectLogCapture() override
		{
			if (bRegistered && GLog != nullptr)
			{
				GLog->FlushThreadedLogs();
				GLog->RemoveOutputDevice(this);
			}
		}

		virtual void Serialize(const TCHAR* Message, ELogVerbosity::Type Verbosity, const FName& Category) override
		{
			if (FCString::Strstr(Message, TEXT("AUTHORITY rejection category=disconnected-command")) != nullptr)
			{
				++DisconnectedCommandRejectionCount;
			}
		}

		int32 GetDisconnectedCommandRejectionCount() const
		{
			if (GLog != nullptr)
			{
				GLog->FlushThreadedLogs();
			}
			return DisconnectedCommandRejectionCount;
		}

	private:
		int32 DisconnectedCommandRejectionCount = 0;
		bool bRegistered = false;
	};
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnNetworkSpikeGameModeDisconnectLifecycleTest,
	"Aetheln.GameCombat.NetworkSpike.DisconnectLifecycle",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnNetworkSpikeGameModeDisconnectLifecycleTest::RunTest(const FString& Parameters)
{
	UWorld* World = UWorld::CreateWorld(EWorldType::Game, false);
	TestNotNull(TEXT("Disconnect lifecycle world was created"), World);
	if (World == nullptr)
	{
		return false;
	}

	TestNotNull(TEXT("Engine exists for disconnect lifecycle world"), GEngine);
	if (GEngine == nullptr)
	{
		World->DestroyWorld(false);
		return false;
	}

	FWorldContext& WorldContext = GEngine->CreateNewWorldContext(EWorldType::Game);
	WorldContext.SetCurrentWorld(World);
	auto DestroyTestWorld = [World]()
	{
		World->DestroyWorld(false);
		GEngine->DestroyWorldContext(World);
	};

	World->InitializeActorsForPlay(FURL());
	World->BeginPlay();

	FActorSpawnParameters SpawnParameters;
	SpawnParameters.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
	AAethelnNetworkSpikeGameMode* GameMode = World->SpawnActor<AAethelnNetworkSpikeGameMode>(
		AAethelnNetworkSpikeGameMode::StaticClass(), FVector::ZeroVector, FRotator::ZeroRotator, SpawnParameters);
	APlayerController* PlayerController = World->SpawnActor<APlayerController>(
		APlayerController::StaticClass(), FVector::ZeroVector, FRotator::ZeroRotator, SpawnParameters);
	AAethelnSpikeCharacter* Character = World->SpawnActor<AAethelnSpikeCharacter>(
		AAethelnSpikeCharacter::StaticClass(), FVector::ZeroVector, FRotator::ZeroRotator, SpawnParameters);

	TestNotNull(TEXT("Disconnect lifecycle GameMode exists"), GameMode);
	TestNotNull(TEXT("Disconnect lifecycle player controller exists"), PlayerController);
	TestNotNull(TEXT("Disconnect lifecycle character exists"), Character);
	if (GameMode == nullptr || PlayerController == nullptr || Character == nullptr)
	{
		DestroyTestWorld();
		return false;
	}

	UAethelnSpikeAuthorityComponent* AuthorityComponent = Character->FindComponentByClass<UAethelnSpikeAuthorityComponent>();
	TestNotNull(TEXT("Disconnect lifecycle authority component exists"), AuthorityComponent);
	if (AuthorityComponent == nullptr)
	{
		DestroyTestWorld();
		return false;
	}

	PlayerController->Possess(Character);
	TestTrue(TEXT("Player controller possesses the disconnect lifecycle character"), PlayerController->GetPawn() == Character);
	if (PlayerController->GetPawn() != Character)
	{
		DestroyTestWorld();
		return false;
	}
	TestEqual(
		TEXT("Connection identity is excluded until the authority assigns an opaque value"),
		Character->GetObservabilityConnectionPseudonym(),
		FString(TEXT("excluded")));
	Character->SetObservabilityConnectionPseudonym(TEXT("server-connection-test-0001"));
	TestEqual(
		TEXT("Authority-owned opaque connection identity is retained by the producer owner"),
		Character->GetObservabilityConnectionPseudonym(),
		FString(TEXT("server-connection-test-0001")));

	GameMode->bScenarioEnabled = true;
	GameMode->ClientIds.Add(PlayerController, TEXT("client-1"));
	GameMode->ConnectionIds.Add(PlayerController, TEXT("disconnect-test-connection"));
	GameMode->InitialLocations.Add(PlayerController, Character->GetActorLocation());
	GameMode->AuthorityComponents.Add(PlayerController, AuthorityComponent);
	AuthorityComponent->SetLifecycleReady(true);

	TWeakObjectPtr<AAethelnSpikeCharacter> CharacterWeak = Character;
	TWeakObjectPtr<UAethelnSpikeAuthorityComponent> AuthorityComponentWeak = AuthorityComponent;
	PlayerController->UnPossess();
	TestNull(TEXT("Exiting controller pawn is null before pawn teardown"), PlayerController->GetPawn());
	TestTrue(TEXT("Disconnect lifecycle pawn destruction succeeds"), World->DestroyActor(Character));
	Character = nullptr;
	AuthorityComponent = nullptr;
	TestNull(TEXT("Exiting controller pawn remains null before Logout"), PlayerController->GetPawn());
	TestFalse(TEXT("Character is unavailable before Logout"), CharacterWeak.IsValid());
	TestFalse(TEXT("Authority component is unavailable before Logout"), AuthorityComponentWeak.IsValid());

	AethelnNetworkSpikeGameModeTests::FScopedDisconnectLogCapture LogCapture;
	GameMode->Logout(PlayerController);

	TestEqual(
		TEXT("Logout does not fabricate a disconnected-command rejection without a command-validation attempt"),
		LogCapture.GetDisconnectedCommandRejectionCount(),
		0);
	TestFalse(TEXT("Logout removes the client id"), GameMode->ClientIds.Contains(PlayerController));
	TestFalse(TEXT("Logout removes the connection id"), GameMode->ConnectionIds.Contains(PlayerController));
	TestFalse(TEXT("Logout removes the initial location"), GameMode->InitialLocations.Contains(PlayerController));
	TestFalse(TEXT("Logout removes the authority component association"), GameMode->AuthorityComponents.Contains(PlayerController));

	DestroyTestWorld();
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnNetworkSpikeGameModeDeferredPseudonymTest,
	"Aetheln.GameCombat.NetworkSpike.DeferredConnectionPseudonym",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnNetworkSpikeGameModeDeferredPseudonymTest::RunTest(const FString& Parameters)
{
	UWorld* World = UWorld::CreateWorld(EWorldType::Game, false);
	TestNotNull(TEXT("Deferred-pseudonym world was created"), World);
	if (World == nullptr || GEngine == nullptr)
	{
		return false;
	}

	FWorldContext& WorldContext = GEngine->CreateNewWorldContext(EWorldType::Game);
	WorldContext.SetCurrentWorld(World);
	auto DestroyTestWorld = [World]()
	{
		World->DestroyWorld(false);
		GEngine->DestroyWorldContext(World);
	};
	World->InitializeActorsForPlay(FURL());
	World->BeginPlay();

	FActorSpawnParameters SpawnParameters;
	SpawnParameters.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
	AAethelnNetworkSpikeGameMode* GameMode = World->SpawnActor<AAethelnNetworkSpikeGameMode>(
		AAethelnNetworkSpikeGameMode::StaticClass(), FVector::ZeroVector, FRotator::ZeroRotator, SpawnParameters);
	APlayerController* PlayerController = World->SpawnActor<APlayerController>(
		APlayerController::StaticClass(), FVector::ZeroVector, FRotator::ZeroRotator, SpawnParameters);
	TestNotNull(TEXT("Deferred-pseudonym GameMode exists"), GameMode);
	TestNotNull(TEXT("Deferred-pseudonym controller exists"), PlayerController);
	if (GameMode == nullptr || PlayerController == nullptr)
	{
		DestroyTestWorld();
		return false;
	}

	GameMode->bScenarioEnabled = true;
	GameMode->RunId = TEXT("run-deferred-login");
	GameMode->ClientIds.Add(PlayerController, TEXT("client-1"));
	TestNull(TEXT("Login starts before an authoritative pawn exists"), PlayerController->GetPawn());
	TestTrue(TEXT("PostLogin registration seam accepts the pawnless connection"), GameMode->RegisterScenarioConnection(PlayerController));
	TestNull(TEXT("Connection registration does not require a pawn"), PlayerController->GetPawn());
	const FString* StoredConnection = GameMode->ConnectionIds.Find(PlayerController);
	TestNotNull(TEXT("PostLogin stores an authority-owned connection pseudonym"), StoredConnection);
	TestFalse(
		TEXT("Stored pseudonym is not fabricated onto an absent pawn"),
		GameMode->ApplyStoredConnectionPseudonym(PlayerController));
	if (StoredConnection == nullptr)
	{
		DestroyTestWorld();
		return false;
	}
	const FString ExpectedConnection = *StoredConnection;

	AAethelnSpikeCharacter* Character = World->SpawnActor<AAethelnSpikeCharacter>(
		AAethelnSpikeCharacter::StaticClass(), FVector::ZeroVector, FRotator::ZeroRotator, SpawnParameters);
	TestNotNull(TEXT("Deferred authoritative pawn exists"), Character);
	if (Character == nullptr)
	{
		DestroyTestWorld();
		return false;
	}
	PlayerController->SetPawn(Character);
	GameMode->FinishRestartPlayer(PlayerController, FRotator::ZeroRotator);
	TestTrue(TEXT("Normal restart flow possesses the deferred pawn"), PlayerController->GetPawn() == Character);
	TestEqual(
		TEXT("Normal restart flow applies the stored authority-owned pseudonym"),
		Character->GetObservabilityConnectionPseudonym(),
		ExpectedConnection);

	GameMode->Logout(PlayerController);
	DestroyTestWorld();
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnNetworkSpikeGameModeRuntimePlacementTest,
	"Aetheln.GameCombat.NetworkSpike.RuntimePlacement",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnNetworkSpikeGameModeRuntimePlacementTest::RunTest(const FString& Parameters)
{
	UWorld* World = UWorld::CreateWorld(EWorldType::Game, false);
	TestNotNull(TEXT("Runtime placement world was created"), World);
	if (World == nullptr)
	{
		return false;
	}

	TestNotNull(TEXT("Engine exists for runtime placement world"), GEngine);
	if (GEngine == nullptr)
	{
		World->DestroyWorld(false);
		return false;
	}

	FWorldContext& WorldContext = GEngine->CreateNewWorldContext(EWorldType::Game);
	WorldContext.SetCurrentWorld(World);
	auto DestroyTestWorld = [World]()
	{
		World->DestroyWorld(false);
		GEngine->DestroyWorldContext(World);
	};

	World->InitializeActorsForPlay(FURL());
	World->BeginPlay();

	FActorSpawnParameters SpawnParameters;
	SpawnParameters.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
	AAethelnNetworkSpikeGameMode* GameMode = World->SpawnActor<AAethelnNetworkSpikeGameMode>(
		AAethelnNetworkSpikeGameMode::StaticClass(), FVector::ZeroVector, FRotator::ZeroRotator, SpawnParameters);
	APlayerController* PlayerController = World->SpawnActor<APlayerController>(
		APlayerController::StaticClass(), FVector::ZeroVector, FRotator::ZeroRotator, SpawnParameters);
	AAethelnSpikeCharacter* Character = World->SpawnActor<AAethelnSpikeCharacter>(
		AAethelnSpikeCharacter::StaticClass(), FVector::ZeroVector, FRotator::ZeroRotator, SpawnParameters);
	AAethelnSpikeEnemy* Enemy = World->SpawnActor<AAethelnSpikeEnemy>(
		AAethelnSpikeEnemy::StaticClass(), FVector(500.0f, 500.0f, 100.0f), FRotator::ZeroRotator, SpawnParameters);

	TestNotNull(TEXT("Runtime placement GameMode exists"), GameMode);
	TestNotNull(TEXT("Runtime placement player controller exists"), PlayerController);
	TestNotNull(TEXT("Runtime placement character exists"), Character);
	TestNotNull(TEXT("Runtime placement enemy exists"), Enemy);
	if (GameMode == nullptr || PlayerController == nullptr || Character == nullptr || Enemy == nullptr)
	{
		DestroyTestWorld();
		return false;
	}

	PlayerController->Possess(Character);
	TestTrue(TEXT("Player controller possesses the runtime placement character"), PlayerController->GetPawn() == Character);
	if (PlayerController->GetPawn() != Character)
	{
		DestroyTestWorld();
		return false;
	}

	GameMode->ClientIds.Add(PlayerController, TEXT("client-1"));
	GameMode->InitialLocations.Add(PlayerController, Character->GetActorLocation());
	GameMode->SpawnedEnemy = Enemy;
	GameMode->bScenarioEnabled = true;

	const FVector EnabledPawnLocation(125.0f, -250.0f, 75.0f);
	const FRotator EnabledPawnRotation(0.0f, 90.0f, 0.0f);
	Character->SetActorLocationAndRotation(EnabledPawnLocation, EnabledPawnRotation);
	GameMode->Tick(0.0f);

	const FVector ExpectedEnabledEnemyLocation =
		EnabledPawnLocation + Character->GetActorForwardVector().GetSafeNormal() * 175.0f;
	TestEqual(
		TEXT("Enabled scenario follows moved and rotated authoritative client one at 175 units"),
		Enemy->GetActorLocation(),
		ExpectedEnabledEnemyLocation);

	GameMode->bScenarioEnabled = false;
	const FVector DisabledEnemyLocation = Enemy->GetActorLocation();
	Character->SetActorLocationAndRotation(FVector(-300.0f, 400.0f, 125.0f), FRotator(0.0f, -45.0f, 0.0f));
	GameMode->Tick(0.0f);
	TestEqual(
		TEXT("Disabled scenario leaves the enemy unchanged"),
		Enemy->GetActorLocation(),
		DisabledEnemyLocation);

	DestroyTestWorld();
	return true;
}

#endif
