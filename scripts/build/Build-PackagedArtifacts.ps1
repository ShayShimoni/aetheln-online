<#
.SYNOPSIS
Builds clean Win64 client and Linux dedicated-server archives with provenance.
.DESCRIPTION
Runs repository composition/cook-reference gates, executes the two proven
BuildCookRun command lines, validates packaged executables, and writes a hashed
artifact inventory. The UBT-emitted Compiler and Resource Compiler lines bind
provenance to the exact MSVC and Windows SDK tools selected for this invocation.
ArchiveRoot and LogRoot must be absent or empty so evidence
from separate runs cannot be mixed.
.EXAMPLE
./scripts/build/Build-PackagedArtifacts.ps1 -ProjectPath ./AethelnOnline.uproject -EngineRoot D:/UnrealEngine/UE-5.8.1-source -LinuxToolchainRoot C:/UnrealToolchains/v26_clang-20.1.8-rockylinux8 -ArchiveRoot D:/Builds/aetheln-e5798da -LogRoot D:/BuildLogs/aetheln-e5798da -SourceRevision e5798da01cc8dddb70c0a586843ddd2294dbfef3
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)] [string] $ProjectPath,
	[Parameter(Mandatory)] [string] $EngineRoot,
	[Parameter(Mandatory)] [string] $LinuxToolchainRoot,
	[Parameter(Mandatory)] [string] $ArchiveRoot,
	[Parameter(Mandatory)] [string] $LogRoot,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SourceRevision,
	[ValidateSet('Development', 'Shipping', 'Test')] [string] $Configuration = 'Development',
	[string] $Map = '/Game/Maps/StarterMap'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RequiredPath([string] $Name, [string] $Path, [string] $PathType) {
	if (-not (Test-Path -LiteralPath $Path -PathType $PathType)) { throw "$Name '$Path' does not exist or is not a $($PathType.ToLowerInvariant())." }
	(Resolve-Path -LiteralPath $Path).Path
}
function Initialize-EmptyDirectory([string] $Name, [string] $Path) {
	if (Test-Path -LiteralPath $Path) {
		if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Name '$Path' is not a directory." }
		if (@(Get-ChildItem -LiteralPath $Path -Force).Count -ne 0) { throw "$Name '$Path' must be empty or not exist; use a unique clean run directory." }
	} else { New-Item -ItemType Directory -Path $Path | Out-Null }
	(Resolve-Path -LiteralPath $Path).Path
}
function Invoke-UatBuild([string] $Label, [string[]] $Arguments, [string] $LogPath) {
	Write-Output "Starting $Label. UAT log: '$LogPath'."
	New-Item -ItemType File -Path $LogPath | Out-Null
	& $script:RunUat @Arguments 2>&1 | Tee-Object -FilePath $LogPath
	if ($LASTEXITCODE -ne 0) { throw "$Label failed with exit code $LASTEXITCODE. Review '$LogPath' for the Unreal AutomationTool error." }
}
function Invoke-LoggedCommand([string] $Label, [string] $Executable, [string[]] $Arguments, [string] $LogPath) {
	Write-Output "Starting $Label. Log: '$LogPath'."
	New-Item -ItemType File -Path $LogPath | Out-Null
	& $Executable @Arguments 2>&1 | Tee-Object -FilePath $LogPath
	if ($LASTEXITCODE -ne 0) { throw "$Label failed with exit code $LASTEXITCODE. Review '$LogPath' for details." }
}
function Assert-PackagedExecutable([string] $Label, [string] $Root, [string[]] $Names) {
	$Match = @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $Names -contains $_.Name })
	if ($Match.Count -eq 0) { throw "$Label completed but no expected packaged executable ($($Names -join ', ')) exists under '$Root'." }
}
function Resolve-UbtSelectedTool([string] $LogPath, [string] $Label, [string] $ExecutableName) {
	$Matches = @(Get-Content -LiteralPath $LogPath | ForEach-Object {
		if ($_ -match "(?:^|\s)$([regex]::Escape($Label)):\s+(?<Path>.+$([regex]::Escape($ExecutableName)))\s*$") { $Matches.Path.Trim() }
	} | Sort-Object -Unique)
	if ($Matches.Count -ne 1) { throw "UAT log '$LogPath' must identify exactly one UBT-selected $Label path ending in '$ExecutableName'; found $($Matches.Count)." }
	Resolve-RequiredPath $Label $Matches[0] 'Leaf'
}
function Assert-CleanRepository([string] $Root) {
	$StatusArguments = @('-C', $Root, 'status', '--porcelain=v1', '--untracked-files=all')
	$Status = @(& git @StatusArguments 2>&1)
	if ($LASTEXITCODE -ne 0) { throw "Could not verify repository cleanliness with 'git $($StatusArguments -join ' ')': $($Status -join [Environment]::NewLine)" }
	$Changes = @($Status | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
	if ($Changes.Count -gt 0) { throw "Packaged builds require a clean repository; git status found $($Changes.Count) modified or untracked path(s):`n - $($Changes -join "`n - ")`nCommit or otherwise resolve these inputs, then run the build again." }
}

$ResolvedProject = Resolve-RequiredPath 'ProjectPath' $ProjectPath 'Leaf'
$ProjectRoot = Split-Path -Parent $ResolvedProject
Assert-CleanRepository $ProjectRoot
$ResolvedEngine = Resolve-RequiredPath 'EngineRoot' $EngineRoot 'Container'
$ResolvedToolchain = Resolve-RequiredPath 'LinuxToolchainRoot' $LinuxToolchainRoot 'Container'
$script:RunUat = Join-Path $ResolvedEngine 'Engine/Build/BatchFiles/RunUAT.bat'
if (-not (Test-Path -LiteralPath $script:RunUat -PathType Leaf)) { throw "EngineRoot '$ResolvedEngine' does not contain RunUAT.bat at '$script:RunUat'." }
$UnrealEditorCmd = Join-Path $ResolvedEngine 'Engine/Binaries/Win64/UnrealEditor-Cmd.exe'
if (-not (Test-Path -LiteralPath $UnrealEditorCmd -PathType Leaf)) { throw "EngineRoot '$ResolvedEngine' does not contain UnrealEditor-Cmd.exe at '$UnrealEditorCmd'." }
$ResolvedArchive = Initialize-EmptyDirectory 'ArchiveRoot' $ArchiveRoot
$ResolvedLogs = Initialize-EmptyDirectory 'LogRoot' $LogRoot
$ClientArchive = Join-Path $ResolvedArchive 'WindowsClient'
$ServerArchive = Join-Path $ResolvedArchive 'LinuxServer'
New-Item -ItemType Directory -Path $ClientArchive, $ServerArchive | Out-Null

$TargetGate = Join-Path $PSScriptRoot 'Validate-TargetComposition.ps1'
$CookGate = Join-Path $PSScriptRoot 'Validate-ServerCookReferences.ps1'
if (-not (Test-Path -LiteralPath $CookGate -PathType Leaf)) { throw "Required server-cook validation gate '$CookGate' is missing." }
& $TargetGate -ProjectRoot $ProjectRoot

$CommonArguments = @('BuildCookRun', "-project=$ResolvedProject", '-nop4', '-utf8output', '-unattended', '-build', '-cook', '-clean', '-stage', '-pak', '-archive', "-map=$Map")
$ClientArguments = $CommonArguments + @('-target=AethelnOnlineClient', '-platform=Win64', "-clientconfig=$Configuration", '-client', "-archivedirectory=$ClientArchive")
$ServerNeverCookDirectories = @(
	(Join-Path $ResolvedEngine 'Engine/Plugins/Runtime/CommonUI/Content'),
	(Join-Path $ResolvedEngine 'Engine/Plugins/EnhancedInput/Content'),
	(Join-Path $ResolvedEngine 'Engine/Plugins/Interchange/Runtime/Interchange/Content')
)
foreach ($Directory in $ServerNeverCookDirectories) {
	if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { throw "Required server cook exclusion directory '$Directory' does not exist." }
}
$ServerCookerOptions = @('-ini:Input:[/Script/CommonUI.CommonUIInputSettings]:DefaultVirtualPointerClass=None') + @($ServerNeverCookDirectories | ForEach-Object { "-NeverCookDir=`"$_`"" })
$ServerArguments = $CommonArguments + @('-target=AethelnOnlineServer', '-server', '-noclient', '-serverplatform=Linux', "-serverconfig=$Configuration", "-archivedirectory=$ServerArchive", "-AdditionalCookerOptions=$($ServerCookerOptions -join ' ')")
$DependencyRegistryPath = Join-Path $ProjectRoot 'Saved/Cooked/LinuxServer/AethelnOnline/Metadata/DevelopmentAssetRegistry.bin'
$CookedInventoryPath = Join-Path $ProjectRoot 'Saved/Cooked/LinuxServer/AethelnOnline/AssetRegistry.bin'
$DependencyRegistryDump = Join-Path $ResolvedLogs 'server-dependency-registry-dump'
$CookedInventoryDump = Join-Path $ResolvedLogs 'server-cooked-inventory-dump'
$DependencyRegistryArguments = @($ResolvedProject, '-run=DumpAssetRegistry', "-Path=$DependencyRegistryPath", "-OutDir=$DependencyRegistryDump", '-ObjectPath', '-PackageName', '-Class', '-DependencyDetails', '-PackageData', '-unattended', '-nop4')
$CookedInventoryArguments = @($ResolvedProject, '-run=DumpAssetRegistry', "-Path=$CookedInventoryPath", "-OutDir=$CookedInventoryDump", '-PackageName', '-unattended', '-nop4')
$PreviousToolchain = [Environment]::GetEnvironmentVariable('LINUX_MULTIARCH_ROOT', 'Process')
try {
	[Environment]::SetEnvironmentVariable('LINUX_MULTIARCH_ROOT', $ResolvedToolchain, 'Process')
	Invoke-UatBuild 'Windows x64 client build/cook/package' $ClientArguments (Join-Path $ResolvedLogs 'client-uat.log')
	Assert-PackagedExecutable 'Windows client packaging' $ClientArchive @('AethelnOnlineClient.exe', 'AethelnOnline.exe')
	$SelectedCompiler = Resolve-UbtSelectedTool (Join-Path $ResolvedLogs 'client-uat.log') 'Compiler' 'cl.exe'
	$SelectedResourceCompiler = Resolve-UbtSelectedTool (Join-Path $ResolvedLogs 'client-uat.log') 'Resource Compiler' 'rc.exe'
	Invoke-UatBuild 'Linux x86-64 dedicated server build/cook/package' $ServerArguments (Join-Path $ResolvedLogs 'server-uat.log')
	Assert-PackagedExecutable 'Linux server packaging' $ServerArchive @('AethelnOnlineServer', 'AethelnOnlineServer-Linux-Shipping')
	Invoke-LoggedCommand 'dedicated-server dependency registry dump' $UnrealEditorCmd $DependencyRegistryArguments (Join-Path $ResolvedLogs 'server-dependency-registry-dump.log')
	Invoke-LoggedCommand 'dedicated-server cooked inventory dump' $UnrealEditorCmd $CookedInventoryArguments (Join-Path $ResolvedLogs 'server-cooked-inventory-dump.log')
	& $CookGate -DependencyReportDirectory $DependencyRegistryDump -CookedInventoryDirectory $CookedInventoryDump
} finally { [Environment]::SetEnvironmentVariable('LINUX_MULTIARCH_ROOT', $PreviousToolchain, 'Process') }

$UatArgumentsJson = [ordered]@{ client = $ClientArguments; server = $ServerArguments; dependencyRegistryDump = $DependencyRegistryArguments; cookedInventoryDump = $CookedInventoryArguments } | ConvertTo-Json -Compress
& (Join-Path $PSScriptRoot 'Write-BuildProvenance.ps1') -OutputPath (Join-Path $ResolvedArchive 'build-provenance.json') -ProjectPath $ResolvedProject -EngineRoot $ResolvedEngine -LinuxToolchainRoot $ResolvedToolchain -SourceRevision $SourceRevision -BuildConfiguration $Configuration -ClientArchivePath $ClientArchive -ServerArchivePath $ServerArchive -CompilerPath $SelectedCompiler -ResourceCompilerPath $SelectedResourceCompiler -UatArgumentsJson $UatArgumentsJson
Write-Output "Packaged artifacts completed under '$ResolvedArchive'."
