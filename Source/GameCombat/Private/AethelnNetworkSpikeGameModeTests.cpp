#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnNetworkSpikeGameMode.h"

#include "AethelnSpikeCharacter.h"
#include "AethelnSpikeEnemy.h"
#include "Engine/Engine.h"
#include "Engine/World.h"
#include "GameFramework/PlayerController.h"
#include "Misc/AutomationTest.h"

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
