#include "AethelnEnemyController.h"

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatEffects.h"
#include "AethelnCombatTimelineSubsystem.h"
#include "AethelnEnemyAttackAbility.h"
#include "Engine/World.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "GameFramework/PlayerController.h"
#include "GameFramework/PlayerState.h"
#include "Navigation/PathFollowingComponent.h"

AAethelnEnemyController::AAethelnEnemyController(const FObjectInitializer& ObjectInitializer)
	: Super(ObjectInitializer)
{
	// FindForPawn must resolve the enemy pawn's own ASC (#19 P2 note on #20).
	bWantsPlayerState = false;
}

void AAethelnEnemyController::OnPossess(APawn* InPawn)
{
	Super::OnPossess(InPawn);
	Unbind();
	// Every decision runs inside the timeline pass; a client world has no subsystem and so no decisions.
	if (UAethelnCombatTimelineSubsystem* Timeline = GetTimeline())
	{
		PassStartHandle = Timeline->OnPassStart.AddUObject(this, &AAethelnEnemyController::Advance);
		PassEndHandle = Timeline->OnPassEnd.AddUObject(this, &AAethelnEnemyController::HandlePassEnd);
		InterruptHandle = Timeline->OnTargetInterrupted.AddUObject(this, &AAethelnEnemyController::HandleTargetInterrupted);
		LethalHandle = Timeline->OnLethalResult.AddUObject(this, &AAethelnEnemyController::HandleLethalResult);
		BoundTimeline = Timeline;
	}
	const UWorld* World = GetWorld();
	Enter(EAethelnEnemyState::Idle, World != nullptr ? World->GetTimeSeconds() : 0.0);
}

void AAethelnEnemyController::OnUnPossess()
{
	Unbind();
	Target.Reset();
	Super::OnUnPossess();
}

void AAethelnEnemyController::EndPlay(const EEndPlayReason::Type EndPlayReason)
{
	Unbind();
	Super::EndPlay(EndPlayReason);
}

void AAethelnEnemyController::Unbind()
{
	if (UAethelnCombatTimelineSubsystem* Timeline = BoundTimeline.Get())
	{
		Timeline->OnPassStart.Remove(PassStartHandle);
		Timeline->OnPassEnd.Remove(PassEndHandle);
		Timeline->OnTargetInterrupted.Remove(InterruptHandle);
		Timeline->OnLethalResult.Remove(LethalHandle);
	}
	PassStartHandle.Reset(); PassEndHandle.Reset(); InterruptHandle.Reset(); LethalHandle.Reset();
	BoundTimeline.Reset();
}

void AAethelnEnemyController::Advance(double Now)
{
	if (GetEnemyAbilitySystem() == nullptr || !HasValidConfig()) { return; }
	if (PendingMoveResult.IsSet())
	{
		const EPathFollowingResult::Type Result = PendingMoveResult.GetValue();
		PendingMoveResult.Reset();
		ApplyMoveResult(Result, Now);
	}
	// Each transition starts its state at a time no later than Now; seven states bound the chain. A reset request
	// ends this pass's decisions: the reset waits for the pass end.
	for (int32 Guard = 0; Guard < 8 && !PendingResetTime.IsSet() && EvaluateOnce(Now); ++Guard) {}
}

