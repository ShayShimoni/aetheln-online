#pragma once

#include "AethelnBasicChainAbility.h"
#include "CoreMinimal.h"
#include "AethelnOathscarAbilities.generated.h"

/*
 * The representative Oathscar actives (docs/characters-and-factions.md; docs/gas-foundation.md,
 * Representative Oathscar Actives; #260). The owner replaced Gate Step, Sworn Rebuke, and Hold
 * the Line on 2026-10-13 with Instant Strike, Parry, and the stance buffs; the superseded
 * skeletons are removed. Every value is config in the class's section of Config/DefaultGame.ini
 * and stays TBD (#107, #45): an unset value refuses the grant, as for the chain and the block.
 * Instant Strike, Parry, Attack Stance, and Defense Stance are working names.
 */

/**
 * order.oathscar.ability.instant_strike: a single weapon strike that hits on press, deals pure
 * Wrought damage (no Guard pressure and no interruption), and has a cooldown. It is a one-step
 * use of the chain machinery: the same registration, contact pipeline, boundaries, and records,
 * with its own commitment tag. The three-hit chain's commitment window refuses it, as it refuses
 * dodge and block (owner, 2026-10-13, issue #260).
 */
UCLASS(Config = Game)
class GAMECOMBAT_API UAethelnInstantStrikeAbility : public UAethelnBasicChainAbility
{
	GENERATED_BODY()

public:
	UAethelnInstantStrikeAbility();
	virtual const TCHAR* FindGrantProblem() const override;
};
