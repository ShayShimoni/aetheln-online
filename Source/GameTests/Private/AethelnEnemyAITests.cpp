#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnAbilitySystemComponent.h"
#include "AethelnChainTestFixture.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnEnemyCharacter.h"
#include "AethelnEnemyController.h"
#include "AethelnEnemyTestAbility.h"
#include "AethelnGameplayTags.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "GameFramework/PlayerState.h"
#include "GameplayTagsManager.h"
#include "Misc/AutomationTest.h"
#include "Navigation/PathFollowingComponent.h"
#include "UObject/UnrealType.h"

// #83 enemy AI foundation (docs/enemy-ai-and-navigation.md, Test Plan E1 to E11). The fixture's player stands at
// the origin aiming along +X with the test chain; the enemy stands still (movement disabled) and its controller
// uses test-only values, never tuning. Geometry: the enemy's radius-10 sphere, 60 units from the player, first
// touches the player's capsule at its step start + 0.125 + 0.125 * 8 / 30; the player's sphere first touches an
// enemy capsule 60 units ahead at the press + 0.125 + 0.125 * 16 / 30. The headless world has no navigation
// system, so every path request fails there (E9); real-navmesh coverage is E12, later.
namespace AethelnEnemyAITests
{
	using namespace AethelnChainTests;
	using EState = EAethelnEnemyState;

	constexpr double Telegraph = 0.1;
	constexpr double InterruptedPause = 0.2;
	constexpr double Respawn = 0.5;
	constexpr double StepRecoveryEnd = 0.625;

	struct FEnemy
	{
		AAethelnEnemyCharacter* Pawn = nullptr;
		AAethelnEnemyController* Controller = nullptr;
		UAethelnAbilitySystemComponent* AbilitySystem = nullptr;
	};

	FAethelnCombatAttributeInitValues MakeInit(float Health)
	{
		FAethelnCombatAttributeInitValues Values = AethelnCombatTests::MakeTestInitValues();
		Values.MaxHealth = Health;
		Values.Health = Health;
		return Values;
	}

	/** Spawns a still enemy at Location (its home) with the given attack class and test controller values. */
	bool SpawnEnemy(FAutomationTestBase& Test, const FFixture& F, FEnemy& Out, const FVector& Location,
		TSubclassOf<UAethelnEnemyAttackAbility> Attack = UAethelnEnemyAttackTestAbility::StaticClass(), float Health = 40.0f)
	{
		const FTransform Transform(Location);
		Out.Pawn = F.World.World->SpawnActorDeferred<AAethelnEnemyCharacter>(AAethelnEnemyCharacter::StaticClass(), Transform,
			nullptr, nullptr, ESpawnActorCollisionHandlingMethod::AlwaysSpawn);
		if (!Test.TestNotNull(TEXT("Enemy exists"), Out.Pawn)) { return false; }
		Out.Pawn->AttackAbilityClass = Attack;
		Out.Pawn->ProvisionalInitialAttributes = MakeInit(Health);
		Out.Pawn->FinishSpawning(Transform);
		// The harness world never reports HasBegunPlay (no game mode), so BeginPlay (home, init, grant) is dispatched by hand.
		Out.Pawn->DispatchBeginPlay();
		Out.Pawn->GetCharacterMovement()->DisableMovement();
		Out.Controller = Cast<AAethelnEnemyController>(Out.Pawn->GetController());
		Out.AbilitySystem = Out.Pawn->GetAethelnAbilitySystemComponent();
		if (!Test.TestNotNull(TEXT("The enemy controller possessed the enemy on spawn"), Out.Controller)) { return false; }
		Out.Controller->ProvisionalTelegraphSeconds = Telegraph;
		Out.Controller->ProvisionalInterruptedSeconds = InterruptedPause;
		Out.Controller->ProvisionalRespawnSeconds = Respawn;
		Out.Controller->ProvisionalAttackRange = 100.0;
		Out.Controller->ProvisionalPerceptionRadius = 400.0;
		Out.Controller->ProvisionalLeashRadius = 600.0;
		return true;
	}

	bool Init(FAutomationTestBase& Test, FFixture& F, int32 PlayerId = 1)
	{
		if (!F.Init(Test)) { return false; }
		F.Player.PlayerState->SetPlayerId(PlayerId);
		return true;
	}

	float Health(const UAethelnAbilitySystemComponent& AbilitySystem)
	{
		return AbilitySystem.GetNumericAttribute(UAethelnCombatAttributeSet::GetHealthAttribute());
	}

	const FAethelnCombatResult* FindResult(const FFixture& F, const FGameplayTag& AbilityId)
	{
		return F.Results.FindByPredicate([&AbilityId](const FAethelnCombatResult& Result) { return Result.AbilityId == AbilityId; });
	}

