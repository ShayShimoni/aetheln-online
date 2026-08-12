#include "AethelnSpikeAuthorityComponent.h"

#include "AbilitySystemComponent.h"
#include "AbilitySystemInterface.h"
#include "AethelnSpikeDamageEffect.h"
#include "AethelnSpikeEnemy.h"
#include "AethelnSpikeMeleeAbility.h"
#include "Engine/OverlapResult.h"
#include "Engine/World.h"
#include "GameFramework/Controller.h"
#include "GameFramework/GameStateBase.h"
#include "GameFramework/Pawn.h"
#include "GameFramework/PlayerState.h"
#include "Misc/CommandLine.h"
#include "Misc/Parse.h"
#include "Net/UnrealNetwork.h"

namespace AethelnSpikeAuthority
{
	constexpr uint8 SchemaVersion = 1;
	constexpr uint32 ContentVersion = 1;
	constexpr float AimUnitTolerance = 0.01f;
}

void UAethelnSpikeAuthorityComponent::SubmitScenarioProbe(const FAethelnSpikeScenarioProbe& Probe)
{
	if (FParse::Param(FCommandLine::Get(), TEXT("AethelnAuthorityScenario")))
	{
		ServerSubmitScenarioProbe(Probe);
	}
}

UAethelnSpikeAuthorityComponent::UAethelnSpikeAuthorityComponent()
{
	SetIsReplicatedByDefault(true);
}

void UAethelnSpikeAuthorityComponent::SubmitAttack(const FVector& AimDirection)
{
	UWorld* World = GetWorld();
	if (World == nullptr)
	{
		return;
	}

	const AGameStateBase* GameState = World->GetGameState();
	FAethelnSpikeAttackIntent Intent;
	Intent.Sequence = NextClientSequence++;
	Intent.ClientTimestampSeconds = GameState != nullptr
		? GameState->GetServerWorldTimeSeconds()
		: World->GetTimeSeconds();
	Intent.Aim = AimDirection;
	ServerSubmitAttack(Intent);
}

void UAethelnSpikeAuthorityComponent::SetLifecycleReady(bool bReady)
{
	bLifecycleReady = bReady;
	if (!bReady)
	{
		CloseAttackWindow();
	}
}

EAethelnSpikeAttackRejection UAethelnSpikeAuthorityComponent::ValidateIntent(
	const FAethelnSpikeAttackIntent& Intent,
	const FVector& AuthoritativeAimDirection,
	uint32 PreviousAcceptedSequence,
	double ServerTimeSeconds,
	double MaximumTimestampDeltaSeconds,
	bool bIsLifecycleReady,
	bool bActorUsable)
{
	if (!bIsLifecycleReady)
	{
		return EAethelnSpikeAttackRejection::ConnectionClosed;
	}
	if (!bActorUsable)
	{
		return EAethelnSpikeAttackRejection::ActorDestroyed;
	}
	if (Intent.SchemaVersion != AethelnSpikeAuthority::SchemaVersion
		|| Intent.ContentVersion != AethelnSpikeAuthority::ContentVersion)
	{
		return EAethelnSpikeAttackRejection::IncompatibleVersion;
	}
	if (Intent.Sequence == PreviousAcceptedSequence && Intent.Sequence != 0)
	{
		return EAethelnSpikeAttackRejection::DuplicateSequence;
	}
	if (Intent.Sequence == 0 || Intent.Sequence < PreviousAcceptedSequence)
	{
		return EAethelnSpikeAttackRejection::StaleSequence;
	}
	if (!FMath::IsFinite(Intent.ClientTimestampSeconds)
		|| !FMath::IsFinite(ServerTimeSeconds)
		|| !FMath::IsFinite(MaximumTimestampDeltaSeconds)
		|| MaximumTimestampDeltaSeconds < 0.0
		|| FMath::Abs(Intent.ClientTimestampSeconds - ServerTimeSeconds) > MaximumTimestampDeltaSeconds)
	{
		return EAethelnSpikeAttackRejection::TimestampOutOfBounds;
	}

	const FVector Aim(Intent.Aim);
	if (Aim.ContainsNaN()
		|| Aim.IsNearlyZero()
		|| !FMath::IsNearlyEqual(Aim.SizeSquared(), 1.0f, AethelnSpikeAuthority::AimUnitTolerance))
	{
		return EAethelnSpikeAttackRejection::MalformedIntent;
	}

	const FVector AuthoritativeAim = AuthoritativeAimDirection.GetSafeNormal();
	if (AuthoritativeAim.IsNearlyZero()
		|| !Aim.Equals(AuthoritativeAim, AethelnSpikeAuthority::AimUnitTolerance))
	{
		return EAethelnSpikeAttackRejection::ImpossibleAimTransition;
	}
	return EAethelnSpikeAttackRejection::None;
}

