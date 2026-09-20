[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[ValidateNotNullOrEmpty()]
	[string] $EngineRoot,
	[ValidateRange(1, 86400)]
	[int] $TimeoutSeconds = 600
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PinnedEngineTag = '5.8.1-release'
$PinnedEngineRevision = '71fe36aac5a8df5ccd66c763ffc902b29b6a9c43'
$ProjectName = 'AethelnOnline'
$Filter = '^Aetheln.Harness.ProjectAndModuleLoad$+^Aetheln.GameCombat.NetworkSpike.Authority$'
$ExpectedTests = @('Aetheln.Harness.ProjectAndModuleLoad','Aetheln.GameCombat.NetworkSpike.Authority')
$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$ProjectPath = Join-Path $RepositoryRoot 'AethelnOnline.uproject'
$UnrealReportDirectory = Join-Path $RepositoryRoot 'TestResults\UnrealAutomation'
$UnrealReportPath = Join-Path $UnrealReportDirectory 'index.json'
$NormalizedReportPath = Join-Path $RepositoryRoot 'TestResults\unreal-automation-report.json'
$LogPath = Join-Path $RepositoryRoot 'Saved\Logs\AethelnUnrealAutomation.log'
$StartedUtc = [DateTime]::UtcNow
$SourceRevision = 'unknown'
$EngineRevision = 'unknown'
$ProcessExitCode = $null
$RepositoryCleanBefore = $false
$RepositoryCleanAfter = $false
$FailureReason = 'none'
$NormalizedTests = @()
$Summary = [ordered]@{total=0;passed=0;passedWithWarnings=0;failed=0;notRun=0;missing=$ExpectedTests.Count;requiredFailed=$ExpectedTests.Count}
$Process = $null
$ProcessJob = $null
$EditorLaunched = $false
$JobObjectSource = @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace Aetheln {
 public sealed class UnrealAutomationJob : IDisposable {
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
  public UnrealAutomationJob() {
   handle=CreateJobObject(IntPtr.Zero,null); if(handle==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"CreateJobObject failed.");
   ExtendedLimitInformation information=new ExtendedLimitInformation(); information.BasicLimitInformation.LimitFlags=KillOnJobClose;
   if(!SetInformationJobObject(handle,9,ref information,(uint)Marshal.SizeOf(typeof(ExtendedLimitInformation)))) { int error=Marshal.GetLastWin32Error(); CloseHandle(handle); handle=IntPtr.Zero; throw new Win32Exception(error,"SetInformationJobObject failed."); }
  }
  void Assign(IntPtr process) { if(handle==IntPtr.Zero) throw new ObjectDisposedException("UnrealAutomationJob"); if(!AssignProcessToJobObject(handle,process)) throw new Win32Exception(Marshal.GetLastWin32Error(),"AssignProcessToJobObject failed."); }
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
  ~UnrealAutomationJob() { Dispose(); }
 }
}
"@
function Initialize-JobObjectType {
	if($null-eq('Aetheln.UnrealAutomationJob' -as [type])){Add-Type -TypeDefinition $JobObjectSource -Language CSharp}
}
function Invoke-NativeCommand([string] $Executable,[string[]] $Arguments) {
	$PreviousPreference=$ErrorActionPreference
	try {$ErrorActionPreference='Continue';$Output=@(& $Executable @Arguments 2>&1|ForEach-Object{"$_"});$ExitCode=$LASTEXITCODE}
	finally {$ErrorActionPreference=$PreviousPreference}
	return [ordered]@{output=@($Output);exitCode=$ExitCode}
}
function Get-SingleGitRevision([string] $WorkingTree,[string[]] $Arguments) {
	$Result=Invoke-NativeCommand 'git' (@('-C',$WorkingTree)+$Arguments)
	$Lines=@($Result.output|ForEach-Object{$_.Trim()}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})
	if($Result.exitCode-ne 0-or $Lines.Count-ne 1-or $Lines[0]-notmatch '^[0-9a-fA-F]{40}$'){throw 'git_revision_query_failed'}
	return $Lines[0].ToLowerInvariant()
}
function Get-RepositoryState([string] $ExpectedRevision) {
	$Revision=Get-SingleGitRevision $RepositoryRoot @('rev-parse','HEAD')
	$Status=Invoke-NativeCommand 'git' @('-C',$RepositoryRoot,'status','--porcelain','--untracked-files=all')
	if($Status.exitCode-ne 0){throw 'repository_status_failed'}
	$Changes=@($Status.output|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})
	return [ordered]@{revision=$Revision;clean=($Revision-eq $ExpectedRevision-and $Changes.Count-eq 0)}
}
function Get-RequiredPropertyValue($InputObject,[string] $Name) {
	$Property=$InputObject.PSObject.Properties[$Name]
	if($null-eq $Property){throw "missing_property_$Name"}
	return $Property.Value
}
function ConvertTo-NonNegativeInteger($Value,[string] $Name) {
	$Parsed=0
	if($null-eq $Value-or -not[int]::TryParse([string]$Value,[ref]$Parsed)-or $Parsed-lt 0){throw "invalid_integer_$Name"}
	return $Parsed
}
function ConvertTo-NonNegativeNumber($Value,[string] $Name) {
	$Parsed=0.0
	if($null-eq $Value-or -not[double]::TryParse([string]$Value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$Parsed)-or $Parsed-lt 0-or[double]::IsNaN($Parsed)-or[double]::IsInfinity($Parsed)){throw "invalid_number_$Name"}
	return $Parsed
}
function ConvertTo-ProcessArgument([AllowEmptyString()][string] $Value) {
	if($Value.Contains('"')){throw 'argument_contains_quote'}
	if($Value.Length-eq 0-or $Value-match '\s'){return '"'+$Value+'"'}
	return $Value
}
function Stop-ProcessTree {
	[CmdletBinding(SupportsShouldProcess)]
	param([Diagnostics.Process] $TargetProcess,$TargetJob)
	# Disposing the kill-on-close job already terminates the owned tree, so the
	# decision precedes it. The target text stays generic: no command line or
	# environment data belongs in a confirmation prompt.
	if(-not $PSCmdlet.ShouldProcess('the owned Unreal editor process tree','Terminate')){return}
	if($null-ne $TargetJob){$TargetJob.Dispose()}
	# Cleanup runs after the outcome is already decided, so each failure below is
	# recorded and stepped over: none may replace the original failure reason.
	try{[void]$TargetProcess.WaitForExit(5000)}catch{Write-Verbose "Bounded wait for the owned process tree failed: $($_.Exception.Message)"}
	# Property access yields $null instead of throwing when no process is
	# associated, and -not $null is $true, so escalation must require an observed
	# boolean. Otherwise an unobservable handle escalates against a bogus id.
	$Alive=$false;try{$Exited=$TargetProcess.HasExited;if($Exited-is [bool]){$Alive=-not $Exited}else{Write-Verbose 'Owned process state is unobservable, so termination is not escalated.'}}catch{Write-Verbose "Reading owned process state failed, so termination is not escalated: $($_.Exception.Message)"}
	if($Alive){Invoke-BoundedTaskKill $TargetProcess.Id;try{if(-not $TargetProcess.HasExited){$TargetProcess.Kill()}}catch{Write-Verbose "Direct termination of the owned process failed: $($_.Exception.Message)"};try{[void]$TargetProcess.WaitForExit(5000)}catch{Write-Verbose "Bounded wait after termination failed: $($_.Exception.Message)"}}
}
function Invoke-BoundedTaskKill([int] $ProcessId) {
	$TaskKill=Get-Command 'taskkill.exe' -ErrorAction SilentlyContinue;if($null-eq $TaskKill){return}
	$Info=New-Object Diagnostics.ProcessStartInfo;$Info.FileName=$TaskKill.Source;$Info.Arguments="/PID $ProcessId /T /F";$Info.UseShellExecute=$false;$Info.CreateNoWindow=$true
	$TaskKillProcess=New-Object Diagnostics.Process;$TaskKillProcess.StartInfo=$Info
	# The fallback is best effort and strictly bounded; every failure is recorded
	# rather than discarded, and none of them changes the run's failure reason.
	try{if($TaskKillProcess.Start()-and -not $TaskKillProcess.WaitForExit(5000)){try{$TaskKillProcess.Kill()}catch{Write-Verbose "Terminating the unresponsive taskkill fallback failed: $($_.Exception.Message)"};try{[void]$TaskKillProcess.WaitForExit(1000)}catch{Write-Verbose "Bounded wait for the terminated taskkill fallback failed: $($_.Exception.Message)"}}}catch{Write-Verbose "The bounded taskkill fallback could not run: $($_.Exception.Message)"}finally{$TaskKillProcess.Dispose()}
}
function Read-UnrealReport {
	$Raw=Get-Content $UnrealReportPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
	if($null-eq $Raw){throw 'report_is_null'}
	$Created=Get-RequiredPropertyValue $Raw 'reportCreatedOn';if([string]::IsNullOrWhiteSpace([string]$Created)){throw 'report_created_on_invalid'}
	$Succeeded=ConvertTo-NonNegativeInteger (Get-RequiredPropertyValue $Raw 'succeeded') 'succeeded'
	$Warned=ConvertTo-NonNegativeInteger (Get-RequiredPropertyValue $Raw 'succeededWithWarnings') 'succeededWithWarnings'
	$Failed=ConvertTo-NonNegativeInteger (Get-RequiredPropertyValue $Raw 'failed') 'failed'
	$NotRun=ConvertTo-NonNegativeInteger (Get-RequiredPropertyValue $Raw 'notRun') 'notRun'
	$InProcess=ConvertTo-NonNegativeInteger (Get-RequiredPropertyValue $Raw 'inProcess') 'inProcess'
	[void](ConvertTo-NonNegativeNumber (Get-RequiredPropertyValue $Raw 'totalDuration') 'totalDuration')
	$RawTests=@(Get-RequiredPropertyValue $Raw 'tests');$Temporary=@();$Counts=[ordered]@{succeeded=0;warned=0;failed=0;notRun=0;inProcess=0};$Ordinal=0
	foreach($RawTest in $RawTests){
		if($null-eq $RawTest){throw 'test_record_is_null'}
		$Path=[string](Get-RequiredPropertyValue $RawTest 'fullTestPath');$State=[string](Get-RequiredPropertyValue $RawTest 'state')
		if([string]::IsNullOrWhiteSpace($Path)-or $State-notin @('Success','Fail','NotRun','InProcess')){throw 'test_identity_or_state_invalid'}
		$Duration=ConvertTo-NonNegativeNumber (Get-RequiredPropertyValue $RawTest 'duration') 'duration';$Warnings=ConvertTo-NonNegativeInteger (Get-RequiredPropertyValue $RawTest 'warnings') 'warnings';$Errors=ConvertTo-NonNegativeInteger (Get-RequiredPropertyValue $RawTest 'errors') 'errors'
		if($State-eq 'Success'){if($Warnings-gt 0){$Counts.warned++}else{$Counts.succeeded++}}elseif($State-eq 'Fail'){$Counts.failed++}elseif($State-eq 'NotRun'){$Counts.notRun++}else{$Counts.inProcess++}
		$Status=if($State-eq 'Success'-and $Warnings-eq 0-and $Errors-eq 0){'passed'}elseif($State-eq 'Success'-and $Errors-eq 0){'passed-with-warnings'}elseif($State-in @('NotRun','InProcess')){'not-run'}else{'failed'}
		$Temporary+=[pscustomobject]@{ordinal=$Ordinal;fullTestPath=$Path;state=$State;status=$Status;durationSeconds=[Math]::Round($Duration,6);warningCount=$Warnings;errorCount=$Errors};$Ordinal++
	}
	if($Succeeded-ne $Counts.succeeded-or $Warned-ne $Counts.warned-or $Failed-ne $Counts.failed-or $NotRun-ne $Counts.notRun-or $InProcess-ne $Counts.inProcess-or ($Succeeded+$Warned+$Failed+$NotRun+$InProcess)-ne $RawTests.Count){throw 'report_aggregate_mismatch'}
	$Tests=@($Temporary|Sort-Object -Property @{Expression={$_.fullTestPath}},@{Expression={$_.ordinal}}|ForEach-Object{[ordered]@{fullTestPath=$_.fullTestPath;state=$_.state;status=$_.status;durationSeconds=$_.durationSeconds;warningCount=$_.warningCount;errorCount=$_.errorCount}})
	$Missing=@($ExpectedTests|Where-Object{$Expected=$_;@($Tests|Where-Object{$_.fullTestPath-ceq $Expected}).Count-eq 0}).Count;$DuplicateOrUnexpected=$false
	foreach($Expected in $ExpectedTests){if(@($Tests|Where-Object{$_.fullTestPath-ceq $Expected}).Count-ne 1){$DuplicateOrUnexpected=$true}}
	if(@($Tests|Where-Object{$_.fullTestPath-cnotin $ExpectedTests}).Count-gt 0){$DuplicateOrUnexpected=$true}
	$DiscoveryMismatch=$Tests.Count-ne $ExpectedTests.Count-or $Missing-gt 0-or $DuplicateOrUnexpected
	$Passed=@($Tests|Where-Object{$_.status-ceq 'passed'}).Count;$PassedWithWarnings=@($Tests|Where-Object{$_.status-ceq 'passed-with-warnings'}).Count;$FailedTests=@($Tests|Where-Object{$_.status-ceq 'failed'}).Count;$NotRunTests=@($Tests|Where-Object{$_.status-ceq 'not-run'}).Count
	$RequiredFailed=$PassedWithWarnings+$FailedTests+$NotRunTests+$Missing;if($DiscoveryMismatch-and $RequiredFailed-eq 0){$RequiredFailed=1}
	return [ordered]@{tests=$Tests;summary=[ordered]@{total=$Tests.Count;passed=$Passed;passedWithWarnings=$PassedWithWarnings;failed=$FailedTests;notRun=$NotRunTests;missing=$Missing;requiredFailed=$RequiredFailed};discoveryMismatch=$DiscoveryMismatch;testFailure=(@($Tests|Where-Object{$_.status-cne 'passed'}).Count-gt 0)}
}
function Write-NormalizedReport {
	$Directory=Split-Path -Parent $NormalizedReportPath;if(-not(Test-Path $Directory)){New-Item -ItemType Directory $Directory -Force|Out-Null}
	$Report=[ordered]@{schemaId='aetheln.unreal-automation';schemaVersion=1;mode='production';sourceRevision=$SourceRevision;engineRevision=$EngineRevision;projectName=$ProjectName;filter=$Filter;timeoutSeconds=$TimeoutSeconds;startedUtc=$StartedUtc.ToString('o');finishedUtc=[DateTime]::UtcNow.ToString('o');processExitCode=$ProcessExitCode;repositoryCleanBefore=$RepositoryCleanBefore;repositoryCleanAfter=$RepositoryCleanAfter;outputs=[ordered]@{unrealReport='TestResults/UnrealAutomation/index.json';log='Saved/Logs/AethelnUnrealAutomation.log'};tests=@($NormalizedTests);summary=$Summary;result=if($FailureReason-ceq 'none'){'passed'}else{'failed'};failureReason=$FailureReason}
	[IO.File]::WriteAllText($NormalizedReportPath,(ConvertTo-Json $Report -Depth 8)+"`n",(New-Object Text.UTF8Encoding($false)))
}
try {
	try {if(-not(Test-Path $ProjectPath -PathType Leaf)){throw 'project_missing'};if(-not(Test-Path $EngineRoot -PathType Container)){throw 'engine_root_invalid'};$EngineRoot=(Resolve-Path $EngineRoot).Path;$EditorPath=Join-Path $EngineRoot 'Engine\Binaries\Win64\UnrealEditor-Cmd.exe';if(-not(Test-Path $EditorPath -PathType Leaf)){throw 'editor_missing'};if($null-eq(Get-Command git -ErrorAction SilentlyContinue)){throw 'git_missing'};Initialize-JobObjectType}catch{$FailureReason='preflight'}
	if($FailureReason-ceq 'none'){try{$SourceRevision=Get-SingleGitRevision $RepositoryRoot @('rev-parse','HEAD');$Before=Get-RepositoryState $SourceRevision;$RepositoryCleanBefore=$Before.clean;if(-not $RepositoryCleanBefore){$FailureReason='repository-dirty'}}catch{$FailureReason='preflight'}}
	if($FailureReason-ceq 'none'){try{$EngineRevision=Get-SingleGitRevision $EngineRoot @('rev-parse','HEAD');$TagRevision=Get-SingleGitRevision $EngineRoot @('rev-parse','--verify',"refs/tags/$PinnedEngineTag^{commit}");if($EngineRevision-cne $PinnedEngineRevision-or $TagRevision-cne $PinnedEngineRevision){throw 'engine_pin_mismatch'}}catch{$FailureReason='engine-pin'}}
	if($FailureReason-ceq 'none'){try{foreach($Directory in @($UnrealReportDirectory,(Split-Path -Parent $NormalizedReportPath),(Split-Path -Parent $LogPath))){if(-not(Test-Path $Directory)){New-Item -ItemType Directory $Directory -Force|Out-Null}};foreach($File in @($UnrealReportPath,$NormalizedReportPath,$LogPath)){if(Test-Path $File -PathType Leaf){Remove-Item $File -Force}}}catch{$FailureReason='preflight'}}
	if($FailureReason-ceq 'none'){
		$Arguments=@($ProjectPath,'-unattended','-nop4','-nullrhi',"-ExecCmds=Automation RunTests $Filter; Quit",'-TestExit=Automation Test Queue Empty',"-ReportExportPath=$UnrealReportDirectory","-abslog=$LogPath")
		try{$CommandLine=(ConvertTo-ProcessArgument $EditorPath)+' '+(@($Arguments|ForEach-Object{ConvertTo-ProcessArgument $_})-join ' ');$ProcessJob=New-Object Aetheln.UnrealAutomationJob;$Process=$ProcessJob.StartSuspended($EditorPath,$CommandLine,$RepositoryRoot);$EditorLaunched=$true}catch{if($null-ne $Process){Stop-ProcessTree $Process $ProcessJob}elseif($null-ne $ProcessJob){$ProcessJob.Dispose()};$FailureReason='process-start'}
	}
	if($EditorLaunched){
		if(-not $Process.WaitForExit($TimeoutSeconds*1000)){$FailureReason='timeout';Stop-ProcessTree $Process $ProcessJob}else{$Process.WaitForExit();$ProcessExitCode=$Process.ExitCode;if($ProcessExitCode-ne 0){$FailureReason='editor-exit'}}
		if(-not(Test-Path $UnrealReportPath -PathType Leaf)){if($FailureReason-ceq 'none'){$FailureReason='missing-report'}}else{try{$Parsed=Read-UnrealReport;$NormalizedTests=@($Parsed.tests);$Summary=$Parsed.summary;if($FailureReason-ceq 'none'-and $Parsed.discoveryMismatch){$FailureReason='discovery-mismatch'}elseif($FailureReason-ceq 'none'-and $Parsed.testFailure){$FailureReason='test-failure'}}catch{if($FailureReason-ceq 'none'){$FailureReason='invalid-report'}}}
	}
	if($SourceRevision-match '^[0-9a-f]{40}$'){try{$After=Get-RepositoryState $SourceRevision;$RepositoryCleanAfter=$After.clean}catch{$RepositoryCleanAfter=$false};if(-not $RepositoryCleanAfter-and ($EditorLaunched-or $FailureReason-ceq 'none')){$FailureReason='repository-drift'}}
}
catch {if($FailureReason-ceq 'none'){$FailureReason=if($EditorLaunched){'editor-exit'}else{'preflight'}}}
finally {
	if($null-ne $Process){if($EditorLaunched-and -not $Process.HasExited){Stop-ProcessTree $Process $ProcessJob}elseif($null-ne $ProcessJob){$ProcessJob.Dispose()};$Process.Dispose()}elseif($null-ne $ProcessJob){$ProcessJob.Dispose()}
	Write-NormalizedReport
}
Write-Output "Unreal automation report: $NormalizedReportPath"
if($FailureReason-cne 'none'){Write-Output "Unreal automation failed: $FailureReason";exit 1}
Write-Output 'Unreal automation passed: both required tests succeeded without warnings or errors.'
exit 0
