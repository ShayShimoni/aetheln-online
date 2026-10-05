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

	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Cooldown_Oathscar_GateStep);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Cooldown_Oathscar_SwornRebuke);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(Cooldown_Oathscar_HoldTheLine);

	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(State_Dead);

	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Init_MaxHealth);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Init_Health);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Init_MaxEndurance);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Init_Endurance);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Init_MaxGuard);
	GAMECORE_API UE_DECLARE_GAMEPLAY_TAG_EXTERN(SetByCaller_Init_Guard);
}
