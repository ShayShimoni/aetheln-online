[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Script = Join-Path $RepositoryRoot 'scripts/build/Invoke-NetworkAuthoritySpike.ps1'
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("AethelnAuthoritySpikeTests-{0}" -f [guid]::NewGuid().ToString('N'))

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

try {
	New-Item -ItemType Directory -Path $FixtureRoot | Out-Null
	$RunnerSource = Get-Content -LiteralPath $Script -Raw
	Assert-True ($RunnerSource -match 'ProcessStartInfo') 'The runner must launch runtime children through ProcessStartInfo.'
	Assert-True ($RunnerSource -match 'UseShellExecute\s*=\s*\$false') 'Runtime child launches must disable shell execution.'
	Assert-True ($RunnerSource -match 'CreateNoWindow\s*=\s*\$true') 'Runtime child launches must not create windows.'
	Assert-True ($RunnerSource -notmatch '\bStart-Process\b') 'The runner must not launch runtime children through Start-Process.'

	$RunnerTokens = $null
	$RunnerParseErrors = $null
	$RunnerAst = [System.Management.Automation.Language.Parser]::ParseInput($RunnerSource, [ref] $RunnerTokens, [ref] $RunnerParseErrors)
	Assert-True ($RunnerParseErrors.Count -eq 0) 'The network-authority runner must parse without PowerShell syntax errors.'
	$ObservationFunctionAst = $RunnerAst.Find({
		param($Ast)
		$Ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
		$Ast.Name -eq 'Wait-ForObservationInterval'
	}, $true)
	Assert-True ($null -ne $ObservationFunctionAst) 'The runner must define Wait-ForObservationInterval.'

	$BoundaryFailure = & {
		param([string] $FunctionSource)

		function Get-RuntimeError([string[]] $Paths) { return $null }
		Invoke-Expression $FunctionSource

		$Clock = [pscustomobject]@{ UtcNow = [DateTime]::Parse('2026-08-12T00:00:00Z').ToUniversalTime() }
		$ProcessState = [pscustomobject]@{ HasExited = $false; ExitCode = 0 }
		$ProcessState | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
		$ProcessState | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { }
		$RequiredProcess = [pscustomobject]@{
			Name = 'boundary-runtime'
			Process = $ProcessState
			StandardOutputPath = 'boundary.stdout.log'
			StandardErrorPath = 'boundary.stderr.log'
		}
		$BoundaryState = [pscustomobject]@{ SleepCount = 0 }
		$UtcNow = { $Clock.UtcNow }.GetNewClosure()
		$Sleep = {
			param([int] $Milliseconds)
			$BoundaryState.SleepCount++
			$Clock.UtcNow = $Clock.UtcNow.AddMilliseconds($Milliseconds)
			if ($Clock.UtcNow -ge [DateTime]::Parse('2026-08-12T00:00:01Z').ToUniversalTime()) {
				$ProcessState.HasExited = $true
			}
		}.GetNewClosure()

		try {
			Wait-ForObservationInterval @($RequiredProcess) 1 -UtcNow $UtcNow -Sleep $Sleep
			return [pscustomobject]@{ Message = $null; SleepCount = $BoundaryState.SleepCount }
		}
		catch {
			return [pscustomobject]@{ Message = $_.Exception.Message; SleepCount = $BoundaryState.SleepCount }
		}
	} $ObservationFunctionAst.Extent.Text
	Assert-True ($BoundaryFailure.SleepCount -eq 10) 'The deterministic boundary fixture must reach the final 100 ms polling sleep.'
	Assert-True ($BoundaryFailure.Message -match "Required process 'boundary-runtime' exited unexpectedly with code 0 during the 1-second observation interval") 'A required process that exits during the final polling sleep must be rejected by the post-sleep health check.'
	Write-Output 'PASS: final polling-sleep exits are rejected by a deterministic post-sleep health check'

	$PowerShellExecutable = (Get-Process -Id $PID).Path
	$FakeRuntime = Join-Path $FixtureRoot 'fake-runtime.ps1'
	Set-Content -LiteralPath $FakeRuntime -Encoding UTF8 -Value @'
param(
	[string] $Role,
	[string] $ClientId,
	[string] $Endpoint,
	[string] $Map,
	[string] $ScenarioId,
	[string] $ProfileId,
	[string] $RunId,
	[string] $RejectionReason = 'duplicate-sequence',
	[string] $ExitAfterMarkers = 'false'
)
if ($Role -eq 'server') {
	Write-Output "AUTHORITY server_ready endpoint=$Endpoint map=$Map scenario=$ScenarioId profile=$ProfileId run=$RunId"
	Write-Output 'AUTHORITY connection client=client-1 connection=connection-1'
	Write-Output 'AUTHORITY connection client=client-2 connection=connection-2'
	Write-Output 'AUTHORITY movement client=client-1'
	Write-Output 'AUTHORITY movement client=client-2'
	Write-Output 'AUTHORITY enemy_spawned enemy=spike-enemy-1'
	Write-Output 'AUTHORITY melee_resolved attacker=client-1 enemy=spike-enemy-1'
	Write-Output 'AUTHORITY damage_applied enemy=spike-enemy-1'
	Write-Output "AUTHORITY rejection reason=$RejectionReason client=client-2"
	Write-Output 'AUTHORITY join_in_progress client=client-2 enemy=spike-enemy-1'
	Write-Output 'AUTHORITY disconnected client=client-1 connection=connection-1'
	Write-Output 'AUTHORITY connection client=client-1-reconnect connection=connection-3'
	Write-Output 'AUTHORITY reconnected client=client-1-reconnect connection=connection-3'
	if ($ExitAfterMarkers -eq 'true') {
		Start-Sleep -Seconds 1
		exit 0
	}
	while ($true) { Start-Sleep -Milliseconds 50 }
}
Write-Output "AUTHORITY client_ready client=$ClientId endpoint=$Endpoint map=$Map"
Start-Sleep -Seconds 30
'@

	function Invoke-FixtureRun(
		[string] $FixtureLogRoot,
		[string] $FixtureRunId,
		[string] $RejectionReason,
		[int] $DurationSeconds = 5,
		[bool] $ExitAfterMarkers = $false
	) {
		& $Script `
			-ServerExecutable $PowerShellExecutable `
			-ServerArguments @('-NoProfile', '-File', $FakeRuntime, 'server', 'server', '{ServerEndpoint}', '{ServerMap}', '{ScenarioId}', '{ProfileId}', '{RunId}', $RejectionReason, $ExitAfterMarkers.ToString().ToLowerInvariant()) `
			-ClientExecutable $PowerShellExecutable `
			-ClientArguments @('-NoProfile', '-File', $FakeRuntime, 'client', '{ClientId}', '{ServerEndpoint}', '{ServerMap}', '{ScenarioId}', '{ProfileId}', '{RunId}') `
			-ServerEndpoint '127.0.0.1:7777' `
			-ServerMap '/Game/Maps/StarterMap' `
			-ScenarioId 'network-authority.baseline.v1' `
			-ProfileId 'network-profile.unset' `
			-RunId $FixtureRunId `
			-SourceRevision 'fixture-revision' `
			-BuildIdentity 'fixture-build' `
			-ToolchainIdentity 'UE-5.8.1-fixture' `
			-HardwareIdentity 'fixture-host' `
			-TopologyIdentity 'one-server-two-clients-local-fixture' `
			-ActorMixIdentity 'network-authority.actor-mix.v1' `
			-DurationSeconds $DurationSeconds `
			-LogRoot $FixtureLogRoot `
			-ServerReadyPattern 'AUTHORITY server_ready.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}' `
			-ServerConnectionPattern 'AUTHORITY connection client=(?<ClientId>[^ ]+) connection=(?<ConnectionId>[^ ]+)' `
			-ClientReadyPattern 'AUTHORITY client_ready client={ClientId}.*map={ServerMap}' `
			-MovementPattern 'AUTHORITY movement client={ClientId}' `
			-EnemyPattern 'AUTHORITY enemy_spawned enemy=' `
			-MeleePattern 'AUTHORITY melee_resolved attacker=' `
			-DamagePattern 'AUTHORITY damage_applied enemy=' `
			-RejectionPattern 'AUTHORITY rejection reason=(?<Reason>[^ ]+)' `
			-JoinInProgressPattern 'AUTHORITY join_in_progress client=client-2' `
			-DisconnectPattern 'AUTHORITY disconnected client=client-1' `
			-ReconnectPattern 'AUTHORITY reconnected client=client-1-reconnect connection=(?<ConnectionId>[^ ]+)' `
			-TimeoutSeconds 8
	}

	$LogRoot = Join-Path $FixtureRoot 'success'
	$SuccessStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
	Invoke-FixtureRun $LogRoot 'fixture-run-001' 'duplicate-sequence'
	$SuccessStopwatch.Stop()
	Assert-True ($SuccessStopwatch.Elapsed.TotalSeconds -ge 5) 'The successful fixture must sustain execution for the requested five-second observation interval.'

	$EvidencePath = Join-Path $LogRoot 'network-authority-spike-evidence.json'
	Assert-True (Test-Path -LiteralPath $EvidencePath -PathType Leaf) 'The runner must emit one machine-readable evidence document.'
	$Evidence = Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json
	Assert-True ($Evidence.schema_id -eq 'aetheln.network-authority-evidence') 'Evidence must use the canonical schema identity.'
	Assert-True ($Evidence.schema_version -eq 1) 'Evidence must use schema version 1.'
	Assert-True ($Evidence.scenario.id -eq 'network-authority.baseline.v1') 'Evidence must preserve immutable scenario identity.'
	Assert-True ($Evidence.scenario.map -eq '/Game/Maps/StarterMap' -and $Evidence.scenario.duration_seconds -eq 5) 'Map and duration must be correlated.'
	Assert-True ($Evidence.scenario.actor_mix -eq 'network-authority.actor-mix.v1') 'Actor mix must be correlated.'
	Assert-True ($Evidence.provenance.source_revision -eq 'fixture-revision' -and $Evidence.provenance.build -eq 'fixture-build') 'Source and build provenance must be explicit.'
	Assert-True ($Evidence.provenance.toolchain -eq 'UE-5.8.1-fixture' -and $Evidence.provenance.hardware -eq 'fixture-host') 'Toolchain and hardware provenance must be explicit.'
	Assert-True ($Evidence.provenance.topology -eq 'one-server-two-clients-local-fixture') 'Topology must be explicit.'
	Assert-True ($Evidence.network_profile.schema_id -eq 'aetheln.network-profile' -and $Evidence.network_profile.schema_version -eq 1) 'Network profile schema identity and version must be stable.'
	Assert-True ($Evidence.network_profile.id -eq 'network-profile.unset') 'Profile identity must be stable.'
	foreach ($Field in @('latency_ms','jitter_ms','loss_percent','duplication_percent','reorder_percent','server_tick_hz','history_ms','bandwidth_limit_kbps','capacity_players')) {
		Assert-True ($null -eq $Evidence.network_profile.$Field) "$Field must remain null when unavailable."
	}
	Assert-True (@($Evidence.clients | Where-Object { $_.id -in @('client-1','client-2') } | Select-Object -ExpandProperty id -Unique).Count -eq 2) 'Two distinct initial client identities are required.'
	Assert-True (@($Evidence.lifecycle | Where-Object { $_.event -eq 'server_ready' }).Count -eq 1) 'Server readiness must be observed.'
	Assert-True (@($Evidence.lifecycle | Where-Object { $_.event -eq 'disconnect' }).Count -eq 1) 'Disconnect must be observed.'
	Assert-True (@($Evidence.lifecycle | Where-Object { $_.event -eq 'reconnect' -and $_.client_id -eq 'client-1-reconnect' }).Count -eq 1) 'Reconnect must use a new client identity.'
	Assert-True (@($Evidence.observations | Where-Object { $_.event -eq 'movement' }).Count -eq 2) 'Movement must be observed for both clients.'
	Assert-True (@($Evidence.observations | Where-Object { $_.event -eq 'melee_resolved' }).Count -eq 1) 'One server-resolved melee observation is required.'
	Assert-True (@($Evidence.observations | Where-Object { $_.event -eq 'damage_applied' }).Count -eq 1) 'Authoritative damage must be observed.'
	Assert-True (@($Evidence.rejections | Where-Object { $_.reason -eq 'duplicate-sequence' }).Count -eq 1) 'An observable stable invalid-claim rejection is required.'
	$MeasurementFields = @(
		'server_game_thread_milliseconds',
		'server_replication_cpu_milliseconds',
		'client_memory_bytes',
		'server_memory_bytes',
		'bandwidth_per_connection_bits_per_second',
		'aggregate_bandwidth_bits_per_second',
		'correction_count',
		'correction_magnitude_centimeters',
		'relevant_actor_count',
		'destruction_event_count',
		'implementation_complexity',
		'failure_behavior'
	)
	$ActualMeasurementFields = @($Evidence.measurements.PSObject.Properties.Name)
	Assert-True ($ActualMeasurementFields.Count -eq $MeasurementFields.Count) 'Measurements must contain exactly the canonical 12 fields.'
	Assert-True (@(Compare-Object ($ActualMeasurementFields | Sort-Object) ($MeasurementFields | Sort-Object)).Count -eq 0) 'Measurement field names must match FAethelnNetworkSpikeMeasurements exactly.'
	foreach ($Field in $MeasurementFields) {
		Assert-True ($null -eq $Evidence.measurements.$Field) "$Field must be explicit null when capture is unavailable."
	}
	Assert-True ($Evidence.result -eq 'passed') 'A complete fixture scenario must pass.'
	Start-Sleep -Milliseconds 200
	$PowerShellExecutableName = [System.IO.Path]::GetFileName($PowerShellExecutable)
	$FixtureProcesses = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $PID" -ErrorAction Stop | Where-Object {
		$_.Name -eq $PowerShellExecutableName
	})
	$UninspectableFixtureProcesses = @($FixtureProcesses | Where-Object {
		-not $_.ExecutablePath -or -not $_.CommandLine
	})
	Assert-True ($UninspectableFixtureProcesses.Count -eq 0) 'Runner-owned fixture process command lines must remain inspectable for cleanup verification.'
	$OwnedProcesses = @($FixtureProcesses | Where-Object {
		$_.ExecutablePath -eq $PowerShellExecutable -and
		$_.CommandLine.IndexOf($FakeRuntime, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
	})
	Assert-True ($OwnedProcesses.Count -eq 0) 'Runner-owned fixture processes must be cleaned up.'
	Write-Output 'PASS: authority spike runner correlates lifecycle, authority, rejection, provenance, null measurements, observation duration, and cleanup evidence'

	$EarlyExitLogRoot = Join-Path $FixtureRoot 'early-exit-after-markers'
	$EarlyExitFailure = $null
	try {
		Invoke-FixtureRun $EarlyExitLogRoot 'fixture-early-exit' 'duplicate-sequence' 3 $true
	} catch { $EarlyExitFailure = $_.Exception.Message }
	Assert-True ($EarlyExitFailure -match "Required process 'server' exited unexpectedly with code 0 during the 3-second observation interval") 'A server that exits after emitting all markers must fail during the requested observation interval.'
	$EarlyExitEvidencePath = Join-Path $EarlyExitLogRoot 'network-authority-spike-evidence.json'
	Assert-True (Test-Path -LiteralPath $EarlyExitEvidencePath -PathType Leaf) 'An early required-process exit must still write evidence.'
	$EarlyExitEvidence = Get-Content -LiteralPath $EarlyExitEvidencePath -Raw | ConvertFrom-Json
	Assert-True ($EarlyExitEvidence.result -eq 'failed') 'An early required-process exit must produce failed evidence.'
	Assert-True ($EarlyExitEvidence.failure -match "Required process 'server' exited unexpectedly with code 0 during the 3-second observation interval") 'Failed evidence must preserve the early-exit reason.'
	Write-Output 'PASS: a runtime child that exits after all markers is rejected during the observation interval'

	$ActivationBlockedLogRoot = Join-Path $FixtureRoot 'accepted-activation-blocked'
	Invoke-FixtureRun $ActivationBlockedLogRoot 'fixture-activation-blocked' 'activation-blocked'
	$ActivationBlockedEvidence = Get-Content -LiteralPath (Join-Path $ActivationBlockedLogRoot 'network-authority-spike-evidence.json') -Raw | ConvertFrom-Json
	Assert-True ($ActivationBlockedEvidence.result -eq 'passed') 'The stable activation-blocked reason must be accepted.'
	Assert-True (@($ActivationBlockedEvidence.rejections | Where-Object { $_.reason -eq 'activation-blocked' }).Count -eq 1) 'Activation refusal evidence must preserve the stable activation-blocked reason.'

	foreach ($InvalidReason in @('duplicate_sequence', 'unknown-reason')) {
		$InvalidReasonLogRoot = Join-Path $FixtureRoot "invalid-rejection-$InvalidReason"
		$RejectionFailure = $null
		try {
			Invoke-FixtureRun $InvalidReasonLogRoot "fixture-$InvalidReason" $InvalidReason
		} catch { $RejectionFailure = $_.Exception.Message }
		Assert-True ($RejectionFailure -match [regex]::Escape("Unsupported rejection reason '$InvalidReason'.")) "Rejection reason '$InvalidReason' must fail closed."
		$InvalidEvidence = Get-Content -LiteralPath (Join-Path $InvalidReasonLogRoot 'network-authority-spike-evidence.json') -Raw | ConvertFrom-Json
		Assert-True ($InvalidEvidence.result -eq 'failed') "Invalid rejection reason '$InvalidReason' must produce failed evidence."
		Assert-True (@($InvalidEvidence.rejections | Where-Object { $_.reason -eq $InvalidReason }).Count -eq 0) "Invalid rejection reason '$InvalidReason' must not be accepted into evidence."
	}
	Write-Output 'PASS: rejection reason vocabulary accepts stable hyphenated values and rejects unsafe spellings'

	$Failure = $null
	try {
		& $Script -ServerExecutable $PowerShellExecutable -ServerArguments @('{ServerEndpoint}', '{ServerMap}') -ClientExecutable $PowerShellExecutable -ClientArguments @('{ClientId}') -ServerEndpoint '127.0.0.1:7777' -ServerMap '/Game/Maps/StarterMap' -ScenarioId 'network-authority.baseline.v1' -ProfileId 'network-profile.unset' -RunId 'invalid' -SourceRevision 'revision' -BuildIdentity 'build' -ToolchainIdentity 'toolchain' -HardwareIdentity 'hardware' -TopologyIdentity 'topology' -ActorMixIdentity 'network-authority.actor-mix.v1' -DurationSeconds 1 -LogRoot (Join-Path $FixtureRoot 'invalid') -ServerReadyPattern 'ready' -ServerConnectionPattern 'connection' -ClientReadyPattern 'ready' -MovementPattern 'movement' -EnemyPattern 'enemy' -MeleePattern 'melee' -DamagePattern 'damage' -RejectionPattern 'rejection' -JoinInProgressPattern 'join' -DisconnectPattern 'disconnect' -ReconnectPattern 'reconnect'
	} catch { $Failure = $_.Exception.Message }
	Assert-True ($Failure -match 'ServerArguments must contain.*ScenarioId') 'Missing correlation placeholders must fail before launch.'
	Write-Output 'PASS: incomplete launch correlation fails closed'
}
finally {
	foreach ($FixtureProcess in @(Get-Process -ErrorAction SilentlyContinue)) {
		try { $ProcessPath = [string] $FixtureProcess.Path } catch { continue }
		if ($ProcessPath -and $ProcessPath.StartsWith($FixtureRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
			Stop-Process -Id $FixtureProcess.Id -Force -ErrorAction SilentlyContinue
		}
	}
	if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
}
