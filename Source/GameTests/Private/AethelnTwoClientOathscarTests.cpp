#if WITH_DEV_AUTOMATION_TESTS && WITH_EDITOR

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatAICharacter.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatEffects.h"
#include "AethelnCombatGameMode.h"
#include "AethelnCombatTestWorld.h"
#include "AethelnCombatTimelineSubsystem.h"
#include "AethelnGameplayTags.h"
#include "AethelnOathscarTestAbilities.h"
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

// #260 P5, Test Plan K14 (docs/gas-foundation.md, Representative Oathscar Actives). A PIE session with one dedicated server and
// two clients in this process, on real net drivers over loopback (CQTest's FPIENetworkComponent), under the A19 to A21
// conditions of #60 P6 (docs/attack-timeline-and-combo.md). The attacker presses Instant Strike, Parry, Attack Stance and Defense
// Stance through the same GameUI entry the bound keys use (SubmitAbilityPress -> IAethelnCombatInputSink -> the ASC's activation
// request), so the request, the control-rotation aim, the time sample and the owner RPCs are the engine's own. It simulates no
// input device and no separate process. The actives are the Editor-module fixture classes (AethelnOathscarTestAbilities.h): the
// production classes stay out of GrantedAbilities until their values exist (owner, issue #260 comment 6142715904), and every
// value here is a fixture value, never tuning. The impairment is a fixture setting, not the #45 profile. Only the clean link
// (C1) and a fixture lag and loss run here; each C2 kind (PktOrder, PktDup, and the others) is the manual step in the document.
namespace AethelnTwoClientOathscarTests
{
	using FState = FBasePIENetworkComponentState;
	using EResult = EAethelnActivationResult;
	constexpr int32 AttackerClient = 0;
	constexpr int32 ObserverClient = 1;
	constexpr int32 PressCount = 4;

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
		FState* Clients[2] = {};
		int32 PlayerId[2] = { INDEX_NONE, INDEX_NONE };
		TWeakObjectPtr<AAethelnCombatAICharacter> Dummy;
		float DummyStartHealth = 0.0f;

		// Server side.
		TArray<FAethelnCombatResult> Results;
		int32 CostApplications = 0;
		bool bServerBothStances = false;
		int32 ServerMaxStanceEffects = 0;

		// The attacker's own client: what the owner RPCs delivered, and its copy of its own stance effects.
		TArray<FOutcome> Outcomes;
		TArray<FAethelnCombatActivationRecord> Records;
		TArray<FEndRecord> Ends;
		bool bOwnerCopyChanged = false;
		int32 OwnerStanceEffects = 0;
		int32 OwnerMaxStanceEffects = 0;
		bool bOwnerBothStances = false;

		// The observer's client: its copy of the attacker's ASC.
		int32 ObserverOutcomes = 0;
		int32 ObserverRecords = 0;
		int32 ObserverEnds = 0;
		TSet<uint8> ObserverSteps;
		FAethelnAttackPresentationState ObserverLast;
		bool bObserverSawParrying = false;
		bool bObserverSawAttackStance = false;
		bool bObserverBothStances = false;
		int32 ObserverMaxStanceEffects = 0;
		bool bObserverHasAttackStance = false;
		bool bObserverHasDefenseStance = false;
		bool bObserverHasParrying = false;

		// Result cues on the dummy's ASC, per client.
		int32 Cues[2] = {};
		bool bClientBound[2] = {};

		// Driver state.
		int32 Stage = 0;
		double StageTime = 0.0;
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

	float HealthOf(const AAethelnCombatAICharacter& Character)
	{
		return Character.GetAethelnAbilitySystemComponent()->GetNumericAttribute(UAethelnCombatAttributeSet::GetHealthAttribute());
	}

	/** True once the four fixture actives are granted on this ASC copy (the client receives its specs after the server grants them). */
	bool HasAllActives(const UAethelnAbilitySystemComponent& AbilitySystem)
	{
		int32 Found = 0;
		for (const FGameplayAbilitySpec& Spec : AbilitySystem.GetActivatableAbilities())
		{
			if (Spec.Ability == nullptr) { continue; }
			Found += Spec.Ability->IsA<UAethelnInstantStrikeTestAbility>() || Spec.Ability->IsA<UAethelnParryTestAbility>()
				|| Spec.Ability->IsA<UAethelnAttackStanceTestAbility>() || Spec.Ability->IsA<UAethelnDefenseStanceTestAbility>();
		}
		return Found == PressCount;
	}

