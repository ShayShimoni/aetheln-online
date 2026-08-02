[CmdletBinding()]
param(
	[string] $Root = $PSScriptRoot,
	[int] $RequiredAssetCount = 103,
	[int] $RequiredTotalFileCount = 107
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = (Resolve-Path -LiteralPath $Root).Path
$ManifestPath = Join-Path $Root 'package-manifest.json'
$ProvenancePath = Join-Path $Root 'asset-provenance.md'
$PromptPath = Join-Path $Root 'generation-prompts.md'
$GovernancePaths = @(
	'package-manifest.json',
	'asset-provenance.md',
	'Test-VisualPackage.ps1',
	'tests/Test-VisualPackageValidation.ps1'
)
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
Assert-Condition (@($ManifestPaths | Sort-Object -Unique).Count -eq @($ManifestPaths).Count) 'Manifest contains duplicate paths.'
foreach ($RelativePath in $ManifestPaths) {
	Assert-Condition ($RelativePath -notmatch '^[A-Za-z]:[/\\]' -and $RelativePath -notmatch '^[/\\]' -and $RelativePath -notmatch '(^|/)\.\.(/|$)' -and $RelativePath -notmatch '\\') "Manifest paths must be normalized relative paths: $RelativePath"
}

$ActualAssetPaths = @(Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object { Get-RelativeVisualPath $_.FullName } | Where-Object { $_ -notin $GovernancePaths } | Sort-Object)
$ExpectedAssetPaths = @($ManifestPaths | Sort-Object)
Assert-Condition (($ActualAssetPaths -join "`n") -eq ($ExpectedAssetPaths -join "`n")) 'Package inventory differs from the manifest inventory.'
$ActualTotal = @(Get-ChildItem -LiteralPath $Root -Recurse -File).Count
Assert-Condition ($ActualTotal -eq $Manifest.expectedTotalFileCount) "Package contains $ActualTotal files; expected $($Manifest.expectedTotalFileCount)."

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
	'License or permission evidence by source class',
	'Owner-supplied legacy package',
	'Owner-directed issue #114 generation',
	'Repository-hardened text derivatives',
	'Pending/TBD',
	'No row in this register grants public distribution'
)) {
	Assert-Condition ($Provenance.Contains($Required)) "Provenance permission coverage missing: $Required"
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
