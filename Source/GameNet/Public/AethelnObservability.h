#pragma once

#include "AethelnNetworkProfile.h"
#include "CoreMinimal.h"
#include "Misc/App.h"
#include "Misc/EngineVersion.h"

namespace AethelnObservability
{
	inline constexpr TCHAR SchemaId[] = TEXT("aetheln.observability-event");
	inline constexpr uint32 SchemaVersion = 1;
	inline constexpr TCHAR UnknownValue[] = TEXT("unknown");
	inline constexpr TCHAR ExcludedIdentifier[] = TEXT("excluded");
	/** Closed server role registered in crash context instead of a caller-supplied instance identity. */
	inline constexpr TCHAR CrashServerRole[] = TEXT("game-server");
	inline constexpr int32 MaxIdentifierLength = 96;
	inline constexpr int32 MaxDiagnosticLength = 64;
	inline constexpr int32 MaxInMemoryEvents = 256;
	inline constexpr int32 MaxPendingDispatchItems = 256;

	inline bool IsSafeIdentifier(const FString& Value)
	{
		if (Value.Len() > MaxIdentifierLength)
		{
			return false;
		}

		for (const TCHAR Character : Value)
		{
			const uint32 CodePoint = static_cast<uint32>(Character);
			if (CodePoint <= 0x1f
				|| (CodePoint >= 0x7f && CodePoint <= 0x9f)
				|| CodePoint == 0x2028
				|| CodePoint == 0x2029)
			{
				return false;
			}
		}
		return true;
	}
}

enum class EAethelnObservabilityCategory : uint8
{
	Movement,
	Aim,
	Ability,
	Cooldown,
	Hit,
	Dodge,
	Block,
	Resource,
	Death,
	Respawn,
	Correction,
	Rejection,
	ServerLifecycle,
	ServerHealth,
	CrashContext
};

enum class EAethelnSafeReason : uint8
{
	None,
	Accepted,
	Corrected,
	Rejected,
	MalformedRequest,
	StaleSequence,
	DuplicateSequence,
	IncompatibleVersion,
	TimestampOutOfBounds,
	ImpossibleAimTransition,
	ConnectionClosed,
	ActorDestroyed,
	ActivationBlocked,
	NotImplemented,
	InternalFailure,
	ControlledShutdown
};

enum class EAethelnDiagnosticCode : uint8
{
	None,
	ValidationFailed,
	SequenceWindowFailed,
	SchemaValidationFailed,
	SinkUnavailable
};

enum class EAethelnFlowKind : uint8
{
	PrototypeAuthority,
	Admission,
	Lease,
	PersistentCommand,
	Transaction,
	Outbox,
	Reward,
	Transfer,
	Allocation,
	Dependency,
	Restore,
	Reconciliation
};

enum class EAethelnMetricKind : uint8
{
	EventCount,
	CorrectionCount,
	RejectionCount,
	LifecycleCount,
	SinkFailureCount,
	QueueDropCount,
	ServerTickMicroseconds,
	ActorCount,
	ReplicatedActorCount,
	PawnCount,
	ControllerCount,
	PlayerStateCount,
	OtherActorCount
};

enum class EAethelnEnvironment : uint8
{
	Local,
	Development
};

inline bool IsKnown(EAethelnObservabilityCategory Value)
{
	switch (Value)
	{
	case EAethelnObservabilityCategory::Movement:
	case EAethelnObservabilityCategory::Aim:
	case EAethelnObservabilityCategory::Ability:
	case EAethelnObservabilityCategory::Cooldown:
	case EAethelnObservabilityCategory::Hit:
	case EAethelnObservabilityCategory::Dodge:
	case EAethelnObservabilityCategory::Block:
	case EAethelnObservabilityCategory::Resource:
	case EAethelnObservabilityCategory::Death:
	case EAethelnObservabilityCategory::Respawn:
	case EAethelnObservabilityCategory::Correction:
	case EAethelnObservabilityCategory::Rejection:
	case EAethelnObservabilityCategory::ServerLifecycle:
	case EAethelnObservabilityCategory::ServerHealth:
	case EAethelnObservabilityCategory::CrashContext:
		return true;
	default:
		return false;
	}
}

