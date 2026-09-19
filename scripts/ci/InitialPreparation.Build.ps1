# Dot-source-safe preparation build sequence. Caller owns admission and lease.
. (Join-Path $PSScriptRoot 'InitialPreparation.Readiness.ps1')
function Invoke-InitialPreparationSingleBuild {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)] $Lease,
		[Parameter(Mandatory)][string] $EngineRoot, [Parameter(Mandatory)][string] $TargetRoot,
		[Parameter(Mandatory)][string] $LinuxToolchainRoot, [Parameter(Mandatory)][string] $EvidenceRoot,
		[Parameter(Mandatory)][string] $Target, [Parameter(Mandatory)][string] $Platform,
		[Parameter(Mandatory)][int] $ActionLimit, [Parameter(Mandatory)] $Roots,
		[Parameter(Mandatory)][scriptblock] $OnSample, [hashtable] $KnownAllocations = @{})
	$Owned = $null
	$CleanupVerified = $false
	$BuildOnSample = $OnSample
	$SampleWrapper = { param($BuildCapacity) & $BuildOnSample $BuildCapacity | Out-Null }.GetNewClosure()
	try {
		$Arguments = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'InitialPreparation.BuildInvocation.ps1'),
			'-Target', $Target, '-Platform', $Platform, '-ActionLimit', [string] $ActionLimit,
			'-EngineRoot', $EngineRoot, '-TargetRoot', $TargetRoot, '-LinuxToolchainRoot', $LinuxToolchainRoot, '-EvidenceRoot', $EvidenceRoot)
		$Owned = Start-InitialPreparationProcess -Attempt $Attempt -Lease $Lease -Executable (Join-Path $PSHOME 'powershell.exe') -Arguments $Arguments -WorkingDirectory $TargetRoot
		$Producer = [pscustomobject]@{ process = $Owned.process; job = $Owned.supervision }
		$Producer | Add-Member -MemberType ScriptMethod -Name RequestStop -Value { $this.job.StopAndWait(5000) }
		$Monitor = Watch-InitialPreparationResource -Attempt $Attempt -OwnedProducer $Producer -Roots $Roots -KnownAllocations $KnownAllocations -OnSample $SampleWrapper -CompletionProbe { param($Item) return $Item.process.HasExited }
		if ($Monitor.code -cne 'producer_completed') { throw 'build_monitor_failed' }
		$Owned.supervision.StopAndWait(5000)
		$CleanupVerified = $true
		$ResultPath = Join-Path $EvidenceRoot 'native-result.json'
		if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf) -or (Get-Item -LiteralPath $ResultPath).Length -gt 4096) { throw 'build_result_missing' }
		$Result = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json
		if ($Result.schemaVersion -ne 1 -or $Result.target -cne $Target -or $Result.platform -cne $Platform -or
			$null -ne $Result.infrastructureFailure -or ($Result.nativeExitCode -isnot [int] -and $Result.nativeExitCode -isnot [long]) -or
			$Owned.process.ExitCode -ne $Result.nativeExitCode) { throw 'build_result_invalid' }
		return [pscustomobject]@{ nativeExitCode = [int] $Result.nativeExitCode; cleanupVerified = $true }
	} finally {
		if ($null -ne $Owned -and -not $CleanupVerified) { $Owned.supervision.StopAndWait(5000) }
	}
}

