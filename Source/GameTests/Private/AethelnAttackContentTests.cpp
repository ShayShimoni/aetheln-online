#if WITH_DEV_AUTOMATION_TESTS

#include "AbilitySystemBlueprintLibrary.h"
#include "AethelnAbilitySystemComponent.h"
#include "AethelnAttackDefinition.h"
#include "AethelnAttackPresentation.h"
#include "AethelnChainTestFixture.h"
#include "AethelnCombatAICharacter.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnContentValidationScanner.h"
#include "AethelnGameplayTags.h"
#include "Animation/AnimComposite.h"
#include "Animation/AnimMontage.h"
#include "Animation/AnimNotifies/AnimNotifyState_DisableRootMotion.h"
#include "Animation/AnimNotifies/AnimNotifyState_Trail.h"
#include "Animation/AnimNotifies/AnimNotify_PlaySound.h"
#include "Animation/AnimNotifies/AnimNotify_ResetDynamics.h"
#include "Animation/AnimSequence.h"
#include "Animation/Skeleton.h"
#include "AnimNotify_PlayNiagaraEffect.h"
#include "AssetRegistry/AssetData.h"
#include "Dom/JsonObject.h"
#include "Engine/SkeletalMeshSocket.h"
#include "Misc/AutomationTest.h"
#include "Misc/DataValidation.h"
#include "Misc/FileHelper.h"
#include "Misc/Guid.h"
#include "Misc/Paths.h"
#include "Serialization/JsonSerializer.h"
#include "UObject/Package.h"

#include <limits>

// #84 P2, P3 and P3b (docs/animation-and-combat-content-pipeline.md, Test Plan N1 to N4 and N6). Fixture values only;
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

namespace AethelnAttackContentTests
{
	/** A valid binding over a valid definition, all transient. */
	struct FBindingFixture
	{
		UAethelnAttackDefinition* Definition = nullptr;
		USkeleton* Skeleton = nullptr;
		UAnimMontage* Montage = nullptr;
		UAethelnAttackPresentation* Binding = nullptr;

		static UAnimMontage* MakeMontage(USkeleton* Skeleton)
		{
			UAnimMontage* Result = NewObject<UAnimMontage>(GetTransientPackage());
			Result->SetSkeleton(Skeleton);
			for (const TCHAR* Name : { TEXT("WindUp"), TEXT("Active"), TEXT("Recovery") })
			{
				Result->CompositeSections.AddDefaulted_GetRef().SectionName = Name;
			}
			Result->Notifies.AddDefaulted_GetRef().Notify = NewObject<UAnimNotify_PlaySound>(Result);
			Result->Notifies.AddDefaulted_GetRef().NotifyStateClass = NewObject<UAnimNotifyState_Trail>(Result);
			return Result;
		}

