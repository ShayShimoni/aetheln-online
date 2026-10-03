<#
.SYNOPSIS
Runs engine-dependent compile, packaged-smoke, or scheduled milestone phase gates on an approved runner.
.DESCRIPTION
Compile runs its complete controlled body under a kill-on-close supervisor
with one CompileTimeoutMinutes budget (default/max 30) anchored at script
start and a two-second finalization grace, followed by bounded tree cleanup.
ReportPath optionally selects a fresh local absolute report file; preexisting
explicit evidence is rejected and never overwritten. PackagedSmoke preserves
the original single-job gate. The phase
modes (PackageClient, PackageServer, ValidateProvenance, SmokePhase) split the
scheduled clean-package milestone into bounded jobs that exchange outputs only
through the durable run-scoped handoff store under AETHELN_HANDOFF_ROOT, with
fail-closed integrity manifests and a run-context record binding each run
directory to its producing context. Every phase runs under a hard-bounded
supervisor: after input validation the parent process re-invokes this script as
a supervised child inside an owned kill-on-close Windows Job Object, so the
complete controlled gate interval - handoff validation, cleanup scanning, root
accounting, manifest reads, payload hashing, smoke discovery, the build/smoke
grandchild, and timeout finalization - runs in that child tree. The child keeps
the cooperative absolute script-phase deadline (established immediately after
input validation and sized below the job timeout; every operation consumes
remaining time from it rather than receiving a fresh watchdog duration) for
precise per-check evidence, and its post-timeout finalization is itself bounded
by PhaseFinalizeGraceSeconds: if any synchronous operation blocks across the
deadline, the parent stops and verifies the whole child tree at deadline plus
grace, classifies phase_timeout (or phase_cleanup_failed when tree termination
cannot be verified), and writes the bounded report itself - so evidence is
published only while platform job time remains; cancellation or runner loss
can prevent publication and missing evidence never establishes success. The bound covers
only the gate-script interval: checkout/LFS and report upload sit inside the
workflow job bound, and a report cannot be preserved if the platform kills the
job before this script starts. Handoff directories are never deleted here; eligible
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
	[string] $ManagedWorkspaceRoot,
	[string] $ManagedWorkspaceRegistrationPath,
	[string] $ManagedWorkspaceRegistrationSha256,
	[string] $HostLeasePath,
	[string] $CompileStartedUtc,
	[long] $CompileStartedTimestamp = 0,
	[double] $CompileTimeoutMinutes = 30,
	[string] $ReportPath,
	[double] $PhaseTimeoutMinutes = 0,
	[long] $HandoffPayloadCapBytes = 68719476736,
	[long] $HandoffRootCapBytes = 274877906944,
	[double] $HandoffStaleHours = 48,
	[double] $PhaseFinalizeGraceSeconds = 120,
	[Parameter(DontShow)] [string] $PhaseSupervisorNonce,
	[Parameter(DontShow)] [string] $PhaseSupervisorParentProcessId,
	[Parameter(DontShow)] [string] $PhaseSupervisorParentStartTicks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Started = [DateTime]::UtcNow
$ExplicitReportRequested = $PSBoundParameters.ContainsKey('ReportPath')
$CompileSupervisorContext = Get-Variable -Name AethelnCompileGateContext -Scope Global -ValueOnly -ErrorAction SilentlyContinue
$IsCompileChild = $Mode -eq 'Compile' -and $null -ne $CompileSupervisorContext
if ($IsCompileChild) { $Started = [DateTime]::Parse($CompileSupervisorContext.startedUtc).ToUniversalTime() }
$ResolvedReportPath = $null
$RelayedReport = $null
$SupervisorReceipt = $null
$ManagedRegistration = $null
$ManagedWorkspaceEvidence = $null
$RoutineResourceMonitor = $null
$RoutineDeadline = $null
$ManagedCompile = $PSBoundParameters.ContainsKey('ManagedWorkspaceRoot')
$CompileDeadlineUtc = [DateTime]::MaxValue
$Checks = New-Object System.Collections.ArrayList
$RequiredFailed = $false
$SupervisedChildExited = $false
$FailureCode = $null
$ResolvedRepository = $null
$PhaseByMode = @{ PackageClient = 'client'; PackageServer = 'server'; ValidateProvenance = 'provenance'; SmokePhase = 'smoke' }
$IsPhaseMode = $PhaseByMode.ContainsKey($Mode)
$PhaseSupervisorMarker = [Environment]::GetEnvironmentVariable('AETHELN_PHASE_SUPERVISED', 'Process')
$PhaseSupervisorEnvironmentNonce = [Environment]::GetEnvironmentVariable('AETHELN_PHASE_SUPERVISOR_NONCE', 'Process')
$PhaseSupervisorEnvironmentParentProcessId = [Environment]::GetEnvironmentVariable('AETHELN_PHASE_SUPERVISOR_PARENT_PROCESS_ID', 'Process')
$PhaseSupervisorEnvironmentParentStartTicks = [Environment]::GetEnvironmentVariable('AETHELN_PHASE_SUPERVISOR_PARENT_START_TICKS', 'Process')
$HasPhaseSupervisorAuthenticationSignal = $null -ne $PhaseSupervisorMarker -or
	$null -ne $PhaseSupervisorEnvironmentNonce -or
	$null -ne $PhaseSupervisorEnvironmentParentProcessId -or
	$null -ne $PhaseSupervisorEnvironmentParentStartTicks -or
	$PSBoundParameters.ContainsKey('PhaseSupervisorNonce') -or
	$PSBoundParameters.ContainsKey('PhaseSupervisorParentProcessId') -or
	$PSBoundParameters.ContainsKey('PhaseSupervisorParentStartTicks')
$IsAuthenticatedPhaseChild = $false
$PhaseSupervisorAuthenticationInvalid = $false
$Policy = if ($Mode -eq 'Compile') { 'incremental-target-compilation' } else { 'clean-package-and-smoke' }
$RepositoryPattern = '^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$'
$RunnerNamePattern = '^[^\\/:*?"<>|\x00-\x1f]{1,128}$'
$ManifestPropertyNames = @('schemaVersion', 'repository', 'sourceRevision', 'runId', 'runAttempt', 'producingPhase', 'expectedConsumingPhases', 'runnerName', 'files', 'totalBytes', 'createdUtc')
$RunContextPropertyNames = @('schemaVersion', 'repository', 'sourceRevision', 'runId', 'runAttempt', 'runnerName', 'createdUtc')
$MarkerPropertyNames = @('schemaVersion', 'repository', 'sourceRevision', 'runId', 'runAttempt', 'runnerName', 'state', 'finishedUtc')
$SmokeDeadlineUtc = [DateTime]::MaxValue
$PhaseDeadlineUtc = [DateTime]::MaxValue
# Report-only compile evidence: identity of the compile inputs plus bounded
# observations extracted from captured build output. It never changes gate
# behavior; missing observations stay explicitly unavailable/not_observed.
$CompileEvidenceIdentity = $null
$CompileBuilds = New-Object System.Collections.ArrayList
$UbtTargetNames = @('AethelnOnlineClient', 'AethelnOnlineServer', 'AethelnOnlineEditor', 'UnrealEditor', 'UnrealPak', 'ShaderCompileWorker')
$UbtMakefileReasons = @{
	# Closed allowlist of the pinned UnrealBuildTool makefile-reload reasons
	# (TargetMakefile.cs / BuildMode.cs); anything else is recorded as 'other'.
	'no existing makefile' = 'no_existing_makefile'
	"couldn't read existing makefile" = 'unreadable_existing_makefile'
	'makefile version does not match' = 'makefile_version_mismatch'
	'makefile VProject availability does not match' = 'vproject_availability_mismatch'
	'working set of source files changed' = 'working_set_changed'
	'command line arguments changed' = 'command_line_changed'
	'build metadata has changed' = 'build_metadata_changed'
	'config setting changed' = 'config_setting_changed'
	'.uproject file is newer' = 'uproject_newer'
	'Build.version is newer' = 'build_version_newer'
	'BuildConfiguration.xml is newer' = 'build_configuration_newer'
	'UnrealBuildTool assembly is newer' = 'ubt_assembly_newer'
	'EpicGames.UHT assembly is newer' = 'uht_assembly_newer'
	'UHT files changed' = 'uht_files_changed'
	'Available UBT plugins changed' = 'ubt_plugins_changed'
	'Enabled UBT plugins need to be recompiled' = 'ubt_plugins_recompile'
}

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
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job, uint exitCode);
  [StructLayout(LayoutKind.Sequential)] struct BasicAccountingInformation { public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime; public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses; }
  [StructLayout(LayoutKind.Sequential)] struct ProcessBasicInformation { public IntPtr Reserved1, PebBaseAddress, Reserved2_0, Reserved2_1, UniqueProcessId, InheritedFromUniqueProcessId; }
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int informationClass, out BasicAccountingInformation information, uint length, IntPtr returnLength);
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int informationClass, out ProcessBasicInformation information, uint length, IntPtr returnLength);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  public static int GetCurrentParentProcessId() {
   using(System.Diagnostics.Process process=System.Diagnostics.Process.GetCurrentProcess()) {
    ProcessBasicInformation information; int status=NtQueryInformationProcess(process.Handle,0,out information,(uint)Marshal.SizeOf(typeof(ProcessBasicInformation)),IntPtr.Zero);
    if(status!=0) throw new InvalidOperationException("Parent process identity is unavailable.");
    long parent=information.InheritedFromUniqueProcessId.ToInt64(); if(parent<=0 || parent>Int32.MaxValue) throw new InvalidOperationException("Parent process identity is invalid.");
    return (int)parent;
   }
  }
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
  public void TerminateAndWait(int milliseconds) {
   if(handle==IntPtr.Zero) throw new ObjectDisposedException("EngineGateJob");
   if(!TerminateJobObject(handle,1)) throw new Win32Exception(Marshal.GetLastWin32Error(),"TerminateJobObject failed.");
   System.Diagnostics.Stopwatch timer=System.Diagnostics.Stopwatch.StartNew();
   do {
    BasicAccountingInformation information;
    if(!QueryInformationJobObject(handle,1,out information,(uint)Marshal.SizeOf(typeof(BasicAccountingInformation)),IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error(),"QueryInformationJobObject failed.");
    if(information.ActiveProcesses==0) return;
    System.Threading.Thread.Sleep(10);
   } while(timer.ElapsedMilliseconds<milliseconds);
   throw new TimeoutException("Job process termination could not be verified.");
  }
  ~EngineGateJob() { Dispose(); }
 }
}
"@

function Initialize-EngineGateJobType {
	if ($null -eq ('Aetheln.EngineGateJob' -as [type])) { Add-Type -TypeDefinition $EngineGateJobSource -Language CSharp }
}

function Test-PhaseSupervisorAuthentication(
	[string] $Marker,
	[string] $EnvironmentNonce,
	[string] $EnvironmentParentProcessId,
	[string] $EnvironmentParentStartTicks,
	[string] $ParameterNonce,
	[string] $ParameterParentProcessId,
	[string] $ParameterParentStartTicks,
	[long] $ActualParentProcessId,
	[long] $ActualParentStartTicks
) {
	# Child admission is a closed, run-scoped contract. The nonce prevents an
	# inherited marker from acting as authority, while PID plus process start
	# time binds that nonce to the direct parent and rejects stale PID reuse.
	if ($Marker -cne '1' -or
		$EnvironmentNonce -cnotmatch '^[0-9a-f]{64}$' -or $ParameterNonce -cnotmatch '^[0-9a-f]{64}$' -or
		$EnvironmentParentProcessId -cnotmatch '^[1-9][0-9]{0,9}$' -or $ParameterParentProcessId -cnotmatch '^[1-9][0-9]{0,9}$' -or
		$EnvironmentParentStartTicks -cnotmatch '^[1-9][0-9]{0,18}$' -or $ParameterParentStartTicks -cnotmatch '^[1-9][0-9]{0,18}$' -or
		$EnvironmentNonce -cne $ParameterNonce -or
		$EnvironmentParentProcessId -cne $ParameterParentProcessId -or
		$EnvironmentParentStartTicks -cne $ParameterParentStartTicks) { return $false }
	$ExpectedParentProcessId = 0
	$ExpectedParentStartTicks = [long] 0
	if (-not [int]::TryParse($ParameterParentProcessId, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref] $ExpectedParentProcessId) -or
		-not [long]::TryParse($ParameterParentStartTicks, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref] $ExpectedParentStartTicks)) { return $false }
	return $ActualParentProcessId -eq $ExpectedParentProcessId -and $ActualParentStartTicks -eq $ExpectedParentStartTicks
}

