#include "AethelnOathscarAbilities.h"

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatEffects.h"
#include "AethelnCombatTimelineSubsystem.h"
#include "AethelnGameplayTags.h"
#include "Engine/World.h"
#include "GameFramework/PlayerState.h"

UAethelnInstantStrikeAbility::UAethelnInstantStrikeAbility()
{
	SetAbilityId(AethelnGameplayTags::Ability_Oathscar_InstantStrike);
	SetCooldownTag(AethelnGameplayTags::Cooldown_Oathscar_InstantStrike);
	StepCount = 1;
	CommitmentTag = AethelnGameplayTags::State_Oathscar_InstantStrike;
	// The chain's constructor blocks and resets on a committed Instant Strike; this ability must not block itself.
	// Owner, 2026-10-13: it is refused inside the three-hit chain's commitment window, as dodge and block are.
	// The inherited grant rule makes the blocking tag also an authored reset tag.
	ActivationBlockedTags.RemoveTag(AethelnGameplayTags::State_Oathscar_InstantStrike);
	ResetTags.RemoveTag(AethelnGameplayTags::State_Oathscar_InstantStrike);
	ActivationBlockedTags.AddTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain);
	ResetTags.AddTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain);
}

const TCHAR* UAethelnInstantStrikeAbility::FindGrantProblem() const
{
	if (const TCHAR* Problem = Super::FindGrantProblem()) { return Problem; }
	// Owner, 2026-10-13: a relatively low cooldown. Its length is TBD; a zero cooldown is not a decision, so it fails closed.
	if (!(ProvisionalCooldownSeconds > 0.0f)) { return TEXT("has no cooldown"); }
	// The base guarantees exactly one valid step. Owner: pure damage, with no Guard drain, interruption, or knockback.
	if (ProvisionalSteps[0].GuardPressure != 0.0f || ProvisionalSteps[0].bInterruptsTarget) { return TEXT("is not pure damage"); }
	// Refused inside the chain's commitment window, and the blocking tag is an authored reset tag.
	if (!ActivationBlockedTags.HasTagExact(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain)
		|| !ResetTags.HasTagExact(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain))
	{
		return TEXT("is not refused inside the chain's commitment window");
	}
	return nullptr;
}

UAethelnParryAbility::UAethelnParryAbility()
{
	SetAbilityId(AethelnGameplayTags::Ability_Oathscar_Parry);
	SetCooldownTag(AethelnGameplayTags::Cooldown_Oathscar_Parry);
	// Defaults, open (docs/gas-foundation.md, Action relations): refused while dodging or blocking (one defense slot per
	// ASC) and inside a committed chain or strike. State.Staggered and State.Dead come from the base ability.
	ActivationBlockedTags.AddTag(AethelnGameplayTags::State_Dodging);
	ActivationBlockedTags.AddTag(AethelnGameplayTags::State_Blocking);
	ActivationBlockedTags.AddTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain);
	ActivationBlockedTags.AddTag(AethelnGameplayTags::State_Oathscar_InstantStrike);
	// No authored version, window, arc, stagger, cost or cooldown preset: unset production config fails grant.
}

const TCHAR* UAethelnParryAbility::FindGrantProblem() const
{
	if (const TCHAR* Problem = Super::FindGrantProblem()) { return Problem; }
	if (IsMovementCarried() || bAcceptsRelease) { return TEXT("is not a Press-only seam ability"); }
	for (const FGameplayTag Tag : { AethelnGameplayTags::State_Dead.GetTag(), AethelnGameplayTags::State_Dodging.GetTag(), AethelnGameplayTags::State_Blocking.GetTag(),
		AethelnGameplayTags::State_Staggered.GetTag(), AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain.GetTag(), AethelnGameplayTags::State_Oathscar_InstantStrike.GetTag() })
	{
		if (!ActivationBlockedTags.HasTagExact(Tag)) { return TEXT("lacks a required blocking tag"); }
	}
	const FAethelnParryDefinition& P = ProvisionalParry;
	for (const float Value : { P.WindowStart, P.WindowEnd, P.ArcDegrees, P.StaggerSeconds })
	{
		if (!FMath::IsFinite(Value)) { return TEXT("has a non-finite parry value"); }
	}
	// The window starts at or after the server acceptance and is not empty: an unset (all zero) window defends nothing.
	if (P.WindowStart < 0.0f || !(P.WindowEnd > P.WindowStart)) { return TEXT("has an empty window or one that starts before acceptance"); }
	if (!(P.ArcDegrees > 0.0f) || P.ArcDegrees > 360.0f) { return TEXT("has an arc outside (0, 360]"); }
	if (P.StaggerSeconds < 0.0f) { return TEXT("has a negative stagger duration"); }
	return nullptr;
}

