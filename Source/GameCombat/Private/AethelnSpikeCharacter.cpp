#include "AethelnSpikeCharacter.h"

#include "AethelnSpikeAuthorityComponent.h"
#include "AethelnSpikeEnemy.h"
#include "AethelnSpikeMovementComponent.h"
#include "AethelnSpikePlayerState.h"
#include "AethelnObservability.h"
#include "AethelnObservabilitySubsystem.h"
#include "Engine/GameInstance.h"
#include "EngineUtils.h"
#include "GameFramework/Controller.h"
#include "Misc/App.h"
#include "Misc/CommandLine.h"
#include "Misc/EngineVersion.h"
#include "Misc/Parse.h"
#include "Net/UnrealNetwork.h"

namespace AethelnSpikeObservability
{
	FString ReadArgument(const TCHAR* Key, const FString& Fallback = AethelnObservability::UnknownValue)
	{
		FString Value;
		return FParse::Value(FCommandLine::Get(), Key, Value) && !Value.IsEmpty()
			? Value
			: Fallback;
	}
}

AAethelnSpikeCharacter::AAethelnSpikeCharacter(const FObjectInitializer& ObjectInitializer)
	: Super(ObjectInitializer.SetDefaultSubobjectClass<UAethelnSpikeMovementComponent>(ACharacter::CharacterMovementComponentName))
{
	AuthorityComponent = CreateDefaultSubobject<UAethelnSpikeAuthorityComponent>(TEXT("AuthorityComponent"));
	PrimaryActorTick.bCanEverTick = true;
}

void AAethelnSpikeCharacter::BeginPlay()
{
	Super::BeginPlay();
	InitializePackagedScenario();
}

void AAethelnSpikeCharacter::Tick(float DeltaSeconds)
{
	Super::Tick(DeltaSeconds);
	if (!bPackagedScenarioEnabled || !IsLocallyControlled() || HasAuthority())
	{
		return;
	}

	ScenarioElapsedSeconds += DeltaSeconds;
	if (!bClientReadyObserved && GetController() != nullptr)
	{
		bClientReadyObserved = true;
		UE_LOG(LogTemp, Log, TEXT("AUTHORITY client_ready client=%s endpoint=%s map=%s %s"), *ScenarioClientId, *ScenarioEndpoint, *ScenarioMap, *GetScenarioIdentityFields());
	}
	if (!bClientReadyObserved)
	{
		return;
	}
	if (ScenarioElapsedSeconds <= 0.5f)
	{
		AddMovementInput(GetActorRightVector(), 1.0f);
	}

	AAethelnSpikeEnemy* ObservedEnemy = nullptr;
	TActorIterator<AAethelnSpikeEnemy> EnemyIt(GetWorld());
	if (EnemyIt)
	{
		ObservedEnemy = *EnemyIt;
	}
	if (ObservedEnemy != nullptr && ScenarioClientId == TEXT("client-2") && !bJoinInProgressObserved)
	{
		bJoinInProgressObserved = true;
		UE_LOG(LogTemp, Log, TEXT("AUTHORITY join_in_progress client=%s enemy=%s %s"), *ScenarioClientId, *ObservedEnemy->GetName(), *GetScenarioIdentityFields());
	}
	if (ShouldSubmitScenarioAttack(ScenarioClientId, bClientReadyObserved, ScenarioElapsedSeconds, bAttackSubmitted))
	{
		bAttackSubmitted = true;
		SubmitFreeAimAttack(GetActorForwardVector());
	}
	if (ScenarioClientId == TEXT("client-2") && !bProbesSubmitted && ScenarioElapsedSeconds >= 3.0f)
	{
		bProbesSubmitted = true;
		for (const FName Category : { FName(TEXT("movement")), FName(TEXT("aim")), FName(TEXT("activation")), FName(TEXT("hit")), FName(TEXT("cooldown")), FName(TEXT("dodge")), FName(TEXT("block")), FName(TEXT("resource")), FName(TEXT("death")), FName(TEXT("respawn")) })
		{
			FAethelnSpikeScenarioProbe Probe;
			Probe.Category = Category;
			Probe.Sequence = 1;
			Probe.ClaimedMovement = GetActorLocation() + FVector(100000.0f, 0.0f, 0.0f);
			Probe.ClaimedAim = -GetActorForwardVector();
			Probe.ClaimedOutcome = Category;
			Probe.ClaimedMagnitude = 100000.0f;
			SubmitScenarioProbe(Probe);
		}
	}
}

void AAethelnSpikeCharacter::PossessedBy(AController* NewController)
{
	Super::PossessedBy(NewController);
	InitializePlayerStateAbilitySystem();
	AuthorityComponent->SetLifecycleReady(true);
}

