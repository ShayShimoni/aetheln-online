[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[ValidateNotNullOrEmpty()]
	[string]$EventLogPath,

	[AllowEmptyCollection()]
	[string[]]$RequiredSourcePaths
)

$ErrorActionPreference = 'Stop'

function Test-PropertyPresent {
	param(
		[Parameter(Mandatory)]
		[object]$InputObject,

		[Parameter(Mandatory)]
		[string]$Name
	)

	return $null -ne $InputObject.PSObject.Properties[$Name]
}

function Get-ObservedTokenValue {
	param(
		[Parameter(Mandatory)]
		[object]$Usage,

		[Parameter(Mandatory)]
		[string]$Name,

		[Parameter(Mandatory)]
		[int]$LineNumber
	)

	if (-not (Test-PropertyPresent -InputObject $Usage -Name $Name)) {
		return $null
	}

	$Value = $Usage.$Name
	if ($null -eq $Value) {
		return $null
	}

	if (
		$Value -is [bool] -or
		$Value -isnot [ValueType] -or
		$Value -isnot [System.IConvertible]
	) {
		throw "Event log line $LineNumber has a non-numeric '$Name' value."
	}

	try {
		$DecimalValue = [decimal]$Value
	}
	catch {
		throw "Event log line $LineNumber has a non-numeric '$Name' value."
	}

	if ($DecimalValue -lt 0 -or $DecimalValue -ne [decimal]::Truncate($DecimalValue)) {
		throw "Event log line $LineNumber has an invalid '$Name' value; token observations must be non-negative integers."
	}

	return $DecimalValue
}

function Test-DeliveryEventInteger {
	param(
		[AllowNull()]
		[object]$Value
	)

	$IsIntegerValue = (
		$null -ne $Value -and
		$Value -isnot [bool] -and
		$Value -isnot [string] -and
		$Value -is [ValueType] -and
		$Value -isnot [single] -and
		$Value -isnot [double] -and
		$Value -isnot [decimal]
	)
	if (-not $IsIntegerValue) {
		return $false
	}
	try {
		[void][int64]$Value
		return $true
	}
	catch {
		return $false
	}
}

function Test-DeliveryPropertySet {
	param(
		[AllowNull()]
		[object]$Value,

		[Parameter(Mandatory)]
		[string[]]$ExpectedNames
	)

	if ($null -eq $Value -or $Value -isnot [pscustomobject]) {
		return $false
	}
	$ObservedNames = [string[]]@($Value.PSObject.Properties.Name)
	if ($ObservedNames.Count -ne $ExpectedNames.Count) {
		return $false
	}
	foreach ($Name in $ExpectedNames) {
		if ($ObservedNames -cnotcontains $Name) {
			return $false
		}
	}
	return $true
}

function Get-DeliverySourceErrorCode {
	param(
		[AllowNull()]
		[object]$Result
	)

	if ($null -eq $Result -or
		-not (Test-PropertyPresent -InputObject $Result -Name 'content') -or
		$Result.content -isnot [System.Array]) {
		return $null
	}
	foreach ($Block in @($Result.content)) {
		if ($null -eq $Block -or $Block -isnot [pscustomobject] -or
			-not (Test-PropertyPresent -InputObject $Block -Name 'text') -or
			$Block.text -isnot [string]) {
			continue
		}
		$Match = [regex]::Match([string]$Block.text, '^\[([a-z][a-z0-9_]*)\]')
		if ($Match.Success) {
			return $Match.Groups[1].Value
		}
	}
	return $null
}

function ConvertTo-DeliveryCanonicalJsonString {
	param(
		[Parameter(Mandatory)]
		[AllowEmptyString()]
		[string]$Value
	)

	$Builder = [System.Text.StringBuilder]::new()
	[void]$Builder.Append('"')
	foreach ($Character in $Value.ToCharArray()) {
		$Code = [int][char]$Character
		$Escaped = switch ($Code) {
			8 { '\b' }
			9 { '\t' }
			10 { '\n' }
			12 { '\f' }
			13 { '\r' }
			34 { '\"' }
			92 { '\\' }
			default {
				if ($Code -lt 32) {
					'\u{0:x4}' -f $Code
				}
				else {
					[string]$Character
				}
			}
		}
		[void]$Builder.Append([string]$Escaped)
	}
	[void]$Builder.Append('"')
	return $Builder.ToString()
}

