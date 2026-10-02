[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Checker = Join-Path $RepositoryRoot 'scripts/ci/Test-FormattingPolicy.ps1'
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("AethelnFormattingPolicyTests-{0}" -f [guid]::NewGuid().ToString('N'))

function Assert-True {
	param(
		[Parameter(Mandatory)]
		[bool] $Condition,
		[Parameter(Mandatory)]
		[string] $Message
	)

	if (-not $Condition) {
		throw "Assertion failed: $Message"
	}
}

function Invoke-FixtureGit {
	param(
		[Parameter(Mandatory)]
		[string] $Root,
		[Parameter(Mandatory)]
		[string[]] $Arguments
	)

	$PreviousPreference = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		$Output = @(& git -C $Root @Arguments 2>&1 | ForEach-Object { "$_" })
		$ExitCode = $LASTEXITCODE
	}
	finally {
		$ErrorActionPreference = $PreviousPreference
	}
	if ($ExitCode -ne 0) {
		throw "git $($Arguments -join ' ') failed: $($Output -join [Environment]::NewLine)"
	}
}

function New-FixtureRepository {
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)]
		[string] $Root,
		[Parameter(Mandatory)]
		[hashtable] $Files
	)

	if (-not $PSCmdlet.ShouldProcess($Root, 'Create a Git fixture repository and its working files')) {
		return
	}

	New-Item -ItemType Directory -Path $Root -Force | Out-Null
	Invoke-FixtureGit -Root $Root -Arguments @('init', '-q')
	Invoke-FixtureGit -Root $Root -Arguments @('config', 'core.autocrlf', 'false')
	foreach ($RelativePath in $Files.Keys) {
		$FullPath = Join-Path $Root $RelativePath
		$Directory = Split-Path -Parent $FullPath
		if (-not (Test-Path -LiteralPath $Directory)) {
			New-Item -ItemType Directory -Path $Directory -Force | Out-Null
		}
		[System.IO.File]::WriteAllText($FullPath, $Files[$RelativePath])
	}
	Invoke-FixtureGit -Root $Root -Arguments @('add', '-A')
}

function Invoke-ExpectedFailure {
	param(
		[Parameter(Mandatory)]
		[string] $Root,
		[Parameter(Mandatory)]
		[string] $ExpectedPattern
	)

	$FailureMessage = $null
	try {
		& $Checker -RepositoryRoot $Root | Out-Null
	}
	catch {
		$FailureMessage = $_.Exception.Message
	}

	Assert-True -Condition ($null -ne $FailureMessage) -Message "Expected formatting validation to fail for fixture '$Root'."
	Assert-True -Condition ($FailureMessage -match $ExpectedPattern) -Message "Failure '$FailureMessage' did not match '$ExpectedPattern'."
}

$ConflictMarker = ('<' * 7) + ' HEAD'

