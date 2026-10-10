#pragma once

#include "CoreMinimal.h"
#include "UObject/Interface.h"
#include "AethelnPlayerInputReceiver.generated.h"

UINTERFACE(MinimalAPI)
class UAethelnPlayerInputReceiver : public UInterface
{
	GENERATED_BODY()
};

/**
 * Engine-neutral input contract implemented by locally controlled player pawns.
 * Client input modules may bind to this contract without leaking Enhanced Input
 * into GameCore or server targets.
 */
class GAMECORE_API IAethelnPlayerInputReceiver
{
	GENERATED_BODY()

public:
	virtual void ReceiveMoveInput(const FVector2D& MovementInput) = 0;
	virtual void ReceiveLookInput(const FVector2D& LookInput) = 0;
	virtual void ReceiveCameraZoomInput(float ZoomInput) = 0;
	virtual void ReceiveAimSteeringIntent(bool bWantsAimSteering) = 0;
	virtual void ReceiveJumpStarted() = 0;
	virtual void ReceiveJumpStopped() = 0;
	virtual void ReceiveJumpCanceled() = 0;
	virtual void ReceiveSprintIntent(bool bWantsToSprint) = 0;
	virtual void ReceiveDodgePressed() = 0;
};
