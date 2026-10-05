#include "AethelnAbilitySystemComponent.h"

#include "AbilitySystemInterface.h"
#include "AethelnGameplayAbility.h"
#include "AethelnObservability.h"
#include "AethelnObservabilitySubsystem.h"
#include "Engine/GameInstance.h"
#include "Engine/World.h"
#include "GameFramework/Controller.h"
#include "GameFramework/Pawn.h"
#include "GameFramework/PlayerState.h"

namespace AethelnActivationTelemetry
{
	struct FSafeOutcome
	{
		EAethelnObservabilityCategory Subject = EAethelnObservabilityCategory::Ability;
		EAethelnSafeReason Reason = EAethelnSafeReason::Rejected;
	};

	/** The private mapping table (docs/gas-foundation.md, Rejection Telemetry). */
	FSafeOutcome ToSafeOutcome(EAethelnActivationResult Result)
	{
		using ECategory = EAethelnObservabilityCategory;
		switch (Result)
		{
		case EAethelnActivationResult::Accepted: return { ECategory::Ability, EAethelnSafeReason::Accepted };
		case EAethelnActivationResult::RateLimited: return { ECategory::Ability, EAethelnSafeReason::RateLimited };
		case EAethelnActivationResult::ConnectionClosed: return { ECategory::Ability, EAethelnSafeReason::ConnectionClosed };
		case EAethelnActivationResult::ActorDestroyed: return { ECategory::Ability, EAethelnSafeReason::ActorDestroyed };
		case EAethelnActivationResult::IncompatibleVersion: return { ECategory::Ability, EAethelnSafeReason::IncompatibleVersion };
		case EAethelnActivationResult::StaleSequence: return { ECategory::Ability, EAethelnSafeReason::StaleSequence };
		case EAethelnActivationResult::DuplicateSequence: return { ECategory::Ability, EAethelnSafeReason::DuplicateSequence };
		case EAethelnActivationResult::MalformedRequest: return { ECategory::Ability, EAethelnSafeReason::MalformedRequest };
		case EAethelnActivationResult::ActivationBlocked: return { ECategory::Ability, EAethelnSafeReason::ActivationBlocked };
		case EAethelnActivationResult::OnCooldown: return { ECategory::Cooldown, EAethelnSafeReason::ActivationBlocked };
		case EAethelnActivationResult::InsufficientResource: return { ECategory::Resource, EAethelnSafeReason::ActivationBlocked };
		case EAethelnActivationResult::InternalFailure: return { ECategory::Ability, EAethelnSafeReason::InternalFailure };
		default: return {};
		}
	}

	/** Resolved at emit time; a missing subsystem or failed sink never changes gameplay. */
	UAethelnObservabilitySubsystem* ResolveSubsystem(const UActorComponent& Component)
	{
		const UWorld* World = Component.GetWorld();
		UGameInstance* GameInstance = World != nullptr ? World->GetGameInstance() : nullptr;
		return GameInstance != nullptr ? GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>() : nullptr;
	}

	void EmitMetric(const UActorComponent& Component, EAethelnMetricKind Metric, const FSafeOutcome& Outcome, int64 Value)
	{
		if (UAethelnObservabilitySubsystem* Subsystem = ResolveSubsystem(Component))
		{
			FAethelnMetricSample Sample;
			Sample.Metric = Metric;
			Sample.Category = Outcome.Subject;
			Sample.Reason = Outcome.Reason;
			Sample.Value = Value;
			Subsystem->EmitMetric(Sample);
		}
	}

