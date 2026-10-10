#include "AethelnReplicationComparisonProbeActor.h"

#include "AethelnReplicationCandidateRuntime.h"
#include "Engine/NetConnection.h"
#include "Engine/World.h"
#include "GameFramework/PlayerController.h"
#include "Net/UnrealNetwork.h"
#include "Net/Core/PushModel/PushModel.h"

AAethelnReplicationComparisonProbeActor::AAethelnReplicationComparisonProbeActor()
{
	bReplicates = true;
	bOnlyRelevantToOwner = true;
	SetReplicateMovement(false);
	PrimaryActorTick.bCanEverTick = true;
}

void AAethelnReplicationComparisonProbeActor::GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const
{
	Super::GetLifetimeReplicatedProps(OutLifetimeProps);
	FDoRepLifetimeParams Params;
	Params.bIsPushBased = true;
	DOREPLIFETIME_WITH_PARAMS_FAST(AAethelnReplicationComparisonProbeActor, ProbeState, Params);
}

bool AAethelnReplicationComparisonProbeActor::StartProbe(APlayerController* OwningController)
{
	if (!HasAuthority() || OwningController == nullptr || ProbeState.Revision != 0) { return false; }
	SetOwner(OwningController);
	const FAethelnReplicationCandidateRequest& Request = AethelnReplicationCandidates::GetRequest();
	ProbeState.CandidateId = Request.CandidateId;
	ProbeState.RunId = Request.RunId;
	ProbeState.SourceRevision = Request.SourceRevision;
	ProbeState.BuildIdentity = Request.BuildIdentity;
	ProbeState.ToolchainIdentity = Request.ToolchainIdentity;
	ProbeState.ProbeId = FGuid::NewGuid().ToString(EGuidFormats::Digits);
	ProbeState.Revision = 1; // Transport baseline, not a performance/tuning value.
	MARK_PROPERTY_DIRTY_FROM_NAME(AAethelnReplicationComparisonProbeActor, ProbeState, this);
	ForceNetUpdate();
	return true;
}

bool AAethelnReplicationComparisonProbeActor::ObserveBackend() const
{
	FAethelnReplicationCandidateObservation Observation;
	FString Reason;
	return AethelnReplicationCandidates::IsActive() && GetWorld() != nullptr
		&& AethelnReplicationCandidates::InspectDriver(AethelnReplicationCandidates::GetRequest(),
			GetWorld()->GetNetDriver(), Observation, Reason);
}

void AAethelnReplicationComparisonProbeActor::LogObservation(const TCHAR* Event) const
{
	const FAethelnReplicationCandidateRequest& Request = AethelnReplicationCandidates::GetRequest();
	UE_LOG(LogTemp, Display, TEXT("AETHELN_REPLICATION_PROBE event=%s candidate=%s run=%s source=%s build=%s toolchain=%s probe=%s revision=%u authority=%d"),
		Event, *Request.CandidateId, *Request.RunId, *Request.SourceRevision, *Request.BuildIdentity,
		*Request.ToolchainIdentity, *ProbeState.ProbeId, ProbeState.Revision, HasAuthority() ? 1 : 0);
}

void AAethelnReplicationComparisonProbeActor::OnRep_ProbeState()
{
	// Ownership and PendingNetDriver adoption may resolve after this rep-notify.
	// Tick consumes the actual received state only once the owning connection is ready.
	ReceivedRevision = ProbeState.Revision;
	ReceivedProbeId = ProbeState.ProbeId;
}

void AAethelnReplicationComparisonProbeActor::Tick(float DeltaSeconds)
{
	Super::Tick(DeltaSeconds);
	if (HasAuthority() || GetNetMode() != NM_Client || !ObserveBackend()
		|| ReceivedRevision != ProbeState.Revision || ReceivedProbeId != ProbeState.ProbeId) { return; }
	const APlayerController* Controller = Cast<APlayerController>(GetOwner());
	if (Controller == nullptr || !Controller->IsLocalController()) { return; }
	const FAethelnReplicationCandidateRequest& Request = AethelnReplicationCandidates::GetRequest();
	if (ProbeState.Revision != 0 && (ProbeState.CandidateId != Request.CandidateId || ProbeState.RunId != Request.RunId
		|| ProbeState.SourceRevision != Request.SourceRevision || ProbeState.BuildIdentity != Request.BuildIdentity
		|| ProbeState.ToolchainIdentity != Request.ToolchainIdentity))
	{
		AethelnReplicationCandidates::Refuse(TEXT("remote_probe_provenance_mismatch"));
		return;
	}
	if (ProbeState.Revision == 1 && LastObservedRevision == 0 && !ProbeState.ProbeId.IsEmpty())
	{
		LastObservedRevision = 1;
		LogObservation(TEXT("baseline_received"));
		bBaselineAcknowledged = true;
		ServerAcknowledgeBaseline(ProbeState.ProbeId);
	}
	else if (ProbeState.Revision == 2 && LastObservedRevision == 1 && bBaselineAcknowledged)
	{
		LastObservedRevision = 2;
		LogObservation(TEXT("postinitial_update_received"));
	}
}

void AAethelnReplicationComparisonProbeActor::ServerAcknowledgeBaseline_Implementation(const FString& ProbeId)
{
	const APlayerController* Controller = Cast<APlayerController>(GetOwner());
	const UNetConnection* Connection = Controller != nullptr ? Controller->GetNetConnection() : nullptr;
	if (!HasAuthority() || !ObserveBackend() || Connection == nullptr
		|| Connection->GetConnectionState() != USOCK_Open || ProbeState.Revision != 1
		|| ProbeId != ProbeState.ProbeId || bBaselineAcknowledged)
	{
		return;
	}
	bBaselineAcknowledged = true;
	LogObservation(TEXT("baseline_acknowledged"));
	ProbeState.Revision = 2;
	MARK_PROPERTY_DIRTY_FROM_NAME(AAethelnReplicationComparisonProbeActor, ProbeState, this);
	ForceNetUpdate();
	LogObservation(TEXT("postinitial_update_sent"));
}
