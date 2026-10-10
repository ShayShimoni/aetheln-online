#pragma once

#include "CoreMinimal.h"
#include "GameFramework/Actor.h"
#include "AethelnReplicationComparisonProbeActor.generated.h"

class APlayerController;

USTRUCT()
struct GAMENET_API FAethelnReplicationProbeState
{
	GENERATED_BODY()

	UPROPERTY()
	FString ProbeId;

	UPROPERTY()
	uint32 Revision = 0;

	UPROPERTY()
	FString CandidateId;

	UPROPERTY()
	FString RunId;

	UPROPERTY()
	FString SourceRevision;

	UPROPERTY()
	FString BuildIdentity;

	UPROPERTY()
	FString ToolchainIdentity;
};

/** Identical owner-relevant property/RPC probe for all three isolated candidates. */
UCLASS(NotBlueprintable)
class GAMENET_API AAethelnReplicationComparisonProbeActor : public AActor
{
	GENERATED_BODY()

public:
	AAethelnReplicationComparisonProbeActor();
	virtual void GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const override;
	virtual void Tick(float DeltaSeconds) override;
	bool StartProbe(APlayerController* OwningController);
	uint32 GetProbeRevision() const { return ProbeState.Revision; }

private:
	UPROPERTY(ReplicatedUsing=OnRep_ProbeState)
	FAethelnReplicationProbeState ProbeState;

	UFUNCTION()
	void OnRep_ProbeState();

	UFUNCTION(Server, Reliable)
	void ServerAcknowledgeBaseline(const FString& ProbeId);

	bool ObserveBackend() const;
	void LogObservation(const TCHAR* Event) const;
	uint32 LastObservedRevision = 0;
	uint32 ReceivedRevision = 0;
	FString ReceivedProbeId;
	bool bBaselineAcknowledged = false;
};
