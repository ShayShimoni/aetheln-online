<#
.SYNOPSIS
Runs the replication-neutral packaged network-authority scenario and writes correlated evidence.

.DESCRIPTION
Starts one packaged server and two distinct packaged clients, observes the frozen authority
scenario through redirected process output, exercises disconnect/reconnect, cleans up processes,
and writes network-authority-spike-evidence.json. The caller supplies every runtime path,
scenario input, provenance identity, and observation pattern. This runner does not select a
replication candidate, latency policy, rewind policy, or numeric network profile.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerExecutable,
	[Parameter(Mandatory)] [string[]] $ServerArguments,
	[ValidateNotNullOrEmpty()] [string] $ServerLauncherExecutable,
	[string[]] $ServerLauncherArguments = @(),
	[string[]] $ServerIdentityArguments = @(),
	[string[]] $ServerCleanupArguments = @(),
	[string] $ServerProcessIdPattern,
	[string] $ServerProvenanceExecutable,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ClientExecutable,
	[Parameter(Mandatory)] [string[]] $ClientArguments,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerEndpoint,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerMap,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ScenarioId,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ProfileId,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $NetworkConfigIdentity,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SourceRevision,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $BuildIdentity,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ToolchainIdentity,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $HardwareIdentity,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $TopologyIdentity,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ActorMixIdentity,
	[Parameter(Mandatory)] [ValidateSet('fixture', 'packaged')] [string] $EvidenceMode,
	[string] $PackagedBuildProvenancePath,
	[Parameter(Mandatory)] [ValidateRange(1, 86400)] [int] $DurationSeconds,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $LogRoot,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerReadyPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServerConnectionPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ClientReadyPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $MovementPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $EnemyPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $MeleePattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $DamagePattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RejectionPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $JoinInProgressPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $DisconnectPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ReconnectPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $NetworkConfigPattern,
	[ValidateNotNullOrEmpty()] [string] $ErrorPattern = '(?i)(fatal error|network\s+failure|connection\s+failed|failed to load package)',
	[ValidateRange(1, 3600)] [int] $TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

public sealed class AethelnProcessOutputCapture : IDisposable
{
	private readonly Process process;
	private readonly StreamWriter outputWriter;
	private readonly StreamWriter errorWriter;
	private readonly DataReceivedEventHandler outputHandler;
	private readonly DataReceivedEventHandler errorHandler;
	private bool disposed;

	public AethelnProcessOutputCapture(Process process, string outputPath, string errorPath)
	{
		this.process = process;
		outputWriter = new StreamWriter(outputPath, false, new UTF8Encoding(false));
		errorWriter = new StreamWriter(errorPath, false, new UTF8Encoding(false));
		outputWriter.AutoFlush = true;
		errorWriter.AutoFlush = true;
		outputHandler = OnOutputDataReceived;
		errorHandler = OnErrorDataReceived;
		process.OutputDataReceived += outputHandler;
		process.ErrorDataReceived += errorHandler;
	}

	private void OnOutputDataReceived(object sender, DataReceivedEventArgs eventArgs)
	{
		if (eventArgs.Data != null)
		{
			outputWriter.WriteLine(eventArgs.Data);
		}
	}

	private void OnErrorDataReceived(object sender, DataReceivedEventArgs eventArgs)
	{
		if (eventArgs.Data != null)
		{
			errorWriter.WriteLine(eventArgs.Data);
		}
	}

	public void Dispose()
	{
		if (disposed)
		{
			return;
		}

		disposed = true;
		process.OutputDataReceived -= outputHandler;
		process.ErrorDataReceived -= errorHandler;
		outputWriter.Dispose();
		errorWriter.Dispose();
	}
}
'@

function Resolve-Executable([string] $Name, [string] $Path) {
	if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Resolve-Path -LiteralPath $Path).Path }
	$Command = Get-Command $Path -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
	if (-not $Command) { throw "$Name '$Path' does not exist and is not available on PATH." }
	return [string] $Command.Source
}

function Initialize-EmptyLogRoot([string] $Path) {
	if (Test-Path -LiteralPath $Path) {
		if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "LogRoot '$Path' exists but is not a directory." }
		$Existing = @(Get-ChildItem -LiteralPath $Path -Force)
		if ($Existing.Count -gt 0) { throw "LogRoot '$Path' must be absent or empty; use a unique clean directory for every authority-spike run." }
	} else {
		New-Item -ItemType Directory -Path $Path | Out-Null
	}
	return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-Placeholder([string[]] $Arguments, [string] $Placeholder, [string] $Name) {
	if (($Arguments -join ' ') -notlike "*$Placeholder*") { throw "$Name must contain $Placeholder so scenario correlation is explicit." }
}

function Expand-Values([string] $Value, [string] $ClientId) {
	return $Value.Replace('{ClientId}', $ClientId).Replace('{ServerEndpoint}', $ServerEndpoint).Replace('{ServerMap}', $ServerMap).Replace('{ScenarioId}', $ScenarioId).Replace('{ProfileId}', $ProfileId).Replace('{NetworkConfigIdentity}', $NetworkConfigIdentity).Replace('{RunId}', $RunId)
}

function Expand-Arguments([string[]] $Arguments, [string] $ClientId) {
	return @($Arguments | ForEach-Object { Expand-Values $_ $ClientId })
}

function Expand-Pattern([string] $Pattern, [string] $ClientId) {
	return $Pattern.Replace('{ClientId}', [regex]::Escape($ClientId)).Replace('{ServerEndpoint}', [regex]::Escape($ServerEndpoint)).Replace('{ServerMap}', [regex]::Escape($ServerMap)).Replace('{ScenarioId}', [regex]::Escape($ScenarioId)).Replace('{ProfileId}', [regex]::Escape($ProfileId)).Replace('{NetworkConfigIdentity}', [regex]::Escape($NetworkConfigIdentity)).Replace('{RunId}', [regex]::Escape($RunId))
}

