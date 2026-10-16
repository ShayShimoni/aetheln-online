#include "AethelnPlayerController.h"

#include "AethelnDeathSubsystem.h"
#include "AethelnLocalPlayer.h"
#include "AethelnPlayerState.h"
#include "GameFramework/Pawn.h"

void AAethelnPlayerController::PawnLeavingGame()
{
	AAethelnPlayerState* Kept = GetPlayerState<AAethelnPlayerState>();
	APawn* KeptPawn = GetPawn();
	if (Kept == nullptr || KeptPawn == nullptr || !UAethelnDeathSubsystem::CanRetain(*Kept))
	{
		Super::PawnLeavingGame();
		return;
	}
	// Unpossession runs #19's null-pawn case and clears the pawn's PlayerState (Pawn.cpp:719), which is how FindForPawn
	// reaches the ASC. Pointing the pawn back at the kept PlayerState makes the kept pawn that ASC's avatar again.
	UnPossess();
	KeptPawn->SetPlayerState(Kept);
}

void AAethelnPlayerController::ClientReceiveReconnectKey_Implementation(const FString& Key)
{
	if (UAethelnLocalPlayer* Local = Cast<UAethelnLocalPlayer>(GetLocalPlayer()))
	{
		Local->SetReconnectKey(Key);
	}
}
