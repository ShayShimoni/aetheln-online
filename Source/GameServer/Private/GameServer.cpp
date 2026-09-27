#include "AethelnObservability.h"
#include "AethelnObservabilitySubsystem.h"
#include "Engine/Engine.h"
#include "Engine/GameInstance.h"
#include "Engine/World.h"
#include "EngineUtils.h"
#include "GameFramework/Controller.h"
#include "GameFramework/Pawn.h"
#include "GameFramework/PlayerState.h"
#include "GenericPlatform/GenericPlatformCrashContext.h"
#include "HAL/PlatformTime.h"
#include "Misc/App.h"
#include "Misc/CommandLine.h"
#include "Misc/CoreDelegates.h"
#include "Misc/EngineVersion.h"
#include "Misc/Parse.h"
#include "Modules/ModuleManager.h"

namespace AethelnServerObservability
{
	inline constexpr TCHAR CrashSchemaKey[] = TEXT("AethelnObservabilitySchema");
	inline constexpr TCHAR CrashLifecycleKey[] = TEXT("AethelnServerLifecycle");
	inline constexpr TCHAR CrashContextStateKey[] = TEXT("AethelnCrashContextState");
	inline constexpr TCHAR CrashContextSchemaVersionKey[] = TEXT("AethelnCrashContextSchemaVersion");
	inline constexpr TCHAR CrashSourceRevisionKey[] = TEXT("AethelnSourceRevision");
	inline constexpr TCHAR CrashBuildIdentityKey[] = TEXT("AethelnBuildIdentity");
	inline constexpr TCHAR CrashBuildConfigurationKey[] = TEXT("AethelnBuildConfiguration");
	inline constexpr TCHAR CrashEngineRevisionKey[] = TEXT("AethelnEngineRevision");
	inline constexpr TCHAR CrashToolchainIdentityKey[] = TEXT("AethelnToolchainIdentity");
	inline constexpr TCHAR CrashNetworkProfileSchemaKey[] = TEXT("AethelnNetworkProfileSchema");
	inline constexpr TCHAR CrashNetworkProfileVersionKey[] = TEXT("AethelnNetworkProfileVersion");
	inline constexpr TCHAR CrashNetworkProfileIdKey[] = TEXT("AethelnNetworkProfileId");
	inline constexpr TCHAR CrashFlowKindKey[] = TEXT("AethelnFlowKind");
	inline constexpr TCHAR CrashRunIdKey[] = TEXT("AethelnRunId");
	inline constexpr TCHAR CrashServerInstanceKey[] = TEXT("AethelnServerInstance");
	inline constexpr TCHAR CrashConnectionPseudonymKey[] = TEXT("AethelnConnectionPseudonym");
	inline constexpr const TCHAR* CrashContextIdentityKeys[] = {
		CrashContextSchemaVersionKey,
		CrashSourceRevisionKey,
		CrashBuildIdentityKey,
		CrashBuildConfigurationKey,
		CrashEngineRevisionKey,
		CrashToolchainIdentityKey,
		CrashNetworkProfileSchemaKey,
		CrashNetworkProfileVersionKey,
		CrashNetworkProfileIdKey,
		CrashFlowKindKey,
		CrashRunIdKey,
		CrashServerInstanceKey,
		CrashConnectionPseudonymKey
	};
	inline constexpr double PrototypeHealthSampleIntervalSeconds = 30.0;

	enum class ECrashContextState : uint8
	{
		Missing,
		Updating,
		Active,
		Ambiguous,
		Stale
	};

	const TCHAR* CrashContextStateToString(ECrashContextState State)
	{
		switch (State)
		{
		case ECrashContextState::Missing: return TEXT("missing");
		case ECrashContextState::Updating: return TEXT("updating");
		case ECrashContextState::Active: return TEXT("active");
		case ECrashContextState::Ambiguous: return TEXT("ambiguous");
		case ECrashContextState::Stale: return TEXT("stale");
		default: return TEXT("missing");
		}
	}

	/**
	 * Owns the Issue #148 crash GameData keys. Every value is registered before
	 * failure; the state key is written first on clear and last on registration
	 * so an interrupted update never reads as active.
	 */
	class FCrashContextRegistration
	{
	public:
		void Initialize()
		{
			ClearIdentity(ECrashContextState::Missing);
		}

		void Register(const FAethelnCrashContextSnapshot* Snapshot)
		{
			if (Snapshot == nullptr || !Snapshot->IsBounded())
			{
				ClearIdentity(ECrashContextState::Missing);
				return;
			}

			SetState(ECrashContextState::Updating);
			FGenericCrashContext::SetGameData(CrashContextSchemaVersionKey, FString::Printf(TEXT("%u"), Snapshot->ObservabilitySchemaVersion));
			FGenericCrashContext::SetGameData(CrashSourceRevisionKey, Snapshot->SourceRevision);
			FGenericCrashContext::SetGameData(CrashBuildIdentityKey, Snapshot->BuildIdentity);
			FGenericCrashContext::SetGameData(CrashBuildConfigurationKey, Snapshot->BuildConfiguration);
			FGenericCrashContext::SetGameData(CrashEngineRevisionKey, Snapshot->EngineRevision);
			FGenericCrashContext::SetGameData(CrashToolchainIdentityKey, Snapshot->ToolchainIdentity);
			FGenericCrashContext::SetGameData(CrashNetworkProfileSchemaKey, Snapshot->NetworkProfileSchemaId);
			FGenericCrashContext::SetGameData(CrashNetworkProfileVersionKey, FString::Printf(TEXT("%u"), Snapshot->NetworkProfileSchemaVersion));
			FGenericCrashContext::SetGameData(CrashNetworkProfileIdKey, Snapshot->NetworkProfileId);
			FGenericCrashContext::SetGameData(CrashFlowKindKey, LexToString(Snapshot->FlowKind));
			FGenericCrashContext::SetGameData(CrashRunIdKey, Snapshot->RunId);
			FGenericCrashContext::SetGameData(CrashServerInstanceKey, Snapshot->ServerInstanceId);
			FGenericCrashContext::SetGameData(CrashConnectionPseudonymKey, Snapshot->ConnectionPseudonym);
			SetState(ECrashContextState::Active);
		}