function Expand-ServerLauncherArguments([string[]] $Arguments, [string] $ResolvedServerExecutable, [string[]] $ExpandedServerArguments) {
	$Expanded = [System.Collections.Generic.List[string]]::new()
	foreach ($Argument in $Arguments) {
		if ($Argument -eq '{ServerArguments}') {
			foreach ($ServerArgument in $ExpandedServerArguments) { $Expanded.Add($ServerArgument) }
		} else {
			$Expanded.Add((Expand-Values $Argument 'server').Replace('{ServerExecutable}', $ResolvedServerExecutable))
		}
	}
	return @($Expanded)
}

function Expand-ServerControlArguments([string[]] $Arguments, [string] $ResolvedServerExecutable, [string] $ServerProcessId = '') {
	return @($Arguments | ForEach-Object {
		(Expand-Values $_ 'server').Replace('{ServerExecutable}', $ResolvedServerExecutable).Replace('{ServerProcessId}', $ServerProcessId)
	})
}

function ConvertTo-ProcessArgument([string] $Argument) {
	$Quoted = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
	$Quoted = [regex]::Replace($Quoted, '(\\+)$', '$1$1')
	return '"' + $Quoted + '"'
}

function Start-HiddenProcess([string] $Executable, [string[]] $Arguments, [string] $StandardOutputPath, [string] $StandardErrorPath) {
	$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = $Executable
	$StartInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ')
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true

	$Process = [System.Diagnostics.Process]::new()
	$Process.StartInfo = $StartInfo
	$Capture = [AethelnProcessOutputCapture]::new($Process, $StandardOutputPath, $StandardErrorPath)
	try {
		if (-not $Process.Start()) { throw "Could not start '$Executable'." }
		$Process.BeginOutputReadLine()
		$Process.BeginErrorReadLine()
		return [pscustomobject]@{ Process = $Process; Capture = $Capture }
	}
	catch {
		$Capture.Dispose()
		$Process.Dispose()
		throw
	}
}

function Get-RuntimeError([string[]] $Paths) {
	foreach ($Path in $Paths) {
		if (Test-Path -LiteralPath $Path -PathType Leaf) {
			$ErrorLine = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Where-Object { $_ -match $ErrorPattern } | Select-Object -First 1
			if ($ErrorLine) { return [string] $ErrorLine }
		}
	}
	return $null
}

function Wait-ForMatch([System.Diagnostics.Process] $Process, [string] $Path, [string] $ErrorPath, [string] $Description, [string] $Pattern) {
	$Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
	do {
		$ErrorLine = Get-RuntimeError @($Path, $ErrorPath)
		if ($ErrorLine) { throw "Runtime reported an error while waiting for ${Description}: $ErrorLine" }
		if (Test-Path -LiteralPath $Path -PathType Leaf) {
			$Line = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Where-Object { $_ -match $Pattern } | Select-Object -First 1
			if ($Line) { return [string] $Line }
		}
		$Process.Refresh()
		if ($Process.HasExited) {
			$Process.WaitForExit()
			throw "Process exited with code $($Process.ExitCode) while waiting for $Description. Review '$Path' and '$ErrorPath'."
		}
		Start-Sleep -Milliseconds 100
	} while ([DateTime]::UtcNow -lt $Deadline)
	throw "Timed out after $TimeoutSeconds seconds waiting for $Description in '$Path' (pattern '$Pattern')."
}

function Invoke-HiddenCommand([string] $Executable, [string[]] $Arguments, [string] $StandardOutputPath, [string] $StandardErrorPath, [string] $Description) {
	$Handle = Start-HiddenProcess $Executable $Arguments $StandardOutputPath $StandardErrorPath
	$Process = $Handle.Process
	try {
		if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
			Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
			$Process.WaitForExit()
			throw "Timed out after $TimeoutSeconds seconds waiting for $Description."
		}
		$Process.WaitForExit()
		if ($Process.ExitCode -ne 0) {
			$ErrorText = if (Test-Path -LiteralPath $StandardErrorPath) { [string] (Get-Content -LiteralPath $StandardErrorPath -Raw -ErrorAction SilentlyContinue) } else { '' }
			throw "$Description exited with code $($Process.ExitCode). Standard error: $ErrorText"
		}
		return [pscustomobject]@{
			Output = if (Test-Path -LiteralPath $StandardOutputPath) { Get-Content -LiteralPath $StandardOutputPath -Raw -ErrorAction Stop } else { '' }
			Error = if (Test-Path -LiteralPath $StandardErrorPath) { Get-Content -LiteralPath $StandardErrorPath -Raw -ErrorAction SilentlyContinue } else { '' }
		}
	}
	finally {
		try { $Process.CancelOutputRead() } catch { }
		try { $Process.CancelErrorRead() } catch { }
		$Handle.Capture.Dispose()
		$Process.Dispose()
	}
}

function Wait-ForRejection([System.Diagnostics.Process] $Process, [string] $Path, [string] $ErrorPath, [regex] $Regex, [string] $Category) {
	$Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
	do {
		$ErrorLine = Get-RuntimeError @($Path, $ErrorPath)
		if ($ErrorLine) { throw "Runtime reported an error while waiting for rejection '$Category': $ErrorLine" }
		if (Test-Path -LiteralPath $Path -PathType Leaf) {
			foreach ($Line in @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
				$Match = $Regex.Match($Line)
				if ($Match.Success -and $Match.Groups['Category'].Value -ceq $Category) { return [pscustomobject]@{ Line = [string] $Line; Match = $Match } }
			}
		}
		$Process.Refresh()
		if ($Process.HasExited) {
			$Process.WaitForExit()
			throw "Process exited with code $($Process.ExitCode) while waiting for rejection '$Category'. Review '$Path' and '$ErrorPath'."
		}
		Start-Sleep -Milliseconds 100
	} while ([DateTime]::UtcNow -lt $Deadline)
	throw "Timed out after $TimeoutSeconds seconds waiting for rejection '$Category' in '$Path'."
}

