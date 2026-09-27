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
	'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp',
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
	Set-FixtureText -RelativePath 'Source\GameNet\Public\AethelnObservabilitySubsystem.h' -Anchor 'TEXT("AethelnRunId")' -Replacement 'TEXT("AethelnRun")'
	Assert-FailsClosed -Name 'missing stable crash key' -ExpectedPattern 'AethelnRunId'

	Reset-Fixture
	Set-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'TEXT("AethelnServerLifecycle")' -Replacement 'TEXT("AethelnLifecycle")'
	Assert-FailsClosed -Name 'missing stable lifecycle key' -ExpectedPattern 'AethelnServerLifecycle'

	Reset-Fixture
	Set-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'void HandleSystemError()' -Replacement "void ResetAll() { FGenericCrashContext::ResetGameData(); }`n`tvoid HandleSystemError()"
	Assert-FailsClosed -Name 'global crash data reset' -ExpectedPattern 'ResetGameData'

	Reset-Fixture
	Set-FixtureText -RelativePath 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp' -Anchor 'void FAethelnCrashContextOwner::MarkStale()' -Replacement "void ResetAll() { FGenericCrashContext::ResetGameData(); }`nvoid FAethelnCrashContextOwner::MarkStale()"
	Assert-FailsClosed -Name 'owner global crash data reset' -ExpectedPattern 'ResetGameData'

	Reset-Fixture
	Set-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'FGenericCrashContext::SetGameData(CrashLifecycleKey, TEXT("crashing"));' -Replacement "FGenericCrashContext::SetGameData(CrashLifecycleKey, TEXT(`"crashing`"));`n`t`tFGenericCrashContext::SetGameData(CrashRunIdKey, FCommandLine::Get());"
	Assert-FailsClosed -Name 'crash-time work expansion' -ExpectedPattern 'System-error handler'

	Reset-Fixture
	Set-FixtureText -RelativePath 'Source\GameNet\Public\AethelnObservability.h' -Anchor 'ConnectionPseudonym.Equals(AethelnObservability::ExcludedIdentifier, ESearchCase::CaseSensitive)' -Replacement '!ConnectionPseudonym.IsEmpty()'
	Assert-FailsClosed -Name 'printable process-wide connection pseudonym' -ExpectedPattern 'excluded connection pseudonym'

	foreach ($Mutation in @('ResetRuntimeContext()', 'SetBuildContext(')) {
		Reset-Fixture
		$Path = Join-Path $FixtureRoot 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp'
		$Text = Get-Content -LiteralPath $Path -Raw
		$Start = $Text.IndexOf("UAethelnObservabilitySubsystem::$Mutation", [StringComparison]::Ordinal)
		$Broadcast = $Text.IndexOf('OnCrashContextChanged().Broadcast(*this);', $Start, [StringComparison]::Ordinal)
		if ($Start -lt 0 -or $Broadcast -lt 0) {
			throw "Fixture broadcast for '$Mutation' is missing."
		}
		[System.IO.File]::WriteAllText($Path, $Text.Remove($Broadcast, 'OnCrashContextChanged().Broadcast(*this);'.Length).Insert($Broadcast, '(void)0;'))
		Assert-FailsClosed -Name "unbroadcast $Mutation" -ExpectedPattern 'must broadcast the change'
	}

	Reset-Fixture
	Set-FixtureText -RelativePath 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp' -Anchor 'UAethelnObservabilitySubsystem::OnCrashContextChanged().AddRaw(' -Replacement 'UAethelnObservabilitySubsystem::OnCrashContextChanged().AddLambda('
	Assert-FailsClosed -Name 'unbound crash-context change handler' -ExpectedPattern 'refresh when accepted context changes'

	Reset-Fixture
	Set-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'FAethelnCrashContextOwner CrashContext;' -Replacement 'FCrashContextRegistration CrashContext;'
	Assert-FailsClosed -Name 'GameServer-local crash-context ownership' -ExpectedPattern 'GameNet owner'

	Reset-Fixture
	Set-FixtureText -RelativePath 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp' -Anchor 'EAutomationTestFlags::EditorContext | EAutomationTestFlags::ServerContext | EAutomationTestFlags::EngineFilter)' -Replacement 'EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)'
	Assert-FailsClosed -Name 'editor-only crash-context automation' -ExpectedPattern 'must live in GameNet'

	Reset-Fixture
	Set-FixtureText -RelativePath 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp' -Anchor '"Aetheln.Observability.CrashContext.CountsWorldsWithoutSubsystem"' -Replacement '"Aetheln.Observability.CrashContext.Other"'
	Assert-FailsClosed -Name 'missing world-count automation' -ExpectedPattern 'CountsWorldsWithoutSubsystem'

	Reset-Fixture
	Set-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'EAutomationTestFlags::EditorContext | EAutomationTestFlags::ServerContext | EAutomationTestFlags::EngineFilter)' -Replacement 'EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)'
	Assert-FailsClosed -Name 'editor-only GameServer system-error automation' -ExpectedPattern 'ServerContext'

	Reset-Fixture
	Set-FixtureText -RelativePath 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp' -Anchor "`tTrackedWorlds.Add(World);" -Replacement "`tAethelnCrashContext::FindObservabilitySubsystem(World);`n`tTrackedWorlds.Add(World);"
	Assert-FailsClosed -Name 'owner subsystem-gated world counting' -ExpectedPattern 'counted before'

	Reset-Fixture
	Set-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'if (CrashContext.TrackWorldTick(World))' -Replacement "AethelnCrashContext::FindObservabilitySubsystem(World);`n`t`tif (CrashContext.TrackWorldTick(World))"
	Assert-FailsClosed -Name 'GameServer subsystem-gated world counting' -ExpectedPattern 'counted before'

	Reset-Fixture
	Set-FixtureText -RelativePath 'docs\observability-and-crash-diagnostics.md' -Anchor 'Character validation bounds these values but does not prove they are free of personal or secret text' -Replacement 'Character validation proves these values are safe'
	Assert-FailsClosed -Name 'overclaimed command-line provenance' -ExpectedPattern 'provenance limitation'

	Write-Output 'All observability contract fixture tests passed.'
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) {
		Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
	}
}
