#pragma once

#include "AethelnPlayerCharacter.h"
#include "CoreMinimal.h"
#include "AethelnSpikeCharacter.generated.h"

class UAethelnSpikeAuthorityComponent;
struct FAethelnSpikeScenarioProbe;

UCLASS()
class GAMECOMBAT_API AAethelnSpikeCharacter : public AAethelnPlayerCharacter
{
	GENERATED_BODY()

public:
	AAethelnSpikeCharacter();
	virtual void BeginPlay() override;
	virtual void Tick(float DeltaSeconds) override;
	virtual void PossessedBy(AController* NewController) override;
	virtual void OnRep_PlayerState() override;

	UFUNCTION(BlueprintCallable, Category = "Spike|Combat")
	void SubmitFreeAimAttack(const FVector& AimDirection);
	void SubmitScenarioProbe(const FAethelnSpikeScenarioProbe& Probe);

private:
	void InitializePlayerStateAbilitySystem();
	void InitializePackagedScenario();
	FString GetScenarioIdentityFields() const;

	UPROPERTY(VisibleAnywhere, Category = "Spike|Combat")
	TObjectPtr<UAethelnSpikeAuthorityComponent> AuthorityComponent;

	FString ScenarioClientId;
	FString ScenarioEndpoint;
	FString ScenarioMap;
	FString ScenarioId;
	FString ScenarioProfileId;
	FString ScenarioRunId;
	float ScenarioElapsedSeconds = 0.0f;
	bool bPackagedScenarioEnabled = false;
	bool bClientReadyObserved = false;
	bool bJoinInProgressObserved = false;
	bool bAttackSubmitted = false;
	bool bProbesSubmitted = false;
};
