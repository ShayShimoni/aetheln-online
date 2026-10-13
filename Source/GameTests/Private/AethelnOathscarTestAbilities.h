#pragma once

#include "AethelnOathscarAbilities.h"
#include "AethelnOathscarTestAbilities.generated.h"

/*
 * Valid representative actives authored only in the Editor test module (#260). Every number
 * is a test fixture chosen for exact binary time arithmetic and the chain fixture's geometry,
 * never tuning (#107 owns the values). The single step matches the chain fixture's first step,
 * with the final-step rule (BufferOpen == RecoveryEnd, no link window). The values are applied in
 * PostInitProperties: a class default object reads its parent classes' config sections after the
 * constructor, so the production sections in DefaultGame.ini would otherwise override them.
 */
namespace AethelnOathscarTestValues
{
	inline FAethelnAttackStepDefinition MakeStep()
	{
		FAethelnAttackStepDefinition Step;
		Step.ActiveStart = 0.125; Step.ActiveEnd = 0.25;
		Step.BufferOpen = 0.625; Step.RecoveryEnd = 0.625; Step.CancelOpen = 0.5;
		Step.MaxAimPitchDegrees = 45.0;
		Step.ShapeExtent = FVector(10.0);
		Step.PathEnd.SetTranslation(FVector(30.0, 0.0, 0.0));
		Step.WroughtDamage = 5.0f;
		Step.MaxTargets = 4;
		return Step;
	}
}

UCLASS(NotBlueprintable, HideDropdown)
class UAethelnInstantStrikeTestAbility : public UAethelnInstantStrikeAbility
{
	GENERATED_BODY()

public:
	virtual void PostInitProperties() override
	{
		Super::PostInitProperties();
		ContentVersion = 1;
		ProvisionalEnduranceCost = 2.0f;
		ProvisionalCooldownSeconds = 0.875f;
		ProvisionalMaxSampleDistance = 10.0;
		ProvisionalMaxSampleAngleDegrees = 5.0;
		ProvisionalSteps = { AethelnOathscarTestValues::MakeStep() };
	}

	const FGameplayTagContainer& GetBlockedTagsForTests() const { return ActivationBlockedTags; }
	void SetBlockedTagsForTests(const FGameplayTagContainer& Tags) { ActivationBlockedTags = Tags; }
};
