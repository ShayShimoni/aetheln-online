#pragma once

#include "AethelnObservability.h"
#include "Subsystems/GameInstanceSubsystem.h"

#include "AethelnObservabilitySubsystem.generated.h"

struct GAMENET_API FAethelnObservabilityRuntimeContext
{
	EAethelnFlowKind FlowKind = EAethelnFlowKind::PrototypeAuthority;
	FString RunId;
	FString InstanceId;
	FString ConnectionPseudonym;

	bool IsValid() const
	{
		return !RunId.IsEmpty()
			&& !InstanceId.IsEmpty()
			&& !ConnectionPseudonym.IsEmpty()
			&& IsKnown(FlowKind)
			&& AethelnObservability::IsSafeIdentifier(RunId)
			&& AethelnObservability::IsSafeIdentifier(InstanceId)
			&& AethelnObservability::IsSafeIdentifier(ConnectionPseudonym);
	}
};

struct GAMENET_API FAethelnObservabilityEventContext
{
	/** Optional authority-owned per-connection override; empty uses the runtime default. */
	FString ConnectionPseudonym;
	FString ActivationId;
	FString AbilityId;
	uint64 Sequence = 0;

	bool IsValid(EAethelnObservabilityCategory Category) const
	{
		const EAethelnObservabilityCategory DefaultSubject = Category == EAethelnObservabilityCategory::Rejection
			? EAethelnObservabilityCategory::Ability
			: Category;
		return IsValid(Category, DefaultSubject);
	}

	bool IsValid(
		EAethelnObservabilityCategory Category,
		EAethelnObservabilityCategory SubjectCategory) const
	{
		const bool bCombatActivationSubject = SubjectCategory == EAethelnObservabilityCategory::Ability
			|| SubjectCategory == EAethelnObservabilityCategory::Hit;
		const bool bRequiresActivation = Category != EAethelnObservabilityCategory::Rejection
			&& bCombatActivationSubject;
		const bool bRequiresAbility = Category != EAethelnObservabilityCategory::Rejection
			&& (bCombatActivationSubject
				|| SubjectCategory == EAethelnObservabilityCategory::Cooldown
				|| SubjectCategory == EAethelnObservabilityCategory::Dodge
				|| SubjectCategory == EAethelnObservabilityCategory::Block);
		return (!bRequiresActivation || !ActivationId.IsEmpty())
			&& (!bRequiresAbility || !AbilityId.IsEmpty())
			&& Sequence != 0
			&& AethelnObservability::IsSafeIdentifier(ConnectionPseudonym)
			&& AethelnObservability::IsSafeIdentifier(ActivationId)
			&& AethelnObservability::IsSafeIdentifier(AbilityId);
	}
};

DECLARE_MULTICAST_DELEGATE_OneParam(FAethelnCrashContextChanged, const class UAethelnObservabilitySubsystem&);

UCLASS()
class GAMENET_API UAethelnObservabilitySubsystem final : public UGameInstanceSubsystem
{
	GENERATED_BODY()

public:
	using FSinkPtr = FAethelnObservabilityService::FSinkPtr;
	using FRestrictedSinkPtr = FAethelnObservabilityService::FRestrictedSinkPtr;

	/** Game-thread broadcast after an accepted runtime/build context change or reset. Reentrant
	 * setters during marker publication are rejected; resets are deferred until publication ends. */
	static FAethelnCrashContextChanged& OnCrashContextChanged();

	virtual void Deinitialize() override;

	bool SetRuntimeContext(
		EAethelnFlowKind FlowKind,
		const FString& RunId,
		const FString& InstanceId,
		const FString& ConnectionPseudonym);
	void ResetRuntimeContext();
	bool HasRuntimeContext() const;
	bool SetBuildContext(const FAethelnBuildIdentity& BuildIdentity, const FAethelnNetworkProfile& NetworkProfile);
	void ResetBuildContext();
	bool HasBuildContext() const;
	bool SetEnvironment(const FString& EnvironmentName);
	/**
	 * Game-thread closed crash snapshot, available once runtime and build/profile context are set; leaves
	 * output unchanged on failure. Carries only closed, engine-owned, and generated values, never the
	 * caller-supplied run, instance, build, or profile text that event correlation keeps.
	 */
	bool TryGetCrashContextSnapshot(FAethelnCrashContextSnapshot& OutSnapshot) const;

	bool TryComposeCorrelation(
		EAethelnObservabilityCategory Category,
		const FAethelnObservabilityEventContext& EventContext,
		FAethelnCorrelationContext& OutCorrelation) const;
	bool TryComposeCorrelation(
		EAethelnObservabilityCategory Category,
		EAethelnObservabilityCategory SubjectCategory,
		const FAethelnObservabilityEventContext& EventContext,
		FAethelnCorrelationContext& OutCorrelation) const;

