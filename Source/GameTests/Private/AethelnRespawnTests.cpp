#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatAICharacter.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatEffects.h"
#include "AethelnCombatGameMode.h"
#include "AethelnDeathSubsystem.h"
#include "AethelnDefenseTestFixture.h"
#include "AethelnGameplayTags.h"
#include "AethelnLocalPlayer.h"
#include "AethelnObservability.h"
#include "AethelnObservabilitySubsystem.h"
#include "AethelnPlayerCharacter.h"
#include "AethelnPlayerController.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "GameFramework/GameModeBase.h"
#include "GameFramework/GameSession.h"
#include "GameFramework/WorldSettings.h"
#include "Misc/AutomationTest.h"
#include <limits>

// #21 P2 server respawn (docs/death-and-respawn.md, Test Plan). Rows implemented here: R3 RespawnFailsClosed,
// R4 RespawnAfterDelay, R7 GuardBreakThenDeath, R8 RespawnRefusesNonDeadAndNonPlayer, R9 LethalContactThenRespawn,
// and R10 DeathTelemetry. P4 and P4b add the reconnect rows (R6, R11) at the end of the file. The delay is set on the subsystem instance: TestDelay is a fixture value, never the
// provisional ini value. The harness registers no game mode, so the tests install the combat game mode through
// UWorld::SetGameMode, as a server's map load does.
namespace AethelnRespawnTests
{
	using namespace AethelnChainTests;
	using EResult = EAethelnActivationResult;

	constexpr float TestDelay = 2.0f;

	void ZeroHealth(UAethelnAbilitySystemComponent& AbilitySystem)
	{
		AethelnCombatTests::ApplyInstantModifier(AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::Override, 0.0f);
	}

	/** The lethal notification the timeline raises, for a player with zero Health. */
	void Kill(FFixture& F, const FGuid& ActivationId, double ContactTime)
	{
		ZeroHealth(*F.Player.AbilitySystem);
		F.Timeline->OnLethalResult.Broadcast(F.Player.AbilitySystem, ActivationId, ContactTime);
	}

	int32 CountActive(const UAbilitySystemComponent& AbilitySystem, TSubclassOf<UGameplayEffect> Effect)
	{
		FGameplayEffectQuery Query;
		Query.EffectDefinition = Effect;
		return AbilitySystem.GetActiveEffects(Query).Num();
	}

	float Read(const UAbilitySystemComponent& AbilitySystem, const FGameplayAttribute& Attribute)
	{
		return AbilitySystem.GetNumericAttribute(Attribute);
	}

	/** The combat game mode as the world's authority, with the plain player character as its pawn. */
	bool InstallGameMode(FAutomationTestBase& Test, UWorld& World)
	{
		World.GetWorldSettings()->DefaultGameMode = AAethelnCombatGameMode::StaticClass();
		if (!Test.TestTrue(TEXT("The world takes the combat game mode"), World.SetGameMode(FURL()))) { return false; }
		AAethelnCombatGameMode* GameMode = World.GetAuthGameMode<AAethelnCombatGameMode>();
		if (!Test.TestNotNull(TEXT("The combat game mode is the world's authority"), GameMode)) { return false; }
		// The configured input-enabled Blueprint pawn is not this test's subject.
		GameMode->InputEnabledPawnClass.Reset();
		GameMode->DefaultPawnClass = AAethelnPlayerCharacter::StaticClass();
		return true;
	}

	/** An enemy dummy with the fixture chain granted, so its directly registered steps pass the content-version check. */
	AAethelnCombatAICharacter* SpawnEnemy(FAutomationTestBase& Test, const FFixture& F, const FVector& Location)
	{
		AAethelnCombatAICharacter* Enemy = F.SpawnTarget(Test, Location);
		if (Enemy != nullptr) { Enemy->GetAethelnAbilitySystemComponent()->GiveAbility(FGameplayAbilitySpec(UAethelnChainTestAbility::StaticClass(), 1)); }
		return Enemy;
	}

