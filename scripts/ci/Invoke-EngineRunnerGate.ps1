<#
.SYNOPSIS
Runs engine-dependent compile, packaged-smoke, or scheduled milestone phase gates on an approved runner.
.DESCRIPTION
Compile and PackagedSmoke preserve the original single-job gates. The phase
modes (PackageClient, PackageServer, ValidateProvenance, SmokePhase) split the
scheduled clean-package milestone into bounded jobs that exchange outputs only
through the durable run-scoped handoff store under AETHELN_HANDOFF_ROOT, with
fail-closed integrity manifests and a run-context record binding each run
directory to its producing context. Every phase runs its long work under a
script-enforced watchdog (a kill-on-close Windows Job Object) sized below the
job timeout so phase_timeout evidence is recorded and uploaded before the
platform cancels the job. Handoff directories are never deleted here; eligible
directories are only listed in cleanup-request records for external
operational cleanup.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)] [ValidateSet('Compile', 'PackagedSmoke', 'PackageClient', 'PackageServer', 'ValidateProvenance', 'SmokePhase')] [string] $Mode,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RepositoryRoot,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SourceRevision,
	[string] $ArchiveRoot,
	[Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $LogRoot,
	[string] $Repository,
	[string] $RunId,
	[string] $RunAttempt,
	[string] $RunnerName,
	[double] $PhaseTimeoutMinutes = 0,
	[long] $HandoffPayloadCapBytes = 68719476736,
	[long] $HandoffRootCapBytes = 274877906944,
	[double] $HandoffStaleHours = 48
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Started = [DateTime]::UtcNow
$Checks = New-Object System.Collections.ArrayList
$RequiredFailed = $false
$FailureCode = $null
$ResolvedRepository = $null
$PhaseByMode = @{ PackageClient = 'client'; PackageServer = 'server'; ValidateProvenance = 'provenance'; SmokePhase = 'smoke' }
$IsPhaseMode = $PhaseByMode.ContainsKey($Mode)
$Policy = if ($Mode -eq 'Compile') { 'incremental-target-compilation' } else { 'clean-package-and-smoke' }
$RepositoryPattern = '^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$'
$RunnerNamePattern = '^[^\\/:*?"<>|\x00-\x1f]{1,128}$'
$ManifestPropertyNames = @('schemaVersion', 'repository', 'sourceRevision', 'runId', 'runAttempt', 'producingPhase', 'expectedConsumingPhases', 'runnerName', 'files', 'totalBytes', 'createdUtc')
$RunContextPropertyNames = @('schemaVersion', 'repository', 'sourceRevision', 'runId', 'runAttempt', 'runnerName', 'createdUtc')
$MarkerPropertyNames = @('schemaVersion', 'repository', 'sourceRevision', 'runId', 'runAttempt', 'runnerName', 'state', 'finishedUtc')
$SmokeDeadlineUtc = [DateTime]::MaxValue

$EngineGateJobSource = @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace Aetheln {
 public sealed class EngineGateJob : IDisposable {
  const uint KillOnJobClose = 0x00002000;
  const uint CreateSuspended = 0x00000004;
  const uint CreateNoWindow = 0x08000000;
  IntPtr handle;
  [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
  [StructLayout(LayoutKind.Sequential)] struct BasicLimitInformation { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
  [StructLayout(LayoutKind.Sequential)] struct ExtendedLimitInformation { public BasicLimitInformation BasicLimitInformation; public IoCounters IoInfo; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct StartupInfo { public uint cb; public string reserved, desktop, title; public uint x, y, xSize, ySize, xCountChars, yCountChars, fillAttribute, flags; public short showWindow, reserved2; public IntPtr reserved2Pointer, standardInput, standardOutput, standardError; }
  [StructLayout(LayoutKind.Sequential)] struct ProcessInformation { public IntPtr process, thread; public uint processId, threadId; }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int informationClass, ref ExtendedLimitInformation information, uint length);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcess(string applicationName, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint creationFlags, IntPtr environment, string currentDirectory, ref StartupInfo startupInfo, out ProcessInformation processInformation);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process, uint exitCode);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  public EngineGateJob() {
   handle=CreateJobObject(IntPtr.Zero,null); if(handle==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"CreateJobObject failed.");
   ExtendedLimitInformation information=new ExtendedLimitInformation(); information.BasicLimitInformation.LimitFlags=KillOnJobClose;
   if(!SetInformationJobObject(handle,9,ref information,(uint)Marshal.SizeOf(typeof(ExtendedLimitInformation)))) { int error=Marshal.GetLastWin32Error(); CloseHandle(handle); handle=IntPtr.Zero; throw new Win32Exception(error,"SetInformationJobObject failed."); }
  }
  void Assign(IntPtr process) { if(handle==IntPtr.Zero) throw new ObjectDisposedException("EngineGateJob"); if(!AssignProcessToJobObject(handle,process)) throw new Win32Exception(Marshal.GetLastWin32Error(),"AssignProcessToJobObject failed."); }
  public System.Diagnostics.Process StartSuspended(string executable, string commandLine, string workingDirectory) {
   StartupInfo startup=new StartupInfo(); startup.cb=(uint)Marshal.SizeOf(typeof(StartupInfo)); ProcessInformation information;
   if(!CreateProcess(executable,new StringBuilder(commandLine),IntPtr.Zero,IntPtr.Zero,false,CreateSuspended|CreateNoWindow,IntPtr.Zero,workingDirectory,ref startup,out information)) throw new Win32Exception(Marshal.GetLastWin32Error(),"CreateProcess failed.");
   System.Diagnostics.Process managed=null;
   try {
    Assign(information.process);
    managed=System.Diagnostics.Process.GetProcessById((int)information.processId); IntPtr managedHandle=managed.Handle;
    if(ResumeThread(information.thread)==UInt32.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error(),"ResumeThread failed.");
    return managed;
   } catch { TerminateProcess(information.process,1); if(managed!=null) managed.Dispose(); throw; }
   finally { CloseHandle(information.thread); CloseHandle(information.process); }
  }
  public void Dispose() { IntPtr current=handle; handle=IntPtr.Zero; if(current!=IntPtr.Zero) CloseHandle(current); GC.SuppressFinalize(this); }
  ~EngineGateJob() { Dispose(); }
 }
}
"@

function Initialize-EngineGateJobType {
	if ($null -eq ('Aetheln.EngineGateJob' -as [type])) { Add-Type -TypeDefinition $EngineGateJobSource -Language CSharp }
}

function Test-IsWithin([string] $Candidate, [string] $Parent) {
	$CandidatePath = [System.IO.Path]::GetFullPath($Candidate).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
	$ParentPath = [System.IO.Path]::GetFullPath($Parent).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
	return $CandidatePath.Equals($ParentPath, [StringComparison]::OrdinalIgnoreCase) -or $CandidatePath.StartsWith($ParentPath + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-RequiredDirectory([string] $Value, [string] $ReasonCode) {
	if ([string]::IsNullOrWhiteSpace($Value) -or -not (Test-Path -LiteralPath $Value -PathType Container)) { throw $ReasonCode }
	return (Resolve-Path -LiteralPath $Value).Path
}

function Resolve-OutputRoot([string] $Value, [string] $Repository, [string] $ReasonCode) {
	if ([string]::IsNullOrWhiteSpace($Value)) { throw $ReasonCode }
	$FullPath = [System.IO.Path]::GetFullPath($Value)
	if (Test-IsWithin $FullPath $Repository) { throw $ReasonCode }
	if (Test-Path -LiteralPath $FullPath) {
		if (-not (Test-Path -LiteralPath $FullPath -PathType Container)) { throw $ReasonCode }
		if (@(Get-ChildItem -LiteralPath $FullPath -Force).Count -ne 0) { throw $ReasonCode }
	}
	return $FullPath
}

function Add-Check([string] $Name, [string] $Status, [datetime] $CheckStarted, [string] $Command, [string] $Message) {
	[void] $Checks.Add([ordered]@{
		name = $Name
		tier = 'required'
		status = $Status
		durationSeconds = [Math]::Round(([DateTime]::UtcNow - $CheckStarted).TotalSeconds, 3)
		command = $Command
		message = $Message
	})
}

function Get-SafeDiagnosticMessage([string] $Reason, [System.Collections.IEnumerable] $Output, [string[]] $ProtectedValues) {
	$Redactions = @($ProtectedValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object Length -Descending -Unique)
	$Lines = New-Object System.Collections.ArrayList
	$EnvironmentTable = $false
	foreach ($Record in @($Output)) {
		$Line = [string] $Record
		foreach ($ProtectedValue in $Redactions) {
			$Line = [regex]::Replace($Line, [regex]::Escape($ProtectedValue), '<redacted-path>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
		}
		$Trimmed = $Line.TrimStart()
		if ([string]::IsNullOrWhiteSpace($Trimmed)) {
			$EnvironmentTable = $false
			continue
		}
		if ($Trimmed -match '(?i)\b(authorization|password|passwd|secret|token|bearer|api[_ -]?key|private[_ -]?key|access[_ -]?key|connection[_ -]?string|client[_ -]?secret|session[_ -]?token)\b(?:\s|:|=)') {
			$Line = 'credential_like_diagnostic_redacted'
		} elseif ($Trimmed -match '^[A-Za-z_][A-Za-z0-9_]*\s*=') {
			$Line = 'environment_assignment_redacted'
		} elseif ($Trimmed -match '^Name\s+Value$' -or $Trimmed -match '^-+\s+-+$') {
			$EnvironmentTable = $true
			$Line = 'environment_table_redacted'
		} elseif ($EnvironmentTable -and $Trimmed -match '^[A-Za-z_][A-Za-z0-9_]*\s+\S') {
			$Line = 'environment_table_redacted'
		}
		if ($Line -notmatch '(?i)\b(error|fatal|warning|failed|failure|timeout|exception)\b|\b[A-Z]{1,6}\d{3,5}\b') { continue }
		$Line = [regex]::Replace($Line, '\bAKIA[0-9A-Z]{16}\b', '<redacted-token>')
		$Line = [regex]::Replace($Line, '\bgh[pousr]_[A-Za-z0-9_]{20,}\b', '<redacted-token>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
		$Line = [regex]::Replace($Line, '\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]{10,})?\b', '<redacted-token>')
		$Line = [regex]::Replace($Line, '\b[A-Za-z0-9+/_=-]{32,}\b', '<redacted-token>')
		if (-not [string]::IsNullOrWhiteSpace($Line)) { [void] $Lines.Add($Line) }
	}
	$Diagnostic = (@($Lines | Select-Object -Last 20) -join "`n")
	if ($Diagnostic.Length -gt 4096) { $Diagnostic = $Diagnostic.Substring($Diagnostic.Length - 4096) }
	if ([string]::IsNullOrWhiteSpace($Diagnostic)) { return $Reason }
	return $Reason + "`n" + $Diagnostic
}

function Invoke-Captured([string] $Executable, [string[]] $Arguments) {
	$PreviousErrorActionPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = 'Continue'
		$Output = @(& $Executable @Arguments 2>&1)
		$ExitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $PreviousErrorActionPreference
	}
	return [ordered]@{ output = $Output; exitCode = $ExitCode }
}

function Assert-RepositoryState([string] $Name) {
	$CheckStarted = [DateTime]::UtcNow
	try {
		$HeadResult = Invoke-Captured 'git' @('-C', $ResolvedRepository, 'rev-parse', 'HEAD')
		if ($HeadResult.exitCode -ne 0) { throw 'revision_query_failed' }
		$HeadLines = @($HeadResult.output | ForEach-Object { ([string] $_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
		if ($HeadLines.Count -ne 1 -or $HeadLines[0] -notmatch '^[0-9a-fA-F]{40}$') { throw 'revision_invalid' }
		if (-not $HeadLines[0].Equals($SourceRevision, [StringComparison]::OrdinalIgnoreCase)) { throw 'revision_changed' }

		$StatusResult = Invoke-Captured 'git' @('-C', $ResolvedRepository, 'status', '--porcelain', '--untracked-files=all')
		if ($StatusResult.exitCode -ne 0) { throw 'repository_status_failed' }
		$Changes = @($StatusResult.output | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) })
		if ($Changes.Count -ne 0) { throw 'repository_drift_detected' }
		Add-Check $Name 'passed' $CheckStarted 'git-revision-and-status' 'repository_state_valid'
	} catch {
		$Reason = [string] $_.Exception.Message
		if ($Reason -notmatch '^[a-z0-9_]+$') { $Reason = 'repository_state_invalid' }
		Add-Check $Name 'failed' $CheckStarted 'git-revision-and-status' $Reason
		throw $Reason
	}
}

function Complete-CommandStateCheck([string] $Name, [string] $CommandFailure) {
	$RepositoryFailure = $null
	try {
		Assert-RepositoryState $Name
	} catch {
		$RepositoryFailure = [string] $_.Exception.Message
	}
	if (-not [string]::IsNullOrWhiteSpace($CommandFailure)) { throw $CommandFailure }
	if (-not [string]::IsNullOrWhiteSpace($RepositoryFailure)) { throw $RepositoryFailure }
}

function Write-RunnerReport {
	if ([string]::IsNullOrWhiteSpace($ResolvedRepository)) { return }
	$ResultRoot = Join-Path $ResolvedRepository 'TestResults'
	if (-not (Test-Path -LiteralPath $ResultRoot)) { New-Item -ItemType Directory -Path $ResultRoot | Out-Null }
	$Passed = @($Checks | Where-Object { $_.status -eq 'passed' }).Count
	$Failed = @($Checks | Where-Object { $_.status -eq 'failed' }).Count
	$Skipped = @($Checks | Where-Object { $_.status -eq 'skipped' }).Count
	$Report = [ordered]@{
		schemaVersion = 1
		mode = $Mode
		policy = $Policy
		revision = $SourceRevision
		startedUtc = $Started.ToString('o')
		finishedUtc = [DateTime]::UtcNow.ToString('o')
		checks = @($Checks)
		summary = [ordered]@{
			total = $Checks.Count
			passed = $Passed
			failed = $Failed
			skipped = $Skipped
			requiredFailed = $Failed
		}
	}
	$Report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $ResultRoot 'engine-runner-report.json') -Encoding UTF8
}

function Test-IsReparsePoint([string] $Path) {
	$Item = Get-Item -LiteralPath $Path -Force
	return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-ChildEntriesSafe([string] $Root, [string] $ReasonCode, [bool] $SkipReparse = $false) {
	# Manual non-following walk: never traverses a reparse point, so a junction
	# or symbolic link can neither escape the approved root nor loop the scan.
	$Files = New-Object System.Collections.ArrayList
	$Directories = New-Object System.Collections.Stack
	if (Test-IsReparsePoint $Root) {
		if ($SkipReparse) { return @() }
		throw $ReasonCode
	}
	$Directories.Push(([System.IO.Path]::GetFullPath($Root)))
	while ($Directories.Count -gt 0) {
		$Current = $Directories.Pop()
		foreach ($Item in @(Get-ChildItem -LiteralPath $Current -Force)) {
			if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
				if ($SkipReparse) { continue }
				throw $ReasonCode
			}
			if ($Item.PSIsContainer) { $Directories.Push($Item.FullName) } else { [void] $Files.Add($Item) }
		}
	}
	return @($Files)
}

function Get-DirectoryBytes([string] $Root, [string] $ReasonCode, [bool] $SkipReparse = $false) {
	$Total = [long] 0
	foreach ($File in @(Get-ChildEntriesSafe $Root $ReasonCode $SkipReparse)) {
		$Total += [long] $File.Length
		if ($Total -lt 0) { throw $ReasonCode }
	}
	return $Total
}

function Assert-PathChainSafe([string] $Root, [string] $Leaf, [string] $ReasonCode) {
	# Validates every existing component from the approved root down to the
	# leaf: resolved containment plus no reparse point anywhere on the chain.
	$RootFull = [System.IO.Path]::GetFullPath($Root)
	$LeafFull = [System.IO.Path]::GetFullPath($Leaf)
	if (-not (Test-IsWithin $LeafFull $RootFull)) { throw $ReasonCode }
	$Current = $LeafFull
	while ($true) {
		if (Test-Path -LiteralPath $Current) {
			if (Test-IsReparsePoint $Current) { throw $ReasonCode }
		}
		if ($Current.Equals($RootFull, [StringComparison]::OrdinalIgnoreCase)) { break }
		$Current = [System.IO.Path]::GetDirectoryName($Current)
		if ([string]::IsNullOrEmpty($Current)) { throw $ReasonCode }
	}
}

function Assert-UniqueJsonProperties([string] $Raw, [string] $ReasonCode) {
	# ConvertFrom-Json silently keeps one value for duplicated properties, so a
	# tampered document could carry two conflicting definitions. Scope-aware
	# scan of the raw text rejects any duplicate property name per object.
	$Scopes = New-Object System.Collections.Stack
	$PendingName = $null
	$Index = 0
	$Length = $Raw.Length
	while ($Index -lt $Length) {
		$Character = $Raw[$Index]
		if ($Character -eq '"') {
			$Builder = New-Object System.Text.StringBuilder
			$Index++
			while ($Index -lt $Length -and $Raw[$Index] -ne '"') {
				if ($Raw[$Index] -eq '\') {
					[void] $Builder.Append($Raw[$Index])
					$Index++
					if ($Index -ge $Length) { throw $ReasonCode }
				}
				[void] $Builder.Append($Raw[$Index])
				$Index++
			}
			if ($Index -ge $Length) { throw $ReasonCode }
			$PendingName = $Builder.ToString()
			$Index++
			continue
		}
		if ($Character -eq '{') {
			$Scopes.Push((New-Object 'System.Collections.Generic.HashSet[string]'))
			$PendingName = $null
		} elseif ($Character -eq '}') {
			if ($Scopes.Count -eq 0) { throw $ReasonCode }
			[void] $Scopes.Pop()
			$PendingName = $null
		} elseif ($Character -eq ':') {
			if ($null -ne $PendingName -and $Scopes.Count -gt 0) {
				if (-not $Scopes.Peek().Add($PendingName)) { throw $ReasonCode }
			}
			$PendingName = $null
		} elseif ($Character -eq ',' -or $Character -eq '[' -or $Character -eq ']') {
			$PendingName = $null
		}
		$Index++
	}
	if ($Scopes.Count -ne 0) { throw $ReasonCode }
}

function Read-JsonStrict([string] $Path, [string] $ReasonCode) {
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw $ReasonCode }
	if (Test-IsReparsePoint $Path) { throw $ReasonCode }
	$Raw = Get-Content -LiteralPath $Path -Raw
	try {
		$Parsed = $Raw | ConvertFrom-Json
	} catch {
		throw $ReasonCode
	}
	Assert-UniqueJsonProperties $Raw $ReasonCode
	if ($null -eq $Parsed) { throw $ReasonCode }
	return $Parsed
}

function Assert-ClosedObject($Value, [string[]] $PropertyNames, [string] $ReasonCode) {
	if ($null -eq $Value -or $Value -isnot [System.Management.Automation.PSCustomObject]) { throw $ReasonCode }
	$ActualNames = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
	if ($ActualNames.Count -ne $PropertyNames.Count) { throw $ReasonCode }
	foreach ($Name in $PropertyNames) {
		if ($ActualNames -cnotcontains $Name) { throw $ReasonCode }
	}
}

function Test-JsonTimestamp($Value) {
	if ($Value -is [datetime]) { return $true }
	if ($Value -isnot [string]) { return $false }
	$Parsed = [DateTime]::MinValue
	return [DateTime]::TryParse([string] $Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref] $Parsed)
}

function Test-JsonInteger($Value, [long] $Expected) {
	if ($Value -isnot [int] -and $Value -isnot [long]) { return $false }
	return ([long] $Value -eq $Expected)
}

function Assert-PhaseContext {
	if ($Repository -notmatch $RepositoryPattern) { throw 'handoff_context_invalid' }
	foreach ($Component in ($Repository -split '/')) {
		if ($Component -in @('.', '..') -or $Component.EndsWith('.')) { throw 'handoff_context_invalid' }
	}
	if ($RunId -notmatch '^[0-9]{1,19}$') { throw 'handoff_context_invalid' }
	if ($RunAttempt -notmatch '^[0-9]{1,6}$') { throw 'handoff_context_invalid' }
	if ($RunnerName -notmatch $RunnerNamePattern) { throw 'handoff_context_invalid' }
	if ($PhaseTimeoutMinutes -le 0 -or $PhaseTimeoutMinutes -gt 1440) { throw 'handoff_context_invalid' }
}

function Resolve-HandoffRoot([string[]] $ForbiddenRoots) {
	$Value = [Environment]::GetEnvironmentVariable('AETHELN_HANDOFF_ROOT', 'Process')
	if ([string]::IsNullOrWhiteSpace($Value)) { throw 'handoff_root_unset' }
	if ($Value -match '^[\\/]{2}') { throw 'handoff_root_invalid' }
	if (-not [System.IO.Path]::IsPathRooted($Value)) { throw 'handoff_root_invalid' }
	if (-not (Test-Path -LiteralPath $Value -PathType Container)) { throw 'handoff_root_invalid' }
	$Full = (Resolve-Path -LiteralPath $Value).Path
	if ($Full -notmatch '^[A-Za-z]:\\.') { throw 'handoff_root_invalid' }
	$Drive = New-Object System.IO.DriveInfo ($Full.Substring(0, 1))
	if ($Drive.DriveType -ne [System.IO.DriveType]::Fixed) { throw 'handoff_root_invalid' }
	if (Test-IsReparsePoint $Full) { throw 'handoff_root_invalid' }
	foreach ($Forbidden in @($ForbiddenRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
		if (-not (Test-Path -LiteralPath $Forbidden)) { continue }
		$ForbiddenFull = [System.IO.Path]::GetFullPath($Forbidden)
		if ((Test-IsWithin $Full $ForbiddenFull) -or (Test-IsWithin $ForbiddenFull $Full)) { throw 'handoff_root_invalid' }
	}
	return $Full
}

function Get-HandoffChildPath([string] $Parent, [string] $Child, [string] $ReasonCode) {
	$Combined = [System.IO.Path]::GetFullPath((Join-Path $Parent $Child))
	if (-not (Test-IsWithin $Combined $Parent) -or $Combined.Equals([System.IO.Path]::GetFullPath($Parent), [StringComparison]::OrdinalIgnoreCase)) { throw $ReasonCode }
	return $Combined
}

function Write-JsonAtomic([object] $Value, [string] $Destination) {
	$Temporary = $Destination + '.tmp'
	$Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Temporary -Encoding UTF8
	Move-Item -LiteralPath $Temporary -Destination $Destination
}

function Write-RunContextRecord {
	Write-JsonAtomic ([ordered]@{
		schemaVersion = 1
		repository = $Repository
		sourceRevision = $SourceRevision
		runId = $RunId
		runAttempt = $RunAttempt
		runnerName = $RunnerName
		createdUtc = [DateTime]::UtcNow.ToString('o')
	}) (Join-Path $RunDirectory 'run-context.json')
}

function Test-RunContextRecord([string] $Directory, [bool] $RequireCurrentContext) {
	$Path = Join-Path $Directory 'run-context.json'
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'handoff_context_invalid' }
	$Record = Read-JsonStrict $Path 'handoff_context_invalid'
	Assert-ClosedObject $Record $RunContextPropertyNames 'handoff_context_invalid'
	if (-not (Test-JsonInteger $Record.schemaVersion 1)) { throw 'handoff_context_invalid' }
	if ($Record.repository -isnot [string] -or $Record.repository -notmatch $RepositoryPattern) { throw 'handoff_context_invalid' }
	if ($Record.sourceRevision -isnot [string] -or $Record.sourceRevision -notmatch '^[0-9a-fA-F]{40}$') { throw 'handoff_context_invalid' }
	if ($Record.runId -isnot [string] -or $Record.runId -notmatch '^[0-9]{1,19}$') { throw 'handoff_context_invalid' }
	if ($Record.runAttempt -isnot [string] -or $Record.runAttempt -notmatch '^[0-9]{1,6}$') { throw 'handoff_context_invalid' }
	if ($Record.runnerName -isnot [string] -or $Record.runnerName -notmatch $RunnerNamePattern) { throw 'handoff_context_invalid' }
	if (-not (Test-JsonTimestamp $Record.createdUtc)) { throw 'handoff_context_invalid' }
	$ExpectedName = 'run-{0}-attempt-{1}' -f [string] $Record.runId, [string] $Record.runAttempt
	if ((Split-Path -Leaf $Directory) -ne $ExpectedName) { throw 'handoff_context_mismatch' }
	if ([string] $Record.repository -cne $Repository) { throw 'handoff_context_mismatch' }
	if ($RequireCurrentContext) {
		if ([string] $Record.runnerName -cne $RunnerName) { throw 'handoff_runner_mismatch' }
		if (-not ([string] $Record.sourceRevision).Equals($SourceRevision, [StringComparison]::OrdinalIgnoreCase)) { throw 'handoff_context_mismatch' }
		if ([string] $Record.runId -ne $RunId -or [string] $Record.runAttempt -ne $RunAttempt) { throw 'handoff_context_mismatch' }
	}
	return $Record
}

function Test-HandoffManifestShape($Manifest) {
	Assert-ClosedObject $Manifest $ManifestPropertyNames 'handoff_schema_invalid'
	if (-not (Test-JsonInteger $Manifest.schemaVersion 1)) { throw 'handoff_schema_invalid' }
	if ($Manifest.repository -isnot [string] -or $Manifest.repository -notmatch $RepositoryPattern) { throw 'handoff_schema_invalid' }
	if ($Manifest.sourceRevision -isnot [string] -or $Manifest.sourceRevision -notmatch '^[0-9a-fA-F]{40}$') { throw 'handoff_schema_invalid' }
	if ($Manifest.runId -isnot [string] -or $Manifest.runId -notmatch '^[0-9]{1,19}$') { throw 'handoff_schema_invalid' }
	if ($Manifest.runAttempt -isnot [string] -or $Manifest.runAttempt -notmatch '^[0-9]{1,6}$') { throw 'handoff_schema_invalid' }
	if ($Manifest.producingPhase -isnot [string] -or $Manifest.producingPhase -notin @('client', 'server', 'provenance')) { throw 'handoff_schema_invalid' }
	if ($Manifest.runnerName -isnot [string] -or $Manifest.runnerName -notmatch $RunnerNamePattern) { throw 'handoff_schema_invalid' }
	if (-not (Test-JsonTimestamp $Manifest.createdUtc)) { throw 'handoff_schema_invalid' }
	$Consumers = @($Manifest.expectedConsumingPhases)
	if ($Consumers.Count -lt 1) { throw 'handoff_schema_invalid' }
	$ConsumerSet = New-Object 'System.Collections.Generic.HashSet[string]'
	foreach ($Consumer in $Consumers) {
		if ($Consumer -isnot [string] -or $Consumer -notin @('provenance', 'smoke') -or -not $ConsumerSet.Add($Consumer)) { throw 'handoff_schema_invalid' }
	}
	$Entries = @($Manifest.files)
	if ($Entries.Count -lt 1) { throw 'handoff_schema_invalid' }
	$PathSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	$Total = [long] 0
	foreach ($Entry in $Entries) {
		Assert-ClosedObject $Entry @('path', 'bytes', 'sha256') 'handoff_schema_invalid'
		$EntryPath = $Entry.path
		if ($EntryPath -isnot [string] -or [string]::IsNullOrWhiteSpace($EntryPath)) { throw 'handoff_schema_invalid' }
		if ($EntryPath -match '^([A-Za-z]:|[\\/])' -or $EntryPath.Contains(':') -or $EntryPath.Contains('\')) { throw 'handoff_schema_invalid' }
		foreach ($Segment in ($EntryPath -split '/')) {
			if ([string]::IsNullOrWhiteSpace($Segment) -or $Segment -in @('.', '..')) { throw 'handoff_schema_invalid' }
		}
		if (-not $PathSet.Add($EntryPath)) { throw 'handoff_schema_invalid' }
		if ($Entry.bytes -isnot [int] -and $Entry.bytes -isnot [long]) { throw 'handoff_schema_invalid' }
		$EntryBytes = [long] $Entry.bytes
		if ($EntryBytes -lt 0) { throw 'handoff_schema_invalid' }
		if ($EntryBytes -gt $HandoffPayloadCapBytes) { throw 'handoff_size_exceeded' }
		if ($Entry.sha256 -isnot [string] -or $Entry.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'handoff_schema_invalid' }
		$Total += $EntryBytes
		if ($Total -gt $HandoffPayloadCapBytes) { throw 'handoff_size_exceeded' }
	}
	if (($Manifest.totalBytes -isnot [int] -and $Manifest.totalBytes -isnot [long]) -or [long] $Manifest.totalBytes -ne $Total) { throw 'handoff_schema_invalid' }
	return [ordered]@{ pathSet = $PathSet; totalBytes = $Total }
}

function Get-HandoffRelativeFiles([string] $PhaseDirectory) {
	$Prefix = [System.IO.Path]::GetFullPath($PhaseDirectory).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
	$Seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	return @(Get-ChildEntriesSafe $PhaseDirectory 'handoff_payload_invalid' | Sort-Object FullName | ForEach-Object {
		$RelativePath = ($_.FullName.Substring($Prefix.Length) -replace '\\', '/')
		if (-not $Seen.Add($RelativePath)) { throw 'handoff_payload_invalid' }
		[ordered]@{
			path = $RelativePath
			bytes = [long] $_.Length
			sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
		}
	})
}

function Write-CleanupRequest([string] $ScopeRoot, [string] $RequestingPhase) {
	$Entries = New-Object System.Collections.ArrayList
	$RunDirectories = @(Get-ChildItem -LiteralPath $ScopeRoot -Directory -Force | Where-Object { $_.Name -like 'run-*' } | Sort-Object Name | Select-Object -First 100)
	foreach ($Directory in $RunDirectories) {
		$AgeHours = [Math]::Round(([DateTime]::UtcNow - $Directory.CreationTimeUtc).TotalHours, 2)
		$State = 'active'
		$Eligible = $false
		$CompletionState = $null
		$MeasuredBytes = [long] 0
		$ManifestDigests = @()
		try {
			if ($Directory.Name -notmatch '^run-[0-9]{1,19}-attempt-[0-9]{1,6}$') { throw 'invalid' }
			if (Test-IsReparsePoint $Directory.FullName) { throw 'invalid' }
			# A descendant reparse point is a containment concern: classify the
			# directory invalid before any recursive size or hash work.
			[void] (Get-ChildEntriesSafe $Directory.FullName 'invalid')
			$Context = Test-RunContextRecord $Directory.FullName $false
			$MeasuredBytes = Get-DirectoryBytes $Directory.FullName 'invalid'
			$ManifestDigests = @(Get-ChildItem -LiteralPath $Directory.FullName -Force -File -Filter 'manifest-*.json' | Sort-Object Name | ForEach-Object {
				if ($_.Name -notmatch '^manifest-(client|server|provenance)\.json$') { throw 'invalid' }
				$ManifestPhase = $Matches[1]
				$ParsedManifest = Read-JsonStrict $_.FullName 'invalid'
				[void] (Test-HandoffManifestShape $ParsedManifest)
				if ([string] $ParsedManifest.producingPhase -ne $ManifestPhase) { throw 'invalid' }
				foreach ($Field in @('repository', 'sourceRevision', 'runId', 'runAttempt', 'runnerName')) {
					if ([string] $ParsedManifest.$Field -cne [string] $Context.$Field) { throw 'invalid' }
				}
				[ordered]@{ name = $_.Name; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
			})
			$MarkerPath = Join-Path $Directory.FullName 'milestone-complete.json'
			if (Test-Path -LiteralPath $MarkerPath -PathType Leaf) {
				$Marker = Read-JsonStrict $MarkerPath 'invalid'
				Assert-ClosedObject $Marker $MarkerPropertyNames 'invalid'
				if (-not (Test-JsonInteger $Marker.schemaVersion 1)) { throw 'invalid' }
				if ($Marker.state -isnot [string] -or $Marker.state -cnotin @('passed', 'failed')) { throw 'invalid' }
				if (-not (Test-JsonTimestamp $Marker.finishedUtc)) { throw 'invalid' }
				foreach ($Field in @('repository', 'sourceRevision', 'runId', 'runAttempt', 'runnerName')) {
					if ([string] $Marker.$Field -cne [string] $Context.$Field) { throw 'invalid' }
				}
				$State = 'completed'
				$CompletionState = [string] $Marker.state
				$Eligible = $true
			} elseif ($AgeHours -gt $HandoffStaleHours) {
				$State = 'abandoned'
				$Eligible = $true
			}
		} catch {
			$State = 'invalid'
			$Eligible = $false
			$CompletionState = $null
			$MeasuredBytes = [long] 0
			$ManifestDigests = @()
		}
		[void] $Entries.Add([ordered]@{
			directory = $Directory.FullName
			runDirectoryName = $Directory.Name
			state = $State
			completionState = $CompletionState
			ageHours = $AgeHours
			measuredBytes = $MeasuredBytes
			manifestDigests = $ManifestDigests
			cleanupEligible = $Eligible
		})
	}
	$RequestRoot = Join-Path $ScopeRoot 'cleanup-requests'
	Assert-PathChainSafe $HandoffRoot $RequestRoot 'handoff_root_invalid'
	if (-not (Test-Path -LiteralPath $RequestRoot)) { New-Item -ItemType Directory -Path $RequestRoot | Out-Null }
	$RequestName = 'request-{0}-run-{1}-attempt-{2}-{3}.json' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')), $RunId, $RunAttempt, $RequestingPhase
	$Request = [ordered]@{
		schemaVersion = 1
		requestedUtc = [DateTime]::UtcNow.ToString('o')
		requestingRunId = $RunId
		requestingRunAttempt = $RunAttempt
		requestingPhase = $RequestingPhase
		staleThresholdHours = $HandoffStaleHours
		note = 'External operational action only. No automated deletion is performed by CI.'
		directories = @($Entries)
	}
	Write-JsonAtomic $Request (Join-Path $RequestRoot $RequestName)
}

function Write-HandoffManifest([string] $RunDirectory, [string] $Phase, [string[]] $Consumers) {
	$PhaseDirectory = Get-HandoffChildPath $RunDirectory $Phase 'handoff_payload_invalid'
	Assert-PathChainSafe $HandoffRoot $PhaseDirectory 'handoff_payload_invalid'
	$Files = @(Get-HandoffRelativeFiles $PhaseDirectory)
	if ($Files.Count -lt 1) { throw 'handoff_payload_invalid' }
	$TotalBytes = [long] 0
	foreach ($File in $Files) {
		$TotalBytes += [long] $File.bytes
		if ($TotalBytes -lt 0) { throw 'handoff_payload_invalid' }
	}
	$CommittedBytes = [long] 0
	foreach ($Existing in @(Get-ChildItem -LiteralPath $RunDirectory -Force -File -Filter 'manifest-*.json')) {
		$Parsed = Read-JsonStrict $Existing.FullName 'handoff_schema_invalid'
		$ExistingShape = Test-HandoffManifestShape $Parsed
		$CommittedBytes += [long] $ExistingShape.totalBytes
	}
	if (($CommittedBytes + $TotalBytes) -gt $HandoffPayloadCapBytes) { throw 'handoff_size_exceeded' }
	$Manifest = [ordered]@{
		schemaVersion = 1
		repository = $Repository
		sourceRevision = $SourceRevision
		runId = $RunId
		runAttempt = $RunAttempt
		producingPhase = $Phase
		expectedConsumingPhases = @($Consumers)
		runnerName = $RunnerName
		files = @($Files)
		totalBytes = $TotalBytes
		createdUtc = [DateTime]::UtcNow.ToString('o')
	}
	Write-JsonAtomic $Manifest (Join-Path $RunDirectory ('manifest-{0}.json' -f $Phase))
}

function Test-HandoffManifest([string] $RunDirectory, [string] $Phase, [string] $ConsumingPhase) {
	$ManifestPath = Join-Path $RunDirectory ('manifest-{0}.json' -f $Phase)
	Assert-PathChainSafe $HandoffRoot $ManifestPath 'handoff_payload_invalid'
	if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw 'handoff_missing' }
	$Manifest = Read-JsonStrict $ManifestPath 'handoff_schema_invalid'
	[void] (Test-HandoffManifestShape $Manifest)
	if ([string] $Manifest.repository -cne $Repository) { throw 'handoff_context_mismatch' }
	if (-not ([string] $Manifest.sourceRevision).Equals($SourceRevision, [StringComparison]::OrdinalIgnoreCase)) { throw 'handoff_context_mismatch' }
	if ([string] $Manifest.runId -ne $RunId -or [string] $Manifest.runAttempt -ne $RunAttempt) { throw 'handoff_context_mismatch' }
	if ([string] $Manifest.producingPhase -ne $Phase) { throw 'handoff_context_mismatch' }
	if (@($Manifest.expectedConsumingPhases) -notcontains $ConsumingPhase) { throw 'handoff_context_mismatch' }
	if ([string] $Manifest.runnerName -cne $RunnerName) { throw 'handoff_runner_mismatch' }
	$PhaseDirectory = Get-HandoffChildPath $RunDirectory $Phase 'handoff_missing'
	Assert-PathChainSafe $HandoffRoot $PhaseDirectory 'handoff_payload_invalid'
	if (-not (Test-Path -LiteralPath $PhaseDirectory -PathType Container)) { throw 'handoff_missing' }
	$ActualFiles = @(Get-HandoffRelativeFiles $PhaseDirectory)
	$ManifestByPath = @{}
	foreach ($Entry in @($Manifest.files)) { $ManifestByPath[[string] $Entry.path] = $Entry }
	if ($ActualFiles.Count -ne $ManifestByPath.Count) { throw 'handoff_digest_mismatch' }
	foreach ($Actual in $ActualFiles) {
		if (-not $ManifestByPath.ContainsKey([string] $Actual.path)) { throw 'handoff_digest_mismatch' }
		$Entry = $ManifestByPath[[string] $Actual.path]
		if ([long] $Actual.bytes -ne [long] $Entry.bytes) { throw 'handoff_digest_mismatch' }
		if ([string] $Actual.sha256 -cne [string] $Entry.sha256) { throw 'handoff_digest_mismatch' }
	}
	return $PhaseDirectory
}

function ConvertTo-DriverLiteral([string] $Value) {
	return "'" + ($Value -replace "'", "''") + "'"
}

function ConvertTo-DriverValueText($Value) {
	if ($Value -is [System.Array]) {
		return '@(' + (@($Value | ForEach-Object { ConvertTo-DriverLiteral ([string] $_) }) -join ', ') + ')'
	}
	return ConvertTo-DriverLiteral ([string] $Value)
}

function New-NamedInvocationText([string] $Target, $Parameters) {
	$Segments = New-Object System.Collections.ArrayList
	[void] $Segments.Add('&')
	[void] $Segments.Add((ConvertTo-DriverLiteral $Target))
	foreach ($Key in $Parameters.Keys) {
		[void] $Segments.Add('-' + $Key)
		[void] $Segments.Add((ConvertTo-DriverValueText $Parameters[$Key]))
	}
	return (@($Segments) -join ' ')
}

function New-PositionalInvocationText([string] $Target, [string[]] $Arguments) {
	return ('& ' + (ConvertTo-DriverLiteral $Target) + ' ' + (@($Arguments | ForEach-Object { ConvertTo-DriverLiteral $_ }) -join ' ')).TrimEnd()
}

function New-PhaseDriverBody([string] $InvocationText, [string] $CapturePath, [bool] $UseNativeExitCode) {
	$CaptureLiteral = ConvertTo-DriverLiteral $CapturePath
	$ExitCapture = if ($UseNativeExitCode) { 'if ($null -ne $LASTEXITCODE) { $GateExitCode = $LASTEXITCODE }' } else { '' }
	$Lines = @(
		'$ErrorActionPreference = ''Stop''',
		'$GateExitCode = 0',
		'try {',
		("`t" + $InvocationText + ' *> ' + $CaptureLiteral),
		("`t" + $ExitCapture),
		'} catch {',
		("`t" + '$_ | Out-String | Add-Content -LiteralPath ' + $CaptureLiteral),
		("`t" + '$GateExitCode = 1'),
		'}',
		'exit $GateExitCode'
	)
	return ($Lines -join "`r`n")
}

function Stop-PhaseProcessTree($TargetProcess, $TargetJob) {
	# RUNNER_TEST_KILL_FAULT is a fault-injection seam used only by the focused
	# fixture suite to force the taskkill fallback ('skip-job') or the
	# fail-closed cleanup-verification branch ('skip-all'); real CI never sets
	# it. Disposing the kill-on-close Job Object is the owned kill mechanism;
	# bounded taskkill and Process.Kill are fallbacks, and an unverifiable tree
	# is a stable phase_cleanup_failed failure, never a silent continuation.
	$KillFault = [Environment]::GetEnvironmentVariable('RUNNER_TEST_KILL_FAULT', 'Process')
	if ($KillFault -ne 'skip-job' -and $KillFault -ne 'skip-all' -and $null -ne $TargetJob) { $TargetJob.Dispose() }
	try { [void] $TargetProcess.WaitForExit(5000) } catch {}
	$Alive = $true
	try { $Alive = -not $TargetProcess.HasExited } catch { $Alive = $true }
	if ($Alive -and $KillFault -ne 'skip-all') {
		$TaskKill = Get-Command 'taskkill.exe' -ErrorAction SilentlyContinue
		if ($null -ne $TaskKill) {
			$KillInfo = New-Object System.Diagnostics.ProcessStartInfo
			$KillInfo.FileName = $TaskKill.Source
			$KillInfo.Arguments = ('/PID {0} /T /F' -f $TargetProcess.Id)
			$KillInfo.UseShellExecute = $false
			$KillInfo.CreateNoWindow = $true
			$KillProcess = New-Object System.Diagnostics.Process
			$KillProcess.StartInfo = $KillInfo
			try {
				if ($KillProcess.Start() -and -not $KillProcess.WaitForExit(5000)) {
					try { $KillProcess.Kill() } catch {}
					try { [void] $KillProcess.WaitForExit(1000) } catch {}
				}
			} catch {} finally { $KillProcess.Dispose() }
		}
		try { if (-not $TargetProcess.HasExited) { $TargetProcess.Kill() } } catch {}
		try { [void] $TargetProcess.WaitForExit(5000) } catch {}
	}
	$StillAlive = $true
	try { $StillAlive = -not $TargetProcess.HasExited } catch { $StillAlive = $true }
	if ($StillAlive) { throw 'phase_cleanup_failed' }
}

function Invoke-PhaseChildScript([string] $InvocationText, [double] $TimeoutMinutes, [bool] $UseNativeExitCode = $false) {
	Initialize-EngineGateJobType
	$WatchdogRoot = Join-Path $ResolvedLogs 'phase-watchdog'
	if (-not (Test-Path -LiteralPath $WatchdogRoot)) { New-Item -ItemType Directory -Path $WatchdogRoot -Force | Out-Null }
	$Token = [guid]::NewGuid().ToString('N')
	$DriverPath = Join-Path $WatchdogRoot ('driver-' + $Token + '.ps1')
	$CapturePath = Join-Path $WatchdogRoot ('capture-' + $Token + '.txt')
	Set-Content -LiteralPath $DriverPath -Value (New-PhaseDriverBody $InvocationText $CapturePath $UseNativeExitCode) -Encoding UTF8
	$PowerShellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
	$CommandLine = ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f $PowerShellPath, $DriverPath)
	$ChildJob = $null
	$ChildProcess = $null
	try {
		$ChildJob = New-Object Aetheln.EngineGateJob
		$ChildProcess = $ChildJob.StartSuspended($PowerShellPath, $CommandLine, $ResolvedRepository)
		if (-not $ChildProcess.WaitForExit([int][Math]::Ceiling($TimeoutMinutes * 60000))) {
			$CleanupFailure = $null
			try { Stop-PhaseProcessTree $ChildProcess $ChildJob } catch { $CleanupFailure = [string] $_.Exception.Message }
			return [ordered]@{ timedOut = $true; exitCode = -1; output = @(); cleanupFailure = $CleanupFailure }
		}
		$ChildProcess.WaitForExit()
		$Output = @()
		if (Test-Path -LiteralPath $CapturePath -PathType Leaf) { $Output = @(Get-Content -LiteralPath $CapturePath) }
		return [ordered]@{ timedOut = $false; exitCode = $ChildProcess.ExitCode; output = @($Output); cleanupFailure = $null }
	} finally {
		if ($null -ne $ChildProcess) { $ChildProcess.Dispose() }
		if ($null -ne $ChildJob) { $ChildJob.Dispose() }
	}
}

function Invoke-BoundedGateCommand([string] $InvocationText, [datetime] $DeadlineUtc, [bool] $UseNativeExitCode = $false) {
	$RemainingMinutes = ($DeadlineUtc - [DateTime]::UtcNow).TotalMinutes
	if ($RemainingMinutes -le 0) { throw 'phase_timeout' }
	$Result = Invoke-PhaseChildScript $InvocationText $RemainingMinutes $UseNativeExitCode
	if (-not [string]::IsNullOrWhiteSpace([string] $Result.cleanupFailure)) { throw 'phase_cleanup_failed' }
	if ($Result.timedOut) { throw 'phase_timeout' }
	return $Result
}

function Invoke-GateCommand([string] $Executable, [string[]] $Arguments) {
	if ($script:SmokeDeadlineUtc -eq [DateTime]::MaxValue) { return Invoke-Captured $Executable $Arguments }
	$Result = Invoke-BoundedGateCommand (New-PositionalInvocationText $Executable $Arguments) $script:SmokeDeadlineUtc $true
	return [ordered]@{ output = @($Result.output); exitCode = $Result.exitCode }
}

function Invoke-SmokeGateWork([string] $SearchRoot, [double] $WatchdogMinutes = 0) {
	$SmokeStarted = [DateTime]::UtcNow
	$SmokeOutput = New-Object System.Collections.ArrayList
	$SmokeProtectedValues = @($ProtectedValues)
	$SmokeFailure = $null
	$script:SmokeDeadlineUtc = if ($WatchdogMinutes -gt 0) { [DateTime]::UtcNow.AddMinutes($WatchdogMinutes) } else { [DateTime]::MaxValue }
	$ServerLauncherArgumentVector = @('-d', 'Ubuntu', '-u', 'aethelnqa', '--exec', '{ServerExecutable}', '{ServerMap}', '-port=7777', '-stdout', '-FullStdOutLogOutput')
	$ClientBaseArgumentVector = @('{ServerEndpoint}', '-stdout', '-FullStdOutLogOutput')
	try {
		$ClientCandidates = @(Get-ChildItem -LiteralPath $SearchRoot -Recurse -File | Where-Object {
			$_.Name -in @('AethelnOnlineClient.exe', 'AethelnOnline.exe')
		})
		$Clients = @($ClientCandidates | Where-Object {
			if ($_.Name -notin @('AethelnOnlineClient.exe', 'AethelnOnline.exe')) { return $false }
			$RelativePath = $_.FullName.Substring($SearchRoot.Length)
			return -not (@($RelativePath -split '[\\/]' | Where-Object { $_ -eq 'Binaries' }).Count)
		})
		if ($Clients.Count -ne 1) { throw 'client_discovery_invalid' }
		$InternalClients = @($ClientCandidates | Where-Object {
			$RelativePath = $_.FullName.Substring($SearchRoot.Length)
			$HasBinariesSegment = @($RelativePath -split '[\\/]' | Where-Object { $_ -eq 'Binaries' }).Count -gt 0
			$HasBinariesSegment -and $_.Name -eq $Clients[0].Name
		})
		if ($InternalClients.Count -lt 1) { throw 'client_discovery_invalid' }
		$Servers = @(Get-ChildItem -LiteralPath $SearchRoot -Recurse -File | Where-Object { $_.Name -eq 'AethelnOnlineServer.sh' })
		if ($Servers.Count -ne 1) { throw 'server_discovery_invalid' }

		$WslPathResult = Invoke-GateCommand 'wsl.exe' @('-d', 'Ubuntu', '-u', 'aethelnqa', '--', 'wslpath', $Servers[0].FullName)
		if ($WslPathResult.exitCode -ne 0) { throw 'wslpath_exit_nonzero' }
		$TranslatedLines = @($WslPathResult.output | ForEach-Object { [string] $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
		if ($TranslatedLines.Count -ne 1) { throw 'wslpath_line_count_invalid' }
		$LinuxServer = $TranslatedLines[0].Trim()
		if ([string]::IsNullOrWhiteSpace($LinuxServer) -or -not $LinuxServer.StartsWith('/')) { throw 'wslpath_result_invalid' }
		$SmokeProtectedValues += @($Clients[0].FullName, $Servers[0].FullName, $LinuxServer)

		$AddressResult = Invoke-GateCommand 'wsl.exe' @('-d', 'Ubuntu', '-u', 'aethelnqa', '--', 'hostname', '-I')
		if ($AddressResult.exitCode -ne 0) { throw 'wsl_address_exit_nonzero' }
		$AddressCandidates = @((($AddressResult.output -join ' ').Trim() -split '\s+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
		$UsableAddresses = @($AddressCandidates | Where-Object {
			$ParsedAddress = $null
			[System.Net.IPAddress]::TryParse($_, [ref] $ParsedAddress) -and $ParsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
		})
		if ($UsableAddresses.Count -lt 1) { throw 'wsl_address_invalid' }
		$ServerEndpoint = '{0}:7777' -f $UsableAddresses[0]
		$SmokeLogRoot = Join-Path $ResolvedLogs 'packaged-smoke'
		$SmokeProtectedValues += @($ServerEndpoint, $SmokeLogRoot)

		if ($script:SmokeDeadlineUtc -ne [DateTime]::MaxValue) {
			$SmokeParameters = [ordered]@{
				ServerExecutable = $LinuxServer
				ServerLauncherExecutable = 'wsl.exe'
				ServerLauncherArguments = $ServerLauncherArgumentVector
				ClientExecutable = $Clients[0].FullName
				ClientBaseArguments = $ClientBaseArgumentVector
				ServerEndpoint = $ServerEndpoint
				ServerMap = '/Game/Maps/StarterMap'
				LogRoot = $SmokeLogRoot
				ServerReadyPattern = 'GameNetDriver.*Listening'
				ServerClientConnectedPattern = 'AddClientConnection:.*RemoteAddr: (?<ConnectionId>[^,]+)'
				ClientConnectedPattern = 'Welcomed by server'
				ClientMapPattern = 'LoadMap:.*StarterMap'
				TimeoutSeconds = '120'
			}
			$SmokeChild = Invoke-BoundedGateCommand (New-NamedInvocationText $SmokeScript $SmokeParameters) $script:SmokeDeadlineUtc $false
			foreach ($Line in @($SmokeChild.output)) { [void] $SmokeOutput.Add($Line) }
			if ($SmokeChild.exitCode -ne 0) { throw 'smoke_failed' }
		} else {
			& $SmokeScript `
				-ServerExecutable $LinuxServer `
				-ServerLauncherExecutable 'wsl.exe' `
				-ServerLauncherArguments $ServerLauncherArgumentVector `
				-ClientExecutable $Clients[0].FullName `
				-ClientBaseArguments $ClientBaseArgumentVector `
				-ServerEndpoint $ServerEndpoint `
				-ServerMap '/Game/Maps/StarterMap' `
				-LogRoot $SmokeLogRoot `
				-ServerReadyPattern 'GameNetDriver.*Listening' `
				-ServerClientConnectedPattern 'AddClientConnection:.*RemoteAddr: (?<ConnectionId>[^,]+)' `
				-ClientConnectedPattern 'Welcomed by server' `
				-ClientMapPattern 'LoadMap:.*StarterMap' `
				-TimeoutSeconds 120 *>&1 | ForEach-Object { [void] $SmokeOutput.Add($_) }
		}
		Add-Check 'packaged-build-smoke' 'passed' $SmokeStarted 'Invoke-PackagedSmokeTest.ps1' 'smoke_passed'
	} catch {
		[void] $SmokeOutput.Add($_)
		$SafeReason = [string] $_.Exception.Message
		if ($SafeReason -notmatch '^[a-z0-9_]+$') { $SafeReason = 'smoke_failed' }
		$SmokeMessage = Get-SafeDiagnosticMessage $SafeReason $SmokeOutput $SmokeProtectedValues
		Add-Check 'packaged-build-smoke' 'failed' $SmokeStarted 'Invoke-PackagedSmokeTest.ps1' $SmokeMessage
		$SmokeFailure = $SafeReason
	} finally {
		$script:SmokeDeadlineUtc = [DateTime]::MaxValue
	}
	return $SmokeFailure
}

function Invoke-HandoffPublish([string] $PublishRunDirectory, [string] $Phase, [string[]] $Consumers) {
	$CheckStarted = [DateTime]::UtcNow
	try {
		Write-HandoffManifest $PublishRunDirectory $Phase $Consumers
		Add-Check ('handoff-publish-{0}' -f $Phase) 'passed' $CheckStarted 'write-handoff-manifest' 'handoff_published'
	} catch {
		$Reason = [string] $_.Exception.Message
		if ($Reason -notmatch '^[a-z0-9_]+$') { $Reason = 'handoff_payload_invalid' }
		Add-Check ('handoff-publish-{0}' -f $Phase) 'failed' $CheckStarted 'write-handoff-manifest' $Reason
		throw $Reason
	}
}

function Invoke-HandoffConsume([string] $ConsumeRunDirectory, [string] $Phase, [string] $ConsumingPhase) {
	$CheckStarted = [DateTime]::UtcNow
	try {
		$PhaseDirectory = Test-HandoffManifest $ConsumeRunDirectory $Phase $ConsumingPhase
		Add-Check ('handoff-consume-{0}' -f $Phase) 'passed' $CheckStarted 'verify-handoff-manifest' 'handoff_verified'
		return $PhaseDirectory
	} catch {
		$Reason = [string] $_.Exception.Message
		if ($Reason -notmatch '^[a-z0-9_]+$') { $Reason = 'handoff_schema_invalid' }
		Add-Check ('handoff-consume-{0}' -f $Phase) 'failed' $CheckStarted 'verify-handoff-manifest' $Reason
		throw $Reason
	}
}

try {
	$ResolvedRepository = Resolve-RequiredDirectory $RepositoryRoot 'repository_root_invalid'
	$ValidationStarted = [DateTime]::UtcNow
	try {
		$ProjectPath = Join-Path $ResolvedRepository 'AethelnOnline.uproject'
		$BuildScript = Join-Path $ResolvedRepository 'scripts/build/Build-PackagedArtifacts.ps1'
		$SmokeScript = Join-Path $ResolvedRepository 'scripts/build/Invoke-PackagedSmokeTest.ps1'
		if (-not (Test-Path -LiteralPath $ProjectPath -PathType Leaf)) { throw 'project_missing' }
		$EngineRoot = Resolve-RequiredDirectory ([Environment]::GetEnvironmentVariable('AETHELN_ENGINE_ROOT', 'Process')) 'engine_root_invalid'
		$ToolchainRoot = Resolve-RequiredDirectory ([Environment]::GetEnvironmentVariable('AETHELN_LINUX_TOOLCHAIN_ROOT', 'Process')) 'toolchain_root_invalid'
		$BuildBatch = Join-Path $EngineRoot 'Engine/Build/BatchFiles/Build.bat'
		if ($Mode -eq 'Compile' -and -not (Test-Path -LiteralPath $BuildBatch -PathType Leaf)) { throw 'build_batch_missing' }
		if ($Mode -in @('PackagedSmoke', 'PackageClient', 'PackageServer', 'ValidateProvenance') -and -not (Test-Path -LiteralPath $BuildScript -PathType Leaf)) { throw 'build_script_missing' }
		if ($Mode -in @('PackagedSmoke', 'SmokePhase') -and -not (Test-Path -LiteralPath $SmokeScript -PathType Leaf)) { throw 'smoke_script_missing' }
		$ResolvedArchive = if ($IsPhaseMode) { $null } else { Resolve-OutputRoot $ArchiveRoot $ResolvedRepository 'archive_root_invalid' }
		$ResolvedLogs = Resolve-OutputRoot $LogRoot $ResolvedRepository 'log_root_invalid'
		if ($SourceRevision -notmatch '^[0-9a-fA-F]{40}$') { throw 'revision_invalid' }
		Add-Check 'runner-input-validation' 'passed' $ValidationStarted 'validate-runner-inputs' 'validation_passed'
	} catch {
		Add-Check 'runner-input-validation' 'failed' $ValidationStarted 'validate-runner-inputs' ([string] $_.Exception.Message)
		throw
	}
	$ProtectedValues = @($ResolvedRepository, $ProjectPath, $BuildScript, $SmokeScript, $BuildBatch, $EngineRoot, $ToolchainRoot, $ResolvedArchive, $ResolvedLogs)

	$HandoffRoot = $null
	$ScopeRoot = $null
	$RunDirectory = $null
	$PhaseName = $null
	if ($IsPhaseMode) {
		$PhaseName = $PhaseByMode[$Mode]
		$HandoffStarted = [DateTime]::UtcNow
		try {
			Assert-PhaseContext
			$HandoffRoot = Resolve-HandoffRoot @($ResolvedRepository, $EngineRoot, $ToolchainRoot, [Environment]::GetEnvironmentVariable('RUNNER_TEMP', 'Process'), [Environment]::GetEnvironmentVariable('GITHUB_WORKSPACE', 'Process'))
			$RepositoryParts = $Repository -split '/'
			$OwnerRoot = Get-HandoffChildPath $HandoffRoot $RepositoryParts[0] 'handoff_root_invalid'
			$ScopeRoot = Get-HandoffChildPath $OwnerRoot $RepositoryParts[1] 'handoff_root_invalid'
			$RunDirectory = Get-HandoffChildPath $ScopeRoot ('run-{0}-attempt-{1}' -f $RunId, $RunAttempt) 'handoff_root_invalid'
			Assert-PathChainSafe $HandoffRoot $RunDirectory 'handoff_root_invalid'
			if (-not (Test-Path -LiteralPath $ScopeRoot)) { New-Item -ItemType Directory -Path $ScopeRoot -Force | Out-Null }
			Add-Check 'handoff-validation' 'passed' $HandoffStarted 'validate-handoff-context' 'handoff_context_valid'
		} catch {
			$Reason = [string] $_.Exception.Message
			if ($Reason -notmatch '^[a-z0-9_]+$') { $Reason = 'handoff_root_invalid' }
			Add-Check 'handoff-validation' 'failed' $HandoffStarted 'validate-handoff-context' $Reason
			throw $Reason
		}
		$ProtectedValues += @($HandoffRoot, $ScopeRoot, $RunDirectory)

		if ($Mode -eq 'PackageClient') {
			$StorageStarted = [DateTime]::UtcNow
			try {
				Write-CleanupRequest $ScopeRoot $PhaseName
				# The committed measurement spans the complete validated handoff
				# root, so every repository scope counts toward the total cap.
				# Reparse points are never traversed or counted: their content
				# does not live under the root.
				$CommittedBytes = Get-DirectoryBytes $HandoffRoot 'handoff_storage_exhausted' $true
				if ($CommittedBytes -gt ($HandoffRootCapBytes - $HandoffPayloadCapBytes)) { throw 'handoff_storage_exhausted' }
				if (Test-Path -LiteralPath $RunDirectory) { throw 'handoff_conflict' }
				New-Item -ItemType Directory -Path $RunDirectory | Out-Null
				Write-RunContextRecord
				Add-Check 'handoff-storage-accounting' 'passed' $StorageStarted 'reserve-handoff-storage' 'handoff_storage_reserved'
			} catch {
				$Reason = [string] $_.Exception.Message
				if ($Reason -notmatch '^[a-z0-9_]+$') { $Reason = 'handoff_storage_exhausted' }
				Add-Check 'handoff-storage-accounting' 'failed' $StorageStarted 'reserve-handoff-storage' $Reason
				throw $Reason
			}
		} else {
			$RunContextStarted = [DateTime]::UtcNow
			try {
				if (-not (Test-Path -LiteralPath $RunDirectory -PathType Container)) { throw 'handoff_missing' }
				[void] (Test-RunContextRecord $RunDirectory $true)
				Add-Check 'handoff-run-directory' 'passed' $RunContextStarted 'validate-handoff-run-context' 'handoff_run_context_valid'
			} catch {
				$Reason = [string] $_.Exception.Message
				if ($Reason -notmatch '^[a-z0-9_]+$') { $Reason = 'handoff_context_invalid' }
				Add-Check 'handoff-run-directory' 'failed' $RunContextStarted 'validate-handoff-run-context' $Reason
				throw $Reason
			}
		}
	}

	Assert-RepositoryState 'repository-state-before-work'

	if ($Mode -eq 'Compile') {
		$Targets = @(
			[ordered]@{ name = 'incremental-client-build'; label = 'AethelnOnlineClient Win64 Development'; arguments = @('AethelnOnlineClient', 'Win64', 'Development', $ProjectPath, '-WaitMutex', '-NoHotReloadFromIDE') },
			[ordered]@{ name = 'incremental-server-build'; label = 'AethelnOnlineServer Linux Development'; arguments = @('AethelnOnlineServer', 'Linux', 'Development', $ProjectPath, '-WaitMutex', '-NoHotReloadFromIDE') }
		)
		foreach ($Target in $Targets) {
			$BuildStarted = [DateTime]::UtcNow
			$BuildResult = Invoke-Captured $BuildBatch $Target.arguments
			$BuildFailure = $null
			if ($BuildResult.exitCode -ne 0) {
				$BuildMessage = Get-SafeDiagnosticMessage 'build_failed' $BuildResult.output $ProtectedValues
				Add-Check $Target.name 'failed' $BuildStarted $Target.label $BuildMessage
				$BuildFailure = 'build_failed'
			} else {
				Add-Check $Target.name 'passed' $BuildStarted $Target.label 'build_passed'
			}
			Complete-CommandStateCheck ($Target.name + '-repository-state') $BuildFailure
		}
		Assert-RepositoryState 'repository-state-at-completion'
	} elseif ($Mode -eq 'PackagedSmoke') {
		$BuildStarted = [DateTime]::UtcNow
		$BuildOutput = New-Object System.Collections.ArrayList
		$BuildFailure = $null
		try {
			& $BuildScript -ProjectPath $ProjectPath -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot $ResolvedArchive -LogRoot $ResolvedLogs -SourceRevision $SourceRevision -Configuration Development -Map '/Game/Maps/StarterMap' *>&1 | ForEach-Object { [void] $BuildOutput.Add($_) }
			Add-Check 'clean-packaged-client-server-build' 'passed' $BuildStarted 'Build-PackagedArtifacts.ps1' 'build_passed'
		} catch {
			[void] $BuildOutput.Add($_)
			$BuildMessage = Get-SafeDiagnosticMessage 'build_failed' $BuildOutput $ProtectedValues
			Add-Check 'clean-packaged-client-server-build' 'failed' $BuildStarted 'Build-PackagedArtifacts.ps1' $BuildMessage
			$BuildFailure = 'build_failed'
		}

		Complete-CommandStateCheck 'repository-state-after-package' $BuildFailure

		$SmokeFailure = Invoke-SmokeGateWork $ResolvedArchive

		Complete-CommandStateCheck 'repository-state-at-completion' $SmokeFailure
	} elseif ($Mode -eq 'PackageClient' -or $Mode -eq 'PackageServer') {
		$PhaseDirectory = Get-HandoffChildPath $RunDirectory $PhaseName 'handoff_conflict'
		$CheckName = 'scheduled-{0}-package' -f $PhaseName
		if ((Test-Path -LiteralPath $PhaseDirectory) -or (Test-Path -LiteralPath (Join-Path $RunDirectory ('manifest-{0}.json' -f $PhaseName)))) {
			Add-Check $CheckName 'failed' ([DateTime]::UtcNow) 'Build-PackagedArtifacts.ps1' 'handoff_conflict'
			throw 'handoff_conflict'
		}
		$Stage = if ($Mode -eq 'PackageClient') { 'Client' } else { 'Server' }
		$PhaseParameters = [ordered]@{
			Stage = $Stage
			ProjectPath = $ProjectPath
			EngineRoot = $EngineRoot
			LinuxToolchainRoot = $ToolchainRoot
			ArchiveRoot = $PhaseDirectory
			LogRoot = (Join-Path $ResolvedLogs $PhaseName)
			SourceRevision = $SourceRevision
			Configuration = 'Development'
			Map = '/Game/Maps/StarterMap'
		}
		$BuildStarted = [DateTime]::UtcNow
		$PhaseResult = Invoke-PhaseChildScript (New-NamedInvocationText $BuildScript $PhaseParameters) $PhaseTimeoutMinutes
		$BuildFailure = $null
		if ($PhaseResult.timedOut) {
			$TimeoutReason = if ([string]::IsNullOrWhiteSpace([string] $PhaseResult.cleanupFailure)) { 'phase_timeout' } else { 'phase_cleanup_failed' }
			Add-Check $CheckName 'failed' $BuildStarted 'Build-PackagedArtifacts.ps1' $TimeoutReason
			$BuildFailure = $TimeoutReason
		} elseif ($PhaseResult.exitCode -ne 0) {
			$BuildMessage = Get-SafeDiagnosticMessage 'build_failed' $PhaseResult.output $ProtectedValues
			Add-Check $CheckName 'failed' $BuildStarted 'Build-PackagedArtifacts.ps1' $BuildMessage
			$BuildFailure = 'build_failed'
		} else {
			Add-Check $CheckName 'passed' $BuildStarted 'Build-PackagedArtifacts.ps1' 'build_passed'
		}
		Complete-CommandStateCheck ('repository-state-after-{0}-package' -f $PhaseName) $BuildFailure

		Invoke-HandoffPublish $RunDirectory $PhaseName @('provenance', 'smoke')
		Assert-RepositoryState 'repository-state-at-completion'
	} elseif ($Mode -eq 'ValidateProvenance') {
		$ClientDirectory = Invoke-HandoffConsume $RunDirectory 'client' 'provenance'
		$ServerDirectory = Invoke-HandoffConsume $RunDirectory 'server' 'provenance'
		$PhaseDirectory = Get-HandoffChildPath $RunDirectory $PhaseName 'handoff_conflict'
		if ((Test-Path -LiteralPath $PhaseDirectory) -or (Test-Path -LiteralPath (Join-Path $RunDirectory ('manifest-{0}.json' -f $PhaseName)))) {
			Add-Check 'registry-provenance-validation' 'failed' ([DateTime]::UtcNow) 'Build-PackagedArtifacts.ps1' 'handoff_conflict'
			throw 'handoff_conflict'
		}
		$PhaseParameters = [ordered]@{
			Stage = 'Provenance'
			ProjectPath = $ProjectPath
			EngineRoot = $EngineRoot
			LinuxToolchainRoot = $ToolchainRoot
			ArchiveRoot = $PhaseDirectory
			LogRoot = (Join-Path $ResolvedLogs $PhaseName)
			SourceRevision = $SourceRevision
			Configuration = 'Development'
			Map = '/Game/Maps/StarterMap'
			ClientStageRoot = $ClientDirectory
			ServerStageRoot = $ServerDirectory
		}
		$BuildStarted = [DateTime]::UtcNow
		$PhaseResult = Invoke-PhaseChildScript (New-NamedInvocationText $BuildScript $PhaseParameters) $PhaseTimeoutMinutes
		$BuildFailure = $null
		if ($PhaseResult.timedOut) {
			$TimeoutReason = if ([string]::IsNullOrWhiteSpace([string] $PhaseResult.cleanupFailure)) { 'phase_timeout' } else { 'phase_cleanup_failed' }
			Add-Check 'registry-provenance-validation' 'failed' $BuildStarted 'Build-PackagedArtifacts.ps1' $TimeoutReason
			$BuildFailure = $TimeoutReason
		} elseif ($PhaseResult.exitCode -ne 0) {
			$BuildMessage = Get-SafeDiagnosticMessage 'validation_failed' $PhaseResult.output $ProtectedValues
			Add-Check 'registry-provenance-validation' 'failed' $BuildStarted 'Build-PackagedArtifacts.ps1' $BuildMessage
			$BuildFailure = 'validation_failed'
		} else {
			Add-Check 'registry-provenance-validation' 'passed' $BuildStarted 'Build-PackagedArtifacts.ps1' 'validation_passed'
		}
		Complete-CommandStateCheck 'repository-state-after-provenance-validation' $BuildFailure

		Invoke-HandoffPublish $RunDirectory $PhaseName @('smoke')
		Assert-RepositoryState 'repository-state-at-completion'
	} else {
		[void] (Invoke-HandoffConsume $RunDirectory 'client' 'smoke')
		[void] (Invoke-HandoffConsume $RunDirectory 'server' 'smoke')
		[void] (Invoke-HandoffConsume $RunDirectory 'provenance' 'smoke')

		$SmokeFailure = Invoke-SmokeGateWork $RunDirectory $PhaseTimeoutMinutes

		$MarkerStarted = [DateTime]::UtcNow
		try {
			if ($SmokeFailure -eq 'phase_timeout' -or $SmokeFailure -eq 'phase_cleanup_failed') {
				# A timed-out smoke never publishes a completion marker: the
				# work is unfinished and must not become cleanup-eligible as a
				# completed milestone. Evidence is still recorded.
				Write-CleanupRequest $ScopeRoot $PhaseName
				Add-Check 'handoff-milestone-completion' 'failed' $MarkerStarted 'write-milestone-marker' 'milestone_incomplete'
			} else {
				Write-JsonAtomic ([ordered]@{
					schemaVersion = 1
					repository = $Repository
					sourceRevision = $SourceRevision
					runId = $RunId
					runAttempt = $RunAttempt
					runnerName = $RunnerName
					state = $(if ($SmokeFailure) { 'failed' } else { 'passed' })
					finishedUtc = [DateTime]::UtcNow.ToString('o')
				}) (Join-Path $RunDirectory 'milestone-complete.json')
				Write-CleanupRequest $ScopeRoot $PhaseName
				Add-Check 'handoff-milestone-completion' 'passed' $MarkerStarted 'write-milestone-marker' 'milestone_recorded'
			}
		} catch {
			Add-Check 'handoff-milestone-completion' 'failed' $MarkerStarted 'write-milestone-marker' 'milestone_record_failed'
			if ([string]::IsNullOrWhiteSpace($SmokeFailure)) { $SmokeFailure = 'milestone_record_failed' }
		}

		Complete-CommandStateCheck 'repository-state-at-completion' $SmokeFailure
	}
} catch {
	$RequiredFailed = $true
	$FailureCode = [string] $_.Exception.Message
	if ($FailureCode -notmatch '^[a-z0-9_]+$') { $FailureCode = 'engine_runner_failed' }
} finally {
	try { Write-RunnerReport } catch { $RequiredFailed = $true; $FailureCode = 'report_write_failed' }
}

if ($RequiredFailed) {
	Write-Error $FailureCode
	exit 1
}
Write-Output 'engine_runner_passed'
exit 0
