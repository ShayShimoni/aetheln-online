#pragma once

#include "AbilitySystemComponent.h"
#include "AethelnActivationTypes.h"
#include "AethelnAttackTypes.h"
#include "CoreMinimal.h"
#include "AethelnAbilitySystemComponent.generated.h"

class APawn;
class AController;
class UAethelnBasicChainAbility;
class UAethelnCombatTimelineSubsystem;

DECLARE_MULTICAST_DELEGATE_TwoParams(FAethelnActivationOutcomeDelegate, uint32 /* Sequence */, EAethelnActivationResult /* Result */);
DECLARE_MULTICAST_DELEGATE_OneParam(FAethelnCombatActivationDelegate, const FAethelnCombatActivationRecord&);
DECLARE_MULTICAST_DELEGATE_TwoParams(FAethelnChainEndDelegate, const FGuid&, EAethelnChainEndReason);

/** Server-only chain bookkeeping, separate from GAS activation and observer state. */
struct FAethelnServerChainState
{
	bool bExists = false;
	bool bWaiting = false;
	bool bCommitmentHeld = false;
	uint8 Step = 0;
	double StartTime = 0.0;
	double BufferedStartTime = 0.0;
	FGameplayAbilitySpecHandle Handle;
	TWeakObjectPtr<UAethelnBasicChainAbility> Ability;
	TArray<FAethelnAttackStepDefinition> Definitions;
	FAethelnAcceptedAttackInput CurrentInput;
	FAethelnAcceptedAttackInput BufferedInput;
};

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

/**
 * Aim and time bounds for validation steps 6a to 6d (docs/attack-timeline-and-combo.md,
 * Validation additions). Valid when every value is finite, 0 <= soft <= hard < 180,
 * the rate slack is in [0, 180], the rate is >= 0, the unit and age tolerances are
 * positive, and the lead and regression tolerances are >= 0. The zero defaults are
 * invalid, so unset config fails closed.
 */
struct FAethelnAimTimeBounds
{
	double AimSoftBoundDegrees = 0.0;
	double AimHardBoundDegrees = 0.0;
	double AimMaxRateDegreesPerSecond = 0.0;
	double AimRateSlackDegrees = 0.0;
	/** Largest allowed | |Aim| - 1 |. */
	double AimUnitTolerance = 0.0;
	double TimestampMaxAgeSeconds = 0.0;
	double TimestampMaxLeadSeconds = 0.0;
	double TimestampRegressionToleranceSeconds = 0.0;
};

/** Server state read by validation steps 2 to 7, including #60's 6a to 6d. */
struct FAethelnActivationValidationState
{
	/** The ASC's avatar is the PlayerState's current pawn, possessed by the PlayerState's controller. */
	bool bHasPossessedAvatar = false;
	bool bAvatarBeingDestroyed = false;
	/** 0 until a request is accepted; then the previous-request checks of 6a and 6d apply. */
	uint32 LastAcceptedSequence = 0;
	/** Scoped requests still on the server stack; not accepted aim/time history. */
	uint32 HighestInFlightSequence = 0;
	/** A spec granted to this ASC is named by the request's AbilityId. */
	bool bAbilityGranted = false;
	uint32 GrantedContentVersion = 0;
	bool bAcceptsRelease = false;
	bool bAbilityActive = false;
	/** Server world time at receipt (6a). */
	double NowSeconds = 0.0;
	/** R: the unit vector of the avatar controller's current server control rotation (6b to 6d). */
	FVector ReferenceAim = FVector::ZeroVector;
	/** Raw aim and client time of the request accepted with LastAcceptedSequence (6a, 6d). */
	FVector LastAcceptedAim = FVector::ZeroVector;
	double LastAcceptedClientTimeSeconds = 0.0;
	FAethelnAimTimeBounds Bounds;
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
	 * Validation steps 2 to 7, with #60's 6a to 6d between 6 and 7, a pure function of
	 * the request and the server state. Step 1, the rate bucket, runs before any lookup
	 * and so before this. Returns Accepted when every step passes. bOutAbilityResolved
	 * is set once step 5 passes. OutAcceptedAim (unit) and OutAimCorrection are set once
	 * step 6d passes: the aim itself within the soft bound of R, otherwise R rotated
	 * toward it by exactly the soft bound.
	 */
	static EAethelnActivationResult ValidateRequest(
		const FAethelnCombatActivationRequest& Request,
		const FAethelnActivationValidationState& State,
		bool& bOutAbilityResolved,
		FVector& OutAcceptedAim,
		EAethelnAimCorrection& OutAimCorrection);

