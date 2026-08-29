#pragma once

#include "AethelnSpikeAuthorityTypes.h"
#include "Components/ActorComponent.h"
#include "CoreMinimal.h"
#include "AethelnSpikeAuthorityComponent.generated.h"

class AAethelnSpikeEnemy;
class UAbilitySystemComponent;

UCLASS(ClassGroup = (Aetheln), meta = (BlueprintSpawnableComponent))
class GAMECOMBAT_API UAethelnSpikeAuthorityComponent : public UActorComponent
{
	GENERATED_BODY()

public:
	UAethelnSpikeAuthorityComponent();

	void SubmitAttack(const FVector& AimDirection);
	void SubmitScenarioProbe(const FAethelnSpikeScenarioProbe& Probe);
	void SetLifecycleReady(bool bReady);
	EAethelnSpikeAttackRejection GetLastRejection() const { return LastRejection; }
	const FGuid& GetActiveAttackId() const { return ActiveAttackId; }
	bool IsAttackWindowActive() const { return bAttackWindowActive; }

	/** Server entry shared by the RPC and behavioral automation. */
	void ProcessServerIntent(const FAethelnSpikeAttackIntent& Intent);
	/** Called only by the server-only GAS ability granted to the authoritative ASC. */
	bool ExecuteActiveAttack();

	static EAethelnSpikeAttackRejection ValidateIntent(
		const FAethelnSpikeAttackIntent& Intent,
		const FVector& AuthoritativeAimDirection,
		uint32 LastAcceptedSequence,
		double ServerTimeSeconds,
		double MaximumTimestampDeltaSeconds,
		bool bLifecycleReady,
		bool bActorUsable);
	EAethelnSpikeAttackRejection ValidateScenarioProbe(const FAethelnSpikeScenarioProbe& Probe) const;
	EAethelnSpikeAttackRejection ProcessServerScenarioProbe(const FAethelnSpikeScenarioProbe& Probe, const FString& ClientIdOverride = FString());
	static FString GetScenarioCategoryId(FName Category);

	virtual void GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const override;

protected:
	UFUNCTION(Server, Reliable)
	void ServerSubmitAttack(const FAethelnSpikeAttackIntent& Intent);

	UFUNCTION(Server, Reliable)
	void ServerSubmitScenarioProbe(const FAethelnSpikeScenarioProbe& Probe);

private:
	void Reject(EAethelnSpikeAttackRejection Reason);
	UAbilitySystemComponent* ResolveOwnerAbilitySystem() const;
	void CloseAttackWindow();

	UPROPERTY(Replicated)
	EAethelnSpikeAttackRejection LastRejection = EAethelnSpikeAttackRejection::None;

	/** Private spike-only default. This is provisional configuration, not a measured or canonical network decision. */
	UPROPERTY(EditDefaultsOnly, Category = "Aetheln|Network Authority Spike", meta = (ClampMin = "0.0"))
	double ProvisionalMaximumTimestampDeltaSeconds = 2.0;

	/** Private spike-only default. This is provisional configuration, not a canonical combat reach decision. */
	UPROPERTY(EditDefaultsOnly, Category = "Aetheln|Network Authority Spike", meta = (ClampMin = "0.0"))
	float ProvisionalAttackReach = 175.0f;

	/** Private spike-only default. This is provisional configuration, not a canonical combat radius decision. */
	UPROPERTY(EditDefaultsOnly, Category = "Aetheln|Network Authority Spike", meta = (ClampMin = "0.0"))
	float ProvisionalAttackRadius = 75.0f;

	uint32 NextClientSequence = 1;
	uint32 LastAcceptedSequence = 0;
	bool bLifecycleReady = false;
	bool bAttackWindowActive = false;
	FGuid ActiveAttackId;
	FAethelnSpikeAttackIntent PendingIntent;
	TSet<TWeakObjectPtr<AAethelnSpikeEnemy>> AlreadyHitTargets;
};
