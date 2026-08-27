#include "AethelnObservability.h"
#include "AethelnObservabilitySubsystem.h"
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
}

class FAethelnGameServerModule final : public IModuleInterface
{
public:
	virtual void StartupModule() override
	{
		FGenericCrashContext::SetGameData(AethelnServerObservability::CrashSchemaKey, AethelnObservability::SchemaId);
		FGenericCrashContext::SetGameData(AethelnServerObservability::CrashLifecycleKey, TEXT("module-started"));
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

		AethelnServerObservability::ConfigureContext(*Subsystem);
		if (!SampledWorlds.Contains(World))
		{
			SampledWorlds.Add(World);
			NextHealthSampleTimes.Add(World, 0.0);
			AethelnServerObservability::EmitEvent(
				*Subsystem,
				EAethelnObservabilityCategory::ServerLifecycle,
				EAethelnSafeReason::Accepted,
				NextSequence++);
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
		if (UGameInstance* GameInstance = World->GetGameInstance())
		{
			if (UAethelnObservabilitySubsystem* Subsystem = GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>())
			{
				AethelnServerObservability::EmitEvent(
					*Subsystem,
					EAethelnObservabilityCategory::ServerLifecycle,
					EAethelnSafeReason::Accepted,
					NextSequence++);
			}
		}
		SampledWorlds.Remove(World);
		NextHealthSampleTimes.Remove(World);
		WorldTickStartTimes.Remove(World);
		FGenericCrashContext::SetGameData(
			AethelnServerObservability::CrashLifecycleKey,
			AethelnServerObservability::GetLifecycleAfterWorldCleanup(SampledWorlds.Num()));
	}

	void OnSystemError()
	{
		FGenericCrashContext::SetGameData(AethelnServerObservability::CrashLifecycleKey, TEXT("crashing"));
	}

	FDelegateHandle WorldTickHandle;
	FDelegateHandle WorldTickEndHandle;
	FDelegateHandle WorldCleanupHandle;
	FDelegateHandle CrashHandle;
	TSet<TWeakObjectPtr<UWorld>> SampledWorlds;
	TMap<TWeakObjectPtr<UWorld>, double> NextHealthSampleTimes;
	TMap<TWeakObjectPtr<UWorld>, double> WorldTickStartTimes;
	uint64 NextSequence = 1;
};

#if WITH_DEV_AUTOMATION_TESTS
#include "Misc/AutomationTest.h"

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnServerObservabilityContractTest,
	"Aetheln.Observability.Server.LifecycleHealthAndCrashContext",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnServerObservabilityContractTest::RunTest(const FString& Parameters)
{
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
	return true;
}
#endif

IMPLEMENT_MODULE(FAethelnGameServerModule, GameServer);
