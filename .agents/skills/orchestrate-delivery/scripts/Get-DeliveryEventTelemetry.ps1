[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[ValidateNotNullOrEmpty()]
	[string]$EventLogPath
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

$ResolvedEventLogPath = (Resolve-Path -LiteralPath $EventLogPath -ErrorAction Stop).Path
$ThreadIds = [System.Collections.Generic.HashSet[string]]::new(
	[System.StringComparer]::Ordinal
)
$SessionId = $null
$LastUsage = $null
$LineNumber = 0

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
}
