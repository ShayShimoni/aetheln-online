#include "AethelnObservability.h"

#include "Async/Async.h"
#include "Containers/Queue.h"
#include "HAL/CriticalSection.h"
#include "HAL/PlatformProcess.h"
#include "HAL/PlatformTime.h"
#include "Misc/ScopeLock.h"

#include <atomic>

DEFINE_LOG_CATEGORY_STATIC(LogAethelnObservability, Log, All);

namespace AethelnStructuredLog
{
	FString EscapeIdentifier(const FString& Value)
	{
		FString Result = Value.Left(AethelnObservability::MaxIdentifierLength);
		Result.ReplaceInline(TEXT("\\"), TEXT("\\\\"), ESearchCase::CaseSensitive);
		Result.ReplaceInline(TEXT("\""), TEXT("\\\""), ESearchCase::CaseSensitive);
		Result.ReplaceInline(TEXT("\r"), TEXT("\\r"), ESearchCase::CaseSensitive);
		Result.ReplaceInline(TEXT("\n"), TEXT("\\n"), ESearchCase::CaseSensitive);
		Result.ReplaceInline(TEXT("\t"), TEXT("\\t"), ESearchCase::CaseSensitive);
		return Result;
	}
}

struct FAethelnObservabilityService::FDispatchState final
	: public TSharedFromThis<FAethelnObservabilityService::FDispatchState, ESPMode::ThreadSafe>
{
	enum class EPublicWorkKind : uint8
	{
		Event,
		Metric
	};

	struct FPublicWork
	{
		EPublicWorkKind Kind = EPublicWorkKind::Event;
		FAethelnObservabilityEvent Event;
		FAethelnMetricSample Metric;
		FSinkPtr Sink;
		bool bRoutineMovement = false;
	};

	struct FRestrictedWork
	{
		FAethelnObservabilityEvent Event;
		FRestrictedSinkPtr Sink;
	};

	FDispatchState(FSinkPtr InPublicSink, FRestrictedSinkPtr InRestrictedSink, int32 InCapacity)
		: PublicSink(MoveTemp(InPublicSink))
		, RestrictedSink(MoveTemp(InRestrictedSink))
		, Capacity(FMath::Clamp(InCapacity, 0, AethelnObservability::MaxPendingDispatchItems))
	{
	}

	bool SetPublicSink(FSinkPtr InSink)
	{
		if (!InSink.IsValid())
		{
			return false;
		}
		FScopeLock Lock(&SinkMutex);
		PublicSink = MoveTemp(InSink);
		return true;
	}

	bool SetRestrictedSink(FRestrictedSinkPtr InSink)
	{
		if (!InSink.IsValid())
		{
			return false;
		}
		FScopeLock Lock(&SinkMutex);
		RestrictedSink = MoveTemp(InSink);
		return true;
	}

	bool EnqueuePublicEvent(const FAethelnObservabilityEvent& Event)
	{
		FPublicWork Work;
		Work.Kind = EPublicWorkKind::Event;
		Work.Event = Event;
		Work.bRoutineMovement = IsRoutineMovementEvent(Event);
		{
			FScopeLock SinkLock(&SinkMutex);
			Work.Sink = PublicSink;
			FScopeLock DispatchLock(&PublicDispatchMutex);
			if (Work.bRoutineMovement)
			{
				if (!TryReserve(PublicRoutinePending, PublicRoutineDropped))
				{
					return false;
				}
				PublicRoutineQueue.Enqueue(MoveTemp(Work));
			}
			else
			{
				if (!TryReserve(PublicPending, PublicDropped))
				{
					return false;
				}
				PublicQueue.Enqueue(MoveTemp(Work));
			}
			SchedulePublicLocked();
		}
		return true;
	}

	bool EnqueuePublicMetric(const FAethelnMetricSample& Metric)
	{
		FPublicWork Work;
		Work.Kind = EPublicWorkKind::Metric;
		Work.Metric = Metric;
		Work.bRoutineMovement = IsRoutineMovementMetric(Metric);
		{
			FScopeLock SinkLock(&SinkMutex);
			Work.Sink = PublicSink;
			FScopeLock DispatchLock(&PublicDispatchMutex);
			if (Work.bRoutineMovement)
			{
				if (!TryReserve(PublicRoutinePending, PublicRoutineDropped))
				{
					return false;
				}
				PublicRoutineQueue.Enqueue(MoveTemp(Work));
			}
			else
			{
				if (!TryReserve(PublicPending, PublicDropped))
				{
					return false;
				}
				PublicQueue.Enqueue(MoveTemp(Work));
			}
			SchedulePublicLocked();
		}
		return true;
	}

	bool EnqueueRestrictedEvent(const FAethelnObservabilityEvent& Event)
	{
		FRestrictedWork Work;
		Work.Event = Event;
		{
			FScopeLock SinkLock(&SinkMutex);
			Work.Sink = RestrictedSink;
			FScopeLock DispatchLock(&RestrictedDispatchMutex);
			if (!TryReserve(RestrictedPending, RestrictedDropped))
			{
				return false;
			}
			RestrictedQueue.Enqueue(MoveTemp(Work));
			ScheduleRestrictedLocked();
		}
		return true;
	}

	bool WaitForPublicIdle(double TimeoutSeconds) const
	{
		return WaitForIdle(PublicPending, PublicRoutinePending, TimeoutSeconds);
	}

	bool WaitForRestrictedIdle(double TimeoutSeconds) const
	{
		return WaitForIdle(RestrictedPending, TimeoutSeconds);
	}

	int32 GetPublicPending() const
	{
		return PublicPending.load(std::memory_order_acquire)
			+ PublicRoutinePending.load(std::memory_order_acquire);
	}
	int32 GetRestrictedPending() const { return RestrictedPending.load(std::memory_order_acquire); }
	uint64 GetPublicDropped() const
	{
		return PublicDropped.load(std::memory_order_relaxed)
			+ PublicRoutineDropped.load(std::memory_order_relaxed);
	}
	uint64 GetRestrictedDropped() const { return RestrictedDropped.load(std::memory_order_relaxed); }

private:
	static bool IsRoutineMovementEvent(const FAethelnObservabilityEvent& Event)
	{
		return Event.Category == EAethelnObservabilityCategory::Movement
			&& Event.SubjectCategory == EAethelnObservabilityCategory::Movement
			&& Event.SafeReason == EAethelnSafeReason::Accepted;
	}

	static bool IsRoutineMovementMetric(const FAethelnMetricSample& Metric)
	{
		return Metric.Metric == EAethelnMetricKind::EventCount
			&& Metric.Category == EAethelnObservabilityCategory::Movement
			&& Metric.Reason == EAethelnSafeReason::Accepted;
	}

	bool TryReserve(std::atomic<int32>& Pending, std::atomic<uint64>& Dropped) const
	{
		int32 Current = Pending.load(std::memory_order_relaxed);
		while (Current < Capacity)
		{
			if (Pending.compare_exchange_weak(
				Current,
				Current + 1,
				std::memory_order_acq_rel,
				std::memory_order_relaxed))
			{
				return true;
			}
		}
		Dropped.fetch_add(1, std::memory_order_relaxed);
		return false;
	}

	static bool WaitForIdle(const std::atomic<int32>& Pending, double TimeoutSeconds)
	{
		const double Deadline = FPlatformTime::Seconds() + FMath::Max(0.0, TimeoutSeconds);
		do
		{
			if (Pending.load(std::memory_order_acquire) == 0)
			{
				return true;
			}
			FPlatformProcess::SleepNoStats(0.001f);
		}
		while (FPlatformTime::Seconds() < Deadline);
		return Pending.load(std::memory_order_acquire) == 0;
	}

	static bool WaitForIdle(
		const std::atomic<int32>& FirstPending,
		const std::atomic<int32>& SecondPending,
		double TimeoutSeconds)
	{
		const double Deadline = FPlatformTime::Seconds() + FMath::Max(0.0, TimeoutSeconds);
		do
		{
			if (FirstPending.load(std::memory_order_acquire) == 0
				&& SecondPending.load(std::memory_order_acquire) == 0)
			{
				return true;
			}
			FPlatformProcess::SleepNoStats(0.001f);
		}
		while (FPlatformTime::Seconds() < Deadline);
		return FirstPending.load(std::memory_order_acquire) == 0
			&& SecondPending.load(std::memory_order_acquire) == 0;
	}

	void SchedulePublicLocked()
	{
		if (!bPublicWorkerScheduled)
		{
			bPublicWorkerScheduled = true;
			TSharedRef<FDispatchState, ESPMode::ThreadSafe> State = AsShared();
			(void)Async(EAsyncExecution::ThreadPool, [State]() { State->DrainPublic(); });
		}
	}

	void ScheduleRestrictedLocked()
	{
		if (!bRestrictedWorkerScheduled)
		{
			bRestrictedWorkerScheduled = true;
			TSharedRef<FDispatchState, ESPMode::ThreadSafe> State = AsShared();
			(void)Async(EAsyncExecution::ThreadPool, [State]() { State->DrainRestricted(); });
		}
	}

	void DrainPublic()
	{
		for (;;)
		{
			ReportPublicQueueDrops();
			FPublicWork Work;
			{
				FScopeLock DispatchLock(&PublicDispatchMutex);
				if (!PublicQueue.Dequeue(Work) && !PublicRoutineQueue.Dequeue(Work))
				{
					bPublicWorkerScheduled = false;
					return;
				}
			}

			bool bRecorded = false;
			if (Work.Sink.IsValid())
			{
				if (Work.Kind == EPublicWorkKind::Event)
				{
					bRecorded = Work.Sink->TryRecordEvent(Work.Event);
				}
				else
				{
					bRecorded = Work.Sink->TryRecordMetric(Work.Metric);
				}
			}
			if (!bRecorded)
			{
				++PublicSinkFailures;
				ReportDispatchFailure(
					LexToString(EAethelnMetricKind::SinkFailureCount),
					TEXT("public"),
					TEXT("sink-write"),
					Work.bRoutineMovement ? TEXT("routine-movement") : TEXT("critical"),
					1,
					PublicSinkFailures);
			}
			std::atomic<int32>& Pending = Work.bRoutineMovement ? PublicRoutinePending : PublicPending;
			Pending.fetch_sub(1, std::memory_order_release);
		}
	}

	void DrainRestricted()
	{
		for (;;)
		{
			ReportRestrictedQueueDrops();
			FRestrictedWork Work;
			{
				FScopeLock DispatchLock(&RestrictedDispatchMutex);
				if (!RestrictedQueue.Dequeue(Work))
				{
					bRestrictedWorkerScheduled = false;
					return;
				}
			}

			bool bRecorded = false;
			if (Work.Sink.IsValid())
			{
				bRecorded = Work.Sink->TryRecordEvent(Work.Event);
			}
			if (!bRecorded)
			{
				++RestrictedSinkFailures;
				ReportDispatchFailure(
					LexToString(EAethelnMetricKind::SinkFailureCount),
					TEXT("restricted"),
					TEXT("sink-write"),
					TEXT("restricted"),
					1,
					RestrictedSinkFailures);
			}
			RestrictedPending.fetch_sub(1, std::memory_order_release);
		}
	}

	static void ReportDispatchFailure(
		const TCHAR* MetricName,
		const TCHAR* Channel,
		const TCHAR* FailureKind,
		const TCHAR* WorkClass,
		uint64 Delta,
		uint64 Total)
	{
		UE_LOG(
			LogAethelnObservability,
			Warning,
			TEXT("dispatch_failure metric=\"%s\" channel=\"%s\" kind=\"%s\" work_class=\"%s\" delta=%llu total=%llu"),
			MetricName,
			Channel,
			FailureKind,
			WorkClass,
			Delta,
			Total);
	}

	void ReportPublicQueueDrops()
	{
		const uint64 CriticalTotal = PublicDropped.load(std::memory_order_acquire);
		if (CriticalTotal > PublicDroppedReported)
		{
			ReportDispatchFailure(
				LexToString(EAethelnMetricKind::QueueDropCount),
				TEXT("public"),
				TEXT("queue-drop"),
				TEXT("critical"),
				CriticalTotal - PublicDroppedReported,
				CriticalTotal);
			PublicDroppedReported = CriticalTotal;
		}

		const uint64 RoutineTotal = PublicRoutineDropped.load(std::memory_order_acquire);
		if (RoutineTotal > PublicRoutineDroppedReported)
		{
			ReportDispatchFailure(
				LexToString(EAethelnMetricKind::QueueDropCount),
				TEXT("public"),
				TEXT("queue-drop"),
				TEXT("routine-movement"),
				RoutineTotal - PublicRoutineDroppedReported,
				RoutineTotal);
			PublicRoutineDroppedReported = RoutineTotal;
		}
	}

	void ReportRestrictedQueueDrops()
	{
		const uint64 Total = RestrictedDropped.load(std::memory_order_acquire);
		if (Total > RestrictedDroppedReported)
		{
			ReportDispatchFailure(
				LexToString(EAethelnMetricKind::QueueDropCount),
				TEXT("restricted"),
				TEXT("queue-drop"),
				TEXT("restricted"),
				Total - RestrictedDroppedReported,
				Total);
			RestrictedDroppedReported = Total;
		}
	}

	mutable FCriticalSection SinkMutex;
	FCriticalSection PublicDispatchMutex;
	FCriticalSection RestrictedDispatchMutex;
	FSinkPtr PublicSink;
	FRestrictedSinkPtr RestrictedSink;
	const int32 Capacity;
	TQueue<FPublicWork, EQueueMode::Mpsc> PublicQueue;
	TQueue<FPublicWork, EQueueMode::Mpsc> PublicRoutineQueue;
	TQueue<FRestrictedWork, EQueueMode::Mpsc> RestrictedQueue;
	std::atomic<int32> PublicPending { 0 };
	std::atomic<int32> PublicRoutinePending { 0 };
	std::atomic<int32> RestrictedPending { 0 };
	std::atomic<uint64> PublicDropped { 0 };
	std::atomic<uint64> PublicRoutineDropped { 0 };
	std::atomic<uint64> RestrictedDropped { 0 };
	uint64 PublicDroppedReported = 0;
	uint64 PublicRoutineDroppedReported = 0;
	uint64 RestrictedDroppedReported = 0;
	uint64 PublicSinkFailures = 0;
	uint64 RestrictedSinkFailures = 0;
	bool bPublicWorkerScheduled = false;
	bool bRestrictedWorkerScheduled = false;
};

