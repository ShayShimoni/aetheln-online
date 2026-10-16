#if WITH_DEV_AUTOMATION_TESTS && WITH_EDITOR

#include "AethelnAbilitySystemComponent.h"
#include "AethelnChainTestFixture.h"
#include "AethelnCombatAICharacter.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatEffects.h"
#include "AethelnCombatGameMode.h"
#include "AethelnCombatTestWorld.h"
#include "AethelnCombatTimelineSubsystem.h"
#include "AethelnGameplayTags.h"
#include "AethelnPOCInputComponent.h"
#include "AethelnPlayerState.h"
#include "Components/PIENetworkComponent.h"
#include "Engine/NetConnection.h"
#include "EngineUtils.h"
#include "GameFramework/Character.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "GameFramework/GameStateBase.h"
#include "GameFramework/PlayerController.h"
#include "Misc/AutomationTest.h"

// #60 P6, Test Plan A19 to A21 (docs/attack-timeline-and-combo.md). A PIE session with one dedicated server and
// two or three clients in this process, on real net drivers over loopback (CQTest's FPIENetworkComponent), as the
// #21 P3 tests are. The attacker presses through the same GameUI entry the left mouse button uses
// (SubmitPrimaryAttack -> IAethelnCombatInputSink -> the ASC's activation request), so the request, the
// control-rotation aim, the time sample and the owner RPCs are the engine's own. It simulates no input device and no
// separate process. Window offsets, damage and cost are the provisional values in Config/DefaultGame.ini (#84 D3); the
// aim and time bounds, the rate bucket and the attribute values are fixture values (AethelnCombatTests), never tuning.
// The impairment is a fixture setting, not the #45 profile.
namespace AethelnTwoClientAttackTests
{
	using FState = FBasePIENetworkComponentState;
	using EResult = EAethelnActivationResult;
	constexpr int32 AttackerClient = 0;
	constexpr int32 ObserverClient = 1;
	constexpr int32 MaxClients = 4;
	/** Past BufferOpen, so a press the client sends at BufferOpen + margin reaches the server inside the buffer. */
	constexpr double PressMarginSeconds = 0.05;

	struct FOutcome
	{
		uint32 Sequence = 0;
		EResult Result = EResult::Accepted;
	};

	struct FEndRecord
	{
		FGuid ActivationId;
		EAethelnChainEndReason Reason = EAethelnChainEndReason::None;
	};

	/** Owns the builder and the component for the whole latent run; the queued lambdas point into it. */
	struct FRun
	{
		explicit FRun(FAutomationTestBase& InTest) : Test(InTest), Builder(InTest), Network(&InTest, Builder, false) {}

		FAutomationTestBase& Test;
		FTestCommandBuilder Builder;
		FPIENetworkComponent<FState> Network;
		FPacketSimulationSettings Packets;
		bool bImpaired = false;
		FState* Server = nullptr;
		FState* Clients[MaxClients] = {};
		int32 PlayerId[MaxClients] = { INDEX_NONE, INDEX_NONE, INDEX_NONE, INDEX_NONE };
		TWeakObjectPtr<AAethelnCombatAICharacter> Dummy[MaxClients];
		float DummyStartHealth = 0.0f;

		// Server side.
		TArray<FAethelnCombatResult> Results;
		int32 CostApplications = 0;

		// The attacker's own client (client 0): what the owner RPCs delivered.
		TArray<FOutcome> Outcomes;
		TArray<FAethelnCombatActivationRecord> Records;
		TArray<FEndRecord> Ends;
		bool bOwnerCopyChanged = false;

		// The observer's client (client 1): its copy of the attacker's ASC.
		int32 ObserverOutcomes = 0;
		int32 ObserverRecords = 0;
		int32 ObserverEnds = 0;
		TSet<uint8> ObserverSteps;
		FAethelnAttackPresentationState ObserverLast;

		// Result cues on the dummy's ASC, per client.
		int32 Cues[MaxClients] = {};
		bool bClientBound[MaxClients] = {};

		// A21: one lost player per disconnect phase.
		double WindowScale = 1.0;
		bool bClosed[MaxClients] = {};
		TWeakObjectPtr<UAethelnAbilitySystemComponent> LostAbilitySystem[MaxClients];
		float HealthAtClose[MaxClients] = {};
		double ElapsedAtClose[MaxClients] = {};
		bool bWaitingAtClose = false;
		bool bSecondPressed = false;
		int32 ResultsAtAllClosed = 0;
		bool bLostChainGone[MaxClients] = {};
		int32 StepsAfterLoss = INDEX_NONE;
		int32 OwnersAfterLoss = INDEX_NONE;

		// Driver state.
		int32 Stage = 0;
		int32 Sent = 0;
		double StageTime = 0.0;
		double ThresholdServerTime = 0.0;
	};

