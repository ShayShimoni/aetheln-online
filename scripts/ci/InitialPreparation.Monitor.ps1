# Runtime API observations occur in a contained worker, never on the resource
# sampling thread. Sixty seconds is a provisional protective freshness cutoff,
# not a measured availability guarantee or a success grace period.
function ConvertTo-InitialPreparationMonitorSnapshot {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Observation, [Parameter(Mandatory)] $Attempt,
		[Parameter(Mandatory)][ValidateRange(0, 4096)][int] $Sequence)
	if ($Observation.activeJobs -isnot [array]) { throw 'monitor_observation_invalid' }
	return [pscustomobject][ordered]@{ schemaVersion = 1; sequence = $Sequence; attemptId = $Attempt.attemptId;
		repository = $Attempt.repository; runnerId = $Observation.runnerId; runnerName = $Observation.runnerName;
		complete = $Observation.complete; routesSafe = $Observation.routesSafe; online = $Observation.online;
		busy = $Observation.busy; labels = $Observation.labels; activeJobCount = $Observation.activeJobs.Count;
		observedTicks = $Observation.observedTicks }
}

function Assert-InitialPreparationMonitorSnapshot {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Snapshot, [Parameter(Mandatory)] $Attempt,
		[Parameter(Mandatory)] $Runner, [Parameter(Mandatory)][int] $Sequence,
		[Parameter(Mandatory)][long] $NowTicks, [switch] $AllowExpired)
	try {
		$Fields = @('schemaVersion', 'sequence', 'attemptId', 'repository', 'runnerId', 'runnerName', 'complete', 'routesSafe', 'online', 'busy', 'labels', 'activeJobCount', 'observedTicks')
		$Names = @($Snapshot.PSObject.Properties.Name)
		if ($Names.Count -ne $Fields.Count) { throw 'invalid' }
		foreach ($Name in $Names) { if ($Fields -cnotcontains $Name) { throw 'invalid' } }
		foreach ($Name in @('schemaVersion', 'sequence', 'runnerId', 'activeJobCount', 'observedTicks')) {
			if ($Snapshot.$Name -isnot [int] -and $Snapshot.$Name -isnot [long]) { throw 'invalid' }
		}
		foreach ($Name in @('complete', 'routesSafe', 'online', 'busy')) { if ($Snapshot.$Name -isnot [bool]) { throw 'invalid' } }
		foreach ($Name in @('attemptId', 'repository', 'runnerName')) { if ($Snapshot.$Name -isnot [string]) { throw 'invalid' } }
		if ($Snapshot.schemaVersion -ne 1 -or $Snapshot.sequence -ne $Sequence -or $Sequence -lt 0 -or $Sequence -gt 4096 -or
			$Snapshot.attemptId -cne $Attempt.attemptId -or $Snapshot.repository -cne $Attempt.repository -or
			$Snapshot.runnerId -ne $Runner.id -or $Snapshot.runnerName -cne $Runner.name -or
			-not $Snapshot.complete -or -not $Snapshot.routesSafe -or -not $Snapshot.online -or $Snapshot.busy -or $Snapshot.activeJobCount -ne 0) { throw 'invalid' }
		if ($Snapshot.observedTicks -lt $Attempt.monotonicStartTicks -or $Snapshot.observedTicks -gt $NowTicks) { throw 'invalid' }
		if ($Snapshot.labels -isnot [array] -or $Snapshot.labels.Count -lt 1 -or $Snapshot.labels.Count -gt 100 -or
			$Runner.originalLabels -isnot [array] -or $Runner.originalLabels -cnotcontains 'aetheln-engine') { throw 'invalid' }
		$Expected = @($Runner.originalLabels | Where-Object { $_ -cne 'aetheln-engine' })
		$Unique = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
		foreach ($Label in $Snapshot.labels) {
			if ($Label -isnot [string] -or $Label.Length -lt 1 -or $Label.Length -gt 100 -or
				-not $Unique.Add($Label) -or $Expected -cnotcontains $Label) { throw 'invalid' }
		}
		if ($Snapshot.labels.Count -ne $Expected.Count) { throw 'invalid' }
	} catch { throw 'monitor_observation_invalid' }
	if (-not $AllowExpired -and ($NowTicks - $Snapshot.observedTicks) / [double] $Attempt.monotonicFrequency -ge 60.0) { throw 'monitor_observation_stale' }
}