	/** One event and one metric per outcome. The contract drops the event of a zero-sequence request. */
	void EmitOutcome(
		const UActorComponent& Component,
		EAethelnActivationResult Result,
		uint32 Sequence,
		const FGameplayTag& ResolvedAbilityId,
		const FGuid& ActivationId)
	{
		UAethelnObservabilitySubsystem* Subsystem = ResolveSubsystem(Component);
		if (Subsystem == nullptr)
		{
			return;
		}

		const bool bAccepted = Result == EAethelnActivationResult::Accepted;
		const FSafeOutcome Outcome = ToSafeOutcome(Result);
		FAethelnObservabilityEvent Event;
		Event.Category = bAccepted ? Outcome.Subject : EAethelnObservabilityCategory::Rejection;
		Event.SubjectCategory = Outcome.Subject;
		Event.SafeReason = Outcome.Reason;
		Event.DiagnosticCode = bAccepted ? EAethelnDiagnosticCode::None : EAethelnDiagnosticCode::ValidationFailed;

		FAethelnObservabilityEventContext Context;
		Context.ConnectionPseudonym = AethelnObservability::ExcludedIdentifier;
		// Rejections precede activation, so they never carry an activation id.
		Context.ActivationId = bAccepted && ActivationId.IsValid()
			? ActivationId.ToString(EGuidFormats::DigitsWithHyphensLower)
			: FString();
		Context.AbilityId = ResolvedAbilityId.IsValid() ? ResolvedAbilityId.ToString() : FString();
		Context.Sequence = Sequence;
		Subsystem->EmitEvent(Event, Context);

		EmitMetric(Component, bAccepted ? EAethelnMetricKind::EventCount : EAethelnMetricKind::RejectionCount, Outcome, 1);
	}
}

bool FAethelnActivationRateBucket::TryConsume(double NowSeconds, double Capacity, double RefillPerSecond)
{
	if (!FMath::IsFinite(NowSeconds) || !FMath::IsFinite(Capacity) || !FMath::IsFinite(RefillPerSecond)
		|| Capacity < 1.0 || RefillPerSecond < 0.0)
	{
		return false;
	}
	if (!bStarted)
	{
		bStarted = true;
		Tokens = Capacity;
		LastRefillSeconds = NowSeconds;
	}
	Tokens = FMath::Min(Capacity, Tokens + FMath::Max(0.0, NowSeconds - LastRefillSeconds) * RefillPerSecond);
	LastRefillSeconds = FMath::Max(LastRefillSeconds, NowSeconds);
	if (Tokens < 1.0)
	{
		return false;
	}
	Tokens -= 1.0;
	return true;
}

UAethelnAbilitySystemComponent* UAethelnAbilitySystemComponent::FindForPawn(const APawn* Pawn)
{
	if (Pawn == nullptr)
	{
		return nullptr;
	}

	if (const IAbilitySystemInterface* PlayerStateOwner = Cast<IAbilitySystemInterface>(Pawn->GetPlayerState()))
	{
		return Cast<UAethelnAbilitySystemComponent>(PlayerStateOwner->GetAbilitySystemComponent());
	}

	return Pawn->FindComponentByClass<UAethelnAbilitySystemComponent>();
}

EAethelnActivationResult UAethelnAbilitySystemComponent::ValidateRequest(
	const FAethelnCombatActivationRequest& Request,
	const FAethelnActivationValidationState& State,
	bool& bOutAbilityResolved)
{
	bOutAbilityResolved = false;

	// 2. Lifecycle.
	if (State.bAvatarBeingDestroyed)
	{
		return EAethelnActivationResult::ActorDestroyed;
	}
	if (!State.bHasPossessedAvatar)
	{
		return EAethelnActivationResult::ConnectionClosed;
	}

	// 3. Layout version.
	if (Request.SchemaVersion != AethelnActivation::SchemaVersion)
	{
		return EAethelnActivationResult::IncompatibleVersion;
	}

	// 4. Sequence: zero or lower is stale, equal is a duplicate, forward gaps are accepted.
	if (Request.Sequence == 0 || Request.Sequence < State.LastAcceptedSequence)
	{
		return EAethelnActivationResult::StaleSequence;
	}
	if (Request.Sequence == State.LastAcceptedSequence)
	{
		return EAethelnActivationResult::DuplicateSequence;
	}

	// 5. Identity: unknown is malformed; known but not granted is blocked.
	if (!UAethelnGameplayAbility::IsAbilityIdentityTag(Request.AbilityId))
	{
		return EAethelnActivationResult::MalformedRequest;
	}
	if (!State.bAbilityGranted)
	{
		return EAethelnActivationResult::ActivationBlocked;
	}
	bOutAbilityResolved = true;

	// 6. Content version.
	if (Request.ContentVersion != State.GrantedContentVersion)
	{
		return EAethelnActivationResult::IncompatibleVersion;
	}

	// 7. Phase and instance state.
	switch (Request.Phase)
	{
	case EAethelnActivationPhase::Press:
		return State.bAbilityActive ? EAethelnActivationResult::ActivationBlocked : EAethelnActivationResult::Accepted;
	case EAethelnActivationPhase::Release:
		if (!State.bAcceptsRelease)
		{
			return EAethelnActivationResult::MalformedRequest;
		}
		return State.bAbilityActive ? EAethelnActivationResult::Accepted : EAethelnActivationResult::ActivationBlocked;
	default:
		return EAethelnActivationResult::MalformedRequest;
	}
}

