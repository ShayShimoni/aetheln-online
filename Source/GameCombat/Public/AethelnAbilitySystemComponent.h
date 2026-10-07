#pragma once

#include "AbilitySystemComponent.h"
#include "AethelnActivationTypes.h"
#include "CoreMinimal.h"
#include "AethelnAbilitySystemComponent.generated.h"

class APawn;

DECLARE_MULTICAST_DELEGATE_TwoParams(FAethelnActivationOutcomeDelegate, uint32 /* Sequence */, EAethelnActivationResult /* Result */);

/** One connection's token bucket for activation messages (validation step 1). Starts full. */
struct GAMECOMBAT_API FAethelnActivationRateBucket
{
	/**
	 * Refills for the time elapsed since the last call, then takes one token if one
	 * is available. A capacity below 1 or a negative or non-finite setting admits nothing.
	 */
	bool TryConsume(double NowSeconds, double Capacity, double RefillPerSecond);

private:
	double Tokens = 0.0;
	double LastRefillSeconds = 0.0;
	bool bStarted = false;
};

/** Server state read by validation steps 2 to 7. */
struct FAethelnActivationValidationState
{
	/** The ASC's avatar is the PlayerState's current pawn, possessed by the PlayerState's controller. */
	bool bHasPossessedAvatar = false;
	bool bAvatarBeingDestroyed = false;
	uint32 LastAcceptedSequence = 0;
	/** A spec granted to this ASC is named by the request's AbilityId. */
	bool bAbilityGranted = false;
	uint32 GrantedContentVersion = 0;
	bool bAcceptsRelease = false;
	bool bAbilityActive = false;
};

/**
 * Project Ability System Component for players (owned by AAethelnPlayerState,
 * Mixed replication) and AI (owned by the pawn, Minimal replication). Hosts the
 * activation seam, the only way a client starts an ability, and closes the stock
 * client activation routes (docs/gas-foundation.md, Activation Seam).
 */
UCLASS(Config = Game)
class GAMECOMBAT_API UAethelnAbilitySystemComponent : public UAbilitySystemComponent
{
	GENERATED_BODY()

public:
	/**
	 * Resolves the ASC that acts for a pawn: the PlayerState's ASC for a player
	 * pawn, otherwise the pawn's own ASC (AI), otherwise null. The GameCore pawn
	 * carries no ASC, so the stock actor lookup cannot find a player's ASC.
	 */
	static UAethelnAbilitySystemComponent* FindForPawn(const APawn* Pawn);

	/**
	 * Validation steps 2 to 7, a pure function of the request and the server state.
	 * Step 1, the rate bucket, runs before any lookup and so before this. Returns
	 * Accepted when every step passes. bOutAbilityResolved is set once step 5 passes.
	 */
	static EAethelnActivationResult ValidateRequest(
		const FAethelnCombatActivationRequest& Request,
		const FAethelnActivationValidationState& State,
		bool& bOutAbilityResolved);

	/** Client entry point: fills in the sequence and the local content version, then sends the request. */
	void RequestActivation(const FGameplayTag& AbilityId, EAethelnActivationPhase Phase);

	/** The only way a client starts an ability. Only the owning connection can call it. */
	UFUNCTION(Server, Reliable)
	void ServerSubmitActivation(const FAethelnCombatActivationRequest& Request);

	/** Server entry shared by the RPC and automation. Returns the outcome; RateLimited also for a suppressed request. */
	EAethelnActivationResult ProcessServerRequest(const FAethelnCombatActivationRequest& Request);

	/** Owning client: every outcome, reliably and in order. */
	FAethelnActivationOutcomeDelegate OnActivationOutcome;

	/** Rate bucket placeholder, never tuning; #45 owns the final value. Without config (0) every request is rate limited. */
	UPROPERTY(Config)
	float ProvisionalActivationBucketCapacity = 0.0f;

	/** Rate bucket placeholder, never tuning; #45 owns the final value. */
	UPROPERTY(Config)
	float ProvisionalActivationBucketRefillPerSecond = 0.0f;

	/** Closed: drops the whole batch, including its target data, with no reply. */
	virtual void ServerAbilityRPCBatch_Internal(FServerAbilityRPCBatch& BatchInfo) override;

	/** Flushes an open rate-limited window. */
	virtual void OnUnregister() override;

#if WITH_DEV_AUTOMATION_TESTS
	void CallServerTryActivateAbilityForTests(FGameplayAbilitySpecHandle Handle);
	void CallServerTryActivateAbilityWithEventDataForTests(FGameplayAbilitySpecHandle Handle, const FGameplayEventData& EventData);
	bool HasReplicatedTargetDataForTests(FGameplayAbilitySpecHandle Handle, const FPredictionKey& PredictionKey) const;
#endif

protected:
	/** Closed: covers both single-ability client RPCs, with no reply. */
	virtual void InternalServerTryActivateAbility(
		FGameplayAbilitySpecHandle Handle,
		bool InputPressed,
		const FPredictionKey& PredictionKey,
		const FGameplayEventData* TriggerEventData) override;

	UFUNCTION(Client, Reliable)
	void ClientActivationOutcome(uint32 Sequence, EAethelnActivationResult Result);

private:
	friend class UAethelnGameplayAbility;

	/** The seam's result slot, open only while the seam activates this one spec handle. */
	struct FSeamScope
	{
		FGameplayAbilitySpecHandle Handle;
		bool bCommitted = false;
		FGuid ActivationId;
	};

	bool IsSeamActivating(FGameplayAbilitySpecHandle Handle) const;
	void RecordSeamCommit(FGameplayAbilitySpecHandle Handle, bool bCommitted, const FGuid& ActivationId);
	const FGameplayAbilitySpec* FindSpecForAbilityId(const FGameplayTag& AbilityId) const;
	bool AdmitMessage(bool bSeamRequest, uint32 Sequence);
	void CloseRateLimitedWindow();
	void RefuseStockRoute();
	EAethelnActivationResult Finish(
		const FAethelnCombatActivationRequest& Request,
		EAethelnActivationResult Result,
		const FGameplayTag& ResolvedAbilityId,
		const FGuid& ActivationId);

	FSeamScope* ActiveSeamScope = nullptr;
	FAethelnActivationRateBucket RateBucket;
	uint32 LastAcceptedSequence = 0;
	uint32 NextRequestSequence = 1;
	int64 SuppressedMessageCount = 0;
	bool bRateLimited = false;
};
