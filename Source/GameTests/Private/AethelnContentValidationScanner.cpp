#include "AethelnContentValidationScanner.h"

#include "AethelnPrimaryAssetDefinition.h"
#include "Animation/AnimationAsset.h"
#include "Animation/AnimSequence.h"
#include "Animation/Skeleton.h"
#include "AssetRegistry/AssetData.h"
#include "AssetRegistry/AssetRegistryModule.h"
#include "AssetRegistry/IAssetRegistry.h"
#include "Dom/JsonObject.h"
#include "Components/CapsuleComponent.h"
#include "Engine/Blueprint.h"
#include "Engine/SkeletalMesh.h"
#include "Engine/SkeletalMeshSocket.h"
#include "Engine/StaticMesh.h"
#include "Engine/Texture.h"
#include "Engine/Texture2D.h"
#include "Engine/World.h"
#include "Engine/Level.h"
#include "GameFramework/WorldSettings.h"
#include "GameFramework/Character.h"
#include "HAL/FileManager.h"
#include "HAL/PlatformMisc.h"
#include "Internationalization/Regex.h"
#include "Materials/MaterialInstance.h"
#include "Materials/MaterialInterface.h"
#include "Materials/Material.h"
#include "Misc/DataValidation.h"
#include "Misc/FileHelper.h"
#include "Misc/PackageName.h"
#include "Misc/Paths.h"
#include "Modules/ModuleManifest.h"
#include "Modules/ModuleManager.h"
#include "NavigationData.h"
#include "PhysicsEngine/BodySetup.h"
#include "PhysicsEngine/PhysicsAsset.h"
#include "Serialization/JsonReader.h"
#include "Serialization/JsonSerializer.h"
#include "TargetReceipt.h"
#include "UObject/GarbageCollection.h"
#include "UObject/ObjectMacros.h"
#include "UObject/Package.h"
#include "UObject/UObjectGlobals.h"
#include "WorldPartition/DataLayer/DataLayerManager.h"
#include "WorldPartition/WorldPartition.h"

#if PLATFORM_WINDOWS
#include "Windows/WindowsHWrapper.h"
#endif

#if AETHELN_CONTENT_VALIDATION_WITH_OPENSSL
THIRD_PARTY_INCLUDES_START
#include <openssl/sha.h>
THIRD_PARTY_INCLUDES_END
#endif

namespace
{
	bool WriteReportToRetainedHandle(const FString& Json, FString& OutFailure)
	{
#if PLATFORM_WINDOWS
		const FString HandleText = FPlatformMisc::GetEnvironmentVariable(TEXT("AETHELN_CONTENT_VALIDATION_REPORT_HANDLE"));
		TCHAR* End = nullptr;
		const uint64 HandleValue = FCString::Strtoui64(*HandleText, &End, 10);
		if (HandleText.IsEmpty() || HandleValue == 0 || End == nullptr || *End != TEXT('\0'))
		{
			OutFailure = TEXT("The retained report output handle is missing or invalid.");
			return false;
		}
		HANDLE Handle = reinterpret_cast<HANDLE>(static_cast<UPTRINT>(HandleValue));
		LARGE_INTEGER Start{};
		if (!SetFilePointerEx(Handle, Start, nullptr, FILE_BEGIN) || !SetEndOfFile(Handle))
		{
			OutFailure = FString::Printf(TEXT("Could not reset the retained report output (Win32 %lu)."), GetLastError());
			return false;
		}
		FTCHARToUTF8 Utf8(*Json);
		const uint8* Cursor = reinterpret_cast<const uint8*>(Utf8.Get());
		int64 Remaining = Utf8.Length();
		while (Remaining > 0)
		{
			const DWORD Requested = static_cast<DWORD>(FMath::Min<int64>(Remaining, MAX_uint32));
			DWORD Written = 0;
			if (!WriteFile(Handle, Cursor, Requested, &Written, nullptr) || Written != Requested)
			{
				OutFailure = FString::Printf(TEXT("Could not write the retained report output (Win32 %lu)."), GetLastError());
				return false;
			}
			Cursor += Written;
			Remaining -= Written;
		}
		if (!FlushFileBuffers(Handle))
		{
			OutFailure = FString::Printf(TEXT("Could not flush the retained report output (Win32 %lu)."), GetLastError());
			return false;
		}
		return true;
#else
		OutFailure = TEXT("Retained report output writing is supported only on Windows.");
		return false;
#endif
	}

	const TArray<FString> GovernedFamilies = {
		TEXT("collision"),
		TEXT("rendering_suitability"),
		TEXT("texture"),
		TEXT("material"),
		TEXT("skeletal_animation"),
		TEXT("map_world"),
		TEXT("navigation"),
		TEXT("reference_boundary")
	};

	TArray<FString> GetExpectedChecks(const FString& FamilyId)
	{
		if (FamilyId == TEXT("collision")) { return { TEXT("profile"), TEXT("simple_complex_policy"), TEXT("presentation_equivalence") }; }
		if (FamilyId == TEXT("rendering_suitability")) { return { TEXT("lod"), TEXT("hlod"), TEXT("nanite_suitability"), TEXT("streaming") }; }
		if (FamilyId == TEXT("texture")) { return { TEXT("pbr_channels"), TEXT("tiling"), TEXT("compression"), TEXT("mips"), TEXT("streaming") }; }
		if (FamilyId == TEXT("material")) { return { TEXT("material_instance_policy"), TEXT("shader_complexity_evidence") }; }
		if (FamilyId == TEXT("skeletal_animation")) { return { TEXT("rig_compatibility"), TEXT("morph_policy"), TEXT("influences"), TEXT("socket_ownership"), TEXT("animation_complexity") }; }
		if (FamilyId == TEXT("map_world")) { return { TEXT("map_identity"), TEXT("data_layers"), TEXT("pcg_authority"), TEXT("runtime_editor_boundary") }; }
		if (FamilyId == TEXT("navigation")) { return { TEXT("navigation_data_audience"), TEXT("streaming_boundaries"), TEXT("runtime_rebuild_policy") }; }
		if (FamilyId == TEXT("reference_boundary")) { return { TEXT("stable_id_unique"), TEXT("redirectors"), TEXT("broken_references"), TEXT("compatible_content_version"), TEXT("audience_reachability"), TEXT("hard_reference_exceptions") }; }
		return {};
	}

	struct FSourceGroup
	{
		FString Id;
		FString AuthorOrProvider;
		FString SourceRecord;
		FString SourceVersion;
		FString LicenseOrPermissionEvidence;
		FString Modifications;
		FString GenerationMetadata;
		FString Reviewer;
		FString ApprovalState;
		FString NamingOwner;
		FString ImportSettingsRecord;
		FString ReimportSettingsRecord;
	};

	struct FIntakeAsset
	{
		FString AssetPath;
		FString RepositoryPath;
		FString StableId;
		int32 ContentVersion = 0;
		FString Audience;
		FString LifecycleState;
		FString SourceGroupId;
		FString ContentSha256;
		TSharedPtr<FJsonObject> LifecycleEvidence;
	};

	struct FPolicyData
	{
		TMap<FString, FString> FailureCodes;
		TMap<FString, TArray<FString>> ChecksByFamily;
		TMap<FString, TSet<FString>> HardAudienceRules;
		TArray<FAethelnSoftReferenceRule> SoftReferenceRules;
	};

	bool IsNonBlank(const FString& Value)
	{
		return !Value.TrimStartAndEnd().IsEmpty();
	}

	bool RequireExactFields(
		const TSharedPtr<FJsonObject>& Object,
		const TArray<FString>& Fields,
		const FString& Context,
		FString& OutFailure)
	{
		if (!Object.IsValid())
		{
			OutFailure = Context + TEXT(" must be a JSON object.");
			return false;
		}
		for (const FString& Field : Fields)
		{
			if (!Object->HasField(Field))
			{
				OutFailure = FString::Printf(TEXT("%s is missing required field '%s'."), *Context, *Field);
				return false;
			}
		}
		if (Object->Values.Num() != Fields.Num())
		{
			OutFailure = FString::Printf(TEXT("%s contains unsupported fields."), *Context);
			return false;
		}
		return true;
	}

	bool RequireString(
		const TSharedPtr<FJsonObject>& Object,
		const TCHAR* Field,
		const FString& Context,
		FString& OutValue,
		FString& OutFailure)
	{
		if (!Object->TryGetStringField(Field, OutValue) || !IsNonBlank(OutValue))
		{
			OutFailure = FString::Printf(TEXT("%s.%s must be a non-blank string."), *Context, Field);
			return false;
		}
		return true;
	}

	bool RequireStringArray(
		const TSharedPtr<FJsonObject>& Object,
		const TCHAR* Field,
		const FString& Context,
		TArray<FString>& OutValues,
		FString& OutFailure,
		bool bMayBeEmpty = true)
	{
		const TArray<TSharedPtr<FJsonValue>>* Values = nullptr;
		if (!Object->TryGetArrayField(Field, Values) || Values == nullptr)
		{
			OutFailure = FString::Printf(TEXT("%s.%s must be an array."), *Context, Field);
			return false;
		}
		if (!bMayBeEmpty && Values->IsEmpty())
		{
			OutFailure = FString::Printf(TEXT("%s.%s must not be empty."), *Context, Field);
			return false;
		}
		TSet<FString> Unique;
		for (int32 Index = 0; Index < Values->Num(); ++Index)
		{
			FString Value;
			if (!(*Values)[Index].IsValid() || !(*Values)[Index]->TryGetString(Value) || !IsNonBlank(Value))
			{
				OutFailure = FString::Printf(TEXT("%s.%s[%d] must be a non-blank string."), *Context, Field, Index);
				return false;
			}
			bool bAlreadyPresent = false;
			Unique.Add(Value, &bAlreadyPresent);
			if (bAlreadyPresent)
			{
				OutFailure = FString::Printf(TEXT("%s.%s contains duplicate value '%s'."), *Context, Field, *Value);
				return false;
			}
			OutValues.Add(MoveTemp(Value));
		}
		OutValues.Sort();
		return true;
	}

	bool ParseJsonDocument(const FString& Json, TSharedPtr<FJsonObject>& OutObject, FString& OutFailure)
	{
		const TSharedRef<TJsonReader<>> Reader = TJsonReaderFactory<>::Create(Json);
		if (!FJsonSerializer::Deserialize(Reader, OutObject) || !OutObject.IsValid())
		{
			OutFailure = FString::Printf(TEXT("JSON document is malformed: %s"), *Reader->GetErrorMessage());
			return false;
		}
		return true;
	}

	bool IsStrictUtf8(const TArray<uint8>& Bytes)
	{
		for (int32 Index = 0; Index < Bytes.Num();)
		{
			const uint8 Lead = Bytes[Index++];
			if (Lead <= 0x7f) { continue; }
			int32 Continuations = 0;
			uint8 MinimumSecond = 0x80;
			uint8 MaximumSecond = 0xbf;
			if (Lead >= 0xc2 && Lead <= 0xdf) { Continuations = 1; }
			else if (Lead >= 0xe0 && Lead <= 0xef)
			{
				Continuations = 2;
				if (Lead == 0xe0) { MinimumSecond = 0xa0; }
				if (Lead == 0xed) { MaximumSecond = 0x9f; }
			}
			else if (Lead >= 0xf0 && Lead <= 0xf4)
			{
				Continuations = 3;
				if (Lead == 0xf0) { MinimumSecond = 0x90; }
				if (Lead == 0xf4) { MaximumSecond = 0x8f; }
			}
			else { return false; }
			if (Index + Continuations > Bytes.Num() || Bytes[Index] < MinimumSecond || Bytes[Index] > MaximumSecond) { return false; }
			for (int32 Offset = 1; Offset < Continuations; ++Offset)
			{
				if (Bytes[Index + Offset] < 0x80 || Bytes[Index + Offset] > 0xbf) { return false; }
			}
			Index += Continuations;
		}
		return true;
	}

	bool LoadBoundedJsonText(const FString& Path, int64 MaximumBytes, const FString& ExpectedHash, FString& OutJson, FString& OutFailure)
	{
		if (!IsLowerSha256(ExpectedHash))
		{
			OutFailure = TEXT("Expected JSON SHA-256 must be an exact lowercase digest.");
			return false;
		}
		TArray<uint8> Bytes;
		if (!FFileHelper::LoadFileToArray(Bytes, *Path) || Bytes.IsEmpty() || Bytes.Num() > MaximumBytes)
		{
			OutFailure = TEXT("JSON input is missing, empty, or exceeds its byte limit.");
			return false;
		}
#if AETHELN_CONTENT_VALIDATION_WITH_OPENSSL
		uint8 Digest[SHA256_DIGEST_LENGTH];
		if (SHA256(Bytes.GetData(), static_cast<size_t>(Bytes.Num()), Digest) == nullptr)
		{
			OutFailure = TEXT("Could not hash bounded JSON input bytes.");
			return false;
		}
		FString ActualHash;
		for (const uint8 Byte : Digest) { ActualHash += FString::Printf(TEXT("%02x"), Byte); }
		if (ActualHash != ExpectedHash)
		{
			OutFailure = TEXT("Bounded JSON input bytes do not match supplied SHA-256 provenance.");
			return false;
		}
#else
		OutFailure = TEXT("SHA-256 verification is unsupported for this editor platform.");
		return false;
#endif
		if (!IsStrictUtf8(Bytes))
		{
			OutFailure = TEXT("Bounded JSON input is not strict UTF-8.");
			return false;
		}
		const FUTF8ToTCHAR Converted(reinterpret_cast<const ANSICHAR*>(Bytes.GetData()), Bytes.Num());
		OutJson = FString(Converted.Length(), Converted.Get());
		return true;
	}

	bool LoadBoundedJsonDocument(const FString& Path, int64 MaximumBytes, const FString& ExpectedHash, TSharedPtr<FJsonObject>& OutObject, FString& OutFailure)
	{
		FString Json;
		return LoadBoundedJsonText(Path, MaximumBytes, ExpectedHash, Json, OutFailure)
			&& ParseJsonDocument(Json, OutObject, OutFailure);
	}

	bool HashFileSha256(const FString& Path, FString& OutHash, FString& OutFailure)
	{
#if AETHELN_CONTENT_VALIDATION_WITH_OPENSSL
		TArray<uint8> Bytes;
		if (!FFileHelper::LoadFileToArray(Bytes, *Path))
		{
			OutFailure = FString::Printf(TEXT("Could not read '%s' for SHA-256 verification."), *Path);
			return false;
		}
		uint8 Digest[SHA256_DIGEST_LENGTH];
		if (SHA256(Bytes.GetData(), static_cast<size_t>(Bytes.Num()), Digest) == nullptr)
		{
			OutFailure = FString::Printf(TEXT("Could not compute SHA-256 for '%s'."), *Path);
			return false;
		}
		OutHash.Reset(SHA256_DIGEST_LENGTH * 2);
		for (const uint8 Byte : Digest)
		{
			OutHash += FString::Printf(TEXT("%02x"), Byte);
		}
		return true;
#else
		OutFailure = FString::Printf(TEXT("SHA-256 verification is unsupported for this editor platform: '%s'."), *Path);
		return false;
#endif
	}

	bool IsValidPackagePath(const FString& Value)
	{
		const FRegexPattern Pattern(TEXT("^/Game(?:/[A-Za-z0-9_]+)+$"));
		FRegexMatcher Matcher(Pattern, Value);
		return Matcher.FindNext() && Matcher.GetMatchBeginning() == 0 && Matcher.GetMatchEnding() == Value.Len();
	}

	bool IsValidLongPackagePath(const FString& Value)
	{
		const FRegexPattern Pattern(TEXT("^/[A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)+$"));
		FRegexMatcher Matcher(Pattern, Value);
		return Matcher.FindNext() && Matcher.GetMatchBeginning() == 0 && Matcher.GetMatchEnding() == Value.Len();
	}

	bool IsValidAssetClassPath(const FString& Value)
	{
		const FRegexPattern Pattern(TEXT("^/Script/[A-Za-z0-9_]+\\.[A-Za-z0-9_]+$"));
		FRegexMatcher Matcher(Pattern, Value);
		return Matcher.FindNext() && Matcher.GetMatchBeginning() == 0 && Matcher.GetMatchEnding() == Value.Len();
	}

	bool IsValidStableId(const FString& Value)
	{
		const FRegexPattern Pattern(TEXT("^[a-z][a-z0-9_]*(?:\\.[a-z0-9_]+)+$"));
		FRegexMatcher Matcher(Pattern, Value);
		return Matcher.FindNext() && Matcher.GetMatchBeginning() == 0 && Matcher.GetMatchEnding() == Value.Len();
	}

	bool RepositoryPathMatchesPackage(const FString& RepositoryPath, const FString& PackagePath)
	{
		const FRegexPattern Pattern(TEXT("^Content/(?:[A-Za-z0-9_]+/)*[A-Za-z0-9_]+\\.(?:uasset|umap)$"));
		FRegexMatcher Matcher(Pattern, RepositoryPath);
		if (!Matcher.FindNext() || Matcher.GetMatchBeginning() != 0 || Matcher.GetMatchEnding() != RepositoryPath.Len())
		{
			return false;
		}
		const int32 ExtensionLength = RepositoryPath.EndsWith(TEXT(".uasset"), ESearchCase::CaseSensitive) ? 7 : 5;
		return TEXT("/Game/") + RepositoryPath.Mid(8, RepositoryPath.Len() - 8 - ExtensionLength) == PackagePath;
	}

