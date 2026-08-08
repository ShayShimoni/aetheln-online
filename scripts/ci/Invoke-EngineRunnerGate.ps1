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

function Invoke-Captured([string] $Executable, [string[]] $Arguments, [string] $FailureReason) {
	$PreviousErrorActionPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = 'Continue'
		$Output = @(& $Executable @Arguments 2>&1)
		$ExitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $PreviousErrorActionPreference
	}
	if ($ExitCode -ne 0) { throw $FailureReason }
	return $Output
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
		if (-not (Test-Path -LiteralPath $BuildScript -PathType Leaf)) { throw 'build_script_missing' }
		if ($Mode -eq 'PackagedSmoke' -and -not (Test-Path -LiteralPath $SmokeScript -PathType Leaf)) { throw 'smoke_script_missing' }
		$EngineRoot = Resolve-RequiredDirectory ([Environment]::GetEnvironmentVariable('AETHELN_ENGINE_ROOT', 'Process')) 'engine_root_invalid'
		$ToolchainRoot = Resolve-RequiredDirectory ([Environment]::GetEnvironmentVariable('AETHELN_LINUX_TOOLCHAIN_ROOT', 'Process')) 'toolchain_root_invalid'
		$ResolvedArchive = Resolve-OutputRoot $ArchiveRoot $ResolvedRepository 'archive_root_invalid'
		$ResolvedLogs = Resolve-OutputRoot $LogRoot $ResolvedRepository 'log_root_invalid'
		if ([string]::IsNullOrWhiteSpace($SourceRevision)) { throw 'revision_invalid' }
		Add-Check 'runner-input-validation' 'passed' $ValidationStarted 'validate-runner-inputs' 'validation_passed'
	} catch {
		Add-Check 'runner-input-validation' 'failed' $ValidationStarted 'validate-runner-inputs' ([string] $_.Exception.Message)
		throw
	}
	$ProtectedValues = @($ResolvedRepository, $ProjectPath, $BuildScript, $SmokeScript, $EngineRoot, $ToolchainRoot, $ResolvedArchive, $ResolvedLogs)

	$BuildStarted = [DateTime]::UtcNow
	$BuildOutput = New-Object System.Collections.ArrayList
	try {
		& $BuildScript -ProjectPath $ProjectPath -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot $ResolvedArchive -LogRoot $ResolvedLogs -SourceRevision $SourceRevision -Configuration Development -Map '/Game/Maps/StarterMap' *>&1 | ForEach-Object { [void] $BuildOutput.Add($_) }
		Add-Check 'supported-client-server-build' 'passed' $BuildStarted 'Build-PackagedArtifacts.ps1' 'build_passed'
	} catch {
		[void] $BuildOutput.Add($_)
		$BuildMessage = Get-SafeDiagnosticMessage 'build_failed' $BuildOutput $ProtectedValues
		Add-Check 'supported-client-server-build' 'failed' $BuildStarted 'Build-PackagedArtifacts.ps1' $BuildMessage
		throw 'build_failed'
	}

	if ($Mode -eq 'PackagedSmoke') {
		$SmokeStarted = [DateTime]::UtcNow
		$SmokeOutput = New-Object System.Collections.ArrayList
		$SmokeProtectedValues = @($ProtectedValues)
		try {
			$Clients = @(Get-ChildItem -LiteralPath $ResolvedArchive -Recurse -File | Where-Object { $_.Name -in @('AethelnOnlineClient.exe', 'AethelnOnline.exe') })
			if ($Clients.Count -ne 1) { throw 'client_discovery_invalid' }
			$Servers = @(Get-ChildItem -LiteralPath $ResolvedArchive -Recurse -File | Where-Object { $_.Name -eq 'AethelnOnlineServer.sh' })
			if ($Servers.Count -ne 1) { throw 'server_discovery_invalid' }

			$WslPathArguments = @('-d', 'Ubuntu', '-u', 'aethelnqa', '--', 'wslpath', $Servers[0].FullName)
			$Translated = Invoke-Captured 'wsl.exe' $WslPathArguments 'wslpath_exit_nonzero'
			$TranslatedLines = @($Translated | ForEach-Object { [string] $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
			if ($TranslatedLines.Count -ne 1) { throw 'wslpath_line_count_invalid' }
			$LinuxServer = $TranslatedLines[0].Trim()
			if ([string]::IsNullOrWhiteSpace($LinuxServer) -or -not $LinuxServer.StartsWith('/')) { throw 'wslpath_result_invalid' }
			$SmokeProtectedValues += @($Clients[0].FullName, $Servers[0].FullName, $LinuxServer)

			$AddressOutput = Invoke-Captured 'wsl.exe' @('-d', 'Ubuntu', '-u', 'aethelnqa', '--', 'hostname', '-I') 'wsl_address_exit_nonzero'
			$AddressCandidates = @((($AddressOutput -join ' ').Trim() -split '\s+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
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
			throw $SafeReason
		}
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
