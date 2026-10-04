#pragma once

#include "CoreMinimal.h"
#include "GameplayEffect.h"
#include "AethelnCombatEffects.generated.h"

class UAbilitySystemComponent;

/**
 * Initial combat attribute values, read from config. Every value is TBD
 * (#107, #45); a config entry is a named placeholder, never tuning.
 */
USTRUCT()
struct GAMECOMBAT_API FAethelnCombatAttributeInitValues
{
	GENERATED_BODY()

	UPROPERTY()
	float MaxHealth = 0.0f;

	UPROPERTY()
	float Health = 0.0f;

	UPROPERTY()
	float MaxEndurance = 0.0f;

	UPROPERTY()
	float Endurance = 0.0f;

	UPROPERTY()
	float MaxGuard = 0.0f;

	UPROPERTY()
	float Guard = 0.0f;
};

/**
 * Instant effect that overrides all six combat attributes from set-by-caller
 * magnitudes. Every maximum is listed before any current value: attributes
 * start at 0, so a current value applied before its maximum would clamp to 0.
 */
UCLASS()
class GAMECOMBAT_API UAethelnAttributeInitEffect : public UGameplayEffect
{
	GENERATED_BODY()

public:
	UAethelnAttributeInitEffect();

	/** Server only. Applies the initial values through this effect. */
	static void ApplyTo(UAbilitySystemComponent& AbilitySystemComponent, const FAethelnCombatAttributeInitValues& Values);
};