bool AAethelnEnemyController::EvaluateOnce(double Now)
{
	AAethelnEnemyCharacter* Enemy = GetEnemy();
	UAethelnAbilitySystemComponent* AbilitySystem = GetEnemyAbilitySystem();
	if (Enemy == nullptr || AbilitySystem == nullptr) { return false; }
	if (State != EAethelnEnemyState::Dead && !UAethelnCombatTimelineSubsystem::IsAlive(*AbilitySystem))
	{
		// Not alive without a lethal result (for example an effect set Health to zero): death starts at this pass.
		StopMovement();
		bMoveRequested = false;
		Target.Reset();
		Enter(EAethelnEnemyState::Dead, Now);
		return true;
	}
	switch (State)
	{
	case EAethelnEnemyState::Dead:
		if (Now >= StateStartTime + ProvisionalRespawnSeconds) { RequestReset(StateStartTime + ProvisionalRespawnSeconds); }
		return false;
	case EAethelnEnemyState::Interrupted:
		if (Now >= StateStartTime + ProvisionalInterruptedSeconds) { Enter(EAethelnEnemyState::Engage, StateStartTime + ProvisionalInterruptedSeconds); return true; }
		return false;
	case EAethelnEnemyState::Attack:
		if (Now >= CurrentRecoveryEnd) { Enter(EAethelnEnemyState::Engage, CurrentRecoveryEnd); return true; }
		return false;
	case EAethelnEnemyState::Telegraph:
	{
		const APawn* Current = Target.Get();
		if (Current == nullptr || !IsEligible(*Current))
		{
			// No step was registered; the choice runs again in Engage.
			Target.Reset();
			Enter(EAethelnEnemyState::Engage, Now);
			return true;
		}
		const double StepStart = StateStartTime + ProvisionalTelegraphSeconds;
		if (Now < StepStart) { return false; }
		if (StartAttack(StepStart)) { Enter(EAethelnEnemyState::Attack, StepStart); }
		else { Enter(EAethelnEnemyState::Engage, StepStart); }
		return true;
	}
	case EAethelnEnemyState::Return:
		// A move request ends this pass's evaluation, so a failed path resets at most once per pass.
		if (!bMoveRequested) { IssueMoveRequest(Now); }
		return false;
	case EAethelnEnemyState::Idle:
	case EAethelnEnemyState::Engage:
	default:
	{
		APawn* Chosen = ChooseTarget();
		if (Chosen != Target.Get()) { bMoveRequested = false; }
		Target = Chosen;
		if (Chosen == nullptr)
		{
			if (State == EAethelnEnemyState::Engage) { BeginReturn(Now); return true; }
			return false;
		}
		if (IsInAttackRange(*Chosen) && FindAttack() != nullptr)
		{
			StopMovement();
			bMoveRequested = false;
			const FVector Toward = (Chosen->GetActorLocation() - Enemy->GetActorLocation()).GetSafeNormal2D();
			if (!Toward.IsNearlyZero()) { Enemy->SetActorRotation(FRotator(0.0, Toward.Rotation().Yaw, 0.0)); }
			Enter(EAethelnEnemyState::Telegraph, Now);
			return true;
		}
		if (State == EAethelnEnemyState::Idle) { Enter(EAethelnEnemyState::Engage, Now); return true; }
		// ponytail: an enemy whose every path request fails (no navigation under it) resets once per pass while a
		// target stays eligible; P3's navmesh evidence decides whether it needs a back-off.
		if (!bMoveRequested) { IssueMoveRequest(Now); }
		return false;
	}
	}
}

bool AAethelnEnemyController::IsEligible(const APawn& Candidate) const
{
	const AAethelnEnemyCharacter* Enemy = GetEnemy();
	const UAethelnAbilitySystemComponent* Own = GetEnemyAbilitySystem();
	const UAethelnAbilitySystemComponent* Other = UAethelnAbilitySystemComponent::FindForPawn(&Candidate);
	return Enemy != nullptr && Own != nullptr && Other != nullptr && !Candidate.IsActorBeingDestroyed()
		&& Cast<APlayerState>(Other->GetOwner()) != nullptr
		&& UAethelnCombatTimelineSubsystem::IsAlive(*Other)
		&& UAethelnCombatTimelineSubsystem::IsHostile(*Own, *Other)
		&& FVector::Dist(Candidate.GetActorLocation(), Enemy->GetActorLocation()) <= ProvisionalPerceptionRadius
		&& FVector::Dist(Candidate.GetActorLocation(), Enemy->GetHome().GetLocation()) <= ProvisionalLeashRadius;
}

APawn* AAethelnEnemyController::ChooseTarget() const
{
	APawn* Current = Target.Get();
	if (Current != nullptr && IsEligible(*Current)) { return Current; }
	const AAethelnEnemyCharacter* Enemy = GetEnemy();
	UWorld* World = GetWorld();
	if (Enemy == nullptr || World == nullptr) { return nullptr; }
	// Order-independent: nearest, then the lower PlayerId, so controller iteration order never decides.
	APawn* Best = nullptr;
	double BestDistanceSquared = 0.0;
	int32 BestPlayerId = 0;
	for (FConstPlayerControllerIterator Iterator = World->GetPlayerControllerIterator(); Iterator; ++Iterator)
	{
		const APlayerController* Player = Iterator->Get();
		APawn* Candidate = Player != nullptr ? Player->GetPawn() : nullptr;
		const APlayerState* CandidateState = Player != nullptr ? Player->GetPlayerState<APlayerState>() : nullptr;
		if (Candidate == nullptr || CandidateState == nullptr || !IsEligible(*Candidate)) { continue; }
		const double DistanceSquared = FVector::DistSquared(Candidate->GetActorLocation(), Enemy->GetActorLocation());
		const int32 PlayerId = CandidateState->GetPlayerId();
		if (Best == nullptr || DistanceSquared < BestDistanceSquared || (DistanceSquared == BestDistanceSquared && PlayerId < BestPlayerId))
		{
			Best = Candidate; BestDistanceSquared = DistanceSquared; BestPlayerId = PlayerId;
		}
	}
	return Best;
}

