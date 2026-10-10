#pragma once

#include "CoreMinimal.h"
#include "AethelnMovementActionAuthority.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "AethelnCharacterMovementComponent.generated.h"

struct FAethelnDodgeMoveDataContainer;
struct FAethelnDodgeMoveResponseData;

/** Simulation state carried only by authoritative corrections, never restored by saved moves. */
struct GAMECORE_API FAethelnDodgeMovementState
{
	bool bInProgress = false;
	float Elapsed = 0.0f;
	FVector Direction = FVector::ZeroVector;
	uint32 ContentVersion = 0;
	float Distance = 0.0f;
	float MoveDuration = 0.0f;
};

/**
 * Project character movement. Sprint intent travels as a predicted saved-move
 * flag; the server grants sprint speed only when its own simulation agrees the
 * move is eligible, and caps backpedal speed. Jump takeoff and body facing are
 * set inside the simulation from the move's flags, acceleration and control yaw,
 * so prediction, correction replay and the server compute the same result.
 * Clients never send speeds or body rotation; facing is derived from the control
 * rotation each move already carries.
 */
UCLASS()
class GAMECORE_API UAethelnCharacterMovementComponent : public UCharacterMovementComponent
{
	GENERATED_BODY()

public:
	explicit UAethelnCharacterMovementComponent(const FObjectInitializer& ObjectInitializer = FObjectInitializer::Get());
	/** Keep generated vtable construction cleanup beside the complete private container types. */
	UAethelnCharacterMovementComponent(FVTableHelper& Helper);
	virtual ~UAethelnCharacterMovementComponent() override;

	/** Local eligibility only; no game authority exists until P3, so the default refuses. */
	bool RequestDodge();
	void EndDodgeForAuthority();
	const FAethelnDodgeMovementState& GetDodgeState() const { return DodgeState; }
	uint32 GetDodgeRequestContentVersion() const { return DodgeRequestContentVersion; }
	bool bWantsToDodge = false;

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

#if WITH_DEV_AUTOMATION_TESTS
	/** Loopback transport seam: still uses the engine's saved-move and timestamp paths. */
	TFunction<void(const FSavedMove_Character*, const FSavedMove_Character*, const FSavedMove_Character*)> TestMoveCapture;
	void TestReplicateMove(float DeltaTime, const FVector& NewAcceleration);
	bool TestReplayCorrection() { return ClientUpdatePositionAfterServerUpdate(); }
	/** Test-only views of the protected packed move/response serialization state. */
	FCharacterNetworkMoveDataContainer& TestGetNetworkMoveDataContainer() const { return GetNetworkMoveDataContainer(); }
	FCharacterMoveResponseDataContainer& TestGetMoveResponseDataContainer() const { return GetMoveResponseDataContainer(); }
	FCharacterNetworkMoveData* TestGetCurrentNetworkMoveData() const { return GetCurrentNetworkMoveData(); }
	int32 TestReceivedMoveCount = 0;
	TArray<uint8> TestReceivedMoveFlags;
	IAethelnMovementActionAuthority* TestDodgeAuthority = nullptr;
	/** Observes the ended ground dodge before the engine resumes falling physics. */
	TFunction<void(const FVector&, const FVector&)> TestDodgeGroundDepartureCapture;
	uint32 TestGetDodgeMoveContentVersion(const FCharacterNetworkMoveData& Data) const;
	void TestSetDodgeIntent(uint32 Version) { bWantsToDodge = true; DodgeRequestContentVersion = Version; }
#endif

	/** Sprint intent. Set by local input, packed into saved moves, and restored from them on the server. */
	bool bWantsToSprint = false;

	/** Aim-steering (Reticle) intent. Set by local input, packed into saved moves, and restored from them on the server. */
	bool bWantsAimSteering = false;

