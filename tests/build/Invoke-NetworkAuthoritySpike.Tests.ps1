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
	Assert-True ($RunnerSource -match 'ServerLauncherExecutable') 'The runner must support an explicit Linux-server launcher executable.'
	Assert-True ($RunnerSource -match 'ServerLauncherArguments') 'The runner must support explicit Linux-server launcher arguments.'
	Assert-True ($RunnerSource -match 'ServerIdentityArguments') 'The runner must authenticate the exact launcher-side server executable.'
	Assert-True ($RunnerSource -match 'ServerCleanupArguments') 'The runner must own launcher-side descendant cleanup.'
	Assert-True ($RunnerSource -match 'ServerProcessIdPattern') 'The runner must capture a launcher-side descendant process identity.'
	Assert-True ($RunnerSource -match 'RequiredRejectionCategories') 'The runner must fail closed unless every required invalid-claim category is observed.'

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

	$CaptureDisposeIndex = $RunnerSource.LastIndexOf('$Handle.Capture.Dispose()', [System.StringComparison]::Ordinal)
	$FinalInventoryIndex = $RunnerSource.LastIndexOf('Assert-ExactRejectionInventory @($FinalServerLines + $FinalServerErrorLines)', [System.StringComparison]::Ordinal)
	$SuccessfulResultIndex = $RunnerSource.LastIndexOf("`$Result = if (`$EvidenceMode -ceq 'packaged')", [System.StringComparison]::Ordinal)
	$EvidenceWriteIndex = $RunnerSource.LastIndexOf('$Evidence | ConvertTo-Json', [System.StringComparison]::Ordinal)
	Assert-True ($CaptureDisposeIndex -ge 0) 'The runner must close and drain process captures.'
	Assert-True ($FinalInventoryIndex -gt $CaptureDisposeIndex) 'The final rejection inventory must be validated only after every process capture is closed and drained.'
	Assert-True ($SuccessfulResultIndex -gt $FinalInventoryIndex) 'A successful result must be assigned only after final rejection-inventory validation.'
	Assert-True ($EvidenceWriteIndex -gt $SuccessfulResultIndex) 'Evidence must be written only after final rejection-inventory validation and result assignment.'
	Write-Output 'PASS: cleanup-boundary rejection validation runs after capture drain and before success publication'

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
	[string] $NetworkConfigIdentity,
	[string] $Environment,
	[string] $Behavior = 'normal',
	[string] $RejectionReason = 'duplicate-sequence',
	[string] $ExitAfterMarkers = 'false'
)
if ($Role -eq 'server') {
	$Identity = "scenario=$ScenarioId profile=$ProfileId run=$RunId"
	Write-Output "AUTHORITY server_ready endpoint=$Endpoint map=$Map network_config=$NetworkConfigIdentity $Identity"
	Write-Output "AUTHORITY network_config network_config=$NetworkConfigIdentity $Identity"
	Write-Output "AUTHORITY enemy_spawned enemy=spike-enemy-1 $Identity"
	Write-Output "AUTHORITY connection client=client-1 connection=connection-1 $Identity"
	Write-Output "AUTHORITY connection client=client-2 connection=connection-2 $Identity"
	Write-Output "AUTHORITY movement client=client-1 $Identity"
	Write-Output "AUTHORITY movement client=client-2 $Identity"
	if ($Behavior -eq 'reordered') { Write-Output "AUTHORITY damage_applied attacker=client-1 enemy=spike-enemy-1 $Identity" }
	Write-Output "AUTHORITY melee_resolved attacker=client-1 enemy=spike-enemy-1 $Identity"
	if ($Behavior -ne 'missing-damage' -and $Behavior -ne 'reordered') {
		$DamageIdentity = if ($Behavior -eq 'mismatched-run') { "scenario=$ScenarioId profile=$ProfileId run=another-run" } else { $Identity }
		Write-Output "AUTHORITY damage_applied attacker=client-1 enemy=spike-enemy-1 $DamageIdentity"
		if ($Behavior -eq 'duplicate-damage') { Write-Output "AUTHORITY damage_applied attacker=client-1 enemy=spike-enemy-1 $DamageIdentity" }
	}
	$StructuredSequence = 1
	foreach ($Category in @('movement','aim','activation','hit','cooldown','dodge','block','resource','death','respawn')) {
		$Reason = if ($Category -eq 'aim') { 'impossible-aim-transition' } elseif ($Category -in @('activation','cooldown','dodge','block')) { 'activation-blocked' } else { 'malformed-intent' }
		if ($Category -eq 'movement') { $Reason = $RejectionReason }
		Write-Output "AUTHORITY rejection category=$Category reason=$Reason client=client-2 $Identity"
		$StructuredSubject = if ($Category -eq 'activation') { 'ability' } else { $Category }
		$StructuredReason = if ($Reason -eq 'malformed-intent') { 'malformed-request' } else { $Reason }
		Write-Output "LogAethelnObservability: event schema=`"aetheln.observability-event`" version=1 category=`"rejection`" subject=`"$StructuredSubject`" reason=`"$StructuredReason`" flow=`"prototype-authority`" run=`"$RunId`" connection=`"connection-2`" instance=`"network-authority-server`" activation=`"`" ability=`"Ability.Melee.Combo1`" sequence=$StructuredSequence source_revision=`"fixture-revision`" build=`"fixture-build`" configuration=`"Development`" engine=`"5.8.1-fixture`" toolchain=`"UE-5.8.1-fixture`" network_profile=`"$ProfileId`""
		++$StructuredSequence
	}
	Write-Output "LogAethelnObservability: metric name=`"rejection-count`" category=`"movement`" reason=`"malformed-request`" environment=`"$Environment`" value=1"
	$ReconnectConnection = if ($Behavior -eq 'reused-connection') { 'connection-1' } else { 'connection-3' }
	if ($Behavior -eq 'reordered-lifecycle') {
		Write-Output "AUTHORITY connection client=client-1-reconnect connection=$ReconnectConnection $Identity"
		Write-Output "AUTHORITY reconnected client=client-1-reconnect connection=$ReconnectConnection $Identity"
	}
	if ($Behavior -ne 'missing-disconnect') {
		Write-Output "AUTHORITY disconnected client=client-1 connection=connection-1 $Identity"
	}
	if ($Behavior -eq 'fabricated-disconnected-command') {
		Write-Output "AUTHORITY rejection category=disconnected-command reason=connection-closed client=client-1 $Identity"
	}
	if ($Behavior -eq 'fabricated-disconnected-command-stderr') {
		[Console]::Error.WriteLine("AUTHORITY rejection category=disconnected-command reason=connection-closed client=client-1 $Identity")
	}
	if ($Behavior -eq 'unexpected-rejection-category') {
		Write-Output "AUTHORITY rejection category=unexpected reason=malformed-intent client=client-2 $Identity"
		Write-Output "LogAethelnObservability: event schema=`"aetheln.observability-event`" version=1 category=`"rejection`" subject=`"unexpected`" reason=`"malformed-request`" flow=`"prototype-authority`" run=`"$RunId`" connection=`"connection-2`" instance=`"network-authority-server`" activation=`"`" ability=`"Ability.Melee.Combo1`" sequence=99 source_revision=`"fixture-revision`" build=`"fixture-build`" configuration=`"Development`" engine=`"5.8.1-fixture`" toolchain=`"UE-5.8.1-fixture`" network_profile=`"$ProfileId`""
	}
	if ($Behavior -ne 'missing-reconnect' -and $Behavior -ne 'reordered-lifecycle') {
		Write-Output "AUTHORITY connection client=client-1-reconnect connection=$ReconnectConnection $Identity"
		Write-Output "AUTHORITY reconnected client=client-1-reconnect connection=$ReconnectConnection $Identity"
	}
	if ($Behavior -eq 'delayed-fabricated-disconnected-command') {
		Start-Sleep -Milliseconds 750
		Write-Output "AUTHORITY rejection category=disconnected-command reason=connection-closed client=client-1 $Identity"
	}
	if ($ExitAfterMarkers -eq 'true') {
		Start-Sleep -Seconds 1
		exit 0
	}
	while ($true) { Start-Sleep -Milliseconds 50 }
}
Write-Output "AUTHORITY client_ready client=$ClientId endpoint=$Endpoint map=$Map scenario=$ScenarioId profile=$ProfileId run=$RunId"
if ($ClientId -eq 'client-2') { Write-Output "AUTHORITY join_in_progress client=client-2 enemy=spike-enemy-1 scenario=$ScenarioId profile=$ProfileId run=$RunId" }
Start-Sleep -Seconds 30
'@
	$FakeLauncher = Join-Path $FixtureRoot 'fake-launcher.ps1'
Set-Content -LiteralPath $FakeLauncher -Encoding UTF8 -Value @'
param([string] $Mode, [string] $Target, [Parameter(ValueFromRemainingArguments)] [string[]] $Remaining)
if ($Mode -eq 'identity') {
	Write-Output ((Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $Target)
	exit 0
}
if ($Mode -eq 'cleanup') {
	$TargetProcess = Get-Process -Id ([int] $Target) -ErrorAction SilentlyContinue
	if ($TargetProcess) {
		Stop-Process -Id $TargetProcess.Id -Force
		$TargetProcess.WaitForExit()
	}
	if (Get-Process -Id ([int] $Target) -ErrorAction SilentlyContinue) { exit 43 }
	if ($env:AETHELN_TEST_CLEANUP_FAIL -eq 'true') { exit 42 }
	Write-Output "AETHELN_SERVER_DESCENDANT_EXITED=$Target"
	exit 0
}
if ($Mode -ne 'launch') { throw "Unsupported launcher mode '$Mode'." }
if ($env:AETHELN_TEST_LAUNCHER_FAIL -eq 'true') { exit 41 }
$Child = Start-Process -FilePath $Target -ArgumentList $Remaining -PassThru -NoNewWindow
Write-Output "AETHELN_SERVER_DESCENDANT_PID=$($Child.Id)"
$Child.WaitForExit()
exit $Child.ExitCode
'@

	function Invoke-FixtureRun(
		[string] $FixtureLogRoot,
		[string] $FixtureRunId,
		[string] $RejectionReason,
		[int] $DurationSeconds = 5,
		[bool] $ExitAfterMarkers = $false,
		[bool] $UseLauncher = $false,
		[string] $Behavior = 'normal',
		[int] $TimeoutSeconds = 8,
		[string] $EvidenceMode = 'fixture',
		[string] $PackagedBuildProvenancePath,
		[string] $ServerProvenanceExecutable,
		[string] $FixtureEnvironment
	) {
		$Arguments = @{
			ServerExecutable = $PowerShellExecutable
			ServerArguments = @('-NoProfile', '-File', $FakeRuntime, 'server', 'server', '{ServerEndpoint}', '{ServerMap}', '{ScenarioId}', '{ProfileId}', '{RunId}', '{NetworkConfigIdentity}', '{Environment}', $Behavior, $RejectionReason, $ExitAfterMarkers.ToString().ToLowerInvariant())
			ClientExecutable = $PowerShellExecutable
			ClientArguments = @('-NoProfile', '-File', $FakeRuntime, 'client', '{ClientId}', '{ServerEndpoint}', '{ServerMap}', '{ScenarioId}', '{ProfileId}', '{RunId}', '{NetworkConfigIdentity}', '{Environment}')
			ServerEndpoint = '127.0.0.1:7777'
			ServerMap = '/Game/Maps/StarterMap'
			ScenarioId = 'network-authority.baseline.v1'
			ProfileId = 'network-profile.unset'
			NetworkConfigIdentity = 'network-emulation.caller-supplied'
			RunId = $FixtureRunId
			Environment = if ($FixtureEnvironment) { $FixtureEnvironment } elseif ($EvidenceMode -ceq 'packaged') { 'development' } else { 'local' }
			SourceRevision = 'fixture-revision'
			BuildIdentity = 'fixture-build'
			ToolchainIdentity = 'UE-5.8.1-fixture'
			HardwareIdentity = 'fixture-host'
			TopologyIdentity = 'one-server-two-clients-local-fixture'
			ActorMixIdentity = 'network-authority.actor-mix.v1'
			EvidenceMode = $EvidenceMode
			DurationSeconds = $DurationSeconds
			LogRoot = $FixtureLogRoot
			ServerReadyPattern = 'AUTHORITY server_ready.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			ServerConnectionPattern = 'AUTHORITY connection client=(?<ClientId>[^ ]+) connection=(?<ConnectionId>[^ ]+).*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			ClientReadyPattern = 'AUTHORITY client_ready client={ClientId}.*map={ServerMap}.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			MovementPattern = 'AUTHORITY movement client={ClientId}.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			EnemyPattern = 'AUTHORITY enemy_spawned enemy=.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			MeleePattern = 'AUTHORITY melee_resolved attacker=.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			DamagePattern = 'AUTHORITY damage_applied attacker=.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			JoinInProgressPattern = 'AUTHORITY join_in_progress client=client-2.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			DisconnectPattern = 'AUTHORITY disconnected client=client-1.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			ReconnectPattern = 'AUTHORITY reconnected client=client-1-reconnect connection=(?<ConnectionId>[^ ]+).*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			NetworkConfigPattern = 'AUTHORITY network_config network_config={NetworkConfigIdentity}.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
			TimeoutSeconds = $TimeoutSeconds
		}
		if ($UseLauncher) {
			$Arguments.ServerLauncherExecutable = $PowerShellExecutable
			$Arguments.ServerLauncherArguments = @('-NoProfile', '-File', $FakeLauncher, 'launch', '{ServerExecutable}', '{ServerArguments}')
			$Arguments.ServerIdentityArguments = @('-NoProfile', '-File', $FakeLauncher, 'identity', '{ServerExecutable}')
			$Arguments.ServerCleanupArguments = @('-NoProfile', '-File', $FakeLauncher, 'cleanup', '{ServerProcessId}')
			$Arguments.ServerProcessIdPattern = 'AETHELN_SERVER_DESCENDANT_PID=(?<ProcessId>[1-9][0-9]*)'
		}
		if ($PackagedBuildProvenancePath) { $Arguments.PackagedBuildProvenancePath = $PackagedBuildProvenancePath }
		if ($ServerProvenanceExecutable) { $Arguments.ServerProvenanceExecutable = $ServerProvenanceExecutable }
		& $Script @Arguments
	}

	$LogRoot = Join-Path $FixtureRoot 'success'
	$SuccessStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
	Invoke-FixtureRun $LogRoot 'fixture-run-001' 'malformed-intent'
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
	Assert-True ($Evidence.network_profile.runtime_config_identity -eq 'network-emulation.caller-supplied') 'The runtime-confirmed caller network configuration identity must be preserved.'
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
	foreach ($Category in @('movement','aim','ability','hit','cooldown','dodge','block','resource','death','respawn')) {
		Assert-True (@($Evidence.rejections | Where-Object { $_.category -eq $Category }).Count -eq 1) "Exactly one observable rejection is required for $Category."
	}
	Assert-True (@($Evidence.rejections).Count -eq 10) 'Evidence must contain exactly the ten structured invalid-claim rejections.'
	Assert-True ($Evidence.scenario.environment -eq 'local') 'Fixture evidence must preserve the explicit local environment.'
	Assert-True (@($Evidence.rejections | Where-Object { $_.category -eq 'disconnected-command' }).Count -eq 0) 'Logout must not be admitted as disconnected-command rejection evidence.'
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
	Assert-True ($Evidence.evidence_mode -eq 'fixture' -and $Evidence.result -eq 'fixture-passed') 'A complete fixture validates orchestration but can never claim packaged success.'
	Assert-True ($Evidence.result -ne 'passed') 'Synthetic marker output must never be admitted as successful packaged evidence.'
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
		Invoke-FixtureRun $EarlyExitLogRoot 'fixture-early-exit' 'malformed-intent' 3 $true
	} catch { $EarlyExitFailure = $_.Exception.Message }
	Assert-True ($EarlyExitFailure -match "(Process exited with code 0 while waiting|Required process 'server' exited unexpectedly with code 0)") 'A server that exits after emitting all markers must fail before the run can pass.'
	$EarlyExitEvidencePath = Join-Path $EarlyExitLogRoot 'network-authority-spike-evidence.json'
	Assert-True (Test-Path -LiteralPath $EarlyExitEvidencePath -PathType Leaf) 'An early required-process exit must still write evidence.'
	$EarlyExitEvidence = Get-Content -LiteralPath $EarlyExitEvidencePath -Raw | ConvertFrom-Json
	Assert-True ($EarlyExitEvidence.result -eq 'failed') 'An early required-process exit must produce failed evidence.'
	Assert-True ($EarlyExitEvidence.failure -match "(Process exited with code 0 while waiting|Required process 'server' exited unexpectedly with code 0)") 'Failed evidence must preserve the early-exit reason.'
	Write-Output 'PASS: a runtime child that exits after all markers is rejected during the observation interval'

	$LauncherLogRoot = Join-Path $FixtureRoot 'launcher-success'
	Invoke-FixtureRun $LauncherLogRoot 'fixture-launcher' 'malformed-intent' 1 $false $true
	$LauncherEvidence = Get-Content -LiteralPath (Join-Path $LauncherLogRoot 'network-authority-spike-evidence.json') -Raw | ConvertFrom-Json
	Assert-True ($LauncherEvidence.result -eq 'fixture-passed') 'The explicit server launcher topology must preserve fixture validation without claiming packaged success.'
	$LauncherDescendants = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Where-Object {
		$_.ExecutablePath -eq $PowerShellExecutable -and
		$_.CommandLine -and
		$_.CommandLine.IndexOf($FakeRuntime, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
	})
	Assert-True ($LauncherDescendants.Count -eq 0) 'Launcher-side server descendants must be confirmed stopped, not merely detached from the launcher.'
	Write-Output 'PASS: explicit Linux-server launcher indirection remains hidden, redirected, monitored, provenance-ready, and descendant-cleaned'

	$env:AETHELN_TEST_CLEANUP_FAIL = 'true'
	$CleanupFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'cleanup-failure') -FixtureRunId 'fixture-cleanup-failure' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true
	} catch { $CleanupFailure = $_.Exception.Message }
	Remove-Item -LiteralPath Env:AETHELN_TEST_CLEANUP_FAIL -ErrorAction Ignore
	Assert-True ($CleanupFailure -match 'server descendant cleanup.*exited with code 42') "A launcher-side cleanup failure must fail the run. Actual: $CleanupFailure"
	$CleanupFailureEvidence = Get-Content -LiteralPath (Join-Path $FixtureRoot 'cleanup-failure/network-authority-spike-evidence.json') -Raw | ConvertFrom-Json
	Assert-True ($CleanupFailureEvidence.result -eq 'failed') 'Cleanup failure must downgrade otherwise complete evidence to failed.'
	Write-Output 'PASS: launcher-side descendant cleanup failure is observable and fails closed'

	$PowerShellArchive = Split-Path -Parent $PowerShellExecutable
	$PowerShellInventoryPath = [System.IO.Path]::GetFileName($PowerShellExecutable)
	$ClientSha256 = (Get-FileHash -LiteralPath $PowerShellExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
	$RunnerTokens = $null
	$RunnerParseErrors = $null
	$RunnerAst = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref] $RunnerTokens, [ref] $RunnerParseErrors)
	Assert-True ($RunnerParseErrors.Count -eq 0) 'The authority runner must parse before its path-comparison helper is inspected.'
	$ComparisonFunction = @($RunnerAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq 'Get-ProvenancePathComparison' }, $true))
	Assert-True ($ComparisonFunction.Count -eq 1) 'The authority runner must define one OS-aware provenance path-comparison helper.'
	$ComparisonProbe = [scriptblock]::Create($ComparisonFunction[0].Extent.Text + "`n[pscustomobject]@{ Windows = Get-ProvenancePathComparison ([char] 92); Posix = Get-ProvenancePathComparison ([char] 47) }")
	$ComparisonResult = & $ComparisonProbe
	Assert-True ($ComparisonResult.Windows -eq [System.StringComparison]::OrdinalIgnoreCase) 'Windows provenance containment must be case-insensitive.'
	Assert-True ($ComparisonResult.Posix -eq [System.StringComparison]::Ordinal) 'Case-sensitive hosts must use ordinal provenance containment.'
	Write-Output 'PASS: provenance containment selects OS-appropriate case sensitivity'
	function Write-ProvenanceFixture([string] $Path, [object[]] $Inventory, [string] $ClientArchive = $PowerShellArchive, [string] $ServerArchive = $PowerShellArchive) {
		[ordered]@{
			schemaVersion = 2
			source = [ordered]@{ revision = 'fixture-revision'; clean = $true }
			host = [ordered]@{ buildIdentity = 'fixture-build' }
			artifacts = [ordered]@{
				clientArchive = $ClientArchive
				serverArchive = $ServerArchive
				inventory = @($Inventory)
			}
		} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
	}

	$MissingHostPathProvenance = Join-Path $FixtureRoot 'missing-host-path-provenance.json'
	Write-ProvenanceFixture $MissingHostPathProvenance @(
		[ordered]@{ kind = 'client'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 }
	)
	$MissingHostPathFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'missing-host-path') -FixtureRunId 'fixture-missing-host-path' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $MissingHostPathProvenance
	} catch { $MissingHostPathFailure = $_.Exception.Message }
	Assert-True ($MissingHostPathFailure -match 'ServerProvenanceExecutable is required') 'Packaged launcher evidence must require an explicit host-side server provenance path.'
	Write-Output 'PASS: packaged launcher provenance requires an explicit host-side server path'

	$ProvenancePath = Join-Path $FixtureRoot 'mismatched-server-provenance.json'
	Write-ProvenanceFixture $ProvenancePath @(
		[ordered]@{ kind = 'client'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = ('0' * 64) }
	)
	$ServerIdentityFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'server-identity-mismatch') -FixtureRunId 'fixture-server-identity-mismatch' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $ProvenancePath -ServerProvenanceExecutable $PowerShellExecutable
	} catch { $ServerIdentityFailure = $_.Exception.Message }
	Assert-True ($ServerIdentityFailure -match 'Packaged executable identity is not uniquely bound') 'Packaged evidence must hash and authenticate the exact launcher-side server path.'
	Write-Output 'PASS: mismatched launcher-side server digest cannot use unrelated packaged provenance'

	$MismatchedClientProvenancePath = Join-Path $FixtureRoot 'mismatched-client-path-provenance.json'
	Write-ProvenanceFixture $MismatchedClientProvenancePath @(
		[ordered]@{ kind = 'client'; path = 'unrelated/powershell.exe'; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 }
	)
	$ClientPathFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'client-path-mismatch') -FixtureRunId 'fixture-client-path-mismatch' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $MismatchedClientProvenancePath -ServerProvenanceExecutable $PowerShellExecutable
	} catch { $ClientPathFailure = $_.Exception.Message }
	Assert-True ($ClientPathFailure -match 'Packaged executable identity is not uniquely bound') 'Packaged evidence must bind the exact selected-client path, not only filename and digest.'
	Write-Output 'PASS: same-named client at an unrelated path cannot use packaged provenance'

	foreach ($UnsafeInventoryCase in @(
		@{ Name = 'rooted'; Path = $PowerShellExecutable },
		@{ Name = 'escape'; Path = '../powershell.exe' },
		@{ Name = 'dot-alias'; Path = "./$PowerShellInventoryPath" },
		@{ Name = 'parent-alias'; Path = "unused/../$PowerShellInventoryPath" }
	)) {
		$UnsafeProvenancePath = Join-Path $FixtureRoot ("unsafe-$($UnsafeInventoryCase.Name)-provenance.json")
		Write-ProvenanceFixture $UnsafeProvenancePath @(
			[ordered]@{ kind = 'client'; path = $UnsafeInventoryCase.Path; sha256 = $ClientSha256 },
			[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 }
		)
		$UnsafeFailure = $null
		try {
			Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot ("unsafe-$($UnsafeInventoryCase.Name)")) -FixtureRunId ("fixture-unsafe-$($UnsafeInventoryCase.Name)") -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $UnsafeProvenancePath -ServerProvenanceExecutable $PowerShellExecutable
		} catch { $UnsafeFailure = $_.Exception.Message }
		Assert-True ($UnsafeFailure -match 'archive-relative') "A $($UnsafeInventoryCase.Name) inventory path must fail closed. Actual: $UnsafeFailure"
	}
	Write-Output 'PASS: rooted and escaping provenance inventory paths fail closed'

	$ClientArchiveParent = Split-Path -Parent $PowerShellArchive
	$ClientArchiveDirectory = Split-Path -Leaf $PowerShellArchive
	$SeparatorAliasProvenancePath = Join-Path $FixtureRoot 'separator-alias-provenance.json'
	Write-ProvenanceFixture $SeparatorAliasProvenancePath @(
		[ordered]@{ kind = 'client'; path = "$ClientArchiveDirectory\$PowerShellInventoryPath"; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 }
	) -ClientArchive $ClientArchiveParent
	$SeparatorAliasFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'separator-alias') -FixtureRunId 'fixture-separator-alias' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $SeparatorAliasProvenancePath -ServerProvenanceExecutable $PowerShellExecutable
	} catch { $SeparatorAliasFailure = $_.Exception.Message }
	Assert-True ($SeparatorAliasFailure -match 'exact canonical archive-relative path') 'Backslash-separated inventory aliases must fail closed.'
	Write-Output 'PASS: provenance inventory paths require canonical forward slashes'

	$OutsideRootProvenancePath = Join-Path $FixtureRoot 'outside-root-provenance.json'
	Write-ProvenanceFixture $OutsideRootProvenancePath @(
		[ordered]@{ kind = 'client'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 }
	) -ServerArchive $FixtureRoot
	$OutsideRootFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'outside-root') -FixtureRunId 'fixture-outside-root' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $OutsideRootProvenancePath -ServerProvenanceExecutable $PowerShellExecutable
	} catch { $OutsideRootFailure = $_.Exception.Message }
	Assert-True ($OutsideRootFailure -match 'ServerProvenanceExecutable.*serverArchive') 'The host-side server provenance path must remain beneath serverArchive.'
	Write-Output 'PASS: host-side server provenance path outside serverArchive fails closed'

	$LinkedServerArchive = Join-Path $FixtureRoot 'linked-server-archive'
	$LinkedServerTarget = Join-Path $LinkedServerArchive 'linked'
	New-Item -ItemType Directory -Path $LinkedServerArchive -Force | Out-Null
	$LinkItemType = if ([System.IO.Path]::DirectorySeparatorChar -ceq '\') { 'Junction' } else { 'SymbolicLink' }
	New-Item -ItemType $LinkItemType -Path $LinkedServerTarget -Target $PowerShellArchive | Out-Null
	$LinkedServerProvenancePath = Join-Path $FixtureRoot 'linked-server-provenance.json'
	Write-ProvenanceFixture $LinkedServerProvenancePath @(
		[ordered]@{ kind = 'client'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = "linked/$PowerShellInventoryPath"; sha256 = $ClientSha256 }
	) -ServerArchive $LinkedServerArchive
	$LinkedServerFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'linked-server') -FixtureRunId 'fixture-linked-server' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $LinkedServerProvenancePath -ServerProvenanceExecutable (Join-Path $LinkedServerTarget $PowerShellInventoryPath)
	} catch { $LinkedServerFailure = $_.Exception.Message }
	Assert-True ($LinkedServerFailure -match 'reparse point') 'A host-side server provenance path traversing a filesystem link must fail closed.'
	Write-Output 'PASS: host-side server provenance path cannot escape through a filesystem link'

	$InventoryLinkedServerArchive = Join-Path $FixtureRoot 'inventory-linked-server-archive'
	$InventoryLinkedServerExecutable = Join-Path $InventoryLinkedServerArchive 'server.exe'
	$InventoryLinkedTarget = Join-Path $InventoryLinkedServerArchive 'linked'
	New-Item -ItemType Directory -Path $InventoryLinkedServerArchive -Force | Out-Null
	Copy-Item -LiteralPath $PowerShellExecutable -Destination $InventoryLinkedServerExecutable
	New-Item -ItemType $LinkItemType -Path $InventoryLinkedTarget -Target $PowerShellArchive | Out-Null
	$InventoryLinkedProvenancePath = Join-Path $FixtureRoot 'inventory-linked-provenance.json'
	Write-ProvenanceFixture $InventoryLinkedProvenancePath @(
		[ordered]@{ kind = 'client'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = 'server.exe'; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = "linked/$PowerShellInventoryPath"; sha256 = $ClientSha256 }
	) -ServerArchive $InventoryLinkedServerArchive
	$InventoryLinkedFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'inventory-linked') -FixtureRunId 'fixture-inventory-linked' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $InventoryLinkedProvenancePath -ServerProvenanceExecutable $InventoryLinkedServerExecutable
	} catch { $InventoryLinkedFailure = $_.Exception.Message }
	Assert-True ($InventoryLinkedFailure -match 'reparse point') 'Every provenance inventory entry must fail closed when it traverses a filesystem link.'
	Write-Output 'PASS: every provenance inventory entry rejects filesystem-link escape'

	foreach ($InvalidKind in @('auxiliary', 'CLIENT', 'SERVER')) {
		$InvalidKindProvenancePath = Join-Path $FixtureRoot ("invalid-kind-$InvalidKind-provenance.json")
		Write-ProvenanceFixture $InvalidKindProvenancePath @(
			[ordered]@{ kind = 'client'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
			[ordered]@{ kind = 'server'; path = 'server.exe'; sha256 = $ClientSha256 },
			[ordered]@{ kind = $InvalidKind; path = "linked/$PowerShellInventoryPath"; sha256 = $ClientSha256 }
		) -ServerArchive $InventoryLinkedServerArchive
		$InvalidKindFailure = $null
		try {
			Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot ("invalid-kind-$InvalidKind")) -FixtureRunId ("fixture-invalid-kind-$InvalidKind") -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $InvalidKindProvenancePath -ServerProvenanceExecutable $InventoryLinkedServerExecutable
		} catch { $InvalidKindFailure = $_.Exception.Message }
		Assert-True ($InvalidKindFailure -match 'kind must be client or server') "Invalid provenance inventory kind '$InvalidKind' must fail closed."
	}
	Write-Output 'PASS: provenance inventory kinds require exact lowercase client or server'

	$DuplicateProvenancePath = Join-Path $FixtureRoot 'duplicate-provenance.json'
	Write-ProvenanceFixture $DuplicateProvenancePath @(
		[ordered]@{ kind = 'client'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 }
	)
	$DuplicateFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'duplicate-provenance') -FixtureRunId 'fixture-duplicate-provenance' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $DuplicateProvenancePath -ServerProvenanceExecutable $PowerShellExecutable
	} catch { $DuplicateFailure = $_.Exception.Message }
	Assert-True ($DuplicateFailure -match 'Packaged executable identity is not uniquely bound') 'Duplicate matching inventory entries must fail closed.'
	Write-Output 'PASS: duplicate matching provenance entries fail closed'

	$ConflictingDigestProvenancePath = Join-Path $FixtureRoot 'conflicting-digest-provenance.json'
	Write-ProvenanceFixture $ConflictingDigestProvenancePath @(
		[ordered]@{ kind = 'client'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = ('0' * 64) }
	)
	$ConflictingDigestFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'conflicting-digest-provenance') -FixtureRunId 'fixture-conflicting-digest-provenance' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $ConflictingDigestProvenancePath -ServerProvenanceExecutable $PowerShellExecutable
	} catch { $ConflictingDigestFailure = $_.Exception.Message }
	Assert-True ($ConflictingDigestFailure -match 'Packaged executable identity is not uniquely bound') 'Conflicting digests for one kind and relative path must fail closed.'
	Write-Output 'PASS: conflicting provenance digests for one artifact identity fail closed'

	$WrongKindProvenancePath = Join-Path $FixtureRoot 'wrong-kind-provenance.json'
	Write-ProvenanceFixture $WrongKindProvenancePath @(
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'client'; path = 'unrelated/powershell.exe'; sha256 = $ClientSha256 }
	)
	$WrongKindFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'wrong-kind-provenance') -FixtureRunId 'fixture-wrong-kind-provenance' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $WrongKindProvenancePath -ServerProvenanceExecutable $PowerShellExecutable
	} catch { $WrongKindFailure = $_.Exception.Message }
	Assert-True ($WrongKindFailure -match 'Packaged executable identity is not uniquely bound') 'Wrong-kind provenance entries must fail closed.'
	Write-Output 'PASS: wrong-kind provenance entries fail closed'

	$SelfAuthoredProvenancePath = Join-Path $FixtureRoot 'self-authored-provenance.json'
	Write-ProvenanceFixture $SelfAuthoredProvenancePath @(
		[ordered]@{ kind = 'client'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 },
		[ordered]@{ kind = 'server'; path = $PowerShellInventoryPath; sha256 = $ClientSha256 }
	)
	$SelfAuthoredRoot = Join-Path $FixtureRoot 'self-authored-packaged'
	Invoke-FixtureRun -FixtureLogRoot $SelfAuthoredRoot -FixtureRunId 'fixture-self-authored' -RejectionReason 'malformed-intent' -DurationSeconds 1 -UseLauncher $true -EvidenceMode 'packaged' -PackagedBuildProvenancePath $SelfAuthoredProvenancePath -ServerProvenanceExecutable $PowerShellExecutable
	$SelfAuthoredEvidence = Get-Content -LiteralPath (Join-Path $SelfAuthoredRoot 'network-authority-spike-evidence.json') -Raw | ConvertFrom-Json
	Assert-True ($SelfAuthoredEvidence.result -eq 'packaged-candidate') 'Even matching caller-authored provenance can produce only a candidate awaiting independent gates.'
	Assert-True ($SelfAuthoredEvidence.result -ne 'passed') 'The runner must never self-award packaged success.'
	Write-Output 'PASS: self-authored matching provenance cannot self-award packaged success'

	$PackagedLocalFailure = $null
	try {
		Invoke-FixtureRun -FixtureLogRoot (Join-Path $FixtureRoot 'packaged-local') -FixtureRunId 'fixture-packaged-local' -RejectionReason 'malformed-intent' -DurationSeconds 1 -EvidenceMode 'packaged' -FixtureEnvironment 'local'
	} catch { $PackagedLocalFailure = $_.Exception.Message }
	Assert-True ($PackagedLocalFailure -match 'Packaged authority evidence must use the development environment') 'Packaged multiplayer evidence must reject the local environment before launch.'
	Write-Output 'PASS: packaged authority evidence requires the explicit development environment'

	$NegativeScenarios = @(
		@{ Name = 'missing'; Behavior = 'missing-damage'; Failure = 'waiting for authoritative damage' },
		@{ Name = 'duplicate'; Behavior = 'duplicate-damage'; Failure = 'Expected exactly one damage-application record, observed 2' },
		@{ Name = 'mismatched'; Behavior = 'mismatched-run'; Failure = 'waiting for authoritative damage' },
		@{ Name = 'reordered'; Behavior = 'reordered'; Failure = 'reordered before authoritative damage' },
		@{ Name = 'missing-disconnect'; Behavior = 'missing-disconnect'; Failure = 'waiting for disconnect cleanup' },
		@{ Name = 'missing-reconnect'; Behavior = 'missing-reconnect'; Failure = 'waiting for new reconnect identity' },
		@{ Name = 'reordered-lifecycle'; Behavior = 'reordered-lifecycle'; Failure = 'Authority rejection, disconnect, and reconnect observations were reordered' },
		@{ Name = 'reused'; Behavior = 'reused-connection'; Failure = 'Reconnect reused the disconnected connection identity' },
		@{ Name = 'fabricated-disconnected-command'; Behavior = 'fabricated-disconnected-command'; Failure = 'Unexpected disconnected-command rejection without a transported command-validation attempt' },
		@{ Name = 'delayed-fabricated-disconnected-command'; Behavior = 'delayed-fabricated-disconnected-command'; Failure = 'Unexpected disconnected-command rejection without a transported command-validation attempt' },
		@{ Name = 'fabricated-disconnected-command-stderr'; Behavior = 'fabricated-disconnected-command-stderr'; Failure = 'Unexpected disconnected-command rejection without a transported command-validation attempt' },
		@{ Name = 'unexpected-rejection-category'; Behavior = 'unexpected-rejection-category'; Failure = "Unexpected authority rejection category 'unexpected'" }
	)
	foreach ($Scenario in $NegativeScenarios) {
		$NegativeFailure = $null
		try { Invoke-FixtureRun (Join-Path $FixtureRoot $Scenario.Name) ("fixture-" + $Scenario.Name) 'malformed-intent' 1 $false $false $Scenario.Behavior 2 } catch { $NegativeFailure = $_.Exception.Message }
		Assert-True ($NegativeFailure -match [regex]::Escape($Scenario.Failure)) "$($Scenario.Name) evidence must fail closed."
	}
	Write-Output 'PASS: missing, duplicate, mismatched-run, reordered, lifecycle, reused-connection, and fabricated-command evidence fails closed'

	$env:AETHELN_TEST_LAUNCHER_FAIL = 'true'
	$LauncherFailure = $null
	try { Invoke-FixtureRun (Join-Path $FixtureRoot 'launcher-failure') 'fixture-launcher-failure' 'malformed-intent' 1 $false $true 'normal' 2 } catch { $LauncherFailure = $_.Exception.Message }
	Remove-Item -LiteralPath Env:AETHELN_TEST_LAUNCHER_FAIL -ErrorAction Ignore
	Assert-True ($LauncherFailure -match 'Process exited with code 41 while waiting for server descendant process identity') "A launcher failure must fail before gameplay evidence can pass. Actual: $LauncherFailure"
	Write-Output 'PASS: launcher failure cannot fabricate a successful authority capture'

	$FabricatedPackagedFailure = $null
	try {
		$FabricatedArgs = @{
			ServerExecutable = $PowerShellExecutable; ServerArguments = @('-NoProfile','-File',$FakeRuntime,'server','server','{ServerEndpoint}','{ServerMap}','{ScenarioId}','{ProfileId}','{RunId}','{NetworkConfigIdentity}','{Environment}','normal','malformed-intent','false')
			ClientExecutable = $PowerShellExecutable; ClientArguments = @('-NoProfile','-File',$FakeRuntime,'client','{ClientId}','{ServerEndpoint}','{ServerMap}','{ScenarioId}','{ProfileId}','{RunId}','{NetworkConfigIdentity}','{Environment}')
			ServerEndpoint = '127.0.0.1:7777'; ServerMap = '/Game/Maps/StarterMap'; ScenarioId = 'network-authority.baseline.v1'; ProfileId = 'network-profile.unset'; NetworkConfigIdentity = 'network-emulation.caller-supplied'; RunId = 'fabricated-packaged'
			Environment = 'development'
			SourceRevision = 'fixture-revision'; BuildIdentity = 'fixture-build'; ToolchainIdentity = 'fixture-toolchain'; HardwareIdentity = 'fixture-host'; TopologyIdentity = 'fixture-topology'; ActorMixIdentity = 'network-authority.actor-mix.v1'; EvidenceMode = 'packaged'; DurationSeconds = 1; LogRoot = (Join-Path $FixtureRoot 'fabricated-packaged')
			ServerReadyPattern = 'AUTHORITY server_ready.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; ServerConnectionPattern = 'AUTHORITY connection client=(?<ClientId>[^ ]+) connection=(?<ConnectionId>[^ ]+).*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; ClientReadyPattern = 'AUTHORITY client_ready client={ClientId}.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; MovementPattern = 'AUTHORITY movement client={ClientId}.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; EnemyPattern = 'AUTHORITY enemy_spawned.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; MeleePattern = 'AUTHORITY melee_resolved.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; DamagePattern = 'AUTHORITY damage_applied.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; JoinInProgressPattern = 'AUTHORITY join_in_progress.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; DisconnectPattern = 'AUTHORITY disconnected.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; ReconnectPattern = 'AUTHORITY reconnected.*connection=(?<ConnectionId>[^ ]+).*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'; NetworkConfigPattern = 'AUTHORITY network_config.*scenario={ScenarioId}.*profile={ProfileId}.*run={RunId}'
		}
		& $Script @FabricatedArgs
	} catch { $FabricatedPackagedFailure = $_.Exception.Message }
	Assert-True ($FabricatedPackagedFailure -match 'PackagedBuildProvenancePath is required') 'Fake marker processes cannot claim packaged success without exact build provenance.'
	Write-Output 'PASS: fixture output cannot masquerade as provenance-bound packaged evidence'

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
		& $Script -ServerExecutable $PowerShellExecutable -ServerArguments @('{ServerEndpoint}', '{ServerMap}') -ClientExecutable $PowerShellExecutable -ClientArguments @('{ClientId}') -ServerEndpoint '127.0.0.1:7777' -ServerMap '/Game/Maps/StarterMap' -ScenarioId 'network-authority.baseline.v1' -ProfileId 'network-profile.unset' -NetworkConfigIdentity 'network-emulation.caller-supplied' -RunId 'invalid' -Environment 'local' -SourceRevision 'revision' -BuildIdentity 'build' -ToolchainIdentity 'toolchain' -HardwareIdentity 'hardware' -TopologyIdentity 'topology' -ActorMixIdentity 'network-authority.actor-mix.v1' -EvidenceMode 'fixture' -DurationSeconds 1 -LogRoot (Join-Path $FixtureRoot 'invalid') -ServerReadyPattern 'ready' -ServerConnectionPattern 'connection' -ClientReadyPattern 'ready' -MovementPattern 'movement' -EnemyPattern 'enemy' -MeleePattern 'melee' -DamagePattern 'damage' -JoinInProgressPattern 'join' -DisconnectPattern 'disconnect' -ReconnectPattern 'reconnect' -NetworkConfigPattern 'network'
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
