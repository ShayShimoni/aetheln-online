[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[string]$HandoffPath,

	[string]$SchemaPath = (
		Join-Path (Split-Path -Parent $PSScriptRoot) 'references\handoff-schemas.json'
	)
)

$ErrorActionPreference = 'Stop'

function Get-PropertyNames {
	param(
		[Parameter(Mandatory)]
		[object]$Value
	)

	return @($Value.PSObject.Properties.Name)
}

function Assert-StrictHandoffJson {
	param(
		[Parameter(Mandatory)]
		[string]$Json
	)

	$State = [pscustomobject]@{
		Json = $Json
		Index = 0
		SchemaVersionSeen = $false
	}

	function Skip-JsonWhitespace {
		while ($State.Index -lt $State.Json.Length -and
			" `t`r`n".IndexOf($State.Json[$State.Index]) -ge 0) {
			$State.Index++
		}
	}

	function Read-JsonString {
		if ($State.Index -ge $State.Json.Length -or
			$State.Json[$State.Index] -ne '"') {
			throw "Invalid JSON string at character $($State.Index)."
		}

		$State.Index++
		$Builder = New-Object System.Text.StringBuilder
		while ($State.Index -lt $State.Json.Length) {
			$Character = $State.Json[$State.Index]
			$State.Index++
			if ($Character -eq '"') {
				return $Builder.ToString()
			}
			if ([int][char]$Character -lt 0x20) {
				throw "Invalid control character in JSON string at character $($State.Index - 1)."
			}
			if ($Character -ne '\') {
				[void]$Builder.Append($Character)
				continue
			}

			if ($State.Index -ge $State.Json.Length) {
				throw 'Invalid escape at the end of a JSON string.'
			}
			$Escape = $State.Json[$State.Index]
			$State.Index++
			switch ($Escape) {
				'"' { [void]$Builder.Append('"') }
				'\' { [void]$Builder.Append('\') }
				'/' { [void]$Builder.Append('/') }
				'b' { [void]$Builder.Append([char]0x08) }
				'f' { [void]$Builder.Append([char]0x0c) }
				'n' { [void]$Builder.Append([char]0x0a) }
				'r' { [void]$Builder.Append([char]0x0d) }
				't' { [void]$Builder.Append([char]0x09) }
				'u' {
					if ($State.Index + 4 -gt $State.Json.Length) {
						throw 'Incomplete Unicode escape in JSON string.'
					}
					$Hex = $State.Json.Substring($State.Index, 4)
					if ($Hex -notmatch '^[0-9A-Fa-f]{4}$') {
						throw "Invalid Unicode escape '\u$Hex' in JSON string."
					}
					[void]$Builder.Append([char][Convert]::ToInt32($Hex, 16))
					$State.Index += 4
				}
				default { throw "Invalid JSON escape '\$Escape'." }
			}
		}

		throw 'Unterminated JSON string.'
	}

	function Read-JsonNumber {
		$Start = $State.Index
		if ($State.Json[$State.Index] -eq '-') {
			$State.Index++
		}
		if ($State.Index -ge $State.Json.Length) {
			throw 'Incomplete JSON number.'
		}
		if ($State.Json[$State.Index] -eq '0') {
			$State.Index++
			if ($State.Index -lt $State.Json.Length -and
				$State.Json[$State.Index] -match '[0-9]') {
				throw "Invalid leading zero in JSON number at character $Start."
			}
		}
		elseif ($State.Json[$State.Index] -match '[1-9]') {
			do { $State.Index++ } while (
				$State.Index -lt $State.Json.Length -and
				$State.Json[$State.Index] -match '[0-9]'
			)
		}
		else {
			throw "Invalid JSON number at character $Start."
		}

		$Kind = 'Integer'
		if ($State.Index -lt $State.Json.Length -and
			$State.Json[$State.Index] -eq '.') {
			$Kind = 'Number'
			$State.Index++
			if ($State.Index -ge $State.Json.Length -or
				$State.Json[$State.Index] -notmatch '[0-9]') {
				throw "Invalid JSON fraction at character $Start."
			}
			do { $State.Index++ } while (
				$State.Index -lt $State.Json.Length -and
				$State.Json[$State.Index] -match '[0-9]'
			)
		}
		if ($State.Index -lt $State.Json.Length -and
			$State.Json[$State.Index] -match '[eE]') {
			$Kind = 'Number'
			$State.Index++
			if ($State.Index -lt $State.Json.Length -and
				$State.Json[$State.Index] -match '[+-]') {
				$State.Index++
			}
			if ($State.Index -ge $State.Json.Length -or
				$State.Json[$State.Index] -notmatch '[0-9]') {
				throw "Invalid JSON exponent at character $Start."
			}
			do { $State.Index++ } while (
				$State.Index -lt $State.Json.Length -and
				$State.Json[$State.Index] -match '[0-9]'
			)
		}

		return [pscustomobject]@{
			Kind = $Kind
			Raw = $State.Json.Substring($Start, $State.Index - $Start)
		}
	}

	function Read-JsonValue {
		param([int]$Depth)

		Skip-JsonWhitespace
		if ($State.Index -ge $State.Json.Length) {
			throw 'Unexpected end of JSON input.'
		}

		switch ($State.Json[$State.Index]) {
			'{' {
				$State.Index++
				$Names = New-Object 'System.Collections.Generic.HashSet[string]' (
					[System.StringComparer]::Ordinal
				)
				Skip-JsonWhitespace
				if ($State.Index -lt $State.Json.Length -and
					$State.Json[$State.Index] -eq '}') {
					$State.Index++
					return [pscustomobject]@{ Kind = 'Object'; Raw = $null }
				}
				do {
					Skip-JsonWhitespace
					$Name = Read-JsonString
					if (-not $Names.Add($Name)) {
						throw "Duplicate JSON object member '$Name'."
					}
					Skip-JsonWhitespace
					if ($State.Index -ge $State.Json.Length -or
						$State.Json[$State.Index] -ne ':') {
						throw "Expected ':' after JSON object member '$Name'."
					}
					$State.Index++
					$Value = Read-JsonValue -Depth ($Depth + 1)
					if ($Depth -eq 0 -and $Name -ceq 'schema_version') {
						$State.SchemaVersionSeen = $true
						if ($Value.Kind -ne 'Integer' -or $Value.Raw -cne '1') {
							throw 'schema_version must be the JSON integer number 1.'
						}
					}
					Skip-JsonWhitespace
					if ($State.Index -lt $State.Json.Length -and
						$State.Json[$State.Index] -eq ',') {
						$State.Index++
						continue
					}
					break
				} while ($true)
				if ($State.Index -ge $State.Json.Length -or
					$State.Json[$State.Index] -ne '}') {
					throw 'Expected closing brace in JSON object.'
				}
				$State.Index++
				return [pscustomobject]@{ Kind = 'Object'; Raw = $null }
			}
			'[' {
				$State.Index++
				Skip-JsonWhitespace
				if ($State.Index -lt $State.Json.Length -and
					$State.Json[$State.Index] -eq ']') {
					$State.Index++
					return [pscustomobject]@{ Kind = 'Array'; Raw = $null }
				}
				do {
					$null = Read-JsonValue -Depth ($Depth + 1)
					Skip-JsonWhitespace
					if ($State.Index -lt $State.Json.Length -and
						$State.Json[$State.Index] -eq ',') {
						$State.Index++
						continue
					}
					break
				} while ($true)
				if ($State.Index -ge $State.Json.Length -or
					$State.Json[$State.Index] -ne ']') {
					throw 'Expected closing bracket in JSON array.'
				}
				$State.Index++
				return [pscustomobject]@{ Kind = 'Array'; Raw = $null }
			}
			'"' {
				$null = Read-JsonString
				return [pscustomobject]@{ Kind = 'String'; Raw = $null }
			}
			default {
				$Remaining = $State.Json.Substring($State.Index)
				foreach ($Literal in @('true', 'false', 'null')) {
					if ($Remaining.StartsWith($Literal, [StringComparison]::Ordinal)) {
						$State.Index += $Literal.Length
						return [pscustomobject]@{ Kind = 'Literal'; Raw = $Literal }
					}
				}
				if ($State.Json[$State.Index] -eq '-' -or
					$State.Json[$State.Index] -match '[0-9]') {
					return Read-JsonNumber
				}
				throw "Invalid JSON token at character $($State.Index)."
			}
		}
	}

	$Root = Read-JsonValue -Depth 0
	Skip-JsonWhitespace
	if ($Root.Kind -ne 'Object') {
		throw 'Handoff must be a JSON object.'
	}
	if ($State.Index -ne $State.Json.Length) {
		throw "Unexpected JSON content at character $($State.Index)."
	}
	if (-not $State.SchemaVersionSeen) {
		throw "Handoff is missing required property 'schema_version'."
	}
}

