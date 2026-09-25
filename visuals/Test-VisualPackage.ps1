[CmdletBinding()]
param(
	[string] $Root,
	[int] $RequiredAssetCount = 104,
	[int] $RequiredTotalFileCount = 108
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).Path
$ManifestPath = Join-Path $Root 'package-manifest.json'
$ProvenancePath = Join-Path $Root 'asset-provenance.md'
$PromptPath = Join-Path $Root 'generation-prompts.md'
$Issue95ReportPath = Join-Path $Root 'issue-95-opening-screen-commonui-validation.md'
$GovernancePaths = @(
	'package-manifest.json',
	'asset-provenance.md',
	'Test-VisualPackage.ps1',
	'tests/Test-VisualPackageValidation.ps1'
)
$GovernanceFields = @('Provenance/custody', 'Authorship', 'Permission', 'License', 'Product approval')
$ReadmeExpectedProvenance = 'Owner-supplied legacy visual-package guidance; repository governance and current owner-approved concept direction updated under issues #94 and #95 after attested ingest.'
$ReadmeExpectedAuthorship = 'Repository-authored modifications under issues #94 and #95 recorded in git history; authorship of the underlying legacy material is **Pending/TBD**.'
$PendingPermissionState = '**Pending/TBD**: no permission grant is retained in this repository.'
$PendingLicenseState = '**Pending/TBD**: no license instrument is retained in this repository.'
$NotApprovedReferenceState = 'Not approved: no product approval is recorded; non-canonical reference/source asset.'
$NotApprovedGovernanceState = 'Not approved: no product approval is recorded; non-canonical planning/governance artifact that grants no asset rights, runtime approval, publication approval, or `Content/` promotion.'

$LegacyGovernancePaths = @(
	'01-main-menu-concept.png',
	'02-playable-peoples-lineup.png',
	'03-aurin-bulwark-equipment.png',
	'04-branmark-settlement.png',
	'05-glasswake-reach.png',
	'06-character-selection-concept.png',
	'07-ui-style-system.png',
	'generation-prompts.md',
	'ui-production/font-recommendations.md',
	'ui-production/README.md',
	'ui-production/screen-flow.md',
	'ui-production/ui-tokens.json',
	'ui-production/unreal-commonui-spec.md',
	'ui-production-v2/README.md'
)
foreach ($Name in @('controls', 'divider', 'logo-aetheln-online', 'panel-nine-slice', 'primary-button-disabled', 'primary-button-focused', 'primary-button-hover', 'primary-button-normal', 'primary-button-pressed')) {
	$LegacyGovernancePaths += "ui-production/assets/$Name.svg"
}
foreach ($Name in @('character-selection-stage', 'main-menu-background')) {
	$LegacyGovernancePaths += "ui-production/backgrounds/$Name.png"
}
foreach ($Name in @('accessibility', 'character-selection', 'main-menu', 'settings')) {
	$LegacyGovernancePaths += "ui-production/screens/$Name.svg"
}
foreach ($Name in @('button-disabled', 'button-focused', 'button-hover', 'button-normal', 'character-selection-stage', 'hud-status-frame', 'icon-basic-attack', 'icon-block', 'icon-buff', 'icon-debuff', 'icon-dodge', 'icon-health-consumable', 'kell-female-selection', 'loading-indicator', 'logo', 'main-menu-background', 'marker-interact', 'marker-objective', 'panel-large', 'playable-peoples-reference', 'reticle-free-aim', 'selection-card-frame', 'slider-cyan-65', 'slot-frame', 'toggle-off', 'toggle-on')) {
	$LegacyGovernancePaths += "ui-production-v2/assets/$Name.png"
}
foreach ($Name in @('button-disabled', 'button-focused', 'button-hover', 'button-normal', 'hud-status-frame', 'icon-basic-attack', 'icon-block', 'icon-buff', 'icon-debuff', 'icon-dodge', 'icon-health-consumable', 'kell-female-selection', 'loading-indicator', 'logo', 'marker-interact', 'marker-objective', 'panel-large', 'reticle-free-aim', 'selection-card-frame', 'slider-cyan-65', 'slot-frame', 'toggle-off', 'toggle-on')) {
	$LegacyGovernancePaths += "ui-production-v2/chroma-sources/$Name-source.png"
}
foreach ($Name in @('accessibility', 'character-selection', 'dialog-tooltip', 'gameplay-icons', 'hud', 'inventory', 'loading', 'main-menu', 'settings')) {
	$LegacyGovernancePaths += "ui-production-v2/previews/$Name-v2-preview.png"
}

$Issue114GovernancePaths = @(
	'01-overall-mood-key.png',
	'02-aurin-playable-study.png',
	'03-kell-playable-study.png',
	'04-vesh-playable-study.png',
	'05-oathscar-combat-sheet.png',
	'06-nullwright-combat-sheet.png',
	'07-hushblade-combat-sheet.png',
	'08-gravecant-combat-sheet.png',
	'09-blackfletch-combat-sheet.png',
	'10-combat-readability-scene.png'
)

$GovernanceSourceClassContracts = @(
	[pscustomobject]@{
		Name = 'Owner-supplied legacy package'
		Paths = $LegacyGovernancePaths
		States = [ordered]@{
			'Provenance/custody' = 'Owner-supplied legacy visual package; byte-preserved through attested external ingest.'
			'Authorship' = '**Pending/TBD**: no author identification is retained for the legacy package.'
			'Permission' = $PendingPermissionState
			'License' = $PendingLicenseState
			'Product approval' = $NotApprovedReferenceState
		}
	},
	[pscustomobject]@{
		Name = 'Owner-directed issue #114 generation'
		Paths = $Issue114GovernancePaths
		States = [ordered]@{
			'Provenance/custody' = 'Owner-directed concept generated through the built-in image-generation workflow for issue #114; frozen external ingest.'
			'Authorship' = 'Owner-directed generation through the built-in OpenAI image workflow, recorded by issue #114, `generation-prompts.md`, and C2PA `caBX` metadata.'
			'Permission' = $PendingPermissionState
			'License' = $PendingLicenseState
			'Product approval' = $NotApprovedReferenceState
		}
	},
	[pscustomobject]@{
		Name = 'Repository-hardened issue #94 authoring utility'
		Paths = @('ui-production-v2/build-gameplay-assets-preview.ps1', 'ui-production-v2/build-preview.ps1', 'ui-production-v2/build-screen-previews.ps1', 'ui-production-v2/remove-chroma.ps1')
		States = [ordered]@{
			'Provenance/custody' = 'Owner-supplied authoring utility; imported through attested external ingest and repository-hardened by issue #94.'
			'Authorship' = 'Repository-authored issue #94 modifications recorded in git history; authorship of the underlying legacy material is **Pending/TBD**.'
			'Permission' = $PendingPermissionState
			'License' = $PendingLicenseState
			'Product approval' = $NotApprovedReferenceState
		}
	},
	[pscustomobject]@{
		Name = 'Repository-hardened issue #94 guidance'
		Paths = @('FUTURE-VISUALS-PLAN.md')
		States = [ordered]@{
			'Provenance/custody' = 'Owner-supplied legacy visual-package guidance; repository references and governance handoff updated by issue #94 after attested ingest.'
			'Authorship' = 'Repository-authored issue #94 modifications recorded in git history; authorship of the underlying legacy material is **Pending/TBD**.'
			'Permission' = $PendingPermissionState
			'License' = $PendingLicenseState
			'Product approval' = $NotApprovedReferenceState
		}
	},
	[pscustomobject]@{
		Name = 'README issues #94/#95 guidance'
		Paths = @('README.md')
		States = [ordered]@{
			'Provenance/custody' = $ReadmeExpectedProvenance
			'Authorship' = $ReadmeExpectedAuthorship
			'Permission' = $PendingPermissionState
			'License' = $PendingLicenseState
			'Product approval' = $NotApprovedReferenceState
		}
	},
	[pscustomobject]@{
		Name = 'Repository-authored Issue #95 report'
		Paths = @('issue-95-opening-screen-commonui-validation.md')
		States = [ordered]@{
			'Provenance/custody' = 'Repository-authored Issue #95 visual-review and CommonUI planning report derived from canonical and imported-package evidence.'
			'Authorship' = 'Repository-authored under issue #95 and recorded in git history.'
			'Permission' = $PendingPermissionState
			'License' = $PendingLicenseState
			'Product approval' = $NotApprovedGovernanceState
		}
	}
)
$AcceptedNotApprovedAllowedCurrentUseValues = @(
	'Reference-only; replacement or rights clearance required before publication/runtime.',
	'Reference-only; potential internal prototype only after owner approval; replacement or rights clearance required before publication/runtime.',
	'Reference-only; potential internal prototype only after owner approval; replacement or clearance required for direct reuse.',
	'Reference-only styling guide; potential internal prototype only after owner approval; replacement or clearance required for direct reuse.',
	'Reference-only; never direct runtime import without clearance.',
	'Reference-only; potential internal prototype only after owner approval; replacement or rights clearance required.',
	'Reference-only; potential internal-prototype comparison only after owner approval; replacement or rights clearance required.',
	'Reference-only; potential internal-prototype styling guide only after owner approval; replacement or rights clearance required for reuse.'
)
$MojibakeEmDash = ([string][char]0x00E2) + [char]0x20AC + [char]0x201D
$EscapedBackslash = [regex]::Escape([string][char]92)
$MachinePathPattern = '(?i)(?:[A-' + 'Z]:' + $EscapedBackslash + '|/Use' + 'rs/|' + $EscapedBackslash + 'Use' + 'rs' + $EscapedBackslash + ')'

