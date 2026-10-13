#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnAbilitySystemComponent.h"
#include "AethelnChainTestFixture.h"
#include "AethelnCombatAICharacter.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnDefenseTestFixture.h"
#include "AethelnGameplayTags.h"
#include "AethelnOathscarTestAbilities.h"
#include "AethelnPlayerState.h"
#include "GameplayTagsManager.h"
#include "Misc/AutomationTest.h"
#include "Misc/ConfigCacheIni.h"
#include <limits>

// #260 (docs/gas-foundation.md, Representative Oathscar Actives; K1 to K4 and K13): Instant Strike, the
// single-step use of #60's timeline and contact pipeline. Fixture geometry and windows, not tuning: the chain
// fixture's step, whose radius-10 sphere first touches a target dummy 60 units ahead at its start + 0.125 +
// 0.125 * 16 / 30, and overlaps one 40 units ahead at its ActiveStart. Only an enemy can hit a player (OQ1), so
// the attacker of a player is an enemy dummy whose step is registered directly on the timeline, as #20's
// enemy steps will be.
namespace AethelnOathscarActiveTests
{
	using namespace AethelnChainTests;
	using EResult = EAethelnActivationResult;
	using EOutcome = EAethelnCombatResultOutcome;

	/** A target dummy 60 units ahead (as in #60's A26 and A27 rows). */
	constexpr double ContactOffset60 = 0.125 + 0.125 * 16.0 / 30.0;

