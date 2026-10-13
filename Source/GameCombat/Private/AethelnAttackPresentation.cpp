#include "AethelnAttackPresentation.h"

#include "AethelnAttackDefinition.h"
#include "AethelnGameplayAbility.h"
#include "Animation/AnimMontage.h"
#include "Animation/AnimNotifies/AnimNotify.h"
#include "Animation/AnimNotifies/AnimNotifyState.h"
#include "Animation/AnimNotifies/AnimNotifyState_Trail.h"
#include "Animation/AnimNotifies/AnimNotify_PlayParticleEffect.h"
#include "Animation/AnimNotifies/AnimNotify_PlaySound.h"
#include "Animation/AnimSequence.h"
#include "Animation/Skeleton.h"
#include "AssetRegistry/AssetData.h"
#include "AssetRegistry/IAssetRegistry.h"
#include "UObject/AssetRegistryTagsContext.h"

#if WITH_EDITOR
#include "Misc/DataValidation.h"
#endif

namespace
{
	const FName AbilityIdTag(TEXT("AbilityId"));
	const FName AuthoredContentVersionTag(TEXT("AuthoredContentVersion"));

	/** Every binding that claims the ability and version, found by class and searchable tags only. */
	TArray<FAssetData> QueryBindings(const FGameplayTag& AbilityId, int32 AuthoredContentVersion)
	{
		TArray<FAssetData> Found;
		if (!AbilityId.IsValid() || AuthoredContentVersion < 1) { return Found; }
		FARFilter Filter;
		Filter.ClassPaths.Add(UAethelnAttackPresentation::StaticClass()->GetClassPathName());
		Filter.bRecursiveClasses = true;
		Filter.TagsAndValues.Add(AbilityIdTag, AbilityId.ToString());
		Filter.TagsAndValues.Add(AuthoredContentVersionTag, FString::FromInt(AuthoredContentVersion));
		IAssetRegistry::GetChecked().GetAssets(Filter, Found);
		return Found;
	}

	bool HasOnlyAllowedNotifies(const TArray<FAnimNotifyEvent>& Notifies)
	{
		for (const FAnimNotifyEvent& Event : Notifies)
		{
			// A name-only notify carries no class to check, so it fails closed.
			const UClass* NotifyClass = Event.Notify != nullptr ? Event.Notify->GetClass()
				: Event.NotifyStateClass != nullptr ? Event.NotifyStateClass->GetClass() : nullptr;
			if (!UAethelnAttackPresentation::IsPresentationNotifyClass(NotifyClass)) { return false; }
		}
		return true;
	}

	/**
	 * The notifies the montage itself carries and those of each plain sequence it plays. A segment that is not
	 * a UAnimSequence (a composite, or an empty reference) fails closed instead of being walked.
	 */
	bool MontageHasOnlyAllowedNotifies(const UAnimMontage& Montage)
	{
		if (!HasOnlyAllowedNotifies(Montage.Notifies)) { return false; }
		for (const FSlotAnimationTrack& Slot : Montage.SlotAnimTracks)
		{
			for (const FAnimSegment& Segment : Slot.AnimTrack.AnimSegments)
			{
				const UAnimSequence* Sequence = Cast<UAnimSequence>(Segment.GetAnimReference());
				if (Sequence == nullptr || !HasOnlyAllowedNotifies(Sequence->Notifies)) { return false; }
			}
		}
		return true;
	}
}

bool UAethelnAttackPresentation::IsPresentationNotifyClass(const UClass* NotifyClass)
{
	return NotifyClass == UAnimNotify_PlaySound::StaticClass()
		|| NotifyClass == UAnimNotify_PlayParticleEffect::StaticClass()
		|| NotifyClass == UAnimNotifyState_Trail::StaticClass()
		// The Niagara notify, matched by exact class path so GameCombat takes no dependency on the Niagara modules.
		|| (NotifyClass != nullptr && NotifyClass->GetClassPathName() == FTopLevelAssetPath(TEXT("/Script/NiagaraAnimNotifies"), TEXT("AnimNotify_PlayNiagaraEffect")));
}

