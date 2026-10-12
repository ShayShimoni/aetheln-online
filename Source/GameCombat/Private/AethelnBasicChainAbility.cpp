#include "AethelnBasicChainAbility.h"

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatTimelineSubsystem.h"
#include "AethelnGameplayTags.h"
#include "Engine/World.h"

UAethelnBasicChainAbility::UAethelnBasicChainAbility()
{
	SetAbilityId(AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain);
	CommitmentTag = AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain;
	ResetTags.AddTag(AethelnGameplayTags::State_Dead);
	// #18 Q17 and Q10: no attack while dodging or blocking. Each blocking tag is also a reset tag (grant rule).
	for (const FGameplayTag Tag : { AethelnGameplayTags::State_Dodging.GetTag(), AethelnGameplayTags::State_Blocking.GetTag() })
	{
		ActivationBlockedTags.AddTag(Tag);
		ResetTags.AddTag(Tag);
	}
	// No authored steps/version/sampling/cost preset. Unset production fails grant.
}

const TCHAR* UAethelnBasicChainAbility::FindGrantProblem() const
{
	if (const TCHAR* Problem = Super::FindGrantProblem()) { return Problem; }
	// Every hit of a multi-step chain commits, so a chain cooldown would block its next hit; a single step may have one.
	if ((StepCount > 1 && ProvisionalCooldownSeconds != 0.0f) || bAcceptsRelease) { return TEXT("has a chain cooldown or Release route"); }
	if (StepCount < 1 || ProvisionalSteps.Num() != StepCount) { return TEXT("does not have its authored number of steps"); }
	if (!ResetTags.HasTagExact(AethelnGameplayTags::State_Dead)) { return TEXT("does not reset on State.Dead"); }
	if (!FMath::IsFinite(ProvisionalMaxSampleDistance) || ProvisionalMaxSampleDistance <= 0.0
		|| !FMath::IsFinite(ProvisionalMaxSampleAngleDegrees) || ProvisionalMaxSampleAngleDegrees <= 0.0)
	{
		return TEXT("has unset or invalid sampling bounds");
	}
	const FGameplayTagContainer Commitment(CommitmentTag);
	if (!CommitmentTag.IsValid() || Commitment.HasAny(ActivationBlockedTags) || Commitment.HasAny(ResetTags))
	{
		return TEXT("blocks or resets its own commitment");
	}
	for (const FGameplayTag Tag : ActivationBlockedTags)
	{
		if (!ResetTags.HasTagExact(Tag)) { return TEXT("has a blocking tag without a reset event"); }
	}
	for (int32 Index = 0; Index < ProvisionalSteps.Num(); ++Index)
	{
		if (const TCHAR* Problem = AethelnAttackTimeline::FindStepProblem(ProvisionalSteps[Index], Index == StepCount - 1)) { return Problem; }
	}
	return nullptr;
}

bool UAethelnBasicChainAbility::CanActivateAbility(FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo,
	const FGameplayTagContainer* SourceTags, const FGameplayTagContainer* TargetTags, FGameplayTagContainer* OptionalRelevantTags) const
{
	const UAethelnAbilitySystemComponent* ASC = Cast<UAethelnAbilitySystemComponent>(ActorInfo != nullptr ? ActorInfo->AbilitySystemComponent.Get() : nullptr);
	return ASC != nullptr && !ASC->HasAnyMatchingGameplayTags(ResetTags) && FindGrantProblem() == nullptr
		&& Super::CanActivateAbility(Handle, ActorInfo, SourceTags, TargetTags, OptionalRelevantTags);
}

void UAethelnBasicChainAbility::ActivateAbility(
	FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo,
	FGameplayAbilityActivationInfo ActivationInfo, const FGameplayEventData* TriggerEventData)
{
	UAethelnAbilitySystemComponent* ASC = Cast<UAethelnAbilitySystemComponent>(ActorInfo != nullptr ? ActorInfo->AbilitySystemComponent.Get() : nullptr);
	const FGuid StartingOperationId = GetActivationOperationId();
	if (ASC != nullptr && ASC->IsSeamActivating(Handle) && ASC->ActiveSeamScope->ActivationId != StartingOperationId) { return; }
	const FGameplayAbilityActorInfo OriginalActorInfo = GetActivationActorInfo();
	bJoinedTimeline = false;
	if (ASC == nullptr || !ASC->IsOwnerActorAuthoritative() || !ASC->IsSeamActivating(Handle)
		|| ASC->ActiveSeamScope->bCanceled || !HasActivationLifecycle()
		|| FindGrantProblem() != nullptr || ASC->ActiveSeamScope->AttackInput.ContentVersion != ContentVersion
		|| ASC->GetCombatTimeline() == nullptr || !ASC->GetCombatTimeline()->CanRegisterStep(*ASC))
	{
		EndAbility(Handle, &OriginalActorInfo, ActivationInfo, true, true);
		return;
	}
	const bool bCommitted = CommitAbility(Handle, &OriginalActorInfo, ActivationInfo);
	if (GetActivationOperationId() != StartingOperationId) { return; }
	if (!bCommitted || !IsActive() || ASC->ActiveSeamScope->bCanceled || !HasActivationLifecycle())
	{
		EndAbility(Handle, &OriginalActorInfo, ActivationInfo, true, true);
		return;
	}
	if (ASC->BeginChainPress(*this, Handle))
	{
		if (GetActivationOperationId() == StartingOperationId) { bJoinedTimeline = IsActive(); }
	}
	else if (GetActivationOperationId() == StartingOperationId)
	{
		// Never end a newer same-handle activation accepted by a synchronous callback.
		EndAbility(Handle, &OriginalActorInfo, ActivationInfo, true, true);
	}
}

void UAethelnBasicChainAbility::EndAtBufferOpen()
{
	if (IsActive()) { EndAbility(CurrentSpecHandle, CurrentActorInfo, CurrentActivationInfo, true, false); }
}

void UAethelnBasicChainAbility::EndAbility(
	FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo,
	FGameplayAbilityActivationInfo ActivationInfo, bool bReplicateEndAbility, bool bWasCancelled)
{
	UAethelnAbilitySystemComponent* ASC = Cast<UAethelnAbilitySystemComponent>(ActorInfo != nullptr ? ActorInfo->AbilitySystemComponent.Get() : nullptr);
	const bool bReset = bWasCancelled && bJoinedTimeline;
	const FGuid EndingActivationId = GetActivationOperationId();
	bJoinedTimeline = false;
	Super::EndAbility(Handle, ActorInfo, ActivationInfo, bReplicateEndAbility, bWasCancelled);
	if (bReset && ASC != nullptr && ASC->ChainState.bExists && ASC->ChainState.Handle == Handle
		&& (ASC->ChainState.bWaiting ? ASC->ChainState.BufferedInput.ActivationId : ASC->ChainState.CurrentInput.ActivationId) == EndingActivationId)
	{
		ASC->ResetChain(EAethelnChainEndReason::IncompatibleState);
	}
}
