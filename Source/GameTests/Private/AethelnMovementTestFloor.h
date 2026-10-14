#pragma once

#include "Components/BoxComponent.h"
#include "Engine/CollisionProfile.h"
#include "GameFramework/Actor.h"
#include "AethelnMovementTestFloor.generated.h"

/**
 * A flat floor for the two-client movement test (#17). The CQTest map is empty, and a pawn standing on a floor that
 * replicates by network GUID (a default subobject of a replicated actor) keeps the engine's movement-base references
 * resolvable on every client. Authored only in the Editor test module; the size is a test fixture, not tuning.
 */
UCLASS(NotBlueprintable, HideDropdown)
class AAethelnMovementTestFloor : public AActor
{
	GENERATED_BODY()

public:
	AAethelnMovementTestFloor()
	{
		Box = CreateDefaultSubobject<UBoxComponent>(TEXT("Floor"));
		Box->SetBoxExtent(FVector(50000.0, 50000.0, 50.0));
		Box->SetMobility(EComponentMobility::Static);
		Box->SetCollisionProfileName(UCollisionProfile::BlockAll_ProfileName);
		SetRootComponent(Box);
		bReplicates = true;
		bAlwaysRelevant = true;
		SetReplicatingMovement(false);
	}

private:
	UPROPERTY()
	TObjectPtr<UBoxComponent> Box;
};
