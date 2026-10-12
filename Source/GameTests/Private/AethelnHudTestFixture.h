#pragma once

#include "AethelnHudSource.h"
#include "CoreMinimal.h"
#include "UObject/Object.h"
#include "AethelnHudTestFixture.generated.h"

/**
 * Test-only objective source for the #61 HUD tests; #4 owns the real objective owner.
 * No WITH_DEV_AUTOMATION_TESTS guard, for the reason in AethelnCombatTestAbilities.h.
 */
UCLASS(Transient, NotBlueprintable, HideDropdown)
class UAethelnHudObjectiveTestFixture : public UObject, public IAethelnHudObjectiveSource
{
	GENERATED_BODY()

public:
	virtual FAethelnHudObjective GetHudObjective() const override { return Objective; }

	FAethelnHudObjective Objective;
};
