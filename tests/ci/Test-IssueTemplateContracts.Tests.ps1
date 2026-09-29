[CmdletBinding()]
param(
	[string] $TemplateRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $TemplateRoot) {
	$TemplateRoot = Join-Path $RepositoryRoot '.github/ISSUE_TEMPLATE'
}
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("AethelnIssueTemplateContractTests-{0}" -f [guid]::NewGuid().ToString('N'))

# Each canonical template applies exactly one existing type label and keeps the
# sections that make an issue of that type completable.
$Contracts = [ordered]@{
	'bug-report.md' = @{ Label = 'type: bug'; Sections = @('Summary', 'Steps to reproduce', 'Expected behavior', 'Actual behavior', 'Definition of done') }
	'epic.md' = @{ Label = 'type: epic'; Sections = @('Purpose', 'Scope', 'Evidence and decision boundaries', 'Acceptance criteria', 'Definition of done') }
	'spike.md' = @{ Label = 'type: spike'; Sections = @('Purpose', 'Scope', 'Evidence and decision boundaries', 'Acceptance criteria', 'Definition of done') }
	'technical-task.md' = @{ Label = 'type: task'; Sections = @('Objective', 'Validation', 'Definition of done') }
	'user-story.md' = @{ Label = 'type: story'; Sections = @('User story', 'Acceptance criteria', 'Definition of done') }
}
$AllowedKeys = @('name', 'about', 'title', 'labels', 'assignees')

function ConvertFrom-TemplateScalar {
	param(
		[Parameter(Mandatory)][AllowEmptyString()][string] $Raw,
		[Parameter(Mandatory)][string] $Where
	)

	if ($Raw.StartsWith('"')) {
		if ($Raw -notmatch '^"((?:[^"\\]|\\.)*)"$') { throw "${Where}: unterminated double-quoted value" }
		return ($Raw | ConvertFrom-Json)
	}
	# A plain YAML scalar cannot start with an indicator or contain ': ' or ' #'.
	if ($Raw -eq '' -or $Raw -match '^[\[\]{}&*!|>''%@`#,?:-]' -or $Raw -match ': |:$| #') {
		throw "${Where}: value '$Raw' is not a valid plain YAML scalar; quote it"
	}
	return $Raw
}

