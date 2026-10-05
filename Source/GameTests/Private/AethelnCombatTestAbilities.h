#pragma once

#include "AbilitySystemComponent.h"
#include "AethelnGameplayAbility.h"
#include "AethelnGameplayTags.h"
#include "CoreMinimal.h"
#include "AethelnCombatTestAbilities.generated.h"

/*
 * Test-only abilities for the #19 automation tests. UHT parses only headers, so
 * the types cannot live in a test .cpp; they live in the editor-only GameTests
 * module so Client and Server targets carry no test class. Their tags
 * (AethelnCombatTestTags) are declared in GameCore, because the engine accepts
 * native tags only from Runtime modules. Only the tests grant these abilities.
 */

/** Commits through the seam's result slot, then stays active until cancelled. */
UCLASS(NotBlueprintable, HideDropdown)
class UAethelnLongRunningTestAbility : public UAethelnGameplayAbility
{
	GENERATED_BODY()

public:
	UAethelnLongRunningTestAbility()
	{
		SetAbilityId(AethelnCombatTestTags::Ability_Test_LongRunning);
		ContentVersion = 1;
	}

	virtual void ActivateAbility(
		const FGameplayAbilitySpecHandle Handle,
		const FGameplayAbilityActorInfo* ActorInfo,
		const FGameplayAbilityActivationInfo ActivationInfo,
		const FGameplayEventData* TriggerEventData) override
	{
		CommitAbility(Handle, ActorInfo, ActivationInfo);
	}
};

/**
 * Seam probe. The knobs and counters live on the primary instance, which the seam
 * reads. Cost and cooldown are counted, not applied (the real ones arrive in P4).
 * It accepts Release, holds a state tag while active, and stays active after a
 * successful commit. The setters let grant-validation tests build bad definitions
 * on transient instances.
 */
UCLASS(NotBlueprintable, HideDropdown)
class UAethelnSeamProbeTestAbility : public UAethelnGameplayAbility
{
	GENERATED_BODY()

public:
	UAethelnSeamProbeTestAbility()
	{
		SetAbilityId(AethelnCombatTestTags::Ability_Test_Probe);
		ContentVersion = 1;
		bAcceptsRelease = true;
		ActivationOwnedTags.AddTag(AethelnCombatTestTags::Test_ProbeActive);
		ActivationBlockedTags.AddTag(AethelnCombatTestTags::Test_Blocking);
	}

	bool bTestOnCooldown = false;
	bool bTestInsufficientResource = false;
	bool bTestFailCommit = false;
	/** With bTestFailCommit: stay active after the failed commit instead of ending. */
	bool bTestKeepActiveOnFailedCommit = false;
	/** Commit through the partial CommitAbilityCost and CommitAbilityCooldown instead of CommitAbility, and stay active. */
	bool bTestUsePartialCommit = false;
	bool bTestPartialCommitSucceeded = false;
	TSubclassOf<UGameplayAbility> TestNestedActivationClass;
	bool bTestNestedActivationSucceeded = false;
	mutable int32 CostApplications = 0;
	mutable int32 CooldownApplications = 0;

	void SetTestAbilityId(const FGameplayTag& InAbilityId) { AbilityId = InAbilityId; }
	void SetTestPolicies(
		EGameplayAbilityInstancingPolicy::Type InInstancing,
		EGameplayAbilityNetExecutionPolicy::Type InExecution,
		EGameplayAbilityNetSecurityPolicy::Type InSecurity)
	{
		InstancingPolicy = InInstancing;
		NetExecutionPolicy = InExecution;
		NetSecurityPolicy = InSecurity;
	}
	void AddTestTrigger(const FGameplayTag& TriggerTag)
	{
		AbilityTriggers.AddDefaulted_GetRef().TriggerTag = TriggerTag;
	}

	virtual bool CheckCooldown(const FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo, FGameplayTagContainer* OptionalRelevantTags = nullptr) const override
	{
		return !bTestOnCooldown;
	}

	virtual bool CheckCost(const FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo, FGameplayTagContainer* OptionalRelevantTags = nullptr) const override
	{
		return !bTestInsufficientResource;
	}

	virtual bool CommitCheck(const FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo, const FGameplayAbilityActivationInfo ActivationInfo, FGameplayTagContainer* OptionalRelevantTags = nullptr) override
	{
		return !bTestFailCommit && Super::CommitCheck(Handle, ActorInfo, ActivationInfo, OptionalRelevantTags);
	}

	virtual void ApplyCooldown(const FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo, const FGameplayAbilityActivationInfo ActivationInfo) const override
	{
		++CooldownApplications;
	}

	virtual void ApplyCost(const FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo, const FGameplayAbilityActivationInfo ActivationInfo) const override
	{
		++CostApplications;
	}

	virtual void ActivateAbility(
		const FGameplayAbilitySpecHandle Handle,
		const FGameplayAbilityActorInfo* ActorInfo,
		const FGameplayAbilityActivationInfo ActivationInfo,
		const FGameplayEventData* TriggerEventData) override
	{
		if (bTestUsePartialCommit)
		{
			const bool bCostCommitted = CommitAbilityCost(Handle, ActorInfo, ActivationInfo);
			const bool bCooldownCommitted = CommitAbilityCooldown(Handle, ActorInfo, ActivationInfo, false);
			bTestPartialCommitSucceeded = bCostCommitted || bCooldownCommitted;
			return;
		}
		const bool bCommitted = CommitAbility(Handle, ActorInfo, ActivationInfo);
		if (TestNestedActivationClass != nullptr)
		{
			bTestNestedActivationSucceeded = ActorInfo->AbilitySystemComponent->TryActivateAbilityByClass(TestNestedActivationClass);
		}
		if (!bCommitted && !bTestKeepActiveOnFailedCommit)
		{
			EndAbility(Handle, ActorInfo, ActivationInfo, true, true);
		}
	}
};

/** Carries an ability trigger, so grant validation refuses it; tests grant it directly. */
UCLASS(NotBlueprintable, HideDropdown)
class UAethelnTriggeredTestAbility : public UAethelnGameplayAbility
{
	GENERATED_BODY()

public:
	UAethelnTriggeredTestAbility()
	{
		SetAbilityId(AethelnCombatTestTags::Ability_Test_Triggered);
		ContentVersion = 1;
		AbilityTriggers.AddDefaulted_GetRef().TriggerTag = AethelnCombatTestTags::Test_Trigger;
	}

	int32 Activations = 0;

	virtual void ActivateAbility(
		const FGameplayAbilitySpecHandle Handle,
		const FGameplayAbilityActorInfo* ActorInfo,
		const FGameplayAbilityActivationInfo ActivationInfo,
		const FGameplayEventData* TriggerEventData) override
	{
		++Activations;
		Super::ActivateAbility(Handle, ActorInfo, ActivationInfo, TriggerEventData);
	}
};
