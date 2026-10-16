#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnAbilitySystemComponent.h"
#include "AethelnChainTestFixture.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatEffects.h"
#include "AethelnCombatGameMode.h"
#include "AethelnDeathSubsystem.h"
#include "AethelnDefenseTestFixture.h"
#include "AethelnGameplayTags.h"
#include "AethelnOathscarTestAbilities.h"
#include "AethelnPlayerCharacter.h"
#include "GameFramework/GameModeBase.h"
#include "GameFramework/WorldSettings.h"
#include "Misc/AutomationTest.h"

// #260 P4 (docs/gas-foundation.md, Representative Oathscar Actives, Stance; K10 to K12): Attack Stance and Defense Stance.
// Fixture values, not tuning: the test stances last 8 s and cost 1 Endurance (the production stances' cost is TBD), and the
// provisional 600 s of the ini is only read, never applied here. The headless world does not expire duration effects, so an
// expiry is never asserted; the remaining time is read as the world advances.
namespace AethelnOathscarStanceTests
{
	using EResult = EAethelnActivationResult;

	const FGameplayTag AttackId = AethelnGameplayTags::Ability_Oathscar_AttackStance;
	const FGameplayTag DefenseId = AethelnGameplayTags::Ability_Oathscar_DefenseStance;
	constexpr float FixtureDuration = 8.0f;

	TArray<TSubclassOf<UGameplayAbility>> Stances()
	{
		return { UAethelnAttackStanceTestAbility::StaticClass(), UAethelnDefenseStanceTestAbility::StaticClass() };
	}

	TArray<TSubclassOf<UGameplayAbility>> WithDefense()
	{
		TArray<TSubclassOf<UGameplayAbility>> Result = Stances();
		Result.Append({ UAethelnChainTestAbility::StaticClass(), UAethelnInstantStrikeTestAbility::StaticClass(), UAethelnDodgeTestAbility::StaticClass(), UAethelnBlockTestAbility::StaticClass() });
		return Result;
	}

	FGameplayTagContainer StanceTags()
	{
		FGameplayTagContainer Tags;
		Tags.AddTag(AethelnGameplayTags::State_Oathscar_AttackStance);
		Tags.AddTag(AethelnGameplayTags::State_Oathscar_DefenseStance);
		return Tags;
	}

	/** The active effects that grant either stance tag. */
	TArray<FActiveGameplayEffectHandle> StanceEffects(const UAbilitySystemComponent& AbilitySystem)
	{
		return AbilitySystem.GetActiveEffects(FGameplayEffectQuery::MakeQuery_MatchAnyOwningTags(StanceTags()));
	}

	/** The first stance effect, or an invalid handle. */
	FActiveGameplayEffectHandle OnlyStance(const UAbilitySystemComponent& AbilitySystem)
	{
		const TArray<FActiveGameplayEffectHandle> Effects = StanceEffects(AbilitySystem);
		return Effects.Num() > 0 ? Effects[0] : FActiveGameplayEffectHandle();
	}

	bool HasStance(const UAbilitySystemComponent& AbilitySystem, const FGameplayTag& Tag) { return AbilitySystem.HasMatchingGameplayTag(Tag); }

	int32 CooldownEffects(const UAbilitySystemComponent& AbilitySystem)
	{
		FGameplayEffectQuery Query;
		Query.EffectDefinition = UAethelnCooldownEffect::StaticClass();
		return AbilitySystem.GetActiveEffects(Query).Num();
	}

	/** A seam request for a stance (content version 1) built now; Sequence 0 takes the next one. */
	FAethelnCombatActivationRequest MakeRequest(UAethelnAbilitySystemComponent& AbilitySystem, uint32& NextSequence, const FGameplayTag& AbilityId, uint32 Sequence = 0)
	{
		FAethelnCombatActivationRequest Request;
		Request.AbilityId = AbilityId;
		Request.ContentVersion = 1;
		Request.Sequence = Sequence != 0 ? Sequence : NextSequence++;
		AethelnCombatTests::FillTestAimAndTime(Request, AbilitySystem);
		return Request;
	}

	FAethelnCombatActivationRequest MakeRequest(AethelnDefenseTests::FDefense& F, const FGameplayTag& AbilityId, uint32 Sequence = 0)
	{
		return MakeRequest(F.ASC(), F.NextSequence, AbilityId, Sequence);
	}

	EResult PressStance(AethelnDefenseTests::FDefense& F, const FGameplayTag& AbilityId) { return F.Deliver(MakeRequest(F, AbilityId)); }

