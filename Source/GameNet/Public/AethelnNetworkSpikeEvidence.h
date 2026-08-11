#pragma once

#include "AethelnNetworkProfile.h"
#include "AethelnReplicationCandidate.h"
#include "CoreMinimal.h"

namespace AethelnNetworkSpike
{
	inline constexpr TCHAR EvidenceSchemaId[] = TEXT("aetheln.network-authority-evidence");
	inline constexpr uint32 EvidenceSchemaVersion = 1;
	inline constexpr TCHAR ScenarioId[] = TEXT("network-authority.baseline.v1");
	inline constexpr TCHAR ActorMixId[] = TEXT("network-authority.actor-mix.v1");
	inline constexpr TCHAR MapId[] = TEXT("/Game/Maps/StarterMap");
	inline constexpr TCHAR SeedConfigId[] = TEXT("network-authority.seed-config.v1");
}

enum class EAethelnValidationMode : uint8
{
	PresentTime,
	BoundedRewind
};

enum class EAethelnActionFamily : uint8
{
	Movement,
	Melee,
	Projectile,
	Block,
	Dodge
};

enum class EAethelnCapabilityStatus : uint8
{
	Implemented,
	NotImplemented
};

/** Stable, safe reason representation. Do not expose detection internals. */
enum class EAethelnAuthorityRejectionReason : uint8
{
	None = 0,
	StaleSequence = 1,
	DuplicateSequence = 2,
	IncompatibleVersion = 3,
	TimestampOutOfBounds = 4,
	ImpossibleAimTransition = 5,
	ConnectionClosed = 6,
	ActorDestroyed = 7,
	MalformedIntent = 8,
	ActivationBlocked = 9
};

inline const TCHAR* LexToString(EAethelnAuthorityRejectionReason Reason)
{
	switch (Reason)
	{
	case EAethelnAuthorityRejectionReason::None:
		return TEXT("none");
	case EAethelnAuthorityRejectionReason::StaleSequence:
		return TEXT("stale-sequence");
	case EAethelnAuthorityRejectionReason::DuplicateSequence:
		return TEXT("duplicate-sequence");
	case EAethelnAuthorityRejectionReason::IncompatibleVersion:
		return TEXT("incompatible-version");
	case EAethelnAuthorityRejectionReason::TimestampOutOfBounds:
		return TEXT("timestamp-out-of-bounds");
	case EAethelnAuthorityRejectionReason::ImpossibleAimTransition:
		return TEXT("impossible-aim-transition");
	case EAethelnAuthorityRejectionReason::ConnectionClosed:
		return TEXT("connection-closed");
	case EAethelnAuthorityRejectionReason::ActorDestroyed:
		return TEXT("actor-destroyed");
	case EAethelnAuthorityRejectionReason::MalformedIntent:
		return TEXT("malformed-intent");
	case EAethelnAuthorityRejectionReason::ActivationBlocked:
		return TEXT("activation-blocked");
	default:
		return TEXT("unknown");
	}
}

struct GAMENET_API FAethelnScenarioCapability
{
	EAethelnActionFamily ActionFamily = EAethelnActionFamily::Movement;
	EAethelnValidationMode ValidationMode = EAethelnValidationMode::PresentTime;
	EAethelnCapabilityStatus Status = EAethelnCapabilityStatus::NotImplemented;
};

