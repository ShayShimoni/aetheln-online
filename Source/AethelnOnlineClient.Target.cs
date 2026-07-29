using UnrealBuildTool;
using System.Collections.Generic;

public class AethelnOnlineClientTarget : TargetRules
{
	public AethelnOnlineClientTarget(TargetInfo Target) : base(Target)
	{
		Type = TargetType.Client;
		DefaultBuildSettings = BuildSettingsVersion.V7;
		IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_8;
		ExtraModuleNames.AddRange(new string[] { "GameCore", "GameCombat", "GameUI", "GameNet" });
	}
}