		void MarkStale()
		{
			ClearIdentity(ECrashContextState::Stale);
		}

		void MarkAmbiguous()
		{
			ClearIdentity(ECrashContextState::Ambiguous);
		}

		ECrashContextState GetState() const
		{
			return State;
		}

	private:
		void SetState(ECrashContextState NewState)
		{
			State = NewState;
			FGenericCrashContext::SetGameData(CrashContextStateKey, CrashContextStateToString(NewState));
		}

		void ClearIdentity(ECrashContextState NewState)
		{
			SetState(NewState);
			for (const TCHAR* Key : CrashContextIdentityKeys)
			{
				FGenericCrashContext::SetGameData(Key, TEXT(""));
			}
		}

		ECrashContextState State = ECrashContextState::Missing;
	};

	/** Crash-time work: only the pre-existing lifecycle transition. */
	void HandleSystemError()
	{
		FGenericCrashContext::SetGameData(CrashLifecycleKey, TEXT("crashing"));
	}

	bool IsObservableWorld(const UWorld* World)
	{
		return World != nullptr
			&& (World->WorldType == EWorldType::Game || World->WorldType == EWorldType::PIE);
	}

	FString ReadArgument(const TCHAR* Key, const FString& Fallback)
	{
		FString Value;
		return FParse::Value(FCommandLine::Get(), Key, Value) && !Value.IsEmpty() ? Value : Fallback;
	}

	void ConfigureContext(UAethelnObservabilitySubsystem& Subsystem)
	{
		Subsystem.SetEnvironment(ReadArgument(TEXT("AethelnEnvironment="), TEXT("local")));
		if (!Subsystem.HasRuntimeContext())
		{
			Subsystem.SetRuntimeContext(
				EAethelnFlowKind::PrototypeAuthority,
				ReadArgument(TEXT("AethelnRunId="), TEXT("run-local")),
				TEXT("game-server"),
				AethelnObservability::ExcludedIdentifier);
		}
		if (!Subsystem.HasBuildContext())
		{
			FAethelnBuildIdentity Build;
			Build.SourceRevision = ReadArgument(TEXT("AethelnSourceRevision="), AethelnObservability::UnknownValue);
			Build.BuildIdentity = ReadArgument(TEXT("AethelnBuildIdentity="), AethelnObservability::UnknownValue);
			Build.BuildConfiguration = LexToString(FApp::GetBuildConfiguration());
			Build.EngineRevision = FEngineVersion::Current().ToString();
			Build.ToolchainIdentity = ReadArgument(TEXT("AethelnToolchainIdentity="), AethelnObservability::UnknownValue);
			FAethelnNetworkProfile Profile;
			Profile.ProfileId = ReadArgument(TEXT("AethelnProfileId="), AethelnNetworkSpike::UnsetNetworkProfileId);
			Subsystem.SetBuildContext(Build, Profile);
		}
	}

	void EmitEvent(
		UAethelnObservabilitySubsystem& Subsystem,
		EAethelnObservabilityCategory Category,
		EAethelnSafeReason Reason,
		uint64 Sequence)
	{
		FAethelnObservabilityEvent Event;
		Event.Category = Category;
		Event.SubjectCategory = Category;
		Event.SafeReason = Reason;
		FAethelnObservabilityEventContext Context;
		Context.Sequence = Sequence;
		Subsystem.EmitEvent(Event, Context);
	}

	int64 CalculateTickDurationMicroseconds(double TickStartSeconds, double TickEndSeconds)
	{
		if (!FMath::IsFinite(TickStartSeconds)
			|| !FMath::IsFinite(TickEndSeconds)
			|| TickEndSeconds < TickStartSeconds)
		{
			return 0;
		}
		return FMath::Max<int64>(
			0,
			FMath::RoundToInt64((TickEndSeconds - TickStartSeconds) * 1000000.0));
	}

	TArray<FAethelnMetricSample> MakeHealthMetrics(
		int64 TickDurationMicroseconds,
		int64 ActorCount,
		int64 ReplicatedActorCount,
		int64 PawnCount,
		int64 ControllerCount,
		int64 PlayerStateCount,
		int64 OtherActorCount)
	{
		TArray<FAethelnMetricSample> Result;
		Result.Reserve(7);
		FAethelnMetricSample Tick;
		Tick.Metric = EAethelnMetricKind::ServerTickMicroseconds;
		Tick.Category = EAethelnObservabilityCategory::ServerHealth;
		Tick.Value = FMath::Max<int64>(0, TickDurationMicroseconds);
		Result.Add(Tick);
		FAethelnMetricSample Actors = Tick;
		Actors.Metric = EAethelnMetricKind::ActorCount;
		Actors.Value = FMath::Max<int64>(0, ActorCount);
		Result.Add(Actors);
		FAethelnMetricSample Replicated = Tick;
		Replicated.Metric = EAethelnMetricKind::ReplicatedActorCount;
		Replicated.Value = FMath::Max<int64>(0, ReplicatedActorCount);
		Result.Add(Replicated);
		FAethelnMetricSample Pawns = Tick;
		Pawns.Metric = EAethelnMetricKind::PawnCount;
		Pawns.Value = FMath::Max<int64>(0, PawnCount);
		Result.Add(Pawns);
		FAethelnMetricSample Controllers = Tick;
		Controllers.Metric = EAethelnMetricKind::ControllerCount;
		Controllers.Value = FMath::Max<int64>(0, ControllerCount);
		Result.Add(Controllers);
		FAethelnMetricSample PlayerStates = Tick;
		PlayerStates.Metric = EAethelnMetricKind::PlayerStateCount;
		PlayerStates.Value = FMath::Max<int64>(0, PlayerStateCount);
		Result.Add(PlayerStates);
		FAethelnMetricSample OtherActors = Tick;
		OtherActors.Metric = EAethelnMetricKind::OtherActorCount;
		OtherActors.Value = FMath::Max<int64>(0, OtherActorCount);
		Result.Add(OtherActors);
		return Result;
	}

