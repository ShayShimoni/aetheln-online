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
 * Presentation-safe client entry for ability presses (#60 P6) and releases (#18 P5). GameUI calls it on the local
 * controller's PlayerState and knows no GAS type. Both are intent only: the server decides whether anything starts or
 * ends (docs/attack-timeline-and-combo.md, Input path across modules; docs/dodge-and-block.md, The Block).
 */
class GAMECORE_API IAethelnCombatInputSink
{
	GENERATED_BODY()

public:
	virtual void RequestAbilityPress(FGameplayTag AbilityId) = 0;
	/** The release of a held ability (the block). A release for an ability that is not active is benign: the server refuses it. */
	virtual void RequestAbilityRelease(FGameplayTag AbilityId) = 0;
};
