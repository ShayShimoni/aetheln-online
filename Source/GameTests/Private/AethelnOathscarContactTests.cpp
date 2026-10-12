#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnAbilitySystemComponent.h"
#include "AethelnChainTestFixture.h"
#include "AethelnCombatAICharacter.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnDefenseTestFixture.h"
#include "AethelnGameplayTags.h"
#include "AethelnOathscarTestAbilities.h"
#include "AethelnPlayerState.h"
#include "Misc/AutomationTest.h"

// #260: contacts and outcomes of the representative Oathscar actives (docs/attack-timeline-and-combo.md,
// Representative actives). Gate Step and Sworn Rebuke run as single-step attacks on #60's timeline; Hold the
// Line holds #18's defense slot. Fixture geometry and windows, not tuning: the chain fixture's step, whose
// radius-10 sphere first touches a radius-42 capsule 60 units ahead at its start + 0.125 + 0.125 * 8 / 30, and
// overlaps one 40 units ahead at its ActiveStart. Only an enemy can hit a player (OQ1), so the attacker of a
// player is an enemy dummy whose step is registered directly on the timeline, as #20's enemy steps will be.
namespace AethelnOathscarContactTests
{
	using namespace AethelnChainTests;
	using EResult = EAethelnActivationResult;
	using EOutcome = EAethelnCombatResultOutcome;

	constexpr double ContactOffset60 = 0.125 + 0.125 * 8.0 / 30.0;

	float Health(const UAethelnAbilitySystemComponent& AbilitySystem)
	{
		return AbilitySystem.GetNumericAttribute(UAethelnCombatAttributeSet::GetHealthAttribute());
	}

	/** A seam request built now for any fixture ability (content version 1); Sequence 0 takes the next one. */
	FAethelnCombatActivationRequest MakeRequest(FFixture& F, const FGameplayTag& AbilityId, uint32 Sequence = 0)
	{
		FAethelnCombatActivationRequest Request;
		Request.AbilityId = AbilityId;
		Request.ContentVersion = 1;
		Request.Sequence = Sequence != 0 ? Sequence : F.NextSequence++;
		AethelnCombatTests::FillTestAimAndTime(Request, *F.Player.AbilitySystem);
		return Request;
	}

	EResult Submit(FFixture& F, const FGameplayTag& AbilityId)
	{
		return F.Player.AbilitySystem->ProcessServerRequest(MakeRequest(F, AbilityId));
	}

	template <typename TAbility>
	TAbility* FindInstance(const UAethelnAbilitySystemComponent& AbilitySystem, FGameplayAbilitySpecHandle* OutHandle = nullptr)
	{
		const FGameplayAbilitySpec* Spec = AbilitySystem.FindAbilitySpecFromClass(TAbility::StaticClass());
		if (Spec != nullptr && OutHandle != nullptr) { *OutHandle = Spec->Handle; }
		return Spec != nullptr ? Cast<TAbility>(Spec->GetPrimaryInstance()) : nullptr;
	}

	bool IsActive(const UAethelnAbilitySystemComponent& AbilitySystem, const UClass* Class)
	{
		const FGameplayAbilitySpec* Spec = AbilitySystem.FindAbilitySpecFromClass(const_cast<UClass*>(Class));
		return Spec != nullptr && Spec->IsActive();
	}

	/** An enemy dummy with the fixture chain granted, so its directly registered step passes the content-version check. */
	AAethelnCombatAICharacter* SpawnEnemy(FAutomationTestBase& Test, const FFixture& F, const FVector& Location)
	{
		AAethelnCombatAICharacter* Enemy = F.SpawnTarget(Test, Location);
		if (Enemy != nullptr) { Enemy->GetAethelnAbilitySystemComponent()->GiveAbility(FGameplayAbilitySpec(UAethelnChainTestAbility::StaticClass(), 1)); }
		return Enemy;
	}

