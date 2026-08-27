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
		const bool bRequiresAbility = bCombatActivationSubject
			|| SubjectCategory == EAethelnObservabilityCategory::Cooldown
			|| SubjectCategory == EAethelnObservabilityCategory::Dodge
			|| SubjectCategory == EAethelnObservabilityCategory::Block;
		return (!bRequiresActivation || !ActivationId.IsEmpty())
			&& (!bRequiresAbility || !AbilityId.IsEmpty())
			&& Sequence != 0
			&& AethelnObservability::IsSafeIdentifier(ConnectionPseudonym)
			&& AethelnObservability::IsSafeIdentifier(ActivationId)
			&& AethelnObservability::IsSafeIdentifier(AbilityId);
	}
};

UCLASS()
class GAMENET_API UAethelnObservabilitySubsystem final : public UGameInstanceSubsystem
{
	GENERATED_BODY()

public:
	using FSinkPtr = FAethelnObservabilityService::FSinkPtr;
	using FRestrictedSinkPtr = FAethelnObservabilityService::FRestrictedSinkPtr;

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
	FAethelnObservabilityService Service;
	FAethelnObservabilityRuntimeContext RuntimeContext;
	FAethelnBuildIdentity BuildIdentity;
	FAethelnNetworkProfile NetworkProfile;
	EAethelnEnvironment MetricEnvironment = EAethelnEnvironment::Local;
	bool bHasRuntimeContext = false;
	bool bHasBuildContext = false;
	bool bHasValidEnvironment = true;
};
