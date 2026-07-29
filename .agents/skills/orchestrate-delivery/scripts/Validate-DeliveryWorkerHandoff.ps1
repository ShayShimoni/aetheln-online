[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[object]$Handoff,

	[Parameter(Mandatory)]
	[string[]]$PropertyNames
)

$ErrorActionPreference = 'Stop'

function Stop-WorkerRouteContract {
	param([Parameter(Mandatory)][string]$Code)
	throw "Worker route contract is invalid: $Code."
}

function Get-ObjectPropertyNames {
	param([AllowNull()][object]$Value)
	if ($null -eq $Value) { return @() }
	return @($Value.PSObject.Properties.Name)
}

function Test-ExactObjectNames {
	param(
		[AllowNull()][object]$Value,
		[Parameter(Mandatory)][string[]]$Expected
	)
	if ($null -eq $Value -or
		$Value -isnot [System.Management.Automation.PSCustomObject]) {
		return $false
	}
	$Actual = @(Get-ObjectPropertyNames -Value $Value)
	if ($Actual.Count -ne $Expected.Count) { return $false }
	foreach ($Name in $Expected) {
		if ($Actual -cnotcontains $Name) { return $false }
	}
	return $true
}

function Test-ExactStringSequence {
	param(
		[AllowNull()][object]$Value,
		[Parameter(Mandatory)][string[]]$Expected
	)
	if ($null -eq $Value -or $Value -is [string]) { return $false }
	$Actual = @($Value)
	if ($Actual.Count -ne $Expected.Count) { return $false }
	for ($Index = 0; $Index -lt $Expected.Count; $Index++) {
		if ($Actual[$Index] -isnot [string] -or
			$Actual[$Index] -cne $Expected[$Index]) {
			return $false
		}
	}
	return $true
}

function Test-JsonInteger {
	param([AllowNull()][object]$Value)
	return $Value -is [byte] -or $Value -is [sbyte] -or
		$Value -is [int16] -or $Value -is [uint16] -or
		$Value -is [int32] -or $Value -is [uint32] -or
		$Value -is [int64] -or $Value -is [uint64]
}

function Test-NonEmptyValue {
	param([AllowNull()][object]$Value)
	if ($null -eq $Value) { return $false }
	if ($Value -is [string]) {
		return -not [string]::IsNullOrWhiteSpace($Value)
	}
	if ($Value -is [System.Collections.IEnumerable] -and
		$Value -isnot [System.Management.Automation.PSCustomObject]) {
		return @($Value).Count -gt 0
	}
	if ($Value -is [System.Management.Automation.PSCustomObject]) {
		return @(Get-ObjectPropertyNames -Value $Value).Count -gt 0
	}
	return $true
}

$HasRoute = $PropertyNames -ccontains 'execution_route'
$ConsumesExternalFiles = $PropertyNames -ccontains 'consumes_external_files'
$HasExternalEvidence = $PropertyNames -ccontains 'external_ingest_evidence'
if ($ConsumesExternalFiles -ne $HasExternalEvidence) {
	Stop-WorkerRouteContract -Code 'external_ingest_gate_incomplete'
}
if ($ConsumesExternalFiles) {
	if ($Handoff.consumes_external_files -isnot [bool] -or
		-not $Handoff.consumes_external_files) {
		Stop-WorkerRouteContract -Code 'external_ingest_marker_invalid'
	}
	$EvidenceNames = @(
		'evidence_manifest_path', 'evidence_manifest_sha256',
		'external_manifest_path', 'external_manifest_sha256',
		'prepared_journal_path', 'prepared_journal_sha256',
		'source_commit', 'target_root'
	)
	if (-not (Test-ExactObjectNames `
			-Value $Handoff.external_ingest_evidence `
			-Expected $EvidenceNames)) {
		Stop-WorkerRouteContract -Code 'external_ingest_evidence_invalid'
	}
	$ExternalEvidence = $Handoff.external_ingest_evidence
	if ($ExternalEvidence.evidence_manifest_path -isnot [string] -or
		[string]::IsNullOrWhiteSpace($ExternalEvidence.evidence_manifest_path) -or
		$ExternalEvidence.evidence_manifest_sha256 -isnot [string] -or
		$ExternalEvidence.evidence_manifest_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
		$ExternalEvidence.external_manifest_path -isnot [string] -or
		[string]::IsNullOrWhiteSpace($ExternalEvidence.external_manifest_path) -or
		$ExternalEvidence.external_manifest_sha256 -isnot [string] -or
		$ExternalEvidence.external_manifest_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
		$ExternalEvidence.prepared_journal_path -isnot [string] -or
		[string]::IsNullOrWhiteSpace($ExternalEvidence.prepared_journal_path) -or
		$ExternalEvidence.prepared_journal_sha256 -isnot [string] -or
		$ExternalEvidence.prepared_journal_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
		$ExternalEvidence.source_commit -isnot [string] -or
		$ExternalEvidence.source_commit -cne [string]$Handoff.source_commit -or
		$ExternalEvidence.target_root -isnot [string] -or
		$ExternalEvidence.target_root -cne 'visuals') {
		Stop-WorkerRouteContract -Code 'external_ingest_evidence_invalid'
	}
}

if (-not $HasRoute) {
	if ($PropertyNames -cnotcontains 'work_package' -or
		-not (Test-NonEmptyValue -Value $Handoff.work_package)) {
		Stop-WorkerRouteContract -Code 'planned_package_required'
	}
	return
}

if ($Handoff.execution_route -isnot [string] -or
	@('planned', 'direct') -cnotcontains $Handoff.execution_route) {
	Stop-WorkerRouteContract -Code 'execution_route_invalid'
}