function Get-RelativeVisualPath {
	param([Parameter(Mandatory)][string] $Path)
	$FullPath = [System.IO.Path]::GetFullPath($Path)
	Assert-Condition ($FullPath.StartsWith($Root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) "Path escapes visual root: $Path"
	$FullPath.Substring($Root.Length + 1).Replace('\', '/')
}

function Assert-Condition {
	param([Parameter(Mandatory)][bool] $Condition, [Parameter(Mandatory)][string] $Message)
	if (-not $Condition) { throw $Message }
}

$GovernanceSourceClassByPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
foreach ($Contract in $GovernanceSourceClassContracts) {
	Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$Contract.Name)) 'Governance source-class contract has a blank name.'
	Assert-Condition (@($Contract.Paths).Count -gt 0) "Governance source-class contract '$($Contract.Name)' has no paths."
	Assert-Condition ($Contract.States.Count -eq $GovernanceFields.Count) "Governance source-class contract '$($Contract.Name)' must define exactly $($GovernanceFields.Count) states."
	foreach ($Field in $GovernanceFields) {
		Assert-Condition ($Contract.States.Contains($Field)) "Governance source-class contract '$($Contract.Name)' is missing state '$Field'."
		Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$Contract.States[$Field])) "Governance source-class contract '$($Contract.Name)' has a blank state '$Field'."
	}
	foreach ($ContractPath in @($Contract.Paths)) {
		Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$ContractPath)) "Governance source-class contract '$($Contract.Name)' has a blank path."
		Assert-Condition (-not $GovernanceSourceClassByPath.ContainsKey([string]$ContractPath)) "Governance path '$ContractPath' is assigned to more than one source class."
		$GovernanceSourceClassByPath.Add([string]$ContractPath, $Contract)
	}
}

