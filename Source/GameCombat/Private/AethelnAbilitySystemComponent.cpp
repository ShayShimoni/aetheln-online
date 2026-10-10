#include "AethelnAbilitySystemComponent.h"

#include "AbilitySystemInterface.h"
#include "AethelnGameplayAbility.h"
#include "AethelnBasicChainAbility.h"
#include "AethelnCharacterMovementComponent.h"
#include "AethelnCombatTimelineSubsystem.h"
#include "AethelnDodgeAbility.h"
#include "AethelnGameplayTags.h"
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
#include "Net/UnrealNetwork.h"

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

	/**
	 * One event and one metric per outcome. The contract drops the event of a zero-sequence request.
	 * ActionSubject replaces the generic Ability subject for a resolved action (Dodge); the
	 * Cooldown, Resource and Aim subjects keep #19's mapping.
	 */
	void EmitOutcome(
		const UActorComponent& Component,
		EAethelnActivationResult Result,
		uint32 Sequence,
		const FGameplayTag& ResolvedAbilityId,
		const FGuid& ActivationId,
		EAethelnObservabilityCategory ActionSubject = EAethelnObservabilityCategory::Ability)
	{
		UAethelnObservabilitySubsystem* Subsystem = ResolveSubsystem(Component);
		if (Subsystem == nullptr)
		{
			return;
		}

		const bool bAccepted = Result == EAethelnActivationResult::Accepted;
		FSafeOutcome Outcome = ToSafeOutcome(Result);
		if (Outcome.Subject == EAethelnObservabilityCategory::Ability)
		{
			Outcome.Subject = ActionSubject;
		}
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

/** Steps both routes share (docs/dodge-and-block.md, T1): pure, so each route calls them without a synthesized request. */
namespace AethelnSharedValidation
{
	/** 2. Lifecycle. */
	EAethelnActivationResult Lifecycle(const FAethelnActivationValidationState& State)
	{
		if (State.bAvatarBeingDestroyed)
		{
			return EAethelnActivationResult::ActorDestroyed;
		}
		return State.bHasPossessedAvatar ? EAethelnActivationResult::Accepted : EAethelnActivationResult::ConnectionClosed;
	}

	/** 6. Content version. */
	EAethelnActivationResult ContentVersion(uint32 RequestVersion, const FAethelnActivationValidationState& State)
	{
		return RequestVersion == State.GrantedContentVersion ? EAethelnActivationResult::Accepted : EAethelnActivationResult::IncompatibleVersion;
	}

	/** 7, Press: the single instance must be inactive. */
	EAethelnActivationResult Press(const FAethelnActivationValidationState& State)
	{
		return State.bAbilityActive ? EAethelnActivationResult::ActivationBlocked : EAethelnActivationResult::Accepted;
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
	const EAethelnActivationResult LifecycleResult = AethelnSharedValidation::Lifecycle(State);
	if (LifecycleResult != EAethelnActivationResult::Accepted)
	{
		return LifecycleResult;
	}

	// 3. Layout version.
	if (Request.SchemaVersion != AethelnActivation::SchemaVersion)
	{
		return EAethelnActivationResult::IncompatibleVersion;
	}

	// 4. Sequence: zero or lower is stale, equal is a duplicate, forward gaps are accepted.
	const uint32 SequenceFloor = FMath::Max(State.LastAcceptedSequence, State.HighestInFlightSequence);
	if (Request.Sequence == 0 || Request.Sequence < SequenceFloor)
	{
		return EAethelnActivationResult::StaleSequence;
	}
	if (Request.Sequence == SequenceFloor)
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
	// Each ability has exactly one route: a movement-carried one never enters through the RPC.
	if (State.bMovementCarried)
	{
		return EAethelnActivationResult::MalformedRequest;
	}
	bOutAbilityResolved = true;

	// 6. Content version.
	const EAethelnActivationResult VersionResult = AethelnSharedValidation::ContentVersion(Request.ContentVersion, State);
	if (VersionResult != EAethelnActivationResult::Accepted)
	{
		return VersionResult;
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
		return AethelnSharedValidation::Press(State);
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

EAethelnActivationResult UAethelnAbilitySystemComponent::ValidateMovementRequest(
	uint32 ContentVersion,
	bool bMovementAllowsStart,
	const FAethelnActivationValidationState& State,
	bool& bOutAbilityResolved)
{
	bOutAbilityResolved = false;

	// 2.
	const EAethelnActivationResult LifecycleResult = AethelnSharedValidation::Lifecycle(State);
	if (LifecycleResult != EAethelnActivationResult::Accepted)
	{
		return LifecycleResult;
	}

	// 3 and 4 do not apply: build-identical move data and the engine's received-move timestamp rule.
	// 5. The granted movement-carried ability; the move names no ability, so absent is blocked.
	if (!State.bAbilityGranted || !State.bMovementCarried)
	{
		return EAethelnActivationResult::ActivationBlocked;
	}
	bOutAbilityResolved = true;

	// 6. Content version. 6a to 6d do not apply: a dodge has no aim and no time sample.
	const EAethelnActivationResult VersionResult = AethelnSharedValidation::ContentVersion(ContentVersion, State);
	if (VersionResult != EAethelnActivationResult::Accepted)
	{
		return VersionResult;
	}

	// 7. Press only, on an inactive instance, with the server's own start predicate.
	const EAethelnActivationResult PressResult = AethelnSharedValidation::Press(State);
	if (PressResult != EAethelnActivationResult::Accepted)
	{
		return PressResult;
	}
	return bMovementAllowsStart ? EAethelnActivationResult::Accepted : EAethelnActivationResult::ActivationBlocked;
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
	if (!AdmitMessage(EMessageRoute::Seam, Request.Sequence))
	{
		return EAethelnActivationResult::RateLimited;
	}

	FRequestScope RequestScope;
	RequestScope.Previous = ActiveRequestScope;
	RequestScope.Sequence = Request.Sequence;
	RequestScope.Owner = GetOwner();
	RequestScope.Avatar = GetAvatarActor();
	const APlayerState* RequestOwner = Cast<APlayerState>(GetOwner());
	RequestScope.Controller = RequestOwner != nullptr ? RequestOwner->GetOwningController() : nullptr;
	TGuardValue<FRequestScope*> RequestGuard(ActiveRequestScope, &RequestScope);
	// Boundaries can end/reset an ability and synchronously admit another request.
	const UWorld* BoundaryWorld = GetWorld();
	ApplyDueBoundaries(BoundaryWorld != nullptr ? BoundaryWorld->GetTimeSeconds() : 0.0);
	FAethelnActivationValidationState State;
	FillLifecycleState(State, RequestScope);
	const APlayerState* PlayerState = Cast<APlayerState>(GetOwner());
	const AController* Controller = PlayerState != nullptr ? PlayerState->GetOwningController() : nullptr;
	State.LastAcceptedSequence = LastAcceptedSequence;
	for (const FRequestScope* Pending = RequestScope.Previous; Pending != nullptr; Pending = Pending->Previous)
	{
		State.HighestInFlightSequence = FMath::Max(State.HighestInFlightSequence, Pending->Sequence);
	}
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
		State.bMovementCarried = Definition->IsMovementCarried();
		State.GrantedContentVersion = Definition->ContentVersion;
		State.bAcceptsRelease = Definition->bAcceptsRelease;
		// PreActivate makes the instance active before it increments the spec count.
		State.bAbilityActive = Request.Phase == EAethelnActivationPhase::Release
			? Instance != nullptr && Instance->CanEndForRelease()
			: Spec->IsActive() || (Instance != nullptr && Instance->IsActive());
	}

	// 2 to 7. Carry only the accepted direction into the activation; RAW history remains in Finish.
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
	const EAethelnActivationResult Eligibility = CheckEligibility(*Source, Handle);
	if (Eligibility != EAethelnActivationResult::Accepted)
	{
		return Finish(Request, Eligibility, ResolvedAbilityId, FGuid());
	}

	// 9. Activate inside the seam scope. The result slot, not the return value, says whether it committed.
	FSeamScope Scope;
	Scope.Handle = Handle;
	Scope.ActivationId = FGuid::NewGuid(); // immutable original server operation, before PreActivate
	Scope.AttackInput.Sequence = Request.Sequence;
	Scope.AttackInput.ContentVersion = Request.ContentVersion;
	Scope.AttackInput.AcceptedAim = AcceptedAim;
	Scope.AttackInput.AimCorrection = AimCorrection;
	Scope.AttackInput.ReceiptServerTime = State.NowSeconds;
	bool bActivated = false;
	{
		TGuardValue<FSeamScope*> ScopeGuard(ActiveSeamScope, &Scope);
		bActivated = TryActivateAbility(Handle, false);
	}
	if (!bActivated)
	{
		return Finish(Request, EAethelnActivationResult::ActivationBlocked, ResolvedAbilityId, FGuid());
	}
	if (!Scope.bCommitted || (Cast<UAethelnBasicChainAbility>(Definition) != nullptr && !Scope.bChainReady))
	{
		CancelUncommittedActivation(Handle, Scope.ActivationId);
		return Finish(Request, EAethelnActivationResult::InternalFailure, ResolvedAbilityId, Scope.bCommitted ? Scope.ActivationId : FGuid());
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
		if (Request.Sequence > LastAcceptedSequence)
		{
			// Outcome correlation remains per request; only the latest accepted tuple advances.
			LastAcceptedSequence = Request.Sequence;
			LastAcceptedAim = Request.Aim;
			LastAcceptedClientTimeSeconds = Request.ClientServerTimeSeconds;
		}
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
	OnActivationOutcome.Broadcast(Sequence, Result);
}

EAethelnActivationResult UAethelnAbilitySystemComponent::ProcessMovementCarriedRequest(const FAethelnDodgeStartRequest& Request)
{
	// A client or replay copy never authorizes; it draws no token and sends nothing.
	if (!IsOwnerActorAuthoritative())
	{
		return EAethelnActivationResult::ConnectionClosed;
	}

	// The ordinal correlates every movement outcome, the rate-limited one included; it never wraps to 0.
	const uint32 Ordinal = MovementActivationOrdinal < MAX_uint32 ? ++MovementActivationOrdinal : MovementActivationOrdinal;

	// 1. The connection's shared bucket, before any lookup.
	if (!AdmitMessage(EMessageRoute::Movement, Ordinal, Request.ClientTimeStamp))
	{
		return EAethelnActivationResult::RateLimited;
	}

	FRequestScope RequestScope;
	RequestScope.Previous = ActiveRequestScope;
	RequestScope.Owner = GetOwner();
	RequestScope.Avatar = GetAvatarActor();
	const APlayerState* RequestOwner = Cast<APlayerState>(GetOwner());
	RequestScope.Controller = RequestOwner != nullptr ? RequestOwner->GetOwningController() : nullptr;
	TGuardValue<FRequestScope*> RequestGuard(ActiveRequestScope, &RequestScope);
	const UWorld* World = GetWorld();
	const double Now = World != nullptr ? World->GetTimeSeconds() : 0.0;
	ApplyDueBoundaries(Now);

	FAethelnActivationValidationState State;
	FillLifecycleState(State, RequestScope);
	// Only the current possessed avatar's own received move may ask.
	State.bHasPossessedAvatar = State.bHasPossessedAvatar && Request.Avatar != nullptr && Request.Avatar == GetAvatarActor();
	State.NowSeconds = Now;
	const FGameplayAbilitySpec* Spec = nullptr;
	const UAethelnDodgeAbility* Source = FindDodgeSource(Spec);
	if (Source != nullptr)
	{
		const UAethelnGameplayAbility* Instance = Cast<UAethelnGameplayAbility>(Spec->GetPrimaryInstance());
		State.bAbilityGranted = true;
		State.bMovementCarried = Source->IsMovementCarried();
		State.GrantedContentVersion = Source->ContentVersion;
		State.bAbilityActive = Spec->IsActive() || (Instance != nullptr && Instance->IsActive());
	}

	// 2 to 7.
	bool bAbilityResolved = false;
	const EAethelnActivationResult Validation = ValidateMovementRequest(Request.ContentVersion, Request.bMovementAllowsStart, State, bAbilityResolved);
	const FGameplayTag ResolvedAbilityId = bAbilityResolved ? Source->GetAbilityId() : FGameplayTag();
	if (Validation != EAethelnActivationResult::Accepted)
	{
		return FinishMovement(Request.ClientTimeStamp, Ordinal, Validation, ResolvedAbilityId, FGuid());
	}

	// 8. Same eligibility and precedence as the ordinary seam.
	const FGameplayAbilitySpecHandle Handle = Spec->Handle;
	const EAethelnActivationResult Eligibility = CheckEligibility(*Source, Handle);
	if (Eligibility != EAethelnActivationResult::Accepted)
	{
		return FinishMovement(Request.ClientTimeStamp, Ordinal, Eligibility, ResolvedAbilityId, FGuid());
	}

	// 9. Activate inside a seam scope for the dodge's spec only; S is this processing time.
	FSeamScope Scope;
	Scope.Handle = Handle;
	Scope.bMovementCarried = true;
	Scope.ActivationId = FGuid::NewGuid();
	Scope.AttackInput.ContentVersion = Request.ContentVersion;
	Scope.AttackInput.ReceiptServerTime = Now;
	bool bActivated = false;
	{
		TGuardValue<FSeamScope*> ScopeGuard(ActiveSeamScope, &Scope);
		bActivated = TryActivateAbility(Handle, false);
	}
	if (!bActivated)
	{
		return FinishMovement(Request.ClientTimeStamp, Ordinal, EAethelnActivationResult::ActivationBlocked, ResolvedAbilityId, FGuid());
	}
	if (!Scope.bCommitted || Scope.bCanceled || !DodgeWindow.bOpen || DodgeWindow.OperationId != Scope.ActivationId)
	{
		CancelUncommittedActivation(Handle, Scope.ActivationId);
		return FinishMovement(Request.ClientTimeStamp, Ordinal, EAethelnActivationResult::InternalFailure, ResolvedAbilityId, Scope.bCommitted ? Scope.ActivationId : FGuid());
	}

	// 10. No ordinary sequence, aim or client time advances.
	return FinishMovement(Request.ClientTimeStamp, Ordinal, EAethelnActivationResult::Accepted, ResolvedAbilityId, Scope.ActivationId);
}

EAethelnActivationResult UAethelnAbilitySystemComponent::FinishMovement(
	float ClientTimeStamp,
	uint32 Ordinal,
	EAethelnActivationResult Result,
	const FGameplayTag& ResolvedAbilityId,
	const FGuid& ActivationId)
{
	AethelnActivationTelemetry::EmitOutcome(*this, Result, Ordinal, ResolvedAbilityId, ActivationId, EAethelnObservabilityCategory::Dodge);
	ClientMovementActivationOutcome(ClientTimeStamp, Result);
	return Result;
}

void UAethelnAbilitySystemComponent::ClientMovementActivationOutcome_Implementation(float ClientTimeStamp, EAethelnActivationResult Result)
{
	OnMovementActivationOutcome.Broadcast(ClientTimeStamp, Result);
}

void UAethelnAbilitySystemComponent::FillLifecycleState(FAethelnActivationValidationState& State, const FRequestScope& RequestScope) const
{
	AActor* Avatar = GetAvatarActor();
	const APawn* AvatarPawn = Cast<APawn>(Avatar);
	const APlayerState* PlayerState = Cast<APlayerState>(GetOwner());
	const AController* Controller = PlayerState != nullptr ? PlayerState->GetOwningController() : nullptr;
	State.bAvatarBeingDestroyed = Avatar != nullptr && Avatar->IsActorBeingDestroyed();
	State.bHasPossessedAvatar = AvatarPawn != nullptr
		&& PlayerState != nullptr
		&& PlayerState->GetPawn() == AvatarPawn
		&& Controller != nullptr
		&& AvatarPawn->GetController() == Controller
		&& RequestScope.Owner.Get() == GetOwner() && RequestScope.Avatar.Get() == Avatar
		&& RequestScope.Controller.Get() == Controller;
}

EAethelnActivationResult UAethelnAbilitySystemComponent::CheckEligibility(const UGameplayAbility& Source, FGameplayAbilitySpecHandle Handle) const
{
	const FGameplayAbilityActorInfo* ActorInfo = AbilityActorInfo.Get();
	if (!Source.CheckCooldown(Handle, ActorInfo))
	{
		return EAethelnActivationResult::OnCooldown;
	}
	if (!Source.CheckCost(Handle, ActorInfo))
	{
		return EAethelnActivationResult::InsufficientResource;
	}
	if (!Source.DoesAbilitySatisfyTagRequirements(*this))
	{
		return EAethelnActivationResult::ActivationBlocked;
	}
	return EAethelnActivationResult::Accepted;
}

void UAethelnAbilitySystemComponent::CancelUncommittedActivation(FGameplayAbilitySpecHandle Handle, const FGuid& OperationId)
{
	// Fail closed: an activation that did not commit must not keep running or holding its state tags.
	const FGameplayAbilitySpec* ActivatedSpec = FindAbilitySpecFromHandle(Handle);
	const UAethelnGameplayAbility* ActivatedInstance = ActivatedSpec != nullptr ? Cast<UAethelnGameplayAbility>(ActivatedSpec->GetPrimaryInstance()) : nullptr;
	// Synchronous end/tag callbacks may have accepted a new activation on this same handle.
	const bool bOwnsCurrentActivation = ActivatedInstance == nullptr || ActivatedInstance->ActivationOperationId == OperationId;
	if (ActivatedSpec != nullptr && ActivatedSpec->IsActive() && bOwnsCurrentActivation)
	{
		CancelAbilityHandle(Handle);
	}
}

const FGameplayAbilitySpec* UAethelnAbilitySystemComponent::FindMovementCarriedSpec() const
{
	for (const FGameplayAbilitySpec& Spec : GetActivatableAbilities())
	{
		const UAethelnGameplayAbility* Ability = Cast<UAethelnGameplayAbility>(Spec.Ability);
		if (Ability != nullptr && !Spec.PendingRemove && Ability->IsMovementCarried())
		{
			return &Spec;
		}
	}
	return nullptr;
}

const UAethelnDodgeAbility* UAethelnAbilitySystemComponent::FindDodgeSource(const FGameplayAbilitySpec*& OutSpec) const
{
	OutSpec = FindMovementCarriedSpec();
	if (OutSpec == nullptr)
	{
		return nullptr;
	}
	// ServerOnly abilities have no client instance; the owner reads the granted definition.
	const UGameplayAbility* Source = OutSpec->GetPrimaryInstance() != nullptr ? OutSpec->GetPrimaryInstance() : OutSpec->Ability.Get();
	return Cast<UAethelnDodgeAbility>(Source);
}

FAethelnDodgeMovementDefinition UAethelnAbilitySystemComponent::GetDodgeMovementDefinition() const
{
	const FGameplayAbilitySpec* Spec = nullptr;
	const UAethelnDodgeAbility* Dodge = FindDodgeSource(Spec);
	FAethelnDodgeMovementDefinition Definition;
	// An invalid definition is never granted; refuse here too if an instance was changed after grant.
	if (Dodge != nullptr && Dodge->FindGrantProblem() == nullptr)
	{
		Definition.Distance = Dodge->ProvisionalDodge.Distance;
		Definition.MoveDuration = Dodge->ProvisionalDodge.MoveDuration;
		Definition.ContentVersion = Dodge->ContentVersion;
	}
	return Definition;
}

bool UAethelnAbilitySystemComponent::CanPredictDodge() const
{
	// ponytail: the commitment-window check from the owner's ClientCombatActivation record is P5 (D26).
	const FGameplayAbilitySpec* Spec = nullptr;
	const UAethelnDodgeAbility* Dodge = FindDodgeSource(Spec);
	return Dodge != nullptr && GetDodgeMovementDefinition().IsValid()
		&& !HasMatchingGameplayTag(AethelnGameplayTags::State_Dodging)
		&& CheckEligibility(*Dodge, Spec->Handle) == EAethelnActivationResult::Accepted;
}

bool UAethelnAbilitySystemComponent::IsAvoidingAt(double ContactTime) const
{
	return FMath::IsFinite(ContactTime) && DodgeWindow.InvulnerableStart <= ContactTime && ContactTime < DodgeWindow.InvulnerableEnd;
}

void UAethelnAbilitySystemComponent::ApplyDueBoundaries(double Now)
{
	ApplyChainBoundaries(Now);
	ApplyDodgeBoundaries(Now);
}

bool UAethelnAbilitySystemComponent::HasPendingBoundaries() const
{
	return ChainState.bExists || DodgeWindow.bOpen;
}

bool UAethelnAbilitySystemComponent::OpenDodgeWindow(const UAethelnDodgeAbility& Ability, FGameplayAbilitySpecHandle Handle)
{
	UAethelnCombatTimelineSubsystem* Timeline = GetCombatTimeline();
	// One window per ASC: the instance gate makes an open one unreachable, so fail closed if it exists.
	if (!IsSeamActivating(Handle) || !ActiveSeamScope->bMovementCarried || !ActiveSeamScope->bCommitted || ActiveSeamScope->bCanceled
		|| Ability.ActivationOperationId != ActiveSeamScope->ActivationId || DodgeWindow.bOpen
		|| Timeline == nullptr || !Timeline->RegisterNonChainBoundaries(*this)) { return false; }
	const FGuid OperationId = ActiveSeamScope->ActivationId;
	const double Start = ActiveSeamScope->AttackInput.ReceiptServerTime;
	const FAethelnDodgeDefinition& Definition = Ability.ProvisionalDodge;
	DodgeWindow = FAethelnServerDodgeWindow();
	DodgeWindow.bOpen = true;
	DodgeWindow.OperationId = OperationId;
	DodgeWindow.Handle = Handle;
	DodgeWindow.Avatar = Ability.ActivationActorInfo.AvatarActor;
	DodgeWindow.StartTime = Start;
	DodgeWindow.InvulnerableStart = Start + Definition.InvulnerableStart;
	DodgeWindow.InvulnerableEnd = Start + Definition.InvulnerableEnd;
	DodgeWindow.ActionEnd = Start + Definition.ActionEnd;
	DodgeDeadHandle = RegisterGameplayTagEvent(AethelnGameplayTags::State_Dead, EGameplayTagEventType::NewOrRemoved)
		.AddUObject(this, &UAethelnAbilitySystemComponent::HandleDodgeDeadTag);
	DodgeWindow.bDodgingTag = true;
	AddLooseGameplayTag(AethelnGameplayTags::State_Dodging, 1, EGameplayTagReplicationState::TagOnly);
	ApplyDodgeBoundaries(Start);
	// Tag callbacks may have cancelled or replaced the operation; only a still-open own window is ready.
	return DodgeWindow.bOpen && DodgeWindow.OperationId == OperationId && !HasMatchingGameplayTag(AethelnGameplayTags::State_Dead);
}

void UAethelnAbilitySystemComponent::ApplyDodgeBoundaries(double Now)
{
	if (!IsOwnerActorAuthoritative() || !DodgeWindow.bOpen || !FMath::IsFinite(Now)) { return; }
	const FGuid OperationId = DodgeWindow.OperationId;
	if (!DodgeWindow.bInvulnerableTag && Now >= DodgeWindow.InvulnerableStart && Now < DodgeWindow.InvulnerableEnd)
	{
		DodgeWindow.bInvulnerableTag = true;
		AddLooseGameplayTag(AethelnGameplayTags::State_DodgeInvulnerable, 1, EGameplayTagReplicationState::TagOnly);
	}
	// Tag callbacks may close or replace the window. Never touch a replacement.
	if (!DodgeWindow.bOpen || DodgeWindow.OperationId != OperationId) { return; }
	if (DodgeWindow.bInvulnerableTag && Now >= DodgeWindow.InvulnerableEnd)
	{
		DodgeWindow.bInvulnerableTag = false;
		RemoveLooseGameplayTag(AethelnGameplayTags::State_DodgeInvulnerable, 1, EGameplayTagReplicationState::TagOnly);
	}
	if (!DodgeWindow.bOpen || DodgeWindow.OperationId != OperationId || Now < DodgeWindow.ActionEnd) { return; }
	// The normal end at ActionEnd. It never touches displacement, which runs in client move time.
	const FGameplayAbilitySpec* Spec = FindAbilitySpecFromHandle(DodgeWindow.Handle);
	UAethelnDodgeAbility* Instance = Spec != nullptr ? Cast<UAethelnDodgeAbility>(Spec->GetPrimaryInstance()) : nullptr;
	if (Instance != nullptr && Instance->ActivationOperationId == OperationId) { Instance->EndAtActionEnd(); }
	CloseDodgeWindow(OperationId, DodgeWindow.ActionEnd, false);
}

void UAethelnAbilitySystemComponent::CloseDodgeWindow(const FGuid& OperationId, double EndTime, bool bEndDisplacement)
{
	if (!DodgeWindow.bOpen || DodgeWindow.OperationId != OperationId || !OperationId.IsValid()) { return; }
	const FAethelnServerDodgeWindow Previous = DodgeWindow;
	// Idempotence before tag callbacks re-enter; the truncated window keeps IsAvoidingAt exact.
	DodgeWindow.bOpen = false;
	DodgeWindow.bDodgingTag = false;
	DodgeWindow.bInvulnerableTag = false;
	if (FMath::IsFinite(EndTime))
	{
		DodgeWindow.InvulnerableEnd = FMath::Min(DodgeWindow.InvulnerableEnd, EndTime);
		DodgeWindow.ActionEnd = FMath::Min(DodgeWindow.ActionEnd, EndTime);
	}
	RegisterGameplayTagEvent(AethelnGameplayTags::State_Dead, EGameplayTagEventType::NewOrRemoved).Remove(DodgeDeadHandle);
	DodgeDeadHandle.Reset();
	if (Previous.bDodgingTag) { RemoveLooseGameplayTag(AethelnGameplayTags::State_Dodging, 1, EGameplayTagReplicationState::TagOnly); }
	if (Previous.bInvulnerableTag) { RemoveLooseGameplayTag(AethelnGameplayTags::State_DodgeInvulnerable, 1, EGameplayTagReplicationState::TagOnly); }
	if (bEndDisplacement)
	{
		const ACharacter* Character = Cast<ACharacter>(Previous.Avatar.Get());
		if (UAethelnCharacterMovementComponent* Movement = Character != nullptr ? Cast<UAethelnCharacterMovementComponent>(Character->GetCharacterMovement()) : nullptr)
		{
			Movement->EndDodgeForAuthority();
		}
	}
}

void UAethelnAbilitySystemComponent::HandleDodgeDeadTag(const FGameplayTag Tag, int32 NewCount)
{
	if (NewCount > 0) { CancelDodge(); }
}

void UAethelnAbilitySystemComponent::CancelDodge()
{
	if (!IsOwnerActorAuthoritative() || !DodgeWindow.bOpen) { return; }
	const FGuid OperationId = DodgeWindow.OperationId;
	const FGameplayAbilitySpec* Spec = FindAbilitySpecFromHandle(DodgeWindow.Handle);
	const UAethelnGameplayAbility* Instance = Spec != nullptr ? Cast<UAethelnGameplayAbility>(Spec->GetPrimaryInstance()) : nullptr;
	if (IsSeamActivating(DodgeWindow.Handle) && ActiveSeamScope->ActivationId == OperationId)
	{
		ActiveSeamScope->bCanceled = true;
	}
	// The cancel path closes the windows at this time and ends the server displacement once.
	if (Spec != nullptr && Spec->IsActive() && Instance != nullptr && Instance->ActivationOperationId == OperationId)
	{
		CancelAbilityHandle(DodgeWindow.Handle);
	}
	const UWorld* World = GetWorld();
	CloseDodgeWindow(OperationId, World != nullptr ? World->GetTimeSeconds() : 0.0, true);
}

bool UAethelnAbilitySystemComponent::AdmitMessage(EMessageRoute Route, uint32 Sequence, float ClientTimeStamp)
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

	// Entering the one shared window: one event (dropped for a zero sequence), one metric, and the
	// entering route's own outcome. A stock route gets no reply; a movement entry uses its ordinal.
	bRateLimited = true;
	SuppressedMessageCount = 0;
	const bool bMovement = Route == EMessageRoute::Movement;
	AethelnActivationTelemetry::EmitOutcome(*this, EAethelnActivationResult::RateLimited, Sequence, FGameplayTag(), FGuid(),
		bMovement ? EAethelnObservabilityCategory::Dodge : EAethelnObservabilityCategory::Ability);
	if (Route == EMessageRoute::Seam)
	{
		ClientActivationOutcome(Sequence, EAethelnActivationResult::RateLimited);
	}
	else if (bMovement)
	{
		ClientMovementActivationOutcome(ClientTimeStamp, EAethelnActivationResult::RateLimited);
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
	if (AdmitMessage(EMessageRoute::Stock, 0))
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
	ResetChain(EAethelnChainEndReason::AvatarLost);
	CancelDodge();
	UnbindChainResetTags();
	// A window ends only when a message is admitted, so teardown flushes it.
	CloseRateLimitedWindow();
	Super::OnUnregister();
}

void UAethelnAbilitySystemComponent::EndPlay(const EEndPlayReason::Type EndPlayReason)
{
	ResetChain(EAethelnChainEndReason::AvatarLost);
	CancelDodge();
	Super::EndPlay(EndPlayReason);
}

bool UAethelnAbilitySystemComponent::IsSeamActivating(FGameplayAbilitySpecHandle Handle) const
{
	return ActiveSeamScope != nullptr && ActiveSeamScope->Handle == Handle;
}

void UAethelnAbilitySystemComponent::RecordSeamCommit(FGameplayAbilitySpecHandle Handle, bool bCommitted, const FGuid& ActivationId)
{
	if (IsSeamActivating(Handle) && ActiveSeamScope->ActivationId == ActivationId)
	{
		ActiveSeamScope->bCommitted = bCommitted;
		ActiveSeamScope->AttackInput.ActivationId = ActivationId;
		const FGameplayAbilitySpec* Spec = FindAbilitySpecFromHandle(Handle);
		const UAethelnGameplayAbility* Instance = Spec != nullptr ? Cast<UAethelnGameplayAbility>(Spec->GetPrimaryInstance()) : nullptr;
		if (bCommitted && !ActiveSeamScope->bCanceled && Spec != nullptr && Instance != nullptr
			&& Instance->ActivationOperationId == ActivationId && Cast<UAethelnBasicChainAbility>(Spec->Ability) == nullptr)
		{
			// PreActivate is too early: a failed other commit must not reset recovery.
			ResetChain(EAethelnChainEndReason::OtherAction);
		}
	}
}

UAethelnCombatTimelineSubsystem* UAethelnAbilitySystemComponent::GetCombatTimeline() const
{
	UWorld* World = GetWorld();
	return World != nullptr && World->GetNetMode() != NM_Client ? World->GetSubsystem<UAethelnCombatTimelineSubsystem>() : nullptr;
}

bool UAethelnAbilitySystemComponent::BeginChainPress(UAethelnBasicChainAbility& Ability, FGameplayAbilitySpecHandle Handle)
{
	if (!IsOwnerActorAuthoritative() || !IsSeamActivating(Handle) || !ActiveSeamScope->bCommitted || ActiveSeamScope->bCanceled
		|| Ability.ActivationOperationId != ActiveSeamScope->ActivationId || !Ability.HasActivationLifecycle()
		|| !ActiveSeamScope->AttackInput.ActivationId.IsValid() || GetAvatarActor() == nullptr) { return false; }
	const FAethelnAcceptedAttackInput Input = ActiveSeamScope->AttackInput;
	if (ChainState.bExists && ChainState.Handle != Handle) { ResetChain(EAethelnChainEndReason::OtherAction, Input.ReceiptServerTime); }
	if (Ability.ActivationOperationId != Input.ActivationId || ActiveSeamScope->bCanceled || !Ability.HasActivationLifecycle()) { return false; }
	if (!ChainState.bExists)
	{
		ChainState.bExists = true;
		ChainState.Handle = Handle;
		ChainState.Ability = &Ability;
		ChainState.Definitions = Ability.ProvisionalSteps; // immutable for this chain
		BindChainResetTags(Ability.ResetTags);
		ActiveSeamScope->bChainReady = StartChainStep(Input, 1, Input.ReceiptServerTime);
		if (!ActiveSeamScope->bChainReady && ChainState.bExists && ChainState.Handle == Handle
			&& ChainState.Ability.Get() == &Ability && ChainState.Step == 0 && !ChainState.CurrentInput.ActivationId.IsValid())
		{
			// Nothing registered or started. Do not leave a step-zero recovery state.
			UnbindChainResetTags();
			ChainState = FAethelnServerChainState();
		}
		return ActiveSeamScope->bChainReady;
	}
	if (ChainState.bWaiting || ChainState.Step >= 3) { return false; }
	const FAethelnAttackStepDefinition& Previous = ChainState.Definitions[ChainState.Step - 1];
	const double LinkOpen = ChainState.StartTime + Previous.LinkOpen;
	if (Input.ReceiptServerTime < LinkOpen)
	{
		ChainState.bWaiting = true;
		ChainState.BufferedStartTime = LinkOpen;
		ChainState.BufferedInput = Input; // accepted/corrected press snapshot, never later controller aim
		ActiveSeamScope->bChainReady = true;
		return true;
	}
	ActiveSeamScope->bChainReady = StartChainStep(Input, ChainState.Step + 1, Input.ReceiptServerTime);
	return ActiveSeamScope->bChainReady;
}

bool UAethelnAbilitySystemComponent::StartChainStep(const FAethelnAcceptedAttackInput& Input, uint8 Step, double StartTime)
{
	UAethelnCombatTimelineSubsystem* Timeline = GetCombatTimeline();
	UAethelnBasicChainAbility* Ability = ChainState.Ability.Get();
	AActor* Avatar = GetAvatarActor();
	if (!ChainState.bExists || Ability == nullptr || Timeline == nullptr || Avatar == nullptr || Avatar->IsActorBeingDestroyed()
		|| Step < 1 || Step > ChainState.Definitions.Num() || !FMath::IsFinite(StartTime)) { return false; }
	// Tag delegates can synchronously reset or replace the chain and free its definitions.
	const FAethelnAttackStepDefinition Definition = ChainState.Definitions[Step - 1];
	const FAethelnServerChainState Previous = ChainState;
	FAethelnCombatActivationRecord Record;
	Record.ActivationId = Input.ActivationId; Record.Sequence = Input.Sequence;
	Record.AbilityId = Ability->GetAbilityId(); Record.ContentVersion = Input.ContentVersion;
	Record.ChainStep = Step; Record.StartServerTime = StartTime;
	Record.AcceptedAim = Input.AcceptedAim; Record.AimCorrection = Input.AimCorrection;
	Record.CapsuleOrigin = Avatar->GetActorLocation();
	Record.Windows.ActiveStart = Definition.ActiveStart; Record.Windows.ActiveEnd = Definition.ActiveEnd;
	Record.Windows.BufferOpen = Definition.BufferOpen; Record.Windows.LinkOpen = Definition.LinkOpen;
	Record.Windows.LinkClose = Definition.LinkClose; Record.Windows.RecoveryEnd = Definition.RecoveryEnd;
	Record.Windows.CancelOpen = Definition.CancelOpen;
	if (!Timeline->RegisterStep(*this, Definition, Record)) { return false; }
	if (ChainState.CurrentInput.ActivationId.IsValid()) { Timeline->StampReset(ChainState.CurrentInput.ActivationId, StartTime); }
	if (ChainState.bCommitmentHeld)
	{
		ChainState.bCommitmentHeld = false;
		RemoveLooseGameplayTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain);
	}
	if (!ChainState.bExists || ChainState.Handle != Previous.Handle || ChainState.Ability.Get() != Ability
		|| ChainState.Step != Previous.Step || ChainState.CurrentInput.ActivationId != Previous.CurrentInput.ActivationId
		|| ChainState.bWaiting != Previous.bWaiting || ChainState.BufferedInput.ActivationId != Previous.BufferedInput.ActivationId)
	{
		// ResetChain could only stamp the previous current input before this transition.
		Timeline->StampReset(Record.ActivationId, LastChainResetTime);
		return false;
	}
	ChainState.Step = Step; ChainState.StartTime = StartTime; ChainState.CurrentInput = Input;
	ChainState.bWaiting = false; ChainState.BufferedInput = FAethelnAcceptedAttackInput();
	ChainState.bCommitmentHeld = Definition.CancelOpen > 0.0;
	if (ChainState.bCommitmentHeld) { AddLooseGameplayTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain); }
	if (!ChainState.bExists || ChainState.Handle != Previous.Handle || ChainState.Ability.Get() != Ability
		|| ChainState.Step != Step || ChainState.CurrentInput.ActivationId != Input.ActivationId)
	{
		Timeline->StampReset(Record.ActivationId, LastChainResetTime);
		return false;
	}
	AttackPresentationState.bActive = true; AttackPresentationState.AbilityId = Record.AbilityId;
	AttackPresentationState.ContentVersion = Record.ContentVersion; AttackPresentationState.ChainStep = Step;
	AttackPresentationState.StartServerTime = StartTime; AttackPresentationState.AcceptedAim = Input.AcceptedAim;
	AttackPresentationState.ActivationCounter = ++AttackActivationCounter;
	AttackPresentationState.EndReason = EAethelnChainEndReason::None;
	ClientCombatActivation(Record);
	return true;
}

void UAethelnAbilitySystemComponent::StartBufferedChainStep(double Now)
{
	if (!IsOwnerActorAuthoritative() || !ChainState.bExists || !ChainState.bWaiting || Now < ChainState.BufferedStartTime) { return; }
	const auto Input = ChainState.BufferedInput;
	const double Start = ChainState.BufferedStartTime;
	const FGuid PreviousActivationId = ChainState.CurrentInput.ActivationId;
	const FGameplayAbilitySpecHandle Handle = ChainState.Handle;
	if (!StartChainStep(Input, ChainState.Step + 1, Start) && ChainState.bExists && ChainState.Handle == Handle
		&& ChainState.bWaiting && ChainState.CurrentInput.ActivationId == PreviousActivationId
		&& ChainState.BufferedInput.ActivationId == Input.ActivationId)
	{
		// A callback's reset/replacement owns its reason and state; only registration failure remains ours.
		ResetChain(EAethelnChainEndReason::AvatarLost);
	}
}

void UAethelnAbilitySystemComponent::ApplyChainBoundaries(double Now)
{
	if (!IsOwnerActorAuthoritative() || !ChainState.bExists || !FMath::IsFinite(Now)) { return; }
	StartBufferedChainStep(Now);
	if (!ChainState.bExists) { return; }
	const FAethelnAttackStepDefinition Step = ChainState.Definitions[ChainState.Step - 1];
	const FGuid ActivationId = ChainState.CurrentInput.ActivationId;
	if (ChainState.bCommitmentHeld && Now >= ChainState.StartTime + Step.CancelOpen)
	{
		ChainState.bCommitmentHeld = false;
		RemoveLooseGameplayTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain);
	}
	if (!ChainState.bExists || ChainState.CurrentInput.ActivationId != ActivationId) { return; }
	if (!ChainState.bWaiting && Now >= ChainState.StartTime + Step.BufferOpen)
	{
		if (UAethelnBasicChainAbility* Ability = ChainState.Ability.Get()) { Ability->EndAtBufferOpen(); }
	}
	// GAS end delegates may reset or replace this chain. Do not touch their state.
	if (!ChainState.bExists || ChainState.CurrentInput.ActivationId != ActivationId) { return; }
	if (ChainState.Step == 3 && Now >= ChainState.StartTime + Step.RecoveryEnd)
	{
		ResetChain(EAethelnChainEndReason::Completed, ChainState.StartTime + Step.RecoveryEnd);
	}
	else if (ChainState.Step < 3 && !ChainState.bWaiting && Now >= ChainState.StartTime + Step.LinkClose)
	{
		ResetChain(EAethelnChainEndReason::Timeout, ChainState.StartTime + Step.LinkClose);
	}
}

void UAethelnAbilitySystemComponent::ResetChain(EAethelnChainEndReason Reason)
{
	const UWorld* World = GetWorld();
	ResetChain(Reason, World != nullptr ? World->GetTimeSeconds() : 0.0);
}

void UAethelnAbilitySystemComponent::ResetChain(EAethelnChainEndReason Reason, double ResetTime)
{
	if (!IsOwnerActorAuthoritative() || !ChainState.bExists || !FMath::IsFinite(ResetTime) || Reason == EAethelnChainEndReason::None) { return; }
	const FAethelnServerChainState Previous = ChainState;
	const FGameplayAbilitySpec* OriginalSpec = FindAbilitySpecFromHandle(Previous.Handle);
	const UAethelnGameplayAbility* OriginalInstance = OriginalSpec != nullptr ? Cast<UAethelnGameplayAbility>(OriginalSpec->GetPrimaryInstance()) : nullptr;
	const FGuid OriginalActiveOperation = OriginalSpec != nullptr && OriginalSpec->IsActive() && OriginalInstance != nullptr
		&& OriginalInstance->IsActive() ? OriginalInstance->ActivationOperationId : FGuid();
	if (OriginalInstance != nullptr && IsSeamActivating(Previous.Handle) && ActiveSeamScope->ActivationId == OriginalInstance->ActivationOperationId)
	{
		ActiveSeamScope->bCanceled = true;
	}
	ChainState = FAethelnServerChainState(); // idempotence before GAS/tag callbacks re-enter
	LastChainResetTime = ResetTime;
	AttackPresentationState = FAethelnAttackPresentationState();
	AttackPresentationState.ActivationCounter = AttackActivationCounter;
	AttackPresentationState.EndReason = Reason;
	if (UAethelnCombatTimelineSubsystem* Timeline = GetCombatTimeline()) { Timeline->StampReset(Previous.CurrentInput.ActivationId, ResetTime); }
	UnbindChainResetTags();
	if (Previous.bCommitmentHeld) { RemoveLooseGameplayTag(AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain); }
	const FGameplayAbilitySpec* CurrentSpec = FindAbilitySpecFromHandle(Previous.Handle);
	const UAethelnGameplayAbility* CurrentInstance = CurrentSpec != nullptr ? Cast<UAethelnGameplayAbility>(CurrentSpec->GetPrimaryInstance()) : nullptr;
	if (OriginalActiveOperation.IsValid() && CurrentSpec != nullptr && CurrentSpec->IsActive() && CurrentInstance != nullptr
		&& CurrentInstance->ActivationOperationId == OriginalActiveOperation)
	{
		CancelAbilityHandle(Previous.Handle);
	}
	ClientChainEnded(Previous.bWaiting ? Previous.BufferedInput.ActivationId : Previous.CurrentInput.ActivationId, Reason);
}

void UAethelnAbilitySystemComponent::BindChainResetTags(const FGameplayTagContainer& Tags)
{
	UnbindChainResetTags();
	for (const FGameplayTag Tag : Tags)
	{
		ChainResetHandles.Emplace(Tag, RegisterGameplayTagEvent(Tag, EGameplayTagEventType::NewOrRemoved).AddUObject(this, &UAethelnAbilitySystemComponent::HandleChainResetTag));
	}
}

void UAethelnAbilitySystemComponent::UnbindChainResetTags()
{
	for (const auto& Entry : ChainResetHandles) { RegisterGameplayTagEvent(Entry.Key, EGameplayTagEventType::NewOrRemoved).Remove(Entry.Value); }
	ChainResetHandles.Reset();
}

void UAethelnAbilitySystemComponent::HandleChainResetTag(const FGameplayTag Tag, int32 NewCount)
{
	if (NewCount > 0) { ResetChain(EAethelnChainEndReason::IncompatibleState); }
}

void UAethelnAbilitySystemComponent::ClientCombatActivation_Implementation(const FAethelnCombatActivationRecord& Record)
{
	OnCombatActivation.Broadcast(Record);
}

void UAethelnAbilitySystemComponent::ClientChainEnded_Implementation(const FGuid& ActivationId, EAethelnChainEndReason Reason)
{
	OnChainEnded.Broadcast(ActivationId, Reason);
}

void UAethelnAbilitySystemComponent::GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const
{
	Super::GetLifetimeReplicatedProps(OutLifetimeProps);
	DOREPLIFETIME_CONDITION(UAethelnAbilitySystemComponent, AttackPresentationState, COND_SkipOwner);
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
