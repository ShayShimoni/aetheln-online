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
 * Login also stamps the reconnect key on the new PlayerState (#21 P4); see ResolveReconnectKey.
 */
UCLASS(Config = Game)
class GAMECOMBAT_API AAethelnCombatGameMode : public AAethelnGameModeBase
{
	GENERATED_BODY()

public:
	AAethelnCombatGameMode();

	/** Returns InputEnabledPawnClass when it loads, otherwise the inherited DefaultPawnClass. */
	virtual UClass* GetDefaultPawnClassForController_Implementation(AController* InController) override;

	/** Stamps the reconnect key (ResolveReconnectKey) on the new player's PlayerState before its first possession. */
	virtual FString InitNewPlayer(APlayerController* NewPlayerController, const FUniqueNetIdRepl& UniqueId, const FString& Options, const FString& Portal = TEXT("")) override;

	/**
	 * The one place a player's reconnect identity is decided (#21 P4, docs/death-and-respawn.md). Prototype key: the
	 * opaque "ReconnectKey" login option, 1 to 64 characters of A-Z, a-z, 0-9, '-' and '_'. It is client-supplied and
	 * not authenticated: it only names a snapshot the server already holds, and it never carries state. A vendor or
	 * account identity replaces this function when #35 and #36 decide one. Returns an empty key, which means
	 * no carry, for a missing or malformed option.
	 */
	static FString ResolveReconnectKey(const FString& Options);

	/**
	 * Config/DefaultGame.ini: the generated input-enabled pawn Blueprint class, for example
	 * /Game/POC/BP_MovementPOCCharacter.BP_MovementPOCCharacter_C. Empty keeps DefaultPawnClass.
	 */
	UPROPERTY(Config)
	TSoftClassPtr<APawn> InputEnabledPawnClass;

private:
	/** The spawn path asks for the class several times; warn once per game mode instance. */
	bool bWarnedPawnClassLoad = false;
};