	bool Active(const AethelnDefenseTests::FDefense& F, TSubclassOf<UGameplayAbility> Class)
	{
		const FGameplayAbilitySpec* Spec = F.ASC().FindAbilitySpecFromClass(Class);
		return Spec != nullptr && Spec->IsActive();
	}

	/** Counts the activations that ended cancelled, for as long as it lives. */
	struct FCancelCounter
	{
		explicit FCancelCounter(UAbilitySystemComponent& InAbilitySystem)
			: AbilitySystem(&InAbilitySystem)
			, Handle(InAbilitySystem.OnAbilityEnded.AddLambda([this](const FAbilityEndedData& Data) { Cancelled += Data.bWasCancelled ? 1 : 0; }))
		{
		}
		~FCancelCounter() { if (AbilitySystem.IsValid()) { AbilitySystem->OnAbilityEnded.Remove(Handle); } }
		TWeakObjectPtr<UAbilitySystemComponent> AbilitySystem;
		FDelegateHandle Handle;
		int32 Cancelled = 0;
	};

	/** The lethal notification the timeline raises, for a player with zero Health (as the respawn tests do). */
	void Kill(AethelnChainTests::FFixture& F)
	{
		AethelnCombatTests::ApplyInstantModifier(*F.Player.AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::Override, 0.0f);
		F.Timeline->OnLethalResult.Broadcast(F.Player.AbilitySystem, FGuid::NewGuid(), F.World.World->GetTimeSeconds());
	}

	/** The combat game mode as the world's authority, with the plain player character as its pawn (as the respawn tests install it). */
	bool InstallGameMode(FAutomationTestBase& Test, UWorld& World)
	{
		World.GetWorldSettings()->DefaultGameMode = AAethelnCombatGameMode::StaticClass();
		if (!Test.TestTrue(TEXT("The world takes the combat game mode"), World.SetGameMode(FURL()))) { return false; }
		AAethelnCombatGameMode* GameMode = World.GetAuthGameMode<AAethelnCombatGameMode>();
		if (!Test.TestNotNull(TEXT("The combat game mode is the world's authority"), GameMode)) { return false; }
		GameMode->InputEnabledPawnClass.Reset();
		GameMode->DefaultPawnClass = AAethelnPlayerCharacter::StaticClass();
		return true;
	}
}

