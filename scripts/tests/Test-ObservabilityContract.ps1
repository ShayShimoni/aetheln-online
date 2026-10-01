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
$RuntimeClearMatch = [regex]::Match($SubsystemImplementation, 'UAethelnObservabilitySubsystem::ClearRuntimeContextWithoutBroadcast\(\)(?<body>.*?)\n\}', [Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $RuntimeSetMatch.Success -or
	$RuntimeSetMatch.Groups['body'].Value.IndexOf('CrashRunId = FGuid::NewGuid().ToString(EGuidFormats::DigitsLower);', [StringComparison]::Ordinal) -lt 0 -or
	-not $RuntimeResetMatch.Success -or
	$RuntimeResetMatch.Groups['body'].Value.IndexOf('ClearRuntimeContextWithoutBroadcast();', [StringComparison]::Ordinal) -lt 0 -or
	-not $RuntimeClearMatch.Success -or
	$RuntimeClearMatch.Groups['body'].Value.IndexOf('CrashRunId.Reset();', [StringComparison]::Ordinal) -lt 0) {
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
if ($SubsystemImplementation -cmatch '(?s)AddExpectedMessage(Plain)?\([^;]*AethelnCrashContextMarker') {
	throw 'Evidence-marker tests must use the test-owned Display capture, not expected-message matching.'
}
foreach ($Literal in @(
	'GLog->AddOutputDevice(this);',
	'GLog->RemoveOutputDevice(this);',
	'virtual bool CanBeUsedOnMultipleThreads() const override { return true; }',
	'if (Category == LogAethelnCrashContext.GetCategoryName())'
)) {
	Assert-ContainsLiteral -Text $SubsystemImplementation -Literal $Literal -Message 'The crash-marker capture must be a scoped, unbuffered, category-bound log device.'
}
$MarkerTestMatch = [regex]::Match($SubsystemImplementation, 'bool FAethelnCrashContextMarkerTest::RunTest\((?<body>.*?)\n\}', [Text.RegularExpressions.RegexOptions]::Singleline)
$MarkerTest = if ($MarkerTestMatch.Success) { $MarkerTestMatch.Groups['body'].Value } else { '' }
$MarkerStages = @(
	[regex]::Matches($MarkerTest, [regex]::Escape('ExpectMarkers({ FirstRun });')).Count,
	[regex]::Matches($MarkerTest, [regex]::Escape('ExpectMarkers({ FirstRun, SecondRun });')).Count
)
if ($MarkerTest.IndexOf('FScopedCrashMarkerCapture Capture;', [StringComparison]::Ordinal) -lt 0 -or
	$MarkerTest.IndexOf('TestEqual(TEXT("Captured marker count matches"), Lines.Num(), Runs.Num());', [StringComparison]::Ordinal) -lt 0 -or
	$MarkerTest.IndexOf('Line.Key == ELogVerbosity::Display', [StringComparison]::Ordinal) -lt 0 -or
	$MarkerTest.IndexOf('Line.Value.Equals(TEXT("AethelnCrashContextMarker crash-run=") + Runs[Index], ESearchCase::CaseSensitive)', [StringComparison]::Ordinal) -lt 0 -or
	$MarkerStages[0] -ne 2 -or $MarkerStages[1] -ne 2) {
	throw 'The evidence-marker test must require exactly one exact Display marker per written crash run ID after registration, same-ID refresh, and replacement.'
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

$TrackMatch = [regex]::Match($SubsystemImplementation, 'FAethelnCrashContextOwner::BeginWorldTickAdmission\((?<body>.*?)\n\}', [Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $TrackMatch.Success) {
	throw 'Could not isolate the guarded crash-context world admission handler.'
}
$Track = $TrackMatch.Groups['body'].Value
$TrackAddIndex = $Track.IndexOf('TrackedWorlds.Add(World);', [StringComparison]::Ordinal)
if ($TrackAddIndex -lt 0 -or $Track.Substring(0, $TrackAddIndex) -match 'FindObservabilitySubsystem\(|GetSubsystem|GetGameInstance') {
	throw 'Observable worlds must be counted before their observability subsystem is looked up.'
}
if ($Track -match 'FindObservabilitySubsystem\(|GetSubsystem|GetGameInstance|\bRefresh\(|\bRegister\(' -or
	-not $Track.Contains('ERequestedUpdate::Missing') -or -not $Track.Contains('ERequestedUpdate::Ambiguous') -or
	-not $Track.Contains('PendingWorldTickAdmissions.Add(World, Candidate.Serial)')) {
	throw 'BeginWorldTickAdmission must count and gate without refreshing before configuration.'
}
$TickStartMatch = [regex]::Match($Server, 'void OnWorldTickStart\((?<body>.*?)\n\t\}', [Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $TickStartMatch.Success) {
	throw 'Could not isolate the world tick-start handler.'
}
$TickStart = $TickStartMatch.Groups['body'].Value
$WorldCountIndex = $TickStart.IndexOf('CrashContext.BeginWorldTickAdmission(World, Admission)', [StringComparison]::Ordinal)
$SubsystemLookupIndex = $TickStart.IndexOf('FindObservabilitySubsystem(', [StringComparison]::Ordinal)
if ($WorldCountIndex -lt 0 -or $SubsystemLookupIndex -lt 0 -or $WorldCountIndex -gt $SubsystemLookupIndex) {
	throw 'Observable worlds must be counted before their observability subsystem is looked up.'
}
$FirstWorldBlock = [regex]::Match($TickStart, 'if\s*\(!NextHealthSampleTimes\.Contains\(World\)\)\s*\{(?<body>.*?)\n\t\t\}', [Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $FirstWorldBlock.Success) {
	throw 'Could not isolate first-admitted-tick server initialization.'
}
if ($FirstWorldBlock.Groups['body'].Value.Contains('FindObservabilitySubsystem(')) {
	throw 'A subsystem appearing after the first world tick must still be configured.'
}
if ($TickStart.Contains('AdmissionResult == FAethelnCrashContextOwner::EWorldTickAdmissionResult::NewWorld')) {
	throw 'GameServer initialization must not depend on the GameNet first-count result.'
}
if (-not $TickStart.Contains('CrashContext.CompleteWorldTickAdmission(Admission)') -or
	-not $TickStart.Contains('ConfiguredSubsystems.Remove(World)')) {
	throw 'GameServer must complete admitted ticks after subsystem changes.'
}
$AbortCount = [regex]::Matches($TickStart, 'CrashContext\.AbortWorldTickAdmission\(Admission\);').Count
if ($AbortCount -ne 6) {
	throw 'Every unsuccessful world-tick admission path must release its exact token.'
}
$FirstConfigureIndex = $TickStart.IndexOf('AethelnServerObservability::ConfigureContext(*Subsystem);', [StringComparison]::Ordinal)
$FirstCompletionIndex = $TickStart.IndexOf('CrashContext.CompleteWorldTickAdmission(Admission)', [StringComparison]::Ordinal)
if ($FirstConfigureIndex -lt 0 -or $FirstCompletionIndex -lt $FirstConfigureIndex -or
	$TickStart.Contains('CrashContext.RefreshForTrackedWorld(World)')) {
	throw 'GameServer must complete admission after configuration, never bypass its gate with direct refresh.'
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
	'Aetheln.Observability.CrashContext.ReplacementBeforeEventIsUnattributed',
	'Aetheln.Observability.CrashContext.MarkerMatchesRegisteredRun'
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
$OnErrorMatch = [regex]::Match($Server, 'void OnSystemError\(\)\s*\{(?<body>[^}]*)\}')
if (-not $OnErrorMatch.Success -or
	$OnErrorMatch.Groups['body'].Value.Trim() -ne 'AethelnServerObservability::HandleSystemError();') {
	throw 'System-error callback must only transition the crash lifecycle.'
}
if ($Server.Contains('RevalidateCrashAssociationBeforeSystemError')) {
	throw 'System-error callback must not traverse the world association.'
}
foreach ($Name in @('OnWorldGameInstanceChanging', 'OnWorldGameInstanceChanged')) {
	Assert-ContainsLiteral -Text $Server -Literal "FWorldDelegates::$Name.AddRaw(this, &FAethelnGameServerModule::$Name)" -Message "GameServer must bind the engine $Name notification."
	Assert-ContainsLiteral -Text $Server -Literal "FWorldDelegates::$Name.Remove(" -Message "GameServer must unbind the engine $Name notification."
	$Handler = [regex]::Match($Server, "void $Name\([^)]*\)\s*\{(?<body>.*?)\n\t\}", [Text.RegularExpressions.RegexOptions]::Singleline)
	$ExpectedHandlerBody = if ($Name -eq 'OnWorldGameInstanceChanging') {
		'(void)OldGameInstance;(void)NewGameInstance;if(AethelnServerObservability::IsObservableWorld(World)){constboolbWasTracked=CrashContext.IsTracked(World);CrashContext.BeginWorldGameInstanceTransition(World);if(bWasTracked){++WorldGameInstanceChangeEpoch;ConfiguredSubsystems.Remove(World);}}'
	} else {
		'(void)OldGameInstance;(void)NewGameInstance;if(AethelnServerObservability::IsObservableWorld(World)){if(CrashContext.IsTracked(World)){++WorldGameInstanceChangeEpoch;ConfiguredSubsystems.Remove(World);}CrashContext.EndWorldGameInstanceTransition(World);}'
	}
	if (-not $Handler.Success -or
		[regex]::Replace($Handler.Groups['body'].Value, '\s+', '') -cne $ExpectedHandlerBody) {
		throw "GameServer $Name must invoke the owner transition gate and invalidate its subsystem cache without independent crash-data work."
	}
}
$OwnerPrechangeMatch = [regex]::Match($SubsystemImplementation, 'FAethelnCrashContextOwner::BeginWorldGameInstanceTransition\((?<body>.*?)\n\}', [Text.RegularExpressions.RegexOptions]::Singleline)
$OwnerPostchangeMatch = [regex]::Match($SubsystemImplementation, 'FAethelnCrashContextOwner::EndWorldGameInstanceTransition\((?<body>.*?)\n\}', [Text.RegularExpressions.RegexOptions]::Singleline)
$OwnerStaleMatch = [regex]::Match($SubsystemImplementation, 'FAethelnCrashContextOwner::MarkTransitionStaleIfNeeded\((?<body>.*?)\n\}', [Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $OwnerPrechangeMatch.Success -or -not $OwnerPostchangeMatch.Success -or -not $OwnerStaleMatch.Success -or
	$OwnerPrechangeMatch.Groups['body'].Value.IndexOf('WorldsInGameInstanceTransition.Add(World);', [StringComparison]::Ordinal) -lt 0 -or
	$OwnerPrechangeMatch.Groups['body'].Value.IndexOf('MarkTransitionStaleIfNeeded(World);', [StringComparison]::Ordinal) -lt 0 -or
	$OwnerStaleMatch.Groups['body'].Value.IndexOf('MarkStale();', [StringComparison]::Ordinal) -lt 0 -or
	$OwnerPostchangeMatch.Groups['body'].Value.Contains('Refresh(') -or
	$OwnerPostchangeMatch.Groups['body'].Value.Contains('Register(')) {
	throw 'The owner prechange gate must revoke active attribution synchronously; postchange must not reactivate it.'
}
Assert-ContainsLiteral -Text $Server -Literal 'A pre-tick replacement invalidates the configured subsystem cache' -Message 'GameServer must test engine-notified pre-tick cache invalidation.'
Assert-ContainsLiteral -Text $Server -Literal 'A-to-B-to-A before a tick never revives the old crash run' -Message 'GameServer must test pre-tick A-to-B-to-A reassociation.'
Assert-ContainsLiteral -Text $Server -Literal 'Reentrant B-to-C configuration cannot cache or emit B' -Message 'GameServer must test reentrant reassociation during configuration.'
Assert-ContainsLiteral -Text $Server -Literal 'Nested prechange ticks stay stale without reactivating the old association' -Message 'GameServer must test a nested tick during the prechange StateKey callback.'
Assert-ContainsLiteral -Text $Server -Literal 'Prechange cleanup does not strand the transition marker' -Message 'GameServer must test cleanup reentrancy during a GameInstance transition.'
Assert-ContainsLiteral -Text $Server -Literal 'First admitted tick initializes once after rejected transition tick' -Message 'GameServer must test initialization after a transition-rejected nested tick.'
Assert-ContainsLiteral -Text $Server -Literal 'First admitted second-world tick initializes once after nested rejection' -Message 'GameServer must test initialization after a second-world nested rejection.'
Assert-ContainsLiteral -Text $Server -Literal 'Disappeared subsystem aborts its admitted tick' -Message 'GameServer must test disappearance abort and later recovery.'
Assert-ContainsLiteral -Text $Server -Literal 'Reattached subsystem recovers after aborted disappearance' -Message 'GameServer must test recovery after an aborted disappearance.'
$ConfigureIndex = $FirstConfigureIndex
$CompleteIndex = $TickStart.IndexOf('CrashContext.CompleteWorldTickAdmission(Admission)', $ConfigureIndex, [StringComparison]::Ordinal)
$CacheIndex = $TickStart.IndexOf('ConfiguredSubsystems.Add(World, Subsystem);', [StringComparison]::Ordinal)
$EmitIndex = if ($CacheIndex -ge 0) { $TickStart.IndexOf('AethelnServerObservability::EmitEvent(', $CacheIndex, [StringComparison]::Ordinal) } else { -1 }
$EpochGuards = @([regex]::Matches($TickStart, 'WorldGameInstanceChangeEpoch != AdmissionEpoch') | Where-Object { $_.Index -gt $ConfigureIndex -and $_.Index -lt $CacheIndex } | ForEach-Object { $_.Index })
$AssociationGuards = @([regex]::Matches($TickStart, 'AethelnCrashContext::FindObservabilitySubsystem\(World\) != Subsystem') | Where-Object { $_.Index -gt $ConfigureIndex -and $_.Index -lt $CacheIndex } | ForEach-Object { $_.Index })
if ($ConfigureIndex -lt 0 -or $CompleteIndex -lt 0 -or $CacheIndex -lt 0 -or $EmitIndex -lt 0 -or
	$EpochGuards.Count -ne 2 -or $AssociationGuards.Count -ne 2 -or
	$EpochGuards[0] -le $ConfigureIndex -or $EpochGuards[0] -ge $CompleteIndex -or
	$AssociationGuards[0] -le $ConfigureIndex -or $AssociationGuards[0] -ge $CompleteIndex -or
	$EpochGuards[1] -le $CompleteIndex -or $EpochGuards[1] -ge $CacheIndex -or
	$AssociationGuards[1] -le $CompleteIndex -or $AssociationGuards[1] -ge $CacheIndex -or
	$CacheIndex -ge $EmitIndex) {
	throw 'GameServer must recheck exact association and epoch around admission completion before cache and lifecycle.'
}
$TickEndMatch = [regex]::Match($Server, 'void OnWorldTickEnd\((?<body>.*?)\n\t\}', [Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $TickEndMatch.Success -or
	-not $TickEndMatch.Groups['body'].Value.Contains('ConfiguredSubsystems.Find(World)') -or
	-not $TickEndMatch.Groups['body'].Value.Contains('Configured->Get() != Subsystem')) {
	throw 'GameServer must not sample health from an unconfigured replacement subsystem.'
}
Assert-ContainsLiteral -Text $Server -Literal 'Redirected tick does not sample C before configuration' -Message 'GameServer must test reentrant health-sampling suppression.'

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
Assert-ContainsLiteral -Text $Operator -Literal 'A marker alone never authorizes attribution' -Message 'A tentative marker must not be mistaken for active attribution.'
Assert-ContainsLiteral -Text $Operator -Literal 'External attribution is not established by reading the event stream alone' -Message 'Crash attribution limitation is missing.'
Assert-ContainsLiteral -Text $Operator -Literal 'fail closed on missing, stale, or ambiguous binding' -Message 'Controlled-capture binding requirement is missing.'
Assert-ContainsLiteral -Text $Operator -Literal 'A format check alone is not provenance' -Message 'Crash run format limitation is missing.'
Assert-ContainsLiteral -Text $Operator -Literal 'The capture covers the in-process log route only' -Message 'Evidence-marker test limitation is missing.'
if ($Operator.IndexOf("use that log's event stream", [StringComparison]::Ordinal) -ge 0) {
	throw 'Documentation must not claim the event stream attributes a crash run.'
}

Write-Output 'Observability contract and redaction checks passed.'
