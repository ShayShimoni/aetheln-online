#include "AethelnObservability.h"

#if WITH_DEV_AUTOMATION_TESTS
#include "HAL/Event.h"
#include "HAL/PlatformProcess.h"
#include "Misc/AutomationTest.h"
#include "Misc/ScopeLock.h"

#include <atomic>

namespace AethelnObservabilityTests
{
	class FBlockingPublicSink final : public IAethelnObservabilitySink
	{
	public:
		FBlockingPublicSink()
			: Entered(FPlatformProcess::GetSynchEventFromPool(true))
			, Release(FPlatformProcess::GetSynchEventFromPool(true))
		{
		}

		virtual ~FBlockingPublicSink() override
		{
			Release->Trigger();
			FPlatformProcess::ReturnSynchEventToPool(Entered);
			FPlatformProcess::ReturnSynchEventToPool(Release);
		}

		virtual bool TryRecordEvent(const FAethelnObservabilityEvent& Event) override
		{
			Calls.fetch_add(1, std::memory_order_relaxed);
			Entered->Trigger();
			Release->Wait();
			FScopeLock Lock(&EventsMutex);
			Events.Add(Event);
			return true;
		}

		virtual bool TryRecordMetric(const FAethelnMetricSample&) override { return true; }
		bool WaitUntilEntered() const { return Entered->Wait(2000); }
		void ReleaseBlockedWrite() { Release->Trigger(); }
		int32 GetCalls() const { return Calls.load(std::memory_order_relaxed); }
		TArray<FAethelnObservabilityEvent> GetEvents() const
		{
			FScopeLock Lock(&EventsMutex);
			return Events;
		}

	private:
		FEvent* Entered;
		FEvent* Release;
		mutable FCriticalSection EventsMutex;
		TArray<FAethelnObservabilityEvent> Events;
		std::atomic<int32> Calls { 0 };
	};

	class FBlockingRestrictedSink final : public IAethelnRestrictedAuditSink
	{
	public:
		FBlockingRestrictedSink()
			: Entered(FPlatformProcess::GetSynchEventFromPool(true))
			, Release(FPlatformProcess::GetSynchEventFromPool(true))
		{
		}

		virtual ~FBlockingRestrictedSink() override
		{
			Release->Trigger();
			FPlatformProcess::ReturnSynchEventToPool(Entered);
			FPlatformProcess::ReturnSynchEventToPool(Release);
		}

		virtual bool TryRecordEvent(const FAethelnObservabilityEvent&) override
		{
			Calls.fetch_add(1, std::memory_order_relaxed);
			Entered->Trigger();
			Release->Wait();
			return true;
		}

		bool WaitUntilEntered() const { return Entered->Wait(2000); }
		void ReleaseBlockedWrite() { Release->Trigger(); }
		int32 GetCalls() const { return Calls.load(std::memory_order_relaxed); }

	private:
		FEvent* Entered;
		FEvent* Release;
		std::atomic<int32> Calls { 0 };
	};

