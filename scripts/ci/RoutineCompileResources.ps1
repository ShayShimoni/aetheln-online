param([string] $CoreDefinitionsPath = (Join-Path $PSScriptRoot 'InitialPreparation.Core.ps1'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# This imports definitions only. Never call attempt/controller entry points.
. $CoreDefinitionsPath

function ConvertTo-RoutineResourceInteger {
	param($Value, [string] $Reason = 'resource_measurement_unavailable')
	if (($Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [uint32] -and $Value -isnot [uint64]) -or
		$Value -lt 0 -or [decimal] $Value -gt [long]::MaxValue) { throw $Reason }
	return [long] $Value
}

function Stop-RoutineResourceMonitor {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Records a terminal reason in the caller-owned in-memory monitor and throws; no process or external state is changed.')]
	[CmdletBinding()]
	param($Monitor, [string] $Reason)
	if (@('resource_measurement_unavailable', 'resource_volume_changed', 'resource_clock_invalid',
		'disk_floor_reached', 'resource_pressure', 'resource_admission_refused') -cnotcontains $Reason) {
		$Reason = 'resource_measurement_unavailable'
	}
	if ($null -eq $Monitor.failureReason) { $Monitor.failureReason = $Reason }
	throw $Monitor.failureReason
}

function Read-RoutineResourceCapacity {
	param($Monitor)
	if ($null -ne $Monitor.failureReason) { throw $Monitor.failureReason }
	try {
		$Memory = & $Monitor.readMemory
		$Ram = ConvertTo-RoutineResourceInteger -Value $Memory.availableRamBytes
		$Commit = ConvertTo-RoutineResourceInteger -Value $Memory.commitHeadroomBytes
		$Volumes = @()
		foreach ($Volume in $Monitor.volumes) {
			$Reading = & $Monitor.readDisk $Volume
			if ($Reading.volumeId -isnot [string] -or [string]::IsNullOrWhiteSpace($Reading.volumeId)) { throw 'resource_measurement_unavailable' }
			if (-not [string]::Equals($Reading.volumeId, $Volume.volumeId, [StringComparison]::OrdinalIgnoreCase)) { throw 'resource_volume_changed' }
			$Free = ConvertTo-RoutineResourceInteger -Value $Reading.availableBytes
			$Volume.minimumAvailableBytes = [Math]::Min($Volume.minimumAvailableBytes, $Free)
			$Volumes += [pscustomobject]@{ availableBytes = $Free; knownAllocationBytes = $Volume.knownAllocationBytes; recoveryFloorBytes = 20GB }
		}
		$Monitor.measurementCount++
		$Monitor.minimumAvailableRamBytes = [Math]::Min($Monitor.minimumAvailableRamBytes, $Ram)
		$Monitor.minimumCommitHeadroomBytes = [Math]::Min($Monitor.minimumCommitHeadroomBytes, $Commit)
		foreach ($Volume in $Volumes) {
			if ([decimal] $Volume.availableBytes -le ([decimal] $Volume.knownAllocationBytes + 20GB)) { throw 'disk_floor_reached' }
		}
		return [pscustomobject]@{ physicalCores = $Monitor.physicalCores; availablePhysicalRamGiB = [double] $Ram / 1GB;
			commitHeadroomGiB = [double] $Commit / 1GB; volumes = $Volumes }
	} catch { Stop-RoutineResourceMonitor -Monitor $Monitor -Reason $_.Exception.Message }
}

function New-RoutineCompileResourceMonitor {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory measurement object using read-only probes; no external state is changed.')]
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][Collections.IDictionary] $Roots,
		[Collections.IDictionary] $KnownAllocations = @{},
		[scriptblock] $ResolveVolume = {
			param($Root)
			if ($Root -isnot [string] -or $Root -notmatch '^[A-Za-z]:[\\/]' -or -not (Test-Path -LiteralPath $Root -PathType Container)) { throw 'resource_root_invalid' }
			$Full = [IO.Path]::GetFullPath($Root)
			Assert-InitialPreparationPlainPath -Path $Full -Reason 'resource_root_invalid'
			Initialize-InitialPreparationMemoryType
			$Identity = [Aetheln.InitialPreparationMemory]::Volume($Full)
			return [pscustomobject]@{ mount = $Identity[0]; volumeId = $Identity[1] }
		},
		[scriptblock] $ReadDisk = {
			param($Volume)
			Initialize-InitialPreparationMemoryType
			$Identity = [Aetheln.InitialPreparationMemory]::Volume($Volume.mount)
			$Drive = New-Object IO.DriveInfo $Volume.mount
			if (-not $Drive.IsReady) { throw 'resource_measurement_unavailable' }
			return [pscustomobject]@{ volumeId = $Identity[1]; availableBytes = $Drive.AvailableFreeSpace }
		},
		[scriptblock] $ReadMemory = {
			Initialize-InitialPreparationMemoryType
			$Memory = [Aetheln.InitialPreparationMemory]::Read()
			return [pscustomobject]@{ availableRamBytes = $Memory[0]; commitHeadroomBytes = $Memory[1] }
		},
		[scriptblock] $ReadPhysicalCores = {
			return [int] (@(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Measure-Object -Property NumberOfCores -Sum).Sum)
		},
		[scriptblock] $ReadMilliseconds = { return [long] ([Diagnostics.Stopwatch]::GetTimestamp() * 1000.0 / [Diagnostics.Stopwatch]::Frequency) }
	)
	if ($Roots.Count -lt 1) { throw 'resource_root_invalid' }
	foreach ($Name in $KnownAllocations.Keys) {
		if (-not $Roots.Contains($Name)) { throw 'resource_allocation_invalid' }
		$null = ConvertTo-RoutineResourceInteger -Value $KnownAllocations[$Name] -Reason 'resource_allocation_invalid'
	}
	$Volumes = [ordered]@{}
	foreach ($Name in $Roots.Keys) {
		if ($Name -isnot [string] -or [string]::IsNullOrWhiteSpace($Name) -or
			$Roots[$Name] -isnot [string] -or [string]::IsNullOrWhiteSpace($Roots[$Name])) { throw 'resource_root_invalid' }
		try {
			$Resolved = & $ResolveVolume $Roots[$Name]
			if ($null -eq $Resolved -or $Resolved.volumeId -isnot [string] -or [string]::IsNullOrWhiteSpace($Resolved.volumeId) -or
				$Resolved.mount -isnot [string] -or [string]::IsNullOrWhiteSpace($Resolved.mount)) { throw 'resource_volume_ambiguous' }
		} catch { throw 'resource_volume_ambiguous' }
		$Id = $Resolved.volumeId.ToLowerInvariant()
		if (-not $Volumes.Contains($Id)) {
			$Volumes[$Id] = [pscustomobject]@{ volumeId = $Id; mount = $Resolved.mount; knownAllocationBytes = 0L; minimumAvailableBytes = [long]::MaxValue }
		}
		if ($KnownAllocations.Contains($Name)) {
			$Allocation = [decimal] $Volumes[$Id].knownAllocationBytes + [decimal] $KnownAllocations[$Name]
			if ($Allocation -gt [long]::MaxValue - 20GB) { throw 'resource_allocation_invalid' }
			$Volumes[$Id].knownAllocationBytes = [long] $Allocation
		}
	}
	try {
		$Cores = ConvertTo-RoutineResourceInteger -Value (& $ReadPhysicalCores)
		if ($Cores -lt 1 -or $Cores -gt [int]::MaxValue) { throw 'resource_measurement_unavailable' }
	} catch { throw 'resource_measurement_unavailable' }
	$Monitor = [pscustomobject]@{
		volumes = @($Volumes.Values); physicalCores = [int] $Cores; readDisk = $ReadDisk; readMemory = $ReadMemory;
		readMilliseconds = $ReadMilliseconds; lastClockMilliseconds = $null; lastSampleMilliseconds = $null;
		maximumSampleGapMilliseconds = 0L; sampleCount = 0L; measurementCount = 0L;
		consecutivePressureSamples = 0; maximumConsecutivePressureSamples = 0;
		minimumAvailableRamBytes = [long]::MaxValue; minimumCommitHeadroomBytes = [long]::MaxValue;
		lastCapacity = $null; failureReason = $null; targetAdmissionCount = 0L; minimumActionLimit = $null; maximumActionLimit = $null
	}
	$null = Update-RoutineCompileResources -Monitor $Monitor
	return $Monitor
}

