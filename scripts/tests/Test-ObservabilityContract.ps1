[CmdletBinding()]
param(
	[string] $RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepositoryRoot) {
	$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

$ContractPath = Join-Path $RepositoryRoot 'Source\GameNet\Public\AethelnObservability.h'
$SubsystemPath = Join-Path $RepositoryRoot 'Source\GameNet\Public\AethelnObservabilitySubsystem.h'
$SubsystemImplementationPath = Join-Path $RepositoryRoot 'Source\GameNet\Private\AethelnObservabilitySubsystem.cpp'
$ServerPath = Join-Path $RepositoryRoot 'Source\GameServer\Private\GameServer.cpp'
$OperatorPath = Join-Path $RepositoryRoot 'docs\observability-and-crash-diagnostics.md'
foreach ($Path in @($ContractPath, $SubsystemPath, $SubsystemImplementationPath, $ServerPath, $OperatorPath)) {
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		throw "Required observability contract '$Path' is missing."
	}
}

$Contract = Get-Content -LiteralPath $ContractPath -Raw
$Subsystem = Get-Content -LiteralPath $SubsystemPath -Raw
$SubsystemImplementation = Get-Content -LiteralPath $SubsystemImplementationPath -Raw
$Server = Get-Content -LiteralPath $ServerPath -Raw
$Operator = Get-Content -LiteralPath $OperatorPath -Raw

function Assert-ContainsLiteral {
	param(
		[Parameter(Mandatory)][string] $Text,
		[Parameter(Mandatory)][string] $Literal,
		[Parameter(Mandatory)][string] $Message
	)
	if ($Text.IndexOf($Literal, [StringComparison]::Ordinal) -lt 0) {
		throw $Message
	}
}

foreach ($Category in @(
	'Movement', 'Aim', 'Ability', 'Cooldown', 'Hit', 'Dodge', 'Block',
	'Resource', 'Death', 'Respawn', 'Correction', 'Rejection',
	'ServerLifecycle', 'ServerHealth', 'CrashContext'
)) {
	Assert-ContainsLiteral -Text $Contract -Literal $Category -Message "Closed observability category '$Category' is missing."
}

foreach ($Flow in @(
	'Admission', 'Lease', 'PersistentCommand', 'Transaction', 'Outbox',
	'Reward', 'Transfer', 'Allocation', 'Dependency', 'Restore', 'Reconciliation'
)) {
	Assert-ContainsLiteral -Text $Contract -Literal $Flow -Message "Versioned 1.0 flow extension '$Flow' is missing."
}

