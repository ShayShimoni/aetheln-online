using UnrealBuildTool;

public class GameNet : ModuleRules
{
	public GameNet(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;

		PublicDependencyModuleNames.AddRange(new string[]
		{
			"Core",
			"CoreUObject",
			"Engine"
		});
		PrivateDependencyModuleNames.AddRange(new string[] { "NetCore" });
		SetupIrisSupport(Target);
	}
}