EAethelnPresentationLookup UAethelnAttackPresentation::FindBinding(const FGameplayTag& InAbilityId, int32 InAuthoredContentVersion, FAssetData& OutAsset)
{
	const TArray<FAssetData> Found = QueryBindings(InAbilityId, InAuthoredContentVersion);
	if (Found.IsEmpty()) { return EAethelnPresentationLookup::NotFound; }
	if (Found.Num() > 1) { return EAethelnPresentationLookup::Ambiguous; }
	OutAsset = Found[0];
	return EAethelnPresentationLookup::Found;
}

void UAethelnAttackPresentation::GetAssetRegistryTags(FAssetRegistryTagsContext Context) const
{
	Super::GetAssetRegistryTags(Context);
	Context.AddTag(FAssetRegistryTag(AbilityIdTag, AbilityId.ToString(), FAssetRegistryTag::TT_Alphabetical));
}

const TCHAR* UAethelnAttackPresentation::FindProblem() const
{
	if (StableContentId.IsNone()) { return TEXT("has no StableContentId"); }
	if (ContentVersion < 1) { return TEXT("has ContentVersion below 1"); }
	if (Audience != EAethelnContentAudience::ClientOnly) { return TEXT("is not ClientOnly"); }
	if (!UAethelnGameplayAbility::IsAbilityIdentityTag(AbilityId)) { return TEXT("lacks a valid Ability. identity tag"); }
	if (Definition == nullptr || Definition->AbilityId != AbilityId) { return TEXT("names an ability ID that has no matching definition"); }
	if (AuthoredContentVersion != Definition->ContentVersion) { return TEXT("is stale: its authored content version differs from the definition's"); }
	if (Skeleton == nullptr) { return TEXT("has no skeleton"); }
	if (Steps.Num() != Definition->Steps.Num()) { return TEXT("does not have one presentation step per definition step"); }
	for (const FAethelnAttackPresentationStep& Step : Steps)
	{
		if (Step.Montage == nullptr) { return TEXT("has a step without a montage"); }
		if (Step.Montage->GetSkeleton() != Skeleton) { return TEXT("has a montage on another skeleton"); }
		for (const FName Section : { Step.WindUpSection, Step.ActiveSection, Step.RecoverySection })
		{
			if (!Step.Montage->IsValidSectionName(Section)) { return TEXT("names a montage section that does not exist"); }
		}
		for (const FName Socket : Step.Sockets)
		{
			if (Skeleton->FindSocket(Socket) == nullptr) { return TEXT("names a socket the skeleton does not have"); }
		}
		if (!MontageHasOnlyAllowedNotifies(*Step.Montage)) { return TEXT("has a montage with a notify that is not an allowlisted presentation class, or with a segment that is not a plain sequence"); }
	}
	return nullptr;
}

#if WITH_EDITOR
EDataValidationResult UAethelnAttackPresentation::IsDataValid(FDataValidationContext& Context) const
{
	EDataValidationResult Result = Super::IsDataValid(Context);
	bool bInvalid = Result == EDataValidationResult::Invalid;
	if (const TCHAR* Problem = FindProblem())
	{
		Context.AddError(FText::FromString(FString::Printf(TEXT("Attack presentation %s %s."), *GetPathName(), Problem)));
		bInvalid = true;
	}
	// Two bindings for the same ability ID and version are an error, not a priority rule. A real asset only:
	// transient fixtures are never mounted content.
	if (GetOutermost() != GetTransientPackage())
	{
		for (const FAssetData& Other : QueryBindings(AbilityId, AuthoredContentVersion))
		{
			if (Other.GetSoftObjectPath() != FSoftObjectPath(this))
			{
				Context.AddError(FText::FromString(FString::Printf(TEXT("Attack presentation %s duplicates the binding %s for the same ability ID and content version."), *GetPathName(), *Other.GetSoftObjectPath().ToString())));
				bInvalid = true;
			}
		}
	}
	return bInvalid ? EDataValidationResult::Invalid : EDataValidationResult::Valid;
}
#endif
