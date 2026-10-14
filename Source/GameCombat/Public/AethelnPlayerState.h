#pragma once

#include "AbilitySystemInterface.h"
#include "AethelnActivationTypes.h"
#include "AethelnCombatEffects.h"
#include "AethelnHudSource.h"
#include "AethelnMovementActionAuthority.h"
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
class GAMECOMBAT_API AAethelnPlayerState : public APlayerState, public IAbilitySystemInterface, public IAethelnMovementActionAuthority, public IAethelnHudStateSource
{
	GENERATED_BODY()

public:
	AAethelnPlayerState();

	virtual void PostInitializeComponents() override;
	/**
	 * A logout (CleanupPlayerState). Inside the disconnect grace window this PlayerState stays, inactive and unowned, with its pawn,
	 * until the player reconnects or the window ends (#21 P4b, UAethelnDeathSubsystem::RetainForGrace). Otherwise the engine
	 * default destroys it.
	 */
	virtual void OnDeactivated() override;
	virtual UAbilitySystemComponent* GetAbilitySystemComponent() const override;

	/** The movement authority (#18 T1) forwards to the ASC, which resolves the current grant and possessed avatar. */
	virtual FAethelnDodgeMovementDefinition GetDodgeMovementDefinition() const override;
	virtual bool CanPredictDodge() const override;
	virtual bool TryAuthorizeDodge(const FAethelnDodgeStartRequest& Request) override;

	/** HUD (#61): the attributes and owned timed tags this machine currently has. Presentation only. */
	virtual FAethelnHudSnapshot GetHudSnapshot() const override;
	/** HUD (#61): one event per owner activation outcome and per aim-corrected started step. */
	virtual FAethelnHudActionOutcomeDelegate& OnHudActionOutcome() override { return HudActionOutcome; }
	static FAethelnHudActionOutcome ToHudOutcome(uint32 Sequence, EAethelnActivationResult Result);

	/**
	 * Server only (#21 P4, P4b). The key under which a logout keeps this player and a reconnect takes it back. Set by the
	 * game mode at login (AAethelnCombatGameMode::InitNewPlayer); empty means no carry. Never replicated and never set by a
	 * client RPC.
	 */
	void SetReconnectKey(const FString& Key) { ReconnectKey = Key; }
	const FString& GetReconnectKey() const { return ReconnectKey; }

	/** Server only: abilities granted and the first attributes applied, at the first possession. */
	bool IsCombatStateInitialized() const { return bCombatStateInitialized; }

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

	/** Server-side config: Endurance and Guard recovery, started once with the initial attributes. TBD (#107); unset starts none. */
	UPROPERTY(Config)
	FAethelnResourceRecoveryValues ProvisionalEnduranceRecovery;

	UPROPERTY(Config)
	FAethelnResourceRecoveryValues ProvisionalGuardRecovery;

	/**
	 * Placeholder network update frequency, set only from Config/DefaultGame.ini; #45 owns the
	 * final value. Without config (0) the engine's 1 Hz PlayerState default stays.
	 */
	UPROPERTY(Config)
	float ProvisionalNetUpdateFrequency = 0.0f;

private:
	UFUNCTION()
	void HandlePawnSet(APlayerState* Player, APawn* NewPawn, APawn* OldPawn);

	FAethelnHudActionOutcomeDelegate HudActionOutcome;

	UPROPERTY(VisibleAnywhere, Category = "Aetheln|Abilities")
	TObjectPtr<UAethelnAbilitySystemComponent> AbilitySystemComponent;

	UPROPERTY()
	TObjectPtr<UAethelnCombatAttributeSet> AttributeSet;

	/** Server only, never replicated: abilities granted and initial attributes applied. */
	bool bCombatStateInitialized = false;

	/** Server only, never replicated: see SetReconnectKey. */
	FString ReconnectKey;
};
