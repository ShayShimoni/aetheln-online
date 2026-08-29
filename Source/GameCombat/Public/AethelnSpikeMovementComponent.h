#pragma once

#include "CoreMinimal.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "AethelnSpikeMovementComponent.generated.h"

/** Movement telemetry seam layered onto Unreal's authoritative prediction component. */
UCLASS()
class GAMECOMBAT_API UAethelnSpikeMovementComponent final : public UCharacterMovementComponent
{
	GENERATED_BODY()

public:
	virtual void MoveAutonomous(float ClientTimeStamp, float DeltaTime, uint8 CompressedFlags, const FVector& NewAccel) override;
	static uint64 MakeMovementSequence(float TimeStamp);
	static bool ShouldEmitServerMovementRejection(bool bExceedsAllowablePositionError);

protected:
	virtual bool ServerExceedsAllowablePositionError(
		float ClientTimeStamp,
		float DeltaTime,
		const FVector& Accel,
		const FVector& ClientWorldLocation,
		const FVector& RelativeClientLocation,
		FMovementBaseInterfaceData* ClientMovementBaseInterfaceData,
		FName ClientBaseBoneName,
		uint8 ClientMovementMode) override;

	virtual void OnClientCorrectionReceived(
		FNetworkPredictionData_Client_Character& ClientData,
		float TimeStamp,
		FVector NewLocation,
		FVector NewVelocity,
		FMovementBaseInterfaceData* NewMovementBaseInterfaceData,
		FName NewBaseBoneName,
		bool bHasBase,
		bool bBaseRelativePosition,
		uint8 ServerMovementMode,
		FVector ServerGravityDirection) override;

private:
	friend class FAethelnSpikeMovementObservabilityContractTest;
	void EmitMovementObservation(bool bCorrection, bool bServerRejected, float TimeStamp) const;
};
