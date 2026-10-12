#pragma once

#include "CoreMinimal.h"
#include "Templates/Function.h"

class FJsonObject;
class IAssetRegistry;
class USkeletalMesh;
class UTexture;

/** Exact lowercase SHA-256 text check, defined once so a unity build cannot see two copies. */
inline bool IsLowerSha256(const FString& Value)
{
	if (Value.Len() != 64)
	{
		return false;
	}
	for (const TCHAR Character : Value)
	{
		if (!((Character >= TEXT('0') && Character <= TEXT('9')) || (Character >= TEXT('a') && Character <= TEXT('f'))))
		{
			return false;
		}
	}
	return true;
}

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
	/** Asset Registry NotGame (editor-only) references; recorded and allowed. */
	TArray<FString> EditorOnlyDependencies;
	/** Live-scan failures for runtime (Game) dependencies whose target is editor-only content. */
	TArray<FString> EditorOnlyRuntimeDependencyFailures;
	/** Runtime (Game) dependencies of a UBlueprint-class package on UncookedOnly-only script packages; recorded, not failed. */
	TArray<FString> RecordedUncookedOnlyDependencies;
	FString ContentSha256;
	bool bRedirector = false;
};

/** Why a dependency target is editor-only content; an empty Reason means runtime content. */
struct FAethelnEditorOnlyTarget
{
	FString Reason;
	/** A loaded /Script package flagged PKG_UncookedOnly and not PKG_EditorOnly. */
	bool bUncookedOnlyScript = false;
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

	/** Classifies whether a dependency target is editor-only content. */
	static FAethelnEditorOnlyTarget ClassifyEditorOnlyTarget(IAssetRegistry& Registry, const FString& TargetPackage);

	/**
	 * Applies the classifier to runtime (hard and soft Game) dependencies only; NotGame references are never failures.
	 * A UBlueprint-class package's UncookedOnly-only script targets go to OutRecorded instead of the failures.
	 */
	static TArray<FString> SelectEditorOnlyRuntimeDependencyFailures(
		const FAethelnObservedPackage& Package,
		TFunctionRef<FAethelnEditorOnlyTarget(const FString& TargetPackage)> ClassifyTarget,
		TArray<FString>& OutRecorded);

	/**
	 * Returns a failure for every ungoverned /Game target of a runtime (hard or soft Game) dependency.
	 * An ungoverned NotGame /Game target is recorded in OutRecorded instead of failing.
	 */
	static TArray<FString> SelectBrokenGameReferences(
		const FAethelnObservedPackage& Package,
		TFunctionRef<bool(const FString& TargetPackage)> IsGoverned,
		TArray<FString>& OutRecorded);

	/** Records the texture family facts, reading size and mips from the editor source data. */
	static void CollectTextureFacts(
		const UTexture& Texture,
		bool bDataValid,
		const FString& ValidationEvidence,
		TMap<FString, TArray<FAethelnContentCheckFacts>>& OutFacts);

	/** Records the skeletal mesh collision facts; the PhysicsAsset bodies are the collision source. */
	static void CollectSkeletalMeshCollisionFacts(
		const USkeletalMesh& SkeletalMesh,
		bool bDataValid,
		const FString& SkeletalEvidence,
		TMap<FString, TArray<FAethelnContentCheckFacts>>& OutFacts);

	/** Derives the closed v2 status vocabulary from typed observed facts. */
	static FAethelnContentFamilyResult EvaluateFamilyFacts(
		const FString& FamilyId,
		const TArray<FAethelnContentCheckFacts>& Facts,
		bool bLifecycleBlocksPromotion);

private:
	static bool ScanLiveRegistry(TArray<FAethelnObservedPackage>& OutPackages, FString& OutFailure);
};
