#include "AethelnSpikeAuthorityComponent.h"

#include "AbilitySystemComponent.h"
#include "AbilitySystemInterface.h"
#include "AethelnSpikeDamageEffect.h"
#include "AethelnSpikeEnemy.h"
#include "AethelnSpikeCharacter.h"
#include "AethelnSpikeMeleeAbility.h"
#include "AethelnObservability.h"
#include "AethelnObservabilitySubsystem.h"
#include "Engine/GameInstance.h"
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
	constexpr TCHAR MeleeAbilityId[] = TEXT("Ability.Melee.Combo1");

	EAethelnSafeReason ToSafeReason(EAethelnSpikeAttackRejection Reason)
	{
		switch (Reason)
		{
		case EAethelnSpikeAttackRejection::None: return EAethelnSafeReason::Accepted;
		case EAethelnSpikeAttackRejection::StaleSequence: return EAethelnSafeReason::StaleSequence;
		case EAethelnSpikeAttackRejection::DuplicateSequence: return EAethelnSafeReason::DuplicateSequence;
		case EAethelnSpikeAttackRejection::IncompatibleVersion: return EAethelnSafeReason::IncompatibleVersion;
		case EAethelnSpikeAttackRejection::TimestampOutOfBounds: return EAethelnSafeReason::TimestampOutOfBounds;
		case EAethelnSpikeAttackRejection::ImpossibleAimTransition: return EAethelnSafeReason::ImpossibleAimTransition;
		case EAethelnSpikeAttackRejection::ConnectionClosed: return EAethelnSafeReason::ConnectionClosed;
		case EAethelnSpikeAttackRejection::ActorDestroyed: return EAethelnSafeReason::ActorDestroyed;
		case EAethelnSpikeAttackRejection::MalformedIntent: return EAethelnSafeReason::MalformedRequest;
		case EAethelnSpikeAttackRejection::ActivationBlocked: return EAethelnSafeReason::ActivationBlocked;
		default: return EAethelnSafeReason::Rejected;
		}
	}

	EAethelnObservabilityCategory ToObservabilityCategory(FName Category)
	{
		if (Category == TEXT("movement")) return EAethelnObservabilityCategory::Movement;
		if (Category == TEXT("aim")) return EAethelnObservabilityCategory::Aim;
		if (Category == TEXT("activation")) return EAethelnObservabilityCategory::Ability;
		if (Category == TEXT("cooldown")) return EAethelnObservabilityCategory::Cooldown;
		if (Category == TEXT("hit") || Category == TEXT("damage")) return EAethelnObservabilityCategory::Hit;
		if (Category == TEXT("dodge")) return EAethelnObservabilityCategory::Dodge;
		if (Category == TEXT("block")) return EAethelnObservabilityCategory::Block;
		if (Category == TEXT("resource")) return EAethelnObservabilityCategory::Resource;
		if (Category == TEXT("death")) return EAethelnObservabilityCategory::Death;
		if (Category == TEXT("respawn")) return EAethelnObservabilityCategory::Respawn;
		return EAethelnObservabilityCategory::Rejection;
	}

	UAethelnObservabilitySubsystem* ResolveObservabilitySubsystem(const AActor* Owner)
	{
		const UWorld* World = Owner != nullptr ? Owner->GetWorld() : nullptr;
		UGameInstance* GameInstance = World != nullptr ? World->GetGameInstance() : nullptr;
		return GameInstance != nullptr ? GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>() : nullptr;
	}

	void EmitObservabilityEvent(
		const AActor* Owner,
		uint64 Sequence,
		const FGuid& AttackId,
		EAethelnObservabilityCategory SubjectCategory,
		EAethelnSpikeAttackRejection Reason,
		bool bIncludeMeleeAbilityIdentity = true)
	{
		UAethelnObservabilitySubsystem* Subsystem = ResolveObservabilitySubsystem(Owner);
		if (Subsystem == nullptr)
		{
			return;
		}

		FAethelnObservabilityEvent Event;
		Event.Category = Reason == EAethelnSpikeAttackRejection::None
			? SubjectCategory
			: EAethelnObservabilityCategory::Rejection;
		Event.SubjectCategory = SubjectCategory;
		Event.SafeReason = ToSafeReason(Reason);
		Event.DiagnosticCode = Reason == EAethelnSpikeAttackRejection::None
			? EAethelnDiagnosticCode::None
			: EAethelnDiagnosticCode::ValidationFailed;

		FAethelnObservabilityEventContext Context;
		if (const AAethelnSpikeCharacter* SpikeCharacter = Cast<AAethelnSpikeCharacter>(Owner))
		{
			Context.ConnectionPseudonym = SpikeCharacter->GetObservabilityConnectionPseudonym();
		}
		Context.ActivationId = AttackId.IsValid()
			? AttackId.ToString(EGuidFormats::DigitsWithHyphensLower)
			: FString();
		if (bIncludeMeleeAbilityIdentity)
		{
			Context.AbilityId = MeleeAbilityId;
		}
		Context.Sequence = Sequence;
		Subsystem->EmitEvent(Event, Context);

		FAethelnMetricSample EventMetric;
		EventMetric.Metric = Reason == EAethelnSpikeAttackRejection::None
			? EAethelnMetricKind::EventCount
			: EAethelnMetricKind::RejectionCount;
		EventMetric.Category = SubjectCategory;
		EventMetric.Reason = Event.SafeReason;
		EventMetric.Value = 1;
		Subsystem->EmitMetric(EventMetric);
	}

	bool IsAuthorityScenario()
	{
		return FParse::Param(FCommandLine::Get(), TEXT("AethelnAuthorityScenario"));
	}

	void RecordScenarioStage(
		const AActor* Owner,
		const FAethelnSpikeAttackIntent& Intent,
		const FGuid& AttackId,
		const TCHAR* Stage,
		const TCHAR* Result,
		EAethelnSpikeAttackRejection Reason,
		int32 OverlapCount = 0,
		int32 EffectCount = 0,
		int32 DamageCount = 0)
	{
		if (!IsAuthorityScenario())
		{
			return;
		}

		const APawn* Pawn = Cast<APawn>(Owner);
		const APlayerState* PlayerState = Pawn != nullptr ? Pawn->GetPlayerState() : nullptr;
		const FString ClientId = PlayerState != nullptr ? PlayerState->GetPlayerName() : FString();
		FString ScenarioId;
		FString ProfileId;
		FString RunId;
		FParse::Value(FCommandLine::Get(), TEXT("AethelnScenarioId="), ScenarioId);
		FParse::Value(FCommandLine::Get(), TEXT("AethelnProfileId="), ProfileId);
		FParse::Value(FCommandLine::Get(), TEXT("AethelnRunId="), RunId);

		UE_LOG(
			LogTemp,
			Log,
			TEXT("AUTHORITY intent stage=%s result=%s reason=%s client=%s scenario=%s profile=%s run=%s attack=%s schema=%u content=%u sequence=%u timestamp=%.6f aim_x=%.6f aim_y=%.6f aim_z=%.6f overlaps=%d effects=%d damage=%d"),
			Stage,
			Result,
			LexToString(Reason),
			*ClientId,
			*ScenarioId,
			*ProfileId,
			*RunId,
			*AttackId.ToString(EGuidFormats::DigitsWithHyphensLower),
			Intent.SchemaVersion,
			Intent.ContentVersion,
			Intent.Sequence,
			Intent.ClientTimestampSeconds,
			Intent.Aim.X,
			Intent.Aim.Y,
			Intent.Aim.Z,
			OverlapCount,
			EffectCount,
			DamageCount);
	}
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
	AethelnSpikeAuthority::RecordScenarioStage(
		GetOwner(),
		Intent,
		FGuid(),
		TEXT("submission"),
		TEXT("submitted"),
		EAethelnSpikeAttackRejection::None);
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
	AethelnSpikeAuthority::RecordScenarioStage(
		GetOwner(),
		Intent,
		FGuid(),
		TEXT("rpc-receipt"),
		TEXT("received"),
		EAethelnSpikeAttackRejection::None);
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
	UE_LOG(LogTemp, Warning, TEXT("AUTHORITY rejection category=%s reason=%s client=%s scenario=%s profile=%s run=%s"), *GetScenarioCategoryId(Probe.Category), LexToString(Reason), *ClientId, *ScenarioId, *ProfileId, *RunId);
	if (Reason != EAethelnSpikeAttackRejection::None)
	{
		AethelnSpikeAuthority::EmitObservabilityEvent(
			GetOwner(),
			Probe.Sequence,
			FGuid(),
			AethelnSpikeAuthority::ToObservabilityCategory(Probe.Category),
			Reason,
			false);
	}
	return Reason;
}

