[CmdletBinding()]
param()

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

function Set-MarkdownTableCell {
	param(
		[Parameter(Mandatory)][string] $Row,
		[Parameter(Mandatory)][int] $Index,
		[Parameter(Mandatory)][AllowEmptyString()][string] $Value
	)

	$Trimmed = $Row.Trim()
	if (-not $Trimmed.StartsWith('|') -or -not $Trimmed.EndsWith('|')) {
		throw "Malformed Markdown table fixture row: $Row"
	}
	$Cells = @($Trimmed.Substring(1, $Trimmed.Length - 2) -split '\|' | ForEach-Object { $_.Trim() })
	if ($Index -lt 0 -or $Index -ge $Cells.Count) {
		throw "Markdown table fixture cell index $Index is outside the $($Cells.Count)-cell row."
	}
	$Cells[$Index] = $Value
	'| ' + ($Cells -join ' | ') + ' |'
}

function Copy-MarkdownTableCells {
	param(
		[Parameter(Mandatory)][string] $TargetRow,
		[Parameter(Mandatory)][int] $TargetStartIndex,
		[Parameter(Mandatory)][string] $SourceRow,
		[Parameter(Mandatory)][int] $SourceStartIndex,
		[Parameter(Mandatory)][int] $Count
	)

	$SourceTrimmed = $SourceRow.Trim()
	if (-not $SourceTrimmed.StartsWith('|') -or -not $SourceTrimmed.EndsWith('|')) {
		throw "Malformed Markdown table fixture source row: $SourceRow"
	}
	$SourceCells = @($SourceTrimmed.Substring(1, $SourceTrimmed.Length - 2) -split '\|' | ForEach-Object { $_.Trim() })
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

if (-not (Test-Path -LiteralPath $Validator -PathType Leaf)) {
	throw "Validator is missing: $Validator"
}

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

	$PromptGovernanceRow = Get-ProvenanceRow -Content $PristineProvenance -Path ([string]$PromptAsset.path)
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
			Pattern    = 'Per-asset governance table in asset-provenance\.md separator row immediately after its header has invalid cell 1'
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
			Pattern = 'Per-asset classification table in issue-95-opening-screen-commonui-validation\.md separator row immediately after its header has invalid cell 1'
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
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) {
		Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
	}
}

Write-Host 'Visual-package validation regression checks passed.'
