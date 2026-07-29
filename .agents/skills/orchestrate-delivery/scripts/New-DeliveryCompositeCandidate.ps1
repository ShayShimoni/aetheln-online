[CmdletBinding()]
param(
	[Parameter(Mandatory)][string]$SourceCommit,
	[Parameter(Mandatory)][string]$ExternalIngestEvidencePath,
	[Parameter(Mandatory)][string]$ExternalIngestEvidenceSha256,
	[Parameter(Mandatory)][string]$ExternalManifestPath,
	[Parameter(Mandatory)][string]$ExternalManifestSha256,
	[Parameter(Mandatory)][string]$PreparedJournalPath,
	[Parameter(Mandatory)][string]$PreparedJournalSha256,
	[Parameter(Mandatory)][string]$TextPatchEvidencePath,
	[Parameter(Mandatory)][string]$TextPatchEvidenceSha256,
	[Parameter(Mandatory)][string]$TextPatchHandoffPath,
	[Parameter(Mandatory)][string]$TextPatchHandoffSha256,
	[Parameter(Mandatory)][string]$RepositoryRoot,
	[Parameter(Mandatory)][string[]]$ChangedPath,
	[Parameter(Mandatory)][string]$OutputPath,
	[Parameter(DontShow)][scriptblock]$FaultInjector,
	[switch]$PassThru
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DeliveryExternalFileIngest.Common.ps1')

function Get-DeliveryCompositePatchPaths {
	param(
		[Parameter(Mandatory)][string]$PatchPath,
		[Parameter(Mandatory)][string]$ExpectedSha256,
		[Parameter(Mandatory)][string]$RepositoryRoot
	)
	$ResolvedPatch = (Resolve-Path -LiteralPath $PatchPath).Path
	if (Test-DeliveryPathWithin -Path $ResolvedPatch -Root $RepositoryRoot) {
		throw '[text_evidence_invalid] Candidate patch must remain outside repository.'
	}
	Assert-DeliveryNoReparsePath -Path $ResolvedPatch `
		-StopRoot ([IO.Path]::GetPathRoot($ResolvedPatch))
	$PatchItem = Get-Item -LiteralPath $ResolvedPatch -Force
	if (-not $PatchItem.IsReadOnly) {
		throw '[text_evidence_invalid] Candidate patch is not read-only.'
	}
	if ((Get-DeliverySha256File -Path $ResolvedPatch) -cne $ExpectedSha256) {
		throw '[text_evidence_tampered] Candidate patch hash differs.'
	}

	$StartInfo = [Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = (Get-Command git -ErrorAction Stop).Source
	$StartInfo.Arguments = '-c core.autocrlf=false apply --numstat -z -- "' +
		$ResolvedPatch.Replace('"', '\"') + '"'
	$StartInfo.UseShellExecute = $false
	$StartInfo.CreateNoWindow = $true
	$StartInfo.RedirectStandardOutput = $true
	$StartInfo.RedirectStandardError = $true
	$StartInfo.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
	$StartInfo.EnvironmentVariables['GIT_CONFIG_GLOBAL'] = 'NUL'
	$StartInfo.EnvironmentVariables['GIT_ATTR_NOSYSTEM'] = '1'
	$Process = [Diagnostics.Process]::new()
	$Output = [IO.MemoryStream]::new()
	try {
		$Process.StartInfo = $StartInfo
		if (-not $Process.Start()) {
			throw '[text_evidence_invalid] Could not start Git patch parser.'
		}
		$OutputTask = $Process.StandardOutput.BaseStream.CopyToAsync($Output)
		$ErrorTask = $Process.StandardError.ReadToEndAsync()
		$Process.WaitForExit()
		[void]$OutputTask.GetAwaiter().GetResult()
		$StandardError = $ErrorTask.GetAwaiter().GetResult()
		if ($Process.ExitCode -ne 0) {
			throw (
				'[text_evidence_invalid] Candidate patch is malformed: ' +
				$StandardError
			)
		}
		$Text = $script:DeliveryUtf8.GetString($Output.ToArray())
	}
	finally {
		$Output.Dispose()
		$Process.Dispose()
	}
	if ((Get-DeliverySha256File -Path $ResolvedPatch) -cne $ExpectedSha256) {
		throw '[text_evidence_tampered] Candidate patch changed during parsing.'
	}

	$Paths = [Collections.Generic.List[string]]::new()
	$Records = $Text.Split([char]0)
	for ($Index = 0; $Index -lt $Records.Count - 1; $Index++) {
		$Columns = $Records[$Index] -split "`t", 3
		if ($Columns.Count -ne 3 -or [string]::IsNullOrEmpty($Columns[2])) {
			throw '[text_evidence_invalid] Rename and copy patches are unsupported.'
		}
		$Paths.Add($Columns[2])
	}
	if ($Paths.Count -lt 1) {
		throw '[text_evidence_invalid] Candidate patch has no paths.'
	}
	return @($Paths)
}

