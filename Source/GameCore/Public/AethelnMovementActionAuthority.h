#pragma once

#include "CoreMinimal.h"
#include "UObject/Interface.h"
#include "AethelnMovementActionAuthority.generated.h"

class AActor;

/** Authored displacement only; windows, costs and eligibility belong to the authority. */
struct GAMECORE_API FAethelnDodgeMovementDefinition
{
	float Distance = 0.0f;
	float MoveDuration = 0.0f;
	uint32 ContentVersion = 0;

	bool IsValid() const
	{
		return ContentVersion != 0 && FMath::IsFinite(Distance) && Distance > 0.0f
			&& FMath::IsFinite(MoveDuration) && MoveDuration > 0.0f
			&& FMath::IsFinite(Distance / MoveDuration) && Distance / MoveDuration > 0.0f;
	}
};

/** The timestamp is the engine-validated received move's timestamp, never a separate RPC. */
struct GAMECORE_API FAethelnDodgeStartRequest
{
	float ClientTimeStamp = 0.0f;
	uint32 ContentVersion = 0;
	bool bMovementAllowsStart = false;
	/** The pawn whose received move this is; the authority refuses any pawn but its current possessed avatar. */
	const AActor* Avatar = nullptr;
};

UINTERFACE(MinimalAPI)
class UAethelnMovementActionAuthority : public UInterface
{
	GENERATED_BODY()
};

/** GameCore policy boundary; P3 supplies the PlayerState implementation. No GAS dependency. */
class GAMECORE_API IAethelnMovementActionAuthority
{
	GENERATED_BODY()

public:
	virtual FAethelnDodgeMovementDefinition GetDodgeMovementDefinition() const = 0;
	virtual bool CanPredictDodge() const = 0;
	virtual bool TryAuthorizeDodge(const FAethelnDodgeStartRequest& Request) = 0;
};
