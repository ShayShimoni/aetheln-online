#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnAbilitySystemComponent.h"
#include "AethelnChainTestFixture.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatGameMode.h"
#include "AethelnCombatTestWorld.h"
#include "AethelnDefenseTestFixture.h"
#include "AethelnGameplayTags.h"
#include "AethelnPOCInputComponent.h"
#include "AethelnPOCInputTestFixture.h"
#include "AethelnPlayerController.h"
#include "AethelnPlayerState.h"
#include "EnhancedActionKeyMapping.h"
#include "EnhancedInputComponent.h"
#include "EnhancedInputSubsystems.h"
#include "Engine/LocalPlayer.h"
#include "GameFramework/Pawn.h"
#include "InputAction.h"
#include "InputCoreTypes.h"
#include "InputMappingContext.h"
#include "InputModifiers.h"
#include "Misc/AutomationTest.h"
#include "UObject/StrongObjectPtr.h"
#include "UObject/UnrealType.h"

// #82 package 82-B (docs/input-camera-free-aim-spike.md, Request-validation automation to add): the input side of the request path.
// Enhanced Input has no device in the harness, so a press is the engine's own dispatch of the component's bound handler: the test finds
// the FEnhancedInputActionEventBinding of an action and trigger event that UAethelnPOCInputComponent registered and executes it. That is
// the call the engine makes when the mapped key raises the event; the key-to-event step belongs to the engine and is not simulated.
namespace AethelnPOCInputTests
{
	using AethelnCombatTests::FScopedCombatTestWorld;
	using EResult = EAethelnActivationResult;

	/** The component's private UPROPERTY objects, read by reflection so the production class needs no test seam. */
	template <typename T>
	T* ReadObjectProperty(const UObject& Owner, const TCHAR* Name)
	{
		const FObjectProperty* Property = CastField<FObjectProperty>(FindFProperty<FProperty>(Owner.GetClass(), Name));
		return Property != nullptr ? Cast<T>(Property->GetObjectPropertyValue_InContainer(&Owner)) : nullptr;
	}

	TArray<UInputAction*> ReadActiveActions(const UObject& Owner)
	{
		TArray<UInputAction*> Result;
		const FArrayProperty* Array = CastField<FArrayProperty>(FindFProperty<FProperty>(Owner.GetClass(), TEXT("ActiveActions")));
		const FObjectProperty* Inner = Array != nullptr ? CastField<FObjectProperty>(Array->Inner) : nullptr;
		if (Inner == nullptr)
		{
			return Result;
		}
		FScriptArrayHelper Helper(Array, Array->ContainerPtrToValuePtr<void>(&Owner));
		for (int32 Index = 0; Index < Helper.Num(); ++Index)
		{
			Result.Add(Cast<UInputAction>(Inner->GetObjectPropertyValue(Helper.GetElementPtr(Index))));
		}
		return Result;
	}

	const FEnhancedActionKeyMapping* FindMapping(const UInputMappingContext& Context, const TCHAR* ActionName)
	{
		for (const FEnhancedActionKeyMapping& Mapping : Context.GetMappings())
		{
			if (Mapping.Action != nullptr && Mapping.Action->GetFName() == FName(ActionName))
			{
				return &Mapping;
			}
		}
		return nullptr;
	}

	/** Executes every binding the component registered for the action and trigger event. Returns how many ran. */
	int32 Fire(const UEnhancedInputComponent& Component, const TCHAR* ActionName, ETriggerEvent Event)
	{
		int32 Count = 0;
		for (const TUniquePtr<FEnhancedInputActionEventBinding>& Binding : Component.GetActionEventBindings())
		{
			const UInputAction* Action = Binding->GetAction();
			if (Action != nullptr && Action->GetFName() == FName(ActionName) && Binding->GetTriggerEvent() == Event)
			{
				Binding->Execute(FInputActionInstance(Action));
				++Count;
			}
		}
		return Count;
	}

	FString DescribeBindings(const UEnhancedInputComponent& Component)
	{
		TArray<FString> Parts;
		for (const TUniquePtr<FEnhancedInputActionEventBinding>& Binding : Component.GetActionEventBindings())
		{
			const UInputAction* Action = Binding->GetAction();
			Parts.Add(FString::Printf(TEXT("%s:%s"), *GetNameSafe(Action), *StaticEnum<ETriggerEvent>()->GetNameStringByValue(static_cast<int64>(Binding->GetTriggerEvent()))));
		}
		Parts.Sort();
		return FString::Join(Parts, TEXT(", "));
	}

	/** Eight bounds at zero are the production state while their values are TBD (DefaultGame.ini sets none). */
	void UnsetAimTimeBounds(UAethelnAbilitySystemComponent& AbilitySystem)
	{
		AbilitySystem.ProvisionalAimSoftBoundDegrees = 0.0f;
		AbilitySystem.ProvisionalAimHardBoundDegrees = 0.0f;
		AbilitySystem.ProvisionalAimMaxRateDegreesPerSecond = 0.0f;
		AbilitySystem.ProvisionalAimRateSlackDegrees = 0.0f;
		AbilitySystem.ProvisionalAimUnitTolerance = 0.0f;
		AbilitySystem.ProvisionalTimestampMaxAgeSeconds = 0.0f;
		AbilitySystem.ProvisionalTimestampMaxLeadSeconds = 0.0f;
		AbilitySystem.ProvisionalTimestampRegressionToleranceSeconds = 0.0f;
	}