function Invoke-InitialPreparationBuildSequence {
	[CmdletBinding()]
	[OutputType([object[]])]
	param([Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)] $Lease,
		[Parameter(Mandatory)][string] $EngineRoot, [Parameter(Mandatory)][string] $TargetRoot,
		[Parameter(Mandatory)][string] $LinuxToolchainRoot, [Parameter(Mandatory)][string] $EvidenceRoot,
		[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string] $InputDigest,
		[Parameter(Mandatory)] $Roots,
		[Parameter(Mandatory)][scriptblock] $ValidateInputs,
		[Parameter(Mandatory)][scriptblock] $AssertReadiness,
		[Parameter(Mandatory)][scriptblock] $OnSample,
		[hashtable] $KnownAllocations = @{})
	Assert-InitialPreparationAttempt -Attempt $Attempt
	$Entries = @($script:InitialPreparationLeaseRegistry.Values | Where-Object { $_.leaseId -ceq $Lease.leaseId })
	if ($Entries.Count -ne 1 -or $Entries[0].attemptId -cne $Attempt.attemptId -or $Entries[0].ownerPid -ne $PID -or
		$Entries[0].ownerStartUtc -cne (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o') -or -not $Entries[0].stream.CanWrite) { throw 'process_lease_invalid' }
	$Results = New-Object Collections.ArrayList
	$SequenceFailure = $null
	$SequenceComplete = $false
	$SummaryPath = Join-Path $EvidenceRoot 'sequence-result.json'
	# Reserve an exclusive, new receipt before any build. An interrupted empty
	# receipt is incomplete evidence, never a reusable successful baseline.
	$SummaryStream = [IO.File]::Open($SummaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
	try {
	for ($Pair = 1; $Pair -le 3; $Pair++) {
		foreach ($Platform in @('Win64', 'Linux')) {
			if ((Get-InitialPreparationTick) -ge $Attempt.stopUsefulWorkTicks) { throw 'useful_work_deadline' }
			$Target = if ($Platform -ceq 'Win64') { 'AethelnOnlineClient' } else { 'AethelnOnlineServer' }
			$Before = & $ValidateInputs
			if ($Before -isnot [string] -or $Before -cne $InputDigest) { throw 'build_input_drift' }
			$Ready = & $AssertReadiness
			if ($Ready -isnot [bool] -or -not $Ready) { throw 'build_readiness_unproven' }
			$Capacity = Get-InitialPreparationCapacity -Roots $Roots -Attempt $Attempt -KnownAllocations $KnownAllocations
			$Limit = Get-InitialPreparationActionLimit -Capacity $Capacity
			& $OnSample $Capacity | Out-Null
			$InvocationRoot = Join-Path $EvidenceRoot ('build-{0}-{1}' -f $Pair, $Platform)
			if (Test-Path -LiteralPath $InvocationRoot) { throw 'build_evidence_exists' }
			$null = New-Item -ItemType Directory -Path $InvocationRoot
			$ReadinessRoot = Join-Path $InvocationRoot 'ubt-readiness'
			$null = New-Item -ItemType Directory -Path $ReadinessRoot
			$UbtReadiness = Invoke-InitialPreparationUbtReadiness -Attempt $Attempt -Lease $Lease -EngineRoot $EngineRoot -EvidenceRoot $ReadinessRoot -Roots $Roots -OnSample $OnSample -KnownAllocations $KnownAllocations
			if ($UbtReadiness.ready -isnot [bool] -or -not $UbtReadiness.ready -or
				$UbtReadiness.cleanupVerified -isnot [bool] -or -not $UbtReadiness.cleanupVerified -or
				$UbtReadiness.scope -isnot [string] -or $UbtReadiness.scope -cne 'ubt_dependency_rebuild_branch') { throw 'build_ubt_readiness_unproven' }
			# The dependency scan can consume substantial time. Keep the earlier
			# admission gate, but derive this target's concurrency from fresh capacity.
			if ((Get-InitialPreparationTick) -ge $Attempt.stopUsefulWorkTicks) { throw 'useful_work_deadline' }
			$Capacity = Get-InitialPreparationCapacity -Roots $Roots -Attempt $Attempt -KnownAllocations $KnownAllocations
			$Limit = Get-InitialPreparationActionLimit -Capacity $Capacity
			& $OnSample $Capacity | Out-Null
			$Result = $null
			$StartedTicks = Get-InitialPreparationTick
			try {
				$Result = Invoke-InitialPreparationSingleBuild -Attempt $Attempt -Lease $Lease -EngineRoot $EngineRoot -TargetRoot $TargetRoot -LinuxToolchainRoot $LinuxToolchainRoot -EvidenceRoot $InvocationRoot -Target $Target -Platform $Platform -ActionLimit $Limit -Roots $Roots -KnownAllocations $KnownAllocations -OnSample $OnSample
			} finally {
				$After = & $ValidateInputs
				if ($After -isnot [string] -or $After -cne $InputDigest) { throw 'build_input_drift' }
			}
			if ((Get-InitialPreparationTick) -ge $Attempt.stopUsefulWorkTicks) { throw 'useful_work_deadline' }
			if ($Result.cleanupVerified -isnot [bool] -or -not $Result.cleanupVerified -or
				($Result.nativeExitCode -isnot [int] -and $Result.nativeExitCode -isnot [long]) -or $Result.nativeExitCode -ne 0) { throw 'build_failed' }
			[void] $Results.Add([pscustomobject]@{ ordinal = $Results.Count + 1; pair = $Pair; target = $Target; platform = $Platform; configuration = 'Development'; targetRevision = $Attempt.targetRevision; inputDigest = $InputDigest; nativeExitCode = 0; actionLimit = $Limit; cleanupVerified = $true; startedTicks = $StartedTicks; finishedTicks = (Get-InitialPreparationTick); ubtReadiness = $UbtReadiness; executorFlags = @('-UBA', '-UBADisableRemote', '-NoXGE', '-NoSNDBS', '-NoFASTBuild', ('-MaxParallelActions=' + $Limit)) })
		}
	}
	$SequenceComplete = $true
	return ,@($Results)
	} catch {
		$SequenceFailure = if ($_.Exception.Message -cmatch '^[a-z_]{1,80}$') { $_.Exception.Message } else { 'sequence_failed' }
		throw
	} finally {
		try {
			$Summary = [ordered]@{ schemaVersion = 1; attemptId = $Attempt.attemptId; targetRevision = $Attempt.targetRevision;
				inputDigest = $InputDigest; complete = $SequenceComplete; baselineVerified = $false;
				failureCode = $SequenceFailure; builds = @($Results); finishedTicks = (Get-InitialPreparationTick) }
			$Bytes = [Text.Encoding]::UTF8.GetBytes(($Summary | ConvertTo-Json -Depth 8))
			if ($Bytes.Length -gt 32768) { throw 'sequence_evidence_limit' }
			$SummaryStream.Write($Bytes, 0, $Bytes.Length)
			$SummaryStream.Flush($true)
		} finally { $SummaryStream.Dispose() }
	}
}
