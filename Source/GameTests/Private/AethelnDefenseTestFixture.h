#pragma once

#include "AethelnBlockAbility.h"
#include "AethelnChainTestFixture.h"
#include "AethelnCombatAICharacter.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatEffects.h"
#include "AethelnDodgeTestAbility.h"
#include "AethelnGameplayTags.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "GameFramework/WorldSettings.h"
#include "AethelnDefenseTestFixture.generated.h"

/**
 * A valid block authored only in the Editor test module. Every number is a test fixture chosen for
 * exact binary time arithmetic, never tuning (#107 owns the values).
 */
UCLASS(NotBlueprintable, HideDropdown)
class UAethelnBlockTestAbility : public UAethelnBlockAbility
{
	GENERATED_BODY()

public:
	UAethelnBlockTestAbility()
	{
		ContentVersion = 1;
		ProvisionalEnduranceCost = 1.0f;
		ProvisionalCooldownSeconds = 0.125f;
		ProvisionalRaiseSeconds = 0.0625f;
		ProvisionalArcHalfAngleDegrees = 90.0f;
		ProvisionalGuardBreakSeconds = 0.5f;
	}

	void SetBlockedTagsForTests(const FGameplayTagContainer& Tags) { ActivationBlockedTags = Tags; }
	void SetMovementCarriedForTests(bool bValue) { bMovementCarried = bValue; }
};

#if WITH_DEV_AUTOMATION_TESTS
/*
 * #18 P4 (docs/dodge-and-block.md, Test Plan D13 to D25). A player defender with the fixture block, dodge
 * and chain, and enemy steps registered directly with #60's driver as the attacker (owner decision 3).
 * Geometry, not tuning: the fixture step sweeps a radius-10 sphere 30 units from the enemy's capsule center
 * during [E + 0.125, E + 0.25). An enemy 40 units from the player's radius-42 capsule overlaps it at the
 * window start, so its contact time is exactly E + 0.125.
 */
namespace AethelnDefenseTests
{
	using EResult = EAethelnActivationResult;
	using EOutcome = EAethelnCombatResultOutcome;

	constexpr double ContactOffset = 0.125;

	struct FDefense
	{
		AethelnCombatTests::FScopedCombatTestWorld World{ true };
		AethelnCombatTests::FTestPlayer Player;
		AAethelnPlayerCharacter* Pawn = nullptr;
		UAethelnCombatTimelineSubsystem* Timeline = nullptr;
		uint32 NextSequence = 1;
		float NextTimeStamp = 1.0f;
		int32 PressureApplications = 0;
		int32 CostApplications = 0;
		int32 CooldownApplications = 0;
		TArray<FAethelnCombatResult> Results;
		TArray<EAethelnChainEndReason> ChainEnds;
		FDelegateHandle EffectHandle;
		FDelegateHandle ResultHandle;
		FDelegateHandle ChainEndHandle;

		bool Init(FAutomationTestBase& Test, const TArray<TSubclassOf<UGameplayAbility>>& Abilities = {
			UAethelnBlockTestAbility::StaticClass(), UAethelnDodgeTestAbility::StaticClass(), UAethelnChainTestAbility::StaticClass() })
		{
			if (!AethelnCombatTests::SpawnTestPlayer(Test, World, Player, Abilities)) { return false; }
			Pawn = World.Spawn<AAethelnPlayerCharacter>();
			if (!Test.TestNotNull(TEXT("Defender pawn exists"), Pawn)) { return false; }
			Player.Controller->Possess(Pawn);
			Pawn->GetCharacterMovement()->DisableMovement();
			World.World->GetWorldSettings()->MaxUndilatedFrameTime = 10.0f; // fixture long frames, not a tick budget
			ASC().ProvisionalAimMaxRateDegreesPerSecond = 1000.0f;
			Timeline = World.World->GetSubsystem<UAethelnCombatTimelineSubsystem>();
			if (!Test.TestNotNull(TEXT("Authority world owns its timeline subsystem"), Timeline)) { return false; }
			ResultHandle = Timeline->OnResultCommitted.AddLambda([this](const FAethelnCombatResult& Result) { Results.Add(Result); });
			ChainEndHandle = ASC().OnChainEnded.AddLambda([this](const FGuid&, EAethelnChainEndReason Reason) { ChainEnds.Add(Reason); });
			EffectHandle = ASC().OnGameplayEffectAppliedDelegateToSelf.AddLambda(
				[this](UAbilitySystemComponent*, const FGameplayEffectSpec& Spec, FActiveGameplayEffectHandle)
				{
					PressureApplications += Spec.Def != nullptr && Spec.Def->IsA<UAethelnGuardPressureEffect>() ? 1 : 0;
					CostApplications += Spec.Def != nullptr && Spec.Def->IsA<UAethelnEnduranceCostEffect>() ? 1 : 0;
					CooldownApplications += Spec.Def != nullptr && Spec.Def->IsA<UAethelnCooldownEffect>()
						&& Spec.DynamicGrantedTags.HasTagExact(AethelnGameplayTags::Cooldown_Block) ? 1 : 0;
				});
			return true;
		}

