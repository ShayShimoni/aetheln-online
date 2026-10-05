#pragma once

#include "AbilitySystemComponent.h"
#include "AethelnGameplayAbility.h"
#include "CoreMinimal.h"
#include "NativeGameplayTags.h"
#include "AethelnCombatTestAbilities.generated.h"

/**
 * Test-only native tags and abilities for the #19 automation tests. UHT parses
 * only headers, so the types cannot live in a test .cpp; they live in the
 * editor-only GameTests module so Client and Server targets carry no test class
 * and no test tag. Only the tests grant these abilities.
 */
namespace AethelnCombatTestTags
{
	UE_DECLARE_GAMEPLAY_TAG_EXTERN(Ability_Test_LongRunning);
	UE_DECLARE_GAMEPLAY_TAG_EXTERN(Ability_Test_Probe);
	UE_DECLARE_GAMEPLAY_TAG_EXTERN(Ability_Test_Triggered);
	UE_DECLARE_GAMEPLAY_TAG_EXTERN(Test_Trigger);
	UE_DECLARE_GAMEPLAY_TAG_EXTERN(Test_ProbeActive);
	UE_DECLARE_GAMEPLAY_TAG_EXTERN(Test_Blocking);
}

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
		const bool bCommitted = CommitAbility(Handle, ActorInfo, ActivationInfo);
		if (TestNestedActivationClass != nullptr)
		{
			bTestNestedActivationSucceeded = ActorInfo->AbilitySystemComponent->TryActivateAbilityByClass(TestNestedActivationClass);
		}
		if (!bCommitted)
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
