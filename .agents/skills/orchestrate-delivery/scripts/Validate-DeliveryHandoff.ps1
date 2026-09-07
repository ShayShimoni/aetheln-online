[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[string]$HandoffPath,

	[AllowNull()]
	[AllowEmptyCollection()]
	[byte[]]$AuthoritativeEvidenceManifestBytes,

	[AllowNull()]
	[AllowEmptyString()]
	[string]$ExpectedAuthoritativeEvidenceManifestSha256,

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
		[string]$Json,

		[ValidateSet('handoff', 'authoritative_evidence_manifest')]
		[string]$DocumentKind = 'handoff',

		[string[]]$RelevantEvidenceFields = @()
	)

	$State = [pscustomobject]@{
		Json = $Json
		Index = 0
		SchemaVersionSeen = $false
	}


	$RelevantEvidenceSet = [System.Collections.Generic.HashSet[string]]::new(
		[System.StringComparer]::Ordinal
	)
	foreach ($RelevantEvidenceField in $RelevantEvidenceFields) {
		$null = $RelevantEvidenceSet.Add($RelevantEvidenceField)
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
		param(
			[int]$Depth,

			[AllowNull()]
			[string]$EvidenceFieldName
		)

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
						$DuplicateField = $null
						if ($DocumentKind -ceq 'authoritative_evidence_manifest') {
							$DuplicateField = 'authoritative_evidence_manifest'
						}
						elseif ($Depth -eq 0 -and
							@('stage', 'required_evidence_sources') -ccontains $Name) {
							$DuplicateField = $Name
						}
						elseif (-not [string]::IsNullOrEmpty($EvidenceFieldName)) {
							$DuplicateField = $EvidenceFieldName
						}
						elseif ($Depth -eq 0 -and $RelevantEvidenceSet.Contains($Name)) {
							$DuplicateField = $Name
						}

						if ($null -ne $DuplicateField) {
							Throw-RequiredEvidenceError -FieldName $DuplicateField `
								-Code 'required_evidence_json_member_duplicate'
						}
						throw "Duplicate JSON object member '$Name'."
					}
					Skip-JsonWhitespace
					if ($State.Index -ge $State.Json.Length -or
						$State.Json[$State.Index] -ne ':') {
						throw "Expected ':' after JSON object member '$Name'."
					}
					$State.Index++
					$ChildEvidenceFieldName = $EvidenceFieldName
					if ($Depth -eq 0 -and (
						$Name -ceq 'required_evidence_sources' -or
						$RelevantEvidenceSet.Contains($Name)
					)) {
						$ChildEvidenceFieldName = $Name
					}
					$Value = Read-JsonValue -Depth ($Depth + 1) `
						-EvidenceFieldName $ChildEvidenceFieldName
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
					$null = Read-JsonValue -Depth ($Depth + 1) `
						-EvidenceFieldName $EvidenceFieldName
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

	$Root = Read-JsonValue -Depth 0 -EvidenceFieldName $null
	Skip-JsonWhitespace
	if ($Root.Kind -ne 'Object') {
		throw 'Handoff must be a JSON object.'
	}
	if ($State.Index -ne $State.Json.Length) {
		throw "Unexpected JSON content at character $($State.Index)."
	}
	if ($DocumentKind -ceq 'handoff' -and -not $State.SchemaVersionSeen) {
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

function Test-DeliveryContainsExactSourceTool {
	param(
		[AllowNull()]
		[object]$Value
	)

	if ($null -eq $Value) {
		return $false
	}
	if ($Value -is [string]) {
		return [string]$Value -cmatch `
			'(?<![A-Za-z0-9_])read_allowed_source_file(?![A-Za-z0-9_])'
	}
	if ($Value -is [pscustomobject]) {
		foreach ($Property in $Value.PSObject.Properties) {
			if ((Test-DeliveryContainsExactSourceTool -Value $Property.Name) -or
				(Test-DeliveryContainsExactSourceTool -Value $Property.Value)) {
				return $true
			}
		}
		return $false
	}
	if ($Value -is [System.Collections.IDictionary]) {
		foreach ($Key in $Value.Keys) {
			if ((Test-DeliveryContainsExactSourceTool -Value $Key) -or
				(Test-DeliveryContainsExactSourceTool -Value $Value[$Key])) {
				return $true
			}
		}
		return $false
	}
	if ($Value -is [System.Collections.IEnumerable]) {
		foreach ($Entry in $Value) {
			if (Test-DeliveryContainsExactSourceTool -Value $Entry) {
				return $true
			}
		}
	}
	return $false
}

function Test-DeliverySourceClauseIsHistoricalOrCorrective {
	param(
		[Parameter(Mandatory)]
		[string]$Clause
	)

	$Clause = [regex]::Replace(
		$Clause,
		'(`+)(?<content>[^`\r\n]+)\1',
		'${content}'
	)
	$IsReplacement = $Clause -cmatch '(?i)^\s*replace\b'
	if ($IsReplacement) {
		$Replacement = [regex]::Match(
			$Clause,
			'(?i)^\s*replace\s+(?<unsupported>.+?)\s+(?:with|in\s+favor\s+of)\s+' +
			'(?<canonical>(?:read_allowed_source_file\s*\(\s*path\s*,\s*' +
			'offset_bytes\s*\)|path\s*(?:,|\s+and\s+)\s*offset_bytes))\s*$'
		)
		if (-not $Replacement.Success) {
			return $false
		}
		$Unsupported = [string]$Replacement.Groups['unsupported'].Value
		$UnsupportedSignature = @(
			Get-DeliveryExplicitRequestMembers -Clause $Unsupported -SourceContext $true
		).Count -gt 0
		$UnsupportedMember = [regex]::Match(
			$Unsupported,
			'(?i)^\s*(?:the\s+)?(?:unsupported\s+)?' +
			'(?<member>[A-Za-z_][A-Za-z0-9_-]*)\s*$'
		)
		return $UnsupportedSignature -or (
			$UnsupportedMember.Success -and
			$UnsupportedMember.Groups['member'].Value -cnotin @('path', 'offset_bytes')
		)
	}

	$UnsupportedMember = '(?!(?:path|offset_bytes)\b)(?:limit_bytes|page_size_bytes|' +
		'timeout_seconds|encoding|' +
		'charset|max_bytes|chunk_bytes|read_window_bytes|aperture_bytes|' +
		'[A-Za-z_][A-Za-z0-9_-]*)'
	$IsDirectNegativeMember = $Clause -cmatch (
		'(?i)^\s*(?:(?:do\s+not|never)\s+(?:pass|include|send|set|add|use|' +
		'supply|attach|append)\s+(?:the\s+)?' + $UnsupportedMember + '\b|' +
		'no\s+(?:source\s+)?(?:calls?|requests?|invocations?)\s+' +
		'(?:with|using|containing|including)\s+' + $UnsupportedMember + '\b)'
	)
	$IsAdministrativeCorrection = $Clause -cmatch (
		'(?i)^\s*(?:remove\b|reject\b|forbid\b|disallow\b|prevent\b|' +
		'swap\b|change\s+from\b|document\s+that\b)'
	)
	$IsCorrective = $IsDirectNegativeMember -or (
		$IsAdministrativeCorrection -and
		-not (Test-DeliverySourceClauseHasActiveDirective -Clause $Clause)
	)
	if ($IsCorrective) {
		return $true
	}
	$IsNegativeVerification = $Clause -cmatch (
		'(?i)^\s*(?:check\s+that|verify)\b.{0,192}?' +
		'\b(?:is|are)\s+(?:rejected|forbidden|disallowed|prevented)\s*$'
	)
	if ($IsNegativeVerification) {
		return $true
	}
	$IsHistorical = $Clause -cmatch (
		'(?i)^\s*(?:historical\b|history\b|prior\b|previous\b|old\b|' +
		'earlier\b|reproduce\s+(?:the\s+)?(?:retained\s+)?(?:raw\s+)?evidence\b)'
	)
	if (-not $IsHistorical) {
		return $false
	}
	return -not (Test-DeliverySourceClauseHasActiveDirective -Clause $Clause)
}