	bool ParsePolicy(const TSharedPtr<FJsonObject>& Root, FPolicyData& OutPolicy, FString& OutFailure)
	{
		FString SchemaId;
		int32 SchemaVersion = 0;
		if (!Root->TryGetStringField(TEXT("schema_id"), SchemaId)
			|| SchemaId != TEXT("aetheln.asset-intake-policy")
			|| !Root->TryGetNumberField(TEXT("schema_version"), SchemaVersion)
			|| SchemaVersion != 2)
		{
			OutFailure = TEXT("Asset intake policy has an incompatible schema identity.");
			return false;
		}

		const TArray<TSharedPtr<FJsonValue>>* Families = nullptr;
		if (!Root->TryGetArrayField(TEXT("policy_families"), Families) || Families == nullptr || Families->Num() != GovernedFamilies.Num())
		{
			OutFailure = TEXT("Asset intake policy must contain exactly the eight governed families.");
			return false;
		}
		for (int32 Index = 0; Index < Families->Num(); ++Index)
		{
			if (!(*Families)[Index].IsValid() || (*Families)[Index]->Type != EJson::Object)
			{
				OutFailure = FString::Printf(TEXT("policy_families[%d] must be an object."), Index);
				return false;
			}
			const TSharedPtr<FJsonObject> Family = (*Families)[Index]->AsObject();
			FString Id;
			FString FailureCode;
			TArray<FString> Checks;
			if (!RequireString(Family, TEXT("id"), FString::Printf(TEXT("policy_families[%d]"), Index), Id, OutFailure)
				|| !RequireString(Family, TEXT("failure_code"), FString::Printf(TEXT("policy_families[%d]"), Index), FailureCode, OutFailure)
				|| !RequireStringArray(Family, TEXT("checks"), FString::Printf(TEXT("policy_families[%d]"), Index), Checks, OutFailure, false))
			{
				return false;
			}
			if (Id != GovernedFamilies[Index] || FailureCode != FString::Printf(TEXT("content.%s.failed"), *Id))
			{
				OutFailure = FString::Printf(TEXT("Policy family %d has an incompatible identity or failure code."), Index);
				return false;
			}
			TArray<FString> ExpectedChecks = GetExpectedChecks(Id);
			ExpectedChecks.Sort();
			if (Checks != ExpectedChecks)
			{
				OutFailure = FString::Printf(TEXT("Policy family '%s' does not contain the exact governed check set."), *Id);
				return false;
			}
			OutPolicy.FailureCodes.Add(Id, FailureCode);
			OutPolicy.ChecksByFamily.Add(Id, MoveTemp(Checks));
		}

		const TSharedPtr<FJsonObject>* ReferencesPointer = nullptr;
		if (!Root->TryGetObjectField(TEXT("references"), ReferencesPointer) || ReferencesPointer == nullptr)
		{
			OutFailure = TEXT("Asset intake policy references must be an object.");
			return false;
		}
		const TSharedPtr<FJsonObject> References = *ReferencesPointer;
		const TSharedPtr<FJsonObject>* SoftRulesPointer = nullptr;
		if (!References->TryGetObjectField(TEXT("soft_reference_rules"), SoftRulesPointer) || SoftRulesPointer == nullptr)
		{
			OutFailure = TEXT("Policy soft_reference_rules must be an object.");
			return false;
		}
		const TSharedPtr<FJsonObject> SoftRulesObject = *SoftRulesPointer;
		bool bDefaultAllowed = true;
		FString MatchMode;
		if (!SoftRulesObject->TryGetBoolField(TEXT("default_allowed"), bDefaultAllowed)
			|| bDefaultAllowed
			|| !SoftRulesObject->TryGetStringField(TEXT("match_mode"), MatchMode)
			|| MatchMode != TEXT("full_package_path_and_audience"))
		{
			OutFailure = TEXT("Soft-reference rules must be deny-by-default full-path and audience matches.");
			return false;
		}
		const TArray<TSharedPtr<FJsonValue>>* SoftRuleValues = nullptr;
		if (!SoftRulesObject->TryGetArrayField(TEXT("rules"), SoftRuleValues) || SoftRuleValues == nullptr || SoftRuleValues->IsEmpty())
		{
			OutFailure = TEXT("Policy soft-reference rules must not be empty.");
			return false;
		}
		TSet<FString> SoftRuleIds;
		for (int32 Index = 0; Index < SoftRuleValues->Num(); ++Index)
		{
			if (!(*SoftRuleValues)[Index].IsValid() || (*SoftRuleValues)[Index]->Type != EJson::Object)
			{
				OutFailure = FString::Printf(TEXT("Soft-reference rule %d must be an object."), Index);
				return false;
			}
			const TSharedPtr<FJsonObject> RuleObject = (*SoftRuleValues)[Index]->AsObject();
			const FString Context = FString::Printf(TEXT("soft_reference_rules.rules[%d]"), Index);
			if (!RequireExactFields(RuleObject, { TEXT("id"), TEXT("source_package_pattern"), TEXT("source_audience"), TEXT("target_package_pattern"), TEXT("target_audience"), TEXT("justification") }, Context, OutFailure))
			{
				return false;
			}
			FAethelnSoftReferenceRule Rule;
			if (!RequireString(RuleObject, TEXT("id"), Context, Rule.Id, OutFailure)
				|| !RequireString(RuleObject, TEXT("source_package_pattern"), Context, Rule.SourcePackagePattern, OutFailure)
				|| !RequireString(RuleObject, TEXT("source_audience"), Context, Rule.SourceAudience, OutFailure)
				|| !RequireString(RuleObject, TEXT("target_package_pattern"), Context, Rule.TargetPackagePattern, OutFailure)
				|| !RequireString(RuleObject, TEXT("target_audience"), Context, Rule.TargetAudience, OutFailure)
				|| !RequireString(RuleObject, TEXT("justification"), Context, Rule.Justification, OutFailure))
			{
				return false;
			}
			bool bDuplicateRule = false;
			SoftRuleIds.Add(Rule.Id, &bDuplicateRule);
			if (bDuplicateRule
				|| !Rule.SourcePackagePattern.StartsWith(TEXT("^"))
				|| !Rule.SourcePackagePattern.EndsWith(TEXT("$"))
				|| !Rule.TargetPackagePattern.StartsWith(TEXT("^"))
				|| !Rule.TargetPackagePattern.EndsWith(TEXT("$")))
			{
				OutFailure = Context + TEXT(" must have a unique ID and anchored source/target patterns.");
				return false;
			}
			OutPolicy.SoftReferenceRules.Add(MoveTemp(Rule));
		}

		const TArray<TSharedPtr<FJsonValue>>* HardRuleValues = nullptr;
		if (!References->TryGetArrayField(TEXT("hard_reference_audience_rules"), HardRuleValues) || HardRuleValues == nullptr || HardRuleValues->Num() != 3)
		{
			OutFailure = TEXT("Policy hard-reference audience rules must contain exactly three source audiences.");
			return false;
		}
		for (int32 Index = 0; Index < HardRuleValues->Num(); ++Index)
		{
			if (!(*HardRuleValues)[Index].IsValid() || (*HardRuleValues)[Index]->Type != EJson::Object)
			{
				OutFailure = FString::Printf(TEXT("Hard-reference audience rule %d must be an object."), Index);
				return false;
			}
			const TSharedPtr<FJsonObject> RuleObject = (*HardRuleValues)[Index]->AsObject();
			FString Source;
			TArray<FString> Targets;
			const FString Context = FString::Printf(TEXT("hard_reference_audience_rules[%d]"), Index);
			if (!RequireExactFields(RuleObject, { TEXT("source"), TEXT("may_reference") }, Context, OutFailure)
				|| !RequireString(RuleObject, TEXT("source"), Context, Source, OutFailure)
				|| !RequireStringArray(RuleObject, TEXT("may_reference"), Context, Targets, OutFailure, false))
			{
				return false;
			}
			if (OutPolicy.HardAudienceRules.Contains(Source))
			{
				OutFailure = FString::Printf(TEXT("Duplicate hard-reference source audience '%s'."), *Source);
				return false;
			}
			TSet<FString> AllowedTargets;
			for (const FString& Target : Targets)
			{
				AllowedTargets.Add(Target);
			}
			OutPolicy.HardAudienceRules.Add(Source, MoveTemp(AllowedTargets));
		}
		return true;
	}

	bool IsLowerCommitSha(const FString& Value)
	{
		if (Value.Len() != 40) { return false; }
		for (const TCHAR Character : Value)
		{
			if (!((Character >= TEXT('0') && Character <= TEXT('9')) || (Character >= TEXT('a') && Character <= TEXT('f')))) { return false; }
		}
		return true;
	}

	bool ReadOptionalEvidence(const TSharedPtr<FJsonObject>& Root, const TCHAR* Field, const FString& Context, TSharedPtr<FJsonObject>& OutEvidence, FString& OutFailure)
	{
		const TArray<TSharedPtr<FJsonValue>>* Values = nullptr;
		if (!Root->TryGetArrayField(Field, Values) || Values == nullptr || Values->Num() > 1)
		{
			OutFailure = Context + TEXT(" must be an array containing at most one evidence object.");
			return false;
		}
		if (Values->Num() == 1)
		{
			if (!(*Values)[0].IsValid() || (*Values)[0]->Type != EJson::Object)
			{
				OutFailure = Context + TEXT(" must contain an evidence object.");
				return false;
			}
			OutEvidence = (*Values)[0]->AsObject();
		}
		return true;
	}

	bool ValidateLifecycleEvidence(const FIntakeAsset& Asset, const FSourceGroup& Group, const FString& Context, FString& OutFailure)
	{
		const FString EvidenceContext = Context + TEXT(".lifecycle_evidence");
		if (!Asset.LifecycleEvidence.IsValid()
			|| !RequireExactFields(Asset.LifecycleEvidence, { TEXT("content_identity"), TEXT("temporary_prototype"), TEXT("runtime_candidate"), TEXT("production_approval") }, EvidenceContext, OutFailure))
		{
			return false;
		}
		const TSharedPtr<FJsonObject>* IdentityPointer = nullptr;
		if (!Asset.LifecycleEvidence->TryGetObjectField(TEXT("content_identity"), IdentityPointer) || IdentityPointer == nullptr)
		{
			OutFailure = EvidenceContext + TEXT(".content_identity must be an object.");
			return false;
		}
		FString StableId;
		FString ContentHash;
		int32 ContentVersion = 0;
		if (!RequireExactFields(*IdentityPointer, { TEXT("stable_id"), TEXT("content_version"), TEXT("content_sha256") }, EvidenceContext + TEXT(".content_identity"), OutFailure)
			|| !RequireString(*IdentityPointer, TEXT("stable_id"), EvidenceContext, StableId, OutFailure)
			|| !(*IdentityPointer)->TryGetNumberField(TEXT("content_version"), ContentVersion)
			|| !RequireString(*IdentityPointer, TEXT("content_sha256"), EvidenceContext, ContentHash, OutFailure)
			|| StableId != Asset.StableId || ContentVersion != Asset.ContentVersion || ContentHash != Asset.ContentSha256)
		{
			if (OutFailure.IsEmpty()) { OutFailure = EvidenceContext + TEXT(" does not bind the exact content identity."); }
			return false;
		}
		TSharedPtr<FJsonObject> Temporary;
		TSharedPtr<FJsonObject> Candidate;
		TSharedPtr<FJsonObject> Production;
		if (!ReadOptionalEvidence(Asset.LifecycleEvidence, TEXT("temporary_prototype"), EvidenceContext + TEXT(".temporary_prototype"), Temporary, OutFailure)
			|| !ReadOptionalEvidence(Asset.LifecycleEvidence, TEXT("runtime_candidate"), EvidenceContext + TEXT(".runtime_candidate"), Candidate, OutFailure)
			|| !ReadOptionalEvidence(Asset.LifecycleEvidence, TEXT("production_approval"), EvidenceContext + TEXT(".production_approval"), Production, OutFailure))
		{
			return false;
		}
		if (Asset.LifecycleState == TEXT("temporary_prototype"))
		{
			FString Value;
			bool bMayBeRuntimeCandidate = true;
			if (!Temporary.IsValid() || Candidate.IsValid() || Production.IsValid() || Group.ApprovalState != TEXT("temporary_prototype_only")
				|| !RequireExactFields(Temporary, { TEXT("owner"), TEXT("approval_record"), TEXT("recovery_trigger"), TEXT("may_be_runtime_candidate") }, EvidenceContext + TEXT(".temporary_prototype[0]"), OutFailure)
				|| !RequireString(Temporary, TEXT("owner"), EvidenceContext, Value, OutFailure)
				|| !RequireString(Temporary, TEXT("approval_record"), EvidenceContext, Value, OutFailure)
				|| !RequireString(Temporary, TEXT("recovery_trigger"), EvidenceContext, Value, OutFailure)
				|| !Temporary->TryGetBoolField(TEXT("may_be_runtime_candidate"), bMayBeRuntimeCandidate) || bMayBeRuntimeCandidate)
			{
				if (OutFailure.IsEmpty()) { OutFailure = EvidenceContext + TEXT(" has invalid temporary-only evidence."); }
				return false;
			}
			return true;
		}
		if (Temporary.IsValid() || !Candidate.IsValid())
		{
			OutFailure = EvidenceContext + TEXT(" must contain exact runtime-candidate evidence and no temporary evidence.");
			return false;
		}
		FString ReviewRevision, Reviewer, ApprovalRecord, CandidateStableId, CandidateHash;
		int32 CandidateVersion = 0;
		if (!RequireExactFields(Candidate, { TEXT("review_revision"), TEXT("reviewer"), TEXT("approval_record"), TEXT("stable_id"), TEXT("content_version"), TEXT("content_sha256") }, EvidenceContext + TEXT(".runtime_candidate[0]"), OutFailure)
			|| !RequireString(Candidate, TEXT("review_revision"), EvidenceContext, ReviewRevision, OutFailure)
			|| !RequireString(Candidate, TEXT("reviewer"), EvidenceContext, Reviewer, OutFailure)
			|| !RequireString(Candidate, TEXT("approval_record"), EvidenceContext, ApprovalRecord, OutFailure)
			|| !RequireString(Candidate, TEXT("stable_id"), EvidenceContext, CandidateStableId, OutFailure)
			|| !Candidate->TryGetNumberField(TEXT("content_version"), CandidateVersion)
			|| !RequireString(Candidate, TEXT("content_sha256"), EvidenceContext, CandidateHash, OutFailure)
			|| !IsLowerCommitSha(ReviewRevision) || CandidateStableId != Asset.StableId || CandidateVersion != Asset.ContentVersion || CandidateHash != Asset.ContentSha256)
		{
			if (OutFailure.IsEmpty()) { OutFailure = EvidenceContext + TEXT(" runtime-candidate evidence does not bind the exact revision and content identity."); }
			return false;
		}
		if (Asset.LifecycleState == TEXT("runtime_candidate"))
		{
			if (Production.IsValid() || Group.ApprovalState != TEXT("runtime_candidate_approved"))
			{
				OutFailure = EvidenceContext + TEXT(" runtime-candidate evidence conflicts with source approval.");
				return false;
			}
			return true;
		}
		FString CandidateRevision, CandidateApproval, ProductionRevision, ProductionReviewer, ProductionApproval, ProductionStableId, ProductionHash;
		int32 ProductionVersion = 0;
		if (!Production.IsValid() || Group.ApprovalState != TEXT("production_approved")
			|| !RequireExactFields(Production, { TEXT("candidate_review_revision"), TEXT("candidate_approval_record"), TEXT("production_revision"), TEXT("reviewer"), TEXT("approval_record"), TEXT("stable_id"), TEXT("content_version"), TEXT("content_sha256") }, EvidenceContext + TEXT(".production_approval[0]"), OutFailure)
			|| !RequireString(Production, TEXT("candidate_review_revision"), EvidenceContext, CandidateRevision, OutFailure)
			|| !RequireString(Production, TEXT("candidate_approval_record"), EvidenceContext, CandidateApproval, OutFailure)
			|| !RequireString(Production, TEXT("production_revision"), EvidenceContext, ProductionRevision, OutFailure)
			|| !RequireString(Production, TEXT("reviewer"), EvidenceContext, ProductionReviewer, OutFailure)
			|| !RequireString(Production, TEXT("approval_record"), EvidenceContext, ProductionApproval, OutFailure)
			|| !RequireString(Production, TEXT("stable_id"), EvidenceContext, ProductionStableId, OutFailure)
			|| !Production->TryGetNumberField(TEXT("content_version"), ProductionVersion)
			|| !RequireString(Production, TEXT("content_sha256"), EvidenceContext, ProductionHash, OutFailure)
			|| CandidateRevision != ReviewRevision || CandidateApproval != ApprovalRecord || !IsLowerCommitSha(ProductionRevision)
			|| ProductionStableId != Asset.StableId || ProductionVersion != Asset.ContentVersion || ProductionHash != Asset.ContentSha256)
		{
			if (OutFailure.IsEmpty()) { OutFailure = EvidenceContext + TEXT(" production evidence does not bind the exact candidate approval and content identity."); }
			return false;
		}
		return true;
	}