inline bool IsCorrectableSubject(EAethelnObservabilityCategory Value)
{
	switch (Value)
	{
	case EAethelnObservabilityCategory::Movement:
	case EAethelnObservabilityCategory::Aim:
	case EAethelnObservabilityCategory::Ability:
	case EAethelnObservabilityCategory::Cooldown:
	case EAethelnObservabilityCategory::Hit:
	case EAethelnObservabilityCategory::Dodge:
	case EAethelnObservabilityCategory::Block:
	case EAethelnObservabilityCategory::Resource:
	case EAethelnObservabilityCategory::Death:
	case EAethelnObservabilityCategory::Respawn:
		return true;
	default:
		return false;
	}
}

inline bool IsKnown(EAethelnSafeReason Value)
{
	switch (Value)
	{
	case EAethelnSafeReason::None:
	case EAethelnSafeReason::Accepted:
	case EAethelnSafeReason::Corrected:
	case EAethelnSafeReason::Rejected:
	case EAethelnSafeReason::MalformedRequest:
	case EAethelnSafeReason::StaleSequence:
	case EAethelnSafeReason::DuplicateSequence:
	case EAethelnSafeReason::IncompatibleVersion:
	case EAethelnSafeReason::TimestampOutOfBounds:
	case EAethelnSafeReason::ImpossibleAimTransition:
	case EAethelnSafeReason::ConnectionClosed:
	case EAethelnSafeReason::ActorDestroyed:
	case EAethelnSafeReason::ActivationBlocked:
	case EAethelnSafeReason::NotImplemented:
	case EAethelnSafeReason::InternalFailure:
	case EAethelnSafeReason::ControlledShutdown:
		return true;
	default:
		return false;
	}
}

inline bool IsKnown(EAethelnDiagnosticCode Value)
{
	switch (Value)
	{
	case EAethelnDiagnosticCode::None:
	case EAethelnDiagnosticCode::ValidationFailed:
	case EAethelnDiagnosticCode::SequenceWindowFailed:
	case EAethelnDiagnosticCode::SchemaValidationFailed:
	case EAethelnDiagnosticCode::SinkUnavailable:
		return true;
	default:
		return false;
	}
}

inline bool IsKnown(EAethelnFlowKind Value)
{
	switch (Value)
	{
	case EAethelnFlowKind::PrototypeAuthority:
	case EAethelnFlowKind::Admission:
	case EAethelnFlowKind::Lease:
	case EAethelnFlowKind::PersistentCommand:
	case EAethelnFlowKind::Transaction:
	case EAethelnFlowKind::Outbox:
	case EAethelnFlowKind::Reward:
	case EAethelnFlowKind::Transfer:
	case EAethelnFlowKind::Allocation:
	case EAethelnFlowKind::Dependency:
	case EAethelnFlowKind::Restore:
	case EAethelnFlowKind::Reconciliation:
		return true;
	default:
		return false;
	}
}

inline const TCHAR* LexToString(EAethelnObservabilityCategory Value)
{
	switch (Value)
	{
	case EAethelnObservabilityCategory::Movement: return TEXT("movement");
	case EAethelnObservabilityCategory::Aim: return TEXT("aim");
	case EAethelnObservabilityCategory::Ability: return TEXT("ability");
	case EAethelnObservabilityCategory::Cooldown: return TEXT("cooldown");
	case EAethelnObservabilityCategory::Hit: return TEXT("hit");
	case EAethelnObservabilityCategory::Dodge: return TEXT("dodge");
	case EAethelnObservabilityCategory::Block: return TEXT("block");
	case EAethelnObservabilityCategory::Resource: return TEXT("resource");
	case EAethelnObservabilityCategory::Death: return TEXT("death");
	case EAethelnObservabilityCategory::Respawn: return TEXT("respawn");
	case EAethelnObservabilityCategory::Correction: return TEXT("correction");
	case EAethelnObservabilityCategory::Rejection: return TEXT("rejection");
	case EAethelnObservabilityCategory::ServerLifecycle: return TEXT("server-lifecycle");
	case EAethelnObservabilityCategory::ServerHealth: return TEXT("server-health");
	case EAethelnObservabilityCategory::CrashContext: return TEXT("crash-context");
	default: return TEXT("unknown");
	}
}

