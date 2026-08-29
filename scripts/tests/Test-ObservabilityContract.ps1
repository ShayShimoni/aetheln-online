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
	Assert-ContainsLiteral $Contract $Category "Closed observability category '$Category' is missing."
}

foreach ($Flow in @(
	'Admission', 'Lease', 'PersistentCommand', 'Transaction', 'Outbox',
	'Reward', 'Transfer', 'Allocation', 'Dependency', 'Restore', 'Reconciliation'
)) {
	Assert-ContainsLiteral $Contract $Flow "Versioned 1.0 flow extension '$Flow' is missing."
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
	Assert-ContainsLiteral $Contract $Required "Required bounded/failure-safe contract '$Required' is missing."
}
Assert-ContainsLiteral $Subsystem 'UGameInstanceSubsystem' 'Observability service must remain GameInstance-owned.'
Assert-ContainsLiteral $Subsystem 'SetTestRestrictedSink' 'Restricted audit injection must remain separate from the public sink.'
Assert-ContainsLiteral $Operator '| `local` |' 'Local environment boundary is missing.'
Assert-ContainsLiteral $Operator '| `development` |' 'Development environment boundary is missing.'
Assert-ContainsLiteral $Operator 'retention is `TBD`' 'Unresolved retention must remain explicit.'
Assert-ContainsLiteral $Operator 'process-local restricted audit buffer' 'Restricted diagnostic retention boundary is missing.'
Assert-ContainsLiteral $Operator 'control-character-bearing record is' 'Malformed identifier rejection boundary is missing.'
Assert-ContainsLiteral $Operator 'independently scheduled background workers' 'Non-blocking independent dispatch boundary is missing.'
Assert-ContainsLiteral $Operator 'Issue #44 owns' 'Packaged orchestration ownership boundary is missing.'
Assert-ContainsLiteral $Operator 'Issue #45 owns' 'Performance-budget ownership boundary is missing.'

Write-Output 'Observability contract and redaction checks passed.'
