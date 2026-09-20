# Synchronous progress uses one persistent sampler; caller owns process cleanup.
. (Join-Path $PSScriptRoot 'InitialPreparation.Core.ps1')
function New-InitialPreparationProgressContext {
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)] $Attempt, [Parameter(Mandatory)] $Roots,
		[Parameter(Mandatory)][string] $EvidenceRoot, [hashtable] $KnownAllocations = @{})
	Assert-InitialPreparationAttempt -Attempt $Attempt
	if ($Roots -isnot [Collections.IDictionary] -or $Roots.Count -lt 1) { throw 'resource_root_invalid' }
	foreach ($Name in $KnownAllocations.Keys) {
		if (-not $Roots.Contains($Name) -or ($KnownAllocations[$Name] -isnot [int] -and $KnownAllocations[$Name] -isnot [long]) -or $KnownAllocations[$Name] -lt 0) { throw 'resource_allocation_invalid' }
	}
	if (-not [IO.Path]::IsPathRooted($EvidenceRoot) -or -not (Test-Path -LiteralPath $EvidenceRoot -PathType Container)) { throw 'resource_evidence_invalid' }
	if (-not $PSCmdlet.ShouldProcess($EvidenceRoot, 'Reserve synchronous resource evidence')) { throw 'resource_progress_declined' }
	$Pins = @(); $Stream = $null
	try {
		$Pins = Get-InitialPreparationDirectoryPin -Directory $EvidenceRoot
		$Path = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) 'synchronous-resources.jsonl'
		if (Test-Path -LiteralPath $Path) { throw 'resource_evidence_exists' }
		$Stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
		$RootCopy = @{}; foreach ($Name in $Roots.Keys) { $RootCopy[$Name] = $Roots[$Name] }
		return [pscustomobject]@{
			attempt = $Attempt; roots = $RootCopy; knownAllocations = $KnownAllocations.Clone()
			evidencePath = $Path; stream = $Stream; pins = $Pins; evidenceBytes = 0L
			sampleCount = 0; consecutivePressureSamples = 0; lastSampleTicks = $null
			lastObservedTicks = $null; failureCode = $null; closed = $false
		}
	} catch {
		if ($null -ne $Stream) { $Stream.Dispose() }
		foreach ($Pin in $Pins) { $Pin.Dispose() }
		throw
	}
}

function Invoke-InitialPreparationProgress {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Context)
	if ($Context.closed) { throw 'resource_progress_closed' }
	if ($null -ne $Context.failureCode) { throw $Context.failureCode }
	try {
		$Now = Get-InitialPreparationTick
		if (($Now -isnot [int] -and $Now -isnot [long]) -or $Now -lt 0 -or
			($null -ne $Context.lastObservedTicks -and $Now -lt $Context.lastObservedTicks)) { throw 'monotonic_clock_unavailable' }
		$Context.lastObservedTicks = $Now
		if ($Now -ge $Context.attempt.stopUsefulWorkTicks) { throw 'useful_work_deadline' }
		if ($null -ne $Context.lastSampleTicks -and
			([decimal] $Now - [decimal] $Context.lastSampleTicks) -lt (5 * [decimal] $Context.attempt.monotonicFrequency)) { return }
		if ($Context.sampleCount -ge 4096 -or $Context.evidenceBytes -ge 16MB) { throw 'resource_evidence_limit' }
		try {
			$Capacity = Get-InitialPreparationCapacity -Roots $Context.roots -Attempt $Context.attempt -KnownAllocations $Context.knownAllocations
			foreach ($Name in @('availablePhysicalRamGiB', 'commitHeadroomGiB')) {
				$Value = $Capacity.$Name
				if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or $Value -is [array] -or
					[double]::IsNaN([double] $Value) -or [double]::IsInfinity([double] $Value) -or [double] $Value -lt 0) { throw 'resource_measurement_unavailable' }
			}
			$Volumes = @($Capacity.volumes)
			if ($Volumes.Count -lt 1 -or $Volumes.Count -gt 64) { throw 'resource_measurement_unavailable' }
			$FloorReached = $false; $VolumeRecords = @()
			foreach ($Volume in $Volumes) {
				foreach ($Name in @('availableBytes', 'knownAllocationBytes', 'recoveryFloorBytes')) {
					$Value = $Volume.$Name
					if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt 0) { throw 'resource_measurement_unavailable' }
				}
				if ($Volume.recoveryFloorBytes -ne 20GB -or $Volume.volumeId -isnot [string] -or
					[string]::IsNullOrWhiteSpace($Volume.volumeId) -or $Volume.volumeId.Length -gt 256) { throw 'resource_measurement_unavailable' }
				if ([decimal] $Volume.availableBytes -le ([decimal] $Volume.knownAllocationBytes + [decimal] $Volume.recoveryFloorBytes)) { $FloorReached = $true }
				$VolumeRecords += [ordered]@{ volumeId = $Volume.volumeId; availableBytes = $Volume.availableBytes; knownAllocationBytes = $Volume.knownAllocationBytes; recoveryFloorBytes = $Volume.recoveryFloorBytes }
			}
		} catch { throw 'resource_measurement_unavailable' }
		$End = Get-InitialPreparationTick
		if (($End -isnot [int] -and $End -isnot [long]) -or $End -lt $Now) { throw 'monotonic_clock_unavailable' }
		$Context.lastObservedTicks = $End
		if ($End -ge $Context.attempt.stopUsefulWorkTicks) { throw 'useful_work_deadline' }
		$Context.lastSampleTicks = $End
		if ([double] $Capacity.availablePhysicalRamGiB -lt 2.0 -or [double] $Capacity.commitHeadroomGiB -lt 2.0) { $Context.consecutivePressureSamples++ } else { $Context.consecutivePressureSamples = 0 }
		$Record = [ordered]@{ schemaVersion = 1; attemptId = $Context.attempt.attemptId; sample = ($Context.sampleCount + 1); sampleTicks = $End; availablePhysicalRamGiB = $Capacity.availablePhysicalRamGiB; commitHeadroomGiB = $Capacity.commitHeadroomGiB; volumes = $VolumeRecords; consecutivePressureSamples = $Context.consecutivePressureSamples }
		$Bytes = (New-Object Text.UTF8Encoding $false).GetBytes(($Record | ConvertTo-Json -Depth 6 -Compress) + "`n")
		if ($Bytes.Length -gt 64KB -or ([decimal] $Context.evidenceBytes + $Bytes.Length) -gt 16MB) { throw 'resource_evidence_limit' }
		try { $Context.stream.Write($Bytes, 0, $Bytes.Length); $Context.stream.Flush() } catch { throw 'resource_evidence_failed' }
		$Context.evidenceBytes += $Bytes.Length
		$Context.sampleCount++
		if ($FloorReached) { throw 'disk_recovery_floor_reached' }
		if ($Context.consecutivePressureSamples -ge 3) { throw 'resource_pressure' }
	} catch {
		$Context.failureCode = $_.Exception.Message
		throw
	}
}

function Close-InitialPreparationProgress {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Context)
	if ($Context.closed) { return }
	$Context.closed = $true
	try { $Context.stream.Dispose() } finally { foreach ($Pin in $Context.pins) { $Pin.Dispose() } }
}
