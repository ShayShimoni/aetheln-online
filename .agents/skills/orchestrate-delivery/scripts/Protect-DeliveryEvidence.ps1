[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[string[]]$EvidencePaths,

	[Parameter(Mandatory)]
	[string]$ManifestPath,

	[Parameter(Mandatory)]
	[string]$HandoffHash
)

$ErrorActionPreference = 'Stop'
$ManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
if (Test-Path -LiteralPath $ManifestPath) {
	throw "Evidence manifest '$ManifestPath' already exists."
}

$Files = @()
foreach ($EvidencePath in @($EvidencePaths | Sort-Object -Unique)) {
	if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
		throw 'Declared evidence path must not be blank.'
	}
	if (-not (Test-Path -LiteralPath $EvidencePath)) {
		throw "Declared evidence path '$EvidencePath' does not exist."
	}
	if (-not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) {
		throw "Declared evidence path '$EvidencePath' is not a file."
	}

	$ResolvedPath = (Resolve-Path -LiteralPath $EvidencePath).Path
	$Files += [ordered]@{
		Path = $ResolvedPath
		Sha256 = (
			Get-FileHash -LiteralPath $ResolvedPath -Algorithm SHA256
		).Hash.ToLowerInvariant()
	}
}

$Manifest = [ordered]@{
	HandoffHash = $HandoffHash
	Files = $Files
}
$Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
$ManifestHash = (
	Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256
).Hash.ToLowerInvariant()

foreach ($ProtectedPath in @(
		$Files | ForEach-Object { [string]$_.Path }
	) + @($ManifestPath)) {
	$Item = Get-Item -LiteralPath $ProtectedPath -Force
	$Item.IsReadOnly = $true
}

[pscustomobject]@{
	ManifestPath = $ManifestPath
	ManifestHash = $ManifestHash
	Files = $Files
}
