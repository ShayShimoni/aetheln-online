[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:InitialPreparationPolicyVersion = 'issue167-preparation-v1'
$script:InitialPreparationRecoveryFloorBytes = 21474836480L
$script:InitialPreparationPressureGiB = 2.0
if ($null -eq (Get-Variable -Name InitialPreparationLeaseRegistry -Scope Script -ErrorAction SilentlyContinue)) {
	$script:InitialPreparationLeaseRegistry = @{}
}
if ($null -eq (Get-Variable -Name InitialPreparationAttemptRegistry -Scope Script -ErrorAction SilentlyContinue)) {
	$script:InitialPreparationAttemptRegistry = @{}
}

function Initialize-InitialPreparationJob {
	if ($null -ne ('Aetheln.PreparationJob' -as [type])) { return }
	Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
namespace Aetheln {
 public static class PreparationDirectory {
  [StructLayout(LayoutKind.Sequential)] struct FileInformation {
   public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created,Accessed,Written;
   public uint Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;
  }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(Microsoft.Win32.SafeHandles.SafeFileHandle handle,out FileInformation information);
  static Microsoft.Win32.SafeHandles.SafeFileHandle OpenVerified(string path,bool directory) {
   var handle=CreateFile(path,directory ? 0x80U : 0x80000000U,directory ? 3U : 1U,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
   if(handle.IsInvalid) { handle.Dispose(); throw new Win32Exception(Marshal.GetLastWin32Error(),"directory_pin_failed"); }
   try {
    FileInformation info;
    if(!GetFileInformationByHandle(handle,out info)) throw new Win32Exception(Marshal.GetLastWin32Error(),"directory_identity_failed");
    if((info.Attributes & 0x400)!=0 || ((info.Attributes & 0x10)!=0)!=directory) throw new InvalidOperationException("source_reparse_or_kind_rejected");
    return handle;
   } catch { handle.Dispose(); throw; }
  }
  public static Microsoft.Win32.SafeHandles.SafeFileHandle Pin(string path) { return OpenVerified(path,true); }
  public static Microsoft.Win32.SafeHandles.SafeFileHandle OpenSource(string path) { return OpenVerified(path,false); }
 }
 public sealed class PreparationJob : IDisposable {
  readonly object gate = new object();
  readonly long deadline;
  readonly Thread watchdog;
  IntPtr handle;
  bool disposed, stopped, started, starting;
  volatile bool timedOut;
  Exception watchError;
  [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
  [StructLayout(LayoutKind.Sequential)] struct BasicLimits { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
  [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits { public BasicLimits BasicLimitInformation; public IoCounters IoInfo; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct StartupInfo { public uint cb; public string reserved, desktop, title; public uint x, y, xSize, ySize, xCountChars, yCountChars, fillAttribute, flags; public short showWindow, reserved2; public IntPtr reserved2Pointer, standardInput, standardOutput, standardError; }
  [StructLayout(LayoutKind.Sequential)] struct ProcessInformation { public IntPtr process, thread; public uint processId, threadId; }
  [StructLayout(LayoutKind.Sequential)] struct StartupInfoEx { public StartupInfo StartupInfo; public IntPtr attributes; }
  [StructLayout(LayoutKind.Sequential)] struct Accounting { public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime; public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses; }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes,string name);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int kind,ref ExtendedLimits limits,uint size);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job,int kind,out Accounting info,uint size,IntPtr returned);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcess(string applicationName,StringBuilder commandLine,IntPtr processAttributes,IntPtr threadAttributes,bool inheritHandles,uint creationFlags,IntPtr environment,string currentDirectory,ref StartupInfoEx startupInfo,out ProcessInformation processInformation);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr attributes,int count,int flags,ref IntPtr size);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr attributes,uint flags,IntPtr attribute,IntPtr value,IntPtr size,IntPtr previous,IntPtr returned);
  [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr attributes);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process,uint exitCode);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint exitCode);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  static void Check(bool success,string code) { if(!success) throw new Win32Exception(Marshal.GetLastWin32Error(),code); }
  public PreparationJob(long deadlineTicks) {
   if(deadlineTicks<=Stopwatch.GetTimestamp()) throw new ArgumentException("operation_deadline_elapsed");
   deadline=deadlineTicks;
   handle=CreateJobObject(IntPtr.Zero,null);
   if(handle==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"job_create_failed");
   try {
    ExtendedLimits limits=new ExtendedLimits(); limits.BasicLimitInformation.LimitFlags=0x2000;
    Check(SetInformationJobObject(handle,9,ref limits,(uint)Marshal.SizeOf(typeof(ExtendedLimits))),"job_limits_failed");
    watchdog=new Thread(Watch); watchdog.IsBackground=true; watchdog.Name="Aetheln preparation deadline"; watchdog.Start();
   } catch { CloseHandle(handle); handle=IntPtr.Zero; throw; }
  }
  void Watch() {
   while(true) {
    lock(gate) {
     if((disposed || stopped) && !starting) return;
     if(disposed || stopped || Stopwatch.GetTimestamp()>=deadline) {
      if(Stopwatch.GetTimestamp()>=deadline) timedOut=true;
      stopped=true;
      try { Check(TerminateJobObject(handle,1),"job_deadline_termination_failed"); }
      catch(Exception error) {
       watchError=error;
       if(!starting) { CloseHandle(handle); handle=IntPtr.Zero; }
       return;
      }
      if(!starting) return;
     }
    }
    Thread.Sleep(10);
   }
  }
  static string Quote(string value) {
   if(value==null || value.IndexOf('\0')>=0) throw new ArgumentException("process_argument_invalid");
   StringBuilder result=new StringBuilder("\""); int slashes=0;
   foreach(char ch in value) {
    if(ch=='\\') { slashes++; continue; }
    if(ch=='"') { result.Append('\\',slashes*2+1); result.Append(ch); slashes=0; continue; }
    result.Append('\\',slashes); slashes=0; result.Append(ch);
   }
   result.Append('\\',slashes*2); result.Append('"'); return result.ToString();
  }
  public Process Start(string executable,string[] arguments,string workingDirectory) {
   StringBuilder command=new StringBuilder(Quote(executable));
   foreach(string argument in arguments) { command.Append(' '); command.Append(Quote(argument)); }
   if(command.Length>32766) throw new ArgumentException("process_command_limit");
   IntPtr job;
   lock(gate) {
    if(disposed || stopped || started || Stopwatch.GetTimestamp()>=deadline) throw new InvalidOperationException("operation_not_startable");
    started=true; starting=true; job=handle;
   }
   IntPtr attributes=IntPtr.Zero, jobList=IntPtr.Zero; bool initialized=false;
   ProcessInformation info=new ProcessInformation(); Process managed=null;
   try {
    IntPtr size=IntPtr.Zero;
    InitializeProcThreadAttributeList(IntPtr.Zero,1,0,ref size);
    if(size.ToInt64()<=0 || size.ToInt64()>65536) throw new InvalidOperationException("job_attribute_size_invalid");
    attributes=Marshal.AllocHGlobal(size); jobList=Marshal.AllocHGlobal(IntPtr.Size); Marshal.WriteIntPtr(jobList,job);
    Check(InitializeProcThreadAttributeList(attributes,1,0,ref size),"job_attribute_init_failed"); initialized=true;
    Check(UpdateProcThreadAttribute(attributes,0,new IntPtr(0x0002000D),jobList,new IntPtr(IntPtr.Size),IntPtr.Zero,IntPtr.Zero),"job_attribute_update_failed");
    StartupInfoEx startup=new StartupInfoEx(); startup.StartupInfo.cb=(uint)Marshal.SizeOf(typeof(StartupInfoEx)); startup.attributes=attributes;
    // Windows assigns the job atomically during creation, even if this owner is
    // interrupted before CreateProcess returns. No uncontained suspended gap.
    Check(CreateProcess(executable,command,IntPtr.Zero,IntPtr.Zero,false,0x08080004,IntPtr.Zero,workingDirectory,ref startup,out info),"process_create_failed");
    managed=Process.GetProcessById((int)info.processId); IntPtr retained=managed.Handle;
    lock(gate) {
     if(disposed || stopped || Stopwatch.GetTimestamp()>=deadline) throw new TimeoutException("operation_deadline_elapsed");
     if(ResumeThread(info.thread)==UInt32.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error(),"process_resume_failed");
    }
    return managed;
   } catch(Exception startupError) {
    if(managed!=null) managed.Dispose();
    if(info.process!=IntPtr.Zero) {
     bool terminationRequested=TerminateProcess(info.process,1);
     uint wait=WaitForSingleObject(info.process,3000);
     if(wait!=0) throw new InvalidOperationException(terminationRequested ? "startup_cleanup_unproven" : "startup_termination_failed",startupError);
    }
    throw;
   } finally {
    if(info.thread!=IntPtr.Zero) CloseHandle(info.thread);
    if(info.process!=IntPtr.Zero) CloseHandle(info.process);
    if(initialized) DeleteProcThreadAttributeList(attributes);
    if(attributes!=IntPtr.Zero) Marshal.FreeHGlobal(attributes);
    if(jobList!=IntPtr.Zero) Marshal.FreeHGlobal(jobList);
    lock(gate) { starting=false; if(disposed && handle!=IntPtr.Zero) { CloseHandle(handle); handle=IntPtr.Zero; } }
   }
  }
  public bool TimedOut { get { return timedOut; } }
  public long DeadlineTicks { get { return deadline; } }
  public uint ActiveCount {
   get { lock(gate) {
    if(watchError!=null) throw new InvalidOperationException("job_watchdog_failed",watchError);
    if(disposed || handle==IntPtr.Zero) throw new ObjectDisposedException("PreparationJob");
    Accounting info; Check(QueryInformationJobObject(handle,1,out info,(uint)Marshal.SizeOf(typeof(Accounting)),IntPtr.Zero),"job_accounting_failed");
    return info.ActiveProcesses;
   } }
  }
  public void StopAndWait(int milliseconds) {
   if(milliseconds<0 || milliseconds>600000) throw new ArgumentOutOfRangeException("milliseconds");
   Stopwatch timer=Stopwatch.StartNew();
   lock(gate) {
    if(disposed || handle==IntPtr.Zero) throw new ObjectDisposedException("PreparationJob");
    stopped=true; Check(TerminateJobObject(handle,1),"job_stop_failed");
   }
   while(true) {
    lock(gate) { if(!starting && ActiveCount==0) return; }
    if(timer.ElapsedMilliseconds>=milliseconds) throw new TimeoutException("job_cleanup_unproven");
    Thread.Sleep(10);
   }
  }
  public void Dispose() {
   lock(gate) {
    if(disposed) return; disposed=true; stopped=true;
    if(handle!=IntPtr.Zero) {
     if(starting) TerminateJobObject(handle,1);
     else { CloseHandle(handle); handle=IntPtr.Zero; }
    }
   }
   GC.SuppressFinalize(this);
  }
  ~PreparationJob() { Dispose(); }
 }
}
'@
}