	/**
	 * A real authority world with a possessed pawn, the PlayerState and its seam, and the POC input component registered on the pawn.
	 * The harness has no ULocalPlayer, and the engine counts a controller without a NetDriver as local only with one, so the controller is
	 * marked local (SetAsLocalPlayerController) before the component registers: BindReceiver then binds, and ActivateLocalPlayerResources
	 * stops at its missing local player (no widget, no subsystem). The lifecycle test sets up a real ULocalPlayer instead.
	 */
	struct FInputFixture
	{
		explicit FInputFixture(bool bWithLocalPlayer = false) : bLocalPlayer(bWithLocalPlayer), World(bWithLocalPlayer) {}
		~FInputFixture()
		{
			if (Player.AbilitySystem != nullptr)
			{
				Player.AbilitySystem->OnActivationOutcome.Remove(OutcomeHandle);
				Player.AbilitySystem->OnCombatActivation.Remove(RecordHandle);
			}
			if (IsValid(Input))
			{
				Input->DestroyComponent();
			}
			if (LocalPlayer != nullptr)
			{
				LocalPlayer->PlayerRemoved();
			}
		}

		bool bLocalPlayer = false;
		FScopedCombatTestWorld World;
		AethelnCombatTests::FTestPlayer Player;
		APawn* Pawn = nullptr;
		UAethelnPOCInputComponent* Input = nullptr;
		ULocalPlayer* LocalPlayer = nullptr;
		TArray<EResult> Outcomes;
		TArray<FAethelnCombatActivationRecord> Records;
		FDelegateHandle OutcomeHandle;
		FDelegateHandle RecordHandle;

		/** The pawn takes the chain ability, or Abilities; InputClass is the component class the pawn selects (APawn::OverrideInputComponentClass). */
		bool Init(FAutomationTestBase& Test, UClass* PawnClass, UClass* InputClass, const TArray<TSubclassOf<UGameplayAbility>>& Abilities = { UAethelnChainTestAbility::StaticClass() })
		{
			if (!AethelnCombatTests::SpawnTestPlayer(Test, World, Player, Abilities)
				|| !Test.TestNotNull(TEXT("A pawn class is given"), PawnClass))
			{
				return false;
			}
			FActorSpawnParameters SpawnParameters;
			SpawnParameters.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
			Pawn = World.World->SpawnActor<APawn>(PawnClass, FVector::ZeroVector, FRotator::ZeroRotator, SpawnParameters);
			if (!Test.TestNotNull(TEXT("The pawn spawns"), Pawn))
			{
				return false;
			}
			Player.Controller->Possess(Pawn);
			Test.TestTrue(TEXT("The controller possessed the pawn"), Pawn->GetController() == Player.Controller);
			OutcomeHandle = Player.AbilitySystem->OnActivationOutcome.AddLambda([this](uint32, EResult Result) { Outcomes.Add(Result); });
			RecordHandle = Player.AbilitySystem->OnCombatActivation.AddLambda([this](const FAethelnCombatActivationRecord& Record) { Records.Add(Record); });

			if (bLocalPlayer)
			{
				LocalPlayer = NewObject<ULocalPlayer>(GEngine);
				LocalPlayer->PlayerAdded(nullptr, FPlatformUserId::CreateFromInternalId(0));
				Player.Controller->SetPlayer(LocalPlayer);
			}
			else
			{
				Player.Controller->SetAsLocalPlayerController();
			}
			if (!Test.TestTrue(TEXT("The controller is local"), Player.Controller->IsLocalController())
				|| !Test.TestNotNull(TEXT("The pawn selects an input component class"), InputClass)
				|| !Test.TestTrue(TEXT("The pawn selects the POC input component"), InputClass->IsChildOf(UAethelnPOCInputComponent::StaticClass())))
			{
				return false;
			}
			// What APawn::PawnClientRestart does for a local controller: create the override component and register it.
			Input = NewObject<UAethelnPOCInputComponent>(Pawn, InputClass, TEXT("PawnInputComponent0"));
			Input->RegisterComponent();
			return Test.TestTrue(TEXT("Registration bound the receiver"), Input->GetActionEventBindings().Num() > 0);
		}

		int32 Press(const TCHAR* Action) const { return Fire(*Input, Action, ETriggerEvent::Started); }
		int32 Release(const TCHAR* Action) const { return Fire(*Input, Action, ETriggerEvent::Completed); }
	};
}