	bool ParseIntake(
		const TSharedPtr<FJsonObject>& Root,
		TMap<FString, FSourceGroup>& OutSourceGroups,
		TArray<FIntakeAsset>& OutAssets,
		FString& OutFailure)
	{
		const TArray<FString> RootFields = {
			TEXT("schema_id"), TEXT("schema_version"), TEXT("policy_schema_id"), TEXT("policy_schema_version"),
			TEXT("content_root"), TEXT("package_root"), TEXT("expected_asset_count"), TEXT("source_groups"), TEXT("assets")
		};
		if (!RequireExactFields(Root, RootFields, TEXT("runtime intake registry"), OutFailure))
		{
			return false;
		}
		FString SchemaId;
		FString PolicySchemaId;
		FString ContentRoot;
		FString PackageRoot;
		int32 SchemaVersion = 0;
		int32 PolicySchemaVersion = 0;
		int32 ExpectedAssetCount = 0;
		if (!Root->TryGetStringField(TEXT("schema_id"), SchemaId)
			|| !Root->TryGetNumberField(TEXT("schema_version"), SchemaVersion)
			|| !Root->TryGetStringField(TEXT("policy_schema_id"), PolicySchemaId)
			|| !Root->TryGetNumberField(TEXT("policy_schema_version"), PolicySchemaVersion)
			|| !Root->TryGetStringField(TEXT("content_root"), ContentRoot)
			|| !Root->TryGetStringField(TEXT("package_root"), PackageRoot)
			|| !Root->TryGetNumberField(TEXT("expected_asset_count"), ExpectedAssetCount)
			|| SchemaId != TEXT("aetheln.runtime-asset-intake")
			|| SchemaVersion != 1
			|| PolicySchemaId != TEXT("aetheln.asset-intake-policy")
			|| PolicySchemaVersion != 2
			|| ContentRoot != TEXT("Content/")
			|| PackageRoot != TEXT("/Game")
			|| ExpectedAssetCount < 1)
		{
			OutFailure = TEXT("Runtime intake registry identity, roots, or expected_asset_count are invalid.");
			return false;
		}

		const TArray<TSharedPtr<FJsonValue>>* SourceGroupValues = nullptr;
		if (!Root->TryGetArrayField(TEXT("source_groups"), SourceGroupValues) || SourceGroupValues == nullptr || SourceGroupValues->IsEmpty())
		{
			OutFailure = TEXT("Runtime intake registry source_groups must not be empty.");
			return false;
		}
		const TArray<FString> SourceGroupFields = {
			TEXT("id"), TEXT("author_or_provider"), TEXT("source_record"), TEXT("source_version"),
			TEXT("license_or_permission_evidence"), TEXT("modifications"), TEXT("generation_metadata_when_applicable"),
			TEXT("reviewer"), TEXT("approval_state"), TEXT("naming_owner"), TEXT("import_settings_record"), TEXT("reimport_settings_record")
		};
		for (int32 Index = 0; Index < SourceGroupValues->Num(); ++Index)
		{
			if (!(*SourceGroupValues)[Index].IsValid() || (*SourceGroupValues)[Index]->Type != EJson::Object)
			{
				OutFailure = FString::Printf(TEXT("source_groups[%d] must be an object."), Index);
				return false;
			}
			const TSharedPtr<FJsonObject> Object = (*SourceGroupValues)[Index]->AsObject();
			const FString Context = FString::Printf(TEXT("source_groups[%d]"), Index);
			FSourceGroup Group;
			if (!RequireExactFields(Object, SourceGroupFields, Context, OutFailure)
				|| !RequireString(Object, TEXT("id"), Context, Group.Id, OutFailure)
				|| !RequireString(Object, TEXT("author_or_provider"), Context, Group.AuthorOrProvider, OutFailure)
				|| !RequireString(Object, TEXT("source_record"), Context, Group.SourceRecord, OutFailure)
				|| !RequireString(Object, TEXT("source_version"), Context, Group.SourceVersion, OutFailure)
				|| !RequireString(Object, TEXT("license_or_permission_evidence"), Context, Group.LicenseOrPermissionEvidence, OutFailure)
				|| !RequireString(Object, TEXT("modifications"), Context, Group.Modifications, OutFailure)
				|| !RequireString(Object, TEXT("generation_metadata_when_applicable"), Context, Group.GenerationMetadata, OutFailure)
				|| !RequireString(Object, TEXT("reviewer"), Context, Group.Reviewer, OutFailure)
				|| !RequireString(Object, TEXT("approval_state"), Context, Group.ApprovalState, OutFailure)
				|| !RequireString(Object, TEXT("naming_owner"), Context, Group.NamingOwner, OutFailure)
				|| !RequireString(Object, TEXT("import_settings_record"), Context, Group.ImportSettingsRecord, OutFailure)
				|| !RequireString(Object, TEXT("reimport_settings_record"), Context, Group.ReimportSettingsRecord, OutFailure))
			{
				return false;
			}
			if (OutSourceGroups.Contains(Group.Id))
			{
				OutFailure = FString::Printf(TEXT("Duplicate source group ID '%s'."), *Group.Id);
				return false;
			}
			OutSourceGroups.Add(Group.Id, MoveTemp(Group));
		}

		const TArray<TSharedPtr<FJsonValue>>* AssetValues = nullptr;
		if (!Root->TryGetArrayField(TEXT("assets"), AssetValues) || AssetValues == nullptr || AssetValues->Num() != ExpectedAssetCount)
		{
			OutFailure = TEXT("Runtime intake registry assets do not match expected_asset_count.");
			return false;
		}
		const TArray<FString> AssetFields = {
			TEXT("asset_path"), TEXT("repository_path"), TEXT("stable_id"), TEXT("content_version"), TEXT("audience"),
			TEXT("lifecycle_state"), TEXT("source_group_id"), TEXT("content_sha256"), TEXT("lifecycle_evidence")
		};
		TSet<FString> AssetPaths;
		TSet<FString> RepositoryPaths;
		TSet<FString> StableIds;
		for (int32 Index = 0; Index < AssetValues->Num(); ++Index)
		{
			if (!(*AssetValues)[Index].IsValid() || (*AssetValues)[Index]->Type != EJson::Object)
			{
				OutFailure = FString::Printf(TEXT("assets[%d] must be an object."), Index);
				return false;
			}
			const TSharedPtr<FJsonObject> Object = (*AssetValues)[Index]->AsObject();
			const FString Context = FString::Printf(TEXT("assets[%d]"), Index);
			FIntakeAsset Asset;
			const TSharedPtr<FJsonObject>* LifecycleEvidencePointer = nullptr;
			if (!RequireExactFields(Object, AssetFields, Context, OutFailure)
				|| !RequireString(Object, TEXT("asset_path"), Context, Asset.AssetPath, OutFailure)
				|| !RequireString(Object, TEXT("repository_path"), Context, Asset.RepositoryPath, OutFailure)
				|| !RequireString(Object, TEXT("stable_id"), Context, Asset.StableId, OutFailure)
				|| !Object->TryGetNumberField(TEXT("content_version"), Asset.ContentVersion)
				|| !RequireString(Object, TEXT("audience"), Context, Asset.Audience, OutFailure)
				|| !RequireString(Object, TEXT("lifecycle_state"), Context, Asset.LifecycleState, OutFailure)
				|| !RequireString(Object, TEXT("source_group_id"), Context, Asset.SourceGroupId, OutFailure)
				|| !RequireString(Object, TEXT("content_sha256"), Context, Asset.ContentSha256, OutFailure)
				|| !Object->TryGetObjectField(TEXT("lifecycle_evidence"), LifecycleEvidencePointer) || LifecycleEvidencePointer == nullptr)
			{
				if (OutFailure.IsEmpty()) { OutFailure = Context + TEXT(" contains an invalid typed field."); }
				return false;
			}
			Asset.LifecycleEvidence = *LifecycleEvidencePointer;
			if (!IsValidPackagePath(Asset.AssetPath)
				|| !IsValidStableId(Asset.StableId)
				|| Asset.ContentVersion < 1
				|| !IsLowerSha256(Asset.ContentSha256)
				|| !RepositoryPathMatchesPackage(Asset.RepositoryPath, Asset.AssetPath)
				|| (Asset.Audience != TEXT("shared") && Asset.Audience != TEXT("server_only") && Asset.Audience != TEXT("client_only"))
				|| (Asset.LifecycleState != TEXT("temporary_prototype") && Asset.LifecycleState != TEXT("runtime_candidate") && Asset.LifecycleState != TEXT("production_approved")))
			{
				OutFailure = Context + TEXT(" contains an invalid identity, path, hash, audience, version, or lifecycle value.");
				return false;
			}
			bool bDuplicateAssetPath = false;
			bool bDuplicateRepositoryPath = false;
			bool bDuplicateStableId = false;
			AssetPaths.Add(Asset.AssetPath, &bDuplicateAssetPath);
			RepositoryPaths.Add(Asset.RepositoryPath, &bDuplicateRepositoryPath);
			StableIds.Add(Asset.StableId, &bDuplicateStableId);
			if (bDuplicateAssetPath || bDuplicateRepositoryPath || bDuplicateStableId)
			{
				OutFailure = Context + TEXT(" duplicates an asset path, repository path, or stable ID.");
				return false;
			}
			const FSourceGroup* Group = OutSourceGroups.Find(Asset.SourceGroupId);
			if (Group == nullptr)
			{
				OutFailure = FString::Printf(TEXT("%s references missing source group '%s'."), *Context, *Asset.SourceGroupId);
				return false;
			}
			if (!ValidateLifecycleEvidence(Asset, *Group, Context, OutFailure)) { return false; }
			OutAssets.Add(MoveTemp(Asset));
		}
		OutAssets.Sort([](const FIntakeAsset& Left, const FIntakeAsset& Right) { return Left.AssetPath < Right.AssetPath; });
		return true;
	}

	bool RegexMatchesEntireValue(const FString& PatternText, const FString& Value)
	{
		const FRegexPattern Pattern(PatternText);
		FRegexMatcher Matcher(Pattern, Value);
		return Matcher.FindNext() && Matcher.GetMatchBeginning() == 0 && Matcher.GetMatchEnding() == Value.Len();
	}

	bool HasClassFragment(const FAethelnObservedPackage& Package, const TCHAR* Fragment)
	{
		for (const FString& ClassPath : Package.ClassPaths)
		{
			if (ClassPath.Contains(Fragment, ESearchCase::IgnoreCase))
			{
				return true;
			}
		}
		return false;
	}

	FString DescribeObservedClasses(const FAethelnObservedPackage& Package)
	{
		return FString::Join(Package.ClassPaths, TEXT(", "));
	}

	TSharedPtr<FJsonValue> JsonObjectValue(const TSharedPtr<FJsonObject>& Value)
	{
		return MakeShared<FJsonValueObject>(Value);
	}

	TSharedPtr<FJsonObject> MakeFinding(
		const FString& PolicyId,
		const FString& FailureCode,
		const FString& AssetPath,
		const FString& Severity,
		const FString& Reason,
		const FString& Remediation,
		const FString& EvidenceField)
	{
		TSharedPtr<FJsonObject> Finding = MakeShared<FJsonObject>();
		Finding->SetStringField(TEXT("policy_id"), PolicyId);
		Finding->SetStringField(TEXT("code"), FailureCode);
		Finding->SetStringField(TEXT("asset_path"), AssetPath);
		Finding->SetStringField(TEXT("severity"), Severity);
		Finding->SetStringField(TEXT("reason"), Reason);
		Finding->SetStringField(TEXT("remediation"), Remediation);
		Finding->SetStringField(TEXT("evidence_field"), EvidenceField);
		return Finding;
	}

	void RecordFacts(
		TMap<FString, TArray<FAethelnContentCheckFacts>>& FactsByFamily,
		const FString& FamilyId,
		const FString& CheckId,
		bool bApplicable,
		const FString& Evidence,
		TMap<FString, bool> BooleanFacts = {},
		TMap<FString, int64> IntegerFacts = {},
		TMap<FString, double> DecimalFacts = {},
		TMap<FString, FString> TextFacts = {},
		bool bHasUnresolvedThreshold = false)
	{
		FAethelnContentCheckFacts Facts;
		Facts.CheckId = CheckId;
		Facts.bApplicable = bApplicable;
		Facts.BooleanFacts = MoveTemp(BooleanFacts);
		Facts.IntegerFacts = MoveTemp(IntegerFacts);
		Facts.DecimalFacts = MoveTemp(DecimalFacts);
		Facts.TextFacts = MoveTemp(TextFacts);
		Facts.bHasUnresolvedThreshold = bHasUnresolvedThreshold;
		Facts.Evidence = Evidence;
		FactsByFamily.FindOrAdd(FamilyId).Add(MoveTemp(Facts));
	}

	FString DescribeDataValidation(UObject* Object, bool& bOutPassed)
	{
		FDataValidationContext Context;
		Context.MarkAssetLoadedForValidation();
		const EDataValidationResult Validation = Object->IsDataValid(Context);
		bOutPassed = Validation != EDataValidationResult::Invalid && Context.GetNumErrors() == 0;
		TArray<FString> Issues;
		for (const FDataValidationContext::FIssue& Issue : Context.GetIssues())
		{
			Issues.Add(Issue.Message.ToString());
		}
		Issues.Sort();
		const TCHAR* State = Validation == EDataValidationResult::Valid
			? TEXT("valid")
			: (Validation == EDataValidationResult::Invalid ? TEXT("invalid") : TEXT("not_validated"));
		return FString::Printf(
			TEXT("object=%s;is_data_valid=%s;errors=%u;warnings=%u;issues=[%s]"),
			*Object->GetPathName(),
			State,
			Context.GetNumErrors(),
			Context.GetNumWarnings(),
			*FString::Join(Issues, TEXT(" | ")));
	}

