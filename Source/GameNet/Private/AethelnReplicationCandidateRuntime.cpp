#include "AethelnReplicationCandidateRuntime.h"

#include "Engine/NetConnection.h"
#include "Engine/Engine.h"
#include "Engine/NetDriver.h"
#include "Engine/ReplicationDriver.h"
#include "Engine/World.h"
#include "HAL/IConsoleManager.h"
#include "HAL/PlatformMisc.h"
#include "Iris/IrisConfig.h"
#include "Misc/CommandLine.h"
#include "Misc/Parse.h"
#include "Modules/ModuleManager.h"
#include "Net/Core/PushModel/PushModel.h"

namespace
{
	constexpr TCHAR GraphClassPath[] = TEXT("/Script/ReplicationGraph.BasicReplicationGraph");
	FAethelnReplicationCandidateRequest ActiveRequest;
	FDelegateHandle DriverCreatedHandle;
	bool bChangedPreferences = false;
	bool bActive = false;
	bool bPreviousIris = false;
	bool bPreviousHandles = false;
	constexpr TCHAR PushPreferenceTag[] = TEXT("AethelnReplicationCandidate");

	bool IsSafeIdentity(const FString& Value)
	{
		if (Value.IsEmpty() || Value.Len() > 256) { return false; }
		for (TCHAR C : Value)
		{
			if (!FChar::IsAlnum(C) && C != TEXT('.') && C != TEXT('-') && C != TEXT('_') && C != TEXT('@')
				&& C != TEXT('/') && C != TEXT(':') && C != TEXT('+')) { return false; }
		}
		return true;
	}

	class FCandidate final : public IAethelnReplicationCandidate
	{
	public:
		explicit FCandidate(const FAethelnReplicationCandidateRequest& Request)
		{
			Identity.CandidateId = Request.CandidateId;
			Identity.ImplementationRevision = Request.SourceRevision;
		}
		virtual const FAethelnReplicationCandidateIdentity& GetIdentity() const override { return Identity; }
		virtual bool IsAvailableForPackagedRun(FString& OutReason) const override
		{
			OutReason.Reset();
#if !WITH_PUSH_MODEL
			OutReason = TEXT("push_model_not_compiled");
			return false;
#else
			if (Identity.CandidateId == AethelnNetworkSpike::ReplicationGraphCandidateId
				&& LoadClass<UReplicationDriver>(nullptr, GraphClassPath) == nullptr)
			{
				OutReason = TEXT("graph_class_unavailable");
				return false;
			}
			if (Identity.CandidateId == AethelnNetworkSpike::IrisCandidateId
				&& !FModuleManager::Get().LoadModulePtr<IModuleInterface>(TEXT("IrisCore")))
			{
				OutReason = TEXT("iris_module_unavailable");
				return false;
			}
			return true;
#endif
		}
	private:
		FAethelnReplicationCandidateIdentity Identity;
	};

#if !UE_BUILD_SHIPPING
	void OnDriverCreated(UWorld* World, UNetDriver* Driver)
	{
		// A joining client initially has a PendingNetDriver, often without a world.
		if (!bActive || Driver == nullptr || Driver->GetNetDriverDefinition() != NAME_GameNetDriver)
		{
			return;
		}
		if (UReplicationDriver::CreateReplicationDriverDelegate().IsBound()
			|| Driver->ReplicationDriverClass != nullptr || !Driver->ReplicationDriverClassName.IsEmpty())
		{
			AethelnReplicationCandidates::Refuse(TEXT("foreign_replication_driver_configuration"));
			return;
		}
		const bool bExpectedIris = ActiveRequest.CandidateId == AethelnNetworkSpike::IrisCandidateId;
		if (Driver->IsUsingIrisReplication() != bExpectedIris)
		{
			AethelnReplicationCandidates::Refuse(TEXT("driver_iris_preference_mismatch"));
			return;
		}
		if (ActiveRequest.CandidateId == AethelnNetworkSpike::ReplicationGraphCandidateId)
		{
			UClass* GraphClass = LoadClass<UReplicationDriver>(nullptr, GraphClassPath);
			if (GraphClass == nullptr)
			{
				AethelnReplicationCandidates::Refuse(TEXT("graph_class_unavailable"));
				return;
			}
			Driver->ReplicationDriverClass = GraphClass;
			Driver->ReplicationDriverClassName = GraphClassPath;
		}
	}
#endif
}

