#include "AethelnNetworkProfile.h"
#include "AethelnNetworkSpikeEvidence.h"
#include "AethelnReplicationCandidate.h"

#if WITH_DEV_AUTOMATION_TESTS
#include "Misc/AutomationTest.h"

namespace
{
	const FAethelnScenarioCapability* FindCapability(
		const FAethelnNetworkSpikeActorMix& ActorMix,
		EAethelnActionFamily ActionFamily,
		EAethelnValidationMode ValidationMode)
	{
		return ActorMix.Capabilities.FindByPredicate(
			[ActionFamily, ValidationMode](const FAethelnScenarioCapability& Capability)
			{
				return Capability.ActionFamily == ActionFamily
					&& Capability.ValidationMode == ValidationMode;
			});
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnNetworkProfileContractTest,
	"Aetheln.NetworkSpike.Contracts.NetworkProfile",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnNetworkProfileContractTest::RunTest(const FString& Parameters)
{
	const FAethelnNetworkProfile Profile;
	TestEqual(TEXT("Profile schema identity is stable"), Profile.SchemaId, FString(TEXT("aetheln.network-profile")));
	TestEqual(TEXT("Profile schema version is stable"), Profile.SchemaVersion, static_cast<uint32>(1));
	TestEqual(TEXT("An unset profile has an explicit identity"), Profile.ProfileId, FString(TEXT("network-profile.unset")));
	TestFalse(TEXT("Latency is not invented"), Profile.LatencyMilliseconds.IsSet());
	TestFalse(TEXT("Jitter is not invented"), Profile.JitterMilliseconds.IsSet());
	TestFalse(TEXT("Loss is not invented"), Profile.PacketLossPercent.IsSet());
	TestFalse(TEXT("Duplication is not invented"), Profile.PacketDuplicationPercent.IsSet());
	TestFalse(TEXT("Reordering is not invented"), Profile.PacketReorderPercent.IsSet());
	TestFalse(TEXT("Server tick is not invented"), Profile.ServerTickHertz.IsSet());
	TestFalse(TEXT("Combat history is not invented"), Profile.CombatHistoryMilliseconds.IsSet());
	TestFalse(TEXT("Bandwidth is not invented"), Profile.BandwidthBitsPerSecond.IsSet());
	TestFalse(TEXT("Capacity is not invented"), Profile.ConnectionCapacity.IsSet());
	TestTrue(TEXT("Unset numeric profile values remain observable"), Profile.HasUnsetNumericValues());
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnNetworkEvidenceIdentityTest,
	"Aetheln.NetworkSpike.Contracts.EvidenceIdentity",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnNetworkEvidenceIdentityTest::RunTest(const FString& Parameters)
{
	const FAethelnNetworkSpikeEvidence Evidence;
	TestEqual(TEXT("Evidence schema identity is stable"), Evidence.SchemaId, FString(TEXT("aetheln.network-authority-evidence")));
	TestEqual(TEXT("Evidence schema version is stable"), Evidence.SchemaVersion, static_cast<uint32>(1));
	TestEqual(TEXT("Scenario identity is immutable"), Evidence.ScenarioId, FString(TEXT("network-authority.baseline.v1")));
	TestEqual(TEXT("Actor mix identity is immutable"), Evidence.ActorMix.ActorMixId, FString(TEXT("network-authority.actor-mix.v1")));
	TestEqual(TEXT("Seed/config identity is immutable"), Evidence.SeedConfigId, FString(TEXT("network-authority.seed-config.v1")));
	TestEqual(TEXT("Scenario map is immutable"), Evidence.MapId, FString(TEXT("/Game/Maps/StarterMap")));
	TestEqual(TEXT("Scenario requires two distinct clients"), Evidence.ActorMix.ClientCount, 2);
	TestEqual(TEXT("Scenario requires one damageable enemy"), Evidence.ActorMix.DamageableEnemyCount, 1);
	TestFalse(TEXT("Duration stays unavailable before capture"), Evidence.DurationSeconds.IsSet());
	TestTrue(TEXT("Source revision field is present"), Evidence.Provenance.SourceRevision.IsEmpty());
	TestTrue(TEXT("Build identity field is present"), Evidence.Provenance.BuildIdentity.IsEmpty());
	TestTrue(TEXT("Engine revision field is present"), Evidence.Provenance.UnrealEngineRevision.IsEmpty());
	TestTrue(TEXT("Toolchain field is present"), Evidence.Provenance.ToolchainIdentity.IsEmpty());
	TestTrue(TEXT("Client hardware field is present"), Evidence.Provenance.ClientHardwareIdentity.IsEmpty());
	TestTrue(TEXT("Server hardware field is present"), Evidence.Provenance.ServerHardwareIdentity.IsEmpty());
	TestTrue(TEXT("Topology field is present"), Evidence.Provenance.TopologyIdentity.IsEmpty());
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnNetworkEvidenceMeasurementTest,
	"Aetheln.NetworkSpike.Contracts.NullableMeasurements",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnNetworkEvidenceMeasurementTest::RunTest(const FString& Parameters)
{
	const FAethelnNetworkSpikeMeasurements Measurements;
	TestFalse(TEXT("Server CPU stays unavailable before capture"), Measurements.ServerGameThreadMilliseconds.IsSet());
	TestFalse(TEXT("Replication CPU stays unavailable before capture"), Measurements.ServerReplicationCpuMilliseconds.IsSet());
	TestFalse(TEXT("Client memory stays unavailable before capture"), Measurements.ClientMemoryBytes.IsSet());
	TestFalse(TEXT("Server memory stays unavailable before capture"), Measurements.ServerMemoryBytes.IsSet());
	TestFalse(TEXT("Per-connection bandwidth stays unavailable before capture"), Measurements.BandwidthPerConnectionBitsPerSecond.IsSet());
	TestFalse(TEXT("Aggregate bandwidth stays unavailable before capture"), Measurements.AggregateBandwidthBitsPerSecond.IsSet());
	TestFalse(TEXT("Correction count stays unavailable before capture"), Measurements.CorrectionCount.IsSet());
	TestFalse(TEXT("Correction magnitude stays unavailable before capture"), Measurements.CorrectionMagnitudeCentimeters.IsSet());
	TestFalse(TEXT("Relevancy count stays unavailable before capture"), Measurements.RelevantActorCount.IsSet());
	TestFalse(TEXT("Destruction count stays unavailable before capture"), Measurements.DestructionEventCount.IsSet());
	TestFalse(TEXT("Complexity stays unavailable before review"), Measurements.ImplementationComplexity.IsSet());
	TestFalse(TEXT("Failure behavior stays unavailable before execution"), Measurements.FailureBehavior.IsSet());
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnReplicationCandidateIsolationTest,
	"Aetheln.NetworkSpike.Contracts.CandidateIsolation",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnReplicationCandidateIsolationTest::RunTest(const FString& Parameters)
{
	FAethelnReplicationCandidateIdentity Identity;
	TestEqual(TEXT("Candidate schema identity is stable"), Identity.SchemaId, FString(TEXT("aetheln.replication-candidate")));
	TestEqual(TEXT("Candidate schema version is stable"), Identity.SchemaVersion, static_cast<uint32>(1));
	TestFalse(TEXT("The neutral contract selects no candidate"), Identity.IsSelected());

	Identity.CandidateId = AethelnNetworkSpike::GenericPushModelCandidateId;
	TestTrue(TEXT("Generic push-model has an isolated identity"), Identity.IsSelected());
	TestNotEqual(TEXT("Replication Graph identity differs from generic"), FString(AethelnNetworkSpike::ReplicationGraphCandidateId), Identity.CandidateId);
	TestNotEqual(TEXT("Iris identity differs from generic"), FString(AethelnNetworkSpike::IrisCandidateId), Identity.CandidateId);
	TestNotEqual(TEXT("Iris and Replication Graph identities differ"), FString(AethelnNetworkSpike::IrisCandidateId), FString(AethelnNetworkSpike::ReplicationGraphCandidateId));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnValidationCapabilityContractTest,
	"Aetheln.NetworkSpike.Contracts.ValidationCapabilities",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnValidationCapabilityContractTest::RunTest(const FString& Parameters)
{
	const FAethelnNetworkSpikeActorMix ActorMix;
	const FAethelnScenarioCapability* PresentMelee = FindCapability(ActorMix, EAethelnActionFamily::Melee, EAethelnValidationMode::PresentTime);
	const FAethelnScenarioCapability* RewindMelee = FindCapability(ActorMix, EAethelnActionFamily::Melee, EAethelnValidationMode::BoundedRewind);
	const FAethelnScenarioCapability* Projectile = FindCapability(ActorMix, EAethelnActionFamily::Projectile, EAethelnValidationMode::PresentTime);
	const FAethelnScenarioCapability* Block = FindCapability(ActorMix, EAethelnActionFamily::Block, EAethelnValidationMode::PresentTime);
	const FAethelnScenarioCapability* Dodge = FindCapability(ActorMix, EAethelnActionFamily::Dodge, EAethelnValidationMode::PresentTime);

	TestNotNull(TEXT("Present-time melee capability is declared"), PresentMelee);
	TestNotNull(TEXT("Bounded-rewind melee seam is declared"), RewindMelee);
	TestNotNull(TEXT("Projectile capability is declared"), Projectile);
	TestNotNull(TEXT("Block capability is declared"), Block);
	TestNotNull(TEXT("Dodge capability is declared"), Dodge);
	if (PresentMelee != nullptr)
	{
		TestEqual(TEXT("Present-time melee is the implemented baseline"), PresentMelee->Status, EAethelnCapabilityStatus::Implemented);
	}
	if (RewindMelee != nullptr)
	{
		TestEqual(TEXT("Bounded rewind remains undecided"), RewindMelee->Status, EAethelnCapabilityStatus::NotImplemented);
	}
	if (Projectile != nullptr)
	{
		TestEqual(TEXT("Projectile coverage is not faked"), Projectile->Status, EAethelnCapabilityStatus::NotImplemented);
	}
	if (Block != nullptr)
	{
		TestEqual(TEXT("Block coverage is not faked"), Block->Status, EAethelnCapabilityStatus::NotImplemented);
	}
	if (Dodge != nullptr)
	{
		TestEqual(TEXT("Dodge coverage is not faked"), Dodge->Status, EAethelnCapabilityStatus::NotImplemented);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnAuthorityRejectionReasonTest,
	"Aetheln.NetworkSpike.Contracts.StableRejectionReasons",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAuthorityRejectionReasonTest::RunTest(const FString& Parameters)
{
	TestEqual(TEXT("Stale sequence reason is stable"), FString(LexToString(EAethelnAuthorityRejectionReason::StaleSequence)), FString(TEXT("stale-sequence")));
	TestEqual(TEXT("Duplicate sequence reason is stable"), FString(LexToString(EAethelnAuthorityRejectionReason::DuplicateSequence)), FString(TEXT("duplicate-sequence")));
	TestEqual(TEXT("Version mismatch reason is stable"), FString(LexToString(EAethelnAuthorityRejectionReason::IncompatibleVersion)), FString(TEXT("incompatible-version")));
	TestEqual(TEXT("Timestamp abuse reason is stable"), FString(LexToString(EAethelnAuthorityRejectionReason::TimestampOutOfBounds)), FString(TEXT("timestamp-out-of-bounds")));
	TestEqual(TEXT("Impossible aim reason is stable"), FString(LexToString(EAethelnAuthorityRejectionReason::ImpossibleAimTransition)), FString(TEXT("impossible-aim-transition")));
	TestEqual(TEXT("Disconnected command reason is stable"), FString(LexToString(EAethelnAuthorityRejectionReason::ConnectionClosed)), FString(TEXT("connection-closed")));
	TestEqual(TEXT("Destroyed actor reason is stable"), FString(LexToString(EAethelnAuthorityRejectionReason::ActorDestroyed)), FString(TEXT("actor-destroyed")));
	TestEqual(TEXT("Activation refusal reason is stable"), FString(LexToString(EAethelnAuthorityRejectionReason::ActivationBlocked)), FString(TEXT("activation-blocked")));
	return true;
}
#endif
