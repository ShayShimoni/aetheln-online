#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatAICharacter.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnDefenseTestFixture.h"
#include "AethelnGameplayTags.h"
#include "AethelnObservability.h"
#include "AethelnObservabilitySubsystem.h"
#include "AethelnOathscarTestAbilities.h"
#include "AethelnPlayerState.h"
#include "GameplayTagsManager.h"
#include "Misc/AutomationTest.h"
#include <limits>

// #260 (docs/gas-foundation.md, Representative Oathscar Actives; K5 to K9): the Parry. A player defender with the
// fixture Parry, block, dodge, chain and strike; enemy steps registered directly with #60's driver are the attackers
// (owner decision 3). Geometry, not tuning: the fixture step sweeps a radius-10 sphere 30 units from the enemy's
// capsule center during [E + 0.125, E + 0.25). An enemy 40 units from the player's radius-42 capsule overlaps it at
// the window start, so its contact time is exactly E + 0.125. The fixture Parry is accepted at S and defends
// [S + 1/16, S + 1/2).
namespace AethelnOathscarParryTests
{
	using namespace AethelnDefenseTests;

	const FGameplayTag ParryId = AethelnGameplayTags::Ability_Oathscar_Parry;

	TArray<TSubclassOf<UGameplayAbility>> Abilities()
	{
		return { UAethelnParryTestAbility::StaticClass(), UAethelnBlockTestAbility::StaticClass(), UAethelnDodgeTestAbility::StaticClass(),
			UAethelnChainTestAbility::StaticClass(), UAethelnInstantStrikeTestAbility::StaticClass() };
	}

	EResult Parry(FDefense& F) { return F.Deliver(F.Request(ParryId)); }

	UAethelnParryTestAbility* FindParry(const FDefense& F)
	{
		const FGameplayAbilitySpec* Spec = F.ASC().FindAbilitySpecFromClass(UAethelnParryTestAbility::StaticClass());
		return Spec != nullptr ? Cast<UAethelnParryTestAbility>(Spec->GetPrimaryInstance()) : nullptr;
	}

	bool ParryActive(const FDefense& F)
	{
		const FGameplayAbilitySpec* Spec = F.ASC().FindAbilitySpecFromClass(UAethelnParryTestAbility::StaticClass());
		return Spec != nullptr && Spec->IsActive();
	}

	/** Like FDefense::Swing, with a step mutation: an enemy step starting now, aimed at the defender. */
	FGuid SwingWith(const FDefense& F, AAethelnCombatAICharacter& Enemy, TFunctionRef<void(FAethelnAttackStepDefinition&)> Mutate)
	{
		const UAethelnChainTestAbility* Chain = GetDefault<UAethelnChainTestAbility>();
		FAethelnAttackStepDefinition Step = Chain->ProvisionalSteps[0];
		Mutate(Step);
		FAethelnCombatActivationRecord Record;
		Record.ActivationId = FGuid::NewGuid();
		Record.Sequence = 1;
		Record.AbilityId = AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain;
		Record.ContentVersion = Chain->ContentVersion;
		Record.ChainStep = 1;
		Record.StartServerTime = F.Now();
		Record.AcceptedAim = (F.Pawn->GetActorLocation() - Enemy.GetActorLocation()).GetSafeNormal();
		return F.Timeline->RegisterStep(*Enemy.GetAethelnAbilitySystemComponent(), Step, Record, Chain->ProvisionalMaxSampleDistance, Chain->ProvisionalMaxSampleAngleDegrees)
			? Record.ActivationId : FGuid();
	}

	/** A second player with the chain, possessing a still pawn at Location, aiming along Yaw (as the chain fixture's attacker). */
	struct FPlayerAttacker
	{
		AethelnCombatTests::FTestPlayer Player;
		AAethelnPlayerCharacter* Pawn = nullptr;
		uint32 NextSequence = 1;
		EResult Press() { return Player.AbilitySystem->ProcessServerRequest(AethelnChainTests::MakeChainRequest(*Player.AbilitySystem, NextSequence++)); }
		/** A block raise, to show that a staggered player is refused every ability, not only the chain. */
		EResult Raise()
		{
			FAethelnCombatActivationRequest Request = AethelnChainTests::MakeChainRequest(*Player.AbilitySystem, NextSequence++);
			Request.AbilityId = AethelnGameplayTags::Ability_Block;
			return Player.AbilitySystem->ProcessServerRequest(Request);
		}
	};

