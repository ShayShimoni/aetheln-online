#pragma once

#include "CoreMinimal.h"
#include "Engine/NetSerialization.h"
#include "GameplayTagContainer.h"
#include "AethelnAttackTypes.generated.h"

/**
 * Whether the seam accepted a request's aim as sent or clamped it toward the
 * server reference (docs/attack-timeline-and-combo.md, Validation additions).
 */
UENUM()
enum class EAethelnAimCorrection : uint8
{
	None = 0,
	AimCorrected = 1
};

UENUM()
enum class EAethelnAttackShape : uint8
{
	Sphere,
	Capsule,
	Box
};

UENUM()
enum class EAethelnChainEndReason : uint8
{
	None,
	Completed,
	Timeout,
	Interrupted,
	AvatarLost,
	IncompatibleState,
	OtherAction
};

/** Authored offsets only. Every zero default is unset, not production tuning. */
USTRUCT()
struct GAMECOMBAT_API FAethelnAttackStepDefinition
{
	GENERATED_BODY()
	UPROPERTY() double ActiveStart = 0.0;
	UPROPERTY() double ActiveEnd = 0.0;
	UPROPERTY() double BufferOpen = 0.0;
	UPROPERTY() double LinkOpen = 0.0;
	UPROPERTY() double LinkClose = 0.0;
	UPROPERTY() double RecoveryEnd = 0.0;
	UPROPERTY() double CancelOpen = 0.0;
	UPROPERTY() EAethelnAttackShape Shape = EAethelnAttackShape::Sphere;
	UPROPERTY() FVector ShapeExtent = FVector::ZeroVector;
	UPROPERTY() FTransform PathStart = FTransform::Identity;
	UPROPERTY() FTransform PathEnd = FTransform::Identity;
	UPROPERTY() double MaxAimPitchDegrees = 0.0;
	UPROPERTY() float WroughtDamage = 0.0f;
	UPROPERTY() int32 MaxTargets = 0;
};

USTRUCT()
struct GAMECOMBAT_API FAethelnAttackWindowOffsets
{
	GENERATED_BODY()
	UPROPERTY() double ActiveStart = 0.0;
	UPROPERTY() double ActiveEnd = 0.0;
	UPROPERTY() double BufferOpen = 0.0;
	UPROPERTY() double LinkOpen = 0.0;
	UPROPERTY() double LinkClose = 0.0;
	UPROPERTY() double RecoveryEnd = 0.0;
	UPROPERTY() double CancelOpen = 0.0;
};

/** Owner-only record for a started step. A waiting accepted press has no record yet. */
USTRUCT()
struct GAMECOMBAT_API FAethelnCombatActivationRecord
{
	GENERATED_BODY()
	UPROPERTY() uint8 SchemaVersion = 1;
	UPROPERTY() FGuid ActivationId;
	UPROPERTY() uint32 Sequence = 0;
	UPROPERTY() uint32 InstigatorCombatId = 0;
	UPROPERTY() double StartServerTime = 0.0;
	UPROPERTY() FGameplayTag AbilityId;
	UPROPERTY() uint32 ContentVersion = 0;
	UPROPERTY() uint8 ChainStep = 0;
	UPROPERTY() FAethelnAttackWindowOffsets Windows;
	UPROPERTY() FVector_NetQuantizeNormal AcceptedAim = FVector_NetQuantizeNormal(ForceInitToZero);
	UPROPERTY() FVector_NetQuantize100 CapsuleOrigin = FVector_NetQuantize100(ForceInitToZero);
	UPROPERTY() EAethelnAimCorrection AimCorrection = EAethelnAimCorrection::None;
};

/** Readable server state, replicated to observers with COND_SkipOwner. */
USTRUCT()
struct GAMECOMBAT_API FAethelnAttackPresentationState
{
	GENERATED_BODY()
	UPROPERTY() bool bActive = false;
	UPROPERTY() FGameplayTag AbilityId;
	UPROPERTY() uint32 ContentVersion = 0;
	UPROPERTY() uint8 ChainStep = 0;
	UPROPERTY() double StartServerTime = 0.0;
	UPROPERTY() FVector_NetQuantizeNormal AcceptedAim = FVector_NetQuantizeNormal(ForceInitToZero);
	UPROPERTY() uint32 ActivationCounter = 0;
	UPROPERTY() EAethelnChainEndReason EndReason = EAethelnChainEndReason::None;
};

/** Immutable accepted seam context; never reconstructed from raw/later aim. */
struct FAethelnAcceptedAttackInput
{
	FGuid ActivationId;
	uint32 Sequence = 0;
	uint32 ContentVersion = 0;
	FVector AcceptedAim = FVector::ZeroVector;
	EAethelnAimCorrection AimCorrection = EAethelnAimCorrection::None;
	double ReceiptServerTime = 0.0;
};

/** Clipped sampling interval. ToSeconds may equal an exclusive active/reset boundary. */
struct FAethelnAttackSampleInterval
{
	bool bValid = false;
	bool bIncludesInitialOverlap = false;
	double FromSeconds = 0.0;
	double ToSeconds = 0.0;
};

namespace AethelnAttackTimeline
{
	GAMECOMBAT_API bool IsWithinWindow(double Time, double Start, double End);
	GAMECOMBAT_API FAethelnAttackSampleInterval ClipActiveInterval(const FAethelnAttackStepDefinition& Step, double Start, double LastSample, double Now, double ResetTime = TNumericLimits<double>::Max());
	/** Zero means invalid/unrepresentable. No numeric production sampling budget is chosen. */
	GAMECOMBAT_API int32 GetSubstepCount(double Distance, double AngleDegrees, double MaxDistance, double MaxAngleDegrees);
}