function Test-NonEmptyValue {
	param(
		[AllowNull()]
		[object]$Value
	)

	if ($null -eq $Value) {
		return $false
	}

	if ($Value -is [string]) {
		return -not [string]::IsNullOrWhiteSpace($Value)
	}

	if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
		return @($Value).Count -gt 0
	}

	return $true
}

function Test-JsonInteger {
	param(
		[AllowNull()]
		[object]$Value
	)

	return (
		$null -ne $Value -and
		$Value -isnot [bool] -and
		$Value -isnot [string] -and
		$Value -is [ValueType] -and
		$Value -isnot [single] -and
		$Value -isnot [double] -and
		$Value -isnot [decimal]
	)
}

function Assert-ClosedObject {
	param(
		[Parameter(Mandatory)]
		[string]$Name,

		[AllowNull()]
		[object]$Value,

		[Parameter(Mandatory)]
		[string[]]$AllowedNames
	)

	if ($null -eq $Value -or
		$Value -isnot [System.Management.Automation.PSCustomObject]) {
		throw "$Name must be a JSON object."
	}

	$AllowedSet = [System.Collections.Generic.HashSet[string]]::new(
		$AllowedNames,
		[System.StringComparer]::Ordinal
	)
	foreach ($PropertyName in (Get-PropertyNames -Value $Value)) {
		if (-not $AllowedSet.Contains($PropertyName)) {
			throw "$Name property '$PropertyName' is not allowed."
		}
	}
}

