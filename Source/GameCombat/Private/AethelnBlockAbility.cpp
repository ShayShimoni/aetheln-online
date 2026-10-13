#include "AethelnBlockAbility.h"

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatEffects.h"
#include "AethelnCombatTimelineSubsystem.h"
#include "AethelnGameplayTags.h"
#include "Engine/World.h"

UAethelnBlockAbility::UAethelnBlockAbility()
{
	SetAbilityId(AethelnGameplayTags::Ability_Block);
	SetCooldownTag(AethelnGameplayTags::Cooldown_Block);
	bAcceptsRelease = true;
	// Q8: no raise during a Guard break. Q10: no raise while dodging or inside the chain's commitment.
	ActivationBlockedTags.AddTag(AethelnGameplayTags::State_GuardBroken);
	ActivationBlockedTags.AddTag(AethelnGameplayTags::State_Dodging);
	ActivationBlockedTags.AddTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain);
	// #260 (default, open): a committed Instant Strike also blocks the raise.
	ActivationBlockedTags.AddTag(AethelnGameplayTags::State_Oathscar_InstantStrike);
	// No authored version, raise, arc, break, cost or cooldown preset: unset production config fails grant.
}

const TCHAR* UAethelnBlockAbility::FindGrantProblem() const
{
	if (const TCHAR* Problem = Super::FindGrantProblem()) { return Problem; }
	if (IsMovementCarried() || !bAcceptsRelease) { return TEXT("is not a held seam ability that accepts Release"); }
	for (const FGameplayTag Tag : { AethelnGameplayTags::State_Dead.GetTag(), AethelnGameplayTags::State_GuardBroken.GetTag(),
		AethelnGameplayTags::State_Dodging.GetTag(), AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain.GetTag() })
	{
		if (!ActivationBlockedTags.HasTagExact(Tag)) { return TEXT("lacks a required blocking tag"); }
	}
	if (!FMath::IsFinite(ProvisionalRaiseSeconds) || ProvisionalRaiseSeconds < 0.0f) { return TEXT("has an invalid raise time"); }
	if (!FMath::IsFinite(ProvisionalArcHalfAngleDegrees) || !(ProvisionalArcHalfAngleDegrees > 0.0f) || ProvisionalArcHalfAngleDegrees > 180.0f)
	{
		return TEXT("has an arc half-angle outside (0, 180]");
	}
	if (!FMath::IsFinite(ProvisionalGuardBreakSeconds) || ProvisionalGuardBreakSeconds < 0.0f) { return TEXT("has an invalid Guard break duration"); }
	return nullptr;
}

bool UAethelnBlockAbility::CheckCost(const FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo, FGameplayTagContainer* OptionalRelevantTags) const
{
	const UAbilitySystemComponent* ASC = ActorInfo != nullptr ? ActorInfo->AbilitySystemComponent.Get() : nullptr;
	return Super::CheckCost(Handle, ActorInfo, OptionalRelevantTags)
		&& ASC != nullptr && ASC->GetNumericAttribute(UAethelnCombatAttributeSet::GetGuardAttribute()) > 0.0f;
}

void UAethelnBlockAbility::ActivateAbility(
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
	// The slot before the commit: a refused slot (one is still held) ends uncommitted, InternalFailure, nothing spent.
	FAethelnDefenseState Slot;
	Slot.StateTag = AethelnGameplayTags::State_Blocking;
	Slot.ActiveFromServerTime = ASC->ActiveSeamScope->AttackInput.ReceiptServerTime + ProvisionalRaiseSeconds;
	Slot.ArcDegrees = 2.0 * ProvisionalArcHalfAngleDegrees;
	Slot.OnBlocked.BindUObject(this, &UAethelnBlockAbility::HandleBlockedHit);
	if (!Timeline->SetDefenseState(*ASC, Slot))
	{
		EndAbility(Handle, &OriginalActorInfo, ActivationInfo, true, true);
		return;
	}
	bHoldsSlot = true;
	const bool bCommitted = CommitAbility(Handle, &OriginalActorInfo, ActivationInfo);
	// A synchronous cost/tag/avatar callback replaced this operation: it owns the instance now.
	if (GetActivationOperationId() != OperationId) { return; }
	if (!bCommitted || !IsActive() || ASC->ActiveSeamScope->bCanceled || !HasActivationLifecycle())
	{
		EndAbility(Handle, &OriginalActorInfo, ActivationInfo, true, true); // a failed commit ends the slot unused
		return;
	}
	// After the commit, so the chain resets once with OtherAction rather than through its State.Blocking reset tag.
	bHoldsStateTag = true;
	ASC->AddLooseGameplayTag(AethelnGameplayTags::State_Blocking, 1, EGameplayTagReplicationState::TagOnly);
	if (GetActivationOperationId() != OperationId || !IsActive()) { return; }
	DeadHandle = ASC->RegisterGameplayTagEvent(AethelnGameplayTags::State_Dead, EGameplayTagEventType::NewOrRemoved)
		.AddUObject(this, &UAethelnBlockAbility::HandleDeadTag);
}

