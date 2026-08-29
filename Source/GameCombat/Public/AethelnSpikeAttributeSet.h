#pragma once

#include "AttributeSet.h"
#include "CoreMinimal.h"
#include "AbilitySystemComponent.h"
#include "AethelnSpikeAttributeSet.generated.h"

UCLASS()
class GAMECOMBAT_API UAethelnSpikeAttributeSet : public UAttributeSet
{
	GENERATED_BODY()

public:
	UAethelnSpikeAttributeSet();

	UPROPERTY(BlueprintReadOnly, ReplicatedUsing = OnRep_Health, Category = "Spike|Attributes")
	FGameplayAttributeData Health;
	ATTRIBUTE_ACCESSORS_BASIC(UAethelnSpikeAttributeSet, Health)

	UPROPERTY(BlueprintReadOnly, ReplicatedUsing = OnRep_MaxHealth, Category = "Spike|Attributes")
	FGameplayAttributeData MaxHealth;
	ATTRIBUTE_ACCESSORS_BASIC(UAethelnSpikeAttributeSet, MaxHealth)

	virtual void PostGameplayEffectExecute(const FGameplayEffectModCallbackData& Data) override;
	virtual void GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const override;

protected:
	UFUNCTION()
	void OnRep_Health(const FGameplayAttributeData& PreviousValue);

	UFUNCTION()
	void OnRep_MaxHealth(const FGameplayAttributeData& PreviousValue);
};
