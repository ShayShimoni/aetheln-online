[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Common = Join-Path $ScriptRoot 'scripts\DeliveryExternalFileIngest.Common.ps1'
$Builder = Join-Path $ScriptRoot 'scripts\New-DeliveryCompositeCandidate.ps1'
$Validator = Join-Path $ScriptRoot 'scripts\Test-DeliveryCompositeCandidate.ps1'
$Protect = Join-Path $ScriptRoot 'scripts\Protect-DeliveryEvidence.ps1'
. $Common

$Root = Join-Path ([IO.Path]::GetPathRoot($PSScriptRoot)) (
	'aetheln-delivery-composite-test-' + [guid]::NewGuid().ToString('N')
)
$Repository = Join-Path $Root 'repo'
$Artifacts = Join-Path $Root 'artifacts'
$Results = [Collections.Generic.List[object]]::new()
function Add-Result([string]$Name, [bool]$Passed) {
	$Results.Add([pscustomobject]@{ Name = $Name; Passed = $Passed })
}
function Test-Failure([scriptblock]$Action, [string]$Pattern) {
	try { & $Action | Out-Null; return $false }
	catch { return $_.Exception.Message -match $Pattern }
}
function New-TextHandoff(
	[string]$Path,
	[string]$SourceCommit,
	[string]$RunId
) {
	$Value = [ordered]@{
		schema_version = 1
		stage = 'worker'
		run_id = $RunId
		workspace_root = $Repository
		source_commit = $SourceCommit
		ticket = 'Issue #93'
		acceptance_criteria = @('Produce the governed text patch.')
		canonical_sources = @('AGENTS.md')
		output_contract = 'Return a delivery_file_bundle_v1 artifact.'
		execution_route = 'planned'
		work_package = 'Produce governed text files.'
		allowed_paths = @('docs/**')
		non_goals = @('External binary changes')
		required_checks = @('Validate text patch.')
		baseline_status = ''
		baseline_diff = ''
	}
	[IO.File]::WriteAllText(
		$Path, ($Value | ConvertTo-Json -Depth 12 -Compress),
		[Text.UTF8Encoding]::new($false)
	)
	return [pscustomobject]@{
		Path = $Path
		Sha256 = Get-DeliverySha256File -Path $Path
	}
}

try {
	[IO.Directory]::CreateDirectory((Join-Path $Repository 'visuals')) | Out-Null
	[IO.Directory]::CreateDirectory((Join-Path $Repository 'docs')) | Out-Null
	[IO.Directory]::CreateDirectory($Artifacts) | Out-Null
	& git -C $Repository init --quiet
	& git -C $Repository -c user.name=DeliveryFixture `
		-c user.email=delivery-fixture.invalid `
		commit --allow-empty --quiet -m fixture
	if ($LASTEXITCODE -ne 0) { throw 'Could not create fixture repository commit.' }
	$RepositoryCommit = (& git -C $Repository rev-parse HEAD).Trim()
	[IO.File]::WriteAllText(
		(Join-Path $Repository 'visuals\a.md'), 'visual',
		[Text.UTF8Encoding]::new($false)
	)
	[IO.File]::WriteAllText(
		(Join-Path $Repository 'docs\new.md'), "text`n",
		[Text.UTF8Encoding]::new($false)
	)
	[IO.File]::WriteAllText(
		(Join-Path $Repository 'unrelated.txt'), "outside candidate union`n",
		[Text.UTF8Encoding]::new($false)
	)
	$VisualFiles = Get-DeliveryExternalInventory -Root (Join-Path $Repository 'visuals')
	$ExternalManifestPath = Join-Path $Artifacts 'external-manifest.json'
	$ExternalManifestValue = [ordered]@{
		format = 'delivery_external_file_bundle_v1'
		target_root = 'visuals'
		files = @($VisualFiles | ForEach-Object {
			[ordered]@{
				path = $_.path
				operation = 'create'
				size = $_.size
				sha256 = $_.sha256
			}
		})
	}
	$ExternalManifestSeal = Write-DeliverySealedJson `
		-Value $ExternalManifestValue -Path $ExternalManifestPath
	$FixtureSource = Join-Path $Root 'source\visuals'
	$FixtureStaging = Join-Path $Root 'staging'
	[IO.Directory]::CreateDirectory($FixtureSource) | Out-Null
	[IO.Directory]::CreateDirectory($FixtureStaging) | Out-Null
	$JournalPath = Join-Path $Artifacts 'prepared-journal.json'
	$JournalValue = [ordered]@{
		format = 'delivery_external_file_ingest_journal_v1'
		state = 'prepared'
		source_commit = $RepositoryCommit
		repository_root = $Repository
		source_root = $FixtureSource
		staging_root = $FixtureStaging
		staged_payload_root = Join-Path $FixtureStaging 'payload'
		target_root = 'visuals'
		destination_root = Join-Path $Repository 'visuals'
		external_manifest_sha256 = $ExternalManifestSeal.Sha256
		expected_inventory_sha256 = Get-DeliveryInventoryHash -Files $VisualFiles
		files = @($VisualFiles)
	}
	$JournalSeal = Write-DeliverySealedJson -Value $JournalValue -Path $JournalPath
	$ExternalValue = New-DeliveryIngestEvidenceValue `
		-SourceCommit $RepositoryCommit `
		-DestinationRoot (Join-Path $Repository 'visuals') `
		-ExternalManifestSha256 $ExternalManifestSeal.Sha256 `
		-JournalSha256 $JournalSeal.Sha256 `
		-Files $VisualFiles
	$ExternalPath = Join-Path $Artifacts 'external-evidence.json'
	$ExternalSeal = Write-DeliverySealedJson -Value $ExternalValue `
		-Path $ExternalPath -Atomic

	$PatchPath = Join-Path $Artifacts 'text.patch'
	$Patch = @'
diff --git a/docs/new.md b/docs/new.md
new file mode 100644
--- /dev/null
+++ b/docs/new.md
@@ -0,0 +1 @@
+text
'@
	[IO.File]::WriteAllText($PatchPath, $Patch + "`n", [Text.UTF8Encoding]::new($false))
	$TextHandoff = New-TextHandoff `
		-Path (Join-Path $Artifacts 'text-handoff.json') `
		-SourceCommit $RepositoryCommit -RunId 'composite-text-worker'
	$TextManifestPath = Join-Path $Artifacts 'text-evidence.json'
	$TextEvidence = & $Protect -EvidencePaths @($PatchPath) `
		-ManifestPath $TextManifestPath -HandoffHash $TextHandoff.Sha256 `
		-Disposition accepted
	$CandidatePath = Join-Path $Artifacts 'composite.json'
	$Candidate = & $Builder -SourceCommit $RepositoryCommit `
		-ExternalIngestEvidencePath $ExternalPath `
		-ExternalIngestEvidenceSha256 $ExternalSeal.Sha256 `
		-ExternalManifestPath $ExternalManifestPath `
		-ExternalManifestSha256 $ExternalManifestSeal.Sha256 `
		-PreparedJournalPath $JournalPath `
		-PreparedJournalSha256 $JournalSeal.Sha256 `
		-TextPatchEvidencePath $TextManifestPath `
		-TextPatchEvidenceSha256 $TextEvidence.ManifestHash `
		-TextPatchHandoffPath $TextHandoff.Path `
		-TextPatchHandoffSha256 $TextHandoff.Sha256 -RepositoryRoot $Repository `
		-ChangedPath @('docs/new.md', 'visuals/a.md') -OutputPath $CandidatePath
	$Validated = & $Validator -CandidatePath $CandidatePath `
		-ExpectedCandidateSha256 $Candidate.CandidateSha256 `
		-SourceCommit $RepositoryCommit `
		-ExternalIngestEvidenceSha256 $ExternalSeal.Sha256 `
		-TextPatchEvidenceSha256 $TextEvidence.ManifestHash `
		-RepositoryRoot $Repository
	Add-Result 'Builds and validates a composite candidate' (
		$Validated.ChangedPaths.Count -eq 2
	)
	Add-Result 'Composite inventory scope is the exact artifact union' (
		$Validated.ChangedPaths.Count -eq 2 -and
		$Validated.ChangedPaths -cnotcontains 'unrelated.txt'
	)
	Add-Result 'Runtime rejects Windows-unsafe composite paths' (
		(Test-Failure {
			Assert-DeliverySafeRelativePath -Path 'CON.md'
		} 'path_unsafe') -and
		(Test-Failure {
			Assert-DeliverySafeRelativePath -Path 'docs/bad?name.md'
		} 'path_unsafe') -and
		(Test-Failure {
			Assert-DeliverySafeRelativePath -Path 'docs/trailing.'
		} 'path_unsafe')
	)
	$TextFilePath = Join-Path $Repository 'docs\new.md'
	$OriginalTextBytes = [IO.File]::ReadAllBytes($TextFilePath)
	$InventoryMutationFault = {
		param($Checkpoint, $Context)
		if ($Checkpoint -ceq 'after_initial_inventory_hash') {
			[IO.File]::WriteAllText(
				(Join-Path $Context.RepositoryRoot 'docs\new.md'),
				"mutated`n", [Text.UTF8Encoding]::new($false)
			)
		}
	}
	$RaceCandidatePath = Join-Path $Artifacts 'inventory-race-composite.json'
	$BuilderRaceRejected = Test-Failure {
		& $Builder -SourceCommit $RepositoryCommit `
			-ExternalIngestEvidencePath $ExternalPath `
			-ExternalIngestEvidenceSha256 $ExternalSeal.Sha256 `
			-ExternalManifestPath $ExternalManifestPath `
			-ExternalManifestSha256 $ExternalManifestSeal.Sha256 `
			-PreparedJournalPath $JournalPath `
			-PreparedJournalSha256 $JournalSeal.Sha256 `
			-TextPatchEvidencePath $TextManifestPath `
			-TextPatchEvidenceSha256 $TextEvidence.ManifestHash `
			-TextPatchHandoffPath $TextHandoff.Path `
			-TextPatchHandoffSha256 $TextHandoff.Sha256 `
			-RepositoryRoot $Repository `
			-ChangedPath @('docs/new.md', 'visuals/a.md') `
			-OutputPath $RaceCandidatePath `
			-FaultInjector $InventoryMutationFault
	} 'inventory_changed'
	Add-Result 'Rejects repository mutation after initial composite hash' (
		$BuilderRaceRejected -and -not (Test-Path -LiteralPath $RaceCandidatePath)
	)
	[IO.File]::WriteAllBytes($TextFilePath, $OriginalTextBytes)
	$ValidatorRaceRejected = Test-Failure {
		& $Validator -CandidatePath $CandidatePath `
			-ExpectedCandidateSha256 $Candidate.CandidateSha256 `
			-SourceCommit $RepositoryCommit `
			-ExternalIngestEvidenceSha256 $ExternalSeal.Sha256 `
			-TextPatchEvidenceSha256 $TextEvidence.ManifestHash `
			-RepositoryRoot $Repository `
			-FaultInjector $InventoryMutationFault
	} 'composite_inventory'
	Add-Result 'Validator rejects mutation after its initial inventory hash' (
		$ValidatorRaceRejected
	)
	[IO.File]::WriteAllBytes($TextFilePath, $OriginalTextBytes)
	$UnicodeRelativePath = 'docs/caf' + [char]0x00e9 + '.md'
	[IO.File]::WriteAllText(
		(Join-Path $Repository $UnicodeRelativePath.Replace('/', '\')), "text`n",
		[Text.UTF8Encoding]::new($false)
	)
	$UnicodePatchPath = Join-Path $Artifacts 'unicode-text.patch'
	$UnicodePatch = @'
diff --git "a/docs/caf\303\251.md" "b/docs/caf\303\251.md"
new file mode 100644
--- /dev/null
+++ "b/docs/caf\303\251.md"
@@ -0,0 +1 @@
+text
'@
	[IO.File]::WriteAllText(
		$UnicodePatchPath, $UnicodePatch + "`n", [Text.UTF8Encoding]::new($false)
	)
	$UnicodeHandoff = New-TextHandoff `
		-Path (Join-Path $Artifacts 'unicode-text-handoff.json') `
		-SourceCommit $RepositoryCommit -RunId 'composite-unicode-worker'
	$UnicodeManifestPath = Join-Path $Artifacts 'unicode-text-evidence.json'
	$UnicodeEvidence = & $Protect -EvidencePaths @($UnicodePatchPath) `
		-ManifestPath $UnicodeManifestPath -HandoffHash $UnicodeHandoff.Sha256 `
		-Disposition accepted
	$UnicodeCandidate = & $Builder -SourceCommit $RepositoryCommit `
		-ExternalIngestEvidencePath $ExternalPath `
		-ExternalIngestEvidenceSha256 $ExternalSeal.Sha256 `
		-ExternalManifestPath $ExternalManifestPath `
		-ExternalManifestSha256 $ExternalManifestSeal.Sha256 `
		-PreparedJournalPath $JournalPath `
		-PreparedJournalSha256 $JournalSeal.Sha256 `
		-TextPatchEvidencePath $UnicodeManifestPath `
		-TextPatchEvidenceSha256 $UnicodeEvidence.ManifestHash `
		-TextPatchHandoffPath $UnicodeHandoff.Path `
		-TextPatchHandoffSha256 $UnicodeHandoff.Sha256 -RepositoryRoot $Repository `
		-ChangedPath @($UnicodeRelativePath, 'visuals/a.md') `
		-OutputPath (Join-Path $Artifacts 'unicode-composite.json')
	Add-Result 'Parses Git-quoted Unicode patch paths without regex ambiguity' (
		$UnicodeCandidate.ChangedPaths -ccontains $UnicodeRelativePath
	)
	Add-Result 'Rejects external evidence hash tampering' (
		Test-Failure {
			& $Builder -SourceCommit $RepositoryCommit `
				-ExternalIngestEvidencePath $ExternalPath `
				-ExternalIngestEvidenceSha256 ('0' * 64) `
				-ExternalManifestPath $ExternalManifestPath `
				-ExternalManifestSha256 $ExternalManifestSeal.Sha256 `
				-PreparedJournalPath $JournalPath `
				-PreparedJournalSha256 $JournalSeal.Sha256 `
				-TextPatchEvidencePath $TextManifestPath `
				-TextPatchEvidenceSha256 $TextEvidence.ManifestHash `
				-TextPatchHandoffPath $TextHandoff.Path `
				-TextPatchHandoffSha256 $TextHandoff.Sha256 `
				-RepositoryRoot $Repository `
				-ChangedPath @('docs/new.md', 'visuals/a.md') `
				-OutputPath (Join-Path $Artifacts 'bad-external.json')
		} 'evidence_tampered'
	)
	Add-Result 'Rejects text evidence hash tampering' (
		Test-Failure {
			& $Builder -SourceCommit $RepositoryCommit `
				-ExternalIngestEvidencePath $ExternalPath `
				-ExternalIngestEvidenceSha256 $ExternalSeal.Sha256 `
				-ExternalManifestPath $ExternalManifestPath `
				-ExternalManifestSha256 $ExternalManifestSeal.Sha256 `
				-PreparedJournalPath $JournalPath `
				-PreparedJournalSha256 $JournalSeal.Sha256 `
				-TextPatchEvidencePath $TextManifestPath `
				-TextPatchEvidenceSha256 ('0' * 64) `
				-TextPatchHandoffPath $TextHandoff.Path `
				-TextPatchHandoffSha256 $TextHandoff.Sha256 `
				-RepositoryRoot $Repository `
				-ChangedPath @('docs/new.md', 'visuals/a.md') `
				-OutputPath (Join-Path $Artifacts 'bad-text.json')
		} 'expected hash'
	)
	Add-Result 'Rejects source commit mismatch' (
		Test-Failure {
			& $Builder -SourceCommit ('f' * 40) `
				-ExternalIngestEvidencePath $ExternalPath `
				-ExternalIngestEvidenceSha256 $ExternalSeal.Sha256 `
				-ExternalManifestPath $ExternalManifestPath `
				-ExternalManifestSha256 $ExternalManifestSeal.Sha256 `
				-PreparedJournalPath $JournalPath `
				-PreparedJournalSha256 $JournalSeal.Sha256 `
				-TextPatchEvidencePath $TextManifestPath `
				-TextPatchEvidenceSha256 $TextEvidence.ManifestHash `
				-TextPatchHandoffPath $TextHandoff.Path `
				-TextPatchHandoffSha256 $TextHandoff.Sha256 `
				-RepositoryRoot $Repository `
				-ChangedPath @('docs/new.md', 'visuals/a.md') `
				-OutputPath (Join-Path $Artifacts 'bad-commit.json')
		} 'journal_invalid|evidence_invalid'
	)
	Add-Result 'Rejects incomplete changed-path inventory' (
		Test-Failure {
			& $Builder -SourceCommit $RepositoryCommit `
				-ExternalIngestEvidencePath $ExternalPath `
				-ExternalIngestEvidenceSha256 $ExternalSeal.Sha256 `
				-ExternalManifestPath $ExternalManifestPath `
				-ExternalManifestSha256 $ExternalManifestSeal.Sha256 `
				-PreparedJournalPath $JournalPath `
				-PreparedJournalSha256 $JournalSeal.Sha256 `
				-TextPatchEvidencePath $TextManifestPath `
				-TextPatchEvidenceSha256 $TextEvidence.ManifestHash `
				-TextPatchHandoffPath $TextHandoff.Path `
				-TextPatchHandoffSha256 $TextHandoff.Sha256 `
				-RepositoryRoot $Repository `
				-ChangedPath @('visuals/a.md') `
				-OutputPath (Join-Path $Artifacts 'bad-paths.json')
		} 'scope|inventory'
	)
	$RepositoryCompositePath = Join-Path $Repository 'composite.json'
	Add-Result 'Rejects a repository-contained composite output' (
		(Test-Failure {
			& $Builder -SourceCommit $RepositoryCommit `
				-ExternalIngestEvidencePath $ExternalPath `
				-ExternalIngestEvidenceSha256 $ExternalSeal.Sha256 `
				-ExternalManifestPath $ExternalManifestPath `
				-ExternalManifestSha256 $ExternalManifestSeal.Sha256 `
				-PreparedJournalPath $JournalPath `
				-PreparedJournalSha256 $JournalSeal.Sha256 `
				-TextPatchEvidencePath $TextManifestPath `
				-TextPatchEvidenceSha256 $TextEvidence.ManifestHash `
				-TextPatchHandoffPath $TextHandoff.Path `
				-TextPatchHandoffSha256 $TextHandoff.Sha256 `
				-RepositoryRoot $Repository `
				-ChangedPath @('docs/new.md', 'visuals/a.md') `
				-OutputPath $RepositoryCompositePath
		} 'artifact_path_unsafe') -and
		-not (Test-Path -LiteralPath $RepositoryCompositePath)
	)
	$WrongHandoff = New-TextHandoff `
		-Path (Join-Path $Artifacts 'wrong-source-handoff.json') `
		-SourceCommit ('f' * 40) -RunId 'composite-wrong-source-worker'
	$WrongTextManifestPath = Join-Path $Artifacts 'wrong-source-text-evidence.json'
	$WrongTextEvidence = & $Protect -EvidencePaths @($PatchPath) `
		-ManifestPath $WrongTextManifestPath -HandoffHash $WrongHandoff.Sha256 `
		-Disposition accepted
	Add-Result 'Rejects text evidence from a different source commit' (
		Test-Failure {
			& $Builder -SourceCommit $RepositoryCommit `
				-ExternalIngestEvidencePath $ExternalPath `
				-ExternalIngestEvidenceSha256 $ExternalSeal.Sha256 `
				-ExternalManifestPath $ExternalManifestPath `
				-ExternalManifestSha256 $ExternalManifestSeal.Sha256 `
				-PreparedJournalPath $JournalPath `
				-PreparedJournalSha256 $JournalSeal.Sha256 `
				-TextPatchEvidencePath $WrongTextManifestPath `
				-TextPatchEvidenceSha256 $WrongTextEvidence.ManifestHash `
				-TextPatchHandoffPath $WrongHandoff.Path `
				-TextPatchHandoffSha256 $WrongHandoff.Sha256 `
				-RepositoryRoot $Repository `
				-ChangedPath @('docs/new.md', 'visuals/a.md') `
				-OutputPath (Join-Path $Artifacts 'bad-source-evidence.json')
		} 'text_handoff_source_commit'
	)
	(Get-Item -LiteralPath $CandidatePath -Force).IsReadOnly = $false
	[IO.File]::AppendAllText($CandidatePath, ' ')
	Add-Result 'Rejects composite-manifest tampering' (
		Test-Failure {
			& $Validator -CandidatePath $CandidatePath `
				-ExpectedCandidateSha256 $Candidate.CandidateSha256 `
				-SourceCommit $RepositoryCommit `
				-ExternalIngestEvidenceSha256 $ExternalSeal.Sha256 `
				-TextPatchEvidenceSha256 $TextEvidence.ManifestHash `
				-RepositoryRoot $Repository
		} 'unsealed|tampered'
	)
}
finally {
	if (Test-Path -LiteralPath $Root) {
		Get-ChildItem -LiteralPath $Root -Recurse -Force |
			Where-Object { -not $_.PSIsContainer } |
			ForEach-Object { $_.IsReadOnly = $false }
		Remove-Item -LiteralPath $Root -Recurse -Force
	}
}

$Failed = @($Results | Where-Object { -not $_.Passed })
$Results | Format-Table -AutoSize
if ($Failed.Count -gt 0) { throw "$($Failed.Count) composite tests failed." }
"All $($Results.Count) composite tests passed."
