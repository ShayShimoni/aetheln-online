#include "AethelnDeathSubsystem.h"

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatEffects.h"
#include "AethelnCombatTimelineSubsystem.h"
#include "AethelnGameplayTags.h"
#include "GameFramework/Character.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "GameFramework/PlayerState.h"

DEFINE_LOG_CATEGORY_STATIC(LogAethelnDeath, Log, All);

bool UAethelnDeathSubsystem::ShouldCreateSubsystem(UObject* Outer) const
{
	return Super::ShouldCreateSubsystem(Outer) && GetDefault<UAethelnCombatTimelineSubsystem>()->ShouldCreateSubsystem(Outer);
}

void UAethelnDeathSubsystem::Initialize(FSubsystemCollectionBase& Collection)
{
	Super::Initialize(Collection);
	Timeline = Collection.InitializeDependency<UAethelnCombatTimelineSubsystem>();
	if (Timeline.IsValid())
	{
		LethalHandle = Timeline->OnLethalResult.AddUObject(this, &UAethelnDeathSubsystem::HandleLethalResult);
	}
}

void UAethelnDeathSubsystem::Deinitialize()
{
	if (Timeline.IsValid()) { Timeline->OnLethalResult.Remove(LethalHandle); }
	Timeline.Reset();
	Super::Deinitialize();
}

bool UAethelnDeathSubsystem::ApplyDeath(UAethelnAbilitySystemComponent& Victim)
{
	const FGameplayAttribute Health = UAethelnCombatAttributeSet::GetHealthAttribute();
	// Players only: #20 owns AI death, so a zero-Health AI stays inert here.
	if (!Victim.IsOwnerActorAuthoritative() || Cast<APlayerState>(Victim.GetOwner()) == nullptr
		|| Victim.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead)
		|| !Victim.HasAttributeSetForAttribute(Health) || Victim.GetNumericAttribute(Health) > 0.0f)
	{
		return false;
	}
	// The tag event ends the chain (IncompatibleState), the dodge window and the block first.
	UAethelnDeathStateEffect::ApplyTo(Victim);
	Victim.CancelAllAbilities();
	if (const ACharacter* Character = Cast<ACharacter>(Victim.GetAvatarActor()))
	{
		if (UCharacterMovementComponent* Movement = Character->GetCharacterMovement()) { Movement->DisableMovement(); }
	}
	return true;
}

void UAethelnDeathSubsystem::HandleLethalResult(UAethelnAbilitySystemComponent* Target, const FGuid& ActivationId, double /*ContactTime*/)
{
	if (Target != nullptr && ApplyDeath(*Target))
	{
		UE_LOG(LogAethelnDeath, Log, TEXT("%s died (activation %s)."), *GetNameSafe(Target->GetOwner()), *ActivationId.ToString(EGuidFormats::DigitsWithHyphensLower));
	}
}
