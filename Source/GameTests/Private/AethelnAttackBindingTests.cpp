#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnAbilitySystemComponent.h"
#include "AethelnChainTestFixture.h"
#include "AethelnGameplayTags.h"
#include "AethelnOathscarTestAbilities.h"
#include "AethelnPOCInputComponent.h"
#include "GameFramework/PlayerController.h"
#include "Misc/AutomationTest.h"
#include "Misc/ConfigCacheIni.h"
#include "Misc/Paths.h"

// #60 P6, Test Plan A22 (docs/attack-timeline-and-combo.md, Input path across modules). The left mouse button's
// routing (FAethelnPrimaryButtonRouter) and the GameUI entry (SubmitPrimaryAttack) run against a real PlayerState
// and activation seam in an authority world, where the request RPC runs in place. The Enhanced Input wiring that calls
// them is not simulated here (no input device in the harness): it is the manual S5 step recorded in the document.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAttackBindingSubmitsControlAimTest,
	"Aetheln.POC.Input.AttackBindingSubmitsControlAim",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAttackBindingSubmitsControlAimTest::RunTest(const FString& Parameters)
{
	using namespace AethelnChainTests;
	using EResult = EAethelnActivationResult;
	using EAction = FAethelnPrimaryButtonRouter::EAction;

	FFixture F;
	if (!F.Init(*this)) { return false; }
	TArray<EResult> Outcomes;
	const FDelegateHandle OutcomeHandle = F.Player.AbilitySystem->OnActivationOutcome.AddLambda([&Outcomes](uint32, EResult Result) { Outcomes.Add(Result); });
	const FRotator Look(30.0, 10.0, 0.0);
	F.Player.Controller->SetControlRotation(Look);
	FAethelnPrimaryButtonRouter Button;

	TestFalse(TEXT("No controller, no press"), SubmitPrimaryAttack(nullptr));

	// A Reticle-mode press attacks, with the control-rotation aim including pitch.
	if (TestEqual(TEXT("A Reticle-mode press is an attack"), Button.Press(EAethelnPOCControlMode::Reticle), EAction::Attack))
	{
		TestTrue(TEXT("The press reaches the PlayerState through the GameUI entry"), SubmitPrimaryAttack(F.Player.Controller));
	}
	TestEqual(TEXT("The server answered the press"), Outcomes.Num(), 1);
	if (Outcomes.Num() == 1) { TestEqual(TEXT("The press is accepted"), Outcomes[0], EResult::Accepted); }
	if (TestEqual(TEXT("The press started the first step"), F.Records.Num(), 1))
	{
		const FVector Aim = F.Records[0].AcceptedAim;
		TestTrue(TEXT("The accepted aim is the control rotation"), Aim.Equals(Look.Vector(), 0.01));
		TestTrue(TEXT("The aim carries the pitch"), Aim.Z > 0.4);
		TestEqual(TEXT("A press at the controller's rotation is not corrected"), F.Records[0].AimCorrection, EAethelnAimCorrection::None);
	}
	Button.Release();

	// A Cursor-mode press recaptures and sends nothing; the same press is not an attack after the mode returns to Reticle.
	TestEqual(TEXT("A Cursor-mode press recaptures"), Button.Press(EAethelnPOCControlMode::Cursor), EAction::Recapture);
	TestEqual(TEXT("The recapture click is never an attack"), Button.Press(EAethelnPOCControlMode::Reticle), EAction::None);
	TestEqual(TEXT("Neither sent a request"), Outcomes.Num(), 1);

	// A fresh press after the release attacks again. The first chain has timed out by then, so it starts step 1.
	Button.Release();
	F.AdvanceTo(1.0);
	TestEqual(TEXT("A fresh Reticle-mode press attacks"), Button.Press(EAethelnPOCControlMode::Reticle), EAction::Attack);
	TestTrue(TEXT("The fresh press is sent"), SubmitPrimaryAttack(F.Player.Controller));
	TestEqual(TEXT("The server answered the fresh press"), Outcomes.Num(), 2);
	if (Outcomes.Num() == 2) { TestEqual(TEXT("The fresh press is accepted"), Outcomes[1], EResult::Accepted); }
	TestEqual(TEXT("The fresh press started a step"), F.Records.Num(), 2);

	F.Player.AbilitySystem->OnActivationOutcome.Remove(OutcomeHandle);
	return true;
}

