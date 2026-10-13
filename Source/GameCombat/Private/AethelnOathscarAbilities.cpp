#include "AethelnOathscarAbilities.h"

#include "AethelnGameplayTags.h"

UAethelnInstantStrikeAbility::UAethelnInstantStrikeAbility()
{
	SetAbilityId(AethelnGameplayTags::Ability_Oathscar_InstantStrike);
	SetCooldownTag(AethelnGameplayTags::Cooldown_Oathscar_InstantStrike);
	StepCount = 1;
	CommitmentTag = AethelnGameplayTags::State_Oathscar_InstantStrike;
	// The chain's constructor blocks and resets on a committed Instant Strike; this ability must not block itself.
	// Owner, 2026-10-13: it is refused inside the three-hit chain's commitment window, as dodge and block are.
	// The inherited grant rule makes the blocking tag also an authored reset tag.
	ActivationBlockedTags.RemoveTag(AethelnGameplayTags::State_Oathscar_InstantStrike);
	ResetTags.RemoveTag(AethelnGameplayTags::State_Oathscar_InstantStrike);
	ActivationBlockedTags.AddTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain);
	ResetTags.AddTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain);
}

const TCHAR* UAethelnInstantStrikeAbility::FindGrantProblem() const
{
	if (const TCHAR* Problem = Super::FindGrantProblem()) { return Problem; }
	// Owner, 2026-10-13: a relatively low cooldown. Its length is TBD; a zero cooldown is not a decision, so it fails closed.
	if (!(ProvisionalCooldownSeconds > 0.0f)) { return TEXT("has no cooldown"); }
	// The base guarantees exactly one valid step. Owner: pure damage, with no Guard drain, interruption, or knockback.
	if (ProvisionalSteps[0].GuardPressure != 0.0f || ProvisionalSteps[0].bInterruptsTarget) { return TEXT("is not pure damage"); }
	// Refused inside the chain's commitment window, and the blocking tag is an authored reset tag.
	if (!ActivationBlockedTags.HasTagExact(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain)
		|| !ResetTags.HasTagExact(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain))
	{
		return TEXT("is not refused inside the chain's commitment window");
	}
	return nullptr;
}
