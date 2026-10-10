#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnReplicationCandidateRuntime.h"
#include "AethelnReplicationComparisonProbeActor.h"
#include "AethelnCombatTestWorld.h"
#include "GameFramework/PlayerController.h"
#include "Misc/AutomationTest.h"
#include "Net/UnrealNetwork.h"
#include "UObject/UnrealType.h"

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnReplicationCandidateSelectionTest,
	"Aetheln.GameNet.ReplicationCandidates.ClosedSelection",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnReplicationCandidateSelectionTest::RunTest(const FString& Parameters)
{
	FAethelnReplicationCandidateRequest Request;
	FString Reason;
	TestTrue(TEXT("Absent selection preserves production defaults"),
		AethelnReplicationCandidates::ParseRequest(TEXT("-unattended"), Request, Reason));
	TestFalse(TEXT("Default is unselected"), Request.IsSelected());
	TestTrue(TEXT("Omitted mode does not validate existing unrelated scenario switches"),
		AethelnReplicationCandidates::ParseRequest(TEXT("-AethelnRunId=bad value -AethelnAuthorityScenario -AethelnAuthorityScenario"), Request, Reason));
	TestFalse(TEXT("Unrelated switches do not activate a candidate"), Request.IsSelected());
	for (const TCHAR* Id : { AethelnNetworkSpike::GenericPushModelCandidateId,
		AethelnNetworkSpike::ReplicationGraphCandidateId, AethelnNetworkSpike::IrisCandidateId })
	{
		TestTrue(TEXT("All three explicit candidates are accepted"),
			AethelnReplicationCandidates::ParseRequest(FString::Printf(
				TEXT("-AethelnAuthorityScenario -AethelnReplicationCandidate=%s"), Id), Request, Reason));
		TestEqual(TEXT("Identity is exact"), Request.CandidateId, FString(Id));
		const TUniquePtr<IAethelnReplicationCandidate> Candidate =
			AethelnReplicationCandidates::CreateCandidate(Request);
		TestNotNull(TEXT("Each identity has an implementation"), Candidate.Get());
		if (Candidate)
		{
			TestEqual(TEXT("Adapter identity matches request"), Candidate->GetIdentity().CandidateId, FString(Id));
		}
	}
	for (const TCHAR* Invalid : {
		TEXT("-AethelnReplicationCandidate=replication-candidate.iris"),
		TEXT("-AethelnAuthorityScenario -AethelnReplicationCandidate=unknown"),
		TEXT("-AethelnAuthorityScenario -AethelnReplicationCandidate=replication-candidate.unselected"),
		TEXT("-AethelnAuthorityScenario -AethelnReplicationCandidate=replication-candidate.iris -AethelnReplicationCandidate=replication-candidate.iris"),
		TEXT("-AethelnAuthorityScenario -AethelnReplicationCandidate=replication-candidate.iris -UseIrisReplication=0"),
		TEXT("-AethelnAuthorityScenario -AethelnReplicationCandidate=replication-candidate.generic-push-model -RepDriverEnable") })
	{
		TestFalse(TEXT("Malformed or conflicting opt-in refuses"),
			AethelnReplicationCandidates::ParseRequest(Invalid, Request, Reason));
		TestFalse(TEXT("Refusal supplies a reason"), Reason.IsEmpty());
		TestFalse(TEXT("Refusal does not leak prior selection"), Request.IsSelected());
	}
	TestFalse(TEXT("No adapter is selected for production default"),
		AethelnReplicationCandidates::CreateCandidate(FAethelnReplicationCandidateRequest()).IsValid());
	Request.CandidateId = TEXT("unknown");
	TestFalse(TEXT("Factory refuses unknown identities even outside CLI parsing"),
		AethelnReplicationCandidates::CreateCandidate(Request).IsValid());
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnReplicationCandidateObservationTest,
	"Aetheln.GameNet.ReplicationCandidates.NoLabelOnlyProof",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnReplicationCandidateObservationTest::RunTest(const FString& Parameters)
{
	FAethelnReplicationCandidateRequest Request;
	Request.CandidateId = AethelnNetworkSpike::IrisCandidateId;
	FAethelnReplicationCandidateObservation Observation;
	FString Reason;
	TestFalse(TEXT("A requested label without a real initialized driver is not effect proof"),
		AethelnReplicationCandidates::InspectDriver(Request, nullptr, Observation, Reason));
	TestFalse(TEXT("No initialized backend was observed"), Observation.bInitialized);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnReplicationProbeAuthorityTest,
	"Aetheln.GameNet.ReplicationCandidates.ProbeAuthority",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnReplicationProbeAuthorityTest::RunTest(const FString& Parameters)
{
	AethelnCombatTests::FScopedCombatTestWorld World;
	AAethelnReplicationComparisonProbeActor* Probe = World.Spawn<AAethelnReplicationComparisonProbeActor>();
	APlayerController* Owner = World.Spawn<APlayerController>();
	if (!TestNotNull(TEXT("Probe exists"), Probe) || !TestNotNull(TEXT("Owner exists"), Owner))
	{
		return false;
	}
	TestEqual(TEXT("Unstarted probe has no fabricated update"), Probe->GetProbeRevision(), 0u);
	TestFalse(TEXT("Missing owner cannot start probe"), Probe->StartProbe(nullptr));
	Probe->SetRole(ROLE_AutonomousProxy);
	TestFalse(TEXT("Client cannot establish authoritative baseline"), Probe->StartProbe(Owner));
	TestEqual(TEXT("Client refusal leaves revision unchanged"), Probe->GetProbeRevision(), 0u);
	Probe->SetRole(ROLE_Authority);
	TestTrue(TEXT("Authority establishes only the baseline"), Probe->StartProbe(Owner));
	TestEqual(TEXT("Baseline precedes postinitial update"), Probe->GetProbeRevision(), 1u);
	TestFalse(TEXT("Repeated start cannot manufacture changed update"), Probe->StartProbe(Owner));
	TestEqual(TEXT("Without remote acknowledgement there is no update"), Probe->GetProbeRevision(), 1u);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnReplicationProbePropertyTest,
	"Aetheln.GameNet.ReplicationCandidates.PushPropertyContract",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnReplicationProbePropertyTest::RunTest(const FString& Parameters)
{
	AethelnCombatTests::FScopedCombatTestWorld World;
	AAethelnReplicationComparisonProbeActor* Probe = World.Spawn<AAethelnReplicationComparisonProbeActor>();
	if (!TestNotNull(TEXT("Probe exists"), Probe)) { return false; }
	const FProperty* Property = FindFProperty<FProperty>(Probe->GetClass(), TEXT("ProbeState"));
	if (!TestNotNull(TEXT("Common property is reflected"), Property)) { return false; }
	TestTrue(TEXT("Common property is actually replicated"), Property->HasAnyPropertyFlags(CPF_Net));
	TestTrue(TEXT("Remote receipt has a rep-notify"), Property->HasAnyPropertyFlags(CPF_RepNotify));
	TArray<FLifetimeProperty> Properties;
	Probe->GetLifetimeReplicatedProps(Properties);
	const FLifetimeProperty* Lifetime = Properties.FindByPredicate([Property](const FLifetimeProperty& Entry)
	{
		return Entry.RepIndex == Property->RepIndex;
	});
	if (TestNotNull(TEXT("Common property is registered for lifetime replication"), Lifetime))
	{
		TestTrue(TEXT("The common property is push marked"), Lifetime->bIsPushBased);
	}
	TestTrue(TEXT("Probe is relevant only to its owning connection"), Probe->bOnlyRelevantToOwner);
	return true;
}

#endif
