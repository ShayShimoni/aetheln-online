<#
.SYNOPSIS
Runs the replication-neutral packaged network-authority scenario and writes correlated evidence.

.DESCRIPTION
Starts one packaged server and two distinct packaged clients, observes the frozen authority
scenario through redirected process output, exercises disconnect/reconnect, cleans up processes,
and writes network-authority-spike-evidence.json. The caller supplies every runtime path,
scenario input, provenance identity, and observation pattern. This runner does not select a
replication candidate, latency policy, rewind policy, or numeric network profile.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerExecutable,
	[Parameter(Mandatory)] [string[]] $ServerArguments,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ClientExecutable,
	[Parameter(Mandatory)] [string[]] $ClientArguments,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerEndpoint,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerMap,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ScenarioId,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ProfileId,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SourceRevision,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $BuildIdentity,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ToolchainIdentity,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $HardwareIdentity,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $TopologyIdentity,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ActorMixIdentity,
	[Parameter(Mandatory)] [ValidateRange(1, 86400)] [int] $DurationSeconds,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $LogRoot,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerReadyPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerConnectionPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ClientReadyPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $MovementPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $EnemyPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $MeleePattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $DamagePattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RejectionPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $JoinInProgressPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $DisconnectPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ReconnectPattern,
	[ValidateNotNullOrEmpty()] [string] $ErrorPattern = '(?i)(fatal error|network\s+failure|connection\s+failed|failed to load package)',
	[ValidateRange(1, 3600)] [int] $TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

public sealed class AethelnProcessOutputCapture : IDisposable
{
	private readonly Process process;
	private readonly StreamWriter outputWriter;
	private readonly StreamWriter errorWriter;
	private readonly DataReceivedEventHandler outputHandler;
	private readonly DataReceivedEventHandler errorHandler;
	private bool disposed;

	public AethelnProcessOutputCapture(Process process, string outputPath, string errorPath)
	{
		this.process = process;
		outputWriter = new StreamWriter(outputPath, false, new UTF8Encoding(false));
		errorWriter = new StreamWriter(errorPath, false, new UTF8Encoding(false));
		outputWriter.AutoFlush = true;
		errorWriter.AutoFlush = true;
		outputHandler = OnOutputDataReceived;
		errorHandler = OnErrorDataReceived;
		process.OutputDataReceived += outputHandler;
		process.ErrorDataReceived += errorHandler;
	}

	private void OnOutputDataReceived(object sender, DataReceivedEventArgs eventArgs)
	{
		if (eventArgs.Data != null)
		{
			outputWriter.WriteLine(eventArgs.Data);
		}
	}

	private void OnErrorDataReceived(object sender, DataReceivedEventArgs eventArgs)
	{
		if (eventArgs.Data != null)
		{
			errorWriter.WriteLine(eventArgs.Data);
		}
	}

	public void Dispose()
	{
		if (disposed)
		{
			return;
		}

		disposed = true;
		process.OutputDataReceived -= outputHandler;
		process.ErrorDataReceived -= errorHandler;
		outputWriter.Dispose();
		errorWriter.Dispose();
	}
}
'@

function Resolve-Executable([string] $Name, [string] $Path) {
	if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Resolve-Path -LiteralPath $Path).Path }
	$Command = Get-Command $Path -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
	if (-not $Command) { throw "$Name '$Path' does not exist and is not available on PATH." }
	return [string] $Command.Source
}

function Initialize-EmptyLogRoot([string] $Path) {
	if (Test-Path -LiteralPath $Path) {
		if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "LogRoot '$Path' exists but is not a directory." }
		$Existing = @(Get-ChildItem -LiteralPath $Path -Force)
		if ($Existing.Count -gt 0) { throw "LogRoot '$Path' must be absent or empty; use a unique clean directory for every authority-spike run." }
	} else {
		New-Item -ItemType Directory -Path $Path | Out-Null
	}
	return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-Placeholder([string[]] $Arguments, [string] $Placeholder, [string] $Name) {
	if (($Arguments -join ' ') -notlike "*$Placeholder*") { throw "$Name must contain $Placeholder so scenario correlation is explicit." }
}

