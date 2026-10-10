#include "AethelnCombatTimelineSubsystem.h"

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatCollision.h"
#include "AethelnCombatEffects.h"
#include "AethelnGameplayAbility.h"
#include "AethelnGameplayTags.h"
#include "AethelnObservability.h"
#include "AethelnObservabilitySubsystem.h"
#include "Components/CapsuleComponent.h"
#include "Engine/GameInstance.h"
#include "Engine/World.h"
#include "GameFramework/Character.h"
#include "GameFramework/PlayerState.h"

namespace AethelnAttackTimeline
{
	bool IsWithinWindow(double Time, double Start, double End)
	{
		return FMath::IsFinite(Time) && FMath::IsFinite(Start) && FMath::IsFinite(End) && Start <= Time && Time < End;
	}

	FAethelnAttackSampleInterval ClipActiveInterval(const FAethelnAttackStepDefinition& Step, double Start, double LastSample, double Now, double ResetTime)
	{
		FAethelnAttackSampleInterval Result;
		if (!FMath::IsFinite(Start) || !FMath::IsFinite(LastSample) || !FMath::IsFinite(Now)
			|| !FMath::IsFinite(ResetTime) || !FMath::IsFinite(Step.ActiveStart) || !FMath::IsFinite(Step.ActiveEnd)
			|| Step.ActiveStart < 0.0 || Step.ActiveEnd <= Step.ActiveStart || Now < LastSample) { return Result; }
		Result.FromSeconds = FMath::Max(LastSample, Start + Step.ActiveStart);
		Result.ToSeconds = FMath::Min(FMath::Min(Now, Start + Step.ActiveEnd), ResetTime);
		Result.bValid = Result.FromSeconds < Result.ToSeconds;
		Result.bIncludesInitialOverlap = Result.bValid && LastSample <= Start + Step.ActiveStart;
		return Result;
	}

	int32 GetSubstepCount(double Distance, double AngleDegrees, double MaxDistance, double MaxAngleDegrees)
	{
		if (!FMath::IsFinite(Distance) || Distance < 0.0 || !FMath::IsFinite(AngleDegrees) || AngleDegrees < 0.0
			|| !FMath::IsFinite(MaxDistance) || MaxDistance <= 0.0 || !FMath::IsFinite(MaxAngleDegrees) || MaxAngleDegrees <= 0.0) { return 0; }
		const double Count = FMath::Max(1.0, FMath::Max(FMath::CeilToDouble(Distance / MaxDistance), FMath::CeilToDouble(AngleDegrees / MaxAngleDegrees)));
		return FMath::IsFinite(Count) && Count <= static_cast<double>(MAX_int32) ? static_cast<int32>(Count) : 0;
	}
}

namespace
{
	/** Not alive: State.Dead, no Health attribute (fails closed until #21), or zero Health. */
	bool IsAlive(const UAethelnAbilitySystemComponent& AbilitySystem)
	{
		const FGameplayAttribute Health = UAethelnCombatAttributeSet::GetHealthAttribute();
		return !AbilitySystem.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead)
			&& AbilitySystem.HasAttributeSetForAttribute(Health)
			&& AbilitySystem.GetNumericAttribute(Health) > 0.0f;
	}

	FCollisionShape MakeShape(const FAethelnAttackStepDefinition& Step)
	{
		switch (Step.Shape)
		{
		case EAethelnAttackShape::Capsule: return FCollisionShape::MakeCapsule(static_cast<float>(Step.ShapeExtent.X), static_cast<float>(Step.ShapeExtent.Z));
		case EAethelnAttackShape::Box: return FCollisionShape::MakeBox(Step.ShapeExtent);
		default: return FCollisionShape::MakeSphere(static_cast<float>(Step.ShapeExtent.X));
		}
	}
}

bool UAethelnCombatTimelineSubsystem::ShouldCreateSubsystem(UObject* Outer) const
{
	const UWorld* World = Cast<UWorld>(Outer);
	return Super::ShouldCreateSubsystem(Outer) && World != nullptr
		&& (World->WorldType == EWorldType::Game || World->WorldType == EWorldType::PIE)
		&& World->GetNetMode() != NM_Client;
}