bool AAethelnEnemyController::IsInAttackRange(const APawn& Candidate) const
{
	const AAethelnEnemyCharacter* Enemy = GetEnemy();
	// 2D capsule-center distance, the measure of the engine's reach test with both radii excluded (IssueMoveRequest).
	return Enemy != nullptr && FVector::Dist2D(Candidate.GetActorLocation(), Enemy->GetActorLocation()) <= ProvisionalAttackRange;
}

const UAethelnEnemyAttackAbility* AAethelnEnemyController::FindAttack() const
{
	const UAethelnAbilitySystemComponent* AbilitySystem = GetEnemyAbilitySystem();
	if (AbilitySystem == nullptr) { return nullptr; }
	for (const FGameplayAbilitySpec& Spec : AbilitySystem->GetActivatableAbilities())
	{
		const UAethelnEnemyAttackAbility* Attack = Cast<UAethelnEnemyAttackAbility>(Spec.Ability);
		if (Attack != nullptr && Attack->FindGrantProblem() == nullptr) { return Attack; }
	}
	return nullptr;
}

bool AAethelnEnemyController::StartAttack(double StartTime)
{
	AAethelnEnemyCharacter* Enemy = GetEnemy();
	UAethelnAbilitySystemComponent* AbilitySystem = GetEnemyAbilitySystem();
	UAethelnCombatTimelineSubsystem* Timeline = GetTimeline();
	const UAethelnEnemyAttackAbility* Attack = FindAttack();
	const APawn* Current = Target.Get();
	if (Enemy == nullptr || AbilitySystem == nullptr || Timeline == nullptr || Attack == nullptr || Current == nullptr) { return false; }
	const FAethelnAttackStepDefinition& Step = Attack->ProvisionalStep;
	FAethelnCombatActivationRecord Record;
	Record.ActivationId = FGuid::NewGuid();
	Record.Sequence = NextSequence;
	Record.AbilityId = Attack->GetAbilityId();
	Record.ContentVersion = Attack->ContentVersion;
	Record.ChainStep = 1; // An enemy has no chain; the timeline accepts steps 1 to 3 only.
	Record.StartServerTime = StartTime;
	// Fixed for the step: from the enemy capsule to the target capsule at the step start.
	Record.AcceptedAim = (Current->GetActorLocation() - Enemy->GetActorLocation()).GetSafeNormal();
	Record.CapsuleOrigin = Enemy->GetActorLocation();
	Record.Windows.ActiveStart = Step.ActiveStart; Record.Windows.ActiveEnd = Step.ActiveEnd;
	Record.Windows.BufferOpen = Step.BufferOpen; Record.Windows.LinkOpen = Step.LinkOpen;
	Record.Windows.LinkClose = Step.LinkClose; Record.Windows.RecoveryEnd = Step.RecoveryEnd;
	Record.Windows.CancelOpen = Step.CancelOpen; Record.Windows.InterruptibleUntil = Step.InterruptibleUntil;
	if (FVector(Record.AcceptedAim).IsNearlyZero()
		|| !Timeline->RegisterStep(*AbilitySystem, Step, Record, Attack->ProvisionalMaxSampleDistance, Attack->ProvisionalMaxSampleAngleDegrees))
	{
		return false;
	}
	++NextSequence;
	CurrentActivationId = Record.ActivationId;
	CurrentStepStart = StartTime;
	CurrentRecoveryEnd = StartTime + Step.RecoveryEnd;
	FAethelnEnemyPresentationState Presentation = Enemy->GetPresentationState();
	Presentation.AbilityId = Record.AbilityId;
	Presentation.ContentVersion = Record.ContentVersion;
	Presentation.StepStartServerTime = StartTime;
	Presentation.AcceptedAim = Record.AcceptedAim;
	Presentation.AttackCounter = ++AttackCounter;
	Enemy->SetPresentationState(Presentation);
	return true;
}

