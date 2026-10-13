#include "AethelnCombatEffects.h"

#include "AbilitySystemComponent.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnGameplayTags.h"
#include "GameplayEffectComponents/TargetTagRequirementsGameplayEffectComponent.h"

DEFINE_LOG_CATEGORY_STATIC(LogAethelnResourceRecovery, Log, All);

UAethelnAttributeInitEffect::UAethelnAttributeInitEffect()
{
	DurationPolicy = EGameplayEffectDurationType::Instant;

	auto AddOverride = [this](const FGameplayAttribute& Attribute, const FGameplayTag& DataTag)
	{
		FSetByCallerFloat SetByCaller;
		SetByCaller.DataTag = DataTag;

		FGameplayModifierInfo& Modifier = Modifiers.AddDefaulted_GetRef();
		Modifier.Attribute = Attribute;
		Modifier.ModifierOp = EGameplayModOp::Override;
		Modifier.ModifierMagnitude = FGameplayEffectModifierMagnitude(SetByCaller);
	};

	// Maxima first (see the class comment).
	AddOverride(UAethelnCombatAttributeSet::GetMaxHealthAttribute(), AethelnGameplayTags::SetByCaller_Init_MaxHealth);
	AddOverride(UAethelnCombatAttributeSet::GetMaxEnduranceAttribute(), AethelnGameplayTags::SetByCaller_Init_MaxEndurance);
	AddOverride(UAethelnCombatAttributeSet::GetMaxGuardAttribute(), AethelnGameplayTags::SetByCaller_Init_MaxGuard);
	AddOverride(UAethelnCombatAttributeSet::GetHealthAttribute(), AethelnGameplayTags::SetByCaller_Init_Health);
	AddOverride(UAethelnCombatAttributeSet::GetEnduranceAttribute(), AethelnGameplayTags::SetByCaller_Init_Endurance);
	AddOverride(UAethelnCombatAttributeSet::GetGuardAttribute(), AethelnGameplayTags::SetByCaller_Init_Guard);
}

void UAethelnAttributeInitEffect::ApplyTo(UAbilitySystemComponent& AbilitySystemComponent, const FAethelnCombatAttributeInitValues& Values)
{
	FGameplayEffectSpec Spec(GetDefault<UAethelnAttributeInitEffect>(), AbilitySystemComponent.MakeEffectContext(), 1.0f);
	Spec.SetSetByCallerMagnitude(AethelnGameplayTags::SetByCaller_Init_MaxHealth, Values.MaxHealth);
	Spec.SetSetByCallerMagnitude(AethelnGameplayTags::SetByCaller_Init_MaxEndurance, Values.MaxEndurance);
	Spec.SetSetByCallerMagnitude(AethelnGameplayTags::SetByCaller_Init_MaxGuard, Values.MaxGuard);
	Spec.SetSetByCallerMagnitude(AethelnGameplayTags::SetByCaller_Init_Health, Values.Health);
	Spec.SetSetByCallerMagnitude(AethelnGameplayTags::SetByCaller_Init_Endurance, Values.Endurance);
	Spec.SetSetByCallerMagnitude(AethelnGameplayTags::SetByCaller_Init_Guard, Values.Guard);
	AbilitySystemComponent.ApplyGameplayEffectSpecToSelf(Spec);
}

UAethelnCooldownEffect::UAethelnCooldownEffect()
{
	DurationPolicy = EGameplayEffectDurationType::HasDuration;

	FSetByCallerFloat Duration;
	Duration.DataTag = AethelnGameplayTags::SetByCaller_Cooldown_Duration;
	DurationMagnitude = FGameplayEffectModifierMagnitude(Duration);
}

UAethelnEnduranceCostEffect::UAethelnEnduranceCostEffect()
{
	DurationPolicy = EGameplayEffectDurationType::Instant;

	FSetByCallerFloat Cost;
	Cost.DataTag = AethelnGameplayTags::SetByCaller_Cost_Endurance;

	FGameplayModifierInfo& Modifier = Modifiers.AddDefaulted_GetRef();
	Modifier.Attribute = UAethelnCombatAttributeSet::GetEnduranceAttribute();
	Modifier.ModifierOp = EGameplayModOp::AddBase;
	Modifier.ModifierMagnitude = FGameplayEffectModifierMagnitude(Cost);
}

UAethelnDamageEffect::UAethelnDamageEffect()
{
	DurationPolicy = EGameplayEffectDurationType::Instant;

	FSetByCallerFloat Damage;
	Damage.DataTag = AethelnGameplayTags::SetByCaller_Damage_Wrought;

	FGameplayModifierInfo& Modifier = Modifiers.AddDefaulted_GetRef();
	Modifier.Attribute = UAethelnCombatAttributeSet::GetHealthAttribute();
	Modifier.ModifierOp = EGameplayModOp::AddBase;
	Modifier.ModifierMagnitude = FGameplayEffectModifierMagnitude(Damage);
}