void UAethelnCombatTimelineSubsystem::Initialize(FSubsystemCollectionBase& Collection)
{
	Super::Initialize(Collection);
	TickHandle = FWorldDelegates::OnWorldPostActorTick.AddUObject(this, &UAethelnCombatTimelineSubsystem::HandlePostActorTick);
}

void UAethelnCombatTimelineSubsystem::Deinitialize()
{
	FWorldDelegates::OnWorldPostActorTick.Remove(TickHandle);
	const auto Sources = AbilitySystems;
	for (const auto& Source : Sources)
	{
		if (UAethelnAbilitySystemComponent* ASC = Source.Get()) { ASC->ResetChain(EAethelnChainEndReason::AvatarLost); }
	}
	Steps.Reset(); AbilitySystems.Reset(); CombatIds.Reset(); Defenses.Reset();
	OnWindowEvaluated.Clear(); OnResultCommitted.Clear(); OnLethalResult.Clear();
	Super::Deinitialize();
}

uint32 UAethelnCombatTimelineSubsystem::GetOrAssignCombatId(UAethelnAbilitySystemComponent& ASC)
{
	const TWeakObjectPtr<UAethelnAbilitySystemComponent> Key(&ASC);
	if (const uint32* Existing = CombatIds.Find(Key)) { return *Existing; }
	return NextCombatId != MAX_uint32 ? CombatIds.Add(Key, NextCombatId++) : 0;
}

bool UAethelnCombatTimelineSubsystem::RegisterStep(UAethelnAbilitySystemComponent& ASC, const FAethelnAttackStepDefinition& Definition,
	FAethelnCombatActivationRecord& Record, double MaxSampleDistance, double MaxSampleAngleDegrees)
{
	AActor* Avatar = ASC.GetAvatarActor();
	if (!CanRegisterStep(ASC) || Avatar == nullptr || !Record.ActivationId.IsValid() || Record.ChainStep < 1 || Record.ChainStep > 3) { return false; }
	Record.InstigatorCombatId = GetOrAssignCombatId(ASC);
	FStep& Entry = Steps.AddDefaulted_GetRef();
	Entry.AbilitySystem = &ASC; Entry.Avatar = Avatar; Entry.Definition = Definition; Entry.Record = Record;
	Entry.Ordinal = NextOrdinal++; Entry.LastSample = Record.StartServerTime; Entry.LastOrigin = Avatar->GetActorLocation();
	Entry.MaxSampleDistance = MaxSampleDistance; Entry.MaxSampleAngleDegrees = MaxSampleAngleDegrees;
	AbilitySystems.AddUnique(TWeakObjectPtr<UAethelnAbilitySystemComponent>(&ASC));
	return true;
}

bool UAethelnCombatTimelineSubsystem::CanRegisterStep(const UAethelnAbilitySystemComponent& ASC) const
{
	return GetWorld() != nullptr && GetWorld()->GetNetMode() != NM_Client && ASC.GetWorld() == GetWorld()
		&& ASC.IsOwnerActorAuthoritative() && NextOrdinal != MAX_uint64 && NextCombatId != MAX_uint32;
}

void UAethelnCombatTimelineSubsystem::StampReset(const FGuid& ActivationId, double Time)
{
	if (!FMath::IsFinite(Time)) { return; }
	for (FStep& Entry : Steps)
	{
		if (Entry.Record.ActivationId == ActivationId) { Entry.ResetTime = FMath::Min(Entry.ResetTime, Time); }
	}
}

bool UAethelnCombatTimelineSubsystem::IsHostile(const UAethelnAbilitySystemComponent& Attacker, const UAethelnAbilitySystemComponent& Target)
{
	const bool bAttackerIsPlayer = Cast<APlayerState>(Attacker.GetOwner()) != nullptr;
	const bool bTargetIsPlayer = Cast<APlayerState>(Target.GetOwner()) != nullptr;
	return &Attacker != &Target && bAttackerIsPlayer != bTargetIsPlayer;
}

