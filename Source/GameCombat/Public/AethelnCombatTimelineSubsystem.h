#pragma once

#include "AethelnAttackTypes.h"
#include "Subsystems/WorldSubsystem.h"
#include "AethelnCombatTimelineSubsystem.generated.h"

class UAethelnAbilitySystemComponent;

DECLARE_MULTICAST_DELEGATE_TwoParams(FAethelnAttackWindowDelegate, const FAethelnCombatActivationRecord&, const FAethelnAttackSampleInterval&);

/** One own-world server pass after actor tick. P3 exposes intervals, never queries/damages. */
UCLASS()
class GAMECOMBAT_API UAethelnCombatTimelineSubsystem : public UWorldSubsystem
{
	GENERATED_BODY()

public:
	virtual void Initialize(FSubsystemCollectionBase& Collection) override;
	virtual void Deinitialize() override;
	virtual bool ShouldCreateSubsystem(UObject* Outer) const override;

	bool RegisterStep(UAethelnAbilitySystemComponent& AbilitySystem, const FAethelnAttackStepDefinition& Step, FAethelnCombatActivationRecord& Record);
	bool CanRegisterStep(const UAethelnAbilitySystemComponent& AbilitySystem) const;
	/**
	 * Non-chain boundary registration (#18 P3): the ASC's own timelines, such as the dodge
	 * windows, get their due boundaries applied in pass step 4 until none remain pending.
	 */
	bool RegisterNonChainBoundaries(UAethelnAbilitySystemComponent& AbilitySystem);
	void StampReset(const FGuid& ActivationId, double Time);
	FAethelnAttackWindowDelegate OnWindowEvaluated;

#if WITH_DEV_AUTOMATION_TESTS
	int32 GetRegisteredStepCountForTests() const { return Steps.Num(); }
	int32 GetBoundaryOwnerCountForTests() const { return AbilitySystems.Num(); }
#endif

private:
	struct FStep
	{
		TWeakObjectPtr<UAethelnAbilitySystemComponent> AbilitySystem;
		FAethelnAttackStepDefinition Definition;
		FAethelnCombatActivationRecord Record;
		uint64 Ordinal = 0;
		double LastSample = 0.0;
		double ResetTime = TNumericLimits<double>::Max();
	};
	void HandlePostActorTick(UWorld* World, ELevelTick TickType, float DeltaSeconds);
	TArray<FStep> Steps;
	TArray<TWeakObjectPtr<UAethelnAbilitySystemComponent>> AbilitySystems;
	TMap<TWeakObjectPtr<UAethelnAbilitySystemComponent>, uint32> CombatIds;
	uint64 NextOrdinal = 1;
	uint32 NextCombatId = 1;
	FDelegateHandle TickHandle;
};