// Test Plan: docs/input-camera-free-aim-spike.md, AC1 "Active actions in IMC_POC_Movement". The built context holds exactly the inventoried
// actions, keys, value types, and modifiers, with no trigger object anywhere, so the document cannot drift silently. The four actives have
// no default key (#82 owns the layout): a key maps only when configured.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnPOCMappingInventoryTest,
	"Aetheln.POC.Input.MappingInventory",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPOCMappingInventoryTest::RunTest(const FString& Parameters)
{
	using namespace AethelnPOCInputTests;
	FScopedCombatTestWorld TestWorld;
	AActor* Owner = TestWorld.Spawn<AActor>();
	if (!TestNotNull(TEXT("Owner actor exists"), Owner)) { return false; }

	// A fresh component reads its four active keys from config, so an untracked ini on this machine could map them: pin the default state.
	UAethelnPOCInputComponent* Unkeyed = NewObject<UAethelnPOCInputComponent>(Owner);
	Unkeyed->InstantStrikeKey = FKey();
	Unkeyed->ParryKey = FKey();
	Unkeyed->AttackStanceKey = FKey();
	Unkeyed->DefenseStanceKey = FKey();
	Unkeyed->DodgeKey = EKeys::LeftControl;
	Unkeyed->RegisterComponent();
	const UInputMappingContext* Context = ReadObjectProperty<UInputMappingContext>(*Unkeyed, TEXT("MappingContext"));
	if (!TestNotNull(TEXT("Registration built the mapping context"), Context)) { return false; }
	TestEqual(TEXT("The context is IMC_POC_Movement"), Context->GetName(), FString(TEXT("IMC_POC_Movement")));

	struct FExpected
	{
		const TCHAR* Action;
		FKey Key;
		EInputActionValueType ValueType;
	};
	const FExpected Expected[] = {
		{ TEXT("IA_POC_MoveForward"), EKeys::W, EInputActionValueType::Boolean },
		{ TEXT("IA_POC_MoveBackward"), EKeys::S, EInputActionValueType::Boolean },
		{ TEXT("IA_POC_MoveLeft"), EKeys::A, EInputActionValueType::Boolean },
		{ TEXT("IA_POC_MoveRight"), EKeys::D, EInputActionValueType::Boolean },
		{ TEXT("IA_POC_Look"), EKeys::Mouse2D, EInputActionValueType::Axis2D },
		{ TEXT("IA_POC_Zoom"), EKeys::MouseWheelAxis, EInputActionValueType::Axis1D },
		{ TEXT("IA_POC_ToggleControlMode"), EKeys::LeftAlt, EInputActionValueType::Boolean },
		{ TEXT("IA_POC_ViewportRecapture"), EKeys::LeftMouseButton, EInputActionValueType::Boolean },
		{ TEXT("IA_POC_Jump"), EKeys::SpaceBar, EInputActionValueType::Boolean },
		{ TEXT("IA_POC_Sprint"), EKeys::LeftShift, EInputActionValueType::Boolean },
		{ TEXT("IA_POC_Block"), EKeys::RightMouseButton, EInputActionValueType::Boolean },
		{ TEXT("IA_POC_Dodge"), EKeys::LeftControl, EInputActionValueType::Boolean },
	};
	TestEqual(TEXT("Only the twelve inventoried mappings exist: no ability, gamepad, or touch key"), Context->GetMappings().Num(), static_cast<int32>(UE_ARRAY_COUNT(Expected)));
	for (const FExpected& Case : Expected)
	{
		const FEnhancedActionKeyMapping* Mapping = FindMapping(*Context, Case.Action);
		if (!TestNotNull(*FString::Printf(TEXT("%s is mapped"), Case.Action), Mapping)) { continue; }
		TestTrue(*FString::Printf(TEXT("%s maps %s, not %s"), Case.Action, *Case.Key.ToString(), *Mapping->Key.ToString()), Mapping->Key == Case.Key);
		TestTrue(*FString::Printf(TEXT("%s has its value type"), Case.Action), Mapping->Action->ValueType == Case.ValueType);
		TestEqual(*FString::Printf(TEXT("%s mapping has no trigger object (implicit down trigger)"), Case.Action), Mapping->Triggers.Num(), 0);
		TestEqual(*FString::Printf(TEXT("%s action has no trigger object"), Case.Action), Mapping->Action->Triggers.Num(), 0);
		TestEqual(*FString::Printf(TEXT("%s action has no modifier object"), Case.Action), Mapping->Action->Modifiers.Num(), 0);
		const bool bLook = FString(Case.Action) == TEXT("IA_POC_Look");
		TestEqual(*FString::Printf(TEXT("%s mapping modifiers: only the look Y axis has one"), Case.Action), Mapping->Modifiers.Num(), bLook ? 1 : 0);
	}
	if (const FEnhancedActionKeyMapping* Look = FindMapping(*Context, TEXT("IA_POC_Look")))
	{
		TestTrue(TEXT("Look accumulates"), Look->Action->AccumulationBehavior == EInputActionAccumulationBehavior::Cumulative);
		const UInputModifierNegate* Negate = Look->Modifiers.Num() == 1 ? Cast<UInputModifierNegate>(Look->Modifiers[0].Get()) : nullptr;
		if (TestNotNull(TEXT("The look modifier is a Negate"), Negate))
		{
			TestTrue(TEXT("It negates Y only"), !Negate->bX && Negate->bY && !Negate->bZ);
		}
	}

	// The four actives exist as actions, so their handlers are bound, but none has a key until one is configured.
	const TArray<UInputAction*> Actives = ReadActiveActions(*Unkeyed);
	const TCHAR* const ActiveNames[] = { TEXT("IA_POC_InstantStrike"), TEXT("IA_POC_Parry"), TEXT("IA_POC_AttackStance"), TEXT("IA_POC_DefenseStance") };
	if (TestEqual(TEXT("Four active actions exist"), Actives.Num(), static_cast<int32>(UE_ARRAY_COUNT(ActiveNames))))
	{
		for (int32 Index = 0; Index < Actives.Num(); ++Index)
		{
			if (!TestNotNull(*FString::Printf(TEXT("Active action %d exists"), Index), Actives[Index])) { continue; }
			TestEqual(*FString::Printf(TEXT("Active action %d name"), Index), Actives[Index]->GetName(), FString(ActiveNames[Index]));
			TestTrue(*FString::Printf(TEXT("%s is a Boolean action"), ActiveNames[Index]), Actives[Index]->ValueType == EInputActionValueType::Boolean);
			TestNull(*FString::Printf(TEXT("%s has no default key"), ActiveNames[Index]), FindMapping(*Context, ActiveNames[Index]));
		}
	}

	// A configured key maps its active, and only that one.
	UAethelnPOCInputComponent* Keyed = NewObject<UAethelnPOCInputComponent>(Owner);
	Keyed->InstantStrikeKey = FKey();
	Keyed->ParryKey = EKeys::One;
	Keyed->AttackStanceKey = FKey();
	Keyed->DefenseStanceKey = EKeys::Two;
	Keyed->DodgeKey = EKeys::F;
	Keyed->RegisterComponent();
	const UInputMappingContext* KeyedContext = ReadObjectProperty<UInputMappingContext>(*Keyed, TEXT("MappingContext"));
	if (TestNotNull(TEXT("The keyed component built its context"), KeyedContext))
	{
		TestEqual(TEXT("Two configured keys add two mappings"), KeyedContext->GetMappings().Num(), static_cast<int32>(UE_ARRAY_COUNT(Expected)) + 2);
		const FEnhancedActionKeyMapping* Parry = FindMapping(*KeyedContext, TEXT("IA_POC_Parry"));
		const FEnhancedActionKeyMapping* Defense = FindMapping(*KeyedContext, TEXT("IA_POC_DefenseStance"));
		const FEnhancedActionKeyMapping* Dodge = FindMapping(*KeyedContext, TEXT("IA_POC_Dodge"));
		TestTrue(TEXT("The dodge key is remappable: the configured key maps the one dodge action"), Dodge != nullptr && Dodge->Key == EKeys::F);
		TestTrue(TEXT("The configured Parry key maps Parry"), Parry != nullptr && Parry->Key == EKeys::One);
		TestTrue(TEXT("The configured Defense Stance key maps Defense Stance"), Defense != nullptr && Defense->Key == EKeys::Two);
		TestNull(TEXT("Instant Strike stays unmapped"), FindMapping(*KeyedContext, TEXT("IA_POC_InstantStrike")));
		TestNull(TEXT("Attack Stance stays unmapped"), FindMapping(*KeyedContext, TEXT("IA_POC_AttackStance")));
	}

	// No dodge key maps no dodge action, as for the actives; the block stays on the right mouse button.
	UAethelnPOCInputComponent* NoDodge = NewObject<UAethelnPOCInputComponent>(Owner);
	NoDodge->DodgeKey = FKey();
	NoDodge->RegisterComponent();
	if (const UInputMappingContext* NoDodgeContext = ReadObjectProperty<UInputMappingContext>(*NoDodge, TEXT("MappingContext")))
	{
		TestNull(TEXT("An invalid dodge key maps no dodge action"), FindMapping(*NoDodgeContext, TEXT("IA_POC_Dodge")));
		TestNotNull(TEXT("The block stays mapped"), FindMapping(*NoDodgeContext, TEXT("IA_POC_Block")));
	}
	return true;
}

