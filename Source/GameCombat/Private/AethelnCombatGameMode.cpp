#include "AethelnCombatGameMode.h"

#include "AethelnPlayerState.h"
#include "GameFramework/Pawn.h"
#include "Kismet/GameplayStatics.h"

DEFINE_LOG_CATEGORY_STATIC(LogAethelnCombatGameMode, Log, All);

AAethelnCombatGameMode::AAethelnCombatGameMode()
{
	PlayerStateClass = AAethelnPlayerState::StaticClass();
}

FString AAethelnCombatGameMode::InitNewPlayer(APlayerController* NewPlayerController, const FUniqueNetIdRepl& UniqueId, const FString& Options, const FString& Portal)
{
	const FString Error = Super::InitNewPlayer(NewPlayerController, UniqueId, Options, Portal);
	if (AAethelnPlayerState* PlayerState = NewPlayerController != nullptr ? NewPlayerController->GetPlayerState<AAethelnPlayerState>() : nullptr)
	{
		PlayerState->SetReconnectKey(ResolveReconnectKey(Options));
	}
	return Error;
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
