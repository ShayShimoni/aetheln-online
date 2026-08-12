#include "AethelnSpikeCharacter.h"

#include "AethelnSpikeAuthorityComponent.h"
#include "AethelnSpikePlayerState.h"

AAethelnSpikeCharacter::AAethelnSpikeCharacter()
{
	AuthorityComponent = CreateDefaultSubobject<UAethelnSpikeAuthorityComponent>(TEXT("AuthorityComponent"));
}

void AAethelnSpikeCharacter::PossessedBy(AController* NewController)
{
	Super::PossessedBy(NewController);
	InitializePlayerStateAbilitySystem();
	AuthorityComponent->SetLifecycleReady(true);
}

void AAethelnSpikeCharacter::OnRep_PlayerState()
{
	Super::OnRep_PlayerState();
	InitializePlayerStateAbilitySystem();
	AuthorityComponent->SetLifecycleReady(GetPlayerState() != nullptr);
}

void AAethelnSpikeCharacter::SubmitFreeAimAttack(const FVector& AimDirection)
{
	AuthorityComponent->SubmitAttack(AimDirection);
}

void AAethelnSpikeCharacter::InitializePlayerStateAbilitySystem()
{
	if (AAethelnSpikePlayerState* SpikePlayerState = GetPlayerState<AAethelnSpikePlayerState>())
	{
		SpikePlayerState->InitializeAbilityActorInfo(this);
	}
}