// Test Plan: docs/input-camera-free-aim-spike.md, AC1 "Cursor-mode gate". Every started handler is inert in Cursor mode and every release
// handler still clears state. The bound handlers run against the real component with a recording receiver, in an authority world with a
// real PlayerState and seam, so "nothing sent" is read from the seam's outcome event, not assumed.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnPOCCursorModeGatesPressesTest,
	"Aetheln.POC.Input.CursorModeGatesPresses",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPOCCursorModeGatesPressesTest::RunTest(const FString& Parameters)
{
	using namespace AethelnPOCInputTests;
	FInputFixture F;
	if (!F.Init(*this, AAethelnPOCInputSpyCharacter::StaticClass(), UAethelnPOCInputComponent::StaticClass())) { return false; }
	AAethelnPOCInputSpyCharacter* Spy = CastChecked<AAethelnPOCInputSpyCharacter>(F.Pawn);
	UAethelnPOCInputComponent& Input = *F.Input;
	const TCHAR* const MoveActions[] = { TEXT("IA_POC_MoveForward"), TEXT("IA_POC_MoveBackward"), TEXT("IA_POC_MoveLeft"), TEXT("IA_POC_MoveRight") };
	const TCHAR* const ActiveActions[] = { TEXT("IA_POC_InstantStrike"), TEXT("IA_POC_Parry"), TEXT("IA_POC_AttackStance"), TEXT("IA_POC_DefenseStance") };

	// The registered bindings are exactly the inventoried (action, trigger event) pairs, so a new binding must come with a test.
	TArray<FString> ExpectedBindings;
	for (const TCHAR* Move : MoveActions)
	{
		ExpectedBindings.Add(FString(Move) + TEXT(":Started"));
		ExpectedBindings.Add(FString(Move) + TEXT(":Completed"));
		ExpectedBindings.Add(FString(Move) + TEXT(":Canceled"));
	}
	for (const TCHAR* Action : { TEXT("IA_POC_Jump"), TEXT("IA_POC_Sprint"), TEXT("IA_POC_ViewportRecapture") })
	{
		ExpectedBindings.Add(FString(Action) + TEXT(":Started"));
		ExpectedBindings.Add(FString(Action) + TEXT(":Completed"));
		ExpectedBindings.Add(FString(Action) + TEXT(":Canceled"));
	}
	for (const TCHAR* Action : ActiveActions) { ExpectedBindings.Add(FString(Action) + TEXT(":Started")); }
	ExpectedBindings.Add(TEXT("IA_POC_Dodge:Started"));
	ExpectedBindings.Add(TEXT("IA_POC_Block:Started"));
	ExpectedBindings.Add(TEXT("IA_POC_Block:Completed"));
	ExpectedBindings.Add(TEXT("IA_POC_Block:Canceled"));
	ExpectedBindings.Add(TEXT("IA_POC_Look:Triggered"));
	ExpectedBindings.Add(TEXT("IA_POC_Zoom:Triggered"));
	ExpectedBindings.Add(TEXT("IA_POC_ToggleControlMode:Started"));
	ExpectedBindings.Sort();
	TestEqual(TEXT("The bound handlers are the inventoried ones"), DescribeBindings(Input), FString::Join(ExpectedBindings, TEXT(", ")));

	// Reticle mode (the default): each started handler acts, so the Cursor-mode silence below is not an unbound handler.
	TestEqual(TEXT("Jump press ran"), F.Press(TEXT("IA_POC_Jump")), 1);
	TestEqual(TEXT("Jump press reached the receiver"), Spy->JumpStartedCount, 1);
	TestEqual(TEXT("Sprint press ran"), F.Press(TEXT("IA_POC_Sprint")), 1);
	TestTrue(TEXT("Sprint intent reached the receiver"), Spy->SprintIntents.Num() == 1 && Spy->SprintIntents[0]);
	TestEqual(TEXT("Zoom ran"), Fire(Input, TEXT("IA_POC_Zoom"), ETriggerEvent::Triggered), 1);
	TestEqual(TEXT("Zoom reached the receiver"), Spy->ZoomInputs.Num(), 1);
	Fire(Input, TEXT("IA_POC_Look"), ETriggerEvent::Triggered);
	TestEqual(TEXT("The first look sample after capture is suppressed"), Spy->LookInputs.Num(), 0);
	Fire(Input, TEXT("IA_POC_Look"), ETriggerEvent::Triggered);
	TestEqual(TEXT("The next look sample reaches the receiver"), Spy->LookInputs.Num(), 1);
	for (const TCHAR* Move : MoveActions)
	{
		TestEqual(*FString::Printf(TEXT("%s press ran"), Move), F.Press(Move), 1);
		TestTrue(*FString::Printf(TEXT("%s press starts the movement tick"), Move), Input.IsComponentTickEnabled());
		TestEqual(*FString::Printf(TEXT("%s release ran"), Move), F.Release(Move), 1);
		TestFalse(*FString::Printf(TEXT("%s release stops the movement tick"), Move), Input.IsComponentTickEnabled());
		F.Press(Move);
		TestEqual(*FString::Printf(TEXT("%s cancel ran"), Move), Fire(Input, Move, ETriggerEvent::Canceled), 1);
		TestFalse(*FString::Printf(TEXT("%s cancel stops the movement tick"), Move), Input.IsComponentTickEnabled());
	}
	for (const TCHAR* Action : ActiveActions) { TestEqual(*FString::Printf(TEXT("%s press ran"), Action), F.Press(Action), 1); }
	TestEqual(TEXT("Each Reticle-mode active press reached the seam"), F.Outcomes.Num(), 4);
	TestEqual(TEXT("The attack press ran"), F.Press(TEXT("IA_POC_ViewportRecapture")), 1);
	TestEqual(TEXT("The attack press reached the seam"), F.Outcomes.Num(), 5);
	F.Release(TEXT("IA_POC_ViewportRecapture"));

	// Left Alt enters Cursor mode, which clears move, sprint, jump, and aim-steering state.
	Spy->ResetRecords();
	TestEqual(TEXT("The Cursor toggle ran"), F.Press(TEXT("IA_POC_ToggleControlMode")), 1);
	TestTrue(TEXT("Cursor entry clears aim steering"), Spy->AimSteeringIntents.Num() == 1 && !Spy->AimSteeringIntents[0]);
	TestTrue(TEXT("Cursor entry clears sprint"), Spy->SprintIntents.Num() == 1 && !Spy->SprintIntents[0]);
	TestEqual(TEXT("Cursor entry cancels a held jump"), Spy->JumpCanceledCount, 1);
	TestFalse(TEXT("Cursor entry stops the movement tick"), Input.IsComponentTickEnabled());

	// Cursor mode: no started handler acts and no press reaches the seam.
	Spy->ResetRecords();
	F.Outcomes.Reset();
	for (const TCHAR* Move : MoveActions)
	{
		TestEqual(*FString::Printf(TEXT("%s press ran in Cursor mode"), Move), F.Press(Move), 1);
		TestFalse(*FString::Printf(TEXT("%s press does not start the movement tick in Cursor mode"), Move), Input.IsComponentTickEnabled());
	}
	F.Press(TEXT("IA_POC_Jump"));
	F.Press(TEXT("IA_POC_Sprint"));
	Fire(Input, TEXT("IA_POC_Zoom"), ETriggerEvent::Triggered);
	Fire(Input, TEXT("IA_POC_Look"), ETriggerEvent::Triggered);
	Fire(Input, TEXT("IA_POC_Look"), ETriggerEvent::Triggered);
	for (const TCHAR* Action : ActiveActions) { F.Press(Action); }
	F.Press(TEXT("IA_POC_Dodge"));
	F.Press(TEXT("IA_POC_Block"));
	TestEqual(TEXT("No started handler reached the receiver in Cursor mode, the dodge press included"), Spy->CallCount(), 0);
	TestEqual(TEXT("No active or block press reached the seam in Cursor mode"), F.Outcomes.Num(), 0);
	TestEqual(TEXT("No new activation started in Cursor mode (the one record is the Reticle-mode attack)"), F.Records.Num(), 1);

	// A release or cancel still clears state, so a key released in Cursor mode is not left held.
	F.Release(TEXT("IA_POC_Jump"));
	TestEqual(TEXT("A jump release passes in Cursor mode"), Spy->JumpStoppedCount, 1);
	Fire(Input, TEXT("IA_POC_Jump"), ETriggerEvent::Canceled);
	TestEqual(TEXT("A jump cancel passes in Cursor mode"), Spy->JumpCanceledCount, 1);
	F.Release(TEXT("IA_POC_Sprint"));
	TestTrue(TEXT("A sprint release clears the intent in Cursor mode"), Spy->SprintIntents.Num() == 1 && !Spy->SprintIntents[0]);
	Fire(Input, TEXT("IA_POC_Sprint"), ETriggerEvent::Canceled);
	TestTrue(TEXT("A sprint cancel clears the intent in Cursor mode"), Spy->SprintIntents.Num() == 2 && !Spy->SprintIntents[1]);
	for (const TCHAR* Move : MoveActions)
	{
		const int32 Before = Spy->MoveInputs.Num();
		F.Release(Move);
		TestTrue(*FString::Printf(TEXT("%s release sends zero move input in Cursor mode"), Move), Spy->MoveInputs.Num() == Before + 1 && Spy->MoveInputs.Last().IsNearlyZero());
		Fire(Input, Move, ETriggerEvent::Canceled);
		TestTrue(*FString::Printf(TEXT("%s cancel sends zero move input in Cursor mode"), Move), Spy->MoveInputs.Num() == Before + 2 && Spy->MoveInputs.Last().IsNearlyZero());
	}
	return true;
}

