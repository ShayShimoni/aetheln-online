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

#if WITH_EDITOR
#include "Misc/DataValidation.h"
#endif

namespace
{
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
		|| NotifyClass == UAnimNotifyState_Trail::StaticClass();
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
	if (const TCHAR* Problem = FindProblem())
	{
		Context.AddError(FText::FromString(FString::Printf(TEXT("Attack presentation %s %s."), *GetPathName(), Problem)));
		return EDataValidationResult::Invalid;
	}
	return Result == EDataValidationResult::Invalid ? Result : EDataValidationResult::Valid;
}
#endif
