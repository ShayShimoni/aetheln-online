#if WITH_DEV_AUTOMATION_TESTS && WITH_EDITOR

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatGameMode.h"
#include "AethelnCombatTestWorld.h"
#include "AethelnCombatTimelineSubsystem.h"
#include "AethelnEnemyAttackAbility.h"
#include "AethelnEnemyCharacter.h"
#include "AethelnEnemyController.h"
#include "AethelnGameplayTags.h"
#include "AethelnPlayerState.h"
#include "Components/PIENetworkComponent.h"
#include "Engine/NetConnection.h"
#include "EngineUtils.h"
#include "GameFramework/Character.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "GameFramework/GameStateBase.h"
#include "GameFramework/PlayerController.h"
#include "Misc/AutomationTest.h"

// #83 P3, Test Plan E13 (docs/enemy-ai-and-navigation.md). The harness of AethelnTwoClientDeathTests.cpp (CQTest's
// FPIENetworkComponent): a PIE session with one dedicated server and two clients in this process, on real net drivers
// over loopback, so replication, relevancy, and conditions are the engine's own. Client 0 is player A, the enemy's
// victim; client 1 is player B, who stays out of the enemy's perception. It simulates no input device and no separate
// process.
//
// The server spawns one enemy beside A with the promoted provisional values from Config/DefaultGame.ini (controller,
// attack, and initial attributes), so this is also the greybox enemy run on provisional values. The untitled map has no
// floor and no navigation, so the pawns are held still (MOVE_None), the enemy hovers (MOVE_Flying), and A stands inside attack range;
// walking on a real mesh is E12. Players' attribute values are fixture values (MakeTestInitValues), not tuning.
//
// What both clients must agree with the server on: the enemy's replicated state (the telegraph and the attack, with
// the attack counter, ability, version, and step start the server recorded), its public Health and MaxHealth (#61), the
// enemy's death and reset, and the enemy's result cues on A. The cue is an unreliable multicast by design, so an
// impaired link may drop one and the impaired variant only bounds the count; nothing authoritative depends on it.
namespace AethelnTwoClientEnemyTests
{
	using FState = FBasePIENetworkComponentState;
	using EState = EAethelnEnemyState;
	constexpr int32 VictimClient = 0;
	constexpr int32 ObserverClient = 1;

	/** Owns the builder and the component for the whole latent run; the queued lambdas point into it. */
	struct FRun
	{
		explicit FRun(FAutomationTestBase& InTest) : Test(InTest), Builder(InTest), Network(&InTest, Builder, false) {}

		FAutomationTestBase& Test;
		FTestCommandBuilder Builder;
		FPIENetworkComponent<FState> Network;
		FPacketSimulationSettings Packets;
		bool bImpaired = false;
		int32 VictimPlayerId = INDEX_NONE;
		FVector EnemyHome = FVector::ZeroVector;
		TWeakObjectPtr<AAethelnEnemyCharacter> ServerEnemy;
		TWeakObjectPtr<AAethelnEnemyController> ServerController;
		/** Server record of every enemy step: attack counter to step start, taken at each pass end. */
		TMap<uint32, double> ServerSteps;
		uint32 LastRecordedCounter = 0;
		int32 ServerHits = 0;
		float ServerVictimHealth = 0.0f;
		double ServerDeathTime = 0.0;
		int32 ClientHits[2] = { 0, 0 };
		bool bClientCueBound[2] = { false, false };
		bool bSawTelegraph[2] = { false, false };
		bool bSawAttack[2] = { false, false };
		bool bSawDead[2] = { false, false };
	};

	UAethelnAbilitySystemComponent* ServerAbilitySystem(const FState& Server, int32 ClientIndex)
	{
		const UNetConnection* Connection = Server.ClientConnections.IsValidIndex(ClientIndex) ? Server.ClientConnections[ClientIndex] : nullptr;
		const APlayerController* Controller = Connection != nullptr ? Connection->PlayerController.Get() : nullptr;
		const AAethelnPlayerState* PlayerState = Controller != nullptr ? Controller->GetPlayerState<AAethelnPlayerState>() : nullptr;
		return PlayerState != nullptr ? PlayerState->GetAethelnAbilitySystemComponent() : nullptr;
	}

