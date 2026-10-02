#pragma once

#include "CoreMinimal.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "AethelnCharacterMovementComponent.generated.h"

/**
 * Project character movement. Sprint intent travels as a predicted saved-move
 * flag; the server grants sprint speed only when its own simulation agrees the
 * move is eligible, and caps backpedal speed. Jump takeoff velocity and facing
 * are set inside the simulation from the move's acceleration, so prediction,
 * correction replay and the server compute the same takeoff. Clients never send speeds.
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
	};

	virtual float GetMaxSpeed() const override;
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

	float GetBackpedalSpeedScale() const { return BackpedalSpeedScale; }

	/** Sprint intent. Set by local input, packed into saved moves, and restored from them on the server. */
	bool bWantsToSprint = false;

	/**
	 * Aim-steering intent, used here only to choose camera or travel facing at jump takeoff.
	 * Local input only: it is not packed into saved moves yet (remote facing follow-up), so the
	 * server always sees false and correction replay uses the live value.
	 */
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
	friend struct FAethelnMovementNetPredictionPair;
	friend struct FAethelnMovementNetJumpReplayScenario;

	bool IsBackpedaling() const;
	float GetSimulatedControlYaw() const;
};