/** Immutable actor mix shared by every future replication candidate. */
struct GAMENET_API FAethelnNetworkSpikeActorMix
{
	FString ActorMixId = AethelnNetworkSpike::ActorMixId;
	int32 ClientCount = 2;
	int32 DamageableEnemyCount = 1;
	TArray<FAethelnScenarioCapability> Capabilities = {
		{ EAethelnActionFamily::Movement, EAethelnValidationMode::PresentTime, EAethelnCapabilityStatus::Implemented },
		{ EAethelnActionFamily::Melee, EAethelnValidationMode::PresentTime, EAethelnCapabilityStatus::Implemented },
		{ EAethelnActionFamily::Projectile, EAethelnValidationMode::PresentTime, EAethelnCapabilityStatus::NotImplemented },
		{ EAethelnActionFamily::Block, EAethelnValidationMode::PresentTime, EAethelnCapabilityStatus::NotImplemented },
		{ EAethelnActionFamily::Dodge, EAethelnValidationMode::PresentTime, EAethelnCapabilityStatus::NotImplemented },
		{ EAethelnActionFamily::Melee, EAethelnValidationMode::BoundedRewind, EAethelnCapabilityStatus::NotImplemented },
		{ EAethelnActionFamily::Projectile, EAethelnValidationMode::BoundedRewind, EAethelnCapabilityStatus::NotImplemented },
		{ EAethelnActionFamily::Block, EAethelnValidationMode::BoundedRewind, EAethelnCapabilityStatus::NotImplemented },
		{ EAethelnActionFamily::Dodge, EAethelnValidationMode::BoundedRewind, EAethelnCapabilityStatus::NotImplemented }
	};
};

struct GAMENET_API FAethelnNetworkSpikeProvenance
{
	FString SourceRevision;
	FString BuildIdentity;
	FString BuildConfiguration;
	FString UnrealEngineRevision;
	FString CompilerIdentity;
	FString SdkIdentity;
	FString ToolchainIdentity;
	FString ClientHardwareIdentity;
	FString ServerHardwareIdentity;
	FString TopologyIdentity;
	FString CaptureToolIdentity;
};

struct GAMENET_API FAethelnNetworkSpikeMeasurements
{
	TOptional<double> ServerGameThreadMilliseconds;
	TOptional<double> ServerReplicationCpuMilliseconds;
	TOptional<int64> ClientMemoryBytes;
	TOptional<int64> ServerMemoryBytes;
	TOptional<int64> BandwidthPerConnectionBitsPerSecond;
	TOptional<int64> AggregateBandwidthBitsPerSecond;
	TOptional<int64> CorrectionCount;
	TOptional<double> CorrectionMagnitudeCentimeters;
	TOptional<int64> RelevantActorCount;
	TOptional<int64> DestructionEventCount;
	TOptional<FString> ImplementationComplexity;
	TOptional<FString> FailureBehavior;
};

struct GAMENET_API FAethelnNetworkSpikeLifecycleEvidence
{
	TArray<FString> InitialConnectionIds;
	TOptional<FString> JoinInProgressConnectionId;
	TOptional<FString> DisconnectedConnectionId;
	TOptional<FString> ReconnectedConnectionId;
	bool bAuthoritativeEnemySpawnObserved = false;
	bool bJoinInProgressStateObserved = false;
	bool bDisconnectCleanupObserved = false;
	bool bReconnectUsedNewConnection = false;
	bool bVersionMismatchFailedClosed = false;
	bool bAuthoritativeCorrectionObserved = false;
	bool bActorDestructionObserved = false;
};

/** A server-observed rejection; it never carries a client-claimed outcome. */
struct GAMENET_API FAethelnAuthorityRejectionEvidence
{
	FString ConnectionId;
	FString ActivationId;
	FString AbilityId;
	uint64 Sequence = 0;
	EAethelnAuthorityRejectionReason Reason = EAethelnAuthorityRejectionReason::None;
};

struct GAMENET_API FAethelnNetworkSpikeEvidence
{
	FString SchemaId = AethelnNetworkSpike::EvidenceSchemaId;
	uint32 SchemaVersion = AethelnNetworkSpike::EvidenceSchemaVersion;
	FString ScenarioId = AethelnNetworkSpike::ScenarioId;
	FString SeedConfigId = AethelnNetworkSpike::SeedConfigId;
	FString MapId = AethelnNetworkSpike::MapId;
	TOptional<double> DurationSeconds;
	FAethelnNetworkSpikeActorMix ActorMix;
	FAethelnNetworkSpikeProvenance Provenance;
	FAethelnNetworkProfile NetworkProfile;
	FAethelnReplicationCandidateIdentity Candidate;
	FAethelnNetworkSpikeMeasurements Measurements;
	FAethelnNetworkSpikeLifecycleEvidence Lifecycle;
	TArray<FAethelnAuthorityRejectionEvidence> Rejections;
};