inline const TCHAR* LexToString(EAethelnSafeReason Value)
{
	switch (Value)
	{
	case EAethelnSafeReason::None: return TEXT("none");
	case EAethelnSafeReason::Accepted: return TEXT("accepted");
	case EAethelnSafeReason::Corrected: return TEXT("corrected");
	case EAethelnSafeReason::Rejected: return TEXT("rejected");
	case EAethelnSafeReason::MalformedRequest: return TEXT("malformed-request");
	case EAethelnSafeReason::StaleSequence: return TEXT("stale-sequence");
	case EAethelnSafeReason::DuplicateSequence: return TEXT("duplicate-sequence");
	case EAethelnSafeReason::IncompatibleVersion: return TEXT("incompatible-version");
	case EAethelnSafeReason::TimestampOutOfBounds: return TEXT("timestamp-out-of-bounds");
	case EAethelnSafeReason::ImpossibleAimTransition: return TEXT("impossible-aim-transition");
	case EAethelnSafeReason::ConnectionClosed: return TEXT("connection-closed");
	case EAethelnSafeReason::ActorDestroyed: return TEXT("actor-destroyed");
	case EAethelnSafeReason::ActivationBlocked: return TEXT("activation-blocked");
	case EAethelnSafeReason::NotImplemented: return TEXT("not-implemented");
	case EAethelnSafeReason::InternalFailure: return TEXT("internal-failure");
	case EAethelnSafeReason::ControlledShutdown: return TEXT("controlled-shutdown");
	default: return TEXT("unknown");
	}
}

inline const TCHAR* LexToString(EAethelnFlowKind Value)
{
	switch (Value)
	{
	case EAethelnFlowKind::PrototypeAuthority: return TEXT("prototype-authority");
	case EAethelnFlowKind::Admission: return TEXT("admission");
	case EAethelnFlowKind::Lease: return TEXT("lease");
	case EAethelnFlowKind::PersistentCommand: return TEXT("persistent-command");
	case EAethelnFlowKind::Transaction: return TEXT("transaction");
	case EAethelnFlowKind::Outbox: return TEXT("outbox");
	case EAethelnFlowKind::Reward: return TEXT("reward");
	case EAethelnFlowKind::Transfer: return TEXT("transfer");
	case EAethelnFlowKind::Allocation: return TEXT("allocation");
	case EAethelnFlowKind::Dependency: return TEXT("dependency");
	case EAethelnFlowKind::Restore: return TEXT("restore");
	case EAethelnFlowKind::Reconciliation: return TEXT("reconciliation");
	default: return TEXT("unknown");
	}
}

inline const TCHAR* LexToString(EAethelnMetricKind Value)
{
	switch (Value)
	{
	case EAethelnMetricKind::EventCount: return TEXT("event-count");
	case EAethelnMetricKind::CorrectionCount: return TEXT("correction-count");
	case EAethelnMetricKind::RejectionCount: return TEXT("rejection-count");
	case EAethelnMetricKind::LifecycleCount: return TEXT("lifecycle-count");
	case EAethelnMetricKind::SinkFailureCount: return TEXT("sink-failure-count");
	case EAethelnMetricKind::QueueDropCount: return TEXT("queue-drop-count");
	case EAethelnMetricKind::ServerTickMicroseconds: return TEXT("server-tick-microseconds");
	case EAethelnMetricKind::ActorCount: return TEXT("actor-count");
	case EAethelnMetricKind::ReplicatedActorCount: return TEXT("replicated-actor-count");
	case EAethelnMetricKind::PawnCount: return TEXT("pawn-count");
	case EAethelnMetricKind::ControllerCount: return TEXT("controller-count");
	case EAethelnMetricKind::PlayerStateCount: return TEXT("player-state-count");
	case EAethelnMetricKind::OtherActorCount: return TEXT("other-actor-count");
	default: return TEXT("unknown");
	}
}

inline const TCHAR* LexToString(EAethelnEnvironment Value)
{
	switch (Value)
	{
	case EAethelnEnvironment::Local: return TEXT("local");
	case EAethelnEnvironment::Development: return TEXT("development");
	default: return TEXT("unknown");
	}
}

struct GAMENET_API FAethelnBuildIdentity
{
	FString SourceRevision = AethelnObservability::UnknownValue;
	FString BuildIdentity = AethelnObservability::UnknownValue;
	FString BuildConfiguration = AethelnObservability::UnknownValue;
	FString EngineRevision = AethelnObservability::UnknownValue;
	FString ToolchainIdentity = AethelnObservability::UnknownValue;

