#include "AethelnCombatAttributeSet.h"

#include "GameplayEffectExtension.h"
#include "Net/UnrealNetwork.h"

namespace AethelnCombatAttributeSetPrivate
{
	struct FBoundedAttribute
	{
		FGameplayAttribute Current;
		FGameplayAttribute Max;
	};

	/** Each current value with the maximum that bounds it. */
	TConstArrayView<FBoundedAttribute> GetBoundedAttributes()
	{
		static const FBoundedAttribute BoundedAttributes[] = {
			{ UAethelnCombatAttributeSet::GetHealthAttribute(), UAethelnCombatAttributeSet::GetMaxHealthAttribute() },
			{ UAethelnCombatAttributeSet::GetEnduranceAttribute(), UAethelnCombatAttributeSet::GetMaxEnduranceAttribute() },
			{ UAethelnCombatAttributeSet::GetGuardAttribute(), UAethelnCombatAttributeSet::GetMaxGuardAttribute() },
		};
		return BoundedAttributes;
	}
}

void UAethelnCombatAttributeSet::ClampAttribute(const FGameplayAttribute& Attribute, float& NewValue) const
{
	for (const AethelnCombatAttributeSetPrivate::FBoundedAttribute& Bounded : AethelnCombatAttributeSetPrivate::GetBoundedAttributes())
	{
		if (Attribute == Bounded.Max)
		{
			NewValue = FMath::Max(NewValue, 0.0f);
			return;
		}
		if (Attribute == Bounded.Current)
		{
			NewValue = FMath::Clamp(NewValue, 0.0f, Bounded.Max.GetNumericValue(this));
			return;
		}
	}
}

void UAethelnCombatAttributeSet::SetClampedBaseValue(const FGameplayAttribute& Attribute, float NewValue)
{
	// Server only: SetNumericAttributeBase has no authority check, and a client
	// reaches the re-clamp when a lowered maximum replicates. Clients never write.
	// Lower only (owner decision on #19): the base is never raised, even when a
	// positive temporary modifier holds the current value above it. Rewriting an
	// unchanged base still re-evaluates, and so re-clamps, that current value.
	UAbilitySystemComponent* AbilitySystemComponent = GetOwningAbilitySystemComponent();
	if (AbilitySystemComponent != nullptr && AbilitySystemComponent->IsOwnerActorAuthoritative())
	{
		AbilitySystemComponent->SetNumericAttributeBase(Attribute, FMath::Min(NewValue, AbilitySystemComponent->GetNumericAttributeBase(Attribute)));
	}
}

void UAethelnCombatAttributeSet::PreAttributeBaseChange(const FGameplayAttribute& Attribute, float& NewValue) const
{
	Super::PreAttributeBaseChange(Attribute, NewValue);
	ClampAttribute(Attribute, NewValue);
}

void UAethelnCombatAttributeSet::PreAttributeChange(const FGameplayAttribute& Attribute, float& NewValue)
{
	Super::PreAttributeChange(Attribute, NewValue);
	ClampAttribute(Attribute, NewValue);
}

void UAethelnCombatAttributeSet::PostAttributeChange(const FGameplayAttribute& Attribute, float OldValue, float NewValue)
{
	Super::PostAttributeChange(Attribute, OldValue, NewValue);

	// A lowered maximum does not fire the current value's own PreAttributeChange,
	// so re-clamp it here. A current value is never scaled up.
	for (const AethelnCombatAttributeSetPrivate::FBoundedAttribute& Bounded : AethelnCombatAttributeSetPrivate::GetBoundedAttributes())
	{
		if (Attribute == Bounded.Max && Bounded.Current.GetNumericValue(this) > NewValue)
		{
			SetClampedBaseValue(Bounded.Current, NewValue);
			return;
		}
	}
}

void UAethelnCombatAttributeSet::PostGameplayEffectExecute(const FGameplayEffectModCallbackData& Data)
{
	Super::PostGameplayEffectExecute(Data);

	for (const AethelnCombatAttributeSetPrivate::FBoundedAttribute& Bounded : AethelnCombatAttributeSetPrivate::GetBoundedAttributes())
	{
		if (Data.EvaluatedData.Attribute == Bounded.Current)
		{
			const float CurrentValue = Bounded.Current.GetNumericValue(this);
			const float ClampedValue = FMath::Clamp(CurrentValue, 0.0f, Bounded.Max.GetNumericValue(this));
			if (ClampedValue != CurrentValue)
			{
				SetClampedBaseValue(Bounded.Current, ClampedValue);
			}
			return;
		}
	}
}

void UAethelnCombatAttributeSet::GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const
{
	Super::GetLifetimeReplicatedProps(OutLifetimeProps);

	// Owner-only fails closed; #61 decides later what opponents may see.
	DOREPLIFETIME_CONDITION_NOTIFY(UAethelnCombatAttributeSet, Health, COND_OwnerOnly, REPNOTIFY_Always);
	DOREPLIFETIME_CONDITION_NOTIFY(UAethelnCombatAttributeSet, MaxHealth, COND_OwnerOnly, REPNOTIFY_Always);
	DOREPLIFETIME_CONDITION_NOTIFY(UAethelnCombatAttributeSet, Endurance, COND_OwnerOnly, REPNOTIFY_Always);
	DOREPLIFETIME_CONDITION_NOTIFY(UAethelnCombatAttributeSet, MaxEndurance, COND_OwnerOnly, REPNOTIFY_Always);
	DOREPLIFETIME_CONDITION_NOTIFY(UAethelnCombatAttributeSet, Guard, COND_OwnerOnly, REPNOTIFY_Always);
	DOREPLIFETIME_CONDITION_NOTIFY(UAethelnCombatAttributeSet, MaxGuard, COND_OwnerOnly, REPNOTIFY_Always);
}

void UAethelnCombatAttributeSet::OnRep_Health(const FGameplayAttributeData& PreviousValue)
{
	GAMEPLAYATTRIBUTE_REPNOTIFY(UAethelnCombatAttributeSet, Health, PreviousValue);
}

void UAethelnCombatAttributeSet::OnRep_MaxHealth(const FGameplayAttributeData& PreviousValue)
{
	GAMEPLAYATTRIBUTE_REPNOTIFY(UAethelnCombatAttributeSet, MaxHealth, PreviousValue);
}

void UAethelnCombatAttributeSet::OnRep_Endurance(const FGameplayAttributeData& PreviousValue)
{
	GAMEPLAYATTRIBUTE_REPNOTIFY(UAethelnCombatAttributeSet, Endurance, PreviousValue);
}

void UAethelnCombatAttributeSet::OnRep_MaxEndurance(const FGameplayAttributeData& PreviousValue)
{
	GAMEPLAYATTRIBUTE_REPNOTIFY(UAethelnCombatAttributeSet, MaxEndurance, PreviousValue);
}

void UAethelnCombatAttributeSet::OnRep_Guard(const FGameplayAttributeData& PreviousValue)
{
	GAMEPLAYATTRIBUTE_REPNOTIFY(UAethelnCombatAttributeSet, Guard, PreviousValue);
}

void UAethelnCombatAttributeSet::OnRep_MaxGuard(const FGameplayAttributeData& PreviousValue)
{
	GAMEPLAYATTRIBUTE_REPNOTIFY(UAethelnCombatAttributeSet, MaxGuard, PreviousValue);
}