	bool EvaluateLoadedPackage(
		const FAethelnObservedPackage& Package,
		const FIntakeAsset& IntakeAsset,
		const FPolicyData& Policy,
		TMap<FString, TArray<FAethelnContentCheckFacts>>& OutFacts,
		FString& OutFailure)
	{
		FAssetRegistryModule& Module = FModuleManager::LoadModuleChecked<FAssetRegistryModule>(TEXT("AssetRegistry"));
		TArray<FAssetData> PackageAssets;
		if (!Module.Get().GetAssetsByPackageName(FName(*Package.PackageName), PackageAssets, true, true) || PackageAssets.IsEmpty())
		{
			OutFailure = FString::Printf(TEXT("Governed package '%s' has no loadable on-disk Asset Registry record."), *Package.PackageName);
			return false;
		}
		PackageAssets.Sort([](const FAssetData& Left, const FAssetData& Right)
		{
			return Left.GetObjectPathString() < Right.GetObjectPathString();
		});

		for (const FAssetData& AssetData : PackageAssets)
		{
			UObject* Object = AssetData.GetAsset();
			if (Object == nullptr)
			{
				OutFailure = FString::Printf(TEXT("Governed asset '%s' could not be loaded for read-only validation."), *AssetData.GetObjectPathString());
				return false;
			}
			bool bDataValid = false;
			const FString ValidationEvidence = DescribeDataValidation(Object, bDataValid);
			if (const UBlueprint* Blueprint = Cast<UBlueprint>(Object))
			{
				const UClass* GeneratedClass = Blueprint->GeneratedClass;
				const ACharacter* Character = GeneratedClass == nullptr ? nullptr : Cast<ACharacter>(GeneratedClass->GetDefaultObject(false));
				if (Character != nullptr)
				{
					const UCapsuleComponent* Capsule = Character->GetCapsuleComponent();
					const FString BlueprintCollisionEvidence = FString::Printf(
						TEXT("%s;generated_class=%s;character_cdo=%s;capsule=%s;profile=%s;collision_enabled=%d"),
						*ValidationEvidence,
						*GeneratedClass->GetPathName(),
						*Character->GetPathName(),
						Capsule == nullptr ? TEXT("missing") : TEXT("present"),
						Capsule == nullptr ? TEXT("missing") : *Capsule->GetCollisionProfileName().ToString(),
						Capsule == nullptr ? -1 : static_cast<int32>(Capsule->GetCollisionEnabled()));
					RecordFacts(OutFacts, TEXT("collision"), TEXT("profile"), true, BlueprintCollisionEvidence,
						{{TEXT("asset_data_valid"), bDataValid}, {TEXT("collision_source_present"), Capsule != nullptr}}, {}, {},
						{{TEXT("profile_name"), Capsule == nullptr ? FString() : Capsule->GetCollisionProfileName().ToString()}});
					RecordFacts(OutFacts, TEXT("collision"), TEXT("simple_complex_policy"), true, BlueprintCollisionEvidence,
						{{TEXT("asset_data_valid"), bDataValid}, {TEXT("collision_source_present"), Capsule != nullptr}},
						{{TEXT("simple_shape_count"), Capsule == nullptr ? 0 : 1}, {TEXT("trace_flag"), Capsule == nullptr ? -1 : static_cast<int64>(Capsule->GetCollisionEnabled())}});
					RecordFacts(OutFacts, TEXT("collision"), TEXT("presentation_equivalence"), true,
						BlueprintCollisionEvidence + TEXT(";quantitative_policy=TBD"),
						{{TEXT("authoritative_geometry_present"), Capsule != nullptr}}, {}, {}, {}, true);
				}
			}

			if (const UStaticMesh* StaticMesh = Cast<UStaticMesh>(Object))
			{
				const UBodySetup* BodySetup = StaticMesh->GetBodySetup();
				const int32 SimpleShapes = BodySetup == nullptr ? 0 : BodySetup->AggGeom.GetElementCount();
				const FString CollisionEvidence = FString::Printf(
					TEXT("%s;body_setup=%s;profile=%s;simple_shapes=%d;trace_flag=%d"),
					*ValidationEvidence,
					BodySetup == nullptr ? TEXT("missing") : TEXT("present"),
					BodySetup == nullptr ? TEXT("missing") : *BodySetup->DefaultInstance.GetCollisionProfileName().ToString(),
					SimpleShapes,
					BodySetup == nullptr ? -1 : static_cast<int32>(BodySetup->GetCollisionTraceFlag()));
				RecordFacts(OutFacts, TEXT("collision"), TEXT("profile"), true, CollisionEvidence,
					{{TEXT("asset_data_valid"), bDataValid}, {TEXT("collision_source_present"), BodySetup != nullptr}}, {}, {},
					{{TEXT("profile_name"), BodySetup == nullptr ? FString() : BodySetup->DefaultInstance.GetCollisionProfileName().ToString()}});
				RecordFacts(OutFacts, TEXT("collision"), TEXT("simple_complex_policy"), true, CollisionEvidence,
					{{TEXT("asset_data_valid"), bDataValid}, {TEXT("collision_source_present"), BodySetup != nullptr}},
					{{TEXT("simple_shape_count"), SimpleShapes}, {TEXT("trace_flag"), BodySetup == nullptr ? -1 : static_cast<int64>(BodySetup->GetCollisionTraceFlag())}});
				RecordFacts(OutFacts, TEXT("collision"), TEXT("presentation_equivalence"), true,
					CollisionEvidence + TEXT(";quantitative_policy=TBD"),
					{{TEXT("authoritative_geometry_present"), BodySetup != nullptr}}, {}, {}, {}, true);

				const int32 SourceModels = StaticMesh->GetNumSourceModels();
				const int32 RenderLods = StaticMesh->GetNumLODs();
				const bool bHasRenderData = StaticMesh->GetRenderData() != nullptr;
				const bool bNaniteEnabled = StaticMesh->GetNaniteSettings().bEnabled;
				const bool bHasNaniteData = StaticMesh->HasValidNaniteData();
				const FString RenderEvidence = FString::Printf(
					TEXT("%s;source_models=%d;render_lods=%d;render_data=%s;lod_group=%s;nanite_enabled=%s;nanite_data=%s"),
					*ValidationEvidence, SourceModels, RenderLods, bHasRenderData ? TEXT("present") : TEXT("missing"), *StaticMesh->GetLODGroup().ToString(),
					bNaniteEnabled ? TEXT("true") : TEXT("false"), bHasNaniteData ? TEXT("present") : TEXT("absent"));
				RecordFacts(OutFacts, TEXT("rendering_suitability"), TEXT("lod"), true, RenderEvidence,
					{{TEXT("asset_data_valid"), bDataValid}}, {{TEXT("source_model_count"), SourceModels}, {TEXT("render_lod_count"), RenderLods}});
				RecordFacts(OutFacts, TEXT("rendering_suitability"), TEXT("hlod"), true, RenderEvidence + TEXT(";quantitative_policy=TBD"),
					{{TEXT("render_data_present"), bHasRenderData}}, {}, {}, {}, true);
				RecordFacts(OutFacts, TEXT("rendering_suitability"), TEXT("nanite_suitability"), true, RenderEvidence + TEXT(";quantitative_policy=TBD"),
					{{TEXT("render_data_present"), bHasRenderData}, {TEXT("nanite_enabled"), bNaniteEnabled}, {TEXT("nanite_data_present"), bHasNaniteData}}, {}, {}, {}, true);
				RecordFacts(OutFacts, TEXT("rendering_suitability"), TEXT("streaming"), true, RenderEvidence + TEXT(";quantitative_policy=TBD"),
					{{TEXT("render_data_present"), bHasRenderData}}, {}, {}, {}, true);
			}

			if (const USkeletalMesh* SkeletalMesh = Cast<USkeletalMesh>(Object))
			{
				const UBodySetup* BodySetup = SkeletalMesh->GetBodySetup();
				const UPhysicsAsset* PhysicsAsset = SkeletalMesh->GetPhysicsAsset();
				const USkeleton* Skeleton = SkeletalMesh->GetSkeleton();
				const int32 BoneCount = SkeletalMesh->GetRefSkeleton().GetRawBoneNum();
				const int32 LodCount = SkeletalMesh->GetLODNum();
				const bool bHasImportedModel = SkeletalMesh->GetImportedModel() != nullptr;
				const int32 ImportedVertices = SkeletalMesh->GetNumImportedVertices();
				int32 InvalidSocketCount = 0;
				for (const USkeletalMeshSocket* Socket : SkeletalMesh->GetMeshOnlySocketList())
				{
					InvalidSocketCount += Socket == nullptr || SkeletalMesh->GetRefSkeleton().FindBoneIndex(Socket->BoneName) == INDEX_NONE ? 1 : 0;
				}
				const FString SkeletalEvidence = FString::Printf(
					TEXT("%s;skeleton=%s;bones=%d;body_setup=%s;physics_asset=%s;lod_count=%d;imported_model=%s;imported_vertices=%d;morph_targets=%d;mesh_sockets=%d"),
					*ValidationEvidence,
					Skeleton == nullptr ? TEXT("missing") : *Skeleton->GetPathName(),
					BoneCount,
					BodySetup == nullptr ? TEXT("missing") : TEXT("present"),
					PhysicsAsset == nullptr ? TEXT("missing") : *PhysicsAsset->GetPathName(),
					LodCount,
					bHasImportedModel ? TEXT("present") : TEXT("missing"),
					ImportedVertices,
					SkeletalMesh->GetMorphTargets().Num(),
					SkeletalMesh->GetMeshOnlySocketList().Num());
				RecordFacts(OutFacts, TEXT("collision"), TEXT("profile"), true, SkeletalEvidence,
					{{TEXT("asset_data_valid"), bDataValid}, {TEXT("collision_source_present"), BodySetup != nullptr}}, {}, {},
					{{TEXT("profile_name"), BodySetup == nullptr ? FString() : BodySetup->DefaultInstance.GetCollisionProfileName().ToString()}});
				RecordFacts(OutFacts, TEXT("collision"), TEXT("simple_complex_policy"), true, SkeletalEvidence,
					{{TEXT("asset_data_valid"), bDataValid}, {TEXT("collision_source_present"), BodySetup != nullptr}},
					{{TEXT("simple_shape_count"), BodySetup == nullptr ? 0 : BodySetup->AggGeom.GetElementCount()}, {TEXT("trace_flag"), BodySetup == nullptr ? -1 : static_cast<int64>(BodySetup->GetCollisionTraceFlag())}});
				RecordFacts(OutFacts, TEXT("collision"), TEXT("presentation_equivalence"), true, SkeletalEvidence + TEXT(";quantitative_policy=TBD"),
					{{TEXT("authoritative_geometry_present"), PhysicsAsset != nullptr}}, {}, {}, {}, true);
				RecordFacts(OutFacts, TEXT("rendering_suitability"), TEXT("lod"), true, SkeletalEvidence,
					{{TEXT("asset_data_valid"), bDataValid}, {TEXT("imported_model_present"), bHasImportedModel}},
					{{TEXT("source_model_count"), LodCount}, {TEXT("render_lod_count"), LodCount}});
				RecordFacts(OutFacts, TEXT("rendering_suitability"), TEXT("hlod"), true, SkeletalEvidence + TEXT(";quantitative_policy=TBD"), {}, {}, {}, {}, true);
				RecordFacts(OutFacts, TEXT("rendering_suitability"), TEXT("nanite_suitability"), true, SkeletalEvidence + TEXT(";quantitative_policy=TBD"), {}, {}, {}, {}, true);
				RecordFacts(OutFacts, TEXT("rendering_suitability"), TEXT("streaming"), true, SkeletalEvidence + TEXT(";quantitative_policy=TBD"), {}, {}, {}, {}, true);
				RecordFacts(OutFacts, TEXT("skeletal_animation"), TEXT("rig_compatibility"), true, SkeletalEvidence,
					{{TEXT("asset_data_valid"), bDataValid}, {TEXT("skeleton_present"), Skeleton != nullptr}}, {{TEXT("bone_count"), BoneCount}});
				RecordFacts(OutFacts, TEXT("skeletal_animation"), TEXT("morph_policy"), true, SkeletalEvidence + TEXT(";quantitative_policy=TBD"),
					{}, {{TEXT("morph_target_count"), SkeletalMesh->GetMorphTargets().Num()}}, {}, {}, true);
				RecordFacts(OutFacts, TEXT("skeletal_animation"), TEXT("influences"), true, SkeletalEvidence + TEXT(";quantitative_policy=TBD"),
					{{TEXT("imported_model_present"), bHasImportedModel}}, {{TEXT("imported_vertex_count"), ImportedVertices}}, {}, {}, true);
				RecordFacts(OutFacts, TEXT("skeletal_animation"), TEXT("socket_ownership"), true, SkeletalEvidence,
					{{TEXT("asset_data_valid"), bDataValid}},
					{{TEXT("socket_count"), SkeletalMesh->GetMeshOnlySocketList().Num()}, {TEXT("invalid_socket_count"), InvalidSocketCount}});
				RecordFacts(OutFacts, TEXT("skeletal_animation"), TEXT("animation_complexity"), false, TEXT("not_applicable:object_is_not_animation"));
			}

			if (const UTexture* Texture = Cast<UTexture>(Object))
			{
				const int64 Width = FMath::RoundToInt64(Texture->GetSurfaceWidth());
				const int64 Height = FMath::RoundToInt64(Texture->GetSurfaceHeight());
				const UTexture2D* Texture2D = Cast<UTexture2D>(Texture);
				const int32 Mips = Texture2D == nullptr ? 0 : Texture2D->GetNumMips();
				const FString TextureEvidence = FString::Printf(
					TEXT("%s;width=%lld;height=%lld;mips=%d;compression=%d;address_x=%d;address_y=%d;virtual_texture_streaming=%s;streaming_method=%d"),
					*ValidationEvidence, Width, Height, Mips, static_cast<int32>(Texture->CompressionSettings),
					static_cast<int32>(Texture->GetTextureAddressX()), static_cast<int32>(Texture->GetTextureAddressY()),
					Texture->VirtualTextureStreaming ? TEXT("true") : TEXT("false"),
					static_cast<int32>(Texture->GetTextureStreamingMethod()));
				RecordFacts(OutFacts, TEXT("texture"), TEXT("pbr_channels"), true, TextureEvidence,
					{{TEXT("asset_data_valid"), bDataValid}}, {{TEXT("width"), Width}, {TEXT("height"), Height}});
				RecordFacts(OutFacts, TEXT("texture"), TEXT("tiling"), true, TextureEvidence,
					{{TEXT("asset_data_valid"), bDataValid}}, {{TEXT("address_x"), static_cast<int64>(Texture->GetTextureAddressX())}, {TEXT("address_y"), static_cast<int64>(Texture->GetTextureAddressY())}});
				RecordFacts(OutFacts, TEXT("texture"), TEXT("compression"), true, TextureEvidence,
					{{TEXT("asset_data_valid"), bDataValid}}, {{TEXT("compression_setting"), static_cast<int64>(Texture->CompressionSettings)}});
				RecordFacts(OutFacts, TEXT("texture"), TEXT("mips"), Texture2D != nullptr, TextureEvidence,
					{{TEXT("asset_data_valid"), bDataValid}}, {{TEXT("width"), Width}, {TEXT("height"), Height}, {TEXT("mip_count"), Mips}});
				RecordFacts(OutFacts, TEXT("texture"), TEXT("streaming"), true, TextureEvidence + TEXT(";quantitative_policy=TBD"),
					{{TEXT("virtual_texture_streaming"), Texture->VirtualTextureStreaming != 0}},
					{{TEXT("streaming_method"), static_cast<int64>(Texture->GetTextureStreamingMethod())}}, {}, {}, true);
			}

			if (const UMaterialInterface* Material = Cast<UMaterialInterface>(Object))
			{
				const UMaterialInstance* Instance = Cast<UMaterialInstance>(Material);
				const FString MaterialEvidence = FString::Printf(
					TEXT("%s;kind=%s;parent=%s;base_material=%s"),
					*ValidationEvidence,
					Instance == nullptr ? TEXT("base_material") : TEXT("material_instance"),
					Instance == nullptr ? TEXT("not_applicable") : (Instance->Parent == nullptr ? TEXT("missing") : *Instance->Parent->GetPathName()),
					Material->GetMaterial() == nullptr ? TEXT("missing") : *Material->GetMaterial()->GetPathName());
				RecordFacts(OutFacts, TEXT("material"), TEXT("material_instance_policy"), true, MaterialEvidence,
					{{TEXT("asset_data_valid"), bDataValid}, {TEXT("is_instance"), Instance != nullptr}, {TEXT("parent_present"), Instance != nullptr && Instance->Parent != nullptr}});
				RecordFacts(OutFacts, TEXT("material"), TEXT("shader_complexity_evidence"), true, MaterialEvidence + TEXT(";quantitative_policy=TBD"),
					{{TEXT("base_material_present"), Material->GetMaterial() != nullptr}}, {}, {}, {}, true);
			}

			if (const UAnimationAsset* Animation = Cast<UAnimationAsset>(Object))
			{
				const USkeleton* Skeleton = Animation->GetSkeleton();
				const UAnimSequence* Sequence = Cast<UAnimSequence>(Animation);
				const int32 SampledKeys = Sequence == nullptr ? -1 : Sequence->GetNumberOfSampledKeys();
				const FString AnimationEvidence = FString::Printf(
					TEXT("%s;skeleton=%s;play_length=%g;sampled_keys=%d"),
					*ValidationEvidence,
					Skeleton == nullptr ? TEXT("missing") : *Skeleton->GetPathName(),
					Animation->GetPlayLength(), SampledKeys);
				RecordFacts(OutFacts, TEXT("skeletal_animation"), TEXT("rig_compatibility"), true, AnimationEvidence,
					{{TEXT("asset_data_valid"), bDataValid}, {TEXT("skeleton_present"), Skeleton != nullptr}});
				RecordFacts(OutFacts, TEXT("skeletal_animation"), TEXT("morph_policy"), false, TEXT("not_applicable:object_is_animation"));
				RecordFacts(OutFacts, TEXT("skeletal_animation"), TEXT("influences"), false, TEXT("not_applicable:object_is_animation"));
				RecordFacts(OutFacts, TEXT("skeletal_animation"), TEXT("socket_ownership"), false, TEXT("not_applicable:object_is_animation"));
				RecordFacts(OutFacts, TEXT("skeletal_animation"), TEXT("animation_complexity"), true, AnimationEvidence + TEXT(";quantitative_policy=TBD"),
					{{TEXT("asset_data_valid"), bDataValid}, {TEXT("skeleton_present"), Skeleton != nullptr}, {TEXT("sequence_asset"), Sequence != nullptr}},
					{{TEXT("sampled_key_count"), SampledKeys}}, {{TEXT("play_length"), Animation->GetPlayLength()}}, {}, true);
			}

			if (const USkeleton* SkeletonAsset = Cast<USkeleton>(Object))
			{
				const FReferenceSkeleton& ReferenceSkeleton = SkeletonAsset->GetReferenceSkeleton();
				int32 InvalidSocketCount = 0;
				for (const TObjectPtr<USkeletalMeshSocket>& Socket : SkeletonAsset->Sockets)
				{
					InvalidSocketCount += Socket == nullptr || ReferenceSkeleton.FindBoneIndex(Socket->BoneName) == INDEX_NONE ? 1 : 0;
				}
				const FString SkeletonEvidence = FString::Printf(
					TEXT("%s;bones=%d;sockets=%d"),
					*ValidationEvidence, ReferenceSkeleton.GetRawBoneNum(), SkeletonAsset->Sockets.Num());
				RecordFacts(OutFacts, TEXT("skeletal_animation"), TEXT("rig_compatibility"), true, SkeletonEvidence,
					{{TEXT("asset_data_valid"), bDataValid}, {TEXT("skeleton_present"), true}}, {{TEXT("bone_count"), ReferenceSkeleton.GetRawBoneNum()}});
				RecordFacts(OutFacts, TEXT("skeletal_animation"), TEXT("morph_policy"), false, TEXT("not_applicable:object_is_skeleton"));
				RecordFacts(OutFacts, TEXT("skeletal_animation"), TEXT("influences"), false, TEXT("not_applicable:object_is_skeleton"));
				RecordFacts(OutFacts, TEXT("skeletal_animation"), TEXT("socket_ownership"), true, SkeletonEvidence,
					{{TEXT("asset_data_valid"), bDataValid}}, {{TEXT("socket_count"), SkeletonAsset->Sockets.Num()}, {TEXT("invalid_socket_count"), InvalidSocketCount}});
				RecordFacts(OutFacts, TEXT("skeletal_animation"), TEXT("animation_complexity"), false, TEXT("not_applicable:object_is_skeleton"));
			}

			if (const UPhysicsAsset* PhysicsAsset = Cast<UPhysicsAsset>(Object))
			{
				const FString PhysicsEvidence = FString::Printf(
					TEXT("%s;skeletal_body_setups=%d;constraints=%d"),
					*ValidationEvidence, PhysicsAsset->SkeletalBodySetups.Num(), PhysicsAsset->ConstraintSetup.Num());
				RecordFacts(OutFacts, TEXT("collision"), TEXT("profile"), true, PhysicsEvidence,
					{{TEXT("asset_data_valid"), bDataValid}, {TEXT("collision_source_present"), PhysicsAsset->SkeletalBodySetups.Num() > 0}});
				RecordFacts(OutFacts, TEXT("collision"), TEXT("simple_complex_policy"), true, PhysicsEvidence,
					{{TEXT("asset_data_valid"), bDataValid}, {TEXT("collision_source_present"), PhysicsAsset->SkeletalBodySetups.Num() > 0}},
					{{TEXT("simple_shape_count"), PhysicsAsset->SkeletalBodySetups.Num()}});
				RecordFacts(OutFacts, TEXT("collision"), TEXT("presentation_equivalence"), true, PhysicsEvidence + TEXT(";quantitative_policy=TBD"),
					{{TEXT("authoritative_geometry_present"), PhysicsAsset->SkeletalBodySetups.Num() > 0}}, {}, {}, {}, true);
				RecordFacts(OutFacts, TEXT("skeletal_animation"), TEXT("rig_compatibility"), true, PhysicsEvidence,
					{{TEXT("asset_data_valid"), bDataValid}, {TEXT("physics_asset_present"), true}}, {{TEXT("body_setup_count"), PhysicsAsset->SkeletalBodySetups.Num()}});
			}

			if (const UWorld* World = Cast<UWorld>(Object))
			{
				const ULevel* PersistentLevel = World->PersistentLevel;
				const AWorldSettings* WorldSettings = World->GetWorldSettings(false, false);
				const UWorldPartition* WorldPartition = World->GetWorldPartition();
				const UDataLayerManager* DataLayerManager = World->GetDataLayerManager();
				const int32 DataLayerCount = DataLayerManager == nullptr ? 0 : DataLayerManager->GetDataLayerInstances().Num();
				int32 NavigationDataCount = 0;
				int32 StreamingNavigationDataCount = 0;
				int32 RuntimeGenerationNavigationDataCount = 0;
				TArray<FString> NavigationGenerationModes;
				if (PersistentLevel != nullptr)
				{
					for (const TObjectPtr<AActor>& Actor : PersistentLevel->Actors)
					{
						if (const ANavigationData* NavigationData = Cast<ANavigationData>(Actor.Get()))
						{
							++NavigationDataCount;
							StreamingNavigationDataCount += NavigationData->SupportsStreaming() ? 1 : 0;
							RuntimeGenerationNavigationDataCount += NavigationData->SupportsRuntimeGeneration() ? 1 : 0;
							NavigationGenerationModes.Add(FString::FromInt(static_cast<int32>(NavigationData->GetRuntimeGenerationMode())));
						}
					}
				}
				const bool bNavigationEnabled = WorldSettings != nullptr && WorldSettings->IsNavigationSystemEnabled();
				const bool bNavigationApplicable = bNavigationEnabled || NavigationDataCount > 0;
				const FString WorldEvidence = FString::Printf(
					TEXT("%s;persistent_level=%s;world_settings=%s;world_type=%d;levels=%d;world_partition=%s;data_layer_manager=%s;data_layers=%d;navigation_enabled=%s;navigation_config=%s;navigation_data=%d;streaming_navigation_data=%d;runtime_generation_navigation_data=%d;runtime_generation_modes=[%s]"),
					*ValidationEvidence,
					PersistentLevel == nullptr ? TEXT("missing") : *PersistentLevel->GetPathName(),
					WorldSettings == nullptr ? TEXT("missing") : *WorldSettings->GetPathName(),
					static_cast<int32>(World->WorldType),
					World->GetLevels().Num(),
					WorldPartition == nullptr ? TEXT("absent") : *WorldPartition->GetPathName(),
					DataLayerManager == nullptr ? TEXT("absent") : *DataLayerManager->GetPathName(),
					DataLayerCount,
					bNavigationEnabled ? TEXT("true") : TEXT("false"),
					WorldSettings == nullptr || WorldSettings->GetNavigationSystemConfig() == nullptr ? TEXT("missing") : TEXT("present"),
					NavigationDataCount,
					StreamingNavigationDataCount,
					RuntimeGenerationNavigationDataCount,
					*FString::Join(NavigationGenerationModes, TEXT(",")));
				RecordFacts(OutFacts, TEXT("map_world"), TEXT("map_identity"), true, WorldEvidence,
					{{TEXT("asset_data_valid"), bDataValid},
					 {TEXT("persistent_level_present"), PersistentLevel != nullptr},
					 {TEXT("world_settings_present"), WorldSettings != nullptr},
					 {TEXT("package_matches_intake"), Package.PackageName == IntakeAsset.AssetPath},
					 {TEXT("repository_path_matches_intake"), Package.RepositoryPath == IntakeAsset.RepositoryPath},
					 {TEXT("content_hash_matches_intake"), Package.ContentSha256 == IntakeAsset.ContentSha256}},
					{{TEXT("intake_content_version"), IntakeAsset.ContentVersion}}, {},
					{{TEXT("intake_stable_id"), IntakeAsset.StableId}});
				RecordFacts(OutFacts, TEXT("map_world"), TEXT("data_layers"), true, WorldEvidence + TEXT(";quantitative_policy=TBD"),
					{{TEXT("data_layer_manager_present"), DataLayerManager != nullptr}}, {{TEXT("data_layer_count"), DataLayerCount}}, {}, {}, true);
				RecordFacts(OutFacts, TEXT("map_world"), TEXT("pcg_authority"), true, WorldEvidence + TEXT(";quantitative_policy=TBD"), {}, {}, {}, {}, true);
				// NotGame references are allowed observations; only runtime (Game) dependencies on editor-only content fail.
				RecordFacts(OutFacts, TEXT("map_world"), TEXT("runtime_editor_boundary"), true, WorldEvidence,
					{{TEXT("asset_data_valid"), bDataValid}},
					{{TEXT("editor_only_runtime_dependency_count"), Package.EditorOnlyRuntimeDependencyFailures.Num()},
					 {TEXT("editor_only_dependency_count"), Package.EditorOnlyDependencies.Num()}});
				const bool bNavigationConfigPresent = WorldSettings != nullptr && WorldSettings->GetNavigationSystemConfig() != nullptr;
				// World metadata does not bind navigation packages to client/server cook or reference evidence.
				RecordFacts(OutFacts, TEXT("navigation"), TEXT("navigation_data_audience"), bNavigationApplicable,
					WorldEvidence + TEXT(";navigation_audience_evidence=unavailable"),
					{{TEXT("asset_data_valid"), bDataValid}, {TEXT("navigation_config_present"), bNavigationConfigPresent}},
					{{TEXT("navigation_data_count"), NavigationDataCount}});
				RecordFacts(OutFacts, TEXT("navigation"), TEXT("streaming_boundaries"), bNavigationApplicable, WorldEvidence + TEXT(";quantitative_policy=TBD"),
					{}, {{TEXT("navigation_data_count"), NavigationDataCount}, {TEXT("streaming_navigation_data_count"), StreamingNavigationDataCount}}, {}, {}, true);
				RecordFacts(OutFacts, TEXT("navigation"), TEXT("runtime_rebuild_policy"), bNavigationApplicable, WorldEvidence + TEXT(";quantitative_policy=TBD"),
					{}, {{TEXT("navigation_data_count"), NavigationDataCount}, {TEXT("runtime_generation_navigation_data_count"), RuntimeGenerationNavigationDataCount}}, {}, {}, true);
			}
		}

		const TSet<FString> RegistryFamilies = FAethelnContentValidationScanner::DeriveApplicableFamilies(Package);
		for (const FString& FamilyId : GovernedFamilies)
		{
			if (FamilyId == TEXT("reference_boundary"))
			{
				continue;
			}
			TArray<FAethelnContentCheckFacts>& FamilyFacts = OutFacts.FindOrAdd(FamilyId);
			const TArray<FString>& ExpectedChecks = Policy.ChecksByFamily.FindChecked(FamilyId);
			const bool bAnyApplicable = FamilyFacts.ContainsByPredicate([](const FAethelnContentCheckFacts& Facts) { return Facts.bApplicable; });
			if (RegistryFamilies.Contains(FamilyId) && !bAnyApplicable)
			{
				RecordFacts(
					OutFacts,
					FamilyId,
					ExpectedChecks[0],
					true,
					FString::Printf(TEXT("class-specific evaluator missing for Asset Registry classes [%s]"), *DescribeObservedClasses(Package)));
			}
			for (const FString& CheckId : ExpectedChecks)
			{
				if (!FamilyFacts.ContainsByPredicate([&CheckId](const FAethelnContentCheckFacts& Facts) { return Facts.CheckId == CheckId; }))
				{
					RecordFacts(OutFacts, FamilyId, CheckId, false, TEXT("not_applicable:no_class_specific_fact"));
				}
			}
			FamilyFacts.Sort([](const FAethelnContentCheckFacts& Left, const FAethelnContentCheckFacts& Right) { return Left.CheckId < Right.CheckId; });
		}
		CollectGarbage(RF_NoFlags, true);
		return true;
	}

