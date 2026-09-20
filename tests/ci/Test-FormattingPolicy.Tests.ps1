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
	}
	$CleanOutput = & $Checker -RepositoryRoot $CleanRoot | Out-String
	Assert-True -Condition ($CleanOutput -match 'Formatting policy checks passed\.') -Message 'A clean LF, marker-free, tab-indented repository should pass.'
	Write-Output 'PASS: clean repository with tab-indented C++ and a setext underline passes'

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
