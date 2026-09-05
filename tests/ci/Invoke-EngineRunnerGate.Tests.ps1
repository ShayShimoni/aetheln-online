param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path (Split-Path $PSScriptRoot)
$SourceScript = Join-Path $RepositoryRoot 'scripts/ci/Invoke-EngineRunnerGate.ps1'
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
$PowerShell = (Get-Process -Id $PID).Path
$Original = @{ PATH = $env:PATH; Engine = $env:AETHELN_ENGINE_ROOT; Toolchain = $env:AETHELN_LINUX_TOOLCHAIN_ROOT; Handoff = $env:AETHELN_HANDOFF_ROOT }

function Assert-True($Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Write-Fixture([string] $Path, [string] $Value) {
	Set-Content -LiteralPath $Path -Value $Value -Encoding UTF8
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
function New-Fixture([string] $Name) {
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
function Install-Fakes($Fixture) {
	Write-Fixture $Fixture.BuildBatch '@echo off
>>"%RUNNER_TEST_BUILD_CAPTURE%" echo %*
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
	Write-Fixture (Join-Path $Fixture.Repository 'scripts/build/Build-PackagedArtifacts.ps1') 'param($ProjectPath,$EngineRoot,$LinuxToolchainRoot,$ArchiveRoot,$LogRoot,$SourceRevision,$Configuration,$Map,$Stage,$ClientStageRoot,$ServerStageRoot)
@{ProjectPath=$ProjectPath;EngineRoot=$EngineRoot;LinuxToolchainRoot=$LinuxToolchainRoot;ArchiveRoot=$ArchiveRoot;LogRoot=$LogRoot;SourceRevision=$SourceRevision;Configuration=$Configuration;Map=$Map;Stage=$Stage;ClientStageRoot=$ClientStageRoot;ServerStageRoot=$ServerStageRoot}|ConvertTo-Json -Compress|Add-Content $env:RUNNER_TEST_PACKAGE_CAPTURE
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
	$env:RUNNER_TEST_DESCENDANT_EXE = Join-Path $Fixture.Bin 'FakeAethelnDescendant.exe'
	$env:AETHELN_HANDOFF_ROOT = $Fixture.Handoff
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
function New-FixtureRunContext($Fixture, [string] $Directory, [string] $ContextRunId, [string] $ContextRunAttempt, [string] $ContextRunnerName = 'fixture-runner') {
	@{ schemaVersion = 1; repository = 'owner/repo'; sourceRevision = $Fixture.Revision; runId = $ContextRunId; runAttempt = $ContextRunAttempt; runnerName = $ContextRunnerName; createdUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Directory 'run-context.json') -Encoding UTF8
}
function Assert-ReportReason($Result, [string] $Reason, [string] $Message) {
	Assert-True ($Result.ExitCode -ne 0) "$Message (exit code)."
	Assert-True (@((Read-Report $Result).checks | Where-Object message -like ($Reason + '*')).Count -ge 1) "$Message (report must carry $Reason)."
}
function Read-Report($Result) { Get-Content -LiteralPath $Result.Report -Raw | ConvertFrom-Json }
function New-Case([string] $Name) { $Fixture = New-Fixture $Name; Install-Fakes $Fixture; return $Fixture }

try {
	New-Item -ItemType Directory -Path $FixtureRoot | Out-Null

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
		elseif ($Case.Kind -eq 'wrong') { $Result = Invoke-Gate $Fixture 'Compile' ('2' * 40) }
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
	Assert-ReportReason $Result 'handoff_root_unset' 'An unset handoff root must fail only the phase job with its stable code'
	Assert-True (-not (Test-Path $Fixture.PackageCapture)) 'An unset handoff root must fail before any packaging work.'

	$Fixture = New-Case 'phase-root-inside-repository'
	$InsideRoot = Join-Path $Fixture.Repository 'handoff-inside'
	New-Item -ItemType Directory -Path $InsideRoot | Out-Null
	$env:AETHELN_HANDOFF_ROOT = $InsideRoot
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-ReportReason $Result 'handoff_root_invalid' 'A handoff root inside the repository must be rejected'

	$Fixture = New-Case 'phase-context-invalid'
	$Result = Invoke-PhaseGate $Fixture 'PackageClient' @() 'abc'
	Assert-ReportReason $Result 'handoff_context_invalid' 'A non-numeric run id must be rejected'

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
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-ReportReason $Result 'handoff_conflict' 'A repeated PackageClient for the same run attempt must not overwrite or reuse the run directory'
	$Result = Invoke-PhaseGate $Fixture 'PackageServer'
	Assert-True ($Result.ExitCode -eq 0) "PackageServer must pass. Output: $($Result.Output)"
	Assert-True (Test-Path (Join-Path $RunDirectory 'manifest-server.json')) 'PackageServer must publish its integrity manifest.'
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
	Assert-ReportReason $Result 'handoff_missing' 'SmokePhase without a produced run directory must fail closed'
	Assert-True (-not (Test-Path $Fixture.SmokeCapture)) 'SmokePhase must not run smoke without verified handoff payloads.'

	$Fixture = New-Case 'phase-digest-tamper'
	$RunDirectory = Get-PhaseRunDirectory $Fixture
	[void] (Invoke-PhaseGate $Fixture 'PackageClient')
	[void] (Invoke-PhaseGate $Fixture 'PackageServer')
	Add-Content (Join-Path $RunDirectory 'server\LinuxServer\Linux\AethelnOnlineServer.sh') 'tampered'
	$CallsBeforeTamper = @(Get-Content $Fixture.PackageCapture).Count
	$Result = Invoke-PhaseGate $Fixture 'ValidateProvenance'
	Assert-ReportReason $Result 'handoff_digest_mismatch' 'A tampered payload must fail digest verification'
	Assert-True (@(Get-Content $Fixture.PackageCapture).Count -eq $CallsBeforeTamper) 'A digest mismatch must stop the phase before any validation work.'

	$Fixture = New-Case 'phase-runner-mismatch'
	[void] (Invoke-PhaseGate $Fixture 'PackageClient')
	[void] (Invoke-PhaseGate $Fixture 'PackageServer')
	$Result = Invoke-PhaseGate $Fixture 'ValidateProvenance' @() '12345' 'other-runner'
	Assert-ReportReason $Result 'handoff_runner_mismatch' 'A consumer on a different runner name must fail closed'

	$Fixture = New-Case 'phase-timeout'
	$env:RUNNER_TEST_PHASE_SLEEP = '25'
	$TimeoutStarted = [DateTime]::UtcNow
	$Result = Invoke-PhaseGate $Fixture 'PackageClient' @() '12345' 'fixture-runner' '0.05'
	$TimeoutElapsed = ([DateTime]::UtcNow - $TimeoutStarted).TotalSeconds
	Assert-ReportReason $Result 'phase_timeout' 'A phase exceeding its recorded limit must fail as phase_timeout'
	Assert-True ($TimeoutElapsed -lt 22) "The timed-out phase process tree must be stopped promptly, took ${TimeoutElapsed}s."
	Assert-True (-not (Test-Path (Join-Path (Get-PhaseRunDirectory $Fixture) 'manifest-client.json'))) 'A timed-out phase must not publish partial outputs.'
	$env:RUNNER_TEST_PHASE_SLEEP = ''

	$Fixture = New-Case 'phase-storage-exhausted'
	$Result = Invoke-PhaseGate $Fixture 'PackageClient' @('-HandoffPayloadCapBytes', '500000', '-HandoffRootCapBytes', '400000')
	Assert-ReportReason $Result 'handoff_storage_exhausted' 'A full handoff root must fail closed before packaging'
	Assert-True (@(Get-ChildItem (Get-CleanupRequestRoot $Fixture) -File).Count -eq 1) 'Storage exhaustion must retain its cleanup-request evidence.'
	Assert-True (-not (Test-Path (Get-PhaseRunDirectory $Fixture))) 'Storage exhaustion must not create the run directory.'

	$Fixture = New-Case 'phase-size-exceeded'
	$Result = Invoke-PhaseGate $Fixture 'PackageClient' @('-HandoffPayloadCapBytes', '10')
	Assert-ReportReason $Result 'handoff_size_exceeded' 'A payload above the per-attempt cap must fail closed'
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
	$Result = Invoke-PhaseGate $Fixture 'ValidateProvenance' @('-HandoffPayloadCapBytes', [string] $AggregateCap)
	Assert-ReportReason $Result 'handoff_size_exceeded' 'Individually valid manifests whose aggregate exceeds the per-run cap must fail closed at provenance consumption'
	Assert-True (@(Get-Content $Fixture.PackageCapture).Count -eq $CallsBeforeConsume) 'An aggregate cap rejection must stop provenance before any payload use.'
	$Result = Invoke-PhaseGate $Fixture 'ValidateProvenance'
	Assert-True ($Result.ExitCode -eq 0) "The same manifest set must validate under the full cap. Output: $($Result.Output)"
	$ProvenanceTotal = [long] (Get-Content (Join-Path $RunDirectory 'manifest-provenance.json') -Raw | ConvertFrom-Json).totalBytes
	$SmokeCap = [Math]::Max($AggregateCap, $ProvenanceTotal)
	Assert-True (($ClientTotal + $ServerTotal + $ProvenanceTotal) -gt $SmokeCap) 'The smoke aggregate must exceed the chosen cap while every single manifest stays within it.'
	$Result = Invoke-PhaseGate $Fixture 'SmokePhase' @('-HandoffPayloadCapBytes', [string] $SmokeCap)
	Assert-ReportReason $Result 'handoff_size_exceeded' 'Individually valid manifests whose aggregate exceeds the per-run cap must fail closed at smoke consumption'
	Assert-True (-not (Test-Path $Fixture.SmokeCapture)) 'An aggregate cap rejection must stop smoke before any payload use.'

	$Fixture = New-Case 'phase-prework-deadline'
	[void] (Invoke-PhaseGate $Fixture 'PackageClient')
	[void] (Invoke-PhaseGate $Fixture 'PackageServer')
	$CallsBeforeDeadline = @(Get-Content $Fixture.PackageCapture).Count
	$Result = Invoke-PhaseGate $Fixture 'ValidateProvenance' @() '12345' 'fixture-runner' '0.0001'
	Assert-ReportReason $Result 'phase_timeout' 'A script-phase deadline expiring during controlled pre-work must fail as phase_timeout with a retained report'
	Assert-True (@(Get-Content $Fixture.PackageCapture).Count -eq $CallsBeforeDeadline) 'The phase child must never start after the script-phase deadline.'

	foreach ($HardCase in @(
		@{ Name = 'phase-hash-block-hard-deadline'; Fault = ''; Reason = 'phase_timeout' },
		@{ Name = 'phase-hash-block-cleanup-failure'; Fault = 'skip-all'; Reason = 'phase_cleanup_failed' }
	)) {
		# A synchronous payload hash blocked across the script-phase deadline
		# must be interrupted by the supervisor hard bound: bounded return, no
		# consumer start, no surviving descendant, retained bounded report.
		$Fixture = New-Case $HardCase.Name
		[void] (Invoke-PhaseGate $Fixture 'PackageClient')
		[void] (Invoke-PhaseGate $Fixture 'PackageServer')
		$CallsBeforeBlock = @(Get-Content $Fixture.PackageCapture).Count
		$env:RUNNER_TEST_HASH_BLOCK_SECONDS = '240'
		$env:RUNNER_TEST_KILL_FAULT = $HardCase.Fault
		$BlockStarted = [DateTime]::UtcNow
		$Result = Invoke-PhaseGate $Fixture 'ValidateProvenance' @('-PhaseFinalizeGraceSeconds', '5') '12345' 'fixture-runner' '0.25'
		$BlockElapsed = ([DateTime]::UtcNow - $BlockStarted).TotalSeconds
		$env:RUNNER_TEST_HASH_BLOCK_SECONDS = ''
		$env:RUNNER_TEST_KILL_FAULT = ''
		Assert-ReportReason $Result $HardCase.Reason "$($HardCase.Name) must classify the blocked pre-work hash as $($HardCase.Reason)"
		Assert-True (@((Read-Report $Result).checks | Where-Object { $_.name -eq 'phase-hard-deadline' -and $_.message -like ($HardCase.Reason + '*') }).Count -eq 1) "$($HardCase.Name) must be enforced by the supervisor hard bound, not the cooperative deadline."
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
	$Result = Invoke-PhaseGate $Fixture 'SmokePhase' @() '12345' 'fixture-runner' '0'
	Assert-ReportReason $Result 'handoff_context_invalid' 'SmokePhase without a positive phase-work timeout must be rejected'

	$Fixture = New-Case 'phase-smoke-hang'
	[void] (Invoke-PhaseGate $Fixture 'PackageClient')
	[void] (Invoke-PhaseGate $Fixture 'PackageServer')
	[void] (Invoke-PhaseGate $Fixture 'ValidateProvenance')
	$env:RUNNER_TEST_SMOKE_HANG = '120'
	$HangStarted = [DateTime]::UtcNow
	$Result = Invoke-PhaseGate $Fixture 'SmokePhase' @() '12345' 'fixture-runner' '0.4'
	$HangElapsed = ([DateTime]::UtcNow - $HangStarted).TotalSeconds
	$env:RUNNER_TEST_SMOKE_HANG = ''
	Assert-ReportReason $Result 'phase_timeout' 'A hanging smoke must fail as phase_timeout under the script watchdog'
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
		$Fixture = New-Case $KillCase.Name
		$env:RUNNER_TEST_PHASE_SPAWN = '1'
		$env:RUNNER_TEST_PHASE_SLEEP = '90'
		$env:RUNNER_TEST_KILL_FAULT = $KillCase.Fault
		$Result = Invoke-PhaseGate $Fixture 'PackageClient' @() '12345' 'fixture-runner' '0.1'
		$env:RUNNER_TEST_PHASE_SPAWN = ''
		$env:RUNNER_TEST_PHASE_SLEEP = ''
		$env:RUNNER_TEST_KILL_FAULT = ''
		Assert-ReportReason $Result $KillCase.Reason "$($KillCase.Name) must report $($KillCase.Reason)"
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
		Assert-ReportReason $Result $TamperCase.Reason "A tampered client manifest ($($TamperCase.Name)) must fail closed"
		Set-Content $ClientManifestPath -Value $OriginalManifest -Encoding UTF8
	}
	$ClientPayloadRecord = Join-Path $RunDirectory 'client\phase-client.json'
	$AsidePath = Join-Path $Fixture.Root 'phase-client-aside.json'
	Move-Item $ClientPayloadRecord $AsidePath
	Set-Content (Join-Path $RunDirectory 'client\extra-substitute.bin') 'substituted' -Encoding UTF8
	$Result = Invoke-PhaseGate $Fixture 'ValidateProvenance'
	Assert-ReportReason $Result 'handoff_digest_mismatch' 'An omitted-plus-extra payload set with an unchanged file count must fail closed'
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
	Assert-ReportReason $Result 'handoff_payload_invalid' 'A junction at the payload directory must be rejected before any digest use'
	[IO.Directory]::Delete((Join-Path $RunDirectory 'server'))

	$Fixture = New-Case 'phase-junction-scope'
	New-Item -ItemType Directory -Path (Join-Path $Fixture.Root 'owner-real') | Out-Null
	New-Item -ItemType Junction -Path (Join-Path $Fixture.Handoff 'owner') -Value (Join-Path $Fixture.Root 'owner-real') | Out-Null
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-ReportReason $Result 'handoff_root_invalid' 'A junction at the repository-scope ancestor must be rejected'
	[IO.Directory]::Delete((Join-Path $Fixture.Handoff 'owner'))

	$Fixture = New-Case 'phase-root-unc'
	$env:AETHELN_HANDOFF_ROOT = '\\fixture-host\handoff-share'
	$Result = Invoke-PhaseGate $Fixture 'PackageClient'
	Assert-ReportReason $Result 'handoff_root_invalid' 'A UNC handoff root must be rejected as non-local'

	$Fixture = New-Case 'phase-root-cap-cross-scope'
	$OtherScope = Join-Path $Fixture.Handoff 'other\repo2'
	New-Item -ItemType Directory -Path $OtherScope -Force | Out-Null
	[IO.File]::WriteAllBytes((Join-Path $OtherScope 'blob.bin'), (New-Object byte[] 600000))
	$Result = Invoke-PhaseGate $Fixture 'PackageClient' @('-HandoffPayloadCapBytes', '500000', '-HandoffRootCapBytes', '1000000')
	Assert-ReportReason $Result 'handoff_storage_exhausted' 'Bytes in another repository scope must count toward the total root cap'
	Assert-True (-not (Test-Path (Get-PhaseRunDirectory $Fixture))) 'Cross-scope exhaustion must not create the run directory.'

	$Fixture = New-Case 'phase-scope-namespace'
	$Result = Invoke-PhaseGate $Fixture 'PackageClient' @() '12345' 'fixture-runner' '5' 'a/b-c'
	Assert-True ($Result.ExitCode -eq 0) "PackageClient for a/b-c must pass. Output: $($Result.Output)"
	$Result = Invoke-PhaseGate $Fixture 'PackageClient' @() '12345' 'fixture-runner' '5' 'a-b/c'
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
	Assert-ReportReason $Result 'handoff_runner_mismatch' 'A run-context record bound to another runner must fail closed'
	Remove-Item $ContextPath
	$Result = Invoke-PhaseGate $Fixture 'PackageServer'
	Assert-ReportReason $Result 'handoff_context_invalid' 'A run directory without its run-context record must fail closed'
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
	New-FixtureRunContext $Fixture (Join-Path $ScopeRoot 'run-901-attempt-1') '901' '1'
	New-FixtureRunContext $Fixture (Join-Path $ScopeRoot 'run-903-attempt-1') '903' '1'
	Set-Content (Join-Path $ScopeRoot 'run-903-attempt-1\milestone-complete.json') 'not-json' -Encoding UTF8
	New-FixtureRunContext $Fixture (Join-Path $ScopeRoot 'run-904-attempt-1') '999' '1'
	New-FixtureRunContext $Fixture (Join-Path $ScopeRoot 'run-905-attempt-1') '905' '1'
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

	Write-Output 'PASS: engine runner wrapper contracts are completely covered'
} finally {
	$env:PATH = $Original.PATH
	$env:AETHELN_ENGINE_ROOT = $Original.Engine
	$env:AETHELN_LINUX_TOOLCHAIN_ROOT = $Original.Toolchain
	$env:AETHELN_HANDOFF_ROOT = $Original.Handoff
	@('RUNNER_TEST_REPOSITORY','RUNNER_TEST_ALT_REVISION','RUNNER_TEST_BUILD_CAPTURE','RUNNER_TEST_PACKAGE_CAPTURE','RUNNER_TEST_SMOKE_CAPTURE','RUNNER_TEST_WSL_CAPTURE','RUNNER_TEST_MUTATION','RUNNER_TEST_FAIL_TARGET','RUNNER_TEST_AMBIGUOUS','RUNNER_TEST_INTERNAL','RUNNER_TEST_SMOKE_FAIL','RUNNER_TEST_SMOKE_HANG','RUNNER_TEST_PHASE_SLEEP','RUNNER_TEST_PHASE_FAIL','RUNNER_TEST_PHASE_SPAWN','RUNNER_TEST_KILL_FAULT','RUNNER_TEST_HASH_BLOCK_SECONDS','RUNNER_TEST_DESCENDANT_EXE','RUNNER_TEST_WSLPATH_OUTPUT','RUNNER_TEST_HOSTNAME_OUTPUT','RUNNER_TEST_WSLPATH_EXIT','RUNNER_TEST_HOSTNAME_EXIT') | ForEach-Object { Remove-Item -LiteralPath ('Env:' + $_) -ErrorAction Ignore }
	if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
}