function Get-InitialPreparationMonitorContext {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)] $Runner,
		[Parameter(Mandatory)] $SeedObservation, [Parameter(Mandatory)] $OwnedWorker,
		[Parameter(Mandatory)][string] $EvidenceRoot)
	Assert-InitialPreparationAttempt -Attempt $Attempt
	$Seed = ConvertTo-InitialPreparationMonitorSnapshot -Observation $SeedObservation -Attempt $Attempt -Sequence 0
	Assert-InitialPreparationMonitorSnapshot -Snapshot $Seed -Attempt $Attempt -Runner $Runner -Sequence 0 -NowTicks (Get-InitialPreparationTick)
	return [pscustomobject]@{ attempt = $Attempt; runner = $Runner; worker = $OwnedWorker; evidenceRoot = $EvidenceRoot;
		sequence = 0; lastObservation = $Seed; freshnessSeconds = 60 }
}

function Start-InitialPreparationMonitor {
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)] $Lease,
		[Parameter(Mandatory)] $Runner, [Parameter(Mandatory)] $SeedObservation,
		[Parameter(Mandatory)][string] $YamlAssemblyPath, [Parameter(Mandatory)][string] $EvidenceRoot)
	Assert-InitialPreparationAttempt -Attempt $Attempt
	$Seed = ConvertTo-InitialPreparationMonitorSnapshot -Observation $SeedObservation -Attempt $Attempt -Sequence 0
	Assert-InitialPreparationMonitorSnapshot -Snapshot $Seed -Attempt $Attempt -Runner $Runner -Sequence 0 -NowTicks (Get-InitialPreparationTick)
	Assert-InitialPreparationPlainPath -Path $EvidenceRoot -Reason 'monitor_path_invalid'
	if (-not (Test-Path -LiteralPath $EvidenceRoot -PathType Container)) { throw 'monitor_path_invalid' }
	if (-not $PSCmdlet.ShouldProcess($EvidenceRoot, 'Start contained runtime quarantine monitor')) { throw 'monitor_start_declined' }
	# The handoff contains only admission-validated immutable routes. A literal
	# digest crosses the process boundary; replacement cannot become new trust.
	Assert-InitialPreparationRuntimeProof -Proof $SeedObservation.runtimeProof -Runner $Runner
	$Envelope = [pscustomobject]@{ schemaVersion = 1; attemptId = $Attempt.attemptId;
		seedObservedTicks = $Seed.observedTicks; proof = $SeedObservation.runtimeProof }
	$ProofBytes = [Text.Encoding]::UTF8.GetBytes(($Envelope | ConvertTo-Json -Depth 14 -Compress))
	if ($ProofBytes.Length -gt 16842752) { throw 'runtime_proof_invalid' }
	$ProofPath = Join-Path $EvidenceRoot 'admission-proof.json'
	$ProofStream = [IO.File]::Open($ProofPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
	try { $ProofStream.Write($ProofBytes, 0, $ProofBytes.Length); $ProofStream.Flush($true) } finally { $ProofStream.Dispose() }
	$Hasher = [Security.Cryptography.SHA256]::Create()
	try { $ProofHash = ([BitConverter]::ToString($Hasher.ComputeHash($ProofBytes))).Replace('-', '').ToLowerInvariant() } finally { $Hasher.Dispose() }
	$Arguments = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'InitialPreparation.MonitorWorker.ps1'),
		'-AttemptJson', ($Attempt | ConvertTo-Json -Compress), '-RunnerJson', ($Runner | ConvertTo-Json -Depth 4 -Compress),
		'-YamlAssemblyPath', $YamlAssemblyPath, '-EvidenceRoot', $EvidenceRoot, '-ProofSha256', $ProofHash)
	$Owned = Start-InitialPreparationProcess -Attempt $Attempt -Lease $Lease -Executable (Join-Path $PSHOME 'powershell.exe') -Arguments $Arguments -WorkingDirectory $EvidenceRoot
	return Get-InitialPreparationMonitorContext -Attempt $Attempt -Runner $Runner -SeedObservation $SeedObservation -OwnedWorker $Owned -EvidenceRoot $EvidenceRoot
}

