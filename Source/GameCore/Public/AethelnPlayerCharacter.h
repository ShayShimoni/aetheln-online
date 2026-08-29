#pragma once

#include "AethelnPlayerInputReceiver.h"
#include "CoreMinimal.h"
#include "GameFramework/Character.h"
#include "AethelnPlayerCharacter.generated.h"

class UCameraComponent;
class USpringArmComponent;

/**
 * Minimal third-person player character for the local movement proof of concept.
 * Presentation assets and the client-only input component are assigned by a thin
 * Blueprint so GameCore remains safe to compile into the server target.
 */
UCLASS()
class GAMECORE_API AAethelnPlayerCharacter
	: public ACharacter
	, public IAethelnPlayerInputReceiver
{
	GENERATED_BODY()

public:
	explicit AAethelnPlayerCharacter(
		const FObjectInitializer& ObjectInitializer = FObjectInitializer::Get());

	virtual void Tick(float DeltaSeconds) override;
	virtual void ReceiveMoveInput(const FVector2D& MovementInput) override;
	virtual void ReceiveLookInput(const FVector2D& LookInput) override;
	virtual void ReceiveCameraZoomInput(float ZoomInput) override;
	virtual void ReceiveAimSteeringIntent(bool bWantsAimSteering) override;
	virtual void ReceiveJumpStarted() override;
	virtual void ReceiveJumpStopped() override;
	virtual void ReceiveJumpCanceled() override;
	virtual void ReceiveSprintIntent(bool bWantsToSprint) override;
	virtual void UnPossessed() override;

protected:
	virtual void BeginPlay() override;
	virtual void EndPlay(const EEndPlayReason::Type EndPlayReason) override;
	virtual void OnJumped_Implementation() override;
	virtual void OnMovementModeChanged(
		EMovementMode PrevMovementMode,
		uint8 PreviousCustomMode = 0) override;

private:
	void ApplyAimSteeringIntent(bool bWantsAimSteering);
	void ApplyCurrentGroundRotationMode();
	void ApplyCurrentGroundSpeed();
	void ApplyCurrentJumpFacing();
	void ApplyCurrentJumpHorizontalVelocity();
	void ApplySprintIntent(bool bWantsToSprint);
	void CaptureTravelFacingAimJumpOffset();
	void ClearBufferedJumpRequest();
	FRotator GetMovementReferenceRotation() const;
	void ResetMovementPresentation(bool bResetImmediately);
	void TryConsumeBufferedJump();
	void UpdateAirborneAimFacing();
	void UpdateCameraPresentation(float DeltaSeconds);
	void UpdateMovementPresentation(float DeltaSeconds);

	UPROPERTY(VisibleAnywhere, Category = "POC|Camera", meta = (AllowPrivateAccess = "true"))
	TObjectPtr<USpringArmComponent> CameraBoom;

	UPROPERTY(VisibleAnywhere, Category = "POC|Camera", meta = (AllowPrivateAccess = "true"))
	TObjectPtr<UCameraComponent> FollowCamera;

	UPROPERTY(EditDefaultsOnly, Category = "POC|Camera", meta = (ClampMin = "0.0", Units = "cm"))
	float CameraZoomMinDistance = 0.0f;

	UPROPERTY(EditDefaultsOnly, Category = "POC|Camera", meta = (ClampMin = "0.0", Units = "cm"))
	float CameraZoomMaxDistance = 700.0f;

	UPROPERTY(EditDefaultsOnly, Category = "POC|Camera", meta = (ClampMin = "0.0", Units = "cm"))
	float CameraZoomStep = 40.0f;

	UPROPERTY(EditDefaultsOnly, Category = "POC|Camera", meta = (ClampMin = "0.0", Units = "cm/s"))
	float CameraZoomTransitionSpeed = 400.0f;

	UPROPERTY(EditDefaultsOnly, Category = "POC|Camera", meta = (ClampMin = "0.0", Units = "cm"))
	float FirstPersonMeshHideDistance = 50.0f;

	UPROPERTY(EditDefaultsOnly, Category = "POC|Camera", meta = (ClampMin = "0.0", Units = "cm"))
	float FirstPersonMeshRestoreDistance = 60.0f;

	UPROPERTY(EditDefaultsOnly, Category = "POC|Camera", meta = (ClampMin = "0.0", Units = "cm"))
	float CameraShoulderMaxOffset = 35.0f;

	UPROPERTY(EditDefaultsOnly, Category = "POC|Camera", meta = (ClampMin = "0.0", Units = "cm"))
	float ThirdPersonCameraTargetHeight = 120.0f;

	UPROPERTY(EditDefaultsOnly, Category = "POC|Camera", meta = (ClampMin = "0.0", Units = "cm"))
	float FirstPersonCameraTargetHeight = 70.0f;

	UPROPERTY(EditDefaultsOnly, Category = "POC|Movement", meta = (ClampMin = "0.0", Units = "cm/s"))
	float WalkSpeed = 500.0f;

	UPROPERTY(EditDefaultsOnly, Category = "POC|Movement", meta = (ClampMin = "0.0", Units = "cm/s"))
	float SprintSpeed = 700.0f;

	UPROPERTY(EditDefaultsOnly, Category = "POC|Movement", meta = (ClampMin = "0.0", ClampMax = "1.0"))
	float BackpedalSpeedScale = 0.7f;

	UPROPERTY(EditDefaultsOnly, Category = "POC|Movement", meta = (ClampMin = "0.0", ClampMax = "30.0", Units = "deg"))
	float MaxAimJumpPresentationYaw = 25.0f;

	UPROPERTY(EditDefaultsOnly, Category = "POC|Movement", meta = (ClampMin = "0.0", ClampMax = "60.0", Units = "deg"))
	float MaxGroundAimPresentationYaw = 35.0f;

	UPROPERTY(EditDefaultsOnly, Category = "POC|Movement", meta = (ClampMin = "0.0"))
	float PresentationInterpSpeed = 12.0f;

	UPROPERTY(EditDefaultsOnly, Category = "POC|Movement", meta = (ClampMin = "0.0", ClampMax = "0.5", Units = "s"))
	float JumpBufferDuration = 0.2f;

	FVector2D LastMovementInput = FVector2D::ZeroVector;
	double BufferedJumpExpiryTime = 0.0;
	float BaseMeshRelativeYaw = 0.0f;
	float PendingJumpPresentationYaw = 0.0f;
	float LockedJumpPresentationYaw = 0.0f;
	float CurrentPresentationYaw = 0.0f;
	float DesiredCameraZoomDistance = 400.0f;
	float TravelFacingAimJumpOffset = 0.0f;
	bool bIssuedNetworkSprintWarning = false;
	bool bAimSteeringActive = false;
	bool bCameraMeshHidden = false;
	bool bHasBufferedJump = false;
	bool bSprintIntentActive = false;
	bool bTravelFacingAimJumpActive = false;
	bool bWantsBackpedal = false;
	bool bJumpPresentationActive = false;
};
