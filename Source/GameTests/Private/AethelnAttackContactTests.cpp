#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnAbilitySystemComponent.h"
#include "AethelnChainTestFixture.h"
#include "AethelnCombatAICharacter.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatCollision.h"
#include "AethelnCombatEffects.h"
#include "AethelnGameplayTags.h"
#include "AethelnObservability.h"
#include "AethelnObservabilitySubsystem.h"
#include "Components/BoxComponent.h"
#include "Misc/AutomationTest.h"

// #60 P4 contacts and damage (docs/attack-timeline-and-combo.md, Test Plan A9 to A14, A18, A24, A26, A28).
// Fixture geometry, not tuning: the test chain sweeps a radius-10 sphere 30 units forward from the
// attacker's capsule center during [S + 0.125, S + 0.25), and a dummy capsule (radius 34) centered
// 60 units ahead is first touched at S + 0.125 + 0.125 * 16 / 30.
namespace AethelnContactTests
{
	using namespace AethelnChainTests;
	using EResult = EAethelnActivationResult;
	using EOutcome = EAethelnCombatResultOutcome;

	constexpr double ContactOffset60 = 0.125 + 0.125 * 16.0 / 30.0;

	float Health(const AAethelnCombatAICharacter& Target)
	{
		return Target.GetAethelnAbilitySystemComponent()->GetNumericAttribute(UAethelnCombatAttributeSet::GetHealthAttribute());
	}

	void SetStepValues(UAethelnChainTestAbility& Ability, TFunctionRef<void(FAethelnAttackStepDefinition&)> Mutate)
	{
		for (FAethelnAttackStepDefinition& Step : Ability.ProvisionalSteps) { Mutate(Step); }
	}

