[CmdletBinding()]
param()

# Offline fixture tests for scripts/delivery/Test-BoardIntegrity.ps1 (Issue
# #214). Every rule is proven red against a single-defect snapshot, and a clean
# snapshot covering every status stays green. No test contacts GitHub.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Checker = Join-Path $RepositoryRoot 'scripts/delivery/Test-BoardIntegrity.ps1'
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnBoardIntegrityTests-' + [guid]::NewGuid().ToString('N'))

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function New-CleanSnapshot {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory fixture.')]
	param()
	$Items = @(
		[ordered]@{ number = 1; state = 'OPEN'; status = 'Backlog'; release = ''; blockedReason = ''; body = "- [ ] not started" },
		[ordered]@{ number = 2; state = 'OPEN'; status = 'Code Review'; release = ''; blockedReason = ''; body = "- [ ] pending" },
		[ordered]@{ number = 3; state = 'OPEN'; status = 'Blocked'; release = ''; blockedReason = 'Waiting on #2'; body = '' },
		[ordered]@{ number = 4; state = 'CLOSED'; status = 'Done'; release = ''; blockedReason = ''; body = "## Acceptance criteria`n- [x] one`n- [X] two" },
		[ordered]@{ number = 5; state = 'CLOSED'; status = 'Release Candidate'; release = 'v1.0.0-alpha.1'; blockedReason = ''; body = '- [x] done' },
		[ordered]@{ number = 6; state = 'CLOSED'; status = 'Released'; release = 'v1.0.0'; blockedReason = ''; body = '- [x] done' },
		[ordered]@{ number = 7; state = 'OPEN'; status = 'In Progress'; release = ''; blockedReason = ''; body = '' }
	)
	$PullRequests = @(
		[ordered]@{ number = 100; title = 'feat(ci): #2 add a check'; isDraft = $false; linkedIssues = @() },
		[ordered]@{ number = 101; title = 'fix(ci): blocked work'; isDraft = $true; linkedIssues = @(3) }
	)
	return [ordered]@{ items = $Items; pullRequests = $PullRequests }
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
		@{ Rule = 'open-pr-issue-status'; Issue = 7; Mutate = { param($S) $S.pullRequests[0].title = 'feat(ci): #7 add a check' } },
		@{ Rule = 'open-pr-issue-status'; Issue = 1; Mutate = { param($S) $S.pullRequests[1].linkedIssues = @(1) } },
		@{ Rule = 'open-pr-issue-status'; Issue = 99; Mutate = { param($S) $S.pullRequests[0].title = 'feat(ci): #99 off-board issue' } },
		@{ Rule = 'closed-issue-status'; Issue = 7; Mutate = { param($S) $S.items[6].state = 'CLOSED' } },
		@{ Rule = 'open-issue-final-status'; Issue = 4; Mutate = { param($S) $S.items[3].state = 'OPEN' } },
		@{ Rule = 'open-issue-final-status'; Issue = 6; Mutate = { param($S) $S.items[5].state = 'OPEN' } },
		@{ Rule = 'release-field-empty'; Issue = 5; Mutate = { param($S) $S.items[4].release = '' } },
		@{ Rule = 'release-field-empty'; Issue = 6; Mutate = { param($S) $S.items[5].release = '  ' } },
		@{ Rule = 'blocked-reason-empty'; Issue = 3; Mutate = { param($S) $S.items[2].blockedReason = '' } }
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
}
finally {
	Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'PASS: board integrity checker reports every rule red, counts all violations, emits -Json, and stays green on a clean board'
exit 0