	FGameplayTagContainer StanceTags()
	{
		FGameplayTagContainer Tags;
		Tags.AddTag(AethelnGameplayTags::State_Oathscar_AttackStance);
		Tags.AddTag(AethelnGameplayTags::State_Oathscar_DefenseStance);
		return Tags;
	}

	/** The active effects on this ASC copy that grant either stance tag. */
	int32 StanceEffectCount(const UAbilitySystemComponent& AbilitySystem)
	{
		return AbilitySystem.GetActiveEffects(FGameplayEffectQuery::MakeQuery_MatchAnyOwningTags(StanceTags())).Num();
	}

	bool BothStanceTags(const UAbilitySystemComponent& AbilitySystem)
	{
		return AbilitySystem.HasMatchingGameplayTag(AethelnGameplayTags::State_Oathscar_AttackStance)
			&& AbilitySystem.HasMatchingGameplayTag(AethelnGameplayTags::State_Oathscar_DefenseStance);
	}

	void AddCqTestPieExpectedMessages(FAutomationTestBase& Test)
	{
		// CQTest plays a new unsaved map, whose level and world settings have no stable package path for the net GUID cache.
		Test.AddExpectedMessage(TEXT("FNetGUIDCache::SupportsObject: Level /Temp/UEDPIE_\\d+_Untitled_\\d+\\.Untitled:PersistentLevel NOT Supported"), ELogVerbosity::Warning,
			EAutomationExpectedMessageFlags::Contains, 0);
		Test.AddExpectedMessage(TEXT("RegisterNetGUID_Client: Guid with pathname\\. FullNetGUIDPath: \\[\\d+\\]WorldSettings"), ELogVerbosity::Warning,
			EAutomationExpectedMessageFlags::Contains, 0);
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
	 * Fixture state for one player on the server: attribute values and a still pawn; the attacker also has the four fixture actives, the
	 * aim and time bounds, a rate bucket that never limits, and a dummy 60 units ahead of its pawn, where Instant Strike's sweep reaches it
	 * (as in K2).
	 */
	void SetUpPlayer(FRun& R, FState& Server, int32 Index, const FVector& Where)
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
		if (Index != AttackerClient) { return; }
		AethelnCombatTests::SetTestAimTimeBounds(*AbilitySystem);
		AbilitySystem->ProvisionalAimMaxRateDegreesPerSecond = 1000.0f;
		AbilitySystem->ProvisionalActivationBucketCapacity = 1000.0f;
		AbilitySystem->ProvisionalActivationBucketRefillPerSecond = 0.0f;
		for (UClass* Class : { UAethelnInstantStrikeTestAbility::StaticClass(), UAethelnParryTestAbility::StaticClass(),
			UAethelnAttackStanceTestAbility::StaticClass(), UAethelnDefenseStanceTestAbility::StaticClass() })
		{
			AbilitySystem->GiveAbility(FGameplayAbilitySpec(Class, 1));
		}

		const FVector Ahead = Pawn->GetActorLocation() + FVector(60.0, 0.0, 0.0);
		FActorSpawnParameters SpawnParameters;
		SpawnParameters.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
		AAethelnCombatAICharacter* Dummy = Server.World->SpawnActor<AAethelnCombatAICharacter>(AAethelnCombatAICharacter::StaticClass(), Ahead, FRotator::ZeroRotator, SpawnParameters);
		if (!R.Test.TestNotNull(TEXT("The target dummy spawned"), Dummy)) { return; }
		Dummy->GetCharacterMovement()->DisableMovement();
		UAethelnAttributeInitEffect::ApplyTo(*Dummy->GetAethelnAbilitySystemComponent(), AethelnCombatTests::MakeTestInitValues());
		R.Dummy = Dummy;
		R.DummyStartHealth = HealthOf(*Dummy);
	}

