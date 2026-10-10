#pragma once

#include "AethelnReplicationCandidate.h"

class UNetDriver;

/** One immutable, explicit laboratory choice for an isolated process. */
struct GAMENET_API FAethelnReplicationCandidateRequest
{
	FString CandidateId = AethelnNetworkSpike::NoSelectedCandidateId;
	FString RunId;
	FString SourceRevision;
	FString BuildIdentity;
	FString ToolchainIdentity;

	bool IsSelected() const { return CandidateId != AethelnNetworkSpike::NoSelectedCandidateId; }
};

/** Observations of an initialized driver, never inferred from its requested label. */
struct GAMENET_API FAethelnReplicationCandidateObservation
{
	bool bInitialized = false;
	bool bServer = false;
	bool bIris = false;
	bool bGraph = false;
	bool bLegacyPushEnabled = false;
	bool bLegacyPushHandlesAllowed = false;
	FString DriverClass;
};

namespace AethelnReplicationCandidates
{
	GAMENET_API bool ParseRequest(const FString& CommandLine, FAethelnReplicationCandidateRequest& OutRequest, FString& OutReason);
	GAMENET_API TUniquePtr<IAethelnReplicationCandidate> CreateCandidate(const FAethelnReplicationCandidateRequest& Request);
	GAMENET_API bool InspectDriver(const FAethelnReplicationCandidateRequest& Request, UNetDriver* Driver,
		FAethelnReplicationCandidateObservation& OutObservation, FString& OutReason);
	GAMENET_API const FAethelnReplicationCandidateRequest& GetRequest();
	GAMENET_API bool IsActive();
	GAMENET_API void Startup();
	GAMENET_API void Shutdown();
	GAMENET_API void Refuse(const TCHAR* Reason);
}
