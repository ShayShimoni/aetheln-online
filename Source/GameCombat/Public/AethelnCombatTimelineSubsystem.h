#pragma once

#include "AethelnAttackTypes.h"
#include "Subsystems/WorldSubsystem.h"
#include "AethelnCombatTimelineSubsystem.generated.h"

class UAethelnAbilitySystemComponent;

DECLARE_MULTICAST_DELEGATE_TwoParams(FAethelnAttackWindowDelegate, const FAethelnCombatActivationRecord&, const FAethelnAttackSampleInterval&);
DECLARE_MULTICAST_DELEGATE_OneParam(FAethelnCombatResultDelegate, const FAethelnCombatResult&);
DECLARE_MULTICAST_DELEGATE_TwoParams(FAethelnLethalResultDelegate, UAethelnAbilitySystemComponent* /* TargetAsc */, const FGuid& /* ActivationId */);

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
	void StampReset(const FGuid& ActivationId, double Time);

	/** The one relation rule (OQ1): players are allies, only enemies are hostile, never self. Faction policy replaces it later. */
	static bool IsHostile(const UAethelnAbilitySystemComponent& Attacker, const UAethelnAbilitySystemComponent& Target);

	/** Server only. The defense owner (#18) exposes or clears a target's active defense state. */
	void SetDefenseState(UAethelnAbilitySystemComponent& Target, const FAethelnDefenseState& State);
	void ClearDefenseState(UAethelnAbilitySystemComponent& Target);

	/** Authored avoidance set: a target holding any of these tags yields Avoided. Empty until #18 adds its tag. */
	UPROPERTY(Config)
	FGameplayTagContainer AvoidanceTags;

	FAethelnAttackWindowDelegate OnWindowEvaluated;
	/** Every committed result, in resolution order, for audit. */
	FAethelnCombatResultDelegate OnResultCommitted;
	/** Raised once per target from its lethal committed result; #21 binds it and applies State.Dead. */
	FAethelnLethalResultDelegate OnLethalResult;

#if WITH_DEV_AUTOMATION_TESTS
	int32 GetRegisteredStepCountForTests() const { return Steps.Num(); }
	int32 GetSweepCountForTests() const { return SweepCountForTests; }
	void SetNextOrdinalForTests(uint64 Ordinal) { NextOrdinal = Ordinal; }
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