	/** Player A's PlayerState as one client world received it, matched by the server's player id. */
	UAethelnAbilitySystemComponent* ClientVictimAbilitySystem(const FState& Client, int32 PlayerId)
	{
		const AGameStateBase* GameState = Client.World != nullptr ? Client.World->GetGameState() : nullptr;
		if (GameState == nullptr) { return nullptr; }
		for (APlayerState* PlayerState : GameState->PlayerArray)
		{
			if (PlayerState != nullptr && PlayerState->GetPlayerId() == PlayerId)
			{
				const AAethelnPlayerState* Aetheln = Cast<AAethelnPlayerState>(PlayerState);
				return Aetheln != nullptr ? Aetheln->GetAethelnAbilitySystemComponent() : nullptr;
			}
		}
		return nullptr;
	}

	AAethelnEnemyCharacter* ClientEnemy(const FState& Client)
	{
		if (Client.World == nullptr) { return nullptr; }
		for (TActorIterator<AAethelnEnemyCharacter> It(Client.World); It; ++It) { return *It; }
		return nullptr;
	}

	float Attribute(const UAethelnAbilitySystemComponent& AbilitySystem, const FGameplayAttribute& Which)
	{
		return AbilitySystem.GetNumericAttribute(Which);
	}

	void QueueTwoClientEnemy(FAutomationTestBase& Test, const FPacketSimulationSettings* Impairment)
	{
		// CQTest plays a new unsaved map, whose level and world settings have no stable package path for the net GUID cache.
		Test.AddExpectedMessage(TEXT("FNetGUIDCache::SupportsObject: Level /Temp/UEDPIE_\\d+_Untitled_\\d+\\.Untitled:PersistentLevel NOT Supported"), ELogVerbosity::Warning,
			EAutomationExpectedMessageFlags::Contains, 0);
		Test.AddExpectedMessage(TEXT("RegisterNetGUID_Client: Guid with pathname\\. FullNetGUIDPath: \\[\\d+\\]WorldSettings"), ELogVerbosity::Warning,
			EAutomationExpectedMessageFlags::Contains, 0);
		const TSharedRef<FRun> Run = MakeShared<FRun>(Test);
		FNetworkComponentBuilder<FState> NetworkBuilder;
		NetworkBuilder.WithClients(2).AsDedicatedServer().WithGameMode(AAethelnCombatGameMode::StaticClass());
		if (Impairment != nullptr)
		{
			Run->Packets = *Impairment;
			Run->bImpaired = true;
			NetworkBuilder.WithPacketSimulationSettings(&Run->Packets);
		}
		NetworkBuilder.Build(Run->Network);
		// Generous bounds: the run waits on replication under impairment, never on a fixed tick.
		const FTimespan Timeout = FTimespan::FromSeconds(30.0);
		const FAethelnCombatAttributeInitValues Init = AethelnCombatTests::MakeTestInitValues();
		// A takes a hit about every 0.7 s for the whole run; fixture Health this high keeps A alive through every wait.
		FAethelnCombatAttributeInitValues VictimInit = Init;
		VictimInit.MaxHealth = 400.0f;
		VictimInit.Health = 400.0f;
		const FAethelnCombatAttributeInitValues EnemyInit = GetDefault<AAethelnEnemyCharacter>()->ProvisionalInitialAttributes;
		const UAethelnEnemyAttackAbility* Attack = GetDefault<UAethelnEnemyAttackAbility>();
		FRun* R = &Run.Get();

		Run->Network
			.UntilServer(TEXT("Both players have a pawn and an ASC"), [](FState& Server)
			{
				for (int32 Index : { VictimClient, ObserverClient })
				{
					const UAethelnAbilitySystemComponent* AbilitySystem = ServerAbilitySystem(Server, Index);
					if (AbilitySystem == nullptr || AbilitySystem->GetAvatarActor() == nullptr) { return false; }
				}
				return true;
			}, Timeout)
			.ThenServer(TEXT("Give both players fixture attributes and hold them still, B out of the enemy's reach"), [R, Init, VictimInit](FState& Server)
			{
				// The ini's provisional player attributes are zero (TBD until #107): an eligible target needs Health.
				for (int32 Index : { VictimClient, ObserverClient })
				{
					UAethelnAbilitySystemComponent& AbilitySystem = *ServerAbilitySystem(Server, Index);
					UAethelnAttributeInitEffect::ApplyTo(AbilitySystem, Index == VictimClient ? VictimInit : Init);
					if (ACharacter* Pawn = Cast<ACharacter>(AbilitySystem.GetAvatarActor())) { Pawn->GetCharacterMovement()->DisableMovement(); }
				}
				UAethelnAbilitySystemComponent& Victim = *ServerAbilitySystem(Server, VictimClient);
				R->VictimPlayerId = CastChecked<APlayerState>(Victim.GetOwner())->GetPlayerId();
				ACharacter* VictimPawn = Cast<ACharacter>(Victim.GetAvatarActor());
				ACharacter* ObserverPawn = Cast<ACharacter>(ServerAbilitySystem(Server, ObserverClient)->GetAvatarActor());
				if (VictimPawn != nullptr && ObserverPawn != nullptr)
				{
					// 600 units from A and about 603 from the enemy, whose promoted perception radius is 400.
					ObserverPawn->SetActorLocation(VictimPawn->GetActorLocation() + FVector(0.0, -600.0, 0.0));
					R->EnemyHome = VictimPawn->GetActorLocation() + FVector(60.0, 0.0, 0.0);
				}
				else { R->Test.AddError(TEXT("A player has no character")); }
			})
			.UntilClients(TEXT("Both clients received player A, and listen for the enemy's cues on A"), [R](FState& Client)
			{
				UAethelnAbilitySystemComponent* AbilitySystem = ClientVictimAbilitySystem(Client, R->VictimPlayerId);
				if (AbilitySystem == nullptr) { return false; }
				if (!R->bClientCueBound[Client.ClientIndex])
				{
					R->bClientCueBound[Client.ClientIndex] = true;
					const int32 Index = Client.ClientIndex;
					AbilitySystem->OnCombatResultCue.AddLambda([R, Index](const FAethelnCombatResultCue& Cue)
					{
						if (Cue.Outcome == EAethelnCombatResultOutcome::Hit) { ++R->ClientHits[Index]; }
					});
				}
				return true;
			}, Timeout)
			.ThenServer(TEXT("Spawn the enemy beside A and record its results and its steps"), [R](FState& Server)
			{
				const FTransform Transform(R->EnemyHome);
				AAethelnEnemyCharacter* Enemy = Server.World->SpawnActorDeferred<AAethelnEnemyCharacter>(AAethelnEnemyCharacter::StaticClass(), Transform,
					nullptr, nullptr, ESpawnActorCollisionHandlingMethod::AlwaysSpawn);
				if (!R->Test.TestNotNull(TEXT("The server spawned the enemy"), Enemy)) { return; }
				Enemy->FinishSpawning(Transform);
				// Flying with no input stays put on this floorless map, and a teleport leaves it flying: MOVE_None would become Falling at the reset.
				Enemy->GetCharacterMovement()->SetMovementMode(MOVE_Flying);
				R->ServerEnemy = Enemy;
				R->ServerController = Cast<AAethelnEnemyController>(Enemy->GetController());
				R->Test.TestTrue(TEXT("An enemy controller possessed the enemy"), R->ServerController.IsValid());
				UAethelnCombatTimelineSubsystem* Timeline = Server.World->GetSubsystem<UAethelnCombatTimelineSubsystem>();
				if (!R->Test.TestNotNull(TEXT("The server world has the combat timeline"), Timeline)) { return; }
				Timeline->OnResultCommitted.AddLambda([R](const FAethelnCombatResult& Result)
				{
					if (Result.AbilityId == AethelnGameplayTags::Ability_Enemy_Greybox_Strike && Result.Outcome == EAethelnCombatResultOutcome::Hit) { ++R->ServerHits; }
				});
				// At each pass end the step fields are final for the pass; replication happens after it.
				Timeline->OnPassEnd.AddLambda([R](double)
				{
					const AAethelnEnemyCharacter* Current = R->ServerEnemy.Get();
					if (Current == nullptr) { return; }
					const FAethelnEnemyPresentationState& State = Current->GetPresentationState();
					if (State.AttackCounter != R->LastRecordedCounter)
					{
						R->LastRecordedCounter = State.AttackCounter;
						R->ServerSteps.Add(State.AttackCounter, State.StepStartServerTime);
					}
				});
			})
			.UntilClients(TEXT("Both clients received the enemy with public Health and MaxHealth, at its place"), [R, EnemyInit](FState& Client)
			{
				const AAethelnEnemyCharacter* Enemy = ClientEnemy(Client);
				const UAethelnAbilitySystemComponent* AbilitySystem = Enemy != nullptr ? Enemy->GetAethelnAbilitySystemComponent() : nullptr;
				if (AbilitySystem == nullptr) { return false; }
				// #61 (issue #61 comment 6131999614): Health and MaxHealth reach every client. The enemy has no owner,
				// so Endurance and Guard reach none; they stay at the class defaults on the client.
				if (Attribute(*AbilitySystem, UAethelnCombatAttributeSet::GetMaxHealthAttribute()) != EnemyInit.MaxHealth
					|| Attribute(*AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute()) > EnemyInit.Health) { return false; }
				const UAethelnCombatAttributeSet* Defaults = GetDefault<UAethelnCombatAttributeSet>();
				R->Test.TestEqual(TEXT("No client receives the enemy's Endurance"), Attribute(*AbilitySystem, UAethelnCombatAttributeSet::GetEnduranceAttribute()), Defaults->GetEndurance());
				R->Test.TestEqual(TEXT("No client receives the enemy's Guard"), Attribute(*AbilitySystem, UAethelnCombatAttributeSet::GetGuardAttribute()), Defaults->GetGuard());
				R->Test.TestTrue(TEXT("The enemy is where the server holds it"), FVector::Dist(Enemy->GetActorLocation(), R->EnemyHome) < 1.0);
				return true;
			}, Timeout)
			.UntilServer(TEXT("The enemy hit A at least twice"), [R](FState& Server)
			{
				R->Test.TestTrue(TEXT("Nothing but A is attacked: B is out of perception"), ServerAbilitySystem(Server, ObserverClient)->GetNumericAttribute(UAethelnCombatAttributeSet::GetHealthAttribute())
					== AethelnCombatTests::MakeTestInitValues().Health);
				return R->ServerHits >= 2;
			}, Timeout)
			.UntilClients(TEXT("Both clients saw the enemy's attack, as the server recorded it"), [R, Attack](FState& Client)
			{
				const AAethelnEnemyCharacter* Enemy = ClientEnemy(Client);
				if (Enemy == nullptr) { return false; }
				const int32 Index = Client.ClientIndex;
				const FAethelnEnemyPresentationState& State = Enemy->GetPresentationState();
				if (State.State == EState::Telegraph) { R->bSawTelegraph[Index] = true; }
				if (State.State == EState::Attack)
				{
					R->bSawAttack[Index] = true;
					R->Test.TestTrue(TEXT("The attack names the enemy strike"), State.AbilityId == AethelnGameplayTags::Ability_Enemy_Greybox_Strike);
					R->Test.TestEqual(TEXT("The attack carries the content version"), State.ContentVersion, Attack->ContentVersion);
					R->Test.TestEqual(TEXT("The attack state starts at the step start"), State.StateStartServerTime, State.StepStartServerTime);
					const double* ServerStepStart = R->ServerSteps.Find(State.AttackCounter);
					if (R->Test.TestNotNull(TEXT("The client's attack counter is one the server recorded"), ServerStepStart))
					{
						R->Test.TestEqual(TEXT("The client's step start is the server's"), State.StepStartServerTime, *ServerStepStart);
					}
				}
				// A telegraph lasts a fraction of a second, and a property that changes twice between net updates
				// replicates only its latest value, so the impaired variant requires only the attack.
				return R->bSawAttack[Index] && (R->bImpaired || R->bSawTelegraph[Index]);
			}, Timeout)
			.ThenServer(TEXT("Damage the enemy by 10"), [R](FState& /*Server*/)
			{
				AAethelnEnemyCharacter* Enemy = R->ServerEnemy.Get();
				if (!R->Test.TestNotNull(TEXT("The enemy still exists"), Enemy)) { return; }
				AethelnCombatTests::ApplyInstantModifier(*Enemy->GetAethelnAbilitySystemComponent(), UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::AddBase, -10.0f);
			})
			.UntilClients(TEXT("Both clients see the enemy's Health 10 lower, MaxHealth unchanged"), [EnemyInit](FState& Client)
			{
				const AAethelnEnemyCharacter* Enemy = ClientEnemy(Client);
				const UAethelnAbilitySystemComponent* AbilitySystem = Enemy != nullptr ? Enemy->GetAethelnAbilitySystemComponent() : nullptr;
				return AbilitySystem != nullptr
					&& Attribute(*AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute()) == EnemyInit.Health - 10.0f
					&& Attribute(*AbilitySystem, UAethelnCombatAttributeSet::GetMaxHealthAttribute()) == EnemyInit.MaxHealth;
			}, Timeout)
			.ThenServer(TEXT("Kill the enemy and blind it, so it stays idle after the reset"), [R](FState& Server)
			{
				AAethelnEnemyCharacter* Enemy = R->ServerEnemy.Get();
				AAethelnEnemyController* Controller = R->ServerController.Get();
				if (Enemy == nullptr || Controller == nullptr) { R->Test.AddError(TEXT("The enemy or its controller no longer exists")); return; }
				// A perception radius of 1 leaves no eligible target, so after the reset the enemy stays idle and the results stop.
				Controller->ProvisionalPerceptionRadius = 1.0;
				R->ServerDeathTime = Server.World->GetTimeSeconds();
				AethelnCombatTests::ApplyInstantModifier(*Enemy->GetAethelnAbilitySystemComponent(), UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::Override, 0.0f);
			})
			.UntilClients(TEXT("Both clients see the enemy dead"), [R](FState& Client)
			{
				const AAethelnEnemyCharacter* Enemy = ClientEnemy(Client);
				if (Enemy != nullptr && Enemy->GetPresentationState().State == EState::Dead) { R->bSawDead[Client.ClientIndex] = true; }
				return R->bSawDead[Client.ClientIndex];
			}, Timeout)
			.UntilServer(TEXT("The server resets the enemy home at full Health, no earlier than the respawn delay"), [R, EnemyInit](FState& Server)
			{
				const AAethelnEnemyController* Controller = R->ServerController.Get();
				const AAethelnEnemyCharacter* Enemy = R->ServerEnemy.Get();
				if (Controller == nullptr || Enemy == nullptr || Controller->GetState() != EState::Idle) { return false; }
				const UAethelnAbilitySystemComponent* AbilitySystem = Enemy->GetAethelnAbilitySystemComponent();
				if (Attribute(*AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute()) != EnemyInit.Health) { return false; }
				R->Test.TestTrue(TEXT("The reset comes no earlier than the death time plus the respawn delay"),
					Server.World->GetTimeSeconds() >= R->ServerDeathTime + GetDefault<AAethelnEnemyController>()->ProvisionalRespawnSeconds);
				R->Test.TestTrue(TEXT("The reset enemy is home"), FVector::Dist(Enemy->GetActorLocation(), R->EnemyHome) < 1.0);
				// The enemy is dead or idle from here on, so no result can follow.
				R->ServerVictimHealth = Attribute(*ServerAbilitySystem(Server, VictimClient), UAethelnCombatAttributeSet::GetHealthAttribute());
				R->Test.TestTrue(TEXT("A is still alive: the waits above ended on the enemy, not on A's death"), R->ServerVictimHealth > 0.0f);
				return true;
			}, Timeout)
			.UntilClients(TEXT("Both clients see the enemy idle at home with full Health, and A's Health the server's"), [R, EnemyInit](FState& Client)
			{
				const AAethelnEnemyCharacter* Enemy = ClientEnemy(Client);
				const UAethelnAbilitySystemComponent* AbilitySystem = Enemy != nullptr ? Enemy->GetAethelnAbilitySystemComponent() : nullptr;
				const UAethelnAbilitySystemComponent* Victim = ClientVictimAbilitySystem(Client, R->VictimPlayerId);
				return AbilitySystem != nullptr && Victim != nullptr
					&& Enemy->GetPresentationState().State == EState::Idle
					&& Attribute(*AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute()) == EnemyInit.Health
					&& FVector::Dist(Enemy->GetActorLocation(), R->EnemyHome) < 1.0
					&& Attribute(*Victim, UAethelnCombatAttributeSet::GetHealthAttribute()) == R->ServerVictimHealth;
			}, Timeout)
			.ThenServer(TEXT("Result cue counts"), [R](FState& /*Server*/)
			{
				R->Test.TestTrue(TEXT("The server counted the enemy's hits on A"), R->ServerHits >= 2);
				for (int32 Index : { VictimClient, ObserverClient })
				{
					// The cue is unreliable by design: an impaired link may drop it, and nothing authoritative depends on it.
					if (R->bImpaired) { R->Test.TestTrue(TEXT("A client never receives more result cues than the server committed"), R->ClientHits[Index] <= R->ServerHits); }
					else { R->Test.TestEqual(TEXT("On a clean loopback link each client receives every result cue once"), R->ClientHits[Index], R->ServerHits); }
				}
			});

		FAutomationTestFramework& Framework = FAutomationTestFramework::Get();
		Framework.EnqueueLatentCommand(Run->Builder.Build());
		Framework.EnqueueLatentCommand(Run->Builder.BuildTearDown());
		// Wait for the editor to end the PIE session, then release the run (the last reference to the lambdas' state).
		// Bounded like CQTest's own steps, so a PIE session that never ends fails this test by name instead of the suite timeout.
		Framework.EnqueueLatentCommand(MakeShared<FFunctionLatentCommand>([Run, Start = TOptional<FDateTime>()]() mutable
		{
			if (!Start.IsSet()) { Start = FDateTime::UtcNow(); }
			bool bPieEnded = true;
			for (const FWorldContext& Context : GEngine->GetWorldContexts())
			{
				bPieEnded &= !(Context.WorldType == EWorldType::PIE && Context.World() != nullptr);
			}
			if (!bPieEnded && FDateTime::UtcNow() - Start.GetValue() < FTimespan::FromSeconds(30.0)) { return false; }
			if (!bPieEnded) { Run->Test.AddError(FString::Printf(TEXT("%s: PIE did not end within 30 s after the E13 teardown"), *Run->Test.GetTestFullName())); }
			return true;
		}));
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnTwoClientEnemyTest,
	"Aetheln.GameCombat.EnemyAI.TwoClientEnemy",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnTwoClientEnemyTest::RunTest(const FString& Parameters)
{
	AethelnTwoClientEnemyTests::QueueTwoClientEnemy(*this, nullptr);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnTwoClientEnemyImpairedTest,
	"Aetheln.GameCombat.EnemyAI.TwoClientEnemyImpaired",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnTwoClientEnemyImpairedTest::RunTest(const FString& Parameters)
{
	// Fixture impairment on every driver, both directions: 100 ms lag each way and 5 % loss. These are test settings,
	// not the #45 network profile.
	FPacketSimulationSettings Impairment;
	Impairment.PktLag = 100;
	Impairment.PktLoss = 5;
	AethelnTwoClientEnemyTests::QueueTwoClientEnemy(*this, &Impairment);
	return true;
}

#endif
