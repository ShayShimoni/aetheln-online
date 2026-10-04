<#
.SYNOPSIS
Builds clean Win64 client and Linux dedicated-server archives with provenance.
.DESCRIPTION
Runs repository composition/cook-reference gates, executes the two proven
BuildCookRun command lines, validates packaged executables, and writes a hashed
artifact inventory. The UBT-emitted Compiler and Resource Compiler lines bind
provenance to the exact MSVC and Windows SDK tools selected for this invocation.
ArchiveRoot and LogRoot must be absent or empty so evidence
from separate runs cannot be mixed. Every run that resolves a valid LogRoot
writes a bounded machine-readable substep timing and cache-state record to
LogRoot/build-timing.json, including runs that fail closed before any UAT
process starts. An optional persistent local Derived Data Cache
(-DerivedDataCachePath) is reused only when its explicit cache-identity.json
record matches the exact clean pinned engine revision, toolchain content,
repository, project, configuration, and targets; a mismatched, corrupt, or
unverifiable cache fails closed or, with -CacheFallback CleanIsolated,
re-derives everything in a fresh run-scoped cache. An optional prebuilt
host-tools boundary (-HostToolsBoundary Prebuilt -EngineRevision <sha>) skips
rebuilding the host editor/engine tools only after fail-closed proof that they
belong to the exact clean pinned engine revision; the client and server
project targets always build with -clean.
.PARAMETER BuildNumber
Optional release build number, accepted only with -Stage Provenance and
forwarded to Write-BuildProvenance.ps1, which then adds a release block to the
provenance. Every other stage rejects it; without it nothing changes.
.EXAMPLE
$AethelnRevision = git rev-parse HEAD
$AethelnHostToolsAttestationPath = Read-Host 'Existing host-tools attestation file path'
./scripts/build/Build-PackagedArtifacts.ps1 -ProjectPath ./AethelnOnline.uproject -EngineRoot D:/UnrealEngine/UE-5.8.1-source-issue81-clean -LinuxToolchainRoot C:/UnrealToolchains/v26_clang-20.1.8-rockylinux8 -ArchiveRoot D:/Builds/aetheln-run-001 -LogRoot D:/BuildLogs/aetheln-run-001 -SourceRevision $AethelnRevision -HostToolsBoundary Prebuilt -EngineRevision 71fe36aac5a8df5ccd66c763ffc902b29b6a9c43 -HostToolsAttestationPath $AethelnHostToolsAttestationPath

