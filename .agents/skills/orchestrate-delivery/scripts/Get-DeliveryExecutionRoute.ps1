[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[string]$AssessmentPath
)

$ErrorActionPreference = 'Stop'

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
$NullableBooleanKeys = @(
	'localized_scope', 'clear_criteria', 'resolved_dependencies',
	'defined_change', 'reproducible_bug_evidence', 'known_verification',
	'known_rollback', 'calculation_heavy', 'ambiguous_requirements',
	'cross_component', 'behavior_sensitive', 'security_or_permissions',
	'data_persistence_or_migration', 'networking_or_concurrency',
	'public_contract_or_schema', 'architecture_build_or_release',
	'canonical_meaning_change'
)
$PositiveReasons = [ordered]@{
	localized_scope = 'localized_scope_not_confirmed'
	clear_criteria = 'clear_criteria_not_confirmed'
	resolved_dependencies = 'resolved_dependencies_not_confirmed'
	defined_change = 'defined_change_not_confirmed'
	known_verification = 'known_verification_not_confirmed'
	known_rollback = 'known_rollback_not_confirmed'
}
$HazardReasons = [ordered]@{
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

Add-Type -AssemblyName System.Runtime.Serialization

function New-ValidationError {
	return [System.Management.Automation.ErrorRecord]::new(
		[System.ArgumentException]::new('Assessment JSON is invalid.'),
		'InvalidDeliveryRouteAssessment',
		[System.Management.Automation.ErrorCategory]::InvalidData,
		$null
	)
}

function Assert-JsonString {
	param(
		[Parameter(Mandatory)]
		[System.Xml.XmlElement]$Value
	)

	if ($Value.GetAttribute('type') -cne 'string') {
		throw (New-ValidationError)
	}
	return $Value.InnerText
}

function Convert-NullableBoolean {
	param(
		[Parameter(Mandatory)]
		[System.Xml.XmlElement]$Value
	)

	switch ($Value.GetAttribute('type')) {
		'boolean' {
			if ($Value.InnerText -ceq 'true') { return $true }
			if ($Value.InnerText -ceq 'false') { return $false }
			throw (New-ValidationError)
		}
		'null' { return $null }
		default { throw (New-ValidationError) }
	}
}

$Stream = $null
$Reader = $null
try {
	$ResolvedPath = Resolve-Path -LiteralPath $AssessmentPath
	$PathItem = Get-Item -LiteralPath $ResolvedPath.Path
	if ($PathItem.PSIsContainer) {
		throw (New-ValidationError)
	}

	try {
		$JsonBytes = [System.IO.File]::ReadAllBytes($ResolvedPath.Path)
		$JsonOffset = 0
		if ($JsonBytes.Length -ge 3 -and
			$JsonBytes[0] -eq 0xEF -and $JsonBytes[1] -eq 0xBB -and
			$JsonBytes[2] -eq 0xBF) {
			$JsonOffset = 3
		}
		$Stream = [System.IO.MemoryStream]::new(
			$JsonBytes, $JsonOffset, $JsonBytes.Length - $JsonOffset, $false
		)
		$Reader = [System.Runtime.Serialization.Json.JsonReaderWriterFactory]::CreateJsonReader(
			$Stream,
			[System.Xml.XmlDictionaryReaderQuotas]::Max
		)
		$Document = [System.Xml.XmlDocument]::new()
		$Document.PreserveWhitespace = $false
		$Document.Load($Reader)
	}
	catch {
		throw (New-ValidationError)
	}

	$Root = $Document.DocumentElement
	if ($null -eq $Root -or $Root.GetAttribute('type') -cne 'object') {
		throw (New-ValidationError)
	}

	$AllowedNames = [System.Collections.Generic.HashSet[string]]::new(
		[string[]]$InputKeys,
		[System.StringComparer]::Ordinal
	)
	$SeenNames = [System.Collections.Generic.HashSet[string]]::new(
		[System.StringComparer]::Ordinal
	)
	$Properties = @{}
	foreach ($Property in $Root.ChildNodes) {
		if ($Property.NodeType -ne [System.Xml.XmlNodeType]::Element -or
			-not $AllowedNames.Contains($Property.LocalName) -or
			-not $SeenNames.Add($Property.LocalName)) {
			throw (New-ValidationError)
		}
		$Properties[$Property.LocalName] = [System.Xml.XmlElement]$Property
	}
	if ($SeenNames.Count -ne $InputKeys.Count) {
		throw (New-ValidationError)
	}
	foreach ($Name in $InputKeys) {
		if (-not $SeenNames.Contains($Name)) {
			throw (New-ValidationError)
		}
	}

	$SchemaVersion = 0L
	if ($Properties.schema_version.GetAttribute('type') -cne 'number' -or
		-not [long]::TryParse(
			$Properties.schema_version.InnerText,
			[System.Globalization.NumberStyles]::Integer,
			[System.Globalization.CultureInfo]::InvariantCulture,
			[ref]$SchemaVersion
		) -or $SchemaVersion -ne 1) {
		throw (New-ValidationError)
	}

	$CurrentRoute = Assert-JsonString -Value $Properties.current_route
	if (@('direct', 'planned') -cnotcontains $CurrentRoute) {
		throw (New-ValidationError)
	}

	$ChangeCategory = Assert-JsonString -Value $Properties.change_category
	if (@(
		'text_edit',
		'small_line_change',
		'localized_reproducible_bug_fix',
		'other'
	) -cnotcontains $ChangeCategory) {
		throw (New-ValidationError)
	}

	$ExpectedFileCount = 0L
	if ($Properties.expected_file_count.GetAttribute('type') -cne 'number' -or
		-not [long]::TryParse(
			$Properties.expected_file_count.InnerText,
			[System.Globalization.NumberStyles]::Integer,
			[System.Globalization.CultureInfo]::InvariantCulture,
			[ref]$ExpectedFileCount
		) -or $ExpectedFileCount -lt 0) {
		throw (New-ValidationError)
	}

	$AssessmentSource = Assert-JsonString -Value $Properties.assessment_source
	if ([string]::IsNullOrWhiteSpace($AssessmentSource)) {
		throw (New-ValidationError)
	}

	$BooleanValues = @{}
	foreach ($Name in $NullableBooleanKeys) {
		$BooleanValues[$Name] = Convert-NullableBoolean -Value $Properties[$Name]
	}

	$NormalizedEvidence = [ordered]@{
		schema_version = 1
		current_route = $CurrentRoute
		change_category = $ChangeCategory
		expected_file_count = $ExpectedFileCount
		localized_scope = $BooleanValues.localized_scope
		clear_criteria = $BooleanValues.clear_criteria
		resolved_dependencies = $BooleanValues.resolved_dependencies
		defined_change = $BooleanValues.defined_change
		reproducible_bug_evidence = $BooleanValues.reproducible_bug_evidence
		known_verification = $BooleanValues.known_verification
		known_rollback = $BooleanValues.known_rollback
		assessment_source = $AssessmentSource
		calculation_heavy = $BooleanValues.calculation_heavy
		ambiguous_requirements = $BooleanValues.ambiguous_requirements
		cross_component = $BooleanValues.cross_component
		behavior_sensitive = $BooleanValues.behavior_sensitive
		security_or_permissions = $BooleanValues.security_or_permissions
		data_persistence_or_migration = $BooleanValues.data_persistence_or_migration
		networking_or_concurrency = $BooleanValues.networking_or_concurrency
		public_contract_or_schema = $BooleanValues.public_contract_or_schema
		architecture_build_or_release = $BooleanValues.architecture_build_or_release
		canonical_meaning_change = $BooleanValues.canonical_meaning_change
		multi_file = $ExpectedFileCount -ne 1
	}

	$Reasons = [System.Collections.Generic.List[string]]::new()
	if ($CurrentRoute -ceq 'planned') {
		$Reasons.Add('current_route_planned')
	}
	if (@(
		'text_edit',
		'small_line_change',
		'localized_reproducible_bug_fix'
	) -cnotcontains $ChangeCategory) {
		$Reasons.Add('unsupported_change_category')
	}
	if ($ExpectedFileCount -ne 1) {
		$Reasons.Add('expected_file_count_not_one')
	}
	foreach ($Entry in $PositiveReasons.GetEnumerator()) {
		if ($BooleanValues[$Entry.Key] -ne $true) {
			$Reasons.Add($Entry.Value)
		}
	}
	if ($ChangeCategory -ceq 'localized_reproducible_bug_fix' -and
		$BooleanValues.reproducible_bug_evidence -ne $true) {
		$Reasons.Add('reproducible_bug_evidence_not_confirmed')
	}
	foreach ($Entry in $HazardReasons.GetEnumerator()) {
		if ($BooleanValues[$Entry.Key] -ne $false) {
			$Reasons.Add($Entry.Value)
		}
	}

	$Route = if ($Reasons.Count -eq 0) { 'direct' } else { 'planned' }
	if ($Route -ceq 'direct') {
		$Reasons.Add('direct_eligible')
	}

	$PromotionState = if ($CurrentRoute -ceq 'planned') {
		'retained_planned'
	}
	elseif ($Route -ceq 'direct') {
		'retained_direct'
	}
	else {
		'promoted_to_planned'
	}

	[string[]]$DirectSkippedStages = @()
	if ($Route -ceq 'direct') {
		$DirectSkippedStages = @('analyst', 'synthesizer')
	}
	$RequiredDownstreamStages = if ($Route -ceq 'direct') {
		@('worker', 'verifier', 'reviewer', 'approver')
	}
	else {
		@('analyst', 'synthesizer', 'worker', 'verifier', 'reviewer', 'approver')
	}

	[pscustomobject][ordered]@{
		schema_version = 1
		route = $Route
		reason_codes = [string[]]$Reasons.ToArray()
		normalized_evidence = [pscustomobject]$NormalizedEvidence
		previous_route = $CurrentRoute
		promotion_state = $PromotionState
		direct_skipped_stages = [string[]]$DirectSkippedStages
		required_downstream_stages = [string[]]$RequiredDownstreamStages
		conditional_fresh_stages = [string[]]@(
			'integrator', 'fixer', 'adjudicator', 'qa'
		)
	}
}
catch {
	if ($_.FullyQualifiedErrorId -eq 'InvalidDeliveryRouteAssessment') {
		throw
	}
	throw (New-ValidationError)
}
finally {
	if ($null -ne $Reader) {
		$Reader.Dispose()
	}
	if ($null -ne $Stream) {
		$Stream.Dispose()
	}
}
