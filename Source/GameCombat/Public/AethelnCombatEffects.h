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

/**
 * The shared ability cooldown. Its duration comes from SetByCaller.Cooldown.Duration;
 * the ability adds its own Cooldown.<Order>.<Name> tag to the spec's
 * DynamicGrantedTags, so one class serves every ability.
 */
UCLASS()
class GAMECOMBAT_API UAethelnCooldownEffect : public UGameplayEffect
{
	GENERATED_BODY()

public:
	UAethelnCooldownEffect();
};

/**
 * The shared Endurance cost: instant, adding SetByCaller.Cost.Endurance to
 * Endurance. A set-by-caller magnitude has no coefficient, so the ability
 * passes the negated cost.
 */
UCLASS()
class GAMECOMBAT_API UAethelnEnduranceCostEffect : public UGameplayEffect
{
	GENERATED_BODY()

public:
	UAethelnEnduranceCostEffect();
};

/**
 * The shared Wrought damage: instant, adding SetByCaller.Damage.Wrought to Health. A
 * set-by-caller magnitude has no coefficient, so the contact pipeline passes the negated
 * authored damage and adds Damage.Wrought as the spec's asset tag. It never touches a
 * maximum and has no duration (A18).
 */
UCLASS()
class GAMECOMBAT_API UAethelnDamageEffect : public UGameplayEffect
{
	GENERATED_BODY()

public:
	UAethelnDamageEffect();
};
