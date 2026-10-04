#pragma once

#include "AbilitySystemComponent.h"
#include "CoreMinimal.h"
#include "AethelnAbilitySystemComponent.generated.h"

class APawn;

/**
 * Project Ability System Component for players (owned by AAethelnPlayerState,
 * Mixed replication) and AI (owned by the pawn, Minimal replication).
 * The activation seam arrives in a later #19 phase (docs/gas-foundation.md).
 */
UCLASS()
class GAMECOMBAT_API UAethelnAbilitySystemComponent : public UAbilitySystemComponent
{
	GENERATED_BODY()

public:
	/**
	 * Resolves the ASC that acts for a pawn: the PlayerState's ASC for a player
	 * pawn, otherwise the pawn's own ASC (AI), otherwise null. The GameCore pawn
	 * carries no ASC, so the stock actor lookup cannot find a player's ASC.
	 */
	static UAethelnAbilitySystemComponent* FindForPawn(const APawn* Pawn);
};
