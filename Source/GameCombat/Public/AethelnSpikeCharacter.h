#pragma once

#include "AethelnPlayerCharacter.h"
#include "CoreMinimal.h"
#include "AethelnSpikeCharacter.generated.h"

class UAethelnSpikeAuthorityComponent;

UCLASS()
class GAMECOMBAT_API AAethelnSpikeCharacter : public AAethelnPlayerCharacter
{
	GENERATED_BODY()

public:
	AAethelnSpikeCharacter();
	virtual void PossessedBy(AController* NewController) override;
	virtual void OnRep_PlayerState() override;

	UFUNCTION(BlueprintCallable, Category = "Spike|Combat")
	void SubmitFreeAimAttack(const FVector& AimDirection);

private:
	void InitializePlayerStateAbilitySystem();

	UPROPERTY(VisibleAnywhere, Category = "Spike|Combat")
	TObjectPtr<UAethelnSpikeAuthorityComponent> AuthorityComponent;
};
