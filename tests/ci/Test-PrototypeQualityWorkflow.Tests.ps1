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

$ShadowSelection = Get-JobBody 'ci-selection-shadow' 'quality-gates'
$QualityGates = Get-JobBody 'quality-gates' 'change-impact'
$ChangeImpact = Get-JobBody 'change-impact' 'trusted-candidate-compile'
$TrustedCompile = Get-JobBody 'trusted-candidate-compile' 'scheduled-client-package'
$ScheduledSmokeStart = $Workflow.IndexOf('  scheduled-packaged-smoke:', [StringComparison]::Ordinal)
Assert-True ($ScheduledSmokeStart -ge 0) "Workflow job 'scheduled-packaged-smoke' should exist."
$ScheduledSmoke = $Workflow.Substring($ScheduledSmokeStart)

# Persistent DDC repository identity uses the root-commit set. Every milestone
# checkout needs complete ancestry so a shallow boundary cannot become a root.
foreach ($Job in @(
	@{ Name = 'scheduled-client-package'; Body = (Get-JobBody 'scheduled-client-package' 'scheduled-server-package') },
	@{ Name = 'scheduled-server-package'; Body = (Get-JobBody 'scheduled-server-package' 'scheduled-provenance-validation') },
	@{ Name = 'scheduled-provenance-validation'; Body = (Get-JobBody 'scheduled-provenance-validation' 'scheduled-packaged-smoke') },
	@{ Name = 'scheduled-packaged-smoke'; Body = $ScheduledSmoke }
)) {
	$Checkout = [regex]::Match($Job.Body, '(?m)^      - uses: actions/checkout@v4\r?\n        with:\r?\n(?<Inputs>(?:          [^\r\n]+\r?\n)+)')
	Assert-True ($Checkout.Success) "$($Job.Name) must declare its checkout inputs."
	Assert-MatchCount -Text $Checkout.Groups['Inputs'].Value -Pattern '(?m)^          fetch-depth: 0\r?$' -Expected 1 -Message "$($Job.Name) must fetch complete ancestry for stable DDC repository identity."
}

# Issue #150: the only engine entry points are the trusted pull-request compile
# and the four bounded, schedule-only milestone phases. No manual entry point
# of any kind exists on this workflow identity, so an older branch that still
# carries the retired 1,440-minute PackagedSmoke job can never be selected.
$PhaseTrigger = "if: github\.event_name == 'schedule'\r?\n"

Assert-True ($Workflow -match '(?m)^permissions:\r?\n  contents: read\r?$') 'Workflow permissions must remain contents read.'
Assert-True ($Workflow -notmatch '\$\{\{\s*secrets\.' -and $Workflow -notmatch '(?m)^\s*secrets\s*:') 'Workflow must not consume or declare secrets.'
Assert-True ($Workflow -notmatch 'workflow_dispatch') 'Workflow must not expose any manual workflow_dispatch entry point.'
Assert-True ($Workflow -notmatch 'cancelled\(\)' -and $Workflow -notmatch 'failure\(\)') 'Workflow must not use status functions that bypass a failed or skipped prerequisite.'
Assert-MatchCount -Text $Workflow -Pattern 'always\(\)' -Expected ([regex]::Matches($Workflow, '(?m)^\s+if: always\(\)\r?$').Count) -Message 'always() may appear only as the bare step-level predicate that preserves report uploads.'

