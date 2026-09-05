[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$WorkflowPath = Join-Path $RepositoryRoot '.github\workflows\prototype-quality-gates.yml'
$Workflow = Get-Content -LiteralPath $WorkflowPath -Raw

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-MatchCount([string] $Text, [string] $Pattern, [int] $Expected, [string] $Message) {
	$Actual = [regex]::Matches($Text, $Pattern).Count
	Assert-True ($Actual -eq $Expected) "$Message Expected $Expected match(es), found $Actual."
}

function Get-JobBody([string] $JobName, [string] $NextJobName) {
	$Start = "  ${JobName}:"
	$End = "  ${NextJobName}:"
	$StartIndex = $Workflow.IndexOf($Start, [StringComparison]::Ordinal)
	$EndIndex = $Workflow.IndexOf($End, $StartIndex + $Start.Length, [StringComparison]::Ordinal)
	Assert-True ($StartIndex -ge 0 -and $EndIndex -gt $StartIndex) "Workflow job '$JobName' should exist before '$NextJobName'."
	return $Workflow.Substring($StartIndex, $EndIndex - $StartIndex)
}

$QualityGates = Get-JobBody 'quality-gates' 'change-impact'
$ChangeImpact = Get-JobBody 'change-impact' 'trusted-candidate-compile'
$TrustedCompile = Get-JobBody 'trusted-candidate-compile' 'scheduled-client-package'
$ScheduledSmokeStart = $Workflow.IndexOf('  scheduled-packaged-smoke:', [StringComparison]::Ordinal)
Assert-True ($ScheduledSmokeStart -ge 0) "Workflow job 'scheduled-packaged-smoke' should exist."
$ScheduledSmoke = $Workflow.Substring($ScheduledSmokeStart)

# Issue #150: the only engine entry points are the trusted pull-request compile
# and the four bounded, schedule-only milestone phases. No manual entry point
# of any kind exists on this workflow identity, so an older branch that still
# carries the retired 1,440-minute PackagedSmoke job can never be selected.
$PhaseTrigger = "if: github\.event_name == 'schedule'\r?\n"

Assert-True ($Workflow -match '(?m)^permissions:\r?\n  contents: read\r?$') 'Workflow permissions must remain contents read.'
Assert-True ($Workflow -notmatch '\$\{\{\s*secrets\.' -and $Workflow -notmatch '(?m)^\s*secrets\s*:') 'Workflow must not consume or declare secrets.'
Assert-True ($Workflow -notmatch 'workflow_dispatch') 'Workflow must not expose any manual workflow_dispatch entry point.'
Assert-True ($Workflow -notmatch 'cancelled\(\)' -and $Workflow -notmatch 'failure\(\)') 'Workflow must not use status functions that bypass a failed or skipped prerequisite.'
Assert-MatchCount $Workflow 'always\(\)' ([regex]::Matches($Workflow, '(?m)^\s+if: always\(\)\r?$').Count) 'always() may appear only as the bare step-level predicate that preserves report uploads.'

# Portable job: GitHub-hosted, explicitly bounded, StarterMap-only LFS.
Assert-True ($QualityGates -match '(?m)^\s+runs-on: windows-latest\r?$') 'The portable job must stay on the GitHub-hosted Windows runner.'
Assert-True ($QualityGates -match '(?m)^\s+timeout-minutes: 60\r?$') 'The portable job must declare an explicit conservative bound.'
Assert-True ($QualityGates -notmatch '(?m)^\s+needs:') 'The portable job must not depend on any engine or classifier job.'
Assert-True ($QualityGates -match 'git lfs pull --include "Content/Maps/StarterMap\.umap"') 'The portable job must materialize the StarterMap LFS fixture.'

# Change-impact classifier: GitHub-hosted, pull requests only, checkout plus
# repository-owned PowerShell, exact SHAs passed through env (no expression
# injection into the script body), stable engine_required output.
Assert-True ($ChangeImpact -match "(?m)^\s+if: github\.event_name == 'pull_request'\r?$") 'The classifier must run only for pull requests.'
Assert-True ($ChangeImpact -match '(?m)^\s+runs-on: windows-latest\r?$') 'The classifier must run on the GitHub-hosted Windows runner, never the engine runner.'
Assert-True ($ChangeImpact -match '(?m)^\s+timeout-minutes: 10\r?$') 'The classifier must declare an explicit short bound.'
Assert-True ($ChangeImpact -notmatch 'self-hosted' -and $ChangeImpact -notmatch 'aetheln-engine') 'The classifier must never touch the engine runner or its concurrency group.'
Assert-MatchCount $ChangeImpact '(?m)^\s+-?\s*uses: ' 1 'The classifier must use exactly one action.'
Assert-True ($ChangeImpact -match '(?m)^\s+- uses: actions/checkout@v4\r?$') 'The classifier''s only action must be actions/checkout@v4.'
Assert-True ($ChangeImpact -match '(?m)^\s+engine_required: \$\{\{ steps\.classify\.outputs\.engine_required \}\}\r?$') 'The classifier must publish engine_required as a job output.'
Assert-True ($ChangeImpact -match '(?m)^\s+AETHELN_PR_BASE_SHA: \$\{\{ github\.event\.pull_request\.base\.sha \}\}\r?$') 'The classifier must receive the exact pull-request base SHA through env.'
Assert-True ($ChangeImpact -match '(?m)^\s+AETHELN_PR_HEAD_SHA: \$\{\{ github\.event\.pull_request\.head\.sha \}\}\r?$') 'The classifier must receive the exact pull-request head SHA through env.'
Assert-True ($ChangeImpact -notmatch 'upload-artifact' -and $ChangeImpact -notmatch '-Mode ') 'The classifier must not upload artifacts or invoke the engine gate.'

function Get-ClassifierScript {
	$Lines = $Workflow -split "\r?\n"
	$IdIndex = -1
	for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
		if ($Lines[$Index] -match '^\s+id: classify$') { $IdIndex = $Index; break }
	}
	Assert-True ($IdIndex -ge 0) 'The classifier step must carry id: classify.'
	$RunIndex = -1
	$RunIndent = 0
	for ($Index = $IdIndex; $Index -lt $Lines.Count; $Index++) {
		if ($Lines[$Index] -match '^(\s+)run: \|$') { $RunIndex = $Index; $RunIndent = $Matches[1].Length; break }
	}
	Assert-True ($RunIndex -ge 0) 'The classifier step must contain a literal run block.'
	$Body = @()
	for ($Index = $RunIndex + 1; $Index -lt $Lines.Count; $Index++) {
		$Line = $Lines[$Index]
		if ($Line -eq '') { $Body += ''; continue }
		if ($Line -match '^(\s+)\S' -and $Matches[1].Length -gt $RunIndent) { $Body += $Line; continue }
		break
	}
	$BodyIndent = ($Body | Where-Object { $_ -ne '' } | ForEach-Object { $null = $_ -match '^(\s+)'; $Matches[1].Length } | Measure-Object -Minimum).Minimum
	return (($Body | ForEach-Object { if ($_ -eq '') { '' } else { $_.Substring($BodyIndent) } }) -join "`n")
}

