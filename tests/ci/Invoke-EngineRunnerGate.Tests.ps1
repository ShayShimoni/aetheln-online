[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SourceScript = Join-Path $RepositoryRoot 'scripts/ci/Invoke-EngineRunnerGate.ps1'
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('AethelnEngineRunnerTests-{0}' -f [guid]::NewGuid().ToString('N'))
$PowerShell = (Get-Process -Id $PID).Path
$OriginalPath = $env:PATH
$OriginalEngine = [Environment]::GetEnvironmentVariable('AETHELN_ENGINE_ROOT', 'Process')
$OriginalToolchain = [Environment]::GetEnvironmentVariable('AETHELN_LINUX_TOOLCHAIN_ROOT', 'Process')

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function New-Fixture([string] $Name) {
	$Root = Join-Path $FixtureRoot $Name
	$Repo = Join-Path $Root 'repo'
	New-Item -ItemType Directory -Path (Join-Path $Repo 'scripts/ci'), (Join-Path $Repo 'scripts/build'), (Join-Path $Root 'engine'), (Join-Path $Root 'toolchain'), (Join-Path $Root 'bin') -Force | Out-Null
	Copy-Item -LiteralPath $SourceScript -Destination (Join-Path $Repo 'scripts/ci/Invoke-EngineRunnerGate.ps1')
	Set-Content -LiteralPath (Join-Path $Repo 'AethelnOnline.uproject') -Value '{}' -Encoding UTF8
	return [ordered]@{
		Root = $Root
		Repo = $Repo
		Engine = Join-Path $Root 'engine'
		Toolchain = Join-Path $Root 'toolchain'
		Archive = Join-Path $Root 'archive'
		Logs = Join-Path $Root 'logs'
		Bin = Join-Path $Root 'bin'
		BuildCapture = Join-Path $Root 'build.json'
		SmokeCapture = Join-Path $Root 'smoke.json'
		WslCapture = Join-Path $Root 'wsl.jsonl'
	}
}

function Install-Fakes($Fixture, [int] $BuildExit = 0, [int] $SmokeExit = 0) {
	$BuildBody = @'
[param()]param(
	[string] $ProjectPath, [string] $EngineRoot, [string] $LinuxToolchainRoot,
	[string] $ArchiveRoot, [string] $LogRoot, [string] $SourceRevision,
	[string] $Configuration, [string] $Map
)
@{ ProjectPath=$ProjectPath; EngineRoot=$EngineRoot; LinuxToolchainRoot=$LinuxToolchainRoot; ArchiveRoot=$ArchiveRoot; LogRoot=$LogRoot; SourceRevision=$SourceRevision; Configuration=$Configuration; Map=$Map } | ConvertTo-Json | Set-Content -LiteralPath $env:AETHELN_TEST_BUILD_CAPTURE -Encoding UTF8
if ([int] $env:AETHELN_TEST_BUILD_EXIT -ne 0) {
	Write-Output ("Compiler error C1234: actionable build diagnostic at {0}" -f (Join-Path $EngineRoot 'Engine/Source/Build.cpp'))
	Write-Output 'Authorization Bearer ghp_build_marker'
	Write-Output '  API_KEY=build_assignment_marker'
	Write-Output 'Name                           Value'
	Write-Output '----                           -----'
	Write-Output 'BUILD_ENV                      build_table_marker'
	Write-Output 'AWS_ACCESS_KEY_ID AKIA1234567890ABCDEF'
	Write-Output 'ConnectionString build_connection_marker'
	Write-Output 'unlabelledBearerValue0123456789abcdefghijklmnop'
	throw 'deliberately revealing build failure'
}
New-Item -ItemType Directory -Path (Join-Path $ArchiveRoot 'WindowsClient/Windows'), (Join-Path $ArchiveRoot 'LinuxServer/Linux'), $LogRoot -Force | Out-Null
Set-Content -LiteralPath (Join-Path $ArchiveRoot 'WindowsClient/Windows/AethelnOnlineClient.exe') -Value client
Set-Content -LiteralPath (Join-Path $ArchiveRoot 'LinuxServer/Linux/AethelnOnlineServer.sh') -Value server
'@
	$BuildBody = $BuildBody.Replace('[param()]', '')
	Set-Content -LiteralPath (Join-Path $Fixture.Repo 'scripts/build/Build-PackagedArtifacts.ps1') -Value $BuildBody -Encoding UTF8
	Set-Content -LiteralPath (Join-Path $Fixture.Repo 'scripts/build/Invoke-PackagedSmokeTest.ps1') -Value @'
param(
	[string] $ServerExecutable, [string] $ServerLauncherExecutable, [string[]] $ServerLauncherArguments,
	[string] $ClientExecutable, [string[]] $ClientBaseArguments, [string] $ServerEndpoint,
	[string] $ServerMap, [string] $LogRoot, [string] $ServerReadyPattern,
	[string] $ServerClientConnectedPattern, [string] $ClientConnectedPattern,
	[string] $ClientMapPattern, [int] $TimeoutSeconds
)
@{ ServerExecutable=$ServerExecutable; ServerLauncherExecutable=$ServerLauncherExecutable; ServerLauncherArguments=$ServerLauncherArguments; ClientExecutable=$ClientExecutable; ClientBaseArguments=$ClientBaseArguments; ServerEndpoint=$ServerEndpoint; ServerMap=$ServerMap; LogRoot=$LogRoot; ServerReadyPattern=$ServerReadyPattern; ServerClientConnectedPattern=$ServerClientConnectedPattern; ClientConnectedPattern=$ClientConnectedPattern; ClientMapPattern=$ClientMapPattern; TimeoutSeconds=$TimeoutSeconds } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $env:AETHELN_TEST_SMOKE_CAPTURE -Encoding UTF8
if ([int] $env:AETHELN_TEST_SMOKE_EXIT -ne 0) {
	Write-Output ("Smoke error NET001: actionable timeout diagnostic for {0}" -f $ServerExecutable)
	Write-Output 'token smoke_bearer_marker'
	Write-Output '  PASSWORD=smoke_assignment_marker'
	Write-Output 'Name                           Value'
	Write-Output '----                           -----'
	Write-Output 'SMOKE_ENV                      smoke_table_marker'
	Write-Output 'AWS_ACCESS_KEY_ID AKIA1234567890ABCDEF'
	Write-Output 'ConnectionString smoke_connection_marker'
	Write-Output 'unlabelledSmokeBearer0123456789abcdefghijklmnop'
	throw 'deliberately revealing smoke failure'
}
'@ -Encoding UTF8
	$FakeWslSource = @'
using System;
using System.IO;
using System.Web.Script.Serialization;
public static class FakeWsl {
	public static int Main(string[] args) {
		File.AppendAllText(Environment.GetEnvironmentVariable("AETHELN_TEST_WSL_CAPTURE"), new JavaScriptSerializer().Serialize(args) + Environment.NewLine);
		bool path = Array.IndexOf(args, "wslpath") >= 0;
		string output = Environment.GetEnvironmentVariable(path ? "AETHELN_TEST_WSLPATH_OUTPUT" : "AETHELN_TEST_HOSTNAME_OUTPUT");
		if (output != null) Console.Write(output.Replace("\\n", Environment.NewLine));
		string code = Environment.GetEnvironmentVariable(path ? "AETHELN_TEST_WSLPATH_EXIT" : "AETHELN_TEST_HOSTNAME_EXIT");
		return String.IsNullOrEmpty(code) ? 0 : Int32.Parse(code);
	}
}
'@
	Add-Type -TypeDefinition $FakeWslSource -ReferencedAssemblies System.Web.Extensions -OutputAssembly (Join-Path $Fixture.Bin 'wsl.exe') -OutputType ConsoleApplication
	$env:AETHELN_TEST_BUILD_CAPTURE = $Fixture.BuildCapture
	$env:AETHELN_TEST_SMOKE_CAPTURE = $Fixture.SmokeCapture
	$env:AETHELN_TEST_WSL_CAPTURE = $Fixture.WslCapture
	$env:AETHELN_TEST_BUILD_EXIT = [string] $BuildExit
	$env:AETHELN_TEST_SMOKE_EXIT = [string] $SmokeExit
	$env:AETHELN_TEST_WSLPATH_OUTPUT = '/mnt/d/archive/LinuxServer/Linux/AethelnOnlineServer.sh'
	$env:AETHELN_TEST_HOSTNAME_OUTPUT = '172.25.32.7 '
	$env:AETHELN_TEST_WSLPATH_EXIT = '0'
	$env:AETHELN_TEST_HOSTNAME_EXIT = '0'
	$env:PATH = $Fixture.Bin + [System.IO.Path]::PathSeparator + $OriginalPath
	[Environment]::SetEnvironmentVariable('AETHELN_ENGINE_ROOT', $Fixture.Engine, 'Process')
	[Environment]::SetEnvironmentVariable('AETHELN_LINUX_TOOLCHAIN_ROOT', $Fixture.Toolchain, 'Process')
}

function Invoke-Gate($Fixture, [string] $Mode = 'Compile') {
	$PreviousErrorActionPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = 'Continue'
		$Output = @(& $PowerShell -NoProfile -File (Join-Path $Fixture.Repo 'scripts/ci/Invoke-EngineRunnerGate.ps1') -Mode $Mode -RepositoryRoot $Fixture.Repo -SourceRevision '87b311cc3bdf7acdc4542b89435c288ce6a3f933' -ArchiveRoot $Fixture.Archive -LogRoot $Fixture.Logs 2>&1)
		$ExitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $PreviousErrorActionPreference
	}
	return [ordered]@{ ExitCode=$ExitCode; Output=($Output -join [Environment]::NewLine); Report=(Join-Path $Fixture.Repo 'TestResults/engine-runner-report.json') }
}