# Issue #167 Package 2: an independent pull-request-only shadow computes the
# future selection record without controlling any existing job. It fetches the
# exact immutable graph before the only checkout, and that checkout is the
# accepted base sparse control path rather than candidate executable bytes.
Assert-True ($ShadowSelection -match "(?m)^\s+if: github\.event_name == 'pull_request'\r?$") 'The shadow selector must run only for pull requests.'
Assert-True ($ShadowSelection -match '(?m)^\s+continue-on-error: true\r?$') 'Shadow evidence must remain observational and cannot fail the authoritative workflow result.'
Assert-True ($ShadowSelection -match '(?m)^\s+runs-on: windows-latest\r?$' -and $ShadowSelection -match '(?m)^\s+timeout-minutes: 10\r?$') 'The shadow selector must be a bounded GitHub-hosted job.'
Assert-True ($ShadowSelection -notmatch '(?m)^\s+needs:' -and $ShadowSelection -notmatch '(?m)^\s+outputs:') 'The shadow selector must expose no authority or dependency edge.'
Assert-True ($ShadowSelection -notmatch 'self-hosted|aetheln-engine-runner|needs\.') 'The shadow selector must not admit or influence engine work.'
Assert-MatchCount -Text $ShadowSelection -Pattern '(?m)^\s+- uses: actions/checkout@v4\r?$' -Expected 1 -Message 'The shadow selector must perform exactly one checkout.'
Assert-True ($ShadowSelection -match 'ref: \$\{\{ github\.event\.pull_request\.base\.sha \}\}' -and $ShadowSelection -match 'sparse-checkout: scripts/ci/Get-CiSelection\.ps1' -and $ShadowSelection -match 'persist-credentials: false') 'The only shadow checkout must sparsely materialize the exact accepted-base selector without credentials.'
$FetchPosition = $ShadowSelection.IndexOf('name: Fetch immutable comparison objects', [StringComparison]::Ordinal)
$CheckoutPosition = $ShadowSelection.IndexOf('uses: actions/checkout@v4', [StringComparison]::Ordinal)
Assert-True ($FetchPosition -ge 0 -and $CheckoutPosition -gt $FetchPosition) 'Base, head and workflow objects must enter the bare control repository before any checkout.'
foreach ($Binding in @('github.event.pull_request.base.sha', 'github.event.pull_request.head.sha', 'github.sha')) {
	Assert-True ($ShadowSelection.Contains($Binding)) "Shadow selection must bind exact immutable identity $Binding."
}
Assert-True ($ShadowSelection -match 'git init --bare' -and $ShadowSelection -match 'accepted_controller_unavailable') 'Bootstrap must use a bare control repository and explicitly diagnose an unavailable accepted controller.'
Assert-True ($ShadowSelection -match 'AETHELN_GITHUB_TOKEN: \$\{\{ github\.token \}\}' -and $ShadowSelection -match "GIT_CONFIG_KEY_0 = 'http\.extraheader'" -and $ShadowSelection -match 'GIT_CONFIG_VALUE_0 = "AUTHORIZATION: basic \$Authorization"' -and $ShadowSelection -match '::add-mask::\$Authorization') 'Private-repository object fetches must use the ephemeral GitHub token through a masked environment-backed authorization header.'
Assert-True ($ShadowSelection -notmatch 'persist-credentials: true' -and $ShadowSelection -notmatch 'https://x-access-token:') 'Shadow bootstrap credentials must not persist in the checkout or remote URL.'
Assert-True ($ShadowSelection -match 'Get-CiSelection\.ps1' -and $ShadowSelection -match '-ContextJson' -and $ShadowSelection -match '-OutputPath' -and $ShadowSelection -match '-RepositoryRoot') 'Only the accepted-base selector entry point may produce a live shadow record.'
Assert-True ($ShadowSelection -match 'controllerBlobOid' -and $ShadowSelection -match 'controllerSha256') 'Shadow evidence must record the accepted controller blob OID and SHA-256 when available.'
Assert-True ($ShadowSelection -match 'selection\.shadow|shadow = \$true' -and $ShadowSelection -match 'authoritative = \$false' -and $ShadowSelection -match 'checkoutAllowed = \$false') 'Bootstrap evidence must be explicitly shadow-only, non-authoritative, and unable to authorize checkout.'
Assert-MatchCount -Text $ShadowSelection -Pattern '(?m)^\s+uses: actions/upload-artifact@v4\r?$' -Expected 1 -Message 'The shadow job must have one artifact producer.'
Assert-True ($ShadowSelection -match 'name: ci-selection-shadow-\$\{\{ github\.run_id \}\}-\$\{\{ github\.run_attempt \}\}' -and $ShadowSelection -match 'path: \$\{\{ runner\.temp \}\}/ci-selection-shadow\.json') 'The shadow artifact must be run/attempt-specific and contain the exact report path.'
Assert-True ($ShadowSelection -notmatch 'retention-days:' -and $ShadowSelection -notmatch '(?m)^\s+path: .*\*') 'The shadow artifact must use default retention and an exact single-file path.'
$ShadowRunBlocks = @([regex]::Matches($ShadowSelection, '(?ms)^        run: \|\r?\n(?<body>.*?)(?=^      - |\z)'))
Assert-True ($ShadowRunBlocks.Count -eq 2) 'Shadow selection must keep exactly two repository-owned PowerShell run blocks.'
foreach ($RunBlock in $ShadowRunBlocks) {
	$Body = (($RunBlock.Groups['body'].Value -split "`r?`n") | ForEach-Object { if ($_.Length -ge 10) { $_.Substring(10) } else { $_ } }) -join "`n"
	$ShadowParseErrors = $null
	$null = [Management.Automation.Language.Parser]::ParseInput($Body, [ref] $null, [ref] $ShadowParseErrors)
	Assert-True ($ShadowParseErrors.Count -eq 0) "Shadow PowerShell must parse under Windows PowerShell 5.1: $($ShadowParseErrors | Select-Object -First 1 | ForEach-Object Message)"
}

