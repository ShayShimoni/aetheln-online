[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $PSScriptRoot
$ClassifierPath = Join-Path $ScriptRoot 'Get-DeliveryExecutionRoute.ps1'

if (-not (Test-Path -LiteralPath $ClassifierPath -PathType Leaf)) {
	throw "Expected missing classifier: '$ClassifierPath'. Apply Package 2."
}

$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
	'aetheln-delivery-routing-tests-' + [guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $TestRoot | Out-Null

$Results = [System.Collections.Generic.List[object]]::new()
$InputKeys = @(
	'schema_version', 'current_route', 'change_category', 'expected_file_count',
	'localized_scope', 'clear_criteria', 'resolved_dependencies',
	'defined_change', 'reproducible_bug_evidence', 'known_verification',
	'known_rollback', 'assessment_source', 'calculation_heavy',
	'ambiguous_requirements', 'cross_component', 'behavior_sensitive',
	'security_or_permissions', 'data_persistence_or_migration',
	'networking_or_concurrency', 'public_contract_or_schema',
	'architecture_build_or_release', 'canonical_meaning_change'
)
$HazardKeys = @(
	'calculation_heavy', 'ambiguous_requirements', 'cross_component',
	'behavior_sensitive', 'security_or_permissions',
	'data_persistence_or_migration', 'networking_or_concurrency',
	'public_contract_or_schema', 'architecture_build_or_release',
	'canonical_meaning_change'
)
$PositiveKeys = @(
	'localized_scope', 'clear_criteria', 'resolved_dependencies',
	'defined_change', 'known_verification', 'known_rollback'
)
$OutputKeys = @(
	'schema_version', 'route', 'reason_codes', 'normalized_evidence',
	'previous_route', 'promotion_state', 'direct_skipped_stages',
	'required_downstream_stages', 'conditional_fresh_stages'
)
$ReasonByPositiveKey = [ordered]@{
	localized_scope = 'localized_scope_not_confirmed'
	clear_criteria = 'clear_criteria_not_confirmed'
	resolved_dependencies = 'resolved_dependencies_not_confirmed'
	defined_change = 'defined_change_not_confirmed'
	known_verification = 'known_verification_not_confirmed'
	known_rollback = 'known_rollback_not_confirmed'
}
$ReasonByHazardKey = [ordered]@{
	calculation_heavy = 'calculation_heavy_present_or_unknown'
	ambiguous_requirements = 'ambiguous_requirements_present_or_unknown'
	cross_component = 'cross_component_present_or_unknown'
	behavior_sensitive = 'behavior_sensitive_present_or_unknown'
	security_or_permissions = 'security_or_permissions_present_or_unknown'
	data_persistence_or_migration = 'data_persistence_or_migration_present_or_unknown'
	networking_or_concurrency = 'networking_or_concurrency_present_or_unknown'
	public_contract_or_schema = 'public_contract_or_schema_present_or_unknown'
	architecture_build_or_release = 'architecture_build_or_release_present_or_unknown'
	canonical_meaning_change = 'canonical_meaning_change_present_or_unknown'
}

function Add-Result {
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][bool]$Passed,
		[string]$Detail = ''
	)

	$Results.Add([pscustomobject]@{
		Name = $Name
		Passed = $Passed
		Detail = $Detail
	})
}

function Test-Sequence {
	param(
		[AllowNull()][object[]]$Actual,
		[AllowNull()][object[]]$Expected
	)

	$ActualItems = @($Actual)
	$ExpectedItems = @($Expected)

	if ($ActualItems.Count -ne $ExpectedItems.Count) {
		return $false
	}

	for ($Index = 0; $Index -lt $ActualItems.Count; $Index++) {
		if (([string]$ActualItems[$Index]) -cne
			([string]$ExpectedItems[$Index])) {
			return $false
		}
	}

	return $true
}

function New-Assessment {
	param(
		[string]$Category = 'text_edit',
		[string]$CurrentRoute = 'direct'
	)

	return [ordered]@{
		schema_version = 1
		current_route = $CurrentRoute
		change_category = $Category
		expected_file_count = 1
		localized_scope = $true
		clear_criteria = $true
		resolved_dependencies = $true
		defined_change = $true
		reproducible_bug_evidence = $true
		known_verification = $true
		known_rollback = $true
		assessment_source = 'ticket evidence'
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
	}
}

function Copy-Assessment {
	param([Parameter(Mandatory)][System.Collections.IDictionary]$Assessment)

	$Copy = [ordered]@{}
	foreach ($Key in $Assessment.Keys) {
		$Copy[$Key] = $Assessment[$Key]
	}
	return $Copy
}

