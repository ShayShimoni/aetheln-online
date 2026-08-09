[CmdletBinding()]
param(
	[string] $ChecksPath,
	[string] $ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $ReportPath) {
	$ReportPath = Join-Path $RepositoryRoot 'TestResults\ci-report.json'
}

# Default manifest. Engine-dependent compile and packaged-smoke gates run in
# trusted self-hosted workflow jobs; their wrapper fixture suite runs here.
$DefaultChecks = @(
	@{ name = 'formatting-policy'; tier = 'required'; script = 'scripts/ci/Test-FormattingPolicy.ps1' },
	@{ name = 'markdown-links'; tier = 'required'; script = 'scripts/ci/Test-MarkdownLinks.ps1' },
	@{ name = 'source-control-policy'; tier = 'required'; script = 'scripts/tests/Test-SourceControlPolicy.ps1' },
	@{ name = 'build-packaged-artifacts-tests'; tier = 'required'; script = 'tests/build/Build-PackagedArtifacts.Tests.ps1' },
	@{ name = 'packaged-smoke-test-tests'; tier = 'required'; script = 'tests/build/Invoke-PackagedSmokeTest.Tests.ps1' },
	@{ name = 'server-cook-reference-tests'; tier = 'required'; script = 'tests/build/Validate-ServerCookReferences.Tests.ps1' },
	@{ name = 'target-composition-tests'; tier = 'required'; script = 'tests/build/Validate-TargetComposition.Tests.ps1' },
	@{ name = 'build-provenance-tests'; tier = 'required'; script = 'tests/build/Write-BuildProvenance.Tests.ps1' },
	@{ name = 'markdown-link-tests'; tier = 'required'; script = 'tests/ci/Test-MarkdownLinks.Tests.ps1' },
	@{ name = 'formatting-policy-tests'; tier = 'required'; script = 'tests/ci/Test-FormattingPolicy.Tests.ps1' },
	@{ name = 'ci-suite-tests'; tier = 'required'; script = 'tests/ci/Invoke-CiSuite.Tests.ps1' },
	@{ name = 'engine-runner-gate-tests'; tier = 'required'; script = 'tests/ci/Invoke-EngineRunnerGate.Tests.ps1' },
	@{ name = 'prototype-quality-workflow-tests'; tier = 'required'; script = 'tests/ci/Test-PrototypeQualityWorkflow.Tests.ps1' },
	@{
		name = 'psscriptanalyzer'
		tier = 'advisory'
		requiredModule = 'PSScriptAnalyzer'
		command = '$Findings = @(Invoke-ScriptAnalyzer -Path scripts, tests -Recurse); $Findings | Format-Table -AutoSize | Out-String -Width 200 | Write-Output; if ($Findings.Count -gt 0) { exit 1 } exit 0'
	}
)

function Get-CheckField {
	param(
		[Parameter(Mandatory)] $Check,
		[Parameter(Mandatory)][string] $Name,
		$Default = $null
	)

	if ($Check -is [hashtable]) {
		if ($Check.ContainsKey($Name)) {
			return $Check[$Name]
		}
		return $Default
	}
	$Property = $Check.PSObject.Properties[$Name]
	if ($null -ne $Property) {
		return $Property.Value
	}
	return $Default
}

function Get-OutputTail {
	param(
		[AllowEmptyCollection()][AllowEmptyString()][string[]] $Lines,
		[int] $MaximumLines = 40
	)

	$Lines = @($Lines | Where-Object { $null -ne $_ })
	if ($Lines.Count -gt $MaximumLines) {
		$Lines = @('...') + @($Lines | Select-Object -Last $MaximumLines)
	}
	return ($Lines -join "`n")
}

if ($ChecksPath) {
	$ParsedChecks = Get-Content -LiteralPath $ChecksPath -Raw | ConvertFrom-Json
	$Checks = @($ParsedChecks)
}
else {
	$Checks = $DefaultChecks
}

$PreviousPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
	$RevisionOutput = @(& git -C $RepositoryRoot rev-parse HEAD 2>&1 | ForEach-Object { "$_" })
	$RevisionExitCode = $LASTEXITCODE
}
finally {
	$ErrorActionPreference = $PreviousPreference
}
$Revision = if ($RevisionExitCode -eq 0) { $RevisionOutput[0] } else { 'unknown' }

