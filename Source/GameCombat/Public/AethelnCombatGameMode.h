#pragma once

#include "AethelnGameModeBase.h"
#include "CoreMinimal.h"
#include "AethelnCombatGameMode.generated.h"

/**
 * Game mode for the GAS combat foundation: spawns AAethelnPlayerState.
 * Must stay on AGameModeBase, never AGameMode: AGameMode::FindInactivePlayer
 * would reuse the old PlayerState on reconnect, which breaks the activation
 * sequence policy and the reconnect test. A base-class change must revisit both.
 * The input-enabled pawn is selected in a later #19 phase (P5).
 */
UCLASS()
class GAMECOMBAT_API AAethelnCombatGameMode : public AAethelnGameModeBase
{
	GENERATED_BODY()

public:
	AAethelnCombatGameMode();
};