function ConvertFrom-InitialPreparationRequest {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $Json, [Parameter(Mandatory)] $Attempt)
	Assert-InitialPreparationAttempt -Attempt $Attempt
	try {
		if ([Text.Encoding]::UTF8.GetByteCount($Json) -gt 65536) { throw 'preparation_request_invalid' }
		$Request = $Json | ConvertFrom-Json
		$Fields = @('schemaVersion', 'repository', 'targetRevision', 'engineRevision', 'runnerId', 'runnerName', 'engineRoot', 'targetRoot', 'sourceRoot', 'lfsStorageRoot', 'compilerPath', 'resourceCompilerPath', 'leasePath', 'yamlAssemblyPath', 'linuxToolchainRoot', 'mode', 'authorizationReference')
		if (@($Request.PSObject.Properties).Count -ne $Fields.Count) { throw 'preparation_request_invalid' }
		# This closed request has scalar values and literal ASCII property names.
		# Count raw keys too: ConvertFrom-Json alone silently collapses duplicates.
		$Keys = [regex]::Matches($Json, '"(?<key>(?:[^"\\]|\\.)*)"\s*:', [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromMilliseconds(100))
		if ($Keys.Count -ne $Fields.Count) { throw 'preparation_request_invalid' }
		$Seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
		foreach ($Key in $Keys) {
			if ($Fields -cnotcontains $Key.Groups['key'].Value -or -not $Seen.Add($Key.Groups['key'].Value)) { throw 'preparation_request_invalid' }
		}
		foreach ($Field in $Fields) { if ($Request.PSObject.Properties.Name -cnotcontains $Field) { throw 'preparation_request_invalid' } }
		if ($Request.schemaVersion -isnot [int] -or $Request.schemaVersion -ne 2 -or $Request.runnerId -isnot [int] -or $Request.runnerId -lt 1 -or
			$Request.repository -isnot [string] -or $Request.targetRevision -isnot [string] -or $Request.engineRevision -isnot [string] -or
			$Request.repository -cne $Attempt.repository -or $Request.targetRevision -cne $Attempt.targetRevision -or
			$Request.engineRevision -cne '9ab6767ecaaa724d01371ffaea14317311ae8371' -or
			$Request.runnerName -isnot [string] -or [string]::IsNullOrWhiteSpace($Request.runnerName) -or $Request.runnerName.Length -gt 100 -or
			$Request.mode -isnot [string] -or $Request.mode -cnotin @('inspect', 'execute')) { throw 'preparation_request_invalid' }
		foreach ($Field in @('engineRoot', 'targetRoot', 'sourceRoot', 'lfsStorageRoot', 'compilerPath', 'resourceCompilerPath', 'leasePath', 'yamlAssemblyPath', 'linuxToolchainRoot')) {
			if ($Request.$Field -isnot [string] -or $Request.$Field -notmatch '^[A-Za-z]:[\\/]' -or
				$Request.$Field.Length -gt 4096 -or $Request.$Field -match '["\x00-\x1f]' -or
				$Request.$Field.Substring(2).Contains(':')) { throw 'preparation_request_invalid' }
		}
		if ($Request.mode -ceq 'execute' -and ($Request.authorizationReference -isnot [string] -or
			[string]::IsNullOrWhiteSpace($Request.authorizationReference) -or $Request.authorizationReference.Length -gt 1024)) { throw 'preparation_request_invalid' }
		if ($null -ne $Request.authorizationReference -and $Request.authorizationReference -isnot [string]) { throw 'preparation_request_invalid' }
		return $Request
	} catch { throw 'preparation_request_invalid' }
}

function Get-InitialPreparationDirectoryPin {
	[CmdletBinding()]
	[OutputType([object[]])]
	param([Parameter(Mandatory)][string] $Directory)
	if (-not [IO.Path]::IsPathRooted($Directory) -or $Directory -match '^[\\/]{2}') { throw 'directory_pin_invalid' }
	$Full = [IO.Path]::GetFullPath($Directory)
	if ($Full.Length -gt 4096) { throw 'directory_pin_invalid' }
	Initialize-InitialPreparationJob
	$Handles = New-Object Collections.ArrayList
	$Current = [IO.Path]::GetPathRoot($Full)
	try {
		[void] $Handles.Add([Aetheln.PreparationDirectory]::Pin($Current))
		foreach ($Part in $Full.Substring($Current.Length).Split([char[]]'\/', [StringSplitOptions]::RemoveEmptyEntries)) {
			$Current = Join-Path $Current $Part
			[void] $Handles.Add([Aetheln.PreparationDirectory]::Pin($Current))
		}
		return ,@($Handles)
	} catch {
		foreach ($Handle in $Handles) { $Handle.Dispose() }
		throw 'directory_pin_invalid'
	}
}

