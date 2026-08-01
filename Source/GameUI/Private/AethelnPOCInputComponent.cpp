#include "AethelnPOCInputComponent.h"

#include "AethelnPOCOverlayWidget.h"
#include "AethelnPlayerInputReceiver.h"
#include "Blueprint/UserWidget.h"
#include "EnhancedActionKeyMapping.h"
#include "EnhancedInputSubsystems.h"
#include "Engine/LocalPlayer.h"
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
		bool bMoveRight,
		bool bMouseForward)
	{
		const float Horizontal = static_cast<float>(bMoveRight)
			- static_cast<float>(bMoveLeft);
		const bool bAnyForward = bMoveForward || bMouseForward;
		const float Vertical = static_cast<float>(bAnyForward)
			- static_cast<float>(bMoveBackward);
		return FVector2D(Horizontal, Vertical).GetClampedToMaxSize(1.0f);
	}

	bool IsCameraOnlyOrbit(
		bool bLeftMouseHeld,
		bool bRightMouseHeld)
	{
		return bLeftMouseHeld && !bRightMouseHeld;
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
		false, false, true, false, false);
	const FVector2D MoveRight = BuildMovementInput(
		false, false, false, true, false);
	TestEqual(TEXT("A produces negative horizontal input"), MoveLeft.X, -1.0);
	TestEqual(TEXT("D produces positive horizontal input"), MoveRight.X, 1.0);
	TestEqual(TEXT("Pure lateral A has no forward input"), MoveLeft.Y, 0.0);
	TestEqual(TEXT("Pure lateral D has no forward input"), MoveRight.Y, 0.0);

	const FVector2D Diagonal = BuildMovementInput(
		true, false, false, true, false);
	TestTrue(
		TEXT("Diagonal movement is normalized"),
		FMath::IsNearlyEqual(Diagonal.Size(), 1.0f));
	TestTrue(
		TEXT("W+D produces a 45-degree movement request"),
		FMath::IsNearlyEqual(Diagonal.X, Diagonal.Y));

	const FVector2D CombinedForwardDiagonal = BuildMovementInput(
		true, false, false, true, true);
	TestTrue(
		TEXT("W and both-button forward remain one logical forward intent"),
		FMath::IsNearlyEqual(
			CombinedForwardDiagonal.X,
			CombinedForwardDiagonal.Y));

	const FVector2D OpposedHorizontal = BuildMovementInput(
		false, false, true, true, false);
	TestTrue(
		TEXT("A and D cancel"),
		OpposedHorizontal.IsNearlyZero());

	const FVector2D MouseForwardCanceled = BuildMovementInput(
		false, true, false, false, true);
	TestTrue(
		TEXT("S cancels both-button forward"),
		MouseForwardCanceled.IsNearlyZero());
	TestTrue(
		TEXT("LMB alone requests camera-only orbit"),
		IsCameraOnlyOrbit(true, false));
	TestFalse(
		TEXT("RMB takes steering control when both buttons are held"),
		IsCameraOnlyOrbit(true, true));
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
		bMoveRightHeld,
		bLeftMouseHeld && bRightMouseHeld);
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

	LeftMouseAction = NewObject<UInputAction>(
		this,
		TEXT("IA_POC_LeftMouse"),
		RF_Transient);
	LeftMouseAction->ValueType = EInputActionValueType::Boolean;

	RightMouseAction = NewObject<UInputAction>(
		this,
		TEXT("IA_POC_RightMouse"),
		RF_Transient);
	RightMouseAction->ValueType = EInputActionValueType::Boolean;

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
	MappingContext->MapKey(LeftMouseAction, EKeys::LeftMouseButton);
	MappingContext->MapKey(RightMouseAction, EKeys::RightMouseButton);

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
	BindAction(LeftMouseAction, ETriggerEvent::Started, this, &UAethelnPOCInputComponent::HandleLeftMouseStarted);
	BindAction(LeftMouseAction, ETriggerEvent::Completed, this, &UAethelnPOCInputComponent::HandleLeftMouseStopped);
	BindAction(LeftMouseAction, ETriggerEvent::Canceled, this, &UAethelnPOCInputComponent::HandleLeftMouseStopped);
	BindAction(RightMouseAction, ETriggerEvent::Started, this, &UAethelnPOCInputComponent::HandleRightMouseStarted);
	BindAction(RightMouseAction, ETriggerEvent::Completed, this, &UAethelnPOCInputComponent::HandleRightMouseStopped);
	BindAction(RightMouseAction, ETriggerEvent::Canceled, this, &UAethelnPOCInputComponent::HandleRightMouseStopped);
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
			InputSubsystem->AddMappingContext(MappingContext, 0);
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

	UpdateMouseControlState();
}