$VisualWorkflow = Get-Content -LiteralPath (Join-Path $RepositoryRoot '.github\workflows\visual-package-validation.yml') -Raw
Assert-True ($VisualWorkflow -match '(?m)^  workflow_call:\r?$') 'Visual validation must expose an additive reusable workflow entry point.'
Assert-True ($VisualWorkflow -match '(?ms)^  pull_request:\r?\n    paths:.*?^  push:\r?\n    branches:\r?\n      - develop\r?\n    paths:') 'Visual validation must preserve its path-filtered pull-request and develop-push triggers.'
foreach ($Validator in @('.\visuals\Test-VisualPackage.ps1', '.\visuals\tests\Test-VisualPackageValidation.ps1')) {
	Assert-MatchCount -Text $VisualWorkflow -Pattern ([regex]::Escape($Validator)) -Expected 1 -Message "Visual workflow must preserve validator $Validator exactly once."
}

# Portable job: GitHub-hosted, explicitly bounded, StarterMap-only LFS.
Assert-True ($QualityGates -match '(?m)^\s+runs-on: windows-latest\r?$') 'The portable job must stay on the GitHub-hosted Windows runner.'
Assert-True ($QualityGates -match '(?m)^\s+timeout-minutes: 30\r?$') 'The portable job must declare an explicit conservative bound.'
Assert-True ($QualityGates -notmatch '(?m)^\s+needs:') 'The portable job must not depend on any engine or classifier job.'
Assert-True ($QualityGates -match 'git lfs pull --include "Content/Maps/StarterMap\.umap"') 'The portable job must materialize the StarterMap LFS fixture.'

