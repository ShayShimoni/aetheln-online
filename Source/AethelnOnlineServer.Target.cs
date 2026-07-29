using UnrealBuildTool;
using System.Collections.Generic;

public class AethelnOnlineServerTarget : TargetRules
{
	public AethelnOnlineServerTarget(TargetInfo Target) : base(Target)
	{
		Type = TargetType.Server;
		DefaultBuildSettings = BuildSettingsVersion.V7;
		IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_8;
		ExtraModuleNames.AddRange(new string[] { "GameCore", "GameCombat", "GameNet", "GameServer" });
	}
}
