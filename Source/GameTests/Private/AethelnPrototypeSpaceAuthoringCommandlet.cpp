#include "AethelnPrototypeSpaceAuthoringCommandlet.h"

#include "AI/NavigationSystemBase.h"
#include "ActorFactories/ActorFactory.h"
#include "AethelnEnemyCharacter.h"
#include "Builders/CubeBuilder.h"
#include "Components/BrushComponent.h"
#include "EngineUtils.h"
#include "FileHelpers.h"
#include "NavMesh/NavMeshBoundsVolume.h"
#include "NavMesh/RecastNavMesh.h"
#include "NavigationSystem.h"

DEFINE_LOG_CATEGORY_STATIC(LogAethelnPrototypeSpaceAuthoring, Log, All);

namespace
{
	const TCHAR* const MapPath = TEXT("/Game/Maps/MovementPOC");
	// The course is a 6000 unit square floor with its top at z = 0, walls to z = 350, and the tallest obstacle to z = 450
	// (docs/movement-poc.md). The volume spans the whole floor and 600 units of height from z = -100.
	const FVector VolumeCenter(0.0, 0.0, 200.0);
	const FVector VolumeSize(6000.0, 6000.0, 600.0);
	// Open floor between the raised platform and the camera obstacles, away from the player start. A character's actor
	// location is its capsule center, so z is the capsule half height above the floor top.
	const FVector EnemyLocation(-1000.0, 300.0, 90.0);
}

UAethelnPrototypeSpaceAuthoringCommandlet::UAethelnPrototypeSpaceAuthoringCommandlet()
{
	IsClient = false;
	IsEditor = true;
	IsServer = false;
	LogToConsole = true;
	ShowErrorCount = true;
	UseCommandletResultAsExitCode = true;
}

int32 UAethelnPrototypeSpaceAuthoringCommandlet::Main(const FString& Params)
{
	UWorld* World = UEditorLoadingAndSavingUtils::LoadMap(MapPath);
	if (World == nullptr)
	{
		UE_LOG(LogAethelnPrototypeSpaceAuthoring, Error, TEXT("Could not load %s."), MapPath);
		return 1;
	}
	if (TActorIterator<ANavMeshBoundsVolume>(World) || TActorIterator<ARecastNavMesh>(World) || TActorIterator<AAethelnEnemyCharacter>(World))
	{
		UE_LOG(LogAethelnPrototypeSpaceAuthoring, Error, TEXT("%s already has a bounds volume, a navigation mesh, or an enemy; refusing to add another."), MapPath);
		return 1;
	}

	ANavMeshBoundsVolume* Volume = World->SpawnActor<ANavMeshBoundsVolume>(VolumeCenter, FRotator::ZeroRotator);
	if (Volume == nullptr)
	{
		UE_LOG(LogAethelnPrototypeSpaceAuthoring, Error, TEXT("The bounds volume did not spawn."));
		return 1;
	}
	// The editor's volume factories build the brush as a box of the real size at scale 1; do the same.
	UCubeBuilder* Builder = NewObject<UCubeBuilder>();
	Builder->X = static_cast<float>(VolumeSize.X);
	Builder->Y = static_cast<float>(VolumeSize.Y);
	Builder->Z = static_cast<float>(VolumeSize.Z);
	UActorFactory::CreateBrushForVolumeActor(Volume, Builder);
	Volume->GetBrushComponent()->UpdateBounds();
	Volume->SetActorLabel(TEXT("MovementPOC_NavBounds"));
	Volume->SetFolderPath(TEXT("POC/Navigation"));

	FActorSpawnParameters Parameters;
	Parameters.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
	AAethelnEnemyCharacter* Enemy = World->SpawnActor<AAethelnEnemyCharacter>(AAethelnEnemyCharacter::StaticClass(), FTransform(EnemyLocation), Parameters);
	if (Enemy == nullptr)
	{
		UE_LOG(LogAethelnPrototypeSpaceAuthoring, Error, TEXT("The enemy did not spawn."));
		return 1;
	}
	Enemy->SetActorLabel(TEXT("MovementPOC_GreyboxEnemy"));
	Enemy->SetFolderPath(TEXT("POC/Enemy"));

	UNavigationSystemV1* Navigation = UNavigationSystemV1::GetCurrent(World);
	if (Navigation == nullptr)
	{
		FNavigationSystem::AddNavigationSystemToWorld(*World, FNavigationSystemRunMode::EditorMode);
		Navigation = UNavigationSystemV1::GetCurrent(World);
	}
	if (Navigation == nullptr)
	{
		UE_LOG(LogAethelnPrototypeSpaceAuthoring, Error, TEXT("The world has no navigation system."));
		return 1;
	}
	// A map load in an editor world leaves its async-load lock on until the Editor's tick releases it, and a commandlet
	// never ticks that far; Build() refuses to run while it is held.
	Navigation->RemoveNavigationBuildLock(ENavigationBuildLock::AsyncLoadLock, UNavigationSystemV1::ELockRemovalRebuildAction::NoRebuild);
	// The new volume registers with the navigation system on its tick, which a commandlet does not run.
	for (int32 Tick = 0; Tick < 3; ++Tick) { Navigation->Tick(0.1f); }
	const double BuildStart = FPlatformTime::Seconds();
	Navigation->Build();
	const double BuildMilliseconds = (FPlatformTime::Seconds() - BuildStart) * 1000.0;
	ARecastNavMesh* Mesh = Cast<ARecastNavMesh>(Navigation->GetDefaultNavDataInstance(FNavigationSystem::DontCreate));
	if (Mesh == nullptr || Mesh->GetNavMeshTilesCount() <= 0)
	{
		UE_LOG(LogAethelnPrototypeSpaceAuthoring, Error, TEXT("The navigation build produced no RecastNavMesh tiles."));
		return 1;
	}
	UE_LOG(LogAethelnPrototypeSpaceAuthoring, Display, TEXT("AETHELN_MEASURE MovementPOC navmesh: Build %.1f ms, %d tiles (%d with data), runtime generation mode %d"),
		BuildMilliseconds, Mesh->GetNavMeshTilesCount(), Mesh->GetNumActiveTiles(), static_cast<int32>(Mesh->GetRuntimeGenerationMode()));

	if (!UEditorLoadingAndSavingUtils::SaveMap(World, MapPath))
	{
		UE_LOG(LogAethelnPrototypeSpaceAuthoring, Error, TEXT("Could not save %s."), MapPath);
		return 1;
	}
	UE_LOG(LogAethelnPrototypeSpaceAuthoring, Display, TEXT("Saved %s with the bounds volume, the navigation mesh, and the greybox enemy."), MapPath);
	return 0;
}