function Get-InitialPreparationLocalWork {
	[CmdletBinding()]
	param([Parameter(Mandatory)][string] $EngineRoot,
		[scriptblock] $ProcessProbe = {
			Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, ExecutablePath, CreationDate -OperationTimeoutSec 10 -ErrorAction Stop
		})
	if (-not [IO.Path]::IsPathRooted($EngineRoot)) { throw 'local_inventory_incomplete' }
	Assert-InitialPreparationPlainPath -Path $EngineRoot -Reason 'local_inventory_incomplete'
	try {
		$Rows = @(& $ProcessProbe)
		if ($Rows.Count -lt 1 -or $Rows.Count -gt 20000) { throw 'local_inventory_incomplete' }
		$ById = @{}
		$Children = @{}
		$Active = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
		$BuildNames = @('Runner.Worker.exe', 'dotnet.exe', 'cl.exe', 'link.exe', 'clang.exe', 'clang++.exe',
			'UnrealBuildTool.exe', 'AutomationTool.exe', 'ShaderCompileWorker.exe', 'UbaAgent.exe', 'UbaHost.exe')
		foreach ($Row in $Rows) {
			if (($Row.ProcessId -isnot [int] -and $Row.ProcessId -isnot [long] -and $Row.ProcessId -isnot [uint32]) -or
				$Row.ProcessId -lt 0 -or ($Row.ParentProcessId -isnot [int] -and $Row.ParentProcessId -isnot [long] -and $Row.ParentProcessId -isnot [uint32]) -or
				$Row.ParentProcessId -lt 0 -or $Row.Name -isnot [string] -or [string]::IsNullOrWhiteSpace($Row.Name) -or
				$ById.ContainsKey([string] $Row.ProcessId)) { throw 'local_inventory_incomplete' }
			$Key = [string] $Row.ProcessId
			$ById[$Key] = $Row
			$ParentKey = [string] $Row.ParentProcessId
			if (-not $Children.ContainsKey($ParentKey)) { $Children[$ParentKey] = New-Object Collections.ArrayList }
			[void] $Children[$ParentKey].Add($Row)
			$InEngine = $false
			if (-not [string]::IsNullOrEmpty($Row.ExecutablePath)) {
				if (-not [IO.Path]::IsPathRooted($Row.ExecutablePath)) { throw 'local_inventory_incomplete' }
				$InEngine = Test-InitialPreparationWithin -Candidate $Row.ExecutablePath -Parent $EngineRoot
			}
			if ($InEngine -or $BuildNames -contains $Row.Name) { [void] $Active.Add($Key) }
		}
		# Linear closure: do not rescan the whole process table per generation.
		# Parent identity includes creation time, not PID alone.
		$Queue = New-Object Collections.Queue
		foreach ($Key in $Active) { $Queue.Enqueue($Key) }
		while ($Queue.Count -gt 0) {
			$ParentKey = [string] $Queue.Dequeue()
			if (-not $Children.ContainsKey($ParentKey)) { continue }
			foreach ($Row in $Children[$ParentKey]) {
				$Key = [string] $Row.ProcessId
				if ($Active.Contains($Key)) { continue }
				if ($Row.CreationDate -isnot [DateTime] -or $ById[$ParentKey].CreationDate -isnot [DateTime] -or
					$Row.CreationDate -lt $ById[$ParentKey].CreationDate) { throw 'local_inventory_incomplete' }
				[void] $Active.Add($Key); $Queue.Enqueue($Key)
			}
		}
		$Identities = @($Active | Sort-Object | ForEach-Object {
			$Row = $ById[$_]
			if ($Row.CreationDate -isnot [DateTime]) { throw 'local_inventory_incomplete' }
			[pscustomobject]@{ processId = $Row.ProcessId; creationUtcTicks = $Row.CreationDate.ToUniversalTime().Ticks; name = $Row.Name }
		})
		return [pscustomobject]@{ complete = $true; activeProcessCount = $Active.Count; processes = $Identities }
	} catch { throw 'local_inventory_incomplete' }
}

function New-InitialPreparationSupervision {
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)] $Attempt,
		[Parameter(Mandatory)][ValidateSet('useful', 'cleanup', 'publication')][string] $Boundary)
	Assert-InitialPreparationAttempt -Attempt $Attempt
	if (-not $PSCmdlet.ShouldProcess($Attempt.attemptId, ('Create ' + $Boundary + ' process supervisor'))) { return }
	$Field = @{ useful = 'stopUsefulWorkTicks'; cleanup = 'cleanupDeadlineTicks'; publication = 'publicationDeadlineTicks' }[$Boundary]
	Initialize-InitialPreparationJob
	return [Aetheln.PreparationJob]::new([long] $Attempt.$Field)
}

function Get-InitialPreparationTick {
	$Ticks = [Diagnostics.Stopwatch]::GetTimestamp()
	if ([Diagnostics.Stopwatch]::Frequency -le 0 -or $Ticks -lt 0) { throw 'monotonic_clock_unavailable' }
	return [long] $Ticks
}

function Test-InitialPreparationSha([object] $Value) {
	return $Value -is [string] -and $Value -cmatch '^[0-9a-fA-F]{40}$'
}

function Test-InitialPreparationRepository([object] $Value) {
	return $Value -is [string] -and $Value -cmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$'
}

function Test-InitialPreparationWithin([string] $Candidate, [string] $Parent) {
	$CandidatePath = [IO.Path]::GetFullPath($Candidate).TrimEnd([char[]]'\/')
	$ParentPath = [IO.Path]::GetFullPath($Parent).TrimEnd([char[]]'\/')
	return $CandidatePath.Equals($ParentPath, [StringComparison]::OrdinalIgnoreCase) -or
		$CandidatePath.StartsWith($ParentPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-InitialPreparationPlainPath([string] $Path, [string] $Reason) {
	$Current = [IO.Path]::GetFullPath($Path)
	while ($Current) {
		if (Test-Path -LiteralPath $Current) {
			$Item = Get-Item -LiteralPath $Current -Force -ErrorAction Stop
			if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw $Reason }
		}
		$Parent = [IO.Path]::GetDirectoryName($Current)
		if ([string]::IsNullOrEmpty($Parent) -or $Parent -eq $Current) { break }
		$Current = $Parent
	}
}

function Assert-InitialPreparationAttempt([object] $Attempt) {
	try {
	if ($null -eq $Attempt -or $Attempt.schemaVersion -ne 1 -or
		$Attempt.policyVersion -cne $script:InitialPreparationPolicyVersion -or
		-not (Test-InitialPreparationRepository $Attempt.repository) -or
		-not (Test-InitialPreparationSha $Attempt.controllerRevision) -or
		-not (Test-InitialPreparationSha $Attempt.targetRevision) -or
		[string]::IsNullOrWhiteSpace([string] $Attempt.attemptId) -or
		[long] $Attempt.monotonicFrequency -le 0) {
		throw 'attempt_identity_invalid'
	}
	$ExpectedFields = @('schemaVersion', 'attemptId', 'repository', 'controllerRevision', 'targetRevision', 'policyVersion',
		'startedUtc', 'monotonicStartTicks', 'monotonicFrequency', 'deadlineTicks', 'admissionDeadlineTicks',
		'stopUsefulWorkTicks', 'cleanupDeadlineTicks', 'publicationDeadlineTicks')
	if (@($Attempt.PSObject.Properties).Count -ne $ExpectedFields.Count) { throw 'attempt_identity_invalid' }
	foreach ($Field in $ExpectedFields) {
		if ($Attempt.PSObject.Properties.Name -cnotcontains $Field) { throw 'attempt_identity_invalid' }
	}
	$Frequency = [decimal] $Attempt.monotonicFrequency
	$Start = [decimal] $Attempt.monotonicStartTicks
	if ($Frequency -ne [Diagnostics.Stopwatch]::Frequency -or $Start -lt 0 -or $Start -gt (Get-InitialPreparationTick)) { throw 'attempt_identity_invalid' }
	$Offsets = @{ admissionDeadlineTicks = 2700; stopUsefulWorkTicks = 19800; cleanupDeadlineTicks = 20400;
		deadlineTicks = 21600; publicationDeadlineTicks = 21600 }
	foreach ($Field in $Offsets.Keys) {
		if ($Attempt.$Field -isnot [long] -and $Attempt.$Field -isnot [int]) { throw 'attempt_identity_invalid' }
		if ([decimal] $Attempt.$Field -ne ($Start + [decimal] $Offsets[$Field] * $Frequency)) { throw 'attempt_identity_invalid' }
	}
	$Key = $Attempt.repository + '|' + $Attempt.attemptId
	if ($script:InitialPreparationAttemptRegistry.ContainsKey($Key) -and
		$script:InitialPreparationAttemptRegistry[$Key] -cne ($Attempt | ConvertTo-Json -Depth 4 -Compress)) { throw 'attempt_identity_invalid' }
	} catch { throw 'attempt_identity_invalid' }
}

function New-InitialPreparationAttempt {
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)][string] $Repository,
		[Parameter(Mandatory)][string] $ControllerRevision,
		[Parameter(Mandatory)][string] $TargetRevision,
		[Parameter(Mandatory)][AllowEmptyString()][string] $AttemptId
	)

	if (-not (Test-InitialPreparationRepository $Repository) -or
		-not (Test-InitialPreparationSha $ControllerRevision) -or
		-not (Test-InitialPreparationSha $TargetRevision) -or
		[string]::IsNullOrWhiteSpace($AttemptId) -or $AttemptId.Length -gt 128 -or
		$AttemptId -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
		throw 'attempt_identity_invalid'
	}
	if (-not $PSCmdlet.ShouldProcess($AttemptId, 'Create bounded preparation attempt')) { throw 'attempt_creation_declined' }
	$AttemptKey = $Repository + '|' + $AttemptId
	if ($script:InitialPreparationAttemptRegistry.ContainsKey($AttemptKey)) { throw 'attempt_exists' }
	$Frequency = [long] [Diagnostics.Stopwatch]::Frequency
	$Start = Get-InitialPreparationTick
	try {
		# Decimal intermediates preserve integral ticks and make the final Int64
		# conversion reject overflow instead of silently rounding through Double.
		$Admission = [long] ([decimal] $Start + [decimal] 2700 * [decimal] $Frequency)
		$Useful = [long] ([decimal] $Start + [decimal] 19800 * [decimal] $Frequency)
		$Cleanup = [long] ([decimal] $Start + [decimal] 20400 * [decimal] $Frequency)
		$Deadline = [long] ([decimal] $Start + [decimal] 21600 * [decimal] $Frequency)
	} catch { throw 'monotonic_clock_unavailable' }

	$Attempt = [pscustomobject][ordered]@{
		schemaVersion = 1
		attemptId = $AttemptId
		repository = $Repository
		controllerRevision = $ControllerRevision.ToLowerInvariant()
		targetRevision = $TargetRevision.ToLowerInvariant()
		policyVersion = $script:InitialPreparationPolicyVersion
		startedUtc = [DateTime]::UtcNow.ToString('o')
		monotonicStartTicks = $Start
		monotonicFrequency = $Frequency
		deadlineTicks = $Deadline
		admissionDeadlineTicks = $Admission
		stopUsefulWorkTicks = $Useful
		cleanupDeadlineTicks = $Cleanup
		publicationDeadlineTicks = $Deadline
	}
	$script:InitialPreparationAttemptRegistry[$AttemptKey] = $Attempt | ConvertTo-Json -Depth 4 -Compress
	return $Attempt
}