	bool SpawnPlayerAttacker(FAutomationTestBase& Test, FDefense& F, FPlayerAttacker& Out, const FVector& Location, double Yaw)
	{
		if (!AethelnCombatTests::SpawnTestPlayer(Test, F.World, Out.Player, { UAethelnChainTestAbility::StaticClass(), UAethelnBlockTestAbility::StaticClass() })) { return false; }
		Out.Pawn = F.World.Spawn<AAethelnPlayerCharacter>();
		if (!Test.TestNotNull(TEXT("Player attacker pawn exists"), Out.Pawn)) { return false; }
		Out.Pawn->SetActorLocationAndRotation(Location, FRotator(0.0, Yaw, 0.0));
		Out.Player.Controller->Possess(Out.Pawn);
		Out.Pawn->GetCharacterMovement()->DisableMovement();
		Out.Player.Controller->SetControlRotation(FRotator(0.0, Yaw, 0.0));
		Out.Player.AbilitySystem->ProvisionalAimMaxRateDegreesPerSecond = 1000.0f;
		return true;
	}

	/** Opens a hostile pair of players for the test and closes it again, whatever happens. */
	struct FScopedHostilePlayers
	{
		FScopedHostilePlayers() { UAethelnCombatTimelineSubsystem::bPlayersHostileForTests = true; }
		~FScopedHostilePlayers() { UAethelnCombatTimelineSubsystem::bPlayersHostileForTests = false; }
	};
}

// K5. Red-first: before the Parry exists, nothing here compiles; at an identity-only stub every invalid value grants.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnParryDefinitionTest,
	"Aetheln.GameCombat.OathscarActives.ParryDefinition",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnParryDefinitionTest::RunTest(const FString& Parameters)
{
	const float NaN = std::numeric_limits<float>::quiet_NaN();
	const float Infinity = std::numeric_limits<float>::infinity();
	TestTrue(TEXT("The fixture definition is grantable"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(UAethelnParryTestAbility::StaticClass(), 1)));
	AddExpectedError(TEXT("Refused to grant ability"), EAutomationExpectedErrorFlags::Contains, 1);
	TestFalse(TEXT("Unset production values fail closed"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(UAethelnParryAbility::StaticClass(), 1)));
	const UAethelnParryTestAbility* Defaults = GetDefault<UAethelnParryTestAbility>();
	TestFalse(TEXT("The Parry has no Release route"), Defaults->bAcceptsRelease);
	for (const FGameplayTag Tag : { AethelnGameplayTags::State_Dead.GetTag(), AethelnGameplayTags::State_Dodging.GetTag(), AethelnGameplayTags::State_Blocking.GetTag(),
		AethelnGameplayTags::State_Staggered.GetTag(), AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain.GetTag(), AethelnGameplayTags::State_Oathscar_InstantStrike.GetTag() })
	{
		TestTrue(FString::Printf(TEXT("Blocked while %s"), *Tag.ToString()), Defaults->GetBlockedTagsForTests().HasTagExact(Tag));
	}
	const TArray<TFunction<void(UAethelnParryTestAbility&)>> Mutations = {
		[NaN](UAethelnParryTestAbility& A) { A.ProvisionalParry.WindowStart = NaN; },
		[Infinity](UAethelnParryTestAbility& A) { A.ProvisionalParry.WindowEnd = Infinity; },
		[NaN](UAethelnParryTestAbility& A) { A.ProvisionalParry.ArcDegrees = NaN; },
		[Infinity](UAethelnParryTestAbility& A) { A.ProvisionalParry.StaggerSeconds = Infinity; },
		[](UAethelnParryTestAbility& A) { A.ProvisionalParry.WindowStart = -0.0625f; }, // starts before acceptance
		[](UAethelnParryTestAbility& A) { A.ProvisionalParry.WindowEnd = A.ProvisionalParry.WindowStart; }, // empty
		[](UAethelnParryTestAbility& A) { A.ProvisionalParry.WindowEnd = 0.03125f; }, // ends before it starts
		[](UAethelnParryTestAbility& A) { A.ProvisionalParry.ArcDegrees = 0.0f; },
		[](UAethelnParryTestAbility& A) { A.ProvisionalParry.ArcDegrees = 360.5f; },
		[](UAethelnParryTestAbility& A) { A.ProvisionalParry.ArcDegrees = -90.0f; },
		[](UAethelnParryTestAbility& A) { A.ProvisionalParry.StaggerSeconds = -0.25f; },
		[](UAethelnParryTestAbility& A) { A.ProvisionalEnduranceCost = -1.0f; },
		[NaN](UAethelnParryTestAbility& A) { A.ProvisionalCooldownSeconds = NaN; },
		[](UAethelnParryTestAbility& A) { A.bAcceptsRelease = true; }, // a Release phase
		[](UAethelnParryTestAbility& A) { A.SetMovementCarriedForTests(true); },
		[](UAethelnParryTestAbility& A) { A.ContentVersion = 0; },
	};
	for (int32 Index = 0; Index < Mutations.Num(); ++Index)
	{
		UAethelnParryTestAbility* Definition = NewObject<UAethelnParryTestAbility>();
		Mutations[Index](*Definition);
		AddExpectedError(TEXT("Refused to grant ability"), EAutomationExpectedErrorFlags::Contains, 1);
		TestFalse(FString::Printf(TEXT("Invalid value %d refuses at grant"), Index), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Definition)));
	}
	for (const FGameplayTag Missing : Defaults->GetBlockedTagsForTests())
	{
		UAethelnParryTestAbility* Definition = NewObject<UAethelnParryTestAbility>();
		FGameplayTagContainer Tags = Definition->GetBlockedTagsForTests();
		Tags.RemoveTag(Missing);
		Definition->SetBlockedTagsForTests(Tags);
		AddExpectedError(TEXT("Refused to grant ability"), EAutomationExpectedErrorFlags::Contains, 1);
		TestFalse(FString::Printf(TEXT("A Parry without blocking tag %s refuses at grant"), *Missing.ToString()), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Definition)));
	}
	// The edges that are valid: a window from acceptance, a full circle, and no stagger.
	UAethelnParryTestAbility* Edges = NewObject<UAethelnParryTestAbility>();
	Edges->ProvisionalParry.WindowStart = 0.0f;
	Edges->ProvisionalParry.ArcDegrees = 360.0f;
	Edges->ProvisionalParry.StaggerSeconds = 0.0f;
	TestTrue(TEXT("A window from acceptance, a 360 degree arc and a zero stagger are accepted"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Edges)));
	return true;
}

