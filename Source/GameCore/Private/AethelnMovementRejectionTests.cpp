#include "AethelnCharacterMovementComponent.h"
#include "AethelnMovementLoopbackHarness.h"

#if WITH_DEV_AUTOMATION_TESTS

/*
 * #17 AC4 server rejections that need a hostile client: a claimed movement mode, a stale
 * timestamp, an over-limit acceleration and a large displacement. They run on the dodge
 * loopback harness, so every move goes through the engine's real saved-move capture, packed
 * serialization, received-move handler and response. The hostile input differs per test:
 * the mode and acceleration tests rewrite the client's saved move right before the engine
 * packs it, the stale test replays earlier honest packets after newer ones, and the
 * displacement test moves the client and then predicts normally. All four go through the
 * real packed path.
 * They describe engine behavior; none adds or changes a threshold. Time-discrepancy
 * detection stays off and its thresholds stay TBD (#2/#45).
 */
namespace AethelnMovementRejectionTests
{
	using AethelnDodgeTests::FLoopback;
	using AethelnDodgeTests::PositionTolerance;
	using FMoveClaim = TFunction<void(FSavedMove_Character&)>;

	/** Predicts one move and lets Claim rewrite the saved move right before the engine packs it. */
	void PredictClaiming(FLoopback& Pair, const FMoveClaim& Claim, const FVector& Acceleration = FVector::ZeroVector)
	{
		const TFunction<void(const FSavedMove_Character*, const FSavedMove_Character*, const FSavedMove_Character*)> Original =
			Pair.ClientMovement->TestMoveCapture;
		Pair.ClientMovement->TestMoveCapture =
			[Original, &Claim](const FSavedMove_Character* New, const FSavedMove_Character* Pending, const FSavedMove_Character* Old)
		{
			Claim(*const_cast<FSavedMove_Character*>(New));
			Original(New, Pending, Old);
		};
		Pair.Predict(Acceleration);
		Pair.ClientMovement->TestMoveCapture = Original;
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnMovementRejectClientModeMismatchTest,
	"Aetheln.Movement.Net.Reject.ClientModeMismatch", EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementRejectClientModeMismatchTest::RunTest(const FString& Parameters)
{
	using namespace AethelnMovementRejectionTests;
	FLoopback Pair;
	TestTrue(TEXT("Loopback roles and acknowledgement are valid"), Pair.IsValid());
	if (!Pair.IsValid()) { return false; }

	Pair.Predict();
	TestTrue(TEXT("Honest warm move is simulated and acknowledged"), Pair.Packets.Num() == 1 && Pair.Deliver(Pair.Packets.Last()));
	TestEqual(TEXT("Positive control: an honest move is not corrected"), Pair.CorrectionCount, 0);

	const uint8 Claimed = static_cast<uint8>(MOVE_Flying);
	TestNotEqual(TEXT("Fixture: the claimed mode differs from the server's"), Claimed, Pair.ServerMovement->PackNetworkMovementMode());
	bool bClaimed = false;
	PredictClaiming(Pair, [Claimed, &bClaimed](FSavedMove_Character& Move)
	{
		Move.EndPackedMovementMode = Claimed;
		bClaimed = true;
	});
	TestTrue(TEXT("The claim was written into the packed move"), bClaimed);
	TestEqual(TEXT("Hostile move was captured"), Pair.Packets.Num(), 2);
	if (Pair.Packets.Num() != 2) { return false; }
	TestTrue(TEXT("Hostile move goes through the real received-move handler"), Pair.Deliver(Pair.Packets.Last()));
	TestEqual(TEXT("Server corrects the claimed mode"), Pair.CorrectionCount, 1);
	TestEqual(TEXT("Server keeps its own movement mode"), Pair.ServerMovement->MovementMode.GetValue(), MOVE_Walking);
	TestTrue(TEXT("All move and response packing succeeded"), Pair.bSerializationSucceeded);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnMovementRejectStaleTimestampTest,
	"Aetheln.Movement.Net.Reject.StaleTimestamp", EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementRejectStaleTimestampTest::RunTest(const FString& Parameters)
{
	using namespace AethelnMovementRejectionTests;
	FLoopback Pair;
	TestTrue(TEXT("Loopback roles and acknowledgement are valid"), Pair.IsValid());
	if (!Pair.IsValid()) { return false; }

	const FVector Acceleration = FVector::ForwardVector * Pair.ClientMovement->GetMaxAcceleration();
	Pair.Predict();
	Pair.Deliver(Pair.Packets.Last());
	Pair.Predict(Acceleration);
	Pair.Deliver(Pair.Packets.Last());
	Pair.Predict(Acceleration);
	Pair.Deliver(Pair.Packets.Last());
	TestEqual(TEXT("Three moves captured"), Pair.Packets.Num(), 3);
	if (Pair.Packets.Num() != 3) { return false; }
	TestEqual(TEXT("Positive control: all three in-order moves simulate"), Pair.ServerMovement->TestReceivedMoveCount, 3);

	FNetworkPredictionData_Server_Character* ServerData = Pair.ServerMovement->GetPredictionData_Server_Character();
	const float CurrentStamp = ServerData->CurrentClientTimeStamp;
	const FVector Location = Pair.Server->GetActorLocation();
	const FVector Velocity = Pair.ServerMovement->Velocity;
	TestTrue(TEXT("Fixture: the server has moved, so a stale replay would be visible"), Velocity.Size2D() > 1.0f);

	for (int32 Index = 0; Index < 2; ++Index)
	{
		const AethelnDodgeTests::FPacket& Stale = Pair.Packets[Index];
		TestTrue(TEXT("Fixture: the packet is older than the server's newest move"), Stale.NewTimeStamp < CurrentStamp);
		TestTrue(TEXT("Stale packet decodes and reaches the timestamp verifier"), Pair.Deliver(Stale, false));
		TestEqual(TEXT("Verifier saw the stale timestamp"), ServerData->LastReceivedClientTimeStamp, Stale.NewTimeStamp);
		TestEqual(TEXT("Stale move simulates nothing"), Pair.ServerMovement->TestReceivedMoveCount, 3);
		TestEqual(TEXT("Stale move does not rewind the server's client timestamp"), ServerData->CurrentClientTimeStamp, CurrentStamp);
		TestTrue(TEXT("Stale move does not change the server location"), Pair.Server->GetActorLocation().Equals(Location, UE_KINDA_SMALL_NUMBER));
		TestTrue(TEXT("Stale move does not change the server velocity"), Pair.ServerMovement->Velocity.Equals(Velocity, UE_KINDA_SMALL_NUMBER));
	}
	TestTrue(TEXT("All move and response packing succeeded"), Pair.bSerializationSucceeded);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnMovementRejectAccelerationOverLimitTest,
	"Aetheln.Movement.Net.Reject.AccelerationOverLimit", EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementRejectAccelerationOverLimitTest::RunTest(const FString& Parameters)
{
	using namespace AethelnMovementRejectionTests;
	FLoopback Pair;
	TestTrue(TEXT("Loopback roles and acknowledgement are valid"), Pair.IsValid());
	if (!Pair.IsValid()) { return false; }

	Pair.Predict();
	TestTrue(TEXT("Honest warm move is simulated and acknowledged"), Pair.Packets.Num() == 1 && Pair.Deliver(Pair.Packets.Last()));
	TestEqual(TEXT("Positive control: an honest move is not corrected"), Pair.CorrectionCount, 0);

	// The client simulates the honest limit but packs a much larger claim from rest.
	const float Limit = Pair.ClientMovement->GetMaxAcceleration();
	const FVector Honest = FVector::ForwardVector * Limit;
	const FVector Claimed = Honest * 20.0f;
	bool bClaimed = false;
	PredictClaiming(Pair, [Claimed, &bClaimed](FSavedMove_Character& Move)
	{
		Move.Acceleration = Claimed;
		bClaimed = true;
	}, Honest);
	TestTrue(TEXT("The over-limit claim was written into the packed move"), bClaimed);
	TestEqual(TEXT("Hostile move was captured"), Pair.Packets.Num(), 2);
	if (Pair.Packets.Num() != 2) { return false; }
	const float ClientSpeed = static_cast<float>(Pair.ClientMovement->Velocity.Size2D());
	TestTrue(TEXT("Fixture: an unclamped claim would reach a different speed than the honest move"),
		ClientSpeed > 1.0f && Pair.ServerMovement->MaxWalkSpeed > ClientSpeed + 1.0f);
	TestTrue(TEXT("Hostile move goes through the real received-move handler"), Pair.Deliver(Pair.Packets.Last()));
	TestEqual(TEXT("Positive control: the hostile move simulated"), Pair.ServerMovement->TestReceivedMoveCount, 2);
	TestTrue(TEXT("Server simulates the claim clamped to the acceleration limit"),
		Pair.ServerMovement->GetCurrentAcceleration().Size() <= Limit + UE_KINDA_SMALL_NUMBER);
	TestTrue(TEXT("Server speed equals the honest limit speed"),
		FMath::IsNearlyEqual(static_cast<float>(Pair.ServerMovement->Velocity.Size2D()), ClientSpeed, 0.5f));
	TestEqual(TEXT("The clamped claim needs no correction"), Pair.CorrectionCount, 0);
	TestTrue(TEXT("Server and client positions agree"), Pair.Client->GetActorLocation().Equals(Pair.Server->GetActorLocation(), PositionTolerance));
	TestTrue(TEXT("All move and response packing succeeded"), Pair.bSerializationSucceeded);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnMovementRejectDisplacementTeleportTest,
	"Aetheln.Movement.Net.Reject.DisplacementTeleport", EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMovementRejectDisplacementTeleportTest::RunTest(const FString& Parameters)
{
	using namespace AethelnMovementRejectionTests;
	FLoopback Pair;
	TestTrue(TEXT("Loopback roles and acknowledgement are valid"), Pair.IsValid());
	if (!Pair.IsValid()) { return false; }

	Pair.Predict();
	TestTrue(TEXT("Honest warm move is simulated and acknowledged"), Pair.Packets.Num() == 1 && Pair.Deliver(Pair.Packets.Last()));
	TestEqual(TEXT("Positive control: an honest move is not corrected"), Pair.CorrectionCount, 0);

	// An arbitrary test distance, far beyond the engine position-error and large-correction limits.
	// It stays inside the harness floor (10000 cm half extent); farther out the client would fall,
	// and the correction would also be a mode mismatch.
	const FVector ServerBefore = Pair.Server->GetActorLocation();
	const FVector Target = ServerBefore + FVector(5000.0f, 0.0f, 0.0f);
	Pair.Client->SetActorLocation(Target, false, nullptr, ETeleportType::TeleportPhysics);
	Pair.Predict();
	TestEqual(TEXT("Teleported move was captured"), Pair.Packets.Num(), 2);
	if (Pair.Packets.Num() != 2) { return false; }
	TestTrue(TEXT("Fixture: the client really reports a far location"), FVector::Dist2D(Pair.Client->GetActorLocation(), ServerBefore) > 4000.0f);
	TestTrue(TEXT("Teleported move goes through the real received-move handler"), Pair.Deliver(Pair.Packets.Last()));
	TestEqual(TEXT("Server corrects the displacement"), Pair.CorrectionCount, 1);
	TestTrue(TEXT("Server does not adopt the claimed location"), Pair.Server->GetActorLocation().Equals(ServerBefore, PositionTolerance));
	TestTrue(TEXT("Client is returned to the server location"), Pair.Client->GetActorLocation().Equals(Pair.Server->GetActorLocation(), PositionTolerance));
	TestTrue(TEXT("All move and response packing succeeded"), Pair.bSerializationSucceeded);
	return true;
}

#endif
