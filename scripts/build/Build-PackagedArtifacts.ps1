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
	[string] $Map = '/Game/Maps/StarterMap',
	[ValidateSet('All', 'Client', 'Server', 'Provenance')] [string] $Stage = 'All',
	[string] $ClientStageRoot,
	[string] $ServerStageRoot
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
function Invoke-UatBuild([string] $Label, [string[]] $Arguments, [string] $LogPath, [string] $AutomationToolLogDirectory) {
	Write-Output "Starting $Label. UAT log: '$LogPath'."
	New-Item -ItemType File -Path $LogPath | Out-Null
	$ResolvedAutomationToolLogs = Initialize-EmptyDirectory "$Label AutomationTool log directory" $AutomationToolLogDirectory
	$PreviousLogFolder = [Environment]::GetEnvironmentVariable('uebp_LogFolder', 'Process')
	$PreviousFinalLogFolder = [Environment]::GetEnvironmentVariable('uebp_FinalLogFolder', 'Process')
	try {
		[Environment]::SetEnvironmentVariable('uebp_LogFolder', $ResolvedAutomationToolLogs, 'Process')
		[Environment]::SetEnvironmentVariable('uebp_FinalLogFolder', $ResolvedAutomationToolLogs, 'Process')
		& $script:RunUat @Arguments 2>&1 | Tee-Object -FilePath $LogPath
		if ($LASTEXITCODE -ne 0) { throw "$Label failed with exit code $LASTEXITCODE. Review '$LogPath' for the Unreal AutomationTool error." }
	} finally {
		[Environment]::SetEnvironmentVariable('uebp_LogFolder', $PreviousLogFolder, 'Process')
		[Environment]::SetEnvironmentVariable('uebp_FinalLogFolder', $PreviousFinalLogFolder, 'Process')
	}
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
function Resolve-UbtSelectedTool([string] $LogDirectory, [string] $Label, [string] $ExecutableName) {
	$Sidecars = @(Get-ChildItem -LiteralPath $LogDirectory -File -Filter 'UBA-*.txt' | Sort-Object FullName)
	$Candidates = @($Sidecars | ForEach-Object {
		Get-Content -LiteralPath $_.FullName | ForEach-Object {
			if ($_ -match "^$([regex]::Escape($Label)):\s+(?<Path>.+$([regex]::Escape($ExecutableName)))\s*$") { $Matches.Path.Trim() }
		}
	})
	$UniqueCandidates = @($Candidates | ForEach-Object {
		try { [System.IO.Path]::GetFullPath($_) } catch { $_ }
	} | Sort-Object -Unique)
	if ($UniqueCandidates.Count -ne 1) {
		$Searched = if ($Sidecars.Count -eq 0) { '<none>' } else { $Sidecars.FullName -join ', ' }
		$Found = if ($UniqueCandidates.Count -eq 0) { '<none>' } else { $UniqueCandidates -join ', ' }
		throw "AutomationTool log directory '$LogDirectory' must identify exactly one UBT-selected $Label path ending in '$ExecutableName'; found $($UniqueCandidates.Count). Searched UBA sidecars: $Searched. Candidates: $Found."
	}
	Resolve-RequiredPath $Label $UniqueCandidates[0] 'Leaf'
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
$ResolvedClientStage = $null
$ResolvedServerStage = $null
if ($Stage -eq 'Provenance') {
	if ([string]::IsNullOrWhiteSpace($ClientStageRoot) -or [string]::IsNullOrWhiteSpace($ServerStageRoot)) { throw "Stage 'Provenance' requires -ClientStageRoot and -ServerStageRoot." }
	$ResolvedClientStage = Resolve-RequiredPath 'ClientStageRoot' $ClientStageRoot 'Container'
	$ResolvedServerStage = Resolve-RequiredPath 'ServerStageRoot' $ServerStageRoot 'Container'
	$ClientArchive = Resolve-RequiredPath 'ClientStageRoot WindowsClient archive' (Join-Path $ResolvedClientStage 'WindowsClient') 'Container'
	$ServerArchive = Resolve-RequiredPath 'ServerStageRoot LinuxServer archive' (Join-Path $ResolvedServerStage 'LinuxServer') 'Container'
} else {
	$ClientArchive = Join-Path $ResolvedArchive 'WindowsClient'
	$ServerArchive = Join-Path $ResolvedArchive 'LinuxServer'
	$StageArchives = switch ($Stage) {
		'Client' { @($ClientArchive) }
		'Server' { @($ServerArchive) }
		default { @($ClientArchive, $ServerArchive) }
	}
	New-Item -ItemType Directory -Path $StageArchives | Out-Null
}

$TargetGate = Join-Path $PSScriptRoot 'Validate-TargetComposition.ps1'
$CookGate = Join-Path $PSScriptRoot 'Validate-ServerCookReferences.ps1'
if (-not (Test-Path -LiteralPath $CookGate -PathType Leaf)) { throw "Required server-cook validation gate '$CookGate' is missing." }
if ($Stage -ne 'Provenance') { & $TargetGate -ProjectRoot $ProjectRoot }

$CommonArguments = @('BuildCookRun', "-project=$ResolvedProject", '-nop4', '-utf8output', '-unattended', '-build', '-cook', '-clean', '-stage', '-pak', '-archive', "-map=$Map")
$ClientArguments = $CommonArguments + @('-target=AethelnOnlineClient', '-platform=Win64', "-clientconfig=$Configuration", '-client', "-archivedirectory=$ClientArchive")
$ServerArguments = $null
if ($Stage -in @('All', 'Server')) {
	$ServerNeverCookDirectories = @(
		(Join-Path $ResolvedEngine 'Engine/Plugins/Runtime/CommonUI/Content'),
		(Join-Path $ResolvedEngine 'Engine/Plugins/EnhancedInput/Content'),
		(Join-Path $ResolvedEngine 'Engine/Plugins/Interchange/Runtime/Content')
	)
	foreach ($Directory in $ServerNeverCookDirectories) {
		if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { throw "Required server cook exclusion directory '$Directory' does not exist." }
	}
	$ServerCookerOptions = @('-ini:Input:[/Script/CommonUI.CommonUIInputSettings]:DefaultVirtualPointerClass=None') + @($ServerNeverCookDirectories | ForEach-Object { "-NeverCookDir=`"$_`"" })
	$ServerArguments = $CommonArguments + @('-target=AethelnOnlineServer', '-server', '-noclient', '-serverplatform=Linux', "-serverconfig=$Configuration", "-archivedirectory=$ServerArchive", "-AdditionalCookerOptions=$($ServerCookerOptions -join ' ')")
}
$DependencyRegistryPath = Join-Path $ProjectRoot 'Saved/Cooked/LinuxServer/AethelnOnline/Metadata/DevelopmentAssetRegistry.bin'
$CookedInventoryPath = Join-Path $ProjectRoot 'Saved/Cooked/LinuxServer/AethelnOnline/AssetRegistry.bin'
# Stage Server publishes its registry dumps as handoff payload so the later
# provenance-validation phase never depends on residual workspace state.
$DumpRoot = if ($Stage -eq 'Server') { Join-Path $ResolvedArchive 'RegistryDumps' } else { $ResolvedLogs }
$DependencyRegistryDump = Join-Path $DumpRoot 'server-dependency-registry-dump'
$CookedInventoryDump = Join-Path $DumpRoot 'server-cooked-inventory-dump'
$ClientAutomationToolLogs = Join-Path $ResolvedLogs 'client-automationtool'
$ServerAutomationToolLogs = Join-Path $ResolvedLogs 'server-automationtool'
$DependencyRegistryArguments = @($ResolvedProject, '-run=DumpAssetRegistry', "-Path=$DependencyRegistryPath", "-OutDir=$DependencyRegistryDump", '-ObjectPath', '-PackageName', '-Class', '-DependencyDetails', '-PackageData', '-unattended', '-nop4')
$CookedInventoryArguments = @($ResolvedProject, '-run=DumpAssetRegistry', "-Path=$CookedInventoryPath", "-OutDir=$CookedInventoryDump", '-PackageName', '-unattended', '-nop4')
$SelectedCompiler = $null
$SelectedResourceCompiler = $null
$PreviousToolchain = [Environment]::GetEnvironmentVariable('LINUX_MULTIARCH_ROOT', 'Process')
try {
	[Environment]::SetEnvironmentVariable('LINUX_MULTIARCH_ROOT', $ResolvedToolchain, 'Process')
	if ($Stage -in @('All', 'Client')) {
		Invoke-UatBuild 'Windows x64 client build/cook/package' $ClientArguments (Join-Path $ResolvedLogs 'client-uat.log') $ClientAutomationToolLogs
		Assert-PackagedExecutable 'Windows client packaging' $ClientArchive @('AethelnOnlineClient.exe', 'AethelnOnline.exe')
		$SelectedCompiler = Resolve-UbtSelectedTool $ClientAutomationToolLogs 'Compiler' 'cl.exe'
		$SelectedResourceCompiler = Resolve-UbtSelectedTool $ClientAutomationToolLogs 'Resource Compiler' 'rc.exe'
	}
	if ($Stage -in @('All', 'Server')) {
		Invoke-UatBuild 'Linux x86-64 dedicated server build/cook/package' $ServerArguments (Join-Path $ResolvedLogs 'server-uat.log') $ServerAutomationToolLogs
		Assert-PackagedExecutable 'Linux server packaging' $ServerArchive @('AethelnOnlineServer', 'AethelnOnlineServer-Linux-Shipping')
		Invoke-LoggedCommand 'dedicated-server dependency registry dump' $UnrealEditorCmd $DependencyRegistryArguments (Join-Path $ResolvedLogs 'server-dependency-registry-dump.log')
		Invoke-LoggedCommand 'dedicated-server cooked inventory dump' $UnrealEditorCmd $CookedInventoryArguments (Join-Path $ResolvedLogs 'server-cooked-inventory-dump.log')
		if ($Stage -eq 'All') { & $CookGate -DependencyReportDirectory $DependencyRegistryDump -CookedInventoryDirectory $CookedInventoryDump }
	}
} finally { [Environment]::SetEnvironmentVariable('LINUX_MULTIARCH_ROOT', $PreviousToolchain, 'Process') }

function Read-StageRecord([string] $Root, [string] $ExpectedStage) {
	$RecordPath = Join-Path $Root ('phase-{0}.json' -f $ExpectedStage.ToLowerInvariant())
	if (-not (Test-Path -LiteralPath $RecordPath -PathType Leaf)) { throw "Stage record '$RecordPath' does not exist; run the $ExpectedStage stage first." }
	$Record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
	foreach ($Property in @('schemaVersion', 'stage', 'sourceRevision', 'configuration', 'map')) {
		if ($null -eq $Record.PSObject.Properties[$Property]) { throw "Stage record '$RecordPath' is missing required property '$Property'." }
	}
	if ([int] $Record.schemaVersion -ne 1) { throw "Stage record '$RecordPath' has unsupported schema version '$($Record.schemaVersion)'." }
	if ([string] $Record.stage -ne $ExpectedStage.ToLowerInvariant()) { throw "Stage record '$RecordPath' records stage '$($Record.stage)' instead of '$($ExpectedStage.ToLowerInvariant())'." }
	if (-not ([string] $Record.sourceRevision).Equals($SourceRevision, [StringComparison]::OrdinalIgnoreCase)) { throw "Stage record '$RecordPath' was produced from source revision '$($Record.sourceRevision)', not the requested '$SourceRevision'." }
	if ([string] $Record.configuration -ne $Configuration -or [string] $Record.map -ne $Map) { throw "Stage record '$RecordPath' was produced with a different configuration or map than requested." }
	return $Record
}

function Resolve-RecordDirectory([string] $Root, [string] $Relative, [string] $Label) {
	if ([string]::IsNullOrWhiteSpace($Relative) -or [System.IO.Path]::IsPathRooted($Relative) -or (($Relative -split '[\\/]') -contains '..')) { throw "$Label must be a safe stage-relative directory path." }
	Resolve-RequiredPath $Label (Join-Path $Root $Relative) 'Container'
}

switch ($Stage) {
	'Client' {
		[ordered]@{
			schemaVersion = 1
			stage = 'client'
			sourceRevision = $SourceRevision
			configuration = $Configuration
			map = $Map
			clientArguments = $ClientArguments
			compilerPath = $SelectedCompiler
			resourceCompilerPath = $SelectedResourceCompiler
		} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ResolvedArchive 'phase-client.json') -Encoding UTF8
		Write-Output "Client packaging stage completed under '$ResolvedArchive'."
	}
	'Server' {
		[ordered]@{
			schemaVersion = 1
			stage = 'server'
			sourceRevision = $SourceRevision
			configuration = $Configuration
			map = $Map
			serverArguments = $ServerArguments
			dependencyRegistryDumpArguments = $DependencyRegistryArguments
			cookedInventoryDumpArguments = $CookedInventoryArguments
			dependencyReportDirectory = 'RegistryDumps/server-dependency-registry-dump'
			cookedInventoryDirectory = 'RegistryDumps/server-cooked-inventory-dump'
		} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ResolvedArchive 'phase-server.json') -Encoding UTF8
		Write-Output "Server packaging stage completed under '$ResolvedArchive'."
	}
	'Provenance' {
		$ClientRecord = Read-StageRecord $ResolvedClientStage 'Client'
		$ServerRecord = Read-StageRecord $ResolvedServerStage 'Server'
		foreach ($Property in @('clientArguments', 'compilerPath', 'resourceCompilerPath')) {
			if ($null -eq $ClientRecord.PSObject.Properties[$Property]) { throw "Client stage record is missing required property '$Property'." }
		}
		foreach ($Property in @('serverArguments', 'dependencyRegistryDumpArguments', 'cookedInventoryDumpArguments', 'dependencyReportDirectory', 'cookedInventoryDirectory')) {
			if ($null -eq $ServerRecord.PSObject.Properties[$Property]) { throw "Server stage record is missing required property '$Property'." }
		}
		$DependencyReportDirectory = Resolve-RecordDirectory $ResolvedServerStage ([string] $ServerRecord.dependencyReportDirectory) 'Dependency report directory'
		$CookedInventoryDirectory = Resolve-RecordDirectory $ResolvedServerStage ([string] $ServerRecord.cookedInventoryDirectory) 'Cooked inventory directory'
		& $CookGate -DependencyReportDirectory $DependencyReportDirectory -CookedInventoryDirectory $CookedInventoryDirectory
		$UatArgumentsJson = [ordered]@{ client = @($ClientRecord.clientArguments); server = @($ServerRecord.serverArguments); dependencyRegistryDump = @($ServerRecord.dependencyRegistryDumpArguments); cookedInventoryDump = @($ServerRecord.cookedInventoryDumpArguments) } | ConvertTo-Json -Compress
		& (Join-Path $PSScriptRoot 'Write-BuildProvenance.ps1') -OutputPath (Join-Path $ResolvedArchive 'build-provenance.json') -ProjectPath $ResolvedProject -EngineRoot $ResolvedEngine -LinuxToolchainRoot $ResolvedToolchain -SourceRevision $SourceRevision -BuildConfiguration $Configuration -ClientArchivePath $ClientArchive -ServerArchivePath $ServerArchive -CompilerPath ([string] $ClientRecord.compilerPath) -ResourceCompilerPath ([string] $ClientRecord.resourceCompilerPath) -UatArgumentsJson $UatArgumentsJson
		Write-Output "Provenance validation stage completed under '$ResolvedArchive'."
	}
	default {
		$UatArgumentsJson = [ordered]@{ client = $ClientArguments; server = $ServerArguments; dependencyRegistryDump = $DependencyRegistryArguments; cookedInventoryDump = $CookedInventoryArguments } | ConvertTo-Json -Compress
		& (Join-Path $PSScriptRoot 'Write-BuildProvenance.ps1') -OutputPath (Join-Path $ResolvedArchive 'build-provenance.json') -ProjectPath $ResolvedProject -EngineRoot $ResolvedEngine -LinuxToolchainRoot $ResolvedToolchain -SourceRevision $SourceRevision -BuildConfiguration $Configuration -ClientArchivePath $ClientArchive -ServerArchivePath $ServerArchive -CompilerPath $SelectedCompiler -ResourceCompilerPath $SelectedResourceCompiler -UatArgumentsJson $UatArgumentsJson
		Write-Output "Packaged artifacts completed under '$ResolvedArchive'."
	}
}
