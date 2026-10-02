#include "AethelnPlayerCharacter.h"

#include "AethelnCharacterMovementComponent.h"
#include "Camera/CameraComponent.h"
#include "Components/CapsuleComponent.h"
#include "Components/SkeletalMeshComponent.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "GameFramework/Controller.h"
#include "GameFramework/SpringArmComponent.h"
#if WITH_DEV_AUTOMATION_TESTS
#include "Misc/AutomationTest.h"
#include "UObject/UnrealType.h"
#endif

namespace
{
	float CalculateCameraZoomDistance(
		float CurrentDistance,
		float ZoomInput,
		float ZoomStep,
		float MinDistance,
		float MaxDistance)
	{
		const float NearDistance = FMath::Min(MinDistance, MaxDistance);
		const float FarDistance = FMath::Max(MinDistance, MaxDistance);
		return FMath::Clamp(
			CurrentDistance - ZoomInput * FMath::Max(ZoomStep, 0.0f),
			NearDistance,
			FarDistance);
	}

	float CalculateCameraShoulderOffset(
		float CameraDistance,
		float FirstPersonDistance,
		float MaxShoulderOffset)
	{
		const float NearDistance = FMath::Max(FirstPersonDistance, 0.0f);
		const float Offset = FMath::Max(MaxShoulderOffset, 0.0f);
		return CameraDistance > NearDistance ? Offset : 0.0f;
	}

	float AdvanceCameraZoomLinearly(
		float CurrentDistance,
		float DesiredDistance,
		float DeltaSeconds,
		float ZoomSpeed)
	{
		return FMath::FInterpConstantTo(
			CurrentDistance,
			DesiredDistance,
			FMath::Max(DeltaSeconds, 0.0f),
			FMath::Max(ZoomSpeed, 0.0f));
	}

	float CalculateCameraTargetHeight(
		float CameraDistance,
		float FirstPersonDistance,
		float ThirdPersonHeight,
		float FirstPersonHeight)
	{
		const float TransitionDistance = FMath::Max(FirstPersonDistance, 0.0f);
		if (TransitionDistance <= KINDA_SMALL_NUMBER)
		{
			return FMath::Max(ThirdPersonHeight, 0.0f);
		}
		const float Alpha = FMath::Clamp(
			CameraDistance / TransitionDistance,
			0.0f,
			1.0f);
		return FMath::Lerp(
			FMath::Max(FirstPersonHeight, 0.0f),
			FMath::Max(ThirdPersonHeight, 0.0f),
			Alpha);
	}

	bool ShouldHideCharacterMeshWithHysteresis(
		bool bCurrentlyHidden,
		float RequestedCameraDistance,
		float ResolvedCameraDistance,
		float HideDistance,
		float RestoreDistance)
	{
		const float SafeHideDistance = FMath::Max(HideDistance, 0.0f);
		const float SafeRestoreDistance = FMath::Max(
			RestoreDistance,
			SafeHideDistance);
		if (!bCurrentlyHidden)
		{
			return RequestedCameraDistance <= SafeHideDistance + KINDA_SMALL_NUMBER
				|| ResolvedCameraDistance <= SafeHideDistance + KINDA_SMALL_NUMBER;
		}
		return RequestedCameraDistance < SafeRestoreDistance - KINDA_SMALL_NUMBER
			|| ResolvedCameraDistance < SafeRestoreDistance - KINDA_SMALL_NUMBER;
	}

	void ConfigureGroundRotationMode(
		UCharacterMovementComponent& Movement,
		bool bWantsAimSteering,
		bool bWantsBackpedal)
	{
		Movement.bOrientRotationToMovement =
			!bWantsAimSteering && !bWantsBackpedal;
		Movement.bUseControllerDesiredRotation =
			bWantsAimSteering || bWantsBackpedal;
	}

	void ConfigureAirborneRotationMode(
		UCharacterMovementComponent& Movement,
		bool bWantsAimSteering)
	{
		Movement.bOrientRotationToMovement = false;
		Movement.bUseControllerDesiredRotation = bWantsAimSteering;
	}

	FVector2D ApplyBackpedalSpeedScale(
		const FVector2D& MovementInput,
		float BackpedalSpeedScale)
	{
		const float DirectionalSpeedScale =
			MovementInput.Y < -KINDA_SMALL_NUMBER
				? FMath::Clamp(BackpedalSpeedScale, 0.0f, 1.0f)
				: 1.0f;
		return MovementInput * DirectionalSpeedScale;
	}

	bool IsBufferedJumpReady(
		bool bHasBufferedJump,
		double BufferedJumpExpiryTime,
		double CurrentTime)
	{
		return bHasBufferedJump
			&& CurrentTime <= BufferedJumpExpiryTime;
	}

	FVector CalculateJumpHorizontalVelocity(
		const FVector2D& MovementInput,
		const FRotator& ControlRotation,
		float MaxGroundSpeed,
		float BackpedalSpeedScale)
	{
		const FVector2D SpeedAdjustedInput =
			ApplyBackpedalSpeedScale(
				MovementInput.GetClampedToMaxSize(1.0f),
				BackpedalSpeedScale);
		const FRotator YawRotation(
			0.0f,
			ControlRotation.Yaw,
			0.0f);
		const FVector ForwardDirection =
			FRotationMatrix(YawRotation).GetUnitAxis(EAxis::X);
		const FVector RightDirection =
			FRotationMatrix(YawRotation).GetUnitAxis(EAxis::Y);
		return (
			ForwardDirection * SpeedAdjustedInput.Y
			+ RightDirection * SpeedAdjustedInput.X)
			* MaxGroundSpeed;
	}

	bool ShouldSnapJumpFacing(
		const FVector2D& MovementInput)
	{
		return !MovementInput.IsNearlyZero();
	}