// K6.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnParryWindowBoundariesTest,
	"Aetheln.GameCombat.OathscarActives.ParryWindowBoundaries",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnParryWindowBoundariesTest::RunTest(const FString& Parameters)
{
	using namespace AethelnOathscarParryTests;
	FDefense F; if (!F.Init(*this, Abilities())) { return false; }
	TArray<AAethelnCombatAICharacter*> Enemies;
	for (int32 Index = 0; Index < 6; ++Index)
	{
		AAethelnCombatAICharacter* Enemy = F.SpawnEnemy(*this, Index == 2 ? FVector(-40.0, 0.0, 0.0) : FVector(40.0, 0.0, 0.0));
		if (Enemy == nullptr) { return false; }
		Enemies.Add(Enemy);
	}
	int32 Interrupts = 0;
	const FDelegateHandle InterruptHandle = F.Timeline->OnTargetInterrupted.AddLambda([&Interrupts](UAethelnAbilitySystemComponent*, double) { ++Interrupts; });
	UAethelnObservabilitySubsystem* Subsystem = F.World.GameInstance != nullptr ? F.World.GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>() : nullptr;
	if (!TestNotNull(TEXT("Observability subsystem exists"), Subsystem)) { return false; }
	const auto Sink = MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(64);
	TestTrue(TEXT("Runtime context is set"), Subsystem->SetRuntimeContext(EAethelnFlowKind::PrototypeAuthority, TEXT("run-parry-test"), TEXT("instance-parry-test"), TEXT("connection-parry-test")));
	TestTrue(TEXT("Public sink is set"), Subsystem->SetTestSink(Sink));
	const float GuardBefore = F.Guard();
	// The Parry is accepted at 1.0: it defends [1.0625, 1.5). Each step's contact is exactly its start + 1/8.
	F.AdvanceTo(0.90625);
	const FGuid JustBefore = F.Swing(*Enemies[0], 0.0f); // contact 1.03125: before the window
	F.AdvanceTo(0.9375);
	const FGuid AtStart = F.Swing(*Enemies[1], 3.0f, 21); // contact 1.0625: the window start, inclusive; a positive pressure that must not apply
	F.AdvanceTo(1.0);
	TestEqual(TEXT("The Parry is accepted"), Parry(F), EResult::Accepted);
	TestTrue(TEXT("It holds its state tag"), F.Has(AethelnGameplayTags::State_Oathscar_Parrying));
	if (TestNotNull(TEXT("It registers the defense slot"), F.Slot()))
	{
		TestEqual(TEXT("The slot is the Parry's"), F.Slot()->StateTag, AethelnGameplayTags::State_Oathscar_Parrying.GetTag());
		TestEqual(TEXT("It starts at the server acceptance plus the offset"), F.Slot()->ActiveFromServerTime, 1.0625);
		TestEqual(TEXT("It ends at the server acceptance plus the offset"), F.Slot()->ActiveUntilServerTime, 1.5);
		TestEqual(TEXT("It defends the authored arc"), F.Slot()->ArcDegrees, 180.0);
	}
	F.AdvanceTo(1.125);
	const FGuid Behind = F.Swing(*Enemies[2], 0.0f); // contact 1.25 from behind: outside the arc
	F.AdvanceTo(1.3125);
	const FGuid JustBeforeEnd = F.Swing(*Enemies[3], 3.0f, 22); // contact 1.4375; likewise
	F.AdvanceTo(1.375);
	const FGuid AtEnd = F.Swing(*Enemies[4], 0.0f); // contact 1.5: the window end, exclusive
	F.AdvanceTo(2.0);
	const auto Outcome = [&F](const FGuid& Id) { const FAethelnCombatResult* Result = F.ResultFor(Id); return Result != nullptr ? Result->Outcome : EOutcome::Avoided; };
	TestEqual(TEXT("Just before the window start: a hit"), Outcome(JustBefore), EOutcome::Hit);
	TestEqual(TEXT("At the window start: parried"), Outcome(AtStart), EOutcome::Parried);
	TestEqual(TEXT("Outside the arc: a hit"), Outcome(Behind), EOutcome::Hit);
	TestEqual(TEXT("Just before the window end: parried"), Outcome(JustBeforeEnd), EOutcome::Parried);
	TestEqual(TEXT("At the window end: a hit"), Outcome(AtEnd), EOutcome::Hit);
	TestEqual(TEXT("Three hits cost Health; the two parried contacts changed nothing"), F.Health(), 25.0f);
	TestEqual(TEXT("A parried contact applies no Guard pressure"), F.PressureApplications, 0);
	TestEqual(TEXT("Nor does it change Guard, though both parried swings author pressure"), F.Guard(), GuardBefore);
	TestEqual(TEXT("The hook ran once per parried contact"), Interrupts, 2);
	const FAethelnCombatResult* Parried = F.ResultFor(AtStart);
	if (TestNotNull(TEXT("The parried result is recorded"), Parried)) { TestEqual(TEXT("At its contact time"), Parried->ContactTime, 1.0625); }
	TestFalse(TEXT("The window ended at WindowEnd: no state tag"), F.Has(AethelnGameplayTags::State_Oathscar_Parrying));
	TestFalse(TEXT("The activation ended at WindowEnd"), ParryActive(F));
	if (TestNotNull(TEXT("The slot is kept for exact contacts"), F.Slot())) { TestEqual(TEXT("It ended at WindowEnd"), F.Slot()->ActiveUntilServerTime, 1.5); }
	// Telemetry (docs/dodge-and-block.md, Observability Events): a Parried result emits one Block event with the attack's ids.
	TestTrue(TEXT("Telemetry drained"), Subsystem->WaitForIdleForTests());
	const FString ParriedId = AtStart.ToString(EGuidFormats::DigitsWithHyphensLower);
	const TArray<FAethelnObservabilityEvent> Events = Sink->GetEvents().FilterByPredicate([&ParriedId](const FAethelnObservabilityEvent& Event) { return Event.Correlation.ActivationId == ParriedId; });
	if (TestEqual(TEXT("One event for the parried result"), Events.Num(), 1))
	{
		TestTrue(TEXT("The Block category, not Hit"), Events[0].Category == EAethelnObservabilityCategory::Block && Events[0].SubjectCategory == EAethelnObservabilityCategory::Block);
		TestTrue(TEXT("Accepted reason"), Events[0].SafeReason == EAethelnSafeReason::Accepted);
		TestEqual(TEXT("The attack's sequence"), static_cast<int64>(Events[0].Correlation.Sequence), static_cast<int64>(21));
		TestEqual(TEXT("No connection or target identity"), Events[0].Correlation.ConnectionPseudonym, FString(AethelnObservability::ExcludedIdentifier));
	}
	Subsystem->ResetSink();
	Subsystem->ResetRuntimeContext();
	F.Timeline->OnTargetInterrupted.Remove(InterruptHandle);
	return true;
}

