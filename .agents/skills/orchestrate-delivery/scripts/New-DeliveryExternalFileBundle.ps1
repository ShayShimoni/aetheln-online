[CmdletBinding()]
param(
	[Parameter(Mandatory)][string]$SourceRoot,
	[Parameter(Mandatory)][string]$RepositoryRoot,
	[Parameter(Mandatory)][string]$ManifestPath,
	[switch]$PassThru
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DeliveryExternalFileIngest.Common.ps1')

$ResolvedSource = (Resolve-Path -LiteralPath $SourceRoot).Path
$ResolvedRepository = (Resolve-Path -LiteralPath $RepositoryRoot).Path
if (-not (Get-Item -LiteralPath $ResolvedSource -Force).PSIsContainer) {
	throw '[source_invalid] SourceRoot must be a directory.'
}
if (-not [IO.Path]::GetFileName($ResolvedSource.TrimEnd('\', '/')).Equals(
	'visuals', [StringComparison]::OrdinalIgnoreCase)) {
	throw '[source_root_invalid] SourceRoot must be the standalone visuals directory.'
}
if ((Test-DeliveryPathWithin -Path $ResolvedSource -Root $ResolvedRepository) -or
	(Test-DeliveryPathWithin -Path $ResolvedRepository -Root $ResolvedSource)) {
	throw '[path_overlap] SourceRoot and RepositoryRoot must be disjoint.'
}
$ManifestFullPath = [IO.Path]::GetFullPath($ManifestPath)
if ((Test-DeliveryPathWithin -Path $ManifestFullPath -Root $ResolvedSource) -or
	(Test-DeliveryPathWithin -Path $ManifestFullPath -Root $ResolvedRepository)) {
	throw '[manifest_path_unsafe] ManifestPath must be outside source and repository.'
}
Assert-DeliveryNoReparsePath -Path $ResolvedSource `
	-StopRoot ([IO.Path]::GetPathRoot($ResolvedSource))
Assert-DeliveryNoReparsePath -Path $ResolvedRepository `
	-StopRoot ([IO.Path]::GetPathRoot($ResolvedRepository))
Assert-DeliveryNoReparsePath -Path $ManifestFullPath `
	-StopRoot ([IO.Path]::GetPathRoot($ManifestFullPath)) -AllowMissingLeaf

$Inventory = Get-DeliveryExternalInventory -Root $ResolvedSource
$Files = @($Inventory | ForEach-Object {
	[ordered]@{
		path = $_.path
		operation = 'create'
		size = [long]$_.size
		sha256 = $_.sha256
	}
})
$Manifest = [ordered]@{
	format = 'delivery_external_file_bundle_v1'
	target_root = 'visuals'
	files = $Files
}
$Written = Write-DeliverySealedJson -Value $Manifest -Path $ManifestFullPath
$Result = [pscustomobject][ordered]@{
	ManifestPath = $Written.Path
	ManifestSha256 = $Written.Sha256
	FileCount = $Files.Count
	TotalBytes = [long](($Inventory | Measure-Object -Property size -Sum).Sum)
}
$Result