FAethelnObservabilityService::FAethelnObservabilityService()
	: FAethelnObservabilityService(
		MakeShared<FAethelnStructuredLogObservabilitySink, ESPMode::ThreadSafe>(),
		MakeShared<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe>())
{
}

FAethelnObservabilityService::FAethelnObservabilityService(FSinkPtr InSink)
	: FAethelnObservabilityService(
		InSink.IsValid()
			? MoveTemp(InSink)
			: MakeShared<FAethelnStructuredLogObservabilitySink, ESPMode::ThreadSafe>(),
		MakeShared<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe>())
{
}

FAethelnObservabilityService::FAethelnObservabilityService(
	FSinkPtr InSink,
	FRestrictedSinkPtr InRestrictedSink)
	: FAethelnObservabilityService(
		MoveTemp(InSink),
		MoveTemp(InRestrictedSink),
		AethelnObservability::MaxPendingDispatchItems)
{
}

FAethelnObservabilityService::FAethelnObservabilityService(
	FSinkPtr InSink,
	FRestrictedSinkPtr InRestrictedSink,
	int32 InDispatchCapacity)
{
	if (!InSink.IsValid())
	{
		InSink = MakeShared<FAethelnStructuredLogObservabilitySink, ESPMode::ThreadSafe>();
	}
	if (!InRestrictedSink.IsValid())
	{
		InRestrictedSink = MakeShared<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe>();
	}
	DispatchState = MakeShared<FDispatchState, ESPMode::ThreadSafe>(
		MoveTemp(InSink),
		MoveTemp(InRestrictedSink),
		InDispatchCapacity);
}

