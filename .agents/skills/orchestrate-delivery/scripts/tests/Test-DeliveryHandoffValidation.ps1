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

$Results | Format-Table -AutoSize
$Failed = @($Results | Where-Object { -not $_.Passed })
if ($Failed.Count -gt 0) {
	throw "$($Failed.Count) handoff validation test(s) failed. Test artifacts: $TestRoot"
}
Write-Host "All handoff validation tests passed. Test artifacts: $TestRoot"
