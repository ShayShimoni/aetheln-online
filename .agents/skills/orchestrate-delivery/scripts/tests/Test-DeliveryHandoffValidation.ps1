[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $PSScriptRoot
$SkillRoot = Split-Path -Parent $ScriptRoot
$RepositoryRoot = (Resolve-Path (Join-Path $SkillRoot '..\..\..')).Path
$ValidatorPath = Join-Path $ScriptRoot 'Validate-DeliveryHandoff.ps1'
$SchemaPath = Join-Path $SkillRoot 'references\handoff-schemas.json'
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
	'aetheln-delivery-handoff-validation-tests-' + [guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $TestRoot | Out-Null

$Results = [System.Collections.Generic.List[object]]::new()
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$Utf8Bom = [System.Text.UTF8Encoding]::new($true)

function Add-Result {
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][bool]$Passed,
		[string]$Detail = ''
	)
	$Results.Add([pscustomobject]@{ Name = $Name; Passed = $Passed; Detail = $Detail })
}

function Write-Fixture {
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][string]$Json,
		[Parameter(Mandatory)][System.Text.Encoding]$Encoding
	)
	$Path = Join-Path $TestRoot $Name
	[System.IO.File]::WriteAllText($Path, $Json, $Encoding)
	return $Path
}

function New-EvidenceRecord {
	param(
		[Parameter(Mandatory)][string]$Kind,
		[Parameter(Mandatory)][string]$Provenance,
		[Parameter(Mandatory)][string]$Source,
		[Parameter(Mandatory)][AllowEmptyString()][string]$Text,
		[ValidateSet('utf8', 'base64')][string]$Encoding = 'utf8'
	)
	$Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
	$Hasher = [System.Security.Cryptography.SHA256]::Create()
	try {
		$Hash = [System.BitConverter]::ToString(
			$Hasher.ComputeHash($Bytes)
		).Replace('-', '').ToLowerInvariant()
	}
	finally {
		$Hasher.Dispose()
	}
	$Content = if ($Encoding -eq 'base64') {
		[System.Convert]::ToBase64String($Bytes)
	}
	else {
		$Text
	}
	return [ordered]@{
		kind = $Kind
		provenance = $Provenance
		encoding = $Encoding
		source = $Source
		sha256 = $Hash
		content = $Content
	}
}

function Copy-JsonObject {
	param([Parameter(Mandatory)][object]$Value)
	return ($Value | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json)
}

function Invoke-RejectionCase {
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][string]$Json,
		[Parameter(Mandatory)][string]$ExpectedPattern,
		[Parameter(Mandatory)][string]$PrivateMarker
	)
	$Path = Write-Fixture -Name "$Name.json" -Json $Json -Encoding $Utf8NoBom
	$Message = ''
	try {
		& $ValidatorPath -HandoffPath $Path -SchemaPath $SchemaPath | Out-Null
	}
	catch {
		$Message = $_.Exception.Message
	}
	Add-Result -Name $Name -Passed (
		-not [string]::IsNullOrWhiteSpace($Message) -and
		$Message -match $ExpectedPattern -and
		$Message -notmatch [regex]::Escape($PrivateMarker)
	) -Detail $Message
}

function Invoke-AcceptanceCase {
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][object]$Handoff,
		[string]$ExpectedStage = 'worker'
	)
	$Path = Write-Fixture `
		-Name "$($Name.Replace(' ', '-')).json" `
		-Json ($Handoff | ConvertTo-Json -Depth 12 -Compress) `
		-Encoding $Utf8NoBom
	try {
		$Result = & $ValidatorPath -HandoffPath $Path -SchemaPath $SchemaPath
		Add-Result -Name $Name -Passed ($Result.Stage -eq $ExpectedStage)
	}
	catch {
		Add-Result -Name $Name -Passed $false -Detail $_.Exception.Message
	}
}

function Invoke-WorkerRejectionCase {
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][object]$Handoff,
		[Parameter(Mandatory)][string]$ExpectedCode,
		[Parameter(Mandatory)][string]$PrivateMarker
	)
	$Handoff.ticket = $PrivateMarker
	Invoke-RejectionCase `
		-Name $Name `
		-Json ($Handoff | ConvertTo-Json -Depth 12 -Compress) `
		-ExpectedPattern ([regex]::Escape($ExpectedCode)) `
		-PrivateMarker $PrivateMarker
}

function New-DirectClassifier {
	param(
		[string]$ChangeCategory = 'text_edit',
		[AllowNull()][object]$ReproducibleBugEvidence = $false
	)
	return [ordered]@{
		schema_version = 1
		route = 'direct'
		reason_codes = @('direct_eligible')
		normalized_evidence = [ordered]@{
			schema_version = 1
			current_route = 'direct'
			change_category = $ChangeCategory
			expected_file_count = 1
			localized_scope = $true
			clear_criteria = $true
			resolved_dependencies = $true
			defined_change = $true
			reproducible_bug_evidence = $ReproducibleBugEvidence
			known_verification = $true
			known_rollback = $true
			assessment_source = 'Issue #70 evidence'
			calculation_heavy = $false
			ambiguous_requirements = $false
			cross_component = $false
			behavior_sensitive = $false
			security_or_permissions = $false
			data_persistence_or_migration = $false
			networking_or_concurrency = $false
			public_contract_or_schema = $false
			architecture_build_or_release = $false
			canonical_meaning_change = $false
			multi_file = $false
		}
		previous_route = 'direct'
		promotion_state = 'retained_direct'
		direct_skipped_stages = @('analyst', 'synthesizer')
		required_downstream_stages = @('worker', 'verifier', 'reviewer', 'approver')
		conditional_fresh_stages = @('integrator', 'fixer', 'adjudicator', 'qa')
	}
}

$BaseHandoff = [ordered]@{
	schema_version = 1
	stage = 'analyst'
	run_id = 'strict-json-test'
	workspace_root = $RepositoryRoot
	source_commit = '0000000000000000000000000000000000000000'
	ticket = 'Issue #70'
	acceptance_criteria = @('Validate strict JSON.')
	canonical_sources = @('AGENTS.md')
	output_contract = 'Return validation evidence.'
	board_export = New-EvidenceRecord -Kind 'text' -Provenance 'external' `
		-Source 'board.json' -Text '{"items":[]}'
	repository_tree = New-EvidenceRecord -Kind 'text' -Provenance 'repository' `
		-Source 'tree.txt' -Text 'AGENTS.md'
	repository_state = New-EvidenceRecord -Kind 'status' -Provenance 'launcher' `
		-Source 'status.txt' -Text 'clean'
	execution_policy = [ordered]@{ attempt_ordinal = 1 }
}
$ValidJson = $BaseHandoff | ConvertTo-Json -Depth 8 -Compress

foreach ($EncodingCase in @(
	@('Valid handoff is accepted', 'valid.json', $Utf8NoBom),
	@('UTF-8 BOM handoff is accepted', 'utf8-bom.json', $Utf8Bom)
)) {
	$Path = Write-Fixture -Name $EncodingCase[1] -Json $ValidJson -Encoding $EncodingCase[2]
	try {
		$Result = & $ValidatorPath -HandoffPath $Path -SchemaPath $SchemaPath
		Add-Result -Name $EncodingCase[0] -Passed (
			$Result.Stage -eq 'analyst' -and
			$Result.RunId -eq 'strict-json-test' -and
			$Result.HandoffJson[0] -ne [char]0xfeff
		)
	}
	catch {
		Add-Result -Name $EncodingCase[0] -Passed $false -Detail $_.Exception.Message
	}
}

