#pragma once

#include "CoreMinimal.h"
#include "Engine/NetSerialization.h"
#include "GameplayTagContainer.h"
#include "AethelnActivationTypes.generated.h"

namespace AethelnActivation
{
	/** Layout version of FAethelnCombatActivationRequest; the server accepts only an exact match. */
	inline constexpr uint8 SchemaVersion = 2;
}

/** Request phase. Charge is absent until an ability charges; adding it is an append plus a SchemaVersion bump. */
UENUM()
enum class EAethelnActivationPhase : uint8
{
	Press = 0,
	Release = 1
};

/**
 * Activation outcome sent to the owning client only. A client-facing mirror of
 * the safe reasons; the observability mapping stays private (TA-021).
 */
UENUM()
enum class EAethelnActivationResult : uint8
{
	Accepted = 0,
	RateLimited,
	ConnectionClosed,
	ActorDestroyed,
	IncompatibleVersion,
	StaleSequence,
	DuplicateSequence,
	MalformedRequest,
	ActivationBlocked,
	OnCooldown,
	InsufficientResource,
	InternalFailure,
	/** #60 step 6a: the client time sample is non-finite, too old, too far ahead, or regresses. */
	TimestampOutOfBounds,
	/** #60 steps 6c and 6d: the aim is beyond the hard bound of the server reference, or turned faster than the rate bound. */
	ImpossibleAimTransition
};

/** Client intent only. No target, hit, contact, damage, magnitude, cost, cooldown, shape, range, window or attribute field. */
USTRUCT()
struct GAMECOMBAT_API FAethelnCombatActivationRequest
{
	GENERATED_BODY()

	/** Layout version of this struct. */
	UPROPERTY()
	uint8 SchemaVersion = AethelnActivation::SchemaVersion;

	/** Ability.<Order>.<Name> */
	UPROPERTY()
	FGameplayTag AbilityId;

	/** Authored definition the client built for. */
	UPROPERTY()
	uint32 ContentVersion = 0;

	UPROPERTY()
	EAethelnActivationPhase Phase = EAethelnActivationPhase::Press;

	/** Per connection, one PlayerState lifetime, never wraps. */
	UPROPERTY()
	uint32 Sequence = 0;

	/** Control-rotation unit vector at press, pitch included. Explicitly zeroed: the vector's default constructor leaves it uninitialized. */
	UPROPERTY()
	FVector_NetQuantizeNormal Aim = FVector_NetQuantizeNormal(ForceInitToZero);

	/** The client's estimate of server world time at press. */
	UPROPERTY()
	double ClientServerTimeSeconds = 0.0;
};
