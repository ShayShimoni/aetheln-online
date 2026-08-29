<#
.SYNOPSIS
Rejects client-presentation hard dependencies from a dedicated-server cook registry dump.

.DESCRIPTION
Consumes two deterministic Page_*.txt dumps written by UE 5.8's built-in
DumpAssetRegistry commandlet. The runtime AssetRegistry dump defines the exact cooked
package inventory. The development registry dump supplies asset classes and dependency
details. Only dependency edges within that cooked inventory are evaluated.

.EXAMPLE
& UnrealEditor-Cmd.exe AethelnOnline.uproject -run=DumpAssetRegistry `
  -Path=Saved/Cooked/LinuxServer/AethelnOnline/Metadata/DevelopmentAssetRegistry.bin `
  -OutDir=Saved/Reports/LinuxServerDependencies -ObjectPath -PackageName -Class `
  -DependencyDetails -PackageData -unattended
& UnrealEditor-Cmd.exe AethelnOnline.uproject -run=DumpAssetRegistry `
  -Path=Saved/Cooked/LinuxServer/AethelnOnline/AssetRegistry.bin `
  -OutDir=Saved/Reports/LinuxServerInventory -PackageName -unattended
& .\scripts\build\Validate-ServerCookReferences.ps1 `
  -DependencyReportDirectory Saved/Reports/LinuxServerDependencies `
  -CookedInventoryDirectory Saved/Reports/LinuxServerInventory
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[string] $DependencyReportDirectory,
	[Parameter(Mandatory)]
	[string] $CookedInventoryDirectory,
	[string[]] $ServerRequiredPrefixes = @(
		'/Game/ServerData/Collision/', '/Game/ServerData/Navigation/', '/Game/ServerData/Gameplay/'
	)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ForbiddenCategory([string] $Asset, [string] $Class) {
	if ($Asset -match '(?i)^/Script/(UMG|Slate|SlateCore|CommonUI)(?:[./]|$)' -or $Asset -match '(?i)^/CommonUI/') { return 'UI' }
	if ($Asset -match '(?i)^/Script/EnhancedInput(?:[./]|$)' -or $Asset -match '(?i)^/EnhancedInput/') { return 'Client input' }
	if ($Class -match '(?i)(Widget|Slate|CommonUI|UserWidget)' -or $Asset -match '(?i)/(UI|HUD|Widgets?)/') { return 'UI' }
	if ($Class -match '(?i)(Sound|Audio|MetaSound|DialogueWave)' -or $Asset -match '(?i)/(Audio|Sounds?|Music)/') { return 'Audio' }
	if ($Class -match '(?i)Niagara' -or $Asset -match '(?i)/(VFX|Niagara|Effects)/') { return 'Niagara' }
	if ($Class -match '(?i)(Camera|CameraShake)' -or $Asset -match '(?i)/(Cameras?)/') { return 'Camera' }
	if ($Class -match '(?i)(LevelSequence|GeometryCache|Groom)' -or $Asset -match '(?i)(?:/|_|-)(Cinematics?|Cinematic|HighDetail|Hero|4K|8K|Nanite|Groom)(?:/|_|-|$)') { return 'High-detail art' }
	return $null
}

if (-not (Test-Path -LiteralPath $DependencyReportDirectory -PathType Container)) {
	throw "Development DumpAssetRegistry dependency report directory is missing at '$DependencyReportDirectory'. Run DumpAssetRegistry with -Class -DependencyDetails; validation fails closed."
}
if (-not (Test-Path -LiteralPath $CookedInventoryDirectory -PathType Container)) {
	throw "Runtime DumpAssetRegistry cooked inventory directory is missing at '$CookedInventoryDirectory'. Run DumpAssetRegistry on the cooked AssetRegistry.bin with -PackageName; validation fails closed."
}
$InventoryPages = @(Get-ChildItem -LiteralPath $CookedInventoryDirectory -File -Filter 'Page_*.txt' | Sort-Object Name)
if ($InventoryPages.Count -eq 0) { throw "Cooked inventory '$CookedInventoryDirectory' contains no Page_*.txt files; validation fails closed." }
$InventoryLines = @($InventoryPages | ForEach-Object { Get-Content -LiteralPath $_.FullName })
$InventoryBeginMatch = $InventoryLines | Select-String '^--- Begin Cached(?:Assets|Packages)ByPackageName ---$' | Select-Object -First 1
$InventoryEndMatch = $InventoryLines | Select-String '^--- End Cached(?:Assets|Packages)ByPackageName : \d+ entries ---$' | Select-Object -First 1
if ($null -eq $InventoryBeginMatch -or $null -eq $InventoryEndMatch) { throw "Cooked inventory '$CookedInventoryDirectory' is missing a complete CachedAssetsByPackageName section. Include -PackageName." }
$CookedPackages = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
for ($Index = $InventoryBeginMatch.LineNumber; $Index -lt ($InventoryEndMatch.LineNumber - 1); $Index++) {
	$Line = $InventoryLines[$Index]
	if ($Line -match '^\t(/[^\t ]+) : \d+ item\(s\)$') { [void]$CookedPackages.Add($Matches[1]); continue }
	if ($Line -match '^\t\t/[^\s]+$') { continue }
	throw "Cooked inventory '$CookedInventoryDirectory' has malformed package data at line $($Index + 1): '$Line'."
}
if ($CookedPackages.Count -eq 0) { throw "Cooked inventory '$CookedInventoryDirectory' contains no packages; validation fails closed." }

$Pages = @(Get-ChildItem -LiteralPath $DependencyReportDirectory -File -Filter 'Page_*.txt' | Sort-Object Name)
if ($Pages.Count -eq 0) { throw "Dependency report '$DependencyReportDirectory' contains no Page_*.txt files; validation fails closed." }
$Lines = @($Pages | ForEach-Object { Get-Content -LiteralPath $_.FullName })

$ClassBegin = [array]::IndexOf($Lines, '--- Begin CachedAssetsByClass ---')
$ClassEnd = ($Lines | Select-String '^--- End CachedAssetsByClass : \d+ entries ---$' | Select-Object -First 1).LineNumber
$DependsBegin = [array]::IndexOf($Lines, '--- Begin CachedDependsNodes ---')
$DependsEnd = ($Lines | Select-String '^--- End CachedDependsNodes : \d+ entries ---$' | Select-Object -First 1).LineNumber
if ($ClassBegin -lt 0 -or $null -eq $ClassEnd) { throw "Dependency report '$DependencyReportDirectory' is missing a complete CachedAssetsByClass section. Include -Class." }
if ($DependsBegin -lt 0 -or $null -eq $DependsEnd) { throw "Dependency report '$DependencyReportDirectory' is missing a complete CachedDependsNodes section. Include -DependencyDetails." }

$PackageClasses = @{}
$CurrentClass = $null
for ($Index = $ClassBegin + 1; $Index -lt ($ClassEnd - 1); $Index++) {
	$Line = $Lines[$Index]
	if ($Line -match '^\t([^\t]+) : \d+ item\(s\)$') { $CurrentClass = $Matches[1]; continue }
	if ($Line -match '^\t\t(/[^\s]+)$' -and $null -ne $CurrentClass) {
		$ObjectPath = $Matches[1]
		$Package = $ObjectPath -replace '\.[^./:]+(?::.*)?$', ''
		if (-not $PackageClasses.ContainsKey($Package)) { $PackageClasses[$Package] = [System.Collections.Generic.List[string]]::new() }
		$PackageClasses[$Package].Add($CurrentClass)
		continue
	}
	throw "Dependency report '$DependencyReportDirectory' has malformed class data at line $($Index + 1): '$Line'."
}

$Violations = [System.Collections.Generic.List[string]]::new()
foreach ($CookedPackage in $CookedPackages) {
	if ($CookedPackage -like '/Engine/*') { continue }
	$Classes = if ($PackageClasses.ContainsKey($CookedPackage)) { @($PackageClasses[$CookedPackage]) } else { @('<class unavailable>') }
	$ClassText = $Classes -join ', '
	$Category = Get-ForbiddenCategory $CookedPackage $ClassText
	if ($null -ne $Category) {
		$Violations.Add("${Category}: cooked inventory contains project package '$CookedPackage' (class '$ClassText') even though it may have no reported dependency edge.")
		continue
	}
}
$CurrentSource = $null
$CurrentCategory = $null
$HardCount = 0
$AllowlistedCount = 0
for ($Index = $DependsBegin + 1; $Index -lt ($DependsEnd - 1); $Index++) {
	$Line = $Lines[$Index]
	if ($Line -match '^\t([^\t]+)$') { $CurrentSource = $Matches[1]; $CurrentCategory = $null; continue }
	if ($Line -match '^\t\t(Package|SearchableName|Manage|References)$') { $CurrentCategory = $Matches[1]; continue }
	if ($Line -match '^\t\t\t([^\t]+)\t\t\{([^}]+)\}$' -and $CurrentCategory -eq 'Package' -and $null -ne $CurrentSource) {
		$Dependency = $Matches[1]; $Properties = $Matches[2]
		if ($Properties -notmatch '^(Hard|Soft),(Game|EditorOnly),(Build|NotBuild)$') { throw "Dependency report '$DependencyReportDirectory' has malformed package properties at line $($Index + 1): '{$Properties}'." }
		if ($Properties -notmatch '^Hard,') { continue }
		if ($CurrentSource -like '/Engine/*') { continue }
		if (-not $CookedPackages.Contains($CurrentSource)) { continue }
		if ($Dependency -notlike '/Script/*' -and -not $CookedPackages.Contains($Dependency)) { continue }
		$HardCount++
		$Classes = if ($PackageClasses.ContainsKey($Dependency)) { @($PackageClasses[$Dependency]) } else { @('<class unavailable>') }
		$ClassText = $Classes -join ', '
		$Category = Get-ForbiddenCategory $Dependency $ClassText
		if ($null -ne $Category) { $Violations.Add("${Category}: source '$CurrentSource' has Hard package dependency '$Dependency' (class '$ClassText'; properties '{$Properties}')."); continue }
		$Allowed = $false
		foreach ($Prefix in $ServerRequiredPrefixes) { if ($Dependency -like "$Prefix*") { $Allowed = $true; break } }
		if ($Allowed) { $AllowlistedCount++ }
		continue
	}
	if ($Line -match '^\t\t\t') { continue }
	throw "Dependency report '$DependencyReportDirectory' has malformed dependency data at line $($Index + 1): '$Line'."
}

if ($Violations.Count -gt 0) { throw "Dedicated-server cook reference validation failed:`n - $($Violations -join "`n - ")" }
Write-Output "Validated $HardCount cooked hard package dependencies ($AllowlistedCount allowlisted server-required) across $($CookedPackages.Count) cooked packages."
Write-Output 'Dedicated-server cook reference validation passed.'
