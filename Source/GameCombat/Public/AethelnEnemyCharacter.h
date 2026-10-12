#pragma once

#include "AethelnCombatAICharacter.h"
#include "CoreMinimal.h"
#include "Engine/NetSerialization.h"
#include "GameplayTagContainer.h"
#include "AethelnEnemyCharacter.generated.h"

class UAethelnEnemyAttackAbility;

/** Server states of the prototype enemy (docs/enemy-ai-and-navigation.md, State Machine). Reset is an instant action, not a state. */
UENUM()
enum class EAethelnEnemyState : uint8
{
	Idle,
	Engage,
	Telegraph,
	Attack,
	Interrupted,
	Dead,
	Return
};

/**
 * The only enemy state clients receive. Wind-up, active, and recovery are derived from StepStartServerTime and
 * the attack ability's configured windows, as observers of the player chain do. AttackCounter wraps; it makes a
 * repeated attack replicate as a change. A reset shows as a new Idle state at home.
 */
USTRUCT()
struct GAMECOMBAT_API FAethelnEnemyPresentationState
{
	GENERATED_BODY()
	UPROPERTY() EAethelnEnemyState State = EAethelnEnemyState::Idle;
	UPROPERTY() double StateStartServerTime = 0.0;
	UPROPERTY() FGameplayTag AbilityId;
	UPROPERTY() uint32 ContentVersion = 0;
	UPROPERTY() double StepStartServerTime = 0.0;
	UPROPERTY() FVector_NetQuantizeNormal AcceptedAim = FVector_NetQuantizeNormal(ForceInitToZero);
	UPROPERTY() uint32 AttackCounter = 0;
};

/**
 * The prototype enemy (#83, #20). The ASC stays on this pawn (the AI base); an AAethelnEnemyController
 * possesses it on the server and owns every decision. Declares no RPC: clients only read replicated movement,
 * attributes, result cues, and the presentation state.
 */
UCLASS(Config = Game)
class GAMECOMBAT_API AAethelnEnemyCharacter : public AAethelnCombatAICharacter
{
	GENERATED_BODY()

public:
	explicit AAethelnEnemyCharacter(const FObjectInitializer& ObjectInitializer = FObjectInitializer::Get());

	virtual void GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const override;

	/** Server: the spawn transform, recorded in BeginPlay. */
	const FTransform& GetHome() const { return Home; }
	const FAethelnEnemyPresentationState& GetPresentationState() const { return PresentationState; }
	/** Server only; the controller is the only writer. */
	void SetPresentationState(const FAethelnEnemyPresentationState& State);

	/** The attack ability granted on the server in BeginPlay if its definition is valid. Set before BeginPlay. */
	UPROPERTY(Config)
	TSubclassOf<UAethelnEnemyAttackAbility> AttackAbilityClass;

protected:
	virtual void BeginPlay() override;

private:
	FTransform Home = FTransform::Identity;

	UPROPERTY(Replicated)
	FAethelnEnemyPresentationState PresentationState;
};