	bool HasSafeIdentifiers() const
	{
		return !SourceRevision.IsEmpty()
			&& !BuildIdentity.IsEmpty()
			&& !BuildConfiguration.IsEmpty()
			&& !EngineRevision.IsEmpty()
			&& !ToolchainIdentity.IsEmpty()
			&& AethelnObservability::IsSafeIdentifier(SourceRevision)
			&& AethelnObservability::IsSafeIdentifier(BuildIdentity)
			&& AethelnObservability::IsSafeIdentifier(BuildConfiguration)
			&& AethelnObservability::IsSafeIdentifier(EngineRevision)
			&& AethelnObservability::IsSafeIdentifier(ToolchainIdentity);
	}
};

struct GAMENET_API FAethelnCorrelationContext
{
	EAethelnFlowKind FlowKind = EAethelnFlowKind::PrototypeAuthority;
	FString RunId;
	FString ConnectionPseudonym;
	FString InstanceId;
	FString ActivationId;
	FString AbilityId;
	uint64 Sequence = 0;

	bool IsBounded() const
	{
		return IsKnown(FlowKind)
			&& AethelnObservability::IsSafeIdentifier(RunId)
			&& AethelnObservability::IsSafeIdentifier(ConnectionPseudonym)
			&& AethelnObservability::IsSafeIdentifier(InstanceId)
			&& AethelnObservability::IsSafeIdentifier(ActivationId)
			&& AethelnObservability::IsSafeIdentifier(AbilityId);
	}

	bool IsValidForEvent(
		EAethelnObservabilityCategory Category,
		EAethelnObservabilityCategory SubjectCategory) const
	{
		const bool bCombatActivationSubject = SubjectCategory == EAethelnObservabilityCategory::Ability
			|| SubjectCategory == EAethelnObservabilityCategory::Hit;
		const bool bRequiresActivation = Category != EAethelnObservabilityCategory::Rejection
			&& bCombatActivationSubject;
		const bool bRequiresAbility = Category != EAethelnObservabilityCategory::Rejection
			&& (bCombatActivationSubject
				|| SubjectCategory == EAethelnObservabilityCategory::Cooldown
				|| SubjectCategory == EAethelnObservabilityCategory::Dodge
				|| SubjectCategory == EAethelnObservabilityCategory::Block);
		return IsBounded()
			&& !RunId.IsEmpty()
			&& !ConnectionPseudonym.IsEmpty()
			&& !InstanceId.IsEmpty()
			&& Sequence != 0
			&& (!bRequiresActivation || !ActivationId.IsEmpty())
			&& (!bRequiresAbility || !AbilityId.IsEmpty());
	}

	static bool TryMakeValidated(
		EAethelnFlowKind InFlowKind,
		const FString& InRunId,
		const FString& InConnectionPseudonym,
		const FString& InInstanceId,
		const FString& InActivationId,
		const FString& InAbilityId,
		uint64 InSequence,
		FAethelnCorrelationContext& OutContext)
	{
		FAethelnCorrelationContext Candidate;
		Candidate.FlowKind = InFlowKind;
		Candidate.RunId = InRunId;
		Candidate.ConnectionPseudonym = InConnectionPseudonym;
		Candidate.InstanceId = InInstanceId;
		Candidate.ActivationId = InActivationId;
		Candidate.AbilityId = InAbilityId;
		Candidate.Sequence = InSequence;
		if (!Candidate.IsBounded())
		{
			return false;
		}
		OutContext = MoveTemp(Candidate);
		return true;
	}
};

struct GAMENET_API FAethelnObservabilityEvent
{
	FString SchemaId = AethelnObservability::SchemaId;
	uint32 SchemaVersion = AethelnObservability::SchemaVersion;
	EAethelnObservabilityCategory Category = EAethelnObservabilityCategory::ServerLifecycle;
	/** Closed-enum family affected by an envelope such as a generic rejection. */
	EAethelnObservabilityCategory SubjectCategory = EAethelnObservabilityCategory::ServerLifecycle;
	EAethelnSafeReason SafeReason = EAethelnSafeReason::None;
	EAethelnDiagnosticCode DiagnosticCode = EAethelnDiagnosticCode::None;
	FAethelnCorrelationContext Correlation;
	FAethelnBuildIdentity Build;
	FAethelnNetworkProfile NetworkProfile;