function Test-DeliverySourceClauseHasActiveDirective {
	param(
		[Parameter(Mandatory)]
		[string]$Clause
	)

	$DirectiveVerb = '(?:invoke|call|use|pass|include|require|set|cap|specify|' +
		'supply|attach|append|send|provide|assign)'
	return $Clause -cmatch ('(?i)^\s*' + $DirectiveVerb + '\b') -or
		$Clause -cmatch (
			'(?i)\bby\s+(?:invoking|calling|passing|including|requiring|specifying)\b'
		) -or $Clause -cmatch (
			'(?i)\b(?:so|then)\s+' + $DirectiveVerb + '\b'
		) -or $Clause -cmatch (
			'(?i)\b(?:must|shall|required\s+to)\s+' + $DirectiveVerb + '\b'
		) -or $Clause -cmatch (
			'(?i)\brequires?\b.{0,96}?\b' + $DirectiveVerb + '\b'
		)
}

function Test-DeliveryLooksLikeSourceCallObject {
	param(
		[AllowNull()]
		[object]$Value
	)

	if ($Value -is [pscustomobject]) {
		$ToolProperty = @($Value.PSObject.Properties | Where-Object {
			$_.Name -ieq 'tool'
		})
		return $ToolProperty.Count -eq 1 -and
			$ToolProperty[0].Value -is [string] -and
			[string]$ToolProperty[0].Value -ieq 'read_allowed_source_file'
	}
	if ($Value -is [System.Collections.IDictionary]) {
		$ToolKeys = @($Value.Keys | Where-Object { [string]$_ -ieq 'tool' })
		return $ToolKeys.Count -eq 1 -and
			$Value[$ToolKeys[0]] -is [string] -and
			[string]$Value[$ToolKeys[0]] -ieq 'read_allowed_source_file'
	}
	return $false
}

function Test-DeliverySourceCallObjectIsCanonical {
	param(
		[Parameter(Mandatory)]
		[object]$Value
	)

	if ($Value -is [pscustomobject]) {
		$Names = [string[]]@($Value.PSObject.Properties.Name)
		if ($Names.Count -ne 2 -or $Names -cnotcontains 'tool' -or
			$Names -cnotcontains 'arguments' -or
			$Value.tool -isnot [string] -or
			$Value.tool -cne 'read_allowed_source_file' -or
			$Value.arguments -isnot [pscustomobject]) {
			return $false
		}
		$ArgumentNames = [string[]]@($Value.arguments.PSObject.Properties.Name)
		$PathValue = $Value.arguments.path
		$OffsetValue = $Value.arguments.offset_bytes
	}
	elseif ($Value -is [System.Collections.IDictionary]) {
		$Names = [string[]]@($Value.Keys | ForEach-Object { [string]$_ })
		if ($Names.Count -ne 2 -or $Names -cnotcontains 'tool' -or
			$Names -cnotcontains 'arguments' -or
			$Value['tool'] -isnot [string] -or
			$Value['tool'] -cne 'read_allowed_source_file' -or
			$Value['arguments'] -isnot [System.Collections.IDictionary]) {
			return $false
		}
		$ArgumentNames = [string[]]@(
			$Value['arguments'].Keys | ForEach-Object { [string]$_ }
		)
		$PathValue = $Value['arguments']['path']
		$OffsetValue = $Value['arguments']['offset_bytes']
	}
	else {
		return $false
	}

	if ($ArgumentNames.Count -ne 2 -or
		$ArgumentNames -cnotcontains 'path' -or
		$ArgumentNames -cnotcontains 'offset_bytes' -or
		$PathValue -isnot [string] -or
		[string]::IsNullOrWhiteSpace([string]$PathValue) -or
		-not (Test-JsonInteger -Value $OffsetValue)) {
		return $false
	}
	try {
		$Offset = [long]$OffsetValue
	}
	catch {
		return $false
	}
	return $Offset -ge 0
}

function Test-DeliverySourceClauseEstablishesContext {
	param(
		[Parameter(Mandatory)]
		[string]$Clause
	)

	if ((Test-DeliverySourceClauseIsHistoricalOrCorrective -Clause $Clause) -or
		-not (Test-DeliveryContainsExactSourceTool -Value $Clause)) {
		return $false
	}
	return (Test-DeliverySourceClauseHasActiveDirective -Clause $Clause) -or
		$Clause -cmatch '(?i)^\s*(?:inspect|use)\b' -or
		$Clause -cmatch (
		'(?i)(?<![A-Za-z0-9_])read_allowed_source_file\s*\('
	)
}

function Test-DeliveryIsExactSourceCallObject {
	param(
		[AllowNull()]
		[object]$Value
	)

	return (Test-DeliveryLooksLikeSourceCallObject -Value $Value) -and
		(Test-DeliverySourceCallObjectIsCanonical -Value $Value)
}

function Test-DeliverySourceInstructionSibling {
	param(
		[Parameter(Mandatory)]
		[string]$Name,

		[AllowNull()]
		[object]$Value
	)

	if ($Name -cmatch '(?i)(?:^|_)(?:evidence|hash|path|baseline)(?:_|$)') {
		return $false
	}
	if ($Name -cmatch '(?i)(?:^|_)(?:instruction|instructions|required_checks)(?:_|$)') {
		return $true
	}
	if ($Value -isnot [string]) {
		return $false
	}
	return [string]$Value -cmatch (
		'(?i)\b(?:must|invok(?:e|es|ed|ing)|call(?:s|ed|ing)?|' +
		'pass(?:es|ed|ing)?|includ(?:e|es|ed|ing)|requir(?:e|es|ed|ing)|' +
		'suppl(?:y|ies|ied|ying)|attach(?:es|ed|ing)?|append(?:s|ed|ing)?|' +
		'send(?:s|ing)?|sent|provid(?:e|es|ed|ing)|assign(?:s|ed|ing)?|' +
		'specif(?:y|ies|ied|ying)|set(?:s|ting)?|use(?:s|d|ing)?)\b'
	)
}