	struct FLoadedProjectModule
	{
		FString Name;
		FAethelnBuildArtifactDescriptor Descriptor;
	};

	bool ResolveAndValidateArtifact(
		const FAethelnBuildArtifactDescriptor& Supplied,
		FString& OutAbsolutePath,
		FString& OutFailure)
	{
		const FString ProjectRoot = FPaths::ConvertRelativePathToFull(FPaths::ProjectDir());
		OutAbsolutePath = FPaths::ConvertRelativePathToFull(FPaths::Combine(ProjectRoot, Supplied.Path));
		FPaths::NormalizeFilename(OutAbsolutePath);
		FString CanonicalRelative = OutAbsolutePath;
		if (!FPaths::IsUnderDirectory(OutAbsolutePath, ProjectRoot)
			|| !FPaths::MakePathRelativeTo(CanonicalRelative, *ProjectRoot))
		{
			OutFailure = FString::Printf(TEXT("Build artifact '%s' is outside the project root."), *Supplied.Path);
			return false;
		}
		FPaths::NormalizeFilename(CanonicalRelative);
		if (CanonicalRelative != Supplied.Path)
		{
			OutFailure = FString::Printf(TEXT("Build artifact path '%s' is not canonical repository-relative form '%s'."), *Supplied.Path, *CanonicalRelative);
			return false;
		}
		const int64 ActualSize = IFileManager::Get().FileSize(*OutAbsolutePath);
		FString ActualHash;
		if (ActualSize <= 0 || ActualSize != Supplied.SizeBytes || !HashFileSha256(OutAbsolutePath, ActualHash, OutFailure))
		{
			if (OutFailure.IsEmpty())
			{
				OutFailure = FString::Printf(TEXT("Build artifact '%s' size does not match its supplied descriptor."), *Supplied.Path);
			}
			return false;
		}
		if (ActualHash != Supplied.Sha256)
		{
			OutFailure = FString::Printf(TEXT("Build artifact '%s' SHA-256 does not match its supplied descriptor."), *Supplied.Path);
			return false;
		}
		return true;
	}

	bool GatherLoadedProjectModules(
		const FAethelnContentValidationRunArguments& Arguments,
		TArray<FLoadedProjectModule>& OutModules,
		FString& OutFailure)
	{
		FString ReceiptPath;
		FString ManifestPath;
		if (!ResolveAndValidateArtifact(Arguments.TargetReceipt, ReceiptPath, OutFailure)
			|| !ResolveAndValidateArtifact(Arguments.ModuleManifest, ManifestPath, OutFailure))
		{
			return false;
		}
		FTargetReceipt Receipt;
		if (!Receipt.Read(ReceiptPath, false)
			|| Receipt.TargetName != Arguments.Target
			|| Receipt.Platform != Arguments.Platform
			|| Receipt.Configuration != EBuildConfiguration::Development
			|| Receipt.Version.BuildId.IsEmpty()
			|| Receipt.Version.BuildId != Arguments.TargetReceipt.BuildId)
		{
			OutFailure = TEXT("Target receipt identity or build ID does not match the frozen invocation provenance.");
			return false;
		}
		FModuleManifest Manifest;
		if (!FModuleManifest::TryRead(ManifestPath, Manifest)
			|| Manifest.BuildId.IsEmpty()
			|| Manifest.BuildId != Arguments.ModuleManifest.BuildId
			|| Manifest.BuildId != Receipt.Version.BuildId)
		{
			OutFailure = TEXT("Module manifest and target receipt do not share the supplied non-blank build ID.");
			return false;
		}
		const FString ExpectedManifestPath = FModuleManifest::GetFileName(FPaths::GetPath(ManifestPath), true);
		if (!FPaths::IsSamePath(ExpectedManifestPath, ManifestPath))
		{
			OutFailure = FString::Printf(TEXT("Module manifest '%s' is not the verified UE game-module manifest path '%s'."), *ManifestPath, *ExpectedManifestPath);
			return false;
		}

		const FString ProjectRoot = FPaths::ConvertRelativePathToFull(FPaths::ProjectDir());
		for (const FString& ModuleName : { FString(TEXT("GameCore")), FString(TEXT("GameTests")) })
		{
			const FName ModuleFName(*ModuleName);
			if (!FModuleManager::Get().IsModuleLoaded(ModuleFName))
			{
				OutFailure = FString::Printf(TEXT("Required project module '%s' is not loaded."), *ModuleName);
				return false;
			}
			FString ModulePath = FPaths::ConvertRelativePathToFull(FModuleManager::Get().GetModuleFilename(ModuleFName));
			FPaths::NormalizeFilename(ModulePath);
			const FString* ManifestFile = Manifest.ModuleNameToFileName.Find(ModuleName);
			if (ManifestFile == nullptr || FPaths::GetCleanFilename(ModulePath) != *ManifestFile)
			{
				OutFailure = FString::Printf(TEXT("Loaded module '%s' does not match the verified module manifest."), *ModuleName);
				return false;
			}
			FLoadedProjectModule Loaded;
			Loaded.Name = ModuleName;
			Loaded.Descriptor.Path = ModulePath;
			if (!FPaths::IsUnderDirectory(ModulePath, ProjectRoot)
				|| !FPaths::MakePathRelativeTo(Loaded.Descriptor.Path, *ProjectRoot))
			{
				OutFailure = FString::Printf(TEXT("Loaded module '%s' is outside the project root."), *ModuleName);
				return false;
			}
			FPaths::NormalizeFilename(Loaded.Descriptor.Path);
			Loaded.Descriptor.SizeBytes = IFileManager::Get().FileSize(*ModulePath);
			Loaded.Descriptor.BuildId = Manifest.BuildId;
			if (Loaded.Descriptor.SizeBytes <= 0 || !HashFileSha256(ModulePath, Loaded.Descriptor.Sha256, OutFailure))
			{
				return false;
			}
			OutModules.Add(MoveTemp(Loaded));
		}
		return OutModules.Num() == 2;
	}

	TSharedPtr<FJsonObject> MakeArtifactDescriptorJson(const FAethelnBuildArtifactDescriptor& Descriptor)
	{
		TSharedPtr<FJsonObject> Object = MakeShared<FJsonObject>();
		Object->SetStringField(TEXT("path"), Descriptor.Path);
		Object->SetNumberField(TEXT("size_bytes"), Descriptor.SizeBytes);
		Object->SetStringField(TEXT("sha256"), Descriptor.Sha256);
		Object->SetStringField(TEXT("build_id"), Descriptor.BuildId);
		return Object;
	}
}

bool FAethelnContentValidationScanner::ParseRegistrySnapshot(
	const FString& SnapshotJson,
	TArray<FAethelnObservedPackage>& OutPackages,
	FString& OutFailure)
{
	OutPackages.Reset();
	TSharedPtr<FJsonObject> Root;
	if (!ParseJsonDocument(SnapshotJson, Root, OutFailure)
		|| !RequireExactFields(Root, { TEXT("schema_id"), TEXT("schema_version"), TEXT("packages") }, TEXT("registry snapshot"), OutFailure))
	{
		return false;
	}
	FString SchemaId;
	int32 SchemaVersion = 0;
	if (!Root->TryGetStringField(TEXT("schema_id"), SchemaId)
		|| !Root->TryGetNumberField(TEXT("schema_version"), SchemaVersion)
		|| SchemaId != TEXT("aetheln.asset-registry-snapshot")
		|| SchemaVersion != 1)
	{
		OutFailure = TEXT("Registry snapshot has an incompatible schema identity.");
		return false;
	}
	const TArray<TSharedPtr<FJsonValue>>* PackageValues = nullptr;
	if (!Root->TryGetArrayField(TEXT("packages"), PackageValues) || PackageValues == nullptr || PackageValues->IsEmpty())
	{
		OutFailure = TEXT("Registry snapshot packages must not be empty.");
		return false;
	}
	const TArray<FString> PackageFields = {
		TEXT("package_name"), TEXT("repository_path"), TEXT("class_paths"), TEXT("tags"), TEXT("hard_dependencies"),
		TEXT("soft_dependencies"), TEXT("editor_only_dependencies"), TEXT("content_sha256"), TEXT("is_redirector")
	};
	TSet<FString> PackageNames;
	TSet<FString> RepositoryPaths;
	for (int32 Index = 0; Index < PackageValues->Num(); ++Index)
	{
		if (!(*PackageValues)[Index].IsValid() || (*PackageValues)[Index]->Type != EJson::Object)
		{
			OutFailure = FString::Printf(TEXT("registry snapshot packages[%d] must be an object."), Index);
			return false;
		}
		const TSharedPtr<FJsonObject> Object = (*PackageValues)[Index]->AsObject();
		const FString Context = FString::Printf(TEXT("registry snapshot packages[%d]"), Index);
		FAethelnObservedPackage Package;
		if (!RequireExactFields(Object, PackageFields, Context, OutFailure)
			|| !RequireString(Object, TEXT("package_name"), Context, Package.PackageName, OutFailure)
			|| !RequireString(Object, TEXT("repository_path"), Context, Package.RepositoryPath, OutFailure)
			|| !RequireStringArray(Object, TEXT("class_paths"), Context, Package.ClassPaths, OutFailure, false)
			|| !RequireStringArray(Object, TEXT("hard_dependencies"), Context, Package.HardDependencies, OutFailure)
			|| !RequireStringArray(Object, TEXT("soft_dependencies"), Context, Package.SoftDependencies, OutFailure)
			|| !RequireStringArray(Object, TEXT("editor_only_dependencies"), Context, Package.EditorOnlyDependencies, OutFailure)
			|| !RequireString(Object, TEXT("content_sha256"), Context, Package.ContentSha256, OutFailure)
			|| !Object->TryGetBoolField(TEXT("is_redirector"), Package.bRedirector))
		{
			if (OutFailure.IsEmpty()) { OutFailure = Context + TEXT(" contains an invalid typed field."); }
			return false;
		}
		const TSharedPtr<FJsonObject>* TagsPointer = nullptr;
		if (!Object->TryGetObjectField(TEXT("tags"), TagsPointer) || TagsPointer == nullptr)
		{
			OutFailure = Context + TEXT(".tags must be an object.");
			return false;
		}
		for (const auto& Tag : (*TagsPointer)->Values)
		{
			FString Value;
			if (Tag.Key == TEXT("applicability")
				|| Tag.Key == TEXT("status")
				|| Tag.Key == TEXT("deterministic_status")
				|| Tag.Key == TEXT("promotion_status")
				|| Tag.Key == TEXT("check_results")
				|| !Tag.Value.IsValid()
				|| !Tag.Value->TryGetString(Value))
			{
				OutFailure = Context + TEXT(".tags must contain raw string facts and cannot contain validation verdicts.");
				return false;
			}
			Package.Tags.Add(FString(Tag.Key.Len(), *Tag.Key), MoveTemp(Value));
		}
		bool bDuplicatePackage = false;
		bool bDuplicateRepositoryPath = false;
		PackageNames.Add(Package.PackageName, &bDuplicatePackage);
		RepositoryPaths.Add(Package.RepositoryPath, &bDuplicateRepositoryPath);
		TSet<FString> ClassifiedDependencies;
		bool bDuplicateDependencyClassification = false;
		bool bInvalidClassOrDependencyPath = false;
		for (const FString& ClassPath : Package.ClassPaths)
		{
			bInvalidClassOrDependencyPath = bInvalidClassOrDependencyPath || !IsValidAssetClassPath(ClassPath);
		}
		for (const TArray<FString>* Dependencies : { &Package.HardDependencies, &Package.SoftDependencies, &Package.EditorOnlyDependencies })
		{
			for (const FString& Dependency : *Dependencies)
			{
				bInvalidClassOrDependencyPath = bInvalidClassOrDependencyPath || !IsValidLongPackagePath(Dependency);
				bool bAlreadyClassified = false;
				ClassifiedDependencies.Add(Dependency, &bAlreadyClassified);
				bDuplicateDependencyClassification = bDuplicateDependencyClassification || bAlreadyClassified;
			}
		}
		if (!IsValidPackagePath(Package.PackageName)
			|| !RepositoryPathMatchesPackage(Package.RepositoryPath, Package.PackageName)
			|| !IsLowerSha256(Package.ContentSha256)
			|| bDuplicatePackage
			|| bDuplicateRepositoryPath
			|| bDuplicateDependencyClassification
			|| bInvalidClassOrDependencyPath)
		{
			OutFailure = Context + TEXT(" contains an invalid or duplicate package path, repository path, dependency classification, or content hash.");
			return false;
		}
		// Snapshots carry no package-flag facts, so EditorOnlyRuntimeDependencyFailures stays empty in snapshot mode.
		OutPackages.Add(MoveTemp(Package));
	}
	OutPackages.Sort([](const FAethelnObservedPackage& Left, const FAethelnObservedPackage& Right) { return Left.PackageName < Right.PackageName; });
	return true;
}