bool AethelnReplicationCandidates::ParseRequest(const FString& CommandLine,
	FAethelnReplicationCandidateRequest& OutRequest, FString& OutReason)
{
	OutRequest = {};
	OutReason.Reset();
	// Omitted mode imposes no new requirements on the existing scenario/provenance switches.
	const TCHAR* SelectionCursor = *CommandLine;
	FString SelectionToken;
	bool bHasCandidateOption = false;
	while (FParse::Token(SelectionCursor, SelectionToken, false))
	{
		if (SelectionToken.Equals(TEXT("-AethelnReplicationCandidate"), ESearchCase::IgnoreCase)
			|| SelectionToken.StartsWith(TEXT("-AethelnReplicationCandidate="), ESearchCase::IgnoreCase))
		{
			bHasCandidateOption = true;
		}
	}
	if (!bHasCandidateOption) { return true; }
	FAethelnReplicationCandidateRequest Parsed;
	TSet<FString> Seen;
	bool bScenario = false;
	bool bConflict = false;
	const TCHAR* Cursor = *CommandLine;
	FString Token;
	while (FParse::Token(Cursor, Token, false))
	{
		if (!Token.StartsWith(TEXT("-"))) { continue; }
		Token.RightChopInline(1);
		FString Key;
		FString Value;
		if (!Token.Split(TEXT("="), &Key, &Value)) { Key = Token; }
		Key = Key.ToLower();
		FString* Destination = nullptr;
		if (Key == TEXT("aethelnreplicationcandidate")) { Destination = &Parsed.CandidateId; }
		else if (Key == TEXT("aethelnrunid")) { Destination = &Parsed.RunId; }
		else if (Key == TEXT("aethelnsourcerevision")) { Destination = &Parsed.SourceRevision; }
		else if (Key == TEXT("aethelnbuildidentity")) { Destination = &Parsed.BuildIdentity; }
		else if (Key == TEXT("aethelntoolchainidentity")) { Destination = &Parsed.ToolchainIdentity; }
		else if (Key == TEXT("aethelnauthorityscenario")) { bScenario = Value.IsEmpty(); }
		else if (Key == TEXT("useirisreplication") || Key == TEXT("repdriverenable") || Key == TEXT("repdriverdisable"))
		{
			bConflict = true;
		}
		if (Destination != nullptr || Key == TEXT("aethelnauthorityscenario"))
		{
			if (Seen.Contains(Key) || (Destination != nullptr && !IsSafeIdentity(Value)))
			{
				OutReason = TEXT("duplicate_or_invalid_candidate_argument");
				return false;
			}
			Seen.Add(Key);
			if (Destination != nullptr) { *Destination = Value; }
		}
	}
	if (!Seen.Contains(TEXT("aethelnreplicationcandidate"))) { return true; }
	if (!bScenario || bConflict
		|| (Parsed.CandidateId != AethelnNetworkSpike::GenericPushModelCandidateId
			&& Parsed.CandidateId != AethelnNetworkSpike::ReplicationGraphCandidateId
			&& Parsed.CandidateId != AethelnNetworkSpike::IrisCandidateId))
	{
		OutReason = TEXT("candidate_selection_requires_isolated_authority_scenario");
		return false;
	}
	OutRequest = MoveTemp(Parsed);
	return true;
}

TUniquePtr<IAethelnReplicationCandidate> AethelnReplicationCandidates::CreateCandidate(const FAethelnReplicationCandidateRequest& Request)
{
	if (Request.CandidateId != AethelnNetworkSpike::GenericPushModelCandidateId
		&& Request.CandidateId != AethelnNetworkSpike::ReplicationGraphCandidateId
		&& Request.CandidateId != AethelnNetworkSpike::IrisCandidateId)
	{
		return nullptr;
	}
	return MakeUnique<FCandidate>(Request);
}

bool AethelnReplicationCandidates::InspectDriver(const FAethelnReplicationCandidateRequest& Request, UNetDriver* Driver,
	FAethelnReplicationCandidateObservation& OutObservation, FString& OutReason)
{
	OutObservation = {};
	OutReason = TEXT("driver_not_initialized");
	if (!Request.IsSelected() || CreateCandidate(Request) == nullptr || Driver == nullptr || Driver->GetWorld() == nullptr
		|| !Driver->IsNetResourceValid() || Driver->GetWorld()->GetNetDriver() != Driver
		|| Driver->GetNetDriverDefinition() != NAME_GameNetDriver
		|| Driver->NetDriverName == NAME_PendingNetDriver
		|| (!Driver->IsServer() && (Driver->ServerConnection == nullptr
			|| Driver->ServerConnection->GetConnectionState() != USOCK_Open)))
	{
		return false;
	}
	OutObservation.bServer = Driver->IsServer();
	OutObservation.bIris = Driver->IsUsingIrisReplication();
	UClass* GraphClass = LoadClass<UReplicationDriver>(nullptr, GraphClassPath);
	UReplicationDriver* ReplicationDriver = Driver->GetReplicationDriver();
	OutObservation.bGraph = ReplicationDriver != nullptr && GraphClass != nullptr && ReplicationDriver->IsA(GraphClass);
	OutObservation.DriverClass = ReplicationDriver != nullptr ? ReplicationDriver->GetClass()->GetPathName() : TEXT("none");
#if WITH_PUSH_MODEL
	OutObservation.bLegacyPushEnabled = UEPushModelPrivate::IsPushModelEnabled();
	OutObservation.bLegacyPushHandlesAllowed = UEPushModelPrivate::IsHandleCreationAllowed();
#endif
	const bool bIris = Request.CandidateId == AethelnNetworkSpike::IrisCandidateId;
	const bool bGraph = Request.CandidateId == AethelnNetworkSpike::ReplicationGraphCandidateId;
	if (OutObservation.bIris != bIris || (bIris && Driver->GetReplicationSystem() == nullptr)
		|| (OutObservation.bServer && OutObservation.bGraph != bGraph)
		|| (!bIris && (!OutObservation.bLegacyPushEnabled || !OutObservation.bLegacyPushHandlesAllowed))
		|| (!bGraph && ReplicationDriver != nullptr))
	{
		OutReason = TEXT("initialized_backend_mismatch");
		return false;
	}
	OutObservation.bInitialized = true;
	OutReason.Reset();
	return true;
}