Selects Prebuilt explicitly. Enter the path to an existing external attestation
record produced with -Stage AttestHostTools after an authorized successful
provisioning build, referencing its retained evidence. See the host-tools
attestation procedure in docs/developer-environment-and-ddc.md. Substitute local
roots and use absent or empty archive/log directories for each run. For a
separately operator-authorized full host-tools rebuild, replace the three
host-tools arguments with -HostToolsBoundary Rebuild. An omitted selection or
unverified prebuilt attestation fails closed; there is no rebuild fallback.
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
	[ValidateSet('All', 'Client', 'Server', 'Provenance', 'AttestHostTools')] [string] $Stage = 'All',
	[string] $ClientStageRoot,
	[string] $ServerStageRoot,
	[string] $DerivedDataCachePath,
	[ValidateSet('FailClosed', 'CleanIsolated')] [string] $CacheFallback = 'FailClosed',
	[ValidateSet('Rebuild', 'Prebuilt')] [string] $HostToolsBoundary,
	[string] $EngineRevision,
	[string] $HostToolsAttestationPath,
	[ValidatePattern('^$|^[^\x00-\x1f]{1,512}$')] [string] $ProvisioningEvidence,
	[ValidatePattern('^$|^[^\\/:*?"<>|\x00-\x1f]{1,128}$')] [string] $RunnerName,
	[string] $BuildNumber
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TimingStarted = [DateTime]::UtcNow
$script:TimingSteps = New-Object System.Collections.ArrayList
$script:UatMarkerEvents = New-Object System.Collections.ArrayList
$script:TimingRecordPath = $null
$script:CacheState = [ordered]@{ mode = 'engine-default'; status = 'not_configured'; appliedPath = $null }
$script:HostToolsState = [ordered]@{ mode = 'unresolved'; status = 'not_configured'; engineRevision = $null }
$script:DdcIdentityFieldNames = @('engineGitRevision', 'engineBuildVersionSha256', 'linuxToolchain', 'linuxToolchainCompilerSha256', 'projectRepository', 'project', 'configuration', 'targets')
# The repository's canonical pinned engine revision (docs/unreal-project-setup.md).
$script:CanonicalEngineRevision = '71fe36aac5a8df5ccd66c763ffc902b29b6a9c43'
$script:BuildTargetsContract = 'AethelnOnlineClient:Win64+AethelnOnlineServer:Linux'
# The pinned engine's generated Unreal target receipts are the authoritative
# bounded source of the host build products -nocompileeditor would skip: the
# source-built editor's executable code spans many UnrealEditor-*.dll
# engine/plugin modules a hand-written closed list cannot cover. UnrealPak and
# ShaderCompileWorker stay explicitly required as host programs.
$script:HostToolReceipts = @(
	@{ path = 'Engine/Binaries/Win64/UnrealEditor.target'; targetName = 'UnrealEditor'; targetType = 'Editor' },
	@{ path = 'Engine/Binaries/Win64/UnrealPak.target'; targetName = 'UnrealPak'; targetType = 'Program' },
	@{ path = 'Engine/Binaries/Win64/ShaderCompileWorker.target'; targetName = 'ShaderCompileWorker'; targetType = 'Program' }
)
# Symbol/debug and link-time-only products do not affect execution and stay
# out of the attested closure; an unknown product type fails closed.
$script:ReceiptIncludedProductTypes = @('Executable', 'DynamicLibrary', 'RequiredResource', 'BuildResource', 'Package')
$script:ReceiptExcludedProductTypes = @('SymbolFile', 'MapFile', 'StaticLibrary', 'ImportLibrary')
$script:ReceiptMaxBytes = 16777216
$script:ReceiptMaxProducts = 8192
$script:AttestationMaxBytes = 8388608
$script:AttestedFileMaxBytes = [long] 4294967296
$script:AttestedAggregateMaxBytes = [long] 137438953472
$script:AttestationPropertyNames = @('schemaVersion', 'engineGitRevision', 'files', 'provisioningEvidence', 'createdUtc')
$script:EvidenceIdentity = [ordered]@{
	engineGitRevision = $null
	engineGitRevisionStatus = 'unavailable'
	engineBuildVersionSha256 = $null
	engineBuildVersionSha256Status = 'unavailable'
	linuxToolchainCompilerSha256 = $null
	linuxToolchainCompilerSha256Status = 'unavailable'
	targets = $script:BuildTargetsContract
	runnerName = $null
}

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
		# The bounded marker capture timestamps UAT's own step-boundary lines as
		# they stream, so build/cook/stage/package/archive time inside one UAT
		# invocation is attributable without parsing logs after the fact.
		& $script:RunUat @Arguments 2>&1 | ForEach-Object {
			if ($script:UatMarkerEvents.Count -lt 64 -and ([string] $_) -match '^\*{6,}\s+(?<Step>[A-Z][A-Z ]*?)\s+COMMAND\s+(?<Event>STARTED|COMPLETED)\s+\*{6,}\s*$') {
				[void] $script:UatMarkerEvents.Add([ordered]@{ invocation = $Label; step = $Matches.Step; event = $Matches.Event; observedUtc = [DateTime]::UtcNow.ToString('o') })
			}
			$_
		} | Tee-Object -FilePath $LogPath
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
	Resolve-RequiredPath -Name $Label -Path $UniqueCandidates[0] -PathType 'Leaf'
}
function Assert-CleanRepository([string] $Root) {
	$StatusArguments = @('-C', $Root, 'status', '--porcelain=v1', '--untracked-files=all')
	$Status = @(& git @StatusArguments 2>&1)
	if ($LASTEXITCODE -ne 0) { throw "Could not verify repository cleanliness with 'git $($StatusArguments -join ' ')': $($Status -join [Environment]::NewLine)" }
	$Changes = @($Status | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
	if ($Changes.Count -gt 0) { throw "Packaged builds require a clean repository; git status found $($Changes.Count) modified or untracked path(s):`n - $($Changes -join "`n - ")`nCommit or otherwise resolve these inputs, then run the build again." }
}
function Get-GitLine([string] $Root, [string[]] $Arguments) {
	$Output = @(& git -C $Root @Arguments 2>&1)
	if ($LASTEXITCODE -ne 0) { return $null }
	return ,@($Output | ForEach-Object { ([string] $_).Trim() } | Where-Object { $_ -ne '' })
}
function Test-PathIsWithin([string] $Candidate, [string] $Parent) {
	$CandidateFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\', '/')
	$ParentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
	if ($CandidateFull.Equals($ParentFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }
	return $CandidateFull.StartsWith($ParentFull + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}
function Invoke-TimedStep([string] $Name, [scriptblock] $Body) {
	$StepStarted = [DateTime]::UtcNow
	$StepStatus = 'failed'
	try {
		& $Body
		$StepStatus = 'passed'
	} finally {
		[void] $script:TimingSteps.Add([ordered]@{
			name = $Name
			startedUtc = $StepStarted.ToString('o')
			durationSeconds = [Math]::Round(([DateTime]::UtcNow - $StepStarted).TotalSeconds, 3)
			status = $StepStatus
		})
	}
}
function Write-BuildTimingRecord {
	if ([string]::IsNullOrWhiteSpace($script:TimingRecordPath)) { return }
	$UatSteps = New-Object System.Collections.ArrayList
	$OpenEvents = @{}
	foreach ($MarkerEvent in @($script:UatMarkerEvents)) {
		$Key = '{0}|{1}' -f $MarkerEvent.invocation, $MarkerEvent.step
		if ($MarkerEvent.event -eq 'STARTED') {
			$OpenEvents[$Key] = [string] $MarkerEvent.observedUtc
		} elseif ($OpenEvents.ContainsKey($Key)) {
			$StepStartedUtc = [DateTime]::Parse([string] $OpenEvents[$Key], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
			$StepCompletedUtc = [DateTime]::Parse([string] $MarkerEvent.observedUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
			[void] $UatSteps.Add([ordered]@{
				invocation = [string] $MarkerEvent.invocation
				step = [string] $MarkerEvent.step
				startedUtc = [string] $OpenEvents[$Key]
				completedUtc = [string] $MarkerEvent.observedUtc
				durationSeconds = [Math]::Round(($StepCompletedUtc - $StepStartedUtc).TotalSeconds, 3)
			})
			$OpenEvents.Remove($Key)
		}
	}
	[ordered]@{
		schemaVersion = 3
		stage = $Stage.ToLowerInvariant()
		sourceRevision = $SourceRevision
		configuration = $Configuration
		map = $Map
		startedUtc = $script:TimingStarted.ToString('o')
		finishedUtc = [DateTime]::UtcNow.ToString('o')
		identity = $script:EvidenceIdentity
		derivedDataCache = $script:CacheState
		hostTools = $script:HostToolsState
		substeps = @($script:TimingSteps)
		uatSteps = @($UatSteps)
	} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:TimingRecordPath -Encoding UTF8
}
function Assert-SafeExternalPath([string] $Label, [string] $Value) {
	# Shared external-path contract for cache and attestation inputs, matching
	# the CI gate: an absolute non-UNC path on a local fixed drive, reached
	# without reparse points, disjoint from the repository, engine, toolchain,
	# archive, and log roots. Path-contract violations are configuration
	# errors and always fail closed; no fallback rescues them.
	if ($Value -match '^[\\/]{2}') { throw "$Label '$Value' must not be a UNC path; use a local fixed-drive path." }
	if (-not [System.IO.Path]::IsPathRooted($Value)) { throw "$Label '$Value' must be an absolute local path." }
	$Full = [System.IO.Path]::GetFullPath($Value)
	if ($Full -notmatch '^[A-Za-z]:\\.') { throw "$Label '$Value' must be a drive-rooted local path." }
	$DriveInfo = New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot($Full))
	if ($DriveInfo.DriveType -ne [System.IO.DriveType]::Fixed) { throw "$Label '$Value' must reside on a local fixed drive; drive '$($DriveInfo.Name)' is $($DriveInfo.DriveType)." }
	foreach ($Forbidden in @($ProjectRoot, $ResolvedEngine, $ResolvedToolchain, $ResolvedArchive, $ResolvedLogs)) {
		if ((Test-PathIsWithin $Full $Forbidden) -or (Test-PathIsWithin $Forbidden $Full)) { throw "$Label '$Value' must be disjoint from the repository, engine, toolchain, archive, and log roots; it overlaps '$Forbidden'." }
	}
	$Probe = $Full
	while ($Probe -and $Probe -notmatch '^[A-Za-z]:\\$') {
		if ((Test-Path -LiteralPath $Probe) -and ((Get-Item -LiteralPath $Probe -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { throw "$Label '$Value' is mediated by a reparse point at '$Probe'; use a plain local path." }
		$Probe = Split-Path -Parent $Probe
	}
	return $Full
}
function Get-ToolchainCompilerPath {
	foreach ($Candidate in @('x86_64-unknown-linux-gnu/bin/clang++.exe', 'x86_64-unknown-linux-gnu/bin/clang.exe', 'x86_64-unknown-linux-gnu/bin/clang.bat')) {
		$CandidateFull = Join-Path $ResolvedToolchain $Candidate
		if (Test-Path -LiteralPath $CandidateFull -PathType Leaf) { return $CandidateFull }
	}
	return $null
}
function Resolve-EvidenceIdentity {
	param([string] $RunnerName)
	# Bounded non-sensitive identity of this run's inputs so before/after
	# comparisons can prove identical engine, toolchain, source, targets,
	# configuration, and runner. Values are normalized identifiers only
	# (commit SHAs, content hashes, a validated runner name) - never machine
	# paths. Resolution never fails the run; unverifiable inputs are recorded
	# as explicit unavailable/dirty states.
	$Identity = [ordered]@{
		engineGitRevision = $null
		engineGitRevisionStatus = 'unavailable'
		engineBuildVersionSha256 = $null
		engineBuildVersionSha256Status = 'unavailable'
		linuxToolchainCompilerSha256 = $null
		linuxToolchainCompilerSha256Status = 'unavailable'
		targets = $script:BuildTargetsContract
		runnerName = $(if ([string]::IsNullOrWhiteSpace($RunnerName)) { $null } else { $RunnerName })
	}
	try {
		$RevisionLines = Get-GitLine $ResolvedEngine @('rev-parse', 'HEAD')
		if ($null -ne $RevisionLines -and $RevisionLines.Count -eq 1 -and $RevisionLines[0] -match '^[0-9a-f]{40}$') {
			$EngineStatus = Get-GitLine $ResolvedEngine @('status', '--porcelain=v1', '--untracked-files=all')
			if ($null -ne $EngineStatus) {
				$Identity.engineGitRevision = $RevisionLines[0]
				$Identity.engineGitRevisionStatus = if ($EngineStatus.Count -eq 0) { 'verified' } else { 'dirty' }
			}
		}
	} catch { Write-Verbose "Engine Git identity probe failed, so the engine revision fields stay unavailable: $($_.Exception.Message)" }
	try {
		$VersionPath = Join-Path $ResolvedEngine 'Engine/Build/Build.version'
		if (Test-Path -LiteralPath $VersionPath -PathType Leaf) {
			$Identity.engineBuildVersionSha256 = (Get-FileHash -LiteralPath $VersionPath -Algorithm SHA256).Hash.ToLowerInvariant()
			$Identity.engineBuildVersionSha256Status = 'verified'
		}
	} catch { Write-Verbose "Engine Build.version hash probe failed, so that identity field stays unavailable: $($_.Exception.Message)" }
	try {
		$CompilerPath = Get-ToolchainCompilerPath
		if ($null -ne $CompilerPath) {
			$Identity.linuxToolchainCompilerSha256 = (Get-FileHash -LiteralPath $CompilerPath -Algorithm SHA256).Hash.ToLowerInvariant()
			$Identity.linuxToolchainCompilerSha256Status = 'verified'
		}
	} catch { Write-Verbose "Linux toolchain compiler hash probe failed, so that identity field stays unavailable: $($_.Exception.Message)" }
	return $Identity
}
function Get-DdcExpectedIdentity {
	# Reuse is bound to the exact verified engine source revision in a clean
	# checkout, the content identity of the Linux cross compiler, a stable
	# repository identity (the project repository's root-commit set, which
	# never changes across project commits), and this controller's
	# configuration and target contract. The project source revision itself
	# stays out of the identity: cross-project-commit reuse is carried by
	# Unreal's content-addressed cache-entry keys, which bind asset content,
	# platform, and settings per entry.
	$VersionPath = Join-Path $ResolvedEngine 'Engine/Build/Build.version'
	if (-not (Test-Path -LiteralPath $VersionPath -PathType Leaf)) { return @{ failure = 'fallback_engine_identity_unverifiable'; detail = "EngineRoot '$ResolvedEngine' has no Engine/Build/Build.version, so the cache identity cannot be bound to the pinned engine" } }
	$EngineRevisionLines = Get-GitLine $ResolvedEngine @('rev-parse', 'HEAD')
	if ($null -eq $EngineRevisionLines -or $EngineRevisionLines.Count -ne 1 -or $EngineRevisionLines[0] -notmatch '^[0-9a-f]{40}$') { return @{ failure = 'fallback_engine_identity_unverifiable'; detail = "EngineRoot '$ResolvedEngine' is not a Git checkout whose exact source revision can be verified" } }
	$EngineStatus = Get-GitLine $ResolvedEngine @('status', '--porcelain=v1', '--untracked-files=all')
	if ($null -eq $EngineStatus) { return @{ failure = 'fallback_engine_identity_unverifiable'; detail = "EngineRoot '$ResolvedEngine' cleanliness could not be verified" } }
	if ($EngineStatus.Count -ne 0) { return @{ failure = 'fallback_engine_identity_unverifiable'; detail = "EngineRoot '$ResolvedEngine' has local modifications; the cache identity requires a clean pinned engine checkout" } }
	$CompilerPath = Get-ToolchainCompilerPath
	if ($null -eq $CompilerPath) { return @{ failure = 'fallback_toolchain_identity_unverifiable'; detail = "LinuxToolchainRoot '$ResolvedToolchain' holds no clang compiler whose content identity can be recorded" } }
	$RootCommits = Get-GitLine $ProjectRoot @('rev-list', '--max-parents=0', 'HEAD')
	if ($null -eq $RootCommits -or $RootCommits.Count -eq 0 -or @($RootCommits | Where-Object { $_ -notmatch '^[0-9a-f]{40}$' }).Count -ne 0) { return @{ failure = 'fallback_project_identity_unverifiable'; detail = 'the project repository root-commit identity could not be determined' } }
	return @{ identity = [ordered]@{
		schemaVersion = 2
		engineGitRevision = $EngineRevisionLines[0]
		engineBuildVersionSha256 = (Get-FileHash -LiteralPath $VersionPath -Algorithm SHA256).Hash.ToLowerInvariant()
		linuxToolchain = Split-Path -Leaf $ResolvedToolchain
		linuxToolchainCompilerSha256 = (Get-FileHash -LiteralPath $CompilerPath -Algorithm SHA256).Hash.ToLowerInvariant()
		projectRepository = (@($RootCommits | Sort-Object) -join '+')
		project = Split-Path -Leaf $ResolvedProject
		configuration = $Configuration
		targets = $script:BuildTargetsContract
	} }
}
function Get-DdcFallbackState([string] $Status, [string] $Detail, [string] $CacheFallback, [string] $DerivedDataCachePath) {
	if ($CacheFallback -ne 'CleanIsolated') {
		$script:CacheState = [ordered]@{ mode = 'persistent'; status = ($Status -replace '^fallback_', 'failed_'); appliedPath = $null }
		throw "DerivedDataCachePath '$DerivedDataCachePath' failed identity validation and cannot be reused safely: $Detail. Repair or replace the cache root, or pass -CacheFallback CleanIsolated to run a full clean re-derive in a fresh run-scoped cache instead."
	}
	$IsolatedPath = Join-Path $ResolvedLogs 'ddc-clean-isolated'
	New-Item -ItemType Directory -Path $IsolatedPath | Out-Null
	return [ordered]@{ mode = 'clean-isolated-fallback'; status = $Status; appliedPath = $IsolatedPath }
}
function Resolve-DerivedDataCache {
	param([string] $DerivedDataCachePath, [string] $CacheFallback)
	# Reused cache state is accepted only when the explicit identity record
	# matches this invocation exactly. Anything unverifiable fails closed or
	# takes the documented clean-isolated fallback; entries inside the cache
	# stay content-addressed by Unreal.
	if ([string]::IsNullOrWhiteSpace($DerivedDataCachePath)) {
		return [ordered]@{ mode = 'engine-default'; status = 'not_configured'; appliedPath = $null }
	}
	try { $FullCachePath = Assert-SafeExternalPath 'DerivedDataCachePath' $DerivedDataCachePath } catch {
		$script:CacheState = [ordered]@{ mode = 'persistent'; status = 'failed_path_invalid'; appliedPath = $null }
		throw
	}
	$Expected = Get-DdcExpectedIdentity
	if ($Expected.ContainsKey('failure')) { return Get-DdcFallbackState ([string] $Expected.failure) ([string] $Expected.detail) -CacheFallback $CacheFallback -DerivedDataCachePath $DerivedDataCachePath }
	$ExpectedIdentity = $Expected.identity
	if (Test-Path -LiteralPath $FullCachePath) {
		if (-not (Test-Path -LiteralPath $FullCachePath -PathType Container)) { return Get-DdcFallbackState 'fallback_unavailable' 'the configured path exists but is not a directory' -CacheFallback $CacheFallback -DerivedDataCachePath $DerivedDataCachePath }
		$CacheRoot = (Resolve-Path -LiteralPath $FullCachePath).Path
	} else {
		$CacheRoot = (New-Item -ItemType Directory -Path $FullCachePath).FullName
	}
	$IdentityPath = Join-Path $CacheRoot 'cache-identity.json'
	if (Test-Path -LiteralPath $IdentityPath -PathType Leaf) {
		$FallbackStatus = $null
		$Identity = $null
		try {
			$Identity = Get-Content -LiteralPath $IdentityPath -Raw | ConvertFrom-Json
			foreach ($Name in @('schemaVersion') + $script:DdcIdentityFieldNames) {
				if ($null -eq $Identity -or $null -eq $Identity.PSObject.Properties[$Name]) { throw 'corrupt' }
			}
			if ([int] $Identity.schemaVersion -ne 2) { throw 'corrupt' }
		} catch { $FallbackStatus = 'fallback_corrupt' }
		if ($null -eq $FallbackStatus) {
			foreach ($Name in $script:DdcIdentityFieldNames) {
				if ([string] $Identity.$Name -cne [string] $ExpectedIdentity[$Name]) { $FallbackStatus = 'fallback_mismatch' }
			}
		}
		if ($null -ne $FallbackStatus) { return Get-DdcFallbackState $FallbackStatus "the cache-identity.json record is $(if ($FallbackStatus -eq 'fallback_corrupt') { 'corrupt, incomplete, or from an older identity schema' } else { 'bound to a different engine revision, toolchain, repository, project, configuration, or target set' })" -CacheFallback $CacheFallback -DerivedDataCachePath $DerivedDataCachePath }
		return [ordered]@{ mode = 'persistent'; status = 'reused'; appliedPath = $CacheRoot }
	}
	if (@(Get-ChildItem -LiteralPath $CacheRoot -Force).Count -ne 0) { return Get-DdcFallbackState 'fallback_unverifiable' 'the directory already holds content but carries no cache-identity.json record' -CacheFallback $CacheFallback -DerivedDataCachePath $DerivedDataCachePath }
	$InitialRecord = [ordered]@{}
	foreach ($Name in @('schemaVersion') + $script:DdcIdentityFieldNames) { $InitialRecord[$Name] = $ExpectedIdentity[$Name] }
	$InitialRecord['schemaVersion'] = 2
	$InitialRecord['createdUtc'] = [DateTime]::UtcNow.ToString('o')
	$InitialRecord | ConvertTo-Json | Set-Content -LiteralPath $IdentityPath -Encoding UTF8
	return [ordered]@{ mode = 'persistent'; status = 'initialized'; appliedPath = $CacheRoot }
}
function Assert-CanonicalCleanEngine {
	$RevisionLines = Get-GitLine $ResolvedEngine @('rev-parse', 'HEAD')
	if ($null -eq $RevisionLines -or $RevisionLines.Count -ne 1 -or $RevisionLines[0] -notmatch '^[0-9a-f]{40}$') { throw "EngineRoot '$ResolvedEngine' is not a Git checkout whose exact revision can be verified; host-tools validation fails closed instead of guessing." }
	if ($RevisionLines[0] -cne $script:CanonicalEngineRevision) { throw "EngineRoot '$ResolvedEngine' is at engine revision '$($RevisionLines[0])', not the canonical pinned '$script:CanonicalEngineRevision'; host-tools validation fails closed." }
	$EngineStatus = Get-GitLine $ResolvedEngine @('status', '--porcelain=v1', '--untracked-files=all')
	if ($null -eq $EngineStatus) { throw "EngineRoot '$ResolvedEngine' cleanliness could not be verified; host-tools validation fails closed." }
	if ($EngineStatus.Count -ne 0) { throw "EngineRoot '$ResolvedEngine' has $($EngineStatus.Count) modified or untracked engine source path(s); host-tools validation requires a clean canonical pinned engine checkout." }
}
function Assert-SafeEngineRelativePath([string] $Label, [string] $Value) {
	if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Contains(':') -or [System.IO.Path]::IsPathRooted($Value) -or @(($Value -split '[\\/]') | Where-Object { $_ -in @('', '.', '..') }).Count -ne 0) { throw "$Label '$Value' must be a safe engine-relative path; host-tools validation fails closed." }
}
function Get-HostToolReceiptProductPath {
	# Derives the exact host build-product closure from the pinned engine's
	# generated Unreal target receipts. The set is re-derived fresh on every
	# attestation write and every prebuilt verification, so a caller-supplied
	# subset in the attestation record is never trusted.
	$Seen = @{}
	$Paths = New-Object System.Collections.ArrayList
	foreach ($Receipt in $script:HostToolReceipts) {
		$ReceiptRelative = [string] $Receipt.path
		$ReceiptFull = [System.IO.Path]::GetFullPath((Join-Path $ResolvedEngine $ReceiptRelative))
		if (-not (Test-Path -LiteralPath $ReceiptFull -PathType Leaf)) { throw "Required host-target receipt '$ReceiptRelative' does not exist under the engine root; host-tools validation fails closed." }
		if ((Get-Item -LiteralPath $ReceiptFull -Force).Length -gt $script:ReceiptMaxBytes) { throw "Required host-target receipt '$ReceiptRelative' exceeds the $($script:ReceiptMaxBytes)-byte receipt bound; host-tools validation fails closed." }
		$Parsed = $null
		try { $Parsed = Get-Content -LiteralPath $ReceiptFull -Raw | ConvertFrom-Json } catch { throw "Required host-target receipt '$ReceiptRelative' is not a parseable Unreal target receipt; host-tools validation fails closed." }
		foreach ($Name in @('TargetName', 'Platform', 'Configuration', 'TargetType', 'BuildProducts')) {
			if ($null -eq $Parsed -or $null -eq $Parsed.PSObject.Properties[$Name]) { throw "Required host-target receipt '$ReceiptRelative' is missing required metadata '$Name'; host-tools validation fails closed." }
		}
		if ([string] $Parsed.TargetName -cne [string] $Receipt.targetName -or [string] $Parsed.Platform -cne 'Win64' -or [string] $Parsed.Configuration -cne 'Development' -or [string] $Parsed.TargetType -cne [string] $Receipt.targetType) { throw "Required host-target receipt '$ReceiptRelative' does not describe the exact expected $($Receipt.targetName) Win64 Development $($Receipt.targetType) target; host-tools validation fails closed." }
		if ($Parsed.BuildProducts -isnot [array]) { throw "Required host-target receipt '$ReceiptRelative' must carry a BuildProducts array; host-tools validation fails closed." }
		$Products = @($Parsed.BuildProducts)
		if ($Products.Count -lt 1 -or $Products.Count -gt $script:ReceiptMaxProducts) { throw "Required host-target receipt '$ReceiptRelative' must list between 1 and $($script:ReceiptMaxProducts) build products; found $($Products.Count). Host-tools validation fails closed." }
		# The receipt itself is part of the attested closure so a receipt edit
		# after attestation fails the content re-verification.
		$Derived = New-Object System.Collections.ArrayList
		[void] $Derived.Add($ReceiptRelative)
		foreach ($Product in $Products) {
			if ($null -eq $Product -or $null -eq $Product.PSObject.Properties['Path'] -or $null -eq $Product.PSObject.Properties['Type'] -or $Product.Path -isnot [string] -or $Product.Type -isnot [string]) { throw "Required host-target receipt '$ReceiptRelative' carries a build product without string Path and Type; host-tools validation fails closed." }
			$ProductType = [string] $Product.Type
			if ($script:ReceiptExcludedProductTypes -ccontains $ProductType) { continue }
			if ($script:ReceiptIncludedProductTypes -cnotcontains $ProductType) { throw "Required host-target receipt '$ReceiptRelative' carries unknown build-product type '$ProductType'; host-tools validation fails closed." }
			$ProductPath = [string] $Product.Path
			if ($ProductPath -cnotmatch '^\$\(EngineDir\)/') { throw "Receipt '$ReceiptRelative' build product '$ProductPath' must resolve under the canonical engine root via `$(EngineDir); host-tools validation fails closed." }
			$RelativeProduct = 'Engine/' + $ProductPath.Substring(13)
			Assert-SafeEngineRelativePath "Receipt '$ReceiptRelative' build product" $RelativeProduct
			[void] $Derived.Add($RelativeProduct)
		}
		foreach ($RelativeProduct in $Derived) {
			$Normalized = ($RelativeProduct -replace '\\', '/').ToLowerInvariant()
			if ($Seen.ContainsKey($Normalized)) { throw "Receipt-derived host build product '$RelativeProduct' duplicates or case-collides with another product; host-tools validation fails closed." }
			$Seen[$Normalized] = $RelativeProduct
			[void] $Paths.Add($RelativeProduct)
		}
	}
	return ,@($Paths)
}
function Assert-UniqueAttestationJsonProperty([string] $Raw) {
	# Ported from Assert-UniqueJsonProperty in Invoke-EngineRunnerGate.ps1:
	# ConvertFrom-Json silently keeps one value for duplicated properties, so a
	# tampered document could carry two conflicting definitions. Scope-aware
	# scan of the raw text; name tracking is case-insensitive here so
	# case-colliding property names are rejected at every object level.
	$Failure = "HostToolsAttestationPath '$HostToolsAttestationPath' carries a duplicate or case-colliding JSON property name; host-tools validation fails closed."
	$Scopes = New-Object System.Collections.Stack
	$PendingName = $null
	$Index = 0
	$Length = $Raw.Length
	while ($Index -lt $Length) {
		$Character = $Raw[$Index]
		if ($Character -eq '"') {
			$Builder = New-Object System.Text.StringBuilder
			$Index++
			while ($Index -lt $Length -and $Raw[$Index] -ne '"') {
				if ($Raw[$Index] -eq '\') {
					[void] $Builder.Append($Raw[$Index])
					$Index++
					if ($Index -ge $Length) { throw $Failure }
				}
				[void] $Builder.Append($Raw[$Index])
				$Index++
			}
			if ($Index -ge $Length) { throw $Failure }
			# Compare decoded property names, not their raw escape spelling. Without
			# this, JSON such as "createdUtc" plus "cr\u0065atedUtc" survives the
			# raw scan and ConvertFrom-Json silently keeps only one value.
			try { $PendingName = [string] (('"' + $Builder.ToString() + '"') | ConvertFrom-Json) } catch { throw $Failure }
			$Index++
			continue
		}
		if ($Character -eq '{') {
			$Scopes.Push((New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)))
			$PendingName = $null
		} elseif ($Character -eq '}') {
			if ($Scopes.Count -eq 0) { throw $Failure }
			[void] $Scopes.Pop()
			$PendingName = $null
		} elseif ($Character -eq ':') {
			if ($null -ne $PendingName -and $Scopes.Count -gt 0) {
				if (-not $Scopes.Peek().Add($PendingName)) { throw $Failure }
			}
			$PendingName = $null
		} elseif ($Character -eq ',' -or $Character -eq '[' -or $Character -eq ']') {
			$PendingName = $null
		}
		$Index++
	}
	if ($Scopes.Count -ne 0) { throw $Failure }
}
function Test-AttestationJsonInteger($Value) {
	# ConvertFrom-Json materializes JSON integers as [int]/[long]; a quoted
	# numeric string or a fractional number is not a JSON integer.
	return ($Value -is [int] -or $Value -is [long])
}
function Test-AttestationTimestamp($Value) {
	# Newer PowerShell ConvertFrom-Json materializes ISO timestamps as
	# [datetime]; otherwise require a bounded string that round-trip parses to
	# an explicit UTC instant.
	if ($Value -is [datetime]) { return $Value.Kind -eq [System.DateTimeKind]::Utc }
	if ($Value -isnot [string] -or ([string] $Value).Length -gt 64) { return $false }
	$Parsed = [DateTime]::MinValue
	if (-not [DateTime]::TryParse([string] $Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref] $Parsed)) { return $false }
	return $Parsed.Kind -eq [System.DateTimeKind]::Utc
}
function Assert-AttestedSizeBound([long[]] $Sizes) {
	$Aggregate = [long] 0
	foreach ($Size in $Sizes) {
		if ($Size -lt 0) { throw 'Attested file sizes must be nonnegative JSON integers; host-tools validation fails closed.' }
		if ($Size -gt ([long]::MaxValue - $Aggregate)) { throw 'Attested file sizes overflow the aggregate size bound; host-tools validation fails closed.' }
		$Aggregate += $Size
	}
	if ($Aggregate -gt $script:AttestedAggregateMaxBytes) { throw "Attested files total $Aggregate bytes, above the $($script:AttestedAggregateMaxBytes)-byte aggregate bound; host-tools validation fails closed." }
	foreach ($Size in $Sizes) {
		if ($Size -gt $script:AttestedFileMaxBytes) { throw "An attested file of $Size bytes exceeds the $($script:AttestedFileMaxBytes)-byte per-file bound; host-tools validation fails closed." }
	}
}
function Get-RequiredHostToolRecord([string] $RelativePath) {
	$EngineFull = [System.IO.Path]::GetFullPath($ResolvedEngine)
	$ToolFull = [System.IO.Path]::GetFullPath((Join-Path $ResolvedEngine $RelativePath))
	if (-not (Test-PathIsWithin $ToolFull $EngineFull) -or $ToolFull.Equals($EngineFull, [StringComparison]::OrdinalIgnoreCase)) { throw "Host-tool path '$RelativePath' escapes the engine root; host-tools validation fails closed." }
	if (-not (Test-Path -LiteralPath $ToolFull -PathType Leaf)) { throw "Required host tool '$RelativePath' does not exist under the engine root; host-tools validation fails closed." }
	$Probe = $ToolFull
	while ($Probe -and -not $Probe.Equals($EngineFull, [StringComparison]::OrdinalIgnoreCase)) {
		if ((Get-Item -LiteralPath $Probe -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "Required host tool '$RelativePath' is mediated by a reparse point at '$Probe'; host-tools validation fails closed." }
		$Probe = Split-Path -Parent $Probe
	}
	[ordered]@{
		path = $RelativePath
		sha256 = (Get-FileHash -LiteralPath $ToolFull -Algorithm SHA256).Hash.ToLowerInvariant()
		sizeBytes = [long] (Get-Item -LiteralPath $ToolFull -Force).Length
	}
}
function Test-HostToolsAttestation([string] $AttestationFull) {
	# The attestation is external local state produced only by the explicit
	# operator attestation step after an authorized provisioning/rebuild. It
	# must list exactly the receipt-derived host build-product closure -
	# re-derived fresh here, never trusted from the record - and every file
	# must re-verify by content hash and size against the binaries on disk;
	# Build.version alone never proves provenance.
	if ((Get-Item -LiteralPath $AttestationFull -Force).Length -gt $script:AttestationMaxBytes) { throw "HostToolsAttestationPath '$HostToolsAttestationPath' exceeds the $($script:AttestationMaxBytes)-byte attestation record bound; host-tools validation fails closed." }
	$Raw = Get-Content -LiteralPath $AttestationFull -Raw
	# The raw duplicate scan runs before conversion: Windows PowerShell's
	# ConvertFrom-Json reports case-colliding keys as a generic parse failure,
	# and newer PowerShell keeps one value silently.
	if ([string]::IsNullOrWhiteSpace($Raw)) { throw "HostToolsAttestationPath '$HostToolsAttestationPath' is empty; host-tools validation fails closed." }
	Assert-UniqueAttestationJsonProperty $Raw
	$Record = $null
	try { $Record = $Raw | ConvertFrom-Json } catch { throw "HostToolsAttestationPath '$HostToolsAttestationPath' is not a parseable attestation record; host-tools validation fails closed." }
	if ($null -eq $Record) { throw "HostToolsAttestationPath '$HostToolsAttestationPath' is empty; host-tools validation fails closed." }
	$RecordNames = @($Record.PSObject.Properties | ForEach-Object { $_.Name })
	foreach ($Name in $script:AttestationPropertyNames) {
		if ($RecordNames -cnotcontains $Name) { throw "Attestation record is missing required property '$Name'; host-tools validation fails closed." }
	}
	foreach ($Name in $RecordNames) {
		if ($script:AttestationPropertyNames -cnotcontains $Name) { throw "Attestation record carries unexpected property '$Name'; host-tools validation fails closed." }
	}
	if (-not (Test-AttestationJsonInteger $Record.schemaVersion) -or [long] $Record.schemaVersion -ne 1) { throw "Attestation record schemaVersion must be the JSON integer 1; host-tools validation fails closed." }
	if ($Record.engineGitRevision -isnot [string] -or [string] $Record.engineGitRevision -cne $script:CanonicalEngineRevision) { throw "Attestation record is bound to engine revision '$($Record.engineGitRevision)', not the canonical pinned '$script:CanonicalEngineRevision'; host-tools validation fails closed." }
	if ($Record.provisioningEvidence -isnot [string] -or [string]::IsNullOrWhiteSpace([string] $Record.provisioningEvidence) -or ([string] $Record.provisioningEvidence) -cnotmatch '^[^\x00-\x1f]{1,512}$') { throw 'Attestation record provisioningEvidence must be a nonempty bounded string; host-tools validation fails closed.' }
	if (-not (Test-AttestationTimestamp $Record.createdUtc)) { throw 'Attestation record createdUtc must be a bounded round-trip UTC timestamp; host-tools validation fails closed.' }
	if ($Record.files -isnot [array]) { throw "Attestation record 'files' must be a JSON array; host-tools validation fails closed." }
	$DerivedPaths = Get-HostToolReceiptProductPath
	$Entries = @($Record.files)
	if ($Entries.Count -ne $DerivedPaths.Count) { throw "Attestation record must list exactly the $($DerivedPaths.Count) receipt-derived host build products; found $($Entries.Count) entries. Host-tools validation fails closed." }
	$SeenPaths = @{}
	foreach ($Entry in $Entries) {
		if ($null -eq $Entry -or $Entry -isnot [System.Management.Automation.PSCustomObject]) { throw 'Every attestation file entry must be a JSON object; host-tools validation fails closed.' }
		$EntryNames = @($Entry.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
		if (($EntryNames -join '|') -cne 'path|sha256|sizeBytes') { throw 'Every attestation file entry must carry exactly path, sha256, and sizeBytes; host-tools validation fails closed.' }
		if ($Entry.path -isnot [string] -or $Entry.sha256 -isnot [string]) { throw 'Every attestation file entry must carry string path and sha256 values; host-tools validation fails closed.' }
		$EntryPath = [string] $Entry.path
		Assert-SafeEngineRelativePath 'Attestation file path' $EntryPath
		$NormalizedPath = ($EntryPath -replace '\\', '/').ToLowerInvariant()
		if ($SeenPaths.ContainsKey($NormalizedPath)) { throw "Attestation file path '$EntryPath' duplicates or case-collides with another entry; host-tools validation fails closed." }
		$SeenPaths[$NormalizedPath] = $EntryPath
		if ([string] $Entry.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw "Attestation entry for '$EntryPath' must carry a lowercase 64-character SHA-256; host-tools validation fails closed." }
		if (-not (Test-AttestationJsonInteger $Entry.sizeBytes)) { throw "Attestation entry for '$EntryPath' must carry sizeBytes as a nonnegative JSON integer; host-tools validation fails closed." }
	}
	Assert-AttestedSizeBound @($Entries | ForEach-Object { [long] $_.sizeBytes })
	foreach ($RequiredPath in $DerivedPaths) {
		if (-not $SeenPaths.ContainsKey((($RequiredPath -replace '\\', '/').ToLowerInvariant()))) { throw "Attestation record is missing receipt-derived host build product '$RequiredPath'; host-tools validation fails closed." }
	}
	foreach ($Entry in $Entries) {
		$Actual = Get-RequiredHostToolRecord ([string] $Entry.path)
		if ([long] $Entry.sizeBytes -ne [long] $Actual.sizeBytes) { throw "Host tool '$($Entry.path)' size does not match its attestation record; host-tools validation fails closed." }
		if ([string] $Entry.sha256 -cne [string] $Actual.sha256) { throw "Host tool '$($Entry.path)' content does not match its attested SHA-256; the existing binaries are not the attested host tools. Host-tools validation fails closed." }
	}
}
function Write-HostToolsAttestation {
	param([string] $HostToolsBoundary, [string] $EngineRevision, [string] $ProvisioningEvidence)
	# Explicit operator attestation step: run only after a successful,
	# authorized host-tools provisioning/rebuild, with -ProvisioningEvidence
	# referencing that build's retained evidence. This step builds nothing.
	if (-not [string]::IsNullOrWhiteSpace($HostToolsBoundary)) { throw "Stage 'AttestHostTools' does not accept -HostToolsBoundary." }
	if (-not [string]::IsNullOrWhiteSpace($EngineRevision)) { throw "Stage 'AttestHostTools' does not accept -EngineRevision; the canonical pinned revision is enforced from the engine checkout." }
	if ([string]::IsNullOrWhiteSpace($HostToolsAttestationPath)) { throw "Stage 'AttestHostTools' requires -HostToolsAttestationPath (a local file path outside the repository and engine roots)." }
	if ([string]::IsNullOrWhiteSpace($ProvisioningEvidence)) { throw "Stage 'AttestHostTools' requires -ProvisioningEvidence referencing the retained evidence of the explicit successful provisioning/rebuild that produced the host tools." }
	$AttestationFull = Assert-SafeExternalPath 'HostToolsAttestationPath' $HostToolsAttestationPath
	if (Test-Path -LiteralPath $AttestationFull) { throw "HostToolsAttestationPath '$HostToolsAttestationPath' already exists; an attestation is an explicit new record - remove the old record first." }
	$AttestationParent = Split-Path -Parent $AttestationFull
	if (-not (Test-Path -LiteralPath $AttestationParent -PathType Container)) { throw "HostToolsAttestationPath parent directory '$AttestationParent' does not exist." }
	Assert-CanonicalCleanEngine
	$DerivedPaths = Get-HostToolReceiptProductPath
	$Files = @($DerivedPaths | ForEach-Object { Get-RequiredHostToolRecord $_ })
	Assert-AttestedSizeBound @($Files | ForEach-Object { [long] $_.sizeBytes })
	# Written to a temporary sibling and moved into place: File.Move is atomic
	# on the same volume and throws if the destination exists, so a concurrent
	# writer can never overwrite or interleave an existing attestation.
	$TemporaryPath = '{0}.tmp-{1}' -f $AttestationFull, [guid]::NewGuid().ToString('N')
	[ordered]@{
		schemaVersion = 1
		engineGitRevision = $script:CanonicalEngineRevision
		files = $Files
		provisioningEvidence = $ProvisioningEvidence
		createdUtc = [DateTime]::UtcNow.ToString('o')
	} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $TemporaryPath -Encoding UTF8
	try {
		[System.IO.File]::Move($TemporaryPath, $AttestationFull)
	} catch {
		try { Remove-Item -LiteralPath $TemporaryPath -Force -ErrorAction SilentlyContinue } catch { Write-Verbose "The temporary attestation file could not be removed after the record move failed: $($_.Exception.Message)" }
		throw "HostToolsAttestationPath '$HostToolsAttestationPath' could not be written as a new record; an attestation never overwrites an existing record. $($_.Exception.Message)"
	}
	return [ordered]@{ mode = 'attest'; status = 'written'; engineRevision = $script:CanonicalEngineRevision }
}
function Resolve-HostToolsBoundary {
	param([string] $HostToolsBoundary, [string] $EngineRevision, [string] $ProvisioningEvidence)
	if ($Stage -eq 'Provenance') {
		if (-not [string]::IsNullOrWhiteSpace($HostToolsBoundary) -or -not [string]::IsNullOrWhiteSpace($EngineRevision) -or -not [string]::IsNullOrWhiteSpace($HostToolsAttestationPath)) { throw "Stage 'Provenance' runs no build phase and does not accept host-tools parameters." }
		return [ordered]@{ mode = 'not_applicable'; status = 'no_build_phase'; engineRevision = $null }
	}
	if (-not [string]::IsNullOrWhiteSpace($ProvisioningEvidence)) { throw "-ProvisioningEvidence is only accepted with -Stage AttestHostTools." }
	# There is deliberately no default: a missing selection must never launch
	# an implicit multi-hour host editor/engine rebuild.
	if ([string]::IsNullOrWhiteSpace($HostToolsBoundary)) { throw "host_tools_configuration_required: -HostToolsBoundary must be chosen explicitly - 'Prebuilt' with -EngineRevision and -HostToolsAttestationPath, or 'Rebuild' as an explicit operator-authorized full host-tools rebuild." }
	if ($HostToolsBoundary -ne 'Prebuilt') {
		if (-not [string]::IsNullOrWhiteSpace($EngineRevision) -or -not [string]::IsNullOrWhiteSpace($HostToolsAttestationPath)) { throw '-EngineRevision and -HostToolsAttestationPath are only accepted with -HostToolsBoundary Prebuilt.' }
		return [ordered]@{ mode = 'rebuild'; status = 'authorized_rebuild'; engineRevision = $null }
	}
	# Fail closed on every unproven condition. The prebuilt boundary skips the
	# host editor/engine tool build only when the attested host tools provably
	# belong to the exact clean canonical pinned engine revision; it never
	# falls back to rebuilding them silently.
	$NormalizedRevision = ([string] $EngineRevision).ToLowerInvariant()
	if ($NormalizedRevision -notmatch '^[0-9a-f]{40}$') { throw "HostToolsBoundary 'Prebuilt' requires -EngineRevision with the full 40-character canonical pinned engine commit hash." }
	if ($NormalizedRevision -cne $script:CanonicalEngineRevision) { throw "-EngineRevision '$NormalizedRevision' is not the repository's canonical pinned engine revision '$script:CanonicalEngineRevision'; the prebuilt host-tools boundary fails closed." }
	if ([string]::IsNullOrWhiteSpace($HostToolsAttestationPath)) { throw "HostToolsBoundary 'Prebuilt' requires -HostToolsAttestationPath naming the external host-tools attestation record; produce it with -Stage AttestHostTools after an explicit authorized provisioning build." }
	Assert-CanonicalCleanEngine
	$AttestationFull = Assert-SafeExternalPath 'HostToolsAttestationPath' $HostToolsAttestationPath
	if (-not (Test-Path -LiteralPath $AttestationFull -PathType Leaf)) { throw "HostToolsAttestationPath '$HostToolsAttestationPath' does not exist; produce it with -Stage AttestHostTools after an explicit authorized provisioning build." }
	Test-HostToolsAttestation $AttestationFull
	return [ordered]@{ mode = 'prebuilt'; status = 'verified'; engineRevision = $NormalizedRevision }
}
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
	Resolve-RequiredPath -Name $Label -Path (Join-Path $Root $Relative) -PathType 'Container'
}
# Hashed immediately after each target's own cook so later consumers can reject
# stale, substituted, or cross-target registry bytes against producer evidence.
function Get-CookedRegistryReceipt([string] $Kind) {
	$Identity = if ($Kind -eq 'client') { @{ target = 'AethelnOnlineClient'; platform = 'Win64'; cookPlatform = 'WindowsClient' } } else { @{ target = 'AethelnOnlineServer'; platform = 'Linux'; cookPlatform = 'LinuxServer' } }
	$RelativePath = "Saved/Cooked/$($Identity.cookPlatform)/AethelnOnline/AssetRegistry.bin"
	$RegistryPath = Join-Path $ProjectRoot $RelativePath
	if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) { throw "The $Kind cooked registry '$RegistryPath' is missing after the cook; packaging fails closed." }
	$Registry = Get-Item -LiteralPath $RegistryPath
	if ($Registry.Length -le 0) { throw "The $Kind cooked registry '$RegistryPath' is empty; packaging fails closed." }
	return [ordered]@{
		relativePath = $RelativePath
		sizeBytes = $Registry.Length
		sha256 = (Get-FileHash -LiteralPath $RegistryPath -Algorithm SHA256).Hash.ToLowerInvariant()
		target = $Identity.target
		platform = $Identity.platform
		cookPlatform = $Identity.cookPlatform
		sourceRevision = $SourceRevision
	}
}

# Release build number (issue #226): a Provenance-stage input only, checked before
# any path, repository, or output work so a rejected value leaves nothing behind.
$ProvenanceBuildNumberArguments = @{}
if ($PSBoundParameters.ContainsKey('BuildNumber')) {
	if ($Stage -ne 'Provenance') { throw "build_number_stage_invalid: -BuildNumber is only accepted with -Stage Provenance, not '$Stage'." }
	if ($BuildNumber -cnotmatch '^[1-9][0-9]{0,9}\z') { throw 'build_number_invalid: -BuildNumber must be a positive integer of at most ten digits without a leading zero.' }
	$ProvenanceBuildNumberArguments['BuildNumber'] = $BuildNumber
}
$ResolvedProject = Resolve-RequiredPath -Name 'ProjectPath' -Path $ProjectPath -PathType 'Leaf'
$ProjectRoot = Split-Path -Parent $ResolvedProject
Assert-CleanRepository $ProjectRoot
$ResolvedEngine = Resolve-RequiredPath -Name 'EngineRoot' -Path $EngineRoot -PathType 'Container'
$ResolvedToolchain = Resolve-RequiredPath -Name 'LinuxToolchainRoot' -Path $LinuxToolchainRoot -PathType 'Container'
$script:RunUat = Join-Path $ResolvedEngine 'Engine/Build/BatchFiles/RunUAT.bat'
if (-not (Test-Path -LiteralPath $script:RunUat -PathType Leaf)) { throw "EngineRoot '$ResolvedEngine' does not contain RunUAT.bat at '$script:RunUat'." }
$UnrealEditorCmd = Join-Path $ResolvedEngine 'Engine/Binaries/Win64/UnrealEditor-Cmd.exe'
if (-not (Test-Path -LiteralPath $UnrealEditorCmd -PathType Leaf)) { throw "EngineRoot '$ResolvedEngine' does not contain UnrealEditor-Cmd.exe at '$UnrealEditorCmd'." }
$ResolvedArchive = Initialize-EmptyDirectory 'ArchiveRoot' $ArchiveRoot
$ResolvedLogs = Initialize-EmptyDirectory 'LogRoot' $LogRoot
$script:TimingRecordPath = Join-Path $ResolvedLogs 'build-timing.json'
# Bound here rather than captured implicitly inside the timed-step script
# blocks below, so each helper's dependency on the run's parameters stays
# visible at its call site.
$EvidenceIdentityArguments = @{ RunnerName = $RunnerName }
$HostToolsArguments = @{ HostToolsBoundary = $HostToolsBoundary; EngineRevision = $EngineRevision; ProvisioningEvidence = $ProvisioningEvidence }
$DerivedDataCacheArguments = @{ DerivedDataCachePath = $DerivedDataCachePath; CacheFallback = $CacheFallback }
# From here on a valid LogRoot exists, so every later validation and phase --
# including fail-closed host-tools and cache-identity errors that stop the run
# before any UAT process starts -- still finalizes bounded timing evidence.
try {
	Invoke-TimedStep 'evidence-identity-resolution' { $script:EvidenceIdentity = Resolve-EvidenceIdentity @EvidenceIdentityArguments }
	if ($Stage -eq 'AttestHostTools') {
		Invoke-TimedStep 'host-tools-attestation-write' { $script:HostToolsState = Write-HostToolsAttestation @HostToolsArguments }
		Write-Output "Host-tools attestation for canonical engine revision '$script:CanonicalEngineRevision' written to '$HostToolsAttestationPath'."
		return
	}
	Invoke-TimedStep 'host-tools-boundary' { $script:HostToolsState = Resolve-HostToolsBoundary @HostToolsArguments }
	Invoke-TimedStep 'derived-data-cache-resolution' { $script:CacheState = Resolve-DerivedDataCache @DerivedDataCacheArguments }
	$ResolvedClientStage = $null
	$ResolvedServerStage = $null
	if ($Stage -eq 'Provenance') {
		if ([string]::IsNullOrWhiteSpace($ClientStageRoot) -or [string]::IsNullOrWhiteSpace($ServerStageRoot)) { throw "Stage 'Provenance' requires -ClientStageRoot and -ServerStageRoot." }
		$ResolvedClientStage = Resolve-RequiredPath -Name 'ClientStageRoot' -Path $ClientStageRoot -PathType 'Container'
		$ResolvedServerStage = Resolve-RequiredPath -Name 'ServerStageRoot' -Path $ServerStageRoot -PathType 'Container'
		$ClientArchive = Resolve-RequiredPath -Name 'ClientStageRoot WindowsClient archive' -Path (Join-Path $ResolvedClientStage 'WindowsClient') -PathType 'Container'
		$ServerArchive = Resolve-RequiredPath -Name 'ServerStageRoot LinuxServer archive' -Path (Join-Path $ResolvedServerStage 'LinuxServer') -PathType 'Container'
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
	if ($Stage -ne 'Provenance') { Invoke-TimedStep 'target-composition-gate' { & $TargetGate -ProjectRoot $ProjectRoot } }

	$CommonArguments = @('BuildCookRun', "-project=$ResolvedProject", '-nop4', '-utf8output', '-unattended', '-build', '-cook', '-clean', '-stage', '-pak', '-archive', "-map=$Map")
	if ($script:HostToolsState.mode -eq 'prebuilt') {
		# Pinned UE 5.8.1 maps -nocompileeditor to SkipBuildEditor: UAT omits
		# the host editor/engine targets from BuildProjectCommand while the
		# client and server project targets still build with -clean.
		$CommonArguments += '-nocompileeditor'
	}
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
	$ClientRegistryReceipt = $null
	$ServerRegistryReceipt = $null
	$PreviousToolchain = [Environment]::GetEnvironmentVariable('LINUX_MULTIARCH_ROOT', 'Process')
	$PreviousLocalDdc = [Environment]::GetEnvironmentVariable('UE-LocalDataCachePath', 'Process')
	try {
		[Environment]::SetEnvironmentVariable('LINUX_MULTIARCH_ROOT', $ResolvedToolchain, 'Process')
		if ($null -ne $script:CacheState.appliedPath) { [Environment]::SetEnvironmentVariable('UE-LocalDataCachePath', $script:CacheState.appliedPath, 'Process') }
		if ($Stage -in @('All', 'Client')) {
			Invoke-TimedStep 'client-uat-build-cook-package' { Invoke-UatBuild -Label 'Windows x64 client build/cook/package' -Arguments $ClientArguments -LogPath (Join-Path $ResolvedLogs 'client-uat.log') -AutomationToolLogDirectory $ClientAutomationToolLogs }
			Invoke-TimedStep 'client-output-validation' {
				Assert-PackagedExecutable -Label 'Windows client packaging' -Root $ClientArchive -Names @('AethelnOnlineClient.exe', 'AethelnOnline.exe')
				$script:SelectedCompiler = Resolve-UbtSelectedTool -LogDirectory $ClientAutomationToolLogs -Label 'Compiler' -ExecutableName 'cl.exe'
				$script:SelectedResourceCompiler = Resolve-UbtSelectedTool -LogDirectory $ClientAutomationToolLogs -Label 'Resource Compiler' -ExecutableName 'rc.exe'
				$script:ClientRegistryReceipt = Get-CookedRegistryReceipt 'client'
			}
		}
		if ($Stage -in @('All', 'Server')) {
			Invoke-TimedStep 'server-uat-build-cook-package' { Invoke-UatBuild -Label 'Linux x86-64 dedicated server build/cook/package' -Arguments $ServerArguments -LogPath (Join-Path $ResolvedLogs 'server-uat.log') -AutomationToolLogDirectory $ServerAutomationToolLogs }
			Invoke-TimedStep 'server-output-validation' {
				Assert-PackagedExecutable -Label 'Linux server packaging' -Root $ServerArchive -Names @('AethelnOnlineServer', 'AethelnOnlineServer-Linux-Shipping')
				$script:ServerRegistryReceipt = Get-CookedRegistryReceipt 'server'
			}
			Invoke-TimedStep 'server-dependency-registry-dump' { Invoke-LoggedCommand -Label 'dedicated-server dependency registry dump' -Executable $UnrealEditorCmd -Arguments $DependencyRegistryArguments -LogPath (Join-Path $ResolvedLogs 'server-dependency-registry-dump.log') }
			Invoke-TimedStep 'server-cooked-inventory-dump' { Invoke-LoggedCommand -Label 'dedicated-server cooked inventory dump' -Executable $UnrealEditorCmd -Arguments $CookedInventoryArguments -LogPath (Join-Path $ResolvedLogs 'server-cooked-inventory-dump.log') }
			if ($Stage -eq 'All') { Invoke-TimedStep 'server-cook-reference-gate' { & $CookGate -DependencyReportDirectory $DependencyRegistryDump -CookedInventoryDirectory $CookedInventoryDump } }
		}
	} finally {
		[Environment]::SetEnvironmentVariable('LINUX_MULTIARCH_ROOT', $PreviousToolchain, 'Process')
		[Environment]::SetEnvironmentVariable('UE-LocalDataCachePath', $PreviousLocalDdc, 'Process')
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
				cookedRegistry = $ClientRegistryReceipt
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
				cookedRegistry = $ServerRegistryReceipt
			} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ResolvedArchive 'phase-server.json') -Encoding UTF8
			Write-Output "Server packaging stage completed under '$ResolvedArchive'."
		}
		'Provenance' {
			$ClientRecord = Read-StageRecord $ResolvedClientStage 'Client'
			$ServerRecord = Read-StageRecord $ResolvedServerStage 'Server'
			foreach ($Property in @('clientArguments', 'compilerPath', 'resourceCompilerPath', 'cookedRegistry')) {
				if ($null -eq $ClientRecord.PSObject.Properties[$Property]) { throw "Client stage record is missing required property '$Property'." }
			}
			foreach ($Property in @('serverArguments', 'dependencyRegistryDumpArguments', 'cookedInventoryDumpArguments', 'dependencyReportDirectory', 'cookedInventoryDirectory', 'cookedRegistry')) {
				if ($null -eq $ServerRecord.PSObject.Properties[$Property]) { throw "Server stage record is missing required property '$Property'." }
			}
			$DependencyReportDirectory = Resolve-RecordDirectory -Root $ResolvedServerStage -Relative ([string] $ServerRecord.dependencyReportDirectory) -Label 'Dependency report directory'
			$CookedInventoryDirectory = Resolve-RecordDirectory -Root $ResolvedServerStage -Relative ([string] $ServerRecord.cookedInventoryDirectory) -Label 'Cooked inventory directory'
			Invoke-TimedStep 'server-cook-reference-gate' { & $CookGate -DependencyReportDirectory $DependencyReportDirectory -CookedInventoryDirectory $CookedInventoryDirectory }
			$UatArgumentsJson = [ordered]@{ client = @($ClientRecord.clientArguments); server = @($ServerRecord.serverArguments); dependencyRegistryDump = @($ServerRecord.dependencyRegistryDumpArguments); cookedInventoryDump = @($ServerRecord.cookedInventoryDumpArguments) } | ConvertTo-Json -Compress
			$CookedRegistryReceiptsJson = [ordered]@{ client = $ClientRecord.cookedRegistry; server = $ServerRecord.cookedRegistry } | ConvertTo-Json -Depth 4 -Compress
			Invoke-TimedStep 'provenance-write' { & (Join-Path $PSScriptRoot 'Write-BuildProvenance.ps1') -OutputPath (Join-Path $ResolvedArchive 'build-provenance.json') -ProjectPath $ResolvedProject -EngineRoot $ResolvedEngine -LinuxToolchainRoot $ResolvedToolchain -SourceRevision $SourceRevision -BuildConfiguration $Configuration -ClientArchivePath $ClientArchive -ServerArchivePath $ServerArchive -CompilerPath ([string] $ClientRecord.compilerPath) -ResourceCompilerPath ([string] $ClientRecord.resourceCompilerPath) -UatArgumentsJson $UatArgumentsJson -CookedRegistryReceiptsJson $CookedRegistryReceiptsJson @ProvenanceBuildNumberArguments }
			Write-Output "Provenance validation stage completed under '$ResolvedArchive'."
		}
		default {
			$UatArgumentsJson = [ordered]@{ client = $ClientArguments; server = $ServerArguments; dependencyRegistryDump = $DependencyRegistryArguments; cookedInventoryDump = $CookedInventoryArguments } | ConvertTo-Json -Compress
			$CookedRegistryReceiptsJson = [ordered]@{ client = $ClientRegistryReceipt; server = $ServerRegistryReceipt } | ConvertTo-Json -Depth 4 -Compress
			Invoke-TimedStep 'provenance-write' { & (Join-Path $PSScriptRoot 'Write-BuildProvenance.ps1') -OutputPath (Join-Path $ResolvedArchive 'build-provenance.json') -ProjectPath $ResolvedProject -EngineRoot $ResolvedEngine -LinuxToolchainRoot $ResolvedToolchain -SourceRevision $SourceRevision -BuildConfiguration $Configuration -ClientArchivePath $ClientArchive -ServerArchivePath $ServerArchive -CompilerPath $SelectedCompiler -ResourceCompilerPath $SelectedResourceCompiler -UatArgumentsJson $UatArgumentsJson -CookedRegistryReceiptsJson $CookedRegistryReceiptsJson }
			Write-Output "Packaged artifacts completed under '$ResolvedArchive'."
		}
	}
} finally {
	Write-BuildTimingRecord
}
