[CmdletBinding()]
param([Parameter(Mandatory)][string] $AttemptJson, [Parameter(Mandatory)][string] $RunnerJson,
	[Parameter(Mandatory)][string] $YamlAssemblyPath, [Parameter(Mandatory)][string] $EvidenceRoot,
	[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string] $ProofSha256)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Pins = @()
$ProofHandle = $null
try {
	. (Join-Path $PSScriptRoot 'InitialPreparation.Core.ps1')
	. (Join-Path $PSScriptRoot 'InitialPreparation.GitHub.ps1')
	. (Join-Path $PSScriptRoot 'InitialPreparation.Monitor.ps1')
	if ($AttemptJson.Length -gt 16384 -or $RunnerJson.Length -gt 16384) { throw 'monitor_input_invalid' }
	$Attempt = $AttemptJson | ConvertFrom-Json
	$Runner = $RunnerJson | ConvertFrom-Json
	Assert-InitialPreparationAttempt -Attempt $Attempt
	Assert-InitialPreparationPlainPath -Path $EvidenceRoot -Reason 'monitor_path_invalid'
	$Pins = Get-InitialPreparationDirectoryPin -Directory $EvidenceRoot
	Initialize-PreparationYaml -AssemblyPath $YamlAssemblyPath
	$ProofHandle = Get-InitialPreparationMonitorProof -EvidenceRoot $EvidenceRoot -Attempt $Attempt -Runner $Runner -ProofSha256 $ProofSha256
	$LastObserved = $ProofHandle.envelope.seedObservedTicks
	$ConditionalCache = New-PreparationConditionalCache -Attempt $Attempt
	# 330 minutes / minimum five-second cycle interval needs at most 3960
	# snapshots. 4096 is finite and does not truncate a healthy bounded attempt.
	for ($Sequence = 1; $Sequence -le 4096; $Sequence++) {
		if ((Get-InitialPreparationTick) -ge $Attempt.stopUsefulWorkTicks) { throw 'useful_work_deadline' }
		$Cycle = [pscustomobject][ordered]@{ schemaVersion = 2; sequence = $Sequence; attemptId = $Attempt.attemptId;
			startedTicks = 0L; finishedTicks = $null; requestCount = 0; phase = 'proof'; failureCode = $null;
			retryCount = 0; lastFailure = $null }
		# Leave five seconds for fail-closed reporting/owned cleanup; consumer
		# freshness stays exactly 60 seconds and no successful request resets it.
		$CycleDeadline = [long] [Math]::Min($Attempt.stopUsefulWorkTicks, $LastObserved + [long] (55 * $Attempt.monotonicFrequency))
		try {
			$Observation = Get-InitialPreparationRuntimeInventory -Runner $Runner -Proof $ProofHandle.envelope.proof -Attempt $Attempt -DeadlineTicks $CycleDeadline -CycleState $Cycle -ConditionalCache $ConditionalCache
			$Cycle.phase = 'snapshot'
			$Snapshot = ConvertTo-InitialPreparationMonitorSnapshot -Observation $Observation -Attempt $Attempt -Sequence $Sequence
			Assert-InitialPreparationMonitorSnapshot -Snapshot $Snapshot -Attempt $Attempt -Runner $Runner -Sequence $Sequence -NowTicks (Get-InitialPreparationTick)
			$Cycle.phase = 'complete'
		} catch {
			if ($null -eq $Cycle.failureCode) {
				$Cycle.failureCode = if ($_.Exception.Message -cin @('monitor_observation_invalid', 'monitor_observation_stale')) { $_.Exception.Message } else { 'monitor_cycle_failed' }
			}
			throw
		} finally {
			$Cycle.finishedTicks = Get-InitialPreparationTick
			$CycleBytes = [Text.Encoding]::UTF8.GetBytes(($Cycle | ConvertTo-Json -Depth 3 -Compress))
			if ($CycleBytes.Length -gt 2048) { throw 'monitor_diagnostic_limit' }
			$CycleStream = [IO.File]::Open((Join-Path $EvidenceRoot ('cycle-{0:D4}.json' -f $Sequence)), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
			try { $CycleStream.Write($CycleBytes, 0, $CycleBytes.Length); $CycleStream.Flush($true) } finally { $CycleStream.Dispose() }
		}
		$Bytes = [Text.Encoding]::UTF8.GetBytes(($Snapshot | ConvertTo-Json -Depth 4 -Compress))
		if ($Bytes.Length -gt 4096) { throw 'monitor_snapshot_invalid' }
		$Stream = [IO.File]::Open((Join-Path $EvidenceRoot ('snapshot-{0:D4}.json' -f $Sequence)), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
		try { $Stream.Write($Bytes, 0, $Bytes.Length); $Stream.Flush($true) } finally { $Stream.Dispose() }
		$LastObserved = $Snapshot.observedTicks
		Start-Sleep -Milliseconds (Get-PreparationMonitorDelayMilliseconds -Attempt $Attempt -StartedTicks $Cycle.startedTicks -NowTicks (Get-InitialPreparationTick))
	}
	throw 'monitor_sequence_exhausted'
} catch { exit 1 } finally {
	if ($null -ne $ProofHandle) {
		$ProofHandle.stream.Dispose(); $ProofHandle.handle.Dispose()
		foreach ($Pin in $ProofHandle.pins) { $Pin.Dispose() }
	}
	foreach ($Pin in $Pins) { $Pin.Dispose() }
}
