#include "AethelnAssetManager.h"

#include "AssetRegistry/AssetData.h"

#if WITH_EDITOR
#include "Interfaces/ITargetPlatform.h"
#endif

DEFINE_LOG_CATEGORY_STATIC(LogAethelnAssetManager, Log, All);

bool UAethelnAssetManager::ShouldCookForTarget(EAethelnContentAudience Audience, bool bServerOnlyTarget, bool bClientOnlyTarget)
{
	switch (Audience)
	{
	case EAethelnContentAudience::Shared: return true;
	case EAethelnContentAudience::ServerOnly: return !bClientOnlyTarget;
	case EAethelnContentAudience::ClientOnly: return !bServerOnlyTarget;
	}
	return false;
}

bool UAethelnAssetManager::TryParseAudienceTag(const FString& Tag, EAethelnContentAudience& OutAudience)
{
	if (Tag == TEXT("Shared")) { OutAudience = EAethelnContentAudience::Shared; return true; }
	if (Tag == TEXT("ServerOnly")) { OutAudience = EAethelnContentAudience::ServerOnly; return true; }
	if (Tag == TEXT("ClientOnly")) { OutAudience = EAethelnContentAudience::ClientOnly; return true; }
	return false;
}

void UAethelnAssetManager::ApplyAudienceCookRule(FName PackageName, EAethelnContentAudience Audience, bool bServerOnlyTarget, bool bClientOnlyTarget,
	TArray<FName>& PackagesToCook, TArray<FName>& PackagesToNeverCook)
{
	if (ShouldCookForTarget(Audience, bServerOnlyTarget, bClientOnlyTarget))
	{
		PackagesToCook.AddUnique(PackageName);
		PackagesToNeverCook.Remove(PackageName);
	}
	else
	{
		PackagesToNeverCook.AddUnique(PackageName);
		PackagesToCook.Remove(PackageName);
	}
}

#if WITH_EDITOR
void UAethelnAssetManager::ModifyCook(TConstArrayView<const ITargetPlatform*> TargetPlatforms, TArray<FName>& PackagesToCook, TArray<FName>& PackagesToNeverCook)
{
	Super::ModifyCook(TargetPlatforms, PackagesToCook, PackagesToNeverCook);

	bool bServerOnlyTarget = false;
	bool bClientOnlyTarget = false;
	for (const ITargetPlatform* TargetPlatform : TargetPlatforms)
	{
		bServerOnlyTarget |= TargetPlatform->IsServerOnly();
		bClientOnlyTarget |= TargetPlatform->IsClientOnly();
	}
	if (bServerOnlyTarget && bClientOnlyTarget)
	{
		// One list serves every platform of a session, so a mixed session cannot keep either audience out. Cook the targets separately.
		UE_LOG(LogAethelnAssetManager, Error, TEXT("A client-only and a server-only target share one cook session; the audience cook rule is not applied. Cook them separately."));
		return;
	}

	TArray<FAssetData> Assets;
	GetPrimaryAssetDataList(FPrimaryAssetType(TEXT("AethelnContent")), Assets);
	for (const FAssetData& Asset : Assets)
	{
		FString AudienceTag;
		EAethelnContentAudience Audience = EAethelnContentAudience::Shared;
		if (!Asset.GetTagValue(TEXT("Audience"), AudienceTag) || !TryParseAudienceTag(AudienceTag, Audience))
		{
			// Fail closed: an asset with no readable audience is in no cook.
			UE_LOG(LogAethelnAssetManager, Error, TEXT("%s has no readable Audience tag; it is kept out of the cook."), *Asset.PackageName.ToString());
			PackagesToCook.Remove(Asset.PackageName);
			PackagesToNeverCook.AddUnique(Asset.PackageName);
			continue;
		}
		ApplyAudienceCookRule(Asset.PackageName, Audience, bServerOnlyTarget, bClientOnlyTarget, PackagesToCook, PackagesToNeverCook);
	}
}
#endif