function Throw-NeutralEvidenceError {
	param(
		[Parameter(Mandatory)]
		[string]$FieldName,

		[Parameter(Mandatory)]
		[string]$Code
	)

	throw "Neutral evidence field '$FieldName' failed validation: $Code."
}

function Get-NeutralEvidenceHash {
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

function Assert-NeutralEvidenceRecord {
	param(
		[Parameter(Mandatory)]
		[string]$FieldName,

		[AllowNull()]
		[object]$Record,

		[Parameter(Mandatory)]
		[string[]]$AllowedKinds,

		[Parameter(Mandatory)]
		[string[]]$AllowedProvenances,

		[Parameter(Mandatory)]
		[object]$NeutralSchema
	)

	if ($null -eq $Record -or
		$Record -isnot [System.Management.Automation.PSCustomObject]) {
		Throw-NeutralEvidenceError -FieldName $FieldName `
			-Code 'neutral_evidence_record_required'
	}

	$ExpectedNames = [string[]]@($NeutralSchema.record_fields)
	$ActualNames = @(Get-PropertyNames -Value $Record)
	if ($ActualNames.Count -ne $ExpectedNames.Count) {
		Throw-NeutralEvidenceError -FieldName $FieldName `
			-Code 'neutral_evidence_keys_invalid'
	}
	foreach ($ExpectedName in $ExpectedNames) {
		if ($ActualNames -cnotcontains $ExpectedName) {
			Throw-NeutralEvidenceError -FieldName $FieldName `
				-Code 'neutral_evidence_keys_invalid'
		}
	}

	if ($Record.kind -isnot [string] -or
		@($NeutralSchema.kinds) -cnotcontains $Record.kind -or
		$AllowedKinds -cnotcontains $Record.kind) {
		Throw-NeutralEvidenceError -FieldName $FieldName `
			-Code 'neutral_evidence_kind_invalid'
	}

	if ($Record.provenance -isnot [string] -or
		@($NeutralSchema.provenances) -cnotcontains $Record.provenance -or
		$AllowedProvenances -cnotcontains $Record.provenance) {
		Throw-NeutralEvidenceError -FieldName $FieldName `
			-Code 'neutral_evidence_provenance_invalid'
	}

	if ($Record.encoding -isnot [string] -or
		@($NeutralSchema.encodings) -cnotcontains $Record.encoding) {
		Throw-NeutralEvidenceError -FieldName $FieldName `
			-Code 'neutral_evidence_encoding_invalid'
	}

	if ($Record.source -isnot [string] -or
		[string]::IsNullOrWhiteSpace($Record.source)) {
		Throw-NeutralEvidenceError -FieldName $FieldName `
			-Code 'neutral_evidence_source_invalid'
	}

	if ($Record.sha256 -isnot [string] -or
		$Record.sha256 -cnotmatch '^[0-9a-f]{64}$') {
		Throw-NeutralEvidenceError -FieldName $FieldName `
			-Code 'neutral_evidence_sha256_invalid'
	}

	if ($Record.content -isnot [string]) {
		Throw-NeutralEvidenceError -FieldName $FieldName `
			-Code 'neutral_evidence_content_invalid'
	}

	if ($Record.encoding -ceq 'base64') {
		try {
			$ContentBytes = [System.Convert]::FromBase64String($Record.content)
		}
		catch {
			Throw-NeutralEvidenceError -FieldName $FieldName `
				-Code 'neutral_evidence_base64_invalid'
		}
		if ([System.Convert]::ToBase64String($ContentBytes) -cne $Record.content) {
			Throw-NeutralEvidenceError -FieldName $FieldName `
				-Code 'neutral_evidence_base64_invalid'
		}
	}
	else {
		try {
			$StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
			$ContentBytes = $StrictUtf8.GetBytes($Record.content)
		}
		catch {
			Throw-NeutralEvidenceError -FieldName $FieldName `
				-Code 'neutral_evidence_content_invalid'
		}
	}

	$ComputedHash = Get-NeutralEvidenceHash -Bytes $ContentBytes
	if (-not [string]::Equals(
		$ComputedHash,
		$Record.sha256,
		[System.StringComparison]::Ordinal
	)) {
		Throw-NeutralEvidenceError -FieldName $FieldName `
			-Code 'neutral_evidence_hash_mismatch'
	}
}

function Assert-NeutralEvidenceFields {
	param(
		[Parameter(Mandatory)]
		[object]$Handoff,

		[Parameter(Mandatory)]
		[object]$FieldMappings,

		[Parameter(Mandatory)]
		[object]$NeutralSchema,

		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[System.Collections.Generic.List[object]]
		$ValidatedRecords,

		[switch]
		$IsRoot
	)

	foreach ($Mapping in $FieldMappings.PSObject.Properties) {
		$FieldName = $Mapping.Name
		$Parts = @(([string]$Mapping.Value).Split(':'))
		if ($Parts.Count -ne 3 -or
			@('single', 'array') -cnotcontains $Parts[0]) {
			Throw-NeutralEvidenceError -FieldName $FieldName `
				-Code 'neutral_evidence_field_contract_invalid'
		}

		$AllowedKinds = @($Parts[1].Split('|'))
		$AllowedProvenances = @($Parts[2].Split('|'))
		if ($AllowedKinds.Count -eq 0 -or
			$AllowedProvenances.Count -eq 0 -or
			@($AllowedKinds | Where-Object {
				[string]::IsNullOrWhiteSpace($_) -or
				@($NeutralSchema.kinds) -cnotcontains $_
			}).Count -gt 0 -or
			@($AllowedProvenances | Where-Object {
				[string]::IsNullOrWhiteSpace($_) -or
				@($NeutralSchema.provenances) -cnotcontains $_
			}).Count -gt 0) {
			Throw-NeutralEvidenceError -FieldName $FieldName `
				-Code 'neutral_evidence_field_contract_invalid'
		}

		if (@($Handoff.PSObject.Properties.Name) -cnotcontains $FieldName) {
			continue
		}

		$Value = $Handoff.($FieldName)
		if ($Parts[0] -ceq 'single') {
			if ($Value -isnot [System.Management.Automation.PSCustomObject]) {
				Throw-NeutralEvidenceError -FieldName $FieldName `
					-Code 'neutral_evidence_record_required'
			}
			$Records = @($Value)
		}
		else {
			if ($Value -isnot [System.Array] -or @($Value).Count -eq 0) {
				Throw-NeutralEvidenceError -FieldName $FieldName `
					-Code 'neutral_evidence_array_required'
			}
			$Records = @($Value)
		}

		foreach ($Record in $Records) {
			Assert-NeutralEvidenceRecord -FieldName $FieldName -Record $Record `
				-AllowedKinds $AllowedKinds `
				-AllowedProvenances $AllowedProvenances `
				-NeutralSchema $NeutralSchema
			$null = $ValidatedRecords.Add($Record)
		}
	}
}

