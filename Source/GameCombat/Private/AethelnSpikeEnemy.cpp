#include "AethelnSpikeEnemy.h"

#include "AbilitySystemComponent.h"
#include "AethelnSpikeAttributeSet.h"
#include "Components/SphereComponent.h"

AAethelnSpikeEnemy::AAethelnSpikeEnemy()
{
	bReplicates = true;

	USphereComponent* Collision = CreateDefaultSubobject<USphereComponent>(TEXT("Collision"));
	Collision->InitSphereRadius(50.0f);
	Collision->SetCollisionEnabled(ECollisionEnabled::QueryOnly);
	Collision->SetCollisionObjectType(ECC_WorldDynamic);
	Collision->SetCollisionResponseToAllChannels(ECR_Overlap);
	RootComponent = Collision;

	AbilitySystemComponent = CreateDefaultSubobject<UAbilitySystemComponent>(TEXT("AbilitySystemComponent"));
	AbilitySystemComponent->SetIsReplicated(true);
	AbilitySystemComponent->SetReplicationMode(EGameplayEffectReplicationMode::Minimal);
	AttributeSet = CreateDefaultSubobject<UAethelnSpikeAttributeSet>(TEXT("AttributeSet"));
}

void AAethelnSpikeEnemy::BeginPlay()
{
	Super::BeginPlay();
	if (AbilitySystemComponent != nullptr)
	{
		AbilitySystemComponent->InitAbilityActorInfo(this, this);
	}
}

UAbilitySystemComponent* AAethelnSpikeEnemy::GetAbilitySystemComponent() const
{
	return AbilitySystemComponent;
}

float AAethelnSpikeEnemy::GetHealth() const
{
	return AttributeSet != nullptr ? AttributeSet->GetHealth() : 0.0f;
}
