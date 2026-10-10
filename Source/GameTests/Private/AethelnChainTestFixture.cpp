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
		Step.WroughtDamage = 5.0f;
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
	namespace
	{
		UAethelnChainTestAbility* FindChainInstance(const UAethelnAbilitySystemComponent& AbilitySystem, FGameplayAbilitySpecHandle* OutHandle = nullptr)
		{
			for (const FGameplayAbilitySpec& Spec : AbilitySystem.GetActivatableAbilities())
			{
				if (UAethelnChainTestAbility* Instance = Cast<UAethelnChainTestAbility>(Spec.GetPrimaryInstance()))
				{
					if (OutHandle != nullptr) { *OutHandle = Spec.Handle; }
					return Instance;
				}
			}
			return nullptr;
		}
	}

	FAethelnCombatActivationRequest MakeChainRequest(const UAethelnAbilitySystemComponent& AbilitySystem, uint32 Sequence)
	{
		FAethelnCombatActivationRequest Result;
		Result.AbilityId = AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain;
		Result.ContentVersion = 1;
		Result.Sequence = Sequence;
		AethelnCombatTests::FillTestAimAndTime(Result, AbilitySystem);
		return Result;
	}

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
		Ability = FindChainInstance(*Player.AbilitySystem, &Handle);
		Timeline = World.World->GetSubsystem<UAethelnCombatTimelineSubsystem>();
		if (!Test.TestNotNull(TEXT("Granted chain primary instance exists"), Ability)
			|| !Test.TestNotNull(TEXT("Authority world owns its timeline subsystem"), Timeline)) { return false; }
		RecordHandle = Player.AbilitySystem->OnCombatActivation.AddLambda([this](const FAethelnCombatActivationRecord& Record) { Records.Add(Record); });
		EndHandle = Player.AbilitySystem->OnChainEnded.AddLambda([this](const FGuid& Id, EAethelnChainEndReason Reason) { Ends.Add({ Id, Reason }); });
		WindowHandle = Timeline->OnWindowEvaluated.AddLambda([this](const FAethelnCombatActivationRecord&, const FAethelnAttackSampleInterval& Interval) { Intervals.Add(Interval); });
		ResultHandle = Timeline->OnResultCommitted.AddLambda([this](const FAethelnCombatResult& Result) { Results.Add(Result); });
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
		if (Timeline != nullptr)
		{
			Timeline->OnWindowEvaluated.Remove(WindowHandle);
			Timeline->OnResultCommitted.Remove(ResultHandle);
		}
	}

	FAethelnCombatActivationRequest FFixture::Request(uint32 Sequence) const
	{
		return MakeChainRequest(*Player.AbilitySystem, Sequence == 0 ? NextSequence : Sequence);
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

	AAethelnCombatAICharacter* FFixture::SpawnTarget(FAutomationTestBase& Test, const FVector& Location) const
	{
		AAethelnCombatAICharacter* Target = World.Spawn<AAethelnCombatAICharacter>();
		if (!Test.TestNotNull(TEXT("Target dummy exists"), Target)) { return nullptr; }
		Target->SetActorLocation(Location);
		Target->GetCharacterMovement()->DisableMovement();
		// BeginPlay applied the unset production values; override them with test-only values.
		UAethelnAttributeInitEffect::ApplyTo(*Target->GetAethelnAbilitySystemComponent(), AethelnCombatTests::MakeTestInitValues());
		return Target;
	}

	bool FFixture::SpawnAttacker(FAutomationTestBase& Test, FAttacker& Out, const FVector& Location, double Yaw) const
	{
		if (!AethelnCombatTests::SpawnTestPlayer(Test, World, Out.Player, { UAethelnChainTestAbility::StaticClass() })) { return false; }
		Out.Pawn = World.Spawn<AAethelnPlayerCharacter>();
		if (!Test.TestNotNull(TEXT("Second attacker pawn exists"), Out.Pawn)) { return false; }
		Out.Pawn->SetActorLocationAndRotation(Location, FRotator(0.0, Yaw, 0.0));
		Out.Player.Controller->Possess(Out.Pawn);
		Out.Pawn->GetCharacterMovement()->DisableMovement();
		Out.Player.Controller->SetControlRotation(FRotator(0.0, Yaw, 0.0));
		Out.Player.AbilitySystem->ProvisionalAimMaxRateDegreesPerSecond = 1000.0f;
		Out.Ability = FindChainInstance(*Out.Player.AbilitySystem);
		return Test.TestNotNull(TEXT("Second attacker chain instance exists"), Out.Ability);
	}
}
#endif
