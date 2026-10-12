#pragma once

#include "AethelnEnemyAttackAbility.h"
#include "AethelnEnemyTestAbility.generated.h"

/** A valid enemy attack authored only in the Editor test module, never production tuning. */
UCLASS(NotBlueprintable, HideDropdown)
class UAethelnEnemyAttackTestAbility : public UAethelnEnemyAttackAbility
{
	GENERATED_BODY()

public:
	UAethelnEnemyAttackTestAbility()
	{
		ContentVersion = 1;
		ProvisionalMaxSampleDistance = 10.0;
		ProvisionalMaxSampleAngleDegrees = 5.0;
		ProvisionalStep.ActiveStart = 0.125;
		ProvisionalStep.ActiveEnd = 0.25;
		ProvisionalStep.BufferOpen = 0.625;
		ProvisionalStep.RecoveryEnd = 0.625;
		ProvisionalStep.CancelOpen = 0.5;
		ProvisionalStep.InterruptibleUntil = 0.25;
		ProvisionalStep.MaxAimPitchDegrees = 45.0;
		ProvisionalStep.ShapeExtent = FVector(10.0);
		ProvisionalStep.PathEnd.SetTranslation(FVector(30.0, 0.0, 0.0));
		ProvisionalStep.WroughtDamage = 5.0f;
		ProvisionalStep.MaxTargets = 4;
	}
};
