[CmdletBinding()]
param()

# Offline tests for scripts/ci/Test-PullRequestPolicy.ps1 and its hosted
# .github/workflows/delivery-policy.yml workflow (Issue #214).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Checker = Join-Path $RepositoryRoot 'scripts/ci/Test-PullRequestPolicy.ps1'
$WorkflowPath = Join-Path $RepositoryRoot '.github/workflows/delivery-policy.yml'

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Invoke-Policy([string] $BaseRef, [string] $HeadRef, [string] $Title) {
	$Output = @(& $Checker -BaseRef $BaseRef -HeadRef $HeadRef -Title $Title | ForEach-Object { "$_" })
	return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = ($Output -join "`n") }
}

Assert-True (Test-Path -LiteralPath $Checker -PathType Leaf) 'The PR policy checker must exist at scripts/ci/Test-PullRequestPolicy.ps1.'
Assert-True (Test-Path -LiteralPath $WorkflowPath -PathType Leaf) 'The hosted delivery-policy workflow must exist.'

$Accepted = @(
	@('develop', 'feature/214-delivery-rule-enforcement', 'feat(ci): #214 add board integrity check'),
	@('develop', 'fix/179-observability-schema-case', 'fix(observability): #179 reject case variants'),
	@('develop', 'docs/208-board-code-review', 'docs(delivery): #208 tie board moves'),
	@('develop', 'chore/87-templates', 'chore(delivery): #87 add templates'),
	@('develop', 'codex/148-bounded-crash-context', 'feat(observability): #148 register crash context'),
	@('develop', 'release/v1.0.0', 'chore(release): #300 merge release fixes back'),
	@('main', 'release/v1.0.0', 'chore(release): v1.0.0'),
	@('main', 'release/v1.0.0', 'chore(release): #300 v1.0.0'),
	@('main', 'hotfix/v1.0.1', 'fix(net): #301 patch reconnect crash')
)
foreach ($Case in $Accepted) {
	$Result = Invoke-Policy -BaseRef $Case[0] -HeadRef $Case[1] -Title $Case[2]
	Assert-True ($Result.ExitCode -eq 0) "Policy must accept $($Case[1]) -> $($Case[0]). Output: $($Result.Text)"
}

$Rejected = @(
	@{ Base = 'main'; Head = 'feature/214-x'; Title = 'feat(ci): #214 x'; Rule = 'main-head-branch' },
	@{ Base = 'main'; Head = 'chore/1-sync'; Title = 'chore: #1 sync'; Rule = 'main-head-branch' },
	@{ Base = 'develop'; Head = 'feature/214-x'; Title = 'feat(ci): add a check'; Rule = 'title-issue-reference' },
	@{ Base = 'main'; Head = 'hotfix/v1.0.1'; Title = 'fix(net): patch reconnect crash'; Rule = 'title-issue-reference' },
	@{ Base = 'develop'; Head = 'release/v1.0.0'; Title = 'chore(release): v1.0.0 fixes'; Rule = 'title-issue-reference' },
	@{ Base = 'develop'; Head = 'my-branch'; Title = 'feat(ci): #214 x'; Rule = 'head-branch-name' },
	@{ Base = 'develop'; Head = 'Feature/214-x'; Title = 'feat(ci): #214 x'; Rule = 'head-branch-name' },
	@{ Base = 'develop'; Head = 'feat/214-x'; Title = 'feat(ci): #214 x'; Rule = 'head-branch-name' }
)
foreach ($Case in $Rejected) {
	$Result = Invoke-Policy -BaseRef $Case.Base -HeadRef $Case.Head -Title $Case.Title
	$Lines = @($Result.Text -split "`n" | Where-Object { $_ -match '^[a-z-]+: ' })
	Assert-True ($Result.ExitCode -eq 1) "Policy must reject $($Case.Head) -> $($Case.Base) ('$($Case.Title)'). Output: $($Result.Text)"
	Assert-True ($Lines.Count -eq 1 -and $Lines[0].StartsWith($Case.Rule + ': ')) "Policy must report exactly rule '$($Case.Rule)'. Output: $($Result.Text)"
}

# Every violated rule is reported together.
$Multi = Invoke-Policy -BaseRef main -HeadRef wip -Title 'no issue'
Assert-True ($Multi.ExitCode -eq 1 -and $Multi.Text -match 'main-head-branch: ' -and $Multi.Text -match 'head-branch-name: ' -and $Multi.Text -match 'title-issue-reference: ' -and $Multi.Text -match '3 violation\(s\)') "All violated rules must be reported. Output: $($Multi.Text)"

