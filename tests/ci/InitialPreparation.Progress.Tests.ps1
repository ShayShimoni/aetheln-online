Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Module = Join-Path $PSScriptRoot '../../scripts/ci/InitialPreparation.Progress.ps1'
if (-not (Test-Path -LiteralPath $Module)) { throw 'Synchronous resource progress integration is missing' }
. $Module
function Assert-ProgressCondition {
	param([bool] $Condition, [string] $Message)
	if (-not $Condition) { throw $Message }
}
function Test-ProgressSampler {
	function Assert-InitialPreparationAttempt { param($Attempt) if ($Attempt.attemptId -cne 'fixture') { throw 'attempt_identity_invalid' } }
	function Get-InitialPreparationTick { return $State.ticks }
	function Get-InitialPreparationCapacity {
		param($Roots, $Attempt, $KnownAllocations)
		Assert-ProgressCondition -Condition ($Roots.fixture -ceq $Root -and $Attempt.attemptId -ceq 'fixture' -and $KnownAllocations.fixture -eq 1GB) -Message 'Sampler inputs lost'
		$State.calls++
		if ($State.mode -ceq 'measurement_failure') { throw 'fixture_measurement_failure' }
		$Capacity = [pscustomobject]@{ availablePhysicalRamGiB = $State.ram; commitHeadroomGiB = $State.commit; volumes = @([pscustomobject]@{ volumeId = 'fixture'; availableBytes = $State.disk; knownAllocationBytes = 1GB; recoveryFloorBytes = 20GB }) }
		if ($State.mode -ceq 'missing') { $Capacity.PSObject.Properties.Remove('commitHeadroomGiB') }
		if ($State.mode -ceq 'empty_volumes') { $Capacity.volumes = @() }
		if ($State.mode -ceq 'invalid_floor') { $Capacity.volumes[0].recoveryFloorBytes = 1GB }
		if ($State.mode -ceq 'overflow_floor') { $Capacity.volumes[0].knownAllocationBytes = [long]::MaxValue }
		if ($State.mode -ceq 'slow_measurement') { $State.ticks = 1000L }
		return $Capacity
	}
	foreach ($Mode in @('gating', 'pressure', 'reset', 'disk', 'missing', 'nan', 'infinity', 'array', 'empty_volumes', 'invalid_floor', 'overflow_floor', 'measurement_failure', 'deadline', 'clock_regression', 'slow_measurement', 'evidence_cap', 'sample_cap', 'existing_evidence')) {
		$Root = Join-Path ([IO.Path]::GetTempPath()) ('AethelnProgress-' + [guid]::NewGuid().ToString('N'))
		$null = New-Item -ItemType Directory -Path $Root
		$State = @{ ticks = 0L; calls = 0; mode = $Mode; ram = 3.0; commit = 3.0; disk = 30GB }
		$Attempt = [pscustomobject]@{ attemptId = 'fixture'; monotonicFrequency = 10L; stopUsefulWorkTicks = 1000L }
		$Context = New-InitialPreparationProgressContext -Attempt $Attempt -Roots @{ fixture = $Root } -EvidenceRoot $Root -KnownAllocations @{ fixture = 1GB }
		$Failure = $null
		try {
			if ($Mode -ceq 'existing_evidence') { $null = New-InitialPreparationProgressContext -Attempt $Attempt -Roots @{ fixture = $Root } -EvidenceRoot $Root -KnownAllocations @{ fixture = 1GB } }
			if ($Mode -ceq 'disk') { $State.disk = 21GB }
			if ($Mode -ceq 'nan') { $State.ram = [double]::NaN }
			if ($Mode -ceq 'infinity') { $State.commit = [double]::PositiveInfinity }
			if ($Mode -ceq 'array') { $State.ram = @(3.0) }
			if ($Mode -ceq 'deadline') { $State.ticks = 1000L }
			if ($Mode -ceq 'evidence_cap') { $Context.evidenceBytes = 16MB }
			if ($Mode -ceq 'sample_cap') { $Context.sampleCount = 4096 }
			Invoke-InitialPreparationProgress -Context $Context
			if ($Mode -ceq 'gating') {
				$OtherWriter = $null; $WriteDenied = $false
				try { $OtherWriter = [IO.File]::Open($Context.evidencePath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite) } catch { $WriteDenied = $true } finally { if ($null -ne $OtherWriter) { $OtherWriter.Dispose() } }
				Assert-ProgressCondition -Condition $WriteDenied -Message 'Concurrent evidence writer was admitted'
				1..100 | ForEach-Object { Invoke-InitialPreparationProgress -Context $Context }
				$State.ticks = 49L; Invoke-InitialPreparationProgress -Context $Context
				Assert-ProgressCondition -Condition ($State.calls -eq 1) -Message 'Per-chunk capacity measurement or early sample'
				$State.ticks = 50L; Invoke-InitialPreparationProgress -Context $Context
				Assert-ProgressCondition -Condition ($State.calls -eq 2) -Message 'Five-second boundary not sampled'
			}
			if ($Mode -in @('pressure', 'reset')) {
				$State.ram = 1.0
				$State.ticks = 50L; Invoke-InitialPreparationProgress -Context $Context
				$State.ticks = 100L; Invoke-InitialPreparationProgress -Context $Context
				if ($Mode -ceq 'reset') { $State.ram = 2.0; $State.ticks = 150L; Invoke-InitialPreparationProgress -Context $Context; $State.commit = 1.0 }
				$State.ticks += 50L; Invoke-InitialPreparationProgress -Context $Context
				if ($Mode -ceq 'reset') { Assert-ProgressCondition -Condition ($Context.consecutivePressureSamples -eq 1) -Message 'Pressure did not reset at boundary' }
			}
			if ($Mode -ceq 'clock_regression') { $State.ticks = -1L; Invoke-InitialPreparationProgress -Context $Context }
		} catch { $Failure = $_.Exception.Message }
		$Expected = switch ($Mode) {
			'pressure' { 'resource_pressure' }
			{ $_ -in @('disk', 'overflow_floor') } { 'disk_recovery_floor_reached' }
			{ $_ -in @('missing', 'nan', 'infinity', 'array', 'empty_volumes', 'invalid_floor', 'measurement_failure') } { 'resource_measurement_unavailable' }
			{ $_ -in @('deadline', 'slow_measurement') } { 'useful_work_deadline' }
			'clock_regression' { 'monotonic_clock_unavailable' }
			{ $_ -in @('evidence_cap', 'sample_cap') } { 'resource_evidence_limit' }
			'existing_evidence' { 'resource_evidence_exists' }
			default { $null }
		}
		Assert-ProgressCondition -Condition ($Failure -ceq $Expected) -Message ("${Mode}: expected [$Expected], got [$Failure]")
		if ($null -ne $Expected -and $Mode -cne 'existing_evidence') {
			$Repeat = $null
			try { Invoke-InitialPreparationProgress -Context $Context } catch { $Repeat = $_.Exception.Message }
			Assert-ProgressCondition -Condition ($Repeat -ceq $Expected) -Message 'Failed context resumed work'
		}
		$EvidencePath = $Context.evidencePath
		Close-InitialPreparationProgress -Context $Context
		Close-InitialPreparationProgress -Context $Context
		Assert-ProgressCondition -Condition (Test-Path -LiteralPath $EvidencePath -PathType Leaf) -Message 'Evidence removed on close'
		if ($Mode -in @('gating', 'pressure', 'disk')) {
			$Records = @(Get-Content -LiteralPath $EvidencePath | ForEach-Object { $_ | ConvertFrom-Json })
			Assert-ProgressCondition -Condition ($Records.Count -eq $Context.sampleCount -and $Records[-1].attemptId -ceq 'fixture' -and $Records[-1].sample -eq $Context.sampleCount) -Message 'Resource evidence identity or count lost'
			if ($Mode -ceq 'pressure') { Assert-ProgressCondition -Condition ($Records[-1].consecutivePressureSamples -eq 3) -Message 'Failing pressure sample not retained' }
		}
		$ClosedFailure = $null
		try { Invoke-InitialPreparationProgress -Context $Context } catch { $ClosedFailure = $_.Exception.Message }
		Assert-ProgressCondition -Condition ($ClosedFailure -ceq 'resource_progress_closed') -Message 'Closed context resumed work'
	}
}
Test-ProgressSampler
Write-Output 'PASS: synchronous resource progress fixtures'