function Write-Assessment {
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Assessment
	)

	$Path = Join-Path $TestRoot "$Name.json"
	$Assessment | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
	return $Path
}

function Invoke-Classifier {
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Assessment
	)

	$Path = Write-Assessment -Name $Name -Assessment $Assessment
	return & $ClassifierPath -AssessmentPath $Path
}

function Invoke-RawFailure {
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][string]$Json
	)

	$Path = Join-Path $TestRoot "$Name.json"
	$Json | Set-Content -LiteralPath $Path -Encoding UTF8
	$Output = @()
	$Message = ''
	try {
		$Output = @(& $ClassifierPath -AssessmentPath $Path)
	}
	catch {
		$Message = $_.Exception.Message
	}
	return [pscustomobject]@{
		Failed = -not [string]::IsNullOrWhiteSpace($Message)
		OutputCount = $Output.Count
		Message = $Message
	}
}

function Invoke-InvalidAssessment {
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][System.Collections.IDictionary]$Assessment
	)

	return Invoke-RawFailure `
		-Name $Name `
		-Json ($Assessment | ConvertTo-Json -Depth 4)
}

foreach ($Category in @(
	'text_edit', 'small_line_change', 'localized_reproducible_bug_fix'
)) {
	$Result = Invoke-Classifier `
		-Name "direct-$Category" `
		-Assessment (New-Assessment -Category $Category)
	Add-Result -Name "$Category is directly eligible" -Passed (
		$Result.route -ceq 'direct' -and
		(Test-Sequence $Result.reason_codes @('direct_eligible')) -and
		$Result.promotion_state -ceq 'retained_direct'
	)
}

foreach ($Category in @('text_edit', 'small_line_change')) {
	foreach ($Evidence in @($false, $null)) {
		$Assessment = New-Assessment -Category $Category
		$Assessment.reproducible_bug_evidence = $Evidence
		$Result = Invoke-Classifier `
			-Name "non-bug-evidence-$Category-$($null -eq $Evidence)" `
			-Assessment $Assessment
		Add-Result `
			-Name "$Category ignores inapplicable bug evidence value" `
			-Passed ($Result.route -ceq 'direct')
	}
}

foreach ($Evidence in @($false, $null)) {
	$Assessment = New-Assessment -Category 'localized_reproducible_bug_fix'
	$Assessment.reproducible_bug_evidence = $Evidence
	$Result = Invoke-Classifier `
		-Name "bug-evidence-not-confirmed-$($null -eq $Evidence)" `
		-Assessment $Assessment
	Add-Result -Name 'Bug fix requires explicit reproducible evidence' -Passed (
		$Result.route -ceq 'planned' -and
		(Test-Sequence $Result.reason_codes @(
			'reproducible_bug_evidence_not_confirmed'
		))
	)
}

foreach ($Key in $PositiveKeys) {
	foreach ($ValueCase in @(
		@('false', $false),
		@('null', $null)
	)) {
		$Assessment = New-Assessment
		$Assessment[$Key] = $ValueCase[1]
		$Result = Invoke-Classifier `
			-Name "positive-$Key-$($ValueCase[0])" `
			-Assessment $Assessment
		Add-Result -Name "$Key rejects $($ValueCase[0]) evidence" -Passed (
			$Result.route -ceq 'planned' -and
			(Test-Sequence $Result.reason_codes @($ReasonByPositiveKey[$Key]))
		)
	}
}

foreach ($Key in $HazardKeys) {
	foreach ($ValueCase in @(
		@('true', $true),
		@('null', $null)
	)) {
		$Assessment = New-Assessment
		$Assessment[$Key] = $ValueCase[1]
		$Result = Invoke-Classifier `
			-Name "hazard-$Key-$($ValueCase[0])" `
			-Assessment $Assessment
		Add-Result -Name "$Key rejects $($ValueCase[0]) evidence" -Passed (
			$Result.route -ceq 'planned' -and
			(Test-Sequence $Result.reason_codes @($ReasonByHazardKey[$Key]))
		)
	}
}

foreach ($Count in @(0, 2)) {
	$Assessment = New-Assessment
	$Assessment.expected_file_count = $Count
	$Result = Invoke-Classifier -Name "file-count-$Count" -Assessment $Assessment
	Add-Result -Name "File count $Count promotes to planned" -Passed (
		$Result.route -ceq 'planned' -and
		$Result.normalized_evidence.multi_file -and
		(Test-Sequence $Result.reason_codes @('expected_file_count_not_one'))
	)
}

$OtherResult = Invoke-Classifier `
	-Name 'unsupported-category' `
	-Assessment (New-Assessment -Category 'other')
Add-Result -Name 'Other category promotes to planned' -Passed (
	$OtherResult.route -ceq 'planned' -and
	(Test-Sequence $OtherResult.reason_codes @('unsupported_change_category'))
)

