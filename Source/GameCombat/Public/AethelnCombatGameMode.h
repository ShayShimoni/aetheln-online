#pragma once

#include "AethelnGameModeBase.h"
#include "CoreMinimal.h"
#include "UObject/SoftObjectPtr.h"
#include "AethelnCombatGameMode.generated.h"

class APawn;

/**
 * Game mode for the GAS combat foundation: spawns AAethelnPlayerState.
 * Must stay on AGameModeBase, never AGameMode: AGameMode::FindInactivePlayer
 * would reuse the old PlayerState on reconnect, which breaks the activation
 * sequence policy and the reconnect test. A base-class change must revisit both.
 * The input-enabled pawn is a generated Blueprint, so it is selected by a config
 * soft-class path (P5), never by editing a binary asset by hand.
 */
UCLASS(Config = Game)
class GAMECOMBAT_API AAethelnCombatGameMode : public AAethelnGameModeBase
{
	GENERATED_BODY()

public:
	AAethelnCombatGameMode();

	/** Returns InputEnabledPawnClass when it loads, otherwise the inherited DefaultPawnClass. */
	virtual UClass* GetDefaultPawnClassForController_Implementation(AController* InController) override;

	/**
	 * Config/DefaultGame.ini: the generated input-enabled pawn Blueprint class, for example
	 * /Game/POC/BP_MovementPOCCharacter.BP_MovementPOCCharacter_C. Empty keeps DefaultPawnClass.
	 */
	UPROPERTY(Config)
	TSoftClassPtr<APawn> InputEnabledPawnClass;
};