	bool IsBounded() const
	{
		const bool bSubjectMatchesCategory = Category == EAethelnObservabilityCategory::Correction
			? IsCorrectableSubject(SubjectCategory)
			: (Category == EAethelnObservabilityCategory::Rejection || SubjectCategory == Category);
		return SchemaId == AethelnObservability::SchemaId
			&& SchemaVersion == AethelnObservability::SchemaVersion
			&& IsKnown(Category)
			&& IsKnown(SubjectCategory)
			&& bSubjectMatchesCategory
			&& IsKnown(SafeReason)
			&& IsKnown(DiagnosticCode)
			&& Correlation.IsValidForEvent(Category, SubjectCategory)
			&& Build.HasSafeIdentifiers()
			&& NetworkProfile.SchemaId == AethelnNetworkSpike::NetworkProfileSchemaId
			&& NetworkProfile.SchemaVersion == AethelnNetworkSpike::NetworkProfileSchemaVersion
			&& !NetworkProfile.ProfileId.IsEmpty()
			&& AethelnObservability::IsSafeIdentifier(NetworkProfile.ProfileId);
	}

	FAethelnObservabilityEvent MakePublicCopy() const
	{
		FAethelnObservabilityEvent Result = *this;
		Result.DiagnosticCode = EAethelnDiagnosticCode::None;
		return Result;
	}
};

/**
 * Closed process-wide crash correlation registered before failure. It never carries
 * launcher or caller text: source, build, toolchain, and profile are closed sentinels,
 * configuration and revision are engine-owned, and the production path supplies a
 * server-generated crash run ID. It does not attribute the crash to an external run.
 */
struct GAMENET_API FAethelnCrashContextSnapshot
{
	FString ObservabilitySchemaId;
	uint32 ObservabilitySchemaVersion = 0;
	FString SourceRevision;
	FString BuildIdentity;
	FString BuildConfiguration;
	FString EngineRevision;
	FString ToolchainIdentity;
	FString NetworkProfileSchemaId;
	uint32 NetworkProfileSchemaVersion = 0;
	FString NetworkProfileId;
	EAethelnFlowKind FlowKind = EAethelnFlowKind::PrototypeAuthority;
	/** Opaque crash run ID; the subsystem generates it, and it is never the launcher run identity. */
	FString CrashRunId;
	FString ServerInstanceId;
	/** Crash context is process-wide, so this is always the literal excluded marker. */
	FString ConnectionPseudonym;

	/**
	 * Format check only: exactly 32 lowercase hexadecimal digits, so the value cannot carry
	 * printable free text. It does not prove that a caller-provided value was generated.
	 */
	static bool HasCrashRunIdFormat(const FString& Value)
	{
		if (Value.Len() != 32)
		{
			return false;
		}
		for (const TCHAR Character : Value)
		{
			if (!((Character >= TCHAR('0') && Character <= TCHAR('9')) || (Character >= TCHAR('a') && Character <= TCHAR('f'))))
			{
				return false;
			}
		}
		return true;
	}

	bool IsBounded() const
	{
		for (const FString* Value : {
			&ObservabilitySchemaId, &SourceRevision, &BuildIdentity, &BuildConfiguration,
			&EngineRevision, &ToolchainIdentity, &NetworkProfileSchemaId, &NetworkProfileId,
			&CrashRunId, &ServerInstanceId, &ConnectionPseudonym })
		{
			if (Value->IsEmpty() || !AethelnObservability::IsSafeIdentifier(*Value))
			{
				return false;
			}
		}
		return ObservabilitySchemaId.Equals(AethelnObservability::SchemaId, ESearchCase::CaseSensitive)
			&& ObservabilitySchemaVersion == AethelnObservability::SchemaVersion
			&& NetworkProfileSchemaId.Equals(AethelnNetworkSpike::NetworkProfileSchemaId, ESearchCase::CaseSensitive)
			&& NetworkProfileSchemaVersion == AethelnNetworkSpike::NetworkProfileSchemaVersion
			&& SourceRevision.Equals(AethelnObservability::UnknownValue, ESearchCase::CaseSensitive)
			&& BuildIdentity.Equals(AethelnObservability::UnknownValue, ESearchCase::CaseSensitive)
			&& ToolchainIdentity.Equals(AethelnObservability::UnknownValue, ESearchCase::CaseSensitive)
			&& NetworkProfileId.Equals(AethelnNetworkSpike::UnsetNetworkProfileId, ESearchCase::CaseSensitive)
			&& BuildConfiguration.Equals(LexToString(FApp::GetBuildConfiguration()), ESearchCase::CaseSensitive)
			&& EngineRevision.Equals(FEngineVersion::Current().ToString(), ESearchCase::CaseSensitive)
			&& HasCrashRunIdFormat(CrashRunId)
			&& ServerInstanceId.Equals(AethelnObservability::CrashServerRole, ESearchCase::CaseSensitive)
			&& ConnectionPseudonym.Equals(AethelnObservability::ExcludedIdentifier, ESearchCase::CaseSensitive)
			&& IsKnown(FlowKind);
	}

