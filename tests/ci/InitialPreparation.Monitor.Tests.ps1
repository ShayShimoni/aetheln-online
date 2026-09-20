[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Core.ps1')
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.GitHub.ps1')
. (Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Monitor.ps1')
function Assert-MonitorTest {
	param([bool] $Condition, [string] $Message)
	if (-not $Condition) { throw $Message }
}
function Assert-MonitorRejected {
	param([scriptblock] $Action, [string] $Reason)
	$Failure = $null
	try { & $Action | Out-Null } catch { $Failure = $_.Exception.Message }
	Assert-MonitorTest -Condition ($Failure -ceq $Reason) -Message "Expected $Reason; received $Failure"
}
# Execute only the worker's owned pause statement with a synthetic clock. The
# old fixed five-second pause made a17-second observation repeat every22s.
$WorkerTokens = $null; $WorkerErrors = $null
$WorkerAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.MonitorWorker.ps1'), [ref] $WorkerTokens, [ref] $WorkerErrors)
$PauseCommands = @($WorkerAst.FindAll({ param($Node) $Node -is [Management.Automation.Language.CommandAst] -and $Node.GetCommandName() -ceq 'Start-Sleep' }, $true))
Assert-MonitorTest -Condition ($WorkerErrors.Count -eq 0 -and $PauseCommands.Count -eq 1) -Message 'Worker must have one explicit bounded post-cycle pause'
$PauseStatement = [scriptblock]::Create($PauseCommands[0].Extent.Text)
$PauseFixture = [pscustomobject]@{ milliseconds = 0; now = 170000000L }
$Cycle = [pscustomobject]@{ startedTicks = 0L }
$null = $Cycle # Referenced by the actual worker pause AST executed below.
$Attempt = [pscustomobject]@{ monotonicFrequency = 10000000L; stopUsefulWorkTicks = 198000000000L }
$PauseClock = ${function:Get-InitialPreparationTick}
try {
	function Get-InitialPreparationTick { return $PauseFixture.now }
	function Start-Sleep {
		[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Fixture-only virtual clock; no sleep or state outside this test.')]
		[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Intercept the real worker pause AST without wall-clock waiting; restored in finally.')]
		param([int] $Seconds, [int] $Milliseconds)
		$PauseFixture.milliseconds += $Seconds * 1000 + $Milliseconds
	}
	& $PauseStatement
	Assert-MonitorTest -Condition ($PauseFixture.milliseconds -eq 13000) -Message ('17-second cycle must wait13seconds for30-second starts, not ' + $PauseFixture.milliseconds)
} finally { Set-Item -Path Function:Get-InitialPreparationTick -Value $PauseClock; Remove-Item -LiteralPath Function:Start-Sleep }
foreach ($Boundary in @(@{ elapsed = 0; wait = 30000 }, @{ elapsed = 17000; wait = 13000 }, @{ elapsed = 24999; wait = 5001 }, @{ elapsed = 25000; wait = 5000 }, @{ elapsed = 34450; wait = 5000 })) {
	$Wait = Get-PreparationMonitorDelayMilliseconds -Attempt $Attempt -StartedTicks 0 -NowTicks ($Boundary.elapsed * 10000L)
	Assert-MonitorTest -Condition ($Wait -eq $Boundary.wait) -Message 'Cycle start/post-cycle minimum boundary changed'
	# A fast prior cycle leaves25s, not55s, for the following observation.
	$NextStart = $Boundary.elapsed + $Wait
	$NextDeadline = $Boundary.elapsed + 55000
	$ExpectedAllowance = [Math]::Min(50000, $Boundary.elapsed + 25000)
	Assert-MonitorTest -Condition ($NextDeadline - $NextStart -eq $ExpectedAllowance) -Message 'Cadence silently reset LastObserved+55 deadline'
}
$FastWait = Get-PreparationMonitorDelayMilliseconds -Attempt $Attempt -StartedTicks 0 -NowTicks 0
Assert-MonitorTest -Condition ($FastWait + 34450 -gt 55000) -Message 'Fast-to-slow34.45s transition must fail its original25s allowance, never widen freshness'
$AlmostTerminal = $Attempt.stopUsefulWorkTicks - 20000L
Assert-MonitorTest -Condition ((Get-PreparationMonitorDelayMilliseconds -Attempt $Attempt -StartedTicks ($AlmostTerminal - 170000000L) -NowTicks $AlmostTerminal) -eq 2) -Message 'Pause exceeded remaining attempt deadline'
Assert-MonitorRejected -Action { Get-PreparationMonitorDelayMilliseconds -Attempt $Attempt -StartedTicks 0 -NowTicks $Attempt.stopUsefulWorkTicks } -Reason 'useful_work_deadline'
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnMonitorFixture-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $FixtureRoot
$Attempt = New-InitialPreparationAttempt -Repository 'owner/repository' -ControllerRevision ('a' * 40) -TargetRevision ('b' * 40) -AttemptId ([guid]::NewGuid().ToString('N'))
$Runner = [pscustomobject]@{ repository = 'owner/repository'; id = 21L; name = 'fixture-runner'; originalLabels = @('self-hosted', 'Windows', 'X64', 'aetheln-engine') }
$Seed = [pscustomobject]@{ complete = $true; routesSafe = $true; online = $true; busy = $false; runnerId = 21L; runnerName = 'fixture-runner'; labels = @('self-hosted', 'Windows', 'X64'); activeJobs = @(); observedTicks = (Get-InitialPreparationTick) }
$Snapshot = ConvertTo-InitialPreparationMonitorSnapshot -Observation $Seed -Attempt $Attempt -Sequence 1
$Now = Get-InitialPreparationTick
Assert-InitialPreparationMonitorSnapshot -Snapshot $Snapshot -Attempt $Attempt -Runner $Runner -Sequence 1 -NowTicks $Now
$LastBoundedSnapshot = ConvertTo-InitialPreparationMonitorSnapshot -Observation $Seed -Attempt $Attempt -Sequence 4096
Assert-InitialPreparationMonitorSnapshot -Snapshot $LastBoundedSnapshot -Attempt $Attempt -Runner $Runner -Sequence 4096 -NowTicks $Now
Assert-MonitorRejected -Action { Assert-InitialPreparationMonitorSnapshot -Snapshot $LastBoundedSnapshot -Attempt $Attempt -Runner $Runner -Sequence 4097 -NowTicks $Now } -Reason 'monitor_observation_invalid'
foreach ($IdentityField in @('attemptId', 'repository', 'runnerName')) {
	foreach ($Shape in @('empty-array', 'singleton-array')) {
		$BadIdentity = $Snapshot | ConvertTo-Json -Depth 4 | ConvertFrom-Json
		if ($Shape -ceq 'empty-array') { $BadIdentity.$IdentityField = @() } else { $BadIdentity.$IdentityField = @($Snapshot.$IdentityField) }
		Assert-MonitorRejected -Action { Assert-InitialPreparationMonitorSnapshot -Snapshot $BadIdentity -Attempt $Attempt -Runner $Runner -Sequence 1 -NowTicks (Get-InitialPreparationTick) } -Reason 'monitor_observation_invalid'
	}
}
Assert-MonitorRejected -Action { Assert-InitialPreparationMonitorSnapshot -Snapshot $Snapshot -Attempt $Attempt -Runner $Runner -Sequence 1 -NowTicks ($Now + [Diagnostics.Stopwatch]::Frequency * 61) } -Reason 'monitor_observation_stale'
foreach ($Field in @('complete', 'online', 'routesSafe')) {
	$Bad = $Snapshot | ConvertTo-Json -Depth 4 | ConvertFrom-Json
	$Bad.$Field = 'true'
	Assert-MonitorRejected -Action { Assert-InitialPreparationMonitorSnapshot -Snapshot $Bad -Attempt $Attempt -Runner $Runner -Sequence 1 -NowTicks (Get-InitialPreparationTick) } -Reason 'monitor_observation_invalid'
}
# A completed next observation must be read before rejecting an expired cache.
$FreshEvidence = Join-Path $FixtureRoot 'expired-cache-fresh-next'
$null = New-Item -ItemType Directory -Path $FreshEvidence
$VirtualNow = $Now + [Diagnostics.Stopwatch]::Frequency * 61
$FreshNext = $Snapshot | ConvertTo-Json -Depth 4 | ConvertFrom-Json
$FreshNext.observedTicks = $VirtualNow - [Diagnostics.Stopwatch]::Frequency
$FreshBytes = [Text.Encoding]::UTF8.GetBytes(($FreshNext | ConvertTo-Json -Depth 4 -Compress))
$FreshStream = [IO.File]::Open((Join-Path $FreshEvidence 'snapshot-0001.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $FreshStream.Write($FreshBytes, 0, $FreshBytes.Length) } finally { $FreshStream.Dispose() }
$FreshMonitor = Get-InitialPreparationMonitorContext -Attempt $Attempt -Runner $Runner -SeedObservation $Seed -OwnedWorker ([pscustomobject]@{ process = [pscustomobject]@{ HasExited = $false } }) -EvidenceRoot $FreshEvidence
$RealClock = ${function:Get-InitialPreparationTick}
try {
	function Get-InitialPreparationTick { return $VirtualNow }
	$FreshResult = Get-InitialPreparationMonitorState -Monitor $FreshMonitor
	Assert-MonitorTest -Condition ($FreshResult.sequence -eq 1 -and $FreshResult.observedTicks -eq $FreshNext.observedTicks) -Message 'Expired cached observation hid a fresh completed next snapshot'
} finally { Set-Item -Path Function:Get-InitialPreparationTick -Value $RealClock }
foreach ($CatchupMode in @('stale-only', 'ordered-backlog', 'unsafe-intermediate', 'missing-intermediate', 'nonmonotonic', 'dead-worker', 'locked-next')) {
	$CatchupRoot = Join-Path $FixtureRoot $CatchupMode
	$null = New-Item -ItemType Directory -Path $CatchupRoot
	$Catchup = Get-InitialPreparationMonitorContext -Attempt $Attempt -Runner $Runner -SeedObservation $Seed -OwnedWorker ([pscustomobject]@{ process = [pscustomobject]@{ HasExited = ($CatchupMode -ceq 'dead-worker') } }) -EvidenceRoot $CatchupRoot
	$HeldNext = $null
	try {
		foreach ($Index in @(1, 2)) {
			if ($CatchupMode -ceq 'stale-only' -or ($CatchupMode -ceq 'missing-intermediate' -and $Index -eq 1)) { continue }
			$Entry = $Snapshot | ConvertTo-Json -Depth 4 | ConvertFrom-Json
			$Entry.sequence = $Index
			$Entry.observedTicks = if ($Index -eq 1) { $Seed.observedTicks + 1 } else { $VirtualNow - [Diagnostics.Stopwatch]::Frequency }
			if ($CatchupMode -ceq 'unsafe-intermediate' -and $Index -eq 1) { $Entry.labels += 'aetheln-engine' }
			if ($CatchupMode -ceq 'nonmonotonic' -and $Index -eq 2) { $Entry.observedTicks = $Seed.observedTicks }
			$Payload = [Text.Encoding]::UTF8.GetBytes(($Entry | ConvertTo-Json -Depth 4 -Compress))
			$EntryStream = [IO.File]::Open((Join-Path $CatchupRoot ('snapshot-{0:D4}.json' -f $Index)), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
			$EntryStream.Write($Payload, 0, $Payload.Length)
			if ($CatchupMode -ceq 'locked-next' -and $Index -eq 1) { $HeldNext = $EntryStream } else { $EntryStream.Dispose() }
		}
		function Get-InitialPreparationTick { return $VirtualNow }
		if ($CatchupMode -ceq 'ordered-backlog') {
			$CaughtUp = Get-InitialPreparationMonitorState -Monitor $Catchup
			Assert-MonitorTest -Condition ($CaughtUp.sequence -eq 2 -and $CaughtUp.observedTicks -eq $Entry.observedTicks) -Message 'Ordered safe backlog was not consumed before freshness'
		} else {
			$ExpectedFailure = if ($CatchupMode -ceq 'dead-worker') { 'monitor_worker_exited' }
				elseif ($CatchupMode -in @('unsafe-intermediate', 'nonmonotonic')) { 'monitor_observation_invalid' } else { 'monitor_observation_stale' }
			Assert-MonitorRejected -Action { Get-InitialPreparationMonitorState -Monitor $Catchup } -Reason $ExpectedFailure
		}
	} finally {
		Set-Item -Path Function:Get-InitialPreparationTick -Value $RealClock
		if ($null -ne $HeldNext) { $HeldNext.Dispose() }
	}
}
# A retained proof is verified by exact bytes, then kept write/delete-denied.
function Test-MonitorProofHandoff {
	$HandoffRoot = Join-Path $FixtureRoot 'proof-handoff'
	$null = New-Item -ItemType Directory -Path $HandoffRoot
	$CapturedLaunch = [pscustomobject]@{ arguments = @() }
	function Start-InitialPreparationProcess {
		[CmdletBinding(SupportsShouldProcess)]
		param($Attempt, $Lease, $Executable, $Arguments, $WorkingDirectory)
		$null = $Attempt; $null = $Lease; $null = $WorkingDirectory
		if (-not $PSCmdlet.ShouldProcess($Executable, 'Record synthetic monitor launch')) { throw 'fixture_declined' }
		$CapturedLaunch.arguments = $Arguments
		return [pscustomobject]@{ process = [pscustomobject]@{ HasExited = $false } }
	}
	$RuntimeProof = [pscustomobject]@{ schemaVersion = 1; repository = $Runner.repository; runnerId = $Runner.id; runnerName = $Runner.name;
		originalLabels = $Runner.originalLabels; referenceKey = ('d' * 64); sources = @([pscustomobject]@{ repository = $Runner.repository; revision = ('b' * 40);
			workflows = @([pscustomobject]@{ revision = ('b' * 40); path = '.github/workflows/ci.yml'; blobId = ('c' * 40); sha256 = ('e' * 64); bytes = 100;
				routes = @([pscustomobject]@{ jobId = 'compile'; labels = @('self-hosted', 'aetheln-engine'); eligible = $true }) }) }) }
	$HandoffSeed = $Seed | ConvertTo-Json -Depth 4 | ConvertFrom-Json
	$HandoffSeed | Add-Member -NotePropertyName runtimeProof -NotePropertyValue $RuntimeProof
	$null = Start-InitialPreparationMonitor -Attempt $Attempt -Lease ([pscustomobject]@{}) -Runner $Runner -SeedObservation $HandoffSeed -YamlAssemblyPath 'fixture.dll' -EvidenceRoot $HandoffRoot
	$ExpectedHash = (Get-FileHash -LiteralPath (Join-Path $HandoffRoot 'admission-proof.json') -Algorithm SHA256).Hash.ToLowerInvariant()
	$HashIndex = [array]::IndexOf($CapturedLaunch.arguments, '-ProofSha256')
	Assert-MonitorTest -Condition ($HashIndex -ge 0 -and $CapturedLaunch.arguments[$HashIndex + 1] -ceq $ExpectedHash) -Message 'Monitor launch lost the exact accepted proof digest'
	$Opened = Get-InitialPreparationMonitorProof -EvidenceRoot $HandoffRoot -Attempt $Attempt -Runner $Runner -ProofSha256 $ExpectedHash
	try {
		Assert-MonitorTest -Condition ($Opened.envelope.attemptId -ceq $Attempt.attemptId -and $Opened.envelope.proof.referenceKey -ceq $RuntimeProof.referenceKey) -Message 'Proof identity changed across handoff'
		$WriteDenied = $false; $Writer = $null
		try { $Writer = [IO.File]::Open((Join-Path $HandoffRoot 'admission-proof.json'), [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite) } catch { $WriteDenied = $true }
		finally { if ($null -ne $Writer) { $Writer.Dispose() } }
		Assert-MonitorTest -Condition $WriteDenied -Message 'Consumed proof is not retained against writers'
	} finally { $Opened.stream.Dispose(); $Opened.handle.Dispose(); foreach ($Pin in $Opened.pins) { $Pin.Dispose() } }
	Assert-MonitorRejected -Action { Get-InitialPreparationMonitorProof -EvidenceRoot $HandoffRoot -Attempt $Attempt -Runner $Runner -ProofSha256 ('0' * 64) } -Reason 'runtime_proof_invalid'
	foreach ($ProofMode in @('wrong-attempt', 'wrong-runner', 'stale', 'malformed', 'wrong-route')) {
		$BadRoot = Join-Path $FixtureRoot ('proof-' + $ProofMode)
		$null = New-Item -ItemType Directory -Path $BadRoot
		$Envelope = Get-Content -LiteralPath (Join-Path $HandoffRoot 'admission-proof.json') -Raw | ConvertFrom-Json
		switch ($ProofMode) {
			'wrong-attempt' { $Envelope.attemptId = 'other-attempt' }
			'wrong-runner' { $Envelope.proof.runnerId = 22 }
			'stale' { $Envelope.seedObservedTicks = 0 }
			'wrong-route' { $Envelope.proof.sources[0].workflows[0].routes[0].labels = @('self-hosted') }
		}
		$BadJson = if ($ProofMode -ceq 'malformed') { '{invalid' } else { $Envelope | ConvertTo-Json -Depth 14 -Compress }
		$Payload = [Text.Encoding]::UTF8.GetBytes($BadJson)
		$Writer = [IO.File]::Open((Join-Path $BadRoot 'admission-proof.json'), [IO.FileMode]::CreateNew)
		try { $Writer.Write($Payload, 0, $Payload.Length) } finally { $Writer.Dispose() }
		$BadHash = (Get-FileHash -LiteralPath (Join-Path $BadRoot 'admission-proof.json') -Algorithm SHA256).Hash.ToLowerInvariant()
		Assert-MonitorRejected -Action { Get-InitialPreparationMonitorProof -EvidenceRoot $BadRoot -Attempt $Attempt -Runner $Runner -ProofSha256 $BadHash } -Reason 'runtime_proof_invalid'
	}
}
Test-MonitorProofHandoff
foreach ($Mode in @('ready', 'held', 'crash', 'malformed', 'future', 'labels')) {
	$Evidence = Join-Path $FixtureRoot $Mode
	$null = New-Item -ItemType Directory -Path $Evidence
	$Lease = Enter-InitialPreparationLease -Attempt $Attempt -LeasePath (Join-Path $Evidence 'owner.lease')
	$Owned = $null
	try {
		$Arguments = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'fixtures/InitialPreparation.MonitorFixture.ps1'), '-EvidenceRoot', $Evidence, '-SnapshotJson', ($Snapshot | ConvertTo-Json -Depth 4 -Compress), '-Mode', $Mode)
		$Owned = Start-InitialPreparationProcess -Attempt $Attempt -Lease $Lease -Executable (Join-Path $PSHOME 'powershell.exe') -Arguments $Arguments -WorkingDirectory $Evidence
		$Monitor = Get-InitialPreparationMonitorContext -Attempt $Attempt -Runner $Runner -SeedObservation $Seed -OwnedWorker $Owned -EvidenceRoot $Evidence
		$Wait = [Diagnostics.Stopwatch]::StartNew()
		while (-not (Test-Path -LiteralPath (Join-Path $Evidence 'ready.txt')) -and -not $Owned.process.HasExited -and $Wait.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 10 }
		Assert-MonitorTest -Condition ($Wait.Elapsed.TotalSeconds -lt 5) -Message 'Fixture did not initialize'
		if ($Mode -in @('ready', 'held')) {
			$Timer = [Diagnostics.Stopwatch]::StartNew()
			$Result = Get-InitialPreparationMonitorState -Monitor $Monitor
			Assert-MonitorTest -Condition ($Timer.Elapsed.TotalSeconds -lt 1) -Message 'Local poll blocked resource sampler'
			if ($Mode -ceq 'ready') {
				Assert-MonitorTest -Condition ($Result.status -ceq 'fresh' -and $Result.sequence -eq 1) -Message 'Valid observation not accepted'
			} else {
				Assert-MonitorTest -Condition ($Result.status -ceq 'pending' -and $Result.sequence -eq 0 -and $Result.observedTicks -eq $Seed.observedTicks) -Message 'Held file reset freshness or was consumed'
			}
		} else {
			$Reason = @{ crash = 'monitor_worker_exited'; malformed = 'monitor_snapshot_invalid'; future = 'monitor_observation_invalid'; labels = 'monitor_observation_invalid' }[$Mode]
			Assert-MonitorRejected -Action { Get-InitialPreparationMonitorState -Monitor $Monitor } -Reason $Reason
		}
	} finally {
		$null = Stop-InitialPreparationOwnedTree -Lease $Lease -DeadlineTicks $Attempt.cleanupDeadlineTicks
		if ($null -ne $Owned) { Assert-MonitorTest -Condition ($Owned.supervision.ActiveCount -eq 0) -Message 'Cleanup left monitor descendants' }
		Exit-InitialPreparationLease -Lease $Lease
	}
}
Write-Output "PASS: monitor fixtures; retained $FixtureRoot"