void UAethelnCombatTimelineSubsystem::SetDefenseState(UAethelnAbilitySystemComponent& Target, const FAethelnDefenseState& State)
{
	Defenses.Add(TWeakObjectPtr<UAethelnAbilitySystemComponent>(&Target), State);
}

void UAethelnCombatTimelineSubsystem::ClearDefenseState(UAethelnAbilitySystemComponent& Target)
{
	Defenses.Remove(TWeakObjectPtr<UAethelnAbilitySystemComponent>(&Target));
}

void UAethelnCombatTimelineSubsystem::HandlePostActorTick(UWorld* World, ELevelTick TickType, float DeltaSeconds)
{
	if (World != GetWorld() || World == nullptr || World->GetNetMode() == NM_Client) { return; }
	const double Now = World->GetTimeSeconds(); // Never DeltaSeconds or a client sample.
	const auto Sources = AbilitySystems;
	// 1. Buffered starts, at their exact authored time, before sweeping.
	for (const auto& Source : Sources)
	{
		if (UAethelnAbilitySystemComponent* ASC = Source.Get()) { ASC->StartBufferedChainStep(Now); }
	}
	Steps.Sort([](const FStep& A, const FStep& B) { return A.Ordinal < B.Ordinal; });
	// Snapshot identities: callbacks may register/reset; never retain an array reference across them.
	TArray<FGuid> Ids;
	for (const FStep& Entry : Steps) { Ids.Add(Entry.Record.ActivationId); }
	// 2. Sweeps, in activation-ordinal order, each step up to its reset time.
	TArray<FCandidate> Candidates;
	for (const FGuid& Id : Ids)
	{
		FStep* Entry = Steps.FindByPredicate([&Id](const FStep& Item) { return Item.Record.ActivationId == Id; });
		if (Entry == nullptr) { continue; }
		UAethelnAbilitySystemComponent* Attacker = Entry->AbilitySystem.Get();
		AActor* Avatar = Attacker != nullptr ? Attacker->GetAvatarActor() : nullptr;
		if (Avatar == nullptr || Avatar != Entry->Avatar.Get() || Avatar->IsActorBeingDestroyed())
		{
			// No authoritative origin: never sweep from a lost or replaced avatar. A live step ends its chain here,
			// including when the avatar went away without the PlayerState's null-pawn case.
			const bool bLive = Entry->ResetTime > Now;
			Entry->ResetTime = FMath::Min(Entry->ResetTime, Now);
			Entry->LastSample = Now;
			if (bLive && Attacker != nullptr) { Attacker->ResetChain(EAethelnChainEndReason::AvatarLost, Now); }
			continue;
		}
		const FVector NowOrigin = Avatar->GetActorLocation();
		const FAethelnAttackSampleInterval Interval = AethelnAttackTimeline::ClipActiveInterval(Entry->Definition, Entry->Record.StartServerTime, Entry->LastSample, Now, Entry->ResetTime);
		const FAethelnCombatActivationRecord Record = Entry->Record;
		if (Interval.bValid) { Sweep(*Entry, Interval, NowOrigin, Now, Candidates); }
		Entry->LastSample = Now;
		Entry->LastOrigin = NowOrigin;
		if (Interval.bValid) { OnWindowEvaluated.Broadcast(Record, Interval); }
	}
	// 3. Resolution in the canonical total order, never actor-iteration or packet order.
	Candidates.Sort([](const FCandidate& A, const FCandidate& B)
	{
		if (A.ContactTime != B.ContactTime) { return A.ContactTime < B.ContactTime; }
		if (A.Ordinal != B.Ordinal) { return A.Ordinal < B.Ordinal; }
		return A.TargetCombatId < B.TargetCombatId; // result slot is always 0 for the chain
	});
	TArray<FCommitted> Committed;
	for (const FCandidate& Candidate : Candidates) { Resolve(Candidate, Committed); }
	// 4. Boundaries; their authored times are never earlier than ActiveEnd.
	for (const auto& Source : Sources)
	{
		if (UAethelnAbilitySystemComponent* ASC = Source.Get()) { ASC->ApplyChainBoundaries(Now); }
	}
	// 5. Emission, then removal of reset steps.
	for (const FCommitted& Result : Committed) { Emit(Result); }
	Steps.RemoveAll([Now](const FStep& Entry) { return !Entry.AbilitySystem.IsValid() || Entry.ResetTime <= Now; });
	AbilitySystems.RemoveAll([](const auto& Source) { return !Source.IsValid() || !Source->ChainState.bExists; });
	for (auto Iterator = CombatIds.CreateIterator(); Iterator; ++Iterator)
	{
		if (!Iterator.Key().IsValid()) { Iterator.RemoveCurrent(); }
	}
	for (auto Iterator = Defenses.CreateIterator(); Iterator; ++Iterator)
	{
		if (!Iterator.Key().IsValid()) { Iterator.RemoveCurrent(); }
	}
}