EAethelnBlockConsequence UAethelnBlockAbility::HandleBlockedHit(const FAethelnBlockedContact& Contact)
{
	UAethelnAbilitySystemComponent* ASC = Cast<UAethelnAbilitySystemComponent>(CurrentActorInfo != nullptr ? CurrentActorInfo->AbilitySystemComponent.Get() : nullptr);
	if (ASC == nullptr) { return EAethelnBlockConsequence::Blocked; }
	// 1. Guard pressure, once, from the attacker's ASC. The attribute set clamps Guard at zero.
	UAethelnAbilitySystemComponent* Source = Contact.Source.Get();
	if (Source != nullptr && FMath::IsFinite(Contact.GuardPressure) && Contact.GuardPressure > 0.0f)
	{
		const FGameplayEffectSpecHandle Pressure = Source->MakeOutgoingSpec(UAethelnGuardPressureEffect::StaticClass(), 1.0f, Source->MakeEffectContext());
		if (Pressure.IsValid())
		{
			Pressure.Data->SetSetByCallerMagnitude(AethelnGameplayTags::SetByCaller_Pressure_Guard, -Contact.GuardPressure);
			Source->ApplyGameplayEffectSpecToTarget(*Pressure.Data.Get(), ASC);
			// Pressure, including a breaking one, restarts the defender's Guard recovery delay (#292).
			UAethelnResourceRecoveryEffect::RestartDelay(*ASC, UAethelnGuardRecoveryEffect::StaticClass());
		}
	}
	if (ASC->GetNumericAttribute(UAethelnCombatAttributeSet::GetGuardAttribute()) > 0.0f) { return EAethelnBlockConsequence::Blocked; }
	// 2. Guard break (Q8): the slot ends at the contact time, so later contacts, including same-time ones
	// later in the total order, are not blocked. No raise for GuardBreakSeconds; no stagger or interruption.
	if (UAethelnCombatTimelineSubsystem* Timeline = ASC->GetCombatTimeline()) { Timeline->EndDefenseState(*ASC, Contact.ContactTime); }
	if (ProvisionalGuardBreakSeconds > 0.0f)
	{
		// The shared duration effect, as a cooldown is applied; a zero duration would never expire, so none is applied.
		const FGameplayEffectSpecHandle Break = ASC->MakeOutgoingSpec(UAethelnCooldownEffect::StaticClass(), 1.0f, ASC->MakeEffectContext());
		if (Break.IsValid())
		{
			Break.Data->SetSetByCallerMagnitude(AethelnGameplayTags::SetByCaller_Cooldown_Duration, ProvisionalGuardBreakSeconds);
			Break.Data->DynamicGrantedTags.AddTag(AethelnGameplayTags::State_GuardBroken);
			ASC->ApplyGameplayEffectSpecToSelf(*Break.Data.Get());
			// Death ends the break, so a respawned avatar never inherits it (stale control state).
			if (!BreakDeadHandle.IsValid())
			{
				BreakDeadHandle = ASC->RegisterGameplayTagEvent(AethelnGameplayTags::State_Dead, EGameplayTagEventType::NewOrRemoved)
					.AddUObject(this, &UAethelnBlockAbility::HandleDeadDuringBreak);
			}
		}
	}
	if (IsActive()) { EndAbility(CurrentSpecHandle, CurrentActorInfo, CurrentActivationInfo, true, false); }
	return EAethelnBlockConsequence::GuardBroken;
}

void UAethelnBlockAbility::HandleDeadTag(const FGameplayTag Tag, int32 NewCount)
{
	UAbilitySystemComponent* ASC = CurrentActorInfo != nullptr ? CurrentActorInfo->AbilitySystemComponent.Get() : nullptr;
	if (NewCount > 0 && ASC != nullptr && IsActive()) { ASC->CancelAbilityHandle(CurrentSpecHandle); }
}

void UAethelnBlockAbility::HandleDeadDuringBreak(const FGameplayTag Tag, int32 NewCount)
{
	UAbilitySystemComponent* ASC = CurrentActorInfo != nullptr ? CurrentActorInfo->AbilitySystemComponent.Get() : nullptr;
	if (NewCount <= 0 || ASC == nullptr) { return; }
	ASC->RegisterGameplayTagEvent(AethelnGameplayTags::State_Dead, EGameplayTagEventType::NewOrRemoved).Remove(BreakDeadHandle);
	BreakDeadHandle.Reset();
	ASC->RemoveActiveEffectsWithGrantedTags(FGameplayTagContainer(AethelnGameplayTags::State_GuardBroken));
}

void UAethelnBlockAbility::EndAbility(
	const FGameplayAbilitySpecHandle Handle,
	const FGameplayAbilityActorInfo* ActorInfo,
	const FGameplayAbilityActivationInfo ActivationInfo,
	bool bReplicateEndAbility,
	bool bWasCancelled)
{
	// Release, dodge, State.Dead, avatar loss and teardown end the slot at their processing time; a Guard break
	// already stamped the earlier contact time. Done before the GAS end callbacks, so a new raise finds it ended.
	if (UAethelnAbilitySystemComponent* ASC = Cast<UAethelnAbilitySystemComponent>(ActorInfo != nullptr ? ActorInfo->AbilitySystemComponent.Get() : nullptr))
	{
		const UWorld* World = ASC->GetWorld();
		if (bHoldsSlot)
		{
			bHoldsSlot = false;
			if (UAethelnCombatTimelineSubsystem* Timeline = ASC->GetCombatTimeline()) { Timeline->EndDefenseState(*ASC, World != nullptr ? World->GetTimeSeconds() : 0.0); }
		}
		if (DeadHandle.IsValid())
		{
			ASC->RegisterGameplayTagEvent(AethelnGameplayTags::State_Dead, EGameplayTagEventType::NewOrRemoved).Remove(DeadHandle);
			DeadHandle.Reset();
		}
		if (bHoldsStateTag)
		{
			bHoldsStateTag = false;
			ASC->RemoveLooseGameplayTag(AethelnGameplayTags::State_Blocking, 1, EGameplayTagReplicationState::TagOnly);
		}
	}
	Super::EndAbility(Handle, ActorInfo, ActivationInfo, bReplicateEndAbility, bWasCancelled);
}
