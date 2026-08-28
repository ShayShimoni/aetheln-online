#include "AethelnObservability.h"

#if WITH_DEV_AUTOMATION_TESTS
#include "Async/Async.h"
#include "HAL/Event.h"
#include "HAL/PlatformProcess.h"
#include "Misc/AutomationTest.h"

#include <atomic>

namespace AethelnSinkGenerationTests
{
	FAethelnObservabilityEvent MakeEvent(uint64 Sequence)
	{
		FAethelnObservabilityEvent Event;
		Event.Category = EAethelnObservabilityCategory::ServerLifecycle;
		Event.SubjectCategory = EAethelnObservabilityCategory::ServerLifecycle;
		Event.SafeReason = EAethelnSafeReason::Accepted;
		Event.Correlation.RunId = TEXT("run-generation");
		Event.Correlation.ConnectionPseudonym = AethelnObservability::ExcludedIdentifier;
		Event.Correlation.InstanceId = TEXT("instance-generation");
		Event.Correlation.Sequence = Sequence;
		return Event;
	}

	class FBlockingRestrictedSink final : public IAethelnRestrictedAuditSink
	{
	public:
		FBlockingRestrictedSink()
			: Entered(FPlatformProcess::GetSynchEventFromPool(true))
			, Release(FPlatformProcess::GetSynchEventFromPool(true))
		{
		}

		virtual ~FBlockingRestrictedSink() override
		{
			Release->Trigger();
			FPlatformProcess::ReturnSynchEventToPool(Entered);
			FPlatformProcess::ReturnSynchEventToPool(Release);
		}

		virtual bool TryRecordEvent(const FAethelnObservabilityEvent&) override
		{
			const int32 Call = Calls.fetch_add(1, std::memory_order_relaxed) + 1;
			if (Call == 1)
			{
				Entered->Trigger();
				Release->Wait();
			}
			return true;
		}

		bool WaitUntilEntered() const { return Entered->Wait(2000); }
		void ReleaseFirstWrite() { Release->Trigger(); }
		int32 GetCalls() const { return Calls.load(std::memory_order_relaxed); }

	private:
		FEvent* Entered;
		FEvent* Release;
		std::atomic<int32> Calls { 0 };
	};

	class FBlockingPublicSink final : public IAethelnObservabilitySink
	{
	public:
		FBlockingPublicSink()
			: Entered(FPlatformProcess::GetSynchEventFromPool(true))
			, Release(FPlatformProcess::GetSynchEventFromPool(true))
		{
		}

		virtual ~FBlockingPublicSink() override
		{
			Release->Trigger();
			FPlatformProcess::ReturnSynchEventToPool(Entered);
			FPlatformProcess::ReturnSynchEventToPool(Release);
		}

		virtual bool TryRecordEvent(const FAethelnObservabilityEvent&) override
		{
			const int32 Call = Calls.fetch_add(1, std::memory_order_relaxed) + 1;
			if (Call == 1)
			{
				Entered->Trigger();
				Release->Wait();
			}
			return true;
		}

		virtual bool TryRecordMetric(const FAethelnMetricSample&) override { return true; }
		bool WaitUntilEntered() const { return Entered->Wait(2000); }
		void ReleaseFirstWrite() { Release->Trigger(); }
		int32 GetCalls() const { return Calls.load(std::memory_order_relaxed); }

