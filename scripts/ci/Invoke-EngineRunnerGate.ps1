<#
.SYNOPSIS
Runs engine-dependent compile or packaged-smoke gates on an approved runner.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)] [ValidateSet('Compile', 'PackagedSmoke')] [string] $Mode,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RepositoryRoot,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SourceRevision,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ArchiveRoot,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $LogRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Started = [DateTime]::UtcNow
$Checks = New-Object System.Collections.ArrayList
$RequiredFailed = $false
$FailureCode = $null
$ResolvedRepository = $null
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
		if ($Mode -eq 'PackagedSmoke') {
			if (-not (Test-Path -LiteralPath $BuildScript -PathType Leaf)) { throw 'build_script_missing' }
			if (-not (Test-Path -LiteralPath $SmokeScript -PathType Leaf)) { throw 'smoke_script_missing' }
		}
		$ResolvedArchive = Resolve-OutputRoot $ArchiveRoot $ResolvedRepository 'archive_root_invalid'
		$ResolvedLogs = Resolve-OutputRoot $LogRoot $ResolvedRepository 'log_root_invalid'
		if ($SourceRevision -notmatch '^[0-9a-fA-F]{40}$') { throw 'revision_invalid' }
		Add-Check 'runner-input-validation' 'passed' $ValidationStarted 'validate-runner-inputs' 'validation_passed'
	} catch {
		Add-Check 'runner-input-validation' 'failed' $ValidationStarted 'validate-runner-inputs' ([string] $_.Exception.Message)
		throw
	}
	$ProtectedValues = @($ResolvedRepository, $ProjectPath, $BuildScript, $SmokeScript, $BuildBatch, $EngineRoot, $ToolchainRoot, $ResolvedArchive, $ResolvedLogs)

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
	} else {
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

		$SmokeStarted = [DateTime]::UtcNow
		$SmokeOutput = New-Object System.Collections.ArrayList
		$SmokeProtectedValues = @($ProtectedValues)
		$SmokeFailure = $null
		try {
			$ClientCandidates = @(Get-ChildItem -LiteralPath $ResolvedArchive -Recurse -File | Where-Object {
				$_.Name -in @('AethelnOnlineClient.exe', 'AethelnOnline.exe')
			})
			$Clients = @($ClientCandidates | Where-Object {
				if ($_.Name -notin @('AethelnOnlineClient.exe', 'AethelnOnline.exe')) { return $false }
				$RelativePath = $_.FullName.Substring($ResolvedArchive.Length)
				return -not (@($RelativePath -split '[\\/]' | Where-Object { $_ -eq 'Binaries' }).Count)
			})
			if ($Clients.Count -ne 1) { throw 'client_discovery_invalid' }
			$InternalClients = @($ClientCandidates | Where-Object {
				$RelativePath = $_.FullName.Substring($ResolvedArchive.Length)
				$HasBinariesSegment = @($RelativePath -split '[\\/]' | Where-Object { $_ -eq 'Binaries' }).Count -gt 0
				$HasBinariesSegment -and $_.Name -eq $Clients[0].Name
			})
			if ($InternalClients.Count -lt 1) { throw 'client_discovery_invalid' }
			$Servers = @(Get-ChildItem -LiteralPath $ResolvedArchive -Recurse -File | Where-Object { $_.Name -eq 'AethelnOnlineServer.sh' })
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
