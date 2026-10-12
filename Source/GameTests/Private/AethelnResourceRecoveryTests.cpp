#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatEffects.h"
#include "AethelnCombatTestWorld.h"
#include "AethelnDefenseTestFixture.h"
#include "AethelnGameplayTags.h"
#include "AethelnOathscarAbilities.h"
#include "AethelnPlayerCharacter.h"
#include "AethelnPlayerState.h"
#include "GameFramework/WorldSettings.h"
#include "GameplayEffectComponents/TargetTagRequirementsGameplayEffectComponent.h"
#include "Misc/AutomationTest.h"
#include <limits>

/*
 * #292 passive and delayed recovery (docs/gas-foundation.md, Resource Recovery). Recovery runs on the
 * timer manager, which ticks at most once per engine frame (FTimerManager::Tick returns early within one
 * GFrameCounter value), so the time-dependent tests run one World->Tick per frame through FFrameSteps.
 */
namespace AethelnResourceRecoveryTests
{
	using namespace AethelnCombatTests;

	/** Fixture values, not tuning: each step adds 1 every 0.25 s, and no delay expiry lands on a step. */
	FAethelnResourceRecoveryValues MakeTestRecovery()
	{
		FAethelnResourceRecoveryValues Values;
		Values.RatePerSecond = 4.0f;
		Values.PeriodSeconds = 0.25f;
		Values.DelaySeconds = 0.625f;
		return Values;
	}

	/** Runs each step in its own engine frame; releases the steps, and the fixtures they hold, after the last. */
	class FFrameSteps : public IAutomationLatentCommand
	{
	public:
		explicit FFrameSteps(TArray<TFunction<void()>> InSteps) : Steps(MoveTemp(InSteps)), LastFrame(GFrameCounter) {}

		virtual bool Update() override
		{
			if (GFrameCounter == LastFrame) { return false; }
			LastFrame = GFrameCounter;
			Steps[Next++]();
			if (Next < Steps.Num()) { return false; }
			Steps.Empty();
			return true;
		}

	private:
		TArray<TFunction<void()>> Steps;
		int32 Next = 0;
		uint64 LastFrame;
	};

	int32 CountActive(const UAbilitySystemComponent& ASC, TSubclassOf<UGameplayEffect> Effect)
	{
		FGameplayEffectQuery Query;
		Query.EffectDefinition = Effect;
		return ASC.GetActiveEffects(Query).Num();
	}

	int32 CountWithTag(const UAbilitySystemComponent& ASC, const FGameplayTag& Tag)
	{
		return ASC.GetActiveEffects(FGameplayEffectQuery::MakeQuery_MatchAnyOwningTags(FGameplayTagContainer(Tag))).Num();
	}

	float Endurance(const UAbilitySystemComponent& ASC) { return ASC.GetNumericAttribute(UAethelnCombatAttributeSet::GetEnduranceAttribute()); }
	float Guard(const UAbilitySystemComponent& ASC) { return ASC.GetNumericAttribute(UAethelnCombatAttributeSet::GetGuardAttribute()); }

	/** A possessed player whose PlayerState starts both recoveries with the fixture values. */
	struct FRecoveryPlayer
	{
		FScopedCombatTestWorld World;
		FTestPlayer Player;
		AAethelnPlayerCharacter* Pawn = nullptr;

		bool Init(FAutomationTestBase& Test, const TArray<TSubclassOf<UGameplayAbility>>& Abilities = { UAethelnLongRunningTestAbility::StaticClass() })
		{
			if (!SpawnTestPlayer(Test, World, Player, Abilities)) { return false; }
			Player.PlayerState->ProvisionalEnduranceRecovery = MakeTestRecovery();
			Player.PlayerState->ProvisionalGuardRecovery = MakeTestRecovery();
			Pawn = World.Spawn<AAethelnPlayerCharacter>();
			if (!Test.TestNotNull(TEXT("Player pawn exists"), Pawn)) { return false; }
			// Fixture frames, not a tick budget: no clamp, so World->Tick advances exactly the given time.
			World.World->GetWorldSettings()->MinUndilatedFrameTime = 0.0f;
			World.World->GetWorldSettings()->MaxUndilatedFrameTime = 10.0f;
			// The timer manager ticks first in this frame, so recovery timers set at possession start at once.
			Tick(0.0f);
			Player.Controller->Possess(Pawn);
			return true;
		}

