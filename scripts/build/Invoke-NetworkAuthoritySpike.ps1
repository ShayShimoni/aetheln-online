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
	[string] $NetworkProfileCatalogPath,
	[string] $ScenarioContractPath,
	[string] $PerformanceContractPath,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
	[Parameter(Mandatory)] [ValidateSet('local', 'development')] [string] $Environment,
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
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $JoinInProgressPattern,
	[string] $DeathPattern,
	[string] $RespawnPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $DisconnectPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ReconnectPattern,
	[string] $ShutdownPattern,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $NetworkConfigPattern,
	[ValidateNotNullOrEmpty()] [string] $ErrorPattern = '(?i)(fatal error|network\s+failure|connection\s+failed|failed to load package)',
	[ValidateRange(1, 3600)] [int] $TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PerformanceContractMaximumBytes = 1MB

# Compiled once at entry so a malformed -ErrorPattern fails before any
# process starts. IgnoreCase reproduces the -match semantics this default
# pattern and its callers were written against.
$ErrorRegex = [regex]::new($ErrorPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

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

function Expand-Value([string] $Value, [string] $ClientId) {
	return $Value.Replace('{ClientId}', $ClientId).Replace('{ServerEndpoint}', $ServerEndpoint).Replace('{ServerMap}', $ServerMap).Replace('{ScenarioId}', $ScenarioId).Replace('{ProfileId}', $ProfileId).Replace('{NetworkConfigIdentity}', $NetworkConfigIdentity).Replace('{RunId}', $RunId).Replace('{Environment}', $Environment)
}

function Expand-Argument([string[]] $Arguments, [string] $ClientId) {
	$Expanded = [System.Collections.Generic.List[string]]::new()
	foreach ($Argument in $Arguments) {
		$Expanded.Add((Expand-Value $Argument $ClientId))
	}
	foreach ($IdentityArgument in @(
		"-AethelnSourceRevision=$SourceRevision",
		"-AethelnBuildIdentity=$BuildIdentity",
		"-AethelnToolchainIdentity=$ToolchainIdentity"
	)) {
		$Expanded.Add($IdentityArgument)
	}
	return @($Expanded)
}

function Expand-Pattern([string] $Pattern, [string] $ClientId) {
	return $Pattern.Replace('{ClientId}', [regex]::Escape($ClientId)).Replace('{ServerEndpoint}', [regex]::Escape($ServerEndpoint)).Replace('{ServerMap}', [regex]::Escape($ServerMap)).Replace('{ScenarioId}', [regex]::Escape($ScenarioId)).Replace('{ProfileId}', [regex]::Escape($ProfileId)).Replace('{NetworkConfigIdentity}', [regex]::Escape($NetworkConfigIdentity)).Replace('{RunId}', [regex]::Escape($RunId))
}

function Expand-ServerLauncherArgument([string[]] $Arguments, [string] $ResolvedServerExecutable, [string[]] $ExpandedServerArguments) {
	$Expanded = [System.Collections.Generic.List[string]]::new()
	foreach ($Argument in $Arguments) {
		if ($Argument -eq '{ServerArguments}') {
			foreach ($ServerArgument in $ExpandedServerArguments) { $Expanded.Add($ServerArgument) }
		} else {
			$Expanded.Add((Expand-Value $Argument 'server').Replace('{ServerExecutable}', $ResolvedServerExecutable))
		}
	}
	return @($Expanded)
}

function Expand-ServerControlArgument([string[]] $Arguments, [string] $ResolvedServerExecutable, [string] $ServerProcessId = '') {
	return @($Arguments | ForEach-Object {
		(Expand-Value $_ 'server').Replace('{ServerExecutable}', $ResolvedServerExecutable).Replace('{ServerProcessId}', $ServerProcessId)
	})
}

function ConvertTo-ProcessArgument([string] $Argument) {
	$Quoted = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
	$Quoted = [regex]::Replace($Quoted, '(\\+)$', '$1$1')
	return '"' + $Quoted + '"'
}

function Start-HiddenProcess {
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType([pscustomobject])]
	param(
		[string] $Executable,
		[string[]] $Arguments,
		[string] $StandardOutputPath,
		[string] $StandardErrorPath
	)
	# Decide before allocating: a declined launch prepares no command line,
	# creates no redirected capture files, starts no child, and returns no
	# handle a caller could mistake for a running process.
	if (-not $PSCmdlet.ShouldProcess($Executable, 'Start a hidden runtime process')) { return }
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
			$ErrorLine = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Where-Object { $ErrorRegex.IsMatch([string] $_) } | Select-Object -First 1
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

function Wait-ForSuccessfulProcessExit([System.Diagnostics.Process] $Process, [string] $Description) {
	if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
		throw "Timed out after $TimeoutSeconds seconds waiting for $Description."
	}
	$Process.WaitForExit()
	if ($Process.ExitCode -ne 0) {
		throw "$Description exited with code $($Process.ExitCode)."
	}
	return [int] $Process.ExitCode
}

