[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Validator = Join-Path $RepositoryRoot 'scripts/build/Validate-ServerCookReferences.ps1'
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("AethelnServerCookReferenceTests-{0}" -f [guid]::NewGuid().ToString('N'))
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }
function Write-Dump([string] $Directory, [object[]] $Dependencies, [hashtable] $Classes) {
	New-Item -ItemType Directory -Path $Directory -Force | Out-Null
	$Lines = [System.Collections.Generic.List[string]]::new()
	$Lines.Add('--- Begin CachedAssetsByClass ---')
	foreach ($Class in ($Classes.Keys | Sort-Object)) {
		$Lines.Add("`t$Class : 1 item(s)"); $Lines.Add("`t`t$($Classes[$Class]).$([IO.Path]::GetFileName($Classes[$Class]))")
	}
	$Lines.Add("--- End CachedAssetsByClass : $($Classes.Count) entries ---")
	$Lines.Add('--- Begin CachedDependsNodes ---')
	foreach ($Dependency in $Dependencies) {
		$Lines.Add("`t$($Dependency.Source)"); $Lines.Add("`t`tPackage"); $Lines.Add("`t`t`t$($Dependency.Target)`t`t{$($Dependency.Properties)}")
	}
	$Lines.Add("--- End CachedDependsNodes : $($Dependencies.Count) entries ---")
	Set-Content -LiteralPath (Join-Path $Directory 'Page_00000.txt') -Value $Lines -Encoding UTF8
}
function Write-Inventory([string] $Directory, [string[]] $Packages) {
	New-Item -ItemType Directory -Path $Directory -Force | Out-Null
	$Lines = [System.Collections.Generic.List[string]]::new(); $Lines.Add('--- Begin CachedAssetsByPackageName ---')
	foreach ($Package in ($Packages | Sort-Object -Unique)) { $Lines.Add("`t$Package : 1 item(s)"); $Lines.Add("`t`t$Package.$([IO.Path]::GetFileName($Package))") }
	$Lines.Add("--- End CachedAssetsByPackageName : $($Packages.Count) entries ---")
	Set-Content -LiteralPath (Join-Path $Directory 'Page_00000.txt') -Value $Lines -Encoding UTF8
}
function Invoke-ExpectedFailure([string] $Directory, [string] $Inventory, [string] $Pattern) {
	$Failure = $null; try { & $Validator -DependencyReportDirectory $Directory -CookedInventoryDirectory $Inventory | Out-Null } catch { $Failure = $_.Exception.Message }
	Assert-True ($null -ne $Failure) "Expected '$Directory' to fail."
	Assert-True ($Failure -match $Pattern) "Failure '$Failure' did not match '$Pattern'."
}
try {
	New-Item -ItemType Directory -Path $FixtureRoot | Out-Null
	$BaseInventory = Join-Path $FixtureRoot 'base-inventory'; Write-Inventory $BaseInventory @('/Game/Gameplay/BP_ServerPawn')
	Invoke-ExpectedFailure (Join-Path $FixtureRoot 'missing') $BaseInventory 'dependency report directory is missing'
	$BaseDependency = Join-Path $FixtureRoot 'base-dependency'; Write-Dump $BaseDependency @() @{}
	Invoke-ExpectedFailure $BaseDependency (Join-Path $FixtureRoot 'missing-inventory') 'inventory directory is missing'
	Write-Output 'PASS: either missing dump fails closed'
	$Cases = @(
		@{ Name='UI'; Asset='/Game/UI/WBP_HUD'; Class='/Script/UMG.WidgetBlueprint' },
		@{ Name='Audio'; Asset='/Game/Audio/SFX_Sword'; Class='/Script/Engine.SoundWave' },
		@{ Name='Niagara'; Asset='/Game/VFX/NS_Hit'; Class='/Script/Niagara.NiagaraSystem' },
		@{ Name='Camera'; Asset='/Game/Cameras/CA_Combat'; Class='/Script/Engine.CameraAnimationSequence' },
		@{ Name='High-detail art'; Asset='/Game/Characters/SK_Hero'; Class='/Script/Engine.SkeletalMesh' }
	)
	foreach ($Case in $Cases) {
		$Dir = Join-Path $FixtureRoot ($Case.Name -replace '[^A-Za-z]', '')
		Write-Dump $Dir @(@{Source='/Game/Gameplay/BP_ServerPawn';Target=$Case.Asset;Properties='Hard,Game,Build'}) @{ $Case.Class = $Case.Asset }
		$Inventory = "$Dir-inventory"; Write-Inventory $Inventory @('/Game/Gameplay/BP_ServerPawn', $Case.Asset)
		Invoke-ExpectedFailure $Dir $Inventory ("{0}.*BP_ServerPawn.*{1}.*{2}" -f [regex]::Escape($Case.Name), [regex]::Escape($Case.Asset), [regex]::Escape($Case.Class))
		Write-Output "PASS: $($Case.Name) hard dependency rejected with evidence"
	}
	$Valid = Join-Path $FixtureRoot 'valid'
	$Deps = @(
		@{Source='/Game/Maps/CombatMap';Target='/Game/ServerData/Collision/SM_Collision';Properties='Hard,Game,Build'},
		@{Source='/Game/Maps/CombatMap';Target='/Game/ServerData/Navigation/DT_Nav';Properties='Hard,Game,Build'},
		@{Source='/Game/Abilities/GA_Strike';Target='/Game/ServerData/Gameplay/CT_Damage';Properties='Hard,Game,Build'},
		@{Source='/Game/Abilities/GA_Strike';Target='/Game/Icons/T_PrototypeIcon';Properties='Soft,Game,NotBuild'}
	)
	Write-Dump $Valid $Deps @{ '/Script/Engine.StaticMesh'='/Game/ServerData/Collision/SM_Collision'; '/Script/Engine.DataTable'='/Game/ServerData/Navigation/DT_Nav'; '/Script/Engine.CurveTable'='/Game/ServerData/Gameplay/CT_Damage'; '/Script/Engine.Texture2D'='/Game/Icons/T_PrototypeIcon' }
	$ValidInventory = "$Valid-inventory"; Write-Inventory $ValidInventory @('/Game/Maps/CombatMap','/Game/Abilities/GA_Strike','/Game/ServerData/Collision/SM_Collision','/Game/ServerData/Navigation/DT_Nav','/Game/ServerData/Gameplay/CT_Damage','/Game/Icons/T_PrototypeIcon')
	$Output = & $Validator -DependencyReportDirectory $Valid -CookedInventoryDirectory $ValidInventory | Out-String
	Assert-True ($Output -match '3 allowlisted server-required') 'Allowlisted hard dependencies should pass.'
	Write-Output 'PASS: collision, navigation, gameplay allowlist and soft presentation pass'
	$EditorOnly = Join-Path $FixtureRoot 'editor-only'; Write-Dump $EditorOnly @(@{Source='/Game/Editor/BP_Preview';Target='/Game/UI/W_Editor';Properties='Hard,Game,Build'}) @{ '/Script/UMG.WidgetBlueprint'='/Game/UI/W_Editor' }
	$EditorOutput = & $Validator -DependencyReportDirectory $EditorOnly -CookedInventoryDirectory $BaseInventory | Out-String
	Assert-True ($EditorOutput -match 'Validated 0 cooked hard') 'Dependencies outside cooked inventory must be ignored.'
	Write-Output 'PASS: full development-registry editor universe is filtered by cooked inventory'
	$EngineSource = Join-Path $FixtureRoot 'engine-source'; Write-Dump $EngineSource @(@{Source='/Engine/Runtime/BP_Engine';Target='/Engine/UI/W_Runtime';Properties='Hard,Game,Build'}) @{ '/Script/UMG.WidgetBlueprint'='/Engine/UI/W_Runtime' }
	$EngineInventory = "$EngineSource-inventory"; Write-Inventory $EngineInventory @('/Engine/Runtime/BP_Engine','/Engine/UI/W_Runtime')
	$EngineOutput = & $Validator -DependencyReportDirectory $EngineSource -CookedInventoryDirectory $EngineInventory | Out-String
	Assert-True ($EngineOutput -match 'Validated 0 cooked hard') 'Engine/plugin sources are outside the project-authored gate.'
	Write-Output 'PASS: cooked engine-owned source graphs are ignored'
	$PrototypeArt = Join-Path $FixtureRoot 'prototype-art'
	Write-Dump $PrototypeArt @(
		@{Source='/Game/Maps/Prototype';Target='/Game/Art/SM_BlockoutWall';Properties='Hard,Game,Build'},
		@{Source='/Game/Maps/Prototype';Target='/Game/Art/M_Blockout';Properties='Hard,Game,Build'},
		@{Source='/Game/Maps/Prototype';Target='/Game/Art/T_Blockout';Properties='Hard,Game,Build'}
	) @{ '/Script/Engine.StaticMesh'='/Game/Art/SM_BlockoutWall'; '/Script/Engine.Material'='/Game/Art/M_Blockout'; '/Script/Engine.Texture2D'='/Game/Art/T_Blockout' }
	$PrototypeInventory = "$PrototypeArt-inventory"; Write-Inventory $PrototypeInventory @('/Game/Maps/Prototype','/Game/Art/SM_BlockoutWall','/Game/Art/M_Blockout','/Game/Art/T_Blockout')
	$PrototypeOutput = & $Validator -DependencyReportDirectory $PrototypeArt -CookedInventoryDirectory $PrototypeInventory | Out-String
	Assert-True ($PrototypeOutput -match 'Validated 3 cooked hard') 'Ordinary low-detail prototype art should pass.'
	Write-Output 'PASS: ordinary prototype meshes, materials, and textures are not classified as high-detail'
	$Orphan = Join-Path $FixtureRoot 'orphan'; Write-Dump $Orphan @() @{ '/Script/UMG.WidgetBlueprint'='/Game/UI/W_Orphan' }
	$OrphanInventory = "$Orphan-inventory"; Write-Inventory $OrphanInventory @('/Game/UI/W_Orphan')
	Invoke-ExpectedFailure $Orphan $OrphanInventory 'UI.*cooked inventory.*W_Orphan.*WidgetBlueprint'
	Write-Output 'PASS: forbidden cooked project package is rejected without a dependency edge'
	$ClientFamilies = @(
		@{ Asset='/Script/UMG'; Category='UI' }, @{ Asset='/Script/Slate'; Category='UI' },
		@{ Asset='/Script/SlateCore'; Category='UI' }, @{ Asset='/Script/CommonUI'; Category='UI' },
		@{ Asset='/Script/EnhancedInput'; Category='Client input' }, @{ Asset='/CommonUI/WBP_Base'; Category='UI' },
		@{ Asset='/EnhancedInput/IMC_Default'; Category='Client input' }
	)
	foreach ($Family in $ClientFamilies) {
		$Name = $Family.Asset -replace '[^A-Za-z]', ''
		$Dir = Join-Path $FixtureRoot "family-$Name"
		Write-Dump $Dir @(@{Source='/Game/Gameplay/BP_Server';Target=$Family.Asset;Properties='Hard,Game,Build'}) @{}
		$InventoryPackages = @('/Game/Gameplay/BP_Server')
		if ($Family.Asset -notlike '/Script/*') { $InventoryPackages += $Family.Asset }
		$Inventory = "$Dir-inventory"; Write-Inventory $Inventory $InventoryPackages
		Invoke-ExpectedFailure $Dir $Inventory ("{0}.*{1}.*class unavailable" -f [regex]::Escape($Family.Category), [regex]::Escape($Family.Asset))
	}
	Write-Output 'PASS: client-only script and plugin content families fail without class metadata'
	foreach ($PluginPackage in @('/CommonUI/WBP_Orphan', '/EnhancedInput/IMC_Orphan')) {
		$Name = $PluginPackage -replace '[^A-Za-z]', ''
		$Dir = Join-Path $FixtureRoot "inventory-$Name"; Write-Dump $Dir @() @{}
		$Inventory = "$Dir-inventory"; Write-Inventory $Inventory @($PluginPackage)
		Invoke-ExpectedFailure $Dir $Inventory ("cooked inventory.*{0}.*class unavailable" -f [regex]::Escape($PluginPackage))
	}
	Write-Output 'PASS: inventory-only CommonUI and EnhancedInput plugin content is rejected'
	$PluginSource = Join-Path $FixtureRoot 'project-plugin-source'
	Write-Dump $PluginSource @(@{Source='/AethelnCombat/BP_PluginServer';Target='/CommonUI/WBP_PluginHUD';Properties='Hard,Game,Build'}) @{}
	$PluginSourceInventory = "$PluginSource-inventory"; Write-Inventory $PluginSourceInventory @('/AethelnCombat/BP_PluginServer','/CommonUI/WBP_PluginHUD')
	Invoke-ExpectedFailure $PluginSource $PluginSourceInventory 'UI.*BP_PluginServer.*CommonUI/WBP_PluginHUD.*class unavailable'
	Write-Output 'PASS: non-/Game project-plugin source dependency graph is validated'
	$AllowlistPresentation = Join-Path $FixtureRoot 'allowlist-presentation'
	$AllowlistAssets = @('/Game/ServerData/Collision/WBP_Admin','/Game/ServerData/Navigation/S_Admin','/Game/ServerData/Gameplay/NS_Admin','/Game/ServerData/Collision/CA_Admin','/Game/ServerData/Navigation/SK_Hero')
	Write-Dump $AllowlistPresentation @(
		@{Source='/Game/Gameplay/BP_Server';Target=$AllowlistAssets[0];Properties='Hard,Game,Build'},
		@{Source='/Game/Gameplay/BP_Server';Target=$AllowlistAssets[1];Properties='Hard,Game,Build'},
		@{Source='/Game/Gameplay/BP_Server';Target=$AllowlistAssets[2];Properties='Hard,Game,Build'},
		@{Source='/Game/Gameplay/BP_Server';Target=$AllowlistAssets[3];Properties='Hard,Game,Build'},
		@{Source='/Game/Gameplay/BP_Server';Target=$AllowlistAssets[4];Properties='Hard,Game,Build'}
	) @{ '/Script/UMG.WidgetBlueprint'=$AllowlistAssets[0]; '/Script/Engine.SoundWave'=$AllowlistAssets[1]; '/Script/Niagara.NiagaraSystem'=$AllowlistAssets[2]; '/Script/Engine.CameraAnimationSequence'=$AllowlistAssets[3]; '/Script/Engine.SkeletalMesh'=$AllowlistAssets[4] }
	$AllowlistInventory = "$AllowlistPresentation-inventory"; Write-Inventory $AllowlistInventory (@('/Game/Gameplay/BP_Server') + $AllowlistAssets)
	$AllowlistFailure = $null; try { & $Validator -DependencyReportDirectory $AllowlistPresentation -CookedInventoryDirectory $AllowlistInventory | Out-Null } catch { $AllowlistFailure = $_.Exception.Message }
	foreach ($Asset in $AllowlistAssets) { Assert-True ($AllowlistFailure -match [regex]::Escape($Asset)) "Forbidden presentation package '$Asset' must not be exempted by a ServerData prefix." }
	Write-Output 'PASS: every server-required prefix still rejects forbidden presentation assets'
	$Malformed = Join-Path $FixtureRoot 'malformed'; Write-Dump $Malformed @(@{Source='/Game/A';Target='/Game/UI/W';Properties='Unknown'}) @{ '/Script/UMG.WidgetBlueprint'='/Game/UI/W' }
	$MalformedInventory = "$Malformed-inventory"; Write-Inventory $MalformedInventory @('/Game/A','/Game/UI/W')
	Invoke-ExpectedFailure $Malformed $MalformedInventory 'malformed package properties'
	Write-Output 'PASS: malformed dependency properties fail closed'
	Write-Output 'All server cook reference tests passed.'
}
finally { if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force } }
