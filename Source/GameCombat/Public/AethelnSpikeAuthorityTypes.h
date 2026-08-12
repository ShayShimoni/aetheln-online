#pragma once

#include "CoreMinimal.h"
#include "AethelnSpikeAuthorityTypes.generated.h"

/** Dependency-free mirror of the stable, safe GameNet rejection vocabulary. */
UENUM(BlueprintType)
enum class EAethelnSpikeAttackRejection : uint8
{
	None = 0,
	StaleSequence = 1,
	DuplicateSequence = 2,
	IncompatibleVersion = 3,
	TimestampOutOfBounds = 4,
	ImpossibleAimTransition = 5,
	ConnectionClosed = 6,
	ActorDestroyed = 7,
	MalformedIntent = 8,
	ActivationBlocked = 9
};

inline const TCHAR* LexToString(EAethelnSpikeAttackRejection Reason)
{
	switch (Reason)
	{
	case EAethelnSpikeAttackRejection::None:
		return TEXT("none");
	case EAethelnSpikeAttackRejection::StaleSequence:
		return TEXT("stale-sequence");
	case EAethelnSpikeAttackRejection::DuplicateSequence:
		return TEXT("duplicate-sequence");
	case EAethelnSpikeAttackRejection::IncompatibleVersion:
		return TEXT("incompatible-version");
	case EAethelnSpikeAttackRejection::TimestampOutOfBounds:
		return TEXT("timestamp-out-of-bounds");
	case EAethelnSpikeAttackRejection::ImpossibleAimTransition:
		return TEXT("impossible-aim-transition");
	case EAethelnSpikeAttackRejection::ConnectionClosed:
		return TEXT("connection-closed");
	case EAethelnSpikeAttackRejection::ActorDestroyed:
		return TEXT("actor-destroyed");
	case EAethelnSpikeAttackRejection::MalformedIntent:
		return TEXT("malformed-intent");
	case EAethelnSpikeAttackRejection::ActivationBlocked:
		return TEXT("activation-blocked");
	default:
		return TEXT("unknown");
	}
}

/** Outcome-free client command. Targets and claimed combat results are deliberately absent. */
USTRUCT(BlueprintType)
struct GAMECOMBAT_API FAethelnSpikeAttackIntent
{
	GENERATED_BODY()

	UPROPERTY()
	uint8 SchemaVersion = 1;

	UPROPERTY()
	uint32 ContentVersion = 1;

	UPROPERTY()
	uint32 Sequence = 0;

	UPROPERTY()
	double ClientTimestampSeconds = 0.0;

	UPROPERTY()
	FVector_NetQuantizeNormal Aim = FVector::ForwardVector;
};
