<#
.SYNOPSIS
Captures package-name inventories from exact cooked client and server Asset Registry files.

.DESCRIPTION
Stages the two canonical, already-produced cooked registries and runs Unreal's
read-only DumpAssetRegistry commandlet only against those immutable copies. It
does not build or cook. Each output directory receives a closed manifest that
binds the registry bytes and every page to content validation, build provenance,
source revision, pinned engine, target, platform, cook platform, and toolchain.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[string] $ProjectPath,
	[Parameter(Mandatory)]
	[string] $EngineRoot,
	[Parameter(Mandatory)]
	[string] $BuildProvenancePath,
	[Parameter(Mandatory)]
	[string] $ContentValidationReportPath,
	[Parameter(Mandatory)]
	[string] $ClientCookedRegistryPath,
	[Parameter(Mandatory)]
	[string] $ServerCookedRegistryPath,
	[Parameter(Mandatory)]
	[string] $OutputRoot,
	[string] $PolicyPath,
	[string] $RuntimeIntakePath,
	[string] $DumpCommandPath,
	[switch] $AllowTestCommand
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$GovernedPolicyPath = Join-Path $RepositoryRoot 'Config\ContentValidation\asset-intake-policy.json'
$GovernedRuntimeIntakePath = Join-Path $RepositoryRoot 'Config\ContentValidation\runtime-asset-intake.json'
if ([string]::IsNullOrWhiteSpace($PolicyPath)) { $PolicyPath = $GovernedPolicyPath }
if ([string]::IsNullOrWhiteSpace($RuntimeIntakePath)) { $RuntimeIntakePath = $GovernedRuntimeIntakePath }
if (-not $AllowTestCommand) {
	if ([IO.Path]::GetFullPath($PolicyPath) -cne [IO.Path]::GetFullPath($GovernedPolicyPath)) { throw 'PolicyPath override is test-only and requires AllowTestCommand.' }
	if ([IO.Path]::GetFullPath($RuntimeIntakePath) -cne [IO.Path]::GetFullPath($GovernedRuntimeIntakePath)) { throw 'RuntimeIntakePath override is test-only and requires AllowTestCommand.' }
}

