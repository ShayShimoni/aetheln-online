#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatTestAbilities.h"
#include "AethelnCombatTestWorld.h"
#include "AethelnChainTestFixture.h"
#include "AethelnCombatEffects.h"
#include "AethelnObservability.h"
#include "AethelnObservabilitySubsystem.h"
#include "AethelnPlayerCharacter.h"
#include "Components/SkeletalMeshComponent.h"
#include "Misc/AutomationTest.h"
#include "Net/UnrealNetwork.h"
#include "UObject/UnrealType.h"
#include <limits>

namespace AethelnAttackTests
{
	using namespace AethelnCombatTests;
	using EResult = EAethelnActivationResult;
	using EPhase = EAethelnActivationPhase;

	FVector AimAt(double Yaw)
	{
		return FRotator(0.0, Yaw, 0.0).Vector();
	}

	FAethelnCombatActivationRequest MakeRequest(const UAethelnAbilitySystemComponent& AbilitySystem, uint32 Sequence = 1)
	{
		FAethelnCombatActivationRequest Request;
		Request.AbilityId = AethelnCombatTestTags::Ability_Test_Probe;
		Request.ContentVersion = 1;
		Request.Sequence = Sequence;
		FillTestAimAndTime(Request, AbilitySystem);
		return Request;
	}

	struct FFixture
	{
		FTestPlayer Player;
		FGameplayAbilitySpecHandle Handle;
		UAethelnSeamProbeTestAbility* Probe = nullptr;
		TArray<EResult> Outcomes;

		bool Init(FAutomationTestBase& Test, const FScopedCombatTestWorld& World)
		{
			if (!SpawnTestPlayer(Test, World, Player, { UAethelnSeamProbeTestAbility::StaticClass() })) { return false; }
			AAethelnPlayerCharacter* Pawn = World.Spawn<AAethelnPlayerCharacter>();
			if (!Test.TestNotNull(TEXT("Player pawn exists"), Pawn)) { return false; }
			Player.Controller->Possess(Pawn);
			for (const FGameplayAbilitySpec& Spec : Player.AbilitySystem->GetActivatableAbilities())
			{
				if (UAethelnSeamProbeTestAbility* Instance = Cast<UAethelnSeamProbeTestAbility>(Spec.GetPrimaryInstance()))
				{
					Handle = Spec.Handle;
					Probe = Instance;
				}
			}
			Player.AbilitySystem->OnActivationOutcome.AddLambda([this](uint32 Sequence, EResult Result) { Outcomes.Add(Result); });
			return Test.TestNotNull(TEXT("Probe instance exists"), Probe);
		}

		~FFixture()
		{
			if (Player.AbilitySystem != nullptr) { Player.AbilitySystem->OnActivationOutcome.Clear(); }
		}
	};

