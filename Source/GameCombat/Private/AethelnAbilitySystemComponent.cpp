#include "AethelnAbilitySystemComponent.h"

#include "AbilitySystemInterface.h"
#include "GameFramework/Pawn.h"
#include "GameFramework/PlayerState.h"

UAethelnAbilitySystemComponent* UAethelnAbilitySystemComponent::FindForPawn(const APawn* Pawn)
{
	if (Pawn == nullptr)
	{
		return nullptr;
	}

	if (const IAbilitySystemInterface* PlayerStateOwner = Cast<IAbilitySystemInterface>(Pawn->GetPlayerState()))
	{
		return Cast<UAethelnAbilitySystemComponent>(PlayerStateOwner->GetAbilitySystemComponent());
	}

	return Pawn->FindComponentByClass<UAethelnAbilitySystemComponent>();
}