	bool ShouldSampleHealth(double NextSampleTime, double CurrentTime)
	{
		return FMath::IsFinite(CurrentTime)
			&& FMath::IsFinite(NextSampleTime)
			&& CurrentTime >= NextSampleTime;
	}

	const TCHAR* GetLifecycleAfterWorldCleanup(int32 RemainingObservableWorldCount)
	{
		return RemainingObservableWorldCount > 0
			? TEXT("world-running")
			: TEXT("controlled-shutdown");
	}

	EAethelnSafeReason GetLifecycleReasonAfterWorldCleanup(int32 RemainingObservableWorldCount)
	{
		return RemainingObservableWorldCount > 0
			? EAethelnSafeReason::Accepted
			: EAethelnSafeReason::ControlledShutdown;
	}
}

class FAethelnGameServerModule final : public IModuleInterface
{
public:
	virtual void StartupModule() override
	{
		FGenericCrashContext::SetGameData(AethelnServerObservability::CrashSchemaKey, AethelnObservability::SchemaId);
		FGenericCrashContext::SetGameData(AethelnServerObservability::CrashLifecycleKey, TEXT("module-started"));
		CrashContext.Initialize();
		WorldTickHandle = FWorldDelegates::OnWorldTickStart.AddRaw(this, &FAethelnGameServerModule::OnWorldTickStart);
		WorldTickEndHandle = FWorldDelegates::OnWorldTickEnd.AddRaw(this, &FAethelnGameServerModule::OnWorldTickEnd);
		WorldCleanupHandle = FWorldDelegates::OnWorldCleanup.AddRaw(this, &FAethelnGameServerModule::OnWorldCleanup);
		CrashHandle = FCoreDelegates::OnHandleSystemError.AddRaw(this, &FAethelnGameServerModule::OnSystemError);
	}

	virtual void ShutdownModule() override
	{
		FWorldDelegates::OnWorldTickStart.Remove(WorldTickHandle);
		FWorldDelegates::OnWorldTickEnd.Remove(WorldTickEndHandle);
		FWorldDelegates::OnWorldCleanup.Remove(WorldCleanupHandle);
		FCoreDelegates::OnHandleSystemError.Remove(CrashHandle);
		SampledWorlds.Reset();
		NextHealthSampleTimes.Reset();
		WorldTickStartTimes.Reset();
		FGenericCrashContext::SetGameData(AethelnServerObservability::CrashLifecycleKey, TEXT("module-stopped"));
		CrashContext.MarkStale();
	}

private:
	void OnWorldTickStart(UWorld* World, ELevelTick TickType, float DeltaSeconds)
	{
		if (!AethelnServerObservability::IsObservableWorld(World))
		{
			return;
		}
		(void)TickType;
		(void)DeltaSeconds;
		WorldTickStartTimes.Add(World, FPlatformTime::Seconds());
		UGameInstance* GameInstance = World->GetGameInstance();
		UAethelnObservabilitySubsystem* Subsystem = GameInstance != nullptr
			? GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>()
			: nullptr;
		if (Subsystem == nullptr)
		{
			return;
		}

		if (!SampledWorlds.Contains(World))
		{
			AethelnServerObservability::ConfigureContext(*Subsystem);
			SampledWorlds.Add(World);
			NextHealthSampleTimes.Add(World, 0.0);
			AethelnServerObservability::EmitEvent(
				*Subsystem,
				EAethelnObservabilityCategory::ServerLifecycle,
				EAethelnSafeReason::Accepted,
				NextSequence++);
			FGenericCrashContext::SetGameData(AethelnServerObservability::CrashLifecycleKey, TEXT("world-running"));
			RefreshCrashContext(*Subsystem);
		}
		else if (SampledWorlds.Num() == 1
			&& (CrashContext.GetState() == AethelnServerObservability::ECrashContextState::Stale
				|| CrashContext.GetState() == AethelnServerObservability::ECrashContextState::Ambiguous))
		{
			RefreshCrashContext(*Subsystem);
		}
	}

	void RefreshCrashContext(const UAethelnObservabilitySubsystem& Subsystem)
	{
		// ponytail: dead weak entries still count, so a leaked world keeps the process ambiguous (fail-safe) until cleanup.
		if (SampledWorlds.Num() != 1)
		{
			CrashContext.MarkAmbiguous();
			return;
		}
		FAethelnCrashContextSnapshot Snapshot;
		CrashContext.Register(Subsystem.TryGetCrashContextSnapshot(Snapshot) ? &Snapshot : nullptr);
	}