function Find-ProhibitedMarker {
	param(
		[AllowNull()]
		[object]$Value,

		[Parameter(Mandatory)]
		[System.Collections.Generic.HashSet[string]]$Prohibited,

		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[System.Collections.Generic.List[object]]
		$ValidatedRecords,

		[switch]
		$IsRoot
	)

	if ($null -eq $Value) {
		return $null
	}

	if ($Value -is [string]) {
		foreach ($Marker in $Prohibited) {
			if ($Value.IndexOf(
				$Marker,
				[System.StringComparison]::OrdinalIgnoreCase
			) -ge 0) {
				return $Marker
			}
		}

		return $null
	}

	if ($Value.GetType().IsPrimitive) {
		return $null
	}

	if ($Value -is [System.Collections.IEnumerable] -and
		$Value -isnot [System.Management.Automation.PSCustomObject]) {
		foreach ($Item in $Value) {
			$Found = Find-ProhibitedMarker -Value $Item `
				-Prohibited $Prohibited `
				-ValidatedRecords $ValidatedRecords
			if ($null -ne $Found) {
				return $Found
			}
		}

		return $null
	}

	$IsValidatedRecord = $false
	foreach ($Record in $ValidatedRecords) {
		if ([object]::ReferenceEquals($Value, $Record)) {
			$IsValidatedRecord = $true
			break
		}
	}

	foreach ($Property in $Value.PSObject.Properties) {
		if ($Prohibited.Contains($Property.Name)) {
			return $Property.Name
		}
		if ($IsValidatedRecord -and $Property.Name -ceq 'content') {
			continue
		}
		if ($IsRoot -and $Property.Name -in @('acceptance_criteria', 'output_contract')) {
			continue
		}

		$Found = Find-ProhibitedMarker -Value $Property.Value `
			-Prohibited $Prohibited `
			-ValidatedRecords $ValidatedRecords
		if ($null -ne $Found) {
			return $Found
		}
	}

	return $null
}

