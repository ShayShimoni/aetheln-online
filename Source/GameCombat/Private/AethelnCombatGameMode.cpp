#include "AethelnCombatGameMode.h"

#include "AethelnPlayerState.h"
#include "GameFramework/Pawn.h"

DEFINE_LOG_CATEGORY_STATIC(LogAethelnCombatGameMode, Log, All);

AAethelnCombatGameMode::AAethelnCombatGameMode()
{
	PlayerStateClass = AAethelnPlayerState::StaticClass();
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
