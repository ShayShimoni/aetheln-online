#pragma once

#include "AethelnDefenseTypes.h"
#include "AethelnGameplayAbility.h"
#include "AethelnDodgeAbility.generated.h"

/**
 * The shared prototype dodge (docs/dodge-and-block.md, T1). Movement-carried: only the
 * server's simulation of a received flagged move reaches it, through
 * UAethelnAbilitySystemComponent::ProcessMovementCarriedRequest. It commits cost and
 * cooldown once, opens the server-owned windows from the processing time, stays active
 * until ActionEnd, and on cancel closes the windows at that time and ends the server
 * displacement. Nothing about it is predicted except the CMC displacement.
 */
UCLASS(Config = Game)
class GAMECOMBAT_API UAethelnDodgeAbility : public UAethelnGameplayAbility
{
	GENERATED_BODY()

public:
	UAethelnDodgeAbility();

	/** Adds the finite, ordered definition, the movement-carried flag, State.Dead, and Q4 (a cost or a cooldown). */
	virtual const TCHAR* FindGrantProblem() const override;

	/** Placeholder definition, never tuning; every value is TBD (#107). */
	UPROPERTY(Config)
	FAethelnDodgeDefinition ProvisionalDodge;

	/** Server boundary pass only: the normal end at ActionEnd, which never touches displacement. */
	void EndAtActionEnd();

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
};