FAethelnObservabilityService::~FAethelnObservabilityService() = default;

bool FAethelnObservabilityService::SetSink(FSinkPtr InSink)
{
	return DispatchState->SetPublicSink(MoveTemp(InSink));
}

bool FAethelnObservabilityService::SetRestrictedSink(FRestrictedSinkPtr InSink)
{
	return DispatchState->SetRestrictedSink(MoveTemp(InSink));
}

void FAethelnObservabilityService::ResetSink()
{
	DispatchState->SetPublicSink(
		MakeShared<FAethelnStructuredLogObservabilitySink, ESPMode::ThreadSafe>());
}

void FAethelnObservabilityService::ResetRestrictedSink()
{
	DispatchState->SetRestrictedSink(
		MakeShared<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe>());
}

void FAethelnObservabilityService::EmitEvent(const FAethelnObservabilityEvent& Event) const
{
	if (!Event.IsBounded())
	{
		return;
	}
	DispatchState->EnqueueRestrictedEvent(Event);
	DispatchState->EnqueuePublicEvent(Event.MakePublicCopy());
}

void FAethelnObservabilityService::EmitMetric(const FAethelnMetricSample& Sample) const
{
	DispatchState->EnqueuePublicMetric(Sample);
}

bool FAethelnObservabilityService::WaitForIdleForTests(double TimeoutSeconds) const
{
	const double StartSeconds = FPlatformTime::Seconds();
	if (!WaitForPublicIdleForTests(TimeoutSeconds))
	{
		return false;
	}
	const double RemainingSeconds = FMath::Max(
		0.0,
		TimeoutSeconds - (FPlatformTime::Seconds() - StartSeconds));
	return WaitForRestrictedIdleForTests(RemainingSeconds);
}