	UAethelnAbilitySystemComponent* ServerAbilitySystem(const FState& Server, int32 ClientIndex)
	{
		const UNetConnection* Connection = Server.ClientConnections.IsValidIndex(ClientIndex) ? Server.ClientConnections[ClientIndex] : nullptr;
		const APlayerController* Controller = Connection != nullptr ? Connection->PlayerController.Get() : nullptr;
		const AAethelnPlayerState* PlayerState = Controller != nullptr ? Controller->GetPlayerState<AAethelnPlayerState>() : nullptr;
		return PlayerState != nullptr ? PlayerState->GetAethelnAbilitySystemComponent() : nullptr;
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

	double ClientServerTime(const FState& Client)
	{
		const AGameStateBase* GameState = Client.World != nullptr ? Client.World->GetGameState() : nullptr;
		return GameState != nullptr ? GameState->GetServerWorldTimeSeconds() : 0.0;
	}

	float HealthOf(const AAethelnCombatAICharacter& Character)
	{
		return Character.GetAethelnAbilitySystemComponent()->GetNumericAttribute(UAethelnCombatAttributeSet::GetHealthAttribute());
	}

	bool HasChainSpec(const UAethelnAbilitySystemComponent& AbilitySystem)
	{
		for (const FGameplayAbilitySpec& Spec : AbilitySystem.GetActivatableAbilities())
		{
			if (Spec.Ability != nullptr && Spec.Ability->IsA<UAethelnChainTestAbility>()) { return true; }
		}
		return false;
	}

	/** The chain's per-step Wrought damage as authored in the ini (read, never set). */
	float WroughtDamageOfStep(uint8 Step)
	{
		const TArray<FAethelnAttackStepDefinition>& Steps = GetDefault<UAethelnChainTestAbility>()->ProvisionalSteps;
		return Steps.IsValidIndex(Step - 1) ? Steps[Step - 1].WroughtDamage : 0.0f;
	}

	void AddCqTestPieExpectedMessages(FAutomationTestBase& Test)
	{
		// CQTest plays a new unsaved map, whose level and world settings have no stable package path for the net GUID cache.
		Test.AddExpectedMessage(TEXT("FNetGUIDCache::SupportsObject: Level /Temp/UEDPIE_\\d+_Untitled_\\d+\\.Untitled:PersistentLevel NOT Supported"), ELogVerbosity::Warning,
			EAutomationExpectedMessageFlags::Contains, 0);
		Test.AddExpectedMessage(TEXT("RegisterNetGUID_Client: Guid with pathname\\. FullNetGUIDPath: \\[\\d+\\]WorldSettings"), ELogVerbosity::Warning,
			EAutomationExpectedMessageFlags::Contains, 0);
	}

	void BuildNetwork(FRun& R, int32 ClientCount, const FPacketSimulationSettings* Impairment)
	{
		AddCqTestPieExpectedMessages(R.Test);
		FNetworkComponentBuilder<FState> NetworkBuilder;
		NetworkBuilder.WithClients(ClientCount).AsDedicatedServer().WithGameMode(AAethelnCombatGameMode::StaticClass());
		if (Impairment != nullptr)
		{
			R.Packets = *Impairment;
			R.bImpaired = true;
			NetworkBuilder.WithPacketSimulationSettings(&R.Packets);
		}
		NetworkBuilder.Build(R.Network);
	}

	/** Releases the run only after the editor ended the PIE session; bounded like CQTest's own steps. */
	void QueueTeardown(const TSharedRef<FRun>& Run)
	{
		FAutomationTestFramework& Framework = FAutomationTestFramework::Get();
		Framework.EnqueueLatentCommand(Run->Builder.Build());
		Framework.EnqueueLatentCommand(Run->Builder.BuildTearDown());
		Framework.EnqueueLatentCommand(MakeShared<FFunctionLatentCommand>([Run, Start = TOptional<FDateTime>()]() mutable
		{
			if (!Start.IsSet()) { Start = FDateTime::UtcNow(); }
			bool bPieEnded = true;
			for (const FWorldContext& Context : GEngine->GetWorldContexts())
			{
				bPieEnded &= !(Context.WorldType == EWorldType::PIE && Context.World() != nullptr);
			}
			if (!bPieEnded && FDateTime::UtcNow() - Start.GetValue() < FTimespan::FromSeconds(30.0)) { return false; }
			if (!bPieEnded) { Run->Test.AddError(FString::Printf(TEXT("%s: PIE did not end within 30 s after the teardown"), *Run->Test.GetTestFullName())); }
			return true;
		}));
	}

	/**
	 * Fixture state for one player on the server: attribute values, a still pawn, and for an attacker the chain, the
	 * aim and time bounds and a rate bucket that never limits. A dummy stands 60 units ahead of the pawn along the
	 * server controller's control rotation, where the provisional chain's sweep reaches it (as in the P4 contact tests).
	 */
	void SetUpPlayer(FRun& R, FState& Server, int32 Index, bool bAttacker, const FVector& Where)
	{
		UAethelnAbilitySystemComponent* AbilitySystem = ServerAbilitySystem(Server, Index);
		if (!R.Test.TestNotNull(TEXT("The player has an ASC"), AbilitySystem)) { return; }
		R.PlayerId[Index] = CastChecked<APlayerState>(AbilitySystem->GetOwner())->GetPlayerId();
		UAethelnAttributeInitEffect::ApplyTo(*AbilitySystem, AethelnCombatTests::MakeTestInitValues());
		ACharacter* Pawn = Cast<ACharacter>(AbilitySystem->GetAvatarActor());
		if (!R.Test.TestNotNull(TEXT("The player has a character"), Pawn)) { return; }
		Pawn->GetCharacterMovement()->DisableMovement();
		Pawn->SetActorLocationAndRotation(Where, FRotator::ZeroRotator, false, nullptr, ETeleportType::TeleportPhysics);
		if (AController* Controller = Pawn->GetController()) { Controller->SetControlRotation(FRotator::ZeroRotator); }
		if (!bAttacker) { return; }
		AethelnCombatTests::SetTestAimTimeBounds(*AbilitySystem);
		// The fixture's own values: aim turns are scripted, so the rate bound is not under test; the bucket never limits.
		AbilitySystem->ProvisionalAimMaxRateDegreesPerSecond = 1000.0f;
		AbilitySystem->ProvisionalActivationBucketCapacity = 1000.0f;
		AbilitySystem->ProvisionalActivationBucketRefillPerSecond = 0.0f;
		AbilitySystem->GiveAbility(FGameplayAbilitySpec(UAethelnChainTestAbility::StaticClass(), 1));
		if (R.WindowScale != 1.0)
		{
			// Fixture only (A21): longer windows so a poll per frame lands in each phase. The offsets stay in order.
			for (const FGameplayAbilitySpec& Spec : AbilitySystem->GetActivatableAbilities())
			{
				UAethelnChainTestAbility* Instance = Cast<UAethelnChainTestAbility>(Spec.GetPrimaryInstance());
				if (Instance == nullptr) { continue; }
				for (FAethelnAttackStepDefinition& Step : Instance->ProvisionalSteps)
				{
					Step.ActiveStart *= R.WindowScale; Step.ActiveEnd *= R.WindowScale; Step.BufferOpen *= R.WindowScale;
					Step.LinkOpen *= R.WindowScale; Step.LinkClose *= R.WindowScale; Step.RecoveryEnd *= R.WindowScale;
					Step.CancelOpen *= R.WindowScale; Step.InterruptibleUntil *= R.WindowScale;
				}
			}
		}

		const FVector Ahead = Pawn->GetActorLocation() + (Pawn->GetController() != nullptr ? Pawn->GetController()->GetControlRotation().Vector() : FVector::ForwardVector) * 60.0;
		FActorSpawnParameters SpawnParameters;
		SpawnParameters.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
		AAethelnCombatAICharacter* Dummy = Server.World->SpawnActor<AAethelnCombatAICharacter>(AAethelnCombatAICharacter::StaticClass(), Ahead, FRotator::ZeroRotator, SpawnParameters);
		if (!R.Test.TestNotNull(TEXT("The target dummy spawned"), Dummy)) { return; }
		Dummy->GetCharacterMovement()->DisableMovement();
		UAethelnAttributeInitEffect::ApplyTo(*Dummy->GetAethelnAbilitySystemComponent(), AethelnCombatTests::MakeTestInitValues());
		R.Dummy[Index] = Dummy;
		R.DummyStartHealth = HealthOf(*Dummy);
	}

	/**
	 * Setup shared by every test: both players (and any further attacker) have a pawn and an ASC; the server prepares the
	 * attackers and their dummies; every client has received every player, the attacker's chain spec and the dummies.
	 * Client delegates are bound once: the attacker's own client records the owner RPCs, the observer's client counts
	 * what its copy of the attacker's ASC delivers, and every client counts the dummy's result cues.
	 */
	void QueueSetup(FRun& R, int32 ClientCount, int32 AttackerCount, bool bBindRouting)
	{
		const FTimespan Timeout = FTimespan::FromSeconds(30.0);
		FRun* Run = &R;
		R.Network
			.UntilServer(TEXT("Every player has a pawn and an ASC"), [Run, ClientCount](FState& Server)
			{
				Run->Server = &Server;
				for (int32 Index = 0; Index < ClientCount; ++Index)
				{
					const UAethelnAbilitySystemComponent* AbilitySystem = ServerAbilitySystem(Server, Index);
					if (AbilitySystem == nullptr || AbilitySystem->GetAvatarActor() == nullptr) { return false; }
				}
				return true;
			}, Timeout)
			.ThenServer(TEXT("Prepare the attackers, the observer and the dummies"), [Run, ClientCount, AttackerCount](FState& Server)
			{
				for (int32 Index = 0; Index < ClientCount; ++Index)
				{
					// Spaced along Y so no pawn or dummy touches another attacker's sweep.
					SetUpPlayer(*Run, Server, Index, Index < AttackerCount, FVector(0.0, 2000.0 * Index, 100.0));
				}
				UAethelnCombatTimelineSubsystem* Timeline = Server.World->GetSubsystem<UAethelnCombatTimelineSubsystem>();
				if (!Run->Test.TestNotNull(TEXT("The server world has the combat timeline"), Timeline)) { return; }
				Timeline->OnResultCommitted.AddLambda([Run](const FAethelnCombatResult& Result) { Run->Results.Add(Result); });
				if (UAethelnAbilitySystemComponent* Attacker = ServerAbilitySystem(Server, AttackerClient))
				{
					Attacker->OnGameplayEffectAppliedDelegateToSelf.AddLambda([Run](UAbilitySystemComponent*, const FGameplayEffectSpec& Spec, FActiveGameplayEffectHandle)
					{
						if (Spec.Def != nullptr && Spec.Def->IsA<UAethelnEnduranceCostEffect>()) { ++Run->CostApplications; }
					});
				}
			})
			.UntilClients(TEXT("Every client received the players, the attacker's chain and the dummies"), [Run, ClientCount, AttackerCount, bBindRouting](FState& Client)
			{
				Run->Clients[Client.ClientIndex] = &Client;
				for (int32 Index = 0; Index < ClientCount; ++Index)
				{
					const AAethelnPlayerState* PlayerState = ClientPlayerState(Client, Run->PlayerId[Index]);
					if (PlayerState == nullptr || PlayerState->GetPawn() == nullptr) { return false; }
					if (Index < AttackerCount && Client.ClientIndex == Index && !HasChainSpec(*PlayerState->GetAethelnAbilitySystemComponent())) { return false; }
				}
				TArray<AAethelnCombatAICharacter*> Dummies;
				for (TActorIterator<AAethelnCombatAICharacter> It(Client.World); It; ++It) { Dummies.Add(*It); }
				if (Dummies.Num() < AttackerCount) { return false; }
				if (!bBindRouting || Run->bClientBound[Client.ClientIndex]) { return true; }
				Run->bClientBound[Client.ClientIndex] = true;
				const int32 Index = Client.ClientIndex;
				Dummies[0]->GetAethelnAbilitySystemComponent()->OnCombatResultCue.AddLambda([Run, Index](const FAethelnCombatResultCue&) { ++Run->Cues[Index]; });
				UAethelnAbilitySystemComponent* Attacker = ClientPlayerState(Client, Run->PlayerId[AttackerClient])->GetAethelnAbilitySystemComponent();
				if (Index == AttackerClient)
				{
					Attacker->OnActivationOutcome.AddLambda([Run](uint32 Sequence, EResult Result) { Run->Outcomes.Add({ Sequence, Result }); });
					Attacker->OnCombatActivation.AddLambda([Run](const FAethelnCombatActivationRecord& Record) { Run->Records.Add(Record); });
					Attacker->OnChainEnded.AddLambda([Run](const FGuid& Id, EAethelnChainEndReason Reason) { Run->Ends.Add({ Id, Reason }); });
				}
				else if (Index == ObserverClient)
				{
					Attacker->OnActivationOutcome.AddLambda([Run](uint32, EResult) { ++Run->ObserverOutcomes; });
					Attacker->OnCombatActivation.AddLambda([Run](const FAethelnCombatActivationRecord&) { ++Run->ObserverRecords; });
					Attacker->OnChainEnded.AddLambda([Run](const FGuid&, EAethelnChainEndReason) { ++Run->ObserverEnds; });
				}
				return true;
			}, Timeout);
	}

	/** Polls the replicated phase state on both clients: the observer should see it, the owner never (COND_SkipOwner). */
	void PollPhaseState(FRun& R)
	{
		if (const AAethelnPlayerState* PlayerState = ClientPlayerState(*R.Clients[ObserverClient], R.PlayerId[AttackerClient]))
		{
			const FAethelnAttackPresentationState& State = PlayerState->GetAethelnAbilitySystemComponent()->GetAttackPresentationState();
			if (State.bActive) { R.ObserverSteps.Add(State.ChainStep); }
			R.ObserverLast = State;
		}
		if (const AAethelnPlayerState* PlayerState = ClientPlayerState(*R.Clients[AttackerClient], R.PlayerId[AttackerClient]))
		{
			const FAethelnAttackPresentationState& State = PlayerState->GetAethelnAbilitySystemComponent()->GetAttackPresentationState();
			R.bOwnerCopyChanged |= State.bActive || State.ActivationCounter != 0 || State.EndReason != EAethelnChainEndReason::None;
		}
	}

	void Press(FRun& R)
	{
		FState& Attacker = *R.Clients[AttackerClient];
		R.Test.TestTrue(TEXT("The press reaches the local player's PlayerState through the GameUI entry"), SubmitPrimaryAttack(Attacker.World->GetFirstPlayerController()));
		++R.Sent;
	}

	bool ServerChainGone(const FRun& R)
	{
		const UAethelnAbilitySystemComponent* AbilitySystem = ServerAbilitySystem(*R.Server, AttackerClient);
		return AbilitySystem != nullptr && !AbilitySystem->GetChainStateForTests().bExists;
	}

	/** A19: the three-step chain, each press sent just after the previous step's BufferOpen, by the record the owner received. */
	bool DriveChain(FRun& R)
	{
		PollPhaseState(R);
		const double Now = FPlatformTime::Seconds();
		switch (R.Stage)
		{
		case 0:
			Press(R);
			R.Stage = 1;
			return false;
		case 1: case 3:
		{
			// Wait for the started step's record, then for the client's server-time estimate to pass BufferOpen + margin.
			if (R.Records.Num() < (R.Stage + 1) / 2) { return false; }
			const FAethelnCombatActivationRecord& Record = R.Records.Last();
			R.ThresholdServerTime = Record.StartServerTime + Record.Windows.BufferOpen + PressMarginSeconds;
			++R.Stage;
			return false;
		}
		case 2: case 4:
			if (ClientServerTime(*R.Clients[AttackerClient]) < R.ThresholdServerTime) { return false; }
			Press(R);
			++R.Stage;
			return false;
		case 5:
			if (R.Ends.Num() < 1) { return false; }
			R.Stage = 6;
			R.StageTime = Now;
			return false;
		default:
			// Let the unreliable result cues and the observer's last state arrive.
			return Now >= R.StageTime + 1.0 && ServerChainGone(R);
		}
	}

	/** A20: presses on a fixed cadence from the client's clock, whatever the link does to them. */
	bool DriveCadence(FRun& R, int32 Presses, double SpacingSeconds)
	{
		PollPhaseState(R);
		const double Now = FPlatformTime::Seconds();
		switch (R.Stage)
		{
		case 0:
			R.StageTime = Now;
			R.Stage = 1;
			return false;
		case 1:
			if (Now >= R.StageTime + R.Sent * SpacingSeconds)
			{
				Press(R);
				if (R.Sent == Presses) { R.Stage = 2; }
			}
			return false;
		case 2:
		{
			// Every press has an outcome (the RPC is reliable and in order), and every chain that started has ended.
			int32 ChainsStarted = 0;
			for (const FAethelnCombatActivationRecord& Record : R.Records) { ChainsStarted += Record.ChainStep == 1 ? 1 : 0; }
			if (R.Outcomes.Num() < Presses || !ServerChainGone(R) || R.Ends.Num() < ChainsStarted) { return false; }
			R.Stage = 3;
			R.StageTime = Now;
			return false;
		}
		default:
			return Now >= R.StageTime + 1.0;
		}
	}

	/**
	 * The invariants every run keeps, whatever the link did: one outcome per press, in order; the cost spent once per
	 * accepted press; ordered records; one end per chain; one hit per activation; the dummy's Health equals the authored
	 * damage of its hits. Cadence is the outcomes of the scripted presses; CraftedAccepted counts accepted server-crafted
	 * requests that also spent a cost and started a chain.
	 */
	void AssertAccounting(FRun& R, const TArray<FOutcome>& Cadence, int32 CraftedAccepted)
	{
		FAutomationTestBase& Test = R.Test;
		int32 Accepted = 0;
		for (int32 Index = 0; Index < Cadence.Num(); ++Index)
		{
			if (Cadence[Index].Result == EResult::Accepted) { ++Accepted; }
			Test.TestEqual(TEXT("Outcomes arrive in sequence order, each once"), Cadence[Index].Sequence, static_cast<uint32>(Index + 1));
			Test.TestTrue(TEXT("A press is accepted or blocked by timing, nothing else"),
				Cadence[Index].Result == EResult::Accepted || Cadence[Index].Result == EResult::ActivationBlocked);
		}
		Test.TestEqual(TEXT("The server spent the cost once per accepted press, never twice"), R.CostApplications, Accepted + CraftedAccepted);
		Test.TestEqual(TEXT("Every accepted press started a step: one record each"), R.Records.Num(), Accepted + CraftedAccepted);

		int32 ChainsStarted = 0;
		TMap<FGuid, uint8> StepOfActivation;
		for (int32 Index = 0; Index < R.Records.Num(); ++Index)
		{
			const FAethelnCombatActivationRecord& Record = R.Records[Index];
			ChainsStarted += Record.ChainStep == 1 ? 1 : 0;
			Test.TestTrue(TEXT("A record names a chain step"), Record.ChainStep >= 1 && Record.ChainStep <= 3);
			Test.TestFalse(TEXT("Each activation id appears once"), StepOfActivation.Contains(Record.ActivationId));
			StepOfActivation.Add(Record.ActivationId, Record.ChainStep);
			if (Index > 0) { Test.TestTrue(TEXT("A step follows the previous one, or a new chain starts at step 1"), Record.ChainStep == 1 || Record.ChainStep == R.Records[Index - 1].ChainStep + 1); }
		}
		Test.TestEqual(TEXT("Every chain that started ended once"), R.Ends.Num(), ChainsStarted);
		for (const FEndRecord& End : R.Ends)
		{
			Test.TestTrue(TEXT("A chain ends by completion or timeout in these runs"), End.Reason == EAethelnChainEndReason::Completed || End.Reason == EAethelnChainEndReason::Timeout);
		}

		// Damage: each activation hit the dummy at most once, and the dummy lost exactly the authored damage of those steps.
		TSet<FGuid> Hit;
		float ExpectedDamage = 0.0f;
		for (const FAethelnCombatResult& Result : R.Results)
		{
			Test.TestEqual(TEXT("A committed result is a hit in this fixture"), Result.Outcome, EAethelnCombatResultOutcome::Hit);
			Test.TestFalse(TEXT("An activation hits the dummy once"), Hit.Contains(Result.ActivationId));
			Hit.Add(Result.ActivationId);
			if (const uint8* Step = StepOfActivation.Find(Result.ActivationId)) { ExpectedDamage += WroughtDamageOfStep(*Step); }
			else { Test.AddError(TEXT("A result belongs to an activation the owner never received a record for")); }
		}
		if (const AAethelnCombatAICharacter* Dummy = R.Dummy[AttackerClient].Get())
		{
			Test.TestEqual(TEXT("The dummy lost the damage of its hits and no more"), HealthOf(*Dummy), R.DummyStartHealth - ExpectedDamage);
		}
		Test.TestTrue(TEXT("The test is not vacuous: the chain hit the dummy at least once"), R.Results.Num() >= 1);
		Test.TestEqual(TEXT("The observer never receives a record, an outcome or a chain end"), R.ObserverRecords + R.ObserverOutcomes + R.ObserverEnds, 0);
		Test.TestFalse(TEXT("The owner's copy of the phase state never changes (COND_SkipOwner)"), R.bOwnerCopyChanged);
	}

	FString OutcomeSummary(const FRun& R, int32 PressesSent)
	{
		TMap<FString, int32> Counts;
		for (const FOutcome& Outcome : R.Outcomes) { ++Counts.FindOrAdd(StaticEnum<EResult>()->GetNameStringByValue(static_cast<int64>(Outcome.Result))); }
		FString Text = FString::Printf(TEXT("presses=%d records=%d hits=%d cues(A,B)=%d,%d"), PressesSent, R.Records.Num(), R.Results.Num(), R.Cues[AttackerClient], R.Cues[ObserverClient]);
		for (const TPair<FString, int32>& Pair : Counts) { Text += FString::Printf(TEXT(" %s=%d"), *Pair.Key, Pair.Value); }
		return Text;
	}

	void QueueAttackOutcomeRouting(FAutomationTestBase& Test)
	{
		const TSharedRef<FRun> Run = MakeShared<FRun>(Test);
		BuildNetwork(*Run, 2, nullptr);
		QueueSetup(*Run, 2, 1, true);
		FRun* R = &Run.Get();
		R->Network.Until(TEXT("Press the three-step chain"), [R]() { return DriveChain(*R); }, FTimespan::FromSeconds(40.0));
		R->Network
			.ThenServer(TEXT("The owner got the outcomes, the records and the chain end; the observer got the phase state"), [R](FState&)
			{
				FAutomationTestBase& T = R->Test;
				T.TestEqual(TEXT("The owner received three outcomes"), R->Outcomes.Num(), 3);
				for (int32 Index = 0; Index < R->Outcomes.Num(); ++Index)
				{
					T.TestEqual(TEXT("Each press is accepted"), R->Outcomes[Index].Result, EResult::Accepted);
					T.TestEqual(TEXT("Outcomes carry the press sequence"), R->Outcomes[Index].Sequence, static_cast<uint32>(Index + 1));
				}
				if (T.TestEqual(TEXT("The owner received a record for each of the three steps"), R->Records.Num(), 3))
				{
					for (int32 Index = 0; Index < 3; ++Index)
					{
						T.TestEqual(TEXT("Records name steps 1, 2, 3 in order"), static_cast<int32>(R->Records[Index].ChainStep), Index + 1);
						T.TestTrue(TEXT("The chain ability id is on the record"), R->Records[Index].AbilityId == AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain);
						T.TestTrue(TEXT("The control-rotation aim is a unit vector"), FMath::IsNearlyEqual(R->Records[Index].AcceptedAim.Size(), 1.0, 0.01));
						T.TestEqual(TEXT("A press at the controller's rotation is not corrected"), R->Records[Index].AimCorrection, EAethelnAimCorrection::None);
					}
				}
				if (T.TestEqual(TEXT("The owner received one chain end"), R->Ends.Num(), 1) && R->Records.Num() == 3)
				{
					T.TestEqual(TEXT("The chain completed"), R->Ends[0].Reason, EAethelnChainEndReason::Completed);
					T.TestEqual(TEXT("The end names the final step's activation"), R->Ends[0].ActivationId, R->Records[2].ActivationId);
				}
				T.TestEqual(TEXT("The server committed three hits, one per step"), R->Results.Num(), 3);
				T.TestEqual(TEXT("The cost was spent once per step"), R->CostApplications, 3);

				T.TestEqual(TEXT("The observer saw the phase state of each step"), R->ObserverSteps.Num(), 3);
				for (const uint8 Step : R->ObserverSteps) { T.TestTrue(TEXT("An observed step is 1, 2 or 3"), Step >= 1 && Step <= 3); }
				T.TestFalse(TEXT("The phase state is inactive at the end"), R->ObserverLast.bActive);
				T.TestEqual(TEXT("The observer sees why the chain ended"), R->ObserverLast.EndReason, EAethelnChainEndReason::Completed);
				T.TestEqual(TEXT("The observer received no record, outcome or chain end"), R->ObserverRecords + R->ObserverOutcomes + R->ObserverEnds, 0);
				T.TestFalse(TEXT("The owner's copy of the phase state never changed (COND_SkipOwner)"), R->bOwnerCopyChanged);

				// The cue is unreliable by design but the link is clean loopback: each client sees one per committed hit.
				T.TestEqual(TEXT("The attacker's client saw a result cue per hit"), R->Cues[AttackerClient], 3);
				T.TestEqual(TEXT("The observer's client saw a result cue per hit"), R->Cues[ObserverClient], 3);
				T.AddInfo(OutcomeSummary(*R, 3));
			});
		QueueTeardown(Run);
	}

	/** All of a settled run's owner traffic has arrived: an outcome per press, and an end per chain that started. */
	bool OwnerTrafficSettled(const FRun& R, int32 ExpectedOutcomes)
	{
		int32 ChainsStarted = 0;
		for (const FAethelnCombatActivationRecord& Record : R.Records) { ChainsStarted += Record.ChainStep == 1 ? 1 : 0; }
		return R.Outcomes.Num() >= ExpectedOutcomes && ServerChainGone(R) && R.Ends.Num() >= ChainsStarted;
	}

	/**
	 * A20: the cadence run, then the attacker's client sends three requests over the reliable RPC that the GameUI entry never
	 * builds (a turn beyond the hard bound, a stale time sample, an aim between the soft and hard bounds) and the run checks that
	 * each outcome and the correction mark reach the owner. The validation math is A2's; this proves the routing.
	 */
	void QueueChainUnderProfile(FAutomationTestBase& Test, const FPacketSimulationSettings* Impairment)
	{
		constexpr int32 Presses = 6;
		constexpr double SpacingSeconds = 0.5;
		constexpr uint32 CraftedBase = 100;
		const TSharedRef<FRun> Run = MakeShared<FRun>(Test);
		BuildNetwork(*Run, 2, Impairment);
		QueueSetup(*Run, 2, 1, true);
		FRun* R = &Run.Get();
		R->Network.Until(TEXT("Press on a fixed cadence"), [R]() { return DriveCadence(*R, Presses, SpacingSeconds); }, FTimespan::FromSeconds(60.0));
		R->Network
			.ThenClient(TEXT("The attacker's client sends an impossible turn, a stale time sample and a corrected aim over the wire"), AttackerClient, [R](FState& Client)
			{
				const AAethelnPlayerState* PlayerState = ClientPlayerState(Client, R->PlayerId[AttackerClient]);
				UAethelnAbilitySystemComponent* Attacker = PlayerState != nullptr ? PlayerState->GetAethelnAbilitySystemComponent() : nullptr;
				if (!R->Test.TestNotNull(TEXT("The attacker's ASC exists on its own client"), Attacker)) { return; }
				const FVector Reference = Client.World->GetFirstPlayerController()->GetControlRotation().Vector();
				const double Now = ClientServerTime(Client);
				// What a client that bypasses the GameUI entry could send: its own aim and time sample, on the reliable RPC.
				auto Send = [&](uint32 Sequence, double YawOffsetDegrees, double TimeOffsetSeconds)
				{
					FAethelnCombatActivationRequest Request = AethelnChainTests::MakeChainRequest(*Attacker, Sequence);
					Request.Aim = FRotator(0.0, YawOffsetDegrees, 0.0).RotateVector(Reference);
					Request.ClientServerTimeSeconds = Now + TimeOffsetSeconds;
					Attacker->ServerSubmitActivation(Request);
				};
				Send(CraftedBase, 120.0, 0.0);
				Send(CraftedBase + 1, 0.0, -10.0);
				Send(CraftedBase + 2, 45.0, 0.0);
			});
		R->Network
			.UntilClient(TEXT("The owner receives the crafted outcomes, the corrected record and the chain end"), AttackerClient, [R](FState&)
			{
				return OwnerTrafficSettled(*R, Presses + 3) && R->Records.Num() > 0 && R->Records.Last().Sequence == CraftedBase + 2;
			}, FTimespan::FromSeconds(30.0))
			.ThenServer(TEXT("Chain accounting, the crafted rows and the profile summary"), [R](FState&)
			{
				FAutomationTestBase& T = R->Test;
				TArray<FOutcome> Crafted;
				TArray<FOutcome> Cadence;
				for (const FOutcome& Outcome : R->Outcomes) { (Outcome.Sequence >= CraftedBase ? Crafted : Cadence).Add(Outcome); }
				if (T.TestEqual(TEXT("The owner received the three crafted outcomes"), Crafted.Num(), 3))
				{
					T.TestEqual(TEXT("The rejected turn reaches the owner as ImpossibleAimTransition"), Crafted[0].Result, EResult::ImpossibleAimTransition);
					T.TestEqual(TEXT("The stale time sample reaches the owner as TimestampOutOfBounds"), Crafted[1].Result, EResult::TimestampOutOfBounds);
					T.TestEqual(TEXT("The corrected press is accepted"), Crafted[2].Result, EResult::Accepted);
				}
				const FAethelnCombatActivationRecord& CraftedRecord = R->Records.Last();
				T.TestEqual(TEXT("The corrected record carries the correction mark"), CraftedRecord.AimCorrection, EAethelnAimCorrection::AimCorrected);
				const double AngleToReference = FMath::RadiansToDegrees(FMath::Acos(FMath::Clamp(FVector(CraftedRecord.AcceptedAim).Dot(FVector::ForwardVector), -1.0, 1.0)));
				T.TestTrue(TEXT("The accepted aim is the server reference turned toward the aim by exactly the soft bound"),
					FMath::IsNearlyEqual(AngleToReference, AethelnCombatTests::MakeTestAimTimeBounds().AimSoftBoundDegrees, 1.0));
				AssertAccounting(*R, Cadence, 1);

				if (R->bImpaired)
				{
					// The cue is unreliable by design: an impaired link may drop it, and nothing authoritative depends on it.
					for (const int32 Client : { AttackerClient, ObserverClient }) { T.TestTrue(TEXT("A client never sees more cues than hits"), R->Cues[Client] <= R->Results.Num()); }
				}
				else
				{
					int32 Accepted = 0;
					for (const FOutcome& Outcome : Cadence) { Accepted += Outcome.Result == EResult::Accepted ? 1 : 0; }
					T.TestTrue(TEXT("On a clean link at least three presses are accepted"), Accepted >= 3);
					for (const int32 Client : { AttackerClient, ObserverClient }) { T.TestEqual(TEXT("On a clean link a client sees a cue per hit"), R->Cues[Client], R->Results.Num()); }
				}
				T.AddInfo(OutcomeSummary(*R, Presses));
			});
		QueueTeardown(Run);
	}

	/** What each lost player was doing on the server at the moment its connection closed. */
	bool PhaseMatches(int32 Index, const FAethelnServerChainState& Chain, const FAethelnAttackStepDefinition& Definition, double Elapsed)
	{
		switch (Index)
		{
		case 0: return Chain.Step == 1 && !Chain.bWaiting && Elapsed < Definition.ActiveStart;
		case 1: return Chain.Step == 1 && !Chain.bWaiting && Elapsed >= Definition.ActiveStart && Elapsed < Definition.ActiveEnd;
		default: return Chain.bWaiting;
		}
	}

	/** A21: three players press at once; each loses its connection in a different phase. */
	bool DriveDisconnects(FRun& R)
	{
		const double Now = FPlatformTime::Seconds();
		FState& Server = *R.Server;
		const double ServerNow = Server.World->GetTimeSeconds();
		if (R.Stage == 0)
		{
			for (int32 Index = 0; Index < 3; ++Index) { SubmitPrimaryAttack(R.Clients[Index]->World->GetFirstPlayerController()); }
			R.Stage = 1;
			return false;
		}
		if (R.Stage == 1)
		{
			for (int32 Index = 0; Index < 3; ++Index)
			{
				if (R.bClosed[Index]) { continue; }
				UAethelnAbilitySystemComponent* AbilitySystem = ServerAbilitySystem(Server, Index);
				if (AbilitySystem == nullptr || !AbilitySystem->GetChainStateForTests().bExists) { continue; }
				const FAethelnServerChainState& Chain = AbilitySystem->GetChainStateForTests();
				const FAethelnAttackStepDefinition& Definition = Chain.Definitions[Chain.Step - 1];
				const double Elapsed = ServerNow - Chain.StartTime;
				if (Index == 2 && !R.bSecondPressed)
				{
					// Buffer the next step, then lose the connection while it waits for LinkOpen.
					if (ClientServerTime(*R.Clients[2]) >= Chain.StartTime + Definition.BufferOpen + PressMarginSeconds)
					{
						SubmitPrimaryAttack(R.Clients[2]->World->GetFirstPlayerController());
						R.bSecondPressed = true;
					}
					continue;
				}
				if (!PhaseMatches(Index, Chain, Definition, Elapsed))
				{
					// Player 0 closes at its first sight of a started step; a later look is not a wind-up and fails the row below.
					if (Index != 0 || Elapsed < Definition.ActiveStart) { continue; }
				}
				R.ElapsedAtClose[Index] = Elapsed;
				R.LostAbilitySystem[Index] = AbilitySystem;
				R.HealthAtClose[Index] = R.Dummy[Index].IsValid() ? HealthOf(*R.Dummy[Index]) : 0.0f;
				R.Test.TestTrue(*FString::Printf(TEXT("Player %d lost its connection in the intended phase (elapsed %.3f s)"), Index, Elapsed), PhaseMatches(Index, Chain, Definition, Elapsed));
				Server.ClientConnections[Index]->Close();
				R.bClosed[Index] = true;
			}
			if (R.bClosed[0] && R.bClosed[1] && R.bClosed[2])
			{
				R.ResultsAtAllClosed = R.Results.Num();
				R.StageTime = Now;
				R.Stage = 2;
			}
			return false;
		}
		const UAethelnCombatTimelineSubsystem* Timeline = Server.World->GetSubsystem<UAethelnCombatTimelineSubsystem>();
		if (R.Stage == 2)
		{
			// The first poll at which every lost player's avatar is gone. Sample the timeline now and do not wait for zero:
			// a step expires on its own within the scaled link window, so waiting would pass without any loss handling.
			for (int32 Index = 0; Index < 3; ++Index)
			{
				const UAethelnAbilitySystemComponent* Lost = R.LostAbilitySystem[Index].Get();
				if (Lost != nullptr && Lost->GetAvatarActor() != nullptr) { return false; }
			}
			if (Timeline == nullptr) { return false; }
			R.StepsAfterLoss = Timeline->GetRegisteredStepCountForTests();
			R.OwnersAfterLoss = Timeline->GetBoundaryOwnerCountForTests();
			for (int32 Index = 0; Index < 3; ++Index)
			{
				// An ASC that is already destroyed has no chain; one still alive must have ended it.
				const UAethelnAbilitySystemComponent* Lost = R.LostAbilitySystem[Index].Get();
				R.bLostChainGone[Index] = Lost == nullptr || !Lost->GetChainStateForTests().bExists;
			}
			R.StageTime = Now;
			R.Stage = 3;
			return false;
		}
		// Stage 3: let a second pass, past the buffered step's LinkOpen, before anything else runs.
		return Now >= R.StageTime + 1.0;
	}

	void QueueDisconnectMidChain(FAutomationTestBase& Test)
	{
		constexpr int32 SurvivorClient = 3;
		const TSharedRef<FRun> Run = MakeShared<FRun>(Test);
		// Windows four times as long as the provisional ones, so a poll per frame lands in each phase.
		Run->WindowScale = 4.0;
		// Each closed connection makes that PIE client log the engine's own connection-lost failure.
		Test.AddExpectedMessage(TEXT("UEngine::BroadcastNetworkFailure: FailureType = ConnectionLost"), ELogVerbosity::Error, EAutomationExpectedMessageFlags::Contains, 0);
		Test.AddExpectedMessage(TEXT("Network Failure: GameNetDriver\\[ConnectionLost\\]"), ELogVerbosity::Warning, EAutomationExpectedMessageFlags::Contains, 0);
		// The three disconnected clients fall back to GameDefaultMap, which is MovementPOC and now holds a built navigation
		// mesh; tearing each of those fallback worlds down makes the crowd manager log an engine warning for the mesh that is
		// already gone (#83 P4). Count 0 requires it at least once, as E12 does.
		Test.AddExpectedMessage(TEXT("Unable to find RecastNavMesh instance while trying to create UCrowdManager instance"), ELogVerbosity::Warning, EAutomationExpectedMessageFlags::Contains, 0);
		BuildNetwork(*Run, 4, nullptr);
		QueueSetup(*Run, 4, 4, false);
		FRun* R = &Run.Get();
		R->Network.Until(TEXT("Press at once; close each connection in a different phase"), [R]() { return DriveDisconnects(*R); }, FTimespan::FromSeconds(60.0));
		R->Network
			.ThenClient(TEXT("The surviving player presses"), SurvivorClient, [R](FState& Client)
			{
				R->Test.TestTrue(TEXT("The surviving player's press reaches its PlayerState"), SubmitPrimaryAttack(Client.World->GetFirstPlayerController()));
			})
			.UntilServer(TEXT("The surviving player's chain hits its own dummy"), [R](FState& Server)
			{
				const UAethelnAbilitySystemComponent* Survivor = ServerAbilitySystem(Server, SurvivorClient);
				return Survivor != nullptr && R->Results.Num() > R->ResultsAtAllClosed && R->Dummy[SurvivorClient].IsValid() && HealthOf(*R->Dummy[SurvivorClient]) < R->DummyStartHealth;
			}, FTimespan::FromSeconds(30.0))
			.ThenServer(TEXT("No result after avatar loss, no stale chain state"), [R](FState& Server)
			{
				FAutomationTestBase& T = R->Test;
				const UAethelnAbilitySystemComponent* Survivor = ServerAbilitySystem(Server, SurvivorClient);
				if (!T.TestNotNull(TEXT("The surviving player's ASC exists"), Survivor)) { return; }
				T.TestEqual(TEXT("Player 0 lost its connection before its first contact: its dummy is untouched"), HealthOf(*R->Dummy[0]), R->DummyStartHealth);
				for (int32 Index = 0; Index < 3; ++Index)
				{
					T.TestEqual(*FString::Printf(TEXT("Player %d's dummy took nothing after the loss"), Index), HealthOf(*R->Dummy[Index]), R->HealthAtClose[Index]);
				}
				for (int32 Index = 0; Index < 3; ++Index) { T.TestTrue(*FString::Printf(TEXT("Player %d had no chain left when its avatar went"), Index), R->bLostChainGone[Index]); }
				T.TestEqual(TEXT("Nothing stayed registered with the timeline when the last avatar went"), R->StepsAfterLoss, 0);
				T.TestEqual(TEXT("No boundary owner stayed registered when the last avatar went"), R->OwnersAfterLoss, 0);
				T.TestEqual(TEXT("The survivor's first press is its sequence 1: nothing carried over from a lost player"), static_cast<int32>(Survivor->GetLastAcceptedSequenceForTests()), 1);
				T.TestTrue(TEXT("The survivor's chain started at step 1"), Survivor->GetChainStateForTests().bExists && Survivor->GetChainStateForTests().Step == 1);
				T.AddInfo(FString::Printf(TEXT("elapsed at close (s): %.3f %.3f %.3f; results at last loss %d; survivor results %d"),
					R->ElapsedAtClose[0], R->ElapsedAtClose[1], R->ElapsedAtClose[2], R->ResultsAtAllClosed, R->Results.Num() - R->ResultsAtAllClosed));
			});
		QueueTeardown(Run);
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAttackOutcomeRoutingTest,
	"Aetheln.GameCombat.Net.AttackOutcomeRouting",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAttackOutcomeRoutingTest::RunTest(const FString& Parameters)
{
	AethelnTwoClientAttackTests::QueueAttackOutcomeRouting(*this);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnChainUnderProfilesTest,
	"Aetheln.GameCombat.Net.ChainUnderProfiles",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnChainUnderProfilesTest::RunTest(const FString& Parameters)
{
	AethelnTwoClientAttackTests::QueueChainUnderProfile(*this, nullptr);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDisconnectMidChainTest,
	"Aetheln.GameCombat.Net.DisconnectMidChain",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDisconnectMidChainTest::RunTest(const FString& Parameters)
{
	AethelnTwoClientAttackTests::QueueDisconnectMidChain(*this);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnChainUnderProfilesImpairedTest,
	"Aetheln.GameCombat.Net.ChainUnderProfilesImpaired",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnChainUnderProfilesImpairedTest::RunTest(const FString& Parameters)
{
	// Fixture impairment on every driver, both directions, as the #21 P3 impaired run: 100 ms lag each way and 5 % loss.
	// These are test settings, not the #45 network profile. Duplication and reordering cannot combine with lag and are
	// absorbed by the reliable channel before the seam sees a request; the seam's own duplicate, stale and dropped
	// request rows are A25 and A26.
	FPacketSimulationSettings Impairment;
	Impairment.PktLag = 100;
	Impairment.PktLoss = 5;
	AethelnTwoClientAttackTests::QueueChainUnderProfile(*this, &Impairment);
	return true;
}

#endif
