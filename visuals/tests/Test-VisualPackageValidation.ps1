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
	$PromptAsset = @($Manifest.assets | Where-Object path -eq 'generation-prompts.md')[0]
	$ReportRelativePath = 'issue-95-opening-screen-commonui-validation.md'
	$ReportAsset = @($Manifest.assets | Where-Object path -eq $ReportRelativePath)[0]
	$AssetPath = Join-Path $VisualRoot ($FirstAsset.path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
	$FixtureAssetPath = Join-Path $FixtureRoot ($FirstAsset.path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
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
	$PristineProvenance = Get-Content -Raw -LiteralPath (Join-Path $VisualRoot 'asset-provenance.md')
	$FixtureProvenance = Join-Path $FixtureRoot 'asset-provenance.md'
	$GovernanceHeader = '| Path | Provenance/custody | Authorship | Permission | License | Product approval |'
	$RowPattern = '(?m)^\| `' + [regex]::Escape($FirstAssetPath) + '` \|.*$'
	if (-not $PristineProvenance.Contains($GovernanceHeader)) {
		throw "Provenance is missing the five-state governance header: $GovernanceHeader"
	}
	if ($PristineProvenance -notmatch $RowPattern) {
		throw "Provenance is missing a per-asset governance row for $($FirstAssetPath)."
	}

	foreach ($Case in @(
		@{
			Provenance = $PristineProvenance.Replace($GovernanceHeader, '| Path | Provenance/custody | Authorship | Permission | License |')
			Pattern    = 'governance table in asset-provenance.md must declare 6 columns'
		},
		@{
			Provenance = [regex]::Replace($PristineProvenance, $RowPattern, "| ``$($FirstAssetPath)`` | Custody recorded. |  | Permission recorded. | License recorded. | Not approved. |")
			Pattern    = "Governance state 'Authorship' is blank for $([regex]::Escape($FirstAssetPath))"
		},
		@{
			Provenance = [regex]::Replace($PristineProvenance, $RowPattern, "| ``$($FirstAssetPath)`` | Custody recorded; permission is Pending/TBD. | Author recorded. | Permission recorded. | License recorded. | Not approved. |")
			Pattern    = "Governance state 'Provenance/custody' for $([regex]::Escape($FirstAssetPath)) .* aggregates other states \(permission\)"
		},
		@{
			Provenance = [regex]::Replace($PristineProvenance, $RowPattern, "| ``$($FirstAssetPath)`` | Pending/TBD: authorship, permission, and license evidence unresolved. | Author recorded. | Permission recorded. | License recorded. | Not approved. |")
			Pattern    = "Governance state 'Provenance/custody' for $([regex]::Escape($FirstAssetPath)) .* aggregates other states"
		}
	)) {
		Set-Content -LiteralPath $FixtureProvenance -Value $Case.Provenance -NoNewline -Encoding utf8
		Assert-Throws -Pattern $Case.Pattern -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 2 -RequiredTotalFileCount 6 }
	}

	Set-Content -LiteralPath $FixtureProvenance -Value $PristineProvenance -NoNewline -Encoding utf8
	& (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 2 -RequiredTotalFileCount 6

	# The Issue #95 report must keep visual suitability and allowed current use
	# separate from the five governance states, and record each governance state
	# independently for every reviewed asset. The report is a manifested asset, so
	# each fixture variant re-stamps its hash and byte length before validation.
	$FixtureReport = Join-Path $FixtureRoot $ReportRelativePath
	$PristineReport = Get-Content -Raw -LiteralPath (Join-Path $VisualRoot $ReportRelativePath)
	$Manifest.assets = @($FirstAsset, $PromptAsset, $ReportAsset)
	$Manifest.expectedAssetCount = 3
	$Manifest.expectedTotalFileCount = 7

	function Set-FixtureReport {
		param([Parameter(Mandatory)][AllowEmptyString()][string] $Content)
		Set-Content -LiteralPath $FixtureReport -Value $Content -NoNewline -Encoding utf8
		$ReportAsset.sha256 = (Get-FileHash -LiteralPath $FixtureReport -Algorithm SHA256).Hash.ToLowerInvariant()
		$ReportAsset.bytes = (Get-Item -LiteralPath $FixtureReport).Length
		$Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $FixtureRoot 'package-manifest.json') -Encoding utf8
	}

	$ReportHeader = '| Reviewed asset | Visual suitability | Provenance/custody | Authorship | Permission | License | Product approval | Allowed current use |'
	$ReportRowPattern = '(?m)^\| `01-main-menu-concept\.png` \|.*$'
	if (-not $PristineReport.Contains($ReportHeader)) {
		throw "Issue #95 report is missing the eight-column classification header: $ReportHeader"
	}
	if ($PristineReport -notmatch $ReportRowPattern) {
		throw 'Issue #95 report is missing the reviewed-asset row for 01-main-menu-concept.png.'
	}

	Set-FixtureReport -Content $PristineReport
	& (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 3 -RequiredTotalFileCount 7

	foreach ($Case in @(
		@{
			Report  = $PristineReport.Replace($ReportHeader, '| Reviewed asset | Visual suitability | Provenance/custody | Authorship | Permission | Product approval | Allowed current use |')
			Pattern = 'classification table in issue-95-opening-screen-commonui-validation\.md must declare 8 columns'
		},
		@{
			Report  = [regex]::Replace($PristineReport, $ReportRowPattern, '| `01-main-menu-concept.png` | Suitable reference. | Custody recorded. | Author recorded. |  | License recorded. | Not approved. | Reference-only. |')
			Pattern = "Governance state 'Permission' is blank for ``01-main-menu-concept\.png``"
		},
		@{
			Report  = [regex]::Replace($PristineReport, $ReportRowPattern, '| `01-main-menu-concept.png` | Suitable reference. | Pending/TBD: authorship, permission, and license evidence unresolved. | Author recorded. | Permission recorded. | License recorded. | Not approved. | Reference-only. |')
			Pattern = "Governance state 'Provenance/custody' for ``01-main-menu-concept\.png`` .* aggregates other states"
		}
	)) {
		Set-FixtureReport -Content $Case.Report
		Assert-Throws -Pattern $Case.Pattern -Action { & (Join-Path $FixtureRoot 'Test-VisualPackage.ps1') -Root $FixtureRoot -RequiredAssetCount 3 -RequiredTotalFileCount 7 }
	}
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) {
		Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
	}
}

Write-Host 'Visual-package validation regression checks passed.'
