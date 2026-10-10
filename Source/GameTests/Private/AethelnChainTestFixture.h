#pragma once

#include "AethelnBasicChainAbility.h"
#include "AethelnCombatAICharacter.h"
#include "AethelnCombatTestWorld.h"
#include "AethelnCombatTimelineSubsystem.h"
#include "AethelnPlayerCharacter.h"
#include "AethelnChainTestFixture.generated.h"

/** A valid definition authored only in the Editor test module, never production tuning. */
UCLASS(NotBlueprintable, HideDropdown)
class UAethelnChainTestAbility : public UAethelnBasicChainAbility
{
	GENERATED_BODY()

public:
	UAethelnChainTestAbility();
	void SetBlockedTagsForTests(const FGameplayTagContainer& Tags) { ActivationBlockedTags = Tags; }
	bool bFailCommitForTests = false;
	FGuid GetOperationIdForTests() const { return GetActivationOperationId(); }
	virtual bool CommitCheck(FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo, FGameplayAbilityActivationInfo ActivationInfo, FGameplayTagContainer* OptionalRelevantTags = nullptr) override
	{
		return !bFailCommitForTests && Super::CommitCheck(Handle, ActorInfo, ActivationInfo, OptionalRelevantTags);
	}
};

UCLASS(NotBlueprintable, HideDropdown)
class UAethelnCommitmentProbeTestAbility : public UAethelnSeamProbeTestAbility
{
	GENERATED_BODY()
public:
	UAethelnCommitmentProbeTestAbility();
};

#if WITH_DEV_AUTOMATION_TESTS
namespace AethelnChainTests
{
	struct FEnd
	{
		FGuid ActivationId;
		EAethelnChainEndReason Reason = EAethelnChainEndReason::None;
	};

	/** A chain request for any player ASC, with the controller's aim and the world time. */
	FAethelnCombatActivationRequest MakeChainRequest(const UAethelnAbilitySystemComponent& AbilitySystem, uint32 Sequence);

	/** Another attacker in the fixture's world, for ordering tests. */
	struct FAttacker
	{
		AethelnCombatTests::FTestPlayer Player;
		AAethelnPlayerCharacter* Pawn = nullptr;
		UAethelnChainTestAbility* Ability = nullptr;
		uint32 NextSequence = 1;
		EAethelnActivationResult Press() { return Player.AbilitySystem->ProcessServerRequest(MakeChainRequest(*Player.AbilitySystem, NextSequence++)); }
	};

	/** Real authority world, possession, grant, seam, GAS effects and world-delegate driver. */
	struct FFixture
	{
		explicit FFixture(bool bWithGameInstance = false) : World(bWithGameInstance) {}
		AethelnCombatTests::FScopedCombatTestWorld World;
		AethelnCombatTests::FTestPlayer Player;
		AAethelnPlayerCharacter* Pawn = nullptr;
		UAethelnChainTestAbility* Ability = nullptr;
		UAethelnCombatTimelineSubsystem* Timeline = nullptr;
		FGameplayAbilitySpecHandle Handle;
		TArray<FAethelnCombatActivationRecord> Records;
		TArray<FEnd> Ends;
		TArray<FAethelnAttackSampleInterval> Intervals;
		TArray<FAethelnCombatResult> Results;
		uint32 NextSequence = 1;
		int32 CostApplications = 0;
		FDelegateHandle RecordHandle;
		FDelegateHandle EndHandle;
		FDelegateHandle WindowHandle;
		FDelegateHandle ResultHandle;
		FDelegateHandle CostHandle;

		bool Init(FAutomationTestBase& Test);
		~FFixture();
		FAethelnCombatActivationRequest Request(uint32 Sequence = 0) const;
		EAethelnActivationResult Press();
		void AdvanceTo(double Time);
		float Endurance() const;
		/** A headless enemy dummy with test attribute values, standing still at Location. */
		AAethelnCombatAICharacter* SpawnTarget(FAutomationTestBase& Test, const FVector& Location) const;
		/** A second player with the chain, possessing a still pawn at Location, aiming along Yaw. */
		bool SpawnAttacker(FAutomationTestBase& Test, FAttacker& Out, const FVector& Location, double Yaw) const;
	};
}
#endif
