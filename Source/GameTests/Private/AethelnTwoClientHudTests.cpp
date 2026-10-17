#if WITH_DEV_AUTOMATION_TESTS && WITH_EDITOR

#include "AethelnAbilitySystemComponent.h"
#include "AethelnActivationTypes.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatGameMode.h"
#include "AethelnCombatTestWorld.h"
#include "AethelnCombatTimelineSubsystem.h"
#include "AethelnGameplayTags.h"
#include "AethelnHudPresenter.h"
#include "AethelnPlayerState.h"
#include "Components/PIENetworkComponent.h"
#include "Engine/NetConnection.h"
#include "GameFramework/GameStateBase.h"
#include "GameFramework/PlayerController.h"
#include "Misc/AutomationTest.h"

// #61 two-client readability (docs/gas-foundation.md, HUD State Source). A PIE session with one dedicated server and two
// clients in this process, on real net drivers over loopback (CQTest's FPIENetworkComponent), the same harness as
// AethelnTwoClientDeathTests.cpp. It drives the HUD's own FAethelnHudPresenter, the code UAethelnHudWidget ticks, on each
// client's replicated PlayerStates and reads the formatted lines. It simulates no input device and instantiates no widget.
// Client 0 is player A, client 1 is player B. Attribute values are fixture values (MakeTestInitValues), not tuning.
// The HUD is presentation only: the test never sets a client value, and it checks that the server's state is the one the
// clients converge to, that a rejected request grants nothing, and that the rejection cue reaches the owner only.
namespace AethelnTwoClientHudTests
{
	using FState = FBasePIENetworkComponentState;
	constexpr int32 ClientA = 0;
	constexpr int32 ClientB = 1;

	/** What one client's HUD shows: its own PlayerState (as the widget does) and the other player's copy on this client. */
	struct FClientHud
	{
		FAethelnHudPresenter OwnHud;
		FAethelnHudPresenter OpponentHud;
		int32 OwnOutcomes = 0;
		int32 OpponentOutcomes = 0;
		bool bBound = false;
	};

	/** Owns the builder and the component for the whole latent run; the queued lambdas point into it. */
	struct FRun
	{
		explicit FRun(FAutomationTestBase& InTest) : Test(InTest), Builder(InTest), Network(&InTest, Builder, false) {}

		FAutomationTestBase& Test;
		FTestCommandBuilder Builder;
		FPIENetworkComponent<FState> Network;
		FPacketSimulationSettings Packets;
		int32 PlayerId[2] = { INDEX_NONE, INDEX_NONE };
		FClientHud Hud[2];
		TWeakObjectPtr<APawn> ServerCorpse;
		TWeakObjectPtr<APawn> ClientCorpse[2];
	};

	AAethelnPlayerState* ServerPlayerState(const FState& Server, int32 ClientIndex)
	{
		const UNetConnection* Connection = Server.ClientConnections.IsValidIndex(ClientIndex) ? Server.ClientConnections[ClientIndex] : nullptr;
		const APlayerController* Controller = Connection != nullptr ? Connection->PlayerController.Get() : nullptr;
		return Controller != nullptr ? Controller->GetPlayerState<AAethelnPlayerState>() : nullptr;
	}

	/** One player's PlayerState as one client world received it, matched by the server's player id. */
	AAethelnPlayerState* ClientPlayerState(const FState& Client, int32 PlayerId)
	{
		const AGameStateBase* GameState = Client.World != nullptr ? Client.World->GetGameState() : nullptr;
		if (GameState == nullptr) { return nullptr; }
		for (APlayerState* PlayerState : GameState->PlayerArray)
		{
			if (PlayerState != nullptr && PlayerState->GetPlayerId() == PlayerId) { return Cast<AAethelnPlayerState>(PlayerState); }
		}
		return nullptr;
	}

	AAethelnPlayerState* OwnState(const FRun& R, const FState& Client) { return ClientPlayerState(Client, R.PlayerId[Client.ClientIndex]); }
	AAethelnPlayerState* OpponentState(const FRun& R, const FState& Client) { return ClientPlayerState(Client, R.PlayerId[1 - Client.ClientIndex]); }
	AAethelnPlayerState* PlayerAOnClient(const FRun& R, const FState& Client) { return ClientPlayerState(Client, R.PlayerId[ClientA]); }