bool FAethelnContentValidationScanner::LoadVerifiedRegistrySnapshot(
	const FString& SnapshotPath,
	const FString& ExpectedSha256,
	TArray<FAethelnObservedPackage>& OutPackages,
	FString& OutFailure)
{
	FString SnapshotJson;
	return LoadBoundedJsonText(SnapshotPath, 64 * 1024 * 1024, ExpectedSha256, SnapshotJson, OutFailure)
		&& ParseRegistrySnapshot(SnapshotJson, OutPackages, OutFailure);
}

TSet<FString> FAethelnContentValidationScanner::DeriveApplicableFamilies(const FAethelnObservedPackage& Package)
{
	TSet<FString> Families;
	const FString ParentClass = Package.Tags.FindRef(TEXT("ParentClass")) + TEXT(" ") + Package.Tags.FindRef(TEXT("NativeParentClass"));
	const bool bMesh = HasClassFragment(Package, TEXT("StaticMesh")) || HasClassFragment(Package, TEXT("SkeletalMesh"));
	const bool bCollisionBlueprint = HasClassFragment(Package, TEXT("Blueprint"))
		&& (ParentClass.Contains(TEXT("Character"), ESearchCase::IgnoreCase) || ParentClass.Contains(TEXT("Pawn"), ESearchCase::IgnoreCase));
	if (bMesh || bCollisionBlueprint || HasClassFragment(Package, TEXT("PhysicsAsset")))
	{
		Families.Add(TEXT("collision"));
	}
	if (bMesh)
	{
		Families.Add(TEXT("rendering_suitability"));
	}
	if (HasClassFragment(Package, TEXT("Texture")))
	{
		Families.Add(TEXT("texture"));
	}
	if (HasClassFragment(Package, TEXT("Material")))
	{
		Families.Add(TEXT("material"));
	}
	if (HasClassFragment(Package, TEXT("SkeletalMesh"))
		|| HasClassFragment(Package, TEXT("Skeleton"))
		|| HasClassFragment(Package, TEXT("Anim"))
		|| HasClassFragment(Package, TEXT("BlendSpace"))
		|| HasClassFragment(Package, TEXT("ControlRig"))
		|| HasClassFragment(Package, TEXT("PhysicsAsset")))
	{
		Families.Add(TEXT("skeletal_animation"));
	}
	if (HasClassFragment(Package, TEXT("World")))
	{
		Families.Add(TEXT("map_world"));
		Families.Add(TEXT("navigation"));
	}
	else if (HasClassFragment(Package, TEXT("Navigation")) || HasClassFragment(Package, TEXT("NavMesh")))
	{
		Families.Add(TEXT("navigation"));
	}
	Families.Add(TEXT("reference_boundary"));
	return Families;
}

bool FAethelnContentValidationScanner::IsSoftReferenceAllowed(
	const FString& SourcePackage,
	const FString& SourceAudience,
	const FString& TargetPackage,
	const FString& TargetAudience,
	const TArray<FAethelnSoftReferenceRule>& Rules)
{
	for (const FAethelnSoftReferenceRule& Rule : Rules)
	{
		if (Rule.SourceAudience == SourceAudience
			&& Rule.TargetAudience == TargetAudience
			&& RegexMatchesEntireValue(Rule.SourcePackagePattern, SourcePackage)
			&& RegexMatchesEntireValue(Rule.TargetPackagePattern, TargetPackage))
		{
			return true;
		}
	}
	return false;
}

FString FAethelnContentValidationScanner::ClassifyEditorOnlyTarget(IAssetRegistry& Registry, const FString& TargetPackage)
{
	// UHT flags Editor-module script packages PKG_EditorOnly and UncookedOnly-module script packages
	// PKG_UncookedOnly; a saved editor-only content package carries PKG_EditorOnly in its package flags.
	if (TargetPackage.StartsWith(TEXT("/Script/")))
	{
		const UPackage* ScriptPackage = FindPackage(nullptr, *TargetPackage);
		if (ScriptPackage == nullptr)
		{
			return TEXT("script package is not loaded in the Editor, so it cannot be proven runtime content");
		}
		return ScriptPackage->HasAnyPackageFlags(PKG_EditorOnly | PKG_UncookedOnly)
			? FString(TEXT("script package is flagged PKG_EditorOnly or PKG_UncookedOnly"))
			: FString();
	}
	TArray<FAssetData> TargetAssets;
	Registry.GetAssetsByPackageName(FName(*TargetPackage), TargetAssets, true, true);
	for (const FAssetData& TargetAsset : TargetAssets)
	{
		if (TargetAsset.HasAnyPackageFlags(PKG_EditorOnly | PKG_UncookedOnly))
		{
			return TEXT("package is flagged PKG_EditorOnly or PKG_UncookedOnly");
		}
	}
	return FString();
}

TArray<FString> FAethelnContentValidationScanner::SelectEditorOnlyRuntimeDependencyFailures(
	const FAethelnObservedPackage& Package,
	TFunctionRef<FString(const FString& TargetPackage)> ClassifyTarget)
{
	TArray<FString> Failures;
	for (const TArray<FString>* RuntimeDependencies : { &Package.HardDependencies, &Package.SoftDependencies })
	{
		for (const FString& Dependency : *RuntimeDependencies)
		{
			const FString Reason = ClassifyTarget(Dependency);
			if (!Reason.IsEmpty())
			{
				Failures.Add(FString::Printf(TEXT("editor-only runtime dependency '%s' is prohibited: %s"), *Dependency, *Reason));
			}
		}
	}
	Failures.Sort();
	return Failures;
}

FAethelnContentFamilyResult FAethelnContentValidationScanner::EvaluateFamilyFacts(
	const FString& FamilyId,
	const TArray<FAethelnContentCheckFacts>& Facts,
	bool bLifecycleBlocksPromotion)
{
	struct FDerivedFactResult
	{
		FString Status;
		FString Evidence;
	};
	auto DeriveSingleFact = [&FamilyId](const FAethelnContentCheckFacts& Fact) -> FDerivedFactResult
	{
		auto Derived = [&Fact](const TCHAR* Status, const FString& Detail)
		{
			return FDerivedFactResult{Status, Fact.Evidence.IsEmpty() ? Detail : Fact.Evidence + TEXT(";") + Detail};
		};
		auto Unavailable = [&Derived](const TCHAR* Missing)
		{
			return Derived(TEXT("evidence_unavailable"), FString::Printf(TEXT("evidence_unavailable:%s"), Missing));
		};
		auto RequiredBool = [&Fact](const TCHAR* Name) { return Fact.BooleanFacts.Find(Name); };
		auto RequiredInt = [&Fact](const TCHAR* Name) { return Fact.IntegerFacts.Find(Name); };
		auto RequiredDecimal = [&Fact](const TCHAR* Name) { return Fact.DecimalFacts.Find(Name); };
		auto RequiredText = [&Fact](const TCHAR* Name) { return Fact.TextFacts.Find(Name); };
		auto DeriveDeclaredPolicy = [&RequiredBool, &Derived, &Unavailable](const TCHAR* Declaration, const TCHAR* Compliance)
		{
			const bool* Declared = RequiredBool(Declaration);
			if (Declared == nullptr || !*Declared) { return Unavailable(Declaration); }
			const bool* Compliant = RequiredBool(Compliance);
			if (Compliant == nullptr) { return Unavailable(Compliance); }
			return *Compliant ? Derived(TEXT("passed"), FString::Printf(TEXT("%s=true"), Compliance)) : Derived(TEXT("failed"), FString::Printf(TEXT("%s=false"), Compliance));
		};
		if (const bool* DataValid = RequiredBool(TEXT("asset_data_valid")); DataValid != nullptr && !*DataValid)
		{
			return Derived(TEXT("failed"), TEXT("asset_data_valid=false"));
		}

		if (FamilyId == TEXT("collision") && Fact.CheckId == TEXT("profile"))
		{
			const bool* SourcePresent = RequiredBool(TEXT("collision_source_present"));
			const FString* ProfileName = RequiredText(TEXT("profile_name"));
			if (SourcePresent == nullptr) { return Unavailable(TEXT("collision_source_present")); }
			if (!*SourcePresent) { return Derived(TEXT("failed"), TEXT("collision_source_present=false")); }
			if (ProfileName == nullptr) { return Unavailable(TEXT("profile_name")); }
			return ProfileName->IsEmpty() || *ProfileName == TEXT("None")
				? Derived(TEXT("failed"), TEXT("profile_name=missing"))
				: Derived(TEXT("passed"), TEXT("profile_name_observed"));
		}
		if (FamilyId == TEXT("collision") && Fact.CheckId == TEXT("simple_complex_policy"))
		{
			const bool* SourcePresent = RequiredBool(TEXT("collision_source_present"));
			const int64* ShapeCount = RequiredInt(TEXT("simple_shape_count"));
			const int64* TraceFlag = RequiredInt(TEXT("trace_flag"));
			if (SourcePresent == nullptr || ShapeCount == nullptr || TraceFlag == nullptr) { return Unavailable(TEXT("collision_geometry_or_trace_fact")); }
			if (!*SourcePresent || *ShapeCount <= 0 || *TraceFlag < 0) { return Derived(TEXT("failed"), TEXT("collision_geometry_or_trace_fact_invalid")); }
			const bool* PolicyDeclared = RequiredBool(TEXT("trace_policy_declared"));
			if (PolicyDeclared == nullptr || !*PolicyDeclared) { return Unavailable(TEXT("trace_policy_declaration")); }
			const bool* PolicyCompliant = RequiredBool(TEXT("trace_policy_compliant"));
			if (PolicyCompliant == nullptr) { return Unavailable(TEXT("trace_policy_compliance")); }
			return *PolicyCompliant ? Derived(TEXT("passed"), TEXT("trace_policy_compliant=true")) : Derived(TEXT("failed"), TEXT("trace_policy_compliant=false"));
		}
		if (FamilyId == TEXT("collision") && Fact.CheckId == TEXT("presentation_equivalence"))
		{
			const bool* GeometryPresent = RequiredBool(TEXT("authoritative_geometry_present"));
			if (GeometryPresent == nullptr) { return Unavailable(TEXT("authoritative_geometry_present")); }
			if (!*GeometryPresent) { return Derived(TEXT("failed"), TEXT("authoritative_geometry_present=false")); }
			const bool* Verified = RequiredBool(TEXT("presentation_equivalence_verified"));
			if (Verified == nullptr) { return Unavailable(TEXT("presentation_equivalence_verified")); }
			return *Verified ? Derived(TEXT("passed"), TEXT("presentation_equivalence_verified=true")) : Derived(TEXT("failed"), TEXT("presentation_equivalence_verified=false"));
		}

		if (FamilyId == TEXT("rendering_suitability") && Fact.CheckId == TEXT("lod"))
		{
			const int64* SourceModels = RequiredInt(TEXT("source_model_count"));
			const int64* RenderLods = RequiredInt(TEXT("render_lod_count"));
			if (SourceModels == nullptr || RenderLods == nullptr) { return Unavailable(TEXT("source_model_count_or_render_lod_count")); }
			if (*SourceModels <= 0 || *RenderLods <= 0) { return Derived(TEXT("failed"), TEXT("lod_counts_non_positive")); }
			return DeriveDeclaredPolicy(TEXT("lod_policy_recorded"), TEXT("lod_suitable"));
		}
		if (FamilyId == TEXT("rendering_suitability") && Fact.CheckId == TEXT("hlod"))
		{
			return DeriveDeclaredPolicy(TEXT("hlod_policy_recorded"), TEXT("hlod_suitable"));
		}
		if (FamilyId == TEXT("rendering_suitability") && Fact.CheckId == TEXT("nanite_suitability"))
		{
			return DeriveDeclaredPolicy(TEXT("nanite_policy_recorded"), TEXT("nanite_suitable"));
		}
		if (FamilyId == TEXT("rendering_suitability") && Fact.CheckId == TEXT("streaming"))
		{
			return DeriveDeclaredPolicy(TEXT("streaming_policy_recorded"), TEXT("streaming_suitable"));
		}

		if (FamilyId == TEXT("texture") && Fact.CheckId == TEXT("mips"))
		{
			const int64* Width = RequiredInt(TEXT("width"));
			const int64* Height = RequiredInt(TEXT("height"));
			const int64* Mips = RequiredInt(TEXT("mip_count"));
			if (Width == nullptr || Height == nullptr || Mips == nullptr) { return Unavailable(TEXT("texture_dimensions_or_mip_count")); }
			if (*Width <= 0 || *Height <= 0 || *Mips <= 0) { return Derived(TEXT("failed"), TEXT("texture_dimensions_or_mips_non_positive")); }
			return DeriveDeclaredPolicy(TEXT("mip_intent_recorded"), TEXT("mip_intent_compliant"));
		}
		if (FamilyId == TEXT("texture") && Fact.CheckId == TEXT("pbr_channels"))
		{
			return DeriveDeclaredPolicy(TEXT("pbr_channel_semantics_recorded"), TEXT("pbr_channel_semantics_compliant"));
		}
		if (FamilyId == TEXT("texture") && Fact.CheckId == TEXT("tiling"))
		{
			return DeriveDeclaredPolicy(TEXT("tiling_intent_recorded"), TEXT("tiling_intent_compliant"));
		}
		if (FamilyId == TEXT("texture") && Fact.CheckId == TEXT("compression"))
		{
			return DeriveDeclaredPolicy(TEXT("compression_intent_recorded"), TEXT("compression_intent_compliant"));
		}
		if (FamilyId == TEXT("texture") && Fact.CheckId == TEXT("streaming"))
		{
			return DeriveDeclaredPolicy(TEXT("streaming_policy_recorded"), TEXT("streaming_suitable"));
		}

		if (FamilyId == TEXT("material") && Fact.CheckId == TEXT("material_instance_policy"))
		{
			const bool* Declared = RequiredBool(TEXT("instance_policy_declared"));
			if (Declared == nullptr || !*Declared) { return Unavailable(TEXT("instance_policy_declared")); }
			const bool* IsInstance = RequiredBool(TEXT("is_instance"));
			const bool* ParentPresent = RequiredBool(TEXT("parent_present"));
			if (IsInstance == nullptr || ParentPresent == nullptr) { return Unavailable(TEXT("material_instance_or_parent_fact")); }
			return *IsInstance && *ParentPresent
				? Derived(TEXT("passed"), TEXT("material_instance_parent_present"))
				: Derived(TEXT("failed"), TEXT("material_instance_policy_not_satisfied"));
		}
		if (FamilyId == TEXT("material") && Fact.CheckId == TEXT("shader_complexity_evidence"))
		{
			return DeriveDeclaredPolicy(TEXT("shader_evidence_recorded"), TEXT("shader_within_budget"));
		}

		if (FamilyId == TEXT("skeletal_animation") && Fact.CheckId == TEXT("rig_compatibility"))
		{
			const bool* SkeletonPresent = RequiredBool(TEXT("skeleton_present"));
			if (SkeletonPresent == nullptr) { return Unavailable(TEXT("skeleton_present")); }
			if (!*SkeletonPresent) { return Derived(TEXT("failed"), TEXT("skeleton_present=false")); }
			return DeriveDeclaredPolicy(TEXT("rig_compatibility_observed"), TEXT("rig_compatible"));
		}
		if (FamilyId == TEXT("skeletal_animation") && Fact.CheckId == TEXT("morph_policy"))
		{
			return DeriveDeclaredPolicy(TEXT("morph_policy_recorded"), TEXT("morph_policy_compliant"));
		}
		if (FamilyId == TEXT("skeletal_animation") && Fact.CheckId == TEXT("influences"))
		{
			const bool* Observed = RequiredBool(TEXT("influence_observation_available"));
			const int64* Maximum = RequiredInt(TEXT("maximum_influences"));
			if (Observed == nullptr || !*Observed || Maximum == nullptr) { return Unavailable(TEXT("influence_observation")); }
			if (*Maximum <= 0) { return Derived(TEXT("failed"), TEXT("maximum_influences_non_positive")); }
			return DeriveDeclaredPolicy(TEXT("influence_policy_recorded"), TEXT("influences_within_budget"));
		}
		if (FamilyId == TEXT("skeletal_animation") && Fact.CheckId == TEXT("socket_ownership"))
		{
			const int64* SocketCount = RequiredInt(TEXT("socket_count"));
			const int64* InvalidSocketCount = RequiredInt(TEXT("invalid_socket_count"));
			if (SocketCount == nullptr || InvalidSocketCount == nullptr) { return Unavailable(TEXT("socket_observation")); }
			return *SocketCount >= 0 && *InvalidSocketCount == 0
				? Derived(TEXT("passed"), TEXT("socket_ownership_valid"))
				: Derived(TEXT("failed"), TEXT("socket_ownership_invalid"));
		}
		if (FamilyId == TEXT("skeletal_animation") && Fact.CheckId == TEXT("animation_complexity"))
		{
			const double* PlayLength = RequiredDecimal(TEXT("play_length"));
			const bool* SequenceAsset = RequiredBool(TEXT("sequence_asset"));
			const int64* SampledKeys = RequiredInt(TEXT("sampled_key_count"));
			if (PlayLength == nullptr || SequenceAsset == nullptr || SampledKeys == nullptr) { return Unavailable(TEXT("animation_length_or_sample_count")); }
			if (!(*PlayLength >= 0.0 && (!*SequenceAsset || *SampledKeys > 0)))
			{
				return Derived(TEXT("failed"), TEXT("animation_observations_invalid"));
			}
			return DeriveDeclaredPolicy(TEXT("animation_complexity_policy_recorded"), TEXT("animation_within_budget"));
		}

		if (FamilyId == TEXT("map_world") && Fact.CheckId == TEXT("map_identity"))
		{
			const bool* PersistentLevel = RequiredBool(TEXT("persistent_level_present"));
			const bool* WorldSettings = RequiredBool(TEXT("world_settings_present"));
			const bool* PackageMatches = RequiredBool(TEXT("package_matches_intake"));
			const bool* RepositoryMatches = RequiredBool(TEXT("repository_path_matches_intake"));
			const bool* HashMatches = RequiredBool(TEXT("content_hash_matches_intake"));
			const FString* StableId = RequiredText(TEXT("intake_stable_id"));
			const int64* ContentVersion = RequiredInt(TEXT("intake_content_version"));
			if (PersistentLevel == nullptr || WorldSettings == nullptr || PackageMatches == nullptr || RepositoryMatches == nullptr
				|| HashMatches == nullptr || StableId == nullptr || ContentVersion == nullptr)
			{
				return Unavailable(TEXT("world_components_or_governed_intake_identity"));
			}
			return *PersistentLevel && *WorldSettings && *PackageMatches && *RepositoryMatches && *HashMatches
				&& !StableId->IsEmpty() && *ContentVersion > 0
				? Derived(TEXT("passed"), TEXT("map_identity_bound_to_intake"))
				: Derived(TEXT("failed"), TEXT("map_identity_binding_mismatch"));
		}
		if (FamilyId == TEXT("map_world") && Fact.CheckId == TEXT("data_layers"))
		{
			return DeriveDeclaredPolicy(TEXT("data_layer_policy_recorded"), TEXT("data_layer_policy_compliant"));
		}
		if (FamilyId == TEXT("map_world") && Fact.CheckId == TEXT("pcg_authority"))
		{
			return DeriveDeclaredPolicy(TEXT("pcg_authority_recorded"), TEXT("pcg_authority_compliant"));
		}
		if (FamilyId == TEXT("map_world") && Fact.CheckId == TEXT("runtime_editor_boundary"))
		{
			// editor_only_dependency_count records allowed NotGame references and never decides this check.
			const int64* EditorOnlyRuntimeDependencies = RequiredInt(TEXT("editor_only_runtime_dependency_count"));
			if (EditorOnlyRuntimeDependencies == nullptr) { return Unavailable(TEXT("editor_only_runtime_dependency_count")); }
			return *EditorOnlyRuntimeDependencies == 0
				? Derived(TEXT("passed"), TEXT("editor_only_runtime_dependency_count=0"))
				: Derived(TEXT("failed"), TEXT("editor_only_runtime_dependencies_present"));
		}

		if (FamilyId == TEXT("navigation") && Fact.CheckId == TEXT("navigation_data_audience"))
		{
			const bool* ConfigPresent = RequiredBool(TEXT("navigation_config_present"));
			const int64* DataCount = RequiredInt(TEXT("navigation_data_count"));
			if (ConfigPresent == nullptr || DataCount == nullptr) { return Unavailable(TEXT("navigation_config_or_data")); }
			// Navigation ownership is explicit per map, and the intake schema cannot yet declare a
			// requirement; the engine-default enabled flag alone never proves one, so no data stays unproven.
			if (*DataCount <= 0) { return Unavailable(TEXT("navigation_intent_undeclared")); }
			if (!*ConfigPresent) { return Derived(TEXT("failed"), TEXT("navigation_config_invalid")); }
			// A producer must bind these observations to the governed navigation packages and build provenance.
			// The live world collector cannot set this evidence marker from the map's intake audience.
			const bool* AudienceEvidence = RequiredBool(TEXT("navigation_audience_evidence_recorded"));
			if (AudienceEvidence == nullptr || !*AudienceEvidence) { return Unavailable(TEXT("navigation_audience_evidence_recorded")); }
			const bool* ClientAudienceValid = RequiredBool(TEXT("client_audience_valid"));
			const bool* ServerAudienceValid = RequiredBool(TEXT("server_audience_valid"));
			if (ClientAudienceValid == nullptr || ServerAudienceValid == nullptr) { return Unavailable(TEXT("navigation_client_or_server_audience")); }
			return *ClientAudienceValid && *ServerAudienceValid
				? Derived(TEXT("passed"), TEXT("navigation_data_audience_valid"))
				: Derived(TEXT("failed"), TEXT("navigation_data_audience_invalid"));
		}
		if (FamilyId == TEXT("navigation") && Fact.CheckId == TEXT("streaming_boundaries"))
		{
			return DeriveDeclaredPolicy(TEXT("streaming_boundary_policy_recorded"), TEXT("streaming_boundary_policy_compliant"));
		}
		if (FamilyId == TEXT("navigation") && Fact.CheckId == TEXT("runtime_rebuild_policy"))
		{
			return DeriveDeclaredPolicy(TEXT("runtime_rebuild_policy_recorded"), TEXT("runtime_rebuild_policy_compliant"));
		}

		if (FamilyId == TEXT("reference_boundary"))
		{
			const int64* ViolationCount = RequiredInt(TEXT("violation_count"));
			if (ViolationCount == nullptr) { return Unavailable(TEXT("violation_count")); }
			return *ViolationCount == 0
				? Derived(TEXT("passed"), TEXT("violation_count=0"))
				: Derived(TEXT("failed"), FString::Printf(TEXT("violation_count=%lld"), *ViolationCount));
		}
		return Unavailable(TEXT("unsupported_fact_evaluator"));
	};

	TMap<FString, TArray<const FAethelnContentCheckFacts*>> FactsByCheck;
	for (const FAethelnContentCheckFacts& Fact : Facts)
	{
		FactsByCheck.FindOrAdd(Fact.CheckId).Add(&Fact);
	}
	TArray<FString> CheckIds;
	FactsByCheck.GetKeys(CheckIds);
	CheckIds.Sort();

	FAethelnContentFamilyResult Result;
	Result.PolicyId = FamilyId;
	bool bAnyApplicable = false;
	bool bAnyFailure = false;
	bool bAnyUnavailable = false;
	bool bAnyPromotionBlock = false;
	TArray<FString> EvidenceParts;
	for (const FString& CheckId : CheckIds)
	{
		bool bCheckApplicable = false;
		bool bCheckFailure = false;
		bool bCheckUnavailable = false;
		bool bCheckPromotionBlock = false;
		TArray<FString> CheckEvidence;
		for (const FAethelnContentCheckFacts* Fact : FactsByCheck.FindChecked(CheckId))
		{
			if (!Fact->bApplicable)
			{
				if (!Fact->Evidence.IsEmpty()) { CheckEvidence.Add(Fact->Evidence); }
				continue;
			}
			bCheckApplicable = true;
			const FDerivedFactResult Derived = DeriveSingleFact(*Fact);
			bCheckFailure = bCheckFailure || Derived.Status == TEXT("failed");
			bCheckUnavailable = bCheckUnavailable || Derived.Status == TEXT("evidence_unavailable");
			bCheckPromotionBlock = bCheckPromotionBlock || Fact->bHasUnresolvedThreshold;
			CheckEvidence.Add(Derived.Evidence);
		}

		FAethelnContentCheckResult Check;
		Check.CheckId = CheckId;
		Check.Applicability = bCheckApplicable ? TEXT("applicable") : TEXT("not_applicable");
		Check.DeterministicStatus = !bCheckApplicable
			? TEXT("not_applicable")
			: (bCheckFailure ? TEXT("failed") : (bCheckUnavailable ? TEXT("evidence_unavailable") : TEXT("passed")));
		Check.PromotionStatus = !bCheckApplicable
			? TEXT("not_applicable")
			: ((bCheckFailure || bCheckUnavailable || bCheckPromotionBlock || bLifecycleBlocksPromotion) ? TEXT("non_promotion") : TEXT("eligible"));
		Check.Evidence = FString::Join(CheckEvidence, TEXT(" | "));
		bAnyApplicable = bAnyApplicable || bCheckApplicable;
		bAnyFailure = bAnyFailure || bCheckFailure;
		bAnyUnavailable = bAnyUnavailable || bCheckUnavailable;
		bAnyPromotionBlock = bAnyPromotionBlock || bCheckPromotionBlock;
		EvidenceParts.Add(FString::Printf(TEXT("%s=%s/%s:%s"), *Check.CheckId, *Check.DeterministicStatus, *Check.PromotionStatus, *Check.Evidence));
		Result.CheckResults.Add(MoveTemp(Check));
	}

	Result.Applicability = bAnyApplicable ? TEXT("applicable") : TEXT("not_applicable");
	Result.DeterministicStatus = !bAnyApplicable
		? TEXT("not_applicable")
		: (bAnyFailure ? TEXT("failed") : (bAnyUnavailable ? TEXT("evidence_unavailable") : TEXT("passed")));
	Result.PromotionStatus = bAnyApplicable
		? ((bAnyFailure || bAnyUnavailable || bAnyPromotionBlock || bLifecycleBlocksPromotion) ? TEXT("non_promotion") : TEXT("eligible"))
		: TEXT("not_applicable");
	Result.Evidence = bAnyApplicable
		? FString::Join(EvidenceParts, TEXT("; "))
		: FString::Printf(TEXT("policy:%s:not_applicable:no_observed_checks"), *FamilyId);
	return Result;
}