	static bool TryMakeValidated(
		const FAethelnBuildIdentity& InBuild,
		const FAethelnNetworkProfile& InProfile,
		EAethelnFlowKind InFlowKind,
		const FString& InCrashRunId,
		const FString& InServerInstanceId,
		const FString& InConnectionPseudonym,
		FAethelnCrashContextSnapshot& OutSnapshot)
	{
		FAethelnCrashContextSnapshot Candidate;
		Candidate.ObservabilitySchemaId = AethelnObservability::SchemaId;
		Candidate.ObservabilitySchemaVersion = AethelnObservability::SchemaVersion;
		Candidate.SourceRevision = InBuild.SourceRevision;
		Candidate.BuildIdentity = InBuild.BuildIdentity;
		Candidate.BuildConfiguration = InBuild.BuildConfiguration;
		Candidate.EngineRevision = InBuild.EngineRevision;
		Candidate.ToolchainIdentity = InBuild.ToolchainIdentity;
		Candidate.NetworkProfileSchemaId = InProfile.SchemaId;
		Candidate.NetworkProfileSchemaVersion = InProfile.SchemaVersion;
		Candidate.NetworkProfileId = InProfile.ProfileId;
		Candidate.FlowKind = InFlowKind;
		Candidate.CrashRunId = InCrashRunId;
		Candidate.ServerInstanceId = InServerInstanceId;
		Candidate.ConnectionPseudonym = InConnectionPseudonym;
		if (!Candidate.IsBounded())
		{
			return false;
		}
		OutSnapshot = MoveTemp(Candidate);
		return true;
	}
};

struct GAMENET_API FAethelnMetricSample
{
	EAethelnMetricKind Metric = EAethelnMetricKind::EventCount;
	EAethelnObservabilityCategory Category = EAethelnObservabilityCategory::ServerHealth;
	EAethelnSafeReason Reason = EAethelnSafeReason::None;
	EAethelnEnvironment Environment = EAethelnEnvironment::Local;
	int64 Value = 0;
};

class GAMENET_API IAethelnObservabilitySink
{
public:
	virtual ~IAethelnObservabilitySink() = default;
	virtual bool TryRecordEvent(const FAethelnObservabilityEvent& Event) = 0;
	virtual bool TryRecordMetric(const FAethelnMetricSample& Sample) = 0;
};

class GAMENET_API FAethelnNoOpObservabilitySink final : public IAethelnObservabilitySink
{
public:
	virtual bool TryRecordEvent(const FAethelnObservabilityEvent& Event) override { return Event.IsBounded(); }
	virtual bool TryRecordMetric(const FAethelnMetricSample&) override { return true; }
};

/** Local/development destination for the bounded public contract. */
class GAMENET_API FAethelnStructuredLogObservabilitySink final : public IAethelnObservabilitySink
{
public:
	virtual bool TryRecordEvent(const FAethelnObservabilityEvent& Event) override;
	virtual bool TryRecordMetric(const FAethelnMetricSample& Sample) override;
};

class GAMENET_API FAethelnInMemoryObservabilitySink final : public IAethelnObservabilitySink
{
public:
	explicit FAethelnInMemoryObservabilitySink(int32 InCapacity = AethelnObservability::MaxInMemoryEvents)
		: Capacity(FMath::Clamp(InCapacity, 0, AethelnObservability::MaxInMemoryEvents))
	{
		Events.Reserve(Capacity);
		Metrics.Reserve(Capacity);
	}