function Expand-Values([string] $Value, [string] $ClientId) {
	return $Value.Replace('{ClientId}', $ClientId).Replace('{ServerEndpoint}', $ServerEndpoint).Replace('{ServerMap}', $ServerMap).Replace('{ScenarioId}', $ScenarioId).Replace('{ProfileId}', $ProfileId).Replace('{RunId}', $RunId)
}

function Expand-Arguments([string[]] $Arguments, [string] $ClientId) {
	return @($Arguments | ForEach-Object { Expand-Values $_ $ClientId })
}

function Expand-Pattern([string] $Pattern, [string] $ClientId) {
	return $Pattern.Replace('{ClientId}', [regex]::Escape($ClientId)).Replace('{ServerEndpoint}', [regex]::Escape($ServerEndpoint)).Replace('{ServerMap}', [regex]::Escape($ServerMap)).Replace('{ScenarioId}', [regex]::Escape($ScenarioId)).Replace('{ProfileId}', [regex]::Escape($ProfileId)).Replace('{RunId}', [regex]::Escape($RunId))
}

function ConvertTo-ProcessArgument([string] $Argument) {
	$Quoted = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
	$Quoted = [regex]::Replace($Quoted, '(\\+)$', '$1$1')
	return '"' + $Quoted + '"'
}

function Start-HiddenProcess([string] $Executable, [string[]] $Arguments, [string] $StandardOutputPath, [string] $StandardErrorPath) {
	$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = $Executable
	$StartInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ')
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true

	$Process = [System.Diagnostics.Process]::new()
	$Process.StartInfo = $StartInfo
	$Capture = [AethelnProcessOutputCapture]::new($Process, $StandardOutputPath, $StandardErrorPath)
	try {
		if (-not $Process.Start()) { throw "Could not start '$Executable'." }
		$Process.BeginOutputReadLine()
		$Process.BeginErrorReadLine()
		return [pscustomobject]@{ Process = $Process; Capture = $Capture }
	}
	catch {
		$Capture.Dispose()
		$Process.Dispose()
		throw
	}
}

function Get-RuntimeError([string[]] $Paths) {
	foreach ($Path in $Paths) {
		if (Test-Path -LiteralPath $Path -PathType Leaf) {
			$ErrorLine = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Where-Object { $_ -match $ErrorPattern } | Select-Object -First 1
			if ($ErrorLine) { return [string] $ErrorLine }
		}
	}
	return $null
}

function Wait-ForMatch([System.Diagnostics.Process] $Process, [string] $Path, [string] $ErrorPath, [string] $Description, [string] $Pattern) {
	$Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
	do {
		$ErrorLine = Get-RuntimeError @($Path, $ErrorPath)
		if ($ErrorLine) { throw "Runtime reported an error while waiting for ${Description}: $ErrorLine" }
		if (Test-Path -LiteralPath $Path -PathType Leaf) {
			$Line = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Where-Object { $_ -match $Pattern } | Select-Object -First 1
			if ($Line) { return [string] $Line }
		}
		$Process.Refresh()
		if ($Process.HasExited) {
			$Process.WaitForExit()
			throw "Process exited with code $($Process.ExitCode) while waiting for $Description. Review '$Path' and '$ErrorPath'."
		}
		Start-Sleep -Milliseconds 100
	} while ([DateTime]::UtcNow -lt $Deadline)
	throw "Timed out after $TimeoutSeconds seconds waiting for $Description in '$Path' (pattern '$Pattern')."
}

