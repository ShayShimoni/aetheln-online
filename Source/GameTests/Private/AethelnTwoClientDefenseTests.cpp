#if WITH_DEV_AUTOMATION_TESTS && WITH_EDITOR

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCharacterMovementComponent.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatEffects.h"
#include "AethelnCombatGameMode.h"
#include "AethelnCombatTestWorld.h"
#include "AethelnDefenseTestFixture.h"
#include "AethelnGameplayTags.h"
#include "AethelnMovementTestFloor.h"
#include "AethelnPOCInputComponent.h"
#include "AethelnPlayerCharacter.h"
#include "AethelnPlayerState.h"
#include "Components/CapsuleComponent.h"
#include "Components/PIENetworkComponent.h"
#include "Engine/NetConnection.h"
#include "EngineUtils.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "GameFramework/GameStateBase.h"
#include "GameFramework/PlayerController.h"
#include "Misc/AutomationTest.h"

// #18 P5, Test Plan D27 (docs/dodge-and-block.md). A PIE session with one dedicated server and two clients in this process, on real net
// drivers over loopback (CQTest's FPIENetworkComponent), as the K14 test of #260 P5 (AethelnTwoClientOathscarTests.cpp). The owner presses
// the block and releases it through the same GameUI entries the right mouse button uses (SubmitAbilityPress and SubmitAbilityRelease ->
// IAethelnCombatInputSink -> the ASC's activation request), then raises it again and dodges through the pawn's receiver
// (ReceiveDodgePressed, which the dodge key calls), so the movement flag, the local gate, the server's received-move authority and the
// owner RPCs are the engine's own. It simulates no input device and no separate process. The dodge and block are the Editor-module fixture
// classes (AethelnDefenseTestFixture.h, AethelnDodgeTestAbility.h): the production classes stay ungranted until their values exist
// (#107), and every value here is a fixture value, never tuning. This run is the clean link (C1). The impaired kinds (C2), the refused
// dodge's correction rate and the contact cues are the manual steps in the document.
namespace AethelnTwoClientDefenseTests
{
	using FState = FBasePIENetworkComponentState;
	using EResult = EAethelnActivationResult;
	constexpr int32 OwnerClient = 0;
	constexpr int32 ObserverClient = 1;
	// Measurement limits, as in the two-client movement test: positions replicate to 0.01 cm and the owner is held within about 1.7 cm.
	constexpr double PositionTolerance = 5.0;
	// The replicated fixture floor sits this far below the spawned pawns' feet, so they settle on it within a fraction of a second.
	constexpr double FloorDrop = 10.0;
	constexpr double ObserverAhead = 400.0;

	/** Owns the builder and the component for the whole latent run; the queued lambdas point into it. */
	struct FRun
	{
		explicit FRun(FAutomationTestBase& InTest) : Test(InTest), Builder(InTest), Network(&InTest, Builder, false) {}

		FAutomationTestBase& Test;
		FTestCommandBuilder Builder;
		FPIENetworkComponent<FState> Network;
		FState* Server = nullptr;
		FState* Clients[2] = {};
		int32 PlayerId[2] = { INDEX_NONE, INDEX_NONE };
		TWeakObjectPtr<AAethelnPlayerCharacter> ServerOwnerPawn;
		TWeakObjectPtr<AAethelnPlayerCharacter> ServerObserverPawn;
		bool bClientBound[2] = {};
		FVector DodgeStart = FVector::ZeroVector;

		// The owner's own client: what the owner RPCs delivered.
		TArray<EResult> Outcomes;
		TArray<EResult> MoveOutcomes;
		// The observer's client: its copy of the owner's ASC. Owner RPCs never reach it.
		int32 ObserverOwnerRpcs = 0;

		// Tags the server and each client copy of the owner's ASC held at any poll.
		bool bServerSawDodging = false;
		bool bOwnerSawBlocking = false;
		bool bOwnerSawDodging = false;
		bool bObserverSawBlocking = false;
		bool bObserverSawDodging = false;

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