function Test-DeliverySourceRequestMemberListIsCanonical {
	param(
		[Parameter(Mandatory)]
		[AllowEmptyString()]
		[string]$Members
	)

	$MemberList = [regex]::Replace($Members.Trim(), '(?i)^(?:only|exactly)\s+', '')
	$MemberList = [regex]::Split(
		$MemberList,
		'(?i)\s+\b(?:for|in|on|then|until|through|when|while)\b',
		2
	)[0].Trim()
	if ([string]::IsNullOrWhiteSpace($MemberList)) {
		return $false
	}

	$MemberList = [regex]::Replace($MemberList, '(?i),\s*and\s+', ',')
	$MemberList = [regex]::Replace($MemberList, '(?i)\s+and\s+', ',')
	if ($MemberList -cnotmatch (
		'^[A-Za-z_][A-Za-z0-9_-]*' +
		'(?:\s*,\s*[A-Za-z_][A-Za-z0-9_-]*)*$'
	)) {
		return $false
	}

	$Names = [string[]]@($MemberList -csplit '\s*,\s*')
	return $Names.Count -eq 2 -and
		$Names[0] -ceq 'path' -and
		$Names[1] -ceq 'offset_bytes'
}

function Test-DeliverySourceMemberContainerIsCanonical {
	param(
		[AllowNull()]
		[object]$Value
	)

	if ($Value -is [pscustomobject]) {
		$Names = [string[]]@($Value.PSObject.Properties.Name)
	}
	elseif ($Value -is [System.Collections.IDictionary]) {
		$Names = [string[]]@($Value.Keys | ForEach-Object { [string]$_ })
	}
	elseif ($Value -is [System.Collections.IEnumerable] -and
		$Value -isnot [string]) {
		$Names = [string[]]@($Value)
	}
	else {
		return $false
	}

	return $Names.Count -eq 2 -and
		$Names[0] -ceq 'path' -and
		$Names[1] -ceq 'offset_bytes'
}

function Get-DeliveryExplicitRequestMembers {
	param(
		[Parameter(Mandatory)]
		[string]$Clause,

		[bool]$SourceContext = $false
	)

	$Clause = [regex]::Replace(
		$Clause,
		'(`+)(?<content>[^`\r\n]+)\1',
		'${content}'
	)
	$ExactTool = '(?<![A-Za-z0-9_])read_allowed_source_file(?![A-Za-z0-9_])'
	$HasExactTool = $Clause -cmatch $ExactTool
	if (-not $SourceContext -and -not $HasExactTool) {
		return @()
	}
	$InvalidEnumeration = '__invalid_source_request_enumeration__'
	if (($SourceContext -or $HasExactTool) -and $Clause -cmatch (
		'(?i)^\s*(?:(?:do\s+not|never)\s+' +
		'(?:pass|include|send|set|add|use|supply|attach|append)\s+' +
		'(?:the\s+)?(?:path|offset_bytes)\b|' +
		'no\s+(?:source\s+)?(?:calls?|requests?|invocations?)\s+' +
		'(?:with|using|containing|including)\s+(?:path|offset_bytes)\b)'
	)) {
		return @($InvalidEnumeration)
	}
	$MemberToken = '(?:path|[a-z][a-z0-9]*_[a-z0-9_]+|' +
		'[a-z]+(?:Bytes|Seconds|Offset|Limit|Size|Token))'
	foreach ($Enumeration in [regex]::Matches(
		$Clause,
		'(?-i)(?<members>' + $MemberToken +
		'(?:\s*(?:,\s*(?:and\s+)?|\s+and\s+)' + $MemberToken + ')+)'
	)) {
		if (-not (Test-DeliverySourceRequestMemberListIsCanonical `
				-Members ([string]$Enumeration.Groups['members'].Value))) {
			return @($InvalidEnumeration)
		}
	}

	foreach ($Signature in [regex]::Matches(
		$Clause,
		'(?i)' + $ExactTool + '\s*\((?<members>[^)]*)\)'
	)) {
		$SignatureMembers = [string]$Signature.Groups['members'].Value
		if ($SignatureMembers -cnotmatch '^\s*path\s*,\s*offset_bytes\s*$') {
			return @($InvalidEnumeration)
		}
	}

	$ExplicitListPatterns = @(
		('(?i)^\s*(?:pass|include|require|provide|send|supply|attach|append|' +
			'assign|set|add|specify)\s+(?<members>[^.;\r\n()]*?)\s+' +
			'(?:to|for|on)\s+(?:the\s+)?' + $ExactTool + '\b'),
		('(?i)' + $ExactTool + '\s+(?:with|using)\s+' +
			'(?:(?:arguments?|members?|fields?)\s*(?::|=|\bare\b)?\s*)?' +
			'(?<members>[^.;\r\n()]*)'),
		('(?i)' + $ExactTool + '\s+(?:arguments?|members?|fields?)\s*' +
			'(?::|=|\bare\b)?\s*(?<members>[^.;\r\n()]*)'),
		('(?i)' + $ExactTool + '\s+(?:requests?|calls?|invocations?|inputs?)\b' +
			'.{0,64}?\b(?:include|contain|send|pass|provide|require|use|with|specify|' +
			'using|set|accept|add|supply|attach|append)\b' +
			'(?<members>[^.;\r\n()]*)')
	)
	if ($SourceContext -and -not $HasExactTool) {
		$ExplicitListPatterns += @(
			('(?i)\b(?:requests?|calls?|invocations?|inputs?|arguments?|members?|fields?)\b' +
			'.{0,64}?\b(?:include|contain|send|pass|provide|require|use|with|specify|' +
			'using|set|accept|add|supply|attach|append)\b' +
			'(?<members>[^.;\r\n()]*)'),
			('(?i)^\s*(?:pass|include|require|provide|send|supply|attach|append)\b' +
			'(?<members>[^.;\r\n()]*)')
		)
	}
	foreach ($Pattern in $ExplicitListPatterns) {
		foreach ($Enumeration in [regex]::Matches($Clause, $Pattern)) {
			$EnumerationMembers = [string]$Enumeration.Groups['members'].Value
			if (-not (Test-DeliverySourceRequestMemberListIsCanonical `
					-Members $EnumerationMembers)) {
				return @($InvalidEnumeration)
			}
		}
	}

	$Segments = [System.Collections.Generic.List[string]]::new()
	foreach ($Signature in [regex]::Matches(
		$Clause,
		'(?i)' + $ExactTool + '\s*\((?<members>[^)]*)\)'
	)) {
		$Segments.Add([string]$Signature.Groups['members'].Value)
	}
	foreach ($Request in [regex]::Matches(
		$Clause,
		'(?i)(?:(?:' + $ExactTool + ').{0,96})?' +
		'\b(?:requests?|calls?|invocations?|inputs?|arguments?)\b.{0,96}?' +
		'\b(?:must\s+)?(?:include|contain|send|pass|provide|require|use|' +
		'with|set|accept|add|supply|attach|append)\b(?<members>[^.;\r\n]*)'
	)) {
		$Segments.Add([string]$Request.Groups['members'].Value)
	}
	if ($HasExactTool) {
		foreach ($Direct in [regex]::Matches(
			$Clause,
			'(?i)' + $ExactTool + '.{0,96}?' +
			'\b(?:include|contain|send|pass|provide|require|use|with|specify|' +
			'specifying|set|' +
			'accept|add|supply|attach|append)\b(?<members>[^.;\r\n]*)'
		)) {
			$Segments.Add([string]$Direct.Groups['members'].Value)
		}
	}
	if ($SourceContext) {
		$HasScopedMemberDirective = $false
		foreach ($MemberDirective in [regex]::Matches(
			$Clause,
			'(?i)^\s*(?:then\s+)?' +
			'(?:set|assign|add|include|pass|require|use)\s+' +
			'(?:only\s+)?' +
			'(?:(?:the|a|an)\s+)?' +
			'(?<member>[A-Za-z_][A-Za-z0-9_-]*)\b' +
			'[^.;\r\n]*?\b(?:every|each)\s+' +
			'(?:source\s+)?(?:call|request)s?\b'
		)) {
			$HasScopedMemberDirective = $true
			$MemberName = [string]$MemberDirective.Groups['member'].Value
			if ($MemberName -cnotin @('path', 'offset_bytes')) {
				return @($MemberName)
			}
		}
		if (-not $HasScopedMemberDirective) {
			foreach ($Direct in [regex]::Matches(
				$Clause,
				'(?i)\b(?:invok(?:e|es|ed|ing)|call(?:s|ed|ing)?|' +
				'pass(?:es|ed|ing)?|includ(?:e|es|ed|ing)|' +
				'requir(?:e|es|ed|ing))\b' +
				'(?<members>[^.;\r\n]*)'
			)) {
				$Segments.Add([string]$Direct.Groups['members'].Value)
			}
		}
	}

	$Members = [System.Collections.Generic.List[string]]::new()
	foreach ($Segment in $Segments) {
		$RequestMembers = [regex]::Split(
			$Segment,
			'(?i)\b(?:then|until|through)\b'
		)[0]
		foreach ($Identifier in [regex]::Matches(
			$RequestMembers,
			'(?-i)(?<![A-Za-z0-9_])(?:[a-z][a-z0-9]*_[a-z0-9_]+|' +
			'[a-z]+(?:Bytes|Seconds|Offset|Limit|Size|Token))(?![A-Za-z0-9_])'
		)) {
			$Name = [string]$Identifier.Value
			if ($Name -cnotin @('read_allowed_source_file', 'offset_bytes')) {
				$Members.Add($Name)
			}
		}
	}
	return [string[]]@($Members)
}

