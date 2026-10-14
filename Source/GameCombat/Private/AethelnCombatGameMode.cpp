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
	// A kept player has no controller, so only connected players are found here: its key is the reconnect, not a duplicate.
	for (FConstPlayerControllerIterator Iterator = GetWorld()->GetPlayerControllerIterator(); Iterator; ++Iterator)
	{
		const APlayerController* Controller = Iterator->Get();
		const AAethelnPlayerState* PlayerState = Controller != nullptr ? Controller->GetPlayerState<AAethelnPlayerState>() : nullptr;
		if (PlayerState != nullptr && PlayerState->GetReconnectKey() == Key)
		{
			// A crashed client waits for its old connection to time out, and then rejoins inside the grace window.
			ErrorMessage = TEXT("The reconnect key belongs to a connected player.");
			UE_LOG(LogAethelnCombatGameMode, Log, TEXT("Refused a login: its reconnect key belongs to the connected player %s."), *GetNameSafe(PlayerState));
			return;
		}
	}
}

FString AAethelnCombatGameMode::InitNewPlayer(APlayerController* NewPlayerController, const FUniqueNetIdRepl& UniqueId, const FString& Options, const FString& Portal)
{
	const FString Error = Super::InitNewPlayer(NewPlayerController, UniqueId, Options, Portal);
	if (AAethelnPlayerState* PlayerState = NewPlayerController != nullptr ? NewPlayerController->GetPlayerState<AAethelnPlayerState>() : nullptr)
	{
		// Only a key that names a kept player is taken as presented; every other login gets a new server-issued key, so no
		// client chooses its own key and two connected players never share one.
		const FString Presented = ResolveReconnectKey(Options);
		const UAethelnDeathSubsystem* Deaths = GetWorld()->GetSubsystem<UAethelnDeathSubsystem>();
		PlayerState->SetReconnectKey(Deaths != nullptr && !Presented.IsEmpty() && Deaths->IsRetainedKey(Presented) ? Presented : IssueReconnectKey());
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
	const AAethelnPlayerState* PlayerState = NewPlayer != nullptr ? NewPlayer->GetPlayerState<AAethelnPlayerState>() : nullptr;
	APawn* Kept = PlayerState != nullptr && NewPlayer->GetPawn() == nullptr ? UAethelnDeathSubsystem::TakeOverRetained(*PlayerState) : nullptr;
	if (Kept == nullptr)
	{
		Super::RestartPlayer(NewPlayer);
		return;
	}
	// The player resumes its own pawn where it stands, through the engine's own finish step (as RestartPlayerAtPlayerStart).
	NewPlayer->SetPawn(Kept);
	FinishRestartPlayer(NewPlayer, Kept->GetActorRotation());
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
	return FGuid::NewGuid().ToString(EGuidFormats::Digits);
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
