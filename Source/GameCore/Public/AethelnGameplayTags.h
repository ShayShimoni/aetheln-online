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
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Ability_Oathscar_SwordShieldBasicChain);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(State_Oathscar_SwordShieldBasicChain);

	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Cooldown_Oathscar_GateStep);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Cooldown_Oathscar_SwornRebuke);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Cooldown_Oathscar_HoldTheLine);

	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(State_Dead);

	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Damage_Wrought);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Damage_Wrought);

	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Init_MaxHealth);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Init_Health);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Init_MaxEndurance);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Init_Endurance);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Init_MaxGuard);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Init_Guard);

	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Cooldown_Duration);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Cost_Endurance);
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
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Ability_Test_Probe);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Ability_Test_Triggered);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Test_Trigger);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Test_ProbeActive);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Test_Blocking);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Test_Avoidance);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Test_Defending);
}
#endif
