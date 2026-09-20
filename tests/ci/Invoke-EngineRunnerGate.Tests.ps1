param([switch] $CompileWatchdogOnly, [switch] $HandoffContractsOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path (Split-Path $PSScriptRoot)
$SourceScript = Join-Path $RepositoryRoot 'scripts/ci/Invoke-EngineRunnerGate.ps1'
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
$RetainFixtureEvidence = $false
$PowerShell = (Get-Process -Id $PID).Path
$Original = @{ PATH = $env:PATH; Engine = $env:AETHELN_ENGINE_ROOT; Toolchain = $env:AETHELN_LINUX_TOOLCHAIN_ROOT; Handoff = $env:AETHELN_HANDOFF_ROOT }

function Assert-True($Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Test-HandoffPrimitiveContract {
	$ParseErrors = $null
	$Tokens = $null
	$Ast = [System.Management.Automation.Language.Parser]::ParseFile($SourceScript, [ref] $Tokens, [ref] $ParseErrors)
	Assert-True ($ParseErrors.Count -eq 0) 'The gate source must parse before its handoff contracts are tested.'
	foreach ($Name in @('Assert-UniqueJsonProperty', 'Stop-PhaseProcessTree')) {
		$Functions = @($Ast.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $Name }, $true))
		Assert-True ($Functions.Count -eq 1) "The gate must have exactly one $Name function."
		# Dot-sourced so the extracted definition lands in this same scope, as
		# Invoke-Expression did, without evaluating the text as a command line.
		. ([scriptblock]::Create($Functions[0].Extent.Text))
	}
	foreach ($Raw in @('{"runId":"bad","\u0072unId":"valid"}', '{"files":[{"path":"bad","p\u0061th":"valid"}]}')) {
		$Rejected = $false
		try { Assert-UniqueJsonProperty $Raw 'handoff_schema_invalid' } catch { Assert-True ($_.Exception.Message -eq 'handoff_schema_invalid') 'Escaped duplicates must retain the stable failure reason.'; $Rejected = $true }
		Assert-True $Rejected 'Escaped duplicate property names must reject at root and nested scopes.'
	}
	Assert-UniqueJsonProperty '{"\u0072unId":"valid","files":[{"path":"a"},{"path":"b"}]}' 'handoff_schema_invalid'
	$PreviousFault = $env:RUNNER_TEST_KILL_FAULT
	try {
		$env:RUNNER_TEST_KILL_FAULT = ''
		$FakeRoot = [pscustomobject]@{ HasExited = $true; Id = -1 }
		$FakeRoot | Add-Member ScriptMethod WaitForExit { return $true }
		$FakeJob = [pscustomobject]@{ Attempts = 0 }
		$FakeJob | Add-Member ScriptMethod Dispose { }
		$FakeJob | Add-Member ScriptMethod TerminateAndWait { $this.Attempts++; throw 'Descendant accounting unavailable.' }
		$Rejected = $false
		try { Stop-PhaseProcessTree $FakeRoot $FakeJob } catch { Assert-True ($_.Exception.Message -eq 'phase_cleanup_failed') 'Unverifiable descendants must retain the stable cleanup failure reason.'; $Rejected = $true }
		Assert-True ($Rejected -and $FakeJob.Attempts -gt 0) 'An exited root cannot establish owned-tree cleanup when Job Object accounting is unavailable.'
		$FakeJob | Add-Member ScriptMethod TerminateAndWait { $this.Attempts++ } -Force
		$FakeJob.Attempts = 0
		Stop-PhaseProcessTree $FakeRoot $FakeJob
		Assert-True ($FakeJob.Attempts -gt 0) 'Successful cleanup must use owned Job Object termination accounting.'
		# A declined cleanup must decide before it touches the owned tree: no Job
		# Object termination accounting, no bounded wait, and no direct kill.
		$DeclinedJob = [pscustomobject]@{ Attempts = 0 }
		$DeclinedJob | Add-Member ScriptMethod Dispose { }
		$DeclinedJob | Add-Member ScriptMethod TerminateAndWait { $this.Attempts++ }
		$DeclinedRoot = [pscustomobject]@{ HasExited = $true; Id = -1 }
		$DeclinedRoot | Add-Member ScriptMethod WaitForExit { return $true }
		$DeclinedRoot | Add-Member ScriptMethod Kill { throw 'A declined cleanup must never terminate the owned tree.' }
		Stop-PhaseProcessTree -TargetProcess $DeclinedRoot -TargetJob $DeclinedJob -WhatIf
		Assert-True ($DeclinedJob.Attempts -eq 0) 'A declined cleanup must not use owned Job Object termination accounting.'
	} finally { $env:RUNNER_TEST_KILL_FAULT = $PreviousFault }
	Write-Output 'PASS: decoded handoff keys and owned-tree cleanup accounting contracts'
}
function Write-Fixture([string] $Path, [string] $Value) {
	Set-Content -LiteralPath $Path -Value $Value -Encoding UTF8
}
function Edit-FixtureText([string] $Source, [string] $Before, [string] $After) {
	Assert-True (($Source.Split(@($Before), [StringSplitOptions]::None).Count - 1) -eq 1) 'A fixture instrumentation anchor must match exactly once.'
	return $Source.Replace($Before, $After)
}
function Install-CompileClockFixture($Fixture, [switch] $BlockDiagnostics, [switch] $Cooperative, [switch] $PhaseProbe) {
	# Inject only the clock and OS wait boundary in a disposable source copy.
	# Deadline construction, shared Started context, stage checks, real Job Object
	# termination and report publication remain the production implementations.
	# Virtual startup/diagnostics/client/server cost 3/3/3/4 seconds, each less
	# than the 10.2 second budget, but jointly beyond its 2 second hard grace.
	# The cooperative variant completes the server at second 11, before hard
	# grace, so a fresh per-target budget cannot be masked by the hard watchdog.
	# Phase probes advance only at the required blocked child/hash/smoke stage.
	$Fixture.Clock = Join-Path $Fixture.Root 'clock'
	New-Item -ItemType Directory -Path $Fixture.Clock | Out-Null
	$env:RUNNER_TEST_CLOCK_ROOT = $Fixture.Clock
	$ClockSupport = @'
function Get-FixtureUtcNow {
	$Seconds = 0
	foreach ($Stage in @('003-startup', '006-diagnostics', '009-client', '011-server', '013-server', '013-diagnostics', '007-phase', '021-hash', '025-smoke')) {
		if (Test-Path -LiteralPath (Join-Path $env:RUNNER_TEST_CLOCK_ROOT $Stage)) { $Seconds = [Math]::Max($Seconds, [int] $Stage.Substring(0, 3)) }
	}
	return ([datetime] '2026-01-01T00:00:00Z').ToUniversalTime().AddSeconds($Seconds)
}
function Get-FixtureWaitStart {
	$script:FixtureWaitStart = Get-FixtureUtcNow
	return $script:FixtureWaitStart
}
function Wait-FixtureProcess($Process, [datetime] $Deadline, [double] $WaitMilliseconds, [datetime] $LaunchTime) {
	# The OS still supplies real process exit/timeout and cleanup behavior.
	# A missing stage is a fixture failure, never successful timeout coverage.
	$Guard = [Diagnostics.Stopwatch]::StartNew()
	if ($Deadline -eq [datetime]::MaxValue) { $Deadline = $LaunchTime.AddMilliseconds($WaitMilliseconds) }
	else {
		$ExpectedRemaining = [Math]::Max(0, ($Deadline - $script:FixtureWaitStart).TotalMilliseconds)
		if ($WaitMilliseconds -ne $ExpectedRemaining) { throw 'fixture_remaining_budget_mismatch' }
	}
	@{ deadline = $Deadline.ToString('o'); remainingMilliseconds = $WaitMilliseconds } | ConvertTo-Json | Set-Content (Join-Path $env:RUNNER_TEST_CLOCK_ROOT ("wait-$PID.json"))
	while (-not $Process.WaitForExit(25)) {
		if ((Get-FixtureUtcNow) -ge $Deadline) { return $false }
		if ($Guard.Elapsed.TotalSeconds -ge 90) { throw 'fixture_stage_handshake_timeout' }
	}
	return $true
}
'@
	$Path = Join-Path $Fixture.Repository 'scripts/ci/Invoke-EngineRunnerGate.ps1'
	$Source = Get-Content -LiteralPath $Path -Raw
	$Source = $Source.Replace('[DateTime]::UtcNow', '(Get-FixtureUtcNow)')
	$Source = Edit-FixtureText -Source $Source -Before '$Started = (Get-FixtureUtcNow)' -After ($ClockSupport + "`r`n" + '$Started = (Get-FixtureUtcNow)')
	$Source = Edit-FixtureText -Source $Source -Before '($AbsoluteDeadlineUtc - (Get-FixtureUtcNow)).TotalMilliseconds' -After '($AbsoluteDeadlineUtc - (Get-FixtureWaitStart)).TotalMilliseconds'
	$Source = Edit-FixtureText -Source $Source -Before '$ChildJob = New-Object Aetheln.EngineGateJob' -After ('$FixtureLaunchTime = Get-FixtureUtcNow' + "`r`n" + '$ChildJob = New-Object Aetheln.EngineGateJob')
	$Source = Edit-FixtureText -Source $Source -Before '$ChildProcess.WaitForExit([int][Math]::Ceiling($WaitMilliseconds))' -After '(Wait-FixtureProcess $ChildProcess $AbsoluteDeadlineUtc $WaitMilliseconds $FixtureLaunchTime)'
	$Source = Edit-FixtureText -Source $Source -Before '$CompileDeadlineUtc = $Started.AddMinutes($CompileTimeoutMinutes)' -After @'
$CompileDeadlineUtc = $Started.AddMinutes($CompileTimeoutMinutes)
		@{ started = $Started.ToString('o'); deadline = $CompileDeadlineUtc.ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $env:RUNNER_TEST_CLOCK_ROOT ("deadline-$IsCompileChild.json"))
'@
	$Source = Edit-FixtureText -Source $Source -Before '$HardDeadline = $Started.AddMinutes($CompileTimeoutMinutes).AddSeconds(2)' -After @'
New-Item -ItemType File (Join-Path $env:RUNNER_TEST_CLOCK_ROOT '003-startup') | Out-Null
	$HardDeadline = $Started.AddMinutes($CompileTimeoutMinutes).AddSeconds(2)
'@
	$DiagnosticBody = if ($PhaseProbe) { 'function Resolve-CompileEvidenceIdentity {' } elseif ($BlockDiagnostics) { @'
function Resolve-CompileEvidenceIdentity {
	& $env:RUNNER_TEST_CLOCK_BUILD 'diagnostics'
'@ } else { @'
function Resolve-CompileEvidenceIdentity {
	New-Item -ItemType File (Join-Path $env:RUNNER_TEST_CLOCK_ROOT '006-diagnostics') | Out-Null
'@ }
	$Source = Edit-FixtureText -Source $Source -Before 'function Resolve-CompileEvidenceIdentity {' -After $DiagnosticBody
	if ($PhaseProbe) {
		$Source = Edit-FixtureText -Source $Source -Before 'Start-Sleep -Seconds ([int] $HashBlockSeconds)' -After "& `$env:RUNNER_TEST_CLOCK_BUILD 'hash'"
	}
	Write-Fixture $Path $Source
	Install-FakeTool $Fixture
	$env:RUNNER_TEST_CLOCK_BUILD = Join-Path $Fixture.Root 'clock-build.ps1'
	Write-Fixture $env:RUNNER_TEST_CLOCK_BUILD @'
param([string] $Target)
$Stage = switch ($Target) { 'AethelnOnlineClient' { '009-client' }; 'AethelnOnlineServer' { '013-server' }; 'diagnostics' { '013-diagnostics' }; 'phase' { '007-phase' }; 'hash' { '021-hash' }; 'smoke' { '025-smoke' }; default { throw 'unknown_fixture_target' } }
$Descendant = Start-Process -FilePath $env:RUNNER_TEST_DESCENDANT_EXE -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120') -WindowStyle Hidden -PassThru
@{ id = $Descendant.Id; startTicks = $Descendant.StartTime.ToUniversalTime().Ticks } | ConvertTo-Json | Set-Content (Join-Path $env:RUNNER_TEST_CLOCK_ROOT ($Stage + '.json'))
New-Item -ItemType File (Join-Path $env:RUNNER_TEST_CLOCK_ROOT $Stage) | Out-Null
if ($Stage -notin @('009-client', '011-server')) { Start-Sleep -Seconds 120 }
'@
	if ($Cooperative) {
		Write-Fixture $env:RUNNER_TEST_CLOCK_BUILD ((Get-Content $env:RUNNER_TEST_CLOCK_BUILD -Raw).Replace("'013-server'", "'011-server'"))
	}
	if ($PhaseProbe) {
		$PackagePath = Join-Path $Fixture.Repository 'scripts/build/Build-PackagedArtifacts.ps1'
		Write-Fixture $PackagePath (Edit-FixtureText -Source (Get-Content $PackagePath -Raw) -Before 'Start-Sleep -Seconds ([int]$env:RUNNER_TEST_PHASE_SLEEP)' -After "& `$env:RUNNER_TEST_CLOCK_BUILD 'phase'")
		$SmokePath = Join-Path $Fixture.Repository 'scripts/build/Invoke-PackagedSmokeTest.ps1'
		Write-Fixture $SmokePath (Edit-FixtureText -Source (Get-Content $SmokePath -Raw) -Before 'Start-Sleep -Seconds ([int]$env:RUNNER_TEST_SMOKE_HANG)' -After "& `$env:RUNNER_TEST_CLOCK_BUILD 'smoke'")
		Invoke-FixtureGit $Fixture @('add', '.')
		& git -C $Fixture.Repository -c user.name=test -c user.email=test@invalid commit -qm clock-fixtures
		$Fixture.Revision = Get-FixtureRevision $Fixture
	}
	Write-Fixture $Fixture.BuildBatch '@echo off
>>"%RUNNER_TEST_BUILD_CAPTURE%" echo %*
powershell -NoProfile -File "%RUNNER_TEST_CLOCK_BUILD%" %1
exit /b %ERRORLEVEL%'
}
function Assert-CompileClockFixture($Fixture, $Result, [int] $ExpectedBuilds, [string[]] $Stages, [bool] $HardTimeout = $true) {
	$ObservedBuilds = if (Test-Path $Fixture.BuildCapture) { @(Get-Content $Fixture.BuildCapture).Count } else { 0 }
	$ObservedStages = @(Get-ChildItem $Fixture.Clock -File | ForEach-Object Name) -join ', '
	Assert-ReportReason -Result $Result -Reason 'compile_timeout' -Message "Shared virtual clock must expire (builds=$ObservedBuilds; stages=$ObservedStages)"
	Assert-True ($ObservedBuilds -eq $ExpectedBuilds) "Expected $ExpectedBuilds builds; observed $ObservedBuilds; stages=$ObservedStages"
	foreach ($Stage in $Stages) {
		Assert-True (Test-Path (Join-Path $Fixture.Clock $Stage)) "Required stage $Stage must be reached; observed=$ObservedStages"
		$Receipt = Get-Content (Join-Path $Fixture.Clock ($Stage + '.json')) -Raw | ConvertFrom-Json
		$Process = Get-Process -Id $Receipt.id -ErrorAction SilentlyContinue
		Assert-True ($null -eq $Process -or $Process.StartTime.ToUniversalTime().Ticks -ne $Receipt.startTicks) "The exact owned descendant at $Stage must be gone before reporting."
	}
	$Anchor = ([datetime] '2026-01-01T00:00:00Z').ToUniversalTime()
	foreach ($Role in @('False', 'True')) {
		$Deadline = Get-Content (Join-Path $Fixture.Clock ("deadline-$Role.json")) -Raw | ConvertFrom-Json
		Assert-True ([datetime]::Parse($Deadline.started).ToUniversalTime() -eq $Anchor -and [datetime]::Parse($Deadline.deadline).ToUniversalTime() -eq $Anchor.AddSeconds(10.2)) "Parent and child must share the original startup anchor and entire work budget (role=$Role; started=$($Deadline.started); deadline=$($Deadline.deadline))."
	}
	$WaitFiles = @(Get-ChildItem $Fixture.Clock -Filter 'wait-*.json')
	Assert-True ($WaitFiles.Count -eq 1) 'Both native targets must share exactly one supervisor wait.'
	$Wait = Get-Content $WaitFiles[0].FullName -Raw | ConvertFrom-Json
	Assert-True ([datetime]::Parse($Wait.deadline).ToUniversalTime() -eq $Anchor.AddSeconds(12.2)) 'The hard watchdog must use the original whole-work deadline plus exactly bounded grace.'
	$Report = Read-Report $Result
	Assert-True ($Report.summary.requiredFailed -gt 0 -and $Report.supervisor.timedOut -eq $HardTimeout -and $Report.supervisor.cleanupVerified) 'Clock-driven timeout must preserve the expected hard/cooperative receipt and verified real owned-tree cleanup.'
}
function Invoke-FixtureGit($Fixture, [string[]] $Arguments) {
	& git -C $Fixture.Repository @Arguments | Out-Null
	if ($LASTEXITCODE -ne 0) { throw 'git fixture failed' }
}
function Get-FixtureRevision($Fixture) {
	$Revision = (& git -C $Fixture.Repository rev-parse HEAD).Trim()
	Assert-True ($Revision -match '^[0-9a-f]{40}$') 'Fixture revision must be a full hash.'
	return $Revision
}
function New-Fixture {
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType([hashtable])]
	param([string] $Name)
	# Decide before the first directory: a declined build creates no fixture
	# tree, no repository copy, and no Git history.
	if (-not $PSCmdlet.ShouldProcess($Name, 'Create an isolated gate fixture tree')) { return }
	$Root = Join-Path $FixtureRoot $Name
	$Repository = Join-Path $Root 'repo'
	$Engine = Join-Path $Root 'engine'
	$BatchRoot = Join-Path $Engine 'Engine/Build/BatchFiles'
	New-Item -ItemType Directory -Force -Path (Join-Path $Repository 'scripts/ci'), (Join-Path $Repository 'scripts/build'), $BatchRoot, (Join-Path $Root 'toolchain'), (Join-Path $Root 'bin') | Out-Null
	Copy-Item -LiteralPath $SourceScript -Destination (Join-Path $Repository 'scripts/ci/Invoke-EngineRunnerGate.ps1')
	Write-Fixture (Join-Path $Repository 'AethelnOnline.uproject') '{}'
	Write-Fixture (Join-Path $Repository '.gitignore') "Intermediate/`nTestResults/"
	Write-Fixture (Join-Path $Repository 'tracked') 'x'
	New-Item -ItemType Directory -Force -Path (Join-Path $Root 'handoff') | Out-Null
	$Fixture = @{
		Root = $Root; Repository = $Repository; Engine = $Engine; Toolchain = Join-Path $Root 'toolchain'
		BuildBatch = Join-Path $BatchRoot 'Build.bat'; Bin = Join-Path $Root 'bin'
		Archive = Join-Path $Root 'archive'; Logs = Join-Path $Root 'logs'
		BuildCapture = Join-Path $Root 'build.txt'; PackageCapture = Join-Path $Root 'package.jsonl'
		SmokeCapture = Join-Path $Root 'smoke.json'; WslCapture = Join-Path $Root 'wsl.jsonl'
		Handoff = Join-Path $Root 'handoff'
	}
	Invoke-FixtureGit $Fixture @('init', '-q')
	Invoke-FixtureGit $Fixture @('add', '.')
	& git -C $Repository -c user.name=test -c user.email=test@invalid commit -qm base
	$Fixture.Revision = Get-FixtureRevision $Fixture
	return $Fixture
}
function Install-FakeTool($Fixture) {
	Write-Fixture $Fixture.BuildBatch '@echo off
>>"%RUNNER_TEST_BUILD_CAPTURE%" echo %*
if defined RUNNER_TEST_UBT_OUTPUT_%1 call type "%%RUNNER_TEST_UBT_OUTPUT_%1%%"
if "%RUNNER_TEST_MUTATION%"=="ignored" (mkdir "%RUNNER_TEST_REPOSITORY%\Intermediate" 2>nul&echo x>"%RUNNER_TEST_REPOSITORY%\Intermediate\x")
if "%RUNNER_TEST_MUTATION%"=="dirty" echo y>"%RUNNER_TEST_REPOSITORY%\tracked"
if "%RUNNER_TEST_MUTATION%"=="revision" git -C "%RUNNER_TEST_REPOSITORY%" update-ref HEAD %RUNNER_TEST_ALT_REVISION%
if "%RUNNER_TEST_FAIL_TARGET%"=="%1" (
echo error C1234 actionable build diagnostic at %AETHELN_ENGINE_ROOT%\Engine\Source\Build.cpp
echo Authorization Bearer ghp_build_marker_12345678901234567890
echo API_KEY=build_assignment_marker
echo Name                           Value
echo ----                           -----
echo BUILD_ENV                      build_table_marker
echo AWS_ACCESS_KEY_ID AKIA1234567890ABCDEF
echo ConnectionString build_connection_marker
echo unlabelledBearerValue0123456789abcdefghijklmnop
echo password: build_password_marker
echo CLIENT_SECRET build_client_secret_marker
exit /b 9
)
exit /b 0'
	Write-Fixture (Join-Path $Fixture.Repository 'scripts/build/Build-PackagedArtifacts.ps1') 'param($ProjectPath,$EngineRoot,$LinuxToolchainRoot,$ArchiveRoot,$LogRoot,$SourceRevision,$Configuration,$Map,$Stage,$ClientStageRoot,$ServerStageRoot,$DerivedDataCachePath,$CacheFallback,$HostToolsBoundary,$EngineRevision,$HostToolsAttestationPath,$RunnerName)
@{ProjectPath=$ProjectPath;EngineRoot=$EngineRoot;LinuxToolchainRoot=$LinuxToolchainRoot;ArchiveRoot=$ArchiveRoot;LogRoot=$LogRoot;SourceRevision=$SourceRevision;Configuration=$Configuration;Map=$Map;Stage=$Stage;ClientStageRoot=$ClientStageRoot;ServerStageRoot=$ServerStageRoot;DerivedDataCachePath=$DerivedDataCachePath;CacheFallback=$CacheFallback;HostToolsBoundary=$HostToolsBoundary;EngineRevision=$EngineRevision;HostToolsAttestationPath=$HostToolsAttestationPath;RunnerName=$RunnerName}|ConvertTo-Json -Compress|Add-Content $env:RUNNER_TEST_PACKAGE_CAPTURE
if($env:RUNNER_TEST_UBT_OUTPUT_PACKAGE){Get-Content $env:RUNNER_TEST_UBT_OUTPUT_PACKAGE}
if($env:RUNNER_TEST_PHASE_SPAWN){Start-Process -FilePath $env:RUNNER_TEST_DESCENDANT_EXE -ArgumentList @("-NoProfile","-Command","Start-Sleep -Seconds 120") -WindowStyle Hidden|Out-Null}
if($env:RUNNER_TEST_PHASE_SLEEP){Start-Sleep -Seconds ([int]$env:RUNNER_TEST_PHASE_SLEEP)}
if($Stage){
New-Item -ItemType Directory -Force -Path $LogRoot|Out-Null
if($env:RUNNER_TEST_PHASE_FAIL -eq $Stage){Write-Output "error P1234 phase fixture failure";exit 9}
if($Stage -eq "Client"){
New-Item -ItemType Directory -Force -Path (Join-Path $ArchiveRoot "WindowsClient/AethelnOnline/Binaries/Win64")|Out-Null
Set-Content (Join-Path $ArchiveRoot "WindowsClient/AethelnOnlineClient.exe") launcher
Set-Content (Join-Path $ArchiveRoot "WindowsClient/AethelnOnline/Binaries/Win64/AethelnOnlineClient.exe") binary
Set-Content (Join-Path $ArchiveRoot "phase-client.json") ''{"schemaVersion":1,"stage":"client"}''
}
if($Stage -eq "Server"){
New-Item -ItemType Directory -Force -Path (Join-Path $ArchiveRoot "LinuxServer/Linux"),(Join-Path $ArchiveRoot "RegistryDumps/server-dependency-registry-dump"),(Join-Path $ArchiveRoot "RegistryDumps/server-cooked-inventory-dump")|Out-Null
Set-Content (Join-Path $ArchiveRoot "LinuxServer/Linux/AethelnOnlineServer.sh") server
Set-Content (Join-Path $ArchiveRoot "RegistryDumps/server-dependency-registry-dump/Page_0.txt") dep
Set-Content (Join-Path $ArchiveRoot "RegistryDumps/server-cooked-inventory-dump/Page_0.txt") inv
Set-Content (Join-Path $ArchiveRoot "phase-server.json") ''{"schemaVersion":1,"stage":"server"}''
}
if($Stage -eq "Provenance"){
New-Item -ItemType Directory -Force -Path $ArchiveRoot|Out-Null
Set-Content (Join-Path $ArchiveRoot "build-provenance.json") ''{"fixture":true}''
}
exit 0
}
New-Item -ItemType Directory -Force -Path (Join-Path $ArchiveRoot "w/AethelnOnline/Binaries/Win64"),(Join-Path $ArchiveRoot "l"),$LogRoot|Out-Null
Set-Content (Join-Path $ArchiveRoot "w/AethelnOnlineClient.exe") launcher
if($env:RUNNER_TEST_INTERNAL -ne "missing"){
$InternalName=if($env:RUNNER_TEST_INTERNAL -eq "mismatch"){"AethelnOnline.exe"}else{"AethelnOnlineClient.exe"}
Set-Content (Join-Path $ArchiveRoot "w/AethelnOnline/Binaries/Win64/$InternalName") binary
}
Set-Content (Join-Path $ArchiveRoot "l/AethelnOnlineServer.sh") server
if($env:RUNNER_TEST_AMBIGUOUS -eq "client"){Set-Content (Join-Path $ArchiveRoot "w/AethelnOnline.exe") client2}
if($env:RUNNER_TEST_AMBIGUOUS -eq "server"){New-Item -ItemType Directory -Force (Join-Path $ArchiveRoot "l2")|Out-Null;Set-Content (Join-Path $ArchiveRoot "l2/AethelnOnlineServer.sh") server2}'
	Write-Fixture (Join-Path $Fixture.Repository 'scripts/build/Invoke-PackagedSmokeTest.ps1') 'param($ServerExecutable,$ServerLauncherExecutable,$ServerLauncherArguments,$ClientExecutable,$ClientBaseArguments,$ServerEndpoint,$ServerMap,$LogRoot,$ServerReadyPattern,$ServerClientConnectedPattern,$ClientConnectedPattern,$ClientMapPattern,$TimeoutSeconds)
@{ServerExecutable=$ServerExecutable;ServerLauncherExecutable=$ServerLauncherExecutable;ServerLauncherArguments=$ServerLauncherArguments;ClientExecutable=$ClientExecutable;ClientBaseArguments=$ClientBaseArguments;ServerEndpoint=$ServerEndpoint;ServerMap=$ServerMap;LogRoot=$LogRoot;ServerReadyPattern=$ServerReadyPattern;ServerClientConnectedPattern=$ServerClientConnectedPattern;ClientConnectedPattern=$ClientConnectedPattern;ClientMapPattern=$ClientMapPattern;TimeoutSeconds=$TimeoutSeconds}|ConvertTo-Json -Depth 4|Set-Content $env:RUNNER_TEST_SMOKE_CAPTURE
if($env:RUNNER_TEST_SMOKE_HANG){Start-Sleep -Seconds ([int]$env:RUNNER_TEST_SMOKE_HANG)}
if($env:RUNNER_TEST_SMOKE_FAIL){
Write-Output "error NET001 actionable timeout diagnostic for $ServerExecutable"
Write-Output "token smoke_bearer_marker"
Write-Output "PASSWORD=smoke_assignment_marker"
Write-Output "Name                           Value"
Write-Output "----                           -----"
Write-Output "SMOKE_ENV                      smoke_table_marker"
Write-Output "AWS_ACCESS_KEY_ID AKIA1234567890ABCDEF"
Write-Output "ConnectionString smoke_connection_marker"
Write-Output "unlabelledSmokeBearer0123456789abcdefghijklmnop"
throw "revealing failure"
}'
	$ClassName = 'FakeWsl' + [guid]::NewGuid().ToString('N')
	$Source = 'using System;using System.IO;using System.Web.Script.Serialization;public class CLASS{public static int Main(string[] args){File.AppendAllText(Environment.GetEnvironmentVariable("RUNNER_TEST_WSL_CAPTURE"),new JavaScriptSerializer().Serialize(args)+Environment.NewLine);bool path=Array.IndexOf(args,"wslpath")>=0;string output=Environment.GetEnvironmentVariable(path?"RUNNER_TEST_WSLPATH_OUTPUT":"RUNNER_TEST_HOSTNAME_OUTPUT");if(output!=null)Console.Write(output.Replace("\\n",Environment.NewLine));string code=Environment.GetEnvironmentVariable(path?"RUNNER_TEST_WSLPATH_EXIT":"RUNNER_TEST_HOSTNAME_EXIT");return String.IsNullOrEmpty(code)?0:Int32.Parse(code);}}'.Replace('CLASS', $ClassName)
	Add-Type -TypeDefinition $Source -ReferencedAssemblies System.Web.Extensions -OutputAssembly (Join-Path $Fixture.Bin 'wsl.exe') -OutputType ConsoleApplication
	Copy-Item -LiteralPath (Get-Command powershell.exe).Source -Destination (Join-Path $Fixture.Bin 'FakeAethelnDescendant.exe')
	Invoke-FixtureGit $Fixture @('add', '.')
	& git -C $Fixture.Repository -c user.name=test -c user.email=test@invalid commit --amend --no-edit -q
	$Fixture.Revision = Get-FixtureRevision $Fixture
	& git -C $Fixture.Repository -c user.name=test -c user.email=test@invalid commit --allow-empty -qm alternate
	$Fixture.AlternateRevision = Get-FixtureRevision $Fixture
	Invoke-FixtureGit $Fixture @('update-ref', 'HEAD', $Fixture.Revision)
	$env:RUNNER_TEST_REPOSITORY = $Fixture.Repository
	$env:RUNNER_TEST_ALT_REVISION = $Fixture.AlternateRevision
	$env:RUNNER_TEST_BUILD_CAPTURE = $Fixture.BuildCapture
	$env:RUNNER_TEST_PACKAGE_CAPTURE = $Fixture.PackageCapture
	$env:RUNNER_TEST_SMOKE_CAPTURE = $Fixture.SmokeCapture
	$env:RUNNER_TEST_WSL_CAPTURE = $Fixture.WslCapture
	$env:RUNNER_TEST_MUTATION = ''
	$env:RUNNER_TEST_FAIL_TARGET = ''
	$env:RUNNER_TEST_AMBIGUOUS = ''
	$env:RUNNER_TEST_INTERNAL = ''
	$env:RUNNER_TEST_SMOKE_FAIL = ''
	$env:RUNNER_TEST_SMOKE_HANG = ''
	$env:RUNNER_TEST_PHASE_SLEEP = ''
	$env:RUNNER_TEST_PHASE_FAIL = ''
	$env:RUNNER_TEST_PHASE_SPAWN = ''
	$env:RUNNER_TEST_KILL_FAULT = ''
	$env:RUNNER_TEST_HASH_BLOCK_SECONDS = ''
	$env:RUNNER_TEST_UBT_OUTPUT_AethelnOnlineClient = ''
	$env:RUNNER_TEST_UBT_OUTPUT_AethelnOnlineServer = ''
	$env:RUNNER_TEST_UBT_OUTPUT_PACKAGE = ''
	$env:RUNNER_TEST_DESCENDANT_EXE = Join-Path $Fixture.Bin 'FakeAethelnDescendant.exe'
	$env:AETHELN_HANDOFF_ROOT = $Fixture.Handoff
	Remove-Item Env:AETHELN_DDC_ROOT -ErrorAction Ignore
	Remove-Item Env:AETHELN_DDC_FALLBACK -ErrorAction Ignore
	# Packaging modes require an explicit host-tools selection; the fixture
	# default is the explicit operator-authorized rebuild.
	$env:AETHELN_HOST_TOOLS = 'rebuild-authorized'
	Remove-Item Env:AETHELN_ENGINE_REVISION -ErrorAction Ignore
	Remove-Item Env:AETHELN_HOST_TOOLS_ATTESTATION -ErrorAction Ignore
	$env:RUNNER_TEST_WSLPATH_OUTPUT = '/mnt/d/archive/LinuxServer/Linux/AethelnOnlineServer.sh'
	$env:RUNNER_TEST_HOSTNAME_OUTPUT = '172.25.32.7 '
	$env:RUNNER_TEST_WSLPATH_EXIT = '0'
	$env:RUNNER_TEST_HOSTNAME_EXIT = '0'
	$env:PATH = $Fixture.Bin + [IO.Path]::PathSeparator + $Original.PATH
	$env:AETHELN_ENGINE_ROOT = $Fixture.Engine
	$env:AETHELN_LINUX_TOOLCHAIN_ROOT = $Fixture.Toolchain
}
function Invoke-Gate($Fixture, [string] $Mode = 'Compile', [string] $Revision = $Fixture.Revision, [string[]] $ExtraArguments = @()) {
	$Previous = $ErrorActionPreference
	try {
		$ErrorActionPreference = 'Continue'
		$Output = @(& $PowerShell -NoProfile -File (Join-Path $Fixture.Repository 'scripts/ci/Invoke-EngineRunnerGate.ps1') -Mode $Mode -RepositoryRoot $Fixture.Repository -SourceRevision $Revision -ArchiveRoot $Fixture.Archive -LogRoot $Fixture.Logs @ExtraArguments 2>&1)
		$ExitCode = $LASTEXITCODE
	} finally { $ErrorActionPreference = $Previous }
	return @{ ExitCode = $ExitCode; Output = $Output -join "`n"; Report = Join-Path $Fixture.Repository 'TestResults/engine-runner-report.json' }
}
function Invoke-PhaseGate($Fixture, [string] $Mode, [string[]] $ExtraArguments = @(), [string] $RunId = '12345', [string] $RunnerName = 'fixture-runner', [string] $TimeoutMinutes = '5', [string] $Repository = 'owner/repo') {
	$Arguments = @('-Repository', $Repository, '-RunId', $RunId, '-RunAttempt', '1', '-RunnerName', $RunnerName, '-PhaseTimeoutMinutes', $TimeoutMinutes) + $ExtraArguments
	$Previous = $ErrorActionPreference
	try {
		$ErrorActionPreference = 'Continue'
		$Output = @(& $PowerShell -NoProfile -File (Join-Path $Fixture.Repository 'scripts/ci/Invoke-EngineRunnerGate.ps1') -Mode $Mode -RepositoryRoot $Fixture.Repository -SourceRevision $Fixture.Revision -LogRoot (Join-Path $Fixture.Root ('logs-' + [guid]::NewGuid().ToString('N'))) @Arguments 2>&1)
		$ExitCode = $LASTEXITCODE
	} finally { $ErrorActionPreference = $Previous }
	return @{ ExitCode = $ExitCode; Output = $Output -join "`n"; Report = Join-Path $Fixture.Repository 'TestResults/engine-runner-report.json' }
}
function Get-PhaseRunDirectory($Fixture) { return Join-Path $Fixture.Handoff 'owner\repo\run-12345-attempt-1' }
function Get-CleanupRequestRoot($Fixture) { return Join-Path $Fixture.Handoff 'owner\repo\cleanup-requests' }
function New-FixtureRunContext {
	[CmdletBinding(SupportsShouldProcess)]
	param($Fixture, [string] $Directory, [string] $ContextRunId, [string] $ContextRunAttempt, [string] $ContextRunnerName = 'fixture-runner')
	# Decide before the record is written: a declined call leaves the phase
	# directory without a run-context record.
	if (-not $PSCmdlet.ShouldProcess($Directory, 'Write a fixture run-context record')) { return }
	@{ schemaVersion = 1; repository = 'owner/repo'; sourceRevision = $Fixture.Revision; runId = $ContextRunId; runAttempt = $ContextRunAttempt; runnerName = $ContextRunnerName; createdUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Directory 'run-context.json') -Encoding UTF8
}
function Assert-ReportReason($Result, [string] $Reason, [string] $Message) {
	Assert-True ($Result.ExitCode -ne 0) "$Message (exit code)."
	Assert-True (@((Read-Report $Result).checks | Where-Object message -like ($Reason + '*')).Count -ge 1) "$Message (report must carry $Reason). Actual: $(@((Read-Report $Result).checks | ForEach-Object message) -join '; ')"
}
function Read-Report($Result) { Get-Content -LiteralPath $Result.Report -Raw | ConvertFrom-Json }
function New-Case {
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType([hashtable])]
	param([string] $Name)
	# Decide before the fixture exists: a declined case builds no tree and
	# installs no fake tooling.
	if (-not $PSCmdlet.ShouldProcess($Name, 'Create an isolated gate fixture case')) { return }
	$Fixture = New-Fixture $Name
	Install-FakeTool $Fixture
	return $Fixture
}
function Test-FixtureHelperGuard {
	# A declined fixture build must leave nothing behind: no fixture tree, no
	# fake tooling, and no run-context record. Ordinary construction is proved
	# by every case that follows.
	$DeclinedFixtureRoot = Join-Path $FixtureRoot 'whatif-declined-fixture'
	New-Fixture 'whatif-declined-fixture' -WhatIf | Out-Null
	Assert-True (-not (Test-Path -LiteralPath $DeclinedFixtureRoot)) 'A declined New-Fixture must create no fixture tree.'
	$DeclinedCaseRoot = Join-Path $FixtureRoot 'whatif-declined-case'
	New-Case 'whatif-declined-case' -WhatIf | Out-Null
	Assert-True (-not (Test-Path -LiteralPath $DeclinedCaseRoot)) 'A declined New-Case must create no fixture and install no fakes.'
	$DeclinedContextDirectory = Join-Path $FixtureRoot 'whatif-declined-context'
	New-Item -ItemType Directory -Force -Path $DeclinedContextDirectory | Out-Null
	New-FixtureRunContext -Fixture @{ Revision = ('0' * 40) } -Directory $DeclinedContextDirectory -ContextRunId 'run-1' -ContextRunAttempt '1' -WhatIf
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $DeclinedContextDirectory 'run-context.json'))) 'A declined New-FixtureRunContext must write no run-context record.'
	Write-Output 'PASS: declined fixture construction leaves no tree, fakes, or run-context record'
}
function Install-VerifiableIdentity($Fixture) {
	# Turns the fixture engine into a clean Git checkout with a Build.version
	# and gives the toolchain a clang binary, so the gate can record a
	# verified engine/toolchain identity. Cases that skip this helper exercise
	# the explicit unavailable states.
	$VersionPath = Join-Path $Fixture.Engine 'Engine/Build/Build.version'
	Write-Fixture $VersionPath '{"MajorVersion":5,"MinorVersion":8,"PatchVersion":1}'
	$CompilerPath = Join-Path $Fixture.Toolchain 'x86_64-unknown-linux-gnu/bin/clang++.exe'
	New-Item -ItemType Directory -Force -Path (Split-Path $CompilerPath) | Out-Null
	Write-Fixture $CompilerPath 'fixture-clang'
	& git -C $Fixture.Engine init -q
	& git -C $Fixture.Engine add . | Out-Null
	& git -C $Fixture.Engine -c user.name=test -c user.email=test@invalid commit -qm engine
	if ($LASTEXITCODE -ne 0) { throw 'engine fixture commit failed' }
	$Revision = (& git -C $Fixture.Engine rev-parse HEAD).Trim()
	Assert-True ($Revision -match '^[0-9a-f]{40}$') 'Engine fixture revision must be a full hash.'
	return @{
		Revision = $Revision
		BuildVersionSha256 = (Get-FileHash -LiteralPath $VersionPath -Algorithm SHA256).Hash.ToLowerInvariant()
		CompilerSha256 = (Get-FileHash -LiteralPath $CompilerPath -Algorithm SHA256).Hash.ToLowerInvariant()
	}
}
function Write-UbtOutput($Fixture, [string] $Name, [string[]] $Lines) {
	$Path = Join-Path $Fixture.Root ('ubt-' + $Name + '.txt')
	Set-Content -LiteralPath $Path -Value ($Lines -join "`r`n") -Encoding ASCII
	return $Path
}

