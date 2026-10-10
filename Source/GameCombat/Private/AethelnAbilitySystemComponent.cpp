#include "AethelnAbilitySystemComponent.h"

#include "AbilitySystemInterface.h"
#include "AethelnGameplayAbility.h"
#include "AethelnObservability.h"
#include "AethelnObservabilitySubsystem.h"
#include "Engine/GameInstance.h"
#include "Engine/World.h"
#include "GameFramework/Character.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "GameFramework/Controller.h"
#include "GameFramework/GameStateBase.h"
#include "GameFramework/Pawn.h"
#include "GameFramework/PlayerState.h"

DEFINE_LOG_CATEGORY_STATIC(LogAethelnActivationOutcome, Log, All);

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
		case EAethelnActivationResult::TimestampOutOfBounds: return { ECategory::Ability, EAethelnSafeReason::TimestampOutOfBounds };
		case EAethelnActivationResult::ImpossibleAimTransition: return { ECategory::Aim, EAethelnSafeReason::ImpossibleAimTransition };
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

	/** An AimCorrected acceptance: one correction event, emitted before the accepted event and with its ids, and one CorrectionCount sample. */
	void EmitAimCorrection(
		const UActorComponent& Component,
		uint32 Sequence,
		const FGameplayTag& ResolvedAbilityId,
		const FGuid& ActivationId)
	{
		UAethelnObservabilitySubsystem* Subsystem = ResolveSubsystem(Component);
		if (Subsystem == nullptr)
		{
			return;
		}

		const FSafeOutcome Outcome{ EAethelnObservabilityCategory::Aim, EAethelnSafeReason::Corrected };
		FAethelnObservabilityEvent Event;
		Event.Category = EAethelnObservabilityCategory::Correction;
		Event.SubjectCategory = Outcome.Subject;
		Event.SafeReason = Outcome.Reason;

		FAethelnObservabilityEventContext Context;
		Context.ConnectionPseudonym = AethelnObservability::ExcludedIdentifier;
		Context.ActivationId = ActivationId.IsValid() ? ActivationId.ToString(EGuidFormats::DigitsWithHyphensLower) : FString();
		Context.AbilityId = ResolvedAbilityId.IsValid() ? ResolvedAbilityId.ToString() : FString();
		Context.Sequence = Sequence;
		Subsystem->EmitEvent(Event, Context);

		EmitMetric(Component, EAethelnMetricKind::CorrectionCount, Outcome, 1);
	}
}

namespace AethelnAimValidation
{
	/** The angle between two unit vectors in degrees; atan2 of the cross and dot products stays accurate near 0 and 180. */
	double AngleDegrees(const FVector& A, const FVector& B)
	{
		return FMath::RadiansToDegrees(FMath::Atan2((A ^ B).Size(), A | B));
	}

