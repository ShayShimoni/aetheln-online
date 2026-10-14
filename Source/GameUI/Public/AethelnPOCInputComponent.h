#pragma once

#include "CoreMinimal.h"
#include "EnhancedInputComponent.h"
#include "AethelnPOCInputComponent.generated.h"

class IAethelnPlayerInputReceiver;
class APlayerController;
class UAethelnHudWidget;
class UAethelnPOCOverlayWidget;
class ULocalPlayer;
class UInputAction;
class UInputMappingContext;

enum class EAethelnPOCControlMode : uint8
{
	Reticle,
	Cursor,
};

/**
 * Routes the left mouse button (#60 P6, docs/attack-timeline-and-combo.md, Input path across modules).
 * Cursor mode: the press recaptures and is consumed until its release. Reticle mode: the press is an
 * attack, unless it was consumed. A recapture click is never an attack, and a fresh press is needed after it.
 */
struct GAMEUI_API FAethelnPrimaryButtonRouter
{
	enum class EAction : uint8
	{
		None,
		Recapture,
		Attack,
	};

	EAction Press(EAethelnPOCControlMode Mode);
	void Release() { bConsumed = false; }

private:
	bool bConsumed = false;
};

/** Sends the basic-chain press through the controller's PlayerState as an IAethelnCombatInputSink. False if it is not one. */
GAMEUI_API bool SubmitPrimaryAttack(APlayerController* Controller);

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
	void ResetGameplayInputState();
	void HandleApplicationDeactivated();
	void HandleApplicationReactivated();
	void RemoveLifecycleDelegates();
	void ApplyControlMode(EAethelnPOCControlMode NewMode);
	void UpdateMovementTickState();
	void ApplyPlayerInputMode();

	void HandleLook(const FInputActionValue& Value);
	void HandleZoom(const FInputActionValue& Value);
	void HandleMoveForwardStarted(const FInputActionValue& Value);
	void HandleMoveForwardStopped(const FInputActionValue& Value);
	void HandleMoveBackwardStarted(const FInputActionValue& Value);
	void HandleMoveBackwardStopped(const FInputActionValue& Value);
	void HandleMoveLeftStarted(const FInputActionValue& Value);
	void HandleMoveLeftStopped(const FInputActionValue& Value);
	void HandleMoveRightStarted(const FInputActionValue& Value);
	void HandleMoveRightStopped(const FInputActionValue& Value);
	void HandleToggleControlMode(const FInputActionValue& Value);
	/** The left mouse button: recaptures in Cursor mode, attacks in Reticle mode (see FAethelnPrimaryButtonRouter). */
	void HandleViewportRecapture(const FInputActionValue& Value);
	void HandleViewportRecaptureReleased(const FInputActionValue& Value);
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
	TObjectPtr<UInputAction> ZoomAction;

	UPROPERTY(Transient)
	TObjectPtr<UInputAction> ToggleControlModeAction;

	UPROPERTY(Transient)
	TObjectPtr<UInputAction> ViewportRecaptureAction;

	UPROPERTY(Transient)
	TObjectPtr<UInputAction> JumpAction;

	UPROPERTY(Transient)
	TObjectPtr<UInputAction> SprintAction;

	UPROPERTY(Transient)
	TObjectPtr<UInputMappingContext> MappingContext;

	UPROPERTY(Transient)
	TObjectPtr<UAethelnPOCOverlayWidget> OverlayWidget;

	UPROPERTY(Transient)
	TObjectPtr<UAethelnHudWidget> HudWidget;

	TWeakObjectPtr<UObject> ReceiverObject;
	TWeakObjectPtr<ULocalPlayer> AppliedLocalPlayer;
	TWeakObjectPtr<APlayerController> AppliedPlayerController;
	FAethelnPrimaryButtonRouter PrimaryButton;
	FDelegateHandle DeactivateHandle;
	FDelegateHandle ReactivateHandle;
	EAethelnPOCControlMode ControlMode = EAethelnPOCControlMode::Reticle;
	bool bContextApplied = false;
	bool bBindingsApplied = false;
	bool bSuppressNextLookInput = true;
	bool bMoveForwardHeld = false;
	bool bMoveBackwardHeld = false;
	bool bMoveLeftHeld = false;
	bool bMoveRightHeld = false;
};
