#pragma once

#include "CoreMinimal.h"
#include "AethelnAttackTypes.generated.h"

/**
 * Whether the seam accepted a request's aim as sent or clamped it toward the
 * server reference (docs/attack-timeline-and-combo.md, Validation additions).
 */
UENUM()
enum class EAethelnAimCorrection : uint8
{
	None = 0,
	AimCorrected = 1
};