	bool SetTestSink(FSinkPtr Sink);
	bool SetTestRestrictedSink(FRestrictedSinkPtr Sink);
	void ResetSink();
	void ResetRestrictedSink();
	bool WaitForIdleForTests(double TimeoutSeconds = 2.0) const;

	void EmitEvent(
		const FAethelnObservabilityEvent& Event,
		const FAethelnObservabilityEventContext& EventContext) const;
	void EmitMetric(const FAethelnMetricSample& Sample) const;

private:
	friend class FAethelnCrashContextOwner;
	/** Claims the log marker once for the current generated crash run, including after world reassociation. */
	bool TryClaimCrashRunMarker(const FString& CandidateCrashRunId);
	/** Shields marker-before-active publication from synchronous log callback mutations. */
	bool BeginCrashRunMarkerPublication(const FString& CandidateCrashRunId);
	void EndCrashRunMarkerPublication();
	void ClearRuntimeContextWithoutBroadcast();
	void ClearBuildContextWithoutBroadcast();
	enum class EDeferredCrashReset : uint8
	{
		Runtime,
		Build
	};
	FAethelnObservabilityService Service;
	FAethelnObservabilityRuntimeContext RuntimeContext;
	/** Opaque crash run ID generated on every accepted runtime context; empty after reset. */
	FString CrashRunId;
	bool bCrashRunMarkerClaimed = false;
	FAethelnBuildIdentity BuildIdentity;
	FAethelnNetworkProfile NetworkProfile;
	TArray<EDeferredCrashReset, TInlineAllocator<8>> DeferredCrashResets;
	bool bDeferredCrashResetOverflow = false;
	bool bPublishingCrashRunMarker = false;
	bool bFailingClosedCrashReset = false;
	EAethelnEnvironment MetricEnvironment = EAethelnEnvironment::Local;
	bool bHasRuntimeContext = false;
	bool bHasBuildContext = false;
	bool bHasValidEnvironment = true;
};

class UGameInstance;
class UWorld;

namespace AethelnCrashContext
{
	inline constexpr TCHAR StateKey[] = TEXT("AethelnCrashContextState");
	inline constexpr TCHAR SchemaVersionKey[] = TEXT("AethelnCrashContextSchemaVersion");
	inline constexpr TCHAR SourceRevisionKey[] = TEXT("AethelnSourceRevision");
	inline constexpr TCHAR BuildIdentityKey[] = TEXT("AethelnBuildIdentity");
	inline constexpr TCHAR BuildConfigurationKey[] = TEXT("AethelnBuildConfiguration");
	inline constexpr TCHAR EngineRevisionKey[] = TEXT("AethelnEngineRevision");
	inline constexpr TCHAR ToolchainIdentityKey[] = TEXT("AethelnToolchainIdentity");
	inline constexpr TCHAR NetworkProfileSchemaKey[] = TEXT("AethelnNetworkProfileSchema");
	inline constexpr TCHAR NetworkProfileVersionKey[] = TEXT("AethelnNetworkProfileVersion");
	inline constexpr TCHAR NetworkProfileIdKey[] = TEXT("AethelnNetworkProfileId");
	inline constexpr TCHAR FlowKindKey[] = TEXT("AethelnFlowKind");
	inline constexpr TCHAR CrashRunIdKey[] = TEXT("AethelnCrashRunId");
	inline constexpr TCHAR ServerInstanceKey[] = TEXT("AethelnServerInstance");
	inline constexpr TCHAR ConnectionPseudonymKey[] = TEXT("AethelnConnectionPseudonym");
	inline constexpr const TCHAR* IdentityKeys[] = {
		SchemaVersionKey,
		SourceRevisionKey,
		BuildIdentityKey,
		BuildConfigurationKey,
		EngineRevisionKey,
		ToolchainIdentityKey,
		NetworkProfileSchemaKey,
		NetworkProfileVersionKey,
		NetworkProfileIdKey,
		FlowKindKey,
		CrashRunIdKey,
		ServerInstanceKey,
		ConnectionPseudonymKey
	};

	enum class EState : uint8
	{
		Missing,
		Updating,
		Active,
		Ambiguous,
		Stale
	};

	GAMENET_API const TCHAR* StateToString(EState State);
	GAMENET_API UAethelnObservabilitySubsystem* FindObservabilitySubsystem(const UWorld* World);
}

/**
 * Owns the Issue #148 crash GameData keys and the set of observable worlds.
 * Every value is registered before failure; the state key is written first on
 * clear and last on registration so an interrupted update never reads as active.
 * Game thread only.
 */