// K10. Red-first: before the stance abilities exist nothing here compiles; at a stub that applies nothing the first count fails.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnStanceExclusiveTest,
	"Aetheln.GameCombat.OathscarActives.StanceExclusive",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnStanceExclusiveTest::RunTest(const FString& Parameters)
{
	using namespace AethelnOathscarStanceTests;
	using AethelnDefenseTests::FDefense;
	const FGameplayTag AttackTag = AethelnGameplayTags::State_Oathscar_AttackStance;
	const FGameplayTag DefenseTag = AethelnGameplayTags::State_Oathscar_DefenseStance;

	// The owner's provisional duration is the only stance value in the ini, in one place, read by both stances.
	TestEqual(TEXT("The ini carries the provisional 600 s"), GetDefault<UAethelnStanceAbility>()->ProvisionalStanceDurationSeconds, 600.0f);
	TestEqual(TEXT("Attack Stance reads it from the shared section"), GetDefault<UAethelnAttackStanceAbility>()->ProvisionalStanceDurationSeconds, 600.0f);
	TestEqual(TEXT("Defense Stance reads it from the shared section"), GetDefault<UAethelnDefenseStanceAbility>()->ProvisionalStanceDurationSeconds, 600.0f);

	FDefense F; if (!F.Init(*this, WithDefense())) { return false; }
	FCancelCounter Cancels(F.ASC());
	F.AdvanceTo(1.0);

	// A cast applies its effect for the configured duration, spends once, and ends itself with no cooldown.
	TestEqual(TEXT("Attack Stance is accepted"), PressStance(F, AttackId), EResult::Accepted);
	TestEqual(TEXT("One stance effect exists"), StanceEffects(F.ASC()).Num(), 1);
	TestTrue(TEXT("It grants State.Oathscar.AttackStance"), HasStance(F.ASC(), AttackTag));
	TestFalse(TEXT("Not the other stance"), HasStance(F.ASC(), DefenseTag));
	const TArray<float> Durations = F.ASC().GetActiveEffectsDuration(FGameplayEffectQuery::MakeQuery_MatchAnyOwningTags(FGameplayTagContainer(AttackTag)));
	if (TestEqual(TEXT("One effect carries the tag"), Durations.Num(), 1)) { TestEqual(TEXT("For the configured duration"), Durations[0], FixtureDuration); }
	TestEqual(TEXT("One Endurance spend"), F.CostApplications, 1);
	TestEqual(TEXT("No cooldown effect"), CooldownEffects(F.ASC()), 0);
	TestFalse(TEXT("The cast ended itself"), Active(F, UAethelnAttackStanceTestAbility::StaticClass()));
	TestEqual(TEXT("It ended uncancelled"), Cancels.Cancelled, 0);
	TestEqual(TEXT("The next cast of the same stance is accepted at once (no cooldown)"), PressStance(F, AttackId), EResult::Accepted);

	// The other stance's cast removes it; never both. Recasting restarts the duration (lane default, open).
	F.AdvanceTo(3.0);
	const TArray<float> Aged = F.ASC().GetActiveEffectsTimeRemaining(FGameplayEffectQuery::MakeQuery_MatchAnyOwningTags(StanceTags()));
	if (TestEqual(TEXT("Still one effect after the recast"), Aged.Num(), 1)) { TestEqual(TEXT("Its duration counts down"), Aged[0], FixtureDuration - 2.0f, 0.01f); }
	const FActiveGameplayEffectHandle AttackHandle = OnlyStance(F.ASC());
	TestEqual(TEXT("Defense Stance is accepted"), PressStance(F, DefenseId), EResult::Accepted);
	TestFalse(TEXT("The attack stance is gone"), HasStance(F.ASC(), AttackTag));
	TestTrue(TEXT("The defense stance holds"), HasStance(F.ASC(), DefenseTag));
	if (TestEqual(TEXT("One stance effect"), StanceEffects(F.ASC()).Num(), 1)) { TestTrue(TEXT("A new effect, not the old one"), OnlyStance(F.ASC()) != AttackHandle); }
	TestEqual(TEXT("Still no cooldown effect"), CooldownEffects(F.ASC()), 0);
	const FActiveGameplayEffectHandle DefenseHandle = OnlyStance(F.ASC());
	F.AdvanceTo(5.0);
	TestEqual(TEXT("Recasting the active stance is accepted"), PressStance(F, DefenseId), EResult::Accepted);
	if (TestEqual(TEXT("It replaced its effect"), StanceEffects(F.ASC()).Num(), 1)) { TestTrue(TEXT("A new handle"), OnlyStance(F.ASC()) != DefenseHandle); }
	const TArray<float> Restarted = F.ASC().GetActiveEffectsTimeRemaining(FGameplayEffectQuery::MakeQuery_MatchAnyOwningTags(StanceTags()));
	if (TestEqual(TEXT("One duration"), Restarted.Num(), 1)) { TestEqual(TEXT("The duration restarted"), Restarted[0], FixtureDuration, 0.01f); }

	// Two casts in one frame resolve in seam order: the later one wins, and never both.
	{
		FAethelnCombatActivationRequest First = MakeRequest(F, AttackId);
		FAethelnCombatActivationRequest Second = MakeRequest(F, DefenseId);
		FAethelnCombatActivationRequest Third = MakeRequest(F, AttackId);
		TestEqual(TEXT("The first of three same-frame casts"), F.Deliver(First), EResult::Accepted);
		TestEqual(TEXT("The second"), F.Deliver(Second), EResult::Accepted);
		TestTrue(TEXT("After two, the later one holds"), HasStance(F.ASC(), DefenseTag) && !HasStance(F.ASC(), AttackTag));
		TestEqual(TEXT("The third"), F.Deliver(Third), EResult::Accepted);
		TestEqual(TEXT("At most one stance effect"), StanceEffects(F.ASC()).Num(), 1);
		TestTrue(TEXT("The last cast holds"), HasStance(F.ASC(), AttackTag) && !HasStance(F.ASC(), DefenseTag));
	}

	// A cast the commit refuses removes nothing: the stance stays and nothing is spent.
	{
		AethelnCombatTests::ApplyInstantModifier(F.ASC(), UAethelnCombatAttributeSet::GetEnduranceAttribute(), EGameplayModOp::Override, 0.0f);
		const int32 Spent = F.CostApplications;
		TestEqual(TEXT("A cast without Endurance is refused"), PressStance(F, DefenseId), EResult::InsufficientResource);
		TestTrue(TEXT("The current stance stays"), HasStance(F.ASC(), AttackTag) && !HasStance(F.ASC(), DefenseTag));
		TestEqual(TEXT("It spends nothing"), F.CostApplications, Spent);
		AethelnCombatTests::ApplyInstantModifier(F.ASC(), UAethelnCombatAttributeSet::GetEnduranceAttribute(), EGameplayModOp::Override, 30.0f);
	}

	// A content version that does not match gets IncompatibleVersion and changes nothing.
	for (const uint32 Version : { 0u, 2u })
	{
		FAethelnCombatActivationRequest Mismatched = MakeRequest(F, DefenseId);
		Mismatched.ContentVersion = Version;
		const int32 Spent = F.CostApplications;
		TestEqual(TEXT("A mismatched content version is refused"), F.Deliver(Mismatched), EResult::IncompatibleVersion);
		TestEqual(TEXT("It spends nothing"), F.CostApplications, Spent);
		TestTrue(TEXT("The stance is unchanged"), HasStance(F.ASC(), AttackTag) && StanceEffects(F.ASC()).Num() == 1);
	}
	TestEqual(TEXT("No cast of the test, refused or accepted, ended cancelled"), Cancels.Cancelled, 0);

	// Default, open: a cast inside a commitment window (the chain's or Instant Strike's) is refused with nothing spent, and
	// one after it is accepted and resets the chain like any committed action (OtherAction).
	for (const bool bStrike : { false, true })
	{
		FDefense G; if (!G.Init(*this, WithDefense())) { return false; }
		G.AdvanceTo(1.0);
		TestEqual(TEXT("The commitment starts"), bStrike ? G.Deliver(G.Request(AethelnGameplayTags::Ability_Oathscar_InstantStrike)) : G.Attack(), EResult::Accepted);
		G.AdvanceTo(1.25);
		const int32 Spent = G.CostApplications;
		TestEqual(TEXT("Refused inside the commitment window"), PressStance(G, AttackId), EResult::ActivationBlocked);
		TestEqual(TEXT("It spends nothing"), G.CostApplications, Spent);
		TestEqual(TEXT("It ends nothing"), G.ChainEnds.Num(), 0);
		TestEqual(TEXT("No stance"), StanceEffects(G.ASC()).Num(), 0);
		G.AdvanceTo(1.5);
		TestEqual(TEXT("Accepted after the window"), PressStance(G, AttackId), EResult::Accepted);
		if (TestEqual(TEXT("It resets the chain once"), G.ChainEnds.Num(), 1)) { TestEqual(TEXT("With OtherAction"), G.ChainEnds[0], EAethelnChainEndReason::OtherAction); }
		TestEqual(TEXT("The stance holds"), StanceEffects(G.ASC()).Num(), 1);
	}
	return true;
}

