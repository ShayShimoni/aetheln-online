#include "AethelnPrimaryAssetDefinition.h"
#include "AethelnContentValidationScanner.h"
#include "HAL/FileManager.h"
#include "Misc/AutomationTest.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
#include "UObject/UnrealType.h"

#if WITH_DEV_AUTOMATION_TESTS

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnPrimaryAssetIdentityTest,
	"Aetheln.Content.Validation.PrimaryAssetIdentity",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPrimaryAssetIdentityTest::RunTest(const FString& Parameters)
{
	UAethelnPrimaryAssetDefinition* Definition = NewObject<UAethelnPrimaryAssetDefinition>();
	TestFalse(TEXT("An empty stable identity is invalid"), Definition->GetPrimaryAssetId().IsValid());

	Definition->StableContentId = TEXT("content.prototype.blockout_wall");
	Definition->ContentVersion = 0;
	TestFalse(TEXT("A non-positive content version invalidates the primary asset identity"), Definition->GetPrimaryAssetId().IsValid());

	Definition->ContentVersion = 1;
	Definition->Audience = EAethelnContentAudience::Shared;

	const FPrimaryAssetId Identity = Definition->GetPrimaryAssetId();
	TestTrue(TEXT("A non-empty stable identity is valid"), Identity.IsValid());
	TestEqual(TEXT("The primary asset type is governed"), Identity.PrimaryAssetType, FPrimaryAssetType(TEXT("AethelnContent")));
	TestEqual(TEXT("Package naming does not define stable identity"), Identity.PrimaryAssetName, FName(TEXT("content.prototype.blockout_wall")));
	TestTrue(TEXT("Content versions are positive"), Definition->ContentVersion > 0);
	TestEqual(TEXT("Audience remains an independent field"), Definition->Audience, EAethelnContentAudience::Shared);
	for (const FName PropertyName : { FName(TEXT("StableContentId")), FName(TEXT("ContentVersion")), FName(TEXT("Audience")) })
	{
		const FProperty* Property = FindFProperty<FProperty>(UAethelnPrimaryAssetDefinition::StaticClass(), PropertyName);
		TestNotNull(*FString::Printf(TEXT("%s is reflected"), *PropertyName.ToString()), Property);
		if (Property != nullptr)
		{
			TestTrue(
				*FString::Printf(TEXT("%s is Asset Registry searchable"), *PropertyName.ToString()),
				Property->HasAnyPropertyFlags(CPF_AssetRegistrySearchable));
		}
	}

	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnContentValidationSnapshotTest,
	"Aetheln.Content.Validation.RegistrySnapshot",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnContentValidationSnapshotTest::RunTest(const FString& Parameters)
{
	const FString Snapshot = TEXT(R"JSON(
{
	"schema_id": "aetheln.asset-registry-snapshot",
	"schema_version": 1,
	"packages": [
		{
			"package_name": "/Game/Fixtures/SM_GovernedFixture",
			"repository_path": "Content/Fixtures/SM_GovernedFixture.uasset",
			"class_paths": ["/Script/Engine.StaticMesh"],
			"tags": {},
			"hard_dependencies": ["/Game/Fixtures/MI_GovernedFixture"],
			"soft_dependencies": [],
			"editor_only_dependencies": [],
			"content_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			"is_redirector": false
		}
	]
}
)JSON");
	TArray<FAethelnObservedPackage> Packages;
	FString Failure;
	TestTrue(TEXT("A closed injected Asset Registry snapshot parses"), FAethelnContentValidationScanner::ParseRegistrySnapshot(Snapshot, Packages, Failure));
	TestEqual(TEXT("One package is observed"), Packages.Num(), 1);
	if (Packages.Num() != 1)
	{
		AddError(FString::Printf(TEXT("Snapshot parser diagnostic: %s"), *Failure));
		return false;
	}

	const TSet<FString> Families = FAethelnContentValidationScanner::DeriveApplicableFamilies(Packages[0]);
	TestTrue(TEXT("Static meshes derive collision applicability"), Families.Contains(TEXT("collision")));
	TestTrue(TEXT("Static meshes derive rendering suitability applicability"), Families.Contains(TEXT("rendering_suitability")));
	TestTrue(TEXT("Every package derives reference-boundary applicability"), Families.Contains(TEXT("reference_boundary")));
	TestFalse(TEXT("Static meshes do not author texture applicability"), Families.Contains(TEXT("texture")));

	const FString UnknownFieldSnapshot = Snapshot.Replace(TEXT("\"is_redirector\": false"), TEXT("\"is_redirector\": false, \"unsupported\": true"));
	TArray<FAethelnObservedPackage> RejectedPackages;
	Failure.Reset();
	TestFalse(TEXT("An unknown snapshot field fails closed"), FAethelnContentValidationScanner::ParseRegistrySnapshot(UnknownFieldSnapshot, RejectedPackages, Failure));
	TestTrue(TEXT("Unknown-field diagnostics are actionable"), Failure.Contains(TEXT("unsupported")));
	const FString InjectedVerdictSnapshot = Snapshot.Replace(
		TEXT("\"is_redirector\": false"),
		TEXT("\"is_redirector\": false, \"deterministic_status\": \"passed\""));
	RejectedPackages.Reset();
	Failure.Reset();
	TestFalse(TEXT("A raw snapshot cannot inject a validation verdict"), FAethelnContentValidationScanner::ParseRegistrySnapshot(InjectedVerdictSnapshot, RejectedPackages, Failure));
	TestTrue(TEXT("Injected-verdict diagnostics are actionable"), Failure.Contains(TEXT("unsupported")));
	const FString VerdictTagSnapshot = Snapshot.Replace(TEXT("\"tags\": {}"), TEXT("\"tags\": {\"promotion_status\": \"eligible\"}"));
	RejectedPackages.Reset();
	Failure.Reset();
	TestFalse(TEXT("A raw tag map cannot disguise a validation verdict as a fact"), FAethelnContentValidationScanner::ParseRegistrySnapshot(VerdictTagSnapshot, RejectedPackages, Failure));
	TestTrue(TEXT("Verdict-tag diagnostics are actionable"), Failure.Contains(TEXT("cannot contain validation verdicts")));

	const FString MismatchedPathSnapshot = Snapshot.Replace(
		TEXT("Content/Fixtures/SM_GovernedFixture.uasset"),
		TEXT("Content/Fixtures/SM_DifferentFixture.uasset"));
	RejectedPackages.Reset();
	Failure.Reset();
	TestFalse(TEXT("A repository/package identity mismatch fails closed"), FAethelnContentValidationScanner::ParseRegistrySnapshot(MismatchedPathSnapshot, RejectedPackages, Failure));
	TestTrue(TEXT("Path-mismatch diagnostics are actionable"), Failure.Contains(TEXT("repository path")));

	const FString DuplicateClassificationSnapshot = Snapshot.Replace(
		TEXT("\"soft_dependencies\": []"),
		TEXT("\"soft_dependencies\": [\"/Game/Fixtures/MI_GovernedFixture\"]"));
	RejectedPackages.Reset();
	Failure.Reset();
	TestFalse(TEXT("A dependency assigned to two classifications fails closed"), FAethelnContentValidationScanner::ParseRegistrySnapshot(DuplicateClassificationSnapshot, RejectedPackages, Failure));
	TestTrue(TEXT("Dependency-classification diagnostics are actionable"), Failure.Contains(TEXT("dependency classification")));

	FAethelnSoftReferenceRule Rule;
	Rule.Id = TEXT("shared-to-client-presentation");
	Rule.SourcePackagePattern = TEXT("^/Game(?:/[A-Za-z0-9_]+)+$");
	Rule.SourceAudience = TEXT("shared");
	Rule.TargetPackagePattern = TEXT("^/Game(?:/[A-Za-z0-9_]+)+$");
	Rule.TargetAudience = TEXT("client_only");
	Rule.Justification = TEXT("Fixture presentation rule.");
	const TArray<FAethelnSoftReferenceRule> Rules = { Rule };
	TestTrue(
		TEXT("A declared anchored soft-reference rule passes"),
		FAethelnContentValidationScanner::IsSoftReferenceAllowed(
			TEXT("/Game/Fixtures/DA_Shared"),
			TEXT("shared"),
			TEXT("/Game/Fixtures/T_Client"),
			TEXT("client_only"),
			Rules));
	TestFalse(
		TEXT("An undeclared soft-reference audience fails closed"),
		FAethelnContentValidationScanner::IsSoftReferenceAllowed(
			TEXT("/Game/Fixtures/DA_Shared"),
			TEXT("shared"),
			TEXT("/Game/Fixtures/DA_Server"),
			TEXT("server_only"),
			Rules));

	const FString VerifiedSnapshot = TEXT("{\"schema_id\":\"aetheln.asset-registry-snapshot\",\"schema_version\":1,\"packages\":[{\"package_name\":\"/Game/Fixtures/SM_GovernedFixture\",\"repository_path\":\"Content/Fixtures/SM_GovernedFixture.uasset\",\"class_paths\":[\"/Script/Engine.StaticMesh\"],\"tags\":{},\"hard_dependencies\":[],\"soft_dependencies\":[],\"editor_only_dependencies\":[],\"content_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"is_redirector\":false}]}");
	const FString VerifiedSnapshotPath = FPaths::CreateTempFilename(*FPaths::ProjectSavedDir(), TEXT("AethelnSnapshotBinding"), TEXT(".json"));
	TestTrue(TEXT("Snapshot seam fixture writes exact UTF-8 bytes"), FFileHelper::SaveStringToFile(VerifiedSnapshot, *VerifiedSnapshotPath, FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM));
	TArray<FAethelnObservedPackage> VerifiedPackages;
	Failure.Reset();
	TestTrue(TEXT("Matching snapshot digest verifies and parses the same bytes"), FAethelnContentValidationScanner::LoadVerifiedRegistrySnapshot(VerifiedSnapshotPath, TEXT("b35c6d2c283bf2c71c1acd91b2c4fa37a8ec82d630dbc9613dfe35b0975db3d9"), VerifiedPackages, Failure));
	Failure.Reset();
	TestFalse(TEXT("Mismatched snapshot digest fails closed"), FAethelnContentValidationScanner::LoadVerifiedRegistrySnapshot(VerifiedSnapshotPath, FString::ChrN(64, TEXT('0')), VerifiedPackages, Failure));
	Failure.Reset();
	TestFalse(TEXT("Missing snapshot digest fails closed"), FAethelnContentValidationScanner::LoadVerifiedRegistrySnapshot(VerifiedSnapshotPath, FString(), VerifiedPackages, Failure));
	Failure.Reset();
	TestFalse(TEXT("Malformed snapshot digest fails closed"), FAethelnContentValidationScanner::LoadVerifiedRegistrySnapshot(VerifiedSnapshotPath, TEXT("ABC"), VerifiedPackages, Failure));
	const TArray<uint8> InvalidUtf8 = { 0x7b, 0x22, 0x78, 0x22, 0x3a, 0xc0, 0xaf, 0x7d };
	TestTrue(TEXT("Invalid UTF-8 seam fixture writes exact bytes"), FFileHelper::SaveArrayToFile(InvalidUtf8, *VerifiedSnapshotPath));
	Failure.Reset();
	TestFalse(TEXT("Verified invalid UTF-8 fails before JSON parsing"), FAethelnContentValidationScanner::LoadVerifiedRegistrySnapshot(VerifiedSnapshotPath, TEXT("45a71f22df795c4c4e563d4e8eba0c3a08b8f4dc3dacb11ee4ee52d44f6b564d"), VerifiedPackages, Failure));
	const FString MalformedSnapshot = TEXT("{\"schema_id\":\"aetheln.asset-registry-snapshot\"");
	TestTrue(TEXT("Malformed JSON seam fixture writes exact UTF-8 bytes"), FFileHelper::SaveStringToFile(MalformedSnapshot, *VerifiedSnapshotPath, FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM));
	Failure.Reset();
	TestFalse(TEXT("Verified malformed JSON still fails parsing"), FAethelnContentValidationScanner::LoadVerifiedRegistrySnapshot(VerifiedSnapshotPath, TEXT("29cc841c7558c03eeff420ea2235119ce4b9ba68a9b3414c4bd5aaf90ae5208c"), VerifiedPackages, Failure));
	IFileManager::Get().Delete(*VerifiedSnapshotPath);

	struct FRawFactCase
	{
		FString FamilyId;
		FAethelnContentCheckFacts Valid;
		FAethelnContentCheckFacts Invalid;
	};
	auto MakeFact = [](const FString& CheckId)
	{
		FAethelnContentCheckFacts Fact;
		Fact.CheckId = CheckId;
		Fact.bApplicable = true;
		Fact.Evidence = TEXT("typed raw fixture facts");
		return Fact;
	};
	TArray<FRawFactCase> RawFactCases;
	{
		FAethelnContentCheckFacts Valid = MakeFact(TEXT("profile"));
		Valid.BooleanFacts.Add(TEXT("asset_data_valid"), true);
		Valid.BooleanFacts.Add(TEXT("collision_source_present"), true);
		Valid.TextFacts.Add(TEXT("profile_name"), TEXT("Pawn"));
		FAethelnContentCheckFacts Invalid = Valid;
		Invalid.TextFacts[TEXT("profile_name")] = TEXT("");
		RawFactCases.Add({ TEXT("collision"), Valid, Invalid });
	}
	{
		FAethelnContentCheckFacts Valid = MakeFact(TEXT("lod"));
		Valid.BooleanFacts.Add(TEXT("asset_data_valid"), true);
		Valid.BooleanFacts.Add(TEXT("lod_policy_recorded"), true);
		Valid.BooleanFacts.Add(TEXT("lod_suitable"), true);
		Valid.IntegerFacts.Add(TEXT("source_model_count"), 1);
		Valid.IntegerFacts.Add(TEXT("render_lod_count"), 1);
		FAethelnContentCheckFacts Invalid = Valid;
		Invalid.IntegerFacts[TEXT("render_lod_count")] = 0;
		RawFactCases.Add({ TEXT("rendering_suitability"), Valid, Invalid });
	}
	{
		FAethelnContentCheckFacts Valid = MakeFact(TEXT("mips"));
		Valid.BooleanFacts.Add(TEXT("asset_data_valid"), true);
		Valid.BooleanFacts.Add(TEXT("mip_intent_recorded"), true);
		Valid.BooleanFacts.Add(TEXT("mip_intent_compliant"), true);
		Valid.IntegerFacts.Add(TEXT("width"), 1024);
		Valid.IntegerFacts.Add(TEXT("height"), 1024);
		Valid.IntegerFacts.Add(TEXT("mip_count"), 11);
		FAethelnContentCheckFacts Invalid = Valid;
		Invalid.IntegerFacts[TEXT("mip_count")] = 0;
		RawFactCases.Add({ TEXT("texture"), Valid, Invalid });
	}
	{
		FAethelnContentCheckFacts Valid = MakeFact(TEXT("material_instance_policy"));
		Valid.BooleanFacts.Add(TEXT("asset_data_valid"), true);
		Valid.BooleanFacts.Add(TEXT("instance_policy_declared"), true);
		Valid.BooleanFacts.Add(TEXT("is_instance"), true);
		Valid.BooleanFacts.Add(TEXT("parent_present"), true);
		FAethelnContentCheckFacts Invalid = Valid;
		Invalid.BooleanFacts[TEXT("parent_present")] = false;
		RawFactCases.Add({ TEXT("material"), Valid, Invalid });
	}
	{
		FAethelnContentCheckFacts Valid = MakeFact(TEXT("socket_ownership"));
		Valid.BooleanFacts.Add(TEXT("asset_data_valid"), true);
		Valid.IntegerFacts.Add(TEXT("socket_count"), 2);
		Valid.IntegerFacts.Add(TEXT("invalid_socket_count"), 0);
		FAethelnContentCheckFacts Invalid = Valid;
		Invalid.IntegerFacts[TEXT("invalid_socket_count")] = 1;
		RawFactCases.Add({ TEXT("skeletal_animation"), Valid, Invalid });
	}
	{
		FAethelnContentCheckFacts Valid = MakeFact(TEXT("map_identity"));
		Valid.BooleanFacts.Add(TEXT("asset_data_valid"), true);
		Valid.BooleanFacts.Add(TEXT("persistent_level_present"), true);
		Valid.BooleanFacts.Add(TEXT("world_settings_present"), true);
		Valid.BooleanFacts.Add(TEXT("package_matches_intake"), true);
		Valid.BooleanFacts.Add(TEXT("repository_path_matches_intake"), true);
		Valid.BooleanFacts.Add(TEXT("content_hash_matches_intake"), true);
		Valid.IntegerFacts.Add(TEXT("intake_content_version"), 1);
		Valid.TextFacts.Add(TEXT("intake_stable_id"), TEXT("map.test"));
		FAethelnContentCheckFacts Invalid = Valid;
		Invalid.BooleanFacts[TEXT("package_matches_intake")] = false;
		RawFactCases.Add({ TEXT("map_world"), Valid, Invalid });
	}
	{
		FAethelnContentCheckFacts Valid = MakeFact(TEXT("navigation_data_audience"));
		Valid.BooleanFacts.Add(TEXT("asset_data_valid"), true);
		Valid.BooleanFacts.Add(TEXT("navigation_config_present"), true);
		Valid.BooleanFacts.Add(TEXT("navigation_audience_evidence_recorded"), true);
		Valid.BooleanFacts.Add(TEXT("client_audience_valid"), true);
		Valid.BooleanFacts.Add(TEXT("server_audience_valid"), true);
		Valid.IntegerFacts.Add(TEXT("navigation_data_count"), 1);
		FAethelnContentCheckFacts Invalid = Valid;
		Invalid.BooleanFacts[TEXT("navigation_config_present")] = false;
		RawFactCases.Add({ TEXT("navigation"), Valid, Invalid });
	}
	{
		FAethelnContentCheckFacts Valid = MakeFact(TEXT("redirectors"));
		Valid.IntegerFacts.Add(TEXT("violation_count"), 0);
		FAethelnContentCheckFacts Invalid = Valid;
		Invalid.IntegerFacts[TEXT("violation_count")] = 1;
		RawFactCases.Add({ TEXT("reference_boundary"), Valid, Invalid });
	}
	for (const FRawFactCase& RawFactCase : RawFactCases)
	{
		const FAethelnContentFamilyResult Valid = FAethelnContentValidationScanner::EvaluateFamilyFacts(
			RawFactCase.FamilyId, { RawFactCase.Valid }, false);
		TestEqual(*FString::Printf(TEXT("Valid %s raw facts pass"), *RawFactCase.FamilyId), Valid.DeterministicStatus, FString(TEXT("passed")));
		TestEqual(*FString::Printf(TEXT("Valid %s raw facts are eligible"), *RawFactCase.FamilyId), Valid.PromotionStatus, FString(TEXT("eligible")));

		const FAethelnContentFamilyResult Invalid = FAethelnContentValidationScanner::EvaluateFamilyFacts(
			RawFactCase.FamilyId, { RawFactCase.Invalid }, false);
		TestEqual(*FString::Printf(TEXT("Invalid %s raw facts fail"), *RawFactCase.FamilyId), Invalid.DeterministicStatus, FString(TEXT("failed")));
		TestEqual(*FString::Printf(TEXT("Invalid %s raw facts block family promotion"), *RawFactCase.FamilyId), Invalid.PromotionStatus, FString(TEXT("non_promotion")));
		TestEqual(*FString::Printf(TEXT("Invalid %s raw facts block check promotion"), *RawFactCase.FamilyId), Invalid.CheckResults[0].PromotionStatus, FString(TEXT("non_promotion")));
	}
	const TMap<FString, TArray<FString>> MissingFactsByFamily = {
		{ TEXT("collision"), { TEXT("profile"), TEXT("simple_complex_policy"), TEXT("presentation_equivalence") } },
		{ TEXT("rendering_suitability"), { TEXT("lod"), TEXT("hlod"), TEXT("nanite_suitability"), TEXT("streaming") } },
		{ TEXT("texture"), { TEXT("pbr_channels"), TEXT("tiling"), TEXT("compression"), TEXT("mips"), TEXT("streaming") } },
		{ TEXT("material"), { TEXT("material_instance_policy"), TEXT("shader_complexity_evidence") } },
		{ TEXT("skeletal_animation"), { TEXT("rig_compatibility"), TEXT("morph_policy"), TEXT("influences"), TEXT("socket_ownership"), TEXT("animation_complexity") } },
		{ TEXT("map_world"), { TEXT("map_identity"), TEXT("data_layers"), TEXT("pcg_authority"), TEXT("runtime_editor_boundary") } },
		{ TEXT("navigation"), { TEXT("navigation_data_audience"), TEXT("streaming_boundaries"), TEXT("runtime_rebuild_policy") } },
		{ TEXT("reference_boundary"), { TEXT("stable_id_unique"), TEXT("redirectors"), TEXT("broken_references"), TEXT("compatible_content_version"), TEXT("audience_reachability"), TEXT("hard_reference_exceptions") } }
	};
	for (const TPair<FString, TArray<FString>>& Family : MissingFactsByFamily)
	{
		for (const FString& CheckId : Family.Value)
		{
			const FAethelnContentFamilyResult Missing = FAethelnContentValidationScanner::EvaluateFamilyFacts(
				Family.Key, { MakeFact(CheckId) }, false);
			TestEqual(*FString::Printf(TEXT("Missing %s.%s raw facts are explicitly unavailable"), *Family.Key, *CheckId), Missing.DeterministicStatus, FString(TEXT("evidence_unavailable")));
			TestEqual(*FString::Printf(TEXT("Unavailable %s.%s evidence blocks promotion"), *Family.Key, *CheckId), Missing.PromotionStatus, FString(TEXT("non_promotion")));
		}
	}
	FAethelnContentCheckFacts ObservedLodOnly = MakeFact(TEXT("lod"));
	ObservedLodOnly.BooleanFacts.Add(TEXT("asset_data_valid"), true);
	ObservedLodOnly.IntegerFacts.Add(TEXT("source_model_count"), 1);
	ObservedLodOnly.IntegerFacts.Add(TEXT("render_lod_count"), 1);
	const FAethelnContentFamilyResult ObservedLodOnlyResult = FAethelnContentValidationScanner::EvaluateFamilyFacts(
		TEXT("rendering_suitability"), { ObservedLodOnly }, false);
	TestEqual(TEXT("Positive LOD counts without declared applicability are unavailable"), ObservedLodOnlyResult.DeterministicStatus, FString(TEXT("evidence_unavailable")));
	TestEqual(TEXT("Unresolved LOD suitability blocks promotion"), ObservedLodOnlyResult.PromotionStatus, FString(TEXT("non_promotion")));

	FAethelnContentCheckFacts ObservedMipsOnly = MakeFact(TEXT("mips"));
	ObservedMipsOnly.BooleanFacts.Add(TEXT("asset_data_valid"), true);
	ObservedMipsOnly.IntegerFacts.Add(TEXT("width"), 1024);
	ObservedMipsOnly.IntegerFacts.Add(TEXT("height"), 1024);
	ObservedMipsOnly.IntegerFacts.Add(TEXT("mip_count"), 11);
	const FAethelnContentFamilyResult ObservedMipsOnlyResult = FAethelnContentValidationScanner::EvaluateFamilyFacts(
		TEXT("texture"), { ObservedMipsOnly }, false);
	TestEqual(TEXT("Positive mip observations without declared intent are unavailable"), ObservedMipsOnlyResult.DeterministicStatus, FString(TEXT("evidence_unavailable")));
	TestEqual(TEXT("Unresolved mip intent blocks promotion"), ObservedMipsOnlyResult.PromotionStatus, FString(TEXT("non_promotion")));

	// Authored evaluator fixtures: these do not establish accepted budgets or real cook provenance.
	auto CheckFactStatus = [this](const FString& Label, const FString& FamilyId,
		const FAethelnContentCheckFacts& Fact, const FString& ExpectedStatus)
	{
		const FAethelnContentFamilyResult Result = FAethelnContentValidationScanner::EvaluateFamilyFacts(FamilyId, { Fact }, false);
		const FString ExpectedPromotion = ExpectedStatus == TEXT("passed") && !Fact.bHasUnresolvedThreshold ? TEXT("eligible") : TEXT("non_promotion");
		TestEqual(*(Label + TEXT(" family status")), Result.DeterministicStatus, ExpectedStatus);
		TestEqual(*(Label + TEXT(" family promotion")), Result.PromotionStatus, ExpectedPromotion);
		TestEqual(*(Label + TEXT(" check status")), Result.CheckResults[0].DeterministicStatus, ExpectedStatus);
		TestEqual(*(Label + TEXT(" check promotion")), Result.CheckResults[0].PromotionStatus, ExpectedPromotion);
	};
	struct FDeclaredPolicyCase
	{
		FString FamilyId;
		FAethelnContentCheckFacts Observed;
		FString Declaration;
		FString Compliance;
	};
	TArray<FDeclaredPolicyCase> DeclaredPolicyCases;
	FAethelnContentCheckFacts ObservedInfluences = MakeFact(TEXT("influences"));
	ObservedInfluences.BooleanFacts.Add(TEXT("influence_observation_available"), true);
	ObservedInfluences.IntegerFacts.Add(TEXT("maximum_influences"), 4);
	DeclaredPolicyCases.Add({ TEXT("skeletal_animation"), ObservedInfluences, TEXT("influence_policy_recorded"), TEXT("influences_within_budget") });
	FAethelnContentCheckFacts ObservedAnimation = MakeFact(TEXT("animation_complexity"));
	ObservedAnimation.BooleanFacts.Add(TEXT("sequence_asset"), true);
	ObservedAnimation.DecimalFacts.Add(TEXT("play_length"), 1.0);
	ObservedAnimation.IntegerFacts.Add(TEXT("sampled_key_count"), 30);
	DeclaredPolicyCases.Add({ TEXT("skeletal_animation"), ObservedAnimation, TEXT("animation_complexity_policy_recorded"), TEXT("animation_within_budget") });
	FAethelnContentCheckFacts ObservedTrace = MakeFact(TEXT("simple_complex_policy"));
	ObservedTrace.BooleanFacts.Add(TEXT("collision_source_present"), true);
	ObservedTrace.IntegerFacts.Add(TEXT("simple_shape_count"), 1);
	ObservedTrace.IntegerFacts.Add(TEXT("trace_flag"), 0);
	DeclaredPolicyCases.Add({ TEXT("collision"), ObservedTrace, TEXT("trace_policy_declared"), TEXT("trace_policy_compliant") });
	DeclaredPolicyCases.Add({ TEXT("skeletal_animation"), MakeFact(TEXT("morph_policy")), TEXT("morph_policy_recorded"), TEXT("morph_policy_compliant") });
	DeclaredPolicyCases.Add({ TEXT("navigation"), MakeFact(TEXT("streaming_boundaries")), TEXT("streaming_boundary_policy_recorded"), TEXT("streaming_boundary_policy_compliant") });
	DeclaredPolicyCases.Add({ TEXT("navigation"), MakeFact(TEXT("runtime_rebuild_policy")), TEXT("runtime_rebuild_policy_recorded"), TEXT("runtime_rebuild_policy_compliant") });
	for (const FDeclaredPolicyCase& PolicyCase : DeclaredPolicyCases)
	{
		const FString Label = PolicyCase.FamilyId + TEXT(".") + PolicyCase.Observed.CheckId;
		CheckFactStatus(Label + TEXT(" observations without policy"), PolicyCase.FamilyId, PolicyCase.Observed, TEXT("evidence_unavailable"));
		FAethelnContentCheckFacts Fact = PolicyCase.Observed;
		Fact.BooleanFacts.Add(PolicyCase.Compliance, true);
		CheckFactStatus(Label + TEXT(" compliance without declaration"), PolicyCase.FamilyId, Fact, TEXT("evidence_unavailable"));
		Fact.BooleanFacts.Add(PolicyCase.Declaration, false);
		CheckFactStatus(Label + TEXT(" unaccepted declaration"), PolicyCase.FamilyId, Fact, TEXT("evidence_unavailable"));
		Fact.BooleanFacts[PolicyCase.Declaration] = true;
		Fact.BooleanFacts.Remove(PolicyCase.Compliance);
		CheckFactStatus(Label + TEXT(" declaration without compliance"), PolicyCase.FamilyId, Fact, TEXT("evidence_unavailable"));
		Fact.BooleanFacts.Add(PolicyCase.Compliance, true);
		CheckFactStatus(Label + TEXT(" declared compliant fixture"), PolicyCase.FamilyId, Fact, TEXT("passed"));
		Fact.bHasUnresolvedThreshold = true;
		CheckFactStatus(Label + TEXT(" unresolved budget still blocks promotion"), PolicyCase.FamilyId, Fact, TEXT("passed"));
		Fact.BooleanFacts[PolicyCase.Compliance] = false;
		CheckFactStatus(Label + TEXT(" policy violation survives TBD"), PolicyCase.FamilyId, Fact, TEXT("failed"));
	}
	ObservedInfluences.IntegerFacts[TEXT("maximum_influences")] = 0;
	CheckFactStatus(TEXT("Nonpositive influences fail before missing policy"), TEXT("skeletal_animation"), ObservedInfluences, TEXT("failed"));
	ObservedAnimation.DecimalFacts[TEXT("play_length")] = -1.0;
	CheckFactStatus(TEXT("Negative animation length fails before missing policy"), TEXT("skeletal_animation"), ObservedAnimation, TEXT("failed"));
	ObservedAnimation.DecimalFacts[TEXT("play_length")] = 1.0;
	ObservedAnimation.IntegerFacts[TEXT("sampled_key_count")] = 0;
	CheckFactStatus(TEXT("Empty sequence fails before missing policy"), TEXT("skeletal_animation"), ObservedAnimation, TEXT("failed"));
	ObservedAnimation.BooleanFacts[TEXT("sequence_asset")] = false;
	ObservedAnimation.IntegerFacts[TEXT("sampled_key_count")] = -1;
	CheckFactStatus(TEXT("Non-sequence animation still needs complexity policy"), TEXT("skeletal_animation"), ObservedAnimation, TEXT("evidence_unavailable"));
	ObservedAnimation.BooleanFacts.Add(TEXT("animation_complexity_policy_recorded"), true);
	ObservedAnimation.BooleanFacts.Add(TEXT("animation_within_budget"), true);
	CheckFactStatus(TEXT("Declared compliant non-sequence animation"), TEXT("skeletal_animation"), ObservedAnimation, TEXT("passed"));

	FAethelnContentCheckFacts Navigation = MakeFact(TEXT("navigation_data_audience"));
	Navigation.BooleanFacts.Add(TEXT("navigation_config_present"), true);
	Navigation.IntegerFacts.Add(TEXT("navigation_data_count"), 1);
	CheckFactStatus(TEXT("Navigation observations without audience evidence"), TEXT("navigation"), Navigation, TEXT("evidence_unavailable"));
	Navigation.BooleanFacts.Add(TEXT("server_audience_valid"), true);
	CheckFactStatus(TEXT("Map audience label cannot establish navigation reachability"), TEXT("navigation"), Navigation, TEXT("evidence_unavailable"));
	Navigation.BooleanFacts.Add(TEXT("client_audience_valid"), true);
	CheckFactStatus(TEXT("Audience claims without bound provenance"), TEXT("navigation"), Navigation, TEXT("evidence_unavailable"));
	Navigation.BooleanFacts.Add(TEXT("navigation_audience_evidence_recorded"), false);
	CheckFactStatus(TEXT("Unbound navigation provenance"), TEXT("navigation"), Navigation, TEXT("evidence_unavailable"));
	Navigation.BooleanFacts[TEXT("navigation_audience_evidence_recorded")] = true;
	CheckFactStatus(TEXT("Bound client and server audience fixture"), TEXT("navigation"), Navigation, TEXT("passed"));
	for (const FString& AudienceFact : { FString(TEXT("client_audience_valid")), FString(TEXT("server_audience_valid")) })
	{
		FAethelnContentCheckFacts MissingAudience = Navigation;
		MissingAudience.BooleanFacts.Remove(AudienceFact);
		CheckFactStatus(AudienceFact + TEXT(" missing from bound evidence"), TEXT("navigation"), MissingAudience, TEXT("evidence_unavailable"));
		FAethelnContentCheckFacts InvalidAudience = Navigation;
		InvalidAudience.BooleanFacts[AudienceFact] = false;
		CheckFactStatus(AudienceFact + TEXT(" violates bound audience policy"), TEXT("navigation"), InvalidAudience, TEXT("failed"));
	}
	Navigation.BooleanFacts.Remove(TEXT("navigation_audience_evidence_recorded"));
	Navigation.BooleanFacts[TEXT("navigation_config_present")] = false;
	CheckFactStatus(TEXT("Missing navigation config fails before missing provenance"), TEXT("navigation"), Navigation, TEXT("failed"));
	Navigation.BooleanFacts[TEXT("navigation_config_present")] = true;
	Navigation.IntegerFacts[TEXT("navigation_data_count")] = 0;
	CheckFactStatus(TEXT("Missing navigation data fails before missing provenance"), TEXT("navigation"), Navigation, TEXT("failed"));

	FAethelnContentCheckFacts Equivalence = MakeFact(TEXT("presentation_equivalence"));
	Equivalence.BooleanFacts.Add(TEXT("authoritative_geometry_present"), true);
	CheckFactStatus(TEXT("Geometry presence cannot prove presentation equivalence"), TEXT("collision"), Equivalence, TEXT("evidence_unavailable"));
	Equivalence.BooleanFacts.Add(TEXT("presentation_equivalence_verified"), true);
	CheckFactStatus(TEXT("Verified presentation equivalence fixture"), TEXT("collision"), Equivalence, TEXT("passed"));
	Equivalence.BooleanFacts[TEXT("presentation_equivalence_verified")] = false;
	CheckFactStatus(TEXT("Presentation equivalence violation"), TEXT("collision"), Equivalence, TEXT("failed"));
	Equivalence.BooleanFacts.Remove(TEXT("presentation_equivalence_verified"));
	Equivalence.BooleanFacts[TEXT("authoritative_geometry_present")] = false;
	CheckFactStatus(TEXT("Missing authoritative geometry remains a failure"), TEXT("collision"), Equivalence, TEXT("failed"));
	FAethelnContentCheckFacts NotApplicable;
	NotApplicable.CheckId = TEXT("material_instance_policy");
	NotApplicable.Evidence = TEXT("not_applicable:object_is_not_material");
	const FAethelnContentFamilyResult NotApplicableResult = FAethelnContentValidationScanner::EvaluateFamilyFacts(
		TEXT("material"), { NotApplicable }, false);
	TestEqual(TEXT("Explicit non-applicability remains distinct from unavailable evidence"), NotApplicableResult.DeterministicStatus, FString(TEXT("not_applicable")));
	TestEqual(TEXT("Non-applicable evidence has no promotion verdict"), NotApplicableResult.PromotionStatus, FString(TEXT("not_applicable")));
	const FAethelnContentFamilyResult FailurePrecedence = FAethelnContentValidationScanner::EvaluateFamilyFacts(
		TEXT("collision"), { RawFactCases[0].Invalid, MakeFact(TEXT("simple_complex_policy")) }, false);
	TestEqual(TEXT("Deterministic failure takes precedence over unavailable evidence"), FailurePrecedence.DeterministicStatus, FString(TEXT("failed")));
	TestEqual(TEXT("Failure plus unavailable evidence blocks promotion"), FailurePrecedence.PromotionStatus, FString(TEXT("non_promotion")));
	FAethelnContentCheckFacts PassingStableId = MakeFact(TEXT("stable_id_unique"));
	PassingStableId.IntegerFacts.Add(TEXT("violation_count"), 0);
	const FAethelnContentFamilyResult FailedAndPassed = FAethelnContentValidationScanner::EvaluateFamilyFacts(
		TEXT("reference_boundary"), { RawFactCases[7].Invalid, PassingStableId }, false);
	TestEqual(TEXT("Failure takes precedence over a passed sibling check"), FailedAndPassed.DeterministicStatus, FString(TEXT("failed")));
	TestEqual(TEXT("Family containing failed and passed checks blocks promotion"), FailedAndPassed.PromotionStatus, FString(TEXT("non_promotion")));
	FAethelnContentCheckFacts Unresolved = RawFactCases[1].Valid;
	Unresolved.bHasUnresolvedThreshold = true;
	const FAethelnContentFamilyResult UnresolvedResult = FAethelnContentValidationScanner::EvaluateFamilyFacts(TEXT("rendering_suitability"), { Unresolved }, false);
	TestEqual(TEXT("TBD evidence does not hide deterministic success"), UnresolvedResult.DeterministicStatus, FString(TEXT("passed")));
	TestEqual(TEXT("TBD evidence blocks promotion"), UnresolvedResult.PromotionStatus, FString(TEXT("non_promotion")));

	return true;
}

#endif