$ClassifierScript = Get-ClassifierScript
Assert-True ($ClassifierScript -notmatch '\$\{\{') 'The classifier script body must not interpolate workflow expressions.'
Assert-True ($ClassifierScript -match '--no-renames') 'The classifier must diff without rename or copy detection so every entry is A/M/D/T.'
$ParseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseInput($ClassifierScript, [ref] $null, [ref] $ParseErrors)
Assert-True ($ParseErrors.Count -eq 0) "The classifier script must parse under Windows PowerShell 5.1: $($ParseErrors | ForEach-Object { $_.Message } | Select-Object -First 1)"

# Trusted compile: pull requests only, owner/same-repo trust, and it may start
# only after the portable gates passed and the classifier demanded the engine.
Assert-True ($TrustedCompile -match '(?m)^\s+needs:\r?\n\s+- quality-gates\r?\n\s+- change-impact\r?$') 'Trusted compile must depend on both the portable gates and the classifier.'
Assert-True ($TrustedCompile -match "needs\.change-impact\.outputs\.engine_required == 'true'") 'Trusted compile must run only when the classifier requires the engine.'
Assert-True ($TrustedCompile -match "github\.event_name == 'pull_request'") 'Trusted compile must remain limited to pull requests.'
Assert-True ($TrustedCompile -match 'github\.event\.pull_request\.head\.repo\.full_name == github\.repository') 'Trusted compile must require the head repository to match this repository.'
Assert-True ($TrustedCompile -match 'github\.event\.pull_request\.user\.login == github\.repository_owner') 'Trusted compile must require the pull request author to be the repository owner.'
Assert-True ($TrustedCompile -match 'github\.triggering_actor == github\.repository_owner') 'Trusted compile must require the triggering actor to be the repository owner.'
Assert-MatchCount $TrustedCompile 'always\(\)' 1 'Trusted compile may use always() only on its report upload, never to bypass a failed, cancelled, or skipped prerequisite.'
Assert-True ($TrustedCompile -match '(?m)^\s+if: always\(\)\r?$') 'Trusted compile must retain its report evidence on failure.'
Assert-MatchCount $TrustedCompile '(?m)^\s+-Mode Compile `\r?$' 1 'Trusted owner pull-request validation must select Compile exactly once.'
Assert-True ($TrustedCompile -notmatch '(?m)^\s+-Mode PackagedSmoke `\r?$') 'Trusted owner pull-request validation must not select PackagedSmoke.'
Assert-True ($TrustedCompile -notmatch 'timeout-minutes:\s*1440') 'Routine trusted compile must not be configured as a 24-hour job.'
Assert-True ($TrustedCompile -notmatch '(?i)clean[^\r\n]*packag|packag[^\r\n]*clean') 'Routine trusted compile must not be described as a clean package gate.'

