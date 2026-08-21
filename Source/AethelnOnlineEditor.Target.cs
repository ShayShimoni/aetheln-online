using UnrealBuildTool;
using System.Collections.Generic;

public class AethelnOnlineEditorTarget : TargetRules
{
	public AethelnOnlineEditorTarget(TargetInfo Target) : base(Target)
	{
		Type = TargetType.Editor;
		DefaultBuildSettings = BuildSettingsVersion.V7;
		IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_8;
		ExtraModuleNames.AddRange(new string[] { "GameCore", "GameCombat", "GameUI", "GameNet", "GameTests" });
	}
}
