<#
.SYNOPSIS
Runs engine-dependent compile, packaged-smoke, or scheduled milestone phase gates on an approved runner.
.DESCRIPTION
Compile and PackagedSmoke preserve the original single-job gates. The phase
modes (PackageClient, PackageServer, ValidateProvenance, SmokePhase) split the
scheduled clean-package milestone into bounded jobs that exchange outputs only
through the durable run-scoped handoff store under AETHELN_HANDOFF_ROOT, with
fail-closed integrity manifests. Handoff directories are never deleted here;
eligible directories are only listed in cleanup-request records for external
operational cleanup.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)] [ValidateSet('Compile', 'PackagedSmoke', 'PackageClient', 'PackageServer', 'ValidateProvenance', 'SmokePhase')] [string] $Mode,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RepositoryRoot,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SourceRevision,
	[string] $ArchiveRoot,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $LogRoot,
	[string] $Repository,
	[string] $RunId,
	[string] $RunAttempt,
	[string] $RunnerName,
	[double] $PhaseTimeoutMinutes = 0,
	[long] $HandoffPayloadCapBytes = 68719476736,
	[long] $HandoffRootCapBytes = 274877906944,
	[double] $HandoffStaleHours = 48
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Started = [DateTime]::UtcNow
$Checks = New-Object System.Collections.ArrayList
$RequiredFailed = $false
$FailureCode = $null
$ResolvedRepository = $null
$PhaseByMode = @{ PackageClient = 'client'; PackageServer = 'server'; ValidateProvenance = 'provenance'; SmokePhase = 'smoke' }
$IsPhaseMode = $PhaseByMode.ContainsKey($Mode)
$Policy = if ($Mode -eq 'Compile') { 'incremental-target-compilation' } else { 'clean-package-and-smoke' }