function ConvertTo-DeliveryCanonicalSourcePageText {
	param(
		[Parameter(Mandatory)]
		[object]$Page
	)

	$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
	$Builder = [System.Text.StringBuilder]::new()
	[void]$Builder.Append('{"path":')
	[void]$Builder.Append((ConvertTo-DeliveryCanonicalJsonString -Value ([string]$Page.path)))
	[void]$Builder.Append(',"encoding":')
	[void]$Builder.Append((ConvertTo-DeliveryCanonicalJsonString -Value ([string]$Page.encoding)))
	[void]$Builder.Append(',"content":')
	[void]$Builder.Append((ConvertTo-DeliveryCanonicalJsonString -Value ([string]$Page.content)))
	[void]$Builder.Append(',"base_sha256":')
	[void]$Builder.Append((ConvertTo-DeliveryCanonicalJsonString -Value ([string]$Page.base_sha256)))
	[void]$Builder.Append(',"offset_bytes":')
	[void]$Builder.Append(([int64]$Page.offset_bytes).ToString($Invariant))
	[void]$Builder.Append(',"content_bytes":')
	[void]$Builder.Append(([int64]$Page.content_bytes).ToString($Invariant))
	[void]$Builder.Append(',"end_offset_bytes":')
	[void]$Builder.Append(([int64]$Page.end_offset_bytes).ToString($Invariant))
	[void]$Builder.Append(',"file_size_bytes":')
	[void]$Builder.Append(([int64]$Page.file_size_bytes).ToString($Invariant))
	[void]$Builder.Append(',"eof":')
	[void]$Builder.Append($(if ([bool]$Page.eof) { 'true' } else { 'false' }))
	[void]$Builder.Append('}')
	return $Builder.ToString()
}

$ResolvedEventLogPath = (Resolve-Path -LiteralPath $EventLogPath -ErrorAction Stop).Path
$ThreadIds = [System.Collections.Generic.HashSet[string]]::new(
	[System.StringComparer]::Ordinal
)
$SessionId = $null
$LastUsage = $null
$LineNumber = 0
$SourceCallIds = [System.Collections.Generic.HashSet[string]]::new(
	[System.StringComparer]::Ordinal
)
$SourceStartedIds = [System.Collections.Generic.HashSet[string]]::new(
	[System.StringComparer]::Ordinal
)
$SourceCompletedIds = [System.Collections.Generic.HashSet[string]]::new(
	[System.StringComparer]::Ordinal
)
$SourceStartStates = [System.Collections.Generic.Dictionary[string, object]]::new(
	[System.StringComparer]::Ordinal
)
$SourcePendingPathCalls = [System.Collections.Generic.Dictionary[string, string]]::new(
	[System.StringComparer]::Ordinal
)
$SourcePathStates = [System.Collections.Generic.Dictionary[string, object]]::new(
	[System.StringComparer]::Ordinal
)
$CompletedSourcePaths = [System.Collections.Generic.HashSet[string]]::new(
	[System.StringComparer]::Ordinal
)
$StrictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
$CompletedSourcePageCount = 0
$HasSourceToolEvent = $false
$HasArgumentValidationFailure = $false
$HasSourcePolicyRejection = $false
$HasProtocolRejection = $false

