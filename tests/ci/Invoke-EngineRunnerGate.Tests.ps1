param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path (Split-Path $PSScriptRoot)
$SourceScript = Join-Path $RepositoryRoot 'scripts/ci/Invoke-EngineRunnerGate.ps1'
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
$PowerShell = (Get-Process -Id $PID).Path
$Original = @{ PATH = $env:PATH; Engine = $env:AETHELN_ENGINE_ROOT; Toolchain = $env:AETHELN_LINUX_TOOLCHAIN_ROOT }

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
	$Fixture = @{
		Root = $Root; Repository = $Repository; Engine = $Engine; Toolchain = Join-Path $Root 'toolchain'
		BuildBatch = Join-Path $BatchRoot 'Build.bat'; Bin = Join-Path $Root 'bin'
		Archive = Join-Path $Root 'archive'; Logs = Join-Path $Root 'logs'
		BuildCapture = Join-Path $Root 'build.txt'; PackageCapture = Join-Path $Root 'package.jsonl'
		SmokeCapture = Join-Path $Root 'smoke.json'; WslCapture = Join-Path $Root 'wsl.jsonl'
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
	Write-Fixture (Join-Path $Fixture.Repository 'scripts/build/Build-PackagedArtifacts.ps1') 'param($ProjectPath,$EngineRoot,$LinuxToolchainRoot,$ArchiveRoot,$LogRoot,$SourceRevision,$Configuration,$Map)
@{ProjectPath=$ProjectPath;EngineRoot=$EngineRoot;LinuxToolchainRoot=$LinuxToolchainRoot;ArchiveRoot=$ArchiveRoot;LogRoot=$LogRoot;SourceRevision=$SourceRevision;Configuration=$Configuration;Map=$Map}|ConvertTo-Json -Compress|Add-Content $env:RUNNER_TEST_PACKAGE_CAPTURE
New-Item -ItemType Directory -Force -Path (Join-Path $ArchiveRoot "w"),(Join-Path $ArchiveRoot "l"),$LogRoot|Out-Null
Set-Content (Join-Path $ArchiveRoot "w/AethelnOnlineClient.exe") client
Set-Content (Join-Path $ArchiveRoot "l/AethelnOnlineServer.sh") server
if($env:RUNNER_TEST_AMBIGUOUS -eq "client"){Set-Content (Join-Path $ArchiveRoot "w/AethelnOnline.exe") client2}
if($env:RUNNER_TEST_AMBIGUOUS -eq "server"){New-Item -ItemType Directory -Force (Join-Path $ArchiveRoot "l2")|Out-Null;Set-Content (Join-Path $ArchiveRoot "l2/AethelnOnlineServer.sh") server2}'
	Write-Fixture (Join-Path $Fixture.Repository 'scripts/build/Invoke-PackagedSmokeTest.ps1') 'param($ServerExecutable,$ServerLauncherExecutable,$ServerLauncherArguments,$ClientExecutable,$ClientBaseArguments,$ServerEndpoint,$ServerMap,$LogRoot,$ServerReadyPattern,$ServerClientConnectedPattern,$ClientConnectedPattern,$ClientMapPattern,$TimeoutSeconds)
@{ServerExecutable=$ServerExecutable;ServerLauncherExecutable=$ServerLauncherExecutable;ServerLauncherArguments=$ServerLauncherArguments;ClientExecutable=$ClientExecutable;ClientBaseArguments=$ClientBaseArguments;ServerEndpoint=$ServerEndpoint;ServerMap=$ServerMap;LogRoot=$LogRoot;ServerReadyPattern=$ServerReadyPattern;ServerClientConnectedPattern=$ServerClientConnectedPattern;ClientConnectedPattern=$ClientConnectedPattern;ClientMapPattern=$ClientMapPattern;TimeoutSeconds=$TimeoutSeconds}|ConvertTo-Json -Depth 4|Set-Content $env:RUNNER_TEST_SMOKE_CAPTURE
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
	$env:RUNNER_TEST_SMOKE_FAIL = ''
	$env:RUNNER_TEST_WSLPATH_OUTPUT = '/mnt/d/archive/LinuxServer/Linux/AethelnOnlineServer.sh'
	$env:RUNNER_TEST_HOSTNAME_OUTPUT = '172.25.32.7 '
	$env:RUNNER_TEST_WSLPATH_EXIT = '0'
	$env:RUNNER_TEST_HOSTNAME_EXIT = '0'
	$env:PATH = $Fixture.Bin + [IO.Path]::PathSeparator + $Original.PATH
	$env:AETHELN_ENGINE_ROOT = $Fixture.Engine
	$env:AETHELN_LINUX_TOOLCHAIN_ROOT = $Fixture.Toolchain
}
function Invoke-Gate($Fixture, [string] $Mode = 'Compile', [string] $Revision = $Fixture.Revision) {
	$Previous = $ErrorActionPreference
	try {
		$ErrorActionPreference = 'Continue'
		$Output = @(& $PowerShell -NoProfile -File (Join-Path $Fixture.Repository 'scripts/ci/Invoke-EngineRunnerGate.ps1') -Mode $Mode -RepositoryRoot $Fixture.Repository -SourceRevision $Revision -ArchiveRoot $Fixture.Archive -LogRoot $Fixture.Logs 2>&1)
		$ExitCode = $LASTEXITCODE
	} finally { $ErrorActionPreference = $Previous }
	return @{ ExitCode = $ExitCode; Output = $Output -join "`n"; Report = Join-Path $Fixture.Repository 'TestResults/engine-runner-report.json' }
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

	Write-Output 'PASS: engine runner wrapper contracts are completely covered'
} finally {
	$env:PATH = $Original.PATH
	$env:AETHELN_ENGINE_ROOT = $Original.Engine
	$env:AETHELN_LINUX_TOOLCHAIN_ROOT = $Original.Toolchain
	@('RUNNER_TEST_REPOSITORY','RUNNER_TEST_ALT_REVISION','RUNNER_TEST_BUILD_CAPTURE','RUNNER_TEST_PACKAGE_CAPTURE','RUNNER_TEST_SMOKE_CAPTURE','RUNNER_TEST_WSL_CAPTURE','RUNNER_TEST_MUTATION','RUNNER_TEST_FAIL_TARGET','RUNNER_TEST_AMBIGUOUS','RUNNER_TEST_SMOKE_FAIL','RUNNER_TEST_WSLPATH_OUTPUT','RUNNER_TEST_HOSTNAME_OUTPUT','RUNNER_TEST_WSLPATH_EXIT','RUNNER_TEST_HOSTNAME_EXIT') | ForEach-Object { Remove-Item -LiteralPath ('Env:' + $_) -ErrorAction Ignore }
	if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
}