function Resolve-InitialPreparationExternalFile {
	param([string] $Path, [string] $Reason)
	if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path) -or $Path -match '^[\/]{2}') { throw $Reason }
	$Full = [IO.Path]::GetFullPath($Path)
	$Root = [IO.Path]::GetPathRoot($Full)
	if ($Full.TrimEnd([char[]]'\/') -eq $Root.TrimEnd([char[]]'\/')) { throw $Reason }
	$Parent = [IO.Path]::GetDirectoryName($Full)
	if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { throw $Reason }
	Assert-InitialPreparationPlainPath $Parent $Reason
	$RepositoryVariable = Get-Variable -Name RepositoryRoot -Scope Script -ErrorAction SilentlyContinue
	if ($null -ne $RepositoryVariable -and -not [string]::IsNullOrWhiteSpace([string] $RepositoryVariable.Value)) {
		if (Test-InitialPreparationWithin $Full ([string] $RepositoryVariable.Value)) { throw $Reason }
	}
	return $Full
}

function Enter-InitialPreparationLease {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)] $Attempt,
		[Parameter(Mandatory)][string] $LeasePath
	)

	Assert-InitialPreparationAttempt $Attempt
	$Full = Resolve-InitialPreparationExternalFile $LeasePath 'lease_path_invalid'
	$Key = $Full.ToLowerInvariant()
	if ($script:InitialPreparationLeaseRegistry.ContainsKey($Key)) {
		if ($script:InitialPreparationLeaseRegistry[$Key].attemptId -ceq $Attempt.attemptId) { throw 'lease_nested' }
		throw 'lease_held'
	}
	$Owner = Get-Process -Id $PID -ErrorAction Stop
	$Record = [pscustomobject][ordered]@{
		leaseId = [guid]::NewGuid().ToString('N')
		ownerPid = $PID
		ownerStartUtc = $Owner.StartTime.ToUniversalTime().ToString('o')
		acquiredTicks = Get-InitialPreparationTick
	}
	$Stream = $null
	try {
		Assert-InitialPreparationPlainPath $Full 'lease_path_invalid'
		$Stream = [IO.File]::Open($Full, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
		if ($Stream.Length -gt 65536) { throw 'lease_journal_limit' }
		if ($Stream.Length -gt 0) {
			$StoredBytes = New-Object byte[] ([int] $Stream.Length)
			$ReadOffset = 0
			while ($ReadOffset -lt $StoredBytes.Length) {
				$ReadCount = $Stream.Read($StoredBytes, $ReadOffset, $StoredBytes.Length - $ReadOffset)
				if ($ReadCount -lt 1) { throw 'lease_owner_ambiguous' }
				$ReadOffset += $ReadCount
			}
			try {
				$Journal = (New-Object Text.UTF8Encoding($false, $true)).GetString($StoredBytes)
				$Lines = @($Journal.Split([char]10) | Where-Object { $_.Length -gt 0 })
				$LastRecord = $Lines[-1] | ConvertFrom-Json
				if ($LastRecord.schemaVersion -ne 1 -or $LastRecord.state -cne 'released' -or
					$LastRecord.cleanupVerified -isnot [bool] -or -not $LastRecord.cleanupVerified) { throw 'lease_owner_ambiguous' }
			} catch { throw 'lease_owner_ambiguous' }
		}
		$HeldRecord = [ordered]@{ schemaVersion = 1; state = 'held'; leaseId = $Record.leaseId;
			attemptId = $Attempt.attemptId; ownerPid = $Record.ownerPid; ownerStartUtc = $Record.ownerStartUtc }
		$Bytes = [Text.Encoding]::UTF8.GetBytes(($HeldRecord | ConvertTo-Json -Compress) + "`n")
		$Stream.Write($Bytes, 0, $Bytes.Length)
		$Stream.Flush($true)
	} catch {
		if ($null -ne $Stream) { $Stream.Dispose() }
		if ($_.Exception -is [IO.IOException]) { throw 'lease_held' }
		throw
	}
	$script:InitialPreparationLeaseRegistry[$Key] = [pscustomobject]@{
		leaseId = $Record.leaseId; path = $Full; attemptId = $Attempt.attemptId
		stream = $Stream; cleanupVerified = $false; ownerPid = $Record.ownerPid; ownerStartUtc = $Record.ownerStartUtc
	}
	return $Record
}