	UAethelnObservabilitySubsystem* SetSink(FAutomationTestBase& Test, const FScopedCombatTestWorld& World, const TSharedPtr<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>& Sink)
	{
		UAethelnObservabilitySubsystem* Subsystem = World.GameInstance != nullptr ? World.GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>() : nullptr;
		if (!Test.TestNotNull(TEXT("Observability subsystem exists"), Subsystem)) { return nullptr; }
		Test.TestTrue(TEXT("Runtime context is set"), Subsystem->SetRuntimeContext(EAethelnFlowKind::PrototypeAuthority, TEXT("run-attack-p2-test"), TEXT("instance-attack-p2-test"), TEXT("connection-attack-p2-test")));
		Test.TestTrue(TEXT("Public sink is set"), Subsystem->SetTestSink(Sink));
		return Subsystem;
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAimAndTimeValidationTest,
	"Aetheln.GameCombat.AttackTimeline.AimAndTimeValidation",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAimAndTimeValidationTest::RunTest(const FString& Parameters)
{
	using namespace AethelnAttackTests;
	FAethelnActivationValidationState State;
	State.bHasPossessedAvatar = true;
	State.bAbilityGranted = true;
	State.GrantedContentVersion = 1;
	State.bAcceptsRelease = true;
	State.NowSeconds = 10.0;
	State.ReferenceAim = FVector::ForwardVector;
	State.Bounds = MakeTestAimTimeBounds();
	FAethelnCombatActivationRequest Request;
	Request.AbilityId = AethelnCombatTestTags::Ability_Test_Probe;
	Request.ContentVersion = 1;
	Request.Sequence = 2;
	Request.Aim = FVector::ForwardVector;
	Request.ClientServerTimeSeconds = State.NowSeconds;

	auto Check = [this](const TCHAR* Name, const FAethelnCombatActivationRequest& Input, const FAethelnActivationValidationState& ServerState, EResult Expected, EAethelnAimCorrection ExpectedCorrection = EAethelnAimCorrection::None)
	{
		bool bResolved = false;
		FVector AcceptedAim;
		EAethelnAimCorrection Correction;
		const EResult Result = UAethelnAbilitySystemComponent::ValidateRequest(Input, ServerState, bResolved, AcceptedAim, Correction);
		TestTrue(Name, Result == Expected);
		if (Result == EResult::Accepted)
		{
			TestTrue(FString(Name) + TEXT(": correction"), Correction == ExpectedCorrection);
			TestTrue(FString(Name) + TEXT(": accepted aim is unit"), FMath::IsNearlyEqual(AcceptedAim.Size(), 1.0, 1.e-6));
		}
		return AcceptedAim;
	};

	for (const double Time : { 8.0, 10.0, 10.5 })
	{
		FAethelnCombatActivationRequest Input = Request; Input.ClientServerTimeSeconds = Time;
		Check(TEXT("Inclusive age and lead boundaries"), Input, State, EResult::Accepted);
	}
	for (const double Time : { 7.999, 10.501, std::numeric_limits<double>::quiet_NaN(), std::numeric_limits<double>::infinity() })
	{
		FAethelnCombatActivationRequest Input = Request; Input.ClientServerTimeSeconds = Time;
		Check(TEXT("Old, ahead, or non-finite time"), Input, State, EResult::TimestampOutOfBounds);
	}
	FAethelnActivationValidationState Previous = State;
	Previous.LastAcceptedSequence = 1;
	Previous.LastAcceptedAim = FVector::ForwardVector;
	Previous.LastAcceptedClientTimeSeconds = 10.0;
	for (const double Time : { 9.75, 9.9, 10.0 })
	{
		FAethelnCombatActivationRequest Input = Request; Input.ClientServerTimeSeconds = Time;
		Check(TEXT("Allowed regression including boundary and equal time"), Input, Previous, EResult::Accepted);
	}
	FAethelnCombatActivationRequest Bad = Request;
	Bad.ClientServerTimeSeconds = 9.749;
	Check(TEXT("Regression beyond tolerance"), Bad, Previous, EResult::TimestampOutOfBounds);
	for (const FVector& Aim : { FVector::ZeroVector, FVector(2.0, 0.0, 0.0), FVector(std::numeric_limits<double>::quiet_NaN(), 0.0, 0.0), FVector(std::numeric_limits<double>::infinity(), 0.0, 0.0), -FVector::ForwardVector })
	{
		Bad = Request; Bad.Aim = Aim;
		Check(TEXT("Malformed or antipodal aim"), Bad, State, EResult::MalformedRequest);
	}
	Bad = Request; Bad.Aim = FVector(1.005, 0.0, 0.0);
	Check(TEXT("Unit tolerance normalizes the accepted aim"), Bad, State, EResult::Accepted);
	Bad.Aim = AimAt(10.0);
	TestTrue(TEXT("Within soft bound aim is unchanged"), Check(TEXT("Soft-bound acceptance"), Bad, State, EResult::Accepted).Equals(AimAt(10.0), 1.e-6));
	Bad.Aim = AimAt(40.0);
	TestTrue(TEXT("Correction clamps exactly to soft bound"), Check(TEXT("Corrected acceptance"), Bad, State, EResult::Accepted, EAethelnAimCorrection::AimCorrected).Equals(AimAt(State.Bounds.AimSoftBoundDegrees), 1.e-6));
	Bad.Aim = FVector::RightVector;
	Check(TEXT("Inclusive hard boundary"), Bad, State, EResult::Accepted, EAethelnAimCorrection::AimCorrected);
	Bad.Aim = AimAt(91.0);
	Check(TEXT("Beyond hard boundary"), Bad, State, EResult::ImpossibleAimTransition);
	Previous.LastAcceptedAim = AimAt(40.0);
	Bad.Aim = AimAt(44.0);
	Check(TEXT("Rate compares raw to raw, not previously clamped aim"), Bad, Previous, EResult::Accepted, EAethelnAimCorrection::AimCorrected);
	Previous.LastAcceptedAim = FVector::ForwardVector;
	for (const double Time : { 10.0, 9.9 })
	{
		Bad = Request; Bad.ClientServerTimeSeconds = Time; Bad.Aim = AimAt(4.0);
		Check(TEXT("Zero and negative intervals allow the slack"), Bad, Previous, EResult::Accepted);
		Bad.Aim = AimAt(6.0);
		Check(TEXT("Zero and negative intervals reject turns beyond slack"), Bad, Previous, EResult::ImpossibleAimTransition);
	}
	Previous.Bounds.AimRateSlackDegrees = 2.0;
	Bad = Request; Bad.Aim = AimAt(4.0);
	Check(TEXT("Narrow rate slack is independent of soft bound"), Bad, Previous, EResult::ImpossibleAimTransition);
	Previous.Bounds.AimRateSlackDegrees = 8.0;
	Check(TEXT("Wider rate slack leaves the same soft bound"), Bad, Previous, EResult::Accepted);
	Previous.Bounds.AimRateSlackDegrees = 90.0;
	Bad.Aim = FVector::RightVector;
	Check(TEXT("Inclusive angular rate boundary"), Bad, Previous, EResult::Accepted, EAethelnAimCorrection::AimCorrected);
	Previous.Bounds = State.Bounds;
	Bad.ClientServerTimeSeconds = 10.5; Bad.Aim = AimAt(64.0);
	Check(TEXT("Positive interval permits configured rate"), Bad, Previous, EResult::Accepted, EAethelnAimCorrection::AimCorrected);
	Bad.Aim = AimAt(66.0);
	Check(TEXT("Positive interval rejects excessive rate"), Bad, Previous, EResult::ImpossibleAimTransition);

	FAethelnActivationValidationState Invalid = State;
	Invalid.Bounds = FAethelnAimTimeBounds();
	Check(TEXT("Unset bounds fail closed"), Request, Invalid, EResult::InternalFailure);
	for (double FAethelnAimTimeBounds::* Key : { &FAethelnAimTimeBounds::AimSoftBoundDegrees, &FAethelnAimTimeBounds::AimHardBoundDegrees, &FAethelnAimTimeBounds::AimMaxRateDegreesPerSecond, &FAethelnAimTimeBounds::AimRateSlackDegrees, &FAethelnAimTimeBounds::AimUnitTolerance, &FAethelnAimTimeBounds::TimestampMaxAgeSeconds, &FAethelnAimTimeBounds::TimestampMaxLeadSeconds, &FAethelnAimTimeBounds::TimestampRegressionToleranceSeconds })
	{
		Invalid = State; Invalid.Bounds.*Key = std::numeric_limits<double>::quiet_NaN();
		Check(TEXT("Every non-finite bound fails closed"), Request, Invalid, EResult::InternalFailure);
		Invalid.Bounds.*Key = -1.0;
		Check(TEXT("Every negative bound fails closed"), Request, Invalid, EResult::InternalFailure);
	}
	Invalid = State; Invalid.Bounds.AimHardBoundDegrees = 180.0;
	Check(TEXT("Antipodal hard bound is invalid"), Request, Invalid, EResult::InternalFailure);
	Invalid = State; Invalid.Bounds.AimSoftBoundDegrees = 91.0;
	Check(TEXT("Soft exceeds hard"), Request, Invalid, EResult::InternalFailure);
	Invalid = State; Invalid.Bounds.AimRateSlackDegrees = 181.0;
	Check(TEXT("Slack exceeds angular range"), Request, Invalid, EResult::InternalFailure);
	Invalid = State; Invalid.Bounds.AimUnitTolerance = 0.0;
	Check(TEXT("Zero unit tolerance is invalid"), Request, Invalid, EResult::InternalFailure);
	Invalid = State; Invalid.Bounds.TimestampMaxAgeSeconds = 0.0;
	Check(TEXT("Zero age tolerance is invalid"), Request, Invalid, EResult::InternalFailure);
	Invalid = State; Invalid.Bounds.AimSoftBoundDegrees = Invalid.Bounds.AimHardBoundDegrees;
	Bad = Request; Bad.Aim = AimAt(40.0);
	Check(TEXT("Equal soft and hard bounds have no correction band"), Bad, Invalid, EResult::Accepted);

	Bad = Request; Bad.ContentVersion = 2; Bad.ClientServerTimeSeconds = -100.0; Bad.Aim = FVector::ZeroVector;
	Invalid = State; Invalid.bAbilityActive = true; Invalid.Bounds = FAethelnAimTimeBounds();
	Check(TEXT("Version check precedes bounds and time"), Bad, Invalid, EResult::IncompatibleVersion);
	Bad.ContentVersion = 1;
	Check(TEXT("Invalid bounds precede time"), Bad, Invalid, EResult::InternalFailure);
	Invalid.Bounds = State.Bounds;
	Check(TEXT("Time precedes aim and phase"), Bad, Invalid, EResult::TimestampOutOfBounds);
	Bad.ClientServerTimeSeconds = 10.0;
	Check(TEXT("Malformed aim precedes phase"), Bad, Invalid, EResult::MalformedRequest);
	Bad.Aim = AimAt(91.0);
	Check(TEXT("Hard aim precedes phase"), Bad, Invalid, EResult::ImpossibleAimTransition);
	Bad.Aim = FVector::ForwardVector;
	Check(TEXT("Phase check after valid aim"), Bad, Invalid, EResult::ActivationBlocked);
	Bad = Request; Bad.Phase = EPhase::Release;
	Check(TEXT("Release with valid sample reaches phase check"), Bad, State, EResult::ActivationBlocked);
	Bad.ClientServerTimeSeconds = 7.0;
	Check(TEXT("Release time is checked before phase"), Bad, State, EResult::TimestampOutOfBounds);
	Bad = Request; Bad.Phase = EPhase::Release; Bad.Aim = FVector::ZeroVector;
	Check(TEXT("Release rejects malformed aim before phase"), Bad, State, EResult::MalformedRequest);
	Bad.Aim = AimAt(91.0);
	Check(TEXT("Release rejects hard-bound aim before phase"), Bad, State, EResult::ImpossibleAimTransition);
	Bad = Request; Bad.AbilityId = AethelnCombatTestTags::Ability_Test_LongRunning; Bad.Aim = AimAt(91.0);
	Check(TEXT("Non-chain ability gets the same aim checks"), Bad, State, EResult::ImpossibleAimTransition);

	FScopedCombatTestWorld World;
	FFixture Fixture;
	if (!Fixture.Init(*this, World)) { return false; }
	World.World->TimeSeconds = 10.0;
	UAethelnAbilitySystemComponent& ASC = *Fixture.Player.AbilitySystem;
	ASC.ProvisionalAimRateSlackDegrees = 10.0f;
	Bad = MakeRequest(ASC); Bad.Aim = AimAt(40.0);
	TestTrue(TEXT("First corrected press is accepted"), ASC.ProcessServerRequest(Bad) == EResult::Accepted);
	Bad.Sequence = 2; Bad.Phase = EPhase::Release; Bad.Aim = AimAt(65.0);
	TestTrue(TEXT("Rejected turn spends no cost or cooldown"), ASC.ProcessServerRequest(Bad) == EResult::ImpossibleAimTransition && Fixture.Probe->CostApplications == 1 && Fixture.Probe->CooldownApplications == 1);
	Bad.Aim = AimAt(45.0); Bad.ClientServerTimeSeconds = 11.0;
	TestTrue(TEXT("Rejected timestamp does not end the ability"), ASC.ProcessServerRequest(Bad) == EResult::TimestampOutOfBounds && ASC.FindAbilitySpecFromHandle(Fixture.Handle)->IsActive());
	Bad.ClientServerTimeSeconds = 10.0;
	TestTrue(TEXT("Retry proves sequence, raw aim and time did not advance on rejection"), ASC.ProcessServerRequest(Bad) == EResult::Accepted);
	TestEqual(TEXT("Only the first Press committed"), Fixture.Probe->CostApplications, 1);
	FFixture ClientFillFixture;
	if (!ClientFillFixture.Init(*this, World)) { return false; }
	ClientFillFixture.Player.Controller->SetControlRotation(FRotator(15.0, 25.0, 0.0));
	TestNull(TEXT("Harness has no GameState for time fill"), World.World->GetGameState());
	ClientFillFixture.Player.AbilitySystem->RequestActivation(AethelnCombatTestTags::Ability_Test_Probe, EPhase::Press);
	TestTrue(TEXT("Client entry fills pitch/yaw aim and local-world-time fallback"), ClientFillFixture.Outcomes.Num() == 1 && ClientFillFixture.Outcomes[0] == EResult::Accepted);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnReplicatedDataRoutesRefusedTest,
	"Aetheln.GameCombat.AttackTimeline.ReplicatedDataRoutesRefused",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnReplicatedDataRoutesRefusedTest::RunTest(const FString& Parameters)
{
	using namespace AethelnAttackTests;
	FScopedCombatTestWorld World(true);
	FFixture Fixture;
	if (!Fixture.Init(*this, World)) { return false; }
	TSharedPtr<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe> Sink = MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(64);
	UAethelnObservabilitySubsystem* Subsystem = SetSink(*this, World, Sink);
	if (Subsystem == nullptr) { return false; }
	UAethelnAbilitySystemComponent& ASC = *Fixture.Player.AbilitySystem;
	ASC.ProvisionalActivationBucketCapacity = 4.0f;
	ASC.ProvisionalActivationBucketRefillPerSecond = 0.0f;
	const FPredictionKey Key;
	// Positive control uses a separate, local key, not any client-callable RPC.
	const FGameplayAbilitySpecHandle Control = ASC.GiveAbility(FGameplayAbilitySpec(UAethelnLongRunningTestAbility::StaticClass(), 1));
	ASC.InvokeReplicatedEvent(EAbilityGenericReplicatedEvent::GenericConfirm, Control, Key, Key);
	TestTrue(TEXT("Accessor sees local cache writer"), ASC.HasReplicatedTargetDataForTests(Control, Key));
	ASC.ServerSetReplicatedTargetData(Fixture.Handle, Key, FGameplayAbilityTargetDataHandle(), FGameplayTag(), Key);
	TestFalse(TEXT("Target data wrote no cache"), ASC.HasReplicatedTargetDataForTests(Fixture.Handle, Key));
	ASC.ServerSetReplicatedTargetDataCancelled(Fixture.Handle, Key, Key);
	TestFalse(TEXT("Target cancellation wrote no cache"), ASC.HasReplicatedTargetDataForTests(Fixture.Handle, Key));
	ASC.ServerSetReplicatedEvent(EAbilityGenericReplicatedEvent::GenericConfirm, Fixture.Handle, Key, Key);
	TestFalse(TEXT("Replicated event wrote no cache"), ASC.HasReplicatedTargetDataForTests(Fixture.Handle, Key));
	ASC.ServerSetReplicatedEventWithPayload(EAbilityGenericReplicatedEvent::GenericConfirm, Fixture.Handle, Key, Key, FVector_NetQuantize100(FVector(1.0, 2.0, 3.0)));
	TestFalse(TEXT("Payload event wrote no cache"), ASC.HasReplicatedTargetDataForTests(Fixture.Handle, Key));
	ASC.ServerSetInputPressed(Fixture.Handle);
	TestTrue(TEXT("Input Press remains open on an existing spec"), ASC.FindAbilitySpecFromHandle(Fixture.Handle)->InputPressed);
	ASC.ServerSetInputReleased(Fixture.Handle);
	TestFalse(TEXT("Input Release remains open"), ASC.FindAbilitySpecFromHandle(Fixture.Handle)->InputPressed);
	TestTrue(TEXT("Refusal telemetry drained"), Subsystem->WaitForIdleForTests());
	TestEqual(TEXT("Four refusals send no owner replies"), Fixture.Outcomes.Num(), 0);
	TestEqual(TEXT("Four refusals emit no events"), Sink->GetEvents().Num(), 0);
	TestEqual(TEXT("Each refused route emits one metric"), Sink->GetMetrics().Num(), 4);
	for (const FAethelnMetricSample& Metric : Sink->GetMetrics())
	{
		TestTrue(TEXT("Metric is a bounded refusal"), Metric.Metric == EAethelnMetricKind::RejectionCount && Metric.Category == EAethelnObservabilityCategory::Ability && Metric.Reason == EAethelnSafeReason::Rejected && Metric.Value == 1);
	}
	TestTrue(TEXT("Four refusals consumed all four tokens"), ASC.ProcessServerRequest(MakeRequest(ASC)) == EResult::RateLimited);
	TestEqual(TEXT("Refused routes committed nothing"), Fixture.Probe->CostApplications, 0);
	Subsystem->ResetSink(); Subsystem->ResetRuntimeContext();
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnRejectionAndCorrectionTelemetryTest,
	"Aetheln.GameCombat.AttackTimeline.RejectionAndCorrectionTelemetry",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnRejectionAndCorrectionTelemetryTest::RunTest(const FString& Parameters)
{
	using namespace AethelnAttackTests;
	using ECategory = EAethelnObservabilityCategory;
	using EReason = EAethelnSafeReason;
	FScopedCombatTestWorld World(true);
	FFixture Fixture;
	if (!Fixture.Init(*this, World)) { return false; }
	TSharedPtr<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe> Sink = MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(64);
	UAethelnObservabilitySubsystem* Subsystem = SetSink(*this, World, Sink);
	if (Subsystem == nullptr) { return false; }
	UAethelnAbilitySystemComponent& ASC = *Fixture.Player.AbilitySystem;
	FAethelnCombatActivationRequest Request = MakeRequest(ASC);
	Request.ClientServerTimeSeconds -= 3.0;
	TestTrue(TEXT("Time rejection"), ASC.ProcessServerRequest(Request) == EResult::TimestampOutOfBounds);
	Request = MakeRequest(ASC); Request.Aim = AimAt(91.0);
	TestTrue(TEXT("Aim rejection"), ASC.ProcessServerRequest(Request) == EResult::ImpossibleAimTransition);
	Request.Aim = AimAt(40.0);
	TestTrue(TEXT("Corrected acceptance"), ASC.ProcessServerRequest(Request) == EResult::Accepted);
	TestTrue(TEXT("Correction telemetry drained"), Subsystem->WaitForIdleForTests());
	const TArray<FAethelnObservabilityEvent>& Events = Sink->GetEvents();
	const TArray<FAethelnMetricSample>& Metrics = Sink->GetMetrics();
	if (TestEqual(TEXT("Two rejections, correction before acceptance"), Events.Num(), 4))
	{
		TestTrue(TEXT("Timestamp reason mapping"), Events[0].Category == ECategory::Rejection && Events[0].SubjectCategory == ECategory::Ability && Events[0].SafeReason == EReason::TimestampOutOfBounds);
		TestTrue(TEXT("Aim reason mapping"), Events[1].Category == ECategory::Rejection && Events[1].SubjectCategory == ECategory::Aim && Events[1].SafeReason == EReason::ImpossibleAimTransition);
		TestTrue(TEXT("Correction event comes first"), Events[2].Category == ECategory::Correction && Events[2].SubjectCategory == ECategory::Aim && Events[2].SafeReason == EReason::Corrected);
		TestTrue(TEXT("Accepted event follows correction"), Events[3].Category == ECategory::Ability && Events[3].SafeReason == EReason::Accepted);
		const FString ActivationId = Fixture.Probe->GetActivationId().ToString(EGuidFormats::DigitsWithHyphensLower);
		for (int32 Index = 0; Index < Events.Num(); ++Index)
		{
			TestEqual(TEXT("Same request sequence"), static_cast<int64>(Events[Index].Correlation.Sequence), static_cast<int64>(1));
			TestEqual(TEXT("Resolved ability id"), Events[Index].Correlation.AbilityId, Request.AbilityId.ToString());
			TestEqual(TEXT("Connection pseudonym remains excluded"), Events[Index].Correlation.ConnectionPseudonym, FString(AethelnObservability::ExcludedIdentifier));
			TestEqual(TEXT("Only accepted/correction events carry activation id"), Events[Index].Correlation.ActivationId, Index >= 2 ? ActivationId : FString());
			TestTrue(TEXT("Public channel hides diagnostics"), Events[Index].DiagnosticCode == EAethelnDiagnosticCode::None);
		}
	}
	if (TestEqual(TEXT("One metric per outcome plus one correction sample"), Metrics.Num(), 4))
	{
		TestTrue(TEXT("Timestamp rejection metric"), Metrics[0].Metric == EAethelnMetricKind::RejectionCount && Metrics[0].Category == ECategory::Ability && Metrics[0].Reason == EReason::TimestampOutOfBounds);
		TestTrue(TEXT("Aim rejection metric"), Metrics[1].Metric == EAethelnMetricKind::RejectionCount && Metrics[1].Category == ECategory::Aim && Metrics[1].Reason == EReason::ImpossibleAimTransition);
		TestTrue(TEXT("Exactly one correction count"), Metrics[2].Metric == EAethelnMetricKind::CorrectionCount && Metrics[2].Category == ECategory::Aim && Metrics[2].Reason == EReason::Corrected && Metrics[2].Value == 1);
		TestTrue(TEXT("Accepted count follows correction"), Metrics[3].Metric == EAethelnMetricKind::EventCount && Metrics[3].Reason == EReason::Accepted);
	}
	TestEqual(TEXT("Correction adds no second owner reply"), Fixture.Outcomes.Num(), 3);
	TestEqual(TEXT("One accepted request commits once"), Fixture.Probe->CostApplications, 1);
	Subsystem->ResetSink(); Subsystem->ResetRuntimeContext();
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAttackWindowEvaluationTest,
	"Aetheln.GameCombat.AttackTimeline.WindowEvaluation",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAttackWindowEvaluationTest::RunTest(const FString& Parameters)
{
	const FAethelnAttackStepDefinition Step = GetDefault<UAethelnChainTestAbility>()->ProvisionalSteps[0];
	TestTrue(TEXT("Active start is inclusive"), AethelnAttackTimeline::IsWithinWindow(0.125, 0.125, 0.25));
	TestFalse(TEXT("Active end is exclusive"), AethelnAttackTimeline::IsWithinWindow(0.25, 0.125, 0.25));
	const FAethelnAttackSampleInterval Whole = AethelnAttackTimeline::ClipActiveInterval(Step, 0.0, 0.0, 1.0);
	TestTrue(TEXT("A whole skipped window is retained"), Whole.bValid);
	TestEqual(TEXT("Clipped start"), Whole.FromSeconds, 0.125);
	TestEqual(TEXT("Clipped exclusive end"), Whole.ToSeconds, 0.25);
	TestTrue(TEXT("The first sample includes initial overlaps"), Whole.bIncludesInitialOverlap);
	const FAethelnAttackSampleInterval Reset = AethelnAttackTimeline::ClipActiveInterval(Step, 0.0, 0.0, 1.0, 0.1875);
	TestEqual(TEXT("Reset clips the segment without dropping its earlier part"), Reset.ToSeconds, 0.1875);
	TestFalse(TEXT("A later frame does not evaluate the window again"), AethelnAttackTimeline::ClipActiveInterval(Step, 0.0, 1.0, 2.0).bValid);
	TestEqual(TEXT("Both distance and angle bounds determine substeps"), AethelnAttackTimeline::GetSubstepCount(25.0, 12.0, 10.0, 5.0), 3);
	TestEqual(TEXT("Unset sampling bounds refuse"), AethelnAttackTimeline::GetSubstepCount(25.0, 12.0, 0.0, 5.0), 0);

	AethelnChainTests::FFixture Fixture;
	if (!Fixture.Init(*this)) { return false; }
	TestEqual(TEXT("Real seam starts a step"), Fixture.Press(), EAethelnActivationResult::Accepted);
	Fixture.AdvanceTo(1.0);
	TestEqual(TEXT("World pass samples before timeout despite a long frame"), Fixture.Intervals.Num(), 1);
	TestEqual(TEXT("Timeout uses authored time"), Fixture.Player.AbilitySystem->GetLastChainResetTimeForTests(), 0.75);
	Fixture.Press();
	Fixture.AdvanceTo(1.5); Fixture.Press();
	Fixture.AdvanceTo(2.0); Fixture.Press();
	Fixture.AdvanceTo(3.0);
	TestEqual(TEXT("Final active interval survives the same frame's completion"), Fixture.Intervals.Num(), 4);
	TestEqual(TEXT("Long final frame completes with the exact authored stamp"), Fixture.Player.AbilitySystem->GetLastChainResetTimeForTests(), 2.625);
	TestEqual(TEXT("Long final frame reports Completed"), Fixture.Ends.Last().Reason, EAethelnChainEndReason::Completed);
	AethelnChainTests::FFixture OtherWorld; if (!OtherWorld.Init(*this)) { return false; }
	OtherWorld.Press();
	Fixture.AdvanceTo(4.0);
	TestEqual(TEXT("Another world's static delegate cannot advance this timeline"), OtherWorld.Intervals.Num(), 0);
	TestTrue(TEXT("Another world's chain remains active"), OtherWorld.Player.AbilitySystem->GetChainStateForTests().bExists);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAttackStepDefinitionTest,
	"Aetheln.GameCombat.AttackTimeline.StepDefinitionFailsClosed",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAttackStepDefinitionTest::RunTest(const FString& Parameters)
{
	UAethelnChainTestAbility* Definition = NewObject<UAethelnChainTestAbility>();
	TestTrue(TEXT("Real grant dispatcher accepts a fixture-only valid definition"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Definition)));
	const TArray<TFunction<void(UAethelnChainTestAbility&)>> Mutations = {
		[](auto& A) { A.ProvisionalSteps.RemoveAt(2); },
		[](auto& A) { A.ProvisionalSteps[0].ActiveStart = -1.0; },
		[](auto& A) { A.ProvisionalSteps[0].ActiveStart = A.ProvisionalSteps[0].ActiveEnd; },
		[](auto& A) { A.ProvisionalSteps[0].ActiveEnd = 0.5; },
		[](auto& A) { A.ProvisionalSteps[0].BufferOpen = 0.5625; },
		[](auto& A) { A.ProvisionalSteps[0].LinkOpen = 0.6875; },
		[](auto& A) { A.ProvisionalSteps[0].RecoveryEnd = 0.8125; },
		[](auto& A) { A.ProvisionalSteps[0].LinkClose = A.ProvisionalSteps[0].LinkOpen; },
		[](auto& A) { A.ProvisionalSteps[0].CancelOpen = 0.125; },
		[](auto& A) { A.ProvisionalSteps[0].CancelOpen = 1.0; },
		[](auto& A) { A.ProvisionalSteps[2].BufferOpen = 0.375; },
		[](auto& A) { A.ProvisionalSteps[2].LinkOpen = 0.5; },
		[](auto& A) { A.ProvisionalSteps[0].WroughtDamage = -1.0f; },
		[](auto& A) { A.ProvisionalSteps[0].ShapeExtent = FVector::ZeroVector; },
		[](auto& A) { A.ProvisionalSteps[0].MaxTargets = 0; },
		[](auto& A) { A.ProvisionalSteps[0].MaxAimPitchDegrees = 91.0; },
		[](auto& A) { A.ProvisionalSteps[0].ActiveEnd = std::numeric_limits<double>::quiet_NaN(); },
		[](auto& A) { A.ProvisionalMaxSampleDistance = 0.0; },
		[](auto& A) { A.ProvisionalMaxSampleAngleDegrees = std::numeric_limits<double>::infinity(); },
		[](auto& A) { A.ProvisionalCooldownSeconds = 1.0f; },
		[](auto& A) { FGameplayTagContainer Tags(AethelnGameplayTags::State_Dead); Tags.AddTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain); A.SetBlockedTagsForTests(Tags); },
		[](auto& A) { FGameplayTagContainer Tags(AethelnGameplayTags::State_Dead); Tags.AddTag(AethelnCombatTestTags::Test_Blocking); A.SetBlockedTagsForTests(Tags); }
	};
	for (const auto& Mutate : Mutations)
	{
		Definition = NewObject<UAethelnChainTestAbility>(); Mutate(*Definition);
		AddExpectedError(TEXT("Refused to grant ability"), EAutomationExpectedErrorFlags::Contains, 1);
		TestFalse(TEXT("Invalid definition refuses through base-pointer grant dispatch"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Definition)));
	}
	for (double FAethelnAttackStepDefinition::* Field : { &FAethelnAttackStepDefinition::ActiveStart, &FAethelnAttackStepDefinition::ActiveEnd,
		&FAethelnAttackStepDefinition::BufferOpen, &FAethelnAttackStepDefinition::LinkOpen, &FAethelnAttackStepDefinition::LinkClose,
		&FAethelnAttackStepDefinition::RecoveryEnd, &FAethelnAttackStepDefinition::CancelOpen, &FAethelnAttackStepDefinition::MaxAimPitchDegrees })
	{
		for (double Value : { -1.0, std::numeric_limits<double>::quiet_NaN(), std::numeric_limits<double>::infinity() })
		{
			Definition = NewObject<UAethelnChainTestAbility>(); Definition->ProvisionalSteps[0].*Field = Value;
			AddExpectedError(TEXT("Refused to grant ability"), EAutomationExpectedErrorFlags::Contains, 1);
			TestFalse(TEXT("Every negative/nonfinite authored time or pitch refuses at grant"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Definition)));
		}
	}
	Definition = NewObject<UAethelnChainTestAbility>(); Definition->ResetTags.Reset();
	AddExpectedError(TEXT("Refused to grant ability"), EAutomationExpectedErrorFlags::Contains, 1);
	TestFalse(TEXT("State.Dead reset cannot be removed by config"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Definition)));
	AddExpectedError(TEXT("Refused to grant ability"), EAutomationExpectedErrorFlags::Contains, 1);
	TestFalse(TEXT("Unset production chain has no usable grant"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(UAethelnBasicChainAbility::StaticClass())));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAttackChainProgressionTest,
	"Aetheln.GameCombat.AttackTimeline.ChainProgression",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAttackChainProgressionTest::RunTest(const FString& Parameters)
{
	using namespace AethelnChainTests;
	FFixture F; if (!F.Init(*this)) { return false; }
	TestEqual(TEXT("First press starts1"), F.Press(), EAethelnActivationResult::Accepted);
	TestEqual(TEXT("First record chooses step1"), F.Records[0].ChainStep, uint8(1));
	TestEqual(TEXT("Zero cooldown creates no lasting gameplay effect"), F.Player.AbilitySystem->GetActiveEffects(FGameplayEffectQuery()).Num(), 0);
	TestEqual(TEXT("An early press cannot spend"), F.Press(), EAethelnActivationResult::ActivationBlocked);
	TestEqual(TEXT("One real cost effect"), F.CostApplications, 1);
	TestEqual(TEXT("Cost changes actual Endurance once"), F.Endurance(), 28.0f);
	F.AdvanceTo(0.375);
	F.Ability->bFailCommitForTests = true;
	TestEqual(TEXT("Failed next-step commit refuses"), F.Press(), EAethelnActivationResult::InternalFailure);
	TestEqual(TEXT("Failed next-step commit spends nothing"), F.CostApplications, 1);
	TestTrue(TEXT("Failed next-step commit preserves prior recovery"), F.Player.AbilitySystem->GetChainStateForTests().bExists);
	TestEqual(TEXT("Failed commit emits no reset"), F.Ends.Num(), 0);
	F.Ability->bFailCommitForTests = false;
	FAethelnCombatActivationRequest Buffered = F.Request(F.NextSequence++);
	Buffered.Aim = FRotator(0.0, 30.0, 0.0).Vector();
	TestEqual(TEXT("Buffered press commits on arrival"), F.Player.AbilitySystem->ProcessServerRequest(Buffered), EAethelnActivationResult::Accepted);
	TestEqual(TEXT("A waiting press has no start record"), F.Records.Num(), 1);
	const uint32 AcceptedSequenceBeforeRefusal = F.Player.AbilitySystem->GetLastAcceptedSequenceForTests();
	const FVector AcceptedAimBeforeRefusal = F.Player.AbilitySystem->GetLastAcceptedAimForTests();
	const double AcceptedTimeBeforeRefusal = F.Player.AbilitySystem->GetLastAcceptedClientTimeForTests();
	const FGuid BufferedActivationBeforeRefusal = F.Player.AbilitySystem->GetChainStateForTests().BufferedInput.ActivationId;
	const float EnduranceBeforeRefusal = F.Endurance();
	const auto CheckBufferedRefusalState = [&]()
	{
		TestEqual(TEXT("A refused waiting press spends no cost"), F.CostApplications, 2);
		TestEqual(TEXT("A refused waiting press preserves Endurance"), F.Endurance(), EnduranceBeforeRefusal);
		TestEqual(TEXT("A refused waiting press publishes no start"), F.Records.Num(), 1);
		TestEqual(TEXT("A refused waiting press ends no chain"), F.Ends.Num(), 0);
		TestTrue(TEXT("A refused waiting press preserves the buffered wait"), F.Player.AbilitySystem->GetChainStateForTests().bWaiting);
		TestEqual(TEXT("A refused waiting press preserves the buffered activation"), F.Player.AbilitySystem->GetChainStateForTests().BufferedInput.ActivationId, BufferedActivationBeforeRefusal);
		TestEqual(TEXT("A refused waiting press preserves accepted sequence"), F.Player.AbilitySystem->GetLastAcceptedSequenceForTests(), AcceptedSequenceBeforeRefusal);
		TestTrue(TEXT("A refused waiting press preserves accepted raw aim"), F.Player.AbilitySystem->GetLastAcceptedAimForTests().Equals(AcceptedAimBeforeRefusal, 0.001));
		TestEqual(TEXT("A refused waiting press preserves accepted client time"), F.Player.AbilitySystem->GetLastAcceptedClientTimeForTests(), AcceptedTimeBeforeRefusal);
	};
	// The default raw aim is 0 at the same client time as the accepted raw 30-degree press.
	// Step 6d must reject that impossible transition before the waiting-activation gate.
	TestEqual(TEXT("A second press with impossible raw aim refuses before buffering"), F.Press(), EAethelnActivationResult::ImpossibleAimTransition);
	CheckBufferedRefusalState();
	FAethelnCombatActivationRequest SecondBuffered = F.Request(F.NextSequence++);
	SecondBuffered.Aim = Buffered.Aim;
	TestEqual(TEXT("A valid-aim second buffered press refuses"), F.Player.AbilitySystem->ProcessServerRequest(SecondBuffered), EAethelnActivationResult::ActivationBlocked);
	CheckBufferedRefusalState();
	TestEqual(TEXT("Replay does not commit"), F.Player.AbilitySystem->ProcessServerRequest(Buffered), EAethelnActivationResult::DuplicateSequence);
	TestEqual(TEXT("Exactly two cost effects"), F.CostApplications, 2);
	F.Player.Controller->SetControlRotation(FRotator(0.0, 60.0, 0.0));
	F.AdvanceTo(0.5);
	TestEqual(TEXT("Buffered start chooses2"), F.Records.Num(), 2);
	TestEqual(TEXT("Buffered start uses exact authored LinkOpen"), F.Records[1].StartServerTime, 0.5);
	TestTrue(TEXT("Buffered start uses corrected accepted press aim, not raw or later aim"), FVector(F.Records[1].AcceptedAim).Equals(FRotator(0.0, 20.0, 0.0).Vector(), 0.001));
	TestEqual(TEXT("Correction is carried to its record"), F.Records[1].AimCorrection, EAethelnAimCorrection::AimCorrected);
	F.AdvanceTo(1.0);
	TestEqual(TEXT("Link press starts immediately"), F.Press(), EAethelnActivationResult::Accepted);
	TestEqual(TEXT("Third record chooses3"), F.Records[2].ChainStep, uint8(3));
	TestEqual(TEXT("Immediate start uses server receipt time"), F.Records[2].StartServerTime, 1.0);
	TestTrue(TEXT("Each accepted step owns a new activation id"), F.Records[0].ActivationId != F.Records[1].ActivationId && F.Records[1].ActivationId != F.Records[2].ActivationId);
	TestEqual(TEXT("No final restart buffer"), F.Press(), EAethelnActivationResult::ActivationBlocked);
	F.AdvanceTo(1.625);
	TestEqual(TEXT("A press after final recovery restarts1"), F.Press(), EAethelnActivationResult::Accepted);
	TestEqual(TEXT("Restart record chooses1"), F.Records.Last().ChainStep, uint8(1));
	TestEqual(TEXT("Four accepted presses spend four times"), F.CostApplications, 4);
	TestEqual(TEXT("Actual Endurance matches accepted presses"), F.Endurance(), 22.0f);
	for (const TCHAR* Name : { TEXT("ClientCombatActivation"), TEXT("ClientChainEnded") })
	{
		const UFunction* Function = UAethelnAbilitySystemComponent::StaticClass()->FindFunctionByName(Name);
		if (TestNotNull(TEXT("Owner message is reflected"), Function))
		{
			TestTrue(TEXT("Owner message is a reliable client RPC"), Function->HasAllFunctionFlags(FUNC_Net | FUNC_NetClient | FUNC_NetReliable));
		}
	}
	TArray<FLifetimeProperty> Properties;
	UAethelnAbilitySystemComponent::StaticClass()->SetUpRuntimeReplicationData();
	F.Player.AbilitySystem->GetLifetimeReplicatedProps(Properties);
	const FProperty* Presentation = FindFProperty<FProperty>(UAethelnAbilitySystemComponent::StaticClass(), TEXT("AttackPresentationState"));
	if (TestNotNull(TEXT("Observer state is reflected"), Presentation))
	{
		const FLifetimeProperty* Lifetime = Properties.FindByPredicate([Presentation](const auto& P) { return P.RepIndex == Presentation->RepIndex; });
		if (TestNotNull(TEXT("Observer state is registered"), Lifetime)) { TestEqual(TEXT("Observer state skips owner"), Lifetime->Condition, COND_SkipOwner); }
	}
	TestEqual(TEXT("Opaque instigator id is stable within one ASC"), F.Records[0].InstigatorCombatId, F.Records.Last().InstigatorCombatId);
	TestTrue(TEXT("Opaque instigator id is nonzero"), F.Records[0].InstigatorCombatId != 0);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAttackChainResetsTest,
	"Aetheln.GameCombat.AttackTimeline.ChainResets",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAttackChainResetsTest::RunTest(const FString& Parameters)
{
	using namespace AethelnChainTests;
	FFixture F; if (!F.Init(*this)) { return false; }
	F.Press(); F.AdvanceTo(0.375); F.Press();
	F.AdvanceTo(0.4375);
	F.Player.AbilitySystem->ResetChain(EAethelnChainEndReason::Interrupted, 0.4375);
	F.Player.AbilitySystem->ResetChain(EAethelnChainEndReason::OtherAction, 0.4375);
	TestEqual(TEXT("Two reset paths emit one end"), F.Ends.Num(), 1);
	TestEqual(TEXT("First reason wins"), F.Ends.Last().Reason, EAethelnChainEndReason::Interrupted);
	TestEqual(TEXT("Reset preserves its server stamp"), F.Player.AbilitySystem->GetLastChainResetTimeForTests(), 0.4375);
	F.AdvanceTo(0.5);
	TestEqual(TEXT("Cancelled buffered activation never starts"), F.Records.Num(), 1);
	F.Press(); F.AdvanceTo(1.25);
	TestEqual(TEXT("Missing followup ends by timeout"), F.Ends.Last().Reason, EAethelnChainEndReason::Timeout);
	F.Press(); F.Player.AbilitySystem->AddLooseGameplayTag(AethelnGameplayTags::State_Dead);
	TestEqual(TEXT("Actual tag event resets incompatible chain"), F.Ends.Last().Reason, EAethelnChainEndReason::IncompatibleState);
	TestEqual(TEXT("Dead state refuses new activation"), F.Press(), EAethelnActivationResult::ActivationBlocked);
	F.Player.AbilitySystem->RemoveLooseGameplayTag(AethelnGameplayTags::State_Dead);
	F.Press(); F.Player.Controller->UnPossess();
	TestEqual(TEXT("Actual null-avatar lifecycle emits AvatarLost"), F.Ends.Last().Reason, EAethelnChainEndReason::AvatarLost);
	F.Player.AbilitySystem->CancelAllAbilities();
	TestEqual(TEXT("Existing CancelAll after AvatarLost cannot emit a second end"), F.Ends.Num(), 4);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAttackCommitmentTest,
	"Aetheln.GameCombat.AttackTimeline.CommitmentWindow",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAttackCommitmentTest::RunTest(const FString& Parameters)
{
	AethelnChainTests::FFixture F; if (!F.Init(*this)) { return false; }
	const FGameplayAbilitySpecHandle OtherHandle = F.Player.AbilitySystem->GiveAbility(FGameplayAbilitySpec(UAethelnCommitmentProbeTestAbility::StaticClass()));
	UAethelnSeamProbeTestAbility* Other = Cast<UAethelnSeamProbeTestAbility>(F.Player.AbilitySystem->FindAbilitySpecFromHandle(OtherHandle)->GetPrimaryInstance());
	F.Press();
	TestTrue(TEXT("Commitment starts at0"), F.Player.AbilitySystem->HasMatchingGameplayTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain));
	F.AdvanceTo(0.484375);
	TestTrue(TEXT("Commitment survives GAS end until CancelOpen"), F.Player.AbilitySystem->HasMatchingGameplayTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain));
	FAethelnCombatActivationRequest Request = F.Request(F.NextSequence++); Request.AbilityId = Other->GetAbilityId();
	TestEqual(TEXT("Blocked other action refuses before CancelOpen"), F.Player.AbilitySystem->ProcessServerRequest(Request), EAethelnActivationResult::ActivationBlocked);
	F.AdvanceTo(0.5);
	TestFalse(TEXT("Commitment ends at exact CancelOpen"), F.Player.AbilitySystem->HasMatchingGameplayTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain));
	Other->bTestFailCommit = true;
	Request = F.Request(F.NextSequence++); Request.AbilityId = Other->GetAbilityId();
	TestEqual(TEXT("Ultimately failed other commit reports failure"), F.Player.AbilitySystem->ProcessServerRequest(Request), EAethelnActivationResult::InternalFailure);
	TestEqual(TEXT("Failed commit does not reset chain"), F.Ends.Num(), 0);
	Other->bTestFailCommit = false;
	Request = F.Request(F.NextSequence++); Request.AbilityId = Other->GetAbilityId();
	TestEqual(TEXT("Successful action is eligible after commitment"), F.Player.AbilitySystem->ProcessServerRequest(Request), EAethelnActivationResult::Accepted);
	TestEqual(TEXT("Successful committed other action resets"), F.Ends.Last().Reason, EAethelnChainEndReason::OtherAction);
	TestEqual(TEXT("OtherAction uses processing time"), F.Player.AbilitySystem->GetLastChainResetTimeForTests(), 0.5);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAttackCommitmentReentrancyTest,
	"Aetheln.GameCombat.AttackTimeline.CommitmentReentrancy",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAttackCommitmentReentrancyTest::RunTest(const FString& Parameters)
{
	using namespace AethelnChainTests;
	const FGameplayTag Commitment = AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain;
	// Removing step one's owned count invokes an actual synchronous GAS delegate.
	for (bool bKeepIndependentCount : { false, true })
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		TestEqual(TEXT("Removal fixture starts first step"), F.Press(), EAethelnActivationResult::Accepted);
		F.AdvanceTo(0.375);
		TestEqual(TEXT("Removal fixture accepts buffered press"), F.Press(), EAethelnActivationResult::Accepted);
		bool bResetTriggered = false;
		const FDelegateHandle Listener = F.Player.AbilitySystem->RegisterGameplayTagEvent(Commitment, EGameplayTagEventType::NewOrRemoved).AddLambda(
			[&F, &bResetTriggered, bKeepIndependentCount, Commitment](const FGameplayTag, int32 Count)
			{
				if (Count == 0 && !bResetTriggered)
				{
					bResetTriggered = true;
					F.Player.AbilitySystem->ResetChain(EAethelnChainEndReason::Interrupted);
					// A different owner acquires a count during the callback; abort must not remove it.
					if (bKeepIndependentCount) { F.Player.AbilitySystem->AddLooseGameplayTag(Commitment); }
				}
			});
		F.AdvanceTo(0.5);
		F.Player.AbilitySystem->RegisterGameplayTagEvent(Commitment, EGameplayTagEventType::NewOrRemoved).Remove(Listener);
		TestTrue(TEXT("Removal callback actually reset the chain"), bResetTriggered);
		TestEqual(TEXT("Removal reset sends exactly one end"), F.Ends.Num(), 1);
		if (F.Ends.Num() == 1) { TestEqual(TEXT("Removal retains first end reason"), F.Ends[0].Reason, EAethelnChainEndReason::Interrupted); }
		TestEqual(TEXT("Removal reset sends no buffered start"), F.Records.Num(), 1);
		TestFalse(TEXT("Removal reset leaves no chain"), F.Player.AbilitySystem->GetChainStateForTests().bExists);
		TestFalse(TEXT("Removal reset leaves no active descriptor"), F.Player.AbilitySystem->GetAttackPresentationState().bActive);
		TestEqual(TEXT("Removal reset preserves its exact server stamp"), F.Player.AbilitySystem->GetLastChainResetTimeForTests(), 0.5);
		TestEqual(TEXT("Removal abort releases only its own commitment"), F.Player.AbilitySystem->GetTagCount(Commitment), bKeepIndependentCount ? 1 : 0);
		TestEqual(TEXT("Normal world pass removes original and aborted entries"), F.Timeline->GetRegisteredStepCountForTests(), 0);
		if (bKeepIndependentCount) { F.Player.AbilitySystem->RemoveLooseGameplayTag(Commitment); }
		TestEqual(TEXT("No commitment remains after independent owner releases"), F.Player.AbilitySystem->GetTagCount(Commitment), 0);
	}
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		bool bResetTriggered = false;
		const FDelegateHandle Listener = F.Player.AbilitySystem->RegisterGameplayTagEvent(Commitment, EGameplayTagEventType::NewOrRemoved).AddLambda(
			[&F, &bResetTriggered](const FGameplayTag, int32 Count)
			{
				if (Count > 0 && !bResetTriggered)
				{
					bResetTriggered = true;
					F.Player.AbilitySystem->ResetChain(EAethelnChainEndReason::Interrupted);
				}
			});
		TestEqual(TEXT("Reset during initial addition aborts startup"), F.Press(), EAethelnActivationResult::InternalFailure);
		F.Player.AbilitySystem->RegisterGameplayTagEvent(Commitment, EGameplayTagEventType::NewOrRemoved).Remove(Listener);
		TestTrue(TEXT("Addition callback actually reset the chain"), bResetTriggered);
		TestEqual(TEXT("Addition reset sends exactly one end"), F.Ends.Num(), 1);
		if (F.Ends.Num() == 1)
		{
			TestEqual(TEXT("Addition retains first end reason"), F.Ends[0].Reason, EAethelnChainEndReason::Interrupted);
			TestTrue(TEXT("Addition reset identifies the accepted activation"), F.Ends[0].ActivationId.IsValid());
		}
		TestEqual(TEXT("Addition reset sends no start record"), F.Records.Num(), 0);
		TestFalse(TEXT("Addition reset leaves no chain"), F.Player.AbilitySystem->GetChainStateForTests().bExists);
		TestFalse(TEXT("Addition reset leaves no active descriptor"), F.Player.AbilitySystem->GetAttackPresentationState().bActive);
		TestEqual(TEXT("Addition reset leaves no commitment"), F.Player.AbilitySystem->GetTagCount(Commitment), 0);
		F.AdvanceTo(0.0625);
		TestEqual(TEXT("Normal pass removes the aborted initial entry"), F.Timeline->GetRegisteredStepCountForTests(), 0);
	}
	// The old startup must not end a newer activation of the same GAS instance/handle.
	for (bool bBuffered : { false, true })
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		if (bBuffered)
		{
			TestEqual(TEXT("Replacement fixture starts first step"), F.Press(), EAethelnActivationResult::Accepted);
			F.AdvanceTo(0.375);
			TestEqual(TEXT("Replacement fixture accepts buffered press"), F.Press(), EAethelnActivationResult::Accepted);
		}
		bool bResetTriggered = false;
		bool bReplacementRequested = false;
		EAethelnActivationResult ReplacementResult = EAethelnActivationResult::InternalFailure;
		FGuid EndedActivationId;
		FGuid ReplacementActivationId;
		const FDelegateHandle EndListener = F.Player.AbilitySystem->OnChainEnded.AddLambda(
			[&F, &bReplacementRequested, &ReplacementResult, &EndedActivationId, &ReplacementActivationId](const FGuid& Id, EAethelnChainEndReason)
			{
				if (!bReplacementRequested)
				{
					bReplacementRequested = true;
					EndedActivationId = Id;
					ReplacementResult = F.Press();
					ReplacementActivationId = F.Ability->GetActivationId();
				}
			});
		const FDelegateHandle TagListener = F.Player.AbilitySystem->RegisterGameplayTagEvent(Commitment, EGameplayTagEventType::NewOrRemoved).AddLambda(
			[&F, &bResetTriggered, bBuffered](const FGameplayTag, int32 Count)
			{
				if (!bResetTriggered && (bBuffered ? Count == 0 : Count > 0))
				{
					bResetTriggered = true;
					F.Player.AbilitySystem->ResetChain(EAethelnChainEndReason::Interrupted);
				}
			});
		if (bBuffered) { F.AdvanceTo(0.5); }
		else { TestEqual(TEXT("Replaced original startup still reports its failure"), F.Press(), EAethelnActivationResult::InternalFailure); }
		F.Player.AbilitySystem->RegisterGameplayTagEvent(Commitment, EGameplayTagEventType::NewOrRemoved).Remove(TagListener);
		F.Player.AbilitySystem->OnChainEnded.Remove(EndListener);
		TestTrue(TEXT("Replacement control exercised the reset callback"), bResetTriggered);
		TestTrue(TEXT("Replacement control submitted a newer press"), bReplacementRequested);
		TestEqual(TEXT("Newer same-handle request is accepted"), ReplacementResult, EAethelnActivationResult::Accepted);
		TestTrue(TEXT("Replacement GUID is valid and distinct"), ReplacementActivationId.IsValid() && ReplacementActivationId != EndedActivationId);
		TestEqual(TEXT("Original reset emits exactly one end"), F.Ends.Num(), 1);
		if (F.Ends.Num() == 1) { TestEqual(TEXT("Original reset keeps Interrupted reason"), F.Ends[0].Reason, EAethelnChainEndReason::Interrupted); }
		TestTrue(TEXT("Replacement GAS instance remains active"), F.Ability->IsActive());
		TestTrue(TEXT("Replacement same-handle spec remains active"), F.Player.AbilitySystem->FindAbilitySpecFromHandle(F.Handle)->IsActive());
		TestEqual(TEXT("Replacement instance keeps its activation GUID"), F.Ability->GetActivationId(), ReplacementActivationId);
		TestTrue(TEXT("Replacement chain survives original caller"), F.Player.AbilitySystem->GetChainStateForTests().bExists);
		TestEqual(TEXT("Replacement chain owns its accepted GUID"), F.Player.AbilitySystem->GetChainStateForTests().CurrentInput.ActivationId, ReplacementActivationId);
		TestEqual(TEXT("Replacement restarts at first step"), F.Player.AbilitySystem->GetChainStateForTests().Step, uint8(1));
		TestTrue(TEXT("Replacement descriptor remains active"), F.Player.AbilitySystem->GetAttackPresentationState().bActive);
		TestEqual(TEXT("Original caller preserves replacement commitment"), F.Player.AbilitySystem->GetTagCount(Commitment), 1);
		TestEqual(TEXT("Only actual old/replacement starts are published"), F.Records.Num(), bBuffered ? 2 : 1);
		if (!F.Records.IsEmpty()) { TestEqual(TEXT("Last record belongs to replacement"), F.Records.Last().ActivationId, ReplacementActivationId); }
		F.AdvanceTo(bBuffered ? 0.5625 : 0.0625);
		TestEqual(TEXT("Normal pass retains only the replacement entry"), F.Timeline->GetRegisteredStepCountForTests(), 1);
	}
	{
		// Super::EndAbility's real ASC delegate runs before the project end override resumes.
		FFixture F; if (!F.Init(*this)) { return false; }
		F.Press(); F.AdvanceTo(0.375); F.Press();
		bool bReplacementRequested = false;
		EAethelnActivationResult ReplacementResult = EAethelnActivationResult::InternalFailure;
		FGuid ReplacementActivationId;
		const FDelegateHandle Listener = F.Player.AbilitySystem->OnAbilityEnded.AddLambda(
			[&F, &bReplacementRequested, &ReplacementResult, &ReplacementActivationId](const FAbilityEndedData& Ended)
			{
				if (!bReplacementRequested && Ended.bWasCancelled && Ended.AbilitySpecHandle == F.Handle)
				{
					bReplacementRequested = true;
					ReplacementResult = F.Press();
					ReplacementActivationId = F.Ability->GetActivationId();
				}
			});
		F.Player.AbilitySystem->ResetChain(EAethelnChainEndReason::Interrupted);
		F.Player.AbilitySystem->OnAbilityEnded.Remove(Listener);
		TestTrue(TEXT("Real GAS ended callback submitted replacement"), bReplacementRequested);
		TestEqual(TEXT("GAS ended callback replacement is accepted"), ReplacementResult, EAethelnActivationResult::Accepted);
		TestEqual(TEXT("Project end continuation cannot reset replacement"), F.Ends.Num(), 1);
		if (F.Ends.Num() == 1) { TestEqual(TEXT("GAS callback retains original end reason"), F.Ends[0].Reason, EAethelnChainEndReason::Interrupted); }
		TestTrue(TEXT("Replacement survives project EndAbility continuation"), F.Ability->IsActive() && F.Player.AbilitySystem->GetChainStateForTests().bExists);
		TestEqual(TEXT("GAS callback replacement keeps current GUID"), F.Player.AbilitySystem->GetChainStateForTests().CurrentInput.ActivationId, ReplacementActivationId);
		TestTrue(TEXT("GAS callback replacement descriptor is active"), F.Player.AbilitySystem->GetAttackPresentationState().bActive);
		TestEqual(TEXT("GAS callback replacement holds one commitment"), F.Player.AbilitySystem->GetTagCount(Commitment), 1);
		F.AdvanceTo(0.4375);
		TestEqual(TEXT("GAS callback normal pass retains only replacement entry"), F.Timeline->GetRegisteredStepCountForTests(), 1);
	}
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		int32 Added = 0;
		int32 Removed = 0;
		const FDelegateHandle Listener = F.Player.AbilitySystem->RegisterGameplayTagEvent(Commitment, EGameplayTagEventType::NewOrRemoved).AddLambda(
			[&Added, &Removed](const FGameplayTag, int32 Count) { if (Count > 0) { ++Added; } else { ++Removed; } });
		TestEqual(TEXT("Positive control starts first step"), F.Press(), EAethelnActivationResult::Accepted);
		F.AdvanceTo(0.375);
		TestEqual(TEXT("Positive control accepts buffered step"), F.Press(), EAethelnActivationResult::Accepted);
		F.AdvanceTo(0.5);
		F.Player.AbilitySystem->RegisterGameplayTagEvent(Commitment, EGameplayTagEventType::NewOrRemoved).Remove(Listener);
		TestEqual(TEXT("Positive control observes both tag additions"), Added, 2);
		TestEqual(TEXT("Positive control observes old commitment removal"), Removed, 1);
		TestEqual(TEXT("Positive control publishes step two"), F.Records.Num(), 2);
		if (F.Records.Num() == 2) { TestEqual(TEXT("Positive control keeps exact LinkOpen"), F.Records[1].StartServerTime, 0.5); }
		TestEqual(TEXT("Positive control emits no premature end"), F.Ends.Num(), 0);
		TestTrue(TEXT("Positive control retains active chain"), F.Player.AbilitySystem->GetChainStateForTests().bExists);
		TestTrue(TEXT("Positive control retains active descriptor"), F.Player.AbilitySystem->GetAttackPresentationState().bActive);
		TestEqual(TEXT("Positive control holds one commitment"), F.Player.AbilitySystem->GetTagCount(Commitment), 1);
		TestEqual(TEXT("Positive control retains only its current entry"), F.Timeline->GetRegisteredStepCountForTests(), 1);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAttackSynchronousOperationTest,
	"Aetheln.GameCombat.AttackTimeline.SynchronousOperationOwnership",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAttackSynchronousOperationTest::RunTest(const FString& Parameters)
{
	using namespace AethelnChainTests;
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		bool bNested = false;
		EAethelnActivationResult Nested = EAethelnActivationResult::InternalFailure;
		const FDelegateHandle Listener = F.Player.AbilitySystem->AbilityActivatedCallbacks.AddLambda([&](UGameplayAbility* Ability)
			{
				if (Ability == F.Ability && !bNested) { bNested = true; Nested = F.Press(); }
			});
		TestEqual(TEXT("Original preactivation commits normally"), F.Press(), EAethelnActivationResult::Accepted);
		F.Player.AbilitySystem->AbilityActivatedCallbacks.Remove(Listener);
		TestTrue(TEXT("Real PreActivate callback attempted same-instance reentry"), bNested);
		TestEqual(TEXT("PreActivate's active instance refuses reentry before spend"), Nested, EAethelnActivationResult::ActivationBlocked);
		TestEqual(TEXT("No orphan second stock active count"), F.Player.AbilitySystem->FindAbilitySpecFromHandle(F.Handle)->ActiveCount, uint8(1));
		TestEqual(TEXT("PreActivate reentry applies one legitimate cost"), F.CostApplications, 1);
		TestEqual(TEXT("PreActivate reentry publishes one legitimate record"), F.Records.Num(), 1);
		F.AdvanceTo(0.375);
		TestEqual(TEXT("Refused scoped sequence can retry after its reservation releases"), F.Player.AbilitySystem->ProcessServerRequest(F.Request(2)), EAethelnActivationResult::Accepted);
		TestEqual(TEXT("Retry spends exactly once"), F.CostApplications, 2);
	}
	for (bool bCostCallback : { false, true })
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		F.Press(); F.AdvanceTo(0.375);
		bool bInterrupted = false;
		bool bReplacement = false;
		EAethelnActivationResult Nested = EAethelnActivationResult::InternalFailure;
		FGuid ReplacementId;
		TArray<FGuid> CostOperations;
		const FDelegateHandle EndListener = F.Player.AbilitySystem->OnChainEnded.AddLambda([&](const FGuid&, EAethelnChainEndReason)
			{
				if (!bReplacement) { bReplacement = true; Nested = F.Press(); ReplacementId = F.Ability->GetActivationId(); }
			});
		auto Interrupt = [&]() { if (!bInterrupted) { bInterrupted = true; F.Player.AbilitySystem->ResetChain(EAethelnChainEndReason::Interrupted); } };
		const FDelegateHandle CommitListener = F.Player.AbilitySystem->AbilityCommittedCallbacks.AddLambda([&](UGameplayAbility* Ability)
			{
				if (!bCostCallback && Ability == F.Ability) { Interrupt(); }
			});
		const FDelegateHandle CostListener = F.Player.AbilitySystem->OnGameplayEffectAppliedDelegateToSelf.AddLambda(
			[&](UAbilitySystemComponent*, const FGameplayEffectSpec& Spec, FActiveGameplayEffectHandle)
			{
				if (Spec.Def != nullptr && Spec.Def->IsA<UAethelnEnduranceCostEffect>())
				{
					CostOperations.Add(F.Ability->GetOperationIdForTests());
					if (bCostCallback) { Interrupt(); }
				}
			});
		TestEqual(TEXT("Interrupted old committed startup does not join replacement"), F.Press(), EAethelnActivationResult::InternalFailure);
		F.Player.AbilitySystem->AbilityCommittedCallbacks.Remove(CommitListener);
		F.Player.AbilitySystem->OnGameplayEffectAppliedDelegateToSelf.Remove(CostListener);
		F.Player.AbilitySystem->OnChainEnded.Remove(EndListener);
		TestTrue(TEXT("Actual commit or self-effect callback interrupted original operation"), bInterrupted && bReplacement);
		TestEqual(TEXT("Post-cancel replacement is accepted"), Nested, EAethelnActivationResult::Accepted);
		TestTrue(TEXT("Replacement has a committed server GUID"), ReplacementId.IsValid());
		TestEqual(TEXT("Old commit continuation preserves replacement GUID"), F.Ability->GetActivationId(), ReplacementId);
		TestTrue(TEXT("Old commit continuation preserves replacement GAS instance"), F.Ability->IsActive());
		TestEqual(TEXT("No orphan active count after commit reentry"), F.Player.AbilitySystem->FindAbilitySpecFromHandle(F.Handle)->ActiveCount, uint8(1));
		TestEqual(TEXT("Replacement chain retains its own GUID"), F.Player.AbilitySystem->GetChainStateForTests().CurrentInput.ActivationId, ReplacementId);
		TestFalse(TEXT("Old committed input is not buffered into replacement"), F.Player.AbilitySystem->GetChainStateForTests().bWaiting);
		TestEqual(TEXT("Each of three actual commit spends is retained, no refund inferred"), F.CostApplications, 3);
		TestEqual(TEXT("Actual resource reflects three physical fixture costs"), F.Endurance(), 24.0f);
		TestEqual(TEXT("Two callback costs have immutable distinct operation IDs"), CostOperations.Num(), 2);
		if (CostOperations.Num() == 2) { TestTrue(TEXT("Each callback cost belongs to a valid distinct server operation"), CostOperations[0].IsValid() && CostOperations[1].IsValid() && CostOperations[0] != CostOperations[1]); }
		TestEqual(TEXT("Only original step and replacement publish starts"), F.Records.Num(), 2);
		if (F.Records.Num() == 2) { TestEqual(TEXT("Published replacement and current GUID agree"), F.Records.Last().ActivationId, ReplacementId); }
		TestEqual(TEXT("Old interruption emits exactly one end"), F.Ends.Num(), 1);
		TestEqual(TEXT("Replacement owns one commitment"), F.Player.AbilitySystem->GetTagCount(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain), 1);
		F.AdvanceTo(0.4375);
		TestEqual(TEXT("Only replacement timeline entry remains"), F.Timeline->GetRegisteredStepCountForTests(), 1);
	}
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		AAethelnPlayerCharacter* Replacement = F.World.Spawn<AAethelnPlayerCharacter>();
		if (!TestNotNull(TEXT("Lifecycle callback replacement pawn exists"), Replacement)) { return false; }
		bool bRepossessed = false;
		const FDelegateHandle Listener = F.Player.AbilitySystem->AbilityActivatedCallbacks.AddLambda([&](UGameplayAbility* Ability)
			{
				if (Ability == F.Ability && !bRepossessed) { bRepossessed = true; F.Player.Controller->Possess(Replacement); }
			});
		TestEqual(TEXT("Old PreActivate frame refuses a changed avatar before spend"), F.Press(), EAethelnActivationResult::InternalFailure);
		F.Player.AbilitySystem->AbilityActivatedCallbacks.Remove(Listener);
		TestTrue(TEXT("Actual activation callback changed possession"), bRepossessed);
		TestEqual(TEXT("ASC has replacement avatar"), F.Player.AbilitySystem->GetAvatarActor(), static_cast<AActor*>(Replacement));
		TestEqual(TEXT("Old avatar continuation applies no cost"), F.CostApplications, 0);
		TestEqual(TEXT("Old avatar continuation publishes no attack"), F.Records.Num(), 0);
		TestFalse(TEXT("Old avatar continuation leaves no chain"), F.Player.AbilitySystem->GetChainStateForTests().bExists);
		TestFalse(TEXT("Own failed epoch cleans up GAS"), F.Ability->IsActive());
		TestEqual(TEXT("Replacement avatar may retry the failed sequence"), F.Player.AbilitySystem->ProcessServerRequest(F.Request(1)), EAethelnActivationResult::Accepted);
		TestEqual(TEXT("Valid replacement avatar applies its own cost once"), F.CostApplications, 1);
	}
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		F.Press(); F.AdvanceTo(0.375);
		bool bReplacement = false;
		EAethelnActivationResult Nested = EAethelnActivationResult::InternalFailure;
		FGuid ReplacementId;
		const FGameplayTag Commitment = AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain;
		const FDelegateHandle Listener = F.Player.AbilitySystem->RegisterGameplayTagEvent(Commitment, EGameplayTagEventType::NewOrRemoved).AddLambda(
			[&](const FGameplayTag, int32 Count)
			{
				if (Count == 0 && !bReplacement) { bReplacement = true; Nested = F.Press(); ReplacementId = F.Ability->GetActivationId(); }
			});
		F.Player.AbilitySystem->ResetChain(EAethelnChainEndReason::Interrupted);
		F.Player.AbilitySystem->RegisterGameplayTagEvent(Commitment, EGameplayTagEventType::NewOrRemoved).Remove(Listener);
		TestEqual(TEXT("Recovery removal callback accepts replacement"), Nested, EAethelnActivationResult::Accepted);
		TestTrue(TEXT("Inactive old chain never authorizes cancel of new GAS activation"), F.Ability->IsActive());
		TestEqual(TEXT("Standalone reset preserves replacement GUID"), F.Player.AbilitySystem->GetChainStateForTests().CurrentInput.ActivationId, ReplacementId);
		TestEqual(TEXT("Standalone reset sends only copied old end"), F.Ends.Num(), 1);
		TestEqual(TEXT("Standalone reset leaves replacement owned count"), F.Player.AbilitySystem->GetTagCount(Commitment), 1);
		TestEqual(TEXT("Standalone reset adds only replacement's one cost"), F.CostApplications, 2);
		F.AdvanceTo(0.4375);
		TestEqual(TEXT("Standalone reset normal pass leaves one entry"), F.Timeline->GetRegisteredStepCountForTests(), 1);
	}
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		F.Ability->bFailCommitForTests = true;
		TestEqual(TEXT("Failed commit remains a genuine failure"), F.Press(), EAethelnActivationResult::InternalFailure);
		TestFalse(TEXT("Failed commit exposes no committed GUID"), F.Ability->GetActivationId().IsValid());
		TestEqual(TEXT("Failed commit spends no resource"), F.CostApplications, 0);
		F.Ability->bFailCommitForTests = false;
		TestEqual(TEXT("Failed sequence can retry without persistent acceptance"), F.Player.AbilitySystem->ProcessServerRequest(F.Request(1)), EAethelnActivationResult::Accepted);
		TestEqual(TEXT("Valid retry applies one cost"), F.CostApplications, 1);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAttackSynchronousRequestTest,
	"Aetheln.GameCombat.AttackTimeline.SynchronousRequestAdmission",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAttackSynchronousRequestTest::RunTest(const FString& Parameters)
{
	using namespace AethelnChainTests;
	for (int32 Variant : { 0, 1, 2 })
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		if (Variant == 2) { F.Player.AbilitySystem->ProvisionalActivationBucketCapacity = 1.0f; }
		const FAethelnCombatActivationRequest Original = F.Request(F.NextSequence++);
		FAethelnCombatActivationRequest NestedRequest = Original;
		if (Variant == 1) { NestedRequest.Sequence = F.NextSequence++; NestedRequest.Aim = FRotator(0.0, 1.0, 0.0).Vector(); }
		bool bInterrupted = false;
		bool bSubmitted = false;
		EAethelnActivationResult Nested = EAethelnActivationResult::InternalFailure;
		const FDelegateHandle EndListener = F.Player.AbilitySystem->OnChainEnded.AddLambda([&](const FGuid&, EAethelnChainEndReason)
			{
				if (!bSubmitted) { bSubmitted = true; Nested = F.Player.AbilitySystem->ProcessServerRequest(NestedRequest); }
			});
		const FDelegateHandle RecordListener = F.Player.AbilitySystem->OnCombatActivation.AddLambda([&](const FAethelnCombatActivationRecord&)
			{
				if (!bInterrupted) { bInterrupted = true; F.Player.AbilitySystem->ResetChain(EAethelnChainEndReason::Interrupted); }
			});
		TestEqual(TEXT("Already published original retains its accepted outcome"), F.Player.AbilitySystem->ProcessServerRequest(Original), EAethelnActivationResult::Accepted);
		F.Player.AbilitySystem->OnCombatActivation.Remove(RecordListener);
		F.Player.AbilitySystem->OnChainEnded.Remove(EndListener);
		TestTrue(TEXT("Actual owner record/end callbacks ran"), bInterrupted && bSubmitted);
		TestEqual(TEXT("In-flight replay/newer/rate-first outcome"), Nested, Variant == 1 ? EAethelnActivationResult::Accepted : Variant == 2 ? EAethelnActivationResult::RateLimited : EAethelnActivationResult::DuplicateSequence);
		TestEqual(TEXT("Only legitimate published requests spend"), F.CostApplications, Variant == 1 ? 2 : 1);
		TestEqual(TEXT("Only legitimate published requests have records"), F.Records.Num(), Variant == 1 ? 2 : 1);
		if (Variant == 1)
		{
			TestEqual(TEXT("Older Finish cannot regress accepted sequence"), F.Player.AbilitySystem->GetLastAcceptedSequenceForTests(), NestedRequest.Sequence);
			TestTrue(TEXT("Older Finish cannot regress raw accepted aim"), F.Player.AbilitySystem->GetLastAcceptedAimForTests().Equals(NestedRequest.Aim, 0.0001));
			TestEqual(TEXT("Accepted time belongs to the same latest tuple"), F.Player.AbilitySystem->GetLastAcceptedClientTimeForTests(), NestedRequest.ClientServerTimeSeconds);
			TestEqual(TEXT("Newer acceptance still rejects exact replay"), F.Player.AbilitySystem->ProcessServerRequest(NestedRequest), EAethelnActivationResult::DuplicateSequence);
			TestTrue(TEXT("Record callback replacement remains active"), F.Ability->IsActive());
		}
	}
	for (bool bLosePossession : { false, true })
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		const FGameplayAbilitySpecHandle OtherHandle = F.Player.AbilitySystem->GiveAbility(FGameplayAbilitySpec(UAethelnSeamProbeTestAbility::StaticClass()));
		UAethelnSeamProbeTestAbility* Other = Cast<UAethelnSeamProbeTestAbility>(F.Player.AbilitySystem->FindAbilitySpecFromHandle(OtherHandle)->GetPrimaryInstance());
		F.Press();
		// Real TimeOnly tick advances the server clock without the post-actor timeline pass.
		F.World.World->Tick(LEVELTICK_TimeOnly, 0.75f);
		bool bBoundaryCallback = false;
		EAethelnActivationResult Nested = EAethelnActivationResult::InternalFailure;
		const FDelegateHandle Listener = F.Player.AbilitySystem->OnChainEnded.AddLambda([&](const FGuid&, EAethelnChainEndReason)
			{
				if (!bBoundaryCallback)
				{
					bBoundaryCallback = true;
					if (bLosePossession) { F.Player.Controller->UnPossess(); }
					else { Nested = F.Player.AbilitySystem->ProcessServerRequest(F.Request(3)); }
				}
			});
		FAethelnCombatActivationRequest Older = F.Request(2); Older.AbilityId = Other->GetAbilityId();
		TestEqual(TEXT("Validation recaptures boundary sequence and lifecycle"), F.Player.AbilitySystem->ProcessServerRequest(Older), bLosePossession ? EAethelnActivationResult::ConnectionClosed : EAethelnActivationResult::StaleSequence);
		F.Player.AbilitySystem->OnChainEnded.Remove(Listener);
		TestTrue(TEXT("Real authored boundary triggered callback"), bBoundaryCallback);
		TestEqual(TEXT("Stale or detached request cannot spend another ability"), Other->CostApplications, 0);
		TestEqual(TEXT("Stale or detached request cannot commit cooldown"), Other->CooldownApplications, 0);
		if (!bLosePossession)
		{
			TestEqual(TEXT("Boundary newer request is accepted"), Nested, EAethelnActivationResult::Accepted);
			TestEqual(TEXT("Boundary newer accepted history survives"), F.Player.AbilitySystem->GetLastAcceptedSequenceForTests(), uint32(3));
			TestTrue(TEXT("Boundary newer chain remains active"), F.Ability->IsActive());
		}
	}
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		const FGameplayAbilitySpecHandle OtherHandle = F.Player.AbilitySystem->GiveAbility(FGameplayAbilitySpec(UAethelnSeamProbeTestAbility::StaticClass()));
		UAethelnSeamProbeTestAbility* Other = Cast<UAethelnSeamProbeTestAbility>(F.Player.AbilitySystem->FindAbilitySpecFromHandle(OtherHandle)->GetPrimaryInstance());
		FAethelnCombatActivationRequest Press = F.Request(1); Press.AbilityId = Other->GetAbilityId();
		TestEqual(TEXT("Release control starts real GAS activation"), F.Player.AbilitySystem->ProcessServerRequest(Press), EAethelnActivationResult::Accepted);
		FAethelnCombatActivationRequest Newer = Press; Newer.Sequence = 3; Newer.Aim = FRotator(0.0, 1.0, 0.0).Vector();
		bool bSubmitted = false;
		EAethelnActivationResult Nested = EAethelnActivationResult::InternalFailure;
		const FDelegateHandle Listener = F.Player.AbilitySystem->OnAbilityEnded.AddLambda([&](const FAbilityEndedData& Data)
			{
				if (Data.AbilityThatEnded == Other && !bSubmitted)
				{
					bSubmitted = true; Nested = F.Player.AbilitySystem->ProcessServerRequest(Newer);
				}
			});
		FAethelnCombatActivationRequest Release = Press; Release.Sequence = 2; Release.Phase = EAethelnActivationPhase::Release;
		TestEqual(TEXT("Original release remains accepted"), F.Player.AbilitySystem->ProcessServerRequest(Release), EAethelnActivationResult::Accepted);
		F.Player.AbilitySystem->OnAbilityEnded.Remove(Listener);
		TestEqual(TEXT("Release end callback accepts replacement"), Nested, EAethelnActivationResult::Accepted);
		TestTrue(TEXT("Release continuation preserves replacement GAS"), Other->IsActive());
		TestEqual(TEXT("Older release cannot regress latest accepted sequence"), F.Player.AbilitySystem->GetLastAcceptedSequenceForTests(), Newer.Sequence);
		TestTrue(TEXT("Older release cannot regress latest raw aim"), F.Player.AbilitySystem->GetLastAcceptedAimForTests().Equals(Newer.Aim, 0.0001));
		TestEqual(TEXT("Release performs no additional cost"), Other->CostApplications, 2);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAttackReleaseCommitReentrancyTest,
	"Aetheln.GameCombat.AttackTimeline.ReleaseAndCommitReentrancy",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAttackReleaseCommitReentrancyTest::RunTest(const FString& Parameters)
{
	using namespace AethelnChainTests;
	for (bool bAtCommit : { false, true })
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		const FGameplayAbilitySpecHandle Handle = F.Player.AbilitySystem->GiveAbility(FGameplayAbilitySpec(UAethelnSeamProbeTestAbility::StaticClass()));
		UAethelnSeamProbeTestAbility* Ability = Cast<UAethelnSeamProbeTestAbility>(F.Player.AbilitySystem->FindAbilitySpecFromHandle(Handle)->GetPrimaryInstance());
		FAethelnCombatActivationRequest Press = F.Request(1); Press.AbilityId = Ability->GetAbilityId();
		FAethelnCombatActivationRequest Release = Press; Release.Sequence = 2; Release.Phase = EAethelnActivationPhase::Release;
		bool bNested = false;
		bool bSpecActiveAtCallback = true;
		bool bGuidValidAtCallback = true;
		EAethelnActivationResult Nested = EAethelnActivationResult::InternalFailure;
		uint32 AcceptedAtCallback = 99;
		auto TryRelease = [&](UGameplayAbility* Activated)
			{
				if (Activated == Ability && !bNested)
				{
					bNested = true;
					bSpecActiveAtCallback = F.Player.AbilitySystem->FindAbilitySpecFromHandle(Handle)->IsActive();
					bGuidValidAtCallback = Ability->GetActivationId().IsValid();
					Nested = F.Player.AbilitySystem->ProcessServerRequest(Release);
					AcceptedAtCallback = F.Player.AbilitySystem->GetLastAcceptedSequenceForTests();
				}
			};
		const FDelegateHandle ActivatedListener = F.Player.AbilitySystem->AbilityActivatedCallbacks.AddLambda([&](UGameplayAbility* Activated) { if (!bAtCommit) { TryRelease(Activated); } });
		const FDelegateHandle CommitListener = F.Player.AbilitySystem->AbilityCommittedCallbacks.AddLambda([&](UGameplayAbility* Activated) { if (bAtCommit) { TryRelease(Activated); } });
		TestEqual(TEXT("Outer release-capable Press remains accepted"), F.Player.AbilitySystem->ProcessServerRequest(Press), EAethelnActivationResult::Accepted);
		F.Player.AbilitySystem->AbilityActivatedCallbacks.Remove(ActivatedListener);
		F.Player.AbilitySystem->AbilityCommittedCallbacks.Remove(CommitListener);
		TestTrue(TEXT("Real activation or commit callback attempted Release"), bNested);
		TestEqual(TEXT("Causal control: spec active only at commit callback"), bSpecActiveAtCallback, bAtCommit);
		TestFalse(TEXT("Causal control: operation has not committed yet"), bGuidValidAtCallback);
		TestEqual(TEXT("Unendable preactivation Release is refused"), Nested, EAethelnActivationResult::ActivationBlocked);
		TestEqual(TEXT("Refused Release does not advance accepted history"), AcceptedAtCallback, uint32(0));
		TestEqual(TEXT("Only outer Press advances accepted history"), F.Player.AbilitySystem->GetLastAcceptedSequenceForTests(), Press.Sequence);
		TestTrue(TEXT("Outer Press leaves its genuine committed epoch active"), Ability->IsActive() && Ability->GetActivationId().IsValid());
		TestEqual(TEXT("Outer Press has one active spec count"), F.Player.AbilitySystem->FindAbilitySpecFromHandle(Handle)->ActiveCount, uint8(1));
		TestEqual(TEXT("Outer Press commits one cost"), Ability->CostApplications, 1);
		TestEqual(TEXT("Outer Press commits one cooldown"), Ability->CooldownApplications, 1);
		TestEqual(TEXT("Same refused sequence may now release committed epoch"), F.Player.AbilitySystem->ProcessServerRequest(Release), EAethelnActivationResult::Accepted);
		TestFalse(TEXT("Valid committed Release actually ends GAS"), Ability->IsActive());
		TestEqual(TEXT("Valid Release advances history"), F.Player.AbilitySystem->GetLastAcceptedSequenceForTests(), Release.Sequence);
		TestEqual(TEXT("Release adds no cost"), Ability->CostApplications, 1);
		TestEqual(TEXT("Valid Release replay refuses"), F.Player.AbilitySystem->ProcessServerRequest(Release), EAethelnActivationResult::DuplicateSequence);
	}
	{
		FFixture F; if (!F.Init(*this)) { return false; }
		bool bNested = false;
		bool bNestedCommitted = true;
		bool bRecordNested = false;
		bool bRecordCommitted = true;
		FGuid NestedOperation;
		const FDelegateHandle Listener = F.Player.AbilitySystem->AbilityCommittedCallbacks.AddLambda([&](UGameplayAbility* Ability)
			{
				if (Ability == F.Ability && !bNested)
				{
					bNested = true; NestedOperation = F.Ability->GetOperationIdForTests();
					bNestedCommitted = F.Ability->CommitAbility(F.Handle, F.Ability->GetCurrentActorInfo(), F.Ability->GetCurrentActivationInfo());
				}
			});
		const FDelegateHandle RecordListener = F.Player.AbilitySystem->OnCombatActivation.AddLambda([&](const FAethelnCombatActivationRecord&)
			{
				if (!bRecordNested)
				{
					bRecordNested = true;
					bRecordCommitted = F.Ability->CommitAbility(F.Handle, F.Ability->GetCurrentActorInfo(), F.Ability->GetCurrentActivationInfo());
				}
			});
		TestEqual(TEXT("Original operation commits despite duplicate full commit refusal"), F.Press(), EAethelnActivationResult::Accepted);
		F.Player.AbilitySystem->AbilityCommittedCallbacks.Remove(Listener);
		F.Player.AbilitySystem->OnCombatActivation.Remove(RecordListener);
		TestTrue(TEXT("Real commit callback attempted second full commit"), bNested);
		TestTrue(TEXT("Real owner record callback attempted completed full commit"), bRecordNested);
		TestFalse(TEXT("Same operation cannot commit while its commit is in flight"), bNestedCommitted);
		TestFalse(TEXT("Same operation cannot commit during its owner record publication"), bRecordCommitted);
		TestEqual(TEXT("Duplicate full commit applies no second physical cost"), F.CostApplications, 1);
		TestEqual(TEXT("One authored cost leaves exact fixture resource"), F.Endurance(), 28.0f);
		TestEqual(TEXT("Original committed GUID retains original server operation"), F.Ability->GetActivationId(), NestedOperation);
		TestEqual(TEXT("One original operation publishes one descriptor"), F.Records.Num(), 1);
		TestEqual(TEXT("Original chain retains its GUID"), F.Player.AbilitySystem->GetChainStateForTests().CurrentInput.ActivationId, NestedOperation);
		TestTrue(TEXT("Duplicate commit does not end original GAS"), F.Ability->IsActive());
		TestEqual(TEXT("Duplicate commit preserves one active spec count"), F.Player.AbilitySystem->FindAbilitySpecFromHandle(F.Handle)->ActiveCount, uint8(1));
		TestTrue(TEXT("Duplicate commit preserves active observer descriptor"), F.Player.AbilitySystem->GetAttackPresentationState().bActive);
		TestEqual(TEXT("Duplicate commit preserves one commitment tag"), F.Player.AbilitySystem->GetTagCount(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain), 1);
		TestFalse(TEXT("Completed operation cannot commit again"), F.Ability->CommitAbility(F.Handle, F.Ability->GetCurrentActorInfo(), F.Ability->GetCurrentActivationInfo()));
		TestEqual(TEXT("Completed duplicate applies no cost"), F.CostApplications, 1);
		TestEqual(TEXT("Completed duplicate preserves valid public GUID"), F.Ability->GetActivationId(), NestedOperation);
		F.AdvanceTo(0.375);
		TestEqual(TEXT("A distinct legitimate activation still commits"), F.Press(), EAethelnActivationResult::Accepted);
		TestEqual(TEXT("Distinct activation applies exactly its own cost"), F.CostApplications, 2);
		TestTrue(TEXT("Distinct activation owns a different committed GUID"), F.Ability->GetActivationId().IsValid() && F.Ability->GetActivationId() != NestedOperation);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAttackWithoutPresentationTest,
	"Aetheln.GameCombat.AttackTimeline.RunsWithoutPresentation",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAttackWithoutPresentationTest::RunTest(const FString& Parameters)
{
	AethelnChainTests::FFixture F; if (!F.Init(*this)) { return false; }
	TestNull(TEXT("No mesh asset"), F.Pawn->GetMesh()->GetSkeletalMeshAsset());
	F.Press(); F.AdvanceTo(0.375);
	TestFalse(TEXT("GAS activation ends at BufferOpen without animation"), F.Player.AbilitySystem->FindAbilitySpecFromHandle(F.Handle)->IsActive());
	TestTrue(TEXT("Server recovery survives GAS activation end"), F.Player.AbilitySystem->GetChainStateForTests().bExists);
	F.AdvanceTo(0.75);
	TestEqual(TEXT("Headless timeout ends chain"), F.Ends.Last().Reason, EAethelnChainEndReason::Timeout);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAttackNetworkConditionsChainTest,
	"Aetheln.GameCombat.AttackTimeline.NetworkConditionsChain",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAttackNetworkConditionsChainTest::RunTest(const FString& Parameters)
{
	const TArray<double> Arrivals = { 0.359375, 0.375, 0.484375, 0.5, 0.734375, 0.75, 0.765625 };
	for (double Arrival : Arrivals)
	{
		AethelnChainTests::FFixture F; if (!F.Init(*this)) { return false; }
		F.Press();
		FAethelnCombatActivationRequest Delayed = F.Request(10); // explicit fixture gap and client sample0, not a profile/tuning value
		F.AdvanceTo(Arrival);
		const EAethelnActivationResult Expected = Arrival < 0.375 ? EAethelnActivationResult::ActivationBlocked : EAethelnActivationResult::Accepted;
		TestEqual(TEXT("Server arrival governs windows, never client sample"), F.Player.AbilitySystem->ProcessServerRequest(Delayed), Expected);
		if (Expected == EAethelnActivationResult::Accepted)
		{
			TestEqual(TEXT("Delivery duplicate rejects before instance gate"), F.Player.AbilitySystem->ProcessServerRequest(Delayed), EAethelnActivationResult::DuplicateSequence);
			Delayed.Sequence = 9;
			TestEqual(TEXT("Reordered older request refuses"), F.Player.AbilitySystem->ProcessServerRequest(Delayed), EAethelnActivationResult::StaleSequence);
			TestEqual(TEXT("No double spend under duplicate/reorder"), F.CostApplications, 2);
			if (Arrival < 0.5) { F.AdvanceTo(0.5); }
			TestEqual(TEXT("Late links restart, timely links continue"), F.Records.Last().ChainStep, uint8(Arrival >= 0.75 ? 1 : 2));
		}
	}
	AethelnChainTests::FFixture Dropped; if (!Dropped.Init(*this)) { return false; }
	Dropped.Press(); Dropped.AdvanceTo(0.75);
	TestEqual(TEXT("A dropped followup causes timeout without automation"), Dropped.CostApplications, 1);
	FAethelnCombatActivationRequest Gap = Dropped.Request(20);
	TestEqual(TEXT("Forward sequence gap remains valid after timeout"), Dropped.Player.AbilitySystem->ProcessServerRequest(Gap), EAethelnActivationResult::Accepted);
	TestEqual(TEXT("Gap starts1"), Dropped.Records.Last().ChainStep, uint8(1));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAttackTeardownChainTest,
	"Aetheln.GameCombat.AttackTimeline.TeardownMidChain",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAttackTeardownChainTest::RunTest(const FString& Parameters)
{
	for (double Time : { 0.0625, 0.1875, 0.4375 })
	{
		for (bool bDestroyPlayerState : { false, true })
		{
			AethelnChainTests::FFixture F; if (!F.Init(*this)) { return false; }
			F.Press();
			if (Time > 0.375) { F.AdvanceTo(0.375); F.Press(); }
			F.AdvanceTo(Time);
			if (bDestroyPlayerState) { F.Player.PlayerState->Destroy(); } else { F.Pawn->Destroy(); }
			TestEqual(TEXT("Teardown sends one chain end"), F.Ends.Num(), 1);
			TestEqual(TEXT("Teardown reason"), F.Ends.Last().Reason, EAethelnChainEndReason::AvatarLost);
			F.AdvanceTo(1.0);
			TestEqual(TEXT("No waiting step starts after teardown"), F.Records.Num(), 1);
			TestEqual(TEXT("No subsystem step or delegate owner leaks"), F.Timeline->GetRegisteredStepCountForTests(), 0);
		}
	}
	AethelnChainTests::FFixture Fresh; if (!Fresh.Init(*this)) { return false; }
	TestFalse(TEXT("Fresh PlayerState has no previous chain"), Fresh.Player.AbilitySystem->GetChainStateForTests().bExists);
	TestEqual(TEXT("Fresh sequence starts1"), Fresh.Press(), EAethelnActivationResult::Accepted);
	TestEqual(TEXT("Fresh record sequence1"), Fresh.Records[0].Sequence, uint32(1));
	Fresh.AdvanceTo(0.375); Fresh.Press();
	// Actual world teardown calls the subsystem's Deinitialize, with a pending buffer.
	UWorld* DestroyedWorld = Fresh.World.World;
	DestroyedWorld->DestroyWorld(false);
	GEngine->DestroyWorldContext(DestroyedWorld);
	Fresh.World.World = nullptr; // the scoped owner must not destroy it twice
	TestEqual(TEXT("World teardown ends a waiting chain once"), Fresh.Ends.Num(), 1);
	TestEqual(TEXT("World teardown has the AvatarLost reason"), Fresh.Ends.Last().Reason, EAethelnChainEndReason::AvatarLost);
	TestEqual(TEXT("World teardown clears subsystem entries"), Fresh.Timeline->GetRegisteredStepCountForTests(), 0);
	return true;
}

#endif
