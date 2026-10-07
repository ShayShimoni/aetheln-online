[CmdletBinding()]
param()

# Offline fixture tests for scripts/delivery/Test-BoardIntegrity.ps1 (Issues
# #214 and #266). Every rule is proven red against a single-defect snapshot,
# and a clean snapshot covering every status stays green. No test contacts
# GitHub.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Checker = Join-Path $RepositoryRoot 'scripts/delivery/Test-BoardIntegrity.ps1'
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnBoardIntegrityTests-' + [guid]::NewGuid().ToString('N'))

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function New-Comment {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory issue comment fixture.')]
	param([string] $At, [string] $Body)
	return [ordered]@{ createdAt = $At; body = $Body }
}

function New-CleanSnapshot {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory fixture.')]
	param()
	# Items without comments have never had a QA round. #9 is in QA with an
	# open round, its comments newest first as an older page arrives, so
	# createdAt, not list order, decides; its later legacy `## Post-merge QA,`
	# heading and lowercase record are not records. #10 is Dev Done and the
	# closed Done #4 is after a recorded round; #10's later legacy `QA round
	# <date>` result line is not a start. #6's start and record share a
	# createdAt second, which counts as closed. #7's comments carry the start
	# marker but not at the start of the first line, after a leading space, or
	# in lowercase.
	$Items = @(
		[ordered]@{ number = 1; state = 'OPEN'; status = 'Backlog'; release = ''; blockedReason = ''; body = "- [ ] not started" },
		[ordered]@{ number = 2; state = 'OPEN'; status = 'Code Review'; release = ''; blockedReason = ''; body = "- [ ] pending" },
		[ordered]@{ number = 3; state = 'OPEN'; status = 'Blocked'; release = ''; blockedReason = 'Waiting on #2'; body = '' },
		[ordered]@{ number = 4; state = 'CLOSED'; status = 'Done'; release = ''; blockedReason = ''; body = "## Acceptance criteria`n- [x] one`n- [X] two"; comments = @(
				(New-Comment '2026-10-01T00:00:00Z' 'QA round started on develop abc1234.'),
				(New-Comment '2026-10-02T00:00:00Z' '## Post-merge QA record, 2026-10-02')) },
		[ordered]@{ number = 5; state = 'CLOSED'; status = 'Release Candidate'; release = 'v1.0.0-alpha.1'; blockedReason = ''; body = '- [x] done' },
		[ordered]@{ number = 6; state = 'CLOSED'; status = 'Released'; release = 'v1.0.0'; blockedReason = ''; body = '- [x] done'; comments = @(
				(New-Comment '2026-10-01T00:00:00Z' 'QA round started on develop abc1234.'),
				(New-Comment '2026-10-01T00:00:00Z' '## Post-merge QA record, 2026-10-01')) },
		[ordered]@{ number = 7; state = 'OPEN'; status = 'In Progress'; release = ''; blockedReason = ''; body = ''; comments = @(
				(New-Comment '2026-10-01T00:00:00Z' 'Lead 2026-10-01: QA round started on develop abc1234.'),
				(New-Comment '2026-10-02T00:00:00Z' "Work notes`r`nQA round started on the second line."),
				(New-Comment '2026-10-03T00:00:00Z' ' QA round started after a leading space.'),
				(New-Comment '2026-10-03T00:00:00Z' 'qa round started in lowercase.')) },
		[ordered]@{ number = 8; state = 'OPEN'; status = 'Code Review'; release = ''; blockedReason = ''; body = "- [ ] pending" },
		[ordered]@{ number = 9; state = 'OPEN'; status = 'QA'; release = ''; blockedReason = ''; body = '- [ ] pending'; comments = @(
				(New-Comment '2026-10-04T00:00:00Z' 'QA round started on develop def5678.'),
				(New-Comment '2026-10-02T00:00:00Z' "## Post-merge QA record, 2026-10-02`r`nResult: one criterion waits for a later round."),
				(New-Comment '2026-10-01T00:00:00Z' 'QA round started on develop abc1234.'),
				(New-Comment '2026-10-05T00:00:00Z' '## Post-merge QA, 2026-10-05 in the older heading.'),
				(New-Comment '2026-10-05T00:00:00Z' '## post-merge qa record in lowercase.')) },
		[ordered]@{ number = 10; state = 'OPEN'; status = 'Dev Done'; release = ''; blockedReason = ''; body = '- [ ] pending'; comments = @(
				(New-Comment '2026-10-01T00:00:00Z' 'QA round started on develop abc1234.'),
				(New-Comment '2026-10-02T00:00:00Z' '## Post-merge QA record, 2026-10-02'),
				(New-Comment '2026-10-03T00:00:00Z' 'QA round 2026-10-03 on develop abc1234: all criteria pass.')) }
	)
	# PR 100 and hotfix PR 102 are ordinary PRs whose issues sit in Code
	# Review. 101 and 103 are release and back-merge PRs whose linked issues
	# sit outside Code Review, so a green clean run proves those PRs are
	# excluded from the Code Review match.
	$PullRequests = @(
		[ordered]@{ number = 100; title = 'feat(ci): #2 add a check'; isDraft = $false; isCrossRepository = $false; headRefName = 'feature/2-add-check'; baseRefName = 'develop'; linkedIssues = @() },
		[ordered]@{ number = 101; title = 'chore(release): #5 v1.0.0'; isDraft = $false; isCrossRepository = $false; headRefName = 'release/v1.0.0'; baseRefName = 'main'; linkedIssues = @() },
		[ordered]@{ number = 102; title = 'fix(net): #8 patch reconnect crash'; isDraft = $false; isCrossRepository = $false; headRefName = 'hotfix/v1.0.1'; baseRefName = 'main'; linkedIssues = @() },
		[ordered]@{ number = 103; title = 'chore(release): back-merge #4 v1.0.0'; isDraft = $false; isCrossRepository = $false; headRefName = 'main'; baseRefName = 'develop'; linkedIssues = @(2) }
	)
	return [ordered]@{ items = $Items; pullRequests = $PullRequests }
}

