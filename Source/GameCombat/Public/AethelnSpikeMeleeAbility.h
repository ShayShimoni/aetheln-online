#pragma once

#include "Abilities/GameplayAbility.h"
#include "CoreMinimal.h"
#include "AethelnSpikeMeleeAbility.generated.h"

UCLASS()
class GAMECOMBAT_API UAethelnSpikeMeleeAbility : public UGameplayAbility
{
	GENERATED_BODY()

public:
	UAethelnSpikeMeleeAbility();

	virtual void ActivateAbility(
		const FGameplayAbilitySpecHandle Handle,
		const FGameplayAbilityActorInfo* ActorInfo,
		const FGameplayAbilityActivationInfo ActivationInfo,
		const FGameplayEventData* TriggerEventData) override;
};