try {
	Test-HandoffPrimitiveContract
	if ($HandoffContractsOnly) { return }
	New-Item -ItemType Directory -Path $FixtureRoot | Out-Null
	Test-FixtureHelperGuard

	$Fixture = New-Case 'compile-fresh-report'
	$FreshReport = Join-Path $Fixture.Root 'fresh-report.json'
	$UnicodeRunner = 'runner-' + [char]0x05e9 + [char]0x00e9
	$Result = Invoke-Gate $Fixture -ExtraArguments @('-ReportPath', $FreshReport, '-RunnerName', $UnicodeRunner)
	Assert-True ($Result.ExitCode -eq 0 -and (Test-Path -LiteralPath $FreshReport)) 'Compile must publish its report at the explicit fresh absolute path.'
	Assert-True (-not (Test-Path -LiteralPath $Result.Report)) 'Explicit report publication must not also write legacy evidence.'
	$FreshBytes = [IO.File]::ReadAllText($FreshReport)
	$Result = Invoke-Gate $Fixture -ExtraArguments @('-ReportPath', $FreshReport)
	Assert-True ($Result.ExitCode -ne 0 -and [IO.File]::ReadAllText($FreshReport) -ceq $FreshBytes) 'An existing explicit report must be rejected without changing its bytes.'
	$FreshObject = $FreshBytes | ConvertFrom-Json
	Assert-True ($FreshObject.runnerName -ceq $UnicodeRunner) 'Supervised report relay must preserve UTF-8 runner identity exactly.'
	Assert-True ($FreshObject.supervisor.childExitCode -eq 0 -and -not $FreshObject.supervisor.timedOut) 'Successful compile reports must retain the supervised child exit receipt.'

	foreach ($InvalidTimeout in @('0', '-1', '31', 'NaN', 'Infinity')) {
		$Fixture = New-Case ('compile-timeout-invalid-' + $InvalidTimeout)
		$Result = Invoke-Gate $Fixture -ExtraArguments @('-CompileTimeoutMinutes', $InvalidTimeout)
		Assert-True ($Result.ExitCode -ne 0 -and -not (Test-Path $Fixture.BuildCapture)) 'Nonfinite, nonpositive, and above-30-minute compile budgets must reject before build.'
	}
	# This uninstrumented probe tests the real whole-launch wall-clock bound.
	# It intentionally requires no particular preflight/build stage to be reached.
	$Fixture = New-Case 'compile-whole-launch-deadline'
	$CompileClock = [Diagnostics.Stopwatch]::StartNew()
	$Result = Invoke-Gate $Fixture -ExtraArguments @('-CompileTimeoutMinutes', '0.0001')
	$CompileClock.Stop()
	Assert-ReportReason -Result $Result -Reason 'compile_timeout' -Message 'An exhausted startup budget must fail under the real whole-launch watchdog'
	Assert-True ($CompileClock.Elapsed.TotalSeconds -lt 20) 'The whole launch and finalization must return within bounded cleanup time.'
	Assert-True (-not (Test-Path $Fixture.BuildCapture)) 'An exhausted startup budget must never start either build.'

	$Fixture = New-Fixture 'compile-shared-deadline'
	Install-CompileClockFixture $Fixture
	$Result = Invoke-Gate $Fixture -ExtraArguments @('-CompileTimeoutMinutes', '0.17')
	Assert-CompileClockFixture -Fixture $Fixture -Result $Result -ExpectedBuilds 2 -Stages @('009-client', '013-server')
	$Fixture = New-Fixture 'compile-cooperative-shared-deadline'
	Install-CompileClockFixture $Fixture -Cooperative
	$Result = Invoke-Gate $Fixture -ExtraArguments @('-CompileTimeoutMinutes', '0.17')
	Assert-CompileClockFixture -Fixture $Fixture -Result $Result -ExpectedBuilds 2 -Stages @('009-client', '011-server') -HardTimeout $false

	$Fixture = New-Fixture 'compile-blocked-diagnostics'
	Install-CompileClockFixture $Fixture -BlockDiagnostics
	$Result = Invoke-Gate $Fixture -ExtraArguments @('-CompileTimeoutMinutes', '0.17')
	Assert-CompileClockFixture -Fixture $Fixture -Result $Result -ExpectedBuilds 0 -Stages @('013-diagnostics')
	if ($CompileWatchdogOnly) { Write-Output 'PASS: compile fresh reports, finite shared deadline, and descendant supervision'; return }

	$Fixture = New-Case 'compile-success'
	$Result = Invoke-Gate $Fixture
	$Commands = @(Get-Content -LiteralPath $Fixture.BuildCapture)
	$Project = Join-Path $Fixture.Repository 'AethelnOnline.uproject'
	Assert-True ($Result.ExitCode -eq 0 -and $Commands.Count -eq 2) 'Compile must run exactly two targets.'
	Assert-True ($Commands[0] -eq "AethelnOnlineClient Win64 Development $Project -WaitMutex -NoHotReloadFromIDE") 'Client command vector must be exact.'
	Assert-True ($Commands[1] -eq "AethelnOnlineServer Linux Development $Project -WaitMutex -NoHotReloadFromIDE") 'Server command vector must be exact.'
	Assert-True (-not (Test-Path $Fixture.PackageCapture) -and -not (Test-Path $Fixture.SmokeCapture)) 'Compile must not package or smoke.'
	Assert-True (($Commands -join ' ') -notmatch '(?i)cook|package|archive|clean') 'Compile must remain incremental.'
	$Report = Read-Report $Result
	Assert-True ($Report.policy -eq 'incremental-target-compilation' -and @($Report.checks | Where-Object name -like '*repository-state*').Count -eq 4) 'Compile policy and repository checks must be reported.'
	Assert-True ($null -ne $Report.compileEvidence -and $Report.compileEvidence.identity.engineGitRevisionStatus -eq 'unavailable' -and $null -eq $Report.compileEvidence.identity.engineGitRevision -and $Report.compileEvidence.identity.engineBuildVersionSha256Status -eq 'unavailable' -and $Report.compileEvidence.identity.linuxToolchainCompilerSha256Status -eq 'unavailable') 'An engine root that is not a Git checkout must record explicit unavailable identity states, never fabricated values.'
	Assert-True (@($Report.compileEvidence.builds).Count -eq 2 -and @($Report.compileEvidence.builds | Where-Object { $_.actionCounterState -eq 'not_observed' -and $null -eq $_.lastObservedAction -and $_.makefileObservation -eq 'not_observed' -and -not $_.intermediateBuildDirectoryPresentBeforeRun }).Count -eq 2) 'Compile output without UBT summary lines must record not-observed counters, never zero work.'

	$Fixture = New-Case 'compile-evidence-success'
	$Identity = Install-VerifiableIdentity $Fixture
	$env:RUNNER_TEST_UBT_OUTPUT_AethelnOnlineClient = Write-UbtOutput -Fixture $Fixture -Name 'client' -Lines @(
		'Creating makefile for AethelnOnlineClient (no existing makefile)',
		'Using Parallel executor to run 5561 action(s)',
		'[1/5561][AethelnOnlineClient Win64 Development] Compile [x64] SharedPCH.Core.Cpp20.cpp',
		('[750/5561][AethelnOnlineClient Win64 Development] Compile [x64] ' + $Fixture.Engine + '\Engine\Source\SecretModule.cpp'),
		'[751/5561][UnrealEditor Win64 Development] Link [x64] UnrealEditor-Core.dll',
		'Total time in Parallel executor: 12.34 seconds')
	$env:RUNNER_TEST_UBT_OUTPUT_AethelnOnlineServer = Write-UbtOutput -Fixture $Fixture -Name 'server' -Lines @('Target is up to date', 'Total execution time: 1.02 seconds')
	$Result = Invoke-Gate $Fixture
	Assert-True ($Result.ExitCode -eq 0) "Compile with UBT summary output must pass. Output: $($Result.Output)"
	$Report = Read-Report $Result
	$Evidence = $Report.compileEvidence
	Assert-True ($Report.schemaVersion -eq 1 -and $Evidence.schemaVersion -eq 1 -and @($Report.checks | Where-Object name -like '*repository-state*').Count -eq 4 -and $Report.summary.total -eq $Report.checks.Count) 'Compile evidence must be additive: no new checks and the report schema version unchanged.'
	Assert-True ($Evidence.identity.engineGitRevision -eq $Identity.Revision -and $Evidence.identity.engineGitRevisionStatus -eq 'verified' -and $Evidence.identity.engineBuildVersionSha256 -eq $Identity.BuildVersionSha256 -and $Evidence.identity.engineBuildVersionSha256Status -eq 'verified' -and $Evidence.identity.linuxToolchainCompilerSha256 -eq $Identity.CompilerSha256 -and $Evidence.identity.linuxToolchainCompilerSha256Status -eq 'verified' -and $null -eq $Evidence.identity.runnerName) 'A clean engine checkout and present compiler must be recorded as verified content identities.'
	Assert-True ($Evidence.identity.durationSeconds -is [double] -or $Evidence.identity.durationSeconds -is [int] -or $Evidence.identity.durationSeconds -is [long] -or $Evidence.identity.durationSeconds -is [decimal]) 'Identity resolution must expose its own bounded duration.'
	$Builds = @($Evidence.builds)
	Assert-True ($Builds.Count -eq 2 -and $Builds[0].check -eq 'incremental-client-build' -and $Builds[0].target -eq 'AethelnOnlineClient' -and $Builds[0].platform -eq 'Win64' -and $Builds[0].configuration -eq 'Development' -and $Builds[1].check -eq 'incremental-server-build' -and $Builds[1].target -eq 'AethelnOnlineServer' -and $Builds[1].platform -eq 'Linux') 'Compile evidence must carry one identity-labelled entry per target in run order.'
	Assert-True ($Builds[0].outputState -eq 'captured' -and $Builds[0].actionCounterState -eq 'observed' -and $Builds[0].lastObservedAction -eq 751 -and $Builds[0].observedTotalActions -eq 5561 -and $Builds[0].plannedActionCount -eq 5561 -and $Builds[0].executorSummaryCount -eq 1) 'The last observed UBT action counter and planned action count must be extracted exactly.'
	Assert-True ($Builds[0].makefileObservation -eq 'created' -and $Builds[0].makefileReason -eq 'no_existing_makefile' -and $Builds[0].makefileCreationCount -eq 1 -and -not $Builds[0].upToDateObserved) 'An observed makefile creation must be recorded with its allowlisted normalized reason.'
	Assert-True ($Builds[0].observedTargetNames -eq 'AethelnOnlineClient,UnrealEditor') 'Observed UBT target names must be recorded from the closed allowlist only.'
	Assert-True (-not $Builds[0].intermediateBuildDirectoryPresentBeforeRun -and -not $Builds[0].makefilePresentBeforeRun) 'Absent intermediates must be recorded as absent before the run.'
	Assert-True ($Builds[1].upToDateObserved -and $Builds[1].actionCounterState -eq 'not_observed' -and $null -eq $Builds[1].lastObservedAction -and $null -eq $Builds[1].observedTotalActions -and $null -eq $Builds[1].plannedActionCount -and $Builds[1].makefileObservation -eq 'not_observed' -and $null -eq $Builds[1].makefileReason -and $null -eq $Builds[1].observedTargetNames) 'An up-to-date target must be recorded as observed up to date with no fabricated counters.'
	$ReportRaw = Get-Content $Result.Report -Raw
	foreach ($Value in @($Fixture.Engine, $Fixture.Toolchain, 'SecretModule', 'SharedPCH', 'UnrealEditor-Core.dll', 'no existing makefile', 'Parallel executor')) { Assert-True (-not $ReportRaw.Contains($Value)) "Compile evidence must not carry raw captured text or paths ($Value)." }

	$Fixture = New-Case 'compile-evidence-build-failure'
	$env:RUNNER_TEST_FAIL_TARGET = 'AethelnOnlineClient'
	$env:RUNNER_TEST_UBT_OUTPUT_AethelnOnlineClient = Write-UbtOutput -Fixture $Fixture -Name 'client' -Lines @('Creating makefile for AethelnOnlineClient (working set of source files changed)', '[120/5561] Compile [x64] Failing.cpp')
	$Result = Invoke-Gate $Fixture
	$Report = Read-Report $Result
	$Builds = @($Report.compileEvidence.builds)
	Assert-True ($Result.ExitCode -ne 0 -and @($Report.checks | Where-Object name -eq 'incremental-client-build')[0].status -eq 'failed') 'The failing client build must still fail the gate.'
	Assert-True ($Builds.Count -eq 1 -and $Builds[0].check -eq 'incremental-client-build' -and $Builds[0].outputState -eq 'captured' -and $Builds[0].lastObservedAction -eq 120 -and $Builds[0].observedTotalActions -eq 5561 -and $Builds[0].makefileObservation -eq 'created' -and $Builds[0].makefileReason -eq 'working_set_changed') 'An ordinary build failure must preserve the bounded compile observations in the finalized report.'
	Assert-True (-not (Get-Content $Result.Report -Raw).Contains('Failing.cpp')) 'Failure evidence must stay path-free and text-free.'
	$env:RUNNER_TEST_FAIL_TARGET = ''

	$Fixture = New-Case 'compile-evidence-malformed'
	$env:RUNNER_TEST_UBT_OUTPUT_AethelnOnlineClient = Write-UbtOutput -Fixture $Fixture -Name 'client' -Lines @(
		'[abc/12] Compile [x64] A.cpp',
		'[5/] Compile [x64] B.cpp',
		'[9/3] Compile [x64] C.cpp',
		'[12345678/99999999] Compile [x64] D.cpp',
		'[0/10] Compile [x64] E.cpp',
		('Creating makefile for AethelnOnlineClient (manifest ''' + $Fixture.Engine + '\Manifest.xml'' not found)'),
		'Using Parallel executor to run many action(s)')
	$env:RUNNER_TEST_UBT_OUTPUT_AethelnOnlineServer = Write-UbtOutput -Fixture $Fixture -Name 'server' -Lines @('[3/10] Compile A.cpp', '[7/10] Compile B.cpp', '[2/10] Compile C.cpp', 'Total time in Parallel executor: 1.00 seconds', 'Total time in Parallel executor: 2.00 seconds')
	$Result = Invoke-Gate $Fixture
	Assert-True ($Result.ExitCode -eq 0) "Malformed summary lines must never fail the gate. Output: $($Result.Output)"
	$Builds = @((Read-Report $Result).compileEvidence.builds)
	Assert-True ($Builds[0].actionCounterState -eq 'not_observed' -and $null -eq $Builds[0].lastObservedAction -and $null -eq $Builds[0].observedTotalActions -and $null -eq $Builds[0].plannedActionCount) 'Malformed, out-of-range, and oversized action counters must be ignored, not coerced.'
	Assert-True ($Builds[0].makefileObservation -eq 'created' -and $Builds[0].makefileReason -eq 'other' -and $Builds[0].makefileCreationCount -eq 1) 'An unknown makefile reason must be recorded as other, never as raw text.'
	Assert-True ($Builds[1].actionCounterState -eq 'observed' -and $Builds[1].lastObservedAction -eq 2 -and $Builds[1].observedTotalActions -eq 10 -and $Builds[1].executorSummaryCount -eq 2) 'The recorded counter is the last one observed in output order, and repeated executor summaries are counted.'
	Assert-True (-not (Get-Content $Result.Report -Raw).Contains('Manifest.xml')) 'Raw makefile reasons carrying paths must never reach the report.'

	$Fixture = New-Case 'compile-evidence-invalid-counter-targets'
	$env:RUNNER_TEST_UBT_OUTPUT_AethelnOnlineClient = Write-UbtOutput -Fixture $Fixture -Name 'client' -Lines @(
		'[9/3][AethelnOnlineClient Win64 Development] Compile [x64] X.cpp',
		'[0/10][UnrealPak Win64 Development] Compile [x64] Y.cpp')
	$env:RUNNER_TEST_UBT_OUTPUT_AethelnOnlineServer = Write-UbtOutput -Fixture $Fixture -Name 'server' -Lines @(
		'[3/10][AethelnOnlineServer Linux Development] Compile [x86_64] A.cpp',
		'[12/10][AethelnOnlineEditor Win64 Development] Compile [x64] B.cpp',
		'[0/10][UnrealPak Win64 Development] Compile [x64] C.cpp')
	$Result = Invoke-Gate $Fixture
	Assert-True ($Result.ExitCode -eq 0) "Invalid counters carrying target metadata must never fail the gate. Output: $($Result.Output)"
	$Builds = @((Read-Report $Result).compileEvidence.builds)
	Assert-True ($Builds[0].actionCounterState -eq 'not_observed' -and $null -eq $Builds[0].lastObservedAction -and $null -eq $Builds[0].observedTotalActions -and $null -eq $Builds[0].observedTargetNames) 'Out-of-range and zero counters must contribute neither counter nor target observations, even with allowlisted target metadata.'
	Assert-True ($Builds[1].actionCounterState -eq 'observed' -and $Builds[1].lastObservedAction -eq 3 -and $Builds[1].observedTotalActions -eq 10 -and $Builds[1].observedTargetNames -eq 'AethelnOnlineServer') 'Later invalid counter lines must neither add their target names nor erase the previously valid counter and target observations.'

	$Fixture = New-Case 'compile-evidence-explicit-zero-plan'
	# UnrealBuildTool runs the executor with an empty action list (cleanup
	# only) and logs the observed count, so an explicit zero is a real
	# observation and must be preserved as 0. Absence stays null (see the
	# up-to-date server above) and malformed summaries stay null, never 0.
	$env:RUNNER_TEST_UBT_OUTPUT_AethelnOnlineClient = Write-UbtOutput -Fixture $Fixture -Name 'client' -Lines @(
		'[0/10][UnrealPak Win64 Development] Compile [x64] Y.cpp',
		'Using Parallel executor to run 0 action(s)',
		'Total time in Parallel executor: 0.01 seconds')
	$env:RUNNER_TEST_UBT_OUTPUT_AethelnOnlineServer = Write-UbtOutput -Fixture $Fixture -Name 'server' -Lines @(
		'Using Parallel executor to run -0 action(s)',
		'Using Parallel executor to run 0 actions',
		'Using Parallel executor to run 0 action(s) trailing')
	$Result = Invoke-Gate $Fixture
	Assert-True ($Result.ExitCode -eq 0) "An explicit zero planned action count must never fail the gate. Output: $($Result.Output)"
	$Builds = @((Read-Report $Result).compileEvidence.builds)
	Assert-True ($null -ne $Builds[0].plannedActionCount -and $Builds[0].plannedActionCount -eq 0 -and $Builds[0].executorSummaryCount -eq 1) 'An explicitly observed executor plan of zero actions must be recorded as 0, not discarded as absent.'
	Assert-True ($Builds[0].actionCounterState -eq 'not_observed' -and $null -eq $Builds[0].lastObservedAction -and $null -eq $Builds[0].observedTotalActions -and $null -eq $Builds[0].observedTargetNames) 'A zero progress counter stays invalid and independent of the planned count: it contributes neither counters nor target names.'
	Assert-True ($null -eq $Builds[1].plannedActionCount -and $Builds[1].executorSummaryCount -eq 0) 'Malformed executor summaries must leave the planned action count null, never coerced to zero.'
	Assert-True (-not (Get-Content $Result.Report -Raw).Contains('Parallel executor')) 'Explicit-zero evidence must stay text-free.'

	$Fixture = New-Case 'compile-evidence-intermediates-present'
	New-Item -ItemType Directory -Force -Path (Join-Path $Fixture.Repository 'Intermediate/Build/Win64/x64/AethelnOnlineClient/Development'), (Join-Path $Fixture.Repository 'Intermediate/Build/Linux') | Out-Null
	Write-Fixture (Join-Path $Fixture.Repository 'Intermediate/Build/Win64/x64/AethelnOnlineClient/Development/Makefile.bin') 'stale'
	$Result = Invoke-Gate $Fixture
	Assert-True ($Result.ExitCode -eq 0) "Pre-existing ignored intermediates must not fail the gate. Output: $($Result.Output)"
	$Builds = @((Read-Report $Result).compileEvidence.builds)
	Assert-True ($Builds[0].intermediateBuildDirectoryPresentBeforeRun -and $Builds[0].makefilePresentBeforeRun -and $Builds[0].actionCounterState -eq 'not_observed' -and $Builds[0].makefileObservation -eq 'not_observed') 'Present intermediates and a present makefile must be recorded as presence only; without UBT observations reuse stays unproven.'
	Assert-True ($Builds[1].intermediateBuildDirectoryPresentBeforeRun -and -not $Builds[1].makefilePresentBeforeRun) 'A platform intermediate directory without the target makefile must be distinguished from a present makefile.'

	$Fixture = New-Case 'ignored-output'
	$env:RUNNER_TEST_MUTATION = 'ignored'
	$Result = Invoke-Gate $Fixture
	Assert-True ($Result.ExitCode -eq 0 -and (Test-Path (Join-Path $Fixture.Repository 'Intermediate/x'))) 'Ignored output must not be treated as drift.'

	foreach ($Case in @(
		@{ Name='initial-dirty'; Kind='initial-dirty'; Reason='repository_drift_detected' },
		@{ Name='wrong-revision'; Kind='wrong'; Reason='revision_changed' },
		@{ Name='post-build-dirty'; Kind='dirty'; Reason='repository_drift_detected' },
		@{ Name='post-build-revision'; Kind='revision'; Reason='revision_changed' }
	)) {
		$Fixture = New-Case $Case.Name
		if ($Case.Kind -eq 'initial-dirty') { Write-Fixture (Join-Path $Fixture.Repository 'tracked') 'changed'; $Result = Invoke-Gate $Fixture }
		elseif ($Case.Kind -eq 'wrong') { $Result = Invoke-Gate -Fixture $Fixture -Mode 'Compile' -Revision ('2' * 40) }
		else { $env:RUNNER_TEST_MUTATION = $Case.Kind; $Result = Invoke-Gate $Fixture }
		Assert-True ($Result.ExitCode -ne 0) "$($Case.Name) must fail."
		Assert-True (@((Read-Report $Result).checks | Where-Object message -eq $Case.Reason).Count -eq 1) "$($Case.Name) must report its stable reason."
		if ($Case.Name -like 'post-build-*') { Assert-True (@(Get-Content $Fixture.BuildCapture).Count -eq 1) 'Repository failure must stop the server target.' }
	}

	$Fixture = New-Case 'client-build-failure'
	$env:RUNNER_TEST_FAIL_TARGET = 'AethelnOnlineClient'
	$Result = Invoke-Gate $Fixture
	Assert-True ($Result.ExitCode -ne 0 -and @(Get-Content $Fixture.BuildCapture).Count -eq 1) 'Client failure must stop before server build.'

	$Fixture = New-Case 'server-build-failure'
	$env:RUNNER_TEST_FAIL_TARGET = 'AethelnOnlineServer'
	$Result = Invoke-Gate $Fixture
	$Commands = @(Get-Content $Fixture.BuildCapture)
	$Report = Read-Report $Result
	Assert-True ($Result.ExitCode -ne 0 -and $Commands.Count -eq 2) 'Server failure must occur only after the successful client target.'
	Assert-True (@($Report.checks | Where-Object name -eq 'incremental-client-build')[0].status -eq 'passed') 'Client target must be recorded passed before server failure.'
	Assert-True (@($Report.checks | Where-Object name -eq 'incremental-server-build')[0].status -eq 'failed') 'Server target must record the failure.'
	$BuildMessage = [string] @($Report.checks | Where-Object name -eq 'incremental-server-build')[0].message
	$Disclosure = $Result.Output + (Get-Content $Result.Report -Raw)
	Assert-True ($BuildMessage -match 'build_failed' -and $BuildMessage -match 'C1234' -and $BuildMessage -match 'actionable build diagnostic' -and $BuildMessage.Length -le 4120) 'Build diagnostic must remain bounded and actionable.'
	foreach ($Value in @($Fixture.Engine,$Fixture.Toolchain,'ghp_build_marker','build_assignment_marker','build_table_marker','AKIA1234567890ABCDEF','build_connection_marker','unlabelledBearerValue','build_password_marker','build_client_secret_marker')) { Assert-True (-not $Disclosure.Contains($Value)) "Build disclosure must redact $Value." }
	Assert-True ($Result.Output -notmatch 'C1234') 'Captured build diagnostics must not reach console output.'

	$Fixture = New-Case 'packaged-smoke-success'
	$Result = Invoke-Gate $Fixture 'PackagedSmoke'
	$Report = Read-Report $Result
	$PackageCalls = @(Get-Content $Fixture.PackageCapture | ForEach-Object { $_ | ConvertFrom-Json })
	$WslCalls = @(Get-Content $Fixture.WslCapture | ForEach-Object { $_ | ConvertFrom-Json })
	$Smoke = Get-Content $Fixture.SmokeCapture -Raw | ConvertFrom-Json
	Assert-True ($Result.ExitCode -eq 0 -and $PackageCalls.Count -eq 1 -and -not (Test-Path $Fixture.BuildCapture)) 'Packaged smoke must package exactly once without Build.bat.'
	Assert-True ($PackageCalls[0].ArchiveRoot -eq $Fixture.Archive -and $PackageCalls[0].Configuration -eq 'Development' -and $PackageCalls[0].Map -eq '/Game/Maps/StarterMap') 'Packaging must use the supplied archive and frozen configuration/map.'
	Assert-True ($WslCalls.Count -eq 2) 'Exactly two WSL calls are required.'
	$ExpectedServerWindowsPath = Join-Path $Fixture.Archive 'l/AethelnOnlineServer.sh'
	Assert-True (($WslCalls[0] -join '|') -eq "-d|Ubuntu|-u|aethelnqa|--|wslpath|$ExpectedServerWindowsPath") 'wslpath command vector must be exact.'
	Assert-True (($WslCalls[1] -join '|') -eq '-d|Ubuntu|-u|aethelnqa|--|hostname|-I') 'hostname command vector must be exact.'
	Assert-True ($Smoke.ServerExecutable -eq '/mnt/d/archive/LinuxServer/Linux/AethelnOnlineServer.sh' -and $Smoke.ServerLauncherExecutable -eq 'wsl.exe') 'Smoke launcher executable contract must be exact.'
	Assert-True (($Smoke.ServerLauncherArguments -join '|') -eq '-d|Ubuntu|-u|aethelnqa|--exec|{ServerExecutable}|{ServerMap}|-port=7777|-stdout|-FullStdOutLogOutput') 'Server launcher arguments must be exact.'
	Assert-True (($Smoke.ClientBaseArguments -join '|') -eq '{ServerEndpoint}|-stdout|-FullStdOutLogOutput') 'Client arguments must be exact.'
	Assert-True ($Smoke.ClientExecutable -eq (Join-Path $Fixture.Archive 'w/AethelnOnlineClient.exe') -and $Smoke.ServerEndpoint -eq '172.25.32.7:7777') 'Smoke must use the same archive and discovered endpoint.'
	Assert-True ($Smoke.ServerMap -eq '/Game/Maps/StarterMap' -and $Smoke.LogRoot -eq (Join-Path $Fixture.Logs 'packaged-smoke')) 'Smoke map and log root must be exact.'
	Assert-True ($Smoke.ServerReadyPattern -eq 'GameNetDriver.*Listening') 'Server readiness pattern must be exact.'
	Assert-True ($Smoke.ServerClientConnectedPattern -eq 'AddClientConnection:.*RemoteAddr: (?<ConnectionId>[^,]+)') 'Server connection pattern must be exact.'
	Assert-True ($Smoke.ClientConnectedPattern -eq 'Welcomed by server' -and $Smoke.ClientMapPattern -eq 'LoadMap:.*StarterMap') 'Client connection and map patterns must be exact.'
	Assert-True ($Smoke.TimeoutSeconds -eq 120) 'Smoke timeout must remain 120 seconds.'
	Assert-True ($Report.policy -eq 'clean-package-and-smoke') 'Packaged smoke policy must be reported.'

	foreach ($Case in @(
		@{ Name='wslpath-nonzero'; Variable='RUNNER_TEST_WSLPATH_EXIT'; Value='9'; Reason='wslpath_exit_nonzero' },
		@{ Name='wslpath-empty'; Variable='RUNNER_TEST_WSLPATH_OUTPUT'; Value=''; Reason='wslpath_line_count_invalid' },
		@{ Name='wslpath-multiline'; Variable='RUNNER_TEST_WSLPATH_OUTPUT'; Value='/one\n/two'; Reason='wslpath_line_count_invalid' },
		@{ Name='wslpath-relative'; Variable='RUNNER_TEST_WSLPATH_OUTPUT'; Value='relative'; Reason='wslpath_result_invalid' },
		@{ Name='hostname-nonzero'; Variable='RUNNER_TEST_HOSTNAME_EXIT'; Value='9'; Reason='wsl_address_exit_nonzero' },
		@{ Name='hostname-empty'; Variable='RUNNER_TEST_HOSTNAME_OUTPUT'; Value=''; Reason='wsl_address_invalid' },
		@{ Name='hostname-invalid'; Variable='RUNNER_TEST_HOSTNAME_OUTPUT'; Value='not-an-address 2001:db8::1'; Reason='wsl_address_invalid' }
	)) {
		$Fixture = New-Case $Case.Name
		Set-Item -LiteralPath ('Env:' + $Case.Variable) -Value $Case.Value
		$Result = Invoke-Gate $Fixture 'PackagedSmoke'
		Assert-True ($Result.ExitCode -ne 0 -and -not (Test-Path $Fixture.SmokeCapture)) "$($Case.Name) must fail before smoke."
		Assert-True (@((Read-Report $Result).checks | Where-Object message -like ($Case.Reason + '*')).Count -eq 1) "$($Case.Name) must report $($Case.Reason)."
	}

	foreach ($Kind in @('client','server')) {
		$Fixture = New-Case ('ambiguous-' + $Kind)
		$env:RUNNER_TEST_AMBIGUOUS = $Kind
		$Result = Invoke-Gate $Fixture 'PackagedSmoke'
		Assert-True ($Result.ExitCode -ne 0 -and -not (Test-Path $Fixture.SmokeCapture)) "Ambiguous $Kind archive must fail before smoke."
		Assert-True (@((Read-Report $Result).checks | Where-Object message -like ($Kind + '_discovery_invalid*')).Count -eq 1) "Ambiguous $Kind must report its reason."
	}

	foreach ($Kind in @('missing','mismatch')) {
		$Fixture = New-Case ('internal-' + $Kind)
		$env:RUNNER_TEST_INTERNAL = $Kind
		$Result = Invoke-Gate $Fixture 'PackagedSmoke'
		Assert-True ($Result.ExitCode -ne 0 -and -not (Test-Path $Fixture.SmokeCapture)) "A $Kind internal client binary must fail before smoke."
		Assert-True (@((Read-Report $Result).checks | Where-Object message -like 'client_discovery_invalid*').Count -eq 1) "A $Kind internal client binary must report client_discovery_invalid."
	}

	foreach ($Variable in @('AETHELN_ENGINE_ROOT','AETHELN_LINUX_TOOLCHAIN_ROOT')) {
		$Fixture = New-Case ('missing-' + $Variable)
		Set-Item -LiteralPath ('Env:' + $Variable) -Value $null
		$Result = Invoke-Gate $Fixture
		Assert-True ($Result.ExitCode -ne 0 -and (Test-Path $Result.Report)) "$Variable must be required and reported."
		$Expected = if ($Variable -eq 'AETHELN_ENGINE_ROOT') { 'engine_root_invalid' } else { 'toolchain_root_invalid' }
		Assert-True (@((Read-Report $Result).checks | Where-Object message -eq $Expected).Count -eq 1) "$Variable must use its safe reason."
	}
	$Fixture = New-Case 'nonexistent-engine-root'
	$env:AETHELN_ENGINE_ROOT = Join-Path $Fixture.Root 'absent-private-root'
	$Result = Invoke-Gate $Fixture
	Assert-True ($Result.ExitCode -ne 0 -and $Result.Output -match 'engine_root_invalid' -and $Result.Output -notmatch 'absent-private-root') 'Nonexistent engine root must fail without path disclosure.'

	$Fixture = New-Case 'report-schema'
	$Result = Invoke-Gate $Fixture
	$Report = Read-Report $Result
	foreach ($Property in @('schemaVersion','mode','policy','revision','startedUtc','finishedUtc','checks','summary')) { Assert-True ($null -ne $Report.$Property) "Report property $Property must exist." }
	Assert-True ($Report.schemaVersion -eq 1 -and $Report.mode -eq 'Compile' -and $Report.revision -eq $Fixture.Revision) 'Report identity must be exact.'
	foreach ($Check in $Report.checks) { foreach ($Property in @('name','tier','status','durationSeconds','command','message')) { Assert-True ($null -ne $Check.$Property) "Check property $Property must exist." }; Assert-True ($Check.tier -eq 'required') 'Every runner check must be required.' }
	foreach ($Property in @('total','passed','failed','skipped','requiredFailed')) { Assert-True ($null -ne $Report.summary.$Property) "Summary property $Property must exist." }
	Assert-True ($Report.summary.total -eq $Report.checks.Count -and $Report.summary.passed -eq $Report.checks.Count -and $Report.summary.failed -eq 0 -and $Report.summary.skipped -eq 0 -and $Report.summary.requiredFailed -eq 0) 'Successful report summary must be complete and consistent.'

	$Fixture = New-Case 'smoke-failure'
	$env:RUNNER_TEST_SMOKE_FAIL = '1'
	$Result = Invoke-Gate $Fixture 'PackagedSmoke'
	$Report = Read-Report $Result
	$SmokeMessage = [string] @($Report.checks | Where-Object name -eq 'packaged-build-smoke')[0].message
	$Disclosure = $Result.Output + (Get-Content $Result.Report -Raw)
	Assert-True ($Result.ExitCode -ne 0 -and $Report.summary.requiredFailed -eq 1 -and $SmokeMessage -match 'smoke_failed' -and $SmokeMessage -match 'NET001' -and $SmokeMessage -match 'actionable timeout diagnostic' -and $SmokeMessage.Length -le 4120) 'Smoke failure must produce bounded actionable required-failure semantics.'
	foreach ($Value in @($Fixture.Engine,$Fixture.Toolchain,'/mnt/d/archive/LinuxServer/Linux/AethelnOnlineServer.sh','smoke_bearer_marker','smoke_assignment_marker','smoke_table_marker','AKIA1234567890ABCDEF','smoke_connection_marker','unlabelledSmokeBearer')) { Assert-True (-not $Disclosure.Contains($Value)) "Smoke disclosure must redact $Value." }
	Assert-True ($Result.Output -notmatch 'NET001') 'Captured smoke diagnostics must not reach console output.'

	$Fixture = New-Case 'phase-root-unset'
	Remove-Item Env:AETHELN_HANDOFF_ROOT -ErrorAction Ignore
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-ReportReason -Result $Result -Reason 'handoff_root_unset' -Message 'An unset handoff root must fail only the phase job with its stable code'
	Assert-True (-not (Test-Path $Fixture.PackageCapture)) 'An unset handoff root must fail before any packaging work.'

	$Fixture = New-Case 'phase-root-inside-repository'
	$InsideRoot = Join-Path $Fixture.Repository 'handoff-inside'
	New-Item -ItemType Directory -Path $InsideRoot | Out-Null
	$env:AETHELN_HANDOFF_ROOT = $InsideRoot
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-ReportReason -Result $Result -Reason 'handoff_root_invalid' -Message 'A handoff root inside the repository must be rejected'

	$Fixture = New-Case 'phase-context-invalid'
	$Result = Invoke-PhaseGate -Fixture $Fixture -Mode 'PackageClient' -ExtraArguments @() -RunId 'abc'
	Assert-ReportReason -Result $Result -Reason 'handoff_context_invalid' -Message 'A non-numeric run id must be rejected'

	$Fixture = New-Case 'phase-milestone-success'
	$RunDirectory = Get-PhaseRunDirectory $Fixture
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-True ($Result.ExitCode -eq 0) "PackageClient must pass. Output: $($Result.Output)"
	$PackageCalls = @(Get-Content $Fixture.PackageCapture | ForEach-Object { $_ | ConvertFrom-Json })
	Assert-True ($PackageCalls.Count -eq 1 -and $PackageCalls[0].Stage -eq 'Client' -and $PackageCalls[0].ArchiveRoot -eq (Join-Path $RunDirectory 'client')) 'PackageClient must run the Client stage into the run-scoped handoff payload directory.'
	$ClientManifest = Get-Content (Join-Path $RunDirectory 'manifest-client.json') -Raw | ConvertFrom-Json
	Assert-True ($ClientManifest.schemaVersion -eq 1 -and $ClientManifest.repository -eq 'owner/repo' -and $ClientManifest.runId -eq '12345' -and $ClientManifest.runAttempt -eq '1' -and $ClientManifest.runnerName -eq 'fixture-runner' -and $ClientManifest.sourceRevision -eq $Fixture.Revision) 'The client integrity manifest must bind the exact producing context.'
	Assert-True (@($ClientManifest.files).Count -eq 3 -and $ClientManifest.producingPhase -eq 'client' -and (@($ClientManifest.expectedConsumingPhases) -contains 'smoke')) 'The client integrity manifest must inventory the payload and its consumers.'
	foreach ($Entry in @($ClientManifest.files)) { Assert-True ($Entry.sha256 -cmatch '^[0-9a-f]{64}$' -and [long] $Entry.bytes -gt 0) 'Every manifest entry must carry a lowercase SHA-256 digest and byte size.' }
	$RunContext = Get-Content (Join-Path $RunDirectory 'run-context.json') -Raw | ConvertFrom-Json
	Assert-True ($RunContext.schemaVersion -eq 1 -and $RunContext.repository -eq 'owner/repo' -and $RunContext.runId -eq '12345' -and $RunContext.runAttempt -eq '1' -and $RunContext.runnerName -eq 'fixture-runner' -and $RunContext.sourceRevision -eq $Fixture.Revision) 'PackageClient must atomically bind the run directory to its closed run-context record.'
	Assert-True (@(Get-ChildItem (Get-CleanupRequestRoot $Fixture) -File).Count -eq 1) 'PackageClient must write exactly one cleanup-request record.'
	$PhaseBuilds = @((Read-Report $Result).compileEvidence.builds)
	Assert-True ($PhaseBuilds.Count -eq 1 -and $PhaseBuilds[0].check -eq 'scheduled-client-package' -and $PhaseBuilds[0].target -eq 'AethelnOnlineClient' -and $PhaseBuilds[0].platform -eq 'Win64' -and $PhaseBuilds[0].outputState -eq 'captured' -and $PhaseBuilds[0].actionCounterState -eq 'not_observed') 'A packaging phase without UBT summary lines must record a captured but not-observed entry.'
	Assert-True ((Read-Report $Result).compileEvidence.identity.runnerName -eq 'fixture-runner') 'Phase compile evidence must carry the validated runner identity.'
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-ReportReason -Result $Result -Reason 'handoff_conflict' -Message 'A repeated PackageClient for the same run attempt must not overwrite or reuse the run directory'
	$env:RUNNER_TEST_UBT_OUTPUT_PACKAGE = Write-UbtOutput -Fixture $Fixture -Name 'package' -Lines @('UATHelper: Creating makefile for AethelnOnlineServer (command line arguments changed)', 'UATHelper: [4000/5561][AethelnOnlineServer Linux Development] Compile [x86_64] Server.cpp', 'UATHelper: [4001/5561][AethelnOnlineEditor Win64 Development] Compile [x64] Editor.cpp')
	$Result = Invoke-PhaseGate $Fixture 'PackageServer'
	$env:RUNNER_TEST_UBT_OUTPUT_PACKAGE = ''
	Assert-True ($Result.ExitCode -eq 0) "PackageServer must pass. Output: $($Result.Output)"
	Assert-True (Test-Path (Join-Path $RunDirectory 'manifest-server.json')) 'PackageServer must publish its integrity manifest.'
	$PhaseBuilds = @((Read-Report $Result).compileEvidence.builds)
	Assert-True ($PhaseBuilds.Count -eq 1 -and $PhaseBuilds[0].check -eq 'scheduled-server-package' -and $PhaseBuilds[0].target -eq 'AethelnOnlineServer' -and $PhaseBuilds[0].platform -eq 'Linux' -and $PhaseBuilds[0].lastObservedAction -eq 4001 -and $PhaseBuilds[0].observedTotalActions -eq 5561 -and $PhaseBuilds[0].makefileReason -eq 'command_line_changed' -and $PhaseBuilds[0].observedTargetNames -eq 'AethelnOnlineEditor,AethelnOnlineServer') 'Prefixed UBT lines captured through the packaging child must yield the same bounded observations.'
	Assert-True (-not (Get-Content $Result.Report -Raw).Contains('Server.cpp')) 'Packaging compile evidence must stay text-free.'
	$Result = Invoke-PhaseGate $Fixture 'ValidateProvenance'
	Assert-True ($Result.ExitCode -eq 0) "ValidateProvenance must pass. Output: $($Result.Output)"
	$Report = Read-Report $Result
	foreach ($Name in @('handoff-consume-client', 'handoff-consume-server', 'registry-provenance-validation', 'handoff-publish-provenance')) {
		Assert-True (@($Report.checks | Where-Object { $_.name -eq $Name -and $_.status -eq 'passed' }).Count -eq 1) "ValidateProvenance must record a passed $Name check."
	}
	$ProvenanceCall = @(Get-Content $Fixture.PackageCapture | ForEach-Object { $_ | ConvertFrom-Json })[-1]
	Assert-True ($ProvenanceCall.Stage -eq 'Provenance' -and $ProvenanceCall.ClientStageRoot -eq (Join-Path $RunDirectory 'client') -and $ProvenanceCall.ServerStageRoot -eq (Join-Path $RunDirectory 'server')) 'ValidateProvenance must consume the exact verified stage payload directories.'
	$Result = Invoke-PhaseGate $Fixture 'SmokePhase'
	Assert-True ($Result.ExitCode -eq 0) "SmokePhase must pass. Output: $($Result.Output)"
	$Smoke = Get-Content $Fixture.SmokeCapture -Raw | ConvertFrom-Json
	Assert-True ($Smoke.ClientExecutable -eq (Join-Path $RunDirectory 'client\WindowsClient\AethelnOnlineClient.exe')) 'SmokePhase must run the packaged client from the verified handoff payload.'
	$Report = Read-Report $Result
	Assert-True (@($Report.checks | Where-Object { $_.name -like 'handoff-consume-*' -and $_.status -eq 'passed' }).Count -eq 3) 'SmokePhase must verify every producing phase manifest before use.'
	$Marker = Get-Content (Join-Path $RunDirectory 'milestone-complete.json') -Raw | ConvertFrom-Json
	Assert-True ($Marker.state -eq 'passed' -and $Marker.repository -eq 'owner/repo' -and $Marker.runId -eq '12345' -and $Marker.runnerName -eq 'fixture-runner' -and $Marker.sourceRevision -eq $Fixture.Revision) 'SmokePhase must record a context-bound terminal completion marker.'
	Assert-True (@(Get-ChildItem (Get-CleanupRequestRoot $Fixture) -File).Count -eq 3) 'SmokePhase must write its own cleanup-request record without deleting anything.'
	$CompletedRequest = Get-Content (@(Get-ChildItem (Get-CleanupRequestRoot $Fixture) -File | Sort-Object Name)[-1]).FullName -Raw | ConvertFrom-Json
	$CompletedEntry = @($CompletedRequest.directories | Where-Object runDirectoryName -eq 'run-12345-attempt-1')[0]
	Assert-True ($CompletedEntry.state -eq 'completed' -and $CompletedEntry.completionState -eq 'passed' -and $CompletedEntry.cleanupEligible) 'A completed milestone with a validated marker must be cleanup-eligible with its terminal state recorded.'
	Assert-True (Test-Path (Join-Path $RunDirectory 'client\WindowsClient\AethelnOnlineClient.exe')) 'No handoff payload may be deleted by CI.'

	$Fixture = New-Case 'phase-smoke-missing-handoff'
	$Result = Invoke-PhaseGate $Fixture 'SmokePhase'
	Assert-ReportReason -Result $Result -Reason 'handoff_missing' -Message 'SmokePhase without a produced run directory must fail closed'
	Assert-True (-not (Test-Path $Fixture.SmokeCapture)) 'SmokePhase must not run smoke without verified handoff payloads.'

	$Fixture = New-Case 'phase-digest-tamper'
	$RunDirectory = Get-PhaseRunDirectory $Fixture
	[void] (Invoke-PhaseGate $Fixture 'PackageClient')
	[void] (Invoke-PhaseGate $Fixture 'PackageServer')
	Add-Content (Join-Path $RunDirectory 'server\LinuxServer\Linux\AethelnOnlineServer.sh') 'tampered'
	$CallsBeforeTamper = @(Get-Content $Fixture.PackageCapture).Count
	$Result = Invoke-PhaseGate $Fixture 'ValidateProvenance'
	Assert-ReportReason -Result $Result -Reason 'handoff_digest_mismatch' -Message 'A tampered payload must fail digest verification'
	Assert-True (@(Get-Content $Fixture.PackageCapture).Count -eq $CallsBeforeTamper) 'A digest mismatch must stop the phase before any validation work.'

	$Fixture = New-Case 'phase-runner-mismatch'
	[void] (Invoke-PhaseGate $Fixture 'PackageClient')
	[void] (Invoke-PhaseGate $Fixture 'PackageServer')
	$Result = Invoke-PhaseGate -Fixture $Fixture -Mode 'ValidateProvenance' -ExtraArguments @() -RunId '12345' -RunnerName 'other-runner'
	Assert-ReportReason -Result $Result -Reason 'handoff_runner_mismatch' -Message 'A consumer on a different runner name must fail closed'

	$Fixture = New-Fixture 'phase-timeout'
	Install-CompileClockFixture $Fixture -PhaseProbe
	$env:RUNNER_TEST_PHASE_SLEEP = '25'
	$TimeoutStarted = [DateTime]::UtcNow
	$Result = Invoke-PhaseGate -Fixture $Fixture -Mode 'PackageClient' -ExtraArguments @() -RunId '12345' -RunnerName 'fixture-runner' -TimeoutMinutes '0.05'
	$TimeoutElapsed = ([DateTime]::UtcNow - $TimeoutStarted).TotalSeconds
	Assert-ReportReason -Result $Result -Reason 'phase_timeout' -Message 'A phase exceeding its recorded limit must fail as phase_timeout'
	Assert-True (Test-Path (Join-Path $Fixture.Clock '007-phase')) 'The packaging timeout must actually reach its controlled child.'
	Assert-True ($TimeoutElapsed -lt 100) "The clock-driven phase must finish within its readiness guard and cleanup allowance, took ${TimeoutElapsed}s."
	Assert-True (-not (Test-Path (Join-Path (Get-PhaseRunDirectory $Fixture) 'manifest-client.json'))) 'A timed-out phase must not publish partial outputs.'
	$TimeoutBuilds = @((Read-Report $Result).compileEvidence.builds)
	Assert-True ($TimeoutBuilds.Count -eq 1 -and $TimeoutBuilds[0].outputState -eq 'unavailable' -and $TimeoutBuilds[0].actionCounterState -eq 'not_observed' -and $null -eq $TimeoutBuilds[0].lastObservedAction) 'A timed-out packaging child leaves its compile observations explicitly unavailable, never fabricated.'
	$env:RUNNER_TEST_PHASE_SLEEP = ''

	$Fixture = New-Case 'phase-storage-exhausted'
	$Result = Invoke-PhaseGate -Fixture $Fixture -Mode 'PackageClient' -ExtraArguments @('-HandoffPayloadCapBytes', '500000', '-HandoffRootCapBytes', '400000')
	Assert-ReportReason -Result $Result -Reason 'handoff_storage_exhausted' -Message 'A full handoff root must fail closed before packaging'
	Assert-True (@(Get-ChildItem (Get-CleanupRequestRoot $Fixture) -File).Count -eq 1) 'Storage exhaustion must retain its cleanup-request evidence.'
	Assert-True (-not (Test-Path (Get-PhaseRunDirectory $Fixture))) 'Storage exhaustion must not create the run directory.'

	$Fixture = New-Case 'phase-size-exceeded'
	$Result = Invoke-PhaseGate -Fixture $Fixture -Mode 'PackageClient' -ExtraArguments @('-HandoffPayloadCapBytes', '10')
	Assert-ReportReason -Result $Result -Reason 'handoff_size_exceeded' -Message 'A payload above the per-attempt cap must fail closed'
	Assert-True (-not (Test-Path (Join-Path (Get-PhaseRunDirectory $Fixture) 'manifest-client.json'))) 'An oversized payload must not publish its manifest.'

	$Fixture = New-Case 'phase-consume-aggregate-cap'
	$RunDirectory = Get-PhaseRunDirectory $Fixture
	[void] (Invoke-PhaseGate $Fixture 'PackageClient')
	[void] (Invoke-PhaseGate $Fixture 'PackageServer')
	$ClientTotal = [long] (Get-Content (Join-Path $RunDirectory 'manifest-client.json') -Raw | ConvertFrom-Json).totalBytes
	$ServerTotal = [long] (Get-Content (Join-Path $RunDirectory 'manifest-server.json') -Raw | ConvertFrom-Json).totalBytes
	$AggregateCap = [Math]::Max($ClientTotal, $ServerTotal)
	Assert-True ($ClientTotal -gt 0 -and $ServerTotal -gt 0 -and $AggregateCap -lt ($ClientTotal + $ServerTotal)) 'The aggregate-cap fixture must hold two individually valid manifests whose sum exceeds the chosen cap.'
	$CallsBeforeConsume = @(Get-Content $Fixture.PackageCapture).Count
	$Result = Invoke-PhaseGate -Fixture $Fixture -Mode 'ValidateProvenance' -ExtraArguments @('-HandoffPayloadCapBytes', [string] $AggregateCap)
	Assert-ReportReason -Result $Result -Reason 'handoff_size_exceeded' -Message 'Individually valid manifests whose aggregate exceeds the per-run cap must fail closed at provenance consumption'
	Assert-True (@(Get-Content $Fixture.PackageCapture).Count -eq $CallsBeforeConsume) 'An aggregate cap rejection must stop provenance before any payload use.'
	$Result = Invoke-PhaseGate $Fixture 'ValidateProvenance'
	Assert-True ($Result.ExitCode -eq 0) "The same manifest set must validate under the full cap. Output: $($Result.Output)"
	$ProvenanceTotal = [long] (Get-Content (Join-Path $RunDirectory 'manifest-provenance.json') -Raw | ConvertFrom-Json).totalBytes
	$SmokeCap = [Math]::Max($AggregateCap, $ProvenanceTotal)
	Assert-True (($ClientTotal + $ServerTotal + $ProvenanceTotal) -gt $SmokeCap) 'The smoke aggregate must exceed the chosen cap while every single manifest stays within it.'
	$Result = Invoke-PhaseGate -Fixture $Fixture -Mode 'SmokePhase' -ExtraArguments @('-HandoffPayloadCapBytes', [string] $SmokeCap)
	Assert-ReportReason -Result $Result -Reason 'handoff_size_exceeded' -Message 'Individually valid manifests whose aggregate exceeds the per-run cap must fail closed at smoke consumption'
	Assert-True (-not (Test-Path $Fixture.SmokeCapture)) 'An aggregate cap rejection must stop smoke before any payload use.'

	$Fixture = New-Case 'phase-prework-deadline'
	[void] (Invoke-PhaseGate $Fixture 'PackageClient')
	[void] (Invoke-PhaseGate $Fixture 'PackageServer')
	$CallsBeforeDeadline = @(Get-Content $Fixture.PackageCapture).Count
	$PreworkClock = [Diagnostics.Stopwatch]::StartNew()
	$Result = Invoke-PhaseGate -Fixture $Fixture -Mode 'ValidateProvenance' -ExtraArguments @() -RunId '12345' -RunnerName 'fixture-runner' -TimeoutMinutes '0.0001'
	$PreworkClock.Stop()
	Assert-ReportReason -Result $Result -Reason 'phase_timeout' -Message 'A script-phase deadline expiring during controlled pre-work must fail as phase_timeout with a retained report'
	Assert-True ($PreworkClock.Elapsed.TotalSeconds -lt 90) 'The uninstrumented whole-phase deadline must bound launch and finalization without requiring a specific stage.'
	Assert-True (@(Get-Content $Fixture.PackageCapture).Count -eq $CallsBeforeDeadline) 'The phase child must never start after the script-phase deadline.'

	foreach ($HardCase in @(
		@{ Name = 'phase-hash-block-hard-deadline'; Fault = ''; Reason = 'phase_timeout' },
		@{ Name = 'phase-hash-block-cleanup-failure'; Fault = 'skip-all'; Reason = 'phase_cleanup_failed' }
	)) {
		# A synchronous payload hash blocked across the script-phase deadline
		# must be interrupted by the supervisor hard bound: bounded return, no
		# consumer start, no surviving descendant, retained bounded report.
		$Fixture = New-Fixture $HardCase.Name
		Install-CompileClockFixture $Fixture -PhaseProbe
		[void] (Invoke-PhaseGate $Fixture 'PackageClient')
		[void] (Invoke-PhaseGate $Fixture 'PackageServer')
		$CallsBeforeBlock = @(Get-Content $Fixture.PackageCapture).Count
		$env:RUNNER_TEST_HASH_BLOCK_SECONDS = '240'
		$env:RUNNER_TEST_KILL_FAULT = $HardCase.Fault
		$BlockStarted = [DateTime]::UtcNow
		$Result = Invoke-PhaseGate -Fixture $Fixture -Mode 'ValidateProvenance' -ExtraArguments @('-PhaseFinalizeGraceSeconds', '5') -RunId '12345' -RunnerName 'fixture-runner' -TimeoutMinutes '0.25'
		$BlockElapsed = ([DateTime]::UtcNow - $BlockStarted).TotalSeconds
		$env:RUNNER_TEST_HASH_BLOCK_SECONDS = ''
		$env:RUNNER_TEST_KILL_FAULT = ''
		Assert-ReportReason -Result $Result -Reason $HardCase.Reason -Message "$($HardCase.Name) must classify the blocked pre-work hash as $($HardCase.Reason)"
		Assert-True (Test-Path (Join-Path $Fixture.Clock '021-hash')) 'The hard hash timeout must reach the synchronous hashing block.'
		Assert-True (@((Read-Report $Result).checks | Where-Object { $_.name -eq 'phase-hard-deadline' -and $_.message -like ($HardCase.Reason + '*') }).Count -eq 1) "$($HardCase.Name) must be enforced by the supervisor hard bound, not the cooperative deadline."
		Assert-True ($null -eq (Read-Report $Result).compileEvidence) "$($HardCase.Name) parent-written hard-timeout report carries no compile evidence rather than a guessed one."
		Assert-True ($BlockElapsed -lt 90) "$($HardCase.Name) must return within the bounded interval including timeout finalization, took ${BlockElapsed}s."
		Assert-True (@(Get-Content $Fixture.PackageCapture).Count -eq $CallsBeforeBlock) "$($HardCase.Name) must never start the provenance consumer."
		$Survivors = @()
		foreach ($Attempt in 1..20) {
			$Survivors = @(Get-Process -Name 'FakeAethelnDescendant' -ErrorAction SilentlyContinue)
			if ($Survivors.Count -eq 0) { break }
			Start-Sleep -Milliseconds 250
		}
		if ($Survivors.Count -gt 0) { $Survivors | Stop-Process -Force -ErrorAction SilentlyContinue }
		Assert-True ($Survivors.Count -eq 0) "$($HardCase.Name) must leave no supervised descendant alive before the gate returns."
		Assert-True (-not (Test-Path (Join-Path (Get-PhaseRunDirectory $Fixture) 'manifest-provenance.json'))) "$($HardCase.Name) must not publish partial outputs."
	}

	$Fixture = New-Case 'phase-smoke-timeout-required'
	$Result = Invoke-PhaseGate -Fixture $Fixture -Mode 'SmokePhase' -ExtraArguments @() -RunId '12345' -RunnerName 'fixture-runner' -TimeoutMinutes '0'
	Assert-ReportReason -Result $Result -Reason 'handoff_context_invalid' -Message 'SmokePhase without a positive phase-work timeout must be rejected'

	$Fixture = New-Fixture 'phase-smoke-hang'
	Install-CompileClockFixture $Fixture -PhaseProbe
	[void] (Invoke-PhaseGate $Fixture 'PackageClient')
	[void] (Invoke-PhaseGate $Fixture 'PackageServer')
	[void] (Invoke-PhaseGate $Fixture 'ValidateProvenance')
	$env:RUNNER_TEST_SMOKE_HANG = '120'
	$HangStarted = [DateTime]::UtcNow
	$Result = Invoke-PhaseGate -Fixture $Fixture -Mode 'SmokePhase' -ExtraArguments @() -RunId '12345' -RunnerName 'fixture-runner' -TimeoutMinutes '0.4'
	$HangElapsed = ([DateTime]::UtcNow - $HangStarted).TotalSeconds
	$env:RUNNER_TEST_SMOKE_HANG = ''
	Assert-ReportReason -Result $Result -Reason 'phase_timeout' -Message 'A hanging smoke must fail as phase_timeout under the script watchdog'
	Assert-True (Test-Path (Join-Path $Fixture.Clock '025-smoke')) 'The smoke timeout must actually reach the hanging smoke child.'
	Assert-True ($HangElapsed -lt 100) "The hanging smoke tree must be stopped by the watchdog, took ${HangElapsed}s."
	Assert-True (-not (Test-Path (Join-Path (Get-PhaseRunDirectory $Fixture) 'milestone-complete.json'))) 'A timed-out smoke must not publish a completion marker.'
	Assert-True (@(Get-ChildItem (Get-CleanupRequestRoot $Fixture) -File).Count -eq 2) 'A timed-out smoke must still retain its cleanup-request evidence.'

	$Fixture = New-Case 'phase-smoke-failure-diagnostics'
	[void] (Invoke-PhaseGate $Fixture 'PackageClient')
	[void] (Invoke-PhaseGate $Fixture 'PackageServer')
	[void] (Invoke-PhaseGate $Fixture 'ValidateProvenance')
	$env:RUNNER_TEST_SMOKE_FAIL = '1'
	$Result = Invoke-PhaseGate $Fixture 'SmokePhase'
	$env:RUNNER_TEST_SMOKE_FAIL = ''
	$Report = Read-Report $Result
	$SmokeMessage = [string] @($Report.checks | Where-Object name -eq 'packaged-build-smoke')[0].message
	$Disclosure = $Result.Output + (Get-Content $Result.Report -Raw)
	Assert-True ($Result.ExitCode -ne 0 -and $SmokeMessage -match 'smoke_failed' -and $SmokeMessage -match 'NET001' -and $SmokeMessage.Length -le 4120) 'A normal SmokePhase failure must keep its bounded actionable diagnostics.'
	foreach ($Value in @('smoke_bearer_marker', 'smoke_assignment_marker', 'AKIA1234567890ABCDEF', 'smoke_connection_marker')) { Assert-True (-not $Disclosure.Contains($Value)) "SmokePhase disclosure must redact $Value." }
	$FailedMarker = Get-Content (Join-Path (Get-PhaseRunDirectory $Fixture) 'milestone-complete.json') -Raw | ConvertFrom-Json
	Assert-True ($FailedMarker.state -eq 'failed') 'A normal smoke failure is terminal and must record a failed completion marker.'

	foreach ($KillCase in @(
		@{ Name = 'phase-descendant-kill'; Fault = ''; Reason = 'phase_timeout' },
		@{ Name = 'phase-kill-fallback'; Fault = 'skip-job'; Reason = 'phase_timeout' },
		@{ Name = 'phase-cleanup-failure'; Fault = 'skip-all'; Reason = 'phase_cleanup_failed' }
	)) {
		$Fixture = New-Fixture $KillCase.Name
		Install-CompileClockFixture $Fixture -PhaseProbe
		$env:RUNNER_TEST_PHASE_SPAWN = '1'
		$env:RUNNER_TEST_PHASE_SLEEP = '90'
		$env:RUNNER_TEST_KILL_FAULT = $KillCase.Fault
		$Result = Invoke-PhaseGate -Fixture $Fixture -Mode 'PackageClient' -ExtraArguments @() -RunId '12345' -RunnerName 'fixture-runner' -TimeoutMinutes '0.1'
		$env:RUNNER_TEST_PHASE_SPAWN = ''
		$env:RUNNER_TEST_PHASE_SLEEP = ''
		$env:RUNNER_TEST_KILL_FAULT = ''
		Assert-ReportReason -Result $Result -Reason $KillCase.Reason -Message "$($KillCase.Name) must report $($KillCase.Reason)"
		Assert-True (Test-Path (Join-Path $Fixture.Clock '007-phase')) 'Every cleanup fault case must reach its real packaging child and descendant.'
		$Survivors = @()
		foreach ($Attempt in 1..20) {
			$Survivors = @(Get-Process -Name 'FakeAethelnDescendant' -ErrorAction SilentlyContinue)
			if ($Survivors.Count -eq 0) { break }
			Start-Sleep -Milliseconds 250
		}
		if ($Survivors.Count -gt 0) { $Survivors | Stop-Process -Force -ErrorAction SilentlyContinue }
		Assert-True ($Survivors.Count -eq 0) "$($KillCase.Name) must leave no differently named descendant process alive before the gate returns."
		Assert-True (-not (Test-Path (Join-Path (Get-PhaseRunDirectory $Fixture) 'manifest-client.json'))) "$($KillCase.Name) must not publish partial outputs."
	}

	$Fixture = New-Case 'phase-manifest-adversarial'
	$RunDirectory = Get-PhaseRunDirectory $Fixture
	[void] (Invoke-PhaseGate $Fixture 'PackageClient')
	[void] (Invoke-PhaseGate $Fixture 'PackageServer')
	$ClientManifestPath = Join-Path $RunDirectory 'manifest-client.json'
	$OriginalManifest = Get-Content $ClientManifestPath -Raw
	foreach ($TamperCase in @(
		@{ Name = 'duplicate manifest paths'; Reason = 'handoff_schema_invalid'; Tamper = {
			$Manifest = $OriginalManifest | ConvertFrom-Json
			$Manifest.files = @($Manifest.files[0], $Manifest.files[0], $Manifest.files[2])
			$Manifest.totalBytes = [long] $Manifest.files[0].bytes * 2 + [long] $Manifest.files[2].bytes
			$Manifest | ConvertTo-Json -Depth 8 | Set-Content $ClientManifestPath -Encoding UTF8 } },
		@{ Name = 'duplicate JSON property'; Reason = 'handoff_schema_invalid'; Tamper = {
			$Index = $OriginalManifest.IndexOf('{')
			($OriginalManifest.Substring(0, $Index + 1) + '"schemaVersion": 1,' + $OriginalManifest.Substring($Index + 1)) | Set-Content $ClientManifestPath -Encoding UTF8 } },
		@{ Name = 'escaped duplicate JSON property'; Reason = 'handoff_schema_invalid'; Tamper = {
			$Index = $OriginalManifest.IndexOf('{')
			($OriginalManifest.Substring(0, $Index + 1) + '"\u0073chemaVersion": 1,' + $OriginalManifest.Substring($Index + 1)) | Set-Content $ClientManifestPath -Encoding UTF8 } },
		@{ Name = 'negative size'; Reason = 'handoff_schema_invalid'; Tamper = {
			$Manifest = $OriginalManifest | ConvertFrom-Json
			$Manifest.files[0].bytes = -5
			$Manifest | ConvertTo-Json -Depth 8 | Set-Content $ClientManifestPath -Encoding UTF8 } },
		@{ Name = 'invalid total'; Reason = 'handoff_schema_invalid'; Tamper = {
			$Manifest = $OriginalManifest | ConvertFrom-Json
			$Manifest.totalBytes = [long] $Manifest.totalBytes + 1
			$Manifest | ConvertTo-Json -Depth 8 | Set-Content $ClientManifestPath -Encoding UTF8 } },
		@{ Name = 'uppercase digest'; Reason = 'handoff_schema_invalid'; Tamper = {
			$Manifest = $OriginalManifest | ConvertFrom-Json
			$Manifest.files[0].sha256 = ([string] $Manifest.files[0].sha256).ToUpperInvariant()
			$Manifest | ConvertTo-Json -Depth 8 | Set-Content $ClientManifestPath -Encoding UTF8 } },
		@{ Name = 'case-colliding paths'; Reason = 'handoff_schema_invalid'; Tamper = {
			$Manifest = $OriginalManifest | ConvertFrom-Json
			$Manifest.files[1].path = ([string] $Manifest.files[0].path).ToUpperInvariant()
			$Manifest | ConvertTo-Json -Depth 8 | Set-Content $ClientManifestPath -Encoding UTF8 } }
	)) {
		& $TamperCase.Tamper
		$Result = Invoke-PhaseGate $Fixture 'ValidateProvenance'
		Assert-ReportReason -Result $Result -Reason $TamperCase.Reason -Message "A tampered client manifest ($($TamperCase.Name)) must fail closed"
		Set-Content $ClientManifestPath -Value $OriginalManifest -Encoding UTF8
	}
	$ClientPayloadRecord = Join-Path $RunDirectory 'client\phase-client.json'
	$AsidePath = Join-Path $Fixture.Root 'phase-client-aside.json'
	Move-Item $ClientPayloadRecord $AsidePath
	Set-Content (Join-Path $RunDirectory 'client\extra-substitute.bin') 'substituted' -Encoding UTF8
	$Result = Invoke-PhaseGate $Fixture 'ValidateProvenance'
	Assert-ReportReason -Result $Result -Reason 'handoff_digest_mismatch' -Message 'An omitted-plus-extra payload set with an unchanged file count must fail closed'
	Remove-Item (Join-Path $RunDirectory 'client\extra-substitute.bin')
	Move-Item $AsidePath $ClientPayloadRecord
	$Result = Invoke-PhaseGate $Fixture 'ValidateProvenance'
	Assert-True ($Result.ExitCode -eq 0) "The restored manifest and payload must validate again. Output: $($Result.Output)"

	$Fixture = New-Case 'phase-junction-payload'
	$RunDirectory = Get-PhaseRunDirectory $Fixture
	[void] (Invoke-PhaseGate $Fixture 'PackageClient')
	[void] (Invoke-PhaseGate $Fixture 'PackageServer')
	Move-Item (Join-Path $RunDirectory 'server') (Join-Path $RunDirectory 'server-moved')
	New-Item -ItemType Junction -Path (Join-Path $RunDirectory 'server') -Value (Join-Path $RunDirectory 'server-moved') | Out-Null
	$Result = Invoke-PhaseGate $Fixture 'ValidateProvenance'
	Assert-ReportReason -Result $Result -Reason 'handoff_payload_invalid' -Message 'A junction at the payload directory must be rejected before any digest use'
	[IO.Directory]::Delete((Join-Path $RunDirectory 'server'))

	$Fixture = New-Case 'phase-junction-scope'
	New-Item -ItemType Directory -Path (Join-Path $Fixture.Root 'owner-real') | Out-Null
	New-Item -ItemType Junction -Path (Join-Path $Fixture.Handoff 'owner') -Value (Join-Path $Fixture.Root 'owner-real') | Out-Null
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-ReportReason -Result $Result -Reason 'handoff_root_invalid' -Message 'A junction at the repository-scope ancestor must be rejected'
	[IO.Directory]::Delete((Join-Path $Fixture.Handoff 'owner'))

	$Fixture = New-Case 'phase-root-unc'
	$env:AETHELN_HANDOFF_ROOT = '\\fixture-host\handoff-share'
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-ReportReason -Result $Result -Reason 'handoff_root_invalid' -Message 'A UNC handoff root must be rejected as non-local'

	$Fixture = New-Case 'phase-root-cap-cross-scope'
	$OtherScope = Join-Path $Fixture.Handoff 'other\repo2'
	New-Item -ItemType Directory -Path $OtherScope -Force | Out-Null
	[IO.File]::WriteAllBytes((Join-Path $OtherScope 'blob.bin'), (New-Object byte[] 600000))
	$Result = Invoke-PhaseGate -Fixture $Fixture -Mode 'PackageClient' -ExtraArguments @('-HandoffPayloadCapBytes', '500000', '-HandoffRootCapBytes', '1000000')
	Assert-ReportReason -Result $Result -Reason 'handoff_storage_exhausted' -Message 'Bytes in another repository scope must count toward the total root cap'
	Assert-True (-not (Test-Path (Get-PhaseRunDirectory $Fixture))) 'Cross-scope exhaustion must not create the run directory.'

	$Fixture = New-Case 'phase-scope-namespace'
	$Result = Invoke-PhaseGate -Fixture $Fixture -Mode 'PackageClient' -ExtraArguments @() -RunId '12345' -RunnerName 'fixture-runner' -TimeoutMinutes '5' -Repository 'a/b-c'
	Assert-True ($Result.ExitCode -eq 0) "PackageClient for a/b-c must pass. Output: $($Result.Output)"
	$Result = Invoke-PhaseGate -Fixture $Fixture -Mode 'PackageClient' -ExtraArguments @() -RunId '12345' -RunnerName 'fixture-runner' -TimeoutMinutes '5' -Repository 'a-b/c'
	Assert-True ($Result.ExitCode -eq 0) "PackageClient for a-b/c must pass. Output: $($Result.Output)"
	Assert-True ((Test-Path (Join-Path $Fixture.Handoff 'a\b-c\run-12345-attempt-1')) -and (Test-Path (Join-Path $Fixture.Handoff 'a-b\c\run-12345-attempt-1'))) 'Colliding flattened names must resolve to distinct owner/repo scopes.'

	$Fixture = New-Case 'phase-run-context-guard'
	$RunDirectory = Get-PhaseRunDirectory $Fixture
	[void] (Invoke-PhaseGate $Fixture 'PackageClient')
	$ContextPath = Join-Path $RunDirectory 'run-context.json'
	$OriginalContext = Get-Content $ContextPath -Raw
	$TamperedContext = $OriginalContext | ConvertFrom-Json
	$TamperedContext.runnerName = 'other-runner'
	$TamperedContext | ConvertTo-Json | Set-Content $ContextPath -Encoding UTF8
	$Result = Invoke-PhaseGate $Fixture 'PackageServer'
	Assert-ReportReason -Result $Result -Reason 'handoff_runner_mismatch' -Message 'A run-context record bound to another runner must fail closed'
	Remove-Item $ContextPath
	$Result = Invoke-PhaseGate $Fixture 'PackageServer'
	Assert-ReportReason -Result $Result -Reason 'handoff_context_invalid' -Message 'A run directory without its run-context record must fail closed'
	Set-Content $ContextPath -Value $OriginalContext -Encoding UTF8
	$Result = Invoke-PhaseGate $Fixture 'PackageServer'
	Assert-True ($Result.ExitCode -eq 0) "The restored run context must validate. Output: $($Result.Output)"

	$Fixture = New-Case 'phase-cleanup-classification'
	$ScopeRoot = Join-Path $Fixture.Handoff 'owner\repo'
	New-Item -ItemType Directory -Path $ScopeRoot -Force | Out-Null
	foreach ($Name in @('run-901-attempt-1', 'run-902-attempt-1', 'run-903-attempt-1', 'run-904-attempt-1', 'run-905-attempt-1')) {
		New-Item -ItemType Directory -Path (Join-Path $ScopeRoot $Name) | Out-Null
		(Get-Item (Join-Path $ScopeRoot $Name)).CreationTimeUtc = [DateTime]::UtcNow.AddHours(-60)
	}
	New-FixtureRunContext -Fixture $Fixture -Directory (Join-Path $ScopeRoot 'run-901-attempt-1') -ContextRunId '901' -ContextRunAttempt '1'
	New-FixtureRunContext -Fixture $Fixture -Directory (Join-Path $ScopeRoot 'run-903-attempt-1') -ContextRunId '903' -ContextRunAttempt '1'
	Set-Content (Join-Path $ScopeRoot 'run-903-attempt-1\milestone-complete.json') 'not-json' -Encoding UTF8
	New-FixtureRunContext -Fixture $Fixture -Directory (Join-Path $ScopeRoot 'run-904-attempt-1') -ContextRunId '999' -ContextRunAttempt '1'
	New-FixtureRunContext -Fixture $Fixture -Directory (Join-Path $ScopeRoot 'run-905-attempt-1') -ContextRunId '905' -ContextRunAttempt '1'
	Set-Content (Join-Path $ScopeRoot 'run-905-attempt-1\payload.bin') 'bytes' -Encoding UTF8
	New-Item -ItemType Junction -Path (Join-Path $ScopeRoot 'run-905-attempt-1\jx') -Value $Fixture.Root | Out-Null
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-True ($Result.ExitCode -eq 0) "PackageClient must pass over the crafted scope. Output: $($Result.Output)"
	$Request = Get-Content (@(Get-ChildItem (Get-CleanupRequestRoot $Fixture) -File | Sort-Object Name)[-1]).FullName -Raw | ConvertFrom-Json
	$EntriesByName = @{}
	foreach ($Entry in @($Request.directories)) { $EntriesByName[[string] $Entry.runDirectoryName] = $Entry }
	Assert-True ($EntriesByName['run-901-attempt-1'].state -eq 'abandoned' -and $EntriesByName['run-901-attempt-1'].cleanupEligible) 'An old run with a valid context and no marker must be abandoned-eligible.'
	Assert-True ($EntriesByName['run-902-attempt-1'].state -eq 'invalid' -and -not $EntriesByName['run-902-attempt-1'].cleanupEligible) 'An old run without a run-context record must be invalid and never eligible.'
	Assert-True ($EntriesByName['run-903-attempt-1'].state -eq 'invalid' -and -not $EntriesByName['run-903-attempt-1'].cleanupEligible) 'A malformed completion marker must classify the run invalid.'
	Assert-True ($EntriesByName['run-904-attempt-1'].state -eq 'invalid' -and -not $EntriesByName['run-904-attempt-1'].cleanupEligible) 'A context record that mismatches its directory name must classify the run invalid.'
	Assert-True ($EntriesByName['run-905-attempt-1'].state -eq 'invalid' -and $EntriesByName['run-905-attempt-1'].measuredBytes -eq 0 -and -not $EntriesByName['run-905-attempt-1'].cleanupEligible) 'A descendant junction must classify the run invalid without traversal.'
	[IO.Directory]::Delete((Join-Path $ScopeRoot 'run-905-attempt-1\jx'))

	$Fixture = New-Case 'ddc-not-configured'
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-True ($Result.ExitCode -eq 0) "PackageClient without a DDC root must pass. Output: $($Result.Output)"
	Assert-True (@((Read-Report $Result).checks | Where-Object { $_.name -eq 'ddc-cache-configuration' -and $_.status -eq 'passed' -and $_.message -eq 'ddc_not_configured' }).Count -eq 1) 'An unset AETHELN_DDC_ROOT must be recorded as explicitly not configured.'
	$PackageCall = @(Get-Content $Fixture.PackageCapture | ForEach-Object { $_ | ConvertFrom-Json })[-1]
	Assert-True ([string]::IsNullOrEmpty([string] $PackageCall.DerivedDataCachePath)) 'Without a configured root the build controller must receive no cache path.'

	$Fixture = New-Case 'ddc-configured'
	$DdcRoot = Join-Path $Fixture.Root 'ddc'
	New-Item -ItemType Directory -Path $DdcRoot | Out-Null
	$env:AETHELN_DDC_ROOT = $DdcRoot
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-True ($Result.ExitCode -eq 0) "PackageClient with a valid DDC root must pass. Output: $($Result.Output)"
	Assert-True (@((Read-Report $Result).checks | Where-Object { $_.name -eq 'ddc-cache-configuration' -and $_.status -eq 'passed' -and $_.message -eq 'ddc_configured' }).Count -eq 1) 'A valid AETHELN_DDC_ROOT must be recorded as configured.'
	$PackageCall = @(Get-Content $Fixture.PackageCapture | ForEach-Object { $_ | ConvertFrom-Json })[-1]
	Assert-True ($PackageCall.DerivedDataCachePath -eq (Resolve-Path -LiteralPath $DdcRoot).Path -and $PackageCall.CacheFallback -eq 'FailClosed') 'The gate must pass the resolved cache root with the fail-closed default.'
	$env:AETHELN_DDC_FALLBACK = 'clean-isolated'
	$Result = Invoke-PhaseGate $Fixture 'PackageServer'
	Assert-True ($Result.ExitCode -eq 0) "PackageServer with the clean-isolated fallback must pass. Output: $($Result.Output)"
	$PackageCall = @(Get-Content $Fixture.PackageCapture | ForEach-Object { $_ | ConvertFrom-Json })[-1]
	Assert-True ($PackageCall.CacheFallback -eq 'CleanIsolated') 'The clean-isolated fallback selection must map to the build controller CleanIsolated mode.'
	$env:AETHELN_DDC_FALLBACK = 'bogus'
	$Result = Invoke-PhaseGate $Fixture 'ValidateProvenance'
	Assert-True ($Result.ExitCode -eq 0) 'A phase that never cooks must ignore the DDC configuration entirely.'
	Remove-Item Env:AETHELN_DDC_ROOT
	Remove-Item Env:AETHELN_DDC_FALLBACK

	$Fixture = New-Case 'ddc-fallback-invalid'
	$DdcRoot = Join-Path $Fixture.Root 'ddc'
	New-Item -ItemType Directory -Path $DdcRoot | Out-Null
	$env:AETHELN_DDC_ROOT = $DdcRoot
	$env:AETHELN_DDC_FALLBACK = 'bogus'
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-ReportReason -Result $Result -Reason 'ddc_fallback_invalid' -Message 'An unknown fallback selection must fail closed'
	Assert-True (-not (Test-Path $Fixture.PackageCapture)) 'An invalid fallback selection must stop before any packaging work.'
	Remove-Item Env:AETHELN_DDC_ROOT
	Remove-Item Env:AETHELN_DDC_FALLBACK

	$Fixture = New-Case 'ddc-root-missing'
	$env:AETHELN_DDC_ROOT = Join-Path $Fixture.Root 'absent-ddc'
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-ReportReason -Result $Result -Reason 'ddc_root_invalid' -Message 'A nonexistent DDC root must fail closed'
	Assert-True ($Result.Output -notmatch 'absent-ddc' -and -not (Test-Path $Fixture.PackageCapture)) 'A missing DDC root must fail before packaging without path disclosure.'
	Remove-Item Env:AETHELN_DDC_ROOT

	$Fixture = New-Case 'ddc-root-inside-repository'
	$InsideDdc = Join-Path $Fixture.Repository 'ddc-inside'
	New-Item -ItemType Directory -Path $InsideDdc | Out-Null
	$env:AETHELN_DDC_ROOT = $InsideDdc
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-ReportReason -Result $Result -Reason 'ddc_root_invalid' -Message 'A DDC root inside the repository must be rejected'
	Remove-Item Env:AETHELN_DDC_ROOT

	$Fixture = New-Case 'host-tools-prebuilt'
	$AttestationFile = Join-Path $Fixture.Root 'host-tools-attestation.json'
	Write-Fixture $AttestationFile '{"fixture":"attestation"}'
	$env:AETHELN_HOST_TOOLS = 'prebuilt'
	$env:AETHELN_ENGINE_REVISION = $Fixture.Revision.ToUpperInvariant()
	$env:AETHELN_HOST_TOOLS_ATTESTATION = $AttestationFile
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-True ($Result.ExitCode -eq 0) "PackageClient with a valid prebuilt host-tools configuration must pass. Output: $($Result.Output)"
	Assert-True (@((Read-Report $Result).checks | Where-Object { $_.name -eq 'host-tools-configuration' -and $_.status -eq 'passed' -and $_.message -eq 'host_tools_prebuilt' }).Count -eq 1) 'A valid prebuilt selection must be recorded as configured.'
	Assert-True ((Read-Report $Result).runnerName -eq 'fixture-runner') 'The runner report must record the validated runner name.'
	$PackageCall = @(Get-Content $Fixture.PackageCapture | ForEach-Object { $_ | ConvertFrom-Json })[-1]
	Assert-True ($PackageCall.HostToolsBoundary -eq 'Prebuilt' -and $PackageCall.EngineRevision -eq $Fixture.Revision.ToLowerInvariant()) 'The gate must forward the prebuilt boundary with the normalized pinned engine revision.'
	Assert-True ($PackageCall.HostToolsAttestationPath -eq (Resolve-Path -LiteralPath $AttestationFile).Path) 'The gate must forward the resolved attestation record path.'
	Assert-True ($PackageCall.RunnerName -eq 'fixture-runner') 'The gate must forward the validated runner name to the build controller.'
	$env:AETHELN_HOST_TOOLS = 'rebuild-authorized'
	Remove-Item Env:AETHELN_ENGINE_REVISION
	Remove-Item Env:AETHELN_HOST_TOOLS_ATTESTATION
	$Result = Invoke-PhaseGate $Fixture 'PackageServer'
	Assert-True ($Result.ExitCode -eq 0) "PackageServer with the explicit authorized rebuild must pass. Output: $($Result.Output)"
	Assert-True (@((Read-Report $Result).checks | Where-Object { $_.name -eq 'host-tools-configuration' -and $_.status -eq 'passed' -and $_.message -eq 'host_tools_rebuild_authorized' }).Count -eq 1) 'The separately named authorized rebuild must be recorded explicitly.'
	$PackageCall = @(Get-Content $Fixture.PackageCapture | ForEach-Object { $_ | ConvertFrom-Json })[-1]
	Assert-True ($PackageCall.HostToolsBoundary -eq 'Rebuild' -and [string]::IsNullOrEmpty([string] $PackageCall.EngineRevision) -and [string]::IsNullOrEmpty([string] $PackageCall.HostToolsAttestationPath)) 'The authorized rebuild must forward the explicit Rebuild boundary without prebuilt arguments.'
	$env:AETHELN_HOST_TOOLS = 'bogus'
	$Result = Invoke-PhaseGate $Fixture 'ValidateProvenance'
	Assert-True ($Result.ExitCode -eq 0) 'A phase that never builds must ignore the host-tools configuration entirely.'
	$env:AETHELN_HOST_TOOLS = 'rebuild-authorized'

	$Fixture = New-Case 'host-tools-invalid'
	Remove-Item Env:AETHELN_HOST_TOOLS
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-ReportReason -Result $Result -Reason 'host_tools_configuration_required' -Message 'Unset host-tools configuration must fail closed instead of rebuilding implicitly'
	Assert-True (-not (Test-Path $Fixture.PackageCapture)) 'Unset host-tools configuration must stop before any packaging work.'
	$env:AETHELN_HOST_TOOLS = 'rebuild'
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-ReportReason -Result $Result -Reason 'host_tools_invalid' -Message 'The retired implicit rebuild name must no longer be accepted'
	$env:AETHELN_HOST_TOOLS = 'prebuilt'
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-ReportReason -Result $Result -Reason 'engine_revision_invalid' -Message 'A prebuilt selection without the pinned engine revision must fail closed'
	$env:AETHELN_ENGINE_REVISION = 'not-a-revision'
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-ReportReason -Result $Result -Reason 'engine_revision_invalid' -Message 'A malformed pinned engine revision must fail closed'
	$env:AETHELN_ENGINE_REVISION = $Fixture.Revision
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-ReportReason -Result $Result -Reason 'host_tools_attestation_invalid' -Message 'A prebuilt selection without an attestation record must fail closed'
	$InsideAttestation = Join-Path $Fixture.Repository 'attestation.json'
	Write-Fixture $InsideAttestation '{}'
	$env:AETHELN_HOST_TOOLS_ATTESTATION = $InsideAttestation
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-ReportReason -Result $Result -Reason 'host_tools_attestation_invalid' -Message 'An attestation record inside the repository must fail closed'
	Assert-True (-not (Test-Path $Fixture.PackageCapture)) 'Every invalid host-tools configuration must stop before any packaging work.'
	$env:AETHELN_HOST_TOOLS = 'rebuild-authorized'
	Remove-Item Env:AETHELN_ENGINE_REVISION
	Remove-Item Env:AETHELN_HOST_TOOLS_ATTESTATION

	Write-Output 'PASS: engine runner wrapper contracts are completely covered'
} catch {
	$RetainFixtureEvidence = $true
	Write-Output "Failed fixture evidence retained at: $FixtureRoot"
	throw
} finally {
	$env:PATH = $Original.PATH
	$env:AETHELN_ENGINE_ROOT = $Original.Engine
	$env:AETHELN_LINUX_TOOLCHAIN_ROOT = $Original.Toolchain
	$env:AETHELN_HANDOFF_ROOT = $Original.Handoff
	Remove-Item Env:AETHELN_DDC_ROOT -ErrorAction Ignore
	Remove-Item Env:AETHELN_DDC_FALLBACK -ErrorAction Ignore
	Remove-Item Env:AETHELN_HOST_TOOLS -ErrorAction Ignore
	Remove-Item Env:AETHELN_ENGINE_REVISION -ErrorAction Ignore
	Remove-Item Env:AETHELN_HOST_TOOLS_ATTESTATION -ErrorAction Ignore
	Remove-Item Env:RUNNER_TEST_CLOCK_ROOT -ErrorAction Ignore
	Remove-Item Env:RUNNER_TEST_CLOCK_BUILD -ErrorAction Ignore
	@('RUNNER_TEST_REPOSITORY','RUNNER_TEST_ALT_REVISION','RUNNER_TEST_BUILD_CAPTURE','RUNNER_TEST_PACKAGE_CAPTURE','RUNNER_TEST_SMOKE_CAPTURE','RUNNER_TEST_WSL_CAPTURE','RUNNER_TEST_MUTATION','RUNNER_TEST_FAIL_TARGET','RUNNER_TEST_AMBIGUOUS','RUNNER_TEST_INTERNAL','RUNNER_TEST_SMOKE_FAIL','RUNNER_TEST_SMOKE_HANG','RUNNER_TEST_PHASE_SLEEP','RUNNER_TEST_PHASE_FAIL','RUNNER_TEST_PHASE_SPAWN','RUNNER_TEST_KILL_FAULT','RUNNER_TEST_HASH_BLOCK_SECONDS','RUNNER_TEST_UBT_OUTPUT_AethelnOnlineClient','RUNNER_TEST_UBT_OUTPUT_AethelnOnlineServer','RUNNER_TEST_UBT_OUTPUT_PACKAGE','RUNNER_TEST_DESCENDANT_EXE','RUNNER_TEST_WSLPATH_OUTPUT','RUNNER_TEST_HOSTNAME_OUTPUT','RUNNER_TEST_WSLPATH_EXIT','RUNNER_TEST_HOSTNAME_EXIT') | ForEach-Object { Remove-Item -LiteralPath ('Env:' + $_) -ErrorAction Ignore }
	if (-not $RetainFixtureEvidence -and (Test-Path -LiteralPath $FixtureRoot)) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
}
