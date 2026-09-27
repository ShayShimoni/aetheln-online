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
	inline constexpr double PrototypeHealthSampleIntervalSeconds = 30.0;

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
		NextHealthSampleTimes.Reset();
		WorldTickStartTimes.Reset();
		FGenericCrashContext::SetGameData(AethelnServerObservability::CrashLifecycleKey, TEXT("module-stopped"));
		CrashContext.Shutdown();
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

		// The world is counted before its subsystem is looked up; configuring context
		// afterwards refreshes crash registration through the accepted-change broadcast.
		if (CrashContext.TrackWorldTick(World))
		{
			NextHealthSampleTimes.Add(World, 0.0);
			if (UAethelnObservabilitySubsystem* Subsystem = AethelnCrashContext::FindObservabilitySubsystem(World))
			{
				AethelnServerObservability::ConfigureContext(*Subsystem);
				AethelnServerObservability::EmitEvent(
					*Subsystem,
					EAethelnObservabilityCategory::ServerLifecycle,
					EAethelnSafeReason::Accepted,
					NextSequence++);
			}
			FGenericCrashContext::SetGameData(AethelnServerObservability::CrashLifecycleKey, TEXT("world-running"));
		}
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
		const int32 RemainingObservableWorldCount = CrashContext.IsTracked(World)
			? CrashContext.NumTrackedWorlds() - 1
			: CrashContext.NumTrackedWorlds();
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
		NextHealthSampleTimes.Remove(World);
		WorldTickStartTimes.Remove(World);
		FGenericCrashContext::SetGameData(
			AethelnServerObservability::CrashLifecycleKey,
			AethelnServerObservability::GetLifecycleAfterWorldCleanup(RemainingObservableWorldCount));
		CrashContext.EndTracking(World);
	}

	void OnSystemError()
	{
		AethelnServerObservability::HandleSystemError();
	}

	FDelegateHandle WorldTickHandle;
	FDelegateHandle WorldTickEndHandle;
	FDelegateHandle WorldCleanupHandle;
	FDelegateHandle CrashHandle;
	TMap<TWeakObjectPtr<UWorld>, double> NextHealthSampleTimes;
	TMap<TWeakObjectPtr<UWorld>, double> WorldTickStartTimes;
	FAethelnCrashContextOwner CrashContext;
	uint64 NextSequence = 1;
};

#if WITH_DEV_AUTOMATION_TESTS
#include "Misc/AutomationTest.h"

namespace AethelnServerObservabilityTests
{
	/** Restores only the crash GameData keys this module and its crash-context owner write. */
	class FScopedOwnedCrashKeyRestore
	{
	public:
		FScopedOwnedCrashKeyRestore()
		{
			Save(AethelnServerObservability::CrashSchemaKey);
			Save(AethelnServerObservability::CrashLifecycleKey);
			Save(AethelnCrashContext::StateKey);
			for (const TCHAR* Key : AethelnCrashContext::IdentityKeys)
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
}

// World-independent, so it is safe in the Server target, which lists GameServer.
IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnServerSystemErrorTest,
	"Aetheln.Observability.Server.SystemErrorLifecycleOnly",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::ServerContext | EAutomationTestFlags::EngineFilter)

bool FAethelnServerSystemErrorTest::RunTest(const FString& Parameters)
{
	using namespace AethelnServerObservability;
	const AethelnServerObservabilityTests::FScopedOwnedCrashKeyRestore Restore;

	TestEqual(TEXT("Crash lifecycle key is stable"), FString(CrashLifecycleKey), FString(TEXT("AethelnServerLifecycle")));
	int32 Writes = 0;
	const FDelegateHandle WriteHandle = FGenericCrashContext::OnGameDataSetDelegate().AddLambda(
		[&Writes](const FString&, const FString&)
		{
			++Writes;
		});
	const TMap<FString, FString> BeforeError = FGenericCrashContext::GetGameData();
	HandleSystemError();
	FGenericCrashContext::OnGameDataSetDelegate().Remove(WriteHandle);

	TestEqual(TEXT("System error performs exactly one crash GameData write"), Writes, 1);
	const FString* Lifecycle = FGenericCrashContext::GetGameData().Find(CrashLifecycleKey);
	TestTrue(TEXT("System error changes lifecycle to crashing"), Lifecycle != nullptr && *Lifecycle == TEXT("crashing"));
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
