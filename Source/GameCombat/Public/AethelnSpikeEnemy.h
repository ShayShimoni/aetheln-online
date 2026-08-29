#pragma once

#include "AbilitySystemInterface.h"
#include "CoreMinimal.h"
#include "GameFramework/Pawn.h"
#include "AethelnSpikeEnemy.generated.h"

class UAbilitySystemComponent;
class UAethelnSpikeAttributeSet;

UCLASS()
class GAMECOMBAT_API AAethelnSpikeEnemy : public APawn, public IAbilitySystemInterface
{
	GENERATED_BODY()

public:
	AAethelnSpikeEnemy();

	virtual UAbilitySystemComponent* GetAbilitySystemComponent() const override;
	UAethelnSpikeAttributeSet* GetSpikeAttributeSet() const { return AttributeSet; }
	float GetHealth() const;

protected:
	virtual void BeginPlay() override;

private:
	UPROPERTY(VisibleAnywhere, Category = "Spike|Abilities")
	TObjectPtr<UAbilitySystemComponent> AbilitySystemComponent;

	UPROPERTY()
	TObjectPtr<UAethelnSpikeAttributeSet> AttributeSet;
};