	/** Registers one enemy step starting now, aimed at the player. Returns its activation id. */
	FGuid Swing(const FFixture& F, AAethelnCombatAICharacter& Enemy, TFunctionRef<void(FAethelnAttackStepDefinition&)> Mutate)
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
		Record.StartServerTime = F.World.World->GetTimeSeconds();
		Record.AcceptedAim = (F.Pawn->GetActorLocation() - Enemy.GetActorLocation()).GetSafeNormal();
		return F.Timeline->RegisterStep(*Enemy.GetAethelnAbilitySystemComponent(), Step, Record, Chain->ProvisionalMaxSampleDistance, Chain->ProvisionalMaxSampleAngleDegrees)
			? Record.ActivationId : FGuid();
	}

	const FAethelnCombatResult* ResultFor(const FFixture& F, const FGuid& ActivationId)
	{
		return F.Results.FindByPredicate([&ActivationId](const FAethelnCombatResult& Result) { return Result.ActivationId == ActivationId; });
	}

	TArray<TSubclassOf<UGameplayAbility>> Attacks()
	{
		return { UAethelnGateStepTestAbility::StaticClass(), UAethelnSwornRebukeTestAbility::StaticClass() };
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnOathscarDefinitionsFailClosedTest,
	"Aetheln.GameCombat.OathscarActives.DefinitionsFailClosed",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnOathscarDefinitionsFailClosedTest::RunTest(const FString& Parameters)
{
	for (UClass* Fixture : { UAethelnGateStepTestAbility::StaticClass(), UAethelnSwornRebukeTestAbility::StaticClass(), UAethelnHoldTheLineTestAbility::StaticClass() })
	{
		TestTrue(FString::Printf(TEXT("%s: the fixture definition is grantable"), *Fixture->GetName()), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Fixture, 1)));
	}
	for (UClass* Production : { UAethelnGateStepAbility::StaticClass(), UAethelnSwornRebukeAbility::StaticClass(), UAethelnHoldTheLineAbility::StaticClass() })
	{
		AddExpectedError(TEXT("Refused to grant ability"), EAutomationExpectedErrorFlags::Contains, 1);
		TestFalse(FString::Printf(TEXT("%s: unset production values refuse the grant"), *Production->GetName()), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Production, 1)));
	}
	const UAethelnGateStepTestAbility* GateStep = GetDefault<UAethelnGateStepTestAbility>();
	const UAethelnSwornRebukeTestAbility* SwornRebuke = GetDefault<UAethelnSwornRebukeTestAbility>();
	TestEqual(TEXT("Gate Step is a single step"), GateStep->GetStepCount(), 1);
	TestEqual(TEXT("Sworn Rebuke is a single step"), SwornRebuke->GetStepCount(), 1);
	TestEqual(TEXT("Gate Step holds its own commitment tag"), GateStep->GetCommitmentTag(), AethelnGameplayTags::State_Oathscar_GateStep.GetTag());
	TestEqual(TEXT("Sworn Rebuke holds its own commitment tag"), SwornRebuke->GetCommitmentTag(), AethelnGameplayTags::State_Oathscar_SwornRebuke.GetTag());
	TestEqual(TEXT("The chain keeps three steps"), GetDefault<UAethelnChainTestAbility>()->GetStepCount(), 3);
	// Q17 and Q10: an attack press while dodging or blocking is refused, so each blocking tag is also a reset tag.
	for (const TPair<const FGameplayTagContainer*, const FGameplayTagContainer*>& Attack : {
		TPair<const FGameplayTagContainer*, const FGameplayTagContainer*>(&GateStep->GetBlockedTagsForTests(), &GateStep->ResetTags),
		TPair<const FGameplayTagContainer*, const FGameplayTagContainer*>(&SwornRebuke->GetBlockedTagsForTests(), &SwornRebuke->ResetTags) })
	{
		TestTrue(TEXT("Blocked while dodging"), Attack.Key->HasTagExact(AethelnGameplayTags::State_Dodging));
		TestTrue(TEXT("Blocked while blocking"), Attack.Key->HasTagExact(AethelnGameplayTags::State_Blocking));
		TestTrue(TEXT("Resets on State.Dead"), Attack.Value->HasTagExact(AethelnGameplayTags::State_Dead));
	}
	const TArray<TFunction<void(UAethelnGateStepTestAbility&)>> Mutations = {
		[](auto& A) { A.ProvisionalSteps.Reset(); },
		[](auto& A) { const FAethelnAttackStepDefinition Copy = A.ProvisionalSteps[0]; A.ProvisionalSteps.Add(Copy); },
		[](auto& A) { A.ProvisionalSteps[0].BufferOpen = 0.375; }, // a single step is the final step: BufferOpen == RecoveryEnd
		[](auto& A) { A.ProvisionalSteps[0].LinkOpen = 0.625; A.ProvisionalSteps[0].LinkClose = 0.75; },
		[](auto& A) { A.ProvisionalSteps[0].GuardPressure = -1.0f; },
		[](auto& A) { A.ProvisionalMaxSampleDistance = 0.0; },
		[](auto& A) { A.ProvisionalCooldownSeconds = -1.0f; },
		[](auto& A) { A.bAcceptsRelease = true; },
		[](auto& A) { A.ContentVersion = 0; },
		[](auto& A) { A.ResetTags.Reset(); },
	};
	for (const auto& Mutate : Mutations)
	{
		UAethelnGateStepTestAbility* Definition = NewObject<UAethelnGateStepTestAbility>();
		Mutate(*Definition);
		AddExpectedError(TEXT("Refused to grant ability"), EAutomationExpectedErrorFlags::Contains, 1);
		TestFalse(TEXT("Each invalid single-step value refuses at grant"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Definition)));
	}
	UAethelnGateStepTestAbility* NoCooldown = NewObject<UAethelnGateStepTestAbility>();
	NoCooldown->ProvisionalCooldownSeconds = 0.0f;
	TestTrue(TEXT("A single step may have no cooldown"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(NoCooldown)));
	UAethelnChainTestAbility* ChainWithCooldown = NewObject<UAethelnChainTestAbility>();
	ChainWithCooldown->ProvisionalCooldownSeconds = 1.0f;
	AddExpectedError(TEXT("Refused to grant ability"), EAutomationExpectedErrorFlags::Contains, 1);
	TestFalse(TEXT("The three-step chain still refuses a cooldown"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(ChainWithCooldown)));

	// Hold the Line: the block's grant rules with its own state tag, and Q10 both ways.
	const UAethelnHoldTheLineTestAbility* HoldTheLine = GetDefault<UAethelnHoldTheLineTestAbility>();
	TestTrue(TEXT("Hold the Line is blocked while blocking (Q10)"), HoldTheLine->GetBlockedTagsForTests().HasTagExact(AethelnGameplayTags::State_Blocking));
	TestFalse(TEXT("Hold the Line is not blocked by its own state"), HoldTheLine->GetBlockedTagsForTests().HasTagExact(AethelnGameplayTags::State_Oathscar_HoldTheLine));
	TestTrue(TEXT("The block is blocked while Hold the Line holds (Q10)"), GetDefault<UAethelnBlockTestAbility>()->GetBlockedTagsForTests().HasTagExact(AethelnGameplayTags::State_Oathscar_HoldTheLine));
	TestTrue(TEXT("Hold the Line accepts Release"), HoldTheLine->bAcceptsRelease);
	for (const FGameplayTag Missing : { AethelnGameplayTags::State_Blocking.GetTag(), AethelnGameplayTags::State_Dead.GetTag() })
	{
		UAethelnHoldTheLineTestAbility* Definition = NewObject<UAethelnHoldTheLineTestAbility>();
		FGameplayTagContainer Tags = Definition->GetBlockedTagsForTests();
		Tags.RemoveTag(Missing);
		Definition->SetBlockedTagsForTests(Tags);
		AddExpectedError(TEXT("Refused to grant ability"), EAutomationExpectedErrorFlags::Contains, 1);
		TestFalse(FString::Printf(TEXT("Hold the Line without blocking tag %s refuses at grant"), *Missing.ToString()), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Definition)));
	}
	UAethelnHoldTheLineTestAbility* NoRelease = NewObject<UAethelnHoldTheLineTestAbility>();
	NoRelease->bAcceptsRelease = false;
	AddExpectedError(TEXT("Refused to grant ability"), EAutomationExpectedErrorFlags::Contains, 1);
	TestFalse(TEXT("Hold the Line without a Release route refuses at grant"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(NoRelease)));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnOathscarSingleStepContactTest,
	"Aetheln.GameCombat.OathscarActives.SingleStepContact",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnOathscarSingleStepContactTest::RunTest(const FString& Parameters)
{
	using namespace AethelnOathscarContactTests;
	for (const FGameplayTag AbilityId : { AethelnGameplayTags::Ability_Oathscar_GateStep.GetTag(), AethelnGameplayTags::Ability_Oathscar_SwornRebuke.GetTag() })
	{
		const bool bGateStep = AbilityId == AethelnGameplayTags::Ability_Oathscar_GateStep;
		const FGameplayTag Commitment = bGateStep ? AethelnGameplayTags::State_Oathscar_GateStep.GetTag() : AethelnGameplayTags::State_Oathscar_SwornRebuke.GetTag();
		const UClass* Class = bGateStep ? UAethelnGateStepTestAbility::StaticClass() : UAethelnSwornRebukeTestAbility::StaticClass();
		const FString Name = AbilityId.ToString();
		FFixture F; if (!F.Init(*this, Attacks())) { return false; }
		UAethelnAbilitySystemComponent& ASC = *F.Player.AbilitySystem;
		AAethelnCombatAICharacter* Target = F.SpawnTarget(*this, FVector(60.0, 0.0, 0.0));
		if (Target == nullptr) { return false; }

		TestEqual(Name + TEXT(": accepted"), Submit(F, AbilityId), EResult::Accepted);
		if (!TestEqual(Name + TEXT(": one record"), F.Records.Num(), 1)) { return false; }
		TestEqual(Name + TEXT(": the record names the active"), F.Records[0].AbilityId, AbilityId);
		TestEqual(Name + TEXT(": its single step"), F.Records[0].ChainStep, uint8(1));
		TestEqual(Name + TEXT(": starts at server receipt"), F.Records[0].StartServerTime, 0.0);
		TestEqual(Name + TEXT(": its authored recovery"), F.Records[0].Windows.RecoveryEnd, 0.625);
		TestEqual(Name + TEXT(": cost spent once"), F.CostApplications, 1);
		TestTrue(Name + TEXT(": holds its own commitment"), ASC.HasMatchingGameplayTag(Commitment));
		TestFalse(Name + TEXT(": never the chain's commitment"), ASC.HasMatchingGameplayTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain));
		TestEqual(Name + TEXT(": an early press is refused by the running activation"), Submit(F, AbilityId), EResult::ActivationBlocked);
		TestEqual(Name + TEXT(": the early press spends nothing"), F.CostApplications, 1);

		F.AdvanceTo(0.5);
		if (TestEqual(Name + TEXT(": one result"), F.Results.Num(), 1))
		{
			TestEqual(Name + TEXT(": the result names the active"), F.Results[0].AbilityId, AbilityId);
			TestEqual(Name + TEXT(": a server hit"), F.Results[0].Outcome, EOutcome::Hit);
			TestEqual(Name + TEXT(": of this activation"), F.Results[0].ActivationId, F.Records[0].ActivationId);
			TestNearlyEqual(Name + TEXT(": at the authored contact time"), F.Results[0].ContactTime, ContactOffset60, 1.0e-3);
		}
		TestEqual(Name + TEXT(": damage by the authored magnitude"), Health(*Target->GetAethelnAbilitySystemComponent()), 35.0f);
		TestFalse(Name + TEXT(": the commitment ends at CancelOpen"), ASC.HasMatchingGameplayTag(Commitment));
		TestTrue(Name + TEXT(": the activation lasts until RecoveryEnd"), IsActive(ASC, Class));
		TestEqual(Name + TEXT(": no end before RecoveryEnd"), F.Ends.Num(), 0);

		F.AdvanceTo(0.625);
		if (TestEqual(Name + TEXT(": one end"), F.Ends.Num(), 1))
		{
			TestEqual(Name + TEXT(": completed at RecoveryEnd"), F.Ends[0].Reason, EAethelnChainEndReason::Completed);
			TestEqual(Name + TEXT(": the end names the activation"), F.Ends[0].ActivationId, F.Records[0].ActivationId);
		}
		TestFalse(Name + TEXT(": the activation ended"), IsActive(ASC, Class));
		TestEqual(Name + TEXT(": the authored cooldown refuses the next press"), Submit(F, AbilityId), EResult::OnCooldown);
		TestEqual(Name + TEXT(": the cooldown rejection spends nothing"), F.CostApplications, 1);
		ASC.RemoveActiveEffectsWithGrantedTags(FGameplayTagContainer(bGateStep ? AethelnGameplayTags::Cooldown_Oathscar_GateStep : AethelnGameplayTags::Cooldown_Oathscar_SwornRebuke));
		TestEqual(Name + TEXT(": accepted after the cooldown"), Submit(F, AbilityId), EResult::Accepted);
		F.AdvanceTo(1.25);
		TestEqual(Name + TEXT(": a new activation hits the target again, once"), F.Results.Num(), 2);
		TestEqual(Name + TEXT(": two activations, two hits"), Health(*Target->GetAethelnAbilitySystemComponent()), 30.0f);
	}
	{
		// Gate Step's authored Guard pressure reaches a defending target's hook once; the contact is Blocked.
		int32 HookCalls = 0;
		float Pressure = 0.0f;
		FGameplayTag HookAbility;
		FFixture F; if (!F.Init(*this, Attacks())) { return false; }
		AAethelnCombatAICharacter* Target = F.SpawnTarget(*this, FVector(60.0, 0.0, 0.0));
		if (Target == nullptr) { return false; }
		Target->SetActorRotation(FRotator(0.0, 180.0, 0.0)); // facing the attacker
		FAethelnDefenseState Slot;
		Slot.StateTag = AethelnCombatTestTags::Test_Defending;
		Slot.ArcDegrees = 180.0;
		Slot.OnBlocked.BindLambda([&](const FAethelnBlockedContact& Contact)
		{
			++HookCalls; Pressure = Contact.GuardPressure; HookAbility = Contact.AbilityId;
			return EAethelnBlockConsequence::Blocked;
		});
		TestTrue(TEXT("The test defense slot registers"), F.Timeline->SetDefenseState(*Target->GetAethelnAbilitySystemComponent(), Slot));
		TestEqual(TEXT("Gate Step accepted"), Submit(F, AethelnGameplayTags::Ability_Oathscar_GateStep), EResult::Accepted);
		F.AdvanceTo(0.5);
		if (TestEqual(TEXT("One result"), F.Results.Num(), 1)) { TestEqual(TEXT("Blocked"), F.Results[0].Outcome, EOutcome::Blocked); }
		TestEqual(TEXT("The hook runs once"), HookCalls, 1);
		TestEqual(TEXT("With Gate Step's authored Guard pressure"), Pressure, 3.0f);
		TestEqual(TEXT("For Gate Step"), HookAbility, AethelnGameplayTags::Ability_Oathscar_GateStep.GetTag());
		TestEqual(TEXT("A blocked contact deals no damage"), Health(*Target->GetAethelnAbilitySystemComponent()), 40.0f);
		F.Timeline->ClearDefenseState(*Target->GetAethelnAbilitySystemComponent());
	}
	{
		// Another committed action ends a running active (OtherAction), and an active ends the chain the same way.
		FFixture F; if (!F.Init(*this, Attacks())) { return false; }
		TestEqual(TEXT("Gate Step accepted"), Submit(F, AethelnGameplayTags::Ability_Oathscar_GateStep), EResult::Accepted);
		F.AdvanceTo(0.25);
		TestEqual(TEXT("A chain press during Gate Step is accepted"), F.Press(), EResult::Accepted);
		if (TestEqual(TEXT("Gate Step ends once"), F.Ends.Num(), 1)) { TestEqual(TEXT("With OtherAction"), F.Ends[0].Reason, EAethelnChainEndReason::OtherAction); }
		TestFalse(TEXT("Gate Step's activation was ended"), IsActive(*F.Player.AbilitySystem, UAethelnGateStepTestAbility::StaticClass()));
		TestFalse(TEXT("Its commitment is gone"), F.Player.AbilitySystem->HasMatchingGameplayTag(AethelnGameplayTags::State_Oathscar_GateStep));
		TestTrue(TEXT("The chain holds its commitment"), F.Player.AbilitySystem->HasMatchingGameplayTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain));
		F.AdvanceTo(0.5);
		TestEqual(TEXT("Sworn Rebuke after the chain's buffer opens"), Submit(F, AethelnGameplayTags::Ability_Oathscar_SwornRebuke), EResult::Accepted);
		if (TestEqual(TEXT("The chain ends once"), F.Ends.Num(), 2)) { TestEqual(TEXT("With OtherAction"), F.Ends[1].Reason, EAethelnChainEndReason::OtherAction); }
		TestEqual(TEXT("Sworn Rebuke started"), F.Records.Last().AbilityId, AethelnGameplayTags::Ability_Oathscar_SwornRebuke.GetTag());
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnOathscarInterruptionTest,
	"Aetheln.GameCombat.OathscarActives.Interruption",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnOathscarInterruptionTest::RunTest(const FString& Parameters)
{
	using namespace AethelnOathscarContactTests;
	// Sworn Rebuke's authored interruption rule ends an enemy's interruptible step at the contact time, so
	// the enemy's later contact drops; Gate Step authors none, so the enemy's hit lands.
	for (const FGameplayTag AbilityId : { AethelnGameplayTags::Ability_Oathscar_SwornRebuke.GetTag(), AethelnGameplayTags::Ability_Oathscar_GateStep.GetTag() })
	{
		const bool bInterrupts = AbilityId == AethelnGameplayTags::Ability_Oathscar_SwornRebuke;
		FFixture F; if (!F.Init(*this, Attacks())) { return false; }
		AAethelnCombatAICharacter* Enemy = SpawnEnemy(*this, F, FVector(60.0, 0.0, 0.0));
		if (Enemy == nullptr) { return false; }
		TestEqual(TEXT("The active is accepted"), Submit(F, AbilityId), EResult::Accepted); // contact at 0.1583
		F.AdvanceTo(0.0625);
		const FGuid EnemyId = Swing(F, *Enemy, [](FAethelnAttackStepDefinition& Step) { Step.InterruptibleUntil = 0.5; }); // contact at 0.2208
		TestTrue(TEXT("The enemy step registers"), EnemyId.IsValid());
		F.AdvanceTo(0.5);
		const FAethelnCombatResult* PlayerResult = F.Records.Num() == 1 ? ResultFor(F, F.Records[0].ActivationId) : nullptr;
		if (TestNotNull(TEXT("The active hits the enemy"), PlayerResult)) { TestEqual(TEXT("An ordinary hit"), PlayerResult->Outcome, EOutcome::Hit); }
		TestEqual(bInterrupts ? TEXT("Sworn Rebuke's interruption drops the enemy's later contact") : TEXT("Without an interruption rule the enemy's hit lands"),
			ResultFor(F, EnemyId) != nullptr, !bInterrupts);
		TestEqual(TEXT("Player Health follows"), Health(*F.Player.AbilitySystem), bInterrupts ? 40.0f : 35.0f);
	}
	// An active is itself interruptible inside its authored window: an enemy's interrupting hit ends it at the
	// contact time, keeping its earlier contact and dropping its later one. InterruptibleUntil 0 means never.
	for (double InterruptibleUntil : { 0.25, 0.0 })
	{
		FFixture F; if (!F.Init(*this, Attacks())) { return false; }
		UAethelnGateStepTestAbility* GateStep = FindInstance<UAethelnGateStepTestAbility>(*F.Player.AbilitySystem);
		if (!TestNotNull(TEXT("Gate Step instance"), GateStep)) { return false; }
		GateStep->ProvisionalSteps[0].InterruptibleUntil = InterruptibleUntil;
		AAethelnCombatAICharacter* Enemy = SpawnEnemy(*this, F, FVector(-60.0, 0.0, 0.0));
		AAethelnCombatAICharacter* Near = F.SpawnTarget(*this, FVector(40.0, 0.0, 0.0)); // Gate Step contact at 0.125
		AAethelnCombatAICharacter* Far = F.SpawnTarget(*this, FVector(70.0, 0.0, 50.0)); // Gate Step contact after the interruption
		if (Enemy == nullptr || Near == nullptr || Far == nullptr) { return false; }
		TestEqual(TEXT("Gate Step accepted"), Submit(F, AethelnGameplayTags::Ability_Oathscar_GateStep), EResult::Accepted);
		const FGuid EnemyId = Swing(F, *Enemy, [](FAethelnAttackStepDefinition& Step) { Step.bInterruptsTarget = true; });
		F.AdvanceTo(0.5);
		const FAethelnCombatResult* Interrupting = ResultFor(F, EnemyId);
		if (!TestNotNull(TEXT("The enemy hits the player"), Interrupting)) { return false; }
		TestEqual(TEXT("The earlier Gate Step contact survives"), Health(*Near->GetAethelnAbilitySystemComponent()), 35.0f);
		if (InterruptibleUntil > 0.0)
		{
			if (TestEqual(TEXT("One end"), F.Ends.Num(), 1)) { TestEqual(TEXT("Gate Step ends Interrupted"), F.Ends[0].Reason, EAethelnChainEndReason::Interrupted); }
			TestEqual(TEXT("Stamped at the contact time"), F.Player.AbilitySystem->GetLastChainResetTimeForTests(), Interrupting->ContactTime);
			TestEqual(TEXT("The later Gate Step contact drops"), Health(*Far->GetAethelnAbilitySystemComponent()), 40.0f);
			TestFalse(TEXT("The activation was ended"), IsActive(*F.Player.AbilitySystem, UAethelnGateStepTestAbility::StaticClass()));
		}
		else
		{
			TestEqual(TEXT("No end"), F.Ends.Num(), 0);
			TestEqual(TEXT("The later Gate Step contact lands"), Health(*Far->GetAethelnAbilitySystemComponent()), 35.0f);
		}
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnOathscarHoldTheLineGuardResultTest,
	"Aetheln.GameCombat.OathscarActives.HoldTheLineGuardResult",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnOathscarHoldTheLineGuardResultTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDefenseTests;
	const TArray<TSubclassOf<UGameplayAbility>> Abilities = { UAethelnHoldTheLineTestAbility::StaticClass(), UAethelnBlockTestAbility::StaticClass(),
		UAethelnDodgeTestAbility::StaticClass(), UAethelnChainTestAbility::StaticClass() };
	const FGameplayTag HoldTheLine = AethelnGameplayTags::Ability_Oathscar_HoldTheLine;
	const FGameplayTag HoldState = AethelnGameplayTags::State_Oathscar_HoldTheLine;
	{
		FDefense F; if (!F.Init(*this, Abilities)) { return false; }
		AAethelnCombatAICharacter* Front = F.SpawnEnemy(*this, FVector(40.0, 0.0, 0.0));
		AAethelnCombatAICharacter* Behind = F.SpawnEnemy(*this, FVector(-40.0, 0.0, 0.0));
		if (Front == nullptr || Behind == nullptr) { return false; }
		TestEqual(TEXT("Hold the Line is raised"), F.Deliver(F.Request(HoldTheLine)), EResult::Accepted);
		TestTrue(TEXT("It holds its own state"), F.Has(HoldState));
		TestFalse(TEXT("Never the block's state"), F.Has(AethelnGameplayTags::State_Blocking));
		if (TestNotNull(TEXT("It holds the defense slot"), F.Slot()))
		{
			TestEqual(TEXT("The slot carries its state tag"), F.Slot()->StateTag, HoldState);
			TestEqual(TEXT("Defending from the authored raise time"), F.Slot()->ActiveFromServerTime, 0.0625);
			TestEqual(TEXT("The authored arc"), F.Slot()->ArcDegrees, 180.0);
		}
		TestEqual(TEXT("The block is refused while Hold the Line holds (Q10)"), F.Raise(), EResult::ActivationBlocked);

		F.AdvanceTo(0.0625);
		const FGuid FrontId = F.Swing(*Front, 2.0f); // contact at 0.1875, inside the arc
		F.AdvanceTo(0.5);
		const FAethelnCombatResult* Blocked = F.ResultFor(FrontId);
		if (TestNotNull(TEXT("A result for the facing contact"), Blocked)) { TestEqual(TEXT("Blocked"), Blocked->Outcome, EOutcome::Blocked); }
		TestEqual(TEXT("Guard pressure applied once"), F.PressureApplications, 1);
		TestEqual(TEXT("Guard reduced by the authored pressure"), F.Guard(), 18.0f);
		TestEqual(TEXT("No Health damage"), F.Health(), 40.0f);

		const FGuid BehindId = F.Swing(*Behind, 2.0f);
		F.AdvanceTo(1.0);
		const FAethelnCombatResult* Hit = F.ResultFor(BehindId);
		if (TestNotNull(TEXT("A result for the contact from behind"), Hit)) { TestEqual(TEXT("Outside the arc: a hit"), Hit->Outcome, EOutcome::Hit); }
		TestEqual(TEXT("Damage from behind"), F.Health(), 35.0f);
		TestEqual(TEXT("No pressure from an unblocked contact"), F.PressureApplications, 1);

		const FGuid BreakId = F.Swing(*Front, 18.0f);
		F.AdvanceTo(1.5);
		const FAethelnCombatResult* Broken = F.ResultFor(BreakId);
		if (!TestNotNull(TEXT("A result for the breaking contact"), Broken)) { return false; }
		TestEqual(TEXT("GuardBroken"), Broken->Outcome, EOutcome::GuardBroken);
		TestFalse(TEXT("A Guard break ends Hold the Line"), F.Has(HoldState));
		TestTrue(TEXT("The Guard break state holds"), F.Has(AethelnGameplayTags::State_GuardBroken));
		if (F.Slot() != nullptr) { TestEqual(TEXT("The slot ends at the contact time"), F.Slot()->ActiveUntilServerTime, Broken->ContactTime); }
		// Isolate State.GuardBroken: Guard restored and cooldown cleared, the Press is still refused.
		F.ASC().RemoveActiveEffectsWithGrantedTags(FGameplayTagContainer(AethelnGameplayTags::Cooldown_Oathscar_HoldTheLine));
		AethelnCombatTests::ApplyInstantModifier(F.ASC(), UAethelnCombatAttributeSet::GetGuardAttribute(), EGameplayModOp::Override, 20.0f);
		TestEqual(TEXT("No raise during the break"), F.Deliver(F.Request(HoldTheLine)), EResult::ActivationBlocked);
	}
	{
		// Release lowers it at the processing time; an ended slot defends nothing. The block refuses Hold the Line (Q10).
		FDefense F; if (!F.Init(*this, Abilities)) { return false; }
		AAethelnCombatAICharacter* Front = F.SpawnEnemy(*this, FVector(40.0, 0.0, 0.0));
		if (Front == nullptr) { return false; }
		TestEqual(TEXT("Raised"), F.Deliver(F.Request(HoldTheLine)), EResult::Accepted);
		F.AdvanceTo(0.25);
		TestEqual(TEXT("Released"), F.Deliver(F.Request(HoldTheLine, EAethelnActivationPhase::Release)), EResult::Accepted);
		TestFalse(TEXT("The state is gone"), F.Has(HoldState));
		if (TestNotNull(TEXT("The slot is kept for exact contacts"), F.Slot())) { TestEqual(TEXT("Ended at the release"), F.Slot()->ActiveUntilServerTime, 0.25); }
		const FGuid FrontId = F.Swing(*Front, 2.0f);
		F.AdvanceTo(0.75);
		const FAethelnCombatResult* Hit = F.ResultFor(FrontId);
		if (TestNotNull(TEXT("A result after the release"), Hit)) { TestEqual(TEXT("A lowered defense: a hit"), Hit->Outcome, EOutcome::Hit); }
		TestEqual(TEXT("No pressure after the release"), F.PressureApplications, 0);
		TestEqual(TEXT("The block is raised"), F.Raise(), EResult::Accepted);
		F.ASC().RemoveActiveEffectsWithGrantedTags(FGameplayTagContainer(AethelnGameplayTags::Cooldown_Oathscar_HoldTheLine));
		TestEqual(TEXT("Hold the Line is refused while blocking (Q10)"), F.Deliver(F.Request(HoldTheLine)), EResult::ActivationBlocked);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnOathscarNetworkConditionsTest,
	"Aetheln.GameCombat.OathscarActives.NetworkConditions",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnOathscarNetworkConditionsTest::RunTest(const FString& Parameters)
{
	using namespace AethelnOathscarContactTests;
	const FGameplayTag GateStepId = AethelnGameplayTags::Ability_Oathscar_GateStep;
	// A25 and A26 delivery profiles (fixture arrival times, not a network profile) against a single-step active.
	for (double Arrival : { 0.5, 0.625, 0.75 })
	{
		FFixture F; if (!F.Init(*this, Attacks())) { return false; }
		UAethelnGateStepTestAbility* GateStep = FindInstance<UAethelnGateStepTestAbility>(*F.Player.AbilitySystem);
		AAethelnCombatAICharacter* Target = F.SpawnTarget(*this, FVector(60.0, 0.0, 0.0));
		if (!TestNotNull(TEXT("Gate Step instance"), GateStep) || Target == nullptr) { return false; }
		GateStep->ProvisionalCooldownSeconds = 0.0f; // so arrival time alone decides
		TestEqual(TEXT("First press accepted"), Submit(F, GateStepId), EResult::Accepted);
		FAethelnCombatActivationRequest Delayed = MakeRequest(F, GateStepId, 10); // explicit gap; client sample 0
		F.AdvanceTo(Arrival);
		const EResult Expected = Arrival < 0.625 ? EResult::ActivationBlocked : EResult::Accepted;
		TestEqual(TEXT("Server arrival governs the window, never the client sample"), F.Player.AbilitySystem->ProcessServerRequest(Delayed), Expected);
		TestEqual(TEXT("Duplicate delivery"), F.Player.AbilitySystem->ProcessServerRequest(Delayed), Expected == EResult::Accepted ? EResult::DuplicateSequence : EResult::ActivationBlocked);
		Delayed.Sequence = 9;
		TestEqual(TEXT("Reordered older delivery"), F.Player.AbilitySystem->ProcessServerRequest(Delayed), Expected == EResult::Accepted ? EResult::StaleSequence : EResult::ActivationBlocked);
		F.AdvanceTo(2.0);
		const int32 Started = Expected == EResult::Accepted ? 2 : 1;
		TestEqual(TEXT("One started step per accepted request"), F.Records.Num(), Started);
		TestEqual(TEXT("No double spend"), F.CostApplications, Started);
		TestEqual(TEXT("Each started step hits the target exactly once"), F.Results.Num(), Started);
		TestEqual(TEXT("Damage matches the results"), Health(*Target->GetAethelnAbilitySystemComponent()), 40.0f - 5.0f * Started);
		for (const FAethelnCombatResult& Result : F.Results)
		{
			const FAethelnCombatActivationRecord* Record = F.Records.FindByPredicate([&Result](const FAethelnCombatActivationRecord& Item) { return Item.ActivationId == Result.ActivationId; });
			if (TestNotNull(TEXT("Every result belongs to a started step"), Record))
			{
				TestNearlyEqual(TEXT("Delay moves only when the step starts"), Result.ContactTime - Record->StartServerTime, ContactOffset60, 1.0e-3);
			}
		}
		// A dropped request sends nothing; the next one, a forward gap, is accepted.
		TestEqual(TEXT("Forward sequence gap after a drop"), F.Player.AbilitySystem->ProcessServerRequest(MakeRequest(F, GateStepId, 20)), EResult::Accepted);
	}
	// A27: teardown during wind-up or after the contact: one end, no contact at or after the teardown time.
	for (double Time : { 0.0625, 0.1875 })
	{
		FFixture F; if (!F.Init(*this, Attacks())) { return false; }
		if (F.SpawnTarget(*this, FVector(60.0, 0.0, 0.0)) == nullptr) { return false; }
		TestEqual(TEXT("Gate Step accepted"), Submit(F, GateStepId), EResult::Accepted);
		F.AdvanceTo(Time);
		F.Pawn->Destroy();
		if (TestEqual(TEXT("Teardown sends one end"), F.Ends.Num(), 1)) { TestEqual(TEXT("AvatarLost"), F.Ends[0].Reason, EAethelnChainEndReason::AvatarLost); }
		F.AdvanceTo(1.0);
		TestEqual(TEXT("No contact at or after the teardown time"), F.Results.Num(), Time > ContactOffset60 ? 1 : 0);
		TestEqual(TEXT("No subsystem step leaks"), F.Timeline->GetRegisteredStepCountForTests(), 0);
	}
	// Hold the Line Press and Release under reordering, duplication, a dropped Release, and teardown.
	{
		const FGameplayTag HoldTheLine = AethelnGameplayTags::Ability_Oathscar_HoldTheLine;
		AethelnDefenseTests::FDefense F; if (!F.Init(*this, { UAethelnHoldTheLineTestAbility::StaticClass() })) { return false; }
		const FAethelnCombatActivationRequest Press = F.Request(HoldTheLine);
		const FAethelnCombatActivationRequest Release = F.Request(HoldTheLine, EAethelnActivationPhase::Release);
		TestEqual(TEXT("A Release that overtakes its Press is refused"), F.Deliver(Release), EResult::ActivationBlocked);
		TestEqual(TEXT("The Press still raises it"), F.Deliver(Press), EResult::Accepted);
		TestEqual(TEXT("A duplicated Press"), F.Deliver(Press), EResult::DuplicateSequence);
		TestEqual(TEXT("One cost"), F.CostApplications, 1);
		F.AdvanceTo(0.25);
		TestEqual(TEXT("The Release lowers it"), F.Deliver(Release), EResult::Accepted);
		TestEqual(TEXT("A duplicated Release"), F.Deliver(Release), EResult::DuplicateSequence);
		if (F.Slot() != nullptr) { TestEqual(TEXT("Ended once, at the first Release"), F.Slot()->ActiveUntilServerTime, 0.25); }
	}
	{
		const FGameplayTag HoldTheLine = AethelnGameplayTags::Ability_Oathscar_HoldTheLine;
		AethelnDefenseTests::FDefense F; if (!F.Init(*this, { UAethelnHoldTheLineTestAbility::StaticClass() })) { return false; }
		AAethelnCombatAICharacter* Front = F.SpawnEnemy(*this, FVector(40.0, 0.0, 0.0));
		if (Front == nullptr) { return false; }
		TestEqual(TEXT("Raised"), F.Deliver(F.Request(HoldTheLine)), EResult::Accepted);
		F.Request(HoldTheLine, EAethelnActivationPhase::Release); // dropped: never delivered
		F.AdvanceTo(1.0);
		const FGuid FrontId = F.Swing(*Front, 2.0f);
		F.AdvanceTo(1.5);
		const FAethelnCombatResult* Blocked = F.ResultFor(FrontId);
		if (TestNotNull(TEXT("A result while still held"), Blocked)) { TestEqual(TEXT("A dropped Release keeps it held"), Blocked->Outcome, EOutcome::Blocked); }
		F.Pawn->Destroy();
		TestFalse(TEXT("Teardown ends the state"), F.Has(AethelnGameplayTags::State_Oathscar_HoldTheLine));
		if (F.Slot() != nullptr) { TestEqual(TEXT("Teardown ends the slot at its processing time"), F.Slot()->ActiveUntilServerTime, 1.5); }
	}
	return true;
}

#endif
