#include "AethelnSpikePlayerState.h"

#include "AbilitySystemComponent.h"
#include "AethelnSpikeAttributeSet.h"
#include "AethelnSpikeMeleeAbility.h"

AAethelnSpikePlayerState::AAethelnSpikePlayerState()
{
	SetReplicates(true);
	AbilitySystemComponent = CreateDefaultSubobject<UAbilitySystemComponent>(TEXT("AbilitySystemComponent"));
	AbilitySystemComponent->SetIsReplicated(true);
	AbilitySystemComponent->SetReplicationMode(EGameplayEffectReplicationMode::Mixed);
	AttributeSet = CreateDefaultSubobject<UAethelnSpikeAttributeSet>(TEXT("AttributeSet"));
}

UAbilitySystemComponent* AAethelnSpikePlayerState::GetAbilitySystemComponent() const
{
	return AbilitySystemComponent;
}

UAethelnSpikeAttributeSet* AAethelnSpikePlayerState::GetSpikeAttributeSet() const
{
	return AttributeSet;
}

void AAethelnSpikePlayerState::InitializeAbilityActorInfo(AActor* AvatarActor)
{
	if (AbilitySystemComponent == nullptr || AvatarActor == nullptr)
	{
		return;
	}

	AbilitySystemComponent->InitAbilityActorInfo(this, AvatarActor);
	if (HasAuthority() && AbilitySystemComponent->FindAbilitySpecFromClass(UAethelnSpikeMeleeAbility::StaticClass()) == nullptr)
	{
		AbilitySystemComponent->GiveAbility(FGameplayAbilitySpec(UAethelnSpikeMeleeAbility::StaticClass(), 1));
	}
}
