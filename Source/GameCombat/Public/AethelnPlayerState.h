#pragma once

#include "AbilitySystemInterface.h"
#include "AethelnActivationTypes.h"
#include "AethelnCombatEffects.h"
#include "AethelnCombatInputSink.h"
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
class GAMECOMBAT_API AAethelnPlayerState : public APlayerState, public IAbilitySystemInterface, public IAethelnMovementActionAuthority, public IAethelnHudStateSource, public IAethelnCombatInputSink
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

	/** The local controller's ability press (#60 P6): forwards to the ASC's activation request. Intent only. */
	virtual void RequestAbilityPress(FGameplayTag AbilityId) override;

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

	virtual void GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const override;

	/**
	 * Server only (#21 P4b). Marks this PlayerState kept for the grace window: inactive, and out of the server's player list
	 * and, through bKeptForGrace, every client's. The engine's own bIsInactive replicates only in the initial bunch
	 * (COND_InitialOnly, PlayerState.cpp:440-443), so a client that already holds this PlayerState would never see it.
	 */
	void MarkKeptForGrace();
	bool IsKeptForGrace() const { return bKeptForGrace; }

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

	/** Server-side config: initial attribute values, applied once through UAethelnAttributeInitEffect. The player's are the owner's provisional values (#107 comment 6232938657), re-tuned at the feel test. */
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

	/** Clients: a kept PlayerState becomes inactive here too, which takes it out of the local player list (OnRep_bIsInactive). */
	UFUNCTION()
	void OnRep_KeptForGrace();

	/** See MarkKeptForGrace. Replicated to every client; never set by a client. */
	UPROPERTY(ReplicatedUsing = OnRep_KeptForGrace)
	bool bKeptForGrace = false;

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