$CorrelationMatch = [regex]::Match(
	$Contract,
	'struct GAMENET_API FAethelnCorrelationContext(?<body>.*?)struct GAMENET_API FAethelnObservabilityEvent',
	[Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $CorrelationMatch.Success) {
	throw 'Could not isolate the bounded correlation and event contract.'
}
$AllowlistedContract = $CorrelationMatch.Groups['body'].Value
foreach ($Forbidden in @('TMap<', 'Metadata', 'Payload', 'CommandBody', 'AccountId', 'CharacterId', 'RawIdentifier;')) {
	if ($AllowlistedContract.IndexOf($Forbidden, [StringComparison]::Ordinal) -ge 0) {
		throw "Free-form or sensitive field marker '$Forbidden' entered the event contract."
	}
}

foreach ($Required in @('MaxIdentifierLength', 'MaxPendingDispatchItems', 'IsSafeIdentifier', 'IsValidForEvent', 'SchemaId == AethelnObservability::SchemaId', 'SchemaVersion == AethelnObservability::SchemaVersion', 'Sequence != 0', 'IsBounded()', 'MakePublicCopy()', 'FAethelnNoOpObservabilitySink', 'FAethelnStructuredLogObservabilitySink', 'FAethelnInMemoryObservabilitySink', 'IAethelnRestrictedAuditSink', 'FAethelnBoundedRestrictedAuditSink', 'FDispatchState', 'WaitForIdleForTests', 'PawnCount', 'ControllerCount', 'PlayerStateCount', 'OtherActorCount')) {
	Assert-ContainsLiteral -Text $Contract -Literal $Required -Message "Required bounded/failure-safe contract '$Required' is missing."
}
$CrashSnapshotMatch = [regex]::Match(
	$Contract,
	'struct GAMENET_API FAethelnCrashContextSnapshot(?<body>.*?)struct GAMENET_API FAethelnMetricSample',
	[Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $CrashSnapshotMatch.Success) {
	throw 'Could not isolate the closed crash-context snapshot contract.'
}
$CrashSnapshot = $CrashSnapshotMatch.Groups['body'].Value
foreach ($Forbidden in @(
	'TMap<', 'TArray<', 'TOptional<', 'Metadata', 'Payload', 'CommandLine', 'Argument',
	'RawIdentifier', 'Credential', 'Secret', 'Token', 'Password', 'AccountId', 'CharacterId',
	'Diagnostic', 'Label', 'Path', 'ActivationId', 'AbilityId', 'Sequence'
)) {
	if ($CrashSnapshot.IndexOf($Forbidden, [StringComparison]::Ordinal) -ge 0) {
		throw "Free-form, sensitive, or per-event marker '$Forbidden' entered the crash-context snapshot contract."
	}
}
foreach ($Required in @(
	'ObservabilitySchemaId', 'ObservabilitySchemaVersion', 'SourceRevision', 'BuildIdentity',
	'BuildConfiguration', 'EngineRevision', 'ToolchainIdentity', 'NetworkProfileSchemaId',
	'NetworkProfileSchemaVersion', 'NetworkProfileId', 'EAethelnFlowKind FlowKind', 'RunId',
	'ServerInstanceId', 'ConnectionPseudonym', 'IsBounded()', 'TryMakeValidated', 'IsSafeIdentifier'
)) {
	Assert-ContainsLiteral -Text $CrashSnapshot -Literal $Required -Message "Required crash-context snapshot field or validation '$Required' is missing."
}
Assert-ContainsLiteral -Text $CrashSnapshot -Literal 'ConnectionPseudonym.Equals(AethelnObservability::ExcludedIdentifier, ESearchCase::CaseSensitive)' -Message 'Process-wide crash-context snapshot must require the literal excluded connection pseudonym.'
foreach ($Closed in @(
	'SourceRevision.Equals(AethelnObservability::UnknownValue, ESearchCase::CaseSensitive)',
	'BuildIdentity.Equals(AethelnObservability::UnknownValue, ESearchCase::CaseSensitive)',
	'ToolchainIdentity.Equals(AethelnObservability::UnknownValue, ESearchCase::CaseSensitive)',
	'NetworkProfileId.Equals(AethelnNetworkSpike::UnsetNetworkProfileId, ESearchCase::CaseSensitive)',
	'ServerInstanceId.Equals(AethelnObservability::CrashServerRole, ESearchCase::CaseSensitive)',
	'BuildConfiguration.Equals(LexToString(FApp::GetBuildConfiguration()), ESearchCase::CaseSensitive)',
	'EngineRevision.Equals(FEngineVersion::Current().ToString(), ESearchCase::CaseSensitive)',
	'HasCrashRunIdFormat(CrashRunId)'
)) {
	Assert-ContainsLiteral -Text $CrashSnapshot -Literal $Closed -Message "Crash-context snapshot must accept only closed, engine-owned, or generated values ('$Closed')."
}
$CrashAccessorMatch = [regex]::Match(
	$SubsystemImplementation,
	'UAethelnObservabilitySubsystem::TryGetCrashContextSnapshot\((?<body>.*?)\n\}',
	[Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $CrashAccessorMatch.Success) {
	throw 'Could not isolate the crash-context snapshot accessor.'
}
$CrashAccessor = $CrashAccessorMatch.Groups['body'].Value
if ($CrashAccessor -cmatch 'RuntimeContext\.(RunId|InstanceId|ConnectionPseudonym)|\bBuildIdentity\b|\bNetworkProfile\b' -or
	$CrashAccessor.IndexOf('CrashRunId', [StringComparison]::Ordinal) -lt 0) {
	throw 'Crash-context snapshot must not copy launcher or caller identity text; it uses the generated crash run ID.'
}
$RuntimeSetMatch = [regex]::Match($SubsystemImplementation, 'UAethelnObservabilitySubsystem::SetRuntimeContext\((?<body>.*?)\n\}', [Text.RegularExpressions.RegexOptions]::Singleline)
$RuntimeResetMatch = [regex]::Match($SubsystemImplementation, 'UAethelnObservabilitySubsystem::ResetRuntimeContext\(\)(?<body>.*?)\n\}', [Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $RuntimeSetMatch.Success -or
	$RuntimeSetMatch.Groups['body'].Value.IndexOf('CrashRunId = FGuid::NewGuid().ToString(EGuidFormats::DigitsLower);', [StringComparison]::Ordinal) -lt 0 -or
	-not $RuntimeResetMatch.Success -or
	$RuntimeResetMatch.Groups['body'].Value.IndexOf('CrashRunId.Reset();', [StringComparison]::Ordinal) -lt 0) {
	throw 'Every accepted runtime context must rotate the generated crash run ID, and a reset must clear it.'
}
$RegisterMatch = [regex]::Match($SubsystemImplementation, 'FAethelnCrashContextOwner::Register\((?<body>.*?)\n\}', [Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $RegisterMatch.Success) {
	throw 'Could not isolate crash-context registration.'
}
$Register = $RegisterMatch.Groups['body'].Value
$MarkerIndex = $Register.IndexOf('TEXT("AethelnCrashContextMarker crash-run=%s"), *Snapshot->CrashRunId);', [StringComparison]::Ordinal)
$ActiveIndex = $Register.IndexOf('SetState(EState::Active);', [StringComparison]::Ordinal)
if ($MarkerIndex -lt 0 -or $ActiveIndex -lt 0 -or $MarkerIndex -gt $ActiveIndex) {
	throw 'The generated crash run ID must be bound to its evidence marker before registration becomes active.'
}
Assert-ContainsLiteral -Text $Subsystem -Literal 'TryGetCrashContextSnapshot(FAethelnCrashContextSnapshot& OutSnapshot) const' -Message 'Crash-context snapshot must be exposed only as a validated copy.'
Assert-ContainsLiteral -Text $Subsystem -Literal 'static FAethelnCrashContextChanged& OnCrashContextChanged();' -Message 'Accepted crash-context changes must be observable without a world tick.'
foreach ($Mutation in @('SetRuntimeContext(', 'ResetRuntimeContext()', 'SetBuildContext(', 'ResetBuildContext()')) {
	$MutationMatch = [regex]::Match(
		$SubsystemImplementation,
		'UAethelnObservabilitySubsystem::' + [regex]::Escape($Mutation) + '(?<body>.*?)\n\}',
		[Text.RegularExpressions.RegexOptions]::Singleline)
	if (-not $MutationMatch.Success -or $MutationMatch.Groups['body'].Value.IndexOf('OnCrashContextChanged().Broadcast(*this);', [StringComparison]::Ordinal) -lt 0) {
		throw "Accepted crash-context mutation '$Mutation' must broadcast the change."
	}
}

foreach ($Key in @('AethelnObservabilitySchema', 'AethelnServerLifecycle')) {
	Assert-ContainsLiteral -Text $Server -Literal "TEXT(`"$Key`")" -Message "Stable crash GameData key '$Key' is missing."
}
foreach ($Key in @(
	'AethelnCrashContextState',
	'AethelnCrashContextSchemaVersion', 'AethelnSourceRevision', 'AethelnBuildIdentity',
	'AethelnBuildConfiguration', 'AethelnEngineRevision', 'AethelnToolchainIdentity',
	'AethelnNetworkProfileSchema', 'AethelnNetworkProfileVersion', 'AethelnNetworkProfileId',
	'AethelnFlowKind', 'AethelnCrashRunId', 'AethelnServerInstance', 'AethelnConnectionPseudonym'
)) {
	Assert-ContainsLiteral -Text $Subsystem -Literal "TEXT(`"$Key`")" -Message "Stable crash GameData key '$Key' is missing."
}
foreach ($Text in @($Subsystem, $SubsystemImplementation, $Server)) {
	if ($Text.IndexOf('TEXT("AethelnRunId")', [StringComparison]::Ordinal) -ge 0) {
		throw 'The crash run key is AethelnCrashRunId; AethelnRunId must not name crash GameData.'
	}
}
foreach ($State in @('missing', 'updating', 'active', 'ambiguous', 'stale')) {
	Assert-ContainsLiteral -Text $SubsystemImplementation -Literal "TEXT(`"$State`")" -Message "Closed crash-context state '$State' is missing."
}
Assert-ContainsLiteral -Text $SubsystemImplementation -Literal 'UAethelnObservabilitySubsystem::OnCrashContextChanged().AddRaw(' -Message 'The crash-context owner must refresh when accepted context changes.'
Assert-ContainsLiteral -Text $SubsystemImplementation -Literal 'UAethelnObservabilitySubsystem::OnCrashContextChanged().Remove(' -Message 'The crash-context owner must unbind its change handler.'
Assert-ContainsLiteral -Text $Server -Literal 'FAethelnCrashContextOwner CrashContext;' -Message 'GameServer must delegate crash-context ownership to the GameNet owner.'

$TrackMatch = [regex]::Match($SubsystemImplementation, 'FAethelnCrashContextOwner::TrackWorldTick\((?<body>.*?)\n\}', [Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $TrackMatch.Success) {
	throw 'Could not isolate the crash-context world tracking handler.'
}
$Track = $TrackMatch.Groups['body'].Value
$TrackAddIndex = $Track.IndexOf('TrackedWorlds.Add(World);', [StringComparison]::Ordinal)
if ($TrackAddIndex -lt 0 -or $Track.Substring(0, $TrackAddIndex) -match 'FindObservabilitySubsystem\(|GetSubsystem|GetGameInstance') {
	throw 'Observable worlds must be counted before their observability subsystem is looked up.'
}
$TickStartMatch = [regex]::Match($Server, 'void OnWorldTickStart\((?<body>.*?)\n\t\}', [Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $TickStartMatch.Success) {
	throw 'Could not isolate the world tick-start handler.'
}
$TickStart = $TickStartMatch.Groups['body'].Value
$WorldCountIndex = $TickStart.IndexOf('CrashContext.TrackWorldTick(World)', [StringComparison]::Ordinal)
$SubsystemLookupIndex = $TickStart.IndexOf('FindObservabilitySubsystem(', [StringComparison]::Ordinal)
if ($WorldCountIndex -lt 0 -or $SubsystemLookupIndex -lt 0 -or $WorldCountIndex -gt $SubsystemLookupIndex) {
	throw 'Observable worlds must be counted before their observability subsystem is looked up.'
}

function Get-AutomationDeclaration([string] $Text) {
	$Result = @{}
	foreach ($Match in [regex]::Matches($Text, 'IMPLEMENT_SIMPLE_AUTOMATION_TEST\((?<body>[^)]*)\)')) {
		$NameMatch = [regex]::Match($Match.Groups['body'].Value, '"(?<name>[^"]+)"')
		if ($NameMatch.Success) {
			$Result[$NameMatch.Groups['name'].Value] = $Match.Groups['body'].Value
		}
	}
	return $Result
}
$GameNetTests = Get-AutomationDeclaration $SubsystemImplementation
foreach ($Name in @(
	'Aetheln.Observability.CrashContext.Registration',
	'Aetheln.Observability.CrashContext.WorldOwnership',
	'Aetheln.Observability.CrashContext.FollowsAcceptedChanges',
	'Aetheln.Observability.CrashContext.CountsWorldsWithoutSubsystem',
	'Aetheln.Observability.CrashContext.ExcludesLauncherText',
	'Aetheln.Observability.CrashContext.ReplacementBeforeEventIsUnattributed'
)) {
	if (-not $GameNetTests.ContainsKey($Name) -or
		$GameNetTests[$Name].IndexOf('EAutomationTestFlags::EditorContext | EAutomationTestFlags::ServerContext', [StringComparison]::Ordinal) -lt 0) {
		throw "Crash-context test '$Name' must live in GameNet and declare EditorContext | ServerContext."
	}
}
$GameServerTests = Get-AutomationDeclaration $Server
if (-not $GameServerTests.ContainsKey('Aetheln.Observability.Server.SystemErrorLifecycleOnly') -or
	$GameServerTests['Aetheln.Observability.Server.SystemErrorLifecycleOnly'].IndexOf('EAutomationTestFlags::ServerContext', [StringComparison]::Ordinal) -lt 0) {
	throw 'The GameServer system-error test must be discoverable in the Server target (ServerContext).'
}
foreach ($Text in @($Server, $SubsystemImplementation)) {
	if ($Text.IndexOf('ResetGameData', [StringComparison]::Ordinal) -ge 0) {
		throw 'Crash-context owners must remove only their owned crash keys and never call ResetGameData.'
	}
}
$SystemErrorMatch = [regex]::Match($Server, 'void HandleSystemError\(\)\s*\{(?<body>[^}]*)\}')
if (-not $SystemErrorMatch.Success) {
	throw 'Could not isolate the minimal system-error handler.'
}
if ($SystemErrorMatch.Groups['body'].Value.Trim() -ne 'FGenericCrashContext::SetGameData(CrashLifecycleKey, TEXT("crashing"));') {
	throw 'System-error handler may only transition the lifecycle key to crashing.'
}

Assert-ContainsLiteral -Text $Subsystem -Literal 'UGameInstanceSubsystem' -Message 'Observability service must remain GameInstance-owned.'
Assert-ContainsLiteral -Text $Subsystem -Literal 'SetTestRestrictedSink' -Message 'Restricted audit injection must remain separate from the public sink.'
Assert-ContainsLiteral -Text $Operator -Literal '| `local` |' -Message 'Local environment boundary is missing.'
Assert-ContainsLiteral -Text $Operator -Literal '| `development` |' -Message 'Development environment boundary is missing.'
Assert-ContainsLiteral -Text $Operator -Literal 'retention is `TBD`' -Message 'Unresolved retention must remain explicit.'
Assert-ContainsLiteral -Text $Operator -Literal 'process-local restricted audit buffer' -Message 'Restricted diagnostic retention boundary is missing.'
Assert-ContainsLiteral -Text $Operator -Literal 'control-character-bearing record is' -Message 'Malformed identifier rejection boundary is missing.'
Assert-ContainsLiteral -Text $Operator -Literal 'independently scheduled background workers' -Message 'Non-blocking independent dispatch boundary is missing.'
Assert-ContainsLiteral -Text $Operator -Literal 'Issue #44 owns' -Message 'Packaged orchestration ownership boundary is missing.'
Assert-ContainsLiteral -Text $Operator -Literal 'Issue #45 owns' -Message 'Performance-budget ownership boundary is missing.'
Assert-ContainsLiteral -Text $Operator -Literal 'No CrashReportClient, uploader, vendor, endpoint, or external submission is configured' -Message 'Crash-report submission boundary is missing.'
Assert-ContainsLiteral -Text $Operator -Literal 'must never be opened, parsed, hashed, copied, or published' -Message 'Raw crash artifact handling boundary is missing.'
Assert-ContainsLiteral -Text $Operator -Literal 'Character validation bounds these values but does not prove they are free of personal or secret text' -Message 'Command-line provenance limitation is missing.'
Assert-ContainsLiteral -Text $Operator -Literal 'The `unknown` and `network-profile.unset` crash values are closed sentinels, not verified provenance' -Message 'Crash sentinel provenance limitation is missing.'
Assert-ContainsLiteral -Text $Operator -Literal 'AethelnCrashContextMarker crash-run=' -Message 'Generated crash run evidence marker is undocumented.'
Assert-ContainsLiteral -Text $Operator -Literal 'External attribution is not established by reading the event stream alone' -Message 'Crash attribution limitation is missing.'
Assert-ContainsLiteral -Text $Operator -Literal 'fail closed on missing, stale, or ambiguous binding' -Message 'Controlled-capture binding requirement is missing.'
Assert-ContainsLiteral -Text $Operator -Literal 'A format check alone is not provenance' -Message 'Crash run format limitation is missing.'
if ($Operator.IndexOf("use that log's event stream", [StringComparison]::Ordinal) -ge 0) {
	throw 'Documentation must not claim the event stream attributes a crash run.'
}

Write-Output 'Observability contract and redaction checks passed.'