// K7.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnParryStaggersAttackerTest,
	"Aetheln.GameCombat.OathscarActives.ParryStaggersAttacker",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnParryStaggersAttackerTest::RunTest(const FString& Parameters)
{
	using namespace AethelnOathscarParryTests;
	// An enemy attacker: its registered steps are stamped at the contact time, its later contacts drop, and the
	// interruption fires once, whatever the step's InterruptibleUntil (the Parry is the authored rule).
	for (double InterruptibleUntil : { 0.0, 0.25 })
	{
		FDefense F; if (!F.Init(*this, Abilities())) { return false; }
		AAethelnCombatAICharacter* Enemy = F.SpawnEnemy(*this);
		if (Enemy == nullptr) { return false; }
		int32 Interrupts = 0;
		double InterruptTime = -1.0;
		const FDelegateHandle Handle = F.Timeline->OnTargetInterrupted.AddLambda([&](UAethelnAbilitySystemComponent* Target, double Time)
		{
			if (Target == Enemy->GetAethelnAbilitySystemComponent()) { ++Interrupts; InterruptTime = Time; }
		});
		F.AdvanceTo(1.0);
		TestEqual(TEXT("The Parry is accepted"), Parry(F), EResult::Accepted);
		const FGuid First = SwingWith(F, *Enemy, [InterruptibleUntil](FAethelnAttackStepDefinition& Step) { Step.InterruptibleUntil = InterruptibleUntil; }); // contact 1.125
		F.AdvanceTo(1.0625);
		const FGuid Later = F.Swing(*Enemy, 0.0f, 2); // contact 1.1875, after the parried contact
		F.AdvanceTo(2.0);
		const FAethelnCombatResult* Result = F.ResultFor(First);
		if (TestNotNull(TEXT("The contact is recorded"), Result)) { TestEqual(TEXT("Parried"), Result->Outcome, EOutcome::Parried); }
		TestNull(TEXT("The attacker's later contact dropped"), F.ResultFor(Later));
		TestEqual(TEXT("No damage in all"), F.Health(), 40.0f);
		TestEqual(TEXT("The interruption fired once"), Interrupts, 1);
		TestEqual(TEXT("At the contact time"), InterruptTime, 1.125);
		F.Timeline->OnTargetInterrupted.Remove(Handle);
	}
	// A player attacker (a test-only hostile pair): its chain ends Interrupted at the contact time, State.Staggered holds
	// for the stagger duration, every ability is refused while it holds, and death removes it.
	for (float StaggerSeconds : { 0.75f, 0.0f })
	{
		FScopedHostilePlayers Hostile;
		FDefense F; if (!F.Init(*this, Abilities())) { return false; }
		FPlayerAttacker Attacker; if (!SpawnPlayerAttacker(*this, F, Attacker, FVector(40.0, 0.0, 0.0), 180.0)) { return false; }
		UAethelnParryTestAbility* Parry = FindParry(F);
		if (!TestNotNull(TEXT("The Parry instance"), Parry)) { return false; }
		Parry->ProvisionalParry.StaggerSeconds = StaggerSeconds;
		TArray<TPair<FGuid, EAethelnChainEndReason>> Ends;
		const FDelegateHandle Handle = Attacker.Player.AbilitySystem->OnChainEnded.AddLambda([&Ends](const FGuid& Id, EAethelnChainEndReason Reason) { Ends.Add({ Id, Reason }); });
		F.AdvanceTo(1.0);
		TestEqual(TEXT("The Parry is accepted"), AethelnOathscarParryTests::Parry(F), EResult::Accepted);
		TestEqual(TEXT("The attacker's chain press is accepted"), Attacker.Press(), EResult::Accepted); // contact 1.125
		F.AdvanceTo(1.25);
		TestEqual(TEXT("The defender takes no damage"), F.Health(), 40.0f);
		TestEqual(TEXT("The attacker is not harmed either"), Attacker.Player.AbilitySystem->GetNumericAttribute(UAethelnCombatAttributeSet::GetHealthAttribute()), 40.0f);
		if (TestEqual(TEXT("The attacker's chain ended once"), Ends.Num(), 1)) { TestEqual(TEXT("Interrupted"), Ends[0].Value, EAethelnChainEndReason::Interrupted); }
		TestEqual(TEXT("It was stamped at the contact time"), Attacker.Player.AbilitySystem->GetLastChainResetTimeForTests(), 1.125);
		const FGameplayTagContainer StaggerTag(AethelnGameplayTags::State_Staggered);
		const bool bStaggered = Attacker.Player.AbilitySystem->HasMatchingGameplayTag(AethelnGameplayTags::State_Staggered);
		TestEqual(TEXT("State.Staggered holds only for a positive duration"), bStaggered, StaggerSeconds > 0.0f);
		if (bStaggered)
		{
			const TArray<float> Durations = Attacker.Player.AbilitySystem->GetActiveEffectsDuration(FGameplayEffectQuery::MakeQuery_MatchAnyOwningTags(StaggerTag));
			if (TestEqual(TEXT("One stagger effect"), Durations.Num(), 1)) { TestEqual(TEXT("For the authored duration"), Durations[0], StaggerSeconds); }
			TestEqual(TEXT("The chain is refused while staggered"), Attacker.Press(), EResult::ActivationBlocked);
			TestEqual(TEXT("So is a block raise (every project ability, via the base blocking tag)"), Attacker.Raise(), EResult::ActivationBlocked);
			TestFalse(TEXT("The defender is not staggered"), F.Has(AethelnGameplayTags::State_Staggered));
			Attacker.Player.AbilitySystem->AddLooseGameplayTag(AethelnGameplayTags::State_Dead);
			TestFalse(TEXT("State.Dead removes the stagger"), Attacker.Player.AbilitySystem->HasMatchingGameplayTag(AethelnGameplayTags::State_Staggered));
			Attacker.Player.AbilitySystem->RemoveLooseGameplayTag(AethelnGameplayTags::State_Dead);
		}
		else
		{
			TestEqual(TEXT("A zero stagger leaves the attacker free"), Attacker.Press(), EResult::Accepted);
		}
		Attacker.Player.AbilitySystem->OnChainEnded.Remove(Handle);
	}
	// A lethal earlier contact: the defender is dead before the window, so nothing is parried and no one is staggered.
	{
		FDefense F; if (!F.Init(*this, Abilities())) { return false; }
		AAethelnCombatAICharacter* Killer = F.SpawnEnemy(*this);
		AAethelnCombatAICharacter* Late = F.SpawnEnemy(*this);
		if (Killer == nullptr || Late == nullptr) { return false; }
		int32 Interrupts = 0;
		const FDelegateHandle Handle = F.Timeline->OnTargetInterrupted.AddLambda([&Interrupts](UAethelnAbilitySystemComponent*, double) { ++Interrupts; });
		AethelnCombatTests::ApplyInstantModifier(F.ASC(), UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::Override, 5.0f);
		F.AdvanceTo(0.90625);
		const FGuid Lethal = F.Swing(*Killer, 0.0f); // contact 1.03125: before the window, lethal
		F.AdvanceTo(1.0);
		Parry(F);
		const FGuid AfterDeath = F.Swing(*Late, 0.0f); // contact 1.125: inside the window, but the defender is dead
		F.AdvanceTo(2.0);
		const FAethelnCombatResult* Result = F.ResultFor(Lethal);
		if (TestNotNull(TEXT("The lethal contact is recorded"), Result)) { TestTrue(TEXT("Lethal"), Result->bLethal); }
		TestNull(TEXT("No result for a contact on a dead defender"), F.ResultFor(AfterDeath));
		TestEqual(TEXT("No one was staggered"), Interrupts, 0);
		F.Timeline->OnTargetInterrupted.Remove(Handle);
	}
	// An avoided contact staggers no one: the dodge ends the Parry, and its invulnerability window avoids the contact.
	{
		FDefense F; if (!F.Init(*this, Abilities())) { return false; }
		AAethelnCombatAICharacter* Enemy = F.SpawnEnemy(*this);
		if (Enemy == nullptr) { return false; }
		int32 Interrupts = 0;
		const FDelegateHandle Handle = F.Timeline->OnTargetInterrupted.AddLambda([&Interrupts](UAethelnAbilitySystemComponent*, double) { ++Interrupts; });
		F.AdvanceTo(1.0);
		TestEqual(TEXT("The Parry is accepted"), Parry(F), EResult::Accepted);
		TestEqual(TEXT("A dodge is accepted"), F.Dodge(), EResult::Accepted);
		const FGuid Avoided = F.Swing(*Enemy, 0.0f);
		F.AdvanceTo(2.0);
		const FAethelnCombatResult* Result = F.ResultFor(Avoided);
		if (TestNotNull(TEXT("The contact is recorded"), Result)) { TestEqual(TEXT("Avoided, never parried"), Result->Outcome, EOutcome::Avoided); }
		TestEqual(TEXT("No one was staggered"), Interrupts, 0);
		F.Timeline->OnTargetInterrupted.Remove(Handle);
	}
	return true;
}