void UAethelnSpikeAuthorityComponent::ServerSubmitAttack_Implementation(const FAethelnSpikeAttackIntent& Intent)
{
	ProcessServerIntent(Intent);
}

void UAethelnSpikeAuthorityComponent::ServerSubmitScenarioProbe_Implementation(const FAethelnSpikeScenarioProbe& Probe)
{
	if (!FParse::Param(FCommandLine::Get(), TEXT("AethelnAuthorityScenario")))
	{
		return;
	}
	ProcessServerScenarioProbe(Probe);
}

EAethelnSpikeAttackRejection UAethelnSpikeAuthorityComponent::ValidateScenarioProbe(const FAethelnSpikeScenarioProbe& Probe) const
{
	const AActor* Owner = GetOwner();
	if (!bLifecycleReady)
	{
		return EAethelnSpikeAttackRejection::ConnectionClosed;
	}
	if (Owner == nullptr || Owner->IsActorBeingDestroyed())
	{
		return EAethelnSpikeAttackRejection::ActorDestroyed;
	}
	if (Probe.Sequence == 0 || !FMath::IsFinite(Probe.ClaimedMagnitude))
	{
		return EAethelnSpikeAttackRejection::MalformedIntent;
	}
	if (Probe.Category == TEXT("movement"))
	{
		return !FVector(Probe.ClaimedMovement).Equals(Owner->GetActorLocation())
			? EAethelnSpikeAttackRejection::MalformedIntent
			: EAethelnSpikeAttackRejection::None;
	}
	if (Probe.Category == TEXT("aim"))
	{
		return FVector(Probe.ClaimedAim).GetSafeNormal().Equals(Owner->GetActorForwardVector(), AethelnSpikeAuthority::AimUnitTolerance)
			? EAethelnSpikeAttackRejection::None
			: EAethelnSpikeAttackRejection::ImpossibleAimTransition;
	}
	if (Probe.Category == TEXT("hit") || Probe.Category == TEXT("damage"))
	{
		return !Probe.ClaimedOutcome.IsNone() || !FMath::IsNearlyZero(Probe.ClaimedMagnitude)
			? EAethelnSpikeAttackRejection::MalformedIntent
			: EAethelnSpikeAttackRejection::None;
	}
	if (Probe.Category == TEXT("activation") || Probe.Category == TEXT("cooldown")
		|| Probe.Category == TEXT("dodge") || Probe.Category == TEXT("block"))
	{
		return EAethelnSpikeAttackRejection::ActivationBlocked;
	}
	return EAethelnSpikeAttackRejection::MalformedIntent;
}

EAethelnSpikeAttackRejection UAethelnSpikeAuthorityComponent::ProcessServerScenarioProbe(
	const FAethelnSpikeScenarioProbe& Probe,
	const FString& ClientIdOverride)
{
	const EAethelnSpikeAttackRejection Reason = ValidateScenarioProbe(Probe);

	const APawn* Pawn = Cast<APawn>(GetOwner());
	const APlayerState* PlayerState = Pawn != nullptr ? Pawn->GetPlayerState() : nullptr;
	const FString ClientId = !ClientIdOverride.IsEmpty()
		? ClientIdOverride
		: (PlayerState != nullptr ? PlayerState->GetPlayerName() : FString());
	FString ScenarioId;
	FString ProfileId;
	FString RunId;
	FParse::Value(FCommandLine::Get(), TEXT("AethelnScenarioId="), ScenarioId);
	FParse::Value(FCommandLine::Get(), TEXT("AethelnProfileId="), ProfileId);
	FParse::Value(FCommandLine::Get(), TEXT("AethelnRunId="), RunId);
	UE_LOG(LogTemp, Warning, TEXT("AUTHORITY rejection category=%s reason=%s client=%s scenario=%s profile=%s run=%s"), *Probe.Category.ToString(), LexToString(Reason), *ClientId, *ScenarioId, *ProfileId, *RunId);
	return Reason;
}