	/** Binds a client's two presenters and counts the HUD outcome events once both PlayerStates have arrived. */
	bool BindHud(FRun& R, const FState& Client)
	{
		AAethelnPlayerState* Own = OwnState(R, Client);
		AAethelnPlayerState* Opponent = OpponentState(R, Client);
		if (Own == nullptr || Opponent == nullptr) { return false; }
		FClientHud& Hud = R.Hud[Client.ClientIndex];
		if (!Hud.bBound)
		{
			Hud.bBound = true;
			Own->OnHudActionOutcome().AddLambda([&Hud](const FAethelnHudActionOutcome&) { ++Hud.OwnOutcomes; });
			Opponent->OnHudActionOutcome().AddLambda([&Hud](const FAethelnHudActionOutcome&) { ++Hud.OpponentOutcomes; });
			Hud.OwnHud.Refresh(Own, nullptr);
			Hud.OpponentHud.Refresh(Opponent, nullptr);
		}
		return true;
	}

	const FAethelnHudView& OwnView(FRun& R, const FState& Client) { return R.Hud[Client.ClientIndex].OwnHud.Refresh(OwnState(R, Client), nullptr); }
	const FAethelnHudView& OpponentView(FRun& R, const FState& Client) { return R.Hud[Client.ClientIndex].OpponentHud.Refresh(OpponentState(R, Client), nullptr); }

	FString Line(const TCHAR* Label, float Current, float Max)
	{
		return FString::Printf(TEXT("%s %d / %d"), Label, FMath::CeilToInt(Current), FMath::RoundToInt(Max));
	}

	/** A new avatar: a live pawn that is not the corpse, which the client's ASC copy uses and which is not dead. */
	bool HasNewLivingAvatar(const AAethelnPlayerState* PlayerState, const TWeakObjectPtr<APawn>& Corpse)
	{
		const UAethelnAbilitySystemComponent* AbilitySystem = PlayerState != nullptr ? PlayerState->GetAethelnAbilitySystemComponent() : nullptr;
		APawn* Pawn = PlayerState != nullptr ? PlayerState->GetPawn() : nullptr;
		return AbilitySystem != nullptr && Pawn != nullptr && Pawn != Corpse.Get() && !Pawn->IsActorBeingDestroyed()
			&& AbilitySystem->GetAvatarActor() == Pawn && !AbilitySystem->HasMatchingGameplayTag(AethelnGameplayTags::State_Dead);
	}