FString UAethelnSpikeAuthorityComponent::GetScenarioCategoryId(FName Category)
{
	return Category.ToString().ToLower();
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
	AethelnSpikeAuthority::RecordScenarioStage(
		Owner,
		Intent,
		FGuid(),
		TEXT("validation"),
		Rejection == EAethelnSpikeAttackRejection::None ? TEXT("accepted") : TEXT("rejected"),
		Rejection);
	if (Rejection != EAethelnSpikeAttackRejection::None)
	{
		const EAethelnObservabilityCategory SubjectCategory = Rejection == EAethelnSpikeAttackRejection::ImpossibleAimTransition
			? EAethelnObservabilityCategory::Aim
			: EAethelnObservabilityCategory::Ability;
		AethelnSpikeAuthority::EmitObservabilityEvent(
			Owner,
			Intent.Sequence,
			FGuid(),
			SubjectCategory,
			Rejection);
		AethelnSpikeAuthority::RecordScenarioStage(
			Owner,
			Intent,
			FGuid(),
			TEXT("terminal"),
			TEXT("rejected"),
			Rejection);
		Reject(Rejection);
		return;
	}

	PendingIntent = Intent;
	ActiveAttackId = FGuid::NewGuid();
	AlreadyHitTargets.Reset();
	bAttackWindowActive = true;
	LastRejection = EAethelnSpikeAttackRejection::None;
	AethelnSpikeAuthority::RecordScenarioStage(
		Owner,
		PendingIntent,
		ActiveAttackId,
		TEXT("activation-request"),
		TEXT("requested"),
		EAethelnSpikeAttackRejection::None);

	if (!AbilitySystem->TryActivateAbilityByClass(UAethelnSpikeMeleeAbility::StaticClass(), true))
	{
		AethelnSpikeAuthority::EmitObservabilityEvent(
			Owner,
			PendingIntent.Sequence,
			ActiveAttackId,
			EAethelnObservabilityCategory::Ability,
			EAethelnSpikeAttackRejection::ActivationBlocked);
		AethelnSpikeAuthority::RecordScenarioStage(
			Owner,
			PendingIntent,
			ActiveAttackId,
			TEXT("activation-result"),
			TEXT("blocked"),
			EAethelnSpikeAttackRejection::ActivationBlocked);
		AethelnSpikeAuthority::RecordScenarioStage(
			Owner,
			PendingIntent,
			ActiveAttackId,
			TEXT("terminal"),
			TEXT("activation-blocked"),
			EAethelnSpikeAttackRejection::ActivationBlocked);
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
		const EAethelnSpikeAttackRejection Reason = Owner == nullptr || Owner->IsActorBeingDestroyed()
			? EAethelnSpikeAttackRejection::ActorDestroyed
			: EAethelnSpikeAttackRejection::ConnectionClosed;
		AethelnSpikeAuthority::RecordScenarioStage(
			Owner,
			PendingIntent,
			ActiveAttackId,
			TEXT("resolution"),
			TEXT("rejected"),
			Reason);
		AethelnSpikeAuthority::EmitObservabilityEvent(
			Owner,
			PendingIntent.Sequence,
			ActiveAttackId,
			EAethelnObservabilityCategory::Ability,
			Reason);
		AethelnSpikeAuthority::RecordScenarioStage(
			Owner,
			PendingIntent,
			ActiveAttackId,
			TEXT("terminal"),
			TEXT("rejected"),
			Reason);
		CloseAttackWindow();
		return false;
	}

	AethelnSpikeAuthority::RecordScenarioStage(
		Owner,
		PendingIntent,
		ActiveAttackId,
		TEXT("activation-result"),
		TEXT("activated"),
		EAethelnSpikeAttackRejection::None);
	AethelnSpikeAuthority::EmitObservabilityEvent(
		Owner,
		PendingIntent.Sequence,
		ActiveAttackId,
		EAethelnObservabilityCategory::Ability,
		EAethelnSpikeAttackRejection::None);

	int32 ServerOverlapCount = 0;
	int32 ServerEffectCount = 0;
	int32 ServerDamageCount = 0;
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
	ServerOverlapCount = Overlaps.Num();

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
			++ServerEffectCount;
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
					++ServerDamageCount;
					UE_LOG(LogTemp, Log, TEXT("AUTHORITY damage_applied attacker=%s enemy=%s scenario=%s profile=%s run=%s"), *ClientId, *Enemy->GetName(), *ScenarioId, *ProfileId, *RunId);
				}
			}
		}
	}

	AethelnSpikeAuthority::RecordScenarioStage(
		Owner,
		PendingIntent,
		ActiveAttackId,
		TEXT("resolution"),
		TEXT("resolved"),
		EAethelnSpikeAttackRejection::None,
		ServerOverlapCount,
		ServerEffectCount,
		ServerDamageCount);
	AethelnSpikeAuthority::RecordScenarioStage(
		Owner,
		PendingIntent,
		ActiveAttackId,
		TEXT("terminal"),
		TEXT("resolved"),
		EAethelnSpikeAttackRejection::None,
		ServerOverlapCount,
		ServerEffectCount,
		ServerDamageCount);
	if (ServerEffectCount > 0)
	{
		AethelnSpikeAuthority::EmitObservabilityEvent(
			Owner,
			PendingIntent.Sequence,
			ActiveAttackId,
			EAethelnObservabilityCategory::Hit,
			EAethelnSpikeAttackRejection::None);
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