		void Tick(float Seconds) const { World.World->Tick(LEVELTICK_All, Seconds); }
		UAethelnAbilitySystemComponent& ASC() const { return *Player.AbilitySystem; }
	};
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnRecoveryEffectDefinitionTest,
	"Aetheln.GameCombat.Recovery.EffectDefinition",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnRecoveryEffectDefinitionTest::RunTest(const FString& Parameters)
{
	using namespace AethelnResourceRecoveryTests;
	struct FCase { TSubclassOf<UAethelnResourceRecoveryEffect> Class; FGameplayAttribute Attribute; FGameplayTag DelayTag; };
	const FCase Cases[] = {
		{ UAethelnEnduranceRecoveryEffect::StaticClass(), UAethelnCombatAttributeSet::GetEnduranceAttribute(), AethelnGameplayTags::State_EnduranceRecoveryDelayed },
		{ UAethelnGuardRecoveryEffect::StaticClass(), UAethelnCombatAttributeSet::GetGuardAttribute(), AethelnGameplayTags::State_GuardRecoveryDelayed },
	};
	for (const FCase& Case : Cases)
	{
		const UAethelnResourceRecoveryEffect* Effect = Case.Class.GetDefaultObject();
		const FString Name = GetNameSafe(Case.Class);
		TestEqual(Name + TEXT(": infinite"), Effect->DurationPolicy, EGameplayEffectDurationType::Infinite);
		TestFalse(Name + TEXT(": no step on application"), Effect->bExecutePeriodicEffectOnApplication);
		TestEqual(Name + TEXT(": a pause restarts the period"), Effect->PeriodicInhibitionPolicy, EGameplayEffectPeriodInhibitionRemovedPolicy::ResetPeriod);
		TestTrue(Name + TEXT(": its own delay tag"), Effect->GetDelayTag() == Case.DelayTag);
		if (TestEqual(Name + TEXT(": one modifier"), Effect->Modifiers.Num(), 1))
		{
			const FGameplayModifierInfo& Modifier = Effect->Modifiers[0];
			TestTrue(Name + TEXT(": on its resource"), Modifier.Attribute == Case.Attribute);
			TestEqual(Name + TEXT(": adds to the base"), Modifier.ModifierOp.GetValue(), EGameplayModOp::AddBase);
			TestTrue(Name + TEXT(": set by caller"), Modifier.ModifierMagnitude.GetSetByCallerFloat().DataTag == AethelnGameplayTags::SetByCaller_Recovery_Amount.GetTag());
		}
		const UTargetTagRequirementsGameplayEffectComponent* Pause = Effect->FindComponent<UTargetTagRequirementsGameplayEffectComponent>();
		if (TestNotNull(Name + TEXT(": pause requirements"), Pause))
		{
			FGameplayTagContainer Expected(AethelnGameplayTags::State_Dead);
			Expected.AddTag(Case.DelayTag);
			TestTrue(Name + TEXT(": pauses exactly while State.Dead or its delay holds"), Pause->OngoingTagRequirements.IgnoreTags == Expected);
			TestTrue(Name + TEXT(": nothing required"), Pause->OngoingTagRequirements.RequireTags.IsEmpty());
			TestTrue(Name + TEXT(": nothing removes it"), Pause->RemovalTagRequirements.IsEmpty());
			TestTrue(Name + TEXT(": no application gate"), Pause->ApplicationTagRequirements.IsEmpty());
		}
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnRecoveryFailsClosedTest,
	"Aetheln.GameCombat.Recovery.FailsClosed",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnRecoveryFailsClosedTest::RunTest(const FString& Parameters)
{
	using namespace AethelnResourceRecoveryTests;
	FScopedCombatTestWorld TestWorld;
	FTestPlayer Player;
	if (!SpawnTestPlayer(*this, TestWorld, Player)) { return false; }
	AAethelnPlayerCharacter* Pawn = TestWorld.Spawn<AAethelnPlayerCharacter>();
	if (!TestNotNull(TEXT("Player pawn exists"), Pawn)) { return false; }
	UAethelnAbilitySystemComponent& ASC = *Player.AbilitySystem;
	const TSubclassOf<UAethelnResourceRecoveryEffect> EnduranceRecovery = UAethelnEnduranceRecoveryEffect::StaticClass();

	// Unset production values (no ini keys until #107): no recovery, so a spend restarts no delay.
	Player.Controller->Possess(Pawn);
	TestEqual(TEXT("Unset: no Endurance recovery"), CountActive(ASC, EnduranceRecovery), 0);
	TestEqual(TEXT("Unset: no Guard recovery"), CountActive(ASC, UAethelnGuardRecoveryEffect::StaticClass()), 0);
	UAethelnResourceRecoveryEffect::RestartDelay(ASC, EnduranceRecovery);
	TestEqual(TEXT("No recovery: a restart applies no delay"), CountWithTag(ASC, AethelnGameplayTags::State_EnduranceRecoveryDelayed), 0);
	TestEqual(TEXT("No recovery: no effect at all"), ASC.GetNumActiveGameplayEffects(), 0);

	// Each invalid value is refused, logged, and applies nothing.
	const float NaN = std::numeric_limits<float>::quiet_NaN();
	const float Infinity = std::numeric_limits<float>::infinity();
	TArray<FAethelnResourceRecoveryValues> Invalid;
	auto With = [&Invalid](float Rate, float Period, float Delay)
	{
		FAethelnResourceRecoveryValues Values;
		Values.RatePerSecond = Rate;
		Values.PeriodSeconds = Period;
		Values.DelaySeconds = Delay;
		Invalid.Add(Values);
	};
	With(NaN, 0.25f, 0.625f);
	With(4.0f, Infinity, 0.625f);
	With(4.0f, 0.25f, NaN);
	With(-4.0f, 0.25f, 0.625f);
	With(0.0f, 0.25f, 0.625f);
	With(4.0f, 0.0f, 0.625f);
	With(4.0f, -0.25f, 0.625f);
	With(4.0f, 0.25f, -0.625f);
	With(0.0f, 0.0f, 0.625f);
	AddExpectedMessagePlain(TEXT("Refused to start"), ELogVerbosity::Warning, EAutomationExpectedMessageFlags::Contains, Invalid.Num());
	for (int32 Index = 0; Index < Invalid.Num(); ++Index)
	{
		TestFalse(*FString::Printf(TEXT("Invalid case %d: no handle"), Index), UAethelnResourceRecoveryEffect::Start(ASC, EnduranceRecovery, Invalid[Index]).IsValid());
	}
	TestEqual(TEXT("Invalid values: no recovery"), CountActive(ASC, EnduranceRecovery), 0);

	// A valid recovery with no delay: a spend restarts nothing, because a zero duration would never expire.
	FAethelnResourceRecoveryValues NoDelay = MakeTestRecovery();
	NoDelay.DelaySeconds = 0.0f;
	TestTrue(TEXT("A zero delay is valid"), UAethelnResourceRecoveryEffect::Start(ASC, EnduranceRecovery, NoDelay).IsValid());
	UAethelnResourceRecoveryEffect::RestartDelay(ASC, EnduranceRecovery);
	TestEqual(TEXT("No delay: a restart applies nothing"), CountWithTag(ASC, AethelnGameplayTags::State_EnduranceRecoveryDelayed), 0);
	TestEqual(TEXT("Only the recovery is active"), ASC.GetNumActiveGameplayEffects(), 1);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnRecoveryPassiveDeathAndCapTest,
	"Aetheln.GameCombat.Recovery.PassiveDeathAndCap",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnRecoveryPassiveDeathAndCapTest::RunTest(const FString& Parameters)
{
	using namespace AethelnResourceRecoveryTests;
	const TSharedRef<FRecoveryPlayer> F = MakeShared<FRecoveryPlayer>();
	if (!F->Init(*this)) { return false; }
	UAethelnAbilitySystemComponent& ASC = F->ASC();
	TestEqual(TEXT("One Endurance recovery"), CountActive(ASC, UAethelnEnduranceRecoveryEffect::StaticClass()), 1);
	TestEqual(TEXT("One Guard recovery"), CountActive(ASC, UAethelnGuardRecoveryEffect::StaticClass()), 1);
	TestEqual(TEXT("Starting adds nothing at once"), Endurance(ASC), 30.0f);
	// Stand-ins for #60 and #21 effects: no cost commit or Guard pressure, so no delay starts.
	ApplyInstantModifier(ASC, UAethelnCombatAttributeSet::GetEnduranceAttribute(), EGameplayModOp::AddBase, -10.0f);
	ApplyInstantModifier(ASC, UAethelnCombatAttributeSet::GetGuardAttribute(), EGameplayModOp::AddBase, -10.0f);

	ADD_LATENT_AUTOMATION_COMMAND(FFrameSteps({
		[this, F]
		{
			F->Tick(1.0f);
			TestEqual(TEXT("Passive: Endurance recovers 4 in 1 s"), Endurance(F->ASC()), 24.0f);
			TestEqual(TEXT("Passive: Guard recovers 4 in 1 s"), Guard(F->ASC()), 14.0f);
			// Stands in for #21's death transition.
			F->ASC().AddLooseGameplayTag(AethelnGameplayTags::State_Dead);
		},
		[this, F]
		{
			F->Tick(1.0f);
			TestEqual(TEXT("Death pauses Endurance recovery"), Endurance(F->ASC()), 24.0f);
			TestEqual(TEXT("Death pauses Guard recovery"), Guard(F->ASC()), 14.0f);
			TestEqual(TEXT("A pause keeps the recovery effect"), CountActive(F->ASC(), UAethelnEnduranceRecoveryEffect::StaticClass()), 1);
			F->ASC().RemoveLooseGameplayTag(AethelnGameplayTags::State_Dead);
		},
		[this, F]
		{
			F->Tick(1.0f);
			TestEqual(TEXT("Resumes after death at the same rate: Endurance"), Endurance(F->ASC()), 28.0f);
			TestEqual(TEXT("Resumes after death at the same rate: Guard"), Guard(F->ASC()), 18.0f);
		},
		[this, F]
		{
			F->Tick(10.0f);
			UAethelnAbilitySystemComponent& Asc = F->ASC();
			TestEqual(TEXT("Cap: Endurance stops at its maximum"), Endurance(Asc), 30.0f);
			TestEqual(TEXT("Cap: the Endurance base never exceeds its maximum"), Asc.GetNumericAttributeBase(UAethelnCombatAttributeSet::GetEnduranceAttribute()), 30.0f);
			TestEqual(TEXT("Cap: Guard stops at its maximum"), Guard(Asc), 20.0f);
			TestEqual(TEXT("Cap: the Guard base never exceeds its maximum"), Asc.GetNumericAttributeBase(UAethelnCombatAttributeSet::GetGuardAttribute()), 20.0f);
		},
	}));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnRecoveryDelayAfterCostCommitTest,
	"Aetheln.GameCombat.Recovery.DelayAfterCostCommit",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnRecoveryDelayAfterCostCommitTest::RunTest(const FString& Parameters)
{
	using namespace AethelnResourceRecoveryTests;
	using EResult = EAethelnActivationResult;
	const TSharedRef<FRecoveryPlayer> F = MakeShared<FRecoveryPlayer>();
	if (!F->Init(*this, { UAethelnGateStepAbility::StaticClass() })) { return false; }
	const FGameplayAbilitySpec* Spec = F->ASC().FindAbilitySpecFromClass(UAethelnGateStepAbility::StaticClass());
	UAethelnGameplayAbility* GateStep = Spec != nullptr ? Cast<UAethelnGameplayAbility>(Spec->GetPrimaryInstance()) : nullptr;
	if (!TestNotNull(TEXT("Gate Step is granted with an instance"), GateStep)) { return false; }
	// Test-pinned values on the granted instance, not tuning.
	GateStep->ProvisionalEnduranceCost = 8.0f;
	GateStep->ProvisionalCooldownSeconds = 0.0f;
	auto Commit = [F, GateStep](uint32 Sequence)
	{
		FAethelnCombatActivationRequest Request;
		Request.AbilityId = AethelnGameplayTags::Ability_Oathscar_GateStep;
		Request.ContentVersion = GateStep->ContentVersion;
		Request.Sequence = Sequence;
		FillTestAimAndTime(Request, F->ASC());
		return F->ASC().ProcessServerRequest(Request);
	};
	const FGameplayTag Delayed = AethelnGameplayTags::State_EnduranceRecoveryDelayed;

	TestEqual(TEXT("The cost commit is accepted"), Commit(1), EResult::Accepted);
	TestEqual(TEXT("It spends 8"), Endurance(F->ASC()), 22.0f);
	TestTrue(TEXT("The commit starts the delay"), F->ASC().HasMatchingGameplayTag(Delayed));
	const TArray<float> Durations = F->ASC().GetActiveEffectsDuration(FGameplayEffectQuery::MakeQuery_MatchAnyOwningTags(FGameplayTagContainer(Delayed)));
	if (TestEqual(TEXT("One delay effect"), Durations.Num(), 1)) { TestEqual(TEXT("It lasts the configured delay"), Durations[0], 0.625f); }
	TestFalse(TEXT("Guard recovery is not delayed by an Endurance cost"), F->ASC().HasMatchingGameplayTag(AethelnGameplayTags::State_GuardRecoveryDelayed));

	ADD_LATENT_AUTOMATION_COMMAND(FFrameSteps({
		[this, F]
		{
			F->Tick(0.5f);
			TestEqual(TEXT("No Endurance recovery during the delay"), Endurance(F->ASC()), 22.0f);
		},
		[this, F, Delayed]
		{
			F->Tick(0.5f); // the delay ends at 0.625; the next step lands one full period after that frame
			TestFalse(TEXT("The delay ends"), F->ASC().HasMatchingGameplayTag(Delayed));
			TestEqual(TEXT("Recovery resumes one period after the delay, not at once"), Endurance(F->ASC()), 22.0f);
		},
		[this, F]
		{
			F->Tick(1.0f);
			TestEqual(TEXT("After the delay Endurance recovers at the configured rate"), Endurance(F->ASC()), 26.0f);
		},
		[this, F, Commit, Delayed]
		{
			F->Tick(0.0f);
			TestEqual(TEXT("A second commit is accepted"), Commit(2), EResult::Accepted);
			TestEqual(TEXT("A third commit is accepted"), Commit(3), EResult::Accepted);
			TestEqual(TEXT("They spend 16 more"), Endurance(F->ASC()), 10.0f);
			TestEqual(TEXT("Back-to-back commits restart the delay rather than stacking it"), CountWithTag(F->ASC(), Delayed), 1);
		},
		[this, F]
		{
			F->Tick(0.5f);
			TestEqual(TEXT("The restarted delay pauses recovery again"), Endurance(F->ASC()), 10.0f);
		},
	}));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnRecoveryDelayAfterGuardPressureTest,
	"Aetheln.GameCombat.Recovery.DelayAfterGuardPressure",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnRecoveryDelayAfterGuardPressureTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDefenseTests;
	using AethelnResourceRecoveryTests::FFrameSteps;
	using AethelnResourceRecoveryTests::MakeTestRecovery;
	using AethelnResourceRecoveryTests::CountWithTag;
	const TSharedRef<FDefense> F = MakeShared<FDefense>();
	if (!F->Init(*this)) { return false; }
	AAethelnCombatAICharacter* First = F->SpawnEnemy(*this);
	AAethelnCombatAICharacter* Second = F->SpawnEnemy(*this);
	if (First == nullptr || Second == nullptr) { return false; }
	F->AdvanceTo(1.0); // the frame's one timer tick, before recovery starts, so its period timer starts at once
	TestTrue(TEXT("Guard recovery starts"), UAethelnResourceRecoveryEffect::Start(F->ASC(), UAethelnGuardRecoveryEffect::StaticClass(), MakeTestRecovery()).IsValid());
	TestEqual(TEXT("Raised"), F->Raise(), EResult::Accepted);
	F->AdvanceTo(1.0625);
	F->Swing(*First, 5.0f);
	F->AdvanceTo(1.25);
	const FGameplayTag Delayed = AethelnGameplayTags::State_GuardRecoveryDelayed;
	TestEqual(TEXT("Pressure lowers Guard"), F->Guard(), 15.0f);
	TestTrue(TEXT("Pressure starts the Guard delay"), F->Has(Delayed));
	const TArray<float> Durations = F->ASC().GetActiveEffectsDuration(FGameplayEffectQuery::MakeQuery_MatchAnyOwningTags(FGameplayTagContainer(Delayed)));
	if (TestEqual(TEXT("One delay effect"), Durations.Num(), 1)) { TestEqual(TEXT("It lasts the configured delay"), Durations[0], 0.625f); }

	ADD_LATENT_AUTOMATION_COMMAND(FFrameSteps({
		[this, F]
		{
			F->AdvanceTo(F->Now() + 0.25);
			TestEqual(TEXT("No Guard recovery during the delay"), F->Guard(), 15.0f);
		},
		[this, F, Second, Delayed]
		{
			F->AdvanceTo(F->Now() + 0.25);
			F->Swing(*Second, 2.0f, 2);
			F->AdvanceTo(F->Now() + 0.1875); // a second World->Tick in this frame resolves the contact; timers do not tick again
			TestEqual(TEXT("More pressure"), F->Guard(), 13.0f);
			TestEqual(TEXT("It restarts the delay rather than stacking it"), CountWithTag(F->ASC(), Delayed), 1);
		},
		[this, F]
		{
			F->AdvanceTo(F->Now() + 0.5);
			TestEqual(TEXT("Past the first delay's end, the restarted delay still pauses recovery"), F->Guard(), 13.0f);
		},
		[this, F, Delayed]
		{
			F->AdvanceTo(F->Now() + 0.5);
			TestFalse(TEXT("The restarted delay ends"), F->Has(Delayed));
		},
		[this, F]
		{
			const float Before = F->Guard();
			F->AdvanceTo(F->Now() + 1.0);
			TestEqual(TEXT("After the delay Guard recovers at the configured rate"), F->Guard(), Before + 4.0f);
		},
		[this, F]
		{
			F->AdvanceTo(F->Now() + 10.0);
			TestEqual(TEXT("Cap: Guard stops at its maximum"), F->Guard(), 20.0f);
		},
	}));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnRecoveryAfterGuardBreakTest,
	"Aetheln.GameCombat.Recovery.AfterGuardBreak",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnRecoveryAfterGuardBreakTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDefenseTests;
	using AethelnResourceRecoveryTests::FFrameSteps;
	using AethelnResourceRecoveryTests::MakeTestRecovery;
	const TSharedRef<FDefense> F = MakeShared<FDefense>();
	if (!F->Init(*this)) { return false; }
	AAethelnCombatAICharacter* Enemy = F->SpawnEnemy(*this);
	if (Enemy == nullptr) { return false; }
	F->AdvanceTo(1.0);
	UAethelnResourceRecoveryEffect::Start(F->ASC(), UAethelnGuardRecoveryEffect::StaticClass(), MakeTestRecovery());
	TestEqual(TEXT("Raised"), F->Raise(), EResult::Accepted);
	F->AdvanceTo(1.0625);
	F->Swing(*Enemy, 20.0f); // all of Guard: the break
	F->AdvanceTo(1.25);
	TestEqual(TEXT("Guard is zero"), F->Guard(), 0.0f);
	TestTrue(TEXT("State.GuardBroken holds"), F->Has(AethelnGameplayTags::State_GuardBroken));
	TestTrue(TEXT("The breaking pressure starts the Guard delay like any other"), F->Has(AethelnGameplayTags::State_GuardRecoveryDelayed));

	ADD_LATENT_AUTOMATION_COMMAND(FFrameSteps({
		[this, F]
		{
			F->AdvanceTo(F->Now() + 1.0); // both the break (0.5) and the delay (0.625) end in this frame
			TestFalse(TEXT("The break ends"), F->Has(AethelnGameplayTags::State_GuardBroken));
			TestFalse(TEXT("The delay ends"), F->Has(AethelnGameplayTags::State_GuardRecoveryDelayed));
		},
		[this, F]
		{
			F->AdvanceTo(F->Now() + 1.0);
			TestTrue(TEXT("Guard recovers after a break"), F->Guard() > 0.0f);
			F->ClearCooldowns();
			TestEqual(TEXT("With Guard recovered, the block rises again"), F->Raise(), EResult::Accepted);
		},
	}));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnRecoveryLifecycleTest,
	"Aetheln.GameCombat.Recovery.RespawnAndReconnect",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnRecoveryLifecycleTest::RunTest(const FString& Parameters)
{
	using namespace AethelnResourceRecoveryTests;
	const TSharedRef<FRecoveryPlayer> F = MakeShared<FRecoveryPlayer>();
	if (!F->Init(*this)) { return false; }
	AAethelnPlayerCharacter* Respawned = F->World.Spawn<AAethelnPlayerCharacter>();
	if (!TestNotNull(TEXT("Second pawn exists"), Respawned)) { return false; }

	// Re-possession (for example #21's respawn) never starts a second recovery.
	F->Player.Controller->UnPossess();
	F->Player.Controller->Possess(Respawned);
	TestEqual(TEXT("Re-possession: one Endurance recovery"), CountActive(F->ASC(), UAethelnEnduranceRecoveryEffect::StaticClass()), 1);
	TestEqual(TEXT("Re-possession: one Guard recovery"), CountActive(F->ASC(), UAethelnGuardRecoveryEffect::StaticClass()), 1);

	// Reconnect: AGameModeBase gives a fresh PlayerState; the old one, and its recovery, is destroyed.
	UAethelnResourceRecoveryEffect::RestartDelay(F->ASC(), UAethelnEnduranceRecoveryEffect::StaticClass());
	TestTrue(TEXT("The old PlayerState holds an Endurance delay"), F->ASC().HasMatchingGameplayTag(AethelnGameplayTags::State_EnduranceRecoveryDelayed));
	F->Player.Controller->UnPossess();
	AAethelnPlayerState* Old = F->Player.PlayerState;
	AAethelnPlayerState* Fresh = AttachFreshPlayerState(F->World, *F->Player.Controller);
	if (!TestNotNull(TEXT("Fresh PlayerState exists"), Fresh)) { return false; }
	Fresh->ProvisionalEnduranceRecovery = MakeTestRecovery();
	Fresh->ProvisionalGuardRecovery = MakeTestRecovery();
	Old->Destroy();
	F->Player.PlayerState = Fresh;
	F->Player.AbilitySystem = Fresh->GetAethelnAbilitySystemComponent();
	F->Player.Controller->Possess(Respawned);
	UAethelnAbilitySystemComponent& ASC = F->ASC();
	TestEqual(TEXT("Reconnect: one Endurance recovery"), CountActive(ASC, UAethelnEnduranceRecoveryEffect::StaticClass()), 1);
	TestEqual(TEXT("Reconnect: one Guard recovery"), CountActive(ASC, UAethelnGuardRecoveryEffect::StaticClass()), 1);
	TestFalse(TEXT("Reconnect: no delay carries over"), ASC.HasMatchingGameplayTag(AethelnGameplayTags::State_EnduranceRecoveryDelayed));
	ApplyInstantModifier(ASC, UAethelnCombatAttributeSet::GetEnduranceAttribute(), EGameplayModOp::AddBase, -10.0f);

	ADD_LATENT_AUTOMATION_COMMAND(FFrameSteps({
		[this, F]
		{
			F->Tick(1.0f);
			TestEqual(TEXT("Reconnect: one rate, not two"), Endurance(F->ASC()), 24.0f);
			F->Player.Controller->UnPossess();
		},
		[this, F]
		{
			F->Tick(1.0f);
			TestEqual(TEXT("With no avatar, recovery continues on the server clock"), Endurance(F->ASC()), 28.0f);
		},
	}));
	return true;
}

#endif