		FBindingFixture()
		{
			Definition = MakeValidDefinition();
			Skeleton = NewObject<USkeleton>(GetTransientPackage());
			USkeletalMeshSocket* Socket = NewObject<USkeletalMeshSocket>(Skeleton);
			Socket->SocketName = TEXT("weapon_r");
			Skeleton->Sockets.Add(Socket);
			Montage = MakeMontage(Skeleton);
			Binding = NewObject<UAethelnAttackPresentation>(GetTransientPackage());
			Binding->StableContentId = TEXT("test.attack.presentation");
			Binding->ContentVersion = 1;
			Binding->Audience = EAethelnContentAudience::ClientOnly;
			Binding->AbilityId = Definition->AbilityId;
			Binding->Definition = Definition;
			Binding->AuthoredContentVersion = Definition->ContentVersion;
			Binding->Skeleton = Skeleton;
			for (int32 Index = 0; Index < Definition->Steps.Num(); ++Index)
			{
				FAethelnAttackPresentationStep& Step = Binding->Steps.AddDefaulted_GetRef();
				Step.Montage = Montage;
				Step.WindUpSection = TEXT("WindUp");
				Step.ActiveSection = TEXT("Active");
				Step.RecoverySection = TEXT("Recovery");
				Step.Sockets.Add(TEXT("weapon_r"));
			}
		}
	};
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnPresentationBindingValidationTest,
	"Aetheln.GameCombat.AttackContent.PresentationBindingValidation",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPresentationBindingValidationTest::RunTest(const FString& Parameters)
{
	using namespace AethelnAttackContentTests;
	// UAnimationSequencerDataModel::ValidateSequencerData logs this once for each UAnimSequence built below (the sequence
	// mutation and the composite mutation), not for montages; it is not a validator result.
	AddExpectedError(TEXT("No Movie Scene found for SequencerDataModel"), EAutomationExpectedErrorFlags::Contains, 3);
	{
		FBindingFixture Valid;
		TestNull(TEXT("A fixture-only valid binding passes, with allowlisted sound and trail notifies"), Valid.Binding->FindProblem());
		FDataValidationContext Context;
		TestTrue(TEXT("Editor validation passes it"), Valid.Binding->IsDataValid(Context) == EDataValidationResult::Valid);
		TestEqual(TEXT("With no error"), static_cast<int32>(Context.GetNumErrors()), 0);
	}
	{
		// A plain UAnimSequence segment is walked, and passes when every notify on it is allowlisted (PR 348 delta review, L1).
		FBindingFixture Fixture;
		UAnimSequence* Sequence = NewObject<UAnimSequence>(Fixture.Montage);
		Sequence->Notifies.AddDefaulted_GetRef().Notify = NewObject<UAnimNotify_PlaySound>(Sequence);
		Sequence->Notifies.AddDefaulted_GetRef().NotifyStateClass = NewObject<UAnimNotifyState_Trail>(Sequence);
		FAnimSegment Segment;
		Segment.SetAnimReference(Sequence);
		Fixture.Montage->SlotAnimTracks.AddDefaulted_GetRef().AnimTrack.AnimSegments.Add(Segment);
		TestNull(TEXT("A plain sequence segment with allowlisted notifies passes"), Fixture.Binding->FindProblem());
	}
	{
		// The Niagara effect notify is on the allowlist (Residual Risk 5).
		FBindingFixture Fixture;
		Fixture.Montage->Notifies.AddDefaulted_GetRef().Notify = NewObject<UAnimNotify_PlayNiagaraEffect>(Fixture.Montage);
		TestNull(TEXT("A Niagara effect notify passes"), Fixture.Binding->FindProblem());
	}

	struct FMutation
	{
		const TCHAR* Name;
		/** The exact FindProblem() text, so a mutation cannot pass on another check's refusal. */
		const TCHAR* Problem;
		TFunction<void(FBindingFixture&)> Apply;
	};
	const TCHAR* const NotAllowlisted = TEXT("has a montage with a notify that is not an allowlisted presentation class, or with a segment that is not a plain sequence");
	const TCHAR* const NoDefinition = TEXT("names an ability ID that has no matching definition");
	const TCHAR* const NotClientOnly = TEXT("is not ClientOnly");
	const TCHAR* const Stale = TEXT("is stale: its authored content version differs from the definition's");
	const TCHAR* const OtherSkeleton = TEXT("has a montage on another skeleton");
	const TCHAR* const NotAbilityTag = TEXT("lacks a valid Ability. identity tag");
	const TArray<FMutation> Mutations = {
		{ TEXT("No stable ID"), TEXT("has no StableContentId"), [](FBindingFixture& F) { F.Binding->StableContentId = NAME_None; } },
		{ TEXT("Content version 0"), TEXT("has ContentVersion below 1"), [](FBindingFixture& F) { F.Binding->ContentVersion = 0; } },
		{ TEXT("Shared audience"), NotClientOnly, [](FBindingFixture& F) { F.Binding->Audience = EAethelnContentAudience::Shared; } },
		{ TEXT("ServerOnly audience"), NotClientOnly, [](FBindingFixture& F) { F.Binding->Audience = EAethelnContentAudience::ServerOnly; } },
		{ TEXT("Unknown ability ID: no definition"), NoDefinition, [](FBindingFixture& F) { F.Binding->Definition = nullptr; } },
		{ TEXT("Unknown ability ID: another ability's definition"), NoDefinition, [](FBindingFixture& F) { F.Binding->AbilityId = AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain; } },
		{ TEXT("Not an ability tag"), NotAbilityTag, [](FBindingFixture& F) { F.Binding->AbilityId = AethelnGameplayTags::State_Dead; F.Definition->AbilityId = AethelnGameplayTags::State_Dead; } },
		{ TEXT("Stale content version: the definition moved on"), Stale, [](FBindingFixture& F) { F.Definition->ContentVersion = 2; } },
		{ TEXT("Stale content version: the binding is newer"), Stale, [](FBindingFixture& F) { F.Binding->AuthoredContentVersion = 2; } },
		{ TEXT("Unset authored content version"), Stale, [](FBindingFixture& F) { F.Binding->AuthoredContentVersion = 0; } },
		{ TEXT("No skeleton"), TEXT("has no skeleton"), [](FBindingFixture& F) { F.Binding->Skeleton = nullptr; } },
		{ TEXT("Fewer steps than the definition"), TEXT("does not have one presentation step per definition step"), [](FBindingFixture& F) { F.Binding->Steps.SetNum(2); } },
		{ TEXT("More steps than the definition"), TEXT("does not have one presentation step per definition step"), [](FBindingFixture& F) { F.Binding->Steps.AddDefaulted(); } },
		{ TEXT("Missing montage"), TEXT("has a step without a montage"), [](FBindingFixture& F) { F.Binding->Steps[1].Montage = nullptr; } },
		{ TEXT("Montage on another skeleton"), OtherSkeleton, [](FBindingFixture& F) { F.Binding->Steps[2].Montage = FBindingFixture::MakeMontage(NewObject<USkeleton>(GetTransientPackage())); } },
		{ TEXT("Montage with no skeleton"), OtherSkeleton, [](FBindingFixture& F) { F.Binding->Steps[0].Montage = NewObject<UAnimMontage>(GetTransientPackage()); } },
		{ TEXT("Missing wind-up section"), TEXT("names a montage section that does not exist"), [](FBindingFixture& F) { F.Binding->Steps[0].WindUpSection = TEXT("Missing"); } },
		{ TEXT("Missing active section"), TEXT("names a montage section that does not exist"), [](FBindingFixture& F) { F.Binding->Steps[1].ActiveSection = TEXT("Missing"); } },
		{ TEXT("Unset recovery section"), TEXT("names a montage section that does not exist"), [](FBindingFixture& F) { F.Binding->Steps[2].RecoverySection = NAME_None; } },
		{ TEXT("Unknown socket"), TEXT("names a socket the skeleton does not have"), [](FBindingFixture& F) { F.Binding->Steps[0].Sockets.Add(TEXT("no_such_socket")); } },
		{ TEXT("Non-allowlisted notify class"), NotAllowlisted, [](FBindingFixture& F) { F.Montage->Notifies.AddDefaulted_GetRef().Notify = NewObject<UAnimNotify_ResetDynamics>(F.Montage); } },
		{ TEXT("Non-allowlisted notify state class"), NotAllowlisted, [](FBindingFixture& F) { F.Montage->Notifies.AddDefaulted_GetRef().NotifyStateClass = NewObject<UAnimNotifyState_DisableRootMotion>(F.Montage); } },
		{ TEXT("A name-only notify carries no class"), NotAllowlisted, [](FBindingFixture& F) { F.Montage->Notifies.AddDefaulted_GetRef().NotifyName = TEXT("AnyName"); } },
		{ TEXT("Non-allowlisted notify on a sequence the montage plays"), NotAllowlisted, [](FBindingFixture& F)
			{
				UAnimSequence* Sequence = NewObject<UAnimSequence>(F.Montage);
				Sequence->Notifies.AddDefaulted_GetRef().Notify = NewObject<UAnimNotify_ResetDynamics>(Sequence);
				FAnimSegment Segment;
				Segment.SetAnimReference(Sequence);
				F.Montage->SlotAnimTracks.AddDefaulted_GetRef().AnimTrack.AnimSegments.Add(Segment);
			} },
		{ TEXT("Non-allowlisted notify on a sequence inside a composite segment"), NotAllowlisted, [](FBindingFixture& F)
			{
				UAnimSequence* Sequence = NewObject<UAnimSequence>(F.Montage);
				Sequence->Notifies.AddDefaulted_GetRef().Notify = NewObject<UAnimNotify_ResetDynamics>(Sequence);
				FAnimSegment Inner;
				Inner.SetAnimReference(Sequence);
				UAnimComposite* Composite = NewObject<UAnimComposite>(F.Montage);
				Composite->AnimationTrack.AnimSegments.Add(Inner);
				FAnimSegment Outer;
				Outer.SetAnimReference(Composite);
				F.Montage->SlotAnimTracks.AddDefaulted_GetRef().AnimTrack.AnimSegments.Add(Outer);
			} }
	};
	for (const FMutation& Mutation : Mutations)
	{
		FBindingFixture Fixture;
		Mutation.Apply(Fixture);
		const TCHAR* Problem = Fixture.Binding->FindProblem();
		TestEqual(*FString::Printf(TEXT("%s is refused for its own reason"), Mutation.Name), FString(Problem != nullptr ? Problem : TEXT("<accepted>")), FString(Mutation.Problem));
		FDataValidationContext Context;
		TestTrue(*FString::Printf(TEXT("%s fails editor validation"), Mutation.Name), Fixture.Binding->IsDataValid(Context) == EDataValidationResult::Invalid);
		TestTrue(*FString::Printf(TEXT("%s reports an error"), Mutation.Name), Context.GetNumErrors() > 0);
	}
	return true;
}

namespace AethelnAttackContentTests
{
	/**
	 * A binding in its own in-memory package: a public, non-transient asset the Asset Registry enumerates, found
	 * through its class and tags and not through its path. The package is never saved.
	 */
	struct FMountedBinding
	{
		UPackage* Package = nullptr;
		UAethelnAttackPresentation* Binding = nullptr;

