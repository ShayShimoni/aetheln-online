#include "AethelnAttackDefinition.h"

#include "AethelnGameplayAbility.h"

#if WITH_EDITOR
#include "Misc/DataValidation.h"
#endif

namespace AethelnAttackTimeline
{
	const TCHAR* FindStepListProblem(TConstArrayView<FAethelnAttackStepDefinition> Steps, double MaxSampleDistance, double MaxSampleAngleDegrees)
	{
		if (Steps.Num() == 0) { return TEXT("has no steps"); }
		if (!FMath::IsFinite(MaxSampleDistance) || MaxSampleDistance <= 0.0
			|| !FMath::IsFinite(MaxSampleAngleDegrees) || MaxSampleAngleDegrees <= 0.0)
		{
			return TEXT("has unset or invalid sampling bounds");
		}
		for (int32 Index = 0; Index < Steps.Num(); ++Index)
		{
			if (const TCHAR* Problem = FindStepProblem(Steps[Index], Index == Steps.Num() - 1)) { return Problem; }
		}
		return nullptr;
	}
}

const TCHAR* UAethelnAttackDefinition::FindProblem() const
{
	if (StableContentId.IsNone()) { return TEXT("has no StableContentId"); }
	if (ContentVersion < 1) { return TEXT("has ContentVersion below 1"); }
	if (Audience != EAethelnContentAudience::Shared) { return TEXT("is not Shared (TA-027)"); }
	if (!UAethelnGameplayAbility::IsAbilityIdentityTag(AbilityId)) { return TEXT("lacks a valid Ability. identity tag"); }
	if (!FMath::IsFinite(EnduranceCost) || EnduranceCost < 0.0f) { return TEXT("has a non-finite or negative cost"); }
	return AethelnAttackTimeline::FindStepListProblem(Steps, MaxSampleDistance, MaxSampleAngleDegrees);
}

#if WITH_EDITOR
EDataValidationResult UAethelnAttackDefinition::IsDataValid(FDataValidationContext& Context) const
{
	EDataValidationResult Result = Super::IsDataValid(Context);
	if (const TCHAR* Problem = FindProblem())
	{
		Context.AddError(FText::FromString(FString::Printf(TEXT("Attack definition %s %s."), *GetPathName(), Problem)));
		return EDataValidationResult::Invalid;
	}
	return Result == EDataValidationResult::Invalid ? Result : EDataValidationResult::Valid;
}
#endif