	bool ShouldUseControllerJumpFacing(
		bool bWantsAimSteering,
		bool bWantsBackpedal,
		const FVector2D& MovementInput)
	{
		const FVector2D ClampedInput =
			MovementInput.GetClampedToMaxSize(1.0f);
		const bool bPureLateralAimJump =
			bWantsAimSteering
			&& FMath::Abs(ClampedInput.X) > KINDA_SMALL_NUMBER
			&& FMath::Abs(ClampedInput.Y) <= KINDA_SMALL_NUMBER;
		return bWantsBackpedal
			|| (bWantsAimSteering && !bPureLateralAimJump);
	}


	float CalculateAimJumpFacingOffset(
		float BodyYaw,
		float ControlYaw)
	{
		return FRotator::NormalizeAxis(
			BodyYaw - ControlYaw);
	}

	float CalculateAimJumpTrackedYaw(
		float ControlYaw,
		float FacingOffset)
	{
		return FRotator::NormalizeAxis(
			ControlYaw + FacingOffset);
	}

	float CalculateControllerJumpFacingYaw(
		const FRotator& ControlRotation)
	{
		return ControlRotation.Yaw;
	}

	float CalculateJumpFacingYaw(
		const FVector& HorizontalVelocity)
	{
		return HorizontalVelocity.IsNearlyZero()
			? 0.0f
			: HorizontalVelocity.Rotation().Yaw;
	}

	float CalculateAimJumpPresentationYaw(
		bool bWantsAimSteering,
		const FVector2D& MovementInput,
		float MaxPresentationYaw)
	{
		const FVector2D ClampedInput =
			MovementInput.GetClampedToMaxSize(1.0f);
		return bWantsAimSteering
			&& ClampedInput.Y > KINDA_SMALL_NUMBER
			? ClampedInput.X
				* MaxPresentationYaw
			: 0.0f;
	}

	float CalculateGroundAimPresentationYaw(
		bool bWantsAimSteering,
		const FVector2D& MovementInput,
		float MaxPresentationYaw)
	{
		return bWantsAimSteering
			? MovementInput.GetClampedToMaxSize(1.0f).X
				* MaxPresentationYaw
			: 0.0f;
	}
}