void AAethelnEnemyController::Enter(EAethelnEnemyState NewState, double Time)
{
	if (State == EAethelnEnemyState::Attack)
	{
		// Every exit ends the step at its transition time (recovery end, death, or the interruption that already
		// stamped it). An unstamped step would stay registered and hold every later contact time (Interrupt's lookup).
		if (UAethelnCombatTimelineSubsystem* Timeline = GetTimeline()) { Timeline->StampReset(CurrentActivationId, Time); }
		CurrentActivationId.Invalidate();
	}
	State = NewState;
	StateStartTime = Time;
	if (AAethelnEnemyCharacter* Enemy = GetEnemy())
	{
		FAethelnEnemyPresentationState Presentation = Enemy->GetPresentationState();
		Presentation.State = NewState;
		Presentation.StateStartServerTime = Time;
		Enemy->SetPresentationState(Presentation);
	}
}

void AAethelnEnemyController::IssueMoveRequest(double Now)
{
	const AAethelnEnemyCharacter* Enemy = GetEnemy();
	if (Enemy == nullptr) { return; }
	bMoveRequested = true;
	FPathFollowingRequestResult Result;
	Result.Code = EPathFollowingRequestResult::Failed;
	if (State == EAethelnEnemyState::Engage && Target.IsValid())
	{
		// Partial paths allowed: an unreachable target still draws the enemy to the nearest reachable point. The reach
		// test excludes both capsule radii, so path following stops at the capsule-center distance IsInAttackRange uses.
		FAIMoveRequest Request(Target.Get());
		Request.SetUsePathfinding(true);
		Request.SetAllowPartialPath(true);
		Request.SetAcceptanceRadius(static_cast<float>(ProvisionalAttackRange));
		Request.SetReachTestIncludesAgentRadius(false);
		Request.SetReachTestIncludesGoalRadius(false);
		Request.SetCanStrafe(false);
		Result = MoveTo(Request);
		// Already in reach: the next pass re-checks range (and requests again if the target moved away).
		if (Result.Code == EPathFollowingRequestResult::AlreadyAtGoal) { bMoveRequested = false; }
	}
	else if (State == EAethelnEnemyState::Return)
	{
		FAIMoveRequest Request(Enemy->GetHome().GetLocation());
		Request.SetUsePathfinding(true);
		Request.SetAllowPartialPath(false);
		Request.SetProjectGoalLocation(false);
		Request.SetCanStrafe(false);
		Result = MoveTo(Request);
		if (Result.Code == EPathFollowingRequestResult::AlreadyAtGoal) { RequestReset(Now); return; }
	}
	// Only this request's completion is applied. MoveTo finishes an AlreadyAtGoal request, and a Failed one that reached
	// the path following component, inside the call (RequestMoveWithImmediateFinish broadcasts OnRequestFinished, which
	// calls OnMoveCompleted, with the new id). Storing the id only now drops that callback, so the return code handles
	// each result once: AlreadyAtGoal above, Failed below. Do not move this assignment.
	MoveRequestId = Result.MoveId;
	if (Result.Code != EPathFollowingRequestResult::Failed) { return; }
	// Invalid destination: Engage gives up the target and returns; Return resets home.
	if (State == EAethelnEnemyState::Engage) { Target.Reset(); BeginReturn(Now); }
	else { RequestReset(Now); }
}

void AAethelnEnemyController::BeginReturn(double Now)
{
	StopMovement();
	Target.Reset();
	Enter(EAethelnEnemyState::Return, Now);
	bMoveRequested = false;
	IssueMoveRequest(Now);
}

void AAethelnEnemyController::RequestReset(double Time)
{
	StopMovement();
	bMoveRequested = false;
	MoveRequestId = FAIRequestID::InvalidRequest;
	PendingMoveResult.Reset();
	Target.Reset();
	PendingResetTime = Time;
}

void AAethelnEnemyController::HandlePassEnd(double Now)
{
	if (!PendingResetTime.IsSet()) { return; }
	const double Time = PendingResetTime.GetValue();
	PendingResetTime.Reset();
	AAethelnEnemyCharacter* Enemy = GetEnemy();
	UAethelnAbilitySystemComponent* AbilitySystem = GetEnemyAbilitySystem();
	ConsecutiveMoveFailures = 0;
	if (Enemy != nullptr && AbilitySystem != nullptr)
	{
		Enemy->GetCharacterMovement()->StopMovementImmediately();
		Enemy->TeleportTo(Enemy->GetHome().GetLocation(), Enemy->GetHome().Rotator(), false, true);
		UAethelnAttributeInitEffect::ApplyTo(*AbilitySystem, Enemy->ProvisionalInitialAttributes);
	}
	Enter(EAethelnEnemyState::Idle, Time);
}