class GAMENET_API FAethelnCrashContextOwner
{
public:
	enum class EWorldTickAdmissionResult : uint8
	{
		Rejected,
		ExistingWorld,
		NewWorld
	};
	class FWorldTickAdmission
	{
	public:
		FWorldTickAdmission() = default;
	private:
		friend class FAethelnCrashContextOwner;
		const FAethelnCrashContextOwner* Owner = nullptr;
		TWeakObjectPtr<const UWorld> World;
		uint64 Serial = 0;
		bool bNewWorld = false;
	};

	FAethelnCrashContextOwner() = default;
	FAethelnCrashContextOwner(const FAethelnCrashContextOwner&) = delete;
	FAethelnCrashContextOwner& operator=(const FAethelnCrashContextOwner&) = delete;
	~FAethelnCrashContextOwner();

	/** Clears to missing and refreshes on every accepted context change of the sole tracked world. */
	void Initialize();
	/** Unbinds, forgets every world, and clears to stale. */
	void Shutdown();
	/** Called by the server's engine pre-change hook before the world association changes. */
	void BeginWorldGameInstanceTransition(const UWorld* World);
	/** Called by the server's engine post-change hook; denial remains until a new completed tick. */
	void EndWorldGameInstanceTransition(const UWorld* World);
	/** Count before configuration and mint one opaque, one-use capability per world tick. */
	EWorldTickAdmissionResult BeginWorldTickAdmission(const UWorld* World, FWorldTickAdmission& OutAdmission);
	/** Complete only the exact admitted tick after server configuration and stable association. */
	bool CompleteWorldTickAdmission(const FWorldTickAdmission& Admission);
	/** Abandon only the exact admitted tick and fail closed if server configuration cannot finish. */
	bool AbortWorldTickAdmission(const FWorldTickAdmission& Admission);
	/** Counts an observable world before any subsystem lookup; returns true on first sight. */
	bool TrackWorldTick(const UWorld* World);
	/** Stops tracking a world and clears to stale. */
	void EndTracking(const UWorld* World);
	/** Re-reads only a tracked world's current subsystem after its association changes. */
	void RefreshForTrackedWorld(const UWorld* World);
	bool IsTracked(const UWorld* World) const;
	int32 NumTrackedWorlds() const;
	/** Only the tracked-world refresh may register; direct calls fail missing without subsystem provenance. */
	void Register(const FAethelnCrashContextSnapshot* Snapshot);
	void MarkStale();
	void MarkAmbiguous();
	AethelnCrashContext::EState GetState() const;

private:
	enum class ERequestedUpdate : uint8
	{
		None,
		Refresh,
		Missing,
		Stale,
		Ambiguous
	};
	void RequestUpdate(ERequestedUpdate Update);
	void Refresh();
	void OnContextChanged(const UAethelnObservabilitySubsystem& Changed);
	const UWorld* GetSoleTrackedWorld() const;
	bool IsWorldGameInstanceTransitioning(const UWorld* World) const;
	void MarkTransitionStaleIfNeeded(const UWorld* World);
	void DenyTrackedWorldsUntilNextCompletion();
	void SetState(AethelnCrashContext::EState NewState);
	void ClearIdentity(AethelnCrashContext::EState NewState);

	TSet<TWeakObjectPtr<const UWorld>> TrackedWorlds;
	TMap<TWeakObjectPtr<const UWorld>, uint64> PendingWorldTickAdmissions;
	/** An aborted tick cannot be refreshed into active before a later exact completion. */
	TSet<TWeakObjectPtr<const UWorld>> DeniedWorldTickAdmissions;
	TSet<TWeakObjectPtr<const UWorld>> WorldsInGameInstanceTransition;
	uint64 NextWorldTickAdmissionSerial = 0;
	AethelnCrashContext::EState State = AethelnCrashContext::EState::Missing;
	TWeakObjectPtr<const UWorld> ActiveWorld;
	TWeakObjectPtr<const UGameInstance> ActiveGameInstance;
	TWeakObjectPtr<UAethelnObservabilitySubsystem> ActiveSubsystem;
	FString ActiveCrashRunId;
	TWeakObjectPtr<UAethelnObservabilitySubsystem> RegistrationSubsystem;
	ERequestedUpdate PendingUpdate = ERequestedUpdate::None;
	uint64 UpdateSerial = 0;
	uint64 ApplyingSerial = 0;
	bool bApplyingUpdate = false;
	bool bInvalidatingReentrantActive = false;
	bool bAllowRegistration = false;
	FDelegateHandle ChangedHandle;
};