$PrivateInvalidUtf8Marker = 'private-invalid-utf8-marker'
$InvalidUtf8Placeholder = '__INVALID_UTF8__'
$InvalidUtf8Json = $ValidJson.Replace(
	'Issue #70',
	$PrivateInvalidUtf8Marker + $InvalidUtf8Placeholder
)
$InvalidUtf8Offset = $InvalidUtf8Json.IndexOf(
	$InvalidUtf8Placeholder,
	[System.StringComparison]::Ordinal
)
$InvalidUtf8Bytes = [System.Collections.Generic.List[byte]]::new()
$InvalidUtf8Bytes.AddRange($Utf8NoBom.GetBytes($InvalidUtf8Json.Substring(0, $InvalidUtf8Offset)))
$InvalidUtf8Bytes.AddRange([byte[]]@(0xc3, 0x28))
$InvalidUtf8Bytes.AddRange($Utf8NoBom.GetBytes(
	$InvalidUtf8Json.Substring($InvalidUtf8Offset + $InvalidUtf8Placeholder.Length)
))
$InvalidUtf8Path = Join-Path $TestRoot 'invalid-utf8.json'
[System.IO.File]::WriteAllBytes($InvalidUtf8Path, $InvalidUtf8Bytes.ToArray())
$InvalidUtf8Message = ''
try {
	& $ValidatorPath -HandoffPath $InvalidUtf8Path -SchemaPath $SchemaPath | Out-Null
}
catch {
	$InvalidUtf8Message = $_.Exception.Message
}
Add-Result -Name 'Invalid UTF-8 handoff is rejected without exposing payload data' -Passed (
	$InvalidUtf8Message -eq 'Handoff JSON is not valid UTF-8.' -and
	$InvalidUtf8Message -notmatch [regex]::Escape($PrivateInvalidUtf8Marker)
) -Detail $InvalidUtf8Message

$Cases = @(
	@(
		'Duplicate top-level member is rejected',
		$ValidJson.Replace('"schema_version":1', '"schema_version":1,"schema_version":"private-top-level-value"'),
		'duplicate.*schema_version|schema_version.*duplicate',
		'private-top-level-value'
	),
	@(
		'Duplicate nested member is rejected',
		$ValidJson.Replace('"attempt_ordinal":1', '"attempt_ordinal":1,"attempt_ordinal":"private-nested-value"'),
		'duplicate.*attempt_ordinal|attempt_ordinal.*duplicate',
		'private-nested-value'
	),
	@(
		'String schema_version is rejected',
		$ValidJson.Replace('"schema_version":1', '"schema_version":"private-schema-value"'),
		'schema_version.*integer|integer.*schema_version',
		'private-schema-value'
	),
	@(
		'Decimal schema_version is rejected',
		$ValidJson.Replace('"schema_version":1', '"schema_version":70.125789'),
		'schema_version.*integer|integer.*schema_version',
		'70.125789'
	),
	@(
		'Unsupported numeric schema_version is rejected',
		$ValidJson.Replace('"schema_version":1', '"schema_version":70999991'),
		'schema_version.*integer|integer.*schema_version',
		'70999991'
	)
)
foreach ($Case in $Cases) {
	Invoke-RejectionCase -Name $Case[0] -Json $Case[1] -ExpectedPattern $Case[2] -PrivateMarker $Case[3]
}

$BaseWorkerHandoff = @{
	schema_version = 1
	stage = 'worker'
	run_id = 'worker-route-test'
	workspace_root = $RepositoryRoot
	source_commit = '0000000000000000000000000000000000000000'
	ticket = 'Issue #70'
	acceptance_criteria = @('Validate the worker route contract.')
	canonical_sources = @('AGENTS.md')
	output_contract = 'Return a unified diff.'
	allowed_paths = @('docs/example.md')
	non_goals = @('Production changes')
	required_checks = @('Parse the test.')
	baseline_status = 'clean'
	baseline_diff = ''
}

$LegacyPlanned = $BaseWorkerHandoff.Clone()
$LegacyPlanned.work_package = 'Legacy planned package.'
Invoke-AcceptanceCase -Name 'Legacy planned worker is accepted' -Handoff $LegacyPlanned

$ExplicitPlanned = $BaseWorkerHandoff.Clone()
$ExplicitPlanned.execution_route = 'planned'
$ExplicitPlanned.work_package = 'Explicit planned package.'
Invoke-AcceptanceCase -Name 'Explicit planned worker is accepted' -Handoff $ExplicitPlanned

$CleanPlanned = $BaseWorkerHandoff.Clone()
$CleanPlanned.execution_route = 'planned'
$CleanPlanned.work_package = 'Clean planned package.'
$CleanPlanned.baseline_status = ''
Invoke-AcceptanceCase `
	-Name 'Clean worker baselines are accepted' `
	-Handoff $CleanPlanned

$ExternalGate = $BaseWorkerHandoff.Clone()
$ExternalGate.execution_route = 'planned'
$ExternalGate.work_package = 'External-file consuming package.'
$ExternalGate.consumes_external_files = $true
$ExternalGate.external_ingest_evidence = [ordered]@{
	evidence_manifest_path = 'C:\delivery\evidence.json'
	evidence_manifest_sha256 = '1' * 64
	external_manifest_path = 'C:\delivery\external-manifest.json'
	external_manifest_sha256 = '2' * 64
	prepared_journal_path = 'C:\delivery\prepared-journal.json'
	prepared_journal_sha256 = '3' * 64
	source_commit = $ExternalGate.source_commit
	target_root = 'visuals'
}
Invoke-AcceptanceCase `
	-Name 'Complete external-ingest worker marker is accepted' `
	-Handoff $ExternalGate

$MarkerOnly = $BaseWorkerHandoff.Clone()
$MarkerOnly.execution_route = 'planned'
$MarkerOnly.work_package = 'Marker only.'
$MarkerOnly.consumes_external_files = $true
Invoke-WorkerRejectionCase `
	-Name 'External worker marker without evidence is rejected' `
	-Handoff $MarkerOnly `
	-ExpectedCode 'external_ingest_gate_incomplete' `
	-PrivateMarker 'private-marker-only'

$EvidenceOnly = $BaseWorkerHandoff.Clone()
$EvidenceOnly.execution_route = 'planned'
$EvidenceOnly.work_package = 'Evidence only.'
$EvidenceOnly.external_ingest_evidence = $ExternalGate.external_ingest_evidence
Invoke-WorkerRejectionCase `
	-Name 'External evidence without worker marker is rejected' `
	-Handoff $EvidenceOnly `
	-ExpectedCode 'external_ingest_gate_incomplete' `
	-PrivateMarker 'private-evidence-only'

$FalseMarker = $BaseWorkerHandoff.Clone()
$FalseMarker.execution_route = 'planned'
$FalseMarker.work_package = 'False marker.'
$FalseMarker.consumes_external_files = $false
$FalseMarker.external_ingest_evidence = $ExternalGate.external_ingest_evidence
Invoke-WorkerRejectionCase `
	-Name 'False external worker marker is rejected' `
	-Handoff $FalseMarker `
	-ExpectedCode 'external_ingest_marker_invalid' `
	-PrivateMarker 'private-false-marker'

$WrongCommitEvidence = $BaseWorkerHandoff.Clone()
$WrongCommitEvidence.execution_route = 'planned'
$WrongCommitEvidence.work_package = 'Wrong commit evidence.'
$WrongCommitEvidence.consumes_external_files = $true
$WrongCommitEvidence.external_ingest_evidence = [ordered]@{
	evidence_manifest_path = 'C:\delivery\evidence.json'
	evidence_manifest_sha256 = '1' * 64
	external_manifest_path = 'C:\delivery\external-manifest.json'
	external_manifest_sha256 = '2' * 64
	prepared_journal_path = 'C:\delivery\prepared-journal.json'
	prepared_journal_sha256 = '3' * 64
	source_commit = '2' * 40
	target_root = 'visuals'
}
Invoke-WorkerRejectionCase `
	-Name 'External evidence with wrong source commit is rejected' `
	-Handoff $WrongCommitEvidence `
	-ExpectedCode 'external_ingest_evidence_invalid' `
	-PrivateMarker 'private-wrong-external-commit'

$DirectTextEdit = $BaseWorkerHandoff.Clone()
$DirectTextEdit.execution_route = 'direct'
$DirectTextEdit.classifier_evidence = New-DirectClassifier `
	-ChangeCategory 'text_edit' `
	-ReproducibleBugEvidence $false
Invoke-AcceptanceCase -Name 'Direct text edit is accepted' -Handoff $DirectTextEdit

$DirectBugFix = $BaseWorkerHandoff.Clone()
$DirectBugFix.execution_route = 'direct'
$DirectBugFix.classifier_evidence = New-DirectClassifier `
	-ChangeCategory 'localized_reproducible_bug_fix' `
	-ReproducibleBugEvidence $true
Invoke-AcceptanceCase -Name 'Direct reproducible bug fix is accepted' -Handoff $DirectBugFix