function Test-OrdinalStringCollectionContains {
	param(
		[Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Values,
		[Parameter(Mandatory)][AllowEmptyString()][string] $Value
	)
	foreach ($Candidate in $Values) {
		if ([string]::Equals($Candidate, $Value, [System.StringComparison]::Ordinal)) { return $true }
	}
	$false
}

function Test-MarkdownIndentedCodeLine {
	param([Parameter(Mandatory)][AllowEmptyString()][string] $Line)

	$Column = 0
	foreach ($Character in $Line.ToCharArray()) {
		if ($Character -eq ' ') { $Column++ }
		elseif ($Character -eq "`t") { $Column += 4 - ($Column % 4) }
		else { break }
		if ($Column -ge 4) { return $true }
	}
	$false
}

function Split-MarkdownTableRow {
	param([Parameter(Mandatory)][string] $Row)
	Assert-Condition (-not (Test-MarkdownIndentedCodeLine -Line $Row)) "Malformed Markdown table row: indentation must stay before the four-column code boundary: $Row"
	$Trimmed = $Row.Trim()
	Assert-Condition (-not [string]::IsNullOrWhiteSpace($Trimmed)) "Malformed Markdown table row: $Row"

	$Start = if ($Trimmed.StartsWith('|')) { 1 } else { 0 }
	$End = $Trimmed.Length
	if ($End -gt $Start -and $Trimmed[$End - 1] -eq '|') {
		$BackslashCount = 0
		for ($Index = $End - 2; $Index -ge $Start -and $Trimmed[$Index] -eq '\'; $Index--) { $BackslashCount++ }
		if (($BackslashCount % 2) -eq 0) { $End-- }
	}

	$Cells = [System.Collections.Generic.List[string]]::new()
	$Cell = [System.Text.StringBuilder]::new()
	$BackslashRun = 0
	for ($Index = $Start; $Index -lt $End; $Index++) {
		$Character = $Trimmed[$Index]
		if ($Character -eq '\') {
			$null = $Cell.Append($Character)
			$BackslashRun++
			continue
		}
		if ($Character -eq '|' -and ($BackslashRun % 2) -eq 0) {
			$Cells.Add($Cell.ToString().Trim())
			$null = $Cell.Clear()
		}
		else {
			if ($Character -eq '|' -and ($BackslashRun % 2) -eq 1) { $Cell.Length-- }
			$null = $Cell.Append($Character)
		}
		$BackslashRun = 0
	}
	$Cells.Add($Cell.ToString().Trim())
	@($Cells)
}

function Measure-MarkdownIndent {
	# Leading whitespace of $Text in columns, measured from the absolute
	# $StartColumn with CommonMark four-column tab stops.
	param([Parameter(Mandatory)][AllowEmptyString()][string] $Text, [Parameter(Mandatory)][int] $StartColumn)
	$Column = $StartColumn
	$Chars = 0
	foreach ($Character in $Text.ToCharArray()) {
		if ($Character -eq ' ') { $Column++ }
		elseif ($Character -eq "`t") { $Column += 4 - ($Column % 4) }
		else { break }
		$Chars++
	}
	@{ Columns = $Column - $StartColumn; Chars = $Chars }
}

function Remove-MarkdownIndent {
	# Strip exactly $Columns of leading whitespace. A tab that overshoots is
	# re-expanded as spaces so the remainder keeps its rendered indentation.
	param([Parameter(Mandatory)][AllowEmptyString()][string] $Text, [Parameter(Mandatory)][int] $StartColumn, [Parameter(Mandatory)][int] $Columns)
	$Indent = Measure-MarkdownIndent -Text $Text -StartColumn $StartColumn
	(' ' * ($Indent.Columns - $Columns)) + $Text.Substring($Indent.Chars)
}

function Get-HtmlTagPattern {
	# Single-line subset of CommonMark's raw HTML tag grammar. Quotes are
	# values only after '='; closing tags cannot carry attributes or a slash.
	$TagNamePattern = '[A-Za-z][A-Za-z0-9-]*'
	$AttributeNamePattern = '[A-Za-z_:][A-Za-z0-9_.:-]*'
	$AttributeValuePattern = '(?:"[^"\r\n]*"|''[^''\r\n]*''|[^ \t\r\n"''=<>`]+)'
	$AttributePattern = '[ \t]+' + $AttributeNamePattern + '(?:[ \t]*=[ \t]*' + $AttributeValuePattern + ')?'
	'(?:<' + $TagNamePattern + '(?:' + $AttributePattern + ')*[ \t]*/?>|</' + $TagNamePattern + '[ \t]*>)'
}

function ConvertFrom-MarkdownLinks {
	# Replace bounded inline, reference, shortcut-link, and image syntax with
	# the visible label text. Inline destinations are scanned instead of matched
	# with a flat regex so balanced or escaped parentheses and quoted titles do
	# not conceal a rendered governance header.
	param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)
	$Output = [System.Text.StringBuilder]::new()
	$Index = 0
	while ($Index -lt $Text.Length) {
		$OpenIndex = if ($Text[$Index] -eq '[') { $Index } elseif ($Text[$Index] -eq '!' -and $Index + 1 -lt $Text.Length -and $Text[$Index + 1] -eq '[') { $Index + 1 } else { -1 }
		if ($OpenIndex -lt 0) {
			$null = $Output.Append($Text[$Index])
			$Index++
			continue
		}

		$Cursor = $OpenIndex + 1
		$BracketDepth = 1
		while ($Cursor -lt $Text.Length -and $BracketDepth -gt 0) {
			if ($Text[$Cursor] -eq '\\' -and $Cursor + 1 -lt $Text.Length) { $Cursor += 2; continue }
			if ($Text[$Cursor] -eq '[') { $BracketDepth++ }
			elseif ($Text[$Cursor] -eq ']') { $BracketDepth-- }
			$Cursor++
		}
		if ($BracketDepth -ne 0) {
			# No later bracket can close a nested link without also closing this
			# opener. Preserve the malformed suffix literally and stop, avoiding a
			# suffix rescan for every unmatched '['.
			$null = $Output.Append($Text.Substring($Index))
			break
		}

		$CloseIndex = $Cursor - 1
		$EndIndex = $Cursor
		if ($Cursor -lt $Text.Length -and $Text[$Cursor] -eq '(') {
			$ParenthesisDepth = 1
			$Quote = [char]0
			$InAngleDestination = $false
			$SeenDestinationContent = $false
			$Cursor++
			while ($Cursor -lt $Text.Length -and $ParenthesisDepth -gt 0) {
				$Character = $Text[$Cursor]
				if ($Character -eq '\\' -and $Cursor + 1 -lt $Text.Length) { $Cursor += 2; continue }
				if ($InAngleDestination) {
					if ($Character -eq '>') { $InAngleDestination = $false }
					$Cursor++
					continue
				}
				if ($Quote -ne [char]0) {
					if ($Character -eq $Quote) { $Quote = [char]0 }
				}
				elseif (-not $SeenDestinationContent -and [char]::IsWhiteSpace($Character)) { }
				elseif (-not $SeenDestinationContent -and $Character -eq '<') { $SeenDestinationContent = $true; $InAngleDestination = $true }
				elseif ($Character -eq '"' -or $Character -eq "'") { $SeenDestinationContent = $true; $Quote = $Character }
				elseif ($Character -eq '(') { $ParenthesisDepth++ }
				elseif ($Character -eq ')') { $ParenthesisDepth-- }
				else { $SeenDestinationContent = $true }
				$Cursor++
			}
			if ($ParenthesisDepth -ne 0 -or $Quote -ne [char]0 -or $InAngleDestination) {
				$null = $Output.Append($Text.Substring($Index))
				break
			}
			$EndIndex = $Cursor
		}
		elseif ($Cursor -lt $Text.Length -and $Text[$Cursor] -eq '[') {
			$ReferenceEnd = $Cursor + 1
			while ($ReferenceEnd -lt $Text.Length) {
				if ($Text[$ReferenceEnd] -eq '\\' -and $ReferenceEnd + 1 -lt $Text.Length) { $ReferenceEnd += 2; continue }
				if ($Text[$ReferenceEnd] -eq ']') { break }
				$ReferenceEnd++
			}
			if ($ReferenceEnd -ge $Text.Length) {
				$null = $Output.Append($Text.Substring($Index))
				break
			}
			$EndIndex = $ReferenceEnd + 1
		}

		$Label = $Text.Substring($OpenIndex + 1, $CloseIndex - $OpenIndex - 1)
		$null = $Output.Append($Label)
		$Index = $EndIndex
	}
	$Output.ToString()
}

function Test-MarkdownTableDelimiterRow {
	param([Parameter(Mandatory)][AllowEmptyString()][string] $Row, [Parameter(Mandatory)][int] $ExpectedCellCount)
	if ($Row -notmatch '\|') { return $false }
	$Cells = @(Split-MarkdownTableRow -Row $Row.TrimStart())
	if ($Cells.Count -ne $ExpectedCellCount) { return $false }
	foreach ($Cell in $Cells) {
		if ($Cell -cnotmatch '^:?-{3,}:?$') { return $false }
	}
	$true
}

function Test-MarkdownTableDelimiterCandidate {
	# Keep malformed delimiter-shaped rows attached to their header so the
	# caller can emit its precise cell-count/alignment diagnostic. Ordinary
	# pipe prose is not delimiter-shaped and therefore cannot create a header.
	param([Parameter(Mandatory)][AllowEmptyString()][string] $Row)
	if ($Row -notmatch '\|') { return $false }
	$Cells = @(Split-MarkdownTableRow -Row $Row.TrimStart())
	if ($Cells.Count -lt 1) { return $false }
	foreach ($Cell in $Cells) {
		if ($Cell -cnotmatch '^:?-*:?$') { return $false }
	}
	$true
}

function ConvertTo-VisibleCellText {
	# Bounded approximation of the text GitHub shows for one table cell, used
	# only to recognize governance headers. Supported grammar: inline HTML
	# comments; inline, reference, and shortcut links or images (their text);
	# single-line HTML tags; character entities; emphasis, strikethrough, and
	# code delimiters; backslash escapes; zero-width format characters. This is
	# not a Markdown or HTML renderer: anything outside this grammar stays
	# literal, so an unrecognized spelling never matches a header.
	param([Parameter(Mandatory)][AllowEmptyString()][string] $Cell)
	$Text = [regex]::Replace($Cell, '<!--.*?-->', '')
	$Text = [regex]::Replace($Text, (Get-HtmlTagPattern), '')
	# Remove valid tags first so brackets inside quoted attributes cannot stop
	# the bounded Markdown-link scan before it reaches later visible labels.
	$Text = ConvertFrom-MarkdownLinks -Text $Text
	$Text = [System.Net.WebUtility]::HtmlDecode($Text)
	$Text = [regex]::Replace($Text, '\\(.)', '$1')
	$Text = [regex]::Replace($Text, '[*_~`]|\p{Cf}', '')
	([regex]::Replace($Text, '\s+', ' ')).Trim()
}

function Find-TableHeaderIndices {
	# Returns the indices of rows that GitHub renders as a governance header:
	# the identifying cell reads as $FirstColumn, or the row carries every
	# $RequiredColumns name whatever its identifying cell says. Callers require
	# exactly one such row and then check the raw row for the canonical header,
	# so a formatted, renamed, or duplicated governance table fails explicitly.
	param([Parameter(Mandatory)][AllowEmptyString()][string[]] $Lines, [Parameter(Mandatory)][string] $FirstColumn, [string[]] $RequiredColumns = @())
	$Indices = [System.Collections.Generic.List[int]]::new()
	$HtmlTagPattern = '^' + (Get-HtmlTagPattern)
	# Blockquotes and list items are CommonMark containers: GitHub renders a
	# table written inside them, so their markers are stripped before the row is
	# inspected. Only paragraph text may continue a container lazily; a blank
	# line, heading, thematic break, fence, comment block, or new container ends
	# the paragraph, and indented code never interrupts one.
	$BlockquotePattern = '^ {0,3}>'
	$ListMarkerPattern = '^ {0,3}(?:[-+*]|\d{1,9}[.)])(?=[ \t]|$)'
	$HeadingPattern = '^ {0,3}#{1,6}(?:[ \t]|$)'
	$ThematicBreakPattern = '^ {0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$'
	$BlockStartPattern = '^ {0,3}(?:>|(?:[-+*]|\d{1,9}[.)])(?:[ \t]|$)|#{1,6}(?:[ \t]|$)|(?:-[ \t]*){3,}$|(?:\*[ \t]*){3,}$|(?:_[ \t]*){3,}$|`{3,}[^`]*$|~{3,}|<!--)'
	$Containers = [System.Collections.Generic.List[object]]::new()
	$NextContainerIdentity = 0
	$InParagraph = $false
	$FenceCharacter = $null
	$FenceLength = 0
	$InHtmlComment = $false
	$PendingHeader = $null
	for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
		$PreviousHeader = $PendingHeader
		$PendingHeader = $null
		$Rest = $Lines[$Index]
		$Column = 0
		$IsIndentedCodeCandidate = $false

		# Continue the open containers in order: a blockquote needs its marker
		# (plus one optional space); a list item needs its content column, or a
		# blank line.
		$Matched = 0
		foreach ($Container in $Containers) {
			if ($Container.Kind -eq 'quote') {
				if (-not ($Rest -cmatch $BlockquotePattern)) { break }
				$Rest = $Rest.Substring($Matches[0].Length)
				$Column += $Matches[0].Length
				if ((Measure-MarkdownIndent -Text $Rest -StartColumn $Column).Columns -ge 1) {
					$Rest = Remove-MarkdownIndent -Text $Rest -StartColumn $Column -Columns 1
					$Column++
				}
			}
			elseif (-not [string]::IsNullOrWhiteSpace($Rest)) {
				if ((Measure-MarkdownIndent -Text $Rest -StartColumn $Column).Columns -lt $Container.Offset) { break }
				$Rest = Remove-MarkdownIndent -Text $Rest -StartColumn $Column -Columns $Container.Offset
				$Column += $Container.Offset
			}
			$Matched++
		}
		$Lazy = $false
		if ($Matched -lt $Containers.Count) {
			$Lazy = $InParagraph -and -not [string]::IsNullOrWhiteSpace($Rest) -and $Rest -cnotmatch $BlockStartPattern
			if (-not $Lazy) {
				# Unmatched containers close, taking any fence or comment block
				# they contain with them; the line is then read at the outer level.
				$Containers.RemoveRange($Matched, $Containers.Count - $Matched)
				$InParagraph = $false
				$FenceCharacter = $null
				$FenceLength = 0
				$InHtmlComment = $false
			}
		}

		if ($null -ne $FenceCharacter) {
			$ClosingFencePattern = '^[ ]{0,3}' + [regex]::Escape([string]$FenceCharacter) + "{$FenceLength,}[ \t]*$"
			if ($Rest -cmatch $ClosingFencePattern) {
				$FenceCharacter = $null
				$FenceLength = 0
			}
			continue
		}

		if (-not $InHtmlComment -and -not $Lazy) {
			# Open new containers on the remaining text before classifying it.
			while ((Measure-MarkdownIndent -Text $Rest -StartColumn $Column).Columns -lt 4) {
				if ($Rest -cmatch $BlockquotePattern) {
					$NextContainerIdentity++
					$Containers.Add(@{ Kind = 'quote'; Identity = $NextContainerIdentity })
					$Rest = $Rest.Substring($Matches[0].Length)
					$Column += $Matches[0].Length
					if ((Measure-MarkdownIndent -Text $Rest -StartColumn $Column).Columns -ge 1) {
						$Rest = Remove-MarkdownIndent -Text $Rest -StartColumn $Column -Columns 1
						$Column++
					}
					$InParagraph = $false
					continue
				}
				if ($Rest -cmatch $ListMarkerPattern) {
					$Marker = $Matches[0]
					$After = $Rest.Substring($Marker.Length)
					$Spacing = Measure-MarkdownIndent -Text $After -StartColumn ($Column + $Marker.Length)
					# Content begins after one to four spaces; an empty item or five
					# or more spaces leave the remainder indented after a single space.
					$Width = if ([string]::IsNullOrWhiteSpace($After) -or $Spacing.Columns -ge 5) { 1 } else { $Spacing.Columns }
					$NextContainerIdentity++
					$Containers.Add(@{ Kind = 'list'; Offset = $Marker.Length + $Width; Identity = $NextContainerIdentity })
					$Rest = if ([string]::IsNullOrWhiteSpace($After)) { '' } else { Remove-MarkdownIndent -Text $After -StartColumn ($Column + $Marker.Length) -Columns $Width }
					$Column += $Marker.Length + $Width
					$InParagraph = $false
					continue
				}
				break
			}

			if ([string]::IsNullOrWhiteSpace($Rest)) {
				$InParagraph = $false
				continue
			}
			$IsIndentedCodeCandidate = (Measure-MarkdownIndent -Text $Rest -StartColumn $Column).Columns -ge 4
			if ($IsIndentedCodeCandidate) {
				# Four-column indentation is code unless it continues a paragraph.
				if (-not $InParagraph) { continue }
			}
			else {
				if ($Rest -cmatch $HeadingPattern -or $Rest -cmatch $ThematicBreakPattern) {
					$InParagraph = $false
					continue
				}
				$OpeningFence = [regex]::Match($Rest, '^[ ]{0,3}(?<Fence>`{3,})[^`]*$')
				if (-not $OpeningFence.Success) {
					$OpeningFence = [regex]::Match($Rest, '^[ ]{0,3}(?<Fence>~{3,}).*$')
				}
				if ($OpeningFence.Success) {
					$Fence = $OpeningFence.Groups['Fence'].Value
					$FenceCharacter = $Fence[0]
					$FenceLength = $Fence.Length
					$InParagraph = $false
					continue
				}
			}
		}

		# CommonMark comment blocks begin before column four and include the
		# closing line (or all remaining lines when unclosed). Fences/indentation
		# inside comments are literal, just as comment markers inside code are.
		if ($InHtmlComment -or $Rest -cmatch '^[ ]{0,3}<!--') {
			# A closing delimiter may be followed by another comment on this
			# same raw HTML line. Track each transition, including on continued
			# comments' closing lines; openers inside an open comment are literal.
			# The closer may reuse the opener's dashes (`<!-->`, `<!--->`), so the
			# search for `-->` resumes right after `<!`.
			$CommentOffset = 0
			while ($CommentOffset -lt $Rest.Length) {
				$Delimiter = if ($InHtmlComment) { '-->' } else { '<' }
				$DelimiterIndex = $Rest.IndexOf($Delimiter, $CommentOffset, [System.StringComparison]::Ordinal)
				if ($DelimiterIndex -lt 0) { break }
				if ($InHtmlComment) {
					$InHtmlComment = $false
					$CommentOffset = $DelimiterIndex + 3
				}
				elseif ($Rest.Substring($DelimiterIndex).StartsWith('<!--', [System.StringComparison]::Ordinal)) {
					$InHtmlComment = $true
					$CommentOffset = $DelimiterIndex + 2
				}
				else {
					# Skip complete tags as lexical units: comment markers inside
					# single/double-quoted attributes cannot open a comment. This
					# bounded scanner rejects other trailing HTML constructs,
					# including multiline/unterminated tags, rather than guessing.
					$Tag = [regex]::Match($Rest.Substring($DelimiterIndex), $HtmlTagPattern)
					Assert-Condition $Tag.Success "Unsupported trailing HTML construct after a comment on line $($Index + 1); use complete single-line tags or move the construct outside the comment-closing line."
					$CommentOffset = $DelimiterIndex + $Tag.Length
				}
			}
			$InParagraph = $false
			continue
		}

		# A GFM table exists only when its header is immediately followed by a
		# compatible delimiter row in the same rendered container. Validate only
		# after this line's container, lazy-continuation, indentation, fence, and
		# comment classification is known; otherwise a delimiter in another block
		# could incorrectly bless the prior paragraph as a table.
		$ContainerSignature = (($Containers | ForEach-Object {
			"$($_.Kind):$($_.Identity)"
		}) -join '/')
		if ($null -ne $PreviousHeader -and -not $Lazy -and -not $IsIndentedCodeCandidate -and
			[string]::Equals($ContainerSignature, $PreviousHeader.ContainerSignature, [System.StringComparison]::Ordinal) -and
			((Test-MarkdownTableDelimiterRow -Row $Rest -ExpectedCellCount $PreviousHeader.CellCount) -or
			(Test-MarkdownTableDelimiterCandidate -Row $Rest))) {
			$Indices.Add($PreviousHeader.Index)
		}

		# Paragraph or table text. The header is matched on the container-free
		# remainder; callers still re-read the raw line, so a governance table
		# written inside a container fails explicitly instead of being ignored.
		$InParagraph = $true
		if ($Rest -notmatch '\|') { continue }
		$Cells = @(Split-MarkdownTableRow -Row $Rest.TrimStart())
		if ($Cells.Count -lt 2) { continue }
		$VisibleCells = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
		foreach ($Cell in $Cells) { $null = $VisibleCells.Add((ConvertTo-VisibleCellText -Cell $Cell)) }
		$IsHeader = [string]::Equals((ConvertTo-VisibleCellText -Cell $Cells[0]), $FirstColumn, [System.StringComparison]::Ordinal)
		if (-not $IsHeader -and $RequiredColumns.Count -gt 0) {
			$IsHeader = @($RequiredColumns | Where-Object { -not $VisibleCells.Contains($_) }).Count -eq 0
		}
		if ($IsHeader) { $PendingHeader = @{ Index = $Index; CellCount = $Cells.Count; ContainerSignature = $ContainerSignature } }
	}
	@($Indices)
}

