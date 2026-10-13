using UnrealBuildTool;

public class GameTests : ModuleRules
{
	public GameTests(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;

		PrivateDependencyModuleNames.AddRange(new string[]
		{
			"AssetRegistry",
			"Core",
			"CoreUObject",
			// #21 P3: CQTest's PIE network component hosts the two-client death test (R5); it needs UnrealEd and IrisCore headers.
			"CQTest",
			"DesktopPlatform",
			"Engine",
			"GameCombat",
			"GameCore",
			"GameNet",
			"GameplayAbilities",
			"GameplayTags",
			"GameUI",
			"IrisCore",
			"Json",
			"NavigationSystem",
			"PhysicsCore",
			"UnrealEd"
		});

		bool bWithOpenSsl = Target.Platform == UnrealTargetPlatform.Win64
			|| Target.Platform == UnrealTargetPlatform.Mac
			|| Target.Platform == UnrealTargetPlatform.Linux;
		if (bWithOpenSsl)
		{
			AddEngineThirdPartyPrivateStaticDependencies(Target, "OpenSSL");
		}
		PrivateDefinitions.Add($"AETHELN_CONTENT_VALIDATION_WITH_OPENSSL={(bWithOpenSsl ? 1 : 0)}");
	}
}
