#pragma once

#include "AbilitySystemInterface.h"
#include "CoreMinimal.h"
#include "GameFramework/PlayerState.h"
#include "AethelnSpikePlayerState.generated.h"

class UAbilitySystemComponent;
class UAethelnSpikeAttributeSet;

UCLASS()
class GAMECOMBAT_API AAethelnSpikePlayerState : public APlayerState, public IAbilitySystemInterface
{
	GENERATED_BODY()

public:
	AAethelnSpikePlayerState();

	virtual UAbilitySystemComponent* GetAbilitySystemComponent() const override;
	UAethelnSpikeAttributeSet* GetSpikeAttributeSet() const;
	void InitializeAbilityActorInfo(AActor* AvatarActor);

private:
	UPROPERTY(VisibleAnywhere, Category = "Spike|Abilities")
	TObjectPtr<UAbilitySystemComponent> AbilitySystemComponent;

	UPROPERTY()
	TObjectPtr<UAethelnSpikeAttributeSet> AttributeSet;
};