# The monolithic manual milestone is retired: no job, no PackagedSmoke mode, no
# 24-hour bound anywhere in the workflow.
Assert-True ($Workflow -notmatch 'manual-packaged-smoke') 'Workflow must not define the retired manual-packaged-smoke job.'
Assert-True ($Workflow -notmatch 'engine-runner-manual-smoke-report') 'Workflow must not publish the retired manual smoke artifact.'
Assert-True ($Workflow -notmatch '-Mode PackagedSmoke') 'Workflow must not select the monolithic PackagedSmoke gate anywhere.'
Assert-True ($Workflow -notmatch 'timeout-minutes:\s*1440') 'Workflow must not contain a 24-hour job bound.'

Assert-True ($ScheduledSmoke -match $PhaseTrigger) 'scheduled-packaged-smoke must accept only the schedule event.'
Assert-True ($ScheduledSmoke -notmatch 'pull_request' -and $ScheduledSmoke -notmatch "'push'") 'scheduled-packaged-smoke must not be selectable by pull requests or pushes.'
Assert-MatchCount $ScheduledSmoke '(?m)^\s+-Mode SmokePhase `\r?$' 1 'scheduled-packaged-smoke must select the SmokePhase gate exactly once.'
Assert-True ($ScheduledSmoke -notmatch '(?m)^\s+-Mode (Compile|PackagedSmoke) `\r?$') 'scheduled-packaged-smoke must not select Compile or the single-job PackagedSmoke gate.'
Assert-True ($ScheduledSmoke -match 'timeout-minutes:\s*120') 'scheduled-packaged-smoke must be bounded by its recorded phase limit.'

foreach ($Job in @(
	@{ Name = 'trusted-candidate-compile'; Body = $TrustedCompile; RequiresContentLfs = $true },
	@{ Name = 'scheduled-packaged-smoke'; Body = $ScheduledSmoke; RequiresContentLfs = $false }
)) {
	if ($Job.RequiresContentLfs) {
		Assert-True ($Job.Body -match 'git lfs pull --include "Content/\*\*"') "$($Job.Name) must materialize every Unreal Content LFS object before build or cook."
	}
	Assert-True ($Job.Body -notmatch 'git lfs pull --include "Content/Maps/StarterMap\.umap"') "$($Job.Name) must not fetch only StarterMap."
	Assert-True ($Job.Body -match '(?m)^\s+group: aetheln-engine-runner\r?$') "$($Job.Name) must use the shared engine-runner concurrency group."
	Assert-True ($Job.Body -match '(?m)^\s+cancel-in-progress: false\r?$') "$($Job.Name) must serialize without cancelling an active engine job."
	Assert-True ($Job.Body -match '(?m)^\s+path: TestResults/engine-runner-report\.json\r?$') "$($Job.Name) must upload only its machine-readable engine report."
}