bool FAethelnContentValidationScanner::ScanLiveRegistry(TArray<FAethelnObservedPackage>& OutPackages, FString& OutFailure)
{
	FAssetRegistryModule& Module = FModuleManager::LoadModuleChecked<FAssetRegistryModule>(TEXT("AssetRegistry"));
	IAssetRegistry& Registry = Module.Get();
	Registry.SearchAllAssets(true);
	TArray<FAssetData> AllAssets;
	if (!Registry.GetAllAssets(AllAssets, true))
	{
		OutFailure = TEXT("Asset Registry could not enumerate on-disk assets.");
		return false;
	}

	TMap<FString, FAethelnObservedPackage> Packages;
	for (const FAssetData& Asset : AllAssets)
	{
		const FString PackageName = Asset.PackageName.ToString();
		if (!PackageName.StartsWith(TEXT("/Game/")))
		{
			continue;
		}
		FAethelnObservedPackage& Package = Packages.FindOrAdd(PackageName);
		Package.PackageName = PackageName;
		Package.ClassPaths.AddUnique(Asset.AssetClassPath.ToString());
		Package.bRedirector = Package.bRedirector || Asset.IsRedirector();
		for (const FName TagName : {
			FName(TEXT("ParentClass")),
			FName(TEXT("NativeParentClass")),
			FName(TEXT("Skeleton")),
			FName(TEXT("StableContentId")),
			FName(TEXT("ContentVersion")),
			FName(TEXT("Audience")) })
		{
			FString TagValue;
			if (Asset.GetTagValue(TagName, TagValue) && !TagValue.IsEmpty())
			{
				Package.Tags.FindOrAdd(TagName.ToString()) = TagValue;
			}
		}
	}
	if (Packages.IsEmpty())
	{
		OutFailure = TEXT("Asset Registry returned no on-disk /Game packages.");
		return false;
	}

	for (auto& Entry : Packages)
	{
		FAethelnObservedPackage& Package = Entry.Value;
		Package.ClassPaths.Sort();
		const bool bMap = Package.ClassPaths.ContainsByPredicate([](const FString& ClassPath) { return ClassPath.EndsWith(TEXT(".World")); });
		const FString Extension = bMap ? FPackageName::GetMapPackageExtension() : FPackageName::GetAssetPackageExtension();
		FString Filename = FPackageName::LongPackageNameToFilename(Package.PackageName, Extension);
		Filename = FPaths::ConvertRelativePathToFull(Filename);
		if (!FPaths::FileExists(Filename))
		{
			OutFailure = FString::Printf(TEXT("Asset Registry package '%s' does not resolve to an on-disk package file."), *Package.PackageName);
			return false;
		}
		FString RelativeFilename = Filename;
		if (!FPaths::MakePathRelativeTo(RelativeFilename, *FPaths::ConvertRelativePathToFull(FPaths::ProjectDir())))
		{
			OutFailure = FString::Printf(TEXT("Package file '%s' is outside the project root."), *Filename);
			return false;
		}
		FPaths::NormalizeFilename(RelativeFilename);
		Package.RepositoryPath = RelativeFilename;
		if (!HashFileSha256(Filename, Package.ContentSha256, OutFailure))
		{
			return false;
		}

		auto GatherDependencies = [&Registry, &Package](UE::AssetRegistry::EDependencyQuery Query, TArray<FString>& OutDependencies) -> bool
		{
			TArray<FName> Dependencies;
			if (!Registry.GetDependencies(
				FName(*Package.PackageName),
				Dependencies,
				UE::AssetRegistry::EDependencyCategory::Package,
				UE::AssetRegistry::FDependencyQuery(Query)))
			{
				return false;
			}
			for (const FName Dependency : Dependencies)
			{
				OutDependencies.AddUnique(Dependency.ToString());
			}
			OutDependencies.Sort();
			return true;
		};
		if (!GatherDependencies(UE::AssetRegistry::EDependencyQuery::Hard | UE::AssetRegistry::EDependencyQuery::Game, Package.HardDependencies)
			|| !GatherDependencies(UE::AssetRegistry::EDependencyQuery::NotHard | UE::AssetRegistry::EDependencyQuery::Game, Package.SoftDependencies)
			|| !GatherDependencies(UE::AssetRegistry::EDependencyQuery::NotGame, Package.EditorOnlyDependencies))
		{
			OutFailure = FString::Printf(TEXT("Asset Registry dependency query failed for '%s'."), *Package.PackageName);
			return false;
		}
		Package.EditorOnlyRuntimeDependencyFailures = SelectEditorOnlyRuntimeDependencyFailures(
			Package,
			[&Registry](const FString& TargetPackage) { return ClassifyEditorOnlyTarget(Registry, TargetPackage); });
		OutPackages.Add(MoveTemp(Package));
	}
	OutPackages.Sort([](const FAethelnObservedPackage& Left, const FAethelnObservedPackage& Right) { return Left.PackageName < Right.PackageName; });
	return true;
}

