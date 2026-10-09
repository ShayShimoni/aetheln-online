param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path (Split-Path $PSScriptRoot)
$Core = Join-Path $RepositoryRoot 'scripts/ci/InitialPreparation.Core.ps1'
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnInitialPreparationCore-' + [guid]::NewGuid().ToString('N'))
$RetainFixtureEvidence = $false

function Assert-True($Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Rejected([scriptblock] $Action, [string] $Reason, [string] $Message) {
	$Failure = $null
	try { & $Action | Out-Null } catch { $Failure = [string] $_.Exception.Message }
	Assert-True -Condition ($Failure -eq $Reason) -Message "$Message Expected '$Reason'; received '$Failure'."
}

function Assert-ClosedProperty($Value, [string[]] $Names, [string] $Message) {
	Assert-True -Condition ($null -ne $Value) -Message "$Message Value must exist."
	$Actual = @($Value.PSObject.Properties | ForEach-Object Name)
	Assert-True -Condition ($Actual.Count -eq $Names.Count) -Message "$Message Property count must be exact."
	foreach ($Name in $Names) {
		Assert-True -Condition ($Actual -ccontains $Name) -Message "$Message Missing property '$Name'."
	}
}

function Get-TestAttempt([string] $Id = 'fixture-attempt') {
	return New-InitialPreparationAttempt `
		-Repository 'owner/repository' `
		-ControllerRevision ('a' * 40) `
		-TargetRevision ('b' * 40) `
		-AttemptId $Id
}

function Get-CapacityRecord([double] $Ram, [double] $Commit, [int] $Cores = 8) {
	return [pscustomobject]@{
		physicalCores = $Cores
		availablePhysicalRamGiB = $Ram
		commitHeadroomGiB = $Commit
		volumes = @([pscustomobject]@{ volumeId = 'fixture-volume'; availableBytes = 100GB; knownAllocationBytes = 0L; recoveryFloorBytes = 20GB })
		sampleTicks = [Diagnostics.Stopwatch]::GetTimestamp()
	}
}

function Initialize-LeaseFixture([string] $Name) {
	$Root = Join-Path $FixtureRoot $Name
	New-Item -ItemType Directory -Path $Root -Force | Out-Null
	return Join-Path $Root 'preparation.lease.json'
}

function Test-FunctionSurface {
	$Required = @(
		@{ Name = 'New-InitialPreparationAttempt'; Parameters = @('Repository', 'ControllerRevision', 'TargetRevision', 'AttemptId') },
		@{ Name = 'Enter-InitialPreparationLease'; Parameters = @('Attempt', 'LeasePath') },
		@{ Name = 'Test-InitialPreparationOwnership'; Parameters = @('Lease', 'OwnedProcesses') },
		@{ Name = 'Get-InitialPreparationCapacity'; Parameters = @('Roots', 'Attempt') },
		@{ Name = 'Get-InitialPreparationActionLimit'; Parameters = @('Capacity') },
		@{ Name = 'Watch-InitialPreparationResource'; Parameters = @('Attempt', 'OwnedProducer', 'Roots', 'OnSample') },
		@{ Name = 'Stop-InitialPreparationOwnedTree'; Parameters = @('Lease', 'DeadlineTicks') },
		@{ Name = 'Write-InitialPreparationReceipt'; Parameters = @('State', 'Artifacts', 'Path') }
	)
	foreach ($Contract in $Required) {
		$Command = Get-Command $Contract.Name -CommandType Function -ErrorAction SilentlyContinue
		Assert-True -Condition ($null -ne $Command) -Message "Required function $($Contract.Name) must exist."
		foreach ($Parameter in $Contract.Parameters) {
			Assert-True -Condition ($Command.Parameters.ContainsKey($Parameter)) -Message "$($Contract.Name) must expose -$Parameter."
		}
	}
}

function Test-AttemptContract {
	$Attempt = Get-TestAttempt
	Assert-ClosedProperty -Value $Attempt -Names @(
		'schemaVersion', 'attemptId', 'repository', 'controllerRevision',
		'targetRevision', 'policyVersion', 'startedUtc', 'monotonicStartTicks',
		'monotonicFrequency', 'deadlineTicks', 'admissionDeadlineTicks',
		'stopUsefulWorkTicks', 'cleanupDeadlineTicks', 'publicationDeadlineTicks'
	) -Message 'Attempt context'
	Assert-True -Condition ($Attempt.schemaVersion -eq 1) -Message 'Attempt schema must be version 1.'
	Assert-True -Condition ($Attempt.policyVersion -ceq 'issue167-preparation-v1') -Message 'Policy identity must be exact.'
	Assert-True -Condition ($Attempt.repository -ceq 'owner/repository') -Message 'Repository identity must be preserved.'
	Assert-True -Condition ($Attempt.controllerRevision -ceq ('a' * 40)) -Message 'Controller revision must be preserved.'
	Assert-True -Condition ($Attempt.targetRevision -ceq ('b' * 40)) -Message 'Target revision must be preserved.'
	Assert-True -Condition ([long] $Attempt.monotonicFrequency -gt 0) -Message 'Monotonic frequency must be positive.'
	$Frequency = [long] $Attempt.monotonicFrequency
	$Start = [long] $Attempt.monotonicStartTicks
	Assert-True -Condition ([long] $Attempt.admissionDeadlineTicks -eq ($Start + (45L * 60L * $Frequency))) -Message 'Admission ends at exactly minute 45.'
	Assert-True -Condition ([long] $Attempt.stopUsefulWorkTicks -eq ($Start + (330L * 60L * $Frequency))) -Message 'Useful work ends at exactly minute 330.'
	Assert-True -Condition ([long] $Attempt.cleanupDeadlineTicks -eq ($Start + (340L * 60L * $Frequency))) -Message 'Cleanup ends at exactly minute 340.'
	Assert-True -Condition ([long] $Attempt.deadlineTicks -eq ($Start + (360L * 60L * $Frequency))) -Message 'Attempt ends at exactly minute 360.'
	Assert-True -Condition ([long] $Attempt.publicationDeadlineTicks -eq [long] $Attempt.deadlineTicks) -Message 'Publication shares the immutable attempt deadline.'

	foreach ($Invalid in @(
		@{ Repository = 'owner'; Controller = ('a' * 40); Target = ('b' * 40); Id = 'x' },
		@{ Repository = 'owner/repository'; Controller = 'not-a-sha'; Target = ('b' * 40); Id = 'x' },
		@{ Repository = 'owner/repository'; Controller = ('a' * 40); Target = 'not-a-sha'; Id = 'x' },
		@{ Repository = 'owner/repository'; Controller = ('a' * 40); Target = ('b' * 40); Id = '' }
	)) {
		Assert-Rejected -Action {
			New-InitialPreparationAttempt -Repository $Invalid.Repository -ControllerRevision $Invalid.Controller -TargetRevision $Invalid.Target -AttemptId $Invalid.Id
		} -Reason 'attempt_identity_invalid' -Message 'Malformed attempt identity must fail closed.'
	}

	$Snapshot = $Attempt | ConvertTo-Json -Depth 5 -Compress
	Start-Sleep -Milliseconds 5
	Assert-True -Condition (($Attempt | ConvertTo-Json -Depth 5 -Compress) -ceq $Snapshot) -Message 'Elapsed wall time must not mutate or extend an attempt.'
	Assert-Rejected -Action { Get-TestAttempt } -Reason 'attempt_exists' -Message 'Creating the same attempt again must not reset its deadline.'
	foreach ($DeadlineField in @('admissionDeadlineTicks', 'stopUsefulWorkTicks', 'cleanupDeadlineTicks', 'deadlineTicks', 'publicationDeadlineTicks')) {
		$AlteredAttempt = $Attempt.PSObject.Copy()
		$AlteredAttempt.$DeadlineField += $Frequency
		Assert-Rejected -Action { Assert-InitialPreparationAttempt -Attempt $AlteredAttempt } -Reason 'attempt_identity_invalid' -Message 'A child cannot change any immutable attempt boundary.'
	}
}

function Test-ActionLimitContract {
	$Cases = @(
		@{ Ram = 32; Commit = 32; Cores = 12; Expected = 4 },
		@{ Ram = 15; Commit = 64; Cores = 16; Expected = 3 },
		@{ Ram = 64; Commit = 12; Cores = 16; Expected = 2 },
		@{ Ram = 64; Commit = 64; Cores = 1; Expected = 1 },
		@{ Ram = 9; Commit = 9; Cores = 8; Expected = 1 }
	)
	foreach ($Case in $Cases) {
		$Result = Get-InitialPreparationActionLimit -Capacity (Get-CapacityRecord -Ram $Case.Ram -Commit $Case.Commit -Cores $Case.Cores)
		Assert-True -Condition ($Result -eq $Case.Expected) -Message "Action limit must implement the exact formula for RAM=$($Case.Ram), commit=$($Case.Commit), cores=$($Case.Cores)."
	}
	foreach ($Capacity in @(
		(Get-CapacityRecord -Ram 8.999 -Commit 32 -Cores 8),
		(Get-CapacityRecord -Ram 32 -Commit 8.999 -Cores 8),
		(Get-CapacityRecord -Ram 32 -Commit 32 -Cores 0),
		[pscustomobject]@{ physicalCores = 8; availablePhysicalRamGiB = $null; commitHeadroomGiB = 32; volumes = @(); sampleTicks = 1 }
	)) {
		Assert-Rejected -Action { Get-InitialPreparationActionLimit -Capacity $Capacity } -Reason 'resource_admission_refused' -Message 'Capacity below one safe action or with missing values must refuse admission.'
	}
}

function Test-LeaseAndOwnershipContract {
	$Attempt = Get-TestAttempt -Id 'lease-attempt'
	$LeasePath = Initialize-LeaseFixture -Name 'exclusive'
	$Lease = Enter-InitialPreparationLease -Attempt $Attempt -LeasePath $LeasePath
	Assert-ClosedProperty -Value $Lease -Names @('leaseId', 'ownerPid', 'ownerStartUtc', 'acquiredTicks') -Message 'Lease receipt'
	Assert-True -Condition ($Lease.ownerPid -eq $PID -and [long] $Lease.acquiredTicks -ge [long] $Attempt.monotonicStartTicks) -Message 'Lease must bind the current owner identity and monotonic acquisition time.'
	Assert-Rejected -Action { Enter-InitialPreparationLease -Attempt $Attempt -LeasePath $LeasePath } -Reason 'lease_nested' -Message 'The same owner must not reacquire its lease.'

	$OtherAttempt = Get-TestAttempt -Id 'concurrent-attempt'
	Assert-Rejected -Action { Enter-InitialPreparationLease -Attempt $OtherAttempt -LeasePath $LeasePath } -Reason 'lease_held' -Message 'A concurrent attempt must not take an existing live lease.'
	Assert-Rejected -Action { Enter-InitialPreparationLease -Attempt $Attempt -LeasePath (Join-Path $RepositoryRoot 'unsafe.lease.json') } -Reason 'lease_path_invalid' -Message 'A repository-contained lease must be rejected.'
	Assert-Rejected -Action { Enter-InitialPreparationLease -Attempt $Attempt -LeasePath 'relative.lease.json' } -Reason 'lease_path_invalid' -Message 'A relative lease path must be rejected.'

	$Current = Get-Process -Id $PID
	$Owned = @([pscustomobject]@{
		processId = $PID
		startTimeUtc = $Current.StartTime.ToUniversalTime().ToString('o')
		parentProcessId = $null
		role = 'owner'
	})
	$Ownership = Test-InitialPreparationOwnership -Lease $Lease -OwnedProcesses $Owned
	Assert-True -Condition ($Ownership.ok -and $Ownership.code -ceq 'ownership_verified') -Message 'A live identity-matched owner must verify.'

	$Reused = @([pscustomobject]@{
		processId = $PID
		startTimeUtc = '2000-01-01T00:00:00.0000000Z'
		parentProcessId = $null
		role = 'owner'
	})
	$Ownership = Test-InitialPreparationOwnership -Lease $Lease -OwnedProcesses $Reused
	Assert-True -Condition (-not $Ownership.ok -and $Ownership.code -ceq 'owned_process_identity_mismatch') -Message 'PID reuse or start-time mismatch must fail closed.'

	$DeadOwnerLease = [pscustomobject]@{
		leaseId = 'dead-owner'
		ownerPid = 2147483000
		ownerStartUtc = '2000-01-01T00:00:00.0000000Z'
		acquiredTicks = [long] $Attempt.monotonicStartTicks
	}
	$SurvivingChild = @([pscustomobject]@{
		processId = $PID
		startTimeUtc = $Current.StartTime.ToUniversalTime().ToString('o')
		parentProcessId = 2147483000
		role = 'build-child'
	})
	$Ownership = Test-InitialPreparationOwnership -Lease $DeadOwnerLease -OwnedProcesses $SurvivingChild
	Assert-True -Condition (-not $Ownership.ok -and $Ownership.code -ceq 'surviving_owned_child') -Message 'A dead owner with an identity-matched surviving child must be detected.'
}

function Test-CapacityContract {
	$Attempt = Get-TestAttempt -Id 'capacity-attempt'
	$Root = Join-Path $FixtureRoot 'capacity-root'
	New-Item -ItemType Directory -Path $Root -Force | Out-Null
	$Capacity = Get-InitialPreparationCapacity -Roots ([ordered]@{ evidence = $Root; logs = $Root }) -Attempt $Attempt
	Assert-True -Condition (@($Capacity.volumes).Count -eq 1) -Message 'Two roots on one physical volume must be deduplicated.'
	Assert-True -Condition ($null -ne $Capacity.availablePhysicalRamGiB -and $null -ne $Capacity.commitHeadroomGiB) -Message 'RAM and commit headroom readings are mandatory.'
	Assert-True -Condition ([long] $Capacity.sampleTicks -ge [long] $Attempt.monotonicStartTicks) -Message 'Capacity sampling must use the attempt monotonic clock.'
	foreach ($Volume in @($Capacity.volumes)) {
		Assert-True -Condition ($null -ne $Volume.availableBytes -and $null -ne $Volume.knownAllocationBytes) -Message 'Each physical volume must report free bytes and known allocation.'
		Assert-True -Condition ([long] $Volume.recoveryFloorBytes -eq 21474836480L) -Message 'Every touched volume must preserve the exact 20 GiB recovery floor.'
	}
	Assert-Rejected -Action { Get-InitialPreparationCapacity -Roots ([ordered]@{ bad = (Join-Path $FixtureRoot 'missing-root') }) -Attempt $Attempt } -Reason 'resource_root_invalid' -Message 'Missing resource roots must fail closed.'
	$Allocated = Get-InitialPreparationCapacity -Roots ([ordered]@{ evidence = $Root; logs = $Root }) -Attempt $Attempt -KnownAllocations @{ evidence = 1GB; logs = 2GB }
	Assert-True -Condition ($Allocated.volumes.Count -eq 1 -and $Allocated.volumes[0].knownAllocationBytes -eq 3GB) -Message 'Known allocations must be summed once on the shared volume.'
	Assert-True -Condition ($Allocated.volumes[0].volumeId -match '^\\\\\?\\Volume\{[0-9a-f-]+\}\\$') -Message 'Capacity identity must be the resolved volume GUID, not its drive letter.'
	$NoSpace = Get-CapacityRecord -Ram 32 -Commit 32
	$NoSpace.volumes[0].availableBytes = 21GB
	$NoSpace.volumes[0].knownAllocationBytes = 2GB
	Assert-Rejected -Action { Get-InitialPreparationActionLimit -Capacity $NoSpace } -Reason 'resource_admission_refused' -Message 'Action admission must reserve known allocations plus the recovery floor.'
}

function Test-LeaseLifecycle {
	$Attempt = Get-TestAttempt -Id 'lease-lifecycle'
	$LeasePath = Initialize-LeaseFixture -Name 'lease-lifecycle'
	$Lease = Enter-InitialPreparationLease -Attempt $Attempt -LeasePath $LeasePath
	Assert-Rejected -Action { Exit-InitialPreparationLease -Lease $Lease } -Reason 'cleanup_unproven' -Message 'A lease cannot release before owned cleanup is verified.'
	$ContentionDenied = $false
	try {
		$Contender = [IO.File]::Open($LeasePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
		$Contender.Dispose()
	} catch [IO.IOException] { $ContentionDenied = $true }
	Assert-True -Condition $ContentionDenied -Message 'The host lease must retain an operating-system file lock for its lifetime.'
	$null = Stop-InitialPreparationOwnedTree -Lease $Lease -DeadlineTicks $Attempt.cleanupDeadlineTicks
	Exit-InitialPreparationLease -Lease $Lease
	$SecondAttempt = Get-TestAttempt -Id 'lease-lifecycle-next'
	$SecondLease = Enter-InitialPreparationLease -Attempt $SecondAttempt -LeasePath $LeasePath
	Assert-True -Condition ($SecondLease.leaseId -cne $Lease.leaseId) -Message 'A verified release must permit a later distinct attempt.'
	$null = Stop-InitialPreparationOwnedTree -Lease $SecondLease -DeadlineTicks $SecondAttempt.cleanupDeadlineTicks
	Exit-InitialPreparationLease -Lease $SecondLease
}

function Test-LeaseJournalCapacity {
	$Owner = Get-Process -Id $PID
	$OwnerStartUtc = $Owner.StartTime.ToUniversalTime().ToString('o')
	$PriorLeaseId = 'b' * 32
	$PriorHeld = [ordered]@{ schemaVersion = 1; state = 'held'; leaseId = $PriorLeaseId;
		attemptId = 'journal-prior'; ownerPid = $PID; ownerStartUtc = $OwnerStartUtc }
	$PriorReleased = [ordered]@{ schemaVersion = 1; state = 'released'; leaseId = $PriorLeaseId;
		attemptId = 'journal-prior'; cleanupVerified = $true }
	$PriorJournal = ($PriorHeld | ConvertTo-Json -Compress) + "`n" + ($PriorReleased | ConvertTo-Json -Compress) + "`n"
	$PriorBytes = [Text.Encoding]::UTF8.GetByteCount($PriorJournal)
	foreach ($Case in @(
		@{ name = 'one-byte-short'; id = ('n' * 128); adjustment = 1; reject = $true },
		@{ name = 'exact-fit'; id = ('e' * 128); adjustment = 0; reject = $false }
	)) {
		$Attempt = Get-TestAttempt -Id $Case.id
		$LeasePath = Initialize-LeaseFixture -Name $Case.name
		# Every generated lease GUID is 32 ASCII characters; use the real owner and attempt identity.
		$ExpectedHeld = [ordered]@{ schemaVersion = 1; state = 'held'; leaseId = ('a' * 32);
			attemptId = $Attempt.attemptId; ownerPid = $PID; ownerStartUtc = $OwnerStartUtc }
		$ExpectedReleased = [ordered]@{ schemaVersion = 1; state = 'released'; leaseId = ('a' * 32);
			attemptId = $Attempt.attemptId; cleanupVerified = $true }
		$ReleaseLength = [Text.Encoding]::UTF8.GetByteCount(($ExpectedReleased | ConvertTo-Json -Compress) + "`n")
		$PairLength = [Text.Encoding]::UTF8.GetByteCount(($ExpectedHeld | ConvertTo-Json -Compress) + "`n") + $ReleaseLength
		$InitialLength = 65536 - $PairLength + $Case.adjustment
		# Leading JSON whitespace preserves a genuine paired released journal at the exact boundary.
		[IO.File]::WriteAllText($LeasePath, (' ' * ($InitialLength - $PriorBytes)) + $PriorJournal, (New-Object Text.UTF8Encoding($false)))
		$BeforeHash = (Get-FileHash -LiteralPath $LeasePath -Algorithm SHA256).Hash
		$Lease = $null
		$Failure = $null
		try { $Lease = Enter-InitialPreparationLease -Attempt $Attempt -LeasePath $LeasePath }
		catch { $Failure = [string] $_.Exception.Message }
		if ($Case.reject) {
			# Release an old implementation's unexpected admission so the RED fixture leaves no owner behind.
			if ($null -ne $Lease) {
				$null = Stop-InitialPreparationOwnedTree -Lease $Lease -DeadlineTicks $Attempt.cleanupDeadlineTicks
				Exit-InitialPreparationLease -Lease $Lease
				Write-Output "Unexpected journal admission: before=$InitialLength after=$((Get-Item -LiteralPath $LeasePath).Length) limit=65536"
			}
			Assert-True -Condition ($Failure -ceq 'lease_journal_limit') -Message 'Insufficient release space must refuse before writing held ownership.'
			Assert-True -Condition ((Get-FileHash -LiteralPath $LeasePath -Algorithm SHA256).Hash -ceq $BeforeHash) -Message 'Capacity refusal must preserve every journal byte.'
			Assert-True -Condition (-not $script:InitialPreparationLeaseRegistry.ContainsKey($LeasePath.ToLowerInvariant())) -Message 'Capacity refusal must not register an owner.'
			$Probe = [IO.File]::Open($LeasePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
			$Probe.Dispose()
		} else {
			Assert-True -Condition ($null -eq $Failure -and $null -ne $Lease) -Message 'An exact-fit complete lease cycle must be admitted.'
			$Entry = $script:InitialPreparationLeaseRegistry[$LeasePath.ToLowerInvariant()]
			Assert-True -Condition ($Entry.stream.Length + $ReleaseLength -eq 65536) -Message 'Held bytes must leave exactly the reserved release space.'
			Assert-Rejected -Action { Exit-InitialPreparationLease -Lease $Lease } -Reason 'cleanup_unproven' -Message 'Reservation must not bypass cleanup proof.'
			$null = Stop-InitialPreparationOwnedTree -Lease $Lease -DeadlineTicks $Attempt.cleanupDeadlineTicks
			Exit-InitialPreparationLease -Lease $Lease
			Assert-True -Condition ((Get-Item -LiteralPath $LeasePath).Length -eq 65536) -Message 'The exact-fit verified release must remain within the reader limit.'
			$Records = @([IO.File]::ReadAllLines($LeasePath) | ForEach-Object { $_ | ConvertFrom-Json })
			Assert-True -Condition ($Records.Count -eq 4 -and $Records[2].leaseId -ceq $Lease.leaseId -and $Records[3].leaseId -ceq $Lease.leaseId -and
				$Records[3].attemptId -ceq $Attempt.attemptId -and $Records[3].cleanupVerified -is [bool] -and $Records[3].cleanupVerified) -Message 'Release must retain the actual lease GUID, attempt identity and literal cleanup proof.'
		}
	}
	$OversizedPath = Initialize-LeaseFixture -Name 'already-oversized'
	[IO.File]::WriteAllText($OversizedPath, (' ' * (65537 - $PriorBytes)) + $PriorJournal, (New-Object Text.UTF8Encoding($false)))
	$OversizedHash = (Get-FileHash -LiteralPath $OversizedPath -Algorithm SHA256).Hash
	$OversizedAttempt = Get-TestAttempt -Id 'journal-already-oversized'
	Assert-Rejected -Action { Enter-InitialPreparationLease -Attempt $OversizedAttempt -LeasePath $OversizedPath } -Reason 'lease_journal_limit' -Message 'The original read bound must still reject oversized journals.'
	Assert-True -Condition ((Get-FileHash -LiteralPath $OversizedPath -Algorithm SHA256).Hash -ceq $OversizedHash) -Message 'An oversized journal must remain immutable on refusal.'
}

function Test-ResourceWatcherContract {
	$Attempt = Get-TestAttempt -Id 'watcher-attempt'
	$SampleRoot = Join-Path $FixtureRoot 'watcher-root'
	New-Item -ItemType Directory -Path $SampleRoot -Force | Out-Null
	$Samples = New-Object Collections.ArrayList
	$Producer = [pscustomobject]@{ stopRequested = $false }
	$Producer | Add-Member ScriptMethod RequestStop { $this.stopRequested = $true }
	$Sink = { param($Sample) [void] $Samples.Add($Sample) }

	# Production exposes this test adapter only when explicitly supplied by the
	# fixture. Runtime code must use genuine measurements and five-second delay.
	$script:InitialPreparationCoreTestAdapter = [pscustomobject]@{
		capacities = New-Object Collections.Queue
		delay = { param([int] $Seconds) Assert-True -Condition ($Seconds -eq 5) -Message 'Watcher cadence must be exactly five seconds.' }
	}
	foreach ($Reading in @(
		(Get-CapacityRecord -Ram 1.9 -Commit 16),
		(Get-CapacityRecord -Ram 1.8 -Commit 16),
		(Get-CapacityRecord -Ram 1.7 -Commit 16)
	)) { $script:InitialPreparationCoreTestAdapter.capacities.Enqueue($Reading) }
	$Result = Watch-InitialPreparationResource -Attempt $Attempt -OwnedProducer $Producer -Roots ([ordered]@{ evidence = $SampleRoot }) -OnSample $Sink
	Assert-True -Condition ($Result.code -ceq 'resource_pressure' -and $Producer.stopRequested) -Message 'Three consecutive sub-2-GiB readings must stop the owned producer as resource_pressure.'
	Assert-True -Condition ($Samples.Count -eq 3) -Message 'All pressure samples must be retained.'

	$Samples.Clear()
	$Producer.stopRequested = $false
	$script:InitialPreparationCoreTestAdapter.capacities = New-Object Collections.Queue
	foreach ($Reading in @(
		(Get-CapacityRecord -Ram 1.9 -Commit 16),
		(Get-CapacityRecord -Ram 3.0 -Commit 16),
		(Get-CapacityRecord -Ram 1.8 -Commit 16),
		(Get-CapacityRecord -Ram 1.7 -Commit 16),
		(Get-CapacityRecord -Ram 3.0 -Commit 16)
	)) { $script:InitialPreparationCoreTestAdapter.capacities.Enqueue($Reading) }
	$Result = Watch-InitialPreparationResource -Attempt $Attempt -OwnedProducer $Producer -Roots ([ordered]@{ evidence = $SampleRoot }) -OnSample $Sink
	Assert-True -Condition ($Result.code -ceq 'resources_stable' -and -not $Producer.stopRequested) -Message 'A recovered reading must reset the consecutive pressure counter.'

	$Producer.stopRequested = $false
	$Disk = Get-CapacityRecord -Ram 16 -Commit 16
	$Disk.volumes = @([pscustomobject]@{
		volumeId = 'fixture-volume'
		availableBytes = 21474836480L
		knownAllocationBytes = 0L
		recoveryFloorBytes = 21474836480L
	})
	$script:InitialPreparationCoreTestAdapter.capacities = New-Object Collections.Queue
	$script:InitialPreparationCoreTestAdapter.capacities.Enqueue($Disk)
	$Result = Watch-InitialPreparationResource -Attempt $Attempt -OwnedProducer $Producer -Roots ([ordered]@{ evidence = $SampleRoot }) -OnSample $Sink
	Assert-True -Condition ($Result.code -ceq 'disk_recovery_floor_reached' -and $Producer.stopRequested) -Message 'Contact with the disk recovery floor must stop owned producers immediately.'
	foreach ($InvalidReading in @(
		[pscustomobject]@{ volumes = @(); commitHeadroomGiB = 16 },
		(Get-CapacityRecord -Ram ([double]::NaN) -Commit 16),
		(Get-CapacityRecord -Ram 16 -Commit ([double]::PositiveInfinity))
	)) {
		$Producer.stopRequested = $false
		$script:InitialPreparationCoreTestAdapter.capacities = New-Object Collections.Queue
		$script:InitialPreparationCoreTestAdapter.capacities.Enqueue($InvalidReading)
		$Result = Watch-InitialPreparationResource -Attempt $Attempt -OwnedProducer $Producer -Roots ([ordered]@{ evidence = $SampleRoot }) -OnSample $Sink
		Assert-True -Condition ($Result.code -ceq 'resource_measurement_unavailable' -and $Producer.stopRequested) -Message 'Missing or non-finite readings must stop owned work.'
	}
	$Producer.stopRequested = $false
	$script:InitialPreparationCoreTestAdapter.capacities = New-Object Collections.Queue
	foreach ($ReadingNumber in 1..3) {
		$script:InitialPreparationCoreTestAdapter.capacities.Enqueue((Get-CapacityRecord -Ram 16 -Commit 1.9))
	}
	$Result = Watch-InitialPreparationResource -Attempt $Attempt -OwnedProducer $Producer -Roots ([ordered]@{ evidence = $SampleRoot }) -OnSample $Sink
	Assert-True -Condition ($Result.code -ceq 'resource_pressure' -and $Result.sampleCount -eq 3 -and $Producer.stopRequested) -Message 'Sustained commit pressure must stop work even when physical RAM is sufficient.'
	$Producer.stopRequested = $false
	$AllocatedDisk = Get-CapacityRecord -Ram 16 -Commit 16
	$AllocatedDisk.volumes = @(
		[pscustomobject]@{ volumeId = 'volume-a'; availableBytes = 100GB; knownAllocationBytes = 0L; recoveryFloorBytes = 20GB },
		[pscustomobject]@{ volumeId = 'volume-b'; availableBytes = 21GB; knownAllocationBytes = 2GB; recoveryFloorBytes = 20GB }
	)
	$script:InitialPreparationCoreTestAdapter.capacities = New-Object Collections.Queue
	$script:InitialPreparationCoreTestAdapter.capacities.Enqueue($AllocatedDisk)
	$Result = Watch-InitialPreparationResource -Attempt $Attempt -OwnedProducer $Producer -Roots ([ordered]@{ evidence = $SampleRoot }) -OnSample $Sink
	Assert-True -Condition ($Result.code -ceq 'disk_recovery_floor_reached' -and $Producer.stopRequested) -Message 'Known allocations on any touched volume must preserve its recovery floor.'
	$Producer.stopRequested = $false
	$Result = Watch-InitialPreparationResource -Attempt $Attempt -OwnedProducer $Producer -Roots ([ordered]@{ evidence = $SampleRoot }) -OnSample $Sink -CompletionProbe { param($Owned) $null = $Owned; return $true }
	Assert-True -Condition ($Result.code -ceq 'producer_completed' -and -not $Producer.stopRequested) -Message 'A completed producer must release the monitoring loop without waiting for the attempt deadline.'
	$Result = Watch-InitialPreparationResource -Attempt $Attempt -OwnedProducer $Producer -Roots ([ordered]@{ evidence = $SampleRoot }) -OnSample $Sink -ReadTicks { return $Attempt.stopUsefulWorkTicks }
	Assert-True -Condition ($Result.code -ceq 'useful_work_deadline' -and $Producer.stopRequested) -Message 'Owned work must stop at minute 330, not at the cleanup deadline.'

	Remove-Variable InitialPreparationCoreTestAdapter -Scope Script -ErrorAction SilentlyContinue
}

function Test-CleanupContract {
	$Attempt = Get-TestAttempt -Id 'cleanup-attempt'
	$LeasePath = Initialize-LeaseFixture -Name 'cleanup'
	$Lease = Enter-InitialPreparationLease -Attempt $Attempt -LeasePath $LeasePath
	$Receipt = Stop-InitialPreparationOwnedTree -Lease $Lease -DeadlineTicks $Attempt.cleanupDeadlineTicks
	Assert-ClosedProperty -Value $Receipt -Names @('stopRequestedTicks', 'quiescentTicks', 'cleanupVerified', 'remainingOwnedProcesses') -Message 'Cleanup receipt'
	Assert-True -Condition ($Receipt.cleanupVerified -and @($Receipt.remainingOwnedProcesses).Count -eq 0) -Message 'Terminal cleanup success requires proven owned-process quiescence.'
	Assert-True -Condition ([long] $Receipt.quiescentTicks -le [long] $Attempt.cleanupDeadlineTicks) -Message 'Cleanup proof must complete by the immutable cleanup deadline.'
	Assert-Rejected -Action { Stop-InitialPreparationOwnedTree -Lease $Lease -DeadlineTicks ([long] $Attempt.monotonicStartTicks - 1L) } -Reason 'cleanup_deadline_exceeded' -Message 'An expired cleanup deadline must fail closed.'
	$OwnedChild = $null
	$UnrelatedChild = $null
	try {
		$OwnedChild = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -WindowStyle Hidden -PassThru
		$UnrelatedChild = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -WindowStyle Hidden -PassThru
		$Lease | Add-Member -NotePropertyName ownedProcesses -NotePropertyValue @(
			[pscustomobject]@{ processId = $OwnedChild.Id; startTimeUtc = $OwnedChild.StartTime.ToUniversalTime().ToString('o'); role = 'fixture-child' }
		)
		$ShortDeadline = [Diagnostics.Stopwatch]::GetTimestamp() + 5L * [Diagnostics.Stopwatch]::Frequency
		$Stopped = Stop-InitialPreparationOwnedTree -Lease $Lease -DeadlineTicks $ShortDeadline
		Assert-True -Condition ($Stopped.cleanupVerified -and $OwnedChild.WaitForExit(1000)) -Message 'Cleanup must actually stop and observe the registered live child.'
		$UnrelatedChild.Refresh()
		Assert-True -Condition (-not $UnrelatedChild.HasExited) -Message 'Cleanup must preserve unrelated processes running the same executable.'
	} finally {
		foreach ($FixtureChild in @($OwnedChild, $UnrelatedChild)) {
			if ($null -ne $FixtureChild) {
				if (-not $FixtureChild.HasExited) { $FixtureChild.Kill(); [void] $FixtureChild.WaitForExit(2000) }
				$FixtureChild.Dispose()
			}
		}
	}
}

function Test-ReceiptContract {
	$Attempt = Get-TestAttempt -Id 'receipt-attempt'
	$ReceiptRoot = Join-Path $FixtureRoot 'receipts'
	New-Item -ItemType Directory -Path $ReceiptRoot -Force | Out-Null
	$Path = Join-Path $ReceiptRoot 'preparation-receipt.json'
	$Builds = @()
	foreach ($Ordinal in 1..6) {
		$Builds += [pscustomobject]@{
			ordinal = $Ordinal
			pair = [int] [Math]::Ceiling($Ordinal / 2.0)
			target = $(if (($Ordinal % 2) -eq 1) { 'AethelnOnlineClient' } else { 'AethelnOnlineServer' })
			platform = $(if (($Ordinal % 2) -eq 1) { 'Win64' } else { 'Linux' })
			configuration = 'Development'
			nativeExitCode = 0
			targetRevision = $Attempt.targetRevision
			inputDigest = ('d' * 64)
			cleanupVerified = $true
			ubtReadiness = [pscustomobject]@{ schemaVersion = 1; attemptId = $Attempt.attemptId; targetRevision = $Attempt.targetRevision; scope = 'ubt_dependency_rebuild_branch'; ready = $true; cleanupVerified = $true; scanExitCode = 0; comparisonExitCode = 0; failureCode = $null; dependencySha256 = ('a' * 64); scanSha256 = ('b' * 64) }
		}
	}
	$State = [pscustomobject]@{
		attempt = $Attempt
		outcome = 'warm_baseline_verified'
		builds = $Builds
		cleanup = [pscustomobject]@{ cleanupVerified = $true; remainingOwnedProcesses = @() }
		resource = [pscustomobject]@{ actionLimit = 4; ubaMode = 'local-only' }
		maintenance = [pscustomobject]@{ cycleCompleted = $true; admitted = $true; leaseReleased = $true; routingRestored = $true; errors = @() }
		nativeExitCode = 0
		infrastructureFailure = $null
		requestSha256 = ('a' * 64)
		controllerManifestSha256 = ('b' * 64)
	}
	$State | Add-Member -NotePropertyName inputDigest -NotePropertyValue ('d' * 64)
	foreach ($ReadinessMutation in @(
		@{ field = 'attemptId'; value = 'previous' },
		@{ field = 'targetRevision'; value = ('f' * 40) },
		@{ field = 'failureCode'; value = 'contradictory_failure' },
		@{ field = 'schemaVersion'; value = @(1) },
		@{ field = 'dependencySha256'; value = 'invalid' }
	)) {
		$OtherBuilds = @($Builds | ForEach-Object { $_.PSObject.Copy() })
		$OtherBuilds[0].ubtReadiness = $Builds[0].ubtReadiness.PSObject.Copy()
		$OtherBuilds[0].ubtReadiness.($ReadinessMutation.field) = $ReadinessMutation.value
		Assert-True -Condition (-not (Test-InitialPreparationBuildSequence -Builds $OtherBuilds -Attempt $Attempt -InputDigest ('d' * 64))) -Message ('Invalid readiness identity accepted: ' + $ReadinessMutation.field)
	}
	$Artifacts = @([pscustomobject]@{ name = 'phase-events'; sha256 = ('c' * 64); bytes = 128 })
	$Unrestored = $State.PSObject.Copy()
	$Unrestored.maintenance = $State.maintenance.PSObject.Copy()
	$Unrestored.maintenance.routingRestored = $false
	Assert-Rejected -Action { Write-InitialPreparationReceipt -State $Unrestored -Artifacts $Artifacts -Path (Join-Path $ReceiptRoot 'unrestored.json') } -Reason 'receipt_invalid' -Message 'Build success without routing restoration must not certify a baseline.'
	foreach ($TerminalMutation in @(
		@{ field = 'nativeExitCode'; value = 7 },
		@{ field = 'nativeExitCode'; value = '0' },
		@{ field = 'infrastructureFailure'; value = 'interrupted' },
		@{ field = 'requestSha256'; value = @('a' * 64) },
		@{ field = 'controllerManifestSha256'; value = 'invalid' },
		@{ field = 'maintenance'; value = $null }
	)) {
		$InvalidTerminal = $State.PSObject.Copy()
		$InvalidTerminal.($TerminalMutation.field) = $TerminalMutation.value
		Assert-Rejected -Action { Write-InitialPreparationReceipt -State $InvalidTerminal -Artifacts $Artifacts -Path (Join-Path $ReceiptRoot ('terminal-' + $TerminalMutation.field + '.json')) } -Reason 'receipt_invalid' -Message 'Terminal infrastructure and source bindings must be typed and successful.'
	}
	$Written = Write-InitialPreparationReceipt -State $State -Artifacts $Artifacts -Path $Path
	Assert-True -Condition (Test-Path -LiteralPath $Path -PathType Leaf) -Message 'Receipt must be persisted to the fresh destination.'
	Assert-True -Condition ($Written.sha256 -cmatch '^[0-9a-f]{64}$' -and [long] $Written.bytes -gt 0) -Message 'Receipt result must report reread lowercase SHA-256 and byte length.'
	Assert-Rejected -Action { Write-InitialPreparationReceipt -State $State -Artifacts $Artifacts -Path $Path } -Reason 'receipt_exists' -Message 'Receipt publication must be create-only.'
	foreach ($Mutation in @(
		@{ field = 'ordinal'; value = 1 },
		@{ field = 'pair'; value = 1 },
		@{ field = 'target'; value = 'AethelnOnlineClient' },
		@{ field = 'platform'; value = 'Win64' },
		@{ field = 'configuration'; value = 'Shipping' },
		@{ field = 'targetRevision'; value = ('e' * 40) },
		@{ field = 'inputDigest'; value = ('e' * 64) },
		@{ field = 'nativeExitCode'; value = '0' },
		@{ field = 'cleanupVerified'; value = $false },
		@{ field = 'targetRevision'; value = @($Attempt.targetRevision) },
		@{ field = 'inputDigest'; value = @('d' * 64) },
		@{ field = 'ubtReadiness'; value = $null },
		@{ field = 'ubtReadiness'; value = [pscustomobject]@{ scope = 'ubt_dependency_rebuild_branch'; ready = $true; cleanupVerified = $false; scanExitCode = 0; comparisonExitCode = 0 } },
		@{ field = 'ubtReadiness'; value = [pscustomobject]@{ scope = 'ubt_dependency_rebuild_branch'; ready = $true; cleanupVerified = $true; scanExitCode = '0'; comparisonExitCode = 0 } },
		@{ field = 'ubtReadiness'; value = [pscustomobject]@{ scope = @('ubt_dependency_rebuild_branch'); ready = $true; cleanupVerified = $true; scanExitCode = 0; comparisonExitCode = 0 } }
	)) {
		$MalformedState = $State.PSObject.Copy()
		$MalformedState.builds = @($Builds | ForEach-Object { $_.PSObject.Copy() })
		$MalformedState.builds[5].($Mutation.field) = $Mutation.value
		Assert-Rejected -Action {
			Write-InitialPreparationReceipt -State $MalformedState -Artifacts $Artifacts -Path (Join-Path $ReceiptRoot ('invalid-' + $Mutation.field + '.json'))
		} -Reason 'receipt_invalid' -Message ('Six successful records with malformed ' + $Mutation.field + ' must not certify a warm baseline.')
	}
	$StringCleanup = $State.PSObject.Copy()
	$StringCleanup.cleanup = [pscustomobject]@{ cleanupVerified = 'false'; remainingOwnedProcesses = @() }
	Assert-Rejected -Action {
		Write-InitialPreparationReceipt -State $StringCleanup -Artifacts $Artifacts -Path (Join-Path $ReceiptRoot 'string-cleanup.json')
	} -Reason 'receipt_invalid' -Message 'A string must not coerce to successful cleanup.'
	$Partial = $State.PSObject.Copy()
	$Partial.outcome = 'targets_built'
	$Partial.builds = @($Builds | Select-Object -First 2)
	$null = Write-InitialPreparationReceipt -State $Partial -Artifacts $Artifacts -Path (Join-Path $ReceiptRoot 'valid-pair.json')
	$Partial.builds[0] = $Partial.builds[0].PSObject.Copy()
	$Partial.builds[0].targetRevision = 'wrong'
	Assert-Rejected -Action { Write-InitialPreparationReceipt -State $Partial -Artifacts $Artifacts -Path (Join-Path $ReceiptRoot 'invalid-pair.json') } -Reason 'receipt_invalid' -Message 'Partial target results must bind the actual revision too.'

	$InvalidWarm = [pscustomobject]@{
		attempt = $Attempt
		outcome = 'warm_baseline_verified'
		builds = @($Builds | Select-Object -First 4)
		cleanup = [pscustomobject]@{ cleanupVerified = $true; remainingOwnedProcesses = @() }
		resource = [pscustomobject]@{ actionLimit = 4; ubaMode = 'local-only' }
	}
	Assert-Rejected -Action {
		Write-InitialPreparationReceipt -State $InvalidWarm -Artifacts $Artifacts -Path (Join-Path $ReceiptRoot 'invalid-four-build-receipt.json')
	} -Reason 'receipt_invalid' -Message 'Warm baseline verification requires exactly three complete unchanged client/server pairs (six invocations).'

	$FailedNative = $Builds | ForEach-Object { $_.PSObject.Copy() }
	$FailedNative[5].nativeExitCode = 9
	$InvalidNative = [pscustomobject]@{
		attempt = $Attempt
		outcome = 'warm_baseline_verified'
		builds = $FailedNative
		cleanup = [pscustomobject]@{ cleanupVerified = $true; remainingOwnedProcesses = @() }
		resource = [pscustomobject]@{ actionLimit = 4; ubaMode = 'local-only' }
	}
	Assert-Rejected -Action {
		Write-InitialPreparationReceipt -State $InvalidNative -Artifacts $Artifacts -Path (Join-Path $ReceiptRoot 'invalid-native-receipt.json')
	} -Reason 'receipt_invalid' -Message 'A native failure cannot be overridden by a successful summary outcome.'

	$InvalidCleanup = [pscustomobject]@{
		attempt = $Attempt
		outcome = 'warm_baseline_verified'
		builds = $Builds
		cleanup = [pscustomobject]@{ cleanupVerified = $false; remainingOwnedProcesses = @('owned-child') }
		resource = [pscustomobject]@{ actionLimit = 4; ubaMode = 'local-only' }
	}
	Assert-Rejected -Action {
		Write-InitialPreparationReceipt -State $InvalidCleanup -Artifacts $Artifacts -Path (Join-Path $ReceiptRoot 'invalid-cleanup-receipt.json')
	} -Reason 'receipt_invalid' -Message 'Unproven cleanup cannot produce terminal success.'

	$RuntimeNotReady = [pscustomobject]@{
		attempt = $Attempt
		outcome = 'runtime_not_ready'
		builds = @()
		cleanup = [pscustomobject]@{ cleanupVerified = $false; remainingOwnedProcesses = @() }
		resource = [pscustomobject]@{ actionLimit = $null; ubaMode = $null }
		missingProductionAdapters = @('owned-process-supervision')
	}
	$NotReadyPath = Join-Path $ReceiptRoot 'runtime-not-ready.json'
	$NotReadyResult = Write-InitialPreparationReceipt -State $RuntimeNotReady -Artifacts @() -Path $NotReadyPath
	Assert-True -Condition ($NotReadyResult.bytes -gt 0) -Message 'Missing genuine production adapters must be recordable as runtime_not_ready, never as experiment acceptance.'
}

function Test-LeaseSupervisionIntegration {
	$Attempt = Get-TestAttempt -Id 'lease-supervision-integration'
	$Lease = Enter-InitialPreparationLease -Attempt $Attempt -LeasePath (Initialize-LeaseFixture -Name 'supervised-lease')
	$Executable = (Get-Command powershell.exe -CommandType Application).Source
	$Producer = Start-InitialPreparationProcess -Attempt $Attempt -Lease $Lease -Executable $Executable -Arguments @('-NoProfile', '-Command', 'Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -Command Start-Sleep -Seconds 30" -WindowStyle Hidden; exit 0') -WorkingDirectory $FixtureRoot
	try {
		Assert-True -Condition ($Producer.process.WaitForExit(10000)) -Message 'Supervised lease fixture root must finish.'
		Assert-True -Condition ($Producer.supervision.ActiveCount -gt 0) -Message 'Lease must retain supervision of a surviving descendant.'
		Assert-Rejected -Action { Exit-InitialPreparationLease -Lease $Lease } -Reason 'cleanup_unproven' -Message 'A root exit is insufficient for lease release.'
		$Cleanup = Stop-InitialPreparationOwnedTree -Lease $Lease -DeadlineTicks $Attempt.cleanupDeadlineTicks
		Assert-True -Condition ($Cleanup.cleanupVerified -and $Producer.supervision.ActiveCount -eq 0) -Message 'Lease cleanup must actually stop and observe its supervised jobs.'
		Exit-InitialPreparationLease -Lease $Lease
	} finally { $Producer.supervision.Dispose(); $Producer.process.Dispose() }
}

function Test-RequestContract {
	$Attempt = Get-TestAttempt -Id 'request-contract'
	$Request = [ordered]@{ schemaVersion = 2; repository = 'owner/repository'; targetRevision = ('b' * 40);
		engineRevision = '71fe36aac5a8df5ccd66c763ffc902b29b6a9c43'; runnerId = 21; runnerName = 'aetheln-engine-pc';
		engineRoot = 'D:\engine'; targetRoot = 'D:\target'; leasePath = 'D:\control\host.lease'; yamlAssemblyPath = 'D:\control\YamlDotNet.dll'; linuxToolchainRoot = 'D:\toolchain';
		sourceRoot = 'D:\source'; lfsStorageRoot = 'D:\lfs-cache'; mode = 'inspect'; authorizationReference = $null }
	$Request['compilerPath'] = 'D:\tools\cl.exe'; $Request['resourceCompilerPath'] = 'D:\tools\rc.exe'
	$Json = $Request | ConvertTo-Json -Compress
	$Parsed = ConvertFrom-InitialPreparationRequest -Json $Json -Attempt $Attempt
	Assert-True -Condition ($Parsed.runnerId -eq 21 -and $Parsed.mode -ceq 'inspect') -Message 'Validated request must preserve exact operation inputs.'
	foreach ($IdentityField in @('repository', 'targetRevision', 'engineRevision')) {
		$Malformed = $Json | ConvertFrom-Json
		$Malformed.$IdentityField = @($Malformed.$IdentityField)
		$MalformedJson = $Malformed | ConvertTo-Json -Compress
		Assert-Rejected -Action { ConvertFrom-InitialPreparationRequest -Json $MalformedJson -Attempt $Attempt } -Reason 'preparation_request_invalid' -Message 'Identity fields must reject arrays even when all elements equal the expected scalar.'
		$Malformed.$IdentityField = @()
		$MalformedJson = $Malformed | ConvertTo-Json -Compress
		Assert-Rejected -Action { ConvertFrom-InitialPreparationRequest -Json $MalformedJson -Attempt $Attempt } -Reason 'preparation_request_invalid' -Message 'Empty identity arrays must not bypass exact identity validation.'
	}
	foreach ($PathField in @('engineRoot', 'targetRoot', 'leasePath', 'yamlAssemblyPath', 'linuxToolchainRoot', 'sourceRoot', 'lfsStorageRoot', 'compilerPath', 'resourceCompilerPath')) {
		foreach ($RelativePath in @('D:relative', '\relative', 'D:\root:stream', "D:\root`npath")) {
			$Malformed = $Json | ConvertFrom-Json
			$Malformed.$PathField = $RelativePath
			$MalformedJson = $Malformed | ConvertTo-Json -Compress
			Assert-Rejected -Action { ConvertFrom-InitialPreparationRequest -Json $MalformedJson -Attempt $Attempt } -Reason 'preparation_request_invalid' -Message 'Drive-relative and current-drive-rooted inputs must not bind operation paths.'
		}
	}
	$Legacy = $Json.Replace('"schemaVersion":2', '"schemaVersion":1')
	Assert-Rejected -Action { ConvertFrom-InitialPreparationRequest -Json $Legacy -Attempt $Attempt } -Reason 'preparation_request_invalid' -Message 'Older request versions cannot imply new source/cache bindings.'
	$Execute = $Json | ConvertFrom-Json
	$Execute.mode = 'execute'; $Execute.authorizationReference = 'fixture authorization only'
	$ExecuteJson = $Execute | ConvertTo-Json -Compress
	$ValidatedExecute = ConvertFrom-InitialPreparationRequest -Json $ExecuteJson -Attempt $Attempt
	Assert-True -Condition ($ValidatedExecute.sourceRoot -ceq 'D:\source' -and $ValidatedExecute.lfsStorageRoot -ceq 'D:\lfs-cache') -Message 'Execute must retain separate source and configured cache paths.'
	foreach ($BadJson in @($Json.Replace('"runnerId":21', '"runnerId":21,"runnerId":22'), $Json.Replace('"runnerId":21', '"runnerId":"21"'), $Json.Replace('"mode":"inspect"', '"mode":"unknown"'), $Json.Replace(('b' * 40), ('c' * 40)), $Json.Replace('"mode":"inspect"', '"mode":"execute"'))) {
		Assert-Rejected -Action { ConvertFrom-InitialPreparationRequest -Json $BadJson -Attempt $Attempt } -Reason 'preparation_request_invalid' -Message 'Ambiguous, mistyped, mismatched or unauthorized requests must be rejected.'
	}
}

function Test-DirectoryPinContract {
	$PinRoot = Join-Path $FixtureRoot 'pin-parent'
	$PinChild = Join-Path $PinRoot 'child'
	$Destination = Join-Path $FixtureRoot 'pin-parent-renamed'
	Assert-True -Condition ((Test-InitialPreparationWithin -Candidate $PinRoot -Parent $FixtureRoot) -and (Test-InitialPreparationWithin -Candidate $Destination -Parent $FixtureRoot)) -Message 'Pin rename fixture must remain inside its own temporary root.'
	$null = New-Item -ItemType Directory -Path $PinChild -Force
	$Pins = Get-InitialPreparationDirectoryPin -Directory $PinChild
	try {
		$Denied = $false
		try { [IO.Directory]::Move($PinRoot, $Destination) } catch [IO.IOException] { $Denied = $true }
		Assert-True -Condition ($Denied -and (Test-Path -LiteralPath $PinChild)) -Message 'Retained ancestors must deny path rebinding during verified execution.'
	} finally { foreach ($Handle in $Pins) { $Handle.Dispose() } }
}

function Test-LocalWorkerContract {
	$ObservedAt = [DateTime]::UtcNow
	$ProcessRows = @(
		[pscustomobject]@{ ProcessId = 10; ParentProcessId = 1; Name = 'Runner.Listener.exe'; ExecutablePath = 'C:\runner\bin\Runner.Listener.exe'; CreationDate = $ObservedAt.AddSeconds(-20) },
		[pscustomobject]@{ ProcessId = 20; ParentProcessId = 1; Name = 'notepad.exe'; ExecutablePath = 'C:\Windows\notepad.exe'; CreationDate = $ObservedAt.AddSeconds(-10) }
	)
	$Probe = { $ProcessRows }.GetNewClosure()
	$Observation = Get-InitialPreparationLocalWork -EngineRoot $FixtureRoot -ProcessProbe $Probe
	Assert-True -Condition ($Observation.complete -and $Observation.activeProcessCount -eq 0) -Message 'The listener and unrelated applications are not active engine work.'
	$ProcessRows += [pscustomobject]@{ ProcessId = 30; ParentProcessId = 10; Name = 'Runner.Worker.exe'; ExecutablePath = 'C:\runner\bin\Runner.Worker.exe'; CreationDate = $ObservedAt.AddSeconds(-5) }
	$ProcessRows += [pscustomobject]@{ ProcessId = 40; ParentProcessId = 30; Name = 'powershell.exe'; ExecutablePath = 'C:\Windows\powershell.exe'; CreationDate = $ObservedAt }
	$Probe = { $ProcessRows }.GetNewClosure()
	$Observation = Get-InitialPreparationLocalWork -EngineRoot $FixtureRoot -ProcessProbe $Probe
	Assert-True -Condition ($Observation.activeProcessCount -eq 2) -Message 'Runner worker descendants must be observed without inspecting command lines.'
	$ProcessRows[3].CreationDate = $ObservedAt.AddSeconds(-15)
	$Probe = { $ProcessRows }.GetNewClosure()
	Assert-Rejected -Action { Get-InitialPreparationLocalWork -EngineRoot $FixtureRoot -ProcessProbe $Probe } -Reason 'local_inventory_incomplete' -Message 'Reused parent PID cannot establish a trustworthy worker tree.'
	$ProcessRows = @([pscustomobject]@{ ProcessId = 50; ParentProcessId = 1; Name = 'dotnet.exe'; ExecutablePath = $null; CreationDate = $ObservedAt })
	$Probe = { $ProcessRows }.GetNewClosure()
	$Observation = Get-InitialPreparationLocalWork -EngineRoot $FixtureRoot -ProcessProbe $Probe
	Assert-True -Condition ($Observation.activeProcessCount -eq 1) -Message 'Unattributed build-capable processes conservatively prevent idle admission.'
	Assert-Rejected -Action { Get-InitialPreparationLocalWork -EngineRoot $FixtureRoot -ProcessProbe { throw 'CIM unavailable' } } -Reason 'local_inventory_incomplete' -Message 'Failed local observation must not become idle.'
}

function Test-SupervisionContract {
	$Attempt = Get-TestAttempt -Id 'supervision-attempt'
	foreach ($Boundary in @('useful', 'cleanup', 'publication')) {
		$BoundJob = New-InitialPreparationSupervision -Attempt $Attempt -Boundary $Boundary
		try {
			$Field = @{ useful = 'stopUsefulWorkTicks'; cleanup = 'cleanupDeadlineTicks'; publication = 'publicationDeadlineTicks' }[$Boundary]
			Assert-True -Condition ($BoundJob.DeadlineTicks -eq $Attempt.$Field) -Message 'Supervisor deadline must inherit the original attempt boundary exactly.'
		} finally { $BoundJob.Dispose() }
	}
	Initialize-InitialPreparationJob
	# Model in-flight lifecycle state; this is not a native CreateProcess stall.
	$InFlightJob = [Aetheln.PreparationJob]::new([Diagnostics.Stopwatch]::GetTimestamp() + 15L * [Diagnostics.Stopwatch]::Frequency)
	$Flags = [Reflection.BindingFlags] 'Instance,NonPublic'
	$Type = $InFlightJob.GetType()
	$StartingField = $Type.GetField('starting', $Flags)
	$DisposedField = $Type.GetField('disposed', $Flags)
	$Gate = $Type.GetField('gate', $Flags).GetValue($InFlightJob)
	try {
		[Threading.Monitor]::Enter($Gate)
		try { $StartingField.SetValue($InFlightJob, $true) } finally { [Threading.Monitor]::Exit($Gate) }
		$Rejected = $false
		try { $InFlightJob.StopAndWait(100) } catch { $Rejected = $_.Exception.InnerException -is [TimeoutException] }
		Assert-True -Condition $Rejected -Message 'Zero active processes cannot prove cleanup while startup remains in flight.'
		$InFlightJob.Dispose()
		Start-Sleep -Milliseconds 50
		Assert-True -Condition ($Type.GetField('watchdog', $Flags).GetValue($InFlightJob).IsAlive) -Message 'Disposal must keep the watchdog alive until in-flight startup finishes.'
		Assert-True -Condition ($Type.GetField('handle', $Flags).GetValue($InFlightJob) -ne [IntPtr]::Zero) -Message 'Disposal must retain the handle supplied to in-flight creation.'
	} finally {
		# Complete the synthetic transition under the same lock and dispose normally.
		[Threading.Monitor]::Enter($Gate)
		try { $StartingField.SetValue($InFlightJob, $false); $DisposedField.SetValue($InFlightJob, $false) } finally { [Threading.Monitor]::Exit($Gate) }
		$InFlightJob.Dispose()
	}
	$Executable = (Get-Command powershell.exe -CommandType Application).Source
	$Deadline = [Diagnostics.Stopwatch]::GetTimestamp() + 15L * [Diagnostics.Stopwatch]::Frequency
	$Job = [Aetheln.PreparationJob]::new($Deadline)
	try {
		$Root = $Job.Start($Executable, @('-NoProfile', '-Command', 'exit 7'), $FixtureRoot)
		Assert-True -Condition ($Root.WaitForExit(10000)) -Message 'Supervised native fixture must terminate.'
		Assert-True -Condition ($Root.ExitCode -eq 7) -Message 'A nonzero native exit must survive supervision.'
		$Job.StopAndWait(3000)
		Assert-True -Condition ($Job.ActiveCount -eq 0 -and -not $Job.TimedOut) -Message 'Normal completion must prove job quiescence.'
	} finally { $Job.Dispose(); if ($null -ne $Root) { $Root.Dispose() } }
	$Deadline = [Diagnostics.Stopwatch]::GetTimestamp() + 2L * [Diagnostics.Stopwatch]::Frequency
	$Job = [Aetheln.PreparationJob]::new($Deadline)
	$Unrelated = Start-Process -FilePath $Executable -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -WindowStyle Hidden -PassThru
	try {
		$Root = $Job.Start($Executable, @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30'), $FixtureRoot)
		# No PowerShell polling loop drives the watchdog: wait directly on the root.
		Assert-True -Condition ($Root.WaitForExit(8000)) -Message 'The native watchdog must enforce the immutable deadline.'
		$Job.StopAndWait(3000)
		Assert-True -Condition ($Job.TimedOut -and $Job.ActiveCount -eq 0 -and -not $Unrelated.HasExited) -Message 'Deadline cleanup must contain owned processes only.'
	} finally {
		$Job.Dispose(); $Root.Dispose()
		if (-not $Unrelated.HasExited) { $Unrelated.Kill(); [void] $Unrelated.WaitForExit(3000) }
		$Unrelated.Dispose()
	}
	$Deadline = [Diagnostics.Stopwatch]::GetTimestamp() + 15L * [Diagnostics.Stopwatch]::Frequency
	$Job = [Aetheln.PreparationJob]::new($Deadline)
	try {
		$Command = 'Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -Command Start-Sleep -Seconds 30" -WindowStyle Hidden; exit 0'
		$Root = $Job.Start($Executable, @('-NoProfile', '-Command', $Command), $FixtureRoot)
		Assert-True -Condition ($Root.WaitForExit(10000)) -Message 'Fixture launcher must exit leaving an owned descendant.'
		Assert-True -Condition ($Job.ActiveCount -gt 0) -Message 'Root exit must not hide a living owned descendant.'
		$Job.StopAndWait(3000)
		Assert-True -Condition ($Job.ActiveCount -eq 0) -Message 'Cleanup must terminate descendants after root exit.'
	} finally { $Job.Dispose(); $Root.Dispose() }
	$SignalPath = Join-Path $FixtureRoot 'supervisor-child.identity'
	$ParentCommand = @'
. '__CORE__'
Initialize-InitialPreparationJob
$Job = [Aetheln.PreparationJob]::new([Diagnostics.Stopwatch]::GetTimestamp() + 20L * [Diagnostics.Stopwatch]::Frequency)
$Child = $Job.Start((Get-Command powershell.exe -CommandType Application).Source, @('-NoProfile','-Command','Start-Sleep -Seconds 30'), '__ROOT__')
$Stream = [IO.File]::Open('__SIGNAL__.pending', [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $Bytes = [Text.Encoding]::ASCII.GetBytes([string] $Child.Id + ',' + [string] $Child.StartTime.ToUniversalTime().Ticks)
    $Stream.Write($Bytes, 0, $Bytes.Length)
} finally { $Stream.Dispose() }
[IO.File]::Move('__SIGNAL__.pending', '__SIGNAL__')
Start-Sleep -Seconds 30
'@
	$ParentCommand = $ParentCommand.Replace('__CORE__', $Core.Replace("'", "''")).Replace('__ROOT__', $FixtureRoot.Replace("'", "''")).Replace('__SIGNAL__', $SignalPath.Replace("'", "''"))
	$OuterJob = [Aetheln.PreparationJob]::new([Diagnostics.Stopwatch]::GetTimestamp() + 25L * [Diagnostics.Stopwatch]::Frequency)
	$ChildProcess = $null
	$ParentProcess = $null
	try {
		$ParentProcess = $OuterJob.Start($Executable, @('-NoProfile', '-Command', $ParentCommand), $FixtureRoot)
		$Wait = [Diagnostics.Stopwatch]::StartNew()
		while (-not (Test-Path -LiteralPath $SignalPath) -and $Wait.ElapsedMilliseconds -lt 10000 -and -not $ParentProcess.HasExited) { Start-Sleep -Milliseconds 50 }
		Assert-True -Condition (Test-Path -LiteralPath $SignalPath) -Message 'Interrupted-owner fixture must publish its child identity.'
		Assert-True -Condition ((Get-Item -LiteralPath $SignalPath).Length -le 128) -Message 'Fixture identity read must be bounded.'
		$Parts = [IO.File]::ReadAllText($SignalPath).Split(',')
		$ChildProcess = [Diagnostics.Process]::GetProcessById([int] $Parts[0])
		$null = $ChildProcess.Handle
		Assert-True -Condition ($ChildProcess.StartTime.ToUniversalTime().Ticks -eq [long] $Parts[1]) -Message 'Child identity must bind PID and creation time.'
		$ParentProcess.Kill()
		Assert-True -Condition ($ParentProcess.WaitForExit(3000) -and $ChildProcess.WaitForExit(5000)) -Message 'Owner interruption must close the inner job and terminate its child, without outer-job cleanup.'
	} finally {
		$OuterJob.StopAndWait(3000); $OuterJob.Dispose()
		if ($null -ne $ParentProcess) { $ParentProcess.Dispose() }
		if ($null -ne $ChildProcess) { $ChildProcess.Dispose() }
	}
}

try {
	Assert-True -Condition (Test-Path -LiteralPath $Core -PathType Leaf) -Message 'Initial preparation core must exist before its negative-first fixtures can pass.'
	. $Core
	New-Item -ItemType Directory -Path $FixtureRoot -Force | Out-Null
	Test-FunctionSurface
	Test-AttemptContract
	Test-ActionLimitContract
	Test-LeaseAndOwnershipContract
	Test-CapacityContract
	Test-LeaseLifecycle
	Test-LeaseJournalCapacity
	Test-ResourceWatcherContract
	Test-CleanupContract
	Test-ReceiptContract
	Test-SupervisionContract
	Test-LeaseSupervisionIntegration
	Test-LocalWorkerContract
	Test-DirectoryPinContract
	Test-RequestContract
	$ReloadAttempt = Get-TestAttempt -Id 'reload-attempt'
	$ReloadLeasePath = Initialize-LeaseFixture -Name 'reload-held-lease'
	$ReloadLease = Enter-InitialPreparationLease -Attempt $ReloadAttempt -LeasePath $ReloadLeasePath
	$HeldEntry = @($script:InitialPreparationLeaseRegistry.Values | Where-Object { $_.leaseId -ceq $ReloadLease.leaseId })[0]
	. $Core
	Assert-Rejected -Action { Get-TestAttempt -Id $ReloadAttempt.attemptId } -Reason 'attempt_exists' -Message 'Dot-sourcing the controller must not reset an existing attempt deadline.'
	$ReloadedEntry = @($script:InitialPreparationLeaseRegistry.Values | Where-Object { $_.leaseId -ceq $ReloadLease.leaseId })[0]
	Assert-True -Condition ([object]::ReferenceEquals($HeldEntry.stream, $ReloadedEntry.stream) -and $HeldEntry.stream.CanWrite) -Message 'Reload must preserve the live exclusive lease handle.'
	Assert-Rejected -Action { Enter-InitialPreparationLease -Attempt $ReloadAttempt -LeasePath $ReloadLeasePath } -Reason 'lease_nested' -Message 'Reload must not permit nested lease acquisition.'
	Write-Output 'PASS: initial preparation core focused fixtures'
} catch {
	$RetainFixtureEvidence = $true
	Write-Output "Failed fixture evidence retained at: $FixtureRoot"
	throw
} finally {
	Remove-Variable InitialPreparationCoreTestAdapter -Scope Script -ErrorAction SilentlyContinue
	$LeaseRegistryVariable = Get-Variable -Name InitialPreparationLeaseRegistry -Scope Script -ErrorAction SilentlyContinue
	if ($null -ne $LeaseRegistryVariable) {
		foreach ($FixtureLease in $LeaseRegistryVariable.Value.Values) {
			if ($FixtureLease.PSObject.Properties.Name -contains 'stream') { $FixtureLease.stream.Dispose() }
		}
	}
	if (-not $RetainFixtureEvidence -and (Test-Path -LiteralPath $FixtureRoot)) {
		Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
	}
}