	virtual bool TryRecordEvent(const FAethelnObservabilityEvent& Event) override
	{
		if (bFailWrites || !Event.IsBounded() || Events.Num() >= Capacity)
		{
			return false;
		}
		Events.Add(Event);
		return true;
	}

	virtual bool TryRecordMetric(const FAethelnMetricSample& Sample) override
	{
		if (bFailWrites || Metrics.Num() >= Capacity)
		{
			return false;
		}
		Metrics.Add(Sample);
		return true;
	}

	void SetFailWrites(bool bInFailWrites) { bFailWrites = bInFailWrites; }
	const TArray<FAethelnObservabilityEvent>& GetEvents() const { return Events; }
	const TArray<FAethelnMetricSample>& GetMetrics() const { return Metrics; }

private:
	int32 Capacity;
	bool bFailWrites = false;
	TArray<FAethelnObservabilityEvent> Events;
	TArray<FAethelnMetricSample> Metrics;
};

class GAMENET_API IAethelnRestrictedAuditSink
{
public:
	virtual ~IAethelnRestrictedAuditSink() = default;
	virtual bool TryRecordEvent(const FAethelnObservabilityEvent& Event) = 0;
};

/** Bounded process-local retention for restricted diagnostic detail; never writes to the public log. */
class GAMENET_API FAethelnBoundedRestrictedAuditSink final : public IAethelnRestrictedAuditSink
{
public:
	explicit FAethelnBoundedRestrictedAuditSink(int32 InCapacity = AethelnObservability::MaxInMemoryEvents)
		: Capacity(FMath::Clamp(InCapacity, 0, AethelnObservability::MaxInMemoryEvents))
	{
		Events.Reserve(Capacity);
	}

	virtual bool TryRecordEvent(const FAethelnObservabilityEvent& Event) override
	{
		if (bFailWrites || !Event.IsBounded() || Events.Num() >= Capacity)
		{
			return false;
		}
		Events.Add(Event);
		return true;
	}

	void SetFailWrites(bool bInFailWrites) { bFailWrites = bInFailWrites; }
	const TArray<FAethelnObservabilityEvent>& GetEvents() const { return Events; }

private:
	int32 Capacity;
	bool bFailWrites = false;
	TArray<FAethelnObservabilityEvent> Events;
};

class GAMENET_API FAethelnObservabilityService
{
public:
	using FSinkPtr = TSharedPtr<IAethelnObservabilitySink, ESPMode::ThreadSafe>;
	using FRestrictedSinkPtr = TSharedPtr<IAethelnRestrictedAuditSink, ESPMode::ThreadSafe>;

	FAethelnObservabilityService();
	explicit FAethelnObservabilityService(FSinkPtr InSink);
	FAethelnObservabilityService(FSinkPtr InSink, FRestrictedSinkPtr InRestrictedSink);
	FAethelnObservabilityService(
		FSinkPtr InSink,
		FRestrictedSinkPtr InRestrictedSink,
		int32 InDispatchCapacity);
	~FAethelnObservabilityService();

	FAethelnObservabilityService(const FAethelnObservabilityService&) = delete;
	FAethelnObservabilityService& operator=(const FAethelnObservabilityService&) = delete;

	bool SetSink(FSinkPtr InSink);
	bool SetRestrictedSink(FRestrictedSinkPtr InSink);
	void ResetSink();
	void ResetRestrictedSink();
	void EmitEvent(const FAethelnObservabilityEvent& Event) const;
	void EmitMetric(const FAethelnMetricSample& Sample) const;

	/** Test-only synchronization; authoritative producers never call these waits. */
	bool WaitForIdleForTests(double TimeoutSeconds = 2.0) const;
	bool WaitForPublicIdleForTests(double TimeoutSeconds = 2.0) const;
	bool WaitForRestrictedIdleForTests(double TimeoutSeconds = 2.0) const;
	int32 GetPublicPendingCountForTests() const;
	int32 GetRestrictedPendingCountForTests() const;
	uint64 GetPublicDroppedCountForTests() const;
	uint64 GetRestrictedDroppedCountForTests() const;

private:
	struct FDispatchState;
	TSharedPtr<FDispatchState, ESPMode::ThreadSafe> DispatchState;
};