function Wait-ForObservationInterval {
	param(
		[Parameter(Mandatory, Position = 0)] [object[]] $RequiredProcesses,
		[Parameter(Mandatory, Position = 1)] [int] $Seconds,
		[scriptblock] $UtcNow = { [DateTime]::UtcNow },
		[scriptblock] $Sleep = { param([int] $Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
	)

	$Deadline = (& $UtcNow).AddSeconds($Seconds)
	while ($true) {
		foreach ($Required in $RequiredProcesses) {
			$ErrorLine = Get-RuntimeError @($Required.StandardOutputPath, $Required.StandardErrorPath)
			if ($ErrorLine) { throw "Runtime '$($Required.Name)' reported an error during the observation interval: $ErrorLine" }
			$Required.Process.Refresh()
			if ($Required.Process.HasExited) {
				$Required.Process.WaitForExit()
				throw "Required process '$($Required.Name)' exited unexpectedly with code $($Required.Process.ExitCode) during the $Seconds-second observation interval. Review '$($Required.StandardOutputPath)' and '$($Required.StandardErrorPath)'."
			}
		}
		$RemainingMilliseconds = [Math]::Ceiling(($Deadline - (& $UtcNow)).TotalMilliseconds)
		if ($RemainingMilliseconds -le 0) { break }
		& $Sleep ([int] [Math]::Min(100, $RemainingMilliseconds))
	}
}

function New-Observation([string] $Event, [string] $Source, [string] $Detail, [string] $ClientId = '') {
	$Record = [ordered]@{ event = $Event; source = $Source; detail = $Detail }
	if ($ClientId) { $Record.client_id = $ClientId }
	return [pscustomobject] $Record
}

foreach ($Placeholder in @('{ServerEndpoint}','{ServerMap}','{ScenarioId}','{ProfileId}','{RunId}')) { Assert-Placeholder $ServerArguments $Placeholder 'ServerArguments' }
foreach ($Placeholder in @('{ClientId}','{ServerEndpoint}','{ServerMap}','{ScenarioId}','{ProfileId}','{RunId}')) { Assert-Placeholder $ClientArguments $Placeholder 'ClientArguments' }

$ConnectionRegex = [regex]::new((Expand-Pattern $ServerConnectionPattern ''))
if ($ConnectionRegex.GetGroupNames() -notcontains 'ClientId' -or $ConnectionRegex.GetGroupNames() -notcontains 'ConnectionId') { throw 'ServerConnectionPattern must contain named ClientId and ConnectionId captures.' }
$RejectionRegex = [regex]::new((Expand-Pattern $RejectionPattern ''))
if ($RejectionRegex.GetGroupNames() -notcontains 'Reason') { throw 'RejectionPattern must contain a named Reason capture.' }
$StableRejectionReasons = @('none','stale-sequence','duplicate-sequence','incompatible-version','timestamp-out-of-bounds','impossible-aim-transition','connection-closed','actor-destroyed','malformed-intent','activation-blocked')
$ReconnectRegex = [regex]::new((Expand-Pattern $ReconnectPattern 'client-1-reconnect'))
if ($ReconnectRegex.GetGroupNames() -notcontains 'ConnectionId') { throw 'ReconnectPattern must contain a named ConnectionId capture.' }

$ResolvedServer = Resolve-Executable 'ServerExecutable' $ServerExecutable
$ResolvedClient = Resolve-Executable 'ClientExecutable' $ClientExecutable
$ResolvedLogs = Initialize-EmptyLogRoot $LogRoot
$EvidencePath = Join-Path $ResolvedLogs 'network-authority-spike-evidence.json'
$Processes = [System.Collections.Generic.List[object]]::new()
$Lifecycle = [System.Collections.Generic.List[object]]::new()
$Observations = [System.Collections.Generic.List[object]]::new()
$Rejections = [System.Collections.Generic.List[object]]::new()
$Clients = [System.Collections.Generic.List[object]]::new()
$Result = 'failed'
$Failure = $null

try {
	$ServerStdOut = Join-Path $ResolvedLogs 'server.stdout.log'
	$ServerStdErr = Join-Path $ResolvedLogs 'server.stderr.log'
	$ExpandedServerArguments = Expand-Arguments $ServerArguments 'server'
	$ServerHandle = Start-HiddenProcess $ResolvedServer $ExpandedServerArguments $ServerStdOut $ServerStdErr
	$Processes.Add($ServerHandle)
	$ServerProcess = $ServerHandle.Process
	$ReadyLine = Wait-ForMatch $ServerProcess $ServerStdOut $ServerStdErr 'server readiness' (Expand-Pattern $ServerReadyPattern 'server')
	$Lifecycle.Add((New-Observation 'server_ready' $ServerStdOut $ReadyLine))

	$ClientProcesses = @{}
	foreach ($ClientId in @('client-1','client-2')) {
		$StdOut = Join-Path $ResolvedLogs "$ClientId.stdout.log"
		$StdErr = Join-Path $ResolvedLogs "$ClientId.stderr.log"
		$Handle = Start-HiddenProcess $ResolvedClient (Expand-Arguments $ClientArguments $ClientId) $StdOut $StdErr
		$Processes.Add($Handle)
		$ClientProcesses[$ClientId] = $Handle.Process
		$Clients.Add([pscustomobject]@{ id = $ClientId; role = 'initial_client' })
	}

	foreach ($ClientId in @('client-1','client-2')) {
		$StdOut = Join-Path $ResolvedLogs "$ClientId.stdout.log"
		$StdErr = Join-Path $ResolvedLogs "$ClientId.stderr.log"
		$Line = Wait-ForMatch $ClientProcesses[$ClientId] $StdOut $StdErr "$ClientId readiness" (Expand-Pattern $ClientReadyPattern $ClientId)
		$Lifecycle.Add((New-Observation 'client_ready' $StdOut $Line $ClientId))
		$MovementLine = Wait-ForMatch $ServerProcess $ServerStdOut $ServerStdErr "$ClientId movement" (Expand-Pattern $MovementPattern $ClientId)
		$Observations.Add((New-Observation 'movement' $ServerStdOut $MovementLine $ClientId))
	}

	$ServerLines = @(Get-Content -LiteralPath $ServerStdOut -ErrorAction SilentlyContinue)
	$Connections = @{}
	foreach ($Line in $ServerLines) {
		$Match = $ConnectionRegex.Match($Line)
		if ($Match.Success) { $Connections[$Match.Groups['ClientId'].Value] = $Match.Groups['ConnectionId'].Value }
	}
	if (@($Connections.Keys | Where-Object { $_ -in @('client-1','client-2') }).Count -ne 2) { throw 'Server did not expose distinct connection identities for both initial clients.' }

	$EnemyLine = Wait-ForMatch $ServerProcess $ServerStdOut $ServerStdErr 'authoritative enemy spawn' (Expand-Pattern $EnemyPattern 'server')
	$Observations.Add((New-Observation 'enemy_spawned' $ServerStdOut $EnemyLine))
	$MeleeLine = Wait-ForMatch $ServerProcess $ServerStdOut $ServerStdErr 'server-resolved melee' (Expand-Pattern $MeleePattern 'server')
	$Observations.Add((New-Observation 'melee_resolved' $ServerStdOut $MeleeLine))
	$DamageLine = Wait-ForMatch $ServerProcess $ServerStdOut $ServerStdErr 'authoritative damage' (Expand-Pattern $DamagePattern 'server')
	$Observations.Add((New-Observation 'damage_applied' $ServerStdOut $DamageLine))
	$JoinLine = Wait-ForMatch $ServerProcess $ServerStdOut $ServerStdErr 'join-in-progress state' (Expand-Pattern $JoinInProgressPattern 'client-2')
	$Lifecycle.Add((New-Observation 'join_in_progress' $ServerStdOut $JoinLine 'client-2'))
	$RejectionLine = Wait-ForMatch $ServerProcess $ServerStdOut $ServerStdErr 'invalid-claim rejection' (Expand-Pattern $RejectionPattern 'server')
	$RejectionMatch = $RejectionRegex.Match($RejectionLine)
	$RejectionReason = $RejectionMatch.Groups['Reason'].Value
	if ($RejectionReason -cnotin $StableRejectionReasons) { throw "Unsupported rejection reason '$RejectionReason'." }
	$Rejections.Add([pscustomobject]@{ reason = $RejectionReason; source = $ServerStdOut; detail = $RejectionLine })

	Stop-Process -Id $ClientProcesses['client-1'].Id -Force
	$ClientProcesses['client-1'].WaitForExit()
	$DisconnectLine = Wait-ForMatch $ServerProcess $ServerStdOut $ServerStdErr 'disconnect cleanup' (Expand-Pattern $DisconnectPattern 'client-1')
	$Lifecycle.Add((New-Observation 'disconnect' $ServerStdOut $DisconnectLine 'client-1'))

	$ReconnectId = 'client-1-reconnect'
	$ReconnectStdOut = Join-Path $ResolvedLogs "$ReconnectId.stdout.log"
	$ReconnectStdErr = Join-Path $ResolvedLogs "$ReconnectId.stderr.log"
	$ReconnectHandle = Start-HiddenProcess $ResolvedClient (Expand-Arguments $ClientArguments $ReconnectId) $ReconnectStdOut $ReconnectStdErr
	$Processes.Add($ReconnectHandle)
	$ReconnectProcess = $ReconnectHandle.Process
	$Clients.Add([pscustomobject]@{ id = $ReconnectId; role = 'reconnect_client' })
	[void] (Wait-ForMatch $ReconnectProcess $ReconnectStdOut $ReconnectStdErr 'reconnect client readiness' (Expand-Pattern $ClientReadyPattern $ReconnectId))
	$ReconnectLine = Wait-ForMatch $ServerProcess $ServerStdOut $ServerStdErr 'new reconnect identity' (Expand-Pattern $ReconnectPattern $ReconnectId)
	$ReconnectMatch = $ReconnectRegex.Match($ReconnectLine)
	if ($ReconnectMatch.Groups['ConnectionId'].Value -eq $Connections['client-1']) { throw 'Reconnect reused the disconnected connection identity.' }
	$Lifecycle.Add([pscustomobject]@{ event = 'reconnect'; client_id = $ReconnectId; connection_id = $ReconnectMatch.Groups['ConnectionId'].Value; source = $ServerStdOut; detail = $ReconnectLine })

	Wait-ForObservationInterval @(
		[pscustomobject]@{ Name = 'server'; Process = $ServerProcess; StandardOutputPath = $ServerStdOut; StandardErrorPath = $ServerStdErr },
		[pscustomobject]@{ Name = 'client-2'; Process = $ClientProcesses['client-2']; StandardOutputPath = (Join-Path $ResolvedLogs 'client-2.stdout.log'); StandardErrorPath = (Join-Path $ResolvedLogs 'client-2.stderr.log') },
		[pscustomobject]@{ Name = $ReconnectId; Process = $ReconnectProcess; StandardOutputPath = $ReconnectStdOut; StandardErrorPath = $ReconnectStdErr }
	) $DurationSeconds
	$Result = 'passed'
}
catch {
	$Failure = $_.Exception.Message
	throw
}
finally {
	foreach ($Handle in $Processes) {
		$Process = $Handle.Process
		try {
			if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue }
			$Process.WaitForExit()
			try { $Process.CancelOutputRead() } catch { }
			try { $Process.CancelErrorRead() } catch { }
		} catch { }
		$Handle.Capture.Dispose()
		$Process.Dispose()
	}
	$Evidence = [ordered]@{
		schema_id = 'aetheln.network-authority-evidence'
		schema_version = 1
		run_id = $RunId
		result = $Result
		failure = $Failure
		scenario = [ordered]@{ id = $ScenarioId; validation_mode = 'present_time'; action_family = 'melee'; map = $ServerMap; duration_seconds = $DurationSeconds; actor_mix = $ActorMixIdentity; seed = $RunId }
		provenance = [ordered]@{ source_revision = $SourceRevision; build = $BuildIdentity; toolchain = $ToolchainIdentity; hardware = $HardwareIdentity; topology = $TopologyIdentity }
		network_profile = [ordered]@{ schema_id = 'aetheln.network-profile'; schema_version = 1; id = $ProfileId; latency_ms = $null; jitter_ms = $null; loss_percent = $null; duplication_percent = $null; reorder_percent = $null; server_tick_hz = $null; history_ms = $null; bandwidth_limit_kbps = $null; capacity_players = $null }
		clients = @($Clients)
		lifecycle = @($Lifecycle)
		observations = @($Observations)
		rejections = @($Rejections)
		measurements = [ordered]@{
			server_game_thread_milliseconds = $null
			server_replication_cpu_milliseconds = $null
			client_memory_bytes = $null
			server_memory_bytes = $null
			bandwidth_per_connection_bits_per_second = $null
			aggregate_bandwidth_bits_per_second = $null
			correction_count = $null
			correction_magnitude_centimeters = $null
			relevant_actor_count = $null
			destruction_event_count = $null
			implementation_complexity = $null
			failure_behavior = $null
		}
		unsupported_capabilities = @('projectile','block','dodge','rewind')
	}
	$Evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
}

Write-Output "Network authority spike passed. Evidence: '$EvidencePath'."