	const FGameplayTag StrikeId = AethelnGameplayTags::Ability_Oathscar_InstantStrike;

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
	TAbility* FindInstance(const UAethelnAbilitySystemComponent& AbilitySystem)
	{
		const FGameplayAbilitySpec* Spec = AbilitySystem.FindAbilitySpecFromClass(TAbility::StaticClass());
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

	TArray<TSubclassOf<UGameplayAbility>> Strike()
	{
		return { UAethelnInstantStrikeTestAbility::StaticClass() };
	}
}

// K1. Red-first: at the identity-only stub the invalid definitions below are still grantable.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnInstantStrikeDefinitionTest,
	"Aetheln.GameCombat.OathscarActives.InstantStrikeDefinition",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnInstantStrikeDefinitionTest::RunTest(const FString& Parameters)
{
	using namespace AethelnOathscarActiveTests;
	const FGameplayTag Chain = AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain;
	TestTrue(TEXT("The fixture definition is grantable"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(UAethelnInstantStrikeTestAbility::StaticClass(), 1)));
	AddExpectedError(TEXT("Refused to grant ability"), EAutomationExpectedErrorFlags::Contains, 1);
	TestFalse(TEXT("Unset production values refuse the grant"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(UAethelnInstantStrikeAbility::StaticClass(), 1)));

	const UAethelnInstantStrikeTestAbility* Defaults = GetDefault<UAethelnInstantStrikeTestAbility>();
	TestEqual(TEXT("Instant Strike is a single step"), Defaults->GetStepCount(), 1);
	TestEqual(TEXT("It holds its own commitment tag"), Defaults->GetCommitmentTag(), AethelnGameplayTags::State_Oathscar_InstantStrike.GetTag());
	TestEqual(TEXT("The three-hit chain keeps three steps"), GetDefault<UAethelnChainTestAbility>()->GetStepCount(), 3);
	TestEqual(TEXT("The three-hit chain keeps its commitment tag"), GetDefault<UAethelnChainTestAbility>()->GetCommitmentTag(), Chain);
	// Owner, 2026-10-13: refused inside the chain's commitment window (as dodge and block). The inherited grant rule
	// makes each blocking tag a reset tag. Q17 and Q10: no attack while dodging or blocking.
	for (const FGameplayTag Tag : { Chain, AethelnGameplayTags::State_Dodging.GetTag(), AethelnGameplayTags::State_Blocking.GetTag(), AethelnGameplayTags::State_Dead.GetTag() })
	{
		TestTrue(FString::Printf(TEXT("Blocked while %s"), *Tag.ToString()), Defaults->GetBlockedTagsForTests().HasTagExact(Tag));
		TestTrue(FString::Printf(TEXT("Resets on %s"), *Tag.ToString()), Defaults->ResetTags.HasTagExact(Tag));
	}
	TestFalse(TEXT("It does not block itself"), Defaults->GetBlockedTagsForTests().HasTagExact(AethelnGameplayTags::State_Oathscar_InstantStrike));

	const TArray<TFunction<void(UAethelnInstantStrikeTestAbility&)>> Mutations = {
		[](auto& A) { A.ProvisionalSteps.Reset(); },
		[](auto& A) { const FAethelnAttackStepDefinition Copy = A.ProvisionalSteps[0]; A.ProvisionalSteps.Add(Copy); },
		[](auto& A) { A.ProvisionalSteps[0].BufferOpen = 0.375; }, // a single step is the final step: BufferOpen == RecoveryEnd
		[](auto& A) { A.ProvisionalSteps[0].LinkOpen = 0.625; A.ProvisionalSteps[0].LinkClose = 0.75; },
		[](auto& A) { A.ProvisionalSteps[0].GuardPressure = 1.0f; }, // owner: pure damage, no Guard pressure
		[](auto& A) { A.ProvisionalSteps[0].GuardPressure = -1.0f; },
		[](auto& A) { A.ProvisionalSteps[0].bInterruptsTarget = true; }, // owner: no interruption
		[](auto& A) { A.ProvisionalMaxSampleDistance = 0.0; },
		[](auto& A) { A.ProvisionalCooldownSeconds = 0.0f; }, // owner: the strike has a cooldown
		[](auto& A) { A.ProvisionalCooldownSeconds = -1.0f; },
		[](auto& A) { A.ProvisionalCooldownSeconds = std::numeric_limits<float>::quiet_NaN(); },
		[](auto& A) { A.bAcceptsRelease = true; },
		[](auto& A) { A.ContentVersion = 0; },
		[](auto& A) { A.ResetTags.Reset(); },
		[](auto& A) { A.ResetTags.RemoveTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain); }, // blocking tag without a reset event
		[](auto& A) { FGameplayTagContainer Tags = A.GetBlockedTagsForTests(); Tags.RemoveTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain); A.SetBlockedTagsForTests(Tags); },
		[](auto& A) { FGameplayTagContainer Tags = A.GetBlockedTagsForTests(); Tags.AddTag(AethelnGameplayTags::State_Oathscar_InstantStrike); A.SetBlockedTagsForTests(Tags); }, // self-blocking
	};
	for (int32 Index = 0; Index < Mutations.Num(); ++Index)
	{
		UAethelnInstantStrikeTestAbility* Definition = NewObject<UAethelnInstantStrikeTestAbility>();
		Mutations[Index](*Definition);
		AddExpectedError(TEXT("Refused to grant ability"), EAutomationExpectedErrorFlags::Contains, 1);
		TestFalse(FString::Printf(TEXT("Invalid value %d refuses at grant"), Index), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Definition)));
	}
	UAethelnInstantStrikeTestAbility* LongCooldown = NewObject<UAethelnInstantStrikeTestAbility>();
	LongCooldown->ProvisionalCooldownSeconds = 30.0f;
	TestTrue(TEXT("A positive cooldown is accepted"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(LongCooldown)));
	UAethelnChainTestAbility* ChainWithCooldown = NewObject<UAethelnChainTestAbility>();
	ChainWithCooldown->ProvisionalCooldownSeconds = 1.0f;
	AddExpectedError(TEXT("Refused to grant ability"), EAutomationExpectedErrorFlags::Contains, 1);
	TestFalse(TEXT("The three-step chain still refuses a cooldown"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(ChainWithCooldown)));
	return true;
}

