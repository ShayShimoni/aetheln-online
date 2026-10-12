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

/**
 * The shared Guard pressure of a blocked contact (#18 Q7): instant, adding SetByCaller.Pressure.Guard to
 * Guard. The block's Guard hook passes the negated authored pressure and applies it from the attacker's
 * ASC. The attribute set clamps Guard at zero. It never touches a maximum and has no duration (A18).
 */
UCLASS()
class GAMECOMBAT_API UAethelnGuardPressureEffect : public UGameplayEffect
{
	GENERATED_BODY()

public:
	UAethelnGuardPressureEffect();
};

/**
 * Passive and delayed recovery of one resource (#292), read from config. Every value is TBD (#107);
 * a config entry is a named placeholder, never tuning. All zero means unset: no recovery.
 */
USTRUCT()
struct GAMECOMBAT_API FAethelnResourceRecoveryValues
{
	GENERATED_BODY()

	/** Amount recovered per second of server time while recovery runs. */
	UPROPERTY()
	float RatePerSecond = 0.0f;

	/** Server-time interval between recovery steps; each step adds RatePerSecond * PeriodSeconds. */
	UPROPERTY()
	float PeriodSeconds = 0.0f;

	/** Pause after each spend of the resource before recovery resumes. Zero: no pause. */
	UPROPERTY()
	float DelaySeconds = 0.0f;
};

/**
 * Passive and delayed recovery of one resource on the server clock (docs/gas-foundation.md, Resource
 * Recovery): an infinite periodic effect adding SetByCaller.Recovery.Amount to the resource each period.
 * It pauses while State.Dead or its own delay tag holds and, when the pause ends, resumes one full period
 * later. Only the server executes periods; clients receive the attribute values. The resource's maximum
 * caps it through the attribute set's clamp.
 */
UCLASS(Abstract)
class GAMECOMBAT_API UAethelnResourceRecoveryEffect : public UGameplayEffect
{
	GENERATED_BODY()

public:
	/**
	 * Server only. Applies the recovery once. Unset values apply nothing; values that are non-finite, negative,
	 * or a positive rate without a positive period log and apply nothing (fail closed).
	 */
	static FActiveGameplayEffectHandle Start(UAbilitySystemComponent& AbilitySystemComponent, TSubclassOf<UAethelnResourceRecoveryEffect> Recovery, const FAethelnResourceRecoveryValues& Values);

	/**
	 * Server only. Called after each spend of the recovery's resource: restarts its delay, so recovery
	 * resumes DelaySeconds after the latest spend. Without an active recovery or a delay, it does nothing.
	 */
	static void RestartDelay(UAbilitySystemComponent& AbilitySystemComponent, TSubclassOf<UAethelnResourceRecoveryEffect> Recovery);

	/** The tag the delay grants; it pauses this recovery. */
	FGameplayTag GetDelayTag() const { return DelayTag; }

protected:
	/** Called from a subclass constructor. */
	void Configure(const FGameplayAttribute& Attribute, const FGameplayTag& InDelayTag);

private:
	FGameplayTag DelayTag;
};

/** Endurance recovery; each Endurance cost commit restarts its delay. */
UCLASS()
class GAMECOMBAT_API UAethelnEnduranceRecoveryEffect : public UAethelnResourceRecoveryEffect
{
	GENERATED_BODY()

public:
	UAethelnEnduranceRecoveryEffect();
};

/** Guard recovery; each applied Guard pressure restarts its delay. */
UCLASS()
class GAMECOMBAT_API UAethelnGuardRecoveryEffect : public UAethelnResourceRecoveryEffect
{
	GENERATED_BODY()

public:
	UAethelnGuardRecoveryEffect();
};
