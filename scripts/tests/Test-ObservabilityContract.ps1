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
$OperatorPath = Join-Path $RepositoryRoot 'docs\observability-and-crash-diagnostics.md'
foreach ($Path in @($ContractPath, $SubsystemPath, $OperatorPath)) {
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		throw "Required observability contract '$Path' is missing."
	}
}

$Contract = Get-Content -LiteralPath $ContractPath -Raw
$Subsystem = Get-Content -LiteralPath $SubsystemPath -Raw
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

# Unreal FString == and != compare case-insensitively, so schema identities must
# use explicit case-sensitive comparisons to reject case-only variants.
$CaseInsensitiveSchemaComparison = [regex]::Match($Contract, 'SchemaId\s*[!=]=')
if ($CaseInsensitiveSchemaComparison.Success) {
	throw "Schema identity uses case-insensitive comparison '$($CaseInsensitiveSchemaComparison.Value)'; use Equals with ESearchCase::CaseSensitive."
}
foreach ($Required in @('MaxIdentifierLength', 'MaxPendingDispatchItems', 'IsSafeIdentifier', 'IsValidForEvent', 'SchemaId.Equals(AethelnObservability::SchemaId, ESearchCase::CaseSensitive)', 'NetworkProfile.SchemaId.Equals(AethelnNetworkSpike::NetworkProfileSchemaId, ESearchCase::CaseSensitive)', 'SchemaVersion == AethelnObservability::SchemaVersion', 'Sequence != 0', 'IsBounded()', 'MakePublicCopy()', 'FAethelnNoOpObservabilitySink', 'FAethelnStructuredLogObservabilitySink', 'FAethelnInMemoryObservabilitySink', 'IAethelnRestrictedAuditSink', 'FAethelnBoundedRestrictedAuditSink', 'FDispatchState', 'WaitForIdleForTests', 'PawnCount', 'ControllerCount', 'PlayerStateCount', 'OtherActorCount')) {
	Assert-ContainsLiteral -Text $Contract -Literal $Required -Message "Required bounded/failure-safe contract '$Required' is missing."
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

Write-Output 'Observability contract and redaction checks passed.'
