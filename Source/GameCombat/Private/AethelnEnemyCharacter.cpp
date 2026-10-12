#include "AethelnEnemyCharacter.h"

#include "AethelnAbilitySystemComponent.h"
#include "AethelnEnemyAttackAbility.h"
#include "AethelnEnemyController.h"
#include "AethelnPlayerState.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "Net/UnrealNetwork.h"

AAethelnEnemyCharacter::AAethelnEnemyCharacter(const FObjectInitializer& ObjectInitializer)
	: Super(ObjectInitializer)
{
	AIControllerClass = AAethelnEnemyController::StaticClass();
	AutoPossessAI = EAutoPossessAI::PlacedInWorldOrSpawned;
	AttackAbilityClass = UAethelnEnemyAttackAbility::StaticClass();
	// Face the way it walks; the controller turns it to its aim at the telegraph.
	bUseControllerRotationYaw = false;
	GetCharacterMovement()->bOrientRotationToMovement = true;
}

void AAethelnEnemyCharacter::GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const
{
	Super::GetLifetimeReplicatedProps(OutLifetimeProps);
	DOREPLIFETIME(AAethelnEnemyCharacter, PresentationState);
}

void AAethelnEnemyCharacter::SetPresentationState(const FAethelnEnemyPresentationState& State)
{
	if (HasAuthority()) { PresentationState = State; }
}

void AAethelnEnemyCharacter::BeginPlay()
{
	Super::BeginPlay();
	if (!HasAuthority()) { return; }
	Home = GetActorTransform();
	// The same grant rules as a player's abilities; an unset definition is refused and logged.
	if (AttackAbilityClass == nullptr) { return; }
	const FGameplayAbilitySpec Spec(AttackAbilityClass, 1);
	if (AAethelnPlayerState::IsGrantableAbilitySpec(Spec)) { GetAethelnAbilitySystemComponent()->GiveAbility(Spec); }
}