	void SetChainInterrupts(FFixture& F, bool bInterrupts)
	{
		for (FAethelnAttackStepDefinition& Step : F.Ability->ProvisionalSteps) { Step.bInterruptsTarget = bInterrupts; }
	}

	bool HasNetFunction(const UClass* Class)
	{
		for (TFieldIterator<UFunction> It(Class, EFieldIteratorFlags::ExcludeSuper); It; ++It)
		{
			if (It->HasAnyFunctionFlags(FUNC_Net)) { return true; }
		}
		return false;
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnEnemyServerOnlyTest,
	"Aetheln.GameCombat.EnemyAI.ServerOnly",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnEnemyServerOnlyTest::RunTest(const FString& Parameters)
{
	using namespace AethelnEnemyAITests;
	{
		// E1: identity, no client route, and the pawn's own ASC.
		FFixture F; if (!Init(*this, F)) { return false; }
		FEnemy E; if (!SpawnEnemy(*this, F, E, FVector(60.0, 0.0, 0.0))) { return false; }
		TestFalse(TEXT("The controller does not want a PlayerState"), static_cast<bool>(E.Controller->bWantsPlayerState));
		TestNull(TEXT("The enemy has no PlayerState"), E.Pawn->GetPlayerState());
		TestTrue(TEXT("FindForPawn resolves the enemy pawn's own ASC"), UAethelnAbilitySystemComponent::FindForPawn(E.Pawn) == E.AbilitySystem);
		TestFalse(TEXT("The enemy character declares no RPC"), HasNetFunction(AAethelnEnemyCharacter::StaticClass()));
		TestFalse(TEXT("The enemy controller declares no RPC"), HasNetFunction(AAethelnEnemyController::StaticClass()));
		TestFalse(TEXT("The enemy attack declares no RPC"), HasNetFunction(UAethelnEnemyAttackAbility::StaticClass()));
		const FProperty* Presentation = AAethelnEnemyCharacter::StaticClass()->FindPropertyByName(TEXT("PresentationState"));
		TestTrue(TEXT("The presentation state replicates"), Presentation != nullptr && Presentation->HasAnyPropertyFlags(CPF_Net));
		// Invalid command: no GAS route activates the attack, on the server or anywhere else.
		const FGameplayAbilitySpec* Spec = E.AbilitySystem->GetActivatableAbilities().FindByPredicate(
			[](const FGameplayAbilitySpec& Item) { return Cast<UAethelnEnemyAttackAbility>(Item.Ability) != nullptr; });
		if (TestNotNull(TEXT("The test attack is granted"), Spec))
		{
			TestFalse(TEXT("TryActivateAbility refuses the enemy attack"), E.AbilitySystem->TryActivateAbility(Spec->Handle));
			TestFalse(TEXT("The enemy attack never becomes active"), Spec->IsActive());
		}
	}
	{
		// E1: a client-mode world never drives the enemy or registers its step.
		FFixture F; if (!Init(*this, F)) { return false; }
		FEnemy E; if (!SpawnEnemy(*this, F, E, FVector(60.0, 0.0, 0.0))) { return false; }
		F.World.World->NextURL = TEXT("127.0.0.1:7777");
		if (TestTrue(TEXT("The world now derives client mode"), F.World.World->GetNetMode() == NM_Client))
		{
			F.AdvanceTo(0.5);
			TestEqual(TEXT("A client-mode world leaves the enemy idle"), E.Controller->GetState(), EState::Idle);
			TestEqual(TEXT("No enemy step is registered"), F.Timeline->GetRegisteredStepCountForTests(), 0);
		}
		F.World.World->NextURL.Empty();
	}
	{
		// E2: unset production config grants nothing, and the enemy never attacks.
		FFixture F; if (!Init(*this, F)) { return false; }
		AddExpectedMessagePlain(TEXT("Refused to grant ability"), ELogVerbosity::Warning, EAutomationExpectedMessageFlags::Contains, 1);
		FEnemy E; if (!SpawnEnemy(*this, F, E, FVector(60.0, 0.0, 0.0), UAethelnEnemyAttackAbility::StaticClass())) { return false; }
		TestNotNull(TEXT("The unset production attack has a grant problem"), GetDefault<UAethelnEnemyAttackAbility>()->FindGrantProblem());
		TestNull(TEXT("The test attack is valid"), GetDefault<UAethelnEnemyAttackTestAbility>()->FindGrantProblem());
		TestEqual(TEXT("Nothing is granted from unset config"), E.AbilitySystem->GetActivatableAbilities().Num(), 0);
		F.AdvanceTo(0.05); F.AdvanceTo(0.5);
		TestEqual(TEXT("Without an attack the enemy engages but never telegraphs"), E.Controller->GetState(), EState::Engage);
		TestEqual(TEXT("No enemy step is registered"), F.Timeline->GetRegisteredStepCountForTests(), 0);
	}
	{
		// Identity: the tag follows from the semantic ID (docs/combat-and-networking-architecture.md, Initial entries).
		const FGameplayTag Tag = AethelnGameplayTags::Ability_Enemy_Greybox_Strike;
		TestEqual(TEXT("The enemy attack tag"), Tag.ToString(), FString(TEXT("Ability.Enemy.Greybox.Strike")));
		TestEqual(TEXT("The enemy attack identity"), GetDefault<UAethelnEnemyAttackAbility>()->GetAbilityId(), Tag);
		TestTrue(TEXT("A valid Ability. tag"), UAethelnGameplayAbility::IsAbilityIdentityTag(Tag));
#if WITH_EDITORONLY_DATA
		const TSharedPtr<FGameplayTagNode> Node = UGameplayTagsManager::Get().FindTagNode(Tag);
		TestEqual(TEXT("The tag maps to its semantic ID"), Node.IsValid() ? Node->GetDevComment() : FString(), FString(TEXT("enemy.greybox.ability.strike")));
#endif
	}
	{
		// E2: a refused registration returns the enemy to Engage; neither the sequence nor the counter advances.
		FFixture F; if (!Init(*this, F)) { return false; }
		FEnemy E; if (!SpawnEnemy(*this, F, E, FVector(60.0, 0.0, 0.0))) { return false; }
		F.AdvanceTo(0.05);
		const double S = F.World.World->GetTimeSeconds() + Telegraph;
		F.Timeline->SetNextOrdinalForTests(MAX_uint64); // CanRegisterStep refuses an exhausted ordinal space
		F.AdvanceTo(S + 0.02);
		TestEqual(TEXT("No enemy step is registered"), F.Timeline->GetRegisteredStepCountForTests(), 0);
		TestEqual(TEXT("The attack counter did not advance"), E.Pawn->GetPresentationState().AttackCounter, 0u);
		TestEqual(TEXT("Back to Engage, then a new telegraph at the pass time"), E.Controller->GetState(), EState::Telegraph);
		TestEqual(TEXT("The new telegraph starts at the pass time"), E.Controller->GetStateStartTime(), F.World.World->GetTimeSeconds());
		F.Timeline->SetNextOrdinalForTests(1000);
		F.AdvanceTo(F.World.World->GetTimeSeconds() + Telegraph + 0.3);
		const FAethelnCombatResult* Result = FindResult(F, AethelnGameplayTags::Ability_Enemy_Greybox_Strike);
		if (TestNotNull(TEXT("The next attack registers and hits"), Result))
		{
			TestEqual(TEXT("The refused attempt used no sequence"), Result->Sequence, 1u);
		}
	}
	{
		// E2: unset controller config decides nothing.
		FFixture F; if (!Init(*this, F)) { return false; }
		FEnemy E; if (!SpawnEnemy(*this, F, E, FVector(60.0, 0.0, 0.0))) { return false; }
		E.Controller->ProvisionalPerceptionRadius = 0.0;
		F.AdvanceTo(0.5);
		TestEqual(TEXT("An unset perception radius leaves the enemy idle"), E.Controller->GetState(), EState::Idle);
		TestNull(TEXT("No target is chosen"), E.Controller->GetTarget());
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnEnemyAttackLifecycleTest,
	"Aetheln.GameCombat.EnemyAI.AttackLifecycle",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnEnemyAttackLifecycleTest::RunTest(const FString& Parameters)
{
	using namespace AethelnEnemyAITests;
	// E3 and E8: telegraph, a step at the exact telegraph end, contact, recovery, and the next telegraph.
	FFixture F; if (!Init(*this, F)) { return false; }
	FEnemy E; if (!SpawnEnemy(*this, F, E, FVector(60.0, 0.0, 0.0))) { return false; }
	F.AdvanceTo(0.05);
	const double T1 = F.World.World->GetTimeSeconds();
	TestEqual(TEXT("A player in range starts the telegraph"), E.Controller->GetState(), EState::Telegraph);
	TestEqual(TEXT("The telegraph starts at the tick time"), E.Controller->GetStateStartTime(), T1);
	TestTrue(TEXT("The player is the target"), E.Controller->GetTarget() == F.Pawn);
	TestEqual(TEXT("No step is registered during the telegraph"), F.Timeline->GetRegisteredStepCountForTests(), 0);
	// An uneven frame that overshoots the telegraph end.
	F.AdvanceTo(T1 + Telegraph + 0.07);
	const double S = T1 + Telegraph;
	TestEqual(TEXT("The attack follows the telegraph"), E.Controller->GetState(), EState::Attack);
	TestEqual(TEXT("The step starts at the authored telegraph end, not the tick"), E.Controller->GetStateStartTime(), S);
	TestEqual(TEXT("One enemy step is registered"), F.Timeline->GetRegisteredStepCountForTests(), 1);
	const FAethelnEnemyPresentationState& Shown = E.Pawn->GetPresentationState();
	TestEqual(TEXT("Presentation shows the attack"), Shown.State, EState::Attack);
	TestEqual(TEXT("Presentation carries the step start"), Shown.StepStartServerTime, S);
	TestTrue(TEXT("Presentation carries the ability id"), Shown.AbilityId == AethelnGameplayTags::Ability_Enemy_Greybox_Strike);
	TestEqual(TEXT("Presentation carries the content version"), Shown.ContentVersion, 1u);
	TestEqual(TEXT("Presentation counts the attack"), Shown.AttackCounter, 1u);
	TestTrue(TEXT("The aim points from the enemy at the player"), FVector(Shown.AcceptedAim).Equals(FVector(-1.0, 0.0, 0.0), 0.01));
	F.AdvanceTo(S + 0.3);
	const FAethelnCombatResult* Result = FindResult(F, AethelnGameplayTags::Ability_Enemy_Greybox_Strike);
	if (TestNotNull(TEXT("The enemy step hit the player"), Result))
	{
		TestEqual(TEXT("A hit"), Result->Outcome, EAethelnCombatResultOutcome::Hit);
		TestEqual(TEXT("The first enemy sequence is 1"), Result->Sequence, 1u);
		TestEqual(TEXT("The contact is at the authored geometry time"), Result->ContactTime, S + 0.125 + 0.125 * 8.0 / 30.0, 1.0e-6);
	}
	TestEqual(TEXT("The player took the authored damage"), Health(*F.Player.AbilitySystem), 35.0f);
	F.AdvanceTo(S + StepRecoveryEnd + 0.05);
	const double T2 = F.World.World->GetTimeSeconds();
	TestEqual(TEXT("After recovery the enemy telegraphs again"), E.Controller->GetState(), EState::Telegraph);
	TestEqual(TEXT("The second telegraph starts at the tick time"), E.Controller->GetStateStartTime(), T2);
	TestEqual(TEXT("The finished step was stamped and removed"), F.Timeline->GetRegisteredStepCountForTests(), 0);
	TestEqual(TEXT("Exactly one result so far"), F.Results.Num(), 1);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnEnemyInterruptionTest,
	"Aetheln.GameCombat.EnemyAI.Interruption",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnEnemyInterruptionTest::RunTest(const FString& Parameters)
{
	using namespace AethelnEnemyAITests;
	{
		// E4: a player hit inside the enemy step's interruptible window, before its active window.
		FFixture F; if (!Init(*this, F)) { return false; }
		SetChainInterrupts(F, true);
		FEnemy E; if (!SpawnEnemy(*this, F, E, FVector(60.0, 0.0, 0.0))) { return false; }
		int32 Notifications = 0;
		const FDelegateHandle Listener = F.Timeline->OnTargetInterrupted.AddLambda(
			[&E, &Notifications](UAethelnAbilitySystemComponent* Target, double) { Notifications += Target == E.AbilitySystem ? 1 : 0; });
		F.AdvanceTo(0.05);
		const double S = F.World.World->GetTimeSeconds() + Telegraph;
		TestEqual(TEXT("The player's press is accepted"), F.Press(), EAethelnActivationResult::Accepted);
		F.AdvanceTo(S + 0.05);
		TestEqual(TEXT("The enemy step started"), E.Controller->GetState(), EState::Attack);
		F.AdvanceTo(S + 0.15);
		const FAethelnCombatResult* PlayerHit = FindResult(F, AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain);
		if (TestNotNull(TEXT("The player hit the enemy"), PlayerHit))
		{
			TestTrue(TEXT("The contact is inside the enemy's interruptible window"), PlayerHit->ContactTime < S + 0.25);
			TestEqual(TEXT("The enemy is interrupted"), E.Controller->GetState(), EState::Interrupted);
			TestEqual(TEXT("The interruption starts at the contact time"), E.Controller->GetStateStartTime(), PlayerHit->ContactTime);
			TestEqual(TEXT("Presentation shows the interruption"), E.Pawn->GetPresentationState().State, EState::Interrupted);
		}
		TestEqual(TEXT("One notification for the one interruption"), Notifications, 1);
		// Copy the time: F.Results may reallocate as later passes commit results.
		const double ContactTime = PlayerHit != nullptr ? PlayerHit->ContactTime : S + 0.1;
		F.AdvanceTo(ContactTime + InterruptedPause + 0.05);
		TestEqual(TEXT("After the pause the enemy re-engages and telegraphs"), E.Controller->GetState(), EState::Telegraph);
		TestNull(TEXT("The interrupted step makes no later contact"), FindResult(F, AethelnGameplayTags::Ability_Enemy_Greybox_Strike));
		TestEqual(TEXT("The player took no damage"), Health(*F.Player.AbilitySystem), 40.0f);
		F.Timeline->OnTargetInterrupted.Remove(Listener);
	}
	{
		// E4: a hit after the interruptible window changes nothing.
		FFixture F; if (!Init(*this, F)) { return false; }
		SetChainInterrupts(F, true);
		FEnemy E; if (!SpawnEnemy(*this, F, E, FVector(60.0, 0.0, 0.0))) { return false; }
		int32 Notifications = 0;
		const FDelegateHandle Listener = F.Timeline->OnTargetInterrupted.AddLambda(
			[&E, &Notifications](UAethelnAbilitySystemComponent* Target, double) { Notifications += Target == E.AbilitySystem ? 1 : 0; });
		F.AdvanceTo(0.05);
		const double S = F.World.World->GetTimeSeconds() + Telegraph;
		F.AdvanceTo(S + 0.25);
		TestEqual(TEXT("The player's press is accepted"), F.Press(), EAethelnActivationResult::Accepted);
		F.AdvanceTo(S + 0.5);
		const FAethelnCombatResult* PlayerHit = FindResult(F, AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain);
		if (TestNotNull(TEXT("The player hit the enemy"), PlayerHit))
		{
			TestTrue(TEXT("The contact is after the interruptible window"), PlayerHit->ContactTime >= S + 0.25);
		}
		TestEqual(TEXT("The enemy stays in its attack"), E.Controller->GetState(), EState::Attack);
		TestEqual(TEXT("No notification"), Notifications, 0);
		TestNotNull(TEXT("The enemy step had already hit"), FindResult(F, AethelnGameplayTags::Ability_Enemy_Greybox_Strike));
		F.Timeline->OnTargetInterrupted.Remove(Listener);
	}
	{
		// E4 late case: one long frame takes the controller (pass step 1) past the first step's recovery end and into a
		// second step; the same pass then commits the player's earlier, interrupting contact. The late result wins.
		FFixture F; if (!Init(*this, F)) { return false; }
		SetChainInterrupts(F, true);
		FEnemy E; if (!SpawnEnemy(*this, F, E, FVector(60.0, 0.0, 0.0))) { return false; }
		E.Controller->ProvisionalTelegraphSeconds = 0.0; // the second step registers in the same pass
		F.AdvanceTo(0.05);
		const double S = F.World.World->GetTimeSeconds();
		TestEqual(TEXT("With no telegraph the first step starts at once"), E.Controller->GetState(), EState::Attack);
		TestEqual(TEXT("The player's press is accepted"), F.Press(), EAethelnActivationResult::Accepted);
		F.AdvanceTo(S + StepRecoveryEnd + 0.05);
		const FAethelnCombatResult* PlayerHit = FindResult(F, AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain);
		if (!TestNotNull(TEXT("The player hit the enemy in the long frame"), PlayerHit)) { return false; }
		TestTrue(TEXT("The contact is inside the first step's interruptible window"), PlayerHit->ContactTime < S + 0.25);
		TestEqual(TEXT("The second step was started before the interruption arrived"), E.Pawn->GetPresentationState().AttackCounter, 2u);
		TestEqual(TEXT("The late interruption wins"), E.Controller->GetState(), EState::Interrupted);
		TestEqual(TEXT("It starts at the earlier contact time"), E.Controller->GetStateStartTime(), PlayerHit->ContactTime);
		const double SecondStart = S + StepRecoveryEnd + 0.05;
		F.AdvanceTo(SecondStart + 0.3);
		int32 EnemyResults = 0;
		for (const FAethelnCombatResult& Result : F.Results)
		{
			if (Result.AbilityId != AethelnGameplayTags::Ability_Enemy_Greybox_Strike) { continue; }
			++EnemyResults;
			TestNotEqual(TEXT("The second step never started, so it made no contact"), Result.Sequence, 2u);
		}
		TestTrue(TEXT("The first step hit the player before the interruption"), EnemyResults >= 1);
	}
	{
		// E4 late case with a pending reset: in one long frame the controller goes Attack -> Engage -> Return -> reset
		// (the player left the leash), and the same pass commits the earlier interruption. It cancels the reset.
		FFixture F; if (!Init(*this, F)) { return false; }
		SetChainInterrupts(F, true);
		FEnemy E; if (!SpawnEnemy(*this, F, E, FVector(60.0, 0.0, 0.0))) { return false; }
		E.Controller->ProvisionalTelegraphSeconds = 0.0;
		F.AdvanceTo(0.05);
		const double S = F.World.World->GetTimeSeconds();
		TestEqual(TEXT("The step starts at once"), E.Controller->GetState(), EState::Attack);
		TestEqual(TEXT("The player's press is accepted"), F.Press(), EAethelnActivationResult::Accepted);
		E.Controller->ProvisionalLeashRadius = 50.0; // the player, 60 from home, is no longer eligible
		F.AdvanceTo(S + StepRecoveryEnd + 0.05);
		const FAethelnCombatResult* PlayerHit = FindResult(F, AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain);
		if (!TestNotNull(TEXT("The player hit the enemy in the long frame"), PlayerHit)) { return false; }
		TestEqual(TEXT("The late interruption wins over the pending reset"), E.Controller->GetState(), EState::Interrupted);
		TestEqual(TEXT("It starts at the contact time"), E.Controller->GetStateStartTime(), PlayerHit->ContactTime);
		TestEqual(TEXT("The cancelled reset did not heal the enemy"), Health(*E.AbilitySystem), 35.0f);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnEnemyDeathResetTest,
	"Aetheln.GameCombat.EnemyAI.DeathAndReset",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnEnemyDeathResetTest::RunTest(const FString& Parameters)
{
	using namespace AethelnEnemyAITests;
	// E5: a lethal hit during the enemy's wind-up, then the respawn at home with its initial attributes.
	FFixture F; if (!Init(*this, F)) { return false; }
	const FVector Home(60.0, 0.0, 0.0);
	FEnemy E; if (!SpawnEnemy(*this, F, E, Home, UAethelnEnemyAttackTestAbility::StaticClass(), 5.0f)) { return false; }
	F.AdvanceTo(0.05);
	const double S = F.World.World->GetTimeSeconds() + Telegraph;
	TestEqual(TEXT("The player's press is accepted"), F.Press(), EAethelnActivationResult::Accepted);
	F.AdvanceTo(S + 0.15);
	const FAethelnCombatResult* PlayerHit = FindResult(F, AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain);
	if (!TestNotNull(TEXT("The player hit the enemy"), PlayerHit)) { return false; }
	TestTrue(TEXT("The hit is lethal"), PlayerHit->bLethal);
	TestTrue(TEXT("The lethal contact is in the enemy's wind-up"), PlayerHit->ContactTime < S + 0.125);
	const double DeathTime = PlayerHit->ContactTime;
	TestEqual(TEXT("The enemy is dead in the pass that committed the lethal hit"), E.Controller->GetState(), EState::Dead);
	TestEqual(TEXT("Death starts at the lethal contact time"), E.Controller->GetStateStartTime(), DeathTime);
	TestEqual(TEXT("Presentation shows death at the contact time"), E.Pawn->GetPresentationState().StateStartServerTime, DeathTime);
	F.AdvanceTo(S + 0.2);
	TestNull(TEXT("A dead enemy has no target"), E.Controller->GetTarget());
	// Only the player's own chain step is left (registered until 0.05 + 0.625); the enemy's step, unstamped, would make it two.
	TestEqual(TEXT("The dead enemy's step is stamped and removed"), F.Timeline->GetRegisteredStepCountForTests(), 1);
	TestNull(TEXT("The dead enemy's step made no contact"), FindResult(F, AethelnGameplayTags::Ability_Enemy_Greybox_Strike));
	E.Pawn->SetActorLocation(FVector(200.0, 0.0, 0.0)); // moved while dead; reset must bring it home
	const double ResetTime = DeathTime + Respawn;
	F.AdvanceTo(ResetTime - 0.05);
	TestEqual(TEXT("Still dead before the respawn delay"), E.Controller->GetState(), EState::Dead);
	// A second player swings at the enemy's home in the respawn pass. The reset applies after the pass's emission, so
	// the swing resolves against the dead enemy still at 200 and commits nothing.
	FAttacker B;
	if (!F.SpawnAttacker(*this, B, FVector(120.0, 0.0, 0.0), 180.0)) { return false; }
	B.Player.PlayerState->SetPlayerId(7);
	const int32 ResultsBefore = F.Results.Num();
	TestEqual(TEXT("The second player's press is accepted"), B.Press(), EAethelnActivationResult::Accepted);
	F.AdvanceTo(ResetTime + 0.2);
	TestEqual(TEXT("The respawn-pass swing resolved against the pre-reset enemy"), F.Results.Num(), ResultsBefore);
	TestEqual(TEXT("The reset applied at the pass end: idle"), E.Controller->GetState(), EState::Idle);
	TestEqual(TEXT("Idle starts at the reset time"), E.Controller->GetStateStartTime(), ResetTime);
	TestEqual(TEXT("Health is restored to its initial value"), Health(*E.AbilitySystem), 5.0f);
	TestTrue(TEXT("The enemy is home"), E.Pawn->GetActorLocation().Equals(Home, 0.01));
	F.AdvanceTo(ResetTime + 0.25);
	TestEqual(TEXT("The reset enemy engages again"), E.Controller->GetState(), EState::Telegraph);
	TestTrue(TEXT("The tie goes to the lower PlayerId"), E.Controller->GetTarget() == F.Pawn);
	{
		// E5: not alive without a lethal result (Health set to zero by an effect): death starts at the pass time.
		FFixture G; if (!Init(*this, G)) { return false; }
		FEnemy D; if (!SpawnEnemy(*this, G, D, Home)) { return false; }
		G.AdvanceTo(0.05);
		TestEqual(TEXT("The enemy telegraphs"), D.Controller->GetState(), EState::Telegraph);
		AethelnCombatTests::ApplyInstantModifier(*D.AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::Override, 0.0f);
		G.AdvanceTo(0.08);
		TestEqual(TEXT("The enemy is dead"), D.Controller->GetState(), EState::Dead);
		TestEqual(TEXT("Death starts at the pass time"), D.Controller->GetStateStartTime(), G.World.World->GetTimeSeconds());
		TestEqual(TEXT("No step was registered"), G.Timeline->GetRegisteredStepCountForTests(), 0);
	}
	{
		// E5: a late lethal result cancels a return reset decided in the same pass (the target left the leash).
		FFixture G; if (!Init(*this, G)) { return false; }
		FEnemy D; if (!SpawnEnemy(*this, G, D, Home, UAethelnEnemyAttackTestAbility::StaticClass(), 5.0f)) { return false; }
		G.AdvanceTo(0.05);
		TestEqual(TEXT("The enemy telegraphs"), D.Controller->GetState(), EState::Telegraph);
		TestEqual(TEXT("The player's press is accepted"), G.Press(), EAethelnActivationResult::Accepted);
		D.Controller->ProvisionalLeashRadius = 50.0;
		G.AdvanceTo(0.3);
		const FAethelnCombatResult* Lethal = FindResult(G, AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain);
		if (!TestNotNull(TEXT("The player's lethal hit landed"), Lethal)) { return false; }
		const double LethalTime = Lethal->ContactTime;
		TestEqual(TEXT("Dead, not reset"), D.Controller->GetState(), EState::Dead);
		TestEqual(TEXT("Death starts at the lethal contact time"), D.Controller->GetStateStartTime(), LethalTime);
		TestEqual(TEXT("The cancelled reset did not heal the enemy"), Health(*D.AbilitySystem), 0.0f);
		G.AdvanceTo(LethalTime + Respawn - 0.02);
		TestEqual(TEXT("Still dead before the respawn delay"), D.Controller->GetState(), EState::Dead);
		G.AdvanceTo(LethalTime + Respawn + 0.02);
		TestEqual(TEXT("Respawned at the pass end, timed from the contact"), D.Controller->GetState(), EState::Idle);
		TestEqual(TEXT("Idle starts at the contact time plus the respawn delay"), D.Controller->GetStateStartTime(), LethalTime + Respawn);
		TestEqual(TEXT("Health is restored"), Health(*D.AbilitySystem), 5.0f);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnEnemyTargetChoiceTest,
	"Aetheln.GameCombat.EnemyAI.TargetChoice",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnEnemyTargetChoiceTest::RunTest(const FString& Parameters)
{
	using namespace AethelnEnemyAITests;
	// E6: two equidistant players; the lower PlayerId wins, whatever the controller order.
	for (const bool bSecondIsLower : { true, false })
	{
		FFixture F; if (!Init(*this, F, bSecondIsLower ? 2 : 1)) { return false; }
		FAttacker B;
		if (!F.SpawnAttacker(*this, B, FVector(120.0, 0.0, 0.0), 180.0)) { return false; }
		B.Player.PlayerState->SetPlayerId(bSecondIsLower ? 1 : 2);
		FEnemy E; if (!SpawnEnemy(*this, F, E, FVector(60.0, 50.0, 0.0))) { return false; }
		F.AdvanceTo(0.05);
		APawn* Lower = bSecondIsLower ? static_cast<APawn*>(B.Pawn) : static_cast<APawn*>(F.Pawn);
		APawn* Higher = bSecondIsLower ? static_cast<APawn*>(F.Pawn) : static_cast<APawn*>(B.Pawn);
		TestTrue(TEXT("The lower PlayerId is chosen"), E.Controller->GetTarget() == Lower);
		TestEqual(TEXT("The enemy telegraphs at it"), E.Controller->GetState(), EState::Telegraph);
		// The current target stays while it is eligible, even if the other player now has the lower id.
		(bSecondIsLower ? F.Player.PlayerState : B.Player.PlayerState)->SetPlayerId(0);
		F.AdvanceTo(0.08);
		TestTrue(TEXT("The current target is kept"), E.Controller->GetTarget() == Lower);
		// The target dies during the telegraph: no step, and the other player is chosen in the same tick.
		UAethelnAbilitySystemComponent* LowerAbilitySystem = UAethelnAbilitySystemComponent::FindForPawn(Lower);
		AethelnCombatTests::ApplyInstantModifier(*LowerAbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::Override, 0.0f);
		F.AdvanceTo(0.1);
		TestTrue(TEXT("The other player is chosen"), E.Controller->GetTarget() == Higher);
		TestEqual(TEXT("A new telegraph starts at the tick"), E.Controller->GetStateStartTime(), F.World.World->GetTimeSeconds());
		TestEqual(TEXT("No step was registered for the lost target"), F.Timeline->GetRegisteredStepCountForTests(), 0);
		TestEqual(TEXT("No attack was counted"), E.Pawn->GetPresentationState().AttackCounter, 0u);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnEnemyTargetLossTest,
	"Aetheln.GameCombat.EnemyAI.TargetLoss",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnEnemyTargetLossTest::RunTest(const FString& Parameters)
{
	using namespace AethelnEnemyAITests;
	enum class ELoss { Perception, Destroyed, Leash };
	// E7 and E11: each loss during the telegraph returns the enemy home with no step and full health.
	for (const ELoss Loss : { ELoss::Perception, ELoss::Destroyed, ELoss::Leash })
	{
		FFixture F; if (!Init(*this, F)) { return false; }
		const FVector Home(60.0, 0.0, 0.0);
		FEnemy E; if (!SpawnEnemy(*this, F, E, Home)) { return false; }
		F.AdvanceTo(0.05);
		TestEqual(TEXT("The enemy telegraphs"), E.Controller->GetState(), EState::Telegraph);
		AethelnCombatTests::ApplyInstantModifier(*E.AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::AddBase, -10.0f);
		switch (Loss)
		{
		case ELoss::Perception: F.Pawn->SetActorLocation(FVector(-1000.0, 0.0, 0.0)); break;
		case ELoss::Destroyed: F.Pawn->Destroy(); break;
		case ELoss::Leash: E.Controller->ProvisionalLeashRadius = 50.0; break;
		}
		F.AdvanceTo(0.1);
		TestEqual(TEXT("The enemy returned and reset to idle"), E.Controller->GetState(), EState::Idle);
		TestNull(TEXT("The target is dropped"), E.Controller->GetTarget());
		TestEqual(TEXT("No step was registered"), F.Timeline->GetRegisteredStepCountForTests(), 0);
		TestEqual(TEXT("The reset restored health"), Health(*E.AbilitySystem), 40.0f);
		TestTrue(TEXT("The enemy is home"), E.Pawn->GetActorLocation().Equals(Home, 0.01));
		F.AdvanceTo(0.2);
		TestEqual(TEXT("With no eligible target the enemy stays idle"), E.Controller->GetState(), EState::Idle);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnEnemyNavigationTest,
	"Aetheln.GameCombat.EnemyAI.Navigation",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnEnemyNavigationTest::RunTest(const FString& Parameters)
{
	using namespace AethelnEnemyAITests;
	{
		// E9: an unreachable target (no navigation data) returns the enemy home; one away from home is teleported.
		FFixture F; if (!Init(*this, F)) { return false; }
		const FVector Home(300.0, 0.0, 0.0);
		FEnemy E; if (!SpawnEnemy(*this, F, E, Home)) { return false; }
		E.Pawn->SetActorLocation(FVector(250.0, 0.0, 0.0));
		F.AdvanceTo(0.05);
		TestEqual(TEXT("A failed path ends in a reset to idle"), E.Controller->GetState(), EState::Idle);
		TestNull(TEXT("The unreachable target is dropped"), E.Controller->GetTarget());
		TestTrue(TEXT("The enemy is home"), E.Pawn->GetActorLocation().Equals(Home, 0.01));
		TestEqual(TEXT("No step was registered"), F.Timeline->GetRegisteredStepCountForTests(), 0);
	}
	{
		// E10: the stuck-recovery policy.
		using ERecovery = EAethelnEnemyMoveRecovery;
		TestEqual(TEXT("Blocked first repaths"), AAethelnEnemyController::DecideMoveRecovery(EPathFollowingResult::Blocked, 0), ERecovery::Repath);
		TestEqual(TEXT("Blocked again resets"), AAethelnEnemyController::DecideMoveRecovery(EPathFollowingResult::Blocked, 1), ERecovery::Reset);
		TestEqual(TEXT("OffPath first repaths"), AAethelnEnemyController::DecideMoveRecovery(EPathFollowingResult::OffPath, 0), ERecovery::Repath);
		TestEqual(TEXT("OffPath again resets"), AAethelnEnemyController::DecideMoveRecovery(EPathFollowingResult::OffPath, 1), ERecovery::Reset);
		TestEqual(TEXT("Success changes nothing"), AAethelnEnemyController::DecideMoveRecovery(EPathFollowingResult::Success, 1), ERecovery::None);
		TestEqual(TEXT("Aborted changes nothing"), AAethelnEnemyController::DecideMoveRecovery(EPathFollowingResult::Aborted, 1), ERecovery::None);
		TestEqual(TEXT("Invalid changes nothing"), AAethelnEnemyController::DecideMoveRecovery(EPathFollowingResult::Invalid, 1), ERecovery::None);
	}
	return true;
}

#endif