function Exit-InitialPreparationLease {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Lease)
	$Keys = @($script:InitialPreparationLeaseRegistry.Keys | Where-Object {
		$script:InitialPreparationLeaseRegistry[$_].leaseId -ceq $Lease.leaseId
	})
	if ($Keys.Count -ne 1) { throw 'lease_lost' }
	$Entry = $script:InitialPreparationLeaseRegistry[$Keys[0]]
	if ($Entry.ownerPid -ne $PID -or $Entry.ownerStartUtc -cne (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')) { throw 'lease_lost' }
	if (-not $Entry.cleanupVerified) { throw 'cleanup_unproven' }
	if ($Entry.PSObject.Properties.Name -contains 'supervisedJobs') {
		foreach ($Job in $Entry.supervisedJobs) {
			try { if ($Job.ActiveCount -ne 0) { throw 'cleanup_unproven' } } catch { throw 'cleanup_unproven' }
		}
	}
	$OwnedRecords = @()
	if ($Lease.PSObject.Properties.Name -ccontains 'ownedProcesses') { $OwnedRecords = @($Lease.ownedProcesses) }
	$Ownership = Test-InitialPreparationOwnership -Lease $Lease -OwnedProcesses $OwnedRecords
	if (-not $Ownership.ok -or $Ownership.data.liveCount -ne 0) { throw 'cleanup_unproven' }
	$Released = [ordered]@{ schemaVersion = 1; state = 'released'; leaseId = $Entry.leaseId;
		attemptId = $Entry.attemptId; cleanupVerified = $true }
	$Bytes = [Text.Encoding]::UTF8.GetBytes(($Released | ConvertTo-Json -Compress) + "`n")
	$Entry.stream.Write($Bytes, 0, $Bytes.Length)
	$Entry.stream.Flush($true)
	$Entry.stream.Dispose()
	if ($Entry.PSObject.Properties.Name -contains 'supervisedJobs') {
		foreach ($Job in $Entry.supervisedJobs) { $Job.Dispose() }
	}
	$script:InitialPreparationLeaseRegistry.Remove($Keys[0])
}

function Start-InitialPreparationProcess {
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)] $Attempt,
		[Parameter(Mandatory)] $Lease,
		[Parameter(Mandatory)][string] $Executable,
		[Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Arguments,
		[Parameter(Mandatory)][string] $WorkingDirectory)
	Assert-InitialPreparationAttempt -Attempt $Attempt
	$Entries = @($script:InitialPreparationLeaseRegistry.Values | Where-Object { $_.leaseId -ceq $Lease.leaseId })
	if ($Entries.Count -ne 1 -or $Entries[0].attemptId -cne $Attempt.attemptId -or $Entries[0].ownerPid -ne $PID -or
		$Entries[0].ownerStartUtc -cne (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o') -or
		-not $Entries[0].stream.CanWrite) { throw 'process_lease_invalid' }
	if (-not [IO.Path]::IsPathRooted($Executable) -or -not [IO.Path]::IsPathRooted($WorkingDirectory) -or
		-not (Test-Path -LiteralPath $Executable -PathType Leaf) -or -not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) { throw 'process_path_invalid' }
	Assert-InitialPreparationPlainPath -Path $Executable -Reason 'process_path_invalid'
	Assert-InitialPreparationPlainPath -Path $WorkingDirectory -Reason 'process_path_invalid'
	if (-not $PSCmdlet.ShouldProcess($Executable, 'Start process under preparation lease and immutable useful-work deadline')) { throw 'process_start_declined' }
	$Entry = $Entries[0]
	if ($Entry.PSObject.Properties.Name -notcontains 'supervisedJobs') {
		$Entry | Add-Member -NotePropertyName supervisedJobs -NotePropertyValue (New-Object Collections.ArrayList)
	}
	# Register ownership BEFORE startup so even a launch failure remains subject
	# to lease cleanup. The cleanup proof is invalidated by every new launch.
	$Entry.cleanupVerified = $false
	$Job = New-InitialPreparationSupervision -Attempt $Attempt -Boundary useful
	[void] $Entry.supervisedJobs.Add($Job)
	$Process = $Job.Start($Executable, $Arguments, $WorkingDirectory)
	return [pscustomobject]@{ process = $Process; supervision = $Job; leaseId = $Lease.leaseId }
}

function Test-InitialPreparationOwnership {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)] $Lease,
		[Parameter(Mandatory)][AllowEmptyCollection()][object[]] $OwnedProcesses
	)

	$Owner = Get-Process -Id ([int] $Lease.ownerPid) -ErrorAction SilentlyContinue
	$OwnerMatches = $false
	if ($null -ne $Owner) {
		try { $OwnerMatches = $Owner.StartTime.ToUniversalTime().ToString('o') -ceq [string] $Lease.ownerStartUtc } catch { $OwnerMatches = $false }
	}
	$Live = New-Object Collections.ArrayList
	$IdentityMismatch = $false
	foreach ($Record in @($OwnedProcesses)) {
		if ($null -eq $Record -or $null -eq $Record.processId -or [string]::IsNullOrWhiteSpace([string] $Record.startTimeUtc)) { $IdentityMismatch = $true; continue }
		$Process = Get-Process -Id ([int] $Record.processId) -ErrorAction SilentlyContinue
		if ($null -eq $Process) { continue }
		$IdentityMatches = $false
		try { $IdentityMatches = $Process.StartTime.ToUniversalTime().ToString('o') -ceq [string] $Record.startTimeUtc } catch { $IdentityMatches = $false }
		if (-not $IdentityMatches) { $IdentityMismatch = $true; continue }
		[void] $Live.Add([pscustomobject][ordered]@{ processId = [int] $Record.processId; startTimeUtc = [string] $Record.startTimeUtc; role = [string] $Record.role })
	}
	if ($IdentityMismatch) { return [pscustomobject][ordered]@{ ok = $false; code = 'owned_process_identity_mismatch'; observedUtc = [DateTime]::UtcNow.ToString('o'); data = $null } }
	if (-not $OwnerMatches) {
		$Children = @($Live | Where-Object { $_.processId -ne [int] $Lease.ownerPid })
		if ($Children.Count -gt 0) { return [pscustomobject][ordered]@{ ok = $false; code = 'surviving_owned_child'; observedUtc = [DateTime]::UtcNow.ToString('o'); data = [pscustomobject]@{ liveCount = $Children.Count } } }
		return [pscustomobject][ordered]@{ ok = $false; code = 'lease_lost'; observedUtc = [DateTime]::UtcNow.ToString('o'); data = $null }
	}
	return [pscustomobject][ordered]@{ ok = $true; code = 'ownership_verified'; observedUtc = [DateTime]::UtcNow.ToString('o'); data = [pscustomobject]@{ liveCount = $Live.Count } }
}

