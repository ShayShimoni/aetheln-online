#pragma once

#include "AethelnPlayerCharacter.h"
#include "CoreMinimal.h"
#include "AethelnPOCInputTestFixture.generated.h"

/**
 * Test-only player character for the #82 package 82-B input tests: the real GameCore character whose input-receiver
 * methods record what the POC input component sends instead of acting on it. No WITH_DEV_AUTOMATION_TESTS guard, for
 * the reason in AethelnCombatTestAbilities.h.
 */
UCLASS(Transient, NotBlueprintable, HideDropdown)
class AAethelnPOCInputSpyCharacter : public AAethelnPlayerCharacter
{
	GENERATED_BODY()

public:
	virtual void ReceiveMoveInput(const FVector2D& MovementInput) override { MoveInputs.Add(MovementInput); }
	virtual void ReceiveLookInput(const FVector2D& LookInput) override { LookInputs.Add(LookInput); }
	virtual void ReceiveCameraZoomInput(float ZoomInput) override { ZoomInputs.Add(ZoomInput); }
	virtual void ReceiveAimSteeringIntent(bool bWantsAimSteering) override { AimSteeringIntents.Add(bWantsAimSteering); }
	virtual void ReceiveJumpStarted() override { ++JumpStartedCount; }
	virtual void ReceiveJumpStopped() override { ++JumpStoppedCount; }
	virtual void ReceiveJumpCanceled() override { ++JumpCanceledCount; }
	virtual void ReceiveSprintIntent(bool bWantsToSprint) override { SprintIntents.Add(bWantsToSprint); }
	virtual void ReceiveDodgePressed() override { ++DodgePressedCount; }

	/** Every call the input component made since the last reset. */
	int32 CallCount() const
	{
		return MoveInputs.Num() + LookInputs.Num() + ZoomInputs.Num() + AimSteeringIntents.Num() + SprintIntents.Num()
			+ JumpStartedCount + JumpStoppedCount + JumpCanceledCount + DodgePressedCount;
	}

	void ResetRecords()
	{
		MoveInputs.Reset();
		LookInputs.Reset();
		ZoomInputs.Reset();
		AimSteeringIntents.Reset();
		SprintIntents.Reset();
		JumpStartedCount = 0;
		JumpStoppedCount = 0;
		JumpCanceledCount = 0;
		DodgePressedCount = 0;
	}

	TArray<FVector2D> MoveInputs;
	TArray<FVector2D> LookInputs;
	TArray<float> ZoomInputs;
	TArray<bool> AimSteeringIntents;
	TArray<bool> SprintIntents;
	int32 JumpStartedCount = 0;
	int32 JumpStoppedCount = 0;
	int32 JumpCanceledCount = 0;
	int32 DodgePressedCount = 0;
};