void UAethelnSpikeAuthorityComponent::ProcessServerIntent(const FAethelnSpikeAttackIntent& Intent)
{
	AActor* Owner = GetOwner();
	UWorld* World = GetWorld();
	UAbilitySystemComponent* AbilitySystem = ResolveOwnerAbilitySystem();
	const bool bActorUsable = Owner != nullptr
		&& Owner->HasAuthority()
		&& !Owner->IsActorBeingDestroyed()
		&& AbilitySystem != nullptr;

	FVector AuthoritativeAim = Owner != nullptr ? Owner->GetActorForwardVector() : FVector::ZeroVector;
	const APawn* Pawn = Cast<APawn>(Owner);
	const AController* Controller = Pawn != nullptr ? Pawn->GetController() : nullptr;
	if (Controller != nullptr)
	{
		AuthoritativeAim = Controller->GetControlRotation().Vector();
	}

	const EAethelnSpikeAttackRejection Rejection = ValidateIntent(
		Intent,
		AuthoritativeAim,
		LastAcceptedSequence,
		World != nullptr ? World->GetTimeSeconds() : -1.0,
		ProvisionalMaximumTimestampDeltaSeconds,
		bLifecycleReady,
		bActorUsable);
	if (Rejection != EAethelnSpikeAttackRejection::None)
	{
		Reject(Rejection);
		return;
	}

	PendingIntent = Intent;
	ActiveAttackId = FGuid::NewGuid();
	AlreadyHitTargets.Reset();
	bAttackWindowActive = true;
	LastRejection = EAethelnSpikeAttackRejection::None;

	if (!AbilitySystem->TryActivateAbilityByClass(UAethelnSpikeMeleeAbility::StaticClass(), true))
	{
		CloseAttackWindow();
		Reject(EAethelnSpikeAttackRejection::ActivationBlocked);
		return;
	}

	LastAcceptedSequence = Intent.Sequence;
}

