[CmdletBinding()]
param(
	[AllowEmptyString()]
	[Parameter(Mandatory)]
	[string]$RawPaths
)

@(
	$RawPaths.Split([char]0) |
		Where-Object { $_.Length -gt 0 }
)
