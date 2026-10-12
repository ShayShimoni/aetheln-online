#include "AethelnPlayerState.h"

#include "Abilities/GameplayAbility.h"
#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnGameplayAbility.h"
#include "AethelnGameplayTags.h"
#include "GameFramework/Pawn.h"
#include "GameplayEffect.h"

DEFINE_LOG_CATEGORY_STATIC(LogAethelnAbilityGrant, Log, All);
DEFINE_LOG_CATEGORY_STATIC(LogAethelnAbilityAvatar, Log, All);

AAethelnPlayerState::AAethelnPlayerState()
{
	AbilitySystemComponent = CreateDefaultSubobject<UAethelnAbilitySystemComponent>(TEXT("AbilitySystemComponent"));
	AbilitySystemComponent->SetIsReplicated(true);
	AbilitySystemComponent->SetReplicationMode(EGameplayEffectReplicationMode::Mixed);

	// The attribute set must be a default subobject of the ASC's owner.
	AttributeSet = CreateDefaultSubobject<UAethelnCombatAttributeSet>(TEXT("CombatAttributeSet"));
}

void AAethelnPlayerState::PostInitializeComponents()
{
	Super::PostInitializeComponents();

	// Config values are not available in the constructor.
	if (ProvisionalNetUpdateFrequency > 0.0f)
	{
		SetNetUpdateFrequency(ProvisionalNetUpdateFrequency);
	}

	// The ASC's InitializeComponent made this PlayerState its avatar. There is no
	// pawn yet, so this sets the avatar to null on the server and on clients.
	AbilitySystemComponent->InitAbilityActorInfo(this, GetPawn());
	OnPawnSet.AddUniqueDynamic(this, &AAethelnPlayerState::HandlePawnSet);

	// HUD (#61): owner outcomes become presentation-safe HUD events. The ASC is this
	// actor's subobject, so these bindings live exactly as long as both.
	AbilitySystemComponent->OnActivationOutcome.AddWeakLambda(this, [this](uint32 Sequence, EAethelnActivationResult Result)
	{
		HudActionOutcome.Broadcast(ToHudOutcome(Sequence, Result));
	});
	AbilitySystemComponent->OnMovementActivationOutcome.AddWeakLambda(this, [this](float /* ClientTimeStamp */, EAethelnActivationResult Result)
	{
		HudActionOutcome.Broadcast(ToHudOutcome(0, Result));
	});
	AbilitySystemComponent->OnCombatActivation.AddWeakLambda(this, [this](const FAethelnCombatActivationRecord& Record)
	{
		if (Record.AimCorrection == EAethelnAimCorrection::AimCorrected)
		{
			FAethelnHudActionOutcome Outcome;
			Outcome.Kind = EAethelnHudOutcomeKind::Corrected;
			Outcome.Sequence = Record.Sequence;
			HudActionOutcome.Broadcast(Outcome);
		}
	});
}

UAbilitySystemComponent* AAethelnPlayerState::GetAbilitySystemComponent() const
{
	return AbilitySystemComponent;
}

FAethelnDodgeMovementDefinition AAethelnPlayerState::GetDodgeMovementDefinition() const
{
	return AbilitySystemComponent != nullptr ? AbilitySystemComponent->GetDodgeMovementDefinition() : FAethelnDodgeMovementDefinition();
}

bool AAethelnPlayerState::CanPredictDodge() const
{
	return AbilitySystemComponent != nullptr && AbilitySystemComponent->CanPredictDodge();
}

bool AAethelnPlayerState::TryAuthorizeDodge(const FAethelnDodgeStartRequest& Request)
{
	return AbilitySystemComponent != nullptr
		&& AbilitySystemComponent->ProcessMovementCarriedRequest(Request) == EAethelnActivationResult::Accepted;
}

FAethelnHudSnapshot AAethelnPlayerState::GetHudSnapshot() const
{
	FAethelnHudSnapshot Snapshot;
	if (AttributeSet == nullptr || AbilitySystemComponent == nullptr)
	{
		return Snapshot;
	}
	auto Read = [](float Current, float Max)
	{
		FAethelnHudResource Resource;
		Resource.Current = Current;
		Resource.Max = Max;
		Resource.bKnown = true;
		return Resource;
	};
	Snapshot.Health = Read(AttributeSet->GetHealth(), AttributeSet->GetMaxHealth());
	Snapshot.Endurance = Read(AttributeSet->GetEndurance(), AttributeSet->GetMaxEndurance());
	Snapshot.Guard = Read(AttributeSet->GetGuard(), AttributeSet->GetMaxGuard());

	// Every owned Cooldown.* tag plus these timed states, each applied through a timed duration effect.
	// Built once, on first use, after native tags are registered.
	static const FGameplayTagContainer TimedTags = []
	{
		FGameplayTagContainer Tags;
		Tags.AddTag(FGameplayTag::RequestGameplayTag(TEXT("Cooldown")));
		Tags.AddTag(AethelnGameplayTags::State_GuardBroken);
		Tags.AddTag(AethelnGameplayTags::State_EnduranceRecoveryDelayed);
		Tags.AddTag(AethelnGameplayTags::State_GuardRecoveryDelayed);
		return Tags;
	}();
	for (const FGameplayTag& Tag : AbilitySystemComponent->GetOwnedGameplayTags().Filter(TimedTags))
	{
		FAethelnHudTimedState& State = Snapshot.TimedStates.AddDefaulted_GetRef();
		State.Tag = Tag;
		for (const float Seconds : AbilitySystemComponent->GetActiveEffectsTimeRemaining(FGameplayEffectQuery::MakeQuery_MatchAnyOwningTags(FGameplayTagContainer(Tag))))
		{
			State.RemainingSeconds = FMath::Max(State.RemainingSeconds, Seconds);
		}
	}
	return Snapshot;
}

