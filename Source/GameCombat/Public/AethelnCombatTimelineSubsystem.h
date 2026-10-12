#pragma once

#include "AethelnAttackTypes.h"
#include "Subsystems/WorldSubsystem.h"
#include "AethelnCombatTimelineSubsystem.generated.h"

class UAethelnAbilitySystemComponent;

DECLARE_MULTICAST_DELEGATE_TwoParams(FAethelnAttackWindowDelegate, const FAethelnCombatActivationRecord&, const FAethelnAttackSampleInterval&);
DECLARE_MULTICAST_DELEGATE_OneParam(FAethelnCombatResultDelegate, const FAethelnCombatResult&);
DECLARE_MULTICAST_DELEGATE_ThreeParams(FAethelnLethalResultDelegate, UAethelnAbilitySystemComponent* /* TargetAsc */, const FGuid& /* ActivationId */, double /* ContactTime */);
DECLARE_MULTICAST_DELEGATE_TwoParams(FAethelnInterruptedDelegate, UAethelnAbilitySystemComponent* /* TargetAsc */, double /* ContactTime */);
DECLARE_MULTICAST_DELEGATE_OneParam(FAethelnPassDelegate, double /* Now */);

/**
 * One own-world server pass after actor tick: buffered starts, sweeps of the authored volumes,
 * contact resolution in the canonical total order, boundaries, then emission
 * (docs/attack-timeline-and-combo.md, Timeline driver and clock).
 */
UCLASS(Config = Game)
class GAMECOMBAT_API UAethelnCombatTimelineSubsystem : public UWorldSubsystem
{
	GENERATED_BODY()

public:
	virtual void Initialize(FSubsystemCollectionBase& Collection) override;
	virtual void Deinitialize() override;
	virtual bool ShouldCreateSubsystem(UObject* Outer) const override;

	/** The sampling bounds are the registering ability's authored budget (TBD, #45). */
	bool RegisterStep(UAethelnAbilitySystemComponent& AbilitySystem, const FAethelnAttackStepDefinition& Step, FAethelnCombatActivationRecord& Record, double MaxSampleDistance, double MaxSampleAngleDegrees);
	bool CanRegisterStep(const UAethelnAbilitySystemComponent& AbilitySystem) const;
	/**
	 * Non-chain boundary registration (#18 P3): the ASC's own timelines, such as the dodge
	 * windows, get their due boundaries applied in pass step 4 until none remain pending.
	 */
	bool RegisterNonChainBoundaries(UAethelnAbilitySystemComponent& AbilitySystem);
	void StampReset(const FGuid& ActivationId, double Time);

	/** The one relation rule (OQ1): players are allies, only enemies are hostile, never self. Faction policy replaces it later. */
	static bool IsHostile(const UAethelnAbilitySystemComponent& Attacker, const UAethelnAbilitySystemComponent& Target);

	/** Not alive: State.Dead, no Health attribute (fails closed until #21), or zero Health. Revalidation step 1. */
	static bool IsAlive(const UAethelnAbilitySystemComponent& AbilitySystem);

	/**
	 * Server only. The defense owner (#18) registers a target's one defense slot. Returns false while
	 * another slot is still held (no finite end), so a second slot fails closed; an ended slot is
	 * replaced. EndDefenseState stamps the exclusive end and keeps the slot, so contacts stay exact.
	 */
	bool SetDefenseState(UAethelnAbilitySystemComponent& Target, const FAethelnDefenseState& State);
	void EndDefenseState(UAethelnAbilitySystemComponent& Target, double EndTime);
	void ClearDefenseState(UAethelnAbilitySystemComponent& Target);
	const FAethelnDefenseState* FindDefenseState(UAethelnAbilitySystemComponent& Target) const;

	/**
	 * Authored avoidance set, checked by presence when the contact resolves: a target holding any of
	 * these tags yields Avoided. Empty. The dodge never enters it: its window is asked at the contact
	 * time (IsAvoidingAt, #18 T2), and no interval-backed tag may be added here.
	 */
	UPROPERTY(Config)
	FGameplayTagContainer AvoidanceTags;

