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
$ServerPath = Join-Path $RepositoryRoot 'Source\GameServer\Private\GameServer.cpp'
$OperatorPath = Join-Path $RepositoryRoot 'docs\observability-and-crash-diagnostics.md'
foreach ($Path in @($ContractPath, $SubsystemPath, $ServerPath, $OperatorPath)) {
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		throw "Required observability contract '$Path' is missing."
	}
}

$Contract = Get-Content -LiteralPath $ContractPath -Raw
$Subsystem = Get-Content -LiteralPath $SubsystemPath -Raw
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
Assert-ContainsLiteral -Text $Subsystem -Literal 'TryGetCrashContextSnapshot(FAethelnCrashContextSnapshot& OutSnapshot) const' -Message 'Crash-context snapshot must be exposed only as a validated copy.'

foreach ($Key in @(
	'AethelnObservabilitySchema', 'AethelnServerLifecycle', 'AethelnCrashContextState',
	'AethelnCrashContextSchemaVersion', 'AethelnSourceRevision', 'AethelnBuildIdentity',
	'AethelnBuildConfiguration', 'AethelnEngineRevision', 'AethelnToolchainIdentity',
	'AethelnNetworkProfileSchema', 'AethelnNetworkProfileVersion', 'AethelnNetworkProfileId',
	'AethelnFlowKind', 'AethelnRunId', 'AethelnServerInstance', 'AethelnConnectionPseudonym'
)) {
	Assert-ContainsLiteral -Text $Server -Literal "TEXT(`"$Key`")" -Message "Stable crash GameData key '$Key' is missing."
}
foreach ($State in @('missing', 'updating', 'active', 'ambiguous', 'stale')) {
	Assert-ContainsLiteral -Text $Server -Literal "TEXT(`"$State`")" -Message "Closed crash-context state '$State' is missing."
}
if ($Server.IndexOf('ResetGameData', [StringComparison]::Ordinal) -ge 0) {
	throw 'GameServer must remove only its owned crash keys and never call ResetGameData.'
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

Write-Output 'Observability contract and redaction checks passed.'
