param([string] $CoreDefinitionsPath = (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'scripts/ci/InitialPreparation.Core.ps1'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'scripts/ci/RoutineCompileResources.ps1') -CoreDefinitionsPath $CoreDefinitionsPath
$script:Assertions = 0
function Assert-ResourceFixture {
	param([bool] $Condition, [string] $Message)
	if (-not $Condition) { throw $Message }
	$script:Assertions++
}
function Assert-ResourceFailure {
	param([scriptblock] $Action, [string] $Reason)
	$Observed = $null
	try { $null = & $Action } catch { $Observed = $_.Exception.Message }
	Assert-ResourceFixture -Condition ($Observed -ceq $Reason) -Message ('Expected ' + $Reason + '; observed ' + $Observed)
}
function New-ResourceFixture {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates only in-memory test objects using injected read-only probes.')]
	[CmdletBinding()]
	[OutputType([hashtable])]
	param([Collections.IDictionary] $Allocations = @{}, [hashtable] $InitialState = @{})
	$State = @{ milliseconds = 0L; ram = 24GB; commit = 24GB; cores = 16; disk = 80GB; reads = 0; coreReads = 0; id = 'volume-a' }
	foreach ($Name in $InitialState.Keys) { $State[$Name] = $InitialState[$Name] }
	$Resolve = { param($Root) return [pscustomobject]@{ volumeId = 'volume-a'; mount = $Root } }.GetNewClosure()
	$Disk = { param($Volume) $null = $Volume; $State.reads++; return [pscustomobject]@{ volumeId = $State.id; availableBytes = $State.disk } }.GetNewClosure()
	$Memory = { return [pscustomobject]@{ availableRamBytes = $State.ram; commitHeadroomBytes = $State.commit } }.GetNewClosure()
	$Cores = { $State.coreReads++; return $State.cores }.GetNewClosure()
	$Clock = { return $State.milliseconds }.GetNewClosure()
	$Monitor = New-RoutineCompileResourceMonitor -Roots ([ordered]@{ target = 'C:/target'; logs = 'X:/alias' }) -KnownAllocations $Allocations -ResolveVolume $Resolve -ReadDisk $Disk -ReadMemory $Memory -ReadPhysicalCores $Cores -ReadMilliseconds $Clock
	return @{ state = $State; monitor = $Monitor }
}
$F = New-ResourceFixture -Allocations @{ target = 1GB; logs = 2GB }
$Proof = Get-RoutineCompileResourceProof -Monitor $F.monitor
Assert-ResourceFixture -Condition ($Proof.volumes.Count -eq 1 -and $Proof.volumes[0].knownAllocationBytes -eq 3GB) -Message 'Physical volume aliases deduplicate floor, sum explicit allocations.'
Assert-ResourceFixture -Condition ($F.monitor.lastAvailableRamBytes -eq 24GB -and $F.monitor.lastCommitHeadroomBytes -eq 24GB -and
	$null -eq $Proof.PSObject.Properties['lastAvailableRamBytes']) -Message 'Retain the last memory sample internally without expanding the closed CI proof schema.'
Assert-ResourceFixture -Condition ($Proof.sampleCount -eq 1 -and $F.state.reads -eq 1) -Message 'Initial sample reads each unique volume once.'
Assert-ResourceFixture -Condition ((Get-RoutineCompileActionLimit -Monitor $F.monitor) -eq 4) -Message 'Action cap four.'
$F.state.cores = 1
Assert-ResourceFixture -Condition ((Get-RoutineCompileActionLimit -Monitor $F.monitor) -eq 4 -and $F.state.coreReads -eq 1) -Message 'Cores discovered once; not probed per sample.'
$F.state.ram = 9GB
Assert-ResourceFixture -Condition ((Get-RoutineCompileActionLimit -Monitor $F.monitor) -eq 1) -Message 'Exact 9 GiB gives one action.'
$F.state.ram = 9GB - 1L
Assert-ResourceFailure -Action { Get-RoutineCompileActionLimit -Monitor $F.monitor } -Reason 'resource_admission_refused'
Assert-ResourceFailure -Action { Update-RoutineCompileResources -Monitor $F.monitor } -Reason 'resource_admission_refused'
$F = New-ResourceFixture
$F.state.commit = 12GB
Assert-ResourceFixture -Condition ((Get-RoutineCompileActionLimit -Monitor $F.monitor) -eq 2) -Message 'Commit headroom caps actions.'
$F = New-ResourceFixture -InitialState @{ cores = 1 }
Assert-ResourceFixture -Condition ((Get-RoutineCompileActionLimit -Monitor $F.monitor) -eq 1) -Message 'Physical core limit caps actions.'
$F = New-ResourceFixture
$F.state.milliseconds = 4999L
Assert-ResourceFixture -Condition (-not (Update-RoutineCompileResources -Monitor $F.monitor) -and $F.state.reads -eq 1) -Message 'No early sample.'
$F.state.milliseconds = 5000L
Assert-ResourceFixture -Condition ((Update-RoutineCompileResources -Monitor $F.monitor) -and $F.state.reads -eq 2) -Message 'Sample at exact five seconds.'
$F.state.milliseconds = 22000L
$null = Update-RoutineCompileResources -Monitor $F.monitor
$Proof = Get-RoutineCompileResourceProof -Monitor $F.monitor
Assert-ResourceFixture -Condition ($Proof.sampleCount -eq 3 -and $Proof.maximumSampleGapMilliseconds -eq 17000L) -Message 'Late call samples once; records gap, never fabricates catch-up samples.'
Assert-ResourceFixture -Condition (($Proof | ConvertTo-Json -Depth 5 -Compress).Length -lt 2000) -Message 'Aggregate proof stays bounded.'
$F = New-ResourceFixture
foreach ($Tick in @(5000L, 10000L)) { $F.state.milliseconds = $Tick; $F.state.ram = 2GB - 1L; $null = Update-RoutineCompileResources -Monitor $F.monitor }
$F.state.milliseconds = 15000L; $F.state.ram = 2GB; $F.state.commit = 2GB
$null = Update-RoutineCompileResources -Monitor $F.monitor
Assert-ResourceFixture -Condition ((Get-RoutineCompileResourceProof -Monitor $F.monitor).consecutivePressureSamples -eq 0) -Message 'Exactly 2 GiB is healthy; resets pressure.'
foreach ($Tick in @(20000L, 25000L)) { $F.state.milliseconds = $Tick; $F.state.commit = 2GB - 1L; $null = Update-RoutineCompileResources -Monitor $F.monitor }
$F.state.milliseconds = 30000L
Assert-ResourceFailure -Action { Update-RoutineCompileResources -Monitor $F.monitor } -Reason 'resource_pressure'
Assert-ResourceFixture -Condition ((Get-RoutineCompileResourceProof -Monitor $F.monitor).consecutivePressureSamples -eq 3) -Message 'Pressure failure retained.'
Assert-ResourceFixture -Condition ($F.monitor.lastCommitHeadroomBytes -eq (2GB - 1L)) -Message 'A sticky pressure failure must preserve the last measured commit headroom.'
$F = New-ResourceFixture
foreach ($Tick in @(5000L, 10000L)) { $F.state.milliseconds = $Tick; $F.state.ram = 1GB; $null = Update-RoutineCompileResources -Monitor $F.monitor }
$F.state.milliseconds = 15000L; $F.state.ram = 24GB; $F.state.commit = 1GB
Assert-ResourceFailure -Action { Update-RoutineCompileResources -Monitor $F.monitor } -Reason 'resource_pressure'
$F = New-ResourceFixture
$F.state.ram = 1GB; $F.state.milliseconds = 5000L
$null = Update-RoutineCompileResources -Monitor $F.monitor
1..10 | ForEach-Object { $null = Update-RoutineCompileResources -Monitor $F.monitor }
Assert-ResourceFixture -Condition ((Get-RoutineCompileResourceProof -Monitor $F.monitor).consecutivePressureSamples -eq 1) -Message 'Frequent polls do not fabricate pressure samples.'
foreach ($Disk in @((20GB + 3GB), (20GB + 3GB - 1L))) {
	$F = New-ResourceFixture -Allocations @{ target = 1GB; logs = 2GB }
	$F.state.disk = $Disk; $F.state.milliseconds = 5000L
	Assert-ResourceFailure -Action { Update-RoutineCompileResources -Monitor $F.monitor } -Reason 'disk_floor_reached'
}
$F = New-ResourceFixture -Allocations @{ target = 1GB; logs = 2GB }
$F.state.disk = 23GB + 1L; $F.state.milliseconds = 5000L
Assert-ResourceFixture -Condition (Update-RoutineCompileResources -Monitor $F.monitor) -Message 'One byte over allocation plus floor succeeds.'
foreach ($Bad in @($null, '100000000000', [double]::NaN, [double]::PositiveInfinity, -1L, $true)) {
	$F = New-ResourceFixture
	$F.state.disk = $Bad; $F.state.milliseconds = 5000L
	Assert-ResourceFailure -Action { Update-RoutineCompileResources -Monitor $F.monitor } -Reason 'resource_measurement_unavailable'
	$F = New-ResourceFixture
	$F.state.ram = $Bad; $F.state.milliseconds = 5000L
	Assert-ResourceFailure -Action { Update-RoutineCompileResources -Monitor $F.monitor } -Reason 'resource_measurement_unavailable'
	$F = New-ResourceFixture
	$F.state.commit = $Bad; $F.state.milliseconds = 5000L
	Assert-ResourceFailure -Action { Update-RoutineCompileResources -Monitor $F.monitor } -Reason 'resource_measurement_unavailable'
	Assert-ResourceFailure -Action { New-ResourceFixture -InitialState @{ cores = $Bad } } -Reason 'resource_measurement_unavailable'
}
$F = New-ResourceFixture
$F.state.id = 'different-volume'; $F.state.milliseconds = 5000L
Assert-ResourceFailure -Action { Update-RoutineCompileResources -Monitor $F.monitor } -Reason 'resource_volume_changed'
$F = New-ResourceFixture
$F.state.milliseconds = -1L
Assert-ResourceFailure -Action { Update-RoutineCompileResources -Monitor $F.monitor } -Reason 'resource_clock_invalid'
$F = New-ResourceFixture
$F.state.milliseconds = 4000L; $null = Update-RoutineCompileResources -Monitor $F.monitor
$F.state.milliseconds = 3999L
Assert-ResourceFailure -Action { Update-RoutineCompileResources -Monitor $F.monitor } -Reason 'resource_clock_invalid'
Assert-ResourceFailure -Action { New-ResourceFixture -Allocations @{ unknown = 1GB } } -Reason 'resource_allocation_invalid'
Assert-ResourceFailure -Action { New-ResourceFixture -Allocations @{ target = -1L } } -Reason 'resource_allocation_invalid'
Assert-ResourceFailure -Action { New-ResourceFixture -Allocations @{ target = [long]::MaxValue; logs = 1L } } -Reason 'resource_allocation_invalid'
Assert-ResourceFailure -Action { New-ResourceFixture -InitialState @{ cores = 0 } } -Reason 'resource_measurement_unavailable'
Assert-ResourceFailure -Action { New-ResourceFixture -InitialState @{ disk = 20GB } } -Reason 'disk_floor_reached'
$F = New-ResourceFixture
$F.state.commit = 9GB - 1L
Assert-ResourceFailure -Action { Get-RoutineCompileActionLimit -Monitor $F.monitor } -Reason 'resource_admission_refused'
$F = New-ResourceFixture
$F.state.disk = 20GB
Assert-ResourceFailure -Action { Get-RoutineCompileActionLimit -Monitor $F.monitor } -Reason 'disk_floor_reached'
$F = New-ResourceFixture
$F.monitor.readMemory = { return [pscustomobject]@{ availableRamBytes = 24GB } }
$F.state.milliseconds = 5000L
Assert-ResourceFailure -Action { Update-RoutineCompileResources -Monitor $F.monitor } -Reason 'resource_measurement_unavailable'
$F = New-ResourceFixture
$F.monitor.readDisk = { throw 'injected probe exception with local implementation paths' }
$F.state.milliseconds = 5000L
Assert-ResourceFailure -Action { Update-RoutineCompileResources -Monitor $F.monitor } -Reason 'resource_measurement_unavailable'
$F = New-ResourceFixture
$F.monitor.readMilliseconds = { throw 'clock failure detail' }
Assert-ResourceFailure -Action { Update-RoutineCompileResources -Monitor $F.monitor } -Reason 'resource_measurement_unavailable'
$ResolveDistinct = { param($Root) return [pscustomobject]@{ volumeId = $Root; mount = $Root } }
$ReadDistinct = { param($Volume) return [pscustomobject]@{ volumeId = $Volume.volumeId; availableBytes = 30GB } }
$Distinct = New-RoutineCompileResourceMonitor -Roots ([ordered]@{ one = 'one'; two = 'two' }) -KnownAllocations @{ one = 3GB; two = 4GB } -ResolveVolume $ResolveDistinct -ReadDisk $ReadDistinct -ReadMemory { return [pscustomobject]@{ availableRamBytes = 24GB; commitHeadroomBytes = 24GB } } -ReadPhysicalCores { return 8 } -ReadMilliseconds { return 0L }
$DistinctProof = Get-RoutineCompileResourceProof -Monitor $Distinct
Assert-ResourceFixture -Condition ($DistinctProof.volumes.Count -eq 2 -and $DistinctProof.volumes[0].knownAllocationBytes -eq 3GB -and $DistinctProof.volumes[1].knownAllocationBytes -eq 4GB) -Message 'Separate volumes retain separate floors and allocations.'
$DistinctProof.volumes[0].knownAllocationBytes = 99GB
Assert-ResourceFixture -Condition ((Get-RoutineCompileResourceProof -Monitor $Distinct).volumes[0].knownAllocationBytes -eq 3GB) -Message 'Proof does not expose mutable internal references.'
$F = New-ResourceFixture
1..1000 | ForEach-Object { $F.state.milliseconds = [long] $_ * 5000L; $null = Update-RoutineCompileResources -Monitor $F.monitor }
$Proof = Get-RoutineCompileResourceProof -Monitor $F.monitor
Assert-ResourceFixture -Condition ($Proof.sampleCount -eq 1001 -and ($Proof | ConvertTo-Json -Depth 5 -Compress).Length -lt 2000) -Message 'Long runtime retains counters, not per-sample history.'
$BeforeSamples = $Proof.sampleCount
$BeforeReads = $Proof.measurementCount
$null = Get-RoutineCompileActionLimit -Monitor $F.monitor
$Proof = Get-RoutineCompileResourceProof -Monitor $F.monitor
Assert-ResourceFixture -Condition ($Proof.sampleCount -eq $BeforeSamples -and $Proof.measurementCount -eq $BeforeReads + 1) -Message 'Between-sample admission obtains fresh measurements without extra pressure sample.'
foreach ($InvalidVolume in @($null, [pscustomobject]@{ mount = 'x' }, [pscustomobject]@{ volumeId = 'v' })) {
	Assert-ResourceFailure -Action { New-RoutineCompileResourceMonitor -Roots @{ target = 'x' } -ResolveVolume { return $InvalidVolume } } -Reason 'resource_volume_ambiguous'
}
Write-Output ('PASS ' + $script:Assertions + ' routine resource assertions.')