	void QueueTwoClientReadability(FAutomationTestBase& Test, const FPacketSimulationSettings* Impairment)
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
			NetworkBuilder.WithPacketSimulationSettings(&Run->Packets);
		}
		NetworkBuilder.Build(Run->Network);
		// Generous bounds: the run waits on replication under impairment, never on a fixed tick.
		const FTimespan Timeout = FTimespan::FromSeconds(30.0);
		const FAethelnCombatAttributeInitValues Init = AethelnCombatTests::MakeTestInitValues();
		FRun* R = &Run.Get();
		const FString FullHealth = Line(TEXT("Health"), Init.Health, Init.MaxHealth);
		const FString FullEndurance = Line(TEXT("Endurance"), Init.Endurance, Init.MaxEndurance);
		const FString FullGuard = Line(TEXT("Guard"), Init.Guard, Init.MaxGuard);
		const FString DeadHealth = Line(TEXT("Health"), 0.0f, Init.MaxHealth);
		const FString NoOutcome = TEXT("Last action: none");

		Run->Network
			.UntilServer(TEXT("Both players have a pawn and an ASC"), [](FState& Server)
			{
				for (int32 Index : { ClientA, ClientB })
				{
					const AAethelnPlayerState* PlayerState = ServerPlayerState(Server, Index);
					const UAethelnAbilitySystemComponent* AbilitySystem = PlayerState != nullptr ? PlayerState->GetAethelnAbilitySystemComponent() : nullptr;
					if (AbilitySystem == nullptr || AbilitySystem->GetAvatarActor() == nullptr) { return false; }
				}
				return true;
			}, Timeout)
			.ThenServer(TEXT("Give both players fixture attributes"), [R, Init](FState& Server)
			{
				// The ini sets the owner's provisional attributes (#19), equal to the fixture values; applying them keeps this test independent of a later re-tune.
				for (int32 Index : { ClientA, ClientB })
				{
					AAethelnPlayerState& PlayerState = *ServerPlayerState(Server, Index);
					UAethelnAttributeInitEffect::ApplyTo(*PlayerState.GetAethelnAbilitySystemComponent(), Init);
					R->PlayerId[Index] = PlayerState.GetPlayerId();
				}
			})
			.UntilClients(TEXT("Each HUD shows its own three resources and the opponent's Health"), [R, FullHealth, FullEndurance, FullGuard](FState& Client)
			{
				if (!BindHud(*R, Client)) { return false; }
				const FAethelnHudView& Own = OwnView(*R, Client);
				const FAethelnHudView& Opponent = OpponentView(*R, Client);
				APawn* PlayerAPawn = PlayerAOnClient(*R, Client)->GetPawn();
				if (PlayerAPawn == nullptr) { return false; }
				R->ClientCorpse[Client.ClientIndex] = PlayerAPawn;
				return Own.Health.ToString() == FullHealth && Own.Endurance.ToString() == FullEndurance && Own.Guard.ToString() == FullGuard
					&& Opponent.Health.ToString() == FullHealth;
			}, Timeout)
			.ThenClients(TEXT("The opponent's Endurance and Guard never reach the HUD"), [R](FState& Client)
			{
				// Health, Endurance and Guard changed in the same server frame and set, so had Endurance and Guard replicated to a
				// non-owner they would be here now. The copy keeps the class defaults, whose maxima are 0: unknown, not 0 / 0.
				const UAethelnCombatAttributeSet* Defaults = GetDefault<UAethelnCombatAttributeSet>();
				R->Test.TestEqual(TEXT("The class default MaxEndurance is 0, so a never-replicated Endurance reads unknown"), Defaults->GetMaxEndurance(), 0.0f);
				R->Test.TestEqual(TEXT("The class default MaxGuard is 0, so a never-replicated Guard reads unknown"), Defaults->GetMaxGuard(), 0.0f);
				const FAethelnHudView& Opponent = OpponentView(*R, Client);
				R->Test.TestEqual(TEXT("The opponent's Endurance reads unknown"), Opponent.Endurance.ToString(), FString(TEXT("Endurance --")));
				R->Test.TestEqual(TEXT("The opponent's Guard reads unknown"), Opponent.Guard.ToString(), FString(TEXT("Guard --")));
				const FAethelnHudSnapshot Snapshot = OpponentState(*R, Client)->GetHudSnapshot();
				R->Test.TestTrue(TEXT("The opponent's Health is known"), Snapshot.Health.bKnown);
				R->Test.TestFalse(TEXT("The opponent's Endurance is not known"), Snapshot.Endurance.bKnown);
				R->Test.TestFalse(TEXT("The opponent's Guard is not known"), Snapshot.Guard.bKnown);
				R->Test.TestEqual(TEXT("The client's own PlayerState is the one the server matched to this connection"),
					OwnState(*R, Client)->GetPlayerId(), R->PlayerId[Client.ClientIndex]);
			})
			.ThenClient(TEXT("A requests an ability it was never granted"), ClientA, [R](FState& Client)
			{
				OwnState(*R, Client)->GetAethelnAbilitySystemComponent()->RequestActivation(AethelnCombatTestTags::Ability_Test_Probe, EAethelnActivationPhase::Press);
			})
			.UntilClient(TEXT("A's HUD receives the rejection"), ClientA, [R](FState& /*Client*/)
			{
				return R->Hud[ClientA].OwnOutcomes >= 1;
			}, Timeout)
			.ThenClients(TEXT("Only A's own HUD shows the rejection, once"), [R, NoOutcome](FState& Client)
			{
				FClientHud& Hud = R->Hud[Client.ClientIndex];
				const FString Own = OwnView(*R, Client).Outcome.ToString();
				const FString Opponent = OpponentView(*R, Client).Outcome.ToString();
				if (Client.ClientIndex == ClientA)
				{
					R->Test.TestEqual(TEXT("A's own PlayerState raises one HUD outcome event for one request"), Hud.OwnOutcomes, 1);
					R->Test.TestTrue(TEXT("A's own HUD reads a rejection with its owner-facing reason"), Own.StartsWith(TEXT("Last action: REJECTED (")) && Own.EndsWith(TEXT(") #1")));
					R->Test.TestEqual(TEXT("A's presenter counts one outcome"), static_cast<int32>(R->Hud[ClientA].OwnHud.Refresh(OwnState(*R, Client), nullptr).OutcomeCount), 1);
					R->Test.TestEqual(TEXT("A's copy of B shows no outcome"), Opponent, NoOutcome);
				}
				else
				{
					R->Test.TestEqual(TEXT("B's own HUD shows no outcome"), Own, NoOutcome);
					R->Test.TestEqual(TEXT("B's copy of A shows no outcome: the outcome is owner-only"), Opponent, NoOutcome);
				}
			})
			.ThenServer(TEXT("The rejected request granted nothing, and the HUD refreshes changed nothing"), [R, Init](FState& Server)
			{
				const FAethelnHudSnapshot Snapshot = ServerPlayerState(Server, ClientA)->GetHudSnapshot();
				R->Test.TestEqual(TEXT("The server's Health is untouched"), Snapshot.Health.Current, Init.Health);
				R->Test.TestEqual(TEXT("The server's Endurance is untouched"), Snapshot.Endurance.Current, Init.Endurance);
				R->Test.TestEqual(TEXT("The server's Guard is untouched"), Snapshot.Guard.Current, Init.Guard);
				R->Test.TestEqual(TEXT("The rejection started no cooldown or other timed state"), Snapshot.TimedStates.Num(), 0);
			})
			.ThenServer(TEXT("Kill player A through the timeline's lethal notification"), [R](FState& Server)
			{
				UAethelnAbilitySystemComponent& Victim = *ServerPlayerState(Server, ClientA)->GetAethelnAbilitySystemComponent();
				AethelnCombatTests::ApplyInstantModifier(Victim, UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::Override, 0.0f);
				UAethelnCombatTimelineSubsystem* Timeline = Server.World->GetSubsystem<UAethelnCombatTimelineSubsystem>();
				if (!R->Test.TestNotNull(TEXT("The server world has the combat timeline"), Timeline)) { return; }
				R->ServerCorpse = Cast<APawn>(Victim.GetAvatarActor());
				Timeline->OnLethalResult.Broadcast(&Victim, FGuid::NewGuid(), Server.World->GetTimeSeconds());
			})
			.UntilClients(TEXT("Both HUDs read A's death: Health 0 and State.Dead"), [R, DeadHealth](FState& Client)
			{
				const AAethelnPlayerState* PlayerA = PlayerAOnClient(*R, Client);
				const FAethelnHudView& OfA = Client.ClientIndex == ClientA ? OwnView(*R, Client) : OpponentView(*R, Client);
				return PlayerA != nullptr && PlayerA->GetAethelnAbilitySystemComponent()->HasMatchingGameplayTag(AethelnGameplayTags::State_Dead)
					&& OfA.Health.ToString() == DeadHealth;
			}, Timeout)
			.ThenClients(TEXT("Death changes A's Health line only"), [R, FullEndurance, FullGuard](FState& Client)
			{
				if (Client.ClientIndex == ClientA)
				{
					R->Test.TestEqual(TEXT("A's own HUD keeps Endurance through death"), OwnView(*R, Client).Endurance.ToString(), FullEndurance);
					R->Test.TestEqual(TEXT("A's own HUD keeps Guard through death"), OwnView(*R, Client).Guard.ToString(), FullGuard);
				}
				else
				{
					R->Test.TestEqual(TEXT("B still does not see A's Endurance"), OpponentView(*R, Client).Endurance.ToString(), FString(TEXT("Endurance --")));
					R->Test.TestEqual(TEXT("B still does not see A's Guard"), OpponentView(*R, Client).Guard.ToString(), FString(TEXT("Guard --")));
				}
			})
			.UntilServer(TEXT("The server respawns A"), [R](FState& Server)
			{
				const UAethelnAbilitySystemComponent* Victim = ServerPlayerState(Server, ClientA)->GetAethelnAbilitySystemComponent();
				const APawn* Avatar = Cast<APawn>(Victim->GetAvatarActor());
				return Avatar != nullptr && Avatar != R->ServerCorpse.Get() && !Victim->HasMatchingGameplayTag(AethelnGameplayTags::State_Dead);
			}, Timeout)
			.UntilClients(TEXT("Both clients see A's new living avatar"), [R](FState& Client)
			{
				return HasNewLivingAvatar(PlayerAOnClient(*R, Client), R->ClientCorpse[Client.ClientIndex]);
			}, Timeout)
			.UntilClients(TEXT("Both HUDs converge back to A's restored Health"), [R, FullHealth](FState& Client)
			{
				const FAethelnHudView& OfA = Client.ClientIndex == ClientA ? OwnView(*R, Client) : OpponentView(*R, Client);
				return OfA.Health.ToString() == FullHealth;
			}, Timeout)
			.ThenClient(TEXT("A requests another ungranted ability after the respawn"), ClientA, [R](FState& Client)
			{
				OwnState(*R, Client)->GetAethelnAbilitySystemComponent()->RequestActivation(AethelnCombatTestTags::Ability_Test_Probe, EAethelnActivationPhase::Press);
			})
			.UntilClient(TEXT("A's HUD receives the second rejection"), ClientA, [R](FState& /*Client*/)
			{
				return R->Hud[ClientA].OwnOutcomes >= 2;
			}, Timeout)
			.ThenClients(TEXT("Death and respawn left one binding, and the cue stayed owner-only"), [R, NoOutcome](FState& Client)
			{
				FClientHud& Hud = R->Hud[Client.ClientIndex];
				if (Client.ClientIndex == ClientA)
				{
					R->Test.TestEqual(TEXT("One HUD outcome event per request across death and respawn"), Hud.OwnOutcomes, 2);
					R->Test.TestTrue(TEXT("A's HUD reads the second rejection"), OwnView(*R, Client).Outcome.ToString().EndsWith(TEXT(") #2")));
				}
				else
				{
					R->Test.TestEqual(TEXT("B's own HUD still shows no outcome"), OwnView(*R, Client).Outcome.ToString(), NoOutcome);
					R->Test.TestEqual(TEXT("B's copy of A still shows no outcome"), OpponentView(*R, Client).Outcome.ToString(), NoOutcome);
					R->Test.TestEqual(TEXT("B's own PlayerState raised no HUD outcome event"), Hud.OwnOutcomes, 0);
				}
				R->Test.TestEqual(TEXT("A copy of the other player raises no HUD outcome event"), Hud.OpponentOutcomes, 0);
			});

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
			if (!bPieEnded) { Run->Test.AddError(FString::Printf(TEXT("%s: PIE did not end within %.0f s after the HUD two-client teardown"), *Run->Test.GetTestFullName(), Timeout.GetTotalSeconds())); }
			return true;
		}));
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnHudTwoClientReadabilityTest,
	"Aetheln.GameUI.Hud.TwoClientReadability",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnHudTwoClientReadabilityTest::RunTest(const FString& Parameters)
{
	AethelnTwoClientHudTests::QueueTwoClientReadability(*this, nullptr);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnHudTwoClientReadabilityImpairedTest,
	"Aetheln.GameUI.Hud.TwoClientReadabilityImpaired",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnHudTwoClientReadabilityImpairedTest::RunTest(const FString& Parameters)
{
	// Fixture impairment on every driver, both directions: 100 ms lag each way and 5 % loss. These are test settings,
	// not the #45 network profile.
	FPacketSimulationSettings Impairment;
	Impairment.PktLag = 100;
	Impairment.PktLoss = 5;
	AethelnTwoClientHudTests::QueueTwoClientReadability(*this, &Impairment);
	return true;
}

#endif