// K11. Red-first: with no removal tag requirement the stance survives the death effect and the first count after Kill fails.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnStanceRemovedOnDeathTest,
	"Aetheln.GameCombat.OathscarActives.StanceRemovedOnDeath",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnStanceRemovedOnDeathTest::RunTest(const FString& Parameters)
{
	using namespace AethelnOathscarStanceTests;
	constexpr float Delay = 2.0f;
	AethelnChainTests::FFixture F(true); if (!F.Init(*this, Stances())) { return false; }
	UAethelnDeathSubsystem* Deaths = F.World.World->GetSubsystem<UAethelnDeathSubsystem>();
	if (!TestNotNull(TEXT("The authority world owns the death subsystem"), Deaths) || !InstallGameMode(*this, *F.World.World)) { return false; }
	Deaths->ProvisionalRespawnDelaySeconds = Delay;
	UAethelnAbilitySystemComponent& Victim = *F.Player.AbilitySystem;
	const auto CastStance = [&](const FGameplayTag& Id) { return Victim.ProcessServerRequest(MakeRequest(Victim, F.NextSequence, Id)); };
	const auto Read = [&Victim](const FGameplayAttribute& Attribute) { return Victim.GetNumericAttribute(Attribute); };
	const FGameplayAttribute Health = UAethelnCombatAttributeSet::GetHealthAttribute();
	const FGameplayAttribute Endurance = UAethelnCombatAttributeSet::GetEnduranceAttribute();
	const FGameplayAttribute Guard = UAethelnCombatAttributeSet::GetGuardAttribute();

	F.AdvanceTo(0.5);
	TestEqual(TEXT("A stance is accepted"), CastStance(AttackId), EResult::Accepted);
	TestEqual(TEXT("It holds"), StanceEffects(Victim).Num(), 1);
	AethelnCombatTests::ApplyInstantModifier(Victim, Guard, EGameplayModOp::AddBase, -5.0f);

	// Re-possession keeps the stance: it lives on the PlayerState ASC, not on the avatar.
	const FActiveGameplayEffectHandle Before = OnlyStance(Victim);
	F.Player.Controller->UnPossess();
	TestEqual(TEXT("The stance survives the avatar loss"), StanceEffects(Victim).Num(), 1);
	AAethelnPlayerCharacter* Second = F.World.Spawn<AAethelnPlayerCharacter>();
	if (!TestNotNull(TEXT("A second pawn exists"), Second)) { return false; }
	F.Player.Controller->Possess(Second);
	if (TestEqual(TEXT("The stance survives re-possession"), StanceEffects(Victim).Num(), 1)) { TestTrue(TEXT("The same effect"), OnlyStance(Victim) == Before); }
	TestTrue(TEXT("Its tag still holds"), HasStance(Victim, AethelnGameplayTags::State_Oathscar_AttackStance));

	// Death removes the stance at the death effect's processing time.
	F.AdvanceTo(1.0);
	Kill(F);
	TestTrue(TEXT("The player is dead"), Victim.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestEqual(TEXT("The stance is gone"), StanceEffects(Victim).Num(), 0);
	TestFalse(TEXT("Its tag is gone"), HasStance(Victim, AethelnGameplayTags::State_Oathscar_AttackStance));

	// No cast while dead, and a stance effect cannot be applied to a dead player.
	const float EnduranceDead = Read(Endurance);
	TestEqual(TEXT("A cast while dead is refused"), CastStance(DefenseId), EResult::ActivationBlocked);
	TestEqual(TEXT("It spends nothing"), Read(Endurance), EnduranceDead);
	FGameplayEffectSpec Direct(GetDefault<UAethelnDefenseStanceEffect>(), Victim.MakeEffectContext(), 1.0f);
	Direct.SetSetByCallerMagnitude(AethelnGameplayTags::SetByCaller_Stance_Duration, FixtureDuration);
	TestFalse(TEXT("The effect is refused while dead"), Victim.ApplyGameplayEffectSpecToSelf(Direct).IsValid());
	TestEqual(TEXT("Still no stance"), StanceEffects(Victim).Num(), 0);

	// Respawn restores Health, Endurance and Guard and brings no stance back.
	F.AdvanceTo(1.0 + Delay + 0.1);
	TestFalse(TEXT("State.Dead is gone after the delay"), Victim.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestEqual(TEXT("Health is restored"), Read(Health), Read(UAethelnCombatAttributeSet::GetMaxHealthAttribute()));
	TestEqual(TEXT("Endurance is restored"), Read(Endurance), Read(UAethelnCombatAttributeSet::GetMaxEnduranceAttribute()));
	TestEqual(TEXT("Guard is restored"), Read(Guard), Read(UAethelnCombatAttributeSet::GetMaxGuardAttribute()));
	TestEqual(TEXT("No stance returns"), StanceEffects(Victim).Num(), 0);
	TestFalse(TEXT("Neither stance tag"), HasStance(Victim, AethelnGameplayTags::State_Oathscar_AttackStance) || HasStance(Victim, AethelnGameplayTags::State_Oathscar_DefenseStance));
	TestEqual(TEXT("The respawned player can cast again"), CastStance(DefenseId), EResult::Accepted);
	TestEqual(TEXT("And holds the new stance"), StanceEffects(Victim).Num(), 1);
	return true;
}

// K12: #60's A25 (request delivery) rows replayed against the stances. The server arrival time and the sequence rules decide;
// the stances have no cooldown or window, so the observable results are the stance effects and the spend.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnStanceNetworkConditionsTest,
	"Aetheln.GameCombat.OathscarActives.StanceNetworkConditions",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnStanceNetworkConditionsTest::RunTest(const FString& Parameters)
{
	using namespace AethelnOathscarStanceTests;
	using AethelnDefenseTests::FDefense;
	const FGameplayTag AttackTag = AethelnGameplayTags::State_Oathscar_AttackStance;
	const FGameplayTag DefenseTag = AethelnGameplayTags::State_Oathscar_DefenseStance;
	// Duplicated: the same request twice is one cast and one spend.
	{
		FDefense F; if (!F.Init(*this, Stances())) { return false; }
		F.AdvanceTo(1.0);
		FAethelnCombatActivationRequest Request = MakeRequest(F, AttackId);
		TestEqual(TEXT("Delivered"), F.Deliver(Request), EResult::Accepted);
		TestEqual(TEXT("A duplicate"), F.Deliver(Request), EResult::DuplicateSequence);
		TestEqual(TEXT("One stance effect"), StanceEffects(F.ASC()).Num(), 1);
		TestEqual(TEXT("One spend"), F.CostApplications, 1);
	}
	// A replay of an earlier cast, delivered after a later one replaced it, cannot bring the replaced stance back.
	{
		FDefense F; if (!F.Init(*this, Stances())) { return false; }
		F.AdvanceTo(1.0);
		FAethelnCombatActivationRequest Old = MakeRequest(F, AttackId);
		TestEqual(TEXT("The first cast"), F.Deliver(Old), EResult::Accepted);
		TestEqual(TEXT("The second cast replaces it"), PressStance(F, DefenseId), EResult::Accepted);
		TestEqual(TEXT("The late replay of the first cast is stale"), F.Deliver(Old), EResult::StaleSequence);
		TestTrue(TEXT("The replacing stance holds"), HasStance(F.ASC(), DefenseTag) && !HasStance(F.ASC(), AttackTag));
		TestEqual(TEXT("One stance effect"), StanceEffects(F.ASC()).Num(), 1);
		TestEqual(TEXT("Two spends in all"), F.CostApplications, 2);
	}
	// Reordered: the newer cast arrives first, so the older one is stale and applies nothing.
	{
		FDefense F; if (!F.Init(*this, Stances())) { return false; }
		F.AdvanceTo(1.0);
		FAethelnCombatActivationRequest Older = MakeRequest(F, DefenseId);
		FAethelnCombatActivationRequest Newer = MakeRequest(F, AttackId);
		TestEqual(TEXT("The newer arrives first"), F.Deliver(Newer), EResult::Accepted);
		TestEqual(TEXT("The older is stale"), F.Deliver(Older), EResult::StaleSequence);
		TestTrue(TEXT("The newer holds"), HasStance(F.ASC(), AttackTag) && !HasStance(F.ASC(), DefenseTag));
		TestEqual(TEXT("One stance effect"), StanceEffects(F.ASC()).Num(), 1);
		TestEqual(TEXT("One spend"), F.CostApplications, 1);
	}
	// Dropped: a cast never delivered changes nothing, and a later cast over a sequence gap is accepted.
	{
		FDefense F; if (!F.Init(*this, Stances())) { return false; }
		F.AdvanceTo(1.0);
		MakeRequest(F, AttackId); // dropped: never delivered
		TestEqual(TEXT("Nothing applied"), StanceEffects(F.ASC()).Num(), 0);
		TestEqual(TEXT("Nothing spent"), F.CostApplications, 0);
		TestEqual(TEXT("A later cast over a gap is accepted"), F.Deliver(MakeRequest(F, DefenseId, 20)), EResult::Accepted);
		TestEqual(TEXT("One stance effect"), StanceEffects(F.ASC()).Num(), 1);
		TestEqual(TEXT("One spend"), F.CostApplications, 1);
	}
	// Delayed: the server arrival time decides, never the client sample. A cast built at 0.5 and arriving at 1.25 is
	// judged at 1.25; one arriving while the player is dead is refused and applies nothing.
	{
		FDefense F; if (!F.Init(*this, Stances())) { return false; }
		F.AdvanceTo(0.5);
		FAethelnCombatActivationRequest Delayed = MakeRequest(F, AttackId);
		FAethelnCombatActivationRequest TooLate = MakeRequest(F, DefenseId);
		F.AdvanceTo(1.25);
		TestEqual(TEXT("The delayed cast is accepted at its arrival"), F.Deliver(Delayed), EResult::Accepted);
		const TArray<float> Remaining = F.ASC().GetActiveEffectsTimeRemaining(FGameplayEffectQuery::MakeQuery_MatchAnyOwningTags(StanceTags()));
		if (TestEqual(TEXT("One effect"), Remaining.Num(), 1)) { TestEqual(TEXT("Its duration starts at the arrival"), Remaining[0], FixtureDuration, 0.01f); }
		F.ASC().AddLooseGameplayTag(AethelnGameplayTags::State_Dead);
		const int32 Spent = F.CostApplications;
		TestEqual(TEXT("A cast arriving after death is refused"), F.Deliver(TooLate), EResult::ActivationBlocked);
		TestEqual(TEXT("It spends nothing"), F.CostApplications, Spent);
		F.ASC().RemoveLooseGameplayTag(AethelnGameplayTags::State_Dead);
	}
	return true;
}

#endif
