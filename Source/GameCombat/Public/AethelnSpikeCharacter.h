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
	explicit AAethelnSpikeCharacter(const FObjectInitializer& ObjectInitializer = FObjectInitializer::Get());
	virtual void BeginPlay() override;
	virtual void Tick(float DeltaSeconds) override;
	virtual void PossessedBy(AController* NewController) override;
	virtual void OnRep_PlayerState() override;
	virtual void GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const override;

	UFUNCTION(BlueprintCallable, Category = "Spike|Combat")
	void SubmitFreeAimAttack(const FVector& AimDirection);
	void SubmitScenarioProbe(const FAethelnSpikeScenarioProbe& Probe);
	void SetObservabilityConnectionPseudonym(const FString& ConnectionPseudonym);
	const FString& GetObservabilityConnectionPseudonym() const { return ObservabilityConnectionPseudonym; }

	static bool ShouldSubmitScenarioAttack(const FString& ClientId, bool bClientReady, float ElapsedSeconds, bool bAlreadySubmitted);

private:
	void InitializePlayerStateAbilitySystem();
	void InitializePackagedScenario();
	FString GetScenarioIdentityFields() const;

	UPROPERTY(VisibleAnywhere, Category = "Spike|Combat")
	TObjectPtr<UAethelnSpikeAuthorityComponent> AuthorityComponent;

	/** Server-owned opaque connection identity, replicated only to the owning client for correction joins. */
	UPROPERTY(Replicated)
	FString ObservabilityConnectionPseudonym = TEXT("excluded");

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
