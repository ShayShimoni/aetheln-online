#include "AethelnPrimaryAssetDefinition.h"

FPrimaryAssetId UAethelnPrimaryAssetDefinition::GetPrimaryAssetId() const
{
	if (StableContentId.IsNone() || ContentVersion < 1)
	{
		return FPrimaryAssetId();
	}

	return FPrimaryAssetId(FPrimaryAssetType(TEXT("AethelnContent")), StableContentId);
}