// K2.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnInstantStrikeContactTest,
	"Aetheln.GameCombat.OathscarActives.InstantStrikeContact",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnInstantStrikeContactTest::RunTest(const FString& Parameters)
{
	using namespace AethelnOathscarActiveTests;
	const FGameplayTag Commitment = AethelnGameplayTags::State_Oathscar_InstantStrike;
	{
		FFixture F; if (!F.Init(*this, Strike())) { return false; }
		UAethelnAbilitySystemComponent& ASC = *F.Player.AbilitySystem;
		AAethelnCombatAICharacter* Target = F.SpawnTarget(*this, FVector(60.0, 0.0, 0.0));
		if (Target == nullptr) { return false; }

		TestEqual(TEXT("Accepted"), Submit(F, StrikeId), EResult::Accepted);
		if (!TestEqual(TEXT("One record"), F.Records.Num(), 1)) { return false; }
		TestEqual(TEXT("The record names the strike"), F.Records[0].AbilityId, StrikeId);
		TestEqual(TEXT("Its single step"), F.Records[0].ChainStep, uint8(1));
		TestEqual(TEXT("Starts at server receipt (hits on press)"), F.Records[0].StartServerTime, 0.0);
		TestEqual(TEXT("Its authored recovery"), F.Records[0].Windows.RecoveryEnd, 0.625);
		TestEqual(TEXT("Cost spent once"), F.CostApplications, 1);
		TestTrue(TEXT("Holds its own commitment"), ASC.HasMatchingGameplayTag(Commitment));
		TestFalse(TEXT("Never the chain's commitment"), ASC.HasMatchingGameplayTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain));
		TestEqual(TEXT("An early press is refused by the running activation"), Submit(F, StrikeId), EResult::ActivationBlocked);
		TestEqual(TEXT("The early press spends nothing"), F.CostApplications, 1);

		F.AdvanceTo(0.5);
		if (TestEqual(TEXT("One result"), F.Results.Num(), 1))
		{
			TestEqual(TEXT("The result names the strike"), F.Results[0].AbilityId, StrikeId);
			TestEqual(TEXT("A server hit"), F.Results[0].Outcome, EOutcome::Hit);
			TestEqual(TEXT("Of this activation"), F.Results[0].ActivationId, F.Records[0].ActivationId);
			TestNearlyEqual(TEXT("At the authored contact time"), F.Results[0].ContactTime, ContactOffset60, 1.0e-3);
		}
		TestEqual(TEXT("One Wrought result through the damage effect: the authored magnitude"), Health(*Target->GetAethelnAbilitySystemComponent()), 35.0f);
		TestFalse(TEXT("The commitment ends at CancelOpen"), ASC.HasMatchingGameplayTag(Commitment));
		TestTrue(TEXT("The activation lasts until RecoveryEnd"), IsActive(ASC, UAethelnInstantStrikeTestAbility::StaticClass()));
		TestEqual(TEXT("No end before RecoveryEnd"), F.Ends.Num(), 0);

		F.AdvanceTo(0.625);
		if (TestEqual(TEXT("One end"), F.Ends.Num(), 1))
		{
			TestEqual(TEXT("Completed at RecoveryEnd"), F.Ends[0].Reason, EAethelnChainEndReason::Completed);
			TestEqual(TEXT("The end names the activation"), F.Ends[0].ActivationId, F.Records[0].ActivationId);
		}
		TestFalse(TEXT("The activation ended"), IsActive(ASC, UAethelnInstantStrikeTestAbility::StaticClass()));
		TestEqual(TEXT("The cooldown refuses the next press"), Submit(F, StrikeId), EResult::OnCooldown);
		TestEqual(TEXT("The cooldown rejection spends nothing"), F.CostApplications, 1);
		ASC.RemoveActiveEffectsWithGrantedTags(FGameplayTagContainer(AethelnGameplayTags::Cooldown_Oathscar_InstantStrike));
		TestEqual(TEXT("Accepted after the cooldown"), Submit(F, StrikeId), EResult::Accepted);
		F.AdvanceTo(1.25);
		TestEqual(TEXT("A second activation hits again, once"), F.Results.Num(), 2);
		TestEqual(TEXT("Two activations, two hits"), Health(*Target->GetAethelnAbilitySystemComponent()), 30.0f);
	}
	{
		// A defending target: the contact is Blocked, the hook sees no Guard pressure, nothing is lost.
		int32 HookCalls = 0;
		float Pressure = -1.0f;
		FGameplayTag HookAbility;
		FFixture F; if (!F.Init(*this, Strike())) { return false; }
		AAethelnCombatAICharacter* Target = F.SpawnTarget(*this, FVector(60.0, 0.0, 0.0));
		if (Target == nullptr) { return false; }
		Target->SetActorRotation(FRotator(0.0, 180.0, 0.0)); // facing the attacker
		const float GuardBefore = Target->GetAethelnAbilitySystemComponent()->GetNumericAttribute(UAethelnCombatAttributeSet::GetGuardAttribute());
		FAethelnDefenseState Slot;
		Slot.StateTag = AethelnCombatTestTags::Test_Defending;
		Slot.ArcDegrees = 180.0;
		Slot.OnBlocked.BindLambda([&](const FAethelnBlockedContact& Contact)
		{
			++HookCalls; Pressure = Contact.GuardPressure; HookAbility = Contact.AbilityId;
			return EAethelnBlockConsequence::Blocked;
		});
		TestTrue(TEXT("The test defense slot registers"), F.Timeline->SetDefenseState(*Target->GetAethelnAbilitySystemComponent(), Slot));
		TestEqual(TEXT("Accepted"), Submit(F, StrikeId), EResult::Accepted);
		F.AdvanceTo(0.5);
		if (TestEqual(TEXT("One result"), F.Results.Num(), 1)) { TestEqual(TEXT("Blocked"), F.Results[0].Outcome, EOutcome::Blocked); }
		TestEqual(TEXT("The hook runs once"), HookCalls, 1);
		TestEqual(TEXT("With no Guard pressure (owner: pure damage)"), Pressure, 0.0f);
		TestEqual(TEXT("For the strike"), HookAbility, StrikeId);
		TestEqual(TEXT("A blocked contact deals no damage"), Health(*Target->GetAethelnAbilitySystemComponent()), 40.0f);
		TestEqual(TEXT("A blocked contact costs no Guard"), Target->GetAethelnAbilitySystemComponent()->GetNumericAttribute(UAethelnCombatAttributeSet::GetGuardAttribute()), GuardBefore);
		F.Timeline->ClearDefenseState(*Target->GetAethelnAbilitySystemComponent());
	}
	{
		// Nothing is interrupted: an enemy's interruptible step is struck first, and its later contact on the player still lands.
		FFixture F; if (!F.Init(*this, Strike())) { return false; }
		AAethelnCombatAICharacter* Enemy = SpawnEnemy(*this, F, FVector(60.0, 0.0, 0.0));
		if (Enemy == nullptr) { return false; }
		TestEqual(TEXT("Accepted"), Submit(F, StrikeId), EResult::Accepted); // contact on the enemy at 0.1917
		F.AdvanceTo(0.0625);
		// Contact on the player's radius-42 capsule at 0.0625 + 0.125 + 0.125 * 8 / 30 = 0.2208, after the strike's.
		const FGuid EnemyId = Swing(F, *Enemy, [](FAethelnAttackStepDefinition& Step) { Step.InterruptibleUntil = 0.5; });
		TestTrue(TEXT("The enemy step registers"), EnemyId.IsValid());
		F.AdvanceTo(0.5);
		const FAethelnCombatResult* StrikeResult = F.Records.Num() == 1 ? ResultFor(F, F.Records[0].ActivationId) : nullptr;
		if (TestNotNull(TEXT("The strike hits the enemy"), StrikeResult)) { TestEqual(TEXT("An ordinary hit"), StrikeResult->Outcome, EOutcome::Hit); }
		TestNotNull(TEXT("The enemy's later contact is not dropped"), ResultFor(F, EnemyId));
		TestEqual(TEXT("The player takes the enemy's hit"), Health(*F.Player.AbilitySystem), 35.0f);
		TestEqual(TEXT("The enemy was struck"), Health(*Enemy->GetAethelnAbilitySystemComponent()), 35.0f);
	}
	return true;
}

