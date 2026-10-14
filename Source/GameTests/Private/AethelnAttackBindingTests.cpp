#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnAbilitySystemComponent.h"
#include "AethelnChainTestFixture.h"
#include "AethelnPOCInputComponent.h"
#include "GameFramework/PlayerController.h"
#include "Misc/AutomationTest.h"

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

#endif
