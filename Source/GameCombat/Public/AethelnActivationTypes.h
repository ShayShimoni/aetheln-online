#pragma once

#include "CoreMinimal.h"
#include "GameplayTagContainer.h"
#include "AethelnActivationTypes.generated.h"

namespace AethelnActivation
{
	/** Layout version of FAethelnCombatActivationRequest; the server accepts only an exact match. */
	inline constexpr uint8 SchemaVersion = 1;
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
	InternalFailure
};

/** Client intent only. No target, hit, contact, aim, damage, magnitude, cost, cooldown or attribute field. */
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
};