void UAethelnAbilitySystemComponent::RequestActivation(const FGameplayTag& AbilityId, EAethelnActivationPhase Phase)
{
	FAethelnCombatActivationRequest Request;
	Request.AbilityId = AbilityId;
	Request.Phase = Phase;
	Request.Sequence = NextRequestSequence++;
	if (const FGameplayAbilitySpec* Spec = FindSpecForAbilityId(AbilityId))
	{
		Request.ContentVersion = CastChecked<UAethelnGameplayAbility>(Spec->Ability)->ContentVersion;
	}
	ServerSubmitActivation(Request);
}

void UAethelnAbilitySystemComponent::ServerSubmitActivation_Implementation(const FAethelnCombatActivationRequest& Request)
{
	ProcessServerRequest(Request);
}

EAethelnActivationResult UAethelnAbilitySystemComponent::ProcessServerRequest(const FAethelnCombatActivationRequest& Request)
{
	// 1. Rate bucket, before any lookup.
	if (!AdmitMessage(true, Request.Sequence))
	{
		return EAethelnActivationResult::RateLimited;
	}

	FAethelnActivationValidationState State;
	AActor* Avatar = GetAvatarActor();
	const APawn* AvatarPawn = Cast<APawn>(Avatar);
	const APlayerState* PlayerState = Cast<APlayerState>(GetOwner());
	const AController* Controller = PlayerState != nullptr ? PlayerState->GetOwningController() : nullptr;
	State.bAvatarBeingDestroyed = Avatar != nullptr && Avatar->IsActorBeingDestroyed();
	State.bHasPossessedAvatar = AvatarPawn != nullptr
		&& PlayerState != nullptr
		&& PlayerState->GetPawn() == AvatarPawn
		&& Controller != nullptr
		&& AvatarPawn->GetController() == Controller;
	State.LastAcceptedSequence = LastAcceptedSequence;

	const FGameplayAbilitySpec* Spec = FindSpecForAbilityId(Request.AbilityId);
	const UAethelnGameplayAbility* Definition = Spec != nullptr ? Cast<UAethelnGameplayAbility>(Spec->Ability) : nullptr;
	UAethelnGameplayAbility* Instance = Spec != nullptr ? Cast<UAethelnGameplayAbility>(Spec->GetPrimaryInstance()) : nullptr;
	if (Definition != nullptr)
	{
		State.bAbilityGranted = true;
		State.GrantedContentVersion = Definition->ContentVersion;
		State.bAcceptsRelease = Definition->bAcceptsRelease;
		State.bAbilityActive = Spec->IsActive();
	}

	// 2 to 7.
	bool bAbilityResolved = false;
	const EAethelnActivationResult Validation = ValidateRequest(Request, State, bAbilityResolved);
	const FGameplayTag ResolvedAbilityId = bAbilityResolved ? Request.AbilityId : FGameplayTag();
	if (Validation != EAethelnActivationResult::Accepted)
	{
		return Finish(Request, Validation, ResolvedAbilityId, FGuid());
	}

	// A valid Release is accepted: it ends the running activation and skips steps 8 and 9.
	if (Request.Phase == EAethelnActivationPhase::Release)
	{
		const FGuid RunningActivationId = Instance != nullptr ? Instance->GetActivationId() : FGuid();
		if (Instance != nullptr)
		{
			Instance->EndForRelease();
		}
		return Finish(Request, EAethelnActivationResult::Accepted, ResolvedAbilityId, RunningActivationId);
	}

	// 8. Engine eligibility, in the engine's order. Unlike the engine, the seam ignores the cheat variables.
	const FGameplayAbilitySpecHandle Handle = Spec->Handle;
	const UGameplayAbility* Source = Instance != nullptr ? static_cast<const UGameplayAbility*>(Instance) : Definition;
	const FGameplayAbilityActorInfo* ActorInfo = AbilityActorInfo.Get();
	if (!Source->CheckCooldown(Handle, ActorInfo))
	{
		return Finish(Request, EAethelnActivationResult::OnCooldown, ResolvedAbilityId, FGuid());
	}
	if (!Source->CheckCost(Handle, ActorInfo))
	{
		return Finish(Request, EAethelnActivationResult::InsufficientResource, ResolvedAbilityId, FGuid());
	}
	if (!Source->DoesAbilitySatisfyTagRequirements(*this))
	{
		return Finish(Request, EAethelnActivationResult::ActivationBlocked, ResolvedAbilityId, FGuid());
	}

	// 9. Activate inside the seam scope. The result slot, not the return value, says whether it committed.
	FSeamScope Scope;
	Scope.Handle = Handle;
	bool bActivated = false;
	{
		TGuardValue<FSeamScope*> ScopeGuard(ActiveSeamScope, &Scope);
		bActivated = TryActivateAbility(Handle, false);
	}
	if (!bActivated)
	{
		return Finish(Request, EAethelnActivationResult::ActivationBlocked, ResolvedAbilityId, FGuid());
	}
	if (!Scope.bCommitted)
	{
		return Finish(Request, EAethelnActivationResult::InternalFailure, ResolvedAbilityId, FGuid());
	}

	// 10.
	return Finish(Request, EAethelnActivationResult::Accepted, ResolvedAbilityId, Scope.ActivationId);
}

