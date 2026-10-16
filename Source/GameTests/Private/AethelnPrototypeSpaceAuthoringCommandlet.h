#pragma once

#include "Commandlets/Commandlet.h"
#include "AethelnPrototypeSpaceAuthoringCommandlet.generated.h"

/**
 * Issue #83 P4: adds the navigation bounds volume, builds the RecastNavMesh, and places the one greybox enemy in
 * /Game/Maps/MovementPOC, then saves the map. Run headless under the LFS lock on the map:
 * UnrealEditor-Cmd <project> -run=AethelnPrototypeSpaceAuthoring -unattended -nullrhi.
 * It refuses a map that already has a bounds volume, a RecastNavMesh, or an enemy, so it cannot duplicate them.
 */
UCLASS()
class UAethelnPrototypeSpaceAuthoringCommandlet : public UCommandlet
{
	GENERATED_BODY()

public:
	UAethelnPrototypeSpaceAuthoringCommandlet();

	virtual int32 Main(const FString& Params) override;
};