	bool AreBoundsValid(const FAethelnAimTimeBounds& Bounds)
	{
		for (const double Value : {
			Bounds.AimSoftBoundDegrees,
			Bounds.AimHardBoundDegrees,
			Bounds.AimMaxRateDegreesPerSecond,
			Bounds.AimRateSlackDegrees,
			Bounds.AimUnitTolerance,
			Bounds.TimestampMaxAgeSeconds,
			Bounds.TimestampMaxLeadSeconds,
			Bounds.TimestampRegressionToleranceSeconds })
		{
			if (!FMath::IsFinite(Value))
			{
				return false;
			}
		}
		// The hard bound stays below 180 so every accepted aim has a great-circle direction to R.
		return Bounds.AimSoftBoundDegrees >= 0.0
			&& Bounds.AimSoftBoundDegrees <= Bounds.AimHardBoundDegrees
			&& Bounds.AimHardBoundDegrees < 180.0
			&& Bounds.AimRateSlackDegrees >= 0.0
			&& Bounds.AimRateSlackDegrees <= 180.0
			&& Bounds.AimMaxRateDegreesPerSecond >= 0.0
			&& Bounds.AimUnitTolerance > 0.0
			&& Bounds.TimestampMaxAgeSeconds > 0.0
			&& Bounds.TimestampMaxLeadSeconds >= 0.0
			&& Bounds.TimestampRegressionToleranceSeconds >= 0.0;
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
	bool& bOutAbilityResolved,
	FVector& OutAcceptedAim,
	EAethelnAimCorrection& OutAimCorrection)
{
	bOutAbilityResolved = false;
	OutAcceptedAim = FVector::ZeroVector;
	OutAimCorrection = EAethelnAimCorrection::None;

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

	// 6a. Bounds (invalid or unset config fails closed), then the client time sample.
	const FAethelnAimTimeBounds& Bounds = State.Bounds;
	if (!AethelnAimValidation::AreBoundsValid(Bounds))
	{
		return EAethelnActivationResult::InternalFailure;
	}
	const bool bHasPrevious = State.LastAcceptedSequence != 0;
	const double ClientTime = Request.ClientServerTimeSeconds;
	if (!FMath::IsFinite(ClientTime)
		|| ClientTime < State.NowSeconds - Bounds.TimestampMaxAgeSeconds
		|| ClientTime > State.NowSeconds + Bounds.TimestampMaxLeadSeconds
		|| (bHasPrevious && ClientTime < State.LastAcceptedClientTimeSeconds - Bounds.TimestampRegressionToleranceSeconds))
	{
		return EAethelnActivationResult::TimestampOutOfBounds;
	}

	// 6b. A finite, non-zero, unit aim. An aim opposite R has no great-circle direction to clamp along.
	const FVector RawAim = Request.Aim;
	const double AimLength = RawAim.Size();
	if (RawAim.ContainsNaN() || !(AimLength > 0.0) || FMath::Abs(AimLength - 1.0) > Bounds.AimUnitTolerance)
	{
		return EAethelnActivationResult::MalformedRequest;
	}
	const FVector Aim = RawAim / AimLength;
	const FVector& Reference = State.ReferenceAim;
	if ((Aim ^ Reference).Size() <= UE_KINDA_SMALL_NUMBER && (Aim | Reference) < 0.0)
	{
		return EAethelnActivationResult::MalformedRequest;
	}

	// 6c. Within the hard bound of the server reference.
	const double ReferenceAngle = AethelnAimValidation::AngleDegrees(Aim, Reference);
	if (ReferenceAngle > Bounds.AimHardBoundDegrees)
	{
		return EAethelnActivationResult::ImpossibleAimTransition;
	}

	// 6d. Raw aim against the last accepted raw aim, over the client-time interval.
	if (bHasPrevious)
	{
		const double Interval = FMath::Max(0.0, ClientTime - State.LastAcceptedClientTimeSeconds);
		const double AllowedDegrees = Bounds.AimRateSlackDegrees + Bounds.AimMaxRateDegreesPerSecond * Interval;
		if (AethelnAimValidation::AngleDegrees(Aim, State.LastAcceptedAim.GetSafeNormal()) > AllowedDegrees)
		{
			return EAethelnActivationResult::ImpossibleAimTransition;
		}
	}

	// The accepted aim: as sent within the soft bound, otherwise R rotated toward it by exactly the soft bound.
	if (ReferenceAngle <= Bounds.AimSoftBoundDegrees)
	{
		OutAcceptedAim = Aim;
	}
	else
	{
		// Not antipodal (6b) and not parallel (the angle exceeds the soft bound), so the direction exists.
		const FVector Toward = ((Reference ^ Aim) ^ Reference).GetUnsafeNormal();
		const double SoftRadians = FMath::DegreesToRadians(Bounds.AimSoftBoundDegrees);
		OutAcceptedAim = Reference * FMath::Cos(SoftRadians) + Toward * FMath::Sin(SoftRadians);
		OutAimCorrection = EAethelnAimCorrection::AimCorrected;
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
	const APlayerState* PlayerState = Cast<APlayerState>(GetOwner());
	if (const AController* Controller = PlayerState != nullptr ? PlayerState->GetOwningController() : nullptr)
	{
		Request.Aim = Controller->GetControlRotation().Vector();
	}
	if (const UWorld* World = GetWorld())
	{
		const AGameStateBase* GameState = World->GetGameState();
		Request.ClientServerTimeSeconds = GameState != nullptr ? GameState->GetServerWorldTimeSeconds() : World->GetTimeSeconds();
	}
	// Send a held move first so the server's control rotation is fresher. A mitigation, not authority.
	if (const ACharacter* Character = Cast<ACharacter>(GetAvatarActor()))
	{
		if (UCharacterMovementComponent* Movement = Character->GetCharacterMovement())
		{
			Movement->FlushServerMoves();
		}
	}
	ServerSubmitActivation(Request);
}

void UAethelnAbilitySystemComponent::ServerSubmitActivation_Implementation(const FAethelnCombatActivationRequest& Request)
{
	ProcessServerRequest(Request);
}

EAethelnActivationResult UAethelnAbilitySystemComponent::ProcessServerRequest(const FAethelnCombatActivationRequest& Request)
{
	// Server only: a client opening a seam scope locally would activate nothing, but it is not the contract.
	if (!ensureMsgf(IsOwnerActorAuthoritative(), TEXT("ProcessServerRequest runs only on the server")))
	{
		return EAethelnActivationResult::ConnectionClosed;
	}

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
	const UWorld* World = GetWorld();
	State.NowSeconds = World != nullptr ? World->GetTimeSeconds() : 0.0;
	if (State.bHasPossessedAvatar)
	{
		State.ReferenceAim = Controller->GetControlRotation().Vector();
	}
	State.LastAcceptedAim = LastAcceptedAim;
	State.LastAcceptedClientTimeSeconds = LastAcceptedClientTimeSeconds;
	State.Bounds.AimSoftBoundDegrees = ProvisionalAimSoftBoundDegrees;
	State.Bounds.AimHardBoundDegrees = ProvisionalAimHardBoundDegrees;
	State.Bounds.AimMaxRateDegreesPerSecond = ProvisionalAimMaxRateDegreesPerSecond;
	State.Bounds.AimRateSlackDegrees = ProvisionalAimRateSlackDegrees;
	State.Bounds.AimUnitTolerance = ProvisionalAimUnitTolerance;
	State.Bounds.TimestampMaxAgeSeconds = ProvisionalTimestampMaxAgeSeconds;
	State.Bounds.TimestampMaxLeadSeconds = ProvisionalTimestampMaxLeadSeconds;
	State.Bounds.TimestampRegressionToleranceSeconds = ProvisionalTimestampRegressionToleranceSeconds;

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

	// 2 to 7. P2 outputs the accepted aim only; #60 P3 carries it through the seam scope.
	bool bAbilityResolved = false;
	FVector AcceptedAim;
	EAethelnAimCorrection AimCorrection = EAethelnAimCorrection::None;
	const EAethelnActivationResult Validation = ValidateRequest(Request, State, bAbilityResolved, AcceptedAim, AimCorrection);
	const FGameplayTag ResolvedAbilityId = bAbilityResolved ? Request.AbilityId : FGameplayTag();
	if (Validation != EAethelnActivationResult::Accepted)
	{
		return Finish(Request, Validation, ResolvedAbilityId, FGuid());
	}

	// A valid Release is accepted: it ends the running activation and skips steps 8 and 9.
	if (Request.Phase == EAethelnActivationPhase::Release)
	{
		// Unreachable for a validated InstancedPerActor spec; fail closed anyway.
		if (Instance == nullptr)
		{
			return Finish(Request, EAethelnActivationResult::InternalFailure, ResolvedAbilityId, FGuid());
		}
		const FGuid RunningActivationId = Instance->GetActivationId();
		Instance->EndForRelease();
		return Finish(Request, EAethelnActivationResult::Accepted, ResolvedAbilityId, RunningActivationId, AimCorrection);
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
		// Fail closed: an activation that did not commit must not keep running or holding its state tags.
		const FGameplayAbilitySpec* ActivatedSpec = FindAbilitySpecFromHandle(Handle);
		if (ActivatedSpec != nullptr && ActivatedSpec->IsActive())
		{
			CancelAbilityHandle(Handle);
		}
		return Finish(Request, EAethelnActivationResult::InternalFailure, ResolvedAbilityId, FGuid());
	}

	// 10.
	return Finish(Request, EAethelnActivationResult::Accepted, ResolvedAbilityId, Scope.ActivationId, AimCorrection);
}

EAethelnActivationResult UAethelnAbilitySystemComponent::Finish(
	const FAethelnCombatActivationRequest& Request,
	EAethelnActivationResult Result,
	const FGameplayTag& ResolvedAbilityId,
	const FGuid& ActivationId,
	EAethelnAimCorrection AimCorrection)
{
	if (Result == EAethelnActivationResult::Accepted)
	{
		LastAcceptedSequence = Request.Sequence;
		LastAcceptedAim = Request.Aim;
		LastAcceptedClientTimeSeconds = Request.ClientServerTimeSeconds;
		if (AimCorrection == EAethelnAimCorrection::AimCorrected)
		{
			AethelnActivationTelemetry::EmitAimCorrection(*this, Request.Sequence, ResolvedAbilityId, ActivationId);
		}
	}
	AethelnActivationTelemetry::EmitOutcome(*this, Result, Request.Sequence, ResolvedAbilityId, ActivationId);
	ClientActivationOutcome(Request.Sequence, Result);
	return Result;
}

void UAethelnAbilitySystemComponent::ClientActivationOutcome_Implementation(uint32 Sequence, EAethelnActivationResult Result)
{
	UE_LOG(LogAethelnActivationOutcome, Log, TEXT("Activation outcome received: sequence=%u result=%s"), Sequence, *UEnum::GetValueAsString(Result));
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

void UAethelnAbilitySystemComponent::ServerSetReplicatedTargetData_Implementation(
	FGameplayAbilitySpecHandle AbilityHandle,
	FPredictionKey AbilityOriginalPredictionKey,
	const FGameplayAbilityTargetDataHandle& ReplicatedTargetDataHandle,
	FGameplayTag ApplicationTag,
	FPredictionKey CurrentPredictionKey)
{
	RefuseStockRoute();
}

void UAethelnAbilitySystemComponent::ServerSetReplicatedTargetDataCancelled_Implementation(
	FGameplayAbilitySpecHandle AbilityHandle,
	FPredictionKey AbilityOriginalPredictionKey,
	FPredictionKey CurrentPredictionKey)
{
	RefuseStockRoute();
}

void UAethelnAbilitySystemComponent::ServerSetReplicatedEvent_Implementation(
	EAbilityGenericReplicatedEvent::Type EventType,
	FGameplayAbilitySpecHandle AbilityHandle,
	FPredictionKey AbilityOriginalPredictionKey,
	FPredictionKey CurrentPredictionKey)
{
	RefuseStockRoute();
}

void UAethelnAbilitySystemComponent::ServerSetReplicatedEventWithPayload_Implementation(
	EAbilityGenericReplicatedEvent::Type EventType,
	FGameplayAbilitySpecHandle AbilityHandle,
	FPredictionKey AbilityOriginalPredictionKey,
	FPredictionKey CurrentPredictionKey,
	FVector_NetQuantize100 VectorPayload)
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
