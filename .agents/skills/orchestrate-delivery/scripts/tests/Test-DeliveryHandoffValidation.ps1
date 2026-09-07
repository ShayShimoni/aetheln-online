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

$SupportedSourceInspectionProtocol = [ordered]@{
	schema_version = 1
	tool = 'read_allowed_source_file'
	request_arguments = @('path', 'offset_bytes')
	path_source = 'allowed_paths'
	initial_offset_bytes = 0
	next_offset_field = 'end_offset_bytes'
	completion_field = 'eof'
	maximum_page_bytes = 8192
}

$ProtocolWorker = $BaseWorkerHandoff.Clone()
$ProtocolWorker.execution_route = 'planned'
$ProtocolWorker.work_package = 'Explicit protocol package.'
$ProtocolWorker.source_inspection_protocol = $SupportedSourceInspectionProtocol
Invoke-AcceptanceCase `
	-Name 'Exact source-inspection protocol is accepted' `
	-Handoff $ProtocolWorker

$ProtocolIntegrator = [ordered]@{
	schema_version = 1
	stage = 'integrator'
	run_id = 'integrator-source-protocol-conflict'
	workspace_root = $RepositoryRoot
	source_commit = '0000000000000000000000000000000000000000'
	ticket = 'Issue #70'
	acceptance_criteria = @('Validate the integrator source protocol.')
	canonical_sources = @('AGENTS.md')
	output_contract = 'Return a delivery_file_bundle_v1 full-file artifact.'
	candidate_artifacts = @(
		New-EvidenceRecord -Kind artifact -Provenance launcher `
			-Source 'candidate-a' -Text 'candidate a'
	)
	integration_order = @(
		'Use read_allowed_source_file with path, offset_bytes, and limit_bytes: 2048.'
	)
	conflict_locations = New-EvidenceRecord -Kind text -Provenance control_plane `
		-Source 'conflicts' -Text 'none'
	allowed_paths = @('docs/example.md')
	non_goals = @('Production changes')
	required_checks = @('Parse the test.')
	baseline_status = New-EvidenceRecord -Kind status -Provenance launcher `
		-Source 'baseline-status' -Text 'clean'
	baseline_diff = New-EvidenceRecord -Kind diff -Provenance launcher `
		-Source 'baseline-diff' -Text ''
	source_inspection_protocol = $SupportedSourceInspectionProtocol
}
Invoke-RejectionCase `
	-Name 'Integrator integration order rejects unsupported source member' `
	-Json ($ProtocolIntegrator | ConvertTo-Json -Depth 12 -Compress) `
	-ExpectedPattern 'source_protocol_invalid' `
	-PrivateMarker 'private-integrator-source-member'

$InvalidProtocolCases = @(
	@('schema-version', 'schema_version', 2),
	@('tool', 'tool', 'source_reader'),
	@('request-arguments', 'request_arguments', @('offset_bytes', 'path')),
	@('path-source', 'path_source', 'canonical_sources'),
	@('initial-offset', 'initial_offset_bytes', 1),
	@('next-offset', 'next_offset_field', 'offset_bytes'),
	@('completion', 'completion_field', 'complete'),
	@('maximum-page', 'maximum_page_bytes', 2048)
)
foreach ($InvalidProtocolCase in $InvalidProtocolCases) {
	$InvalidProtocolWorker = Copy-JsonObject -Value $ProtocolWorker
	$InvalidProtocolWorker.run_id = "invalid-protocol-$($InvalidProtocolCase[0])"
	$InvalidProtocolWorker.source_inspection_protocol.($InvalidProtocolCase[1]) =
		$InvalidProtocolCase[2]
	Invoke-RejectionCase `
		-Name "Source protocol $($InvalidProtocolCase[0]) mismatch is rejected" `
		-Json ($InvalidProtocolWorker | ConvertTo-Json -Depth 12 -Compress) `
		-ExpectedPattern 'source_protocol_invalid' `
		-PrivateMarker 'private-invalid-protocol'
}

$ExtraProtocolMemberWorker = Copy-JsonObject -Value $ProtocolWorker
$ExtraProtocolMemberWorker.source_inspection_protocol | Add-Member `
	-NotePropertyName timeout_seconds -NotePropertyValue 30
Invoke-RejectionCase `
	-Name 'Extra source protocol member uses sanitized protocol rejection' `
	-Json ($ExtraProtocolMemberWorker | ConvertTo-Json -Depth 12 -Compress) `
	-ExpectedPattern 'source_protocol_invalid' `
	-PrivateMarker 'private-extra-protocol-value'

$RetainedReplacementWorker = Copy-JsonObject -Value $ProtocolWorker
$RetainedReplacementWorker.run_id = 'retained-replacement-conflict'
$RetainedReplacementWorker.work_package =
	'Use read_allowed_source_file. Require `limit_bytes: 2048` for each source read. private-retained-value'
Invoke-RejectionCase `
	-Name 'Exact retained replacement limit_bytes requirement is rejected' `
	-Json ($RetainedReplacementWorker | ConvertTo-Json -Depth 12 -Compress) `
	-ExpectedPattern 'source_protocol_invalid' `
	-PrivateMarker 'private-retained-value'

$AdjacentClauseSourceWorker = Copy-JsonObject -Value $ProtocolWorker
$AdjacentClauseSourceWorker.run_id = 'adjacent-clause-source-member-conflict'
$AdjacentClauseSourceWorker.work_package =
	'Inspect with read_allowed_source_file. Pass limit_bytes: 4096 on every call.'
Invoke-RejectionCase `
	-Name 'Exact source-tool context continues into an adjacent operational clause' `
	-Json ($AdjacentClauseSourceWorker | ConvertTo-Json -Depth 12 -Compress) `
	-ExpectedPattern 'source_protocol_invalid' `
	-PrivateMarker 'private-adjacent-clause-marker'

$AdjacentSetClauseSourceWorker = Copy-JsonObject -Value $ProtocolWorker
$AdjacentSetClauseSourceWorker.run_id = 'adjacent-set-clause-source-member-conflict'
$AdjacentSetClauseSourceWorker.work_package =
	'Use read_allowed_source_file. Set limit_bytes to 2048 on every call.'
Invoke-RejectionCase `
	-Name 'Exact source-tool context scopes an adjacent set directive' `
	-Json ($AdjacentSetClauseSourceWorker | ConvertTo-Json -Depth 12 -Compress) `
	-ExpectedPattern 'source_protocol_invalid' `
	-PrivateMarker 'private-adjacent-set-clause-marker'

$AdjacentPlainMemberSourceWorker = Copy-JsonObject -Value $ProtocolWorker
$AdjacentPlainMemberSourceWorker.run_id =
	'adjacent-plain-member-source-conflict'
$AdjacentPlainMemberSourceWorker.work_package =
	'Use read_allowed_source_file. Set limit to 2048 on every call.'
Invoke-RejectionCase `
	-Name 'Exact source-tool context scopes an adjacent plain member directive' `
	-Json ($AdjacentPlainMemberSourceWorker | ConvertTo-Json -Depth 12 -Compress) `
	-ExpectedPattern 'source_protocol_invalid' `
	-PrivateMarker 'private-adjacent-plain-member-marker'

$AdjacentPlainMemberDirectiveVerbs = @('assign', 'add', 'include', 'pass', 'require')
foreach ($DirectiveVerb in $AdjacentPlainMemberDirectiveVerbs) {
	$PlainMemberDirectiveWorker = Copy-JsonObject -Value $ProtocolWorker
	$PlainMemberDirectiveWorker.run_id =
		"adjacent-plain-member-$DirectiveVerb-conflict"
	$PlainMemberDirectiveWorker.work_package =
		("Use read_allowed_source_file. $DirectiveVerb limit to every request. " +
		"private-adjacent-$DirectiveVerb-plain-member-marker")
	Invoke-RejectionCase `
		-Name "Exact source-tool context scopes adjacent $DirectiveVerb plain member directive" `
		-Json ($PlainMemberDirectiveWorker | ConvertTo-Json -Depth 12 -Compress) `
		-ExpectedPattern 'source_protocol_invalid' `
		-PrivateMarker "private-adjacent-$DirectiveVerb-plain-member-marker"
}

$ActiveReplaceSourceWorker = Copy-JsonObject -Value $ProtocolWorker
$ActiveReplaceSourceWorker.run_id = 'active-replace-source-conflict'
$ActiveReplaceSourceWorker.work_package =
	'Replace source after calling read_allowed_source_file(path, offset_bytes, limit_bytes).'
Invoke-RejectionCase `
	-Name 'Leading replace with an active unsupported source call is rejected' `
	-Json ($ActiveReplaceSourceWorker | ConvertTo-Json -Depth 12 -Compress) `
	-ExpectedPattern 'source_protocol_invalid' `
	-PrivateMarker 'private-active-replace-source-marker'

$UnrelatedLimitRecordWorker = Copy-JsonObject -Value $ProtocolWorker
$UnrelatedLimitRecordWorker.run_id = 'unrelated-limit-record-control'
$UnrelatedLimitRecordWorker.work_package =
	'Write a configuration record named limit_bytes: 2048; do not call any source tool.'
Invoke-AcceptanceCase `
	-Name 'Unrelated limit record without exact source context is accepted' `
	-Handoff $UnrelatedLimitRecordWorker

$AdjacentSetControlWorker = Copy-JsonObject -Value $ProtocolWorker
$AdjacentSetControlWorker.run_id = 'adjacent-set-clause-unrelated-control'
$AdjacentSetControlWorker.work_package =
	'Use read_allowed_source_file. Set response_limit_bytes to 2048 for the output response.'
Invoke-AcceptanceCase `
	-Name 'Adjacent source context does not scope an unrelated set directive' `
	-Handoff $AdjacentSetControlWorker

$AdjacentCanonicalMemberWorker = Copy-JsonObject -Value $ProtocolWorker
$AdjacentCanonicalMemberWorker.run_id = 'adjacent-canonical-member-control'
$AdjacentCanonicalMemberWorker.work_package =
	'Use read_allowed_source_file. Set offset_bytes to each returned end_offset_bytes on every call.'
Invoke-AcceptanceCase `
	-Name 'Adjacent canonical offset continuation remains accepted' `
	-Handoff $AdjacentCanonicalMemberWorker

$RetainedEvidenceInvocationWorker = Copy-JsonObject -Value $ProtocolWorker
$RetainedEvidenceInvocationWorker.run_id = 'retained-evidence-invocation-conflict'
$RetainedEvidenceInvocationWorker.work_package =
	'Reproduce the retained raw evidence by invoking read_allowed_source_file with limit_bytes: 2048.'
Invoke-RejectionCase `
	-Name 'Active source-tool invocation is not exempted as retained evidence prose' `
	-Json ($RetainedEvidenceInvocationWorker | ConvertTo-Json -Depth 12 -Compress) `
	-ExpectedPattern 'source_protocol_invalid' `
	-PrivateMarker 'private-retained-evidence-marker'

$ExactToolShapingCases = @(
	'Do not stop before invoking read_allowed_source_file with limit_bytes: 2048.',
	'No incomplete reads are allowed when calling read_allowed_source_file with timeout_seconds.',
	'Call read_allowed_source_file and cap each request at 2048 bytes.',
	'Use read_allowed_source_file. Cap each page at 2048 bytes.',
	'Use read_allowed_source_file, specifying timeout_seconds: 30 on every request.',
	'Use read_allowed_source_file and specify limit_bytes on each request.',
	'Remove ambiguity by invoking read_allowed_source_file with timeout_seconds: 30.',
	'Previous attempts failed, so invoke read_allowed_source_file with timeout_seconds: 30.'
)
for ($ShapingIndex = 0; $ShapingIndex -lt $ExactToolShapingCases.Count; $ShapingIndex++) {
	$ShapingWorker = Copy-JsonObject -Value $ProtocolWorker
	$ShapingWorker.run_id = "exact-source-shaping-$ShapingIndex"
	$ShapingWorker.work_package = $ExactToolShapingCases[$ShapingIndex]
	Invoke-RejectionCase `
		-Name "Exact source-tool shaping case $($ShapingIndex + 1) is rejected" `
		-Json ($ShapingWorker | ConvertTo-Json -Depth 12 -Compress) `
		-ExpectedPattern 'source_protocol_invalid' `
		-PrivateMarker 'private-exact-source-shaping'
}

$SplitSourceContextCases = @(
	[pscustomobject]@{
		Value = @(
			'Use read_allowed_source_file.',
			'Pass timeout_seconds on every source request.'
		)
	},
	[pscustomobject]@{
		Value = [ordered]@{
			procedure = 'Use read_allowed_source_file.'
			instructions = 'Pass timeout_seconds on every source request.'
		}
	}
)
for ($SplitContextIndex = 0;
	$SplitContextIndex -lt $SplitSourceContextCases.Count;
	$SplitContextIndex++) {
	$SplitContextWorker = Copy-JsonObject -Value $ProtocolWorker
	$SplitContextWorker.run_id = "split-source-context-$SplitContextIndex"
	$SplitContextWorker.work_package = $SplitSourceContextCases[$SplitContextIndex].Value
	Invoke-RejectionCase `
		-Name "Split source context case $($SplitContextIndex + 1) is rejected" `
		-Json ($SplitContextWorker | ConvertTo-Json -Depth 12 -Compress) `
		-ExpectedPattern 'source_protocol_invalid' `
		-PrivateMarker 'private-split-source-context'
}

$MemberBeforeToolVerbs = @('Supply', 'Attach', 'Append', 'Send', 'Provide', 'Assign')
foreach ($MemberBeforeToolVerb in $MemberBeforeToolVerbs) {
	$MemberBeforeToolWorker = Copy-JsonObject -Value $ProtocolWorker
	$MemberBeforeToolWorker.run_id =
		"member-before-source-tool-$($MemberBeforeToolVerb.ToLowerInvariant())"
	$MemberBeforeToolWorker.work_package =
		"$MemberBeforeToolVerb timeout_seconds to read_allowed_source_file."
	Invoke-RejectionCase `
		-Name "$MemberBeforeToolVerb member before exact source tool is rejected" `
		-Json ($MemberBeforeToolWorker | ConvertTo-Json -Depth 12 -Compress) `
		-ExpectedPattern 'source_protocol_invalid' `
		-PrivateMarker 'private-member-before-source-tool'
}

$CanonicalMemberBeforeToolWorker = Copy-JsonObject -Value $ProtocolWorker
$CanonicalMemberBeforeToolWorker.run_id = 'canonical-members-before-source-tool'
$CanonicalMemberBeforeToolWorker.work_package =
	'Supply path and offset_bytes to read_allowed_source_file.'
Invoke-AcceptanceCase `
	-Name 'Canonical members before exact source tool remain accepted' `
	-Handoff $CanonicalMemberBeforeToolWorker

$VerbIndependentMemberCases = @(
	'Use read_allowed_source_file. Each request must carry path, offset_bytes, and timeout_seconds.',
	'Use read_allowed_source_file. Each request has path, offset_bytes, and timeout_seconds.',
	'Use read_allowed_source_file. Each request is required to carry path, offset_bytes, and timeout_seconds.'
)
for ($VerbIndependentIndex = 0;
	$VerbIndependentIndex -lt $VerbIndependentMemberCases.Count;
	$VerbIndependentIndex++) {
	$VerbIndependentWorker = Copy-JsonObject -Value $ProtocolWorker
	$VerbIndependentWorker.run_id = "verb-independent-source-members-$VerbIndependentIndex"
	$VerbIndependentWorker.work_package = $VerbIndependentMemberCases[$VerbIndependentIndex]
	Invoke-RejectionCase `
		-Name "Verb-independent source member case $($VerbIndependentIndex + 1) is rejected" `
		-Json ($VerbIndependentWorker | ConvertTo-Json -Depth 12 -Compress) `
		-ExpectedPattern 'source_protocol_invalid' `
		-PrivateMarker 'private-verb-independent-source-member'
}

$ObjectSourceMemberCases = @(
	[ordered]@{
		procedure = 'Use read_allowed_source_file.'
		request_arguments = @('path', 'offset_bytes', 'timeout_seconds')
	},
	[ordered]@{
		procedure = 'Use read_allowed_source_file.'
		arguments = [ordered]@{
			path = 'docs/example.md'
			offset_bytes = 0
			timeout_seconds = 30
		}
	}
)
for ($ObjectMemberIndex = 0;
	$ObjectMemberIndex -lt $ObjectSourceMemberCases.Count;
	$ObjectMemberIndex++) {
	$ObjectMemberWorker = Copy-JsonObject -Value $ProtocolWorker
	$ObjectMemberWorker.run_id = "object-source-members-$ObjectMemberIndex"
	$ObjectMemberWorker.work_package = $ObjectSourceMemberCases[$ObjectMemberIndex]
	Invoke-RejectionCase `
		-Name "Object source member case $($ObjectMemberIndex + 1) is rejected" `
		-Json ($ObjectMemberWorker | ConvertTo-Json -Depth 12 -Compress) `
		-ExpectedPattern 'source_protocol_invalid' `
		-PrivateMarker 'private-object-source-member'
}

$ExplicitSourceMemberCases = @(
	'Every read_allowed_source_file call must include timeout_seconds. private-call-value',
	'Use read_allowed_source_file(path, offset_bytes, timeout_seconds). private-signature-value',
	'Use read_allowed_source_file(path, offset_bytes, limit). private-signature-limit',
	'Use read_allowed_source_file(path, offset_bytes, foo). private-signature-foo',
	'Use read_allowed_source_file(path, offset_bytes, x). private-signature-x',
	'Use read_allowed_source_file(path). private-signature-missing-offset',
	'Use read_allowed_source_file(offset_bytes). private-signature-missing-path',
	'Use read_allowed_source_file(path, path, offset_bytes). private-signature-duplicate-path',
	'Use read_allowed_source_file(path, offset_bytes, offset_bytes). private-signature-duplicate-offset',
	'Use read_allowed_source_file(offset_bytes, path). private-signature-reordered',
	'Use read_allowed_source_file(). private-signature-empty',
	'Use read_allowed_source_file(path,, offset_bytes). private-signature-malformed',
	'Use read_allowed_source_file with path and offset_bytes and limit. private-with-limit',
	'Use read_allowed_source_file using path, offset_bytes, foo. private-using-foo',
	'The read_allowed_source_file arguments are path, offset_bytes, and x. private-arguments-x',
	'The read_allowed_source_file members are path and offset_bytes and limit. private-members-limit',
	'The read_allowed_source_file fields are path, offset_bytes, foo. private-fields-foo'
)
$ExplicitSourcePrivateMarkers = @(
	'private-call-value',
	'private-signature-value',
	'private-signature-limit',
	'private-signature-foo',
	'private-signature-x',
	'private-signature-missing-offset',
	'private-signature-missing-path',
	'private-signature-duplicate-path',
	'private-signature-duplicate-offset',
	'private-signature-reordered',
	'private-signature-empty',
	'private-signature-malformed',
	'private-with-limit',
	'private-using-foo',
	'private-arguments-x',
	'private-members-limit',
	'private-fields-foo'
)
for ($ExplicitMemberIndex = 0; $ExplicitMemberIndex -lt $ExplicitSourceMemberCases.Count; $ExplicitMemberIndex++) {
	$ExplicitMemberWorker = Copy-JsonObject -Value $ProtocolWorker
	$ExplicitMemberWorker.run_id = "explicit-source-member-$ExplicitMemberIndex"
	$ExplicitMemberWorker.work_package = $ExplicitSourceMemberCases[$ExplicitMemberIndex]
	Invoke-RejectionCase `
		-Name "Exact source-tool request member case $($ExplicitMemberIndex + 1) is rejected" `
		-Json ($ExplicitMemberWorker | ConvertTo-Json -Depth 12 -Compress) `
		-ExpectedPattern 'source_protocol_invalid' `
		-PrivateMarker $ExplicitSourcePrivateMarkers[$ExplicitMemberIndex]
}

$CanonicalSourceEnumerationCases = @(
	'Use read_allowed_source_file(path, offset_bytes) for every source page.',
	'Use `read_allowed_source_file(path, offset_bytes)` for every source page.',
	'Use read_allowed_source_file with path and offset_bytes.',
	'Use read_allowed_source_file. Pass only path and offset_bytes in every source call.',
	'Use read_allowed_source_file. Use end_offset_bytes from each response as the next offset.',
	'Use read_allowed_source_file with exactly path and offset_bytes.',
	'Use read_allowed_source_file using path, offset_bytes.',
	'The read_allowed_source_file arguments are path and offset_bytes.',
	'The read_allowed_source_file members are path, offset_bytes.',
	'The read_allowed_source_file fields are path, and offset_bytes.',
	'Historical evidence records read_allowed_source_file(path, offset_bytes, limit).',
	'Remove read_allowed_source_file(path, offset_bytes, limit) from prior instructions.',
	'Replace read_allowed_source_file(path, offset_bytes, limit_bytes) with read_allowed_source_file(path, offset_bytes).'
)
for ($CanonicalEnumerationIndex = 0;
	$CanonicalEnumerationIndex -lt $CanonicalSourceEnumerationCases.Count;
	$CanonicalEnumerationIndex++) {
	$CanonicalEnumerationWorker = Copy-JsonObject -Value $ProtocolWorker
	$CanonicalEnumerationWorker.run_id =
		"canonical-source-enumeration-$CanonicalEnumerationIndex"
	$CanonicalEnumerationWorker.work_package =
		$CanonicalSourceEnumerationCases[$CanonicalEnumerationIndex]
	Invoke-AcceptanceCase `
		-Name "Canonical source enumeration case $($CanonicalEnumerationIndex + 1) is accepted" `
		-Handoff $CanonicalEnumerationWorker
}

$StructuredSourceCallWorker = Copy-JsonObject -Value $ProtocolWorker
$StructuredSourceCallWorker.run_id = 'structured-source-member-conflict'
$StructuredSourceCallWorker.work_package = [ordered]@{
	tool = 'read_allowed_source_file'
	arguments = [ordered]@{
		path = 'docs/example.md'
		offset_bytes = 0
		timeout_seconds = 30
	}
}
Invoke-RejectionCase `
	-Name 'Structured exact source-tool call rejects unsupported argument member' `
	-Json ($StructuredSourceCallWorker | ConvertTo-Json -Depth 12 -Compress) `
	-ExpectedPattern 'source_protocol_invalid' `
	-PrivateMarker 'private-structured-source-member'

$InvalidStructuredSourceCallCases = @(
	[ordered]@{
		tool = 'read_allowed_source_file'
		arguments = [ordered]@{ path = 'AGENTS.md'; offset_bytes = '0' }
	},
	[ordered]@{
		tool = 'read_allowed_source_file'
		arguments = [ordered]@{ path = 'AGENTS.md'; offset_bytes = -1 }
	},
	[ordered]@{
		tool = 'Read_Allowed_Source_File'
		arguments = [ordered]@{ path = 'AGENTS.md'; offset_bytes = 0; limit_bytes = 2048 }
	}
)
for ($StructuredCaseIndex = 0;
	$StructuredCaseIndex -lt $InvalidStructuredSourceCallCases.Count;
	$StructuredCaseIndex++) {
	$InvalidStructuredWorker = Copy-JsonObject -Value $ProtocolWorker
	$InvalidStructuredWorker.run_id = "invalid-structured-source-call-$StructuredCaseIndex"
	$InvalidStructuredWorker.work_package = $InvalidStructuredSourceCallCases[$StructuredCaseIndex]
	Invoke-RejectionCase `
		-Name "Invalid structured source call case $($StructuredCaseIndex + 1) is rejected" `
		-Json ($InvalidStructuredWorker | ConvertTo-Json -Depth 12 -Compress) `
		-ExpectedPattern 'source_protocol_invalid' `
		-PrivateMarker 'private-invalid-structured-source-call'
}

$StructuredSourceInstructionWorker = Copy-JsonObject -Value $ProtocolWorker
$StructuredSourceInstructionWorker.run_id = 'structured-source-instruction-conflict'
$StructuredSourceInstructionWorker.work_package = [ordered]@{
	source_call = [ordered]@{
		tool = 'read_allowed_source_file'
		arguments = [ordered]@{
			path = 'docs/example.md'
			offset_bytes = 0
		}
	}
	instructions = 'Every call must include timeout_seconds 30.'
}
Invoke-RejectionCase `
	-Name 'Structured exact source-tool call scopes an instruction sibling' `
	-Json ($StructuredSourceInstructionWorker | ConvertTo-Json -Depth 12 -Compress) `
	-ExpectedPattern 'source_protocol_invalid' `
	-PrivateMarker 'private-structured-instruction-marker'

$StructuredSourceCompanionWorker = Copy-JsonObject -Value $ProtocolWorker
$StructuredSourceCompanionWorker.run_id = 'structured-source-companion-control'
$StructuredSourceCompanionWorker.work_package = [ordered]@{
	source_call = [ordered]@{
		tool = 'read_allowed_source_file'
		arguments = [ordered]@{
			path = 'docs/example.md'
			offset_bytes = 0
		}
	}
	instructions = 'Continue with each returned end_offset_bytes until eof.'
	evidence = 'A prior API call included timeout_seconds 30.'
	artifact_hash = 'The unrelated digest includes response_hash_token.'
	output_path = 'docs/source_timeout_seconds.md'
	baseline = 'The old API call required baseline_timeout_seconds.'
}
Invoke-AcceptanceCase `
	-Name 'Structured source call does not scope inert companion values' `
	-Handoff $StructuredSourceCompanionWorker

$CrossFieldSourceWorker = Copy-JsonObject -Value $ProtocolWorker
$CrossFieldSourceWorker.run_id = 'cross-field-source-member-conflict'
$CrossFieldSourceWorker.work_package =
	'Use read_allowed_source_file with path and offset_bytes.'
$CrossFieldSourceWorker.required_checks = @(
	'Every call must include timeout_seconds 30. private-cross-field-value'
)
Invoke-RejectionCase `
	-Name 'Exact source-tool context rejects later explicit request member' `
	-Json ($CrossFieldSourceWorker | ConvertTo-Json -Depth 12 -Compress) `
	-ExpectedPattern 'source_protocol_invalid' `
	-PrivateMarker 'private-cross-field-value'

$NegativeSourceClauseCases = @(
	@('No calls with limit_bytes.', 'No-call negative clause'),
	@('Check that calls with limit_bytes are rejected.', 'Check rejection clause'),
	@('Do not pass limit_bytes; use path and offset_bytes.', 'Corrective source clause'),
	@('Verify calls containing limit_bytes are rejected.', 'Verification rejection clause')
)
for ($NegativeClauseIndex = 0;
	$NegativeClauseIndex -lt $NegativeSourceClauseCases.Count;
	$NegativeClauseIndex++) {
	$NegativeClauseWorker = Copy-JsonObject -Value $ProtocolWorker
	$NegativeClauseWorker.run_id = "negative-source-clause-$NegativeClauseIndex"
	$NegativeClauseWorker.work_package = 'Use read_allowed_source_file.'
	if ($NegativeClauseIndex -eq 0) {
		$NegativeClauseWorker.non_goals = @($NegativeSourceClauseCases[$NegativeClauseIndex][0])
	}
	else {
		$NegativeClauseWorker.required_checks = @($NegativeSourceClauseCases[$NegativeClauseIndex][0])
	}
	Invoke-AcceptanceCase `
		-Name "$($NegativeSourceClauseCases[$NegativeClauseIndex][1]) remains accepted" `
		-Handoff $NegativeClauseWorker
}

$NegativeClauseContinuationCases = @(
	'No calls with limit_bytes. Then set limit_bytes to 2048 on every call.',
	'Check that calls with limit_bytes are rejected. Require timeout_seconds on each call.',
	'Use read_allowed_source_file. Do not pass path.',
	'Use read_allowed_source_file. Do not pass offset_bytes.'
)
for ($ContinuationIndex = 0;
	$ContinuationIndex -lt $NegativeClauseContinuationCases.Count;
	$ContinuationIndex++) {
	$ContinuationWorker = Copy-JsonObject -Value $ProtocolWorker
	$ContinuationWorker.run_id = "negative-source-clause-continuation-$ContinuationIndex"
	$ContinuationWorker.work_package = 'Use read_allowed_source_file.'
	$ContinuationWorker.required_checks = @(
		$NegativeClauseContinuationCases[$ContinuationIndex]
	)
	Invoke-RejectionCase `
		-Name "Negative source clause continuation $($ContinuationIndex + 1) rejects a later directive" `
		-Json ($ContinuationWorker | ConvertTo-Json -Depth 12 -Compress) `
		-ExpectedPattern 'source_protocol_invalid' `
		-PrivateMarker 'private-negative-clause-continuation'
}

$LiveIssueBody = @'
## Problem

Issue #139's fresh planned worker consumed its initial attempt after source inspection stopped with multi-page files still at `eof:false`. The one permitted replacement was instructed to use `limit_bytes: 2048`, but the closed `read_allowed_source_file` schema accepts only `path` and `offset_bytes`. The replacement launched, made no MCP tool call, returned no artifact, and consumed the replacement budget.

The retained artifacts do not establish response-artifact capacity overflow or a cause for the missing replacement tool call. They do establish a control-plane contract defect: replacement instructions can require unsupported source-reader arguments, while the launcher does not reject that mismatch before child launch.

## Objective

Make restricted producer replacement handoffs mechanically consistent with the closed source-reader schema and preserve actionable evidence for incomplete pagination without weakening isolation or retry bounds.

## Acceptance criteria

- [ ] Reproduce the real restricted-launcher replacement path from retained raw events without consuming an unbounded producer retry.
- [ ] Ensure producer and replacement instructions use only arguments supported by the closed runtime `read_allowed_source_file` input schema, or reject unsupported requirements before child launch with retry-neutral evidence.
- [ ] Distinguish no-tool-call, tool argument-validation, and incomplete-pagination outcomes in retained launcher evidence without trusting producer narrative as the cause.
- [ ] Prove a restricted producer can read one large allowed file through exact sequential `end_offset_bytes` calls until `eof: true`, with stable metadata, no gaps, overlaps, reordering, duplication, or transcript truncation.
- [ ] Preserve read-only sandboxing, exact path/source attestation, sensitive/reparse/drift rejection, text/structured parity, complete full-file bundles, exact base hashes, snapshot equality, strict patch validation, and the initial-plus-one-replacement budget.
- [ ] Add focused source-reader and launcher/handoff regression coverage and align the operating contract and producer instructions with the supported paging protocol.
- [ ] Complete fresh verification, review and approval before publication; after merge, independently QA the installed-Codex replacement path before unblocking #139.

## Evidence

- Initial handoff and artifacts: `C:\Users\shais\AppData\Local\Temp\aetheln-issue139-wave-20260902\worker-initial-handoff.json` and `worker-initial-artifacts`
- Replacement handoff and artifacts: `C:\Users\shais\AppData\Local\Temp\aetheln-issue139-wave-20260902\worker-replacement-handoff.json` and `worker-replacement-artifacts`
- Source commit: `085932aa31856041a9c5544ba4f838a2f5e66e24`
- The replacement handoff requires `limit_bytes: 2048`; `Invoke-DeliverySourceInspectionServer.ps1` declares only `path` and `offset_bytes` with `additionalProperties: false`.

## Relationship

Immediate prerequisite for #139. After this bug is independently merged and QA-passed, #139 must restart as a new planned wave from the new `develop` source; the exhausted attempts are not reusable.

## Non-goals

- No third #139 producer attempt before this prerequisite is delivered.
- No partial files, hand-authored patches, weakened snapshot/hash/scope gates, or bypass of the restricted launcher.
- No numeric response-capacity claim without measured evidence.
- No gameplay, Unreal, CI runner, packaging, deployment, migration, #44 behavior, or unrelated #143/#145/#146 scope.
'@
$LiveIssueAcceptanceCriteria = @(
	'Reproduce the real restricted-launcher replacement path from retained raw events without consuming an unbounded producer retry.',
	'Ensure producer and replacement instructions use only arguments supported by the closed runtime `read_allowed_source_file` input schema, or reject unsupported requirements before child launch with retry-neutral evidence.',
	'Distinguish no-tool-call, tool argument-validation, and incomplete-pagination outcomes in retained launcher evidence without trusting producer narrative as the cause.',
	'Prove a restricted producer can read one large allowed file through exact sequential `end_offset_bytes` calls until `eof: true`, with stable metadata, no gaps, overlaps, reordering, duplication, or transcript truncation.',
	'Preserve read-only sandboxing, exact path/source attestation, sensitive/reparse/drift rejection, text/structured parity, complete full-file bundles, exact base hashes, snapshot equality, strict patch validation, and the initial-plus-one-replacement budget.',
	'Add focused source-reader and launcher/handoff regression coverage and align the operating contract and producer instructions with the supported paging protocol.',
	'Complete fresh verification, review and approval before publication; after merge, independently QA the installed-Codex replacement path before unblocking #139.'
)
$LiveIssueWorker = Copy-JsonObject -Value $ProtocolWorker
$LiveIssueWorker.run_id = 'live-issue-151-context'
$LiveIssueWorker.ticket = $LiveIssueBody
$LiveIssueWorker.acceptance_criteria = $LiveIssueAcceptanceCriteria
$LiveIssueWorker.work_package = 'Apply the bounded typed-protocol validation change.'
$LiveIssueWorker.required_checks = @(
	'Retry an unrelated API request with timeout_seconds 30.'
)
Invoke-AcceptanceCase `
	-Name 'Exact live Issue 151 body and seven acceptance criteria remain valid' `
	-Handoff $LiveIssueWorker

$DescriptiveContextCases = @(
	'Retry the deployment API request with timeout_seconds 30.',
	'Keep the output response_limit_bytes at 2048.',
	'Return the delivery_file_bundle_v1 full-file contract with base_sha256.',
	'Edit docs/source_reader_timeout_seconds.md.',
	'Document `timeout_seconds` in the Markdown issue history.',
	'Historical evidence records that read_allowed_source_file once accepted limit_bytes: 2048.',
	'Remove limit_bytes from read_allowed_source_file requests.',
	'Document read_allowed_source_file behavior. Retry an unrelated API request with timeout_seconds 30.',
	'Use the source reader with a timeout of thirty seconds.',
	'Keep source inspection results bounded and compact.',
	'Set limit to 2048 on every call.'
)
for ($ContextIndex = 0; $ContextIndex -lt $DescriptiveContextCases.Count; $ContextIndex++) {
	$ContextWorker = Copy-JsonObject -Value $ProtocolWorker
	$ContextWorker.run_id = "descriptive-context-$ContextIndex"
	$ContextWorker.work_package = $DescriptiveContextCases[$ContextIndex]
	Invoke-AcceptanceCase `
		-Name "Descriptive non-protocol context case $($ContextIndex + 1) remains accepted" `
		-Handoff $ContextWorker
}

$TicketIsolationWorker = Copy-JsonObject -Value $ProtocolWorker
$TicketIsolationWorker.run_id = 'ticket-criteria-source-context-isolation'
$TicketIsolationWorker.ticket =
	'Every read_allowed_source_file call must include timeout_seconds.'
$TicketIsolationWorker.acceptance_criteria = @(
	'Use read_allowed_source_file with path and offset_bytes.',
	'Every call must include timeout_seconds 30.'
)
$TicketIsolationWorker.work_package =
	'Retry an unrelated API request with timeout_seconds 30.'
Invoke-AcceptanceCase `
	-Name 'Ticket and acceptance criteria do not establish operational source context' `
	-Handoff $TicketIsolationWorker
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
