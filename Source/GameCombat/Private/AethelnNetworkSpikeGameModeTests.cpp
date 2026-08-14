#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnNetworkSpikeGameMode.h"

#include "AethelnSpikeAuthorityComponent.h"
#include "AethelnSpikeCharacter.h"
#include "AethelnSpikeEnemy.h"
#include "Engine/Engine.h"
#include "Engine/World.h"
#include "GameFramework/PlayerController.h"
#include "Misc/AutomationTest.h"

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

	GameMode->bScenarioEnabled = true;
	GameMode->ClientIds.Add(PlayerController, TEXT("client-1"));
	GameMode->ConnectionIds.Add(PlayerController, TEXT("disconnect-test-connection"));
	GameMode->InitialLocations.Add(PlayerController, Character->GetActorLocation());
	GameMode->AuthorityComponents.Add(PlayerController, AuthorityComponent);
	AuthorityComponent->SetLifecycleReady(true);

	PlayerController->UnPossess();
	TestNull(TEXT("Exiting controller pawn is null before Logout"), PlayerController->GetPawn());
	TestTrue(TEXT("Character remains live after controller pawn detachment"), IsValid(Character));
	TestTrue(TEXT("Authority component remains live after controller pawn detachment"), IsValid(AuthorityComponent));

	AddExpectedErrorPlain(
		TEXT("AUTHORITY rejection category=disconnected-command reason=connection-closed client=client-1"),
		EAutomationExpectedErrorFlags::Contains,
		1);
	GameMode->Logout(PlayerController);

	FAethelnSpikeScenarioProbe ClosedCommand;
	ClosedCommand.Category = TEXT("disconnected-command");
	ClosedCommand.Sequence = 1;
	ClosedCommand.ClaimedMagnitude = 1.0f;
	TestEqual(
		TEXT("Detached client command is rejected because the connection is closed"),
		AuthorityComponent->ValidateScenarioProbe(ClosedCommand),
		EAethelnSpikeAttackRejection::ConnectionClosed);
	TestFalse(TEXT("Logout removes the client id"), GameMode->ClientIds.Contains(PlayerController));
	TestFalse(TEXT("Logout removes the connection id"), GameMode->ConnectionIds.Contains(PlayerController));
	TestFalse(TEXT("Logout removes the initial location"), GameMode->InitialLocations.Contains(PlayerController));
	TestFalse(TEXT("Logout removes the authority component association"), GameMode->AuthorityComponents.Contains(PlayerController));

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
