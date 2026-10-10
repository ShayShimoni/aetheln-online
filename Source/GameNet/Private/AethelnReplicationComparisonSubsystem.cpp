#include "AethelnReplicationComparisonSubsystem.h"

#include "AethelnReplicationCandidateRuntime.h"
#include "AethelnReplicationComparisonProbeActor.h"
#include "Engine/NetConnection.h"
#include "Engine/NetDriver.h"
#include "Engine/World.h"
#include "GameFramework/PlayerController.h"

bool UAethelnReplicationComparisonSubsystem::ShouldCreateSubsystem(UObject* Outer) const
{
#if UE_BUILD_SHIPPING
	return false;
#else
	return AethelnReplicationCandidates::IsActive() && Super::ShouldCreateSubsystem(Outer);
#endif
}

bool UAethelnReplicationComparisonSubsystem::DoesSupportWorldType(EWorldType::Type WorldType) const
{
	return WorldType == EWorldType::Game || WorldType == EWorldType::PIE;
}

TStatId UAethelnReplicationComparisonSubsystem::GetStatId() const
{
	RETURN_QUICK_DECLARE_CYCLE_STAT(UAethelnReplicationComparisonSubsystem, STATGROUP_Tickables);
}

void UAethelnReplicationComparisonSubsystem::Tick(float DeltaTime)
{
	UWorld* World = GetWorld();
	if (World == nullptr || !World->HasBegunPlay() || !AethelnReplicationCandidates::IsActive()) { return; }
	UNetDriver* Driver = World->GetNetDriver();
	FAethelnReplicationCandidateObservation Observation;
	FString Reason;
	const FAethelnReplicationCandidateRequest& Request = AethelnReplicationCandidates::GetRequest();
	if (!AethelnReplicationCandidates::InspectDriver(Request, Driver, Observation, Reason))
	{
		if (Reason == TEXT("initialized_backend_mismatch")) { AethelnReplicationCandidates::Refuse(*Reason); }
		return;
	}
	if (ObservedDriver.Get() != Driver)
	{
		ObservedDriver = Driver;
		UE_LOG(LogTemp, Display, TEXT("AETHELN_REPLICATION_BACKEND candidate=%s run=%s source=%s build=%s toolchain=%s server=%d iris=%d graph=%d driver=%s legacyPushEnabled=%d legacyPushHandles=%d"),
			*Request.CandidateId, *Request.RunId, *Request.SourceRevision, *Request.BuildIdentity, *Request.ToolchainIdentity,
			Observation.bServer ? 1 : 0, Observation.bIris ? 1 : 0, Observation.bGraph ? 1 : 0, *Observation.DriverClass,
			Observation.bLegacyPushEnabled ? 1 : 0, Observation.bLegacyPushHandlesAllowed ? 1 : 0);
	}
	if (!Observation.bServer) { return; }
	for (auto It = Probes.CreateIterator(); It; ++It)
	{
		if (!It.Key().IsValid())
		{
			if (It.Value().IsValid()) { It.Value()->Destroy(); }
			It.RemoveCurrent();
		}
	}
	for (FConstPlayerControllerIterator It = World->GetPlayerControllerIterator(); It; ++It)
	{
		APlayerController* Controller = It->Get();
		UNetConnection* Connection = Controller != nullptr ? Controller->GetNetConnection() : nullptr;
		const TWeakObjectPtr<APlayerController> Key(Controller);
		if (Controller == nullptr || Controller->IsLocalController() || Connection == nullptr
			|| Connection->GetConnectionState() != USOCK_Open || Probes.Contains(Key)) { continue; }
		FActorSpawnParameters Params;
		Params.Owner = Controller;
		AAethelnReplicationComparisonProbeActor* Probe = World->SpawnActor<AAethelnReplicationComparisonProbeActor>(Params);
		if (Probe == nullptr || !Probe->StartProbe(Controller))
		{
			AethelnReplicationCandidates::Refuse(TEXT("replication_probe_creation_failed"));
			return;
		}
		Probes.Add(Key, TWeakObjectPtr<AAethelnReplicationComparisonProbeActor>(Probe));
	}
}