function Assert-PhaseDeadline {
	if ([DateTime]::UtcNow -ge $script:PhaseDeadlineUtc) { throw 'phase_timeout' }
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

function Assert-RoutineCompileProgress {
	$null = Get-RoutineCompileRemainingMillisecondCount -Deadline $RoutineDeadline
	if ($null -ne $RoutineResourceMonitor) { $null = Update-RoutineCompileResources -Monitor $RoutineResourceMonitor }
}

function Initialize-ManagedCompileResourceMonitor {
	# Discovery and all probes run in the already supervised, lease-owned child.
	$script:EngineRoot = Resolve-RequiredDirectory ([Environment]::GetEnvironmentVariable('AETHELN_ENGINE_ROOT', 'Process')) 'engine_root_invalid'
	$script:ToolchainRoot = Resolve-RequiredDirectory ([Environment]::GetEnvironmentVariable('AETHELN_LINUX_TOOLCHAIN_ROOT', 'Process')) 'toolchain_root_invalid'
	$script:ResolvedLogs = Resolve-OutputRoot -Value $LogRoot -Repository $ResolvedRepository -ReasonCode 'log_root_invalid'
	if (-not (Test-Path -LiteralPath $ResolvedLogs)) { $null = New-Item -ItemType Directory -Path $ResolvedLogs }
	$Roots = [ordered]@{
		control = $RepositoryRoot; target = $ManagedWorkspaceRoot
		engine = $EngineRoot; toolchain = $ToolchainRoot
		evidence = $ResolvedLogs; temporary = [IO.Path]::GetTempPath()
		git = $ManagedRegistration.record.gitCommonDirectory
	}
	$script:RoutineResourceMonitor = New-RoutineCompileResourceMonitor -Roots $Roots
	Assert-RoutineCompileProgress
}

function Invoke-RoutineManagedBuild {
	param([Parameter(Mandatory)] $Target)
	Assert-RoutineCompileProgress
	$Limit = Get-RoutineCompileActionLimit -Monitor $RoutineResourceMonitor
	$EvidenceRoot = Join-Path $ResolvedLogs ('routine-' + $Target.target + '-' + [guid]::NewGuid().ToString('N'))
	$null = New-Item -ItemType Directory -Path $EvidenceRoot
	$Invocation = Join-Path $PSScriptRoot 'InitialPreparation.BuildInvocation.ps1'
	$Parameters = @('-Target', $Target.target, '-Platform', $Target.platform, '-ActionLimit', $Limit.ToString([Globalization.CultureInfo]::InvariantCulture),
		'-EngineRoot', $EngineRoot, '-TargetRoot', $ResolvedRepository, '-LinuxToolchainRoot', $ToolchainRoot, '-EvidenceRoot', $EvidenceRoot)
	$Result = Invoke-RoutineCompileCommand -Executable $Invocation -Arguments $Parameters -WorkingDirectory $ResolvedRepository -OnProgress { Assert-RoutineCompileProgress }
	Assert-RoutineCompileProgress
	$Pins = @()
	try {
		$ReceiptPath = Join-Path $EvidenceRoot 'native-result.json'
		$BuildLog = Join-Path $EvidenceRoot 'build.log'
		Initialize-ManagedWorkspaceNative
		foreach ($Path in @($ReceiptPath, $BuildLog)) {
			$Pins += [Aetheln.ManagedWorkspaceGit]::OpenPlain($Path, $false)
		}
		if ((Get-Item -LiteralPath $ReceiptPath).Length -gt 8192 -or (Get-Item -LiteralPath $BuildLog).Length -gt 16777216) { throw 'routine_build_evidence_oversized' }
		$Receipt = Read-JsonStrict -Path $ReceiptPath -ReasonCode 'routine_build_receipt_invalid'
		Assert-ClosedObject -Value $Receipt -PropertyNames @('schemaVersion', 'target', 'platform', 'nativeExitCode', 'infrastructureFailure') -ReasonCode 'routine_build_receipt_invalid'
		if ($Receipt.schemaVersion -isnot [int] -or $Receipt.schemaVersion -ne 1 -or
			$Receipt.target -cne $Target.target -or $Receipt.platform -cne $Target.platform -or
			$Receipt.nativeExitCode -isnot [int] -or $null -ne $Receipt.infrastructureFailure -or
			$Result.exitCode -isnot [int] -or $Receipt.nativeExitCode -ne $Result.exitCode) { throw 'routine_build_receipt_invalid' }
		$Output = New-Object 'Collections.Generic.List[string]'
		$Reader = New-Object IO.StreamReader($BuildLog, [Text.Encoding]::UTF8)
		try {
			while ($null -ne ($Line = $Reader.ReadLine())) {
				if ($Output.Count -ge 65536) { throw 'routine_build_evidence_oversized' }
				$Output.Add($Line)
				if (($Output.Count % 256) -eq 0) { Assert-RoutineCompileProgress }
			}
		} finally { $Reader.Dispose() }
		Assert-RoutineCompileProgress
		return [ordered]@{ exitCode = $Receipt.nativeExitCode; output = [string[]] $Output.ToArray() }
	} catch {
		if ($_.Exception.Message -cmatch '^(routine_build_|resource_|disk_|compile_)[a-z_]+$') { throw }
		throw 'routine_build_evidence_invalid'
	} finally { foreach ($Pin in $Pins) { $Pin.Dispose() } }
}

function Invoke-Captured([string] $Executable, [string[]] $Arguments) {
	if ($ManagedCompile -and $IsCompileChild) {
		if (-not [IO.Path]::IsPathRooted($Executable)) { $Executable = (Get-Command -Name $Executable -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source }
		return Invoke-RoutineCompileCommand -Executable $Executable -Arguments $Arguments -WorkingDirectory $ResolvedRepository -OnProgress { Assert-RoutineCompileProgress }
	}
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
		Add-Check -Name $Name -Status 'passed' -CheckStarted $CheckStarted -Command 'git-revision-and-status' -Message 'repository_state_valid'
	} catch {
		$Reason = [string] $_.Exception.Message
		if ($Reason -notmatch '^[a-z0-9_]+$') { $Reason = 'repository_state_invalid' }
		Add-Check -Name $Name -Status 'failed' -CheckStarted $CheckStarted -Command 'git-revision-and-status' -Message $Reason
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

function Resolve-CompileEvidenceIdentity {
	# Same field names, commands, and verified/dirty/unavailable vocabulary as
	# Resolve-EvidenceIdentity in Build-PackagedArtifacts.ps1, so the uploaded
	# report and build-timing.json are comparable. Normalized identifiers only
	# (commit SHA, content hashes, validated runner name); never fails the run.
	$IdentityStarted = [DateTime]::UtcNow
	$Identity = [ordered]@{
		engineGitRevision = $null
		engineGitRevisionStatus = 'unavailable'
		engineBuildVersionSha256 = $null
		engineBuildVersionSha256Status = 'unavailable'
		linuxToolchainCompilerSha256 = $null
		linuxToolchainCompilerSha256Status = 'unavailable'
		runnerName = $(if ($RunnerName -match $RunnerNamePattern) { $RunnerName } else { $null })
		durationSeconds = 0
	}
	try {
		$RevisionResult = Invoke-Captured 'git' @('-C', $EngineRoot, 'rev-parse', 'HEAD')
		$RevisionLines = @($RevisionResult.output | ForEach-Object { ([string] $_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
		if ($RevisionResult.exitCode -eq 0 -and $RevisionLines.Count -eq 1 -and $RevisionLines[0] -match '^[0-9a-fA-F]{40}$') {
			$StatusResult = Invoke-Captured 'git' @('-C', $EngineRoot, 'status', '--porcelain=v1', '--untracked-files=all')
			if ($StatusResult.exitCode -eq 0) {
				$Identity.engineGitRevision = $RevisionLines[0].ToLowerInvariant()
				$Identity.engineGitRevisionStatus = if (@($StatusResult.output | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) }).Count -eq 0) { 'verified' } else { 'dirty' }
			}
		}
	} catch { Write-Verbose "Engine Git identity probe failed, so the engine revision fields stay unavailable: $($_.Exception.Message)" }
	try {
		$VersionPath = Join-Path $EngineRoot 'Engine/Build/Build.version'
		if (Test-Path -LiteralPath $VersionPath -PathType Leaf) {
			$Identity.engineBuildVersionSha256 = (Get-FileHash -LiteralPath $VersionPath -Algorithm SHA256).Hash.ToLowerInvariant()
			$Identity.engineBuildVersionSha256Status = 'verified'
		}
	} catch { Write-Verbose "Engine Build.version hash probe failed, so that identity field stays unavailable: $($_.Exception.Message)" }
	try {
		foreach ($Candidate in @('x86_64-unknown-linux-gnu/bin/clang++.exe', 'x86_64-unknown-linux-gnu/bin/clang.exe', 'x86_64-unknown-linux-gnu/bin/clang.bat')) {
			$CompilerPath = Join-Path $ToolchainRoot $Candidate
			if (Test-Path -LiteralPath $CompilerPath -PathType Leaf) {
				$Identity.linuxToolchainCompilerSha256 = (Get-FileHash -LiteralPath $CompilerPath -Algorithm SHA256).Hash.ToLowerInvariant()
				$Identity.linuxToolchainCompilerSha256Status = 'verified'
				break
			}
		}
	} catch { Write-Verbose "Linux toolchain compiler hash probe failed, so that identity field stays unavailable: $($_.Exception.Message)" }
	$Identity.durationSeconds = [Math]::Round(([DateTime]::UtcNow - $IdentityStarted).TotalSeconds, 3)
	return $Identity
}

function Get-CompileObservation([object[]] $Output) {
	# Bounded, path-free extraction from captured UnrealBuildTool output: the
	# last '[n/total]' action counter seen in output order, the planned action
	# count, makefile creation lines with an allowlisted reason token, and the
	# up-to-date marker. Absence is recorded as not_observed, never as zero.
	$Observation = [ordered]@{
		outputState = 'captured'
		lastObservedAction = $null
		observedTotalActions = $null
		actionCounterState = 'not_observed'
		plannedActionCount = $null
		observedTargetNames = $null
		makefileObservation = 'not_observed'
		makefileReason = $null
		makefileCreationCount = 0
		upToDateObserved = $false
		executorSummaryCount = 0
	}
	$Names = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
	foreach ($Record in @($Output)) {
		$Line = ([string] $Record).Trim()
		if ($Line -match '^(?:.*?\s)?\[(\d{1,7})/(\d{1,7})\](?:\[([A-Za-z0-9_]+) [A-Za-z0-9_]+ [A-Za-z0-9_]+\])?') {
			$Completed = [int] $Matches[1]
			$Total = [int] $Matches[2]
			if ($Completed -ge 1 -and $Completed -le $Total) {
				$Observation.lastObservedAction = $Completed
				$Observation.observedTotalActions = $Total
				$Observation.actionCounterState = 'observed'
				# Target metadata counts only when its enclosing counter is valid.
				if ($Matches.ContainsKey(3)) { [void] $Names.Add($(if ($Matches[3] -cin $UbtTargetNames) { $Matches[3] } else { 'other' })) }
			}
		} elseif ($Line -match '^(?:.*?\s)?Creating makefile for [A-Za-z0-9_]+ \((.+)\)$') {
			$Observation.makefileObservation = 'created'
			$Observation.makefileCreationCount++
			$Observation.makefileReason = $(if ($UbtMakefileReasons.ContainsKey($Matches[1])) { $UbtMakefileReasons[$Matches[1]] } else { 'other' })
		} elseif ($Line -match '(?:^|\s)Target is up to date$') {
			$Observation.upToDateObserved = $true
		} elseif ($Line -match '(?:^|\s)Using [A-Za-z0-9 ]+ executor to run (\d{1,7}) action\(s\)$') {
			$Observation.plannedActionCount = [int] $Matches[1]
		} elseif ($Line -match '(?:^|\s)Total time in [A-Za-z0-9 ]+ executor: ') {
			$Observation.executorSummaryCount++
		}
	}
	if ($Names.Count -gt 0) { $Observation.observedTargetNames = (@($Names) -join ',') }
	return $Observation
}

function Get-IntermediatePresence([string] $Platform, [string] $Target) {
	# Presence before the run only: an intermediate directory or makefile on
	# disk is not proof of reusable object identity or of a warm compile.
	$BuildRoot = Join-Path $ResolvedRepository ('Intermediate/Build/' + $Platform)
	$DirectoryPresent = Test-Path -LiteralPath $BuildRoot -PathType Container
	$MakefilePresent = $false
	if ($DirectoryPresent) {
		foreach ($Relative in @("$Target/Development/Makefile.bin", "*/$Target/Development/Makefile.bin")) {
			if (Test-Path -Path (Join-Path $BuildRoot $Relative) -PathType Leaf) { $MakefilePresent = $true }
		}
	}
	return [ordered]@{ intermediateBuildDirectoryPresentBeforeRun = $DirectoryPresent; makefilePresentBeforeRun = $MakefilePresent }
}

function Add-CompileBuildEvidence([string] $Check, [string] $Target, [string] $Platform, $Presence, [object[]] $Output, [bool] $OutputAvailable) {
	$Entry = [ordered]@{
		check = $Check
		target = $Target
		platform = $Platform
		configuration = 'Development'
		intermediateBuildDirectoryPresentBeforeRun = $(if ($null -eq $Presence) { $null } else { $Presence.intermediateBuildDirectoryPresentBeforeRun })
		makefilePresentBeforeRun = $(if ($null -eq $Presence) { $null } else { $Presence.makefilePresentBeforeRun })
	}
	$Observation = Get-CompileObservation @(if ($OutputAvailable) { $Output } else { @() })
	if (-not $OutputAvailable) { $Observation.outputState = 'unavailable' }
	foreach ($Key in $Observation.Keys) { $Entry[$Key] = $Observation[$Key] }
	[void] $CompileBuilds.Add($Entry)
}

function Write-RunnerReport {
	if ([string]::IsNullOrWhiteSpace($ResolvedRepository)) { return }
	if ($ExplicitReportRequested -and [string]::IsNullOrWhiteSpace($ResolvedReportPath)) { return }
	$ResultRoot = if ($ResolvedReportPath) { Split-Path $ResolvedReportPath } else { Join-Path $ResolvedRepository 'TestResults' }
	if (-not (Test-Path -LiteralPath $ResultRoot)) { New-Item -ItemType Directory -Path $ResultRoot | Out-Null }
	$Passed = @($Checks | Where-Object { $_.status -eq 'passed' }).Count
	$Failed = @($Checks | Where-Object { $_.status -eq 'failed' }).Count
	$Skipped = @($Checks | Where-Object { $_.status -eq 'skipped' }).Count
	$Report = [ordered]@{
		schemaVersion = 1
		mode = $Mode
		policy = $Policy
		revision = $SourceRevision
		runnerName = $(if ($RunnerName -match $RunnerNamePattern) { $RunnerName } else { $null })
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
		compileEvidence = $(if ($null -eq $CompileEvidenceIdentity) { $null } else { [ordered]@{ schemaVersion = 1; identity = $CompileEvidenceIdentity; builds = @($CompileBuilds) } })
	}
	if ($null -ne $RelayedReport) {
		$Report = $RelayedReport
		# Parent-owned failures (including lease release) cannot disappear behind
		# a successful child report. Native exit and report must agree on failure.
		$ParentFailures = @($Checks | Where-Object status -eq 'failed')
		if ($ParentFailures.Count -gt 0) {
			$Report.checks = @($Report.checks) + $ParentFailures
			$Report.summary.total = $Report.checks.Count
			$Report.summary.passed = @($Report.checks | Where-Object status -eq 'passed').Count
			$Report.summary.failed = @($Report.checks | Where-Object status -eq 'failed').Count
			$Report.summary.skipped = @($Report.checks | Where-Object status -eq 'skipped').Count
			$Report.summary.requiredFailed = $Report.summary.failed
		}
	}
	if ($null -ne $ManagedWorkspaceEvidence) {
		if ($Report -is [Collections.IDictionary]) { $Report['managedWorkspace'] = $ManagedWorkspaceEvidence }
		else { $Report | Add-Member -NotePropertyName managedWorkspace -NotePropertyValue $ManagedWorkspaceEvidence -Force }
	}
	if ($null -ne $RoutineResourceMonitor) {
		$ResourceProof = Get-RoutineCompileResourceProof -Monitor $RoutineResourceMonitor
		if ($Report -is [Collections.IDictionary]) { $Report['compileResources'] = $ResourceProof }
		else { $Report | Add-Member -NotePropertyName compileResources -NotePropertyValue $ResourceProof -Force }
	}
	if ($null -ne $SupervisorReceipt) {
		if ($Report -is [Collections.IDictionary]) { $Report['supervisor'] = $SupervisorReceipt }
		else { $Report | Add-Member -NotePropertyName supervisor -NotePropertyValue $SupervisorReceipt -Force }
	}
	$Json = $Report | ConvertTo-Json -Depth 8
	if ($ResolvedReportPath) {
		# CreateNew closes the validation/publication race without replacing any
		# prior evidence. Only this invocation owns the newly created file.
		$Stream = [IO.File]::Open($ResolvedReportPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
		try { $Bytes = [Text.Encoding]::UTF8.GetBytes($Json); $Stream.Write($Bytes, 0, $Bytes.Length) } finally { $Stream.Dispose() }
	} else { $Json | Set-Content -LiteralPath (Join-Path $ResultRoot 'engine-runner-report.json') -Encoding UTF8 }
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
		Assert-PhaseDeadline
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

function Get-DirectoryByteCount([string] $Root, [string] $ReasonCode, [bool] $SkipReparse = $false) {
	$Total = [long] 0
	foreach ($File in @(Get-ChildEntriesSafe -Root $Root -ReasonCode $ReasonCode -SkipReparse $SkipReparse)) {
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

function Assert-UniqueJsonProperty([string] $Raw, [string] $ReasonCode) {
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
			# Compare decoded names: escaped spellings can identify the same key
			# and ConvertFrom-Json otherwise silently keeps one conflicting value.
			try { $PendingName = [string] (('"' + $Builder.ToString() + '"') | ConvertFrom-Json) } catch { throw $ReasonCode }
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

function Assert-UniqueJsonProperties {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Retains the current-base managed-compile fixture seam while the canonical helper uses the singular name.')]
	param([string] $Raw, [string] $ReasonCode)

	# Compatibility seam for current-base #167 fixtures that extract this
	# function in isolation. Keep it self-contained so those fixtures validate
	# the same duplicate-property behavior as the canonical singular helper.
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
			try { $PendingName = [string] (('"' + $Builder.ToString() + '"') | ConvertFrom-Json) } catch { throw $ReasonCode }
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
	if ($PhaseFinalizeGraceSeconds -lt 1 -or $PhaseFinalizeGraceSeconds -gt 600) { throw 'handoff_context_invalid' }
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
	Assert-ClosedObject -Value $Record -PropertyNames $RunContextPropertyNames -ReasonCode 'handoff_context_invalid'
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
	Assert-ClosedObject -Value $Manifest -PropertyNames $ManifestPropertyNames -ReasonCode 'handoff_schema_invalid'
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
		Assert-ClosedObject -Value $Entry -PropertyNames @('path', 'bytes', 'sha256') -ReasonCode 'handoff_schema_invalid'
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

function Get-HandoffRelativeFile([string] $PhaseDirectory) {
	$Prefix = [System.IO.Path]::GetFullPath($PhaseDirectory).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
	$Seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
	return @(Get-ChildEntriesSafe $PhaseDirectory 'handoff_payload_invalid' | Sort-Object FullName | ForEach-Object {
		Assert-PhaseDeadline
		# RUNNER_TEST_HASH_BLOCK_SECONDS is a fault-injection seam used only by
		# the focused fixture suite to block a payload hash synchronously across
		# the script-phase deadline (spawning a marker descendant via
		# RUNNER_TEST_DESCENDANT_EXE) so the supervisor hard bound is provable;
		# real CI never sets it.
		$HashBlockSeconds = [Environment]::GetEnvironmentVariable('RUNNER_TEST_HASH_BLOCK_SECONDS', 'Process')
		if (-not [string]::IsNullOrWhiteSpace($HashBlockSeconds)) {
			$DescendantExecutable = [Environment]::GetEnvironmentVariable('RUNNER_TEST_DESCENDANT_EXE', 'Process')
			if (-not [string]::IsNullOrWhiteSpace($DescendantExecutable)) { Start-Process -FilePath $DescendantExecutable -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 240') -WindowStyle Hidden | Out-Null }
			Start-Sleep -Seconds ([int] $HashBlockSeconds)
		}
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
		Assert-PhaseDeadline
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
			$MeasuredBytes = Get-DirectoryByteCount $Directory.FullName 'invalid'
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
				Assert-ClosedObject -Value $Marker -PropertyNames $MarkerPropertyNames -ReasonCode 'invalid'
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
	Assert-PathChainSafe -Root $HandoffRoot -Leaf $RequestRoot -ReasonCode 'handoff_root_invalid'
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
	$PhaseDirectory = Get-HandoffChildPath -Parent $RunDirectory -Child $Phase -ReasonCode 'handoff_payload_invalid'
	Assert-PathChainSafe -Root $HandoffRoot -Leaf $PhaseDirectory -ReasonCode 'handoff_payload_invalid'
	$Files = @(Get-HandoffRelativeFile $PhaseDirectory)
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
	Assert-PathChainSafe -Root $HandoffRoot -Leaf $ManifestPath -ReasonCode 'handoff_payload_invalid'
	if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw 'handoff_missing' }
	$Manifest = Read-JsonStrict $ManifestPath 'handoff_schema_invalid'
	$Shape = Test-HandoffManifestShape $Manifest
	if ([string] $Manifest.repository -cne $Repository) { throw 'handoff_context_mismatch' }
	if (-not ([string] $Manifest.sourceRevision).Equals($SourceRevision, [StringComparison]::OrdinalIgnoreCase)) { throw 'handoff_context_mismatch' }
	if ([string] $Manifest.runId -ne $RunId -or [string] $Manifest.runAttempt -ne $RunAttempt) { throw 'handoff_context_mismatch' }
	if ([string] $Manifest.producingPhase -ne $Phase) { throw 'handoff_context_mismatch' }
	if (@($Manifest.expectedConsumingPhases) -notcontains $ConsumingPhase) { throw 'handoff_context_mismatch' }
	if ([string] $Manifest.runnerName -cne $RunnerName) { throw 'handoff_runner_mismatch' }
	$PhaseDirectory = Get-HandoffChildPath -Parent $RunDirectory -Child $Phase -ReasonCode 'handoff_missing'
	Assert-PathChainSafe -Root $HandoffRoot -Leaf $PhaseDirectory -ReasonCode 'handoff_payload_invalid'
	if (-not (Test-Path -LiteralPath $PhaseDirectory -PathType Container)) { throw 'handoff_missing' }
	$ActualFiles = @(Get-HandoffRelativeFile $PhaseDirectory)
	$ManifestByPath = @{}
	foreach ($Entry in @($Manifest.files)) { $ManifestByPath[[string] $Entry.path] = $Entry }
	if ($ActualFiles.Count -ne $ManifestByPath.Count) { throw 'handoff_digest_mismatch' }
	foreach ($Actual in $ActualFiles) {
		if (-not $ManifestByPath.ContainsKey([string] $Actual.path)) { throw 'handoff_digest_mismatch' }
		$Entry = $ManifestByPath[[string] $Actual.path]
		if ([long] $Actual.bytes -ne [long] $Entry.bytes) { throw 'handoff_digest_mismatch' }
		if ([string] $Actual.sha256 -cne [string] $Entry.sha256) { throw 'handoff_digest_mismatch' }
	}
	return [ordered]@{ phaseDirectory = $PhaseDirectory; totalBytes = [long] $Shape.totalBytes }
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

function ConvertTo-NamedInvocationText([string] $Target, $Parameters) {
	$Segments = New-Object System.Collections.ArrayList
	[void] $Segments.Add('&')
	[void] $Segments.Add((ConvertTo-DriverLiteral $Target))
	foreach ($Key in $Parameters.Keys) {
		[void] $Segments.Add('-' + $Key)
		[void] $Segments.Add((ConvertTo-DriverValueText $Parameters[$Key]))
	}
	return (@($Segments) -join ' ')
}

function New-NamedInvocationText {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Retains the current-base managed-compile fixture seam; the helper only formats an in-memory command string.')]
	param([string] $Target, $Parameters)

	$Segments = New-Object System.Collections.ArrayList
	[void] $Segments.Add('&')
	[void] $Segments.Add((ConvertTo-DriverLiteral $Target))
	foreach ($Key in $Parameters.Keys) {
		[void] $Segments.Add('-' + $Key)
		[void] $Segments.Add((ConvertTo-DriverValueText $Parameters[$Key]))
	}
	return (@($Segments) -join ' ')
}

function ConvertTo-PositionalInvocationText([string] $Target, [string[]] $Arguments) {
	return ('& ' + (ConvertTo-DriverLiteral $Target) + ' ' + (@($Arguments | ForEach-Object { ConvertTo-DriverLiteral $_ }) -join ' ')).TrimEnd()
}

function ConvertTo-PhaseDriverBody([string] $InvocationText, [string] $CapturePath, [bool] $UseNativeExitCode) {
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

function Stop-PhaseProcessTree {
	[CmdletBinding(SupportsShouldProcess)]
	param($TargetProcess, $TargetJob)
	# RUNNER_TEST_KILL_FAULT is a fault-injection seam used only by the focused
	# fixture suite to force the taskkill fallback ('skip-job') or the
	# fail-closed cleanup-verification branch ('skip-all'); real CI never sets
	# it. Keep the Job Object handle until termination accounting proves every
	# owned process stopped; root exit alone cannot prove descendant cleanup.
	# Bounded taskkill and Process.Kill remain fallbacks, followed by the same
	# owned-job proof. An unverifiable tree is phase_cleanup_failed.
	# The decision precedes every cleanup action below, so a declined call
	# terminates nothing, disposes no owned Job Object, and reports no cleanup.
	# The target text stays generic: no command line or environment data
	# belongs in a confirmation prompt.
	if (-not $PSCmdlet.ShouldProcess('the owned phase process tree', 'Terminate')) { return }
	$KillFault = [Environment]::GetEnvironmentVariable('RUNNER_TEST_KILL_FAULT', 'Process')
	if ($KillFault -ne 'skip-job' -and $KillFault -ne 'skip-all' -and $null -ne $TargetJob) {
		try { $TargetJob.TerminateAndWait(5000); return } catch { Write-Verbose "Owned Job Object termination accounting was unavailable, so cleanup continues with bounded termination: $($_.Exception.Message)" }
	}
	try { [void] $TargetProcess.WaitForExit(5000) } catch { Write-Verbose "Bounded wait for the owned phase process failed: $($_.Exception.Message)" }
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
					try { $KillProcess.Kill() } catch { Write-Verbose "Terminating the bounded taskkill helper failed: $($_.Exception.Message)" }
					try { [void] $KillProcess.WaitForExit(1000) } catch { Write-Verbose "Bounded wait for the taskkill helper to exit failed: $($_.Exception.Message)" }
				}
			} catch { Write-Verbose "The bounded taskkill helper could not be run, so cleanup continues with direct termination: $($_.Exception.Message)" } finally { $KillProcess.Dispose() }
		}
		try { if (-not $TargetProcess.HasExited) { $TargetProcess.Kill() } } catch { Write-Verbose "Direct termination of the owned phase process failed: $($_.Exception.Message)" }
		try { [void] $TargetProcess.WaitForExit(5000) } catch { Write-Verbose "Bounded wait after terminating the owned phase process failed: $($_.Exception.Message)" }
	}
	$StillAlive = $true
	try { $StillAlive = -not $TargetProcess.HasExited } catch { $StillAlive = $true }
	if ($StillAlive -or $KillFault -eq 'skip-all' -or $null -eq $TargetJob) { throw 'phase_cleanup_failed' }
	try { $TargetJob.TerminateAndWait(5000) } catch { throw 'phase_cleanup_failed' }
}

function Invoke-PhaseChildScript([string] $InvocationText, [double] $TimeoutMinutes, [bool] $UseNativeExitCode = $false, [string] $WatchdogRoot = '', [datetime] $AbsoluteDeadlineUtc = [DateTime]::MaxValue, [scriptblock] $RemainingBudget) {
	Initialize-EngineGateJobType
	if ([string]::IsNullOrWhiteSpace($WatchdogRoot)) { $WatchdogRoot = Join-Path $ResolvedLogs 'phase-watchdog' }
	if (-not (Test-Path -LiteralPath $WatchdogRoot)) { New-Item -ItemType Directory -Path $WatchdogRoot -Force | Out-Null }
	$Token = [guid]::NewGuid().ToString('N')
	$DriverPath = Join-Path $WatchdogRoot ('driver-' + $Token + '.ps1')
	$CapturePath = Join-Path $WatchdogRoot ('capture-' + $Token + '.txt')
	Set-Content -LiteralPath $DriverPath -Value (ConvertTo-PhaseDriverBody -InvocationText $InvocationText -CapturePath $CapturePath -UseNativeExitCode $UseNativeExitCode) -Encoding UTF8
	$PowerShellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
	$CommandLine = ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f $PowerShellPath, $DriverPath)
	$ChildJob = $null
	$ChildProcess = $null
	try {
		$ChildJob = New-Object Aetheln.EngineGateJob
		$ChildProcess = $ChildJob.StartSuspended($PowerShellPath, $CommandLine, $ResolvedRepository)
		$WaitMilliseconds = if ($AbsoluteDeadlineUtc -eq [DateTime]::MaxValue) { $TimeoutMinutes * 60000 } else { [Math]::Max(0, ($AbsoluteDeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds) }
		if ($null -ne $RemainingBudget) {
			try { $WaitMilliseconds = & $RemainingBudget }
			catch { if ($_.Exception.Message -eq 'compile_timeout') { $WaitMilliseconds = 0 } else { throw } }
		}
		if (-not $ChildProcess.WaitForExit([int][Math]::Ceiling($WaitMilliseconds))) {
			$CleanupFailure = $null
			try {
				if ($AbsoluteDeadlineUtc -ne [DateTime]::MaxValue) { $ChildJob.TerminateAndWait(5000) }
				else { Stop-PhaseProcessTree $ChildProcess $ChildJob }
			} catch { $CleanupFailure = 'phase_cleanup_failed' }
			$ExitReceipt = $null
			try { if ($ChildProcess.HasExited) { $ExitReceipt = $ChildProcess.ExitCode } } catch { Write-Verbose "The timed-out child exit code could not be read, so the exit receipt stays unavailable: $($_.Exception.Message)" }
			return [ordered]@{ timedOut = $true; exitCode = $ExitReceipt; output = @(); cleanupFailure = $CleanupFailure; cleanupVerified = ($null -eq $CleanupFailure) }
		}
		$ChildProcess.WaitForExit()
		# Normal root exit can leave detached descendants for Compile or phases.
		# Verify the owned job before publishing the child's success evidence.
		try {
			if ($AbsoluteDeadlineUtc -ne [DateTime]::MaxValue) { $ChildJob.TerminateAndWait(5000) }
			else { Stop-PhaseProcessTree $ChildProcess $ChildJob }
		} catch { return [ordered]@{ timedOut = $true; exitCode = $ChildProcess.ExitCode; output = @(); cleanupFailure = 'phase_cleanup_failed'; cleanupVerified = $false } }
		$Output = @()
		if ($AbsoluteDeadlineUtc -eq [DateTime]::MaxValue -and (Test-Path -LiteralPath $CapturePath -PathType Leaf)) { $Output = @(Get-Content -LiteralPath $CapturePath) }
		return [ordered]@{ timedOut = $false; exitCode = $ChildProcess.ExitCode; output = @($Output); cleanupFailure = $null; cleanupVerified = $true }
	} finally {
		if ($null -ne $ChildProcess) { $ChildProcess.Dispose() }
		if ($null -ne $ChildJob) { $ChildJob.Dispose() }
	}
}

function Invoke-CompileSupervisor {
	# Only bootstrap (local report/log paths and supervisor creation) runs in
	# this parent. Engine discovery, Git/identity diagnostics, both native
	# builds and finalization all belong to one kill-on-close child tree.
	$WatchdogRoot = Join-Path $ResolvedLogs ('compile-watchdog-' + [guid]::NewGuid().ToString('N'))
	$ChildReportPath = Join-Path $WatchdogRoot 'child-report.json'
	$ChildParameters = [ordered]@{
		Mode = $Mode; RepositoryRoot = $ResolvedRepository; SourceRevision = $SourceRevision
		ArchiveRoot = $ArchiveRoot; LogRoot = (Join-Path $ResolvedLogs 'compile')
		RunnerName = $RunnerName; CompileTimeoutMinutes = $CompileTimeoutMinutes
		ReportPath = $ChildReportPath
	}
	if ($ManagedCompile) {
		$ChildParameters['Repository'] = $Repository
		$ChildParameters['ManagedWorkspaceRoot'] = $ManagedWorkspaceRoot
		$ChildParameters['ManagedWorkspaceRegistrationPath'] = $ManagedWorkspaceRegistrationPath
		$ChildParameters['ManagedWorkspaceRegistrationSha256'] = $ManagedWorkspaceRegistrationSha256
		$ChildParameters['HostLeasePath'] = $HostLeasePath
	}
	$Context = '$global:AethelnCompileGateContext = @{ startedUtc = ' + (ConvertTo-DriverLiteral $Started.ToString('o')) + ' }; '
	$HardDeadline = $Started.AddMinutes($CompileTimeoutMinutes).AddSeconds(2)
	$RemainingBudget = $null
	if ($ManagedCompile) {
		$Context = '$global:AethelnCompileGateContext = @{ startedUtc = ' + (ConvertTo-DriverLiteral $Started.ToString('o')) +
			'; startedTimestamp = ' + $CompileStartedTimestamp.ToString([Globalization.CultureInfo]::InvariantCulture) + ' }; '
		$HardDeadline = Get-RoutineCompileDeadlineUtc -Deadline $RoutineDeadline -GraceMilliseconds 2000
		$RemainingBudget = { Get-RoutineCompileRemainingMillisecondCount -Deadline $RoutineDeadline -GraceMilliseconds 2000 }
	}
	$HostLease = $null
	$Result = $null
	$OwnedCleanupVerified = $false
	try {
		if ($ManagedCompile) {
			. (Join-Path $PSScriptRoot 'EngineRunnerHostLease.ps1')
			$LeaseDeadline = Get-RoutineCompileDeadlineUtc -Deadline $RoutineDeadline
			$HostLease = Enter-EngineRunnerHostLease -LeasePath $HostLeasePath -OwnerId ('compile-' + [guid]::NewGuid().ToString('N')) -DeadlineUtc $LeaseDeadline -RemainingBudget { Get-RoutineCompileRemainingMillisecondCount -Deadline $RoutineDeadline } -OnProgress { $null = Get-RoutineCompileRemainingMillisecondCount -Deadline $RoutineDeadline }
		}
		# Synchronization belongs to this same child and original deadline. The
		# parent holds the shared host lease until all owned descendants end.
		if ($ManagedCompile) {
			$Result = Invoke-PhaseChildScript -InvocationText ($Context + (New-NamedInvocationText $PSCommandPath $ChildParameters)) -TimeoutMinutes $CompileTimeoutMinutes -UseNativeExitCode $true -WatchdogRoot $WatchdogRoot -AbsoluteDeadlineUtc $HardDeadline -RemainingBudget $RemainingBudget
		} else {
			$Result = Invoke-PhaseChildScript -InvocationText ($Context + (New-NamedInvocationText $PSCommandPath $ChildParameters)) -TimeoutMinutes $CompileTimeoutMinutes -UseNativeExitCode $true -WatchdogRoot $WatchdogRoot -AbsoluteDeadlineUtc $HardDeadline
		}
		# Only the process owner can prove quiescence. Missing/loosely typed
		# fields cannot release the host or turn a partial result into success.
		if ($null -ne $Result -and $Result.Contains('cleanupVerified')) {
			$OwnedCleanupVerified = $Result.cleanupVerified -is [bool] -and $Result.cleanupVerified -and
				$Result.Contains('cleanupFailure') -and [string]::IsNullOrWhiteSpace([string] $Result.cleanupFailure)
		}
		if (-not $OwnedCleanupVerified) { throw 'compile_cleanup_failed' }
	} finally {
		if ($null -ne $HostLease) {
			try {
				if ($OwnedCleanupVerified) { Exit-EngineRunnerHostLease -Lease $HostLease -CleanupVerified $true }
				else { Close-EngineRunnerHostLease -Lease $HostLease }
				$HostLease = $null
			}
			catch {
				Add-Check -Name 'compile-host-lease' -Status 'failed' -CheckStarted $Started -Command 'release-shared-host-lease' -Message 'compile_lease_release_failed'
				throw 'compile_lease_release_failed'
			} finally {
				# Closing does not append a release receipt. If release failed,
				# retain the held journal for explicit recovery without leaking handles.
				if ($null -ne $HostLease) { Close-EngineRunnerHostLease -Lease $HostLease }
			}
		}
	}
	$script:SupervisorReceipt = [ordered]@{ childExitCode = $Result.exitCode; timedOut = $Result.timedOut; cleanupVerified = $OwnedCleanupVerified }
	if ($Result.timedOut) {
		$Reason = if ($SupervisorReceipt.cleanupVerified) { 'compile_timeout' } else { 'compile_cleanup_failed' }
		Add-Check -Name 'compile-hard-deadline' -Status 'failed' -CheckStarted $Started -Command 'supervise-compile-child-tree' -Message $Reason
		throw $Reason
	}
	# The internal child report is bounded, normalized evidence. Never relay
	# raw driver output: its local capture may contain implementation paths.
	if (-not (Test-Path -LiteralPath $ChildReportPath -PathType Leaf) -or (Get-Item -LiteralPath $ChildReportPath).Length -gt 1048576) { throw 'compile_report_missing' }
	# Validate before assigning the relay: a malformed child must not prevent
	# the parent from publishing its own well-formed failure report.
	try {
		$ChildReport = Get-Content -LiteralPath $ChildReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
		if ($ChildReport.schemaVersion -isnot [int] -or $ChildReport.schemaVersion -ne 1 -or
			$ChildReport.mode -cne 'Compile' -or $ChildReport.revision -cne $SourceRevision -or
			$ChildReport.checks -isnot [array] -or $null -eq $ChildReport.summary) { throw 'compile_report_invalid' }
		$Counts = @{ total = $ChildReport.checks.Count; passed = 0; failed = 0; skipped = 0; requiredFailed = 0 }
		$ChecksByName = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
		foreach ($ChildCheck in $ChildReport.checks) {
			if ($ChildCheck.name -isnot [string] -or [string]::IsNullOrWhiteSpace($ChildCheck.name) -or
				$ChecksByName.ContainsKey($ChildCheck.name) -or $ChildCheck.tier -cne 'required' -or
				$ChildCheck.status -isnot [string] -or @('passed', 'failed', 'skipped') -cnotcontains $ChildCheck.status) { throw 'compile_report_invalid' }
			$ChecksByName.Add($ChildCheck.name, $ChildCheck)
			$Counts[$ChildCheck.status]++
		}
		$Counts.requiredFailed = $Counts.failed
		foreach ($CountName in $Counts.Keys) {
			$CountValue = $ChildReport.summary.$CountName
			if (($CountValue -isnot [int] -and $CountValue -isnot [long]) -or $CountValue -ne $Counts[$CountName]) { throw 'compile_report_invalid' }
		}
		# Partial failure reports remain useful evidence. Success, however, must
		# prove both actual targets completed and the managed admission remained healthy.
		if ($Result.exitCode -eq 0 -and $Counts.requiredFailed -eq 0) {
			foreach ($RequiredTarget in @('incremental-client-build', 'incremental-server-build')) {
				if (-not $ChecksByName.ContainsKey($RequiredTarget) -or $ChecksByName[$RequiredTarget].status -cne 'passed') { throw 'compile_report_invalid' }
			}
			if ($ManagedCompile) {
				if (-not $ChecksByName.ContainsKey('managed-compile-workspace') -or $ChecksByName['managed-compile-workspace'].status -cne 'passed') { throw 'compile_report_invalid' }
				$WorkspaceProof = $ChildReport.managedWorkspace
				if ($null -eq $WorkspaceProof -or $WorkspaceProof.schemaVersion -isnot [int] -or $WorkspaceProof.schemaVersion -ne 1 -or
					$WorkspaceProof.registrationId -cnotmatch '^[a-f0-9]{32}$' -or
					$WorkspaceProof.registrationSha256 -cne $ManagedWorkspaceRegistrationSha256 -or
					$WorkspaceProof.preparationReceiptSha256 -cnotmatch '^[a-f0-9]{64}$' -or
					$WorkspaceProof.revision -cne $SourceRevision -or $WorkspaceProof.synchronized -isnot [bool] -or -not $WorkspaceProof.synchronized) { throw 'compile_report_invalid' }
				$ResourceProof = $ChildReport.compileResources
				if ($null -eq $ResourceProof -or $ResourceProof.schemaVersion -isnot [int] -or $ResourceProof.schemaVersion -ne 1 -or
					$null -ne $ResourceProof.failureReason -or $ResourceProof.volumes -isnot [array] -or $ResourceProof.volumes.Count -lt 1) { throw 'compile_report_invalid' }
				foreach ($IntegerField in @('sampleCount', 'measurementCount', 'targetAdmissionCount', 'minimumActionLimit', 'maximumActionLimit')) {
					if (($ResourceProof.$IntegerField -isnot [int] -and $ResourceProof.$IntegerField -isnot [long]) -or $ResourceProof.$IntegerField -lt 1) { throw 'compile_report_invalid' }
				}
				if ($ResourceProof.targetAdmissionCount -ne 2 -or $ResourceProof.measurementCount -lt $ResourceProof.sampleCount -or
					$ResourceProof.maximumActionLimit -gt 4 -or $ResourceProof.minimumActionLimit -gt $ResourceProof.maximumActionLimit) { throw 'compile_report_invalid' }
				foreach ($VolumeProof in $ResourceProof.volumes) {
					if ($VolumeProof.volumeId -isnot [string] -or [string]::IsNullOrWhiteSpace($VolumeProof.volumeId) -or
					($VolumeProof.knownAllocationBytes -isnot [long] -and $VolumeProof.knownAllocationBytes -isnot [int]) -or $VolumeProof.knownAllocationBytes -lt 0 -or
					($VolumeProof.minimumAvailableBytes -isnot [long] -and $VolumeProof.minimumAvailableBytes -isnot [int]) -or
					[decimal]$VolumeProof.minimumAvailableBytes -le ([decimal]$VolumeProof.knownAllocationBytes + 20GB)) { throw 'compile_report_invalid' }
				}
			}
		}
	} catch { throw 'compile_report_invalid' }
	$script:RelayedReport = $ChildReport
	if ($Result.exitCode -ne 0) {
		$ChildFailures = @($RelayedReport.checks | Where-Object status -eq 'failed')
		if ($ChildFailures.Count -gt 0) {
			$ChildReason = ([string] $ChildFailures[0].message -split '[\r\n]')[0]
			if ($ChildReason -match '^[a-z0-9_]+$') { throw $ChildReason }
		}
		throw 'compile_child_failed'
	}
	if ($RelayedReport.summary.requiredFailed -ne 0) { throw 'compile_report_failed' }
}

function Invoke-PhaseChildWithinDeadline([string] $InvocationText) {
	# The phase child never receives a fresh watchdog duration: it gets only
	# the time remaining on the absolute script-phase deadline, and it is
	# never started once that deadline has expired.
	$RemainingMinutes = ($script:PhaseDeadlineUtc - [DateTime]::UtcNow).TotalMinutes
	if ($RemainingMinutes -le 0) { return [ordered]@{ timedOut = $true; exitCode = -1; output = @(); cleanupFailure = $null } }
	return Invoke-PhaseChildScript -InvocationText $InvocationText -TimeoutMinutes $RemainingMinutes
}

function Assert-ExactPhaseReportObject($Value, [string[]] $PropertyNames) {
	if ($null -eq $Value -or $Value -isnot [System.Management.Automation.PSCustomObject]) { throw 'phase_report_invalid' }
	$ActualNames = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
	if ($ActualNames.Count -ne $PropertyNames.Count) { throw 'phase_report_invalid' }
	for ($Index = 0; $Index -lt $PropertyNames.Count; $Index++) {
		if ($ActualNames[$Index] -cne $PropertyNames[$Index]) { throw 'phase_report_invalid' }
	}
}

function ConvertFrom-PhaseReportTimestamp($Value) {
	if ($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') { throw 'phase_report_invalid' }
	$Parsed = [DateTime]::MinValue
	if (-not [DateTime]::TryParseExact($Value, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref] $Parsed) -or
		$Parsed.Kind -ne [DateTimeKind]::Utc) { throw 'phase_report_invalid' }
	return $Parsed
}

function Test-PhaseReportNumber($Value) {
	if ($Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [double] -and $Value -isnot [decimal]) { return $false }
	$Number = [double] $Value
	return -not [double]::IsNaN($Number) -and -not [double]::IsInfinity($Number) -and $Number -ge 0
}

function Read-PhaseSupervisorReport([string] $Path, [string] $ExpectedMode, [string] $ExpectedRevision, [string] $ExpectedRunnerName) {
	# The child report is private input to the outer supervisor, not published
	# evidence. Bound and validate its exact producer schema before any field can
	# reach the final report. A nominal result is not trusted merely because it
	# contains all expected check names.
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'phase_report_invalid' }
	$Item = Get-Item -LiteralPath $Path
	if ($Item.Length -le 0 -or $Item.Length -gt 1MB) { throw 'phase_report_invalid' }
	try {
		$Utf8 = New-Object System.Text.UTF8Encoding($false, $true)
		$Raw = [IO.File]::ReadAllText($Path, $Utf8)
		Assert-UniqueJsonProperty $Raw 'phase_report_invalid'
		$ConvertFromJson = Get-Command ConvertFrom-Json -CommandType Cmdlet -ErrorAction Stop
		$Report = if ($ConvertFromJson.Parameters.ContainsKey('DateKind')) { $Raw | ConvertFrom-Json -DateKind String } else { $Raw | ConvertFrom-Json }
		Assert-ExactPhaseReportObject $Report @(
			'schemaVersion', 'mode', 'policy', 'revision', 'runnerName', 'startedUtc',
			'finishedUtc', 'checks', 'summary', 'compileEvidence'
		)
		if ($Report.schemaVersion -isnot [int] -or $Report.schemaVersion -ne 1 -or
			@('PackageClient', 'PackageServer', 'ValidateProvenance', 'SmokePhase') -cnotcontains $ExpectedMode -or
			$Report.mode -isnot [string] -or $Report.mode -cne $ExpectedMode -or
			$Report.policy -isnot [string] -or $Report.policy -cne 'clean-package-and-smoke' -or
			$Report.revision -isnot [string] -or $Report.revision -cne $ExpectedRevision -or
			$ExpectedRevision -cnotmatch '^[0-9a-fA-F]{40}$' -or $Report.checks -isnot [array]) { throw 'phase_report_invalid' }
		$BoundRunnerName = if ($ExpectedRunnerName -match '^[^\\/:*?"<>|\x00-\x1f]{1,128}$') { $ExpectedRunnerName } else { $null }
		if (($null -eq $BoundRunnerName -and $null -ne $Report.runnerName) -or
			($null -ne $BoundRunnerName -and ($Report.runnerName -isnot [string] -or $Report.runnerName -cne $BoundRunnerName))) { throw 'phase_report_invalid' }
		$StartedUtc = ConvertFrom-PhaseReportTimestamp $Report.startedUtc
		$FinishedUtc = ConvertFrom-PhaseReportTimestamp $Report.finishedUtc
		if ($FinishedUtc -lt $StartedUtc) { throw 'phase_report_invalid' }
		if ($Report.checks.Count -lt 1 -or $Report.checks.Count -gt 128) { throw 'phase_report_invalid' }
		$Counts = @{ total = $Report.checks.Count; passed = 0; failed = 0; skipped = 0; requiredFailed = 0 }
		$Names = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
		$Statuses = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
		foreach ($Check in $Report.checks) {
			Assert-ExactPhaseReportObject $Check @('name', 'tier', 'status', 'durationSeconds', 'command', 'message')
			if ($Check.name -isnot [string] -or $Check.name -cnotmatch '^[a-z0-9][a-z0-9-]{0,127}$' -or -not $Names.Add($Check.name) -or
				$Check.tier -cne 'required' -or $Check.status -isnot [string] -or
				@('passed', 'failed', 'skipped') -cnotcontains $Check.status -or -not (Test-PhaseReportNumber $Check.durationSeconds) -or
				$Check.command -isnot [string] -or [string]::IsNullOrWhiteSpace($Check.command) -or $Check.command.Length -gt 256 -or
				$Check.message -isnot [string] -or [string]::IsNullOrWhiteSpace($Check.message) -or $Check.message.Length -gt 8192) { throw 'phase_report_invalid' }
			$Statuses.Add($Check.name, $Check.status)
			$Counts[$Check.status]++
		}
		$Counts.requiredFailed = $Counts.failed
		Assert-ExactPhaseReportObject $Report.summary @('total', 'passed', 'failed', 'skipped', 'requiredFailed')
		foreach ($Name in $Counts.Keys) {
			$Value = $Report.summary.$Name
			if (($Value -isnot [int] -and $Value -isnot [long]) -or [long] $Value -ne $Counts[$Name]) { throw 'phase_report_invalid' }
		}

		if ($null -eq $Report.compileEvidence) {
			# The child can fail before compile-identity resolution if an input that
			# the parent already checked disappears before the supervised re-entry.
			# A successful child can never omit this canonical evidence object.
			if ($Counts.requiredFailed -eq 0) { throw 'phase_report_invalid' }
		} else {
			Assert-ExactPhaseReportObject $Report.compileEvidence @('schemaVersion', 'identity', 'builds')
			if ($Report.compileEvidence.schemaVersion -isnot [int] -or $Report.compileEvidence.schemaVersion -ne 1 -or
				$Report.compileEvidence.builds -isnot [array]) { throw 'phase_report_invalid' }
			$Identity = $Report.compileEvidence.identity
			Assert-ExactPhaseReportObject $Identity @(
				'engineGitRevision', 'engineGitRevisionStatus', 'engineBuildVersionSha256', 'engineBuildVersionSha256Status',
				'linuxToolchainCompilerSha256', 'linuxToolchainCompilerSha256Status', 'runnerName', 'durationSeconds'
			)
			if ($Identity.engineGitRevisionStatus -isnot [string] -or @('verified', 'dirty', 'unavailable') -cnotcontains $Identity.engineGitRevisionStatus -or
				($Identity.engineGitRevisionStatus -ceq 'unavailable' -and $null -ne $Identity.engineGitRevision) -or
				($Identity.engineGitRevisionStatus -cne 'unavailable' -and ($Identity.engineGitRevision -isnot [string] -or $Identity.engineGitRevision -cnotmatch '^[0-9a-f]{40}$'))) { throw 'phase_report_invalid' }
			foreach ($HashEvidence in @(
				[ordered]@{ hash = $Identity.engineBuildVersionSha256; status = $Identity.engineBuildVersionSha256Status },
				[ordered]@{ hash = $Identity.linuxToolchainCompilerSha256; status = $Identity.linuxToolchainCompilerSha256Status }
			)) {
				$Hash = $HashEvidence.hash
				$Status = $HashEvidence.status
				if ($Status -isnot [string] -or @('verified', 'unavailable') -cnotcontains $Status -or
					($Status -ceq 'unavailable' -and $null -ne $Hash) -or
					($Status -ceq 'verified' -and ($Hash -isnot [string] -or $Hash -cnotmatch '^[0-9a-f]{64}$'))) { throw 'phase_report_invalid' }
			}
			if (($null -eq $BoundRunnerName -and $null -ne $Identity.runnerName) -or
				($null -ne $BoundRunnerName -and ($Identity.runnerName -isnot [string] -or $Identity.runnerName -cne $BoundRunnerName)) -or
				-not (Test-PhaseReportNumber $Identity.durationSeconds)) { throw 'phase_report_invalid' }

			$Builds = @($Report.compileEvidence.builds)
			$ExpectedBuildCheck = if ($ExpectedMode -eq 'PackageClient') { 'scheduled-client-package' } elseif ($ExpectedMode -eq 'PackageServer') { 'scheduled-server-package' } else { $null }
			$ExpectedBuildTarget = if ($ExpectedMode -eq 'PackageClient') { 'AethelnOnlineClient' } elseif ($ExpectedMode -eq 'PackageServer') { 'AethelnOnlineServer' } else { $null }
			$ExpectedBuildPlatform = if ($ExpectedMode -eq 'PackageClient') { 'Win64' } elseif ($ExpectedMode -eq 'PackageServer') { 'Linux' } else { $null }
			if ($null -eq $ExpectedBuildCheck -and $Builds.Count -ne 0) { throw 'phase_report_invalid' }
			if ($null -ne $ExpectedBuildCheck -and ($Builds.Count -gt 1 -or ($Counts.requiredFailed -eq 0 -and $Builds.Count -ne 1))) { throw 'phase_report_invalid' }
			foreach ($Build in $Builds) {
				Assert-ExactPhaseReportObject $Build @(
					'check', 'target', 'platform', 'configuration', 'intermediateBuildDirectoryPresentBeforeRun',
					'makefilePresentBeforeRun', 'outputState', 'lastObservedAction', 'observedTotalActions',
					'actionCounterState', 'plannedActionCount', 'observedTargetNames', 'makefileObservation',
					'makefileReason', 'makefileCreationCount', 'upToDateObserved', 'executorSummaryCount'
				)
				if ($Build.check -isnot [string] -or $Build.check -cne $ExpectedBuildCheck -or
					$Build.target -isnot [string] -or $Build.target -cne $ExpectedBuildTarget -or
					$Build.platform -isnot [string] -or $Build.platform -cne $ExpectedBuildPlatform -or
					$Build.configuration -isnot [string] -or $Build.configuration -cne 'Development' -or
					$Build.intermediateBuildDirectoryPresentBeforeRun -isnot [bool] -or $Build.makefilePresentBeforeRun -isnot [bool] -or
					$Build.outputState -isnot [string] -or @('captured', 'unavailable') -cnotcontains $Build.outputState -or
					$Build.actionCounterState -isnot [string] -or @('observed', 'not_observed') -cnotcontains $Build.actionCounterState -or
					$Build.makefileObservation -isnot [string] -or @('created', 'not_observed') -cnotcontains $Build.makefileObservation -or
					$Build.upToDateObserved -isnot [bool]) { throw 'phase_report_invalid' }
				foreach ($IntegerField in @('makefileCreationCount', 'executorSummaryCount')) {
					if (($Build.$IntegerField -isnot [int] -and $Build.$IntegerField -isnot [long]) -or [long] $Build.$IntegerField -lt 0) { throw 'phase_report_invalid' }
				}
				if ($Build.actionCounterState -ceq 'observed') {
					if (($Build.lastObservedAction -isnot [int] -and $Build.lastObservedAction -isnot [long]) -or
						($Build.observedTotalActions -isnot [int] -and $Build.observedTotalActions -isnot [long]) -or
						[long] $Build.lastObservedAction -lt 1 -or [long] $Build.lastObservedAction -gt [long] $Build.observedTotalActions -or
						[long] $Build.observedTotalActions -gt 10000000) { throw 'phase_report_invalid' }
				} elseif ($null -ne $Build.lastObservedAction -or $null -ne $Build.observedTotalActions) { throw 'phase_report_invalid' }
				if ($null -ne $Build.plannedActionCount -and (($Build.plannedActionCount -isnot [int] -and $Build.plannedActionCount -isnot [long]) -or
					[long] $Build.plannedActionCount -lt 0 -or [long] $Build.plannedActionCount -gt 10000000)) { throw 'phase_report_invalid' }
				if ($null -ne $Build.observedTargetNames -and ($Build.observedTargetNames -isnot [string] -or
					$Build.observedTargetNames -cnotmatch '^(?:AethelnOnlineClient|AethelnOnlineServer|AethelnOnlineEditor|UnrealEditor|UnrealPak|ShaderCompileWorker|other)(?:,(?:AethelnOnlineClient|AethelnOnlineServer|AethelnOnlineEditor|UnrealEditor|UnrealPak|ShaderCompileWorker|other))*$')) { throw 'phase_report_invalid' }
				if ($Build.makefileObservation -ceq 'created') {
					if ($Build.makefileReason -isnot [string] -or $Build.makefileReason -cnotmatch '^[a-z0-9_]{1,64}$' -or [long] $Build.makefileCreationCount -lt 1) { throw 'phase_report_invalid' }
				} elseif ($null -ne $Build.makefileReason -or [long] $Build.makefileCreationCount -ne 0) { throw 'phase_report_invalid' }
				if (-not $Statuses.ContainsKey($Build.check)) { throw 'phase_report_invalid' }
			}
		}
		if ($Counts.requiredFailed -eq 0) {
			# A zero exit may be relayed only when the child reached every required
			# terminal checkpoint for its phase. JSON and summary consistency alone
			# cannot turn an empty or prematurely finalized report into success.
			$RequiredSuccessChecks = switch ($ExpectedMode) {
				'PackageClient' { @(
					'runner-input-validation', 'ddc-cache-configuration', 'host-tools-configuration',
					'handoff-validation', 'handoff-storage-accounting', 'repository-state-before-work',
					'scheduled-client-package', 'repository-state-after-client-package',
					'handoff-publish-client', 'repository-state-at-completion'
				) }
				'PackageServer' { @(
					'runner-input-validation', 'ddc-cache-configuration', 'host-tools-configuration',
					'handoff-validation', 'handoff-run-directory', 'repository-state-before-work',
					'scheduled-server-package', 'repository-state-after-server-package',
					'handoff-publish-server', 'repository-state-at-completion'
				) }
				'ValidateProvenance' { @(
					'runner-input-validation', 'handoff-validation', 'handoff-run-directory',
					'repository-state-before-work', 'handoff-consume-client', 'handoff-consume-server',
					'registry-provenance-validation', 'repository-state-after-provenance-validation',
					'handoff-publish-provenance', 'repository-state-at-completion'
				) }
				'SmokePhase' { @(
					'runner-input-validation', 'handoff-validation', 'handoff-run-directory',
					'repository-state-before-work', 'handoff-consume-client', 'handoff-consume-server',
					'handoff-consume-provenance', 'packaged-build-smoke',
					'handoff-milestone-completion', 'repository-state-at-completion'
				) }
				default { throw 'phase_report_invalid' }
			}
			if ($Counts.skipped -ne 0) { throw 'phase_report_invalid' }
			foreach ($RequiredCheck in $RequiredSuccessChecks) {
				if (-not $Statuses.ContainsKey($RequiredCheck) -or $Statuses[$RequiredCheck] -cne 'passed') { throw 'phase_report_invalid' }
			}
		}
		return $Report
	} catch { throw 'phase_report_invalid' }
}

function Invoke-PhaseSupervisor {
	# Hard bound for the whole controlled gate interval: the parent owns the
	# absolute deadline and the report, while the complete phase body - handoff
	# validation, cleanup/root scans, manifest reads, payload hashing, smoke
	# discovery, build/smoke work, and timeout finalization - runs as this same
	# script re-invoked inside an owned kill-on-close child tree. The child
	# keeps the cooperative script-phase deadline for precise per-check
	# evidence; the parent stops and verifies the whole tree at
	# PhaseTimeoutMinutes plus a bounded finalization grace, so no synchronous
	# operation and no post-timeout finalization can outlive the bound.
	$WatchdogRoot = Join-Path $ResolvedLogs ('phase-supervisor-' + [guid]::NewGuid().ToString('N'))
	$ChildReportPath = Join-Path $WatchdogRoot 'child-report.json'
	try {
		$NonceBytes = New-Object byte[] 32
		$Random = [Security.Cryptography.RandomNumberGenerator]::Create()
		try { $Random.GetBytes($NonceBytes) } finally { $Random.Dispose() }
		$SupervisorNonce = [BitConverter]::ToString($NonceBytes).Replace('-', '').ToLowerInvariant()
		$SupervisorParentProcess = Get-Process -Id $PID -ErrorAction Stop
		$SupervisorParentProcessId = $PID.ToString([Globalization.CultureInfo]::InvariantCulture)
		$SupervisorParentStartTicks = $SupervisorParentProcess.StartTime.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
	} catch { throw 'phase_supervisor_auth_invalid' }
	$ChildParameters = [ordered]@{
		Mode = $Mode
		RepositoryRoot = $ResolvedRepository
		SourceRevision = $SourceRevision
		LogRoot = (Join-Path $ResolvedLogs 'phase')
		Repository = $Repository
		RunId = $RunId
		RunAttempt = $RunAttempt
		RunnerName = $RunnerName
		PhaseTimeoutMinutes = [string] $PhaseTimeoutMinutes
		HandoffPayloadCapBytes = [string] $HandoffPayloadCapBytes
		HandoffRootCapBytes = [string] $HandoffRootCapBytes
		HandoffStaleHours = [string] $HandoffStaleHours
		PhaseFinalizeGraceSeconds = [string] $PhaseFinalizeGraceSeconds
		PhaseSupervisorNonce = $SupervisorNonce
		PhaseSupervisorParentProcessId = $SupervisorParentProcessId
		PhaseSupervisorParentStartTicks = $SupervisorParentStartTicks
	}
	$ChildParameters['ReportPath'] = $ChildReportPath
	$BoundedGraceSeconds = [Math]::Min([Math]::Max($PhaseFinalizeGraceSeconds, 1), 600)
	$HardDeadlineUtc = $Started.AddMinutes($PhaseTimeoutMinutes).AddSeconds($BoundedGraceSeconds)
	$RemainingMinutes = ($HardDeadlineUtc - [DateTime]::UtcNow).TotalMinutes
	if ($RemainingMinutes -le 0) { return [ordered]@{ timedOut = $true; exitCode = -1; output = @(); cleanupFailure = $null } }
	$AuthenticationEnvironment = [ordered]@{
		AETHELN_PHASE_SUPERVISED = '1'
		AETHELN_PHASE_SUPERVISOR_NONCE = $SupervisorNonce
		AETHELN_PHASE_SUPERVISOR_PARENT_PROCESS_ID = $SupervisorParentProcessId
		AETHELN_PHASE_SUPERVISOR_PARENT_START_TICKS = $SupervisorParentStartTicks
	}
	$PreviousAuthenticationEnvironment = @{}
	foreach ($Name in $AuthenticationEnvironment.Keys) {
		$PreviousAuthenticationEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
	}
	try {
		foreach ($Name in $AuthenticationEnvironment.Keys) {
			[Environment]::SetEnvironmentVariable($Name, $AuthenticationEnvironment[$Name], 'Process')
		}
		$Result = Invoke-PhaseChildScript -InvocationText (ConvertTo-NamedInvocationText $PSCommandPath $ChildParameters) -TimeoutMinutes $RemainingMinutes -UseNativeExitCode $true -WatchdogRoot $WatchdogRoot
		$Result['childReportPath'] = $ChildReportPath
		return $Result
	} finally {
		foreach ($Name in $AuthenticationEnvironment.Keys) {
			[Environment]::SetEnvironmentVariable($Name, $PreviousAuthenticationEnvironment[$Name], 'Process')
		}
	}
}

function Invoke-BoundedGateCommand([string] $InvocationText, [datetime] $DeadlineUtc, [bool] $UseNativeExitCode = $false) {
	$RemainingMinutes = ($DeadlineUtc - [DateTime]::UtcNow).TotalMinutes
	if ($RemainingMinutes -le 0) { throw 'phase_timeout' }
	$Result = Invoke-PhaseChildScript -InvocationText $InvocationText -TimeoutMinutes $RemainingMinutes -UseNativeExitCode $UseNativeExitCode
	if (-not [string]::IsNullOrWhiteSpace([string] $Result.cleanupFailure)) { throw 'phase_cleanup_failed' }
	if ($Result.timedOut) { throw 'phase_timeout' }
	return $Result
}

function Invoke-GateCommand([string] $Executable, [string[]] $Arguments) {
	if ($script:SmokeDeadlineUtc -eq [DateTime]::MaxValue) { return Invoke-Captured $Executable $Arguments }
	$Result = Invoke-BoundedGateCommand -InvocationText (ConvertTo-PositionalInvocationText $Executable $Arguments) -DeadlineUtc $script:SmokeDeadlineUtc -UseNativeExitCode $true
	return [ordered]@{ output = @($Result.output); exitCode = $Result.exitCode }
}

function Invoke-SmokeGateWork([string] $SearchRoot, [datetime] $DeadlineUtc = [DateTime]::MaxValue) {
	$SmokeStarted = [DateTime]::UtcNow
	$SmokeOutput = New-Object System.Collections.ArrayList
	$SmokeProtectedValues = @($ProtectedValues)
	$SmokeFailure = $null
	$script:SmokeDeadlineUtc = $DeadlineUtc
	$ServerLauncherArgumentVector = @('-d', 'Ubuntu', '-u', 'aethelnqa', '--exec', '{ServerExecutable}', '{ServerMap}', '-port=7777', '-stdout', '-FullStdOutLogOutput')
	$ClientBaseArgumentVector = @('{ServerEndpoint}', '-stdout', '-FullStdOutLogOutput')
	try {
		if ([DateTime]::UtcNow -ge $script:SmokeDeadlineUtc) { throw 'phase_timeout' }
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
			$SmokeChild = Invoke-BoundedGateCommand -InvocationText (ConvertTo-NamedInvocationText $SmokeScript $SmokeParameters) -DeadlineUtc $script:SmokeDeadlineUtc -UseNativeExitCode $false
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
		Add-Check -Name 'packaged-build-smoke' -Status 'passed' -CheckStarted $SmokeStarted -Command 'Invoke-PackagedSmokeTest.ps1' -Message 'smoke_passed'
	} catch {
		[void] $SmokeOutput.Add($_)
		$SafeReason = [string] $_.Exception.Message
		if ($SafeReason -notmatch '^[a-z0-9_]+$') { $SafeReason = 'smoke_failed' }
		$SmokeMessage = Get-SafeDiagnosticMessage -Reason $SafeReason -Output $SmokeOutput -ProtectedValues $SmokeProtectedValues
		Add-Check -Name 'packaged-build-smoke' -Status 'failed' -CheckStarted $SmokeStarted -Command 'Invoke-PackagedSmokeTest.ps1' -Message $SmokeMessage
		$SmokeFailure = $SafeReason
	} finally {
		$script:SmokeDeadlineUtc = [DateTime]::MaxValue
	}
	return $SmokeFailure
}

function Invoke-HandoffPublish([string] $PublishRunDirectory, [string] $Phase, [string[]] $Consumers) {
	$CheckStarted = [DateTime]::UtcNow
	try {
		Write-HandoffManifest -RunDirectory $PublishRunDirectory -Phase $Phase -Consumers $Consumers
		Add-Check -Name ('handoff-publish-{0}' -f $Phase) -Status 'passed' -CheckStarted $CheckStarted -Command 'write-handoff-manifest' -Message 'handoff_published'
	} catch {
		$Reason = [string] $_.Exception.Message
		if ($Reason -notmatch '^[a-z0-9_]+$') { $Reason = 'handoff_payload_invalid' }
		Add-Check -Name ('handoff-publish-{0}' -f $Phase) -Status 'failed' -CheckStarted $CheckStarted -Command 'write-handoff-manifest' -Message $Reason
		throw $Reason
	}
}

function Invoke-HandoffConsumeSet([string] $ConsumeRunDirectory, [string[]] $Phases, [string] $ConsumingPhase) {
	# The complete required manifest set for the consumer is validated as one
	# closed set: every manifest and payload passes the full per-manifest
	# checks, the aggregate totalBytes stays under the single per-run payload
	# cap with overflow-safe accounting, and no phase directory is returned
	# until the whole set is accepted.
	$Directories = [ordered]@{}
	$AggregateBytes = [long] 0
	foreach ($Phase in $Phases) {
		$CheckStarted = [DateTime]::UtcNow
		try {
			Assert-PhaseDeadline
			$Verified = Test-HandoffManifest -RunDirectory $ConsumeRunDirectory -Phase $Phase -ConsumingPhase $ConsumingPhase
			$AggregateBytes += [long] $Verified.totalBytes
			if ($AggregateBytes -lt 0 -or $AggregateBytes -gt $HandoffPayloadCapBytes) { throw 'handoff_size_exceeded' }
			$Directories[$Phase] = $Verified.phaseDirectory
			Add-Check -Name ('handoff-consume-{0}' -f $Phase) -Status 'passed' -CheckStarted $CheckStarted -Command 'verify-handoff-manifest' -Message 'handoff_verified'
		} catch {
			$Reason = [string] $_.Exception.Message
			if ($Reason -notmatch '^[a-z0-9_]+$') { $Reason = 'handoff_schema_invalid' }
			Add-Check -Name ('handoff-consume-{0}' -f $Phase) -Status 'failed' -CheckStarted $CheckStarted -Command 'verify-handoff-manifest' -Message $Reason
			throw $Reason
		}
	}
	return $Directories
}

try {
	if (($ManagedCompile -and $Mode -ne 'Compile') -or
		(-not $ManagedCompile -and (-not [string]::IsNullOrWhiteSpace($HostLeasePath) -or
			-not [string]::IsNullOrWhiteSpace($ManagedWorkspaceRegistrationPath) -or
			-not [string]::IsNullOrWhiteSpace($ManagedWorkspaceRegistrationSha256)))) { throw 'managed_workspace_configuration_invalid' }
	if ($ManagedCompile -and ([string]::IsNullOrWhiteSpace($ManagedWorkspaceRoot) -or
		[string]::IsNullOrWhiteSpace($HostLeasePath) -or
		[string]::IsNullOrWhiteSpace($ManagedWorkspaceRegistrationPath) -or
		$ManagedWorkspaceRegistrationSha256 -cnotmatch '^[0-9a-f]{64}$' -or
		$Repository -cnotmatch $RepositoryPattern)) { throw 'managed_workspace_configuration_invalid' }
	$ResolvedRepository = Resolve-RequiredDirectory $RepositoryRoot 'repository_root_invalid'
	if ($HasPhaseSupervisorAuthenticationSignal) {
		try {
			if (-not $IsPhaseMode) { throw 'phase_supervisor_auth_invalid' }
			Initialize-EngineGateJobType
			$ActualParentProcessId = [Aetheln.EngineGateJob]::GetCurrentParentProcessId()
			$ActualParentProcess = Get-Process -Id $ActualParentProcessId -ErrorAction Stop
			$ActualParentStartTicks = $ActualParentProcess.StartTime.ToUniversalTime().Ticks
			$IsAuthenticatedPhaseChild = Test-PhaseSupervisorAuthentication `
				-Marker $PhaseSupervisorMarker `
				-EnvironmentNonce $PhaseSupervisorEnvironmentNonce `
				-EnvironmentParentProcessId $PhaseSupervisorEnvironmentParentProcessId `
				-EnvironmentParentStartTicks $PhaseSupervisorEnvironmentParentStartTicks `
				-ParameterNonce $PhaseSupervisorNonce `
				-ParameterParentProcessId $PhaseSupervisorParentProcessId `
				-ParameterParentStartTicks $PhaseSupervisorParentStartTicks `
				-ActualParentProcessId $ActualParentProcessId `
				-ActualParentStartTicks $ActualParentStartTicks
			if (-not $IsAuthenticatedPhaseChild) { throw 'phase_supervisor_auth_invalid' }
		} catch { $PhaseSupervisorAuthenticationInvalid = $true }
	}
	$IsPhaseSupervisorParent = $IsPhaseMode -and -not $IsAuthenticatedPhaseChild
	if ($ExplicitReportRequested -or $IsPhaseSupervisorParent) {
		$RequestedReport = if ($ExplicitReportRequested) { $ReportPath } else { Join-Path $ResolvedRepository 'TestResults\engine-runner-report.json' }
		if ($RequestedReport -notmatch '^[A-Za-z]:[\\/]' -or $RequestedReport -match '^[\\/]{2}' -or $RequestedReport.Substring(2).Contains(':')) { throw 'report_path_invalid' }
		$CandidateReport = [IO.Path]::GetFullPath($RequestedReport)
		if (Test-Path -LiteralPath $CandidateReport) { throw 'report_path_exists' }
		$Ancestor = Split-Path $CandidateReport
		while ($Ancestor) {
			if ((Test-Path -LiteralPath $Ancestor) -and (Test-IsReparsePoint $Ancestor)) { throw 'report_path_invalid' }
			$Ancestor = Split-Path $Ancestor
		}
		$ResolvedReportPath = $CandidateReport
	}
	if ($PhaseSupervisorAuthenticationInvalid) {
		Add-Check -Name 'runner-input-validation' -Status 'failed' -CheckStarted $Started -Command 'validate-phase-supervisor-authentication' -Message 'phase_supervisor_auth_invalid'
		throw 'phase_supervisor_auth_invalid'
	}
	if ($Mode -eq 'Compile') {
		if ([double]::IsNaN($CompileTimeoutMinutes) -or [double]::IsInfinity($CompileTimeoutMinutes) -or $CompileTimeoutMinutes -le 0 -or $CompileTimeoutMinutes -gt 30) {
			Add-Check -Name 'runner-input-validation' -Status 'failed' -CheckStarted $Started -Command 'validate-runner-inputs' -Message 'compile_timeout_invalid'
			throw 'compile_timeout_invalid'
		}
		if ($ManagedCompile) {
			. (Join-Path $PSScriptRoot 'RoutineCompileDeadline.ps1')
			if ($IsCompileChild) {
				$CompileStartedUtc = $CompileSupervisorContext.startedUtc
				$CompileStartedTimestamp = $CompileSupervisorContext.startedTimestamp
			}
			$RoutineDeadline = New-RoutineCompileDeadline -StartedUtc $CompileStartedUtc -StartedTimestamp $CompileStartedTimestamp -TimeoutMinutes $CompileTimeoutMinutes
			$Started = [DateTime]::ParseExact($CompileStartedUtc, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
			$CompileDeadlineUtc = Get-RoutineCompileDeadlineUtc -Deadline $RoutineDeadline
		} else { $CompileDeadlineUtc = $Started.AddMinutes($CompileTimeoutMinutes) }
		if (-not $IsCompileChild) {
			$ResolvedLogs = Resolve-OutputRoot -Value $LogRoot -Repository $ResolvedRepository -ReasonCode 'log_root_invalid'
			Invoke-CompileSupervisor
			Write-RunnerReport
			$SupervisedChildExited = $true
			Write-Output 'engine_runner_passed'
			exit 0
		}
	}
	if ($ManagedCompile) {
		$WorkspaceStarted = [DateTime]::UtcNow
		try {
			. (Join-Path $PSScriptRoot 'ManagedCompileRegistration.ps1')
			. (Join-Path $PSScriptRoot 'ManagedCompileWorkspace.ps1')
			$ManagedRegistration = Get-ManagedCompileRegistration -Path $ManagedWorkspaceRegistrationPath -ExpectedSha256 $ManagedWorkspaceRegistrationSha256 -Repository $Repository -TargetRoot $ManagedWorkspaceRoot
			. (Join-Path $PSScriptRoot 'RoutineCompileResources.ps1')
			. (Join-Path $PSScriptRoot 'RoutineCompileCommand.ps1')
			Initialize-ManagedCompileResourceMonitor
			$ControlRoot = $ResolvedRepository
			$Registered = $ManagedRegistration.record
			# Authorization comes from the separately registered operator tuple;
			# this is not endpoint/filter/hook certification by candidate code.
			$TrustRegisteredWorkspace = {
				param($ProposedControl, $ProposedTarget, $ProposedRepository, $ProposedRevision)
				return ($ProposedControl -ceq $ControlRoot -and
					[string]::Equals([IO.Path]::GetFullPath($ProposedTarget).TrimEnd('\', '/'), [IO.Path]::GetFullPath($Registered.targetRoot).TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase) -and
					$ProposedRepository -ceq $Registered.repository -and $ProposedRevision -ceq $SourceRevision)
			}
			$null = Sync-ManagedCompileWorkspace -ControlRoot $ControlRoot -TargetRoot $ManagedWorkspaceRoot -SourceRevision $SourceRevision -Repository $Repository -ExpectedGitCommonDirectory $Registered.gitCommonDirectory -DeadlineUtc $CompileDeadlineUtc -RemainingBudget { Get-RoutineCompileRemainingMillisecondCount -Deadline $RoutineDeadline } -AssertRepositoryTrust $TrustRegisteredWorkspace -OnProgress { Assert-RoutineCompileProgress }
			$ResolvedRepository = Resolve-RequiredDirectory $ManagedWorkspaceRoot 'managed_workspace_root_invalid'
			$ManagedWorkspaceEvidence = [ordered]@{ schemaVersion = 1; registrationId = $Registered.registrationId;
				registrationSha256 = $ManagedWorkspaceRegistrationSha256; preparationReceiptSha256 = $Registered.preparationReceiptSha256;
				revision = $SourceRevision; synchronized = $true }
			Add-Check -Name 'managed-compile-workspace' -Status 'passed' -CheckStarted $WorkspaceStarted -Command 'synchronize-registered-workspace' -Message 'managed_workspace_synchronized'
		} catch {
			$Reason = [string] $_.Exception.Message
			if ($Reason -cnotmatch '^managed_workspace_[a-z_]+$' -and $Reason -cnotin @('compile_timeout', 'compile_clock_invalid', 'resource_pressure', 'disk_floor_reached')) { $Reason = 'managed_workspace_failed' }
			Add-Check -Name 'managed-compile-workspace' -Status 'failed' -CheckStarted $WorkspaceStarted -Command 'synchronize-registered-workspace' -Message $Reason
			throw $Reason
		}
	}
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
		$ResolvedArchive = if ($IsPhaseMode) { $null } else { Resolve-OutputRoot -Value $ArchiveRoot -Repository $ResolvedRepository -ReasonCode 'archive_root_invalid' }
		$ResolvedLogs = Resolve-OutputRoot -Value $LogRoot -Repository $ResolvedRepository -ReasonCode 'log_root_invalid'
		if ($SourceRevision -notmatch '^[0-9a-fA-F]{40}$') { throw 'revision_invalid' }
		Add-Check -Name 'runner-input-validation' -Status 'passed' -CheckStarted $ValidationStarted -Command 'validate-runner-inputs' -Message 'validation_passed'
	} catch {
		Add-Check -Name 'runner-input-validation' -Status 'failed' -CheckStarted $ValidationStarted -Command 'validate-runner-inputs' -Message ([string] $_.Exception.Message)
		throw
	}
	$ProtectedValues = @($ResolvedRepository, $RepositoryRoot, $ManagedWorkspaceRegistrationPath, $HostLeasePath, $ProjectPath, $BuildScript, $SmokeScript, $BuildBatch, $EngineRoot, $ToolchainRoot, $ResolvedArchive, $ResolvedLogs)

	$DdcRoot = $null
	$DdcFallback = 'FailClosed'
	if ($Mode -in @('PackagedSmoke', 'PackageClient', 'PackageServer')) {
		# Optional persistent local DDC for the cook: AETHELN_DDC_ROOT names an
		# existing local fixed directory disjoint from every other approved
		# root; AETHELN_DDC_FALLBACK selects the build controller's behavior on
		# cache-identity mismatch. Unset means unchanged engine-default DDC.
		$DdcStarted = [DateTime]::UtcNow
		try {
			$DdcValue = [Environment]::GetEnvironmentVariable('AETHELN_DDC_ROOT', 'Process')
			if ([string]::IsNullOrWhiteSpace($DdcValue)) {
				Add-Check -Name 'ddc-cache-configuration' -Status 'passed' -CheckStarted $DdcStarted -Command 'resolve-ddc-configuration' -Message 'ddc_not_configured'
			} else {
				if ($DdcValue -match '^[\\/]{2}') { throw 'ddc_root_invalid' }
				if (-not [System.IO.Path]::IsPathRooted($DdcValue)) { throw 'ddc_root_invalid' }
				if (-not (Test-Path -LiteralPath $DdcValue -PathType Container)) { throw 'ddc_root_invalid' }
				$DdcFull = (Resolve-Path -LiteralPath $DdcValue).Path
				if ($DdcFull -notmatch '^[A-Za-z]:\\.') { throw 'ddc_root_invalid' }
				if (Test-IsReparsePoint $DdcFull) { throw 'ddc_root_invalid' }
				foreach ($Forbidden in @($ResolvedRepository, $EngineRoot, $ToolchainRoot, $ResolvedArchive, $ResolvedLogs, [Environment]::GetEnvironmentVariable('AETHELN_HANDOFF_ROOT', 'Process'))) {
					if ([string]::IsNullOrWhiteSpace($Forbidden)) { continue }
					$ForbiddenFull = [System.IO.Path]::GetFullPath($Forbidden)
					if ((Test-IsWithin $DdcFull $ForbiddenFull) -or (Test-IsWithin $ForbiddenFull $DdcFull)) { throw 'ddc_root_invalid' }
				}
				$FallbackValue = [Environment]::GetEnvironmentVariable('AETHELN_DDC_FALLBACK', 'Process')
				if ([string]::IsNullOrWhiteSpace($FallbackValue)) { $FallbackValue = 'fail-closed' }
				$DdcFallback = switch ($FallbackValue) {
					'fail-closed' { 'FailClosed' }
					'clean-isolated' { 'CleanIsolated' }
					default { throw 'ddc_fallback_invalid' }
				}
				$DdcRoot = $DdcFull
				Add-Check -Name 'ddc-cache-configuration' -Status 'passed' -CheckStarted $DdcStarted -Command 'resolve-ddc-configuration' -Message 'ddc_configured'
			}
		} catch {
			$Reason = [string] $_.Exception.Message
			if ($Reason -notmatch '^[a-z0-9_]+$') { $Reason = 'ddc_root_invalid' }
			Add-Check -Name 'ddc-cache-configuration' -Status 'failed' -CheckStarted $DdcStarted -Command 'resolve-ddc-configuration' -Message $Reason
			throw $Reason
		}
		if ($null -ne $DdcRoot) { $ProtectedValues += @($DdcRoot) }
	}

	$HostToolsArguments = @{}
	if ($Mode -in @('PackagedSmoke', 'PackageClient', 'PackageServer')) {
		# Mandatory host-tools selection for the packaging modes: unset
		# configuration fails closed so one missing runner variable can never
		# silently launch another multi-hour host editor/engine rebuild.
		# 'prebuilt' requires the pinned engine revision and the external
		# attestation record; 'rebuild-authorized' is the explicit, separately
		# named operator authorization for a full host-tools rebuild.
		$HostToolsStarted = [DateTime]::UtcNow
		try {
			$HostToolsValue = [Environment]::GetEnvironmentVariable('AETHELN_HOST_TOOLS', 'Process')
			if ([string]::IsNullOrWhiteSpace($HostToolsValue)) { throw 'host_tools_configuration_required' }
			if ($HostToolsValue -eq 'rebuild-authorized') {
				$HostToolsArguments = @{ HostToolsBoundary = 'Rebuild' }
				Add-Check -Name 'host-tools-configuration' -Status 'passed' -CheckStarted $HostToolsStarted -Command 'resolve-host-tools-configuration' -Message 'host_tools_rebuild_authorized'
			} elseif ($HostToolsValue -eq 'prebuilt') {
				$EngineRevisionValue = [Environment]::GetEnvironmentVariable('AETHELN_ENGINE_REVISION', 'Process')
				if ([string]::IsNullOrWhiteSpace($EngineRevisionValue) -or $EngineRevisionValue -notmatch '^[0-9a-fA-F]{40}$') { throw 'engine_revision_invalid' }
				$AttestationValue = [Environment]::GetEnvironmentVariable('AETHELN_HOST_TOOLS_ATTESTATION', 'Process')
				if ([string]::IsNullOrWhiteSpace($AttestationValue)) { throw 'host_tools_attestation_invalid' }
				if ($AttestationValue -match '^[\\/]{2}') { throw 'host_tools_attestation_invalid' }
				if (-not [System.IO.Path]::IsPathRooted($AttestationValue)) { throw 'host_tools_attestation_invalid' }
				if (-not (Test-Path -LiteralPath $AttestationValue -PathType Leaf)) { throw 'host_tools_attestation_invalid' }
				$AttestationFull = (Resolve-Path -LiteralPath $AttestationValue).Path
				if ($AttestationFull -notmatch '^[A-Za-z]:\\.') { throw 'host_tools_attestation_invalid' }
				if (Test-IsReparsePoint $AttestationFull) { throw 'host_tools_attestation_invalid' }
				foreach ($Forbidden in @($ResolvedRepository, $EngineRoot, $ToolchainRoot, $ResolvedArchive, $ResolvedLogs, [Environment]::GetEnvironmentVariable('AETHELN_HANDOFF_ROOT', 'Process'))) {
					if ([string]::IsNullOrWhiteSpace($Forbidden)) { continue }
					$ForbiddenFull = [System.IO.Path]::GetFullPath($Forbidden)
					if ((Test-IsWithin $AttestationFull $ForbiddenFull) -or (Test-IsWithin $ForbiddenFull $AttestationFull)) { throw 'host_tools_attestation_invalid' }
				}
				$HostToolsArguments = @{ HostToolsBoundary = 'Prebuilt'; EngineRevision = $EngineRevisionValue.ToLowerInvariant(); HostToolsAttestationPath = $AttestationFull }
				Add-Check -Name 'host-tools-configuration' -Status 'passed' -CheckStarted $HostToolsStarted -Command 'resolve-host-tools-configuration' -Message 'host_tools_prebuilt'
			} else { throw 'host_tools_invalid' }
		} catch {
			$Reason = [string] $_.Exception.Message
			if ($Reason -notmatch '^[a-z0-9_]+$') { $Reason = 'host_tools_invalid' }
			Add-Check -Name 'host-tools-configuration' -Status 'failed' -CheckStarted $HostToolsStarted -Command 'resolve-host-tools-configuration' -Message $Reason
			throw $Reason
		}
		if ($HostToolsArguments.ContainsKey('HostToolsAttestationPath')) { $ProtectedValues += @($HostToolsArguments['HostToolsAttestationPath']) }
		# Forward the validated runner identity so the build controller can bind
		# its timing evidence to the runner without reading the environment.
		if ($RunnerName -match $RunnerNamePattern) { $HostToolsArguments['RunnerName'] = $RunnerName }
	}

	if ($IsPhaseMode -and $PhaseTimeoutMinutes -gt 0 -and $PhaseTimeoutMinutes -le 1440 -and -not $IsAuthenticatedPhaseChild) {
		# Supervisor (parent) path: the child writes only a private bounded report.
		# After the owned Job Object proves quiescence, this parent validates that
		# report, attaches its own cleanup receipt, and create-only publishes the
		# final evidence exactly once. Child exit can never imply descendant cleanup.
		$SupervisorStarted = [DateTime]::UtcNow
		$SupervisorResult = Invoke-PhaseSupervisor
		$OuterCleanupVerified = $SupervisorResult.Contains('cleanupVerified') -and
			$SupervisorResult.cleanupVerified -is [bool] -and $SupervisorResult.cleanupVerified -and
			$SupervisorResult.Contains('cleanupFailure') -and [string]::IsNullOrWhiteSpace([string] $SupervisorResult.cleanupFailure)
		$script:SupervisorReceipt = [ordered]@{
			childExitCode = $SupervisorResult.exitCode
			timedOut = [bool] $SupervisorResult.timedOut
			cleanupVerified = $OuterCleanupVerified
		}
		if (-not $OuterCleanupVerified -or $SupervisorResult.timedOut) {
			$HardReason = if ($OuterCleanupVerified) { 'phase_timeout' } else { 'phase_cleanup_failed' }
			Add-Check -Name 'phase-hard-deadline' -Status 'failed' -CheckStarted $SupervisorStarted -Command 'supervise-phase-child-tree' -Message $HardReason
			$SupervisedChildExited = $true
			Write-RunnerReport
			throw $HardReason
		}
		try {
			$ChildReport = Read-PhaseSupervisorReport -Path ([string] $SupervisorResult.childReportPath) -ExpectedMode $Mode -ExpectedRevision $SourceRevision -ExpectedRunnerName $RunnerName
			$ChildFailed = [long] $ChildReport.summary.requiredFailed -gt 0
			if (($SupervisorResult.exitCode -eq 0 -and $ChildFailed) -or ($SupervisorResult.exitCode -ne 0 -and -not $ChildFailed)) { throw 'phase_report_invalid' }
			$script:RelayedReport = $ChildReport
		} catch {
			Add-Check -Name 'phase-supervisor-report' -Status 'failed' -CheckStarted $SupervisorStarted -Command 'validate-private-phase-report' -Message 'phase_report_invalid'
			$SupervisedChildExited = $true
			Write-RunnerReport
			throw 'phase_report_invalid'
		}
		$SupervisedChildExited = $true
		Write-RunnerReport
		foreach ($Line in @($SupervisorResult.output)) { Write-Output ([string] $Line) }
		if ($SupervisorResult.exitCode -ne 0) { exit 1 }
		exit 0
	}

	# Resolved once per gate process that writes its own report (Compile,
	# PackagedSmoke, and the supervised phase child); the parent's hard-timeout
	# report deliberately carries no compile evidence.
	$CompileEvidenceIdentity = Resolve-CompileEvidenceIdentity

	if ($IsPhaseMode -and $PhaseTimeoutMinutes -gt 0 -and $PhaseTimeoutMinutes -le 1440) {
		# One absolute cooperative script-phase deadline, anchored at script
		# start, covers the whole gate-script interval: every later handoff,
		# cleanup-scan, root-accounting, manifest, hashing, and child operation
		# consumes remaining time from it. This branch runs only in the
		# supervised child, whose whole tree the parent additionally hard-kills
		# at this deadline plus the bounded finalization grace. An out-of-range
		# timeout is still rejected by Assert-PhaseContext.
		$script:PhaseDeadlineUtc = $Started.AddMinutes($PhaseTimeoutMinutes)
	}

	$HandoffRoot = $null
	$ScopeRoot = $null
	$RunDirectory = $null
	$PhaseName = $null
	if ($IsPhaseMode) {
		$PhaseName = $PhaseByMode[$Mode]
		$HandoffStarted = [DateTime]::UtcNow
		try {
			Assert-PhaseDeadline
			Assert-PhaseContext
			$HandoffRoot = Resolve-HandoffRoot @($ResolvedRepository, $EngineRoot, $ToolchainRoot, [Environment]::GetEnvironmentVariable('RUNNER_TEMP', 'Process'), [Environment]::GetEnvironmentVariable('GITHUB_WORKSPACE', 'Process'))
			$RepositoryParts = $Repository -split '/'
			$OwnerRoot = Get-HandoffChildPath -Parent $HandoffRoot -Child $RepositoryParts[0] -ReasonCode 'handoff_root_invalid'
			$ScopeRoot = Get-HandoffChildPath -Parent $OwnerRoot -Child $RepositoryParts[1] -ReasonCode 'handoff_root_invalid'
			$RunDirectory = Get-HandoffChildPath -Parent $ScopeRoot -Child ('run-{0}-attempt-{1}' -f $RunId, $RunAttempt) -ReasonCode 'handoff_root_invalid'
			Assert-PathChainSafe -Root $HandoffRoot -Leaf $RunDirectory -ReasonCode 'handoff_root_invalid'
			if (-not (Test-Path -LiteralPath $ScopeRoot)) { New-Item -ItemType Directory -Path $ScopeRoot -Force | Out-Null }
			Add-Check -Name 'handoff-validation' -Status 'passed' -CheckStarted $HandoffStarted -Command 'validate-handoff-context' -Message 'handoff_context_valid'
		} catch {
			$Reason = [string] $_.Exception.Message
			if ($Reason -notmatch '^[a-z0-9_]+$') { $Reason = 'handoff_root_invalid' }
			Add-Check -Name 'handoff-validation' -Status 'failed' -CheckStarted $HandoffStarted -Command 'validate-handoff-context' -Message $Reason
			throw $Reason
		}
		$ProtectedValues += @($HandoffRoot, $ScopeRoot, $RunDirectory)

		if ($Mode -eq 'PackageClient') {
			$StorageStarted = [DateTime]::UtcNow
			try {
				Assert-PhaseDeadline
				Write-CleanupRequest $ScopeRoot $PhaseName
				# The committed measurement spans the complete validated handoff
				# root, so every repository scope counts toward the total cap.
				# Reparse points are never traversed or counted: their content
				# does not live under the root.
				$CommittedBytes = Get-DirectoryByteCount -Root $HandoffRoot -ReasonCode 'handoff_storage_exhausted' -SkipReparse $true
				if ($CommittedBytes -gt ($HandoffRootCapBytes - $HandoffPayloadCapBytes)) { throw 'handoff_storage_exhausted' }
				if (Test-Path -LiteralPath $RunDirectory) { throw 'handoff_conflict' }
				New-Item -ItemType Directory -Path $RunDirectory | Out-Null
				Write-RunContextRecord
				Add-Check -Name 'handoff-storage-accounting' -Status 'passed' -CheckStarted $StorageStarted -Command 'reserve-handoff-storage' -Message 'handoff_storage_reserved'
			} catch {
				$Reason = [string] $_.Exception.Message
				if ($Reason -notmatch '^[a-z0-9_]+$') { $Reason = 'handoff_storage_exhausted' }
				Add-Check -Name 'handoff-storage-accounting' -Status 'failed' -CheckStarted $StorageStarted -Command 'reserve-handoff-storage' -Message $Reason
				throw $Reason
			}
		} else {
			$RunContextStarted = [DateTime]::UtcNow
			try {
				Assert-PhaseDeadline
				if (-not (Test-Path -LiteralPath $RunDirectory -PathType Container)) { throw 'handoff_missing' }
				[void] (Test-RunContextRecord $RunDirectory $true)
				Add-Check -Name 'handoff-run-directory' -Status 'passed' -CheckStarted $RunContextStarted -Command 'validate-handoff-run-context' -Message 'handoff_run_context_valid'
			} catch {
				$Reason = [string] $_.Exception.Message
				if ($Reason -notmatch '^[a-z0-9_]+$') { $Reason = 'handoff_context_invalid' }
				Add-Check -Name 'handoff-run-directory' -Status 'failed' -CheckStarted $RunContextStarted -Command 'validate-handoff-run-context' -Message $Reason
				throw $Reason
			}
		}
	}

	Assert-RepositoryState 'repository-state-before-work'

	if ($Mode -eq 'Compile') {
		$Targets = @(
			[ordered]@{ name = 'incremental-client-build'; label = 'AethelnOnlineClient Win64 Development'; target = 'AethelnOnlineClient'; platform = 'Win64'; arguments = @('AethelnOnlineClient', 'Win64', 'Development', $ProjectPath, '-WaitMutex', '-NoHotReloadFromIDE') },
			[ordered]@{ name = 'incremental-server-build'; label = 'AethelnOnlineServer Linux Development'; target = 'AethelnOnlineServer'; platform = 'Linux'; arguments = @('AethelnOnlineServer', 'Linux', 'Development', $ProjectPath, '-WaitMutex', '-NoHotReloadFromIDE') }
		)
		foreach ($Target in $Targets) {
			if ($ManagedCompile) { Assert-RoutineCompileProgress }
			elseif ([DateTime]::UtcNow -ge $CompileDeadlineUtc) { throw 'compile_timeout' }
			$Presence = Get-IntermediatePresence $Target.platform $Target.target
			$BuildStarted = [DateTime]::UtcNow
			$BuildResult = if ($ManagedCompile) { Invoke-RoutineManagedBuild -Target $Target } else { Invoke-Captured $BuildBatch $Target.arguments }
			if ($ManagedCompile) { Assert-RoutineCompileProgress }
			elseif ([DateTime]::UtcNow -ge $CompileDeadlineUtc) { throw 'compile_timeout' }
			Add-CompileBuildEvidence -Check $Target.name -Target $Target.target -Platform $Target.platform -Presence $Presence -Output $BuildResult.output -OutputAvailable $true
			$BuildFailure = $null
			if ($BuildResult.exitCode -ne 0) {
				$BuildMessage = Get-SafeDiagnosticMessage -Reason 'build_failed' -Output $BuildResult.output -ProtectedValues $ProtectedValues
				Add-Check -Name $Target.name -Status 'failed' -CheckStarted $BuildStarted -Command $Target.label -Message $BuildMessage
				$BuildFailure = 'build_failed'
			} else {
				Add-Check -Name $Target.name -Status 'passed' -CheckStarted $BuildStarted -Command $Target.label -Message 'build_passed'
			}
			Complete-CommandStateCheck ($Target.name + '-repository-state') $BuildFailure
		}
		Assert-RepositoryState 'repository-state-at-completion'
		if ($ManagedCompile) { Assert-RoutineCompileProgress }
		elseif ([DateTime]::UtcNow -ge $CompileDeadlineUtc) { throw 'compile_timeout' }
	} elseif ($Mode -eq 'PackagedSmoke') {
		$BuildStarted = [DateTime]::UtcNow
		$BuildOutput = New-Object System.Collections.ArrayList
		$BuildFailure = $null
		try {
			$DdcArguments = @{}
			if ($null -ne $DdcRoot) { $DdcArguments['DerivedDataCachePath'] = $DdcRoot; $DdcArguments['CacheFallback'] = $DdcFallback }
			& $BuildScript -ProjectPath $ProjectPath -EngineRoot $EngineRoot -LinuxToolchainRoot $ToolchainRoot -ArchiveRoot $ResolvedArchive -LogRoot $ResolvedLogs -SourceRevision $SourceRevision -Configuration Development -Map '/Game/Maps/StarterMap' @DdcArguments @HostToolsArguments *>&1 | ForEach-Object { [void] $BuildOutput.Add($_) }
			Add-Check -Name 'clean-packaged-client-server-build' -Status 'passed' -CheckStarted $BuildStarted -Command 'Build-PackagedArtifacts.ps1' -Message 'build_passed'
		} catch {
			[void] $BuildOutput.Add($_)
			$BuildMessage = Get-SafeDiagnosticMessage -Reason 'build_failed' -Output $BuildOutput -ProtectedValues $ProtectedValues
			Add-Check -Name 'clean-packaged-client-server-build' -Status 'failed' -CheckStarted $BuildStarted -Command 'Build-PackagedArtifacts.ps1' -Message $BuildMessage
			$BuildFailure = 'build_failed'
		}
		# Both targets build in one controller invocation, so pre-run presence
		# is not attributable to one platform and stays explicitly null.
		Add-CompileBuildEvidence -Check 'clean-packaged-client-server-build' -Target 'AethelnOnlineClient+AethelnOnlineServer' -Platform 'Win64+Linux' -Presence $null -Output $BuildOutput -OutputAvailable $true

		Complete-CommandStateCheck 'repository-state-after-package' $BuildFailure

		$SmokeFailure = Invoke-SmokeGateWork $ResolvedArchive

		Complete-CommandStateCheck 'repository-state-at-completion' $SmokeFailure
	} elseif ($Mode -eq 'PackageClient' -or $Mode -eq 'PackageServer') {
		$PhaseDirectory = Get-HandoffChildPath -Parent $RunDirectory -Child $PhaseName -ReasonCode 'handoff_conflict'
		$CheckName = 'scheduled-{0}-package' -f $PhaseName
		if ((Test-Path -LiteralPath $PhaseDirectory) -or (Test-Path -LiteralPath (Join-Path $RunDirectory ('manifest-{0}.json' -f $PhaseName)))) {
			Add-Check -Name $CheckName -Status 'failed' -CheckStarted ([DateTime]::UtcNow) -Command 'Build-PackagedArtifacts.ps1' -Message 'handoff_conflict'
			throw 'handoff_conflict'
		}
		$Stage = if ($Mode -eq 'PackageClient') { 'Client' } else { 'Server' }
		$StageTarget = if ($Mode -eq 'PackageClient') { 'AethelnOnlineClient' } else { 'AethelnOnlineServer' }
		$StagePlatform = if ($Mode -eq 'PackageClient') { 'Win64' } else { 'Linux' }
		$Presence = Get-IntermediatePresence $StagePlatform $StageTarget
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
		if ($null -ne $DdcRoot) { $PhaseParameters['DerivedDataCachePath'] = $DdcRoot; $PhaseParameters['CacheFallback'] = $DdcFallback }
		foreach ($HostToolsKey in @($HostToolsArguments.Keys)) { $PhaseParameters[$HostToolsKey] = $HostToolsArguments[$HostToolsKey] }
		$BuildStarted = [DateTime]::UtcNow
		$PhaseResult = Invoke-PhaseChildWithinDeadline (ConvertTo-NamedInvocationText $BuildScript $PhaseParameters)
		Add-CompileBuildEvidence -Check $CheckName -Target $StageTarget -Platform $StagePlatform -Presence $Presence -Output $PhaseResult.output -OutputAvailable (-not $PhaseResult.timedOut)
		$BuildFailure = $null
		if ($PhaseResult.timedOut) {
			$TimeoutReason = if ([string]::IsNullOrWhiteSpace([string] $PhaseResult.cleanupFailure)) { 'phase_timeout' } else { 'phase_cleanup_failed' }
			Add-Check -Name $CheckName -Status 'failed' -CheckStarted $BuildStarted -Command 'Build-PackagedArtifacts.ps1' -Message $TimeoutReason
			$BuildFailure = $TimeoutReason
		} elseif ($PhaseResult.exitCode -ne 0) {
			$BuildMessage = Get-SafeDiagnosticMessage -Reason 'build_failed' -Output $PhaseResult.output -ProtectedValues $ProtectedValues
			Add-Check -Name $CheckName -Status 'failed' -CheckStarted $BuildStarted -Command 'Build-PackagedArtifacts.ps1' -Message $BuildMessage
			$BuildFailure = 'build_failed'
		} else {
			Add-Check -Name $CheckName -Status 'passed' -CheckStarted $BuildStarted -Command 'Build-PackagedArtifacts.ps1' -Message 'build_passed'
		}
		Complete-CommandStateCheck ('repository-state-after-{0}-package' -f $PhaseName) $BuildFailure

		Invoke-HandoffPublish -PublishRunDirectory $RunDirectory -Phase $PhaseName -Consumers @('provenance', 'smoke')
		Assert-RepositoryState 'repository-state-at-completion'
	} elseif ($Mode -eq 'ValidateProvenance') {
		$ConsumedDirectories = Invoke-HandoffConsumeSet -ConsumeRunDirectory $RunDirectory -Phases @('client', 'server') -ConsumingPhase 'provenance'
		$ClientDirectory = $ConsumedDirectories['client']
		$ServerDirectory = $ConsumedDirectories['server']
		$PhaseDirectory = Get-HandoffChildPath -Parent $RunDirectory -Child $PhaseName -ReasonCode 'handoff_conflict'
		if ((Test-Path -LiteralPath $PhaseDirectory) -or (Test-Path -LiteralPath (Join-Path $RunDirectory ('manifest-{0}.json' -f $PhaseName)))) {
			Add-Check -Name 'registry-provenance-validation' -Status 'failed' -CheckStarted ([DateTime]::UtcNow) -Command 'Build-PackagedArtifacts.ps1' -Message 'handoff_conflict'
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
		$PhaseResult = Invoke-PhaseChildWithinDeadline (ConvertTo-NamedInvocationText $BuildScript $PhaseParameters)
		$BuildFailure = $null
		if ($PhaseResult.timedOut) {
			$TimeoutReason = if ([string]::IsNullOrWhiteSpace([string] $PhaseResult.cleanupFailure)) { 'phase_timeout' } else { 'phase_cleanup_failed' }
			Add-Check -Name 'registry-provenance-validation' -Status 'failed' -CheckStarted $BuildStarted -Command 'Build-PackagedArtifacts.ps1' -Message $TimeoutReason
			$BuildFailure = $TimeoutReason
		} elseif ($PhaseResult.exitCode -ne 0) {
			$BuildMessage = Get-SafeDiagnosticMessage -Reason 'validation_failed' -Output $PhaseResult.output -ProtectedValues $ProtectedValues
			Add-Check -Name 'registry-provenance-validation' -Status 'failed' -CheckStarted $BuildStarted -Command 'Build-PackagedArtifacts.ps1' -Message $BuildMessage
			$BuildFailure = 'validation_failed'
		} else {
			Add-Check -Name 'registry-provenance-validation' -Status 'passed' -CheckStarted $BuildStarted -Command 'Build-PackagedArtifacts.ps1' -Message 'validation_passed'
		}
		Complete-CommandStateCheck 'repository-state-after-provenance-validation' $BuildFailure

		Invoke-HandoffPublish -PublishRunDirectory $RunDirectory -Phase $PhaseName -Consumers @('smoke')
		Assert-RepositoryState 'repository-state-at-completion'
	} else {
		[void] (Invoke-HandoffConsumeSet -ConsumeRunDirectory $RunDirectory -Phases @('client', 'server', 'provenance') -ConsumingPhase 'smoke')

		$SmokeFailure = Invoke-SmokeGateWork $RunDirectory $script:PhaseDeadlineUtc
		# Marker, cleanup-request, and report finalization run after the
		# cooperative deadline but stay bounded: the supervising parent kills
		# this whole child tree at the deadline plus PhaseFinalizeGraceSeconds
		# and writes the bounded report itself if finalization blocks.
		$script:PhaseDeadlineUtc = [DateTime]::MaxValue

		$MarkerStarted = [DateTime]::UtcNow
		try {
			if ($SmokeFailure -eq 'phase_timeout' -or $SmokeFailure -eq 'phase_cleanup_failed') {
				# A timed-out smoke never publishes a completion marker: the
				# work is unfinished and must not become cleanup-eligible as a
				# completed milestone. Evidence is still recorded.
				Write-CleanupRequest $ScopeRoot $PhaseName
				Add-Check -Name 'handoff-milestone-completion' -Status 'failed' -CheckStarted $MarkerStarted -Command 'write-milestone-marker' -Message 'milestone_incomplete'
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
				Add-Check -Name 'handoff-milestone-completion' -Status 'passed' -CheckStarted $MarkerStarted -Command 'write-milestone-marker' -Message 'milestone_recorded'
			}
		} catch {
			Add-Check -Name 'handoff-milestone-completion' -Status 'failed' -CheckStarted $MarkerStarted -Command 'write-milestone-marker' -Message 'milestone_record_failed'
			if ([string]::IsNullOrWhiteSpace($SmokeFailure)) { $SmokeFailure = 'milestone_record_failed' }
		}

		Complete-CommandStateCheck 'repository-state-at-completion' $SmokeFailure
	}
} catch {
	$RequiredFailed = $true
	$FailureCode = [string] $_.Exception.Message
	if ($FailureCode -notmatch '^[a-z0-9_]+$') { $FailureCode = 'engine_runner_failed' }
	# A validated child already owns its failure row. Preserve that evidence
	# once; add a parent row only for a failure the child did not report.
	$RelayedFailureRecorded = $null -ne $RelayedReport -and @($RelayedReport.checks | Where-Object {
		$_.status -eq 'failed' -and ([string] $_.message -split '[\r\n]')[0] -ceq $FailureCode
	}).Count -gt 0
	if ($Mode -eq 'Compile' -and -not $RelayedFailureRecorded -and @($Checks | Where-Object status -eq 'failed').Count -eq 0) {
		Add-Check -Name 'compile-gate' -Status 'failed' -CheckStarted $Started -Command 'compile-gate' -Message $FailureCode
	}
} finally {
	if ($null -ne $ManagedRegistration) {
		try { Close-ManagedCompileRegistration -Registration $ManagedRegistration }
		catch {
			$RequiredFailed = $true; $FailureCode = 'managed_registration_cleanup_failed'
			Add-Check -Name 'managed-compile-registration' -Status 'failed' -CheckStarted $Started -Command 'close-registration-proof' -Message $FailureCode
		}
	}
	# A supervised parent publishes exactly once after validating private child
	# evidence and proving owned-tree cleanup. Its explicit publication path sets
	# this flag before control reaches the common finalizer.
	if (-not $SupervisedChildExited) {
		try { Write-RunnerReport } catch { $RequiredFailed = $true; $FailureCode = 'report_write_failed' }
	}
}

if ($RequiredFailed) {
	Write-Error $FailureCode
	exit 1
}
Write-Output 'engine_runner_passed'
exit 0
