#include "AethelnSpikeAttributeSet.h"

#include "GameplayEffectExtension.h"
#include "Net/UnrealNetwork.h"

UAethelnSpikeAttributeSet::UAethelnSpikeAttributeSet()
{
	InitHealth(100.0f);
	InitMaxHealth(100.0f);
}

void UAethelnSpikeAttributeSet::PostGameplayEffectExecute(const FGameplayEffectModCallbackData& Data)
{
	Super::PostGameplayEffectExecute(Data);
	if (Data.EvaluatedData.Attribute == GetHealthAttribute())
	{
		SetHealth(FMath::Clamp(GetHealth(), 0.0f, GetMaxHealth()));
	}
}

void UAethelnSpikeAttributeSet::GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const
{
	Super::GetLifetimeReplicatedProps(OutLifetimeProps);
	DOREPLIFETIME_CONDITION_NOTIFY(UAethelnSpikeAttributeSet, Health, COND_None, REPNOTIFY_Always);
	DOREPLIFETIME_CONDITION_NOTIFY(UAethelnSpikeAttributeSet, MaxHealth, COND_None, REPNOTIFY_Always);
}

void UAethelnSpikeAttributeSet::OnRep_Health(const FGameplayAttributeData& PreviousValue)
{
	GAMEPLAYATTRIBUTE_REPNOTIFY(UAethelnSpikeAttributeSet, Health, PreviousValue);
}

void UAethelnSpikeAttributeSet::OnRep_MaxHealth(const FGameplayAttributeData& PreviousValue)
{
	GAMEPLAYATTRIBUTE_REPNOTIFY(UAethelnSpikeAttributeSet, MaxHealth, PreviousValue);
}