// K3 (the relations that need #18's dodge and block).
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnInstantStrikeRelationsTest,
	"Aetheln.GameCombat.OathscarActives.InstantStrikeRelations",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnInstantStrikeRelationsTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDefenseTests;
	const TArray<TSubclassOf<UGameplayAbility>> Abilities = { UAethelnInstantStrikeTestAbility::StaticClass(), UAethelnBlockTestAbility::StaticClass(),
		UAethelnDodgeTestAbility::StaticClass(), UAethelnChainTestAbility::StaticClass() };
	const FGameplayTag Commitment = AethelnGameplayTags::State_Oathscar_InstantStrike;
	const FGameplayTag ChainCommitment = AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain;
	const auto Strike = [](FDefense& F) { return F.Deliver(F.Request(AethelnGameplayTags::Ability_Oathscar_InstantStrike)); };
	const auto StrikeActive = [](const FDefense& F)
	{
		const FGameplayAbilitySpec* Spec = F.ASC().FindAbilitySpecFromClass(UAethelnInstantStrikeTestAbility::StaticClass());
		return Spec != nullptr && Spec->IsActive();
	};
	{
		// OnCooldown spends nothing; State.Dead refuses.
		FDefense F; if (!F.Init(*this, Abilities)) { return false; }
		F.AdvanceTo(1.0);
		TestEqual(TEXT("Accepted"), Strike(F), EResult::Accepted);
		F.AdvanceTo(1.625); // past the strike's RecoveryEnd, inside its cooldown
		const int32 Spent = F.CostApplications;
		TestEqual(TEXT("OnCooldown"), Strike(F), EResult::OnCooldown);
		TestEqual(TEXT("The cooldown rejection spends nothing"), F.CostApplications, Spent);
		F.ASC().RemoveActiveEffectsWithGrantedTags(FGameplayTagContainer(AethelnGameplayTags::Cooldown_Oathscar_InstantStrike));
		F.ASC().AddLooseGameplayTag(AethelnGameplayTags::State_Dead);
		TestEqual(TEXT("State.Dead refuses"), Strike(F), EResult::ActivationBlocked);
		TestEqual(TEXT("State.Dead spends nothing"), F.CostApplications, Spent);
		F.ASC().RemoveLooseGameplayTag(AethelnGameplayTags::State_Dead);
	}
	{
		// Q17: refused while dodging or blocking.
		FDefense F; if (!F.Init(*this, Abilities)) { return false; }
		F.AdvanceTo(1.0);
		TestEqual(TEXT("Dodge accepted"), F.Dodge(), EResult::Accepted);
		TestEqual(TEXT("Refused while dodging"), Strike(F), EResult::ActivationBlocked);
		F.AdvanceTo(2.0); // past the dodge's ActionEnd
		F.ClearCooldowns();
		TestEqual(TEXT("Block raised"), F.Raise(), EResult::Accepted);
		const int32 Spent = F.CostApplications;
		TestEqual(TEXT("Refused while blocking"), Strike(F), EResult::ActivationBlocked);
		TestEqual(TEXT("The refused presses spend nothing"), F.CostApplications, Spent);
	}
	{
		// Owner, 2026-10-13: refused inside the chain's commitment window, accepted after it, resetting the chain.
		FDefense F; if (!F.Init(*this, Abilities)) { return false; }
		F.AdvanceTo(1.0);
		TestEqual(TEXT("The chain's first hit is accepted"), F.Attack(), EResult::Accepted);
		TestTrue(TEXT("The chain holds its commitment"), F.Has(ChainCommitment));
		F.AdvanceTo(1.25);
		const int32 Spent = F.CostApplications;
		TestEqual(TEXT("Refused inside the chain's commitment"), Strike(F), EResult::ActivationBlocked);
		TestEqual(TEXT("Nothing is spent"), F.CostApplications, Spent);
		TestEqual(TEXT("The chain is not ended"), F.ChainEnds.Num(), 0);
		F.AdvanceTo(1.5); // the chain's CancelOpen
		TestFalse(TEXT("The commitment is released"), F.Has(ChainCommitment));
		TestEqual(TEXT("Accepted after the commitment window"), Strike(F), EResult::Accepted);
		if (TestEqual(TEXT("The chain ends once"), F.ChainEnds.Num(), 1)) { TestEqual(TEXT("With OtherAction"), F.ChainEnds[0], EAethelnChainEndReason::OtherAction); }
		TestTrue(TEXT("The strike holds its own commitment"), F.Has(Commitment));
	}
	{
		// Default (open): any action inside the strike's own commitment window is refused; after CancelOpen it is
		// accepted and ends the strike with OtherAction (the existing #60 rule).
		for (int32 Case = 0; Case < 3; ++Case)
		{
			FDefense F; if (!F.Init(*this, Abilities)) { return false; }
			F.AdvanceTo(1.0);
			TestEqual(TEXT("The strike is accepted"), Strike(F), EResult::Accepted);
			TestTrue(TEXT("It holds its commitment"), F.Has(Commitment));
			F.AdvanceTo(1.25);
			const auto Other = [&]() { return Case == 0 ? F.Dodge() : (Case == 1 ? F.Raise() : F.Attack()); };
			const int32 Spent = F.CostApplications;
			TestEqual(TEXT("The other action is refused inside the strike's commitment"), Other(), EResult::ActivationBlocked);
			TestEqual(TEXT("Nothing is spent"), F.CostApplications, Spent);
			TestEqual(TEXT("The strike is not ended"), F.ChainEnds.Num(), 0);
			F.AdvanceTo(1.5);
			TestFalse(TEXT("The commitment is released at CancelOpen"), F.Has(Commitment));
			TestEqual(TEXT("The other action is accepted after the commitment window"), Other(), EResult::Accepted);
			if (TestEqual(TEXT("The strike ends once"), F.ChainEnds.Num(), 1)) { TestEqual(TEXT("With OtherAction"), F.ChainEnds[0], EAethelnChainEndReason::OtherAction); }
			TestFalse(TEXT("Its activation was ended"), StrikeActive(F));
		}
	}
	{
		// Death ends a running strike.
		FDefense F; if (!F.Init(*this, Abilities)) { return false; }
		F.AdvanceTo(1.0);
		TestEqual(TEXT("The strike is accepted"), Strike(F), EResult::Accepted);
		F.AdvanceTo(1.25);
		F.ASC().AddLooseGameplayTag(AethelnGameplayTags::State_Dead);
		if (TestEqual(TEXT("Death ends it once"), F.ChainEnds.Num(), 1)) { TestEqual(TEXT("As an incompatible state"), F.ChainEnds[0], EAethelnChainEndReason::IncompatibleState); }
		TestFalse(TEXT("Its activation was ended"), StrikeActive(F));
		TestFalse(TEXT("Its commitment is gone"), F.Has(Commitment));
		F.ASC().RemoveLooseGameplayTag(AethelnGameplayTags::State_Dead);
	}
	return true;
}