// K8.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnParryRelationsTest,
	"Aetheln.GameCombat.OathscarActives.ParryRelations",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnParryRelationsTest::RunTest(const FString& Parameters)
{
	using namespace AethelnOathscarParryTests;
	const FGameplayTag Strike = AethelnGameplayTags::Ability_Oathscar_InstantStrike;
	{
		// Cost, cooldown, and one window at a time: a second press while it runs is refused, spending nothing.
		FDefense F; if (!F.Init(*this, Abilities())) { return false; }
		F.AdvanceTo(1.0);
		TestEqual(TEXT("Accepted"), Parry(F), EResult::Accepted);
		TestEqual(TEXT("Cost spent once"), F.CostApplications, 1);
		const int32 Spent = F.CostApplications;
		TestEqual(TEXT("A second press while the window runs is refused"), Parry(F), EResult::ActivationBlocked);
		TestEqual(TEXT("It spends nothing"), F.CostApplications, Spent);
		F.AdvanceTo(1.5);
		TestFalse(TEXT("The window ended"), ParryActive(F));
		TestEqual(TEXT("The cooldown refuses the next press"), Parry(F), EResult::OnCooldown);
		TestEqual(TEXT("Spending nothing"), F.CostApplications, Spent);
		TestTrue(TEXT("Its own cooldown tag"), F.Has(AethelnGameplayTags::Cooldown_Oathscar_Parry));
	}
	{
		// Refused while dodging, blocking, staggered or dead.
		FDefense F; if (!F.Init(*this, Abilities())) { return false; }
		F.AdvanceTo(1.0);
		TestEqual(TEXT("Dodge accepted"), F.Dodge(), EResult::Accepted);
		TestEqual(TEXT("Refused while dodging"), Parry(F), EResult::ActivationBlocked);
		F.AdvanceTo(2.0);
		F.ClearCooldowns();
		TestEqual(TEXT("Block raised"), F.Raise(), EResult::Accepted);
		const int32 Spent = F.CostApplications;
		TestEqual(TEXT("Refused while blocking"), Parry(F), EResult::ActivationBlocked);
		TestEqual(TEXT("It spends nothing"), F.CostApplications, Spent);
		TestEqual(TEXT("Block released"), F.Lower(), EResult::Accepted);
		F.ASC().AddLooseGameplayTag(AethelnGameplayTags::State_Staggered);
		TestEqual(TEXT("Refused while staggered"), Parry(F), EResult::ActivationBlocked);
		F.ASC().RemoveLooseGameplayTag(AethelnGameplayTags::State_Staggered);
		F.ASC().AddLooseGameplayTag(AethelnGameplayTags::State_Dead);
		TestEqual(TEXT("Refused while dead"), Parry(F), EResult::ActivationBlocked);
		F.ASC().RemoveLooseGameplayTag(AethelnGameplayTags::State_Dead);
		TestEqual(TEXT("Accepted when free"), Parry(F), EResult::Accepted);
	}
	{
		// A block is refused while the Parry window runs.
		FDefense F; if (!F.Init(*this, Abilities())) { return false; }
		F.AdvanceTo(1.0);
		TestEqual(TEXT("Accepted"), Parry(F), EResult::Accepted);
		const int32 Spent = F.CostApplications;
		TestEqual(TEXT("A block is refused during the window"), F.Raise(), EResult::ActivationBlocked);
		TestEqual(TEXT("It spends nothing"), F.CostApplications, Spent);
	}
	{
		// Refused inside the chain's commitment and inside Instant Strike's; the Parry's own relations to attacks stay open.
		FDefense F; if (!F.Init(*this, Abilities())) { return false; }
		F.AdvanceTo(1.0);
		TestEqual(TEXT("The chain's first hit is accepted"), F.Attack(), EResult::Accepted);
		F.AdvanceTo(1.25);
		const int32 Spent = F.CostApplications;
		TestEqual(TEXT("Refused inside the chain's commitment"), Parry(F), EResult::ActivationBlocked);
		TestEqual(TEXT("It spends nothing"), F.CostApplications, Spent);
		F.AdvanceTo(1.5); // the chain's CancelOpen
		TestEqual(TEXT("Accepted after the commitment window"), Parry(F), EResult::Accepted);
		if (TestEqual(TEXT("The chain ends once"), F.ChainEnds.Num(), 1)) { TestEqual(TEXT("With OtherAction"), F.ChainEnds[0], EAethelnChainEndReason::OtherAction); }
	}
	{
		FDefense F; if (!F.Init(*this, Abilities())) { return false; }
		F.AdvanceTo(1.0);
		TestEqual(TEXT("Instant Strike accepted"), F.Deliver(F.Request(Strike)), EResult::Accepted);
		F.AdvanceTo(1.25);
		TestEqual(TEXT("Refused inside Instant Strike's commitment"), Parry(F), EResult::ActivationBlocked);
		F.AdvanceTo(1.5);
		TestEqual(TEXT("Accepted after it"), Parry(F), EResult::Accepted);
		if (TestEqual(TEXT("The strike ends once"), F.ChainEnds.Num(), 1)) { TestEqual(TEXT("With OtherAction"), F.ChainEnds[0], EAethelnChainEndReason::OtherAction); }
	}
	{
		// An accepted dodge ends a running Parry window at its acceptance time, as it ends a block (Q10).
		FDefense F; if (!F.Init(*this, Abilities())) { return false; }
		F.AdvanceTo(1.0);
		TestEqual(TEXT("The Parry is accepted"), Parry(F), EResult::Accepted);
		F.AdvanceTo(1.25);
		TestEqual(TEXT("A dodge is accepted during the window"), F.Dodge(), EResult::Accepted);
		TestFalse(TEXT("The Parry ended"), ParryActive(F));
		TestFalse(TEXT("Its state tag is gone"), F.Has(AethelnGameplayTags::State_Oathscar_Parrying));
		if (TestNotNull(TEXT("The slot is kept for exact contacts"), F.Slot())) { TestEqual(TEXT("It ended at the dodge's acceptance"), F.Slot()->ActiveUntilServerTime, 1.25); }
	}
	{
		// State.Dead ends the window at the processing time.
		FDefense F; if (!F.Init(*this, Abilities())) { return false; }
		F.AdvanceTo(1.0);
		TestEqual(TEXT("The Parry is accepted"), Parry(F), EResult::Accepted);
		F.AdvanceTo(1.25);
		F.ASC().AddLooseGameplayTag(AethelnGameplayTags::State_Dead);
		TestFalse(TEXT("Death ends the activation"), ParryActive(F));
		TestFalse(TEXT("And the state tag"), F.Has(AethelnGameplayTags::State_Oathscar_Parrying));
		if (TestNotNull(TEXT("The slot is kept"), F.Slot())) { TestEqual(TEXT("It ended at the death time"), F.Slot()->ActiveUntilServerTime, 1.25); }
		F.ASC().RemoveLooseGameplayTag(AethelnGameplayTags::State_Dead);
	}
	{
		// Avatar loss ends it at the teardown time.
		FDefense F; if (!F.Init(*this, Abilities())) { return false; }
		F.AdvanceTo(1.0);
		TestEqual(TEXT("The Parry is accepted"), Parry(F), EResult::Accepted);
		F.AdvanceTo(1.25);
		F.Pawn->Destroy();
		TestFalse(TEXT("Teardown ends the activation"), ParryActive(F));
		TestFalse(TEXT("And the state tag"), F.Has(AethelnGameplayTags::State_Oathscar_Parrying));
		if (TestNotNull(TEXT("The slot is kept"), F.Slot())) { TestEqual(TEXT("It ended at the teardown time"), F.Slot()->ActiveUntilServerTime, 1.25); }
	}
	return true;
}

