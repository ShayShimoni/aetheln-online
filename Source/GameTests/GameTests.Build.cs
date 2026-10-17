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
			"EnhancedInput",
			"GameCombat",
			"GameCore",
			"GameNet",
			"GameplayAbilities",
			"GameplayTags",
			"GameUI",
			"InputCore",
			"IrisCore",
			"Json",
			"NavigationSystem",
			// #60 P6: A21 closes a server connection (UNetConnection::Close links the NetCloseResult enum).
			"NetCore",
			// #84 P3b: N3 builds a Niagara effect notify for the allowlist case.
			"Niagara",
			"NiagaraAnimNotifies",
			"PhysicsCore",
			// #84 P4: the audience cook rule test calls the cook hook for a client-only and a dedicated-server target.
			"TargetPlatform",
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
