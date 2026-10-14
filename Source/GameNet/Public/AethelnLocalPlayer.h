#pragma once

#include "CoreMinimal.h"
#include "Engine/LocalPlayer.h"
#include "AethelnLocalPlayer.generated.h"

/**
 * Client side of the prototype reconnect key (#21 P4b, docs/death-and-respawn.md, Identity key). The server issues the
 * key and sends it to this player's own connection only; this local player keeps it in memory and presents it in the
 * login options of its next join, so a rejoin inside the grace window resumes the player's pawn and state. The key is
 * an opaque server-issued string, never a vendor identity; #35 and #36 replace it.
 */
UCLASS()
class GAMENET_API UAethelnLocalPlayer : public ULocalPlayer
{
	GENERATED_BODY()

public:
	/** PendingNetGame.cpp:335 appends these to the join URL, so the key reaches the server's login options. */
	virtual FString GetGameLoginOptions() const override { return ReconnectKey.IsEmpty() ? FString() : FString(TEXT("ReconnectKey=")) + ReconnectKey; }

	void SetReconnectKey(const FString& Key) { ReconnectKey = Key; }
	const FString& GetReconnectKey() const { return ReconnectKey; }

private:
	/** In memory only: never saved, and lost when the process ends. */
	FString ReconnectKey;
};
