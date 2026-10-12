#pragma once

#include "CoreMinimal.h"
#include "Subsystems/WorldSubsystem.h"
#include "AethelnDeathSubsystem.generated.h"

class UAethelnAbilitySystemComponent;
class UAethelnCombatTimelineSubsystem;

/**
 * Server-only death and respawn (#21 P1 and P2, docs/death-and-respawn.md). Binds the timeline's lethal
 * notification and enters death once per life: State.Dead through UAethelnDeathStateEffect, every active
 * ability canceled, and the avatar's movement stopped. It then waits for the respawn deadline on the world
 * clock and respawns the player through the world's game mode.
 */
UCLASS(Config = Game)
class GAMECOMBAT_API UAethelnDeathSubsystem : public UWorldSubsystem
{
	GENERATED_BODY()

public:
	/** Created exactly where the combat timeline is: Game and PIE worlds that are not clients. */
	virtual bool ShouldCreateSubsystem(UObject* Outer) const override;
	virtual void Initialize(FSubsystemCollectionBase& Collection) override;
	virtual void Deinitialize() override;

	/**
	 * Authority only. Enters death for a player ASC with authoritative Health at or below zero and
	 * no State.Dead; refuses anything else. Returns true only when this call entered death. A death
	 * from a contact passes the lethal activation id and the lethal contact time: the chain ends at
	 * that time, and the Death event carries the id. Otherwise the chain ends at the processing time.
	 * A successful call starts the respawn wait.
	 */
	static bool ApplyDeath(UAethelnAbilitySystemComponent& Victim, const FGuid& ActivationId = FGuid(), TOptional<double> ContactTime = TOptional<double>());

	/**
	 * Authority only. Respawns a dead player: unpossess and destroy the dead pawn, restore Health,
	 * Endurance and Guard to their maxima, remove the death effect, then let the game mode restart the
	 * player with a new pawn. Refuses silently unless the ASC is a dead player's; refuses and logs, with
	 * the player left dead, when it cannot restart the player. Returns true only when this call respawned.
	 * Cooldowns, granted abilities and the maxima are never touched.
	 */
	static bool Respawn(UAethelnAbilitySystemComponent& Victim);

	/**
	 * Server-side config: seconds from death to respawn. Provisional and owner-set to 5 (issue #21
	 * comment 6131998770, 2026-10-12); re-tuned at the P5 feel test. Unset (0), negative, or non-finite
	 * means no automatic respawn: the player stays dead and the server logs why.
	 */
	UPROPERTY(Config)
	float ProvisionalRespawnDelaySeconds = 0.0f;

private:
	struct FPendingRespawn
	{
		double Deadline = 0.0;
		uint64 Generation = 0;
	};

	void HandleLethalResult(UAethelnAbilitySystemComponent* Target, const FGuid& ActivationId, double ContactTime);
	void HandlePostActorTick(UWorld* World, ELevelTick TickType, float DeltaSeconds);
	/** Records the death: its Death event and its respawn deadline. */
	void BeginRespawnWait(UAethelnAbilitySystemComponent& Victim, const FGuid& ActivationId);
	void EmitDeathEvent(const FGuid& ActivationId, uint64 Generation) const;

	TWeakObjectPtr<UAethelnCombatTimelineSubsystem> Timeline;
	FDelegateHandle LethalHandle;
	FDelegateHandle TickHandle;
	TMap<TWeakObjectPtr<UAethelnAbilitySystemComponent>, FPendingRespawn> Pending;
	/** One per death in this world; also the Death event's sequence (never 0). */
	uint64 LifeGeneration = 0;
};