	/**
	 * Client entry point: fills in the sequence, the local content version, the owning
	 * controller's control-rotation aim, and the game state's server world time (local
	 * world time without a game state), flushes any held move, then sends the request.
	 */
	void RequestActivation(const FGameplayTag& AbilityId, EAethelnActivationPhase Phase);

	/** The only way a client starts an ability. Only the owning connection can call it. */
	UFUNCTION(Server, Reliable)
	void ServerSubmitActivation(const FAethelnCombatActivationRequest& Request);

	/** Server entry shared by the RPC and automation. Returns the outcome; RateLimited also for a suppressed request. */
	EAethelnActivationResult ProcessServerRequest(const FAethelnCombatActivationRequest& Request);

	/** Owning client: every outcome, reliably and in order. */
	FAethelnActivationOutcomeDelegate OnActivationOutcome;
	FAethelnCombatActivationDelegate OnCombatActivation;
	FAethelnChainEndDelegate OnChainEnded;
	const FAethelnAttackPresentationState& GetAttackPresentationState() const { return AttackPresentationState; }

	/** Authority only; stamp the step and clear the chain once, without removing a mid-frame step. */
	void ResetChain(EAethelnChainEndReason Reason);
	void ResetChain(EAethelnChainEndReason Reason, double ResetTime);
	virtual void GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const override;

	/** Rate bucket placeholder, never tuning; #45 owns the final value. Without config (0) every request is rate limited. */
	UPROPERTY(Config)
	float ProvisionalActivationBucketCapacity = 0.0f;

	/** Rate bucket placeholder, never tuning; #45 owns the final value. */
	UPROPERTY(Config)
	float ProvisionalActivationBucketRefillPerSecond = 0.0f;

	/*
	 * Aim and time bound placeholders for steps 6a to 6d, never tuning; the values are TBD
	 * (#60 Data-Driven Tuning, #45, #2). Unset (0) they are invalid, so every seam request
	 * fails closed with InternalFailure.
	 */
	UPROPERTY(Config)
	float ProvisionalAimSoftBoundDegrees = 0.0f;

	UPROPERTY(Config)
	float ProvisionalAimHardBoundDegrees = 0.0f;

	UPROPERTY(Config)
	float ProvisionalAimMaxRateDegreesPerSecond = 0.0f;

	UPROPERTY(Config)
	float ProvisionalAimRateSlackDegrees = 0.0f;

	UPROPERTY(Config)
	float ProvisionalAimUnitTolerance = 0.0f;

	UPROPERTY(Config)
	float ProvisionalTimestampMaxAgeSeconds = 0.0f;

	UPROPERTY(Config)
	float ProvisionalTimestampMaxLeadSeconds = 0.0f;

	UPROPERTY(Config)
	float ProvisionalTimestampRegressionToleranceSeconds = 0.0f;

	/** Closed: drops the whole batch, including its target data, with no reply. */
	virtual void ServerAbilityRPCBatch_Internal(FServerAbilityRPCBatch& BatchInfo) override;

