#pragma once

#include "CoreMinimal.h"
#include "Subsystems/WorldSubsystem.h"
#include "AethelnDeathSubsystem.generated.h"

class UAethelnAbilitySystemComponent;
class UAethelnCombatTimelineSubsystem;

/**
 * Server-only death transition (#21 P1, docs/death-and-respawn.md). Binds the timeline's lethal
 * notification and enters death once per life: State.Dead through UAethelnDeathStateEffect, every
 * active ability canceled, and the avatar's movement stopped.
 */
UCLASS()
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
	 * no State.Dead; refuses anything else. Returns true only when this call entered death.
	 */
	static bool ApplyDeath(UAethelnAbilitySystemComponent& Victim);

private:
	void HandleLethalResult(UAethelnAbilitySystemComponent* Target, const FGuid& ActivationId, double ContactTime);

	TWeakObjectPtr<UAethelnCombatTimelineSubsystem> Timeline;
	FDelegateHandle LethalHandle;
};
