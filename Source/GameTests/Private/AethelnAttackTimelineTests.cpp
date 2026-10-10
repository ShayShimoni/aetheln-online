#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatTestAbilities.h"
#include "AethelnCombatTestWorld.h"
#include "AethelnObservability.h"
#include "AethelnObservabilitySubsystem.h"
#include "AethelnPlayerCharacter.h"
#include "Misc/AutomationTest.h"
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

#endif
