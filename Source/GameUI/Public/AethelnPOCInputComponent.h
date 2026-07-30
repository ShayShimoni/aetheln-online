#pragma once

#include "CoreMinimal.h"
#include "EnhancedInputComponent.h"
#include "AethelnPOCInputComponent.generated.h"

class IAethelnPlayerInputReceiver;
class APlayerController;
class UAethelnPOCOverlayWidget;
class ULocalPlayer;
class UInputAction;
class UInputMappingContext;

/**
 * Client-only transient Enhanced Input setup for the movement POC.
 * The component is selected only by the POC pawn Blueprint.
 */
UCLASS(Transient)
class GAMEUI_API UAethelnPOCInputComponent : public UEnhancedInputComponent
{
	GENERATED_BODY()

public:
	UAethelnPOCInputComponent();

protected:
	virtual void OnRegister() override;
	virtual void OnUnregister() override;
	virtual void OnComponentDestroyed(bool bDestroyingHierarchy) override;
	virtual void TickComponent(
		float DeltaTime,
		ELevelTick TickType,
		FActorComponentTickFunction* ThisTickFunction) override;

private:
	void InitializeActions();
	void BindReceiver();
	void ActivateLocalPlayerResources();
	void ReleaseLocalPlayerResources();
	void ResetHeldState();
	void HandleApplicationDeactivated();
	void HandleApplicationReactivated();
	void RemoveLifecycleDelegates();
	void UpdateMouseControlState();
	void UpdateMovementTickState();
	void SetMouseCapture(bool bCaptureMouse);

	void HandleLook(const FInputActionValue& Value);
	void HandleMoveForwardStarted(const FInputActionValue& Value);
	void HandleMoveForwardStopped(const FInputActionValue& Value);
	void HandleMoveBackwardStarted(const FInputActionValue& Value);
	void HandleMoveBackwardStopped(const FInputActionValue& Value);
	void HandleMoveLeftStarted(const FInputActionValue& Value);
	void HandleMoveLeftStopped(const FInputActionValue& Value);
	void HandleMoveRightStarted(const FInputActionValue& Value);
	void HandleMoveRightStopped(const FInputActionValue& Value);
	void HandleLeftMouseStarted(const FInputActionValue& Value);
	void HandleLeftMouseStopped(const FInputActionValue& Value);
	void HandleRightMouseStarted(const FInputActionValue& Value);
	void HandleRightMouseStopped(const FInputActionValue& Value);
	void HandleJumpStarted(const FInputActionValue& Value);
	void HandleJumpStopped(const FInputActionValue& Value);
	void HandleJumpCanceled(const FInputActionValue& Value);
	void HandleSprintStarted(const FInputActionValue& Value);
	void HandleSprintStopped(const FInputActionValue& Value);

	IAethelnPlayerInputReceiver* GetReceiver() const;

	UPROPERTY(Transient)
	TObjectPtr<UInputAction> MoveForwardAction;

	UPROPERTY(Transient)
	TObjectPtr<UInputAction> MoveBackwardAction;

	UPROPERTY(Transient)
	TObjectPtr<UInputAction> MoveLeftAction;

	UPROPERTY(Transient)
	TObjectPtr<UInputAction> MoveRightAction;

	UPROPERTY(Transient)
	TObjectPtr<UInputAction> LookAction;

	UPROPERTY(Transient)
	TObjectPtr<UInputAction> LeftMouseAction;

	UPROPERTY(Transient)
	TObjectPtr<UInputAction> RightMouseAction;

	UPROPERTY(Transient)
	TObjectPtr<UInputAction> JumpAction;

	UPROPERTY(Transient)
	TObjectPtr<UInputAction> SprintAction;

	UPROPERTY(Transient)
	TObjectPtr<UInputMappingContext> MappingContext;

	UPROPERTY(Transient)
	TObjectPtr<UAethelnPOCOverlayWidget> OverlayWidget;

	TWeakObjectPtr<UObject> ReceiverObject;
	TWeakObjectPtr<ULocalPlayer> AppliedLocalPlayer;
	TWeakObjectPtr<APlayerController> AppliedPlayerController;
	FDelegateHandle DeactivateHandle;
	FDelegateHandle ReactivateHandle;
	bool bContextApplied = false;
	bool bBindingsApplied = false;
	bool bLookCaptured = false;
	bool bMoveForwardHeld = false;
	bool bMoveBackwardHeld = false;
	bool bMoveLeftHeld = false;
	bool bMoveRightHeld = false;
	bool bLeftMouseHeld = false;
	bool bRightMouseHeld = false;
};