function Update-RoutineCompileResources {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only updates the caller-owned in-memory measurement aggregate; no external state is changed.')]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The API samples disk, RAM and commit resources together as one observation.')]
	[CmdletBinding()]
	[OutputType([bool])]
	param([Parameter(Mandatory)] $Monitor)
	if ($null -ne $Monitor.failureReason) { throw $Monitor.failureReason }
	try {
		$Now = ConvertTo-RoutineResourceInteger -Value (& $Monitor.readMilliseconds) -Reason 'resource_clock_invalid'
		if ($null -ne $Monitor.lastClockMilliseconds -and $Now -lt $Monitor.lastClockMilliseconds) { throw 'resource_clock_invalid' }
		$Monitor.lastClockMilliseconds = $Now
		if ($null -ne $Monitor.lastSampleMilliseconds -and $Now - $Monitor.lastSampleMilliseconds -lt 5000L) { return $false }
		if ($null -ne $Monitor.lastSampleMilliseconds) {
			$Monitor.maximumSampleGapMilliseconds = [Math]::Max($Monitor.maximumSampleGapMilliseconds, $Now - $Monitor.lastSampleMilliseconds)
		}
		$Capacity = Read-RoutineResourceCapacity -Monitor $Monitor
		$Monitor.lastCapacity = $Capacity
		$Monitor.lastSampleMilliseconds = $Now
		$Monitor.sampleCount++
		if ($Capacity.availablePhysicalRamGiB -lt 2.0 -or $Capacity.commitHeadroomGiB -lt 2.0) { $Monitor.consecutivePressureSamples++ }
		else { $Monitor.consecutivePressureSamples = 0 }
		$Monitor.maximumConsecutivePressureSamples = [Math]::Max($Monitor.maximumConsecutivePressureSamples, $Monitor.consecutivePressureSamples)
		if ($Monitor.consecutivePressureSamples -ge 3) { throw 'resource_pressure' }
		return $true
	} catch { Stop-RoutineResourceMonitor -Monitor $Monitor -Reason $_.Exception.Message }
}