int32 FAethelnContentValidationScanner::Run(const FAethelnContentValidationRunArguments& Arguments, FString& OutFailure)
{
	const bool bHasSnapshotPath = !Arguments.RegistrySnapshotPath.IsEmpty();
	const bool bHasSnapshotHash = IsLowerSha256(Arguments.RegistrySnapshotSha256);
	const bool bSnapshotMode = Arguments.RegistrySource == TEXT("test_snapshot");
	if (Arguments.bAllowTestRegistrySnapshot != bHasSnapshotPath
		|| Arguments.bAllowTestRegistrySnapshot != bHasSnapshotHash
		|| Arguments.bAllowTestRegistrySnapshot != bSnapshotMode)
	{
		OutFailure = TEXT("Guarded snapshot path, SHA-256, authorization, and registry source must form one closed combination.");
		return 3;
	}
	if (!Arguments.bAllowTestRegistrySnapshot && Arguments.RegistrySource != TEXT("live_asset_registry"))
	{
		OutFailure = TEXT("Live registry mode rejects snapshot-only members and unsupported registry sources.");
		return 3;
	}
	TSharedPtr<FJsonObject> PolicyRoot;
	TSharedPtr<FJsonObject> IntakeRoot;
	if (!LoadBoundedJsonDocument(Arguments.PolicyPath, 1024 * 1024, Arguments.PolicySha256, PolicyRoot, OutFailure)
		|| !LoadBoundedJsonDocument(Arguments.IntakePath, 8 * 1024 * 1024, Arguments.IntakeSha256, IntakeRoot, OutFailure))
	{
		return 3;
	}
	FPolicyData Policy;
	TMap<FString, FSourceGroup> SourceGroups;
	TArray<FIntakeAsset> IntakeAssets;
	if (!ParsePolicy(PolicyRoot, Policy, OutFailure)
		|| !ParseIntake(IntakeRoot, SourceGroups, IntakeAssets, OutFailure))
	{
		return 3;
	}

	TArray<FAethelnObservedPackage> ObservedPackages;
	if (Arguments.bAllowTestRegistrySnapshot)
	{
		if (!LoadVerifiedRegistrySnapshot(Arguments.RegistrySnapshotPath, Arguments.RegistrySnapshotSha256, ObservedPackages, OutFailure))
		{
			if (OutFailure.IsEmpty()) { OutFailure = FString::Printf(TEXT("Could not read registry snapshot '%s'."), *Arguments.RegistrySnapshotPath); }
			return 3;
		}
	}
	else if (!ScanLiveRegistry(ObservedPackages, OutFailure))
	{
		return 3;
	}

	if (ObservedPackages.Num() != IntakeAssets.Num())
	{
		OutFailure = FString::Printf(
			TEXT("Asset Registry observed %d /Game packages but the runtime intake registry contains %d; complete closed coverage is required."),
			ObservedPackages.Num(),
			IntakeAssets.Num());
		return 3;
	}
	TMap<FString, const FAethelnObservedPackage*> ObservedByPath;
	for (const FAethelnObservedPackage& Package : ObservedPackages)
	{
		if (ObservedByPath.Contains(Package.PackageName))
		{
			OutFailure = FString::Printf(TEXT("Asset Registry contains duplicate package '%s'."), *Package.PackageName);
			return 3;
		}
		ObservedByPath.Add(Package.PackageName, &Package);
	}
	TMap<FString, const FIntakeAsset*> IntakeByPath;
	for (const FIntakeAsset& Asset : IntakeAssets)
	{
		if (!ObservedByPath.Contains(Asset.AssetPath))
		{
			OutFailure = FString::Printf(TEXT("Runtime intake package '%s' is absent from the Asset Registry scan."), *Asset.AssetPath);
			return 3;
		}
		IntakeByPath.Add(Asset.AssetPath, &Asset);
	}
	for (const FAethelnObservedPackage& Package : ObservedPackages)
	{
		if (!IntakeByPath.Contains(Package.PackageName))
		{
			OutFailure = FString::Printf(TEXT("Observed /Game package '%s' has no runtime intake record."), *Package.PackageName);
			return 3;
		}
	}

	TArray<FLoadedProjectModule> LoadedProjectModules;
	if (!GatherLoadedProjectModules(Arguments, LoadedProjectModules, OutFailure))
	{
		if (OutFailure.IsEmpty())
		{
			OutFailure = TEXT("Could not verify the two loaded project modules.");
		}
		return 3;
	}

	TArray<TSharedPtr<FJsonValue>> AssetValues;
	TArray<TSharedPtr<FJsonValue>> FindingValues;
	int32 ErrorCount = 0;
	int32 NonPromotionCount = 0;
	for (const FIntakeAsset& IntakeAsset : IntakeAssets)
	{
		const FAethelnObservedPackage& Observed = **ObservedByPath.Find(IntakeAsset.AssetPath);
		const FSourceGroup& SourceGroup = *SourceGroups.Find(IntakeAsset.SourceGroupId);
		TMap<FString, TArray<FAethelnContentCheckFacts>> FamilyFacts;
		if (!EvaluateLoadedPackage(Observed, IntakeAsset, Policy, FamilyFacts, OutFailure))
		{
			return 3;
		}

		TArray<FString> StableIdentityFailures;
		TArray<FString> RedirectorFailures;
		TArray<FString> BrokenReferenceFailures;
		TArray<FString> VersionFailures;
		TArray<FString> AudienceFailures;
		TArray<FString> HardAudienceFailures;
		if (Observed.RepositoryPath != IntakeAsset.RepositoryPath)
		{
			BrokenReferenceFailures.Add(FString::Printf(TEXT("repository path '%s' does not match observed '%s'"), *IntakeAsset.RepositoryPath, *Observed.RepositoryPath));
		}
		if (Observed.ContentSha256 != IntakeAsset.ContentSha256)
		{
			BrokenReferenceFailures.Add(TEXT("content SHA-256 does not match the observed package bytes"));
		}
		if (Observed.bRedirector)
		{
			RedirectorFailures.Add(TEXT("package contains an unresolved redirector"));
		}

		const FString ParentClasses = Observed.Tags.FindRef(TEXT("ParentClass")) + TEXT(" ") + Observed.Tags.FindRef(TEXT("NativeParentClass"));
		const bool bHasGovernedSearchableIdentity = HasClassFragment(Observed, TEXT("AethelnPrimaryAssetDefinition"))
			|| ParentClasses.Contains(TEXT("AethelnPrimaryAssetDefinition"), ESearchCase::CaseSensitive);
		if (bHasGovernedSearchableIdentity)
		{
			const FString ExpectedAudienceTag = IntakeAsset.Audience == TEXT("shared")
				? TEXT("Shared")
				: (IntakeAsset.Audience == TEXT("server_only") ? TEXT("ServerOnly") : TEXT("ClientOnly"));
			const FString ObservedStableId = Observed.Tags.FindRef(TEXT("StableContentId"));
			const FString ObservedVersion = Observed.Tags.FindRef(TEXT("ContentVersion"));
			const FString ObservedAudience = Observed.Tags.FindRef(TEXT("Audience"));
			if (ObservedStableId != IntakeAsset.StableId)
			{
				StableIdentityFailures.Add(FString::Printf(TEXT("searchable StableContentId tag '%s' does not match intake '%s'"), *ObservedStableId, *IntakeAsset.StableId));
			}
			if (ObservedVersion != FString::FromInt(IntakeAsset.ContentVersion))
			{
				VersionFailures.Add(FString::Printf(TEXT("searchable ContentVersion tag '%s' does not exactly match intake version %d"), *ObservedVersion, IntakeAsset.ContentVersion));
			}
			if (ObservedAudience != ExpectedAudienceTag)
			{
				AudienceFailures.Add(FString::Printf(TEXT("searchable Audience tag '%s' does not exactly match intake audience '%s'"), *ObservedAudience, *IntakeAsset.Audience));
			}
		}

		BrokenReferenceFailures.Append(Observed.EditorOnlyRuntimeDependencyFailures);
		auto ResolveTarget = [&IntakeByPath, &BrokenReferenceFailures](const FString& Dependency) -> const FIntakeAsset*
		{
			if (!Dependency.StartsWith(TEXT("/Game/")))
			{
				return nullptr;
			}
			const FIntakeAsset* const* Target = IntakeByPath.Find(Dependency);
			if (Target == nullptr)
			{
				BrokenReferenceFailures.Add(FString::Printf(TEXT("broken or ungoverned /Game dependency '%s'"), *Dependency));
				return nullptr;
			}
			return *Target;
		};
		// NotGame (editor-only) references are allowed, but a /Game target must still resolve to governed content.
		for (const FString& Dependency : Observed.EditorOnlyDependencies)
		{
			ResolveTarget(Dependency);
		}
		for (const FString& Dependency : Observed.HardDependencies)
		{
			const FIntakeAsset* Target = ResolveTarget(Dependency);
			if (Target == nullptr)
			{
				continue;
			}
			const TSet<FString>* AllowedTargets = Policy.HardAudienceRules.Find(IntakeAsset.Audience);
			if (AllowedTargets == nullptr || !AllowedTargets->Contains(Target->Audience))
			{
				HardAudienceFailures.Add(FString::Printf(
					TEXT("hard dependency '%s' crosses prohibited audience boundary %s -> %s"),
					*Dependency,
					*IntakeAsset.Audience,
					*Target->Audience));
			}
		}
		for (const FString& Dependency : Observed.SoftDependencies)
		{
			const FIntakeAsset* Target = ResolveTarget(Dependency);
			if (Target == nullptr)
			{
				continue;
			}
			if (!IsSoftReferenceAllowed(IntakeAsset.AssetPath, IntakeAsset.Audience, Target->AssetPath, Target->Audience, Policy.SoftReferenceRules))
			{
				AudienceFailures.Add(FString::Printf(
					TEXT("soft dependency '%s' has no declared full-path audience rule for %s -> %s"),
					*Dependency,
					*IntakeAsset.Audience,
					*Target->Audience));
			}
		}
		StableIdentityFailures.Sort();
		RedirectorFailures.Sort();
		BrokenReferenceFailures.Sort();
		VersionFailures.Sort();
		AudienceFailures.Sort();
		HardAudienceFailures.Sort();
		auto RecordReferenceCheck = [&FamilyFacts](const FString& CheckId, const TArray<FString>& Failures)
		{
			RecordFacts(
				FamilyFacts,
				TEXT("reference_boundary"),
				CheckId,
				true,
				Failures.IsEmpty() ? TEXT("verified from closed intake and Asset Registry facts") : FString::Join(Failures, TEXT("; ")),
				{}, {{TEXT("violation_count"), Failures.Num()}});
		};
		RecordReferenceCheck(TEXT("stable_id_unique"), StableIdentityFailures);
		RecordReferenceCheck(TEXT("redirectors"), RedirectorFailures);
		RecordReferenceCheck(TEXT("broken_references"), BrokenReferenceFailures);
		RecordReferenceCheck(TEXT("compatible_content_version"), VersionFailures);
		RecordReferenceCheck(TEXT("audience_reachability"), AudienceFailures);
		RecordReferenceCheck(TEXT("hard_reference_exceptions"), HardAudienceFailures);
		FamilyFacts.FindChecked(TEXT("reference_boundary")).Sort(
			[](const FAethelnContentCheckFacts& Left, const FAethelnContentCheckFacts& Right) { return Left.CheckId < Right.CheckId; });

		TArray<TSharedPtr<FJsonValue>> FamilyResultValues;
		for (const FString& FamilyId : GovernedFamilies)
		{
			const TArray<FAethelnContentCheckFacts>& Facts = FamilyFacts.FindChecked(FamilyId);
			const FAethelnContentFamilyResult Evaluated = EvaluateFamilyFacts(
				FamilyId,
				Facts,
				IntakeAsset.LifecycleState == TEXT("temporary_prototype"));
			TSharedPtr<FJsonObject> FamilyResult = MakeShared<FJsonObject>();
			FamilyResult->SetStringField(TEXT("policy_id"), FamilyId);
			FamilyResult->SetStringField(TEXT("applicability"), Evaluated.Applicability);
			FamilyResult->SetStringField(TEXT("deterministic_status"), Evaluated.DeterministicStatus);
			FamilyResult->SetStringField(TEXT("promotion_status"), Evaluated.PromotionStatus);
			FamilyResult->SetStringField(TEXT("evidence"), Evaluated.Evidence);
			TArray<TSharedPtr<FJsonValue>> CheckResultValues;
			for (const FAethelnContentCheckResult& Check : Evaluated.CheckResults)
			{
				TSharedPtr<FJsonObject> CheckObject = MakeShared<FJsonObject>();
				CheckObject->SetStringField(TEXT("check_id"), Check.CheckId);
				CheckObject->SetStringField(TEXT("applicability"), Check.Applicability);
				CheckObject->SetStringField(TEXT("deterministic_status"), Check.DeterministicStatus);
				CheckObject->SetStringField(TEXT("promotion_status"), Check.PromotionStatus);
				CheckObject->SetStringField(TEXT("evidence"), Check.Evidence);
				CheckResultValues.Add(JsonObjectValue(CheckObject));
			}
			FamilyResult->SetArrayField(TEXT("check_results"), MoveTemp(CheckResultValues));
			if (Evaluated.DeterministicStatus == TEXT("failed"))
			{
				FindingValues.Add(JsonObjectValue(MakeFinding(
					FamilyId,
					Policy.FailureCodes.FindChecked(FamilyId),
					IntakeAsset.AssetPath,
					TEXT("error"),
					Evaluated.Evidence,
					TEXT("Correct the failed deterministic asset facts and rerun read-only validation."),
					FString::Printf(TEXT("family_results.%s.check_results"), *FamilyId))));
				++ErrorCount;
			}
			else if (Evaluated.PromotionStatus == TEXT("non_promotion"))
			{
				const bool bEvidenceUnavailable = Evaluated.DeterministicStatus == TEXT("evidence_unavailable");
				FindingValues.Add(JsonObjectValue(MakeFinding(
					FamilyId,
					Policy.FailureCodes.FindChecked(FamilyId).Replace(TEXT(".failed"), TEXT(".non_promotion"), ESearchCase::CaseSensitive),
					IntakeAsset.AssetPath,
					TEXT("non_promotion"),
					bEvidenceUnavailable
						? TEXT("The governed family is applicable, but required raw evaluation evidence is unavailable.")
						: TEXT("The governed family remains non-promotable while a quantitative policy is TBD or the asset remains temporary_prototype."),
					bEvidenceUnavailable
						? TEXT("Supply the missing observed facts through the governed scanner path, then rerun validation; do not author a verdict or edit evidence to suppress this result.")
						: TEXT("Supply accepted owner-controlled measurements and lifecycle approval, then rerun validation; do not edit evidence to suppress this result."),
					bEvidenceUnavailable ? FString::Printf(TEXT("family_results.%s.check_results"), *FamilyId) : TEXT("thresholds.unresolved_budgets"))));
				++NonPromotionCount;
			}
			FamilyResultValues.Add(JsonObjectValue(FamilyResult));
		}

		TSharedPtr<FJsonObject> Provenance = MakeShared<FJsonObject>();
		Provenance->SetStringField(TEXT("author_or_provider"), SourceGroup.AuthorOrProvider);
		Provenance->SetStringField(TEXT("source_record"), SourceGroup.SourceRecord);
		Provenance->SetStringField(TEXT("source_version"), SourceGroup.SourceVersion);
		Provenance->SetStringField(TEXT("license_or_permission_evidence"), SourceGroup.LicenseOrPermissionEvidence);
		Provenance->SetStringField(TEXT("modifications"), SourceGroup.Modifications);
		Provenance->SetStringField(TEXT("generation_metadata_when_applicable"), SourceGroup.GenerationMetadata);
		Provenance->SetStringField(TEXT("content_sha256"), IntakeAsset.ContentSha256);
		Provenance->SetStringField(TEXT("reviewer"), SourceGroup.Reviewer);
		Provenance->SetStringField(TEXT("approval_state"), SourceGroup.ApprovalState);

		TSharedPtr<FJsonObject> AssetObject = MakeShared<FJsonObject>();
		AssetObject->SetStringField(TEXT("asset_path"), IntakeAsset.AssetPath);
		AssetObject->SetStringField(TEXT("stable_id"), IntakeAsset.StableId);
		AssetObject->SetNumberField(TEXT("content_version"), IntakeAsset.ContentVersion);
		AssetObject->SetStringField(TEXT("audience"), IntakeAsset.Audience);
		AssetObject->SetStringField(TEXT("lifecycle_state"), IntakeAsset.LifecycleState);
		AssetObject->SetObjectField(TEXT("provenance"), Provenance);
		AssetObject->SetObjectField(TEXT("lifecycle_evidence"), IntakeAsset.LifecycleEvidence);
		AssetObject->SetArrayField(TEXT("family_results"), MoveTemp(FamilyResultValues));
		AssetValues.Add(JsonObjectValue(AssetObject));
	}

	TSharedPtr<FJsonObject> Execution = MakeShared<FJsonObject>();
	Execution->SetBoolField(TEXT("repository_clean"), true);
	Execution->SetStringField(TEXT("engine_revision"), Arguments.EngineRevision);
	Execution->SetStringField(TEXT("engine_tag"), Arguments.EngineTag);
	Execution->SetStringField(TEXT("engine_binary_sha256"), Arguments.EngineBinarySha256);
	Execution->SetStringField(TEXT("build_version_sha256"), Arguments.BuildVersionSha256);
	Execution->SetStringField(TEXT("target"), Arguments.Target);
	Execution->SetStringField(TEXT("platform"), Arguments.Platform);
	Execution->SetStringField(TEXT("configuration"), Arguments.Configuration);
	Execution->SetStringField(TEXT("editor_build_command_sha256"), Arguments.EditorBuildCommandSha256);
	Execution->SetStringField(TEXT("editor_build_log_sha256"), Arguments.EditorBuildLogSha256);
	Execution->SetStringField(TEXT("compiler_version"), Arguments.CompilerVersion);
	Execution->SetStringField(TEXT("compiler_sha256"), Arguments.CompilerSha256);
	Execution->SetStringField(TEXT("resource_compiler_version"), Arguments.ResourceCompilerVersion);
	Execution->SetStringField(TEXT("resource_compiler_sha256"), Arguments.ResourceCompilerSha256);
	Execution->SetObjectField(TEXT("target_receipt"), MakeArtifactDescriptorJson(Arguments.TargetReceipt));
	Execution->SetObjectField(TEXT("module_manifest"), MakeArtifactDescriptorJson(Arguments.ModuleManifest));
	TArray<TSharedPtr<FJsonValue>> LoadedModuleValues;
	for (const FLoadedProjectModule& LoadedModule : LoadedProjectModules)
	{
		TSharedPtr<FJsonObject> ModuleObject = MakeShared<FJsonObject>();
		ModuleObject->SetStringField(TEXT("name"), LoadedModule.Name);
		ModuleObject->SetStringField(TEXT("path"), LoadedModule.Descriptor.Path);
		ModuleObject->SetNumberField(TEXT("size_bytes"), LoadedModule.Descriptor.SizeBytes);
		ModuleObject->SetStringField(TEXT("sha256"), LoadedModule.Descriptor.Sha256);
		ModuleObject->SetStringField(TEXT("build_id"), LoadedModule.Descriptor.BuildId);
		LoadedModuleValues.Add(JsonObjectValue(ModuleObject));
	}
	Execution->SetArrayField(TEXT("loaded_project_modules"), MoveTemp(LoadedModuleValues));
	Execution->SetStringField(TEXT("project_sha256"), Arguments.ProjectSha256);
	Execution->SetStringField(TEXT("policy_sha256"), Arguments.PolicySha256);
	Execution->SetStringField(TEXT("intake_sha256"), Arguments.IntakeSha256);
	Execution->SetStringField(TEXT("invocation_sha256"), Arguments.InvocationSha256);
	Execution->SetStringField(TEXT("registry_source"), Arguments.RegistrySource);

	TSharedPtr<FJsonObject> Counts = MakeShared<FJsonObject>();
	Counts->SetNumberField(TEXT("assets"), AssetValues.Num());
	Counts->SetNumberField(TEXT("findings"), FindingValues.Num());
	Counts->SetNumberField(TEXT("errors"), ErrorCount);
	Counts->SetNumberField(TEXT("non_promotion"), NonPromotionCount);

	const FString Result = ErrorCount > 0 ? TEXT("failed") : (NonPromotionCount > 0 ? TEXT("non_promotion") : TEXT("passed"));
	TSharedPtr<FJsonObject> Report = MakeShared<FJsonObject>();
	Report->SetStringField(TEXT("schema_id"), TEXT("aetheln.content-validation-report"));
	Report->SetNumberField(TEXT("schema_version"), 2);
	Report->SetStringField(TEXT("revision"), Arguments.Revision);
	Report->SetStringField(TEXT("engine_identity"), Arguments.EngineTag + TEXT("@") + Arguments.EngineRevision);
	Report->SetStringField(TEXT("policy_sha256"), Arguments.PolicySha256);
	Report->SetStringField(TEXT("intake_sha256"), Arguments.IntakeSha256);
	Report->SetStringField(TEXT("audience"), TEXT("all"));
	Report->SetStringField(TEXT("started_utc"), Arguments.StartedUtc);
	Report->SetStringField(TEXT("finished_utc"), FDateTime::UtcNow().ToIso8601());
	Report->SetStringField(TEXT("command"), FString::Printf(TEXT("GameTests.AethelnContentValidation invocation_sha256=%s"), *Arguments.InvocationSha256));
	Report->SetObjectField(TEXT("execution_provenance"), Execution);
	Report->SetObjectField(TEXT("counts"), Counts);
	Report->SetArrayField(TEXT("assets"), MoveTemp(AssetValues));
	Report->SetArrayField(TEXT("findings"), MoveTemp(FindingValues));
	Report->SetStringField(TEXT("result"), Result);

	FString Json;
	const TSharedRef<TJsonWriter<TCHAR, TPrettyJsonPrintPolicy<TCHAR>>> Writer =
		TJsonWriterFactory<TCHAR, TPrettyJsonPrintPolicy<TCHAR>>::Create(&Json);
	if (!FJsonSerializer::Serialize(Report.ToSharedRef(), Writer))
	{
		OutFailure = TEXT("Could not serialize the content-validation report.");
		return 3;
	}
	if (!WriteReportToRetainedHandle(Json, OutFailure))
	{
		return 3;
	}
	if (ErrorCount > 0)
	{
		OutFailure = FString::Printf(TEXT("%d deterministic content-validation error(s) were reported."), ErrorCount);
		return 2;
	}
	OutFailure.Reset();
	return 0;
}
