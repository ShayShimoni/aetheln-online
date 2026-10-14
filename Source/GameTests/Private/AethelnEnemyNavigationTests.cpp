#if WITH_DEV_AUTOMATION_TESTS && WITH_EDITOR

#include "AI/NavigationSystemBase.h"
#include "ActorFactories/ActorFactory.h"
#include "AethelnChainTestFixture.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnEnemyAttackAbility.h"
#include "AethelnEnemyCharacter.h"
#include "AethelnEnemyController.h"
#include "Builders/CubeBuilder.h"
#include "Components/BrushComponent.h"
#include "Components/CapsuleComponent.h"
#include "Components/StaticMeshComponent.h"
#include "Engine/CollisionProfile.h"
#include "Engine/StaticMesh.h"
#include "Engine/StaticMeshActor.h"
#include "EngineUtils.h"
#include "FileHelpers.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "GameFramework/PlayerStart.h"
#include "Misc/AutomationTest.h"
#include "NavMesh/NavMeshBoundsVolume.h"
#include "NavMesh/RecastNavMesh.h"
#include "Navigation/PathFollowingComponent.h"
#include "NavigationSystem.h"

// #83 P3, Test Plan E12 (docs/enemy-ai-and-navigation.md): a real navmesh. A headless world has no navigation system, so
// the test adds one the way a game map load does (FNavigationSystem::AddNavigationSystemToWorld, GameMode), after the
// floor and the bounds volume exist, then builds the mesh and blocks until it is done. The floor is the engine's cube
// scaled to an arena, and the enemy, controller, attack, and attributes are the promoted provisional values from
// Config/DefaultGame.ini. Nothing here is tuning, and the sizes are fixture values.
//
// The mesh is static, as in the prototype space: it is built once, so a blocker added afterwards (one that does not
// affect navigation) stands in a path the mesh still offers. The enemy walks into it, and the engine's block detection
// reports a real Blocked result.
namespace AethelnEnemyNavigationTests
{
	using namespace AethelnChainTests;
	using EState = EAethelnEnemyState;

	constexpr double TickSeconds = 1.0 / 30.0;
	/** The floor top is z = 0; capsule centers sit this far above it. */
	constexpr double EnemyHeight = 90.0;
	constexpr double PlayerHeight = 97.0;

	struct FNavigation
	{
		UNavigationSystemV1* System = nullptr;
		ARecastNavMesh* Mesh = nullptr;
		double InitAndBuildMilliseconds = 0.0;
	};

	AStaticMeshActor* SpawnBox(UWorld& World, const FVector& Center, const FVector& Size, bool bAffectsNavigation)
	{
		UStaticMesh* Cube = LoadObject<UStaticMesh>(nullptr, TEXT("/Engine/BasicShapes/Cube.Cube"));
		if (Cube == nullptr) { return nullptr; }
		FActorSpawnParameters Parameters;
		Parameters.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
		// The engine cube is 100 units on a side.
		AStaticMeshActor* Box = World.SpawnActor<AStaticMeshActor>(AStaticMeshActor::StaticClass(), FTransform(FRotator::ZeroRotator, Center, Size / 100.0), Parameters);
		if (Box == nullptr) { return nullptr; }
		Box->SetMobility(EComponentMobility::Movable);
		UStaticMeshComponent* Mesh = Box->GetStaticMeshComponent();
		Mesh->SetStaticMesh(Cube);
		Mesh->SetCollisionProfileName(UCollisionProfile::BlockAll_ProfileName);
		Mesh->SetCanEverAffectNavigation(bAffectsNavigation);
		return Box;
	}

	ANavMeshBoundsVolume* SpawnBounds(UWorld& World, const FVector& Center, const FVector& Size)
	{
		ANavMeshBoundsVolume* Volume = World.SpawnActor<ANavMeshBoundsVolume>(Center, FRotator::ZeroRotator);
		if (Volume == nullptr) { return nullptr; }
		Volume->SetActorScale3D(Size);
		// A runtime volume has no brush, so its bounds are empty: build the unit cube the editor's volume factories build.
		UCubeBuilder* Builder = NewObject<UCubeBuilder>();
		Builder->X = 1.0f;
		Builder->Y = 1.0f;
		Builder->Z = 1.0f;
		UActorFactory::CreateBrushForVolumeActor(Volume, Builder);
		Volume->GetBrushComponent()->UpdateBounds();
		return Volume;
	}

