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
			const FAethelnAttackStepDefinition& S = Steps[Index];
			for (double Value : { S.ActiveStart, S.ActiveEnd, S.BufferOpen, S.LinkOpen, S.LinkClose, S.RecoveryEnd, S.CancelOpen, S.MaxAimPitchDegrees, S.InterruptibleUntil })
			{
				if (!FMath::IsFinite(Value) || Value < 0.0) { return TEXT("has a non-finite or negative step value"); }
			}
			if (!(S.ActiveStart < S.ActiveEnd && S.ActiveEnd <= S.BufferOpen
				&& S.ActiveEnd <= S.CancelOpen && S.CancelOpen <= S.RecoveryEnd && S.InterruptibleUntil <= S.RecoveryEnd))
			{
				return TEXT("has invalid active, buffer, commitment or interruptible ordering");
			}
			if (Index == Steps.Num() - 1)
			{
				if (S.BufferOpen != S.RecoveryEnd || S.LinkOpen != 0.0 || S.LinkClose != 0.0)
				{
					return TEXT("has a final-step buffer or link window");
				}
			}
			else if (!(S.BufferOpen <= S.LinkOpen && S.LinkOpen <= S.RecoveryEnd
				&& S.RecoveryEnd <= S.LinkClose && S.LinkOpen < S.LinkClose))
			{
				return TEXT("has invalid link or recovery ordering");
			}
			if (S.Shape > EAethelnAttackShape::Box || S.ShapeExtent.ContainsNaN()
				|| S.ShapeExtent.X <= 0.0 || S.ShapeExtent.Y <= 0.0 || S.ShapeExtent.Z <= 0.0
				|| (S.Shape == EAethelnAttackShape::Capsule && S.ShapeExtent.Z < S.ShapeExtent.X)
				|| !S.PathStart.IsValid() || !S.PathEnd.IsValid()
				|| !FMath::IsFinite(S.WroughtDamage) || S.WroughtDamage < 0.0f
				|| !FMath::IsFinite(S.GuardPressure) || S.GuardPressure < 0.0f
				|| S.MaxTargets < 1 || S.MaxAimPitchDegrees > 90.0)
			{
				return TEXT("has an invalid shape, damage, Guard pressure, target bound or pitch clamp");
			}
		}
		return nullptr;
	}
}

const TCHAR* UAethelnAttackDefinition::FindProblem() const
{
	return nullptr; // #84 P2 RED STUB, reverted at head: the validator accepts everything, so N2 fails for the right reason.
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