bool UAethelnSpikeAuthorityComponent::ExecuteActiveAttack()
{
	AActor* Owner = GetOwner();
	UWorld* World = GetWorld();
	UAbilitySystemComponent* SourceAbilitySystem = ResolveOwnerAbilitySystem();
	if (!bAttackWindowActive
		|| !ActiveAttackId.IsValid()
		|| Owner == nullptr
		|| World == nullptr
		|| SourceAbilitySystem == nullptr
		|| !Owner->HasAuthority()
		|| Owner->IsActorBeingDestroyed())
	{
		CloseAttackWindow();
		return false;
	}

	const FVector Center = Owner->GetActorLocation() + FVector(PendingIntent.Aim) * ProvisionalAttackReach;
	TArray<FOverlapResult> Overlaps;
	FCollisionQueryParams QueryParams(SCENE_QUERY_STAT(AethelnSpikeMelee), false, Owner);
	World->OverlapMultiByObjectType(
		Overlaps,
		Center,
		FQuat::Identity,
		FCollisionObjectQueryParams::AllDynamicObjects,
		FCollisionShape::MakeSphere(ProvisionalAttackRadius),
		QueryParams);

	for (const FOverlapResult& Overlap : Overlaps)
	{
		AAethelnSpikeEnemy* Enemy = Cast<AAethelnSpikeEnemy>(Overlap.GetActor());
		if (Enemy == nullptr
			|| Enemy->IsActorBeingDestroyed()
			|| !Enemy->HasAuthority()
			|| Enemy->GetHealth() <= 0.0f
			|| AlreadyHitTargets.Contains(Enemy))
		{
			continue;
		}

		UAbilitySystemComponent* TargetAbilitySystem = Enemy->GetAbilitySystemComponent();
		if (TargetAbilitySystem == nullptr)
		{
			continue;
		}

		AlreadyHitTargets.Add(Enemy);
		FGameplayEffectContextHandle EffectContext = SourceAbilitySystem->MakeEffectContext();
		EffectContext.AddSourceObject(this);
		const FGameplayEffectSpecHandle EffectSpec = SourceAbilitySystem->MakeOutgoingSpec(
			UAethelnSpikeDamageEffect::StaticClass(),
			1.0f,
			EffectContext);
		if (EffectSpec.IsValid())
		{
			const bool bAuthorityScenario = FParse::Param(FCommandLine::Get(), TEXT("AethelnAuthorityScenario"));
			const float PreviousHealth = bAuthorityScenario ? Enemy->GetHealth() : 0.0f;
			SourceAbilitySystem->ApplyGameplayEffectSpecToTarget(*EffectSpec.Data.Get(), TargetAbilitySystem);
			if (bAuthorityScenario)
			{
				const APawn* OwnerPawn = Cast<APawn>(Owner);
				const APlayerState* OwnerPlayerState = OwnerPawn != nullptr ? OwnerPawn->GetPlayerState() : nullptr;
				const FString ClientId = OwnerPlayerState != nullptr ? OwnerPlayerState->GetPlayerName() : FString();
				FString ScenarioId;
				FString ProfileId;
				FString RunId;
				FParse::Value(FCommandLine::Get(), TEXT("AethelnScenarioId="), ScenarioId);
				FParse::Value(FCommandLine::Get(), TEXT("AethelnProfileId="), ProfileId);
				FParse::Value(FCommandLine::Get(), TEXT("AethelnRunId="), RunId);
				UE_LOG(LogTemp, Log, TEXT("AUTHORITY melee_resolved attacker=%s enemy=%s scenario=%s profile=%s run=%s"), *ClientId, *Enemy->GetName(), *ScenarioId, *ProfileId, *RunId);
				if (Enemy->GetHealth() < PreviousHealth)
				{
					UE_LOG(LogTemp, Log, TEXT("AUTHORITY damage_applied attacker=%s enemy=%s scenario=%s profile=%s run=%s"), *ClientId, *Enemy->GetName(), *ScenarioId, *ProfileId, *RunId);
				}
			}
		}
	}

	CloseAttackWindow();
	return true;
}

UAbilitySystemComponent* UAethelnSpikeAuthorityComponent::ResolveOwnerAbilitySystem() const
{
	AActor* Owner = GetOwner();
	if (IAbilitySystemInterface* AbilitySystemOwner = Cast<IAbilitySystemInterface>(Owner))
	{
		return AbilitySystemOwner->GetAbilitySystemComponent();
	}

	const APawn* Pawn = Cast<APawn>(Owner);
	APlayerState* PlayerState = Pawn != nullptr ? Pawn->GetPlayerState() : nullptr;
	if (IAbilitySystemInterface* AbilitySystemPlayerState = Cast<IAbilitySystemInterface>(PlayerState))
	{
		return AbilitySystemPlayerState->GetAbilitySystemComponent();
	}
	return nullptr;
}

void UAethelnSpikeAuthorityComponent::CloseAttackWindow()
{
	bAttackWindowActive = false;
	ActiveAttackId.Invalidate();
	AlreadyHitTargets.Reset();
}

void UAethelnSpikeAuthorityComponent::Reject(EAethelnSpikeAttackRejection Reason)
{
	LastRejection = Reason;
	UE_LOG(LogTemp, Warning, TEXT("AethelnSpikeAttackRejected Reason=%s"), LexToString(Reason));
}

void UAethelnSpikeAuthorityComponent::GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const
{
	Super::GetLifetimeReplicatedProps(OutLifetimeProps);
	DOREPLIFETIME(UAethelnSpikeAuthorityComponent, LastRejection);
}
