#pragma once

#include "CoreMinimal.h"
#include "GameplayTagContainer.h"
#include "AethelnDefenseTypes.generated.h"

class UAethelnAbilitySystemComponent;

/** What the defense owner's Guard hook did with one blocked contact (docs/dodge-and-block.md, The Guard hook). */
enum class EAethelnBlockConsequence : uint8
{
	Blocked,
	GuardBroken
};

/** The blocked contact handed to the defense owner's hook, once per contact. Server only. */
struct FAethelnBlockedContact
{
	/** The attacker's ASC; the hook applies its effects from it. */
	TWeakObjectPtr<UAethelnAbilitySystemComponent> Source;
	FGuid ActivationId;
	FGameplayTag AbilityId;
	uint32 ContentVersion = 0;
	double ContactTime = 0.0;
	/** The attack step's authored pressure (Q7), TBD (#107). */
	float GuardPressure = 0.0f;
};

/**
 * Authored dodge definition (docs/dodge-and-block.md, Server-owned windows). Distance and
 * MoveDuration drive the predicted displacement in client move time; the three window values
 * are seconds after the server step S that accepted the dodge. Every value is TBD (#107);
 * the zero defaults fail grant validation.
 */
USTRUCT()
struct GAMECOMBAT_API FAethelnDodgeDefinition
{
	GENERATED_BODY()

	UPROPERTY()
	float Distance = 0.0f;

	UPROPERTY()
	float MoveDuration = 0.0f;

	/** Invulnerability is [S + InvulnerableStart, S + InvulnerableEnd) on server world time. */
	UPROPERTY()
	float InvulnerableStart = 0.0f;

	UPROPERTY()
	float InvulnerableEnd = 0.0f;

	/** The activation ends and State.Dodging is removed at S + ActionEnd. */
	UPROPERTY()
	float ActionEnd = 0.0f;
};