UAethelnGuardPressureEffect::UAethelnGuardPressureEffect()
{
	DurationPolicy = EGameplayEffectDurationType::Instant;

	FSetByCallerFloat Pressure;
	Pressure.DataTag = AethelnGameplayTags::SetByCaller_Pressure_Guard;

	FGameplayModifierInfo& Modifier = Modifiers.AddDefaulted_GetRef();
	Modifier.Attribute = UAethelnCombatAttributeSet::GetGuardAttribute();
	Modifier.ModifierOp = EGameplayModOp::AddBase;
	Modifier.ModifierMagnitude = FGameplayEffectModifierMagnitude(Pressure);
}

void UAethelnResourceRecoveryEffect::Configure(const FGameplayAttribute& Attribute, const FGameplayTag& InDelayTag)
{
	DelayTag = InDelayTag;
	DurationPolicy = EGameplayEffectDurationType::Infinite;
	// The period comes from config on each spec; the first step lands one period after the start or a pause.
	bExecutePeriodicEffectOnApplication = false;
	PeriodicInhibitionPolicy = EGameplayEffectPeriodInhibitionRemovedPolicy::ResetPeriod;

	FSetByCallerFloat Amount;
	Amount.DataTag = AethelnGameplayTags::SetByCaller_Recovery_Amount;
	FGameplayModifierInfo& Modifier = Modifiers.AddDefaulted_GetRef();
	Modifier.Attribute = Attribute;
	Modifier.ModifierOp = EGameplayModOp::AddBase;
	Modifier.ModifierMagnitude = FGameplayEffectModifierMagnitude(Amount);

	// Native GE components must be default subobjects listed in GEComponents during construction.
	UTargetTagRequirementsGameplayEffectComponent* Pause = CreateDefaultSubobject<UTargetTagRequirementsGameplayEffectComponent>(TEXT("RecoveryPause"));
	Pause->OngoingTagRequirements.IgnoreTags.AddTag(AethelnGameplayTags::State_Dead);
	Pause->OngoingTagRequirements.IgnoreTags.AddTag(DelayTag);
	GEComponents.Add(Pause);
}

FActiveGameplayEffectHandle UAethelnResourceRecoveryEffect::Start(UAbilitySystemComponent& AbilitySystemComponent, TSubclassOf<UAethelnResourceRecoveryEffect> Recovery, const FAethelnResourceRecoveryValues& Values)
{
	if (Recovery == nullptr || !AbilitySystemComponent.IsOwnerActorAuthoritative()
		|| (Values.RatePerSecond == 0.0f && Values.PeriodSeconds == 0.0f && Values.DelaySeconds == 0.0f))
	{
		return FActiveGameplayEffectHandle();
	}
	if (!FMath::IsFinite(Values.RatePerSecond) || !FMath::IsFinite(Values.PeriodSeconds) || !FMath::IsFinite(Values.DelaySeconds)
		|| !(Values.RatePerSecond > 0.0f) || !(Values.PeriodSeconds > 0.0f) || Values.DelaySeconds < 0.0f)
	{
		UE_LOG(LogAethelnResourceRecovery, Warning, TEXT("Refused to start %s: rate %f, period %f, delay %f must be finite, with a positive rate and period and a non-negative delay."),
			*GetNameSafe(Recovery), Values.RatePerSecond, Values.PeriodSeconds, Values.DelaySeconds);
		return FActiveGameplayEffectHandle();
	}
	FGameplayEffectSpec Spec(Recovery.GetDefaultObject(), AbilitySystemComponent.MakeEffectContext(), 1.0f);
	Spec.Period = Values.PeriodSeconds;
	Spec.SetSetByCallerMagnitude(AethelnGameplayTags::SetByCaller_Recovery_Amount, Values.RatePerSecond * Values.PeriodSeconds);
	Spec.SetSetByCallerMagnitude(AethelnGameplayTags::SetByCaller_Recovery_Delay, Values.DelaySeconds);
	return AbilitySystemComponent.ApplyGameplayEffectSpecToSelf(Spec);
}

