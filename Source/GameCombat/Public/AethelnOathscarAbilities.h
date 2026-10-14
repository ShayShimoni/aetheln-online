#pragma once

#include "AethelnBasicChainAbility.h"
#include "AethelnDefenseTypes.h"
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

/**
 * order.oathscar.ability.parry: a short timed defensive window on the server defense slot (docs/dodge-and-block.md,
 * The Parry). A seam Press registers the slot [S + WindowStart, S + WindowEnd) and holds State.Oathscar.Parrying;
 * #60 resolves each contact against the slot at its authoritative contact time, and a contact inside the window and
 * the arc is fully negated (Parried) while the hook staggers its attacker through the interruption path. The client
 * never claims a parry. Every value is config and TBD (#107); an unset window defends nothing, so the grant fails.
 */
UCLASS(Config = Game)
class GAMECOMBAT_API UAethelnParryAbility : public UAethelnGameplayAbility
{
	GENERATED_BODY()

public:
	UAethelnParryAbility();

	/** Adds a Press-only seam ability, finite values, 0 <= WindowStart < WindowEnd, 0 < Arc <= 360, StaggerSeconds >= 0, and the blocking tags. */
	virtual const TCHAR* FindGrantProblem() const override;

	/** Placeholder, never tuning; every value is TBD (#107). */
	UPROPERTY(Config)
	FAethelnParryDefinition ProvisionalParry;

	/** Server timeline only: the normal end at WindowEnd. */
	void EndAtWindowEnd();

protected:
	virtual void ActivateAbility(
		const FGameplayAbilitySpecHandle Handle,
		const FGameplayAbilityActorInfo* ActorInfo,
		const FGameplayAbilityActivationInfo ActivationInfo,
		const FGameplayEventData* TriggerEventData) override;

	virtual void EndAbility(
		const FGameplayAbilitySpecHandle Handle,
		const FGameplayAbilityActorInfo* ActorInfo,
		const FGameplayAbilityActivationInfo ActivationInfo,
		bool bReplicateEndAbility,
		bool bWasCancelled) override;

private:
	/** The hook #60 calls once per contact inside the window: the attacker's interruption and stagger; the contact is Parried. */
	EAethelnBlockConsequence HandleParriedHit(const FAethelnBlockedContact& Contact);
	void HandleDeadTag(const FGameplayTag Tag, int32 NewCount);

	bool bHoldsSlot = false;
	bool bHoldsStateTag = false;
	FDelegateHandle DeadHandle;
};