function Assert-ExactRejectionInventory([string[]] $Lines, [regex] $Regex, [System.Collections.IDictionary] $RequiredCategories) {
	$ObservedCounts = @{}
	$ObservedTotal = 0
	foreach ($Line in $Lines) {
		$Match = $Regex.Match($Line)
		if (-not $Match.Success) { continue }
		$Category = $Match.Groups['Category'].Value
		if ($Category -ceq 'disconnected-command') {
			throw 'Unexpected disconnected-command rejection without a transported command-validation attempt.'
		}
		if (-not $RequiredCategories.Contains($Category)) {
			throw "Unexpected authority rejection category '$Category'."
		}
		$Reason = $Match.Groups['Reason'].Value
		if ($Reason -cne $RequiredCategories[$Category]) {
			throw "Rejection '$Category' used unexpected reason '$Reason'."
		}
		$ClientId = $Match.Groups['ClientId'].Value
		if ($ClientId -cne 'client-2') {
			throw "Rejection '$Category' was not correlated to client-2."
		}
		$ObservedCounts[$Category] = 1 + [int] $ObservedCounts[$Category]
		++$ObservedTotal
	}
	foreach ($Category in $RequiredCategories.Keys) {
		if ([int] $ObservedCounts[$Category] -ne 1) {
			throw "Expected exactly one '$Category' rejection, observed $([int] $ObservedCounts[$Category])."
		}
	}
	if ($ObservedTotal -ne $RequiredCategories.Count) {
		throw "Expected exactly $($RequiredCategories.Count) correlated authority rejections, observed $ObservedTotal."
	}
}

