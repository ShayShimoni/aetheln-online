[CmdletBinding()]
param()

# Offline fixture tests for scripts/delivery/Invoke-ReleaseCut.ps1 (Issue #225).
# Every failure code is proven red against a single-defect snapshot, and a clean
# snapshot stays green. Verify reads a normalized snapshot from -FixturePath;
# VerifyPackage reads fixture logs and provenance files. No test contacts GitHub
# or a git remote.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Cutter = Join-Path $RepositoryRoot 'scripts/delivery/Invoke-ReleaseCut.ps1'
. (Join-Path $RepositoryRoot 'scripts/build/ProjectVersion.ps1')
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('AethelnReleaseCutTests-' + [guid]::NewGuid().ToString('N'))
$Failures = New-Object Collections.Generic.List[string]
$CutRevision = '0123456789abcdef0123456789abcdef01234567'
$OtherRevision = 'fedcba9876543210fedcba9876543210fedcba98'

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Test-Case([string] $Name, [scriptblock] $Body) {
	try { & $Body } catch { $Failures.Add("$Name :: $($_.Exception.Message)") }
}

function New-CleanSnapshot {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory fixture.')]
	param()
	# `board` is handed to Test-BoardIntegrity.ps1 unchanged; `items` is the
	# release scope view of the same board, including PR cards.
	$BoardItems = @(
		[ordered]@{ number = 4; state = 'CLOSED'; status = 'Done'; release = ''; blockedReason = ''; body = '- [x] one' },
		[ordered]@{ number = 9; state = 'CLOSED'; status = 'Done'; release = ''; blockedReason = ''; body = '- [x] two' },
		[ordered]@{ number = 2; state = 'OPEN'; status = 'Code Review'; release = ''; blockedReason = ''; body = '- [ ] pending' },
		[ordered]@{ number = 5; state = 'CLOSED'; status = 'Release Candidate'; release = 'v0.1.0'; blockedReason = ''; body = '- [x] done' },
		[ordered]@{ number = 7; state = 'OPEN'; status = 'In Progress'; release = ''; blockedReason = ''; body = '' }
	)
	$BoardPulls = @(
		[ordered]@{ number = 100; title = 'feat(ci): #2 add a check'; isDraft = $false; isCrossRepository = $false; headRefName = 'feature/2-add-check'; baseRefName = 'develop'; linkedIssues = @() }
	)
	$Items = @($BoardItems | ForEach-Object { [ordered]@{ number = $_.number; type = 'Issue'; status = $_.status; release = $_.release } })
	return [ordered]@{
		tags = @('v0.1.0')
		remoteBranches = @('release/v0.1.0')
		developRevision = $CutRevision
		developRun = [ordered]@{ status = 'completed'; conclusion = 'success' }
		defaultGameIni = "[/Script/EngineSettings.GeneralProjectSettings]`nProjectID=00000000-0000-0000-0000-000000000000`nProjectName=AethelnOnline`nProjectVersion=1.0.0-alpha.1`n"
		otherConfigIni = @()
		items = $Items
		openPullRequests = @([ordered]@{ number = 100; title = 'feat(ci): #2 add a check'; linkedIssues = @() })
		# PR 52 links a Release Candidate issue and PR 53 merged into a feature
		# branch, so neither is part of the scope even though neither is in the cut.
		mergedPullRequests = @(
			[ordered]@{ number = 50; title = 'feat(ci): #4 add a check'; baseRefName = 'develop'; mergeCommit = $CutRevision; linkedIssues = @(); inCut = $true },
			[ordered]@{ number = 51; title = 'fix(net): #9 repair'; baseRefName = 'develop'; mergeCommit = $CutRevision; linkedIssues = @(); inCut = $true },
			[ordered]@{ number = 52; title = 'chore(release): #5 earlier'; baseRefName = 'develop'; mergeCommit = $OtherRevision; linkedIssues = @(); inCut = $false },
			[ordered]@{ number = 53; title = 'feat(ci): #4 stacked'; baseRefName = 'feature/4-base'; mergeCommit = $OtherRevision; linkedIssues = @(); inCut = $false }
		)
		board = [ordered]@{ items = $BoardItems; pullRequests = $BoardPulls }
	}
}

function Invoke-Cut {
	param([hashtable] $Arguments)
	$Output = @(& $Cutter @Arguments | ForEach-Object { "$_" })
	return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = ($Output -join "`n"); Lines = @($Output | Where-Object { $_ -cmatch '^release_[a-z_]+ ' }) }
}

# A child process reports what `-File` reports: the real exit code and the stderr
# an in-process call does not capture.
function Invoke-CutProcess {
	param([string[]] $ArgumentList, [string] $Script = $Cutter)
	$Previous = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		$Output = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $Script @ArgumentList 2>&1 | ForEach-Object { "$_" })
		$ExitCode = $LASTEXITCODE
	}
	finally {
		$ErrorActionPreference = $Previous
	}
	return [pscustomobject]@{ ExitCode = $ExitCode; Text = ($Output -join "`n"); Lines = @($Output | Where-Object { $_ -cmatch '^release_[a-z_]+ ' }) }
}

function Assert-ExitTwo {
	param($Result, [string] $Reason, [string] $Name)
	Assert-True ($Result.ExitCode -eq 2 -and $Result.Lines.Count -eq 0) "$Name must exit 2 without a violation line. Exit: $($Result.ExitCode). Output: $($Result.Text)"
	Assert-True ($Result.Text -match "Release cut error \[$Reason\]: ") "$Name must print the fixed reason [$Reason]. Output: $($Result.Text)"
	Assert-True ($Result.Text -notmatch '(?<![A-Za-z0-9])[A-Za-z]:[\\/]') "$Name must print no drive-letter path in stdout or stderr. Output: $($Result.Text)"
}

