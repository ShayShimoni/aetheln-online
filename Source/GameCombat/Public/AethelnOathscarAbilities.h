#pragma once

#include "AethelnGameplayAbility.h"
#include "CoreMinimal.h"
#include "AethelnOathscarAbilities.generated.h"

/*
 * Skeletons of the three representative Oathscar actives (docs/characters-and-factions.md;
 * docs/gas-foundation.md, Abilities): identity, cooldown tag, activation, validation, cost
 * and cooldown only. Each constructor sets the structure; the config section of each class
 * in Config/DefaultGame.ini sets ContentVersion and the provisional cost and cooldown,
 * which stay TBD (#107, #45). Contacts, Guard results and windows belong to #60.
 *
 * None overrides ActivateAbility: the base commits once through CommitAbility and ends
 * directly. Gate Step, Sworn Rebuke and Hold the Line are working names.
 */

/** order.oathscar.ability.gate_step */
UCLASS()
class GAMECOMBAT_API UAethelnGateStepAbility : public UAethelnGameplayAbility
{
	GENERATED_BODY()

public:
	UAethelnGateStepAbility();
};

/** order.oathscar.ability.sworn_rebuke */
UCLASS()
class GAMECOMBAT_API UAethelnSwornRebukeAbility : public UAethelnGameplayAbility
{
	GENERATED_BODY()

public:
	UAethelnSwornRebukeAbility();
};

/** order.oathscar.ability.hold_the_line. Duration-or-hold behavior is TBD (#107). */
UCLASS()
class GAMECOMBAT_API UAethelnHoldTheLineAbility : public UAethelnGameplayAbility
{
	GENERATED_BODY()

public:
	UAethelnHoldTheLineAbility();
};
