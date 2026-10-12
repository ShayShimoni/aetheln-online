#include "AethelnGameplayTags.h"

namespace AethelnGameplayTags
{
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Ability_Oathscar_GateStep, "Ability.Oathscar.GateStep", "order.oathscar.ability.gate_step");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Ability_Oathscar_SwornRebuke, "Ability.Oathscar.SwornRebuke", "order.oathscar.ability.sworn_rebuke");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Ability_Oathscar_HoldTheLine, "Ability.Oathscar.HoldTheLine", "order.oathscar.ability.hold_the_line");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Ability_Oathscar_SwordShieldBasicChain, "Ability.Oathscar.SwordShieldBasicChain", "order.oathscar.ability.sword_shield_basic_chain");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(State_Oathscar_SwordShieldBasicChain, "State.Oathscar.SwordShieldBasicChain", "Commitment state of order.oathscar.ability.sword_shield_basic_chain");

	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Cooldown_Oathscar_GateStep, "Cooldown.Oathscar.GateStep", "Cooldown state of order.oathscar.ability.gate_step");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Cooldown_Oathscar_SwornRebuke, "Cooldown.Oathscar.SwornRebuke", "Cooldown state of order.oathscar.ability.sworn_rebuke");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Cooldown_Oathscar_HoldTheLine, "Cooldown.Oathscar.HoldTheLine", "Cooldown state of order.oathscar.ability.hold_the_line");

	UE_DEFINE_GAMEPLAY_TAG_COMMENT(State_Dead, "State.Dead", "Death flow state. Declared by #19, applied and removed only by #21.");

	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Damage_Wrought, "Damage.Wrought", "combat.damage.wrought");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(SetByCaller_Damage_Wrought, "SetByCaller.Damage.Wrought", "Negated Wrought damage for the shared damage effect");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Ability_Dodge, "Ability.Dodge", "combat.action.dodge (proposed for #106)");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Cooldown_Dodge, "Cooldown.Dodge", "Cooldown state of combat.action.dodge");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(State_Dodging, "State.Dodging", "Server-owned dodge action state, [S, S + ActionEnd)");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(State_DodgeInvulnerable, "State.DodgeInvulnerable", "Server-owned dodge invulnerability window; gating and observers only, never an avoidance check");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Ability_Block, "Ability.Block", "combat.action.block (proposed for #106)");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Cooldown_Block, "Cooldown.Block", "Cooldown state of combat.action.block");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(State_Blocking, "State.Blocking", "Server-owned block state; gating and observers only, never a contact check");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(State_GuardBroken, "State.GuardBroken", "Server-owned Guard break state; blocks raising the block for the authored duration");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(SetByCaller_Pressure_Guard, "SetByCaller.Pressure.Guard", "Negated Guard pressure for the shared Guard pressure effect");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Ability_Enemy_Greybox_Strike, "Ability.Enemy.Greybox.Strike", "enemy.greybox.ability.strike");

	UE_DEFINE_GAMEPLAY_TAG_COMMENT(SetByCaller_Init_MaxHealth, "SetByCaller.Init.MaxHealth", "Initial MaxHealth magnitude for the attribute init effect");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(SetByCaller_Init_Health, "SetByCaller.Init.Health", "Initial Health magnitude for the attribute init effect");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(SetByCaller_Init_MaxEndurance, "SetByCaller.Init.MaxEndurance", "Initial MaxEndurance magnitude for the attribute init effect");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(SetByCaller_Init_Endurance, "SetByCaller.Init.Endurance", "Initial Endurance magnitude for the attribute init effect");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(SetByCaller_Init_MaxGuard, "SetByCaller.Init.MaxGuard", "Initial MaxGuard magnitude for the attribute init effect");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(SetByCaller_Init_Guard, "SetByCaller.Init.Guard", "Initial Guard magnitude for the attribute init effect");

	UE_DEFINE_GAMEPLAY_TAG_COMMENT(SetByCaller_Cooldown_Duration, "SetByCaller.Cooldown.Duration", "Cooldown duration in seconds for the shared cooldown effect");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(SetByCaller_Cost_Endurance, "SetByCaller.Cost.Endurance", "Negated Endurance cost for the shared cost effect");

	UE_DEFINE_GAMEPLAY_TAG_COMMENT(State_EnduranceRecoveryDelayed, "State.EnduranceRecoveryDelayed", "Server-owned delay after an Endurance cost commit; pauses Endurance recovery");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(State_GuardRecoveryDelayed, "State.GuardRecoveryDelayed", "Server-owned delay after Guard pressure; pauses Guard recovery");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(SetByCaller_Recovery_Amount, "SetByCaller.Recovery.Amount", "Amount one period of a recovery effect adds to its resource");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(SetByCaller_Recovery_Delay, "SetByCaller.Recovery.Delay", "Delay in seconds a spend restarts, carried on the active recovery effect's spec");
}

#if WITH_DEV_AUTOMATION_TESTS
namespace AethelnCombatTestTags
{
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Ability_Test_LongRunning, "Ability.Test.LongRunning", "Test-only identity of UAethelnLongRunningTestAbility");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Ability_Test_Probe, "Ability.Test.Probe", "Test-only identity of UAethelnSeamProbeTestAbility");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Ability_Test_Triggered, "Ability.Test.Triggered", "Test-only identity of UAethelnTriggeredTestAbility");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Test_Trigger, "Test.Trigger", "Test-only gameplay event that UAethelnTriggeredTestAbility responds to");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Test_ProbeActive, "Test.ProbeActive", "Test-only state tag held while the seam probe is active");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Test_Blocking, "Test.Blocking", "Test-only tag that blocks the seam probe");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Test_Avoidance, "Test.Avoidance", "Test-only tag placed in the contact pipeline's avoidance set");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Test_Defending, "Test.Defending", "Test-only state tag of a test defense state");
}
#endif