try {
	New-Item -ItemType Directory -Path $FixtureRoot | Out-Null

	$DeclinedRoot = Join-Path $FixtureRoot 'declined'
	New-FixtureRepository -Root $DeclinedRoot -Files @{ 'docs/declined.md' = "# Declined`n" } -WhatIf
	Assert-True -Condition (-not (Test-Path -LiteralPath $DeclinedRoot)) -Message 'A declined fixture must not create its directory, its Git repository, or its files.'
	Write-Output 'PASS: fixture repository creation is declined without mutating the filesystem'

	$CleanRoot = Join-Path $FixtureRoot 'clean'
	New-FixtureRepository -Root $CleanRoot -Files @{
		'docs/clean.md' = "# Clean`n`nBody text.`n"
		'docs/setext.md' = "Setext Title`n$('=' * 9)`n`nBody.`n"
		'Source/GameCore/Private/Clean.cpp' = "void Clean()`n{`n`tint Value = 0;`n}`n"
		'Content/Maps/Real.umap' = "`0`0/Game/Maps/Real`0"
		'Content/Maps/Pointer.umap' = "version https://git-lfs.github.com/spec/v1`noid sha256:$('0' * 64)`nsize 1`n"
		'AethelnOnline.uproject' = "{`n`t`"Plugins`": [ { `"Name`": `"EnhancedInput`", `"Enabled`": true } ]`n}`n"
	}
	$CleanOutput = & $Checker -RepositoryRoot $CleanRoot | Out-String
	Assert-True -Condition ($CleanOutput -match 'Formatting policy checks passed\.') -Message 'A clean LF, marker-free, tab-indented repository should pass.'
	Assert-True -Condition ($CleanOutput -match 'scanned 3 tracked files; 1 LFS pointer files not scanned') -Message "The private art boundary must report scanned and pointer-only files honestly: $CleanOutput"
	Write-Output 'PASS: clean repository with tab-indented C++, a setext underline, a real asset, and an LFS pointer passes'

	$ArtAssetRoot = Join-Path $FixtureRoot 'art-asset'
	New-FixtureRepository -Root $ArtAssetRoot -Files @{ 'Content/Maps/Leak.umap' = "`0`0/AethelnArt/Meshes/SM_Rock`0" }
	Invoke-ExpectedFailure -Root $ArtAssetRoot -ExpectedPattern 'Content/Maps/Leak\.umap: references the private AethelnArt plugin'
	Write-Output 'PASS: a binary public asset referencing /AethelnArt/ is rejected'

	$FakePointerRoot = Join-Path $FixtureRoot 'fake-pointer'
	New-FixtureRepository -Root $FakePointerRoot -Files @{ 'Content/Maps/Fake.umap' = "version https://git-lfs.github.com/spec/v1`n`0/AethelnArt/Maps/Art`0" }
	Invoke-ExpectedFailure -Root $FakePointerRoot -ExpectedPattern 'Content/Maps/Fake\.umap: references the private AethelnArt plugin'
	Write-Output 'PASS: a pointer-like header without oid and size lines is scanned, not skipped'

	$UnicodeRoot = Join-Path $FixtureRoot 'unicode-path'
	New-FixtureRepository -Root $UnicodeRoot -Files @{ "Content/Maps/Caf$([char]0xE9) Map.umap" = "`0`0/AethelnArt/Maps/Art`0" }
	Invoke-ExpectedFailure -Root $UnicodeRoot -ExpectedPattern "Content/Maps/Caf$([char]0xE9) Map\.umap: references the private AethelnArt plugin"
	Write-Output 'PASS: a non-ASCII tracked path is listed, scanned, and reported by its real name'

	$MissingRoot = Join-Path $FixtureRoot 'missing'
	New-FixtureRepository -Root $MissingRoot -Files @{ 'Content/Maps/Gone.umap' = "`0`0/Game/Maps/Gone`0" }
	Remove-Item -LiteralPath (Join-Path $MissingRoot 'Content/Maps/Gone.umap')
	Invoke-ExpectedFailure -Root $MissingRoot -ExpectedPattern 'Content/Maps/Gone\.umap: tracked file is missing from the work tree'
	Write-Output 'PASS: a tracked file missing from the work tree fails instead of being skipped'

	$ArtConfigRoot = Join-Path $FixtureRoot 'art-config'
	New-FixtureRepository -Root $ArtConfigRoot -Files @{ 'Config/DefaultEngine.ini' = "[/Script/EngineSettings.GameMapsSettings]`nGameDefaultMap=/AethelnArt/Maps/Art.Art`n" }
	Invoke-ExpectedFailure -Root $ArtConfigRoot -ExpectedPattern 'Config/DefaultEngine\.ini: references the private AethelnArt plugin'
	Write-Output 'PASS: public config referencing /AethelnArt/ is rejected'

	$ArtPluginRoot = Join-Path $FixtureRoot 'art-plugin'
	New-FixtureRepository -Root $ArtPluginRoot -Files @{ 'AethelnOnline.uproject' = "{`n`t`"Plugins`": [ { `"Name`": `"AethelnArt`", `"Enabled`": true, `"Optional`": true } ]`n}`n" }
	Invoke-ExpectedFailure -Root $ArtPluginRoot -ExpectedPattern 'AethelnOnline\.uproject: references the private AethelnArt plugin'
	Write-Output 'PASS: listing AethelnArt as a .uproject plugin dependency is rejected'

	$CrlfRoot = Join-Path $FixtureRoot 'crlf'
	New-FixtureRepository -Root $CrlfRoot -Files @{
		'docs/bad-endings.md' = "# Bad`r`n`r`nCarriage returns.`r`n"
	}
	Invoke-ExpectedFailure -Root $CrlfRoot -ExpectedPattern 'docs/bad-endings\.md.*i/crlf'
	Write-Output 'PASS: committed CRLF text file is rejected with its path'

	$ConflictRoot = Join-Path $FixtureRoot 'conflict'
	New-FixtureRepository -Root $ConflictRoot -Files @{
		'docs/conflicted.md' = "# Doc`n`n$ConflictMarker`nours`n"
	}
	Invoke-ExpectedFailure -Root $ConflictRoot -ExpectedPattern 'docs/conflicted\.md.*merge-conflict marker'
	Write-Output 'PASS: committed merge-conflict marker is rejected with its path'

	$SeparatorRoot = Join-Path $FixtureRoot 'separator'
	New-FixtureRepository -Root $SeparatorRoot -Files @{
		'docs/separated.md' = "# Doc`n`nours`n$('=' * 7)`ntheirs`n"
	}
	Invoke-ExpectedFailure -Root $SeparatorRoot -ExpectedPattern 'docs/separated\.md.*merge-conflict marker'
	Write-Output 'PASS: an exactly-seven-equals conflict separator is rejected'

	$SpaceIndentRoot = Join-Path $FixtureRoot 'space-indent'
	New-FixtureRepository -Root $SpaceIndentRoot -Files @{
		'Source/GameCore/Private/Spaces.cpp' = "void Spaces()`n{`n    int Value = 0;`n}`n"
	}
	Invoke-ExpectedFailure -Root $SpaceIndentRoot -ExpectedPattern 'Source/GameCore/Private/Spaces\.cpp:3.*tab indentation'
	Write-Output 'PASS: space-indented C++ under Source/ is rejected with file and line'

	Write-Output 'All formatting policy tests passed.'
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) {
		Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
	}
}