$PlannedResult = Invoke-Classifier `
	-Name 'planned-absorbing' `
	-Assessment (New-Assessment -CurrentRoute 'planned')
Add-Result -Name 'Planned route is absorbing' -Passed (
	$PlannedResult.route -ceq 'planned' -and
	$PlannedResult.previous_route -ceq 'planned' -and
	$PlannedResult.promotion_state -ceq 'retained_planned' -and
	(Test-Sequence $PlannedResult.reason_codes @('current_route_planned'))
)

$PromotedAssessment = New-Assessment
$PromotedAssessment.localized_scope = $false
$PromotedResult = Invoke-Classifier `
	-Name 'direct-promoted' `
	-Assessment $PromotedAssessment
Add-Result -Name 'Ineligible direct route promotes to planned' -Passed (
	$PromotedResult.previous_route -ceq 'direct' -and
	$PromotedResult.route -ceq 'planned' -and
	$PromotedResult.promotion_state -ceq 'promoted_to_planned'
)

$OrderedAssessment = New-Assessment -Category 'other' -CurrentRoute 'planned'
$OrderedAssessment.expected_file_count = 2
foreach ($Key in $PositiveKeys) { $OrderedAssessment[$Key] = $false }
foreach ($Key in $HazardKeys) { $OrderedAssessment[$Key] = $null }
$OrderedResult = Invoke-Classifier `
	-Name 'ordered-reasons' `
	-Assessment $OrderedAssessment
$ExpectedReasons = @(
	'current_route_planned',
	'unsupported_change_category',
	'expected_file_count_not_one',
	'localized_scope_not_confirmed',
	'clear_criteria_not_confirmed',
	'resolved_dependencies_not_confirmed',
	'defined_change_not_confirmed',
	'known_verification_not_confirmed',
	'known_rollback_not_confirmed',
	'calculation_heavy_present_or_unknown',
	'ambiguous_requirements_present_or_unknown',
	'cross_component_present_or_unknown',
	'behavior_sensitive_present_or_unknown',
	'security_or_permissions_present_or_unknown',
	'data_persistence_or_migration_present_or_unknown',
	'networking_or_concurrency_present_or_unknown',
	'public_contract_or_schema_present_or_unknown',
	'architecture_build_or_release_present_or_unknown',
	'canonical_meaning_change_present_or_unknown'
)
Add-Result -Name 'Reason codes have deterministic contract order' -Passed (
	Test-Sequence $OrderedResult.reason_codes $ExpectedReasons
)

$DirectResult = Invoke-Classifier `
	-Name 'exact-output' `
	-Assessment (New-Assessment)
Add-Result -Name 'Success output has exact ordered fields' -Passed (
	(Test-Sequence $DirectResult.PSObject.Properties.Name $OutputKeys) -and
	$DirectResult.schema_version -eq 1
)
Add-Result -Name 'Normalized evidence has exact ordered fields' -Passed (
	Test-Sequence `
		$DirectResult.normalized_evidence.PSObject.Properties.Name `
		@($InputKeys + 'multi_file')
)
Add-Result -Name 'Normalized evidence preserves values and derives multi-file' -Passed (
	$DirectResult.normalized_evidence.assessment_source -ceq 'ticket evidence' -and
	$DirectResult.normalized_evidence.expected_file_count -eq 1 -and
	-not $DirectResult.normalized_evidence.multi_file
)
Add-Result -Name 'Direct skips only analyst and synthesizer' -Passed (
	Test-Sequence $DirectResult.direct_skipped_stages @('analyst', 'synthesizer')
)
Add-Result -Name 'Direct keeps mandatory downstream gates' -Passed (
	(Test-Sequence $DirectResult.required_downstream_stages @(
		'worker', 'verifier', 'reviewer', 'approver'
	)) -and
	(Test-Sequence $DirectResult.conditional_fresh_stages @(
		'integrator', 'fixer', 'adjudicator', 'qa'
	))
)
Add-Result -Name 'Planned route keeps the complete ordered stage path' -Passed (
	(Test-Sequence $PlannedResult.direct_skipped_stages @()) -and
	(Test-Sequence $PlannedResult.required_downstream_stages @(
		'analyst', 'synthesizer', 'worker', 'verifier', 'reviewer', 'approver'
	)) -and
	(Test-Sequence $PlannedResult.conditional_fresh_stages @(
		'integrator', 'fixer', 'adjudicator', 'qa'
	))
)

$InvalidCases = [System.Collections.Generic.List[object]]::new()
foreach ($Key in $InputKeys) {
	$Assessment = New-Assessment
	$Assessment.Remove($Key)
	$InvalidCases.Add(@("missing-$Key", $Assessment))
}

