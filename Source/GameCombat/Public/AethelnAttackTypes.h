#pragma once

#include "CoreMinimal.h"
#include "Engine/NetSerialization.h"
#include "GameplayTagContainer.h"
#include "AethelnAttackTypes.generated.h"

class AActor;

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
	OtherAction,
	/** The timeline refused a buffered step for a reason other than a lost avatar (no subsystem, exhausted ids). */
	InternalFailure
};

/** A committed contact result. Blocked and Avoided apply no damage. */
UENUM()
enum class EAethelnCombatResultOutcome : uint8
{
	Hit,
	Avoided,
	Blocked
};

/** Presentation-safe result cue: no damage amount and no attribute value. */
USTRUCT()
struct GAMECOMBAT_API FAethelnCombatResultCue
{
	GENERATED_BODY()
	UPROPERTY() TObjectPtr<AActor> SourceAvatar = nullptr;
	UPROPERTY() EAethelnCombatResultOutcome Outcome = EAethelnCombatResultOutcome::Hit;
	UPROPERTY() FGameplayTag FamilyTag;
	UPROPERTY() bool bLethal = false;
	UPROPERTY() FVector_NetQuantize ContactLocation = FVector_NetQuantize(ForceInitToZero);
};

/** Server-only result record, kept for audit; clients see only the cue. */
struct FAethelnCombatResult
{
	FGuid ActivationId;
	uint32 Sequence = 0;
	FGameplayTag AbilityId;
	uint32 InstigatorCombatId = 0;
	uint32 TargetCombatId = 0;
	double ContactTime = 0.0;
	EAethelnCombatResultOutcome Outcome = EAethelnCombatResultOutcome::Hit;
	bool bLethal = false;
};

DECLARE_DELEGATE_OneParam(FAethelnBlockedHook, const FAethelnCombatResult&);

/**
 * An active defense state exposed by the defense owner (#18). Active while the target holds
 * StateTag. A contact whose direction from the target lies within ArcDegrees (the full arc,
 * centered on the target's authoritative facing) is Blocked, and OnBlocked runs once; it
 * applies what a blocked hit does. A non-finite arc or one outside (0, 360] defends nothing.
 */
struct FAethelnDefenseState
{
	FGameplayTag StateTag;
	double ArcDegrees = 0.0;
	FAethelnBlockedHook OnBlocked;
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
	/** Sphere: X is the radius. Capsule: X is the radius, Z the half height. Box: the half extents. */
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