	FAethelnAttackWindowDelegate OnWindowEvaluated;
	/** Every committed result, in resolution order, for audit. */
	FAethelnCombatResultDelegate OnResultCommitted;
	/**
	 * Raised once per target from its lethal committed result, with its contact time; #21 binds it and applies
	 * State.Dead, and the enemy controller (#83) dies at that time.
	 */
	FAethelnLethalResultDelegate OnLethalResult;
	/**
	 * Pass step 1, after the players' buffered starts and before the sweeps. The enemy controllers (#83) advance
	 * to Now here, so a step they register at S <= Now is swept and resolved in this same pass.
	 */
	FAethelnPassDelegate OnPassStart;
	/** After pass step 5 (emission). The enemy controllers (#83) apply a pending reset here. */
	FAethelnPassDelegate OnPassEnd;
	/**
	 * Raised once per committed interruption, during resolution, after the target's steps are stamped at the
	 * contact time. An enemy has no chain, so this is how its controller learns of it (#83).
	 */
	FAethelnInterruptedDelegate OnTargetInterrupted;

#if WITH_DEV_AUTOMATION_TESTS
	int32 GetRegisteredStepCountForTests() const { return Steps.Num(); }
	int32 GetSweepCountForTests() const { return SweepCountForTests; }
	void SetNextOrdinalForTests(uint64 Ordinal) { NextOrdinal = Ordinal; }
	int32 GetBoundaryOwnerCountForTests() const { return AbilitySystems.Num(); }
#endif

private:
	struct FStep
	{
		TWeakObjectPtr<UAethelnAbilitySystemComponent> AbilitySystem;
		TWeakObjectPtr<AActor> Avatar;
		FAethelnAttackStepDefinition Definition;
		FAethelnCombatActivationRecord Record;
		uint64 Ordinal = 0;
		double LastSample = 0.0;
		FVector LastOrigin = FVector::ZeroVector;
		double ResetTime = TNumericLimits<double>::Max();
		double MaxSampleDistance = 0.0;
		double MaxSampleAngleDegrees = 0.0;
		/** Allowance record: target combat ids with a result. Never evicted while the step is registered. */
		TArray<uint32> ResultTargets;
	};
	struct FCandidate
	{
		double ContactTime = 0.0;
		uint64 Ordinal = 0;
		uint32 TargetCombatId = 0;
		FGuid ActivationId;
		TWeakObjectPtr<UAethelnAbilitySystemComponent> Target;
		FVector Location = FVector::ZeroVector;
		FVector SourceOrigin = FVector::ZeroVector;
	};
	struct FCommitted
	{
		FAethelnCombatResult Result;
		FAethelnCombatResultCue Cue;
		TWeakObjectPtr<UAethelnAbilitySystemComponent> Target;
	};
	void HandlePostActorTick(UWorld* World, ELevelTick TickType, float DeltaSeconds);
	void Sweep(const FStep& Entry, const FAethelnAttackSampleInterval& Interval, const FVector& NowOrigin, double Now, TArray<FCandidate>& OutCandidates);
	void Resolve(const FCandidate& Candidate, TArray<FCommitted>& OutCommitted);
	/** Ends the target's step and chain at the contact time if the step at that time is still interruptible. */
	void Interrupt(UAethelnAbilitySystemComponent& Target, double ContactTime);
	void Emit(const FCommitted& Committed);
	uint32 GetOrAssignCombatId(UAethelnAbilitySystemComponent& AbilitySystem);
	TArray<FStep> Steps;
	TArray<TWeakObjectPtr<UAethelnAbilitySystemComponent>> AbilitySystems;
	TMap<TWeakObjectPtr<UAethelnAbilitySystemComponent>, uint32> CombatIds;
	TMap<TWeakObjectPtr<UAethelnAbilitySystemComponent>, FAethelnDefenseState> Defenses;
	uint64 NextOrdinal = 1;
	uint32 NextCombatId = 1;
	FDelegateHandle TickHandle;
#if WITH_DEV_AUTOMATION_TESTS
	int32 SweepCountForTests = 0;
#endif
};
