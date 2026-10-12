#pragma once

#include "AethelnBasicChainAbility.h"
#include "AethelnBlockAbility.h"
#include "CoreMinimal.h"
#include "AethelnOathscarAbilities.generated.h"

/*
 * The three representative Oathscar actives (docs/characters-and-factions.md; #260 in
 * docs/attack-timeline-and-combo.md, Representative actives). Gate Step and Sworn Rebuke
 * are single-step attacks on #60's timeline: one authored step, its contact, Guard
 * pressure and interruption rule, resolved on the server. Hold the Line is a held
 * directional defense on #18's defense slot. Every value is config in the class's
 * section of Config/DefaultGame.ini and stays TBD (#107, #45); unset values fail grant.
 * Gate Step's advance (character displacement) is not here (#260 package B).
 * Gate Step, Sworn Rebuke and Hold the Line are working names.
 */

/** order.oathscar.ability.gate_step */
UCLASS(Config = Game)
class GAMECOMBAT_API UAethelnGateStepAbility : public UAethelnBasicChainAbility
{
	GENERATED_BODY()

public:
	UAethelnGateStepAbility();
};

/** order.oathscar.ability.sworn_rebuke */
UCLASS(Config = Game)
class GAMECOMBAT_API UAethelnSwornRebukeAbility : public UAethelnBasicChainAbility
{
	GENERATED_BODY()

public:
	UAethelnSwornRebukeAbility();
};

/**
 * order.oathscar.ability.hold_the_line. Held: a seam Press raises it and a Release lowers it
 * (hold-and-release with no fixed duration, owner decision 2026-10-12).
 */
UCLASS(Config = Game)
class GAMECOMBAT_API UAethelnHoldTheLineAbility : public UAethelnBlockAbility
{
	GENERATED_BODY()

public:
	UAethelnHoldTheLineAbility();
};
