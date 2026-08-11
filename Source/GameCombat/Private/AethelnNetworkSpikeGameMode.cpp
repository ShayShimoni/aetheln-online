#include "AethelnNetworkSpikeGameMode.h"

#include "AethelnSpikeCharacter.h"
#include "AethelnSpikeEnemy.h"
#include "AethelnSpikePlayerState.h"
#include "Engine/World.h"

AAethelnNetworkSpikeGameMode::AAethelnNetworkSpikeGameMode()
{
	DefaultPawnClass = AAethelnSpikeCharacter::StaticClass();
	PlayerStateClass = AAethelnSpikePlayerState::StaticClass();
}

void AAethelnNetworkSpikeGameMode::BeginPlay()
{
	Super::BeginPlay();
	if (HasAuthority() && GetWorld() != nullptr)
	{
		FActorSpawnParameters SpawnParameters;
		SpawnParameters.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AdjustIfPossibleButAlwaysSpawn;
		SpawnedEnemy = GetWorld()->SpawnActor<AAethelnSpikeEnemy>(
			AAethelnSpikeEnemy::StaticClass(),
			FVector(300.0f, 0.0f, 100.0f),
			FRotator::ZeroRotator,
			SpawnParameters);
	}
}

void AAethelnNetworkSpikeGameMode::PostLogin(APlayerController* NewPlayer)
{
	Super::PostLogin(NewPlayer);
	UE_LOG(LogTemp, Log, TEXT("AethelnSpikeLifecycle PostLogin Player=%s"), *GetNameSafe(NewPlayer));
}

void AAethelnNetworkSpikeGameMode::Logout(AController* Exiting)
{
	UE_LOG(LogTemp, Log, TEXT("AethelnSpikeLifecycle Logout Controller=%s"), *GetNameSafe(Exiting));
	Super::Logout(Exiting);
}
