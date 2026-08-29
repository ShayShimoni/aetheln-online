#include "AethelnNetworkSpikeGameMode.h"

#include "AethelnSpikeCharacter.h"
#include "AethelnSpikeAuthorityComponent.h"
#include "AethelnSpikeEnemy.h"
#include "AethelnSpikePlayerState.h"
#include "AethelnObservability.h"
#include "AethelnObservabilitySubsystem.h"
#include "Engine/GameInstance.h"
#include "Engine/World.h"
#include "GameFramework/PlayerController.h"
#include "GameFramework/PlayerState.h"
#include "Kismet/GameplayStatics.h"
#include "Misc/App.h"
#include "Misc/CommandLine.h"
#include "Misc/EngineVersion.h"
#include "Misc/Parse.h"

namespace AethelnNetworkSpikeScenario
{
	FString ReadArgument(const TCHAR* Key, const FString& Fallback)
	{
		FString Value;
		return FParse::Value(FCommandLine::Get(), Key, Value) && !Value.IsEmpty() ? Value : Fallback;
	}
}

AAethelnNetworkSpikeGameMode::AAethelnNetworkSpikeGameMode()
{
	DefaultPawnClass = AAethelnSpikeCharacter::StaticClass();
	PlayerStateClass = AAethelnSpikePlayerState::StaticClass();
	PrimaryActorTick.bCanEverTick = true;
}

void AAethelnNetworkSpikeGameMode::BeginPlay()
{
	Super::BeginPlay();
	bScenarioEnabled = FParse::Param(FCommandLine::Get(), TEXT("AethelnAuthorityScenario"));
	if (!bScenarioEnabled)
	{
		return;
	}

	ScenarioId = AethelnNetworkSpikeScenario::ReadArgument(TEXT("AethelnScenarioId="), TEXT("network-authority.baseline.v1"));
	ProfileId = AethelnNetworkSpikeScenario::ReadArgument(TEXT("AethelnProfileId="), TEXT("network-profile.unset"));
	RunId = AethelnNetworkSpikeScenario::ReadArgument(TEXT("AethelnRunId="), TEXT("run-unset"));
	ServerEndpoint = AethelnNetworkSpikeScenario::ReadArgument(TEXT("AethelnServerEndpoint="), TEXT("endpoint-unset"));
	ServerMap = AethelnNetworkSpikeScenario::ReadArgument(TEXT("AethelnServerMap="), TEXT("/Game/Maps/StarterMap"));
	NetworkConfigIdentity = AethelnNetworkSpikeScenario::ReadArgument(TEXT("AethelnNetworkConfig="), TEXT("network-config-unset"));

	if (UGameInstance* GameInstance = GetGameInstance())
	{
		if (UAethelnObservabilitySubsystem* Observability = GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>())
		{
			Observability->SetEnvironment(
				AethelnNetworkSpikeScenario::ReadArgument(TEXT("AethelnEnvironment="), TEXT("local")));
			Observability->SetRuntimeContext(
				EAethelnFlowKind::PrototypeAuthority,
				RunId,
				TEXT("network-authority-server"),
				AethelnObservability::ExcludedIdentifier);

			FAethelnBuildIdentity Build;
			Build.SourceRevision = AethelnNetworkSpikeScenario::ReadArgument(TEXT("AethelnSourceRevision="), AethelnObservability::UnknownValue);
			Build.BuildIdentity = AethelnNetworkSpikeScenario::ReadArgument(TEXT("AethelnBuildIdentity="), AethelnObservability::UnknownValue);
			Build.BuildConfiguration = LexToString(FApp::GetBuildConfiguration());
			Build.EngineRevision = FEngineVersion::Current().ToString();
			Build.ToolchainIdentity = AethelnNetworkSpikeScenario::ReadArgument(TEXT("AethelnToolchainIdentity="), AethelnObservability::UnknownValue);
			FAethelnNetworkProfile Profile;
			Profile.ProfileId = ProfileId;
			Observability->SetBuildContext(Build, Profile);
		}
	}

	if (HasAuthority() && GetWorld() != nullptr)
	{
		FActorSpawnParameters SpawnParameters;
		SpawnParameters.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AdjustIfPossibleButAlwaysSpawn;
		SpawnedEnemy = GetWorld()->SpawnActor<AAethelnSpikeEnemy>(
			AAethelnSpikeEnemy::StaticClass(),
			FVector(300.0f, 0.0f, 100.0f),
			FRotator::ZeroRotator,
			SpawnParameters);
		UE_LOG(LogTemp, Log, TEXT("AUTHORITY server_ready endpoint=%s map=%s network_config=%s %s"), *ServerEndpoint, *ServerMap, *NetworkConfigIdentity, *GetIdentityFields());
		UE_LOG(LogTemp, Log, TEXT("AUTHORITY network_config network_config=%s %s"), *NetworkConfigIdentity, *GetIdentityFields());
		if (SpawnedEnemy != nullptr)
		{
			UE_LOG(LogTemp, Log, TEXT("AUTHORITY enemy_spawned enemy=%s %s"), *SpawnedEnemy->GetName(), *GetIdentityFields());
		}
	}
}

