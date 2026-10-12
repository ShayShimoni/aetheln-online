#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatEffects.h"
#include "AethelnCombatTestWorld.h"
#include "AethelnGameplayTags.h"
#include "AethelnHudPresenter.h"
#include "AethelnHudTestFixture.h"
#include "AethelnPlayerState.h"
#include "GameFramework/PlayerController.h"
#include "Misc/AutomationTest.h"

/*
 * #61 player-state HUD. The presenter and the PlayerState source are presentation only;
 * these tests pin formatting, outcome mapping and forwarding, convergence to the source,
 * and that bindings neither duplicate nor go stale when the HUD or its source changes.
 * Values below are test fixtures, not tuning.
 */
namespace AethelnHudTests
{
	using AethelnCombatTests::FScopedCombatTestWorld;

	FAethelnHudActionOutcome MakeOutcome(EAethelnHudOutcomeKind Kind, uint32 Sequence, FName Reason = NAME_None)
	{
		FAethelnHudActionOutcome Outcome;
		Outcome.Kind = Kind;
		Outcome.Sequence = Sequence;
		Outcome.Reason = Reason;
		return Outcome;
	}

	AAethelnPlayerState* SpawnInitializedPlayerState(const FScopedCombatTestWorld& TestWorld)
	{
		APlayerController* Controller = TestWorld.Spawn<APlayerController>();
		AAethelnPlayerState* PlayerState = Controller != nullptr ? AethelnCombatTests::AttachFreshPlayerState(TestWorld, *Controller) : nullptr;
		if (PlayerState != nullptr)
		{
			UAethelnAttributeInitEffect::ApplyTo(*PlayerState->GetAethelnAbilitySystemComponent(), AethelnCombatTests::MakeTestInitValues());
		}
		return PlayerState;
	}

	void ApplyTimedTag(UAbilitySystemComponent& AbilitySystem, const FGameplayTag& Tag, float Seconds)
	{
		const FGameplayEffectSpecHandle Spec = AbilitySystem.MakeOutgoingSpec(UAethelnCooldownEffect::StaticClass(), 1.0f, AbilitySystem.MakeEffectContext());
		Spec.Data->SetSetByCallerMagnitude(AethelnGameplayTags::SetByCaller_Cooldown_Duration, Seconds);
		Spec.Data->DynamicGrantedTags.AddTag(Tag);
		AbilitySystem.ApplyGameplayEffectSpecToSelf(*Spec.Data.Get());
	}