$UploadPaths = @([regex]::Matches($Workflow, '(?m)^\s+path:\s*(TestResults/[^\r\n]+)\r?$') | ForEach-Object { $_.Groups[1].Value.Trim() })
Assert-True ($UploadPaths.Count -eq 6) 'Workflow must publish exactly one JSON report for each portable or selected engine job.'
foreach ($UploadPath in $UploadPaths) {
	Assert-True ($UploadPath -match '^TestResults/(ci-report|engine-runner-report)\.json$') "Upload path '$UploadPath' must be an approved JSON report."
}
Assert-True ($Workflow -notmatch '(?m)^\s+path:\s*.*(?:archives?|logs?|Saved|StagedBuilds)') 'Workflow must not upload packages, archives, logs, or generated Unreal output.'

# Classifier behavior matrix: run the extracted script against fixture commits.
# Every uncertainty (bad SHA, unreachable commit, empty or unparsable diff)
# must fail closed to engine_required=true while the step still exits 0.
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('aetheln-change-impact-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $FixtureRoot
$ScriptPath = Join-Path $FixtureRoot 'classify.ps1'
[IO.File]::WriteAllText($ScriptPath, $ClassifierScript + "`n", (New-Object System.Text.UTF8Encoding $false))
$RepoRoot = Join-Path $FixtureRoot 'repo'

function Invoke-FixtureGit([string[]] $Arguments) {
	$Previous = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		$Output = @(& git -C $RepoRoot @Arguments 2>&1 | ForEach-Object { "$_" })
		$ExitCode = $LASTEXITCODE
	}
	finally {
		$ErrorActionPreference = $Previous
	}
	Assert-True ($ExitCode -eq 0) "fixture git $($Arguments -join ' ') failed: $($Output -join ' ')"
	return ,$Output
}