function Assert-GovernanceHeader {
	param([Parameter(Mandatory)][AllowEmptyString()][string[]] $HeaderCells, [Parameter(Mandatory)][AllowEmptyString()][string[]] $ExpectedHeader, [Parameter(Mandatory)][string] $Table)
	Assert-Condition ($HeaderCells.Count -eq $ExpectedHeader.Count) "$Table must declare $($ExpectedHeader.Count) columns ('$($ExpectedHeader -join "', '")'); found $($HeaderCells.Count) ('$($HeaderCells -join "', '")'). The five governance states must each keep their own column."
	for ($Index = 0; $Index -lt $ExpectedHeader.Count; $Index++) {
		Assert-Condition ([string]::Equals($HeaderCells[$Index], $ExpectedHeader[$Index], [System.StringComparison]::Ordinal)) "$Table column $($Index + 1) must be '$($ExpectedHeader[$Index])'; found '$($HeaderCells[$Index])'. The five governance states must each keep their own column."
	}
}

function Assert-MarkdownTableSeparator {
	param(
		[Parameter(Mandatory)][AllowEmptyString()][string] $Row,
		[Parameter(Mandatory)][int] $ExpectedCellCount,
		[Parameter(Mandatory)][string] $Table
	)

	$Cells = @(Split-MarkdownTableRow -Row $Row)
	Assert-Condition ($Cells.Count -eq $ExpectedCellCount) "$Table separator row immediately after its header must have exactly $ExpectedCellCount cells; found $($Cells.Count)."
	for ($Index = 0; $Index -lt $Cells.Count; $Index++) {
		Assert-Condition ($Cells[$Index] -cmatch '^:?-{3,}:?$') "$Table separator row immediately after its header has invalid cell $($Index + 1) '$($Cells[$Index])'; expected at least three hyphens with optional alignment colons."
	}
}