	const FAethelnHudTimedState* FindTimedState(const FAethelnHudSnapshot& Snapshot, const FGameplayTag& Tag)
	{
		return Snapshot.TimedStates.FindByPredicate([&Tag](const FAethelnHudTimedState& State) { return State.Tag == Tag; });
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnHudFormattingTest,
	"Aetheln.GameUI.Hud.Formatting",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnHudFormattingTest::RunTest(const FString& Parameters)
{
	using namespace AethelnHudTests;
	const FText Health = FText::FromString(TEXT("Health"));

	FAethelnHudResource Resource;
	TestEqual(TEXT("An unknown resource shows no number"), FAethelnHudPresenter::FormatResource(Health, Resource).ToString(), FString(TEXT("Health --")));
	Resource = { 30.3f, 40.0f, true };
	TestEqual(TEXT("A fractional current value rounds up, so a living character never shows 0"), FAethelnHudPresenter::FormatResource(Health, Resource).ToString(), FString(TEXT("Health 31 / 40")));
	Resource = { 0.0f, 40.0f, true };
	TestEqual(TEXT("Zero shows 0"), FAethelnHudPresenter::FormatResource(Health, Resource).ToString(), FString(TEXT("Health 0 / 40")));

	TestEqual(TEXT("No timed states"), FAethelnHudPresenter::FormatTimedStates({}).ToString(), FString(TEXT("Timers: none")));
	FAethelnHudTimedState Dodge;
	Dodge.Tag = AethelnGameplayTags::Cooldown_Dodge;
	Dodge.RemainingSeconds = 1.21f;
	FAethelnHudTimedState Broken;
	Broken.Tag = AethelnGameplayTags::State_GuardBroken;
	TestEqual(TEXT("Remaining time rounds up to a tenth; an unknown duration reads active"),
		FAethelnHudPresenter::FormatTimedStates({ Dodge, Broken }).ToString(),
		FString(TEXT("Cooldown.Dodge 1.3s\nState.GuardBroken active")));
	Dodge.RemainingSeconds = 0.00005f;
	TestEqual(TEXT("A nearly expired timer reads 0.1s, never 0.0s or -0.0s"), FAethelnHudPresenter::FormatTimedStates({ Dodge }).ToString(), FString(TEXT("Cooldown.Dodge 0.1s")));
	Dodge.RemainingSeconds = 0.0f;
	TestEqual(TEXT("A timer at zero still reads 0.1s while its tag is owned"), FAethelnHudPresenter::FormatTimedStates({ Dodge }).ToString(), FString(TEXT("Cooldown.Dodge 0.1s")));

	TestEqual(TEXT("No outcome yet"), FAethelnHudPresenter::FormatOutcome({}, 0).ToString(), FString(TEXT("Last action: none")));
	TestEqual(TEXT("Accepted"), FAethelnHudPresenter::FormatOutcome(MakeOutcome(EAethelnHudOutcomeKind::Accepted, 1), 1).ToString(), FString(TEXT("Last action: ACCEPTED #1")));
	TestEqual(TEXT("Corrected"), FAethelnHudPresenter::FormatOutcome(MakeOutcome(EAethelnHudOutcomeKind::Corrected, 2), 2).ToString(), FString(TEXT("Last action: CORRECTED #2")));
	TestEqual(TEXT("Rejected names its reason"),
		FAethelnHudPresenter::FormatOutcome(MakeOutcome(EAethelnHudOutcomeKind::Rejected, 3, TEXT("OnCooldown")), 3).ToString(),
		FString(TEXT("Last action: REJECTED (OnCooldown) #3")));

	FAethelnHudObjective Objective;
	TestEqual(TEXT("No objective"), FAethelnHudPresenter::FormatObjective(Objective).ToString(), FString(TEXT("Objective: none")));
	Objective.Label = FText::FromString(TEXT("Fixture objective"));
	Objective.State = EAethelnHudObjectiveState::Active;
	TestEqual(TEXT("Active objective"), FAethelnHudPresenter::FormatObjective(Objective).ToString(), FString(TEXT("Objective: Fixture objective")));
	Objective.State = EAethelnHudObjectiveState::Completed;
	TestEqual(TEXT("Completed objective"), FAethelnHudPresenter::FormatObjective(Objective).ToString(), FString(TEXT("Objective complete: Fixture objective")));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnHudOutcomeMappingTest,
	"Aetheln.GameUI.Hud.OutcomeMapping",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnHudOutcomeMappingTest::RunTest(const FString& Parameters)
{
	const FAethelnHudActionOutcome Accepted = AAethelnPlayerState::ToHudOutcome(7, EAethelnActivationResult::Accepted);
	TestTrue(TEXT("Accepted maps to Accepted"), Accepted.Kind == EAethelnHudOutcomeKind::Accepted);
	TestEqual(TEXT("The sequence is kept"), static_cast<int32>(Accepted.Sequence), 7);
	TestTrue(TEXT("Accepted has no reason"), Accepted.Reason.IsNone());

	const UEnum* ResultEnum = StaticEnum<EAethelnActivationResult>();
	for (int32 Index = 0; Index < ResultEnum->NumEnums() - 1; ++Index)
	{
		const EAethelnActivationResult Result = static_cast<EAethelnActivationResult>(ResultEnum->GetValueByIndex(Index));
		if (Result == EAethelnActivationResult::Accepted)
		{
			continue;
		}
		const FString Name = ResultEnum->GetNameStringByIndex(Index);
		const FAethelnHudActionOutcome Outcome = AAethelnPlayerState::ToHudOutcome(9, Result);
		TestTrue(*FString::Printf(TEXT("%s maps to Rejected"), *Name), Outcome.Kind == EAethelnHudOutcomeKind::Rejected);
		TestEqual(*FString::Printf(TEXT("%s keeps its owner-facing name as the reason"), *Name), Outcome.Reason.ToString(), Name);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnHudPlayerStateSnapshotTest,
	"Aetheln.GameUI.Hud.PlayerStateSnapshot",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnHudPlayerStateSnapshotTest::RunTest(const FString& Parameters)
{
	using namespace AethelnHudTests;
	FScopedCombatTestWorld TestWorld;
	AAethelnPlayerState* PlayerState = SpawnInitializedPlayerState(TestWorld);
	if (!TestNotNull(TEXT("PlayerState"), PlayerState))
	{
		return false;
	}
	UAethelnAbilitySystemComponent* AbilitySystem = PlayerState->GetAethelnAbilitySystemComponent();

	// Before the first owner replication (or the server's init) every maximum is 0: the HUD must not read "Health 0 / 0".
	APlayerController* FreshController = TestWorld.Spawn<APlayerController>();
	AAethelnPlayerState* FreshPlayerState = FreshController != nullptr ? AethelnCombatTests::AttachFreshPlayerState(TestWorld, *FreshController) : nullptr;
	if (TestNotNull(TEXT("Uninitialized PlayerState"), FreshPlayerState))
	{
		const FAethelnHudSnapshot Unknown = FreshPlayerState->GetHudSnapshot();
		TestFalse(TEXT("Health is unknown before the attributes arrive"), Unknown.Health.bKnown);
		TestFalse(TEXT("Endurance is unknown before the attributes arrive"), Unknown.Endurance.bKnown);
		TestFalse(TEXT("Guard is unknown before the attributes arrive"), Unknown.Guard.bKnown);
	}

	FAethelnHudSnapshot Snapshot = PlayerState->GetHudSnapshot();
	TestTrue(TEXT("Health is known"), Snapshot.Health.bKnown);
	TestEqual(TEXT("Health"), Snapshot.Health.Current, 40.0f);
	TestEqual(TEXT("MaxHealth"), Snapshot.Health.Max, 40.0f);
	TestTrue(TEXT("Endurance is known"), Snapshot.Endurance.bKnown);
	TestEqual(TEXT("Endurance"), Snapshot.Endurance.Current, 30.0f);
	TestEqual(TEXT("MaxEndurance"), Snapshot.Endurance.Max, 30.0f);
	TestTrue(TEXT("Guard is known"), Snapshot.Guard.bKnown);
	TestEqual(TEXT("Guard"), Snapshot.Guard.Current, 20.0f);
	TestEqual(TEXT("MaxGuard"), Snapshot.Guard.Max, 20.0f);
	TestEqual(TEXT("No timed state yet"), Snapshot.TimedStates.Num(), 0);

	AethelnCombatTests::ApplyInstantModifier(*AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::Additive, -15.0f);
	ApplyTimedTag(*AbilitySystem, AethelnGameplayTags::Cooldown_Dodge, 5.0f);
	ApplyTimedTag(*AbilitySystem, AethelnGameplayTags::Cooldown_Oathscar_GateStep, 3.0f);
	ApplyTimedTag(*AbilitySystem, AethelnGameplayTags::State_GuardBroken, 2.0f);
	ApplyTimedTag(*AbilitySystem, AethelnGameplayTags::State_EnduranceRecoveryDelayed, 1.0f);
	ApplyTimedTag(*AbilitySystem, AethelnGameplayTags::State_GuardRecoveryDelayed, 1.0f);
	AbilitySystem->AddLooseGameplayTag(AethelnGameplayTags::State_Blocking);

	Snapshot = PlayerState->GetHudSnapshot();
	TestEqual(TEXT("A new value shows on the next snapshot"), Snapshot.Health.Current, 25.0f);
	TestEqual(TEXT("Cooldowns, the Guard break and the recovery delays are the timed states"), Snapshot.TimedStates.Num(), 5);
	const FAethelnHudTimedState* Dodge = FindTimedState(Snapshot, AethelnGameplayTags::Cooldown_Dodge);
	if (TestNotNull(TEXT("Cooldown.Dodge"), Dodge))
	{
		TestTrue(TEXT("Cooldown.Dodge remaining time"), Dodge->RemainingSeconds > 4.9f && Dodge->RemainingSeconds <= 5.0f);
	}
	TestNotNull(TEXT("Cooldown.Oathscar.GateStep"), FindTimedState(Snapshot, AethelnGameplayTags::Cooldown_Oathscar_GateStep));
	TestNotNull(TEXT("State.GuardBroken"), FindTimedState(Snapshot, AethelnGameplayTags::State_GuardBroken));
	TestNotNull(TEXT("State.EnduranceRecoveryDelayed"), FindTimedState(Snapshot, AethelnGameplayTags::State_EnduranceRecoveryDelayed));
	TestNotNull(TEXT("State.GuardRecoveryDelayed"), FindTimedState(Snapshot, AethelnGameplayTags::State_GuardRecoveryDelayed));
	TestNull(TEXT("An untimed state is not a timed state"), FindTimedState(Snapshot, AethelnGameplayTags::State_Blocking));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnHudOutcomeForwardingTest,
	"Aetheln.GameUI.Hud.OutcomeForwarding",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnHudOutcomeForwardingTest::RunTest(const FString& Parameters)
{
	using namespace AethelnHudTests;
	FScopedCombatTestWorld TestWorld;
	AAethelnPlayerState* PlayerState = SpawnInitializedPlayerState(TestWorld);
	if (!TestNotNull(TEXT("PlayerState"), PlayerState))
	{
		return false;
	}
	UAethelnAbilitySystemComponent* AbilitySystem = PlayerState->GetAethelnAbilitySystemComponent();

	TArray<FAethelnHudActionOutcome> Received;
	const FDelegateHandle Handle = PlayerState->OnHudActionOutcome().AddLambda([&Received](const FAethelnHudActionOutcome& Outcome) { Received.Add(Outcome); });

	AbilitySystem->OnActivationOutcome.Broadcast(3, EAethelnActivationResult::OnCooldown);
	AbilitySystem->OnMovementActivationOutcome.Broadcast(1.5f, EAethelnActivationResult::InsufficientResource);
	FAethelnCombatActivationRecord Record;
	Record.Sequence = 4;
	AbilitySystem->OnCombatActivation.Broadcast(Record);
	Record.Sequence = 5;
	Record.AimCorrection = EAethelnAimCorrection::AimCorrected;
	AbilitySystem->OnCombatActivation.Broadcast(Record);
	PlayerState->OnHudActionOutcome().Remove(Handle);

	if (!TestEqual(TEXT("One HUD event per outcome and per corrected step; an uncorrected step adds none"), Received.Num(), 3))
	{
		return false;
	}
	TestTrue(TEXT("Activation outcome is rejected"), Received[0].Kind == EAethelnHudOutcomeKind::Rejected);
	TestEqual(TEXT("Activation outcome sequence"), static_cast<int32>(Received[0].Sequence), 3);
	TestEqual(TEXT("Activation outcome reason"), Received[0].Reason.ToString(), FString(TEXT("OnCooldown")));
	TestTrue(TEXT("Movement outcome is rejected"), Received[1].Kind == EAethelnHudOutcomeKind::Rejected);
	TestEqual(TEXT("Movement outcome has no sequence"), static_cast<int32>(Received[1].Sequence), 0);
	TestEqual(TEXT("Movement outcome reason"), Received[1].Reason.ToString(), FString(TEXT("InsufficientResource")));
	TestTrue(TEXT("Corrected step"), Received[2].Kind == EAethelnHudOutcomeKind::Corrected);
	TestEqual(TEXT("Corrected step sequence"), static_cast<int32>(Received[2].Sequence), 5);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnHudPresenterValuesTest,
	"Aetheln.GameUI.Hud.PresenterValues",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnHudPresenterValuesTest::RunTest(const FString& Parameters)
{
	using namespace AethelnHudTests;
	FScopedCombatTestWorld TestWorld;
	AAethelnPlayerState* PlayerState = SpawnInitializedPlayerState(TestWorld);
	if (!TestNotNull(TEXT("PlayerState"), PlayerState))
	{
		return false;
	}
	UAethelnAbilitySystemComponent* AbilitySystem = PlayerState->GetAethelnAbilitySystemComponent();

	FAethelnHudPresenter Presenter;
	const FAethelnHudView* View = &Presenter.Refresh(PlayerState, nullptr);
	TestEqual(TEXT("Health"), View->Health.ToString(), FString(TEXT("Health 40 / 40")));
	TestEqual(TEXT("Endurance"), View->Endurance.ToString(), FString(TEXT("Endurance 30 / 30")));
	TestEqual(TEXT("Guard"), View->Guard.ToString(), FString(TEXT("Guard 20 / 20")));
	TestEqual(TEXT("Timers"), View->TimedStates.ToString(), FString(TEXT("Timers: none")));
	TestEqual(TEXT("Objective without a source"), View->Objective.ToString(), FString(TEXT("Objective: none")));
	TestEqual(TEXT("No outcome yet"), View->Outcome.ToString(), FString(TEXT("Last action: none")));

	// A rejection is a cue only: it never changes a displayed value.
	AbilitySystem->OnActivationOutcome.Broadcast(1, EAethelnActivationResult::InsufficientResource);
	View = &Presenter.Refresh(PlayerState, nullptr);
	TestEqual(TEXT("Rejected cue"), View->Outcome.ToString(), FString(TEXT("Last action: REJECTED (InsufficientResource) #1")));
	TestEqual(TEXT("Endurance unchanged by a rejection"), View->Endurance.ToString(), FString(TEXT("Endurance 30 / 30")));

	// Values converge to the source on the next refresh.
	AethelnCombatTests::ApplyInstantModifier(*AbilitySystem, UAethelnCombatAttributeSet::GetEnduranceAttribute(), EGameplayModOp::Additive, -10.0f);
	View = &Presenter.Refresh(PlayerState, nullptr);
	TestEqual(TEXT("Endurance converges"), View->Endurance.ToString(), FString(TEXT("Endurance 20 / 30")));

	// The server sends a started step's record before its Accepted outcome; Accepted must not hide the correction.
	FAethelnCombatActivationRecord Record;
	Record.Sequence = 2;
	Record.AimCorrection = EAethelnAimCorrection::AimCorrected;
	AbilitySystem->OnCombatActivation.Broadcast(Record);
	AbilitySystem->OnActivationOutcome.Broadcast(2, EAethelnActivationResult::Accepted);
	View = &Presenter.Refresh(PlayerState, nullptr);
	TestEqual(TEXT("Corrected survives its own Accepted"), View->Outcome.ToString(), FString(TEXT("Last action: CORRECTED #2")));

	AbilitySystem->OnActivationOutcome.Broadcast(3, EAethelnActivationResult::Accepted);
	View = &Presenter.Refresh(PlayerState, nullptr);
	TestEqual(TEXT("A later action replaces it"), View->Outcome.ToString(), FString(TEXT("Last action: ACCEPTED #3")));

	// A buffered step sends its record after its Accepted outcome: the same action's cue upgrades, without a new count.
	Record.Sequence = 3;
	AbilitySystem->OnCombatActivation.Broadcast(Record);
	View = &Presenter.Refresh(PlayerState, nullptr);
	TestEqual(TEXT("A late correction upgrades its own action's cue"), View->Outcome.ToString(), FString(TEXT("Last action: CORRECTED #3")));

	// A late correction for an older action never replaces a newer action's cue.
	AbilitySystem->OnActivationOutcome.Broadcast(4, EAethelnActivationResult::Accepted);
	AbilitySystem->OnActivationOutcome.Broadcast(5, EAethelnActivationResult::Accepted);
	Record.Sequence = 4;
	AbilitySystem->OnCombatActivation.Broadcast(Record);
	View = &Presenter.Refresh(PlayerState, nullptr);
	TestEqual(TEXT("An older action's correction is dropped"), View->Outcome.ToString(), FString(TEXT("Last action: ACCEPTED #5")));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnHudPresenterBindingLifecycleTest,
	"Aetheln.GameUI.Hud.PresenterBindingLifecycle",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnHudPresenterBindingLifecycleTest::RunTest(const FString& Parameters)
{
	using namespace AethelnHudTests;
	FScopedCombatTestWorld TestWorld;
	AAethelnPlayerState* First = SpawnInitializedPlayerState(TestWorld);
	AAethelnPlayerState* Second = SpawnInitializedPlayerState(TestWorld);
	if (!TestNotNull(TEXT("First PlayerState"), First) || !TestNotNull(TEXT("Second PlayerState"), Second))
	{
		return false;
	}
	auto Reject = [](AAethelnPlayerState* PlayerState, uint32 Sequence)
	{
		PlayerState->GetAethelnAbilitySystemComponent()->OnActivationOutcome.Broadcast(Sequence, EAethelnActivationResult::OnCooldown);
	};

	{
		// One HUD across many refreshes of the same source (every tick) binds once.
		FAethelnHudPresenter Presenter;
		Presenter.Refresh(First, nullptr);
		Presenter.Refresh(First, nullptr);
		Reject(First, 1);
		TestEqual(TEXT("Repeated refreshes do not duplicate the binding"), static_cast<int32>(Presenter.Refresh(First, nullptr).OutcomeCount), 1);

		// A new source (reconnect gives a new PlayerState) replaces the old binding and its cue.
		const FAethelnHudView& Switched = Presenter.Refresh(Second, nullptr);
		TestEqual(TEXT("The old source's cue does not carry over"), Switched.Outcome.ToString(), FString(TEXT("Last action: none")));
		TestEqual(TEXT("The count restarts"), static_cast<int32>(Switched.OutcomeCount), 0);
		TestFalse(TEXT("The old source keeps no binding"), First->OnHudActionOutcome().IsBound());
		Reject(First, 2);
		TestEqual(TEXT("The old source no longer reaches the HUD"), static_cast<int32>(Presenter.Refresh(Second, nullptr).OutcomeCount), 0);
		Reject(Second, 1);
		TestEqual(TEXT("The new source does"), static_cast<int32>(Presenter.Refresh(Second, nullptr).OutcomeCount), 1);

		// No source (between PlayerStates): nothing stale is shown and nothing stays bound.
		const FAethelnHudView& Empty = Presenter.Refresh(nullptr, nullptr);
		TestEqual(TEXT("Health unknown without a source"), Empty.Health.ToString(), FString(TEXT("Health --")));
		TestEqual(TEXT("No cue without a source"), Empty.Outcome.ToString(), FString(TEXT("Last action: none")));
		Reject(Second, 2);
		TestEqual(TEXT("Unbound without a source"), static_cast<int32>(Presenter.Refresh(nullptr, nullptr).OutcomeCount), 0);
		TestFalse(TEXT("No binding without a source"), Second->OnHudActionOutcome().IsBound());
		Presenter.Refresh(Second, nullptr);
	}
	TestFalse(TEXT("A destroyed presenter leaves no binding"), Second->OnHudActionOutcome().IsBound());

	// The HUD is torn down with its pawn and recreated on respawn; the PlayerState persists.
	// A leaked binding from the destroyed presenter would run on freed memory here.
	Reject(Second, 3);
	{
		FAethelnHudPresenter Recreated;
		Recreated.Refresh(Second, nullptr);
		Reject(Second, 4);
		TestEqual(TEXT("A recreated HUD receives each outcome once"), static_cast<int32>(Recreated.Refresh(Second, nullptr).OutcomeCount), 1);

		// The source can go away while bound.
		Second->Destroy();
		TestEqual(TEXT("A destroyed source shows unknown values"), Recreated.Refresh(Second, nullptr).Health.ToString(), FString(TEXT("Health --")));
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnHudObjectiveFixtureTest,
	"Aetheln.GameUI.Hud.ObjectiveFixture",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnHudObjectiveFixtureTest::RunTest(const FString& Parameters)
{
	UAethelnHudObjectiveTestFixture* Fixture = NewObject<UAethelnHudObjectiveTestFixture>();
	Fixture->Objective.Label = FText::FromString(TEXT("Fixture objective"));

	FAethelnHudPresenter Presenter;
	TestEqual(TEXT("No objective state"), Presenter.Refresh(nullptr, Fixture).Objective.ToString(), FString(TEXT("Objective: none")));

	Fixture->Objective.State = EAethelnHudObjectiveState::Active;
	const FAethelnHudView& Active = Presenter.Refresh(nullptr, Fixture);
	TestEqual(TEXT("Active"), Active.Objective.ToString(), FString(TEXT("Objective: Fixture objective")));
	TestFalse(TEXT("No completion while active"), Active.bObjectiveCompletedThisRefresh);

	Fixture->Objective.State = EAethelnHudObjectiveState::Completed;
	const FAethelnHudView& Completed = Presenter.Refresh(nullptr, Fixture);
	TestEqual(TEXT("Completed"), Completed.Objective.ToString(), FString(TEXT("Objective complete: Fixture objective")));
	TestTrue(TEXT("The completion event fires on the transition"), Completed.bObjectiveCompletedThisRefresh);
	TestFalse(TEXT("The completion event fires once"), Presenter.Refresh(nullptr, Fixture).bObjectiveCompletedThisRefresh);

	FAethelnHudPresenter Recreated;
	const FAethelnHudView& Late = Recreated.Refresh(nullptr, Fixture);
	TestEqual(TEXT("A recreated HUD shows the terminal state"), Late.Objective.ToString(), FString(TEXT("Objective complete: Fixture objective")));
	TestFalse(TEXT("A recreated HUD does not repeat the completion event"), Late.bObjectiveCompletedThisRefresh);
	return true;
}

#endif