function Assert-IssueTemplate {
	param(
		[Parameter(Mandatory)][string] $Name,
		[Parameter(Mandatory)][string] $Text
	)

	if ($Text.Contains("`r")) { throw "${Name}: CRLF line endings; templates are stored with LF" }
	$Lines = $Text -split "`n"
	if ($Lines[0] -cne '---') { throw "${Name}: front matter must start on line 1" }
	$End = [Array]::IndexOf($Lines, '---', 1)
	if ($End -lt 0) { throw "${Name}: front matter is not closed" }

	$Meta = @{}
	for ($Index = 1; $Index -lt $End; $Index++) {
		if ($Lines[$Index] -cnotmatch '^([a-z_]+): ?(.*)$') { throw "${Name}:$($Index + 1): expected a flat 'key: value' line" }
		$Key = $Matches[1]
		$Raw = $Matches[2]
		if ($AllowedKeys -cnotcontains $Key) { throw "${Name}:$($Index + 1): unsupported front-matter key '$Key'" }
		if ($Meta.ContainsKey($Key)) { throw "${Name}:$($Index + 1): duplicate front-matter key '$Key'" }
		$Meta[$Key] = ConvertFrom-TemplateScalar -Raw $Raw -Where "${Name}:$($Index + 1)"
	}
	foreach ($Required in @('name', 'about', 'labels')) {
		if (-not $Meta.ContainsKey($Required) -or [string]::IsNullOrWhiteSpace([string] $Meta[$Required])) { throw "${Name}: missing front-matter '$Required'" }
	}

	$Contract = $Contracts[$Name]
	$Labels = @(([string] $Meta['labels']) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
	if ($Labels.Count -ne 1 -or $Labels[0] -cne $Contract.Label) {
		throw "${Name}: labels must be exactly '$($Contract.Label)', found '$($Labels -join ', ')'"
	}

	$Body = @($Lines[($End + 1)..($Lines.Count - 1)])
	$VisibleBody = [System.Collections.Generic.List[string]]::new()
	$FenceCharacter = ''
	$FenceWidth = 0
	foreach ($Line in $Body) {
		if ($FenceWidth -gt 0) {
			if ($Line -match '^ {0,3}(`{3,}|~{3,})[ \t]*$' -and [string] $Matches[1][0] -ceq $FenceCharacter -and $Matches[1].Length -ge $FenceWidth) {
				$FenceWidth = 0
			}
			continue
		}
		if ($Line -match '^ {0,3}(`{3,}|~{3,})(.*)$') {
			$CandidateCharacter = [string] $Matches[1][0]
			if ($CandidateCharacter -cne '`' -or $Matches[2] -cnotmatch '`') {
				$FenceCharacter = $CandidateCharacter
				$FenceWidth = $Matches[1].Length
				continue
			}
		}
		# These five issue forms need plain Markdown sections, not raw HTML.
		# Reject HTML-like source outside fences instead of partially parsing it:
		# comments and raw HTML blocks can hide an apparent heading or checkbox.
		if ($Line -cmatch '<(?=[A-Za-z/!?])') { throw "${Name}: raw HTML-like markup is not allowed" }
		[void] $VisibleBody.Add($Line)
	}
	$Body = @($VisibleBody.ToArray())
	$Headings = @($Body | Where-Object { $_ -cmatch '^## ' } | ForEach-Object { $_.Substring(3).Trim() })
	foreach ($Section in $Contract.Sections) {
		if ($Headings -cnotcontains $Section) { throw "${Name}: missing section '## $Section'" }
	}
	$DoneStart = [Array]::IndexOf($Body, '## Definition of done')
	$DoneItems = 0
	for ($Index = $DoneStart + 1; $Index -lt $Body.Count -and $Body[$Index] -cnotmatch '^## '; $Index++) {
		if ($Body[$Index] -cmatch '^- \[ \] \S') { $DoneItems++ }
	}
	if ($DoneItems -eq 0) { throw "${Name}: Definition of done has no checklist items" }
	return [string] $Meta['name']
}

function Assert-IssueTemplateSet {
	param([Parameter(Mandatory)][string] $Root)

	$Found = @(Get-ChildItem -LiteralPath $Root -File | ForEach-Object { $_.Name } | Sort-Object)
	$Expected = @($Contracts.Keys | Sort-Object)
	if (($Found -join '|') -cne ($Expected -join '|')) {
		throw "Issue template set '$($Found -join ', ')' does not match '$($Expected -join ', ')'"
	}
	$Names = @{}
	foreach ($File in $Found) {
		$TemplateName = Assert-IssueTemplate -Name $File -Text ([System.IO.File]::ReadAllText((Join-Path $Root $File)))
		if ($Names.ContainsKey($TemplateName)) { throw "${File}: duplicate template name '$TemplateName'" }
		$Names[$TemplateName] = $true
	}
}

function Assert-TemplateFailure {
	param(
		[Parameter(Mandatory)][string] $Case,
		[Parameter(Mandatory)][scriptblock] $Mutate,
		[Parameter(Mandatory)][string] $Expected
	)

	$CaseRoot = Join-Path $FixtureRoot $Case
	Copy-Item -LiteralPath $TemplateRoot -Destination $CaseRoot -Recurse
	& $Mutate $CaseRoot
	try {
		Assert-IssueTemplateSet -Root $CaseRoot
	}
	catch {
		if ($_.Exception.Message -notmatch $Expected) {
			throw "Fixture '$Case' failed for the wrong reason: $($_.Exception.Message)"
		}
		Write-Output "PASS: $Case fails closed"
		return
	}
	throw "Fixture '$Case' was accepted"
}

function Set-TemplateText {
	param([string] $Root, [string] $File, [string] $From, [string] $To)

	$Path = Join-Path $Root $File
	$Text = [System.IO.File]::ReadAllText($Path)
	if ($Text.IndexOf($From, [StringComparison]::Ordinal) -lt 0) { throw "Fixture setup: '$From' not found in $File" }
	[System.IO.File]::WriteAllText($Path, $Text.Replace($From, $To))
}

try {
	Assert-IssueTemplateSet -Root $TemplateRoot
	Write-Output 'PASS: all five canonical issue templates satisfy the contract'

	New-Item -ItemType Directory -Path $FixtureRoot | Out-Null
	Assert-TemplateFailure 'unquoted-colon-label' { param($R) Set-TemplateText $R 'bug-report.md' 'labels: "type: bug"' 'labels: type: bug' } 'not a valid plain YAML scalar'
	Assert-TemplateFailure 'legacy-label' { param($R) Set-TemplateText $R 'user-story.md' 'labels: "type: story"' 'labels: enhancement' } "labels must be exactly 'type: story'"
	Assert-TemplateFailure 'wrong-type-label' { param($R) Set-TemplateText $R 'bug-report.md' 'labels: "type: bug"' 'labels: "type: task"' } "labels must be exactly 'type: bug'"
	Assert-TemplateFailure 'extra-label' { param($R) Set-TemplateText $R 'spike.md' 'labels: "type: spike"' 'labels: "type: spike, documentation"' } "labels must be exactly 'type: spike'"
	Assert-TemplateFailure 'missing-about' { param($R) Set-TemplateText $R 'epic.md' "about: Group related stories, tasks, and spikes behind one delivery outcome`n" '' } "missing front-matter 'about'"
	Assert-TemplateFailure 'unsupported-key' { param($R) Set-TemplateText $R 'epic.md' 'about: ' 'summary: ' } "unsupported front-matter key 'summary'"
	Assert-TemplateFailure 'duplicate-key' { param($R) Set-TemplateText $R 'epic.md' "name: Epic`n" "name: Epic`nname: Epic`n" } "duplicate front-matter key 'name'"
	Assert-TemplateFailure 'unclosed-front-matter' { param($R) Set-TemplateText $R 'technical-task.md' "labels: `"type: task`"`n---`n" "labels: `"type: task`"`n" } 'front matter is not closed'
	Assert-TemplateFailure 'missing-section' { param($R) Set-TemplateText $R 'spike.md' '## Evidence and decision boundaries' '## Notes' } "missing section '## Evidence and decision boundaries'"
	Assert-TemplateFailure 'section-only-in-fence' { param($R) Set-TemplateText $R 'technical-task.md' '## Validation' "~~~markdown`n## Validation`n~~~" } "missing section '## Validation'"
	Assert-TemplateFailure 'section-only-in-comment' { param($R) Set-TemplateText $R 'technical-task.md' '## Validation' "<!--`n## Validation`n-->" } 'raw HTML-like markup'
	Assert-TemplateFailure 'section-only-in-raw-html' { param($R) Set-TemplateText $R 'technical-task.md' '## Validation' "<pre>`n## Validation`n</pre>" } 'raw HTML-like markup'
	Assert-TemplateFailure 'inline-html-comment' { param($R) Set-TemplateText $R 'technical-task.md' '## Validation' '## Validation <!-- maintainer note -->' } 'raw HTML-like markup'
	$InvalidFenceRoot = Join-Path $FixtureRoot 'backtick-in-info-is-not-fence'
	Copy-Item -LiteralPath $TemplateRoot -Destination $InvalidFenceRoot -Recurse
	Set-TemplateText $InvalidFenceRoot 'technical-task.md' '## Validation' ('```bad`info' + "`n## Validation")
	Assert-IssueTemplateSet -Root $InvalidFenceRoot
	Write-Output 'PASS: backtick in fence info does not hide a real section'
	Assert-TemplateFailure 'empty-definition-of-done' { param($R) $P = Join-Path $R 'epic.md'; $T = [System.IO.File]::ReadAllText($P); [System.IO.File]::WriteAllText($P, $T.Substring(0, $T.IndexOf('## Definition of done')) + "## Definition of done`n`nTBD`n") } 'Definition of done has no checklist items'
	Assert-TemplateFailure 'checklist-only-in-fence' {
		param($R)
		$P = Join-Path $R 'epic.md'
		$T = [System.IO.File]::ReadAllText($P)
		$Fenced = "## Definition of done`n`n" + '```markdown' + "`n- [ ] Example, not a real completion criterion`n" + '```' + "`n"
		[System.IO.File]::WriteAllText($P, $T.Substring(0, $T.IndexOf('## Definition of done')) + $Fenced)
	} 'Definition of done has no checklist items'
	Assert-TemplateFailure 'checklist-only-in-raw-html' {
		param($R)
		$P = Join-Path $R 'epic.md'
		$T = [System.IO.File]::ReadAllText($P)
		$RawHtml = "## Definition of done`n`n<pre>`n- [ ] Example, not a real completion criterion`n</pre>`n"
		[System.IO.File]::WriteAllText($P, $T.Substring(0, $T.IndexOf('## Definition of done')) + $RawHtml)
	} 'raw HTML-like markup'
	Assert-TemplateFailure 'checklist-only-in-comment' {
		param($R)
		$P = Join-Path $R 'epic.md'
		$T = [System.IO.File]::ReadAllText($P)
		$Commented = "## Definition of done`n`n<!--`n- [ ] Example, not a real completion criterion`n-->`n"
		[System.IO.File]::WriteAllText($P, $T.Substring(0, $T.IndexOf('## Definition of done')) + $Commented)
	} 'raw HTML-like markup'
	Assert-TemplateFailure 'crlf' { param($R) $P = Join-Path $R 'user-story.md'; [System.IO.File]::WriteAllText($P, ([System.IO.File]::ReadAllText($P)).Replace("`n", "`r`n")) } 'CRLF line endings'
	Assert-TemplateFailure 'missing-template' { param($R) Remove-Item -LiteralPath (Join-Path $R 'spike.md') } 'does not match'
	Assert-TemplateFailure 'unexpected-template' { param($R) Copy-Item -LiteralPath (Join-Path $R 'epic.md') -Destination (Join-Path $R 'feature.md') } 'does not match'
	Write-Output 'All issue template contract tests passed.'
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) {
		Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
	}
}
