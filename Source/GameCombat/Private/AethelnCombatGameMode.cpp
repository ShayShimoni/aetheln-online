#include "AethelnCombatGameMode.h"

#include "AethelnPlayerState.h"

AAethelnCombatGameMode::AAethelnCombatGameMode()
{
	PlayerStateClass = AAethelnPlayerState::StaticClass();
}
