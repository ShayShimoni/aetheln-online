#if WITH_DEV_AUTOMATION_TESTS && WITH_EDITOR

#include "AethelnCharacterMovementComponent.h"
#include "AethelnCombatGameMode.h"
#include "AethelnMovementTestFloor.h"
#include "AethelnPlayerCharacter.h"
#include "Components/CapsuleComponent.h"
#include "Components/PIENetworkComponent.h"
#include "EngineUtils.h"
#include "Engine/NetConnection.h"
#include "GameFramework/GameStateBase.h"
#include "GameFramework/PlayerController.h"
#include "GameFramework/PlayerState.h"
#include "Misc/AutomationTest.h"

// #17 DoD (docs/movement-poc.md): a PIE session with one DEDICATED server and two clients in this process, on real net
// drivers over loopback (CQTest's FPIENetworkComponent). Client 0 (player A) walks and then sprints forward through the
// real character input entry points (ReceiveMoveInput, ReceiveSprintIntent); it simulates no input device. Client 1
// (player B) only watches. When A has stopped, A's authoritative server pawn, A's own client pawn and B's view of A's pawn
// must agree on position and facing within the stated tolerances, and the server must have granted sprint speed above the
// walk cap. Tolerances are measurement limits, not tuning values:
//  - Position 5 cm (3D). Pawns replicate location to 0.01 cm (APawn sets RoundTwoDecimals), and the owning client is held
//    within about 1.7 cm of the server by MAXPOSITIONERRORSQUARED 3, so 5 cm leaves margin.
//  - Facing 3 degrees. Replicated rotation uses ByteComponents, a byte per axis (about 1.4 degrees per step).
// Everything runs in one process, so the run state below is shared by the server and client worlds.
namespace AethelnTwoClientMovementTests
{
	using FState = FBasePIENetworkComponentState;
	constexpr int32 MoverClient = 0;
	constexpr int32 ObserverClient = 1;
	constexpr double PositionTolerance = 5.0;
	constexpr double FacingToleranceDegrees = 3.0;
	// Test route lengths on the flat fixture floor: walk first, then sprint. Not tuning values.
	constexpr double WalkRoute = 300.0;
	constexpr double SprintRoute = 700.0;
	// The replicated fixture floor sits this far below the spawned pawns' feet, so the pawns settle on it within a fraction of a second.
	constexpr double FloorDrop = 10.0;
	constexpr double ObserverBehind = 400.0;

	/** Owns the builder and the component for the whole latent run; the queued lambdas point into it. */
	struct FRun
	{
		explicit FRun(FAutomationTestBase& InTest) : Test(InTest), Builder(InTest), Network(&InTest, Builder, false) {}

		FAutomationTestBase& Test;
		FTestCommandBuilder Builder;
		FPIENetworkComponent<FState> Network;
		int32 MoverPlayerId = INDEX_NONE;
		int32 ObserverPlayerId = INDEX_NONE;
		double FloorTop = 0.0;
		FVector RouteStart = FVector::ZeroVector;
		FVector RouteDirection = FVector::ForwardVector;
		double ServerWalkPeak = 0.0;
		double ServerSprintPeak = 0.0;
		float UAethelnCharacterMovementComponent::* SprintSpeedMember = nullptr;
		TWeakObjectPtr<AAethelnPlayerCharacter> ServerMover;
		TWeakObjectPtr<AAethelnPlayerCharacter> ServerObserver;
	};

	AAethelnPlayerCharacter* ServerPawn(const FState& Server, int32 ClientIndex)
	{
		const UNetConnection* Connection = Server.ClientConnections.IsValidIndex(ClientIndex) ? Server.ClientConnections[ClientIndex] : nullptr;
		const APlayerController* Controller = Connection != nullptr ? Connection->PlayerController.Get() : nullptr;
		return Controller != nullptr ? Cast<AAethelnPlayerCharacter>(Controller->GetPawn()) : nullptr;
	}

