#include "AethelnPOCInputComponent.h"

#include "AethelnPOCOverlayWidget.h"
#include "AethelnPlayerInputReceiver.h"
#include "Blueprint/UserWidget.h"
#include "EnhancedActionKeyMapping.h"
#include "EnhancedInputSubsystems.h"
#include "Engine/LocalPlayer.h"
#include "Engine/GameViewportClient.h"
#include "GameFramework/Pawn.h"
#include "GameFramework/PlayerController.h"
#include "InputAction.h"
#include "InputCoreTypes.h"
#include "InputMappingContext.h"
#include "InputModifiers.h"
#include "Misc/CoreDelegates.h"
#if WITH_DEV_AUTOMATION_TESTS
#include "Misc/AutomationTest.h"
#endif

namespace
{
	void AddNegateYModifier(FEnhancedActionKeyMapping& Mapping, UObject* Outer)
	{
		UInputModifierNegate* Negate = NewObject<UInputModifierNegate>(Outer);
		Negate->bX = false;
		Negate->bY = true;
		Negate->bZ = false;
		Mapping.Modifiers.Add(Negate);
	}

	FVector2D BuildMovementInput(
		bool bMoveForward,
		bool bMoveBackward,
		bool bMoveLeft,
		bool bMoveRight)
	{
		const float Horizontal = static_cast<float>(bMoveRight)
			- static_cast<float>(bMoveLeft);
		const float Vertical = static_cast<float>(bMoveForward)
			- static_cast<float>(bMoveBackward);
		return FVector2D(Horizontal, Vertical).GetClampedToMaxSize(1.0f);
	}

	bool IsGameplayInputEnabled(EAethelnPOCControlMode ControlMode)
	{
		return ControlMode == EAethelnPOCControlMode::Reticle;
	}

	EAethelnPOCControlMode ToggleControlMode(
		EAethelnPOCControlMode ControlMode)
	{
		return IsGameplayInputEnabled(ControlMode)
			? EAethelnPOCControlMode::Cursor
			: EAethelnPOCControlMode::Reticle;
	}

	bool ConsumeLookSuppression(bool& bSuppressNextLookInput)
	{
		if (!bSuppressNextLookInput)
		{
			return false;
		}

		bSuppressNextLookInput = false;
		return true;
	}

	FModifyContextOptions BuildPOCMappingContextOptions()
	{
		FModifyContextOptions Options;
		Options.bIgnoreAllPressedKeysUntilRelease = true;
		return Options;
	}
}