function Resolve-RequiredFile([string] $Name, [string] $Path) {
	if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Name is missing at '$Path'." }
	return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-RequiredDirectory([string] $Name, [string] $Path) {
	if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Name is missing at '$Path'." }
	return (Resolve-Path -LiteralPath $Path).Path
}

function Get-LowerSha256([string] $Path) {
	return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-StableFileSnapshot([string] $Name, [string] $Path, [switch] $IncludeBytes) {
	$ResolvedPath = Resolve-RequiredFile $Name $Path
	$Before = Get-Item -LiteralPath $ResolvedPath
	$Bytes = $null
	$Stream = [IO.File]::Open($ResolvedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
	try {
		if ($IncludeBytes) {
			$Memory = [IO.MemoryStream]::new()
			try {
				$Stream.CopyTo($Memory)
				$Bytes = $Memory.ToArray()
			}
			finally { $Memory.Dispose() }
			$Hasher = [Security.Cryptography.SHA256]::Create()
			try { $Sha256 = ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
			finally { $Hasher.Dispose() }
		}
		else {
			$Hasher = [Security.Cryptography.SHA256]::Create()
			try { $Sha256 = ([BitConverter]::ToString($Hasher.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant() }
			finally { $Hasher.Dispose() }
		}
		$SizeBytes = $Stream.Length
	}
	finally { $Stream.Dispose() }
	$After = Get-Item -LiteralPath $ResolvedPath
	if ($Before.Length -ne $After.Length -or $Before.LastWriteTimeUtc.Ticks -ne $After.LastWriteTimeUtc.Ticks -or $SizeBytes -ne $After.Length) {
		throw "$Name changed while it was being read; capture fails closed."
	}
	if ($SizeBytes -le 0) { throw "$Name must have a positive byte size." }
	return [pscustomobject]@{
		Path = $ResolvedPath
		SizeBytes = [long]$SizeBytes
		Sha256 = $Sha256
		LastWriteTimeUtcTicks = [long]$After.LastWriteTimeUtc.Ticks
		Bytes = $Bytes
	}
}

function Read-StableJsonSnapshot([string] $Name, [string] $Path) {
	$Snapshot = Read-StableFileSnapshot $Name $Path -IncludeBytes
	try {
		$Text = [Text.UTF8Encoding]::new($false, $true).GetString($Snapshot.Bytes).TrimStart([char]0xfeff)
		$Value = $Text | ConvertFrom-Json
	}
	catch { throw "$Name '$($Snapshot.Path)' is not valid UTF-8 JSON: $($_.Exception.Message)" }
	return [pscustomobject]@{ Value = $Value; Identity = $Snapshot }
}

function Assert-FileUnchanged([object] $Expected, [string] $Context) {
	$Actual = Read-StableFileSnapshot $Context $Expected.Path
	if ($Actual.SizeBytes -ne $Expected.SizeBytes -or $Actual.Sha256 -cne $Expected.Sha256 -or $Actual.LastWriteTimeUtcTicks -ne $Expected.LastWriteTimeUtcTicks) {
		throw "$Context changed during capture; capture fails closed."
	}
}

function Copy-StableFile([object] $ExpectedSource, [string] $DestinationPath, [string] $Context) {
	Assert-FileUnchanged $ExpectedSource "$Context source"
	if (Test-Path -LiteralPath $DestinationPath) { throw "$Context staged path '$DestinationPath' already exists; refusing to overwrite evidence." }
	$SourceStream = [IO.File]::Open($ExpectedSource.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
	try {
		$DestinationStream = [IO.File]::Open($DestinationPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
		try { $SourceStream.CopyTo($DestinationStream) }
		finally { $DestinationStream.Dispose() }
	}
	finally { $SourceStream.Dispose() }
	Assert-FileUnchanged $ExpectedSource "$Context source"
	$Staged = Read-StableFileSnapshot "$Context staged copy" $DestinationPath
	if ($Staged.SizeBytes -ne $ExpectedSource.SizeBytes -or $Staged.Sha256 -cne $ExpectedSource.Sha256) {
		throw "$Context staged copy does not match the exact source bytes."
	}
	return $Staged
}

function Get-StringSha256([string] $Value) {
	$Bytes = [Text.Encoding]::UTF8.GetBytes($Value)
	$Hasher = [Security.Cryptography.SHA256]::Create()
	try { return ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
	finally { $Hasher.Dispose() }
}

function Get-JsonProperty([object] $Value, [string] $Name, [string] $Context) {
	if ($null -eq $Value -or $Value.PSObject.Properties.Name -notcontains $Name) { throw "$Context is missing required field '$Name'." }
	return $Value.$Name
}

function Assert-LowerSha256([object] $Value, [string] $Context) {
	if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{64}$') { throw "$Context must be a lowercase SHA-256 digest." }
}

function Invoke-IdentityCommand([string] $Executable, [string[]] $Arguments) {
	$Output = @(& $Executable @Arguments 2>&1)
	if ($LASTEXITCODE -ne 0) { throw "Identity command failed: $Executable $($Arguments -join ' ')`n$($Output -join [Environment]::NewLine)" }
	return (($Output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
}

function Get-PackageCount([string[]] $Pages, [string] $Context) {
	$Lines = @($Pages | ForEach-Object { Get-Content -LiteralPath $_ })
	$End = @($Lines | Select-String '^--- End Cached(?:Assets|Packages)ByPackageName : (?<EntryCount>\d+) entries ---$')
	if ($End.Count -ne 1) { throw "$Context did not emit exactly one complete package inventory section." }
	return [long]$End[0].Matches[0].Groups['EntryCount'].Value
}

function Invoke-InventoryCapture(
	[string] $Kind,
	[object] $StagedRegistry,
	[string] $RegistrySourceBinding,
	[string] $Target,
	[string] $Platform,
	[string] $CookPlatform,
	[string] $ToolchainIdentity,
	[string] $ToolchainSha256
) {
	$Destination = Join-Path $ResolvedOutputRoot $Kind
	$StartedUtc = [DateTime]::UtcNow.ToString('o')
	$Arguments = @($ResolvedProject, '-run=DumpAssetRegistry', "-Path=$($StagedRegistry.Path)", "-OutDir=$Destination", '-PackageName', '-unattended', '-nop4')
	$SemanticInvocation = (@($ResolvedDumpCommand) + $Arguments) -join "`0"
	if ($AllowTestCommand) {
		$CommandOutput = @(& powershell.exe -NoProfile -File $ResolvedDumpCommand @Arguments 2>&1)
	}
	else {
		$CommandOutput = @(& $ResolvedDumpCommand @Arguments 2>&1)
	}
	if ($LASTEXITCODE -ne 0) { throw "$Kind DumpAssetRegistry failed with exit code ${LASTEXITCODE}:`n$($CommandOutput -join [Environment]::NewLine)" }
	Assert-FileUnchanged $StagedRegistry ((Get-Culture).TextInfo.ToTitleCase($Kind) + ' staged cooked registry')

	$PageFiles = @(Get-ChildItem -LiteralPath $Destination -File -Filter 'Page_*.txt' | Sort-Object Name)
	if ($PageFiles.Count -eq 0) { throw "$Kind DumpAssetRegistry emitted no Page_*.txt files in '$Destination'." }
	for ($Index = 0; $Index -lt $PageFiles.Count; $Index++) {
		$Expected = 'Page_{0:D5}.txt' -f $Index
		if ($PageFiles[$Index].Name -cne $Expected) { throw "$Kind DumpAssetRegistry page sequence is not contiguous: expected '$Expected' but found '$($PageFiles[$Index].Name)'." }
	}
	$Pages = @($PageFiles | ForEach-Object { [ordered]@{ name = $_.Name; sha256 = Get-LowerSha256 $_.FullName } })
	$PackageCount = Get-PackageCount @($PageFiles.FullName) "$Kind DumpAssetRegistry"
	$CookArguments = if ($Kind -ceq 'client') { @($Build.build.uatInvocations.client.arguments) } else { @($Build.build.uatInvocations.server.arguments) }
	return [pscustomobject]@{
		Destination = $Destination
		StartedUtc = $StartedUtc
		Manifest = [ordered]@{
			schema_id = 'aetheln.cooked-inventory-manifest'
			schema_version = 2
			capture_mode = if ($AllowTestCommand) { 'test_fixture' } else { 'live_cooked_registry' }
			source_revision = [string]$Report.revision
			repository_clean = [bool]$Build.source.clean
			engine_revision = [string]$Report.execution_provenance.engine_revision
			engine_tag = [string]$Report.execution_provenance.engine_tag
			engine_binary_sha256 = $EngineBinarySha256
			build_version_sha256 = $BuildVersionSha256
			target = $Target
			platform = $Platform
			configuration = [string]$Build.build.configuration
			toolchain_identity = $ToolchainIdentity
			toolchain_sha256 = $ToolchainSha256
			project_sha256 = $ProjectSha256
			policy_sha256 = $PolicySha256
			intake_sha256 = $IntakeSha256
			content_validation_report_sha256 = $ReportSha256
			build_provenance_sha256 = $BuildProvenanceSha256
			cooked_registry = [ordered]@{
				source_path = $RegistrySourceBinding
				staged_path = 'AssetRegistry.bin'
				size_bytes = [long]$StagedRegistry.SizeBytes
				sha256 = [string]$StagedRegistry.Sha256
				target = $Target
				platform = $Platform
				cook_platform = $CookPlatform
				build_provenance_sha256 = $BuildProvenanceSha256
				source_revision = [string]$Build.source.revision
			}
			cook_command_sha256 = Get-StringSha256 (@($CookArguments) -join "`0")
			capture_command_sha256 = Get-StringSha256 $SemanticInvocation
			started_utc = $StartedUtc
			finished_utc = $null
			package_count = $PackageCount
			pages = $Pages
		}
	}
}

function Assert-LiveCaptureIdentity {
	$ActualRevision = Invoke-IdentityCommand 'git' @('-C', $RepositoryRoot, 'rev-parse', 'HEAD')
	if ($ActualRevision -cne [string]$Report.revision) { throw "Repository HEAD '$ActualRevision' differs from report revision '$($Report.revision)'." }
	$Status = @(& git -C $RepositoryRoot status --porcelain=v1 --untracked-files=all 2>&1)
	if ($LASTEXITCODE -ne 0 -or @($Status | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { throw 'Live inventory capture requires a clean repository.' }
	$EngineRevision = Invoke-IdentityCommand 'git' @('-C', $ResolvedEngine, 'rev-parse', 'HEAD')
	if ($EngineRevision -cne [string]$Report.execution_provenance.engine_revision) { throw 'Live EngineRoot HEAD differs from content-validation provenance.' }
	$TaggedRevision = Invoke-IdentityCommand 'git' @('-C', $ResolvedEngine, 'rev-parse', 'refs/tags/5.8.1-release^{commit}')
	if ([string]$Report.execution_provenance.engine_tag -cne '5.8.1-release' -or $TaggedRevision -cne $EngineRevision) { throw 'EngineRoot does not resolve the pinned 5.8.1-release tag at its recorded revision.' }
}

$ResolvedProject = Resolve-RequiredFile 'ProjectPath' $ProjectPath
$ResolvedProjectRoot = Split-Path -Parent $ResolvedProject
$ResolvedEngine = Resolve-RequiredDirectory 'EngineRoot' $EngineRoot
$ResolvedBuildProvenance = Resolve-RequiredFile 'BuildProvenancePath' $BuildProvenancePath
$ResolvedReport = Resolve-RequiredFile 'ContentValidationReportPath' $ContentValidationReportPath
$ResolvedClientRegistry = Resolve-RequiredFile 'ClientCookedRegistryPath' $ClientCookedRegistryPath
$ResolvedServerRegistry = Resolve-RequiredFile 'ServerCookedRegistryPath' $ServerCookedRegistryPath
$ResolvedPolicy = Resolve-RequiredFile 'PolicyPath' $PolicyPath
$ResolvedIntake = Resolve-RequiredFile 'RuntimeIntakePath' $RuntimeIntakePath
$ResolvedOutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$CanonicalClientRegistryRelativePath = 'Saved/Cooked/WindowsClient/AethelnOnline/AssetRegistry.bin'
$CanonicalServerRegistryRelativePath = 'Saved/Cooked/LinuxServer/AethelnOnline/AssetRegistry.bin'
$CanonicalClientRegistryPath = [IO.Path]::GetFullPath((Join-Path $ResolvedProjectRoot ($CanonicalClientRegistryRelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)))
$CanonicalServerRegistryPath = [IO.Path]::GetFullPath((Join-Path $ResolvedProjectRoot ($CanonicalServerRegistryRelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)))
if (-not $AllowTestCommand) {
	if (-not [string]::Equals([IO.Path]::GetFullPath($ResolvedClientRegistry), $CanonicalClientRegistryPath, [StringComparison]::OrdinalIgnoreCase)) {
		throw "ClientCookedRegistryPath must be the canonical '$CanonicalClientRegistryRelativePath' file."
	}
	if (-not [string]::Equals([IO.Path]::GetFullPath($ResolvedServerRegistry), $CanonicalServerRegistryPath, [StringComparison]::OrdinalIgnoreCase)) {
		throw "ServerCookedRegistryPath must be the canonical '$CanonicalServerRegistryRelativePath' file."
	}
}

if ($AllowTestCommand -and [string]::IsNullOrWhiteSpace($DumpCommandPath)) { throw 'AllowTestCommand requires an explicit DumpCommandPath.' }
if (-not $AllowTestCommand -and -not [string]::IsNullOrWhiteSpace($DumpCommandPath)) { throw 'DumpCommandPath is test-only and requires AllowTestCommand.' }
$ResolvedDumpCommand = if ($AllowTestCommand) {
	Resolve-RequiredFile 'DumpCommandPath' $DumpCommandPath
}
else {
	Resolve-RequiredFile 'pinned UnrealEditor-Cmd.exe' (Join-Path $ResolvedEngine 'Engine\Binaries\Win64\UnrealEditor-Cmd.exe')
}
if (Test-Path -LiteralPath $ResolvedOutputRoot) {
	if (-not (Test-Path -LiteralPath $ResolvedOutputRoot -PathType Container)) { throw "OutputRoot '$ResolvedOutputRoot' is not a directory." }
	if (@(Get-ChildItem -LiteralPath $ResolvedOutputRoot -Force).Count -gt 0) { throw "OutputRoot '$ResolvedOutputRoot' is not empty; refusing to mix or overwrite evidence." }
}

$BuildSnapshot = Read-StableJsonSnapshot 'Build provenance' $ResolvedBuildProvenance
$ReportSnapshot = Read-StableJsonSnapshot 'Content validation report' $ResolvedReport
$PolicySnapshot = Read-StableJsonSnapshot 'Asset intake policy' $ResolvedPolicy
$IntakeSnapshot = Read-StableJsonSnapshot 'Runtime asset intake registry' $ResolvedIntake
$Build = $BuildSnapshot.Value
$Report = $ReportSnapshot.Value
$Policy = $PolicySnapshot.Value
$Intake = $IntakeSnapshot.Value
if ([int](Get-JsonProperty $Build 'schemaVersion' 'Build provenance') -ne 2) { throw 'Build provenance must use schemaVersion 2.' }
if ((Get-JsonProperty $Build.source 'clean' 'Build provenance source') -ne $true) { throw 'Build provenance must record a clean source tree.' }
$PolicyReport = Get-JsonProperty $Policy 'report' 'Asset intake policy'
if ((Get-JsonProperty $Report 'schema_id' 'Content validation report') -cne (Get-JsonProperty $PolicyReport 'schema_id' 'Asset intake policy report') -or
	[int](Get-JsonProperty $Report 'schema_version' 'Content validation report') -ne [int](Get-JsonProperty $PolicyReport 'schema_version' 'Asset intake policy report')) {
	throw 'Content validation report schema identity does not match the governed policy.'
}
if ((Get-JsonProperty $Policy 'schema_id' 'Asset intake policy') -cne [string]$Intake.policy_schema_id -or [int]$Policy.schema_version -ne [int]$Intake.policy_schema_version) { throw 'Runtime intake policy identity does not match the governed policy.' }

$PolicySha256 = $PolicySnapshot.Identity.Sha256
$IntakeSha256 = $IntakeSnapshot.Identity.Sha256
$ReportSha256 = $ReportSnapshot.Identity.Sha256
$BuildProvenanceSha256 = $BuildSnapshot.Identity.Sha256
$ProjectIdentity = Read-StableFileSnapshot 'ProjectPath' $ResolvedProject
$ProjectSha256 = $ProjectIdentity.Sha256
$BuildVersionPath = Resolve-RequiredFile 'Unreal Build.version' (Join-Path $ResolvedEngine 'Engine\Build\Build.version')
$BuildVersionIdentity = Read-StableFileSnapshot 'Unreal Build.version' $BuildVersionPath
$DumpCommandIdentity = Read-StableFileSnapshot 'Dump command' $ResolvedDumpCommand
$EngineBinarySha256 = $DumpCommandIdentity.Sha256
$BuildVersionSha256 = $BuildVersionIdentity.Sha256

foreach ($DigestName in @('policy_sha256', 'intake_sha256')) { Assert-LowerSha256 $Report.$DigestName "Content validation report $DigestName" }
if ($Report.policy_sha256 -cne $PolicySha256 -or $Report.intake_sha256 -cne $IntakeSha256) { throw 'Content validation report policy/intake digests do not match the exact inputs.' }
if ($Report.execution_provenance.repository_clean -ne $true) { throw 'Content validation report must record a clean repository.' }
if ([string]$Report.execution_provenance.engine_tag -cne '5.8.1-release') { throw 'Content validation report must bind the pinned 5.8.1-release engine tag.' }
if ([string]$Build.source.revision -cne [string]$Report.revision) { throw 'Build provenance and content validation report source revisions differ.' }
if ([string]$Build.source.projectSha256 -cne $ProjectSha256 -or [string]$Report.execution_provenance.project_sha256 -cne $ProjectSha256) { throw 'Project digest is not bound consistently across build and content-validation provenance.' }
if ([string]$Build.tools.unreal.repositoryRevision -cne [string]$Report.execution_provenance.engine_revision) { throw 'Pinned engine revision differs between build and content-validation provenance.' }
if ([string]$Build.tools.unreal.buildVersionSha256 -cne $BuildVersionSha256 -or [string]$Report.execution_provenance.build_version_sha256 -cne $BuildVersionSha256) { throw 'Unreal Build.version digest is not bound consistently.' }
if ([string]$Report.execution_provenance.engine_binary_sha256 -cne $EngineBinarySha256) { throw 'Content-validation engine binary digest differs from the capture command binary.' }
if ([string]$Report.execution_provenance.target -cne 'AethelnOnlineEditor' -or [string]$Report.execution_provenance.platform -cne 'Win64') { throw 'Content validation report must be produced by AethelnOnlineEditor on Win64.' }
if ([string]$Report.execution_provenance.configuration -cne [string]$Build.build.configuration) { throw 'Content-validation and cook configurations differ.' }
if ([string]$Report.execution_provenance.compiler_sha256 -cne [string]$Build.tools.compiler.sha256) { throw 'Content-validation and build compiler digests differ.' }
if ([string]$Report.execution_provenance.resource_compiler_sha256 -cne [string]$Build.tools.windowsSdk.resourceCompilerSha256) { throw 'Content-validation and build resource-compiler digests differ.' }
if ([string]$Build.build.clientTarget -cne 'AethelnOnlineClient' -or [string]$Build.build.clientPlatform -cne 'Win64') { throw 'Build provenance must bind the AethelnOnlineClient Win64 target.' }
if ([string]$Build.build.serverTarget -cne 'AethelnOnlineServer' -or [string]$Build.build.serverPlatform -cne 'Linux') { throw 'Build provenance must bind the AethelnOnlineServer Linux target.' }
if ($AllowTestCommand) {
	if ([string]$Report.execution_provenance.registry_source -cne 'test_snapshot') { throw 'Test command capture requires a test_snapshot content-validation report.' }
}
elseif ([string]$Report.execution_provenance.registry_source -cne 'live_asset_registry') { throw 'Live capture requires a live_asset_registry content-validation report.' }
if (-not $AllowTestCommand) { Assert-LiveCaptureIdentity }

foreach ($Digest in @([string]$Build.tools.compiler.sha256, [string]$Build.tools.linuxCrossToolchain.compilerSha256)) { Assert-LowerSha256 $Digest 'Build toolchain digest' }
$ClientRegistryIdentity = Read-StableFileSnapshot 'Client cooked registry source' $ResolvedClientRegistry
$ServerRegistryIdentity = Read-StableFileSnapshot 'Server cooked registry source' $ResolvedServerRegistry

New-Item -ItemType Directory -Path $ResolvedOutputRoot -Force | Out-Null
$ClientDestination = Join-Path $ResolvedOutputRoot 'client'
$ServerDestination = Join-Path $ResolvedOutputRoot 'server'
New-Item -ItemType Directory -Path $ClientDestination,$ServerDestination | Out-Null
$StagedBuildProvenance = Copy-StableFile $BuildSnapshot.Identity (Join-Path $ResolvedOutputRoot 'build-provenance.json') 'Build provenance'
$StagedClientRegistry = Copy-StableFile $ClientRegistryIdentity (Join-Path $ClientDestination 'AssetRegistry.bin') 'Client cooked registry'
$StagedServerRegistry = Copy-StableFile $ServerRegistryIdentity (Join-Path $ServerDestination 'AssetRegistry.bin') 'Server cooked registry'
$ClientRegistrySourceBinding = if ($AllowTestCommand) { $ResolvedClientRegistry.Replace('\','/') } else { $CanonicalClientRegistryRelativePath }
$ServerRegistrySourceBinding = if ($AllowTestCommand) { $ResolvedServerRegistry.Replace('\','/') } else { $CanonicalServerRegistryRelativePath }

$ClientCapture = Invoke-InventoryCapture 'client' $StagedClientRegistry $ClientRegistrySourceBinding ([string]$Build.build.clientTarget) ([string]$Build.build.clientPlatform) 'WindowsClient' ([string]$Build.tools.compiler.version) ([string]$Build.tools.compiler.sha256)
$ServerCapture = Invoke-InventoryCapture 'server' $StagedServerRegistry $ServerRegistrySourceBinding ([string]$Build.build.serverTarget) ([string]$Build.build.serverPlatform) 'LinuxServer' ([string]$Build.tools.linuxCrossToolchain.identity) ([string]$Build.tools.linuxCrossToolchain.compilerSha256)

$CaptureInputChecks = @(
	@{ Identity=$BuildSnapshot.Identity; Context='Build provenance' },
	@{ Identity=$ReportSnapshot.Identity; Context='Content validation report' },
	@{ Identity=$PolicySnapshot.Identity; Context='Asset intake policy' },
	@{ Identity=$IntakeSnapshot.Identity; Context='Runtime asset intake registry' },
	@{ Identity=$ProjectIdentity; Context='Project descriptor' },
	@{ Identity=$BuildVersionIdentity; Context='Unreal Build.version' },
	@{ Identity=$DumpCommandIdentity; Context='Dump command' },
	@{ Identity=$ClientRegistryIdentity; Context='Client cooked registry source' },
	@{ Identity=$ServerRegistryIdentity; Context='Server cooked registry source' },
	@{ Identity=$StagedBuildProvenance; Context='Staged build provenance' },
	@{ Identity=$StagedClientRegistry; Context='Client staged cooked registry' },
	@{ Identity=$StagedServerRegistry; Context='Server staged cooked registry' }
)
foreach ($Check in $CaptureInputChecks) {
	Assert-FileUnchanged $Check.Identity $Check.Context
}
if (-not $AllowTestCommand) { Assert-LiveCaptureIdentity }

foreach ($Capture in @($ClientCapture,$ServerCapture)) {
	$Capture.Manifest.finished_utc = [DateTime]::UtcNow.ToString('o')
	$ManifestPath = Join-Path $Capture.Destination 'inventory-manifest.json'
	[IO.File]::WriteAllText($ManifestPath, (($Capture.Manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
	Write-Output "Captured $($Capture.Manifest.package_count) $((Split-Path -Leaf $Capture.Destination)) package(s) into '$($Capture.Destination)'."
}

foreach ($Check in $CaptureInputChecks) {
	Assert-FileUnchanged $Check.Identity $Check.Context
}
if (-not $AllowTestCommand) { Assert-LiveCaptureIdentity }