void UAethelnParryAbility::ActivateAbility(
	const FGameplayAbilitySpecHandle Handle,
	const FGameplayAbilityActorInfo* ActorInfo,
	const FGameplayAbilityActivationInfo ActivationInfo,
	const FGameplayEventData* TriggerEventData)
{
	UAethelnAbilitySystemComponent* ASC = Cast<UAethelnAbilitySystemComponent>(ActorInfo != nullptr ? ActorInfo->AbilitySystemComponent.Get() : nullptr);
	const FGuid OperationId = GetActivationOperationId();
	if (ASC != nullptr && ASC->IsSeamActivating(Handle) && ASC->ActiveSeamScope->ActivationId != OperationId) { return; }
	const FGameplayAbilityActorInfo OriginalActorInfo = GetActivationActorInfo();
	UAethelnCombatTimelineSubsystem* Timeline = ASC != nullptr ? ASC->GetCombatTimeline() : nullptr;
	if (ASC == nullptr || Timeline == nullptr || !ASC->IsOwnerActorAuthoritative() || !ASC->IsSeamActivating(Handle)
		|| ASC->ActiveSeamScope->bMovementCarried || ASC->ActiveSeamScope->bCanceled || !HasActivationLifecycle() || FindGrantProblem() != nullptr)
	{
		EndAbility(Handle, &OriginalActorInfo, ActivationInfo, true, true);
		return;
	}
	// The slot before the commit, with its whole interval fixed at the server acceptance: a refused slot ends uncommitted
	// (InternalFailure, nothing spent), and a failed commit clears it. The client cannot move the window earlier.
	const double Start = ASC->ActiveSeamScope->AttackInput.ReceiptServerTime;
	FAethelnDefenseState Slot;
	Slot.StateTag = AethelnGameplayTags::State_Oathscar_Parrying;
	Slot.ActiveFromServerTime = Start + ProvisionalParry.WindowStart;
	Slot.ActiveUntilServerTime = Start + ProvisionalParry.WindowEnd;
	Slot.ArcDegrees = ProvisionalParry.ArcDegrees;
	Slot.OnBlocked.BindUObject(this, &UAethelnParryAbility::HandleParriedHit);
	if (!Timeline->SetDefenseState(*ASC, Slot))
	{
		EndAbility(Handle, &OriginalActorInfo, ActivationInfo, true, true);
		return;
	}
	bHoldsSlot = true;
	// The end boundary before the commit too, so a refused boundary spends nothing; a failed commit closes it again.
	if (!ASC->OpenParryWindow(OperationId, Handle, Slot.ActiveUntilServerTime))
	{
		EndAbility(Handle, &OriginalActorInfo, ActivationInfo, true, true);
		return;
	}
	const bool bCommitted = CommitAbility(Handle, &OriginalActorInfo, ActivationInfo);
	// A synchronous cost/tag/avatar callback replaced this operation: it owns the instance now.
	if (GetActivationOperationId() != OperationId) { return; }
	if (!bCommitted || !IsActive() || ASC->ActiveSeamScope->bCanceled || !HasActivationLifecycle())
	{
		EndAbility(Handle, &OriginalActorInfo, ActivationInfo, true, true); // a failed commit ends the slot and the window unused
		return;
	}
	bHoldsStateTag = true;
	ASC->AddLooseGameplayTag(AethelnGameplayTags::State_Oathscar_Parrying, 1, EGameplayTagReplicationState::TagOnly);
	if (GetActivationOperationId() != OperationId || !IsActive()) { return; }
	DeadHandle = ASC->RegisterGameplayTagEvent(AethelnGameplayTags::State_Dead, EGameplayTagEventType::NewOrRemoved)
		.AddUObject(this, &UAethelnParryAbility::HandleDeadTag);
}

