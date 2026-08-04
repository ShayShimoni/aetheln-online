[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Runner = Join-Path $RepositoryRoot 'scripts/ci/Invoke-CiSuite.ps1'
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("AethelnCiSuiteTests-{0}" -f [guid]::NewGuid().ToString('N'))

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

function Invoke-Runner {
	param(
		[Parameter(Mandatory)]
		[string] $ManifestPath,
		[Parameter(Mandatory)]
		[string] $ReportPath
	)

	$PreviousPreference = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		$Output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Runner -ChecksPath $ManifestPath -ReportPath $ReportPath 2>&1 | ForEach-Object { "$_" })
		$ExitCode = $LASTEXITCODE
	}
	finally {
		$ErrorActionPreference = $PreviousPreference
	}
	return @{ Output = $Output; ExitCode = $ExitCode }
}

function Assert-CheckShape {
	param(
		[Parameter(Mandatory)] $Check
	)

	foreach ($Field in @('name', 'tier', 'status', 'durationSeconds', 'command', 'message')) {
		Assert-True -Condition ($null -ne $Check.PSObject.Properties[$Field]) -Message "Check '$($Check | ConvertTo-Json -Compress)' is missing field '$Field'."
	}
}

try {
	New-Item -ItemType Directory -Path $FixtureRoot | Out-Null

	$PassScript = Join-Path $FixtureRoot 'pass.ps1'
	[System.IO.File]::WriteAllText($PassScript, "Write-Output 'fixture pass output'`nexit 0`n")
	$FailScript = Join-Path $FixtureRoot 'fail.ps1'
	[System.IO.File]::WriteAllText($FailScript, "throw 'fixture failure text'`n")
	$AdvisoryFailScript = Join-Path $FixtureRoot 'advisory-fail.ps1'
	[System.IO.File]::WriteAllText($AdvisoryFailScript, "throw 'advisory fixture failure'`n")

	$AdvisoryManifest = Join-Path $FixtureRoot 'advisory-manifest.json'
	$AdvisoryChecks = @(
		@{ name = 'fixture-pass'; tier = 'required'; script = $PassScript },
		@{ name = 'fixture-command-pass'; tier = 'advisory'; command = "Write-Output 'command fixture output'; exit 0" },
		@{ name = 'fixture-advisory-fail'; tier = 'advisory'; script = $AdvisoryFailScript },
		@{ name = 'fixture-advisory-skip'; tier = 'advisory'; script = $PassScript; requiredModule = 'AethelnNoSuchModuleFixture' }
	)
	[System.IO.File]::WriteAllText($AdvisoryManifest, (ConvertTo-Json -InputObject $AdvisoryChecks -Depth 4))
	$AdvisoryReport = Join-Path $FixtureRoot 'advisory-report.json'

	$AdvisoryRun = Invoke-Runner -ManifestPath $AdvisoryManifest -ReportPath $AdvisoryReport
	Assert-True -Condition ($AdvisoryRun.ExitCode -eq 0) -Message "Advisory-only failures must exit 0, got $($AdvisoryRun.ExitCode): $($AdvisoryRun.Output -join "`n")"
	Assert-True -Condition (Test-Path -LiteralPath $AdvisoryReport) -Message 'The machine-readable report must be written.'
	$Report = (Get-Content -LiteralPath $AdvisoryReport -Raw) | ConvertFrom-Json
	foreach ($Field in @('schemaVersion', 'revision', 'startedUtc', 'finishedUtc', 'checks', 'summary')) {
		Assert-True -Condition ($null -ne $Report.PSObject.Properties[$Field]) -Message "Report is missing field '$Field'."
	}
	Assert-True -Condition (@($Report.checks).Count -eq 4) -Message 'Report must contain one record per manifest check.'
	foreach ($Check in $Report.checks) {
		Assert-CheckShape -Check $Check
	}
	$PassCheck = @($Report.checks | Where-Object { $_.name -eq 'fixture-pass' })[0]
	Assert-True -Condition ($PassCheck.status -eq 'passed' -and $PassCheck.tier -eq 'required') -Message 'The passing required check must be reported as passed.'
	$CommandCheck = @($Report.checks | Where-Object { $_.name -eq 'fixture-command-pass' })[0]
	Assert-True -Condition ($CommandCheck.status -eq 'passed' -and $CommandCheck.tier -eq 'advisory') -Message 'The passing command check must capture exit code 0 and be reported as passed.'
	Assert-True -Condition ($CommandCheck.command -match '-Command') -Message 'The report must record the -Command invocation for command checks.'
	Assert-True -Condition ($CommandCheck.message -match 'command fixture output') -Message 'The command check message must carry the captured output.'
	$AdvisoryFail = @($Report.checks | Where-Object { $_.name -eq 'fixture-advisory-fail' })[0]
	Assert-True -Condition ($AdvisoryFail.status -eq 'failed' -and $AdvisoryFail.tier -eq 'advisory') -Message 'The advisory failure must be reported as failed with tier advisory.'
	Assert-True -Condition ($AdvisoryFail.message -match 'advisory fixture failure') -Message 'The advisory failure message must carry the captured error text.'
	$Skipped = @($Report.checks | Where-Object { $_.name -eq 'fixture-advisory-skip' })[0]
	Assert-True -Condition ($Skipped.status -eq 'skipped' -and $Skipped.message -match 'AethelnNoSuchModuleFixture') -Message 'The module-gated check must be reported as skipped with a reason.'
	Assert-True -Condition ($Report.summary.requiredFailed -eq 0) -Message 'Advisory failures must not count as required failures.'
	Write-Output 'PASS: advisory failures and skips report machine-readably and exit 0'
	Write-Output 'PASS: a command manifest entry runs via -Command with its exit code captured'

	$RequiredManifest = Join-Path $FixtureRoot 'required-manifest.json'
	$RequiredChecks = @(
		@{ name = 'fixture-pass'; tier = 'required'; script = $PassScript },
		@{ name = 'fixture-required-fail'; tier = 'required'; script = $FailScript }
	)
	[System.IO.File]::WriteAllText($RequiredManifest, (ConvertTo-Json -InputObject $RequiredChecks -Depth 4))
	$RequiredReport = Join-Path $FixtureRoot 'required-report.json'

	$RequiredRun = Invoke-Runner -ManifestPath $RequiredManifest -ReportPath $RequiredReport
	Assert-True -Condition ($RequiredRun.ExitCode -ne 0) -Message 'A required-check failure must exit nonzero.'
	$Report = (Get-Content -LiteralPath $RequiredReport -Raw) | ConvertFrom-Json
	$FailCheck = @($Report.checks | Where-Object { $_.name -eq 'fixture-required-fail' })[0]
	Assert-True -Condition ($FailCheck.status -eq 'failed' -and $FailCheck.tier -eq 'required') -Message 'The required failure must be reported as failed.'
	Assert-True -Condition ($FailCheck.message -match 'fixture failure text') -Message 'The required failure message must carry the captured error text.'
	Assert-True -Condition ($FailCheck.command -match 'powershell\.exe') -Message 'The report must record the exact child command.'
	Assert-True -Condition ($Report.summary.requiredFailed -eq 1) -Message 'The summary must count the required failure.'
	Assert-True -Condition (($RequiredRun.Output -join "`n") -match 'fixture failure text') -Message 'The console output must include the actionable failure tail.'
	Write-Output 'PASS: a required-check failure exits nonzero with actionable output'

	Write-Output 'All CI suite runner tests passed.'
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) {
		Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
	}
}