	/** A 3000 x 1000 floor with its top at z = 0, a bounds volume around it, and a built navigation mesh. */
	bool BuildArena(FAutomationTestBase& Test, UWorld& World, FNavigation& Out)
	{
		// The headless world has no saved navigation data, so the system spawns the mesh at runtime, which it logs as a warning;
		// and the crowd manager, at world cleanup, looks for the mesh that is already gone.
		Test.AddExpectedMessage(TEXT("SpawnMissingNavigationData: No saved navigation data found"), ELogVerbosity::Warning, EAutomationExpectedMessageFlags::Contains, 0);
		Test.AddExpectedMessage(TEXT("Unable to find RecastNavMesh instance while trying to create UCrowdManager instance"), ELogVerbosity::Warning, EAutomationExpectedMessageFlags::Contains, 0);
		if (!Test.TestNotNull(TEXT("The arena floor spawned"), SpawnBox(World, FVector(0.0, 0.0, -50.0), FVector(3000.0, 1000.0, 100.0), true))) { return false; }
		const ANavMeshBoundsVolume* Bounds = SpawnBounds(World, FVector(0.0, 0.0, 100.0), FVector(3200.0, 1200.0, 600.0));
		if (!Test.TestNotNull(TEXT("The bounds volume spawned"), Bounds)) { return false; }
		Test.TestTrue(TEXT("The bounds volume has a real box"), Bounds->GetComponentsBoundingBox(true).GetSize().X > 3000.0);
		const double Start = FPlatformTime::Seconds();
		FNavigationSystem::AddNavigationSystemToWorld(World, FNavigationSystemRunMode::GameMode);
		Out.System = UNavigationSystemV1::GetCurrent(&World);
		if (!Test.TestNotNull(TEXT("The world has a navigation system"), Out.System)) { return false; }
		Out.System->Build();
		Out.InitAndBuildMilliseconds = (FPlatformTime::Seconds() - Start) * 1000.0;
		Out.Mesh = Cast<ARecastNavMesh>(Out.System->GetDefaultNavDataInstance(FNavigationSystem::DontCreate));
		if (!Test.TestNotNull(TEXT("The navigation system created a RecastNavMesh"), Out.Mesh)) { return false; }
		FNavLocation Projected;
		return Test.TestTrue(TEXT("The built mesh covers the floor"),
			Out.System->ProjectPointToNavigation(FVector(0.0, 0.0, 0.0), Projected, FVector(100.0, 100.0, 200.0)));
	}

	/** An enemy at Location that can walk. */
	AAethelnEnemyCharacter* SpawnWalkingEnemy(FAutomationTestBase& Test, UWorld& World, const FVector& Location)
	{
		const FTransform Transform(Location);
		AAethelnEnemyCharacter* Enemy = World.SpawnActorDeferred<AAethelnEnemyCharacter>(AAethelnEnemyCharacter::StaticClass(), Transform,
			nullptr, nullptr, ESpawnActorCollisionHandlingMethod::AlwaysSpawn);
		if (!Test.TestNotNull(TEXT("Enemy exists"), Enemy)) { return nullptr; }
		Enemy->FinishSpawning(Transform);
		// The harness world never reports HasBegunPlay (no game mode), so BeginPlay (home, init, grant) is dispatched by hand,
		// and the controller begins play too: its path following component only ticks after that.
		Enemy->DispatchBeginPlay();
		if (AController* Controller = Enemy->GetController()) { Controller->DispatchBeginPlay(); }
		Enemy->GetCharacterMovement()->SetMovementMode(MOVE_Walking);
		return Enemy;
	}