// #18 P5, Test Plan D26 (docs/dodge-and-block.md). The dodge key and the right mouse button on the real component with a recording
// receiver, in an authority world with a real PlayerState and seam, so "sent" is read from the seam's outcome and the Blocking tag.
// Red-first: with the right mouse handler stubbed to send nothing, "The right mouse press reaches the seam" is the line that flips; with
// the release not sent on Cursor entry, "Cursor entry releases the held block" is. The local gate is the ASC's CanPredictDodge, whose
// commitment-window check reads the owner's ClientCombatActivation record: the record is delivered through the owner's own RPC body, so
// no server-only commitment tag is involved, and "The gate fails during the commitment window" flips if the check is removed.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnPOCDodgeAndBlockBindingsTest,
	"Aetheln.POC.Input.DodgeAndBlockBindings",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPOCDodgeAndBlockBindingsTest::RunTest(const FString& Parameters)
{
	using namespace AethelnPOCInputTests;
	FInputFixture F;
	if (!F.Init(*this, AAethelnPOCInputSpyCharacter::StaticClass(), UAethelnPOCInputComponent::StaticClass(),
		{ UAethelnBlockTestAbility::StaticClass(), UAethelnDodgeTestAbility::StaticClass(), UAethelnChainTestAbility::StaticClass() })) { return false; }
	AAethelnPOCInputSpyCharacter* Spy = CastChecked<AAethelnPOCInputSpyCharacter>(F.Pawn);
	UAethelnAbilitySystemComponent& AbilitySystem = *F.Player.AbilitySystem;
	const FGameplayTag Blocking = AethelnGameplayTags::State_Blocking;
	const auto ClearBlockCooldown = [&AbilitySystem]() { AbilitySystem.RemoveActiveEffectsWithGrantedTags(FGameplayTagContainer(AethelnGameplayTags::Cooldown_Block)); };

	// The default keys: one remappable dodge key (Left Control, Q1) and the right mouse button, in the built context.
	const UInputMappingContext* Context = ReadObjectProperty<UInputMappingContext>(*F.Input, TEXT("MappingContext"));
	if (!TestNotNull(TEXT("The component built its context"), Context)) { return false; }
	const FEnhancedActionKeyMapping* DodgeMapping = FindMapping(*Context, TEXT("IA_POC_Dodge"));
	const FEnhancedActionKeyMapping* BlockMapping = FindMapping(*Context, TEXT("IA_POC_Block"));
	TestTrue(TEXT("The dodge defaults to Left Control"), DodgeMapping != nullptr && DodgeMapping->Key == EKeys::LeftControl);
	TestTrue(TEXT("The block is the right mouse button"), BlockMapping != nullptr && BlockMapping->Key == EKeys::RightMouseButton);

	// Reticle mode: the dodge press reaches the pawn's receiver, whose own gate sets the flag; it is never a seam press.
	TestEqual(TEXT("The dodge key's binding ran"), F.Press(TEXT("IA_POC_Dodge")), 1);
	TestEqual(TEXT("A Reticle-mode dodge press reaches the receiver"), Spy->DodgePressedCount, 1);
	TestEqual(TEXT("The dodge press is not a seam request"), F.Outcomes.Num(), 0);

	// Reticle mode: right mouse maps to Press and Release.
	TestEqual(TEXT("The right mouse press ran"), F.Press(TEXT("IA_POC_Block")), 1);
	if (TestEqual(TEXT("The right mouse press reaches the seam"), F.Outcomes.Num(), 1)) { TestEqual(TEXT("The press is accepted"), F.Outcomes[0], EResult::Accepted); }
	TestTrue(TEXT("The block is raised"), AbilitySystem.HasMatchingGameplayTag(Blocking));
	TestTrue(TEXT("A held block does not close the dodge gate: an accepted dodge ends it (Q10)"), AbilitySystem.CanPredictDodge());
	TestEqual(TEXT("The right mouse release ran"), F.Release(TEXT("IA_POC_Block")), 1);
	if (TestEqual(TEXT("The right mouse release reaches the seam"), F.Outcomes.Num(), 2)) { TestEqual(TEXT("The release is accepted"), F.Outcomes[1], EResult::Accepted); }
	TestFalse(TEXT("The release lowers the block"), AbilitySystem.HasMatchingGameplayTag(Blocking));
	F.Release(TEXT("IA_POC_Block"));
	Fire(*F.Input, TEXT("IA_POC_Block"), ETriggerEvent::Canceled);
	TestEqual(TEXT("A release or cancel with nothing held sends nothing"), F.Outcomes.Num(), 2);

	// Cursor entry releases a held block, once; the key release the flush raises afterwards sends nothing more.
	ClearBlockCooldown();
	F.Press(TEXT("IA_POC_Block"));
	TestTrue(TEXT("The block is raised again"), AbilitySystem.HasMatchingGameplayTag(Blocking));
	TestEqual(TEXT("The Cursor toggle ran"), F.Press(TEXT("IA_POC_ToggleControlMode")), 1);
	TestFalse(TEXT("Cursor entry releases the held block"), AbilitySystem.HasMatchingGameplayTag(Blocking));
	TestEqual(TEXT("The press and the Cursor release were the only requests"), F.Outcomes.Num(), 4);
	F.Release(TEXT("IA_POC_Block"));
	Fire(*F.Input, TEXT("IA_POC_Block"), ETriggerEvent::Canceled);
	TestEqual(TEXT("The flushed key release sends no second release"), F.Outcomes.Num(), 4);

	// Cursor mode: neither key does anything, and the recapture click is never a block (nor an attack).
	ClearBlockCooldown();
	Spy->ResetRecords();
	F.Press(TEXT("IA_POC_Block"));
	F.Press(TEXT("IA_POC_Dodge"));
	TestEqual(TEXT("A Cursor-mode dodge press does not reach the receiver"), Spy->DodgePressedCount, 0);
	TestEqual(TEXT("A Cursor-mode block press sends nothing"), F.Outcomes.Num(), 4);
	TestEqual(TEXT("The recapture click ran"), F.Press(TEXT("IA_POC_ViewportRecapture")), 1);
	TestEqual(TEXT("The recapture click sends no request"), F.Outcomes.Num(), 4);
	TestFalse(TEXT("The recapture click raises no block"), AbilitySystem.HasMatchingGameplayTag(Blocking));
	TestEqual(TEXT("The recapture click starts no attack"), F.Records.Num(), 0);
	F.Release(TEXT("IA_POC_ViewportRecapture"));
	F.Release(TEXT("IA_POC_Block"));
	TestEqual(TEXT("A release with nothing held sends nothing"), F.Outcomes.Num(), 4);

	// The local gate (ASC::CanPredictDodge), here with the fixture dodge granted and no server-only tag on this ASC.
	// Record times are relative to now: a window ends at StartServerTime + CancelOpen, and a window ending now is over (half-open).
	const double Now = F.World.World->GetTimeSeconds();
	const auto Record = [Now](double StartAgo, double CancelOpen)
	{
		FAethelnCombatActivationRecord Result;
		Result.ActivationId = FGuid::NewGuid();
		Result.StartServerTime = Now - StartAgo;
		Result.Windows.CancelOpen = CancelOpen;
		return Result;
	};
	TestTrue(TEXT("The gate passes with nothing in the way"), AbilitySystem.CanPredictDodge());
	AbilitySystem.ReceiveCombatActivationForTests(Record(0.25, 0.5));
	TestFalse(TEXT("The gate fails during the commitment window of an owner record"), AbilitySystem.CanPredictDodge());
	AbilitySystem.ReceiveCombatActivationForTests(Record(0.5, 0.5));
	TestTrue(TEXT("The gate passes once the window has ended"), AbilitySystem.CanPredictDodge());
	AbilitySystem.ReceiveCombatActivationForTests(Record(0.0, 0.0));
	TestTrue(TEXT("A step with no commitment window never closes the gate"), AbilitySystem.CanPredictDodge());
	const FAethelnCombatActivationRecord Open = Record(0.0, 0.5);
	AbilitySystem.ReceiveCombatActivationForTests(Open);
	TestFalse(TEXT("The gate fails again in the next step's window"), AbilitySystem.CanPredictDodge());
	AbilitySystem.ReceiveChainEndedForTests(Open.ActivationId, EAethelnChainEndReason::Completed);
	TestTrue(TEXT("The gate passes when the chain ends"), AbilitySystem.CanPredictDodge());
	AbilitySystem.AddLooseGameplayTag(AethelnGameplayTags::State_Staggered);
	TestFalse(TEXT("The gate fails while a blocking tag the owner can see is present"), AbilitySystem.CanPredictDodge());
	AbilitySystem.RemoveLooseGameplayTag(AethelnGameplayTags::State_Staggered);
	TestTrue(TEXT("The gate passes when the tag is gone"), AbilitySystem.CanPredictDodge());
	return true;
}