function Get-InitialPreparationMonitorProof {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $EvidenceRoot, [Parameter(Mandatory)] $Attempt,
		[Parameter(Mandatory)] $Runner, [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string] $ProofSha256)
	$Pins = @(); $Handle = $null; $Stream = $null
	try {
		$Pins = Get-InitialPreparationDirectoryPin -Directory $EvidenceRoot
		$Handle = [Aetheln.PreparationDirectory]::OpenSource((Join-Path $EvidenceRoot 'admission-proof.json'))
		$Stream = [IO.FileStream]::new($Handle, [IO.FileAccess]::Read)
		if ($Stream.Length -lt 1 -or $Stream.Length -gt 16842752) { throw 'invalid' }
		$Hasher = [Security.Cryptography.SHA256]::Create()
		try { $Digest = ([BitConverter]::ToString($Hasher.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant() } finally { $Hasher.Dispose() }
		if ($Digest -cne $ProofSha256) { throw 'invalid' }
		$Stream.Position = 0
		$Bytes = New-Object byte[] ([int] $Stream.Length)
		$Offset = 0
		while ($Offset -lt $Bytes.Length) {
			$Count = $Stream.Read($Bytes, $Offset, $Bytes.Length - $Offset)
			if ($Count -le 0) { throw 'invalid' }
			$Offset += $Count
		}
		$Utf8 = New-Object Text.UTF8Encoding($false, $true)
		$Envelope = $Utf8.GetString($Bytes) | ConvertFrom-Json
		if (@($Envelope.PSObject.Properties).Count -ne 4 -or $Envelope.schemaVersion -isnot [int] -or $Envelope.schemaVersion -ne 1 -or
			$Envelope.attemptId -isnot [string] -or $Envelope.attemptId -cne $Attempt.attemptId -or
			($Envelope.seedObservedTicks -isnot [int] -and $Envelope.seedObservedTicks -isnot [long]) -or
			$Envelope.seedObservedTicks -lt $Attempt.monotonicStartTicks -or $Envelope.seedObservedTicks -gt (Get-InitialPreparationTick) -or
			((Get-InitialPreparationTick) - $Envelope.seedObservedTicks) / [double] $Attempt.monotonicFrequency -ge 60) { throw 'invalid' }
		Assert-InitialPreparationRuntimeProof -Proof $Envelope.proof -Runner $Runner
		return [pscustomobject]@{ envelope = $Envelope; stream = $Stream; handle = $Handle; pins = $Pins }
	} catch {
		if ($null -ne $Stream) { $Stream.Dispose() }
		if ($null -ne $Handle) { $Handle.Dispose() }
		foreach ($Pin in $Pins) { $Pin.Dispose() }
		throw 'runtime_proof_invalid'
	}
}

function Get-InitialPreparationMonitorState {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Monitor)
	$Now = Get-InitialPreparationTick
	if ($Now -ge $Monitor.attempt.stopUsefulWorkTicks) { throw 'useful_work_deadline' }
	try { if ($Monitor.worker.process.HasExited) { throw 'monitor_worker_exited' } } catch { throw 'monitor_worker_exited' }
	# Validate identities and every intermediate state before catching up. Only
	# the newest consumed state may satisfy freshness; a bad intermediate fails.
	Assert-InitialPreparationMonitorSnapshot -Snapshot $Monitor.lastObservation -Attempt $Monitor.attempt -Runner $Monitor.runner -Sequence $Monitor.sequence -NowTicks $Now -AllowExpired
	if ($Monitor.sequence -ge 4096) { throw 'monitor_sequence_exhausted' }
	$Consumed = $false
	for ($Drain = 0; $Drain -lt 64; $Drain++) {
		$Next = $Monitor.sequence + 1
		$Path = Join-Path $Monitor.evidenceRoot ('snapshot-{0:D4}.json' -f $Next)
		$Stream = $null
		$SourceHandle = $null
		$Pins = @()
		$Pending = $false
		try {
			$Pins = Get-InitialPreparationDirectoryPin -Directory $Monitor.evidenceRoot
			try {
				$SourceHandle = [Aetheln.PreparationDirectory]::OpenSource($Path)
				$Stream = New-Object IO.FileStream($SourceHandle, [IO.FileAccess]::Read)
			} catch {
				# Only sharing/lock violations represent a writer still publishing.
				$Cause = $_.Exception.GetBaseException()
				if ($Cause -is [ComponentModel.Win32Exception] -and $Cause.NativeErrorCode -in @(2, 32, 33)) { $Pending = $true } else { throw 'monitor_snapshot_unreadable' }
			}
			if (-not $Pending) {
				if ($Stream.Length -lt 1 -or $Stream.Length -gt 4096) { throw 'monitor_snapshot_invalid' }
				$Bytes = New-Object byte[] ([int] $Stream.Length)
				$Offset = 0
				while ($Offset -lt $Bytes.Length) {
					$Count = $Stream.Read($Bytes, $Offset, $Bytes.Length - $Offset)
					if ($Count -le 0) { throw 'monitor_snapshot_invalid' }
					$Offset += $Count
				}
				try {
					$Utf8 = New-Object Text.UTF8Encoding($false, $true)
					$Json = $Utf8.GetString($Bytes)
					# Closed flat object with a string-array labels field. Every property
					# must occur once before conversion can collapse duplicate keys.
					$Keys = [regex]::Matches($Json, '"(?<key>(?:[^"\\]|\\.)*)"\s*:', [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromMilliseconds(50))
					$Unique = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
					if ($Keys.Count -ne 13) { throw 'invalid' }
					foreach ($Key in $Keys) { if (-not $Unique.Add($Key.Groups['key'].Value)) { throw 'invalid' } }
					$Snapshot = $Json | ConvertFrom-Json
				} catch { throw 'monitor_snapshot_invalid' }
				Assert-InitialPreparationMonitorSnapshot -Snapshot $Snapshot -Attempt $Monitor.attempt -Runner $Monitor.runner -Sequence $Next -NowTicks (Get-InitialPreparationTick) -AllowExpired
				if ($Snapshot.observedTicks -le $Monitor.lastObservation.observedTicks) { throw 'monitor_observation_invalid' }
				$Monitor.lastObservation = $Snapshot
				$Monitor.sequence = $Next
				$Consumed = $true
			}
		} finally {
			if ($null -ne $Stream) { $Stream.Dispose() }
			if ($null -ne $SourceHandle) { $SourceHandle.Dispose() }
			foreach ($Pin in $Pins) { $Pin.Dispose() }
		}
		if ($Pending -or $Monitor.sequence -ge 4096) { break }
	}
	if ($Monitor.worker.process.HasExited) { throw 'monitor_worker_exited' }
	Assert-InitialPreparationMonitorSnapshot -Snapshot $Monitor.lastObservation -Attempt $Monitor.attempt -Runner $Monitor.runner -Sequence $Monitor.sequence -NowTicks (Get-InitialPreparationTick)
	return [pscustomobject]@{ status = $(if ($Consumed) { 'fresh' } else { 'pending' }); sequence = $Monitor.sequence;
		observedTicks = $Monitor.lastObservation.observedTicks; freshnessSeconds = 60 }
}