$ResolvedHandoffPath = (Resolve-Path -LiteralPath $HandoffPath).Path
$ResolvedSchemaPath = (Resolve-Path -LiteralPath $SchemaPath).Path
$HandoffBytes = [System.IO.File]::ReadAllBytes($ResolvedHandoffPath)
try {
	$StrictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
	$HandoffJson = $StrictUtf8.GetString($HandoffBytes)
}
catch [System.Text.DecoderFallbackException] {
	throw 'Handoff JSON is not valid UTF-8.'
}
if ($HandoffJson.Length -gt 0 -and $HandoffJson[0] -eq [char]0xfeff) {
	$HandoffJson = $HandoffJson.Substring(1)
}
Assert-StrictHandoffJson -Json $HandoffJson
$Handoff = $HandoffJson | ConvertFrom-Json
$Schema = Get-Content -Raw -LiteralPath $ResolvedSchemaPath | ConvertFrom-Json

if ($Handoff.schema_version -ne $Schema.schema_version) {
	throw "Unsupported handoff schema version '$($Handoff.schema_version)'."
}

$Stage = [string]$Handoff.stage
$RunId = [string]$Handoff.run_id
if ($RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$') {
	throw (
		"Handoff run_id '$RunId' is not a safe artifact identifier. " +
		"Use 1-80 ASCII letters, digits, dots, underscores, or hyphens, " +
		"starting with a letter or digit."
	)
}

$StageSchemaProperty = $Schema.stages.PSObject.Properties |
	Where-Object { $_.Name -eq $Stage } |
	Select-Object -First 1

if ($null -eq $StageSchemaProperty) {
	throw "Unknown delivery stage '$Stage'."
}

$StageSchema = $StageSchemaProperty.Value
$Required = @($Schema.common_required) + @($StageSchema.required)
$AllowEmpty = @('baseline_status', 'baseline_diff')
$Allowed = [System.Collections.Generic.HashSet[string]]::new(
	[string[]](@($Schema.common_allowed) + @($StageSchema.allowed)),
	[System.StringComparer]::Ordinal
)
$PropertyNames = Get-PropertyNames -Value $Handoff

