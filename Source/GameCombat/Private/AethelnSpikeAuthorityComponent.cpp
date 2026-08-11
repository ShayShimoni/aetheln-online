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
#include "Net/UnrealNetwork.h"

namespace AethelnSpikeAuthority
{
	constexpr uint8 SchemaVersion = 1;
	constexpr uint32 ContentVersion = 1;
	constexpr float AimUnitTolerance = 0.01f;
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
			SourceAbilitySystem->ApplyGameplayEffectSpecToTarget(*EffectSpec.Data.Get(), TargetAbilitySystem);
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
