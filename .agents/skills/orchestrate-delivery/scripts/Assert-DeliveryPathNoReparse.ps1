[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[string]$Path,

	[Parameter(Mandatory)]
	[string]$Root
)

$ErrorActionPreference = 'Stop'
$CurrentPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
$Root = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')

if (-not $CurrentPath.Equals(
		$Root,
		[System.StringComparison]::OrdinalIgnoreCase
	) -and -not $CurrentPath.StartsWith(
		$Root + [System.IO.Path]::DirectorySeparatorChar,
		[System.StringComparison]::OrdinalIgnoreCase
	)) {
	throw "Path '$Path' is outside root '$Root'."
}

while ($true) {
	if (Test-Path -LiteralPath $CurrentPath) {
		$Item = Get-Item -LiteralPath $CurrentPath -Force
		if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
			throw 'Repository snapshot path traverses a reparse point.'
		}
	}

	if ($CurrentPath.Equals(
		$Root,
		[System.StringComparison]::OrdinalIgnoreCase
		)) {
		break
	}

	$Parent = [System.IO.Path]::GetDirectoryName($CurrentPath)
	if ([string]::IsNullOrWhiteSpace($Parent) -or $Parent -eq $CurrentPath) {
		throw "Could not walk path '$Path' to root '$Root'."
	}
	$CurrentPath = $Parent.TrimEnd('\', '/')
}