$ExplicitPlannedWithoutPackage = $BaseWorkerHandoff.Clone()
$ExplicitPlannedWithoutPackage.execution_route = 'planned'
Invoke-WorkerRejectionCase `
	-Name 'Explicit planned worker without package is rejected' `
	-Handoff $ExplicitPlannedWithoutPackage `
	-ExpectedCode 'planned_package_required' `
	-PrivateMarker 'private-planned-package-marker'

$DirectBugWithoutEvidence = $BaseWorkerHandoff.Clone()
$DirectBugWithoutEvidence.execution_route = 'direct'
$DirectBugWithoutEvidence.classifier_evidence = New-DirectClassifier `
	-ChangeCategory 'localized_reproducible_bug_fix' `
	-ReproducibleBugEvidence $false
Invoke-WorkerRejectionCase `
	-Name 'Direct bug without reproducible evidence is rejected' `
	-Handoff $DirectBugWithoutEvidence `
	-ExpectedCode 'direct_classifier_invalid' `
	-PrivateMarker 'private-bug-evidence-marker'

$PlannedClassifier = $BaseWorkerHandoff.Clone()
$PlannedClassifier.execution_route = 'direct'
$PlannedClassifier.classifier_evidence = New-DirectClassifier
$PlannedClassifier.classifier_evidence.route = 'planned'
Invoke-WorkerRejectionCase `
	-Name 'Direct worker with planned classifier is rejected' `
	-Handoff $PlannedClassifier `
	-ExpectedCode 'direct_classifier_invalid' `
	-PrivateMarker 'private-planned-classifier-marker'

$TwoFileClassifier = $BaseWorkerHandoff.Clone()
$TwoFileClassifier.execution_route = 'direct'
$TwoFileClassifier.classifier_evidence = New-DirectClassifier
$TwoFileClassifier.classifier_evidence.normalized_evidence.expected_file_count = 2
Invoke-WorkerRejectionCase `
	-Name 'Direct worker with two-file classifier is rejected' `
	-Handoff $TwoFileClassifier `
	-ExpectedCode 'direct_classifier_invalid' `
	-PrivateMarker 'private-file-count-marker'

$IncompleteClassifier = $BaseWorkerHandoff.Clone()
$IncompleteClassifier.execution_route = 'direct'
$IncompleteClassifier.classifier_evidence = New-DirectClassifier
$IncompleteClassifier.classifier_evidence.Remove('promotion_state')
Invoke-WorkerRejectionCase `
	-Name 'Direct worker with incomplete classifier is rejected' `
	-Handoff $IncompleteClassifier `
	-ExpectedCode 'direct_classifier_invalid' `
	-PrivateMarker 'private-incomplete-classifier-marker'

$DirectWithPackage = $BaseWorkerHandoff.Clone()
$DirectWithPackage.execution_route = 'direct'
$DirectWithPackage.work_package = 'Forbidden direct package.'
$DirectWithPackage.classifier_evidence = New-DirectClassifier
Invoke-WorkerRejectionCase `
	-Name 'Direct worker with package is rejected' `
	-Handoff $DirectWithPackage `
	-ExpectedCode 'direct_package_forbidden' `
	-PrivateMarker 'private-direct-package-marker'

$DirectWithoutClassifier = $BaseWorkerHandoff.Clone()
$DirectWithoutClassifier.execution_route = 'direct'
Invoke-WorkerRejectionCase `
	-Name 'Direct worker without classifier is rejected' `
	-Handoff $DirectWithoutClassifier `
	-ExpectedCode 'direct_classifier_required' `
	-PrivateMarker 'private-missing-classifier-marker'

$DirectWithTwoPaths = $BaseWorkerHandoff.Clone()
$DirectWithTwoPaths.execution_route = 'direct'
$DirectWithTwoPaths.allowed_paths = @('docs/one.md', 'docs/two.md')
$DirectWithTwoPaths.classifier_evidence = New-DirectClassifier
Invoke-WorkerRejectionCase `
	-Name 'Direct worker with two allowed paths is rejected' `
	-Handoff $DirectWithTwoPaths `
	-ExpectedCode 'direct_scope_invalid' `
	-PrivateMarker 'private-direct-scope-marker'

