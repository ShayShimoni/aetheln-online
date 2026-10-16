#pragma once

#include "CoreMinimal.h"
#include "GameFramework/PlayerController.h"
#include "AethelnPlayerController.generated.h"

/**
 * The combat game mode's player controller (#21 P4b, docs/death-and-respawn.md). A logout inside the disconnect grace
 * window keeps the player's pawn in the world, server-controlled and attackable, and the server sends each player its
 * reconnect key over this controller's own connection.
 */
UCLASS()
class GAMECOMBAT_API AAethelnPlayerController : public APlayerController
{
	GENERATED_BODY()

public:
	/**
	 * Called by the engine when the connection ends (APlayerController::Destroyed). For a player kept for the grace window
	 * (UAethelnDeathSubsystem::CanRetain), the pawn stays: unpossessed, so no input reaches it, and pointed back at the kept
	 * PlayerState, so its ASC still resolves and takes damage. Otherwise the engine destroys the pawn.
	 */
	virtual void PawnLeavingGame() override;

	/** Server to the owning client only: the reconnect key this player presents at its next login. Never multicast. */
	UFUNCTION(Client, Reliable)
	void ClientReceiveReconnectKey(const FString& Key);
};