EAethelnBlockConsequence UAethelnParryAbility::HandleParriedHit(const FAethelnBlockedContact& Contact)
{
	// Fully negated: no damage, no Guard pressure, no Guard break. The attacker is staggered once through the interruption
	// path, at the contact time and without its step's InterruptibleUntil check (the Parry is the authored rule).
	UAethelnAbilitySystemComponent* Attacker = Contact.Source.Get();
	if (Attacker != nullptr)
	{
		if (UAethelnCombatTimelineSubsystem* Timeline = Attacker->GetCombatTimeline()) { Timeline->ForceInterrupt(*Attacker, Contact.ContactTime); }
		// A player attacker also holds State.Staggered; a zero duration grants nothing. An enemy's stagger is #20's.
		if (Cast<APlayerState>(Attacker->GetOwner()) != nullptr) { UAethelnStaggerEffect::ApplyTo(*Attacker, ProvisionalParry.StaggerSeconds); }
	}
	return EAethelnBlockConsequence::Parried;
}

void UAethelnParryAbility::HandleDeadTag(const FGameplayTag Tag, int32 NewCount)
{
	UAbilitySystemComponent* ASC = CurrentActorInfo != nullptr ? CurrentActorInfo->AbilitySystemComponent.Get() : nullptr;
	if (NewCount > 0 && ASC != nullptr && IsActive()) { ASC->CancelAbilityHandle(CurrentSpecHandle); }
}

void UAethelnParryAbility::EndAtWindowEnd()
{
	if (IsActive()) { EndAbility(CurrentSpecHandle, CurrentActorInfo, CurrentActivationInfo, true, false); }
}

void UAethelnParryAbility::EndAbility(
	const FGameplayAbilitySpecHandle Handle,
	const FGameplayAbilityActorInfo* ActorInfo,
	const FGameplayAbilityActivationInfo ActivationInfo,
	bool bReplicateEndAbility,
	bool bWasCancelled)
{
	// A dodge, State.Dead, avatar loss and teardown end the slot at their processing time; the normal end is the slot's
	// own WindowEnd (EndDefenseState keeps the earlier time). Done before the GAS end callbacks, so a new Parry finds it ended.
	if (UAethelnAbilitySystemComponent* ASC = Cast<UAethelnAbilitySystemComponent>(ActorInfo != nullptr ? ActorInfo->AbilitySystemComponent.Get() : nullptr))
	{
		const UWorld* World = ASC->GetWorld();
		if (bHoldsSlot)
		{
			bHoldsSlot = false;
			if (UAethelnCombatTimelineSubsystem* Timeline = ASC->GetCombatTimeline()) { Timeline->EndDefenseState(*ASC, World != nullptr ? World->GetTimeSeconds() : 0.0); }
		}
		ASC->CloseParryWindow(GetActivationOperationId());
		if (DeadHandle.IsValid())
		{
			ASC->RegisterGameplayTagEvent(AethelnGameplayTags::State_Dead, EGameplayTagEventType::NewOrRemoved).Remove(DeadHandle);
			DeadHandle.Reset();
		}
		if (bHoldsStateTag)
		{
			bHoldsStateTag = false;
			ASC->RemoveLooseGameplayTag(AethelnGameplayTags::State_Oathscar_Parrying, 1, EGameplayTagReplicationState::TagOnly);
		}
	}
	Super::EndAbility(Handle, ActorInfo, ActivationInfo, bReplicateEndAbility, bWasCancelled);
}
