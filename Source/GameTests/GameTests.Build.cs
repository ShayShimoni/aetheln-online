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
			"DesktopPlatform",
			"Engine",
			"GameCore",
			"Json",
			"NavigationSystem",
			"PhysicsCore"
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