	AAethelnPlayerCharacter* ServerPawn(const FState& Server, int32 ClientIndex)
	{
		const UNetConnection* Connection = Server.ClientConnections.IsValidIndex(ClientIndex) ? Server.ClientConnections[ClientIndex] : nullptr;
		const APlayerController* Controller = Connection != nullptr ? Connection->PlayerController.Get() : nullptr;
		return Controller != nullptr ? Cast<AAethelnPlayerCharacter>(Controller->GetPawn()) : nullptr;
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

	AAethelnPlayerCharacter* ClientPawn(const FState& Client, int32 PlayerId)
	{
		const AAethelnPlayerState* PlayerState = ClientPlayerState(Client, PlayerId);
		return PlayerState != nullptr ? Cast<AAethelnPlayerCharacter>(PlayerState->GetPawn()) : nullptr;
	}

	bool IsSettled(const AAethelnPlayerCharacter* Pawn)
	{
		return Pawn != nullptr && Pawn->GetCharacterMovement()->IsMovingOnGround() && Pawn->GetVelocity().SizeSquared2D() < 1.0;
	}

	bool HasFloor(const FState& Client)
	{
		return Client.World != nullptr && TActorIterator<AAethelnMovementTestFloor>(Client.World);
	}

	/** True once both fixture abilities are granted on this ASC copy (only the owner receives its ability specs). */
	bool HasBothAbilities(const UAethelnAbilitySystemComponent& AbilitySystem)
	{
		int32 Found = 0;
		for (const FGameplayAbilitySpec& Spec : AbilitySystem.GetActivatableAbilities())
		{
			Found += Spec.Ability != nullptr && (Spec.Ability->IsA<UAethelnBlockTestAbility>() || Spec.Ability->IsA<UAethelnDodgeTestAbility>());
		}
		return Found == 2;
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

	/** The server's fixture state for one player: attribute values, and for the owner the two abilities, the aim and time bounds and a rate bucket that never limits. */
	void SetUpPlayer(FRun& R, FState& Server, int32 Index)
	{
		UAethelnAbilitySystemComponent* AbilitySystem = ServerAbilitySystem(Server, Index);
		if (!R.Test.TestNotNull(TEXT("The player has an ASC"), AbilitySystem)) { return; }
		R.PlayerId[Index] = CastChecked<APlayerState>(AbilitySystem->GetOwner())->GetPlayerId();
		UAethelnAttributeInitEffect::ApplyTo(*AbilitySystem, AethelnCombatTests::MakeTestInitValues());
		if (Index != OwnerClient) { return; }
		AethelnCombatTests::SetTestAimTimeBounds(*AbilitySystem);
		AbilitySystem->ProvisionalAimMaxRateDegreesPerSecond = 1000.0f;
		AbilitySystem->ProvisionalActivationBucketCapacity = 1000.0f;
		AbilitySystem->ProvisionalActivationBucketRefillPerSecond = 0.0f;
		for (UClass* Class : { UAethelnBlockTestAbility::StaticClass(), UAethelnDodgeTestAbility::StaticClass() })
		{
			AbilitySystem->GiveAbility(FGameplayAbilitySpec(Class, 1));
		}
	}

	/** Prepares the server, builds the floor, and waits for both clients to see both players, the floor and (the owner) the abilities, standing where the server has them. */
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
					const AAethelnPlayerCharacter* Pawn = ServerPawn(Server, Index);
					if (AbilitySystem == nullptr || AbilitySystem->GetAvatarActor() == nullptr || Pawn == nullptr) { return false; }
				}
				Run->ServerOwnerPawn = ServerPawn(Server, OwnerClient);
				Run->ServerObserverPawn = ServerPawn(Server, ObserverClient);
				return true;
			}, Timeout)
			.ThenServer(TEXT("Prepare both players and build the floor under them"), [Run](FState& Server)
			{
				for (int32 Index = 0; Index < 2; ++Index) { SetUpPlayer(*Run, Server, Index); }
				double LowestFoot = TNumericLimits<double>::Max();
				for (const AAethelnPlayerCharacter* Pawn : { Run->ServerOwnerPawn.Get(), Run->ServerObserverPawn.Get() })
				{
					if (Pawn != nullptr) { LowestFoot = FMath::Min(LowestFoot, Pawn->GetActorLocation().Z - Pawn->GetCapsuleComponent()->GetScaledCapsuleHalfHeight()); }
				}
				const double FloorTop = LowestFoot - FloorDrop;
				Server.World->SpawnActor<AAethelnMovementTestFloor>(FVector(0.0, 0.0, FloorTop - 50.0), FRotator::ZeroRotator);
				// Both pawns may spawn on the same spot: the observer stands ahead of the owner, away from the dodge's path.
				if (AAethelnPlayerCharacter* Observer = Run->ServerObserverPawn.Get())
				{
					Observer->SetActorLocation(Run->ServerOwnerPawn->GetActorLocation() + FVector(ObserverAhead, 0.0, 0.0), false, nullptr, ETeleportType::TeleportPhysics);
				}
			})
			.UntilClients(TEXT("Every client received the players, the floor and (the owner) both abilities"), [Run](FState& Client)
			{
				Run->Clients[Client.ClientIndex] = &Client;
				if (!HasFloor(Client)) { return false; }
				for (int32 Index = 0; Index < 2; ++Index)
				{
					const AAethelnPlayerState* PlayerState = ClientPlayerState(Client, Run->PlayerId[Index]);
					if (PlayerState == nullptr || PlayerState->GetPawn() == nullptr) { return false; }
				}
				AAethelnPlayerState* OwnerState = ClientPlayerState(Client, Run->PlayerId[OwnerClient]);
				if (Client.ClientIndex == OwnerClient && !HasBothAbilities(*OwnerState->GetAethelnAbilitySystemComponent())) { return false; }
				if (Run->bClientBound[Client.ClientIndex]) { return true; }
				Run->bClientBound[Client.ClientIndex] = true;
				UAethelnAbilitySystemComponent* Owner = OwnerState->GetAethelnAbilitySystemComponent();
				if (Client.ClientIndex == OwnerClient)
				{
					Owner->OnActivationOutcome.AddLambda([Run](uint32, EResult Result) { Run->Outcomes.Add(Result); });
					Owner->OnMovementActivationOutcome.AddLambda([Run](float, EResult Result) { Run->MoveOutcomes.Add(Result); });
				}
				else
				{
					Owner->OnActivationOutcome.AddLambda([Run](uint32, EResult) { ++Run->ObserverOwnerRpcs; });
					Owner->OnMovementActivationOutcome.AddLambda([Run](float, EResult) { ++Run->ObserverOwnerRpcs; });
					Owner->OnCombatActivation.AddLambda([Run](const FAethelnCombatActivationRecord&) { ++Run->ObserverOwnerRpcs; });
					Owner->OnChainEnded.AddLambda([Run](const FGuid&, EAethelnChainEndReason) { ++Run->ObserverOwnerRpcs; });
				}
				return true;
			}, Timeout)
			.UntilServer(TEXT("Both pawns are standing on the floor on the server"), [Run](FState& /*Server*/)
			{
				return IsSettled(Run->ServerOwnerPawn.Get()) && IsSettled(Run->ServerObserverPawn.Get());
			}, Timeout)
			.UntilClients(TEXT("Each client sees both pawns standing where the server has them"), [Run](FState& Client)
			{
				for (int32 Index = 0; Index < 2; ++Index)
				{
					const AAethelnPlayerCharacter* Pawn = ClientPawn(Client, Run->PlayerId[Index]);
					const AAethelnPlayerCharacter* Server = Index == OwnerClient ? Run->ServerOwnerPawn.Get() : Run->ServerObserverPawn.Get();
					if (!IsSettled(Pawn) || Server == nullptr || FVector::Dist(Pawn->GetActorLocation(), Server->GetActorLocation()) > PositionTolerance) { return false; }
				}
				return true;
			}, Timeout);
	}

	bool ServerHas(const FRun& R, const FGameplayTag& Tag)
	{
		const UAethelnAbilitySystemComponent* AbilitySystem = ServerAbilitySystem(*R.Server, OwnerClient);
		return AbilitySystem != nullptr && AbilitySystem->HasMatchingGameplayTag(Tag);
	}

	bool ClientHas(const FRun& R, int32 ClientIndex, const FGameplayTag& Tag)
	{
		const AAethelnPlayerState* PlayerState = ClientPlayerState(*R.Clients[ClientIndex], R.PlayerId[OwnerClient]);
		return PlayerState != nullptr && PlayerState->GetAethelnAbilitySystemComponent()->HasMatchingGameplayTag(Tag);
	}

	/** Polls what each side holds, every frame: the dodge window and the block are short enough to miss between two checks. */
	void Poll(FRun& R)
	{
		R.bServerSawDodging |= ServerHas(R, AethelnGameplayTags::State_Dodging);
		R.bOwnerSawBlocking |= ClientHas(R, OwnerClient, AethelnGameplayTags::State_Blocking);
		R.bOwnerSawDodging |= ClientHas(R, OwnerClient, AethelnGameplayTags::State_Dodging);
		R.bObserverSawBlocking |= ClientHas(R, ObserverClient, AethelnGameplayTags::State_Blocking);
		R.bObserverSawDodging |= ClientHas(R, ObserverClient, AethelnGameplayTags::State_Dodging);
	}

	APlayerController* OwnerController(const FRun& R) { return R.Clients[OwnerClient]->World->GetFirstPlayerController(); }

	/**
	 * Raise the block and lower it (both accepted); let the block's cooldown end; raise it again, and dodge while it is held: the accepted
	 * dodge ends the block (Q10), and the release that follows is the benign ActivationBlocked of a block that is already down.
	 */
	bool Drive(FRun& R)
	{
		Poll(R);
		const double Now = FPlatformTime::Seconds();
		switch (R.Stage)
		{
		case 0:
			R.Test.TestTrue(TEXT("The press reaches the local player's PlayerState through the GameUI entry"), SubmitAbilityPress(OwnerController(R), AethelnGameplayTags::Ability_Block));
			R.Stage = 1;
			return false;
		case 1:
			if (R.Outcomes.Num() < 1 || !ServerHas(R, AethelnGameplayTags::State_Blocking) || !ClientHas(R, ObserverClient, AethelnGameplayTags::State_Blocking)
				|| !ClientHas(R, OwnerClient, AethelnGameplayTags::State_Blocking)) { return false; }
			R.Test.TestTrue(TEXT("The release reaches the local player's PlayerState through the GameUI entry"), SubmitAbilityRelease(OwnerController(R), AethelnGameplayTags::Ability_Block));
			R.Stage = 2;
			return false;
		case 2:
			if (R.Outcomes.Num() < 2 || ServerHas(R, AethelnGameplayTags::State_Blocking) || ClientHas(R, ObserverClient, AethelnGameplayTags::State_Blocking)
				|| ClientHas(R, OwnerClient, AethelnGameplayTags::State_Blocking) || ServerHas(R, AethelnGameplayTags::Cooldown_Block)) { return false; }
			SubmitAbilityPress(OwnerController(R), AethelnGameplayTags::Ability_Block);
			R.Stage = 3;
			return false;
		case 3:
		{
			// The block is held on the server and on both clients; the owner dodges through the receiver, as the dodge key does.
			AAethelnPlayerCharacter* Pawn = ClientPawn(*R.Clients[OwnerClient], R.PlayerId[OwnerClient]);
			if (R.Outcomes.Num() < 3 || !ServerHas(R, AethelnGameplayTags::State_Blocking) || !ClientHas(R, ObserverClient, AethelnGameplayTags::State_Blocking)
				|| Pawn == nullptr || !IsSettled(Pawn)
				|| !Pawn->GetPlayerState<AAethelnPlayerState>()->CanPredictDodge()) { return false; }
			R.DodgeStart = R.ServerOwnerPawn->GetActorLocation();
			Pawn->ReceiveDodgePressed();
			R.Stage = 4;
			return false;
		}
		case 4:
		{
			// The server's window opened and closed, the block ended with the accepted dodge, the displacement is over, and both clients saw the tags.
			const AAethelnPlayerCharacter* Mover = R.ServerOwnerPawn.Get();
			const UAethelnCharacterMovementComponent* Movement = Mover != nullptr ? Cast<UAethelnCharacterMovementComponent>(Mover->GetCharacterMovement()) : nullptr;
			if (R.MoveOutcomes.Num() < 1 || !R.bServerSawDodging || ServerHas(R, AethelnGameplayTags::State_Dodging) || ServerHas(R, AethelnGameplayTags::State_Blocking)
				|| !R.bOwnerSawDodging || !R.bObserverSawDodging || Movement == nullptr || Movement->GetDodgeState().bInProgress) { return false; }
			SubmitAbilityRelease(OwnerController(R), AethelnGameplayTags::Ability_Block);
			R.Stage = 5;
			return false;
		}
		case 5:
			if (R.Outcomes.Num() < 4) { return false; }
			R.StageTime = Now;
			R.Stage = 6;
			return false;
		default:
			// Let the last replicated state and the final positions arrive.
			return Now >= R.StageTime + 1.0;
		}
	}

	void QueueDodgeAndBlockTwoClient(FAutomationTestBase& Test)
	{
		const TSharedRef<FRun> Run = MakeShared<FRun>(Test);
		AddCqTestPieExpectedMessages(Test);
		FNetworkComponentBuilder<FState> NetworkBuilder;
		NetworkBuilder.WithClients(2).AsDedicatedServer().WithGameMode(AAethelnCombatGameMode::StaticClass());
		NetworkBuilder.Build(Run->Network);
		QueueSetup(*Run);
		FRun* R = &Run.Get();
		R->Network.Until(TEXT("Block, release, block, and dodge while blocking"), [R]() { return Drive(*R); }, FTimespan::FromSeconds(60.0));
		R->Network
			.UntilServer(TEXT("The owner's pawn has stopped on the server"), [R](FState& /*Server*/) { return IsSettled(R->ServerOwnerPawn.Get()); }, FTimespan::FromSeconds(30.0))
			.UntilClients(TEXT("Both clients show the owner's pawn at the server's resting position"), [R](FState& Client)
			{
				const AAethelnPlayerCharacter* Pawn = ClientPawn(Client, R->PlayerId[OwnerClient]);
				return Pawn != nullptr && R->ServerOwnerPawn.IsValid() && IsSettled(Pawn) && FVector::Dist(Pawn->GetActorLocation(), R->ServerOwnerPawn->GetActorLocation()) <= PositionTolerance;
			}, FTimespan::FromSeconds(30.0))
			.ThenServer(TEXT("The owner got every outcome; the observer saw the tags only; the dodge covered its distance once"), [R](FState& Server)
			{
				FAutomationTestBase& T = R->Test;
				const UAethelnAbilitySystemComponent* Owner = ServerAbilitySystem(Server, OwnerClient);
				const AAethelnPlayerCharacter* Mover = R->ServerOwnerPawn.Get();
				if (!T.TestNotNull(TEXT("The owner's ASC exists on the server"), Owner) || !T.TestNotNull(TEXT("The owner's pawn exists on the server"), Mover)) { return; }

				// The owner: one outcome per request, in order (press, release, press, then the benign refusal of the last release),
				// and one movement outcome for the one flagged move.
				if (T.TestEqual(TEXT("The owner received one outcome per block request"), R->Outcomes.Num(), 4))
				{
					T.TestEqual(TEXT("The first press is accepted"), R->Outcomes[0], EResult::Accepted);
					T.TestEqual(TEXT("The release is accepted"), R->Outcomes[1], EResult::Accepted);
					T.TestEqual(TEXT("The second press is accepted"), R->Outcomes[2], EResult::Accepted);
					T.TestEqual(TEXT("A release after the dodge ended the block is refused as already lowered"), R->Outcomes[3], EResult::ActivationBlocked);
				}
				if (T.TestEqual(TEXT("The owner received one movement outcome"), R->MoveOutcomes.Num(), 1)) { T.TestEqual(TEXT("The dodge is accepted"), R->MoveOutcomes[0], EResult::Accepted); }

				// The server: nothing is left standing, and the dodge ended the block.
				T.TestFalse(TEXT("The server holds no block"), Owner->HasMatchingGameplayTag(AethelnGameplayTags::State_Blocking));
				T.TestFalse(TEXT("The server's dodge window is closed"), Owner->HasMatchingGameplayTag(AethelnGameplayTags::State_Dodging));
				const double Travelled = FVector::Dist2D(Mover->GetActorLocation(), R->DodgeStart);
				const double Distance = GetDefault<UAethelnDodgeTestAbility>()->ProvisionalDodge.Distance;
				T.TestTrue(TEXT("The server pawn dodged the authored distance, once"), FMath::Abs(Travelled - Distance) <= PositionTolerance);

				// The observer: both tags, and nothing owner-only.
				T.TestTrue(TEXT("The observer saw the block"), R->bObserverSawBlocking);
				T.TestTrue(TEXT("The observer saw the dodge"), R->bObserverSawDodging);
				T.TestEqual(TEXT("The observer received no outcome, record or chain end"), R->ObserverOwnerRpcs, 0);
				T.TestTrue(TEXT("The owner saw its own block and dodge tags"), R->bOwnerSawBlocking && R->bOwnerSawDodging);
				T.AddInfo(FString::Printf(TEXT("outcomes=%d moveOutcomes=%d travelled=%.2f authored=%.2f"), R->Outcomes.Num(), R->MoveOutcomes.Num(), Travelled, Distance));
			})
			.ThenClients(TEXT("Both clients' final position agrees with the server's"), [R](FState& Client)
			{
				const AAethelnPlayerCharacter* Pawn = ClientPawn(Client, R->PlayerId[OwnerClient]);
				const AAethelnPlayerCharacter* Server = R->ServerOwnerPawn.Get();
				if (!R->Test.TestNotNull(TEXT("The client has the owner's pawn"), Pawn) || Server == nullptr) { return; }
				const FString Who = Client.ClientIndex == OwnerClient ? TEXT("The owner's own client") : TEXT("The observer's client");
				R->Test.TestTrue(*FString::Printf(TEXT("%s is within %.0f cm of the server's position"), *Who, PositionTolerance),
					FVector::Dist(Pawn->GetActorLocation(), Server->GetActorLocation()) <= PositionTolerance);
				R->Test.TestTrue(*FString::Printf(TEXT("%s saw the pawn dodge the authored distance"), *Who),
					FMath::Abs(FVector::Dist2D(Pawn->GetActorLocation(), R->DodgeStart) - GetDefault<UAethelnDodgeTestAbility>()->ProvisionalDodge.Distance) <= PositionTolerance);
			});
		QueueTeardown(Run);
	}
}

// D27. Red-first: with SubmitAbilityRelease sending nothing, the second stage never completes ("Block, release, block, and dodge while
// blocking" times out at stage 2, the owner never receiving its second outcome); with the dodge sent as a seam press instead of the
// movement flag, the server answers MalformedRequest and "The dodge is accepted" is the line that flips.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDodgeAndBlockTwoClientsTest,
	"Aetheln.GameCombat.Net.DodgeAndBlockTwoClients",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDodgeAndBlockTwoClientsTest::RunTest(const FString& Parameters)
{
	AethelnTwoClientDefenseTests::QueueDodgeAndBlockTwoClient(*this);
	return true;
}

#endif
