#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnAssetManager.h"
#include "AethelnAttackDefinitionTestAbilities.h"
#include "AethelnBasicChainAbility.h"
#include "AethelnGameplayTags.h"
#include "AethelnPlayerState.h"
#include "Engine/AssetManager.h"
#include "Interfaces/ITargetPlatform.h"
#include "Interfaces/ITargetPlatformManagerModule.h"
#include "Misc/AutomationTest.h"
#include "Misc/ConfigCacheIni.h"

// #84 P4 (docs/animation-and-combat-content-pipeline.md, Test Plan N7 and N8): the first definition asset, the grant
// check for a missing one, and the audience cook rule. No value is invented; the asset holds the D3 provisional values.
namespace AethelnAttackDefinitionAssetTests
{
	const TCHAR* const ChainDefinitionPackage = TEXT("/Game/Combat/Attacks/DA_SwordShieldBasicChain");
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnMissingDefinitionRefusesGrantTest,
	"Aetheln.GameCombat.AttackContent.MissingDefinitionRefusesGrant",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnMissingDefinitionRefusesGrantTest::RunTest(const FString& Parameters)
{
	UAethelnMissingDefinitionTestAbility* Missing = NewObject<UAethelnMissingDefinitionTestAbility>();
	const TCHAR* MissingProblem = Missing->FindGrantProblem();
	TestTrue(TEXT("The grant problem names the missing asset by its validation identifier"),
		MissingProblem != nullptr && FString(MissingProblem).Contains(AethelnAttackDefinitionId::Missing));
	AddExpectedError(AethelnAttackDefinitionId::Missing, EAutomationExpectedErrorFlags::Contains, 1);
	TestFalse(TEXT("The server refuses to grant an ability whose definition asset is missing"),
		AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Missing)));

	// A definition of another ability is refused by its own identifier and never used.
	UAethelnOtherAbilityDefinitionTestAbility* Other = NewObject<UAethelnOtherAbilityDefinitionTestAbility>();
	const TCHAR* OtherProblem = Other->FindGrantProblem();
	TestTrue(TEXT("A definition of another ability is refused with its identifier"),
		OtherProblem != nullptr && FString(OtherProblem).Contains(AethelnAttackDefinitionId::AbilityMismatch));

	// A definition that fails its own validator (here a zero ContentVersion, in memory) is refused as invalid.
	UAethelnAttackDefinition* Invalid = NewObject<UAethelnAttackDefinition>(GetTransientPackage(), TEXT("DA_InvalidDefinitionFixture"));
	Invalid->StableContentId = FName(TEXT("test.invalid.definition"));
	Invalid->ContentVersion = 0;
	Invalid->AbilityId = AethelnGameplayTags::Ability_Oathscar_SwordShieldBasicChain;
	UAethelnBasicChainAbility* UsesInvalid = NewObject<UAethelnBasicChainAbility>();
	UsesInvalid->Definition = TSoftObjectPtr<UAethelnAttackDefinition>(Invalid);
	const TCHAR* InvalidProblem = UsesInvalid->FindGrantProblem();
	TestTrue(TEXT("An invalid definition is refused with its identifier"),
		InvalidProblem != nullptr && FString(InvalidProblem).Contains(AethelnAttackDefinitionId::Invalid));

	// The production chain, whose asset exists, has no definition problem.
	TestNull(TEXT("The production chain's definition asset is usable"), GetDefault<UAethelnBasicChainAbility>()->FindGrantProblem());
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnChainReadsDefinitionAssetTest,
	"Aetheln.GameCombat.AttackContent.ChainReadsDefinitionAsset",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnChainReadsDefinitionAssetTest::RunTest(const FString& Parameters)
{
	const UAethelnBasicChainAbility* Chain = GetDefault<UAethelnBasicChainAbility>();
	const UAethelnAttackDefinition* Asset = Chain->Definition.Get();
	if (!TestNotNull(TEXT("The chain's configured definition asset loads"), Asset)) { return false; }
	TestEqual(TEXT("The asset is the final DA_ package"), Chain->Definition.GetLongPackageName(), FString(AethelnAttackDefinitionAssetTests::ChainDefinitionPackage));
	TestNull(TEXT("No problem in the asset"), Asset->FindProblem());
	TestTrue(TEXT("The asset is Shared (TA-027)"), Asset->Audience == EAethelnContentAudience::Shared);
	TestEqual(TEXT("The stable ID is the registry semantic ID"), Asset->StableContentId, FName(TEXT("order.oathscar.ability.sword_shield_basic_chain")));
	TestEqual(TEXT("The asset serves the chain's ability"), Asset->AbilityId, Chain->GetAbilityId());

	// The chain's fields are the asset's values and nothing else.
	TestEqual(TEXT("ContentVersion comes from the asset"), static_cast<int32>(Chain->ContentVersion), Asset->ContentVersion);
	TestEqual(TEXT("The steps come from the asset"), Chain->ProvisionalSteps.Num(), Asset->Steps.Num());
	TestEqual(TEXT("The cost comes from the asset"), Chain->ProvisionalEnduranceCost, Asset->EnduranceCost);
	TestEqual(TEXT("The sampling distance comes from the asset"), Chain->ProvisionalMaxSampleDistance, Asset->MaxSampleDistance);
	TestEqual(TEXT("The sampling angle comes from the asset"), Chain->ProvisionalMaxSampleAngleDegrees, Asset->MaxSampleAngleDegrees);

	// One place for each value: the chain's ini section holds the path only.
	const TCHAR* const Section = TEXT("/Script/GameCombat.AethelnBasicChainAbility");
	for (const TCHAR* Key : { TEXT("ContentVersion"), TEXT("ProvisionalSteps"), TEXT("ProvisionalEnduranceCost"), TEXT("ProvisionalMaxSampleDistance"), TEXT("ProvisionalMaxSampleAngleDegrees") })
	{
		TArray<FString> Lines;
		GConfig->GetArray(Section, Key, Lines, GGameIni);
		TestEqual(FString::Printf(TEXT("%s is not also set in Config/DefaultGame.ini"), Key), Lines.Num(), 0);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnAudienceCookRuleTest,
	"Aetheln.GameCore.AssetManager.AudienceCookRule",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAudienceCookRuleTest::RunTest(const FString& Parameters)
{
	using Audience = EAethelnContentAudience;
	// Targets: a dedicated server, a client-only build, and a full game build (neither).
	TestTrue(TEXT("Shared is in the server cook"), UAethelnAssetManager::ShouldCookForTarget(Audience::Shared, true, false));
	TestTrue(TEXT("Shared is in the client cook"), UAethelnAssetManager::ShouldCookForTarget(Audience::Shared, false, true));
	TestTrue(TEXT("Shared is in a full game cook"), UAethelnAssetManager::ShouldCookForTarget(Audience::Shared, false, false));
	TestFalse(TEXT("ClientOnly is not in the dedicated-server cook"), UAethelnAssetManager::ShouldCookForTarget(Audience::ClientOnly, true, false));
	TestTrue(TEXT("ClientOnly is in the client cook"), UAethelnAssetManager::ShouldCookForTarget(Audience::ClientOnly, false, true));
	TestTrue(TEXT("ClientOnly is in a full game cook"), UAethelnAssetManager::ShouldCookForTarget(Audience::ClientOnly, false, false));
	TestTrue(TEXT("ServerOnly is in the dedicated-server cook"), UAethelnAssetManager::ShouldCookForTarget(Audience::ServerOnly, true, false));
	TestFalse(TEXT("ServerOnly is not in the client cook"), UAethelnAssetManager::ShouldCookForTarget(Audience::ServerOnly, false, true));
	TestTrue(TEXT("ServerOnly is in a full game cook"), UAethelnAssetManager::ShouldCookForTarget(Audience::ServerOnly, false, false));

	EAethelnContentAudience Parsed = Audience::Shared;
	TestTrue(TEXT("ClientOnly tag parses"), UAethelnAssetManager::TryParseAudienceTag(TEXT("ClientOnly"), Parsed) && Parsed == Audience::ClientOnly);
	TestTrue(TEXT("ServerOnly tag parses"), UAethelnAssetManager::TryParseAudienceTag(TEXT("ServerOnly"), Parsed) && Parsed == Audience::ServerOnly);
	TestTrue(TEXT("Shared tag parses"), UAethelnAssetManager::TryParseAudienceTag(TEXT("Shared"), Parsed) && Parsed == Audience::Shared);
	TestFalse(TEXT("A qualified tag is refused"), UAethelnAssetManager::TryParseAudienceTag(TEXT("EAethelnContentAudience::Shared"), Parsed));
	TestFalse(TEXT("An empty tag is refused"), UAethelnAssetManager::TryParseAudienceTag(FString(), Parsed));

	// The lists move: a package listed to cook is taken out when the target refuses it, and the reverse.
	const FName Binding(TEXT("/Game/Fixture/DA_Binding"));
	TArray<FName> Cook{ Binding };
	TArray<FName> Never;
	UAethelnAssetManager::ApplyAudienceCookRule(Binding, Audience::ClientOnly, true, false, Cook, Never);
	TestTrue(TEXT("A client-only binding is never cooked for the server, even if something referenced it"), Never.Contains(Binding) && !Cook.Contains(Binding));
	UAethelnAssetManager::ApplyAudienceCookRule(Binding, Audience::ClientOnly, false, true, Cook, Never);
	TestTrue(TEXT("The same binding is cooked for the client"), Cook.Contains(Binding) && !Never.Contains(Binding));

	// The project selects this manager; without it the rule never runs.
	TestNotNull(TEXT("The project asset manager is the Aetheln one"), Cast<UAethelnAssetManager>(&UAssetManager::Get()));

	// The real cook hook, for a client-only and a dedicated-server target: the Shared definition is in both.
	ITargetPlatformManagerModule& Platforms = GetTargetPlatformManagerRef();
	const ITargetPlatform* Client = Platforms.FindTargetPlatform(TEXT("WindowsClient"));
	const ITargetPlatform* Server = Platforms.FindTargetPlatform(TEXT("WindowsServer"));
	if (TestNotNull(TEXT("The WindowsClient target platform is available"), Client) && TestNotNull(TEXT("The WindowsServer target platform is available"), Server))
	{
		const FName Definition(AethelnAttackDefinitionAssetTests::ChainDefinitionPackage);
		for (const ITargetPlatform* Target : { Client, Server })
		{
			TArray<FName> TargetCook;
			TArray<FName> TargetNever;
			UAssetManager::Get().ModifyCook(MakeArrayView(&Target, 1), TargetCook, TargetNever);
			TestTrue(FString::Printf(TEXT("The Shared definition is cooked for %s"), *Target->PlatformName()), TargetCook.Contains(Definition));
			TestFalse(FString::Printf(TEXT("The Shared definition is never excluded for %s"), *Target->PlatformName()), TargetNever.Contains(Definition));
		}
	}
	return true;
}

#endif
