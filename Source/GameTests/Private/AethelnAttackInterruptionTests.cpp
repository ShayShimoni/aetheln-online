#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnAbilitySystemComponent.h"
#include "AethelnChainTestFixture.h"
#include "AethelnCombatAICharacter.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnGameplayTags.h"
#include "Misc/AutomationTest.h"

// #60 P5 interruption (docs/attack-timeline-and-combo.md, Interruption; Test Plan A15 with the A28 row).
// Only an enemy can hit a player (OQ1), and only players hold a chain, so the interrupter is an enemy
// dummy whose step is registered directly on the timeline, as #20's enemy steps will be. Fixture
// geometry and windows, not tuning: an enemy 60 units behind the player first touches the player's
// capsule at its step start + 0.125 + 0.125 * 16 / 30; one 40 units behind overlaps at its ActiveStart.
namespace AethelnInterruptionTests
{
	using namespace AethelnChainTests;
	using EResult = EAethelnActivationResult;
	using EOutcome = EAethelnCombatResultOutcome;

	constexpr double ContactOffset60 = 0.125 + 0.125 * 16.0 / 30.0;

	float Health(const UAethelnAbilitySystemComponent& AbilitySystem)
	{
		return AbilitySystem.GetNumericAttribute(UAethelnCombatAttributeSet::GetHealthAttribute());
	}

	void SetInterruptibleUntil(UAethelnChainTestAbility& Ability, double Value)
	{
		for (FAethelnAttackStepDefinition& Step : Ability.ProvisionalSteps) { Step.InterruptibleUntil = Value; }
	}

	/** An enemy dummy with the fixture chain granted, so its directly registered steps pass the content-version check. */
	AAethelnCombatAICharacter* SpawnEnemy(FAutomationTestBase& Test, const FFixture& F, const FVector& Location)
	{
		AAethelnCombatAICharacter* Enemy = F.SpawnTarget(Test, Location);
		if (Enemy != nullptr) { Enemy->GetAethelnAbilitySystemComponent()->GiveAbility(FGameplayAbilitySpec(UAethelnChainTestAbility::StaticClass(), 1)); }
		return Enemy;
	}

