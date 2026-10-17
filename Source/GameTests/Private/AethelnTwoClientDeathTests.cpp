#if WITH_DEV_AUTOMATION_TESTS && WITH_EDITOR

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatGameMode.h"
#include "AethelnCombatTestWorld.h"
#include "AethelnCombatTimelineSubsystem.h"
#include "AethelnDeathSubsystem.h"
#include "AethelnGameplayTags.h"
#include "AethelnLocalPlayer.h"
#include "AethelnPlayerState.h"
#include "Components/PIENetworkComponent.h"
#include "Engine/NetConnection.h"
#include "GameFramework/Character.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "GameFramework/GameStateBase.h"
#include "GameFramework/PlayerController.h"
#include "Misc/AutomationTest.h"

// #21 P3, Test Plan R5 (docs/death-and-respawn.md). A PIE session with one dedicated server and two clients in this
// process, on real net drivers over loopback (CQTest's FPIENetworkComponent): replication, relevancy, conditions, RPCs
// and character movement corrections are the engine's own. Client 0 is player A, the victim; client 1 is player B.
// It simulates no input device and no separate process. The server kills A through the timeline's lethal notification,
// and the respawn follows the configured delay. Attribute values are fixture values (MakeTestInitValues), not tuning.
namespace AethelnTwoClientDeathTests
{
	using FState = FBasePIENetworkComponentState;
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
		TWeakObjectPtr<APawn> ServerCorpse;
		double ServerDeathTime = 0.0;
		TWeakObjectPtr<APawn> ClientCorpse[2];
		int32 ServerCues = 0;
		int32 ClientCues[2] = { 0, 0 };
		bool bClientCueBound[2] = { false, false };
		FString ServerKeys[2];
		TWeakObjectPtr<UAethelnAbilitySystemComponent> ServerKept;
	};

	UAethelnAbilitySystemComponent* ServerAbilitySystem(const FState& Server, int32 ClientIndex)
	{
		const UNetConnection* Connection = Server.ClientConnections.IsValidIndex(ClientIndex) ? Server.ClientConnections[ClientIndex] : nullptr;
		const APlayerController* Controller = Connection != nullptr ? Connection->PlayerController.Get() : nullptr;
		const AAethelnPlayerState* PlayerState = Controller != nullptr ? Controller->GetPlayerState<AAethelnPlayerState>() : nullptr;
		return PlayerState != nullptr ? PlayerState->GetAethelnAbilitySystemComponent() : nullptr;
	}

	/** Player A's PlayerState as one client world received it, matched by the server's player id. */
	AAethelnPlayerState* ClientVictim(const FState& Client, int32 PlayerId)
	{
		const AGameStateBase* GameState = Client.World != nullptr ? Client.World->GetGameState() : nullptr;
		if (GameState == nullptr) { return nullptr; }
		for (APlayerState* PlayerState : GameState->PlayerArray)
		{
			if (PlayerState != nullptr && PlayerState->GetPlayerId() == PlayerId) { return Cast<AAethelnPlayerState>(PlayerState); }
		}
		return nullptr;
	}

	float Attribute(const UAethelnAbilitySystemComponent& AbilitySystem, const FGameplayAttribute& Which)
	{
		return AbilitySystem.GetNumericAttribute(Which);
	}

	/** A new avatar: a live pawn that is not the corpse, which the client's ASC copy uses and which is not dead. */
	bool HasNewLivingAvatar(const AAethelnPlayerState* PlayerState, const TWeakObjectPtr<APawn>& Corpse)
	{
		const UAethelnAbilitySystemComponent* AbilitySystem = PlayerState != nullptr ? PlayerState->GetAethelnAbilitySystemComponent() : nullptr;
		APawn* Pawn = PlayerState != nullptr ? PlayerState->GetPawn() : nullptr;
		return AbilitySystem != nullptr && Pawn != nullptr && Pawn != Corpse.Get() && !Pawn->IsActorBeingDestroyed()
			&& AbilitySystem->GetAvatarActor() == Pawn && !AbilitySystem->HasMatchingGameplayTag(AethelnGameplayTags::State_Dead);
	}

	void ExpectUnsavedMapWarnings(FAutomationTestBase& Test)
	{
		// CQTest plays a new unsaved map, whose level and world settings have no stable package path for the net GUID cache.
		Test.AddExpectedMessage(TEXT("FNetGUIDCache::SupportsObject: Level /Temp/UEDPIE_\\d+_Untitled_\\d+\\.Untitled:PersistentLevel NOT Supported"), ELogVerbosity::Warning,
			EAutomationExpectedMessageFlags::Contains, 0);
		Test.AddExpectedMessage(TEXT("RegisterNetGUID_Client: Guid with pathname\\. FullNetGUIDPath: \\[\\d+\\]WorldSettings"), ELogVerbosity::Warning,
			EAutomationExpectedMessageFlags::Contains, 0);
	}

	/** Queues the run's steps, CQTest's teardown, and a bounded wait for the editor to end the PIE session. */
	void EnqueueWithTeardown(const TSharedRef<FRun>& Run, const FTimespan& Timeout)
	{
		FAutomationTestFramework& Framework = FAutomationTestFramework::Get();
		Framework.EnqueueLatentCommand(Run->Builder.Build());
		Framework.EnqueueLatentCommand(Run->Builder.BuildTearDown());
		// Wait for the editor to end the PIE session, then release the run (the last reference to the lambdas' state).
		// Bounded like CQTest's own steps, so a PIE session that never ends fails this test by name instead of the suite timeout.
		Framework.EnqueueLatentCommand(MakeShared<FFunctionLatentCommand>([Run, Timeout, Start = TOptional<FDateTime>()]() mutable
		{
			if (!Start.IsSet()) { Start = FDateTime::UtcNow(); }
			bool bPieEnded = true;
			for (const FWorldContext& Context : GEngine->GetWorldContexts())
			{
				bPieEnded &= !(Context.WorldType == EWorldType::PIE && Context.World() != nullptr);
			}
			if (!bPieEnded && FDateTime::UtcNow() - Start.GetValue() < Timeout) { return false; }
			if (!bPieEnded) { Run->Test.AddError(FString::Printf(TEXT("%s: PIE did not end within %.0f s after the teardown"), *Run->Test.GetTestFullName(), Timeout.GetTotalSeconds())); }
			return true;
		}));
	}

	void QueueTwoClientDeathAndRespawn(FAutomationTestBase& Test, const FPacketSimulationSettings* Impairment)
	{
		ExpectUnsavedMapWarnings(Test);
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
		const FAethelnCombatAttributeInitValues Init =AethelnCombatTests::MakeTestInitValues();
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
			.ThenServer(TEXT("Give both players fixture attributes"), [R, Init](FState& Server)
			{
				// The ini sets the owner's provisional attributes (#19), equal to the fixture values; applying them keeps this test independent of a later re-tune.
				for (int32 Index : { VictimClient, ObserverClient }) { UAethelnAttributeInitEffect::ApplyTo(*ServerAbilitySystem(Server, Index), Init); }
				UAethelnAbilitySystemComponent& Victim = *ServerAbilitySystem(Server, VictimClient);
				R->VictimPlayerId = CastChecked<APlayerState>(Victim.GetOwner())->GetPlayerId();
				Victim.OnDeathCue.AddLambda([R] { ++R->ServerCues; });
			})
			.UntilClients(TEXT("Both clients received player A, its pawn and its attributes"), [R, Init](FState& Client)
			{
				AAethelnPlayerState* PlayerState = ClientVictim(Client, R->VictimPlayerId);
				UAethelnAbilitySystemComponent* AbilitySystem = PlayerState != nullptr ? PlayerState->GetAethelnAbilitySystemComponent() : nullptr;
				if (AbilitySystem == nullptr || PlayerState->GetPawn() == nullptr) { return false; }
				if (Client.ClientIndex == VictimClient
					&& (Attribute(*AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute()) != Init.Health
						|| Attribute(*AbilitySystem, UAethelnCombatAttributeSet::GetGuardAttribute()) != Init.Guard))
				{
					return false;
				}
				if (Client.ClientIndex == ObserverClient)
				{
					// #61 (issue #61 comment 6131999614): Health and MaxHealth reach every client.
					if (Attribute(*AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute()) != Init.Health
						|| Attribute(*AbilitySystem, UAethelnCombatAttributeSet::GetMaxHealthAttribute()) != Init.MaxHealth)
					{
						return false;
					}
					// Endurance and Guard changed in the same server frame and set, so had they replicated to B they would be here
					// now. They stay owner-only: B's copy keeps the class defaults.
					const UAethelnCombatAttributeSet* Defaults = GetDefault<UAethelnCombatAttributeSet>();
					R->Test.TestEqual(TEXT("B never receives A's Endurance"), Attribute(*AbilitySystem, UAethelnCombatAttributeSet::GetEnduranceAttribute()), Defaults->GetEndurance());
					R->Test.TestEqual(TEXT("B never receives A's MaxEndurance"), Attribute(*AbilitySystem, UAethelnCombatAttributeSet::GetMaxEnduranceAttribute()), Defaults->GetMaxEndurance());
					R->Test.TestEqual(TEXT("B never receives A's Guard"), Attribute(*AbilitySystem, UAethelnCombatAttributeSet::GetGuardAttribute()), Defaults->GetGuard());
					R->Test.TestEqual(TEXT("B never receives A's MaxGuard"), Attribute(*AbilitySystem, UAethelnCombatAttributeSet::GetMaxGuardAttribute()), Defaults->GetMaxGuard());
					R->Test.TestNotEqual(TEXT("The fixture Endurance differs from the default, so the check can fail"), Init.Endurance, Defaults->GetEndurance());
				}
				if (!R->bClientCueBound[Client.ClientIndex])
				{
					R->bClientCueBound[Client.ClientIndex] = true;
					const int32 Index = Client.ClientIndex;
					AbilitySystem->OnDeathCue.AddLambda([R, Index] { ++R->ClientCues[Index]; });
				}
				R->ClientCorpse[Client.ClientIndex] = PlayerState->GetPawn();
				return true;
			}, Timeout)
			.ThenServer(TEXT("Kill player A, then repeat the lethal notification"), [R](FState& Server)
			{
				UAethelnAbilitySystemComponent& Victim = *ServerAbilitySystem(Server, VictimClient);
				AethelnCombatTests::ApplyInstantModifier(Victim, UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::Override, 0.0f);
				UAethelnCombatTimelineSubsystem* Timeline = Server.World->GetSubsystem<UAethelnCombatTimelineSubsystem>();
				if (!R->Test.TestNotNull(TEXT("The server world has the combat timeline"), Timeline)) { return; }
				R->ServerDeathTime = Server.World->GetTimeSeconds();
				Timeline->OnLethalResult.Broadcast(&Victim, FGuid::NewGuid(), R->ServerDeathTime);
				Timeline->OnLethalResult.Broadcast(&Victim, FGuid::NewGuid(), R->ServerDeathTime);
				R->ServerCorpse = Cast<APawn>(Victim.GetAvatarActor());
				R->Test.TestTrue(TEXT("The server holds State.Dead on A"), Victim.HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
				R->Test.TestEqual(TEXT("The server raises one death cue for one death and a repeat"), R->ServerCues, 1);
				R->Test.TestFalse(TEXT("B stays alive"), ServerAbilitySystem(Server, ObserverClient)->HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
			})
			.UntilClient(TEXT("A's own client sees State.Dead and is corrected to MOVE_None"), VictimClient, [R](FState& Client)
			{
				const AAethelnPlayerState* PlayerState = ClientVictim(Client, R->VictimPlayerId);
				const ACharacter* Corpse = Cast<ACharacter>(R->ClientCorpse[VictimClient].Get());
				// ReplicatedMovementMode is simulated-only, so the owner reaches MOVE_None only through a move correction.
				return PlayerState != nullptr && PlayerState->GetAethelnAbilitySystemComponent()->HasMatchingGameplayTag(AethelnGameplayTags::State_Dead)
					&& Corpse != nullptr && Corpse->GetLocalRole() == ROLE_AutonomousProxy
					&& Corpse->GetCharacterMovement()->MovementMode == MOVE_None;
			}, Timeout)
			.UntilClient(TEXT("B's client sees State.Dead on A"), ObserverClient, [R](FState& Client)
			{
				const AAethelnPlayerState* PlayerState = ClientVictim(Client, R->VictimPlayerId);
				return PlayerState != nullptr && PlayerState->GetAethelnAbilitySystemComponent()->HasMatchingGameplayTag(AethelnGameplayTags::State_Dead);
			}, Timeout)
			.UntilServer(TEXT("The server respawns A, no earlier than the configured delay"), [R](FState& Server)
			{
				const UAethelnAbilitySystemComponent* Victim = ServerAbilitySystem(Server, VictimClient);
				const APawn* Avatar = Victim != nullptr ? Cast<APawn>(Victim->GetAvatarActor()) : nullptr;
				if (Avatar == nullptr || Avatar == R->ServerCorpse.Get() || Victim->HasMatchingGameplayTag(AethelnGameplayTags::State_Dead)) { return false; }
				// Lower bound only, from the ini value the server uses (R4 owns the exact deadline): never before death time plus the delay.
				const UAethelnDeathSubsystem* Death = Server.World->GetSubsystem<UAethelnDeathSubsystem>();
				if (R->Test.TestNotNull(TEXT("The server world has the death subsystem"), Death))
				{
					R->Test.TestTrue(TEXT("The respawn comes no earlier than the death time plus the configured delay"),
						Server.World->GetTimeSeconds() >= R->ServerDeathTime + Death->ProvisionalRespawnDelaySeconds);
				}
				return true;
			}, Timeout)
			.UntilClients(TEXT("Both clients receive A's new avatar without State.Dead"), [R](FState& Client)
			{
				return HasNewLivingAvatar(ClientVictim(Client, R->VictimPlayerId), R->ClientCorpse[Client.ClientIndex]);
			}, Timeout)
			.UntilClient(TEXT("A's own client receives the restored Health"), VictimClient, [R, Init](FState& Client)
			{
				const AAethelnPlayerState* PlayerState = ClientVictim(Client, R->VictimPlayerId);
				return PlayerState != nullptr && Attribute(*PlayerState->GetAethelnAbilitySystemComponent(), UAethelnCombatAttributeSet::GetHealthAttribute()) == Init.Health;
			}, Timeout)
			.ThenServer(TEXT("Death cue counts"), [R](FState& /*Server*/)
			{
				R->Test.TestEqual(TEXT("Still one server death cue after the respawn"), R->ServerCues, 1);
				for (int32 Index : { VictimClient, ObserverClient })
				{
					// The cue is unreliable by design: an impaired link may drop it, and nothing authoritative depends on it.
					if (R->bImpaired) { R->Test.TestTrue(TEXT("A client never receives a second death cue"), R->ClientCues[Index] <= 1); }
					else { R->Test.TestEqual(TEXT("On a clean loopback link each client receives the death cue once"), R->ClientCues[Index], 1); }
				}
			});

		EnqueueWithTeardown(Run, Timeout);
	}

	/** The reconnect key this client's local player holds; empty without one. */
	FString LocalKey(const FState& Client)
	{
		const UGameInstance* GameInstance = Client.World != nullptr ? Client.World->GetGameInstance() : nullptr;
		const UAethelnLocalPlayer* Local = GameInstance != nullptr ? Cast<UAethelnLocalPlayer>(GameInstance->GetFirstGamePlayer()) : nullptr;
		return Local != nullptr ? Local->GetReconnectKey() : FString();
	}

	/**
	 * #21 P4b key producer (R11): the server issues each player a reconnect key at login and sends it to that player's own
	 * connection only. Each client's local player holds its own key, which it presents in its next login options; no client
	 * holds the other's key, and no client's copy of a PlayerState carries one.
	 */
	void QueueReconnectKeyReachesOwner(FAutomationTestBase& Test)
	{
		ExpectUnsavedMapWarnings(Test);
		const TSharedRef<FRun> Run = MakeShared<FRun>(Test);
		FNetworkComponentBuilder<FState> NetworkBuilder;
		NetworkBuilder.WithClients(2).AsDedicatedServer().WithGameMode(AAethelnCombatGameMode::StaticClass());
		NetworkBuilder.Build(Run->Network);
		const FTimespan Timeout = FTimespan::FromSeconds(30.0);
		FRun* R = &Run.Get();

		Run->Network
			.UntilServer(TEXT("The server issued both players a key"), [R](FState& Server)
			{
				for (int32 Index : { VictimClient, ObserverClient })
				{
					const UAethelnAbilitySystemComponent* AbilitySystem = ServerAbilitySystem(Server, Index);
					const AAethelnPlayerState* PlayerState = AbilitySystem != nullptr ? Cast<AAethelnPlayerState>(AbilitySystem->GetOwner()) : nullptr;
					if (PlayerState == nullptr || PlayerState->GetReconnectKey().IsEmpty()) { return false; }
					R->ServerKeys[Index] = PlayerState->GetReconnectKey();
				}
				R->Test.TestNotEqual(TEXT("Each player has its own key"), R->ServerKeys[VictimClient], R->ServerKeys[ObserverClient]);
				return true;
			}, Timeout)
			.UntilClients(TEXT("Each client's local player holds its own key"), [R](FState& Client)
			{
				return LocalKey(Client) == R->ServerKeys[Client.ClientIndex];
			}, Timeout)
			.ThenClients(TEXT("No client holds another player's key"), [R](FState& Client)
			{
				const FString Own = LocalKey(Client);
				R->Test.TestNotEqual(TEXT("A client never holds the other player's key"), Own, R->ServerKeys[1 - Client.ClientIndex]);
				R->Test.TestEqual(TEXT("The key a client presents at its next login is its own"), AAethelnCombatGameMode::ResolveReconnectKey(
					FString(TEXT("?")) + CastChecked<UAethelnLocalPlayer>(Client.World->GetGameInstance()->GetFirstGamePlayer())->GetGameLoginOptions()), Own);
				const AGameStateBase* GameState = Client.World->GetGameState();
				for (const APlayerState* PlayerState : GameState != nullptr ? GameState->PlayerArray : TArray<TObjectPtr<APlayerState>>())
				{
					if (const AAethelnPlayerState* Copy = Cast<AAethelnPlayerState>(PlayerState))
					{
						R->Test.TestTrue(TEXT("No client's copy of a PlayerState carries a key"), Copy->GetReconnectKey().IsEmpty());
					}
				}
			});

		EnqueueWithTeardown(Run, Timeout);
	}

	/** Player A's pawn as the observer received it before A left; its PlayerState is then the kept one. */
	const AAethelnPlayerState* ObservedKeptState(const FRun& R)
	{
		const APawn* Pawn = R.ClientCorpse[ObserverClient].Get();
		return Pawn != nullptr ? Pawn->GetPlayerState<AAethelnPlayerState>() : nullptr;
	}

	/**
	 * #21 P4b, lead decision 2026-10-14 (R11): while player A is away, the remaining player B keeps seeing A's kept pawn and
	 * its Health, State.Dead and death cue, because the kept PlayerState still replicates. It is inactive, so it leaves B's
	 * player list, and it has no owner, so A's owner-only Endurance and Guard reach nobody. The server ends A's connection
	 * through the engine's own entry for a closed connection, APlayerController::OnNetCleanup.
	 */
	void QueueKeptPawnSeenByOthers(FAutomationTestBase& Test)
	{
		ExpectUnsavedMapWarnings(Test);
		const TSharedRef<FRun> Run = MakeShared<FRun>(Test);
		FNetworkComponentBuilder<FState> NetworkBuilder;
		NetworkBuilder.WithClients(2).AsDedicatedServer().WithGameMode(AAethelnCombatGameMode::StaticClass());
		NetworkBuilder.Build(Run->Network);
		const FTimespan Timeout = FTimespan::FromSeconds(30.0);
		const FAethelnCombatAttributeInitValues Init = AethelnCombatTests::MakeTestInitValues();
		FRun* R = &Run.Get();

		Run->Network
			.UntilServer(TEXT("Both players have a pawn, an ASC and a key"), [](FState& Server)
			{
				for (int32 Index : { VictimClient, ObserverClient })
				{
					const UAethelnAbilitySystemComponent* AbilitySystem = ServerAbilitySystem(Server, Index);
					if (AbilitySystem == nullptr || AbilitySystem->GetAvatarActor() == nullptr
						|| CastChecked<AAethelnPlayerState>(AbilitySystem->GetOwner())->GetReconnectKey().IsEmpty()) { return false; }
				}
				return true;
			}, Timeout)
			.ThenServer(TEXT("Give both players fixture attributes"), [R, Init](FState& Server)
			{
				for (int32 Index : { VictimClient, ObserverClient }) { UAethelnAttributeInitEffect::ApplyTo(*ServerAbilitySystem(Server, Index), Init); }
				R->VictimPlayerId = CastChecked<APlayerState>(ServerAbilitySystem(Server, VictimClient)->GetOwner())->GetPlayerId();
			})
			.UntilClient(TEXT("B received player A, its pawn and its Health"), ObserverClient, [R, Init](FState& Client)
			{
				AAethelnPlayerState* PlayerState = ClientVictim(Client, R->VictimPlayerId);
				if (PlayerState == nullptr || PlayerState->GetPawn() == nullptr
					|| Attribute(*PlayerState->GetAethelnAbilitySystemComponent(), UAethelnCombatAttributeSet::GetHealthAttribute()) != Init.Health) { return false; }
				R->ClientCorpse[ObserverClient] = PlayerState->GetPawn();
				return true;
			}, Timeout)
			.ThenServer(TEXT("A's connection ends; the server keeps A's pawn and PlayerState, then damages the kept pawn"), [R](FState& Server)
			{
				UNetConnection* Connection = Server.ClientConnections[VictimClient];
				APlayerController* Controller = Connection != nullptr ? Connection->PlayerController.Get() : nullptr;
				UAethelnAbilitySystemComponent* Victim = ServerAbilitySystem(Server, VictimClient);
				if (!R->Test.TestNotNull(TEXT("A's server controller exists"), Controller) || !R->Test.TestNotNull(TEXT("A's ASC exists"), Victim)) { return; }
				R->ServerKept = Victim;
				Controller->OnNetCleanup(Connection);
				const AAethelnPlayerState* Kept = Cast<AAethelnPlayerState>(Victim->GetOwner());
				if (!R->Test.TestTrue(TEXT("A's PlayerState is kept"), IsValid(Kept)) || !R->Test.TestNotNull(TEXT("A's pawn is kept"), Cast<APawn>(Victim->GetAvatarActor()))) { return; }
				R->Test.TestTrue(TEXT("The kept PlayerState still replicates"), Kept->GetIsReplicated());
				R->Test.TestTrue(TEXT("The kept PlayerState is inactive"), Kept->IsInactive());
				R->Test.TestNull(TEXT("The kept PlayerState has no owner"), Kept->GetOwner());
				AethelnCombatTests::ApplyInstantModifier(*Victim, UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::AddBase, -10.0f);
				AethelnCombatTests::ApplyInstantModifier(*Victim, UAethelnCombatAttributeSet::GetEnduranceAttribute(), EGameplayModOp::AddBase, -5.0f);
			})
			.UntilClient(TEXT("B sees the kept pawn's Health drop, and the kept player leaves B's player list"), ObserverClient, [R, Init](FState& Client)
			{
				const AAethelnPlayerState* Kept = ObservedKeptState(*R);
				const AGameStateBase* GameState = Client.World->GetGameState();
				if (Kept == nullptr || GameState == nullptr || !Kept->IsInactive() || GameState->PlayerArray.ContainsByPredicate([Kept](const APlayerState* Listed) { return Listed == Kept; })
					|| Attribute(*Kept->GetAethelnAbilitySystemComponent(), UAethelnCombatAttributeSet::GetHealthAttribute()) != Init.Health - 10.0f) { return false; }
				// Endurance changed in the same server frame and set as Health; it is owner-only and the owner is gone.
				R->Test.TestEqual(TEXT("B never receives the kept player's Endurance"),
					Attribute(*Kept->GetAethelnAbilitySystemComponent(), UAethelnCombatAttributeSet::GetEnduranceAttribute()), GetDefault<UAethelnCombatAttributeSet>()->GetEndurance());
				const int32 Index = ObserverClient;
				Kept->GetAethelnAbilitySystemComponent()->OnDeathCue.AddLambda([R, Index] { ++R->ClientCues[Index]; });
				return true;
			}, Timeout)
			.ThenServer(TEXT("Kill the kept player"), [R](FState& Server)
			{
				UAethelnAbilitySystemComponent* Kept = R->ServerKept.Get();
				UAethelnCombatTimelineSubsystem* Timeline = Server.World->GetSubsystem<UAethelnCombatTimelineSubsystem>();
				if (!R->Test.TestNotNull(TEXT("The kept ASC exists"), Kept) || !R->Test.TestNotNull(TEXT("The server world has the combat timeline"), Timeline)) { return; }
				AethelnCombatTests::ApplyInstantModifier(*Kept, UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::Override, 0.0f);
				Timeline->OnLethalResult.Broadcast(Kept, FGuid::NewGuid(), Server.World->GetTimeSeconds());
				R->Test.TestTrue(TEXT("The server holds State.Dead on the kept player"), Kept->HasMatchingGameplayTag(AethelnGameplayTags::State_Dead));
			})
			.UntilClient(TEXT("B sees the kept player's death: State.Dead, zero Health and the death cue"), ObserverClient, [R](FState& Client)
			{
				const AAethelnPlayerState* Kept = ObservedKeptState(*R);
				return Kept != nullptr && Kept->GetAethelnAbilitySystemComponent()->HasMatchingGameplayTag(AethelnGameplayTags::State_Dead)
					&& Attribute(*Kept->GetAethelnAbilitySystemComponent(), UAethelnCombatAttributeSet::GetHealthAttribute()) == 0.0f
					&& R->ClientCues[ObserverClient] >= 1;
			}, Timeout)
			.ThenServer(TEXT("One death cue"), [R](FState& /*Server*/)
			{
				R->Test.TestEqual(TEXT("On a clean loopback link B receives the kept player's death cue once"), R->ClientCues[ObserverClient], 1);
			});

		EnqueueWithTeardown(Run, Timeout);
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnTwoClientDeathAndRespawnTest,
	"Aetheln.GameCombat.Death.TwoClientDeathAndRespawn",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnTwoClientDeathAndRespawnTest::RunTest(const FString& Parameters)
{
	// This test creates its own map over the Editor's startup world, the default map, which now holds a built navigation mesh;
	// replacing it makes the crowd manager log an engine warning for the mesh that is already gone (#83 P4). The warning lands
	// on whichever test first replaces the Editor's startup world, which is this one only in the full `^Aetheln.` run order
	// (Aetheln.GameCombat.Death sorts first among the tests that create a map). Count -1 ignores it so this test does not fail
	// if that order changes; a new test that sorts earlier and replaces the startup world would inherit the warning and needs
	// the same expectation.
	AddExpectedMessagePlain(TEXT("Unable to find RecastNavMesh instance while trying to create UCrowdManager instance"), ELogVerbosity::Warning, EAutomationExpectedMessageFlags::Contains, -1);
	AethelnTwoClientDeathTests::QueueTwoClientDeathAndRespawn(*this, nullptr);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnTwoClientDeathAndRespawnImpairedTest,
	"Aetheln.GameCombat.Death.TwoClientDeathAndRespawnImpaired",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnTwoClientDeathAndRespawnImpairedTest::RunTest(const FString& Parameters)
{
	// Fixture impairment on every driver, both directions: 100 ms lag each way and 5 % loss. These are test settings,
	// not the #45 network profile.
	FPacketSimulationSettings Impairment;
	Impairment.PktLag = 100;
	Impairment.PktLoss = 5;
	AethelnTwoClientDeathTests::QueueTwoClientDeathAndRespawn(*this, &Impairment);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnTwoClientReconnectKeyReachesOwnerTest,
	"Aetheln.GameCombat.Death.TwoClientReconnectKeyReachesOwner",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnTwoClientReconnectKeyReachesOwnerTest::RunTest(const FString& Parameters)
{
	AethelnTwoClientDeathTests::QueueReconnectKeyReachesOwner(*this);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnTwoClientKeptPawnSeenByOthersTest,
	"Aetheln.GameCombat.Death.TwoClientKeptPawnSeenByOthers",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnTwoClientKeptPawnSeenByOthersTest::RunTest(const FString& Parameters)
{
	AethelnTwoClientDeathTests::QueueKeptPawnSeenByOthers(*this);
	return true;
}

#endif
