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
 * stay null; the cost and cooldown overrides arrive in P4.
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

	/** Server only: the id of the latest committed activation of this instance. */
	const FGuid& GetActivationId() const { return ActivationId; }

	/** Grant-time validation of this definition: null when it may be granted, otherwise the reason. */
	const TCHAR* FindGrantProblem() const;

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

	/** Authored definition version, starting at 1. The seam accepts only an exact match. */
	UPROPERTY(Config)
	uint32 ContentVersion = 0;

	/** Optional Endurance cost; TBD (#107). Validated at grant; applied from P4. */
	UPROPERTY(Config)
	float ProvisionalEnduranceCost = 0.0f;

	/** Cooldown duration; TBD (#107). Validated at grant; applied from P4. */
	UPROPERTY(Config)
	float ProvisionalCooldownSeconds = 0.0f;

	/** Whether a Release request ends the running activation. */
	UPROPERTY(Config)
	bool bAcceptsRelease = false;

protected:
	/** Commits, then ends. #60 replaces the end with its timeline. */
	virtual void ActivateAbility(
		const FGameplayAbilitySpecHandle Handle,
		const FGameplayAbilityActorInfo* ActorInfo,
		const FGameplayAbilityActivationInfo ActivationInfo,
		const FGameplayEventData* TriggerEventData) override;

	/** Constructor only: sets the identity, also as the asset tag that stock tag queries read. */
	void SetAbilityId(const FGameplayTag& InAbilityId);

	FGameplayTag AbilityId;

private:
	friend class UAethelnAbilitySystemComponent;

	/** Seam only: ends the running activation for a valid Release. */
	void EndForRelease();

	FGuid ActivationId;
};
