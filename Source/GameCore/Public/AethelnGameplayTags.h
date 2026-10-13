#pragma once

#include "CoreMinimal.h"
#include "NativeGameplayTags.h"

/**
 * Authoritative native Gameplay Tags (Issue #19). The conventions and the tag to
 * semantic ID mapping are in docs/combat-and-networking-architecture.md
 * ("Gameplay Tag and Content-Version Conventions"). Working names are not final
 * display names.
 */
namespace AethelnGameplayTags
{
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Ability_Oathscar_GateStep);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Ability_Oathscar_SwornRebuke);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Ability_Oathscar_HoldTheLine);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Ability_Oathscar_InstantStrike);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Ability_Oathscar_SwordShieldBasicChain);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(State_Oathscar_SwordShieldBasicChain);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(State_Oathscar_InstantStrike);

	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Cooldown_Oathscar_InstantStrike);

	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Cooldown_Oathscar_GateStep);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Cooldown_Oathscar_SwornRebuke);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Cooldown_Oathscar_HoldTheLine);

	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(State_Dead);

	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Damage_Wrought);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Damage_Wrought);
	// #18 shared dodge (<Family>.<Name>); its semantic ID is proposed for #106 (Q13).
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Ability_Dodge);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Cooldown_Dodge);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(State_Dodging);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(State_DodgeInvulnerable);
	// #18 shared block; its semantic ID is proposed for #106 (Q13).
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Ability_Block);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Cooldown_Block);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(State_Blocking);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(State_GuardBroken);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Pressure_Guard);
	// #83 prototype enemy attack, enemy.greybox.ability.strike (working name): enemy-scoped IDs map to <Family>.Enemy.<Enemy>.<Name>.
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Ability_Enemy_Greybox_Strike);

	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Init_MaxHealth);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Init_Health);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Init_MaxEndurance);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Init_Endurance);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Init_MaxGuard);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Init_Guard);

	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Cooldown_Duration);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Cost_Endurance);

	// #292 passive and delayed resource recovery.
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(State_EnduranceRecoveryDelayed);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(State_GuardRecoveryDelayed);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Recovery_Amount);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Recovery_Delay);
}

#if WITH_DEV_AUTOMATION_TESTS
/**
 * Test-only tags for the #19 automation tests (Source/GameTests). They are not
 * content and map to no semantic ID. The engine accepts native tags only from
 * Runtime modules, and client and server tag sets must match, so they live here
 * rather than in the editor-only GameTests module; Shipping builds carry none.
 */
namespace AethelnCombatTestTags
{
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Ability_Test_LongRunning);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Ability_Test_CostCommit);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Ability_Test_Probe);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Ability_Test_Triggered);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Test_Trigger);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Test_ProbeActive);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Test_Blocking);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Test_Avoidance);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Test_Defending);
}
#endif
