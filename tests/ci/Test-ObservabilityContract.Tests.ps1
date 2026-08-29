[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$CheckScript = Join-Path $RepositoryRoot 'scripts\tests\Test-ObservabilityContract.ps1'
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("AethelnObservabilityContractTests-{0}" -f [guid]::NewGuid().ToString('N'))

function Invoke-Check {
	$PreviousPreference = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		$Output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $CheckScript -RepositoryRoot $FixtureRoot 2>&1 | ForEach-Object { "$_" })
		return @{ Output = $Output; ExitCode = $LASTEXITCODE }
	}
	finally {
		$ErrorActionPreference = $PreviousPreference
	}
}

try {
	foreach ($RelativeDirectory in @('Source\GameNet\Public', 'docs')) {
		New-Item -ItemType Directory -Path (Join-Path $FixtureRoot $RelativeDirectory) -Force | Out-Null
	}
	Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'Source\GameNet\Public\AethelnObservability.h') -Destination (Join-Path $FixtureRoot 'Source\GameNet\Public\AethelnObservability.h')
	Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'Source\GameNet\Public\AethelnObservabilitySubsystem.h') -Destination (Join-Path $FixtureRoot 'Source\GameNet\Public\AethelnObservabilitySubsystem.h')
	Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'docs\observability-and-crash-diagnostics.md') -Destination (Join-Path $FixtureRoot 'docs\observability-and-crash-diagnostics.md')

	$Pass = Invoke-Check
	if ($Pass.ExitCode -ne 0) {
		throw "Valid observability fixture failed: $($Pass.Output -join [Environment]::NewLine)"
	}
	Write-Output 'PASS: valid bounded observability fixture is accepted'

	$ContractPath = Join-Path $FixtureRoot 'Source\GameNet\Public\AethelnObservability.h'
	$Contract = Get-Content -LiteralPath $ContractPath -Raw
	$Contract = $Contract.Replace('uint64 Sequence = 0;', "uint64 Sequence = 0;`n`tFString RawIdentifier;")
	[System.IO.File]::WriteAllText($ContractPath, $Contract)
	$Fail = Invoke-Check
	if ($Fail.ExitCode -eq 0 -or ($Fail.Output -join "`n") -notmatch 'RawIdentifier') {
		throw "Sensitive-field fixture did not fail closed: $($Fail.Output -join [Environment]::NewLine)"
	}
	Write-Output 'PASS: sensitive free-form identifier fixture fails closed'
	Write-Output 'All observability contract fixture tests passed.'
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) {
		Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
	}
}
