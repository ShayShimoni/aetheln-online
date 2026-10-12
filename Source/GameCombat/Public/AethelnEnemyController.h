#pragma once

#include "AIController.h"
#include "AethelnEnemyCharacter.h"
#include "CoreMinimal.h"
#include "AethelnEnemyController.generated.h"

class UAethelnAbilitySystemComponent;
class UAethelnCombatTimelineSubsystem;
class UAethelnEnemyAttackAbility;

/** What the controller does with a finished move (docs/enemy-ai-and-navigation.md, Stuck recovery). */
enum class EAethelnEnemyMoveRecovery : uint8
{
	None,
	Repath,
	Reset
};

/**
 * Server-only decisions of the prototype enemy (TA-026; docs/enemy-ai-and-navigation.md): a C++ state machine
 * driven by the #60 timeline pass (step 1), whose transitions are stamped with their authored server times; late
 * interruptions and lethal results move it back to their contact time. It also runs a server eligibility query
 * for perception, engine path following, a leash around home, stuck recovery, and death and reset. It registers
 * the enemy's attack step on the timeline directly, only in pass step 1. bWantsPlayerState stays false, so FindForPawn resolves the pawn's
 * own ASC. Every Provisional... value is TBD (#107, #45). Unset config fails closed: with a zero respawn delay,
 * attack range, perception radius, or leash radius, or any non-finite or negative value, the controller decides
 * nothing. The telegraph and the interrupted pause may be 0.
 */
UCLASS(Config = Game)
class GAMECOMBAT_API AAethelnEnemyController : public AAIController
{
	GENERATED_BODY()

public:
	explicit AAethelnEnemyController(const FObjectInitializer& ObjectInitializer = FObjectInitializer::Get());

	virtual void OnMoveCompleted(FAIRequestID RequestID, const FPathFollowingResult& Result) override;

	EAethelnEnemyState GetState() const { return State; }
	double GetStateStartTime() const { return StateStartTime; }
	const APawn* GetTarget() const { return Target.Get(); }

	/** Pure policy: Blocked or OffPath repaths once, then resets; Success clears; anything else changes nothing. */
	static EAethelnEnemyMoveRecovery DecideMoveRecovery(EPathFollowingResult::Type Result, int32 PreviousConsecutiveFailures);

	UPROPERTY(Config) double ProvisionalTelegraphSeconds = 0.0;
	UPROPERTY(Config) double ProvisionalInterruptedSeconds = 0.0;
	UPROPERTY(Config) double ProvisionalRespawnSeconds = 0.0;
	UPROPERTY(Config) double ProvisionalAttackRange = 0.0;
	UPROPERTY(Config) double ProvisionalPerceptionRadius = 0.0;
	UPROPERTY(Config) double ProvisionalLeashRadius = 0.0;

protected:
	virtual void OnPossess(APawn* InPawn) override;
	virtual void OnUnPossess() override;
	virtual void EndPlay(const EEndPlayReason::Type EndPlayReason) override;

private:
	/** Pass step 1: applies a recorded move result, then runs due transitions in order until none applies at Now. */
	void Advance(double Now);
	/** One transition, if one applies; returns whether the state changed. */
	bool EvaluateOnce(double Now);
	bool IsEligible(const APawn& Candidate) const;
	APawn* ChooseTarget() const;
	bool IsInAttackRange(const APawn& Candidate) const;
	const UAethelnEnemyAttackAbility* FindAttack() const;
	/** Registers the step at StartTime; false if the timeline refused it. */
	bool StartAttack(double StartTime);
	void Enter(EAethelnEnemyState NewState, double Time);
	/** Engage: toward the target. Return: home. A failed request follows the invalid-destination rule. */
	void IssueMoveRequest(double Now);
	void BeginReturn(double Now);
	/** Pass step 1: stops moving and deciding; the reset itself waits for the pass end. */
	void RequestReset(double Time);
	/** Pass end: home, initial attributes, no target, then Idle at the requested reset time. */
	void HandlePassEnd(double Now);
	void HandleTargetInterrupted(UAethelnAbilitySystemComponent* TargetAbilitySystem, double ContactTime);
	void HandleLethalResult(UAethelnAbilitySystemComponent* TargetAbilitySystem, const FGuid& ActivationId, double ContactTime);
	/** Recorded by OnMoveCompleted during the actor tick; applied at the next pass start. */
	void ApplyMoveResult(EPathFollowingResult::Type Result, double Now);
	void Unbind();
	AAethelnEnemyCharacter* GetEnemy() const;
	UAethelnAbilitySystemComponent* GetEnemyAbilitySystem() const;
	UAethelnCombatTimelineSubsystem* GetTimeline() const;
	bool HasValidConfig() const;

	EAethelnEnemyState State = EAethelnEnemyState::Idle;
	double StateStartTime = 0.0;
	TWeakObjectPtr<APawn> Target;
	FGuid CurrentActivationId;
	double CurrentStepStart = 0.0;
	double CurrentRecoveryEnd = 0.0;
	uint32 NextSequence = 1;
	uint32 AttackCounter = 0;
	int32 ConsecutiveMoveFailures = 0;
	bool bMoveRequested = false;
	TOptional<EPathFollowingResult::Type> PendingMoveResult;
	FAIRequestID MoveRequestId;
	TOptional<double> PendingResetTime;
	TWeakObjectPtr<UAethelnCombatTimelineSubsystem> BoundTimeline;
	FDelegateHandle PassStartHandle;
	FDelegateHandle PassEndHandle;
	FDelegateHandle InterruptHandle;
	FDelegateHandle LethalHandle;
};