$StartedUtc = [DateTime]::UtcNow.ToString('o')
$Results = @()
$FailureDetails = @()

foreach ($Check in $Checks) {
	$Name = Get-CheckField -Check $Check -Name 'name'
	$Tier = Get-CheckField -Check $Check -Name 'tier'
	$Script = Get-CheckField -Check $Check -Name 'script'
	$Command = Get-CheckField -Check $Check -Name 'command'
	$RequiredModule = Get-CheckField -Check $Check -Name 'requiredModule'
	if (-not $Name -or $Tier -notin @('required', 'advisory') -or (-not $Script -and -not $Command)) {
		throw "Check manifest entry is invalid: every check needs a name, a tier of 'required' or 'advisory', and a script or command."
	}

	if ($Script) {
		$ScriptPath = if ([IO.Path]::IsPathRooted($Script)) { $Script } else { Join-Path $RepositoryRoot ($Script -replace '/', [IO.Path]::DirectorySeparatorChar) }
		$ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)
		$CommandText = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
	}
	else {
		$ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $Command)
		$CommandText = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"$Command`""
	}

	if ($RequiredModule -and -not (Get-Module -ListAvailable -Name $RequiredModule)) {
		$Results += [ordered]@{
			name = $Name
			tier = $Tier
			status = 'skipped'
			durationSeconds = 0
			command = $CommandText
			message = "Skipped: module '$RequiredModule' is not available on this runner."
		}
		Write-Output "[$Tier] ${Name}: skipped (module '$RequiredModule' unavailable)"
		continue
	}

	$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
	Push-Location $RepositoryRoot
	$ErrorActionPreference = 'Continue'
	try {
		$Output = @(& powershell.exe @ArgumentList 2>&1 | ForEach-Object { "$_" })
		$ExitCode = $LASTEXITCODE
	}
	finally {
		$ErrorActionPreference = 'Stop'
		Pop-Location
	}
	$Stopwatch.Stop()

	$Status = if ($ExitCode -eq 0) { 'passed' } else { 'failed' }
	$Message = Get-OutputTail -Lines $Output
	$Results += [ordered]@{
		name = $Name
		tier = $Tier
		status = $Status
		durationSeconds = [Math]::Round($Stopwatch.Elapsed.TotalSeconds, 3)
		command = $CommandText
		message = $Message
	}
	Write-Output "[$Tier] ${Name}: $Status ($([Math]::Round($Stopwatch.Elapsed.TotalSeconds, 1))s)"
	if ($Status -eq 'failed') {
		$FailureDetails += "FAILED [$Tier] ${Name}`nCommand: $CommandText`nOutput tail:`n$Message"
	}
}

$FinishedUtc = [DateTime]::UtcNow.ToString('o')
$Summary = [ordered]@{
	total = $Results.Count
	passed = @($Results | Where-Object { $_.status -eq 'passed' }).Count
	failed = @($Results | Where-Object { $_.status -eq 'failed' }).Count
	skipped = @($Results | Where-Object { $_.status -eq 'skipped' }).Count
	requiredFailed = @($Results | Where-Object { $_.tier -eq 'required' -and $_.status -eq 'failed' }).Count
}

$Report = [ordered]@{
	schemaVersion = 1
	revision = $Revision
	startedUtc = $StartedUtc
	finishedUtc = $FinishedUtc
	checks = $Results
	summary = $Summary
}
$ReportDirectory = Split-Path -Parent $ReportPath
if ($ReportDirectory -and -not (Test-Path -LiteralPath $ReportDirectory)) {
	New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
}
[System.IO.File]::WriteAllText($ReportPath, (ConvertTo-Json -InputObject $Report -Depth 6))

Write-Output ''
Write-Output ($Results | ForEach-Object { [pscustomobject]$_ } | Format-Table -Property name, tier, status, durationSeconds -AutoSize | Out-String -Width 200).TrimEnd()
Write-Output ''
Write-Output "Report: $ReportPath"

foreach ($Detail in $FailureDetails) {
	Write-Output ''
	Write-Output $Detail
}

if ($Summary.requiredFailed -gt 0) {
	Write-Output ''
	Write-Output "CI suite failed: $($Summary.requiredFailed) required check(s) failed."
	exit 1
}

Write-Output ''
Write-Output 'CI suite passed: no required check failed.'
exit 0
