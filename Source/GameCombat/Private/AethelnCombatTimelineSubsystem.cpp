#include "AethelnCombatTimelineSubsystem.h"

#include "AethelnAbilitySystemComponent.h"
#include "Engine/World.h"

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
	Steps.Reset(); AbilitySystems.Reset(); CombatIds.Reset(); OnWindowEvaluated.Clear();
	Super::Deinitialize();
}

bool UAethelnCombatTimelineSubsystem::RegisterStep(UAethelnAbilitySystemComponent& ASC, const FAethelnAttackStepDefinition& Definition, FAethelnCombatActivationRecord& Record)
{
	if (!CanRegisterStep(ASC) || !Record.ActivationId.IsValid() || Record.ChainStep < 1 || Record.ChainStep > 3) { return false; }
	const TWeakObjectPtr<UAethelnAbilitySystemComponent> Key(&ASC);
	uint32* CombatId = CombatIds.Find(Key);
	if (CombatId == nullptr) { CombatId = &CombatIds.Add(Key, NextCombatId++); }
	Record.InstigatorCombatId = *CombatId;
	FStep& Entry = Steps.AddDefaulted_GetRef();
	Entry.AbilitySystem = &ASC; Entry.Definition = Definition; Entry.Record = Record;
	Entry.Ordinal = NextOrdinal++; Entry.LastSample = Record.StartServerTime;
	AbilitySystems.AddUnique(Key);
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

void UAethelnCombatTimelineSubsystem::HandlePostActorTick(UWorld* World, ELevelTick TickType, float DeltaSeconds)
{
	if (World != GetWorld() || World == nullptr || World->GetNetMode() == NM_Client) { return; }
	const double Now = World->GetTimeSeconds(); // Never DeltaSeconds or a client sample.
	const auto Sources = AbilitySystems;
	for (const auto& Source : Sources)
	{
		if (UAethelnAbilitySystemComponent* ASC = Source.Get()) { ASC->StartBufferedChainStep(Now); }
	}
	Steps.Sort([](const FStep& A, const FStep& B) { return A.Ordinal < B.Ordinal; });
	// Snapshot identities: callbacks may register/reset; never retain an array reference across them.
	TArray<FGuid> Ids;
	for (const FStep& Entry : Steps) { Ids.Add(Entry.Record.ActivationId); }
	for (const FGuid& Id : Ids)
	{
		FStep* Entry = Steps.FindByPredicate([&Id](const FStep& Item) { return Item.Record.ActivationId == Id; });
		if (Entry == nullptr) { continue; }
		const FAethelnAttackSampleInterval Interval = AethelnAttackTimeline::ClipActiveInterval(Entry->Definition, Entry->Record.StartServerTime, Entry->LastSample, Now, Entry->ResetTime);
		const FAethelnCombatActivationRecord Record = Entry->Record;
		Entry->LastSample = Now;
		if (Interval.bValid) { OnWindowEvaluated.Broadcast(Record, Interval); }
	}
	// P4 inserts contact resolution here, before these exact authored boundaries.
	for (const auto& Source : Sources)
	{
		if (UAethelnAbilitySystemComponent* ASC = Source.Get()) { ASC->ApplyChainBoundaries(Now); }
	}
	Steps.RemoveAll([Now](const FStep& Entry) { return !Entry.AbilitySystem.IsValid() || Entry.ResetTime <= Now; });
	AbilitySystems.RemoveAll([](const auto& Source) { return !Source.IsValid() || !Source->ChainState.bExists; });
	for (auto Iterator = CombatIds.CreateIterator(); Iterator; ++Iterator)
	{
		if (!Iterator.Key().IsValid()) { Iterator.RemoveCurrent(); }
	}
}
