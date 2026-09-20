param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path (Split-Path $PSScriptRoot)
$SourceScript = Join-Path $RepositoryRoot 'scripts/ci/Invoke-EngineRunnerGate.ps1'
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnPostCommandState-' + [guid]::NewGuid().ToString('N'))
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
	$Toolchain = Join-Path $Root 'toolchain'
	$Bin = Join-Path $Root 'bin'
	New-Item -ItemType Directory -Force -Path (Join-Path $Repository 'scripts/ci'), (Join-Path $Repository 'scripts/build'), $BatchRoot, $Toolchain, $Bin | Out-Null
	Copy-Item -LiteralPath $SourceScript -Destination (Join-Path $Repository 'scripts/ci/Invoke-EngineRunnerGate.ps1')
	Write-Fixture (Join-Path $Repository 'AethelnOnline.uproject') '{}'
	Write-Fixture (Join-Path $Repository '.gitignore') "TestResults/`n"
	Write-Fixture (Join-Path $Repository 'tracked') 'clean'
	$Fixture = @{
		Root = $Root
		Repository = $Repository
		Engine = $Engine
		Toolchain = $Toolchain
		Bin = $Bin
		BuildBatch = Join-Path $BatchRoot 'Build.bat'
		Archive = Join-Path $Root 'archive'
		Logs = Join-Path $Root 'logs'
	}
	Invoke-FixtureGit $Fixture @('init', '-q')
	Invoke-FixtureGit $Fixture @('add', '.')
	& git -C $Repository -c user.name=test -c user.email=test@invalid commit -qm base
	if ($LASTEXITCODE -ne 0) { throw 'git fixture commit failed' }
	$Fixture.Revision = Get-FixtureRevision $Fixture
	return $Fixture
}

function Install-FakeTool($Fixture) {
	Write-Fixture $Fixture.BuildBatch '@echo off
if "%RUNNER_POST_CASE%"=="client-dirty" if "%1"=="AethelnOnlineClient" (
  echo changed>"%RUNNER_POST_REPOSITORY%\tracked"
  exit /b 9
)
if "%RUNNER_POST_CASE%"=="server-revision" if "%1"=="AethelnOnlineServer" (
  git -C "%RUNNER_POST_REPOSITORY%" update-ref HEAD %RUNNER_POST_ALT_REVISION%
  exit /b 9
)
exit /b 0'

	Write-Fixture (Join-Path $Fixture.Repository 'scripts/build/Build-PackagedArtifacts.ps1') 'param($ProjectPath,$EngineRoot,$LinuxToolchainRoot,$ArchiveRoot,$LogRoot,$SourceRevision,$Configuration,$Map)
if ($env:RUNNER_POST_CASE -eq "package-dirty") {
	Set-Content -LiteralPath (Join-Path $env:RUNNER_POST_REPOSITORY "tracked") -Value changed
	throw "package failed"
}
New-Item -ItemType Directory -Force -Path (Join-Path $ArchiveRoot "w/AethelnOnline/Binaries/Win64"),(Join-Path $ArchiveRoot "l"),$LogRoot | Out-Null
Set-Content -LiteralPath (Join-Path $ArchiveRoot "w/AethelnOnlineClient.exe") -Value launcher
Set-Content -LiteralPath (Join-Path $ArchiveRoot "w/AethelnOnline/Binaries/Win64/AethelnOnlineClient.exe") -Value binary
Set-Content -LiteralPath (Join-Path $ArchiveRoot "l/AethelnOnlineServer.sh") -Value server'

	Write-Fixture (Join-Path $Fixture.Repository 'scripts/build/Invoke-PackagedSmokeTest.ps1') 'param($ServerExecutable,$ServerLauncherExecutable,$ServerLauncherArguments,$ClientExecutable,$ClientBaseArguments,$ServerEndpoint,$ServerMap,$LogRoot,$ServerReadyPattern,$ServerClientConnectedPattern,$ClientConnectedPattern,$ClientMapPattern,$TimeoutSeconds)
if ($env:RUNNER_POST_CASE -eq "smoke-revision") {
	& git -C $env:RUNNER_POST_REPOSITORY update-ref HEAD $env:RUNNER_POST_ALT_REVISION
	throw "smoke failed"
}'

	$ClassName = 'FakePostCommandWsl' + [guid]::NewGuid().ToString('N')
	$Source = 'using System; public class CLASS { public static int Main(string[] args) { if (Array.IndexOf(args, "wslpath") >= 0) Console.Write("/mnt/d/archive/server.sh"); else Console.Write("172.25.32.7 "); return 0; } }'.Replace('CLASS', $ClassName)
	Add-Type -TypeDefinition $Source -OutputAssembly (Join-Path $Fixture.Bin 'wsl.exe') -OutputType ConsoleApplication

	Invoke-FixtureGit $Fixture @('add', '.')
	& git -C $Fixture.Repository -c user.name=test -c user.email=test@invalid commit --amend --no-edit -q
	if ($LASTEXITCODE -ne 0) { throw 'git fixture amend failed' }
	$Fixture.Revision = Get-FixtureRevision $Fixture
	& git -C $Fixture.Repository -c user.name=test -c user.email=test@invalid commit --allow-empty -qm alternate
	if ($LASTEXITCODE -ne 0) { throw 'git alternate commit failed' }
	$Fixture.AlternateRevision = Get-FixtureRevision $Fixture
	Invoke-FixtureGit $Fixture @('update-ref', 'HEAD', $Fixture.Revision)
}

