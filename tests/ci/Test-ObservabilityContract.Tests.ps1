[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$CheckScript = Join-Path $RepositoryRoot 'scripts\tests\Test-ObservabilityContract.ps1'
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("AethelnObservabilityContractTests-{0}" -f [guid]::NewGuid().ToString('N'))
$FixtureFiles = @(
	'Source\GameNet\Public\AethelnObservability.h',
	'Source\GameNet\Public\AethelnObservabilitySubsystem.h',
	'Source\GameServer\Private\GameServer.cpp',
	'docs\observability-and-crash-diagnostics.md'
)

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

function Reset-Fixture {
	foreach ($RelativePath in $FixtureFiles) {
		$Destination = Join-Path $FixtureRoot $RelativePath
		New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
		Copy-Item -LiteralPath (Join-Path $RepositoryRoot $RelativePath) -Destination $Destination -Force
	}
}

function Set-FixtureText {
	param(
		[Parameter(Mandatory)][string] $RelativePath,
		[Parameter(Mandatory)][string] $Anchor,
		[Parameter(Mandatory)][string] $Replacement
	)
	$Path = Join-Path $FixtureRoot $RelativePath
	$Text = Get-Content -LiteralPath $Path -Raw
	if ($Text.IndexOf($Anchor, [StringComparison]::Ordinal) -lt 0) {
		throw "Fixture anchor '$Anchor' is missing from '$RelativePath'."
	}
	[System.IO.File]::WriteAllText($Path, $Text.Replace($Anchor, $Replacement))
}

function Assert-FailsClosed {
	param(
		[Parameter(Mandatory)][string] $Name,
		[Parameter(Mandatory)][string] $ExpectedPattern
	)
	$Fail = Invoke-Check
	if ($Fail.ExitCode -eq 0 -or ($Fail.Output -join "`n") -notmatch $ExpectedPattern) {
		throw "$Name fixture did not fail closed: $($Fail.Output -join [Environment]::NewLine)"
	}
	Write-Output "PASS: $Name fixture fails closed"
}

try {
	Reset-Fixture
	$Pass = Invoke-Check
	if ($Pass.ExitCode -ne 0) {
		throw "Valid observability fixture failed: $($Pass.Output -join [Environment]::NewLine)"
	}
	Write-Output 'PASS: valid bounded observability fixture is accepted'

	Set-FixtureText -RelativePath 'Source\GameNet\Public\AethelnObservability.h' -Anchor 'uint64 Sequence = 0;' -Replacement "uint64 Sequence = 0;`n`tFString RawIdentifier;"
	Assert-FailsClosed -Name 'sensitive free-form identifier' -ExpectedPattern 'RawIdentifier'

	$CrashSnapshotAnchor = 'FString ServerInstanceId;'
	$ForbiddenCrashFields = [ordered]@{
		'free-form map'              = 'TMap<FString, FString> Extra;'
		'metadata bag'               = 'FString Metadata;'
		'raw identifier'             = 'FString RawIdentifier;'
		'command line'               = 'FString CommandLine;'
		'raw arguments'              = 'FString Arguments;'
		'payload'                    = 'FString Payload;'
		'credential'                 = 'FString Credential;'
		'secret'                     = 'FString Secret;'
		'token'                      = 'FString Token;'
		'account identity'           = 'FString AccountId;'
		'character identity'         = 'FString CharacterId;'
		'unrestricted diagnostic'    = 'FString DiagnosticText;'
		'arbitrary label'            = 'FString Label;'
		'path'                       = 'FString Path;'
		'activation identity'        = 'FString ActivationId;'
		'ability identity'           = 'FString AbilityId;'
		'event sequence'             = 'uint64 Sequence = 0;'
		'network profile tuning'     = 'TOptional<double> LatencyMilliseconds;'
	}
	foreach ($Entry in $ForbiddenCrashFields.GetEnumerator()) {
		Reset-Fixture
		Set-FixtureText -RelativePath 'Source\GameNet\Public\AethelnObservability.h' -Anchor $CrashSnapshotAnchor -Replacement "$CrashSnapshotAnchor`n`t$($Entry.Value)"
		Assert-FailsClosed -Name "crash snapshot $($Entry.Key)" -ExpectedPattern 'crash-context snapshot'
	}

	Reset-Fixture
	Set-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'TEXT("AethelnRunId")' -Replacement 'TEXT("AethelnRun")'
	Assert-FailsClosed -Name 'missing stable crash key' -ExpectedPattern 'AethelnRunId'

	Reset-Fixture
	Set-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'void HandleSystemError()' -Replacement "void ResetAll() { FGenericCrashContext::ResetGameData(); }`n`tvoid HandleSystemError()"
	Assert-FailsClosed -Name 'global crash data reset' -ExpectedPattern 'ResetGameData'

	Reset-Fixture
	Set-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'FGenericCrashContext::SetGameData(CrashLifecycleKey, TEXT("crashing"));' -Replacement "FGenericCrashContext::SetGameData(CrashLifecycleKey, TEXT(`"crashing`"));`n`t`tFGenericCrashContext::SetGameData(CrashRunIdKey, FCommandLine::Get());"
	Assert-FailsClosed -Name 'crash-time work expansion' -ExpectedPattern 'System-error handler'

	Write-Output 'All observability contract fixture tests passed.'
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) {
		Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
	}
}