#if WITH_DEV_AUTOMATION_TESTS
IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnPOCCameraZoomTest,
	"Aetheln.POC.Camera.MouseWheelZoom",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPOCCameraZoomTest::RunTest(const FString& Parameters)
{
	constexpr float MinDistance = 0.0f;
	constexpr float MaxDistance = 700.0f;
	constexpr float ZoomStep = 40.0f;

	TestEqual(
		TEXT("Wheel up moves the camera one bounded step closer"),
		CalculateCameraZoomDistance(
			400.0f, 1.0f, ZoomStep, MinDistance, MaxDistance),
		360.0f);
	TestEqual(
		TEXT("Wheel down moves the camera one small step farther"),
		CalculateCameraZoomDistance(
			400.0f, -1.0f, ZoomStep, MinDistance, MaxDistance),
		440.0f);
	TestEqual(
		TEXT("Zooming out from first person uses the same small step"),
		CalculateCameraZoomDistance(
			0.0f, -1.0f, ZoomStep, MinDistance, MaxDistance),
		40.0f);
	TestEqual(
		TEXT("Zoom in cannot pass the near limit"),
		CalculateCameraZoomDistance(
			10.0f, 1.0f, ZoomStep, MinDistance, MaxDistance),
		MinDistance);
	TestEqual(
		TEXT("Zoom out cannot pass the far limit"),
		CalculateCameraZoomDistance(
			695.0f, -1.0f, ZoomStep, MinDistance, MaxDistance),
		MaxDistance);
	TestEqual(
		TEXT("No wheel input preserves the current distance"),
		CalculateCameraZoomDistance(
			400.0f, 0.0f, ZoomStep, MinDistance, MaxDistance),
		400.0f);
	AAethelnPlayerCharacter* Character =
		NewObject<AAethelnPlayerCharacter>();
	const FFloatProperty* MinZoomProperty = FindFProperty<FFloatProperty>(
		AAethelnPlayerCharacter::StaticClass(),
		TEXT("CameraZoomMinDistance"));
	TestNotNull(TEXT("Minimum zoom distance remains configurable"), MinZoomProperty);
	if (MinZoomProperty != nullptr)
	{
		TestEqual(
			TEXT("POC camera can reach its first-person-like endpoint"),
			MinZoomProperty->GetPropertyValue_InContainer(Character),
			MinDistance);
	}
	const FFloatProperty* MaxZoomProperty = FindFProperty<FFloatProperty>(
		AAethelnPlayerCharacter::StaticClass(),
		TEXT("CameraZoomMaxDistance"));
	const FFloatProperty* ZoomStepProperty = FindFProperty<FFloatProperty>(
		AAethelnPlayerCharacter::StaticClass(),
		TEXT("CameraZoomStep"));
	TestNotNull(TEXT("Maximum zoom distance remains configurable"), MaxZoomProperty);
	TestNotNull(TEXT("Zoom step remains configurable"), ZoomStepProperty);
	if (MaxZoomProperty != nullptr)
	{
		TestEqual(
			TEXT("POC camera supports the approved far view"),
			MaxZoomProperty->GetPropertyValue_InContainer(Character),
			MaxDistance);
	}
	if (ZoomStepProperty != nullptr)
	{
		TestEqual(
			TEXT("POC zoom uses the approved small step in both directions"),
			ZoomStepProperty->GetPropertyValue_InContainer(Character),
			ZoomStep);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnPOCCloseCameraTest,
	"Aetheln.POC.Camera.CloseShoulderOffset",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPOCCloseCameraTest::RunTest(const FString& Parameters)
{
	constexpr float FirstPersonDistance = 50.0f;
	constexpr float MaxShoulderOffset = 50.0f;

	TestEqual(
		TEXT("Far third-person camera keeps Quinn clear of the reticle"),
		CalculateCameraShoulderOffset(
			400.0f,
			FirstPersonDistance,
			MaxShoulderOffset),
		MaxShoulderOffset);
	TestEqual(
		TEXT("Close third-person framing remains shouldered"),
		CalculateCameraShoulderOffset(
			100.0f,
			FirstPersonDistance,
			MaxShoulderOffset),
		MaxShoulderOffset);
	TestEqual(
		TEXT("First-person threshold recenters the camera"),
		CalculateCameraShoulderOffset(
			FirstPersonDistance,
			FirstPersonDistance,
			MaxShoulderOffset),
		0.0f);
	TestTrue(
		TEXT("Every visible third-person frame uses positive local-right offset"),
		CalculateCameraShoulderOffset(
			50.01f,
			FirstPersonDistance,
			MaxShoulderOffset) > 0.0f);
	TestEqual(
		TEXT("Negative offset tuning cannot reverse the framing side"),
		CalculateCameraShoulderOffset(
			100.0f,
			FirstPersonDistance,
			-MaxShoulderOffset),
		0.0f);
	TestEqual(
		TEXT("Wheel zoom advances by constant linear distance"),
		AdvanceCameraZoomLinearly(400.0f, 390.0f, 0.05f, 100.0f),
		395.0f);
	TestEqual(
		TEXT("Linear zoom stops exactly at the requested distance"),
		AdvanceCameraZoomLinearly(395.0f, 390.0f, 0.1f, 100.0f),
		390.0f);
	TestEqual(
		TEXT("A new wheel event replaces queued travel with one current step"),
		CalculateCameraZoomDistance(
			395.0f, 1.0f, 40.0f, 0.0f, 700.0f),
		355.0f);
	TestEqual(
		TEXT("Third-person aim pivot keeps the reticle above Quinn"),
		CalculateCameraTargetHeight(400.0f, 50.0f, 120.0f, 70.0f),
		120.0f);
	TestEqual(
		TEXT("Hidden first-person transition lowers the camera linearly"),
		CalculateCameraTargetHeight(25.0f, 50.0f, 120.0f, 70.0f),
		95.0f);
	TestEqual(
		TEXT("First-person endpoint returns to eye-level framing"),
		CalculateCameraTargetHeight(0.0f, 50.0f, 120.0f, 70.0f),
		70.0f);
	TestTrue(
		TEXT("Requested first-person zoom hides Quinn"),
		ShouldHideCharacterMeshWithHysteresis(
			false, 50.0f, 120.0f, 50.0f, 60.0f));
	TestTrue(
		TEXT("Collision-compressed first-person distance hides Quinn"),
		ShouldHideCharacterMeshWithHysteresis(
			false, 400.0f, 50.0f, 50.0f, 60.0f));
	TestTrue(
		TEXT("Hysteresis keeps Quinn hidden before both distances recover"),
		ShouldHideCharacterMeshWithHysteresis(
			true, 400.0f, 55.0f, 50.0f, 60.0f));
	TestFalse(
		TEXT("Quinn returns after requested and resolved distances recover"),
		ShouldHideCharacterMeshWithHysteresis(
			true, 60.0f, 60.0f, 50.0f, 60.0f));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnPOCRotationModeTest,
	"Aetheln.POC.Movement.RotationModes",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPOCRotationModeTest::RunTest(const FString& Parameters)
{
	UCharacterMovementComponent* Movement =
		NewObject<UCharacterMovementComponent>();

	ConfigureGroundRotationMode(*Movement, false, false);
	TestTrue(
		TEXT("Movement without aim steering faces travel direction"),
		Movement->bOrientRotationToMovement);
	TestFalse(
		TEXT("Movement without aim steering ignores controller yaw"),
		Movement->bUseControllerDesiredRotation);

	ConfigureGroundRotationMode(*Movement, false, true);
	TestFalse(
		TEXT("Backpedaling does not face the reverse travel direction"),
		Movement->bOrientRotationToMovement);
	TestTrue(
		TEXT("Backpedaling realigns facing to camera-forward"),
		Movement->bUseControllerDesiredRotation);

	ConfigureGroundRotationMode(*Movement, true, true);
	TestFalse(
		TEXT("Reticle aim preserves camera-facing strafing"),
		Movement->bOrientRotationToMovement);
	TestTrue(
		TEXT("Reticle aim steers character with controller yaw"),
		Movement->bUseControllerDesiredRotation);

	ConfigureAirborneRotationMode(*Movement, false);
	TestFalse(
		TEXT("Airborne movement cannot rotate toward movement input"),
		Movement->bOrientRotationToMovement);
	TestFalse(
		TEXT("Free airborne movement preserves takeoff facing"),
		Movement->bUseControllerDesiredRotation);

	ConfigureAirborneRotationMode(*Movement, true);
	TestFalse(
		TEXT("Airborne aim never rotates toward movement input"),
		Movement->bOrientRotationToMovement);
	TestTrue(
		TEXT("Airborne aim may rotate facing toward camera yaw"),
		Movement->bUseControllerDesiredRotation);

	const FVector2D DiagonalInput(UE_INV_SQRT_2, UE_INV_SQRT_2);
	TestTrue(
		TEXT("Aim-jump presentation turns only slightly toward takeoff"),
		FMath::IsNearlyEqual(
			CalculateAimJumpPresentationYaw(
				true,
				DiagonalInput,
				25.0f),
			25.0f * UE_INV_SQRT_2));
	TestEqual(
		TEXT("Pure-lateral RMB jump does not add aim presentation yaw"),
		CalculateAimJumpPresentationYaw(
			true,
			FVector2D(1.0, 0.0),
			25.0f),
		0.0f);
	TestEqual(
		TEXT("Backward RMB jump does not add aim presentation yaw"),
		CalculateAimJumpPresentationYaw(
			true,
			FVector2D(UE_INV_SQRT_2, -UE_INV_SQRT_2),
			25.0f),
		0.0f);
	TestEqual(
		TEXT("Free jumps do not add presentation-only mesh yaw"),
		CalculateAimJumpPresentationYaw(
			false,
			DiagonalInput,
			25.0f),
		0.0f);
	TestEqual(
		TEXT("Pure-right RMB strafe uses the stronger ground body angle"),
		CalculateGroundAimPresentationYaw(
			true,
			FVector2D(1.0f, 0.0f),
			35.0f),
		35.0f);
	TestEqual(
		TEXT("Pure-left RMB strafe mirrors the stronger ground body angle"),
		CalculateGroundAimPresentationYaw(
			true,
			FVector2D(-1.0f, 0.0f),
			35.0f),
		-35.0f);
	TestTrue(
		TEXT("Forward-diagonal RMB strafe uses a proportional body angle"),
		FMath::IsNearlyEqual(
			CalculateGroundAimPresentationYaw(
				true,
				DiagonalInput,
				35.0f),
			35.0f * UE_INV_SQRT_2));
	TestEqual(
		TEXT("Free movement does not add ground mesh yaw"),
		CalculateGroundAimPresentationYaw(
			false,
			FVector2D(1.0f, 0.0f),
			35.0f),
		0.0f);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnPOCBackpedalSpeedTest,
	"Aetheln.POC.Movement.BackpedalSpeed",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPOCBackpedalSpeedTest::RunTest(const FString& Parameters)
{
	constexpr float BackpedalSpeedScale = 0.7f;
	const FVector2D ForwardInput =
		ApplyBackpedalSpeedScale(FVector2D(0.0f, 1.0f), BackpedalSpeedScale);
	TestEqual(
		TEXT("Forward movement keeps full speed"),
		ForwardInput.Size(),
		1.0);

	const FVector2D BackwardInput =
		ApplyBackpedalSpeedScale(FVector2D(0.0f, -1.0f), BackpedalSpeedScale);
	TestEqual(
		TEXT("Backward movement uses seventy percent speed"),
		BackwardInput.Size(),
		0.7);

	const FVector2D BackwardDiagonal =
		ApplyBackpedalSpeedScale(
			FVector2D(-UE_INV_SQRT_2, -UE_INV_SQRT_2),
			BackpedalSpeedScale);
	TestTrue(
		TEXT("Backward diagonal movement preserves its direction"),
		BackwardDiagonal.GetSafeNormal().Equals(
			FVector2D(-UE_INV_SQRT_2, -UE_INV_SQRT_2)));
	TestEqual(
		TEXT("Backward diagonal movement uses the same reduced speed"),
		BackwardDiagonal.Size(),
		0.7);

	TestEqual(
		TEXT("Forward movement may use sprint speed"),
		UAethelnCharacterMovementComponent::SelectGroundMaxSpeed(true, false, 500.0f, 700.0f),
		700.0f);
	TestEqual(
		TEXT("Backward movement cannot sprint"),
		UAethelnCharacterMovementComponent::SelectGroundMaxSpeed(true, true, 500.0f, 700.0f),
		500.0f);
	TestEqual(
		TEXT("Backward sprint intent remains capped at 350 cm/s"),
		BackwardInput.Size()
			* UAethelnCharacterMovementComponent::SelectGroundMaxSpeed(
				true,
				true,
				500.0f,
				700.0f),
		350.0);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnPOCJumpBufferTest,
	"Aetheln.POC.Movement.JumpBuffer",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPOCJumpBufferTest::RunTest(const FString& Parameters)
{
	TestTrue(
		TEXT("A recent airborne jump press is consumed on landing"),
		IsBufferedJumpReady(true, 10.20, 10.10));
	TestFalse(
		TEXT("An expired airborne jump press is ignored"),
		IsBufferedJumpReady(true, 10.20, 10.21));
	TestFalse(
		TEXT("Landing without a buffered press does not jump"),
		IsBufferedJumpReady(false, 10.20, 10.10));

	const FVector LeftTakeoffVelocity =
		CalculateJumpHorizontalVelocity(
			FVector2D(-1.0, 0.0),
			FRotator::ZeroRotator,
			500.0f,
			0.7f);
	TestTrue(
		TEXT("Latest held left input replaces the previous rightward velocity"),
		LeftTakeoffVelocity.Equals(FVector(0.0, -500.0, 0.0)));

	const FVector BackwardTakeoffVelocity =
		CalculateJumpHorizontalVelocity(
			FVector2D(0.0, -1.0),
			FRotator::ZeroRotator,
			500.0f,
			0.7f);
	TestTrue(
		TEXT("Buffered backward takeoff respects backpedal speed"),
		BackwardTakeoffVelocity.Equals(FVector(-350.0, 0.0, 0.0)));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnPOCJumpFacingTest,
	"Aetheln.POC.Movement.JumpFacing",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPOCJumpFacingTest::RunTest(const FString& Parameters)
{
	TestTrue(
		TEXT("Free jump chains snap body facing to takeoff direction"),
		ShouldSnapJumpFacing(
			FVector2D(-1.0, 0.0)));
	TestEqual(
		TEXT("A leftward takeoff faces left immediately"),
		CalculateJumpFacingYaw(FVector(0.0, -500.0, 0.0)),
		-90.0f);
	TestTrue(
		TEXT("Aim jumps snap base body to camera-facing"),
		ShouldSnapJumpFacing(
			FVector2D(-1.0, 0.0)));
	TestTrue(
		TEXT("Backward jumps snap base body to camera-forward"),
		ShouldSnapJumpFacing(
			FVector2D(0.0, -1.0)));
	TestTrue(
		TEXT("Forward-diagonal aim jump facing uses controller yaw"),
		ShouldUseControllerJumpFacing(
			true,
			false,
			FVector2D(UE_INV_SQRT_2, UE_INV_SQRT_2)));
	TestFalse(
		TEXT("Pure-lateral aim jump facing uses travel yaw"),
		ShouldUseControllerJumpFacing(
			true,
			false,
			FVector2D(1.0f, 0.0f)));
	TestTrue(
		TEXT("Backward jump facing uses controller yaw"),
		ShouldUseControllerJumpFacing(
			false,
			true,
			FVector2D(0.0f, -1.0f)));
	TestFalse(
		TEXT("Free lateral jump facing uses travel yaw"),
		ShouldUseControllerJumpFacing(
			false,
			false,
			FVector2D(-1.0f, 0.0f)));
	TestEqual(
		TEXT("Controller-facing jumps snap to camera-forward yaw"),
		CalculateControllerJumpFacingYaw(
			FRotator(20.0f, 35.0f, 10.0f)),
		35.0f);
	TestFalse(
		TEXT("Stationary jumps preserve current facing"),
		ShouldSnapJumpFacing(
			FVector2D::ZeroVector));
	const float RightJumpFacingOffset =
		CalculateAimJumpFacingOffset(90.0f, 0.0f);
	TestEqual(
		TEXT("Rightward RMB jump retains its sideways takeoff offset"),
		RightJumpFacingOffset,
		90.0f);
	TestEqual(
		TEXT("Airborne RMB camera yaw turns the sideways body by the same delta"),
		CalculateAimJumpTrackedYaw(35.0f, RightJumpFacingOffset),
		125.0f);
	TestEqual(
		TEXT("Airborne RMB tracking normalizes across the yaw boundary"),
		CalculateAimJumpTrackedYaw(
			-175.0f,
			CalculateAimJumpFacingOffset(-170.0f, 170.0f)),
		-155.0f);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnPOCResponsiveMovementSettingsTest,
	"Aetheln.POC.Movement.ResponsiveSettings",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPOCResponsiveMovementSettingsTest::RunTest(
	const FString& Parameters)
{
	const AAethelnPlayerCharacter* Character =
		GetDefault<AAethelnPlayerCharacter>();
	const UCharacterMovementComponent* Movement =
		Character->GetCharacterMovement();
	const FFloatProperty* AimJumpYawProperty =
		FindFProperty<FFloatProperty>(
			AAethelnPlayerCharacter::StaticClass(),
			TEXT("MaxAimJumpPresentationYaw"));
	const FFloatProperty* GroundAimYawProperty =
		FindFProperty<FFloatProperty>(
			AAethelnPlayerCharacter::StaticClass(),
			TEXT("MaxGroundAimPresentationYaw"));

	TestEqual(
		TEXT("Ground travel-facing turns use the smoother visual rate"),
		Movement->RotationRate.Yaw,
		720.0);
	TestEqual(
		TEXT("Direction changes use the responsive acceleration"),
		Movement->MaxAcceleration,
		10000.0f);
	TestEqual(
		TEXT("Ground direction changes use responsive friction"),
		Movement->GroundFriction,
		16.0f);
	TestEqual(
		TEXT("Airborne trajectory is locked after takeoff"),
		Movement->AirControl,
		0.0f);
	TestEqual(
		TEXT("Locked airborne trajectory preserves takeoff momentum"),
		Movement->BrakingDecelerationFalling,
		0.0f);
	TestNotNull(
		TEXT("Aim-jump yaw tuning remains reflected"),
		AimJumpYawProperty);
	if (AimJumpYawProperty != nullptr)
	{
		TestEqual(
			TEXT("Aim-diagonal jump presentation uses the stronger turn"),
			AimJumpYawProperty->GetPropertyValue_InContainer(
				Character),
			25.0f);
	}
	TestNotNull(
		TEXT("Ground aim-strafe yaw tuning remains reflected"),
		GroundAimYawProperty);
	if (GroundAimYawProperty != nullptr)
	{
		TestEqual(
			TEXT("Pure grounded RMB strafe uses the stronger body angle"),
			GroundAimYawProperty->GetPropertyValue_InContainer(
				Character),
			35.0f);
	}
	return true;
}
#endif

AAethelnPlayerCharacter::AAethelnPlayerCharacter(
	const FObjectInitializer& ObjectInitializer)
	: Super(ObjectInitializer.SetDefaultSubobjectClass<UAethelnCharacterMovementComponent>(
		ACharacter::CharacterMovementComponentName))
{
	PrimaryActorTick.bCanEverTick = true;

	GetCapsuleComponent()->InitCapsuleSize(42.0f, 96.0f);

	bUseControllerRotationPitch = false;
	bUseControllerRotationYaw = false;
	bUseControllerRotationRoll = false;

	UCharacterMovementComponent* Movement = GetCharacterMovement();
	ConfigureGroundRotationMode(*Movement, false, false);
	Movement->RotationRate = FRotator(0.0f, 720.0f, 0.0f);
	Movement->JumpZVelocity = 500.0f;
	Movement->AirControl = 0.0f;
	Movement->MaxAcceleration = 10000.0f;
	Movement->GroundFriction = 16.0f;
	Movement->MaxWalkSpeed = WalkSpeed;
	Movement->MinAnalogWalkSpeed = 20.0f;
	Movement->BrakingDecelerationWalking = 2000.0f;
	Movement->BrakingDecelerationFalling = 0.0f;
	Movement->MaxStepHeight = 45.0f;

	CameraBoom = CreateDefaultSubobject<USpringArmComponent>(TEXT("CameraBoom"));
	CameraBoom->SetupAttachment(RootComponent);
	CameraBoom->TargetArmLength = 400.0f;
	CameraBoom->bUsePawnControlRotation = true;
	CameraBoom->bEnableCameraLag = false;
	CameraBoom->bDoCollisionTest = true;
	CameraBoom->SocketOffset = FVector::ZeroVector;
	CameraBoom->TargetOffset = FVector(0.0f, 0.0f, 70.0f);

	FollowCamera = CreateDefaultSubobject<UCameraComponent>(TEXT("FollowCamera"));
	FollowCamera->SetupAttachment(CameraBoom, USpringArmComponent::SocketName);
	FollowCamera->bUsePawnControlRotation = false;
	FollowCamera->FieldOfView = 90.0f;
}

void AAethelnPlayerCharacter::BeginPlay()
{
	Super::BeginPlay();
	GetCharacterMovement()->MaxWalkSpeed = WalkSpeed;
	BaseMeshRelativeYaw = GetMesh()->GetRelativeRotation().Yaw;
	DesiredCameraZoomDistance = CameraBoom->TargetArmLength;
	UpdateCameraPresentation(0.0f);
	if (GetNetMode() == NM_DedicatedServer)
	{
		SetActorTickEnabled(false);
	}
}

void AAethelnPlayerCharacter::Tick(float DeltaSeconds)
{
	Super::Tick(DeltaSeconds);
	if (!IsLocallyControlled())
	{
		return;
	}
	UpdateAirborneAimFacing();
	UpdateMovementPresentation(DeltaSeconds);
	UpdateCameraPresentation(DeltaSeconds);
}

void AAethelnPlayerCharacter::ReceiveMoveInput(const FVector2D& MovementInput)
{
	if (Controller == nullptr)
	{
		return;
	}

	const FVector2D ClampedInput = MovementInput.GetClampedToMaxSize(1.0f);
	const FVector2D SpeedAdjustedInput =
		ApplyBackpedalSpeedScale(ClampedInput, BackpedalSpeedScale);
	LastMovementInput = ClampedInput;
	bWantsBackpedal = ClampedInput.Y < -KINDA_SMALL_NUMBER;
	if (!GetCharacterMovement()->IsFalling())
	{
		ApplyCurrentGroundRotationMode();
	}

	const FRotator YawRotation = GetMovementReferenceRotation();

	const FVector ForwardDirection = FRotationMatrix(YawRotation).GetUnitAxis(EAxis::X);
	const FVector RightDirection = FRotationMatrix(YawRotation).GetUnitAxis(EAxis::Y);

	AddMovementInput(ForwardDirection, SpeedAdjustedInput.Y);
	AddMovementInput(RightDirection, SpeedAdjustedInput.X);
}

void AAethelnPlayerCharacter::ReceiveLookInput(const FVector2D& LookInput)
{
	AddControllerYawInput(LookInput.X);
	AddControllerPitchInput(LookInput.Y);
}

void AAethelnPlayerCharacter::ReceiveCameraZoomInput(float ZoomInput)
{
	if (CameraBoom == nullptr)
	{
		return;
	}

	DesiredCameraZoomDistance = CalculateCameraZoomDistance(
		CameraBoom->TargetArmLength,
		ZoomInput,
		CameraZoomStep,
		CameraZoomMinDistance,
		CameraZoomMaxDistance);
}

void AAethelnPlayerCharacter::ReceiveAimSteeringIntent(bool bWantsAimSteering)
{
	ApplyAimSteeringIntent(bWantsAimSteering);
}

void AAethelnPlayerCharacter::ReceiveJumpStarted()
{
	if (GetCharacterMovement()->IsFalling())
	{
		bHasBufferedJump = true;
		const UWorld* World = GetWorld();
		const double CurrentTime =
			World != nullptr ? World->GetTimeSeconds() : 0.0;
		BufferedJumpExpiryTime =
			CurrentTime + JumpBufferDuration;
		return;
	}

	ClearBufferedJumpRequest();
	ApplyCurrentJumpHorizontalVelocity();
	bTravelFacingAimJumpActive =
		bAimSteeringActive
		&& !ShouldUseControllerJumpFacing(
			true,
			bWantsBackpedal,
			LastMovementInput);
	ApplyCurrentJumpFacing();
	CaptureTravelFacingAimJumpOffset();
	PendingJumpPresentationYaw = CalculateAimJumpPresentationYaw(
		bAimSteeringActive,
		LastMovementInput,
		MaxAimJumpPresentationYaw);
	Jump();
}

void AAethelnPlayerCharacter::ReceiveJumpStopped()
{
	StopJumping();
}

void AAethelnPlayerCharacter::ReceiveJumpCanceled()
{
	ClearBufferedJumpRequest();
	StopJumping();
}

void AAethelnPlayerCharacter::ReceiveSprintIntent(bool bWantsToSprint)
{
	ApplySprintIntent(bWantsToSprint);
}

void AAethelnPlayerCharacter::UnPossessed()
{
	GetMesh()->SetOwnerNoSee(false);
	bCameraMeshHidden = false;
	ResetMovementPresentation(true);
	ClearBufferedJumpRequest();
	LastMovementInput = FVector2D::ZeroVector;
	bWantsBackpedal = false;
	bTravelFacingAimJumpActive = false;
	TravelFacingAimJumpOffset = 0.0f;
	ApplyAimSteeringIntent(false);
	ApplySprintIntent(false);
	StopJumping();
	Super::UnPossessed();
}

void AAethelnPlayerCharacter::EndPlay(const EEndPlayReason::Type EndPlayReason)
{
	GetMesh()->SetOwnerNoSee(false);
	bCameraMeshHidden = false;
	ResetMovementPresentation(true);
	ClearBufferedJumpRequest();
	LastMovementInput = FVector2D::ZeroVector;
	bWantsBackpedal = false;
	bTravelFacingAimJumpActive = false;
	TravelFacingAimJumpOffset = 0.0f;
	ApplyAimSteeringIntent(false);
	ApplySprintIntent(false);
	StopJumping();
	Super::EndPlay(EndPlayReason);
}

void AAethelnPlayerCharacter::OnJumped_Implementation()
{
	Super::OnJumped_Implementation();
	LockedJumpPresentationYaw = PendingJumpPresentationYaw;
	bJumpPresentationActive =
		!FMath::IsNearlyZero(LockedJumpPresentationYaw);
	if (bTravelFacingAimJumpActive)
	{
		CurrentPresentationYaw = 0.0f;
		FRotator MeshRotation = GetMesh()->GetRelativeRotation();
		MeshRotation.Yaw = BaseMeshRelativeYaw;
		GetMesh()->SetRelativeRotation(MeshRotation);
	}
}

void AAethelnPlayerCharacter::OnMovementModeChanged(
	EMovementMode PrevMovementMode,
	uint8 PreviousCustomMode)
{
	Super::OnMovementModeChanged(
		PrevMovementMode,
		PreviousCustomMode);

	UCharacterMovementComponent* Movement = GetCharacterMovement();
	if (Movement->IsFalling())
	{
		ConfigureAirborneRotationMode(
			*Movement,
			bAimSteeringActive
				&& !bTravelFacingAimJumpActive);
		return;
	}

	bTravelFacingAimJumpActive = false;
	TravelFacingAimJumpOffset = 0.0f;
	PendingJumpPresentationYaw = 0.0f;
	LockedJumpPresentationYaw = 0.0f;
	bJumpPresentationActive = false;
	ApplyCurrentGroundRotationMode();
	if (PrevMovementMode == MOVE_Falling
		&& Movement->IsMovingOnGround())
	{
		TryConsumeBufferedJump();
	}
}

void AAethelnPlayerCharacter::ApplyAimSteeringIntent(bool bWantsAimSteering)
{
	const bool bWasAimSteeringActive = bAimSteeringActive;
	bAimSteeringActive = bWantsAimSteering;
	UCharacterMovementComponent* Movement = GetCharacterMovement();
	if (Movement->IsFalling())
	{
		if (bAimSteeringActive
			&& !bWasAimSteeringActive
			&& bTravelFacingAimJumpActive)
		{
			CaptureTravelFacingAimJumpOffset();
		}
		ConfigureAirborneRotationMode(
			*Movement,
			bAimSteeringActive
				&& !bTravelFacingAimJumpActive);
		return;
	}

	ApplyCurrentGroundRotationMode();
}

void AAethelnPlayerCharacter::CaptureTravelFacingAimJumpOffset()
{
	if (!bTravelFacingAimJumpActive
		|| Controller == nullptr)
	{
		return;
	}

	TravelFacingAimJumpOffset =
		CalculateAimJumpFacingOffset(
			GetActorRotation().Yaw,
			Controller->GetControlRotation().Yaw);
}

void AAethelnPlayerCharacter::UpdateCameraPresentation(float DeltaSeconds)
{
	if (CameraBoom == nullptr || FollowCamera == nullptr || GetMesh() == nullptr
		|| !IsLocallyControlled())
	{
		return;
	}
	CameraBoom->TargetArmLength = AdvanceCameraZoomLinearly(
		CameraBoom->TargetArmLength,
		DesiredCameraZoomDistance,
		DeltaSeconds,
		CameraZoomTransitionSpeed);
	CameraBoom->TargetOffset.Z = CalculateCameraTargetHeight(
		CameraBoom->TargetArmLength,
		FirstPersonMeshHideDistance,
		ThirdPersonCameraTargetHeight,
		FirstPersonCameraTargetHeight);

	CameraBoom->SocketOffset = FVector(
		0.0f,
		CalculateCameraShoulderOffset(
			CameraBoom->TargetArmLength,
			FirstPersonMeshHideDistance,
			CameraShoulderMaxOffset),
		0.0f);
	const FVector BoomPivot =
		CameraBoom->GetComponentLocation() + CameraBoom->TargetOffset;
	const float ResolvedCameraDistance = FVector::Distance(
		FollowCamera->GetComponentLocation(),
		BoomPivot);
	bCameraMeshHidden = ShouldHideCharacterMeshWithHysteresis(
		bCameraMeshHidden,
		CameraBoom->TargetArmLength,
		ResolvedCameraDistance,
		FirstPersonMeshHideDistance,
		FirstPersonMeshRestoreDistance);
	GetMesh()->SetOwnerNoSee(bCameraMeshHidden);
}

void AAethelnPlayerCharacter::ApplyCurrentGroundRotationMode()
{
	if (UCharacterMovementComponent* Movement = GetCharacterMovement())
	{
		ConfigureGroundRotationMode(
			*Movement,
			bAimSteeringActive,
			bWantsBackpedal);
	}
}

void AAethelnPlayerCharacter::ApplyCurrentJumpHorizontalVelocity()
{
	UCharacterMovementComponent* Movement = GetCharacterMovement();
	if (Movement == nullptr
		|| Controller == nullptr
		|| LastMovementInput.IsNearlyZero())
	{
		return;
	}

	const FVector HorizontalVelocity =
		CalculateJumpHorizontalVelocity(
			LastMovementInput,
			GetMovementReferenceRotation(),
			Movement->GetMaxSpeed(),
			BackpedalSpeedScale);
	Movement->Velocity.X = HorizontalVelocity.X;
	Movement->Velocity.Y = HorizontalVelocity.Y;
}

void AAethelnPlayerCharacter::ApplyCurrentJumpFacing()
{
	if (!ShouldSnapJumpFacing(LastMovementInput))
	{
		return;
	}

	const UCharacterMovementComponent* Movement =
		GetCharacterMovement();
	const FVector HorizontalVelocity(
		Movement->Velocity.X,
		Movement->Velocity.Y,
		0.0);
	const bool bUseControllerFacing =
		ShouldUseControllerJumpFacing(
			bAimSteeringActive,
			bWantsBackpedal,
			LastMovementInput);
	if (bUseControllerFacing && Controller == nullptr)
	{
		return;
	}
	if (!bUseControllerFacing
		&& HorizontalVelocity.IsNearlyZero())
	{
		return;
	}

	FRotator FacingRotation = GetActorRotation();
	FacingRotation.Pitch = 0.0f;
	FacingRotation.Yaw = bUseControllerFacing
		? CalculateControllerJumpFacingYaw(
			bAimSteeringActive
				? Controller->GetControlRotation()
				: GetMovementReferenceRotation())
		: CalculateJumpFacingYaw(HorizontalVelocity);
	FacingRotation.Roll = 0.0f;
	SetActorRotation(
		FacingRotation,
		ETeleportType::TeleportPhysics);
}

FRotator AAethelnPlayerCharacter::GetMovementReferenceRotation() const
{
	const float ControlYaw = Controller != nullptr
		? Controller->GetControlRotation().Yaw
		: GetActorRotation().Yaw;
	return FRotator(0.0f, ControlYaw, 0.0f);
}

void AAethelnPlayerCharacter::ClearBufferedJumpRequest()
{
	bHasBufferedJump = false;
	BufferedJumpExpiryTime = 0.0;
}

void AAethelnPlayerCharacter::TryConsumeBufferedJump()
{
	const UWorld* World = GetWorld();
	const double CurrentTime =
		World != nullptr ? World->GetTimeSeconds() : 0.0;
	const bool bShouldJump = IsBufferedJumpReady(
		bHasBufferedJump,
		BufferedJumpExpiryTime,
		CurrentTime);
	ClearBufferedJumpRequest();
	if (!bShouldJump)
	{
		return;
	}

	ApplyCurrentJumpHorizontalVelocity();
	bTravelFacingAimJumpActive =
		bAimSteeringActive
		&& !ShouldUseControllerJumpFacing(
			true,
			bWantsBackpedal,
			LastMovementInput);
	ApplyCurrentJumpFacing();
	CaptureTravelFacingAimJumpOffset();
	PendingJumpPresentationYaw = CalculateAimJumpPresentationYaw(
		bAimSteeringActive,
		LastMovementInput,
		MaxAimJumpPresentationYaw);
	Jump();
}

void AAethelnPlayerCharacter::UpdateAirborneAimFacing()
{
	if (!bTravelFacingAimJumpActive
		|| !bAimSteeringActive
		|| Controller == nullptr
		|| !GetCharacterMovement()->IsFalling())
	{
		return;
	}

	FRotator FacingRotation = GetActorRotation();
	FacingRotation.Pitch = 0.0f;
	FacingRotation.Yaw =
		CalculateAimJumpTrackedYaw(
			Controller->GetControlRotation().Yaw,
			TravelFacingAimJumpOffset);
	FacingRotation.Roll = 0.0f;
	SetActorRotation(
		FacingRotation,
		ETeleportType::TeleportPhysics);
}

void AAethelnPlayerCharacter::ResetMovementPresentation(
	bool bResetImmediately)
{
	PendingJumpPresentationYaw = 0.0f;
	LockedJumpPresentationYaw = 0.0f;
	bJumpPresentationActive = false;
	if (!bResetImmediately)
	{
		return;
	}

	CurrentPresentationYaw = 0.0f;
	FRotator MeshRotation = GetMesh()->GetRelativeRotation();
	MeshRotation.Yaw = BaseMeshRelativeYaw;
	GetMesh()->SetRelativeRotation(MeshRotation);
}

void AAethelnPlayerCharacter::UpdateMovementPresentation(
	float DeltaSeconds)
{
	const UCharacterMovementComponent* Movement =
		GetCharacterMovement();
	const float GroundAimPresentationYaw =
		Movement != nullptr && !Movement->IsFalling()
			? CalculateGroundAimPresentationYaw(
				bAimSteeringActive,
				LastMovementInput,
				MaxGroundAimPresentationYaw)
			: 0.0f;
	const float TargetYaw = bJumpPresentationActive
		? LockedJumpPresentationYaw
		: GroundAimPresentationYaw;
	CurrentPresentationYaw = FMath::FInterpTo(
		CurrentPresentationYaw,
		TargetYaw,
		DeltaSeconds,
		PresentationInterpSpeed);

	FRotator MeshRotation = GetMesh()->GetRelativeRotation();
	MeshRotation.Yaw =
		BaseMeshRelativeYaw + CurrentPresentationYaw;
	GetMesh()->SetRelativeRotation(MeshRotation);
}

void AAethelnPlayerCharacter::ApplySprintIntent(bool bWantsToSprint)
{
	if (UAethelnCharacterMovementComponent* Movement =
		GetCharacterMovement<UAethelnCharacterMovementComponent>())
	{
		Movement->bWantsToSprint = bWantsToSprint;
	}
}