// Test Plan: docs/input-camera-free-aim-spike.md, Phase 2 "Request-validation automation to add" and the #60 P6 input path. From the left
// mouse button's bound action on the POC input pawn that the combat game mode selects, through the PlayerState sink, to the versioned
// bounded request on the ASC and its server validation. Complements Aetheln.POC.Input.AttackBindingSubmitsControlAim, which runs the
// routing and the GameUI entry directly. The pawn, controller, and PlayerState classes are the combat game mode's own pairing.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnPOCPressReachesSeamTest,
	"Aetheln.POC.Input.PressReachesSeam",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPOCPressReachesSeamTest::RunTest(const FString& Parameters)
{
	using namespace AethelnPOCInputTests;
	// The game mode lives in its own world, so its GameState never reaches the press world. It holds the pawn class only softly,
	// so the loaded Blueprint class is held strongly for the test.
	FScopedCombatTestWorld ModeWorld;
	AAethelnCombatGameMode* GameMode = ModeWorld.Spawn<AAethelnCombatGameMode>();
	if (!TestNotNull(TEXT("Combat game mode spawns"), GameMode)) { return false; }
	TestTrue(TEXT("The game mode pairs the combat controller"), GameMode->PlayerControllerClass == AAethelnPlayerController::StaticClass());
	TestTrue(TEXT("The game mode pairs the combat PlayerState and its seam"), GameMode->PlayerStateClass == AAethelnPlayerState::StaticClass());
	UClass* PawnClass = GameMode->GetDefaultPawnClassForController(nullptr);
	if (!TestNotNull(TEXT("The game mode selects a pawn class"), PawnClass)) { return false; }
	const TStrongObjectPtr<UClass> KeepPawnClass(PawnClass);
	UClass* InputClass = Cast<APawn>(PawnClass->GetDefaultObject())->GetOverrideInputComponentClass();

	FInputFixture F;
	if (!F.Init(*this, PawnClass, InputClass)) { return false; }
	const FRotator Look(30.0, 10.0, 0.0);
	F.Player.Controller->SetControlRotation(Look);
	const FGameplayTag Chain = AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain.GetTag();

	// A Reticle-mode press of the bound action is one request, accepted, with the control-rotation aim including pitch.
	TestEqual(TEXT("The primary button's Started binding ran"), F.Press(TEXT("IA_POC_ViewportRecapture")), 1);
	if (TestEqual(TEXT("The server answered the press"), F.Outcomes.Num(), 1)) { TestEqual(TEXT("The press is accepted"), F.Outcomes[0], EResult::Accepted); }
	if (TestEqual(TEXT("The press started the first chain step"), F.Records.Num(), 1))
	{
		TestTrue(TEXT("The request named the basic chain"), F.Records[0].AbilityId == Chain);
		const FVector Aim = F.Records[0].AcceptedAim;
		TestTrue(TEXT("The accepted aim is the control rotation"), Aim.Equals(Look.Vector(), 0.01));
		TestTrue(TEXT("The aim carries the pitch"), Aim.Z > 0.4);
		TestEqual(TEXT("A press at the controller's rotation is not corrected"), F.Records[0].AimCorrection, EAethelnAimCorrection::None);
	}
	F.Release(TEXT("IA_POC_ViewportRecapture"));

	// A Cursor-mode click recaptures and is never an attack; the same press stays consumed until its release.
	F.Press(TEXT("IA_POC_ToggleControlMode"));
	F.Press(TEXT("IA_POC_ViewportRecapture"));
	TestEqual(TEXT("The recapture click sent no request"), F.Outcomes.Num(), 1);
	F.Press(TEXT("IA_POC_ViewportRecapture"));
	TestEqual(TEXT("The recapturing press is not an attack after the mode returned to Reticle"), F.Outcomes.Num(), 1);
	F.Release(TEXT("IA_POC_ViewportRecapture"));
	TestEqual(TEXT("A fresh press after the release attacks"), F.Press(TEXT("IA_POC_ViewportRecapture")), 1);
	TestEqual(TEXT("The server answered the fresh press"), F.Outcomes.Num(), 2);

	// A cancel releases the primary button as a release does: a consumed click does not attack, and the press after the cancel does.
	F.Press(TEXT("IA_POC_ToggleControlMode"));
	F.Press(TEXT("IA_POC_ViewportRecapture"));
	F.Press(TEXT("IA_POC_ViewportRecapture"));
	TestEqual(TEXT("A consumed click sends nothing"), F.Outcomes.Num(), 2);
	TestEqual(TEXT("The primary button's Canceled binding ran"), Fire(*F.Input, TEXT("IA_POC_ViewportRecapture"), ETriggerEvent::Canceled), 1);
	F.Press(TEXT("IA_POC_ViewportRecapture"));
	TestEqual(TEXT("A fresh press after the cancel attacks"), F.Outcomes.Num(), 3);
	return true;
}