void UAethelnResourceRecoveryEffect::RestartDelay(UAbilitySystemComponent& AbilitySystemComponent, TSubclassOf<UAethelnResourceRecoveryEffect> Recovery)
{
	if (Recovery == nullptr || !AbilitySystemComponent.IsOwnerActorAuthoritative())
	{
		return;
	}
	FGameplayEffectQuery Query;
	Query.EffectDefinition = Recovery;
	const TArray<FActiveGameplayEffectHandle> Active = AbilitySystemComponent.GetActiveEffects(Query);
	const FActiveGameplayEffect* Running = Active.Num() > 0 ? AbilitySystemComponent.GetActiveGameplayEffect(Active[0]) : nullptr;
	const float Delay = Running != nullptr ? Running->Spec.GetSetByCallerMagnitude(AethelnGameplayTags::SetByCaller_Recovery_Delay, false, 0.0f) : 0.0f;
	// A zero duration would never expire, so no delay applies nothing.
	if (!(Delay > 0.0f))
	{
		return;
	}
	// Restart, never stack: the delay ends DelaySeconds after the latest spend.
	const FGameplayTag Tag = Recovery.GetDefaultObject()->GetDelayTag();
	AbilitySystemComponent.RemoveActiveEffectsWithGrantedTags(FGameplayTagContainer(Tag));
	// The shared duration effect, as a cooldown or a Guard break is applied.
	FGameplayEffectSpec Spec(GetDefault<UAethelnCooldownEffect>(), AbilitySystemComponent.MakeEffectContext(), 1.0f);
	Spec.SetSetByCallerMagnitude(AethelnGameplayTags::SetByCaller_Cooldown_Duration, Delay);
	Spec.DynamicGrantedTags.AddTag(Tag);
	AbilitySystemComponent.ApplyGameplayEffectSpecToSelf(Spec);
}

UAethelnEnduranceRecoveryEffect::UAethelnEnduranceRecoveryEffect()
{
	Configure(UAethelnCombatAttributeSet::GetEnduranceAttribute(), AethelnGameplayTags::State_EnduranceRecoveryDelayed);
}

UAethelnGuardRecoveryEffect::UAethelnGuardRecoveryEffect()
{
	Configure(UAethelnCombatAttributeSet::GetGuardAttribute(), AethelnGameplayTags::State_GuardRecoveryDelayed);
}

UAethelnDeathStateEffect::UAethelnDeathStateEffect()
{
	DurationPolicy = EGameplayEffectDurationType::Infinite;
}

void UAethelnDeathStateEffect::ApplyTo(UAbilitySystemComponent& AbilitySystemComponent)
{
	FGameplayEffectSpec Spec(GetDefault<UAethelnDeathStateEffect>(), AbilitySystemComponent.MakeEffectContext(), 1.0f);
	Spec.DynamicGrantedTags.AddTag(AethelnGameplayTags::State_Dead);
	AbilitySystemComponent.ApplyGameplayEffectSpecToSelf(Spec);
}

void UAethelnDeathStateEffect::RemoveFrom(UAbilitySystemComponent& AbilitySystemComponent)
{
	// By class: an owning-tag query reads the definition's tags only, not the spec's dynamic granted State.Dead.
	FGameplayEffectQuery Query;
	Query.EffectDefinition = UAethelnDeathStateEffect::StaticClass();
	AbilitySystemComponent.RemoveActiveEffects(Query);
}

UAethelnRespawnRestorationEffect::UAethelnRespawnRestorationEffect()
{
	DurationPolicy = EGameplayEffectDurationType::Instant;

	auto AddRestore = [this](const FGameplayAttribute& Current, const FGameplayAttribute& Maximum)
	{
		FAttributeBasedFloat Based;
		Based.BackingAttribute = FGameplayEffectAttributeCaptureDefinition(Maximum, EGameplayEffectAttributeCaptureSource::Target, false);

		FGameplayModifierInfo& Modifier = Modifiers.AddDefaulted_GetRef();
		Modifier.Attribute = Current;
		Modifier.ModifierOp = EGameplayModOp::Override;
		Modifier.ModifierMagnitude = FGameplayEffectModifierMagnitude(Based);
	};
	AddRestore(UAethelnCombatAttributeSet::GetHealthAttribute(), UAethelnCombatAttributeSet::GetMaxHealthAttribute());
	AddRestore(UAethelnCombatAttributeSet::GetEnduranceAttribute(), UAethelnCombatAttributeSet::GetMaxEnduranceAttribute());
	AddRestore(UAethelnCombatAttributeSet::GetGuardAttribute(), UAethelnCombatAttributeSet::GetMaxGuardAttribute());
}

void UAethelnRespawnRestorationEffect::ApplyTo(UAbilitySystemComponent& AbilitySystemComponent)
{
	FGameplayEffectSpec Spec(GetDefault<UAethelnRespawnRestorationEffect>(), AbilitySystemComponent.MakeEffectContext(), 1.0f);
	AbilitySystemComponent.ApplyGameplayEffectSpecToSelf(Spec);
}
