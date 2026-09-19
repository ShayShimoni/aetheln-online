param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Module = Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'scripts/ci/RoutineCompileCommand.ps1'
if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) { throw 'routine_command_module_missing' }
. $Module
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnRoutineCommand-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $FixtureRoot
$script:Assertions = 0
function Assert-True($Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
	$script:Assertions++
}
function Assert-Rejected([scriptblock] $Action, [string] $Reason) {
	$Failure = ''
	try { & $Action | Out-Null } catch { $Failure = $_.Exception.Message }
	Assert-True -Condition ($Failure -ceq $Reason) -Message "Expected $Reason; got $Failure"
}
$FixtureExe = Join-Path $FixtureRoot 'command fixture.exe'
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
public static class RoutineCommandFixture {
    public static int Main(string[] args) {
        Console.OutputEncoding = new UTF8Encoding(false);
        if (args[0] == "args") { for(int i=1; i<args.Length; i++) Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(args[i]))); return 0; }
        if (args[0] == "stderr") { Console.WriteLine("normal stdout"); Console.Error.WriteLine("legitimate stderr"); return 0; }
        if (args[0] == "exit") return 23;
        if (args[0] == "marker") { File.WriteAllText(args[1], "launched"); return 0; }
        if (args[0] == "sleep") { File.WriteAllText(args[1], Process.GetCurrentProcess().Id.ToString()); Thread.Sleep(10000); return 0; }
        if (args[0] == "flood") { byte[] bytes = new byte[8192]; for(int i=0;i<bytes.Length;i++) bytes[i]=65; Stream stdout=Console.OpenStandardOutput(); Stream stderr=Console.OpenStandardError(); for(int i=0;i<2300;i++) { (i%2==0?stdout:stderr).Write(bytes,0,bytes.Length); } return 0; }
        if (args[0] == "lines") { for(int i=0;i<65537;i++) Console.WriteLine(); return 0; }
        if (args[0] == "pipe") { var info=new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, "hold"); info.UseShellExecute=false; info.CreateNoWindow=true; var child=Process.Start(info); File.WriteAllText(args[1], child.Id.ToString()); return 0; }
        if (args[0] == "hold") { Thread.Sleep(2200); Console.WriteLine("held pipe done"); return 0; }
        return 99;
    }
}
'@ -OutputAssembly $FixtureExe -OutputType ConsoleApplication
$Clock = [Diagnostics.Stopwatch]::StartNew()
$Progress = { if ($Clock.Elapsed.TotalSeconds -gt 15) { throw 'fixture_deadline' } }.GetNewClosure()
$Result = Invoke-RoutineCompileCommand -Executable $FixtureExe -Arguments @('stderr') -WorkingDirectory $FixtureRoot -OnProgress $Progress
Assert-True -Condition ($Result.exitCode -eq 0) -Message 'Legitimate stderr does not rewrite native success'
Assert-True -Condition ($Result.output -contains 'normal stdout' -and $Result.output -contains 'legitimate stderr') -Message 'Both streams retained'
$Result = Invoke-RoutineCompileCommand -Executable $FixtureExe -Arguments @('exit') -WorkingDirectory $FixtureRoot -OnProgress $Progress
Assert-True -Condition ($Result.exitCode -eq 23) -Message 'Native nonzero exit remains exact'
$Expected = @('', 'space value', 'double"quote', 'end slash\', 'two\\"quotes', "single'quote", [string][char]0x03A9, 'literal&%|<>!')
$Result = Invoke-RoutineCompileCommand -Executable $FixtureExe -Arguments (@('args') + $Expected) -WorkingDirectory $FixtureRoot -OnProgress $Progress
Assert-True -Condition ($Result.output.Count -eq $Expected.Count) -Message 'Empty argument retained'
for ($Index = 0; $Index -lt $Expected.Count; $Index++) {
	$Actual = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Result.output[$Index]))
	Assert-True -Condition ($Actual -ceq $Expected[$Index]) -Message "Exact argument $Index"
}
$Marker = Join-Path $FixtureRoot 'not-launched.txt'
Assert-Rejected -Action { Invoke-RoutineCompileCommand -Executable $FixtureExe -Arguments @('marker', $Marker) -WorkingDirectory $FixtureRoot -OnProgress { throw 'fixture_before_launch' } } -Reason 'fixture_before_launch'
Assert-True -Condition (-not (Test-Path -LiteralPath $Marker)) -Message 'Callback denial precedes launch'
Assert-Rejected -Action { Invoke-RoutineCompileCommand -Executable (Join-Path $FixtureRoot 'missing.exe') -Arguments @() -WorkingDirectory $FixtureRoot -OnProgress $Progress } -Reason 'routine_command_start_failed'
$SleepingId = Join-Path $FixtureRoot 'sleep.pid'
$StopClock = [Diagnostics.Stopwatch]::StartNew()
$StopProgress = { if ($StopClock.Elapsed.TotalMilliseconds -gt 600) { throw 'fixture_running_deadline' } }.GetNewClosure()
Assert-Rejected -Action { Invoke-RoutineCompileCommand -Executable $FixtureExe -Arguments @('sleep', $SleepingId) -WorkingDirectory $FixtureRoot -OnProgress $StopProgress } -Reason 'fixture_running_deadline'
Assert-True -Condition ($StopClock.Elapsed.TotalSeconds -lt 3) -Message 'Active command cancellation is bounded'
Assert-True -Condition (Test-Path -LiteralPath $SleepingId) -Message 'Cancellation fixture really started'
$OwnedProcess = Get-Process -Id ([int][IO.File]::ReadAllText($SleepingId)) -ErrorAction SilentlyContinue
Assert-True -Condition ($null -eq $OwnedProcess) -Message 'Exact direct process was terminated'
Assert-Rejected -Action { Invoke-RoutineCompileCommand -Executable $FixtureExe -Arguments @('flood') -WorkingDirectory $FixtureRoot -OnProgress $Progress } -Reason 'routine_command_output_limit'
Assert-Rejected -Action { Invoke-RoutineCompileCommand -Executable $FixtureExe -Arguments @('lines') -WorkingDirectory $FixtureRoot -OnProgress $Progress } -Reason 'routine_command_output_limit'
$ScriptFixture = Join-Path $FixtureRoot 'fixture script.ps1'
[IO.File]::WriteAllText($ScriptFixture, 'param([string] $Value) [Console]::WriteLine($Value); [Console]::Error.WriteLine("script stderr"); exit 17')
$Result = Invoke-RoutineCompileCommand -Executable $ScriptFixture -Arguments @("space ' quote " + [char]0x03A9) -WorkingDirectory $FixtureRoot -OnProgress $Progress
Assert-True -Condition ($Result.exitCode -eq 17 -and $Result.output -contains "space ' quote $([char]0x03A9)" -and $Result.output -contains 'script stderr') -Message 'Encoded script arguments, stderr and exit preserved'
$NamedFixture = Join-Path $FixtureRoot 'named script.ps1'
[IO.File]::WriteAllText($NamedFixture, @'
param(
    [Parameter(Mandatory=$true)][ValidateSet('AethelnOnlineClient','AethelnOnlineServer')][string] $Target,
    [Parameter(Mandatory=$true)][ValidateSet('Win64','Linux')][string] $Platform,
    [Parameter(Mandatory=$true)][ValidateRange(1,4)][int] $ActionLimit,
    [string] $Value
)
[Console]::WriteLine("$Target|$Platform|$ActionLimit")
[Console]::WriteLine($Value)
[Console]::Error.WriteLine('named stderr')
exit 31
'@)
$NamedValue = "space ' double`" quote &|% " + [char]0x03A9
$Result = Invoke-RoutineCompileCommand -Executable $NamedFixture -Arguments @('-Target', 'AethelnOnlineClient', '-Platform', 'Win64', '-ActionLimit', '4', '-Value', $NamedValue) -WorkingDirectory $FixtureRoot -OnProgress $Progress
Assert-True -Condition ($Result.exitCode -eq 31 -and $Result.output -contains 'AethelnOnlineClient|Win64|4') -Message 'Mandatory ValidateSet parameters bind by name, not as positional dash tokens'
Assert-True -Condition ($Result.output -contains $NamedValue -and $Result.output -contains 'named stderr') -Message 'Named values preserve quotes, Unicode, metacharacters and stderr'
$Result = Invoke-RoutineCompileCommand -Executable $NamedFixture -Arguments @('-Target', 'AethelnOnlineClient', '-Platform', 'Win64', '-ActionLimit', '4', '-Value', '-literal-dash-value') -WorkingDirectory $FixtureRoot -OnProgress $Progress
Assert-True -Condition ($Result.exitCode -eq 31 -and $Result.output -contains '-literal-dash-value') -Message 'A named parameter value may itself start with a dash'
Assert-Rejected -Action { Invoke-RoutineCompileCommand -Executable $NamedFixture -Arguments @('-Target') -WorkingDirectory $FixtureRoot -OnProgress $Progress } -Reason 'routine_command_arguments_invalid'
Assert-Rejected -Action { Invoke-RoutineCompileCommand -Executable $NamedFixture -Arguments @('-Target', 'AethelnOnlineClient', '-target', 'AethelnOnlineServer') -WorkingDirectory $FixtureRoot -OnProgress $Progress } -Reason 'routine_command_arguments_invalid'
Assert-Rejected -Action { Invoke-RoutineCompileCommand -Executable $NamedFixture -Arguments @('-Target:$(throw)') -WorkingDirectory $FixtureRoot -OnProgress $Progress } -Reason 'routine_command_arguments_invalid'
$ThrowFixture = Join-Path $FixtureRoot 'throw.ps1'
[IO.File]::WriteAllText($ThrowFixture, 'throw "fixture powershell failure"')
$Result = Invoke-RoutineCompileCommand -Executable $ThrowFixture -Arguments @() -WorkingDirectory $FixtureRoot -OnProgress $Progress
Assert-True -Condition ($Result.exitCode -ne 0 -and $Result.output -contains 'routine_command_script_failed') -Message 'PowerShell failure cannot become exit zero'
$BatchFixture = Join-Path $FixtureRoot 'fixture batch.bat'
[IO.File]::WriteAllText($BatchFixture, "@echo off`r`necho %~1`r`nexit /b 19`r`n")
$Result = Invoke-RoutineCompileCommand -Executable $BatchFixture -Arguments @('two words') -WorkingDirectory $FixtureRoot -OnProgress $Progress
Assert-True -Condition ($Result.exitCode -eq 19 -and $Result.output -contains 'two words') -Message 'Batch spaces and native exit preserved'
Assert-Rejected -Action { Invoke-RoutineCompileCommand -Executable $BatchFixture -Arguments @('" & echo injected') -WorkingDirectory $FixtureRoot -OnProgress $Progress } -Reason 'routine_command_arguments_invalid'
$PipeId = Join-Path $FixtureRoot 'pipe.pid'
$PipeClock = [Diagnostics.Stopwatch]::StartNew()
$PipeProgress = { if ($PipeClock.Elapsed.TotalMilliseconds -gt 700) { throw 'fixture_pipe_deadline' } }.GetNewClosure()
Assert-Rejected -Action { Invoke-RoutineCompileCommand -Executable $FixtureExe -Arguments @('pipe', $PipeId) -WorkingDirectory $FixtureRoot -OnProgress $PipeProgress } -Reason 'fixture_pipe_deadline'
Assert-True -Condition ($PipeClock.Elapsed.TotalSeconds -lt 3) -Message 'Inherited pipe cannot block callback deadline'
Assert-True -Condition (Test-Path -LiteralPath $PipeId) -Message 'Descendant pipe fixture started'
# This harmless fixture exits itself; the helper must not claim or perform tree cleanup.
Start-Sleep -Milliseconds 2400
Assert-True -Condition ($null -eq (Get-Process -Id ([int][IO.File]::ReadAllText($PipeId)) -ErrorAction SilentlyContinue)) -Message 'Pipe descendant naturally finished'
Write-Output "PASS: $script:Assertions routine command assertions; fixtures retained at $FixtureRoot"
