#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnDefenseTestFixture.h"
#include "AethelnObservability.h"
#include "AethelnObservabilitySubsystem.h"
#include "Misc/AutomationTest.h"
#include <limits>

// #18 P4 block and contact integration (docs/dodge-and-block.md, Test Plan D17 to D25). Every number is a
// test fixture, never tuning; the geometry is described in AethelnDefenseTestFixture.h.
namespace AethelnBlockDefenseTests
{
	using namespace AethelnDefenseTests;

	UAethelnBlockTestAbility* FindBlock(const UAethelnAbilitySystemComponent& AbilitySystem)
	{
		for (const FGameplayAbilitySpec& Spec : AbilitySystem.GetActivatableAbilities())
		{
			if (UAethelnBlockTestAbility* Instance = Cast<UAethelnBlockTestAbility>(Spec.GetPrimaryInstance())) { return Instance; }
		}
		return nullptr;
	}

	FGameplayTagContainer RequiredBlockTags()
	{
		FGameplayTagContainer Tags(AethelnGameplayTags::State_Dead);
		Tags.AddTag(AethelnGameplayTags::State_GuardBroken);
		Tags.AddTag(AethelnGameplayTags::State_Dodging);
		Tags.AddTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain);
		return Tags;
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnBlockDefinitionFailsClosedTest,
	"Aetheln.GameCombat.Defense.BlockDefinitionFailsClosed",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnBlockDefinitionFailsClosedTest::RunTest(const FString& Parameters)
{
	using namespace AethelnBlockDefenseTests;
	constexpr float NaN = std::numeric_limits<float>::quiet_NaN();
	constexpr float Infinity = std::numeric_limits<float>::infinity();
	TestNull(TEXT("The fixture block is valid"), GetDefault<UAethelnBlockTestAbility>()->FindGrantProblem());
	TestTrue(TEXT("The fixture block is grantable through the PlayerState"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(UAethelnBlockTestAbility::StaticClass())));
	for (const TFunction<void(UAethelnBlockTestAbility&)>& Valid : TArray<TFunction<void(UAethelnBlockTestAbility&)>>{
		[](UAethelnBlockTestAbility& B) { B.ProvisionalRaiseSeconds = 0.0f; },
		[](UAethelnBlockTestAbility& B) { B.ProvisionalArcHalfAngleDegrees = 180.0f; },
		[](UAethelnBlockTestAbility& B) { B.ProvisionalGuardBreakSeconds = 0.0f; } })
	{
		UAethelnBlockTestAbility* Definition = NewObject<UAethelnBlockTestAbility>();
		Valid(*Definition);
		TestNull(TEXT("Inclusive boundaries are valid: zero raise, a 180-degree half-angle, zero break"), Definition->FindGrantProblem());
	}
	const TArray<TFunction<void(UAethelnBlockTestAbility&)>> Mutations = {
		[](UAethelnBlockTestAbility& B) { B.ContentVersion = 0; },
		[](UAethelnBlockTestAbility& B) { B.ProvisionalRaiseSeconds = -0.0625f; },
		[NaN](UAethelnBlockTestAbility& B) { B.ProvisionalRaiseSeconds = NaN; },
		[](UAethelnBlockTestAbility& B) { B.ProvisionalArcHalfAngleDegrees = 0.0f; },
		[](UAethelnBlockTestAbility& B) { B.ProvisionalArcHalfAngleDegrees = -45.0f; },
		[](UAethelnBlockTestAbility& B) { B.ProvisionalArcHalfAngleDegrees = 180.5f; },
		[NaN](UAethelnBlockTestAbility& B) { B.ProvisionalArcHalfAngleDegrees = NaN; },
		[](UAethelnBlockTestAbility& B) { B.ProvisionalGuardBreakSeconds = -0.5f; },
		[Infinity](UAethelnBlockTestAbility& B) { B.ProvisionalGuardBreakSeconds = Infinity; },
		[](UAethelnBlockTestAbility& B) { B.ProvisionalEnduranceCost = -1.0f; },
		[NaN](UAethelnBlockTestAbility& B) { B.ProvisionalCooldownSeconds = NaN; },
		[](UAethelnBlockTestAbility& B) { B.bAcceptsRelease = false; },
		[](UAethelnBlockTestAbility& B) { B.SetMovementCarriedForTests(true); },
	};
	for (const auto& Mutate : Mutations)
	{
		UAethelnBlockTestAbility* Definition = NewObject<UAethelnBlockTestAbility>();
		Mutate(*Definition);
		AddExpectedError(TEXT("Refused to grant ability"), EAutomationExpectedErrorFlags::Contains, 1);
		TestFalse(TEXT("Each invalid value refuses at grant"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Definition)));
	}
	for (const FGameplayTag Missing : RequiredBlockTags())
	{
		UAethelnBlockTestAbility* Definition = NewObject<UAethelnBlockTestAbility>();
		FGameplayTagContainer Tags = RequiredBlockTags();
		Tags.RemoveTag(Missing);
		Definition->SetBlockedTagsForTests(Tags);
		AddExpectedError(TEXT("Refused to grant ability"), EAutomationExpectedErrorFlags::Contains, 1);
		TestFalse(FString::Printf(TEXT("A block without blocking tag %s refuses at grant"), *Missing.ToString()), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Definition)));
	}
	AddExpectedError(TEXT("Refused to grant ability"), EAutomationExpectedErrorFlags::Contains, 1);
	TestFalse(TEXT("The unset production block has no usable grant"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(UAethelnBlockAbility::StaticClass())));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnBlockHoldAndReleaseTest,
	"Aetheln.GameCombat.Defense.BlockHoldAndRelease",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnBlockHoldAndReleaseTest::RunTest(const FString& Parameters)
{
	using namespace AethelnBlockDefenseTests;
	FDefense F;
	if (!F.Init(*this)) { return false; }
	UAethelnBlockTestAbility* Block = FindBlock(F.ASC());
	if (!TestNotNull(TEXT("Block instance"), Block)) { return false; }
	F.AdvanceTo(1.0);
	TestEqual(TEXT("Press raises the block"), F.Raise(), EResult::Accepted);
	if (!TestNotNull(TEXT("The press registers the defense slot"), F.Slot())) { return false; }
	TestEqual(TEXT("The slot starts at S + RaiseSeconds"), F.Slot()->ActiveFromServerTime, 1.0625);
	TestEqual(TEXT("The slot is held with no end"), F.Slot()->ActiveUntilServerTime, TNumericLimits<double>::Max());
	TestEqual(TEXT("The slot carries the full arc"), F.Slot()->ArcDegrees, 180.0);
	TestTrue(TEXT("State.Blocking is held for gating and observers"), F.Has(AethelnGameplayTags::State_Blocking));
	TestTrue(TEXT("The block stays active"), Block->IsActive());
	TestEqual(TEXT("One cost"), F.CostApplications, 1);
	TestEqual(TEXT("One cooldown"), F.CooldownApplications, 1);

	TestEqual(TEXT("A Press while active is blocked"), F.Raise(), EResult::ActivationBlocked);
	TestEqual(TEXT("It spends nothing"), F.CostApplications, 1);
	TestEqual(TEXT("It changes no slot"), F.Slot()->ActiveFromServerTime, 1.0625);

	F.AdvanceTo(1.25);
	const FAethelnCombatActivationRequest Release = F.Request(AethelnGameplayTags::Ability_Block, EAethelnActivationPhase::Release);
	TestEqual(TEXT("Release is accepted"), F.Deliver(Release), EResult::Accepted);
	TestEqual(TEXT("Release ends the slot at the stamped time"), F.Slot()->ActiveUntilServerTime, 1.25);
	TestFalse(TEXT("Release ends the activation"), Block->IsActive());
	TestFalse(TEXT("Release removes State.Blocking"), F.Has(AethelnGameplayTags::State_Blocking));
	TestEqual(TEXT("A replayed Release gets a sequence reason"), F.Deliver(Release), EResult::DuplicateSequence);
	TestEqual(TEXT("A Release while lowered is blocked"), F.Lower(), EResult::ActivationBlocked);
	TestEqual(TEXT("Releases spend nothing"), F.CostApplications + F.CooldownApplications, 2);
	TestEqual(TEXT("A later Release leaves the stamped end"), F.Slot()->ActiveUntilServerTime, 1.25);

	// Q8: with no Guard left, a Press is InsufficientResource and spends nothing.
	F.ClearCooldowns();
	AethelnCombatTests::ApplyInstantModifier(F.ASC(), UAethelnCombatAttributeSet::GetGuardAttribute(), EGameplayModOp::Override, 0.0f);
	TestEqual(TEXT("Zero Guard refuses the Press"), F.Raise(), EResult::InsufficientResource);
	TestEqual(TEXT("No spend on the refusal"), F.CostApplications, 1);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnBlockArcAndBoundariesTest,
	"Aetheln.GameCombat.Defense.BlockArcAndBoundaries",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnBlockArcAndBoundariesTest::RunTest(const FString& Parameters)
{
	using namespace AethelnBlockDefenseTests;
	using AethelnAttackTimeline::IsInsideDefenseArc;
	const FVector Center = FVector::ZeroVector;
	// The pure evaluator. 180 degrees of full arc is a 90-degree half-angle; acos(0) is exactly 90 degrees.
	TestTrue(TEXT("Inside exactly at the half-angle"), IsInsideDefenseArc(0.0, Center, FVector(0.0, 100.0, 0.0), 180.0));
	TestFalse(TEXT("Outside just beyond it"), IsInsideDefenseArc(0.0, Center, FVector(-1.0, 100.0, 0.0), 180.0));
	TestTrue(TEXT("Straight ahead is inside"), IsInsideDefenseArc(0.0, Center, FVector(100.0, 0.0, 50.0), 1.0));
	TestFalse(TEXT("A zero-length direction is outside"), IsInsideDefenseArc(0.0, Center, Center, 360.0));
	TestFalse(TEXT("A vertical-only direction has no horizontal part and is outside"), IsInsideDefenseArc(0.0, Center, FVector(0.0, 0.0, 100.0), 360.0));
	TestTrue(TEXT("A full circle covers behind"), IsInsideDefenseArc(0.0, Center, FVector(-100.0, 0.0, 0.0), 360.0));
	TestFalse(TEXT("A zero arc defends nothing"), IsInsideDefenseArc(0.0, Center, FVector(100.0, 0.0, 0.0), 0.0));
	TestFalse(TEXT("An arc beyond a full circle defends nothing"), IsInsideDefenseArc(0.0, Center, FVector(100.0, 0.0, 0.0), 361.0));
	TestFalse(TEXT("A non-finite arc defends nothing"), IsInsideDefenseArc(0.0, Center, FVector(100.0, 0.0, 0.0), std::numeric_limits<double>::quiet_NaN()));
	TestFalse(TEXT("The yaw decides: facing away is outside"), IsInsideDefenseArc(180.0, Center, FVector(100.0, 0.0, 0.0), 180.0));

	// Pipeline boundaries: the enemy's contact is exactly E + 0.125; RaiseSeconds is 0.0625.
	const auto RunCase = [this](const TCHAR* What, TFunctionRef<void(FDefense&, AAethelnCombatAICharacter&)> Script, EOutcome Expected)
	{
		FDefense F;
		if (!F.Init(*this)) { return; }
		AAethelnCombatAICharacter* Enemy = F.SpawnEnemy(*this);
		if (Enemy == nullptr) { return; }
		F.AdvanceTo(1.0);
		Script(F, *Enemy);
		F.AdvanceTo(1.375);
		if (TestEqual(FString::Printf(TEXT("%s: one result"), What), F.Results.Num(), 1))
		{
			TestEqual(FString::Printf(TEXT("%s: outcome"), What), F.Results[0].Outcome, Expected);
			TestEqual(FString::Printf(TEXT("%s: contact time"), What), F.Results[0].ContactTime, 1.125);
		}
	};
	RunCase(TEXT("Contact exactly at S + RaiseSeconds is blocked"), [](FDefense& F, AAethelnCombatAICharacter& Enemy)
	{
		F.Swing(Enemy, 5.0f);
		F.AdvanceTo(1.0625);
		F.Raise(); // slot from 1.125
	}, EOutcome::Blocked);
	RunCase(TEXT("Contact before S + RaiseSeconds is a hit"), [](FDefense& F, AAethelnCombatAICharacter& Enemy)
	{
		F.Swing(Enemy, 5.0f);
		F.AdvanceTo(1.09375);
		F.Raise(); // slot from 1.15625
	}, EOutcome::Hit);
	RunCase(TEXT("Contact at the release time is a hit"), [](FDefense& F, AAethelnCombatAICharacter& Enemy)
	{
		F.Raise();
		F.Swing(Enemy, 5.0f);
		F.AdvanceTo(1.125);
		F.Lower(); // slot until 1.125, exclusive
	}, EOutcome::Hit);
	RunCase(TEXT("The actor yaw counts, not the control rotation (facing, control away)"), [this](FDefense& F, AAethelnCombatAICharacter& Enemy)
	{
		F.Player.Controller->SetControlRotation(FRotator(0.0, 180.0, 0.0));
		F.Raise();
		F.Swing(Enemy, 5.0f);
		TestEqual(TEXT("The defender still faces the enemy"), F.Pawn->GetActorRotation().Yaw, 0.0);
	}, EOutcome::Blocked);
	RunCase(TEXT("The actor yaw counts, not the control rotation (away, control facing)"), [this](FDefense& F, AAethelnCombatAICharacter& Enemy)
	{
		F.Pawn->SetActorRotation(FRotator(0.0, 180.0, 0.0));
		F.Player.Controller->SetControlRotation(FRotator::ZeroRotator);
		F.Raise();
		F.Swing(Enemy, 5.0f);
		TestEqual(TEXT("The defender faces away"), F.Pawn->GetActorRotation().Yaw, 180.0);
	}, EOutcome::Hit);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnBlockedContactCallsGuardHookOnceTest,
	"Aetheln.GameCombat.Defense.BlockedContactCallsGuardHookOnce",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnBlockedContactCallsGuardHookOnceTest::RunTest(const FString& Parameters)
{
	using namespace AethelnBlockDefenseTests;
	for (const bool bFacingEnemy : { true, false })
	{
		FDefense F;
		if (!F.Init(*this)) { return false; }
		AAethelnCombatAICharacter* Enemy = F.SpawnEnemy(*this);
		if (Enemy == nullptr) { return false; }
		F.Pawn->SetActorRotation(FRotator(0.0, bFacingEnemy ? 0.0 : 180.0, 0.0));
		F.AdvanceTo(1.0);
		TestEqual(TEXT("Raised"), F.Raise(), EResult::Accepted);
		F.AdvanceTo(1.0625);
		F.Swing(*Enemy, 5.0f);
		// The defender stays inside the swept shape across several sub-sweeps and frames: duplicated candidates
		// of one activation, arriving in later frames, converge on the one recorded result.
		for (const double Time : { 1.1875, 1.2, 1.21875, 1.25, 1.5 }) { F.AdvanceTo(Time); }
		TestTrue(TEXT("Several sweeps ran"), F.Timeline->GetSweepCountForTests() > 3);
		if (TestEqual(TEXT("One result for the activation"), F.Results.Num(), 1))
		{
			TestEqual(TEXT("Facing the enemy blocks; facing away is an ordinary hit"), F.Results[0].Outcome, bFacingEnemy ? EOutcome::Blocked : EOutcome::Hit);
		}
		TestEqual(TEXT("The Guard hook runs once per blocked contact"), F.PressureApplications, bFacingEnemy ? 1 : 0);
		TestEqual(TEXT("Guard is lowered once by the step's pressure"), F.Guard(), bFacingEnemy ? 15.0f : 20.0f);
		TestEqual(TEXT("A blocked hit deals no Health damage (Q6)"), F.Health(), bFacingEnemy ? 40.0f : 35.0f);
		TestEqual(TEXT("The block holds after a blocked hit"), F.Has(AethelnGameplayTags::State_Blocking), true);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnGuardBreakTest,
	"Aetheln.GameCombat.Defense.GuardBreak",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnGuardBreakTest::RunTest(const FString& Parameters)
{
	using namespace AethelnBlockDefenseTests;
	FDefense F;
	if (!F.Init(*this)) { return false; }
	AAethelnCombatAICharacter* First = F.SpawnEnemy(*this);
	AAethelnCombatAICharacter* Second = F.SpawnEnemy(*this);
	UAethelnBlockTestAbility* Block = FindBlock(F.ASC());
	if (First == nullptr || Second == nullptr || !TestNotNull(TEXT("Block instance"), Block)) { return false; }
	F.AdvanceTo(1.0);
	TestEqual(TEXT("Raised"), F.Raise(), EResult::Accepted);
	F.AdvanceTo(1.0625);
	// Both contacts are at 1.1875; the first registered sorts first in the total order.
	const FGuid Breaking = F.Swing(*First, 20.0f); // at Guard (20): the break
	const FGuid Later = F.Swing(*Second, 5.0f);
	F.AdvanceTo(1.25);
	const FAethelnCombatResult* BreakResult = F.ResultFor(Breaking);
	const FAethelnCombatResult* LaterResult = F.ResultFor(Later);
	if (!TestNotNull(TEXT("Breaking contact resolved"), BreakResult) || !TestNotNull(TEXT("Same-time contact resolved"), LaterResult)) { return false; }
	TestEqual(TEXT("Same contact time"), LaterResult->ContactTime, BreakResult->ContactTime);
	TestEqual(TEXT("The breaking contact is still blocked and records GuardBroken"), BreakResult->Outcome, EOutcome::GuardBroken);
	TestEqual(TEXT("Guard is zero"), F.Guard(), 0.0f);
	TestEqual(TEXT("The hook ran once"), F.PressureApplications, 1);
	TestEqual(TEXT("The block ends at the contact time"), F.Slot()->ActiveUntilServerTime, BreakResult->ContactTime);
	TestFalse(TEXT("The activation ended"), Block->IsActive());
	TestFalse(TEXT("State.Blocking is gone"), F.Has(AethelnGameplayTags::State_Blocking));
	TestEqual(TEXT("A same-time contact later in the total order is not blocked"), LaterResult->Outcome, EOutcome::Hit);
	TestEqual(TEXT("It damages"), F.Health(), 35.0f);
	TestTrue(TEXT("State.GuardBroken holds"), F.Has(AethelnGameplayTags::State_GuardBroken));

	// Isolate State.GuardBroken: Guard restored and cooldown cleared, the Press is still refused.
	F.ClearCooldowns();
	AethelnCombatTests::ApplyInstantModifier(F.ASC(), UAethelnCombatAttributeSet::GetGuardAttribute(), EGameplayModOp::Override, 20.0f);
	TestEqual(TEXT("A Press during the break is refused"), F.Raise(), EResult::ActivationBlocked);
	// Effect timers tick once per engine frame, not per test World->Tick, so read the authored duration and
	// then remove the effect as its expiry would.
	const TArray<float> Durations = F.ASC().GetActiveEffectsDuration(FGameplayEffectQuery::MakeQuery_MatchAnyOwningTags(FGameplayTagContainer(AethelnGameplayTags::State_GuardBroken)));
	if (TestEqual(TEXT("One Guard-break effect"), Durations.Num(), 1)) { TestEqual(TEXT("The break lasts the test duration"), Durations[0], 0.5f); }
	F.ASC().RemoveActiveEffectsWithGrantedTags(FGameplayTagContainer(AethelnGameplayTags::State_GuardBroken));
	TestFalse(TEXT("The break ends with its effect"), F.Has(AethelnGameplayTags::State_GuardBroken));
	TestEqual(TEXT("The block can be raised again"), F.Raise(), EResult::Accepted);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAvoidanceBeatsContactTest,
	"Aetheln.GameCombat.Defense.AvoidanceBeatsContact",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAvoidanceBeatsContactTest::RunTest(const FString& Parameters)
{
	using namespace AethelnBlockDefenseTests;
	// The fixture dodge's window is [S + 0.0625, S + 0.3125).
	{
		FDefense F;
		if (!F.Init(*this)) { return false; }
		AAethelnCombatAICharacter* Enemy = F.SpawnEnemy(*this);
		if (Enemy == nullptr) { return false; }
		F.AdvanceTo(1.0);
		TestEqual(TEXT("Dodge accepted"), F.Dodge(), EResult::Accepted);
		F.Swing(*Enemy, 5.0f); // contact 1.125, inside the window
		F.AdvanceTo(1.25);
		if (TestEqual(TEXT("One result"), F.Results.Num(), 1)) { TestEqual(TEXT("Inside the window: Avoided"), F.Results[0].Outcome, EOutcome::Avoided); }
		TestEqual(TEXT("No damage"), F.Health(), 40.0f);
		TestEqual(TEXT("No Guard change"), F.Guard(), 20.0f);
		TestEqual(TEXT("No hook call"), F.PressureApplications, 0);
	}
	{
		// At the window end it hits, although State.DodgeInvulnerable is still present when the frame's contacts resolve.
		FDefense F;
		if (!F.Init(*this)) { return false; }
		AAethelnCombatAICharacter* Enemy = F.SpawnEnemy(*this);
		if (Enemy == nullptr) { return false; }
		F.AdvanceTo(1.0);
		F.Dodge();
		F.AdvanceTo(1.1875);
		F.Swing(*Enemy, 5.0f); // contact 1.3125 == S + InvulnerableEnd
		TestTrue(TEXT("The invulnerability tag is present before the frame"), F.Has(AethelnGameplayTags::State_DodgeInvulnerable));
		F.AdvanceTo(1.375); // one frame: contacts resolve before the boundary removes the tag
		if (TestEqual(TEXT("One result"), F.Results.Num(), 1))
		{
			TestEqual(TEXT("Contact time is the window end"), F.Results[0].ContactTime, 1.3125);
			TestEqual(TEXT("At the window end: a hit (time-exact, #18 T2)"), F.Results[0].Outcome, EOutcome::Hit);
		}
		TestEqual(TEXT("It damages"), F.Health(), 35.0f);
	}
	{
		// Requests before contacts: a dodge processed in the contact's frame is stamped with the previous frame's time.
		FDefense F;
		if (!F.Init(*this)) { return false; }
		AAethelnCombatAICharacter* Enemy = F.SpawnEnemy(*this);
		if (Enemy == nullptr) { return false; }
		F.AdvanceTo(1.0);
		F.Swing(*Enemy, 5.0f); // contact 1.125
		F.AdvanceTo(1.0625);
		TestEqual(TEXT("Dodge accepted"), F.Dodge(), EResult::Accepted); // window from 1.125
		F.AdvanceTo(1.25); // the frame (1.0625, 1.25] holds the contact
		if (TestEqual(TEXT("One result"), F.Results.Num(), 1)) { TestEqual(TEXT("Same frame, window start: Avoided"), F.Results[0].Outcome, EOutcome::Avoided); }
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDefenseActionRelationsTest,
	"Aetheln.GameCombat.Defense.ActionRelations",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDefenseActionRelationsTest::RunTest(const FString& Parameters)
{
	using namespace AethelnBlockDefenseTests;
	FDefense F;
	if (!F.Init(*this)) { return false; }
	UAethelnBlockTestAbility* Block = FindBlock(F.ASC());
	if (!TestNotNull(TEXT("Block instance"), Block)) { return false; }

	// An accepted dodge ends a held block at its acceptance time (Q10, Q18).
	F.AdvanceTo(1.0);
	TestEqual(TEXT("Raised"), F.Raise(), EResult::Accepted);
	F.AdvanceTo(1.25);
	TestEqual(TEXT("A held block does not block the dodge"), F.Dodge(), EResult::Accepted);
	TestFalse(TEXT("The dodge ends the block"), Block->IsActive());
	TestEqual(TEXT("At the dodge's acceptance time"), F.Slot()->ActiveUntilServerTime, 1.25);
	TestFalse(TEXT("State.Blocking is gone"), F.Has(AethelnGameplayTags::State_Blocking));
	// Effect timers tick once per engine frame, not per test World->Tick: clear cooldowns to isolate each tag rule.
	F.ClearCooldowns();
	TestEqual(TEXT("A block is refused while State.Dodging holds"), F.Raise(), EResult::ActivationBlocked);
	TestEqual(TEXT("An attack is refused while State.Dodging holds (Q17)"), F.Attack(), EResult::ActivationBlocked);

	// An attack is refused while blocking.
	F.AdvanceTo(1.75);
	F.ClearCooldowns();
	TestEqual(TEXT("Raised after the dodge"), F.Raise(), EResult::Accepted);
	TestEqual(TEXT("An attack while blocking is refused"), F.Attack(), EResult::ActivationBlocked);
	// A second defense slot fails closed.
	FAethelnDefenseState Other;
	Other.ArcDegrees = 360.0;
	TestFalse(TEXT("A second slot fails closed"), F.Timeline->SetDefenseState(F.ASC(), Other));
	TestEqual(TEXT("The block keeps its slot"), F.Slot()->ArcDegrees, 180.0);
	TestEqual(TEXT("Lowered"), F.Lower(), EResult::Accepted);

	// The chain's commitment tag blocks both; their activation after CancelOpen resets the chain (OtherAction).
	F.AdvanceTo(2.0);
	TestEqual(TEXT("Attack step 1"), F.Attack(), EResult::Accepted);
	F.ClearCooldowns();
	TestEqual(TEXT("Commitment blocks the dodge"), F.Dodge(), EResult::ActivationBlocked);
	TestEqual(TEXT("Commitment blocks the block"), F.Raise(), EResult::ActivationBlocked);
	F.AdvanceTo(2.5);
	F.ClearCooldowns();
	TestEqual(TEXT("After CancelOpen the block is accepted"), F.Raise(), EResult::Accepted);
	if (TestTrue(TEXT("The chain ended"), F.ChainEnds.Num() > 0)) { TestEqual(TEXT("A block activation resets the chain"), F.ChainEnds.Last(), EAethelnChainEndReason::OtherAction); }
	TestEqual(TEXT("Lowered"), F.Lower(), EResult::Accepted);
	F.AdvanceTo(3.0);
	const int32 EndsBefore = F.ChainEnds.Num();
	TestEqual(TEXT("Attack step 1 again"), F.Attack(), EResult::Accepted);
	F.AdvanceTo(3.5);
	F.ClearCooldowns();
	TestEqual(TEXT("After CancelOpen the dodge is accepted on the same ASC"), F.Dodge(), EResult::Accepted);
	if (TestEqual(TEXT("One more chain end"), F.ChainEnds.Num(), EndsBefore + 1)) { TestEqual(TEXT("A dodge activation resets the chain"), F.ChainEnds.Last(), EAethelnChainEndReason::OtherAction); }
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnNetworkConditionsBlockTest,
	"Aetheln.GameCombat.Defense.NetworkConditionsBlock",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnNetworkConditionsBlockTest::RunTest(const FString& Parameters)
{
	using namespace AethelnBlockDefenseTests;
	// Requests are built at their client send time and delivered at their server arrival time. The enemy's
	// contact is at 1.125 and RaiseSeconds is 0.0625, so a Press blocks it exactly when it arrives by 1.0625.
	struct FProfile
	{
		const TCHAR* Name;
		double PressArrival;
		EOutcome Expected;
	};
	for (const FProfile& Profile : { FProfile{ TEXT("normal"), 1.0, EOutcome::Blocked },
		FProfile{ TEXT("high latency"), 1.125, EOutcome::Hit },
		FProfile{ TEXT("packet loss, resend arrives at the boundary"), 1.0625, EOutcome::Blocked } })
	{
		FDefense F;
		if (!F.Init(*this)) { return false; }
		AAethelnCombatAICharacter* Enemy = F.SpawnEnemy(*this);
		if (Enemy == nullptr) { return false; }
		F.AdvanceTo(1.0);
		const FAethelnCombatActivationRequest Press = F.Request(AethelnGameplayTags::Ability_Block);
		F.Swing(*Enemy, 5.0f);
		if (Profile.PressArrival > F.Now()) { F.AdvanceTo(Profile.PressArrival); }
		TestEqual(FString::Printf(TEXT("%s: the Press is accepted on arrival"), Profile.Name), F.Deliver(Press), EResult::Accepted);
		TestEqual(FString::Printf(TEXT("%s: a duplicated Press gets a sequence reason"), Profile.Name), F.Deliver(Press), EResult::DuplicateSequence);
		F.AdvanceTo(1.375);
		if (TestEqual(FString::Printf(TEXT("%s: one result"), Profile.Name), F.Results.Num(), 1))
		{
			TestEqual(FString::Printf(TEXT("%s: blocked exactly when the arrival precedes the contact"), Profile.Name), F.Results[0].Outcome, Profile.Expected);
		}
		const FAethelnCombatActivationRequest Release = F.Request(AethelnGameplayTags::Ability_Block, EAethelnActivationPhase::Release);
		TestEqual(FString::Printf(TEXT("%s: Release"), Profile.Name), F.Deliver(Release), EResult::Accepted);
		TestEqual(FString::Printf(TEXT("%s: the reordered older Press is stale"), Profile.Name), F.Deliver(Press), EResult::StaleSequence);
		TestEqual(FString::Printf(TEXT("%s: a duplicated Release gets a sequence reason"), Profile.Name), F.Deliver(Release), EResult::DuplicateSequence);
		TestEqual(FString::Printf(TEXT("%s: the hook never runs twice"), Profile.Name), F.PressureApplications, Profile.Expected == EOutcome::Blocked ? 1 : 0);
	}
	// A delayed Release: the contact stays blocked unless the Release arrives by the contact time.
	for (const double ReleaseArrival : { 1.1875, 1.125 })
	{
		FDefense F;
		if (!F.Init(*this)) { return false; }
		AAethelnCombatAICharacter* Enemy = F.SpawnEnemy(*this);
		if (Enemy == nullptr) { return false; }
		F.AdvanceTo(1.0);
		F.Raise();
		F.Swing(*Enemy, 5.0f);
		F.AdvanceTo(1.0625);
		const FAethelnCombatActivationRequest Release = F.Request(AethelnGameplayTags::Ability_Block, EAethelnActivationPhase::Release);
		F.AdvanceTo(ReleaseArrival);
		TestEqual(TEXT("The delayed Release is accepted"), F.Deliver(Release), EResult::Accepted);
		F.AdvanceTo(1.375);
		if (TestEqual(TEXT("One result"), F.Results.Num(), 1))
		{
			TestEqual(TEXT("Blocked only when the Release arrives after the contact"), F.Results[0].Outcome, ReleaseArrival > 1.125 ? EOutcome::Blocked : EOutcome::Hit);
		}
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDefenseResultTelemetryTest,
	"Aetheln.GameCombat.Defense.DefenseResultTelemetry",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDefenseResultTelemetryTest::RunTest(const FString& Parameters)
{
	using namespace AethelnBlockDefenseTests;
	using ECategory = EAethelnObservabilityCategory;
	FDefense F;
	if (!F.Init(*this)) { return false; }
	AAethelnCombatAICharacter* Enemy = F.SpawnEnemy(*this);
	UAethelnObservabilitySubsystem* Subsystem = F.World.GameInstance != nullptr ? F.World.GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>() : nullptr;
	if (Enemy == nullptr || !TestNotNull(TEXT("Observability subsystem exists"), Subsystem)) { return false; }
	auto Sink = MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(64);
	TestTrue(TEXT("Runtime context is set"), Subsystem->SetRuntimeContext(EAethelnFlowKind::PrototypeAuthority, TEXT("run-block-p4-test"), TEXT("instance-block-p4-test"), TEXT("connection-block-p4-test")));
	TestTrue(TEXT("Public sink is set"), Subsystem->SetTestSink(Sink));

	F.AdvanceTo(1.0);
	F.Dodge();
	const FGuid Avoided = F.Swing(*Enemy, 5.0f, 11); // contact 1.125, inside the window
	F.AdvanceTo(2.0);
	F.Raise(); // slot from 2.0625
	const FGuid Blocked = F.Swing(*Enemy, 5.0f, 12); // contact 2.125: Guard 20 -> 15
	F.AdvanceTo(2.375);
	const FGuid Broken = F.Swing(*Enemy, 20.0f, 13); // contact 2.5: Guard 15 -> 0
	F.AdvanceTo(2.75);
	TestTrue(TEXT("Telemetry drained"), Subsystem->WaitForIdleForTests());

	struct FExpected { FGuid Id; EOutcome Outcome; ECategory Subject; uint64 Sequence; };
	for (const FExpected& Expected : { FExpected{ Avoided, EOutcome::Avoided, ECategory::Dodge, 11 },
		FExpected{ Blocked, EOutcome::Blocked, ECategory::Block, 12 }, FExpected{ Broken, EOutcome::GuardBroken, ECategory::Block, 13 } })
	{
		const FAethelnCombatResult* Result = F.ResultFor(Expected.Id);
		if (TestNotNull(TEXT("Result recorded"), Result)) { TestEqual(TEXT("Outcome"), Result->Outcome, Expected.Outcome); }
		const FString Id = Expected.Id.ToString(EGuidFormats::DigitsWithHyphensLower);
		const TArray<FAethelnObservabilityEvent> Events = Sink->GetEvents().FilterByPredicate([&Id](const FAethelnObservabilityEvent& Event) { return Event.Correlation.ActivationId == Id; });
		if (TestEqual(TEXT("One event per committed result"), Events.Num(), 1))
		{
			TestTrue(TEXT("The table's subject, not Hit"), Events[0].Category == Expected.Subject && Events[0].SubjectCategory == Expected.Subject);
			TestTrue(TEXT("Accepted reason"), Events[0].SafeReason == EAethelnSafeReason::Accepted);
			TestEqual(TEXT("The attack's ability id"), Events[0].Correlation.AbilityId, AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain.GetTag().ToString());
			TestEqual(TEXT("The attack's sequence"), static_cast<int64>(Events[0].Correlation.Sequence), static_cast<int64>(Expected.Sequence));
			TestEqual(TEXT("No connection or target identity"), Events[0].Correlation.ConnectionPseudonym, FString(AethelnObservability::ExcludedIdentifier));
			TestTrue(TEXT("Public channel hides diagnostics"), Events[0].DiagnosticCode == EAethelnDiagnosticCode::None);
		}
	}
	TestFalse(TEXT("No committed result emits a Hit event here"), Sink->GetEvents().ContainsByPredicate([](const FAethelnObservabilityEvent& Event) { return Event.Category == ECategory::Hit; }));
	TestFalse(TEXT("No Guard value is emitted: no Resource sample from a result"), Sink->GetMetrics().ContainsByPredicate([](const FAethelnMetricSample& Metric) { return Metric.Category == ECategory::Resource; }));
	Subsystem->ResetSink();
	Subsystem->ResetRuntimeContext();
	return true;
}

#endif