	void OnWorldTickEnd(UWorld* World, ELevelTick TickType, float DeltaSeconds)
	{
		if (!AethelnServerObservability::IsObservableWorld(World))
		{
			return;
		}
		(void)TickType;
		(void)DeltaSeconds;
		const double TickEndSeconds = FPlatformTime::Seconds();
		const double* TickStartSeconds = WorldTickStartTimes.Find(World);
		const int64 TickDurationMicroseconds = TickStartSeconds != nullptr
			? AethelnServerObservability::CalculateTickDurationMicroseconds(*TickStartSeconds, TickEndSeconds)
			: 0;
		WorldTickStartTimes.Remove(World);

		UGameInstance* GameInstance = World->GetGameInstance();
		UAethelnObservabilitySubsystem* Subsystem = GameInstance != nullptr
			? GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>()
			: nullptr;
		if (Subsystem == nullptr)
		{
			return;
		}

		double* NextHealthSampleTime = NextHealthSampleTimes.Find(World);
		const double CurrentTime = World->GetTimeSeconds();
		if (NextHealthSampleTime == nullptr
			|| !AethelnServerObservability::ShouldSampleHealth(*NextHealthSampleTime, CurrentTime))
		{
			return;
		}
		*NextHealthSampleTime = CurrentTime + AethelnServerObservability::PrototypeHealthSampleIntervalSeconds;

		int64 ActorCount = 0;
		int64 ReplicatedActorCount = 0;
		int64 PawnCount = 0;
		int64 ControllerCount = 0;
		int64 PlayerStateCount = 0;
		int64 OtherActorCount = 0;
		for (TActorIterator<AActor> It(World); It; ++It)
		{
			++ActorCount;
			if (It->GetIsReplicated())
			{
				++ReplicatedActorCount;
			}
			if (It->IsA<APawn>())
			{
				++PawnCount;
			}
			else if (It->IsA<AController>())
			{
				++ControllerCount;
			}
			else if (It->IsA<APlayerState>())
			{
				++PlayerStateCount;
			}
			else
			{
				++OtherActorCount;
			}
		}
		AethelnServerObservability::EmitEvent(
			*Subsystem,
			EAethelnObservabilityCategory::ServerHealth,
			EAethelnSafeReason::Accepted,
			NextSequence++);
		for (const FAethelnMetricSample& Sample : AethelnServerObservability::MakeHealthMetrics(
			TickDurationMicroseconds,
			ActorCount,
			ReplicatedActorCount,
			PawnCount,
			ControllerCount,
			PlayerStateCount,
			OtherActorCount))
		{
			Subsystem->EmitMetric(Sample);
		}
	}

	void OnWorldCleanup(UWorld* World, bool bSessionEnded, bool bCleanupResources)
	{
		if (!AethelnServerObservability::IsObservableWorld(World))
		{
			return;
		}
		const int32 RemainingObservableWorldCount = SampledWorlds.Contains(World)
			? SampledWorlds.Num() - 1
			: SampledWorlds.Num();
		if (UGameInstance* GameInstance = World->GetGameInstance())
		{
			if (UAethelnObservabilitySubsystem* Subsystem = GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>())
			{
				AethelnServerObservability::EmitEvent(
					*Subsystem,
					EAethelnObservabilityCategory::ServerLifecycle,
					AethelnServerObservability::GetLifecycleReasonAfterWorldCleanup(RemainingObservableWorldCount),
					NextSequence++);
			}
		}
		SampledWorlds.Remove(World);
		NextHealthSampleTimes.Remove(World);
		WorldTickStartTimes.Remove(World);
		FGenericCrashContext::SetGameData(
			AethelnServerObservability::CrashLifecycleKey,
			AethelnServerObservability::GetLifecycleAfterWorldCleanup(RemainingObservableWorldCount));
		CrashContext.MarkStale();
	}

	void OnSystemError()
	{
		AethelnServerObservability::HandleSystemError();
	}

	FDelegateHandle WorldTickHandle;
	FDelegateHandle WorldTickEndHandle;
	FDelegateHandle WorldCleanupHandle;
	FDelegateHandle CrashHandle;
	TSet<TWeakObjectPtr<UWorld>> SampledWorlds;
	TMap<TWeakObjectPtr<UWorld>, double> NextHealthSampleTimes;
	TMap<TWeakObjectPtr<UWorld>, double> WorldTickStartTimes;
	AethelnServerObservability::FCrashContextRegistration CrashContext;
	uint64 NextSequence = 1;
};

#if WITH_DEV_AUTOMATION_TESTS
#include "Misc/AutomationTest.h"

namespace AethelnServerObservabilityTests
{
	/** Restores only the crash GameData keys this module owns. */
	class FScopedOwnedCrashKeyRestore
	{
	public:
		FScopedOwnedCrashKeyRestore()
		{
			Save(AethelnServerObservability::CrashSchemaKey);
			Save(AethelnServerObservability::CrashLifecycleKey);
			Save(AethelnServerObservability::CrashContextStateKey);
			for (const TCHAR* Key : AethelnServerObservability::CrashContextIdentityKeys)
			{
				Save(Key);
			}
		}

		~FScopedOwnedCrashKeyRestore()
		{
			for (const TPair<FString, TOptional<FString>>& Entry : Saved)
			{
				FGenericCrashContext::SetGameData(Entry.Key, Entry.Value.IsSet() ? Entry.Value.GetValue() : FString());
			}
		}

	private:
		void Save(const TCHAR* Key)
		{
			const FString* Value = FGenericCrashContext::GetGameData().Find(Key);
			Saved.Add(Key, Value != nullptr ? TOptional<FString>(*Value) : TOptional<FString>());
		}

		TMap<FString, TOptional<FString>> Saved;
	};

	FString ReadKey(const TCHAR* Key)
	{
		const FString* Value = FGenericCrashContext::GetGameData().Find(Key);
		return Value != nullptr ? *Value : FString();
	}

	bool HasAnyIdentityKey()
	{
		for (const TCHAR* Key : AethelnServerObservability::CrashContextIdentityKeys)
		{
			if (FGenericCrashContext::GetGameData().Find(Key) != nullptr)
			{
				return true;
			}
		}
		return false;
	}

	bool AnyOwnedKeyContains(const FString& Needle)
	{
		for (const TCHAR* Key : AethelnServerObservability::CrashContextIdentityKeys)
		{
			if (ReadKey(Key).Contains(Needle))
			{
				return true;
			}
		}
		return ReadKey(AethelnServerObservability::CrashContextStateKey).Contains(Needle);
	}