function Initialize-InitialPreparationMemoryType {
	if ($null -ne ('Aetheln.InitialPreparationMemory' -as [type])) { return }
	$Source = @'
using System;
using System.Runtime.InteropServices;
namespace Aetheln {
 public static class InitialPreparationMemory {
  [StructLayout(LayoutKind.Sequential)] public struct PerformanceInformation {
   public uint cb; public UIntPtr CommitTotal, CommitLimit, CommitPeak, PhysicalTotal, PhysicalAvailable;
   public UIntPtr SystemCache, KernelTotal, KernelPaged, KernelNonpaged, PageSize;
   public uint HandleCount, ProcessCount, ThreadCount;
  }
  [DllImport("psapi.dll", SetLastError=true)] static extern bool GetPerformanceInfo(out PerformanceInformation value, uint size);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool GetVolumePathNameW(string path, System.Text.StringBuilder mount, uint size);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool GetVolumeNameForVolumeMountPointW(string mount, System.Text.StringBuilder name, uint size);
  public static string[] Volume(string path) {
   var mount = new System.Text.StringBuilder(32768);
   var name = new System.Text.StringBuilder(64);
   if(!GetVolumePathNameW(path,mount,(uint)mount.Capacity) || !GetVolumeNameForVolumeMountPointW(mount.ToString(),name,(uint)name.Capacity))
    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
   return new string[]{mount.ToString(),name.ToString()};
  }
  public static ulong[] Read() {
   PerformanceInformation value; uint size=(uint)Marshal.SizeOf(typeof(PerformanceInformation));
   if(!GetPerformanceInfo(out value,size)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
   ulong page=value.PageSize.ToUInt64();
   return new ulong[]{value.PhysicalAvailable.ToUInt64()*page,(value.CommitLimit.ToUInt64()-value.CommitTotal.ToUInt64())*page};
  }
 }
}
'@
	try { Add-Type -TypeDefinition $Source -Language CSharp -ErrorAction Stop } catch { throw 'resource_measurement_unavailable' }
}

function Get-InitialPreparationCapacity {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)] $Roots,
		[Parameter(Mandatory)] $Attempt,
		[hashtable] $KnownAllocations = @{}
	)

	Assert-InitialPreparationAttempt $Attempt
	if ($null -eq $Roots -or $Roots -isnot [Collections.IDictionary] -or $Roots.Count -lt 1) { throw 'resource_root_invalid' }
	foreach ($AllocationName in $KnownAllocations.Keys) {
		if (-not $Roots.Contains($AllocationName)) { throw 'resource_allocation_invalid' }
		$Allocation = $KnownAllocations[$AllocationName]
		if (($Allocation -isnot [int] -and $Allocation -isnot [long]) -or $Allocation -lt 0) { throw 'resource_allocation_invalid' }
	}
	Initialize-InitialPreparationMemoryType
	$Volumes = [ordered]@{}
	foreach ($Name in @($Roots.Keys)) {
		$Value = [string] $Roots[$Name]
		if ([string]::IsNullOrWhiteSpace($Value) -or -not [IO.Path]::IsPathRooted($Value) -or -not (Test-Path -LiteralPath $Value -PathType Container)) { throw 'resource_root_invalid' }
		$Full = (Resolve-Path -LiteralPath $Value).Path
		Assert-InitialPreparationPlainPath $Full 'resource_root_invalid'
		try { $ResolvedVolume = [Aetheln.InitialPreparationMemory]::Volume($Full) } catch { throw 'resource_volume_ambiguous' }
		$VolumeRoot = $ResolvedVolume[0]
		if ([string]::IsNullOrWhiteSpace($VolumeRoot)) { throw 'resource_volume_ambiguous' }
		try { $Drive = New-Object IO.DriveInfo $VolumeRoot } catch { throw 'resource_volume_ambiguous' }
		if (-not $Drive.IsReady) { throw 'resource_measurement_unavailable' }
		$VolumeId = $ResolvedVolume[1].ToLowerInvariant()
		if (-not $Volumes.Contains($VolumeId)) {
			$Volumes[$VolumeId] = [pscustomobject][ordered]@{
				volumeId = $VolumeId
				availableBytes = [long] $Drive.AvailableFreeSpace
				knownAllocationBytes = 0L
				recoveryFloorBytes = $script:InitialPreparationRecoveryFloorBytes
			}
		}
		if ($KnownAllocations.ContainsKey($Name)) {
			try { $Volumes[$VolumeId].knownAllocationBytes = [long] ([decimal] $Volumes[$VolumeId].knownAllocationBytes + [decimal] $KnownAllocations[$Name]) }
			catch { throw 'resource_allocation_invalid' }
		}
	}
	try {
		Initialize-InitialPreparationMemoryType
		$Memory = [Aetheln.InitialPreparationMemory]::Read()
		$RamGiB = [double] $Memory[0] / 1GB
		$CommitGiB = [double] $Memory[1] / 1GB
		$PhysicalCores = 0
		try {
			$PhysicalCores = [int] (@(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Measure-Object -Property NumberOfCores -Sum).Sum)
		} catch {
			throw 'resource_measurement_unavailable'
		}
		if ($PhysicalCores -lt 1 -or [double]::IsNaN($RamGiB) -or [double]::IsNaN($CommitGiB)) { throw 'resource_measurement_unavailable' }
	} catch {
		if ($_.Exception.Message -eq 'resource_measurement_unavailable') { throw }
		throw 'resource_measurement_unavailable'
	}
	return [pscustomobject][ordered]@{
		physicalCores = $PhysicalCores
		availablePhysicalRamGiB = $RamGiB
		commitHeadroomGiB = $CommitGiB
		volumes = @($Volumes.Values)
		sampleTicks = Get-InitialPreparationTick
	}
}

function Get-InitialPreparationActionLimit {
	[CmdletBinding()]
	[OutputType([int])]
	param([Parameter(Mandatory)] $Capacity)
	try {
		if (@($Capacity.volumes).Count -eq 0) { throw 'resource_admission_refused' }
		foreach ($Volume in @($Capacity.volumes)) {
			foreach ($Field in @('availableBytes', 'knownAllocationBytes', 'recoveryFloorBytes')) {
				if (($Volume.$Field -isnot [long] -and $Volume.$Field -isnot [int]) -or $Volume.$Field -lt 0) { throw 'resource_admission_refused' }
			}
			if ($Volume.recoveryFloorBytes -ne $script:InitialPreparationRecoveryFloorBytes -or
				[decimal] $Volume.availableBytes -le ([decimal] $Volume.knownAllocationBytes + [decimal] $Volume.recoveryFloorBytes)) { throw 'resource_admission_refused' }
		}
		if ($null -eq $Capacity.physicalCores -or $null -eq $Capacity.availablePhysicalRamGiB -or $null -eq $Capacity.commitHeadroomGiB) { throw 'resource_admission_refused' }
		$Cores = [int] $Capacity.physicalCores
		$Ram = [double] $Capacity.availablePhysicalRamGiB
		$Commit = [double] $Capacity.commitHeadroomGiB
		if ($Cores -lt 1 -or [double]::IsNaN($Ram) -or [double]::IsInfinity($Ram) -or [double]::IsNaN($Commit) -or [double]::IsInfinity($Commit)) { throw 'resource_admission_refused' }
		$Limit = [Math]::Min(4, [Math]::Min($Cores, [Math]::Min([Math]::Floor(($Ram - 6.0) / 3.0), [Math]::Floor(($Commit - 6.0) / 3.0))))
		if ($Limit -lt 1) { throw 'resource_admission_refused' }
		return [int] $Limit
	} catch {
		if ($_.Exception.Message -eq 'resource_admission_refused') { throw }
		throw 'resource_admission_refused'
	}
}

function Watch-InitialPreparationResource {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)] $Attempt,
		[Parameter(Mandatory)] $OwnedProducer,
		[Parameter(Mandatory)] $Roots,
		[Parameter(Mandatory)][scriptblock] $OnSample,
		[hashtable] $KnownAllocations = @{},
		[scriptblock] $CompletionProbe = { param($Producer) return $Producer.HasExited },
		[scriptblock] $ReadTicks = { Get-InitialPreparationTick }
	)

	Assert-InitialPreparationAttempt $Attempt
	$PressureCount = 0
	$ResourceSampleCount = 0
	while ($true) {
		if ((& $ReadTicks) -ge [long] $Attempt.stopUsefulWorkTicks) {
			try { $OwnedProducer.RequestStop() } catch { throw 'owned_producer_stop_failed' }
			return [pscustomobject][ordered]@{ code = 'useful_work_deadline'; sampleCount = $ResourceSampleCount; consecutivePressureSamples = $PressureCount }
		}
		$Adapter = Get-Variable -Name InitialPreparationCoreTestAdapter -Scope Script -ValueOnly -ErrorAction SilentlyContinue
		if ($null -eq $Adapter -or $PSBoundParameters.ContainsKey('CompletionProbe')) {
			try {
				$Completed = & $CompletionProbe $OwnedProducer
				if ($Completed -isnot [bool]) { throw 'owned_producer_state_unavailable' }
			} catch {
				try { $OwnedProducer.RequestStop() } catch { throw 'owned_producer_stop_failed' }
				throw 'owned_producer_state_unavailable'
			}
			if ($Completed) { return [pscustomobject][ordered]@{ code = 'producer_completed'; sampleCount = $ResourceSampleCount; consecutivePressureSamples = $PressureCount } }
		}
		if ($null -ne $Adapter) {
			if ($Adapter.capacities.Count -eq 0) { return [pscustomobject][ordered]@{ code = 'resources_stable'; sampleCount = $ResourceSampleCount; consecutivePressureSamples = $PressureCount } }
			$Capacity = $Adapter.capacities.Dequeue()
		} else {
			try { $Capacity = Get-InitialPreparationCapacity -Roots $Roots -Attempt $Attempt -KnownAllocations $KnownAllocations } catch {
				try { $OwnedProducer.RequestStop() } catch { throw 'owned_producer_stop_failed' }
				return [pscustomobject][ordered]@{ code = 'resource_measurement_unavailable'; sampleCount = $ResourceSampleCount; consecutivePressureSamples = $PressureCount }
			}
		}
		$ResourceSampleCount++
		try {
			foreach ($Measurement in @('availablePhysicalRamGiB', 'commitHeadroomGiB')) {
				$Value = $Capacity.$Measurement
				if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or
					[double]::IsNaN([double] $Value) -or [double]::IsInfinity([double] $Value) -or [double] $Value -lt 0) {
					throw 'resource_measurement_unavailable'
				}
			}
			foreach ($Volume in @($Capacity.volumes)) {
				foreach ($Measurement in @('availableBytes', 'knownAllocationBytes', 'recoveryFloorBytes')) {
					$Value = $Volume.$Measurement
					if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt 0) { throw 'resource_measurement_unavailable' }
				}
				if ($Volume.recoveryFloorBytes -ne $script:InitialPreparationRecoveryFloorBytes) { throw 'resource_measurement_unavailable' }
			}
		} catch {
			try { $OwnedProducer.RequestStop() } catch { throw 'owned_producer_stop_failed' }
			return [pscustomobject][ordered]@{ code = 'resource_measurement_unavailable'; sampleCount = $ResourceSampleCount; consecutivePressureSamples = $PressureCount }
		}
		try { & $OnSample $Capacity } catch {
			try { $OwnedProducer.RequestStop() } catch { throw 'owned_producer_stop_failed' }
			throw 'resource_evidence_failed'
		}
		$FloorReached = $false
		foreach ($Volume in @($Capacity.volumes)) {
			if ($null -eq $Volume.availableBytes -or $null -eq $Volume.knownAllocationBytes -or $null -eq $Volume.recoveryFloorBytes) {
				try { $OwnedProducer.RequestStop() } catch { throw 'owned_producer_stop_failed' }
				return [pscustomobject][ordered]@{ code = 'resource_measurement_unavailable'; sampleCount = $ResourceSampleCount; consecutivePressureSamples = $PressureCount }
			}
			if ([long] $Volume.availableBytes -le ([long] $Volume.recoveryFloorBytes + [long] $Volume.knownAllocationBytes)) { $FloorReached = $true }
		}
		if ($FloorReached) {
			try { $OwnedProducer.RequestStop() } catch { throw 'owned_producer_stop_failed' }
			return [pscustomobject][ordered]@{ code = 'disk_recovery_floor_reached'; sampleCount = $ResourceSampleCount; consecutivePressureSamples = $PressureCount }
		}
		if ($null -eq $Capacity.availablePhysicalRamGiB -or $null -eq $Capacity.commitHeadroomGiB) {
			try { $OwnedProducer.RequestStop() } catch { throw 'owned_producer_stop_failed' }
			return [pscustomobject][ordered]@{ code = 'resource_measurement_unavailable'; sampleCount = $ResourceSampleCount; consecutivePressureSamples = $PressureCount }
		}
		if ([double] $Capacity.availablePhysicalRamGiB -lt $script:InitialPreparationPressureGiB -or [double] $Capacity.commitHeadroomGiB -lt $script:InitialPreparationPressureGiB) { $PressureCount++ } else { $PressureCount = 0 }
		if ($PressureCount -ge 3) {
			try { $OwnedProducer.RequestStop() } catch { throw 'owned_producer_stop_failed' }
			return [pscustomobject][ordered]@{ code = 'resource_pressure'; sampleCount = $ResourceSampleCount; consecutivePressureSamples = $PressureCount }
		}
		if ($null -ne $Adapter) { & $Adapter.delay 5 } else {
			$DelayMilliseconds = [int] [Math]::Min(5000, [Math]::Max(0, [Math]::Floor(
				($Attempt.stopUsefulWorkTicks - (& $ReadTicks)) * 1000.0 / $Attempt.monotonicFrequency)))
			Start-Sleep -Milliseconds $DelayMilliseconds
		}
	}
}