	/** Prepares the server and waits for both clients to receive both players, the attacker's four actives and the dummy; binds each client's delegates once. */
	void QueueSetup(FRun& R)
	{
		const FTimespan Timeout = FTimespan::FromSeconds(30.0);
		FRun* Run = &R;
		R.Network
			.UntilServer(TEXT("Both players have a pawn and an ASC"), [Run](FState& Server)
			{
				Run->Server = &Server;
				for (int32 Index = 0; Index < 2; ++Index)
				{
					const UAethelnAbilitySystemComponent* AbilitySystem = ServerAbilitySystem(Server, Index);
					if (AbilitySystem == nullptr || AbilitySystem->GetAvatarActor() == nullptr) { return false; }
				}
				return true;
			}, Timeout)
			.ThenServer(TEXT("Prepare the attacker, the observer and the dummy"), [Run](FState& Server)
			{
				for (int32 Index = 0; Index < 2; ++Index) { SetUpPlayer(*Run, Server, Index, FVector(0.0, 2000.0 * Index, 100.0)); }
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
			.UntilClients(TEXT("Every client received the players, the attacker's actives and the dummy"), [Run](FState& Client)
			{
				Run->Clients[Client.ClientIndex] = &Client;
				for (int32 Index = 0; Index < 2; ++Index)
				{
					const AAethelnPlayerState* PlayerState = ClientPlayerState(Client, Run->PlayerId[Index]);
					if (PlayerState == nullptr || PlayerState->GetPawn() == nullptr) { return false; }
				}
				// Only the owner receives its ability specs; an observer's copy has none.
				if (Client.ClientIndex == AttackerClient && !HasAllActives(*ClientPlayerState(Client, Run->PlayerId[AttackerClient])->GetAethelnAbilitySystemComponent())) { return false; }
				TArray<AAethelnCombatAICharacter*> Dummies;
				for (TActorIterator<AAethelnCombatAICharacter> It(Client.World); It; ++It) { Dummies.Add(*It); }
				if (Dummies.Num() < 1) { return false; }
				if (Run->bClientBound[Client.ClientIndex]) { return true; }
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
				else
				{
					Attacker->OnActivationOutcome.AddLambda([Run](uint32, EResult) { ++Run->ObserverOutcomes; });
					Attacker->OnCombatActivation.AddLambda([Run](const FAethelnCombatActivationRecord&) { ++Run->ObserverRecords; });
					Attacker->OnChainEnded.AddLambda([Run](const FGuid&, EAethelnChainEndReason) { ++Run->ObserverEnds; });
				}
				return true;
			}, Timeout);
	}

	/**
	 * Polls what each side holds, every frame: the observer's copy of the attacker (phase state, the Parry and stance tags, any effect)
	 * and the owner's (its phase state never changes, its stance effect count), and the server's stance exclusion.
	 */
	void Poll(FRun& R)
	{
		if (const UAethelnAbilitySystemComponent* Server = ServerAbilitySystem(*R.Server, AttackerClient))
		{
			R.ServerMaxStanceEffects = FMath::Max(R.ServerMaxStanceEffects, StanceEffectCount(*Server));
			R.bServerBothStances |= BothStanceTags(*Server);
		}
		if (const AAethelnPlayerState* PlayerState = ClientPlayerState(*R.Clients[ObserverClient], R.PlayerId[AttackerClient]))
		{
			const UAethelnAbilitySystemComponent& AbilitySystem = *PlayerState->GetAethelnAbilitySystemComponent();
			const FAethelnAttackPresentationState& State = AbilitySystem.GetAttackPresentationState();
			if (State.bActive) { R.ObserverSteps.Add(State.ChainStep); }
			R.ObserverLast = State;
			R.bObserverHasParrying = AbilitySystem.HasMatchingGameplayTag(AethelnGameplayTags::State_Oathscar_Parrying);
			R.bObserverHasAttackStance = AbilitySystem.HasMatchingGameplayTag(AethelnGameplayTags::State_Oathscar_AttackStance);
			R.bObserverHasDefenseStance = AbilitySystem.HasMatchingGameplayTag(AethelnGameplayTags::State_Oathscar_DefenseStance);
			R.bObserverSawParrying |= R.bObserverHasParrying;
			R.bObserverSawAttackStance |= R.bObserverHasAttackStance;
			R.bObserverBothStances |= BothStanceTags(AbilitySystem);
			R.ObserverMaxStanceEffects = FMath::Max(R.ObserverMaxStanceEffects, StanceEffectCount(AbilitySystem));
		}
		if (const AAethelnPlayerState* PlayerState = ClientPlayerState(*R.Clients[AttackerClient], R.PlayerId[AttackerClient]))
		{
			const UAethelnAbilitySystemComponent& AbilitySystem = *PlayerState->GetAethelnAbilitySystemComponent();
			const FAethelnAttackPresentationState& State = AbilitySystem.GetAttackPresentationState();
			R.bOwnerCopyChanged |= State.bActive || State.ActivationCounter != 0 || State.EndReason != EAethelnChainEndReason::None;
			R.OwnerStanceEffects = StanceEffectCount(AbilitySystem);
			R.OwnerMaxStanceEffects = FMath::Max(R.OwnerMaxStanceEffects, R.OwnerStanceEffects);
			R.bOwnerBothStances |= BothStanceTags(AbilitySystem);
		}
	}

	void Press(FRun& R, const FGameplayTag& AbilityId)
	{
		R.Test.TestTrue(TEXT("The press reaches the local player's PlayerState through the GameUI entry"),
			SubmitAbilityPress(R.Clients[AttackerClient]->World->GetFirstPlayerController(), AbilityId));
	}

	bool ServerHas(const FRun& R, const FGameplayTag& Tag)
	{
		const UAethelnAbilitySystemComponent* AbilitySystem = ServerAbilitySystem(*R.Server, AttackerClient);
		return AbilitySystem != nullptr && AbilitySystem->HasMatchingGameplayTag(Tag);
	}

	/**
	 * One press of each active, each sent only after the previous one's server effect ended or settled, so every press is accepted whatever
	 * the link does to its delivery: Instant Strike (hits the dummy once, ends the chain), Parry (its window opens and closes), Attack Stance,
	 * then Defense Stance (which replaces it).
	 */
	bool DriveActives(FRun& R)
	{
		Poll(R);
		const double Now = FPlatformTime::Seconds();
		const UAethelnAbilitySystemComponent* ServerAttacker = ServerAbilitySystem(*R.Server, AttackerClient);
		switch (R.Stage)
		{
		case 0:
			Press(R, AethelnGameplayTags::Ability_Oathscar_InstantStrike);
			R.Stage = 1;
			return false;
		case 1:
			// Its outcome and record reached the owner, the strike hit, and the commitment and the chain are over on the server.
			if (R.Outcomes.Num() < 1 || R.Records.Num() < 1 || R.Ends.Num() < 1 || R.Results.Num() < 1 || ServerAttacker == nullptr
				|| ServerAttacker->GetChainStateForTests().bExists || ServerHas(R, AethelnGameplayTags::State_Oathscar_InstantStrike)) { return false; }
			Press(R, AethelnGameplayTags::Ability_Oathscar_Parry);
			R.Stage = 2;
			return false;
		case 2:
			// The window opened and closed on the server, and the observer saw its tag.
			if (R.Outcomes.Num() < 2 || !R.bObserverSawParrying || ServerHas(R, AethelnGameplayTags::State_Oathscar_Parrying) || R.bObserverHasParrying) { return false; }
			Press(R, AethelnGameplayTags::Ability_Oathscar_AttackStance);
			R.Stage = 3;
			return false;
		case 3:
			if (R.Outcomes.Num() < 3 || R.OwnerStanceEffects != 1 || !R.bObserverHasAttackStance) { return false; }
			Press(R, AethelnGameplayTags::Ability_Oathscar_DefenseStance);
			R.Stage = 4;
			return false;
		case 4:
			if (R.Outcomes.Num() < 4 || R.OwnerStanceEffects != 1 || !R.bObserverHasDefenseStance || R.bObserverHasAttackStance) { return false; }
			R.StageTime = Now;
			R.Stage = 5;
			return false;
		default:
			// Let the unreliable result cues and the last replicated state arrive.
			return Now >= R.StageTime + 1.0;
		}
	}

	void QueueOathscarActivesTwoClient(FAutomationTestBase& Test, const FPacketSimulationSettings* Impairment)
	{
		const TSharedRef<FRun> Run = MakeShared<FRun>(Test);
		AddCqTestPieExpectedMessages(Test);
		FNetworkComponentBuilder<FState> NetworkBuilder;
		NetworkBuilder.WithClients(2).AsDedicatedServer().WithGameMode(AAethelnCombatGameMode::StaticClass());
		if (Impairment != nullptr)
		{
			Run->Packets = *Impairment;
			Run->bImpaired = true;
			NetworkBuilder.WithPacketSimulationSettings(&Run->Packets);
		}
		NetworkBuilder.Build(Run->Network);
		QueueSetup(*Run);
		FRun* R = &Run.Get();
		R->Network.Until(TEXT("Press the four actives in turn"), [R]() { return DriveActives(*R); }, FTimespan::FromSeconds(60.0));
		R->Network
			.ThenServer(TEXT("The owner got every outcome and record; the observer got the phase state, the Parry tag and the stance tag only"), [R](FState& Server)
			{
				FAutomationTestBase& T = R->Test;
				const UAethelnAbilitySystemComponent* Attacker = ServerAbilitySystem(Server, AttackerClient);
				if (!T.TestNotNull(TEXT("The attacker's ASC exists on the server"), Attacker)) { return; }

				// The owner: one accepted outcome per press, in order, and the record and chain end of Instant Strike only.
				if (T.TestEqual(TEXT("The owner received one outcome per press"), R->Outcomes.Num(), PressCount))
				{
					for (int32 Index = 0; Index < PressCount; ++Index)
					{
						T.TestEqual(TEXT("Each press is accepted"), R->Outcomes[Index].Result, EResult::Accepted);
						T.TestEqual(TEXT("Outcomes carry the press sequence"), R->Outcomes[Index].Sequence, static_cast<uint32>(Index + 1));
					}
				}
				if (T.TestEqual(TEXT("The owner received the record of Instant Strike and no other"), R->Records.Num(), 1))
				{
					T.TestTrue(TEXT("The record names Instant Strike"), R->Records[0].AbilityId == AethelnGameplayTags::Ability_Oathscar_InstantStrike);
					T.TestEqual(TEXT("It is the only step"), static_cast<int32>(R->Records[0].ChainStep), 1);
					T.TestTrue(TEXT("The control-rotation aim is a unit vector"), FMath::IsNearlyEqual(R->Records[0].AcceptedAim.Size(), 1.0, 0.01));
					T.TestEqual(TEXT("A press at the controller's rotation is not corrected"), R->Records[0].AimCorrection, EAethelnAimCorrection::None);
				}
				if (T.TestEqual(TEXT("The owner received one chain end"), R->Ends.Num(), 1) && R->Records.Num() == 1)
				{
					T.TestEqual(TEXT("The strike completed"), R->Ends[0].Reason, EAethelnChainEndReason::Completed);
					T.TestEqual(TEXT("The end names the strike's activation"), R->Ends[0].ActivationId, R->Records[0].ActivationId);
				}

				// The server committed once per accepted press: one strike hit, four Endurance spends, one stance effect.
				T.TestEqual(TEXT("The server committed one hit"), R->Results.Num(), 1);
				if (const AAethelnCombatAICharacter* Dummy = R->Dummy.Get())
				{
					T.TestEqual(TEXT("The dummy lost the strike's damage once"), HealthOf(*Dummy), R->DummyStartHealth - GetDefault<UAethelnInstantStrikeTestAbility>()->ProvisionalSteps[0].WroughtDamage);
				}
				T.TestEqual(TEXT("The cost was spent once per press"), R->CostApplications, PressCount);
				T.TestEqual(TEXT("The server holds one stance effect"), StanceEffectCount(*Attacker), 1);
				T.TestEqual(TEXT("It was never more than one"), R->ServerMaxStanceEffects, 1);
				T.TestFalse(TEXT("The server never held both stance tags"), R->bServerBothStances);
				T.TestTrue(TEXT("The server holds the Defense Stance tag"), Attacker->HasMatchingGameplayTag(AethelnGameplayTags::State_Oathscar_DefenseStance));
				T.TestFalse(TEXT("And not the Attack Stance tag"), Attacker->HasMatchingGameplayTag(AethelnGameplayTags::State_Oathscar_AttackStance));
				T.TestFalse(TEXT("The Parry window is closed"), Attacker->HasMatchingGameplayTag(AethelnGameplayTags::State_Oathscar_Parrying));

				// The owner receives its stance effect; it never saw both stances or two effects.
				T.TestEqual(TEXT("The owner holds the one stance effect"), R->OwnerStanceEffects, 1);
				T.TestEqual(TEXT("The owner never held more than one"), R->OwnerMaxStanceEffects, 1);
				T.TestFalse(TEXT("The owner never held both stance tags"), R->bOwnerBothStances);
				T.TestFalse(TEXT("The owner's copy of the phase state never changed (COND_SkipOwner)"), R->bOwnerCopyChanged);

				// The observer: the phase state of the strike, the Parry tag and the stance tags, and nothing owner-only.
				T.TestEqual(TEXT("The observer saw the strike's one step"), R->ObserverSteps.Num(), 1);
				for (const uint8 Step : R->ObserverSteps) { T.TestEqual(TEXT("It was step 1"), static_cast<int32>(Step), 1); }
				T.TestFalse(TEXT("The phase state is inactive at the end"), R->ObserverLast.bActive);
				if (R->Ends.Num() == 1) { T.TestEqual(TEXT("The observer sees why the chain ended"), R->ObserverLast.EndReason, R->Ends[0].Reason); }
				T.TestTrue(TEXT("The observer saw the Parry tag"), R->bObserverSawParrying);
				T.TestTrue(TEXT("The observer saw the Attack Stance tag"), R->bObserverSawAttackStance);
				T.TestTrue(TEXT("The observer holds the Defense Stance tag"), R->bObserverHasDefenseStance);
				T.TestFalse(TEXT("The observer never held both stance tags"), R->bObserverBothStances);
				T.TestEqual(TEXT("The observer never held a stance effect, only the tag"), R->ObserverMaxStanceEffects, 0);
				T.TestEqual(TEXT("The observer received no record, outcome or chain end"), R->ObserverRecords + R->ObserverOutcomes + R->ObserverEnds, 0);

				// The cue is unreliable by design: a clean loopback shows one per hit, an impaired link may drop it.
				if (R->bImpaired)
				{
					for (const int32 Client : { AttackerClient, ObserverClient }) { T.TestTrue(TEXT("A client never sees more cues than hits"), R->Cues[Client] <= R->Results.Num()); }
				}
				else
				{
					for (const int32 Client : { AttackerClient, ObserverClient }) { T.TestEqual(TEXT("A client saw a result cue per hit"), R->Cues[Client], R->Results.Num()); }
				}
				T.AddInfo(FString::Printf(TEXT("presses=%d outcomes=%d records=%d hits=%d cues(A,B)=%d,%d"), PressCount, R->Outcomes.Num(), R->Records.Num(), R->Results.Num(), R->Cues[AttackerClient], R->Cues[ObserverClient]));
			});
		QueueTeardown(Run);
	}
}

// K14. Red-first: SubmitAbilityPress routes the id it is given. With a stub that sends the chain's id whatever it is given, the
// first press starts the three-hit chain instead of the strike, the drive step "Press the four actives in turn" never completes and
// times out, and the run fails there (the record check "The record names Instant Strike" is the line that would flip if it got that far).
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnOathscarActivesTwoClientTest,
	"Aetheln.GameCombat.Net.OathscarActivesTwoClient",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnOathscarActivesTwoClientTest::RunTest(const FString& Parameters)
{
	AethelnTwoClientOathscarTests::QueueOathscarActivesTwoClient(*this, nullptr);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnOathscarActivesTwoClientImpairedTest,
	"Aetheln.GameCombat.Net.OathscarActivesTwoClientImpaired",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnOathscarActivesTwoClientImpairedTest::RunTest(const FString& Parameters)
{
	// Fixture impairment on every driver, both directions, as the A20 impaired run and the #21 P3 impaired run: 100 ms lag each way and
	// 5 % loss. These are test settings, not the #45 network profile. The reliable channel absorbs duplication and reordering before the
	// seam sees a request, so they are the manual C2 steps; the seam's own rows for them are K4, K9 and K12.
	FPacketSimulationSettings Impairment;
	Impairment.PktLag = 100;
	Impairment.PktLoss = 5;
	AethelnTwoClientOathscarTests::QueueOathscarActivesTwoClient(*this, &Impairment);
	return true;
}

#endif
