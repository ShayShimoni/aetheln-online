[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[string]$ManifestPath,

	[Parameter(Mandatory)]
	[string]$ExpectedManifestHash,

	[Parameter(Mandatory)]
	[string]$ExpectedHandoffHash
)

$ErrorActionPreference = 'Stop'
$ManifestPath = (Resolve-Path -LiteralPath $ManifestPath).Path
$ManifestItem = Get-Item -LiteralPath $ManifestPath -Force
if (-not $ManifestItem.IsReadOnly) {
	throw "Evidence manifest '$ManifestPath' is not read-only."
}

$ActualManifestHash = (
	Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256
).Hash.ToLowerInvariant()
if ($ActualManifestHash -ne $ExpectedManifestHash) {
	throw "Evidence manifest '$ManifestPath' does not match its expected hash."
}

$Manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
if ([string]$Manifest.HandoffHash -ne $ExpectedHandoffHash) {
	throw "Evidence manifest '$ManifestPath' belongs to a different handoff."
}

foreach ($File in @($Manifest.Files)) {
	$EvidencePath = [string]$File.Path
	if (-not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) {
		throw "Evidence file '$EvidencePath' is missing."
	}

	$EvidenceItem = Get-Item -LiteralPath $EvidencePath -Force
	if (-not $EvidenceItem.IsReadOnly) {
		throw "Evidence file '$EvidencePath' is not read-only."
	}

	$ActualHash = (
		Get-FileHash -LiteralPath $EvidencePath -Algorithm SHA256
	).Hash.ToLowerInvariant()
	if ($ActualHash -ne [string]$File.Sha256) {
		throw "Evidence file '$EvidencePath' does not match its manifest hash."
	}
}

[pscustomobject]@{
	ManifestPath = $ManifestPath
	ManifestHash = $ActualManifestHash
	HandoffHash = [string]$Manifest.HandoffHash
	FileCount = @($Manifest.Files).Count
}
