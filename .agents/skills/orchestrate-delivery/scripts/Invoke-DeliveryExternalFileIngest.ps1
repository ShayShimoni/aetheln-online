[CmdletBinding()]
param(
	[Parameter(Mandatory)][string]$ManifestPath,
	[Parameter(Mandatory)][string]$SourceRoot,
	[Parameter(Mandatory)][string]$RepositoryRoot,
	[Parameter(Mandatory)][string]$StagingParent,
	[Parameter(Mandatory)][string]$JournalPath,
	[Parameter(Mandatory)][string]$EvidencePath,
	[Parameter(Mandatory)][string]$SourceCommit,
	[switch]$PassThru
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DeliveryExternalFileIngest.Common.ps1')

function Invoke-DeliveryExternalFileIngestCore {
	param(
		[Parameter(Mandatory)][string]$ManifestPath,
		[Parameter(Mandatory)][string]$SourceRoot,
		[Parameter(Mandatory)][string]$RepositoryRoot,
		[Parameter(Mandatory)][string]$StagingParent,
		[Parameter(Mandatory)][string]$JournalPath,
		[Parameter(Mandatory)][string]$EvidencePath,
		[Parameter(Mandatory)][string]$SourceCommit,
		[scriptblock]$FaultInjector
	)

	if ($SourceCommit -cnotmatch '^[0-9a-f]{40,64}$') {
		throw '[source_commit_invalid] SourceCommit must be lowercase Git hex.'
	}
	$Repository = (Resolve-Path -LiteralPath $RepositoryRoot).Path
	$Source = (Resolve-Path -LiteralPath $SourceRoot).Path
	$StageParent = (Resolve-Path -LiteralPath $StagingParent).Path
	if (-not [IO.Path]::GetFileName($Source.TrimEnd('\', '/')).Equals(
		'visuals', [StringComparison]::OrdinalIgnoreCase)) {
		throw '[source_root_invalid] SourceRoot must be the standalone visuals directory.'
	}
	foreach ($Directory in @($Repository, $Source, $StageParent)) {
		if (-not (Get-Item -LiteralPath $Directory -Force).PSIsContainer) {
			throw "[path_invalid] '$Directory' must be a directory."
		}
		Assert-DeliveryNoReparsePath -Path $Directory `
			-StopRoot ([IO.Path]::GetPathRoot($Directory))
	}
	if ((Get-DeliveryRepositoryHeadCommit -RepositoryRoot $Repository) -cne
		$SourceCommit) {
		throw '[source_commit_mismatch] SourceCommit must equal repository HEAD.'
	}
	if ((Test-DeliveryPathWithin -Path $Source -Root $Repository) -or
		(Test-DeliveryPathWithin -Path $Repository -Root $Source) -or
		(Test-DeliveryPathWithin -Path $StageParent -Root $Repository) -or
		(Test-DeliveryPathWithin -Path $StageParent -Root $Source) -or
		(Test-DeliveryPathWithin -Path $Source -Root $StageParent)) {
		throw '[path_overlap] Source and staging must be outside the repository and each other.'
	}
	if (-not (Get-DeliveryVolumeRoot $Repository).Equals(
		(Get-DeliveryVolumeRoot $StageParent), [StringComparison]::OrdinalIgnoreCase)) {
		throw '[cross_volume] StagingParent must be on the repository volume.'
	}
	$ManifestFullPath = (Resolve-Path -LiteralPath $ManifestPath).Path
	if ((Test-DeliveryPathWithin -Path $ManifestFullPath -Root $Repository) -or
		(Test-DeliveryPathWithin -Path $ManifestFullPath -Root $Source) -or
		(Test-DeliveryPathWithin -Path $ManifestFullPath -Root $StageParent)) {
		throw '[manifest_path_unsafe] Manifest must be outside repository, source, and staging roots.'
	}
	Assert-DeliveryNoReparsePath -Path $ManifestFullPath `
		-StopRoot ([IO.Path]::GetPathRoot($ManifestFullPath))
	$Journal = [IO.Path]::GetFullPath($JournalPath)
	$Evidence = [IO.Path]::GetFullPath($EvidencePath)
	if ($Journal.Equals($Evidence, [StringComparison]::OrdinalIgnoreCase)) {
		throw '[artifact_path_unsafe] JournalPath and EvidencePath must differ.'
	}
	foreach ($ArtifactPath in @($Journal, $Evidence)) {
		if (Test-Path -LiteralPath $ArtifactPath) {
			throw "[target_exists] '$ArtifactPath' exists."
		}
		if ((Test-DeliveryPathWithin -Path $ArtifactPath -Root $Repository) -or
			(Test-DeliveryPathWithin -Path $ArtifactPath -Root $Source)) {
			throw '[artifact_path_unsafe] Evidence artifacts must be outside source and repository.'
		}
		Assert-DeliveryNoReparsePath -Path $ArtifactPath `
			-StopRoot ([IO.Path]::GetPathRoot($ArtifactPath)) -AllowMissingLeaf
	}

	$Manifest = Read-DeliveryExternalManifest -Path $ManifestFullPath
	$SourceInventory = Get-DeliveryExternalInventory -Root $Source
	Assert-DeliveryInventoryEqual -Expected $Manifest.Records -Actual $SourceInventory
	$Destination = [IO.Path]::GetFullPath((Join-Path $Repository 'visuals'))
	if (Test-Path -LiteralPath $Destination) {
		throw '[target_exists] Repository visuals target already exists.'
	}
	Assert-DeliveryNoReparsePath -Path $Destination -StopRoot $Repository -AllowMissingLeaf
	$ProspectiveEvidence = New-DeliveryIngestEvidenceValue `
		-SourceCommit $SourceCommit -DestinationRoot $Destination `
		-ExternalManifestSha256 $Manifest.Sha256 `
		-JournalSha256 ('0' * 64) -Files $Manifest.Records
	$null = ConvertTo-DeliverySealedJsonBytes -Value $ProspectiveEvidence

	$StagingRoot = Join-Path $StageParent (
		'aetheln-delivery-ingest-' + [guid]::NewGuid().ToString('N')
	)
	$PayloadRoot = Join-Path $StagingRoot 'payload'
	[IO.Directory]::CreateDirectory($PayloadRoot) | Out-Null
	Assert-DeliveryNoReparsePath -Path $PayloadRoot -StopRoot $StageParent

	$CopyIndex = 0
	foreach ($Record in $Manifest.Records) {
		$SourcePath = Join-Path $Source ($Record.path.Replace('/', '\'))
		$StagedPath = Join-Path $PayloadRoot ($Record.path.Replace('/', '\'))
		$StagedParent = [IO.Path]::GetDirectoryName($StagedPath)
		if (-not (Test-Path -LiteralPath $StagedParent)) {
			[IO.Directory]::CreateDirectory($StagedParent) | Out-Null
		}
		Assert-DeliveryNoReparsePath -Path $SourcePath -StopRoot $Source
		Assert-DeliveryDefaultStreamOnly -Path $SourcePath
		$Input = [IO.FileStream]::new(
			$SourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
			[IO.FileShare]::Read, 1048576, [IO.FileOptions]::SequentialScan
		)
		$Output = [IO.FileStream]::new(
			$StagedPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
			[IO.FileShare]::None, 1048576, [IO.FileOptions]::WriteThrough
		)
		try {
			$Input.CopyTo($Output, 1048576)
			$Output.Flush($true)
		}
		finally {
			$Output.Dispose()
			$Input.Dispose()
		}
		$CopyIndex++
		if ($CopyIndex -eq 1) {
			Invoke-DeliveryIngestFault $FaultInjector 'after_first_staged_copy' @{
				SourceRoot = $Source; StagingRoot = $StagingRoot
			}
		}
	}
	$StagedInventory = Get-DeliveryExternalInventory -Root $PayloadRoot
	Assert-DeliveryInventoryEqual -Expected $Manifest.Records -Actual $StagedInventory
	$SourceInventory = Get-DeliveryExternalInventory -Root $Source
	Assert-DeliveryInventoryEqual -Expected $Manifest.Records -Actual $SourceInventory

	Invoke-DeliveryIngestFault $FaultInjector 'before_journal_write' @{
		JournalPath = $Journal
	}
	Assert-DeliveryNoReparsePath -Path $Journal `
		-StopRoot ([IO.Path]::GetPathRoot($Journal)) -AllowMissingLeaf
	$JournalValue = [ordered]@{
		format = 'delivery_external_file_ingest_journal_v1'
		state = 'prepared'
		source_commit = $SourceCommit
		repository_root = $Repository
		source_root = $Source
		staging_root = $StagingRoot
		staged_payload_root = $PayloadRoot
		target_root = 'visuals'
		destination_root = $Destination
		external_manifest_sha256 = $Manifest.Sha256
		expected_inventory_sha256 = Get-DeliveryInventoryHash -Files $Manifest.Records
		files = @($Manifest.Records)
	}
	$JournalSeal = Write-DeliverySealedJson -Value $JournalValue -Path $Journal
	Invoke-DeliveryIngestFault $FaultInjector 'after_journal_seal' @{
		JournalPath = $Journal
	}

	$Moved = $false
	try {
		$SourceInventory = Get-DeliveryExternalInventory -Root $Source
		Assert-DeliveryInventoryEqual -Expected $Manifest.Records -Actual $SourceInventory
		$StagedInventory = Get-DeliveryExternalInventory -Root $PayloadRoot
		Assert-DeliveryInventoryEqual -Expected $Manifest.Records -Actual $StagedInventory
		Invoke-DeliveryIngestFault $FaultInjector 'before_move' @{
			DestinationRoot = $Destination
			StagingRoot = $PayloadRoot
		}
		$StagedInventory = Get-DeliveryExternalInventory -Root $PayloadRoot
		Assert-DeliveryInventoryEqual -Expected $Manifest.Records -Actual $StagedInventory
		Invoke-DeliveryIngestFault $FaultInjector 'after_final_staging_validation' @{
			DestinationRoot = $Destination
			StagingRoot = $PayloadRoot
		}
		if ((Get-DeliveryRepositoryHeadCommit -RepositoryRoot $Repository) -cne
			$SourceCommit) {
			throw '[source_commit_mismatch] Repository HEAD changed before move.'
		}
		if (Test-Path -LiteralPath $Destination) {
			throw '[target_race] Repository visuals target appeared before move.'
		}
		try { [IO.Directory]::Move($PayloadRoot, $Destination) }
		catch {
			if (Test-Path -LiteralPath $Destination) {
				throw '[target_race] Repository visuals target appeared during move.'
			}
			throw
		}
		$Moved = $true
		Invoke-DeliveryIngestFault $FaultInjector 'after_move_before_head_recheck' @{
			DestinationRoot = $Destination
		}
		if ((Get-DeliveryRepositoryHeadCommit -RepositoryRoot $Repository) -cne
			$SourceCommit) {
			throw '[source_commit_mismatch] Repository HEAD changed during move.'
		}
		Invoke-DeliveryIngestFault $FaultInjector 'after_move' @{
			DestinationRoot = $Destination
		}
		Invoke-DeliveryIngestFault $FaultInjector 'before_destination_verification' @{
			DestinationRoot = $Destination
		}
		$FinalInventory = Get-DeliveryExternalInventory -Root $Destination
		Assert-DeliveryInventoryEqual -Expected $Manifest.Records -Actual $FinalInventory
		Invoke-DeliveryIngestFault $FaultInjector 'before_evidence_seal' @{
			EvidencePath = $Evidence
		}
		if ((Get-DeliveryRepositoryHeadCommit -RepositoryRoot $Repository) -cne
			$SourceCommit) {
			throw '[source_commit_mismatch] Repository HEAD changed before evidence seal.'
		}
		Assert-DeliveryNoReparsePath -Path $Evidence `
			-StopRoot ([IO.Path]::GetPathRoot($Evidence)) -AllowMissingLeaf
		$EvidenceValue = New-DeliveryIngestEvidenceValue `
			-SourceCommit $SourceCommit -DestinationRoot $Destination `
			-ExternalManifestSha256 $Manifest.Sha256 `
			-JournalSha256 $JournalSeal.Sha256 -Files $FinalInventory
		$PendingEvidence = $Evidence + '.pending-' + [guid]::NewGuid().ToString('N')
		Assert-DeliveryNoReparsePath -Path $PendingEvidence `
			-StopRoot ([IO.Path]::GetPathRoot($PendingEvidence)) -AllowMissingLeaf
		$PendingSeal = Write-DeliverySealedJson -Value $EvidenceValue `
			-Path $PendingEvidence
		Invoke-DeliveryIngestFault $FaultInjector 'after_evidence_prepare' @{
			EvidencePath = $Evidence
			PendingEvidencePath = $PendingEvidence
		}
		if ((Get-DeliveryRepositoryHeadCommit -RepositoryRoot $Repository) -cne
			$SourceCommit) {
			throw '[source_commit_mismatch] Repository HEAD changed before evidence publish.'
		}
		$PublishInventory = Get-DeliveryExternalInventory -Root $Destination
		Assert-DeliveryInventoryEqual -Expected $FinalInventory -Actual $PublishInventory
		if ((Get-DeliveryInventoryHash -Files $PublishInventory) -cne
			[string]$EvidenceValue.final_inventory_sha256) {
			throw '[inventory_mismatch] Destination changed before evidence publish.'
		}
		if (Test-Path -LiteralPath $Evidence) {
			throw '[target_race] Evidence path appeared before publish.'
		}
		[IO.File]::Move($PendingEvidence, $Evidence)
		$EvidenceSeal = [pscustomobject]@{
			Path = $Evidence
			Sha256 = $PendingSeal.Sha256
		}
		return [pscustomobject][ordered]@{
			Status = 'accepted'
			ExternalManifestSha256 = $Manifest.Sha256
			PreparedJournalPath = $Journal
			PreparedJournalSha256 = $JournalSeal.Sha256
			EvidenceManifestPath = $Evidence
			EvidenceManifestSha256 = $EvidenceSeal.Sha256
			DestinationRoot = $Destination
			ChangedPaths = $EvidenceValue.changed_paths
		}
	}
	catch {
		if (-not $Moved) { throw }
		return [pscustomobject][ordered]@{
			Status = 'ingest_evidence_incomplete'
			ExternalManifestSha256 = $Manifest.Sha256
			PreparedJournalPath = $Journal
			PreparedJournalSha256 = $JournalSeal.Sha256
			EvidenceManifestPath = $null
			EvidenceManifestSha256 = $null
			DestinationRoot = $Destination
			ChangedPaths = @($Manifest.Records | ForEach-Object { 'visuals/' + $_.path })
		}
	}
}

if ($MyInvocation.InvocationName -cne '.') {
	Invoke-DeliveryExternalFileIngestCore `
		-ManifestPath $ManifestPath -SourceRoot $SourceRoot `
		-RepositoryRoot $RepositoryRoot -StagingParent $StagingParent `
		-JournalPath $JournalPath -EvidencePath $EvidencePath `
		-SourceCommit $SourceCommit
}