foreach ($PropertyName in $PropertyNames) {
	if (-not $Allowed.Contains($PropertyName)) {
		throw "Handoff property '$PropertyName' is not allowed for stage '$Stage'."
	}
}

foreach ($RequiredName in $Required) {
	if ($PropertyNames -notcontains $RequiredName) {
		throw "Handoff is missing required property '$RequiredName' for stage '$Stage'."
	}

	if ($AllowEmpty -notcontains $RequiredName -and
		-not (Test-NonEmptyValue -Value $Handoff.$RequiredName)) {
		throw "Handoff property '$RequiredName' must not be empty for stage '$Stage'."
	}
}

if ($Stage -eq 'worker') {
	$WorkerValidatorPath = Join-Path -Path $PSScriptRoot -ChildPath 'Validate-DeliveryWorkerHandoff.ps1'
	& $WorkerValidatorPath -Handoff $Handoff -PropertyNames $PropertyNames
}

if ($StageSchema.blind) {
	$ValidatedNeutralEvidenceRecords = New-Object `
		'System.Collections.Generic.List[object]'
	if ($null -ne $StageSchema.neutral_evidence_fields) {
		Assert-NeutralEvidenceFields `
			-Handoff $Handoff `
			-FieldMappings $StageSchema.neutral_evidence_fields `
			-NeutralSchema $Schema.neutral_evidence_schema `
			-ValidatedRecords $ValidatedNeutralEvidenceRecords
	}

	$Prohibited = [System.Collections.Generic.HashSet[string]]::new(
		[string[]]@($Schema.blind_prohibited_keys),
		[System.StringComparer]::OrdinalIgnoreCase
	)
	$Found = Find-ProhibitedMarker -Value $Handoff `
		-Prohibited $Prohibited `
		-ValidatedRecords $ValidatedNeutralEvidenceRecords `
		-IsRoot
	if ($null -ne $Found) {
		throw "Handoff contains prohibited blind-stage marker '$Found'."
	}
}

$DefaultCapabilityClass = if ($Stage -eq 'adjudicator') {
	'elevated'
}
else {
	'standard'
}
$ExecutionPolicy = [pscustomobject]@{
	AttemptOrdinal = 1
	AttemptClass = 'initial'
	CapabilityClass = $DefaultCapabilityClass
	RetryCause = $null
	Limits = [pscustomobject]@{
		TotalTokens = $null
		ElapsedMilliseconds = $null
		ConcurrentStages = $null
		ExecutionRetries = $null
		FixCycles = $null
		Provenance = $null
		ApprovedAtUtc = $null
	}
}