// #260 P5, Test Plan K14's routing leg (docs/gas-foundation.md, Representative Oathscar Actives). The press of Instant Strike, Parry,
// Attack Stance and Defense Stance (RouteActivePress, which each bound key's handler calls) against a real PlayerState and seam in an
// authority world. The fixture actives are granted for the first part; the second part grants none, as production does until their
// values exist. The Enhanced Input wiring that calls the router is the manual step in the document: the key layout is #82's, so no
// key is mapped by default.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnActiveBindingsRouteTest,
	"Aetheln.POC.Input.ActiveBindingsRoute",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnActiveBindingsRouteTest::RunTest(const FString& Parameters)
{
	using namespace AethelnChainTests;
	using EResult = EAethelnActivationResult;
	const TArray<FGameplayTag> Ids = { AethelnGameplayTags::Ability_Oathscar_InstantStrike, AethelnGameplayTags::Ability_Oathscar_Parry,
		AethelnGameplayTags::Ability_Oathscar_AttackStance, AethelnGameplayTags::Ability_Oathscar_DefenseStance };
	const FGameplayTag AttackStance = AethelnGameplayTags::State_Oathscar_AttackStance;
	const FGameplayTag DefenseStance = AethelnGameplayTags::State_Oathscar_DefenseStance;

	{
		FFixture F;
		if (!F.Init(*this, { UAethelnInstantStrikeTestAbility::StaticClass(), UAethelnParryTestAbility::StaticClass(),
			UAethelnAttackStanceTestAbility::StaticClass(), UAethelnDefenseStanceTestAbility::StaticClass() })) { return false; }
		TArray<EResult> Outcomes;
		const FDelegateHandle OutcomeHandle = F.Player.AbilitySystem->OnActivationOutcome.AddLambda([&Outcomes](uint32, EResult Result) { Outcomes.Add(Result); });
		F.AdvanceTo(1.0);

		// Cursor mode and no controller send nothing, for every active.
		for (const FGameplayTag& Id : Ids)
		{
			TestFalse(TEXT("A Cursor-mode press sends nothing"), RouteActivePress(EAethelnPOCControlMode::Cursor, F.Player.Controller, Id));
			TestFalse(TEXT("No controller, no press"), RouteActivePress(EAethelnPOCControlMode::Reticle, nullptr, Id));
		}
		TestEqual(TEXT("No request reached the server"), Outcomes.Num(), 0);
		TestEqual(TEXT("Nothing was spent"), F.CostApplications, 0);

		// A Reticle-mode press of each active is accepted by its own ability, with room for each one's window to pass.
		// Red-first: the fixture always grants the chain, so if the route sent the chain's id the press would start chain step 1 and the record count
		// would still pass; the line that fails is "The record names Instant Strike".
		TestTrue(TEXT("A Reticle-mode press of Instant Strike is sent"), RouteActivePress(EAethelnPOCControlMode::Reticle, F.Player.Controller, Ids[0]));
		if (TestEqual(TEXT("Instant Strike started its one step"), F.Records.Num(), 1)) { TestTrue(TEXT("The record names Instant Strike"), F.Records[0].AbilityId == Ids[0]); }
		F.AdvanceTo(2.0);
		TestTrue(TEXT("A Reticle-mode press of Parry is sent"), RouteActivePress(EAethelnPOCControlMode::Reticle, F.Player.Controller, Ids[1]));
		F.AdvanceTo(3.0);
		TestTrue(TEXT("A Reticle-mode press of Attack Stance is sent"), RouteActivePress(EAethelnPOCControlMode::Reticle, F.Player.Controller, Ids[2]));
		TestTrue(TEXT("It grants the Attack Stance tag"), F.Player.AbilitySystem->HasMatchingGameplayTag(AttackStance));
		TestTrue(TEXT("A Reticle-mode press of Defense Stance is sent"), RouteActivePress(EAethelnPOCControlMode::Reticle, F.Player.Controller, Ids[3]));
		TestTrue(TEXT("It replaces the Attack Stance with its own tag"), F.Player.AbilitySystem->HasMatchingGameplayTag(DefenseStance) && !F.Player.AbilitySystem->HasMatchingGameplayTag(AttackStance));
		if (TestEqual(TEXT("The server answered each press"), Outcomes.Num(), 4))
		{
			for (const EResult Outcome : Outcomes) { TestEqual(TEXT("Each press is accepted"), Outcome, EResult::Accepted); }
		}
		TestEqual(TEXT("Each accepted press spent its cost once"), F.CostApplications, 4);
		F.Player.AbilitySystem->OnActivationOutcome.Remove(OutcomeHandle);
	}

	// A binding whose active is not granted does nothing: the server answers ActivationBlocked, and nothing is spent, started or applied.
	{
		FFixture F;
		if (!F.Init(*this)) { return false; }
		TArray<EResult> Outcomes;
		const FDelegateHandle OutcomeHandle = F.Player.AbilitySystem->OnActivationOutcome.AddLambda([&Outcomes](uint32, EResult Result) { Outcomes.Add(Result); });
		F.AdvanceTo(1.0);
		const float EnduranceBefore = F.Endurance();
		for (const FGameplayTag& Id : Ids) { TestTrue(TEXT("The press is sent"), RouteActivePress(EAethelnPOCControlMode::Reticle, F.Player.Controller, Id)); }
		if (TestEqual(TEXT("The server answered each press"), Outcomes.Num(), 4))
		{
			for (const EResult Outcome : Outcomes) { TestEqual(TEXT("An ungranted active is blocked"), Outcome, EResult::ActivationBlocked); }
		}
		TestEqual(TEXT("Nothing was spent"), F.CostApplications, 0);
		TestEqual(TEXT("Endurance is untouched"), F.Endurance(), EnduranceBefore);
		TestEqual(TEXT("No step started"), F.Records.Num(), 0);
		TestFalse(TEXT("No Attack Stance"), F.Player.AbilitySystem->HasMatchingGameplayTag(AttackStance));
		TestFalse(TEXT("No Defense Stance"), F.Player.AbilitySystem->HasMatchingGameplayTag(DefenseStance));
		F.Player.AbilitySystem->OnActivationOutcome.Remove(OutcomeHandle);
	}

	// The key layout is #82's: the tracked ini maps no key to any of the four.
	FConfigFile Tracked;
	Tracked.Read(FPaths::ProjectConfigDir() / TEXT("DefaultGame.ini"));
	TestNull(TEXT("DefaultGame.ini chooses no key for the actives"), Tracked.FindSection(TEXT("/Script/GameUI.AethelnPOCInputComponent")));
	return true;
}

#endif
