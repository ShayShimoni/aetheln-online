#include "AethelnObservabilitySubsystem.h"

#include "HAL/PlatformTLS.h"

void UAethelnObservabilitySubsystem::Deinitialize()
{
	if (IsInGameThread())
	{
		ResetSink();
		ResetRestrictedSink();
		ResetRuntimeContext();
		ResetBuildContext();
	}

	Super::Deinitialize();
}

bool UAethelnObservabilitySubsystem::SetRuntimeContext(
	EAethelnFlowKind FlowKind,
	const FString& RunId,
	const FString& InstanceId,
	const FString& ConnectionPseudonym)
{
	if (!IsInGameThread())
	{
		return false;
	}

	FAethelnObservabilityRuntimeContext Candidate;
	Candidate.FlowKind = FlowKind;
	Candidate.RunId = RunId;
	Candidate.InstanceId = InstanceId;
	Candidate.ConnectionPseudonym = ConnectionPseudonym;
	if (!Candidate.IsValid())
	{
		return false;
	}

	RuntimeContext = MoveTemp(Candidate);
	bHasRuntimeContext = true;
	return true;
}

void UAethelnObservabilitySubsystem::ResetRuntimeContext()
{
	if (!IsInGameThread())
	{
		return;
	}

	RuntimeContext = FAethelnObservabilityRuntimeContext();
	bHasRuntimeContext = false;
	MetricEnvironment = EAethelnEnvironment::Local;
	bHasValidEnvironment = true;
}

bool UAethelnObservabilitySubsystem::HasRuntimeContext() const
{
	return IsInGameThread() && bHasRuntimeContext && RuntimeContext.IsValid();
}

bool UAethelnObservabilitySubsystem::SetBuildContext(
	const FAethelnBuildIdentity& InBuildIdentity,
	const FAethelnNetworkProfile& InNetworkProfile)
{
	if (!IsInGameThread()
		|| InBuildIdentity.SourceRevision.IsEmpty()
		|| InBuildIdentity.BuildIdentity.IsEmpty()
		|| InBuildIdentity.BuildConfiguration.IsEmpty()
		|| InBuildIdentity.EngineRevision.IsEmpty()
		|| InBuildIdentity.ToolchainIdentity.IsEmpty()
		|| InNetworkProfile.SchemaId != AethelnNetworkSpike::NetworkProfileSchemaId
		|| InNetworkProfile.SchemaVersion != AethelnNetworkSpike::NetworkProfileSchemaVersion
		|| InNetworkProfile.ProfileId.IsEmpty())
	{
		return false;
	}

	if (!InBuildIdentity.HasSafeIdentifiers()
		|| !AethelnObservability::IsSafeIdentifier(InNetworkProfile.ProfileId))
	{
		return false;
	}

	BuildIdentity = InBuildIdentity;
	NetworkProfile = InNetworkProfile;
	bHasBuildContext = true;
	return true;
}

void UAethelnObservabilitySubsystem::ResetBuildContext()
{
	if (!IsInGameThread())
	{
		return;
	}

	BuildIdentity = FAethelnBuildIdentity();
	NetworkProfile = FAethelnNetworkProfile();
	bHasBuildContext = false;
}

bool UAethelnObservabilitySubsystem::HasBuildContext() const
{
	return IsInGameThread() && bHasBuildContext;
}

bool UAethelnObservabilitySubsystem::SetEnvironment(const FString& EnvironmentName)
{
	if (!IsInGameThread())
	{
		return false;
	}

	if (EnvironmentName == TEXT("local"))
	{
		MetricEnvironment = EAethelnEnvironment::Local;
		bHasValidEnvironment = true;
		return true;
	}
	if (EnvironmentName == TEXT("development"))
	{
		MetricEnvironment = EAethelnEnvironment::Development;
		bHasValidEnvironment = true;
		return true;
	}

	bHasValidEnvironment = false;
	return false;
}

