[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProjectId', Justification = 'Consumed by the nested Get-LiveSnapshot.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Repository', Justification = 'Consumed by the nested Get-LiveSnapshot.')]
param(
	[string] $FixturePath,
	[string] $ProjectId = 'PVT_kwHOBB63qs4Bedeu',
	[string] $Repository = 'ShayShimoni/aetheln-online',
	[switch] $Json
)

# Issue #214 board integrity check. Reads the project board and open pull
# requests through the locally authenticated `gh` (read-only GraphQL), or a
# normalized JSON snapshot from -FixturePath for offline tests, and reports
# every delivery-rule violation as `<rule-id> #<issue> <detail>`. Exits 1 on
# any violation and 0 when the board is clean.
#
# Snapshot shape: { items: [{ number, state, status, release, blockedReason,
# body }], pullRequests: [{ number, title, isDraft, isCrossRepository,
# headRefName, baseRefName, linkedIssues: [n] }] }. A pull request links an
# issue through closingIssuesReferences or a `#<n>` in its title. PRs reference
# their issue with a body `Refs #<n>` line and no closing keyword or
# Development link, so the title is the usual link; a carried fix's `Refs` line
# is not a link. A PR that links no issue is left to the hosted
# `pull-request-policy` title check. Draft pull requests count as open, and
# `draft-pr-open` reports the PR's own number. Release and `main` into
# `develop` back-merge PRs ship work already tracked elsewhere, so they are
# outside the Code Review match; a hotfix PR links its own ticket and is
# matched like any other. A fork names its own branches, so a cross-repository
# PR gets no exclusion. Only this repository's issues are read.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GhGraphQl {
	param(
		[Parameter(Mandatory)][string] $Query,
		[Parameter(Mandatory)][hashtable] $Variables
	)

	$Arguments = @('api', 'graphql', '-f', ('query=' + $Query))
	foreach ($Name in $Variables.Keys) {
		if ($null -ne $Variables[$Name]) { $Arguments += @('-f', ($Name + '=' + $Variables[$Name])) }
	}
	$PreviousPreference = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		$Output = @(& gh @Arguments 2>&1 | ForEach-Object { "$_" })
		$ExitCode = $LASTEXITCODE
	}
	finally {
		$ErrorActionPreference = $PreviousPreference
	}
	if ($ExitCode -ne 0) { throw "gh api graphql failed: $($Output -join [Environment]::NewLine)" }
	return (($Output -join "`n") | ConvertFrom-Json)
}

function Get-LiveSnapshot {
	# Queries contain no string literals so native argument passing stays safe.
	$ItemQuery = 'query($id: ID!, $after: String) { node(id: $id) { ... on ProjectV2 { items(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { content { __typename ... on Issue { number state body repository { nameWithOwner } } } fieldValues(first: 30) { nodes { ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2FieldCommon { name } } } ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { name } } } } } } } } } }'
	$PullQuery = 'query($owner: String!, $name: String!, $after: String) { repository(owner: $owner, name: $name) { pullRequests(states: OPEN, first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { number title isDraft isCrossRepository headRefName baseRefName closingIssuesReferences(first: 20) { nodes { number } } } } } }'

	$Items = New-Object Collections.Generic.List[object]
	$Cursor = $null
	do {
		$Page = (Invoke-GhGraphQl -Query $ItemQuery -Variables @{ id = $ProjectId; after = $Cursor }).data.node.items
		foreach ($Node in $Page.nodes) {
			if ($null -eq $Node.content -or $Node.content.__typename -cne 'Issue' -or $Node.content.repository.nameWithOwner -cne $Repository) { continue }
			$Fields = @{}
			foreach ($Value in $Node.fieldValues.nodes) {
				$FieldProperty = $Value.PSObject.Properties['field']
				if ($null -eq $FieldProperty -or $null -eq $FieldProperty.Value) { continue }
				$Fields[$FieldProperty.Value.name] = if ($Value.PSObject.Properties['name']) { $Value.name } else { $Value.text }
			}
			$Items.Add([pscustomobject][ordered]@{
				number = $Node.content.number; state = $Node.content.state; status = $Fields['Status']
				release = $Fields['Release']; blockedReason = $Fields['Blocked Reason']; body = $Node.content.body
			})
		}
		$Cursor = $Page.pageInfo.endCursor
	} while ($Page.pageInfo.hasNextPage)

	$Owner, $Name = $Repository -split '/', 2
	$PullRequests = New-Object Collections.Generic.List[object]
	$Cursor = $null
	do {
		$Page = (Invoke-GhGraphQl -Query $PullQuery -Variables @{ owner = $Owner; name = $Name; after = $Cursor }).data.repository.pullRequests
		foreach ($Node in $Page.nodes) {
			$PullRequests.Add([pscustomobject][ordered]@{
				number = $Node.number; title = $Node.title; isDraft = $Node.isDraft; isCrossRepository = $Node.isCrossRepository
				headRefName = $Node.headRefName; baseRefName = $Node.baseRefName
				linkedIssues = @($Node.closingIssuesReferences.nodes | ForEach-Object { $_.number })
			})
		}
		$Cursor = $Page.pageInfo.endCursor
	} while ($Page.pageInfo.hasNextPage)

	return [pscustomobject]@{ items = $Items.ToArray(); pullRequests = $PullRequests.ToArray() }
}

