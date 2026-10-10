#pragma once

#include "CoreMinimal.h"
#include "Subsystems/WorldSubsystem.h"
#include "AethelnReplicationComparisonSubsystem.generated.h"

class APlayerController;
class AAethelnReplicationComparisonProbeActor;
class UNetDriver;

/** Opt-in experiment lifecycle; no combat or performance authority. */
UCLASS()
class GAMENET_API UAethelnReplicationComparisonSubsystem : public UTickableWorldSubsystem
{
	GENERATED_BODY()

public:
	virtual bool ShouldCreateSubsystem(UObject* Outer) const override;
	virtual void Tick(float DeltaTime) override;
	virtual TStatId GetStatId() const override;

protected:
	virtual bool DoesSupportWorldType(EWorldType::Type WorldType) const override;

private:
	TWeakObjectPtr<UNetDriver> ObservedDriver;
	TMap<TWeakObjectPtr<APlayerController>, TWeakObjectPtr<AAethelnReplicationComparisonProbeActor>> Probes;
};
