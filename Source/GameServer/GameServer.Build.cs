using UnrealBuildTool;

public class GameServer : ModuleRules
{
	public GameServer(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;

		PublicDependencyModuleNames.AddRange(new string[]
		{
			"Core",
			"CoreUObject",
			"Engine",
			"GameCore",
			"GameCombat",
			"GameNet"
		});
	}
}