	/** Closed: no cache writes, one bucket token, metric only, no owner reply. */
	virtual void ServerSetReplicatedTargetData_Implementation(FGameplayAbilitySpecHandle AbilityHandle, FPredictionKey AbilityOriginalPredictionKey, const FGameplayAbilityTargetDataHandle& ReplicatedTargetDataHandle, FGameplayTag ApplicationTag, FPredictionKey CurrentPredictionKey) override;
	virtual void ServerSetReplicatedTargetDataCancelled_Implementation(FGameplayAbilitySpecHandle AbilityHandle, FPredictionKey AbilityOriginalPredictionKey, FPredictionKey CurrentPredictionKey) override;
	virtual void ServerSetReplicatedEvent_Implementation(EAbilityGenericReplicatedEvent::Type EventType, FGameplayAbilitySpecHandle AbilityHandle, FPredictionKey AbilityOriginalPredictionKey, FPredictionKey CurrentPredictionKey) override;
	virtual void ServerSetReplicatedEventWithPayload_Implementation(EAbilityGenericReplicatedEvent::Type EventType, FGameplayAbilitySpecHandle AbilityHandle, FPredictionKey AbilityOriginalPredictionKey, FPredictionKey CurrentPredictionKey, FVector_NetQuantize100 VectorPayload) override;

	/** Flushes an open rate-limited window. */
	virtual void OnUnregister() override;
	virtual void EndPlay(const EEndPlayReason::Type EndPlayReason) override;

#if WITH_DEV_AUTOMATION_TESTS
	const FAethelnServerChainState& GetChainStateForTests() const { return ChainState; }
	double GetLastChainResetTimeForTests() const { return LastChainResetTime; }
	uint32 GetLastAcceptedSequenceForTests() const { return LastAcceptedSequence; }
	FVector GetLastAcceptedAimForTests() const { return LastAcceptedAim; }
	double GetLastAcceptedClientTimeForTests() const { return LastAcceptedClientTimeSeconds; }
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
	UFUNCTION(Client, Reliable)
	void ClientCombatActivation(const FAethelnCombatActivationRecord& Record);
	UFUNCTION(Client, Reliable)
	void ClientChainEnded(const FGuid& ActivationId, EAethelnChainEndReason Reason);

private:
	friend class UAethelnGameplayAbility;
	friend class UAethelnBasicChainAbility;
	friend class UAethelnCombatTimelineSubsystem;

	/** The seam's result slot, open only while the seam activates this one spec handle. */
	struct FSeamScope
	{
		FGameplayAbilitySpecHandle Handle;
		bool bCommitted = false;
		bool bChainReady = false;
		bool bCanceled = false;
		FGuid ActivationId;
		FAethelnAcceptedAttackInput AttackInput;
	};
	/** Per-call reservation: discarded on every return, including refusal. */
	struct FRequestScope
	{
		FRequestScope* Previous = nullptr;
		uint32 Sequence = 0;
		TWeakObjectPtr<AActor> Owner;
		TWeakObjectPtr<AActor> Avatar;
		TWeakObjectPtr<AController> Controller;
	};
	FRequestScope* ActiveRequestScope = nullptr;

	bool BeginChainPress(UAethelnBasicChainAbility& Ability, FGameplayAbilitySpecHandle Handle);
	bool StartChainStep(const FAethelnAcceptedAttackInput& Input, uint8 Step, double StartTime);
	void StartBufferedChainStep(double Now);
	void ApplyChainBoundaries(double Now);
	void HandleChainResetTag(const FGameplayTag Tag, int32 NewCount);
	void BindChainResetTags(const FGameplayTagContainer& Tags);
	void UnbindChainResetTags();
	UAethelnCombatTimelineSubsystem* GetCombatTimeline() const;
	FAethelnServerChainState ChainState;
	TArray<TPair<FGameplayTag, FDelegateHandle>> ChainResetHandles;
	double LastChainResetTime = 0.0;
	uint32 AttackActivationCounter = 0;
	UPROPERTY(Replicated)
	FAethelnAttackPresentationState AttackPresentationState;

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
		const FGuid& ActivationId,
		EAethelnAimCorrection AimCorrection = EAethelnAimCorrection::None);

	FSeamScope* ActiveSeamScope = nullptr;
	FAethelnActivationRateBucket RateBucket;
	uint32 LastAcceptedSequence = 0;
	/** Raw, as received; they advance only with LastAcceptedSequence. */
	FVector LastAcceptedAim = FVector::ZeroVector;
	double LastAcceptedClientTimeSeconds = 0.0;
	uint32 NextRequestSequence = 1;
	int64 SuppressedMessageCount = 0;
	bool bRateLimited = false;
};
