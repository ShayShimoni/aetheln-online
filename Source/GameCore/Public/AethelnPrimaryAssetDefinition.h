#pragma once

#include "CoreMinimal.h"
#include "Engine/DataAsset.h"
#include "AethelnPrimaryAssetDefinition.generated.h"

UENUM(BlueprintType)
enum class EAethelnContentAudience : uint8
{
	Shared,
	ServerOnly,
	ClientOnly
};

/**
 * Stable metadata shared by governed runtime content.
 *
 * Package and display names may change without changing StableContentId. Chunking and
 * delivery rules remain intentionally outside this definition until their owning work
 * supplies accepted evidence.
 */
UCLASS(BlueprintType)
class GAMECORE_API UAethelnPrimaryAssetDefinition : public UPrimaryDataAsset
{
	GENERATED_BODY()

public:
	virtual FPrimaryAssetId GetPrimaryAssetId() const override;

	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, AssetRegistrySearchable, Category = "Aetheln|Content")
	FName StableContentId;

	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, AssetRegistrySearchable, Category = "Aetheln|Content", meta = (ClampMin = "1", UIMin = "1"))
	int32 ContentVersion = 1;

	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, AssetRegistrySearchable, Category = "Aetheln|Content")
	EAethelnContentAudience Audience = EAethelnContentAudience::Shared;
};