function New-Pull {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory pull request fixture.')]
	param([int] $Number, [string] $Title, [string] $Head, [int[]] $Linked = @())
	return [ordered]@{ number = $Number; title = $Title; isDraft = $false; isCrossRepository = $false; headRefName = $Head; baseRefName = 'develop'; linkedIssues = $Linked }
}

function Invoke-Checker {
	param($Snapshot, [string] $Name, [switch] $Json)
	$Path = Join-Path $FixtureRoot ($Name + '.json')
	[IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Snapshot -Depth 6))
	$Arguments = @{ FixturePath = $Path }
	if ($Json) { $Arguments.Json = $true }
	$Output = @(& $Checker @Arguments | ForEach-Object { "$_" })
	return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = ($Output -join "`n") }
}

New-Item -ItemType Directory -Path $FixtureRoot -Force | Out-Null
try {
	Assert-True (Test-Path -LiteralPath $Checker -PathType Leaf) 'The board integrity checker must exist at scripts/delivery/Test-BoardIntegrity.ps1.'

	$Clean = Invoke-Checker (New-CleanSnapshot) 'clean'
	Assert-True ($Clean.ExitCode -eq 0) "A clean board must exit 0. Output: $($Clean.Text)"
	Assert-True ($Clean.Text -match 'Board integrity: 0 violation\(s\)') 'A clean board must print a zero summary count.'

	$CleanJson = Invoke-Checker (New-CleanSnapshot) 'clean-json' -Json
	$CleanParsed = $CleanJson.Text | ConvertFrom-Json
	Assert-True ($CleanJson.ExitCode -eq 0 -and $CleanParsed.count -eq 0 -and @($CleanParsed.violations).Count -eq 0) '-Json on a clean board must emit only a zero-count JSON document.'

	# Each case applies one defect to the clean snapshot and expects exactly
	# that rule on that issue.
	$Cases = @(
		@{ Rule = 'done-unchecked-acceptance'; Issue = 4; Mutate = { param($S) $S.items[3].body = "- [x] one`n- [ ] two" } },
		@{ Rule = 'open-pr-issue-status'; Issue = 7; Mutate = { param($S) $S.pullRequests += , (New-Pull -Number 110 -Title 'feat(ci): #7 add a check' -Head 'feature/7-add-check') } },
		@{ Rule = 'open-pr-issue-status'; Issue = 1; Mutate = { param($S) $S.pullRequests += , (New-Pull -Number 110 -Title 'fix(ci): no title reference' -Head 'fix/1-no-ref' -Linked @(1)) } },
		@{ Rule = 'open-pr-issue-status'; Issue = 99; Mutate = { param($S) $S.pullRequests += , (New-Pull -Number 110 -Title 'feat(ci): #99 off-board issue' -Head 'feature/99-off-board') } },
		# A Blocked issue has no open PR of its own; only carried fixes sit in Blocked.
		@{ Rule = 'open-pr-issue-status'; Issue = 3; Mutate = { param($S) $S.pullRequests += , (New-Pull -Number 110 -Title 'fix(ci): #3 blocked work' -Head 'fix/3-blocked-work') } },
		# Without its release head the release PR is ordinary, so its Release Candidate issue is out of place.
		@{ Rule = 'open-pr-issue-status'; Issue = 5; Mutate = { param($S) $S.pullRequests[1].headRefName = 'feature/5-not-a-release' } },
		# A fork names its own branches, so its release or main head earns no exclusion.
		@{ Rule = 'open-pr-issue-status'; Issue = 5; Mutate = { param($S) $S.pullRequests[1].isCrossRepository = $true } },
		@{ Rule = 'duplicate-pr-issue'; Issue = 2; Mutate = { param($S) $S.pullRequests[3].isCrossRepository = $true; $S.pullRequests[3].title = 'chore(release): back-merge v1.0.0' } },
		# A hotfix PR goes through the normal match: its ticket must be in Code Review.
		@{ Rule = 'open-pr-issue-status'; Issue = 8; Mutate = { param($S) $S.items[7].status = 'Dev Done' } },
		@{ Rule = 'code-review-without-pr'; Issue = 8; Mutate = { param($S) $S.pullRequests[2].title = 'fix(net): patch reconnect crash' } },
		@{ Rule = 'duplicate-pr-issue'; Issue = 8; Mutate = { param($S) $S.pullRequests += , (New-Pull -Number 110 -Title 'fix(net): #8 second hotfix' -Head 'hotfix/v1.0.2') } },
		@{ Rule = 'code-review-without-pr'; Issue = 2; Mutate = { param($S) $S.pullRequests[0].title = 'feat(ci): add a check' } },
		# A release head does not count as the Code Review issue's PR.
		@{ Rule = 'code-review-without-pr'; Issue = 2; Mutate = { param($S) $S.pullRequests[0].headRefName = 'release/v1.1.0' } },
		@{ Rule = 'duplicate-pr-issue'; Issue = 2; Mutate = { param($S) $S.pullRequests += , (New-Pull -Number 110 -Title 'fix(ci): #2 second attempt' -Head 'fix/2-second-attempt') } },
		# Head main is a back-merge only into develop.
		@{ Rule = 'duplicate-pr-issue'; Issue = 2; Mutate = { param($S) $S.pullRequests[3].baseRefName = 'main'; $S.pullRequests[3].title = 'chore(release): back-merge v1.0.0' } },
		# A draft is reported by its PR number, on any base, and still links its issue.
		@{ Rule = 'draft-pr-open'; Issue = 100; Mutate = { param($S) $S.pullRequests[0].isDraft = $true } },
		@{ Rule = 'draft-pr-open'; Issue = 101; Mutate = { param($S) $S.pullRequests[1].isDraft = $true } },
		@{ Rule = 'closed-issue-status'; Issue = 7; Mutate = { param($S) $S.items[6].state = 'CLOSED' } },
		@{ Rule = 'open-issue-final-status'; Issue = 4; Mutate = { param($S) $S.items[3].state = 'OPEN' } },
		@{ Rule = 'open-issue-final-status'; Issue = 6; Mutate = { param($S) $S.items[5].state = 'OPEN' } },
		@{ Rule = 'release-field-empty'; Issue = 5; Mutate = { param($S) $S.items[4].release = '' } },
		@{ Rule = 'release-field-empty'; Issue = 6; Mutate = { param($S) $S.items[5].release = '  ' } },
		@{ Rule = 'blocked-reason-empty'; Issue = 3; Mutate = { param($S) $S.items[2].blockedReason = '' } },
		# QA round lifecycle (Issue #266): a QA card never had a round, or its record is newer than its start.
		@{ Rule = 'qa-status-without-round'; Issue = 9; Mutate = { param($S) $S.items[8].comments = @() } },
		@{ Rule = 'qa-status-without-round'; Issue = 9; Mutate = { param($S) $S.items[8].comments = @($S.items[8].comments[1], $S.items[8].comments[2]) } },
		# An open round on a card outside QA, including a Blocked card and a reopened round.
		@{ Rule = 'qa-round-not-in-qa'; Issue = 9; Mutate = { param($S) $S.items[8].status = 'Dev Done' } },
		@{ Rule = 'qa-round-not-in-qa'; Issue = 10; Mutate = { param($S) $S.items[9].comments += , (New-Comment '2026-10-03T00:00:00Z' 'QA round started on develop def5678.') } },
		@{ Rule = 'qa-round-not-in-qa'; Issue = 3; Mutate = { param($S) $S.items[2].comments = @(New-Comment '2026-10-03T00:00:00Z' 'QA round started on develop def5678.') } },
		# Closed and final cards are checked too: a round left unrecorded on a closed Done or Release Candidate card.
		@{ Rule = 'qa-round-not-in-qa'; Issue = 4; Mutate = { param($S) $S.items[3].comments = @($S.items[3].comments[0]) } },
		@{ Rule = 'qa-round-not-in-qa'; Issue = 5; Mutate = { param($S) $S.items[4].comments = @(New-Comment '2026-10-03T00:00:00Z' 'QA round started on develop def5678.') } }
	)
	$Index = 0
	foreach ($Case in $Cases) {
		$Snapshot = New-CleanSnapshot
		& $Case.Mutate $Snapshot
		$Index++
		$Result = Invoke-Checker $Snapshot ('case-' + $Index)
		$Lines = @($Result.Text -split "`n" | Where-Object { $_ -match '^[a-z-]+ #\d+ ' })
		Assert-True ($Result.ExitCode -eq 1) "$($Case.Rule) must exit 1. Output: $($Result.Text)"
		Assert-True ($Lines.Count -eq 1 -and $Lines[0].StartsWith("$($Case.Rule) #$($Case.Issue) ")) "$($Case.Rule) must report exactly '<rule-id> #$($Case.Issue) <detail>'. Output: $($Result.Text)"
		Assert-True ($Result.Text -match 'Board integrity: 1 violation\(s\)') "$($Case.Rule) must print a summary count of 1."

		$JsonResult = Invoke-Checker $Snapshot ('case-' + $Index + '-json') -Json
		$Parsed = $JsonResult.Text | ConvertFrom-Json
		Assert-True ($JsonResult.ExitCode -eq 1 -and $Parsed.count -eq 1 -and @($Parsed.violations).Count -eq 1) "$($Case.Rule) -Json must emit one violation and exit 1."
		Assert-True ($Parsed.violations[0].rule -ceq $Case.Rule -and $Parsed.violations[0].issue -eq $Case.Issue -and -not [string]::IsNullOrWhiteSpace($Parsed.violations[0].detail)) "$($Case.Rule) -Json must carry rule, issue, and detail."
	}

	# Several defects are all reported, not just the first.
	$Multi = New-CleanSnapshot
	$Multi.items[2].blockedReason = ''
	$Multi.items[4].release = ''
	$Multi.items[6].state = 'CLOSED'
	$MultiResult = Invoke-Checker $Multi 'multi'
	Assert-True ($MultiResult.ExitCode -eq 1 -and $MultiResult.Text -match 'Board integrity: 3 violation\(s\)') "Every violation must be counted. Output: $($MultiResult.Text)"

	# Checkbox parsing counts only '- [ ]' and '- [x]' list lines.
	$Prose = New-CleanSnapshot
	$Prose.items[3].body = "Use [ ] in prose`n``- [ ]`` inline is fine`n- [x] real box"
	$ProseResult = Invoke-Checker $Prose 'prose'
	Assert-True ($ProseResult.ExitCode -eq 0) "Non-list bracket text must not count as an unchecked box. Output: $($ProseResult.Text)"

	# A public PR title with an oversized or non-ASCII digit run must not abort the check.
	$Digits = New-CleanSnapshot
	$Digits.pullRequests += , (New-Pull -Number 110 -Title ('feat(ci): #99999999999 and #' + [char] 0x0663) -Head 'feature/digits')
	$DigitsResult = Invoke-Checker $Digits 'digits'
	Assert-True ($DigitsResult.ExitCode -in 0, 1 -and $DigitsResult.Text -match 'Board integrity: \d+ violation\(s\)') "A PR title with an oversized or non-ASCII digit run must not abort the check. Output: $($DigitsResult.Text)"
}
finally {
	Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'PASS: board integrity checker reports every rule red, counts all violations, emits -Json, and stays green on a clean board'
exit 0