bool UAethelnObservabilitySubsystem::TryComposeCorrelation(
	EAethelnObservabilityCategory Category,
	const FAethelnObservabilityEventContext& EventContext,
	FAethelnCorrelationContext& OutCorrelation) const
{
	const EAethelnObservabilityCategory DefaultSubject = Category == EAethelnObservabilityCategory::Rejection
		? EAethelnObservabilityCategory::Ability
		: Category;
	return TryComposeCorrelation(Category, DefaultSubject, EventContext, OutCorrelation);
}

bool UAethelnObservabilitySubsystem::TryComposeCorrelation(
	EAethelnObservabilityCategory Category,
	EAethelnObservabilityCategory SubjectCategory,
	const FAethelnObservabilityEventContext& EventContext,
	FAethelnCorrelationContext& OutCorrelation) const
{
	if (!HasRuntimeContext() || !EventContext.IsValid(Category, SubjectCategory))
	{
		return false;
	}

	return FAethelnCorrelationContext::TryMakeValidated(
		RuntimeContext.FlowKind,
		RuntimeContext.RunId,
		EventContext.ConnectionPseudonym.IsEmpty()
			? RuntimeContext.ConnectionPseudonym
			: EventContext.ConnectionPseudonym,
		RuntimeContext.InstanceId,
		EventContext.ActivationId,
		EventContext.AbilityId,
		EventContext.Sequence,
		OutCorrelation);
}

bool UAethelnObservabilitySubsystem::SetTestSink(FSinkPtr Sink)
{
	return IsInGameThread() && Service.SetSink(MoveTemp(Sink));
}

bool UAethelnObservabilitySubsystem::SetTestRestrictedSink(FRestrictedSinkPtr Sink)
{
	return IsInGameThread() && Service.SetRestrictedSink(MoveTemp(Sink));
}

void UAethelnObservabilitySubsystem::ResetSink()
{
	if (IsInGameThread())
	{
		Service.ResetSink();
	}
}

void UAethelnObservabilitySubsystem::ResetRestrictedSink()
{
	if (IsInGameThread())
	{
		Service.ResetRestrictedSink();
	}
}

bool UAethelnObservabilitySubsystem::WaitForIdleForTests(double TimeoutSeconds) const
{
	return Service.WaitForIdleForTests(TimeoutSeconds);
}

void UAethelnObservabilitySubsystem::EmitEvent(
	const FAethelnObservabilityEvent& Event,
	const FAethelnObservabilityEventContext& EventContext) const
{
	if (!IsInGameThread())
	{
		return;
	}

	FAethelnCorrelationContext Correlation;
	const EAethelnObservabilityCategory EffectiveSubject = Event.Category == EAethelnObservabilityCategory::Rejection
		? Event.SubjectCategory
		: Event.Category;
	if (!TryComposeCorrelation(Event.Category, EffectiveSubject, EventContext, Correlation))
	{
		return;
	}

	FAethelnObservabilityEvent ComposedEvent = Event;
	ComposedEvent.SubjectCategory = EffectiveSubject;
	ComposedEvent.Correlation = MoveTemp(Correlation);
	if (HasBuildContext())
	{
		ComposedEvent.Build = BuildIdentity;
		ComposedEvent.NetworkProfile = NetworkProfile;
	}
	Service.EmitEvent(ComposedEvent);
}

void UAethelnObservabilitySubsystem::EmitMetric(const FAethelnMetricSample& Sample) const
{
	if (IsInGameThread() && bHasValidEnvironment)
	{
		FAethelnMetricSample ComposedSample = Sample;
		ComposedSample.Environment = MetricEnvironment;
		Service.EmitMetric(ComposedSample);
	}
}