void UAethelnCombatTimelineSubsystem::Sweep(const FStep& Entry, const FAethelnAttackSampleInterval& Interval, const FVector& NowOrigin, double Now, TArray<FCandidate>& OutCandidates)
{
	const FAethelnAttackStepDefinition& Step = Entry.Definition;
	const double ActiveStart = Entry.Record.StartServerTime + Step.ActiveStart;
	const double Span = Now - Entry.LastSample;
	// The combat frame: accepted yaw, pitch clamped, fixed for the step. Sockets, montages and root motion never move it.
	FRotator FrameRotation = FVector(Entry.Record.AcceptedAim).Rotation();
	FrameRotation.Pitch = FMath::Clamp(FrameRotation.Pitch, -Step.MaxAimPitchDegrees, Step.MaxAimPitchDegrees);
	FrameRotation.Roll = 0.0;
	const FQuat Frame = FrameRotation.Quaternion();
	// The server holds end-of-frame capsule centers only, so the origin is interpolated across the frame.
	const auto OriginAt = [&](double Time) { return FMath::Lerp(Entry.LastOrigin, NowOrigin, Span > 0.0 ? (Time - Entry.LastSample) / Span : 1.0); };
	const auto ShapeAt = [&](double Time)
	{
		FTransform Local;
		Local.Blend(Step.PathStart, Step.PathEnd, static_cast<float>((Time - ActiveStart) / (Step.ActiveEnd - Step.ActiveStart)));
		return Local * FTransform(Frame, OriginAt(Time));
	};
	const FTransform First = ShapeAt(Interval.FromSeconds);
	const FTransform Last = ShapeAt(Interval.ToSeconds);
	const int32 Count = AethelnAttackTimeline::GetSubstepCount(FVector::Dist(First.GetLocation(), Last.GetLocation()),
		FMath::RadiansToDegrees(First.GetRotation().AngularDistance(Last.GetRotation())), Entry.MaxSampleDistance, Entry.MaxSampleAngleDegrees);
	UWorld* World = GetWorld();
	const UAethelnAbilitySystemComponent* Attacker = Entry.AbilitySystem.Get();
	if (Count == 0 || World == nullptr || Attacker == nullptr) { return; } // unset or unrepresentable sampling fails closed
	const FCollisionShape Shape = MakeShape(Step);
	const FCollisionQueryParams Params(SCENE_QUERY_STAT(AethelnCombatSweep), false, Entry.Avatar.Get());
	const double SubstepSeconds = (Interval.ToSeconds - Interval.FromSeconds) / Count;
	for (int32 Index = 0; Index < Count; ++Index)
	{
		const double From = Interval.FromSeconds + Index * SubstepSeconds;
		const double To = Index + 1 == Count ? Interval.ToSeconds : From + SubstepSeconds;
		const FTransform Start = ShapeAt(From);
		TArray<FHitResult> Hits;
		// Engine sweeps translate at one rotation: each sub-sweep uses its start rotation.
		World->SweepMultiByChannel(Hits, Start.GetLocation(), ShapeAt(To).GetLocation(), Start.GetRotation(), AethelnCombatCollision::QueryChannel, Shape, Params);
#if WITH_DEV_AUTOMATION_TESTS
		++SweepCountForTests;
#endif
		for (const FHitResult& Hit : Hits)
		{
			// The target character's capsule only: a misconfigured mesh never creates a contact.
			const ACharacter* Character = Cast<ACharacter>(Hit.GetActor());
			if (Character == nullptr || Hit.GetComponent() != Character->GetCapsuleComponent()) { continue; }
			UAethelnAbilitySystemComponent* Target = UAethelnAbilitySystemComponent::FindForPawn(Character);
			const double ContactTime = From + FMath::Clamp(static_cast<double>(Hit.Time), 0.0, 1.0) * (To - From);
			// Half-open: the interval end is ActiveEnd, a reset, or the next pass's start.
			if (Target == nullptr || Target == Attacker || !(ContactTime < Interval.ToSeconds)) { continue; }
			const uint32 TargetCombatId = GetOrAssignCombatId(*Target);
			if (TargetCombatId == 0) { continue; }
			FCandidate& Candidate = OutCandidates.AddDefaulted_GetRef();
			Candidate.ContactTime = ContactTime;
			Candidate.Ordinal = Entry.Ordinal;
			Candidate.TargetCombatId = TargetCombatId;
			Candidate.ActivationId = Entry.Record.ActivationId;
			Candidate.Target = Target;
			Candidate.Location = Hit.bStartPenetrating ? Character->GetActorLocation() : FVector(Hit.ImpactPoint);
			Candidate.SourceOrigin = OriginAt(ContactTime);
		}
	}
}