	FAethelnCrashContextSnapshot MakeSnapshot(const TCHAR* Suffix)
	{
		FAethelnBuildIdentity Build;
		Build.SourceRevision = FString::Printf(TEXT("revision-%s"), Suffix);
		Build.BuildIdentity = FString::Printf(TEXT("build-%s"), Suffix);
		Build.BuildConfiguration = FString::Printf(TEXT("configuration-%s"), Suffix);
		Build.EngineRevision = FString::Printf(TEXT("engine-%s"), Suffix);
		Build.ToolchainIdentity = FString::Printf(TEXT("toolchain-%s"), Suffix);
		FAethelnNetworkProfile Profile;
		Profile.ProfileId = FString::Printf(TEXT("network-profile.%s"), Suffix);
		FAethelnCrashContextSnapshot Snapshot;
		FAethelnCrashContextSnapshot::TryMakeValidated(
			Build,
			Profile,
			EAethelnFlowKind::PrototypeAuthority,
			FString::Printf(TEXT("run-%s"), Suffix),
			FString::Printf(TEXT("instance-%s"), Suffix),
			FString::Printf(TEXT("connection-%s"), Suffix),
			Snapshot);
		return Snapshot;
	}

	/** Game world plus owning game instance, created and destroyed by the test. */
	struct FTestServerWorld
	{
		UWorld* World = nullptr;
		UGameInstance* GameInstance = nullptr;
		UAethelnObservabilitySubsystem* Subsystem = nullptr;

		bool Create(const TCHAR* RunId, const TCHAR* InstanceId)
		{
			World = UWorld::CreateWorld(EWorldType::Game, false);
			if (World == nullptr || GEngine == nullptr)
			{
				return false;
			}
			FWorldContext& WorldContext = GEngine->CreateNewWorldContext(EWorldType::Game);
			GameInstance = NewObject<UGameInstance>(GEngine);
			WorldContext.OwningGameInstance = GameInstance;
			World->SetGameInstance(GameInstance);
			WorldContext.SetCurrentWorld(World);
			GameInstance->Init();
			World->InitializeActorsForPlay(FURL());
			World->BeginPlay();
			Subsystem = GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>();
			return Subsystem != nullptr
				&& Subsystem->SetRuntimeContext(
					EAethelnFlowKind::PrototypeAuthority,
					RunId,
					InstanceId,
					AethelnObservability::ExcludedIdentifier);
		}

