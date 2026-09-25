[CmdletBinding()]
param([switch] $CommentTagGrammarOnly)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$VisualRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Validator = Join-Path $VisualRoot 'Test-VisualPackage.ps1'

function Assert-Throws {
	param(
		[Parameter(Mandatory)][scriptblock] $Action,
		[Parameter(Mandatory)][string] $Pattern
	)

	try {
		& $Action
	}
	catch {
		if ($_.Exception.Message -notmatch $Pattern) {
			throw "Expected failure matching '$Pattern', got: $($_.Exception.Message)"
		}
		return
	}
	throw "Expected failure matching '$Pattern', but the action succeeded."
}

function Split-GfmFixtureRow {
	param([Parameter(Mandatory)][string] $Row)

	$Trimmed = $Row.Trim()
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

function Set-MarkdownTableCell {
	param(
		[Parameter(Mandatory)][string] $Row,
		[Parameter(Mandatory)][int] $Index,
		[Parameter(Mandatory)][AllowEmptyString()][string] $Value
	)

	$Cells = @(Split-GfmFixtureRow -Row $Row)
	if ($Index -lt 0 -or $Index -ge $Cells.Count) {
		throw "Markdown table fixture cell index $Index is outside the $($Cells.Count)-cell row."
	}
	$Cells[$Index] = $Value
	$SerializedCells = @($Cells | ForEach-Object { $_ -replace '(?<!\\)\|', '\|' })
	'| ' + ($SerializedCells -join ' | ') + ' |'
}

function Copy-MarkdownTableCells {
	param(
		[Parameter(Mandatory)][string] $TargetRow,
		[Parameter(Mandatory)][int] $TargetStartIndex,
		[Parameter(Mandatory)][string] $SourceRow,
		[Parameter(Mandatory)][int] $SourceStartIndex,
		[Parameter(Mandatory)][int] $Count
	)

	$SourceCells = @(Split-GfmFixtureRow -Row $SourceRow)
	$Result = $TargetRow
	for ($Offset = 0; $Offset -lt $Count; $Offset++) {
		$Result = Set-MarkdownTableCell -Row $Result -Index ($TargetStartIndex + $Offset) -Value $SourceCells[$SourceStartIndex + $Offset]
	}
	$Result
}

function Get-ProvenanceRow {
	param(
		[Parameter(Mandatory)][string] $Content,
		[Parameter(Mandatory)][string] $Path
	)

	$Pattern = '(?m)^\| `' + [regex]::Escape($Path) + '` \|.*$'
	$Match = [regex]::Match($Content, $Pattern)
	if (-not $Match.Success) { throw "Provenance fixture row is missing for $Path." }
	$Match.Value
}

function Set-GfmTableRowEdges {
	param(
		[Parameter(Mandatory)][string] $Row,
		[Parameter(Mandatory)][bool] $LeadingPipe,
		[Parameter(Mandatory)][bool] $TrailingPipe,
		[ValidateRange(0, 3)][int] $Indent = 0
	)

	$Content = $Row.Trim()
	if ($Content.StartsWith('|')) { $Content = $Content.Substring(1) }
	if ($Content.EndsWith('|')) { $Content = $Content.Substring(0, $Content.Length - 1) }
	$Content = $Content.Trim()
	(' ' * $Indent) + $(if ($LeadingPipe) { '| ' } else { '' }) + $Content + $(if ($TrailingPipe) { ' |' } else { '' })
}

function Convert-GfmTableBlock {
	param(
		[Parameter(Mandatory)][string] $Content,
		[Parameter(Mandatory)][string] $Header,
		[Parameter(Mandatory)][string] $NewLine,
		[Parameter(Mandatory)][hashtable[]] $Styles,
		[Parameter(Mandatory)][string] $AlignedSeparator
	)

	$Start = $Content.IndexOf($Header, [System.StringComparison]::Ordinal)
	if ($Start -lt 0) { throw "GFM fixture header not found: $Header" }
	$End = $Content.IndexOf("$NewLine$NewLine", $Start, [System.StringComparison]::Ordinal)
	if ($End -lt 0) { $End = $Content.Length }
	$Block = $Content.Substring($Start, $End - $Start)
	$Rows = @($Block -split [regex]::Escape($NewLine))
	$Rows[1] = $AlignedSeparator
	for ($Index = 0; $Index -lt $Rows.Count; $Index++) {
		$Style = $Styles[$Index % $Styles.Count]
		$Rows[$Index] = Set-GfmTableRowEdges -Row $Rows[$Index] -LeadingPipe $Style.Leading -TrailingPipe $Style.Trailing -Indent $Style.Indent
	}
	$Content.Substring(0, $Start) + ($Rows -join $NewLine) + $Content.Substring($End)
}

function Add-GfmTableCodeIndent {
	param(
		[Parameter(Mandatory)][string] $Content,
		[Parameter(Mandatory)][string] $Header,
		[Parameter(Mandatory)][string] $NewLine,
		[Parameter(Mandatory)][string] $Prefix
	)

	$Start = $Content.IndexOf($Header, [System.StringComparison]::Ordinal)
	if ($Start -lt 0) { throw "GFM fixture header not found: $Header" }
	$End = $Content.IndexOf("$NewLine$NewLine", $Start, [System.StringComparison]::Ordinal)
	if ($End -lt 0) { $End = $Content.Length }
	$Block = $Content.Substring($Start, $End - $Start)
	$IndentedBlock = (@($Block -split [regex]::Escape($NewLine)) | ForEach-Object { $Prefix + $_ }) -join $NewLine
	$Content.Substring(0, $Start) + $IndentedBlock + $Content.Substring($End)
}

if (-not (Test-Path -LiteralPath $Validator -PathType Leaf)) {
	throw "Validator is missing: $Validator"
}

function Test-CommentTagGrammar {
	# Exercise the actual production header scanner without hashing the package
	# for each lexical case. The default full suite always runs these checks.
	$ParseTokens = $null
	$ParseErrors = $null
	$ValidatorAst = [System.Management.Automation.Language.Parser]::ParseFile($Validator, [ref] $ParseTokens, [ref] $ParseErrors)
	if ($ParseErrors.Count -gt 0) { throw ($ParseErrors | Out-String) }
	foreach ($FunctionName in @('Assert-Condition', 'Test-MarkdownIndentedCodeLine', 'Split-MarkdownTableRow', 'Measure-MarkdownIndent', 'Remove-MarkdownIndent', 'Get-HtmlTagPattern', 'ConvertFrom-MarkdownLinks', 'Test-MarkdownTableDelimiterRow', 'Test-MarkdownTableDelimiterCandidate', 'ConvertTo-VisibleCellText', 'Find-TableHeaderIndices')) {
		$Definitions = @($ValidatorAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq $FunctionName }, $true))
		if ($Definitions.Count -ne 1) { throw "Expected one production function: $FunctionName" }
		. ([scriptblock]::Create($Definitions[0].Extent.Text))
	}
	$GrammarFailures = [System.Collections.Generic.List[string]]::new()
	$GrammarPasses = 0
	$InvalidTags = @(
		'<span "><!--">', "<span '><!--'>",
		'<span title"<!--">', "<span title'<!--'>",
		'</span title="<!--">', '</span/>',
		'<span title=>', '<span title=one=two>',
		'<span title=abc"<!--">', '<span title="<!--"next=x>',
		'<span / >', '<33 title="<!--">', '<span foo/ bar>',
		'<?thing>', '<!DOCTYPE html>', "<span title=`"first`nsecond`">",
		'<span a=x"><!--">', '<span 1name=x>', '<span na*me=x>',
		'<span a=`bad>', '<span a=<bad>', '</span "><!--">', "</span '><!--'>",
		'<![CDATA[<!--]]>'
	)
	$ValidTags = @(
		'<span>', '</span >', '<span hidden>', '<span hidden data-mode=demo/>',
		'<span title="<!--"></span>', "<span title='<!--'></span>",
		'<span title="> <!--" disabled>', "<span title='> <!--' _flag :flag=plain data.key=`"a`">",
		"<x-1`tflag`tkey`t=`t'value' />", '<span title="" data-empty=''''>',
		'<span hidden/><x-1 a=plain></x-1><span title="<!--"></span>'
	)
	foreach ($FirstColumn in @('Path', 'Reviewed asset')) {
		$Header = "| $FirstColumn | Other |"
		$Delimiter = '| --- | --- |'
		foreach ($Continued in @($false, $true)) {
			$Prefix = if ($Continued) { "<!-- note`n--> " } else { '<!-- note --> ' }
			for ($CaseIndex = 0; $CaseIndex -lt $InvalidTags.Count; $CaseIndex++) {
				$Name = "$FirstColumn/invalid-$CaseIndex/continued-$Continued"
				try {
					$Lines = @(($Prefix + $InvalidTags[$CaseIndex] + "`n`n$Header") -split "`n")
					Assert-Throws -Pattern 'Unsupported trailing HTML construct after a comment on line [0-9]+; use complete single-line tags' -Action { Find-TableHeaderIndices -Lines $Lines -FirstColumn $FirstColumn }
					$GrammarPasses++
					Write-Host "HTML tag grammar PASS: $Name"
				}
				catch { $GrammarFailures.Add("${Name}: $($_.Exception.Message)") }
			}
			for ($CaseIndex = 0; $CaseIndex -lt $ValidTags.Count; $CaseIndex++) {
				foreach ($Suffix in @('', ' <!-- real -->', ' <!-- real')) {
					$Name = "$FirstColumn/valid-$CaseIndex/continued-$Continued/suffix-$Suffix"
					try {
						$Body = $Prefix + $ValidTags[$CaseIndex] + $Suffix + "`n`n$Header`n$Delimiter"
						$Expected = if ($Suffix -ceq ' <!-- real') { 0 } else { 1 }
						$Indices = @(Find-TableHeaderIndices -Lines @($Body -split "`n") -FirstColumn $FirstColumn)
						if ($Indices.Count -ne $Expected) { throw "Expected $Expected visible headers; found $($Indices.Count)." }
						$DuplicateIndices = @(Find-TableHeaderIndices -Lines @(("$Header`n$Delimiter`n`n" + $Body) -split "`n") -FirstColumn $FirstColumn)
						if ($DuplicateIndices.Count -ne ($Expected + 1)) { throw "Expected $($Expected + 1) headers including the original; found $($DuplicateIndices.Count)." }
						$GrammarPasses++
						Write-Host "HTML tag grammar PASS: $Name"
					}
					catch { $GrammarFailures.Add("${Name}: $($_.Exception.Message)") }
				}
			}
		}

		$GovernanceColumnsForContainer = @('Provenance/custody', 'Authorship', 'Permission', 'License', 'Product approval')
		$GovernanceHeaderForContainer = "| $FirstColumn | Provenance/custody | Authorship | Permission | License | Product approval |"
		$GovernanceDelimiterForContainer = '| --- | --- | --- | --- | --- | --- |'
		$BoldHeader = $GovernanceHeaderForContainer.Replace($FirstColumn, "**$FirstColumn**")
		$Fence = '```'
		$ContainerCases = [ordered]@{
			'visible-blockquote'             = @{ Body = "> $GovernanceHeaderForContainer`n> $GovernanceDelimiterForContainer"; Count = 1 }
			'visible-list-item'              = @{ Body = "- $GovernanceHeaderForContainer`n  $GovernanceDelimiterForContainer"; Count = 1 }
			'visible-nested-quote-list'      = @{ Body = "> - $GovernanceHeaderForContainer`n>   $GovernanceDelimiterForContainer"; Count = 1 }
			'visible-bold-header-in-quote'   = @{ Body = "> $BoldHeader`n> $GovernanceDelimiterForContainer"; Count = 1 }
			'visible-lazy-continuation'      = @{ Body = "Introductory paragraph text.`n    $GovernanceHeaderForContainer`n$GovernanceDelimiterForContainer"; Count = 1 }
			'harmless-fence-in-blockquote'   = @{ Body = "> ${Fence}markdown`n> $GovernanceHeaderForContainer`n> $GovernanceDelimiterForContainer`n> $Fence"; Count = 0 }
			'harmless-fence-in-list-item'    = @{ Body = "- ${Fence}markdown`n  $GovernanceHeaderForContainer`n  $GovernanceDelimiterForContainer`n  $Fence"; Count = 0 }
			'harmless-code-in-list-item'     = @{ Body = "- Example:`n`n      $GovernanceHeaderForContainer`n      $GovernanceDelimiterForContainer"; Count = 0 }
			'harmless-code-in-blockquote'    = @{ Body = ">     $GovernanceHeaderForContainer`n>     $GovernanceDelimiterForContainer"; Count = 0 }
			'harmless-comment-in-blockquote' = @{ Body = "> <!--`n> $GovernanceHeaderForContainer`n> $GovernanceDelimiterForContainer`n> -->"; Count = 0 }
			'harmless-full-column-prose'     = @{ Body = "$GovernanceHeaderForContainer`nThis is prose, not a delimiter row."; Count = 0 }
		}
		foreach ($CaseName in $ContainerCases.Keys) {
			$Case = $ContainerCases[$CaseName]
			try {
				$Found = @(Find-TableHeaderIndices -Lines @($Case.Body -split "`n") -FirstColumn $FirstColumn -RequiredColumns $GovernanceColumnsForContainer)
				if ($Found.Count -ne $Case.Count) { throw "Expected $($Case.Count) visible headers; found $($Found.Count)." }
				$GrammarPasses++
				Write-Host "Container grammar PASS: $FirstColumn/$CaseName"
			}
			catch { $GrammarFailures.Add("$FirstColumn/${CaseName}: $($_.Exception.Message)") }
		}
	}

	$GovernanceColumns = @('Provenance/custody', 'Authorship', 'Permission', 'License', 'Product approval')
	$GovernanceDelimiter = '| --- | --- | --- | --- | --- | --- |'
	foreach ($LinkHeader in @(
		'| [Path](https://example.test/a(b)) | [Provenance/custody](https://example.test/a(b)) | Authorship | Permission | License | Product approval |',
		'| [Path](https://example.test/a\(b\) "title") | [Provenance/custody](https://example.test/a\(b\) ''title'') | Authorship | Permission | License | Product approval |',
		'| [Path](<https://example.test/a(b>) | [Provenance/custody](<https://example.test/a(b>) | Authorship | Permission | License | Product approval |'
	)) {
		$Indices = @(Find-TableHeaderIndices -Lines @($LinkHeader, $GovernanceDelimiter) -FirstColumn 'Path' -RequiredColumns $GovernanceColumns)
		if ($Indices.Count -ne 1) { $GrammarFailures.Add("balanced-link-header: expected 1 visible header; found $($Indices.Count).") }
	}
	$PipeProse = @(
		'Path | Provenance/custody | Authorship | Permission | License | Product approval',
		'This is ordinary prose, not a GFM delimiter row.'
	)
	$PipeProseIndices = @(Find-TableHeaderIndices -Lines $PipeProse -FirstColumn 'Path' -RequiredColumns $GovernanceColumns)
	if ($PipeProseIndices.Count -ne 0) { $GrammarFailures.Add("pipe-prose: expected 0 rendered table headers; found $($PipeProseIndices.Count).") }
	Write-Host "HTML tag grammar totals: $GrammarPasses passed, $($GrammarFailures.Count) failed."
	if ($GrammarFailures.Count -gt 0) { throw "HTML tag grammar failures:`n$($GrammarFailures -join "`n")" }
}

Test-CommentTagGrammar
if ($CommentTagGrammarOnly) { return }

& $Validator -Root $VisualRoot

$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("aetheln-visual-validation-{0}" -f [guid]::NewGuid().ToString('N'))
try {
	[System.IO.Directory]::CreateDirectory($FixtureRoot) | Out-Null
	Copy-Item -LiteralPath (Join-Path $VisualRoot 'package-manifest.json') -Destination $FixtureRoot
	Copy-Item -LiteralPath (Join-Path $VisualRoot 'asset-provenance.md') -Destination $FixtureRoot
	Copy-Item -LiteralPath (Join-Path $VisualRoot 'generation-prompts.md') -Destination $FixtureRoot
	Copy-Item -LiteralPath $Validator -Destination $FixtureRoot
	[System.IO.Directory]::CreateDirectory((Join-Path $FixtureRoot 'tests')) | Out-Null
	Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $FixtureRoot 'tests\Test-VisualPackageValidation.ps1')

	$Manifest = Get-Content -Raw -LiteralPath (Join-Path $FixtureRoot 'package-manifest.json') | ConvertFrom-Json
	$FirstAsset = $Manifest.assets[0]
	$FirstAssetPath = [string]$FirstAsset.path
	$PromptAsset = @($Manifest.assets | Where-Object { [string]$_.path -ceq 'generation-prompts.md' })[0]
	$ReportRelativePath = 'issue-95-opening-screen-commonui-validation.md'
	$ReportAsset = @($Manifest.assets | Where-Object { [string]$_.path -ceq $ReportRelativePath })[0]
	$AssetPath = Join-Path $VisualRoot ($FirstAsset.path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
	$FixtureAssetPath = Join-Path $FixtureRoot ($FirstAsset.path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
	$FixtureProvenance = Join-Path $FixtureRoot 'asset-provenance.md'
	$SourceProvenance = Get-Content -Raw -LiteralPath (Join-Path $VisualRoot 'asset-provenance.md')
	$FixtureRegisterPaths = @($FirstAssetPath, [string]$PromptAsset.path)
	$PristineProvenance = $SourceProvenance
	foreach ($RegisterMatch in [regex]::Matches($SourceProvenance, '(?m)^\| `([^`]+)` \|[^\r\n]*(?:\r?\n)?')) {
		if ($FixtureRegisterPaths -cnotcontains $RegisterMatch.Groups[1].Value) {
			$PristineProvenance = $PristineProvenance.Replace($RegisterMatch.Value, '')
		}
	}
	[System.IO.Directory]::CreateDirectory((Split-Path -Parent $FixtureAssetPath)) | Out-Null
	Copy-Item -LiteralPath $AssetPath -Destination $FixtureAssetPath
	(Get-Item -LiteralPath $FixtureAssetPath).IsReadOnly = $false

	Assert-Throws -Pattern 'inventory' -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot }

	$Manifest.assets = @($FirstAsset, $PromptAsset)
	$Manifest.expectedAssetCount = 2
	$Manifest.expectedTotalFileCount = 6
	$Manifest.expectedC2paPngCount = if ($FirstAsset.PSObject.Properties.Name -contains 'c2pa' -and $FirstAsset.c2pa) { 1 } else { 0 }
	$Manifest.mirrorPairs = @()
	$Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $FixtureRoot 'package-manifest.json') -Encoding utf8
	Set-Content -LiteralPath $FixtureProvenance -Value $PristineProvenance -NoNewline -Encoding utf8
	& (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 2 -RequiredTotalFileCount 6

	[System.IO.File]::AppendAllText($FixtureAssetPath, 'tamper')
	Assert-Throws -Pattern 'SHA-256' -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 2 -RequiredTotalFileCount 6 }

	Copy-Item -LiteralPath $AssetPath -Destination $FixtureAssetPath -Force
	$Manifest.assets[0].path = 'C:/machine-specific/asset.png'
	$Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $FixtureRoot 'package-manifest.json') -Encoding utf8
	Assert-Throws -Pattern 'relative' -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 2 -RequiredTotalFileCount 6 }

	# Provenance/custody, authorship, permission, license, and product approval
	# must stay five independent per-asset states. Collapsing, renaming, or
	# blanking one must fail with a diagnostic naming the asset and the field.
	$Manifest.assets[0].path = $FirstAssetPath
	$Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $FixtureRoot 'package-manifest.json') -Encoding utf8
	$GovernanceHeader = '| Path | Provenance/custody | Authorship | Permission | License | Product approval |'
	$GovernanceSeparator = '| --- | --- | --- | --- | --- | --- |'
	$RowPattern = '(?m)^\| `' + [regex]::Escape($FirstAssetPath) + '` \|.*$'
	if (-not $PristineProvenance.Contains($GovernanceHeader)) {
		throw "Provenance is missing the five-state governance header: $GovernanceHeader"
	}
	if (-not $PristineProvenance.Contains($GovernanceSeparator)) {
		throw "Provenance is missing the expected governance separator: $GovernanceSeparator"
	}
	if ($PristineProvenance -notmatch $RowPattern) {
		throw "Provenance is missing a per-asset governance row for $($FirstAssetPath)."
	}

	$FirstGovernanceRow = [regex]::Match($PristineProvenance, $RowPattern).Value
	$ProvenanceNewLine = if ($PristineProvenance.Contains("`r`n")) { "`r`n" } else { "`n" }
	$GovernanceTablePrefix = "$GovernanceHeader$ProvenanceNewLine$GovernanceSeparator"
	$BacktickFence = '```'
	$Issue94GuidanceRow = Get-ProvenanceRow -Content $SourceProvenance -Path 'FUTURE-VISUALS-PLAN.md'
	$PromptGovernanceRow = Get-ProvenanceRow -Content $PristineProvenance -Path ([string]$PromptAsset.path)
	$GfmStyles = @(
		@{ Leading = $false; Trailing = $false; Indent = 0 },
		@{ Leading = $true; Trailing = $false; Indent = 1 },
		@{ Leading = $false; Trailing = $true; Indent = 2 },
		@{ Leading = $true; Trailing = $true; Indent = 3 }
	)
	$GfmRegister = Convert-GfmTableBlock -Content $PristineProvenance -Header $GovernanceHeader -NewLine $ProvenanceNewLine -Styles $GfmStyles -AlignedSeparator '| :--- | ---: | :---: | --- | :--- | ---: |'
	Set-Content -LiteralPath $FixtureProvenance -Value $GfmRegister -NoNewline -Encoding utf8
	& (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 2 -RequiredTotalFileCount 6

	$CrossAssignedLegacyRow = Copy-MarkdownTableCells -TargetRow $FirstGovernanceRow -TargetStartIndex 1 -SourceRow $Issue94GuidanceRow -SourceStartIndex 1 -Count 5
	$CrossAssignedLegacyProvenance = $PristineProvenance.Replace($FirstGovernanceRow, $CrossAssignedLegacyRow)
	Set-Content -LiteralPath $FixtureProvenance -Value $CrossAssignedLegacyProvenance -NoNewline -Encoding utf8
	Assert-Throws -Pattern "Governance state 'Provenance/custody'.*$([regex]::Escape($FirstAssetPath)).*does not match source class 'Owner-supplied legacy package'" -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 2 -RequiredTotalFileCount 6 }

	$ConflictingRegisterRow = Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 2 -Value 'Repository-authored under issue #95 and recorded in git history.'
	$SeparatedDuplicateRegister = "$PristineProvenance$ProvenanceNewLine$ProvenanceNewLine## Conflicting duplicate governance table$ProvenanceNewLine$ProvenanceNewLine$GovernanceHeader$ProvenanceNewLine$GovernanceSeparator$ProvenanceNewLine$ConflictingRegisterRow$ProvenanceNewLine"
	Set-Content -LiteralPath $FixtureProvenance -Value $SeparatedDuplicateRegister -NoNewline -Encoding utf8
	Assert-Throws -Pattern 'Per-asset governance table in asset-provenance\.md must declare exactly one applicable header; found 2' -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 2 -RequiredTotalFileCount 6 }

	foreach ($IndentWidth in 1..3) {
		$Indent = ' ' * $IndentWidth
		$IndentedDuplicateRegister = "$PristineProvenance$ProvenanceNewLine$ProvenanceNewLine## Indented duplicate governance table$ProvenanceNewLine$ProvenanceNewLine$Indent$GovernanceHeader$ProvenanceNewLine$Indent$GovernanceSeparator$ProvenanceNewLine$Indent$ConflictingRegisterRow$ProvenanceNewLine"
		Set-Content -LiteralPath $FixtureProvenance -Value $IndentedDuplicateRegister -NoNewline -Encoding utf8
		Assert-Throws -Pattern 'Per-asset governance table in asset-provenance\.md must declare exactly one applicable header; found 2' -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 2 -RequiredTotalFileCount 6 }
	}

	foreach ($CodeBlockRegister in @(
		"$PristineProvenance$ProvenanceNewLine$ProvenanceNewLine${BacktickFence}markdown$ProvenanceNewLine$GovernanceHeader$ProvenanceNewLine$GovernanceSeparator$ProvenanceNewLine$ConflictingRegisterRow$ProvenanceNewLine$BacktickFence$ProvenanceNewLine",
		"$PristineProvenance$ProvenanceNewLine$ProvenanceNewLine   ~~~markdown$ProvenanceNewLine$GovernanceHeader$ProvenanceNewLine$GovernanceSeparator$ProvenanceNewLine$ConflictingRegisterRow$ProvenanceNewLine   ~~~$ProvenanceNewLine",
		"$PristineProvenance$ProvenanceNewLine$ProvenanceNewLine    $GovernanceHeader$ProvenanceNewLine    $GovernanceSeparator$ProvenanceNewLine    $ConflictingRegisterRow$ProvenanceNewLine"
	)) {
		Set-Content -LiteralPath $FixtureProvenance -Value $CodeBlockRegister -NoNewline -Encoding utf8
		& (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 2 -RequiredTotalFileCount 6
	}
	foreach ($SpaceCount in 1..3) {
		$CodeIndent = (' ' * $SpaceCount) + "`t"
		$RegisterCodeExample = "$PristineProvenance$ProvenanceNewLine$ProvenanceNewLine## Indented code example$ProvenanceNewLine$ProvenanceNewLine$CodeIndent$GovernanceHeader$ProvenanceNewLine$CodeIndent$GovernanceSeparator$ProvenanceNewLine$CodeIndent$ConflictingRegisterRow$ProvenanceNewLine"
		Set-Content -LiteralPath $FixtureProvenance -Value $RegisterCodeExample -NoNewline -Encoding utf8
		& (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 2 -RequiredTotalFileCount 6

		$CodeOnlyRegister = Add-GfmTableCodeIndent -Content $PristineProvenance -Header $GovernanceHeader -NewLine $ProvenanceNewLine -Prefix $CodeIndent
		Set-Content -LiteralPath $FixtureProvenance -Value $CodeOnlyRegister -NoNewline -Encoding utf8
		Assert-Throws -Pattern 'Per-asset governance table in asset-provenance\.md must declare exactly one applicable header; found 0' -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 2 -RequiredTotalFileCount 6 }
	}

	$FencedOnlyRegister = $PristineProvenance.Replace($GovernanceHeader, "${BacktickFence}markdown$ProvenanceNewLine$GovernanceHeader").Replace($PromptGovernanceRow, "$PromptGovernanceRow$ProvenanceNewLine$BacktickFence")
	Set-Content -LiteralPath $FixtureProvenance -Value $FencedOnlyRegister -NoNewline -Encoding utf8
	Assert-Throws -Pattern 'Per-asset governance table in asset-provenance\.md must declare exactly one applicable header; found 0' -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 2 -RequiredTotalFileCount 6 }

	$UnrecognizedCustodyPattern = "Governance state 'Provenance/custody' has unrecognized value for $([regex]::Escape($FirstAssetPath))"
	foreach ($Case in @(
		@{
			Provenance = $PristineProvenance.Replace($GovernanceTablePrefix, "$GovernanceHeader$ProvenanceNewLine| -- | --- | --- | --- | --- | --- |")
			Pattern    = 'Per-asset governance table in asset-provenance\.md separator row immediately after its header has invalid cell 1'
		},
		@{
			Provenance = $PristineProvenance.Replace($GovernanceTablePrefix, "$GovernanceHeader$ProvenanceNewLine| |")
			Pattern    = 'Per-asset governance table in asset-provenance\.md separator row immediately after its header must have exactly 6 cells; found 1'
		},
		@{
			Provenance = $PristineProvenance.Replace($GovernanceTablePrefix, "$GovernanceHeader$ProvenanceNewLine| --- |")
			Pattern    = 'Per-asset governance table in asset-provenance\.md separator row immediately after its header must have exactly 6 cells; found 1'
		},
		@{
			Provenance = $PristineProvenance.Replace($GovernanceTablePrefix, "$GovernanceHeader$ProvenanceNewLine||||")
			Pattern    = 'Per-asset governance table in asset-provenance\.md separator row immediately after its header must have exactly 6 cells; found 3'
		},
		@{
			Provenance = $PristineProvenance.Replace($GovernanceTablePrefix, "$GovernanceHeader$ProvenanceNewLine| --- | --- | --- | --- | --- | --- | --- |")
			Pattern    = 'Per-asset governance table in asset-provenance\.md separator row immediately after its header must have exactly 6 cells; found 7'
		},
		@{
			Provenance = $PristineProvenance.Replace("$GovernanceTablePrefix$ProvenanceNewLine", "$GovernanceHeader$ProvenanceNewLine")
			Pattern    = 'Per-asset governance table in asset-provenance\.md must declare exactly one applicable header; found 0'
		},
		@{
			Provenance = $PristineProvenance.Replace($GovernanceHeader, '| Path | Provenance/custody | Authorship | Permission | License |')
			Pattern    = 'governance table in asset-provenance.md must declare 6 columns'
		},
		@{
			Provenance = $PristineProvenance.Replace($FirstGovernanceRow, '')
			Pattern    = "Provenance coverage missing: $([regex]::Escape($FirstAssetPath))"
		},
		@{
			Provenance = $PristineProvenance.Replace($FirstGovernanceRow, "$FirstGovernanceRow$ProvenanceNewLine$FirstGovernanceRow")
			Pattern    = "Duplicate per-asset governance row: $([regex]::Escape($FirstAssetPath))"
		},
		@{
			Provenance = $PristineProvenance.Replace($FirstGovernanceRow, (Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 2 -Value ''))
			Pattern    = "Governance state 'Authorship' is blank for $([regex]::Escape($FirstAssetPath))"
		},
		@{
			Provenance = $PristineProvenance.Replace($FirstGovernanceRow, (Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 1 -Value 'Custody recorded; owner-approved for production.'))
			Pattern    = $UnrecognizedCustodyPattern
		},
		@{
			Provenance = $PristineProvenance.Replace($FirstGovernanceRow, (Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 1 -Value 'Custody recorded; approve runtime use.'))
			Pattern    = $UnrecognizedCustodyPattern
		},
		@{
			Provenance = $PristineProvenance.Replace($FirstGovernanceRow, (Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 1 -Value 'Custody recorded; approves runtime use.'))
			Pattern    = $UnrecognizedCustodyPattern
		},
		@{
			Provenance = $PristineProvenance.Replace($FirstGovernanceRow, (Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 1 -Value 'Custody recorded; approving runtime use.'))
			Pattern    = $UnrecognizedCustodyPattern
		},
		@{
			Provenance = $PristineProvenance.Replace($FirstGovernanceRow, (Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 1 -Value 'Custody recorded; approval is Pending/TBD.'))
			Pattern    = $UnrecognizedCustodyPattern
		},
		@{
			Provenance = $PristineProvenance.Replace($FirstGovernanceRow, (Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 1 -Value 'Custody recorded; permissions are Pending/TBD.'))
			Pattern    = $UnrecognizedCustodyPattern
		},
		@{
			Provenance = $PristineProvenance.Replace($FirstGovernanceRow, (Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 1 -Value 'Custody recorded; author is Pending/TBD.'))
			Pattern    = $UnrecognizedCustodyPattern
		},
		@{
			Provenance = $PristineProvenance.Replace($FirstGovernanceRow, (Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 1 -Value 'Custody recorded; permission is Pending/TBD.'))
			Pattern    = $UnrecognizedCustodyPattern
		},
		@{
			Provenance = $PristineProvenance.Replace($FirstGovernanceRow, (Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 1 -Value 'Pending/TBD: authorship, permission, and license evidence unresolved.'))
			Pattern    = $UnrecognizedCustodyPattern
		},
		@{
			Provenance = $PristineProvenance.Replace($FirstGovernanceRow, (Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 1 -Value 'Custody recorded; usage rights remain unresolved.'))
			Pattern    = $UnrecognizedCustodyPattern
		},
		@{
			Provenance = $PristineProvenance.Replace($FirstGovernanceRow, (Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 1 -Value 'Custody recorded; authorized for runtime use.'))
			Pattern    = $UnrecognizedCustodyPattern
		},
		@{
			Provenance = $PristineProvenance.Replace($FirstGovernanceRow, (Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 1 -Value 'Custody recorded; created by Named Creator.'))
			Pattern    = $UnrecognizedCustodyPattern
		},
		@{
			Provenance = $PristineProvenance.Replace($FirstGovernanceRow, (Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 1 -Value 'Custody recorded; cleared for production.'))
			Pattern    = $UnrecognizedCustodyPattern
		},
		@{
			Provenance = $PristineProvenance.Replace($FirstGovernanceRow, (Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 2 -Value 'Opaque governance value.'))
			Pattern    = "Governance state 'Authorship' has unrecognized value for $([regex]::Escape($FirstAssetPath))"
		},
		@{
			Provenance = $PristineProvenance.Replace($FirstGovernanceRow, (Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 3 -Value 'Opaque governance value.'))
			Pattern    = "Governance state 'Permission' has unrecognized value for $([regex]::Escape($FirstAssetPath))"
		},
		@{
			Provenance = $PristineProvenance.Replace($FirstGovernanceRow, (Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 4 -Value 'Opaque governance value.'))
			Pattern    = "Governance state 'License' has unrecognized value for $([regex]::Escape($FirstAssetPath))"
		},
		@{
			Provenance = $PristineProvenance.Replace($FirstGovernanceRow, (Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 5 -Value 'Opaque governance value.'))
			Pattern    = "Governance state 'Product approval' has unrecognized value for $([regex]::Escape($FirstAssetPath))"
		}
	)) {
		Set-Content -LiteralPath $FixtureProvenance -Value $Case.Provenance -NoNewline -Encoding utf8
		Assert-Throws -Pattern $Case.Pattern -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 2 -RequiredTotalFileCount 6 }
	}

	Set-Content -LiteralPath $FixtureProvenance -Value $PristineProvenance -NoNewline -Encoding utf8
	& (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 2 -RequiredTotalFileCount 6

	$UnexpectedRegisterRow = Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 0 -Value '`unexpected-governance-record.png`'
	$UnexpectedRegisterProvenance = $PristineProvenance.Replace($FirstGovernanceRow, "$FirstGovernanceRow$ProvenanceNewLine$UnexpectedRegisterRow")
	Set-Content -LiteralPath $FixtureProvenance -Value $UnexpectedRegisterProvenance -NoNewline -Encoding utf8
	Assert-Throws -Pattern 'Unexpected per-asset governance row: unexpected-governance-record\.png is not listed in package-manifest\.json' -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 2 -RequiredTotalFileCount 6 }

	$UnquotedRegisterRow = Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 0 -Value 'unexpected-governance-record.png'
	$UnquotedRegisterRow = Set-MarkdownTableCell -Row $UnquotedRegisterRow -Index 2 -Value 'Named creator.'
	$UnquotedRegisterRow = Set-MarkdownTableCell -Row $UnquotedRegisterRow -Index 3 -Value 'Authorized for runtime use.'
	$UnquotedRegisterRow = Set-MarkdownTableCell -Row $UnquotedRegisterRow -Index 4 -Value 'Production license.'
	$UnquotedRegisterRow = Set-MarkdownTableCell -Row $UnquotedRegisterRow -Index 5 -Value 'Approved for production.'
	$UnquotedRegisterProvenance = $PristineProvenance.Replace($FirstGovernanceRow, "$FirstGovernanceRow$ProvenanceNewLine$UnquotedRegisterRow")
	Set-Content -LiteralPath $FixtureProvenance -Value $UnquotedRegisterProvenance -NoNewline -Encoding utf8
	Assert-Throws -Pattern "Malformed per-asset governance path cell in asset-provenance\.md: expected a single backtick-wrapped path; found 'unexpected-governance-record\.png'\." -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 2 -RequiredTotalFileCount 6 }

	Set-Content -LiteralPath $FixtureProvenance -Value $PristineProvenance -NoNewline -Encoding utf8
	& (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 2 -RequiredTotalFileCount 6

	$UnknownRelativePath = 'unclassified/new-legacy-copy.png'
	$UnknownAssetPath = Join-Path $FixtureRoot ($UnknownRelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
	$UnknownAssetDirectory = Split-Path -Parent $UnknownAssetPath
	$OriginalFixtureC2paCount = [int]$Manifest.expectedC2paPngCount
	try {
		[System.IO.Directory]::CreateDirectory($UnknownAssetDirectory) | Out-Null
		Copy-Item -LiteralPath $AssetPath -Destination $UnknownAssetPath
		(Get-Item -LiteralPath $UnknownAssetPath).IsReadOnly = $false
		$UnknownAsset = $FirstAsset | Select-Object *
		$UnknownAsset.path = $UnknownRelativePath
		$Manifest.assets = @($FirstAsset, $PromptAsset, $UnknownAsset)
		$Manifest.expectedAssetCount = 3
		$Manifest.expectedTotalFileCount = 7
		$Manifest.expectedC2paPngCount = $OriginalFixtureC2paCount + $(if ($FirstAsset.PSObject.Properties.Name -contains 'c2pa' -and $FirstAsset.c2pa) { 1 } else { 0 })
		$Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $FixtureRoot 'package-manifest.json') -Encoding utf8
		$UnknownGovernanceRow = Set-MarkdownTableCell -Row $FirstGovernanceRow -Index 0 -Value "``$UnknownRelativePath``"
		$UnknownGovernanceProvenance = $PristineProvenance.Replace($FirstGovernanceRow, "$FirstGovernanceRow$ProvenanceNewLine$UnknownGovernanceRow")
		Set-Content -LiteralPath $FixtureProvenance -Value $UnknownGovernanceProvenance -NoNewline -Encoding utf8
		Assert-Throws -Pattern "Manifest path '$([regex]::Escape($UnknownRelativePath))' does not resolve to a reviewed governance source class" -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 3 -RequiredTotalFileCount 7 }
	}
	finally {
		$Manifest.assets = @($FirstAsset, $PromptAsset)
		$Manifest.expectedAssetCount = 2
		$Manifest.expectedTotalFileCount = 6
		$Manifest.expectedC2paPngCount = $OriginalFixtureC2paCount
		$Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $FixtureRoot 'package-manifest.json') -Encoding utf8
		Set-Content -LiteralPath $FixtureProvenance -Value $PristineProvenance -NoNewline -Encoding utf8
		if ([System.IO.File]::Exists($UnknownAssetPath)) { [System.IO.File]::Delete($UnknownAssetPath) }
		if ([System.IO.Directory]::Exists($UnknownAssetDirectory)) { [System.IO.Directory]::Delete($UnknownAssetDirectory) }
	}

	# The Issue #95 report must keep visual suitability and allowed current use
	# separate from the five governance states, and record each governance state
	# independently for every reviewed asset. The report is a manifested asset, so
	# each fixture variant re-stamps its hash and byte length before validation.
	$FixtureReport = Join-Path $FixtureRoot $ReportRelativePath
	$PristineReport = Get-Content -Raw -LiteralPath (Join-Path $VisualRoot $ReportRelativePath)
	$Manifest = Get-Content -Raw -LiteralPath (Join-Path $VisualRoot 'package-manifest.json') | ConvertFrom-Json
	$ReportAsset = @($Manifest.assets | Where-Object { [string]$_.path -ceq $ReportRelativePath })[0]
	foreach ($Asset in $Manifest.assets) {
		$SourceAssetPath = Join-Path $VisualRoot ($Asset.path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
		$FixtureFullAssetPath = Join-Path $FixtureRoot ($Asset.path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
		[System.IO.Directory]::CreateDirectory((Split-Path -Parent $FixtureFullAssetPath)) | Out-Null
		Copy-Item -LiteralPath $SourceAssetPath -Destination $FixtureFullAssetPath -Force
	}
	(Get-Item -LiteralPath $FixtureReport).IsReadOnly = $false
	Set-Content -LiteralPath $FixtureProvenance -Value $SourceProvenance -NoNewline -Encoding utf8

	function Set-FixtureReport {
		param([Parameter(Mandatory)][AllowEmptyString()][string] $Content)
		Set-Content -LiteralPath $FixtureReport -Value $Content -NoNewline -Encoding utf8
		$ReportAsset.sha256 = (Get-FileHash -LiteralPath $FixtureReport -Algorithm SHA256).Hash.ToLowerInvariant()
		$ReportAsset.bytes = (Get-Item -LiteralPath $FixtureReport).Length
		$Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $FixtureRoot 'package-manifest.json') -Encoding utf8
	}

	$ReportHeader = '| Reviewed asset | Visual suitability | Provenance/custody | Authorship | Permission | License | Product approval | Allowed current use |'
	$ReportSeparator = '| --- | --- | --- | --- | --- | --- | --- | --- |'
	$ReportRowPattern = '(?m)^\| `01-main-menu-concept\.png` \|.*$'
	$SecondReportRowPattern = '(?m)^\| `02-playable-peoples-lineup\.png` \|.*(?:\r?\n)?'
	if (-not $PristineReport.Contains($ReportHeader)) {
		throw "Issue #95 report is missing the eight-column classification header: $ReportHeader"
	}
	if (-not $PristineReport.Contains($ReportSeparator)) {
		throw "Issue #95 report is missing the expected classification separator: $ReportSeparator"
	}
	if ($PristineReport -notmatch $ReportRowPattern) {
		throw 'Issue #95 report is missing the reviewed-asset row for 01-main-menu-concept.png.'
	}
	if ($PristineReport -notmatch $SecondReportRowPattern) {
		throw 'Issue #95 report is missing the reviewed-asset row for 02-playable-peoples-lineup.png.'
	}

	$MainReportRow = [regex]::Match($PristineReport, $ReportRowPattern).Value
	$ReportNewLine = if ($PristineReport.Contains("`r`n")) { "`r`n" } else { "`n" }
	$ReportTablePrefix = "$ReportHeader$ReportNewLine$ReportSeparator"
	$DuplicateMainReport = $PristineReport.Replace($MainReportRow, "$MainReportRow$ReportNewLine$MainReportRow")
	$BlankPermissionRow = Set-MarkdownTableCell -Row $MainReportRow -Index 4 -Value ''
	$CollapsedCustodyRow = Set-MarkdownTableCell -Row $MainReportRow -Index 2 -Value 'Pending/TBD: authorship, permission, and license evidence unresolved.'
	$AuthorshipMismatchRow = Set-MarkdownTableCell -Row $MainReportRow -Index 3 -Value 'Repository-authored under issue #95 and recorded in git history.'
	$PermissionUnrecognizedRow = Set-MarkdownTableCell -Row $MainReportRow -Index 4 -Value 'Authorized for runtime use.'
	$ContradictoryAllowedUseRow = Set-MarkdownTableCell -Row $MainReportRow -Index 7 -Value 'Approved for runtime and Content promotion.'
	$CaseVariantReportRow = Set-MarkdownTableCell -Row $MainReportRow -Index 0 -Value '`01-Main-menu-concept.png`'
	$SeparatedDuplicateReport = "$PristineReport$ReportNewLine$ReportNewLine## Conflicting duplicate classification table$ReportNewLine$ReportNewLine$ReportHeader$ReportNewLine$ReportSeparator$ReportNewLine$AuthorshipMismatchRow$ReportNewLine"

	Set-FixtureReport -Content $PristineReport
	& (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot

	$EscapedPipeReportRow = Set-MarkdownTableCell -Row $MainReportRow -Index 1 -Value 'Suitable visual reference with a literal A \| B label.'
	$GfmReportSource = $PristineReport.Replace($MainReportRow, $EscapedPipeReportRow)
	$GfmReport = Convert-GfmTableBlock -Content $GfmReportSource -Header $ReportHeader -NewLine $ReportNewLine -Styles $GfmStyles -AlignedSeparator ':--- | ---: | :---: | --- | :--- | ---: | :---: | ---:'
	Set-FixtureReport -Content $GfmReport
	& (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot
	Set-FixtureReport -Content $PristineReport

	foreach ($ClassCase in @(
		@{
			TargetPath  = '01-overall-mood-key.png'
			SourcePath  = 'generation-prompts.md'
			SourceClass = 'Owner-directed issue #114 generation'
		},
		@{
			TargetPath  = 'ui-production-v2/build-preview.ps1'
			SourcePath  = 'generation-prompts.md'
			SourceClass = 'Repository-hardened issue #94 authoring utility'
		},
		@{
			TargetPath  = 'FUTURE-VISUALS-PLAN.md'
			SourcePath  = 'generation-prompts.md'
			SourceClass = 'Repository-hardened issue #94 guidance'
		},
		@{
			TargetPath  = 'README.md'
			SourcePath  = 'generation-prompts.md'
			SourceClass = 'README issues #94/#95 guidance'
		},
		@{
			TargetPath  = $ReportRelativePath
			SourcePath  = 'generation-prompts.md'
			SourceClass = 'Repository-authored Issue #95 report'
		}
	)) {
		$TargetClassRow = Get-ProvenanceRow -Content $SourceProvenance -Path $ClassCase.TargetPath
		$SourceClassRow = Get-ProvenanceRow -Content $SourceProvenance -Path $ClassCase.SourcePath
		$CrossAssignedClassRow = Copy-MarkdownTableCells -TargetRow $TargetClassRow -TargetStartIndex 1 -SourceRow $SourceClassRow -SourceStartIndex 1 -Count 5
		$CrossAssignedClassProvenance = $SourceProvenance.Replace($TargetClassRow, $CrossAssignedClassRow)
		Set-Content -LiteralPath $FixtureProvenance -Value $CrossAssignedClassProvenance -NoNewline -Encoding utf8
		Assert-Throws -Pattern "Governance state 'Provenance/custody'.*$([regex]::Escape($ClassCase.TargetPath)).*does not match source class '$([regex]::Escape($ClassCase.SourceClass))'" -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot }
	}

	$GeneratedGovernanceRow = Get-ProvenanceRow -Content $SourceProvenance -Path '01-overall-mood-key.png'
	$MainRegisterRow = Get-ProvenanceRow -Content $SourceProvenance -Path '01-main-menu-concept.png'
	$CrossAssignedMainRegisterRow = Copy-MarkdownTableCells -TargetRow $MainRegisterRow -TargetStartIndex 1 -SourceRow $GeneratedGovernanceRow -SourceStartIndex 1 -Count 5
	$CrossAssignedMainReportRow = Copy-MarkdownTableCells -TargetRow $MainReportRow -TargetStartIndex 2 -SourceRow $GeneratedGovernanceRow -SourceStartIndex 1 -Count 5
	$CrossAssignedMainProvenance = $SourceProvenance.Replace($MainRegisterRow, $CrossAssignedMainRegisterRow)
	$CrossAssignedMainReport = $PristineReport.Replace($MainReportRow, $CrossAssignedMainReportRow)
	Set-Content -LiteralPath $FixtureProvenance -Value $CrossAssignedMainProvenance -NoNewline -Encoding utf8
	Set-FixtureReport -Content $CrossAssignedMainReport
	Assert-Throws -Pattern "Governance state 'Provenance/custody'.*01-main-menu-concept\.png.*does not match source class 'Owner-supplied legacy package'" -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot }

	Set-Content -LiteralPath $FixtureProvenance -Value $SourceProvenance -NoNewline -Encoding utf8
	Set-FixtureReport -Content $CrossAssignedMainReport
	Assert-Throws -Pattern "Governance state 'Provenance/custody'.*``01-main-menu-concept\.png``.*does not match source class 'Owner-supplied legacy package'" -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot }

	Set-Content -LiteralPath $FixtureProvenance -Value $SourceProvenance -NoNewline -Encoding utf8
	Set-FixtureReport -Content $PristineReport

	foreach ($IndentWidth in 1..3) {
		$Indent = ' ' * $IndentWidth
		$IndentedDuplicateReport = "$PristineReport$ReportNewLine$ReportNewLine## Indented duplicate classification table$ReportNewLine$ReportNewLine$Indent$ReportHeader$ReportNewLine$Indent$ReportSeparator$ReportNewLine$Indent$AuthorshipMismatchRow$ReportNewLine"
		Set-FixtureReport -Content $IndentedDuplicateReport
		Assert-Throws -Pattern 'Per-asset classification table in issue-95-opening-screen-commonui-validation\.md must declare exactly one applicable header; found 2' -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot }
	}

	foreach ($CodeBlockReport in @(
		"$PristineReport$ReportNewLine$ReportNewLine~~~markdown$ReportNewLine$ReportHeader$ReportNewLine$ReportSeparator$ReportNewLine$AuthorshipMismatchRow$ReportNewLine~~~$ReportNewLine",
		"$PristineReport$ReportNewLine$ReportNewLine   ~~~markdown$ReportNewLine$ReportHeader$ReportNewLine$ReportSeparator$ReportNewLine$AuthorshipMismatchRow$ReportNewLine   ~~~$ReportNewLine",
		"$PristineReport$ReportNewLine$ReportNewLine    $ReportHeader$ReportNewLine    $ReportSeparator$ReportNewLine    $AuthorshipMismatchRow$ReportNewLine"
	)) {
		Set-FixtureReport -Content $CodeBlockReport
		& (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot
	}
	foreach ($SpaceCount in 1..3) {
		$CodeIndent = (' ' * $SpaceCount) + "`t"
		$ReportCodeExample = "$PristineReport$ReportNewLine$ReportNewLine## Indented code example$ReportNewLine$ReportNewLine$CodeIndent$ReportHeader$ReportNewLine$CodeIndent$ReportSeparator$ReportNewLine$CodeIndent$AuthorshipMismatchRow$ReportNewLine"
		Set-FixtureReport -Content $ReportCodeExample
		& (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot

		$CodeOnlyReport = Add-GfmTableCodeIndent -Content $PristineReport -Header $ReportHeader -NewLine $ReportNewLine -Prefix $CodeIndent
		Set-FixtureReport -Content $CodeOnlyReport
		Assert-Throws -Pattern 'Per-asset classification table in issue-95-opening-screen-commonui-validation\.md must declare exactly one applicable header; found 0' -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot }
	}

	$LastReportRow = [regex]::Match($PristineReport, '(?m)^\| Kell selection render \|.*$').Value
	if ([string]::IsNullOrWhiteSpace($LastReportRow)) { throw 'Issue #95 report is missing the final reviewed-asset row.' }
	$FencedOnlyReport = $PristineReport.Replace($ReportHeader, "~~~markdown$ReportNewLine$ReportHeader").Replace($LastReportRow, "$LastReportRow$ReportNewLine~~~")
	Set-FixtureReport -Content $FencedOnlyReport
	Assert-Throws -Pattern 'Per-asset classification table in issue-95-opening-screen-commonui-validation\.md must declare exactly one applicable header; found 0' -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot }

	foreach ($Case in @(
		@{
			Report  = $PristineReport.Replace($ReportTablePrefix, "$ReportHeader$ReportNewLine| -- | --- | --- | --- | --- | --- | --- | --- |")
			Pattern = 'Per-asset classification table in issue-95-opening-screen-commonui-validation\.md separator row immediately after its header has invalid cell 1'
		},
		@{
			Report  = $PristineReport.Replace($ReportTablePrefix, "$ReportHeader$ReportNewLine| |")
			Pattern = 'Per-asset classification table in issue-95-opening-screen-commonui-validation\.md separator row immediately after its header must have exactly 8 cells; found 1'
		},
		@{
			Report  = $PristineReport.Replace($ReportTablePrefix, "$ReportHeader$ReportNewLine||||")
			Pattern = 'Per-asset classification table in issue-95-opening-screen-commonui-validation\.md separator row immediately after its header must have exactly 8 cells; found 3'
		},
		@{
			Report  = $PristineReport.Replace($ReportTablePrefix, "$ReportHeader$ReportNewLine| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
			Pattern = 'Per-asset classification table in issue-95-opening-screen-commonui-validation\.md separator row immediately after its header must have exactly 8 cells; found 9'
		},
		@{
			Report  = $PristineReport.Replace("$ReportTablePrefix$ReportNewLine", "$ReportHeader$ReportNewLine")
			Pattern = 'Per-asset classification table in issue-95-opening-screen-commonui-validation\.md must declare exactly one applicable header; found 0'
		},
		@{
			Report  = $PristineReport.Replace($ReportHeader, '| Reviewed asset | Visual suitability | Provenance/custody | Authorship | Permission | Product approval | Allowed current use |')
			Pattern = 'classification table in issue-95-opening-screen-commonui-validation\.md must declare 8 columns'
		},
		@{
			Report  = $PristineReport.Replace($MainReportRow, $BlankPermissionRow)
			Pattern = "Governance state 'Permission' is blank for ``01-main-menu-concept\.png``"
		},
		@{
			Report  = $PristineReport.Replace($MainReportRow, ($MainReportRow.Substring(0, $MainReportRow.Length - 1) + '| unexpected |'))
			Pattern = 'row for `01-main-menu-concept\.png` has 9 cells; expected 8'
		},
		@{
			Report  = $PristineReport.Replace($MainReportRow, $CollapsedCustodyRow)
			Pattern = "Governance state 'Provenance/custody' has unrecognized value for ``01-main-menu-concept\.png``"
		},
		@{
			Report  = $DuplicateMainReport
			Pattern = 'Duplicate reviewed-asset record.*01-main-menu-concept\.png'
		},
		@{
			Report  = $SeparatedDuplicateReport
			Pattern = 'Per-asset classification table in issue-95-opening-screen-commonui-validation\.md must declare exactly one applicable header; found 2'
		},
		@{
			Report  = $PristineReport.Replace($MainReportRow, $CaseVariantReportRow)
			Pattern = 'Unexpected reviewed-asset record.*`01-Main-menu-concept\.png`'
		},
		@{
			Report  = [regex]::Replace($PristineReport, $SecondReportRowPattern, '')
			Pattern = 'Required reviewed-asset record missing.*02-playable-peoples-lineup\.png'
		},
		@{
			Report  = $PristineReport.Replace($MainReportRow, $AuthorshipMismatchRow)
			Pattern = "Governance state 'Authorship'.*``01-main-menu-concept\.png``.*does not match source class 'Owner-supplied legacy package'"
		},
		@{
			Report  = $PristineReport.Replace($MainReportRow, $PermissionUnrecognizedRow)
			Pattern = "Governance state 'Permission' has unrecognized value for ``01-main-menu-concept\.png``"
		},
		@{
			Report  = $PristineReport.Replace($MainReportRow, $ContradictoryAllowedUseRow)
			Pattern = "Field 'Allowed current use' is contradictory for reviewed asset ``01-main-menu-concept\.png``.*Product approval is Not approved"
		}
	)) {
		Set-FixtureReport -Content $Case.Report
		Assert-Throws -Pattern $Case.Pattern -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot }
	}

	Set-FixtureReport -Content $PristineReport
	& (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot

	# GitHub renders governance tables inside blockquotes, list items, and lazy
	# paragraph continuations (retained GFM-rendered fixtures, issue #95), so a
	# conflicting duplicate in any of those containers must be counted. Fenced,
	# commented, and genuinely indented code inside the same containers must not.
	$ContainerFailures = [System.Collections.Generic.List[string]]::new()
	foreach ($Document in @(
		@{ Name = 'register'; Content = $SourceProvenance; Header = $GovernanceHeader; Separator = $GovernanceSeparator; Row = $MainRegisterRow; PermissionIndex = 3; NewLine = $ProvenanceNewLine; Pattern = 'Per-asset governance table in asset-provenance\.md must declare exactly one applicable header; found 2' },
		@{ Name = 'report'; Content = $PristineReport; Header = $ReportHeader; Separator = $ReportSeparator; Row = $MainReportRow; PermissionIndex = 4; NewLine = $ReportNewLine; Pattern = 'Per-asset classification table in issue-95-opening-screen-commonui-validation\.md must declare exactly one applicable header; found 2' }
	)) {
		$NewLine = $Document.NewLine
		$ConflictingRow = Set-MarkdownTableCell -Row $Document.Row -Index $Document.PermissionIndex -Value 'Approved for runtime use.'
		# GitHub renders emphasis or code delimiters around the identifying header
		# cell as the same visible header (retained GFM API renders of full
		# packages, issue #95), so such duplicates must be counted; the canonical
		# table itself still needs the exact unformatted header.
		$FirstHeaderCell = @(Split-GfmFixtureRow -Row $Document.Header)[0]
		$BoldHeader = Set-MarkdownTableCell -Row $Document.Header -Index 0 -Value "**$FirstHeaderCell**"
		$UnderscoreHeader = Set-MarkdownTableCell -Row $Document.Header -Index 0 -Value "__${FirstHeaderCell}__"
		$CodeHeader = Set-MarkdownTableCell -Row $Document.Header -Index 0 -Value "``$FirstHeaderCell``"
		$StrikeHeader = Set-MarkdownTableCell -Row $Document.Header -Index 0 -Value "~~$FirstHeaderCell~~"
		# Inline HTML, links, character entities, inline comments, nested formatting,
		# and zero-width characters in the identifying cell also render as the same
		# visible header (retained GFM API renders of full register packages, issue
		# #95), and a header whose other cells are the five governance columns is a
		# governance table whatever its first cell says. All of these must be
		# counted; a table that merely shares a word or some columns must not.
		$EntityCell = $FirstHeaderCell.Substring(0, 1) + '&#' + [int][char]$FirstHeaderCell[1] + ';' + $FirstHeaderCell.Substring(2)
		$Variants = [ordered]@{
			'{HB}' = Set-MarkdownTableCell -Row $Document.Header -Index 0 -Value "<b>$FirstHeaderCell</b>"
			'{HS}' = Set-MarkdownTableCell -Row $Document.Header -Index 0 -Value "<span class=`"x`">$FirstHeaderCell</span>"
			'{LI}' = Set-MarkdownTableCell -Row $Document.Header -Index 0 -Value "[$FirstHeaderCell](#x)"
			'{LR}' = Set-MarkdownTableCell -Row $Document.Header -Index 0 -Value "[$FirstHeaderCell][ref]"
			'{LS}' = Set-MarkdownTableCell -Row $Document.Header -Index 0 -Value "[$FirstHeaderCell]"
			'{EN}' = Set-MarkdownTableCell -Row $Document.Header -Index 0 -Value $EntityCell
			'{IC}' = Set-MarkdownTableCell -Row $Document.Header -Index 0 -Value ($FirstHeaderCell.Substring(0, 2) + '<!-- c -->' + $FirstHeaderCell.Substring(2))
			'{NE}' = Set-MarkdownTableCell -Row $Document.Header -Index 0 -Value "**_${FirstHeaderCell}_**"
			'{NH}' = Set-MarkdownTableCell -Row $Document.Header -Index 0 -Value "<b>*$FirstHeaderCell*</b>"
			'{ZW}' = Set-MarkdownTableCell -Row $Document.Header -Index 0 -Value ($FirstHeaderCell.Substring(0, 2) + '&#8203;' + $FirstHeaderCell.Substring(2))
			'{SR}' = Set-MarkdownTableCell -Row $Document.Header -Index 0 -Value 'Asset'
			'{SB}' = Set-MarkdownTableCell -Row (Set-MarkdownTableCell -Row $Document.Header -Index 0 -Value 'Asset') -Index $Document.PermissionIndex -Value '<b>Permission</b>'
		}
		$ContainerCases = [ordered]@{
			'visible-html-b-header'           = @{ Body = '{HB}{N}{S}{N}{R}'; Visible = $true }
			'visible-html-span-header'        = @{ Body = '{HS}{N}{S}{N}{R}'; Visible = $true }
			'visible-inline-link-header'      = @{ Body = '{LI}{N}{S}{N}{R}'; Visible = $true }
			'visible-reference-link-header'   = @{ Body = '{LR}{N}{S}{N}{R}{N}{N}[ref]: #x'; Visible = $true }
			'visible-shortcut-link-header'    = @{ Body = '{LS}{N}{S}{N}{R}{N}{N}[' + $FirstHeaderCell + ']: #x'; Visible = $true }
			'visible-entity-header'           = @{ Body = '{EN}{N}{S}{N}{R}'; Visible = $true }
			'visible-inline-comment-header'   = @{ Body = '{IC}{N}{S}{N}{R}'; Visible = $true }
			'visible-nested-emphasis-header'  = @{ Body = '{NE}{N}{S}{N}{R}'; Visible = $true }
			'visible-nested-html-header'      = @{ Body = '{NH}{N}{S}{N}{R}'; Visible = $true }
			'visible-zero-width-header'       = @{ Body = '{ZW}{N}{S}{N}{R}'; Visible = $true }
			'visible-structural-rename'       = @{ Body = '{SR}{N}{S}{N}{R}'; Visible = $true }
			'visible-structural-html-column'  = @{ Body = '{SB}{N}{S}{N}{R}'; Visible = $true }
			'harmless-html-b-header-in-fence' = @{ Body = '```markdown{N}{HB}{N}{S}{N}{R}{N}```'; Visible = $false }
			'harmless-shared-word-table'      = @{ Body = '| ' + $FirstHeaderCell + ' count | Value |{N}| --- | --- |{N}| 1 | 2 |'; Visible = $false }
			'harmless-partial-columns-table'  = @{ Body = '| State | Authorship | Permission |{N}| --- | --- | --- |{N}| a | b | c |'; Visible = $false }
			'visible-bold-header'            = @{ Body = '{B}{N}{S}{N}{R}'; Visible = $true }
			'visible-underscore-header'      = @{ Body = '{U}{N}{S}{N}{R}'; Visible = $true }
			'visible-code-header'            = @{ Body = '{C}{N}{S}{N}{R}'; Visible = $true }
			'visible-strike-header'          = @{ Body = '{K}{N}{S}{N}{R}'; Visible = $true }
			'visible-bold-header-in-quote'   = @{ Body = '> {B}{N}> {S}{N}> {R}'; Visible = $true }
			'harmless-bold-header-in-fence'  = @{ Body = '```markdown{N}{B}{N}{S}{N}{R}{N}```'; Visible = $false }
			'harmless-bold-header-in-code'   = @{ Body = '    {B}{N}    {S}{N}    {R}'; Visible = $false }
			'visible-blockquote'             = @{ Body = '> {H}{N}> {S}{N}> {R}'; Visible = $true }
			'visible-list-item'              = @{ Body = '- {H}{N}  {S}{N}  {R}'; Visible = $true }
			'visible-star-list-item'         = @{ Body = '* {H}{N}  {S}{N}  {R}'; Visible = $true }
			'visible-lazy-continuation'      = @{ Body = 'Introductory paragraph text.{N}    {H}{N}{S}{N}{R}'; Visible = $true }
			'visible-nested-quote-list'      = @{ Body = '> - {H}{N}>   {S}{N}>   {R}'; Visible = $true }
			'visible-ordered-list-4-space'   = @{ Body = '10. {H}{N}    {S}{N}    {R}'; Visible = $true }
			'visible-list-blank-4-space'     = @{ Body = '- Item{N}{N}    {H}{N}    {S}{N}    {R}'; Visible = $true }
			'visible-blockquote-tab'         = @{ Body = '>{T}{H}{N}>{T}{S}{N}>{T}{R}'; Visible = $true }
			'harmless-fence-in-blockquote'   = @{ Body = '> ```markdown{N}> {H}{N}> {S}{N}> {R}{N}> ```'; Visible = $false }
			'harmless-fence-in-list-item'    = @{ Body = '- ```markdown{N}  {H}{N}  {S}{N}  {R}{N}  ```'; Visible = $false }
			'harmless-code-in-list-item'     = @{ Body = '- Example:{N}{N}      {H}{N}      {S}{N}      {R}'; Visible = $false }
			'harmless-code-in-blockquote'    = @{ Body = '>     {H}{N}>     {S}{N}>     {R}'; Visible = $false }
			'harmless-comment-in-blockquote' = @{ Body = '> <!--{N}> {H}{N}> {S}{N}> {R}{N}> -->'; Visible = $false }
			'harmless-heading-then-code'     = @{ Body = '## Example{N}{N}    {H}{N}    {S}{N}    {R}'; Visible = $false }
			'harmless-break-then-code'       = @{ Body = 'Intro{N}{N}---{N}    {H}{N}    {S}{N}    {R}'; Visible = $false }
		}
		# The lexical/container matrix runs directly against the extracted
		# production scanner in Test-CommentTagGrammar. Keep only one rendered
		# container and one rendered-code integration case per governed document;
		# do not rehash the complete 108-file package for every lexical variant.
		$ContainerCases = [ordered]@{
			'visible-blockquote' = $ContainerCases['visible-blockquote']
			'harmless-code-in-list-item' = $ContainerCases['harmless-code-in-list-item']
		}
		foreach ($CaseName in $ContainerCases.Keys) {
			$Case = $ContainerCases[$CaseName]
			$Body = $Case.Body.Replace('{H}', $Document.Header).Replace('{B}', $BoldHeader).Replace('{U}', $UnderscoreHeader).Replace('{C}', $CodeHeader).Replace('{K}', $StrikeHeader).Replace('{S}', $Document.Separator).Replace('{R}', $ConflictingRow).Replace('{N}', $NewLine).Replace('{T}', "`t")
			foreach ($Token in $Variants.Keys) { $Body = $Body.Replace($Token, $Variants[$Token]) }
			$Content = "$($Document.Content)$NewLine$NewLine## Container case$NewLine$NewLine$Body$NewLine"
			Set-Content -LiteralPath $FixtureProvenance -Value $SourceProvenance -NoNewline -Encoding utf8
			Set-FixtureReport -Content $PristineReport
			if ($Document.Name -eq 'register') { Set-Content -LiteralPath $FixtureProvenance -Value $Content -NoNewline -Encoding utf8 }
			else { Set-FixtureReport -Content $Content }
			try {
				if ($Case.Visible) { Assert-Throws -Pattern $Document.Pattern -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot } }
				else { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot }
				Write-Host "Container regression PASS: $($Document.Name)/$CaseName"
			}
			catch {
				$Failure = "$($Document.Name)/${CaseName}: $($_.Exception.Message)"
				$ContainerFailures.Add($Failure)
				Write-Host "Container regression FAIL: $Failure"
			}
		}
	}
	if ($ContainerFailures.Count -gt 0) { throw "Container regression failures ($($ContainerFailures.Count)):`n$($ContainerFailures -join "`n")" }
	Set-Content -LiteralPath $FixtureProvenance -Value $SourceProvenance -NoNewline -Encoding utf8
	Set-FixtureReport -Content $PristineReport

	# Governance records must be visible Markdown tables. Exercise both source
	# documents with the same comment boundaries; only fixture report bytes are
	# re-stamped, never the source report or manifest.
	$CommentFailures = [System.Collections.Generic.List[string]]::new()
	foreach ($Document in @(
		@{ Name = 'register'; Content = $SourceProvenance; Header = $GovernanceHeader; NewLine = $ProvenanceNewLine; Pattern = 'Per-asset governance table in asset-provenance\.md must declare exactly one applicable header; found 0' },
		@{ Name = 'report'; Content = $PristineReport; Header = $ReportHeader; NewLine = $ReportNewLine; Pattern = 'Per-asset classification table in issue-95-opening-screen-commonui-validation\.md must declare exactly one applicable header; found 0' }
	)) {
		$Content = $Document.Content
		$NewLine = $Document.NewLine
		$Start = $Content.IndexOf($Document.Header, [System.StringComparison]::Ordinal)
		$End = $Content.IndexOf("$NewLine$NewLine", $Start, [System.StringComparison]::Ordinal)
		if ($End -lt 0) { $End = $Content.Length }
		$TableBlock = $Content.Substring($Start, $End - $Start)
		$CommentCases = [System.Collections.Generic.List[object]]::new()
		foreach ($IndentWidth in @(0, 3)) {
			foreach ($Closed in @($true, $false)) {
				$Opening = (' ' * $IndentWidth) + '<!--' + $NewLine
				$Closing = if ($Closed) { "$NewLine-->" } else { '' }
				$CommentCases.Add(@{
					Name = "hidden-table-indent-$IndentWidth-closed-$Closed"
					Content = $Content.Substring(0, $Start) + $Opening + $TableBlock + $Closing + $Content.Substring($End)
					Hidden = $true
				})
			}
		}
		# A closed comment does not make a later opener on the same line visible.
		# Cover both the opening line and a continued comment's closing line.
		$AdjacentOpenings = @(
			'<!-- note --> <!--',
			'   <!-- first --><!-- second --><!--',
			"<!-- first$NewLine--> <!--",
			"<!-- first$NewLine    --> <!-- second --> <!--"
		)
		for ($OpeningIndex = 0; $OpeningIndex -lt $AdjacentOpenings.Count; $OpeningIndex++) {
			foreach ($Closed in @($true, $false)) {
				$Closing = if ($Closed) { "$NewLine$NewLine-->" } else { '' }
				$CommentCases.Add(@{
					Name = "adjacent-hidden-table-opening-$OpeningIndex-closed-$Closed"
					Content = $Content.Substring(0, $Start) + $AdjacentOpenings[$OpeningIndex] + $NewLine + $TableBlock + $Closing + $Content.Substring($End)
					Hidden = $true
				})
			}
			$CommentCases.Add(@{
				Name = "visible-table-after-adjacent-comments-$OpeningIndex"
				Content = $AdjacentOpenings[$OpeningIndex] + " closed -->$NewLine$NewLine" + $Content
				Hidden = $false
			})
		}
		$Prefixes = @(
			"<!-- closed on the opening line -->$NewLine$NewLine",
			"<!--$NewLine$TableBlock$NewLine-->$NewLine$NewLine",
			"<!--$NewLine~~~markdown$NewLine$TableBlock$NewLine    -->$NewLine$NewLine",
			"${BacktickFence}markdown$NewLine<!--$NewLine$BacktickFence$NewLine$NewLine",
			"~~~markdown$NewLine<!--$NewLine~~~$NewLine$NewLine",
			"    <!--$NewLine$NewLine",
			"`t<!--$NewLine$NewLine"
		)
		foreach ($SpaceCount in 1..3) { $Prefixes += (' ' * $SpaceCount) + "`t<!--$NewLine$NewLine" }
		for ($PrefixIndex = 0; $PrefixIndex -lt $Prefixes.Count; $PrefixIndex++) {
			$CommentCases.Add(@{ Name = "visible-table-after-prefix-$PrefixIndex"; Content = $Prefixes[$PrefixIndex] + $Content; Hidden = $false })
		}
		# Quoted tag attributes on a comment's closing line are literal text.
		# They must neither hide the sole table nor conceal a conflicting duplicate.
		$DuplicateRow = if ($Document.Name -eq 'register') { $MainRegisterRow } else { $MainReportRow }
		$PermissionIndex = if ($Document.Name -eq 'register') { 3 } else { 4 }
		$ContradictoryRow = Set-MarkdownTableCell -Row $DuplicateRow -Index $PermissionIndex -Value 'Approved for runtime use.'
		$ContradictoryTable = $TableBlock.Replace($DuplicateRow, $ContradictoryRow)
		foreach ($Quote in @('"', "'")) {
			foreach ($Continued in @($false, $true)) {
				$CommentStart = if ($Continued) { "<!-- note$NewLine--> " } else { '<!-- note --> ' }
				$TagPrefix = $CommentStart + '<span title=' + $Quote + '<!--' + $Quote + '></span>'
				$CaseSuffix = "quote-$([int][char]$Quote)-continued-$Continued"
				$CommentCases.Add(@{
					Name = "visible-table-after-quoted-attribute-$CaseSuffix"
					Content = "$TagPrefix$NewLine$NewLine$Content"
					Hidden = $false
				})
				$CommentCases.Add(@{
					Name = "visible-duplicate-after-quoted-attribute-$CaseSuffix"
					Content = "$Content$NewLine$NewLine$TagPrefix$NewLine$NewLine$ContradictoryTable$NewLine"
					ExpectedPattern = ($Document.Pattern -replace 'found 0$', 'found 2')
				})
				$CommentCases.Add(@{
					Name = "real-comment-after-quoted-attribute-$CaseSuffix"
					Content = "$TagPrefix <!--$NewLine$NewLine$Content"
					Hidden = $true
				})
				$CommentCases.Add(@{
					Name = "unsupported-tag-after-comment-$CaseSuffix"
					Content = $CommentStart + '<span title=' + $Quote + "<!--$NewLine$NewLine$Content"
					ExpectedPattern = 'Unsupported trailing HTML construct after a comment on line [0-9]+; use complete single-line tags'
				})
			}
		}
		# Comments whose closer reuses the opener's dashes (`<!-->`, `<!--->`) end on
		# their own line, like `<!---->` and ordinary comments: alone they hide
		# nothing, and a visible duplicate table after them must still conflict.
		foreach ($ShortComment in @('<!-->', '<!--->', '<!---->', '<!-- note -->')) {
			$CaseSuffix = "length-$($ShortComment.Length)"
			$CommentCases.Add(@{
				Name = "visible-table-after-short-comment-$CaseSuffix"
				Content = "$ShortComment$NewLine$NewLine$Content"
				Hidden = $false
			})
			$CommentCases.Add(@{
				Name = "visible-duplicate-after-short-comment-$CaseSuffix"
				Content = "$Content$NewLine$NewLine$ShortComment$NewLine$NewLine$ContradictoryTable$NewLine"
				ExpectedPattern = ($Document.Pattern -replace 'found 0$', 'found 2')
			})
		}

		foreach ($CommentCase in $CommentCases) {
			Set-Content -LiteralPath $FixtureProvenance -Value $SourceProvenance -NoNewline -Encoding utf8
			Set-FixtureReport -Content $PristineReport
			if ($Document.Name -eq 'register') {
				Set-Content -LiteralPath $FixtureProvenance -Value $CommentCase.Content -NoNewline -Encoding utf8
			}
			else { Set-FixtureReport -Content $CommentCase.Content }
			try {
				if ($CommentCase.ContainsKey('ExpectedPattern')) {
					Assert-Throws -Pattern $CommentCase.ExpectedPattern -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot }
				}
				elseif ($CommentCase.Hidden) {
					Assert-Throws -Pattern $Document.Pattern -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot }
				}
				else { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot }
				Write-Host "HTML comment regression PASS: $($Document.Name)/$($CommentCase.Name)"
			}
			catch {
				$Failure = "$($Document.Name)/$($CommentCase.Name): $($_.Exception.Message)"
				$CommentFailures.Add($Failure)
				Write-Host "HTML comment regression FAIL: $Failure"
			}
		}
	}
	if ($CommentFailures.Count -gt 0) { throw "HTML comment regression failures ($($CommentFailures.Count)):`n$($CommentFailures -join "`n")" }
	Set-Content -LiteralPath $FixtureProvenance -Value $SourceProvenance -NoNewline -Encoding utf8
	Set-FixtureReport -Content $PristineReport
	& (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) {
		Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
	}
}

Write-Host 'Visual-package validation regression checks passed.'
