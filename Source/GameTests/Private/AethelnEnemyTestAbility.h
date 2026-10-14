#pragma once

#include "AethelnEnemyAttackAbility.h"
#include "AethelnEnemyTestAbility.generated.h"

/**
 * The production enemy attack with its definition cleared, which is what unset config looks like. Config loads after
 * the constructor and a subclass also reads its parent's section, so the values are cleared in PostInitProperties.
 */
UCLASS(NotBlueprintable, HideDropdown)
class UAethelnEnemyAttackUnsetTestAbility : public UAethelnEnemyAttackAbility
{
	GENERATED_BODY()

public:
	virtual void PostInitProperties() override
	{
		Super::PostInitProperties();
		ContentVersion = 0;
		ProvisionalMaxSampleDistance = 0.0;
		ProvisionalMaxSampleAngleDegrees = 0.0;
		ProvisionalStep = FAethelnAttackStepDefinition();
	}
};
