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
$AcceptedGovernanceValues = [ordered]@{
	'Provenance/custody' = @(
		'Owner-directed concept generated through the built-in image-generation workflow for issue #114; frozen external ingest.',
		'Owner-supplied authoring utility; imported through attested external ingest and repository-hardened by issue #94.',
		'Owner-supplied legacy visual package; byte-preserved through attested external ingest.',
		'Owner-supplied legacy visual-package guidance; repository governance and current owner-approved concept direction updated by issue #94 after attested ingest.',
		'Owner-supplied legacy visual-package guidance; repository references and governance handoff updated by issue #94 after attested ingest.',
		'Repository-authored Issue #95 visual-review and CommonUI planning report derived from canonical and imported-package evidence.'
	)
	'Authorship' = @(
		'**Pending/TBD**: no author identification is retained for the legacy package.',
		'Owner-directed generation through the built-in OpenAI image workflow, recorded by issue #114, `generation-prompts.md`, and C2PA `caBX` metadata.',
		'Repository-authored issue #94 modifications recorded in git history; authorship of the underlying legacy material is **Pending/TBD**.',
		'Repository-authored under issue #95 and recorded in git history.'
	)
	'Permission' = @(
		'**Pending/TBD**: no permission grant is retained in this repository.'
	)
	'License' = @(
		'**Pending/TBD**: no license instrument is retained in this repository.'
	)
	'Product approval' = @(
		'Not approved: no product approval is recorded; non-canonical planning/governance artifact that grants no asset rights, runtime approval, publication approval, or `Content/` promotion.',
		'Not approved: no product approval is recorded; non-canonical reference/source asset.'
	)
}
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

function Split-MarkdownTableRow {
	param([Parameter(Mandatory)][string] $Row)
	$Trimmed = $Row.Trim()
	Assert-Condition ($Trimmed.StartsWith('|') -and $Trimmed.EndsWith('|') -and $Trimmed.Length -ge 2) "Malformed Markdown table row: $Row"
	@($Trimmed.Substring(1, $Trimmed.Length - 2) -split '\|' | ForEach-Object { $_.Trim() })
}

function Find-TableHeaderIndex {
	param([Parameter(Mandatory)][AllowEmptyString()][string[]] $Lines, [Parameter(Mandatory)][string] $FirstColumn)
	for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
		if ($Lines[$Index].TrimEnd() -match ('^\|\s*' + [regex]::Escape($FirstColumn) + '\s*\|')) { return $Index }
	}
	-1
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

	$Trimmed = $Row.Trim()
	Assert-Condition ($Trimmed.StartsWith('|') -and $Trimmed.EndsWith('|') -and $Trimmed.Length -ge 2) "$Table separator row immediately after its header is missing or malformed: $Row"
	$Cells = @(Split-MarkdownTableRow -Row $Trimmed)
	Assert-Condition ($Cells.Count -eq $ExpectedCellCount) "$Table separator row immediately after its header must have exactly $ExpectedCellCount cells; found $($Cells.Count)."
	for ($Index = 0; $Index -lt $Cells.Count; $Index++) {
		Assert-Condition ($Cells[$Index] -cmatch '^:?-{3,}:?$') "$Table separator row immediately after its header has invalid cell $($Index + 1) '$($Cells[$Index])'; expected at least three hyphens with optional alignment colons."
	}
}

