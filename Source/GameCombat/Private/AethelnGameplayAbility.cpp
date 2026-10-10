#include "AethelnGameplayAbility.h"

#include "AbilitySystemComponent.h"
#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatEffects.h"
#include "AethelnGameplayTags.h"
#include "GameFramework/PlayerState.h"

UAethelnGameplayAbility::UAethelnGameplayAbility()
{
	InstancingPolicy = EGameplayAbilityInstancingPolicy::InstancedPerActor;
	NetExecutionPolicy = EGameplayAbilityNetExecutionPolicy::ServerOnly;
	NetSecurityPolicy = EGameplayAbilityNetSecurityPolicy::ServerOnly;

	// Declared by #19, applied and removed only by #21.
	ActivationBlockedTags.AddTag(AethelnGameplayTags::State_Dead);
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

void UAethelnGameplayAbility::PreActivate(const FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo,
	const FGameplayAbilityActivationInfo ActivationInfo, FOnGameplayAbilityEnded::FDelegate* OnGameplayAbilityEndedDelegate,
	const FGameplayEventData* TriggerEventData)
{
	UAethelnAbilitySystemComponent* ASC = Cast<UAethelnAbilitySystemComponent>(ActorInfo != nullptr ? ActorInfo->AbilitySystemComponent.Get() : nullptr);
	ActivationOperationId = ASC != nullptr && ASC->IsSeamActivating(Handle) ? ASC->ActiveSeamScope->ActivationId : FGuid::NewGuid();
	ActivationId.Invalidate(); // an operation is not proof of a successful commit
	ActivationActorInfo = ActorInfo != nullptr ? *ActorInfo : FGameplayAbilityActorInfo();
	Super::PreActivate(Handle, ActorInfo, ActivationInfo, OnGameplayAbilityEndedDelegate, TriggerEventData);
}

bool UAethelnGameplayAbility::HasActivationLifecycle() const
{
	const UAbilitySystemComponent* ASC = CurrentActorInfo != nullptr ? CurrentActorInfo->AbilitySystemComponent.Get() : nullptr;
	return ASC != nullptr && ActivationActorInfo.OwnerActor.IsValid() && ActivationActorInfo.AvatarActor.IsValid()
		&& ASC->GetOwner() == ActivationActorInfo.OwnerActor.Get() && ASC->GetAvatarActor() == ActivationActorInfo.AvatarActor.Get()
		&& !ActivationActorInfo.AvatarActor->IsActorBeingDestroyed();
}

bool UAethelnGameplayAbility::CommitAbility(
	const FGameplayAbilitySpecHandle Handle,
	const FGameplayAbilityActorInfo* ActorInfo,
	const FGameplayAbilityActivationInfo ActivationInfo,
	FGameplayTagContainer* OptionalRelevantTags)
{
	const FGuid OperationId = ActivationOperationId;
	UAethelnAbilitySystemComponent* AbilitySystem = Cast<UAethelnAbilitySystemComponent>(ActorInfo != nullptr ? ActorInfo->AbilitySystemComponent.Get() : nullptr);
	if (!OperationId.IsValid() || CommitAttemptOperationId == OperationId || ActorInfo == nullptr || !HasActivationLifecycle()
		|| (AbilitySystem != nullptr && AbilitySystem->IsSeamActivating(Handle) && AbilitySystem->ActiveSeamScope->ActivationId != OperationId)) { return false; }
	// One attempt per server operation; nested/repeated calls cannot spend or rewrite its result.
	CommitAttemptOperationId = OperationId;
	// Stock cost/commit delegates can re-enter the shared instance. Keep the original inputs.
	const FGameplayAbilityActorInfo OriginalActorInfo = ActivationActorInfo;
	FCommitContext CommitContext;
	CommitContext.EnduranceCost = ProvisionalEnduranceCost;
	CommitContext.CooldownSeconds = ProvisionalCooldownSeconds;
	CommitContext.CooldownTags = CooldownTags;
	CommitContext.AbilityLevel = GetAbilityLevel(Handle, &OriginalActorInfo);
	TGuardValue<const FCommitContext*> CommitGuard(ActiveCommitContext, &CommitContext);
	const bool bCommitted = Super::CommitAbility(Handle, &OriginalActorInfo, ActivationInfo, OptionalRelevantTags);
	if (ActivationOperationId == OperationId) { ActivationId = bCommitted ? OperationId : FGuid(); }
	if (AbilitySystem != nullptr)
	{
		AbilitySystem->RecordSeamCommit(Handle, bCommitted, OperationId);
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

bool UAethelnGameplayAbility::CheckCost(
	const FGameplayAbilitySpecHandle Handle,
	const FGameplayAbilityActorInfo* ActorInfo,
	FGameplayTagContainer* OptionalRelevantTags) const
{
	const UAbilitySystemComponent* AbilitySystem = ActorInfo != nullptr ? ActorInfo->AbilitySystemComponent.Get() : nullptr;
	return FMath::IsFinite(ProvisionalEnduranceCost)
		&& ProvisionalEnduranceCost >= 0.0f
		&& AbilitySystem != nullptr
		&& AbilitySystem->GetNumericAttribute(UAethelnCombatAttributeSet::GetEnduranceAttribute()) >= ProvisionalEnduranceCost;
}

void UAethelnGameplayAbility::ApplyCost(
	const FGameplayAbilitySpecHandle Handle,
	const FGameplayAbilityActorInfo* ActorInfo,
	const FGameplayAbilityActivationInfo ActivationInfo) const
{
	const float Cost = ActiveCommitContext != nullptr ? ActiveCommitContext->EnduranceCost : ProvisionalEnduranceCost;
	if (Cost <= 0.0f)
	{
		return;
	}
	const int32 Level = ActiveCommitContext != nullptr ? ActiveCommitContext->AbilityLevel : GetAbilityLevel(Handle, ActorInfo);
	const FGameplayEffectSpecHandle Spec = MakeOutgoingGameplayEffectSpec(Handle, ActorInfo, ActivationInfo, UAethelnEnduranceCostEffect::StaticClass(), Level);
	if (Spec.IsValid())
	{
		Spec.Data->SetSetByCallerMagnitude(AethelnGameplayTags::SetByCaller_Cost_Endurance, -Cost);
		ApplyGameplayEffectSpecToOwner(Handle, ActorInfo, ActivationInfo, Spec);
	}
}

const FGameplayTagContainer* UAethelnGameplayAbility::GetCooldownTags() const
{
	return &CooldownTags;
}

void UAethelnGameplayAbility::ApplyCooldown(
	const FGameplayAbilitySpecHandle Handle,
	const FGameplayAbilityActorInfo* ActorInfo,
	const FGameplayAbilityActivationInfo ActivationInfo) const
{
	const float Cooldown = ActiveCommitContext != nullptr ? ActiveCommitContext->CooldownSeconds : ProvisionalCooldownSeconds;
	if (Cooldown <= 0.0f)
	{
		return;
	}
	const int32 Level = ActiveCommitContext != nullptr ? ActiveCommitContext->AbilityLevel : GetAbilityLevel(Handle, ActorInfo);
	const FGameplayEffectSpecHandle Spec = MakeOutgoingGameplayEffectSpec(Handle, ActorInfo, ActivationInfo, UAethelnCooldownEffect::StaticClass(), Level);
	if (Spec.IsValid())
	{
		Spec.Data->SetSetByCallerMagnitude(AethelnGameplayTags::SetByCaller_Cooldown_Duration, Cooldown);
		Spec.Data->DynamicGrantedTags.AppendTags(ActiveCommitContext != nullptr ? ActiveCommitContext->CooldownTags : CooldownTags);
		ApplyGameplayEffectSpecToOwner(Handle, ActorInfo, ActivationInfo, Spec);
	}
}

void UAethelnGameplayAbility::ActivateAbility(
	const FGameplayAbilitySpecHandle Handle,
	const FGameplayAbilityActorInfo* ActorInfo,
	const FGameplayAbilityActivationInfo ActivationInfo,
	const FGameplayEventData* TriggerEventData)
{
	const FGuid OperationId = ActivationOperationId;
	const FGameplayAbilityActorInfo OriginalActorInfo = ActivationActorInfo;
	const UAethelnAbilitySystemComponent* ASC = Cast<UAethelnAbilitySystemComponent>(ActorInfo != nullptr ? ActorInfo->AbilitySystemComponent.Get() : nullptr);
	if (ASC != nullptr && ASC->IsSeamActivating(Handle) && ASC->ActiveSeamScope->ActivationId != OperationId) { return; }
	const bool bCommitted = CommitAbility(Handle, &OriginalActorInfo, ActivationInfo);
	if (ActivationOperationId == OperationId) { EndAbility(Handle, &OriginalActorInfo, ActivationInfo, true, !bCommitted); }
}

void UAethelnGameplayAbility::SetAbilityId(const FGameplayTag& InAbilityId)
{
	AbilityId = InAbilityId;
	SetAssetTags(FGameplayTagContainer(InAbilityId));
}

void UAethelnGameplayAbility::SetCooldownTag(const FGameplayTag& InCooldownTag)
{
	CooldownTags = FGameplayTagContainer(InCooldownTag);
}

void UAethelnGameplayAbility::EndForRelease()
{
	EndAbility(CurrentSpecHandle, CurrentActorInfo, CurrentActivationInfo, true, false);
}

bool UAethelnGameplayAbility::CanEndForRelease() const
{
	// Instance activity begins before stock Spec.ActiveCount and before commitment.
	return ActivationId.IsValid() && ActivationId == ActivationOperationId && HasActivationLifecycle()
		&& IsEndAbilityValid(CurrentSpecHandle, CurrentActorInfo);
}