// Test Plan: docs/input-camera-free-aim-spike.md, F1 to F3 "bounds that fail closed while unset". The same bound action with the eight aim and
// time bounds unset, as in production while their values are TBD: the seam answers InternalFailure, nothing is spent, started, or applied, and
// a later press with valid bounds is accepted, so the failure left no state behind.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnPOCPressFailsClosedWithoutBoundsTest,
	"Aetheln.POC.Input.PressFailsClosedWithoutBounds",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPOCPressFailsClosedWithoutBoundsTest::RunTest(const FString& Parameters)
{
	using namespace AethelnPOCInputTests;
	FInputFixture F;
	if (!F.Init(*this, AAethelnPOCInputSpyCharacter::StaticClass(), UAethelnPOCInputComponent::StaticClass())) { return false; }
	UAethelnAbilitySystemComponent& AbilitySystem = *F.Player.AbilitySystem;
	const FGameplayTag ChainState = AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain.GetTag();
	UnsetAimTimeBounds(AbilitySystem);
	const float EnduranceBefore = AbilitySystem.GetNumericAttribute(UAethelnCombatAttributeSet::GetEnduranceAttribute());

	TestEqual(TEXT("The press ran"), F.Press(TEXT("IA_POC_ViewportRecapture")), 1);
	if (TestEqual(TEXT("The server answered the press"), F.Outcomes.Num(), 1)) { TestEqual(TEXT("Unset bounds fail closed"), F.Outcomes[0], EResult::InternalFailure); }
	TestEqual(TEXT("No activation started"), F.Records.Num(), 0);
	TestFalse(TEXT("The chain state is not applied"), AbilitySystem.HasMatchingGameplayTag(ChainState));
	TestEqual(TEXT("Nothing was spent"), AbilitySystem.GetNumericAttribute(UAethelnCombatAttributeSet::GetEnduranceAttribute()), EnduranceBefore);
	F.Release(TEXT("IA_POC_ViewportRecapture"));

	AethelnCombatTests::SetTestAimTimeBounds(AbilitySystem);
	TestEqual(TEXT("The press with valid bounds ran"), F.Press(TEXT("IA_POC_ViewportRecapture")), 1);
	if (TestEqual(TEXT("The server answered the second press"), F.Outcomes.Num(), 2)) { TestEqual(TEXT("A press with valid bounds is accepted"), F.Outcomes[1], EResult::Accepted); }
	TestEqual(TEXT("The accepted press started the first chain step"), F.Records.Num(), 1);
	return true;
}

