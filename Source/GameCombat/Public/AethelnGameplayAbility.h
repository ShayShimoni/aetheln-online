#pragma once

#include "Abilities/GameplayAbility.h"
#include "CoreMinimal.h"
#include "AethelnGameplayAbility.generated.h"

/**
 * Base for every project ability (docs/gas-foundation.md, Abilities). The policies
 * are InstancedPerActor and ServerOnly for execution and security. On a
 * PlayerState-owned ASC, CanActivateAbility is the choke point: it is false unless
 * the activation seam is activating this spec handle, which closes every stock
 * activation route. AI ASCs are exempt. The engine cost and cooldown effect classes
 * stay null: the overrides below apply the shared UAethelnEnduranceCostEffect and
 * UAethelnCooldownEffect from the config values. State.Dead blocks every ability.
 */
UCLASS(Abstract, Config = Game)
class GAMECOMBAT_API UAethelnGameplayAbility : public UGameplayAbility
{
	GENERATED_BODY()

public:
	UAethelnGameplayAbility();

	/** True for a valid tag strictly below the Ability. family. */
	static bool IsAbilityIdentityTag(const FGameplayTag& Tag);

	/** Ability identity and the request AbilityId (Ability.<Order>.<Name>). */
	const FGameplayTag& GetAbilityId() const { return AbilityId; }

	/** Server only: the id this instance's latest CommitAbility created, or invalid if that commit failed. */
	const FGuid& GetActivationId() const { return ActivationId; }

	/** Grant-time validation of this definition: null when it may be granted, otherwise the reason. */
	virtual const TCHAR* FindGrantProblem() const;

	virtual bool CanActivateAbility(
		const FGameplayAbilitySpecHandle Handle,
		const FGameplayAbilityActorInfo* ActorInfo,
		const FGameplayTagContainer* SourceTags = nullptr,
		const FGameplayTagContainer* TargetTags = nullptr,
		FGameplayTagContainer* OptionalRelevantTags = nullptr) const override;

	/** Records the commit outcome and a new activation id in the seam's result slot. */
	virtual bool CommitAbility(
		const FGameplayAbilitySpecHandle Handle,
		const FGameplayAbilityActorInfo* ActorInfo,
		const FGameplayAbilityActivationInfo ActivationInfo,
		FGameplayTagContainer* OptionalRelevantTags = nullptr) override;

	/** Refused: CommitAbility is the only commit, so the seam's result slot sees every spend. Applies nothing. */
	virtual bool CommitAbilityCost(
		const FGameplayAbilitySpecHandle Handle,
		const FGameplayAbilityActorInfo* ActorInfo,
		const FGameplayAbilityActivationInfo ActivationInfo,
		FGameplayTagContainer* OptionalRelevantTags = nullptr) override;

	/** Refused: CommitAbility is the only commit, so the seam's result slot sees every spend. Applies nothing. */
	virtual bool CommitAbilityCooldown(
		const FGameplayAbilitySpecHandle Handle,
		const FGameplayAbilityActorInfo* ActorInfo,
		const FGameplayAbilityActivationInfo ActivationInfo,
		const bool ForceCooldown,
		FGameplayTagContainer* OptionalRelevantTags = nullptr) override;

	/** The engine cost check cannot see set-by-caller magnitudes: the cost must be finite, >= 0, and at most current Endurance. */
	virtual bool CheckCost(const FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo, FGameplayTagContainer* OptionalRelevantTags = nullptr) const override;

	/** Applies the shared cost effect with the negated cost. A zero cost applies nothing. */
	virtual void ApplyCost(const FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo, const FGameplayAbilityActivationInfo ActivationInfo) const override;

	/** The ability's Cooldown.<Order>.<Name> tag, which the engine's CheckCooldown reads. */
	virtual const FGameplayTagContainer* GetCooldownTags() const override;

	/**
	 * Applies the shared cooldown effect, granting the cooldown tag for the configured duration.
	 * A zero cooldown applies nothing (a zero-duration effect would never expire).
	 */
	virtual void ApplyCooldown(const FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo, const FGameplayAbilityActivationInfo ActivationInfo) const override;

	/** Authored definition version, starting at 1. The seam accepts only an exact match. */
	UPROPERTY(Config)
	uint32 ContentVersion = 0;

	/** Optional Endurance cost; TBD (#107). Validated at grant, checked by CheckCost, spent by ApplyCost. */
	UPROPERTY(Config)
	float ProvisionalEnduranceCost = 0.0f;

	/** Cooldown duration in seconds; TBD (#107). Validated at grant, applied by ApplyCooldown. */
	UPROPERTY(Config)
	float ProvisionalCooldownSeconds = 0.0f;

	/** Whether a Release request ends the running activation. */
	UPROPERTY(Config)
	bool bAcceptsRelease = false;

protected:
	/** Establishes the server operation before stock owned-tag/activation callbacks. */
	virtual void PreActivate(const FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo,
		const FGameplayAbilityActivationInfo ActivationInfo, FOnGameplayAbilityEnded::FDelegate* OnGameplayAbilityEndedDelegate,
		const FGameplayEventData* TriggerEventData = nullptr) override;
	const FGuid& GetActivationOperationId() const { return ActivationOperationId; }
	const FGameplayAbilityActorInfo& GetActivationActorInfo() const { return ActivationActorInfo; }
	bool HasActivationLifecycle() const;
	/**
	 * Commits once through CommitAbility, then ends directly with EndAbility whether or not the
	 * commit succeeded, so it never relies on the seam's cancel, which a non-cancelable ability
	 * ignores. #60 replaces the end with its timeline.
	 */
	virtual void ActivateAbility(
		const FGameplayAbilitySpecHandle Handle,
		const FGameplayAbilityActorInfo* ActorInfo,
		const FGameplayAbilityActivationInfo ActivationInfo,
		const FGameplayEventData* TriggerEventData) override;

	/** Constructor only: sets the identity, also as the asset tag that stock tag queries read. */
	void SetAbilityId(const FGameplayTag& InAbilityId);

	/** Constructor only: sets the Cooldown.<Order>.<Name> tag that ApplyCooldown grants. */
	void SetCooldownTag(const FGameplayTag& InCooldownTag);

	FGameplayTag AbilityId;

private:
	friend class UAethelnAbilitySystemComponent;

	/** Seam only: ends the running activation for a valid Release. */
	void EndForRelease();
	bool CanEndForRelease() const;

	FGuid ActivationId;
	FGuid ActivationOperationId;
	FGuid CommitAttemptOperationId;
	FGameplayAbilityActorInfo ActivationActorInfo;
	struct FCommitContext
	{
		float EnduranceCost = 0.0f;
		float CooldownSeconds = 0.0f;
		int32 AbilityLevel = 1;
		FGameplayTagContainer CooldownTags;
	};
	const FCommitContext* ActiveCommitContext = nullptr;
	FGameplayTagContainer CooldownTags;
};
