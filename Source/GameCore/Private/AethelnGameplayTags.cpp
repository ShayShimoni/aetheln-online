#include "AethelnGameplayTags.h"

namespace AethelnGameplayTags
{
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Ability_Oathscar_GateStep, "Ability.Oathscar.GateStep", "order.oathscar.ability.gate_step");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Ability_Oathscar_SwornRebuke, "Ability.Oathscar.SwornRebuke", "order.oathscar.ability.sworn_rebuke");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Ability_Oathscar_HoldTheLine, "Ability.Oathscar.HoldTheLine", "order.oathscar.ability.hold_the_line");

	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Cooldown_Oathscar_GateStep, "Cooldown.Oathscar.GateStep", "Cooldown state of order.oathscar.ability.gate_step");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Cooldown_Oathscar_SwornRebuke, "Cooldown.Oathscar.SwornRebuke", "Cooldown state of order.oathscar.ability.sworn_rebuke");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Cooldown_Oathscar_HoldTheLine, "Cooldown.Oathscar.HoldTheLine", "Cooldown state of order.oathscar.ability.hold_the_line");

	UE_DEFINE_GAMEPLAY_TAG_COMMENT(State_Dead, "State.Dead", "Death flow state. Declared by #19, applied and removed only by #21.");

	UE_DEFINE_GAMEPLAY_TAG_COMMENT(SetByCaller_Init_MaxHealth, "SetByCaller.Init.MaxHealth", "Initial MaxHealth magnitude for the attribute init effect");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(SetByCaller_Init_Health, "SetByCaller.Init.Health", "Initial Health magnitude for the attribute init effect");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(SetByCaller_Init_MaxEndurance, "SetByCaller.Init.MaxEndurance", "Initial MaxEndurance magnitude for the attribute init effect");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(SetByCaller_Init_Endurance, "SetByCaller.Init.Endurance", "Initial Endurance magnitude for the attribute init effect");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(SetByCaller_Init_MaxGuard, "SetByCaller.Init.MaxGuard", "Initial MaxGuard magnitude for the attribute init effect");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(SetByCaller_Init_Guard, "SetByCaller.Init.Guard", "Initial Guard magnitude for the attribute init effect");
}
