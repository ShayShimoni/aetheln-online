#pragma once

#include "CoreMinimal.h"
#include "GameplayTagContainer.h"
#include "UObject/Interface.h"
#include "AethelnCombatInputSink.generated.h"

UINTERFACE(MinimalAPI)
class UAethelnCombatInputSink : public UInterface
{
	GENERATED_BODY()
};

/**
 * Presentation-safe client entry for ability presses (#60 P6). GameUI calls it on the local
 * controller's PlayerState and knows no GAS type. The press is intent only: the server decides
 * whether anything starts (docs/attack-timeline-and-combo.md, Input path across modules).
 */
class GAMECORE_API IAethelnCombatInputSink
{
	GENERATED_BODY()

public:
	virtual void RequestAbilityPress(FGameplayTag AbilityId) = 0;
};
