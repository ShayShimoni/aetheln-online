<#
.SYNOPSIS
Proves that two packaged Windows clients connect to a packaged Linux dedicated server.

.DESCRIPTION
Starts the Linux server through a configurable launcher (WSL by default), starts two
Windows clients against an explicit endpoint, correlates server- and client-side log
observations, and writes script-owned JSONL evidence to smoke-evidence.jsonl.
LogRoot must be absent or empty so evidence from separate smoke runs cannot be mixed.

.EXAMPLE
.\scripts\build\Invoke-PackagedSmokeTest.ps1 `
  -ServerExecutable '/mnt/d/build/LinuxServer/AethelnOnlineServer.sh' `
  -ServerLauncherExecutable 'wsl.exe' `
  -ServerLauncherArguments @('-d','Ubuntu','-u','aethelnqa','--exec','{ServerExecutable}','{ServerMap}','-port=7777','-stdout','-FullStdOutLogOutput') `
  -ClientExecutable 'D:\build\WindowsClient\AethelnOnlineClient.exe' `
  -ClientBaseArguments @('{ServerEndpoint}','-stdout','-FullStdOutLogOutput') `
  -ServerEndpoint '127.0.0.1:7777' -ServerMap '/Game/Maps/StarterMap' `
  -LogRoot 'D:\smoke\run-001' `
  -ServerReadyPattern 'GameNetDriver.*Listening.*{ServerEndpoint}' `
  -ServerClientConnectedPattern 'AddClientConnection:.*RemoteAddr: (?<ConnectionId>[^,]+)' `
  -ClientConnectedPattern 'Join succeeded.*{ServerEndpoint}' `
  -ClientMapPattern 'Bringing World.*{ServerMap}'

.PARAMETER ServerLauncherExecutable
Windows executable used to launch the packaged Linux server. Defaults to wsl.exe.

.PARAMETER ServerLauncherArguments
Launcher and server arguments. Must contain {ServerExecutable}, {ServerMap}, and
may contain {ServerEndpoint}. Server readiness is monitored from redirected launcher
stdout. {LogPath} is optional and requires ServerLogPath to be a Linux/WSL path.

.PARAMETER ServerLogPath
Optional Linux/WSL-compatible Unreal server log path substituted for {LogPath} in
ServerLauncherArguments. Windows LogRoot paths are never passed into WSL implicitly.

.PARAMETER ClientBaseArguments
Packaged-client arguments. Must contain {ServerEndpoint}; {ServerMap}, {ClientId},
and {LogPath} are also available. Client evidence is monitored from redirected stdout.

.PARAMETER ClientLogPath
Optional absolute client log-path template substituted for {LogPath}. Use {ClientId}
to give each process a distinct path. No LogRoot path is passed implicitly.

.PARAMETER ServerClientConnectedPattern
Regex applied to redirected server stdout. It must contain a named ConnectionId
capture. The smoke requires two unique captured values; they are transport evidence
and are intentionally not mapped to client names.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerExecutable,
	[string] $ServerLauncherExecutable = 'wsl.exe',
	[Parameter(Mandatory)] [string[]] $ServerLauncherArguments,
	[string] $ServerLogPath,
	[Parameter(Mandatory)] [string] $ClientExecutable,
	[Parameter(Mandatory)] [string[]] $ClientBaseArguments,
	[string] $ClientLogPath,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerEndpoint,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerMap,
	[Parameter(Mandatory)] [string] $LogRoot,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerReadyPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerClientConnectedPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ClientConnectedPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ClientMapPattern,
	[ValidateNotNullOrEmpty()] [string] $ErrorPattern = '(?i)(fatal error|network\s+failure|connection\s+failed|connection\s+timed\s+out|connectiontimeout|failed to load package)',
	[ValidateRange(1, 3600)] [int] $TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-Executable([string] $Name, [string] $Path) {
	if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Resolve-Path -LiteralPath $Path).Path }
	$Command = Get-Command $Path -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
	if (-not $Command) { throw "$Name '$Path' does not exist and is not available on PATH." }
	return [string] $Command.Source
}

function Get-ProcessesUnderPath([string] $Root) {
	$ResolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
	$Prefix = $ResolvedRoot + [System.IO.Path]::DirectorySeparatorChar
	foreach ($Process in @(Get-Process -ErrorAction Stop)) {
		try { $ProcessPath = [string] $Process.Path } catch { continue }
		if ([string]::IsNullOrWhiteSpace($ProcessPath)) { continue }
		try { $FullProcessPath = [System.IO.Path]::GetFullPath($ProcessPath) } catch { continue }
		if ($FullProcessPath.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $Process }
	}
}

function Resolve-ProcessIdentity($Process, [hashtable] $Baseline, [long] $BaselineTicks = 0) {
	# Baseline absence is not ownership proof: enumeration/path observation can miss
	# a pre-launch process. Require a readable start time beyond the captured boundary.
	# An observed PID with an unreadable baseline identity remains protected even if
	# its current identity becomes readable; an unknown identity never permits a kill.
	$ProcessId = [string] $Process.Id
	$Observed = $Baseline.ContainsKey($ProcessId)
	if ($Observed -and $null -eq $Baseline[$ProcessId]) { return 'unresolved' }
	try { $StartTicks = [long] $Process.StartTime.ToUniversalTime().Ticks } catch [System.SystemException] { return 'unresolved' }
	if ($Observed -and $StartTicks -eq [long] $Baseline[$ProcessId]) { return 'preexisting' }
	if (-not $Observed) {
		if ($BaselineTicks -le 0) { return 'unresolved' }
		if ($StartTicks -le $BaselineTicks) { return 'preexisting' }
	}
	return 'new'
}

function Test-IsPreexistingProcessIdentity($Process, [hashtable] $Baseline, [long] $BaselineTicks = 0) {
	# True when the process must not be terminated: proven preexisting or unresolved.
	return (Resolve-ProcessIdentity -Process $Process -Baseline $Baseline -BaselineTicks $BaselineTicks) -ne 'new'
}

function Get-PreexistingProcessIdentityBaseline([object[]] $Processes) {
	$Baseline = @{}
	foreach ($Process in @($Processes)) {
		# StartTime throws Win32Exception (access denied) or InvalidOperationException
		# (exited between enumeration and read). Record the PID with an unknown identity
		# so cleanup protects it instead of treating it as smoke-owned.
		try { $Baseline[[string] $Process.Id] = [long] $Process.StartTime.ToUniversalTime().Ticks } catch [System.SystemException] { $Baseline[[string] $Process.Id] = $null }
	}
	return $Baseline
}

function Initialize-EmptyLogRoot([string] $Path) {
	if (Test-Path -LiteralPath $Path) {
		if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "LogRoot '$Path' exists but is not a directory." }
		$Existing = @(Get-ChildItem -LiteralPath $Path -Force)
		if ($Existing.Count -gt 0) { throw "LogRoot '$Path' must be absent or empty; found $($Existing.Count) existing item(s). Use a unique clean directory for each smoke run." }
	}
	else { New-Item -ItemType Directory -Path $Path | Out-Null }
	return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-Placeholder([string[]] $Arguments, [string] $Placeholder, [string] $Name) {
	if (-not (($Arguments -join ' ') -like "*$Placeholder*")) { throw "$Name must contain $Placeholder so the smoke target is explicit." }
}

function Expand-ArgumentList([string[]] $Arguments, [string] $ClientId, [string] $LogPath, [string] $ServerExecutable) {
	$LogReplacement = if ($null -eq $LogPath) { '' } else { $LogPath }
	return @($Arguments | ForEach-Object {
		$_.Replace('{ClientId}', $ClientId).Replace('{LogPath}', $LogReplacement).Replace('{ServerExecutable}', $ServerExecutable).Replace('{ServerEndpoint}', $ServerEndpoint).Replace('{ServerMap}', $ServerMap)
	})
}

function Expand-Pattern([string] $Pattern, [string] $ClientId) {
	return $Pattern.Replace('{ClientId}', [regex]::Escape($ClientId)).Replace('{ServerEndpoint}', [regex]::Escape($ServerEndpoint)).Replace('{ServerMap}', [regex]::Escape($ServerMap))
}

function Write-Evidence([string] $Process, [string] $Role, [string] $EventName, [string] $Source, [string] $Detail, [string] $ConnectionId = '') {
	$Record = [ordered]@{
		schema = 'aetheln.packaged-smoke.evidence/v1'
		timestamp = [DateTime]::UtcNow.ToString('o')
		process = $Process
		role = $Role
		event = $EventName
		source = $Source
		detail = $Detail
	}
	if ($ConnectionId) { $Record['connection_id'] = $ConnectionId }
	$SerializedRecord = $Record | ConvertTo-Json -Compress
	$Encoding = [System.Text.UTF8Encoding]::new($true)
	$RecordBytes = $Encoding.GetBytes($SerializedRecord + [Environment]::NewLine)
	$Stream = $null
	# One orchestrator owns writes; observers may read concurrently. Opening with
	# write access avoids Add-Content's encoding-read fallback on a write-only
	# stream. Retry only sharing/lock failures before any record bytes are written.
	for ($Attempt = 1; $Attempt -le 50; $Attempt++) {
		try {
			$Stream = [System.IO.File]::Open($EvidencePath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
			break
		} catch [System.IO.IOException] {
			$ErrorCode = $_.Exception.GetBaseException().HResult -band 0xffff
			if ($ErrorCode -notin @(32, 33) -or $Attempt -eq 50) { throw }
			Start-Sleep -Milliseconds 20
		}
	}
	try {
		# Preserve Windows PowerShell's UTF-8 BOM, once at the start of a new file.
		if ($Stream.Length -eq 0) {
			$Preamble = $Encoding.GetPreamble()
			$Stream.Write($Preamble, 0, $Preamble.Length)
		}
		$Stream.Write($RecordBytes, 0, $RecordBytes.Length)
		$Stream.Flush()
	} finally { $Stream.Dispose() }
}

function Wait-ForEvidence([string] $ProcessName, [string] $Role, [System.Diagnostics.Process] $Process, [string] $Description, [string] $Path, [string] $ErrorPath, [string] $Pattern, [string] $EventName, [string] $ErrorPattern, [int] $TimeoutSeconds) {
	$Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
	do {
		if (Test-Path -LiteralPath $Path -PathType Leaf) {
			$Lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
			$ErrorLine = $Lines | Where-Object { $_ -match $ErrorPattern } | Select-Object -First 1
			if ($ErrorLine) { throw "$ProcessName reported an error while waiting for $Description in '$Path': $ErrorLine" }
			$Match = $Lines | Where-Object { $_ -match $Pattern } | Select-Object -First 1
			if ($Match) {
				Write-Evidence -Process $ProcessName -Role $Role -EventName $EventName -Source $Path -Detail $Match
				return
			}
		}
		$Process.Refresh()
		if ($Process.HasExited) {
			$Process.WaitForExit()
			$ExitCode = $Process.ExitCode
			if ($null -eq $ExitCode) { $ExitCode = 'unavailable from launcher' }
			throw "$ProcessName exited early with exit code $ExitCode while waiting for $Description. Review '$Path' and '$ErrorPath'."
		}
		Start-Sleep -Milliseconds 100
	} while ([DateTime]::UtcNow -lt $Deadline)
	throw "Timed out after $TimeoutSeconds seconds waiting for $Description for $ProcessName in '$Path' (pattern '$Pattern')."
}

function Wait-ForUniqueServerConnectionPair([System.Diagnostics.Process] $Process, [string] $Path, [string] $ErrorPath, [string] $Pattern, [string] $ErrorPattern, [int] $TimeoutSeconds) {
	$Expression = [regex]::new($Pattern)
	if ($Expression.GetGroupNames() -notcontains 'ConnectionId') {
		throw 'ServerClientConnectedPattern must contain a named regex capture (?<ConnectionId>...).'
	}
	$Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
	$Connections = @{}
	do {
		if (Test-Path -LiteralPath $Path -PathType Leaf) {
			$Lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
			$ErrorLine = $Lines | Where-Object { $_ -match $ErrorPattern } | Select-Object -First 1
			if ($ErrorLine) { throw "server reported an error while waiting for two unique server connections in '$Path': $ErrorLine" }
			foreach ($Line in $Lines) {
				$Match = $Expression.Match($Line)
				if ($Match.Success) {
					$ConnectionId = $Match.Groups['ConnectionId'].Value
					if ($ConnectionId -and -not $Connections.ContainsKey($ConnectionId)) { $Connections[$ConnectionId] = $Line }
				}
			}
			if ($Connections.Count -ge 2) {
				foreach ($ConnectionId in @($Connections.Keys | Sort-Object | Select-Object -First 2)) {
					Write-Evidence -Process 'server' -Role 'server-observation' -EventName 'server_observed_connection' -Source $Path -Detail $Connections[$ConnectionId] -ConnectionId $ConnectionId
				}
				return
			}
		}
		$Process.Refresh()
		if ($Process.HasExited) {
			$Process.WaitForExit()
			$ExitCode = $Process.ExitCode
			if ($null -eq $ExitCode) { $ExitCode = 'unavailable from launcher' }
			throw "server exited early with exit code $ExitCode while waiting for two unique server connections; observed only $($Connections.Count) unique. Review '$Path' and '$ErrorPath'."
		}
		Start-Sleep -Milliseconds 100
	} while ([DateTime]::UtcNow -lt $Deadline)
	throw "Timed out after $TimeoutSeconds seconds waiting for two unique server connections; observed only $($Connections.Count) unique in '$Path' (pattern '$Pattern')."
}

function Wait-ForOwnedProcessExit($Process, [int] $TimeoutMilliseconds, [string] $Source) {
	# WaitForExit throws Win32Exception (handle could not be opened) or a SystemException
	# when no process is associated any more. Neither decides cleanup: the bounded rescan
	# loop does. Record the failure as evidence with PID and exception type only.
	try {
		if ($Process.WaitForExit($TimeoutMilliseconds)) { return $true }
		Write-Evidence -Process 'orchestrator' -Role 'cleanup' -EventName 'process_cleanup_wait_failed' -Source $Source -Detail "PID $($Process.Id): exit not confirmed within $TimeoutMilliseconds milliseconds."
	}
	catch [System.SystemException] {
		Write-Evidence -Process 'orchestrator' -Role 'cleanup' -EventName 'process_cleanup_wait_failed' -Source $Source -Detail "PID $($Process.Id): $($_.Exception.GetBaseException().GetType().Name)"
	}
	return $false
}

Assert-Placeholder -Arguments $ServerLauncherArguments -Placeholder '{ServerExecutable}' -Name 'ServerLauncherArguments'
Assert-Placeholder -Arguments $ServerLauncherArguments -Placeholder '{ServerMap}' -Name 'ServerLauncherArguments'
Assert-Placeholder -Arguments $ClientBaseArguments -Placeholder '{ServerEndpoint}' -Name 'ClientBaseArguments'
if (($ServerLauncherArguments -join ' ') -like '*{LogPath}*' -and [string]::IsNullOrWhiteSpace($ServerLogPath)) {
	throw 'ServerLogPath must be supplied with a Linux/WSL-compatible path when ServerLauncherArguments contains {LogPath}.'
}
if (($ClientBaseArguments -join ' ') -like '*{LogPath}*' -and [string]::IsNullOrWhiteSpace($ClientLogPath)) {
	throw 'ClientLogPath must be supplied when ClientBaseArguments contains {LogPath}.'
}

$ResolvedLauncher = Resolve-Executable 'ServerLauncherExecutable' $ServerLauncherExecutable
$ResolvedClient = Resolve-Executable 'ClientExecutable' $ClientExecutable
$ResolvedLogs = Initialize-EmptyLogRoot $LogRoot
$ClientPackageRoot = Split-Path -Parent $ResolvedClient
$EvidencePath = Join-Path $ResolvedLogs 'smoke-evidence.jsonl'
# Capture identities before filtering by executable path. A process whose Path is
# unreadable now may be visible under the package root later and must stay protected.
# Enumeration errors fail before any smoke process is launched.
$PreexistingClientProcessIdentities = Get-PreexistingProcessIdentityBaseline -Processes @(Get-Process -ErrorAction Stop)
$ClientProcessBaselineTicks = [DateTime]::UtcNow.Ticks
foreach ($UnknownProcessId in @($PreexistingClientProcessIdentities.Keys | Where-Object { $null -eq $PreexistingClientProcessIdentities[$_] })) {
	Write-Evidence -Process 'orchestrator' -Role 'cleanup' -EventName 'preexisting_identity_unknown' -Source $ClientPackageRoot -Detail "PID $UnknownProcessId start time unreadable; protected from cleanup."
}
$ServerStdOutLog = Join-Path $ResolvedLogs 'server.stdout.log'
$ServerStdErrLog = Join-Path $ResolvedLogs 'server.stderr.log'
$Processes = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()

try {
	$ExpandedServerArguments = Expand-ArgumentList -Arguments $ServerLauncherArguments -ClientId 'server' -LogPath $ServerLogPath -ServerExecutable $ServerExecutable
	$ServerProcess = Start-Process -FilePath $ResolvedLauncher -ArgumentList $ExpandedServerArguments -RedirectStandardOutput $ServerStdOutLog -RedirectStandardError $ServerStdErrLog -WindowStyle Hidden -PassThru
	$Processes.Add($ServerProcess)
	Write-Evidence -Process 'server' -Role 'server' -EventName 'process_started' -Source $ResolvedLauncher -Detail ($ExpandedServerArguments -join ' ')
	Wait-ForEvidence -ProcessName 'server' -Role 'server' -Process $ServerProcess -Description 'server listen readiness' -Path $ServerStdOutLog -ErrorPath $ServerStdErrLog -Pattern (Expand-Pattern $ServerReadyPattern 'server') -EventName 'server_listening' -ErrorPattern $ErrorPattern -TimeoutSeconds $TimeoutSeconds

	$Clients = @{}
	foreach ($ClientNumber in 1..2) {
		$ClientId = "client-$ClientNumber"
		$ClientStdOutLog = Join-Path $ResolvedLogs "$ClientId.stdout.log"
		$ClientStdErrLog = Join-Path $ResolvedLogs "$ClientId.stderr.log"
		$ResolvedClientLogPath = if ($null -eq $ClientLogPath) { $null } else { $ClientLogPath.Replace('{ClientId}', $ClientId) }
		$ExpandedClientArguments = Expand-ArgumentList -Arguments $ClientBaseArguments -ClientId $ClientId -LogPath $ResolvedClientLogPath -ServerExecutable $ServerExecutable
		$ClientProcess = Start-Process -FilePath $ResolvedClient -ArgumentList $ExpandedClientArguments -RedirectStandardOutput $ClientStdOutLog -RedirectStandardError $ClientStdErrLog -WindowStyle Hidden -PassThru
		$Processes.Add($ClientProcess)
		$Clients[$ClientId] = $ClientProcess
		Write-Evidence -Process $ClientId -Role 'client' -EventName 'process_started' -Source $ResolvedClient -Detail ($ExpandedClientArguments -join ' ')
	}
	Wait-ForUniqueServerConnectionPair -Process $ServerProcess -Path $ServerStdOutLog -ErrorPath $ServerStdErrLog -Pattern (Expand-Pattern $ServerClientConnectedPattern 'server') -ErrorPattern $ErrorPattern -TimeoutSeconds $TimeoutSeconds

	foreach ($ClientNumber in 1..2) {
		$ClientId = "client-$ClientNumber"
		$ClientProcess = $Clients[$ClientId]
		$ClientStdOutLog = Join-Path $ResolvedLogs "$ClientId.stdout.log"
		$ClientStdErrLog = Join-Path $ResolvedLogs "$ClientId.stderr.log"
		Wait-ForEvidence -ProcessName $ClientId -Role 'client' -Process $ClientProcess -Description 'client connection confirmation' -Path $ClientStdOutLog -ErrorPath $ClientStdErrLog -Pattern (Expand-Pattern $ClientConnectedPattern $ClientId) -EventName 'client_connected' -ErrorPattern $ErrorPattern -TimeoutSeconds $TimeoutSeconds
		Wait-ForEvidence -ProcessName $ClientId -Role 'client' -Process $ClientProcess -Description 'client map confirmation' -Path $ClientStdOutLog -ErrorPath $ClientStdErrLog -Pattern (Expand-Pattern $ClientMapPattern $ClientId) -EventName 'client_map_confirmed' -ErrorPattern $ErrorPattern -TimeoutSeconds $TimeoutSeconds
	}
	Write-Evidence -Process 'orchestrator' -Role 'smoke' -EventName 'smoke_passed' -Source $EvidencePath -Detail "Two distinct clients connected to $ServerEndpoint on $ServerMap."
	Write-Output "Packaged smoke test passed: the Linux server listened on '$ServerEndpoint' and observed two unique connections; both packaged Windows clients confirmed '$ServerMap'. Evidence: '$EvidencePath'."
}
finally {
	$CleanupDeadline = [DateTime]::UtcNow.AddSeconds(10)
	$DirectCleanupFailures = [System.Collections.Generic.List[string]]::new()
	foreach ($Process in $Processes) {
		try {
			try {
				if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force -ErrorAction Stop }
			} catch [System.SystemException] {
				Write-Evidence -Process 'orchestrator' -Role 'cleanup' -EventName 'process_cleanup_stop_failed' -Source $EvidencePath -Detail "PID $($Process.Id): $($_.Exception.GetBaseException().GetType().Name)"
			}
			$WaitMilliseconds = [int] [Math]::Max(0, [Math]::Min(5000, ($CleanupDeadline - [DateTime]::UtcNow).TotalMilliseconds))
			if (-not (Wait-ForOwnedProcessExit -Process $Process -TimeoutMilliseconds $WaitMilliseconds -Source $EvidencePath)) { $DirectCleanupFailures.Add([string] $Process.Id) }
		} finally { $Process.Dispose() }
	}
	Write-Evidence -Process 'orchestrator' -Role 'cleanup' -EventName 'process_cleanup_started' -Source $EvidencePath -Detail 'Scanning for smoke-owned package processes.'
	$QuiescentSince = $null
	do {
		$PackageProcesses = @(Get-ProcessesUnderPath $ClientPackageRoot)
		$NewPackageProcesses = @($PackageProcesses | Where-Object { (Resolve-ProcessIdentity -Process $_ -Baseline $PreexistingClientProcessIdentities -BaselineTicks $ClientProcessBaselineTicks) -eq 'new' })
		$UnresolvedPackageProcesses = @($PackageProcesses | Where-Object { (Resolve-ProcessIdentity -Process $_ -Baseline $PreexistingClientProcessIdentities -BaselineTicks $ClientProcessBaselineTicks) -eq 'unresolved' })
		if ($NewPackageProcesses.Count -gt 0) {
			$QuiescentSince = $null
			foreach ($Process in $NewPackageProcesses) {
				Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
				$WaitMilliseconds = [int] [Math]::Max(0, [Math]::Min(5000, ($CleanupDeadline - [DateTime]::UtcNow).TotalMilliseconds))
				[void] (Wait-ForOwnedProcessExit -Process $Process -TimeoutMilliseconds $WaitMilliseconds -Source $ClientPackageRoot)
				$Process.Dispose()
			}
		} elseif ($UnresolvedPackageProcesses.Count -gt 0) {
			# Never terminate an unresolved process. Keep waiting, inside the same deadline,
			# for its identity to resolve or for it to vanish; quiescence cannot start yet.
			$QuiescentSince = $null
		} elseif ($null -eq $QuiescentSince) {
			$QuiescentSince = [DateTime]::UtcNow
		} elseif (([DateTime]::UtcNow - $QuiescentSince).TotalSeconds -ge 2) {
			break
		}
		Start-Sleep -Milliseconds 100
	} while ([DateTime]::UtcNow -lt $CleanupDeadline)
	$FinalPackageProcesses = @(Get-ProcessesUnderPath $ClientPackageRoot)
	$UnresolvedProcessIds = @($FinalPackageProcesses | Where-Object { (Resolve-ProcessIdentity -Process $_ -Baseline $PreexistingClientProcessIdentities -BaselineTicks $ClientProcessBaselineTicks) -eq 'unresolved' } | ForEach-Object { [string] $_.Id })
	if ($UnresolvedProcessIds.Count -gt 0) {
		foreach ($UnresolvedProcessId in $UnresolvedProcessIds) {
			Write-Evidence -Process 'orchestrator' -Role 'cleanup' -EventName 'process_cleanup_unresolved' -Source $ClientPackageRoot -Detail "PID $UnresolvedProcessId identity unresolved; not terminated."
		}
		throw "Packaged client process cleanup found $($UnresolvedProcessIds.Count) process(es) with unresolved identity under the package root (PID $($UnresolvedProcessIds -join ', ')) within 10 seconds; they were not terminated and cleanup is not complete."
	}
	$RemainingPackageProcesses = @($FinalPackageProcesses | Where-Object { (Resolve-ProcessIdentity -Process $_ -Baseline $PreexistingClientProcessIdentities -BaselineTicks $ClientProcessBaselineTicks) -eq 'new' })
	if ($DirectCleanupFailures.Count -gt 0) {
		throw "Packaged smoke direct process cleanup could not confirm exit for PID $($DirectCleanupFailures -join ', ') within the bounded cleanup window; cleanup is not complete."
	}
	if ($RemainingPackageProcesses.Count -gt 0 -or $null -eq $QuiescentSince -or ([DateTime]::UtcNow - $QuiescentSince).TotalSeconds -lt 2) {
		throw 'Packaged client process cleanup did not reach quiescence within 10 seconds.'
	}
	Write-Evidence -Process 'orchestrator' -Role 'cleanup' -EventName 'process_cleanup_complete' -Source $EvidencePath -Detail 'No smoke-owned package processes remained after the quiescence window.'
}
