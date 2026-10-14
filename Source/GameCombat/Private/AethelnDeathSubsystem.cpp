#include "AethelnDeathSubsystem.h"

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatEffects.h"
#include "AethelnCombatTimelineSubsystem.h"
#include "AethelnGameplayTags.h"
#include "AethelnObservability.h"
#include "AethelnObservabilitySubsystem.h"
#include "Engine/GameInstance.h"
#include "Engine/World.h"
#include "GameFramework/Character.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "GameFramework/Controller.h"
#include "GameFramework/GameModeBase.h"
#include "GameFramework/PlayerState.h"

DEFINE_LOG_CATEGORY_STATIC(LogAethelnDeath, Log, All);

bool UAethelnDeathSubsystem::ShouldCreateSubsystem(UObject* Outer) const
{
	return Super::ShouldCreateSubsystem(Outer) && GetDefault<UAethelnCombatTimelineSubsystem>()->ShouldCreateSubsystem(Outer);
}

void UAethelnDeathSubsystem::Initialize(FSubsystemCollectionBase& Collection)
{
	Super::Initialize(Collection);
	Timeline = Collection.InitializeDependency<UAethelnCombatTimelineSubsystem>();
	if (Timeline.IsValid())
	{
		LethalHandle = Timeline->OnLethalResult.AddUObject(this, &UAethelnDeathSubsystem::HandleLethalResult);
	}
	TickHandle = FWorldDelegates::OnWorldPostActorTick.AddUObject(this, &UAethelnDeathSubsystem::HandlePostActorTick);
}

void UAethelnDeathSubsystem::Deinitialize()
{
	FWorldDelegates::OnWorldPostActorTick.Remove(TickHandle);
	if (Timeline.IsValid()) { Timeline->OnLethalResult.Remove(LethalHandle); }
	Timeline.Reset();
	Pending.Reset();
	Super::Deinitialize();
}

bool UAethelnDeathSubsystem::ApplyDeath(UAethelnAbilitySystemComponent& Victim, const FGuid& ActivationId, TOptional<double> ContactTime)
{
	const FGameplayAttribute Health = UAethelnCombatAttributeSet::GetHealthAttribute();
	const UWorld* World = Victim.GetWorld();
	UAethelnDeathSubsystem* Self = World != nullptr ? World->GetSubsystem<UAethelnDeathSubsystem>() : nullptr;
	// Players only: #20 owns AI death, so a zero-Health AI stays inert here.
	if (Self == nullptr || !Victim.IsOwnerActorAuthoritative() || Cast<APlayerState>(Victim.GetOwner()) == nullptr
		|| Victim.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead)
		|| !Victim.HasAttributeSetForAttribute(Health) || Victim.GetNumericAttribute(Health) > 0.0f)
	{
		return false;
	}
	// A lethal contact ends the chain at the contact time. The timeline has already sent a held buffered-start
	// record before it raises the lethal notification, so that record stays presentation-only (docs/death-and-respawn.md).
	if (ContactTime.IsSet()) { Victim.ResetChain(EAethelnChainEndReason::IncompatibleState, ContactTime.GetValue()); }
	// The tag event ends any remaining chain (IncompatibleState), the dodge window and the block first.
	UAethelnDeathStateEffect::ApplyTo(Victim);
	// A Guard break carried across a reconnect has no death binding (P4): death ends it here, as it does for a live break.
	Victim.RemoveActiveEffectsWithGrantedTags(FGameplayTagContainer(AethelnGameplayTags::State_GuardBroken));
	Victim.CancelAllAbilities();
	if (const ACharacter* Character = Cast<ACharacter>(Victim.GetAvatarActor()))
	{
		if (UCharacterMovementComponent* Movement = Character->GetCharacterMovement()) { Movement->DisableMovement(); }
	}
	// Presentation only, after the authoritative state is in place; a refused repeat never reaches this line.
	Victim.MulticastDeathCue();
	Self->BeginRespawnWait(Victim, ActivationId);
	return true;
}

