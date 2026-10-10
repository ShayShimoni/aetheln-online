[CmdletBinding()]
param()

# Issue #226: offline fixtures for the release-packaging guard and evidence
# modes. Every case runs the script as its own process with a closed GitHub
# environment, and asserts that stdout carries exactly one reason code, stderr
# stays empty, and nothing local (drive-letter paths, the handoff root, the
# runner temp root, the machine name) reaches the output or the record.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Script = Join-Path $RepositoryRoot 'scripts/ci/Invoke-ReleasePackaging.ps1'
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnReleaseTests-' + [guid]::NewGuid().ToString('N'))
$PowerShellPath = (Get-Command powershell.exe).Source
$Revision = '0123456789abcdef0123456789abcdef01234567'
$VersionLine = 'AethelnOnline 1.0.0-alpha.1, NetCL: 55116800, EngineNetworkVersion: 39, GameNetworkVersion: 0 (Checksum: 3141592653)'
$ManagedVariables = @('GITHUB_EVENT_NAME', 'GITHUB_REPOSITORY', 'GITHUB_REPOSITORY_OWNER', 'GITHUB_ACTOR', 'GITHUB_TRIGGERING_ACTOR', 'GITHUB_RUN_ATTEMPT', 'GITHUB_RUN_NUMBER', 'GITHUB_RUN_ID', 'GITHUB_REF', 'GITHUB_SHA', 'GITHUB_JOB', 'GITHUB_STEP_SUMMARY', 'GITHUB_WORKSPACE', 'RUNNER_TEMP', 'AETHELN_HANDOFF_ROOT')

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Invoke-Release([string[]] $Arguments, [hashtable] $Environment) {
	$Info = New-Object Diagnostics.ProcessStartInfo
	$Info.FileName = $PowerShellPath
	$Info.Arguments = (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $Script + '"')) + @($Arguments | ForEach-Object { '"' + $_ + '"' })) -join ' '
	$Info.UseShellExecute = $false
	$Info.RedirectStandardOutput = $true
	$Info.RedirectStandardError = $true
	$Info.CreateNoWindow = $true
	foreach ($Name in @($Info.EnvironmentVariables.Keys)) {
		if ($ManagedVariables -contains $Name) { $Info.EnvironmentVariables.Remove($Name) }
	}
	foreach ($Name in $Environment.Keys) {
		if ($null -ne $Environment[$Name]) { $Info.EnvironmentVariables[$Name] = [string] $Environment[$Name] }
	}
	$Process = [Diagnostics.Process]::Start($Info)
	$StandardOutput = $Process.StandardOutput.ReadToEndAsync()
	$StandardError = $Process.StandardError.ReadToEnd()
	$Process.WaitForExit()
	return [pscustomobject]@{ ExitCode = $Process.ExitCode; StdOut = $StandardOutput.Result; StdErr = $StandardError }
}

function Assert-Hygienic([string] $Text, [string[]] $ForbiddenValues, [string] $Context) {
	Assert-True ($Text -notmatch '[A-Za-z]:[\\/]') "$Context must not contain a drive-letter path."
	Assert-True ($Text -notmatch '\\\\') "$Context must not contain a UNC or escaped Windows path."
	foreach ($Value in @($ForbiddenValues | Where-Object { -not [string]::IsNullOrEmpty($_) })) {
		Assert-True ($Text.IndexOf($Value, [StringComparison]::OrdinalIgnoreCase) -lt 0) "$Context must not contain the local value '$Value'."
	}
	$MachineName = [Environment]::MachineName
	if ($MachineName.Length -ge 4) { Assert-True ($Text.IndexOf($MachineName, [StringComparison]::OrdinalIgnoreCase) -lt 0) "$Context must not contain the machine name." }
	Assert-True ($Text.IndexOf('FIXTURE-HOST-226', [StringComparison]::OrdinalIgnoreCase) -lt 0) "$Context must not contain the provenance machine name."
}

function Assert-Outcome($Result, [string] $Reason, [string[]] $ForbiddenValues, [string] $Context) {
	$ExpectedExit = if ($Reason -cin @('release_guard_passed', 'release_evidence_passed')) { 0 } else { 1 }
	Assert-True ($Result.ExitCode -eq $ExpectedExit) "$Context must exit $ExpectedExit. Exit: $($Result.ExitCode). Stdout: $($Result.StdOut) Stderr: $($Result.StdErr)"
	Assert-True ($Result.StdOut -cmatch ('^' + [regex]::Escape($Reason) + '\r?\n?\z')) "$Context must print exactly the reason code '$Reason'. Stdout: $($Result.StdOut) Stderr: $($Result.StdErr)"
	Assert-True ($Result.StdErr.Length -eq 0) "$Context must write nothing to stderr. Stderr: $($Result.StdErr)"
	Assert-Hygienic -Text ($Result.StdOut + $Result.StdErr) -ForbiddenValues $ForbiddenValues -Context "$Context output"
}