function Stop-InitialPreparationOwnedTree {
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)] $Lease,
		[Parameter(Mandatory)][long] $DeadlineTicks
	)

	$Requested = Get-InitialPreparationTick
	$RegisteredLease = @($script:InitialPreparationLeaseRegistry.Values | Where-Object { $_.leaseId -ceq $Lease.leaseId })
	if ($RegisteredLease.Count -ne 1) { throw 'cleanup_owner_invalid' }
	$RegisteredLease[0].cleanupVerified = $false
	if ($Requested -gt $DeadlineTicks) { throw 'cleanup_deadline_exceeded' }
	if (-not $PSCmdlet.ShouldProcess([string] $Lease.leaseId, 'Stop preparation-owned work and verify quiescence')) { throw 'cleanup_declined' }
	# The controller supplies identities captured at launch, never a directory or
	# executable-name match. Its enclosing Job Object owns unenumerated descendants.
	$OwnerCheck = Test-InitialPreparationOwnership -Lease $Lease -OwnedProcesses @(
		[pscustomobject]@{ processId = $Lease.ownerPid; startTimeUtc = $Lease.ownerStartUtc; role = 'owner' }
	)
	if (-not $OwnerCheck.ok) { throw 'cleanup_owner_invalid' }
	if ($RegisteredLease[0].PSObject.Properties.Name -contains 'supervisedJobs') {
		foreach ($Job in $RegisteredLease[0].supervisedJobs) {
			$RemainingMilliseconds = [int] [Math]::Min(600000, [Math]::Max(0, [Math]::Floor(
				($DeadlineTicks - (Get-InitialPreparationTick)) * 1000.0 / [Diagnostics.Stopwatch]::Frequency)))
			try { $Job.StopAndWait($RemainingMilliseconds) } catch { throw 'cleanup_unproven' }
		}
	}
	$Remaining = @()
	if ($Lease.PSObject.Properties.Name -ccontains 'ownedProcesses') {
		foreach ($Record in @($Lease.ownedProcesses)) {
			if ((Get-InitialPreparationTick) -ge $DeadlineTicks) { throw 'cleanup_deadline_exceeded' }
			if ([int] $Record.processId -eq $PID) { throw 'cleanup_owner_in_process_set' }
			$Process = Get-Process -Id ([int] $Record.processId) -ErrorAction SilentlyContinue
			if ($null -eq $Process) { continue }
			try {
				# Open the process handle before checking creation time so PID reuse
				# cannot redirect termination to a newly created unrelated process.
				$null = $Process.Handle
				if ($Process.StartTime.ToUniversalTime().ToString('o') -cne [string] $Record.startTimeUtc) { throw 'cleanup_identity_mismatch' }
				$Process.Kill()
				$WaitMilliseconds = [int] [Math]::Min(1000, [Math]::Max(0, [Math]::Floor(
					($DeadlineTicks - (Get-InitialPreparationTick)) * 1000.0 / [Diagnostics.Stopwatch]::Frequency)))
				if (-not $Process.WaitForExit($WaitMilliseconds)) { $Remaining += $Record }
			} catch {
				$Remaining += $Record
			} finally { $Process.Dispose() }
		}
	}
	$Quiescent = Get-InitialPreparationTick
	if ($Quiescent -gt $DeadlineTicks) { throw 'cleanup_deadline_exceeded' }
	if ($Remaining.Count -gt 0) { throw 'cleanup_unproven' }
	foreach ($Entry in $script:InitialPreparationLeaseRegistry.Values) {
		if ($Entry.leaseId -ceq $Lease.leaseId) { $Entry.cleanupVerified = $true }
	}
	return [pscustomobject][ordered]@{
		stopRequestedTicks = $Requested
		quiescentTicks = $Quiescent
		cleanupVerified = $true
		remainingOwnedProcesses = @()
	}
}

