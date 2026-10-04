#pragma once

#include "AbilitySystemInterface.h"
#include "AethelnCombatEffects.h"
#include "CoreMinimal.h"
#include "GameFramework/Character.h"
#include "AethelnCombatAICharacter.generated.h"

class UAethelnAbilitySystemComponent;
class UAethelnCombatAttributeSet;

/**
 * Base for AI combatants (#20's enemy). The ASC and attribute set live on the
 * authoritative pawn, in Minimal replication mode; the pawn is both owner and
 * avatar. AI never uses the player activation seam: server code activates its
 * abilities directly.
 */
UCLASS(Config = Game)
class GAMECOMBAT_API AAethelnCombatAICharacter : public ACharacter, public IAbilitySystemInterface
{
	GENERATED_BODY()

public:
	explicit AAethelnCombatAICharacter(const FObjectInitializer& ObjectInitializer = FObjectInitializer::Get());

	virtual UAbilitySystemComponent* GetAbilitySystemComponent() const override;
	virtual void PossessedBy(AController* NewController) override;

	UAethelnAbilitySystemComponent* GetAethelnAbilitySystemComponent() const { return AbilitySystemComponent; }
	const UAethelnCombatAttributeSet* GetCombatAttributeSet() const { return AttributeSet; }

	/** Server-side config: initial attribute values, applied once in BeginPlay. TBD (#20, #107). */
	UPROPERTY(Config)
	FAethelnCombatAttributeInitValues ProvisionalInitialAttributes;

protected:
	virtual void BeginPlay() override;

private:
	UPROPERTY(VisibleAnywhere, Category = "Aetheln|Abilities")
	TObjectPtr<UAethelnAbilitySystemComponent> AbilitySystemComponent;

	UPROPERTY()
	TObjectPtr<UAethelnCombatAttributeSet> AttributeSet;
};