void AAethelnSpikeCharacter::OnRep_PlayerState()
{
	Super::OnRep_PlayerState();
	InitializePlayerStateAbilitySystem();
	AuthorityComponent->SetLifecycleReady(GetPlayerState() != nullptr);
}

void AAethelnSpikeCharacter::GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const
{
	Super::GetLifetimeReplicatedProps(OutLifetimeProps);
	DOREPLIFETIME_CONDITION(AAethelnSpikeCharacter, ObservabilityConnectionPseudonym, COND_OwnerOnly);
}

void AAethelnSpikeCharacter::SubmitFreeAimAttack(const FVector& AimDirection)
{
	AuthorityComponent->SubmitAttack(AimDirection);
}

void AAethelnSpikeCharacter::SubmitScenarioProbe(const FAethelnSpikeScenarioProbe& Probe)
{
	AuthorityComponent->SubmitScenarioProbe(Probe);
}

void AAethelnSpikeCharacter::SetObservabilityConnectionPseudonym(const FString& ConnectionPseudonym)
{
	if (HasAuthority()
		&& !ConnectionPseudonym.IsEmpty()
		&& ConnectionPseudonym.Len() <= AethelnObservability::MaxIdentifierLength)
	{
		ObservabilityConnectionPseudonym = ConnectionPseudonym;
	}
}

bool AAethelnSpikeCharacter::ShouldSubmitScenarioAttack(const FString& ClientId, bool bClientReady, float ElapsedSeconds, bool bAlreadySubmitted)
{
	return ClientId == TEXT("client-1") && bClientReady && ElapsedSeconds >= 2.0f && !bAlreadySubmitted;
}

void AAethelnSpikeCharacter::InitializePlayerStateAbilitySystem()
{
	if (AAethelnSpikePlayerState* SpikePlayerState = GetPlayerState<AAethelnSpikePlayerState>())
	{
		SpikePlayerState->InitializeAbilityActorInfo(this);
	}
}

void AAethelnSpikeCharacter::InitializePackagedScenario()
{
	bPackagedScenarioEnabled = FParse::Param(FCommandLine::Get(), TEXT("AethelnAuthorityScenario"));
	if (!bPackagedScenarioEnabled)
	{
		return;
	}
	FParse::Value(FCommandLine::Get(), TEXT("AethelnSpikeClientId="), ScenarioClientId);
	FParse::Value(FCommandLine::Get(), TEXT("AethelnServerEndpoint="), ScenarioEndpoint);
	FParse::Value(FCommandLine::Get(), TEXT("AethelnServerMap="), ScenarioMap);
	FParse::Value(FCommandLine::Get(), TEXT("AethelnScenarioId="), ScenarioId);
	FParse::Value(FCommandLine::Get(), TEXT("AethelnProfileId="), ScenarioProfileId);
	FParse::Value(FCommandLine::Get(), TEXT("AethelnRunId="), ScenarioRunId);
	if (GetNetMode() == NM_Client)
	{
		if (UGameInstance* GameInstance = GetGameInstance())
		{
			if (UAethelnObservabilitySubsystem* Observability = GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>())
			{
				Observability->SetEnvironment(
					AethelnSpikeObservability::ReadArgument(TEXT("AethelnEnvironment="), TEXT("local")));
				const FString RunIdentity = ScenarioRunId.IsEmpty() ? TEXT("run-unset") : ScenarioRunId;
				Observability->SetRuntimeContext(
					EAethelnFlowKind::PrototypeAuthority,
					RunIdentity,
					TEXT("network-authority-client"),
					AethelnObservability::ExcludedIdentifier);
				FAethelnBuildIdentity Build;
				Build.SourceRevision = AethelnSpikeObservability::ReadArgument(TEXT("AethelnSourceRevision="));
				Build.BuildIdentity = AethelnSpikeObservability::ReadArgument(TEXT("AethelnBuildIdentity="));
				Build.BuildConfiguration = LexToString(FApp::GetBuildConfiguration());
				Build.EngineRevision = FEngineVersion::Current().ToString();
				Build.ToolchainIdentity = AethelnSpikeObservability::ReadArgument(TEXT("AethelnToolchainIdentity="));
				FAethelnNetworkProfile Profile;
				Profile.ProfileId = ScenarioProfileId.IsEmpty()
					? AethelnNetworkSpike::UnsetNetworkProfileId
					: ScenarioProfileId;
				Observability->SetBuildContext(Build, Profile);
			}
		}
	}
}

FString AAethelnSpikeCharacter::GetScenarioIdentityFields() const
{
	return FString::Printf(TEXT("scenario=%s profile=%s run=%s"), *ScenarioId, *ScenarioProfileId, *ScenarioRunId);
}
