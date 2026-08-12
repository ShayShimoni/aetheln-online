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
	virtual void Tick(float DeltaSeconds) override;
	virtual FString InitNewPlayer(APlayerController* NewPlayerController, const FUniqueNetIdRepl& UniqueId, const FString& Options, const FString& Portal = TEXT("")) override;
	virtual void PostLogin(APlayerController* NewPlayer) override;
	virtual void Logout(AController* Exiting) override;

	static bool IsAllowedScenarioClientId(const FString& ClientId);
	static FString MakeScenarioConnectionId(const FString& RunId, uint32 Sequence);

private:
	FString GetIdentityFields() const;
	FString GetClientId(const AController* Controller) const;
	void PositionEnemyForFirstClient(APlayerController* NewPlayer);

	UPROPERTY()
	TObjectPtr<AActor> SpawnedEnemy;

	TMap<TWeakObjectPtr<AController>, FString> ClientIds;
	TMap<TWeakObjectPtr<AController>, FString> ConnectionIds;
	TMap<TWeakObjectPtr<AController>, FVector> InitialLocations;
	TSet<FString> MovementObserved;
	FString ScenarioId;
	FString ProfileId;
	FString RunId;
	FString ServerEndpoint;
	FString ServerMap;
	FString NetworkConfigIdentity;
	uint32 NextConnectionSequence = 1;
	bool bScenarioEnabled = false;
};