		~FDefense()
		{
			if (Player.AbilitySystem != nullptr)
			{
				Player.AbilitySystem->OnGameplayEffectAppliedDelegateToSelf.Remove(EffectHandle);
				Player.AbilitySystem->OnChainEnded.Remove(ChainEndHandle);
			}
			if (Timeline != nullptr) { Timeline->OnResultCommitted.Remove(ResultHandle); }
		}

		UAethelnAbilitySystemComponent& ASC() const { return *Player.AbilitySystem; }
		double Now() const { return World.World->GetTimeSeconds(); }
		/** Ticks the real world, so the timeline's post-actor pass runs. */
		void AdvanceTo(double Time) { World.World->Tick(LEVELTICK_All, static_cast<float>(Time - Now())); }
		bool Has(const FGameplayTag& Tag) const { return ASC().HasMatchingGameplayTag(Tag); }
		float Attribute(const FGameplayAttribute& Attribute) const { return ASC().GetNumericAttribute(Attribute); }
		float Guard() const { return Attribute(UAethelnCombatAttributeSet::GetGuardAttribute()); }
		float Health() const { return Attribute(UAethelnCombatAttributeSet::GetHealthAttribute()); }
		const FAethelnDefenseState* Slot() const { return Timeline->FindDefenseState(ASC()); }

		/** A seam request built now; Sequence 0 takes the next one. Deliver it now or later. */
		FAethelnCombatActivationRequest Request(const FGameplayTag& AbilityId, EAethelnActivationPhase Phase = EAethelnActivationPhase::Press, uint32 Sequence = 0)
		{
			FAethelnCombatActivationRequest Result;
			Result.AbilityId = AbilityId;
			Result.Phase = Phase;
			Result.ContentVersion = 1;
			Result.Sequence = Sequence != 0 ? Sequence : NextSequence++;
			AethelnCombatTests::FillTestAimAndTime(Result, ASC());
			return Result;
		}

		EResult Deliver(const FAethelnCombatActivationRequest& InRequest) { return ASC().ProcessServerRequest(InRequest); }
		EResult Raise() { return Deliver(Request(AethelnGameplayTags::Ability_Block)); }
		EResult Lower() { return Deliver(Request(AethelnGameplayTags::Ability_Block, EAethelnActivationPhase::Release)); }
		EResult Attack() { return Deliver(Request(AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain)); }

		/** The dodge through the movement-carried entry, as the server's received-move simulation calls it. */
		EResult Dodge()
		{
			FAethelnDodgeStartRequest Move;
			Move.ClientTimeStamp = NextTimeStamp++;
			Move.ContentVersion = 1;
			Move.bMovementAllowsStart = true;
			Move.Avatar = Pawn;
			return ASC().ProcessMovementCarriedRequest(Move);
		}

		void ClearCooldowns()
		{
			FGameplayTagContainer Tags(AethelnGameplayTags::Cooldown_Block);
			Tags.AddTag(AethelnGameplayTags::Cooldown_Dodge);
			ASC().RemoveActiveEffectsWithGrantedTags(Tags);
		}

		/** A headless enemy with the fixture chain granted to its own ASC, standing still at Location. */
		AAethelnCombatAICharacter* SpawnEnemy(FAutomationTestBase& Test, const FVector& Location = FVector(40.0, 0.0, 0.0)) const
		{
			AAethelnCombatAICharacter* Enemy = World.Spawn<AAethelnCombatAICharacter>();
			if (!Test.TestNotNull(TEXT("Enemy exists"), Enemy)) { return nullptr; }
			Enemy->SetActorLocation(Location);
			Enemy->GetCharacterMovement()->DisableMovement();
			UAethelnAttributeInitEffect::ApplyTo(*Enemy->GetAethelnAbilitySystemComponent(), AethelnCombatTests::MakeTestInitValues());
			Enemy->GetAethelnAbilitySystemComponent()->GiveAbility(FGameplayAbilitySpec(UAethelnChainTestAbility::StaticClass(), 1));
			return Enemy;
		}

		/** Registers one enemy step starting now, aimed at the defender. Returns its activation id. */
		FGuid Swing(AAethelnCombatAICharacter& Enemy, float GuardPressure, uint32 Sequence = 1) const
		{
			const UAethelnChainTestAbility* Chain = GetDefault<UAethelnChainTestAbility>();
			FAethelnAttackStepDefinition Step = Chain->ProvisionalSteps[0];
			Step.GuardPressure = GuardPressure;
			FAethelnCombatActivationRecord Record;
			Record.ActivationId = FGuid::NewGuid();
			Record.Sequence = Sequence; // stands in for #20's server sequence, so the result event is kept
			Record.AbilityId = AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain;
			Record.ContentVersion = Chain->ContentVersion;
			Record.ChainStep = 1;
			Record.StartServerTime = Now();
			Record.AcceptedAim = (Pawn->GetActorLocation() - Enemy.GetActorLocation()).GetSafeNormal();
			return Timeline->RegisterStep(*Enemy.GetAethelnAbilitySystemComponent(), Step, Record, Chain->ProvisionalMaxSampleDistance, Chain->ProvisionalMaxSampleAngleDegrees)
				? Record.ActivationId : FGuid();
		}

		const FAethelnCombatResult* ResultFor(const FGuid& ActivationId) const
		{
			return Results.FindByPredicate([&ActivationId](const FAethelnCombatResult& Result) { return Result.ActivationId == ActivationId; });
		}
	};
}
#endif