function Invoke-HiddenCommand([string] $Executable, [string[]] $Arguments, [string] $StandardOutputPath, [string] $StandardErrorPath, [string] $Description) {
	$Handle = Start-HiddenProcess -Executable $Executable -Arguments $Arguments -StandardOutputPath $StandardOutputPath -StandardErrorPath $StandardErrorPath
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
		try { $Process.CancelOutputRead() } catch { Write-Verbose "Cancelling asynchronous standard-output capture failed during process cleanup: $($_.Exception.Message)" }
		try { $Process.CancelErrorRead() } catch { Write-Verbose "Cancelling asynchronous standard-error capture failed during process cleanup: $($_.Exception.Message)" }
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

function Assert-StructuredRejectionMatch(
	[System.Text.RegularExpressions.Match] $Match,
	[string] $ExpectedCategory,
	[string] $ExpectedReason,
	[string] $ExpectedConnectionId
) {
	if ($Match.Groups['SchemaId'].Value -cne 'aetheln.observability-event' -or [int] $Match.Groups['SchemaVersion'].Value -ne 1) {
		throw "Rejection '$ExpectedCategory' used an unsupported structured schema."
	}
	if ($Match.Groups['EnvelopeCategory'].Value -cne 'rejection' -or $Match.Groups['Category'].Value -cne $ExpectedCategory) {
		throw "Rejection '$ExpectedCategory' used an invalid envelope or subject category."
	}
	if ($Match.Groups['Reason'].Value -cne $ExpectedReason) { throw "Rejection '$ExpectedCategory' used unexpected reason '$($Match.Groups['Reason'].Value)'." }
	if ($Match.Groups['Flow'].Value -cne 'prototype-authority') { throw "Rejection '$ExpectedCategory' used an unexpected flow." }
	if ($Match.Groups['EventRunId'].Value -cne $RunId) { throw "Rejection '$ExpectedCategory' was not correlated to the requested run." }
	if ($Match.Groups['ConnectionId'].Value -cne $ExpectedConnectionId) { throw "Rejection '$ExpectedCategory' was not correlated to client-2's authority-owned connection pseudonym." }
	if ($Match.Groups['EventSourceRevision'].Value -cne $SourceRevision -or
		$Match.Groups['EventBuildIdentity'].Value -cne $BuildIdentity -or
		$Match.Groups['EventToolchainIdentity'].Value -cne $ToolchainIdentity -or
		$Match.Groups['EventProfileId'].Value -cne $ProfileId) {
		throw "Rejection '$ExpectedCategory' was not correlated to the requested build and network profile."
	}
	if ($Match.Groups['BuildConfiguration'].Value -cne 'Development' -or
		$Match.Groups['EngineRevision'].Value -in @('', 'unknown') -or
		$Match.Groups['InstanceId'].Value -in @('', 'unknown')) {
		throw "Rejection '$ExpectedCategory' omitted bounded runtime provenance."
	}
	[uint64] $Sequence = 0
	if (-not [uint64]::TryParse($Match.Groups['Sequence'].Value, [ref] $Sequence) -or $Sequence -eq 0) {
		throw "Rejection '$ExpectedCategory' omitted its nonzero authority sequence."
	}
	foreach ($BoundedField in @('EventRunId','ConnectionId','InstanceId','ActivationId','AbilityId','EventSourceRevision','EventBuildIdentity','BuildConfiguration','EngineRevision','EventToolchainIdentity','EventProfileId')) {
		if ($Match.Groups[$BoundedField].Value.Length -gt 96) { throw "Rejection '$ExpectedCategory' exceeded the bounded public-field contract." }
	}
	if ($Match.Value -match 'client-2') { throw "Rejection '$ExpectedCategory' exposed the raw scenario client identifier." }
}

function Assert-MetricEnvironmentInventory([string[]] $Lines, [regex] $Regex, [string] $ExpectedEnvironment) {
	$MetricCount = 0
	foreach ($Line in $Lines) {
		$Match = $Regex.Match($Line)
		if (-not $Match.Success) { continue }
		++$MetricCount
		if ($Match.Groups['Environment'].Value -cne $ExpectedEnvironment) {
			throw "Structured metric '$($Match.Groups['Metric'].Value)' used environment '$($Match.Groups['Environment'].Value)' instead of '$ExpectedEnvironment'."
		}
	}
	if ($MetricCount -eq 0) { throw 'No structured metric environment evidence was observed.' }
}

function Assert-ExactRejectionInventory([string[]] $Lines, [regex] $Regex, [System.Collections.IDictionary] $RequiredCategories, [string] $ExpectedConnectionId) {
	$ObservedCounts = @{}
	$ObservedTotal = 0
	foreach ($Line in $Lines) {
		if ($Line -match 'AUTHORITY rejection category=disconnected-command(?:\s|$)') {
			throw 'Unexpected disconnected-command rejection without a transported command-validation attempt.'
		}
		$Match = $Regex.Match($Line)
		if (-not $Match.Success) { continue }
		$Category = $Match.Groups['Category'].Value
		if (-not $RequiredCategories.Contains($Category)) {
			throw "Unexpected authority rejection category '$Category'."
		}
		Assert-StructuredRejectionMatch -Match $Match -ExpectedCategory $Category -ExpectedReason $RequiredCategories[$Category] -ExpectedConnectionId $ExpectedConnectionId
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

function ConvertTo-Observation([string] $EventName, [string] $Source, [string] $Detail, [string] $ClientId = '') {
	$EvidenceSource = if ($script:UseScenarioContract) {
		[System.IO.Path]::GetFileName($Source)
	} else {
		$Source
	}
	$EvidenceDetail = if ($script:UseScenarioContract) { $EventName } else { $Detail }
	$Record = [ordered]@{ event = $EventName; source = $EvidenceSource; detail = $EvidenceDetail }
	if ($ClientId) { $Record.client_id = $ClientId }
	return [pscustomobject] $Record
}

function ConvertTo-ScenarioStage(
	[int] $Ordinal,
	[string] $Stage,
	[string] $AuthoritativeResult,
	[string] $ProcessRole,
	[string] $Source,
	[string] $Detail,
	[string] $ClientId = '',
	[object] $SequenceId = $null
) {
	$Record = [ordered]@{
		ordinal = $Ordinal
		stage = $Stage
		source_revision = $SourceRevision
		build = $BuildIdentity
		scenario_id = $ScenarioId
		scenario_version = $ScenarioVersion
		profile_id = $ProfileId
		profile_version = $ProfileVersion
		process_role = $ProcessRole
		client_id = if ([string]::IsNullOrWhiteSpace($ClientId)) { $null } else { $ClientId }
		activation_id = $null
		sequence_id = $SequenceId
		authoritative_result = $AuthoritativeResult
		source = [System.IO.Path]::GetFileName($Source)
		detail = $AuthoritativeResult
	}
	return [pscustomobject] $Record
}

function Get-RequiredSequenceId([string] $Line, [regex] $Pattern, [string] $Description) {
	$Match = $Pattern.Match($Line)
	if (-not $Match.Success) { throw "$Description did not match its validated sequence pattern." }
	$SequenceText = $Match.Groups['Sequence'].Value
	$SequenceId = [long] 0
	if ($SequenceText -notmatch '^[1-9][0-9]*$' -or -not [long]::TryParse($SequenceText, [ref] $SequenceId)) {
		throw "$Description Sequence must be a positive 64-bit integer."
	}
	return $SequenceId
}

function ConvertTo-ProcessOutcome([string] $ProcessRole, [string] $TerminationState, [int] $ExitCode) {
	return [pscustomobject] [ordered]@{
		process_role = $ProcessRole
		client_id = if ($ProcessRole -in @('client-1','client-2','client-1-reconnect')) { $ProcessRole } else { $null }
		timed_out = $false
		exit_code = $ExitCode
		termination_state = $TerminationState
	}
}

function ConvertTo-FailureDetail(
	[string] $Message,
	[string] $PublishedReason,
	[string] $Stage,
	[string] $ProcessRole,
	[string] $ClientId,
	[bool] $CleanupWasAttempted,
	[object] $CleanupWasSuccessful,
	[string] $CleanupError
) {
	$ResolvedRole = $ProcessRole
	$ResolvedClientId = $ClientId
	$ExitCode = $null
	$RequiredProcessMatch = [regex]::Match($Message, "Required process '([^']+)' exited unexpectedly with code (-?[0-9]+)")
	$ProcessExitMatch = [regex]::Match($Message, 'Process exited with code (-?[0-9]+)')
	if ($RequiredProcessMatch.Success) {
		$ResolvedRole = $RequiredProcessMatch.Groups[1].Value
		$ExitCode = [int] $RequiredProcessMatch.Groups[2].Value
	} elseif ($ProcessExitMatch.Success) {
		$ExitCode = [int] $ProcessExitMatch.Groups[1].Value
	}
	if ($ResolvedRole -in @('client-1','client-2','client-1-reconnect')) { $ResolvedClientId = $ResolvedRole }
	$NormalizedClientId = if ([string]::IsNullOrWhiteSpace($ResolvedClientId)) { $null } else { $ResolvedClientId }
	return [ordered]@{
		source_revision = $SourceRevision
		build = $BuildIdentity
		scenario_id = $ScenarioId
		scenario_version = $ScenarioVersion
		profile_id = $ProfileId
		profile_version = $ProfileVersion
		process_role = $ResolvedRole
		client_id = $NormalizedClientId
		observed_stage = $Stage
		activation_id = $null
		sequence_id = $null
		authoritative_result = 'failed'
		failure_reason = $PublishedReason
		exit_code = $ExitCode
		timed_out = [bool] ($Message -match '(?i)timed out')
		cleanup_attempted = $CleanupWasAttempted
		cleanup_succeeded = $CleanupWasSuccessful
		cleanup_failure = $CleanupError
		raw_log_files = @('server.stdout.log','server.stderr.log','client-1.stdout.log','client-1.stderr.log','client-2.stdout.log','client-2.stderr.log','client-1-reconnect.stdout.log','client-1-reconnect.stderr.log')
	}
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

function Assert-JsonString([string] $Name, [object] $Value) {
	if ($Value -isnot [string]) { throw "$Name must be a JSON string." }
}

function Assert-ClosedProperty([object] $Value, [string[]] $Expected, [string] $Name) {
	if ($null -eq $Value -or $null -eq $Value.PSObject) { throw "$Name must be one JSON object." }
	$Actual = @($Value.PSObject.Properties.Name)
	if ($Actual.Count -ne $Expected.Count -or
		@($Actual | Where-Object { $Expected -cnotcontains $_ }).Count -ne 0 -or
		@($Expected | Where-Object { $Actual -cnotcontains $_ }).Count -ne 0) {
		throw "$Name has unsupported or missing fields."
	}
}

function Move-PastJsonWhitespace([string] $Json, [ref] $Index) {
	while ($Index.Value -lt $Json.Length -and [char]::IsWhiteSpace($Json[$Index.Value])) { $Index.Value++ }
}

function Read-JsonStringToken([string] $Json, [ref] $Index) {
	if ($Index.Value -ge $Json.Length -or $Json[$Index.Value] -cne '"') { throw 'Expected a JSON string.' }
	$Start = $Index.Value
	$Index.Value++
	while ($Index.Value -lt $Json.Length) {
		$Character = $Json[$Index.Value]
		if ($Character -ceq '"') {
			$Index.Value++
			$Token = $Json.Substring($Start, $Index.Value - $Start)
			return [string] ($Token | ConvertFrom-Json -ErrorAction Stop)
		}
		if ($Character -ceq '\') {
			$Index.Value++
			if ($Index.Value -ge $Json.Length) { throw 'JSON string has an incomplete escape sequence.' }
			if ($Json[$Index.Value] -ceq 'u') {
				if ($Index.Value + 4 -ge $Json.Length) { throw 'JSON string has an incomplete Unicode escape sequence.' }
				$Index.Value += 4
			}
		}
		$Index.Value++
	}
	throw 'JSON string is not terminated.'
}

function Assert-NoDuplicateJsonPropertiesValue([string] $Json, [ref] $Index) {
	Move-PastJsonWhitespace $Json $Index
	if ($Index.Value -ge $Json.Length) { throw 'Expected a JSON value.' }
	if ($Json[$Index.Value] -ceq '{') {
		$Index.Value++
		$Keys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
		Move-PastJsonWhitespace $Json $Index
		if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -ceq '}') { $Index.Value++; return }
		while ($true) {
			Move-PastJsonWhitespace $Json $Index
			$Key = Read-JsonStringToken $Json $Index
			if (-not $Keys.Add($Key)) { throw "Duplicate JSON property '$Key' is not allowed." }
			Move-PastJsonWhitespace $Json $Index
			if ($Index.Value -ge $Json.Length -or $Json[$Index.Value] -cne ':') { throw "Expected ':' after a JSON property name." }
			$Index.Value++
			Assert-NoDuplicateJsonPropertiesValue $Json $Index
			Move-PastJsonWhitespace $Json $Index
			if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -ceq '}') { $Index.Value++; return }
			if ($Index.Value -ge $Json.Length -or $Json[$Index.Value] -cne ',') { throw "Expected ',' or '}' after a JSON property value." }
			$Index.Value++
		}
	}
	if ($Json[$Index.Value] -ceq '[') {
		$Index.Value++
		Move-PastJsonWhitespace $Json $Index
		if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -ceq ']') { $Index.Value++; return }
		while ($true) {
			Assert-NoDuplicateJsonPropertiesValue $Json $Index
			Move-PastJsonWhitespace $Json $Index
			if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -ceq ']') { $Index.Value++; return }
			if ($Index.Value -ge $Json.Length -or $Json[$Index.Value] -cne ',') { throw "Expected ',' or ']' after a JSON array value." }
			$Index.Value++
		}
	}
	if ($Json[$Index.Value] -ceq '"') {
		[void] (Read-JsonStringToken $Json $Index)
		return
	}
	$Start = $Index.Value
	while ($Index.Value -lt $Json.Length -and -not [char]::IsWhiteSpace($Json[$Index.Value]) -and $Json[$Index.Value] -cnotin @(',',']','}')) { $Index.Value++ }
	if ($Index.Value -eq $Start) { throw 'Expected a JSON value.' }
}

function Assert-NoDuplicateJsonProperty([string] $Json) {
	$Index = 0
	Assert-NoDuplicateJsonPropertiesValue $Json ([ref] $Index)
	Move-PastJsonWhitespace $Json ([ref] $Index)
	if ($Index -ne $Json.Length) { throw 'Unexpected content after the JSON value.' }
}

function Read-ContractJson([string] $Name, [string] $Path) {
	if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Name path is required." }
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Name '$Path' does not exist or is not a file." }
	try {
		$Json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
		Assert-NoDuplicateJsonProperty $Json
		return $Json | ConvertFrom-Json -ErrorAction Stop
	}
	catch {
		throw "$Name is not valid JSON: $($_.Exception.Message)"
	}
}