bool UAethelnDeathSubsystem::Respawn(UAethelnAbilitySystemComponent& Victim)
{
	UWorld* World = Victim.GetWorld();
	UAethelnDeathSubsystem* Self = World != nullptr ? World->GetSubsystem<UAethelnDeathSubsystem>() : nullptr;
	const APlayerState* PlayerState = Cast<APlayerState>(Victim.GetOwner());
	if (Self == nullptr || PlayerState == nullptr || !Victim.IsOwnerActorAuthoritative()
		|| !Victim.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead))
	{
		return false;
	}
	// Fail closed before anything changes: a player that cannot be restarted stays dead.
	AController* Controller = PlayerState->GetOwningController();
	AGameModeBase* GameMode = World->GetAuthGameMode();
	const FGameplayAttribute MaxHealth = UAethelnCombatAttributeSet::GetMaxHealthAttribute();
	const TCHAR* Problem = Controller == nullptr ? TEXT("the player has no controller")
		: GameMode == nullptr ? TEXT("the world has no game mode")
		: GameMode->GetDefaultPawnClassForController(Controller) == nullptr ? TEXT("the game mode has no pawn class")
		: !(Victim.HasAttributeSetForAttribute(MaxHealth) && Victim.GetNumericAttribute(MaxHealth) > 0.0f) ? TEXT("MaxHealth is not above zero, so there is no Health to restore")
		: nullptr;
	if (Problem != nullptr)
	{
		UE_LOG(LogAethelnDeath, Warning, TEXT("Refused to respawn %s: %s; the player stays dead."), *GetNameSafe(PlayerState), Problem);
		return false;
	}
	Self->Pending.Remove(TWeakObjectPtr<UAethelnAbilitySystemComponent>(&Victim));

	// Unpossession runs #19's null-pawn case (chain AvatarLost, dodge cancel, CancelAllAbilities, avatar cleared), and the
	// seam stays closed until the new pawn is possessed. The corpse is destroyed with the delay, not before.
	APawn* DeadPawn = Controller->GetPawn();
	Controller->UnPossess();
	if (DeadPawn != nullptr) { DeadPawn->Destroy(); }
	// Restore, then remove the death effect, then possess: a living avatar never exists with zero Health.
	UAethelnRespawnRestorationEffect::ApplyTo(Victim);
	UAethelnDeathStateEffect::RemoveFrom(Victim);
	GameMode->RestartPlayer(Controller);
	if (Controller->GetPawn() == nullptr)
	{
		UE_LOG(LogAethelnDeath, Error, TEXT("Respawn of %s left the player without a pawn: the game mode did not restart it."), *GetNameSafe(PlayerState));
		return false;
	}
	UE_LOG(LogAethelnDeath, Log, TEXT("%s respawned as %s."), *GetNameSafe(PlayerState), *GetNameSafe(Controller->GetPawn()));
	return true;
}

bool UAethelnDeathSubsystem::CaptureCarriedState(UAethelnAbilitySystemComponent& Player, const FString& Key)
{
	UWorld* World = Player.GetWorld();
	UAethelnDeathSubsystem* Self = World != nullptr ? World->GetSubsystem<UAethelnDeathSubsystem>() : nullptr;
	if (Self == nullptr || Key.IsEmpty() || !Player.IsOwnerActorAuthoritative() || Cast<APlayerState>(Player.GetOwner()) == nullptr) { return false; }
	// The respawn wait leaves with the player: it moves into the snapshot, or is dropped when no snapshot is kept.
	FPendingRespawn Wait;
	const bool bHasWait = Self->Pending.RemoveAndCopyValue(TWeakObjectPtr<UAethelnAbilitySystemComponent>(&Player), Wait);
	const float Grace = Self->ProvisionalDisconnectGraceSeconds;
	if (!FMath::IsFinite(Grace) || !(Grace > 0.0f))
	{
		UE_LOG(LogAethelnDeath, Warning, TEXT("Refused to carry the state of %s: ProvisionalDisconnectGraceSeconds %f must be finite and above zero; a reconnect is a new session."),
			*GetNameSafe(Player.GetOwner()), Grace);
		return false;
	}
	const FGameplayAttribute Health = UAethelnCombatAttributeSet::GetHealthAttribute();
	if (!Player.HasAttributeSetForAttribute(Health)) { return false; }
	const double Now = World->GetTimeSeconds();
	FCarriedState State;
	auto Read = [&Player](const FGameplayAttribute& Attribute) { return Player.GetNumericAttribute(Attribute); };
	State.Attributes.MaxHealth = Read(UAethelnCombatAttributeSet::GetMaxHealthAttribute());
	State.Attributes.Health = Read(Health);
	State.Attributes.MaxEndurance = Read(UAethelnCombatAttributeSet::GetMaxEnduranceAttribute());
	State.Attributes.Endurance = Read(UAethelnCombatAttributeSet::GetEnduranceAttribute());
	State.Attributes.MaxGuard = Read(UAethelnCombatAttributeSet::GetMaxGuardAttribute());
	State.Attributes.Guard = Read(UAethelnCombatAttributeSet::GetGuardAttribute());
	// The shared duration effect carries cooldowns, the Guard break and the recovery delays; each expires on the server clock.
	// The death effect is the life state and the recovery effects are started again by the new PlayerState. Any other active
	// non-instant effect is not carried, so a reconnect would cleanse it: say so, so a new effect class cannot slip through.
	for (auto Effect = Player.GetActiveGameplayEffects().CreateConstIterator(); Effect; ++Effect)
	{
		const FActiveGameplayEffect* Active = &*Effect;
		const UGameplayEffect* Definition = Active != nullptr ? Active->Spec.Def.Get() : nullptr;
		if (Definition == nullptr || Definition->DurationPolicy == EGameplayEffectDurationType::Instant) { continue; }
		if (Definition->IsA<UAethelnCooldownEffect>())
		{
			const double Remaining = Active->GetTimeRemaining(static_cast<float>(Now));
			if (Remaining > 0.0 && Active->Spec.DynamicGrantedTags.Num() > 0)
			{
				State.TimedStates.Add({ Active->Spec.DynamicGrantedTags, Now + Remaining });
			}
		}
		else if (!Definition->IsA<UAethelnDeathStateEffect>() && !Definition->IsA<UAethelnResourceRecoveryEffect>())
		{
			UE_LOG(LogAethelnDeath, Warning, TEXT("The reconnect snapshot of %s does not carry the active effect %s; a reconnect would end it."),
				*GetNameSafe(Player.GetOwner()), *GetNameSafe(Definition));
		}
	}
	State.bDead = Player.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead);
	State.bHasRespawnWait = State.bDead && bHasWait;
	State.Deadline = Wait.Deadline;
	State.Generation = Wait.Generation;
	State.GraceEndsAt = Now + Grace;
	Self->Carried.Add(Key, State);
	return true;
}