// K9: #60's A25 (request delivery), A26 (contacts), and A27 (teardown) rows replayed against the Parry.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnParryNetworkConditionsTest,
	"Aetheln.GameCombat.OathscarActives.ParryNetworkConditions",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnParryNetworkConditionsTest::RunTest(const FString& Parameters)
{
	using namespace AethelnOathscarParryTests;
	// The server arrival time decides, never the client sample (the request is built at 0.5). An enemy step starting at
	// 1.0 touches the defender at 1.125. A Parry arriving at 1.0625 defends [1.125, 1.5625): the contact is parried. One
	// arriving at 1.09375 defends from 1.15625: the same contact is a hit. One arriving after the contact cannot undo it.
	for (double Arrival : { 1.0625, 1.09375, 1.25 })
	{
		FDefense F; if (!F.Init(*this, Abilities())) { return false; }
		AAethelnCombatAICharacter* Enemy = F.SpawnEnemy(*this);
		if (Enemy == nullptr) { return false; }
		F.AdvanceTo(0.5);
		FAethelnCombatActivationRequest Delayed = F.Request(ParryId); // the client sample is 0.5
		F.AdvanceTo(1.0);
		const FGuid Contact = F.Swing(*Enemy, 0.0f);
		F.AdvanceTo(Arrival);
		TestEqual(TEXT("Delivered, accepted at its arrival time"), F.Deliver(Delayed), EResult::Accepted);
		TestEqual(TEXT("A duplicated delivery opens no second window"), F.Deliver(Delayed), EResult::DuplicateSequence);
		FAethelnCombatActivationRequest Older = Delayed;
		Older.Sequence = Delayed.Sequence - 1;
		TestEqual(TEXT("A reordered older delivery opens no second window"), F.Deliver(Older), EResult::StaleSequence);
		TestEqual(TEXT("One cost"), F.CostApplications, 1);
		F.AdvanceTo(2.0);
		const FAethelnCombatResult* Result = F.ResultFor(Contact);
		if (TestNotNull(TEXT("The contact is recorded"), Result))
		{
			TestEqual(TEXT("Judged by the server arrival time"), Result->Outcome, Arrival <= 1.0625 ? EOutcome::Parried : EOutcome::Hit);
		}
		if (TestNotNull(TEXT("The slot is the one window"), F.Slot())) { TestEqual(TEXT("From the arrival"), F.Slot()->ActiveFromServerTime, Arrival + 0.0625); }
	}
	// A dropped request sends nothing: the contact is a hit, and a later press is accepted.
	{
		FDefense F; if (!F.Init(*this, Abilities())) { return false; }
		AAethelnCombatAICharacter* Enemy = F.SpawnEnemy(*this);
		if (Enemy == nullptr) { return false; }
		F.AdvanceTo(1.0);
		F.Request(ParryId); // dropped: never delivered
		const FGuid Contact = F.Swing(*Enemy, 0.0f);
		F.AdvanceTo(2.0);
		const FAethelnCombatResult* Result = F.ResultFor(Contact);
		if (TestNotNull(TEXT("The contact is recorded"), Result)) { TestEqual(TEXT("No Parry without a request"), Result->Outcome, EOutcome::Hit); }
		TestEqual(TEXT("A later press, a forward sequence gap, is accepted"), F.Deliver(F.Request(ParryId, EAethelnActivationPhase::Press, 20)), EResult::Accepted);
	}
	// Teardown inside the window, before and after a contact: one end, no state, and the slot ends at the teardown time.
	for (double Time : { 1.0625, 1.25 })
	{
		FDefense F; if (!F.Init(*this, Abilities())) { return false; }
		F.AdvanceTo(1.0);
		TestEqual(TEXT("The Parry is accepted"), Parry(F), EResult::Accepted);
		F.AdvanceTo(Time);
		F.Pawn->Destroy();
		TestFalse(TEXT("The activation ended"), ParryActive(F));
		TestFalse(TEXT("No state tag"), F.Has(AethelnGameplayTags::State_Oathscar_Parrying));
		if (TestNotNull(TEXT("The slot is kept"), F.Slot())) { TestEqual(TEXT("It ended at the teardown time"), F.Slot()->ActiveUntilServerTime, Time); }
		F.AdvanceTo(2.0);
		TestEqual(TEXT("No later boundary touches it"), F.Timeline->GetBoundaryOwnerCountForTests(), 0);
	}
	return true;
}

#endif