EAethelnActivationResult UAethelnAbilitySystemComponent::Finish(
	const FAethelnCombatActivationRequest& Request,
	EAethelnActivationResult Result,
	const FGameplayTag& ResolvedAbilityId,
	const FGuid& ActivationId)
{
	if (Result == EAethelnActivationResult::Accepted)
	{
		LastAcceptedSequence = Request.Sequence;
	}
	AethelnActivationTelemetry::EmitOutcome(*this, Result, Request.Sequence, ResolvedAbilityId, ActivationId);
	ClientActivationOutcome(Request.Sequence, Result);
	return Result;
}

void UAethelnAbilitySystemComponent::ClientActivationOutcome_Implementation(uint32 Sequence, EAethelnActivationResult Result)
{
	OnActivationOutcome.Broadcast(Sequence, Result);
}

bool UAethelnAbilitySystemComponent::AdmitMessage(bool bSeamRequest, uint32 Sequence)
{
	const UWorld* World = GetWorld();
	if (RateBucket.TryConsume(
		World != nullptr ? World->GetRealTimeSeconds() : 0.0,
		ProvisionalActivationBucketCapacity,
		ProvisionalActivationBucketRefillPerSecond))
	{
		CloseRateLimitedWindow();
		return true;
	}

	// While limited: no events and no outcomes, only a count.
	if (bRateLimited)
	{
		++SuppressedMessageCount;
		return false;
	}

	// Entering the window: one event (dropped for a zero sequence), one metric, and an outcome only for a seam request.
	bRateLimited = true;
	SuppressedMessageCount = 0;
	AethelnActivationTelemetry::EmitOutcome(*this, EAethelnActivationResult::RateLimited, Sequence, FGameplayTag(), FGuid());
	if (bSeamRequest)
	{
		ClientActivationOutcome(Sequence, EAethelnActivationResult::RateLimited);
	}
	return false;
}

