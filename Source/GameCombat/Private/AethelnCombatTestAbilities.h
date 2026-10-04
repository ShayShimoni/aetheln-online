#pragma once

#include "Abilities/GameplayAbility.h"
#include "CoreMinimal.h"
#include "AethelnCombatTestAbilities.generated.h"

/**
 * Test-only long-running ability for the #19 lifecycle automation tests. Only
 * those tests grant it. It uses the server-only policies the project abilities
 * will use, never commits, and stays active until cancelled. UHT parses only
 * headers, so the type cannot live in the test .cpp.
 */
UCLASS(NotBlueprintable, HideDropdown)
class UAethelnLongRunningTestAbility : public UGameplayAbility
{
	GENERATED_BODY()

public:
	UAethelnLongRunningTestAbility()
	{
		InstancingPolicy = EGameplayAbilityInstancingPolicy::InstancedPerActor;
		NetExecutionPolicy = EGameplayAbilityNetExecutionPolicy::ServerOnly;
		NetSecurityPolicy = EGameplayAbilityNetSecurityPolicy::ServerOnly;
	}

	virtual void ActivateAbility(
		const FGameplayAbilitySpecHandle Handle,
		const FGameplayAbilityActorInfo* ActorInfo,
		const FGameplayAbilityActivationInfo ActivationInfo,
		const FGameplayEventData* TriggerEventData) override
	{
		// Intentionally neither commits nor ends.
	}
};
