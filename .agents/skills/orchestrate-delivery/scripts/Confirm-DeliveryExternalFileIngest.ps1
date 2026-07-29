[CmdletBinding()]
param(
	[Parameter(Mandatory)][string]$JournalPath,
	[Parameter(Mandatory)][string]$ExpectedJournalSha256,
	[Parameter(Mandatory)][string]$RepositoryRoot,
	[Parameter(Mandatory)][string]$EvidencePath,
	[Parameter(DontShow)][scriptblock]$FaultInjector,
	[switch]$PassThru
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DeliveryExternalFileIngest.Common.ps1')

$Repository = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$JournalFullPath = [IO.Path]::GetFullPath($JournalPath)
Assert-DeliveryNoReparsePath -Path $JournalFullPath `
	-StopRoot ([IO.Path]::GetPathRoot($JournalFullPath))
$JournalItem = Get-Item -LiteralPath $JournalPath -Force
if (-not $JournalItem.IsReadOnly) { throw '[journal_unsealed] Journal is not read-only.' }
$JournalRead = Read-DeliveryJsonFile -Path $JournalPath
if ($ExpectedJournalSha256 -cnotmatch '^[0-9a-f]{64}$' -or
	$JournalRead.Sha256 -cne $ExpectedJournalSha256) {
	throw '[journal_tampered] Journal hash differs from the retained hash.'
}
$Journal = $JournalRead.Value
Assert-DeliveryExactProperties $Journal @(
	'format','state','source_commit','repository_root','source_root','staging_root',
	'staged_payload_root','target_root','destination_root','external_manifest_sha256',
	'expected_inventory_sha256','files'
) 'prepared journal'
if ($Journal.format -cne 'delivery_external_file_ingest_journal_v1' -or
	$Journal.state -cne 'prepared' -or $Journal.target_root -cne 'visuals' -or
	[string]$Journal.source_commit -cnotmatch '^[0-9a-f]{40,64}$' -or
	[string]$Journal.external_manifest_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
	[string]$Journal.expected_inventory_sha256 -cnotmatch '^[0-9a-f]{64}$') {
	throw '[journal_invalid] Journal contract differs.'
}
if (-not ([IO.Path]::GetFullPath([string]$Journal.repository_root)).Equals(
	$Repository, [StringComparison]::OrdinalIgnoreCase)) {
	throw '[journal_invalid] Journal repository differs.'
}
if ((Get-DeliveryRepositoryHeadCommit -RepositoryRoot $Repository) -cne
	[string]$Journal.source_commit) {
	throw '[source_commit_mismatch] Repository HEAD differs from the journal.'
}
$Destination = [IO.Path]::GetFullPath((Join-Path $Repository 'visuals'))
if (-not ([IO.Path]::GetFullPath([string]$Journal.destination_root)).Equals(
	$Destination, [StringComparison]::OrdinalIgnoreCase)) {
	throw '[journal_invalid] Journal destination differs.'
}
$Source = [IO.Path]::GetFullPath([string]$Journal.source_root)
$StagingRoot = [IO.Path]::GetFullPath([string]$Journal.staging_root)
if ((Test-DeliveryPathWithin -Path $JournalFullPath -Root $Repository) -or
	(Test-DeliveryPathWithin -Path $JournalFullPath -Root $Source) -or
	(Test-DeliveryPathWithin -Path $JournalFullPath -Root $StagingRoot)) {
	throw '[journal_path_unsafe] Journal must remain outside repository, source, and staging roots.'
}
$Evidence = [IO.Path]::GetFullPath($EvidencePath)
if ((Test-DeliveryPathWithin -Path $Evidence -Root $Repository) -or
	(Test-DeliveryPathWithin -Path $Evidence -Root $Source) -or
	(Test-DeliveryPathWithin -Path $Evidence -Root $StagingRoot)) {
	throw '[artifact_path_unsafe] Reconciliation evidence must be outside repository, source, and staging roots.'
}
Assert-DeliveryNoReparsePath -Path $Evidence `
	-StopRoot ([IO.Path]::GetPathRoot($Evidence)) -AllowMissingLeaf
$Actual = Get-DeliveryExternalInventory -Root $Destination
$Expected = Assert-DeliveryInventoryRecords -Files @($Journal.files)
Assert-DeliveryInventoryEqual -Expected $Expected -Actual $Actual
if ((Get-DeliveryInventoryHash -Files $Actual) -cne
	[string]$Journal.expected_inventory_sha256) {
	throw '[inventory_mismatch] Destination inventory hash differs.'
}
$EvidenceValue = New-DeliveryIngestEvidenceValue `
	-SourceCommit ([string]$Journal.source_commit) -DestinationRoot $Destination `
	-ExternalManifestSha256 ([string]$Journal.external_manifest_sha256) `
	-JournalSha256 $JournalRead.Sha256 -Files $Actual
$ExpectedEvidenceBytes = $script:DeliveryUtf8.GetBytes(
	($EvidenceValue | ConvertTo-Json -Depth 20 -Compress)
)
$PendingEvidence = $null
if (Test-Path -LiteralPath $Evidence) {
	if (-not (Test-Path -LiteralPath $Evidence -PathType Leaf) -or
		(Get-DeliverySha256File -Path $Evidence) -cne
		(Get-DeliverySha256Bytes -Bytes $ExpectedEvidenceBytes)) {
		throw '[evidence_conflict] Existing reconciliation evidence differs.'
	}
	$EvidenceItem = Get-Item -LiteralPath $Evidence -Force
}
else {
	$PendingEvidence = $Evidence + '.pending-' + [guid]::NewGuid().ToString('N')
	Assert-DeliveryNoReparsePath -Path $PendingEvidence `
		-StopRoot ([IO.Path]::GetPathRoot($PendingEvidence)) -AllowMissingLeaf
	$PendingSeal = Write-DeliverySealedJson `
		-Value $EvidenceValue -Path $PendingEvidence
}
if ($null -ne $FaultInjector) {
	& $FaultInjector 'after_reconciliation_prepare' @{
		DestinationRoot = $Destination
		EvidencePath = $Evidence
		PendingEvidencePath = $PendingEvidence
	}
}
if ((Get-DeliveryRepositoryHeadCommit -RepositoryRoot $Repository) -cne
	[string]$Journal.source_commit) {
	throw '[source_commit_mismatch] Repository HEAD changed before evidence publish.'
}
$PublishActual = Get-DeliveryExternalInventory -Root $Destination
Assert-DeliveryInventoryEqual -Expected $Expected -Actual $PublishActual
if ((Get-DeliveryInventoryHash -Files $PublishActual) -cne
	[string]$Journal.expected_inventory_sha256) {
	throw '[inventory_mismatch] Destination changed before evidence publish.'
}
if ($null -ne $PendingEvidence) {
	if (Test-Path -LiteralPath $Evidence) {
		throw '[evidence_conflict] Evidence path appeared before publish.'
	}
	[IO.File]::Move($PendingEvidence, $Evidence)
	$EvidenceSeal = [pscustomobject]@{
		Path = $Evidence
		Sha256 = $PendingSeal.Sha256
	}
}
else {
	if (-not $EvidenceItem.IsReadOnly) {
		$EvidenceItem.IsReadOnly = $true
	}
	$EvidenceSeal = [pscustomobject]@{
		Path = $Evidence
		Sha256 = Get-DeliverySha256File -Path $Evidence
	}
}
[pscustomobject][ordered]@{
	Status = 'accepted'
	ExternalManifestSha256 = [string]$Journal.external_manifest_sha256
	PreparedJournalPath = $JournalRead.Path
	PreparedJournalSha256 = $JournalRead.Sha256
	EvidenceManifestPath = $EvidenceSeal.Path
	EvidenceManifestSha256 = $EvidenceSeal.Sha256
	DestinationRoot = $Destination
	ChangedPaths = $EvidenceValue.changed_paths
}