function Read-ExactContractJsonRecord([string] $Name, [string] $Path) {
	if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Name path is required." }
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Name '$Path' does not exist or is not a file." }
	$Stream = $null
	$MemoryStream = $null
	$Reader = $null
	$Hasher = $null
	try {
		$ResolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
		$Stream = [System.IO.File]::Open(
			$ResolvedPath,
			[System.IO.FileMode]::Open,
			[System.IO.FileAccess]::Read,
			[System.IO.FileShare]::Read)
		if ($Stream.Length -gt $script:PerformanceContractMaximumBytes) {
			throw "$Name exceeds the $($script:PerformanceContractMaximumBytes)-byte input limit."
		}
		$Bytes = [byte[]]::new([int] $Stream.Length)
		$Offset = 0
		while ($Offset -lt $Bytes.Length) {
			$ReadCount = $Stream.Read($Bytes, $Offset, $Bytes.Length - $Offset)
			if ($ReadCount -le 0) { throw "$Name could not be read completely." }
			$Offset += $ReadCount
		}
		$MemoryStream = [System.IO.MemoryStream]::new($Bytes, $false)
		$StrictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
		$Reader = [System.IO.StreamReader]::new($MemoryStream, $StrictUtf8, $true, 1024, $false)
		$Json = $Reader.ReadToEnd()
		Assert-NoDuplicateJsonProperty -Json $Json
		$Value = $Json | ConvertFrom-Json -ErrorAction Stop
		$Hasher = [System.Security.Cryptography.SHA256]::Create()
		$Sha256 = [System.BitConverter]::ToString($Hasher.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant()
		return [pscustomobject]@{ Value = $Value; Bytes = $Bytes; Sha256 = $Sha256 }
	}
	catch {
		throw "$Name is not valid JSON: $($_.Exception.Message)"
	}
	finally {
		if ($null -ne $Hasher) { $Hasher.Dispose() }
		if ($null -ne $Reader) { $Reader.Dispose() }
		if ($null -ne $MemoryStream) { $MemoryStream.Dispose() }
		if ($null -ne $Stream) { $Stream.Dispose() }
	}
}

function Assert-OpaqueArgument([string] $Name, [object] $Value) {
	if ($null -eq $Value -or $Value -is [string] -or $Value -isnot [System.Collections.IEnumerable]) {
		throw "$Name must be a JSON array of argument strings."
	}
	if (@($Value).Count -eq 0) {
		throw "$Name must contain at least one non-empty opaque argument string."
	}
	foreach ($Argument in @($Value)) {
		if ($Argument -isnot [string] -or [string]::IsNullOrWhiteSpace([string] $Argument) -or
			[string] $Argument -match '[\r\n\x00]') {
			throw "$Name must contain only non-empty argument strings without control characters."
		}
	}
}

function Get-Sha256Text([string] $Text) {
	$Hasher = [System.Security.Cryptography.SHA256]::Create()
	try {
		$Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
		return [System.BitConverter]::ToString($Hasher.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant()
	}
	finally {
		$Hasher.Dispose()
	}
}

function Resolve-NetworkProfileCatalog([string] $Path) {
	$Catalog = Read-ContractJson 'NetworkProfileCatalog' $Path
	Assert-ClosedProperty -Value $Catalog -Expected @('schema_id','schema_version','selected_profile_id','profiles') -Name 'NetworkProfileCatalog'
	if ($Catalog.schema_id -cne 'aetheln.network-profile-catalog' -or [long] $Catalog.schema_version -ne 1) {
		throw 'NetworkProfileCatalog must use aetheln.network-profile-catalog schema version 1.'
	}
	Assert-RecordToken 'NetworkProfileCatalog selected_profile_id' ([string] $Catalog.selected_profile_id)
	$Profiles = @($Catalog.profiles)
	$RequiredKinds = @('clean','representative','harsh','loss','duplication','reordering')
	if ($Profiles.Count -ne $RequiredKinds.Count) {
		throw 'NetworkProfileCatalog must contain exactly one profile for every required profile kind.'
	}
	$Ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
	$Kinds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
	foreach ($ProfileRecord in $Profiles) {
		Assert-ClosedProperty -Value $ProfileRecord -Expected @('id','version','kind','runtime_config_identity','server_arguments','client_arguments') -Name 'NetworkProfileCatalog profile'
		Assert-RecordToken 'Network profile id' ([string] $ProfileRecord.id)
		Assert-RecordToken 'Network profile version' ([string] $ProfileRecord.version)
		Assert-RecordToken 'Network profile runtime_config_identity' ([string] $ProfileRecord.runtime_config_identity)
		if ([string] $ProfileRecord.kind -cnotin $RequiredKinds) { throw "Unsupported network profile kind '$($ProfileRecord.kind)'." }
		if (-not $Ids.Add([string] $ProfileRecord.id)) { throw "Duplicate network profile id '$($ProfileRecord.id)'." }
		if (-not $Kinds.Add([string] $ProfileRecord.kind)) { throw "Duplicate network profile kind '$($ProfileRecord.kind)'." }
		$ExpectedProfileId = "network-profile.$($ProfileRecord.kind)"
		if ([string] $ProfileRecord.id -cne $ExpectedProfileId) {
			throw "Network profile kind '$($ProfileRecord.kind)' must use exact id '$ExpectedProfileId'."
		}
		Assert-OpaqueArgument 'Network profile server_arguments' $ProfileRecord.server_arguments
		Assert-OpaqueArgument 'Network profile client_arguments' $ProfileRecord.client_arguments
	}
	if (@($RequiredKinds | Where-Object { -not $Kinds.Contains($_) }).Count -ne 0) {
		throw 'NetworkProfileCatalog is missing one or more required profile kinds.'
	}
	$Selected = @($Profiles | Where-Object { [string] $_.id -ceq [string] $Catalog.selected_profile_id })
	if ($Selected.Count -ne 1) { throw 'NetworkProfileCatalog must select exactly one declared profile.' }
	if ([string] $Selected[0].id -cne $ProfileId) { throw 'ProfileId must equal the explicitly selected network profile id.' }
	if ([string] $Selected[0].runtime_config_identity -cne $NetworkConfigIdentity) {
		throw 'NetworkConfigIdentity must equal the selected network profile runtime configuration identity.'
	}
	return $Selected[0]
}

function Resolve-ScenarioContract([string] $Path) {
	$Contract = Read-ContractJson 'ScenarioContract' $Path
	Assert-ClosedProperty -Value $Contract -Expected @('schema_id','schema_version','id','version','lifecycle_stages') -Name 'ScenarioContract'
	if ($Contract.schema_id -cne 'aetheln.network-authority-scenario' -or [long] $Contract.schema_version -ne 1) {
		throw 'ScenarioContract must use aetheln.network-authority-scenario schema version 1.'
	}
	Assert-RecordToken 'Scenario contract id' ([string] $Contract.id)
	Assert-RecordToken 'Scenario contract version' ([string] $Contract.version)
	if ([string] $Contract.id -cne $ScenarioId) { throw 'ScenarioContract id must equal ScenarioId.' }
	$ExpectedStages = @('join','play','death','respawn','disconnect','reconnect','shutdown')
	$Stages = @($Contract.lifecycle_stages)
	if ($Stages.Count -ne $ExpectedStages.Count) { throw 'ScenarioContract must declare exactly seven lifecycle stages.' }
	for ($Index = 0; $Index -lt $ExpectedStages.Count; $Index++) {
		if ([string] $Stages[$Index] -cne $ExpectedStages[$Index]) {
			throw 'ScenarioContract lifecycle stages must be ordered join, play, death, respawn, disconnect, reconnect, shutdown.'
		}
	}
	return $Contract
}

function Resolve-PerformanceContract([string] $Path) {
	$ContractRecord = Read-ExactContractJsonRecord -Name 'PerformanceContract' -Path $Path
	$Contract = $ContractRecord.Value
	Assert-ClosedProperty -Value $Contract -Expected @('schema_id','schema_version','capture','budgets') -Name 'PerformanceContract'
	Assert-JsonString -Name 'PerformanceContract schema_id' -Value $Contract.schema_id
	if (($Contract.schema_version -isnot [int] -and $Contract.schema_version -isnot [long]) -or [long] $Contract.schema_version -ne 1) {
		throw 'PerformanceContract schema_version must be the JSON integer 1.'
	}
	if ([string] $Contract.schema_id -cne 'aetheln.performance-capture-contract') {
		throw 'PerformanceContract must use aetheln.performance-capture-contract schema version 1.'
	}
	$Capture = $Contract.capture
	Assert-ClosedProperty -Value $Capture -Expected @('source_revision','build','toolchain','hardware','topology','environment','map','duration_seconds','actor_mix','scenario_id','profile_id','network_config_identity','scenario_version','profile_version','profile_arguments_sha256','evidence_references','measurement_domains','sampling') -Name 'PerformanceContract capture'
	foreach ($IdentityEntry in @(
		@('source_revision', $SourceRevision), @('build', $BuildIdentity), @('toolchain', $ToolchainIdentity),
		@('hardware', $HardwareIdentity), @('topology', $TopologyIdentity), @('environment', $Environment),
		@('map', $ServerMap), @('actor_mix', $ActorMixIdentity), @('scenario_id', $ScenarioId), @('profile_id', $ProfileId),
		@('network_config_identity', $NetworkConfigIdentity)
	)) {
		Assert-JsonString -Name "PerformanceContract capture '$($IdentityEntry[0])'" -Value $Capture.($IdentityEntry[0])
		if ([string] $Capture.($IdentityEntry[0]) -cne [string] $IdentityEntry[1]) {
			throw "PerformanceContract capture '$($IdentityEntry[0])' must equal the exact correlated runner identity."
		}
	}
	foreach ($VersionEntry in @(
		@('scenario_version', $ScenarioVersion),
		@('profile_version', $ProfileVersion),
		@('profile_arguments_sha256', $ProfileArgumentsSha256)
	)) {
		$FieldName = [string] $VersionEntry[0]
		$ExpectedValue = $VersionEntry[1]
		$ActualValue = $Capture.$FieldName
		if ($null -eq $ExpectedValue) {
			if ($null -ne $ActualValue) { throw "PerformanceContract capture '$FieldName' must be null when versioned scenario/profile contracts are omitted." }
		} else {
			Assert-JsonString -Name "PerformanceContract capture '$FieldName'" -Value $ActualValue
			if ([string] $ActualValue -cne [string] $ExpectedValue) {
				throw "PerformanceContract capture '$FieldName' must equal the exact selected scenario/profile identity."
			}
		}
	}
	if (($Capture.duration_seconds -isnot [int] -and $Capture.duration_seconds -isnot [long]) -or [long] $Capture.duration_seconds -ne $DurationSeconds) {
		throw 'PerformanceContract capture duration_seconds must equal the exact DurationSeconds identity.'
	}
	$ReferenceFailure = 'PerformanceContract capture evidence_references must be a non-empty array of unique record tokens.'
	$References = $Capture.evidence_references
	if ($null -eq $References -or $References -is [string] -or $References -isnot [System.Collections.IEnumerable]) { throw $ReferenceFailure }
	$ReferenceSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
	foreach ($Reference in @($References)) {
		if ($Reference -isnot [string] -or [string] $Reference -notmatch '^\S+$' -or -not $ReferenceSet.Add([string] $Reference)) { throw $ReferenceFailure }
	}
	if ($ReferenceSet.Count -eq 0) { throw $ReferenceFailure }
	$RequiredDomains = [ordered]@{
		client = @('client_memory_bytes','correction_count','correction_magnitude_centimeters')
		server = @('server_game_thread_milliseconds','server_replication_cpu_milliseconds','server_memory_bytes','relevant_actor_count','destruction_event_count')
		network = @('bandwidth_per_connection_bits_per_second','aggregate_bandwidth_bits_per_second')
	}
	Assert-ClosedProperty -Value $Capture.measurement_domains -Expected @('client','server','network') -Name 'PerformanceContract measurement_domains'
	foreach ($DomainName in $RequiredDomains.Keys) {
		$DeclaredMetrics = @($Capture.measurement_domains.$DomainName)
		$ExpectedMetrics = @($RequiredDomains[$DomainName])
		$DomainFailure = "PerformanceContract measurement_domains '$DomainName' must declare exactly the version-1 network-authority-runner ordered metrics."
		if ($DeclaredMetrics.Count -ne $ExpectedMetrics.Count) { throw $DomainFailure }
		for ($Index = 0; $Index -lt $ExpectedMetrics.Count; $Index++) {
			if ($DeclaredMetrics[$Index] -isnot [string] -or [string] $DeclaredMetrics[$Index] -cne $ExpectedMetrics[$Index]) { throw $DomainFailure }
		}
	}
	Assert-ClosedProperty -Value $Capture.sampling -Expected @('sampling_rate_hz','server_tick_hz','bandwidth_limit_kbps','capacity_players') -Name 'PerformanceContract sampling'
	foreach ($SamplingField in @('sampling_rate_hz','server_tick_hz','bandwidth_limit_kbps','capacity_players')) {
		if ($null -ne $Capture.sampling.$SamplingField) { throw "PerformanceContract sampling '$SamplingField' must remain null in this wave." }
	}
	$MetricDomains = @{}
	foreach ($DomainName in $RequiredDomains.Keys) {
		foreach ($MetricId in $RequiredDomains[$DomainName]) { $MetricDomains[$MetricId] = $DomainName }
	}
	$Budgets = $Contract.budgets
	if ($null -eq $Budgets -or $Budgets -is [string] -or $Budgets -isnot [System.Collections.IEnumerable]) {
		throw 'PerformanceContract budgets must be a JSON array of budget records.'
	}
	$ClassificationCounts = [ordered]@{ measured = 0; modeled = 0; hypothetical = 0; unset = 0 }
	$BudgetCounts = @{}
	foreach ($Budget in @($Budgets)) {
		Assert-ClosedProperty -Value $Budget -Expected @('metric_id','domain','target','warning_threshold','failure_threshold','measurement_method','scenario_id','owner','evidence_references','evidence_classification','approval_status') -Name 'Performance budget'
		Assert-JsonString -Name 'Performance budget metric_id' -Value $Budget.metric_id
		$MetricId = [string] $Budget.metric_id
		if (-not $MetricDomains.ContainsKey($MetricId)) { throw "Unsupported performance budget metric '$MetricId'." }
		Assert-JsonString -Name "Performance budget '$MetricId' domain" -Value $Budget.domain
		if ([string] $Budget.domain -cne $MetricDomains[$MetricId]) { throw "Performance budget '$MetricId' domain must be '$($MetricDomains[$MetricId])'." }
		foreach ($ValueField in @('target','warning_threshold','failure_threshold')) {
			if ($null -ne $Budget.$ValueField) { throw "Performance budget '$MetricId' $ValueField must remain null in this wave; populated values require measurement authority." }
		}
		Assert-JsonString -Name "Performance budget '$MetricId' measurement_method" -Value $Budget.measurement_method
		Assert-RecordToken -Name "Performance budget '$MetricId' measurement_method" -Value ([string] $Budget.measurement_method)
		Assert-JsonString -Name "Performance budget '$MetricId' scenario_id" -Value $Budget.scenario_id
		if ([string] $Budget.scenario_id -cne $ScenarioId) { throw "Performance budget '$MetricId' scenario_id must equal ScenarioId." }
		Assert-JsonString -Name "Performance budget '$MetricId' owner" -Value $Budget.owner
		Assert-RecordToken -Name "Performance budget '$MetricId' owner" -Value ([string] $Budget.owner)
		Assert-JsonString -Name "Performance budget '$MetricId' evidence_classification" -Value $Budget.evidence_classification
		$Classification = [string] $Budget.evidence_classification
		if ($Classification -cnotin @('measured','modeled','hypothetical','unset')) {
			throw "Performance budget '$MetricId' evidence_classification must be measured, modeled, hypothetical, or unset."
		}
		Assert-JsonString -Name "Performance budget '$MetricId' approval_status" -Value $Budget.approval_status
		if ([string] $Budget.approval_status -cne 'unapproved') {
			throw "Performance budget '$MetricId' must remain 'unapproved'; contracts cannot self-approve budgets."
		}
		$BudgetReferences = $Budget.evidence_references
		if ($null -eq $BudgetReferences -or $BudgetReferences -is [string] -or $BudgetReferences -isnot [System.Collections.IEnumerable]) {
			throw "Performance budget '$MetricId' evidence_references must be a JSON array."
		}
		$BudgetReferenceValues = @($BudgetReferences)
		if ($Classification -ceq 'unset') {
			if ($BudgetReferenceValues.Count -ne 0) { throw "Performance budget '$MetricId' with unset classification must declare no evidence references." }
		} else {
			if ($BudgetReferenceValues.Count -eq 0) { throw "Performance budget '$MetricId' must reference only declared capture evidence references." }
			foreach ($Reference in $BudgetReferenceValues) {
				if ($Reference -isnot [string] -or -not $ReferenceSet.Contains([string] $Reference)) {
					throw "Performance budget '$MetricId' must reference only declared capture evidence references."
				}
			}
		}
		$ClassificationCounts[$Classification] = 1 + [int] $ClassificationCounts[$Classification]
		$BudgetCounts[$MetricId] = 1 + [int] $BudgetCounts[$MetricId]
	}
	foreach ($MetricId in $MetricDomains.Keys) {
		if ([int] $BudgetCounts[$MetricId] -ne 1) { throw 'PerformanceContract budgets must declare exactly one budget for every canonical metric.' }
	}
	return [pscustomobject]@{
		Summary = [ordered]@{
			schema_id = 'aetheln.performance-capture-contract'
			schema_version = 1
			contract_sha256 = $ContractRecord.Sha256
			contract_artifact = 'performance-contract.json'
			measurement_domains = [ordered]@{ client = @($RequiredDomains.client); server = @($RequiredDomains.server); network = @($RequiredDomains.network) }
			budget_count = @($Budgets).Count
			targets_defined = $false
			approval_status = 'unapproved'
			evidence_reference_count = $ReferenceSet.Count
			classification_counts = $ClassificationCounts
		}
		Bytes = $ContractRecord.Bytes
	}
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
	Assert-NoProvenanceReparsePoint -Name 'Packaged provenance inventory path' -ArchiveRoot $ArchiveRoot -ResolvedPath $ResolvedPath -AllowMissing
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
	Assert-NoProvenanceReparsePoint -Name $Name -ArchiveRoot $ArchiveRoot -ResolvedPath $ResolvedPath
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
	$ClientBinding = Resolve-ProvenanceExecutable -Name 'ClientExecutable' -Path $ResolvedClient -ArchiveName 'clientArchive' -ArchiveRoot $ClientArchive
	$ServerBinding = Resolve-ProvenanceExecutable -Name 'ServerProvenanceExecutable' -Path $ServerHostExecutable -ArchiveName 'serverArchive' -ArchiveRoot $ServerArchive
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

$ProfileCatalogSupplied = -not [string]::IsNullOrWhiteSpace($NetworkProfileCatalogPath)
$ScenarioContractSupplied = -not [string]::IsNullOrWhiteSpace($ScenarioContractPath)
if ($ProfileCatalogSupplied -ne $ScenarioContractSupplied) {
	throw 'NetworkProfileCatalogPath and ScenarioContractPath must be supplied together.'
}
$script:UseScenarioContract = $ProfileCatalogSupplied -and $ScenarioContractSupplied
$ProfileServerArguments = @()
$ProfileClientArguments = @()
$SelectedNetworkProfile = $null
$ResolvedScenarioContract = $null
$ProfileVersion = $null
$ProfileKind = $null
$ScenarioVersion = $null
$ProfileArgumentsSha256 = $null
$ProfileServerArgumentCount = 0
$ProfileClientArgumentCount = 0
foreach ($Placeholder in @('{ServerEndpoint}','{ServerMap}','{ScenarioId}','{ProfileId}','{RunId}','{Environment}')) { Assert-Placeholder -Arguments $ServerArguments -Placeholder $Placeholder -Name 'ServerArguments' }
Assert-Placeholder -Arguments $ServerArguments -Placeholder '{NetworkConfigIdentity}' -Name 'ServerArguments'
foreach ($Placeholder in @('{ClientId}','{ServerEndpoint}','{ServerMap}','{ScenarioId}','{ProfileId}','{NetworkConfigIdentity}','{RunId}','{Environment}')) { Assert-Placeholder -Arguments $ClientArguments -Placeholder $Placeholder -Name 'ClientArguments' }
if ($script:UseScenarioContract) {
	$SelectedNetworkProfile = Resolve-NetworkProfileCatalog $NetworkProfileCatalogPath
	$ResolvedScenarioContract = Resolve-ScenarioContract $ScenarioContractPath
	foreach ($RequiredPattern in @(
		@('DeathPattern', $DeathPattern),
		@('RespawnPattern', $RespawnPattern),
		@('ShutdownPattern', $ShutdownPattern)
	)) {
		if ([string]::IsNullOrWhiteSpace([string] $RequiredPattern[1])) {
			throw "$($RequiredPattern[0]) is required when scenario/profile contracts are supplied."
		}
	}
	$ProfileVersion = [string] $SelectedNetworkProfile.version
	$ProfileKind = [string] $SelectedNetworkProfile.kind
	$ScenarioVersion = [string] $ResolvedScenarioContract.version
	$ProfileServerArguments = @($SelectedNetworkProfile.server_arguments)
	$ProfileClientArguments = @($SelectedNetworkProfile.client_arguments)
	$ProfileServerArgumentCount = $ProfileServerArguments.Count
	$ProfileClientArgumentCount = $ProfileClientArguments.Count
	$ProfileArgumentsJson = [ordered]@{
		server = $ProfileServerArguments
		client = $ProfileClientArguments
	} | ConvertTo-Json -Depth 4 -Compress
	$ProfileArgumentsSha256 = Get-Sha256Text $ProfileArgumentsJson
}
$script:PerformanceContractRecord = if ([string]::IsNullOrWhiteSpace($PerformanceContractPath)) { $null } else { Resolve-PerformanceContract -Path $PerformanceContractPath }

if ($EvidenceMode -ceq 'packaged' -and $Environment -cne 'development') { throw 'Packaged authority evidence must use the development environment.' }
if ($ServerLauncherExecutable) {
	Assert-Placeholder -Arguments $ServerLauncherArguments -Placeholder '{ServerExecutable}' -Name 'ServerLauncherArguments'
	Assert-Placeholder -Arguments $ServerLauncherArguments -Placeholder '{ServerArguments}' -Name 'ServerLauncherArguments'
	Assert-Placeholder -Arguments $ServerCleanupArguments -Placeholder '{ServerProcessId}' -Name 'ServerCleanupArguments'
	if (-not $ServerProcessIdPattern) { throw 'ServerProcessIdPattern is required when ServerLauncherExecutable is supplied.' }
	$ServerProcessIdRegex = [regex]::new($ServerProcessIdPattern)
	if ($ServerProcessIdRegex.GetGroupNames() -notcontains 'ProcessId') { throw 'ServerProcessIdPattern must contain a named ProcessId capture.' }
	if ($EvidenceMode -ceq 'packaged') {
		Assert-Placeholder -Arguments $ServerIdentityArguments -Placeholder '{ServerExecutable}' -Name 'ServerIdentityArguments'
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
	@('JoinInProgressPattern', $JoinInProgressPattern),
	@('DisconnectPattern', $DisconnectPattern), @('ReconnectPattern', $ReconnectPattern),
	@('NetworkConfigPattern', $NetworkConfigPattern)
)) {
	foreach ($IdentityPlaceholder in @('{ScenarioId}','{ProfileId}','{RunId}')) { Assert-Placeholder -Arguments @([string] $PatternEntry[1]) -Placeholder $IdentityPlaceholder -Name ([string] $PatternEntry[0]) }
}
if ($script:UseScenarioContract) {
	foreach ($PatternEntry in @(
		@('DeathPattern', $DeathPattern),
		@('RespawnPattern', $RespawnPattern),
		@('ShutdownPattern', $ShutdownPattern)
	)) {
		foreach ($IdentityPlaceholder in @('{ScenarioId}','{ProfileId}','{RunId}')) {
			Assert-Placeholder -Arguments @([string] $PatternEntry[1]) -Placeholder $IdentityPlaceholder -Name ([string] $PatternEntry[0])
		}
	}
	$JoinSequenceRegex = [regex]::new((Expand-Pattern $JoinInProgressPattern 'client-2'))
	$PlaySequenceRegex = [regex]::new((Expand-Pattern $DamagePattern 'server'))
	foreach ($SequencePattern in @(
		@('JoinInProgressPattern', $JoinSequenceRegex),
		@('DamagePattern', $PlaySequenceRegex)
	)) {
		if ($SequencePattern[1].GetGroupNames() -cnotcontains 'Sequence') {
			throw "$($SequencePattern[0]) must contain a named Sequence capture in scenario-contract mode."
		}
	}
}
foreach ($TokenEntry in @(
	@('ServerEndpoint', $ServerEndpoint), @('ServerMap', $ServerMap), @('ScenarioId', $ScenarioId),
	@('ProfileId', $ProfileId), @('NetworkConfigIdentity', $NetworkConfigIdentity), @('RunId', $RunId),
	@('Environment', $Environment),
	@('SourceRevision', $SourceRevision), @('BuildIdentity', $BuildIdentity), @('ToolchainIdentity', $ToolchainIdentity),
	@('HardwareIdentity', $HardwareIdentity), @('TopologyIdentity', $TopologyIdentity), @('ActorMixIdentity', $ActorMixIdentity)
)) { Assert-RecordToken ([string] $TokenEntry[0]) ([string] $TokenEntry[1]) }

$ConnectionRegex = [regex]::new((Expand-Pattern $ServerConnectionPattern ''))
if ($ConnectionRegex.GetGroupNames() -notcontains 'ClientId' -or $ConnectionRegex.GetGroupNames() -notcontains 'ConnectionId') { throw 'ServerConnectionPattern must contain named ClientId and ConnectionId captures.' }
$RejectionRegex = [regex]::new('LogAethelnObservability: event schema="(?<SchemaId>[^"]+)" version=(?<SchemaVersion>[0-9]+) category="(?<EnvelopeCategory>[^"]+)" subject="(?<Category>[^"]+)" reason="(?<Reason>[^"]+)" flow="(?<Flow>[^"]+)" run="(?<EventRunId>[^"]+)" connection="(?<ConnectionId>[^"]+)" instance="(?<InstanceId>[^"]+)" activation="(?<ActivationId>[^"]*)" ability="(?<AbilityId>[^"]*)" sequence=(?<Sequence>[0-9]+) source_revision="(?<EventSourceRevision>[^"]+)" build="(?<EventBuildIdentity>[^"]+)" configuration="(?<BuildConfiguration>[^"]+)" engine="(?<EngineRevision>[^"]+)" toolchain="(?<EventToolchainIdentity>[^"]+)" network_profile="(?<EventProfileId>[^"]+)"')
$MetricRegex = [regex]::new('LogAethelnObservability: metric name="(?<Metric>[^"]+)" category="(?<Category>[^"]+)" reason="(?<Reason>[^"]+)" environment="(?<Environment>[^"]+)" value=(?<Value>-?[0-9]+)')
$StableRejectionReasons = @('none','stale-sequence','duplicate-sequence','incompatible-version','timestamp-out-of-bounds','impossible-aim-transition','connection-closed','actor-destroyed','malformed-request','activation-blocked')
$RequiredRejectionCategories = [ordered]@{
	'movement' = 'malformed-request'
	'aim' = 'impossible-aim-transition'
	'ability' = 'activation-blocked'
	'hit' = 'malformed-request'
	'cooldown' = 'activation-blocked'
	'dodge' = 'activation-blocked'
	'block' = 'activation-blocked'
	'resource' = 'malformed-request'
	'death' = 'malformed-request'
	'respawn' = 'malformed-request'
}
$ReconnectRegex = [regex]::new((Expand-Pattern $ReconnectPattern 'client-1-reconnect'))
if ($ReconnectRegex.GetGroupNames() -notcontains 'ConnectionId') { throw 'ReconnectPattern must contain a named ConnectionId capture.' }

$ResolvedServer = if ($ServerLauncherExecutable) { $ServerExecutable } else { Resolve-Executable 'ServerExecutable' $ServerExecutable }
$ResolvedServerLauncher = if ($ServerLauncherExecutable) { Resolve-Executable 'ServerLauncherExecutable' $ServerLauncherExecutable } else { $ResolvedServer }
$ResolvedClient = Resolve-Executable 'ClientExecutable' $ClientExecutable
$ResolvedLogs = Initialize-EmptyLogRoot $LogRoot
if ($script:PerformanceContractRecord) {
	[System.IO.File]::WriteAllBytes(
		(Join-Path $ResolvedLogs $script:PerformanceContractRecord.Summary.contract_artifact),
		[byte[]] $script:PerformanceContractRecord.Bytes)
}
$ActualServerSha256 = if ($EvidenceMode -ceq 'packaged') {
	if ($ServerLauncherExecutable) {
		$IdentityCommand = Invoke-HiddenCommand `
			-Executable $ResolvedServerLauncher `
			-Arguments (Expand-ServerControlArgument $ServerIdentityArguments $ResolvedServer) `
			-StandardOutputPath (Join-Path $ResolvedLogs 'server.identity.stdout.log') `
			-StandardErrorPath (Join-Path $ResolvedLogs 'server.identity.stderr.log') `
			-Description 'server executable identity probe'
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
$ScenarioLifecycle = [System.Collections.Generic.List[object]]::new()
$ProcessOutcomes = [System.Collections.Generic.List[object]]::new()
$Observations = [System.Collections.Generic.List[object]]::new()
$Rejections = [System.Collections.Generic.List[object]]::new()
$Clients = [System.Collections.Generic.List[object]]::new()
$Result = 'failed'
$Failure = $null
$FailureStage = $null
$FailureProcessRole = $null
$FailureClientId = $null
$CleanupFailure = $null
$CleanupFailureRole = $null
$PostCaptureValidationFailure = $null
$ServerDescendantProcessId = $null
$ObservationCompleted = $false
$CurrentStage = 'launch'
$CurrentProcessRole = 'server'
$CurrentClientId = $null
$CleanupAttempted = $false
$CleanupSucceeded = $null

try {
	$CurrentStage = 'server-start'
	$CurrentProcessRole = 'server'
	$ServerStdOut = Join-Path $ResolvedLogs 'server.stdout.log'
	$ServerStdErr = Join-Path $ResolvedLogs 'server.stderr.log'
	$ExpandedServerArguments = @(Expand-Argument $ServerArguments 'server') + @($ProfileServerArguments)
	$ServerProcessArguments = if ($ServerLauncherExecutable) { Expand-ServerLauncherArgument -Arguments $ServerLauncherArguments -ResolvedServerExecutable $ResolvedServer -ExpandedServerArguments $ExpandedServerArguments } else { $ExpandedServerArguments }
	$ServerHandle = Start-HiddenProcess -Executable $ResolvedServerLauncher -Arguments $ServerProcessArguments -StandardOutputPath $ServerStdOut -StandardErrorPath $ServerStdErr
	$ServerHandle | Add-Member -NotePropertyName Role -NotePropertyValue 'server'
	$ServerHandle | Add-Member -NotePropertyName TerminationState -NotePropertyValue $null
	$Processes.Add($ServerHandle)
	$ServerProcess = $ServerHandle.Process
	if ($ServerLauncherExecutable) {
		$ProcessIdLine = Wait-ForMatch -Process $ServerProcess -Path $ServerStdOut -ErrorPath $ServerStdErr -Description 'server descendant process identity' -Pattern $ServerProcessIdPattern
		$ProcessIdMatch = $ServerProcessIdRegex.Match($ProcessIdLine)
		$ServerDescendantProcessId = $ProcessIdMatch.Groups['ProcessId'].Value
		if ($ServerDescendantProcessId -notmatch '^[1-9][0-9]*$') { throw 'Server launcher emitted an invalid descendant process identity.' }
	}
	$ReadyLine = Wait-ForMatch -Process $ServerProcess -Path $ServerStdOut -ErrorPath $ServerStdErr -Description 'server readiness' -Pattern (Expand-Pattern $ServerReadyPattern 'server')
	$Lifecycle.Add((ConvertTo-Observation -EventName 'server_ready' -Source $ServerStdOut -Detail $ReadyLine))
	$NetworkConfigLine = Wait-ForMatch -Process $ServerProcess -Path $ServerStdOut -ErrorPath $ServerStdErr -Description 'network emulation configuration confirmation' -Pattern (Expand-Pattern $NetworkConfigPattern 'server')
	$Lifecycle.Add((ConvertTo-Observation -EventName 'network_config_confirmed' -Source $ServerStdOut -Detail $NetworkConfigLine))

	$ClientProcesses = @{}
	foreach ($ClientId in @('client-1','client-2')) {
		$CurrentStage = 'client-start'
		$CurrentProcessRole = $ClientId
		$CurrentClientId = $ClientId
		$StdOut = Join-Path $ResolvedLogs "$ClientId.stdout.log"
		$StdErr = Join-Path $ResolvedLogs "$ClientId.stderr.log"
		$ExpandedClientArguments = @(Expand-Argument $ClientArguments $ClientId) + @($ProfileClientArguments)
		$Handle = Start-HiddenProcess -Executable $ResolvedClient -Arguments $ExpandedClientArguments -StandardOutputPath $StdOut -StandardErrorPath $StdErr
		$Handle | Add-Member -NotePropertyName Role -NotePropertyValue $ClientId
		$Handle | Add-Member -NotePropertyName TerminationState -NotePropertyValue $null
		$Processes.Add($Handle)
		$ClientProcesses[$ClientId] = $Handle.Process
		$Clients.Add([pscustomobject]@{ id = $ClientId; role = 'initial_client' })
	}

	foreach ($ClientId in @('client-1','client-2')) {
		$CurrentStage = 'client-ready'
		$CurrentProcessRole = $ClientId
		$CurrentClientId = $ClientId
		$StdOut = Join-Path $ResolvedLogs "$ClientId.stdout.log"
		$StdErr = Join-Path $ResolvedLogs "$ClientId.stderr.log"
		$Line = Wait-ForMatch -Process $ClientProcesses[$ClientId] -Path $StdOut -ErrorPath $StdErr -Description "$ClientId readiness" -Pattern (Expand-Pattern $ClientReadyPattern $ClientId)
		$Lifecycle.Add((ConvertTo-Observation -EventName 'client_ready' -Source $StdOut -Detail $Line -ClientId $ClientId))
	}

	$CurrentStage = 'join'
	$CurrentProcessRole = 'client-2'
	$CurrentClientId = 'client-2'
	$JoinLine = Wait-ForMatch -Process $ClientProcesses['client-2'] -Path (Join-Path $ResolvedLogs 'client-2.stdout.log') -ErrorPath (Join-Path $ResolvedLogs 'client-2.stderr.log') -Description 'join-in-progress state' -Pattern (Expand-Pattern $JoinInProgressPattern 'client-2')
	$Lifecycle.Add((ConvertTo-Observation -EventName 'join_in_progress' -Source (Join-Path $ResolvedLogs 'client-2.stdout.log') -Detail $JoinLine -ClientId 'client-2'))
	if ($script:UseScenarioContract) {
		$JoinSequenceId = Get-RequiredSequenceId -Line $JoinLine -Pattern $JoinSequenceRegex -Description 'join-in-progress'
		$ScenarioLifecycle.Add((ConvertTo-ScenarioStage -Ordinal 1 -Stage 'join' -AuthoritativeResult 'joined' -ProcessRole 'client-2' -Source (Join-Path $ResolvedLogs 'client-2.stdout.log') -Detail $JoinLine -ClientId 'client-2' -SequenceId $JoinSequenceId))
	}

	foreach ($ClientId in @('client-1','client-2')) {
		$CurrentStage = 'play'
		$CurrentProcessRole = 'server'
		$CurrentClientId = $ClientId
		$MovementLine = Wait-ForMatch -Process $ServerProcess -Path $ServerStdOut -ErrorPath $ServerStdErr -Description "$ClientId movement" -Pattern (Expand-Pattern $MovementPattern $ClientId)
		$Observations.Add((ConvertTo-Observation -EventName 'movement' -Source $ServerStdOut -Detail $MovementLine -ClientId $ClientId))
	}

	$ServerLines = @(Get-Content -LiteralPath $ServerStdOut -ErrorAction SilentlyContinue)
	$Connections = @{}
	foreach ($Line in $ServerLines) {
		$Match = $ConnectionRegex.Match($Line)
		if ($Match.Success) { $Connections[$Match.Groups['ClientId'].Value] = $Match.Groups['ConnectionId'].Value }
	}
	if (@($Connections.Keys | Where-Object { $_ -in @('client-1','client-2') }).Count -ne 2) { throw 'Server did not expose distinct connection identities for both initial clients.' }

	$EnemyLine = Wait-ForMatch -Process $ServerProcess -Path $ServerStdOut -ErrorPath $ServerStdErr -Description 'authoritative enemy spawn' -Pattern (Expand-Pattern $EnemyPattern 'server')
	$Observations.Add((ConvertTo-Observation -EventName 'enemy_spawned' -Source $ServerStdOut -Detail $EnemyLine))
	$MeleeLine = Wait-ForMatch -Process $ServerProcess -Path $ServerStdOut -ErrorPath $ServerStdErr -Description 'server-resolved melee' -Pattern (Expand-Pattern $MeleePattern 'server')
	$Observations.Add((ConvertTo-Observation -EventName 'melee_resolved' -Source $ServerStdOut -Detail $MeleeLine))
	$CurrentClientId = 'client-1'
	$DamageLine = Wait-ForMatch -Process $ServerProcess -Path $ServerStdOut -ErrorPath $ServerStdErr -Description 'authoritative damage' -Pattern (Expand-Pattern $DamagePattern 'server')
	$Observations.Add((ConvertTo-Observation -EventName 'damage_applied' -Source $ServerStdOut -Detail $DamageLine))
	if ($script:UseScenarioContract) {
		$PlaySequenceId = Get-RequiredSequenceId -Line $DamageLine -Pattern $PlaySequenceRegex -Description 'authoritative damage'
		if ($JoinSequenceId -ge $PlaySequenceId) { throw 'Contract join sequence must precede authoritative play sequence.' }
		$ScenarioLifecycle.Add((ConvertTo-ScenarioStage -Ordinal 2 -Stage 'play' -AuthoritativeResult 'damage-applied' -ProcessRole 'server' -Source $ServerStdOut -Detail $DamageLine -ClientId 'client-1' -SequenceId $PlaySequenceId))
	}
	foreach ($Category in $RequiredRejectionCategories.Keys) {
		$CurrentStage = 'play'
		$CurrentProcessRole = 'server'
		$CurrentClientId = 'client-2'
		$Observed = Wait-ForRejection -Process $ServerProcess -Path $ServerStdOut -ErrorPath $ServerStdErr -Regex $RejectionRegex -Category $Category
		$Reason = $Observed.Match.Groups['Reason'].Value
		if ($Reason -cnotin $StableRejectionReasons) { throw "Unsupported rejection reason '$Reason'." }
		if ($Reason -cne $RequiredRejectionCategories[$Category]) { throw "Rejection category '$Category' used '$Reason' instead of '$($RequiredRejectionCategories[$Category])'." }
		Assert-StructuredRejectionMatch -Match $Observed.Match -ExpectedCategory $Category -ExpectedReason $Reason -ExpectedConnectionId $Connections['client-2']
		if ($script:UseScenarioContract) {
			$Rejections.Add([pscustomobject]@{
				category = $Category
				reason = $Reason
				connection_pseudonym = $Connections['client-2']
				process_role = 'server'
				client_id = 'client-2'
				activation_id = $Observed.Match.Groups['ActivationId'].Value
				sequence_id = [long] $Observed.Match.Groups['Sequence'].Value
				authoritative_result = 'rejected'
				scenario_id = $ScenarioId
				profile_id = $ProfileId
				profile_version = $ProfileVersion
				build = $BuildIdentity
				source = [System.IO.Path]::GetFileName($ServerStdOut)
				detail = "rejected:$Reason"
			})
		} else {
			$Rejections.Add([pscustomobject]@{ category = $Category; reason = $Reason; connection_pseudonym = $Connections['client-2']; source = $ServerStdOut; detail = $Observed.Line })
		}
	}

	if ($script:UseScenarioContract) {
		$CurrentStage = 'death'
		$CurrentProcessRole = 'server'
		$CurrentClientId = 'client-2'
		$DeathLine = Wait-ForMatch -Process $ServerProcess -Path $ServerStdOut -ErrorPath $ServerStdErr -Description 'authoritative death' -Pattern (Expand-Pattern $DeathPattern 'client-2')
		$Lifecycle.Add((ConvertTo-Observation -EventName 'death' -Source $ServerStdOut -Detail $DeathLine -ClientId 'client-2'))
		$ScenarioLifecycle.Add((ConvertTo-ScenarioStage -Ordinal 3 -Stage 'death' -AuthoritativeResult 'dead' -ProcessRole 'server' -Source $ServerStdOut -Detail $DeathLine -ClientId 'client-2'))

		$CurrentStage = 'respawn'
		$RespawnLine = Wait-ForMatch -Process $ServerProcess -Path $ServerStdOut -ErrorPath $ServerStdErr -Description 'authoritative respawn' -Pattern (Expand-Pattern $RespawnPattern 'client-2')
		$Lifecycle.Add((ConvertTo-Observation -EventName 'respawn' -Source $ServerStdOut -Detail $RespawnLine -ClientId 'client-2'))
		$ScenarioLifecycle.Add((ConvertTo-ScenarioStage -Ordinal 4 -Stage 'respawn' -AuthoritativeResult 'respawned' -ProcessRole 'server' -Source $ServerStdOut -Detail $RespawnLine -ClientId 'client-2'))
	}

	$CurrentStage = 'disconnect'
	$CurrentProcessRole = 'client-1'
	$CurrentClientId = 'client-1'
	Stop-Process -Id $ClientProcesses['client-1'].Id -Force
	$ClientProcesses['client-1'].WaitForExit()
	@($Processes | Where-Object { $_.Role -ceq 'client-1' })[0].TerminationState = 'runner-terminated'
	$DisconnectLine = Wait-ForMatch -Process $ServerProcess -Path $ServerStdOut -ErrorPath $ServerStdErr -Description 'disconnect cleanup' -Pattern (Expand-Pattern $DisconnectPattern 'client-1')
	$Lifecycle.Add((ConvertTo-Observation -EventName 'disconnect' -Source $ServerStdOut -Detail $DisconnectLine -ClientId 'client-1'))
	if ($script:UseScenarioContract) {
		$ScenarioLifecycle.Add((ConvertTo-ScenarioStage -Ordinal 5 -Stage 'disconnect' -AuthoritativeResult 'disconnected' -ProcessRole 'server' -Source $ServerStdOut -Detail $DisconnectLine -ClientId 'client-1'))
	}

	$ReconnectId = 'client-1-reconnect'
	$CurrentStage = 'reconnect'
	$CurrentProcessRole = $ReconnectId
	$CurrentClientId = $ReconnectId
	$ReconnectStdOut = Join-Path $ResolvedLogs "$ReconnectId.stdout.log"
	$ReconnectStdErr = Join-Path $ResolvedLogs "$ReconnectId.stderr.log"
	$ExpandedReconnectArguments = @(Expand-Argument $ClientArguments $ReconnectId) + @($ProfileClientArguments)
	$ReconnectHandle = Start-HiddenProcess -Executable $ResolvedClient -Arguments $ExpandedReconnectArguments -StandardOutputPath $ReconnectStdOut -StandardErrorPath $ReconnectStdErr
	$ReconnectHandle | Add-Member -NotePropertyName Role -NotePropertyValue $ReconnectId
	$ReconnectHandle | Add-Member -NotePropertyName TerminationState -NotePropertyValue $null
	$Processes.Add($ReconnectHandle)
	$ReconnectProcess = $ReconnectHandle.Process
	$Clients.Add([pscustomobject]@{ id = $ReconnectId; role = 'reconnect_client' })
	[void] (Wait-ForMatch -Process $ReconnectProcess -Path $ReconnectStdOut -ErrorPath $ReconnectStdErr -Description 'reconnect client readiness' -Pattern (Expand-Pattern $ClientReadyPattern $ReconnectId))
	$ReconnectLine = Wait-ForMatch -Process $ServerProcess -Path $ServerStdOut -ErrorPath $ServerStdErr -Description 'new reconnect identity' -Pattern (Expand-Pattern $ReconnectPattern $ReconnectId)
	$ReconnectMatch = $ReconnectRegex.Match($ReconnectLine)
	if ($ReconnectMatch.Groups['ConnectionId'].Value -eq $Connections['client-1']) { throw 'Reconnect reused the disconnected connection identity.' }
	$ReconnectObservation = ConvertTo-Observation -EventName 'reconnect' -Source $ServerStdOut -Detail $ReconnectLine -ClientId $ReconnectId
	$ReconnectObservation | Add-Member -NotePropertyName connection_id -NotePropertyValue $ReconnectMatch.Groups['ConnectionId'].Value
	$Lifecycle.Add($ReconnectObservation)
	if ($script:UseScenarioContract) {
		$ScenarioLifecycle.Add((ConvertTo-ScenarioStage -Ordinal 6 -Stage 'reconnect' -AuthoritativeResult 'reconnected' -ProcessRole 'server' -Source $ServerStdOut -Detail $ReconnectLine -ClientId $ReconnectId))
	}

	$ServerLines = @(Get-Content -LiteralPath $ServerStdOut -ErrorAction Stop)
	$ReadyIndex = Get-SingleMatchIndex -Lines $ServerLines -Pattern (Expand-Pattern $ServerReadyPattern 'server') -Description 'server-ready'
	$NetworkConfigIndex = Get-SingleMatchIndex -Lines $ServerLines -Pattern (Expand-Pattern $NetworkConfigPattern 'server') -Description 'network-config'
	[void] (Get-SingleMatchIndex -Lines $ServerLines -Pattern (Expand-Pattern $EnemyPattern 'server') -Description 'enemy-spawn')
	$MeleeIndex = Get-SingleMatchIndex -Lines $ServerLines -Pattern (Expand-Pattern $MeleePattern 'server') -Description 'melee-resolution'
	$DamageIndex = Get-SingleMatchIndex -Lines $ServerLines -Pattern (Expand-Pattern $DamagePattern 'server') -Description 'damage-application'
	$DisconnectIndex = Get-SingleMatchIndex -Lines $ServerLines -Pattern (Expand-Pattern $DisconnectPattern 'client-1') -Description 'disconnect'
	$ReconnectIndex = Get-SingleMatchIndex -Lines $ServerLines -Pattern (Expand-Pattern $ReconnectPattern 'client-1-reconnect') -Description 'reconnect'
	$MovementIndexes = @{}
	foreach ($ClientId in @('client-1','client-2')) { $MovementIndexes[$ClientId] = Get-SingleMatchIndex -Lines $ServerLines -Pattern (Expand-Pattern $MovementPattern $ClientId) -Description "$ClientId movement" }
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
	Assert-ExactRejectionInventory -Lines @($ServerLines + $ServerErrorLines) -Regex $RejectionRegex -RequiredCategories $RequiredRejectionCategories -ExpectedConnectionId $Connections['client-2']
	Assert-MetricEnvironmentInventory -Lines @($ServerLines + $ServerErrorLines) -Regex $MetricRegex -ExpectedEnvironment $Environment
	foreach ($ClientId in @('client-1','client-2','client-1-reconnect')) {
		$ClientLines = @(Get-Content -LiteralPath (Join-Path $ResolvedLogs "$ClientId.stdout.log") -ErrorAction Stop)
		[void] (Get-SingleMatchIndex -Lines $ClientLines -Pattern (Expand-Pattern $ClientReadyPattern $ClientId) -Description "$ClientId ready")
		if ($ClientId -eq 'client-2') { [void] (Get-SingleMatchIndex -Lines $ClientLines -Pattern (Expand-Pattern $JoinInProgressPattern $ClientId) -Description 'client-2 join-in-progress') }
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

	$CurrentStage = 'observation'
	$CurrentProcessRole = 'server'
	$CurrentClientId = $null
	Wait-ForObservationInterval @(
		[pscustomobject]@{ Name = 'server'; Process = $ServerProcess; StandardOutputPath = $ServerStdOut; StandardErrorPath = $ServerStdErr },
		[pscustomobject]@{ Name = 'client-2'; Process = $ClientProcesses['client-2']; StandardOutputPath = (Join-Path $ResolvedLogs 'client-2.stdout.log'); StandardErrorPath = (Join-Path $ResolvedLogs 'client-2.stderr.log') },
		[pscustomobject]@{ Name = $ReconnectId; Process = $ReconnectProcess; StandardOutputPath = $ReconnectStdOut; StandardErrorPath = $ReconnectStdErr }
	) $DurationSeconds
	$ObservationCompleted = $true

	if ($script:UseScenarioContract) {
		$CurrentStage = 'shutdown'
		$CurrentProcessRole = 'server'
		$CurrentClientId = $null
		$ShutdownLine = Wait-ForMatch -Process $ServerProcess -Path $ServerStdOut -ErrorPath $ServerStdErr -Description 'controlled shutdown' -Pattern (Expand-Pattern $ShutdownPattern 'server')
		[void] (Wait-ForSuccessfulProcessExit $ServerProcess 'authoritative server exit after controlled shutdown')
		$ServerHandle.TerminationState = 'exited'
		$Lifecycle.Add((ConvertTo-Observation -EventName 'shutdown' -Source $ServerStdOut -Detail $ShutdownLine))
		$ScenarioLifecycle.Add((ConvertTo-ScenarioStage -Ordinal 7 -Stage 'shutdown' -AuthoritativeResult 'shutdown-complete' -ProcessRole 'server' -Source $ServerStdOut -Detail $ShutdownLine))

		$ContractServerLines = @(Get-Content -LiteralPath $ServerStdOut -ErrorAction Stop)
		$DeathIndex = Get-SingleMatchIndex -Lines $ContractServerLines -Pattern (Expand-Pattern $DeathPattern 'client-2') -Description 'authoritative death'
		$RespawnIndex = Get-SingleMatchIndex -Lines $ContractServerLines -Pattern (Expand-Pattern $RespawnPattern 'client-2') -Description 'authoritative respawn'
		$ContractDisconnectIndex = Get-SingleMatchIndex -Lines $ContractServerLines -Pattern (Expand-Pattern $DisconnectPattern 'client-1') -Description 'contract disconnect'
		$ContractReconnectIndex = Get-SingleMatchIndex -Lines $ContractServerLines -Pattern (Expand-Pattern $ReconnectPattern 'client-1-reconnect') -Description 'contract reconnect'
		$ShutdownIndex = Get-SingleMatchIndex -Lines $ContractServerLines -Pattern (Expand-Pattern $ShutdownPattern 'server') -Description 'controlled shutdown'
		if ($LastGameplayRejectionIndex -ge $DeathIndex -or
			$DeathIndex -ge $RespawnIndex -or
			$RespawnIndex -ge $ContractDisconnectIndex -or
			$ContractDisconnectIndex -ge $ContractReconnectIndex -or
			$ContractReconnectIndex -ge $ShutdownIndex) {
			throw 'Scenario lifecycle observations were duplicated or reordered.'
		}
		$ObservedStages = @($ScenarioLifecycle | ForEach-Object { $_.stage })
		$ExpectedStages = @($ResolvedScenarioContract.lifecycle_stages)
		if (@(Compare-Object $ExpectedStages $ObservedStages -SyncWindow 0).Count -ne 0) {
			throw 'Scenario lifecycle evidence did not match the ordered contract.'
		}
	}
}
catch {
	$Failure = $_.Exception.Message
	$FailureStage = $CurrentStage
	$FailureProcessRole = $CurrentProcessRole
	$FailureClientId = $CurrentClientId
	throw
}
finally {
	$CleanupAttempted = $true
	if ($ServerLauncherExecutable -and $ServerDescendantProcessId) {
		try {
			[void] (Invoke-HiddenCommand `
				-Executable $ResolvedServerLauncher `
				-Arguments (Expand-ServerControlArgument -Arguments $ServerCleanupArguments -ResolvedServerExecutable $ResolvedServer -ServerProcessId $ServerDescendantProcessId) `
				-StandardOutputPath (Join-Path $ResolvedLogs 'server.cleanup.stdout.log') `
				-StandardErrorPath (Join-Path $ResolvedLogs 'server.cleanup.stderr.log') `
				-Description "server descendant cleanup for process $ServerDescendantProcessId")
		}
		catch {
			$CleanupFailure = $_.Exception.Message
			$CleanupFailureRole = 'server'
			$CleanupSucceeded = $false
			$Result = 'failed'
			if (-not $Failure) {
				$Failure = $CleanupFailure
				$FailureStage = 'cleanup'
				$FailureProcessRole = 'server'
				$FailureClientId = $null
			}
		}
	}
	foreach ($Handle in $Processes) {
		$Process = $Handle.Process
		try {
			$Process.Refresh()
			if (-not $Process.HasExited) {
				Stop-Process -Id $Process.Id -Force -ErrorAction Stop
				$Handle.TerminationState = 'runner-terminated'
			}
			if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
				throw "Timed out after $TimeoutSeconds seconds waiting for runtime process '$($Handle.Role)' cleanup."
			}
			$Process.WaitForExit()
			if (-not $Handle.TerminationState) { $Handle.TerminationState = 'exited' }
			try { $Process.CancelOutputRead() } catch { Write-Verbose "Cancelling asynchronous standard-output capture failed during runtime cleanup: $($_.Exception.Message)" }
			try { $Process.CancelErrorRead() } catch { Write-Verbose "Cancelling asynchronous standard-error capture failed during runtime cleanup: $($_.Exception.Message)" }
			if ($script:UseScenarioContract) {
				$ProcessOutcomes.Add((ConvertTo-ProcessOutcome -ProcessRole ([string] $Handle.Role) -TerminationState ([string] $Handle.TerminationState) -ExitCode ([int] $Process.ExitCode)))
			}
		}
		catch {
			if (-not $CleanupFailure) {
				$CleanupFailure = "Runtime process '$($Handle.Role)' cleanup failed: $($_.Exception.Message)"
				$CleanupFailureRole = [string] $Handle.Role
			}
			$CleanupSucceeded = $false
			$Result = 'failed'
			if (-not $Failure) {
				$Failure = $CleanupFailure
				$FailureStage = 'cleanup'
				$FailureProcessRole = [string] $Handle.Role
				$FailureClientId = if ($Handle.Role -in @('client-1','client-2','client-1-reconnect')) { [string] $Handle.Role } else { $null }
			}
		}
		$Handle.Capture.Dispose()
		$Process.Dispose()
	}
	if ($null -eq $CleanupSucceeded) { $CleanupSucceeded = -not [bool] $CleanupFailure }
	if ($ObservationCompleted -and -not $Failure -and -not $CleanupFailure) {
		try {
			$FinalServerLines = @(Get-Content -LiteralPath $ServerStdOut -ErrorAction Stop)
			$FinalServerErrorLines = @(Get-Content -LiteralPath $ServerStdErr -ErrorAction Stop)
			Assert-ExactRejectionInventory -Lines @($FinalServerLines + $FinalServerErrorLines) -Regex $RejectionRegex -RequiredCategories $RequiredRejectionCategories -ExpectedConnectionId $Connections['client-2']
			Assert-MetricEnvironmentInventory -Lines @($FinalServerLines + $FinalServerErrorLines) -Regex $MetricRegex -ExpectedEnvironment $Environment
			$Result = if ($EvidenceMode -ceq 'packaged') { 'packaged-candidate' } else { 'fixture-passed' }
		}
		catch {
			$PostCaptureValidationFailure = $_.Exception.Message
			$Failure = $PostCaptureValidationFailure
			$FailureStage = $CurrentStage
			$FailureProcessRole = $CurrentProcessRole
			$FailureClientId = $CurrentClientId
			$Result = 'failed'
		}
	}
	$EvidenceSchemaVersion = if ($script:UseScenarioContract) { 2 } else { 1 }
	$PackagedProvenanceEvidence = if ($PackagedProvenance) {
		[ordered]@{
			path = if ($script:UseScenarioContract) { [System.IO.Path]::GetFileName($PackagedProvenance.Path) } else { $PackagedProvenance.Path }
			sha256 = $PackagedProvenance.Sha256
		}
	} else { $null }
	$ScenarioEvidence = [ordered]@{ id = $ScenarioId; validation_mode = 'present_time'; action_family = 'melee'; map = $ServerMap; duration_seconds = $DurationSeconds; actor_mix = $ActorMixIdentity; seed = $RunId; environment = $Environment }
	if ($script:UseScenarioContract) { $ScenarioEvidence.version = $ScenarioVersion }
	$ProfileEvidence = [ordered]@{ schema_id = 'aetheln.network-profile'; schema_version = 1; id = $ProfileId; runtime_config_identity = $NetworkConfigIdentity; latency_ms = $null; jitter_ms = $null; loss_percent = $null; duplication_percent = $null; reorder_percent = $null; server_tick_hz = $null; history_ms = $null; bandwidth_limit_kbps = $null; capacity_players = $null }
	if ($script:UseScenarioContract) {
		$ProfileEvidence.version = $ProfileVersion
		$ProfileEvidence.kind = $ProfileKind
		$ProfileEvidence.server_argument_count = $ProfileServerArgumentCount
		$ProfileEvidence.client_argument_count = $ProfileClientArgumentCount
		$ProfileEvidence.arguments_sha256 = $ProfileArgumentsSha256
	}
	$PublishedFailureStage = if ($FailureStage) { $FailureStage } else { $CurrentStage }
	$PublishedFailureRole = if ($FailureProcessRole) { $FailureProcessRole } else { $CurrentProcessRole }
	$PublishedFailureClientId = if ($FailureStage) { $FailureClientId } else { $CurrentClientId }
	$PublishedFailure = if ($script:UseScenarioContract -and $Failure) {
		$FailureKind = if ($Failure -match '(?i)timed out') {
			'timeout'
		} elseif ($Failure -match "Required process '[^']+' exited unexpectedly") {
			'required-process-exit'
		} elseif ($Failure -match '(?i)process exited with code') {
			'process-exit'
		} elseif ($Failure -match '(?i)runtime reported an error') {
			'runtime-error'
		} elseif ($PublishedFailureStage -ceq 'cleanup') {
			'cleanup-failed'
		} else {
			'contract-validation-failed'
		}
		"stage=$PublishedFailureStage;role=$PublishedFailureRole;reason=$FailureKind"
	} else { $Failure }
	$PublishedCleanupFailure = if ($script:UseScenarioContract -and $CleanupFailure) {
		$PublishedCleanupFailureRole = if ($CleanupFailureRole) { $CleanupFailureRole } else { 'server' }
		"stage=cleanup;role=$PublishedCleanupFailureRole;reason=cleanup-failed"
	} else { $CleanupFailure }
	$FailureDetails = if ($script:UseScenarioContract -and $PublishedFailure) {
		ConvertTo-FailureDetail -Message $Failure -PublishedReason $PublishedFailure -Stage $PublishedFailureStage -ProcessRole $PublishedFailureRole -ClientId $PublishedFailureClientId -CleanupWasAttempted $CleanupAttempted -CleanupWasSuccessful $CleanupSucceeded -CleanupError $PublishedCleanupFailure
	} else { $null }
	$Evidence = [ordered]@{
		schema_id = 'aetheln.network-authority-evidence'
		schema_version = $EvidenceSchemaVersion
		run_id = $RunId
		evidence_mode = $EvidenceMode
		result = $Result
		failure = $PublishedFailure
		scenario = $ScenarioEvidence
		provenance = [ordered]@{ source_revision = $SourceRevision; build = $BuildIdentity; toolchain = $ToolchainIdentity; hardware = $HardwareIdentity; topology = $TopologyIdentity; packaged_build_provenance = $PackagedProvenanceEvidence }
		network_profile = $ProfileEvidence
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
	if ($script:UseScenarioContract) {
		$Evidence.failure_details = $FailureDetails
		$Evidence.scenario_lifecycle = @($ScenarioLifecycle)
		$Evidence.scenario_lifecycle_summary = [ordered]@{ expected_stage_count = 7; observed_stage_count = $ScenarioLifecycle.Count; completed = ($ScenarioLifecycle.Count -eq 7 -and -not $Failure) }
		$Evidence.process_outcomes = if (-not $Failure -and -not $CleanupFailure) { @($ProcessOutcomes) } else { $null }
		$Evidence.cleanup = [ordered]@{ attempted = $CleanupAttempted; succeeded = $CleanupSucceeded; failure = $PublishedCleanupFailure }
	}
	if ($script:PerformanceContractRecord) { $Evidence.performance_contract = $script:PerformanceContractRecord.Summary }
	$Evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
	if ($PostCaptureValidationFailure) { throw "Post-capture evidence validation failed: $PostCaptureValidationFailure" }
	if ($CleanupFailure -and $FailureStage -ceq 'cleanup') { throw "Server cleanup failed: $CleanupFailure" }
}

Write-Output "Network authority spike $Result. Evidence: '$EvidencePath'."