function Invoke-Verify {
	param($Snapshot, [string] $Name, [hashtable] $Parameters = @{}, [switch] $Json)
	$Path = Join-Path $FixtureRoot ($Name + '.json')
	# The landed ProjectVersion follows a valid planned -Version, so a case that
	# varies the version stays a one-violation case; invalid versions keep the default.
	$Planned = if ($Parameters.ContainsKey('Version')) { [string] $Parameters.Version } else { '' }
	if ($Planned -cmatch ('^' + (Get-ProjectVersionPattern) + '\z') -and $Snapshot.defaultGameIni -is [string]) {
		$Snapshot.defaultGameIni = $Snapshot.defaultGameIni.Replace('ProjectVersion=1.0.0-alpha.1', "ProjectVersion=$Planned")
	}
	[IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Snapshot -Depth 8))
	$Arguments = @{ Stage = 'Verify'; Version = '1.0.0-alpha.1'; FixturePath = $Path }
	foreach ($Key in $Parameters.Keys) { $Arguments[$Key] = $Parameters[$Key] }
	if ($Json) { $Arguments.Json = $true }
	return Invoke-Cut $Arguments
}

function Assert-Single {
	param($Result, [string] $Code, [string] $Subject, [string] $Name)
	Assert-True ($Result.ExitCode -eq 1) "$Name must exit 1. Output: $($Result.Text)"
	Assert-True ($Result.Lines.Count -eq 1 -and $Result.Lines[0].StartsWith("$Code $Subject ")) "$Name must report exactly '$Code $Subject <detail>'. Output: $($Result.Text)"
	Assert-True ($Result.Text -match 'Release cut Verify: 1 violation\(s\)\.') "$Name must print a summary count of 1."
}

function Assert-Green {
	param($Result, [string] $Name)
	Assert-True ($Result.ExitCode -eq 0 -and $Result.Text -match 'violation\(s\)\.' -and $Result.Lines.Count -eq 0) "$Name must be green. Output: $($Result.Text)"
}

