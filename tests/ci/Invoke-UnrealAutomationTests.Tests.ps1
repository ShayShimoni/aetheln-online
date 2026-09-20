[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SourceRunner = Join-Path $RepositoryRoot 'scripts\ci\Invoke-UnrealAutomationTests.ps1'
$DefaultGameConfig = Join-Path $RepositoryRoot 'Config\DefaultGame.ini'
$AuthorityTestSource = Join-Path $RepositoryRoot 'Source\GameCombat\Private\AethelnNetworkSpikeAuthorityTests.cpp'
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnUnrealAutomationTests-' + [guid]::NewGuid().ToString('N'))
$FakeBin = Join-Path $FixtureRoot 'fake-bin'
$PowerShell = (Get-Process -Id $PID).Path
$OriginalPath = $env:PATH
$PinnedRevision = '71fe36aac5a8df5ccd66c763ffc902b29b6a9c43'
$SourceRevision = '1111111111111111111111111111111111111111'
$Filter = '^Aetheln.Harness.ProjectAndModuleLoad$+^Aetheln.GameCombat.NetworkSpike.Authority$'
$AllowedFailureReasons = @('preflight','engine-pin','repository-dirty','process-start','timeout','editor-exit','missing-report','invalid-report','discovery-mismatch','test-failure','repository-drift')
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }
function Write-Utf8([string] $Path, [string] $Content) {
	$Parent = Split-Path -Parent $Path
	if ($Parent -and -not (Test-Path -LiteralPath $Parent)) { New-Item -ItemType Directory -Path $Parent -Force | Out-Null }
	[IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}
function New-FakeToolchain {
	[CmdletBinding(SupportsShouldProcess)]
	param()
	# Add-Type -OutputAssembly ignores $WhatIfPreference, so the guard precedes every mutation.
	if (-not $PSCmdlet.ShouldProcess($FakeBin, 'Compile fake git, taskkill, and UnrealEditor-Cmd executables')) { return }
	New-Item -ItemType Directory -Path $FakeBin -Force | Out-Null
	$GitSource = @"
using System;
using System.IO;
public static class FakeGitForAethelnAutomation {
 public static int Main(string[] args) {
  string joined=string.Join(" ",args), root=args.Length>1&&args[0]=="-C"?args[1]:"";
  bool engine=root.IndexOf("engine",StringComparison.OrdinalIgnoreCase)>=0;
  string scenario=Environment.GetEnvironmentVariable("FAKE_GIT_CASE")??"clean";
  string pinned="71fe36aac5a8df5ccd66c763ffc902b29b6a9c43", source="1111111111111111111111111111111111111111", alternate="2222222222222222222222222222222222222222";
  if(joined.IndexOf("status --porcelain",StringComparison.Ordinal)>=0) { if(!engine&&scenario=="dirty") Console.WriteLine(" M tracked.txt"); return 0; }
  if(joined.IndexOf("rev-parse",StringComparison.Ordinal)>=0) {
   if(engine) {
    if(joined.IndexOf("refs/tags/5.8.1-release",StringComparison.Ordinal)>=0&&scenario=="tag-mismatch") Console.WriteLine(alternate);
    else if(joined.IndexOf("refs/tags/5.8.1-release",StringComparison.Ordinal)<0&&scenario=="head-mismatch") Console.WriteLine(alternate);
    else Console.WriteLine(pinned);
   } else { string marker=Environment.GetEnvironmentVariable("FAKE_GIT_DRIFT_MARKER")??""; Console.WriteLine(marker.Length>0&&File.Exists(marker)?alternate:source); }
   return 0;
  }
  Console.Error.WriteLine("unsupported fake git invocation: "+joined); return 17;
 }
}
"@
	Add-Type -TypeDefinition $GitSource -OutputAssembly (Join-Path $FakeBin 'git.exe') -OutputType ConsoleApplication
	$TaskKillSource = @"
using System;
using System.IO;
using System.Threading;
public static class FakeTaskKillForAethelnAutomation {
 public static int Main(string[] args) { string capture=Environment.GetEnvironmentVariable("FAKE_TASKKILL_CAPTURE")??""; if(capture.Length>0) File.WriteAllText(capture,"called"); Thread.Sleep((Environment.GetEnvironmentVariable("FAKE_TASKKILL_CASE")??"")=="hang"?30000:500); return 0; }
}
"@
	Add-Type -TypeDefinition $TaskKillSource -OutputAssembly (Join-Path $FakeBin 'taskkill.exe') -OutputType ConsoleApplication
	$EditorSource = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
public static class FakeUnrealEditorForAethelnAutomation {
 static string Test(string path,string state,int warnings,int errors) { return "{\"testDisplayName\":\"fixture\",\"fullTestPath\":\""+path+"\",\"state\":\""+state+"\",\"deviceInstance\":[],\"duration\":0.25,\"dateTime\":\"2026-08-21T00:00:00Z\",\"entries\":[],\"warnings\":"+warnings+",\"errors\":"+errors+",\"artifacts\":[]}"; }
 static string Report(string tests,int succeeded,int warned,int failed,int notRun,int inProcess) { return "{\"devices\":[],\"reportCreatedOn\":\"2026-08-21T00:00:00Z\",\"succeeded\":"+succeeded+",\"succeededWithWarnings\":"+warned+",\"failed\":"+failed+",\"notRun\":"+notRun+",\"inProcess\":"+inProcess+",\"totalDuration\":0.5,\"comparisonExported\":false,\"comparisonExportDirectory\":\"\",\"tests\":["+tests+"]}"; }
 public static int Main(string[] args) {
  if(args.Length==1&&args[0]=="--child") { Thread.Sleep(30000); return 0; }
  string capture=Environment.GetEnvironmentVariable("FAKE_UNREAL_CAPTURE")??""; if(capture.Length>0) File.WriteAllLines(capture,args);
  string reportDirectory="",log=""; foreach(string arg in args) { if(arg.StartsWith("-ReportExportPath=",StringComparison.Ordinal)) reportDirectory=arg.Substring(18); if(arg.StartsWith("-abslog=",StringComparison.Ordinal)) log=arg.Substring(8); }
  if(log.Length>0) { Directory.CreateDirectory(Path.GetDirectoryName(log)); File.WriteAllText(log,"fake unreal automation log\n"); }
  string scenario=Environment.GetEnvironmentVariable("FAKE_UNREAL_CASE")??"success";
  if(scenario=="launch-before-assignment") { ProcessStartInfo info=new ProcessStartInfo(); info.FileName=Process.GetCurrentProcess().MainModule.FileName; info.Arguments="--child"; info.UseShellExecute=false; info.CreateNoWindow=true; Process child=Process.Start(info); File.WriteAllText(Environment.GetEnvironmentVariable("FAKE_UNREAL_CHILD_PID"),child.Id.ToString()); }
  if(scenario=="timeout"||scenario=="parent-exits-at-timeout") { ProcessStartInfo info=new ProcessStartInfo(); info.FileName=Process.GetCurrentProcess().MainModule.FileName; info.Arguments="--child"; info.UseShellExecute=false; info.CreateNoWindow=true; Process child=Process.Start(info); File.WriteAllText(Environment.GetEnvironmentVariable("FAKE_UNREAL_CHILD_PID"),child.Id.ToString()); Thread.Sleep(scenario=="parent-exits-at-timeout"?1100:30000); return 0; }
  Directory.CreateDirectory(reportDirectory);
  string harness=Test("Aetheln.Harness.ProjectAndModuleLoad","Success",0,0), authority=Test("Aetheln.GameCombat.NetworkSpike.Authority","Success",0,0), json;
  if(scenario=="zero") json=Report("",0,0,0,0,0);
  else if(scenario=="missing") json=Report(harness,1,0,0,0,0);
  else if(scenario=="duplicate") json=Report(harness+","+authority+","+authority,3,0,0,0,0);
  else if(scenario=="unexpected") json=Report(harness+","+authority+","+Test("Aetheln.Other","Success",0,0),3,0,0,0,0);
  else if(scenario=="failed") json=Report(harness+","+Test("Aetheln.GameCombat.NetworkSpike.Authority","Fail",0,1),1,0,1,0,0);
  else if(scenario=="not-run") json=Report(harness+","+Test("Aetheln.GameCombat.NetworkSpike.Authority","NotRun",0,0),1,0,0,1,0);
  else if(scenario=="warning") json=Report(harness+","+Test("Aetheln.GameCombat.NetworkSpike.Authority","Success",1,0),1,1,0,0,0);
  else if(scenario=="error") json=Report(harness+","+Test("Aetheln.GameCombat.NetworkSpike.Authority","Success",0,1),2,0,0,0,0);
  else if(scenario=="corrupt") json="{broken";
  else if(scenario=="invalid") json="{\"reportCreatedOn\":\"now\",\"tests\":[]}";
  else json=Report(authority+","+harness,2,0,0,0,0);
  if(scenario!="missing-report") File.WriteAllText(Path.Combine(reportDirectory,"index.json"),json);
  string marker=Environment.GetEnvironmentVariable("FAKE_GIT_DRIFT_MARKER")??""; if(scenario=="drift"&&marker.Length>0) File.WriteAllText(marker,"drift");
  return scenario=="nonzero"?9:0;
 }
}
"@
	Add-Type -TypeDefinition $EditorSource -OutputAssembly (Join-Path $FakeBin 'UnrealEditor-Cmd.exe') -OutputType ConsoleApplication
}
function New-Case {
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType([System.Collections.Specialized.OrderedDictionary])]
	param([string] $Name)
	$Root=Join-Path $FixtureRoot $Name; $Repository=Join-Path $Root 'repo'; $Engine=Join-Path $Root 'engine'; $EditorDirectory=Join-Path $Engine 'Engine\Binaries\Win64'
	# Write-Utf8 ignores $WhatIfPreference; a previewed case returns nothing instead of paths that do not exist.
	if (-not $PSCmdlet.ShouldProcess($Root, 'Create Unreal automation case fixture')) { return }
	New-Item -ItemType Directory -Path (Join-Path $Repository 'scripts\ci'),$EditorDirectory -Force | Out-Null
	Copy-Item $SourceRunner (Join-Path $Repository 'scripts\ci\Invoke-UnrealAutomationTests.ps1'); Copy-Item (Join-Path $FakeBin 'UnrealEditor-Cmd.exe') (Join-Path $EditorDirectory 'UnrealEditor-Cmd.exe'); Write-Utf8 (Join-Path $Repository 'AethelnOnline.uproject') '{}'
	return [ordered]@{root=$Root;repository=$Repository;engine=$Engine;runner=Join-Path $Repository 'scripts\ci\Invoke-UnrealAutomationTests.ps1';editor=Join-Path $EditorDirectory 'UnrealEditor-Cmd.exe';capture=Join-Path $Root 'arguments.txt';childPid=Join-Path $Root 'child-pid.txt';taskkillCapture=Join-Path $Root 'taskkill.txt';driftMarker=Join-Path $Root 'drift.marker';report=Join-Path $Repository 'TestResults\unreal-automation-report.json'}
}
function Invoke-Case([string] $Name,[string] $UnrealCase='success',[string] $GitCase='clean',[int] $TimeoutSeconds=5,[scriptblock] $Prepare) {
	$Fixture=New-Case $Name; if($null-ne $Prepare){& $Prepare $Fixture}
	$env:FAKE_UNREAL_CASE=$UnrealCase;$env:FAKE_GIT_CASE=$GitCase;$env:FAKE_UNREAL_CAPTURE=$Fixture.capture;$env:FAKE_UNREAL_CHILD_PID=$Fixture.childPid;$env:FAKE_TASKKILL_CAPTURE=$Fixture.taskkillCapture;$env:FAKE_GIT_DRIFT_MARKER=$Fixture.driftMarker
	$Info=New-Object Diagnostics.ProcessStartInfo;$Info.FileName=$PowerShell;$Info.Arguments="-NoProfile -ExecutionPolicy Bypass -File `"$($Fixture.runner)`" -EngineRoot `"$($Fixture.engine)`" -TimeoutSeconds $TimeoutSeconds";$Info.WorkingDirectory=$Fixture.repository;$Info.UseShellExecute=$false;$Info.CreateNoWindow=$true;$Info.RedirectStandardOutput=$true;$Info.RedirectStandardError=$true
	$Process=New-Object Diagnostics.Process;$Process.StartInfo=$Info;$Watch=[Diagnostics.Stopwatch]::StartNew()
	try { Assert-True ($Process.Start()) "$Name runner must start.";$Stdout=$Process.StandardOutput.ReadToEndAsync();$Stderr=$Process.StandardError.ReadToEndAsync();Assert-True ($Process.WaitForExit(20000)) "$Name must finish within fixture bound.";$Output=$Stdout.GetAwaiter().GetResult()+$Stderr.GetAwaiter().GetResult();$ExitCode=$Process.ExitCode }
	finally { $Watch.Stop();if(-not $Process.HasExited){$Process.Kill()};$Process.Dispose() }
	Assert-True (Test-Path $Fixture.report -PathType Leaf) "$Name must write normalized report. Output: $Output";$Report=Get-Content $Fixture.report -Raw|ConvertFrom-Json
	return [ordered]@{fixture=$Fixture;exitCode=$ExitCode;output=$Output;report=$Report;durationSeconds=$Watch.Elapsed.TotalSeconds}
}
function Assert-Failure($Run,[string] $ExpectedReason) {
	Assert-True ($Run.exitCode-ne 0) "$ExpectedReason must exit nonzero.";Assert-True ($Run.report.result-ceq 'failed') "$ExpectedReason must report failed.";Assert-True ($Run.report.failureReason-ceq $ExpectedReason) "Expected $ExpectedReason, got $($Run.report.failureReason).";Assert-True ($Run.report.failureReason-cin $AllowedFailureReasons) "$ExpectedReason must be in enum.";Assert-True ($Run.report.failureReason-is [string]) 'failureReason must be a string.'
}
try {
	$DefaultGameSource = Get-Content -LiteralPath $DefaultGameConfig -Raw
	Assert-True ([regex]::Matches($DefaultGameSource, '(?m)^\[/Script/GameplayAbilities\.AbilitySystemGlobals\]\r?$').Count -eq 1) 'DefaultGame.ini must declare the AbilitySystemGlobals section exactly once.'
	Assert-True ([regex]::Matches($DefaultGameSource, '(?m)^\+GameplayCueNotifyPaths=/Game\r?$').Count -eq 1) 'DefaultGame.ini must explicitly preserve the current /Game gameplay-cue search path.'
	$AuthoritySource = Get-Content -LiteralPath $AuthorityTestSource -Raw
	Assert-True ($AuthoritySource -notmatch 'No GameplayCueNotifyPaths were specified') 'The authority test must not require unrelated project-configuration warnings.'
	New-Item -ItemType Directory $FixtureRoot -Force|Out-Null
	New-FakeToolchain -WhatIf;Assert-True (-not(Test-Path -LiteralPath $FakeBin)) 'WhatIf must not create or compile the fake toolchain.'
	$WhatIfCase=New-Case 'whatif-case' -WhatIf;Assert-True ($null-eq $WhatIfCase-and -not(Test-Path -LiteralPath (Join-Path $FixtureRoot 'whatif-case'))) 'WhatIf must not build a case fixture or return one.'
	New-FakeToolchain;$env:PATH=$FakeBin+[IO.Path]::PathSeparator+$OriginalPath
	$Tokens=$null;$Errors=$null;$Ast=[Management.Automation.Language.Parser]::ParseFile($SourceRunner,[ref]$Tokens,[ref]$Errors);Assert-True ($Errors.Count-eq 0) 'Runner must parse.';$Names=@($Ast.ParamBlock.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath});Assert-True ($Names.Count-eq 2-and $Names[0]-ceq 'EngineRoot'-and $Names[1]-ceq 'TimeoutSeconds') 'Only exact public parameters are allowed.'
	$RunnerSource=Get-Content $SourceRunner -Raw;Assert-True ($RunnerSource-match '\[Parameter\(Mandatory\)\][\s\S]*\[string\]\s+\$EngineRoot') 'EngineRoot must be required.';Assert-True ($RunnerSource-match '\[int\]\s+\$TimeoutSeconds\s*=\s*600') 'Timeout default must be 600.';$CreateIndex=$RunnerSource.IndexOf('if(!CreateProcess(');$AssignIndex=$RunnerSource.IndexOf('Assign(information.process)');$ResumeIndex=$RunnerSource.IndexOf('ResumeThread(information.thread)');Assert-True ($CreateIndex-ge 0-and $CreateIndex-lt $AssignIndex-and $AssignIndex-lt $ResumeIndex-and $RunnerSource-match 'CreateSuspended') 'CreateProcess must stay suspended until assignment to the kill-on-close job succeeds.';Assert-True ($RunnerSource-notmatch '\$Process\.Start\(') 'The editor must not use managed Process.Start before job assignment.';Assert-True ($RunnerSource-match 'JOB_OBJECT_LIMIT_KILL_ON_CLOSE|KillOnJobClose'-and $RunnerSource-match 'AssignProcessToJobObject'-and $RunnerSource-match '\$TargetJob\.Dispose\(\)') 'The editor tree must be owned by a kill-on-close Windows Job Object.';Assert-True ($RunnerSource-match 'WaitForExit\(5000\)'-and $RunnerSource-match 'taskkill\.exe'-and $RunnerSource-match "'/T'|/T") 'Cleanup must close the job first and bound taskkill fallback.'
	$EmptyCatches=@($Ast.FindAll({param($Node)$Node -is [Management.Automation.Language.CatchClauseAst]-and $Node.Body.Statements.Count-eq 0},$true))
	Assert-True ($EmptyCatches.Count-eq 0) "Cleanup must never discard a failure silently; empty catch blocks remain at line(s) $(@($EmptyCatches|ForEach-Object{$_.Extent.StartLineNumber})-join ', ')."
	foreach($CleanupFunction in @('Invoke-BoundedTaskKill','Stop-ProcessTree')){$Definition=$Ast.Find({param($Node)$Node -is [Management.Automation.Language.FunctionDefinitionAst]-and $Node.Name-eq $CleanupFunction},$false);Assert-True ($null-ne $Definition) "Cleanup function $CleanupFunction must remain discoverable.";. ([scriptblock]::Create($Definition.Extent.Text))}
	$StopDefinition=$Ast.Find({param($Node)$Node -is [Management.Automation.Language.FunctionDefinitionAst]-and $Node.Name-eq 'Stop-ProcessTree'},$false)
	$StopFirstStatement=@($StopDefinition.Body.EndBlock.Statements)[0]
	Assert-True ($StopFirstStatement -is [Management.Automation.Language.IfStatementAst]-and $StopFirstStatement.Clauses[0].Item1.Extent.Text-match 'ShouldProcess') 'Stop-ProcessTree must decide ShouldProcess before it disposes the kill-on-close job.'
	# Termination fixtures own every process they touch; the fake taskkill already on PATH keeps the fallback observable without terminating anything else.
	$DeclinedJob=[pscustomobject]@{Disposals=0};$DeclinedJob|Add-Member ScriptMethod Dispose {$this.Disposals++}
	$env:FAKE_TASKKILL_CAPTURE=Join-Path $FixtureRoot 'cleanup-declined-taskkill.txt'
	$DeclinedProcess=[Diagnostics.Process]::Start((New-Object Diagnostics.ProcessStartInfo -Property @{FileName=$PowerShell;Arguments='-NoProfile -Command "Start-Sleep -Seconds 30"';UseShellExecute=$false;CreateNoWindow=$true}))
	try { Stop-ProcessTree $DeclinedProcess $DeclinedJob -WhatIf;Assert-True ($DeclinedJob.Disposals-eq 0-and -not $DeclinedProcess.HasExited-and -not(Test-Path $env:FAKE_TASKKILL_CAPTURE)) 'A declined cleanup must not dispose the owning job, terminate the owned tree, or invoke the taskkill fallback.' }
	finally { if(-not $DeclinedProcess.HasExited){$DeclinedProcess.Kill();[void]$DeclinedProcess.WaitForExit(5000)};$DeclinedProcess.Dispose() }
	$UnobservableJob=[pscustomobject]@{Disposals=0};$UnobservableJob|Add-Member ScriptMethod Dispose {$this.Disposals++}
	$env:FAKE_TASKKILL_CAPTURE=Join-Path $FixtureRoot 'cleanup-unobservable-taskkill.txt'
	$Unstarted=New-Object Diagnostics.Process;$UnobservableWatch=[Diagnostics.Stopwatch]::StartNew()
	try { Stop-ProcessTree $Unstarted $UnobservableJob } finally { $UnobservableWatch.Stop();$Unstarted.Dispose() }
	Assert-True ($UnobservableJob.Disposals-eq 1-and $UnobservableWatch.Elapsed.TotalSeconds-lt 10-and -not(Test-Path $env:FAKE_TASKKILL_CAPTURE)) 'Unobservable process state must still dispose the job, stay bounded, and never escalate to termination.'
	$AliveJob=[pscustomobject]@{Disposals=0};$AliveJob|Add-Member ScriptMethod Dispose {$this.Disposals++}
	$env:FAKE_TASKKILL_CAPTURE=Join-Path $FixtureRoot 'cleanup-alive-taskkill.txt'
	$AliveProcess=[Diagnostics.Process]::Start((New-Object Diagnostics.ProcessStartInfo -Property @{FileName=$PowerShell;Arguments='-NoProfile -Command "Start-Sleep -Seconds 30"';UseShellExecute=$false;CreateNoWindow=$true}))
	$AliveWatch=[Diagnostics.Stopwatch]::StartNew()
	try { Stop-ProcessTree $AliveProcess $AliveJob } finally { $AliveWatch.Stop();if(-not $AliveProcess.HasExited){$AliveProcess.Kill();[void]$AliveProcess.WaitForExit(5000)} }
	Assert-True ($AliveJob.Disposals-eq 1-and $AliveProcess.HasExited-and (Test-Path $env:FAKE_TASKKILL_CAPTURE)-and $AliveWatch.Elapsed.TotalSeconds-lt 15) 'A surviving owned process must dispose the job, use the bounded taskkill fallback, and still be terminated.'
	$AliveProcess.Dispose()
	Write-Output 'PASS: declined cleanup terminates nothing and cleanup failures stay explicit and bounded'
	$Success=Invoke-Case 'success';Assert-True ($Success.exitCode-eq 0) "Success failed: $($Success.output)";$Report=$Success.report
	foreach($Field in @('schemaId','schemaVersion','mode','sourceRevision','engineRevision','projectName','filter','timeoutSeconds','startedUtc','finishedUtc','processExitCode','repositoryCleanBefore','repositoryCleanAfter','outputs','tests','summary','result','failureReason')){Assert-True ($null-ne $Report.PSObject.Properties[$Field]) "Missing $Field."}
	Assert-True ($Report.schemaId-ceq 'aetheln.unreal-automation'-and $Report.schemaVersion-eq 1-and $Report.mode-ceq 'production') 'Schema identity invalid.';Assert-True ($Report.sourceRevision-ceq $SourceRevision-and $Report.engineRevision-ceq $PinnedRevision-and $Report.projectName-ceq 'AethelnOnline') 'Revision/project identity invalid.';Assert-True ($Report.filter-ceq $Filter-and $Report.timeoutSeconds-eq 5-and $Report.processExitCode-eq 0) 'Filter/timeout/exit invalid.';Assert-True ($Report.repositoryCleanBefore-and $Report.repositoryCleanAfter) 'Clean boundaries required.'
	Assert-True ($Report.outputs.unrealReport-ceq 'TestResults/UnrealAutomation/index.json'-and $Report.outputs.log-ceq 'Saved/Logs/AethelnUnrealAutomation.log'-and @($Report.outputs.PSObject.Properties).Count-eq 2) 'Outputs invalid.';Assert-True (@($Report.tests).Count-eq 2-and $Report.tests[0].fullTestPath-ceq 'Aetheln.GameCombat.NetworkSpike.Authority'-and $Report.tests[1].fullTestPath-ceq 'Aetheln.Harness.ProjectAndModuleLoad') 'Exact deterministic discovery invalid.'
	foreach($Test in $Report.tests){foreach($Field in @('fullTestPath','state','status','durationSeconds','warningCount','errorCount')){Assert-True ($null-ne $Test.PSObject.Properties[$Field]) "Missing test $Field."};Assert-True ($Test.state-ceq 'Success'-and $Test.status-ceq 'passed'-and $Test.warningCount-eq 0-and $Test.errorCount-eq 0) 'Test must be clean Success.'}
	Assert-True ($Report.summary.total-eq 2-and $Report.summary.passed-eq 2-and $Report.summary.passedWithWarnings-eq 0-and $Report.summary.failed-eq 0-and $Report.summary.notRun-eq 0-and $Report.summary.missing-eq 0-and $Report.summary.requiredFailed-eq 0-and $Report.result-ceq 'passed'-and $Report.failureReason-ceq 'none'-and $Report.failureReason-is [string]) 'Success summary/result invalid.'
	$Arguments=[IO.File]::ReadAllLines($Success.fixture.capture);$Expected=@((Join-Path $Success.fixture.repository 'AethelnOnline.uproject'),'-unattended','-nop4','-nullrhi',"-ExecCmds=Automation RunTests $Filter; Quit",'-TestExit=Automation Test Queue Empty',('-ReportExportPath='+(Join-Path $Success.fixture.repository 'TestResults\UnrealAutomation')),('-abslog='+(Join-Path $Success.fixture.repository 'Saved\Logs\AethelnUnrealAutomation.log')));Assert-True ($Arguments.Count-eq $Expected.Count) 'Argument count invalid.';for($i=0;$i-lt $Expected.Count;$i++){Assert-True ($Arguments[$i]-ceq $Expected[$i]) "Argument $i invalid."}
	$Second=Invoke-Case 'deterministic';$One=[ordered]@{tests=$Success.report.tests;summary=$Success.report.summary;result=$Success.report.result;failureReason=$Success.report.failureReason}|ConvertTo-Json -Depth 6 -Compress;$Two=[ordered]@{tests=$Second.report.tests;summary=$Second.report.summary;result=$Second.report.result;failureReason=$Second.report.failureReason}|ConvertTo-Json -Depth 6 -Compress;Assert-True ($One-ceq $Two) 'Normalization must be deterministic.'
	$Launch=Invoke-Case 'launch-before-assignment' 'launch-before-assignment';Assert-True ($Launch.exitCode-eq 0-and $Launch.report.result-ceq 'passed') 'Immediate-child launch must pass only after suspended assignment.';Assert-True (Test-Path $Launch.fixture.childPid) 'Immediate launch child missing.';$LaunchChild=[int](Get-Content $Launch.fixture.childPid -Raw);for($i=0;$i-lt 20-and $null-ne(Get-Process -Id $LaunchChild -ErrorAction SilentlyContinue);$i++){Start-Sleep -Milliseconds 100};Assert-True ($null-eq(Get-Process -Id $LaunchChild -ErrorAction SilentlyContinue)) 'A child launched at editor entry escaped job ownership.'
	foreach($Case in @(@('tag-pin','tag-mismatch'),@('head-pin','head-mismatch'))){$Run=Invoke-Case -Name $Case[0] -UnrealCase 'success' -GitCase $Case[1];Assert-Failure $Run 'engine-pin';Assert-True (-not(Test-Path $Run.fixture.capture)) 'Pin mismatch must not launch.'}
	$Dirty=Invoke-Case -Name 'dirty' -UnrealCase 'success' -GitCase 'dirty';Assert-Failure $Dirty 'repository-dirty';Assert-True (-not(Test-Path $Dirty.fixture.capture)) 'Dirty repo must not launch.'
	Assert-Failure (Invoke-Case -Name 'preflight' -UnrealCase 'success' -GitCase 'clean' -TimeoutSeconds 5 -Prepare {param($f)Remove-Item $f.editor -Force}) 'preflight';Assert-Failure (Invoke-Case -Name 'process-start' -UnrealCase 'success' -GitCase 'clean' -TimeoutSeconds 5 -Prepare {param($f)Write-Utf8 $f.editor 'not executable'}) 'process-start'
	foreach($Scenario in @('zero','missing','duplicate','unexpected')){$Run=Invoke-Case "discovery-$Scenario" $Scenario;Assert-Failure $Run 'discovery-mismatch';Assert-True ($Run.report.summary.requiredFailed-gt 0) "$Scenario must count failure."}
	foreach($Scenario in @('failed','not-run','warning','error')){$Run=Invoke-Case "test-$Scenario" $Scenario;Assert-Failure $Run 'test-failure';Assert-True ($Run.report.summary.requiredFailed-gt 0) "$Scenario must count failure."}
	$Nonzero=Invoke-Case 'nonzero' 'nonzero';Assert-Failure $Nonzero 'editor-exit';Assert-True ($Nonzero.report.processExitCode-eq 9) 'Exit code must be preserved.';Assert-Failure (Invoke-Case 'missing-report' 'missing-report') 'missing-report';foreach($Scenario in @('corrupt','invalid')){Assert-Failure (Invoke-Case "report-$Scenario" $Scenario) 'invalid-report'}
	$Drift=Invoke-Case 'drift' 'drift';Assert-Failure $Drift 'repository-drift';Assert-True ($Drift.report.repositoryCleanBefore-and -not $Drift.report.repositoryCleanAfter) 'Drift boundaries invalid.'
	$env:FAKE_TASKKILL_CASE='hang';foreach($TimeoutScenario in @('timeout','parent-exits-at-timeout')){$Timeout=Invoke-Case -Name $TimeoutScenario -UnrealCase $TimeoutScenario -GitCase 'clean' -TimeoutSeconds 1;Assert-Failure $Timeout 'timeout';Assert-True ($Timeout.durationSeconds-lt 10) "$TimeoutScenario was blocked by hanging taskkill fallback.";Assert-True (-not(Test-Path $Timeout.fixture.taskkillCapture)) "$TimeoutScenario invoked taskkill before job disposal.";Assert-True (Test-Path $Timeout.fixture.childPid) "$TimeoutScenario child missing.";$ChildId=[int](Get-Content $Timeout.fixture.childPid -Raw);for($i=0;$i-lt 20-and $null-ne(Get-Process -Id $ChildId -ErrorAction SilentlyContinue);$i++){Start-Sleep -Milliseconds 100};Assert-True ($null-eq(Get-Process -Id $ChildId -ErrorAction SilentlyContinue)) "$TimeoutScenario child tree survived timeout."};Remove-Item Env:FAKE_TASKKILL_CASE -ErrorAction SilentlyContinue
	Write-Output 'PASS: Unreal automation runner fixture contract is completely covered'
}
finally {
	$env:PATH=$OriginalPath;foreach($Name in @('FAKE_UNREAL_CASE','FAKE_GIT_CASE','FAKE_UNREAL_CAPTURE','FAKE_UNREAL_CHILD_PID','FAKE_TASKKILL_CASE','FAKE_TASKKILL_CAPTURE','FAKE_GIT_DRIFT_MARKER')){Remove-Item ('Env:'+$Name) -ErrorAction SilentlyContinue};if(Test-Path $FixtureRoot){Remove-Item $FixtureRoot -Recurse -Force}
}