# The untrusted title is never echoed, so it cannot inject workflow commands.
$Injected = Invoke-Policy -BaseRef develop -HeadRef feature/1-x -Title '::error::injected title'
Assert-True ($Injected.ExitCode -eq 1 -and $Injected.Text -notmatch 'injected') 'The checker must not echo the PR title.'

# Missing inputs fail closed instead of passing silently.
foreach ($Missing in @(@('', 'feature/1-x', '#1 t'), @('develop', '', '#1 t'))) {
	$Failed = $false
	try { $null = Invoke-Policy -BaseRef $Missing[0] -HeadRef $Missing[1] -Title $Missing[2]; $Failed = $LASTEXITCODE -ne 0 } catch { $Failed = $true }
	Assert-True $Failed 'An empty base or head ref must fail.'
}

# The workflow passes PR data through environment variables read as defaults.
$SavedEnvironment = @($env:AETHELN_PR_BASE_REF, $env:AETHELN_PR_HEAD_REF, $env:AETHELN_PR_TITLE)
try {
	$env:AETHELN_PR_BASE_REF = 'main'; $env:AETHELN_PR_HEAD_REF = 'feature/1-x'; $env:AETHELN_PR_TITLE = 'feat: #1 x'
	$EnvironmentOutput = @(& $Checker | ForEach-Object { "$_" }) -join "`n"
	Assert-True ($LASTEXITCODE -eq 1 -and $EnvironmentOutput -match 'main-head-branch: ') 'Environment-variable inputs must be the parameter defaults.'
}
finally {
	$env:AETHELN_PR_BASE_REF = $SavedEnvironment[0]; $env:AETHELN_PR_HEAD_REF = $SavedEnvironment[1]; $env:AETHELN_PR_TITLE = $SavedEnvironment[2]
}

# Workflow contract: hosted, read-only, bounded, re-run on title edits, and no
# untrusted expression inside a run block.
$Workflow = Get-Content -LiteralPath $WorkflowPath -Raw
Assert-True ($Workflow -match "(?m)^on:\r?\n  pull_request:\r?\n    types: \[opened, edited, synchronize, reopened\]\r?\n    branches:\r?\n      - develop\r?\n      - main\r?\n") 'The workflow must run on pull_request to develop and main, including title edits.'
Assert-True ($Workflow -match "(?m)^permissions:\r?\n  contents: read\r?$" -and $Workflow -notmatch '(?m):\s*write\s*$') 'The workflow must be read-only.'
Assert-True ($Workflow -notmatch 'pull_request_target|workflow_dispatch|self-hosted|aetheln-engine') 'The workflow must be hosted and pull_request only.'
Assert-True ($Workflow -match '(?m)^    name: pull-request-policy\r?$' -and $Workflow -match '(?m)^    runs-on: windows-latest\r?$' -and $Workflow -match '(?m)^    timeout-minutes: 5\r?$') 'The policy job must be named, hosted, and bounded.'
Assert-True ($Workflow -match '(?m)^      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\r?$' -and $Workflow -match '(?m)^          persist-credentials: false\r?$') 'Checkout must use the reviewed pinned action without persisted credentials.'
Assert-True ($Workflow -match '(?m)^          AETHELN_PR_TITLE: \$\{\{ github\.event\.pull_request\.title \}\}\r?$' -and $Workflow -match '(?m)^          AETHELN_PR_BASE_REF: \$\{\{ github\.base_ref \}\}\r?$' -and $Workflow -match '(?m)^          AETHELN_PR_HEAD_REF: \$\{\{ github\.head_ref \}\}\r?$') 'PR inputs must be bound through env.'
$RunLines = @([regex]::Matches($Workflow, '(?m)^\s+run: (.+)$') | ForEach-Object { $_.Groups[1].Value })
Assert-True ($RunLines.Count -eq 1 -and $RunLines[0] -notmatch '\$\{\{' -and $RunLines[0] -match 'scripts/ci/Test-PullRequestPolicy\.ps1') 'The single run step must call the checker with no expression interpolation.'

Write-Output 'PASS: pull request policy enforces main heads, branch naming, and issue-referencing titles through a hosted read-only workflow'
exit 0