	struct FCueLog
	{
		TArray<FAethelnCombatResultCue> Cues;
		FDelegateHandle Handle;
		TWeakObjectPtr<UAethelnAbilitySystemComponent> Source;
		explicit FCueLog(AAethelnCombatAICharacter& Target) : Source(Target.GetAethelnAbilitySystemComponent())
		{
			Handle = Source->OnCombatResultCue.AddLambda([this](const FAethelnCombatResultCue& Cue) { Cues.Add(Cue); });
		}
		~FCueLog() { if (Source.IsValid()) { Source->OnCombatResultCue.Remove(Handle); } }
	};
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnContactOnCapsuleOnlyTest,
	"Aetheln.GameCombat.AttackTimeline.ContactOnCapsuleOnly",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnContactOnCapsuleOnlyTest::RunTest(const FString& Parameters)
{
	using namespace AethelnContactTests;
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		AAethelnCombatAICharacter* Target = F.SpawnTarget(*this, FVector(60.0, 0.0, 0.0));
		if (Target == nullptr) { return false; }
		FCueLog Cues(*Target);
		TestEqual(TEXT("Press starts a step"), F.Press(), EResult::Accepted);
		F.AdvanceTo(0.5);
		if (TestEqual(TEXT("A sweep through the target capsule yields one result"), F.Results.Num(), 1))
		{
			TestEqual(TEXT("The result is a hit"), F.Results[0].Outcome, EOutcome::Hit);
			TestEqual(TEXT("The result belongs to the started step"), F.Results[0].ActivationId, F.Records[0].ActivationId);
			TestNearlyEqual(TEXT("The contact time comes from the sweep fraction on the server clock"), F.Results[0].ContactTime, ContactOffset60, 1.0e-3);
			TestTrue(TEXT("The attacker is never its own target"), F.Results[0].TargetCombatId != F.Records[0].InstigatorCombatId);
		}
		if (TestEqual(TEXT("The target's ASC multicasts one cue"), Cues.Cues.Num(), 1))
		{
			TestEqual(TEXT("The cue names the source avatar"), Cues.Cues[0].SourceAvatar.Get(), static_cast<AActor*>(F.Pawn));
			TestTrue(TEXT("The cue carries the Wrought family"), Cues.Cues[0].FamilyTag == AethelnGameplayTags::Damage_Wrought);
			TestFalse(TEXT("A non-lethal hit cue"), Cues.Cues[0].bLethal);
		}
	}
	{
		// A query-enabled non-capsule component in the swept volume, on a character that is itself out of reach.
		FFixture F; if (!F.Init(*this)) { return false; }
		AAethelnCombatAICharacter* Target = F.SpawnTarget(*this, FVector(300.0, 0.0, 0.0));
		if (Target == nullptr) { return false; }
		UBoxComponent* Mesh = NewObject<UBoxComponent>(Target);
		Mesh->SetupAttachment(Target->GetRootComponent());
		Mesh->SetBoxExtent(FVector(20.0));
		Mesh->SetCollisionEnabled(ECollisionEnabled::QueryOnly);
		Mesh->SetCollisionResponseToAllChannels(ECR_Ignore);
		Mesh->SetCollisionResponseToChannel(AethelnCombatCollision::QueryChannel, ECR_Overlap);
		Mesh->RegisterComponent();
		Mesh->SetWorldLocation(FVector(40.0, 0.0, 0.0));
		TArray<FHitResult> Control;
		F.World.World->SweepMultiByChannel(Control, FVector::ZeroVector, FVector(30.0, 0.0, 0.0), FQuat::Identity, AethelnCombatCollision::QueryChannel,
			FCollisionShape::MakeSphere(10.0f), FCollisionQueryParams(SCENE_QUERY_STAT(AethelnContactControl), false, F.Pawn));
		TestTrue(TEXT("Control: the same sweep does reach the non-capsule component"), Control.ContainsByPredicate([Mesh](const FHitResult& Hit) { return Hit.GetComponent() == Mesh; }));
		F.Press();
		F.AdvanceTo(0.5);
		TestEqual(TEXT("A shape overlapping only a non-capsule component yields no contact"), F.Results.Num(), 0);
		TestEqual(TEXT("No damage without a capsule contact"), Health(*Target), 40.0f);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAlreadyHitAllowanceTest,
	"Aetheln.GameCombat.AttackTimeline.AlreadyHitAllowance",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAlreadyHitAllowanceTest::RunTest(const FString& Parameters)
{
	using namespace AethelnContactTests;
	{
		// The target overlaps the shape from ActiveStart to ActiveEnd, across many sub-sweeps and frames.
		FFixture F; if (!F.Init(*this)) { return false; }
		AAethelnCombatAICharacter* Target = F.SpawnTarget(*this, FVector(40.0, 0.0, 0.0));
		if (Target == nullptr) { return false; }
		F.Press();
		for (double Time : { 0.125, 0.15, 0.175, 0.2, 0.225, 0.25, 0.375 }) { F.AdvanceTo(Time); }
		TestTrue(TEXT("The window was swept in several sub-sweeps and frames"), F.Timeline->GetSweepCountForTests() > 3);
		if (TestEqual(TEXT("One result per target per activation"), F.Results.Num(), 1))
		{
			TestEqual(TEXT("An initial overlap counts at the window start"), F.Results[0].ContactTime, 0.125);
		}
		TestEqual(TEXT("Damage applied once"), Health(*Target), 35.0f);
		TestEqual(TEXT("A replayed request adds nothing"), F.Player.AbilitySystem->ProcessServerRequest(F.Request(1)), EResult::DuplicateSequence);
		F.AdvanceTo(0.5);
		TestEqual(TEXT("Link press starts the next step"), F.Press(), EResult::Accepted);
		F.AdvanceTo(0.75);
		if (TestEqual(TEXT("A second activation can hit the same target again"), F.Results.Num(), 2))
		{
			TestTrue(TEXT("Each result has its own activation"), F.Results[0].ActivationId != F.Results[1].ActivationId);
		}
		TestEqual(TEXT("Each activation damages once"), Health(*Target), 30.0f);
	}
	{
		// A full record rejects later targets without evicting the first.
		FFixture F; if (!F.Init(*this)) { return false; }
		SetStepValues(*F.Ability, [](FAethelnAttackStepDefinition& Step) { Step.MaxTargets = 1; });
		AAethelnCombatAICharacter* Near = F.SpawnTarget(*this, FVector(60.0, 0.0, 0.0));
		AAethelnCombatAICharacter* Far = F.SpawnTarget(*this, FVector(70.0, 0.0, 50.0));
		if (Near == nullptr || Far == nullptr) { return false; }
		F.Press();
		for (double Time : { 0.2, 0.22, 0.24, 0.375 }) { F.AdvanceTo(Time); }
		TestEqual(TEXT("MaxTargets bounds the record"), F.Results.Num(), 1);
		TestEqual(TEXT("The earlier contact keeps its record"), Health(*Near), 35.0f);
		TestEqual(TEXT("The later target is rejected, never swapped in"), Health(*Far), 40.0f);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDeterministicOrderingTest,
	"Aetheln.GameCombat.AttackTimeline.DeterministicOrdering",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDeterministicOrderingTest::RunTest(const FString& Parameters)
{
	using namespace AethelnContactTests;
	// Each run: one lethal hit (test magnitude equals the dummy's Health), so only the first resolved contact commits.
	const auto Run = [this](bool bPrimaryIsNear, bool bNearPressesFirst, double FarDistance, FGuid& OutNearId, FGuid& OutWinner) -> bool
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		AAethelnCombatAICharacter* Target = F.SpawnTarget(*this, FVector::ZeroVector);
		FAttacker Other;
		if (Target == nullptr || !F.SpawnAttacker(*this, Other, FVector(FarDistance, 0.0, 0.0), 180.0)) { return false; }
		F.Pawn->SetActorLocation(FVector(-60.0, 0.0, 0.0));
		if (!bPrimaryIsNear)
		{
			// Swap roles so actor spawn (tick) order is reversed too.
			F.Pawn->SetActorLocationAndRotation(FVector(FarDistance, 0.0, 0.0), FRotator(0.0, 180.0, 0.0));
			F.Player.Controller->SetControlRotation(FRotator(0.0, 180.0, 0.0));
			Other.Pawn->SetActorLocationAndRotation(FVector(-60.0, 0.0, 0.0), FRotator::ZeroRotator);
			Other.Player.Controller->SetControlRotation(FRotator::ZeroRotator);
		}
		SetStepValues(*F.Ability, [](FAethelnAttackStepDefinition& Step) { Step.WroughtDamage = 40.0f; });
		SetStepValues(*Other.Ability, [](FAethelnAttackStepDefinition& Step) { Step.WroughtDamage = 40.0f; });
		const auto PressNear = [&]() { return bPrimaryIsNear ? F.Press() : Other.Press(); };
		const auto PressFar = [&]() { return bPrimaryIsNear ? Other.Press() : F.Press(); };
		if (bNearPressesFirst) { PressNear(); PressFar(); } else { PressFar(); PressNear(); }
		F.AdvanceTo(0.5);
		OutNearId = (bPrimaryIsNear ? F.Player.AbilitySystem : Other.Player.AbilitySystem)->GetChainStateForTests().CurrentInput.ActivationId;
		TestEqual(TEXT("Exactly one lethal result commits"), F.Results.Num(), 1);
		OutWinner = F.Results.IsEmpty() ? FGuid() : F.Results[0].ActivationId;
		TestEqual(TEXT("The target is at zero Health"), Health(*Target), 0.0f);
		return true;
	};
	for (bool bPrimaryIsNear : { true, false })
	{
		for (bool bNearPressesFirst : { true, false })
		{
			FGuid NearId, Winner;
			if (!Run(bPrimaryIsNear, bNearPressesFirst, 70.0, NearId, Winner)) { return false; }
			TestEqual(TEXT("The earlier contact wins whatever the registration and tick order"), Winner, NearId);
		}
	}
	{
		// Exactly equal contact times: two attackers at the same pose; the activation ordinal breaks the tie.
		FFixture F; if (!F.Init(*this)) { return false; }
		AAethelnCombatAICharacter* Target = F.SpawnTarget(*this, FVector::ZeroVector);
		FAttacker Other;
		if (Target == nullptr || !F.SpawnAttacker(*this, Other, FVector(-60.0, 0.0, 0.0), 0.0)) { return false; }
		F.Pawn->SetActorLocation(FVector(-60.0, 0.0, 0.0));
		SetStepValues(*F.Ability, [](FAethelnAttackStepDefinition& Step) { Step.WroughtDamage = 40.0f; });
		SetStepValues(*Other.Ability, [](FAethelnAttackStepDefinition& Step) { Step.WroughtDamage = 40.0f; });
		Other.Press(); F.Press();
		const FGuid FirstRegistered = Other.Player.AbilitySystem->GetChainStateForTests().CurrentInput.ActivationId;
		F.AdvanceTo(0.5);
		if (TestEqual(TEXT("A tie still commits one lethal result"), F.Results.Num(), 1))
		{
			TestEqual(TEXT("The lower activation ordinal resolves first on a tie"), F.Results[0].ActivationId, FirstRegistered);
		}
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDamageAndLethalLatchTest,
	"Aetheln.GameCombat.AttackTimeline.DamageAndLethalLatch",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDamageAndLethalLatchTest::RunTest(const FString& Parameters)
{
	using namespace AethelnContactTests;
	FFixture F; if (!F.Init(*this)) { return false; }
	AAethelnCombatAICharacter* Target = F.SpawnTarget(*this, FVector(60.0, 0.0, 0.0));
	if (Target == nullptr) { return false; }
	SetStepValues(*F.Ability, [](FAethelnAttackStepDefinition& Step) { Step.WroughtDamage = 15.0f; });
	int32 DamageEffects = 0;
	int32 UntaggedDamage = 0;
	int32 OtherEffects = 0;
	UAethelnAbilitySystemComponent* TargetAsc = Target->GetAethelnAbilitySystemComponent();
	const FDelegateHandle EffectHandle = TargetAsc->OnGameplayEffectAppliedDelegateToSelf.AddLambda(
		[&](UAbilitySystemComponent*, const FGameplayEffectSpec& Spec, FActiveGameplayEffectHandle)
		{
			if (Spec.Def != nullptr && Spec.Def->IsA<UAethelnDamageEffect>())
			{
				++DamageEffects;
				FGameplayTagContainer Tags; Spec.GetAllAssetTags(Tags);
				if (!Tags.HasTagExact(AethelnGameplayTags::Damage_Wrought)) { ++UntaggedDamage; }
			}
			else { ++OtherEffects; }
		});
	TArray<FGuid> Lethal;
	const FDelegateHandle LethalHandle = F.Timeline->OnLethalResult.AddLambda([&](UAethelnAbilitySystemComponent* Victim, const FGuid& Id)
		{
			if (Victim == TargetAsc) { Lethal.Add(Id); }
		});
	F.Press(); F.AdvanceTo(0.5);
	TestEqual(TEXT("First hit lowers Health by the test magnitude"), Health(*Target), 25.0f);
	F.Press(); F.AdvanceTo(1.0);
	TestEqual(TEXT("Second hit"), Health(*Target), 10.0f);
	F.Press(); F.AdvanceTo(2.0);
	TestEqual(TEXT("Health clamps at zero"), Health(*Target), 0.0f);
	TestEqual(TEXT("Three steps, three results"), F.Results.Num(), 3);
	if (F.Results.Num() == 3)
	{
		TestFalse(TEXT("Earlier hits are not lethal"), F.Results[0].bLethal || F.Results[1].bLethal);
		TestTrue(TEXT("The zeroing hit is latched lethal"), F.Results[2].bLethal);
	}
	if (TestEqual(TEXT("The lethal notification fires once"), Lethal.Num(), 1) && F.Records.Num() == 3)
	{
		TestEqual(TEXT("The lethal notification names the activation"), Lethal[0], F.Records[2].ActivationId);
	}
	TestEqual(TEXT("A new chain after completion starts"), F.Press(), EResult::Accepted);
	F.AdvanceTo(2.5);
	TestEqual(TEXT("A zero-Health target takes no further result"), F.Results.Num(), 3);
	TestEqual(TEXT("No second lethal notification"), Lethal.Num(), 1);
	TestEqual(TEXT("Health changed only through the damage effect"), DamageEffects, 3);
	TestEqual(TEXT("Every damage spec carries Damage.Wrought"), UntaggedDamage, 0);
	TestEqual(TEXT("No other effect reached the target"), OtherEffects, 0);
	TargetAsc->OnGameplayEffectAppliedDelegateToSelf.Remove(EffectHandle);
	F.Timeline->OnLethalResult.Remove(LethalHandle);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDeadLifeStateRejectedTest,
	"Aetheln.GameCombat.AttackTimeline.DeadLifeStateRejected",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDeadLifeStateRejectedTest::RunTest(const FString& Parameters)
{
	using namespace AethelnContactTests;
	FFixture F; if (!F.Init(*this)) { return false; }
	AAethelnCombatAICharacter* Target = F.SpawnTarget(*this, FVector(60.0, 0.0, 0.0));
	if (Target == nullptr) { return false; }
	UAethelnAbilitySystemComponent* TargetAsc = Target->GetAethelnAbilitySystemComponent();
	F.Player.AbilitySystem->AddLooseGameplayTag(AethelnGameplayTags::State_Dead);
	TestEqual(TEXT("A dead attacker is refused"), F.Press(), EResult::ActivationBlocked);
	F.Player.AbilitySystem->RemoveLooseGameplayTag(AethelnGameplayTags::State_Dead);
	TargetAsc->AddLooseGameplayTag(AethelnGameplayTags::State_Dead);
	TestEqual(TEXT("A live attacker swings at a dead target"), F.Press(), EResult::Accepted);
	F.AdvanceTo(1.0);
	TestEqual(TEXT("A dead target yields no result"), F.Results.Num(), 0);
	TestEqual(TEXT("A dead target takes no damage"), Health(*Target), 40.0f);
	TargetAsc->RemoveLooseGameplayTag(AethelnGameplayTags::State_Dead);
	F.Press(); F.AdvanceTo(1.15);
	F.Player.AbilitySystem->AddLooseGameplayTag(AethelnGameplayTags::State_Dead);
	F.AdvanceTo(1.5);
	TestEqual(TEXT("An attacker that dies before its contact time resolves nothing"), F.Results.Num(), 0);
	TestEqual(TEXT("The dead attacker's chain ended"), F.Ends.Last().Reason, EAethelnChainEndReason::IncompatibleState);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAvoidanceDefenseAndRelationTest,
	"Aetheln.GameCombat.AttackTimeline.AvoidanceDefenseAndRelation",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAvoidanceDefenseAndRelationTest::RunTest(const FString& Parameters)
{
	using namespace AethelnContactTests;
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		AAethelnCombatAICharacter* Target = F.SpawnTarget(*this, FVector(60.0, 0.0, 0.0));
		if (Target == nullptr) { return false; }
		FCueLog Cues(*Target);
		F.Timeline->AvoidanceTags.AddTag(AethelnCombatTestTags::Test_Avoidance);
		Target->GetAethelnAbilitySystemComponent()->AddLooseGameplayTag(AethelnCombatTestTags::Test_Avoidance);
		F.Press(); F.AdvanceTo(0.5);
		if (TestEqual(TEXT("An avoiding target yields one recorded result"), F.Results.Num(), 1))
		{
			TestEqual(TEXT("The result is Avoided"), F.Results[0].Outcome, EOutcome::Avoided);
		}
		TestEqual(TEXT("Avoided applies no damage"), Health(*Target), 40.0f);
		if (TestEqual(TEXT("Avoided still cues"), Cues.Cues.Num(), 1)) { TestEqual(TEXT("Avoided cue"), Cues.Cues[0].Outcome, EOutcome::Avoided); }
	}
	for (bool bFacingAttacker : { true, false })
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		AAethelnCombatAICharacter* Target = F.SpawnTarget(*this, FVector(60.0, 0.0, 0.0));
		if (Target == nullptr) { return false; }
		Target->SetActorRotation(FRotator(0.0, bFacingAttacker ? 180.0 : 0.0, 0.0));
		UAethelnAbilitySystemComponent* TargetAsc = Target->GetAethelnAbilitySystemComponent();
		int32 HookCalls = 0;
		FAethelnDefenseState Defense;
		Defense.StateTag = AethelnCombatTestTags::Test_Defending;
		Defense.ArcDegrees = 90.0; // test-only arc
		Defense.OnBlocked.BindLambda([&HookCalls](const FAethelnCombatResult&) { ++HookCalls; });
		F.Timeline->SetDefenseState(*TargetAsc, Defense);
		TargetAsc->AddLooseGameplayTag(AethelnCombatTestTags::Test_Defending);
		F.Press(); F.AdvanceTo(0.5);
		if (TestEqual(TEXT("One result either way"), F.Results.Num(), 1))
		{
			TestEqual(TEXT("Facing the contact blocks; facing away is an ordinary hit"), F.Results[0].Outcome, bFacingAttacker ? EOutcome::Blocked : EOutcome::Hit);
		}
		TestEqual(TEXT("The defense hook runs once per block"), HookCalls, bFacingAttacker ? 1 : 0);
		TestEqual(TEXT("A block applies no damage here; the hook owns its consequence"), Health(*Target), bFacingAttacker ? 40.0f : 35.0f);
		TargetAsc->RemoveLooseGameplayTag(AethelnCombatTestTags::Test_Defending);
		F.Press(); F.AdvanceTo(1.0);
		TestEqual(TEXT("Without the state tag no target is defending"), HookCalls, bFacingAttacker ? 1 : 0);
		TestEqual(TEXT("The undefended hit damages"), Health(*Target), bFacingAttacker ? 35.0f : 30.0f);
	}
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		FAttacker Ally;
		if (!F.SpawnAttacker(*this, Ally, FVector(60.0, 0.0, 0.0), 0.0)) { return false; }
		const float AllyHealth = Ally.Player.AbilitySystem->GetNumericAttribute(UAethelnCombatAttributeSet::GetHealthAttribute());
		F.Press(); F.AdvanceTo(0.5);
		TestEqual(TEXT("A player target yields nothing (OQ1)"), F.Results.Num(), 0);
		TestEqual(TEXT("The ally takes no damage"), Ally.Player.AbilitySystem->GetNumericAttribute(UAethelnCombatAttributeSet::GetHealthAttribute()), AllyHealth);
		TestFalse(TEXT("Players are allies"), UAethelnCombatTimelineSubsystem::IsHostile(*F.Player.AbilitySystem, *Ally.Player.AbilitySystem));
		TestFalse(TEXT("Never hostile to self"), UAethelnCombatTimelineSubsystem::IsHostile(*F.Player.AbilitySystem, *F.Player.AbilitySystem));
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnNoMaximumModifiersTest,
	"Aetheln.GameCombat.AttackTimeline.NoMaximumModifiers",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnNoMaximumModifiersTest::RunTest(const FString& Parameters)
{
	// Every effect #60 adds. A later #60 effect joins this list.
	for (const UGameplayEffect* Effect : { static_cast<const UGameplayEffect*>(GetDefault<UAethelnDamageEffect>()) })
	{
		TestEqual(TEXT("No duration modifier on a current value"), Effect->DurationPolicy, EGameplayEffectDurationType::Instant);
		for (const FGameplayModifierInfo& Modifier : Effect->Modifiers)
		{
			TestTrue(TEXT("No maximum is modified"), Modifier.Attribute != UAethelnCombatAttributeSet::GetMaxHealthAttribute()
				&& Modifier.Attribute != UAethelnCombatAttributeSet::GetMaxEnduranceAttribute()
				&& Modifier.Attribute != UAethelnCombatAttributeSet::GetMaxGuardAttribute());
		}
		TestEqual(TEXT("Damage modifies Health only"), Effect->Modifiers.Num(), 1);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnHitTelemetryTest,
	"Aetheln.GameCombat.AttackTimeline.HitTelemetry",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnHitTelemetryTest::RunTest(const FString& Parameters)
{
	using namespace AethelnContactTests;
	FFixture F(true); if (!F.Init(*this)) { return false; }
	AAethelnCombatAICharacter* Target = F.SpawnTarget(*this, FVector(60.0, 0.0, 0.0));
	UAethelnObservabilitySubsystem* Subsystem = F.World.GameInstance != nullptr ? F.World.GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>() : nullptr;
	if (Target == nullptr || !TestNotNull(TEXT("Observability subsystem exists"), Subsystem)) { return false; }
	TSharedPtr<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe> Sink = MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(64);
	TestTrue(TEXT("Runtime context is set"), Subsystem->SetRuntimeContext(EAethelnFlowKind::PrototypeAuthority, TEXT("run-attack-p4-test"), TEXT("instance-attack-p4-test"), TEXT("connection-attack-p4-test")));
	TestTrue(TEXT("Public sink is set"), Subsystem->SetTestSink(Sink));
	F.Press(); F.AdvanceTo(0.5);
	TestTrue(TEXT("Telemetry drained"), Subsystem->WaitForIdleForTests());
	TArray<FAethelnObservabilityEvent> Hits;
	for (const FAethelnObservabilityEvent& Event : Sink->GetEvents())
	{
		if (Event.Category == EAethelnObservabilityCategory::Hit) { Hits.Add(Event); }
	}
	if (TestEqual(TEXT("One hit event per committed result"), Hits.Num(), 1) && F.Records.Num() == 1)
	{
		TestTrue(TEXT("Hit subject, accepted reason"), Hits[0].SubjectCategory == EAethelnObservabilityCategory::Hit && Hits[0].SafeReason == EAethelnSafeReason::Accepted);
		TestEqual(TEXT("Activation id"), Hits[0].Correlation.ActivationId, F.Records[0].ActivationId.ToString(EGuidFormats::DigitsWithHyphensLower));
		TestEqual(TEXT("Ability id"), Hits[0].Correlation.AbilityId, AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain.GetTag().ToString());
		TestEqual(TEXT("Request sequence"), static_cast<int64>(Hits[0].Correlation.Sequence), static_cast<int64>(1));
		TestEqual(TEXT("No connection or target identity"), Hits[0].Correlation.ConnectionPseudonym, FString(AethelnObservability::ExcludedIdentifier));
		TestTrue(TEXT("Public channel hides diagnostics"), Hits[0].DiagnosticCode == EAethelnDiagnosticCode::None);
	}
	Subsystem->ResetSink(); Subsystem->ResetRuntimeContext();
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnNetworkConditionsContactsTest,
	"Aetheln.GameCombat.AttackTimeline.NetworkConditionsContacts",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnNetworkConditionsContactsTest::RunTest(const FString& Parameters)
{
	using namespace AethelnContactTests;
	// The A25 delivery profiles (fixture arrival times, not a network profile) against a target dummy.
	for (double Arrival : { 0.359375, 0.375, 0.484375, 0.5, 0.734375, 0.75, 0.765625 })
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		AAethelnCombatAICharacter* Target = F.SpawnTarget(*this, FVector(60.0, 0.0, 0.0));
		if (Target == nullptr) { return false; }
		F.Press();
		FAethelnCombatActivationRequest Delayed = F.Request(10);
		F.AdvanceTo(Arrival);
		const EResult First = F.Player.AbilitySystem->ProcessServerRequest(Delayed);
		TestEqual(TEXT("Duplicate delivery"), F.Player.AbilitySystem->ProcessServerRequest(Delayed), First == EResult::Accepted ? EResult::DuplicateSequence : EResult::ActivationBlocked);
		Delayed.Sequence = 9;
		F.Player.AbilitySystem->ProcessServerRequest(Delayed);
		F.AdvanceTo(2.0);
		TestEqual(TEXT("One started step per accepted request"), F.Records.Num(), First == EResult::Accepted ? 2 : 1);
		TestEqual(TEXT("Each started step hits the dummy exactly once; rejected requests add nothing"), F.Results.Num(), F.Records.Num());
		TestEqual(TEXT("Damage matches the results"), Health(*Target), 40.0f - 5.0f * F.Results.Num());
		for (const FAethelnCombatResult& Result : F.Results)
		{
			const FAethelnCombatActivationRecord* Record = F.Records.FindByPredicate([&Result](const FAethelnCombatActivationRecord& Item) { return Item.ActivationId == Result.ActivationId; });
			if (TestNotNull(TEXT("Every result belongs to a started step"), Record))
			{
				TestNearlyEqual(TEXT("Delay moves only when a step starts, never the contact within it"), Result.ContactTime - Record->StartServerTime, ContactOffset60, 1.0e-3);
			}
		}
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnBufferedStartWithinFrameTest,
	"Aetheln.GameCombat.AttackTimeline.BufferedStartWithinFrame",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnBufferedStartWithinFrameTest::RunTest(const FString& Parameters)
{
	using namespace AethelnContactTests;
	FFixture F; if (!F.Init(*this)) { return false; }
	AAethelnCombatAICharacter* Target = F.SpawnTarget(*this, FVector::ZeroVector);
	FAttacker Other;
	if (Target == nullptr || !F.SpawnAttacker(*this, Other, FVector(60.0, 0.0, 0.0), 180.0)) { return false; }
	F.Pawn->SetActorLocation(FVector(-60.0, 0.0, 0.0));
	// Test-only: the other attacker's first active window opens later in its step.
	Other.Ability->ProvisionalSteps[0].ActiveStart = 0.25;
	Other.Ability->ProvisionalSteps[0].ActiveEnd = 0.375;
	F.Press(); F.AdvanceTo(0.375);
	TestEqual(TEXT("Buffered press"), F.Press(), EResult::Accepted);
	F.AdvanceTo(0.4375);
	TestEqual(TEXT("The other attacker starts before the frame"), Other.Press(), EResult::Accepted);
	const FGuid OtherId = Other.Player.AbilitySystem->GetChainStateForTests().CurrentInput.ActivationId;
	F.Results.Reset();
	F.AdvanceTo(0.8); // one frame spanning LinkOpen, the buffered step's whole active window and the other contact
	if (TestEqual(TEXT("The buffered step started in this frame"), F.Records.Num(), 2))
	{
		TestEqual(TEXT("It started at exactly LinkOpen, partway through the frame"), F.Records[1].StartServerTime, 0.5);
	}
	if (TestEqual(TEXT("Both contacts resolve in the same pass"), F.Results.Num(), 2) && F.Records.Num() == 2)
	{
		TestEqual(TEXT("The buffered step's earlier contact sorts first despite its later ordinal"), F.Results[0].ActivationId, F.Records[1].ActivationId);
		TestNearlyEqual(TEXT("Its contact time is on its own start"), F.Results[0].ContactTime, 0.5 + ContactOffset60, 1.0e-3);
		TestEqual(TEXT("The other attacker's later contact follows"), F.Results[1].ActivationId, OtherId);
	}
	return true;
}

#endif
