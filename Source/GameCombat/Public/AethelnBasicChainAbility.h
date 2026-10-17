#pragma once

#include "AethelnAttackDefinition.h"
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

	/**
	 * The authored definition asset (TA-027, #84). When set, the asset is the only source of ContentVersion, steps,
	 * sampling bounds and Endurance cost: ApplyDefinition copies them into the fields above once at startup, and an
	 * unusable asset refuses the grant (FindGrantProblem). When unset, the fields keep their config values.
	 */
	UPROPERTY(Config) TSoftObjectPtr<UAethelnAttackDefinition> Definition;

	/** Class defaults only, never an instance: copies a usable definition into this object's authored fields. A missing or unusable one copies nothing. */
	void ApplyDefinition();

	/** Applies the definition of every chain class default (the chain and its subclasses). Run once the engine is up, so no asset loads while classes register. */
	static void ApplyDefinitionToClassDefaults();

	/** Server timeline only: end GAS at BufferOpen without ending recovery. */
	void EndAtBufferOpen();

protected:
	virtual void ActivateAbility(FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo, FGameplayAbilityActivationInfo ActivationInfo, const FGameplayEventData* TriggerEventData) override;
	virtual void EndAbility(FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo, FGameplayAbilityActivationInfo ActivationInfo, bool bReplicateEndAbility, bool bWasCancelled) override;

	/** Constructor only: structure, never config. */
	int32 StepCount = 3;
	FGameplayTag CommitmentTag;

private:
	/** Null when Definition is unset or unusable; the failure reason is FindDefinitionProblem. */
	const TCHAR* FindDefinitionProblem() const;

	/** Keeps the loaded definition alive for this object. */
	UPROPERTY(Transient)
	TObjectPtr<UAethelnAttackDefinition> LoadedDefinition;

	bool bJoinedTimeline = false;
};
