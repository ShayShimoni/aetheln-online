#if WITH_DEV_AUTOMATION_TESTS

#include "AbilitySystemBlueprintLibrary.h"
#include "AethelnAbilitySystemComponent.h"
#include "AethelnAttackDefinition.h"
#include "AethelnChainTestFixture.h"
#include "AethelnCombatAICharacter.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnGameplayTags.h"
#include "Animation/AnimMontage.h"
#include "Misc/AutomationTest.h"
#include "Misc/DataValidation.h"

#include <limits>

// #84 P2 (docs/animation-and-combat-content-pipeline.md, Test Plan N1 and N2). Fixture values only;
// no tuning is approved here. The geometry is the #60 contact fixture: the test chain's sphere reaches
// a dummy centered 60 units ahead during the first step's active window.
namespace AethelnAttackContentTests
{
	using namespace AethelnChainTests;

	/** What the server decided at one checkpoint. Activation GUIDs differ per run, so they are compared by count. */
	struct FCheckpoint
	{
		int32 Records = 0;
		int32 Ends = 0;
		int32 Results = 0;
		int32 CostApplications = 0;
		/** Health, Endurance and Guard of the attacker then the target. */
		float Attributes[6] = {};
		bool bChainExists = false;
		uint8 ChainStep = 0;
		FGameplayTagContainer AttackerTags;
		FGameplayTagContainer TargetTags;
		int32 AttackerEffects = 0;
		int32 TargetEffects = 0;
		int32 Intervals = 0;

		bool operator==(const FCheckpoint& Other) const
		{
			for (int32 Index = 0; Index < UE_ARRAY_COUNT(Attributes); ++Index)
			{
				if (Attributes[Index] != Other.Attributes[Index]) { return false; }
			}
			return Records == Other.Records && Ends == Other.Ends && Results == Other.Results
				&& CostApplications == Other.CostApplications && bChainExists == Other.bChainExists && ChainStep == Other.ChainStep
				&& AttackerTags == Other.AttackerTags && TargetTags == Other.TargetTags
				&& AttackerEffects == Other.AttackerEffects && TargetEffects == Other.TargetEffects && Intervals == Other.Intervals;
		}
	};

	bool SameWindows(const FAethelnAttackWindowOffsets& A, const FAethelnAttackWindowOffsets& B)
	{
		return A.ActiveStart == B.ActiveStart && A.ActiveEnd == B.ActiveEnd && A.BufferOpen == B.BufferOpen && A.LinkOpen == B.LinkOpen
			&& A.LinkClose == B.LinkClose && A.RecoveryEnd == B.RecoveryEnd && A.CancelOpen == B.CancelOpen && A.InterruptibleUntil == B.InterruptibleUntil;
	}

	bool SameInterval(const FAethelnAttackSampleInterval& A, const FAethelnAttackSampleInterval& B)
	{
		return A.bValid == B.bValid && A.bIncludesInitialOverlap == B.bIncludesInitialOverlap && A.FromSeconds == B.FromSeconds && A.ToSeconds == B.ToSeconds;
	}

	struct FRun
	{
		TArray<FCheckpoint> Checkpoints;
		TArray<FAethelnCombatResult> Results;
		TArray<FAethelnCombatActivationRecord> Records;
		TArray<FEnd> Ends;
		TArray<FAethelnAttackSampleInterval> Intervals;
		int32 MontagePlays = 0;
	};

	FCheckpoint Sample(const FFixture& F, const AAethelnCombatAICharacter& Target)
	{
		const UAethelnAbilitySystemComponent& Attacker = *F.Player.AbilitySystem;
		const UAethelnAbilitySystemComponent& Victim = *Target.GetAethelnAbilitySystemComponent();
		FCheckpoint C;
		C.Records = F.Records.Num();
		C.Ends = F.Ends.Num();
		C.Results = F.Results.Num();
		C.CostApplications = F.CostApplications;
		const FGameplayAttribute Watched[3] = {
			UAethelnCombatAttributeSet::GetHealthAttribute(), UAethelnCombatAttributeSet::GetEnduranceAttribute(), UAethelnCombatAttributeSet::GetGuardAttribute() };
		for (int32 Index = 0; Index < 3; ++Index)
		{
			C.Attributes[Index] = Attacker.GetNumericAttribute(Watched[Index]);
			C.Attributes[3 + Index] = Victim.GetNumericAttribute(Watched[Index]);
		}
		C.bChainExists = Attacker.GetChainStateForTests().bExists;
		C.ChainStep = Attacker.GetChainStateForTests().Step;
		Attacker.GetOwnedGameplayTags(C.AttackerTags);
		Victim.GetOwnedGameplayTags(C.TargetTags);
		C.Intervals = F.Intervals.Num();
		C.AttackerEffects = Attacker.GetActiveEffects(FGameplayEffectQuery()).Num();
		C.TargetEffects = Victim.GetActiveEffects(FGameplayEffectQuery()).Num();
		return C;
	}

