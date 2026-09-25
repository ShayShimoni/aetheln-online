[CmdletBinding()]
param([Parameter(Mandatory)][string] $EvidenceRoot, [Parameter(Mandatory)][string] $SnapshotJson,
	[Parameter(Mandatory)][ValidateSet('ready', 'held', 'crash', 'malformed', 'future', 'labels')][string] $Mode)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Mode -ceq 'crash') { exit 7 }
$Snapshot = $SnapshotJson | ConvertFrom-Json
$Snapshot.observedTicks = [Diagnostics.Stopwatch]::GetTimestamp()
if ($Mode -ceq 'future') { $Snapshot.observedTicks += [Diagnostics.Stopwatch]::Frequency * 61 }
if ($Mode -ceq 'labels') { $Snapshot.labels += 'aetheln-engine' }
$Json = if ($Mode -ceq 'malformed') { '{oops' } else { $Snapshot | ConvertTo-Json -Depth 4 -Compress }
$Bytes = [Text.Encoding]::UTF8.GetBytes($Json)
$Stream = [IO.File]::Open((Join-Path $EvidenceRoot 'snapshot-0001.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
	$Stream.Write($Bytes, 0, $Bytes.Length)
	$Stream.Flush($true)
	if ($Mode -cne 'held') { $Stream.Dispose(); $Stream = $null }
	$Ready = [IO.File]::Open((Join-Path $EvidenceRoot 'ready.txt'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
	$Ready.Dispose()
	Start-Sleep -Seconds 60
} finally { if ($null -ne $Stream) { $Stream.Dispose() } }
