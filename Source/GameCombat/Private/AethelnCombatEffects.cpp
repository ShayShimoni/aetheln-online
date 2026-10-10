#include "AethelnCombatEffects.h"

#include "AbilitySystemComponent.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnGameplayTags.h"

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