New-Item -ItemType Directory -Path $FixtureRoot -Force | Out-Null
try {
	Assert-True (Test-Path -LiteralPath $Cutter -PathType Leaf) 'The release-cut script must exist at scripts/delivery/Invoke-ReleaseCut.ps1.'

	# A clean snapshot is green, in text and -Json, and records every consumer.
	Test-Case 'clean text' {
		$Clean = Invoke-Verify (New-CleanSnapshot) 'clean'
		Assert-True ($Clean.ExitCode -eq 0 -and $Clean.Text -match 'Release cut Verify: 0 violation\(s\)\.' -and $Clean.Lines.Count -eq 0) "A clean snapshot must exit 0 with a zero summary. Output: $($Clean.Text)"
	}
	Test-Case 'clean json and consumers' {
		$CleanJson = Invoke-Verify (New-CleanSnapshot) 'clean-json' -Json
		$Parsed = $CleanJson.Text | ConvertFrom-Json
		Assert-True ($CleanJson.ExitCode -eq 0 -and $Parsed.stage -ceq 'Verify' -and $Parsed.count -eq 0 -and @($Parsed.violations).Count -eq 0) '-Json on a clean snapshot must emit a zero-count Verify document.'
		$Consumers = @{}
		foreach ($Consumer in @($Parsed.consumers)) { $Consumers[$Consumer.name] = $Consumer }
		Assert-True ($Consumers.Count -eq 4) 'The consumer record must list exactly four consumers.'
		Assert-True ($Consumers['network-version'].status -ceq 'accepted' -and $Consumers['network-version'].form -ceq '1.0.0-alpha.1+65535') 'The network version consumer must accept the stamped form built with the worst-case build number.'
		Assert-True ($Consumers['build-identity'].status -ceq 'accepted') 'The build identity consumer must accept the stamped form.'
		Assert-True ($Consumers['windows-file-version'].status -ceq 'unverified' -and $Consumers['windows-file-version'].form -ceq '1.0.0.65535') 'The Windows file version numeric form must pass its grammar but stay unverified until a packaged executable is checked.'
		Assert-True ($Consumers['appx-manifest'].status -ceq 'not-applicable' -and $Consumers['appx-manifest'].evidence -match 'AppXManifestGeneratorBase\.cs') 'The AppX manifest consumer must be not-applicable and cite its engine evidence.'
		foreach ($Consumer in $Consumers.Values) { Assert-True (-not [string]::IsNullOrWhiteSpace($Consumer.evidence)) "Consumer $($Consumer.name) must carry evidence." }
	}

	# Each case applies one defect to the clean snapshot (or its parameters) and
	# expects exactly that code on that subject.
	$Long = '1.0.0-' + ('a' * 85)
	$Cases = @(
		@{ Code = 'release_version_invalid'; Subject = 'version'; Mutate = { $Parameters.Version = '1.0.0-alpha.1+412' } },
		@{ Code = 'release_version_invalid'; Subject = 'version'; Mutate = { $Parameters.Version = 'v1.0.0' } },
		@{ Code = 'release_version_invalid'; Subject = 'version'; Mutate = { $Parameters.Version = '1.0' } },
		@{ Code = 'release_version_invalid'; Subject = 'version'; Mutate = { $Parameters.Version = '01.0.0-alpha.1' } },
		@{ Code = 'release_version_invalid'; Subject = 'version'; Mutate = { $Parameters.Version = '1.0.0-alpha..1' } },
		@{ Code = 'release_version_not_newer'; Subject = 'version'; Mutate = { $Snapshot.tags += 'v1.0.0-alpha.2' } },
		@{ Code = 'release_version_not_newer'; Subject = 'version'; Mutate = { $Snapshot.tags += 'v1.0.0' } },
		@{ Code = 'release_version_not_newer'; Subject = 'version'; Mutate = { $Parameters.Version = '1.0.0-alpha'; $Snapshot.tags += 'v1.0.0-alpha.1' } },
		@{ Code = 'release_version_not_newer'; Subject = 'version'; Mutate = { $Parameters.Version = '0.0.9' } },
		@{ Code = 'release_branch_exists'; Subject = 'branch'; Mutate = { $Snapshot.remoteBranches += 'release/v1.0.0-alpha.1' } },
		@{ Code = 'release_branch_exists'; Subject = 'branch'; Mutate = { $Parameters.BranchName = 'release/v0.1.0' } },
		@{ Code = 'release_tag_exists'; Subject = 'tag'; Mutate = { $Snapshot.tags += 'v1.0.0-alpha.1' } },
		@{ Code = 'release_develop_not_green'; Subject = 'develop'; Mutate = { $Snapshot.developRun = $null } },
		@{ Code = 'release_develop_not_green'; Subject = 'develop'; Mutate = { $Snapshot.developRun.status = 'in_progress'; $Snapshot.developRun.conclusion = '' } },
		@{ Code = 'release_develop_not_green'; Subject = 'develop'; Mutate = { $Snapshot.developRun.conclusion = 'failure' } },
		@{ Code = 'release_develop_not_green'; Subject = 'develop'; Mutate = { $Snapshot.developRun.conclusion = 'skipped' } },
		@{ Code = 'release_board_integrity_failed'; Subject = '#4'; Mutate = { $Snapshot.board.items[0].body = '- [ ] unchecked' } },
		@{ Code = 'release_board_integrity_failed'; Subject = '#7'; Mutate = { $Snapshot.board.items[4].state = 'CLOSED' } },
		@{ Code = 'release_scope_empty'; Subject = 'scope'; Mutate = { $Snapshot.items = @($Snapshot.items | Where-Object { $_.status -cne 'Done' }) } },
		@{ Code = 'release_item_release_field_set'; Subject = '#4'; Mutate = { $Snapshot.items[0].release = 'v0.1.0' } },
		@{ Code = 'release_item_not_issue'; Subject = '#72'; Mutate = { $Snapshot.items += , [ordered]@{ number = 72; type = 'PullRequest'; status = 'Done'; release = '' } } },
		@{ Code = 'release_item_open_pr'; Subject = '#4'; Mutate = { $Snapshot.openPullRequests += , [ordered]@{ number = 101; title = 'fix(ci): #4 late fix'; linkedIssues = @() } } },
		@{ Code = 'release_item_open_pr'; Subject = '#9'; Mutate = { $Snapshot.openPullRequests += , [ordered]@{ number = 101; title = 'fix(ci): late fix'; linkedIssues = @(9) } } },
		@{ Code = 'release_item_work_not_in_cut'; Subject = '#4'; Mutate = { $Snapshot.mergedPullRequests[0].inCut = $false } },
		@{ Code = 'release_item_work_not_in_cut'; Subject = '#9'; Mutate = { $Snapshot.mergedPullRequests[1].inCut = $false; $Snapshot.mergedPullRequests[1].baseRefName = 'main' } },
		@{ Code = 'release_project_version_conflict'; Subject = 'Config/DefaultGame.ini'; Mutate = { $Snapshot.defaultGameIni = $Snapshot.defaultGameIni.Replace('ProjectVersion=1.0.0-alpha.1', 'ProjectVersion=0.9.0') } },
		@{ Code = 'release_project_version_conflict'; Subject = 'Config/DefaultGame.ini'; Mutate = { $Snapshot.defaultGameIni += "  projectversion = 1.0.0`n" } },
		# TA-022 lands the version before the cut, so a missing one is a violation.
		@{ Code = 'release_project_version_conflict'; Subject = 'Config/DefaultGame.ini'; Mutate = { $Snapshot.defaultGameIni = "[/Script/EngineSettings.GeneralProjectSettings]`nProjectName=AethelnOnline`n" } },
		# Issue #226: the shared ProjectVersion reader. Each defect below hides
		# another version or sits where the engine would read it differently.
		@{ Code = 'release_project_version_conflict'; Subject = 'Config/DefaultGame.ini'; Mutate = { $Snapshot.defaultGameIni += "ProjectVersion=1.0.0-alpha.1`nProjectVersion=0.9.0`n" } },
		@{ Code = 'release_project_version_conflict'; Subject = 'Config/DefaultGame.ini'; Mutate = { $Snapshot.defaultGameIni += "ProjectVersion=1.0.0-alpha.1`nPROJECTVERSION=1.0.0-alpha.1`n" } },
		@{ Code = 'release_project_version_conflict'; Subject = 'Config/DefaultGame.ini'; Mutate = { $Snapshot.defaultGameIni += "[/Script/Engine.Other]`nProjectVersion=1.0.0-alpha.1`n" } },
		@{ Code = 'release_project_version_conflict'; Subject = 'Config/DefaultGame.ini'; Mutate = { $Snapshot.defaultGameIni += "ProjectVersion=1.0.0-alpha.1`n~ProjectVersion=0.9.0`n" } },
		@{ Code = 'release_project_version_conflict'; Subject = 'Config/DefaultGame.ini'; Mutate = { $Snapshot.defaultGameIni += "ProjectVersion=1.0.0-alpha.1`n~+ProjectVersion=0.9.0`n" } },
		@{ Code = 'release_project_version_conflict'; Subject = 'Config/DefaultGame.ini'; Mutate = { $Snapshot.defaultGameIni += "Unrelated=1`rProjectVersion=0.9.0`n" } },
		# Refused, not parsed: a header that trailing whitespace still closes, a
		# joined line, a // header, and braces.
		@{ Code = 'release_project_version_conflict'; Subject = 'Config/DefaultGame.ini'; Mutate = { $Snapshot.defaultGameIni += "[/Script/Engine.Other] `nProjectVersion=1.0.0-alpha.1`n" } },
		@{ Code = 'release_project_version_conflict'; Subject = 'Config/DefaultGame.ini'; Mutate = { $Snapshot.defaultGameIni += "ProjectVersion=1.0.0-alpha.1`nUnrelated=1\`n" } },
		@{ Code = 'release_project_version_conflict'; Subject = 'Config/DefaultGame.ini'; Mutate = { $Snapshot.defaultGameIni += "//[/Script/Engine.Other]`nProjectVersion=1.0.0-alpha.1`n" } },
		@{ Code = 'release_project_version_conflict'; Subject = 'Config/DefaultGame.ini'; Mutate = { $Snapshot.defaultGameIni += "ProjectVersion=1.0.0-alpha.1`nUnrelated={1}`n" } },
		# Another tracked Config ini overrides the version, with or without a default declaration.
		@{ Code = 'release_project_version_conflict'; Subject = 'Config'; Mutate = { $Snapshot.defaultGameIni += "ProjectVersion=1.0.0-alpha.1`n"; $Snapshot.otherConfigIni = @("[/Script/EngineSettings.GeneralProjectSettings]`nProjectVersion=0.9.0`n") } },
		@{ Code = 'release_project_version_conflict'; Subject = 'Config'; Mutate = { $Snapshot.otherConfigIni = @("[/Script/EngineSettings.GeneralProjectSettings]`nProjectVersion=1.0.0-alpha.1`n") } },
		@{ Code = 'release_project_version_conflict'; Subject = 'Config'; Mutate = { $Snapshot.otherConfigIni = @("[/Script/Engine.Engine]`nUnrelated=1`n", "[/Script/EngineSettings.GeneralProjectSettings]`nProject{Version}=0.9.0`n") } },
		@{ Code = 'release_version_consumer_rejects'; Subject = 'windows-file-version'; Mutate = { $Parameters.BuildNumber = '70000' } },
		@{ Code = 'release_version_consumer_rejects'; Subject = 'windows-file-version'; Mutate = { $Parameters.BuildNumber = 'abc' } },
		# The numeric form must have exactly four parts, so the build number is digits only.
		@{ Code = 'release_version_consumer_rejects'; Subject = 'windows-file-version'; Mutate = { $Parameters.BuildNumber = '4.1' } },
		@{ Code = 'release_version_consumer_rejects'; Subject = 'windows-file-version'; Mutate = { $Parameters.BuildNumber = '1.2.3' } },
		@{ Code = 'release_version_consumer_rejects'; Subject = 'windows-file-version'; Mutate = { $Parameters.BuildNumber = '0412' } },
		@{ Code = 'release_version_consumer_rejects'; Subject = 'windows-file-version'; Mutate = { $Parameters.BuildNumber = '12345678901' } },
		@{ Code = 'release_version_consumer_rejects'; Subject = 'windows-file-version'; Mutate = { $Parameters.Version = '70000.0.0' } },
		@{ Code = 'release_version_consumer_rejects'; Subject = 'build-identity'; Mutate = { $Parameters.Version = $Long } }
	)
	# Every engine array-operator prefix also hides a second version.
	foreach ($Operator in '-', '+', '.', '!', '@', '*', '^') {
		$Cases += @{ Code = 'release_project_version_conflict'; Subject = 'Config/DefaultGame.ini'; Mutate = [scriptblock]::Create("`$Snapshot.defaultGameIni += ""ProjectVersion=1.0.0-alpha.1``n$($Operator)ProjectVersion=0.9.0``n""") }
	}
	$Index = 0
	foreach ($Case in $Cases) {
		$Index++
		$Name = "$($Case.Code) case $Index"
		Test-Case $Name {
			$Snapshot = New-CleanSnapshot
			$Parameters = @{}
			& $Case.Mutate
			$Result = Invoke-Verify -Snapshot $Snapshot -Name ('case-' + $Index) -Parameters $Parameters
			Assert-Single -Result $Result -Code $Case.Code -Subject $Case.Subject -Name $Name
			$JsonResult = Invoke-Verify -Snapshot $Snapshot -Name ('case-' + $Index + '-json') -Parameters $Parameters -Json
			$Parsed = $JsonResult.Text | ConvertFrom-Json
			Assert-True ($JsonResult.ExitCode -eq 1 -and $Parsed.count -eq 1 -and @($Parsed.violations).Count -eq 1) "$Name -Json must emit one violation and exit 1."
			Assert-True ($Parsed.violations[0].code -ceq $Case.Code -and $Parsed.violations[0].subject -ceq $Case.Subject -and -not [string]::IsNullOrWhiteSpace($Parsed.violations[0].detail)) "$Name -Json must carry code, subject, and detail."
		}
	}

	# Test-BoardIntegrity.ps1 owns the board rules; its rule id and detail are carried through.
	Test-Case 'board integrity reuse' {
		$Snapshot = New-CleanSnapshot
		$Snapshot.board.items[0].body = '- [ ] unchecked'
		$Result = Invoke-Verify $Snapshot 'board-reuse'
		Assert-True ($Result.Lines.Count -eq 1 -and $Result.Lines[0] -match '^release_board_integrity_failed #4 done-unchecked-acceptance: ') "The integrity violation must name its Test-BoardIntegrity rule. Output: $($Result.Text)"
	}

	# A control character in the build number fails the build identity and the numeric form.
	Test-Case 'control character build number' {
		$Result = Invoke-Verify -Snapshot (New-CleanSnapshot) -Name 'control' -Parameters @{ BuildNumber = "41`t2" }
		Assert-True ($Result.ExitCode -eq 1 -and @($Result.Lines | Where-Object { $_.StartsWith('release_version_consumer_rejects build-identity ') }).Count -eq 1) "A control character must fail the build identity. Output: $($Result.Text)"
		Assert-True ($Result.Text -notmatch "`t") 'Details must not echo raw control characters.'
		$Unicode = Invoke-Verify -Snapshot (New-CleanSnapshot) -Name 'line-separator' -Parameters @{ BuildNumber = "41$([char] 0x2028)2" }
		Assert-True (@($Unicode.Lines | Where-Object { $_.StartsWith('release_version_consumer_rejects build-identity ') }).Count -eq 1) 'U+2028 must fail the build identity.'
	}

	# Accepted forms: the limits themselves, and SemVer precedence in both directions.
	$GreenCases = @(
		@{ Name = 'build number at the 16-bit limit'; Mutate = { $Parameters.BuildNumber = '65535' } },
		@{ Name = 'explicit build number'; Mutate = { $Parameters.BuildNumber = '412' } },
		@{ Name = 'stamped identity at 96 characters'; Mutate = { $Parameters.Version = '1.0.0-' + ('a' * 84) } },
		@{ Name = 'later pre-release over earlier'; Mutate = { $Parameters.Version = '1.0.0-alpha.2'; $Snapshot.tags = @('v1.0.0-alpha.1') } },
		@{ Name = 'numeric identifiers compare as numbers'; Mutate = { $Parameters.Version = '1.0.0-alpha.10'; $Snapshot.tags = @('v1.0.0-alpha.9') } },
		@{ Name = 'alphanumeric identifier over numeric'; Mutate = { $Parameters.Version = '1.0.0-alpha.beta'; $Snapshot.tags = @('v1.0.0-alpha.1') } },
		@{ Name = 'longer identifier list over its prefix'; Mutate = { $Parameters.Version = '1.0.0-alpha.1'; $Snapshot.tags = @('v1.0.0-alpha') } },
		@{ Name = 'release over its pre-releases'; Mutate = { $Parameters.Version = '1.0.0'; $Snapshot.tags = @('v1.0.0-alpha.1', 'v1.0.0-alpha.2', 'v1.0.0-rc.1') } },
		@{ Name = 'non-SemVer tags are ignored'; Mutate = { $Snapshot.tags += @('vfoo', 'v2', 'nightly', 'v9.0.0+5') } },
		@{ Name = 'no tags at all'; Mutate = { $Snapshot.tags = @() } },
		@{ Name = 'commented ProjectVersion line'; Mutate = { $Snapshot.defaultGameIni += ";ProjectVersion=0.9.0`n" } },
		@{ Name = 'matching ProjectVersion with LF'; Mutate = { $Snapshot.defaultGameIni = "[/Script/EngineSettings.GeneralProjectSettings]`nProjectName=AethelnOnline`nProjectVersion=1.0.0-alpha.1`n" } },
		@{ Name = 'matching ProjectVersion with CRLF'; Mutate = { $Snapshot.defaultGameIni = "[/Script/EngineSettings.GeneralProjectSettings]`r`nProjectName=AethelnOnline`r`nProjectVersion=1.0.0-alpha.1`r`n" } },
		@{ Name = 'matching ProjectVersion with lone CR'; Mutate = { $Snapshot.defaultGameIni = "[/Script/EngineSettings.GeneralProjectSettings]`rProjectName=AethelnOnline`rProjectVersion=1.0.0-alpha.1`r" } },
		@{ Name = 'other Config ini without a version'; Mutate = { $Snapshot.otherConfigIni = @("[/Script/Engine.Engine]`nUnrelated=1`n") } }
	)
	$Index = 0
	foreach ($Case in $GreenCases) {
		$Index++
		$Name = "green: $($Case.Name)"
		Test-Case $Name {
			$Snapshot = New-CleanSnapshot
			$Parameters = @{}
			& $Case.Mutate
			Assert-Green -Result (Invoke-Verify -Snapshot $Snapshot -Name ('green-' + $Index) -Parameters $Parameters) -Name $Name
		}
	}

	# Several defects are all reported, not just the first.
	Test-Case 'multiple defects' {
		$Multi = New-CleanSnapshot
		$Multi.tags += 'v1.0.0-alpha.1'
		$Multi.remoteBranches += 'release/v1.0.0-alpha.1'
		$Multi.developRun = $null
		$Multi.items[0].release = 'v0.1.0'
		$MultiResult = Invoke-Verify $Multi 'multi'
		Assert-True ($MultiResult.ExitCode -eq 1 -and $MultiResult.Text -match 'Release cut Verify: 4 violation\(s\)\.') "Every violation must be counted. Output: $($MultiResult.Text)"
	}

	# An environment error is exit 2, not a violation, and prints a fixed reason with no local path.
	Test-Case 'environment error' {
		$Missing = Invoke-CutProcess @('-Stage', 'Verify', '-Version', '1.0.0-alpha.1', '-FixturePath', (Join-Path $FixtureRoot 'does-not-exist.json'))
		Assert-ExitTwo -Result $Missing -Reason 'environment' -Name 'A missing fixture'
		$Garbled = Join-Path $FixtureRoot 'garbled.json'
		[IO.File]::WriteAllText($Garbled, '{ not json')
		Assert-ExitTwo -Result (Invoke-CutProcess @('-Stage', 'Verify', '-Version', '1.0.0-alpha.1', '-FixturePath', $Garbled)) -Reason 'environment' -Name 'An unparsable fixture'
	}

	# A failing git call must not echo `-C <repository root>`. The script is copied
	# into a folder that is not a repository, so `ls-remote` fails without a network.
	Test-Case 'environment error from git' {
		$Copy = Join-Path $FixtureRoot 'not-a-repository/scripts/delivery'
		New-Item -ItemType Directory -Path $Copy -Force | Out-Null
		Copy-Item -LiteralPath $Cutter -Destination $Copy
		$BuildCopy = Join-Path $FixtureRoot 'not-a-repository/scripts/build'
		New-Item -ItemType Directory -Path $BuildCopy -Force | Out-Null
		Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'scripts/build/ProjectVersion.ps1') -Destination $BuildCopy
		$PreviousCeiling = $env:GIT_CEILING_DIRECTORIES
		$env:GIT_CEILING_DIRECTORIES = $FixtureRoot
		try { $Failed = Invoke-CutProcess @('-Stage', 'Verify', '-Version', '1.0.0-alpha.1') -Script (Join-Path $Copy 'Invoke-ReleaseCut.ps1') }
		finally { $env:GIT_CEILING_DIRECTORIES = $PreviousCeiling }
		Assert-ExitTwo -Result $Failed -Reason 'environment' -Name 'A failing git call'
	}

	# A valid planned -Version that differs from the landed one is refused by the
	# comparison itself, not by the shared reader: the landed text is replaced, so it
	# stays one canonical declaration.
	Test-Case 'landed version differs from planned' {
		$Snapshot = New-CleanSnapshot
		$Snapshot.defaultGameIni = $Snapshot.defaultGameIni.Replace('ProjectVersion=1.0.0-alpha.1', 'ProjectVersion=0.9.0')
		$Result = Invoke-Verify -Snapshot $Snapshot -Name 'landed-differs'
		Assert-Single -Result $Result -Code 'release_project_version_conflict' -Subject 'Config/DefaultGame.ini' -Name 'A landed version other than the planned one'
		Assert-True ($Result.Lines[0] -match 'already holds ProjectVersion=0[.]9[.]0, not 1[.]0[.]0-alpha[.]1') "The conflict must name the mismatch, not a reader refusal. Output: $($Result.Text)"
	}

	# The live snapshot reads Config ini from the nominated revision's Git objects,
	# never from the checkout. A local repository needs no network.
	Test-Case 'config read at the nominated revision' {
		. (Join-Path $RepositoryRoot 'scripts/build/ProjectVersion.ps1')
		$Repo = Join-Path $FixtureRoot 'revision-repo'
		New-Item -ItemType Directory -Path (Join-Path $Repo 'Config/Linux') -Force | Out-Null
		function Invoke-FixtureGit([string[]] $Arguments) {
			$Previous = $ErrorActionPreference
			$ErrorActionPreference = 'Continue'
			try { $Output = @(& git -C $Repo -c user.name=fixture -c user.email=fixture@example.invalid -c core.autocrlf=false @Arguments 2>&1) }
			finally { $ErrorActionPreference = $Previous }
			if ($LASTEXITCODE -ne 0) { throw "fixture git $($Arguments[0]) failed: $Output" }
			return $Output
		}
		$Clean = "[/Script/EngineSettings.GeneralProjectSettings]`nProjectName=AethelnOnline`n"
		$Override = "[/Script/EngineSettings.GeneralProjectSettings]`nProjectVersion=0.9.0`n"
		Invoke-FixtureGit @('init', '-q') | Out-Null
		[IO.File]::WriteAllText((Join-Path $Repo 'Config/DefaultGame.ini'), $Clean)
		[IO.File]::WriteAllText((Join-Path $Repo 'Config/Linux/LinuxGame.ini'), $Override)
		Invoke-FixtureGit @('add', '-A') | Out-Null
		Invoke-FixtureGit @('commit', '-q', '-m', 'A') | Out-Null
		$RevisionA = [string] (Invoke-FixtureGit @('rev-parse', 'HEAD'))
		Invoke-FixtureGit @('rm', '-q', 'Config/Linux/LinuxGame.ini') | Out-Null
		Invoke-FixtureGit @('commit', '-q', '-m', 'B') | Out-Null
		$RevisionB = [string] (Invoke-FixtureGit @('rev-parse', 'HEAD'))

		# A's tracked override is refused although the checkout (B) is clean.
		$AtA = Get-ProjectVersionGitConfig -RepositoryRoot $Repo -Revision $RevisionA
		Assert-True (@($AtA.otherConfigIni).Count -eq 1) 'Revision A must yield its one other Config ini.'
		$Refused = $null
		try { Read-ProjectVersionConfig -DefaultGameContent $AtA.defaultGameIni -OtherIniContents $AtA.otherConfigIni -AllowMissing | Out-Null } catch { $Refused = $_.Exception.Message }
		Assert-True ($Refused -ceq 'project_version_override') "Revision A's override must be refused. Got: $Refused"

		# B stays clean although the checkout now carries an untracked override and a dirty default.
		New-Item -ItemType Directory -Path (Join-Path $Repo 'Config/Linux') -Force | Out-Null
		[IO.File]::WriteAllText((Join-Path $Repo 'Config/Linux/LinuxGame.ini'), $Override)
		[IO.File]::WriteAllText((Join-Path $Repo 'Config/DefaultGame.ini'), $Clean + "ProjectVersion=0.9.0`n")
		$AtB = Get-ProjectVersionGitConfig -RepositoryRoot $Repo -Revision $RevisionB
		Assert-True (@($AtB.otherConfigIni).Count -eq 0 -and $AtB.defaultGameIni -cnotmatch 'ProjectVersion') 'Revision B must not read the checkout.'
		Assert-True ($null -eq (Read-ProjectVersionConfig -DefaultGameContent $AtB.defaultGameIni -OtherIniContents $AtB.otherConfigIni -AllowMissing)) 'Revision B must read as having no version.'

		# An unreadable revision throws without the repository path.
		$Unreadable = $null
		try { Get-ProjectVersionGitConfig -RepositoryRoot $Repo -Revision ('0' * 40) | Out-Null } catch { $Unreadable = $_.Exception.Message }
		Assert-True ($Unreadable -match '^git ls-tree failed' -and $Unreadable -notmatch [regex]::Escape($FixtureRoot)) "An unreadable revision must throw a path-free git failure. Got: $Unreadable"
	}

	# A tracked ini with a UTF-8 byte-order mark reads the same from Git as from disk.
	Test-Case 'byte-order mark in tracked config' {
		. (Join-Path $RepositoryRoot 'scripts/build/ProjectVersion.ps1')
		$Repo = Join-Path $FixtureRoot 'bom-repo'
		New-Item -ItemType Directory -Path (Join-Path $Repo 'Config') -Force | Out-Null
		$Bom = [Text.UTF8Encoding]::new($true)
		[IO.File]::WriteAllText((Join-Path $Repo 'Config/DefaultGame.ini'), "[/Script/EngineSettings.GeneralProjectSettings]`nProjectVersion=1.0.0-alpha.1`n", $Bom)
		[IO.File]::WriteAllText((Join-Path $Repo 'Config/DefaultEngine.ini'), "[/Script/Engine.Engine]`nUnrelated=1`n", $Bom)
		function Invoke-BomGit([string[]] $Arguments) {
			$Previous = $ErrorActionPreference
			$ErrorActionPreference = 'Continue'
			try { $Output = @(& git -C $Repo -c user.name=fixture -c user.email=fixture@example.invalid -c core.autocrlf=false @Arguments 2>&1) }
			finally { $ErrorActionPreference = $Previous }
			if ($LASTEXITCODE -ne 0) { throw "fixture git $($Arguments[0]) failed: $Output" }
			return $Output
		}
		Invoke-BomGit @('init', '-q') | Out-Null
		Invoke-BomGit @('add', '-A') | Out-Null
		Invoke-BomGit @('commit', '-q', '-m', 'bom') | Out-Null
		$Revision = [string] (Invoke-BomGit @('rev-parse', 'HEAD'))
		$AtBom = Get-ProjectVersionGitConfig -RepositoryRoot $Repo -Revision $Revision
		$FromGit = Read-ProjectVersionConfig -DefaultGameContent $AtBom.defaultGameIni -OtherIniContents $AtBom.otherConfigIni -AllowMissing
		Assert-True ($FromGit -ceq (Read-ProjectVersion (Join-Path $Repo 'Config/DefaultGame.ini')) -and $FromGit -ceq '1.0.0-alpha.1') "A BOM-prefixed ini must read the same from Git and disk. Got: $FromGit"
	}

	# Usage errors exit 2 under `-File`, not the exit 1 that is reserved for violations.
	Test-Case 'usage errors' {
		$Fixture = Join-Path $FixtureRoot 'usage.json'
		[IO.File]::WriteAllText($Fixture, (ConvertTo-Json -InputObject (New-CleanSnapshot) -Depth 8))
		Assert-ExitTwo -Result (Invoke-CutProcess @('-Stage', 'Nope', '-Version', '1.0.0-alpha.1', '-FixturePath', $Fixture)) -Reason 'usage' -Name 'A bad -Stage'
		Assert-ExitTwo -Result (Invoke-CutProcess @('-Stage', 'verify', '-Version', '1.0.0-alpha.1', '-FixturePath', $Fixture)) -Reason 'usage' -Name 'A -Stage in the wrong case'
		Assert-ExitTwo -Result (Invoke-CutProcess @('-Stage', 'Verify', '-FixturePath', $Fixture)) -Reason 'usage' -Name 'A missing -Version'
		Assert-ExitTwo -Result (Invoke-CutProcess @('-Stage', 'Verify', '-Version', '1.0.0-alpha.1', '-FixturePath', $Fixture, '-Bogus', 'x')) -Reason 'usage' -Name 'An unknown parameter'
		Assert-ExitTwo -Result (Invoke-CutProcess @('-Stage', 'VerifyPackage', '-Version', '1.0.0-alpha.1')) -Reason 'usage' -Name 'VerifyPackage without its inputs'
	}

	# VerifyPackage: logs and provenance only.
	function New-NetVersionLog {
		[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs fixture text.')]
		param([string] $Version, [string] $Checksum = '1234567890')
		return "[2026.10.03-12.00.00:000][  0]LogInit: Build: fixture`n[2026.10.03-12.00.01:000][  0]LogNet: Set ProjectVersion to $Version. Version Checksum will be recalculated on next use.`n[2026.10.03-12.00.02:000][  0]LogNetVersion: AethelnOnline $Version, NetCL: 0, EngineNetworkVersion: 38, GameNetworkVersion: 0 (Checksum: $Checksum)`n"
	}
	function Invoke-VerifyPackage {
		param([string] $Name, [string] $ClientLog, [string] $ServerLog, [string] $Provenance, [hashtable] $Parameters = @{})
		$Client = Join-Path $FixtureRoot ($Name + '-client.log')
		$Server = Join-Path $FixtureRoot ($Name + '-server.log')
		$ProvenanceFile = Join-Path $FixtureRoot ($Name + '-provenance.json')
		[IO.File]::WriteAllText($Client, $ClientLog)
		[IO.File]::WriteAllText($Server, $ServerLog)
		[IO.File]::WriteAllText($ProvenanceFile, $Provenance)
		$Arguments = @{ Stage = 'VerifyPackage'; Version = '1.0.0-alpha.1'; ClientLogPath = $Client; ServerLogPath = $Server; ProvenancePath = $ProvenanceFile; ReleaseRevision = $CutRevision }
		foreach ($Key in $Parameters.Keys) { $Arguments[$Key] = $Parameters[$Key] }
		return Invoke-Cut $Arguments
	}
	$GoodLog = New-NetVersionLog -Version '1.0.0-alpha.1'
	$GoodProvenance = "{ `"schemaVersion`": 2, `"source`": { `"revision`": `"$CutRevision`" } }"
	$PackageCases = @(
		@{ Code = 'release_package_version_mismatch'; Subject = 'server'; Client = $GoodLog; Server = (New-NetVersionLog -Version '1.0.0-alpha.2' -Checksum '777'); Provenance = $GoodProvenance },
		@{ Code = 'release_package_version_mismatch'; Subject = 'client'; Client = "[2026.10.03-12.00.00:000][  0]LogInit: no net version line here`n"; Server = $GoodLog; Provenance = $GoodProvenance },
		@{ Code = 'release_package_version_mismatch'; Subject = 'client-server'; Client = $GoodLog; Server = (New-NetVersionLog -Version '1.0.0-alpha.1' -Checksum '999'); Provenance = $GoodProvenance },
		@{ Code = 'release_package_version_mismatch'; Subject = 'client-server'; Client = $GoodLog; Server = (New-NetVersionLog -Version '1.0.0-alpha.1+412'); Provenance = $GoodProvenance },
		@{ Code = 'release_package_revision_mismatch'; Subject = 'provenance'; Client = $GoodLog; Server = $GoodLog; Provenance = "{ `"schemaVersion`": 2, `"source`": { `"revision`": `"$OtherRevision`" } }" },
		@{ Code = 'release_package_revision_mismatch'; Subject = 'provenance'; Client = $GoodLog; Server = $GoodLog; Provenance = "{ `"sourceRevision`": `"$OtherRevision`" }" },
		@{ Code = 'release_package_revision_mismatch'; Subject = 'provenance'; Client = $GoodLog; Server = $GoodLog; Provenance = '{ "schemaVersion": 2 }' }
	)
	$Index = 0
	foreach ($Case in $PackageCases) {
		$Index++
		$Name = "$($Case.Code) package case $Index"
		Test-Case $Name {
			$Result = Invoke-VerifyPackage -Name ('package-' + $Index) -ClientLog $Case.Client -ServerLog $Case.Server -Provenance $Case.Provenance
			Assert-True ($Result.ExitCode -eq 1 -and $Result.Lines.Count -eq 1 -and $Result.Lines[0].StartsWith("$($Case.Code) $($Case.Subject) ") -and $Result.Text -match 'Release cut VerifyPackage: 1 violation\(s\)\.') "$Name must report exactly '$($Case.Code) $($Case.Subject) <detail>'. Output: $($Result.Text)"
		}
	}

	# The engine default 1.0.0.0 (Engine/Config/BaseGame.ini) in both logs means ProjectVersion never reached the package.
	Test-Case 'package default version' {
		$Default = New-NetVersionLog -Version '1.0.0.0'
		$Result = Invoke-VerifyPackage -Name 'package-default' -ClientLog $Default -ServerLog $Default -Provenance $GoodProvenance
		Assert-True ($Result.ExitCode -eq 1 -and $Result.Lines.Count -eq 2 -and $Result.Lines[0].StartsWith('release_package_version_mismatch client ') -and $Result.Lines[1].StartsWith('release_package_version_mismatch server ')) "Both logs must fail when they show a version other than the release. Output: $($Result.Text)"
	}
	Test-Case 'package green forms' {
		$Clean = Invoke-VerifyPackage -Name 'package-clean' -ClientLog $GoodLog -ServerLog $GoodLog -Provenance $GoodProvenance
		Assert-True ($Clean.ExitCode -eq 0 -and $Clean.Text -match 'Release cut VerifyPackage: 0 violation\(s\)\.') "Matching logs and provenance must be green. Output: $($Clean.Text)"
		$Flat = Invoke-VerifyPackage -Name 'package-flat' -ClientLog $GoodLog -ServerLog $GoodLog -Provenance "{ `"sourceRevision`": `"$($CutRevision.ToUpperInvariant())`" }"
		Assert-True ($Flat.ExitCode -eq 0) "A top-level sourceRevision must be accepted case-insensitively. Output: $($Flat.Text)"
		$Stamped = New-NetVersionLog -Version '1.0.0-alpha.1+412'
		$StampedResult = Invoke-VerifyPackage -Name 'package-stamped' -ClientLog $Stamped -ServerLog $Stamped -Provenance $GoodProvenance
		Assert-True ($StampedResult.ExitCode -eq 0) "A stamped version carrying the release version must be accepted. Output: $($StampedResult.Text)"
		$Exact = Invoke-VerifyPackage -Name 'package-exact' -ClientLog $Stamped -ServerLog $Stamped -Provenance $GoodProvenance -Parameters @{ BuildNumber = '412' }
		Assert-True ($Exact.ExitCode -eq 0) "The expected build number must be accepted. Output: $($Exact.Text)"
		$Wrong = Invoke-VerifyPackage -Name 'package-wrong-build' -ClientLog $Stamped -ServerLog $Stamped -Provenance $GoodProvenance -Parameters @{ BuildNumber = '413' }
		Assert-True ($Wrong.ExitCode -eq 1 -and $Wrong.Lines.Count -eq 2) "A different build number must fail both logs. Output: $($Wrong.Text)"
		$Recalculated = (New-NetVersionLog -Version '1.0.0') + (New-NetVersionLog -Version '1.0.0-alpha.1')
		$Last = Invoke-VerifyPackage -Name 'package-last' -ClientLog $Recalculated -ServerLog $Recalculated -Provenance $GoodProvenance
		Assert-True ($Last.ExitCode -eq 0) "The last LogNetVersion line must win after a recalculation. Output: $($Last.Text)"
		$Json = Invoke-VerifyPackage -Name 'package-json' -ClientLog $GoodLog -ServerLog (New-NetVersionLog -Version '1.0.0-alpha.1' -Checksum '999') -Provenance $GoodProvenance -Parameters @{ Json = $true }
		$Parsed = $Json.Text | ConvertFrom-Json
		Assert-True ($Json.ExitCode -eq 1 -and $Parsed.stage -ceq 'VerifyPackage' -and $Parsed.count -eq 1 -and $Parsed.violations[0].code -ceq 'release_package_version_mismatch') '-Json must emit the VerifyPackage violation.'
	}
	Test-Case 'package environment error' {
		$Missing = Invoke-CutProcess @('-Stage', 'VerifyPackage', '-Version', '1.0.0-alpha.1', '-ClientLogPath', (Join-Path $FixtureRoot 'absent-client.log'), '-ServerLogPath', (Join-Path $FixtureRoot 'absent-server.log'), '-ProvenancePath', (Join-Path $FixtureRoot 'absent.json'), '-ReleaseRevision', $CutRevision)
		Assert-ExitTwo -Result $Missing -Reason 'environment' -Name 'A missing log'
		$Present = Join-Path $FixtureRoot 'present.log'
		[IO.File]::WriteAllText($Present, $GoodLog)
		$NoProvenance = Invoke-CutProcess @('-Stage', 'VerifyPackage', '-Version', '1.0.0-alpha.1', '-ClientLogPath', $Present, '-ServerLogPath', $Present, '-ProvenancePath', (Join-Path $FixtureRoot 'absent.json'), '-ReleaseRevision', $CutRevision)
		Assert-ExitTwo -Result $NoProvenance -Reason 'environment' -Name 'A missing provenance file'
	}

	# -ReleaseRevision is a 40-character commit SHA, so a short SHA or a ref name is an error, not a mismatch.
	Test-Case 'invalid release revision' {
		foreach ($Bad in @('abc123', 'refs/heads/release/v1.0.0-alpha.1', ($CutRevision + '0'), ('g' + $CutRevision.Substring(1)))) {
			$Result = Invoke-VerifyPackage -Name 'package-bad-revision' -ClientLog $GoodLog -ServerLog $GoodLog -Provenance $GoodProvenance -Parameters @{ ReleaseRevision = $Bad }
			Assert-True ($Result.ExitCode -eq 2 -and $Result.Lines.Count -eq 0) "-ReleaseRevision '$Bad' must exit 2 without a violation line. Exit: $($Result.ExitCode). Output: $($Result.Text)"
		}
		$Upper = Invoke-VerifyPackage -Name 'package-upper-revision' -ClientLog $GoodLog -ServerLog $GoodLog -Provenance $GoodProvenance -Parameters @{ ReleaseRevision = $CutRevision.ToUpperInvariant() }
		Assert-True ($Upper.ExitCode -eq 0) "An uppercase SHA is lowercased like -DevelopRevision. Output: $($Upper.Text)"
	}
}
finally {
	Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Failures.Count -gt 0) {
	foreach ($Failure in $Failures) { Write-Output "FAIL: $Failure" }
	Write-Output "FAIL: $($Failures.Count) release-cut check(s) failed"
	exit 1
}
Write-Output 'PASS: release-cut script reports every code red, counts all violations, emits -Json, records every ProjectVersion consumer, and stays green on a clean snapshot and package'
exit 0