if ($Handoff.execution_route -ceq 'planned') {
	if ($PropertyNames -cnotcontains 'work_package' -or
		-not (Test-NonEmptyValue -Value $Handoff.work_package)) {
		Stop-WorkerRouteContract -Code 'planned_package_required'
	}
	return
}

if ($PropertyNames -ccontains 'work_package') {
	Stop-WorkerRouteContract -Code 'direct_package_forbidden'
}
if ($PropertyNames -cnotcontains 'classifier_evidence') {
	Stop-WorkerRouteContract -Code 'direct_classifier_required'
}
if ($PropertyNames -cnotcontains 'allowed_paths' -or
	$Handoff.allowed_paths -is [string] -or
	@($Handoff.allowed_paths).Count -ne 1 -or
	$Handoff.allowed_paths[0] -isnot [string] -or
	[string]::IsNullOrWhiteSpace($Handoff.allowed_paths[0])) {
	Stop-WorkerRouteContract -Code 'direct_scope_invalid'
}

$Classifier = $Handoff.classifier_evidence
$ClassifierNames = @(
	'schema_version', 'route', 'reason_codes', 'normalized_evidence',
	'previous_route', 'promotion_state', 'direct_skipped_stages',
	'required_downstream_stages', 'conditional_fresh_stages'
)
$NormalizedNames = @(
	'schema_version', 'current_route', 'change_category', 'expected_file_count',
	'localized_scope', 'clear_criteria', 'resolved_dependencies',
	'defined_change', 'reproducible_bug_evidence', 'known_verification',
	'known_rollback', 'assessment_source', 'calculation_heavy',
	'ambiguous_requirements', 'cross_component', 'behavior_sensitive',
	'security_or_permissions', 'data_persistence_or_migration',
	'networking_or_concurrency', 'public_contract_or_schema',
	'architecture_build_or_release', 'canonical_meaning_change', 'multi_file'
)

if (-not (Test-ExactObjectNames -Value $Classifier -Expected $ClassifierNames) -or
	-not (Test-JsonInteger -Value $Classifier.schema_version) -or
	[long]$Classifier.schema_version -ne 1 -or
	$Classifier.route -isnot [string] -or $Classifier.route -cne 'direct' -or
	$Classifier.previous_route -isnot [string] -or
	$Classifier.previous_route -cne 'direct' -or
	$Classifier.promotion_state -isnot [string] -or
	$Classifier.promotion_state -cne 'retained_direct' -or
	-not (Test-ExactStringSequence -Value $Classifier.reason_codes -Expected @('direct_eligible')) -or
	-not (Test-ExactStringSequence -Value $Classifier.direct_skipped_stages -Expected @('analyst', 'synthesizer')) -or
	-not (Test-ExactStringSequence -Value $Classifier.required_downstream_stages -Expected @('worker', 'verifier', 'reviewer', 'approver')) -or
	-not (Test-ExactStringSequence -Value $Classifier.conditional_fresh_stages -Expected @('integrator', 'fixer', 'adjudicator', 'qa'))) {
	Stop-WorkerRouteContract -Code 'direct_classifier_invalid'
}

$Evidence = $Classifier.normalized_evidence
if (-not (Test-ExactObjectNames -Value $Evidence -Expected $NormalizedNames) -or
	-not (Test-JsonInteger -Value $Evidence.schema_version) -or
	[long]$Evidence.schema_version -ne 1 -or
	$Evidence.current_route -isnot [string] -or
	$Evidence.current_route -cne 'direct' -or
	$Evidence.change_category -isnot [string] -or
	@('text_edit', 'small_line_change', 'localized_reproducible_bug_fix') -cnotcontains $Evidence.change_category -or
	-not (Test-JsonInteger -Value $Evidence.expected_file_count) -or
	[long]$Evidence.expected_file_count -ne 1 -or
	$Evidence.assessment_source -isnot [string] -or
	[string]::IsNullOrWhiteSpace($Evidence.assessment_source) -or
	$Evidence.multi_file -isnot [bool] -or $Evidence.multi_file) {
	Stop-WorkerRouteContract -Code 'direct_classifier_invalid'
}

foreach ($Name in @(
	'localized_scope', 'clear_criteria', 'resolved_dependencies',
	'defined_change', 'known_verification', 'known_rollback'
)) {
	if ($Evidence.$Name -isnot [bool] -or -not $Evidence.$Name) {
		Stop-WorkerRouteContract -Code 'direct_classifier_invalid'
	}
}

foreach ($Name in @(
	'calculation_heavy', 'ambiguous_requirements', 'cross_component',
	'behavior_sensitive', 'security_or_permissions',
	'data_persistence_or_migration', 'networking_or_concurrency',
	'public_contract_or_schema', 'architecture_build_or_release',
	'canonical_meaning_change'
)) {
	if ($Evidence.$Name -isnot [bool] -or $Evidence.$Name) {
		Stop-WorkerRouteContract -Code 'direct_classifier_invalid'
	}
}

if ($Evidence.change_category -ceq 'localized_reproducible_bug_fix') {
	if ($Evidence.reproducible_bug_evidence -isnot [bool] -or
		-not $Evidence.reproducible_bug_evidence) {
		Stop-WorkerRouteContract -Code 'direct_classifier_invalid'
	}
}
elseif ($null -ne $Evidence.reproducible_bug_evidence -and
	$Evidence.reproducible_bug_evidence -isnot [bool]) {
	Stop-WorkerRouteContract -Code 'direct_classifier_invalid'
}