$ExtraAssessment = New-Assessment
$ExtraAssessment.unexpected = $true
$InvalidCases.Add(@('extra-key', $ExtraAssessment))

foreach ($Key in @($PositiveKeys + 'reproducible_bug_evidence' + $HazardKeys)) {
	$Assessment = New-Assessment
	$Assessment[$Key] = 'true'
	$InvalidCases.Add(@("malformed-$Key", $Assessment))
}

$InvalidValues = @(
	@('schema-string', 'schema_version', '1'),
	@('unsupported-version', 'schema_version', 2),
	@('route-case', 'current_route', 'Direct'),
	@('route-enum', 'current_route', 'unknown'),
	@('category-case', 'change_category', 'Text_Edit'),
	@('category-enum', 'change_category', 'unknown'),
	@('negative-count', 'expected_file_count', -1),
	@('fractional-count', 'expected_file_count', 1.5),
	@('string-count', 'expected_file_count', '1'),
	@('null-source', 'assessment_source', $null),
	@('blank-source', 'assessment_source', ' '),
	@('numeric-source', 'assessment_source', 1)
)
foreach ($Case in $InvalidValues) {
	$Assessment = New-Assessment
	$Assessment[$Case[1]] = $Case[2]
	$InvalidCases.Add(@($Case[0], $Assessment))
}

foreach ($Case in $InvalidCases) {
	$Failure = Invoke-InvalidAssessment -Name $Case[0] -Assessment $Case[1]
	Add-Result -Name "Invalid input rejects $($Case[0])" -Passed (
		$Failure.Failed -and $Failure.OutputCount -eq 0
	)
}

$RawInvalidCases = @(
	@('malformed-json', '{"schema_version":1'),
	@('array-root', '[]'),
	@('scalar-root', '1'),
	@('null-root', 'null'),
	@('duplicate-key', '{"schema_version":1,"schema_version":1}')
)
foreach ($Case in $RawInvalidCases) {
	$Failure = Invoke-RawFailure -Name $Case[0] -Json $Case[1]
	Add-Result -Name "Invalid JSON rejects $($Case[0])" -Passed (
		$Failure.Failed -and $Failure.OutputCount -eq 0
	)
}

$NoArgumentFailed = $false
try { & $ClassifierPath | Out-Null } catch { $NoArgumentFailed = $true }
Add-Result -Name 'AssessmentPath is mandatory' -Passed $NoArgumentFailed

$DirectoryFailed = $false
try { & $ClassifierPath -AssessmentPath $TestRoot | Out-Null } catch {
	$DirectoryFailed = $true
}
Add-Result -Name 'AssessmentPath must identify one file' -Passed $DirectoryFailed

$LeakMarker = 'do-not-expose-routing-payload'
$LeakAssessment = New-Assessment
$LeakAssessment.assessment_source = $LeakMarker
$LeakAssessment.localized_scope = $LeakMarker
$LeakFailure = Invoke-InvalidAssessment `
	-Name 'payload-privacy' `
	-Assessment $LeakAssessment
Add-Result -Name 'Malformed-input errors do not expose payload values' -Passed (
	$LeakFailure.Failed -and
	$LeakFailure.OutputCount -eq 0 -and
	$LeakFailure.Message -notmatch [regex]::Escape($LeakMarker)
)

$FallbackRoute = if ($LeakFailure.Failed) { 'planned' } else { 'direct' }
Add-Result -Name 'Classifier failure requires planned control-plane fallback' -Passed (
	$FallbackRoute -ceq 'planned'
)

$ClassifierSource = Get-Content -Raw -LiteralPath $ClassifierPath
$ForbiddenThresholdTerms = @(
	'maximum_file_count', 'file_count_threshold', 'direct_file_limit',
	'multi_file_threshold', 'threshold_file_count'
)
$ThresholdMatches = @($ForbiddenThresholdTerms | Where-Object {
	$ClassifierSource -match [regex]::Escape($_)
})
Add-Result -Name 'Classifier defines no unauthorized threshold fields' -Passed (
	$ThresholdMatches.Count -eq 0
) -Detail ([string]::Join(', ', $ThresholdMatches))
Add-Result -Name 'Classifier uses only schema version one' -Passed (
	$ClassifierSource -notmatch 'schema_version[^\r\n]+(?:2|3|4|5)'
)

$Results | Format-Table -AutoSize
$Failed = @($Results | Where-Object { -not $_.Passed })
if ($Failed.Count -gt 0) {
	throw "$($Failed.Count) adaptive-routing test(s) failed. Test artifacts: $TestRoot"
}

Write-Host "All adaptive-routing tests passed. Test artifacts: $TestRoot"