	/**
	 * Simulation state of the current jump: set at takeoff, cleared when not falling, and saved with each
	 * client move so correction replay restores it. Never sent to the server, which simulates its own.
	 */
	bool bAimTrackedJump = false;
	float AimTrackedJumpYawOffset = 0.0f;

protected:
	virtual void UpdateFromCompressedFlags(uint8 Flags) override;
	virtual bool ClientUpdatePositionAfterServerUpdate() override;
	virtual void ControlledCharacterMove(const FVector& InputVector, float DeltaSeconds) override;
	virtual void MoveAutonomous(float ClientTimeStamp, float DeltaTime, uint8 CompressedFlags, const FVector& NewAccel) override;
	virtual void UpdateCharacterStateBeforeMovement(float DeltaSeconds) override;
	virtual void UpdateCharacterStateAfterMovement(float DeltaSeconds) override;
	virtual void PhysWalking(float DeltaTime, int32 Iterations) override;
	virtual void CalcVelocity(float DeltaTime, float Friction, bool bFluid, float BrakingDeceleration) override;
	virtual void OnMovementModeChanged(EMovementMode PreviousMovementMode, uint8 PreviousCustomMode) override;
	PRAGMA_DISABLE_DEPRECATION_WARNINGS
	using Super::ServerMoveHandleClientError;
	using Super::OnClientCorrectionReceived;
	PRAGMA_ENABLE_DEPRECATION_WARNINGS
	virtual void ServerMoveHandleClientError(float ClientTimeStamp, float DeltaTime, const FVector& Accel, const FVector& RelativeClientLocation, FMovementBaseInterfaceData* ClientMovementBase, FName ClientBaseBoneName, uint8 ClientMovementMode) override;
	virtual void OnClientCorrectionReceived(FNetworkPredictionData_Client_Character& ClientData, float TimeStamp, FVector NewLocation, FVector NewVelocity, FMovementBaseInterfaceData* NewMovementBase, FName NewBaseBoneName, bool bHasBase, bool bBaseRelativePosition, uint8 ServerMovementMode, FVector ServerGravityDirection) override;
#if WITH_DEV_AUTOMATION_TESTS
	virtual void CallServerMovePacked(const FSavedMove_Character* NewMove, const FSavedMove_Character* PendingMove, const FSavedMove_Character* OldMove) override;
#endif

	/** Provisional POC sprint speed carried over from issue #100; not a canonical tuning value. */
	UPROPERTY(EditDefaultsOnly, Category = "POC|Movement", meta = (ClampMin = "0.0", Units = "cm/s"))
	float SprintSpeed = 700.0f;

	/** Provisional POC backpedal fraction of walk speed carried over from issue #100; not a canonical tuning value. */
	UPROPERTY(EditDefaultsOnly, Category = "POC|Movement", meta = (ClampMin = "0.0", ClampMax = "1.0"))
	float BackpedalSpeedScale = 0.7f;

private:
	friend struct FAethelnDodgeMoveResponseData;
	IAethelnMovementActionAuthority* GetDodgeAuthority() const;
	bool CanCaptureDodgePrediction() const;
	void PrepareDodgeForMove(float ClientTimeStamp, uint8 Flags, const FVector& NewAcceleration, uint32 ContentVersion);
	void FinishDodgeDisplacement(bool bPreserveHorizontalVelocity = false);
	FAethelnDodgeMovementState DodgeState;
	FAethelnDodgeMovementState PendingDodgeCorrection;
	float PendingDodgeCorrectionTimeStamp = 0.0f;
	uint32 DodgeRequestContentVersion = 0;
	bool bDodgeMovePrepared = false;
	bool bDodgeJumpSuppressedForMove = false;
	TUniquePtr<FAethelnDodgeMoveDataContainer> DodgeMoveData;
	TUniquePtr<FAethelnDodgeMoveResponseData> DodgeMoveResponse;
	friend class FAethelnMovementNetSavedMoveSprintFlagTest;
	friend class FAethelnMovementNetServerSpeedClampTest;
	friend class FAethelnMovementNetInvalidSprintRejectedTest;
	friend class FAethelnMovementNetJumpTakeoffParityTest;
	friend class FAethelnMovementNetFacingSpoofBoundedTest;
	friend class FAethelnMovementNetAimTrackingReplayTest;
	friend struct FAethelnMovementNetPredictionPair;
	friend struct FAethelnMovementNetJumpReplayScenario;

	bool IsBackpedaling() const;
	float GetSimulatedControlYaw() const;
};