void AAethelnNetworkSpikeGameMode::Tick(float DeltaSeconds)
{
	Super::Tick(DeltaSeconds);
	if (!bScenarioEnabled || !HasAuthority())
	{
		return;
	}

	for (const TPair<TWeakObjectPtr<AController>, FVector>& Entry : InitialLocations)
	{
		AController* Controller = Entry.Key.Get();
		APawn* Pawn = Controller != nullptr ? Controller->GetPawn() : nullptr;
		const FString ClientId = GetClientId(Controller);
		if (ClientId == TEXT("client-1"))
		{
			PositionEnemyForFirstClient(Cast<APlayerController>(Controller));
		}
		if (Pawn != nullptr && !ClientId.IsEmpty() && !MovementObserved.Contains(ClientId)
			&& FVector::DistSquared(Pawn->GetActorLocation(), Entry.Value) >= 1.0f)
		{
			MovementObserved.Add(ClientId);
			UE_LOG(LogTemp, Log, TEXT("AUTHORITY movement client=%s %s"), *ClientId, *GetIdentityFields());
		}
	}
}

FString AAethelnNetworkSpikeGameMode::InitNewPlayer(
	APlayerController* NewPlayerController,
	const FUniqueNetIdRepl& UniqueId,
	const FString& Options,
	const FString& Portal)
{
	const FString Error = Super::InitNewPlayer(NewPlayerController, UniqueId, Options, Portal);
	if (bScenarioEnabled && NewPlayerController != nullptr)
	{
		const FString ClientId = UGameplayStatics::ParseOption(Options, TEXT("AethelnClientId"));
		if (IsAllowedScenarioClientId(ClientId))
		{
			ClientIds.Add(NewPlayerController, ClientId);
		}
	}
	return Error;
}

void AAethelnNetworkSpikeGameMode::PostLogin(APlayerController* NewPlayer)
{
	Super::PostLogin(NewPlayer);
	RegisterScenarioConnection(NewPlayer);
}

bool AAethelnNetworkSpikeGameMode::RegisterScenarioConnection(APlayerController* NewPlayer)
{
	if (!bScenarioEnabled || NewPlayer == nullptr)
	{
		return false;
	}

	const FString ClientId = GetClientId(NewPlayer);
	if (!IsAllowedScenarioClientId(ClientId))
	{
		return false;
	}
	const FString ConnectionId = MakeScenarioConnectionId(RunId, NextConnectionSequence++);
	ConnectionIds.Add(NewPlayer, ConnectionId);
	if (NewPlayer->PlayerState != nullptr)
	{
		NewPlayer->PlayerState->SetPlayerName(ClientId);
	}
	ApplyStoredConnectionPseudonym(NewPlayer);
	if (APawn* Pawn = NewPlayer->GetPawn())
	{
		InitialLocations.Add(NewPlayer, Pawn->GetActorLocation());
		if (UAethelnSpikeAuthorityComponent* AuthorityComponent = Pawn->FindComponentByClass<UAethelnSpikeAuthorityComponent>())
		{
			AuthorityComponents.Add(NewPlayer, AuthorityComponent);
		}
	}
	PositionEnemyForFirstClient(NewPlayer);
	UE_LOG(LogTemp, Log, TEXT("AUTHORITY connection client=%s connection=%s %s"), *ClientId, *ConnectionId, *GetIdentityFields());
	if (ClientId == TEXT("client-1-reconnect"))
	{
		UE_LOG(LogTemp, Log, TEXT("AUTHORITY reconnected client=%s connection=%s %s"), *ClientId, *ConnectionId, *GetIdentityFields());
	}
	return true;
}