bool UAethelnDeathSubsystem::RestoreCarriedState(UAethelnAbilitySystemComponent& Player, const FString& Key)
{
	UWorld* World = Player.GetWorld();
	UAethelnDeathSubsystem* Self = World != nullptr ? World->GetSubsystem<UAethelnDeathSubsystem>() : nullptr;
	FCarriedState State;
	// One reconnect consumes the snapshot; an expired one is dropped and the caller starts a new session.
	if (Self == nullptr || Key.IsEmpty() || !Player.IsOwnerActorAuthoritative() || !Self->Carried.RemoveAndCopyValue(Key, State)) { return false; }
	const double Now = World->GetTimeSeconds();
	if (Now > State.GraceEndsAt) { return false; }
	UAethelnAttributeInitEffect::ApplyTo(Player, State.Attributes);
	for (const FCarriedState::FTimedState& Timed : State.TimedStates)
	{
		if (!(Timed.ExpiresAt > Now)) { continue; }
		FGameplayEffectSpec Spec(GetDefault<UAethelnCooldownEffect>(), Player.MakeEffectContext(), 1.0f);
		Spec.SetSetByCallerMagnitude(AethelnGameplayTags::SetByCaller_Cooldown_Duration, static_cast<float>(Timed.ExpiresAt - Now));
		Spec.DynamicGrantedTags.AppendTags(Timed.Tags);
		Player.ApplyGameplayEffectSpecToSelf(Spec);
	}
	if (State.bDead)
	{
		// The same death, not a new one: no cue, no Death event, no new generation. The respawn follows the old deadline.
		UAethelnDeathStateEffect::ApplyTo(Player);
		Player.CancelAllAbilities();
		if (const ACharacter* Character = Cast<ACharacter>(Player.GetAvatarActor()))
		{
			if (UCharacterMovementComponent* Movement = Character->GetCharacterMovement()) { Movement->DisableMovement(); }
		}
		if (State.bHasRespawnWait) { Self->Pending.Add(TWeakObjectPtr<UAethelnAbilitySystemComponent>(&Player), FPendingRespawn{ State.Deadline, State.Generation }); }
	}
	return true;
}

bool UAethelnDeathSubsystem::FindRespawnWaitForTests(const UAethelnAbilitySystemComponent& Player, double& OutDeadline, uint64& OutGeneration) const
{
	const FPendingRespawn* Wait = Pending.Find(TWeakObjectPtr<UAethelnAbilitySystemComponent>(const_cast<UAethelnAbilitySystemComponent*>(&Player)));
	if (Wait != nullptr) { OutDeadline = Wait->Deadline; OutGeneration = Wait->Generation; }
	return Wait != nullptr;
}