function Get-OptionalText($Object, [string] $Name) {
	$Property = $Object.PSObject.Properties[$Name]
	if ($null -eq $Property -or $null -eq $Property.Value) { return '' }
	return [string] $Property.Value
}

function Get-BoardViolation {
	param([Parameter(Mandatory)] $Snapshot)

	$Violations = New-Object Collections.Generic.List[object]
	function Add-Violation([string] $Rule, [int] $Issue, [string] $Detail) {
		$Violations.Add([pscustomobject][ordered]@{ rule = $Rule; issue = $Issue; detail = $Detail })
	}

	$ByNumber = @{}
	foreach ($Item in @($Snapshot.items)) {
		$Number = [int] $Item.number
		$ByNumber[$Number] = $Item
		$State = Get-OptionalText $Item 'state'
		$Status = Get-OptionalText $Item 'status'
		$StatusLabel = if ($Status) { $Status } else { '(none)' }
		# Release Candidate sits between Done and Released, so its issue stays closed.
		$ClosedAllowed = $Status -cin @('Done', 'Release Candidate', 'Released')

		if ($Status -ceq 'Done') {
			$Boxes = @([regex]::Matches((Get-OptionalText $Item 'body'), '(?m)^[ \t]*- \[([ xX])\]'))
			$Unchecked = @($Boxes | Where-Object { $_.Groups[1].Value -ceq ' ' }).Count
			if ($Unchecked -gt 0) { Add-Violation -Rule 'done-unchecked-acceptance' -Issue $Number -Detail "is Done with $Unchecked of $($Boxes.Count) checkboxes unchecked" }
		}
		if ($State -ceq 'CLOSED' -and -not $ClosedAllowed) { Add-Violation -Rule 'closed-issue-status' -Issue $Number -Detail "is closed but in '$StatusLabel', not Done, Release Candidate, or Released" }
		if ($State -ceq 'OPEN' -and $Status -cin @('Done', 'Released')) { Add-Violation -Rule 'open-issue-final-status' -Issue $Number -Detail "is open but in '$Status'" }
		if ($Status -cin @('Release Candidate', 'Released') -and [string]::IsNullOrWhiteSpace((Get-OptionalText $Item 'release'))) { Add-Violation -Rule 'release-field-empty' -Issue $Number -Detail "is in '$Status' with an empty Release field" }
		if ($Status -ceq 'Blocked' -and [string]::IsNullOrWhiteSpace((Get-OptionalText $Item 'blockedReason'))) { Add-Violation -Rule 'blocked-reason-empty' -Issue $Number -Detail 'is Blocked without a Blocked Reason' }
	}

	$PullsByIssue = @{}
	foreach ($Pull in @($Snapshot.pullRequests)) {
		if ($Pull.isDraft) { Add-Violation -Rule 'draft-pr-open' -Issue ([int] $Pull.number) -Detail 'is an open draft PR; open a PR only after developer verification' }
		$Head = Get-OptionalText $Pull 'headRefName'
		if (-not $Pull.isCrossRepository -and ($Head -cmatch '^release/' -or ($Head -ceq 'main' -and (Get-OptionalText $Pull 'baseRefName') -ceq 'develop'))) { continue }
		$Linked = @(@($Pull.linkedIssues) + @([regex]::Matches((Get-OptionalText $Pull 'title'), '#(\d+)') | ForEach-Object { $_.Groups[1].Value }) |
			Where-Object { $null -ne $_ } | ForEach-Object { [int] $_ } | Sort-Object -Unique)
		foreach ($Number in $Linked) {
			if (-not $PullsByIssue.ContainsKey($Number)) { $PullsByIssue[$Number] = @() }
			$PullsByIssue[$Number] += [int] $Pull.number
			$Status = if ($ByNumber.ContainsKey($Number)) { Get-OptionalText $ByNumber[$Number] 'status' } else { '(not on board)' }
			if ($Status -cne 'Code Review') {
				$StatusLabel = if ($Status) { $Status } else { '(none)' }
				Add-Violation -Rule 'open-pr-issue-status' -Issue $Number -Detail "has open PR #$($Pull.number) but is in '$StatusLabel', not Code Review"
			}
		}
	}
	foreach ($Number in $PullsByIssue.Keys) {
		$Pulls = $PullsByIssue[$Number]
		if ($Pulls.Count -gt 1) { Add-Violation -Rule 'duplicate-pr-issue' -Issue $Number -Detail "is linked by open PRs #$($Pulls -join ', #'); keep one open PR per issue" }
	}
	foreach ($Item in @($Snapshot.items)) {
		if ((Get-OptionalText $Item 'status') -ceq 'Code Review' -and -not $PullsByIssue.ContainsKey([int] $Item.number)) {
			Add-Violation -Rule 'code-review-without-pr' -Issue ([int] $Item.number) -Detail 'is in Code Review without an open PR linking it'
		}
	}
	return $Violations.ToArray()
}

$Snapshot = if ($FixturePath) { Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json } else { Get-LiveSnapshot }
$Violations = @(Get-BoardViolation -Snapshot $Snapshot | Sort-Object -Property rule, issue)

if ($Json) {
	Write-Output (ConvertTo-Json -InputObject ([ordered]@{ count = $Violations.Count; violations = $Violations }) -Depth 4)
}
else {
	foreach ($Violation in $Violations) { Write-Output "$($Violation.rule) #$($Violation.issue) $($Violation.detail)" }
	Write-Output "Board integrity: $($Violations.Count) violation(s)."
}
if ($Violations.Count -gt 0) { exit 1 }
exit 0