void AAethelnNetworkSpikeGameMode::FinishRestartPlayer(
	AController* NewPlayer,
	const FRotator& StartRotation)
{
	Super::FinishRestartPlayer(NewPlayer, StartRotation);
	ApplyStoredConnectionPseudonym(NewPlayer);
}

void AAethelnNetworkSpikeGameMode::Logout(AController* Exiting)
{
	if (bScenarioEnabled && Exiting != nullptr)
	{
		const FString ClientId = GetClientId(Exiting);
		const FString* ConnectionId = ConnectionIds.Find(Exiting);
		if (ClientId == TEXT("client-1") && ConnectionId != nullptr)
		{
			UE_LOG(LogTemp, Log, TEXT("AUTHORITY disconnected client=%s connection=%s %s"), *ClientId, **ConnectionId, *GetIdentityFields());
		}
		AuthorityComponents.Remove(Exiting);
		InitialLocations.Remove(Exiting);
		ConnectionIds.Remove(Exiting);
		ClientIds.Remove(Exiting);
	}
	Super::Logout(Exiting);
}

bool AAethelnNetworkSpikeGameMode::IsAllowedScenarioClientId(const FString& ClientId)
{
	return ClientId == TEXT("client-1") || ClientId == TEXT("client-2") || ClientId == TEXT("client-1-reconnect");
}

FString AAethelnNetworkSpikeGameMode::MakeScenarioConnectionId(const FString& InRunId, uint32 Sequence)
{
	return FString::Printf(TEXT("%s-connection-%04u"), *InRunId, Sequence);
}

FVector AAethelnNetworkSpikeGameMode::MakeScenarioEnemyLocation(const FVector& PawnLocation, const FVector& PawnForward)
{
	return PawnLocation + PawnForward.GetSafeNormal() * 175.0f;
}

FString AAethelnNetworkSpikeGameMode::GetIdentityFields() const
{
	return FString::Printf(TEXT("scenario=%s profile=%s run=%s"), *ScenarioId, *ProfileId, *RunId);
}

FString AAethelnNetworkSpikeGameMode::GetClientId(const AController* Controller) const
{
	if (const FString* ClientId = ClientIds.Find(Controller))
	{
		return *ClientId;
	}
	return FString();
}

bool AAethelnNetworkSpikeGameMode::ApplyStoredConnectionPseudonym(AController* Controller)
{
	const FString* ConnectionId = ConnectionIds.Find(Controller);
	AAethelnSpikeCharacter* SpikeCharacter = Controller != nullptr
		? Cast<AAethelnSpikeCharacter>(Controller->GetPawn())
		: nullptr;
	if (ConnectionId == nullptr || SpikeCharacter == nullptr)
	{
		return false;
	}
	SpikeCharacter->SetObservabilityConnectionPseudonym(*ConnectionId);
	return SpikeCharacter->GetObservabilityConnectionPseudonym() == *ConnectionId;
}

void AAethelnNetworkSpikeGameMode::PositionEnemyForFirstClient(APlayerController* NewPlayer)
{
	if (SpawnedEnemy == nullptr || NewPlayer == nullptr || GetClientId(NewPlayer) != TEXT("client-1"))
	{
		return;
	}
	if (APawn* Pawn = NewPlayer->GetPawn())
	{
		SpawnedEnemy->SetActorLocation(MakeScenarioEnemyLocation(Pawn->GetActorLocation(), Pawn->GetActorForwardVector()));
	}
}
