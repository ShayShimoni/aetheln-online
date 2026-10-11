#pragma once

#include "Engine/EngineTypes.h"

namespace AethelnCombatCollision
{
	/**
	 * The combat query trace channel, named AethelnCombatQuery in Config/DefaultEngine.ini with
	 * default response Ignore. Character capsules respond with Overlap, set in C++ on the player
	 * pawn and the AI base for every race, sex and appearance alike; meshes keep the default
	 * (docs/attack-timeline-and-combo.md, Target query).
	 */
	inline constexpr ECollisionChannel QueryChannel = ECC_GameTraceChannel1;
}