# Change-impact classifier: GitHub-hosted, pull requests only, checkout plus
# repository-owned PowerShell, exact SHAs passed through env (no expression
# injection into the script body), stable engine_required output.
Assert-True ($ChangeImpact -match "(?m)^\s+if: github\.event_name == 'pull_request'\r?$") 'The classifier must run only for pull requests.'
Assert-True ($ChangeImpact -match '(?m)^\s+runs-on: windows-latest\r?$') 'The classifier must run on the GitHub-hosted Windows runner, never the engine runner.'
Assert-True ($ChangeImpact -match '(?m)^\s+timeout-minutes: 10\r?$') 'The classifier must declare an explicit short bound.'
Assert-True ($ChangeImpact -notmatch 'self-hosted' -and $ChangeImpact -notmatch 'aetheln-engine') 'The classifier must never touch the engine runner or its concurrency group.'
Assert-MatchCount -Text $ChangeImpact -Pattern '(?m)^\s+-?\s*uses: ' -Expected 1 -Message 'The classifier must use exactly one action.'
Assert-True ($ChangeImpact -match '(?m)^\s+- uses: actions/checkout@v4\r?$') 'The classifier''s only action must be actions/checkout@v4.'
Assert-True ($ChangeImpact -match '(?m)^\s+engine_required: \$\{\{ steps\.classify\.outputs\.engine_required \}\}\r?$') 'The classifier must publish engine_required as a job output.'
Assert-True ($ChangeImpact -match '(?m)^\s+AETHELN_PR_BASE_SHA: \$\{\{ github\.event\.pull_request\.base\.sha \}\}\r?$') 'The classifier must receive the exact pull-request base SHA through env.'
Assert-True ($ChangeImpact -match '(?m)^\s+AETHELN_PR_HEAD_SHA: \$\{\{ github\.event\.pull_request\.head\.sha \}\}\r?$') 'The classifier must receive the exact pull-request head SHA through env.'
Assert-True ($ChangeImpact -notmatch 'upload-artifact' -and $ChangeImpact -notmatch '-Mode ') 'The classifier must not upload artifacts or invoke the engine gate.'
$NormalizedWorkflow = $Workflow.Replace("`r`n", "`n")
$LegacyStart = $NormalizedWorkflow.IndexOf('  change-impact:', [StringComparison]::Ordinal)
$LegacyEnd = $NormalizedWorkflow.IndexOf('  trusted-candidate-compile:', $LegacyStart, [StringComparison]::Ordinal)
Assert-True ($LegacyStart -ge 0 -and $LegacyEnd -gt $LegacyStart) 'The authoritative legacy classifier block must remain addressable by exact job markers.'
$LegacyBytes = [Text.Encoding]::UTF8.GetBytes($NormalizedWorkflow.Substring($LegacyStart, $LegacyEnd - $LegacyStart))
$LegacyHasher = [Security.Cryptography.SHA256]::Create()
try { $LegacyDigest = ([BitConverter]::ToString($LegacyHasher.ComputeHash($LegacyBytes)) -replace '-', '').ToLowerInvariant() }
finally { $LegacyHasher.Dispose() }
Assert-True ($LegacyBytes.Length -eq 5595 -and $LegacyDigest -ceq 'b69855c18bf8a8dd0a7e686b80d97d338c558b0868c27a05bf7cbdf9b3c04b6c') 'The existing change-impact block and its explanatory trust boundary must remain byte-for-byte unchanged after LF normalization.'

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
Assert-MatchCount -Text $TrustedCompile -Pattern 'always\(\)' -Expected 1 -Message 'Trusted compile may use always() only on its report upload, never to bypass a failed, cancelled, or skipped prerequisite.'
Assert-True ($TrustedCompile -match '(?m)^\s+if: always\(\)\r?$') 'Trusted compile must retain its report evidence on failure.'
Assert-MatchCount -Text $TrustedCompile -Pattern '(?m)^\s+-Mode Compile `\r?$' -Expected 1 -Message 'Trusted owner pull-request validation must select Compile exactly once.'
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
Assert-MatchCount -Text $ScheduledSmoke -Pattern '(?m)^\s+-Mode SmokePhase `\r?$' -Expected 1 -Message 'scheduled-packaged-smoke must select the SmokePhase gate exactly once.'
Assert-True ($ScheduledSmoke -notmatch '(?m)^\s+-Mode (Compile|PackagedSmoke) `\r?$') 'scheduled-packaged-smoke must not select Compile or the single-job PackagedSmoke gate.'
Assert-True ($ScheduledSmoke -match 'timeout-minutes:\s*20') 'scheduled-packaged-smoke must be bounded by its recorded phase limit.'

foreach ($Job in @(
	@{ Name = 'trusted-candidate-compile'; Body = $TrustedCompile; RequiresContentLfs = $false },
	@{ Name = 'scheduled-packaged-smoke'; Body = $ScheduledSmoke; RequiresContentLfs = $false }
)) {
	if ($Job.Name -eq 'trusted-candidate-compile') {
		Assert-True ($Job.Body -match '-ManagedWorkspaceRoot' -and $Job.Body -match '-HostLeasePath') 'Compile must validate selected materialized inputs inside the owned managed workspace operation.'
		Assert-True ($Job.Body -notmatch 'git lfs pull') 'Compile must not hydrate retained inputs outside supervised ownership.'
		Assert-True ($Job.Body.IndexOf('name: Capture routine compile deadline') -ge 0 -and $Job.Body.IndexOf('name: Capture routine compile deadline') -lt $Job.Body.IndexOf('uses: actions/checkout@v4')) 'Compile must start its controlled budget before checkout.'
		Assert-True ($Job.Body.Contains('-CompileStartedUtc $env:AETHELN_COMPILE_STARTED_UTC') -and $Job.Body.Contains('-CompileStartedTimestamp $env:AETHELN_COMPILE_STARTED_TIMESTAMP')) 'Compile must pass the original UTC and monotonic anchors into the gate.'
	}
	if ($Job.RequiresContentLfs) {
		Assert-True ($Job.Body -match 'git lfs pull --include "Content/\*\*"') "$($Job.Name) must materialize every Unreal Content LFS object before build or cook."
	}
	Assert-True ($Job.Body -notmatch 'git lfs pull --include "Content/Maps/StarterMap\.umap"') "$($Job.Name) must not fetch only StarterMap."
	Assert-True ($Job.Body -match '(?m)^\s+group: aetheln-engine-runner\r?$') "$($Job.Name) must use the shared engine-runner concurrency group."
	Assert-True ($Job.Body -match '(?m)^\s+cancel-in-progress: false\r?$') "$($Job.Name) must serialize without cancelling an active engine job."
	Assert-True ($Job.Body -match '(?m)^\s+path: .*engine-runner-report\.json\r?$') "$($Job.Name) must upload only its machine-readable engine report."
}

