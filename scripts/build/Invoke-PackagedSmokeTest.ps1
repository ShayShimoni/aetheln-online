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
	foreach ($Process in @(Get-Process -ErrorAction SilentlyContinue)) {
		try { $ProcessPath = [string] $Process.Path } catch { continue }
		if ([string]::IsNullOrWhiteSpace($ProcessPath)) { continue }
		try { $FullProcessPath = [System.IO.Path]::GetFullPath($ProcessPath) } catch { continue }
		if ($FullProcessPath.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $Process }
	}
}

function Test-IsPreexistingProcessIdentity($Process, [hashtable] $Baseline) {
	$ProcessId = [string] $Process.Id
	if (-not $Baseline.ContainsKey($ProcessId)) { return $false }
	try { $StartTicks = [long] $Process.StartTime.ToUniversalTime().Ticks } catch { return $false }
	return $StartTicks -eq [long] $Baseline[$ProcessId]
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

function Expand-Arguments([string[]] $Arguments, [string] $ClientId, [string] $LogPath) {
	$LogReplacement = if ($null -eq $LogPath) { '' } else { $LogPath }
	return @($Arguments | ForEach-Object {
		$_.Replace('{ClientId}', $ClientId).Replace('{LogPath}', $LogReplacement).Replace('{ServerExecutable}', $ServerExecutable).Replace('{ServerEndpoint}', $ServerEndpoint).Replace('{ServerMap}', $ServerMap)
	})
}

function Expand-Pattern([string] $Pattern, [string] $ClientId) {
	return $Pattern.Replace('{ClientId}', [regex]::Escape($ClientId)).Replace('{ServerEndpoint}', [regex]::Escape($ServerEndpoint)).Replace('{ServerMap}', [regex]::Escape($ServerMap))
}

function Write-Evidence([string] $Process, [string] $Role, [string] $Event, [string] $Source, [string] $Detail, [string] $ConnectionId = '') {
	$Record = [ordered]@{
		schema = 'aetheln.packaged-smoke.evidence/v1'
		timestamp = [DateTime]::UtcNow.ToString('o')
		process = $Process
		role = $Role
		event = $Event
		source = $Source
		detail = $Detail
	}
	if ($ConnectionId) { $Record['connection_id'] = $ConnectionId }
	$SerializedRecord = $Record | ConvertTo-Json -Compress
	for ($Attempt = 1; $Attempt -le 50; $Attempt++) {
		try {
			Add-Content -LiteralPath $EvidencePath -Value $SerializedRecord -Encoding UTF8
			return
		} catch [System.IO.IOException] {
			if ($Attempt -eq 50) { throw }
			Start-Sleep -Milliseconds 20
		}
	}
}

function Wait-ForEvidence([string] $ProcessName, [string] $Role, [System.Diagnostics.Process] $Process, [string] $Description, [string] $Path, [string] $ErrorPath, [string] $Pattern, [string] $Event) {
	$Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
	do {
		if (Test-Path -LiteralPath $Path -PathType Leaf) {
			$Lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
			$ErrorLine = $Lines | Where-Object { $_ -match $ErrorPattern } | Select-Object -First 1
			if ($ErrorLine) { throw "$ProcessName reported an error while waiting for $Description in '$Path': $ErrorLine" }
			$Match = $Lines | Where-Object { $_ -match $Pattern } | Select-Object -First 1
			if ($Match) {
				Write-Evidence $ProcessName $Role $Event $Path $Match
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

function Wait-ForUniqueServerConnections([System.Diagnostics.Process] $Process, [string] $Path, [string] $ErrorPath, [string] $Pattern) {
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
					Write-Evidence 'server' 'server-observation' 'server_observed_connection' $Path $Connections[$ConnectionId] $ConnectionId
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

Assert-Placeholder $ServerLauncherArguments '{ServerExecutable}' 'ServerLauncherArguments'
Assert-Placeholder $ServerLauncherArguments '{ServerMap}' 'ServerLauncherArguments'
Assert-Placeholder $ClientBaseArguments '{ServerEndpoint}' 'ClientBaseArguments'
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
$PreexistingClientProcessIdentities = @{}
foreach ($Process in @(Get-ProcessesUnderPath $ClientPackageRoot)) {
	try { $PreexistingClientProcessIdentities[[string] $Process.Id] = [long] $Process.StartTime.ToUniversalTime().Ticks } catch { }
}
$EvidencePath = Join-Path $ResolvedLogs 'smoke-evidence.jsonl'
$ServerStdOutLog = Join-Path $ResolvedLogs 'server.stdout.log'
$ServerStdErrLog = Join-Path $ResolvedLogs 'server.stderr.log'
$Processes = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()

try {
	$ExpandedServerArguments = Expand-Arguments $ServerLauncherArguments 'server' $ServerLogPath
	$ServerProcess = Start-Process -FilePath $ResolvedLauncher -ArgumentList $ExpandedServerArguments -RedirectStandardOutput $ServerStdOutLog -RedirectStandardError $ServerStdErrLog -WindowStyle Hidden -PassThru
	$Processes.Add($ServerProcess)
	Write-Evidence 'server' 'server' 'process_started' $ResolvedLauncher ($ExpandedServerArguments -join ' ')
	Wait-ForEvidence 'server' 'server' $ServerProcess 'server listen readiness' $ServerStdOutLog $ServerStdErrLog (Expand-Pattern $ServerReadyPattern 'server') 'server_listening'

	$Clients = @{}
	foreach ($ClientNumber in 1..2) {
		$ClientId = "client-$ClientNumber"
		$ClientStdOutLog = Join-Path $ResolvedLogs "$ClientId.stdout.log"
		$ClientStdErrLog = Join-Path $ResolvedLogs "$ClientId.stderr.log"
		$ResolvedClientLogPath = if ($null -eq $ClientLogPath) { $null } else { $ClientLogPath.Replace('{ClientId}', $ClientId) }
		$ExpandedClientArguments = Expand-Arguments $ClientBaseArguments $ClientId $ResolvedClientLogPath
		$ClientProcess = Start-Process -FilePath $ResolvedClient -ArgumentList $ExpandedClientArguments -RedirectStandardOutput $ClientStdOutLog -RedirectStandardError $ClientStdErrLog -WindowStyle Hidden -PassThru
		$Processes.Add($ClientProcess)
		$Clients[$ClientId] = $ClientProcess
		Write-Evidence $ClientId 'client' 'process_started' $ResolvedClient ($ExpandedClientArguments -join ' ')
	}
	Wait-ForUniqueServerConnections $ServerProcess $ServerStdOutLog $ServerStdErrLog (Expand-Pattern $ServerClientConnectedPattern 'server')

	foreach ($ClientNumber in 1..2) {
		$ClientId = "client-$ClientNumber"
		$ClientProcess = $Clients[$ClientId]
		$ClientStdOutLog = Join-Path $ResolvedLogs "$ClientId.stdout.log"
		$ClientStdErrLog = Join-Path $ResolvedLogs "$ClientId.stderr.log"
		Wait-ForEvidence $ClientId 'client' $ClientProcess 'client connection confirmation' $ClientStdOutLog $ClientStdErrLog (Expand-Pattern $ClientConnectedPattern $ClientId) 'client_connected'
		Wait-ForEvidence $ClientId 'client' $ClientProcess 'client map confirmation' $ClientStdOutLog $ClientStdErrLog (Expand-Pattern $ClientMapPattern $ClientId) 'client_map_confirmed'
	}
	Write-Evidence 'orchestrator' 'smoke' 'smoke_passed' $EvidencePath "Two distinct clients connected to $ServerEndpoint on $ServerMap."
	Write-Output "Packaged smoke test passed: the Linux server listened on '$ServerEndpoint' and observed two unique connections; both packaged Windows clients confirmed '$ServerMap'. Evidence: '$EvidencePath'."
}
finally {
	foreach ($Process in $Processes) {
		if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue }
		$Process.WaitForExit()
		$Process.Dispose()
	}
	Write-Evidence 'orchestrator' 'cleanup' 'process_cleanup_started' $EvidencePath 'Scanning for smoke-owned package processes.'
	$CleanupDeadline = [DateTime]::UtcNow.AddSeconds(10)
	$QuiescentSince = $null
	do {
		$NewPackageProcesses = @(Get-ProcessesUnderPath $ClientPackageRoot | Where-Object { -not (Test-IsPreexistingProcessIdentity $_ $PreexistingClientProcessIdentities) })
		if ($NewPackageProcesses.Count -gt 0) {
			$QuiescentSince = $null
			foreach ($Process in $NewPackageProcesses) {
				Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
				try { [void] $Process.WaitForExit(5000) } catch { }
				$Process.Dispose()
			}
		} elseif ($null -eq $QuiescentSince) {
			$QuiescentSince = [DateTime]::UtcNow
		} elseif (([DateTime]::UtcNow - $QuiescentSince).TotalSeconds -ge 2) {
			break
		}
		Start-Sleep -Milliseconds 100
	} while ([DateTime]::UtcNow -lt $CleanupDeadline)
	$RemainingPackageProcesses = @(Get-ProcessesUnderPath $ClientPackageRoot | Where-Object { -not (Test-IsPreexistingProcessIdentity $_ $PreexistingClientProcessIdentities) })
	if ($RemainingPackageProcesses.Count -gt 0 -or $null -eq $QuiescentSince -or ([DateTime]::UtcNow - $QuiescentSince).TotalSeconds -lt 2) {
		throw 'Packaged client process cleanup did not reach quiescence within 10 seconds.'
	}
	Write-Evidence 'orchestrator' 'cleanup' 'process_cleanup_complete' $EvidencePath 'No smoke-owned package processes remained after the quiescence window.'
}