function Write-FixtureFile([string] $RelativePath, [string] $Content) {
	$FullPath = Join-Path $RepoRoot ($RelativePath -replace '/', '\')
	$Directory = Split-Path -Parent $FullPath
	if (-not (Test-Path -LiteralPath $Directory)) { $null = New-Item -ItemType Directory -Path $Directory -Force }
	[IO.File]::WriteAllText($FullPath, $Content + "`n")
}

function Add-FixtureCommit([string[]] $Write, [string[]] $Delete, [string] $Message, [string[]] $IndexOnly = @()) {
	$Stamp = [guid]::NewGuid().ToString('N')
	foreach ($Path in @($Write)) { if ($Path) { Write-FixtureFile $Path "$Message $Stamp" } }
	foreach ($Path in @($Delete)) { if ($Path) { Remove-Item -LiteralPath (Join-Path $RepoRoot ($Path -replace '/', '\')) -Force } }
	$null = Invoke-FixtureGit @('add', '-A', '--', '.')
	foreach ($Path in @($IndexOnly)) {
		# Case-variant paths cannot be materialized beside their lowercase twin
		# on a case-insensitive filesystem, so they enter the index directly.
		if (-not $Path) { continue }
		$BlobPath = Join-Path $FixtureRoot ('blob-' + $Stamp + '.txt')
		[IO.File]::WriteAllText($BlobPath, "$Message $Stamp $Path`n")
		$Blob = [string] @(Invoke-FixtureGit @('hash-object', '-w', '--', $BlobPath))[0]
		$null = Invoke-FixtureGit @('update-index', '--add', '--cacheinfo', "100644,$Blob,$Path")
	}
	$null = Invoke-FixtureGit @('-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-q', '--allow-empty', '-m', $Message)
	return [string] @(Invoke-FixtureGit @('rev-parse', 'HEAD'))[0]
}

function Invoke-Classifier([string] $BaseSha, [string] $HeadSha, [switch] $OmitBase, [string] $WorkingDirectory = $RepoRoot) {
	$OutputFile = Join-Path $FixtureRoot ('output-' + [guid]::NewGuid().ToString('N') + '.txt')
	$SummaryFile = Join-Path $FixtureRoot ('summary-' + [guid]::NewGuid().ToString('N') + '.md')
	[IO.File]::WriteAllText($OutputFile, '')
	[IO.File]::WriteAllText($SummaryFile, '')
	$env:GITHUB_OUTPUT = $OutputFile
	$env:GITHUB_STEP_SUMMARY = $SummaryFile
	if ($OmitBase) { Remove-Item Env:AETHELN_PR_BASE_SHA -ErrorAction SilentlyContinue } else { $env:AETHELN_PR_BASE_SHA = $BaseSha }
	$env:AETHELN_PR_HEAD_SHA = $HeadSha
	Push-Location -LiteralPath $WorkingDirectory
	try {
		$StdOut = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath 2>&1 | ForEach-Object { "$_" })
		$ExitCode = $LASTEXITCODE
	}
	finally {
		Pop-Location
		foreach ($Name in @('GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY', 'AETHELN_PR_BASE_SHA', 'AETHELN_PR_HEAD_SHA')) { Remove-Item "Env:$Name" -ErrorAction SilentlyContinue }
	}
	$Outputs = @{}
	foreach ($Line in @(Get-Content -LiteralPath $OutputFile)) {
		if ($Line -match '^([a-z_]+)=(.*)$') { $Outputs[$Matches[1]] = $Matches[2] }
	}
	return @{ ExitCode = $ExitCode; Outputs = $Outputs; Summary = [string] (Get-Content -LiteralPath $SummaryFile -Raw); StdOut = $StdOut }
}

function Assert-Classification([string] $Case, [hashtable] $Result, [string] $EngineRequired, [string] $Reason) {
	Assert-True ($Result.ExitCode -eq 0) "[$Case] classifier step must exit 0 so the compile decision is always published (stdout: $($Result.StdOut -join ' '))."
	Assert-True ($Result.Outputs.ContainsKey('engine_required') -and $Result.Outputs['engine_required'] -ceq $EngineRequired) "[$Case] expected engine_required=$EngineRequired, got '$($Result.Outputs['engine_required'])' (reason '$($Result.Outputs['reason'])')."
	Assert-True ($Result.Outputs.ContainsKey('reason') -and $Result.Outputs['reason'] -ceq $Reason) "[$Case] expected reason=$Reason, got '$($Result.Outputs['reason'])'."
	Assert-True ($Result.Summary -match ('engine_required=' + $EngineRequired) -and $Result.Summary -match [regex]::Escape($Reason)) "[$Case] step summary must state the decision and reason."
	Assert-True (([regex]::Matches($Result.Summary, "`n")).Count -le 2) "[$Case] step summary must stay concise."
}

try {
	$null = New-Item -ItemType Directory -Path $RepoRoot
	$null = Invoke-FixtureGit @('init', '-q')
	$null = Invoke-FixtureGit @('config', 'core.autocrlf', 'false')
	$null = Invoke-FixtureGit @('config', 'core.quotePath', 'true')
	$Seed = @(
		'AethelnOnline.uproject', 'Source/AethelnOnline/A.cpp', 'Source/AethelnOnline/README.md', 'Config/DefaultEngine.ini',
		'Content/Maps/Seed.txt', 'Plugins/Seed/Seed.uplugin', 'scripts/ci/Seed.ps1', '.github/workflows/prototype-quality-gates.yml',
		'.github/ISSUE_TEMPLATE/bug-report.md', 'docs/a.md', 'docs/sub/b.md', 'visuals/a.svg', 'output/pdf/a.pdf',
		'tests/ci/Seed.Tests.ps1', 'tests/ci/fixture.json', 'README.md', 'AGENTS.md'
	)
	$BaseSha = Add-FixtureCommit -Write $Seed -Delete @() -Message 'base'

	$Matrix = @(
		# Portable-only set: no Unreal compile.
		@{ Case = 'docs markdown'; Write = @('docs/a.md'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'docs nested any extension'; Write = @('docs/sub/new.png', 'docs/sub/b.md'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'visuals'; Write = @('visuals/a.svg', 'visuals/new/b.png'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'output pdf'; Write = @('output/pdf/a.pdf'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'tests ps1 and md only'; Write = @('tests/ci/Seed.Tests.ps1', 'tests/build/New.Tests.ps1', 'tests/README.md'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'top-level markdown'; Write = @('README.md', 'AGENTS.md', 'CHANGELOG.md'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'issue templates markdown and yaml'; Write = @('.github/ISSUE_TEMPLATE/bug-report.md', '.github/ISSUE_TEMPLATE/config.yml', '.github/ISSUE_TEMPLATE/feature.yaml'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'pull request template'; Write = @('.github/PULL_REQUEST_TEMPLATE.md', '.github/PULL_REQUEST_TEMPLATE/default.md'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'portable deletion'; Write = @(); Delete = @('docs/sub/b.md', 'visuals/a.svg'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'portable rename appears as delete plus add'; Write = @('docs/renamed.md'); Delete = @('docs/a.md'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'portable combination'; Write = @('docs/a.md', 'README.md', 'tests/ci/Seed.Tests.ps1', 'visuals/a.svg', '.github/ISSUE_TEMPLATE/bug-report.md'); Expect = 'false'; Reason = 'portable_paths_only' },
		# Engine-impact set: compile required.
		@{ Case = 'Source'; Write = @('Source/AethelnOnline/A.cpp'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'Config'; Write = @('Config/DefaultEngine.ini'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'Content'; Write = @('Content/Maps/Seed.txt'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'Plugins'; Write = @('Plugins/Seed/Seed.uplugin'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'scripts'; Write = @('scripts/ci/Seed.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'workflow file'; Write = @('.github/workflows/prototype-quality-gates.yml'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'new workflow file'; Write = @('.github/workflows/new.yml'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'other .github yaml'; Write = @('.github/dependabot.yml'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'template directory non-markdown'; Write = @('.github/ISSUE_TEMPLATE/script.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'uproject'; Write = @('AethelnOnline.uproject'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'tests non-ps1 non-md'; Write = @('tests/ci/fixture.json'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'tests ps1 plus fixture'; Write = @('tests/ci/Seed.Tests.ps1', 'tests/ci/fixture.json'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different docs directory'; Write = @(); IndexOnly = @('Docs/x.md'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different markdown extension'; Write = @(); IndexOnly = @('docs/x.MD', 'CHANGELOG.MD'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different tests directory'; Write = @(); IndexOnly = @('Tests/ci/x.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'nested markdown outside portable roots'; Write = @('Source/AethelnOnline/README.md'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'top-level non-markdown'; Write = @('Setup.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'engine deletion'; Write = @(); Delete = @('Source/AethelnOnline/A.cpp'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'mixed docs and Source'; Write = @('docs/a.md', 'Source/AethelnOnline/A.cpp'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'mixed portable set plus scripts'; Write = @('README.md', 'visuals/a.svg', 'scripts/ci/Seed.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' }
	)
	foreach ($Entry in $Matrix) {
		$null = Invoke-FixtureGit @('checkout', '-q', '--detach', $BaseSha)
		$Delete = if ($Entry.ContainsKey('Delete')) { $Entry.Delete } else { @() }
		$IndexOnly = if ($Entry.ContainsKey('IndexOnly')) { $Entry.IndexOnly } else { @() }
		$HeadSha = Add-FixtureCommit -Write $Entry.Write -Delete $Delete -Message $Entry.Case -IndexOnly $IndexOnly
		Assert-Classification $Entry.Case (Invoke-Classifier $BaseSha $HeadSha) $Entry.Expect $Entry.Reason
	}

	# Fail-closed uncertainty cases.
	$null = Invoke-FixtureGit @('checkout', '-q', '--detach', $BaseSha)
	$DocsHead = Add-FixtureCommit -Write @('docs/a.md') -Delete @() -Message 'docs for uncertainty cases'
	Assert-Classification 'short base sha' (Invoke-Classifier $BaseSha.Substring(0, 12) $DocsHead) 'true' 'invalid_sha'
	Assert-Classification 'uppercase head sha' (Invoke-Classifier $BaseSha $DocsHead.ToUpperInvariant()) 'true' 'invalid_sha'
	Assert-Classification 'missing base sha' (Invoke-Classifier '' $DocsHead -OmitBase) 'true' 'invalid_sha'
	Assert-Classification 'identical shas' (Invoke-Classifier $DocsHead $DocsHead) 'true' 'identical_shas'
	Assert-Classification 'unreachable base sha' (Invoke-Classifier ('0' * 40) $DocsHead) 'true' 'commit_unavailable'
	Assert-Classification 'unreachable head sha' (Invoke-Classifier $BaseSha ('f' * 40)) 'true' 'commit_unavailable'
	$null = Invoke-FixtureGit @('checkout', '-q', '--detach', $BaseSha)
	$EmptyHead = Add-FixtureCommit -Write @() -Delete @() -Message 'empty'
	Assert-Classification 'empty diff' (Invoke-Classifier $BaseSha $EmptyHead) 'true' 'empty_diff'
	$null = Invoke-FixtureGit @('checkout', '-q', '--detach', $BaseSha)
	$QuotedHead = Add-FixtureCommit -Write @([string]::Concat('docs/', [char] 0x00FC, 'ber.md')) -Delete @() -Message 'quoted path'
	Assert-Classification 'quoted non-ascii path' (Invoke-Classifier $BaseSha $QuotedHead) 'true' 'unexpected_diff_entry'

	# Production path: actions/checkout on pull_request materializes only the
	# depth-1 merge commit, so both SHAs are absent locally and must be fetched
	# by SHA from origin before the diff. Exercise fetch-then-classify from a
	# shallow clone whose origin allows SHA fetches, as GitHub does.
	$null = Invoke-FixtureGit @('branch', '-f', 'fixture-other', $EmptyHead)
	$BareRoot = Join-Path $FixtureRoot 'origin.git'
	$ShallowRoot = Join-Path $FixtureRoot 'shallow'
	$null = Invoke-FixtureGit @('clone', '-q', '--bare', $RepoRoot, $BareRoot)
	$null = Invoke-FixtureGit @('-C', $BareRoot, 'config', 'uploadpack.allowAnySHA1InWant', 'true')
	# A plain local path ignores --depth; the file:// transport honors it and
	# routes later SHA fetches through upload-pack like a remote origin.
	$BareUrl = 'file:///' + ($BareRoot -replace '\\', '/')
	$null = Invoke-FixtureGit @('clone', '-q', '--depth', '1', '--no-tags', '--branch', 'fixture-other', $BareUrl, $ShallowRoot)
	foreach ($Revision in @($BaseSha, $DocsHead)) {
		$Missing = Invoke-FixtureGit @('-C', $ShallowRoot, 'rev-list', '--all')
		Assert-True ($Missing -notcontains $Revision) "shallow fixture must not already contain $Revision."
	}
	Assert-Classification 'shallow clone fetches both shas then classifies portable' (Invoke-Classifier $BaseSha $DocsHead -WorkingDirectory $ShallowRoot) 'false' 'portable_paths_only'
	$null = Invoke-FixtureGit @('checkout', '-q', '--detach', $BaseSha)
	$SourceHead = Add-FixtureCommit -Write @('Source/AethelnOnline/A.cpp') -Delete @() -Message 'source for shallow case'
	$null = Invoke-FixtureGit @('-C', $BareRoot, 'fetch', '-q', $RepoRoot, "${SourceHead}:refs/heads/fixture-source")
	Assert-Classification 'shallow clone fetches both shas then classifies engine' (Invoke-Classifier $BaseSha $SourceHead -WorkingDirectory $ShallowRoot) 'true' 'engine_paths_changed'
}
finally {
	Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'PASS: workflow exposes no manual entry point, gates trusted compile behind portable success and the change-impact classifier, and retires the monolithic packaged-smoke job'
Write-Output 'PASS: classifier skips compile only for the closed portable set and fails closed on every uncertainty'
Write-Output 'PASS: workflow preserves LFS, serialization, report-only upload, and no-secret policy'
exit 0
