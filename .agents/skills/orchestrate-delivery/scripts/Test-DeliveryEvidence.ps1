[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[string]$ManifestPath,

	[Parameter(Mandatory)]
	[string]$ExpectedManifestHash,

	[Parameter(Mandatory)]
	[string]$ExpectedHandoffHash,

	[switch]$IntegrityOnly
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
$ManifestPropertyNames = @($Manifest.PSObject.Properties.Name)
$HasSchemaVersion = $ManifestPropertyNames -ccontains 'SchemaVersion'
$HasDisposition = $ManifestPropertyNames -ccontains 'Disposition'
$IsLegacyManifest = -not $HasSchemaVersion -and -not $HasDisposition

if ($IsLegacyManifest) {
	$LegacyPropertyNames = @('HandoffHash', 'Files')
	if ($ManifestPropertyNames.Count -ne $LegacyPropertyNames.Count -or
		@($LegacyPropertyNames | Where-Object {
			$ManifestPropertyNames -cnotcontains $_
		}).Count -ne 0) {
		throw "Evidence manifest '$ManifestPath' has an unsupported legacy schema."
	}
	if (-not $IntegrityOnly) {
		throw (
			"Evidence manifest '$ManifestPath' is legacy evidence and not routable. " +
			'Use -IntegrityOnly only to inspect retained failure evidence.'
		)
	}
	$Disposition = 'legacy-unknown'
}
else {
	if (-not $HasSchemaVersion -or -not $HasDisposition -or
		($Manifest.SchemaVersion -isnot [int32] -and
			$Manifest.SchemaVersion -isnot [int64]) -or
		[long]$Manifest.SchemaVersion -ne 2) {
		throw "Evidence manifest '$ManifestPath' has an unsupported schema version."
	}

	$Disposition = [string]$Manifest.Disposition
	if (@('accepted', 'rejected') -cnotcontains $Disposition) {
		throw "Evidence manifest '$ManifestPath' has an invalid disposition."
	}
	if (-not $IntegrityOnly -and $Disposition -cne 'accepted') {
		throw (
			"Evidence manifest '$ManifestPath' is rejected and not routable. " +
			'Use -IntegrityOnly only to inspect retained failure evidence.'
		)
	}
}

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
	Disposition = $Disposition
	FileCount = @($Manifest.Files).Count
}