bool FAethelnObservabilityService::WaitForPublicIdleForTests(double TimeoutSeconds) const
{
	return DispatchState->WaitForPublicIdle(TimeoutSeconds);
}

bool FAethelnObservabilityService::WaitForRestrictedIdleForTests(double TimeoutSeconds) const
{
	return DispatchState->WaitForRestrictedIdle(TimeoutSeconds);
}

int32 FAethelnObservabilityService::GetPublicPendingCountForTests() const
{
	return DispatchState->GetPublicPending();
}

int32 FAethelnObservabilityService::GetRestrictedPendingCountForTests() const
{
	return DispatchState->GetRestrictedPending();
}

uint64 FAethelnObservabilityService::GetPublicDroppedCountForTests() const
{
	return DispatchState->GetPublicDropped();
}

uint64 FAethelnObservabilityService::GetRestrictedDroppedCountForTests() const
{
	return DispatchState->GetRestrictedDropped();
}

bool FAethelnStructuredLogObservabilitySink::TryRecordEvent(
	const FAethelnObservabilityEvent& Event)
{
	if (!Event.IsBounded())
	{
		return false;
	}

	const FAethelnObservabilityEvent PublicEvent = Event.MakePublicCopy();
	UE_LOG(
		LogAethelnObservability,
		Log,
		TEXT("event schema=\"%s\" version=%u category=\"%s\" subject=\"%s\" reason=\"%s\" flow=\"%s\" run=\"%s\" connection=\"%s\" instance=\"%s\" activation=\"%s\" ability=\"%s\" sequence=%llu source_revision=\"%s\" build=\"%s\" configuration=\"%s\" engine=\"%s\" toolchain=\"%s\" network_profile=\"%s\""),
		*AethelnStructuredLog::EscapeIdentifier(PublicEvent.SchemaId),
		PublicEvent.SchemaVersion,
		LexToString(PublicEvent.Category),
		LexToString(PublicEvent.SubjectCategory),
		LexToString(PublicEvent.SafeReason),
		LexToString(PublicEvent.Correlation.FlowKind),
		*AethelnStructuredLog::EscapeIdentifier(PublicEvent.Correlation.RunId),
		*AethelnStructuredLog::EscapeIdentifier(PublicEvent.Correlation.ConnectionPseudonym),
		*AethelnStructuredLog::EscapeIdentifier(PublicEvent.Correlation.InstanceId),
		*AethelnStructuredLog::EscapeIdentifier(PublicEvent.Correlation.ActivationId),
		*AethelnStructuredLog::EscapeIdentifier(PublicEvent.Correlation.AbilityId),
		PublicEvent.Correlation.Sequence,
		*AethelnStructuredLog::EscapeIdentifier(PublicEvent.Build.SourceRevision),
		*AethelnStructuredLog::EscapeIdentifier(PublicEvent.Build.BuildIdentity),
		*AethelnStructuredLog::EscapeIdentifier(PublicEvent.Build.BuildConfiguration),
		*AethelnStructuredLog::EscapeIdentifier(PublicEvent.Build.EngineRevision),
		*AethelnStructuredLog::EscapeIdentifier(PublicEvent.Build.ToolchainIdentity),
		*AethelnStructuredLog::EscapeIdentifier(PublicEvent.NetworkProfile.ProfileId));
	return true;
}

bool FAethelnStructuredLogObservabilitySink::TryRecordMetric(
	const FAethelnMetricSample& Sample)
{
	UE_LOG(
		LogAethelnObservability,
		Log,
		TEXT("metric name=\"%s\" category=\"%s\" reason=\"%s\" environment=\"%s\" value=%lld"),
		LexToString(Sample.Metric),
		LexToString(Sample.Category),
		LexToString(Sample.Reason),
		LexToString(Sample.Environment),
		Sample.Value);
	return true;
}