void UAethelnDeathSubsystem::BeginRespawnWait(UAethelnAbilitySystemComponent& Victim, const FGuid& ActivationId)
{
	const uint64 Generation = ++LifeGeneration;
	EmitDeathEvent(ActivationId, Generation);
	const TWeakObjectPtr<UAethelnAbilitySystemComponent> Key(&Victim);
	const float Delay = ProvisionalRespawnDelaySeconds;
	if (!FMath::IsFinite(Delay) || !(Delay > 0.0f))
	{
		Pending.Remove(Key);
		UE_LOG(LogAethelnDeath, Warning, TEXT("Refused to schedule a respawn for %s: ProvisionalRespawnDelaySeconds %f must be finite and above zero; the player stays dead."),
			*GetNameSafe(Victim.GetOwner()), Delay);
		return;
	}
	// A new death replaces the player's wait: one respawn per life.
	Pending.Add(Key, FPendingRespawn{ GetWorld()->GetTimeSeconds() + Delay, Generation });
}

void UAethelnDeathSubsystem::HandlePostActorTick(UWorld* World, ELevelTick /*TickType*/, float /*DeltaSeconds*/)
{
	if (World == nullptr || World != GetWorld() || (Pending.IsEmpty() && Carried.IsEmpty())) { return; }
	const double Now = World->GetTimeSeconds(); // Never DeltaSeconds: the deadline is on the world clock.
	// A snapshot is valid through its grace window; the restore checks the same bound, so this only frees memory.
	for (auto Iterator = Carried.CreateIterator(); Iterator; ++Iterator)
	{
		if (Now > Iterator.Value().GraceEndsAt) { Iterator.RemoveCurrent(); }
	}
	TArray<TPair<uint64, TWeakObjectPtr<UAethelnAbilitySystemComponent>>> Due;
	for (auto Iterator = Pending.CreateIterator(); Iterator; ++Iterator)
	{
		if (!Iterator.Key().IsValid()) { Iterator.RemoveCurrent(); }
		else if (Now >= Iterator.Value().Deadline)
		{
			Due.Emplace(Iterator.Value().Generation, Iterator.Key());
			Iterator.RemoveCurrent();
		}
		else if (const ACharacter* Character = Cast<ACharacter>(Iterator.Key()->GetAvatarActor()))
		{
			// A dead player's pawn stays still. A restored one is possessed after the restore (P4), and the engine's restart
			// can reset its movement mode, so this keeps the dead pawn at MOVE_None until the respawn.
			UCharacterMovementComponent* Movement = Character->GetCharacterMovement();
			if (Movement != nullptr && Movement->MovementMode != MOVE_None) { Movement->DisableMovement(); }
		}
	}
	// Death order, never map order.
	Due.Sort([](const TPair<uint64, TWeakObjectPtr<UAethelnAbilitySystemComponent>>& A, const TPair<uint64, TWeakObjectPtr<UAethelnAbilitySystemComponent>>& B) { return A.Key < B.Key; });
	for (const TPair<uint64, TWeakObjectPtr<UAethelnAbilitySystemComponent>>& Entry : Due)
	{
		if (UAethelnAbilitySystemComponent* Victim = Entry.Value.Get()) { Respawn(*Victim); }
	}
}

void UAethelnDeathSubsystem::EmitDeathEvent(const FGuid& ActivationId, uint64 Generation) const
{
	// A missing subsystem or failed sink never changes gameplay (as the timeline's hit event).
	const UWorld* World = GetWorld();
	UGameInstance* GameInstance = World != nullptr ? World->GetGameInstance() : nullptr;
	UAethelnObservabilitySubsystem* Observability = GameInstance != nullptr ? GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>() : nullptr;
	if (Observability == nullptr) { return; }
	FAethelnObservabilityEvent Event;
	Event.Category = EAethelnObservabilityCategory::Death;
	Event.SubjectCategory = EAethelnObservabilityCategory::Death;
	Event.SafeReason = EAethelnSafeReason::Accepted;
	FAethelnObservabilityEventContext Context;
	Context.ConnectionPseudonym = AethelnObservability::ExcludedIdentifier;
	// The lethal activation correlates the death with its hit event; a non-contact death has none.
	Context.ActivationId = ActivationId.IsValid() ? ActivationId.ToString(EGuidFormats::DigitsWithHyphensLower) : FString();
	Context.Sequence = Generation;
	Observability->EmitEvent(Event, Context);
}

void UAethelnDeathSubsystem::HandleLethalResult(UAethelnAbilitySystemComponent* Target, const FGuid& ActivationId, double ContactTime)
{
	if (Target != nullptr && ApplyDeath(*Target, ActivationId, ContactTime))
	{
		UE_LOG(LogAethelnDeath, Log, TEXT("%s died (activation %s)."), *GetNameSafe(Target->GetOwner()), *ActivationId.ToString(EGuidFormats::DigitsWithHyphensLower));
	}
}
