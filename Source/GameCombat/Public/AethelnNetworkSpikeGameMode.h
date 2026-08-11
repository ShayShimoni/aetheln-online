#pragma once

#include "CoreMinimal.h"
#include "GameFramework/GameModeBase.h"
#include "AethelnNetworkSpikeGameMode.generated.h"

UCLASS()
class GAMECOMBAT_API AAethelnNetworkSpikeGameMode : public AGameModeBase
{
	GENERATED_BODY()

public:
	AAethelnNetworkSpikeGameMode();
	virtual void BeginPlay() override;
	virtual void PostLogin(APlayerController* NewPlayer) override;
	virtual void Logout(AController* Exiting) override;

private:
	UPROPERTY()
	TObjectPtr<AActor> SpawnedEnemy;
};
