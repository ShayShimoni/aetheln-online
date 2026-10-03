#pragma once

#include "CoreMinimal.h"

class FJsonObject;

struct FAethelnBuildArtifactDescriptor
{
	FString Path;
	int64 SizeBytes = 0;
	FString Sha256;
	FString BuildId;
};

struct FAethelnContentValidationRunArguments
{
	FString ReportPath;
	FString PolicyPath;
	FString IntakePath;
	FString Revision;
	FString EngineRevision;
	FString EngineTag;
	FString EngineBinarySha256;
	FString BuildVersionSha256;
	FString Target;
	FString Platform;
	FString Configuration;
	FString EditorBuildCommandSha256;
	FString EditorBuildLogSha256;
	FString CompilerVersion;
	FString CompilerSha256;
	FString ResourceCompilerVersion;
	FString ResourceCompilerSha256;
	FAethelnBuildArtifactDescriptor TargetReceipt;
	FAethelnBuildArtifactDescriptor ModuleManifest;
	FString ProjectSha256;
	FString PolicySha256;
	FString IntakeSha256;
	FString InvocationSha256;
	FString StartedUtc;
	FString RegistrySource;
	FString RegistrySnapshotPath;
	FString RegistrySnapshotSha256;
	bool bAllowTestRegistrySnapshot = false;
};

struct FAethelnObservedPackage
{
	FString PackageName;
	FString RepositoryPath;
	TArray<FString> ClassPaths;
	TMap<FString, FString> Tags;
	TArray<FString> HardDependencies;
	TArray<FString> SoftDependencies;
	TArray<FString> EditorOnlyDependencies;
	FString ContentSha256;
	bool bRedirector = false;
};

struct FAethelnSoftReferenceRule
{
	FString Id;
	FString SourcePackagePattern;
	FString SourceAudience;
	FString TargetPackagePattern;
	FString TargetAudience;
	FString Justification;
};

struct FAethelnContentCheckFacts
{
	FString CheckId;
	bool bApplicable = false;
	TMap<FString, bool> BooleanFacts;
	TMap<FString, int64> IntegerFacts;
	TMap<FString, double> DecimalFacts;
	TMap<FString, FString> TextFacts;
	bool bHasUnresolvedThreshold = false;
	FString Evidence;
};

struct FAethelnContentCheckResult
{
	FString CheckId;
	FString Applicability;
	FString DeterministicStatus;
	FString PromotionStatus;
	FString Evidence;
};

struct FAethelnContentFamilyResult
{
	FString PolicyId;
	FString Applicability;
	FString DeterministicStatus;
	FString PromotionStatus;
	FString Evidence;
	TArray<FAethelnContentCheckResult> CheckResults;
};

/** Read-only Asset Registry scanner and report writer used by the commandlet. */
class FAethelnContentValidationScanner
{
public:
	/** Returns 0 for passed/non-promotion evidence and non-zero for validation or infrastructure failure. */
	static int32 Run(const FAethelnContentValidationRunArguments& Arguments, FString& OutFailure);

	/** Shared parser used by guarded injected-snapshot automation coverage. */
	static bool ParseRegistrySnapshot(
		const FString& SnapshotJson,
		TArray<FAethelnObservedPackage>& OutPackages,
		FString& OutFailure);

	/** Verifies a guarded snapshot digest and parses the exact verified UTF-8 bytes. */
	static bool LoadVerifiedRegistrySnapshot(
		const FString& SnapshotPath,
		const FString& ExpectedSha256,
		TArray<FAethelnObservedPackage>& OutPackages,
		FString& OutFailure);

	/** Derives applicability only from observed Asset Registry class and tag facts. */
	static TSet<FString> DeriveApplicableFamilies(const FAethelnObservedPackage& Package);

	/** Applies the policy's anchored source/target path and audience rule. */
	static bool IsSoftReferenceAllowed(
		const FString& SourcePackage,
		const FString& SourceAudience,
		const FString& TargetPackage,
		const FString& TargetAudience,
		const TArray<FAethelnSoftReferenceRule>& Rules);

	/** Derives the closed v2 status vocabulary from typed observed facts. */
	static FAethelnContentFamilyResult EvaluateFamilyFacts(
		const FString& FamilyId,
		const TArray<FAethelnContentCheckFacts>& Facts,
		bool bLifecycleBlocksPromotion);

private:
	static bool ScanLiveRegistry(TArray<FAethelnObservedPackage>& OutPackages, FString& OutFailure);
};
