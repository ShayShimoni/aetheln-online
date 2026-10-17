#pragma once

#include "AethelnPrimaryAssetDefinition.h"
#include "Engine/AssetManager.h"
#include "AethelnAssetManager.generated.h"

/**
 * The project asset manager (#84, docs/animation-and-combat-content-pipeline.md, Cook inclusion by audience).
 * Its one job is the cook rule for governed primary assets (AethelnContent): the audience decides which cook
 * target holds a package. A Shared package is in every cook, a ServerOnly package is never in a client-only
 * cook, and a ClientOnly package (a presentation binding) is never in a dedicated-server cook. Montages,
 * notifies, trails, audio and effects are not primary assets; they ride in as the binding's dependencies, so
 * keeping the binding out of the server cook keeps them out too. Selected by AssetManagerClassName in
 * Config/DefaultEngine.ini.
 */
UCLASS()
class GAMECORE_API UAethelnAssetManager : public UAssetManager
{
	GENERATED_BODY()

public:
	/** The cook matrix. A target that is neither client-only nor server-only (a full game build) takes every audience. */
	static bool ShouldCookForTarget(EAethelnContentAudience Audience, bool bServerOnlyTarget, bool bClientOnlyTarget);

	/** Reads the Audience registry tag ("Shared", "ServerOnly", "ClientOnly"). Anything else is refused. */
	static bool TryParseAudienceTag(const FString& Tag, EAethelnContentAudience& OutAudience);

	/** Puts one package in the cook list or the never-cook list for the target, removing it from the other. */
	static void ApplyAudienceCookRule(FName PackageName, EAethelnContentAudience Audience, bool bServerOnlyTarget, bool bClientOnlyTarget,
		TArray<FName>& PackagesToCook, TArray<FName>& PackagesToNeverCook);

#if WITH_EDITOR
	virtual void ModifyCook(TConstArrayView<const ITargetPlatform*> TargetPlatforms, TArray<FName>& PackagesToCook, TArray<FName>& PackagesToNeverCook) override;
#endif
};