#if WITH_DEV_AUTOMATION_TESTS
IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnPOCDirectionalMovementInputTest,
	"Aetheln.POC.Input.DirectionalMovement",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPOCDirectionalMovementInputTest::RunTest(
	const FString& Parameters)
{
	const FVector2D MoveLeft = BuildMovementInput(
		false, false, true, false);
	const FVector2D MoveRight = BuildMovementInput(
		false, false, false, true);
	TestEqual(TEXT("A produces negative horizontal input"), MoveLeft.X, -1.0);
	TestEqual(TEXT("D produces positive horizontal input"), MoveRight.X, 1.0);
	TestEqual(TEXT("Pure lateral A has no forward input"), MoveLeft.Y, 0.0);
	TestEqual(TEXT("Pure lateral D has no forward input"), MoveRight.Y, 0.0);

	const FVector2D Diagonal = BuildMovementInput(
		true, false, false, true);
	TestTrue(
		TEXT("Diagonal movement is normalized"),
		FMath::IsNearlyEqual(Diagonal.Size(), 1.0f));
	TestTrue(
		TEXT("W+D produces a 45-degree movement request"),
		FMath::IsNearlyEqual(Diagonal.X, Diagonal.Y));

	TestTrue(
		TEXT("Mouse buttons no longer add movement intent"),
		BuildMovementInput(
			false, false, false, false).IsNearlyZero());
	TestTrue(
		TEXT("Keyboard diagonals remain balanced"),
		FMath::IsNearlyEqual(
			Diagonal.X,
			Diagonal.Y));

	const FVector2D OpposedHorizontal = BuildMovementInput(
		false, false, true, true);
	TestTrue(
		TEXT("A and D cancel"),
		OpposedHorizontal.IsNearlyZero());

	const FVector2D OpposedVertical = BuildMovementInput(
		true, true, false, false);
	TestTrue(
		TEXT("W and S cancel"),
		OpposedVertical.IsNearlyZero());
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnPOCControlModeTest,
	"Aetheln.POC.Input.ControlModes",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPOCControlModeTest::RunTest(const FString& Parameters)
{
	TestTrue(
		TEXT("Reticle mode accepts gameplay input"),
		IsGameplayInputEnabled(EAethelnPOCControlMode::Reticle));
	TestFalse(
		TEXT("Cursor mode blocks gameplay input"),
		IsGameplayInputEnabled(EAethelnPOCControlMode::Cursor));
	TestEqual(
		TEXT("Left Alt moves Reticle mode to Cursor mode"),
		ToggleControlMode(EAethelnPOCControlMode::Reticle),
		EAethelnPOCControlMode::Cursor);
	TestEqual(
		TEXT("Left Alt or a viewport click recaptures Reticle mode"),
		ToggleControlMode(EAethelnPOCControlMode::Cursor),
		EAethelnPOCControlMode::Reticle);

	bool bSuppressLook = true;
	TestTrue(
		TEXT("The first look sample after capture is suppressed"),
		ConsumeLookSuppression(bSuppressLook));
	TestFalse(
		TEXT("Later look samples are accepted"),
		ConsumeLookSuppression(bSuppressLook));
	TestTrue(
		TEXT("Restored input ignores keys held across focus recovery"),
		BuildPOCMappingContextOptions().bIgnoreAllPressedKeysUntilRelease);
	return true;
}
#endif

UAethelnPOCInputComponent::UAethelnPOCInputComponent()
{
	PrimaryComponentTick.bCanEverTick = true;
	PrimaryComponentTick.bStartWithTickEnabled = false;
}

void UAethelnPOCInputComponent::OnRegister()
{
	Super::OnRegister();
	ControlMode = EAethelnPOCControlMode::Reticle;
	bSuppressNextLookInput = true;

	InitializeActions();
	BindReceiver();

	DeactivateHandle = FCoreDelegates::ApplicationWillDeactivateDelegate.AddUObject(
		this,
		&UAethelnPOCInputComponent::HandleApplicationDeactivated);
	ReactivateHandle = FCoreDelegates::ApplicationHasReactivatedDelegate.AddUObject(
		this,
		&UAethelnPOCInputComponent::HandleApplicationReactivated);

	ActivateLocalPlayerResources();
}

void UAethelnPOCInputComponent::OnUnregister()
{
	RemoveLifecycleDelegates();
	ReleaseLocalPlayerResources();
	Super::OnUnregister();
}

void UAethelnPOCInputComponent::OnComponentDestroyed(bool bDestroyingHierarchy)
{
	RemoveLifecycleDelegates();
	ReleaseLocalPlayerResources();
	ClearActionBindings();
	bBindingsApplied = false;
	ReceiverObject.Reset();

	Super::OnComponentDestroyed(bDestroyingHierarchy);
}

void UAethelnPOCInputComponent::TickComponent(
	float DeltaTime,
	ELevelTick TickType,
	FActorComponentTickFunction* ThisTickFunction)
{
	Super::TickComponent(DeltaTime, TickType, ThisTickFunction);

	const FVector2D MovementInput = BuildMovementInput(
		bMoveForwardHeld,
		bMoveBackwardHeld,
		bMoveLeftHeld,
		bMoveRightHeld);
	if (!MovementInput.IsNearlyZero())
	{
		if (IAethelnPlayerInputReceiver* Receiver = GetReceiver())
		{
			Receiver->ReceiveMoveInput(MovementInput);
		}
	}
}

void UAethelnPOCInputComponent::InitializeActions()
{
	if (MappingContext != nullptr)
	{
		return;
	}

	MoveForwardAction = NewObject<UInputAction>(
		this,
		TEXT("IA_POC_MoveForward"),
		RF_Transient);
	MoveForwardAction->ValueType = EInputActionValueType::Boolean;

	MoveBackwardAction = NewObject<UInputAction>(
		this,
		TEXT("IA_POC_MoveBackward"),
		RF_Transient);
	MoveBackwardAction->ValueType = EInputActionValueType::Boolean;

	MoveLeftAction = NewObject<UInputAction>(
		this,
		TEXT("IA_POC_MoveLeft"),
		RF_Transient);
	MoveLeftAction->ValueType = EInputActionValueType::Boolean;

	MoveRightAction = NewObject<UInputAction>(
		this,
		TEXT("IA_POC_MoveRight"),
		RF_Transient);
	MoveRightAction->ValueType = EInputActionValueType::Boolean;

	LookAction = NewObject<UInputAction>(this, TEXT("IA_POC_Look"), RF_Transient);
	LookAction->ValueType = EInputActionValueType::Axis2D;
	LookAction->AccumulationBehavior = EInputActionAccumulationBehavior::Cumulative;

	ZoomAction = NewObject<UInputAction>(this, TEXT("IA_POC_Zoom"), RF_Transient);
	ZoomAction->ValueType = EInputActionValueType::Axis1D;

	ToggleControlModeAction = NewObject<UInputAction>(
		this,
		TEXT("IA_POC_ToggleControlMode"),
		RF_Transient);
	ToggleControlModeAction->ValueType = EInputActionValueType::Boolean;

	ViewportRecaptureAction = NewObject<UInputAction>(
		this,
		TEXT("IA_POC_ViewportRecapture"),
		RF_Transient);
	ViewportRecaptureAction->ValueType = EInputActionValueType::Boolean;

	JumpAction = NewObject<UInputAction>(this, TEXT("IA_POC_Jump"), RF_Transient);
	JumpAction->ValueType = EInputActionValueType::Boolean;

	SprintAction = NewObject<UInputAction>(this, TEXT("IA_POC_Sprint"), RF_Transient);
	SprintAction->ValueType = EInputActionValueType::Boolean;

	MappingContext = NewObject<UInputMappingContext>(this, TEXT("IMC_POC_Movement"), RF_Transient);

	MappingContext->MapKey(MoveForwardAction, EKeys::W);
	MappingContext->MapKey(MoveBackwardAction, EKeys::S);
	MappingContext->MapKey(MoveLeftAction, EKeys::A);
	MappingContext->MapKey(MoveRightAction, EKeys::D);

	FEnhancedActionKeyMapping& Look = MappingContext->MapKey(
		LookAction,
		EKeys::Mouse2D);
	AddNegateYModifier(Look, MappingContext);
	MappingContext->MapKey(ZoomAction, EKeys::MouseWheelAxis);
	MappingContext->MapKey(ToggleControlModeAction, EKeys::LeftAlt);
	MappingContext->MapKey(
		ViewportRecaptureAction,
		EKeys::LeftMouseButton);

	MappingContext->MapKey(JumpAction, EKeys::SpaceBar);
	MappingContext->MapKey(SprintAction, EKeys::LeftShift);
}

void UAethelnPOCInputComponent::BindReceiver()
{
	if (bBindingsApplied)
	{
		return;
	}

	APawn* OwnerPawn = Cast<APawn>(GetOwner());
	APlayerController* PlayerController = OwnerPawn != nullptr
		? Cast<APlayerController>(OwnerPawn->GetController())
		: nullptr;

	if (PlayerController == nullptr || !PlayerController->IsLocalController())
	{
		return;
	}

	IAethelnPlayerInputReceiver* Receiver = Cast<IAethelnPlayerInputReceiver>(OwnerPawn);
	if (Receiver == nullptr)
	{
		return;
	}

	ReceiverObject = OwnerPawn;

	BindAction(LookAction, ETriggerEvent::Triggered, this, &UAethelnPOCInputComponent::HandleLook);
	BindAction(ZoomAction, ETriggerEvent::Triggered, this, &UAethelnPOCInputComponent::HandleZoom);
	BindAction(MoveForwardAction, ETriggerEvent::Started, this, &UAethelnPOCInputComponent::HandleMoveForwardStarted);
	BindAction(MoveForwardAction, ETriggerEvent::Completed, this, &UAethelnPOCInputComponent::HandleMoveForwardStopped);
	BindAction(MoveForwardAction, ETriggerEvent::Canceled, this, &UAethelnPOCInputComponent::HandleMoveForwardStopped);
	BindAction(MoveBackwardAction, ETriggerEvent::Started, this, &UAethelnPOCInputComponent::HandleMoveBackwardStarted);
	BindAction(MoveBackwardAction, ETriggerEvent::Completed, this, &UAethelnPOCInputComponent::HandleMoveBackwardStopped);
	BindAction(MoveBackwardAction, ETriggerEvent::Canceled, this, &UAethelnPOCInputComponent::HandleMoveBackwardStopped);
	BindAction(MoveLeftAction, ETriggerEvent::Started, this, &UAethelnPOCInputComponent::HandleMoveLeftStarted);
	BindAction(MoveLeftAction, ETriggerEvent::Completed, this, &UAethelnPOCInputComponent::HandleMoveLeftStopped);
	BindAction(MoveLeftAction, ETriggerEvent::Canceled, this, &UAethelnPOCInputComponent::HandleMoveLeftStopped);
	BindAction(MoveRightAction, ETriggerEvent::Started, this, &UAethelnPOCInputComponent::HandleMoveRightStarted);
	BindAction(MoveRightAction, ETriggerEvent::Completed, this, &UAethelnPOCInputComponent::HandleMoveRightStopped);
	BindAction(MoveRightAction, ETriggerEvent::Canceled, this, &UAethelnPOCInputComponent::HandleMoveRightStopped);
	BindAction(ToggleControlModeAction, ETriggerEvent::Started, this, &UAethelnPOCInputComponent::HandleToggleControlMode);
	BindAction(ViewportRecaptureAction, ETriggerEvent::Started, this, &UAethelnPOCInputComponent::HandleViewportRecapture);
	BindAction(JumpAction, ETriggerEvent::Started, this, &UAethelnPOCInputComponent::HandleJumpStarted);
	BindAction(JumpAction, ETriggerEvent::Completed, this, &UAethelnPOCInputComponent::HandleJumpStopped);
	BindAction(JumpAction, ETriggerEvent::Canceled, this, &UAethelnPOCInputComponent::HandleJumpCanceled);
	BindAction(SprintAction, ETriggerEvent::Started, this, &UAethelnPOCInputComponent::HandleSprintStarted);
	BindAction(SprintAction, ETriggerEvent::Completed, this, &UAethelnPOCInputComponent::HandleSprintStopped);
	BindAction(SprintAction, ETriggerEvent::Canceled, this, &UAethelnPOCInputComponent::HandleSprintStopped);
	bBindingsApplied = true;
}

void UAethelnPOCInputComponent::ActivateLocalPlayerResources()
{
	APawn* OwnerPawn = Cast<APawn>(GetOwner());
	APlayerController* PlayerController = OwnerPawn != nullptr
		? Cast<APlayerController>(OwnerPawn->GetController())
		: nullptr;
	ULocalPlayer* LocalPlayer = PlayerController != nullptr ? PlayerController->GetLocalPlayer() : nullptr;
	if (LocalPlayer == nullptr || MappingContext == nullptr)
	{
		return;
	}
	AppliedPlayerController = PlayerController;

	if (UEnhancedInputLocalPlayerSubsystem* InputSubsystem =
		LocalPlayer->GetSubsystem<UEnhancedInputLocalPlayerSubsystem>())
	{
		if (!bContextApplied)
		{
			InputSubsystem->AddMappingContext(
				MappingContext,
				0,
				BuildPOCMappingContextOptions());
			bContextApplied = true;
			AppliedLocalPlayer = LocalPlayer;
		}
	}

	if (OverlayWidget == nullptr)
	{
		OverlayWidget = CreateWidget<UAethelnPOCOverlayWidget>(
			PlayerController,
			UAethelnPOCOverlayWidget::StaticClass());
		if (OverlayWidget != nullptr)
		{
			OverlayWidget->AddToPlayerScreen();
		}
	}

	ApplyControlMode(ControlMode);
}

void UAethelnPOCInputComponent::ReleaseLocalPlayerResources()
{
	ApplyControlMode(EAethelnPOCControlMode::Cursor);

	APawn* OwnerPawn = Cast<APawn>(GetOwner());
	APlayerController* PlayerController = OwnerPawn != nullptr
		? Cast<APlayerController>(OwnerPawn->GetController())
		: nullptr;
	ULocalPlayer* LocalPlayer = AppliedLocalPlayer.Get();
	if (LocalPlayer == nullptr && PlayerController != nullptr)
	{
		LocalPlayer = PlayerController->GetLocalPlayer();
	}

	if (bContextApplied && LocalPlayer != nullptr)
	{
		if (UEnhancedInputLocalPlayerSubsystem* InputSubsystem =
			LocalPlayer->GetSubsystem<UEnhancedInputLocalPlayerSubsystem>())
		{
			InputSubsystem->RemoveMappingContext(MappingContext);
		}
	}
	bContextApplied = false;
	AppliedLocalPlayer.Reset();

	if (OverlayWidget != nullptr)
	{
		OverlayWidget->RemoveFromParent();
		OverlayWidget = nullptr;
	}
	AppliedPlayerController.Reset();
}

void UAethelnPOCInputComponent::ResetGameplayInputState()
{
	if (IAethelnPlayerInputReceiver* Receiver = GetReceiver())
	{
		Receiver->ReceiveAimSteeringIntent(false);
		Receiver->ReceiveSprintIntent(false);
		Receiver->ReceiveJumpCanceled();
	}
	bMoveForwardHeld = false;
	bMoveBackwardHeld = false;
	bMoveLeftHeld = false;
	bMoveRightHeld = false;
	SetComponentTickEnabled(false);
	if (IAethelnPlayerInputReceiver* Receiver = GetReceiver())
	{
		Receiver->ReceiveMoveInput(FVector2D::ZeroVector);
	}
}

void UAethelnPOCInputComponent::HandleApplicationDeactivated()
{
	ReleaseLocalPlayerResources();
}

void UAethelnPOCInputComponent::HandleApplicationReactivated()
{
	BindReceiver();
	ActivateLocalPlayerResources();
}

void UAethelnPOCInputComponent::RemoveLifecycleDelegates()
{
	FCoreDelegates::ApplicationWillDeactivateDelegate.Remove(DeactivateHandle);
	FCoreDelegates::ApplicationHasReactivatedDelegate.Remove(ReactivateHandle);
	DeactivateHandle.Reset();
	ReactivateHandle.Reset();
}

void UAethelnPOCInputComponent::ApplyControlMode(
	EAethelnPOCControlMode NewMode)
{
	ControlMode = NewMode;
	const bool bReticleMode = IsGameplayInputEnabled(ControlMode);

	if (!bReticleMode)
	{
		ResetGameplayInputState();
		if (APlayerController* PlayerController = AppliedPlayerController.Get())
		{
			PlayerController->FlushPressedKeys();
		}
	}
	else
	{
		bSuppressNextLookInput = true;
		if (IAethelnPlayerInputReceiver* Receiver = GetReceiver())
		{
			Receiver->ReceiveAimSteeringIntent(true);
		}
	}

	if (OverlayWidget != nullptr)
	{
		OverlayWidget->SetControlMode(bReticleMode);
	}

	ApplyPlayerInputMode();
}

void UAethelnPOCInputComponent::UpdateMovementTickState()
{
	const FVector2D MovementInput = BuildMovementInput(
		bMoveForwardHeld,
		bMoveBackwardHeld,
		bMoveLeftHeld,
		bMoveRightHeld);
	if (MovementInput.IsNearlyZero())
	{
		if (IAethelnPlayerInputReceiver* Receiver = GetReceiver())
		{
			Receiver->ReceiveMoveInput(FVector2D::ZeroVector);
		}
	}
	SetComponentTickEnabled(!MovementInput.IsNearlyZero());
}

void UAethelnPOCInputComponent::ApplyPlayerInputMode()
{
	APlayerController* PlayerController = AppliedPlayerController.Get();
	if (PlayerController == nullptr)
	{
		const APawn* OwnerPawn = Cast<APawn>(GetOwner());
		PlayerController = OwnerPawn != nullptr
			? Cast<APlayerController>(OwnerPawn->GetController())
			: nullptr;
	}
	if (PlayerController == nullptr || !PlayerController->IsLocalController())
	{
		return;
	}

	const bool bReticleMode = IsGameplayInputEnabled(ControlMode);
	PlayerController->bShowMouseCursor = !bReticleMode;
	if (bReticleMode)
	{
		if (ULocalPlayer* LocalPlayer = PlayerController->GetLocalPlayer())
		{
			if (UGameViewportClient* ViewportClient = LocalPlayer->ViewportClient)
			{
				ViewportClient->SetMouseCaptureMode(
					EMouseCaptureMode::CapturePermanently_IncludingInitialMouseDown);
			}
		}
		FInputModeGameOnly InputMode;
		InputMode.SetConsumeCaptureMouseDown(true);
		PlayerController->SetInputMode(InputMode);
		return;
	}

	if (ULocalPlayer* LocalPlayer = PlayerController->GetLocalPlayer())
	{
		if (UGameViewportClient* ViewportClient = LocalPlayer->ViewportClient)
		{
			ViewportClient->SetMouseCaptureMode(EMouseCaptureMode::NoCapture);
		}
	}
	FInputModeGameAndUI InputMode;
	InputMode.SetHideCursorDuringCapture(false);
	InputMode.SetLockMouseToViewportBehavior(EMouseLockMode::DoNotLock);
	PlayerController->SetInputMode(InputMode);
}

void UAethelnPOCInputComponent::HandleMoveForwardStarted(
	const FInputActionValue& Value)
{
	if (!IsGameplayInputEnabled(ControlMode))
	{
		return;
	}
	bMoveForwardHeld = true;
	UpdateMovementTickState();
}

void UAethelnPOCInputComponent::HandleMoveForwardStopped(
	const FInputActionValue& Value)
{
	bMoveForwardHeld = false;
	UpdateMovementTickState();
}

void UAethelnPOCInputComponent::HandleMoveBackwardStarted(
	const FInputActionValue& Value)
{
	if (!IsGameplayInputEnabled(ControlMode))
	{
		return;
	}
	bMoveBackwardHeld = true;
	UpdateMovementTickState();
}

void UAethelnPOCInputComponent::HandleMoveBackwardStopped(
	const FInputActionValue& Value)
{
	bMoveBackwardHeld = false;
	UpdateMovementTickState();
}

void UAethelnPOCInputComponent::HandleMoveLeftStarted(
	const FInputActionValue& Value)
{
	if (!IsGameplayInputEnabled(ControlMode))
	{
		return;
	}
	bMoveLeftHeld = true;
	UpdateMovementTickState();
}

void UAethelnPOCInputComponent::HandleMoveLeftStopped(
	const FInputActionValue& Value)
{
	bMoveLeftHeld = false;
	UpdateMovementTickState();
}

void UAethelnPOCInputComponent::HandleMoveRightStarted(
	const FInputActionValue& Value)
{
	if (!IsGameplayInputEnabled(ControlMode))
	{
		return;
	}
	bMoveRightHeld = true;
	UpdateMovementTickState();
}

void UAethelnPOCInputComponent::HandleMoveRightStopped(
	const FInputActionValue& Value)
{
	bMoveRightHeld = false;
	UpdateMovementTickState();
}

void UAethelnPOCInputComponent::HandleLook(const FInputActionValue& Value)
{
	if (!IsGameplayInputEnabled(ControlMode)
		|| ConsumeLookSuppression(bSuppressNextLookInput))
	{
		return;
	}

	if (IAethelnPlayerInputReceiver* Receiver = GetReceiver())
	{
		Receiver->ReceiveLookInput(Value.Get<FVector2D>());
	}
}

void UAethelnPOCInputComponent::HandleZoom(const FInputActionValue& Value)
{
	if (!IsGameplayInputEnabled(ControlMode))
	{
		return;
	}

	if (IAethelnPlayerInputReceiver* Receiver = GetReceiver())
	{
		Receiver->ReceiveCameraZoomInput(Value.Get<float>());
	}
}

void UAethelnPOCInputComponent::HandleToggleControlMode(
	const FInputActionValue& Value)
{
	ApplyControlMode(ToggleControlMode(ControlMode));
}

void UAethelnPOCInputComponent::HandleViewportRecapture(
	const FInputActionValue& Value)
{
	if (!IsGameplayInputEnabled(ControlMode))
	{
		ApplyControlMode(EAethelnPOCControlMode::Reticle);
	}
}

void UAethelnPOCInputComponent::HandleJumpStarted(const FInputActionValue& Value)
{
	if (!IsGameplayInputEnabled(ControlMode))
	{
		return;
	}

	if (IAethelnPlayerInputReceiver* Receiver = GetReceiver())
	{
		Receiver->ReceiveJumpStarted();
	}
}

void UAethelnPOCInputComponent::HandleJumpStopped(const FInputActionValue& Value)
{
	if (IAethelnPlayerInputReceiver* Receiver = GetReceiver())
	{
		Receiver->ReceiveJumpStopped();
	}
}

void UAethelnPOCInputComponent::HandleJumpCanceled(
	const FInputActionValue& Value)
{
	if (IAethelnPlayerInputReceiver* Receiver = GetReceiver())
	{
		Receiver->ReceiveJumpCanceled();
	}
}

void UAethelnPOCInputComponent::HandleSprintStarted(const FInputActionValue& Value)
{
	if (!IsGameplayInputEnabled(ControlMode))
	{
		return;
	}

	if (IAethelnPlayerInputReceiver* Receiver = GetReceiver())
	{
		Receiver->ReceiveSprintIntent(true);
	}
}

void UAethelnPOCInputComponent::HandleSprintStopped(const FInputActionValue& Value)
{
	if (IAethelnPlayerInputReceiver* Receiver = GetReceiver())
	{
		Receiver->ReceiveSprintIntent(false);
	}
}

IAethelnPlayerInputReceiver* UAethelnPOCInputComponent::GetReceiver() const
{
	return Cast<IAethelnPlayerInputReceiver>(ReceiverObject.Get());
}
