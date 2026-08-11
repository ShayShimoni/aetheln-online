#pragma once

#include "CoreMinimal.h"

namespace AethelnNetworkSpike
{
	inline constexpr TCHAR ReplicationCandidateSchemaId[] = TEXT("aetheln.replication-candidate");
	inline constexpr uint32 ReplicationCandidateSchemaVersion = 1;
	inline constexpr TCHAR NoSelectedCandidateId[] = TEXT("replication-candidate.unselected");
	inline constexpr TCHAR GenericPushModelCandidateId[] = TEXT("replication-candidate.generic-push-model");
	inline constexpr TCHAR ReplicationGraphCandidateId[] = TEXT("replication-candidate.replication-graph");
	inline constexpr TCHAR IrisCandidateId[] = TEXT("replication-candidate.iris");
}

/** Identity recorded for one isolated replication implementation candidate. */
struct GAMENET_API FAethelnReplicationCandidateIdentity
{
	FString SchemaId = AethelnNetworkSpike::ReplicationCandidateSchemaId;
	uint32 SchemaVersion = AethelnNetworkSpike::ReplicationCandidateSchemaVersion;
	FString CandidateId = AethelnNetworkSpike::NoSelectedCandidateId;
	FString ImplementationRevision;

	bool IsSelected() const
	{
		return CandidateId != AethelnNetworkSpike::NoSelectedCandidateId;
	}
};

/**
 * Candidate adapter seam. Implementations configure replication only; they do
 * not own combat truth, latency validation policy, or evidence measurements.
 */
class GAMENET_API IAethelnReplicationCandidate
{
public:
	virtual ~IAethelnReplicationCandidate() = default;

	virtual const FAethelnReplicationCandidateIdentity& GetIdentity() const = 0;
	virtual bool IsAvailableForPackagedRun(FString& OutUnavailableReason) const = 0;
};