	private:
		FEvent* Entered;
		FEvent* Release;
		std::atomic<int32> Calls { 0 };
	};
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnObservabilitySinkGenerationIsolationTest,
	"Aetheln.Observability.Contracts.SinkGenerationIsolation",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnObservabilitySinkGenerationIsolationTest::RunTest(const FString& Parameters)
{
	using namespace AethelnSinkGenerationTests;

	TSharedPtr<FBlockingRestrictedSink, ESPMode::ThreadSafe> OldRestricted =
		MakeShared<FBlockingRestrictedSink, ESPMode::ThreadSafe>();
	TSharedPtr<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe> Public =
		MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(8);
	FAethelnObservabilityService RestrictedReplacement(Public, OldRestricted, 4);
	RestrictedReplacement.EmitEvent(MakeEvent(1));
	TestTrue(TEXT("Old restricted generation blocks its first write"), OldRestricted->WaitUntilEntered());
	RestrictedReplacement.EmitEvent(MakeEvent(2));
	TSharedPtr<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe> NewRestricted =
		MakeShared<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe>(4);
	TestTrue(TEXT("Restricted sink replacement remains non-blocking"), RestrictedReplacement.SetRestrictedSink(NewRestricted));
	RestrictedReplacement.EmitEvent(MakeEvent(3));
	TestTrue(TEXT("Accepted restricted work remains capacity bounded"), RestrictedReplacement.GetRestrictedPendingCountForTests() <= 4);
	OldRestricted->ReleaseFirstWrite();
	TestTrue(TEXT("Restricted generations drain"), RestrictedReplacement.WaitForIdleForTests());
	TestEqual(TEXT("Queued restricted work stays with its enqueue-time sink"), OldRestricted->GetCalls(), 2);
	TestEqual(TEXT("Later restricted work uses the replacement sink"), NewRestricted->GetEvents().Num(), 1);

	TSharedPtr<FBlockingRestrictedSink, ESPMode::ThreadSafe> ResetRestricted =
		MakeShared<FBlockingRestrictedSink, ESPMode::ThreadSafe>();
	FAethelnObservabilityService RestrictedReset(Public, ResetRestricted, 4);
	RestrictedReset.EmitEvent(MakeEvent(4));
	TestTrue(TEXT("Reset scenario blocks the old restricted generation"), ResetRestricted->WaitUntilEntered());
	RestrictedReset.EmitEvent(MakeEvent(5));
	RestrictedReset.ResetRestrictedSink();
	RestrictedReset.EmitEvent(MakeEvent(6));
	ResetRestricted->ReleaseFirstWrite();
	TestTrue(TEXT("Restricted reset generations drain"), RestrictedReset.WaitForIdleForTests());
	TestEqual(TEXT("Reset cannot redirect already accepted restricted work"), ResetRestricted->GetCalls(), 2);

	TSharedPtr<FBlockingPublicSink, ESPMode::ThreadSafe> OldPublic =
		MakeShared<FBlockingPublicSink, ESPMode::ThreadSafe>();
	TSharedPtr<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe> Restricted =
		MakeShared<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe>(8);
	FAethelnObservabilityService PublicReplacement(OldPublic, Restricted, 4);
	PublicReplacement.EmitEvent(MakeEvent(7));
	TestTrue(TEXT("Old public generation blocks its first write"), OldPublic->WaitUntilEntered());
	PublicReplacement.EmitEvent(MakeEvent(8));
	TSharedPtr<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe> NewPublic =
		MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(4);
	TestTrue(TEXT("Public sink replacement remains non-blocking"), PublicReplacement.SetSink(NewPublic));
	PublicReplacement.EmitEvent(MakeEvent(9));
	OldPublic->ReleaseFirstWrite();
	TestTrue(TEXT("Public generations drain"), PublicReplacement.WaitForIdleForTests());
	TestEqual(TEXT("Queued public work stays with its enqueue-time sink"), OldPublic->GetCalls(), 2);
	TestEqual(TEXT("Later public work uses the replacement sink"), NewPublic->GetEvents().Num(), 1);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnObservabilityConcurrentDrainSchedulingTest,
	"Aetheln.Observability.Contracts.ConcurrentDrainScheduling",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnObservabilityConcurrentDrainSchedulingTest::RunTest(const FString& Parameters)
{
	using namespace AethelnSinkGenerationTests;

	constexpr int32 RoundCount = 32;
	constexpr int32 ProducerCount = 4;
	constexpr int32 ExpectedEventCount = RoundCount * ProducerCount;
	constexpr int32 ExpectedPublicWorkCount = ExpectedEventCount * 2;

	TSharedPtr<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe> Public =
		MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(ExpectedPublicWorkCount);
	TSharedPtr<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe> Restricted =
		MakeShared<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe>(ExpectedEventCount);
	FAethelnObservabilityService Service(Public, Restricted, ExpectedPublicWorkCount);

	for (int32 Round = 0; Round < RoundCount; ++Round)
	{
		TArray<TFuture<void>> Producers;
		Producers.Reserve(ProducerCount);
		for (int32 Producer = 0; Producer < ProducerCount; ++Producer)
		{
			const uint64 Sequence = static_cast<uint64>((Round * ProducerCount) + Producer + 1);
			Producers.Add(Async(EAsyncExecution::ThreadPool, [&Service, Sequence]()
			{
				FAethelnObservabilityEvent Event = MakeEvent(Sequence);
				Event.DiagnosticCode = EAethelnDiagnosticCode::ValidationFailed;
				Service.EmitEvent(Event);

				FAethelnMetricSample Metric;
				Metric.Category = EAethelnObservabilityCategory::ServerLifecycle;
				Metric.Reason = EAethelnSafeReason::Accepted;
				Service.EmitMetric(Metric);
			}));
		}

		for (TFuture<void>& Producer : Producers)
		{
			Producer.Wait();
		}
		TestTrue(TEXT("Concurrent accepted work reaches idle at every drain boundary"), Service.WaitForIdleForTests());
	}

	TestEqual(TEXT("Concurrent public work is accepted without capacity drops"), Service.GetPublicDroppedCountForTests(), static_cast<uint64>(0));
	TestEqual(TEXT("Concurrent restricted work is accepted without capacity drops"), Service.GetRestrictedDroppedCountForTests(), static_cast<uint64>(0));
	TestEqual(TEXT("All accepted public events eventually drain"), Public->GetEvents().Num(), ExpectedEventCount);
	TestEqual(TEXT("All accepted public metrics eventually drain"), Public->GetMetrics().Num(), ExpectedEventCount);
	TestEqual(TEXT("All accepted restricted events eventually drain"), Restricted->GetEvents().Num(), ExpectedEventCount);
	TestEqual(TEXT("No accepted public work remains pending"), Service.GetPublicPendingCountForTests(), 0);
	TestEqual(TEXT("No accepted restricted work remains pending"), Service.GetRestrictedPendingCountForTests(), 0);
	return true;
}
#endif
