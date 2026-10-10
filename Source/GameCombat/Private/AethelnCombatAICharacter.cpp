#include "AethelnCombatAICharacter.h"

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatCollision.h"
#include "Components/CapsuleComponent.h"

AAethelnCombatAICharacter::AAethelnCombatAICharacter(const FObjectInitializer& ObjectInitializer)
	: Super(ObjectInitializer)
{
	AbilitySystemComponent = CreateDefaultSubobject<UAethelnAbilitySystemComponent>(TEXT("AbilitySystemComponent"));
	AbilitySystemComponent->SetIsReplicated(true);
	AbilitySystemComponent->SetReplicationMode(EGameplayEffectReplicationMode::Minimal);
	AttributeSet = CreateDefaultSubobject<UAethelnCombatAttributeSet>(TEXT("CombatAttributeSet"));
	// Contacts resolve on the capsule only; the mesh keeps the channel's Ignore default.
	GetCapsuleComponent()->SetCollisionResponseToChannel(AethelnCombatCollision::QueryChannel, ECR_Overlap);
}

UAbilitySystemComponent* AAethelnCombatAICharacter::GetAbilitySystemComponent() const
{
	return AbilitySystemComponent;
}

void AAethelnCombatAICharacter::PossessedBy(AController* NewController)
{
	Super::PossessedBy(NewController);

	// InitializeComponent already made this pawn owner and avatar; pick up the new controller.
	AbilitySystemComponent->RefreshAbilityActorInfo();
}

void AAethelnCombatAICharacter::BeginPlay()
{
	Super::BeginPlay();

	if (HasAuthority())
	{
		UAethelnAttributeInitEffect::ApplyTo(*AbilitySystemComponent, ProvisionalInitialAttributes);
	}
}