try {
	New-Item -ItemType Directory -Path $FixtureRoot | Out-Null

	$Compile = New-Fixture 'compile-success'
	Install-Fakes $Compile
	$Result = Invoke-Gate $Compile
	Assert-True ($Result.ExitCode -eq 0) 'Compile should succeed.'
	$Build = Get-Content -LiteralPath $Compile.BuildCapture -Raw | ConvertFrom-Json
	Assert-True ($Build.ProjectPath -eq (Join-Path $Compile.Repo 'AethelnOnline.uproject')) 'The exact project descriptor should be passed.'
	Assert-True ($Build.Configuration -eq 'Development' -and $Build.Map -eq '/Game/Maps/StarterMap') 'The frozen configuration and map should be passed.'
	Assert-True ($Build.SourceRevision -eq '87b311cc3bdf7acdc4542b89435c288ce6a3f933') 'The supplied revision should be passed.'
	Assert-True (-not (Test-Path -LiteralPath $Compile.SmokeCapture)) 'Compile must not run smoke.'
	Write-Output 'PASS: Compile delegates the complete supported client/server build contract once'

	$Smoke = New-Fixture 'smoke-success'
	Install-Fakes $Smoke
	$Result = Invoke-Gate $Smoke 'PackagedSmoke'
	Assert-True ($Result.ExitCode -eq 0) 'PackagedSmoke should succeed.'
	$WslCalls = @(Get-Content -LiteralPath $Smoke.WslCapture | ForEach-Object { $_ | ConvertFrom-Json })
	Assert-True ($WslCalls.Count -eq 2) 'Exactly one conversion and one address lookup are required.'
	$ExpectedPrefix = @('-d', 'Ubuntu', '-u', 'aethelnqa', '--', 'wslpath')
	for ($Index = 0; $Index -lt $ExpectedPrefix.Count; $Index++) { Assert-True ($WslCalls[0][$Index] -eq $ExpectedPrefix[$Index]) "wslpath argument $Index should match." }
	Assert-True ($WslCalls[0].Count -eq 7 -and $WslCalls[0][6] -like '*AethelnOnlineServer.sh') 'wslpath must receive exactly the six frozen launcher arguments plus the discovered Windows path.'
	Assert-True (($WslCalls[1] -join '|') -eq '-d|Ubuntu|-u|aethelnqa|--|hostname|-I') 'The approved hostname -I command should run immediately before smoke.'
	$SmokeCall = Get-Content -LiteralPath $Smoke.SmokeCapture -Raw | ConvertFrom-Json
	Assert-True ($SmokeCall.ServerExecutable -eq '/mnt/d/archive/LinuxServer/Linux/AethelnOnlineServer.sh') 'Smoke should receive the translated server path.'
	Assert-True ($SmokeCall.ServerEndpoint -eq '172.25.32.7:7777') 'Smoke should use the current WSL guest address and port 7777.'
	Assert-True (($SmokeCall.ServerLauncherArguments -join '|') -eq '-d|Ubuntu|-u|aethelnqa|--exec|{ServerExecutable}|{ServerMap}|-port=7777|-stdout|-FullStdOutLogOutput') 'Server launcher arguments should match the proven contract.'
	Assert-True (($SmokeCall.ClientBaseArguments -join '|') -eq '{ServerEndpoint}|-stdout|-FullStdOutLogOutput') 'Client arguments should match the proven contract.'
	Assert-True ($SmokeCall.ServerReadyPattern -eq 'GameNetDriver.*Listening' -and $SmokeCall.ClientConnectedPattern -eq 'Welcomed by server' -and $SmokeCall.ClientMapPattern -eq 'LoadMap:.*StarterMap') 'Smoke regex contracts should be frozen.'
	Write-Output 'PASS: PackagedSmoke performs exact discovery, WSL conversion, address lookup, and smoke delegation'

	foreach ($Case in @(
		@{ Name='nonzero'; Exit='9'; Output='/valid/path'; Reason='wslpath_exit_nonzero' },
		@{ Name='empty'; Exit='0'; Output=''; Reason='wslpath_line_count_invalid' },
		@{ Name='multiline'; Exit='0'; Output='/one\n/two'; Reason='wslpath_line_count_invalid' },
		@{ Name='relative'; Exit='0'; Output='relative/server'; Reason='wslpath_result_invalid' }
	)) {
		$Fixture = New-Fixture ('wslpath-' + $Case.Name)
		Install-Fakes $Fixture
		$env:AETHELN_TEST_WSLPATH_EXIT = $Case.Exit
		$env:AETHELN_TEST_WSLPATH_OUTPUT = $Case.Output
		$Result = Invoke-Gate $Fixture 'PackagedSmoke'
		Assert-True ($Result.ExitCode -ne 0 -and $Result.Output -match $Case.Reason) "$($Case.Name) wslpath output should fail with a safe reason."
		Assert-True (-not (Test-Path -LiteralPath $Fixture.SmokeCapture)) 'Invalid conversion must fail before smoke.'
	}
	Write-Output 'PASS: nonzero, empty, multiline, and relative wslpath results fail closed'

	foreach ($Variable in @('AETHELN_ENGINE_ROOT', 'AETHELN_LINUX_TOOLCHAIN_ROOT')) {
		$Fixture = New-Fixture ('missing-' + $Variable)
		Install-Fakes $Fixture
		[Environment]::SetEnvironmentVariable($Variable, $null, 'Process')
		$Result = Invoke-Gate $Fixture
		Assert-True ($Result.ExitCode -ne 0 -and (Test-Path -LiteralPath $Result.Report)) "$Variable absence should fail and report."
	}
	$Fixture = New-Fixture 'nonexistent-root'
	Install-Fakes $Fixture
	[Environment]::SetEnvironmentVariable('AETHELN_ENGINE_ROOT', (Join-Path $Fixture.Root 'absent-secret-root'), 'Process')
	$Result = Invoke-Gate $Fixture
	Assert-True ($Result.ExitCode -ne 0 -and $Result.Output -match 'engine_root_invalid') 'A nonexistent engine root should fail safely.'
	Write-Output 'PASS: required environment roots are validated without enumeration'

	$Fixture = New-Fixture 'build-failure'
	Install-Fakes $Fixture -BuildExit 1
	$Result = Invoke-Gate $Fixture
	$Report = Get-Content -LiteralPath $Result.Report -Raw | ConvertFrom-Json
	Assert-True ($Result.ExitCode -ne 0 -and $Report.summary.requiredFailed -eq 1) 'A child build failure should produce required failure semantics.'
	Assert-True ($Report.schemaVersion -eq 1 -and $Report.mode -eq 'Compile' -and $Report.revision -eq '87b311cc3bdf7acdc4542b89435c288ce6a3f933') 'The frozen report identity should be present.'
	Assert-True ($null -ne $Report.startedUtc -and $null -ne $Report.finishedUtc -and $Report.checks.Count -eq 2) 'The report should contain bounded timing and checks.'
	foreach ($Check in $Report.checks) {
		foreach ($Property in @('name', 'tier', 'status', 'durationSeconds', 'command', 'message')) { Assert-True ($null -ne $Check.$Property) "Check property $Property should exist." }
	}
	$BuildFailureMessage = [string] @($Report.checks | Where-Object { $_.name -eq 'supported-client-server-build' })[0].message
	Assert-True ($BuildFailureMessage -match 'build_failed' -and $BuildFailureMessage -match 'C1234' -and $BuildFailureMessage -match 'actionable build diagnostic') 'The report should retain a bounded actionable build diagnostic.'
	Assert-True ($BuildFailureMessage.Length -le 4120) 'The reason plus diagnostic must remain bounded.'
	$Sensitive = @($Fixture.Engine, $Fixture.Toolchain, (Join-Path $Fixture.Archive 'LinuxServer/Linux/AethelnOnlineServer.sh'), '/mnt/d/archive/LinuxServer/Linux/AethelnOnlineServer.sh')
	$DisclosureSurface = $Result.Output + (Get-Content -LiteralPath $Result.Report -Raw)
	foreach ($Value in $Sensitive) { Assert-True (-not $DisclosureSurface.Contains($Value)) 'Console and report output must not disclose protected paths.' }
	foreach ($Value in @('ghp_build_marker', 'build_assignment_marker', 'build_table_marker', 'AKIA1234567890ABCDEF', 'build_connection_marker', 'unlabelledBearerValue')) { Assert-True (-not $DisclosureSurface.Contains($Value)) 'Build diagnostics must reject credential, token, and environment-dump values.' }
	Assert-True ($Result.Output -notmatch 'C1234') 'Captured diagnostics must not be echoed to the console.'

	$Fixture = New-Fixture 'smoke-failure'
	Install-Fakes $Fixture -SmokeExit 1
	$Result = Invoke-Gate $Fixture 'PackagedSmoke'
	$Report = Get-Content -LiteralPath $Result.Report -Raw | ConvertFrom-Json
	$SmokeFailureMessage = [string] @($Report.checks | Where-Object { $_.name -eq 'packaged-build-smoke' })[0].message
	Assert-True ($Result.ExitCode -ne 0 -and $SmokeFailureMessage -match 'smoke_failed' -and $SmokeFailureMessage -match 'NET001' -and $SmokeFailureMessage -match 'actionable timeout diagnostic') 'The report should retain a bounded actionable smoke diagnostic.'
	Assert-True ($SmokeFailureMessage.Length -le 4120) 'The smoke reason plus diagnostic must remain bounded.'
	$DisclosureSurface = $Result.Output + (Get-Content -LiteralPath $Result.Report -Raw)
	foreach ($Value in @($Fixture.Engine, $Fixture.Toolchain, '/mnt/d/archive/LinuxServer/Linux/AethelnOnlineServer.sh')) { Assert-True (-not $DisclosureSurface.Contains($Value)) 'Smoke diagnostics must not disclose protected paths.' }
	foreach ($Value in @('smoke_bearer_marker', 'smoke_assignment_marker', 'smoke_table_marker', 'AKIA1234567890ABCDEF', 'smoke_connection_marker', 'unlabelledSmokeBearer')) { Assert-True (-not $DisclosureSurface.Contains($Value)) 'Smoke diagnostics must reject credential, token, and environment-dump values.' }
	Assert-True ($Result.Output -notmatch 'NET001') 'Captured smoke diagnostics must not be echoed to the console.'
	Write-Output 'PASS: handled child failures write bounded actionable redacted reports and exit nonzero'

	foreach ($Kind in @('client', 'server')) {
		$Fixture = New-Fixture ('ambiguous-' + $Kind)
		Install-Fakes $Fixture
		if ($Kind -eq 'client') {
			New-Item -ItemType Directory -Path $Fixture.Archive -Force | Out-Null
			# Build creates the first candidate; this fake build extension creates another.
			Add-Content -LiteralPath (Join-Path $Fixture.Repo 'scripts/build/Build-PackagedArtifacts.ps1') -Value "Set-Content -LiteralPath (Join-Path `$ArchiveRoot 'WindowsClient/Windows/AethelnOnline.exe') -Value client2"
		} else {
			Add-Content -LiteralPath (Join-Path $Fixture.Repo 'scripts/build/Build-PackagedArtifacts.ps1') -Value "Set-Content -LiteralPath (Join-Path `$ArchiveRoot 'LinuxServer/Linux/second-AethelnOnlineServer.sh') -Value ignored`nSet-Content -LiteralPath (Join-Path `$ArchiveRoot 'LinuxServer/AethelnOnlineServer.sh') -Value server2"
		}
		$Result = Invoke-Gate $Fixture 'PackagedSmoke'
		Assert-True ($Result.ExitCode -ne 0) "Ambiguous $Kind discovery should fail closed."
	}
	Write-Output 'PASS: executable discovery rejects ambiguous archives'
}
finally {
	$env:PATH = $OriginalPath
	[Environment]::SetEnvironmentVariable('AETHELN_ENGINE_ROOT', $OriginalEngine, 'Process')
	[Environment]::SetEnvironmentVariable('AETHELN_LINUX_TOOLCHAIN_ROOT', $OriginalToolchain, 'Process')
	foreach ($Name in @('AETHELN_TEST_BUILD_CAPTURE','AETHELN_TEST_SMOKE_CAPTURE','AETHELN_TEST_WSL_CAPTURE','AETHELN_TEST_BUILD_EXIT','AETHELN_TEST_SMOKE_EXIT','AETHELN_TEST_WSLPATH_OUTPUT','AETHELN_TEST_HOSTNAME_OUTPUT','AETHELN_TEST_WSLPATH_EXIT','AETHELN_TEST_HOSTNAME_EXIT')) { Remove-Item -LiteralPath ('Env:' + $Name) -ErrorAction SilentlyContinue }
	if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
}
