[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Checker = Join-Path $RepositoryRoot 'scripts/ci/Test-MarkdownLinks.ps1'
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("AethelnMarkdownLinkTests-{0}" -f [guid]::NewGuid().ToString('N'))

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
	param(
		[Parameter(Mandatory)]
		[string] $Root,
		[Parameter(Mandatory)]
		[hashtable] $Files
	)

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

	Assert-True -Condition ($null -ne $FailureMessage) -Message "Expected link validation to fail for fixture '$Root'."
	Assert-True -Condition ($FailureMessage -match $ExpectedPattern) -Message "Failure '$FailureMessage' did not match '$ExpectedPattern'."
}

$BetaDocument = "# Beta Doc`n`n## Beta Section`n`nBody.`n"

try {
	New-Item -ItemType Directory -Path $FixtureRoot | Out-Null

	$ValidRoot = Join-Path $FixtureRoot 'valid'
	New-FixtureRepository -Root $ValidRoot -Files @{
		'docs/a.md' = @(
			'# Alpha Doc',
			'',
			'## Dawn Concordat - Working Name',
			'',
			'## Uses_Underscore Heading',
			'',
			'[relative](b.md) and [cross anchor](b.md#beta-section).',
			'[same-file anchor](#dawn-concordat---working-name)',
			'[underscore anchor](#uses_underscore-heading)',
			'[external](https://example.invalid/missing) [plain](http://example.invalid) [mail](mailto:nobody@example.invalid)',
			'',
			'```text',
			'[ignored inside fence](missing-inside-fence.md)',
			'```',
			''
		) -join "`n"
		'docs/b.md' = $BetaDocument
	}
	$ValidOutput = & $Checker -RepositoryRoot $ValidRoot | Out-String
	Assert-True -Condition ($ValidOutput -match 'Markdown link checks passed\.') -Message 'Valid relative links, anchors, external links, and fenced examples should pass.'
	Write-Output 'PASS: valid relative links, anchors, external targets, and fenced code examples'

	$BrokenTargetRoot = Join-Path $FixtureRoot 'broken-target'
	New-FixtureRepository -Root $BrokenTargetRoot -Files @{
		'docs/a.md' = "# Alpha Doc`n`nSee [missing](missing.md).`n"
	}
	Invoke-ExpectedFailure -Root $BrokenTargetRoot -ExpectedPattern 'docs/a\.md:3 -> missing\.md.*does not exist'
	Write-Output 'PASS: broken relative target is reported with file, line, and target'

	$BrokenAnchorRoot = Join-Path $FixtureRoot 'broken-anchor'
	New-FixtureRepository -Root $BrokenAnchorRoot -Files @{
		'docs/a.md' = "# Alpha Doc`n`nSee [bad cross anchor](b.md#no-such-section).`n"
		'docs/b.md' = $BetaDocument
	}
	Invoke-ExpectedFailure -Root $BrokenAnchorRoot -ExpectedPattern 'docs/a\.md:3 -> b\.md#no-such-section.*no-such-section'
	Write-Output 'PASS: broken cross-file anchor is reported'

	$BrokenSameFileAnchorRoot = Join-Path $FixtureRoot 'broken-same-file-anchor'
	New-FixtureRepository -Root $BrokenSameFileAnchorRoot -Files @{
		'docs/a.md' = "# Alpha Doc`n`nSee [bad anchor](#absent-heading).`n"
	}
	Invoke-ExpectedFailure -Root $BrokenSameFileAnchorRoot -ExpectedPattern 'docs/a\.md:3 -> #absent-heading.*absent-heading'
	Write-Output 'PASS: broken same-file anchor is reported'

	Write-Output 'All markdown link tests passed.'
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) {
		Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
	}
}
