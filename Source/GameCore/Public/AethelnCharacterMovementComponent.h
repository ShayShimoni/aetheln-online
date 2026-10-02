#pragma once

#include "CoreMinimal.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "AethelnCharacterMovementComponent.generated.h"

/**
 * Project character movement. Sprint intent travels as a predicted saved-move
 * flag; the server grants sprint speed only when its own simulation agrees the
 * move is eligible. Clients never send speeds.
 */
UCLASS()
class GAMECORE_API UAethelnCharacterMovementComponent : public UCharacterMovementComponent
{
	GENERATED_BODY()

public:
	virtual float GetMaxSpeed() const override;
	virtual FNetworkPredictionData_Client* GetPredictionData_Client() const override;

	static float SelectGroundMaxSpeed(
		bool bSprintAllowed,
		bool bBackpedaling,
		float WalkSpeed,
		float SprintSpeed);

	/** Sprint intent. Set by local input, packed into saved moves, and restored from them on the server. */
	bool bWantsToSprint = false;

protected:
	virtual void UpdateFromCompressedFlags(uint8 Flags) override;
	virtual bool ClientUpdatePositionAfterServerUpdate() override;

	/** Provisional POC sprint speed carried over from issue #100; not a canonical tuning value. */
	UPROPERTY(EditDefaultsOnly, Category = "POC|Movement", meta = (ClampMin = "0.0", Units = "cm/s"))
	float SprintSpeed = 700.0f;

private:
	friend class FAethelnMovementNetSavedMoveSprintFlagTest;
	friend class FAethelnMovementNetServerSpeedClampTest;
	friend class FAethelnMovementNetInvalidSprintRejectedTest;

	bool IsBackpedaling() const;
};
