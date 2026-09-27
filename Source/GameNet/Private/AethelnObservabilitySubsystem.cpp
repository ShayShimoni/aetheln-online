#include "AethelnObservabilitySubsystem.h"

#include "Engine/GameInstance.h"
#include "Engine/World.h"
#include "GenericPlatform/GenericPlatformCrashContext.h"
#include "HAL/PlatformTLS.h"

FAethelnCrashContextChanged& UAethelnObservabilitySubsystem::OnCrashContextChanged()
{
	static FAethelnCrashContextChanged Delegate;
	return Delegate;
}

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
	OnCrashContextChanged().Broadcast(*this);
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
	OnCrashContextChanged().Broadcast(*this);
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
	OnCrashContextChanged().Broadcast(*this);
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
	OnCrashContextChanged().Broadcast(*this);
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

bool UAethelnObservabilitySubsystem::TryGetCrashContextSnapshot(FAethelnCrashContextSnapshot& OutSnapshot) const
{
	if (!HasRuntimeContext() || !HasBuildContext())
	{
		return false;
	}

	return FAethelnCrashContextSnapshot::TryMakeValidated(
		BuildIdentity,
		NetworkProfile,
		RuntimeContext.FlowKind,
		RuntimeContext.RunId,
		RuntimeContext.InstanceId,
		RuntimeContext.ConnectionPseudonym,
		OutSnapshot);
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
	if (Event.Category == EAethelnObservabilityCategory::Correction
		&& !IsCorrectableSubject(Event.SubjectCategory))
	{
		return;
	}

	FAethelnCorrelationContext Correlation;
	const bool bSubjectEnvelope = Event.Category == EAethelnObservabilityCategory::Rejection
		|| Event.Category == EAethelnObservabilityCategory::Correction;
	const EAethelnObservabilityCategory EffectiveSubject = bSubjectEnvelope
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

const TCHAR* AethelnCrashContext::StateToString(EState State)
{
	switch (State)
	{
	case EState::Missing: return TEXT("missing");
	case EState::Updating: return TEXT("updating");
	case EState::Active: return TEXT("active");
	case EState::Ambiguous: return TEXT("ambiguous");
	case EState::Stale: return TEXT("stale");
	default: return TEXT("missing");
	}
}

UAethelnObservabilitySubsystem* AethelnCrashContext::FindObservabilitySubsystem(const UWorld* World)
{
	UGameInstance* GameInstance = World != nullptr ? World->GetGameInstance() : nullptr;
	return GameInstance != nullptr
		? GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>()
		: nullptr;
}

FAethelnCrashContextOwner::~FAethelnCrashContextOwner()
{
	if (ChangedHandle.IsValid())
	{
		UAethelnObservabilitySubsystem::OnCrashContextChanged().Remove(ChangedHandle);
	}
}

void FAethelnCrashContextOwner::Initialize()
{
	if (!ChangedHandle.IsValid())
	{
		ChangedHandle = UAethelnObservabilitySubsystem::OnCrashContextChanged().AddRaw(this, &FAethelnCrashContextOwner::OnContextChanged);
	}
	ClearIdentity(AethelnCrashContext::EState::Missing);
}

void FAethelnCrashContextOwner::Shutdown()
{
	UAethelnObservabilitySubsystem::OnCrashContextChanged().Remove(ChangedHandle);
	ChangedHandle.Reset();
	TrackedWorlds.Reset();
	MarkStale();
}

bool FAethelnCrashContextOwner::TrackWorldTick(const UWorld* World)
{
	if (World == nullptr)
	{
		return false;
	}
	if (TrackedWorlds.Contains(World))
	{
		// A later tick from a sole remaining world recovers stale or ambiguous context.
		if (TrackedWorlds.Num() == 1
			&& (State == AethelnCrashContext::EState::Stale || State == AethelnCrashContext::EState::Ambiguous))
		{
			Refresh();
		}
		return false;
	}
	// Every observable world counts toward ownership, with or without a subsystem.
	TrackedWorlds.Add(World);
	Refresh();
	return true;
}

void FAethelnCrashContextOwner::EndTracking(const UWorld* World)
{
	TrackedWorlds.Remove(World);
	MarkStale();
}

bool FAethelnCrashContextOwner::IsTracked(const UWorld* World) const
{
	return TrackedWorlds.Contains(World);
}

int32 FAethelnCrashContextOwner::NumTrackedWorlds() const
{
	return TrackedWorlds.Num();
}

void FAethelnCrashContextOwner::Register(const FAethelnCrashContextSnapshot* Snapshot)
{
	using namespace AethelnCrashContext;
	if (Snapshot == nullptr || !Snapshot->IsBounded())
	{
		ClearIdentity(EState::Missing);
		return;
	}

	SetState(EState::Updating);
	FGenericCrashContext::SetGameData(SchemaVersionKey, FString::Printf(TEXT("%u"), Snapshot->ObservabilitySchemaVersion));
	FGenericCrashContext::SetGameData(SourceRevisionKey, Snapshot->SourceRevision);
	FGenericCrashContext::SetGameData(BuildIdentityKey, Snapshot->BuildIdentity);
	FGenericCrashContext::SetGameData(BuildConfigurationKey, Snapshot->BuildConfiguration);
	FGenericCrashContext::SetGameData(EngineRevisionKey, Snapshot->EngineRevision);
	FGenericCrashContext::SetGameData(ToolchainIdentityKey, Snapshot->ToolchainIdentity);
	FGenericCrashContext::SetGameData(NetworkProfileSchemaKey, Snapshot->NetworkProfileSchemaId);
	FGenericCrashContext::SetGameData(NetworkProfileVersionKey, FString::Printf(TEXT("%u"), Snapshot->NetworkProfileSchemaVersion));
	FGenericCrashContext::SetGameData(NetworkProfileIdKey, Snapshot->NetworkProfileId);
	FGenericCrashContext::SetGameData(FlowKindKey, LexToString(Snapshot->FlowKind));
	FGenericCrashContext::SetGameData(RunIdKey, Snapshot->RunId);
	FGenericCrashContext::SetGameData(ServerInstanceKey, Snapshot->ServerInstanceId);
	FGenericCrashContext::SetGameData(ConnectionPseudonymKey, Snapshot->ConnectionPseudonym);
	SetState(EState::Active);
}

void FAethelnCrashContextOwner::MarkStale()
{
	ClearIdentity(AethelnCrashContext::EState::Stale);
}

void FAethelnCrashContextOwner::MarkAmbiguous()
{
	ClearIdentity(AethelnCrashContext::EState::Ambiguous);
}

AethelnCrashContext::EState FAethelnCrashContextOwner::GetState() const
{
	return State;
}

void FAethelnCrashContextOwner::Refresh()
{
	// No tracked world: startup or cleanup already owns the missing/stale state.
	if (TrackedWorlds.IsEmpty())
	{
		return;
	}
	// ponytail: dead weak entries still count, so a leaked world keeps the process ambiguous (fail-safe) until cleanup.
	if (TrackedWorlds.Num() != 1)
	{
		MarkAmbiguous();
		return;
	}
	const UAethelnObservabilitySubsystem* Subsystem = AethelnCrashContext::FindObservabilitySubsystem(GetSoleTrackedWorld());
	FAethelnCrashContextSnapshot Snapshot;
	Register(Subsystem != nullptr && Subsystem->TryGetCrashContextSnapshot(Snapshot) ? &Snapshot : nullptr);
}

void FAethelnCrashContextOwner::OnContextChanged(const UAethelnObservabilitySubsystem& Changed)
{
	// Only the sole tracked world's own game instance can change process crash context.
	const UWorld* World = GetSoleTrackedWorld();
	const UGameInstance* GameInstance = World != nullptr ? World->GetGameInstance() : nullptr;
	if (GameInstance != nullptr && GameInstance == Changed.GetGameInstance())
	{
		Refresh();
	}
}

const UWorld* FAethelnCrashContextOwner::GetSoleTrackedWorld() const
{
	return TrackedWorlds.Num() == 1 ? TrackedWorlds.CreateConstIterator()->Get() : nullptr;
}

void FAethelnCrashContextOwner::SetState(AethelnCrashContext::EState NewState)
{
	State = NewState;
	FGenericCrashContext::SetGameData(AethelnCrashContext::StateKey, AethelnCrashContext::StateToString(NewState));
}

void FAethelnCrashContextOwner::ClearIdentity(AethelnCrashContext::EState NewState)
{
	SetState(NewState);
	for (const TCHAR* Key : AethelnCrashContext::IdentityKeys)
	{
		FGenericCrashContext::SetGameData(Key, TEXT(""));
	}
}

#if WITH_DEV_AUTOMATION_TESTS
#include "Engine/Engine.h"
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
	TestTrue(
		TEXT("Pre-resolution rejection composes without fabricating an ability"),
		Subsystem->TryComposeCorrelation(EAethelnObservabilityCategory::Rejection, MissingAbility, Correlation));
	TestTrue(TEXT("Pre-resolution rejection retains an empty ability identity"), Correlation.AbilityId.IsEmpty());

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
	FAethelnObservabilitySubsystemCrashContextTest,
	"Aetheln.Observability.Subsystem.CrashContextSnapshot",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnObservabilitySubsystemCrashContextTest::RunTest(const FString& Parameters)
{
	UGameInstance* GameInstance = NewObject<UGameInstance>(GEngine);
	UAethelnObservabilitySubsystem* Subsystem = NewObject<UAethelnObservabilitySubsystem>(GameInstance);
	int32 Changes = 0;
	const FDelegateHandle ChangeHandle = UAethelnObservabilitySubsystem::OnCrashContextChanged().AddLambda(
		[&Changes, Subsystem](const UAethelnObservabilitySubsystem& Changed)
		{
			if (&Changed == Subsystem)
			{
				++Changes;
			}
		});

	FAethelnCrashContextSnapshot Sentinel;
	Sentinel.RunId = TEXT("sentinel-run");
	FAethelnCrashContextSnapshot Snapshot = Sentinel;
	TestFalse(TEXT("Missing runtime and build context yields no snapshot"), Subsystem->TryGetCrashContextSnapshot(Snapshot));
	TestEqual(TEXT("Failed accessor leaves the caller's output unchanged"), Snapshot.RunId, Sentinel.RunId);
	TestEqual(TEXT("Reading context never broadcasts a change"), Changes, 0);

	TestTrue(
		TEXT("Runtime context is accepted"),
		Subsystem->SetRuntimeContext(
			EAethelnFlowKind::PrototypeAuthority,
			TEXT("run-148"),
			TEXT("instance-148"),
			AethelnObservability::ExcludedIdentifier));
	TestEqual(TEXT("Accepted runtime context broadcasts one change"), Changes, 1);
	TestFalse(TEXT("Missing build context yields no snapshot"), Subsystem->TryGetCrashContextSnapshot(Snapshot));
	TestEqual(TEXT("Missing build context leaves output unchanged"), Snapshot.RunId, Sentinel.RunId);

	Subsystem->ResetRuntimeContext();
	TestEqual(TEXT("Runtime reset broadcasts one change"), Changes, 2);
	FAethelnBuildIdentity Build;
	Build.SourceRevision = TEXT("revision-148");
	Build.BuildIdentity = TEXT("build-148");
	Build.BuildConfiguration = TEXT("Development");
	Build.EngineRevision = TEXT("5.8.1");
	Build.ToolchainIdentity = TEXT("toolchain-148");
	FAethelnNetworkProfile Profile;
	Profile.ProfileId = TEXT("network-profile.test");
	TestTrue(TEXT("Build context is accepted"), Subsystem->SetBuildContext(Build, Profile));
	TestEqual(TEXT("Accepted build context broadcasts one change"), Changes, 3);
	TestFalse(TEXT("Missing runtime context yields no snapshot"), Subsystem->TryGetCrashContextSnapshot(Snapshot));
	TestEqual(TEXT("Missing runtime context leaves output unchanged"), Snapshot.RunId, Sentinel.RunId);

	TestTrue(
		TEXT("Runtime context is restored"),
		Subsystem->SetRuntimeContext(
			EAethelnFlowKind::PrototypeAuthority,
			TEXT("run-148"),
			TEXT("instance-148"),
			AethelnObservability::ExcludedIdentifier));
	TestTrue(TEXT("Valid runtime and build context yields a snapshot"), Subsystem->TryGetCrashContextSnapshot(Snapshot));
	TestTrue(TEXT("Returned snapshot is bounded"), Snapshot.IsBounded());
	TestEqual(TEXT("Returned snapshot maps the run"), Snapshot.RunId, FString(TEXT("run-148")));
	TestEqual(TEXT("Returned snapshot maps the server instance"), Snapshot.ServerInstanceId, FString(TEXT("instance-148")));
	TestEqual(TEXT("Returned snapshot maps the build"), Snapshot.BuildIdentity, Build.BuildIdentity);
	TestEqual(TEXT("Returned snapshot maps the profile"), Snapshot.NetworkProfileId, Profile.ProfileId);
	TestEqual(TEXT("Returned snapshot keeps the excluded connection marker"), Snapshot.ConnectionPseudonym, FString(AethelnObservability::ExcludedIdentifier));

	Snapshot.RunId = TEXT("caller-mutation");
	FAethelnCrashContextSnapshot Fresh;
	TestTrue(TEXT("Snapshot remains available after caller mutation"), Subsystem->TryGetCrashContextSnapshot(Fresh));
	TestEqual(TEXT("Caller mutation cannot reach subsystem state"), Fresh.RunId, FString(TEXT("run-148")));

	const int32 ChangesBeforeRejected = Changes;
	const FString Oversized = FString::ChrN(AethelnObservability::MaxIdentifierLength + 1, TCHAR('x'));
	TestFalse(
		TEXT("Invalid runtime replacement is rejected"),
		Subsystem->SetRuntimeContext(EAethelnFlowKind::PrototypeAuthority, TEXT("run-replacement"), Oversized, AethelnObservability::ExcludedIdentifier));
	FAethelnBuildIdentity InvalidBuild = Build;
	InvalidBuild.BuildIdentity = FString::Printf(TEXT("build%cunsafe"), TCHAR(0x2029));
	TestFalse(TEXT("Invalid build replacement is rejected"), Subsystem->SetBuildContext(InvalidBuild, Profile));
	FAethelnNetworkProfile InvalidProfile = Profile;
	InvalidProfile.SchemaVersion = AethelnNetworkSpike::NetworkProfileSchemaVersion + 1;
	TestFalse(TEXT("Invalid profile replacement is rejected"), Subsystem->SetBuildContext(Build, InvalidProfile));
	TestEqual(TEXT("Rejected replacements never broadcast a change"), Changes, ChangesBeforeRejected);
	TestTrue(TEXT("Prior accepted context still yields a snapshot"), Subsystem->TryGetCrashContextSnapshot(Fresh));
	TestEqual(TEXT("Invalid runtime replacement preserves the prior run"), Fresh.RunId, FString(TEXT("run-148")));
	TestEqual(TEXT("Invalid runtime replacement preserves the prior instance"), Fresh.ServerInstanceId, FString(TEXT("instance-148")));
	TestEqual(TEXT("Invalid build replacement preserves the prior build"), Fresh.BuildIdentity, Build.BuildIdentity);
	TestEqual(TEXT("Invalid profile replacement preserves the prior profile version"), Fresh.NetworkProfileSchemaVersion, AethelnNetworkSpike::NetworkProfileSchemaVersion);

	Subsystem->ResetRuntimeContext();
	FAethelnCrashContextSnapshot AfterReset = Sentinel;
	TestFalse(TEXT("Runtime reset cannot return stale identity"), Subsystem->TryGetCrashContextSnapshot(AfterReset));
	TestEqual(TEXT("Runtime reset leaves output unchanged"), AfterReset.RunId, Sentinel.RunId);
	TestTrue(
		TEXT("Runtime context is restored after reset"),
		Subsystem->SetRuntimeContext(EAethelnFlowKind::PrototypeAuthority, TEXT("run-149"), TEXT("instance-149"), AethelnObservability::ExcludedIdentifier));
	const int32 ChangesBeforeBuildReset = Changes;
	Subsystem->ResetBuildContext();
	TestEqual(TEXT("Build reset broadcasts one change"), Changes, ChangesBeforeBuildReset + 1);
	TestFalse(TEXT("Build reset cannot return stale identity"), Subsystem->TryGetCrashContextSnapshot(AfterReset));
	TestEqual(TEXT("Build reset leaves output unchanged"), AfterReset.RunId, Sentinel.RunId);

	TestTrue(TEXT("Build context is restored"), Subsystem->SetBuildContext(Build, Profile));
	Subsystem->SetRuntimeContext(EAethelnFlowKind::PrototypeAuthority, TEXT("run-150"), TEXT("instance-150"), TEXT("user@example.com"));
	TestFalse(TEXT("A printable non-excluded runtime pseudonym never yields process-wide crash context"), Subsystem->TryGetCrashContextSnapshot(AfterReset));
	TestEqual(TEXT("Rejected pseudonym leaves output unchanged"), AfterReset.RunId, Sentinel.RunId);

	UAethelnObservabilitySubsystem::OnCrashContextChanged().Remove(ChangeHandle);
	Subsystem->ResetRuntimeContext();
	Subsystem->ResetBuildContext();
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
		MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(8);
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
	MovementRejectionEvent.SafeReason = EAethelnSafeReason::Rejected;
	MovementRejectionEvent.DiagnosticCode = EAethelnDiagnosticCode::ValidationFailed;
	FAethelnObservabilityEventContext MovementRejectionContext;
	MovementRejectionContext.Sequence = 24;
	Subsystem->EmitEvent(MovementRejectionEvent, MovementRejectionContext);
	TestTrue(TEXT("Movement rejection dispatch drains"), Subsystem->WaitForIdleForTests());
	TestEqual(TEXT("Movement rejection without fabricated combat identities reaches the sink"), RecordedSink->GetEvents().Num(), 3);
	TestEqual(TEXT("Movement rejection retains its authoritative subject"), RecordedSink->GetEvents()[2].SubjectCategory, EAethelnObservabilityCategory::Movement);
	TestEqual(TEXT("Public movement rejection retains its safe rejection reason"), RecordedSink->GetEvents()[2].SafeReason, EAethelnSafeReason::Rejected);
	TestTrue(TEXT("Movement rejection has no fabricated ability identity"), RecordedSink->GetEvents()[2].Correlation.AbilityId.IsEmpty());
	TestEqual(TEXT("Public movement rejection removes diagnostic detail"), RecordedSink->GetEvents()[2].DiagnosticCode, EAethelnDiagnosticCode::None);
	TestEqual(TEXT("Restricted channel retained every emitted event"), RecordedRestrictedSink->GetEvents().Num(), 3);
	TestEqual(TEXT("Restricted movement rejection retains its safe rejection reason"), RecordedRestrictedSink->GetEvents()[2].SafeReason, EAethelnSafeReason::Rejected);
	TestEqual(TEXT("Restricted movement rejection retains diagnostic detail"), RecordedRestrictedSink->GetEvents()[2].DiagnosticCode, EAethelnDiagnosticCode::ValidationFailed);

	FAethelnObservabilityEvent MovementCorrectionEvent;
	MovementCorrectionEvent.Category = EAethelnObservabilityCategory::Correction;
	MovementCorrectionEvent.SubjectCategory = EAethelnObservabilityCategory::Movement;
	MovementCorrectionEvent.SafeReason = EAethelnSafeReason::Corrected;
	FAethelnObservabilityEventContext MovementCorrectionContext;
	MovementCorrectionContext.Sequence = 25;
	Subsystem->EmitEvent(MovementCorrectionEvent, MovementCorrectionContext);
	TestTrue(TEXT("Movement correction dispatch drains"), Subsystem->WaitForIdleForTests());
	TestEqual(TEXT("Movement correction reaches the sink"), RecordedSink->GetEvents().Num(), 4);
	TestEqual(
		TEXT("Movement correction retains the corrected subject"),
		RecordedSink->GetEvents()[3].SubjectCategory,
		EAethelnObservabilityCategory::Movement);
	TestTrue(TEXT("Movement correction has no fabricated ability identity"), RecordedSink->GetEvents()[3].Correlation.AbilityId.IsEmpty());
	FAethelnObservabilityEvent MissingCorrectionSubject = MovementCorrectionEvent;
	MissingCorrectionSubject.SubjectCategory = EAethelnObservabilityCategory::ServerLifecycle;
	MovementCorrectionContext.Sequence = 26;
	Subsystem->EmitEvent(MissingCorrectionSubject, MovementCorrectionContext);
	FAethelnObservabilityEvent SelfReferentialCorrection = MovementCorrectionEvent;
	SelfReferentialCorrection.SubjectCategory = EAethelnObservabilityCategory::Correction;
	MovementCorrectionContext.Sequence = 27;
	Subsystem->EmitEvent(SelfReferentialCorrection, MovementCorrectionContext);
	TestTrue(TEXT("Invalid correction subjects leave dispatch idle"), Subsystem->WaitForIdleForTests());
	TestEqual(TEXT("Corrections without a concrete gameplay subject are suppressed"), RecordedSink->GetEvents().Num(), 4);

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
	TestEqual(TEXT("Invalid rejection context suppresses void emission"), RecordedSink->GetEvents().Num(), 4);

	RecordedSink->SetFailWrites(true);
	Subsystem->EmitEvent(Event, Overlay);
	Subsystem->EmitMetric(FAethelnMetricSample());
	TestTrue(TEXT("Failed injected writes drain without escaping"), Subsystem->WaitForIdleForTests());
	TestEqual(TEXT("Sink event failure does not escape or alter state"), RecordedSink->GetEvents().Num(), 4);
	TestEqual(TEXT("Sink metric failure does not escape or alter state"), RecordedSink->GetMetrics().Num(), 2);

	TestFalse(
		TEXT("Null sink injection is rejected without replacing the active sink"),
		Subsystem->SetTestSink(UAethelnObservabilitySubsystem::FSinkPtr()));
	RecordedSink->SetFailWrites(false);
	Subsystem->EmitEvent(Event, Overlay);
	TestTrue(TEXT("Preserved injected sink dispatch drains"), Subsystem->WaitForIdleForTests());
	TestEqual(TEXT("Rejected injection preserves the active sink"), RecordedSink->GetEvents().Num(), 5);

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

namespace AethelnCrashContextTests
{
	using namespace AethelnCrashContext;

	/** Restores only the crash GameData keys the crash-context owner writes. */
	class FScopedOwnedCrashKeyRestore
	{
	public:
		FScopedOwnedCrashKeyRestore()
		{
			Save(StateKey);
			for (const TCHAR* Key : IdentityKeys)
			{
				Save(Key);
			}
		}

		~FScopedOwnedCrashKeyRestore()
		{
			for (const TPair<FString, TOptional<FString>>& Entry : Saved)
			{
				FGenericCrashContext::SetGameData(Entry.Key, Entry.Value.IsSet() ? Entry.Value.GetValue() : FString());
			}
		}

	private:
		void Save(const TCHAR* Key)
		{
			const FString* Value = FGenericCrashContext::GetGameData().Find(Key);
			Saved.Add(Key, Value != nullptr ? TOptional<FString>(*Value) : TOptional<FString>());
		}

		TMap<FString, TOptional<FString>> Saved;
	};

	FString ReadKey(const TCHAR* Key)
	{
		const FString* Value = FGenericCrashContext::GetGameData().Find(Key);
		return Value != nullptr ? *Value : FString();
	}

	bool HasAnyIdentityKey()
	{
		for (const TCHAR* Key : IdentityKeys)
		{
			if (FGenericCrashContext::GetGameData().Find(Key) != nullptr)
			{
				return true;
			}
		}
		return false;
	}

	bool AnyOwnedKeyContains(const FString& Needle)
	{
		for (const TCHAR* Key : IdentityKeys)
		{
			if (ReadKey(Key).Contains(Needle))
			{
				return true;
			}
		}
		return ReadKey(StateKey).Contains(Needle);
	}

	FAethelnCrashContextSnapshot MakeSnapshot(const TCHAR* Suffix)
	{
		FAethelnBuildIdentity Build;
		Build.SourceRevision = FString::Printf(TEXT("revision-%s"), Suffix);
		Build.BuildIdentity = FString::Printf(TEXT("build-%s"), Suffix);
		Build.BuildConfiguration = FString::Printf(TEXT("configuration-%s"), Suffix);
		Build.EngineRevision = FString::Printf(TEXT("engine-%s"), Suffix);
		Build.ToolchainIdentity = FString::Printf(TEXT("toolchain-%s"), Suffix);
		FAethelnNetworkProfile Profile;
		Profile.ProfileId = FString::Printf(TEXT("network-profile.%s"), Suffix);
		FAethelnCrashContextSnapshot Snapshot;
		FAethelnCrashContextSnapshot::TryMakeValidated(
			Build,
			Profile,
			EAethelnFlowKind::PrototypeAuthority,
			FString::Printf(TEXT("run-%s"), Suffix),
			FString::Printf(TEXT("instance-%s"), Suffix),
			AethelnObservability::ExcludedIdentifier,
			Snapshot);
		return Snapshot;
	}

	FAethelnBuildIdentity MakeBuild(const TCHAR* BuildIdentity)
	{
		FAethelnBuildIdentity Build;
		Build.SourceRevision = TEXT("revision-owner");
		Build.BuildIdentity = BuildIdentity;
		Build.BuildConfiguration = TEXT("Development");
		Build.EngineRevision = TEXT("5.8.1");
		Build.ToolchainIdentity = TEXT("toolchain-owner");
		return Build;
	}

	/** Game world plus owning game instance, created and destroyed by the test. */
	struct FTestGameWorld
	{
		UWorld* World = nullptr;
		UGameInstance* GameInstance = nullptr;
		UAethelnObservabilitySubsystem* Subsystem = nullptr;

		bool Create(const TCHAR* RunId, const TCHAR* InstanceId)
		{
			World = UWorld::CreateWorld(EWorldType::Game, false);
			if (World == nullptr || GEngine == nullptr)
			{
				return false;
			}
			FWorldContext& WorldContext = GEngine->CreateNewWorldContext(EWorldType::Game);
			GameInstance = NewObject<UGameInstance>(GEngine);
			WorldContext.OwningGameInstance = GameInstance;
			World->SetGameInstance(GameInstance);
			WorldContext.SetCurrentWorld(World);
			GameInstance->Init();
			Subsystem = GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>();
			FAethelnNetworkProfile Profile;
			Profile.ProfileId = TEXT("network-profile.owner");
			return Subsystem != nullptr
				&& Subsystem->SetRuntimeContext(
					EAethelnFlowKind::PrototypeAuthority,
					RunId,
					InstanceId,
					AethelnObservability::ExcludedIdentifier)
				&& Subsystem->SetBuildContext(MakeBuild(TEXT("build-owner")), Profile);
		}

		void Destroy()
		{
			if (GameInstance != nullptr)
			{
				GameInstance->Shutdown();
			}
			if (World != nullptr)
			{
				World->DestroyWorld(false);
				if (GEngine != nullptr)
				{
					GEngine->DestroyWorldContext(World);
				}
			}
			World = nullptr;
			GameInstance = nullptr;
			Subsystem = nullptr;
		}
	};
}

// Crash-context tests own their FAethelnCrashContextOwner instead of broadcasting to a
// live module, so a Server target's own map world cannot make them ambiguous.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnCrashContextRegistrationTest,
	"Aetheln.Observability.CrashContext.Registration",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::ServerContext | EAutomationTestFlags::EngineFilter)

bool FAethelnCrashContextRegistrationTest::RunTest(const FString& Parameters)
{
	using namespace AethelnCrashContext;
	using namespace AethelnCrashContextTests;
	const FScopedOwnedCrashKeyRestore Restore;

	TArray<TPair<FString, FString>> Writes;
	TSet<FString> OwnedKeys;
	OwnedKeys.Add(StateKey);
	for (const TCHAR* Key : IdentityKeys)
	{
		OwnedKeys.Add(Key);
	}
	const FDelegateHandle WriteHandle = FGenericCrashContext::OnGameDataSetDelegate().AddLambda(
		[&Writes, &OwnedKeys](const FString& Key, const FString& Value)
		{
			if (OwnedKeys.Contains(Key))
			{
				Writes.Emplace(Key, Value);
			}
		});

	TestEqual(TEXT("State key is stable"), FString(StateKey), FString(TEXT("AethelnCrashContextState")));
	TestEqual(TEXT("Crash context owns exactly thirteen identity keys"), static_cast<int32>(UE_ARRAY_COUNT(IdentityKeys)), 13);

	FAethelnCrashContextOwner Owner;
	Owner.Initialize();
	TestEqual(TEXT("Initialization claims no run"), ReadKey(StateKey), FString(TEXT("missing")));
	TestFalse(TEXT("Initialization leaves no identity key"), HasAnyIdentityKey());

	const FAethelnCrashContextSnapshot First = MakeSnapshot(TEXT("first"));
	TestTrue(TEXT("First fixture snapshot is bounded"), First.IsBounded());
	Writes.Reset();
	Owner.Register(&First);
	TestTrue(TEXT("First registration writes state, thirteen values, and state"), Writes.Num() == 15);
	if (Writes.Num() == 15)
	{
		TestEqual(TEXT("Registration begins with the updating state"), Writes[0].Key, FString(StateKey));
		TestEqual(TEXT("Registration begins in updating"), Writes[0].Value, FString(TEXT("updating")));
		TestEqual(TEXT("Registration ends with the state key"), Writes.Last().Key, FString(StateKey));
		TestEqual(TEXT("Registration ends in active"), Writes.Last().Value, FString(TEXT("active")));
	}
	TestEqual(TEXT("Active state is registered"), ReadKey(StateKey), FString(TEXT("active")));
	TestEqual(TEXT("Schema version is registered"), ReadKey(SchemaVersionKey), FString(TEXT("1")));
	TestEqual(TEXT("Source revision is registered"), ReadKey(SourceRevisionKey), First.SourceRevision);
	TestEqual(TEXT("Build identity is registered"), ReadKey(BuildIdentityKey), First.BuildIdentity);
	TestEqual(TEXT("Build configuration is registered"), ReadKey(BuildConfigurationKey), First.BuildConfiguration);
	TestEqual(TEXT("Engine revision is registered"), ReadKey(EngineRevisionKey), First.EngineRevision);
	TestEqual(TEXT("Toolchain identity is registered"), ReadKey(ToolchainIdentityKey), First.ToolchainIdentity);
	TestEqual(TEXT("Network-profile schema is registered"), ReadKey(NetworkProfileSchemaKey), FString(AethelnNetworkSpike::NetworkProfileSchemaId));
	TestEqual(TEXT("Network-profile version is registered"), ReadKey(NetworkProfileVersionKey), FString(TEXT("1")));
	TestEqual(TEXT("Network-profile identity is registered"), ReadKey(NetworkProfileIdKey), First.NetworkProfileId);
	TestEqual(TEXT("Flow kind is registered"), ReadKey(FlowKindKey), FString(TEXT("prototype-authority")));
	TestEqual(TEXT("Run is registered"), ReadKey(RunIdKey), First.RunId);
	TestEqual(TEXT("Server instance is registered"), ReadKey(ServerInstanceKey), First.ServerInstanceId);
	TestEqual(TEXT("Connection pseudonym is the excluded marker"), ReadKey(ConnectionPseudonymKey), FString(AethelnObservability::ExcludedIdentifier));

	const FAethelnCrashContextSnapshot Second = MakeSnapshot(TEXT("second"));
	Owner.Register(&Second);
	TestEqual(TEXT("Valid replacement is active"), ReadKey(StateKey), FString(TEXT("active")));
	TestEqual(TEXT("Valid replacement registers the new run"), ReadKey(RunIdKey), Second.RunId);
	TestFalse(TEXT("Valid replacement leaves no prior unique value"), AnyOwnedKeyContains(TEXT("first")));

	FAethelnCrashContextSnapshot Invalid = MakeSnapshot(TEXT("third"));
	Invalid.RunId = FString::Printf(TEXT("run%cthird"), TCHAR(0x2028));
	TestFalse(TEXT("Tampered snapshot is not bounded"), Invalid.IsBounded());
	Owner.Register(&Invalid);
	TestEqual(TEXT("Invalid snapshot marks the context missing"), ReadKey(StateKey), FString(TEXT("missing")));
	TestFalse(TEXT("Invalid snapshot clears every identity key"), HasAnyIdentityKey());
	TestFalse(TEXT("Invalid snapshot never partially overwrites"), AnyOwnedKeyContains(TEXT("third")));
	TestFalse(TEXT("Invalid snapshot leaves no prior value"), AnyOwnedKeyContains(TEXT("second")));

	FAethelnCrashContextSnapshot Personal = MakeSnapshot(TEXT("fourth"));
	Personal.ConnectionPseudonym = TEXT("user@example.com");
	Owner.Register(&Personal);
	TestEqual(TEXT("A non-excluded pseudonym marks the context missing"), ReadKey(StateKey), FString(TEXT("missing")));
	TestFalse(TEXT("A non-excluded pseudonym never reaches crash GameData"), AnyOwnedKeyContains(TEXT("example.com")));

	Owner.Register(&First);
	Owner.Register(nullptr);
	TestEqual(TEXT("Missing snapshot marks the context missing"), ReadKey(StateKey), FString(TEXT("missing")));
	TestFalse(TEXT("Missing snapshot clears every identity key"), HasAnyIdentityKey());

	Owner.Register(&First);
	Owner.MarkStale();
	TestEqual(TEXT("Stale context is explicit"), ReadKey(StateKey), FString(TEXT("stale")));
	TestFalse(TEXT("Stale context clears every identity key"), HasAnyIdentityKey());
	Owner.Register(&Second);
	TestEqual(TEXT("A later valid owner replaces stale context"), ReadKey(StateKey), FString(TEXT("active")));

	Owner.MarkAmbiguous();
	TestEqual(TEXT("Ambiguous ownership is explicit"), ReadKey(StateKey), FString(TEXT("ambiguous")));
	TestFalse(TEXT("Ambiguous ownership clears every identity key"), HasAnyIdentityKey());
	Owner.Register(&First);
	TestEqual(TEXT("A later valid owner replaces ambiguous context"), ReadKey(StateKey), FString(TEXT("active")));

	Owner.Shutdown();
	TestEqual(TEXT("Shutdown marks the context stale"), ReadKey(StateKey), FString(TEXT("stale")));
	TestFalse(TEXT("Shutdown clears every identity key"), HasAnyIdentityKey());

	FGenericCrashContext::OnGameDataSetDelegate().Remove(WriteHandle);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnCrashContextWorldOwnershipTest,
	"Aetheln.Observability.CrashContext.WorldOwnership",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::ServerContext | EAutomationTestFlags::EngineFilter)

bool FAethelnCrashContextWorldOwnershipTest::RunTest(const FString& Parameters)
{
	using namespace AethelnCrashContext;
	using namespace AethelnCrashContextTests;
	const FScopedOwnedCrashKeyRestore Restore;

	FTestGameWorld First;
	FTestGameWorld Second;
	const bool bCreated = First.Create(TEXT("run-world-alpha"), TEXT("instance-world-alpha"))
		&& Second.Create(TEXT("run-world-beta"), TEXT("instance-world-beta"));
	TestTrue(TEXT("Two independent game worlds were created"), bCreated);
	if (!bCreated)
	{
		First.Destroy();
		Second.Destroy();
		return false;
	}

	FAethelnCrashContextOwner Owner;
	Owner.Initialize();
	TestTrue(TEXT("The first world is new"), Owner.TrackWorldTick(First.World));
	TestEqual(TEXT("A single observable world registers active context"), ReadKey(StateKey), FString(TEXT("active")));
	TestEqual(TEXT("The single owner supplies the run"), ReadKey(RunIdKey), FString(TEXT("run-world-alpha")));
	TestEqual(TEXT("The single owner supplies the server instance"), ReadKey(ServerInstanceKey), FString(TEXT("instance-world-alpha")));
	TestEqual(TEXT("Process-wide context keeps the connection excluded"), ReadKey(ConnectionPseudonymKey), FString(AethelnObservability::ExcludedIdentifier));

	TestTrue(TEXT("The second world is new"), Owner.TrackWorldTick(Second.World));
	TestEqual(TEXT("Two observable worlds mark the context ambiguous"), ReadKey(StateKey), FString(TEXT("ambiguous")));
	TestFalse(TEXT("Ambiguous context clears every identity key"), HasAnyIdentityKey());
	TestFalse(TEXT("A later tick is not a new world"), Owner.TrackWorldTick(First.World));
	TestFalse(TEXT("Ambiguous context never attributes the first run"), AnyOwnedKeyContains(TEXT("alpha")));
	TestFalse(TEXT("Ambiguous context never attributes the second run"), AnyOwnedKeyContains(TEXT("beta")));

	Owner.EndTracking(First.World);
	TestEqual(TEXT("World cleanup marks the context stale"), ReadKey(StateKey), FString(TEXT("stale")));
	TestFalse(TEXT("World cleanup clears every identity key"), HasAnyIdentityKey());
	TestEqual(TEXT("One world remains tracked"), Owner.NumTrackedWorlds(), 1);

	Owner.TrackWorldTick(Second.World);
	TestEqual(TEXT("A later single owner replaces stale context"), ReadKey(StateKey), FString(TEXT("active")));
	TestEqual(TEXT("The later single owner supplies its run"), ReadKey(RunIdKey), FString(TEXT("run-world-beta")));
	TestFalse(TEXT("The cleaned-up owner leaves no identity"), AnyOwnedKeyContains(TEXT("alpha")));

	Owner.EndTracking(Second.World);
	TestEqual(TEXT("Final cleanup marks the context stale"), ReadKey(StateKey), FString(TEXT("stale")));
	TestFalse(TEXT("Final cleanup clears every identity key"), HasAnyIdentityKey());

	Owner.Shutdown();
	First.Destroy();
	Second.Destroy();
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnCrashContextAcceptedChangeTest,
	"Aetheln.Observability.CrashContext.FollowsAcceptedChanges",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::ServerContext | EAutomationTestFlags::EngineFilter)

bool FAethelnCrashContextAcceptedChangeTest::RunTest(const FString& Parameters)
{
	using namespace AethelnCrashContext;
	using namespace AethelnCrashContextTests;
	const FScopedOwnedCrashKeyRestore Restore;

	FTestGameWorld World;
	if (!World.Create(TEXT("run-change-first"), TEXT("instance-change-first")))
	{
		TestTrue(TEXT("Game world was created"), false);
		World.Destroy();
		return false;
	}
	UAethelnObservabilitySubsystem& Subsystem = *World.Subsystem;
	FAethelnNetworkProfile Profile;
	Profile.ProfileId = TEXT("network-profile.change");

	FAethelnCrashContextOwner Owner;
	Owner.Initialize();
	Owner.TrackWorldTick(World.World);
	TestEqual(TEXT("The sole world registers active context"), ReadKey(StateKey), FString(TEXT("active")));
	TestEqual(TEXT("The first run is registered"), ReadKey(RunIdKey), FString(TEXT("run-change-first")));

	TestTrue(
		TEXT("Valid runtime replacement is accepted"),
		Subsystem.SetRuntimeContext(EAethelnFlowKind::PrototypeAuthority, TEXT("run-change-second"), TEXT("instance-change-second"), AethelnObservability::ExcludedIdentifier));
	TestEqual(TEXT("Runtime replacement refreshes before another tick"), ReadKey(StateKey), FString(TEXT("active")));
	TestEqual(TEXT("Runtime replacement registers the new run"), ReadKey(RunIdKey), FString(TEXT("run-change-second")));
	TestEqual(TEXT("Runtime replacement registers the new instance"), ReadKey(ServerInstanceKey), FString(TEXT("instance-change-second")));
	TestFalse(TEXT("Runtime replacement leaves no prior run"), AnyOwnedKeyContains(TEXT("change-first")));

	const FString Oversized = FString::ChrN(AethelnObservability::MaxIdentifierLength + 1, TCHAR('x'));
	TestFalse(
		TEXT("Invalid runtime replacement is rejected"),
		Subsystem.SetRuntimeContext(EAethelnFlowKind::PrototypeAuthority, TEXT("run-change-third"), Oversized, AethelnObservability::ExcludedIdentifier));
	TestEqual(TEXT("Invalid runtime replacement keeps the registration active"), ReadKey(StateKey), FString(TEXT("active")));
	TestEqual(TEXT("Invalid runtime replacement keeps the last valid run"), ReadKey(RunIdKey), FString(TEXT("run-change-second")));
	TestFalse(TEXT("Invalid runtime replacement never reaches crash GameData"), AnyOwnedKeyContains(TEXT("change-third")));

	const bool bPrintableAccepted = Subsystem.SetRuntimeContext(
		EAethelnFlowKind::PrototypeAuthority,
		TEXT("run-change-personal"),
		TEXT("instance-change-personal"),
		TEXT("user@example.com"));
	TestFalse(TEXT("Printable personal text never reaches crash GameData"), AnyOwnedKeyContains(TEXT("example.com")));
	if (bPrintableAccepted)
	{
		TestEqual(TEXT("A non-excluded process pseudonym marks the context missing"), ReadKey(StateKey), FString(TEXT("missing")));
		TestFalse(TEXT("A non-excluded process pseudonym clears every identity key"), HasAnyIdentityKey());
	}

	TestTrue(
		TEXT("Valid runtime context is restored"),
		Subsystem.SetRuntimeContext(EAethelnFlowKind::PrototypeAuthority, TEXT("run-change-fourth"), TEXT("instance-change-fourth"), AethelnObservability::ExcludedIdentifier));
	TestEqual(TEXT("Restored runtime context is active before another tick"), ReadKey(StateKey), FString(TEXT("active")));
	TestEqual(TEXT("Restored runtime context registers its run"), ReadKey(RunIdKey), FString(TEXT("run-change-fourth")));

	Subsystem.ResetRuntimeContext();
	TestEqual(TEXT("Runtime reset marks the context missing before another tick"), ReadKey(StateKey), FString(TEXT("missing")));
	TestFalse(TEXT("Runtime reset clears every identity key"), HasAnyIdentityKey());
	TestTrue(
		TEXT("Runtime context is set after reset"),
		Subsystem.SetRuntimeContext(EAethelnFlowKind::PrototypeAuthority, TEXT("run-change-fifth"), TEXT("instance-change-fifth"), AethelnObservability::ExcludedIdentifier));
	TestEqual(TEXT("Runtime context after reset is active"), ReadKey(StateKey), FString(TEXT("active")));

	TestTrue(TEXT("Valid build replacement is accepted"), Subsystem.SetBuildContext(MakeBuild(TEXT("build-change-replacement")), Profile));
	TestEqual(TEXT("Build replacement registers before another tick"), ReadKey(BuildIdentityKey), FString(TEXT("build-change-replacement")));
	TestEqual(TEXT("Build replacement registers the new profile"), ReadKey(NetworkProfileIdKey), FString(TEXT("network-profile.change")));
	TestEqual(TEXT("Build replacement keeps the registration active"), ReadKey(StateKey), FString(TEXT("active")));
	FAethelnBuildIdentity InvalidBuild = MakeBuild(TEXT("build-change-invalid"));
	InvalidBuild.BuildIdentity = FString::Printf(TEXT("build%cunsafe"), TCHAR(0x2029));
	TestFalse(TEXT("Invalid build replacement is rejected"), Subsystem.SetBuildContext(InvalidBuild, Profile));
	TestEqual(TEXT("Invalid build replacement keeps the last valid build"), ReadKey(BuildIdentityKey), FString(TEXT("build-change-replacement")));
	TestEqual(TEXT("Invalid build replacement keeps the registration active"), ReadKey(StateKey), FString(TEXT("active")));

	Subsystem.ResetBuildContext();
	TestEqual(TEXT("Build reset marks the context missing before another tick"), ReadKey(StateKey), FString(TEXT("missing")));
	TestFalse(TEXT("Build reset clears every identity key"), HasAnyIdentityKey());
	TestTrue(TEXT("Build context is restored"), Subsystem.SetBuildContext(MakeBuild(TEXT("build-change-restored")), Profile));
	TestEqual(TEXT("Restored build context is active"), ReadKey(StateKey), FString(TEXT("active")));
	TestEqual(TEXT("Restored build context registers the run"), ReadKey(RunIdKey), FString(TEXT("run-change-fifth")));

	Owner.EndTracking(World.World);
	TestEqual(TEXT("Cleanup marks the context stale"), ReadKey(StateKey), FString(TEXT("stale")));
	TestTrue(
		TEXT("Changes after cleanup are accepted by the subsystem"),
		Subsystem.SetRuntimeContext(EAethelnFlowKind::PrototypeAuthority, TEXT("run-change-after"), TEXT("instance-change-after"), AethelnObservability::ExcludedIdentifier));
	TestEqual(TEXT("An untracked world cannot re-register crash context"), ReadKey(StateKey), FString(TEXT("stale")));
	TestFalse(TEXT("An untracked world leaves no identity"), HasAnyIdentityKey());

	Owner.Shutdown();
	World.Destroy();
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnCrashContextWorldCountTest,
	"Aetheln.Observability.CrashContext.CountsWorldsWithoutSubsystem",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::ServerContext | EAutomationTestFlags::EngineFilter)

bool FAethelnCrashContextWorldCountTest::RunTest(const FString& Parameters)
{
	using namespace AethelnCrashContext;
	using namespace AethelnCrashContextTests;
	const FScopedOwnedCrashKeyRestore Restore;

	FTestGameWorld Valid;
	UWorld* Bare = UWorld::CreateWorld(EWorldType::Game, false);
	const bool bCreated = Valid.Create(TEXT("run-count-alpha"), TEXT("instance-count-alpha")) && Bare != nullptr;
	TestTrue(TEXT("A subsystem-owning world and a bare world were created"), bCreated);
	if (!bCreated)
	{
		Valid.Destroy();
		if (Bare != nullptr)
		{
			Bare->DestroyWorld(false);
		}
		return false;
	}
	TestNull(TEXT("The bare observable world has no observability subsystem"), FindObservabilitySubsystem(Bare));

	FAethelnCrashContextOwner Owner;
	Owner.Initialize();
	Owner.TrackWorldTick(Valid.World);
	TestEqual(TEXT("The sole world registers active context"), ReadKey(StateKey), FString(TEXT("active")));

	TestTrue(TEXT("A world without a subsystem is counted"), Owner.TrackWorldTick(Bare));
	TestEqual(TEXT("Two worlds are tracked"), Owner.NumTrackedWorlds(), 2);
	TestEqual(TEXT("A second world without a subsystem marks the context ambiguous"), ReadKey(StateKey), FString(TEXT("ambiguous")));
	TestFalse(TEXT("Ambiguous context clears every identity key"), HasAnyIdentityKey());
	Owner.TrackWorldTick(Valid.World);
	TestTrue(
		TEXT("A change while ambiguous is accepted by the subsystem"),
		Valid.Subsystem->SetRuntimeContext(EAethelnFlowKind::PrototypeAuthority, TEXT("run-count-beta"), TEXT("instance-count-beta"), AethelnObservability::ExcludedIdentifier));
	TestEqual(TEXT("Ambiguous context stays ambiguous"), ReadKey(StateKey), FString(TEXT("ambiguous")));
	TestFalse(TEXT("Ambiguous context never attributes the first run"), AnyOwnedKeyContains(TEXT("count-alpha")));
	TestFalse(TEXT("Ambiguous context never attributes a changed run"), AnyOwnedKeyContains(TEXT("count-beta")));

	Owner.EndTracking(Bare);
	TestEqual(TEXT("Bare-world cleanup marks the context stale"), ReadKey(StateKey), FString(TEXT("stale")));
	Owner.TrackWorldTick(Valid.World);
	TestEqual(TEXT("The remaining valid world recovers active context"), ReadKey(StateKey), FString(TEXT("active")));
	TestEqual(TEXT("The recovered context registers the current run"), ReadKey(RunIdKey), FString(TEXT("run-count-beta")));

	Owner.TrackWorldTick(Bare);
	TestEqual(TEXT("A re-entering bare world marks the context ambiguous"), ReadKey(StateKey), FString(TEXT("ambiguous")));
	Owner.EndTracking(Valid.World);
	TestEqual(TEXT("Valid-world cleanup marks the context stale"), ReadKey(StateKey), FString(TEXT("stale")));
	Owner.TrackWorldTick(Bare);
	TestEqual(TEXT("A sole world without a subsystem marks the context missing"), ReadKey(StateKey), FString(TEXT("missing")));
	TestFalse(TEXT("A sole world without a subsystem leaves no identity"), HasAnyIdentityKey());

	Owner.EndTracking(Bare);
	TestEqual(TEXT("Final cleanup marks the context stale"), ReadKey(StateKey), FString(TEXT("stale")));
	TestEqual(TEXT("No world remains tracked"), Owner.NumTrackedWorlds(), 0);

	Owner.Shutdown();
	Valid.Destroy();
	Bare->DestroyWorld(false);
	return true;
}
#endif