		FMountedBinding(const FGameplayTag& AbilityId, int32 AuthoredContentVersion)
		{
			Package = CreatePackage(*FString::Printf(TEXT("/Temp/AethelnAttackContentTests/%s/Bindings"), *FGuid::NewGuid().ToString()));
			Binding = NewObject<UAethelnAttackPresentation>(Package, TEXT("DA_LookupFixture"), RF_Public | RF_Standalone);
			Binding->AbilityId = AbilityId;
			Binding->AuthoredContentVersion = AuthoredContentVersion;
		}

		~FMountedBinding()
		{
			Binding->ClearFlags(RF_Public | RF_Standalone);
			Binding->MarkAsGarbage();
			Package->MarkAsGarbage();
		}

		FSoftObjectPath Path() const { return FSoftObjectPath(Binding); }
	};

	EAethelnPresentationLookup Lookup(const FGameplayTag& AbilityId, int32 AuthoredContentVersion, FAssetData& Out)
	{
		Out = FAssetData();
		return UAethelnAttackPresentation::FindBinding(AbilityId, AuthoredContentVersion, Out);
	}

	/** Whether editor validation of the binding names a duplicate binding. */
	bool ReportsDuplicate(const UAethelnAttackPresentation& Binding)
	{
		FDataValidationContext Context;
		Binding.IsDataValid(Context);
		for (const FDataValidationContext::FIssue& Issue : Context.GetIssues())
		{
			if (Issue.Message.ToString().Contains(TEXT("duplicates the binding"))) { return true; }
		}
		return false;
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnBindingLookupTest,
	"Aetheln.GameCombat.AttackContent.BindingLookup",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnBindingLookupTest::RunTest(const FString& Parameters)
{
	using namespace AethelnAttackContentTests;
	const FGameplayTag Ability = AethelnCombatTestTags::Ability_Test_Probe;
	const FGameplayTag OtherAbility = AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain;
	// Far above any definition version, so no other fixture in the session shares the key.
	const int32 Version = 9001;
	FAssetData Found;
	TestTrue(TEXT("Nothing mounted: not found"), Lookup(Ability, Version, Found) == EAethelnPresentationLookup::NotFound);
	TestTrue(TEXT("An invalid ability ID is not found"), Lookup(FGameplayTag(), Version, Found) == EAethelnPresentationLookup::NotFound);
	TestTrue(TEXT("A content version below 1 is not found"), Lookup(Ability, 0, Found) == EAethelnPresentationLookup::NotFound);
	{
		FMountedBinding First(Ability, Version);
		TestTrue(TEXT("One binding is found by ability ID and version"), Lookup(Ability, Version, Found) == EAethelnPresentationLookup::Found);
		TestTrue(TEXT("It is that binding"), Found.GetSoftObjectPath() == First.Path());
		FString TagValue;
		TestTrue(TEXT("The registry holds the ability ID as a plain tag"), Found.GetTagValue(TEXT("AbilityId"), TagValue));
		TestEqual(TEXT("Its value is the tag name"), TagValue, Ability.ToString());
		TestTrue(TEXT("Another version is not found"), Lookup(Ability, Version + 1, Found) == EAethelnPresentationLookup::NotFound);
		TestTrue(TEXT("Another ability is not found"), Lookup(OtherAbility, Version, Found) == EAethelnPresentationLookup::NotFound);
		TestFalse(TEXT("A unique binding reports no duplicate"), ReportsDuplicate(*First.Binding));

		{
			FMountedBinding NextVersion(Ability, Version + 1);
			TestTrue(TEXT("A binding in another package for another version does not collide"), Lookup(Ability, Version, Found) == EAethelnPresentationLookup::Found);
			TestTrue(TEXT("The first version still resolves to the first binding"), Found.GetSoftObjectPath() == First.Path());
			TestTrue(TEXT("The next version resolves"), Lookup(Ability, Version + 1, Found) == EAethelnPresentationLookup::Found);
			TestTrue(TEXT("To the next binding"), Found.GetSoftObjectPath() == NextVersion.Path());
		}
		{
			FMountedBinding Second(Ability, Version);
			TestTrue(TEXT("Two bindings for the same ability ID and version are ambiguous"), Lookup(Ability, Version, Found) == EAethelnPresentationLookup::Ambiguous);
			TestFalse(TEXT("An ambiguous lookup returns no asset"), Found.IsValid());
			TestTrue(TEXT("Editor validation names the duplicate of the first"), ReportsDuplicate(*First.Binding));
			TestTrue(TEXT("And of the second"), ReportsDuplicate(*Second.Binding));
		}
		TestTrue(TEXT("Once the duplicate is gone the first binding resolves again"), Lookup(Ability, Version, Found) == EAethelnPresentationLookup::Found);
		TestFalse(TEXT("And reports no duplicate"), ReportsDuplicate(*First.Binding));
	}
	TestTrue(TEXT("Once unmounted: not found"), Lookup(Ability, Version, Found) == EAethelnPresentationLookup::NotFound);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnBindingAudienceTest,
	"Aetheln.GameCombat.AttackContent.BindingAudience",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnBindingAudienceTest::RunTest(const FString& Parameters)
{
	using namespace AethelnAttackContentTests;
	// A binding is ClientOnly; the audience of a Shared or ServerOnly binding is itself refused.
	for (const EAethelnContentAudience Audience : { EAethelnContentAudience::Shared, EAethelnContentAudience::ServerOnly })
	{
		FBindingFixture Fixture;
		Fixture.Binding->Audience = Audience;
		const TCHAR* Problem = Fixture.Binding->FindProblem();
		TestEqual(TEXT("A binding that is not ClientOnly is refused"), FString(Problem != nullptr ? Problem : TEXT("<accepted>")), FString(TEXT("is not ClientOnly")));
	}

	// reference_boundary applies the policy's hard-reference matrix through IsHardReferenceAllowed.
	FString PolicyText;
	const FString PolicyPath = FPaths::Combine(FPaths::ProjectConfigDir(), TEXT("ContentValidation/asset-intake-policy.json"));
	if (!TestTrue(TEXT("The intake policy loads"), FFileHelper::LoadFileToString(PolicyText, *PolicyPath))) { return false; }
	TSharedPtr<FJsonObject> Policy;
	if (!TestTrue(TEXT("The intake policy parses"), FJsonSerializer::Deserialize(TJsonReaderFactory<>::Create(PolicyText), Policy) && Policy.IsValid())) { return false; }
	const TSharedPtr<FJsonObject>* References = nullptr;
	const TArray<TSharedPtr<FJsonValue>>* RuleValues = nullptr;
	if (!TestTrue(TEXT("The policy declares hard-reference audience rules"),
		Policy->TryGetObjectField(TEXT("references"), References) && (*References)->TryGetArrayField(TEXT("hard_reference_audience_rules"), RuleValues))) { return false; }
	TMap<FString, TSet<FString>> Rules;
	for (const TSharedPtr<FJsonValue>& RuleValue : *RuleValues)
	{
		const TSharedPtr<FJsonObject> Rule = RuleValue->AsObject();
		TSet<FString>& Allowed = Rules.Add(Rule->GetStringField(TEXT("source")));
		for (const TSharedPtr<FJsonValue>& Target : Rule->GetArrayField(TEXT("may_reference"))) { Allowed.Add(Target->AsString()); }
	}
	using FScanner = FAethelnContentValidationScanner;
	TestFalse(TEXT("A Shared package that hard-references a binding fails reference_boundary"), FScanner::IsHardReferenceAllowed(Rules, TEXT("shared"), TEXT("client_only")));
	TestFalse(TEXT("A ServerOnly package that hard-references a binding fails reference_boundary"), FScanner::IsHardReferenceAllowed(Rules, TEXT("server_only"), TEXT("client_only")));
	TestTrue(TEXT("A binding may hard-reference the Shared definition"), FScanner::IsHardReferenceAllowed(Rules, TEXT("client_only"), TEXT("shared")));
	TestTrue(TEXT("A binding may hard-reference another ClientOnly asset"), FScanner::IsHardReferenceAllowed(Rules, TEXT("client_only"), TEXT("client_only")));
	TestFalse(TEXT("A binding may not hard-reference a ServerOnly asset"), FScanner::IsHardReferenceAllowed(Rules, TEXT("client_only"), TEXT("server_only")));
	TestFalse(TEXT("An unknown source audience fails closed"), FScanner::IsHardReferenceAllowed(Rules, TEXT("unknown"), TEXT("shared")));
	return true;
}

#endif
