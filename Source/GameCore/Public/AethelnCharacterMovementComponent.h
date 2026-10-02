#pragma once

#include "CoreMinimal.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "AethelnCharacterMovementComponent.generated.h"

/**
 * Project character movement. Sprint intent travels as a predicted saved-move
 * flag; the server grants sprint speed only when its own simulation agrees the
 * move is eligible, and caps backpedal speed. Jump takeoff and body facing are
 * set inside the simulation from the move's flags, acceleration and control yaw,
 * so prediction, correction replay and the server compute the same result.
 * Clients never send speeds or rotations.
 */
UCLASS()
class GAMECORE_API UAethelnCharacterMovementComponent : public UCharacterMovementComponent
{
	GENERATED_BODY()

public:
	/** Jump takeoff derived from one move's acceleration. */
	struct FJumpTakeoff
	{
		FVector HorizontalVelocity = FVector::ZeroVector;
		float FacingYaw = 0.0f;
		/** False when the move has no input: the jump keeps its current velocity and facing. */
		bool bHasMoveInput = false;
		/** Aimed pure-lateral takeoff: faces travel, then turns with camera yaw while aim is held. */
		bool bAimTracked = false;
	};

	virtual float GetMaxSpeed() const override;
	virtual void PhysicsRotation(float DeltaTime) override;
	virtual FNetworkPredictionData_Client* GetPredictionData_Client() const override;
	// Re-expose the deprecated DoJump(bool) overload so overriding the current one does not hide it
	// (clang -Woverloaded-virtual, an error under UBT's -Werror on Linux).
	PRAGMA_DISABLE_DEPRECATION_WARNINGS
	using Super::DoJump;
	PRAGMA_ENABLE_DEPRECATION_WARNINGS
	virtual bool DoJump(bool bReplayingMoves, float DeltaTime) override;

	static float SelectGroundMaxSpeed(
		bool bSprintAllowed,
		bool bBackpedaling,
		float WalkSpeed,
		float SprintSpeed);

	static FJumpTakeoff CalculateJumpTakeoff(
		const FVector& MoveAcceleration,
		float MaxAcceleration,
		float ControlYaw,
		float TakeoffSpeed,
		bool bAimSteering);

	/**
	 * Rotation mode for one move: camera facing on the ground for aim or backpedal, else travel facing;
	 * airborne, camera facing for aim unless the jump is aim tracked, never travel facing.
	 */
	static void ConfigureRotationMode(
		UCharacterMovementComponent& Movement,
		bool bFalling,
		bool bAimSteering,
		bool bBackpedaling,
		bool bTrackedJump);

	float GetBackpedalSpeedScale() const { return BackpedalSpeedScale; }
	bool IsAimTrackedJump() const { return bAimTrackedJump; }

	/** Sprint intent. Set by local input, packed into saved moves, and restored from them on the server. */
	bool bWantsToSprint = false;

	/** Aim-steering (Reticle) intent. Set by local input, packed into saved moves, and restored from them on the server. */
	bool bWantsAimSteering = false;

protected:
	virtual void UpdateFromCompressedFlags(uint8 Flags) override;
	virtual bool ClientUpdatePositionAfterServerUpdate() override;
	virtual void ControlledCharacterMove(const FVector& InputVector, float DeltaSeconds) override;
	virtual void MoveAutonomous(float ClientTimeStamp, float DeltaTime, uint8 CompressedFlags, const FVector& NewAccel) override;

	/** Provisional POC sprint speed carried over from issue #100; not a canonical tuning value. */
	UPROPERTY(EditDefaultsOnly, Category = "POC|Movement", meta = (ClampMin = "0.0", Units = "cm/s"))
	float SprintSpeed = 700.0f;

	/** Provisional POC backpedal fraction of walk speed carried over from issue #100; not a canonical tuning value. */
	UPROPERTY(EditDefaultsOnly, Category = "POC|Movement", meta = (ClampMin = "0.0", ClampMax = "1.0"))
	float BackpedalSpeedScale = 0.7f;

private:
	friend class FAethelnMovementNetSavedMoveSprintFlagTest;
	friend class FAethelnMovementNetServerSpeedClampTest;
	friend class FAethelnMovementNetInvalidSprintRejectedTest;
	friend class FAethelnMovementNetJumpTakeoffParityTest;
	friend class FAethelnMovementNetFacingSpoofBoundedTest;
	friend struct FAethelnMovementNetPredictionPair;
	friend struct FAethelnMovementNetJumpReplayScenario;

	bool IsBackpedaling() const;
	float GetSimulatedControlYaw() const;

	/** Simulation state of the current jump, set at takeoff and cleared when not falling. */
	bool bAimTrackedJump = false;
	float AimTrackedJumpYawOffset = 0.0f;
};