function Invoke-Case([string] $Name, [string] $Mode, [string] $Case) {
	$Fixture = New-Fixture $Name
	Install-FakeTool $Fixture
	$env:RUNNER_POST_CASE = $Case
	$env:RUNNER_POST_REPOSITORY = $Fixture.Repository
	$env:RUNNER_POST_ALT_REVISION = $Fixture.AlternateRevision
	$env:AETHELN_ENGINE_ROOT = $Fixture.Engine
	$env:AETHELN_LINUX_TOOLCHAIN_ROOT = $Fixture.Toolchain
	# Packaging modes require an explicit host-tools selection; these cases
	# exercise post-command state, so use the explicit authorized rebuild.
	$env:AETHELN_HOST_TOOLS = 'rebuild-authorized'
	$env:PATH = $Fixture.Bin + [IO.Path]::PathSeparator + $Original.PATH
	$Previous = $ErrorActionPreference
	try {
		$ErrorActionPreference = 'Continue'
		& $PowerShell -NoProfile -File (Join-Path $Fixture.Repository 'scripts/ci/Invoke-EngineRunnerGate.ps1') -Mode $Mode -RepositoryRoot $Fixture.Repository -SourceRevision $Fixture.Revision -ArchiveRoot $Fixture.Archive -LogRoot $Fixture.Logs *> $null
		$ExitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $Previous
	}
	$ReportPath = Join-Path $Fixture.Repository 'TestResults/engine-runner-report.json'
	Assert-True ($ExitCode -ne 0) "$Name must exit nonzero."
	Assert-True (Test-Path -LiteralPath $ReportPath) "$Name must write a report."
	return Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
}

function Assert-FailedPair($Report, [string] $CommandName, [string] $StateName, [string] $StateReason) {
	$Command = @($Report.checks | Where-Object name -eq $CommandName)
	$State = @($Report.checks | Where-Object name -eq $StateName)
	Assert-True ($Command.Count -eq 1 -and $Command[0].status -eq 'failed') "$CommandName must be reported failed."
	Assert-True ($State.Count -eq 1 -and $State[0].status -eq 'failed') "$StateName must be reported failed."
	Assert-True ($State[0].message -eq $StateReason) "$StateName must report $StateReason."
	$CommandIndex = [array]::IndexOf(@($Report.checks), $Command[0])
	$StateIndex = [array]::IndexOf(@($Report.checks), $State[0])
	Assert-True ($StateIndex -eq ($CommandIndex + 1)) "$StateName must immediately follow $CommandName."
}

try {
	New-Item -ItemType Directory -Path $FixtureRoot | Out-Null

	# A declined fixture build must leave no fixture tree and no fake tooling.
	$DeclinedFixtureRoot = Join-Path $FixtureRoot 'whatif-declined-fixture'
	New-Fixture 'whatif-declined-fixture' -WhatIf | Out-Null
	Assert-True (-not (Test-Path -LiteralPath $DeclinedFixtureRoot)) 'A declined New-Fixture must create no fixture tree.'
	Write-Output 'PASS: declined fixture construction leaves no fixture tree'

	$Report = Invoke-Case -Name 'client-dirty' -Mode 'Compile' -Case 'client-dirty'
	Assert-FailedPair -Report $Report -CommandName 'incremental-client-build' -StateName 'incremental-client-build-repository-state' -StateReason 'repository_drift_detected'
	Assert-True ($Report.supervisor.childExitCode -ne 0 -and -not $Report.supervisor.timedOut -and $Report.supervisor.cleanupVerified) 'An ordinary compile failure must retain the actual child failure receipt with verified descendant cleanup.'

	$Report = Invoke-Case -Name 'server-revision' -Mode 'Compile' -Case 'server-revision'
	$Client = @($Report.checks | Where-Object name -eq 'incremental-client-build')
	Assert-True ($Client.Count -eq 1 -and $Client[0].status -eq 'passed') 'Client compile must pass before the failed server compile.'
	Assert-FailedPair -Report $Report -CommandName 'incremental-server-build' -StateName 'incremental-server-build-repository-state' -StateReason 'revision_changed'

	$Report = Invoke-Case -Name 'package-dirty' -Mode 'PackagedSmoke' -Case 'package-dirty'
	Assert-FailedPair -Report $Report -CommandName 'clean-packaged-client-server-build' -StateName 'repository-state-after-package' -StateReason 'repository_drift_detected'

	$Report = Invoke-Case -Name 'smoke-revision' -Mode 'PackagedSmoke' -Case 'smoke-revision'
	Assert-FailedPair -Report $Report -CommandName 'packaged-build-smoke' -StateName 'repository-state-at-completion' -StateReason 'revision_changed'

	Write-Output 'PASS: child-command failures retain their following repository-state failures'
} finally {
	$env:PATH = $Original.PATH
	$env:AETHELN_ENGINE_ROOT = $Original.Engine
	$env:AETHELN_LINUX_TOOLCHAIN_ROOT = $Original.Toolchain
	@('RUNNER_POST_CASE','RUNNER_POST_REPOSITORY','RUNNER_POST_ALT_REVISION','AETHELN_HOST_TOOLS') | ForEach-Object {
		Remove-Item -LiteralPath ('Env:' + $_) -ErrorAction Ignore
	}
	if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
}