EAethelnEnemyMoveRecovery AAethelnEnemyController::DecideMoveRecovery(EPathFollowingResult::Type Result, int32 PreviousConsecutiveFailures)
{
	if (Result != EPathFollowingResult::Blocked && Result != EPathFollowingResult::OffPath) { return EAethelnEnemyMoveRecovery::None; }
	return PreviousConsecutiveFailures < 1 ? EAethelnEnemyMoveRecovery::Repath : EAethelnEnemyMoveRecovery::Reset;
}

void AAethelnEnemyController::OnMoveCompleted(FAIRequestID RequestID, const FPathFollowingResult& Result)
{
	Super::OnMoveCompleted(RequestID, Result);
	// Path following reports during the actor tick; decisions wait for the next pass start.
	if (MoveRequestId.IsValid() && RequestID.IsEquivalent(MoveRequestId)) { PendingMoveResult = Result.Code; }
}

void AAethelnEnemyController::ApplyMoveResult(EPathFollowingResult::Type Result, double Now)
{
	if (State != EAethelnEnemyState::Engage && State != EAethelnEnemyState::Return) { return; }
	if (Result == EPathFollowingResult::Success)
	{
		ConsecutiveMoveFailures = 0;
		bMoveRequested = false;
		if (State == EAethelnEnemyState::Return) { RequestReset(Now); }
		return;
	}
	const EAethelnEnemyMoveRecovery Recovery = DecideMoveRecovery(Result, ConsecutiveMoveFailures);
	if (Recovery == EAethelnEnemyMoveRecovery::Repath) { ++ConsecutiveMoveFailures; bMoveRequested = false; IssueMoveRequest(Now); }
	else if (Recovery == EAethelnEnemyMoveRecovery::Reset) { RequestReset(Now); }
}

void AAethelnEnemyController::HandleTargetInterrupted(UAethelnAbilitySystemComponent* TargetAbilitySystem, double ContactTime)
{
	// Raised during resolution. The timeline already stamped every enemy step at ContactTime, so whatever this
	// controller advanced to after ContactTime in pass step 1 (a later step included) never happened. Dead ignores it.
	if (TargetAbilitySystem == nullptr || TargetAbilitySystem != GetEnemyAbilitySystem() || State == EAethelnEnemyState::Dead) { return; }
	StopMovement();
	bMoveRequested = false;
	PendingResetTime.Reset(); // a late interruption cancels a reset decided after it
	Enter(EAethelnEnemyState::Interrupted, ContactTime);
}

void AAethelnEnemyController::HandleLethalResult(UAethelnAbilitySystemComponent* TargetAbilitySystem, const FGuid& ActivationId, double ContactTime)
{
	// Raised during emission. Death starts at the lethal contact time, even if pass step 1 advanced past it.
	if (TargetAbilitySystem == nullptr || TargetAbilitySystem != GetEnemyAbilitySystem() || State == EAethelnEnemyState::Dead) { return; }
	StopMovement();
	bMoveRequested = false;
	Target.Reset();
	PendingResetTime.Reset(); // a late death cancels a pending return reset
	Enter(EAethelnEnemyState::Dead, ContactTime);
}

AAethelnEnemyCharacter* AAethelnEnemyController::GetEnemy() const
{
	return Cast<AAethelnEnemyCharacter>(GetPawn());
}

UAethelnAbilitySystemComponent* AAethelnEnemyController::GetEnemyAbilitySystem() const
{
	return UAethelnAbilitySystemComponent::FindForPawn(GetPawn());
}

UAethelnCombatTimelineSubsystem* AAethelnEnemyController::GetTimeline() const
{
	UWorld* World = GetWorld();
	return World != nullptr && World->GetNetMode() != NM_Client ? World->GetSubsystem<UAethelnCombatTimelineSubsystem>() : nullptr;
}

bool AAethelnEnemyController::HasValidConfig() const
{
	// The telegraph and the interrupted pause may be 0; a zero delay or distance is unset.
	for (const double Value : { ProvisionalTelegraphSeconds, ProvisionalInterruptedSeconds })
	{
		if (!FMath::IsFinite(Value) || Value < 0.0) { return false; }
	}
	for (const double Value : { ProvisionalRespawnSeconds, ProvisionalAttackRange, ProvisionalPerceptionRadius, ProvisionalLeashRadius })
	{
		if (!FMath::IsFinite(Value) || Value <= 0.0) { return false; }
	}
	return true;
}