# Provenance/custody, authorship, permission, license, and product approval are
# five independent states. Each field has a closed contract derived from the
# reviewed register values; a new value requires an explicit validator update.
function Assert-GovernanceStates {
	param(
		[Parameter(Mandatory)][string] $Label,
		[Parameter(Mandatory)][AllowEmptyString()][string[]] $Values,
		[Parameter(Mandatory)][string] $Table
	)
	Assert-Condition ($Values.Count -eq $GovernanceFields.Count) "$Table row for $Label exposes $($Values.Count) governance states; expected $($GovernanceFields.Count) ($($GovernanceFields -join ', ')). Governance states must not be collapsed or omitted."
	for ($Index = 0; $Index -lt $GovernanceFields.Count; $Index++) {
		$Field = $GovernanceFields[$Index]
		$Value = $Values[$Index]
		Assert-Condition (-not [string]::IsNullOrWhiteSpace($Value)) "Governance state '$Field' is blank for $Label in $Table; record the known value, or record '**Pending/TBD**' when it is unknown."
		$NormalizedValue = ConvertTo-NormalizedGovernanceValue -Field $Field -Value $Value
		$NormalizedAcceptedValues = @($AcceptedGovernanceValues[$Field] | ForEach-Object { ConvertTo-NormalizedGovernanceValue -Field $Field -Value $_ })
		Assert-Condition ($NormalizedAcceptedValues -contains $NormalizedValue) "Governance state '$Field' has unrecognized value for $Label in ${Table}: '$Value'. Update the explicit accepted-value contract only after governance review."
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
$RegisterHeaderIndex = Find-TableHeaderIndex -Lines $ProvenanceLines -FirstColumn 'Path'
Assert-Condition ($RegisterHeaderIndex -ge 0) "$RegisterTable is missing; expected a header row starting with '| Path |'."

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
	if ([string]::IsNullOrWhiteSpace($Trimmed) -or -not $Trimmed.StartsWith('|')) { break }
	$Cells = Split-MarkdownTableRow -Row $Trimmed
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
	Assert-GovernanceStates -Label $RelativePath -Values $Cells[1..($Cells.Count - 1)] -Table $RegisterTable
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
	$ReportHeaderIndex = Find-TableHeaderIndex -Lines $ReportLines -FirstColumn 'Reviewed asset'
	Assert-Condition ($ReportHeaderIndex -ge 0) "$ReportTable is missing; expected a header row starting with '| Reviewed asset |'."

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
		if (-not $Trimmed.StartsWith('|')) { break }
		$Cells = Split-MarkdownTableRow -Row $Trimmed
		$Label = $Cells[0]
		Assert-Condition (-not [string]::IsNullOrWhiteSpace($Label)) "$ReportTable contains a row with no reviewed-asset name: $Trimmed"
		Assert-Condition ($RequiredReviewedAssetRecords.Contains($Label)) "Unexpected reviewed-asset record in ${ReportTable}: $Label"
		Assert-Condition (-not $ReviewedAssetRows.ContainsKey($Label)) "Duplicate reviewed-asset record in ${ReportTable}: $Label"
		Assert-Condition ($Cells.Count -eq $ReportHeader.Count) "$ReportTable row for $Label has $($Cells.Count) cells; expected $($ReportHeader.Count) ($($ReportHeader -join ', ')). Governance states must not be collapsed or omitted."
		Assert-Condition (-not [string]::IsNullOrWhiteSpace($Cells[1])) "Visual suitability is blank for $Label in $ReportTable."
		Assert-Condition (-not [string]::IsNullOrWhiteSpace($Cells[$ReportHeader.Count - 1])) "Allowed current use is blank for $Label in $ReportTable."
		Assert-GovernanceStates -Label $Label -Values $Cells[2..($Cells.Count - 2)] -Table $ReportTable
		$ReviewedAssetRows.Add($Label, $Cells)
	}
	foreach ($Label in $RequiredReviewedAssetRecords.Keys) {
		Assert-Condition ($ReviewedAssetRows.ContainsKey($Label)) "Required reviewed-asset record missing from ${ReportTable}: $Label"
		$ReportGovernanceValues = $ReviewedAssetRows[$Label][2..($ReportHeader.Count - 2)]
		foreach ($RegisterPath in @($RequiredReviewedAssetRecords[$Label])) {
			Assert-Condition ($GovernanceRows.ContainsKey($RegisterPath)) "Provenance register row missing for reviewed asset ${Label}: $RegisterPath"
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