function Wait-ForObservationInterval {
	param(
		[Parameter(Mandatory, Position = 0)] [object[]] $RequiredProcesses,
		[Parameter(Mandatory, Position = 1)] [int] $Seconds,
		[scriptblock] $UtcNow = { [DateTime]::UtcNow },
		[scriptblock] $Sleep = { param([int] $Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
	)

	$Deadline = (& $UtcNow).AddSeconds($Seconds)
	while ($true) {
		foreach ($Required in $RequiredProcesses) {
			$ErrorLine = Get-RuntimeError @($Required.StandardOutputPath, $Required.StandardErrorPath)
			if ($ErrorLine) { throw "Runtime '$($Required.Name)' reported an error during the observation interval: $ErrorLine" }
			$Required.Process.Refresh()
			if ($Required.Process.HasExited) {
				$Required.Process.WaitForExit()
				throw "Required process '$($Required.Name)' exited unexpectedly with code $($Required.Process.ExitCode) during the $Seconds-second observation interval. Review '$($Required.StandardOutputPath)' and '$($Required.StandardErrorPath)'."
			}
		}
		$RemainingMilliseconds = [Math]::Ceiling(($Deadline - (& $UtcNow)).TotalMilliseconds)
		if ($RemainingMilliseconds -le 0) { break }
		& $Sleep ([int] [Math]::Min(100, $RemainingMilliseconds))
	}
}

function New-Observation([string] $Event, [string] $Source, [string] $Detail, [string] $ClientId = '') {
	$Record = [ordered]@{ event = $Event; source = $Source; detail = $Detail }
	if ($ClientId) { $Record.client_id = $ClientId }
	return [pscustomobject] $Record
}

function Get-SingleMatchIndex([string[]] $Lines, [string] $Pattern, [string] $Description) {
	$Indexes = [System.Collections.Generic.List[int]]::new()
	for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
		if ($Lines[$Index] -match $Pattern) { $Indexes.Add($Index) }
	}
	if ($Indexes.Count -ne 1) { throw "Expected exactly one $Description record, observed $($Indexes.Count)." }
	return $Indexes[0]
}

function Assert-RecordToken([string] $Name, [string] $Value) {
	if ($Value -notmatch '^\S+$') { throw "$Name must be one non-empty structured-record token without whitespace." }
}

function Resolve-ProvenanceArchiveRoot([string] $Name, [string] $Path) {
	if (-not $Path -or -not [System.IO.Path]::IsPathRooted($Path)) { throw "$Name must be an absolute archive root." }
	if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Name '$Path' does not exist or is not a directory." }
	return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
}

function Get-ArchivePrefix([string] $ArchiveRoot) {
	$Trimmed = $ArchiveRoot.TrimEnd([char[]] @('\', '/'))
	if ($Trimmed -match '^[A-Za-z]:$') { return $Trimmed + '\' }
	return $Trimmed + [System.IO.Path]::DirectorySeparatorChar
}

function Get-ProvenancePathComparison([char] $DirectorySeparator = [System.IO.Path]::DirectorySeparatorChar) {
	if ($DirectorySeparator -ceq '\') { return [System.StringComparison]::OrdinalIgnoreCase }
	return [System.StringComparison]::Ordinal
}

function Resolve-ArchiveInventoryPath([string] $ArchiveRoot, [string] $InventoryPath) {
	if ([string]::IsNullOrWhiteSpace($InventoryPath) -or [System.IO.Path]::IsPathRooted($InventoryPath) -or $InventoryPath -match '^[A-Za-z]:') {
		throw 'Packaged provenance inventory path must be archive-relative and remain within its declared archive root.'
	}
	if ($InventoryPath.Contains('\')) {
		throw 'Packaged provenance inventory path must be an exact canonical archive-relative path.'
	}
	$NormalizedInventoryPath = $InventoryPath
	$NativePath = $InventoryPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
	$ResolvedPath = [System.IO.Path]::GetFullPath((Join-Path $ArchiveRoot $NativePath))
	$ArchivePrefix = Get-ArchivePrefix $ArchiveRoot
	if (-not $ResolvedPath.StartsWith($ArchivePrefix, (Get-ProvenancePathComparison))) {
		throw 'Packaged provenance inventory path must be archive-relative and remain within its declared archive root.'
	}
	$ResolvedRelativePath = $ResolvedPath.Substring($ArchivePrefix.Length).Replace('\', '/')
	if ($NormalizedInventoryPath -cne $ResolvedRelativePath) {
		throw 'Packaged provenance inventory path must be an exact canonical archive-relative path.'
	}
	Assert-NoProvenanceReparsePoint 'Packaged provenance inventory path' $ArchiveRoot $ResolvedPath -AllowMissing
	return [pscustomobject]@{
		FullPath = $ResolvedPath
		RelativePath = $ResolvedRelativePath
	}
}

function Assert-NoProvenanceReparsePoint([string] $Name, [string] $ArchiveRoot, [string] $ResolvedPath, [switch] $AllowMissing) {
	$ArchivePrefix = Get-ArchivePrefix $ArchiveRoot
	$CurrentPath = $ArchiveRoot.TrimEnd([char[]] @('\', '/'))
	$RelativePath = $ResolvedPath.Substring($ArchivePrefix.Length)
	$PathsToInspect = @($CurrentPath)
	foreach ($Segment in @($RelativePath -split '[\\/]')) {
		if ([string]::IsNullOrWhiteSpace($Segment)) { continue }
		$CurrentPath = Join-Path $CurrentPath $Segment
		$PathsToInspect += $CurrentPath
	}
	foreach ($CandidatePath in $PathsToInspect) {
		if (-not (Test-Path -LiteralPath $CandidatePath)) {
			if ($AllowMissing) { break }
			throw "$Name path component '$CandidatePath' does not exist."
		}
		$Attributes = [System.IO.File]::GetAttributes($CandidatePath)
		if (($Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
			throw "$Name must not traverse a reparse point beneath its packaged archive root."
		}
	}
}

function Resolve-ProvenanceExecutable([string] $Name, [string] $Path, [string] $ArchiveName, [string] $ArchiveRoot) {
	if (-not $Path -or -not [System.IO.Path]::IsPathRooted($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		throw "$Name must be an absolute existing file beneath packaged $ArchiveName."
	}
	$ResolvedPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
	$ArchivePrefix = Get-ArchivePrefix $ArchiveRoot
	if (-not $ResolvedPath.StartsWith($ArchivePrefix, (Get-ProvenancePathComparison))) {
		throw "$Name must resolve beneath packaged $ArchiveName."
	}
	Assert-NoProvenanceReparsePoint $Name $ArchiveRoot $ResolvedPath
	return [pscustomobject]@{
		FullPath = $ResolvedPath
		RelativePath = $ResolvedPath.Substring($ArchivePrefix.Length).Replace('\', '/')
		Sha256 = (Get-FileHash -LiteralPath $ResolvedPath -Algorithm SHA256).Hash.ToLowerInvariant()
	}
}

function Test-PackagedBuildProvenance([string] $Path, [string] $ActualServerSha256) {
	if (-not $Path) { throw 'PackagedBuildProvenancePath is required for packaged evidence.' }
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Packaged build provenance '$Path' does not exist." }
	try { $Provenance = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { throw "Packaged build provenance '$Path' is invalid JSON: $($_.Exception.Message)" }
	if ($Provenance.schemaVersion -ne 2 -or $Provenance.source.revision -cne $SourceRevision -or $Provenance.source.clean -ne $true) { throw 'Packaged build provenance does not bind a clean exact source revision.' }
	if ($Provenance.host.buildIdentity -cne $BuildIdentity) { throw 'BuildIdentity does not match packaged build provenance.' }
	$ClientArchive = Resolve-ProvenanceArchiveRoot 'artifacts.clientArchive' ([string] $Provenance.artifacts.clientArchive)
	$ServerArchive = Resolve-ProvenanceArchiveRoot 'artifacts.serverArchive' ([string] $Provenance.artifacts.serverArchive)
	$ServerHostExecutable = if ($ServerLauncherExecutable) { $ServerProvenanceExecutable } else { $ResolvedServer }
	$ClientBinding = Resolve-ProvenanceExecutable 'ClientExecutable' $ResolvedClient 'clientArchive' $ClientArchive
	$ServerBinding = Resolve-ProvenanceExecutable 'ServerProvenanceExecutable' $ServerHostExecutable 'serverArchive' $ServerArchive
	if ($ServerBinding.Sha256 -cne $ActualServerSha256) { throw 'Packaged executable identity is not uniquely bound by build provenance.' }
	$Inventory = @($Provenance.artifacts.inventory | ForEach-Object {
		$Kind = [string] $_.kind
		if ($Kind -cne 'client' -and $Kind -cne 'server') { throw 'Packaged provenance inventory kind must be client or server.' }
		$ArchiveRoot = if ($Kind -ceq 'client') { $ClientArchive } else { $ServerArchive }
		$ResolvedEntry = Resolve-ArchiveInventoryPath $ArchiveRoot ([string] $_.path)
		[pscustomobject]@{ Kind = $Kind; RelativePath = $ResolvedEntry.RelativePath; Sha256 = ([string] $_.sha256).ToLowerInvariant() }
	})
	$ClientEntries = @($Inventory | Where-Object {
		$_.Kind -ceq 'client' -and
		$_.RelativePath -ceq $ClientBinding.RelativePath
	})
	$ServerEntries = @($Inventory | Where-Object {
		$_.Kind -ceq 'server' -and
		$_.RelativePath -ceq $ServerBinding.RelativePath
	})
	if ($ClientEntries.Count -ne 1 -or $ServerEntries.Count -ne 1) { throw 'Packaged executable identity is not uniquely bound by build provenance.' }
	if ($ClientEntries[0].Sha256 -cne $ClientBinding.Sha256 -or $ServerEntries[0].Sha256 -cne $ActualServerSha256) { throw 'Packaged executable identity is not uniquely bound by build provenance.' }
	return [pscustomobject]@{ Path = (Resolve-Path -LiteralPath $Path).Path; Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
}

foreach ($Placeholder in @('{ServerEndpoint}','{ServerMap}','{ScenarioId}','{ProfileId}','{RunId}')) { Assert-Placeholder $ServerArguments $Placeholder 'ServerArguments' }
Assert-Placeholder $ServerArguments '{NetworkConfigIdentity}' 'ServerArguments'
foreach ($Placeholder in @('{ClientId}','{ServerEndpoint}','{ServerMap}','{ScenarioId}','{ProfileId}','{NetworkConfigIdentity}','{RunId}')) { Assert-Placeholder $ClientArguments $Placeholder 'ClientArguments' }
if ($ServerLauncherExecutable) {
	Assert-Placeholder $ServerLauncherArguments '{ServerExecutable}' 'ServerLauncherArguments'
	Assert-Placeholder $ServerLauncherArguments '{ServerArguments}' 'ServerLauncherArguments'
	Assert-Placeholder $ServerCleanupArguments '{ServerProcessId}' 'ServerCleanupArguments'
	if (-not $ServerProcessIdPattern) { throw 'ServerProcessIdPattern is required when ServerLauncherExecutable is supplied.' }
	$ServerProcessIdRegex = [regex]::new($ServerProcessIdPattern)
	if ($ServerProcessIdRegex.GetGroupNames() -notcontains 'ProcessId') { throw 'ServerProcessIdPattern must contain a named ProcessId capture.' }
	if ($EvidenceMode -ceq 'packaged') {
		Assert-Placeholder $ServerIdentityArguments '{ServerExecutable}' 'ServerIdentityArguments'
		if (-not $ServerProvenanceExecutable) { throw 'ServerProvenanceExecutable is required for packaged evidence when ServerLauncherExecutable is supplied.' }
	}
} elseif ($ServerLauncherArguments.Count -gt 0) {
	throw 'ServerLauncherExecutable is required when ServerLauncherArguments are supplied.'
} elseif ($ServerIdentityArguments.Count -gt 0 -or $ServerCleanupArguments.Count -gt 0 -or $ServerProcessIdPattern) {
	throw 'ServerLauncherExecutable is required when server identity or cleanup controls are supplied.'
}
foreach ($PatternEntry in @(
	@('ServerReadyPattern', $ServerReadyPattern), @('ServerConnectionPattern', $ServerConnectionPattern),
	@('ClientReadyPattern', $ClientReadyPattern), @('MovementPattern', $MovementPattern),
	@('EnemyPattern', $EnemyPattern), @('MeleePattern', $MeleePattern), @('DamagePattern', $DamagePattern),
	@('RejectionPattern', $RejectionPattern), @('JoinInProgressPattern', $JoinInProgressPattern),
	@('DisconnectPattern', $DisconnectPattern), @('ReconnectPattern', $ReconnectPattern),
	@('NetworkConfigPattern', $NetworkConfigPattern)
)) {
	foreach ($IdentityPlaceholder in @('{ScenarioId}','{ProfileId}','{RunId}')) { Assert-Placeholder @([string] $PatternEntry[1]) $IdentityPlaceholder ([string] $PatternEntry[0]) }
}
foreach ($TokenEntry in @(
	@('ServerEndpoint', $ServerEndpoint), @('ServerMap', $ServerMap), @('ScenarioId', $ScenarioId),
	@('ProfileId', $ProfileId), @('NetworkConfigIdentity', $NetworkConfigIdentity), @('RunId', $RunId),
	@('SourceRevision', $SourceRevision), @('BuildIdentity', $BuildIdentity), @('ToolchainIdentity', $ToolchainIdentity),
	@('HardwareIdentity', $HardwareIdentity), @('TopologyIdentity', $TopologyIdentity), @('ActorMixIdentity', $ActorMixIdentity)
)) { Assert-RecordToken ([string] $TokenEntry[0]) ([string] $TokenEntry[1]) }

$ConnectionRegex = [regex]::new((Expand-Pattern $ServerConnectionPattern ''))
if ($ConnectionRegex.GetGroupNames() -notcontains 'ClientId' -or $ConnectionRegex.GetGroupNames() -notcontains 'ConnectionId') { throw 'ServerConnectionPattern must contain named ClientId and ConnectionId captures.' }
$RejectionRegex = [regex]::new((Expand-Pattern $RejectionPattern ''))
foreach ($Capture in @('Category','Reason','ClientId')) { if ($RejectionRegex.GetGroupNames() -notcontains $Capture) { throw "RejectionPattern must contain a named $Capture capture." } }
$StableRejectionReasons = @('none','stale-sequence','duplicate-sequence','incompatible-version','timestamp-out-of-bounds','impossible-aim-transition','connection-closed','actor-destroyed','malformed-intent','activation-blocked')
$RequiredRejectionCategories = [ordered]@{
	'movement' = 'malformed-intent'
	'aim' = 'impossible-aim-transition'
	'activation' = 'activation-blocked'
	'hit' = 'malformed-intent'
	'cooldown' = 'activation-blocked'
	'dodge' = 'activation-blocked'
	'block' = 'activation-blocked'
	'damage' = 'malformed-intent'
}
$ReconnectRegex = [regex]::new((Expand-Pattern $ReconnectPattern 'client-1-reconnect'))
if ($ReconnectRegex.GetGroupNames() -notcontains 'ConnectionId') { throw 'ReconnectPattern must contain a named ConnectionId capture.' }

$ResolvedServer = if ($ServerLauncherExecutable) { $ServerExecutable } else { Resolve-Executable 'ServerExecutable' $ServerExecutable }
$ResolvedServerLauncher = if ($ServerLauncherExecutable) { Resolve-Executable 'ServerLauncherExecutable' $ServerLauncherExecutable } else { $ResolvedServer }
$ResolvedClient = Resolve-Executable 'ClientExecutable' $ClientExecutable
$ResolvedLogs = Initialize-EmptyLogRoot $LogRoot
$ActualServerSha256 = if ($EvidenceMode -ceq 'packaged') {
	if ($ServerLauncherExecutable) {
		$IdentityCommand = Invoke-HiddenCommand `
			$ResolvedServerLauncher `
			(Expand-ServerControlArguments $ServerIdentityArguments $ResolvedServer) `
			(Join-Path $ResolvedLogs 'server.identity.stdout.log') `
			(Join-Path $ResolvedLogs 'server.identity.stderr.log') `
			'server executable identity probe'
		$IdentityMatches = @([regex]::Matches($IdentityCommand.Output, '(?im)^(?<Sha256>[0-9a-f]{64})(?:\s+|\s+\*)'))
		if ($IdentityMatches.Count -ne 1) { throw 'Server identity probe must emit exactly one SHA-256 record.' }
		$IdentityMatches[0].Groups['Sha256'].Value.ToLowerInvariant()
	} else {
		(Get-FileHash -LiteralPath $ResolvedServer -Algorithm SHA256).Hash.ToLowerInvariant()
	}
} else { $null }
$PackagedProvenance = if ($EvidenceMode -ceq 'packaged') { Test-PackagedBuildProvenance $PackagedBuildProvenancePath $ActualServerSha256 } else { $null }
$EvidencePath = Join-Path $ResolvedLogs 'network-authority-spike-evidence.json'
$Processes = [System.Collections.Generic.List[object]]::new()
$Lifecycle = [System.Collections.Generic.List[object]]::new()
$Observations = [System.Collections.Generic.List[object]]::new()
$Rejections = [System.Collections.Generic.List[object]]::new()
$Clients = [System.Collections.Generic.List[object]]::new()
$Result = 'failed'
$Failure = $null
$CleanupFailure = $null
$PostCaptureValidationFailure = $null
$ServerDescendantProcessId = $null
$ObservationCompleted = $false

try {
	$ServerStdOut = Join-Path $ResolvedLogs 'server.stdout.log'
	$ServerStdErr = Join-Path $ResolvedLogs 'server.stderr.log'
	$ExpandedServerArguments = Expand-Arguments $ServerArguments 'server'
	$ServerProcessArguments = if ($ServerLauncherExecutable) { Expand-ServerLauncherArguments $ServerLauncherArguments $ResolvedServer $ExpandedServerArguments } else { $ExpandedServerArguments }
	$ServerHandle = Start-HiddenProcess $ResolvedServerLauncher $ServerProcessArguments $ServerStdOut $ServerStdErr
	$Processes.Add($ServerHandle)
	$ServerProcess = $ServerHandle.Process
	if ($ServerLauncherExecutable) {
		$ProcessIdLine = Wait-ForMatch $ServerProcess $ServerStdOut $ServerStdErr 'server descendant process identity' $ServerProcessIdPattern
		$ProcessIdMatch = $ServerProcessIdRegex.Match($ProcessIdLine)
		$ServerDescendantProcessId = $ProcessIdMatch.Groups['ProcessId'].Value
		if ($ServerDescendantProcessId -notmatch '^[1-9][0-9]*$') { throw 'Server launcher emitted an invalid descendant process identity.' }
	}
	$ReadyLine = Wait-ForMatch $ServerProcess $ServerStdOut $ServerStdErr 'server readiness' (Expand-Pattern $ServerReadyPattern 'server')
	$Lifecycle.Add((New-Observation 'server_ready' $ServerStdOut $ReadyLine))
	$NetworkConfigLine = Wait-ForMatch $ServerProcess $ServerStdOut $ServerStdErr 'network emulation configuration confirmation' (Expand-Pattern $NetworkConfigPattern 'server')
	$Lifecycle.Add((New-Observation 'network_config_confirmed' $ServerStdOut $NetworkConfigLine))

	$ClientProcesses = @{}
	foreach ($ClientId in @('client-1','client-2')) {
		$StdOut = Join-Path $ResolvedLogs "$ClientId.stdout.log"
		$StdErr = Join-Path $ResolvedLogs "$ClientId.stderr.log"
		$Handle = Start-HiddenProcess $ResolvedClient (Expand-Arguments $ClientArguments $ClientId) $StdOut $StdErr
		$Processes.Add($Handle)
		$ClientProcesses[$ClientId] = $Handle.Process
		$Clients.Add([pscustomobject]@{ id = $ClientId; role = 'initial_client' })
	}

	foreach ($ClientId in @('client-1','client-2')) {
		$StdOut = Join-Path $ResolvedLogs "$ClientId.stdout.log"
		$StdErr = Join-Path $ResolvedLogs "$ClientId.stderr.log"
		$Line = Wait-ForMatch $ClientProcesses[$ClientId] $StdOut $StdErr "$ClientId readiness" (Expand-Pattern $ClientReadyPattern $ClientId)
		$Lifecycle.Add((New-Observation 'client_ready' $StdOut $Line $ClientId))
		$MovementLine = Wait-ForMatch $ServerProcess $ServerStdOut $ServerStdErr "$ClientId movement" (Expand-Pattern $MovementPattern $ClientId)
		$Observations.Add((New-Observation 'movement' $ServerStdOut $MovementLine $ClientId))
	}

	$ServerLines = @(Get-Content -LiteralPath $ServerStdOut -ErrorAction SilentlyContinue)
	$Connections = @{}
	foreach ($Line in $ServerLines) {
		$Match = $ConnectionRegex.Match($Line)
		if ($Match.Success) { $Connections[$Match.Groups['ClientId'].Value] = $Match.Groups['ConnectionId'].Value }
	}
	if (@($Connections.Keys | Where-Object { $_ -in @('client-1','client-2') }).Count -ne 2) { throw 'Server did not expose distinct connection identities for both initial clients.' }

	$EnemyLine = Wait-ForMatch $ServerProcess $ServerStdOut $ServerStdErr 'authoritative enemy spawn' (Expand-Pattern $EnemyPattern 'server')
	$Observations.Add((New-Observation 'enemy_spawned' $ServerStdOut $EnemyLine))
	$MeleeLine = Wait-ForMatch $ServerProcess $ServerStdOut $ServerStdErr 'server-resolved melee' (Expand-Pattern $MeleePattern 'server')
	$Observations.Add((New-Observation 'melee_resolved' $ServerStdOut $MeleeLine))
	$DamageLine = Wait-ForMatch $ServerProcess $ServerStdOut $ServerStdErr 'authoritative damage' (Expand-Pattern $DamagePattern 'server')
	$Observations.Add((New-Observation 'damage_applied' $ServerStdOut $DamageLine))
	$JoinLine = Wait-ForMatch $ClientProcesses['client-2'] (Join-Path $ResolvedLogs 'client-2.stdout.log') (Join-Path $ResolvedLogs 'client-2.stderr.log') 'join-in-progress state' (Expand-Pattern $JoinInProgressPattern 'client-2')
	$Lifecycle.Add((New-Observation 'join_in_progress' (Join-Path $ResolvedLogs 'client-2.stdout.log') $JoinLine 'client-2'))
	foreach ($Category in $RequiredRejectionCategories.Keys) {
		$Observed = Wait-ForRejection $ServerProcess $ServerStdOut $ServerStdErr $RejectionRegex $Category
		$Reason = $Observed.Match.Groups['Reason'].Value
		$ClientId = $Observed.Match.Groups['ClientId'].Value
		if ($Reason -cnotin $StableRejectionReasons) { throw "Unsupported rejection reason '$Reason'." }
		if ($Reason -cne $RequiredRejectionCategories[$Category]) { throw "Rejection category '$Category' used '$Reason' instead of '$($RequiredRejectionCategories[$Category])'." }
		if ($ClientId -cne 'client-2') { throw "Rejection category '$Category' must be correlated to client-2, not '$ClientId'." }
		$Rejections.Add([pscustomobject]@{ category = $Category; reason = $Reason; client_id = $ClientId; source = $ServerStdOut; detail = $Observed.Line })
	}

	Stop-Process -Id $ClientProcesses['client-1'].Id -Force
	$ClientProcesses['client-1'].WaitForExit()
	$DisconnectLine = Wait-ForMatch $ServerProcess $ServerStdOut $ServerStdErr 'disconnect cleanup' (Expand-Pattern $DisconnectPattern 'client-1')
	$Lifecycle.Add((New-Observation 'disconnect' $ServerStdOut $DisconnectLine 'client-1'))

	$ReconnectId = 'client-1-reconnect'
	$ReconnectStdOut = Join-Path $ResolvedLogs "$ReconnectId.stdout.log"
	$ReconnectStdErr = Join-Path $ResolvedLogs "$ReconnectId.stderr.log"
	$ReconnectHandle = Start-HiddenProcess $ResolvedClient (Expand-Arguments $ClientArguments $ReconnectId) $ReconnectStdOut $ReconnectStdErr
	$Processes.Add($ReconnectHandle)
	$ReconnectProcess = $ReconnectHandle.Process
	$Clients.Add([pscustomobject]@{ id = $ReconnectId; role = 'reconnect_client' })
	[void] (Wait-ForMatch $ReconnectProcess $ReconnectStdOut $ReconnectStdErr 'reconnect client readiness' (Expand-Pattern $ClientReadyPattern $ReconnectId))
	$ReconnectLine = Wait-ForMatch $ServerProcess $ServerStdOut $ServerStdErr 'new reconnect identity' (Expand-Pattern $ReconnectPattern $ReconnectId)
	$ReconnectMatch = $ReconnectRegex.Match($ReconnectLine)
	if ($ReconnectMatch.Groups['ConnectionId'].Value -eq $Connections['client-1']) { throw 'Reconnect reused the disconnected connection identity.' }
	$Lifecycle.Add([pscustomobject]@{ event = 'reconnect'; client_id = $ReconnectId; connection_id = $ReconnectMatch.Groups['ConnectionId'].Value; source = $ServerStdOut; detail = $ReconnectLine })

	$ServerLines = @(Get-Content -LiteralPath $ServerStdOut -ErrorAction Stop)
	$ReadyIndex = Get-SingleMatchIndex $ServerLines (Expand-Pattern $ServerReadyPattern 'server') 'server-ready'
	$NetworkConfigIndex = Get-SingleMatchIndex $ServerLines (Expand-Pattern $NetworkConfigPattern 'server') 'network-config'
	[void] (Get-SingleMatchIndex $ServerLines (Expand-Pattern $EnemyPattern 'server') 'enemy-spawn')
	$MeleeIndex = Get-SingleMatchIndex $ServerLines (Expand-Pattern $MeleePattern 'server') 'melee-resolution'
	$DamageIndex = Get-SingleMatchIndex $ServerLines (Expand-Pattern $DamagePattern 'server') 'damage-application'
	$DisconnectIndex = Get-SingleMatchIndex $ServerLines (Expand-Pattern $DisconnectPattern 'client-1') 'disconnect'
	$ReconnectIndex = Get-SingleMatchIndex $ServerLines (Expand-Pattern $ReconnectPattern 'client-1-reconnect') 'reconnect'
	$MovementIndexes = @{}
	foreach ($ClientId in @('client-1','client-2')) { $MovementIndexes[$ClientId] = Get-SingleMatchIndex $ServerLines (Expand-Pattern $MovementPattern $ClientId) "$ClientId movement" }
	$ConnectionIndexes = @{}
	for ($Index = 0; $Index -lt $ServerLines.Count; $Index++) {
		$Match = $ConnectionRegex.Match($ServerLines[$Index])
		if ($Match.Success) {
			$ClientId = $Match.Groups['ClientId'].Value
			if ($ConnectionIndexes.ContainsKey($ClientId)) { throw "Observed duplicate connection record for '$ClientId'." }
			$ConnectionIndexes[$ClientId] = $Index
		}
	}
	foreach ($ClientId in @('client-1','client-2','client-1-reconnect')) { if (-not $ConnectionIndexes.ContainsKey($ClientId)) { throw "Missing connection record for '$ClientId'." } }
	if ($ConnectionIndexes.Count -ne 3) { throw "Expected exactly three correlated connection records, observed $($ConnectionIndexes.Count)." }

	$RejectionIndexes = @{}
	foreach ($Category in $RequiredRejectionCategories.Keys) {
		$CategoryIndexes = [System.Collections.Generic.List[int]]::new()
		for ($Index = 0; $Index -lt $ServerLines.Count; $Index++) {
			$Match = $RejectionRegex.Match($ServerLines[$Index])
			if ($Match.Success -and $Match.Groups['Category'].Value -ceq $Category) { $CategoryIndexes.Add($Index) }
		}
		if ($CategoryIndexes.Count -ne 1) { throw "Expected exactly one '$Category' rejection, observed $($CategoryIndexes.Count)." }
		$RejectionIndexes[$Category] = $CategoryIndexes[0]
	}
	$ServerErrorLines = @(Get-Content -LiteralPath $ServerStdErr -ErrorAction Stop)
	Assert-ExactRejectionInventory @($ServerLines + $ServerErrorLines) $RejectionRegex $RequiredRejectionCategories
	foreach ($ClientId in @('client-1','client-2','client-1-reconnect')) {
		$ClientLines = @(Get-Content -LiteralPath (Join-Path $ResolvedLogs "$ClientId.stdout.log") -ErrorAction Stop)
		[void] (Get-SingleMatchIndex $ClientLines (Expand-Pattern $ClientReadyPattern $ClientId) "$ClientId ready")
		if ($ClientId -eq 'client-2') { [void] (Get-SingleMatchIndex $ClientLines (Expand-Pattern $JoinInProgressPattern $ClientId) 'client-2 join-in-progress') }
	}
	$GameplayOrderInvalid = $ReadyIndex -ge $NetworkConfigIndex -or
		$ReadyIndex -ge $ConnectionIndexes['client-1'] -or
		$ReadyIndex -ge $ConnectionIndexes['client-2'] -or
		$ConnectionIndexes['client-1'] -ge $MovementIndexes['client-1'] -or
		$ConnectionIndexes['client-2'] -ge $MovementIndexes['client-2'] -or
		$MovementIndexes['client-1'] -ge $MeleeIndex -or
		$MeleeIndex -ge $DamageIndex
	if ($GameplayOrderInvalid) {
		throw 'Authority observations were duplicated or reordered before authoritative damage.'
	}
	$GameplayRejectionIndexes = @($RequiredRejectionCategories.Keys | ForEach-Object { $RejectionIndexes[$_] })
	$FirstGameplayRejectionIndex = ($GameplayRejectionIndexes | Measure-Object -Minimum).Minimum
	$LastGameplayRejectionIndex = ($GameplayRejectionIndexes | Measure-Object -Maximum).Maximum
	$LifecycleOrderInvalid = $DamageIndex -ge $FirstGameplayRejectionIndex -or
		$LastGameplayRejectionIndex -ge $DisconnectIndex -or
		$DisconnectIndex -ge $ConnectionIndexes['client-1-reconnect'] -or
		$ConnectionIndexes['client-1-reconnect'] -ge $ReconnectIndex
	if ($LifecycleOrderInvalid) {
		throw 'Authority rejection, disconnect, and reconnect observations were reordered.'
	}

	Wait-ForObservationInterval @(
		[pscustomobject]@{ Name = 'server'; Process = $ServerProcess; StandardOutputPath = $ServerStdOut; StandardErrorPath = $ServerStdErr },
		[pscustomobject]@{ Name = 'client-2'; Process = $ClientProcesses['client-2']; StandardOutputPath = (Join-Path $ResolvedLogs 'client-2.stdout.log'); StandardErrorPath = (Join-Path $ResolvedLogs 'client-2.stderr.log') },
		[pscustomobject]@{ Name = $ReconnectId; Process = $ReconnectProcess; StandardOutputPath = $ReconnectStdOut; StandardErrorPath = $ReconnectStdErr }
	) $DurationSeconds
	$ObservationCompleted = $true
}
catch {
	$Failure = $_.Exception.Message
	throw
}
finally {
	if ($ServerLauncherExecutable -and $ServerDescendantProcessId) {
		try {
			[void] (Invoke-HiddenCommand `
				$ResolvedServerLauncher `
				(Expand-ServerControlArguments $ServerCleanupArguments $ResolvedServer $ServerDescendantProcessId) `
				(Join-Path $ResolvedLogs 'server.cleanup.stdout.log') `
				(Join-Path $ResolvedLogs 'server.cleanup.stderr.log') `
				"server descendant cleanup for process $ServerDescendantProcessId")
		}
		catch {
			$CleanupFailure = $_.Exception.Message
			$Result = 'failed'
			if (-not $Failure) { $Failure = $CleanupFailure }
		}
	}
	foreach ($Handle in $Processes) {
		$Process = $Handle.Process
		try {
			if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue }
			$Process.WaitForExit()
			try { $Process.CancelOutputRead() } catch { }
			try { $Process.CancelErrorRead() } catch { }
		} catch { }
		$Handle.Capture.Dispose()
		$Process.Dispose()
	}
	if ($ObservationCompleted -and -not $Failure -and -not $CleanupFailure) {
		try {
			$FinalServerLines = @(Get-Content -LiteralPath $ServerStdOut -ErrorAction Stop)
			$FinalServerErrorLines = @(Get-Content -LiteralPath $ServerStdErr -ErrorAction Stop)
			Assert-ExactRejectionInventory @($FinalServerLines + $FinalServerErrorLines) $RejectionRegex $RequiredRejectionCategories
			$Result = if ($EvidenceMode -ceq 'packaged') { 'packaged-candidate' } else { 'fixture-passed' }
		}
		catch {
			$PostCaptureValidationFailure = $_.Exception.Message
			$Failure = $PostCaptureValidationFailure
			$Result = 'failed'
		}
	}
	$Evidence = [ordered]@{
		schema_id = 'aetheln.network-authority-evidence'
		schema_version = 1
		run_id = $RunId
		evidence_mode = $EvidenceMode
		result = $Result
		failure = $Failure
		scenario = [ordered]@{ id = $ScenarioId; validation_mode = 'present_time'; action_family = 'melee'; map = $ServerMap; duration_seconds = $DurationSeconds; actor_mix = $ActorMixIdentity; seed = $RunId }
		provenance = [ordered]@{ source_revision = $SourceRevision; build = $BuildIdentity; toolchain = $ToolchainIdentity; hardware = $HardwareIdentity; topology = $TopologyIdentity; packaged_build_provenance = if ($PackagedProvenance) { [ordered]@{ path = $PackagedProvenance.Path; sha256 = $PackagedProvenance.Sha256 } } else { $null } }
		network_profile = [ordered]@{ schema_id = 'aetheln.network-profile'; schema_version = 1; id = $ProfileId; runtime_config_identity = $NetworkConfigIdentity; latency_ms = $null; jitter_ms = $null; loss_percent = $null; duplication_percent = $null; reorder_percent = $null; server_tick_hz = $null; history_ms = $null; bandwidth_limit_kbps = $null; capacity_players = $null }
		clients = @($Clients)
		lifecycle = @($Lifecycle)
		observations = @($Observations)
		rejections = @($Rejections)
		measurements = [ordered]@{
			server_game_thread_milliseconds = $null
			server_replication_cpu_milliseconds = $null
			client_memory_bytes = $null
			server_memory_bytes = $null
			bandwidth_per_connection_bits_per_second = $null
			aggregate_bandwidth_bits_per_second = $null
			correction_count = $null
			correction_magnitude_centimeters = $null
			relevant_actor_count = $null
			destruction_event_count = $null
			implementation_complexity = $null
			failure_behavior = $null
		}
		unsupported_capabilities = @('projectile','block','dodge','rewind')
	}
	$Evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
	if ($PostCaptureValidationFailure) { throw "Post-capture evidence validation failed: $PostCaptureValidationFailure" }
	if ($CleanupFailure) { throw "Server cleanup failed: $CleanupFailure" }
}

Write-Output "Network authority spike $Result. Evidence: '$EvidencePath'."
