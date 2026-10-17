#pragma once

#include "CoreMinimal.h"
#include "EnhancedInputComponent.h"
#include "GameplayTagContainer.h"
#include "InputCoreTypes.h"
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

/** Sends one ability press through the controller's PlayerState as an IAethelnCombatInputSink. False if it is not one. */
GAMEUI_API bool SubmitAbilityPress(APlayerController* Controller, FGameplayTag AbilityId);

/** Sends one ability release (the right mouse button's block) the same way. False if it is not a sink. */
GAMEUI_API bool SubmitAbilityRelease(APlayerController* Controller, FGameplayTag AbilityId);

/** Sends the basic-chain press (the left mouse button's attack). */
GAMEUI_API bool SubmitPrimaryAttack(APlayerController* Controller);

/**
 * The press of one of the four representative Oathscar actives (#260 P5): sent only in Reticle mode, never in Cursor mode, and
 * never through the recapture router (these keys have no recapture role). True if a press was sent.
 */
GAMEUI_API bool RouteActivePress(EAethelnPOCControlMode Mode, APlayerController* Controller, FGameplayTag AbilityId);

/**
 * Client-only transient Enhanced Input setup for the movement POC.
 * The component is selected only by the POC pawn Blueprint.
 */
UCLASS(Transient, Config=Game)
class GAMEUI_API UAethelnPOCInputComponent : public UEnhancedInputComponent
{
	GENERATED_BODY()

public:
	UAethelnPOCInputComponent();

	/**
	 * Keys of the four representative Oathscar actives (#260 P5). The key layout is #82's, so none is chosen here or in the ini:
	 * an invalid key (the default) maps nothing, and the press has no way in. A run sets them in
	 * [/Script/GameUI.AethelnPOCInputComponent] of an untracked ini, for example Saved/Config/WindowsEditor/Game.ini.
	 */
	UPROPERTY(Config)
	FKey InstantStrikeKey;

	UPROPERTY(Config)
	FKey ParryKey;

	UPROPERTY(Config)
	FKey AttackStanceKey;

	UPROPERTY(Config)
	FKey DefenseStanceKey;

	/**
	 * The one dodge key (#18 P5, owner decision 2026-10-10, Q1): Left Control by default, remappable here. The block is the right
	 * mouse button. Neither has a controller layout yet (#82).
	 */
	UPROPERTY(Config)
	FKey DodgeKey;

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
	/** One of the four actives: a Reticle-mode press only, sent to the server as an ability press; Cursor mode sends nothing. */
	void HandleActivePress(const FInputActionValue& Value, FGameplayTag AbilityId);
	/** The dodge key: a Reticle-mode press asks the pawn for a movement-carried dodge, whose local gate decides; Cursor mode sends nothing. */
	void HandleDodgePressed(const FInputActionValue& Value);
	/** The right mouse button: a Reticle-mode press raises the block, and the release lowers it if it is held. */
	void HandleBlockPressed(const FInputActionValue& Value);
	void HandleBlockReleased(const FInputActionValue& Value);
	/** Lowers a held block once, on Cursor entry and focus loss. On teardown it only clears the held state: the controller is usually gone by then, and the server's avatar-loss path ends the block. */
	void ReleaseHeldBlock();
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

	/** Instant Strike, Parry, Attack Stance, Defense Stance, in that order. */
	UPROPERTY(Transient)
	TArray<TObjectPtr<UInputAction>> ActiveActions;

	UPROPERTY(Transient)
	TObjectPtr<UInputAction> DodgeAction;

	UPROPERTY(Transient)
	TObjectPtr<UInputAction> BlockAction;

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
	/** A block press was sent and its release was not. */
	bool bBlockHeld = false;
};
