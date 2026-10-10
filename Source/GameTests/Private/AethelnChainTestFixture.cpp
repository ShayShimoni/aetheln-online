#include "AethelnChainTestFixture.h"

#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatEffects.h"
#include "AethelnGameplayTags.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "GameFramework/WorldSettings.h"

UAethelnChainTestAbility::UAethelnChainTestAbility()
{
	ContentVersion = 1;
	ProvisionalEnduranceCost = 2.0f;
	ProvisionalMaxSampleDistance = 10.0;
	ProvisionalMaxSampleAngleDegrees = 5.0;
	for (int32 Index = 0; Index < 3; ++Index)
	{
		FAethelnAttackStepDefinition& Step = ProvisionalSteps.AddDefaulted_GetRef();
		Step.ActiveStart = 0.125; Step.ActiveEnd = 0.25;
		Step.BufferOpen = Index == 2 ? 0.625 : 0.375;
		Step.LinkOpen = Index == 2 ? 0.0 : 0.5;
		Step.LinkClose = Index == 2 ? 0.0 : 0.75;
		Step.RecoveryEnd = 0.625; Step.CancelOpen = 0.5;
		Step.MaxAimPitchDegrees = 45.0;
		Step.ShapeExtent = FVector(10.0);
		Step.PathEnd.SetTranslation(FVector(30.0, 0.0, 0.0));
		Step.MaxTargets = 4;
	}
}

UAethelnCommitmentProbeTestAbility::UAethelnCommitmentProbeTestAbility()
{
	ActivationBlockedTags.AddTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain);
}

#if WITH_DEV_AUTOMATION_TESTS
namespace AethelnChainTests
{
	bool FFixture::Init(FAutomationTestBase& Test)
	{
		if (!AethelnCombatTests::SpawnTestPlayer(Test, World, Player, { UAethelnChainTestAbility::StaticClass() })) { return false; }
		Pawn = World.Spawn<AAethelnPlayerCharacter>();
		if (!Test.TestNotNull(TEXT("Chain pawn exists"), Pawn)) { return false; }
		Player.Controller->Possess(Pawn);
		Pawn->GetCharacterMovement()->DisableMovement();
		// Allow deliberate long-frame fixtures; this is not a production tick budget.
		World.World->GetWorldSettings()->MaxUndilatedFrameTime = 10.0f;
		Player.AbilitySystem->ProvisionalAimMaxRateDegreesPerSecond = 1000.0f;
		for (const FGameplayAbilitySpec& Spec : Player.AbilitySystem->GetActivatableAbilities())
		{
			if (UAethelnChainTestAbility* Instance = Cast<UAethelnChainTestAbility>(Spec.GetPrimaryInstance()))
			{
				Handle = Spec.Handle; Ability = Instance;
			}
		}
		Timeline = World.World->GetSubsystem<UAethelnCombatTimelineSubsystem>();
		if (!Test.TestNotNull(TEXT("Granted chain primary instance exists"), Ability)
			|| !Test.TestNotNull(TEXT("Authority world owns its timeline subsystem"), Timeline)) { return false; }
		RecordHandle = Player.AbilitySystem->OnCombatActivation.AddLambda([this](const FAethelnCombatActivationRecord& Record) { Records.Add(Record); });
		EndHandle = Player.AbilitySystem->OnChainEnded.AddLambda([this](const FGuid& Id, EAethelnChainEndReason Reason) { Ends.Add({ Id, Reason }); });
		WindowHandle = Timeline->OnWindowEvaluated.AddLambda([this](const FAethelnCombatActivationRecord&, const FAethelnAttackSampleInterval& Interval) { Intervals.Add(Interval); });
		CostHandle = Player.AbilitySystem->OnGameplayEffectAppliedDelegateToSelf.AddLambda(
			[this](UAbilitySystemComponent*, const FGameplayEffectSpec& Spec, FActiveGameplayEffectHandle)
			{
				if (Spec.Def != nullptr && Spec.Def->IsA<UAethelnEnduranceCostEffect>()) { ++CostApplications; }
			});
		return true;
	}

	FFixture::~FFixture()
	{
		if (Player.AbilitySystem != nullptr)
		{
			Player.AbilitySystem->OnCombatActivation.Remove(RecordHandle);
			Player.AbilitySystem->OnChainEnded.Remove(EndHandle);
			Player.AbilitySystem->OnGameplayEffectAppliedDelegateToSelf.Remove(CostHandle);
		}
		if (Timeline != nullptr) { Timeline->OnWindowEvaluated.Remove(WindowHandle); }
	}

	FAethelnCombatActivationRequest FFixture::Request(uint32 Sequence) const
	{
		FAethelnCombatActivationRequest Result;
		Result.AbilityId = AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain;
		Result.ContentVersion = 1;
		Result.Sequence = Sequence == 0 ? NextSequence : Sequence;
		AethelnCombatTests::FillTestAimAndTime(Result, *Player.AbilitySystem);
		return Result;
	}

	EAethelnActivationResult FFixture::Press()
	{
		return Player.AbilitySystem->ProcessServerRequest(Request(NextSequence++));
	}

	void FFixture::AdvanceTo(double Time)
	{
		const double Delta = Time - World.World->GetTimeSeconds();
		check(Delta >= 0.0);
		// Actual post-actor world delegate drives the subsystem, not a test-only call.
		World.World->Tick(LEVELTICK_All, static_cast<float>(Delta));
	}

	float FFixture::Endurance() const
	{
		return Player.AbilitySystem->GetNumericAttribute(UAethelnCombatAttributeSet::GetEnduranceAttribute());
	}
}
#endif