	/** The mover's pawn as one client world received it, matched by the server's player id. */
	AAethelnPlayerCharacter* ClientMover(const FState& Client, int32 PlayerId)
	{
		const AGameStateBase* GameState = Client.World != nullptr ? Client.World->GetGameState() : nullptr;
		if (GameState == nullptr) { return nullptr; }
		for (const APlayerState* PlayerState : GameState->PlayerArray)
		{
			if (PlayerState != nullptr && PlayerState->GetPlayerId() == PlayerId) { return Cast<AAethelnPlayerCharacter>(PlayerState->GetPawn()); }
		}
		return nullptr;
	}

	/** The replicated test floor as one client world received it. */
	bool ClientHasFloor(const FState& Client)
	{
		return Client.World != nullptr && TActorIterator<AAethelnMovementTestFloor>(Client.World);
	}

	bool IsSettled(const AAethelnPlayerCharacter* Pawn)
	{
		return Pawn != nullptr && Pawn->GetCharacterMovement()->IsMovingOnGround() && Pawn->GetVelocity().SizeSquared2D() < 1.0;
	}

	double YawDifference(double A, double B)
	{
		return FMath::Abs(FRotator::NormalizeAxis(A - B));
	}

	/** Position and facing agree with the server's pawn, within the stated tolerances. */
	bool Agrees(const AAethelnPlayerCharacter& Pawn, const AAethelnPlayerCharacter& Server)
	{
		return FVector::Dist(Pawn.GetActorLocation(), Server.GetActorLocation()) <= PositionTolerance
			&& YawDifference(Pawn.GetActorRotation().Yaw, Server.GetActorRotation().Yaw) <= FacingToleranceDegrees;
	}

	double PlanarDistance(const FVector& From, const FVector& To)
	{
		return FVector::Dist2D(From, To);
	}

