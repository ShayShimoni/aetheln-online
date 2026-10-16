#pragma once

#include "AethelnAttackTypes.h"
#include "AethelnGameplayAbility.h"
#include "AethelnBasicChainAbility.generated.h"

/**
 * Server-only, one GAS activation per press. Timeline recovery survives its GAS end.
 * The three-hit chain has three steps; a single-step subclass (#260's Instant Strike) is a
 * chain of one step that ends at its RecoveryEnd.
 */
UCLASS(Config = Game)
class GAMECOMBAT_API UAethelnBasicChainAbility : public UAethelnGameplayAbility
{
	GENERATED_BODY()

public:
	UAethelnBasicChainAbility();
	int32 GetStepCount() const { return StepCount; }
	/** The State.<Order>.<Name> tag held in [0, CancelOpen) of each step. */
	const FGameplayTag& GetCommitmentTag() const { return CommitmentTag; }
	virtual const TCHAR* FindGrantProblem() const override;
	virtual bool CanActivateAbility(FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo, const FGameplayTagContainer* SourceTags = nullptr, const FGameplayTagContainer* TargetTags = nullptr, FGameplayTagContainer* OptionalRelevantTags = nullptr) const override;

	UPROPERTY(Config) TArray<FAethelnAttackStepDefinition> ProvisionalSteps;
	UPROPERTY(Config) double ProvisionalMaxSampleAngleDegrees = 0.0;
	UPROPERTY(Config) double ProvisionalMaxSampleDistance = 0.0;
	UPROPERTY(Config) FGameplayTagContainer ResetTags;

	/** Server timeline only: end GAS at BufferOpen without ending recovery. */
	void EndAtBufferOpen();

protected:
	virtual void ActivateAbility(FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo, FGameplayAbilityActivationInfo ActivationInfo, const FGameplayEventData* TriggerEventData) override;
	virtual void EndAbility(FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo, FGameplayAbilityActivationInfo ActivationInfo, bool bReplicateEndAbility, bool bWasCancelled) override;

	/** Constructor only: structure, never config. */
	int32 StepCount = 3;
	FGameplayTag CommitmentTag;

private:
	bool bJoinedTimeline = false;
};
