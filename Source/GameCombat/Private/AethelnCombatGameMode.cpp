#include "AethelnCombatGameMode.h"

#include "AethelnDeathSubsystem.h"
#include "AethelnPlayerController.h"
#include "AethelnPlayerState.h"
#include "Engine/World.h"
#include "GameFramework/Pawn.h"
#include "Kismet/GameplayStatics.h"

DEFINE_LOG_CATEGORY_STATIC(LogAethelnCombatGameMode, Log, All);

AAethelnCombatGameMode::AAethelnCombatGameMode()
{
	PlayerStateClass = AAethelnPlayerState::StaticClass();
	PlayerControllerClass = AAethelnPlayerController::StaticClass();
}

void AAethelnCombatGameMode::PreLogin(const FString& Options, const FString& Address, const FUniqueNetIdRepl& UniqueId, FString& ErrorMessage)
{
	Super::PreLogin(Options, Address, UniqueId, ErrorMessage);
	const FString Key = ResolveReconnectKey(Options);
	if (!ErrorMessage.IsEmpty() || Key.IsEmpty()) { return; }
	if (const AAethelnPlayerState* PlayerState = FindConnectedPlayer(Key))
	{
		// Only a rejoin from the same client process, which still holds its key, while its old connection is alive: it rejoins once
		// that connection closes. A crashed or restarted client has lost its key and is a new session (the #35 exception).
		ErrorMessage = TEXT("The reconnect key belongs to a connected player.");
		UE_LOG(LogAethelnCombatGameMode, Log, TEXT("Refused a login: its reconnect key belongs to the connected player %s."), *GetNameSafe(PlayerState));
	}
}

const AAethelnPlayerState* AAethelnCombatGameMode::FindConnectedPlayer(const FString& Key) const
{
	// A kept player has no controller, so only connected players are found here: its key is the reconnect, not a duplicate.
	for (FConstPlayerControllerIterator Iterator = GetWorld()->GetPlayerControllerIterator(); Iterator; ++Iterator)
	{
		const APlayerController* Controller = Iterator->Get();
		const AAethelnPlayerState* PlayerState = Controller != nullptr ? Controller->GetPlayerState<AAethelnPlayerState>() : nullptr;
		if (PlayerState != nullptr && PlayerState->GetReconnectKey() == Key) { return PlayerState; }
	}
	return nullptr;
}

FString AAethelnCombatGameMode::InitNewPlayer(APlayerController* NewPlayerController, const FUniqueNetIdRepl& UniqueId, const FString& Options, const FString& Portal)
{
	const FString Error = Super::InitNewPlayer(NewPlayerController, UniqueId, Options, Portal);
	if (AAethelnPlayerState* PlayerState = NewPlayerController != nullptr ? NewPlayerController->GetPlayerState<AAethelnPlayerState>() : nullptr)
	{
		// Only a key that names a kept player, and that no connected player holds, is taken as presented; every other login gets
		// a new server-issued key. So no client chooses its own key, and two connected players never share one, even when a first
		// login's restart (and so its takeover, which runs inside PostLogin) is deferred.
		const FString Presented = ResolveReconnectKey(Options);
		const UAethelnDeathSubsystem* Deaths = GetWorld()->GetSubsystem<UAethelnDeathSubsystem>();
		const bool bResumes = Deaths != nullptr && !Presented.IsEmpty() && Deaths->IsRetainedKey(Presented) && FindConnectedPlayer(Presented) == nullptr;
		PlayerState->SetReconnectKey(bResumes ? Presented : IssueReconnectKey());
	}
	return Error;
}

void AAethelnCombatGameMode::PostLogin(APlayerController* NewPlayer)
{
	Super::PostLogin(NewPlayer);
	AAethelnPlayerController* Controller = Cast<AAethelnPlayerController>(NewPlayer);
	const AAethelnPlayerState* PlayerState = NewPlayer != nullptr ? NewPlayer->GetPlayerState<AAethelnPlayerState>() : nullptr;
	if (Controller != nullptr && PlayerState != nullptr && !PlayerState->GetReconnectKey().IsEmpty())
	{
		Controller->ClientReceiveReconnectKey(PlayerState->GetReconnectKey());
	}
}

void AAethelnCombatGameMode::RestartPlayer(AController* NewPlayer)
{
	AAethelnPlayerState* PlayerState = NewPlayer != nullptr ? NewPlayer->GetPlayerState<AAethelnPlayerState>() : nullptr;
	APawn* Kept = nullptr;
	const bool bTookOver = PlayerState != nullptr && NewPlayer->GetPawn() == nullptr && UAethelnDeathSubsystem::TakeOverRetained(*PlayerState, Kept);
	if (Kept == nullptr)
	{
		Super::RestartPlayer(NewPlayer);
	}
	else
	{
		// The player resumes its own pawn where it stands, through the engine's own finish step (as RestartPlayerAtPlayerStart).
		NewPlayer->SetPawn(Kept);
		FinishRestartPlayer(NewPlayer, Kept->GetActorRotation());
	}
	if (bTookOver)
	{
		// After the first possession, whose restore takes the snapshot under the presented key: the engine logged that key at login,
		// so a resume replaces it, and PostLogin, which runs this restart, sends the new key.
		PlayerState->SetReconnectKey(IssueReconnectKey());
	}
}

FString AAethelnCombatGameMode::ResolveReconnectKey(const FString& Options)
{
	const FString Key = UGameplayStatics::ParseOption(Options, TEXT("ReconnectKey"));
	if (Key.Len() < 1 || Key.Len() > 64) { return FString(); }
	for (const TCHAR Character : Key)
	{
		const bool bAlphanumeric = (Character >= TEXT('A') && Character <= TEXT('Z')) || (Character >= TEXT('a') && Character <= TEXT('z')) || (Character >= TEXT('0') && Character <= TEXT('9'));
		if (!bAlphanumeric && Character != TEXT('-') && Character != TEXT('_')) { return FString(); }
	}
	return Key;
}

FString AAethelnCombatGameMode::IssueReconnectKey()
{
	// A platform that cannot make a GUID returns the all-zero one, which every player would then share: issue no key (no carry).
	const FGuid Guid = FGuid::NewGuid();
	return Guid.IsValid() ? Guid.ToString(EGuidFormats::Digits) : FString();
}

UClass* AAethelnCombatGameMode::GetDefaultPawnClassForController_Implementation(AController* InController)
{
	if (!InputEnabledPawnClass.IsNull())
	{
		// ponytail: synchronous load, once per spawn; preload asynchronously if a hitch shows up.
		if (UClass* PawnClass = InputEnabledPawnClass.LoadSynchronous())
		{
			UE_LOG(LogAethelnCombatGameMode, Verbose, TEXT("Input-enabled pawn class selected: %s"), *PawnClass->GetPathName());
			return PawnClass;
		}
		if (!bWarnedPawnClassLoad)
		{
			bWarnedPawnClassLoad = true;
			UE_LOG(LogAethelnCombatGameMode, Warning, TEXT("Input-enabled pawn class %s did not load; using the default pawn class."), *InputEnabledPawnClass.ToString());
		}
	}
	return Super::GetDefaultPawnClassForController_Implementation(InController);
}