function Test-InitialPreparationBuildSequence([object[]] $Builds, $Attempt, [string] $InputDigest, [switch] $AllowPartial) {
	if ((-not $AllowPartial -and @($Builds).Count -ne 6) -or @($Builds).Count -lt 2 -or @($Builds).Count -gt 6) { return $false }
	if ($InputDigest -cnotmatch '^[0-9a-f]{64}$') { return $false }
	$Expected = @(
		@('AethelnOnlineClient', 'Win64'), @('AethelnOnlineServer', 'Linux'),
		@('AethelnOnlineClient', 'Win64'), @('AethelnOnlineServer', 'Linux'),
		@('AethelnOnlineClient', 'Win64'), @('AethelnOnlineServer', 'Linux')
	)
	for ($Index = 0; $Index -lt $Builds.Count; $Index++) {
		$Build = $Builds[$Index]
		if ($null -eq $Build) { return $false }
		foreach ($Field in @('ordinal', 'pair', 'nativeExitCode', 'target', 'platform', 'configuration', 'targetRevision', 'inputDigest', 'cleanupVerified')) {
			if ($Build.PSObject.Properties.Name -cnotcontains $Field) { return $false }
		}
		foreach ($Field in @('target', 'platform', 'configuration', 'targetRevision', 'inputDigest')) {
			if ($Build.$Field -isnot [string]) { return $false }
		}
		if ($Build.cleanupVerified -isnot [bool] -or -not $Build.cleanupVerified) { return $false }
		if ($Build.PSObject.Properties.Name -cnotcontains 'ubtReadiness' -or $null -eq $Build.ubtReadiness) { return $false }
		$Readiness = $Build.ubtReadiness
		foreach ($Field in @('schemaVersion', 'attemptId', 'targetRevision', 'scope', 'ready', 'cleanupVerified', 'scanExitCode', 'comparisonExitCode', 'failureCode', 'dependencySha256', 'scanSha256')) {
			if ($Readiness.PSObject.Properties.Name -cnotcontains $Field) { return $false }
		}
		if (($Readiness.schemaVersion -isnot [int] -and $Readiness.schemaVersion -isnot [long]) -or $Readiness.schemaVersion -ne 1 -or
			$Readiness.attemptId -isnot [string] -or $Readiness.attemptId -cne $Attempt.attemptId -or
			$Readiness.targetRevision -isnot [string] -or $Readiness.targetRevision -cne $Attempt.targetRevision -or $null -ne $Readiness.failureCode) { return $false }
		foreach ($Field in @('dependencySha256', 'scanSha256')) {
			if ($Readiness.$Field -isnot [string] -or $Readiness.$Field -cnotmatch '^[0-9a-f]{64}$') { return $false }
		}
		if ($Readiness.scope -isnot [string] -or $Readiness.scope -cne 'ubt_dependency_rebuild_branch' -or
			$Readiness.ready -isnot [bool] -or -not $Readiness.ready -or
			$Readiness.cleanupVerified -isnot [bool] -or -not $Readiness.cleanupVerified) { return $false }
		foreach ($Field in @('scanExitCode', 'comparisonExitCode')) {
			if (($Readiness.$Field -isnot [int] -and $Readiness.$Field -isnot [long]) -or $Readiness.$Field -ne 0) { return $false }
		}
		foreach ($Field in @('ordinal', 'pair', 'nativeExitCode')) {
			if ($Build.$Field -isnot [int] -and $Build.$Field -isnot [long]) { return $false }
		}
		if ([int] $Build.ordinal -ne ($Index + 1) -or [int] $Build.pair -ne ([Math]::Floor($Index / 2) + 1) -or
			[string] $Build.target -cne $Expected[$Index][0] -or [string] $Build.platform -cne $Expected[$Index][1] -or
			[string] $Build.configuration -cne 'Development' -or [int] $Build.nativeExitCode -ne 0) { return $false }
		if ($Build.targetRevision -cne $Attempt.targetRevision -or $Build.inputDigest -cne $InputDigest) { return $false }
	}
	return $true
}

function Write-InitialPreparationReceipt {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)] $State,
		[Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Artifacts,
		[Parameter(Mandatory)][string] $Path
	)

	$Full = Resolve-InitialPreparationExternalFile $Path 'receipt_invalid'
	if (Test-Path -LiteralPath $Full) { throw 'receipt_exists' }
	try { Assert-InitialPreparationAttempt $State.attempt } catch { throw 'receipt_invalid' }
	if ((Get-InitialPreparationTick) -gt [long] $State.attempt.publicationDeadlineTicks) { throw 'publication_deadline_exceeded' }
	$AllowedOutcomes = @('maintenance_not_admitted', 'targets_built', 'warm_baseline_verified', 'incomplete', 'failed', 'runtime_not_ready')
	if ([string] $State.outcome -cnotin $AllowedOutcomes -or $null -eq $State.cleanup -or $null -eq $State.resource) { throw 'receipt_invalid' }
	$Builds = @($State.builds)
	if ($State.outcome -in @('warm_baseline_verified', 'targets_built')) {
		try {
			foreach ($Field in @('inputDigest', 'nativeExitCode', 'infrastructureFailure', 'maintenance', 'requestSha256', 'controllerManifestSha256')) {
				if ($State.PSObject.Properties.Name -cnotcontains $Field) { throw 'receipt_invalid' }
			}
			foreach ($Field in @('inputDigest', 'requestSha256', 'controllerManifestSha256')) {
				if ($State.$Field -isnot [string] -or $State.$Field -cnotmatch '^[0-9a-f]{64}$') { throw 'receipt_invalid' }
			}
			if (($State.nativeExitCode -isnot [int] -and $State.nativeExitCode -isnot [long]) -or $State.nativeExitCode -ne 0 -or
				$null -ne $State.infrastructureFailure -or $null -eq $State.maintenance) { throw 'receipt_invalid' }
			foreach ($Field in @('cycleCompleted', 'admitted', 'leaseReleased', 'routingRestored')) {
				if ($State.maintenance.$Field -isnot [bool] -or -not $State.maintenance.$Field) { throw 'receipt_invalid' }
			}
			if ($State.maintenance.errors -isnot [array] -or $State.maintenance.errors.Count -ne 0 -or
				-not (Test-InitialPreparationBuildSequence -Builds $Builds -Attempt $State.attempt -InputDigest $State.inputDigest -AllowPartial:($State.outcome -ceq 'targets_built')) -or
				$State.cleanup.cleanupVerified -isnot [bool] -or -not $State.cleanup.cleanupVerified -or
				$State.cleanup.remainingOwnedProcesses -isnot [array] -or
				@($State.cleanup.remainingOwnedProcesses).Count -ne 0) { throw 'receipt_invalid' }
		} catch { throw 'receipt_invalid' }
	} elseif ($State.outcome -eq 'maintenance_not_admitted' -and $Builds.Count -ne 0) { throw 'receipt_invalid' }
	elseif ($State.outcome -eq 'runtime_not_ready') {
		if ($State.PSObject.Properties.Name -cnotcontains 'missingProductionAdapters' -or @($State.missingProductionAdapters).Count -lt 1 -or $Builds.Count -ne 0) { throw 'receipt_invalid' }
	}
	foreach ($Artifact in @($Artifacts)) {
		if ($null -eq $Artifact -or [string]::IsNullOrWhiteSpace([string] $Artifact.name) -or [string] $Artifact.sha256 -cnotmatch '^[0-9a-f]{64}$' -or [long] $Artifact.bytes -lt 0) { throw 'receipt_invalid' }
	}
	$Receipt = [ordered]@{
		schemaVersion = 2
		attempt = $State.attempt
		outcome = [string] $State.outcome
		builds = $Builds
		cleanup = $State.cleanup
		resource = $State.resource
		artifacts = @($Artifacts)
		finishedUtc = [DateTime]::UtcNow.ToString('o')
	}
	if ($State.outcome -in @('warm_baseline_verified', 'targets_built')) {
		foreach ($Field in @('inputDigest', 'requestSha256', 'controllerManifestSha256', 'nativeExitCode', 'infrastructureFailure')) { $Receipt[$Field] = $State.$Field }
		$Receipt['maintenance'] = [ordered]@{ cycleCompleted = $true; admitted = $true; leaseReleased = $true; routingRestored = $true; errors = @() }
	}
	if ($State.outcome -eq 'runtime_not_ready') { $Receipt['missingProductionAdapters'] = @($State.missingProductionAdapters) }
	$Json = $Receipt | ConvertTo-Json -Depth 12
	$Bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Json)
	if ($Bytes.Length -gt 65536) { throw 'receipt_evidence_limit' }
	$Stream = $null
	try {
		$Stream = [IO.File]::Open($Full, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
		$Stream.Write($Bytes, 0, $Bytes.Length)
		$Stream.Flush()
	} catch [IO.IOException] {
		if (Test-Path -LiteralPath $Full) { throw 'receipt_exists' }
		throw 'receipt_invalid'
	} finally {
		if ($null -ne $Stream) { $Stream.Dispose() }
	}
	if ((Get-InitialPreparationTick) -gt [long] $State.attempt.publicationDeadlineTicks) { throw 'publication_deadline_exceeded' }
	try {
		$Reread = [IO.File]::ReadAllBytes($Full)
		$Hasher = [Security.Cryptography.SHA256]::Create()
		try { $Digest = ([BitConverter]::ToString($Hasher.ComputeHash($Reread))).Replace('-', '').ToLowerInvariant() } finally { $Hasher.Dispose() }
	} catch { throw 'receipt_invalid' }
	return [pscustomobject][ordered]@{ sha256 = $Digest; bytes = [long] $Reread.Length }
}
