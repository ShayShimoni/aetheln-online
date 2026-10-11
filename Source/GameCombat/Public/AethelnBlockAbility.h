#pragma once

#include "AethelnDefenseTypes.h"
#include "AethelnGameplayAbility.h"
#include "AethelnBlockAbility.generated.h"

/**
 * The right-mouse directional block (docs/dodge-and-block.md, The Block). Held: a seam Press raises it
 * and a seam Release (bAcceptsRelease) lowers it. While active it holds the target's one defense slot on
 * the timeline subsystem: State.Blocking, the interval [S + RaiseSeconds, end), the authored arc, and the
 * Guard hook #60 calls once per blocked contact. Nothing about it is predicted.
 */
UCLASS(Config = Game)
class GAMECOMBAT_API UAethelnBlockAbility : public UAethelnGameplayAbility
{
	GENERATED_BODY()

public:
	UAethelnBlockAbility();

	/** Adds finite values, RaiseSeconds >= 0, 0 < ArcHalfAngle <= 180, GuardBreakSeconds >= 0, Release, and the Q8/Q10 blocking tags. */
	virtual const TCHAR* FindGrantProblem() const override;

	/** Q8: a Press with no Guard left is InsufficientResource, beside the base Endurance check. */
	virtual bool CheckCost(const FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo, FGameplayTagContainer* OptionalRelevantTags = nullptr) const override;

	/** Placeholders, never tuning; every value is TBD (#107). */
	UPROPERTY(Config)
	float ProvisionalRaiseSeconds = 0.0f;

	UPROPERTY(Config)
	float ProvisionalArcHalfAngleDegrees = 0.0f;

	UPROPERTY(Config)
	float ProvisionalGuardBreakSeconds = 0.0f;

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
	/** The Guard hook: pressure once from the attacker's ASC; at zero Guard, the break. */
	EAethelnBlockConsequence HandleBlockedHit(const FAethelnBlockedContact& Contact);
	void HandleDeadTag(const FGameplayTag Tag, int32 NewCount);
	/** State.Dead removes the Guard-break effect; bound from the break until the next death. */
	void HandleDeadDuringBreak(const FGameplayTag Tag, int32 NewCount);

	bool bHoldsSlot = false;
	bool bHoldsStateTag = false;
	FDelegateHandle DeadHandle;
	FDelegateHandle BreakDeadHandle;
};
