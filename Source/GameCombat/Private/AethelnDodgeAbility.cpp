#include "AethelnDodgeAbility.h"

#include "AethelnAbilitySystemComponent.h"
#include "AethelnGameplayTags.h"
#include "Engine/World.h"

UAethelnDodgeAbility::UAethelnDodgeAbility()
{
	SetAbilityId(AethelnGameplayTags::Ability_Dodge);
	SetCooldownTag(AethelnGameplayTags::Cooldown_Dodge);
	bMovementCarried = true;
	// No authored version, definition, cost or cooldown preset: unset production config fails grant.
}

const TCHAR* UAethelnDodgeAbility::FindGrantProblem() const
{
	if (const TCHAR* Problem = Super::FindGrantProblem()) { return Problem; }
	if (!IsMovementCarried()) { return TEXT("is not movement-carried"); }
	if (!ActivationBlockedTags.HasTagExact(AethelnGameplayTags::State_Dead)) { return TEXT("does not list State.Dead among its blocking tags"); }
	const FAethelnDodgeDefinition& D = ProvisionalDodge;
	for (const float Value : { D.Distance, D.MoveDuration, D.InvulnerableStart, D.InvulnerableEnd, D.ActionEnd })
	{
		if (!FMath::IsFinite(Value)) { return TEXT("has a non-finite dodge value"); }
	}
	if (!(D.Distance > 0.0f) || !(D.MoveDuration > 0.0f) || !FMath::IsFinite(D.Distance / D.MoveDuration))
	{
		return TEXT("has a non-positive distance or move duration");
	}
	if (!(0.0f <= D.InvulnerableStart && D.InvulnerableStart < D.InvulnerableEnd && D.InvulnerableEnd <= D.ActionEnd))
	{
		return TEXT("has invalid invulnerability or action-end ordering");
	}
	if (D.MoveDuration > D.ActionEnd) { return TEXT("has a move duration beyond its action end"); }
	// Q4 (owner-approved 2026-10-10): a dodge always has an Endurance cost or a cooldown.
	if (!(ProvisionalEnduranceCost > 0.0f) && !(ProvisionalCooldownSeconds > 0.0f)) { return TEXT("has neither a cost nor a cooldown"); }
	return nullptr;
}

void UAethelnDodgeAbility::ActivateAbility(
	const FGameplayAbilitySpecHandle Handle,
	const FGameplayAbilityActorInfo* ActorInfo,
	const FGameplayAbilityActivationInfo ActivationInfo,
	const FGameplayEventData* TriggerEventData)
{
	UAethelnAbilitySystemComponent* ASC = Cast<UAethelnAbilitySystemComponent>(ActorInfo != nullptr ? ActorInfo->AbilitySystemComponent.Get() : nullptr);
	const FGuid OperationId = GetActivationOperationId();
	if (ASC != nullptr && ASC->IsSeamActivating(Handle) && ASC->ActiveSeamScope->ActivationId != OperationId) { return; }
	const FGameplayAbilityActorInfo OriginalActorInfo = GetActivationActorInfo();
	if (ASC == nullptr || !ASC->IsOwnerActorAuthoritative() || !ASC->IsSeamActivating(Handle) || !ASC->ActiveSeamScope->bMovementCarried
		|| ASC->ActiveSeamScope->bCanceled || !HasActivationLifecycle() || FindGrantProblem() != nullptr)
	{
		EndAbility(Handle, &OriginalActorInfo, ActivationInfo, true, true);
		return;
	}
	const bool bCommitted = CommitAbility(Handle, &OriginalActorInfo, ActivationInfo);
	// A synchronous cost/tag/avatar callback replaced this operation: it owns the instance now.
	if (GetActivationOperationId() != OperationId) { return; }
	if (!bCommitted || !IsActive() || ASC->ActiveSeamScope->bCanceled || !HasActivationLifecycle() || !ASC->OpenDodgeWindow(*this, Handle))
	{
		if (GetActivationOperationId() == OperationId) { EndAbility(Handle, &OriginalActorInfo, ActivationInfo, true, true); }
	}
}

void UAethelnDodgeAbility::EndAtActionEnd()
{
	if (IsActive()) { EndAbility(CurrentSpecHandle, CurrentActorInfo, CurrentActivationInfo, true, false); }
}

void UAethelnDodgeAbility::EndAbility(
	const FGameplayAbilitySpecHandle Handle,
	const FGameplayAbilityActorInfo* ActorInfo,
	const FGameplayAbilityActivationInfo ActivationInfo,
	bool bReplicateEndAbility,
	bool bWasCancelled)
{
	// Close before the GAS end callbacks run, so a replacement they accept opens on a clean slot.
	if (UAethelnAbilitySystemComponent* ASC = Cast<UAethelnAbilitySystemComponent>(ActorInfo != nullptr ? ActorInfo->AbilitySystemComponent.Get() : nullptr))
	{
		const UWorld* World = ASC->GetWorld();
		ASC->CloseDodgeWindow(GetActivationOperationId(), World != nullptr ? World->GetTimeSeconds() : 0.0, bWasCancelled);
	}
	Super::EndAbility(Handle, ActorInfo, ActivationInfo, bReplicateEndAbility, bWasCancelled);
}
