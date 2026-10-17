#include "AethelnBasicChainAbility.h"

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatTimelineSubsystem.h"
#include "AethelnGameplayTags.h"
#include "Engine/World.h"
#include "Misc/PackageName.h"

UAethelnBasicChainAbility::UAethelnBasicChainAbility()
{
	SetAbilityId(AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain);
	CommitmentTag = AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain;
	ResetTags.AddTag(AethelnGameplayTags::State_Dead);
	// #18 Q17 and Q10: no attack while dodging or blocking. Each blocking tag is also a reset tag (grant rule).
	// #260 (default, open): nor inside a committed Instant Strike (its own constructor swaps this for the chain's).
	// Owner, 2026-10-14: nor while a Parry window is open, as for the block (Q10). Accepting a Parry resets a running chain
	// itself (OtherAction) before the tag is held, so the reset tag only guards a window that is somehow already open.
	for (const FGameplayTag Tag : { AethelnGameplayTags::State_Dodging.GetTag(), AethelnGameplayTags::State_Blocking.GetTag(),
		AethelnGameplayTags::State_Oathscar_InstantStrike.GetTag(), AethelnGameplayTags::State_Staggered.GetTag(), AethelnGameplayTags::State_Oathscar_Parrying.GetTag() })
	{
		ActivationBlockedTags.AddTag(Tag);
		ResetTags.AddTag(Tag);
	}
	// No preset in code: the values come only from the definition asset (#84 D3, TA-027), and an unset one fails grant.
}

const TCHAR* UAethelnBasicChainAbility::FindDefinitionProblem() const
{
	if (Definition.IsNull()) { return nullptr; }
	// The texts carry the validation identifiers, so they are built once from the constants tests and docs name.
	static const FString MissingText = FString::Printf(TEXT("references an attack definition asset that does not exist (%s)"), AethelnAttackDefinitionId::Missing);
	static const FString NoLoadText = FString::Printf(TEXT("references an attack definition asset that does not load (%s)"), AethelnAttackDefinitionId::Missing);
	static const FString InvalidText = FString::Printf(TEXT("references an invalid attack definition asset (%s)"), AethelnAttackDefinitionId::Invalid);
	static const FString MismatchText = FString::Printf(TEXT("references an attack definition asset of another ability (%s)"), AethelnAttackDefinitionId::AbilityMismatch);
	// An already loaded asset is found without file access, so the per-activation checks stay cheap.
	const UAethelnAttackDefinition* Loaded = Definition.Get();
	if (Loaded == nullptr)
	{
		// Checked before the load, so a missing asset is a refusal with an identifier and not a load error.
		if (!FPackageName::DoesPackageExist(Definition.GetLongPackageName()))
		{
			return *MissingText;
		}
		Loaded = Definition.LoadSynchronous();
	}
	if (Loaded == nullptr) { return *NoLoadText; }
	if (Loaded->FindProblem() != nullptr) { return *InvalidText; }
	if (Loaded->AbilityId != GetAbilityId()) { return *MismatchText; }
	return nullptr;
}

void UAethelnBasicChainAbility::ApplyDefinition()
{
	check(HasAnyFlags(RF_ClassDefaultObject));
	if (FindDefinitionProblem() != nullptr || Definition.IsNull()) { return; }
	LoadedDefinition = Definition.LoadSynchronous();
	ContentVersion = static_cast<uint32>(LoadedDefinition->ContentVersion);
	ProvisionalSteps = LoadedDefinition->Steps;
	ProvisionalMaxSampleDistance = LoadedDefinition->MaxSampleDistance;
	ProvisionalMaxSampleAngleDegrees = LoadedDefinition->MaxSampleAngleDegrees;
	ProvisionalEnduranceCost = LoadedDefinition->EnduranceCost;
}

void UAethelnBasicChainAbility::ApplyDefinitionToClassDefaults()
{
	TArray<UClass*> Classes;
	GetDerivedClasses(UAethelnBasicChainAbility::StaticClass(), Classes, true);
	Classes.Add(UAethelnBasicChainAbility::StaticClass());
	for (UClass* Class : Classes)
	{
		if (!Class->HasAnyClassFlags(CLASS_NewerVersionExists | CLASS_Deprecated))
		{
			Class->GetDefaultObject<UAethelnBasicChainAbility>()->ApplyDefinition();
		}
	}
}

const TCHAR* UAethelnBasicChainAbility::FindGrantProblem() const
{
	// First, so a missing asset names itself instead of the zero version it leaves behind.
	if (const TCHAR* Problem = FindDefinitionProblem()) { return Problem; }
	if (const TCHAR* Problem = Super::FindGrantProblem()) { return Problem; }
	// Every hit of a multi-step chain commits, so a chain cooldown would block its next hit; a single step may have one.
	if ((StepCount > 1 && ProvisionalCooldownSeconds != 0.0f) || bAcceptsRelease) { return TEXT("has a chain cooldown or Release route"); }
	if (StepCount < 1 || ProvisionalSteps.Num() != StepCount) { return TEXT("does not have its authored number of steps"); }
	if (!ResetTags.HasTagExact(AethelnGameplayTags::State_Dead)) { return TEXT("does not reset on State.Dead"); }
	const FGameplayTagContainer Commitment(CommitmentTag);
	if (!CommitmentTag.IsValid() || Commitment.HasAny(ActivationBlockedTags) || Commitment.HasAny(ResetTags))
	{
		return TEXT("blocks or resets its own commitment");
	}
	for (const FGameplayTag Tag : ActivationBlockedTags)
	{
		if (!ResetTags.HasTagExact(Tag)) { return TEXT("has a blocking tag without a reset event"); }
	}
	return AethelnAttackTimeline::FindStepListProblem(ProvisionalSteps, ProvisionalMaxSampleDistance, ProvisionalMaxSampleAngleDegrees);
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