void UAethelnCombatTimelineSubsystem::Resolve(const FCandidate& Candidate, TArray<FCommitted>& OutCommitted)
{
	FStep* Entry = Steps.FindByPredicate([&Candidate](const FStep& Item) { return Item.Record.ActivationId == Candidate.ActivationId; });
	UAethelnAbilitySystemComponent* Attacker = Entry != nullptr ? Entry->AbilitySystem.Get() : nullptr;
	UAethelnAbilitySystemComponent* Target = Candidate.Target.Get();
	// 1. Revalidate: not reset at or before the contact, both alive, hostile, the activation's content version.
	if (Attacker == nullptr || Target == nullptr || !(Candidate.ContactTime < Entry->ResetTime)
		|| !IsAlive(*Attacker) || !IsAlive(*Target) || !IsHostile(*Attacker, *Target)) { return; }
	const FGameplayAbilitySpec* Spec = Attacker->FindSpecForAbilityId(Entry->Record.AbilityId);
	const UAethelnGameplayAbility* Ability = Spec != nullptr ? Cast<UAethelnGameplayAbility>(Spec->Ability) : nullptr;
	if (Ability == nullptr || Ability->ContentVersion != Entry->Record.ContentVersion) { return; }
	// 2. Allowance: one result per target per activation, at most MaxTargets, never evicted.
	if (Entry->ResultTargets.Contains(Candidate.TargetCombatId) || Entry->ResultTargets.Num() >= Entry->Definition.MaxTargets) { return; }
	Entry->ResultTargets.Add(Candidate.TargetCombatId);
	FCommitted Committed;
	Committed.Target = Target;
	Committed.Result.ActivationId = Entry->Record.ActivationId;
	Committed.Result.Sequence = Entry->Record.Sequence;
	Committed.Result.AbilityId = Entry->Record.AbilityId;
	Committed.Result.InstigatorCombatId = Entry->Record.InstigatorCombatId;
	Committed.Result.TargetCombatId = Candidate.TargetCombatId;
	Committed.Result.ContactTime = Candidate.ContactTime;
	Committed.Cue.SourceAvatar = Entry->Avatar.Get();
	Committed.Cue.FamilyTag = AethelnGameplayTags::Damage_Wrought;
	Committed.Cue.ContactLocation = Candidate.Location;
	const float Damage = Entry->Definition.WroughtDamage;
	// Entry is not used past this point: effects and hooks may re-enter and register steps.
	const FAethelnDefenseState* Defense = Defenses.Find(Candidate.Target);
	const AActor* TargetAvatar = Target->GetAvatarActor();
	bool bBlocked = false;
	if (Defense != nullptr && TargetAvatar != nullptr && Defense->StateTag.IsValid() && Target->HasMatchingGameplayTag(Defense->StateTag)
		&& FMath::IsFinite(Defense->ArcDegrees) && Defense->ArcDegrees > 0.0 && Defense->ArcDegrees <= 360.0)
	{
		const FVector Facing = TargetAvatar->GetActorForwardVector().GetSafeNormal2D();
		const FVector Toward = (Candidate.SourceOrigin - TargetAvatar->GetActorLocation()).GetSafeNormal2D();
		bBlocked = !Toward.IsNearlyZero() && FMath::RadiansToDegrees(FMath::Acos(FMath::Clamp(Facing | Toward, -1.0, 1.0))) <= Defense->ArcDegrees * 0.5;
	}
	if (Target->HasAnyMatchingGameplayTags(AvoidanceTags))
	{
		// 3. Avoidance: a recorded result and nothing else.
		Committed.Result.Outcome = EAethelnCombatResultOutcome::Avoided;
	}
	else if (bBlocked)
	{
		// 4. Directional defense: recorded once; the defense owner's hook applies what a blocked hit does.
		Committed.Result.Outcome = EAethelnCombatResultOutcome::Blocked;
		const FAethelnBlockedHook Hook = Defense->OnBlocked;
		Hook.ExecuteIfBound(Committed.Result);
	}
	else
	{
		// 5. Wrought mitigation and 6. Ward have no prototype inputs. 7. Health, through the damage effect only.
		const FGameplayEffectSpecHandle DamageSpec = Attacker->MakeOutgoingSpec(UAethelnDamageEffect::StaticClass(), 1.0f, Attacker->MakeEffectContext());
		if (DamageSpec.IsValid())
		{
			DamageSpec.Data->SetSetByCallerMagnitude(AethelnGameplayTags::SetByCaller_Damage_Wrought, -Damage);
			DamageSpec.Data->AddDynamicAssetTag(AethelnGameplayTags::Damage_Wrought);
			Attacker->ApplyGameplayEffectSpecToTarget(*DamageSpec.Data.Get(), Target);
		}
		Target = Candidate.Target.Get();
		Committed.Result.bLethal = Target != nullptr && Target->HasAttributeSetForAttribute(UAethelnCombatAttributeSet::GetHealthAttribute())
			&& Target->GetNumericAttribute(UAethelnCombatAttributeSet::GetHealthAttribute()) <= 0.0f;
	}
	// 8. Commit; emission follows the frame's boundaries.
	Committed.Cue.Outcome = Committed.Result.Outcome;
	Committed.Cue.bLethal = Committed.Result.bLethal;
	OutCommitted.Add(Committed);
}