	/** Registers one interrupting enemy step starting now, aimed at the player. Returns its activation id. */
	FGuid Swing(const FFixture& F, AAethelnCombatAICharacter& Enemy, TFunctionRef<void(FAethelnAttackStepDefinition&)> Mutate)
	{
		const UAethelnChainTestAbility* Chain = GetDefault<UAethelnChainTestAbility>();
		FAethelnAttackStepDefinition Step = Chain->ProvisionalSteps[0];
		Step.bInterruptsTarget = true;
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
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAttackInterruptionTest,
	"Aetheln.GameCombat.AttackTimeline.Interruption",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAttackInterruptionTest::RunTest(const FString& Parameters)
{
	using namespace AethelnInterruptionTests;
	{
		// Inside InterruptibleUntil: the chain ends Interrupted at the contact time, and only its later contacts drop.
		FFixture F; if (!F.Init(*this)) { return false; }
		SetInterruptibleUntil(*F.Ability, 0.25);
		AAethelnCombatAICharacter* Enemy = SpawnEnemy(*this, F, FVector(-60.0, 0.0, 0.0));
		AAethelnCombatAICharacter* Near = F.SpawnTarget(*this, FVector(40.0, 0.0, 0.0)); // player contact at 0.125
		AAethelnCombatAICharacter* Far = F.SpawnTarget(*this, FVector(70.0, 0.0, 50.0)); // player contact after the interruption
		if (Enemy == nullptr || Near == nullptr || Far == nullptr) { return false; }
		TestEqual(TEXT("Press starts step 1"), F.Press(), EResult::Accepted);
		const FGuid EnemyId = Swing(F, *Enemy, [](FAethelnAttackStepDefinition&) {});
		TestTrue(TEXT("The enemy step registers"), EnemyId.IsValid());
		F.AdvanceTo(0.5);
		const FAethelnCombatResult* Interrupting = ResultFor(F, EnemyId);
		if (!TestNotNull(TEXT("The enemy hits the player"), Interrupting)) { return false; }
		TestEqual(TEXT("An ordinary hit"), Interrupting->Outcome, EOutcome::Hit);
		TestNearlyEqual(TEXT("Its contact time"), Interrupting->ContactTime, ContactOffset60, 1.0e-3);
		if (TestEqual(TEXT("One chain end"), F.Ends.Num(), 1) && F.Records.Num() == 1)
		{
			TestEqual(TEXT("The chain ends Interrupted"), F.Ends[0].Reason, EAethelnChainEndReason::Interrupted);
			TestEqual(TEXT("The end names the interrupted step"), F.Ends[0].ActivationId, F.Records[0].ActivationId);
			TestEqual(TEXT("The record carries the interruptible window"), F.Records[0].Windows.InterruptibleUntil, 0.25);
		}
		TestEqual(TEXT("The reset is stamped at the contact time"), F.Player.AbilitySystem->GetLastChainResetTimeForTests(), Interrupting->ContactTime);
		TestFalse(TEXT("No chain remains"), F.Player.AbilitySystem->GetChainStateForTests().bExists);
		TestEqual(TEXT("The interrupting hit still damages"), Health(*F.Player.AbilitySystem), 35.0f);
		TestEqual(TEXT("The player's earlier contact survives"), Health(*Near->GetAethelnAbilitySystemComponent()), 35.0f);
		TestEqual(TEXT("The player's later contact is dropped"), Health(*Far->GetAethelnAbilitySystemComponent()), 40.0f);
		TestEqual(TEXT("Two results: the earlier player hit and the interrupting hit"), F.Results.Num(), 2);
		TestEqual(TEXT("The next press is accepted"), F.Press(), EResult::Accepted);
		if (TestEqual(TEXT("The next press starts a step"), F.Records.Num(), 2)) { TestEqual(TEXT("It is step 1"), F.Records[1].ChainStep, uint8(1)); }
	}
	// Outside the window, InterruptibleUntil 0 (never), and a step that does not interrupt: the chain continues.
	for (int32 Variant : { 0, 1, 2 })
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		SetInterruptibleUntil(*F.Ability, Variant == 0 ? 0.125 : Variant == 1 ? 0.0 : 0.25);
		AAethelnCombatAICharacter* Enemy = SpawnEnemy(*this, F, FVector(-60.0, 0.0, 0.0));
		AAethelnCombatAICharacter* Far = F.SpawnTarget(*this, FVector(70.0, 0.0, 50.0));
		if (Enemy == nullptr || Far == nullptr) { return false; }
		F.Press();
		const FGuid EnemyId = Swing(F, *Enemy, [Variant](FAethelnAttackStepDefinition& Step) { Step.bInterruptsTarget = Variant != 2; });
		F.AdvanceTo(0.5);
		TestNotNull(TEXT("The enemy hits the player"), ResultFor(F, EnemyId));
		TestEqual(TEXT("No chain end"), F.Ends.Num(), 0);
		TestTrue(TEXT("The chain continues"), F.Player.AbilitySystem->GetChainStateForTests().bExists);
		TestEqual(TEXT("The player's later contact still lands"), Health(*Far->GetAethelnAbilitySystemComponent()), 35.0f);
	}
	// A lethal target and an avoiding target are not interrupted.
	for (bool bLethal : { true, false })
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		SetInterruptibleUntil(*F.Ability, 0.25);
		AAethelnCombatAICharacter* Enemy = SpawnEnemy(*this, F, FVector(-60.0, 0.0, 0.0));
		if (Enemy == nullptr) { return false; }
		if (!bLethal)
		{
			F.Timeline->AvoidanceTags.AddTag(AethelnCombatTestTags::Test_Avoidance);
			F.Player.AbilitySystem->AddLooseGameplayTag(AethelnCombatTestTags::Test_Avoidance);
		}
		F.Press();
		const FGuid EnemyId = Swing(F, *Enemy, [bLethal](FAethelnAttackStepDefinition& Step) { if (bLethal) { Step.WroughtDamage = 40.0f; } });
		F.AdvanceTo(0.5);
		const FAethelnCombatResult* Result = ResultFor(F, EnemyId);
		if (TestNotNull(TEXT("The enemy contact commits a result"), Result))
		{
			TestEqual(TEXT("Lethal hit or avoided contact"), Result->Outcome, bLethal ? EOutcome::Hit : EOutcome::Avoided);
			TestEqual(TEXT("Latched lethal only for the lethal row"), Result->bLethal, bLethal);
		}
		TestEqual(TEXT("No interruption"), F.Ends.Num(), 0);
		TestTrue(TEXT("The chain is not ended by the result"), F.Player.AbilitySystem->GetChainStateForTests().bExists);
	}
	// A28 interruption row: a buffered step starts at S + LinkOpen inside one frame that also holds the contact.
	// ContactBefore: the contact precedes LinkOpen inside step 1's window, so the buffered start is cancelled.
	// NotInterruptible: the same contact outside step 1's window; the buffered step starts normally.
	// AtLinkOpen: the contact lands exactly at LinkOpen, so the started step 2 is interrupted after its record.
	enum class ERow { ContactBefore, NotInterruptible, AtLinkOpen };
	for (ERow Row : { ERow::ContactBefore, ERow::NotInterruptible, ERow::AtLinkOpen })
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		SetInterruptibleUntil(*F.Ability, Row == ERow::NotInterruptible ? 0.375 : 0.5);
		AAethelnCombatAICharacter* Enemy = SpawnEnemy(*this, F, FVector(-40.0, 0.0, 0.0));
		AAethelnCombatAICharacter* Dummy = F.SpawnTarget(*this, FVector(40.0, 0.0, 0.0)); // each player step overlaps it at ActiveStart
		if (Enemy == nullptr || Dummy == nullptr) { return false; }
		TArray<TCHAR> Messages; // R: record, E: chain end, in the order the owner receives them
		const FDelegateHandle RecordOrder = F.Player.AbilitySystem->OnCombatActivation.AddLambda([&Messages](const FAethelnCombatActivationRecord&) { Messages.Add(TEXT('R')); });
		const FDelegateHandle EndOrder = F.Player.AbilitySystem->OnChainEnded.AddLambda([&Messages](const FGuid&, EAethelnChainEndReason) { Messages.Add(TEXT('E')); });
		F.Press(); F.AdvanceTo(0.375);
		TestEqual(TEXT("Step 1 hit the dummy"), Health(*Dummy->GetAethelnAbilitySystemComponent()), 35.0f);
		TestEqual(TEXT("Buffered press"), F.Press(), EResult::Accepted);
		const FGuid BufferedId = F.Player.AbilitySystem->GetChainStateForTests().BufferedInput.ActivationId;
		if (Row == ERow::AtLinkOpen) { F.AdvanceTo(0.4375); }
		// Test-only window: the enemy overlaps the player at its ActiveStart, 0.0625 after it registers.
		const FGuid EnemyId = Swing(F, *Enemy, [](FAethelnAttackStepDefinition& Step) { Step.ActiveStart = 0.0625; });
		F.Results.Reset();
		F.AdvanceTo(0.8); // one frame spanning LinkOpen (0.5), the contact, and step 2's whole active window
		F.Player.AbilitySystem->OnCombatActivation.Remove(RecordOrder);
		F.Player.AbilitySystem->OnChainEnded.Remove(EndOrder);
		const FAethelnCombatResult* Interrupting = ResultFor(F, EnemyId);
		if (!TestNotNull(TEXT("The enemy hits the player"), Interrupting)) { return false; }
		TestEqual(TEXT("Contact time"), Interrupting->ContactTime, Row == ERow::AtLinkOpen ? 0.5 : 0.4375);
		switch (Row)
		{
		case ERow::ContactBefore:
			TestEqual(TEXT("The cancelled start sends no record"), F.Records.Num(), 1);
			if (TestEqual(TEXT("One chain end"), F.Ends.Num(), 1))
			{
				TestEqual(TEXT("Interrupted"), F.Ends[0].Reason, EAethelnChainEndReason::Interrupted);
				TestEqual(TEXT("The chain end reports the buffered activation"), F.Ends[0].ActivationId, BufferedId);
			}
			TestEqual(TEXT("The cancelled start has no contact"), F.Results.Num(), 1);
			TestEqual(TEXT("The dummy takes nothing from the cancelled step"), Health(*Dummy->GetAethelnAbilitySystemComponent()), 35.0f);
			TestEqual(TEXT("The reset is stamped before LinkOpen"), F.Player.AbilitySystem->GetLastChainResetTimeForTests(), 0.4375);
			TestEqual(TEXT("The owner gets the step-1 record, then the end"), FString(Messages.Num(), Messages.GetData()), FString(TEXT("RE")));
			break;
		case ERow::NotInterruptible:
			if (TestEqual(TEXT("The buffered step starts and sends its record"), F.Records.Num(), 2))
			{
				TestEqual(TEXT("At LinkOpen"), F.Records[1].StartServerTime, 0.5);
				TestEqual(TEXT("For the buffered activation"), F.Records[1].ActivationId, BufferedId);
			}
			TestEqual(TEXT("No chain end"), F.Ends.Num(), 0);
			TestEqual(TEXT("Step 2 hits the dummy"), Health(*Dummy->GetAethelnAbilitySystemComponent()), 30.0f);
			break;
		case ERow::AtLinkOpen:
			if (TestEqual(TEXT("The started step keeps its record"), F.Records.Num(), 2)) { TestEqual(TEXT("For the buffered activation"), F.Records[1].ActivationId, BufferedId); }
			if (TestEqual(TEXT("One chain end"), F.Ends.Num(), 1))
			{
				TestEqual(TEXT("Interrupted"), F.Ends[0].Reason, EAethelnChainEndReason::Interrupted);
				TestEqual(TEXT("The end names step 2"), F.Ends[0].ActivationId, BufferedId);
			}
			TestEqual(TEXT("Step 2's later contact is dropped"), Health(*Dummy->GetAethelnAbilitySystemComponent()), 35.0f);
			TestEqual(TEXT("Its record reaches the owner before its end"), FString(Messages.Num(), Messages.GetData()), FString(TEXT("RRE")));
			break;
		}
		if (Row != ERow::NotInterruptible)
		{
			TestEqual(TEXT("The next press starts step 1"), F.Press(), EResult::Accepted);
			TestEqual(TEXT("Step 1 again"), F.Records.Last().ChainStep, uint8(1));
		}
	}
	return true;
}

#endif