// K4: #60's A25 (request delivery), A26 (contacts), and A27 (teardown) rows replayed against the strike.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnInstantStrikeNetworkConditionsTest,
	"Aetheln.GameCombat.OathscarActives.InstantStrikeNetworkConditions",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnInstantStrikeNetworkConditionsTest::RunTest(const FString& Parameters)
{
	using namespace AethelnOathscarActiveTests;
	// A25 and A26 delivery profiles (fixture arrival times, not a network profile). The server arrival time
	// decides: 0.5 is inside the strike (ActivationBlocked), 0.75 after it and inside its 0.875 cooldown
	// (OnCooldown), 1.0 after both (accepted).
	for (double Arrival : { 0.5, 0.75, 1.0 })
	{
		FFixture F; if (!F.Init(*this, Strike())) { return false; }
		AAethelnCombatAICharacter* Target = F.SpawnTarget(*this, FVector(60.0, 0.0, 0.0));
		if (Target == nullptr) { return false; }
		TestEqual(TEXT("First press accepted"), Submit(F, StrikeId), EResult::Accepted);
		FAethelnCombatActivationRequest Delayed = MakeRequest(F, StrikeId, 10); // explicit gap; client sample 0
		F.AdvanceTo(Arrival);
		// The headless world does not expire duration effects (as in T17), so the cooldown's end is applied by the test.
		if (Arrival >= 0.875) { F.Player.AbilitySystem->RemoveActiveEffectsWithGrantedTags(FGameplayTagContainer(AethelnGameplayTags::Cooldown_Oathscar_InstantStrike)); }
		const EResult Expected = Arrival < 0.625 ? EResult::ActivationBlocked : (Arrival < 0.875 ? EResult::OnCooldown : EResult::Accepted);
		TestEqual(TEXT("Server arrival governs the window, never the client sample"), F.Player.AbilitySystem->ProcessServerRequest(Delayed), Expected);
		TestEqual(TEXT("Duplicate delivery"), F.Player.AbilitySystem->ProcessServerRequest(Delayed), Expected == EResult::Accepted ? EResult::DuplicateSequence : Expected);
		Delayed.Sequence = 9;
		TestEqual(TEXT("Reordered older delivery"), F.Player.AbilitySystem->ProcessServerRequest(Delayed), Expected == EResult::Accepted ? EResult::StaleSequence : Expected);
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
		// A dropped request sends nothing; the next one, a forward gap, is judged by its own arrival.
		F.Player.AbilitySystem->RemoveActiveEffectsWithGrantedTags(FGameplayTagContainer(AethelnGameplayTags::Cooldown_Oathscar_InstantStrike));
		TestEqual(TEXT("Forward sequence gap after a drop"), F.Player.AbilitySystem->ProcessServerRequest(MakeRequest(F, StrikeId, 20)), EResult::Accepted);
	}
	// A25 against the chain's commitment window: a request delayed to arrive inside it is refused, after it accepted.
	for (double Arrival : { 0.25, 0.5, 0.75 })
	{
		FFixture F; if (!F.Init(*this, Strike())) { return false; }
		TestEqual(TEXT("The chain's first hit is accepted"), F.Press(), EResult::Accepted);
		const FAethelnCombatActivationRequest Delayed = MakeRequest(F, StrikeId);
		F.AdvanceTo(Arrival);
		const EResult Expected = Arrival < 0.5 ? EResult::ActivationBlocked : EResult::Accepted;
		TestEqual(TEXT("Server arrival decides against the chain's CancelOpen"), F.Player.AbilitySystem->ProcessServerRequest(Delayed), Expected);
		TestEqual(TEXT("Duplicate delivery"), F.Player.AbilitySystem->ProcessServerRequest(Delayed), Expected == EResult::Accepted ? EResult::DuplicateSequence : EResult::ActivationBlocked);
		TestEqual(TEXT("A refused request spends nothing"), F.CostApplications, 1 + (Expected == EResult::Accepted ? 1 : 0));
	}
	// A27: avatar teardown (Destroy) before the active window, inside it before the contact, or after it: one end, no contact at or after the teardown time.
	// A PlayerState teardown leg is not replayed.
	for (double Time : { 0.0625, 0.15625, 0.25 }) // before the active window, inside it before the contact, after the contact
	{
		FFixture F; if (!F.Init(*this, Strike())) { return false; }
		if (F.SpawnTarget(*this, FVector(60.0, 0.0, 0.0)) == nullptr) { return false; }
		TestEqual(TEXT("Accepted"), Submit(F, StrikeId), EResult::Accepted);
		F.AdvanceTo(Time);
		F.Pawn->Destroy();
		if (TestEqual(TEXT("Teardown sends one end"), F.Ends.Num(), 1)) { TestEqual(TEXT("AvatarLost"), F.Ends[0].Reason, EAethelnChainEndReason::AvatarLost); }
		F.AdvanceTo(1.0);
		TestEqual(TEXT("No contact at or after the teardown time"), F.Results.Num(), Time > ContactOffset60 ? 1 : 0);
		TestEqual(TEXT("No subsystem step leaks"), F.Timeline->GetRegisteredStepCountForTests(), 0);
	}
	return true;
}

