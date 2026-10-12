#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnAbilitySystemComponent.h"
#include "AethelnChainTestFixture.h"
#include "AethelnCombatAICharacter.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnGameplayTags.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "Misc/AutomationTest.h"

// #21 P1 server death state (docs/death-and-respawn.md, Test Plan R1 and R2). The tests zero a player's Health and
// raise the timeline's lethal notification, the seam the lethal latch uses. The real lethal path (an AI swing that
// kills the player) is the lethal row of Aetheln.GameCombat.AttackTimeline.Interruption.
namespace AethelnDeathTests
{
	using namespace AethelnChainTests;
	using EResult = EAethelnActivationResult;

	void ZeroHealth(UAethelnAbilitySystemComponent& AbilitySystem)
	{
		AethelnCombatTests::ApplyInstantModifier(AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::AddBase,
			-AethelnCombatTests::MakeTestInitValues().Health);
	}

	/** By class: an owning-tag query reads the definition's tags only, not the spec's dynamic granted State.Dead. */
	int32 DeathEffects(const UAethelnAbilitySystemComponent& AbilitySystem)
	{
		FGameplayEffectQuery Query;
		Query.EffectDefinition = UAethelnDeathStateEffect::StaticClass();
		return AbilitySystem.GetActiveEffects(Query).Num();
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnLethalNotificationAppliesDeathTest,
	"Aetheln.GameCombat.Death.LethalNotificationAppliesDeath",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnLethalNotificationAppliesDeathTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDeathTests;
	FFixture F; if (!F.Init(*this)) { return false; }
	FAttacker Living;
	if (!F.SpawnAttacker(*this, Living, FVector(0.0, 300.0, 0.0), 0.0)) { return false; }
	AAethelnCombatAICharacter* Dummy = F.SpawnTarget(*this, FVector(300.0, 0.0, 0.0));
	if (Dummy == nullptr) { return false; }
	UAethelnAbilitySystemComponent& Victim = *F.Player.AbilitySystem;

	// The server reads authoritative Health: a notification for a living player kills nobody.
	F.Timeline->OnLethalResult.Broadcast(Living.Player.AbilitySystem, FGuid::NewGuid());
	TestFalse(TEXT("A player with Health above zero gets no death state"), Living.Player.AbilitySystem->HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));

	ZeroHealth(Victim);
	F.Timeline->OnLethalResult.Broadcast(&Victim, FGuid::NewGuid());
	TestTrue(TEXT("The lethal notification applies State.Dead"), Victim.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestEqual(TEXT("State.Dead comes from one death-state effect, not a loose tag"), DeathEffects(Victim), 1);

	// AC3: a repeated notification is not a second death.
	F.Timeline->OnLethalResult.Broadcast(&Victim, FGuid::NewGuid());
	TestEqual(TEXT("A repeated notification adds no second death effect"), DeathEffects(Victim), 1);
	TestEqual(TEXT("State.Dead is held once"), Victim.GetTagCount(AethelnGameplayTags::State_Dead), 1);
	TestFalse(TEXT("The other player is still alive"), Living.Player.AbilitySystem->HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));

	// #21 is player death only; #20 owns AI death.
	UAethelnAbilitySystemComponent* DummyAbilitySystem = Dummy->GetAethelnAbilitySystemComponent();
	ZeroHealth(*DummyAbilitySystem);
	F.Timeline->OnLethalResult.Broadcast(DummyAbilitySystem, FGuid::NewGuid());
	TestEqual(TEXT("An AI victim gets no player death effect"), DeathEffects(*DummyAbilitySystem), 0);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDeadPlayerRefusesActionsTest,
	"Aetheln.GameCombat.Death.DeadPlayerRefusesActions",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDeadPlayerRefusesActionsTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDeathTests;
	FFixture F; if (!F.Init(*this)) { return false; }
	// Fixture geometry from the contact tests: a dummy 60 units ahead is first touched at S + 0.19.
	AAethelnCombatAICharacter* Dummy = F.SpawnTarget(*this, FVector(60.0, 0.0, 0.0));
	if (Dummy == nullptr) { return false; }
	UAethelnAbilitySystemComponent& Victim = *F.Player.AbilitySystem;
	const float DummyHealth = Dummy->GetAethelnAbilitySystemComponent()->GetNumericAttribute(UAethelnCombatAttributeSet::GetHealthAttribute());

	TestEqual(TEXT("The living player's chain starts"), F.Press(), EResult::Accepted);
	F.AdvanceTo(0.15);
	// The fixture parks the pawn in MOVE_None; give it a live mode so the death transition has something to stop.
	// Flying with no input keeps the pawn, and so the step's sweep, still. The no-contact check below is a regression
	// guard only: zero Health alone already makes the attacker not alive (the timeline's liveness rule), so it holds
	// without State.Dead; A13 (DeadLifeStateRejected) is the State.Dead contact evidence.
	UCharacterMovementComponent* Movement = F.Pawn->GetCharacterMovement();
	Movement->SetMovementMode(MOVE_Flying);
	TestNotEqual(TEXT("The living pawn can move"), static_cast<int32>(Movement->MovementMode), static_cast<int32>(MOVE_None));

	ZeroHealth(Victim);
	F.Timeline->OnLethalResult.Broadcast(&Victim, FGuid::NewGuid());
	TestTrue(TEXT("The player is dead"), Victim.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
	TestEqual(TEXT("The server stops the dead avatar's movement"), static_cast<int32>(Movement->MovementMode), static_cast<int32>(MOVE_None));
	TestFalse(TEXT("No ability stays active"), F.Ability->IsActive());
	if (TestEqual(TEXT("Death ends the chain once"), F.Ends.Num(), 1))
	{
		TestEqual(TEXT("The chain ends as IncompatibleState"), F.Ends[0].Reason, EAethelnChainEndReason::IncompatibleState);
	}

	F.AdvanceTo(0.5);
	TestEqual(TEXT("The dead player's pending contact resolves nothing"), F.Results.Num(), 0);
	TestEqual(TEXT("The dummy takes no damage"),
		Dummy->GetAethelnAbilitySystemComponent()->GetNumericAttribute(UAethelnCombatAttributeSet::GetHealthAttribute()), DummyHealth);
	TestEqual(TEXT("A dead player's press is refused"), F.Press(), EResult::ActivationBlocked);
	F.AdvanceTo(1.0);
	TestEqual(TEXT("Still no result"), F.Results.Num(), 0);
	TestEqual(TEXT("Still one chain end"), F.Ends.Num(), 1);
	return true;
}

#endif
