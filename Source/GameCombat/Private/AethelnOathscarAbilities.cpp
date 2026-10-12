#include "AethelnOathscarAbilities.h"

#include "AethelnGameplayTags.h"

UAethelnGateStepAbility::UAethelnGateStepAbility()
{
	SetAbilityId(AethelnGameplayTags::Ability_Oathscar_GateStep);
	SetCooldownTag(AethelnGameplayTags::Cooldown_Oathscar_GateStep);
	StepCount = 1;
	CommitmentTag = AethelnGameplayTags::State_Oathscar_GateStep;
}

UAethelnSwornRebukeAbility::UAethelnSwornRebukeAbility()
{
	SetAbilityId(AethelnGameplayTags::Ability_Oathscar_SwornRebuke);
	SetCooldownTag(AethelnGameplayTags::Cooldown_Oathscar_SwornRebuke);
	StepCount = 1;
	CommitmentTag = AethelnGameplayTags::State_Oathscar_SwornRebuke;
}

UAethelnHoldTheLineAbility::UAethelnHoldTheLineAbility()
{
	SetAbilityId(AethelnGameplayTags::Ability_Oathscar_HoldTheLine);
	SetCooldownTag(AethelnGameplayTags::Cooldown_Oathscar_HoldTheLine);
	DefenseStateTag = AethelnGameplayTags::State_Oathscar_HoldTheLine;
	// #18 Q10: Block and Hold the Line block each other.
	ActivationBlockedTags.RemoveTag(AethelnGameplayTags::State_Oathscar_HoldTheLine);
	ActivationBlockedTags.AddTag(AethelnGameplayTags::State_Blocking);
}