function Test-DeliveryContainsUnsupportedSourceArgument {
	param(
		[AllowNull()]
		[object]$Value,

		[bool]$SourceContext = $false
	)

	if ($null -eq $Value) {
		return $false
	}
	if ($Value -is [string]) {
		$ClauseSourceContext = $SourceContext
		foreach ($Clause in ([string]$Value -csplit '[.;\r\n]+')) {
			if ([string]::IsNullOrWhiteSpace($Clause) -or
				(Test-DeliverySourceClauseIsHistoricalOrCorrective -Clause $Clause)) {
				continue
			}
			$ClauseHasExactTool = Test-DeliveryContainsExactSourceTool -Value $Clause
			if (($ClauseSourceContext -or $ClauseHasExactTool) -and
				$Clause -cmatch `
				'(?i)(?<![A-Za-z0-9_])limit_bytes\s*:\s*2048(?![0-9])') {
				return $true
			}
			if (($ClauseSourceContext -or $ClauseHasExactTool) -and
				$Clause -cmatch (
					'(?i)\b(?:cap|limit|restrict|keep)\b.{0,64}?' +
					'\b(?:each|every)\s+(?:source\s+)?' +
					'(?:call|request|page|read)s?\b.{0,48}?' +
					'\b(?:[0-9]+\s*)?(?:bytes?|kilobytes?|kib|kb)\b'
				)) {
				return $true
			}
			if (@(Get-DeliveryExplicitRequestMembers `
					-Clause $Clause `
					-SourceContext ($ClauseSourceContext -or $ClauseHasExactTool)).Count -gt 0) {
				return $true
			}
			if (Test-DeliverySourceClauseEstablishesContext -Clause $Clause) {
				$ClauseSourceContext = $true
			}
		}
		return $false
	}
	if ($Value -is [pscustomobject]) {
		if (Test-DeliveryLooksLikeSourceCallObject -Value $Value) {
			return -not (Test-DeliverySourceCallObjectIsCanonical -Value $Value)
		}
		$ContainsExactSourceCall = @($Value.PSObject.Properties | Where-Object {
			Test-DeliveryIsExactSourceCallObject -Value $_.Value
		}).Count -gt 0
		foreach ($Property in $Value.PSObject.Properties) {
			if (($SourceContext -or $ContainsExactSourceCall) -and
				$Property.Name -cmatch `
				'(?i)(?:^|_)(?:request_)?(?:arguments|members|fields)(?:_|$)' -and
				-not (Test-DeliverySourceMemberContainerIsCanonical `
					-Value $Property.Value)) {
				return $true
			}
			$PropertySourceContext = ($SourceContext -or $ContainsExactSourceCall) -and
				(Test-DeliverySourceInstructionSibling `
					-Name $Property.Name -Value $Property.Value)
			if (Test-DeliveryContainsUnsupportedSourceArgument `
					-Value $Property.Value -SourceContext $PropertySourceContext) {
				return $true
			}
		}
		return $false
	}
	if ($Value -is [System.Collections.IDictionary]) {
		if (Test-DeliveryLooksLikeSourceCallObject -Value $Value) {
			return -not (Test-DeliverySourceCallObjectIsCanonical -Value $Value)
		}
		$ContainsExactSourceCall = @($Value.Keys | Where-Object {
			Test-DeliveryIsExactSourceCallObject -Value $Value[$_]
		}).Count -gt 0
		foreach ($Key in $Value.Keys) {
			if (($SourceContext -or $ContainsExactSourceCall) -and
				[string]$Key -cmatch `
				'(?i)(?:^|_)(?:request_)?(?:arguments|members|fields)(?:_|$)' -and
				-not (Test-DeliverySourceMemberContainerIsCanonical `
					-Value $Value[$Key])) {
				return $true
			}
			$PropertySourceContext = ($SourceContext -or $ContainsExactSourceCall) -and
				(Test-DeliverySourceInstructionSibling `
					-Name ([string]$Key) -Value $Value[$Key])
			if (Test-DeliveryContainsUnsupportedSourceArgument `
					-Value $Value[$Key] -SourceContext $PropertySourceContext) {
				return $true
			}
		}
		return $false
	}
	if ($Value -is [System.Collections.IEnumerable]) {
		foreach ($Entry in $Value) {
			if (Test-DeliveryContainsUnsupportedSourceArgument `
					-Value $Entry -SourceContext $SourceContext) {
				return $true
			}
		}
	}
	return $false
}

function Test-DeliveryEstablishesCanonicalSourceContext {
	param(
		[AllowNull()]
		[object]$Value
	)

	if ($null -eq $Value) {
		return $false
	}
	if ($Value -is [string]) {
		foreach ($Clause in ([string]$Value -csplit '[.;\r\n]+')) {
			if (-not [string]::IsNullOrWhiteSpace($Clause) -and
				(Test-DeliverySourceClauseEstablishesContext -Clause $Clause)) {
				return $true
			}
		}
		return $false
	}
	if ($Value -is [pscustomobject]) {
		if ((Test-DeliveryLooksLikeSourceCallObject -Value $Value) -and
			(Test-DeliverySourceCallObjectIsCanonical -Value $Value)) {
			return $true
		}
		foreach ($Property in $Value.PSObject.Properties) {
			if (Test-DeliveryEstablishesCanonicalSourceContext -Value $Property.Value) {
				return $true
			}
		}
		return $false
	}
	if ($Value -is [System.Collections.IDictionary]) {
		if ((Test-DeliveryLooksLikeSourceCallObject -Value $Value) -and
			(Test-DeliverySourceCallObjectIsCanonical -Value $Value)) {
			return $true
		}
		foreach ($Key in $Value.Keys) {
			if (Test-DeliveryEstablishesCanonicalSourceContext -Value $Value[$Key]) {
				return $true
			}
		}
		return $false
	}
	if ($Value -is [System.Collections.IEnumerable]) {
		foreach ($Entry in $Value) {
			if (Test-DeliveryEstablishesCanonicalSourceContext -Value $Entry) {
				return $true
			}
		}
	}
	return $false
}

function Assert-DeliverySourceInspectionProtocol {
	param(
		[Parameter(Mandatory)][object]$Handoff,
		[Parameter(Mandatory)][string]$Stage,
		[Parameter(Mandatory)][object]$ProtocolSchema
	)

	$ProducerStages = @('worker', 'integrator', 'fixer')
	if ($ProducerStages -cnotcontains $Stage) {
		return
	}

	# Ticket and acceptance criteria are task evidence. They do not instruct the
	# producer and therefore cannot establish source-tool context for other fields.
	$CommonOperationalFields = @('output_contract')
	$StageOperationalFields = switch ($Stage) {
		'worker' {
			@('work_package', 'non_goals', 'required_checks')
		}
		'integrator' {
			@('integration_order', 'non_goals', 'required_checks')
		}
		'fixer' {
			@('accepted_findings', 'non_goals', 'required_checks')
		}
	}
	$OperationalFields = @($CommonOperationalFields) + @($StageOperationalFields)
	$HandoffNames = Get-PropertyNames -Value $Handoff
	$SourceContext = $false
	foreach ($FieldName in $OperationalFields) {
		$FieldEstablishesSourceContext = $HandoffNames -ccontains $FieldName -and
			(Test-DeliveryEstablishesCanonicalSourceContext `
				-Value $Handoff.$FieldName)
		$FieldSourceContext = $SourceContext -or $FieldEstablishesSourceContext
		if ($HandoffNames -ccontains $FieldName -and
			(Test-DeliveryContainsUnsupportedSourceArgument `
				-Value $Handoff.$FieldName `
				-SourceContext $FieldSourceContext)) {
			throw (
				'[source_protocol_invalid] source_inspection_protocol operational instructions ' +
				'contain an unsupported source-reader request member.'
			)
		}
		if ($FieldEstablishesSourceContext) {
			$SourceContext = $true
		}
	}

	if ($HandoffNames -cnotcontains 'source_inspection_protocol') {
		return
	}
	$Protocol = $Handoff.source_inspection_protocol
	try {
		Assert-ClosedObject `
			-Name 'source_inspection_protocol' `
			-Value $Protocol `
			-AllowedNames @($ProtocolSchema.allowed)
	}
	catch {
		throw '[source_protocol_invalid] source_inspection_protocol contains unsupported members.'
	}
	$ProtocolNames = Get-PropertyNames -Value $Protocol
	foreach ($RequiredName in @($ProtocolSchema.allowed)) {
		if ($ProtocolNames -cnotcontains $RequiredName) {
			throw '[source_protocol_invalid] source_inspection_protocol is incomplete.'
		}
	}

	$Arguments = $Protocol.request_arguments
	$ArgumentsValid = (
		$Arguments -is [System.Array] -and
		@($Arguments).Count -eq 2 -and
		$Arguments[0] -is [string] -and $Arguments[0] -ceq 'path' -and
		$Arguments[1] -is [string] -and $Arguments[1] -ceq 'offset_bytes'
	)
	$ScalarValuesValid = (
		(Test-JsonInteger -Value $Protocol.schema_version) -and
		[long]$Protocol.schema_version -eq [long]$ProtocolSchema.schema_version -and
		$Protocol.tool -is [string] -and $Protocol.tool -ceq [string]$ProtocolSchema.tool -and
		$Protocol.path_source -is [string] -and
		$Protocol.path_source -ceq [string]$ProtocolSchema.path_source -and
		(Test-JsonInteger -Value $Protocol.initial_offset_bytes) -and
		[long]$Protocol.initial_offset_bytes -eq [long]$ProtocolSchema.initial_offset_bytes -and
		$Protocol.next_offset_field -is [string] -and
		$Protocol.next_offset_field -ceq [string]$ProtocolSchema.next_offset_field -and
		$Protocol.completion_field -is [string] -and
		$Protocol.completion_field -ceq [string]$ProtocolSchema.completion_field -and
		(Test-JsonInteger -Value $Protocol.maximum_page_bytes) -and
		[long]$Protocol.maximum_page_bytes -eq [long]$ProtocolSchema.maximum_page_bytes
	)
	if (-not $ArgumentsValid -or -not $ScalarValuesValid) {
		throw '[source_protocol_invalid] source_inspection_protocol does not match the supported runtime contract.'
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

		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[System.Collections.Generic.List[object]]
		$ValidatedEntries,

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
			$null = $ValidatedEntries.Add([pscustomobject]@{
				FieldName = $FieldName
				Record = $Record
			})
		}
	}
}

function Assert-RequiredNeutralEvidencePresence {
	param(
		[Parameter(Mandatory)][object]$Handoff,
		[Parameter(Mandatory)][object]$FieldMappings,
		[Parameter(Mandatory)][string[]]$RequiredNames
	)

	$PropertyNames = @(Get-PropertyNames -Value $Handoff)
	foreach ($Mapping in $FieldMappings.PSObject.Properties) {
		$FieldName = $Mapping.Name
		if ($RequiredNames -cnotcontains $FieldName) {
			continue
		}

		$Parts = @(([string]$Mapping.Value).Split(':'))
		if ($Parts.Count -ne 3 -or
			@('single', 'array') -cnotcontains $Parts[0]) {
			Throw-NeutralEvidenceError -FieldName $FieldName `
				-Code 'neutral_evidence_field_contract_invalid'
		}

		if ($PropertyNames -cnotcontains $FieldName) {
			$Code = if ($Parts[0] -ceq 'single') {
				'neutral_evidence_record_required'
			}
			else {
				'neutral_evidence_array_required'
			}
			Throw-NeutralEvidenceError -FieldName $FieldName -Code $Code
		}

		$Value = $Handoff.($FieldName)
		if ($Parts[0] -ceq 'single' -and
			$Value -isnot [System.Management.Automation.PSCustomObject]) {
			Throw-NeutralEvidenceError -FieldName $FieldName `
				-Code 'neutral_evidence_record_required'
		}
		if ($Parts[0] -ceq 'array' -and
			($Value -isnot [System.Array] -or @($Value).Count -eq 0)) {
			Throw-NeutralEvidenceError -FieldName $FieldName `
				-Code 'neutral_evidence_array_required'
		}
	}
}

function Throw-RequiredEvidenceError {
	param(
		[Parameter(Mandatory)][string]$FieldName,
		[Parameter(Mandatory)][string]$Code
	)

	throw "Required evidence field '$FieldName' failed validation: $Code."
}

function Test-ExactPropertySet {
	param(
		[AllowNull()][object]$Value,
		[Parameter(Mandatory)][string[]]$ExpectedNames
	)

	if ($null -eq $Value -or
		$Value -isnot [System.Management.Automation.PSCustomObject]) {
		return $false
	}

	$ActualNames = @(Get-PropertyNames -Value $Value)
	if ($ActualNames.Count -ne $ExpectedNames.Count) {
		return $false
	}
	foreach ($ExpectedName in $ExpectedNames) {
		if ($ActualNames -cnotcontains $ExpectedName) {
			return $false
		}
	}

	return $true
}

function Get-EvidenceIdentityKey {
	param(
		[Parameter(Mandatory)][string]$FieldName,
		[Parameter(Mandatory)][string]$Source
	)

	return [string]::Concat($FieldName, [char]0, $Source)
}

function Assert-AuthoritativeEvidenceManifest {
	param(
		[Parameter(Mandatory)]
		[AllowNull()]
		[AllowEmptyCollection()]
		[byte[]]$Bytes,

		[Parameter(Mandatory)]
		[AllowNull()]
		[AllowEmptyString()]
		[string]$ExpectedSha256,

		[Parameter(Mandatory)][string]$Stage,
		[Parameter(Mandatory)][object]$StageSchema,
		[Parameter(Mandatory)][object]$Schema
	)

	$ManifestField = 'authoritative_evidence_manifest'
	if ($null -eq $Bytes -or $Bytes.Count -eq 0 -or
		[string]::IsNullOrWhiteSpace($ExpectedSha256)) {
		Throw-RequiredEvidenceError -FieldName $ManifestField `
			-Code 'authoritative_evidence_manifest_required'
	}
	if ($ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$') {
		Throw-RequiredEvidenceError -FieldName $ManifestField `
			-Code 'authoritative_evidence_manifest_malformed'
	}

	$ComputedHash = Get-NeutralEvidenceHash -Bytes $Bytes
	if ($ComputedHash -cne $ExpectedSha256) {
		Throw-RequiredEvidenceError -FieldName $ManifestField `
			-Code 'authoritative_evidence_manifest_hash_mismatch'
	}

	try {
		$StrictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
		$ManifestJson = $StrictUtf8.GetString($Bytes)
	}
	catch [System.Text.DecoderFallbackException] {
		Throw-RequiredEvidenceError -FieldName $ManifestField `
			-Code 'authoritative_evidence_manifest_malformed'
	}
	if ($ManifestJson.Length -gt 0 -and
		$ManifestJson[0] -eq [char]0xfeff) {
		$ManifestJson = $ManifestJson.Substring(1)
	}

	try {
		Assert-StrictHandoffJson -Json $ManifestJson `
			-DocumentKind 'authoritative_evidence_manifest'
		$Manifest = $ManifestJson | ConvertFrom-Json
	}
	catch {
		if ($_.Exception.Message.IndexOf(
			'required_evidence_json_member_duplicate',
			[System.StringComparison]::Ordinal
		) -ge 0) {
			throw
		}
		Throw-RequiredEvidenceError -FieldName $ManifestField `
			-Code 'authoritative_evidence_manifest_malformed'
	}

	$ManifestSchema = $Schema.authoritative_evidence_manifest_schema
	$RootNames = [string[]]@($ManifestSchema.root_fields)
	if (-not (Test-ExactPropertySet -Value $Manifest -ExpectedNames $RootNames) -or
		$Manifest.format -isnot [string] -or
		$Manifest.format -cne $ManifestSchema.format -or
		$Manifest.stage -isnot [string] -or
		@($ManifestSchema.stages) -cnotcontains $Manifest.stage -or
		$Manifest.stage -cne $Stage -or
		$Manifest.records -isnot [System.Array] -or
		@($Manifest.records).Count -lt [int]$ManifestSchema.records_minimum) {
		Throw-RequiredEvidenceError -FieldName $ManifestField `
			-Code 'authoritative_evidence_manifest_malformed'
	}

	$ExpectedRecordNames = [string[]]@($ManifestSchema.record_fields)
	$IdentityKeys = [System.Collections.Generic.HashSet[string]]::new(
		[System.StringComparer]::Ordinal
	)
	foreach ($Record in @($Manifest.records)) {
		if (-not (Test-ExactPropertySet `
			-Value $Record `
			-ExpectedNames $ExpectedRecordNames)) {
			Throw-RequiredEvidenceError -FieldName $ManifestField `
				-Code 'authoritative_evidence_manifest_malformed'
		}

		if ($Record.field -isnot [string]) {
			Throw-RequiredEvidenceError -FieldName $ManifestField `
				-Code 'authoritative_evidence_manifest_malformed'
		}
		$Mappings = @(
			$StageSchema.neutral_evidence_fields.PSObject.Properties |
				Where-Object { $_.Name -ceq $Record.field }
		)
		if ($Mappings.Count -ne 1) {
			Throw-RequiredEvidenceError -FieldName $ManifestField `
				-Code 'authoritative_evidence_manifest_malformed'
		}

		$Parts = @(([string]$Mappings[0].Value).Split(':'))
		if ($Parts.Count -ne 3) {
			Throw-RequiredEvidenceError -FieldName $ManifestField `
				-Code 'authoritative_evidence_manifest_malformed'
		}
		$AllowedKinds = @($Parts[1].Split('|'))
		$AllowedProvenances = @($Parts[2].Split('|'))
		if ($Record.kind -isnot [string] -or
			@($Schema.neutral_evidence_schema.kinds) -cnotcontains $Record.kind -or
			$AllowedKinds -cnotcontains $Record.kind -or
			$Record.provenance -isnot [string] -or
			@($Schema.neutral_evidence_schema.provenances) -cnotcontains $Record.provenance -or
			$AllowedProvenances -cnotcontains $Record.provenance -or
			$Record.encoding -isnot [string] -or
			@($Schema.neutral_evidence_schema.encodings) -cnotcontains $Record.encoding -or
			$Record.source -isnot [string] -or
			[string]::IsNullOrWhiteSpace($Record.source) -or
			$Record.sha256 -isnot [string] -or
			$Record.sha256 -cnotmatch '^[0-9a-f]{64}$') {
			Throw-RequiredEvidenceError -FieldName $ManifestField `
				-Code 'authoritative_evidence_manifest_malformed'
		}

		$IdentityKey = Get-EvidenceIdentityKey `
			-FieldName $Record.field `
			-Source $Record.source
		if (-not $IdentityKeys.Add($IdentityKey)) {
			Throw-RequiredEvidenceError -FieldName $Record.field `
				-Code 'authoritative_evidence_source_duplicate'
		}
	}

	return [pscustomobject]@{
		Hash = $ComputedHash
		Records = [object[]]@($Manifest.records)
	}
}

function Assert-RequiredEvidenceSourcesPresence {
	param([Parameter(Mandatory)][object]$Handoff)

	$PropertyNames = @(Get-PropertyNames -Value $Handoff)
	if ($PropertyNames -cnotcontains 'required_evidence_sources' -or
		$Handoff.required_evidence_sources -isnot [System.Array] -or
		@($Handoff.required_evidence_sources).Count -eq 0) {
		Throw-RequiredEvidenceError -FieldName 'required_evidence_sources' `
			-Code 'required_evidence_declarations_malformed'
	}
}

function Assert-RequiredRoutedEvidencePresence {
	param(
		[Parameter(Mandatory)][object]$Handoff,
		[Parameter(Mandatory)][object]$FieldMappings,
		[Parameter(Mandatory)][string[]]$RequiredNames
	)

	$PropertyNames = @(Get-PropertyNames -Value $Handoff)
	foreach ($Mapping in $FieldMappings.PSObject.Properties) {
		$FieldName = $Mapping.Name
		if ($RequiredNames -cnotcontains $FieldName) {
			continue
		}

		$Parts = @(([string]$Mapping.Value).Split(':'))
		if ($Parts.Count -ne 3 -or
			@('single', 'array') -cnotcontains $Parts[0] -or
			$PropertyNames -cnotcontains $FieldName) {
			Throw-RequiredEvidenceError -FieldName $FieldName `
				-Code 'required_evidence_routed_record_malformed'
		}

		$Value = $Handoff.($FieldName)
		if (($Parts[0] -ceq 'single' -and
			$Value -isnot [System.Management.Automation.PSCustomObject]) -or
			($Parts[0] -ceq 'array' -and
			($Value -isnot [System.Array] -or @($Value).Count -eq 0))) {
			Throw-RequiredEvidenceError -FieldName $FieldName `
				-Code 'required_evidence_routed_record_malformed'
		}
	}
}

function Assert-RequiredEvidenceComposition {
	param(
		[Parameter(Mandatory)][object]$Handoff,
		[Parameter(Mandatory)][object]$DeclarationSchema,
		[Parameter(Mandatory)][object]$StageSchema,
		[Parameter(Mandatory)][object]$NeutralSchema,
		[Parameter(Mandatory)][object[]]$ManifestRecords,
		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[System.Collections.Generic.List[object]]$ValidatedEntries
	)

	$Declarations = @($Handoff.required_evidence_sources)
	$ExpectedNames = [string[]]@($DeclarationSchema.record_fields)
	$DeclarationKeys = [System.Collections.Generic.HashSet[string]]::new(
		[System.StringComparer]::Ordinal
	)

	foreach ($Declaration in $Declarations) {
		if (-not (Test-ExactPropertySet `
			-Value $Declaration `
			-ExpectedNames $ExpectedNames) -or
			$Declaration.field -isnot [string]) {
			Throw-RequiredEvidenceError -FieldName 'required_evidence_sources' `
				-Code 'required_evidence_declarations_malformed'
		}

		$Mappings = @(
			$StageSchema.neutral_evidence_fields.PSObject.Properties |
				Where-Object { $_.Name -ceq $Declaration.field }
		)
		if ($Mappings.Count -ne 1) {
			Throw-RequiredEvidenceError -FieldName 'required_evidence_sources' `
				-Code 'required_evidence_declarations_malformed'
		}

		$Parts = @(([string]$Mappings[0].Value).Split(':'))
		if ($Parts.Count -ne 3) {
			Throw-RequiredEvidenceError -FieldName 'required_evidence_sources' `
				-Code 'required_evidence_declarations_malformed'
		}
		$AllowedKinds = @($Parts[1].Split('|'))
		$AllowedProvenances = @($Parts[2].Split('|'))
		if ($Declaration.kind -isnot [string] -or
			@($NeutralSchema.kinds) -cnotcontains $Declaration.kind -or
			$AllowedKinds -cnotcontains $Declaration.kind -or
			$Declaration.provenance -isnot [string] -or
			@($NeutralSchema.provenances) -cnotcontains $Declaration.provenance -or
			$AllowedProvenances -cnotcontains $Declaration.provenance -or
			$Declaration.encoding -isnot [string] -or
			@($NeutralSchema.encodings) -cnotcontains $Declaration.encoding -or
			$Declaration.source -isnot [string] -or
			[string]::IsNullOrWhiteSpace($Declaration.source) -or
			$Declaration.sha256 -isnot [string] -or
			$Declaration.sha256 -cnotmatch '^[0-9a-f]{64}$') {
			Throw-RequiredEvidenceError -FieldName 'required_evidence_sources' `
				-Code 'required_evidence_declarations_malformed'
		}

		$IdentityKey = Get-EvidenceIdentityKey `
			-FieldName $Declaration.field `
			-Source $Declaration.source
		if (-not $DeclarationKeys.Add($IdentityKey)) {
			Throw-RequiredEvidenceError -FieldName 'required_evidence_sources' `
				-Code 'required_evidence_declaration_duplicate'
		}
	}

	$RoutedKeys = [System.Collections.Generic.HashSet[string]]::new(
		[System.StringComparer]::Ordinal
	)
	foreach ($Entry in $ValidatedEntries) {
		$IdentityKey = Get-EvidenceIdentityKey `
			-FieldName $Entry.FieldName `
			-Source $Entry.Record.source
		if (-not $RoutedKeys.Add($IdentityKey)) {
			Throw-RequiredEvidenceError -FieldName $Entry.FieldName `
				-Code 'required_evidence_routed_record_duplicate'
		}
	}

	foreach ($Declaration in $Declarations) {
		$MatchingManifest = @($ManifestRecords | Where-Object {
			$_.field -ceq $Declaration.field -and
			$_.source -ceq $Declaration.source
		})
		if ($MatchingManifest.Count -ne 1) {
			Throw-RequiredEvidenceError -FieldName $Declaration.field `
				-Code 'required_evidence_composition_mismatch'
		}
	}
	foreach ($Entry in $ValidatedEntries) {
		$MatchingManifest = @($ManifestRecords | Where-Object {
			$_.field -ceq $Entry.FieldName -and
			$_.source -ceq $Entry.Record.source
		})
		if ($MatchingManifest.Count -ne 1) {
			Throw-RequiredEvidenceError -FieldName $Entry.FieldName `
				-Code 'required_evidence_composition_mismatch'
		}
	}

	foreach ($ManifestRecord in $ManifestRecords) {
		$MatchingDeclarations = @($Declarations | Where-Object {
			$_.field -ceq $ManifestRecord.field -and
			$_.source -ceq $ManifestRecord.source
		})
		$MatchingEntries = @($ValidatedEntries | Where-Object {
			$_.FieldName -ceq $ManifestRecord.field -and
			$_.Record.source -ceq $ManifestRecord.source
		})
		if ($MatchingDeclarations.Count -ne 1 -or
			$MatchingEntries.Count -ne 1) {
			Throw-RequiredEvidenceError -FieldName $ManifestRecord.field `
				-Code 'required_evidence_composition_mismatch'
		}

		$Declaration = $MatchingDeclarations[0]
		foreach ($Name in @('field', 'kind', 'provenance', 'encoding', 'source', 'sha256')) {
			if ($Declaration.($Name) -cne $ManifestRecord.($Name)) {
				Throw-RequiredEvidenceError -FieldName $ManifestRecord.field `
					-Code 'required_evidence_composition_mismatch'
			}
		}

		$Entry = $MatchingEntries[0]
		if ($Entry.FieldName -cne $ManifestRecord.field) {
			Throw-RequiredEvidenceError -FieldName $ManifestRecord.field `
				-Code 'required_evidence_composition_mismatch'
		}
		foreach ($Name in @('kind', 'provenance', 'encoding', 'source', 'sha256')) {
			if ($Entry.Record.($Name) -cne $ManifestRecord.($Name)) {
				Throw-RequiredEvidenceError -FieldName $ManifestRecord.field `
					-Code 'required_evidence_composition_mismatch'
			}
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
$Schema = Get-Content -Raw -LiteralPath $ResolvedSchemaPath | ConvertFrom-Json
$RelevantEvidenceFields = [System.Collections.Generic.HashSet[string]]::new(
	[System.StringComparer]::Ordinal
)
foreach ($SchemaStage in $Schema.stages.PSObject.Properties) {
	if ($null -eq $SchemaStage.Value.neutral_evidence_fields) {
		continue
	}
	foreach ($Mapping in $SchemaStage.Value.neutral_evidence_fields.PSObject.Properties) {
		$null = $RelevantEvidenceFields.Add($Mapping.Name)
	}
}

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
Assert-StrictHandoffJson -Json $HandoffJson `
	-RelevantEvidenceFields ([string[]]@($RelevantEvidenceFields))
$Handoff = $HandoffJson | ConvertFrom-Json

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
$ValidatedAuthoritativeEvidenceManifest = $null
if ($StageSchema.PSObject.Properties.Name -ccontains `
	'authoritative_evidence_manifest_required' -and
	$StageSchema.authoritative_evidence_manifest_required -eq $true) {
	$ValidatedAuthoritativeEvidenceManifest = `
		Assert-AuthoritativeEvidenceManifest `
			-Bytes $AuthoritativeEvidenceManifestBytes `
			-ExpectedSha256 $ExpectedAuthoritativeEvidenceManifestSha256 `
			-Stage $Stage `
			-StageSchema $StageSchema `
			-Schema $Schema
}

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

if ($null -ne $ValidatedAuthoritativeEvidenceManifest) {
	Assert-RequiredRoutedEvidencePresence `
		-Handoff $Handoff `
		-FieldMappings $StageSchema.neutral_evidence_fields `
		-RequiredNames ([string[]]$Required)
	Assert-RequiredEvidenceSourcesPresence -Handoff $Handoff
}
elseif ($StageSchema.blind -and
	$null -ne $StageSchema.neutral_evidence_fields) {
	Assert-RequiredNeutralEvidencePresence `
		-Handoff $Handoff `
		-FieldMappings $StageSchema.neutral_evidence_fields `
		-RequiredNames ([string[]]$Required)
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

Assert-DeliverySourceInspectionProtocol `
	-Handoff $Handoff `
	-Stage $Stage `
	-ProtocolSchema $Schema.source_inspection_protocol

if ($Stage -eq 'worker') {
	$WorkerValidatorPath = Join-Path -Path $PSScriptRoot -ChildPath 'Validate-DeliveryWorkerHandoff.ps1'
	& $WorkerValidatorPath -Handoff $Handoff -PropertyNames $PropertyNames
}

if ($StageSchema.blind) {
	$ValidatedNeutralEvidenceRecords = New-Object `
		'System.Collections.Generic.List[object]'
	$ValidatedNeutralEvidenceEntries = New-Object `
		'System.Collections.Generic.List[object]'
	if ($null -ne $StageSchema.neutral_evidence_fields) {
		Assert-NeutralEvidenceFields `
			-Handoff $Handoff `
			-FieldMappings $StageSchema.neutral_evidence_fields `
			-NeutralSchema $Schema.neutral_evidence_schema `
			-ValidatedRecords $ValidatedNeutralEvidenceRecords `
			-ValidatedEntries $ValidatedNeutralEvidenceEntries
	}
	if ($null -ne $ValidatedAuthoritativeEvidenceManifest) {
		Assert-RequiredEvidenceComposition `
			-Handoff $Handoff `
			-DeclarationSchema $Schema.required_evidence_source_schema `
			-StageSchema $StageSchema `
			-NeutralSchema $Schema.neutral_evidence_schema `
			-ManifestRecords $ValidatedAuthoritativeEvidenceManifest.Records `
			-ValidatedEntries $ValidatedNeutralEvidenceEntries
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
	AuthoritativeEvidenceManifestHash = if (
		$null -eq $ValidatedAuthoritativeEvidenceManifest
	) { $null } else { $ValidatedAuthoritativeEvidenceManifest.Hash }
	AuthoritativeEvidenceManifestRecordCount = if (
		$null -eq $ValidatedAuthoritativeEvidenceManifest
	) { 0 } else { @($ValidatedAuthoritativeEvidenceManifest.Records).Count }
	AuthoritativeEvidenceManifestValidated = `
		$null -ne $ValidatedAuthoritativeEvidenceManifest
}