FAethelnHudActionOutcome AAethelnPlayerState::ToHudOutcome(uint32 Sequence, EAethelnActivationResult Result)
{
	FAethelnHudActionOutcome Outcome;
	Outcome.Sequence = Sequence;
	if (Result != EAethelnActivationResult::Accepted)
	{
		// The owner already receives this result; its name carries no server-only detail.
		Outcome.Kind = EAethelnHudOutcomeKind::Rejected;
		Outcome.Reason = FName(*StaticEnum<EAethelnActivationResult>()->GetNameStringByValue(static_cast<int64>(Result)));
	}
	return Outcome;
}

bool AAethelnPlayerState::IsGrantableAbilitySpec(const FGameplayAbilitySpec& Spec)
{
	// A plain UGameplayAbility subclass would bypass the choke point.
	const UAethelnGameplayAbility* Ability = Cast<UAethelnGameplayAbility>(Spec.Ability);
	const TCHAR* Problem = Ability == nullptr
		? TEXT("does not derive from UAethelnGameplayAbility")
		: Spec.InputID != INDEX_NONE
			? TEXT("would be granted with an input id")
			: Spec.DynamicAbilityTriggers.Num() > 0
				? TEXT("would be granted with dynamic ability triggers")
				: Ability->FindGrantProblem();
	if (Problem != nullptr)
	{
		UE_LOG(LogAethelnAbilityGrant, Warning, TEXT("Refused to grant ability %s: it %s."), *GetNameSafe(Spec.Ability), Problem);
		return false;
	}
	return true;
}

void AAethelnPlayerState::HandlePawnSet(APlayerState* Player, APawn* NewPawn, APawn* OldPawn)
{
	// Never read Controller->GetPawn() here: during possession it still points at the old pawn.
	if (NewPawn != nullptr)
	{
		// Clients converge on the server's replicated avatar either way.
		AbilitySystemComponent->InitAbilityActorInfo(this, NewPawn);
		UE_LOG(LogAethelnAbilityAvatar, Log, TEXT("%s possessed %s (%s): ASC owner=%s avatar=%s authority=%d"),
			*GetNameSafe(this), *GetNameSafe(NewPawn), *GetNameSafe(NewPawn->GetClass()),
			*GetNameSafe(AbilitySystemComponent->GetOwnerActor()), *GetNameSafe(AbilitySystemComponent->GetAvatarActor()), HasAuthority() ? 1 : 0);

		// Keyed on the flag only, never on OldPawn: re-possession (for example a
		// respawn) never re-grants, refills, or resets cooldowns. #21 owns respawn.
		if (HasAuthority() && !bCombatStateInitialized)
		{
			bCombatStateInitialized = true;
			for (const TSubclassOf<UGameplayAbility>& AbilityClass : GrantedAbilities)
			{
				const FGameplayAbilitySpec Spec(AbilityClass, 1);
				if (IsGrantableAbilitySpec(Spec))
				{
					AbilitySystemComponent->GiveAbility(Spec);
				}
			}
			UAethelnAttributeInitEffect::ApplyTo(*AbilitySystemComponent, ProvisionalInitialAttributes);
			// Once per PlayerState, like the init: a re-possession never stacks a second recovery.
			UAethelnResourceRecoveryEffect::Start(*AbilitySystemComponent, UAethelnEnduranceRecoveryEffect::StaticClass(), ProvisionalEnduranceRecovery);
			UAethelnResourceRecoveryEffect::Start(*AbilitySystemComponent, UAethelnGuardRecoveryEffect::StaticClass(), ProvisionalGuardRecovery);
		}
		return;
	}

	UE_LOG(LogAethelnAbilityAvatar, Log, TEXT("%s has no pawn (was %s): authority=%d"), *GetNameSafe(this), *GetNameSafe(OldPawn), HasAuthority() ? 1 : 0);
	if (!HasAuthority())
	{
		return;
	}

	// Unpossession, or the possessed pawn is being destroyed. InitAbilityActorInfo
	// does not cancel on an avatar change, so cancel explicitly.
	AbilitySystemComponent->ResetChain(EAethelnChainEndReason::AvatarLost);
	// Ends the dodge on the old avatar's movement while it is still reachable.
	AbilitySystemComponent->CancelDodge();
	AbilitySystemComponent->CancelAllAbilities();

	// SetAvatarActor, never ClearActorInfo: the owner must stay the PlayerState.
	if (OldPawn == nullptr || AbilitySystemComponent->GetAvatarActor() == OldPawn)
	{
		AbilitySystemComponent->SetAvatarActor(nullptr);
	}
}