	/** SprintSpeedMember is a pointer to the protected sprint cap, taken by the friend test class and read here from the live pawn. */
	void QueueTwoClientMovement(FAutomationTestBase& Test, float UAethelnCharacterMovementComponent::* SprintSpeedMember)
	{
		// CQTest plays a new unsaved map, whose level and world settings have no stable package path for the net GUID cache.
		Test.AddExpectedMessage(TEXT("FNetGUIDCache::SupportsObject: Level /Temp/UEDPIE_\\d+_Untitled_\\d+\\.Untitled:PersistentLevel NOT Supported"), ELogVerbosity::Warning,
			EAutomationExpectedMessageFlags::Contains, 0);
		Test.AddExpectedMessage(TEXT("RegisterNetGUID_Client: Guid with pathname\\. FullNetGUIDPath: \\[\\d+\\]WorldSettings"), ELogVerbosity::Warning,
			EAutomationExpectedMessageFlags::Contains, 0);
		const TSharedRef<FRun> Run = MakeShared<FRun>(Test);
		FNetworkComponentBuilder<FState> NetworkBuilder;
		NetworkBuilder.WithClients(2).AsDedicatedServer().WithGameMode(AAethelnCombatGameMode::StaticClass());
		NetworkBuilder.Build(Run->Network);
		// Generous bounds: every wait ends on replicated state, never on a fixed tick.
		const FTimespan Timeout = FTimespan::FromSeconds(30.0);
		FRun* R = &Run.Get();
		R->SprintSpeedMember = SprintSpeedMember;

		Run->Network
			.UntilServer(TEXT("Both players have a character pawn"), [R](FState& Server)
			{
				for (int32 Index : { MoverClient, ObserverClient })
				{
					const AAethelnPlayerCharacter* Pawn = ServerPawn(Server, Index);
					if (Pawn == nullptr || Pawn->GetPlayerState() == nullptr) { return false; }
				}
				R->ServerMover = ServerPawn(Server, MoverClient);
				R->ServerObserver = ServerPawn(Server, ObserverClient);
				R->MoverPlayerId = R->ServerMover->GetPlayerState()->GetPlayerId();
				R->ObserverPlayerId = R->ServerObserver->GetPlayerState()->GetPlayerId();
				return true;
			}, Timeout)
			.ThenServer(TEXT("Build the server's floor under the pawns"), [R](FState& Server)
			{
				double LowestFoot = TNumericLimits<double>::Max();
				for (int32 Index : { MoverClient, ObserverClient })
				{
					const AAethelnPlayerCharacter* Pawn = ServerPawn(Server, Index);
					LowestFoot = FMath::Min(LowestFoot, Pawn->GetActorLocation().Z - Pawn->GetCapsuleComponent()->GetScaledCapsuleHalfHeight());
				}
				R->FloorTop = LowestFoot - FloorDrop;
				Server.World->SpawnActor<AAethelnMovementTestFloor>(FVector(0.0, 0.0, R->FloorTop - 50.0), FRotator::ZeroRotator);
				// Both pawns may spawn on the same spot. B moves 400 cm behind A's start, so the route below (along +Y) leads away from B.
				R->ServerObserver->SetActorLocation(R->ServerMover->GetActorLocation() - FVector(0.0, ObserverBehind, 0.0), false, nullptr, ETeleportType::TeleportPhysics);
			})
			.UntilClients(TEXT("Each client received the floor"), [](FState& Client)
			{
				return ClientHasFloor(Client);
			}, Timeout)
			.UntilServer(TEXT("Both pawns are standing on the floor on the server"), [R](FState& /*Server*/)
			{
				return IsSettled(R->ServerMover.Get()) && IsSettled(R->ServerObserver.Get());
			}, Timeout)
			.UntilClients(TEXT("Each client sees both pawns standing on the floor where the server has them"), [R](FState& Client)
			{
				const AAethelnPlayerCharacter* Mover = ClientMover(Client, R->MoverPlayerId);
				const AAethelnPlayerCharacter* Observer = ClientMover(Client, R->ObserverPlayerId);
				return IsSettled(Mover) && IsSettled(Observer) && R->ServerMover.IsValid() && R->ServerObserver.IsValid()
					&& Agrees(*Mover, *R->ServerMover) && Agrees(*Observer, *R->ServerObserver);
			}, Timeout)
			.ThenClient(TEXT("Point the mover along +Y, a yaw of 90 degrees, so its facing changes from the spawn facing"), MoverClient, [R](FState& Client)
			{
				AAethelnPlayerCharacter* Pawn = ClientMover(Client, R->MoverPlayerId);
				if (!R->Test.TestNotNull(TEXT("The mover's client has its pawn and controller"), Pawn) || Pawn->GetController() == nullptr) { return; }
				R->RouteDirection = FRotator(0.0, 90.0, 0.0).Vector();
				Pawn->GetController()->SetControlRotation(FRotator(0.0, 90.0, 0.0));
				R->RouteStart = Pawn->GetActorLocation();
			})
			.UntilClient(TEXT("The mover walks the walk route"), MoverClient, [R](FState& Client)
			{
				AAethelnPlayerCharacter* Pawn = ClientMover(Client, R->MoverPlayerId);
				if (Pawn == nullptr || !R->ServerMover.IsValid()) { return false; }
				Pawn->ReceiveMoveInput(FVector2D(0.0, 1.0));
				R->ServerWalkPeak = FMath::Max(R->ServerWalkPeak, R->ServerMover->GetVelocity().Size2D());
				return PlanarDistance(Pawn->GetActorLocation(), R->RouteStart) >= WalkRoute;
			}, Timeout)
			.UntilClient(TEXT("The mover sprints the sprint route"), MoverClient, [R](FState& Client)
			{
				AAethelnPlayerCharacter* Pawn = ClientMover(Client, R->MoverPlayerId);
				if (Pawn == nullptr || !R->ServerMover.IsValid()) { return false; }
				Pawn->ReceiveSprintIntent(true);
				Pawn->ReceiveMoveInput(FVector2D(0.0, 1.0));
				R->ServerSprintPeak = FMath::Max(R->ServerSprintPeak, R->ServerMover->GetVelocity().Size2D());
				return PlanarDistance(Pawn->GetActorLocation(), R->RouteStart) >= WalkRoute + SprintRoute;
			}, Timeout)
			.ThenClient(TEXT("The mover lets go of sprint and movement"), MoverClient, [R](FState& Client)
			{
				if (AAethelnPlayerCharacter* Pawn = ClientMover(Client, R->MoverPlayerId)) { Pawn->ReceiveSprintIntent(false); }
			})
			.UntilServer(TEXT("The mover has stopped on the server"), [R](FState& /*Server*/)
			{
				return IsSettled(R->ServerMover.Get());
			}, Timeout)
			.UntilClients(TEXT("Both clients show the mover at the server's resting position and facing"), [R](FState& Client)
			{
				const AAethelnPlayerCharacter* Pawn = ClientMover(Client, R->MoverPlayerId);
				return Pawn != nullptr && R->ServerMover.IsValid() && IsSettled(Pawn) && Agrees(*Pawn, *R->ServerMover);
			}, Timeout)
			.ThenServer(TEXT("Server-side movement checks"), [R](FState& /*Server*/)
			{
				const AAethelnPlayerCharacter* Mover = R->ServerMover.Get();
				if (!R->Test.TestNotNull(TEXT("The server still has the mover"), Mover)) { return; }
				const UCharacterMovementComponent* Movement = Mover->GetCharacterMovement();
				R->Test.TestTrue(TEXT("The server pawn travelled the whole route"), PlanarDistance(Mover->GetActorLocation(), R->RouteStart) >= WalkRoute + SprintRoute - PositionTolerance);
				R->Test.TestTrue(TEXT("Walking never exceeded the walk cap on the server"), R->ServerWalkPeak > 0.0 && R->ServerWalkPeak <= Movement->MaxWalkSpeed + 1.0);
				R->Test.TestTrue(TEXT("The server granted a sprint speed above the walk cap"), R->ServerSprintPeak > Movement->MaxWalkSpeed + 1.0);
				const UAethelnCharacterMovementComponent* AethelnMovement = Cast<UAethelnCharacterMovementComponent>(Movement);
				if (R->Test.TestNotNull(TEXT("The server pawn uses the project movement component"), AethelnMovement))
				{
					R->Test.TestTrue(TEXT("Sprint never exceeded the project's sprint speed"), R->ServerSprintPeak <= AethelnMovement->*R->SprintSpeedMember + 1.0);
				}
				const double Heading = (Mover->GetActorLocation() - R->RouteStart).GetSafeNormal2D().Rotation().Yaw;
				R->Test.TestTrue(TEXT("The server pawn faces the direction it travelled"), YawDifference(Mover->GetActorRotation().Yaw, Heading) <= FacingToleranceDegrees);
				R->Test.TestTrue(TEXT("The route followed the commanded heading"), YawDifference(Heading, R->RouteDirection.Rotation().Yaw) <= FacingToleranceDegrees);
			})
			.ThenClients(TEXT("Both clients' final position and facing"), [R](FState& Client)
			{
				const AAethelnPlayerCharacter* Pawn = ClientMover(Client, R->MoverPlayerId);
				const AAethelnPlayerCharacter* Server = R->ServerMover.Get();
				if (!R->Test.TestNotNull(TEXT("The client has the mover's pawn"), Pawn) || Server == nullptr) { return; }
				const FString Who = Client.ClientIndex == MoverClient ? TEXT("The mover's own client") : TEXT("The observer's client");
				R->Test.TestTrue(*FString::Printf(TEXT("%s is within %.0f cm of the server's position"), *Who, PositionTolerance),
					FVector::Dist(Pawn->GetActorLocation(), Server->GetActorLocation()) <= PositionTolerance);
				R->Test.TestTrue(*FString::Printf(TEXT("%s is within %.0f degrees of the server's facing"), *Who, FacingToleranceDegrees),
					YawDifference(Pawn->GetActorRotation().Yaw, Server->GetActorRotation().Yaw) <= FacingToleranceDegrees);
				R->Test.TestTrue(*FString::Printf(TEXT("%s saw the mover end far from its start"), *Who),
					PlanarDistance(Pawn->GetActorLocation(), R->RouteStart) >= WalkRoute + SprintRoute - PositionTolerance);
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
			if (!bPieEnded) { Run->Test.AddError(FString::Printf(TEXT("%s: PIE did not end within 30 s after the teardown"), *Run->Test.GetTestFullName())); }
			return true;
		}));
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnTwoClientMovementTest,
	"Aetheln.Movement.Net.TwoClientMoveAndSprint",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnTwoClientMovementTest::RunTest(const FString& Parameters)
{
	AethelnTwoClientMovementTests::QueueTwoClientMovement(*this, &UAethelnCharacterMovementComponent::SprintSpeed);
	return true;
}

#endif