// Test Plan: docs/input-camera-free-aim-spike.md, AC1 "Add" and "Remove". The context is added to the local player's Enhanced Input subsystem
// at priority 0 on registration, and removed on unregister and on destroy, which also clears the bindings. The subsystem is the engine's own,
// on a ULocalPlayer added without a viewport. Application deactivation and reactivation are not covered: they are process-wide engine
// delegates, and broadcasting them from a test would also signal the editor.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnPOCContextLifecycleTest,
	"Aetheln.POC.Input.ContextLifecycle",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPOCContextLifecycleTest::RunTest(const FString& Parameters)
{
	using namespace AethelnPOCInputTests;
	// The component also creates its overlay and HUD widgets for a local player; with no viewport the engine answers each with this warning.
	AddExpectedMessagePlain(TEXT("No game viewport was found"), ELogVerbosity::Warning, EAutomationExpectedMessageFlags::Contains, -1);
	FInputFixture F(true);
	if (!F.Init(*this, AAethelnPOCInputSpyCharacter::StaticClass(), UAethelnPOCInputComponent::StaticClass())) { return false; }
	UEnhancedInputLocalPlayerSubsystem* Subsystem = F.LocalPlayer->GetSubsystem<UEnhancedInputLocalPlayerSubsystem>();
	if (!TestNotNull(TEXT("The local player has the Enhanced Input subsystem"), Subsystem)) { return false; }
	const UInputMappingContext* Context = ReadObjectProperty<UInputMappingContext>(*F.Input, TEXT("MappingContext"));
	if (!TestNotNull(TEXT("The component built its context"), Context)) { return false; }

	int32 Priority = INDEX_NONE;
	TestTrue(TEXT("Registration adds the context"), Subsystem->HasMappingContext(Context, Priority));
	TestEqual(TEXT("It is added at priority 0"), Priority, 0);

	F.Input->UnregisterComponent();
	TestFalse(TEXT("Unregistering removes the context"), Subsystem->HasMappingContext(Context));
	F.Input->RegisterComponent();
	TestTrue(TEXT("Registering again restores the context"), Subsystem->HasMappingContext(Context));

	UAethelnPOCInputComponent* Destroyed = F.Input;
	F.Input->DestroyComponent();
	TestFalse(TEXT("Destroying removes the context"), Subsystem->HasMappingContext(Context));
	TestEqual(TEXT("Destroying clears the action bindings"), Destroyed->GetActionEventBindings().Num(), 0);
	F.Input = nullptr;
	return true;
}

#endif
