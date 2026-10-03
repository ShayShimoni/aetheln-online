[CmdletBinding()]
param(
	[string] $BaseRef = $env:AETHELN_PR_BASE_REF,
	[string] $HeadRef = $env:AETHELN_PR_HEAD_REF,
	[string] $Title = $env:AETHELN_PR_TITLE
)

# Issue #214 hosted pull-request policy. Needs no GitHub or project access:
# the workflow passes the base ref, head ref, and title through environment
# variables. The title is untrusted and is never echoed, so it cannot inject
# workflow commands into the log. Exits 1 on any violation.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($BaseRef) -or [string]::IsNullOrWhiteSpace($HeadRef)) {
	throw 'Pull request policy needs both a base ref and a head ref.'
}

# Gitflow back-merges `main` into `develop`; no other base accepts head `main`.
$BackMerge = $BaseRef -ceq 'develop' -and $HeadRef -ceq 'main'
# A release PR (into main, or merging release fixes back into develop) and the
# back-merge ship several tickets and carry no single issue. A hotfix has its
# own ticket, so its PRs still need one.
$NoSingleIssue = $BackMerge -or $HeadRef -cmatch '^release/'
$Violations = @(
	if ($BaseRef -ceq 'main' -and $HeadRef -cnotmatch '^(release|hotfix)/') {
		"main-head-branch: base 'main' accepts only release/* or hotfix/* heads, not '$HeadRef'."
	}
	if (-not $BackMerge -and $HeadRef -cnotmatch '^(feature|fix|docs|chore|release|hotfix|codex)/') {
		"head-branch-name: head '$HeadRef' must start with feature/, fix/, docs/, chore/, release/, hotfix/, or codex/, or be main into develop."
	}
	if (-not $NoSingleIssue -and $Title -notmatch '#\d+') {
		'title-issue-reference: the title must reference its issue as #<number>.'
	}
)

foreach ($Violation in $Violations) { Write-Output $Violation }
Write-Output "Pull request policy: $($Violations.Count) violation(s)."
if ($Violations.Count -gt 0) { exit 1 }
exit 0