	/** Registers one enemy step starting now, aimed at the player. Returns its activation id. */
	FGuid Swing(const FFixture& F, AAethelnCombatAICharacter& Enemy, float Damage)
	{
		const UAethelnChainTestAbility* Chain = GetDefault<UAethelnChainTestAbility>();
		FAethelnAttackStepDefinition Step = Chain->ProvisionalSteps[0];
		Step.WroughtDamage = Damage;
		FAethelnCombatActivationRecord Record;
		Record.ActivationId = FGuid::NewGuid();
		Record.Sequence = 1;
		Record.AbilityId = AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain;
		Record.ContentVersion = Chain->ContentVersion;
		Record.ChainStep = 1;
		Record.StartServerTime = F.World.World->GetTimeSeconds();
		Record.AcceptedAim = (F.Pawn->GetActorLocation() - Enemy.GetActorLocation()).GetSafeNormal();
		return F.Timeline->RegisterStep(*Enemy.GetAethelnAbilitySystemComponent(), Step, Record, Chain->ProvisionalMaxSampleDistance, Chain->ProvisionalMaxSampleAngleDegrees)
			? Record.ActivationId : FGuid();
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnRespawnAfterDelayTest,
	"Aetheln.GameCombat.Death.RespawnAfterDelay",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnRespawnAfterDelayTest::RunTest(const FString& Parameters)
{
	using namespace AethelnRespawnTests;
	FFixture F(true); if (!F.Init(*this)) { return false; }
	UAethelnDeathSubsystem* Deaths = F.World.World->GetSubsystem<UAethelnDeathSubsystem>();
	if (!TestNotNull(TEXT("The authority world owns the death subsystem"), Deaths) || !InstallGameMode(*this, *F.World.World)) { return false; }
	Deaths->ProvisionalRespawnDelaySeconds = TestDelay;
	UAethelnAbilitySystemComponent& Victim = *F.Player.AbilitySystem;
	const FGameplayAttribute HealthAttribute = UAethelnCombatAttributeSet::GetHealthAttribute();
	const FGameplayAttribute EnduranceAttribute = UAethelnCombatAttributeSet::GetEnduranceAttribute();
	const FGameplayAttribute GuardAttribute = UAethelnCombatAttributeSet::GetGuardAttribute();
	const AethelnCombatTests::FTestPlayer& Player = F.Player;
	const TWeakObjectPtr<APawn> DeadPawn(F.Pawn);
	const int32 GrantedBefore = Victim.GetActivatableAbilities().Num();

	// A cooldown that outlasts the delay, spent Guard and Endurance, and a running chain: respawn restores the three
	// resources and nothing else.
	FGameplayEffectSpec Cooldown(GetDefault<UAethelnCooldownEffect>(), Victim.MakeEffectContext(), 1.0f);
	Cooldown.SetSetByCallerMagnitude(AethelnGameplayTags::SetByCaller_Cooldown_Duration, 20.0f);
	Cooldown.DynamicGrantedTags.AddTag(AethelnGameplayTags::Cooldown_Block);
	Victim.ApplyGameplayEffectSpecToSelf(Cooldown);
	AethelnCombatTests::ApplyInstantModifier(Victim, GuardAttribute, EGameplayModOp::AddBase, -5.0f);
	TestEqual(TEXT("The chain starts"), F.Press(), EResult::Accepted);
	F.AdvanceTo(0.15);
	TestTrue(TEXT("The fixture holds a spent resource"), Read(Victim, EnduranceAttribute) < 30.0f);

	// The lethal contact was earlier than the processing time: the chain ends at the contact time (P2).
	Kill(F, FGuid::NewGuid(), 0.1);
	TestTrue(TEXT("The player is dead"), Victim.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestEqual(TEXT("The chain reset is stamped at the lethal contact time, not the processing time"), Victim.GetLastChainResetTimeForTests(), 0.1);
	TestEqual(TEXT("Death ends the chain once"), F.Ends.Num(), 1);

	// R3: nothing happens before the deadline (death time plus the delay), and no client input is involved.
	F.AdvanceTo(0.15 + TestDelay - 0.1);
	TestTrue(TEXT("Still dead before the delay"), Victim.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestTrue(TEXT("The dead pawn is still possessed"), Player.Controller->GetPawn() == F.Pawn);
	TestEqual(TEXT("Health stays at zero"), Read(Victim, HealthAttribute), 0.0f);
	TestEqual(TEXT("The cooldown effect stays through death"), CountActive(Victim, UAethelnCooldownEffect::StaticClass()), 1);

	F.AdvanceTo(0.15 + TestDelay + 0.1);
	TestFalse(TEXT("State.Dead is gone after the delay"), Victim.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestEqual(TEXT("The death effect is removed"), CountActive(Victim, UAethelnDeathStateEffect::StaticClass()), 0);

	// R4: exactly the three resources are at their maxima, and the maxima did not move.
	TestEqual(TEXT("Health is restored to its maximum"), Read(Victim, HealthAttribute), 40.0f);
	TestEqual(TEXT("Endurance is restored to its maximum"), Read(Victim, EnduranceAttribute), 30.0f);
	TestEqual(TEXT("Guard is restored to its maximum"), Read(Victim, GuardAttribute), 20.0f);
	TestEqual(TEXT("MaxHealth is unchanged"), Read(Victim, UAethelnCombatAttributeSet::GetMaxHealthAttribute()), 40.0f);
	TestEqual(TEXT("MaxEndurance is unchanged"), Read(Victim, UAethelnCombatAttributeSet::GetMaxEnduranceAttribute()), 30.0f);
	TestEqual(TEXT("MaxGuard is unchanged"), Read(Victim, UAethelnCombatAttributeSet::GetMaxGuardAttribute()), 20.0f);

	// A new pawn is possessed and the corpse is destroyed.
	APawn* NewPawn = Player.Controller->GetPawn();
	if (!TestNotNull(TEXT("The player has a new pawn"), NewPawn)) { return false; }
	TestFalse(TEXT("The corpse is destroyed"), DeadPawn.IsValid());
	TestTrue(TEXT("The new pawn is the game mode's pawn class"), NewPawn->IsA<AAethelnPlayerCharacter>());
	TestTrue(TEXT("The new pawn is the ability avatar"), Victim.GetAvatarActor() == NewPawn);
	if (const ACharacter* Character = Cast<ACharacter>(NewPawn))
	{
		TestNotEqual(TEXT("The new pawn can move"), static_cast<int32>(Character->GetCharacterMovement()->MovementMode), static_cast<int32>(MOVE_None));
	}

	// Abilities are never granted again, and the cooldown kept counting from its original start.
	TestEqual(TEXT("No ability is granted again"), Victim.GetActivatableAbilities().Num(), GrantedBefore);
	FGameplayEffectQuery CooldownQuery;
	CooldownQuery.EffectDefinition = UAethelnCooldownEffect::StaticClass();
	const TArray<float> Remaining = Victim.GetActiveEffectsTimeRemaining(CooldownQuery);
	if (TestEqual(TEXT("The cooldown effect survived death and respawn"), Remaining.Num(), 1))
	{
		TestEqual(TEXT("The cooldown was neither reset nor paused"), Remaining[0], 20.0f - static_cast<float>(F.World.World->GetTimeSeconds()), 0.01f);
	}

	// Stale state from the previous life (DoD3).
	TestFalse(TEXT("No chain survives"), Victim.GetChainStateForTests().bExists);
	TestEqual(TEXT("Respawn added no second chain end"), F.Ends.Num(), 1);
	TestFalse(TEXT("No dodge window survives"), Victim.GetDodgeWindowForTests().bOpen);
	for (const FGameplayTag& Tag : { AethelnGameplayTags::State_Dodging.GetTag(), AethelnGameplayTags::State_DodgeInvulnerable.GetTag(),
		AethelnGameplayTags::State_Blocking.GetTag(), AethelnGameplayTags::State_GuardBroken.GetTag(), AethelnGameplayTags::State_Oathscar_SwordShieldBasicChain.GetTag() })
	{
		TestFalse(*FString::Printf(TEXT("%s is not held after respawn"), *Tag.ToString()), Victim.HasMatchingGameplayTag(Tag));
	}
	TestEqual(TEXT("The timeline tracks no step of the previous life"), F.Timeline->GetRegisteredStepCountForTests(), 0);

	// One respawn per death: a second request, and a long wait, change nothing.
	TestFalse(TEXT("A second respawn is refused"), UAethelnDeathSubsystem::Respawn(Victim));
	F.AdvanceTo(8.0);
	TestTrue(TEXT("The new pawn stays the player's pawn"), Player.Controller->GetPawn() == NewPawn);

	// The player rejoins combat on the new avatar.
	TestEqual(TEXT("The respawned player can start a chain"), F.Press(), EResult::Accepted);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnRespawnFailsClosedTest,
	"Aetheln.GameCombat.Death.RespawnFailsClosed",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnRespawnFailsClosedTest::RunTest(const FString& Parameters)
{
	using namespace AethelnRespawnTests;
	constexpr float NaN = std::numeric_limits<float>::quiet_NaN();
	constexpr float Infinity = std::numeric_limits<float>::infinity();
	const float IniDelay = GetDefault<UAethelnDeathSubsystem>()->ProvisionalRespawnDelaySeconds;
	TestTrue(TEXT("The ini sets a finite, positive provisional respawn delay"), FMath::IsFinite(IniDelay) && IniDelay > 0.0f);

	// An unset, negative or non-finite delay means no respawn: the player stays dead and the server says why, once for
	// each of the four deaths. One expectation counts all four: a repeated AddExpectedError with the same pattern
	// replaces the earlier entry and its count.
	AddExpectedError(TEXT("Refused to schedule a respawn"), EAutomationExpectedErrorFlags::Contains, 4);
	for (const float Delay : { 0.0f, -1.0f, NaN, Infinity })
	{
		FFixture F(true); if (!F.Init(*this)) { return false; }
		UAethelnDeathSubsystem* Deaths = F.World.World->GetSubsystem<UAethelnDeathSubsystem>();
		if (!TestNotNull(TEXT("The authority world owns the death subsystem"), Deaths) || !InstallGameMode(*this, *F.World.World)) { return false; }
		Deaths->ProvisionalRespawnDelaySeconds = Delay;
		Kill(F, FGuid::NewGuid(), 0.0);
		F.AdvanceTo(9.0);
		F.AdvanceTo(18.0);
		TestTrue(TEXT("An invalid delay leaves the player dead"), F.Player.AbilitySystem->HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
		TestTrue(TEXT("The dead pawn stays possessed"), F.Player.Controller->GetPawn() == F.Pawn);
	}

	// A world with no game mode cannot restart a player: one refusal at the deadline, then nothing more.
	{
		FFixture F(true); if (!F.Init(*this)) { return false; }
		UAethelnDeathSubsystem* Deaths = F.World.World->GetSubsystem<UAethelnDeathSubsystem>();
		if (!TestNotNull(TEXT("The authority world owns the death subsystem"), Deaths)) { return false; }
		Deaths->ProvisionalRespawnDelaySeconds = TestDelay;
		AddExpectedError(TEXT("the world has no game mode"), EAutomationExpectedErrorFlags::Contains, 1);
		Kill(F, FGuid::NewGuid(), 0.0);
		F.AdvanceTo(2.5);
		F.AdvanceTo(9.0);
		TestTrue(TEXT("Without a game mode the player stays dead"), F.Player.AbilitySystem->HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
		TestTrue(TEXT("The dead pawn stays possessed"), F.Player.Controller->GetPawn() == F.Pawn);
		TestEqual(TEXT("Nothing was restored"), Read(*F.Player.AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute()), 0.0f);
	}

	// A maximum Health of zero would respawn a living avatar with zero Health: refused.
	{
		FFixture F(true); if (!F.Init(*this)) { return false; }
		UAethelnDeathSubsystem* Deaths = F.World.World->GetSubsystem<UAethelnDeathSubsystem>();
		if (!TestNotNull(TEXT("The authority world owns the death subsystem"), Deaths) || !InstallGameMode(*this, *F.World.World)) { return false; }
		Deaths->ProvisionalRespawnDelaySeconds = TestDelay;
		AethelnCombatTests::ApplyInstantModifier(*F.Player.AbilitySystem, UAethelnCombatAttributeSet::GetMaxHealthAttribute(), EGameplayModOp::Override, 0.0f);
		AddExpectedError(TEXT("MaxHealth is not above zero"), EAutomationExpectedErrorFlags::Contains, 1);
		Kill(F, FGuid::NewGuid(), 0.0);
		F.AdvanceTo(2.5);
		TestTrue(TEXT("A zero maximum Health leaves the player dead"), F.Player.AbilitySystem->HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
		TestTrue(TEXT("The dead pawn stays possessed"), F.Player.Controller->GetPawn() == F.Pawn);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnRespawnRefusesNonDeadAndNonPlayerTest,
	"Aetheln.GameCombat.Death.RespawnRefusesNonDeadAndNonPlayer",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnRespawnRefusesNonDeadAndNonPlayerTest::RunTest(const FString& Parameters)
{
	using namespace AethelnRespawnTests;
	FFixture F(true); if (!F.Init(*this)) { return false; }
	UAethelnDeathSubsystem* Deaths = F.World.World->GetSubsystem<UAethelnDeathSubsystem>();
	if (!TestNotNull(TEXT("The authority world owns the death subsystem"), Deaths) || !InstallGameMode(*this, *F.World.World)) { return false; }
	Deaths->ProvisionalRespawnDelaySeconds = TestDelay;
	UAethelnAbilitySystemComponent& Victim = *F.Player.AbilitySystem;
	const FGameplayAttribute HealthAttribute = UAethelnCombatAttributeSet::GetHealthAttribute();

	// A living player is not respawned: no pawn change, no restoration.
	AethelnCombatTests::ApplyInstantModifier(Victim, HealthAttribute, EGameplayModOp::Override, 10.0f);
	TestFalse(TEXT("A living player is refused"), UAethelnDeathSubsystem::Respawn(Victim));
	TestTrue(TEXT("The living player keeps its pawn"), F.Player.Controller->GetPawn() == F.Pawn);
	TestEqual(TEXT("The living player's Health is untouched"), Read(Victim, HealthAttribute), 10.0f);
	TestFalse(TEXT("A living player cannot die from a non-contact request"), UAethelnDeathSubsystem::ApplyDeath(Victim));

	// A dead AI is not a player: only the owner rule refuses it (it holds State.Dead and Health 0).
	AAethelnCombatAICharacter* Dummy = F.SpawnTarget(*this, FVector(300.0, 0.0, 0.0));
	if (Dummy == nullptr) { return false; }
	UAethelnAbilitySystemComponent& Ai = *Dummy->GetAethelnAbilitySystemComponent();
	ZeroHealth(Ai);
	Ai.AddLooseGameplayTag(AethelnGameplayTags::State_Dead);
	TestFalse(TEXT("A non-player owner is refused"), UAethelnDeathSubsystem::Respawn(Ai));
	TestTrue(TEXT("The AI keeps State.Dead"), Ai.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestEqual(TEXT("The AI's Health is untouched"), Read(Ai, HealthAttribute), 0.0f);

	// A death from any server code (no contact) starts the same wait and the same single respawn.
	ZeroHealth(Victim);
	TestTrue(TEXT("A non-contact death is accepted"), UAethelnDeathSubsystem::ApplyDeath(Victim));
	TestFalse(TEXT("A second death request is a no-op"), UAethelnDeathSubsystem::ApplyDeath(Victim));
	TestEqual(TEXT("One death effect"), CountActive(Victim, UAethelnDeathStateEffect::StaticClass()), 1);
	F.AdvanceTo(TestDelay - 0.1);
	TestTrue(TEXT("The non-contact death is still dead before the delay"), Victim.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestTrue(TEXT("The dead pawn is still possessed before the delay"), F.Player.Controller->GetPawn() == F.Pawn);
	F.AdvanceTo(TestDelay + 0.5);
	TestFalse(TEXT("The non-contact death respawns after the delay"), Victim.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestEqual(TEXT("Health is restored"), Read(Victim, HealthAttribute), 40.0f);
	TestTrue(TEXT("The player has a new pawn"), F.Player.Controller->GetPawn() != nullptr && F.Player.Controller->GetPawn() != F.Pawn);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnLethalContactThenRespawnTest,
	"Aetheln.GameCombat.Death.LethalContactThenRespawn",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnLethalContactThenRespawnTest::RunTest(const FString& Parameters)
{
	using namespace AethelnRespawnTests;
	FFixture F(true); if (!F.Init(*this)) { return false; }
	UAethelnDeathSubsystem* Deaths = F.World.World->GetSubsystem<UAethelnDeathSubsystem>();
	if (!TestNotNull(TEXT("The authority world owns the death subsystem"), Deaths) || !InstallGameMode(*this, *F.World.World)) { return false; }
	Deaths->ProvisionalRespawnDelaySeconds = TestDelay;
	UAethelnAbilitySystemComponent& Victim = *F.Player.AbilitySystem;
	// Fixture geometry from the interruption tests: an enemy 60 units behind first touches the player's capsule well before 0.5.
	AAethelnCombatAICharacter* Enemy = SpawnEnemy(*this, F, FVector(-60.0, 0.0, 0.0));
	if (Enemy == nullptr) { return false; }

	TestEqual(TEXT("The chain starts"), F.Press(), EResult::Accepted);
	const FGuid EnemyId = Swing(F, *Enemy, 40.0f);
	F.AdvanceTo(0.5);
	const FAethelnCombatResult* Result = F.Results.FindByPredicate([&EnemyId](const FAethelnCombatResult& Item) { return Item.ActivationId == EnemyId; });
	if (!TestNotNull(TEXT("The enemy contact commits a result"), Result)) { return false; }
	TestTrue(TEXT("The result is lethal"), Result->bLethal);
	TestTrue(TEXT("The contact was before the processing time"), Result->ContactTime < 0.5);
	TestTrue(TEXT("The real lethal path kills the player"), Victim.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestEqual(TEXT("The chain ended once, at the lethal contact time"), Victim.GetLastChainResetTimeForTests(), Result->ContactTime);
	TestEqual(TEXT("Death ends the chain once"), F.Ends.Num(), 1);

	F.AdvanceTo(0.5 + TestDelay - 0.1);
	TestTrue(TEXT("Still dead before the delay"), Victim.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	F.AdvanceTo(0.5 + TestDelay + 0.1);
	TestFalse(TEXT("Respawned after the delay"), Victim.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestEqual(TEXT("Health is restored to its maximum"), Read(Victim, UAethelnCombatAttributeSet::GetHealthAttribute()), 40.0f);
	TestEqual(TEXT("Respawn added no second chain end"), F.Ends.Num(), 1);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnGuardBreakThenDeathTest,
	"Aetheln.GameCombat.Death.GuardBreakThenDeath",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnGuardBreakThenDeathTest::RunTest(const FString& Parameters)
{
	// R7: a real Guard break, then death. Geometry and times are the Guard break test's (Aetheln.GameCombat.Defense.GuardBreak).
	using namespace AethelnRespawnTests;
	AethelnDefenseTests::FDefense F;
	if (!F.Init(*this)) { return false; }
	AAethelnCombatAICharacter* Enemy = F.SpawnEnemy(*this);
	if (Enemy == nullptr) { return false; }
	// A running Guard recovery (fixture values, not tuning), so its pause by death is observable.
	FAethelnResourceRecoveryValues Recovery;
	Recovery.RatePerSecond = 1.0f;
	Recovery.PeriodSeconds = 1.0f;
	TestTrue(TEXT("Guard recovery starts"), UAethelnResourceRecoveryEffect::Start(F.ASC(), UAethelnGuardRecoveryEffect::StaticClass(), Recovery).IsValid());

	F.AdvanceTo(1.0);
	TestEqual(TEXT("Raised"), F.Raise(), EResult::Accepted);
	F.AdvanceTo(1.0625);
	const FGuid Breaking = F.Swing(*Enemy, 20.0f); // at Guard (20): the break
	F.AdvanceTo(1.25);
	const FAethelnCombatResult* BreakResult = F.ResultFor(Breaking);
	if (!TestNotNull(TEXT("The breaking contact resolved"), BreakResult)) { return false; }
	TestEqual(TEXT("The contact broke the Guard"), BreakResult->Outcome, EAethelnCombatResultOutcome::GuardBroken);
	TestTrue(TEXT("State.GuardBroken holds before death"), F.Has(AethelnGameplayTags::State_GuardBroken));
	TestEqual(TEXT("Guard is zero"), F.Guard(), 0.0f);
	// The break does not refuse an attack, so a chain runs when death arrives.
	TestEqual(TEXT("A chain starts during the break"), F.Attack(), EResult::Accepted);
	const int32 EndsBefore = F.ChainEnds.Num();

	AethelnCombatTests::ApplyInstantModifier(F.ASC(), UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::Override, 0.0f);
	F.Timeline->OnLethalResult.Broadcast(&F.ASC(), FGuid::NewGuid(), F.Now());

	TestTrue(TEXT("The player is dead"), F.Has(AethelnGameplayTags::State_Dead));
	TestEqual(TEXT("State.Dead is held once"), F.ASC().GetTagCount(AethelnGameplayTags::State_Dead), 1);
	TestEqual(TEXT("One death effect"), CountActive(F.ASC(), UAethelnDeathStateEffect::StaticClass()), 1);
	TestFalse(TEXT("The break effect is gone"), F.Has(AethelnGameplayTags::State_GuardBroken));
	TestEqual(TEXT("No break tag is held"), F.ASC().GetTagCount(AethelnGameplayTags::State_GuardBroken), 0);
	TestEqual(TEXT("Death does not refill Guard"), F.Guard(), 0.0f);
	if (TestEqual(TEXT("Death ends the running chain once"), F.ChainEnds.Num(), EndsBefore + 1))
	{
		TestEqual(TEXT("The chain ends as IncompatibleState"), F.ChainEnds.Last(), EAethelnChainEndReason::IncompatibleState);
	}

	// Guard recovery stays paused by State.Dead: the effect is kept and inhibited.
	FGameplayEffectQuery RecoveryQuery;
	RecoveryQuery.EffectDefinition = UAethelnGuardRecoveryEffect::StaticClass();
	const TArray<FActiveGameplayEffectHandle> Active = F.ASC().GetActiveEffects(RecoveryQuery);
	if (TestEqual(TEXT("Guard recovery is kept"), Active.Num(), 1))
	{
		const FActiveGameplayEffect* Effect = F.ASC().GetActiveGameplayEffect(Active[0]);
		TestTrue(TEXT("Guard recovery is paused while dead"), Effect != nullptr && Effect->bIsInhibited);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDeathEventTest,
	"Aetheln.GameCombat.Death.DeathTelemetry",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDeathEventTest::RunTest(const FString& Parameters)
{
	using namespace AethelnRespawnTests;
	FFixture F(true); if (!F.Init(*this)) { return false; }
	UAethelnObservabilitySubsystem* Subsystem = F.World.GameInstance != nullptr ? F.World.GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>() : nullptr;
	if (!TestNotNull(TEXT("Observability subsystem exists"), Subsystem)) { return false; }
	TSharedPtr<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe> Sink = MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(64);
	TestTrue(TEXT("Runtime context is set"), Subsystem->SetRuntimeContext(EAethelnFlowKind::PrototypeAuthority, TEXT("run-death-p2-test"), TEXT("instance-death-p2-test"), TEXT("connection-death-p2-test")));
	TestTrue(TEXT("Public sink is set"), Subsystem->SetTestSink(Sink));

	// A death is one event whose activation id is the lethal activation; a repeated notification adds none.
	const FGuid Lethal = FGuid::NewGuid();
	Kill(F, Lethal, 0.0);
	Kill(F, FGuid::NewGuid(), 0.0);
	TestTrue(TEXT("Telemetry drained"), Subsystem->WaitForIdleForTests());
	TArray<FAethelnObservabilityEvent> Deaths;
	for (const FAethelnObservabilityEvent& Event : Sink->GetEvents())
	{
		if (Event.Category == EAethelnObservabilityCategory::Death) { Deaths.Add(Event); }
	}
	if (TestEqual(TEXT("One Death event per death"), Deaths.Num(), 1))
	{
		TestTrue(TEXT("Death subject, accepted reason"), Deaths[0].SubjectCategory == EAethelnObservabilityCategory::Death && Deaths[0].SafeReason == EAethelnSafeReason::Accepted);
		TestEqual(TEXT("Activation id is the lethal activation"), Deaths[0].Correlation.ActivationId, Lethal.ToString(EGuidFormats::DigitsWithHyphensLower));
		TestEqual(TEXT("The first death is life generation 1"), static_cast<int64>(Deaths[0].Correlation.Sequence), static_cast<int64>(1));
		TestEqual(TEXT("No connection or player identity"), Deaths[0].Correlation.ConnectionPseudonym, FString(AethelnObservability::ExcludedIdentifier));
		TestTrue(TEXT("Public channel hides diagnostics"), Deaths[0].DiagnosticCode == EAethelnDiagnosticCode::None);
	}
	Subsystem->ResetSink(); Subsystem->ResetRuntimeContext();
	return true;
}

// #21 P4 and P4b reconnect (docs/death-and-respawn.md, Test Plan R6 and R11). One authority world. The logout is the production
// chain, the controller's destruction: PawnLeavingGame, the game mode's Logout, CleanupPlayerState and OnDeactivated. With a
// reconnect key and a valid grace window, the PlayerState and the pawn stay in the world for the window (P4b). The login is a
// new controller with a fresh PlayerState and the key, started by the game mode's RestartPlayer, which resumes a kept pawn.
// Most tests set the key directly; ReconnectKeyIsClientPresented and ReconnectLoginStampsKey cover its source.
namespace AethelnRespawnTests
{
	/** A fixture value, never the provisional ini value. */
	constexpr float TestGrace = 5.0f;
	const TCHAR* const TestKey = TEXT("player-a-key");

	/** The logout through the controller's destruction. F.Pawn keeps pointing at the pawn the player had. */
	void Disconnect(FFixture& F, const FString& Key)
	{
		F.Player.PlayerState->SetReconnectKey(Key);
		F.Player.Controller->Destroy();
		F.Player.Controller = nullptr;
		F.Player.PlayerState = nullptr;
		F.Player.AbilitySystem = nullptr;
	}

	/**
	 * The login: a new controller and a fresh PlayerState with Key, and the game mode starts the player. Updates F.Player and
	 * F.Pawn. BeforeStart runs on the fresh ASC before the game mode starts the player, so a test can observe the restore itself.
	 */
	bool Reconnect(FAutomationTestBase& Test, FFixture& F, const FString& Key, TFunctionRef<void(UAethelnAbilitySystemComponent&)> BeforeStart = [](UAethelnAbilitySystemComponent&) {})
	{
		F.Player.Controller = F.World.Spawn<AAethelnPlayerController>();
		if (!Test.TestNotNull(TEXT("The new connection's controller exists"), F.Player.Controller)) { return false; }
		F.Player.PlayerState = AethelnCombatTests::AttachFreshPlayerState(F.World, *F.Player.Controller, { UAethelnChainTestAbility::StaticClass() });
		if (!Test.TestNotNull(TEXT("The fresh PlayerState exists"), F.Player.PlayerState)) { return false; }
		F.Player.PlayerState->SetReconnectKey(Key);
		F.Player.AbilitySystem = F.Player.PlayerState->GetAethelnAbilitySystemComponent();
		BeforeStart(*F.Player.AbilitySystem);
		F.World.World->GetAuthGameMode()->RestartPlayer(F.Player.Controller);
		F.Pawn = Cast<AAethelnPlayerCharacter>(F.Player.Controller->GetPawn());
		return Test.TestNotNull(TEXT("The game mode starts the reconnected player with a pawn"), F.Pawn);
	}

	void ApplyTimedState(UAethelnAbilitySystemComponent& Player, const FGameplayTag& Tag, float Seconds)
	{
		FGameplayEffectSpec Spec(GetDefault<UAethelnCooldownEffect>(), Player.MakeEffectContext(), 1.0f);
		Spec.SetSetByCallerMagnitude(AethelnGameplayTags::SetByCaller_Cooldown_Duration, Seconds);
		Spec.DynamicGrantedTags.AddTag(Tag);
		Player.ApplyGameplayEffectSpecToSelf(Spec);
	}

	/** The fixture's world, game mode, and death subsystem with the delay and the grace window set. */
	UAethelnDeathSubsystem* PrepareReconnect(FAutomationTestBase& Test, FFixture& F)
	{
		UAethelnDeathSubsystem* Deaths = F.World.World->GetSubsystem<UAethelnDeathSubsystem>();
		if (!Test.TestNotNull(TEXT("The authority world owns the death subsystem"), Deaths) || !InstallGameMode(Test, *F.World.World)) { return nullptr; }
		Deaths->ProvisionalRespawnDelaySeconds = TestDelay;
		Deaths->ProvisionalDisconnectGraceSeconds = TestGrace;
		return Deaths;
	}

	/** The harness world has no game session, which the game mode's login steps use, so a test supplies one. */
	AAethelnCombatGameMode* GameModeWithSession(FAutomationTestBase& Test, FFixture& F)
	{
		AAethelnCombatGameMode* GameMode = F.World.World->GetAuthGameMode<AAethelnCombatGameMode>();
		if (!Test.TestNotNull(TEXT("The combat game mode is the authority"), GameMode)) { return nullptr; }
		GameMode->GameSession = F.World.World->SpawnActor<AGameSession>();
		return Test.TestNotNull(TEXT("The game mode has a game session"), GameMode->GameSession.Get()) ? GameMode : nullptr;
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnReconnectCarriesLivingStateTest,
	"Aetheln.GameCombat.Death.ReconnectCarriesLivingState",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnReconnectCarriesLivingStateTest::RunTest(const FString& Parameters)
{
	using namespace AethelnRespawnTests;
	FFixture F(true); if (!F.Init(*this)) { return false; }
	UAethelnDeathSubsystem* Deaths = PrepareReconnect(*this, F);
	if (Deaths == nullptr) { return false; }
	UAethelnAbilitySystemComponent& Old = *F.Player.AbilitySystem;

	// Spent resources, a long cooldown, and a short Guard break: a reconnect refills none of them and clears none of them.
	AethelnCombatTests::ApplyInstantModifier(Old, UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::AddBase, -10.0f);
	AethelnCombatTests::ApplyInstantModifier(Old, UAethelnCombatAttributeSet::GetEnduranceAttribute(), EGameplayModOp::AddBase, -12.0f);
	AethelnCombatTests::ApplyInstantModifier(Old, UAethelnCombatAttributeSet::GetGuardAttribute(), EGameplayModOp::AddBase, -7.0f);
	// Maxima that differ from the initial values (40, 30, 20), so a restore from the initial attributes could not pass.
	AethelnCombatTests::ApplyInstantModifier(Old, UAethelnCombatAttributeSet::GetMaxHealthAttribute(), EGameplayModOp::Override, 50.0f);
	AethelnCombatTests::ApplyInstantModifier(Old, UAethelnCombatAttributeSet::GetMaxEnduranceAttribute(), EGameplayModOp::Override, 35.0f);
	AethelnCombatTests::ApplyInstantModifier(Old, UAethelnCombatAttributeSet::GetMaxGuardAttribute(), EGameplayModOp::Override, 25.0f);
	ApplyTimedState(Old, AethelnGameplayTags::Cooldown_Block, 20.0f);
	ApplyTimedState(Old, AethelnGameplayTags::State_GuardBroken, 4.0f);
	ApplyTimedState(Old, AethelnGameplayTags::State_EnduranceRecoveryDelayed, 6.0f);
	// Away from the start spot, so a resume in place differs from a restart.
	const FVector Where(250.0, -80.0, 0.0);
	F.Pawn->SetActorLocation(Where);
	const TWeakObjectPtr<APawn> KeptPawn(F.Pawn);
	const TWeakObjectPtr<AAethelnPlayerState> KeptState(F.Player.PlayerState);

	F.AdvanceTo(1.0);
	Disconnect(F, TestKey);
	TestEqual(TEXT("The logout keeps one player for the grace window"), Deaths->GetCarriedStateCountForTests(), 1);

	// Away for two seconds of server time, inside the grace window.
	F.AdvanceTo(3.0);
	if (!Reconnect(*this, F, TestKey)) { return false; }
	UAethelnAbilitySystemComponent& Player = *F.Player.AbilitySystem;
	TestEqual(TEXT("The reconnect consumed the kept state"), Deaths->GetCarriedStateCountForTests(), 0);
	// P4b: the player resumes the same pawn, where it stood, and the kept PlayerState is gone.
	TestTrue(TEXT("The reconnect resumes the same pawn"), KeptPawn.IsValid() && F.Pawn == KeptPawn.Get());
	TestTrue(TEXT("The resumed pawn is where the player left it"), F.Pawn->GetActorLocation().Equals(Where, 0.01));
	TestFalse(TEXT("The kept PlayerState is removed at the reconnect"), KeptState.IsValid());
	TestTrue(TEXT("The resumed pawn is the fresh ASC's avatar"), Player.GetAvatarActor() == F.Pawn);
	TestTrue(TEXT("The resumed pawn resolves to the fresh ASC"), UAethelnAbilitySystemComponent::FindForPawn(F.Pawn) == &Player);
	TestEqual(TEXT("Health carries over, it is not refilled"), Read(Player, UAethelnCombatAttributeSet::GetHealthAttribute()), 30.0f);
	TestEqual(TEXT("Endurance carries over"), Read(Player, UAethelnCombatAttributeSet::GetEnduranceAttribute()), 18.0f);
	TestEqual(TEXT("Guard carries over"), Read(Player, UAethelnCombatAttributeSet::GetGuardAttribute()), 13.0f);
	TestEqual(TEXT("MaxHealth carries over, not the initial value"), Read(Player, UAethelnCombatAttributeSet::GetMaxHealthAttribute()), 50.0f);
	TestEqual(TEXT("MaxEndurance carries over, not the initial value"), Read(Player, UAethelnCombatAttributeSet::GetMaxEnduranceAttribute()), 35.0f);
	TestEqual(TEXT("MaxGuard carries over, not the initial value"), Read(Player, UAethelnCombatAttributeSet::GetMaxGuardAttribute()), 25.0f);
	TestFalse(TEXT("The player is alive"), Player.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestEqual(TEXT("Abilities are granted once on the new PlayerState"), Player.GetActivatableAbilities().Num(), 1);

	// The timed states kept counting on the server clock while the player was away: 20 s from 0 is 17 s left at 3 s.
	FGameplayEffectQuery TimedQuery;
	TimedQuery.EffectDefinition = UAethelnCooldownEffect::StaticClass();
	TArray<float> Remaining = Player.GetActiveEffectsTimeRemaining(TimedQuery);
	Remaining.Sort();
	if (TestEqual(TEXT("The cooldown, the Guard break and the recovery delay carried over"), Remaining.Num(), 3))
	{
		TestEqual(TEXT("The Guard break has one second left"), Remaining[0], 1.0f, 0.01f);
		TestEqual(TEXT("The recovery delay has three seconds left"), Remaining[1], 3.0f, 0.01f);
		TestEqual(TEXT("The cooldown has 17 seconds left"), Remaining[2], 17.0f, 0.01f);
	}
	TestTrue(TEXT("The recovery delay is not cleansed by the reconnect"), Player.HasMatchingGameplayTag(AethelnGameplayTags::State_EnduranceRecoveryDelayed));
	TestTrue(TEXT("The cooldown tag is held"), Player.HasMatchingGameplayTag(AethelnGameplayTags::Cooldown_Block));
	TestTrue(TEXT("The Guard break is not cleansed by the reconnect"), Player.HasMatchingGameplayTag(AethelnGameplayTags::State_GuardBroken));

	// A death ends the carried Guard break at the death, as it ends a live one, and keeps the cooldown (the effects' timers
	// fire at most once per engine frame, so expiry is not asserted here).
	ZeroHealth(Player);
	TestTrue(TEXT("A death after a reconnect is accepted"), UAethelnDeathSubsystem::ApplyDeath(Player));
	TestFalse(TEXT("Death ends the carried break"), Player.HasMatchingGameplayTag(AethelnGameplayTags::State_GuardBroken));
	TestTrue(TEXT("Death keeps the cooldown"), Player.HasMatchingGameplayTag(AethelnGameplayTags::Cooldown_Block));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnReconnectDeadKeepsDeadlineTest,
	"Aetheln.GameCombat.Death.ReconnectDeadKeepsDeadline",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnReconnectDeadKeepsDeadlineTest::RunTest(const FString& Parameters)
{
	using namespace AethelnRespawnTests;
	FFixture F(true); if (!F.Init(*this)) { return false; }
	UAethelnDeathSubsystem* Deaths = PrepareReconnect(*this, F);
	if (Deaths == nullptr) { return false; }
	F.AdvanceTo(0.5);
	Kill(F, FGuid::NewGuid(), 0.4); // deadline 0.5 + TestDelay
	double Deadline = 0.0;
	uint64 Generation = 0;
	if (!TestTrue(TEXT("The death starts a respawn wait"), Deaths->FindRespawnWaitForTests(*F.Player.AbilitySystem, Deadline, Generation))) { return false; }
	TestEqual(TEXT("The deadline is the death time plus the delay"), Deadline, 0.5 + TestDelay);
	const TWeakObjectPtr<APawn> Corpse(F.Pawn);

	F.AdvanceTo(1.0);
	Disconnect(F, TestKey);
	TestEqual(TEXT("The logout keeps one player for the grace window"), Deaths->GetCarriedStateCountForTests(), 1);
	F.AdvanceTo(1.5); // before the deadline
	if (!Reconnect(*this, F, TestKey)) { return false; }
	UAethelnAbilitySystemComponent& Player = *F.Player.AbilitySystem;

	// The same death: dead, one death effect, no health, no movement, and the old deadline and generation, on the same corpse.
	TestTrue(TEXT("The reconnect resumes the same corpse"), Corpse.IsValid() && F.Pawn == Corpse.Get());
	TestTrue(TEXT("The player is still dead"), Player.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestEqual(TEXT("One death effect"), CountActive(Player, UAethelnDeathStateEffect::StaticClass()), 1);
	TestEqual(TEXT("Health stays at zero"), Read(Player, UAethelnCombatAttributeSet::GetHealthAttribute()), 0.0f);
	double ReconnectDeadline = 0.0;
	uint64 ReconnectGeneration = 0;
	if (TestTrue(TEXT("The respawn wait carried over"), Deaths->FindRespawnWaitForTests(Player, ReconnectDeadline, ReconnectGeneration)))
	{
		TestEqual(TEXT("The deadline is the same"), ReconnectDeadline, Deadline);
		TestEqual(TEXT("The life generation is the same"), static_cast<int64>(ReconnectGeneration), static_cast<int64>(Generation));
	}
	TestEqual(TEXT("The reconnect started no new life generation"), static_cast<int64>(Deaths->GetLifeGenerationForTests()), static_cast<int64>(Generation));
	TestEqual(TEXT("The reconnect consumed the kept state"), Deaths->GetCarriedStateCountForTests(), 0);

	// The dead pawn stays still: the next tick holds it at MOVE_None, even if the engine's restart reset its movement mode.
	F.AdvanceTo(1.6);
	if (const ACharacter* Character = Cast<ACharacter>(F.Pawn))
	{
		TestEqual(TEXT("The reconnected pawn cannot move"), static_cast<int32>(Character->GetCharacterMovement()->MovementMode), static_cast<int32>(MOVE_None));
	}

	// Not before the carried deadline, then once.
	F.AdvanceTo(0.5 + TestDelay - 0.1);
	TestTrue(TEXT("Still dead before the carried deadline"), Player.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	F.AdvanceTo(0.5 + TestDelay + 0.1);
	TestFalse(TEXT("Respawned at the carried deadline"), Player.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestEqual(TEXT("Health is restored"), Read(Player, UAethelnCombatAttributeSet::GetHealthAttribute()), 40.0f);
	TestFalse(TEXT("The corpse is destroyed by the respawn"), Corpse.IsValid());
	TestFalse(TEXT("A second respawn is refused"), UAethelnDeathSubsystem::Respawn(Player));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnReconnectAfterDeadlineRespawnsOnceTest,
	"Aetheln.GameCombat.Death.ReconnectAfterDeadlineRespawnsOnce",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnReconnectAfterDeadlineRespawnsOnceTest::RunTest(const FString& Parameters)
{
	using namespace AethelnRespawnTests;
	FFixture F(true); if (!F.Init(*this)) { return false; }
	UAethelnDeathSubsystem* Deaths = PrepareReconnect(*this, F);
	if (Deaths == nullptr) { return false; }
	F.AdvanceTo(0.5);
	Kill(F, FGuid::NewGuid(), 0.4); // deadline 2.5
	const uint64 Generation = Deaths->GetLifeGenerationForTests();
	const TWeakObjectPtr<APawn> Corpse(F.Pawn);
	F.AdvanceTo(1.0);
	Disconnect(F, TestKey);
	TestTrue(TEXT("The corpse stays in the world while the player is away"), Corpse.IsValid());

	// The deadline passes while the player is away: the corpse goes at the deadline (the owner's corpse rule), and nothing
	// respawns a player who is not there.
	F.AdvanceTo(3.0);
	TestEqual(TEXT("The kept player waits for the reconnect"), Deaths->GetCarriedStateCountForTests(), 1);
	TestFalse(TEXT("The corpse is destroyed at the deadline"), Corpse.IsValid());
	TestEqual(TEXT("Nobody respawned the absent player"), static_cast<int64>(Deaths->GetLifeGenerationForTests()), static_cast<int64>(Generation));
	if (!Reconnect(*this, F, TestKey)) { return false; }
	UAethelnAbilitySystemComponent& Player = *F.Player.AbilitySystem;
	TestTrue(TEXT("The reconnect resolves to the dead state first"), Player.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	const TWeakObjectPtr<APawn> ReconnectPawn(F.Pawn);

	// The next tick runs the normal respawn order, once.
	F.AdvanceTo(3.1);
	TestFalse(TEXT("The player respawned"), Player.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestEqual(TEXT("The death effect was removed"), CountActive(Player, UAethelnDeathStateEffect::StaticClass()), 0);
	TestEqual(TEXT("Health is restored"), Read(Player, UAethelnCombatAttributeSet::GetHealthAttribute()), 40.0f);
	TestEqual(TEXT("Endurance is restored"), Read(Player, UAethelnCombatAttributeSet::GetEnduranceAttribute()), 30.0f);
	TestEqual(TEXT("Guard is restored"), Read(Player, UAethelnCombatAttributeSet::GetGuardAttribute()), 20.0f);
	APawn* NewPawn = F.Player.Controller->GetPawn();
	if (TestNotNull(TEXT("The player has a new pawn"), NewPawn))
	{
		TestTrue(TEXT("The new pawn is not the pawn the reconnect started"), NewPawn != ReconnectPawn.Get());
		TestTrue(TEXT("The new pawn is the ability avatar"), Player.GetAvatarActor() == NewPawn);
	}
	TestEqual(TEXT("Abilities are granted once"), Player.GetActivatableAbilities().Num(), 1);
	TestFalse(TEXT("A second respawn is refused"), UAethelnDeathSubsystem::Respawn(Player));
	F.AdvanceTo(9.0);
	TestTrue(TEXT("Nothing respawns the player again"), F.Player.Controller->GetPawn() == NewPawn);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnReconnectRespawnStepIsAtomicTest,
	"Aetheln.GameCombat.Death.ReconnectRespawnStepIsAtomic",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnReconnectRespawnStepIsAtomicTest::RunTest(const FString& Parameters)
{
	using namespace AethelnRespawnTests;
	FFixture F(true); if (!F.Init(*this)) { return false; }
	UAethelnDeathSubsystem* Deaths = PrepareReconnect(*this, F);
	if (Deaths == nullptr) { return false; }
	F.AdvanceTo(0.5);
	Kill(F, FGuid::NewGuid(), 0.4); // deadline 2.5
	const uint64 Generation = Deaths->GetLifeGenerationForTests();
	F.AdvanceTo(2.6); // the respawn step runs in this tick, wholly
	TestFalse(TEXT("The respawn completed"), F.Player.AbilitySystem->HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	F.Pawn = Cast<AAethelnPlayerCharacter>(F.Player.Controller->GetPawn());

	// A disconnect right after it carries the living, restored player: never the dead one, and no wait.
	Disconnect(F, TestKey);
	F.AdvanceTo(2.7);
	if (!Reconnect(*this, F, TestKey)) { return false; }
	UAethelnAbilitySystemComponent& Player = *F.Player.AbilitySystem;
	TestFalse(TEXT("The reconnect sees the living state"), Player.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestEqual(TEXT("No death effect"), CountActive(Player, UAethelnDeathStateEffect::StaticClass()), 0);
	TestEqual(TEXT("Health is the restored value"), Read(Player, UAethelnCombatAttributeSet::GetHealthAttribute()), 40.0f);
	double Deadline = 0.0;
	uint64 WaitGeneration = 0;
	TestFalse(TEXT("No respawn wait remains"), Deaths->FindRespawnWaitForTests(Player, Deadline, WaitGeneration));
	APawn* Pawn = F.Player.Controller->GetPawn();
	F.AdvanceTo(9.0);
	TestTrue(TEXT("Nothing respawns the player a second time"), F.Player.Controller->GetPawn() == Pawn);
	TestEqual(TEXT("No new life generation"), static_cast<int64>(Deaths->GetLifeGenerationForTests()), static_cast<int64>(Generation));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnReconnectAfterGraceIsNewSessionTest,
	"Aetheln.GameCombat.Death.ReconnectAfterGraceIsNewSession",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnReconnectAfterGraceIsNewSessionTest::RunTest(const FString& Parameters)
{
	using namespace AethelnRespawnTests;
	constexpr float NaN = std::numeric_limits<float>::quiet_NaN();
	const float IniGrace = GetDefault<UAethelnDeathSubsystem>()->ProvisionalDisconnectGraceSeconds;
	TestTrue(TEXT("The ini sets a finite, positive provisional disconnect grace window"), FMath::IsFinite(IniGrace) && IniGrace > 0.0f);

	// Past the grace window the kept pawn and PlayerState are removed, and the reconnect is a new session under the initial
	// attributes (P4b expiry).
	{
		FFixture F(true); if (!F.Init(*this)) { return false; }
		UAethelnDeathSubsystem* Deaths = PrepareReconnect(*this, F);
		if (Deaths == nullptr) { return false; }
		AethelnCombatTests::ApplyInstantModifier(*F.Player.AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::AddBase, -10.0f);
		const TWeakObjectPtr<APawn> KeptPawn(F.Pawn);
		const TWeakObjectPtr<AAethelnPlayerState> KeptState(F.Player.PlayerState);
		F.AdvanceTo(1.0);
		Disconnect(F, TestKey);
		F.AdvanceTo(1.0 + TestGrace - 0.1);
		TestEqual(TEXT("The player is still kept inside the window"), Deaths->GetCarriedStateCountForTests(), 1);
		TestTrue(TEXT("The pawn stays in the world inside the window"), KeptPawn.IsValid());
		F.AdvanceTo(1.0 + TestGrace + 0.1);
		TestEqual(TEXT("Nothing is kept after the window"), Deaths->GetCarriedStateCountForTests(), 0);
		TestFalse(TEXT("The kept pawn is removed when the window ends"), KeptPawn.IsValid());
		TestFalse(TEXT("The kept PlayerState is removed when the window ends"), KeptState.IsValid());
		if (!Reconnect(*this, F, TestKey)) { return false; }
		TestEqual(TEXT("A reconnect after the window gets the initial Health"), Read(*F.Player.AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute()), 40.0f);
	}

	// A player who dies while away and whose window ends is gone with the window: the reconnect is alive, not dead.
	{
		FFixture F(true); if (!F.Init(*this)) { return false; }
		UAethelnDeathSubsystem* Deaths = PrepareReconnect(*this, F);
		if (Deaths == nullptr) { return false; }
		const TWeakObjectPtr<UAethelnAbilitySystemComponent> Kept(F.Player.AbilitySystem);
		F.AdvanceTo(0.5);
		Disconnect(F, TestKey);
		F.AdvanceTo(1.0);
		if (TestTrue(TEXT("The away player is kept"), Kept.IsValid()))
		{
			ZeroHealth(*Kept);
			F.Timeline->OnLethalResult.Broadcast(Kept.Get(), FGuid::NewGuid(), 0.9);
			TestTrue(TEXT("The away player dies"), Kept->HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
		}
		F.AdvanceTo(0.5 + TestGrace + 0.1);
		TestEqual(TEXT("Nothing is kept after the window, dead or alive"), Deaths->GetCarriedStateCountForTests(), 0);
		if (!Reconnect(*this, F, TestKey)) { return false; }
		TestFalse(TEXT("The reconnect after the window is alive"), F.Player.AbilitySystem->HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
		TestEqual(TEXT("The reconnect after the window gets the initial Health"), Read(*F.Player.AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute()), 40.0f);
	}

	// An unset, negative, or non-finite window keeps nothing: the server says why, the pawn leaves with the connection, and a
	// reconnect is a new session.
	AddExpectedError(TEXT("Refused to carry the state"), EAutomationExpectedErrorFlags::Contains, 3);
	for (const float Grace : { 0.0f, -1.0f, NaN })
	{
		FFixture F(true); if (!F.Init(*this)) { return false; }
		UAethelnDeathSubsystem* Deaths = PrepareReconnect(*this, F);
		if (Deaths == nullptr) { return false; }
		Deaths->ProvisionalDisconnectGraceSeconds = Grace;
		AethelnCombatTests::ApplyInstantModifier(*F.Player.AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::AddBase, -10.0f);
		const TWeakObjectPtr<APawn> Pawn(F.Pawn);
		Disconnect(F, TestKey);
		TestEqual(TEXT("An invalid window keeps nothing"), Deaths->GetCarriedStateCountForTests(), 0);
		TestFalse(TEXT("An invalid window keeps no pawn"), Pawn.IsValid());
		if (!Reconnect(*this, F, TestKey)) { return false; }
		TestEqual(TEXT("The reconnect is a new session"), Read(*F.Player.AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute()), 40.0f);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnReconnectKeyIsClientPresentedTest,
	"Aetheln.GameCombat.Death.ReconnectKeyIsClientPresented",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnReconnectKeyIsClientPresentedTest::RunTest(const FString& Parameters)
{
	using namespace AethelnRespawnTests;
	// The one identity function: a missing, empty, too long, or malformed key means no carry.
	TestEqual(TEXT("A valid key is used as given"), AAethelnCombatGameMode::ResolveReconnectKey(TEXT("?Name=x?ReconnectKey=abc-1_Z")), FString(TEXT("abc-1_Z")));
	TestEqual(TEXT("A 64 character key is valid"), AAethelnCombatGameMode::ResolveReconnectKey(TEXT("?ReconnectKey=") + FString::ChrN(64, TEXT('a'))), FString::ChrN(64, TEXT('a')));
	TestEqual(TEXT("A 65 character key is refused"), AAethelnCombatGameMode::ResolveReconnectKey(TEXT("?ReconnectKey=") + FString::ChrN(65, TEXT('a'))), FString());
	TestEqual(TEXT("No option is no key"), AAethelnCombatGameMode::ResolveReconnectKey(TEXT("?Name=x")), FString());
	TestEqual(TEXT("No options is no key"), AAethelnCombatGameMode::ResolveReconnectKey(FString()), FString());
	TestEqual(TEXT("An empty key is no key"), AAethelnCombatGameMode::ResolveReconnectKey(TEXT("?ReconnectKey=")), FString());
	TestEqual(TEXT("A path character is refused"), AAethelnCombatGameMode::ResolveReconnectKey(TEXT("?ReconnectKey=ab/cd")), FString());
	TestEqual(TEXT("A non-ASCII character is refused"), AAethelnCombatGameMode::ResolveReconnectKey(TEXT("?ReconnectKey=abü")), FString());

	FFixture F(true); if (!F.Init(*this)) { return false; }
	UAethelnDeathSubsystem* Deaths = PrepareReconnect(*this, F);
	if (Deaths == nullptr) { return false; }
	AethelnCombatTests::ApplyInstantModifier(*F.Player.AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::AddBase, -10.0f);
	Disconnect(F, TestKey);
	TestEqual(TEXT("One player is kept"), Deaths->GetCarriedStateCountForTests(), 1);

	// The client presents only the key. The state belongs to the server's kept player under that key: another key, or none, never
	// takes it, and nothing the player says changes what is restored.
	if (!Reconnect(*this, F, TEXT("another-key"))) { return false; }
	TestEqual(TEXT("Another key gets the initial Health"), Read(*F.Player.AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute()), 40.0f);
	TestEqual(TEXT("Another key leaves the kept player alone"), Deaths->GetCarriedStateCountForTests(), 1);
	Disconnect(F, FString());
	TestEqual(TEXT("A player with no key keeps nothing"), Deaths->GetCarriedStateCountForTests(), 1);
	if (!Reconnect(*this, F, FString())) { return false; }
	TestEqual(TEXT("No key gets the initial Health"), Read(*F.Player.AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute()), 40.0f);
	TestEqual(TEXT("No key leaves the kept player alone"), Deaths->GetCarriedStateCountForTests(), 1);
	Disconnect(F, FString());
	if (!Reconnect(*this, F, TestKey)) { return false; }
	TestEqual(TEXT("The owner of the key gets the carried Health"), Read(*F.Player.AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute()), 30.0f);
	TestEqual(TEXT("The reconnect consumed the kept state"), Deaths->GetCarriedStateCountForTests(), 0);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnReconnectLoginStampsKeyTest,
	"Aetheln.GameCombat.Death.ReconnectLoginStampsKey",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnReconnectLoginStampsKeyTest::RunTest(const FString& Parameters)
{
	using namespace AethelnRespawnTests;
	FFixture F(true); if (!F.Init(*this)) { return false; }
	if (PrepareReconnect(*this, F) == nullptr) { return false; }
	AAethelnCombatGameMode* GameMode = GameModeWithSession(*this, F);
	if (GameMode == nullptr) { return false; }

	// P4b: the server issues the key. A login with no key, a malformed key, or a key that names no kept player gets a new one,
	// stamped on the PlayerState before any possession, and every issued key passes the identity check.
	TestTrue(TEXT("The PlayerState has no key before login"), F.Player.PlayerState->GetReconnectKey().IsEmpty());
	GameMode->InitNewPlayer(F.Player.Controller, FUniqueNetIdRepl(), FString(), FString());
	const FString Issued = F.Player.PlayerState->GetReconnectKey();
	TestFalse(TEXT("A login without a key gets an issued key"), Issued.IsEmpty());
	TestEqual(TEXT("The issued key passes the identity check"), AAethelnCombatGameMode::ResolveReconnectKey(TEXT("?ReconnectKey=") + Issued), Issued);
	GameMode->InitNewPlayer(F.Player.Controller, FUniqueNetIdRepl(), TEXT("?ReconnectKey=bad/key"), FString());
	const FString Second = F.Player.PlayerState->GetReconnectKey();
	TestFalse(TEXT("A malformed key gets an issued key"), Second.IsEmpty());
	TestNotEqual(TEXT("Each login gets its own key"), Second, Issued);
	GameMode->InitNewPlayer(F.Player.Controller, FUniqueNetIdRepl(), TEXT("?ReconnectKey=login-key"), FString());
	TestNotEqual(TEXT("A key that names no kept player is not taken"), F.Player.PlayerState->GetReconnectKey(), FString(TEXT("login-key")));
	TestFalse(TEXT("It gets an issued key instead"), F.Player.PlayerState->GetReconnectKey().IsEmpty());

	// A key that names a player inside the grace window is kept as presented, so the rejoin resumes that player.
	Disconnect(F, TestKey);
	AAethelnPlayerController* Next = F.World.Spawn<AAethelnPlayerController>();
	AAethelnPlayerState* Fresh = Next != nullptr ? AethelnCombatTests::AttachFreshPlayerState(F.World, *Next, { UAethelnChainTestAbility::StaticClass() }) : nullptr;
	if (!TestNotNull(TEXT("The rejoin's PlayerState exists"), Fresh)) { return false; }
	GameMode->InitNewPlayer(Next, FUniqueNetIdRepl(), FString(TEXT("?ReconnectKey=")) + TestKey, FString());
	TestEqual(TEXT("The kept player's key is stamped as presented"), Fresh->GetReconnectKey(), FString(TestKey));

	// The client side: the local player presents the key it was sent in its next login options (a local player lives within the engine).
	UAethelnLocalPlayer* Local = NewObject<UAethelnLocalPlayer>(GEngine);
	Local->SetReconnectKey(Issued);
	TestEqual(TEXT("The local player presents its key in the login options"), AAethelnCombatGameMode::ResolveReconnectKey(FString(TEXT("?")) + Local->GetGameLoginOptions()), Issued);
	TestTrue(TEXT("A local player without a key presents none"), NewObject<UAethelnLocalPlayer>(GEngine)->GetGameLoginOptions().IsEmpty());
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnReconnectRefusesLiveKeyTest,
	"Aetheln.GameCombat.Death.ReconnectRefusesLiveKey",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnReconnectRefusesLiveKeyTest::RunTest(const FString& Parameters)
{
	using namespace AethelnRespawnTests;
	FFixture F(true); if (!F.Init(*this)) { return false; }
	if (PrepareReconnect(*this, F) == nullptr) { return false; }
	AAethelnCombatGameMode* GameMode = GameModeWithSession(*this, F);
	if (GameMode == nullptr) { return false; }
	F.Player.PlayerState->SetReconnectKey(TestKey);
	APlayerController* LiveController = F.Player.Controller;
	const FString Options = FString(TEXT("?ReconnectKey=")) + TestKey;

	// Lead decision (2026-10-14): a login with the key of a connected player is refused before it joins, and the connected
	// player is never kicked.
	FString Error;
	GameMode->PreLogin(Options, TEXT("127.0.0.1"), FUniqueNetIdRepl(), Error);
	TestFalse(TEXT("A login with a connected player's key is refused"), Error.IsEmpty());
	TestTrue(TEXT("The connected player keeps its controller and pawn"), IsValid(LiveController) && LiveController->GetPawn() == F.Pawn);
	TestEqual(TEXT("The connected player keeps its key"), F.Player.PlayerState->GetReconnectKey(), FString(TestKey));

	Error.Reset();
	GameMode->PreLogin(TEXT("?ReconnectKey=other-key"), TEXT("127.0.0.1"), FUniqueNetIdRepl(), Error);
	TestTrue(TEXT("A key that names nobody is a new session, not a refusal"), Error.IsEmpty());
	Error.Reset();
	GameMode->PreLogin(TEXT("?Name=x"), TEXT("127.0.0.1"), FUniqueNetIdRepl(), Error);
	TestTrue(TEXT("A login without a key is not refused"), Error.IsEmpty());

	// Once the player is away, the same key is the reconnect inside the grace window.
	Disconnect(F, TestKey);
	Error.Reset();
	GameMode->PreLogin(Options, TEXT("127.0.0.1"), FUniqueNetIdRepl(), Error);
	TestTrue(TEXT("The key of a player inside the grace window is accepted"), Error.IsEmpty());
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnGraceKeepsAttackablePawnTest,
	"Aetheln.GameCombat.Death.GraceKeepsAttackablePawn",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnGraceKeepsAttackablePawnTest::RunTest(const FString& Parameters)
{
	using namespace AethelnRespawnTests;
	FFixture F(true); if (!F.Init(*this)) { return false; }
	UAethelnDeathSubsystem* Deaths = PrepareReconnect(*this, F);
	if (Deaths == nullptr) { return false; }
	// Fixture geometry from R9: an enemy 60 units behind first touches the player's capsule well before 0.5.
	AAethelnCombatAICharacter* Enemy = SpawnEnemy(*this, F, FVector(-60.0, 0.0, 0.0));
	if (Enemy == nullptr) { return false; }
	const TWeakObjectPtr<APawn> Pawn(F.Pawn);
	const TWeakObjectPtr<AAethelnPlayerState> KeptState(F.Player.PlayerState);
	const TWeakObjectPtr<UAethelnAbilitySystemComponent> Kept(F.Player.AbilitySystem);

	// Owner rule (issue #21 comment 6131998770): the pawn stays in the world for the grace window, server-controlled.
	Disconnect(F, TestKey);
	if (!TestTrue(TEXT("The pawn stays in the world after the logout"), Pawn.IsValid() && !Pawn->IsActorBeingDestroyed())
		|| !TestTrue(TEXT("The PlayerState is kept for the grace window"), KeptState.IsValid() && Kept.IsValid()))
	{
		return false;
	}
	TestNull(TEXT("No controller drives the kept pawn, so no input reaches it"), Pawn->GetController());
	TestTrue(TEXT("The kept pawn resolves to the kept ASC"), UAethelnAbilitySystemComponent::FindForPawn(Pawn.Get()) == Kept.Get());
	TestTrue(TEXT("The kept ASC's avatar is the kept pawn"), Kept->GetAvatarActor() == Pawn.Get());
	TestTrue(TEXT("The kept PlayerState is inactive"), KeptState->IsInactive());
	TestFalse(TEXT("The kept PlayerState no longer replicates"), KeptState->GetIsReplicated());
	TestEqual(TEXT("One player is kept"), Deaths->GetCarriedStateCountForTests(), 1);

	// Attackable and killable: an enemy swing through the real contact pipeline hits the kept pawn, and the death is real.
	const FGuid Lethal = Swing(F, *Enemy, 40.0f);
	F.AdvanceTo(0.5);
	const FAethelnCombatResult* Result = F.Results.FindByPredicate([&Lethal](const FAethelnCombatResult& Item) { return Item.ActivationId == Lethal; });
	if (!TestNotNull(TEXT("The swing commits a result on the kept pawn"), Result)) { return false; }
	TestTrue(TEXT("The result is lethal"), Result->bLethal);
	TestTrue(TEXT("The kept player dies"), Kept->HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestEqual(TEXT("The kept player's Health is zero"), Read(*Kept, UAethelnCombatAttributeSet::GetHealthAttribute()), 0.0f);
	double Deadline = 0.0;
	uint64 Generation = 0;
	if (!TestTrue(TEXT("The death starts a respawn wait"), Deaths->FindRespawnWaitForTests(*Kept, Deadline, Generation))) { return false; }
	if (const ACharacter* Character = Cast<ACharacter>(Pawn.Get()))
	{
		TestEqual(TEXT("The dead kept pawn cannot move"), static_cast<int32>(Character->GetCharacterMovement()->MovementMode), static_cast<int32>(MOVE_None));
	}

	// The death carries: the reconnect resumes the same corpse, dead, with the same deadline and generation, and respawns once.
	F.AdvanceTo(1.0);
	if (!Reconnect(*this, F, TestKey)) { return false; }
	UAethelnAbilitySystemComponent& Player = *F.Player.AbilitySystem;
	TestTrue(TEXT("The reconnect resumes the kept corpse"), F.Pawn == Pawn.Get());
	TestTrue(TEXT("The reconnected player is dead"), Player.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestEqual(TEXT("Health stays at zero"), Read(Player, UAethelnCombatAttributeSet::GetHealthAttribute()), 0.0f);
	double CarriedDeadline = 0.0;
	uint64 CarriedGeneration = 0;
	if (TestTrue(TEXT("The respawn wait carried over"), Deaths->FindRespawnWaitForTests(Player, CarriedDeadline, CarriedGeneration)))
	{
		TestEqual(TEXT("The deadline is the same"), CarriedDeadline, Deadline);
		TestEqual(TEXT("The life generation is the same"), static_cast<int64>(CarriedGeneration), static_cast<int64>(Generation));
	}
	F.AdvanceTo(Deadline + 0.1);
	TestFalse(TEXT("The player respawns at the deadline"), Player.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestEqual(TEXT("One life generation for the one death"), static_cast<int64>(Deaths->GetLifeGenerationForTests()), static_cast<int64>(Generation));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnReconnectThroughControllerDestroyTest,
	"Aetheln.GameCombat.Death.ReconnectThroughControllerDestroy",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnReconnectThroughControllerDestroyTest::RunTest(const FString& Parameters)
{
	using namespace AethelnRespawnTests;
	FFixture F(true); if (!F.Init(*this)) { return false; }
	UAethelnDeathSubsystem* Deaths = PrepareReconnect(*this, F);
	if (Deaths == nullptr) { return false; }
	AethelnCombatTests::ApplyInstantModifier(*F.Player.AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::AddBase, -10.0f);

	// The production chain of a logout: the controller's destruction calls PawnLeavingGame, the game mode's Logout, and the
	// PlayerState's cleanup (OnDeactivated). Nothing here destroys the PlayerState or the pawn by hand.
	Disconnect(F, TestKey);
	TestEqual(TEXT("Destroying the controller keeps one player"), Deaths->GetCarriedStateCountForTests(), 1);

	// A new connection: a new controller, a fresh PlayerState with the key, and the game mode starts the player.
	if (!Reconnect(*this, F, TestKey)) { return false; }
	TestEqual(TEXT("The kept player is taken"), Deaths->GetCarriedStateCountForTests(), 0);
	TestEqual(TEXT("Health carries over through the production logout"), Read(*F.Player.AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute()), 30.0f);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnReconnectNamesUncarriedEffectsTest,
	"Aetheln.GameCombat.Death.ReconnectNamesUncarriedEffects",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnReconnectNamesUncarriedEffectsTest::RunTest(const FString& Parameters)
{
	using namespace AethelnRespawnTests;
	FFixture F(true); if (!F.Init(*this)) { return false; }
	UAethelnDeathSubsystem* Deaths = PrepareReconnect(*this, F);
	if (Deaths == nullptr) { return false; }

	// A duration effect of another class is not carried, so a reconnect would end it: the capture says so, once for it. The
	// shared timed-state effect, an instant effect, and the recovery and death effects stay silent.
	ApplyTimedState(*F.Player.AbilitySystem, AethelnGameplayTags::Cooldown_Block, 20.0f);
	AethelnCombatTests::ApplyInstantModifier(*F.Player.AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::AddBase, -10.0f);
	F.Player.AbilitySystem->ApplyGameplayEffectToSelf(
		AethelnCombatTests::MakeTestEffect(EGameplayEffectDurationType::Infinite), 1.0f, F.Player.AbilitySystem->MakeEffectContext());
	AddExpectedError(TEXT("does not carry the active effect"), EAutomationExpectedErrorFlags::Contains, 1);
	Disconnect(F, TestKey);
	if (!Reconnect(*this, F, TestKey)) { return false; }
	TestEqual(TEXT("The carried Health is still restored"), Read(*F.Player.AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute()), 30.0f);
	TestEqual(TEXT("Nothing is left kept"), Deaths->GetCarriedStateCountForTests(), 0);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnReconnectDuplicatesNothingTest,
	"Aetheln.GameCombat.Death.ReconnectDuplicatesNothing",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnReconnectDuplicatesNothingTest::RunTest(const FString& Parameters)
{
	using namespace AethelnRespawnTests;
	FFixture F(true); if (!F.Init(*this)) { return false; }
	UAethelnDeathSubsystem* Deaths = PrepareReconnect(*this, F);
	UAethelnObservabilitySubsystem* Subsystem = F.World.GameInstance != nullptr ? F.World.GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>() : nullptr;
	if (Deaths == nullptr || !TestNotNull(TEXT("Observability subsystem exists"), Subsystem)) { return false; }
	TSharedPtr<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe> Sink = MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(64);
	TestTrue(TEXT("Runtime context is set"), Subsystem->SetRuntimeContext(EAethelnFlowKind::PrototypeAuthority, TEXT("run-death-p4-test"), TEXT("instance-death-p4-test"), TEXT("connection-death-p4-test")));
	TestTrue(TEXT("Public sink is set"), Subsystem->SetTestSink(Sink));

	F.AdvanceTo(0.5);
	Kill(F, FGuid::NewGuid(), 0.4);
	F.AdvanceTo(1.0);
	Disconnect(F, TestKey);
	F.AdvanceTo(1.5);
	// Bound before the game mode starts the player, so the restore itself is observed.
	int32 DeathCues = 0;
	FDelegateHandle CueHandle;
	if (!Reconnect(*this, F, TestKey, [&DeathCues, &CueHandle](UAethelnAbilitySystemComponent& Fresh) { CueHandle = Fresh.OnDeathCue.AddLambda([&DeathCues] { ++DeathCues; }); })) { return false; }
	UAethelnAbilitySystemComponent& Player = *F.Player.AbilitySystem;

	// A repeated lethal notification for the reconnected, already dead player is the same no-op as before the logout.
	F.Timeline->OnLethalResult.Broadcast(&Player, FGuid::NewGuid(), 1.2);
	TestEqual(TEXT("A repeated notification adds no death effect"), CountActive(Player, UAethelnDeathStateEffect::StaticClass()), 1);
	TestEqual(TEXT("State.Dead is held once"), Player.GetTagCount(AethelnGameplayTags::State_Dead), 1);
	F.AdvanceTo(3.0);
	TestFalse(TEXT("The player respawned once"), Player.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestEqual(TEXT("The reconnect and the respawn raised no death cue"), DeathCues, 0);
	Player.OnDeathCue.Remove(CueHandle);
	TestEqual(TEXT("Abilities are granted once"), Player.GetActivatableAbilities().Num(), 1);
	TestEqual(TEXT("There was one life generation in all"), static_cast<int64>(Deaths->GetLifeGenerationForTests()), static_cast<int64>(1));

	TestTrue(TEXT("Telemetry drained"), Subsystem->WaitForIdleForTests());
	int32 DeathEvents = 0;
	for (const FAethelnObservabilityEvent& Event : Sink->GetEvents())
	{
		if (Event.Category == EAethelnObservabilityCategory::Death) { ++DeathEvents; }
	}
	TestEqual(TEXT("One Death event for the one death"), DeathEvents, 1);
	Subsystem->ResetSink(); Subsystem->ResetRuntimeContext();
	return true;
}

#endif