# Provenance/custody, authorship, permission, license, and product approval are
# five independent states. The expected whole tuple is selected by an explicit
# manifested-path contract, never by values asserted in the register or report.
function Assert-GovernanceStates {
	param(
		[Parameter(Mandatory)][string] $Label,
		[Parameter(Mandatory)][AllowEmptyString()][string[]] $Values,
		[Parameter(Mandatory)][string] $Table,
		[Parameter(Mandatory)] $Contract,
		[switch] $AllowEquivalentWording
	)
	Assert-Condition ($Values.Count -eq $GovernanceFields.Count) "$Table row for $Label exposes $($Values.Count) governance states; expected $($GovernanceFields.Count) ($($GovernanceFields -join ', ')). Governance states must not be collapsed or omitted."
	for ($Index = 0; $Index -lt $GovernanceFields.Count; $Index++) {
		$Field = $GovernanceFields[$Index]
		$Value = $Values[$Index]
		Assert-Condition (-not [string]::IsNullOrWhiteSpace($Value)) "Governance state '$Field' is blank for $Label in $Table; record the known value, or record '**Pending/TBD**' when it is unknown."
		$ExpectedValue = [string]$Contract.States[$Field]
		$MatchesExpected = [string]::Equals($Value, $ExpectedValue, [System.StringComparison]::Ordinal)
		if ($AllowEquivalentWording) {
			$NormalizedValue = ConvertTo-NormalizedGovernanceValue -Field $Field -Value $Value
			$NormalizedExpectedValue = ConvertTo-NormalizedGovernanceValue -Field $Field -Value $ExpectedValue
			$MatchesExpected = [string]::Equals($NormalizedValue, $NormalizedExpectedValue, [System.StringComparison]::Ordinal)
		}
		Assert-Condition $MatchesExpected "Governance state '$Field' has unrecognized value for $Label in ${Table}: '$Value'. It does not match source class '$($Contract.Name)' expected value '$ExpectedValue'. Update the explicit path/source-class contract only after governance review."
	}
}

function ConvertTo-NormalizedGovernanceValue {
	param(
		[Parameter(Mandatory)][string] $Field,
		[Parameter(Mandatory)][string] $Value
	)

	$Normalized = $Value.ToLowerInvariant()
	$Normalized = $Normalized.Replace($MojibakeEmDash, ' ')
	$Normalized = $Normalized -replace '\*', ''
	$Normalized = $Normalized -replace '[\p{Pd}:;.]', ' '
	if ($Field -eq 'Authorship') {
		$Normalized = $Normalized -replace '\bfor the legacy package\b', ''
	}
	elseif ($Field -eq 'Permission' -or $Field -eq 'License') {
		$Normalized = $Normalized -replace '\bin this repository\b', ''
	}
	elseif ($Field -eq 'Product approval') {
		$Normalized = $Normalized -replace '\bapproval is recorded\b', 'approval recorded'
		$Normalized = $Normalized -replace '\bnon canonical reference/source asset\b', ''
	}
	($Normalized -replace '\s+', ' ').Trim()
}

function Assert-AllowedCurrentUse {
	param(
		[Parameter(Mandatory)][string] $Label,
		[Parameter(Mandatory)][AllowEmptyString()][string] $Value,
		[Parameter(Mandatory)][AllowEmptyString()][string] $ProductApproval,
		[Parameter(Mandatory)][string] $Table
	)

	$NormalizedProductApproval = ConvertTo-NormalizedGovernanceValue -Field 'Product approval' -Value $ProductApproval
	if ($NormalizedProductApproval -match '^not approved\b') {
		Assert-Condition (Test-OrdinalStringCollectionContains -Values $AcceptedNotApprovedAllowedCurrentUseValues -Value $Value) "Field 'Allowed current use' is contradictory for reviewed asset $Label in ${Table}: '$Value'. Product approval is Not approved, so allowed use must remain one of the reviewed bounded non-production values."
	}
}

function Get-JsonDepth {
	param($Value, [int] $Depth = 1)
	if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return $Depth }
	$Depths = @($Depth)
	if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [System.Management.Automation.PSCustomObject]) {
		foreach ($Item in $Value) { $Depths += Get-JsonDepth -Value $Item -Depth ($Depth + 1) }
	}
	else {
		foreach ($Property in $Value.PSObject.Properties) { $Depths += Get-JsonDepth -Value $Property.Value -Depth ($Depth + 1) }
	}
	($Depths | Measure-Object -Maximum).Maximum
}

function Test-Png {
	param([Parameter(Mandatory)][string] $Path)
	$Bytes = [System.IO.File]::ReadAllBytes($Path)
	Assert-Condition ($Bytes.Length -ge 24) "PNG is truncated: $(Get-RelativeVisualPath $Path)"
	$Signature = '89504e470d0a1a0a'
	$ActualSignature = [BitConverter]::ToString($Bytes[0..7]).Replace('-', '').ToLowerInvariant()
	Assert-Condition ($ActualSignature -eq $Signature) "Invalid PNG signature: $(Get-RelativeVisualPath $Path)"
	$Width = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($Bytes, 16))
	$Height = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($Bytes, 20))
	$HasC2pa = $false
	for ($Offset = 8; $Offset + 12 -le $Bytes.Length;) {
		$Length = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($Bytes, $Offset))
		Assert-Condition ($Length -ge 0 -and $Offset + 12 + $Length -le $Bytes.Length) "Invalid PNG chunk bounds: $(Get-RelativeVisualPath $Path)"
		$ChunkType = [System.Text.Encoding]::ASCII.GetString($Bytes, $Offset + 4, 4)
		if ($ChunkType -eq 'caBX') { $HasC2pa = $true }
		$Offset += 12 + $Length
		if ($ChunkType -eq 'IEND') { break }
	}
	@{ Width = $Width; Height = $Height; HasC2pa = $HasC2pa }
}

Assert-Condition (Test-Path -LiteralPath $ManifestPath -PathType Leaf) "Manifest is missing: $ManifestPath"
Assert-Condition (Test-Path -LiteralPath $ProvenancePath -PathType Leaf) "Provenance is missing: $ProvenancePath"
Assert-Condition (Test-Path -LiteralPath $PromptPath -PathType Leaf) "Generation prompts are missing: $PromptPath"
$Manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
Assert-Condition ($Manifest.schemaVersion -eq 1) 'Manifest schemaVersion must be 1.'
Assert-Condition ($Manifest.packageStatus -eq 'non-canonical') 'Manifest packageStatus must be non-canonical.'
Assert-Condition ($Manifest.expectedAssetCount -eq $RequiredAssetCount) "Manifest expectedAssetCount must be $RequiredAssetCount."
Assert-Condition ($Manifest.expectedTotalFileCount -eq $RequiredTotalFileCount) "Manifest expectedTotalFileCount must be $RequiredTotalFileCount."
Assert-Condition (@($Manifest.assets).Count -eq $Manifest.expectedAssetCount) 'Manifest asset count does not match expectedAssetCount.'

$ManifestPaths = @($Manifest.assets | ForEach-Object { [string]$_.path })
$HasIssue95Report = Test-OrdinalStringCollectionContains -Values $ManifestPaths -Value 'issue-95-opening-screen-commonui-validation.md'
$ManifestPathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($RelativePath in $ManifestPaths) {
	Assert-Condition ($ManifestPathSet.Add($RelativePath)) "Manifest contains duplicate path: $RelativePath"
	Assert-Condition ($RelativePath -notmatch '^[A-Za-z]:[/\\]' -and $RelativePath -notmatch '^[/\\]' -and $RelativePath -notmatch '(^|/)\.\.(/|$)' -and $RelativePath -notmatch '\\') "Manifest paths must be normalized relative paths: $RelativePath"
}

$GovernanceContractByManifestPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
foreach ($RelativePath in $ManifestPaths) {
	Assert-Condition ($GovernanceSourceClassByPath.ContainsKey($RelativePath)) "Manifest path '$RelativePath' does not resolve to a reviewed governance source class. Unknown, new, or reclassified paths require an explicit path/source-class contract and governance review."
	$GovernanceContractByManifestPath.Add($RelativePath, $GovernanceSourceClassByPath[$RelativePath])
}

$ActualAssetPaths = @(Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object { Get-RelativeVisualPath $_.FullName } | Where-Object { -not (Test-OrdinalStringCollectionContains -Values $GovernancePaths -Value $_) })
$MissingAssetPaths = @($ManifestPaths | Where-Object { -not (Test-OrdinalStringCollectionContains -Values $ActualAssetPaths -Value $_) })
$UnexpectedAssetPaths = @($ActualAssetPaths | Where-Object { -not (Test-OrdinalStringCollectionContains -Values $ManifestPaths -Value $_) })
Assert-Condition ($MissingAssetPaths.Count -eq 0 -and $UnexpectedAssetPaths.Count -eq 0 -and $ActualAssetPaths.Count -eq $ManifestPaths.Count) "Package inventory differs from the manifest inventory. Missing: $($MissingAssetPaths -join ', '); unexpected: $($UnexpectedAssetPaths -join ', ')."
$ActualTotal = @(Get-ChildItem -LiteralPath $Root -Recurse -File).Count
Assert-Condition ($ActualTotal -eq $Manifest.expectedTotalFileCount) "Package contains $ActualTotal files; expected $($Manifest.expectedTotalFileCount)."
if ($HasIssue95Report) {
	Assert-Condition (Test-Path -LiteralPath $Issue95ReportPath -PathType Leaf) "Issue #95 report is missing: $Issue95ReportPath"
}

$C2paCount = 0
foreach ($Entry in $Manifest.assets) {
	$RelativePath = [string]$Entry.path
	$Path = Join-Path $Root ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
	$Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
	Assert-Condition ($Hash -eq [string]$Entry.sha256) "SHA-256 mismatch: $RelativePath"
	$Length = (Get-Item -LiteralPath $Path).Length
	Assert-Condition ($Length -eq [long]$Entry.bytes) "Byte-length mismatch: $RelativePath"
	if ([System.IO.Path]::GetExtension($Path) -ieq '.png') {
		$Png = Test-Png -Path $Path
		Assert-Condition ($Png.Width -eq [int]$Entry.width -and $Png.Height -eq [int]$Entry.height) "PNG dimensions mismatch: $RelativePath"
		Assert-Condition ($Png.Width -le 8192 -and $Png.Height -le 8192 -and $Length -le 32MB) "PNG exceeds metadata ceilings: $RelativePath"
		Assert-Condition ($Png.HasC2pa -eq [bool]$Entry.c2pa) "C2PA caBX presence mismatch: $RelativePath"
		if ($Png.HasC2pa) { $C2paCount++ }
	}
}
Assert-Condition ($C2paCount -eq [int]$Manifest.expectedC2paPngCount) "C2PA PNG count is $C2paCount; expected $($Manifest.expectedC2paPngCount)."

foreach ($Pair in $Manifest.mirrorPairs) {
	$Left = Join-Path $Root ([string]$Pair.left -replace '/', [System.IO.Path]::DirectorySeparatorChar)
	$Right = Join-Path $Root ([string]$Pair.right -replace '/', [System.IO.Path]::DirectorySeparatorChar)
	Assert-Condition ((Get-FileHash -LiteralPath $Left -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $Right -Algorithm SHA256).Hash) "Mirror pair differs: $($Pair.left), $($Pair.right)"
}