const FAethelnReplicationCandidateRequest& AethelnReplicationCandidates::GetRequest() { return ActiveRequest; }
bool AethelnReplicationCandidates::IsActive() { return bActive; }

void AethelnReplicationCandidates::Refuse(const TCHAR* Reason)
{
	bActive = false;
	UE_LOG(LogTemp, Error, TEXT("AETHELN_REPLICATION_REFUSED reason=%s"), Reason);
	FPlatformMisc::RequestExitWithStatus(false, 1, TEXT("AethelnReplicationCandidates"));
}

void AethelnReplicationCandidates::Startup()
{
#if !UE_BUILD_SHIPPING
	// Shipping builds never read candidate selection; the laboratory stays inactive.
	if (bChangedPreferences) { Refuse(TEXT("candidate_runtime_already_configured")); return; }
	FString Reason;
	if (!ParseRequest(FCommandLine::Get(), ActiveRequest, Reason)) { Refuse(*Reason); return; }
	if (!ActiveRequest.IsSelected()) { return; }
	if (!IsSafeIdentity(ActiveRequest.RunId) || !IsSafeIdentity(ActiveRequest.BuildIdentity)
		|| !IsSafeIdentity(ActiveRequest.ToolchainIdentity) || ActiveRequest.SourceRevision.Len() != 40)
	{
		Refuse(TEXT("candidate_provenance_missing_or_invalid"));
		return;
	}
	for (TCHAR C : ActiveRequest.SourceRevision)
	{
		if (!FChar::IsHexDigit(C)) { Refuse(TEXT("candidate_source_revision_invalid")); return; }
	}
	if (GEngine != nullptr)
	{
		for (const FWorldContext& Context : GEngine->GetWorldContexts())
		{
			for (const FNamedNetDriver& Entry : Context.ActiveNetDrivers)
			{
				if (Entry.NetDriver != nullptr && Entry.NetDriver->GetNetDriverDefinition() == NAME_GameNetDriver)
				{
					Refuse(TEXT("candidate_selected_after_game_driver_creation"));
					return;
				}
			}
		}
	}
	const TUniquePtr<IAethelnReplicationCandidate> Candidate = CreateCandidate(ActiveRequest);
	if (!Candidate || !Candidate->IsAvailableForPackagedRun(Reason)) { Refuse(*Reason); return; }
	if (UReplicationDriver::CreateReplicationDriverDelegate().IsBound()) { Refuse(TEXT("foreign_replication_driver_factory")); return; }
	IConsoleVariable* Push = IConsoleManager::Get().FindConsoleVariable(TEXT("net.IsPushModelEnabled"));
	if (Push == nullptr) { Refuse(TEXT("push_model_runtime_unavailable")); return; }
	bPreviousIris = UE::Net::ShouldUseIrisReplication();
#if WITH_PUSH_MODEL
	bPreviousHandles = UEPushModelPrivate::IsHandleCreationAllowed();
#endif
	bChangedPreferences = true;
	// This supported preference is process-wide. Use fresh isolated processes for every candidate.
	UE::Net::SetUseIrisReplication(ActiveRequest.CandidateId == AethelnNetworkSpike::IrisCandidateId);
	Push->Set(1, ECVF_SetByTemp, FName(PushPreferenceTag));
	if (Push->GetInt() != 1) { Refuse(TEXT("push_model_runtime_override_conflict")); return; }
	DriverCreatedHandle = FWorldDelegates::OnNetDriverCreated.AddStatic(&OnDriverCreated);
	bActive = true;
#endif
}

void AethelnReplicationCandidates::Shutdown()
{
	FWorldDelegates::OnNetDriverCreated.Remove(DriverCreatedHandle);
	DriverCreatedHandle.Reset();
	if (bChangedPreferences)
	{
		UE::Net::SetUseIrisReplication(bPreviousIris);
		if (IConsoleVariable* Push = IConsoleManager::Get().FindConsoleVariable(TEXT("net.IsPushModelEnabled")))
		{
			Push->Unset(ECVF_SetByTemp, FName(PushPreferenceTag));
		}
#if WITH_PUSH_MODEL
		UEPushModelPrivate::SetHandleCreationAllowed(bPreviousHandles);
#endif
	}
	bChangedPreferences = false;
	bActive = false;
	ActiveRequest = {};
}
