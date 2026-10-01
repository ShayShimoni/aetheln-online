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

function Initialize-Fixture {
	foreach ($RelativePath in $FixtureFiles) {
		$Destination = Join-Path $FixtureRoot $RelativePath
		New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
		Copy-Item -LiteralPath (Join-Path $RepositoryRoot $RelativePath) -Destination $Destination -Force
	}
}

function Edit-FixtureText {
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
	Initialize-Fixture
	$Pass = Invoke-Check
	if ($Pass.ExitCode -ne 0) {
		throw "Valid observability fixture failed: $($Pass.Output -join [Environment]::NewLine)"
	}
	Write-Output 'PASS: valid bounded observability fixture is accepted'

	Edit-FixtureText -RelativePath 'Source\GameNet\Public\AethelnObservability.h' -Anchor 'uint64 Sequence = 0;' -Replacement "uint64 Sequence = 0;`n`tFString RawIdentifier;"
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
		Initialize-Fixture
		Edit-FixtureText -RelativePath 'Source\GameNet\Public\AethelnObservability.h' -Anchor $CrashSnapshotAnchor -Replacement "$CrashSnapshotAnchor`n`t$($Entry.Value)"
		Assert-FailsClosed -Name "crash snapshot $($Entry.Key)" -ExpectedPattern 'crash-context snapshot'
	}

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameNet\Public\AethelnObservabilitySubsystem.h' -Anchor 'TEXT("AethelnCrashRunId")' -Replacement 'TEXT("AethelnCrashRun")'
	Assert-FailsClosed -Name 'missing stable crash key' -ExpectedPattern 'AethelnCrashRunId'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameNet\Public\AethelnObservabilitySubsystem.h' -Anchor 'inline constexpr TCHAR CrashRunIdKey[]' -Replacement "inline constexpr TCHAR LegacyRunIdKey[] = TEXT(`"AethelnRunId`");`n`tinline constexpr TCHAR CrashRunIdKey[]"
	Assert-FailsClosed -Name 'ambiguous legacy crash run key' -ExpectedPattern 'AethelnRunId must not name crash GameData'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'TEXT("AethelnServerLifecycle")' -Replacement 'TEXT("AethelnLifecycle")'
	Assert-FailsClosed -Name 'missing stable lifecycle key' -ExpectedPattern 'AethelnServerLifecycle'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'void HandleSystemError()' -Replacement "void ResetAll() { FGenericCrashContext::ResetGameData(); }`n`tvoid HandleSystemError()"
	Assert-FailsClosed -Name 'global crash data reset' -ExpectedPattern 'ResetGameData'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp' -Anchor 'void FAethelnCrashContextOwner::MarkStale()' -Replacement "void ResetAll() { FGenericCrashContext::ResetGameData(); }`nvoid FAethelnCrashContextOwner::MarkStale()"
	Assert-FailsClosed -Name 'owner global crash data reset' -ExpectedPattern 'ResetGameData'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'FGenericCrashContext::SetGameData(CrashLifecycleKey, TEXT("crashing"));' -Replacement "FGenericCrashContext::SetGameData(CrashLifecycleKey, TEXT(`"crashing`"));`n`t`tFGenericCrashContext::SetGameData(CrashRunIdKey, FCommandLine::Get());"
	Assert-FailsClosed -Name 'crash-time work expansion' -ExpectedPattern 'System-error handler'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'AethelnServerObservability::HandleSystemError();' -Replacement "CrashContext.MarkStale();`n`t`tAethelnServerObservability::HandleSystemError();"
	Assert-FailsClosed -Name 'crash-time association inspection' -ExpectedPattern 'System-error callback must only transition'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'FWorldDelegates::OnWorldGameInstanceChanging.AddRaw(this, &FAethelnGameServerModule::OnWorldGameInstanceChanging)' -Replacement 'FWorldDelegates::OnWorldGameInstanceChanging.AddLambda([](UWorld*, UGameInstance*, UGameInstance*) {})'
	Assert-FailsClosed -Name 'missing prechange binding' -ExpectedPattern 'must bind the engine OnWorldGameInstanceChanging'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'FWorldDelegates::OnWorldGameInstanceChanged.Remove(' -Replacement 'FWorldDelegates::OnWorldGameInstanceChanged.Clear('
	Assert-FailsClosed -Name 'missing postchange unbinding' -ExpectedPattern 'must unbind the engine OnWorldGameInstanceChanged'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'CrashContext.BeginWorldGameInstanceTransition(World);' -Replacement '(void)World;'
	Assert-FailsClosed -Name 'prechange does not revoke active attribution' -ExpectedPattern 'must invoke the owner transition gate'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp' -Anchor 'WorldsInGameInstanceTransition.Add(World);' -Replacement 'WorldsInGameInstanceTransition.Contains(World);'
	Assert-FailsClosed -Name 'owner prechange does not establish transition gate' -ExpectedPattern 'must revoke active attribution synchronously'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'CrashContext.EndWorldGameInstanceTransition(World);' -Replacement '(void)World;'
	Assert-FailsClosed -Name 'postchange does not close transition' -ExpectedPattern 'must invoke the owner transition gate'

	Initialize-Fixture
	$ServerFixturePath = Join-Path $FixtureRoot 'Source\GameServer\Private\GameServer.cpp'
	$ServerFixture = Get-Content -LiteralPath $ServerFixturePath -Raw
	$PrechangeStart = $ServerFixture.IndexOf('void OnWorldGameInstanceChanging(', [StringComparison]::Ordinal)
	$CacheRemoval = $ServerFixture.IndexOf('ConfiguredSubsystems.Remove(World);', $PrechangeStart, [StringComparison]::Ordinal)
	if ($PrechangeStart -lt 0 -or $CacheRemoval -lt 0) {
		throw 'Prechange cache-invalidation fixture anchor is missing.'
	}
	[System.IO.File]::WriteAllText($ServerFixturePath, $ServerFixture.Remove($CacheRemoval, 'ConfiguredSubsystems.Remove(World);'.Length).Insert($CacheRemoval, 'ConfiguredSubsystems.Contains(World);'))
	Assert-FailsClosed -Name 'missing notified cache invalidation' -ExpectedPattern 'must invoke the owner transition gate'

	Initialize-Fixture
	$ServerFixturePath = Join-Path $FixtureRoot 'Source\GameServer\Private\GameServer.cpp'
	$ServerFixture = Get-Content -LiteralPath $ServerFixturePath -Raw
	$PrechangeStart = $ServerFixture.IndexOf('void OnWorldGameInstanceChanging(', [StringComparison]::Ordinal)
	$CacheRemoval = $ServerFixture.IndexOf('ConfiguredSubsystems.Remove(World);', $PrechangeStart, [StringComparison]::Ordinal)
	if ($PrechangeStart -lt 0 -or $CacheRemoval -lt 0) {
		throw 'Prechange extra-work fixture anchor is missing.'
	}
	[System.IO.File]::WriteAllText($ServerFixturePath, $ServerFixture.Insert($CacheRemoval, '(void)World->GetGameInstance();'))
	Assert-FailsClosed -Name 'prechange extra world read' -ExpectedPattern 'must invoke the owner transition gate'

	Initialize-Fixture
	$ServerFixture = Get-Content -LiteralPath $ServerFixturePath -Raw
	$PostchangeStart = $ServerFixture.IndexOf('void OnWorldGameInstanceChanged(', [StringComparison]::Ordinal)
	$CacheRemoval = $ServerFixture.IndexOf('ConfiguredSubsystems.Remove(World);', $PostchangeStart, [StringComparison]::Ordinal)
	if ($PostchangeStart -lt 0 -or $CacheRemoval -lt 0) {
		throw 'Postchange extra-work fixture anchor is missing.'
	}
	[System.IO.File]::WriteAllText($ServerFixturePath, $ServerFixture.Insert($CacheRemoval, 'FGenericCrashContext::SetGameData(TEXT("extra"), TEXT("unsafe"));'))
	Assert-FailsClosed -Name 'postchange extra crash-data write' -ExpectedPattern 'must invoke the owner transition gate'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'WorldGameInstanceChangeEpoch != AdmissionEpoch' -Replacement 'WorldGameInstanceChangeEpoch == AdmissionEpoch'
	Assert-FailsClosed -Name 'missing reentrant epoch guard' -ExpectedPattern 'must recheck exact association and epoch'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'Configured->Get() != Subsystem' -Replacement 'Configured->Get() == Subsystem'
	Assert-FailsClosed -Name 'unconfigured replacement health sample' -ExpectedPattern 'must not sample health'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameNet\Public\AethelnObservability.h' -Anchor 'ConnectionPseudonym.Equals(AethelnObservability::ExcludedIdentifier, ESearchCase::CaseSensitive)' -Replacement '!ConnectionPseudonym.IsEmpty()'
	Assert-FailsClosed -Name 'printable process-wide connection pseudonym' -ExpectedPattern 'excluded connection pseudonym'

	foreach ($Mutation in @('ResetRuntimeContext()', 'SetBuildContext(')) {
		Initialize-Fixture
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

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp' -Anchor 'UAethelnObservabilitySubsystem::OnCrashContextChanged().AddRaw(' -Replacement 'UAethelnObservabilitySubsystem::OnCrashContextChanged().AddLambda('
	Assert-FailsClosed -Name 'unbound crash-context change handler' -ExpectedPattern 'refresh when accepted context changes'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'FAethelnCrashContextOwner CrashContext;' -Replacement 'FCrashContextRegistration CrashContext;'
	Assert-FailsClosed -Name 'GameServer-local crash-context ownership' -ExpectedPattern 'GameNet owner'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp' -Anchor 'EAutomationTestFlags::EditorContext | EAutomationTestFlags::ServerContext | EAutomationTestFlags::EngineFilter)' -Replacement 'EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)'
	Assert-FailsClosed -Name 'editor-only crash-context automation' -ExpectedPattern 'must live in GameNet'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp' -Anchor '"Aetheln.Observability.CrashContext.CountsWorldsWithoutSubsystem"' -Replacement '"Aetheln.Observability.CrashContext.Other"'
	Assert-FailsClosed -Name 'missing world-count automation' -ExpectedPattern 'CountsWorldsWithoutSubsystem'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'EAutomationTestFlags::EditorContext | EAutomationTestFlags::ServerContext | EAutomationTestFlags::EngineFilter)' -Replacement 'EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)'
	Assert-FailsClosed -Name 'editor-only GameServer system-error automation' -ExpectedPattern 'ServerContext'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp' -Anchor "`tTrackedWorlds.Add(World);" -Replacement "`tAethelnCrashContext::FindObservabilitySubsystem(World);`n`tTrackedWorlds.Add(World);"
	Assert-FailsClosed -Name 'owner subsystem-gated world counting' -ExpectedPattern 'counted before'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'CrashContext.BeginWorldTickAdmission(World, Admission);' -Replacement "AethelnCrashContext::FindObservabilitySubsystem(World);`n`t`tCrashContext.BeginWorldTickAdmission(World, Admission);"
	Assert-FailsClosed -Name 'GameServer subsystem-gated world counting' -ExpectedPattern 'counted before'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'if (!NextHealthSampleTimes.Contains(World))' -Replacement 'if (AdmissionResult == FAethelnCrashContextOwner::EWorldTickAdmissionResult::NewWorld)'
	Assert-FailsClosed -Name 'server initialization tied to first count' -ExpectedPattern 'Could not isolate first-admitted-tick server initialization'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'AethelnServerObservability::ConfigureContext(*Subsystem);' -Replacement "CrashContext.RefreshForTrackedWorld(World);`n`t`t`tAethelnServerObservability::ConfigureContext(*Subsystem);"
	Assert-FailsClosed -Name 'refresh before configuration' -ExpectedPattern 'must complete admission after configuration'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'AethelnServerObservability::ConfigureContext(*Subsystem);' -Replacement "CrashContext.CompleteWorldTickAdmission(Admission);`n`t`t`tAethelnServerObservability::ConfigureContext(*Subsystem);"
	Assert-FailsClosed -Name 'admission completion before configuration' -ExpectedPattern 'must complete admission after configuration'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'CrashContext.CompleteWorldTickAdmission(Admission)' -Replacement '(void)World'
	Assert-FailsClosed -Name 'missing subsystem-transition admission' -ExpectedPattern 'must complete admitted ticks'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameServer\Private\GameServer.cpp' -Anchor 'CrashContext.AbortWorldTickAdmission(Admission);' -Replacement '(void)Admission;'
	Assert-FailsClosed -Name 'unreleased failed world-tick admission' -ExpectedPattern 'must release its exact token'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'docs\observability-and-crash-diagnostics.md' -Anchor 'Character validation bounds these values but does not prove they are free of personal or secret text' -Replacement 'Character validation proves these values are safe'
	Assert-FailsClosed -Name 'overclaimed command-line provenance' -ExpectedPattern 'provenance limitation'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'docs\observability-and-crash-diagnostics.md' -Anchor 'A marker alone never authorizes attribution' -Replacement 'A marker alone authorizes attribution'
	Assert-FailsClosed -Name 'tentative marker claimed as attribution' -ExpectedPattern 'tentative marker'

	foreach ($Entry in @(
		@{ Name = 'launcher source revision in crash snapshot'; Anchor = 'SourceRevision.Equals(AethelnObservability::UnknownValue, ESearchCase::CaseSensitive)'; Replacement = '!SourceRevision.IsEmpty()' },
		@{ Name = 'launcher profile in crash snapshot'; Anchor = 'NetworkProfileId.Equals(AethelnNetworkSpike::UnsetNetworkProfileId, ESearchCase::CaseSensitive)'; Replacement = '!NetworkProfileId.IsEmpty()' },
		@{ Name = 'caller engine revision in crash snapshot'; Anchor = 'EngineRevision.Equals(FEngineVersion::Current().ToString(), ESearchCase::CaseSensitive)'; Replacement = '!EngineRevision.IsEmpty()' },
		@{ Name = 'caller instance in crash snapshot'; Anchor = 'ServerInstanceId.Equals(AethelnObservability::CrashServerRole, ESearchCase::CaseSensitive)'; Replacement = '!ServerInstanceId.IsEmpty()' },
		@{ Name = 'launcher run in crash snapshot'; Anchor = 'HasCrashRunIdFormat(CrashRunId)'; Replacement = '!CrashRunId.IsEmpty()' }
	)) {
		Initialize-Fixture
		Edit-FixtureText -RelativePath 'Source\GameNet\Public\AethelnObservability.h' -Anchor $Entry.Anchor -Replacement $Entry.Replacement
		Assert-FailsClosed -Name $Entry.Name -ExpectedPattern 'closed, engine-owned, or generated'
	}

	foreach ($Entry in @(
		@{ Name = 'crash accessor copying the launcher run'; Anchor = "`t`tCrashRunId,"; Replacement = "`t`tRuntimeContext.RunId," },
		@{ Name = 'crash accessor copying the launcher build'; Anchor = "`t`tCrashBuild,"; Replacement = "`t`tBuildIdentity," }
	)) {
		Initialize-Fixture
		Edit-FixtureText -RelativePath 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp' -Anchor $Entry.Anchor -Replacement $Entry.Replacement
		Assert-FailsClosed -Name $Entry.Name -ExpectedPattern 'must not copy launcher or caller identity text'
	}

	foreach ($Entry in @(
		@{ Name = 'unrotated crash run'; Anchor = 'CrashRunId = FGuid::NewGuid().ToString(EGuidFormats::DigitsLower);'; Replacement = 'CrashRunId = RunId;' },
		@{ Name = 'crash run surviving reset'; Anchor = 'CrashRunId.Reset();'; Replacement = '(void)0;' }
	)) {
		Initialize-Fixture
		Edit-FixtureText -RelativePath 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp' -Anchor $Entry.Anchor -Replacement $Entry.Replacement
		Assert-FailsClosed -Name $Entry.Name -ExpectedPattern 'rotate the generated crash run ID'
	}

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp' -Anchor 'UE_LOG(LogAethelnCrashContext, Display, TEXT("AethelnCrashContextMarker crash-run=%s"), *Snapshot->CrashRunId);' -Replacement '(void)0;'
	Assert-FailsClosed -Name 'unbound crash run evidence marker' -ExpectedPattern 'evidence marker before registration becomes active'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp' -Anchor '"Aetheln.Observability.CrashContext.ExcludesLauncherText"' -Replacement '"Aetheln.Observability.CrashContext.Other"'
	Assert-FailsClosed -Name 'missing launcher-text exclusion automation' -ExpectedPattern 'ExcludesLauncherText'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'docs\observability-and-crash-diagnostics.md' -Anchor 'crash values are closed sentinels, not verified provenance' -Replacement 'crash values prove provenance'
	Assert-FailsClosed -Name 'crash sentinels claimed as provenance' -ExpectedPattern 'Crash sentinel provenance limitation'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'docs\observability-and-crash-diagnostics.md' -Anchor 'AethelnCrashContextMarker crash-run=' -Replacement 'crash marker'
	Assert-FailsClosed -Name 'undocumented crash run evidence marker' -ExpectedPattern 'evidence marker is undocumented'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp' -Anchor '"Aetheln.Observability.CrashContext.ReplacementBeforeEventIsUnattributed"' -Replacement '"Aetheln.Observability.CrashContext.Other"'
	Assert-FailsClosed -Name 'missing replacement-before-event regression' -ExpectedPattern 'ReplacementBeforeEventIsUnattributed'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp' -Anchor '"Aetheln.Observability.CrashContext.MarkerMatchesRegisteredRun"' -Replacement '"Aetheln.Observability.CrashContext.Other"'
	Assert-FailsClosed -Name 'missing exact evidence-marker test' -ExpectedPattern 'MarkerMatchesRegisteredRun'

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp' -Anchor '	const FAethelnCrashContextSnapshot First = MakeSnapshot();' -Replacement "	AddExpectedMessage(TEXT(`"AethelnCrashContextMarker crash-run=[0-9a-f]{32}`"), ELogVerbosity::Display, EAutomationExpectedMessageFlags::Contains, 0);`n	const FAethelnCrashContextSnapshot First = MakeSnapshot();"
	Assert-FailsClosed -Name 'restored expected-message marker assertion' -ExpectedPattern 'test-owned Display capture'

	foreach ($Entry in @(
		@{ Name = 'buffered marker capture'; Anchor = 'virtual bool CanBeUsedOnMultipleThreads() const override { return true; }'; Replacement = 'virtual bool CanBeUsedOnMultipleThreads() const override { return false; }' },
		@{ Name = 'marker capture not bound to its category'; Anchor = 'if (Category == LogAethelnCrashContext.GetCategoryName())'; Replacement = 'if (true)' },
		@{ Name = 'marker capture left registered'; Anchor = 'GLog->RemoveOutputDevice(this);'; Replacement = '(void)0;' }
	)) {
		Initialize-Fixture
		Edit-FixtureText -RelativePath 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp' -Anchor $Entry.Anchor -Replacement $Entry.Replacement
		Assert-FailsClosed -Name $Entry.Name -ExpectedPattern 'scoped, unbuffered, category-bound log device'
	}

	foreach ($Entry in @(
		@{ Name = 'unbounded marker count'; Anchor = 'TestEqual(TEXT("Captured marker count matches"), Lines.Num(), Runs.Num());'; Replacement = 'TestTrue(TEXT("Captured marker count matches"), Lines.Num() >= Runs.Num());' },
		@{ Name = 'marker severity unchecked'; Anchor = 'Line.Key == ELogVerbosity::Display'; Replacement = 'true' },
		@{ Name = 'partial marker match'; Anchor = 'Line.Value.Equals(TEXT("AethelnCrashContextMarker crash-run=") + Runs[Index], ESearchCase::CaseSensitive)'; Replacement = 'Line.Value.Contains(Runs[Index])' },
		@{ Name = 'missing same-ID refresh stage'; Anchor = "ReadKey(CrashRunIdKey).Equals(FirstRun, ESearchCase::CaseSensitive));`n`tExpectMarkers({ FirstRun });"; Replacement = 'ReadKey(CrashRunIdKey).Equals(FirstRun, ESearchCase::CaseSensitive));' },
		@{ Name = 'missing replacement stage'; Anchor = "SecondRun.Equals(FirstRun, ESearchCase::CaseSensitive));`n`tExpectMarkers({ FirstRun, SecondRun });"; Replacement = 'SecondRun.Equals(FirstRun, ESearchCase::CaseSensitive));' }
	)) {
		Initialize-Fixture
		Edit-FixtureText -RelativePath 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp' -Anchor $Entry.Anchor -Replacement $Entry.Replacement
		Assert-FailsClosed -Name $Entry.Name -ExpectedPattern 'exactly one exact Display marker per written crash run ID'
	}

	Initialize-Fixture
	Edit-FixtureText -RelativePath 'docs\observability-and-crash-diagnostics.md' -Anchor 'The capture covers the in-process log route only' -Replacement 'The capture proves the packaged log'
	Assert-FailsClosed -Name 'overclaimed evidence-marker coverage' -ExpectedPattern 'Evidence-marker test limitation'

	foreach ($Entry in @(
		@{ Name = 'event stream claimed as crash attribution'; Anchor = 'External attribution is not established by reading the event stream alone'; Replacement = 'The event stream attributes the crash'; Pattern = 'Crash attribution limitation' },
		@{ Name = 'unbound controlled-capture manifest'; Anchor = 'fail closed on missing, stale, or ambiguous binding'; Replacement = 'best-effort binding'; Pattern = 'Controlled-capture binding requirement' },
		@{ Name = 'format check claimed as provenance'; Anchor = 'A format check alone is not provenance'; Replacement = 'The format proves generation'; Pattern = 'Crash run format limitation' },
		@{ Name = 'restored event-stream join claim'; Anchor = 'Until that runner exists'; Replacement = "Otherwise use that log's event stream. Until that runner exists"; Pattern = 'must not claim the event stream attributes' }
	)) {
		Initialize-Fixture
		Edit-FixtureText -RelativePath 'docs\observability-and-crash-diagnostics.md' -Anchor $Entry.Anchor -Replacement $Entry.Replacement
		Assert-FailsClosed -Name $Entry.Name -ExpectedPattern $Entry.Pattern
	}

	Write-Output 'All observability contract fixture tests passed.'
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) {
		Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
	}
}