function Get-DeliveryCompositeInventory {
	param(
		[Parameter(Mandatory)][string]$RepositoryRoot,
		[Parameter(Mandatory)][string[]]$Path
	)
	$Result = [Collections.Generic.List[object]]::new()
	foreach ($RelativePath in $Path) {
		$FullPath = [IO.Path]::GetFullPath(
			(Join-Path $RepositoryRoot $RelativePath.Replace('/', '\'))
		)
		if (-not (Test-DeliveryPathWithin -Path $FullPath -Root $RepositoryRoot) -or
			-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
			throw "[inventory_missing] Changed file '$RelativePath' is absent."
		}
		Assert-DeliveryNoReparsePath -Path $FullPath -StopRoot $RepositoryRoot
		$Item = Get-Item -LiteralPath $FullPath -Force
		$Result.Add([pscustomobject][ordered]@{
			path = $RelativePath
			size = [long]$Item.Length
			sha256 = Get-DeliverySha256File -Path $FullPath
		})
	}
	return @($Result)
}

function Assert-DeliveryCompositeInventoryUnchanged {
	param(
		[Parameter(Mandatory)][object[]]$Expected,
		[Parameter(Mandatory)][object[]]$Actual
	)
	try { Assert-DeliveryInventoryEqual -Expected $Expected -Actual $Actual }
	catch {
		throw '[inventory_changed] Repository inventory changed during composite binding.'
	}
}

if ($SourceCommit -cnotmatch '^[0-9a-f]{40,64}$') {
	throw '[source_commit_invalid] SourceCommit must be lowercase Git hex.'
}
$Repository = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$OutputFullPath = [IO.Path]::GetFullPath($OutputPath)
if (Test-DeliveryPathWithin -Path $OutputFullPath -Root $Repository) {
	throw '[artifact_path_unsafe] Composite output must remain outside repository.'
}
Assert-DeliveryNoReparsePath -Path $OutputFullPath `
	-StopRoot ([IO.Path]::GetPathRoot($OutputFullPath)) -AllowMissingLeaf
$External = Test-DeliveryAcceptedIngestEvidence `
	-EvidenceManifestPath $ExternalIngestEvidencePath `
	-ExpectedEvidenceManifestSha256 $ExternalIngestEvidenceSha256 `
	-ExternalManifestPath $ExternalManifestPath `
	-ExpectedExternalManifestSha256 $ExternalManifestSha256 `
	-PreparedJournalPath $PreparedJournalPath `
	-ExpectedPreparedJournalSha256 $PreparedJournalSha256 `
	-ExpectedSourceCommit $SourceCommit -RepositoryRoot $Repository

$HandoffValidator = Join-Path $PSScriptRoot 'Validate-DeliveryHandoff.ps1'
$HandoffSchema = Join-Path (
	Split-Path -Parent $PSScriptRoot
) 'references\handoff-schemas.json'
$TextHandoffFullPath = (Resolve-Path -LiteralPath $TextPatchHandoffPath).Path
if (Test-DeliveryPathWithin -Path $TextHandoffFullPath -Root $Repository) {
	throw '[text_handoff_path] Text-patch handoff must remain outside repository.'
}
Assert-DeliveryNoReparsePath -Path $TextHandoffFullPath `
	-StopRoot ([IO.Path]::GetPathRoot($TextHandoffFullPath))
$TextHandoff = & $HandoffValidator `
	-HandoffPath $TextHandoffFullPath -SchemaPath $HandoffSchema
if ($TextHandoff.HandoffHash -cne $TextPatchHandoffSha256) {
	throw '[text_handoff_tampered] Text-patch handoff hash differs.'
}
if ([string]$TextHandoff.Handoff.source_commit -cne $SourceCommit) {
	throw '[text_handoff_source_commit] Text-patch handoff source commit differs.'
}
if (@('worker', 'integrator', 'fixer') -cnotcontains [string]$TextHandoff.Stage) {
	throw '[text_handoff_stage] Text-patch evidence must belong to a producer stage.'
}

$TextEvidenceScript = Join-Path $PSScriptRoot 'Test-DeliveryEvidence.ps1'
$TextEvidenceFullPath = (Resolve-Path -LiteralPath $TextPatchEvidencePath).Path
if (Test-DeliveryPathWithin -Path $TextEvidenceFullPath -Root $Repository) {
	throw '[text_evidence_path] Text-patch evidence must remain outside repository.'
}
Assert-DeliveryNoReparsePath -Path $TextEvidenceFullPath `
	-StopRoot ([IO.Path]::GetPathRoot($TextEvidenceFullPath))
$TextEvidence = & $TextEvidenceScript `
	-ManifestPath $TextEvidenceFullPath `
	-ExpectedManifestHash $TextPatchEvidenceSha256 `
	-ExpectedHandoffHash $TextPatchHandoffSha256
if ($TextEvidence.Disposition -cne 'accepted') {
	throw '[text_evidence_rejected] Text patch evidence is not accepted.'
}

$NormalizedSet = [Collections.Generic.HashSet[string]]::new(
	[StringComparer]::OrdinalIgnoreCase
)
foreach ($Path in $ChangedPath) {
	$Normalized = Assert-DeliverySafeRelativePath -Path $Path -MaxLength 512
	if (-not $NormalizedSet.Add($Normalized)) {
		throw "[path_collision] Changed path '$Path' is duplicated."
	}
}
$SortedChanged = @(Get-DeliveryOrdinalSortedStrings -Value ([string[]]$NormalizedSet))
$ExternalPaths = @($External.Value.changed_paths)
foreach ($Path in $ExternalPaths) {
	if ($SortedChanged -cnotcontains [string]$Path) {
		throw "[inventory_incomplete] External path '$Path' is omitted."
	}
}
$TextManifestBytes = [IO.File]::ReadAllBytes($TextEvidenceFullPath)
if ((Get-DeliverySha256Bytes -Bytes $TextManifestBytes) -cne
	$TextPatchEvidenceSha256) {
	throw '[text_evidence_tampered] Text evidence hash differs after validation.'
}
try {
	$TextManifestJson = $script:DeliveryUtf8.GetString($TextManifestBytes)
	if ($TextManifestJson.Length -gt 0 -and
		$TextManifestJson[0] -eq [char]0xfeff) {
		$TextManifestJson = $TextManifestJson.Substring(1)
	}
	$TextManifest = $TextManifestJson | ConvertFrom-Json
}
catch {
	throw '[text_evidence_invalid] Text evidence manifest is malformed.'
}
$PatchFiles = @($TextManifest.Files | Where-Object {
	[IO.Path]::GetExtension([string]$_.Path) -ceq '.patch'
})
if ($PatchFiles.Count -ne 1) {
	throw '[text_evidence_invalid] Text evidence must bind exactly one candidate patch.'
}
$PatchPaths = @(Get-DeliveryCompositePatchPaths `
	-PatchPath ([string]$PatchFiles[0].Path) `
	-ExpectedSha256 ([string]$PatchFiles[0].Sha256) `
	-RepositoryRoot $Repository)
$ExpectedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($Path in $ExternalPaths + @($PatchPaths)) {
	if (-not $ExpectedSet.Add([string]$Path)) {
		throw "[path_collision] Candidate path '$Path' is repeated across artifacts."
	}
}
$ExpectedChanged = @(Get-DeliveryOrdinalSortedStrings -Value ([string[]]$ExpectedSet))
if ($ExpectedChanged.Count -ne $SortedChanged.Count) {
	throw '[inventory_incomplete] Changed paths do not match artifact union.'
}
for ($Index = 0; $Index -lt $ExpectedChanged.Count; $Index++) {
	if ($ExpectedChanged[$Index] -cne $SortedChanged[$Index]) {
		throw '[inventory_incomplete] Changed paths do not match artifact union.'
	}
}

$Records = @(Get-DeliveryCompositeInventory `
	-RepositoryRoot $Repository -Path $SortedChanged)
if ($null -ne $FaultInjector) {
	& $FaultInjector 'after_initial_inventory_hash' @{
		RepositoryRoot = $Repository
		ChangedPaths = $SortedChanged
	}
}
$null = Test-DeliveryAcceptedIngestEvidence `
	-EvidenceManifestPath $ExternalIngestEvidencePath `
	-ExpectedEvidenceManifestSha256 $ExternalIngestEvidenceSha256 `
	-ExternalManifestPath $ExternalManifestPath `
	-ExpectedExternalManifestSha256 $ExternalManifestSha256 `
	-PreparedJournalPath $PreparedJournalPath `
	-ExpectedPreparedJournalSha256 $PreparedJournalSha256 `
	-ExpectedSourceCommit $SourceCommit -RepositoryRoot $Repository
$null = & $TextEvidenceScript `
	-ManifestPath $TextEvidenceFullPath `
	-ExpectedManifestHash $TextPatchEvidenceSha256 `
	-ExpectedHandoffHash $TextPatchHandoffSha256
$FinalTextHandoff = & $HandoffValidator `
	-HandoffPath $TextHandoffFullPath -SchemaPath $HandoffSchema
if ($FinalTextHandoff.HandoffHash -cne $TextPatchHandoffSha256 -or
	[string]$FinalTextHandoff.Handoff.source_commit -cne $SourceCommit -or
	@('worker', 'integrator', 'fixer') -cnotcontains
	[string]$FinalTextHandoff.Stage) {
	throw '[text_handoff_tampered] Text-patch handoff changed before sealing.'
}
$ConfirmedRecords = @(Get-DeliveryCompositeInventory `
	-RepositoryRoot $Repository -Path $SortedChanged)
Assert-DeliveryCompositeInventoryUnchanged `
	-Expected $Records -Actual $ConfirmedRecords
$Candidate = [ordered]@{
	format = 'delivery_composite_candidate_v1'
	source_commit = $SourceCommit
	external_ingest_evidence_sha256 = $ExternalIngestEvidenceSha256
	text_patch_evidence_sha256 = $TextPatchEvidenceSha256
	final_inventory_sha256 = Get-DeliveryInventoryHash -Files $ConfirmedRecords
	changed_paths = @($SortedChanged)
}
$Written = Write-DeliverySealedJson -Value $Candidate -Path $OutputFullPath -Atomic
$PostSealRecords = @(Get-DeliveryCompositeInventory `
	-RepositoryRoot $Repository -Path $SortedChanged)
Assert-DeliveryCompositeInventoryUnchanged `
	-Expected $ConfirmedRecords -Actual $PostSealRecords
if ((Get-DeliverySha256File -Path $Written.Path) -cne $Written.Sha256) {
	throw '[composite_tampered] Composite changed while sealing.'
}
[pscustomobject][ordered]@{
	CandidatePath = $Written.Path
	CandidateSha256 = $Written.Sha256
	FinalInventorySha256 = $Candidate.final_inventory_sha256
	ChangedPaths = $SortedChanged
}
