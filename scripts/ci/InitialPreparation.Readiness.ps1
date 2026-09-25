# Dot-source-safe UBT dependency readiness. Caller owns admission and engine lease.
# This proves only the pinned BuildUBT dependency/DLL branch, never a full baseline.
function Invoke-InitialPreparationUbtReadiness {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)] $Lease,
		[Parameter(Mandatory)][string] $EngineRoot, [Parameter(Mandatory)][string] $EvidenceRoot,
		[Parameter(Mandatory)] $Roots, [Parameter(Mandatory)][scriptblock] $OnSample,
		[hashtable] $KnownAllocations = @{})
	Assert-InitialPreparationAttempt -Attempt $Attempt
	$Entries = @($script:InitialPreparationLeaseRegistry.Values | Where-Object { $_.leaseId -ceq $Lease.leaseId })
	if ($Entries.Count -ne 1 -or $Entries[0].attemptId -cne $Attempt.attemptId -or $Entries[0].ownerPid -ne $PID -or
		$Entries[0].ownerStartUtc -cne (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o') -or -not $Entries[0].stream.CanWrite) { throw 'process_lease_invalid' }
	foreach ($Path in @($EngineRoot, $EvidenceRoot)) {
		if ($Path -cnotmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':') -or
			$Path -match '["%!&|<>^()\x00-\x1f]' -or -not (Test-Path -LiteralPath $Path -PathType Container)) { throw 'readiness_path_invalid' }
		Assert-InitialPreparationPlainPath -Path $Path -Reason 'readiness_path_invalid'
	}
	# DotnetDepends assigns its second batch argument with %2, so reject a
	# whitespace-bearing output path instead of depending on double-quote parsing.
	if ($EvidenceRoot -match '\s' -or (Test-InitialPreparationWithin -Candidate $EvidenceRoot -Parent $EngineRoot) -or
		(Test-InitialPreparationWithin -Candidate $EngineRoot -Parent $EvidenceRoot)) { throw 'readiness_path_invalid' }
	if ((Get-InitialPreparationTick) -ge $Attempt.stopUsefulWorkTicks) { throw 'useful_work_deadline' }
	$Pins = Get-InitialPreparationDirectoryPin -Directory $EvidenceRoot
	$Owned = $null
	$SummaryStream = $null
	$CleanupVerified = $false
	$Result = [ordered]@{ schemaVersion = 1; attemptId = $Attempt.attemptId; targetRevision = $Attempt.targetRevision;
		scope = 'ubt_dependency_rebuild_branch'; ready = $false; baselineVerified = $false; cleanupVerified = $false;
		scanExitCode = $null; comparisonExitCode = $null; dependencySha256 = $null; scanSha256 = $null; failureCode = $null; finishedTicks = $null }
	try {
		foreach ($Name in @('readiness-result.json', 'readiness-native-result.json', 'scan.log', 'comparison.log', 'dependencies.csv', 'scan-temp')) {
			if (Test-Path -LiteralPath (Join-Path $EvidenceRoot $Name)) { throw 'readiness_evidence_exists' }
		}
		try { $SummaryStream = [IO.File]::Open((Join-Path $EvidenceRoot 'readiness-result.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read) } catch { throw 'readiness_evidence_exists' }
		$SampleCallback = $OnSample
		$SampleWrapper = { param($Capacity) & $SampleCallback $Capacity | Out-Null }.GetNewClosure()
		$Arguments = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'InitialPreparation.ReadinessInvocation.ps1'),
			'-EngineRoot', $EngineRoot, '-EvidenceRoot', $EvidenceRoot)
		$Owned = Start-InitialPreparationProcess -Attempt $Attempt -Lease $Lease -Executable (Join-Path $PSHOME 'powershell.exe') -Arguments $Arguments -WorkingDirectory $EvidenceRoot
		$Producer = [pscustomobject]@{ process = $Owned.process; job = $Owned.supervision }
		$Producer | Add-Member -MemberType ScriptMethod -Name RequestStop -Value { $this.job.StopAndWait(5000) }
		$Monitor = Watch-InitialPreparationResource -Attempt $Attempt -OwnedProducer $Producer -Roots $Roots -KnownAllocations $KnownAllocations -OnSample $SampleWrapper -CompletionProbe { param($Item) return $Item.process.HasExited }
		if ($Monitor.code -cne 'producer_completed') {
			if ($Monitor.code -ceq 'useful_work_deadline') { throw 'useful_work_deadline' }
			throw 'readiness_monitor_failed'
		}
		$Owned.supervision.StopAndWait(5000)
		$CleanupVerified = $true
		if ((Get-InitialPreparationTick) -ge $Attempt.stopUsefulWorkTicks -or $Owned.supervision.TimedOut) { throw 'useful_work_deadline' }
		$NativePath = Join-Path $EvidenceRoot 'readiness-native-result.json'
		$Source = $null
		try {
			$Source = New-Object IO.FileStream([Aetheln.PreparationDirectory]::OpenSource($NativePath), [IO.FileAccess]::Read)
			if ($Source.Length -lt 1 -or $Source.Length -gt 4096) { throw 'readiness_result_invalid' }
			$Reader = New-Object IO.StreamReader($Source, (New-Object Text.UTF8Encoding($false, $true)))
			try { $Native = $Reader.ReadToEnd() | ConvertFrom-Json } finally { $Reader.Dispose() }
		} catch { throw 'readiness_result_invalid' } finally { if ($null -ne $Source) { $Source.Dispose() } }
		$Fields = @('schemaVersion', 'scope', 'ready', 'scanExitCode', 'comparisonExitCode', 'dependencySha256', 'scanSha256', 'failureCode')
		if (@($Native.PSObject.Properties).Count -ne $Fields.Count) { throw 'readiness_result_invalid' }
		foreach ($Field in $Fields) { if ($Native.PSObject.Properties.Name -cnotcontains $Field) { throw 'readiness_result_invalid' } }
		# PowerShell comparisons filter arrays: [] or [expected] can produce a
		# falsey mismatch result. Require scalar types before comparing values.
		if (($Native.schemaVersion -isnot [int] -and $Native.schemaVersion -isnot [long]) -or
			$Native.schemaVersion -ne 1 -or $Native.scope -isnot [string] -or
			$Native.scope -cne $Result.scope -or $Native.ready -isnot [bool]) { throw 'readiness_result_invalid' }
		foreach ($Field in @('scanExitCode', 'comparisonExitCode')) {
			if ($null -ne $Native.$Field -and $Native.$Field -isnot [int] -and $Native.$Field -isnot [long]) { throw 'readiness_result_invalid' }
			$Result[$Field] = $Native.$Field
		}
		foreach ($Field in @('dependencySha256', 'scanSha256')) {
			if ($null -ne $Native.$Field -and ($Native.$Field -isnot [string] -or $Native.$Field -cnotmatch '^[0-9a-f]{64}$')) { throw 'readiness_result_invalid' }
			$Result[$Field] = $Native.$Field
		}
		if (-not $Native.ready) {
			$Failures = @('ubt_readiness_input_missing', 'ubt_readiness_path_invalid', 'ubt_dependency_scan_failed', 'ubt_dependency_scan_invalid', 'ubt_dependencies_changed', 'ubt_dependency_comparison_failed', 'ubt_readiness_capture_failed')
			if ($Owned.process.ExitCode -ne 1 -or $Native.failureCode -isnot [string] -or
				$Native.failureCode -cnotin $Failures) { throw 'readiness_result_invalid' }
			throw $Native.failureCode
		}
		if ($Owned.process.ExitCode -ne 0 -or $null -ne $Native.failureCode -or $null -eq $Native.scanExitCode -or
			$Native.scanExitCode -ne 0 -or $null -eq $Native.comparisonExitCode -or $Native.comparisonExitCode -ne 0 -or
			$null -eq $Native.dependencySha256 -or $null -eq $Native.scanSha256) { throw 'readiness_result_invalid' }
		$Result.ready = $true
	} catch {
		$Result.failureCode = if ($_.Exception.Message -cmatch '^[a-z_]{1,80}$') { $_.Exception.Message } else { 'readiness_failed' }
		throw
	} finally {
		try {
			if ($null -ne $Owned -and -not $CleanupVerified) { $Owned.supervision.StopAndWait(5000); $CleanupVerified = $true }
			$Result.cleanupVerified = $CleanupVerified
		} catch { $Result.ready = $false; $Result.failureCode = 'readiness_cleanup_unproven'; throw 'readiness_cleanup_unproven' } finally {
			try {
				if ($null -ne $SummaryStream) {
					$Result.finishedTicks = Get-InitialPreparationTick
					$Bytes = [Text.Encoding]::UTF8.GetBytes(($Result | ConvertTo-Json -Compress))
					$SummaryStream.Write($Bytes, 0, $Bytes.Length); $SummaryStream.Flush($true)
				}
			} finally {
				if ($null -ne $SummaryStream) { $SummaryStream.Dispose() }
				foreach ($Pin in $Pins) { $Pin.Dispose() }
			}
		}
	}
	return [pscustomobject] $Result
}
