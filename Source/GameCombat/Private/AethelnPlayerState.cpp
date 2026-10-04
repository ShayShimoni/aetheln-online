#include "AethelnPlayerState.h"

#include "Abilities/GameplayAbility.h"
#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatAttributeSet.h"
#include "GameFramework/Pawn.h"

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
	SetNetUpdateFrequency(ProvisionalNetUpdateFrequency);

	// The ASC's InitializeComponent made this PlayerState its avatar. There is no
	// pawn yet, so this sets the avatar to null on the server and on clients.
	AbilitySystemComponent->InitAbilityActorInfo(this, GetPawn());
	OnPawnSet.AddUniqueDynamic(this, &AAethelnPlayerState::HandlePawnSet);
}

UAbilitySystemComponent* AAethelnPlayerState::GetAbilitySystemComponent() const
{
	return AbilitySystemComponent;
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
				if (AbilityClass != nullptr)
				{
					AbilitySystemComponent->GiveAbility(FGameplayAbilitySpec(AbilityClass, 1));
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
