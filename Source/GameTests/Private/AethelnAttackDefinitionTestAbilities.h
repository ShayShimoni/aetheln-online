#pragma once

#include "AethelnBasicChainAbility.h"
#include "AethelnOathscarAbilities.h"
#include "AethelnAttackDefinitionTestAbilities.generated.h"

/*
 * Abilities whose definition reference is unusable (#84 P4). The reference is set in PostInitProperties because a
 * class default object reads its parent classes' config sections after the constructor.
 */
UCLASS(NotBlueprintable, HideDropdown)
class UAethelnMissingDefinitionTestAbility : public UAethelnBasicChainAbility
{
	GENERATED_BODY()

public:
	virtual void PostInitProperties() override
	{
		Super::PostInitProperties();
		Definition = TSoftObjectPtr<UAethelnAttackDefinition>(FSoftObjectPath(TEXT("/Game/Combat/Attacks/DA_DoesNotExist.DA_DoesNotExist")));
	}
};

/** An ability with another ID, pointed at the basic chain's real definition. */
UCLASS(NotBlueprintable, HideDropdown)
class UAethelnOtherAbilityDefinitionTestAbility : public UAethelnInstantStrikeAbility
{
	GENERATED_BODY()

public:
	virtual void PostInitProperties() override
	{
		Super::PostInitProperties();
		Definition = TSoftObjectPtr<UAethelnAttackDefinition>(FSoftObjectPath(TEXT("/Game/Combat/Attacks/DA_SwordShieldBasicChain.DA_SwordShieldBasicChain")));
	}
};
