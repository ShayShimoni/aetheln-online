#include "AethelnSpikeDamageEffect.h"

#include "AethelnSpikeAttributeSet.h"

UAethelnSpikeDamageEffect::UAethelnSpikeDamageEffect()
{
	DurationPolicy = EGameplayEffectDurationType::Instant;

	FGameplayModifierInfo& HealthModifier = Modifiers.AddDefaulted_GetRef();
	HealthModifier.Attribute = UAethelnSpikeAttributeSet::GetHealthAttribute();
	HealthModifier.ModifierOp = EGameplayModOp::Additive;
	// Private spike-only default. This remains provisional, not canonical damage tuning.
	HealthModifier.ModifierMagnitude = FScalableFloat(-25.0f);
}