	FAethelnObservabilityEvent MakeValidEvent(
		EAethelnObservabilityCategory Category = EAethelnObservabilityCategory::ServerLifecycle,
		EAethelnObservabilityCategory SubjectCategory = EAethelnObservabilityCategory::ServerLifecycle)
	{
		FAethelnObservabilityEvent Event;
		Event.Category = Category;
		Event.SubjectCategory = SubjectCategory;
		Event.SafeReason = EAethelnSafeReason::Accepted;
		Event.Correlation.RunId = TEXT("run-test");
		Event.Correlation.ConnectionPseudonym = AethelnObservability::ExcludedIdentifier;
		Event.Correlation.InstanceId = TEXT("instance-test");
		Event.Correlation.Sequence = 1;
		const bool bCombatActivationSubject = SubjectCategory == EAethelnObservabilityCategory::Ability
			|| SubjectCategory == EAethelnObservabilityCategory::Hit;
		if (bCombatActivationSubject)
		{
			Event.Correlation.AbilityId = TEXT("Ability.Test");
			if (Category != EAethelnObservabilityCategory::Rejection)
			{
				Event.Correlation.ActivationId = TEXT("activation-test");
			}
		}
		else if (SubjectCategory == EAethelnObservabilityCategory::Cooldown
			|| SubjectCategory == EAethelnObservabilityCategory::Dodge
			|| SubjectCategory == EAethelnObservabilityCategory::Block)
		{
			Event.Correlation.AbilityId = TEXT("Ability.Test");
		}
		return Event;
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnObservabilitySchemaTest,
	"Aetheln.Observability.Contracts.SchemaAndVocabulary",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnObservabilitySchemaTest::RunTest(const FString& Parameters)
{
	const FAethelnObservabilityEvent Event;
	TestEqual(TEXT("Schema identity is stable"), Event.SchemaId, FString(TEXT("aetheln.observability-event")));
	TestEqual(TEXT("Schema version is stable"), Event.SchemaVersion, static_cast<uint32>(1));
	TestFalse(TEXT("A default event cannot enter either observability channel"), Event.IsBounded());
	TestEqual(TEXT("Movement category is stable"), FString(LexToString(EAethelnObservabilityCategory::Movement)), FString(TEXT("movement")));
	TestEqual(TEXT("Respawn category is stable"), FString(LexToString(EAethelnObservabilityCategory::Respawn)), FString(TEXT("respawn")));
	TestEqual(TEXT("Event subject category is a closed enum"), Event.SubjectCategory, EAethelnObservabilityCategory::ServerLifecycle);
	TestEqual(TEXT("Safe rejection reason is stable"), FString(LexToString(EAethelnSafeReason::Rejected)), FString(TEXT("rejected")));
	TestEqual(TEXT("Controlled shutdown reason is stable"), FString(LexToString(EAethelnSafeReason::ControlledShutdown)), FString(TEXT("controlled-shutdown")));
	TestEqual(TEXT("Queue drop metric is stable"), FString(LexToString(EAethelnMetricKind::QueueDropCount)), FString(TEXT("queue-drop-count")));
	TestFalse(
		TEXT("Correction cannot use a server lifecycle default as its affected subject"),
		AethelnObservabilityTests::MakeValidEvent(
			EAethelnObservabilityCategory::Correction,
			EAethelnObservabilityCategory::ServerLifecycle).IsBounded());
	TestFalse(
		TEXT("Correction cannot be self-referential"),
		AethelnObservabilityTests::MakeValidEvent(
			EAethelnObservabilityCategory::Correction,
			EAethelnObservabilityCategory::Correction).IsBounded());
	TestEqual(TEXT("Admission extension is stable"), FString(LexToString(EAethelnFlowKind::Admission)), FString(TEXT("admission")));
	TestEqual(TEXT("Lease extension is stable"), FString(LexToString(EAethelnFlowKind::Lease)), FString(TEXT("lease")));
	TestEqual(TEXT("Persistent command extension is stable"), FString(LexToString(EAethelnFlowKind::PersistentCommand)), FString(TEXT("persistent-command")));
	TestEqual(TEXT("Transaction extension is stable"), FString(LexToString(EAethelnFlowKind::Transaction)), FString(TEXT("transaction")));
	TestEqual(TEXT("Outbox extension is stable"), FString(LexToString(EAethelnFlowKind::Outbox)), FString(TEXT("outbox")));
	TestEqual(TEXT("Reward extension is stable"), FString(LexToString(EAethelnFlowKind::Reward)), FString(TEXT("reward")));
	TestEqual(TEXT("Transfer extension is stable"), FString(LexToString(EAethelnFlowKind::Transfer)), FString(TEXT("transfer")));
	TestEqual(TEXT("Allocation extension is stable"), FString(LexToString(EAethelnFlowKind::Allocation)), FString(TEXT("allocation")));
	TestEqual(TEXT("Dependency extension is stable"), FString(LexToString(EAethelnFlowKind::Dependency)), FString(TEXT("dependency")));
	TestEqual(TEXT("Restore extension is stable"), FString(LexToString(EAethelnFlowKind::Restore)), FString(TEXT("restore")));
	TestEqual(TEXT("Reconciliation extension is stable"), FString(LexToString(EAethelnFlowKind::Reconciliation)), FString(TEXT("reconciliation")));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnObservabilityIdentityTest,
	"Aetheln.Observability.Contracts.IdentityAndRedaction",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnObservabilityIdentityTest::RunTest(const FString& Parameters)
{
	FAethelnObservabilityEvent Event;
	TestEqual(TEXT("Unknown build identity remains explicit"), Event.Build.BuildIdentity, FString(TEXT("unknown")));
	TestEqual(TEXT("Unset network profile remains explicit"), Event.NetworkProfile.ProfileId, FString(TEXT("network-profile.unset")));
	TestTrue(TEXT("Unset network values remain unset"), Event.NetworkProfile.HasUnsetNumericValues());

	const FString RawIdentifier(TEXT("raw-account-or-connection-123"));
	const FString ExcludedIdentifier(AethelnObservability::ExcludedIdentifier);
	TestEqual(TEXT("Excluded identifiers use the stable public marker"), ExcludedIdentifier, FString(TEXT("excluded")));
	TestFalse(TEXT("Excluded identifiers never contain caller-controlled identity"), ExcludedIdentifier.Contains(RawIdentifier));
	FAethelnCorrelationContext ExcludedContext;
	TestTrue(
		TEXT("Explicitly excluded connection identity remains a valid bounded correlation context"),
		FAethelnCorrelationContext::TryMakeValidated(
			EAethelnFlowKind::PrototypeAuthority,
			TEXT("run-a"),
			ExcludedIdentifier,
			TEXT("instance-a"),
			TEXT("activation-a"),
			TEXT("ability-a"),
			1,
			ExcludedContext));
	TestEqual(TEXT("Caller identity is replaced rather than transformed"), ExcludedContext.ConnectionPseudonym, ExcludedIdentifier);

	Event.DiagnosticCode = EAethelnDiagnosticCode::ValidationFailed;
	const FAethelnObservabilityEvent PublicEvent = Event.MakePublicCopy();
	TestEqual(TEXT("Internal diagnostic remains available internally"), Event.DiagnosticCode, EAethelnDiagnosticCode::ValidationFailed);
	TestEqual(TEXT("Public event excludes diagnostic detail"), PublicEvent.DiagnosticCode, EAethelnDiagnosticCode::None);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnObservabilityCorrelationContextTest,
	"Aetheln.Observability.Contracts.BoundedCorrelationContext",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnObservabilityCorrelationContextTest::RunTest(const FString& Parameters)
{
	FAethelnCorrelationContext Context;
	const bool bAccepted = FAethelnCorrelationContext::TryMakeValidated(
		EAethelnFlowKind::PrototypeAuthority,
		TEXT("run-17"),
		TEXT("connection-a1b2c3"),
		TEXT("instance-4"),
		TEXT("activation-5"),
		TEXT("ability-melee-combo1"),
		42,
		Context);
	TestTrue(TEXT("Bounded pre-pseudonymized context is accepted"), bAccepted);
	TestTrue(TEXT("Accepted context remains bounded"), Context.IsBounded());
	TestEqual(TEXT("Connection pseudonym is handed off unchanged"), Context.ConnectionPseudonym, FString(TEXT("connection-a1b2c3")));
	TestEqual(TEXT("Sequence is handed off unchanged"), Context.Sequence, static_cast<uint64>(42));

	const FAethelnCorrelationContext BeforeRejectedHandoff = Context;
	const FString Oversized = FString::ChrN(AethelnObservability::MaxIdentifierLength + 1, TCHAR('x'));
	const bool bRejected = FAethelnCorrelationContext::TryMakeValidated(
		EAethelnFlowKind::PrototypeAuthority,
		TEXT("run-17"),
		TEXT("connection-a1b2c3"),
		TEXT("instance-4"),
		TEXT("activation-5"),
		Oversized,
		43,
		Context);
	TestFalse(TEXT("Oversized allowlisted context is rejected"), bRejected);
	TestEqual(TEXT("Rejected handoff preserves the previous context"), Context.AbilityId, BeforeRejectedHandoff.AbilityId);
	TestEqual(TEXT("Rejected handoff preserves the previous sequence"), Context.Sequence, BeforeRejectedHandoff.Sequence);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnObservabilityCrashContextSnapshotTest,
	"Aetheln.Observability.Contracts.CrashContextSnapshot",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnObservabilityCrashContextSnapshotTest::RunTest(const FString& Parameters)
{
	// Only closed sentinels, engine-owned build values, and a generated run form a snapshot.
	FAethelnBuildIdentity Build;
	Build.BuildConfiguration = LexToString(FApp::GetBuildConfiguration());
	Build.EngineRevision = FEngineVersion::Current().ToString();
	FAethelnNetworkProfile Profile;
	const FString RunId = FGuid::NewGuid().ToString(EGuidFormats::DigitsLower);
	const FString Role = AethelnObservability::CrashServerRole;

	FAethelnCrashContextSnapshot Snapshot;
	TestFalse(TEXT("A default crash-context snapshot is not bounded"), Snapshot.IsBounded());
	TestTrue(TEXT("A generated run has the closed crash run format"), FAethelnCrashContextSnapshot::IsGeneratedRunId(RunId));
	TestTrue(
		TEXT("Closed build, profile, and generated run form a snapshot"),
		FAethelnCrashContextSnapshot::TryMakeValidated(
			Build,
			Profile,
			EAethelnFlowKind::PrototypeAuthority,
			RunId,
			Role,
			AethelnObservability::ExcludedIdentifier,
			Snapshot));
	TestTrue(TEXT("Accepted snapshot remains bounded"), Snapshot.IsBounded());
	TestEqual(TEXT("Snapshot carries the observability schema"), Snapshot.ObservabilitySchemaId, FString(AethelnObservability::SchemaId));
	TestEqual(TEXT("Snapshot carries the observability schema version"), Snapshot.ObservabilitySchemaVersion, AethelnObservability::SchemaVersion);
	TestEqual(TEXT("Snapshot keeps the unknown source revision sentinel"), Snapshot.SourceRevision, FString(AethelnObservability::UnknownValue));
	TestEqual(TEXT("Snapshot keeps the unknown build identity sentinel"), Snapshot.BuildIdentity, FString(AethelnObservability::UnknownValue));
	TestEqual(TEXT("Snapshot maps the engine build configuration"), Snapshot.BuildConfiguration, Build.BuildConfiguration);
	TestEqual(TEXT("Snapshot maps the engine revision"), Snapshot.EngineRevision, Build.EngineRevision);
	TestEqual(TEXT("Snapshot keeps the unknown toolchain sentinel"), Snapshot.ToolchainIdentity, FString(AethelnObservability::UnknownValue));
	TestEqual(TEXT("Snapshot maps the network-profile schema"), Snapshot.NetworkProfileSchemaId, FString(AethelnNetworkSpike::NetworkProfileSchemaId));
	TestEqual(TEXT("Snapshot maps the network-profile version"), Snapshot.NetworkProfileSchemaVersion, AethelnNetworkSpike::NetworkProfileSchemaVersion);
	TestEqual(TEXT("Snapshot keeps the unset network-profile sentinel"), Snapshot.NetworkProfileId, FString(AethelnNetworkSpike::UnsetNetworkProfileId));
	TestEqual(TEXT("Snapshot maps the flow kind"), Snapshot.FlowKind, EAethelnFlowKind::PrototypeAuthority);
	TestEqual(TEXT("Snapshot maps the generated run"), Snapshot.RunId, RunId);
	TestEqual(TEXT("Snapshot maps the closed server role"), Snapshot.ServerInstanceId, Role);
	TestEqual(TEXT("Snapshot keeps the excluded connection marker"), Snapshot.ConnectionPseudonym, FString(AethelnObservability::ExcludedIdentifier));

	const FAethelnCrashContextSnapshot Accepted = Snapshot;
	auto ExpectRejectedAndUnchanged = [this, &Snapshot, &Accepted](
		const TCHAR* What,
		const FAethelnBuildIdentity& InBuild,
		const FAethelnNetworkProfile& InProfile,
		EAethelnFlowKind InFlowKind,
		const FString& InRunId,
		const FString& InInstanceId,
		const FString& InConnectionPseudonym)
	{
		TestFalse(
			What,
			FAethelnCrashContextSnapshot::TryMakeValidated(
				InBuild,
				InProfile,
				InFlowKind,
				InRunId,
				InInstanceId,
				InConnectionPseudonym,
				Snapshot));
		TestEqual(TEXT("Rejected snapshot leaves the prior run unchanged"), Snapshot.RunId, Accepted.RunId);
		TestEqual(TEXT("Rejected snapshot leaves the prior build unchanged"), Snapshot.BuildIdentity, Accepted.BuildIdentity);
		TestEqual(TEXT("Rejected snapshot leaves the prior profile unchanged"), Snapshot.NetworkProfileId, Accepted.NetworkProfileId);
		TestEqual(TEXT("Rejected snapshot leaves the prior instance unchanged"), Snapshot.ServerInstanceId, Accepted.ServerInstanceId);
	};

	const FString Oversized = FString::ChrN(AethelnObservability::MaxIdentifierLength + 1, TCHAR('x'));
	TArray<FString> UnsafeValues;
	UnsafeValues.Add(FString());
	UnsafeValues.Add(Oversized);
	for (const TCHAR UnsafeCharacter : { TCHAR(0x08), TCHAR(0x1b), TCHAR(0x7f), TCHAR(0x85), TCHAR(0x2028), TCHAR(0x2029) })
	{
		UnsafeValues.Add(FString::Printf(TEXT("value%cunsafe"), UnsafeCharacter));
	}
	for (const FString& Unsafe : UnsafeValues)
	{
		ExpectRejectedAndUnchanged(TEXT("Unsafe run identity fails closed"), Build, Profile, EAethelnFlowKind::PrototypeAuthority, Unsafe, Role, AethelnObservability::ExcludedIdentifier);
		ExpectRejectedAndUnchanged(TEXT("Unsafe server instance fails closed"), Build, Profile, EAethelnFlowKind::PrototypeAuthority, RunId, Unsafe, AethelnObservability::ExcludedIdentifier);
		ExpectRejectedAndUnchanged(TEXT("Unsafe connection pseudonym fails closed"), Build, Profile, EAethelnFlowKind::PrototypeAuthority, RunId, Role, Unsafe);
		FAethelnBuildIdentity UnsafeBuild = Build;
		UnsafeBuild.SourceRevision = Unsafe;
		ExpectRejectedAndUnchanged(TEXT("Unsafe source revision fails closed"), UnsafeBuild, Profile, EAethelnFlowKind::PrototypeAuthority, RunId, Role, AethelnObservability::ExcludedIdentifier);
		UnsafeBuild = Build;
		UnsafeBuild.ToolchainIdentity = Unsafe;
		ExpectRejectedAndUnchanged(TEXT("Unsafe toolchain identity fails closed"), UnsafeBuild, Profile, EAethelnFlowKind::PrototypeAuthority, RunId, Role, AethelnObservability::ExcludedIdentifier);
		FAethelnNetworkProfile UnsafeProfile = Profile;
		UnsafeProfile.ProfileId = Unsafe;
		ExpectRejectedAndUnchanged(TEXT("Unsafe network-profile identity fails closed"), Build, UnsafeProfile, EAethelnFlowKind::PrototypeAuthority, RunId, Role, AethelnObservability::ExcludedIdentifier);
	}

	ExpectRejectedAndUnchanged(TEXT("Unknown flow kind fails closed"), Build, Profile, static_cast<EAethelnFlowKind>(200), RunId, Role, AethelnObservability::ExcludedIdentifier);
	FAethelnNetworkProfile WrongSchema = Profile;
	WrongSchema.SchemaId = TEXT("aetheln.other-profile");
	ExpectRejectedAndUnchanged(TEXT("Wrong network-profile schema fails closed"), Build, WrongSchema, EAethelnFlowKind::PrototypeAuthority, RunId, Role, AethelnObservability::ExcludedIdentifier);
	FAethelnNetworkProfile WrongVersion = Profile;
	WrongVersion.SchemaVersion = AethelnNetworkSpike::NetworkProfileSchemaVersion + 1;
	ExpectRejectedAndUnchanged(TEXT("Wrong network-profile version fails closed"), Build, WrongVersion, EAethelnFlowKind::PrototypeAuthority, RunId, Role, AethelnObservability::ExcludedIdentifier);
	ExpectRejectedAndUnchanged(TEXT("Printable personal text is never a process-wide connection pseudonym"), Build, Profile, EAethelnFlowKind::PrototypeAuthority, RunId, Role, TEXT("user@example.com"));
	ExpectRejectedAndUnchanged(TEXT("An authority per-connection pseudonym is never process-wide crash context"), Build, Profile, EAethelnFlowKind::PrototypeAuthority, RunId, Role, TEXT("connection-148"));
	ExpectRejectedAndUnchanged(TEXT("The excluded marker is matched case-sensitively"), Build, Profile, EAethelnFlowKind::PrototypeAuthority, RunId, Role, TEXT("EXCLUDED"));

	// Printable personal or credential-like text passes the identifier bound but is
	// never a closed, engine-owned, or generated crash value in any field.
	const FString Adversarial[] = {
		TEXT("user@example.com"), TEXT("password=hunter2"), TEXT("Bearer abc.def"), TEXT("UNKNOWN"),
		TEXT("0123456789ABCDEF0123456789ABCDEF"), TEXT("0123456789abcdef0123456789abcdeg") };
	for (const FString& Text : Adversarial)
	{
		FAethelnBuildIdentity LauncherBuild = Build;
		LauncherBuild.SourceRevision = Text;
		ExpectRejectedAndUnchanged(TEXT("Launcher source revision text fails closed"), LauncherBuild, Profile, EAethelnFlowKind::PrototypeAuthority, RunId, Role, AethelnObservability::ExcludedIdentifier);
		LauncherBuild = Build;
		LauncherBuild.BuildIdentity = Text;
		ExpectRejectedAndUnchanged(TEXT("Launcher build identity text fails closed"), LauncherBuild, Profile, EAethelnFlowKind::PrototypeAuthority, RunId, Role, AethelnObservability::ExcludedIdentifier);
		LauncherBuild = Build;
		LauncherBuild.ToolchainIdentity = Text;
		ExpectRejectedAndUnchanged(TEXT("Launcher toolchain text fails closed"), LauncherBuild, Profile, EAethelnFlowKind::PrototypeAuthority, RunId, Role, AethelnObservability::ExcludedIdentifier);
		LauncherBuild = Build;
		LauncherBuild.BuildConfiguration = Text;
		ExpectRejectedAndUnchanged(TEXT("Caller build configuration text fails closed"), LauncherBuild, Profile, EAethelnFlowKind::PrototypeAuthority, RunId, Role, AethelnObservability::ExcludedIdentifier);
		LauncherBuild = Build;
		LauncherBuild.EngineRevision = Text;
		ExpectRejectedAndUnchanged(TEXT("Caller engine revision text fails closed"), LauncherBuild, Profile, EAethelnFlowKind::PrototypeAuthority, RunId, Role, AethelnObservability::ExcludedIdentifier);
		FAethelnNetworkProfile LauncherProfile = Profile;
		LauncherProfile.ProfileId = Text;
		ExpectRejectedAndUnchanged(TEXT("Launcher network-profile text fails closed"), Build, LauncherProfile, EAethelnFlowKind::PrototypeAuthority, RunId, Role, AethelnObservability::ExcludedIdentifier);
		ExpectRejectedAndUnchanged(TEXT("Launcher run text fails closed"), Build, Profile, EAethelnFlowKind::PrototypeAuthority, Text, Role, AethelnObservability::ExcludedIdentifier);
		ExpectRejectedAndUnchanged(TEXT("Caller instance text fails closed"), Build, Profile, EAethelnFlowKind::PrototypeAuthority, RunId, Text, AethelnObservability::ExcludedIdentifier);
	}
	ExpectRejectedAndUnchanged(TEXT("The omitted-run fallback is never a crash run"), Build, Profile, EAethelnFlowKind::PrototypeAuthority, TEXT("run-local"), Role, AethelnObservability::ExcludedIdentifier);
	ExpectRejectedAndUnchanged(TEXT("A caller instance identity is never the crash server role"), Build, Profile, EAethelnFlowKind::PrototypeAuthority, RunId, TEXT("network-authority-server"), AethelnObservability::ExcludedIdentifier);

	FAethelnCrashContextSnapshot Tampered = Accepted;
	Tampered.ObservabilitySchemaVersion = AethelnObservability::SchemaVersion + 1;
	TestFalse(TEXT("Snapshot with a foreign observability schema version is not bounded"), Tampered.IsBounded());
	Tampered = Accepted;
	Tampered.FlowKind = static_cast<EAethelnFlowKind>(200);
	TestFalse(TEXT("Snapshot with an unknown flow kind is not bounded"), Tampered.IsBounded());
	Tampered = Accepted;
	Tampered.ConnectionPseudonym = TEXT("user@example.com");
	TestFalse(TEXT("Snapshot with a non-excluded connection pseudonym is not bounded"), Tampered.IsBounded());
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnObservabilityBoundedSinkTest,
	"Aetheln.Observability.Contracts.BoundedSinkAndFailure",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnObservabilityBoundedSinkTest::RunTest(const FString& Parameters)
{
	AddExpectedMessage(
		TEXT("dispatch_failure metric=\\\"sink-failure-count\\\" channel=\\\"public\\\" kind=\\\"sink-write\\\" work_class=\\\"critical\\\" delta=1 total=[123]"),
		ELogVerbosity::Warning,
		EAutomationExpectedMessageFlags::Contains,
		3);
	AddExpectedMessage(
		TEXT("dispatch_failure metric=\\\"sink-failure-count\\\" channel=\\\"restricted\\\" kind=\\\"sink-write\\\" work_class=\\\"restricted\\\" delta=1 total=[123]"),
		ELogVerbosity::Warning,
		EAutomationExpectedMessageFlags::Contains,
		3);
	TSharedPtr<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe> PublicSink = MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(4);
	TSharedPtr<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe> RestrictedSink = MakeShared<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe>(2);
	FAethelnObservabilityService Service(PublicSink, RestrictedSink);
	FAethelnObservabilityEvent Event = AethelnObservabilityTests::MakeValidEvent(
		EAethelnObservabilityCategory::Ability,
		EAethelnObservabilityCategory::Ability);
	Event.DiagnosticCode = EAethelnDiagnosticCode::ValidationFailed;
	Service.EmitEvent(FAethelnObservabilityEvent());
	TestTrue(TEXT("Malformed event leaves both dispatch queues idle"), Service.WaitForIdleForTests());
	TestEqual(TEXT("Malformed event does not reach the public sink"), PublicSink->GetEvents().Num(), 0);
	TestEqual(TEXT("Malformed event does not reach the restricted sink"), RestrictedSink->GetEvents().Num(), 0);
	Service.EmitEvent(Event);
	TestTrue(TEXT("Initial event drains through both channels"), Service.WaitForIdleForTests());
	TestEqual(TEXT("Public sink receives one bounded event"), PublicSink->GetEvents().Num(), 1);
	TestEqual(TEXT("Public sink receives only the redacted copy"), PublicSink->GetEvents()[0].DiagnosticCode, EAethelnDiagnosticCode::None);
	TestEqual(TEXT("Restricted sink retains one bounded event"), RestrictedSink->GetEvents().Num(), 1);
	TestEqual(TEXT("Restricted sink retains diagnostic detail"), RestrictedSink->GetEvents()[0].DiagnosticCode, EAethelnDiagnosticCode::ValidationFailed);

	PublicSink->SetFailWrites(true);
	Service.EmitEvent(Event);
	TestTrue(TEXT("Public failure drains without blocking restricted retention"), Service.WaitForIdleForTests());
	TestEqual(TEXT("Public sink failure preserves prior public evidence"), PublicSink->GetEvents().Num(), 1);
	TestEqual(TEXT("Public sink failure cannot block restricted retention"), RestrictedSink->GetEvents().Num(), 2);
	PublicSink->SetFailWrites(false);

	RestrictedSink->SetFailWrites(true);
	Service.EmitEvent(Event);
	TestTrue(TEXT("Restricted failure drains without blocking public emission"), Service.WaitForIdleForTests());
	TestEqual(TEXT("Restricted sink failure cannot block public emission"), PublicSink->GetEvents().Num(), 2);
	TestEqual(TEXT("Restricted sink failure preserves prior restricted evidence"), RestrictedSink->GetEvents().Num(), 2);
	RestrictedSink->SetFailWrites(false);
	Service.EmitEvent(Event);
	TestTrue(TEXT("Bounded restricted capacity drains"), Service.WaitForIdleForTests());
	TestEqual(TEXT("Restricted sink never exceeds bounded capacity"), RestrictedSink->GetEvents().Num(), 2);

	FAethelnMetricSample Metric;
	Metric.Category = EAethelnObservabilityCategory::Ability;
	Metric.Reason = EAethelnSafeReason::Accepted;
	Service.EmitMetric(Metric);
	TestTrue(TEXT("Metric dispatch drains"), Service.WaitForIdleForTests());
	TestEqual(TEXT("Metric dimensions remain on the public channel"), PublicSink->GetMetrics().Num(), 1);

	PublicSink->SetFailWrites(true);
	Service.EmitEvent(Event);
	Service.EmitMetric(Metric);
	TestTrue(TEXT("Failed public writes still drain bounded work"), Service.WaitForIdleForTests());
	TestEqual(TEXT("Public sink failure does not alter recorded events"), PublicSink->GetEvents().Num(), 3);
	TestEqual(TEXT("Public sink failure does not alter recorded metrics"), PublicSink->GetMetrics().Num(), 1);

	FAethelnObservabilityEvent Oversized = Event;
	Oversized.Correlation.AbilityId = FString::ChrN(AethelnObservability::MaxIdentifierLength + 1, TCHAR('x'));
	TestFalse(TEXT("Oversized allowlisted field is rejected"), Oversized.IsBounded());
	for (const TCHAR UnsafeCharacter : { TCHAR(0x08), TCHAR(0x1b), TCHAR(0x7f), TCHAR(0x85), TCHAR(0x2028) })
	{
		FAethelnObservabilityEvent Unsafe = Event;
		Unsafe.Correlation.RunId = FString::Printf(TEXT("run%cunsafe"), UnsafeCharacter);
		TestFalse(TEXT("Control-character-bearing identifier is rejected"), Unsafe.IsBounded());
		Service.EmitEvent(Unsafe);
	}
	TestTrue(TEXT("Unsafe events never leave pending dispatch work"), Service.WaitForIdleForTests());
	TestEqual(TEXT("Unsafe identifiers never reach the public sink"), PublicSink->GetEvents().Num(), 3);
	TestEqual(TEXT("Unsafe identifiers never reach the restricted sink"), RestrictedSink->GetEvents().Num(), 2);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnObservabilityInjectionLifetimeTest,
	"Aetheln.Observability.Contracts.InjectionLifetimeAndReset",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnObservabilityInjectionLifetimeTest::RunTest(const FString& Parameters)
{
	FAethelnObservabilityService Service;
	TWeakPtr<IAethelnObservabilitySink, ESPMode::ThreadSafe> WeakSink;
	TWeakPtr<IAethelnRestrictedAuditSink, ESPMode::ThreadSafe> WeakRestrictedSink;
	{
		TSharedPtr<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe> InjectedSink = MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(2);
		TSharedPtr<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe> InjectedRestrictedSink = MakeShared<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe>(2);
		WeakSink = InjectedSink;
		WeakRestrictedSink = InjectedRestrictedSink;
		TestTrue(TEXT("Valid shared sink is accepted"), Service.SetSink(InjectedSink));
		TestTrue(TEXT("Valid restricted sink is accepted"), Service.SetRestrictedSink(InjectedRestrictedSink));
	}

	TestTrue(TEXT("Service retains the injected sink lifetime"), WeakSink.IsValid());
	TestTrue(TEXT("Service retains the injected restricted sink lifetime"), WeakRestrictedSink.IsValid());
	FAethelnObservabilityEvent DiagnosticEvent = AethelnObservabilityTests::MakeValidEvent();
	DiagnosticEvent.DiagnosticCode = EAethelnDiagnosticCode::SinkUnavailable;
	Service.EmitEvent(DiagnosticEvent);
	TestTrue(TEXT("Injected sinks receive their initial async dispatch"), Service.WaitForIdleForTests());
	TSharedPtr<IAethelnObservabilitySink, ESPMode::ThreadSafe> PinnedSink = WeakSink.Pin();
	TSharedPtr<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe> InMemorySink = StaticCastSharedPtr<FAethelnInMemoryObservabilitySink>(PinnedSink);
	TSharedPtr<IAethelnRestrictedAuditSink, ESPMode::ThreadSafe> PinnedRestrictedSink = WeakRestrictedSink.Pin();
	TSharedPtr<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe> RestrictedSink = StaticCastSharedPtr<FAethelnBoundedRestrictedAuditSink>(PinnedRestrictedSink);
	TestEqual(TEXT("Retained sink receives emission"), InMemorySink->GetEvents().Num(), 1);
	TestEqual(TEXT("Public injection remains redacted"), InMemorySink->GetEvents()[0].DiagnosticCode, EAethelnDiagnosticCode::None);
	TestEqual(TEXT("Restricted injection receives emission"), RestrictedSink->GetEvents().Num(), 1);
	TestEqual(TEXT("Restricted injection retains diagnostic detail"), RestrictedSink->GetEvents()[0].DiagnosticCode, EAethelnDiagnosticCode::SinkUnavailable);

	TestFalse(TEXT("Invalid injection is rejected"), Service.SetSink(FAethelnObservabilityService::FSinkPtr()));
	TestFalse(TEXT("Invalid restricted injection is rejected"), Service.SetRestrictedSink(FAethelnObservabilityService::FRestrictedSinkPtr()));
	Service.EmitEvent(AethelnObservabilityTests::MakeValidEvent());
	TestTrue(TEXT("Rejected injection preserves a drainable active sink"), Service.WaitForIdleForTests());
	TestEqual(TEXT("Rejected injection leaves the active sink unchanged"), InMemorySink->GetEvents().Num(), 2);
	TestEqual(TEXT("Rejected restricted injection leaves the active sink unchanged"), RestrictedSink->GetEvents().Num(), 2);

	PinnedSink.Reset();
	InMemorySink.Reset();
	PinnedRestrictedSink.Reset();
	RestrictedSink.Reset();
	Service.ResetSink();
	Service.ResetRestrictedSink();
	TestFalse(TEXT("Reset releases the injected sink"), WeakSink.IsValid());
	TestFalse(TEXT("Reset releases the injected restricted sink"), WeakRestrictedSink.IsValid());
	Service.EmitEvent(AethelnObservabilityTests::MakeValidEvent());
	Service.EmitMetric(FAethelnMetricSample());
	TestTrue(TEXT("Reset sinks drain default bounded work"), Service.WaitForIdleForTests());
	TestTrue(TEXT("Reset restores void structured-log emission"), true);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnObservabilityNoOpTest,
	"Aetheln.Observability.Contracts.RuntimeSinks",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnObservabilityNoOpTest::RunTest(const FString& Parameters)
{
	FAethelnObservabilityEvent Event = AethelnObservabilityTests::MakeValidEvent();
	FAethelnNoOpObservabilitySink NoOpSink;
	TestTrue(TEXT("Explicit no-op sink accepts bounded events"), NoOpSink.TryRecordEvent(Event));
	TestTrue(TEXT("Explicit no-op sink accepts closed metrics"), NoOpSink.TryRecordMetric(FAethelnMetricSample()));

	FAethelnStructuredLogObservabilitySink LogSink;
	TestTrue(TEXT("Structured log sink records bounded public events"), LogSink.TryRecordEvent(Event));
	TestTrue(TEXT("Structured log sink records closed metrics"), LogSink.TryRecordMetric(FAethelnMetricSample()));
	Event.Correlation.RunId = FString::ChrN(
		AethelnObservability::MaxIdentifierLength + 1,
		TEXT('x'));
	TestFalse(TEXT("Structured log sink rejects unbounded events"), LogSink.TryRecordEvent(Event));
	TestFalse(TEXT("No-op sink also rejects malformed events"), NoOpSink.TryRecordEvent(FAethelnObservabilityEvent()));

	FAethelnObservabilityService Service;
	Service.EmitEvent(FAethelnObservabilityEvent());
	Service.EmitMetric(FAethelnMetricSample());
	TestTrue(TEXT("Default metric dispatch drains after malformed event rejection"), Service.WaitForIdleForTests());
	TestTrue(TEXT("Malformed structured-log emission is dropped without a gameplay result"), true);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnObservabilityNonBlockingDispatchTest,
	"Aetheln.Observability.Contracts.NonBlockingBoundedDispatch",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnObservabilityNonBlockingDispatchTest::RunTest(const FString& Parameters)
{
	AddExpectedMessage(
		TEXT("dispatch_failure metric=\\\"queue-drop-count\\\" channel=\\\"public\\\" kind=\\\"queue-drop\\\" work_class=\\\"routine-movement\\\" delta=[1-9][0-9]* total=[1-9][0-9]*"),
		ELogVerbosity::Warning,
		EAutomationExpectedMessageFlags::Contains,
		1);
	AddExpectedMessage(
		TEXT("dispatch_failure metric=\\\"queue-drop-count\\\" channel=\\\"public\\\" kind=\\\"queue-drop\\\" work_class=\\\"critical\\\" delta=[1-9][0-9]* total=[1-9][0-9]*"),
		ELogVerbosity::Warning,
		EAutomationExpectedMessageFlags::Contains,
		1);
	AddExpectedMessage(
		TEXT("dispatch_failure metric=\\\"queue-drop-count\\\" channel=\\\"restricted\\\" kind=\\\"queue-drop\\\" work_class=\\\"restricted\\\" delta=[1-9][0-9]* total=[1-9][0-9]*"),
		ELogVerbosity::Warning,
		EAutomationExpectedMessageFlags::Contains,
		1);
	FAethelnObservabilityEvent Event = AethelnObservabilityTests::MakeValidEvent(
		EAethelnObservabilityCategory::Movement,
		EAethelnObservabilityCategory::Movement);
	TSharedPtr<AethelnObservabilityTests::FBlockingPublicSink, ESPMode::ThreadSafe> BlockingPublic =
		MakeShared<AethelnObservabilityTests::FBlockingPublicSink, ESPMode::ThreadSafe>();
	TSharedPtr<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe> Restricted =
		MakeShared<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe>(8);
	FAethelnObservabilityService PublicBlocked(BlockingPublic, Restricted, 2);
	PublicBlocked.EmitEvent(Event);
	TestTrue(TEXT("Public sink runs on a background dispatcher"), BlockingPublic->WaitUntilEntered());
	TestTrue(TEXT("Restricted channel drains while public sink is blocked"), PublicBlocked.WaitForRestrictedIdleForTests());
	for (uint64 Sequence = 2; Sequence <= 4; ++Sequence)
	{
		Event.Correlation.Sequence = Sequence;
		PublicBlocked.EmitEvent(Event);
		TestTrue(TEXT("Restricted channel remains independently drainable"), PublicBlocked.WaitForRestrictedIdleForTests());
	}
	FAethelnObservabilityEvent Rejection = AethelnObservabilityTests::MakeValidEvent(
		EAethelnObservabilityCategory::Rejection,
		EAethelnObservabilityCategory::Movement);
	Rejection.SafeReason = EAethelnSafeReason::Rejected;
	Rejection.Correlation.Sequence = 5;
	PublicBlocked.EmitEvent(Rejection);
	TestTrue(TEXT("Critical public work remains independently bounded"), PublicBlocked.GetPublicPendingCountForTests() <= 4);
	TestTrue(TEXT("Blocked public saturation drops observability work"), PublicBlocked.GetPublicDroppedCountForTests() > 0);
	TestTrue(TEXT("Critical rejection remains admitted while routine movement is saturated"), PublicBlocked.GetPublicPendingCountForTests() >= 2);
	TestTrue(TEXT("Restricted channel drains the critical rejection independently"), PublicBlocked.WaitForRestrictedIdleForTests());
	TestEqual(TEXT("Restricted channel retained all independently drained events"), Restricted->GetEvents().Num(), 5);
	BlockingPublic->ReleaseBlockedWrite();
	TestTrue(TEXT("Public channel drains after the blocked sink is released"), PublicBlocked.WaitForIdleForTests());
	TestEqual(TEXT("Bounded routine work and the critical rejection reached the blocked sink"), BlockingPublic->GetCalls(), 3);
	const TArray<FAethelnObservabilityEvent> PublicEvents = BlockingPublic->GetEvents();
	TestTrue(
		TEXT("Critical rejection reaches the public sink despite routine movement saturation"),
		PublicEvents.ContainsByPredicate([](const FAethelnObservabilityEvent& Recorded)
		{
			return Recorded.Category == EAethelnObservabilityCategory::Rejection
				&& Recorded.SubjectCategory == EAethelnObservabilityCategory::Movement;
		}));

	TSharedPtr<AethelnObservabilityTests::FBlockingPublicSink, ESPMode::ThreadSafe> BlockingCritical =
		MakeShared<AethelnObservabilityTests::FBlockingPublicSink, ESPMode::ThreadSafe>();
	TSharedPtr<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe> CriticalRestricted =
		MakeShared<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe>(8);
	FAethelnObservabilityService CriticalBlocked(BlockingCritical, CriticalRestricted, 2);
	FAethelnObservabilityEvent CriticalEvent = AethelnObservabilityTests::MakeValidEvent(
		EAethelnObservabilityCategory::Rejection,
		EAethelnObservabilityCategory::Movement);
	CriticalEvent.SafeReason = EAethelnSafeReason::Rejected;
	CriticalBlocked.EmitEvent(CriticalEvent);
	TestTrue(TEXT("Critical public sink runs on the background dispatcher"), BlockingCritical->WaitUntilEntered());
	for (uint64 Sequence = 2; Sequence <= 4; ++Sequence)
	{
		CriticalEvent.Correlation.Sequence = Sequence;
		CriticalBlocked.EmitEvent(CriticalEvent);
		TestTrue(TEXT("Restricted evidence drains during critical public saturation"), CriticalBlocked.WaitForRestrictedIdleForTests());
	}
	TestTrue(TEXT("Critical public saturation increments the production-visible drop count"), CriticalBlocked.GetPublicDroppedCountForTests() > 0);
	BlockingCritical->ReleaseBlockedWrite();
	TestTrue(TEXT("Critical public lane drains after release"), CriticalBlocked.WaitForIdleForTests());
	TestEqual(TEXT("Critical public lane remains capacity bounded"), BlockingCritical->GetCalls(), 2);

	TSharedPtr<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe> Public =
		MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(8);
	TSharedPtr<AethelnObservabilityTests::FBlockingRestrictedSink, ESPMode::ThreadSafe> BlockingRestricted =
		MakeShared<AethelnObservabilityTests::FBlockingRestrictedSink, ESPMode::ThreadSafe>();
	FAethelnObservabilityService RestrictedBlocked(Public, BlockingRestricted, 2);
	Event = AethelnObservabilityTests::MakeValidEvent();
	Event.Correlation.Sequence = 10;
	RestrictedBlocked.EmitEvent(Event);
	TestTrue(TEXT("Restricted sink runs on its independent background dispatcher"), BlockingRestricted->WaitUntilEntered());
	TestTrue(TEXT("Public channel drains while restricted sink is blocked"), RestrictedBlocked.WaitForPublicIdleForTests());
	for (uint64 Sequence = 11; Sequence <= 13; ++Sequence)
	{
		Event.Correlation.Sequence = Sequence;
		RestrictedBlocked.EmitEvent(Event);
		TestTrue(TEXT("Public channel remains independently drainable"), RestrictedBlocked.WaitForPublicIdleForTests());
	}
	TestTrue(TEXT("Blocked restricted work never exceeds dispatch capacity"), RestrictedBlocked.GetRestrictedPendingCountForTests() <= 2);
	TestTrue(TEXT("Blocked restricted saturation drops observability work"), RestrictedBlocked.GetRestrictedDroppedCountForTests() > 0);
	TestEqual(TEXT("Public channel retained all independently drained events"), Public->GetEvents().Num(), 4);
	BlockingRestricted->ReleaseBlockedWrite();
	TestTrue(TEXT("Restricted channel drains after the blocked sink is released"), RestrictedBlocked.WaitForIdleForTests());
	TestEqual(TEXT("Only bounded restricted work reached the blocked sink"), BlockingRestricted->GetCalls(), 2);
	return true;
}
#endif
