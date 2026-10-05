#include "AethelnGameplayAbility.h"

#include "AbilitySystemComponent.h"
#include "AethelnAbilitySystemComponent.h"
#include "GameFramework/PlayerState.h"

UAethelnGameplayAbility::UAethelnGameplayAbility()
{
	InstancingPolicy = EGameplayAbilityInstancingPolicy::InstancedPerActor;
	NetExecutionPolicy = EGameplayAbilityNetExecutionPolicy::ServerOnly;
	NetSecurityPolicy = EGameplayAbilityNetSecurityPolicy::ServerOnly;
}

bool UAethelnGameplayAbility::IsAbilityIdentityTag(const FGameplayTag& Tag)
{
	const FGameplayTag Family = FGameplayTag::RequestGameplayTag(TEXT("Ability"), false);
	return Tag.IsValid() && Family.IsValid() && Tag != Family && Tag.MatchesTag(Family);
}

const TCHAR* UAethelnGameplayAbility::FindGrantProblem() const
{
	if (GetInstancingPolicy() != EGameplayAbilityInstancingPolicy::InstancedPerActor)
	{
		return TEXT("is not InstancedPerActor");
	}
	if (GetNetExecutionPolicy() != EGameplayAbilityNetExecutionPolicy::ServerOnly
		|| GetNetSecurityPolicy() != EGameplayAbilityNetSecurityPolicy::ServerOnly)
	{
		return TEXT("is not ServerOnly in both net policies");
	}
	if (!IsAbilityIdentityTag(AbilityId))
	{
		return TEXT("lacks a valid Ability. identity tag");
	}
	if (ContentVersion == 0)
	{
		return TEXT("has ContentVersion 0");
	}
	if (!FMath::IsFinite(ProvisionalEnduranceCost) || ProvisionalEnduranceCost < 0.0f)
	{
		return TEXT("has a non-finite or negative cost");
	}
	if (!FMath::IsFinite(ProvisionalCooldownSeconds) || ProvisionalCooldownSeconds < 0.0f)
	{
		return TEXT("has a non-finite or negative cooldown");
	}
	if (AbilityTriggers.Num() > 0)
	{
		return TEXT("has AbilityTriggers");
	}
	if (bReplicateInputDirectly)
	{
		return TEXT("sets bReplicateInputDirectly");
	}
	return nullptr;
}

bool UAethelnGameplayAbility::CanActivateAbility(
	const FGameplayAbilitySpecHandle Handle,
	const FGameplayAbilityActorInfo* ActorInfo,
	const FGameplayTagContainer* SourceTags,
	const FGameplayTagContainer* TargetTags,
	FGameplayTagContainer* OptionalRelevantTags) const
{
	// The choke point: on a player ASC only the seam may activate, and only the handle it is activating.
	const UAbilitySystemComponent* AbilitySystem = ActorInfo != nullptr ? ActorInfo->AbilitySystemComponent.Get() : nullptr;
	if (AbilitySystem != nullptr && Cast<APlayerState>(AbilitySystem->GetOwner()) != nullptr)
	{
		const UAethelnAbilitySystemComponent* ProjectAbilitySystem = Cast<UAethelnAbilitySystemComponent>(AbilitySystem);
		if (ProjectAbilitySystem == nullptr || !ProjectAbilitySystem->IsSeamActivating(Handle))
		{
			return false;
		}
	}
	return Super::CanActivateAbility(Handle, ActorInfo, SourceTags, TargetTags, OptionalRelevantTags);
}

bool UAethelnGameplayAbility::CommitAbility(
	const FGameplayAbilitySpecHandle Handle,
	const FGameplayAbilityActorInfo* ActorInfo,
	const FGameplayAbilityActivationInfo ActivationInfo,
	FGameplayTagContainer* OptionalRelevantTags)
{
	const bool bCommitted = Super::CommitAbility(Handle, ActorInfo, ActivationInfo, OptionalRelevantTags);
	ActivationId = bCommitted ? FGuid::NewGuid() : FGuid();
	if (UAethelnAbilitySystemComponent* AbilitySystem = Cast<UAethelnAbilitySystemComponent>(ActorInfo != nullptr ? ActorInfo->AbilitySystemComponent.Get() : nullptr))
	{
		AbilitySystem->RecordSeamCommit(Handle, bCommitted, ActivationId);
	}
	return bCommitted;
}

bool UAethelnGameplayAbility::CommitAbilityCost(
	const FGameplayAbilitySpecHandle Handle,
	const FGameplayAbilityActorInfo* ActorInfo,
	const FGameplayAbilityActivationInfo ActivationInfo,
	FGameplayTagContainer* OptionalRelevantTags)
{
	return false;
}

bool UAethelnGameplayAbility::CommitAbilityCooldown(
	const FGameplayAbilitySpecHandle Handle,
	const FGameplayAbilityActorInfo* ActorInfo,
	const FGameplayAbilityActivationInfo ActivationInfo,
	const bool ForceCooldown,
	FGameplayTagContainer* OptionalRelevantTags)
{
	return false;
}

void UAethelnGameplayAbility::ActivateAbility(
	const FGameplayAbilitySpecHandle Handle,
	const FGameplayAbilityActorInfo* ActorInfo,
	const FGameplayAbilityActivationInfo ActivationInfo,
	const FGameplayEventData* TriggerEventData)
{
	const bool bCommitted = CommitAbility(Handle, ActorInfo, ActivationInfo);
	EndAbility(Handle, ActorInfo, ActivationInfo, true, !bCommitted);
}

void UAethelnGameplayAbility::SetAbilityId(const FGameplayTag& InAbilityId)
{
	AbilityId = InAbilityId;
	SetAssetTags(FGameplayTagContainer(InAbilityId));
}

void UAethelnGameplayAbility::EndForRelease()
{
	EndAbility(CurrentSpecHandle, CurrentActorInfo, CurrentActivationInfo, true, false);
}