function Test-IsWithin([string] $Candidate, [string] $Parent) {
	$CandidatePath = [System.IO.Path]::GetFullPath($Candidate).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
	$ParentPath = [System.IO.Path]::GetFullPath($Parent).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
	return $CandidatePath.Equals($ParentPath, [StringComparison]::OrdinalIgnoreCase) -or $CandidatePath.StartsWith($ParentPath + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-RequiredDirectory([string] $Value, [string] $ReasonCode) {
	if ([string]::IsNullOrWhiteSpace($Value) -or -not (Test-Path -LiteralPath $Value -PathType Container)) { throw $ReasonCode }
	return (Resolve-Path -LiteralPath $Value).Path
}

function Resolve-OutputRoot([string] $Value, [string] $Repository, [string] $ReasonCode) {
	if ([string]::IsNullOrWhiteSpace($Value)) { throw $ReasonCode }
	$FullPath = [System.IO.Path]::GetFullPath($Value)
	if (Test-IsWithin $FullPath $Repository) { throw $ReasonCode }
	if (Test-Path -LiteralPath $FullPath) {
		if (-not (Test-Path -LiteralPath $FullPath -PathType Container)) { throw $ReasonCode }
		if (@(Get-ChildItem -LiteralPath $FullPath -Force).Count -ne 0) { throw $ReasonCode }
	}
	return $FullPath
}

function Add-Check([string] $Name, [string] $Status, [datetime] $CheckStarted, [string] $Command, [string] $Message) {
	[void] $Checks.Add([ordered]@{
		name = $Name
		tier = 'required'
		status = $Status
		durationSeconds = [Math]::Round(([DateTime]::UtcNow - $CheckStarted).TotalSeconds, 3)
		command = $Command
		message = $Message
	})
}

function Get-SafeDiagnosticMessage([string] $Reason, [System.Collections.IEnumerable] $Output, [string[]] $ProtectedValues) {
	$Redactions = @($ProtectedValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object Length -Descending -Unique)
	$Lines = New-Object System.Collections.ArrayList
	$EnvironmentTable = $false
	foreach ($Record in @($Output)) {
		$Line = [string] $Record
		foreach ($ProtectedValue in $Redactions) {
			$Line = [regex]::Replace($Line, [regex]::Escape($ProtectedValue), '<redacted-path>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
		}
		$Trimmed = $Line.TrimStart()
		if ([string]::IsNullOrWhiteSpace($Trimmed)) {
			$EnvironmentTable = $false
			continue
		}
		if ($Trimmed -match '(?i)\b(authorization|password|passwd|secret|token|bearer|api[_ -]?key|private[_ -]?key|access[_ -]?key|connection[_ -]?string|client[_ -]?secret|session[_ -]?token)\b(?:\s|:|=)') {
			$Line = 'credential_like_diagnostic_redacted'
		} elseif ($Trimmed -match '^[A-Za-z_][A-Za-z0-9_]*\s*=') {
			$Line = 'environment_assignment_redacted'
		} elseif ($Trimmed -match '^Name\s+Value$' -or $Trimmed -match '^-+\s+-+$') {
			$EnvironmentTable = $true
			$Line = 'environment_table_redacted'
		} elseif ($EnvironmentTable -and $Trimmed -match '^[A-Za-z_][A-Za-z0-9_]*\s+\S') {
			$Line = 'environment_table_redacted'
		}
		if ($Line -notmatch '(?i)\b(error|fatal|warning|failed|failure|timeout|exception)\b|\b[A-Z]{1,6}\d{3,5}\b') { continue }
		$Line = [regex]::Replace($Line, '\bAKIA[0-9A-Z]{16}\b', '<redacted-token>')
		$Line = [regex]::Replace($Line, '\bgh[pousr]_[A-Za-z0-9_]{20,}\b', '<redacted-token>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
		$Line = [regex]::Replace($Line, '\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]{10,})?\b', '<redacted-token>')
		$Line = [regex]::Replace($Line, '\b[A-Za-z0-9+/_=-]{32,}\b', '<redacted-token>')
		if (-not [string]::IsNullOrWhiteSpace($Line)) { [void] $Lines.Add($Line) }
	}
	$Diagnostic = (@($Lines | Select-Object -Last 20) -join "`n")
	if ($Diagnostic.Length -gt 4096) { $Diagnostic = $Diagnostic.Substring($Diagnostic.Length - 4096) }
	if ([string]::IsNullOrWhiteSpace($Diagnostic)) { return $Reason }
	return $Reason + "`n" + $Diagnostic
}

function Invoke-Captured([string] $Executable, [string[]] $Arguments) {
	$PreviousErrorActionPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = 'Continue'
		$Output = @(& $Executable @Arguments 2>&1)
		$ExitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $PreviousErrorActionPreference
	}
	return [ordered]@{ output = $Output; exitCode = $ExitCode }
}

function Assert-RepositoryState([string] $Name) {
	$CheckStarted = [DateTime]::UtcNow
	try {
		$HeadResult = Invoke-Captured 'git' @('-C', $ResolvedRepository, 'rev-parse', 'HEAD')
		if ($HeadResult.exitCode -ne 0) { throw 'revision_query_failed' }
		$HeadLines = @($HeadResult.output | ForEach-Object { ([string] $_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
		if ($HeadLines.Count -ne 1 -or $HeadLines[0] -notmatch '^[0-9a-fA-F]{40}$') { throw 'revision_invalid' }
		if (-not $HeadLines[0].Equals($SourceRevision, [StringComparison]::OrdinalIgnoreCase)) { throw 'revision_changed' }

		$StatusResult = Invoke-Captured 'git' @('-C', $ResolvedRepository, 'status', '--porcelain', '--untracked-files=all')
		if ($StatusResult.exitCode -ne 0) { throw 'repository_status_failed' }
		$Changes = @($StatusResult.output | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) })
		if ($Changes.Count -ne 0) { throw 'repository_drift_detected' }
		Add-Check $Name 'passed' $CheckStarted 'git-revision-and-status' 'repository_state_valid'
	} catch {
		$Reason = [string] $_.Exception.Message
		if ($Reason -notmatch '^[a-z0-9_]+$') { $Reason = 'repository_state_invalid' }
		Add-Check $Name 'failed' $CheckStarted 'git-revision-and-status' $Reason
		throw $Reason
	}
}

function Complete-CommandStateCheck([string] $Name, [string] $CommandFailure) {
	$RepositoryFailure = $null
	try {
		Assert-RepositoryState $Name
	} catch {
		$RepositoryFailure = [string] $_.Exception.Message
	}
	if (-not [string]::IsNullOrWhiteSpace($CommandFailure)) { throw $CommandFailure }
	if (-not [string]::IsNullOrWhiteSpace($RepositoryFailure)) { throw $RepositoryFailure }
}

function Write-RunnerReport {
	if ([string]::IsNullOrWhiteSpace($ResolvedRepository)) { return }
	$ResultRoot = Join-Path $ResolvedRepository 'TestResults'
	if (-not (Test-Path -LiteralPath $ResultRoot)) { New-Item -ItemType Directory -Path $ResultRoot | Out-Null }
	$Passed = @($Checks | Where-Object { $_.status -eq 'passed' }).Count
	$Failed = @($Checks | Where-Object { $_.status -eq 'failed' }).Count
	$Skipped = @($Checks | Where-Object { $_.status -eq 'skipped' }).Count
	$Report = [ordered]@{
		schemaVersion = 1
		mode = $Mode
		policy = $Policy
		revision = $SourceRevision
		startedUtc = $Started.ToString('o')
		finishedUtc = [DateTime]::UtcNow.ToString('o')
		checks = @($Checks)
		summary = [ordered]@{
			total = $Checks.Count
			passed = $Passed
			failed = $Failed
			skipped = $Skipped
			requiredFailed = $Failed
		}
	}
	$Report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $ResultRoot 'engine-runner-report.json') -Encoding UTF8
}

function Test-IsReparsePoint([string] $Path) {
	$Item = Get-Item -LiteralPath $Path -Force
	return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-NoReparseTree([string] $Root, [string] $ReasonCode) {
	if (Test-IsReparsePoint $Root) { throw $ReasonCode }
	foreach ($Item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force)) {
		if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw $ReasonCode }
	}
}

function Assert-PhaseContext {
	if ($Repository -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$') { throw 'handoff_context_invalid' }
	foreach ($Component in ($Repository -split '/')) {
		if ($Component -in @('.', '..')) { throw 'handoff_context_invalid' }
	}
	if ($RunId -notmatch '^[0-9]{1,19}$') { throw 'handoff_context_invalid' }
	if ($RunAttempt -notmatch '^[0-9]{1,6}$') { throw 'handoff_context_invalid' }
	if ($RunnerName -notmatch '^[^\\/:*?"<>|\x00-\x1f]{1,128}$') { throw 'handoff_context_invalid' }
	if ($Mode -ne 'SmokePhase' -and ($PhaseTimeoutMinutes -le 0 -or $PhaseTimeoutMinutes -gt 1440)) { throw 'handoff_context_invalid' }
}

function Resolve-HandoffRoot([string[]] $ForbiddenRoots) {
	$Value = [Environment]::GetEnvironmentVariable('AETHELN_HANDOFF_ROOT', 'Process')
	if ([string]::IsNullOrWhiteSpace($Value)) { throw 'handoff_root_unset' }
	if (-not [System.IO.Path]::IsPathRooted($Value)) { throw 'handoff_root_invalid' }
	if (-not (Test-Path -LiteralPath $Value -PathType Container)) { throw 'handoff_root_invalid' }
	$Full = (Resolve-Path -LiteralPath $Value).Path
	if (Test-IsReparsePoint $Full) { throw 'handoff_root_invalid' }
	foreach ($Forbidden in @($ForbiddenRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
		if (-not (Test-Path -LiteralPath $Forbidden)) { continue }
		$ForbiddenFull = [System.IO.Path]::GetFullPath($Forbidden)
		if ((Test-IsWithin $Full $ForbiddenFull) -or (Test-IsWithin $ForbiddenFull $Full)) { throw 'handoff_root_invalid' }
	}
	return $Full
}

function Get-HandoffChildPath([string] $Parent, [string] $Child, [string] $ReasonCode) {
	$Combined = [System.IO.Path]::GetFullPath((Join-Path $Parent $Child))
	if (-not (Test-IsWithin $Combined $Parent) -or $Combined.Equals([System.IO.Path]::GetFullPath($Parent), [StringComparison]::OrdinalIgnoreCase)) { throw $ReasonCode }
	return $Combined
}

function Get-DirectoryBytes([string] $Root) {
	$Total = [long] 0
	foreach ($File in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File)) { $Total += $File.Length }
	return $Total
}

function Write-JsonAtomic([object] $Value, [string] $Destination) {
	$Temporary = $Destination + '.tmp'
	$Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Temporary -Encoding UTF8
	Move-Item -LiteralPath $Temporary -Destination $Destination
}

function Write-CleanupRequest([string] $ScopeRoot, [string] $RequestingPhase) {
	$Entries = New-Object System.Collections.ArrayList
	$RunDirectories = @(Get-ChildItem -LiteralPath $ScopeRoot -Directory -Force | Where-Object { $_.Name -like 'run-*' } | Sort-Object Name | Select-Object -First 100)
	foreach ($Directory in $RunDirectories) {
		$AgeHours = [Math]::Round(([DateTime]::UtcNow - $Directory.CreationTimeUtc).TotalHours, 2)
		$State = 'active'
		$Eligible = $false
		$MeasuredBytes = [long] 0
		$ManifestDigests = @()
		try {
			if ($Directory.Name -notmatch '^run-[0-9]{1,19}-attempt-[0-9]{1,6}$') { throw 'invalid' }
			if (Test-IsReparsePoint $Directory.FullName) { throw 'invalid' }
			$MeasuredBytes = Get-DirectoryBytes $Directory.FullName
			$ManifestDigests = @(Get-ChildItem -LiteralPath $Directory.FullName -Force -File -Filter 'manifest-*.json' | Sort-Object Name | ForEach-Object {
				[ordered]@{ name = $_.Name; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
			})
			if (Test-Path -LiteralPath (Join-Path $Directory.FullName 'milestone-complete.json') -PathType Leaf) {
				$State = 'completed'
				$Eligible = $true
			} elseif ($AgeHours -gt $HandoffStaleHours) {
				$State = 'abandoned'
				$Eligible = $true
			}
		} catch {
			$State = 'invalid'
			$Eligible = $false
		}
		[void] $Entries.Add([ordered]@{
			directory = $Directory.FullName
			runDirectoryName = $Directory.Name
			state = $State
			ageHours = $AgeHours
			measuredBytes = $MeasuredBytes
			manifestDigests = $ManifestDigests
			cleanupEligible = $Eligible
		})
	}
	$RequestRoot = Join-Path $ScopeRoot 'cleanup-requests'
	if (-not (Test-Path -LiteralPath $RequestRoot)) { New-Item -ItemType Directory -Path $RequestRoot | Out-Null }
	$RequestName = 'request-{0}-run-{1}-attempt-{2}-{3}.json' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')), $RunId, $RunAttempt, $RequestingPhase
	$Request = [ordered]@{
		schemaVersion = 1
		requestedUtc = [DateTime]::UtcNow.ToString('o')
		requestingRunId = $RunId
		requestingRunAttempt = $RunAttempt
		requestingPhase = $RequestingPhase
		staleThresholdHours = $HandoffStaleHours
		note = 'External operational action only. No automated deletion is performed by CI.'
		directories = @($Entries)
	}
	Write-JsonAtomic $Request (Join-Path $RequestRoot $RequestName)
}

function Get-HandoffRelativeFiles([string] $PhaseDirectory) {
	Assert-NoReparseTree $PhaseDirectory 'handoff_payload_invalid'
	$Prefix = [System.IO.Path]::GetFullPath($PhaseDirectory).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
	return @(Get-ChildItem -LiteralPath $PhaseDirectory -Recurse -Force -File | Sort-Object FullName | ForEach-Object {
		[ordered]@{
			path = ($_.FullName.Substring($Prefix.Length) -replace '\\', '/')
			bytes = [long] $_.Length
			sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
		}
	})
}

function Write-HandoffManifest([string] $RunDirectory, [string] $Phase, [string[]] $Consumers) {
	$PhaseDirectory = Get-HandoffChildPath $RunDirectory $Phase 'handoff_payload_invalid'
	$Files = @(Get-HandoffRelativeFiles $PhaseDirectory)
	if ($Files.Count -lt 1) { throw 'handoff_payload_invalid' }
	$TotalBytes = [long] 0
	foreach ($File in $Files) { $TotalBytes += $File.bytes }
	$CommittedBytes = [long] 0
	foreach ($Existing in @(Get-ChildItem -LiteralPath $RunDirectory -Force -File -Filter 'manifest-*.json')) {
		$Parsed = Get-Content -LiteralPath $Existing.FullName -Raw | ConvertFrom-Json
		$CommittedBytes += [long] $Parsed.totalBytes
	}
	if (($CommittedBytes + $TotalBytes) -gt $HandoffPayloadCapBytes) { throw 'handoff_size_exceeded' }
	$Manifest = [ordered]@{
		schemaVersion = 1
		repository = $Repository
		sourceRevision = $SourceRevision
		runId = $RunId
		runAttempt = $RunAttempt
		producingPhase = $Phase
		expectedConsumingPhases = @($Consumers)
		runnerName = $RunnerName
		files = @($Files)
		totalBytes = $TotalBytes
		createdUtc = [DateTime]::UtcNow.ToString('o')
	}
	Write-JsonAtomic $Manifest (Join-Path $RunDirectory ('manifest-{0}.json' -f $Phase))
}

function Test-HandoffManifest([string] $RunDirectory, [string] $Phase, [string] $ConsumingPhase) {
	$ManifestPath = Join-Path $RunDirectory ('manifest-{0}.json' -f $Phase)
	if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw 'handoff_missing' }
	try {
		$Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
	} catch {
		throw 'handoff_schema_invalid'
	}
	foreach ($Property in @('schemaVersion', 'repository', 'sourceRevision', 'runId', 'runAttempt', 'producingPhase', 'expectedConsumingPhases', 'runnerName', 'files', 'totalBytes', 'createdUtc')) {
		if ($null -eq $Manifest.PSObject.Properties[$Property]) { throw 'handoff_schema_invalid' }
	}
	if ([int] $Manifest.schemaVersion -ne 1) { throw 'handoff_schema_invalid' }
	if ([string] $Manifest.repository -cne $Repository) { throw 'handoff_context_mismatch' }
	if (-not ([string] $Manifest.sourceRevision).Equals($SourceRevision, [StringComparison]::OrdinalIgnoreCase)) { throw 'handoff_context_mismatch' }
	if ([string] $Manifest.runId -ne $RunId -or [string] $Manifest.runAttempt -ne $RunAttempt) { throw 'handoff_context_mismatch' }
	if ([string] $Manifest.producingPhase -ne $Phase) { throw 'handoff_context_mismatch' }
	if (@($Manifest.expectedConsumingPhases) -notcontains $ConsumingPhase) { throw 'handoff_context_mismatch' }
	if ([string] $Manifest.runnerName -cne $RunnerName) { throw 'handoff_runner_mismatch' }
	$PhaseDirectory = Get-HandoffChildPath $RunDirectory $Phase 'handoff_missing'
	if (-not (Test-Path -LiteralPath $PhaseDirectory -PathType Container)) { throw 'handoff_missing' }
	$ActualFiles = @(Get-HandoffRelativeFiles $PhaseDirectory)
	$ManifestFiles = @($Manifest.files)
	if ($ActualFiles.Count -ne $ManifestFiles.Count) { throw 'handoff_digest_mismatch' }
	$ActualByPath = @{}
	foreach ($File in $ActualFiles) { $ActualByPath[[string] $File.path] = $File }
	$ExpectedTotal = [long] 0
	foreach ($Entry in $ManifestFiles) {
		$EntryPath = [string] $Entry.path
		if ([string]::IsNullOrWhiteSpace($EntryPath) -or $EntryPath -match '^([A-Za-z]:|[\\/])' -or $EntryPath -match '(^|/)\.\.(/|$)' -or $EntryPath.Contains(':')) { throw 'handoff_schema_invalid' }
		if (-not $ActualByPath.ContainsKey($EntryPath)) { throw 'handoff_digest_mismatch' }
		$Actual = $ActualByPath[$EntryPath]
		if ([long] $Actual.bytes -ne [long] $Entry.bytes) { throw 'handoff_digest_mismatch' }
		if (-not ([string] $Actual.sha256).Equals([string] $Entry.sha256, [StringComparison]::OrdinalIgnoreCase)) { throw 'handoff_digest_mismatch' }
		$ExpectedTotal += [long] $Entry.bytes
	}
	if ($ExpectedTotal -ne [long] $Manifest.totalBytes) { throw 'handoff_schema_invalid' }
	return $PhaseDirectory
}

function Invoke-SmokeGateWork([string] $SearchRoot) {
	$SmokeStarted = [DateTime]::UtcNow
	$SmokeOutput = New-Object System.Collections.ArrayList
	$SmokeProtectedValues = @($ProtectedValues)
	$SmokeFailure = $null
	try {
		$ClientCandidates = @(Get-ChildItem -LiteralPath $SearchRoot -Recurse -File | Where-Object {
			$_.Name -in @('AethelnOnlineClient.exe', 'AethelnOnline.exe')
		})
		$Clients = @($ClientCandidates | Where-Object {
			if ($_.Name -notin @('AethelnOnlineClient.exe', 'AethelnOnline.exe')) { return $false }
			$RelativePath = $_.FullName.Substring($SearchRoot.Length)
			return -not (@($RelativePath -split '[\\/]' | Where-Object { $_ -eq 'Binaries' }).Count)
		})
		if ($Clients.Count -ne 1) { throw 'client_discovery_invalid' }
		$InternalClients = @($ClientCandidates | Where-Object {
			$RelativePath = $_.FullName.Substring($SearchRoot.Length)
			$HasBinariesSegment = @($RelativePath -split '[\\/]' | Where-Object { $_ -eq 'Binaries' }).Count -gt 0
			$HasBinariesSegment -and $_.Name -eq $Clients[0].Name
		})
		if ($InternalClients.Count -lt 1) { throw 'client_discovery_invalid' }
		$Servers = @(Get-ChildItem -LiteralPath $SearchRoot -Recurse -File | Where-Object { $_.Name -eq 'AethelnOnlineServer.sh' })
		if ($Servers.Count -ne 1) { throw 'server_discovery_invalid' }

		$WslPathResult = Invoke-Captured 'wsl.exe' @('-d', 'Ubuntu', '-u', 'aethelnqa', '--', 'wslpath', $Servers[0].FullName)
		if ($WslPathResult.exitCode -ne 0) { throw 'wslpath_exit_nonzero' }
		$TranslatedLines = @($WslPathResult.output | ForEach-Object { [string] $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
		if ($TranslatedLines.Count -ne 1) { throw 'wslpath_line_count_invalid' }
		$LinuxServer = $TranslatedLines[0].Trim()
		if ([string]::IsNullOrWhiteSpace($LinuxServer) -or -not $LinuxServer.StartsWith('/')) { throw 'wslpath_result_invalid' }
		$SmokeProtectedValues += @($Clients[0].FullName, $Servers[0].FullName, $LinuxServer)

		$AddressResult = Invoke-Captured 'wsl.exe' @('-d', 'Ubuntu', '-u', 'aethelnqa', '--', 'hostname', '-I')
		if ($AddressResult.exitCode -ne 0) { throw 'wsl_address_exit_nonzero' }
		$AddressCandidates = @((($AddressResult.output -join ' ').Trim() -split '\s+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
		$UsableAddresses = @($AddressCandidates | Where-Object {
			$ParsedAddress = $null
			[System.Net.IPAddress]::TryParse($_, [ref] $ParsedAddress) -and $ParsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
		})
		if ($UsableAddresses.Count -lt 1) { throw 'wsl_address_invalid' }
		$ServerEndpoint = '{0}:7777' -f $UsableAddresses[0]
		$SmokeLogRoot = Join-Path $ResolvedLogs 'packaged-smoke'
		$SmokeProtectedValues += @($ServerEndpoint, $SmokeLogRoot)

		& $SmokeScript `
			-ServerExecutable $LinuxServer `
			-ServerLauncherExecutable 'wsl.exe' `
			-ServerLauncherArguments @('-d', 'Ubuntu', '-u', 'aethelnqa', '--exec', '{ServerExecutable}', '{ServerMap}', '-port=7777', '-stdout', '-FullStdOutLogOutput') `
			-ClientExecutable $Clients[0].FullName `
			-ClientBaseArguments @('{ServerEndpoint}', '-stdout', '-FullStdOutLogOutput') `
			-ServerEndpoint $ServerEndpoint `
			-ServerMap '/Game/Maps/StarterMap' `
			-LogRoot $SmokeLogRoot `
			-ServerReadyPattern 'GameNetDriver.*Listening' `
			-ServerClientConnectedPattern 'AddClientConnection:.*RemoteAddr: (?<ConnectionId>[^,]+)' `
			-ClientConnectedPattern 'Welcomed by server' `
			-ClientMapPattern 'LoadMap:.*StarterMap' `
			-TimeoutSeconds 120 *>&1 | ForEach-Object { [void] $SmokeOutput.Add($_) }
		Add-Check 'packaged-build-smoke' 'passed' $SmokeStarted 'Invoke-PackagedSmokeTest.ps1' 'smoke_passed'
	} catch {
		[void] $SmokeOutput.Add($_)
		$SafeReason = [string] $_.Exception.Message
		if ($SafeReason -notmatch '^[a-z0-9_]+$') { $SafeReason = 'smoke_failed' }
		$SmokeMessage = Get-SafeDiagnosticMessage $SafeReason $SmokeOutput $SmokeProtectedValues
		Add-Check 'packaged-build-smoke' 'failed' $SmokeStarted 'Invoke-PackagedSmokeTest.ps1' $SmokeMessage
		$SmokeFailure = $SafeReason
	}
	return $SmokeFailure
}

function Invoke-HandoffPublish([string] $PublishRunDirectory, [string] $Phase, [string[]] $Consumers) {
	$CheckStarted = [DateTime]::UtcNow
	try {
		Write-HandoffManifest $PublishRunDirectory $Phase $Consumers
		Add-Check ('handoff-publish-{0}' -f $Phase) 'passed' $CheckStarted 'write-handoff-manifest' 'handoff_published'
	} catch {
		$Reason = [string] $_.Exception.Message
		if ($Reason -notmatch '^[a-z0-9_]+$') { $Reason = 'handoff_payload_invalid' }
		Add-Check ('handoff-publish-{0}' -f $Phase) 'failed' $CheckStarted 'write-handoff-manifest' $Reason
		throw $Reason
	}
}

function Invoke-HandoffConsume([string] $ConsumeRunDirectory, [string] $Phase, [string] $ConsumingPhase) {
	$CheckStarted = [DateTime]::UtcNow
	try {
		$PhaseDirectory = Test-HandoffManifest $ConsumeRunDirectory $Phase $ConsumingPhase
		Add-Check ('handoff-consume-{0}' -f $Phase) 'passed' $CheckStarted 'verify-handoff-manifest' 'handoff_verified'
		return $PhaseDirectory
	} catch {
		$Reason = [string] $_.Exception.Message
		if ($Reason -notmatch '^[a-z0-9_]+$') { $Reason = 'handoff_schema_invalid' }
		Add-Check ('handoff-consume-{0}' -f $Phase) 'failed' $CheckStarted 'verify-handoff-manifest' $Reason
		throw $Reason
	}
}

function Invoke-PhaseChildScript([string] $ScriptPath, [string[]] $ScriptArguments, [double] $TimeoutMinutes) {
	$QuotedArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $ScriptPath)) + @($ScriptArguments | ForEach-Object { '"{0}"' -f ($_ -replace '"', '\"') })
	$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
	$StartInfo.Arguments = $QuotedArguments -join ' '
	$StartInfo.WorkingDirectory = $ResolvedRepository
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true
	$Process = [System.Diagnostics.Process]::new()
	$Process.StartInfo = $StartInfo
	try {
		if (-not $Process.Start()) { throw 'phase_start_failed' }
		$StandardOutput = $Process.StandardOutput.ReadToEndAsync()
		$StandardError = $Process.StandardError.ReadToEndAsync()
		if (-not $Process.WaitForExit([int][Math]::Ceiling($TimeoutMinutes * 60000))) {
			& taskkill /PID $Process.Id /T /F 2>&1 | Out-Null
			[void] $Process.WaitForExit(30000)
			return [ordered]@{ timedOut = $true; exitCode = -1; output = @() }
		}
		$Output = @(
			@($StandardOutput.GetAwaiter().GetResult() -split "`r?`n")
			@($StandardError.GetAwaiter().GetResult() -split "`r?`n")
		) | Where-Object { -not [string]::IsNullOrEmpty($_) }
		return [ordered]@{ timedOut = $false; exitCode = $Process.ExitCode; output = @($Output) }
	} finally {
		$Process.Dispose()
	}
}

try {
	$ResolvedRepository = Resolve-RequiredDirectory $RepositoryRoot 'repository_root_invalid'
	$ValidationStarted = [DateTime]::UtcNow
	try {
		$ProjectPath = Join-Path $ResolvedRepository 'AethelnOnline.uproject'
		$BuildScript = Join-Path $ResolvedRepository 'scripts/build/Build-PackagedArtifacts.ps1'
		$SmokeScript = Join-Path $ResolvedRepository 'scripts/build/Invoke-PackagedSmokeTest.ps1'
		if (-not (Test-Path -LiteralPath $ProjectPath -PathType Leaf)) { throw 'project_missing' }
		$EngineRoot = Resolve-RequiredDirectory ([Environment]::GetEnvironmentVariable('AETHELN_ENGINE_ROOT', 'Process')) 'engine_root_invalid'
		$ToolchainRoot = Resolve-RequiredDirectory ([Environment]::GetEnvironmentVariable('AETHELN_LINUX_TOOLCHAIN_ROOT', 'Process')) 'toolchain_root_invalid'
		$BuildBatch = Join-Path $EngineRoot 'Engine/Build/BatchFiles/Build.bat'
		if ($Mode -eq 'Compile' -and -not (Test-Path -LiteralPath $BuildBatch -PathType Leaf)) { throw 'build_batch_missing' }
		if ($Mode -in @('PackagedSmoke', 'PackageClient', 'PackageServer', 'ValidateProvenance') -and -not (Test-Path -LiteralPath $BuildScript -PathType Leaf)) { throw 'build_script_missing' }
		if ($Mode -in @('PackagedSmoke', 'SmokePhase') -and -not (Test-Path -LiteralPath $SmokeScript -PathType Leaf)) { throw 'smoke_script_missing' }
		$ResolvedArchive = if ($IsPhaseMode) { $null } else { Resolve-OutputRoot $ArchiveRoot $ResolvedRepository 'archive_root_invalid' }
		$ResolvedLogs = Resolve-OutputRoot $LogRoot $ResolvedRepository 'log_root_invalid'
		if ($SourceRevision -notmatch '^[0-9a-fA-F]{40}$') { throw 'revision_invalid' }
		Add-Check 'runner-input-validation' 'passed' $ValidationStarted 'validate-runner-inputs' 'validation_passed'
	} catch {
		Add-Check 'runner-input-validation' 'failed' $ValidationStarted 'validate-runner-inputs' ([string] $_.Exception.Message)
		throw
	}
	$ProtectedValues = @($ResolvedRepository, $ProjectPath, $BuildScript, $SmokeScript, $BuildBatch, $EngineRoot, $ToolchainRoot, $ResolvedArchive, $ResolvedLogs)

	$HandoffRoot = $null
	$ScopeRoot = $null
	$RunDirectory = $null
	$PhaseName = $null
	if ($IsPhaseMode) {
		$PhaseName = $PhaseByMode[$Mode]
		$HandoffStarted = [DateTime]::UtcNow
		try {
			Assert-PhaseContext
			$HandoffRoot = Resolve-HandoffRoot @($ResolvedRepository, $EngineRoot, $ToolchainRoot, [Environment]::GetEnvironmentVariable('RUNNER_TEMP', 'Process'), [Environment]::GetEnvironmentVariable('GITHUB_WORKSPACE', 'Process'))
			$ScopeRoot = Get-HandoffChildPath $HandoffRoot ($Repository -replace '/', '-') 'handoff_root_invalid'
			$RunDirectory = Get-HandoffChildPath $ScopeRoot ('run-{0}-attempt-{1}' -f $RunId, $RunAttempt) 'handoff_root_invalid'
			if (-not (Test-Path -LiteralPath $ScopeRoot)) { New-Item -ItemType Directory -Path $ScopeRoot -Force | Out-Null }
			Add-Check 'handoff-validation' 'passed' $HandoffStarted 'validate-handoff-context' 'handoff_context_valid'
		} catch {
			$Reason = [string] $_.Exception.Message
			if ($Reason -notmatch '^[a-z0-9_]+$') { $Reason = 'handoff_root_invalid' }
			Add-Check 'handoff-validation' 'failed' $HandoffStarted 'validate-handoff-context' $Reason
			throw $Reason
		}
		$ProtectedValues += @($HandoffRoot, $ScopeRoot, $RunDirectory)

		if ($Mode -eq 'PackageClient') {
			$StorageStarted = [DateTime]::UtcNow
			try {
				Write-CleanupRequest $ScopeRoot $PhaseName
				$CommittedBytes = Get-DirectoryBytes $ScopeRoot
				if (($CommittedBytes + $HandoffPayloadCapBytes) -gt $HandoffRootCapBytes) { throw 'handoff_storage_exhausted' }
				if (Test-Path -LiteralPath $RunDirectory) { throw 'handoff_conflict' }
				New-Item -ItemType Directory -Path $RunDirectory | Out-Null
				Add-Check 'handoff-storage-accounting' 'passed' $StorageStarted 'reserve-handoff-storage' 'handoff_storage_reserved'
			} catch {
				$Reason = [string] $_.Exception.Message
				if ($Reason -notmatch '^[a-z0-9_]+$') { $Reason = 'handoff_storage_exhausted' }
				Add-Check 'handoff-storage-accounting' 'failed' $StorageStarted 'reserve-handoff-storage' $Reason
				throw $Reason
			}
		} else {
			if (-not (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
				Add-Check 'handoff-run-directory' 'failed' ([DateTime]::UtcNow) 'locate-handoff-run-directory' 'handoff_missing'
				throw 'handoff_missing'
			}
		}
	}

	Assert-RepositoryState 'repository-state-before-work'

	if ($Mode -eq 'Compile') {
		$Targets = @(
			[ordered]@{ name = 'incremental-client-build'; label = 'AethelnOnlineClient Win64 Development'; arguments = @('AethelnOnlineClient', 'Win64', 'Development', $ProjectPath, '-WaitMutex', '-NoHotReloadFromIDE') },
			[ordered]@{ name = 'incremental-server-build'; label = 'AethelnOnlineServer Linux Development'; arguments = @('AethelnOnlineServer', 'Linux', 'Development', $ProjectPath, '-WaitMutex', '-NoHotReloadFromIDE') }
		)
		foreach ($Target in $Targets) {
			$BuildStarted = [DateTime]::UtcNow
			$BuildResult = Invoke-Captured $BuildBatch $Target.arguments
			$BuildFailure = $null
			if ($BuildResult.exitCode -ne 0) {
				$BuildMessage = Get-SafeDiagnosticMessage 'build_failed' $BuildResult.output $ProtectedValues
				Add-Check $Target.name 'failed' $BuildStarted $Target.label $BuildMessage
				$BuildFailure = 'build_failed'
			} else {
				Add-Check $Target.name 'passed' $BuildStarted $Target.label 'build_passed'
			}
			Complete-CommandStateCheck ($Target.name + '-repository-state') $BuildFailure
		}
		Assert-RepositoryState 'repository-state-at-completion'
	} elseif ($Mode -eq 'PackagedSmoke') {
		$BuildStarted = [DateTime]::UtcNow
		$BuildOutput = New-Object System.Collections.ArrayList
		$BuildFailure = $null
		try {
			& $BuildScript -ProjectPath $ProjectPath -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot $ResolvedArchive -LogRoot $ResolvedLogs -SourceRevision $SourceRevision -Configuration Development -Map '/Game/Maps/StarterMap' *>&1 | ForEach-Object { [void] $BuildOutput.Add($_) }
			Add-Check 'clean-packaged-client-server-build' 'passed' $BuildStarted 'Build-PackagedArtifacts.ps1' 'build_passed'
		} catch {
			[void] $BuildOutput.Add($_)
			$BuildMessage = Get-SafeDiagnosticMessage 'build_failed' $BuildOutput $ProtectedValues
			Add-Check 'clean-packaged-client-server-build' 'failed' $BuildStarted 'Build-PackagedArtifacts.ps1' $BuildMessage
			$BuildFailure = 'build_failed'
		}

		Complete-CommandStateCheck 'repository-state-after-package' $BuildFailure

		$SmokeFailure = Invoke-SmokeGateWork $ResolvedArchive

		Complete-CommandStateCheck 'repository-state-at-completion' $SmokeFailure
	} elseif ($Mode -eq 'PackageClient' -or $Mode -eq 'PackageServer') {
		$PhaseDirectory = Get-HandoffChildPath $RunDirectory $PhaseName 'handoff_conflict'
		$CheckName = 'scheduled-{0}-package' -f $PhaseName
		if ((Test-Path -LiteralPath $PhaseDirectory) -or (Test-Path -LiteralPath (Join-Path $RunDirectory ('manifest-{0}.json' -f $PhaseName)))) {
			Add-Check $CheckName 'failed' ([DateTime]::UtcNow) 'Build-PackagedArtifacts.ps1' 'handoff_conflict'
			throw 'handoff_conflict'
		}
		$Stage = if ($Mode -eq 'PackageClient') { 'Client' } else { 'Server' }
		$BuildStarted = [DateTime]::UtcNow
		$PhaseResult = Invoke-PhaseChildScript $BuildScript @('-Stage', $Stage, '-ProjectPath', $ProjectPath, '-EngineRoot', $EngineRoot, '-LinuxToolchainRoot', $ToolchainRoot, '-ArchiveRoot', $PhaseDirectory, '-LogRoot', (Join-Path $ResolvedLogs $PhaseName), '-SourceRevision', $SourceRevision, '-Configuration', 'Development', '-Map', '/Game/Maps/StarterMap') $PhaseTimeoutMinutes
		$BuildFailure = $null
		if ($PhaseResult.timedOut) {
			Add-Check $CheckName 'failed' $BuildStarted 'Build-PackagedArtifacts.ps1' 'phase_timeout'
			$BuildFailure = 'phase_timeout'
		} elseif ($PhaseResult.exitCode -ne 0) {
			$BuildMessage = Get-SafeDiagnosticMessage 'build_failed' $PhaseResult.output $ProtectedValues
			Add-Check $CheckName 'failed' $BuildStarted 'Build-PackagedArtifacts.ps1' $BuildMessage
			$BuildFailure = 'build_failed'
		} else {
			Add-Check $CheckName 'passed' $BuildStarted 'Build-PackagedArtifacts.ps1' 'build_passed'
		}
		Complete-CommandStateCheck ('repository-state-after-{0}-package' -f $PhaseName) $BuildFailure

		Invoke-HandoffPublish $RunDirectory $PhaseName @('provenance', 'smoke')
		Assert-RepositoryState 'repository-state-at-completion'
	} elseif ($Mode -eq 'ValidateProvenance') {
		$ClientDirectory = Invoke-HandoffConsume $RunDirectory 'client' 'provenance'
		$ServerDirectory = Invoke-HandoffConsume $RunDirectory 'server' 'provenance'
		$PhaseDirectory = Get-HandoffChildPath $RunDirectory $PhaseName 'handoff_conflict'
		if ((Test-Path -LiteralPath $PhaseDirectory) -or (Test-Path -LiteralPath (Join-Path $RunDirectory ('manifest-{0}.json' -f $PhaseName)))) {
			Add-Check 'registry-provenance-validation' 'failed' ([DateTime]::UtcNow) 'Build-PackagedArtifacts.ps1' 'handoff_conflict'
			throw 'handoff_conflict'
		}
		$BuildStarted = [DateTime]::UtcNow
		$PhaseResult = Invoke-PhaseChildScript $BuildScript @('-Stage', 'Provenance', '-ProjectPath', $ProjectPath, '-EngineRoot', $EngineRoot, '-LinuxToolchainRoot', $ToolchainRoot, '-ArchiveRoot', $PhaseDirectory, '-LogRoot', (Join-Path $ResolvedLogs $PhaseName), '-SourceRevision', $SourceRevision, '-Configuration', 'Development', '-Map', '/Game/Maps/StarterMap', '-ClientStageRoot', $ClientDirectory, '-ServerStageRoot', $ServerDirectory) $PhaseTimeoutMinutes
		$BuildFailure = $null
		if ($PhaseResult.timedOut) {
			Add-Check 'registry-provenance-validation' 'failed' $BuildStarted 'Build-PackagedArtifacts.ps1' 'phase_timeout'
			$BuildFailure = 'phase_timeout'
		} elseif ($PhaseResult.exitCode -ne 0) {
			$BuildMessage = Get-SafeDiagnosticMessage 'validation_failed' $PhaseResult.output $ProtectedValues
			Add-Check 'registry-provenance-validation' 'failed' $BuildStarted 'Build-PackagedArtifacts.ps1' $BuildMessage
			$BuildFailure = 'validation_failed'
		} else {
			Add-Check 'registry-provenance-validation' 'passed' $BuildStarted 'Build-PackagedArtifacts.ps1' 'validation_passed'
		}
		Complete-CommandStateCheck 'repository-state-after-provenance-validation' $BuildFailure

		Invoke-HandoffPublish $RunDirectory $PhaseName @('smoke')
		Assert-RepositoryState 'repository-state-at-completion'
	} else {
		[void] (Invoke-HandoffConsume $RunDirectory 'client' 'smoke')
		[void] (Invoke-HandoffConsume $RunDirectory 'server' 'smoke')
		[void] (Invoke-HandoffConsume $RunDirectory 'provenance' 'smoke')

		$SmokeFailure = Invoke-SmokeGateWork $RunDirectory

		$MarkerStarted = [DateTime]::UtcNow
		try {
			Write-JsonAtomic ([ordered]@{
				schemaVersion = 1
				state = $(if ($SmokeFailure) { 'failed' } else { 'passed' })
				runId = $RunId
				runAttempt = $RunAttempt
				finishedUtc = [DateTime]::UtcNow.ToString('o')
			}) (Join-Path $RunDirectory 'milestone-complete.json')
			Write-CleanupRequest $ScopeRoot $PhaseName
			Add-Check 'handoff-milestone-completion' 'passed' $MarkerStarted 'write-milestone-marker' 'milestone_recorded'
		} catch {
			Add-Check 'handoff-milestone-completion' 'failed' $MarkerStarted 'write-milestone-marker' 'milestone_record_failed'
			if ([string]::IsNullOrWhiteSpace($SmokeFailure)) { $SmokeFailure = 'milestone_record_failed' }
		}

		Complete-CommandStateCheck 'repository-state-at-completion' $SmokeFailure
	}
} catch {
	$RequiredFailed = $true
	$FailureCode = [string] $_.Exception.Message
	if ($FailureCode -notmatch '^[a-z0-9_]+$') { $FailureCode = 'engine_runner_failed' }
} finally {
	try { Write-RunnerReport } catch { $RequiredFailed = $true; $FailureCode = 'report_write_failed' }
}

if ($RequiredFailed) {
	Write-Error $FailureCode
	exit 1
}
Write-Output 'engine_runner_passed'
exit 0