if ($PropertyNames -contains 'execution_policy') {
	$Policy = $Handoff.execution_policy
	$PolicySchema = $Schema.execution_policy
	Assert-ClosedObject `
		-Name 'execution_policy' `
		-Value $Policy `
		-AllowedNames @($PolicySchema.allowed)
	$PolicyNames = Get-PropertyNames -Value $Policy

	if ($PolicyNames -contains 'attempt_ordinal') {
		if (-not (Test-JsonInteger -Value $Policy.attempt_ordinal) -or
			[long]$Policy.attempt_ordinal -lt 1) {
			throw 'execution_policy.attempt_ordinal must be an integer greater than or equal to 1.'
		}
		$ExecutionPolicy.AttemptOrdinal = [long]$Policy.attempt_ordinal
	}

	if ($PolicyNames -contains 'attempt_class') {
		if ($Policy.attempt_class -isnot [string] -or
			@($PolicySchema.attempt_classes) -notcontains $Policy.attempt_class) {
			throw 'execution_policy.attempt_class is invalid.'
		}
		$ExecutionPolicy.AttemptClass = [string]$Policy.attempt_class
	}

	if ($PolicyNames -contains 'capability_class') {
		if ($Policy.capability_class -isnot [string] -or
			@($PolicySchema.capability_classes) -notcontains $Policy.capability_class) {
			throw 'execution_policy.capability_class is invalid.'
		}
		$ExecutionPolicy.CapabilityClass = [string]$Policy.capability_class
	}

	if ($ExecutionPolicy.CapabilityClass -eq 'economy' -and
		@($PolicySchema.economy_prohibited_stages) -contains $Stage) {
		throw "execution_policy.capability_class 'economy' is not allowed for stage '$Stage'."
	}

	if ($PolicyNames -contains 'retry_cause') {
		if ($null -ne $Policy.retry_cause -and
			($Policy.retry_cause -isnot [string] -or
			[string]::IsNullOrWhiteSpace($Policy.retry_cause))) {
			throw 'execution_policy.retry_cause must be null or a nonblank string.'
		}
		$ExecutionPolicy.RetryCause = $Policy.retry_cause
	}

	if ($PolicyNames -contains 'limits') {
		$Limits = $Policy.limits
		Assert-ClosedObject `
			-Name 'execution_policy.limits' `
			-Value $Limits `
			-AllowedNames @($PolicySchema.limits_allowed)
		$LimitNames = Get-PropertyNames -Value $Limits
		$NumericLimits = @{
			total_tokens = 'TotalTokens'
			elapsed_milliseconds = 'ElapsedMilliseconds'
			concurrent_stages = 'ConcurrentStages'
			execution_retries = 'ExecutionRetries'
			fix_cycles = 'FixCycles'
		}
		$HasNumericLimit = $false
		foreach ($LimitName in $NumericLimits.Keys) {
			if ($LimitNames -contains $LimitName) {
				$LimitValue = $Limits.$LimitName
				if ($null -ne $LimitValue -and
					(-not (Test-JsonInteger -Value $LimitValue) -or
					[long]$LimitValue -lt 0)) {
					throw "execution_policy.limits.$LimitName must be null or a non-negative integer."
				}
				if ($null -ne $LimitValue) {
					$HasNumericLimit = $true
					$ExecutionPolicy.Limits.($NumericLimits[$LimitName]) = [long]$LimitValue
				}
			}
		}

		if ($LimitNames -contains 'provenance') {
			if ($null -ne $Limits.provenance -and
				($Limits.provenance -isnot [string] -or
				[string]::IsNullOrWhiteSpace($Limits.provenance))) {
				throw 'execution_policy.limits.provenance must be null or a nonblank string.'
			}
			$ExecutionPolicy.Limits.Provenance = $Limits.provenance
		}

		if ($LimitNames -contains 'approved_at_utc') {
			$ApprovedAtUtc = $Limits.approved_at_utc
			$ParsedApprovedAtUtc = [datetimeoffset]::MinValue
			$TimestampValid = (
				$null -eq $ApprovedAtUtc -or
				($ApprovedAtUtc -is [string] -and
				$ApprovedAtUtc -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$' -and
				[datetimeoffset]::TryParseExact(
					$ApprovedAtUtc,
					"yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'",
					[System.Globalization.CultureInfo]::InvariantCulture,
					[System.Globalization.DateTimeStyles]::AssumeUniversal,
					[ref]$ParsedApprovedAtUtc
				))
			)
			if (-not $TimestampValid) {
				throw 'execution_policy.limits.approved_at_utc must be null or a strict UTC ISO-8601 timestamp ending in Z.'
			}
			$ExecutionPolicy.Limits.ApprovedAtUtc = $ApprovedAtUtc
		}

		if ($HasNumericLimit -and
			([string]::IsNullOrWhiteSpace([string]$ExecutionPolicy.Limits.Provenance) -or
			$null -eq $ExecutionPolicy.Limits.ApprovedAtUtc)) {
			throw 'Non-null execution_policy numeric limits require non-null user-approved provenance and approved_at_utc.'
		}
	}
}

$WorkspaceRoot = (Resolve-Path -LiteralPath ([string]$Handoff.workspace_root)).Path
$Hasher = [System.Security.Cryptography.SHA256]::Create()
try {
	$Hash = [System.BitConverter]::ToString(
		$Hasher.ComputeHash($HandoffBytes)
	).Replace('-', '').ToLowerInvariant()
}
finally {
	$Hasher.Dispose()
}

[pscustomobject]@{
	Stage = $Stage
	RunId = $RunId
	WorkspaceRoot = $WorkspaceRoot
	HandoffPath = $ResolvedHandoffPath
	HandoffHash = $Hash
	Handoff = $Handoff
	HandoffJson = $HandoffJson
	ExecutionPolicy = $ExecutionPolicy
}