$ReportUploads = @([regex]::Matches($Workflow, '(?m)^          path: (.+(?:ci-report|engine-runner-report)\.json)\r?$'))
Assert-True ($ReportUploads.Count -eq 6) 'Exactly six report uploads remain.'
Assert-True ($TrustedCompile.Contains('path: ${{ runner.temp }}/aetheln-engine-${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}/engine-runner-report.json')) 'Compile artifact is unique to this run, attempt and job.'
Assert-True ($TrustedCompile -match 'timeout-minutes: 40' -and $TrustedCompile -match '-CompileTimeoutMinutes 30') 'Routine compile has a whole-job and controlled-work limit.'
Assert-True ($Workflow -notmatch '(?m)^          path: .*\*') 'Uploads cannot contain wildcard payload paths.'
Assert-MatchCount -Text $Workflow -Pattern '(?m)^\s*uses: actions/upload-artifact@' -Expected 7 -Message 'Only the six existing report uploads and one shadow-selection upload are permitted.'
Assert-True ($Workflow -notmatch '(?m)^\s+path:\s*.*(?:archives?|logs?|Saved|StagedBuilds)') 'Generated payload directories must never be uploaded.'

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
	# The exact CI paths are added per case, not seeded: their index-only case
	# variants must not collide with a tracked twin on Windows.
	$Seed = @(
		'AethelnOnline.uproject', 'Source/AethelnOnline/A.cpp', 'Source/AethelnOnline/README.md', 'Config/DefaultEngine.ini',
		'Content/Maps/Seed.txt', 'Plugins/Seed/Seed.uplugin', 'scripts/ci/Seed.ps1',
		'.github/ISSUE_TEMPLATE/bug-report.md', 'docs/a.md', 'docs/sub/b.md', 'visuals/a.svg', 'output/pdf/a.pdf',
		'tests/ci/Seed.Tests.ps1', 'tests/ci/fixture.json', 'README.md', 'AGENTS.md'
	)
	$BaseSha = Add-FixtureCommit -Write $Seed -Delete @() -Message 'base'

	$Matrix = @(
		@{ Case = 'exact packaging orchestration'; Write = @('scripts/build/Build-PackagedArtifacts.ps1'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'exact engine wrapper'; Write = @('scripts/ci/Invoke-EngineRunnerGate.ps1'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'exact retention helper'; Write = @('scripts/ci/Initialize-CompileWorkspace.ps1'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'exact smoke evidence runner'; Write = @('scripts/build/Invoke-PackagedSmokeTest.ps1'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'smoke runner lookalike'; Write = @('scripts/build/Invoke-PackagedSmokeTestHelper.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different smoke runner'; Write = @(); IndexOnly = @('scripts/build/invoke-PackagedSmokeTest.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'smoke runner mixed with C++'; Write = @('scripts/build/Invoke-PackagedSmokeTest.ps1', 'Source/AethelnOnline/A.cpp'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'orchestration mixed with C++'; Write = @('scripts/ci/Invoke-EngineRunnerGate.ps1', 'Source/AethelnOnline/A.cpp'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'retention helper lookalike'; Write = @('scripts/ci/Initialize-CompileWorkspace.psm1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different wrapper'; Write = @(); IndexOnly = @('scripts/ci/invoke-EngineRunnerGate.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different packaging'; Write = @(); IndexOnly = @('Scripts/build/Build-PackagedArtifacts.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different retention'; Write = @(); IndexOnly = @('scripts/ci/initialize-CompileWorkspace.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		# Portable-only set: no Unreal compile.
		@{ Case = 'exact portable CI suite'; Write = @('scripts/ci/Invoke-CiSuite.ps1'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'exact portable formatting policy'; Write = @('scripts/ci/Test-FormattingPolicy.ps1'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'exact portable markdown links'; Write = @('scripts/ci/Test-MarkdownLinks.ps1'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'exact tested prototype workflow'; Write = @('.github/workflows/prototype-quality-gates.yml'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'portable CI workflow plus fixtures'; Write = @('scripts/ci/Invoke-CiSuite.ps1', '.github/workflows/prototype-quality-gates.yml', 'tests/ci/Seed.Tests.ps1', 'docs/a.md'); Expect = 'false'; Reason = 'portable_paths_only' },
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
		@{ Case = 'CI suite lookalike'; Write = @('scripts/ci/Invoke-CiSuite.ps1.bak'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'formatting policy lookalike'; Write = @('scripts/ci/Test-FormattingPolicyExtra.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'markdown links lookalike'; Write = @('scripts/ci/sub/Test-MarkdownLinks.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'workflow lookalike'; Write = @('.github/workflows/prototype-quality-gates.yaml'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different CI suite'; Write = @(); IndexOnly = @('scripts/ci/invoke-CiSuite.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different formatting directory'; Write = @(); IndexOnly = @('Scripts/ci/Test-FormattingPolicy.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different markdown checker extension'; Write = @(); IndexOnly = @('scripts/ci/Test-MarkdownLinks.PS1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'case-different workflow'; Write = @(); IndexOnly = @('.github/workflows/Prototype-quality-gates.yml'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'engine gate script'; Write = @('scripts/ci/Invoke-EngineRunnerGate.ps1'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'real Unreal automation script'; Write = @('scripts/ci/Invoke-UnrealAutomationTests.ps1'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'packaging script'; Write = @('scripts/build/Build-PackagedArtifacts.ps1'); Expect = 'false'; Reason = 'portable_paths_only' },
		@{ Case = 'mixed portable CI and Source'; Write = @('scripts/ci/Invoke-CiSuite.ps1', 'Source/AethelnOnline/A.cpp'); Expect = 'true'; Reason = 'engine_paths_changed' },
		@{ Case = 'mixed tested workflow and engine gate'; Write = @('.github/workflows/prototype-quality-gates.yml', 'scripts/ci/Invoke-EngineRunnerGate.ps1'); Expect = 'false'; Reason = 'portable_paths_only' },
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
		Assert-Classification -Case $Entry.Case -Result (Invoke-Classifier $BaseSha $HeadSha) -EngineRequired $Entry.Expect -Reason $Entry.Reason
	}

	# Fail-closed uncertainty cases.
	$null = Invoke-FixtureGit @('checkout', '-q', '--detach', $BaseSha)
	$DocsHead = Add-FixtureCommit -Write @('docs/a.md') -Delete @() -Message 'docs for uncertainty cases'
	Assert-Classification -Case 'short base sha' -Result (Invoke-Classifier $BaseSha.Substring(0, 12) $DocsHead) -EngineRequired 'true' -Reason 'invalid_sha'
	Assert-Classification -Case 'uppercase head sha' -Result (Invoke-Classifier $BaseSha $DocsHead.ToUpperInvariant()) -EngineRequired 'true' -Reason 'invalid_sha'
	Assert-Classification -Case 'missing base sha' -Result (Invoke-Classifier '' $DocsHead -OmitBase) -EngineRequired 'true' -Reason 'invalid_sha'
	Assert-Classification -Case 'identical shas' -Result (Invoke-Classifier $DocsHead $DocsHead) -EngineRequired 'true' -Reason 'identical_shas'
	Assert-Classification -Case 'unreachable base sha' -Result (Invoke-Classifier ('0' * 40) $DocsHead) -EngineRequired 'true' -Reason 'commit_unavailable'
	Assert-Classification -Case 'unreachable head sha' -Result (Invoke-Classifier $BaseSha ('f' * 40)) -EngineRequired 'true' -Reason 'commit_unavailable'
	$null = Invoke-FixtureGit @('checkout', '-q', '--detach', $BaseSha)
	$EmptyHead = Add-FixtureCommit -Write @() -Delete @() -Message 'empty'
	Assert-Classification -Case 'empty diff' -Result (Invoke-Classifier $BaseSha $EmptyHead) -EngineRequired 'true' -Reason 'empty_diff'
	$null = Invoke-FixtureGit @('checkout', '-q', '--detach', $BaseSha)
	$QuotedHead = Add-FixtureCommit -Write @([string]::Concat('docs/', [char] 0x00FC, 'ber.md')) -Delete @() -Message 'quoted path'
	Assert-Classification -Case 'quoted non-ascii path' -Result (Invoke-Classifier $BaseSha $QuotedHead) -EngineRequired 'true' -Reason 'unexpected_diff_entry'

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
	Assert-Classification -Case 'shallow clone fetches both shas then classifies portable' -Result (Invoke-Classifier $BaseSha $DocsHead -WorkingDirectory $ShallowRoot) -EngineRequired 'false' -Reason 'portable_paths_only'
	$null = Invoke-FixtureGit @('checkout', '-q', '--detach', $BaseSha)
	$SourceHead = Add-FixtureCommit -Write @('Source/AethelnOnline/A.cpp') -Delete @() -Message 'source for shallow case'
	$null = Invoke-FixtureGit @('-C', $BareRoot, 'fetch', '-q', $RepoRoot, "${SourceHead}:refs/heads/fixture-source")
	Assert-Classification -Case 'shallow clone fetches both shas then classifies engine' -Result (Invoke-Classifier $BaseSha $SourceHead -WorkingDirectory $ShallowRoot) -EngineRequired 'true' -Reason 'engine_paths_changed'

	# Reproduce DDC identity drift across consecutive shallow checkouts, then
	# prove that complete ancestry restores the same root set at both revisions.
	$NextSourceHead = Add-FixtureCommit -Write @('Source/AethelnOnline/A.cpp') -Delete @() -Message 'next source for DDC ancestry'
	$null = Invoke-FixtureGit @('-C', $BareRoot, 'fetch', '-q', $RepoRoot, "${NextSourceHead}:refs/heads/fixture-next-source")
	$DdcShallowRoot = Join-Path $FixtureRoot 'ddc-shallow'
	$null = Invoke-FixtureGit @('clone', '-q', '--depth', '1', '--no-tags', '--branch', 'fixture-source', $BareUrl, $DdcShallowRoot)
	$FirstShallowRoots = @(Invoke-FixtureGit @('-C', $DdcShallowRoot, 'rev-list', '--max-parents=0', 'HEAD'))
	Assert-True ($FirstShallowRoots.Count -eq 1 -and $FirstShallowRoots[0] -ceq $SourceHead) 'The first shallow checkout incorrectly identifies its tip as the repository root.'
	$null = Invoke-FixtureGit @('-C', $DdcShallowRoot, 'fetch', '-q', '--depth', '1', 'origin', $NextSourceHead)
	$null = Invoke-FixtureGit @('-C', $DdcShallowRoot, 'checkout', '-q', '--detach', $NextSourceHead)
	$NextShallowRoots = @(Invoke-FixtureGit @('-C', $DdcShallowRoot, 'rev-list', '--max-parents=0', 'HEAD'))
	Assert-True ($NextShallowRoots.Count -eq 1 -and $NextShallowRoots[0] -ceq $NextSourceHead -and $NextShallowRoots[0] -cne $FirstShallowRoots[0]) 'The next depth-1 checkout changes the apparent repository root and invalidates DDC identity.'
	$null = Invoke-FixtureGit @('-C', $DdcShallowRoot, 'fetch', '-q', '--unshallow', 'origin')
	Assert-True (([string] @(Invoke-FixtureGit @('-C', $DdcShallowRoot, 'rev-parse', '--is-shallow-repository'))[0]) -ceq 'false') 'Complete ancestry must remove the shallow boundary.'
	foreach ($Revision in @($SourceHead, $NextSourceHead)) {
		$FullRoots = @(Invoke-FixtureGit @('-C', $DdcShallowRoot, 'rev-list', '--max-parents=0', $Revision))
		Assert-True ($FullRoots.Count -eq 1 -and $FullRoots[0] -ceq $BaseSha) 'Complete ancestry must preserve the actual DDC repository root across consecutive revisions.'
	}
}
finally {
	Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'PASS: workflow exposes no manual entry point, gates trusted compile behind portable success and the change-impact classifier, and retires the monolithic packaged-smoke job'
Write-Output 'PASS: classifier skips compile only for the closed portable set and fails closed on every uncertainty'
Write-Output 'PASS: milestone checkouts fetch complete ancestry; fixture proves shallow DDC root drift and full-ancestry stability across consecutive revisions'
Write-Output 'PASS: workflow preserves LFS, serialization, report-only upload, and no-secret policy'
exit 0