		void Destroy()
		{
			if (Subsystem != nullptr)
			{
				Subsystem->ResetRuntimeContext();
			}
			if (GameInstance != nullptr)
			{
				GameInstance->Shutdown();
			}
			if (World != nullptr)
			{
				World->DestroyWorld(false);
				if (GEngine != nullptr)
				{
					GEngine->DestroyWorldContext(World);
				}
			}
			World = nullptr;
			GameInstance = nullptr;
			Subsystem = nullptr;
		}
	};
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnServerCrashContextRegistrationTest,
	"Aetheln.Observability.Server.CrashContextRegistration",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnServerCrashContextRegistrationTest::RunTest(const FString& Parameters)
{
	using namespace AethelnServerObservability;
	using namespace AethelnServerObservabilityTests;
	const FScopedOwnedCrashKeyRestore Restore;

	TArray<TPair<FString, FString>> Writes;
	TSet<FString> OwnedKeys;
	OwnedKeys.Add(CrashContextStateKey);
	OwnedKeys.Add(CrashLifecycleKey);
	for (const TCHAR* Key : CrashContextIdentityKeys)
	{
		OwnedKeys.Add(Key);
	}
	const FDelegateHandle WriteHandle = FGenericCrashContext::OnGameDataSetDelegate().AddLambda(
		[&Writes, &OwnedKeys](const FString& Key, const FString& Value)
		{
			if (OwnedKeys.Contains(Key))
			{
				Writes.Emplace(Key, Value);
			}
		});

	TestEqual(TEXT("State key is stable"), FString(CrashContextStateKey), FString(TEXT("AethelnCrashContextState")));
	TestEqual(TEXT("Crash context owns exactly thirteen identity keys"), static_cast<int32>(UE_ARRAY_COUNT(CrashContextIdentityKeys)), 13);

	FCrashContextRegistration Registration;
	Registration.Initialize();
	TestEqual(TEXT("Initialization claims no run"), ReadKey(CrashContextStateKey), FString(TEXT("missing")));
	TestFalse(TEXT("Initialization leaves no identity key"), HasAnyIdentityKey());

	const FAethelnCrashContextSnapshot First = MakeSnapshot(TEXT("first"));
	TestTrue(TEXT("First fixture snapshot is bounded"), First.IsBounded());
	Writes.Reset();
	Registration.Register(&First);
	TestTrue(TEXT("First registration writes state, thirteen values, and state"), Writes.Num() == 15);
	if (Writes.Num() == 15)
	{
		TestEqual(TEXT("Registration begins with the updating state"), Writes[0].Key, FString(CrashContextStateKey));
		TestEqual(TEXT("Registration begins in updating"), Writes[0].Value, FString(TEXT("updating")));
		TestEqual(TEXT("Registration ends with the state key"), Writes.Last().Key, FString(CrashContextStateKey));
		TestEqual(TEXT("Registration ends in active"), Writes.Last().Value, FString(TEXT("active")));
	}
	TestEqual(TEXT("Active state is registered"), ReadKey(CrashContextStateKey), FString(TEXT("active")));
	TestEqual(TEXT("Schema version is registered"), ReadKey(CrashContextSchemaVersionKey), FString(TEXT("1")));
	TestEqual(TEXT("Source revision is registered"), ReadKey(CrashSourceRevisionKey), First.SourceRevision);
	TestEqual(TEXT("Build identity is registered"), ReadKey(CrashBuildIdentityKey), First.BuildIdentity);
	TestEqual(TEXT("Build configuration is registered"), ReadKey(CrashBuildConfigurationKey), First.BuildConfiguration);
	TestEqual(TEXT("Engine revision is registered"), ReadKey(CrashEngineRevisionKey), First.EngineRevision);
	TestEqual(TEXT("Toolchain identity is registered"), ReadKey(CrashToolchainIdentityKey), First.ToolchainIdentity);
	TestEqual(TEXT("Network-profile schema is registered"), ReadKey(CrashNetworkProfileSchemaKey), FString(AethelnNetworkSpike::NetworkProfileSchemaId));
	TestEqual(TEXT("Network-profile version is registered"), ReadKey(CrashNetworkProfileVersionKey), FString(TEXT("1")));
	TestEqual(TEXT("Network-profile identity is registered"), ReadKey(CrashNetworkProfileIdKey), First.NetworkProfileId);
	TestEqual(TEXT("Flow kind is registered"), ReadKey(CrashFlowKindKey), FString(TEXT("prototype-authority")));
	TestEqual(TEXT("Run is registered"), ReadKey(CrashRunIdKey), First.RunId);
	TestEqual(TEXT("Server instance is registered"), ReadKey(CrashServerInstanceKey), First.ServerInstanceId);
	TestEqual(TEXT("Connection pseudonym is registered"), ReadKey(CrashConnectionPseudonymKey), First.ConnectionPseudonym);

	const FAethelnCrashContextSnapshot Second = MakeSnapshot(TEXT("second"));
	Registration.Register(&Second);
	TestEqual(TEXT("Valid replacement is active"), ReadKey(CrashContextStateKey), FString(TEXT("active")));
	TestEqual(TEXT("Valid replacement registers the new run"), ReadKey(CrashRunIdKey), Second.RunId);
	TestFalse(TEXT("Valid replacement leaves no prior unique value"), AnyOwnedKeyContains(TEXT("first")));

	FAethelnCrashContextSnapshot Invalid = MakeSnapshot(TEXT("third"));
	Invalid.RunId = FString::Printf(TEXT("run%cthird"), TCHAR(0x2028));
	TestFalse(TEXT("Tampered snapshot is not bounded"), Invalid.IsBounded());
	Registration.Register(&Invalid);
	TestEqual(TEXT("Invalid replacement marks the context missing"), ReadKey(CrashContextStateKey), FString(TEXT("missing")));
	TestFalse(TEXT("Invalid replacement clears every identity key"), HasAnyIdentityKey());
	TestFalse(TEXT("Invalid replacement never partially overwrites"), AnyOwnedKeyContains(TEXT("third")));
	TestFalse(TEXT("Invalid replacement leaves no prior value"), AnyOwnedKeyContains(TEXT("second")));

	Registration.Register(&First);
	Registration.Register(nullptr);
	TestEqual(TEXT("Missing snapshot marks the context missing"), ReadKey(CrashContextStateKey), FString(TEXT("missing")));
	TestFalse(TEXT("Missing snapshot clears every identity key"), HasAnyIdentityKey());

	Registration.Register(&First);
	Registration.MarkStale();
	TestEqual(TEXT("Reset marks the context stale"), ReadKey(CrashContextStateKey), FString(TEXT("stale")));
	TestFalse(TEXT("Reset clears every identity key"), HasAnyIdentityKey());
	Registration.Register(&Second);
	TestEqual(TEXT("A later valid owner replaces stale context"), ReadKey(CrashContextStateKey), FString(TEXT("active")));
	TestEqual(TEXT("Stale replacement registers the later run"), ReadKey(CrashRunIdKey), Second.RunId);

	Registration.MarkAmbiguous();
	TestEqual(TEXT("Ambiguous ownership is explicit"), ReadKey(CrashContextStateKey), FString(TEXT("ambiguous")));
	TestFalse(TEXT("Ambiguous ownership clears every identity key"), HasAnyIdentityKey());
	Registration.Register(&First);
	TestEqual(TEXT("A later valid owner replaces ambiguous context"), ReadKey(CrashContextStateKey), FString(TEXT("active")));

	const TMap<FString, FString> BeforeError = FGenericCrashContext::GetGameData();
	Writes.Reset();
	HandleSystemError();
	TestEqual(TEXT("System error performs exactly one owned write"), Writes.Num(), 1);
	TestEqual(TEXT("System error changes lifecycle to crashing"), ReadKey(CrashLifecycleKey), FString(TEXT("crashing")));
	const TMap<FString, FString>& AfterError = FGenericCrashContext::GetGameData();
	for (const TPair<FString, FString>& Entry : BeforeError)
	{
		if (Entry.Key != CrashLifecycleKey)
		{
			const FString* After = AfterError.Find(Entry.Key);
			TestTrue(TEXT("System error leaves every other crash value unchanged"), After != nullptr && *After == Entry.Value);
		}
	}
	TestEqual(TEXT("System error adds no crash key"), AfterError.Num(), BeforeError.Contains(CrashLifecycleKey) ? BeforeError.Num() : BeforeError.Num() + 1);

	FGenericCrashContext::OnGameDataSetDelegate().Remove(WriteHandle);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnServerCrashContextWorldOwnershipTest,
	"Aetheln.Observability.Server.CrashContextWorldOwnership",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnServerCrashContextWorldOwnershipTest::RunTest(const FString& Parameters)
{
	using namespace AethelnServerObservability;
	using namespace AethelnServerObservabilityTests;
	const FScopedOwnedCrashKeyRestore Restore;

	FTestServerWorld First;
	FTestServerWorld Second;
	const bool bCreated = First.Create(TEXT("run-world-alpha"), TEXT("instance-world-alpha"))
		&& Second.Create(TEXT("run-world-beta"), TEXT("instance-world-beta"));
	TestTrue(TEXT("Two independent server worlds were created"), bCreated);
	if (!bCreated)
	{
		First.Destroy();
		Second.Destroy();
		return false;
	}

	FWorldDelegates::OnWorldTickStart.Broadcast(First.World, LEVELTICK_All, 0.016f);
	TestEqual(TEXT("A single observable world registers active context"), ReadKey(CrashContextStateKey), FString(TEXT("active")));
	TestEqual(TEXT("The single owner supplies the run"), ReadKey(CrashRunIdKey), FString(TEXT("run-world-alpha")));
	TestEqual(TEXT("The single owner supplies the server instance"), ReadKey(CrashServerInstanceKey), FString(TEXT("instance-world-alpha")));
	TestEqual(TEXT("Process-wide context keeps the connection excluded"), ReadKey(CrashConnectionPseudonymKey), FString(AethelnObservability::ExcludedIdentifier));
	TestEqual(TEXT("Lifecycle transition is preserved"), ReadKey(CrashLifecycleKey), FString(TEXT("world-running")));

	FWorldDelegates::OnWorldTickStart.Broadcast(Second.World, LEVELTICK_All, 0.016f);
	TestEqual(TEXT("Two observable worlds mark the context ambiguous"), ReadKey(CrashContextStateKey), FString(TEXT("ambiguous")));
	TestFalse(TEXT("Ambiguous context clears every identity key"), HasAnyIdentityKey());
	FWorldDelegates::OnWorldTickStart.Broadcast(First.World, LEVELTICK_All, 0.016f);
	TestFalse(TEXT("Ambiguous context never attributes the first run"), AnyOwnedKeyContains(TEXT("alpha")));
	TestFalse(TEXT("Ambiguous context never attributes the second run"), AnyOwnedKeyContains(TEXT("beta")));

	FWorldDelegates::OnWorldCleanup.Broadcast(First.World, true, true);
	TestEqual(TEXT("World cleanup marks the context stale"), ReadKey(CrashContextStateKey), FString(TEXT("stale")));
	TestFalse(TEXT("World cleanup clears every identity key"), HasAnyIdentityKey());
	TestEqual(TEXT("Cleanup with a remaining world preserves the running lifecycle"), ReadKey(CrashLifecycleKey), FString(TEXT("world-running")));

	FWorldDelegates::OnWorldTickStart.Broadcast(Second.World, LEVELTICK_All, 0.016f);
	TestEqual(TEXT("A later single owner replaces stale context"), ReadKey(CrashContextStateKey), FString(TEXT("active")));
	TestEqual(TEXT("The later single owner supplies its run"), ReadKey(CrashRunIdKey), FString(TEXT("run-world-beta")));
	TestFalse(TEXT("The cleaned-up owner leaves no identity"), AnyOwnedKeyContains(TEXT("alpha")));

	FWorldDelegates::OnWorldCleanup.Broadcast(Second.World, true, true);
	TestEqual(TEXT("Final cleanup marks the context stale"), ReadKey(CrashContextStateKey), FString(TEXT("stale")));
	TestFalse(TEXT("Final cleanup clears every identity key"), HasAnyIdentityKey());
	TestEqual(TEXT("Final cleanup preserves controlled shutdown"), ReadKey(CrashLifecycleKey), FString(TEXT("controlled-shutdown")));

	First.Destroy();
	Second.Destroy();
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnServerObservabilityContractTest,
	"Aetheln.Observability.Server.LifecycleHealthAndCrashContext",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnServerObservabilityContractTest::RunTest(const FString& Parameters)
{
	const AethelnServerObservabilityTests::FScopedOwnedCrashKeyRestore Restore;
	TestEqual(TEXT("Crash schema key is stable"), FString(AethelnServerObservability::CrashSchemaKey), FString(TEXT("AethelnObservabilitySchema")));
	TestEqual(TEXT("Crash lifecycle key is stable"), FString(AethelnServerObservability::CrashLifecycleKey), FString(TEXT("AethelnServerLifecycle")));
	TestEqual(
		TEXT("One remaining observable world retains the running lifecycle"),
		FString(AethelnServerObservability::GetLifecycleAfterWorldCleanup(1)),
		FString(TEXT("world-running")));
	TestEqual(
		TEXT("No remaining observable worlds enter controlled shutdown"),
		FString(AethelnServerObservability::GetLifecycleAfterWorldCleanup(0)),
		FString(TEXT("controlled-shutdown")));
	TestEqual(
		TEXT("No remaining observable worlds emit a distinct controlled-shutdown reason"),
		AethelnServerObservability::GetLifecycleReasonAfterWorldCleanup(0),
		EAethelnSafeReason::ControlledShutdown);
	TestEqual(
		TEXT("Remaining observable worlds retain the accepted lifecycle reason"),
		AethelnServerObservability::GetLifecycleReasonAfterWorldCleanup(1),
		EAethelnSafeReason::Accepted);
	const int64 TickDurationMicroseconds = AethelnServerObservability::CalculateTickDurationMicroseconds(10.0, 10.0025);
	TestEqual(TEXT("Tick duration uses monotonic start/end elapsed time"), TickDurationMicroseconds, static_cast<int64>(2500));
	TestEqual(TEXT("Backwards tick timestamps fail closed to zero"), AethelnServerObservability::CalculateTickDurationMicroseconds(10.0, 9.0), static_cast<int64>(0));
	const TArray<FAethelnMetricSample> Samples = AethelnServerObservability::MakeHealthMetrics(
		TickDurationMicroseconds,
		14,
		8,
		2,
		3,
		4,
		5);
	TestEqual(TEXT("Health snapshot has exactly seven bounded metrics"), Samples.Num(), 7);
	TestEqual(TEXT("Measured tick execution duration uses the closed metric"), Samples[0].Metric, EAethelnMetricKind::ServerTickMicroseconds);
	TestEqual(TEXT("Measured tick execution duration is preserved"), Samples[0].Value, TickDurationMicroseconds);
	TestEqual(TEXT("Actor mix preserves the closed total metric"), Samples[1].Metric, EAethelnMetricKind::ActorCount);
	TestEqual(TEXT("Actor mix records total actors"), Samples[1].Value, static_cast<int64>(14));
	TestEqual(TEXT("Actor mix preserves the closed replicated metric"), Samples[2].Metric, EAethelnMetricKind::ReplicatedActorCount);
	TestEqual(TEXT("Actor mix records replicated actors"), Samples[2].Value, static_cast<int64>(8));
	TestEqual(TEXT("Pawn classification uses a closed metric"), Samples[3].Metric, EAethelnMetricKind::PawnCount);
	TestEqual(TEXT("Pawn population remains independently distinguishable"), Samples[3].Value, static_cast<int64>(2));
	TestEqual(TEXT("Controller classification uses a closed metric"), Samples[4].Metric, EAethelnMetricKind::ControllerCount);
	TestEqual(TEXT("Controller population remains independently distinguishable"), Samples[4].Value, static_cast<int64>(3));
	TestEqual(TEXT("Player-state classification uses a closed metric"), Samples[5].Metric, EAethelnMetricKind::PlayerStateCount);
	TestEqual(TEXT("Player-state population remains observable"), Samples[5].Value, static_cast<int64>(4));
	TestEqual(TEXT("Other actor classification uses a closed metric"), Samples[6].Metric, EAethelnMetricKind::OtherActorCount);
	TestEqual(TEXT("Other actor population remains observable"), Samples[6].Value, static_cast<int64>(5));
	for (const FAethelnMetricSample& Sample : Samples)
	{
		TestEqual(TEXT("Health metrics use a closed category"), Sample.Category, EAethelnObservabilityCategory::ServerHealth);
	}
	TestTrue(TEXT("Initial health sample is due"), AethelnServerObservability::ShouldSampleHealth(0.0, 0.0));
	TestFalse(TEXT("Health sampling remains bounded between due times"), AethelnServerObservability::ShouldSampleHealth(30.0, 29.0));
	TestTrue(TEXT("Later health sample becomes due"), AethelnServerObservability::ShouldSampleHealth(30.0, 30.0));

	UWorld* World = UWorld::CreateWorld(EWorldType::Game, false);
	TestNotNull(TEXT("Server lifecycle runtime world was created"), World);
	TestNotNull(TEXT("Engine exists for server lifecycle runtime world"), GEngine);
	if (World == nullptr || GEngine == nullptr)
	{
		if (World != nullptr)
		{
			World->DestroyWorld(false);
		}
		return false;
	}

	FWorldContext& WorldContext = GEngine->CreateNewWorldContext(EWorldType::Game);
	UGameInstance* GameInstance = NewObject<UGameInstance>(GEngine);
	TestNotNull(TEXT("Server lifecycle game instance was created"), GameInstance);
	if (GameInstance == nullptr)
	{
		World->DestroyWorld(false);
		GEngine->DestroyWorldContext(World);
		return false;
	}
	WorldContext.OwningGameInstance = GameInstance;
	World->SetGameInstance(GameInstance);
	WorldContext.SetCurrentWorld(World);
	GameInstance->Init();
	World->InitializeActorsForPlay(FURL());
	World->BeginPlay();

	UAethelnObservabilitySubsystem* Subsystem = GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>();
	TSharedPtr<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe> Sink =
		MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(16);
	TestNotNull(TEXT("Server lifecycle runtime owns the observability subsystem"), Subsystem);
	if (Subsystem == nullptr
		|| !Subsystem->SetRuntimeContext(
			EAethelnFlowKind::PrototypeAuthority,
			TEXT("run-server-runtime"),
			TEXT("instance-server-runtime"),
			AethelnObservability::ExcludedIdentifier)
		|| !Subsystem->SetTestSink(Sink))
	{
		GameInstance->Shutdown();
		World->DestroyWorld(false);
		GEngine->DestroyWorldContext(World);
		return false;
	}

	FWorldDelegates::OnWorldTickStart.Broadcast(World, LEVELTICK_All, 0.016f);
	FWorldDelegates::OnWorldTickEnd.Broadcast(World, LEVELTICK_All, 0.016f);
	FWorldDelegates::OnWorldCleanup.Broadcast(World, true, true);
	TestTrue(TEXT("Actual server world delegates drain lifecycle and health evidence"), Subsystem->WaitForIdleForTests());
	const TArray<FAethelnObservabilityEvent> RuntimeEvents = Sink->GetEvents();
	TestEqual(TEXT("Actual server world delegates emit start, health, and shutdown events"), RuntimeEvents.Num(), 3);
	if (RuntimeEvents.Num() == 3)
	{
		TestEqual(TEXT("World-start delegate emits server lifecycle"), RuntimeEvents[0].Category, EAethelnObservabilityCategory::ServerLifecycle);
		TestEqual(TEXT("World-tick delegate emits server health"), RuntimeEvents[1].Category, EAethelnObservabilityCategory::ServerHealth);
		TestEqual(TEXT("World-cleanup delegate emits server lifecycle"), RuntimeEvents[2].Category, EAethelnObservabilityCategory::ServerLifecycle);
		TestEqual(TEXT("World-cleanup delegate emits controlled shutdown"), RuntimeEvents[2].SafeReason, EAethelnSafeReason::ControlledShutdown);
	}
	TestEqual(TEXT("Actual server health delegate emits seven metrics"), Sink->GetMetrics().Num(), 7);

	Subsystem->ResetSink();
	Subsystem->ResetRuntimeContext();
	GameInstance->Shutdown();
	World->DestroyWorld(false);
	GEngine->DestroyWorldContext(World);
	return true;
}
#endif

IMPLEMENT_MODULE(FAethelnGameServerModule, GameServer);