void UAethelnCombatTimelineSubsystem::Emit(const FCommitted& Committed)
{
	if (UAethelnAbilitySystemComponent* Target = Committed.Target.Get()) { Target->MulticastCombatResultCue(Committed.Cue); }
	// One hit event per committed result; target identity is not an allowlisted field.
	const UWorld* World = GetWorld();
	UGameInstance* GameInstance = World != nullptr ? World->GetGameInstance() : nullptr;
	if (UAethelnObservabilitySubsystem* Observability = GameInstance != nullptr ? GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>() : nullptr)
	{
		FAethelnObservabilityEvent Event;
		Event.Category = EAethelnObservabilityCategory::Hit;
		Event.SubjectCategory = EAethelnObservabilityCategory::Hit;
		Event.SafeReason = EAethelnSafeReason::Accepted;
		FAethelnObservabilityEventContext Context;
		Context.ConnectionPseudonym = AethelnObservability::ExcludedIdentifier;
		Context.ActivationId = Committed.Result.ActivationId.ToString(EGuidFormats::DigitsWithHyphensLower);
		Context.AbilityId = Committed.Result.AbilityId.ToString();
		Context.Sequence = Committed.Result.Sequence;
		Observability->EmitEvent(Event, Context);
	}
	OnResultCommitted.Broadcast(Committed.Result);
	if (Committed.Result.bLethal)
	{
		if (UAethelnAbilitySystemComponent* Target = Committed.Target.Get()) { OnLethalResult.Broadcast(Target, Committed.Result.ActivationId); }
	}
}