	/**
	 * Ticks the enemy's path following and movement components by hand. In this headless fixture world their scheduled
	 * ticks never run (the pending movement input is never consumed, although a plain tick function does run), so the
	 * test supplies them. The controller's state machine, the navmesh queries, the engine's path following and its block
	 * detection are the real ones; the hand tick only lets the capsule move. The scheduled ticks are not covered here.
	 */
	void TickEnemyComponents(AAethelnEnemyCharacter& Enemy, float DeltaSeconds)
	{
		if (AAethelnEnemyController* Controller = Cast<AAethelnEnemyController>(Enemy.GetController()))
		{
			UPathFollowingComponent* PathFollowing = Controller->GetPathFollowingComponent();
			PathFollowing->TickComponent(DeltaSeconds, LEVELTICK_All, &PathFollowing->PrimaryComponentTick);
		}
		UCharacterMovementComponent* Movement = Enemy.GetCharacterMovement();
		Movement->TickComponent(DeltaSeconds, LEVELTICK_All, &Movement->PrimaryComponentTick);
	}

	/** Advances the world in small steps until Done holds or MaxSeconds pass; false on timeout. */
	template <typename TDone>
	bool TickUntil(FFixture& F, AAethelnEnemyCharacter* Enemy, double MaxSeconds, TDone Done)
	{
		const double End = F.World.World->GetTimeSeconds() + MaxSeconds;
		while (!Done())
		{
			if (F.World.World->GetTimeSeconds() >= End) { return false; }
			TickEnemyComponents(*Enemy, static_cast<float>(TickSeconds));
			F.AdvanceTo(F.World.World->GetTimeSeconds() + TickSeconds);
		}
		return true;
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnEnemyRealNavmeshTest,
	"Aetheln.GameCombat.EnemyAI.RealNavmesh",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnEnemyRealNavmeshTest::RunTest(const FString& Parameters)
{
	using namespace AethelnEnemyNavigationTests;
	{
		// E12: the enemy reaches a target across the floor on the real mesh. The target stands 350 units from home, inside
		// the promoted perception radius, and the enemy is not told to stand still.
		FFixture F; if (!F.Init(*this)) { return false; }
		F.Player.PlayerState->SetPlayerId(1);
		F.Pawn->SetActorLocation(FVector(350.0, 0.0, PlayerHeight));
		FNavigation Navigation; if (!BuildArena(*this, *F.World.World, Navigation)) { return false; }
		AAethelnEnemyCharacter* Enemy = SpawnWalkingEnemy(*this, *F.World.World, FVector(0.0, 0.0, EnemyHeight));
		if (Enemy == nullptr) { return false; }
		AAethelnEnemyController* Controller = Cast<AAethelnEnemyController>(Enemy->GetController());
		if (!TestNotNull(TEXT("The enemy controller possessed the enemy on spawn"), Controller)) { return false; }
		const FVector Home = Enemy->GetActorLocation();
		const double Range = Controller->ProvisionalAttackRange;
		TestTrue(TEXT("The target starts out of attack range"), FVector::Dist2D(Home, F.Pawn->GetActorLocation()) > Range);
		const bool bReached = TickUntil(F, Enemy, 5.0, [&]() { return FVector::Dist2D(Enemy->GetActorLocation(), F.Pawn->GetActorLocation()) <= Range; });
		TestTrue(TEXT("The enemy walked across the floor into attack range"), bReached);
		TestTrue(TEXT("The enemy left home on its own"), FVector::Dist2D(Enemy->GetActorLocation(), Home) > 100.0);
		TestTrue(TEXT("The player is the target"), Controller->GetTarget() == F.Pawn);
		const bool bTelegraphed = TickUntil(F, Enemy, 2.0, [&]() { return Controller->GetState() == EState::Telegraph || Controller->GetState() == EState::Attack; });
		TestTrue(TEXT("At the target the enemy telegraphs"), bTelegraphed);
	}
	{
		// E12: stuck recovery on a real Blocked result. A wall that does not affect navigation stands across the path
		// after the mesh is built. The first Blocked repaths, the second resets the enemy home.
		FFixture F; if (!F.Init(*this)) { return false; }
		F.Player.PlayerState->SetPlayerId(1);
		F.Pawn->SetActorLocation(FVector(350.0, 0.0, PlayerHeight));
		FNavigation Navigation; if (!BuildArena(*this, *F.World.World, Navigation)) { return false; }
		if (!TestNotNull(TEXT("The wall spawned"), SpawnBox(*F.World.World, FVector(200.0, 0.0, 150.0), FVector(40.0, 1100.0, 300.0), false))) { return false; }
		AAethelnEnemyCharacter* Enemy = SpawnWalkingEnemy(*this, *F.World.World, FVector(0.0, 0.0, EnemyHeight));
		if (Enemy == nullptr) { return false; }
		AAethelnEnemyController* Controller = Cast<AAethelnEnemyController>(Enemy->GetController());
		if (!TestNotNull(TEXT("The enemy controller possessed the enemy on spawn"), Controller)) { return false; }
		const FVector Home = Enemy->GetActorLocation();
		TArray<EPathFollowingResult::Type> Results;
		UPathFollowingComponent* PathFollowing = Controller->GetPathFollowingComponent();
		if (!TestNotNull(TEXT("The controller has a path following component"), PathFollowing)) { return false; }
		const FDelegateHandle Listener = PathFollowing->OnRequestFinished.AddLambda(
			[&Results](FAIRequestID, const FPathFollowingResult& Result) { Results.Add(Result.Code); });
		// Block detection needs a full sample window (engine defaults) of no progress, twice.
		const bool bReset = TickUntil(F, Enemy, 40.0, [&]() { return Results.Num() >= 2 && Controller->GetState() == EState::Idle; });
		PathFollowing->OnRequestFinished.Remove(Listener);
		TestTrue(TEXT("Two moves ended and the second one reset the enemy"), bReset);
		if (Results.Num() >= 2)
		{
			TestEqual(TEXT("The first move ended Blocked"), Results[0], EPathFollowingResult::Blocked);
			TestEqual(TEXT("The repathed move ended Blocked"), Results[1], EPathFollowingResult::Blocked);
		}
		TestTrue(TEXT("The reset brought the enemy home"), FVector::Dist(Enemy->GetActorLocation(), Home) < 1.0);
		TestNull(TEXT("The reset dropped the target"), Controller->GetTarget());
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnEnemyPrototypeSpaceTest,
	"Aetheln.GameCombat.EnemyAI.PrototypeSpace",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnEnemyPrototypeSpaceTest::RunTest(const FString& Parameters)
{
	// E14 (#83 P4): the prototype space itself. /Game/Maps/MovementPOC is loaded the way the Editor loads it, and the test
	// reads what is saved in the map: one navigation bounds volume around the playable area, a built static RecastNavMesh,
	// and one placed greybox enemy. The map is never saved, so nothing here changes it. A loaded editor world does not
	// begin play, so the placed enemy is given its controller and begun by hand, as E12's fixture world does, to prove that
	// what is saved in the map initialises as the document requires.
	UWorld* World = UEditorLoadingAndSavingUtils::LoadMap(TEXT("/Game/Maps/MovementPOC"));
	if (TestNotNull(TEXT("MovementPOC loads"), World))
	{
		TArray<ANavMeshBoundsVolume*> Volumes;
		for (TActorIterator<ANavMeshBoundsVolume> It(World); It; ++It) { Volumes.Add(*It); }
		TArray<ARecastNavMesh*> Meshes;
		for (TActorIterator<ARecastNavMesh> It(World); It; ++It) { Meshes.Add(*It); }
		TArray<AAethelnEnemyCharacter*> Enemies;
		for (TActorIterator<AAethelnEnemyCharacter> It(World); It; ++It) { Enemies.Add(*It); }
		TArray<APlayerStart*> Starts;
		for (TActorIterator<APlayerStart> It(World); It; ++It) { Starts.Add(*It); }
		TestEqual(TEXT("The map has one navigation bounds volume"), Volumes.Num(), 1);
		TestEqual(TEXT("The map has one RecastNavMesh"), Meshes.Num(), 1);
		TestEqual(TEXT("The map has one greybox enemy"), Enemies.Num(), 1);
		TestEqual(TEXT("The map has one player start"), Starts.Num(), 1);
		if (Volumes.Num() == 1 && Meshes.Num() == 1 && Enemies.Num() == 1 && Starts.Num() == 1)
		{
			const FBox Bounds = Volumes[0]->GetComponentsBoundingBox(true);
			// The playable area is the floor inside the four perimeter walls (movement-poc.md), 5800 units square with its top at z = 0.
			TestTrue(TEXT("The bounds volume covers the floor inside the walls"),
				Bounds.IsInside(FVector(-2900.0, -2900.0, 0.0)) && Bounds.IsInside(FVector(2900.0, 2900.0, 0.0)));
			TestTrue(TEXT("The bounds volume covers the player start"), Bounds.IsInside(Starts[0]->GetActorLocation()));
			TestTrue(TEXT("The bounds volume covers the enemy"), Bounds.IsInside(Enemies[0]->GetActorLocation()));

			ARecastNavMesh* Mesh = Meshes[0];
			TestTrue(TEXT("The mesh is static, built in the Editor"), Mesh->GetRuntimeGenerationMode() == ERuntimeGenerationType::Static);
			TestTrue(TEXT("The mesh was saved with built tiles"), Mesh->GetNavMeshTilesCount() > 0);

			UNavigationSystemV1* Navigation = UNavigationSystemV1::GetCurrent(World);
			if (TestNotNull(TEXT("The loaded world has a navigation system"), Navigation))
			{
				FNavLocation Projected;
				TestTrue(TEXT("The enemy stands on the mesh"), Navigation->ProjectPointToNavigation(Enemies[0]->GetActorLocation(), Projected, FVector(100.0, 100.0, 200.0)));
				TestTrue(TEXT("The player start stands on the mesh"), Navigation->ProjectPointToNavigation(Starts[0]->GetActorLocation(), Projected, FVector(100.0, 100.0, 200.0)));
				const UNavigationPath* Path = UNavigationSystemV1::FindPathToLocationSynchronously(World, Enemies[0]->GetActorLocation(), Starts[0]->GetActorLocation(), Enemies[0]);
				if (TestNotNull(TEXT("A path query from the enemy to the player start returns a path"), Path))
				{
					TestTrue(TEXT("The path from the enemy to the player start is valid"), Path->IsValid());
					TestFalse(TEXT("The path from the enemy to the player start is complete, not partial"), Path->IsPartial());
				}
			}

			// Initialisation: the saved enemy is the production class with its controller, and begins play as the document requires.
			AAethelnEnemyCharacter* Enemy = Enemies[0];
			TestTrue(TEXT("The placed enemy is the production class"), Enemy->GetClass() == AAethelnEnemyCharacter::StaticClass());
			TestTrue(TEXT("The enemy uses the enemy controller class"), Enemy->AIControllerClass == AAethelnEnemyController::StaticClass());
			TestTrue(TEXT("The enemy is possessed when placed in the world"), Enemy->AutoPossessAI == EAutoPossessAI::PlacedInWorldOrSpawned);
			const FTransform Placed = Enemy->GetActorTransform();
			Enemy->SpawnDefaultController();
			TestTrue(TEXT("The enemy controller possesses the enemy"), Cast<AAethelnEnemyController>(Enemy->GetController()) != nullptr);
			Enemy->DispatchBeginPlay();
			TestTrue(TEXT("Home is the placed transform"), Enemy->GetHome().Equals(Placed, 0.01f));
			UAethelnAbilitySystemComponent* AbilitySystem = Enemy->GetAethelnAbilitySystemComponent();
			const FAethelnCombatAttributeInitValues& Initial = Enemy->ProvisionalInitialAttributes;
			TestTrue(TEXT("The provisional enemy Health is configured"), Initial.Health > 0.0f);
			TestEqual(TEXT("The enemy has its initial Health"), AbilitySystem->GetNumericAttribute(UAethelnCombatAttributeSet::GetHealthAttribute()), Initial.Health);
			TestTrue(TEXT("The enemy attack is granted"), AbilitySystem->GetActivatableAbilities().ContainsByPredicate(
				[](const FGameplayAbilitySpec& Spec) { return Cast<UAethelnEnemyAttackAbility>(Spec.Ability) != nullptr; }));
		}
	}
	// Release the map without saving it.
	UEditorLoadingAndSavingUtils::NewBlankMap(false);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnEnemyNavigationMeasurementsTest,
	"Aetheln.GameCombat.EnemyAI.NavigationMeasurements",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnEnemyNavigationMeasurementsTest::RunTest(const FString& Parameters)
{
	using namespace AethelnEnemyNavigationTests;
	// Measurements for #45, with no thresholds and no pass or fail on the numbers: they only record what the arena above
	// costs in this headless editor world on this machine. The logged lines start with AETHELN_MEASURE.
	FFixture F; if (!F.Init(*this)) { return false; }
	F.Player.PlayerState->SetPlayerId(1);
	F.Pawn->SetActorLocation(FVector(350.0, 0.0, PlayerHeight));
	FNavigation Navigation; if (!BuildArena(*this, *F.World.World, Navigation)) { return false; }
	// LogMemUsed logs the tile memory it returns, as a warning.
	AddExpectedMessage(TEXT("RecastNavMesh-Default: ARecastNavMesh:"), ELogVerbosity::Warning, EAutomationExpectedMessageFlags::Contains, 0);
	const int32 Tiles = Navigation.Mesh->GetNavMeshTilesCount();
	const int32 ActiveTiles = Navigation.Mesh->GetNumActiveTiles();
	const uint32 NavMeshBytes = Navigation.Mesh->LogMemUsed();
	const FString Mesh = FString::Printf(TEXT("AETHELN_MEASURE navmesh: arena 3000x1000 units, navigation init and Build %.2f ms, %d tiles (%d with data), %u bytes"),
		Navigation.InitAndBuildMilliseconds, Tiles, ActiveTiles, NavMeshBytes);
	AddInfo(Mesh);
	UE_LOG(LogTemp, Display, TEXT("%s"), *Mesh);

	// Server frame cost: world ticks at 60 Hz, first with no enemy, then with one enemy walking to the player and attacking.
	AAethelnEnemyCharacter* Enemy = nullptr;
	auto Measure = [&F, &Enemy](int32 Frames, double& OutAverageMicroseconds, double& OutWorstMicroseconds)
	{
		double Total = 0.0;
		OutWorstMicroseconds = 0.0;
		for (int32 Frame = 0; Frame < Frames; ++Frame)
		{
			const double Start = FPlatformTime::Seconds();
			if (Enemy != nullptr) { TickEnemyComponents(*Enemy, 1.0f / 60.0f); }
			F.AdvanceTo(F.World.World->GetTimeSeconds() + 1.0 / 60.0);
			const double Microseconds = (FPlatformTime::Seconds() - Start) * 1.0e6;
			Total += Microseconds;
			OutWorstMicroseconds = FMath::Max(OutWorstMicroseconds, Microseconds);
		}
		OutAverageMicroseconds = Total / Frames;
	};
	constexpr int32 Frames = 300;
	double Average = 0.0, Worst = 0.0;
	Measure(Frames, Average, Worst);
	const FString Empty = FString::Printf(TEXT("AETHELN_MEASURE frame, no enemy: %d frames of 1/60 s, average %.1f us, worst %.1f us"), Frames, Average, Worst);
	AddInfo(Empty);
	UE_LOG(LogTemp, Display, TEXT("%s"), *Empty);

	Enemy = SpawnWalkingEnemy(*this, *F.World.World, FVector(0.0, 0.0, EnemyHeight));
	if (Enemy == nullptr) { return false; }
	Measure(Frames, Average, Worst);
	const FString Engaged = FString::Printf(TEXT("AETHELN_MEASURE frame, one enemy engaging one player: %d frames of 1/60 s, average %.1f us, worst %.1f us"), Frames, Average, Worst);
	AddInfo(Engaged);
	UE_LOG(LogTemp, Display, TEXT("%s"), *Engaged);
	const AAethelnEnemyController* Controller = Cast<AAethelnEnemyController>(Enemy->GetController());
	TestTrue(TEXT("The enemy engaged during the measured frames"), Controller != nullptr && Controller->GetState() != EState::Idle);
	return true;
}

#endif