// K13: identity, version, policies, state tags and ini of every active, and that the superseded skeletons are gone.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnOathscarDefinitionsAndTagsTest,
	"Aetheln.GameCombat.OathscarActives.DefinitionsAndTags",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnOathscarDefinitionsAndTagsTest::RunTest(const FString& Parameters)
{
	struct FActive
	{
		UClass* Class;
		FGameplayTag Id;
		/** Invalid for the stances, which have no cooldown tag. */
		FGameplayTag CooldownTag;
		const TCHAR* SemanticId;
		bool bReleases;
	};
	const TArray<FActive> Actives = {
		{ UAethelnInstantStrikeAbility::StaticClass(), AethelnGameplayTags::Ability_Oathscar_InstantStrike, AethelnGameplayTags::Cooldown_Oathscar_InstantStrike, TEXT("order.oathscar.ability.instant_strike"), false },
		{ UAethelnParryAbility::StaticClass(), AethelnGameplayTags::Ability_Oathscar_Parry, AethelnGameplayTags::Cooldown_Oathscar_Parry, TEXT("order.oathscar.ability.parry"), false },
	};
	TSet<FGameplayTag> Ids;
	TSet<FGameplayTag> Cooldowns;
	const TArray<TSubclassOf<UGameplayAbility>>& Configured = GetDefault<AAethelnPlayerState>()->GrantedAbilities;
	for (const FActive& Active : Actives)
	{
		const FString Name = Active.Id.ToString();
		const UAethelnGameplayAbility* Ability = Active.Class->GetDefaultObject<UAethelnGameplayAbility>();
		TestEqual(Name + TEXT(": identity"), Ability->GetAbilityId(), Active.Id);
		TestTrue(Name + TEXT(": a valid Ability. tag"), UAethelnGameplayAbility::IsAbilityIdentityTag(Ability->GetAbilityId()));
		TestFalse(Name + TEXT(": a unique identity"), Ids.Contains(Active.Id));
		Ids.Add(Active.Id);
		int32 IniContentVersion = 0;
		TestTrue(Name + TEXT(": DefaultGame.ini sets ContentVersion"), GConfig->GetInt(*Active.Class->GetPathName(), TEXT("ContentVersion"), IniContentVersion, GGameIni));
		TestEqual(Name + TEXT(": version 1, a new identity"), static_cast<int64>(Ability->ContentVersion), static_cast<int64>(1));
		TestEqual(Name + TEXT(": the class default loaded the ini ContentVersion"), static_cast<int64>(Ability->ContentVersion), static_cast<int64>(IniContentVersion));
		TestTrue(Name + TEXT(": InstancedPerActor"), Ability->GetInstancingPolicy() == EGameplayAbilityInstancingPolicy::InstancedPerActor);
		TestTrue(Name + TEXT(": ServerOnly execution, nothing predicted"), Ability->GetNetExecutionPolicy() == EGameplayAbilityNetExecutionPolicy::ServerOnly);
		TestTrue(Name + TEXT(": ServerOnly security"), Ability->GetNetSecurityPolicy() == EGameplayAbilityNetSecurityPolicy::ServerOnly);
		const FGameplayTagContainer* CooldownTags = Ability->GetCooldownTags();
		if (Active.CooldownTag.IsValid())
		{
			TestTrue(Name + TEXT(": exactly its cooldown tag"), CooldownTags != nullptr && CooldownTags->Num() == 1 && CooldownTags->HasTagExact(Active.CooldownTag));
			TestFalse(Name + TEXT(": a unique cooldown tag"), Cooldowns.Contains(Active.CooldownTag));
			Cooldowns.Add(Active.CooldownTag);
		}
		else
		{
			TestTrue(Name + TEXT(": no cooldown tag"), CooldownTags == nullptr || CooldownTags->IsEmpty());
		}
		TestNull(Name + TEXT(": no engine cost effect class"), Ability->GetCostGameplayEffect());
		TestNull(Name + TEXT(": no engine cooldown effect class"), Ability->GetCooldownGameplayEffect());
		TestEqual(Name + TEXT(": bAcceptsRelease"), Ability->bAcceptsRelease, Active.bReleases);
		TestFalse(Name + TEXT(": not granted by config until its values exist"), Configured.ContainsByPredicate([&Active](const TSubclassOf<UGameplayAbility>& Granted) { return Granted.Get() == Active.Class; }));
#if WITH_EDITORONLY_DATA
		const TSharedPtr<FGameplayTagNode> Node = UGameplayTagsManager::Get().FindTagNode(Active.Id);
		TestEqual(Name + TEXT(": the tag maps to its semantic ID"), Node.IsValid() ? Node->GetDevComment() : FString(), FString(Active.SemanticId));
#endif
	}
	// The superseded skeletons (owner, 2026-10-13) are gone: their tags are not declared, their classes do not exist,
	// and their config sections are removed.
	for (const TCHAR* Name : { TEXT("Ability.Oathscar.GateStep"), TEXT("Ability.Oathscar.SwornRebuke"), TEXT("Ability.Oathscar.HoldTheLine"),
		TEXT("Cooldown.Oathscar.GateStep"), TEXT("Cooldown.Oathscar.SwornRebuke"), TEXT("Cooldown.Oathscar.HoldTheLine") })
	{
		TestFalse(FString::Printf(TEXT("%s is not a declared tag"), Name), UGameplayTagsManager::Get().RequestGameplayTag(FName(Name), false).IsValid());
	}
	for (const TCHAR* Name : { TEXT("AethelnGateStepAbility"), TEXT("AethelnSwornRebukeAbility"), TEXT("AethelnHoldTheLineAbility") })
	{
		const FString Path = FString(TEXT("/Script/GameCombat.")) + Name;
		TestNull(FString::Printf(TEXT("%s does not exist"), Name), FindObject<UClass>(nullptr, *Path));
		TestFalse(FString::Printf(TEXT("%s has no config section"), Name), GConfig->DoesSectionExist(*Path, GGameIni));
	}
	return true;
}

#endif
