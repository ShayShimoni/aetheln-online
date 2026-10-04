#pragma once

#include "AbilitySystemComponent.h"
#include "AttributeSet.h"
#include "CoreMinimal.h"
#include "AethelnCombatAttributeSet.generated.h"

/** Static attribute accessor plus current-value getter. Deliberately no setter or initter. */
#define AETHELN_ATTRIBUTE_GETTERS(ClassName, PropertyName) \
	GAMEPLAYATTRIBUTE_PROPERTY_GETTER(ClassName, PropertyName) \
	GAMEPLAYATTRIBUTE_VALUE_GETTER(PropertyName)

/**
 * Prototype combat resources: Health, Endurance and Guard, each with its maximum
 * (combat.resource.health, combat.resource.endurance, combat.resource.guard).
 * Only Gameplay Effects change them; the set's own clamps are the only direct
 * writes. All six replicate to the owner only (#61 decides what opponents see).
 */
UCLASS()
class GAMECOMBAT_API UAethelnCombatAttributeSet : public UAttributeSet
{
	GENERATED_BODY()

public:
	AETHELN_ATTRIBUTE_GETTERS(UAethelnCombatAttributeSet, Health)
	AETHELN_ATTRIBUTE_GETTERS(UAethelnCombatAttributeSet, MaxHealth)
	AETHELN_ATTRIBUTE_GETTERS(UAethelnCombatAttributeSet, Endurance)
	AETHELN_ATTRIBUTE_GETTERS(UAethelnCombatAttributeSet, MaxEndurance)
	AETHELN_ATTRIBUTE_GETTERS(UAethelnCombatAttributeSet, Guard)
	AETHELN_ATTRIBUTE_GETTERS(UAethelnCombatAttributeSet, MaxGuard)

	virtual void PreAttributeBaseChange(const FGameplayAttribute& Attribute, float& NewValue) const override;
	virtual void PreAttributeChange(const FGameplayAttribute& Attribute, float& NewValue) override;
	virtual void PostAttributeChange(const FGameplayAttribute& Attribute, float OldValue, float NewValue) override;
	virtual void PostGameplayEffectExecute(const FGameplayEffectModCallbackData& Data) override;
	virtual void GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const override;

private:
	/** Clamps a current value to [0, Max] and a maximum to >= 0. */
	void ClampAttribute(const FGameplayAttribute& Attribute, float& NewValue) const;

	/** The only direct write: used by the clamps above, never by gameplay code. */
	void SetClampedBaseValue(const FGameplayAttribute& Attribute, float NewValue);

	UFUNCTION()
	void OnRep_Health(const FGameplayAttributeData& PreviousValue);
	UFUNCTION()
	void OnRep_MaxHealth(const FGameplayAttributeData& PreviousValue);
	UFUNCTION()
	void OnRep_Endurance(const FGameplayAttributeData& PreviousValue);
	UFUNCTION()
	void OnRep_MaxEndurance(const FGameplayAttributeData& PreviousValue);
	UFUNCTION()
	void OnRep_Guard(const FGameplayAttributeData& PreviousValue);
	UFUNCTION()
	void OnRep_MaxGuard(const FGameplayAttributeData& PreviousValue);

	UPROPERTY(BlueprintReadOnly, ReplicatedUsing = OnRep_Health, Category = "Aetheln|Attributes", meta = (AllowPrivateAccess = "true"))
	FGameplayAttributeData Health;

	UPROPERTY(BlueprintReadOnly, ReplicatedUsing = OnRep_MaxHealth, Category = "Aetheln|Attributes", meta = (AllowPrivateAccess = "true"))
	FGameplayAttributeData MaxHealth;

	UPROPERTY(BlueprintReadOnly, ReplicatedUsing = OnRep_Endurance, Category = "Aetheln|Attributes", meta = (AllowPrivateAccess = "true"))
	FGameplayAttributeData Endurance;

	UPROPERTY(BlueprintReadOnly, ReplicatedUsing = OnRep_MaxEndurance, Category = "Aetheln|Attributes", meta = (AllowPrivateAccess = "true"))
	FGameplayAttributeData MaxEndurance;

	UPROPERTY(BlueprintReadOnly, ReplicatedUsing = OnRep_Guard, Category = "Aetheln|Attributes", meta = (AllowPrivateAccess = "true"))
	FGameplayAttributeData Guard;

	UPROPERTY(BlueprintReadOnly, ReplicatedUsing = OnRep_MaxGuard, Category = "Aetheln|Attributes", meta = (AllowPrivateAccess = "true"))
	FGameplayAttributeData MaxGuard;
};