function Get-RoutineCompileActionLimit {
	[CmdletBinding()]
	[OutputType([int])]
	param([Parameter(Mandatory)] $Monitor)
	# Admission refreshes readings even between scheduled samples, without
	# counting repeated calls as additional five-second pressure samples.
	try {
		$Sampled = Update-RoutineCompileResources -Monitor $Monitor
		$Capacity = if ($Sampled) { $Monitor.lastCapacity } else { Read-RoutineResourceCapacity -Monitor $Monitor }
		$Limit = Get-InitialPreparationActionLimit -Capacity $Capacity
		$Monitor.targetAdmissionCount++
		if ($null -eq $Monitor.minimumActionLimit) { $Monitor.minimumActionLimit = $Limit; $Monitor.maximumActionLimit = $Limit }
		else {
			$Monitor.minimumActionLimit = [Math]::Min($Monitor.minimumActionLimit, $Limit)
			$Monitor.maximumActionLimit = [Math]::Max($Monitor.maximumActionLimit, $Limit)
		}
		return $Limit
	} catch { Stop-RoutineResourceMonitor -Monitor $Monitor -Reason $_.Exception.Message }
}

function Get-RoutineCompileResourceProof {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Monitor)
	# Fixed-size counters/minima plus one record per configured physical volume.
	# No root paths, sample history, scriptblocks or mutable internal references.
	return [pscustomobject][ordered]@{
		schemaVersion = 1; sampleIntervalMilliseconds = 5000; recoveryFloorBytes = 20GB; pressureThresholdBytes = 2GB;
		sampleCount = $Monitor.sampleCount; measurementCount = $Monitor.measurementCount;
		maximumSampleGapMilliseconds = $Monitor.maximumSampleGapMilliseconds;
		consecutivePressureSamples = $Monitor.consecutivePressureSamples; maximumConsecutivePressureSamples = $Monitor.maximumConsecutivePressureSamples;
		minimumAvailableRamBytes = $Monitor.minimumAvailableRamBytes; minimumCommitHeadroomBytes = $Monitor.minimumCommitHeadroomBytes;
		physicalCores = $Monitor.physicalCores; targetAdmissionCount = $Monitor.targetAdmissionCount;
		minimumActionLimit = $Monitor.minimumActionLimit; maximumActionLimit = $Monitor.maximumActionLimit; failureReason = $Monitor.failureReason;
		volumes = @($Monitor.volumes | ForEach-Object {
			[pscustomobject]@{ volumeId = $_.volumeId; knownAllocationBytes = $_.knownAllocationBytes; minimumAvailableBytes = $_.minimumAvailableBytes }
		})
	}
}