$TextFiles = Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object Extension -in @('.md', '.json', '.svg', '.ps1')
foreach ($File in $TextFiles) {
	$Bytes = [System.IO.File]::ReadAllBytes($File.FullName)
	$Text = [System.Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
	Assert-Condition ($Text -notmatch "`r(?!`n)") "Invalid bare CR newline: $(Get-RelativeVisualPath $File.FullName)"
	$WithoutCrLf = $Text.Replace("`r`n", '')
	Assert-Condition (-not ($Text.Contains("`r`n") -and $WithoutCrLf.Contains("`n"))) "Mixed newline styles: $(Get-RelativeVisualPath $File.FullName)"
	Assert-Condition ($Text -notmatch $MachinePathPattern) "Machine-specific path found: $(Get-RelativeVisualPath $File.FullName)"
}

foreach ($Markdown in $TextFiles | Where-Object Extension -eq '.md') {
	$Text = Get-Content -Raw -LiteralPath $Markdown.FullName
	foreach ($Match in [regex]::Matches($Text, '!?(?:\[[^\]]*\])\(([^)]+)\)')) {
		$Target = $Match.Groups[1].Value.Trim().Trim('<', '>')
		if ($Target -match '^(?:https?:|mailto:|#)') { continue }
		$Target = [uri]::UnescapeDataString(($Target -split '#')[0])
		if (-not $Target) { continue }
		$Resolved = Join-Path $Markdown.DirectoryName ($Target -replace '/', [System.IO.Path]::DirectorySeparatorChar)
		Assert-Condition (Test-Path -LiteralPath $Resolved) "Broken Markdown link in $(Get-RelativeVisualPath $Markdown.FullName): $Target"
	}
}

foreach ($Json in $TextFiles | Where-Object Extension -eq '.json') {
	$Object = Get-Content -Raw -LiteralPath $Json.FullName | ConvertFrom-Json
	Assert-Condition ((Get-JsonDepth -Value $Object) -le 32) "JSON depth exceeds 32: $(Get-RelativeVisualPath $Json.FullName)"
}
foreach ($Svg in $TextFiles | Where-Object Extension -eq '.svg') {
	[xml]$Xml = Get-Content -Raw -LiteralPath $Svg.FullName
	foreach ($Node in $Xml.SelectNodes('//*[@href or @*[local-name()="href"]]')) {
		$Href = $Node.GetAttribute('href')
		if (-not $Href) { $Href = $Node.GetAttribute('href', 'http://www.w3.org/1999/xlink') }
		if ($Href -and $Href -notmatch '^(?:#|data:|https?:)') {
			$Resolved = Join-Path $Svg.DirectoryName ($Href -replace '/', [System.IO.Path]::DirectorySeparatorChar)
			Assert-Condition (Test-Path -LiteralPath $Resolved) "Broken SVG reference in $(Get-RelativeVisualPath $Svg.FullName): $Href"
		}
	}
}

$ParserErrors = @()
foreach ($Script in $TextFiles | Where-Object Extension -eq '.ps1') {
	$Tokens = $null
	$Errors = $null
	$null = [System.Management.Automation.Language.Parser]::ParseFile($Script.FullName, [ref]$Tokens, [ref]$Errors)
	if (@($Errors).Count -gt 0) { $ParserErrors += @($Errors | ForEach-Object { "$(Get-RelativeVisualPath $Script.FullName): $($_.Message)" }) }
}
Assert-Condition (@($ParserErrors).Count -eq 0) "PowerShell syntax errors: $($ParserErrors -join '; ')"

$Provenance = Get-Content -Raw -LiteralPath $ProvenancePath
foreach ($RelativePath in $ManifestPaths) {
	Assert-Condition ($Provenance.Contains("``$RelativePath``")) "Provenance coverage missing: $RelativePath"
}
foreach ($Required in @(
	'Permission, license, and approval evidence by source class',
	'Owner-supplied legacy package',
	'Owner-directed issue #114 generation',
	'Repository-hardened text derivatives',
	'Pending/TBD',
	'No row in this register grants public distribution'
)) {
	Assert-Condition ($Provenance.Contains($Required)) "Provenance permission coverage missing: $Required"
}

# Every manifested asset must record all five governance states in its own
# column so no state is inferred from, collapsed into, or omitted alongside
# another.
$ProvenanceLines = @($Provenance -split "`r?`n")
$RegisterTable = 'Per-asset governance table in asset-provenance.md'
$RegisterHeaderIndices = @(Find-TableHeaderIndices -Lines $ProvenanceLines -FirstColumn 'Path' -RequiredColumns $GovernanceFields)
Assert-Condition ($RegisterHeaderIndices.Count -eq 1) "$RegisterTable must declare exactly one applicable header; found $($RegisterHeaderIndices.Count). Expected one header row starting with '| Path |'."
$RegisterHeaderIndex = $RegisterHeaderIndices[0]

$RegisterHeader = @('Path') + $GovernanceFields
Assert-GovernanceHeader -HeaderCells (Split-MarkdownTableRow -Row $ProvenanceLines[$RegisterHeaderIndex]) -ExpectedHeader $RegisterHeader -Table $RegisterTable
$RegisterSeparatorIndex = $RegisterHeaderIndex + 1
Assert-Condition ($RegisterSeparatorIndex -lt $ProvenanceLines.Count) "$RegisterTable separator row immediately after its header is missing."
Assert-MarkdownTableSeparator -Row $ProvenanceLines[$RegisterSeparatorIndex] -ExpectedCellCount $RegisterHeader.Count -Table $RegisterTable

$GovernanceRows = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
$RegisterDataLines = @()
if ($RegisterSeparatorIndex + 1 -lt $ProvenanceLines.Count) {
	$RegisterDataLines = @($ProvenanceLines[($RegisterSeparatorIndex + 1)..($ProvenanceLines.Count - 1)])
}
foreach ($Line in $RegisterDataLines) {
	$Trimmed = $Line.Trim()
	if ([string]::IsNullOrWhiteSpace($Trimmed) -or $Line -notmatch '\|') { break }
	$Cells = Split-MarkdownTableRow -Row $Line
	$PathCell = $Cells[0]
	Assert-Condition ($PathCell -cmatch '^`([^`]+)`$') "Malformed per-asset governance path cell in asset-provenance.md: expected a single backtick-wrapped path; found '$PathCell'."
	$RowPath = $Matches[1]
	Assert-Condition (-not $GovernanceRows.ContainsKey($RowPath)) "Duplicate per-asset governance row: $RowPath"
	$GovernanceRows.Add($RowPath, $Cells)
}

foreach ($RowPath in $GovernanceRows.Keys) {
	Assert-Condition (Test-OrdinalStringCollectionContains -Values $ManifestPaths -Value $RowPath) "Unexpected per-asset governance row: $RowPath is not listed in package-manifest.json."
}

foreach ($RelativePath in $ManifestPaths) {
	Assert-Condition ($GovernanceRows.ContainsKey($RelativePath)) "Per-asset governance row missing for ${RelativePath}: every manifested asset must record $($GovernanceFields -join ', ') independently."
	$Cells = $GovernanceRows[$RelativePath]
	Assert-Condition ($Cells.Count -eq $RegisterHeader.Count) "$RegisterTable row for $RelativePath has $($Cells.Count) cells; expected $($RegisterHeader.Count) (Path plus $($GovernanceFields -join ', ')). Governance states must not be collapsed or omitted."
	Assert-GovernanceStates -Label $RelativePath -Values $Cells[1..($Cells.Count - 1)] -Table $RegisterTable -Contract $GovernanceContractByManifestPath[$RelativePath]
}

if (Test-OrdinalStringCollectionContains -Values $ManifestPaths -Value 'README.md') {
	$ReadmeGovernanceValues = $GovernanceRows['README.md'][1..($RegisterHeader.Count - 1)]
	Assert-Condition ([string]::Equals($ReadmeGovernanceValues[0], $ReadmeExpectedProvenance, [System.StringComparison]::Ordinal)) "Governance state 'Provenance/custody' for README.md must record repository modifications under issues #94 and #95; found '$($ReadmeGovernanceValues[0])'."
	Assert-Condition ([string]::Equals($ReadmeGovernanceValues[1], $ReadmeExpectedAuthorship, [System.StringComparison]::Ordinal)) "Governance state 'Authorship' for README.md must record repository modifications under issues #94 and #95; found '$($ReadmeGovernanceValues[1])'."
}

if ($HasIssue95Report) {
	$Issue95Report = Get-Content -Raw -LiteralPath $Issue95ReportPath
	foreach ($Required in @(
	'# Issue #95 Opening-Screen Visual Review and CommonUI Plan',
	'## Opening-screen assessment',
	'Legibility and contrast',
	'Focus order and keyboard/controller navigation',
	'Safe zones and localization expansion',
	'Ultrawide and scalable layout',
	'## Per-asset classification',
	'Visual suitability',
	'Allowed current use',
	'Reference-only',
	'Potential internal prototype',
	'Replacement/clearance required',
	'Provenance/custody, authorship, permission, license, and product approval are',
	'five independent states',
	'Provenance/custody is **known**',
	'Product approval is a recorded negative',
	'each independently prohibit production',
	'packageStatus: non-canonical',
	'## Issue #3 minimal entry contract',
	'## Issue #53 later editor contract',
	'Identity, race, sex, appearance, class/Skein, faction/Doctrine',
	'class/Skein, faction/Doctrine, permanent',
	'Character Level, seasonal Ember Rank, inventory/equipment, cosmetics',
	'its `LEVEL 1` display conflicts with the 1.0 slice',
	'Character Level begins in 1.1/#50',
	'Levels 1-3 are excluded from 1.0',
	'Remove or replace that level display for 1.0',
	'`LEAVE` the orange keyboard/controller focus treatment',
	'`CANCEL` remains visually normal',
	'destructive initial focus or default is unsafe',
	'initial focus and default action must both be non-destructive',
	'session state remain separate data concerns',
	'Race, sex, and appearance never alter statistics',
	'hitboxes, reach, timing, collision, traces, or loot probability',
	'Faction = Unassigned',
	'Doctrine selection',
	'W_RootLayout',
	'Game layer',
	'Menu layer',
	'Modal layer',
	'Notification layer',
	'Loading layer',
	'Full-viewport presentation container',
	"scrim → ``SafeZone`` → responsive scale/container",
	'focus',
	'Accept',
	'Back',
	'1280×720',
	'1920×1080',
	'2560×1440',
	'3440×1440',
	'3840×2160',
	'## Testable acceptance checklist',
	'## Blockers and unresolved TBD decisions'
	)) {
		Assert-Condition ($Issue95Report.Contains($Required)) "Issue #95 report contract missing: $Required"
	}
	foreach ($StalePattern in @(
		'(?i)the one supported initial class once canonically selected',
		'(?i)exact (?:supported )?initial class[^.\r\n]*remain(?:s)? TBD'
	)) {
		Assert-Condition ($Issue95Report -notmatch $StalePattern) "Issue #95 report contains stale initial Order/class wording matching '$StalePattern'; Oathscar (`order.oathscar`) is the active initial Order working label."
	}
	$NormalizedIssue95Report = ($Issue95Report -replace '\s+', ' ').Trim()
	foreach ($CurrentInitialOrderContract in @(
		'Oathscar (`order.oathscar`) is the active initial Order/class working label',
		'The Oathscar display name remains working and non-final'
	)) {
		Assert-Condition ($NormalizedIssue95Report.Contains($CurrentInitialOrderContract)) "Issue #95 report current initial Order/class contract missing: $CurrentInitialOrderContract"
	}
	foreach ($Screen in @(
	'Main menu',
	'Character roster/selection',
	'Minimal character entry (#3)',
	'Settings',
	'Accessibility',
	'Dialog/tooltip and errors',
	'Loading'
	)) {
		Assert-Condition ($Issue95Report.Contains("| $Screen |")) "Issue #95 screen assessment missing: $Screen"
	}

	# The per-asset classification table must keep visual suitability and allowed
	# current use separate from the five governance states, and must record each
	# governance state independently for every reviewed asset.
	$ReportLines = @($Issue95Report -split "`r?`n")
	$ReportTable = 'Per-asset classification table in issue-95-opening-screen-commonui-validation.md'
	$ReportHeaderIndices = @(Find-TableHeaderIndices -Lines $ReportLines -FirstColumn 'Reviewed asset' -RequiredColumns $GovernanceFields)
	Assert-Condition ($ReportHeaderIndices.Count -eq 1) "$ReportTable must declare exactly one applicable header; found $($ReportHeaderIndices.Count). Expected one header row starting with '| Reviewed asset |'."
	$ReportHeaderIndex = $ReportHeaderIndices[0]

	$ReportHeader = @('Reviewed asset', 'Visual suitability') + $GovernanceFields + @('Allowed current use')
	Assert-GovernanceHeader -HeaderCells (Split-MarkdownTableRow -Row $ReportLines[$ReportHeaderIndex]) -ExpectedHeader $ReportHeader -Table $ReportTable
	$ReportSeparatorIndex = $ReportHeaderIndex + 1
	Assert-Condition ($ReportSeparatorIndex -lt $ReportLines.Count) "$ReportTable separator row immediately after its header is missing."
	Assert-MarkdownTableSeparator -Row $ReportLines[$ReportSeparatorIndex] -ExpectedCellCount $ReportHeader.Count -Table $ReportTable

	$RequiredReviewedAssetRecordDefinitions = [ordered]@{
		'`01-main-menu-concept.png`' = @('01-main-menu-concept.png')
		'`02-playable-peoples-lineup.png`' = @('02-playable-peoples-lineup.png')
		'`03-aurin-bulwark-equipment.png`' = @('03-aurin-bulwark-equipment.png')
		'`04-branmark-settlement.png`' = @('04-branmark-settlement.png')
		'`05-glasswake-reach.png`' = @('05-glasswake-reach.png')
		'`06-character-selection-concept.png`' = @('06-character-selection-concept.png')
		'`07-ui-style-system.png`' = @('07-ui-style-system.png')
		'`ui-production/screens/main-menu.svg`' = @('ui-production/screens/main-menu.svg')
		'`ui-production/screens/character-selection.svg`' = @('ui-production/screens/character-selection.svg')
		'`ui-production/screens/accessibility.svg`' = @('ui-production/screens/accessibility.svg')
		'`ui-production/screens/settings.svg`' = @('ui-production/screens/settings.svg')
		'`main-menu-v2-preview.png`' = @('ui-production-v2/previews/main-menu-v2-preview.png')
		'`character-selection-v2-preview.png`' = @('ui-production-v2/previews/character-selection-v2-preview.png')
		'`accessibility-v2-preview.png`' = @('ui-production-v2/previews/accessibility-v2-preview.png')
		'`settings-v2-preview.png`' = @('ui-production-v2/previews/settings-v2-preview.png')
		'Dialog/tooltip V2 preview' = @('ui-production-v2/previews/dialog-tooltip-v2-preview.png')
		'`loading-v2-preview.png`' = @('ui-production-v2/previews/loading-v2-preview.png')
		'Menu/selection backgrounds' = @('ui-production-v2/assets/main-menu-background.png', 'ui-production-v2/assets/character-selection-stage.png')
		'Logo/wordmark' = @('ui-production-v2/assets/logo.png')
		'Normal, hover, focused, pressed, and disabled buttons' = @('ui-production-v2/assets/button-normal.png', 'ui-production-v2/assets/button-hover.png', 'ui-production-v2/assets/button-focused.png', 'ui-production-v2/assets/button-disabled.png')
		'Panel and selection-card frame' = @('ui-production-v2/assets/panel-large.png', 'ui-production-v2/assets/selection-card-frame.png')
		'Loading indicator, slider, and toggles' = @('ui-production-v2/assets/loading-indicator.png', 'ui-production-v2/assets/slider-cyan-65.png', 'ui-production-v2/assets/toggle-off.png', 'ui-production-v2/assets/toggle-on.png')
		'Kell selection render' = @('ui-production-v2/assets/kell-female-selection.png')
	}
	$RequiredReviewedAssetRecords = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
	foreach ($Definition in $RequiredReviewedAssetRecordDefinitions.GetEnumerator()) {
		$RequiredReviewedAssetRecords.Add([string]$Definition.Key, $Definition.Value)
	}
	$ReviewedAssetRows = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
	$ReportDataLines = @()
	if ($ReportSeparatorIndex + 1 -lt $ReportLines.Count) {
		$ReportDataLines = @($ReportLines[($ReportSeparatorIndex + 1)..($ReportLines.Count - 1)])
	}
	foreach ($Line in $ReportDataLines) {
		$Trimmed = $Line.Trim()
		if ([string]::IsNullOrWhiteSpace($Trimmed) -or $Line -notmatch '\|') { break }
		$Cells = Split-MarkdownTableRow -Row $Line
		$Label = $Cells[0]
		Assert-Condition (-not [string]::IsNullOrWhiteSpace($Label)) "$ReportTable contains a row with no reviewed-asset name: $Trimmed"
		Assert-Condition ($RequiredReviewedAssetRecords.Contains($Label)) "Unexpected reviewed-asset record in ${ReportTable}: $Label"
		Assert-Condition (-not $ReviewedAssetRows.ContainsKey($Label)) "Duplicate reviewed-asset record in ${ReportTable}: $Label"
		Assert-Condition ($Cells.Count -eq $ReportHeader.Count) "$ReportTable row for $Label has $($Cells.Count) cells; expected $($ReportHeader.Count) ($($ReportHeader -join ', ')). Governance states must not be collapsed or omitted."
		Assert-Condition (-not [string]::IsNullOrWhiteSpace($Cells[1])) "Visual suitability is blank for $Label in $ReportTable."
		Assert-Condition (-not [string]::IsNullOrWhiteSpace($Cells[$ReportHeader.Count - 1])) "Allowed current use is blank for $Label in $ReportTable."
		Assert-AllowedCurrentUse -Label $Label -Value $Cells[$Cells.Count - 1] -ProductApproval $Cells[$Cells.Count - 2] -Table $ReportTable
		$ReviewedAssetRows.Add($Label, $Cells)
	}
	foreach ($Label in $RequiredReviewedAssetRecords.Keys) {
		Assert-Condition ($ReviewedAssetRows.ContainsKey($Label)) "Required reviewed-asset record missing from ${ReportTable}: $Label"
		$ReportGovernanceValues = $ReviewedAssetRows[$Label][2..($ReportHeader.Count - 2)]
		foreach ($RegisterPath in @($RequiredReviewedAssetRecords[$Label])) {
			Assert-Condition ($GovernanceRows.ContainsKey($RegisterPath)) "Provenance register row missing for reviewed asset ${Label}: $RegisterPath"
			Assert-Condition ($GovernanceContractByManifestPath.ContainsKey($RegisterPath)) "Reviewed asset $Label references unclassified manifest path ${RegisterPath}."
			Assert-GovernanceStates -Label $Label -Values $ReportGovernanceValues -Table $ReportTable -Contract $GovernanceContractByManifestPath[$RegisterPath] -AllowEquivalentWording
			$RegisterGovernanceValues = $GovernanceRows[$RegisterPath][1..($RegisterHeader.Count - 1)]
			for ($Index = 0; $Index -lt $GovernanceFields.Count; $Index++) {
				$Field = $GovernanceFields[$Index]
				$ReportValue = ConvertTo-NormalizedGovernanceValue -Field $Field -Value $ReportGovernanceValues[$Index]
				$RegisterValue = ConvertTo-NormalizedGovernanceValue -Field $Field -Value $RegisterGovernanceValues[$Index]
				Assert-Condition ($ReportValue -eq $RegisterValue) "Governance state '$Field' mismatch for reviewed asset $Label against register path ${RegisterPath}: report '$($ReportGovernanceValues[$Index])'; register '$($RegisterGovernanceValues[$Index])'."
			}
		}
	}
}

$Prompts = Get-Content -Raw -LiteralPath $PromptPath
$PromptContracts = [ordered]@{
	'## 08 - Overall Mood Key' = @('01-overall-mood-key.png', 'negative space')
	'## 09 - Aurin Playable Study' = @('02-aurin-playable-study.png', 'recognizably human')
	'## 10 - Kell Playable Study' = @('03-kell-playable-study.png', 'visibly muscular', 'strongly non-human')
	'## 11 - Vesh Playable Study' = @('04-vesh-playable-study.png', 'no hood', 'matte-white angular full-face', 'eyes of light')
	'## 12 - Oathscar Combat Sheet' = @('05-oathscar-combat-sheet.png', 'Oathbreak')
	'## 13 - Nullwright Combat Sheet' = @('06-nullwright-combat-sheet.png', 'Contradiction')
	'## 14 - Hushblade Combat Sheet' = @('07-hushblade-combat-sheet.png', 'Missing Second')
	'## 15 - Gravecant Combat Sheet' = @('08-gravecant-combat-sheet.png', 'remove all readable text')
	'## 16 - Blackfletch Combat Sheet' = @('09-blackfletch-combat-sheet.png', 'remove all readable text', 'target lock')
	'## 17 - Combat Readability Scene' = @('10-combat-readability-scene.png', 'white dashed circular', 'golden directional block plane', 'red hostile wedge')
}
foreach ($Heading in $PromptContracts.Keys) {
	Assert-Condition ($Prompts.Contains($Heading)) "Generation prompt coverage missing: $Heading"
	foreach ($Required in $PromptContracts[$Heading]) {
		Assert-Condition ($Prompts.Contains($Required)) "Generation prompt detail missing for ${Heading}: $Required"
	}
}

Write-Host "Visual package validation passed: $ActualTotal files, $(@($Manifest.assets).Count) manifested assets, $C2paCount C2PA PNGs."
