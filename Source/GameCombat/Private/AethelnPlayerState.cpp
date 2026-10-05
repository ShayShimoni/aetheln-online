#include "AethelnPlayerState.h"

#include "Abilities/GameplayAbility.h"
#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnGameplayAbility.h"
#include "GameFramework/Pawn.h"

DEFINE_LOG_CATEGORY_STATIC(LogAethelnAbilityGrant, Log, All);

AAethelnPlayerState::AAethelnPlayerState()
{
	AbilitySystemComponent = CreateDefaultSubobject<UAethelnAbilitySystemComponent>(TEXT("AbilitySystemComponent"));
	AbilitySystemComponent->SetIsReplicated(true);
	AbilitySystemComponent->SetReplicationMode(EGameplayEffectReplicationMode::Mixed);

	// The attribute set must be a default subobject of the ASC's owner.
	AttributeSet = CreateDefaultSubobject<UAethelnCombatAttributeSet>(TEXT("CombatAttributeSet"));
}

void AAethelnPlayerState::PostInitializeComponents()
{
	Super::PostInitializeComponents();

	// Config values are not available in the constructor.
	if (ProvisionalNetUpdateFrequency > 0.0f)
	{
		SetNetUpdateFrequency(ProvisionalNetUpdateFrequency);
	}

	// The ASC's InitializeComponent made this PlayerState its avatar. There is no
	// pawn yet, so this sets the avatar to null on the server and on clients.
	AbilitySystemComponent->InitAbilityActorInfo(this, GetPawn());
	OnPawnSet.AddUniqueDynamic(this, &AAethelnPlayerState::HandlePawnSet);
}

UAbilitySystemComponent* AAethelnPlayerState::GetAbilitySystemComponent() const
{
	return AbilitySystemComponent;
}

bool AAethelnPlayerState::IsGrantableAbilitySpec(const FGameplayAbilitySpec& Spec)
{
	// A plain UGameplayAbility subclass would bypass the choke point.
	const UAethelnGameplayAbility* Ability = Cast<UAethelnGameplayAbility>(Spec.Ability);
	const TCHAR* Problem = Ability == nullptr
		? TEXT("does not derive from UAethelnGameplayAbility")
		: Spec.InputID != INDEX_NONE
			? TEXT("would be granted with an input id")
			: Spec.DynamicAbilityTriggers.Num() > 0
				? TEXT("would be granted with dynamic ability triggers")
				: Ability->FindGrantProblem();
	if (Problem != nullptr)
	{
		UE_LOG(LogAethelnAbilityGrant, Warning, TEXT("Refused to grant ability %s: it %s."), *GetNameSafe(Spec.Ability), Problem);
		return false;
	}
	return true;
}

void AAethelnPlayerState::HandlePawnSet(APlayerState* Player, APawn* NewPawn, APawn* OldPawn)
{
	// Never read Controller->GetPawn() here: during possession it still points at the old pawn.
	if (NewPawn != nullptr)
	{
		// Clients converge on the server's replicated avatar either way.
		AbilitySystemComponent->InitAbilityActorInfo(this, NewPawn);

		// Keyed on the flag only, never on OldPawn: re-possession (for example a
		// respawn) never re-grants, refills, or resets cooldowns. #21 owns respawn.
		if (HasAuthority() && !bCombatStateInitialized)
		{
			bCombatStateInitialized = true;
			for (const TSubclassOf<UGameplayAbility>& AbilityClass : GrantedAbilities)
			{
				const FGameplayAbilitySpec Spec(AbilityClass, 1);
				if (IsGrantableAbilitySpec(Spec))
				{
					AbilitySystemComponent->GiveAbility(Spec);
				}
			}
			UAethelnAttributeInitEffect::ApplyTo(*AbilitySystemComponent, ProvisionalInitialAttributes);
		}
		return;
	}

	if (!HasAuthority())
	{
		return;
	}

	// Unpossession, or the possessed pawn is being destroyed. InitAbilityActorInfo
	// does not cancel on an avatar change, so cancel explicitly.
	AbilitySystemComponent->CancelAllAbilities();

	// SetAvatarActor, never ClearActorInfo: the owner must stay the PlayerState.
	if (OldPawn == nullptr || AbilitySystemComponent->GetAvatarActor() == OldPawn)
	{
		AbilitySystemComponent->SetAvatarActor(nullptr);
	}
}
