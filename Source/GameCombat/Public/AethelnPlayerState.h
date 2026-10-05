#pragma once

#include "AbilitySystemInterface.h"
#include "AethelnCombatEffects.h"
#include "CoreMinimal.h"
#include "GameFramework/PlayerState.h"
#include "AethelnPlayerState.generated.h"

class UAethelnAbilitySystemComponent;
class UAethelnCombatAttributeSet;
class UGameplayAbility;
struct FGameplayAbilitySpec;

/**
 * Owns the player Ability System Component (Mixed replication) and the combat
 * attribute set. The possessed pawn is the ASC's avatar; before the first
 * possession, and after unpossession, the avatar is null. Abilities are granted
 * and initial attributes applied once per PlayerState, on the server.
 * See docs/gas-foundation.md (Lifecycle).
 */
UCLASS(Config = Game)
class GAMECOMBAT_API AAethelnPlayerState : public APlayerState, public IAbilitySystemInterface
{
	GENERATED_BODY()

public:
	AAethelnPlayerState();

	virtual void PostInitializeComponents() override;
	virtual UAbilitySystemComponent* GetAbilitySystemComponent() const override;

	UAethelnAbilitySystemComponent* GetAethelnAbilitySystemComponent() const { return AbilitySystemComponent; }
	const UAethelnCombatAttributeSet* GetCombatAttributeSet() const { return AttributeSet; }

	/**
	 * Grant-time validation (docs/gas-foundation.md, Abilities). Refuses, and logs, a spec
	 * whose ability does not derive from UAethelnGameplayAbility, whose definition fails
	 * UAethelnGameplayAbility::FindGrantProblem, or that carries an input id or
	 * spec-level dynamic ability triggers.
	 */
	static bool IsGrantableAbilitySpec(const FGameplayAbilitySpec& Spec);

	/** Server-side config: abilities granted on the first possession, each through grant validation. */
	UPROPERTY(Config)
	TArray<TSubclassOf<UGameplayAbility>> GrantedAbilities;

	/** Server-side config: initial attribute values, applied once through UAethelnAttributeInitEffect. TBD (#107, #45). */
	UPROPERTY(Config)
	FAethelnCombatAttributeInitValues ProvisionalInitialAttributes;

	/**
	 * Placeholder network update frequency, set only from Config/DefaultGame.ini; #45 owns the
	 * final value. Without config (0) the engine's 1 Hz PlayerState default stays.
	 */
	UPROPERTY(Config)
	float ProvisionalNetUpdateFrequency = 0.0f;

private:
	UFUNCTION()
	void HandlePawnSet(APlayerState* Player, APawn* NewPawn, APawn* OldPawn);

	UPROPERTY(VisibleAnywhere, Category = "Aetheln|Abilities")
	TObjectPtr<UAethelnAbilitySystemComponent> AbilitySystemComponent;

	UPROPERTY()
	TObjectPtr<UAethelnCombatAttributeSet> AttributeSet;

	/** Server only, never replicated: abilities granted and initial attributes applied. */
	bool bCombatStateInitialized = false;
};