$BaseReviewerHandoff = [ordered]@{
	schema_version = 1
	stage = 'reviewer'
	run_id = 'neutral-evidence-test'
	workspace_root = $RepositoryRoot
	source_commit = '0000000000000000000000000000000000000000'
	ticket = 'Issue #70'
	acceptance_criteria = @('Validate typed neutral evidence.')
	canonical_sources = @('AGENTS.md')
	output_contract = 'Return review evidence.'
	baseline_status = New-EvidenceRecord -Kind 'status' -Provenance 'launcher' `
		-Source 'baseline-status.txt' -Text 'clean'
	baseline_diff = New-EvidenceRecord -Kind 'diff' -Provenance 'launcher' `
		-Source 'baseline.diff' -Text ''
	allowed_paths = @('docs/example.md')
	non_goals = @('Production changes')
	final_diff = New-EvidenceRecord -Kind 'diff' -Provenance 'launcher' `
		-Source 'candidate.diff' -Text 'diff --git a/docs/example.md b/docs/example.md'
	artifact_state = New-EvidenceRecord -Kind 'status' -Provenance 'launcher' `
		-Source 'artifact-state.txt' -Text 'validated'
	raw_check_output = @(
		(New-EvidenceRecord -Kind 'command_log' -Provenance 'launcher' `
			-Source 'git-diff-check.log' -Text 'git diff --check passed')
	)
}

Invoke-AcceptanceCase `
	-Name 'Reviewer typed evidence envelope is accepted' `
	-Handoff $BaseReviewerHandoff `
	-ExpectedStage 'reviewer'

$Base64Reviewer = Copy-JsonObject $BaseReviewerHandoff
$Base64Reviewer.raw_check_output = @(
	(New-EvidenceRecord -Kind 'command_log' -Provenance 'launcher' `
		-Source 'unicode-command.log' -Text 'check passed base64 payload' -Encoding 'base64')
)
Invoke-AcceptanceCase `
	-Name 'Canonical base64 command log is accepted' `
	-Handoff $Base64Reviewer `
	-ExpectedStage 'reviewer'

$OpaqueCommandLogText = 'command output contains prior_verdict and remains opaque'
$Utf8OpaqueReviewer = Copy-JsonObject $BaseReviewerHandoff
$Utf8OpaqueReviewer.raw_check_output = @(
	(New-EvidenceRecord -Kind 'command_log' -Provenance 'launcher' `
		-Source 'opaque-command.log' -Text $OpaqueCommandLogText)
)
Invoke-AcceptanceCase `
	-Name 'UTF-8 command log content containing prohibited marker is accepted' `
	-Handoff $Utf8OpaqueReviewer `
	-ExpectedStage 'reviewer'

$Base64OpaqueReviewer = Copy-JsonObject $BaseReviewerHandoff
$Base64OpaqueReviewer.raw_check_output = @(
	(New-EvidenceRecord -Kind 'command_log' -Provenance 'launcher' `
		-Source 'opaque-command.log' -Text $OpaqueCommandLogText -Encoding 'base64')
)
Invoke-AcceptanceCase `
	-Name 'Canonical base64 command log content containing prohibited marker is accepted' `
	-Handoff $Base64OpaqueReviewer `
	-ExpectedStage 'reviewer'

function Invoke-NeutralEvidenceRejectionCase {
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][object]$Handoff,
		[string]$PrivateMarker = 'private-neutral-marker'
	)
	Invoke-RejectionCase `
		-Name $Name `
		-Json ($Handoff | ConvertTo-Json -Depth 20 -Compress) `
		-ExpectedPattern 'neutral|evidence|record|raw_check_output|baseline_status|kind|provenance|encoding|source|sha256|content|cardinality' `
		-PrivateMarker $PrivateMarker
}

$MarkerInEvidenceSource = Copy-JsonObject $BaseReviewerHandoff
$PrivateEvidenceSource = 'private-prior_verdict-source-marker'
$MarkerInEvidenceSource.raw_check_output[0].source = $PrivateEvidenceSource
Invoke-RejectionCase `
	-Name 'Prohibited marker in evidence source metadata is rejected' `
	-Json ($MarkerInEvidenceSource | ConvertTo-Json -Depth 20 -Compress) `
	-ExpectedPattern 'prohibited blind-stage marker' `
	-PrivateMarker $PrivateEvidenceSource

$CanonicalRootMarkers = Copy-JsonObject $BaseReviewerHandoff
$CanonicalRootMarkers.acceptance_criteria = @(
	'Address the prior_findings vocabulary defined by the ticket.'
)
$CanonicalRootMarkers.output_contract = (
	'Return evidence matching the reviewer_conclusion contract.'
)
Invoke-AcceptanceCase `
	-Name 'Canonical root values containing prohibited markers are accepted' `
	-Handoff $CanonicalRootMarkers `
	-ExpectedStage 'reviewer'

$MarkerInOrdinaryField = Copy-JsonObject $BaseReviewerHandoff
$PrivateOrdinaryMarker = 'private-prior_verdict-non-goal-marker'
$MarkerInOrdinaryField.non_goals = @($PrivateOrdinaryMarker)
Invoke-RejectionCase `
	-Name 'Prohibited marker in ordinary stage-specific field is rejected' `
	-Json ($MarkerInOrdinaryField | ConvertTo-Json -Depth 20 -Compress) `
	-ExpectedPattern 'prohibited blind-stage marker' `
	-PrivateMarker $PrivateOrdinaryMarker

$ProhibitedPropertyName = Copy-JsonObject $BaseReviewerHandoff
$PrivatePropertyValue = 'private-property-value-marker'
$ProhibitedPropertyName.ticket = [ordered]@{
	prior_verdict = $PrivatePropertyValue
}
Invoke-RejectionCase `
	-Name 'Prohibited property name is rejected before its value is scanned' `
	-Json ($ProhibitedPropertyName | ConvertTo-Json -Depth 20 -Compress) `
	-ExpectedPattern 'prohibited blind-stage marker' `
	-PrivateMarker $PrivatePropertyValue

$InjectedSummary = Copy-JsonObject $BaseReviewerHandoff
$InjectedSummary.raw_check_output[0] | Add-Member -NotePropertyName agent_summary `
	-NotePropertyValue 'private-agent-summary-marker'
Invoke-NeutralEvidenceRejectionCase `
	-Name 'Nested agent summary injection is rejected' `
	-Handoff $InjectedSummary `
	-PrivateMarker 'private-agent-summary-marker'

$ExtraKey = Copy-JsonObject $BaseReviewerHandoff
$ExtraKey.raw_check_output[0] | Add-Member -NotePropertyName extra `
	-NotePropertyValue 'private-extra-key-marker'
Invoke-NeutralEvidenceRejectionCase `
	-Name 'Extra evidence record key is rejected' `
	-Handoff $ExtraKey `
	-PrivateMarker 'private-extra-key-marker'

foreach ($MissingKey in @('kind', 'provenance', 'encoding', 'source', 'sha256', 'content')) {
	$MissingRecordKey = Copy-JsonObject $BaseReviewerHandoff
	$MissingRecordKey.raw_check_output[0].PSObject.Properties.Remove($MissingKey)
	Invoke-NeutralEvidenceRejectionCase `
		-Name "Missing evidence record key $MissingKey is rejected" `
		-Handoff $MissingRecordKey
}

$InvalidValues = @(
	@('Invalid evidence kind is rejected', 'kind', 'private-kind-marker'),
	@('Invalid evidence provenance is rejected', 'provenance', 'private-provenance-marker'),
	@('Invalid evidence encoding is rejected', 'encoding', 'private-encoding-marker'),
	@('Blank evidence source is rejected', 'source', '   '),
	@('Invalid evidence sha256 is rejected', 'sha256', 'private-sha256-marker')
)
foreach ($InvalidValue in $InvalidValues) {
	$InvalidRecord = Copy-JsonObject $BaseReviewerHandoff
	$InvalidRecord.raw_check_output[0].($InvalidValue[1]) = $InvalidValue[2]
	Invoke-NeutralEvidenceRejectionCase `
		-Name $InvalidValue[0] `
		-Handoff $InvalidRecord `
		-PrivateMarker $InvalidValue[2]
}

$WrongKindMapping = Copy-JsonObject $BaseReviewerHandoff
$WrongKindMapping.raw_check_output[0].kind = 'text'
Invoke-NeutralEvidenceRejectionCase `
	-Name 'Evidence kind outside stage field mapping is rejected' `
	-Handoff $WrongKindMapping

$WrongProvenanceMapping = Copy-JsonObject $BaseReviewerHandoff
$WrongProvenanceMapping.raw_check_output[0].provenance = 'external'
Invoke-NeutralEvidenceRejectionCase `
	-Name 'Evidence provenance outside stage field mapping is rejected' `
	-Handoff $WrongProvenanceMapping

$NonStringContent = Copy-JsonObject $BaseReviewerHandoff
$NonStringContent.raw_check_output[0].content = [ordered]@{ nested = 'private-content-marker' }
Invoke-NeutralEvidenceRejectionCase `
	-Name 'Non-string evidence content is rejected' `
	-Handoff $NonStringContent `
	-PrivateMarker 'private-content-marker'

$MalformedBase64 = Copy-JsonObject $Base64Reviewer
$MalformedBase64.raw_check_output[0].content = 'private-not-base64-marker!'
Invoke-NeutralEvidenceRejectionCase `
	-Name 'Malformed base64 evidence is rejected' `
	-Handoff $MalformedBase64 `
	-PrivateMarker 'private-not-base64-marker!'

$NonCanonicalBase64 = Copy-JsonObject $Base64Reviewer
$CanonicalContent = [string]$NonCanonicalBase64.raw_check_output[0].content
$NonCanonicalBase64.raw_check_output[0].content = $CanonicalContent.Insert(2, ' ')
Invoke-NeutralEvidenceRejectionCase `
	-Name 'Noncanonical base64 evidence is rejected' `
	-Handoff $NonCanonicalBase64

$Utf8HashMismatch = Copy-JsonObject $BaseReviewerHandoff
$Utf8HashMismatch.raw_check_output[0].content = 'changed command output'
Invoke-NeutralEvidenceRejectionCase `
	-Name 'UTF-8 evidence hash mismatch is rejected' `
	-Handoff $Utf8HashMismatch

$Base64HashMismatch = Copy-JsonObject $Base64Reviewer
$Base64HashMismatch.raw_check_output[0].sha256 = ('0' * 64)
Invoke-NeutralEvidenceRejectionCase `
	-Name 'Base64 decoded-byte hash mismatch is rejected' `
	-Handoff $Base64HashMismatch

$SingularAsArray = Copy-JsonObject $BaseReviewerHandoff
$SingularAsArray.baseline_status = @($SingularAsArray.baseline_status)
Invoke-NeutralEvidenceRejectionCase `
	-Name 'Array value for singular evidence field is rejected' `
	-Handoff $SingularAsArray

$ArrayAsSingular = Copy-JsonObject $BaseReviewerHandoff
$ArrayAsSingular.raw_check_output = $ArrayAsSingular.raw_check_output[0]
Invoke-NeutralEvidenceRejectionCase `
	-Name 'Singular value for array evidence field is rejected' `
	-Handoff $ArrayAsSingular

function Get-TestSha256 {
	param(
		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[byte[]]$Bytes
	)

	$Hasher = [System.Security.Cryptography.SHA256]::Create()
	try {
		return [System.BitConverter]::ToString(
			$Hasher.ComputeHash($Bytes)
		).Replace('-', '').ToLowerInvariant()
	}
	finally {
		$Hasher.Dispose()
	}
}

function New-RequiredEvidenceDeclaration {
	param(
		[Parameter(Mandatory)][string]$Field,
		[Parameter(Mandatory)][object]$Record
	)
	return [ordered]@{
		field = $Field
		kind = $Record.kind
		provenance = $Record.provenance
		encoding = $Record.encoding
		source = $Record.source
		sha256 = $Record.sha256
	}
}

function New-FrozenAuthoritativeEvidenceManifest {
	param(
		[Parameter(Mandatory)][ValidateSet('verifier', 'approver')][string]$Stage,
		[Parameter(Mandatory)][object]$Handoff
	)

	[string[]]$FieldNames = if ($Stage -eq 'verifier') {
		@('candidate_artifact', 'raw_check_output')
	}
	else {
		@('baseline_status', 'baseline_diff', 'final_artifact', 'raw_check_output')
	}
	$Records = [System.Collections.Generic.List[object]]::new()
	foreach ($FieldName in $FieldNames) {
		$FieldValue = $Handoff[$FieldName]
		$FieldRecords = if ($FieldValue -is [System.Array]) {
			@($FieldValue)
		}
		else {
			@($FieldValue)
		}
		foreach ($Record in $FieldRecords) {
			$null = $Records.Add([ordered]@{
				field = $FieldName
				kind = $Record.kind
				provenance = $Record.provenance
				encoding = $Record.encoding
				source = $Record.source
				sha256 = $Record.sha256
			})
		}
	}

	$Manifest = [ordered]@{
		format = 'delivery_authoritative_evidence_manifest_v1'
		stage = $Stage
		records = [object[]]@($Records)
	}
	$Json = $Manifest | ConvertTo-Json -Depth 8 -Compress
	$Bytes = $Utf8NoBom.GetBytes($Json)
	return [pscustomobject]@{
		Manifest = $Manifest
		Records = [object[]]@($Records)
		Json = $Json
		Bytes = [byte[]]$Bytes
		Sha256 = Get-TestSha256 -Bytes $Bytes
	}
}

function New-TestJsonBytes {
	param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)

	$Bytes = $Utf8NoBom.GetBytes($Json)
	return [pscustomobject]@{
		Json = $Json
		Bytes = [byte[]]$Bytes
		Sha256 = Get-TestSha256 -Bytes $Bytes
	}
}

function Add-DuplicateJsonMemberAtFirstMatch {
	param(
		[Parameter(Mandatory)][string]$Json,
		[Parameter(Mandatory)][string]$Fragment,
		[Parameter(Mandatory)][string]$Replacement,
		[int]$StartIndex = 0
	)

	$Index = $Json.IndexOf(
		$Fragment,
		$StartIndex,
		[System.StringComparison]::Ordinal
	)
	if ($Index -lt 0) {
		throw "Test JSON fragment was not found."
	}
	return $Json.Substring(0, $Index) + $Replacement +
		$Json.Substring($Index + $Fragment.Length)
}

function Invoke-RequiredEvidenceAcceptanceCase {
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][object]$Handoff,
		[Parameter(Mandatory)][byte[]]$ManifestBytes,
		[Parameter(Mandatory)][string]$ExpectedManifestSha256,
		[Parameter(Mandatory)][int]$ExpectedManifestRecordCount,
		[Parameter(Mandatory)][ValidateSet('verifier', 'approver')][string]$ExpectedStage
	)

	$Path = Write-Fixture `
		-Name "$($Name.Replace(' ', '-')).json" `
		-Json ($Handoff | ConvertTo-Json -Depth 20 -Compress) `
		-Encoding $Utf8NoBom
	try {
		$Result = & $ValidatorPath `
			-HandoffPath $Path `
			-SchemaPath $SchemaPath `
			-AuthoritativeEvidenceManifestBytes $ManifestBytes `
			-ExpectedAuthoritativeEvidenceManifestSha256 $ExpectedManifestSha256
		Add-Result -Name $Name -Passed (
			$Result.Stage -ceq $ExpectedStage -and
			$Result.AuthoritativeEvidenceManifestValidated -eq $true -and
			$Result.AuthoritativeEvidenceManifestHash -ceq $ExpectedManifestSha256 -and
			$Result.AuthoritativeEvidenceManifestRecordCount -eq
				$ExpectedManifestRecordCount
		)
	}
	catch {
		Add-Result -Name $Name -Passed $false -Detail $_.Exception.Message
	}
}

function Invoke-RequiredEvidenceRejectionCase {
	param(
		[Parameter(Mandatory)][string]$Name,
		[AllowNull()][object]$Handoff,
		[AllowNull()][AllowEmptyString()][string]$Json,
		[AllowNull()][AllowEmptyCollection()][byte[]]$ManifestBytes,
		[AllowNull()][AllowEmptyString()][string]$ExpectedManifestSha256,
		[bool]$SupplyManifestBytes = $true,
		[bool]$SupplyExpectedHash = $true,
		[Parameter(Mandatory)][string]$ExpectedCode,
		[Parameter(Mandatory)][string]$ExpectedField,
		[string]$PrivateMarker = 'private-required-evidence-marker'
	)

	$FixtureJson = if ($PSBoundParameters.ContainsKey('Json')) {
		$Json
	}
	elseif ($PSBoundParameters.ContainsKey('Handoff')) {
		$Handoff | ConvertTo-Json -Depth 20 -Compress
	}
	else {
		throw 'A handoff object or raw JSON fixture is required.'
	}
	$Path = Write-Fixture `
		-Name "$($Name.Replace(' ', '-')).json" `
		-Json $FixtureJson `
		-Encoding $Utf8NoBom
	$ValidatorParameters = @{
		HandoffPath = $Path
		SchemaPath = $SchemaPath
	}
	if ($SupplyManifestBytes) {
		$ValidatorParameters['AuthoritativeEvidenceManifestBytes'] = $ManifestBytes
	}
	if ($SupplyExpectedHash) {
		$ValidatorParameters['ExpectedAuthoritativeEvidenceManifestSha256'] =
			$ExpectedManifestSha256
	}

	$Message = ''
	try {
		& $ValidatorPath @ValidatorParameters | Out-Null
	}
	catch {
		$Message = $_.Exception.Message
	}
	$Tokens = [string[]]@(
		$Message -csplit '[^a-z0-9_]+' |
			Where-Object { -not [string]::IsNullOrEmpty($_) }
	)
	Add-Result -Name $Name -Passed (
		-not [string]::IsNullOrWhiteSpace($Message) -and
		$Tokens -ccontains $ExpectedCode -and
		$Tokens -ccontains $ExpectedField -and
		$Message.IndexOf(
			$PrivateMarker,
			[System.StringComparison]::Ordinal
		) -lt 0
	) -Detail $Message
}

function New-DeclaredEvidenceHandoff {
	param([Parameter(Mandatory)][ValidateSet('verifier', 'approver')][string]$Stage)

	$LinuxLog = New-EvidenceRecord -Kind 'command_log' -Provenance 'launcher' `
		-Source 'linux-server-build-log' -Text 'Linux server build passed.'
	$DiffCheck = New-EvidenceRecord -Kind 'command_log' -Provenance 'launcher' `
		-Source 'git-diff-check-log' -Text 'git diff --check passed.'
	$Handoff = [ordered]@{
		schema_version = 1
		stage = $Stage
		run_id = "$Stage-required-evidence-test"
		workspace_root = $RepositoryRoot
		source_commit = '0000000000000000000000000000000000000000'
		ticket = 'Issue #130'
		acceptance_criteria = @('Validate required evidence declarations.')
		canonical_sources = @('AGENTS.md')
		output_contract = 'Return independent evidence.'
		allowed_paths = @('docs/example.md')
		non_goals = @('Production changes')
	}

	if ($Stage -eq 'verifier') {
		$Candidate = New-EvidenceRecord -Kind 'artifact' -Provenance 'launcher' `
			-Source 'candidate-artifact' -Text 'candidate bytes'
		$Handoff.Remove('allowed_paths')
		$Handoff.Remove('non_goals')
		$Handoff['candidate_artifact'] = $Candidate
		$Handoff['test_environment'] = 'read-only validator test'
		$Handoff['commands'] = @('Invoke focused checks.')
		$Handoff['raw_check_output'] = @($LinuxLog, $DiffCheck)
		$Handoff['required_evidence_sources'] = @(
			(New-RequiredEvidenceDeclaration -Field 'candidate_artifact' -Record $Candidate),
			(New-RequiredEvidenceDeclaration -Field 'raw_check_output' -Record $LinuxLog),
			(New-RequiredEvidenceDeclaration -Field 'raw_check_output' -Record $DiffCheck)
		)
	}
	else {
		$BaselineStatus = New-EvidenceRecord -Kind 'status' -Provenance 'launcher' `
			-Source 'baseline-status' -Text 'clean'
		$BaselineDiff = New-EvidenceRecord -Kind 'diff' -Provenance 'launcher' `
			-Source 'baseline-diff' -Text ''
		$FinalArtifact = New-EvidenceRecord -Kind 'artifact' -Provenance 'launcher' `
			-Source 'final-artifact' -Text 'final candidate bytes'
		$Handoff['baseline_status'] = $BaselineStatus
		$Handoff['baseline_diff'] = $BaselineDiff
		$Handoff['final_artifact'] = $FinalArtifact
		$Handoff['raw_check_output'] = @($LinuxLog, $DiffCheck)
		$Handoff['required_evidence_sources'] = @(
			(New-RequiredEvidenceDeclaration -Field 'baseline_status' -Record $BaselineStatus),
			(New-RequiredEvidenceDeclaration -Field 'baseline_diff' -Record $BaselineDiff),
			(New-RequiredEvidenceDeclaration -Field 'final_artifact' -Record $FinalArtifact),
			(New-RequiredEvidenceDeclaration -Field 'raw_check_output' -Record $LinuxLog),
			(New-RequiredEvidenceDeclaration -Field 'raw_check_output' -Record $DiffCheck)
		)
	}

	return $Handoff
}

$VerifierDeclaredEvidence = New-DeclaredEvidenceHandoff -Stage 'verifier'
$ApproverDeclaredEvidence = New-DeclaredEvidenceHandoff -Stage 'approver'
$DeclaredEvidenceStages = @(
	[pscustomobject]@{
		Name = 'Verifier'
		Stage = 'verifier'
		SingularField = 'candidate_artifact'
		Base = $VerifierDeclaredEvidence
		FrozenManifest = New-FrozenAuthoritativeEvidenceManifest `
			-Stage 'verifier' -Handoff $VerifierDeclaredEvidence
	},
	[pscustomobject]@{
		Name = 'Approver'
		Stage = 'approver'
		SingularField = 'final_artifact'
		Base = $ApproverDeclaredEvidence
		FrozenManifest = New-FrozenAuthoritativeEvidenceManifest `
			-Stage 'approver' -Handoff $ApproverDeclaredEvidence
	}
)

$ManifestInputCase = $DeclaredEvidenceStages[0]
$FrozenVerifierManifest = $ManifestInputCase.FrozenManifest
Invoke-RequiredEvidenceRejectionCase `
	-Name 'Missing authoritative manifest inputs are rejected' `
	-Handoff $ManifestInputCase.Base `
	-SupplyManifestBytes $false `
	-SupplyExpectedHash $false `
	-ExpectedCode 'authoritative_evidence_manifest_required' `
	-ExpectedField 'authoritative_evidence_manifest'
Invoke-RequiredEvidenceRejectionCase `
	-Name 'Manifest bytes without expected hash are rejected' `
	-Handoff $ManifestInputCase.Base `
	-ManifestBytes $FrozenVerifierManifest.Bytes `
	-SupplyExpectedHash $false `
	-ExpectedCode 'authoritative_evidence_manifest_required' `
	-ExpectedField 'authoritative_evidence_manifest'
Invoke-RequiredEvidenceRejectionCase `
	-Name 'Expected hash without manifest bytes is rejected' `
	-Handoff $ManifestInputCase.Base `
	-ExpectedManifestSha256 $FrozenVerifierManifest.Sha256 `
	-SupplyManifestBytes $false `
	-ExpectedCode 'authoritative_evidence_manifest_required' `
	-ExpectedField 'authoritative_evidence_manifest'
Invoke-RequiredEvidenceRejectionCase `
	-Name 'Empty authoritative manifest bytes are rejected' `
	-Handoff $ManifestInputCase.Base `
	-ManifestBytes ([byte[]]@()) `
	-ExpectedManifestSha256 $FrozenVerifierManifest.Sha256 `
	-ExpectedCode 'authoritative_evidence_manifest_required' `
	-ExpectedField 'authoritative_evidence_manifest'
Invoke-RequiredEvidenceRejectionCase `
	-Name 'Empty authoritative manifest expected hash is rejected' `
	-Handoff $ManifestInputCase.Base `
	-ManifestBytes $FrozenVerifierManifest.Bytes `
	-ExpectedManifestSha256 '' `
	-ExpectedCode 'authoritative_evidence_manifest_required' `
	-ExpectedField 'authoritative_evidence_manifest'
Invoke-RequiredEvidenceRejectionCase `
	-Name 'Invalid authoritative manifest expected hash syntax is rejected' `
	-Handoff $ManifestInputCase.Base `
	-ManifestBytes $FrozenVerifierManifest.Bytes `
	-ExpectedManifestSha256 'private-invalid-expected-hash' `
	-ExpectedCode 'authoritative_evidence_manifest_malformed' `
	-ExpectedField 'authoritative_evidence_manifest' `
	-PrivateMarker 'private-invalid-expected-hash'
Invoke-RequiredEvidenceRejectionCase `
	-Name 'Exact authoritative manifest hash mismatch is rejected' `
	-Handoff $ManifestInputCase.Base `
	-ManifestBytes $FrozenVerifierManifest.Bytes `
	-ExpectedManifestSha256 ('0' * 64) `
	-ExpectedCode 'authoritative_evidence_manifest_hash_mismatch' `
	-ExpectedField 'authoritative_evidence_manifest'

$MalformedManifest = New-TestJsonBytes -Json '{'
Invoke-RequiredEvidenceRejectionCase `
	-Name 'Malformed authoritative manifest JSON is rejected' `
	-Handoff $ManifestInputCase.Base `
	-ManifestBytes $MalformedManifest.Bytes `
	-ExpectedManifestSha256 $MalformedManifest.Sha256 `
	-ExpectedCode 'authoritative_evidence_manifest_malformed' `
	-ExpectedField 'authoritative_evidence_manifest'

$DuplicateManifestRootJson = $FrozenVerifierManifest.Json.Substring(
	0,
	$FrozenVerifierManifest.Json.Length - 1
) + ',"stage":"private-duplicate-manifest-stage"}'
$DuplicateManifestRoot = New-TestJsonBytes -Json $DuplicateManifestRootJson
Invoke-RequiredEvidenceRejectionCase `
	-Name 'Duplicate authoritative manifest root member is rejected' `
	-Handoff $ManifestInputCase.Base `
	-ManifestBytes $DuplicateManifestRoot.Bytes `
	-ExpectedManifestSha256 $DuplicateManifestRoot.Sha256 `
	-ExpectedCode 'required_evidence_json_member_duplicate' `
	-ExpectedField 'authoritative_evidence_manifest' `
	-PrivateMarker 'private-duplicate-manifest-stage'

$ManifestSourceFragment = '"source":"' +
	[string]$FrozenVerifierManifest.Records[0].source + '"'
$DuplicateManifestRecordJson = Add-DuplicateJsonMemberAtFirstMatch `
	-Json $FrozenVerifierManifest.Json `
	-Fragment $ManifestSourceFragment `
	-Replacement ($ManifestSourceFragment +
		',"source":"private-duplicate-manifest-source"')
$DuplicateManifestRecord = New-TestJsonBytes -Json $DuplicateManifestRecordJson
Invoke-RequiredEvidenceRejectionCase `
	-Name 'Duplicate authoritative manifest record member is rejected' `
	-Handoff $ManifestInputCase.Base `
	-ManifestBytes $DuplicateManifestRecord.Bytes `
	-ExpectedManifestSha256 $DuplicateManifestRecord.Sha256 `
	-ExpectedCode 'required_evidence_json_member_duplicate' `
	-ExpectedField 'authoritative_evidence_manifest' `
	-PrivateMarker 'private-duplicate-manifest-source'

$WrongStageManifestObject = Copy-JsonObject $FrozenVerifierManifest.Manifest
$WrongStageManifestObject.stage = 'approver'
$WrongStageManifest = New-TestJsonBytes -Json (
	$WrongStageManifestObject | ConvertTo-Json -Depth 8 -Compress
)
Invoke-RequiredEvidenceRejectionCase `
	-Name 'Wrong-stage authoritative manifest is rejected' `
	-Handoff $ManifestInputCase.Base `
	-ManifestBytes $WrongStageManifest.Bytes `
	-ExpectedManifestSha256 $WrongStageManifest.Sha256 `
	-ExpectedCode 'authoritative_evidence_manifest_malformed' `
	-ExpectedField 'authoritative_evidence_manifest'

$EmptyRecordsManifestObject = Copy-JsonObject $FrozenVerifierManifest.Manifest
$EmptyRecordsManifestObject.records = @()
$EmptyRecordsManifest = New-TestJsonBytes -Json (
	$EmptyRecordsManifestObject | ConvertTo-Json -Depth 8 -Compress
)
Invoke-RequiredEvidenceRejectionCase `
	-Name 'Empty authoritative manifest record array is rejected' `
	-Handoff $ManifestInputCase.Base `
	-ManifestBytes $EmptyRecordsManifest.Bytes `
	-ExpectedManifestSha256 $EmptyRecordsManifest.Sha256 `
	-ExpectedCode 'authoritative_evidence_manifest_malformed' `
	-ExpectedField 'authoritative_evidence_manifest'

$EmptyRecordManifestObject = Copy-JsonObject $FrozenVerifierManifest.Manifest
$EmptyRecordManifestObject.records = @([pscustomobject]@{})
$EmptyRecordManifest = New-TestJsonBytes -Json (
	$EmptyRecordManifestObject | ConvertTo-Json -Depth 8 -Compress
)
Invoke-RequiredEvidenceRejectionCase `
	-Name 'Empty authoritative manifest record is rejected' `
	-Handoff $ManifestInputCase.Base `
	-ManifestBytes $EmptyRecordManifest.Bytes `
	-ExpectedManifestSha256 $EmptyRecordManifest.Sha256 `
	-ExpectedCode 'authoritative_evidence_manifest_malformed' `
	-ExpectedField 'authoritative_evidence_manifest'

$DuplicateIdentityManifestObject = Copy-JsonObject $FrozenVerifierManifest.Manifest
$DuplicateIdentityManifestObject.records = @(
	$DuplicateIdentityManifestObject.records
) + @((Copy-JsonObject $DuplicateIdentityManifestObject.records[0]))
$DuplicateIdentityManifest = New-TestJsonBytes -Json (
	$DuplicateIdentityManifestObject | ConvertTo-Json -Depth 8 -Compress
)
Invoke-RequiredEvidenceRejectionCase `
	-Name 'Duplicate authoritative manifest identity is rejected' `
	-Handoff $ManifestInputCase.Base `
	-ManifestBytes $DuplicateIdentityManifest.Bytes `
	-ExpectedManifestSha256 $DuplicateIdentityManifest.Sha256 `
	-ExpectedCode 'authoritative_evidence_source_duplicate' `
	-ExpectedField 'candidate_artifact'

foreach ($StageCase in $DeclaredEvidenceStages) {
	$FrozenManifest = $StageCase.FrozenManifest
	Invoke-RequiredEvidenceAcceptanceCase `
		-Name "$($StageCase.Name) valid exact-once launcher provenance evidence is accepted" `
		-Handoff $StageCase.Base `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedManifestRecordCount $FrozenManifest.Records.Count `
		-ExpectedStage $StageCase.Stage

	$MissingSingular = Copy-JsonObject $StageCase.Base
	$MissingSingular.PSObject.Properties.Remove($StageCase.SingularField)
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) omitted singular evidence is rejected" `
		-Handoff $MissingSingular `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'required_evidence_routed_record_malformed' `
		-ExpectedField $StageCase.SingularField

	$NullSingular = Copy-JsonObject $StageCase.Base
	$NullSingular.($StageCase.SingularField) = $null
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) null singular evidence is rejected" `
		-Handoff $NullSingular `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'required_evidence_routed_record_malformed' `
		-ExpectedField $StageCase.SingularField

	$EmptySingular = Copy-JsonObject $StageCase.Base
	$EmptySingular.($StageCase.SingularField) = [pscustomobject]@{}
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) empty singular evidence record is rejected" `
		-Handoff $EmptySingular `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'neutral_evidence_keys_invalid' `
		-ExpectedField $StageCase.SingularField

	$MissingArray = Copy-JsonObject $StageCase.Base
	$MissingArray.PSObject.Properties.Remove('raw_check_output')
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) omitted evidence array is rejected" `
		-Handoff $MissingArray `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'required_evidence_routed_record_malformed' `
		-ExpectedField 'raw_check_output'

	$EmptyArray = Copy-JsonObject $StageCase.Base
	$EmptyArray.raw_check_output = @()
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) empty evidence array is rejected" `
		-Handoff $EmptyArray `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'required_evidence_routed_record_malformed' `
		-ExpectedField 'raw_check_output'

	$MissingDeclarations = Copy-JsonObject $StageCase.Base
	$MissingDeclarations.PSObject.Properties.Remove('required_evidence_sources')
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) missing evidence declarations are rejected" `
		-Handoff $MissingDeclarations `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'required_evidence_declarations_malformed' `
		-ExpectedField 'required_evidence_sources'

	$EmptyDeclarations = Copy-JsonObject $StageCase.Base
	$EmptyDeclarations.required_evidence_sources = @()
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) empty evidence declarations are rejected" `
		-Handoff $EmptyDeclarations `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'required_evidence_declarations_malformed' `
		-ExpectedField 'required_evidence_sources'

	$NullDeclarations = Copy-JsonObject $StageCase.Base
	$NullDeclarations.required_evidence_sources = $null
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) null evidence declarations are rejected" `
		-Handoff $NullDeclarations `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'required_evidence_declarations_malformed' `
		-ExpectedField 'required_evidence_sources'

	$MalformedDeclaration = Copy-JsonObject $StageCase.Base
	$MalformedDeclaration.required_evidence_sources[0] | Add-Member `
		-NotePropertyName extra -NotePropertyValue 'private-declaration-extra'
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) malformed evidence declaration is rejected" `
		-Handoff $MalformedDeclaration `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'required_evidence_declarations_malformed' `
		-ExpectedField 'required_evidence_sources' `
		-PrivateMarker 'private-declaration-extra'

	$IncompleteDeclaration = Copy-JsonObject $StageCase.Base
	$IncompleteDeclaration.required_evidence_sources[0].PSObject.Properties.Remove('sha256')
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) incomplete evidence declaration is rejected" `
		-Handoff $IncompleteDeclaration `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'required_evidence_declarations_malformed' `
		-ExpectedField 'required_evidence_sources'

	$DuplicateDeclaration = Copy-JsonObject $StageCase.Base
	$DuplicateDeclaration.required_evidence_sources = @(
		$DuplicateDeclaration.required_evidence_sources
	) + @((Copy-JsonObject $DuplicateDeclaration.required_evidence_sources[0]))
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) duplicate evidence declaration is rejected" `
		-Handoff $DuplicateDeclaration `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'required_evidence_declaration_duplicate' `
		-ExpectedField 'required_evidence_sources'

	$DuplicateRecord = Copy-JsonObject $StageCase.Base
	$LinuxRecord = @($DuplicateRecord.raw_check_output | Where-Object {
		$_.source -ceq 'linux-server-build-log'
	})[0]
	$DuplicateRecord.raw_check_output = @($DuplicateRecord.raw_check_output) +
		@((Copy-JsonObject $LinuxRecord))
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) duplicate evidence record is rejected" `
		-Handoff $DuplicateRecord `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'required_evidence_routed_record_duplicate' `
		-ExpectedField 'raw_check_output'

	foreach ($Mismatch in @(
		[pscustomobject]@{
			Name = 'kind'
			Property = 'kind'
			Value = 'text'
			Code = 'required_evidence_declarations_malformed'
			Field = 'required_evidence_sources'
		},
		[pscustomobject]@{
			Name = 'provenance'
			Property = 'provenance'
			Value = 'repository'
			Code = 'required_evidence_declarations_malformed'
			Field = 'required_evidence_sources'
		},
		[pscustomobject]@{
			Name = 'encoding'
			Property = 'encoding'
			Value = 'base64'
			Code = 'required_evidence_composition_mismatch'
			Field = 'raw_check_output'
		},
		[pscustomobject]@{
			Name = 'hash'
			Property = 'sha256'
			Value = ('0' * 64)
			Code = 'required_evidence_composition_mismatch'
			Field = 'raw_check_output'
		},
		[pscustomobject]@{
			Name = 'source'
			Property = 'source'
			Value = 'private-declaration-source-substitution'
			Code = 'required_evidence_composition_mismatch'
			Field = 'raw_check_output'
		}
	)) {
		$MismatchedDeclaration = Copy-JsonObject $StageCase.Base
		$LinuxDeclaration = @($MismatchedDeclaration.required_evidence_sources |
			Where-Object { $_.source -ceq 'linux-server-build-log' })[0]
		$LinuxDeclaration.($Mismatch.Property) = $Mismatch.Value
		Invoke-RequiredEvidenceRejectionCase `
			-Name "$($StageCase.Name) declaration $($Mismatch.Name) mismatch is rejected" `
			-Handoff $MismatchedDeclaration `
			-ManifestBytes $FrozenManifest.Bytes `
			-ExpectedManifestSha256 $FrozenManifest.Sha256 `
			-ExpectedCode $Mismatch.Code `
			-ExpectedField $Mismatch.Field `
			-PrivateMarker ([string]$Mismatch.Value)
	}

	$RoutedEncodingMismatch = Copy-JsonObject $StageCase.Base
	$RoutedEncodingLinux = @($RoutedEncodingMismatch.raw_check_output |
		Where-Object { $_.source -ceq 'linux-server-build-log' })[0]
	$RoutedEncodingLinux.encoding = 'base64'
	$RoutedEncodingLinux.content = [System.Convert]::ToBase64String(
		[System.Text.Encoding]::UTF8.GetBytes([string]$RoutedEncodingLinux.content)
	)
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) routed encoding substitution is rejected" `
		-Handoff $RoutedEncodingMismatch `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'required_evidence_composition_mismatch' `
		-ExpectedField 'raw_check_output'

	$RoutedProvenanceMismatch = Copy-JsonObject $StageCase.Base
	$RoutedProvenanceLinux = @($RoutedProvenanceMismatch.raw_check_output |
		Where-Object { $_.source -ceq 'linux-server-build-log' })[0]
	$RoutedProvenanceLinux.provenance = 'repository'
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) routed repository provenance is rejected" `
		-Handoff $RoutedProvenanceMismatch `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'neutral_evidence_provenance_invalid' `
		-ExpectedField 'raw_check_output'

	$ConsistentSubstitution = Copy-JsonObject $StageCase.Base
	$SubstitutedRoutedRecord = @($ConsistentSubstitution.raw_check_output |
		Where-Object { $_.source -ceq 'linux-server-build-log' })[0]
	$SubstitutedDeclaration = @($ConsistentSubstitution.required_evidence_sources |
		Where-Object { $_.source -ceq 'linux-server-build-log' })[0]
	$SubstitutedRoutedRecord.source = 'private-consistent-linux-substitution'
	$SubstitutedDeclaration.source = 'private-consistent-linux-substitution'
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) mutually consistent handoff substitution is rejected" `
		-Handoff $ConsistentSubstitution `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'required_evidence_composition_mismatch' `
		-ExpectedField 'raw_check_output' `
		-PrivateMarker 'private-consistent-linux-substitution'

	$RepositoryLinuxHandoff = Copy-JsonObject $StageCase.Base
	$RepositoryLinuxRecord = @($RepositoryLinuxHandoff.raw_check_output |
		Where-Object { $_.source -ceq 'linux-server-build-log' })[0]
	$RepositoryLinuxDeclaration = @(
		$RepositoryLinuxHandoff.required_evidence_sources |
			Where-Object { $_.source -ceq 'linux-server-build-log' }
	)[0]
	$RepositoryLinuxRecord.provenance = 'repository'
	$RepositoryLinuxDeclaration.provenance = 'repository'
	$RepositoryLinuxManifestObject = Copy-JsonObject $FrozenManifest.Manifest
	$RepositoryLinuxManifestRecord = @($RepositoryLinuxManifestObject.records |
		Where-Object {
			$_.field -ceq 'raw_check_output' -and
			$_.source -ceq 'linux-server-build-log'
		})[0]
	$RepositoryLinuxManifestRecord.provenance = 'repository'
	$RepositoryLinuxManifest = New-TestJsonBytes -Json (
		$RepositoryLinuxManifestObject | ConvertTo-Json -Depth 8 -Compress
	)
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) repository-provenance Linux manifest record is rejected" `
		-Handoff $RepositoryLinuxHandoff `
		-ManifestBytes $RepositoryLinuxManifest.Bytes `
		-ExpectedManifestSha256 $RepositoryLinuxManifest.Sha256 `
		-ExpectedCode 'authoritative_evidence_manifest_malformed' `
		-ExpectedField 'authoritative_evidence_manifest'

	$UndeclaredEvidence = Copy-JsonObject $StageCase.Base
	$UndeclaredEvidence.raw_check_output = @($UndeclaredEvidence.raw_check_output) + @(
		(New-EvidenceRecord -Kind 'command_log' -Provenance 'launcher' `
			-Source 'undeclared-check-log' -Text 'undeclared output')
	)
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) undeclared evidence is rejected" `
		-Handoff $UndeclaredEvidence `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'required_evidence_composition_mismatch' `
		-ExpectedField 'raw_check_output'

	$MissingLinuxLog = Copy-JsonObject $StageCase.Base
	$MissingLinuxLog.raw_check_output = @($MissingLinuxLog.raw_check_output |
		Where-Object { $_.source -cne 'linux-server-build-log' })
	$MissingLinuxLog.required_evidence_sources = @(
		$MissingLinuxLog.required_evidence_sources |
			Where-Object { $_.source -cne 'linux-server-build-log' }
	)
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) authoritative Linux build log omission is rejected" `
		-Handoff $MissingLinuxLog `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'required_evidence_composition_mismatch' `
		-ExpectedField 'raw_check_output'

	$BaseJson = $StageCase.Base | ConvertTo-Json -Depth 20 -Compress
	$DuplicateRequiredSourcesJson = $BaseJson.Substring(0, $BaseJson.Length - 1) +
		',"required_evidence_sources":[]}'
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) duplicate required_evidence_sources member is rejected" `
		-Json $DuplicateRequiredSourcesJson `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'required_evidence_json_member_duplicate' `
		-ExpectedField 'required_evidence_sources'

	$DuplicateRawOutputJson = $BaseJson.Substring(0, $BaseJson.Length - 1) +
		',"raw_check_output":[]}'
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) duplicate raw_check_output member is rejected" `
		-Json $DuplicateRawOutputJson `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'required_evidence_json_member_duplicate' `
		-ExpectedField 'raw_check_output'

	$DeclarationStart = $BaseJson.IndexOf(
		'"required_evidence_sources":',
		[System.StringComparison]::Ordinal
	)
	$DeclarationFieldFragment = '"field":"' + $StageCase.SingularField + '"'
	$DuplicateDeclarationMemberJson = Add-DuplicateJsonMemberAtFirstMatch `
		-Json $BaseJson `
		-Fragment $DeclarationFieldFragment `
		-Replacement ($DeclarationFieldFragment +
			',"field":"private-duplicate-declaration-field"') `
		-StartIndex $DeclarationStart
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) duplicate declaration JSON member is rejected" `
		-Json $DuplicateDeclarationMemberJson `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'required_evidence_json_member_duplicate' `
		-ExpectedField 'required_evidence_sources' `
		-PrivateMarker 'private-duplicate-declaration-field'

	$RoutedSourceFragment = '"source":"linux-server-build-log"'
	$DuplicateRoutedMemberJson = Add-DuplicateJsonMemberAtFirstMatch `
		-Json $BaseJson `
		-Fragment $RoutedSourceFragment `
		-Replacement ($RoutedSourceFragment +
			',"source":"private-duplicate-routed-source"')
	Invoke-RequiredEvidenceRejectionCase `
		-Name "$($StageCase.Name) duplicate routed-record JSON member is rejected" `
		-Json $DuplicateRoutedMemberJson `
		-ManifestBytes $FrozenManifest.Bytes `
		-ExpectedManifestSha256 $FrozenManifest.Sha256 `
		-ExpectedCode 'required_evidence_json_member_duplicate' `
		-ExpectedField 'raw_check_output' `
		-PrivateMarker 'private-duplicate-routed-source'
}

$Results | Format-Table -AutoSize
$Failed = @($Results | Where-Object { -not $_.Passed })
if ($Failed.Count -gt 0) {
	throw "$($Failed.Count) handoff validation test(s) failed. Test artifacts: $TestRoot"
}
Write-Host "All handoff validation tests passed. Test artifacts: $TestRoot"
