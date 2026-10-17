using UnrealBuildTool;

public class GameCore : ModuleRules
{
	public GameCore(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;

		PublicDependencyModuleNames.AddRange(new string[]
		{
			"Core",
			"CoreUObject",
			"Engine",
			"GameplayTags"
		});

		// #84: the audience cook rule reads asset registry tags, and its editor-only cook hook sees the target platform.
		PrivateDependencyModuleNames.Add("AssetRegistry");
		if (Target.bBuildEditor)
		{
			PrivateDependencyModuleNames.Add("TargetPlatform");
		}
	}
}
