[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[string]$BaselinePath,

	[Parameter(Mandatory)]
	[string]$CandidatePath
)

$ErrorActionPreference = 'Stop'

function Test-JsonObject {
	param([AllowNull()][object]$Value)

	return $null -ne $Value -and $Value -is [pscustomobject]
}

function Assert-ExactProperties {
	param(
		[Parameter(Mandatory)]
		[pscustomobject]$Value,

		[Parameter(Mandatory)]
		[string[]]$Expected,

		[Parameter(Mandatory)]
		[string]$Location
	)

	$Actual = @($Value.PSObject.Properties.Name)
	if ($Actual.Count -ne $Expected.Count) {
		throw "$Location must contain exactly the required fields."
	}

	foreach ($Name in $Expected) {
		if (-not ($Actual -ccontains $Name)) {
			throw "$Location must contain exactly the required fields."
		}
	}
}

function Test-NonNegativeIntegralNumber {
	param([AllowNull()][object]$Value)

	$NumericTypes = @(
		[byte], [sbyte], [int16], [uint16], [int32], [uint32],
		[int64], [uint64], [single], [double], [decimal]
	)
	$IsNumeric = $false
	foreach ($NumericType in $NumericTypes) {
		if ($Value -is $NumericType) {
			$IsNumeric = $true
			break
		}
	}
	if (-not $IsNumeric) {
		return $false
	}

	$AsDouble = [double]$Value
	return -not [double]::IsNaN($AsDouble) -and
		-not [double]::IsInfinity($AsDouble) -and
		$AsDouble -ge 0 -and
		[math]::Floor($AsDouble) -eq $AsDouble
}

function Read-EfficiencyRecord {
	param(
		[Parameter(Mandatory)]
		[string]$Path,

		[Parameter(Mandatory)]
		[string]$Label
	)

	try {
		$Record = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
	}
	catch {
		throw "$Label input could not be read as JSON."
	}

	if (-not (Test-JsonObject -Value $Record)) {
		throw "$Label root must be a JSON object."
	}

	$RootFields = @(
		'schema_version',
		'quality_criteria_version',
		'environment_id',
		'total_tokens',
		'quality'
	)
	Assert-ExactProperties -Value $Record -Expected $RootFields -Location "$Label root"

	if ($Record.schema_version -isnot [int64] -and
		$Record.schema_version -isnot [int32]) {
		throw "$Label schema_version must be integer 1."
	}
	if ([int64]$Record.schema_version -ne 1) {
		throw "$Label schema_version must be integer 1."
	}
	if ($Record.quality_criteria_version -isnot [string] -or
		$Record.quality_criteria_version -cne 'issue-70-quality-v1') {
		throw "$Label quality_criteria_version must be 'issue-70-quality-v1'."
	}
	if ($Record.environment_id -isnot [string] -or
		[string]::IsNullOrWhiteSpace($Record.environment_id)) {
		throw "$Label environment_id must be a nonblank string."
	}
	if ($null -ne $Record.total_tokens -and
		-not (Test-NonNegativeIntegralNumber -Value $Record.total_tokens)) {
		throw "$Label total_tokens must be null or a nonnegative integral number."
	}
	if (-not (Test-JsonObject -Value $Record.quality)) {
		throw "$Label quality must be a JSON object."
	}

	$QualityFields = @(
		'mandatory_checks_passed',
		'attestations_passed',
		'acceptance_evidence_complete',
		'unresolved_material_findings',
		'approval_passed'
	)
	Assert-ExactProperties `
		-Value $Record.quality `
		-Expected $QualityFields `
		-Location "$Label quality"

	foreach ($BooleanField in @(
		'mandatory_checks_passed',
		'attestations_passed',
		'acceptance_evidence_complete',
		'approval_passed'
	)) {
		if ($Record.quality.$BooleanField -isnot [bool]) {
			throw "$Label quality boolean fields must contain booleans."
		}
	}
	if (-not (Test-NonNegativeIntegralNumber `
		-Value $Record.quality.unresolved_material_findings)) {
		throw "$Label unresolved_material_findings must be a nonnegative integral number."
	}

	$QualityPassed = $Record.quality.mandatory_checks_passed -and
		$Record.quality.attestations_passed -and
		$Record.quality.acceptance_evidence_complete -and
		$Record.quality.approval_passed -and
		$Record.quality.unresolved_material_findings -eq 0

	return [pscustomobject]@{
		QualityCriteriaVersion = $Record.quality_criteria_version
		EnvironmentId = $Record.environment_id
		TotalTokens = $Record.total_tokens
		QualityPassed = $QualityPassed
	}
}

$Baseline = Read-EfficiencyRecord -Path $BaselinePath -Label 'Baseline'
$Candidate = Read-EfficiencyRecord -Path $CandidatePath -Label 'Candidate'
$TokenDelta = if ($null -ne $Baseline.TotalTokens -and
	$null -ne $Candidate.TotalTokens) {
	$Candidate.TotalTokens - $Baseline.TotalTokens
} else {
	$null
}

if ($Baseline.QualityPassed -and -not $Candidate.QualityPassed) {
	$Classification = 'quality_regression'
	$Reason = 'Candidate quality does not pass while baseline quality passes.'
} elseif ($Baseline.QualityCriteriaVersion -cne $Candidate.QualityCriteriaVersion) {
	$Classification = 'not_measurable'
	$Reason = 'Quality criteria versions differ.'
} elseif ($Baseline.EnvironmentId -cne $Candidate.EnvironmentId) {
	$Classification = 'not_measurable'
	$Reason = 'Environment identities differ.'
} elseif ($null -eq $Baseline.TotalTokens -or $null -eq $Candidate.TotalTokens) {
	$Classification = 'not_measurable'
	$Reason = 'Measured total tokens are missing.'
} elseif (-not $Baseline.QualityPassed) {
	$Classification = 'not_measurable'
	$Reason = 'Baseline quality does not pass.'
} elseif ($Candidate.TotalTokens -lt $Baseline.TotalTokens) {
	$Classification = 'improved'
	$Reason = 'Candidate passed quality with fewer measured total tokens.'
} else {
	$Classification = 'not_improved'
	$Reason = 'Candidate passed quality without fewer measured total tokens.'
}

[pscustomobject][ordered]@{
	Classification = $Classification
	BaselineQualityPassed = $Baseline.QualityPassed
	CandidateQualityPassed = $Candidate.QualityPassed
	BaselineTotalTokens = $Baseline.TotalTokens
	CandidateTotalTokens = $Candidate.TotalTokens
	TokenDelta = $TokenDelta
	Reason = $Reason
}
