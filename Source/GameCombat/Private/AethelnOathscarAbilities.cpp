#include "AethelnOathscarAbilities.h"

#include "AethelnGameplayTags.h"

UAethelnGateStepAbility::UAethelnGateStepAbility()
{
	SetAbilityId(AethelnGameplayTags::Ability_Oathscar_GateStep);
	SetCooldownTag(AethelnGameplayTags::Cooldown_Oathscar_GateStep);
}

UAethelnSwornRebukeAbility::UAethelnSwornRebukeAbility()
{
	SetAbilityId(AethelnGameplayTags::Ability_Oathscar_SwornRebuke);
	SetCooldownTag(AethelnGameplayTags::Cooldown_Oathscar_SwornRebuke);
}

UAethelnHoldTheLineAbility::UAethelnHoldTheLineAbility()
{
	SetAbilityId(AethelnGameplayTags::Ability_Oathscar_HoldTheLine);
	SetCooldownTag(AethelnGameplayTags::Cooldown_Oathscar_HoldTheLine);
}
