#pragma once

#include "AethelnDodgeAbility.h"
#include "AethelnDodgeTestAbility.generated.h"

/**
 * A valid dodge authored only in the Editor test module. Every number is a test
 * fixture chosen for exact binary time arithmetic, never tuning (#107 owns the values).
 */
UCLASS(NotBlueprintable, HideDropdown)
class UAethelnDodgeTestAbility : public UAethelnDodgeAbility
{
	GENERATED_BODY()

public:
	UAethelnDodgeTestAbility()
	{
		ContentVersion = 1;
		ProvisionalEnduranceCost = 5.0f;
		ProvisionalCooldownSeconds = 1.0f;
		ProvisionalDodge.Distance = 120.0f;
		ProvisionalDodge.MoveDuration = 0.25f;
		ProvisionalDodge.InvulnerableStart = 0.0625f;
		ProvisionalDodge.InvulnerableEnd = 0.3125f;
		ProvisionalDodge.ActionEnd = 0.5f;
	}

	void SetMovementCarriedForTests(bool bValue) { bMovementCarried = bValue; }
	void SetBlockedTagsForTests(const FGameplayTagContainer& Tags) { ActivationBlockedTags = Tags; }
	FGuid GetOperationIdForTests() const { return GetActivationOperationId(); }
	bool bFailCommitForTests = false;

	virtual bool CommitCheck(const FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo, const FGameplayAbilityActivationInfo ActivationInfo, FGameplayTagContainer* OptionalRelevantTags = nullptr) override
	{
		return !bFailCommitForTests && Super::CommitCheck(Handle, ActorInfo, ActivationInfo, OptionalRelevantTags);
	}
};