function Write-Utf8([string] $Path, [string] $Text) {
	New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
	[IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Get-Sha256([string] $Path) {
	return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# ---------------------------------------------------------------- Guard mode

function Initialize-GuardRoot([string] $Name, [string[]] $DefaultGameLines, [hashtable] $OtherIni = @{}) {
	$Root = Join-Path $FixtureRoot ('guard-' + $Name)
	New-Item -ItemType Directory -Path (Join-Path $Root 'Config') -Force | Out-Null
	if ($null -ne $DefaultGameLines) { Write-Utf8 (Join-Path $Root 'Config/DefaultGame.ini') (($DefaultGameLines -join "`n") + "`n") }
	Write-Utf8 (Join-Path $Root 'Config/DefaultEngine.ini') "[/Script/EngineSettings.GameMapsSettings]`nGameDefaultMap=/Game/Maps/StarterMap`n"
	foreach ($Relative in $OtherIni.Keys) { Write-Utf8 (Join-Path $Root $Relative) $OtherIni[$Relative] }
	return $Root
}

function Get-GuardEnvironment([string] $Root, [hashtable] $Override = @{}) {
	$Environment = @{
		GITHUB_EVENT_NAME = 'workflow_dispatch'
		GITHUB_REPOSITORY = 'ShayShimoni/aetheln-online'
		GITHUB_REPOSITORY_OWNER = 'ShayShimoni'
		GITHUB_ACTOR = 'ShayShimoni'
		GITHUB_TRIGGERING_ACTOR = 'ShayShimoni'
		GITHUB_RUN_ATTEMPT = '1'
		GITHUB_RUN_NUMBER = '7'
		GITHUB_REF = 'refs/heads/release/v1.0.0-alpha.1'
		GITHUB_STEP_SUMMARY = (Join-Path $Root 'step-summary.md')
	}
	foreach ($Name in $Override.Keys) { $Environment[$Name] = $Override[$Name] }
	return $Environment
}

function Invoke-Guard([string] $Root, [hashtable] $Override = @{}, [string] $Mode = 'Guard') {
	return Invoke-Release @('-Mode', $Mode, '-RepositoryRoot', $Root) (Get-GuardEnvironment $Root $Override)
}

$SectionHeader = '[/Script/EngineSettings.GeneralProjectSettings]'

try {
	. (Join-Path $RepositoryRoot 'scripts/build/ProjectVersion.ps1')
	foreach ($Separator in @("`n", "`r", "`r`n")) {
		$ConfigText = $SectionHeader + $Separator + 'ProjectVersion=1.0.0-alpha.1' + $Separator
		Assert-True ((Read-ProjectVersionConfig -DefaultGameContent $ConfigText) -ceq '1.0.0-alpha.1') 'The shared parser must accept canonical version text with each engine line boundary.'
	}
	$PreCutText = $SectionHeader + "`nProjectName=AethelnOnline`n"
	Assert-True ($null -eq (Read-ProjectVersionConfig -DefaultGameContent $PreCutText -AllowMissing)) 'Only an explicit -AllowMissing caller may accept an absent version.'
	$ConfigRefusals = @(
		@{ Text = ([string][char]0 + "`n$SectionHeader`nProjectVersion=1.0.0-alpha.1"); Other = @(); Missing = $false; Reason = 'project_version_invalid' },
		@{ Text = ([string][char]0); Other = @(); Missing = $true; Reason = 'project_version_invalid' },
		@{ Text = "$SectionHeader`nProjectVersion=1.0.0-alpha.1"; Other = @([string][char]0 + "`n$SectionHeader`nProjectVersion=9.9.9"); Missing = $false; Reason = 'project_version_override' },
		@{ Text = $PreCutText; Other = @(); Missing = $false; Reason = 'project_version_missing' },
		@{ Text = $PreCutText; Other = @("$SectionHeader`nProjectVersion=9.9.9`n"); Missing = $true; Reason = 'project_version_override' },
		@{ Text = "$SectionHeader`nProjectVersion=1.0.0-alpha.1`rProjectVersion=9.9.9"; Other = @(); Missing = $false; Reason = 'project_version_invalid' },
		@{ Text = "[/Script/Other]`nProjectVersion=1.0.0-alpha.1"; Other = @(); Missing = $false; Reason = 'project_version_invalid' },
		@{ Text = "$SectionHeader`nProjectName=AethelnOnline\`n"; Other = @(); Missing = $true; Reason = 'project_version_invalid' }
	)
	foreach ($Case in $ConfigRefusals) {
		$ConfigReason = ''
		try { $null = Read-ProjectVersionConfig -DefaultGameContent $Case.Text -OtherIniContents $Case.Other -AllowMissing:$Case.Missing } catch { $ConfigReason = $_.Exception.Message.Split(':')[0] }
		Assert-True ($ConfigReason -ceq $Case.Reason) "Shared version parsing must refuse with $($Case.Reason), including before a release version exists (actual: $ConfigReason)."
	}
	Write-Output 'PASS: the shared text parser preserves line endings, strict required callers and pre-cut override refusal'
	New-Item -ItemType Directory -Path $FixtureRoot -Force | Out-Null

	$AlphaRoot = Initialize-GuardRoot 'alpha' @($SectionHeader, 'ProjectName=AethelnOnline', 'ProjectVersion=1.0.0-alpha.1')
	$Result = Invoke-Guard $AlphaRoot
	Assert-Outcome -Result $Result -Reason 'release_guard_passed' -ForbiddenValues @($AlphaRoot, $FixtureRoot) -Context 'An owner dispatch of release/v1.0.0-alpha.1 carrying 1.0.0-alpha.1'
	$Summary = Get-Content -LiteralPath (Join-Path $AlphaRoot 'step-summary.md') -Raw
	Assert-True ($Summary.Contains('`1.0.0-alpha.1`') -and $Summary.Contains('`7`') -and $Summary.Contains('`1.0.0-alpha.1+7`')) 'The guard must write ProjectVersion, the build number, and the build version to the job summary.'
	Assert-Hygienic -Text $Summary -ForbiddenValues @($AlphaRoot, $FixtureRoot) -Context 'The job summary'
	$PlainRoot = Initialize-GuardRoot 'plain' @($SectionHeader, 'ProjectVersion=1.0.0')
	Assert-Outcome -Result (Invoke-Guard $PlainRoot @{ GITHUB_REF = 'refs/heads/release/v1.0.0'; GITHUB_RUN_NUMBER = '9999999999' }) -Reason 'release_guard_passed' -ForbiddenValues @($PlainRoot) -Context 'An owner dispatch of release/v1.0.0 carrying 1.0.0'
	Write-Output 'PASS: the guard accepts an owner dispatch of release/v<ProjectVersion> and records the build version in the job summary'

	$RefusalCases = @(
		@{ Name = 'event-push'; Override = @{ GITHUB_EVENT_NAME = 'push' }; Reason = 'release_event_invalid' },
		@{ Name = 'event-schedule'; Override = @{ GITHUB_EVENT_NAME = 'schedule' }; Reason = 'release_event_invalid' },
		@{ Name = 'event-pull-request'; Override = @{ GITHUB_EVENT_NAME = 'pull_request' }; Reason = 'release_event_invalid' },
		@{ Name = 'event-pull-request-target'; Override = @{ GITHUB_EVENT_NAME = 'pull_request_target' }; Reason = 'release_event_invalid' },
		@{ Name = 'event-case'; Override = @{ GITHUB_EVENT_NAME = 'Workflow_Dispatch' }; Reason = 'release_event_invalid' },
		@{ Name = 'event-missing'; Override = @{ GITHUB_EVENT_NAME = $null }; Reason = 'release_event_invalid' },
		@{ Name = 'fork-repository'; Override = @{ GITHUB_REPOSITORY = 'someone/aetheln-online'; GITHUB_REPOSITORY_OWNER = 'someone'; GITHUB_ACTOR = 'someone'; GITHUB_TRIGGERING_ACTOR = 'someone' }; Reason = 'release_repository_invalid' },
		@{ Name = 'repository-case'; Override = @{ GITHUB_REPOSITORY = 'shayshimoni/aetheln-online' }; Reason = 'release_repository_invalid' },
		@{ Name = 'owner-case'; Override = @{ GITHUB_REPOSITORY_OWNER = 'shayshimoni' }; Reason = 'release_repository_invalid' },
		@{ Name = 'repository-missing'; Override = @{ GITHUB_REPOSITORY = $null }; Reason = 'release_repository_invalid' },
		@{ Name = 'actor-other'; Override = @{ GITHUB_ACTOR = 'someone' }; Reason = 'release_actor_invalid' },
		@{ Name = 'actor-case'; Override = @{ GITHUB_ACTOR = 'shayshimoni' }; Reason = 'release_actor_invalid' },
		@{ Name = 'actor-bot'; Override = @{ GITHUB_ACTOR = 'github-actions[bot]' }; Reason = 'release_actor_invalid' },
		@{ Name = 'triggering-actor-other'; Override = @{ GITHUB_TRIGGERING_ACTOR = 'someone' }; Reason = 'release_actor_invalid' },
		@{ Name = 'triggering-actor-missing'; Override = @{ GITHUB_TRIGGERING_ACTOR = $null }; Reason = 'release_actor_invalid' },
		@{ Name = 'attempt-2'; Override = @{ GITHUB_RUN_ATTEMPT = '2' }; Reason = 'release_attempt_invalid' },
		@{ Name = 'attempt-01'; Override = @{ GITHUB_RUN_ATTEMPT = '01' }; Reason = 'release_attempt_invalid' },
		@{ Name = 'attempt-missing'; Override = @{ GITHUB_RUN_ATTEMPT = $null }; Reason = 'release_attempt_invalid' },
		@{ Name = 'ref-develop'; Override = @{ GITHUB_REF = 'refs/heads/develop' }; Reason = 'release_ref_invalid' },
		@{ Name = 'ref-main'; Override = @{ GITHUB_REF = 'refs/heads/main' }; Reason = 'release_ref_invalid' },
		@{ Name = 'ref-tag'; Override = @{ GITHUB_REF = 'refs/tags/v1.0.0-alpha.1' }; Reason = 'release_ref_invalid' },
		@{ Name = 'ref-pull'; Override = @{ GITHUB_REF = 'refs/pull/1/merge' }; Reason = 'release_ref_invalid' },
		@{ Name = 'ref-bare-release'; Override = @{ GITHUB_REF = 'refs/heads/release' }; Reason = 'release_ref_invalid' },
		@{ Name = 'ref-releases'; Override = @{ GITHUB_REF = 'refs/heads/releases/v1.0.0-alpha.1' }; Reason = 'release_ref_invalid' },
		@{ Name = 'ref-nested-release'; Override = @{ GITHUB_REF = 'refs/heads/feature/release/v1.0.0-alpha.1' }; Reason = 'release_ref_invalid' },
		@{ Name = 'ref-case'; Override = @{ GITHUB_REF = 'refs/heads/Release/v1.0.0-alpha.1' }; Reason = 'release_ref_invalid' },
		@{ Name = 'ref-no-v'; Override = @{ GITHUB_REF = 'refs/heads/release/1.0.0-alpha.1' }; Reason = 'release_ref_invalid' },
		@{ Name = 'ref-build-metadata'; Override = @{ GITHUB_REF = 'refs/heads/release/v1.0.0-alpha.1+7' }; Reason = 'release_ref_invalid' },
		@{ Name = 'ref-suffix'; Override = @{ GITHUB_REF = 'refs/heads/release/v1.0.0-alpha.1/extra' }; Reason = 'release_ref_invalid' },
		@{ Name = 'ref-missing'; Override = @{ GITHUB_REF = $null }; Reason = 'release_ref_invalid' },
		@{ Name = 'build-number-zero'; Override = @{ GITHUB_RUN_NUMBER = '0' }; Reason = 'build_number_invalid' },
		@{ Name = 'build-number-leading-zero'; Override = @{ GITHUB_RUN_NUMBER = '07' }; Reason = 'build_number_invalid' },
		@{ Name = 'build-number-text'; Override = @{ GITHUB_RUN_NUMBER = 'x' }; Reason = 'build_number_invalid' },
		@{ Name = 'build-number-long'; Override = @{ GITHUB_RUN_NUMBER = '12345678901' }; Reason = 'build_number_invalid' },
		@{ Name = 'build-number-missing'; Override = @{ GITHUB_RUN_NUMBER = $null }; Reason = 'build_number_invalid' },
		@{ Name = 'branch-mismatch'; Override = @{ GITHUB_REF = 'refs/heads/release/v1.0.0-alpha.2' }; Reason = 'project_version_branch_mismatch' },
		@{ Name = 'branch-core-only'; Override = @{ GITHUB_REF = 'refs/heads/release/v1.0.0' }; Reason = 'project_version_branch_mismatch' }
	)
	foreach ($Case in $RefusalCases) {
		$Root = Initialize-GuardRoot ('refuse-' + $Case.Name) @($SectionHeader, 'ProjectVersion=1.0.0-alpha.1')
		Assert-Outcome -Result (Invoke-Guard $Root $Case.Override) -Reason $Case.Reason -ForbiddenValues @($Root, $FixtureRoot) -Context "Guard case '$($Case.Name)'"
		Assert-True (-not (Test-Path -LiteralPath (Join-Path $Root 'step-summary.md'))) "Guard case '$($Case.Name)' must not write a job summary."
	}
	Write-Output 'PASS: the guard refuses other events, repositories, actors, attempts, refs, build numbers, and branch versions case-sensitively'

	$VersionCases = @(
		@{ Name = 'linux-braced'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0-alpha.1'); Other = @{ 'Config/Linux/LinuxGame.ini' = "$SectionHeader`nProject{Version}=9.9.9`n" }; Reason = 'project_version_override' },
		@{ Name = 'linux-joined-key'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0-alpha.1'); Other = @{ 'Config/Linux/LinuxGame.ini' = "$SectionHeader`nProjectVersion\`n=9.9.9`n" }; Reason = 'project_version_override' },
		@{ Name = 'tilde-set'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0-alpha.1', '~ProjectVersion=9.9.9'); Other = @{}; Reason = 'project_version_invalid' },
		@{ Name = 'tilde-add'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0-alpha.1', '~+ProjectVersion=9.9.9'); Other = @{}; Reason = 'project_version_invalid' },
		@{ Name = 'lone-cr'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0-alpha.1', "ProjectName=AethelnOnline`rProjectVersion=9.9.9"); Other = @{}; Reason = 'project_version_invalid' },
		@{ Name = 'commented-header'; Lines = @($SectionHeader, '[/Script/Other] // note', 'ProjectVersion=1.0.0-alpha.1'); Other = @{}; Reason = 'project_version_invalid' },
		@{ Name = 'linux-tilde'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0-alpha.1'); Other = @{ 'Config/Linux/LinuxGame.ini' = "$SectionHeader`n~ProjectVersion=9.9.9`n" }; Reason = 'project_version_override' },
		@{ Name = 'linux-reset'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0-alpha.1'); Other = @{ 'Config/Linux/LinuxGame.ini' = "$SectionHeader`n^ProjectVersion=`n" }; Reason = 'project_version_override' },
		@{ Name = 'missing-file'; Lines = $null; Other = @{}; Reason = 'project_version_missing' },
		@{ Name = 'missing-line'; Lines = @($SectionHeader, 'ProjectName=AethelnOnline'); Other = @{}; Reason = 'project_version_missing' },
		@{ Name = 'build-metadata'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0-alpha.1+7'); Other = @{}; Reason = 'project_version_invalid' },
		@{ Name = 'other-section'; Lines = @($SectionHeader, '[/Script/Other] ', 'ProjectVersion=1.0.0-alpha.1'); Other = @{}; Reason = 'project_version_invalid' },
		@{ Name = 'joined-line'; Lines = @($SectionHeader, 'ProjectName=AethelnOnline\', 'ProjectVersion=1.0.0-alpha.1'); Other = @{}; Reason = 'project_version_invalid' },
		@{ Name = 'platform-override'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0-alpha.1'); Other = @{ 'Config/Windows/WindowsGame.ini' = "$SectionHeader`nProjectVersion=1.0.0-alpha.1`n" }; Reason = 'project_version_override' },
		@{ Name = 'array-override'; Lines = @($SectionHeader, 'ProjectVersion=1.0.0-alpha.1'); Other = @{ 'Config/DedicatedServerGame.ini' = "$SectionHeader`n+projectversion=2.0.0`n" }; Reason = 'project_version_override' }
	)
	foreach ($Case in $VersionCases) {
		$Root = Initialize-GuardRoot -Name ('version-' + $Case.Name) -DefaultGameLines $Case.Lines -OtherIni $Case.Other
		Assert-Outcome -Result (Invoke-Guard $Root) -Reason $Case.Reason -ForbiddenValues @($Root, $FixtureRoot) -Context "Guard version case '$($Case.Name)'"
	}
	$DevelopRoot = Initialize-GuardRoot 'develop-without-version' @($SectionHeader, 'ProjectName=AethelnOnline')
	Assert-Outcome -Result (Invoke-Guard $DevelopRoot @{ GITHUB_REF = 'refs/heads/develop' }) -Reason 'release_ref_invalid' -ForbiddenValues @($DevelopRoot) -Context 'A develop dispatch before ProjectVersion exists'
	Write-Output 'PASS: the guard reads ProjectVersion through the shared reader, refuses other ini overrides, and checks the ref before the version'

	foreach ($BadMode in @('guard', 'Other', '')) {
		Assert-Outcome -Result (Invoke-Guard -Root $AlphaRoot -Override @{} -Mode $BadMode) -Reason 'release_mode_invalid' -ForbiddenValues @($AlphaRoot) -Context "Mode '$BadMode'"
	}
	$Missing = Join-Path $FixtureRoot 'no-such-root'
	Assert-Outcome -Result (Invoke-Guard $Missing) -Reason 'project_version_missing' -ForbiddenValues @($Missing, $FixtureRoot) -Context 'A missing repository root'
	Write-Output 'PASS: an unknown mode or a missing root yields only a reason code'

	# ------------------------------------------------------------ Evidence mode

	function Initialize-EvidenceFixture([string] $Name, [scriptblock] $Customize = $null) {
		$Root = Join-Path $FixtureRoot ('evidence-' + $Name)
		$Fixture = @{
			Root = $Root
			Handoff = (Join-Path $Root 'handoff')
			RunnerTemp = (Join-Path $Root 'runner-temp')
			Output = (Join-Path $Root 'milestone/TestResults/release-evidence.json')
			Environment = @{
				GITHUB_REPOSITORY = 'ShayShimoni/aetheln-online'
				GITHUB_REF = 'refs/heads/release/v1.0.0-alpha.1'
				GITHUB_SHA = $Revision
				GITHUB_RUN_ID = '4242'
				GITHUB_RUN_ATTEMPT = '1'
				GITHUB_RUN_NUMBER = '7'
				GITHUB_JOB = 'release-packaged-smoke'
			}
			ProjectVersion = '1.0.0-alpha.1'
			ProvenanceRevision = $Revision
			BuildNumber = 7
			Logs = [ordered]@{
				'server.stdout.log' = @('[2026.10.03-10.00.00:000][  0]LogInit: Display: Starting Game.', '[2026.10.03-10.00.00:001][  0]LogNetVersion: Set ProjectVersion to 1.0.0-alpha.1. Version Checksum will be recalculated on next use.', "[2026.10.03-10.00.01:002][  0]LogNetVersion: $VersionLine", 'LogNet: GameNetDriver IpNetDriver_0 IpNetDriver listening on port 7777')
				'client-1.stdout.log' = @("LogNetVersion: $VersionLine", 'LogNet: Welcomed by server (Level: /Game/Maps/StarterMap, Game: /Script/Engine.GameModeBase)')
				'client-2.stdout.log' = @("[2026.10.03-10.00.03:004][ 12]LogNetVersion: $VersionLine", "[2026.10.03-10.00.03:005][ 13]LogNetVersion: $VersionLine")
			}
			SmokeEvents = @('process_started', 'server_listening', 'smoke_passed')
			Mutate = $null
		}
		$Fixture.Environment['RUNNER_TEMP'] = $Fixture.RunnerTemp
		$Fixture.Environment['AETHELN_HANDOFF_ROOT'] = $Fixture.Handoff
		if ($null -ne $Customize) { & $Customize $Fixture }
		$RunDirectory = Join-Path $Fixture.Handoff 'ShayShimoni/aetheln-online/run-4242-attempt-1'
		$ProvenancePath = Join-Path $RunDirectory 'provenance/build-provenance.json'
		$Release = [ordered]@{ schemaVersion = 1; projectVersion = $Fixture.ProjectVersion; buildNumber = $Fixture.BuildNumber; buildVersion = ('{0}+{1}' -f $Fixture.ProjectVersion, $Fixture.BuildNumber) }
		$Provenance = [ordered]@{
			schemaVersion = 2
			createdUtc = '2026-10-03T10:00:00.0000000Z'
			host = [ordered]@{ machineName = 'FIXTURE-HOST-226'; buildIdentity = ('AethelnOnline@{0}/Development' -f $Fixture.ProvenanceRevision) }
			source = [ordered]@{ revision = $Fixture.ProvenanceRevision; repositoryRoot = 'C:\fixture-runner\_work\milestone'; clean = $true }
			artifacts = [ordered]@{
				clientArchive = 'C:\fixture-handoff\client\WindowsClient'
				serverArchive = 'C:\fixture-handoff\server\LinuxServer'
				inventory = @(
					[ordered]@{ kind = 'client'; path = 'AethelnOnlineClient.exe'; sizeBytes = 10; sha256 = ('a' * 64) },
					[ordered]@{ kind = 'client'; path = 'AethelnOnline/Binaries/Win64/AethelnOnlineClient.exe'; sizeBytes = 100; sha256 = ('b' * 64) },
					[ordered]@{ kind = 'server'; path = 'AethelnOnlineServer.sh'; sizeBytes = 5; sha256 = ('c' * 64) },
					[ordered]@{ kind = 'server'; path = 'AethelnOnline/Binaries/Linux/AethelnOnlineServer'; sizeBytes = 200; sha256 = ('d' * 64) }
				)
			}
			release = $Release
		}
		if ($Fixture.ContainsKey('RecipeCase')) {
			$Provenance['build'] = if ($Fixture.RecipeCase -ceq 'skip-without-proof') { [ordered]@{ uatInvocations = [ordered]@{ client = @{ arguments = @('BuildCookRun', '-skipbuild') }; server = @{ arguments = @('BuildCookRun') } } } } else { [ordered]@{ packageRecipe = [ordered]@{} } }
		}
		Write-Utf8 $ProvenancePath ($Provenance | ConvertTo-Json -Depth 8)
		$Manifest = [ordered]@{
			schemaVersion = 1; repository = 'ShayShimoni/aetheln-online'; sourceRevision = $Revision; runId = '4242'; runAttempt = '1'; producingPhase = 'provenance'
			expectedConsumingPhases = @('smoke'); runnerName = 'fixture-runner'
			files = @([ordered]@{ path = 'build-provenance.json'; bytes = (Get-Item -LiteralPath $ProvenancePath).Length; sha256 = (Get-Sha256 $ProvenancePath) })
			totalBytes = (Get-Item -LiteralPath $ProvenancePath).Length; createdUtc = '2026-10-03T10:00:00.0000000Z'
		}
		Write-Utf8 (Join-Path $RunDirectory 'manifest-provenance.json') ($Manifest | ConvertTo-Json -Depth 6)
		$SmokeRoot = Join-Path $Fixture.RunnerTemp 'aetheln-engine-4242-1-release-packaged-smoke/logs/phase/packaged-smoke'
		New-Item -ItemType Directory -Path $SmokeRoot -Force | Out-Null
		foreach ($LogName in $Fixture.Logs.Keys) {
			if ($null -ne $Fixture.Logs[$LogName]) { Write-Utf8 (Join-Path $SmokeRoot $LogName) (($Fixture.Logs[$LogName] -join "`r`n") + "`r`n") }
		}
		$Events = @($Fixture.SmokeEvents | ForEach-Object { ([ordered]@{ schema = 'aetheln.packaged-smoke.evidence/v1'; timestamp = '2026-10-03T10:00:04.0000000Z'; process = 'orchestrator'; role = 'smoke'; event = $_; source = 'C:\fixture-runner\temp\smoke-evidence.jsonl'; detail = 'Two distinct clients connected to 172.20.0.2:7777 on /Game/Maps/StarterMap.' } | ConvertTo-Json -Compress) })
		Write-Utf8 (Join-Path $SmokeRoot 'smoke-evidence.jsonl') (($Events -join "`n") + "`n")
		$Fixture['RunDirectory'] = $RunDirectory
		$Fixture['ProvenancePath'] = $ProvenancePath
		$Fixture['SmokeRoot'] = $SmokeRoot
		if ($null -ne $Fixture.Mutate) { & $Fixture.Mutate $Fixture }
		return $Fixture
	}

	function Invoke-Evidence($Fixture) {
		return Invoke-Release @('-Mode', 'Evidence', '-OutputPath', $Fixture.Output) $Fixture.Environment
	}

	function Assert-EvidenceOutcome($Fixture, [string] $Reason, [bool] $ExpectRecord = $true) {
		$Result = Invoke-Evidence $Fixture
		$Forbidden = @($Fixture.Root, $Fixture.Handoff, $Fixture.RunnerTemp, $FixtureRoot, 'fixture-runner', 'fixture-handoff', '172.20.0.2')
		Assert-Outcome -Result $Result -Reason $Reason -ForbiddenValues $Forbidden -Context "Evidence case '$Reason'"
		if (-not $ExpectRecord) { return $null }
		Assert-True (Test-Path -LiteralPath $Fixture.Output -PathType Leaf) "Evidence case '$Reason' must still write the record."
		$Text = Get-Content -LiteralPath $Fixture.Output -Raw
		Assert-Hygienic -Text $Text -ForbiddenValues $Forbidden -Context "Evidence record for '$Reason'"
		$Record = $Text | ConvertFrom-Json
		Assert-True ((@($Record.PSObject.Properties.Name) -join ',') -ceq 'schema,passed,reason,repository,ref,sourceRevision,runId,runAttempt,runNumber,projectVersion,buildNumber,buildVersion,provenance,archives,netVersion,smokeEvidenceSha256') "Evidence record for '$Reason' must keep the closed top-level schema."
		Assert-True ($Record.schema -ceq 'aetheln.release-evidence/v1' -and $Record.reason -ceq $Reason -and $Record.passed -eq ($Reason -ceq 'release_evidence_passed')) "Evidence record for '$Reason' must carry its decision and reason."
		return $Record
	}

	$Passing = Initialize-EvidenceFixture 'pass'
	$Record = Assert-EvidenceOutcome $Passing 'release_evidence_passed'
	Assert-True ($Record.repository -ceq 'ShayShimoni/aetheln-online' -and $Record.ref -ceq 'refs/heads/release/v1.0.0-alpha.1' -and $Record.sourceRevision -ceq $Revision -and $Record.runId -ceq '4242' -and $Record.runAttempt -eq 1 -and $Record.runNumber -eq 7) 'The record must bind the repository, ref, revision, run id, attempt, and number.'
	Assert-True ($Record.projectVersion -ceq '1.0.0-alpha.1' -and $Record.buildNumber -eq 7 -and $Record.buildVersion -ceq '1.0.0-alpha.1+7') 'The record must carry the version, build number, and build version.'
	Assert-True ($Record.provenance.sha256 -ceq (Get-Sha256 $Passing.ProvenancePath) -and $Record.provenance.schemaVersion -eq 2) 'The record must carry the provenance digest and schema version.'
	Assert-True ($Record.archives.client.fileCount -eq 2 -and $Record.archives.client.totalBytes -eq 110 -and $Record.archives.client.mainExecutable.path -ceq 'AethelnOnline/Binaries/Win64/AethelnOnlineClient.exe' -and $Record.archives.client.mainExecutable.sha256 -ceq ('b' * 64)) 'The record must summarize the client archive and its main executable.'
	Assert-True ($Record.archives.server.fileCount -eq 2 -and $Record.archives.server.totalBytes -eq 205 -and $Record.archives.server.mainExecutable.path -ceq 'AethelnOnline/Binaries/Linux/AethelnOnlineServer' -and $Record.archives.server.mainExecutable.sha256 -ceq ('d' * 64)) 'The record must summarize the server archive and its main executable.'
	Assert-True ($Record.netVersion.server -ceq $VersionLine -and $Record.netVersion.client1 -ceq $VersionLine -and $Record.netVersion.client2 -ceq $VersionLine -and $Record.netVersion.checksum -eq 3141592653) 'The record must carry the three identical network version lines and the shared checksum.'
	Assert-True ($Record.smokeEvidenceSha256 -ceq (Get-Sha256 (Join-Path $Passing.SmokeRoot 'smoke-evidence.jsonl'))) 'The record must carry only the digest of the raw smoke evidence.'
	$Before = Get-Sha256 $Passing.Output
	Assert-EvidenceOutcome -Fixture $Passing -Reason 'release_evidence_exists' -ExpectRecord $false | Out-Null
	Assert-True ((Get-Sha256 $Passing.Output) -ceq $Before) 'An existing record must never be overwritten.'
	Write-Output 'PASS: evidence binds provenance, archives, three identical network version lines, and the smoke digest in a closed, path-free, create-only record'

	$EvidenceCases = @(
		@{ Name = 'checksum-differs'; Reason = 'net_version_mismatch'; Customize = { param($F) $F.Logs['client-2.stdout.log'] = @('LogNetVersion: ' + $VersionLine.Replace('3141592653', '3141592654')) } },
		@{ Name = 'two-lines-in-one-log'; Reason = 'net_version_mismatch'; Customize = { param($F) $F.Logs['server.stdout.log'] = @("LogNetVersion: $VersionLine", ('LogNetVersion: ' + $VersionLine.Replace('NetCL: 55116800', 'NetCL: 55116801'))) } },
		@{ Name = 'version-not-provenance'; Reason = 'net_version_project_mismatch'; Customize = { param($F) $Other = $VersionLine.Replace('1.0.0-alpha.1', '1.0.0-alpha.2'); foreach ($Key in @($F.Logs.Keys)) { $F.Logs[$Key] = @("LogNetVersion: $Other") } } },
		@{ Name = 'version-missing-from-line'; Reason = 'net_version_line_invalid'; Customize = { param($F) $F.Logs['client-1.stdout.log'] = @('LogNetVersion: ' + $VersionLine.Replace('AethelnOnline 1.0.0-alpha.1,', 'AethelnOnline ,')) } },
		@{ Name = 'free-text-in-line'; Reason = 'net_version_line_invalid'; Customize = { param($F) $F.Logs['server.stdout.log'] = @('LogNetVersion: ' + $VersionLine.Replace(' (Checksum:', ', Extra: C:\fixture-runner (Checksum:')) } },
		@{ Name = 'unexpected-prefix'; Reason = 'net_version_line_invalid'; Customize = { param($F) $F.Logs['client-1.stdout.log'] = @("C:\fixture-runner LogNetVersion: $VersionLine") } },
		@{ Name = 'extra-custom-version'; Reason = 'net_version_line_invalid'; Customize = { param($F) $F.Logs['server.stdout.log'] = @('LogNetVersion: ' + $VersionLine.Replace(' (Checksum:', ', OtherVersion: 1 (Checksum:')) } },
		@{ Name = 'line-missing'; Reason = 'net_version_missing'; Customize = { param($F) $F.Logs['client-2.stdout.log'] = @('LogNet: Welcomed by server', 'LogNetVersion: Checksum from delegate: 12') } },
		@{ Name = 'log-missing'; Reason = 'smoke_logs_missing'; Customize = { param($F) $F.Logs['client-1.stdout.log'] = $null } },
		@{ Name = 'smoke-not-passed'; Reason = 'smoke_not_passed'; Customize = { param($F) $F.SmokeEvents = @('process_started', 'server_listening') } },
		@{ Name = 'provenance-digest'; Reason = 'provenance_digest_mismatch'; Customize = { param($F) $F.Mutate = { param($G) Add-Content -LiteralPath $G.ProvenancePath -Value ' ' } } },
		@{ Name = 'provenance-revision'; Reason = 'provenance_revision_mismatch'; Customize = { param($F) $F.ProvenanceRevision = ('f' * 40) } },
		@{ Name = 'recipe-skip-unproved'; Reason = 'provenance_recipe_invalid'; Customize = { param($F) $F['RecipeCase'] = 'skip-without-proof' } },
		@{ Name = 'recipe-block-invalid'; Reason = 'provenance_recipe_invalid'; Customize = { param($F) $F['RecipeCase'] = 'invalid-block' } },
		@{ Name = 'build-number'; Reason = 'provenance_build_number_mismatch'; Customize = { param($F) $F.Environment['GITHUB_RUN_NUMBER'] = '8' } },
		@{ Name = 'provenance-version'; Reason = 'project_version_branch_mismatch'; Customize = { param($F) $F.ProjectVersion = '1.0.0-alpha.2' } },
		@{ Name = 'manifest-revision'; Reason = 'provenance_manifest_invalid'; Customize = { param($F) $F.Environment['GITHUB_SHA'] = ('e' * 40) } },
		@{ Name = 'context-attempt'; Reason = 'release_context_invalid'; Customize = { param($F) $F.Environment['GITHUB_RUN_ATTEMPT'] = '2' } },
		@{ Name = 'context-ref'; Reason = 'release_context_invalid'; Customize = { param($F) $F.Environment['GITHUB_REF'] = 'refs/heads/develop' } },
		@{ Name = 'context-repository'; Reason = 'release_context_invalid'; Customize = { param($F) $F.Environment['GITHUB_REPOSITORY'] = 'someone/aetheln-online' } },
		@{ Name = 'handoff-unset'; Reason = 'handoff_root_unset'; Customize = { param($F) $F.Environment['AETHELN_HANDOFF_ROOT'] = $null } },
		@{ Name = 'handoff-unc'; Reason = 'handoff_root_invalid'; Customize = { param($F) $F.Environment['AETHELN_HANDOFF_ROOT'] = '\\fixture-server\share' } },
		@{ Name = 'handoff-absent'; Reason = 'handoff_root_invalid'; Customize = { param($F) $F.Environment['AETHELN_HANDOFF_ROOT'] = (Join-Path $F.Root 'absent') } },
		@{ Name = 'handoff-inside-runner-temp'; Reason = 'handoff_root_invalid'; Customize = { param($F) $F.Handoff = (Join-Path $F.RunnerTemp 'handoff'); $F.Environment['AETHELN_HANDOFF_ROOT'] = $F.Handoff } },
		@{ Name = 'handoff-junction'; Reason = 'handoff_root_invalid'; Customize = { param($F) $F.Mutate = { param($G) $Real = Join-Path $G.Root 'real-run'; Move-Item -LiteralPath $G.RunDirectory -Destination $Real; New-Item -ItemType Junction -Path $G.RunDirectory -Target $Real | Out-Null } } },
		@{ Name = 'smoke-junction'; Reason = 'smoke_logs_invalid'; Customize = { param($F) $F.Mutate = { param($G) $Real = Join-Path $G.Root 'real-smoke'; Move-Item -LiteralPath $G.SmokeRoot -Destination $Real; New-Item -ItemType Junction -Path $G.SmokeRoot -Target $Real | Out-Null } } }
	)
	foreach ($Case in $EvidenceCases) {
		$Fixture = Initialize-EvidenceFixture $Case.Name $Case.Customize
		[void] (Assert-EvidenceOutcome $Fixture $Case.Reason)
	}
	Write-Output 'PASS: evidence fails closed, with a written record and only a reason code, on every version, log, smoke, provenance, context, and path fault'

	$BadOutput = Initialize-EvidenceFixture 'bad-output'
	$BadOutput.Output = (Join-Path $BadOutput.Root 'bad|name/release-evidence.json')
	$Result = Invoke-Evidence $BadOutput
	Assert-True ($Result.ExitCode -eq 1 -and $Result.StdOut -cmatch '^[a-z][a-z0-9_]*\r?\n?\z' -and $Result.StdErr.Length -eq 0) "An unexpected exception must still print only a reason code. Stdout: $($Result.StdOut) Stderr: $($Result.StdErr)"
	Assert-Hygienic -Text ($Result.StdOut + $Result.StdErr) -ForbiddenValues @($BadOutput.Root, $FixtureRoot) -Context 'An unexpected exception'
	Write-Output 'PASS: an unexpected exception still yields only a reason code'
} finally {
	if (Test-Path -LiteralPath $FixtureRoot) {
		# Remove the junction fixtures as links first, so cleanup never follows them.
		foreach ($Link in @(Get-ChildItem -LiteralPath $FixtureRoot -Recurse -Force -Directory -Attributes ReparsePoint -ErrorAction SilentlyContinue)) { [IO.Directory]::Delete($Link.FullName) }
		Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
	}
}
exit 0