foreach ($Line in [System.IO.File]::ReadLines($ResolvedEventLogPath)) {
	$LineNumber++
	try {
		$Event = $Line | ConvertFrom-Json -ErrorAction Stop
	}
	catch {
		throw "Event log line $LineNumber is not valid JSON: $($_.Exception.Message)"
	}

	if ($null -eq $Event -or $Event -isnot [psobject]) {
		throw "Event log line $LineNumber must contain a JSON object."
	}
	if (-not (Test-PropertyPresent -InputObject $Event -Name 'type') -or $Event.type -isnot [string]) {
		throw "Event log line $LineNumber has a missing or invalid 'type' field."
	}

	if ((@('item.started', 'item.completed') -icontains [string]$Event.type) -and
		(Test-PropertyPresent -InputObject $Event -Name 'item') -and
		$null -ne $Event.item -and $Event.item -is [pscustomobject] -and
		(Test-PropertyPresent -InputObject $Event.item -Name 'type') -and
		$Event.item.type -ieq 'mcp_tool_call' -and
		(
			((Test-PropertyPresent -InputObject $Event.item -Name 'server') -and
				$Event.item.server -ieq 'source_inspection') -or
			((Test-PropertyPresent -InputObject $Event.item -Name 'tool') -and
				$Event.item.tool -ieq 'read_allowed_source_file')
		)) {
		$HasSourceToolEvent = $true
		$Item = $Event.item
		$ItemId = if ((Test-PropertyPresent -InputObject $Item -Name 'id') -and
			$Item.id -is [string] -and
			-not [string]::IsNullOrWhiteSpace([string]$Item.id)) {
			[string]$Item.id
		}
		else {
			$HasProtocolRejection = $true
			"invalid-$LineNumber"
		}
		[void]$SourceCallIds.Add($ItemId)

		if (@('item.started', 'item.completed') -cnotcontains [string]$Event.type -or
			$Item.type -cne 'mcp_tool_call' -or
			-not (Test-PropertyPresent -InputObject $Item -Name 'server') -or
			$Item.server -cne 'source_inspection' -or
			-not (Test-PropertyPresent -InputObject $Item -Name 'tool') -or
			$Item.tool -cne 'read_allowed_source_file') {
			$HasProtocolRejection = $true
		}

		$ArgumentsValid = (
			(Test-PropertyPresent -InputObject $Item -Name 'arguments') -and
			(Test-DeliveryPropertySet -Value $Item.arguments `
				-ExpectedNames @('path', 'offset_bytes')) -and
			$Item.arguments.path -is [string] -and
			-not [string]::IsNullOrWhiteSpace([string]$Item.arguments.path) -and
			(Test-DeliveryEventInteger -Value $Item.arguments.offset_bytes) -and
			[int64]$Item.arguments.offset_bytes -ge 0
		)
		if (-not $ArgumentsValid) {
			$HasArgumentValidationFailure = $true
		}

		if ($Event.type -ieq 'item.started') {
			$StartedEnvelopeValid = (
				(Test-PropertyPresent -InputObject $Item -Name 'status') -and
				$Item.status -ceq 'in_progress' -and
				(-not (Test-PropertyPresent -InputObject $Item -Name 'result') -or
					$null -eq $Item.result) -and
				(-not (Test-PropertyPresent -InputObject $Item -Name 'error') -or
					$null -eq $Item.error)
			)
			if (-not $StartedEnvelopeValid) {
				$HasProtocolRejection = $true
			}
			if (-not $SourceStartedIds.Add($ItemId)) {
				$HasProtocolRejection = $true
			}
			if ($SourceCompletedIds.Contains($ItemId) -or $SourceStartStates.ContainsKey($ItemId)) {
				$HasProtocolRejection = $true
			}
			else {
				$SourceStartStates.Add($ItemId, [pscustomobject]@{
					Server = if ((Test-PropertyPresent -InputObject $Item -Name 'server') -and
						$Item.server -is [string]) { [string]$Item.server } else { $null }
					Tool = if ((Test-PropertyPresent -InputObject $Item -Name 'tool') -and
						$Item.tool -is [string]) { [string]$Item.tool } else { $null }
					ArgumentsValid = $ArgumentsValid
					Path = if ($ArgumentsValid) { [string]$Item.arguments.path } else { $null }
					OffsetBytes = if ($ArgumentsValid) {
						[int64]$Item.arguments.offset_bytes
					} else { $null }
				})
			}
			if ($ArgumentsValid) {
				$StartPath = [string]$Item.arguments.path
				$StartOffset = [int64]$Item.arguments.offset_bytes
				$StartPathState = if ($SourcePathStates.ContainsKey($StartPath)) {
					$SourcePathStates[$StartPath]
				}
				else {
					$null
				}
				$StartOffsetValid = if ($null -eq $StartPathState) {
					$StartOffset -eq 0
				}
				else {
					-not [bool]$StartPathState.Eof -and
					$StartOffset -eq [int64]$StartPathState.NextOffset
				}
				if (-not $StartOffsetValid -or $SourcePendingPathCalls.ContainsKey($StartPath)) {
					$HasProtocolRejection = $true
				}
				else {
					$SourcePendingPathCalls.Add($StartPath, $ItemId)
				}
			}
		}
		else {
			if (-not $SourceCompletedIds.Add($ItemId)) {
				$HasProtocolRejection = $true
			}
			$StartState = if ($SourceStartStates.ContainsKey($ItemId)) {
				$SourceStartStates[$ItemId]
			}
			else {
				$null
			}
			if ($null -eq $StartState) {
				$HasProtocolRejection = $true
				continue
			}
			if (-not $ArgumentsValid) {
				continue
			}
			if (-not [bool]$StartState.ArgumentsValid -or
				[string]$StartState.Server -cne [string]$Item.server -or
				[string]$StartState.Tool -cne [string]$Item.tool -or
				[string]$StartState.Path -cne [string]$Item.arguments.path -or
				[int64]$StartState.OffsetBytes -ne [int64]$Item.arguments.offset_bytes) {
				$HasProtocolRejection = $true
				continue
			}
			$CompletedPath = [string]$Item.arguments.path
			if (-not $SourcePendingPathCalls.ContainsKey($CompletedPath) -or
				$SourcePendingPathCalls[$CompletedPath] -cne $ItemId) {
				$HasProtocolRejection = $true
				continue
			}
			[void]$SourcePendingPathCalls.Remove($CompletedPath)
			if (-not (Test-PropertyPresent -InputObject $Item -Name 'status') -or
				$Item.status -cne 'completed' -or
				((Test-PropertyPresent -InputObject $Item -Name 'error') -and
					$null -ne $Item.error)) {
				$HasProtocolRejection = $true
				continue
			}
			if (-not (Test-PropertyPresent -InputObject $Item -Name 'result') -or
				$null -eq $Item.result -or $Item.result -isnot [pscustomobject]) {
				$HasProtocolRejection = $true
				continue
			}

			$Result = $Item.result
			$HasCamelToolError = Test-PropertyPresent -InputObject $Result -Name 'isError'
			$HasSnakeToolError = Test-PropertyPresent -InputObject $Result -Name 'is_error'
			if (($HasCamelToolError -and $HasSnakeToolError) -or
				($HasCamelToolError -and $Result.isError -isnot [bool]) -or
				($HasSnakeToolError -and $Result.is_error -isnot [bool])) {
				$HasProtocolRejection = $true
				continue
			}
			$IsToolError = (
				($HasCamelToolError -and $Result.isError -eq $true) -or
				($HasSnakeToolError -and $Result.is_error -eq $true)
			)
			if ($IsToolError) {
				$SourceErrorCode = Get-DeliverySourceErrorCode -Result $Result
				if (@(
					'source_argument_keys_invalid', 'source_offset_invalid',
					'source_offset_out_of_range', 'source_offset_utf8_boundary'
				) `
					-ccontains $SourceErrorCode) {
					$HasArgumentValidationFailure = $true
				}
				elseif (@(
					'source_file_missing', 'source_path_not_attested',
					'source_path_reparse', 'source_path_sensitive',
					'source_path_unsafe', 'source_snapshot_drift'
				) -ccontains $SourceErrorCode) {
					$HasSourcePolicyRejection = $true
				}
				else {
					$HasProtocolRejection = $true
				}
				continue
			}

			$HasSnakeStructured = Test-PropertyPresent `
				-InputObject $Result -Name 'structured_content'
			$HasCamelStructured = Test-PropertyPresent `
				-InputObject $Result -Name 'structuredContent'
			if ($HasSnakeStructured -eq $HasCamelStructured) {
				$HasProtocolRejection = $true
				continue
			}
			$Structured = if ($HasSnakeStructured) {
				$Result.structured_content
			}
			else {
				$Result.structuredContent
			}
			$RequiredPageFields = @(
				'path', 'encoding', 'content', 'base_sha256', 'offset_bytes', 'content_bytes',
				'end_offset_bytes', 'file_size_bytes', 'eof'
			)
			$PageValid = Test-DeliveryPropertySet `
				-Value $Structured `
				-ExpectedNames $RequiredPageFields
			if ($PageValid) {
				$PageValid = (
					$Structured.path -is [string] -and
					-not [string]::IsNullOrWhiteSpace([string]$Structured.path) -and
					$Structured.path -ceq $Item.arguments.path -and
					$Structured.encoding -is [string] -and
					@('utf8', 'base64') -ccontains [string]$Structured.encoding -and
					$Structured.content -is [string] -and
					$Structured.base_sha256 -is [string] -and
					$Structured.base_sha256 -cmatch '^[0-9a-f]{64}$' -and
					(Test-DeliveryEventInteger -Value $Structured.offset_bytes) -and
					(Test-DeliveryEventInteger -Value $Structured.content_bytes) -and
					(Test-DeliveryEventInteger -Value $Structured.end_offset_bytes) -and
					(Test-DeliveryEventInteger -Value $Structured.file_size_bytes) -and
					$Structured.eof -is [bool]
				)
			}
			$PageBytes = $null
			if ($PageValid) {
				try {
					$PageBytes = if ($Structured.encoding -ceq 'utf8') {
						$StrictUtf8.GetBytes([string]$Structured.content)
					}
					else {
						[Convert]::FromBase64String([string]$Structured.content)
					}
				}
				catch {
					$PageValid = $false
				}
			}
			if ($PageValid -and $Structured.encoding -ceq 'base64') {
				$PageValid = (
					[Convert]::ToBase64String($PageBytes) -ceq [string]$Structured.content
				)
			}
			if ($PageValid) {
				$PageValid = (
					(Test-PropertyPresent -InputObject $Result -Name 'content') -and
					$Result.content -is [System.Array] -and
					@($Result.content).Count -eq 1 -and
					$Result.content[0] -is [pscustomobject] -and
					(Test-DeliveryPropertySet -Value $Result.content[0] `
						-ExpectedNames @('type', 'text')) -and
					$Result.content[0].type -ceq 'text' -and
					$Result.content[0].text -is [string]
				)
			}
			if ($PageValid) {
				$CanonicalStructuredText = ConvertTo-DeliveryCanonicalSourcePageText `
					-Page $Structured
				$PageValid = ([string]$Result.content[0].text -ceq $CanonicalStructuredText)
			}
			if ($PageValid) {
				$Offset = [int64]$Structured.offset_bytes
				$ContentBytes = [int64]$Structured.content_bytes
				$EndOffset = [int64]$Structured.end_offset_bytes
				$FileSize = [int64]$Structured.file_size_bytes
				$PageValid = (
					$Offset -eq [int64]$Item.arguments.offset_bytes -and
					$Offset -ge 0 -and $ContentBytes -ge 0 -and
					$EndOffset -eq ($Offset + $ContentBytes) -and
					$ContentBytes -eq [int64]$PageBytes.Length -and
					$ContentBytes -le 8192 -and
					$EndOffset -le $FileSize -and
					[bool]$Structured.eof -eq ($EndOffset -eq $FileSize) -and
					([bool]$Structured.eof -or $ContentBytes -gt 0)
				)
			}

			$PathState = if ($PageValid -and $SourcePathStates.ContainsKey([string]$Structured.path)) {
				$SourcePathStates[[string]$Structured.path]
			}
			else {
				$null
			}
			if ($PageValid -and $null -eq $PathState) {
				$PageValid = ([int64]$Structured.offset_bytes -eq 0)
			}
			elseif ($PageValid) {
				$PageValid = (
					-not [bool]$PathState.Eof -and
					[int64]$Structured.offset_bytes -eq [int64]$PathState.NextOffset -and
					[string]$Structured.encoding -ceq [string]$PathState.Encoding -and
					[string]$Structured.base_sha256 -ceq [string]$PathState.BaseSha256 -and
					[int64]$Structured.file_size_bytes -eq [int64]$PathState.FileSize
				)
			}
			if (-not $PageValid) {
				$HasProtocolRejection = $true
				continue
			}

			if ($null -eq $PathState) {
				$PathState = [pscustomobject]@{
					Path = [string]$Structured.path
					NextOffset = [int64]0
					Encoding = [string]$Structured.encoding
					BaseSha256 = [string]$Structured.base_sha256
					FileSize = [int64]$Structured.file_size_bytes
					Eof = $false
					Hasher = [System.Security.Cryptography.SHA256]::Create()
				}
				$SourcePathStates.Add([string]$Structured.path, $PathState)
			}
			if ([bool]$Structured.eof) {
				[void]$PathState.Hasher.TransformFinalBlock($PageBytes, 0, $PageBytes.Length)
				$ActualHash = [BitConverter]::ToString($PathState.Hasher.Hash).
					Replace('-', '').ToLowerInvariant()
				if ($ActualHash -cne [string]$Structured.base_sha256) {
					$HasProtocolRejection = $true
					continue
				}
			}
			else {
				[void]$PathState.Hasher.TransformBlock(
					$PageBytes, 0, $PageBytes.Length, $PageBytes, 0
				)
			}
			$PathState.NextOffset = [int64]$Structured.end_offset_bytes
			$PathState.Eof = [bool]$Structured.eof
			$CompletedSourcePageCount++
			if ([bool]$Structured.eof) {
				[void]$CompletedSourcePaths.Add([string]$Structured.path)
			}
		}
	}

	switch ($Event.type) {
		'thread.started' {
			if (-not (Test-PropertyPresent -InputObject $Event -Name 'thread_id') -or $Event.thread_id -isnot [string]) {
				throw "Event log line $LineNumber has a missing or invalid 'thread_id' field."
			}
			if (-not [string]::IsNullOrWhiteSpace($Event.thread_id)) {
				[void]$ThreadIds.Add($Event.thread_id)
				if ($ThreadIds.Count -gt 1) {
					throw 'Event log contains multiple conflicting nonempty thread IDs.'
				}
				$SessionId = $Event.thread_id
			}
		}
		'turn.completed' {
			if (Test-PropertyPresent -InputObject $Event -Name 'usage') {
				if ($null -ne $Event.usage -and $Event.usage -isnot [pscustomobject]) {
					throw "Event log line $LineNumber has an invalid 'usage' field."
				}
				$LastUsage = $Event.usage
			}
			else {
				$LastUsage = $null
			}
		}
	}
}

foreach ($StartedId in $SourceStartedIds) {
	if (-not $SourceCompletedIds.Contains($StartedId)) {
		$HasProtocolRejection = $true
	}
}
foreach ($CompletedId in $SourceCompletedIds) {
	if (-not $SourceStartedIds.Contains($CompletedId)) {
		$HasProtocolRejection = $true
	}
}

foreach ($PathState in $SourcePathStates.Values) {
	$PathState.Hasher.Dispose()
}

$RequiredSourcePathSet = $null
if ($PSBoundParameters.ContainsKey('RequiredSourcePaths')) {
	$RequiredSourcePathSet = [System.Collections.Generic.HashSet[string]]::new(
		[System.StringComparer]::Ordinal
	)
	foreach ($RequiredSourcePath in $RequiredSourcePaths) {
		[void]$RequiredSourcePathSet.Add([string]$RequiredSourcePath)
	}
}
$CompletedSources = [object[]]@(
	$SourcePathStates.Values |
		Where-Object {
			[bool]$_.Eof -and
			($null -eq $RequiredSourcePathSet -or
				$RequiredSourcePathSet.Contains([string]$_.Path))
		} |
		Sort-Object -Property Path |
		ForEach-Object {
			[pscustomobject][ordered]@{
				Path = [string]$_.Path
				BaseSha256 = [string]$_.BaseSha256
			}
		}
)

$SourceInspectionOutcome = if (-not $HasSourceToolEvent) {
	'no_tool_call'
}
elseif ($HasArgumentValidationFailure) {
	'argument_validation_failed'
}
elseif ($HasSourcePolicyRejection) {
	'source_policy_rejected'
}
elseif ($HasProtocolRejection -or $CompletedSourcePageCount -eq 0) {
	'protocol_rejected'
}
elseif ($CompletedSourcePaths.Count -eq $SourcePathStates.Count) {
	'complete_pagination'
}
else {
	'incomplete_pagination'
}

$TokenNames = @(
	'input_tokens', 'cached_input_tokens', 'cache_write_input_tokens',
	'output_tokens', 'reasoning_output_tokens'
)
$Observed = @{}
foreach ($TokenName in $TokenNames) {
	$Observed[$TokenName] = if ($null -eq $LastUsage) {
		$null
	} else {
		Get-ObservedTokenValue -Usage $LastUsage -Name $TokenName -LineNumber $LineNumber
	}
}

[pscustomobject]@{
	SessionId = $SessionId
	InputTokens = $Observed.input_tokens
	CachedInputTokens = $Observed.cached_input_tokens
	CacheWriteInputTokens = $Observed.cache_write_input_tokens
	OutputTokens = $Observed.output_tokens
	ReasoningOutputTokens = $Observed.reasoning_output_tokens
	TotalTokens = if ($null -ne $Observed.input_tokens -and $null -ne $Observed.output_tokens) {
		$Observed.input_tokens + $Observed.output_tokens
	} else { $null }
	Model = $null
	ReasoningTier = $null
	SourceInspection = [pscustomobject][ordered]@{
		Outcome = $SourceInspectionOutcome
		CallCount = [long]$SourceCallIds.Count
		CompletedPageCount = [long]$CompletedSourcePageCount
		CompletedPathCount = [long]$CompletedSourcePaths.Count
		CompletedSources = $CompletedSources
	}
}
