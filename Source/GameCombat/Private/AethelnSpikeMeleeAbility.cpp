#include "AethelnSpikeMeleeAbility.h"

#include "AethelnSpikeAuthorityComponent.h"
#include "GameFramework/Actor.h"

UAethelnSpikeMeleeAbility::UAethelnSpikeMeleeAbility()
{
	InstancingPolicy = EGameplayAbilityInstancingPolicy::InstancedPerActor;
	NetExecutionPolicy = EGameplayAbilityNetExecutionPolicy::ServerOnly;
}

void UAethelnSpikeMeleeAbility::ActivateAbility(
	const FGameplayAbilitySpecHandle Handle,
	const FGameplayAbilityActorInfo* ActorInfo,
	const FGameplayAbilityActivationInfo ActivationInfo,
	const FGameplayEventData* TriggerEventData)
{
	Super::ActivateAbility(Handle, ActorInfo, ActivationInfo, TriggerEventData);

	AActor* AvatarActor = ActorInfo != nullptr ? ActorInfo->AvatarActor.Get() : nullptr;
	UAethelnSpikeAuthorityComponent* AuthorityComponent =
		AvatarActor != nullptr ? AvatarActor->FindComponentByClass<UAethelnSpikeAuthorityComponent>() : nullptr;
	const bool bExecuted = AvatarActor != nullptr
		&& AvatarActor->HasAuthority()
		&& AuthorityComponent != nullptr
		&& AuthorityComponent->ExecuteActiveAttack();

	EndAbility(Handle, ActorInfo, ActivationInfo, true, !bExecuted);
}