	/**
	 * Everything an animation, notify or effect could send to the server: gameplay events with the chain's own
	 * ability, commitment and damage tags and the test trigger (the route an anim notify uses), a gameplay cue
	 * execution, and montage play and stop requests. The pawn has no mesh, so PlayMontage cannot play; that row is
	 * weak evidence and is reported, and the event rows are the proof.
	 */
	void SendPresentationEvents(FFixture& F, AAethelnCombatAICharacter& Target, FRun& Run)
	{
		UAethelnAbilitySystemComponent& Attacker = *F.Player.AbilitySystem;
		const FGameplayTag Tags[] = {
			AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain,
			AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain,
			AethelnGameplayTags::Damage_Wrought,
			AethelnCombatTestTags::Test_Trigger
		};
		for (const FGameplayTag& Tag : Tags)
		{
			FGameplayEventData Payload;
			Payload.EventTag = Tag;
			Payload.Instigator = F.Pawn;
			Payload.Target = &Target;
			Payload.EventMagnitude = 1000.0f;
			UAbilitySystemBlueprintLibrary::SendGameplayEventToActor(F.Player.PlayerState, Tag, Payload);
			UAbilitySystemBlueprintLibrary::SendGameplayEventToActor(&Target, Tag, Payload);
			Attacker.HandleGameplayEvent(Tag, &Payload);
			Attacker.ExecuteGameplayCue(Tag, FGameplayEffectContextHandle());
		}
		UAnimMontage* Montage = NewObject<UAnimMontage>(GetTransientPackage());
		if (Attacker.PlayMontage(F.Ability, F.Ability->GetCurrentActivationInfo(), Montage, 1.0f) > 0.0f) { ++Run.MontagePlays; }
		Attacker.CurrentMontageStop();
	}

	/** Press, sample wind-up, active, recovery and a link press, with or without presentation events at each sample. */
	bool RunChain(FAutomationTestBase& Test, bool bSendEvents, FRun& Out)
	{
		FFixture F; if (!F.Init(Test)) { return false; }
		AAethelnCombatAICharacter* Target = F.SpawnTarget(Test, FVector(60.0, 0.0, 0.0));
		if (Target == nullptr) { return false; }
		Test.TestEqual(TEXT("Step 1 accepted"), F.Press(), EAethelnActivationResult::Accepted);
		// 0.0625 wind-up, 0.1875 active, 0.3125 recovery, 0.4375 buffer; 0.5 link press; 1.5 after the chain ends.
		for (double Time : { 0.0625, 0.1875, 0.3125, 0.4375 })
		{
			F.AdvanceTo(Time);
			if (bSendEvents) { SendPresentationEvents(F, *Target, Out); }
			Out.Checkpoints.Add(Sample(F, *Target));
		}
		F.AdvanceTo(0.5);
		Test.TestEqual(TEXT("Link press accepted"), F.Press(), EAethelnActivationResult::Accepted);
		for (double Time : { 0.5625, 0.6875, 0.8125 })
		{
			F.AdvanceTo(Time);
			if (bSendEvents) { SendPresentationEvents(F, *Target, Out); }
			Out.Checkpoints.Add(Sample(F, *Target));
		}
		F.AdvanceTo(1.5);
		Out.Checkpoints.Add(Sample(F, *Target));
		Out.Results = F.Results;
		Out.Records = F.Records;
		Out.Ends = F.Ends;
		Out.Intervals = F.Intervals;
		return true;
	}

