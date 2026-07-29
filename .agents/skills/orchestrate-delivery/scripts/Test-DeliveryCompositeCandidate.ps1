[CmdletBinding()]
param(
	[Parameter(Mandatory)][string]$CandidatePath,
	[Parameter(Mandatory)][string]$ExpectedCandidateSha256,
	[Parameter(Mandatory)][string]$SourceCommit,
	[Parameter(Mandatory)][string]$ExternalIngestEvidenceSha256,
	[Parameter(Mandatory)][string]$TextPatchEvidenceSha256,
	[Parameter(Mandatory)][string]$RepositoryRoot,
	[Parameter(DontShow)][scriptblock]$FaultInjector
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DeliveryExternalFileIngest.Common.ps1')

$Repository = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$CandidateFullPath = [IO.Path]::GetFullPath($CandidatePath)
if (Test-DeliveryPathWithin -Path $CandidateFullPath -Root $Repository) {
	throw '[composite_invalid] Composite must remain outside repository.'
}
Assert-DeliveryNoReparsePath -Path $CandidateFullPath `
	-StopRoot ([IO.Path]::GetPathRoot($CandidateFullPath))
$Item = Get-Item -LiteralPath $CandidatePath -Force
if (-not $Item.IsReadOnly) { throw '[composite_unsealed] Composite is not read-only.' }
$Read = Read-DeliveryJsonFile -Path $CandidatePath
if ($ExpectedCandidateSha256 -cnotmatch '^[0-9a-f]{64}$' -or
	$Read.Sha256 -cne $ExpectedCandidateSha256) {
	throw '[composite_tampered] Composite hash differs.'
}
$Value = $Read.Value
Assert-DeliveryExactProperties $Value @(
	'format','source_commit','external_ingest_evidence_sha256',
	'text_patch_evidence_sha256','final_inventory_sha256','changed_paths'
) 'composite candidate'
if ($Value.format -cne 'delivery_composite_candidate_v1' -or
	$Value.source_commit -cne $SourceCommit -or
	$Value.external_ingest_evidence_sha256 -cne $ExternalIngestEvidenceSha256 -or
	$Value.text_patch_evidence_sha256 -cne $TextPatchEvidenceSha256) {
	throw '[composite_invalid] Composite provenance differs.'
}
$Seen = [Collections.Generic.HashSet[string]]::new(
	[StringComparer]::OrdinalIgnoreCase
)
$Paths = @($Value.changed_paths)
if ($Paths.Count -lt 1 -or $Paths.Count -gt 256) {
	throw '[composite_invalid] Changed path count is invalid.'
}
foreach ($Path in $Paths) {
	if ($Path -isnot [string]) {
		throw '[composite_invalid] Changed paths are invalid.'
	}
	try {
		$Normalized = Assert-DeliverySafeRelativePath -Path $Path -MaxLength 512
	}
	catch {
		throw '[composite_invalid] Changed paths are invalid.'
	}
	if ($Normalized -cne $Path -or -not $Seen.Add($Normalized)) {
		throw '[composite_invalid] Changed paths are invalid.'
	}
}
$Sorted = @(Get-DeliveryOrdinalSortedStrings -Value ([string[]]$Paths))
for ($Index = 0; $Index -lt $Paths.Count; $Index++) {
	if ($Paths[$Index] -cne $Sorted[$Index]) {
		throw '[composite_invalid] Changed paths are not ordinal-sorted.'
	}
}
$Files = foreach ($Path in $Paths) {
	$FullPath = [IO.Path]::GetFullPath((Join-Path $Repository $Path.Replace('/', '\')))
	if (-not (Test-DeliveryPathWithin -Path $FullPath -Root $Repository) -or
		-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
		throw "[composite_inventory] '$Path' is absent."
	}
	Assert-DeliveryNoReparsePath -Path $FullPath -StopRoot $Repository
	$File = Get-Item -LiteralPath $FullPath -Force
	[pscustomobject][ordered]@{
		path = $Path
		size = [long]$File.Length
		sha256 = Get-DeliverySha256File -Path $FullPath
	}
}
if ($null -ne $FaultInjector) {
	& $FaultInjector 'after_initial_inventory_hash' @{
		RepositoryRoot = $Repository
		ChangedPaths = $Paths
	}
}
$ConfirmedFiles = foreach ($Path in $Paths) {
	$FullPath = [IO.Path]::GetFullPath((Join-Path $Repository $Path.Replace('/', '\')))
	if (-not (Test-DeliveryPathWithin -Path $FullPath -Root $Repository) -or
		-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
		throw "[composite_inventory] '$Path' is absent."
	}
	Assert-DeliveryNoReparsePath -Path $FullPath -StopRoot $Repository
	$File = Get-Item -LiteralPath $FullPath -Force
	[pscustomobject][ordered]@{
		path = $Path
		size = [long]$File.Length
		sha256 = Get-DeliverySha256File -Path $FullPath
	}
}
try {
	Assert-DeliveryInventoryEqual -Expected @($Files) -Actual @($ConfirmedFiles)
}
catch {
	throw '[composite_inventory] Repository inventory changed during validation.'
}
if ((Get-DeliveryInventoryHash -Files @($ConfirmedFiles)) -cne
	[string]$Value.final_inventory_sha256) {
	throw '[composite_inventory] Final inventory hash differs.'
}
$FinalRead = Read-DeliveryJsonFile -Path $CandidatePath
if ($FinalRead.Sha256 -cne $Read.Sha256) {
	throw '[composite_tampered] Composite changed during validation.'
}
[pscustomobject]@{
	CandidatePath = $Read.Path
	CandidateSha256 = $Read.Sha256
	FinalInventorySha256 = [string]$Value.final_inventory_sha256
	ChangedPaths = $Paths
}
