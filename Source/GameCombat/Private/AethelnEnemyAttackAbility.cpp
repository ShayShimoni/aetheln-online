#include "AethelnEnemyAttackAbility.h"

#include "AethelnGameplayTags.h"

UAethelnEnemyAttackAbility::UAethelnEnemyAttackAbility()
{
	SetAbilityId(AethelnGameplayTags::Ability_Enemy_Greybox_Strike);
	// No authored step, version, or sampling preset. Unset production fails the grant.
}

const TCHAR* UAethelnEnemyAttackAbility::FindGrantProblem() const
{
	if (const TCHAR* Problem = Super::FindGrantProblem()) { return Problem; }
	if (ProvisionalEnduranceCost != 0.0f || ProvisionalCooldownSeconds != 0.0f || bAcceptsRelease)
	{
		return TEXT("has a cost, cooldown or Release route, but is never activated");
	}
	if (!FMath::IsFinite(ProvisionalMaxSampleDistance) || ProvisionalMaxSampleDistance <= 0.0
		|| !FMath::IsFinite(ProvisionalMaxSampleAngleDegrees) || ProvisionalMaxSampleAngleDegrees <= 0.0)
	{
		return TEXT("has unset or invalid sampling bounds");
	}
	return AethelnAttackTimeline::FindStepProblem(ProvisionalStep, true);
}

bool UAethelnEnemyAttackAbility::CanActivateAbility(FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo,
	const FGameplayTagContainer* SourceTags, const FGameplayTagContainer* TargetTags, FGameplayTagContainer* OptionalRelevantTags) const
{
	return false;
}