	UAethelnAttackDefinition* MakeValidDefinition()
	{
		UAethelnAttackDefinition* Definition = NewObject<UAethelnAttackDefinition>(GetTransientPackage());
		Definition->StableContentId = TEXT("test.attack.definition");
		Definition->ContentVersion = 1;
		Definition->Audience = EAethelnContentAudience::Shared;
		Definition->AbilityId = AethelnCombatTestTags::Ability_Test_Probe;
		Definition->Steps = GetDefault<UAethelnChainTestAbility>()->ProvisionalSteps;
		Definition->MaxSampleDistance = 10.0;
		Definition->MaxSampleAngleDegrees = 5.0;
		return Definition;
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnPresentationEventsGrantNothingTest,
	"Aetheln.GameCombat.AttackTimeline.PresentationEventsGrantNothing",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPresentationEventsGrantNothingTest::RunTest(const FString& Parameters)
{
	using namespace AethelnAttackContentTests;
	FRun Reference;
	FRun WithEvents;
	if (!RunChain(*this, false, Reference) || !RunChain(*this, true, WithEvents)) { return false; }

	TestTrue(TEXT("Control: the reference run hits the target"), Reference.Results.Num() > 0);
	TestEqual(TEXT("Control: the mesh-less pawn cannot play a montage, so the montage rows prove only that requests are harmless"), WithEvents.MontagePlays, 0);
	if (TestEqual(TEXT("Same checkpoints"), WithEvents.Checkpoints.Num(), Reference.Checkpoints.Num()))
	{
		for (int32 Index = 0; Index < Reference.Checkpoints.Num(); ++Index)
		{
			TestTrue(*FString::Printf(TEXT("Checkpoint %d: no Health, Endurance or Guard change on either side, no tag, effect, record, result, end, cost, evaluated-window count or chain change"), Index),
				WithEvents.Checkpoints[Index] == Reference.Checkpoints[Index]);
		}
	}
	if (TestEqual(TEXT("Same results"), WithEvents.Results.Num(), Reference.Results.Num()))
	{
		for (int32 Index = 0; Index < Reference.Results.Num(); ++Index)
		{
			TestEqual(TEXT("Same contact time"), WithEvents.Results[Index].ContactTime, Reference.Results[Index].ContactTime);
			TestEqual(TEXT("Same outcome"), WithEvents.Results[Index].Outcome, Reference.Results[Index].Outcome);
			TestEqual(TEXT("Same lethal flag"), WithEvents.Results[Index].bLethal, Reference.Results[Index].bLethal);
		}
	}
	if (TestEqual(TEXT("Same records"), WithEvents.Records.Num(), Reference.Records.Num()))
	{
		for (int32 Index = 0; Index < Reference.Records.Num(); ++Index)
		{
			TestEqual(TEXT("Same step"), WithEvents.Records[Index].ChainStep, Reference.Records[Index].ChainStep);
			TestEqual(TEXT("Same start"), WithEvents.Records[Index].StartServerTime, Reference.Records[Index].StartServerTime);
			TestTrue(TEXT("Same windows"), SameWindows(WithEvents.Records[Index].Windows, Reference.Records[Index].Windows));
		}
	}
	if (TestEqual(TEXT("Same evaluated windows"), WithEvents.Intervals.Num(), Reference.Intervals.Num()))
	{
		for (int32 Index = 0; Index < Reference.Intervals.Num(); ++Index)
		{
			TestTrue(TEXT("Same evaluated window"), SameInterval(WithEvents.Intervals[Index], Reference.Intervals[Index]));
		}
	}
	if (TestEqual(TEXT("Same chain ends"), WithEvents.Ends.Num(), Reference.Ends.Num()))
	{
		for (int32 Index = 0; Index < Reference.Ends.Num(); ++Index)
		{
			TestEqual(TEXT("Same end reason"), WithEvents.Ends[Index].Reason, Reference.Ends[Index].Reason);
		}
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAttackDefinitionValidationTest,
	"Aetheln.GameCombat.AttackContent.DefinitionValidation",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAttackDefinitionValidationTest::RunTest(const FString& Parameters)
{
	using namespace AethelnAttackContentTests;
	UAethelnAttackDefinition* Definition = MakeValidDefinition();
	TestNull(TEXT("A fixture-only valid definition passes"), Definition->FindProblem());
	{
		FDataValidationContext Context;
		TestTrue(TEXT("Editor validation passes it"), Definition->IsDataValid(Context) == EDataValidationResult::Valid);
		TestEqual(TEXT("With no error"), static_cast<int32>(Context.GetNumErrors()), 0);
	}
	Definition = MakeValidDefinition();
	Definition->Steps.SetNum(1);
	Definition->Steps[0].BufferOpen = Definition->Steps[0].RecoveryEnd;
	Definition->Steps[0].LinkOpen = 0.0;
	Definition->Steps[0].LinkClose = 0.0;
	TestNull(TEXT("A single-step attack (an enemy step) is valid"), Definition->FindProblem());

	struct FMutation
	{
		const TCHAR* Name;
		TFunction<void(UAethelnAttackDefinition&)> Apply;
	};
	const TArray<FMutation> Mutations = {
		{ TEXT("No stable ID"), [](UAethelnAttackDefinition& D) { D.StableContentId = NAME_None; } },
		{ TEXT("Content version 0"), [](UAethelnAttackDefinition& D) { D.ContentVersion = 0; } },
		{ TEXT("ServerOnly audience"), [](UAethelnAttackDefinition& D) { D.Audience = EAethelnContentAudience::ServerOnly; } },
		{ TEXT("ClientOnly audience"), [](UAethelnAttackDefinition& D) { D.Audience = EAethelnContentAudience::ClientOnly; } },
		{ TEXT("No ability ID"), [](UAethelnAttackDefinition& D) { D.AbilityId = FGameplayTag(); } },
		{ TEXT("A state tag as ability ID"), [](UAethelnAttackDefinition& D) { D.AbilityId = AethelnGameplayTags::State_Dead; } },
		{ TEXT("The bare Ability root"), [](UAethelnAttackDefinition& D) { D.AbilityId = FGameplayTag::RequestGameplayTag(TEXT("Ability"), false); } },
		{ TEXT("Negative cost"), [](UAethelnAttackDefinition& D) { D.EnduranceCost = -1.0f; } },
		{ TEXT("Non-finite cost"), [](UAethelnAttackDefinition& D) { D.EnduranceCost = std::numeric_limits<float>::quiet_NaN(); } },
		{ TEXT("No steps"), [](UAethelnAttackDefinition& D) { D.Steps.Reset(); } },
		{ TEXT("Unset sampling distance"), [](UAethelnAttackDefinition& D) { D.MaxSampleDistance = 0.0; } },
		{ TEXT("Non-finite sampling angle"), [](UAethelnAttackDefinition& D) { D.MaxSampleAngleDegrees = std::numeric_limits<double>::infinity(); } },
		{ TEXT("Empty active window"), [](UAethelnAttackDefinition& D) { D.Steps[0].ActiveStart = D.Steps[0].ActiveEnd; } },
		{ TEXT("Commitment before ActiveEnd"), [](UAethelnAttackDefinition& D) { D.Steps[0].CancelOpen = 0.125; } },
		{ TEXT("Link closes before recovery ends"), [](UAethelnAttackDefinition& D) { D.Steps[0].RecoveryEnd = 0.8125; } },
		{ TEXT("Final step with a link window"), [](UAethelnAttackDefinition& D) { D.Steps.Last().LinkOpen = 0.5; } },
		{ TEXT("Negative offset"), [](UAethelnAttackDefinition& D) { D.Steps[1].ActiveStart = -1.0; } },
		{ TEXT("Zero extent"), [](UAethelnAttackDefinition& D) { D.Steps[0].ShapeExtent = FVector::ZeroVector; } },
		{ TEXT("Capsule shorter than its radius"), [](UAethelnAttackDefinition& D) { D.Steps[0].Shape = EAethelnAttackShape::Capsule; D.Steps[0].ShapeExtent = FVector(10.0, 10.0, 5.0); } },
		{ TEXT("NaN extent"), [](UAethelnAttackDefinition& D) { D.Steps[0].ShapeExtent.X = std::numeric_limits<double>::quiet_NaN(); } },
		{ TEXT("Negative damage"), [](UAethelnAttackDefinition& D) { D.Steps[0].WroughtDamage = -1.0f; } },
		{ TEXT("No target bound"), [](UAethelnAttackDefinition& D) { D.Steps[0].MaxTargets = 0; } },
		{ TEXT("Pitch clamp above 90"), [](UAethelnAttackDefinition& D) { D.Steps[0].MaxAimPitchDegrees = 91.0; } },
		{ TEXT("Interruptible beyond recovery"), [](UAethelnAttackDefinition& D) { D.Steps[0].InterruptibleUntil = 0.6875; } }
	};
	for (const FMutation& Mutation : Mutations)
	{
		Definition = MakeValidDefinition();
		Mutation.Apply(*Definition);
		TestNotNull(*FString::Printf(TEXT("%s is refused"), Mutation.Name), Definition->FindProblem());
		FDataValidationContext Context;
		TestTrue(*FString::Printf(TEXT("%s fails editor validation"), Mutation.Name), Definition->IsDataValid(Context) == EDataValidationResult::Invalid);
		TestTrue(*FString::Printf(TEXT("%s reports an error"), Mutation.Name), Context.GetNumErrors() > 0);
	}
	return true;
}

#endif