void UAethelnPOCInputComponent::ReleaseLocalPlayerResources()
{
	ResetHeldState();

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

void UAethelnPOCInputComponent::ResetHeldState()
{
	if (IAethelnPlayerInputReceiver* Receiver = GetReceiver())
	{
		Receiver->ReceiveCameraOrbitIntent(false);
		Receiver->ReceiveAimSteeringIntent(false);
		Receiver->ReceiveSprintIntent(false);
		Receiver->ReceiveJumpCanceled();
	}
	bMoveForwardHeld = false;
	bMoveBackwardHeld = false;
	bMoveLeftHeld = false;
	bMoveRightHeld = false;
	bLeftMouseHeld = false;
	bRightMouseHeld = false;
	bLookCaptured = false;
	SetComponentTickEnabled(false);
	if (IAethelnPlayerInputReceiver* Receiver = GetReceiver())
	{
		Receiver->ReceiveMoveInput(FVector2D::ZeroVector);
	}
	if (OverlayWidget != nullptr)
	{
		OverlayWidget->SetAimReticleVisible(false);
	}
	SetMouseCapture(false);
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

void UAethelnPOCInputComponent::UpdateMouseControlState()
{
	const bool bCaptureMouse = bLeftMouseHeld || bRightMouseHeld;
	bLookCaptured = bCaptureMouse;
	UpdateMovementTickState();

	if (IAethelnPlayerInputReceiver* Receiver = GetReceiver())
	{
		Receiver->ReceiveCameraOrbitIntent(
			IsCameraOnlyOrbit(
				bLeftMouseHeld,
				bRightMouseHeld));
		Receiver->ReceiveAimSteeringIntent(bRightMouseHeld);
	}

	if (OverlayWidget != nullptr)
	{
		OverlayWidget->SetAimReticleVisible(bRightMouseHeld);
	}

	SetMouseCapture(bCaptureMouse);
}

void UAethelnPOCInputComponent::UpdateMovementTickState()
{
	const FVector2D MovementInput = BuildMovementInput(
		bMoveForwardHeld,
		bMoveBackwardHeld,
		bMoveLeftHeld,
		bMoveRightHeld,
		bLeftMouseHeld && bRightMouseHeld);
	if (MovementInput.IsNearlyZero())
	{
		if (IAethelnPlayerInputReceiver* Receiver = GetReceiver())
		{
			Receiver->ReceiveMoveInput(FVector2D::ZeroVector);
		}
	}
	SetComponentTickEnabled(!MovementInput.IsNearlyZero());
}

void UAethelnPOCInputComponent::SetMouseCapture(bool bCaptureMouse)
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

	PlayerController->bShowMouseCursor = !bCaptureMouse;
	if (bCaptureMouse)
	{
		FInputModeGameOnly InputMode;
		PlayerController->SetInputMode(InputMode);
		return;
	}

	FInputModeGameAndUI InputMode;
	InputMode.SetHideCursorDuringCapture(false);
	InputMode.SetLockMouseToViewportBehavior(EMouseLockMode::DoNotLock);
	PlayerController->SetInputMode(InputMode);
}

void UAethelnPOCInputComponent::HandleMoveForwardStarted(
	const FInputActionValue& Value)
{
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
	if (bLookCaptured)
	{
		if (IAethelnPlayerInputReceiver* Receiver = GetReceiver())
		{
			Receiver->ReceiveLookInput(Value.Get<FVector2D>());
		}
	}
}

void UAethelnPOCInputComponent::HandleZoom(const FInputActionValue& Value)
{
	if (IAethelnPlayerInputReceiver* Receiver = GetReceiver())
	{
		Receiver->ReceiveCameraZoomInput(Value.Get<float>());
	}
}

void UAethelnPOCInputComponent::HandleLeftMouseStarted(
	const FInputActionValue& Value)
{
	bLeftMouseHeld = true;
	UpdateMouseControlState();
}

void UAethelnPOCInputComponent::HandleLeftMouseStopped(
	const FInputActionValue& Value)
{
	bLeftMouseHeld = false;
	UpdateMouseControlState();
}

void UAethelnPOCInputComponent::HandleRightMouseStarted(
	const FInputActionValue& Value)
{
	bRightMouseHeld = true;
	UpdateMouseControlState();
}

void UAethelnPOCInputComponent::HandleRightMouseStopped(
	const FInputActionValue& Value)
{
	bRightMouseHeld = false;
	UpdateMouseControlState();
}

void UAethelnPOCInputComponent::HandleJumpStarted(const FInputActionValue& Value)
{
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