#if WITH_DEV_AUTOMATION_TESTS
#include "Engine/GameInstance.h"
#include "Misc/AutomationTest.h"

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnObservabilitySubsystemContextTest,
	"Aetheln.Observability.Subsystem.ContextComposition",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnObservabilitySubsystemContextTest::RunTest(const FString& Parameters)
{
	UGameInstance* GameInstance = NewObject<UGameInstance>(GEngine);
	UAethelnObservabilitySubsystem* Subsystem = NewObject<UAethelnObservabilitySubsystem>(GameInstance);
	TestNotNull(TEXT("Subsystem can own the service independently of an actor"), Subsystem);
	TestFalse(TEXT("Runtime context is initially absent"), Subsystem->HasRuntimeContext());

	FAethelnObservabilityEventContext Overlay;
	Overlay.ActivationId = TEXT("activation-7");
	Overlay.AbilityId = TEXT("ability-spike");
	Overlay.Sequence = 19;

	FAethelnCorrelationContext Correlation;
	TestFalse(
		TEXT("Missing runtime context suppresses composition"),
		Subsystem->TryComposeCorrelation(EAethelnObservabilityCategory::Ability, Overlay, Correlation));

	TestTrue(
		TEXT("Bounded pre-pseudonymized runtime context is accepted"),
		Subsystem->SetRuntimeContext(
			EAethelnFlowKind::PrototypeAuthority,
			TEXT("run-17"),
			TEXT("instance-4"),
			TEXT("connection-a1b2c3")));
	TestTrue(TEXT("Accepted runtime context becomes available"), Subsystem->HasRuntimeContext());
	TestFalse(TEXT("Build context is independent and initially absent"), Subsystem->HasBuildContext());
	FAethelnBuildIdentity Build;
	Build.SourceRevision = TEXT("revision-17");
	Build.BuildIdentity = TEXT("build-17");
	Build.BuildConfiguration = TEXT("Development");
	Build.EngineRevision = TEXT("5.8.1");
	Build.ToolchainIdentity = TEXT("toolchain-17");
	FAethelnNetworkProfile Profile;
	Profile.ProfileId = TEXT("network-profile.test");
	TestTrue(TEXT("Bounded build and profile context is accepted"), Subsystem->SetBuildContext(Build, Profile));
	TestTrue(TEXT("Accepted build context becomes available"), Subsystem->HasBuildContext());
	TestTrue(
		TEXT("Valid event overlay composes"),
		Subsystem->TryComposeCorrelation(EAethelnObservabilityCategory::Ability, Overlay, Correlation));
	TestEqual(TEXT("Flow is supplied by the runtime owner"), Correlation.FlowKind, EAethelnFlowKind::PrototypeAuthority);
	TestEqual(TEXT("Run is supplied by the runtime owner"), Correlation.RunId, FString(TEXT("run-17")));
	TestEqual(TEXT("Instance is supplied by the runtime owner"), Correlation.InstanceId, FString(TEXT("instance-4")));
	TestEqual(TEXT("Pseudonym is supplied unchanged"), Correlation.ConnectionPseudonym, FString(TEXT("connection-a1b2c3")));
	TestEqual(TEXT("Activation is supplied by the event overlay"), Correlation.ActivationId, Overlay.ActivationId);
	TestEqual(TEXT("Ability is supplied by the event overlay"), Correlation.AbilityId, Overlay.AbilityId);
	TestEqual(TEXT("Sequence is supplied by the event overlay"), Correlation.Sequence, Overlay.Sequence);
	FAethelnObservabilityEventContext PerConnectionOverlay = Overlay;
	PerConnectionOverlay.ConnectionPseudonym = TEXT("server-connection-0002");
	TestTrue(
		TEXT("Authority-owned per-event connection identity composes"),
		Subsystem->TryComposeCorrelation(EAethelnObservabilityCategory::Ability, PerConnectionOverlay, Correlation));
	TestEqual(TEXT("Per-event connection identity overrides the process default"), Correlation.ConnectionPseudonym, PerConnectionOverlay.ConnectionPseudonym);
	FAethelnObservabilityEventContext SecondConnectionOverlay = Overlay;
	SecondConnectionOverlay.ConnectionPseudonym = TEXT("server-connection-0003");
	TestTrue(
		TEXT("A second authority-owned connection remains independently correlatable"),
		Subsystem->TryComposeCorrelation(EAethelnObservabilityCategory::Ability, SecondConnectionOverlay, Correlation));
	TestEqual(TEXT("Second connection does not collapse into the first"), Correlation.ConnectionPseudonym, FString(TEXT("server-connection-0003")));

	FAethelnObservabilityEventContext PreActivationRejection = Overlay;
	PreActivationRejection.ActivationId.Reset();
	TestTrue(
		TEXT("Rejection composes before an activation ID exists"),
		Subsystem->TryComposeCorrelation(
			EAethelnObservabilityCategory::Rejection,
			PreActivationRejection,
			Correlation));
	TestTrue(TEXT("Pre-activation rejection retains an empty activation ID"), Correlation.ActivationId.IsEmpty());
	TestEqual(TEXT("Pre-activation rejection retains its ability"), Correlation.AbilityId, PreActivationRejection.AbilityId);
	TestEqual(TEXT("Pre-activation rejection retains its intent sequence"), Correlation.Sequence, PreActivationRejection.Sequence);
	TestFalse(
		TEXT("Equivalent non-rejection context still requires activation"),
		Subsystem->TryComposeCorrelation(
			EAethelnObservabilityCategory::Ability,
			PreActivationRejection,
			Correlation));
	FAethelnObservabilityEventContext MovementRejectionContext;
	MovementRejectionContext.Sequence = 20;
	TestTrue(
		TEXT("Movement rejection composes without fabricated combat identities"),
		Subsystem->TryComposeCorrelation(
			EAethelnObservabilityCategory::Rejection,
			EAethelnObservabilityCategory::Movement,
			MovementRejectionContext,
			Correlation));
	TestTrue(TEXT("Movement rejection leaves activation identity empty"), Correlation.ActivationId.IsEmpty());
	TestTrue(TEXT("Movement rejection leaves ability identity empty"), Correlation.AbilityId.IsEmpty());
	FAethelnObservabilityEventContext ServerLifecycleContext;
	ServerLifecycleContext.Sequence = 21;
	TestTrue(
		TEXT("Server lifecycle composition does not fabricate combat identities"),
		Subsystem->TryComposeCorrelation(
			EAethelnObservabilityCategory::ServerLifecycle,
			ServerLifecycleContext,
			Correlation));
	FAethelnObservabilityEventContext MovementCorrectionContext;
	MovementCorrectionContext.Sequence = 22;
	TestTrue(
		TEXT("Movement correction composition does not fabricate combat identities"),
		Subsystem->TryComposeCorrelation(
			EAethelnObservabilityCategory::Correction,
			MovementCorrectionContext,
			Correlation));

	const FString Oversized = FString::ChrN(AethelnObservability::MaxIdentifierLength + 1, TCHAR('x'));
	TestFalse(
		TEXT("Oversized runtime context is rejected"),
		Subsystem->SetRuntimeContext(
			EAethelnFlowKind::PrototypeAuthority,
			TEXT("run-replacement"),
			Oversized,
			TEXT("connection-replacement")));
	TestTrue(
		TEXT("Rejected runtime replacement preserves valid context"),
		Subsystem->TryComposeCorrelation(EAethelnObservabilityCategory::Ability, Overlay, Correlation));
	TestEqual(TEXT("Preserved context retains its instance"), Correlation.InstanceId, FString(TEXT("instance-4")));

	FAethelnObservabilityEventContext MissingAbility = PreActivationRejection;
	MissingAbility.AbilityId.Reset();
	TestFalse(
		TEXT("Missing ability suppresses rejection composition"),
		Subsystem->TryComposeCorrelation(EAethelnObservabilityCategory::Rejection, MissingAbility, Correlation));

	FAethelnObservabilityEventContext MissingSequence = PreActivationRejection;
	MissingSequence.Sequence = 0;
	TestFalse(
		TEXT("Missing sequence suppresses rejection composition"),
		Subsystem->TryComposeCorrelation(EAethelnObservabilityCategory::Rejection, MissingSequence, Correlation));

	FAethelnObservabilityEventContext OversizedActivation = Overlay;
	OversizedActivation.ActivationId = Oversized;
	TestFalse(
		TEXT("Oversized activation suppresses composition"),
		Subsystem->TryComposeCorrelation(EAethelnObservabilityCategory::Rejection, OversizedActivation, Correlation));

	FAethelnObservabilityEventContext OversizedAbility = PreActivationRejection;
	OversizedAbility.AbilityId = Oversized;
	TestFalse(
		TEXT("Oversized ability suppresses pre-activation rejection composition"),
		Subsystem->TryComposeCorrelation(EAethelnObservabilityCategory::Rejection, OversizedAbility, Correlation));

	Subsystem->ResetRuntimeContext();
	Subsystem->ResetBuildContext();
	TestFalse(TEXT("Runtime reset removes context"), Subsystem->HasRuntimeContext());
	TestFalse(TEXT("Build reset removes context"), Subsystem->HasBuildContext());
	TestFalse(
		TEXT("Reset context suppresses later composition"),
		Subsystem->TryComposeCorrelation(EAethelnObservabilityCategory::Ability, Overlay, Correlation));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnObservabilitySubsystemSinkTest,
	"Aetheln.Observability.Subsystem.OwnershipFailureAndReset",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnObservabilitySubsystemSinkTest::RunTest(const FString& Parameters)
{
	UGameInstance* GameInstance = NewObject<UGameInstance>(GEngine);
	UAethelnObservabilitySubsystem* Subsystem = NewObject<UAethelnObservabilitySubsystem>(GameInstance);
	TestTrue(
		TEXT("Runtime context is configured for emission"),
		Subsystem->SetRuntimeContext(
			EAethelnFlowKind::PrototypeAuthority,
			TEXT("run-22"),
			TEXT("instance-8"),
			TEXT("connection-d4e5f6")));

	FAethelnObservabilityEventContext Overlay;
	Overlay.ActivationId = TEXT("activation-9");
	Overlay.AbilityId = TEXT("ability-spike");
	Overlay.Sequence = 23;

	FAethelnObservabilityEvent Event;
	Event.Category = EAethelnObservabilityCategory::Ability;
	Event.SafeReason = EAethelnSafeReason::Accepted;
	FAethelnBuildIdentity Build;
	Build.SourceRevision = TEXT("revision-22");
	Build.BuildIdentity = TEXT("build-22");
	Build.BuildConfiguration = TEXT("Development");
	Build.EngineRevision = TEXT("5.8.1");
	Build.ToolchainIdentity = TEXT("toolchain-22");
	FAethelnNetworkProfile Profile;
	Profile.ProfileId = TEXT("network-profile.test");
	TestTrue(TEXT("Build and network profile are configured for emission"), Subsystem->SetBuildContext(Build, Profile));

	TWeakPtr<IAethelnObservabilitySink, ESPMode::ThreadSafe> WeakSink;
	TWeakPtr<IAethelnRestrictedAuditSink, ESPMode::ThreadSafe> WeakRestrictedSink;
	TSharedPtr<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe> InMemorySink =
		MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(4);
	TSharedPtr<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe> InMemoryRestrictedSink =
		MakeShared<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe>(8);
	WeakSink = InMemorySink;
	WeakRestrictedSink = InMemoryRestrictedSink;
	TestTrue(TEXT("Shared test sink is accepted on the game thread"), Subsystem->SetTestSink(InMemorySink));
	TestTrue(TEXT("Shared restricted sink is accepted on the game thread"), Subsystem->SetTestRestrictedSink(InMemoryRestrictedSink));
	InMemorySink.Reset();
	InMemoryRestrictedSink.Reset();
	TestTrue(TEXT("Subsystem service owns the injected sink lifetime"), WeakSink.IsValid());
	TestTrue(TEXT("Subsystem service owns the restricted sink lifetime"), WeakRestrictedSink.IsValid());

	Subsystem->EmitEvent(Event, Overlay);
	TestTrue(TEXT("Initial subsystem event dispatch drains"), Subsystem->WaitForIdleForTests());
	TSharedPtr<IAethelnObservabilitySink, ESPMode::ThreadSafe> PinnedSink = WeakSink.Pin();
	TSharedPtr<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe> RecordedSink =
		StaticCastSharedPtr<FAethelnInMemoryObservabilitySink>(PinnedSink);
	TSharedPtr<IAethelnRestrictedAuditSink, ESPMode::ThreadSafe> PinnedRestrictedSink = WeakRestrictedSink.Pin();
	TSharedPtr<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe> RecordedRestrictedSink =
		StaticCastSharedPtr<FAethelnBoundedRestrictedAuditSink>(PinnedRestrictedSink);
	TestEqual(TEXT("Composed event reaches the owned sink"), RecordedSink->GetEvents().Num(), 1);
	TestEqual(TEXT("Recorded event contains the overlay sequence"), RecordedSink->GetEvents()[0].Correlation.Sequence, Overlay.Sequence);
	TestEqual(TEXT("Recorded event contains the configured build"), RecordedSink->GetEvents()[0].Build.BuildIdentity, Build.BuildIdentity);
	TestEqual(TEXT("Recorded event contains the configured network profile"), RecordedSink->GetEvents()[0].NetworkProfile.ProfileId, Profile.ProfileId);

	FAethelnObservabilityEventContext PreActivationContext = Overlay;
	PreActivationContext.ActivationId.Reset();
	Subsystem->EmitEvent(Event, PreActivationContext);
	TestTrue(TEXT("Suppressed non-rejection leaves dispatch idle"), Subsystem->WaitForIdleForTests());
	TestEqual(TEXT("Non-rejection without activation suppresses void emission"), RecordedSink->GetEvents().Num(), 1);

	FAethelnObservabilityEvent RejectionEvent = Event;
	RejectionEvent.Category = EAethelnObservabilityCategory::Rejection;
	RejectionEvent.SubjectCategory = EAethelnObservabilityCategory::Ability;
	RejectionEvent.SafeReason = EAethelnSafeReason::ActivationBlocked;
	Subsystem->EmitEvent(RejectionEvent, PreActivationContext);
	TestTrue(TEXT("Pre-activation rejection dispatch drains"), Subsystem->WaitForIdleForTests());
	TestEqual(TEXT("Pre-activation rejection reaches the sink"), RecordedSink->GetEvents().Num(), 2);
	TestTrue(
		TEXT("Emitted pre-activation rejection has no activation ID"),
		RecordedSink->GetEvents()[1].Correlation.ActivationId.IsEmpty());

	FAethelnObservabilityEvent MovementRejectionEvent;
	MovementRejectionEvent.Category = EAethelnObservabilityCategory::Rejection;
	MovementRejectionEvent.SubjectCategory = EAethelnObservabilityCategory::Movement;
	MovementRejectionEvent.SafeReason = EAethelnSafeReason::Corrected;
	MovementRejectionEvent.DiagnosticCode = EAethelnDiagnosticCode::ValidationFailed;
	FAethelnObservabilityEventContext MovementRejectionContext;
	MovementRejectionContext.Sequence = 24;
	Subsystem->EmitEvent(MovementRejectionEvent, MovementRejectionContext);
	TestTrue(TEXT("Movement rejection dispatch drains"), Subsystem->WaitForIdleForTests());
	TestEqual(TEXT("Movement rejection without fabricated combat identities reaches the sink"), RecordedSink->GetEvents().Num(), 3);
	TestEqual(TEXT("Movement rejection retains its authoritative subject"), RecordedSink->GetEvents()[2].SubjectCategory, EAethelnObservabilityCategory::Movement);
	TestTrue(TEXT("Movement rejection has no fabricated ability identity"), RecordedSink->GetEvents()[2].Correlation.AbilityId.IsEmpty());
	TestEqual(TEXT("Public movement rejection removes diagnostic detail"), RecordedSink->GetEvents()[2].DiagnosticCode, EAethelnDiagnosticCode::None);
	TestEqual(TEXT("Restricted channel retained every emitted event"), RecordedRestrictedSink->GetEvents().Num(), 3);
	TestEqual(TEXT("Restricted movement rejection retains diagnostic detail"), RecordedRestrictedSink->GetEvents()[2].DiagnosticCode, EAethelnDiagnosticCode::ValidationFailed);

	Subsystem->EmitMetric(FAethelnMetricSample());
	TestTrue(TEXT("Local metric dispatch drains"), Subsystem->WaitForIdleForTests());
	TestEqual(TEXT("Contributor metrics default to the local environment"), RecordedSink->GetMetrics().Num(), 1);
	TestEqual(TEXT("Default metric environment is local"), RecordedSink->GetMetrics()[0].Environment, EAethelnEnvironment::Local);
	TestTrue(TEXT("Explicit development environment is accepted"), Subsystem->SetEnvironment(TEXT("development")));
	Subsystem->EmitMetric(FAethelnMetricSample());
	TestTrue(TEXT("Development metric dispatch drains"), Subsystem->WaitForIdleForTests());
	TestEqual(TEXT("Development metric reaches the sink"), RecordedSink->GetMetrics().Num(), 2);
	TestEqual(TEXT("Explicit metric environment is development"), RecordedSink->GetMetrics()[1].Environment, EAethelnEnvironment::Development);
	TestFalse(TEXT("Unsupported environment fails closed"), Subsystem->SetEnvironment(TEXT("staging")));
	Subsystem->EmitMetric(FAethelnMetricSample());
	TestTrue(TEXT("Suppressed invalid-environment metric leaves dispatch idle"), Subsystem->WaitForIdleForTests());
	TestEqual(TEXT("Invalid environment suppresses metric emission"), RecordedSink->GetMetrics().Num(), 2);
	TestTrue(TEXT("Local environment can be restored explicitly"), Subsystem->SetEnvironment(TEXT("local")));

	FAethelnObservabilityEventContext InvalidRejectionContext = PreActivationContext;
	InvalidRejectionContext.Sequence = 0;
	Subsystem->EmitEvent(RejectionEvent, InvalidRejectionContext);
	TestTrue(TEXT("Invalid rejection leaves dispatch idle"), Subsystem->WaitForIdleForTests());
	TestEqual(TEXT("Invalid rejection context suppresses void emission"), RecordedSink->GetEvents().Num(), 3);

	RecordedSink->SetFailWrites(true);
	Subsystem->EmitEvent(Event, Overlay);
	Subsystem->EmitMetric(FAethelnMetricSample());
	TestTrue(TEXT("Failed injected writes drain without escaping"), Subsystem->WaitForIdleForTests());
	TestEqual(TEXT("Sink event failure does not escape or alter state"), RecordedSink->GetEvents().Num(), 3);
	TestEqual(TEXT("Sink metric failure does not escape or alter state"), RecordedSink->GetMetrics().Num(), 2);

	TestFalse(
		TEXT("Null sink injection is rejected without replacing the active sink"),
		Subsystem->SetTestSink(UAethelnObservabilitySubsystem::FSinkPtr()));
	RecordedSink->SetFailWrites(false);
	Subsystem->EmitEvent(Event, Overlay);
	TestTrue(TEXT("Preserved injected sink dispatch drains"), Subsystem->WaitForIdleForTests());
	TestEqual(TEXT("Rejected injection preserves the active sink"), RecordedSink->GetEvents().Num(), 4);

	PinnedSink.Reset();
	RecordedSink.Reset();
	PinnedRestrictedSink.Reset();
	RecordedRestrictedSink.Reset();
	Subsystem->ResetSink();
	Subsystem->ResetRestrictedSink();
	TestFalse(TEXT("Reset releases the injected shared sink"), WeakSink.IsValid());
	TestFalse(TEXT("Reset releases the injected restricted sink"), WeakRestrictedSink.IsValid());
	Subsystem->EmitEvent(Event, Overlay);
	Subsystem->EmitMetric(FAethelnMetricSample());
	TestTrue(TEXT("Reset default dispatch drains"), Subsystem->WaitForIdleForTests());
	TestTrue(TEXT("Reset restores bounded structured-log emission"), true);
	return true;
}
#endif