void UAethelnAbilitySystemComponent::CloseRateLimitedWindow()
{
	if (!bRateLimited)
	{
		return;
	}
	bRateLimited = false;
	AethelnActivationTelemetry::EmitMetric(
		*this,
		EAethelnMetricKind::RejectionCount,
		AethelnActivationTelemetry::ToSafeOutcome(EAethelnActivationResult::RateLimited),
		SuppressedMessageCount);
	SuppressedMessageCount = 0;
}

void UAethelnAbilitySystemComponent::RefuseStockRoute()
{
	// No reply: no legitimate client uses the stock routes, so a hostile one gets nothing to amplify.
	if (AdmitMessage(false, 0))
	{
		AethelnActivationTelemetry::EmitMetric(
			*this,
			EAethelnMetricKind::RejectionCount,
			{ EAethelnObservabilityCategory::Ability, EAethelnSafeReason::Rejected },
			1);
	}
}

void UAethelnAbilitySystemComponent::InternalServerTryActivateAbility(
	FGameplayAbilitySpecHandle Handle,
	bool InputPressed,
	const FPredictionKey& PredictionKey,
	const FGameplayEventData* TriggerEventData)
{
	RefuseStockRoute();
}

void UAethelnAbilitySystemComponent::ServerAbilityRPCBatch_Internal(FServerAbilityRPCBatch& BatchInfo)
{
	RefuseStockRoute();
}

void UAethelnAbilitySystemComponent::OnUnregister()
{
	// A window ends only when a message is admitted, so teardown flushes it.
	CloseRateLimitedWindow();
	Super::OnUnregister();
}

bool UAethelnAbilitySystemComponent::IsSeamActivating(FGameplayAbilitySpecHandle Handle) const
{
	return ActiveSeamScope != nullptr && ActiveSeamScope->Handle == Handle;
}

void UAethelnAbilitySystemComponent::RecordSeamCommit(FGameplayAbilitySpecHandle Handle, bool bCommitted, const FGuid& ActivationId)
{
	if (IsSeamActivating(Handle))
	{
		ActiveSeamScope->bCommitted = bCommitted;
		ActiveSeamScope->ActivationId = ActivationId;
	}
}

const FGameplayAbilitySpec* UAethelnAbilitySystemComponent::FindSpecForAbilityId(const FGameplayTag& AbilityId) const
{
	if (!AbilityId.IsValid())
	{
		return nullptr;
	}
	for (const FGameplayAbilitySpec& Spec : GetActivatableAbilities())
	{
		const UAethelnGameplayAbility* Ability = Cast<UAethelnGameplayAbility>(Spec.Ability);
		if (Ability != nullptr && !Spec.PendingRemove && Ability->GetAbilityId() == AbilityId)
		{
			return &Spec;
		}
	}
	return nullptr;
}

#if WITH_DEV_AUTOMATION_TESTS
void UAethelnAbilitySystemComponent::CallServerTryActivateAbilityForTests(FGameplayAbilitySpecHandle Handle)
{
	ServerTryActivateAbility(Handle, true, FPredictionKey());
}

void UAethelnAbilitySystemComponent::CallServerTryActivateAbilityWithEventDataForTests(FGameplayAbilitySpecHandle Handle, const FGameplayEventData& EventData)
{
	ServerTryActivateAbilityWithEventData(Handle, true, FPredictionKey(), EventData);
}

bool UAethelnAbilitySystemComponent::HasReplicatedTargetDataForTests(FGameplayAbilitySpecHandle Handle, const FPredictionKey& PredictionKey) const
{
	return AbilityTargetDataMap.Find(FGameplayAbilitySpecHandleAndPredictionKey(Handle, PredictionKey)).IsValid();
}
#endif
