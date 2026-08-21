using UnrealBuildTool;

public class GameTests : ModuleRules
{
	public GameTests(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;

		PrivateDependencyModuleNames.AddRange(new string[]
		{
			"Core"
		});
	}
}
