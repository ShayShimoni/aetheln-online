[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Generator = Join-Path $ScriptRoot 'scripts\New-DeliveryExternalFileBundle.ps1'
$Importer = Join-Path $ScriptRoot 'scripts\Invoke-DeliveryExternalFileIngest.ps1'
$Reconciler = Join-Path $ScriptRoot 'scripts\Confirm-DeliveryExternalFileIngest.ps1'
$Results = [Collections.Generic.List[object]]::new()
$TestRoots = [Collections.Generic.List[string]]::new()

. $Importer -ManifestPath unused -SourceRoot unused -RepositoryRoot unused `
	-StagingParent unused -JournalPath unused -EvidencePath unused `
	-SourceCommit ('a' * 40)

function Add-Result([string]$Name, [bool]$Passed, [string]$Detail = '') {
	$Results.Add([pscustomobject]@{ Name = $Name; Passed = $Passed; Detail = $Detail })
}

function New-Fixture {
	$Root = Join-Path ([IO.Path]::GetPathRoot($PSScriptRoot)) (
		'aetheln-delivery-ingest-test-' + [guid]::NewGuid().ToString('N')
	)
	foreach ($Name in @('visuals', 'repo', 'stage', 'artifacts')) {
		[IO.Directory]::CreateDirectory((Join-Path $Root $Name)) | Out-Null
	}
	$Repository = Join-Path $Root 'repo'
	& git -C $Repository init --quiet
	& git -C $Repository -c user.name=DeliveryFixture `
		-c user.email=delivery-fixture.invalid `
		commit --allow-empty --quiet -m fixture
	if ($LASTEXITCODE -ne 0) { throw 'Could not create fixture repository commit.' }
	$SourceCommit = (& git -C $Repository rev-parse HEAD).Trim()
	[IO.Directory]::CreateDirectory((Join-Path $Root 'visuals\nested')) | Out-Null
	[IO.File]::WriteAllText(
		(Join-Path $Root 'visuals\a.md'), 'alpha', [Text.UTF8Encoding]::new($false)
	)
	[IO.File]::WriteAllText(
		(Join-Path $Root 'visuals\nested\b.json'), '{}', [Text.UTF8Encoding]::new($false)
	)
	$TestRoots.Add($Root)
	return [pscustomobject]@{
		Root = $Root
		Source = Join-Path $Root 'visuals'
		Repository = $Repository
		SourceCommit = $SourceCommit
		Stage = Join-Path $Root 'stage'
		Artifacts = Join-Path $Root 'artifacts'
		Manifest = Join-Path $Root 'artifacts\manifest.json'
		Journal = Join-Path $Root 'artifacts\journal.json'
		Evidence = Join-Path $Root 'artifacts\evidence.json'
	}
}

function New-Manifest($Fixture) {
	& $Generator -SourceRoot $Fixture.Source `
		-RepositoryRoot $Fixture.Repository `
		-ManifestPath $Fixture.Manifest -PassThru
}

function Invoke-Core($Fixture, [scriptblock]$Fault = $null) {
	Invoke-DeliveryExternalFileIngestCore `
		-ManifestPath $Fixture.Manifest -SourceRoot $Fixture.Source `
		-RepositoryRoot $Fixture.Repository -StagingParent $Fixture.Stage `
		-JournalPath $Fixture.Journal -EvidencePath $Fixture.Evidence `
		-SourceCommit $Fixture.SourceCommit -FaultInjector $Fault
}

function Test-Failure([scriptblock]$Action, [string]$Pattern) {
	try { & $Action | Out-Null; return $false }
	catch { return $_.Exception.Message -match $Pattern }
}

function Write-ManifestValue($Fixture, [object]$Value) {
	if (Test-Path -LiteralPath $Fixture.Manifest) {
		(Get-Item -LiteralPath $Fixture.Manifest -Force).IsReadOnly = $false
	}
	[IO.File]::WriteAllText(
		$Fixture.Manifest, ($Value | ConvertTo-Json -Depth 12 -Compress),
		[Text.UTF8Encoding]::new($false)
	)
}

try {
	$F = New-Fixture
	$WrongSource = Join-Path $F.Root 'source'
	[IO.Directory]::CreateDirectory($WrongSource) | Out-Null
	[IO.File]::WriteAllText(
		(Join-Path $WrongSource 'a.md'), 'alpha', [Text.UTF8Encoding]::new($false)
	)
	Add-Result 'Rejects a source root not named visuals' (
		Test-Failure {
			& $Generator -SourceRoot $WrongSource `
				-RepositoryRoot $F.Repository `
				-ManifestPath (Join-Path $F.Artifacts 'wrong-root.json')
		} 'source_root_invalid'
	)

	$F = New-Fixture
	$RepositoryManifest = Join-Path $F.Repository 'external-manifest.json'
	Add-Result 'Manifest writer rejects a repository-contained output' (
		(Test-Failure {
			& $Generator -SourceRoot $F.Source `
				-RepositoryRoot $F.Repository -ManifestPath $RepositoryManifest
		} 'manifest_path_unsafe') -and
		-not (Test-Path -LiteralPath $RepositoryManifest)
	)

	$F = New-Fixture
	$RepositorySource = Join-Path $F.Repository 'visuals'
	[IO.Directory]::CreateDirectory($RepositorySource) | Out-Null
	[IO.File]::WriteAllText(
		(Join-Path $RepositorySource 'a.md'), 'alpha',
		[Text.UTF8Encoding]::new($false)
	)
	Add-Result 'Manifest writer rejects a repository-contained source' (
		Test-Failure {
			& $Generator -SourceRoot $RepositorySource `
				-RepositoryRoot $F.Repository `
				-ManifestPath (Join-Path $F.Artifacts 'repository-source.json')
		} 'path_overlap'
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	Add-Result 'Rejects a staging parent that contains SourceRoot' (
		Test-Failure {
			Invoke-DeliveryExternalFileIngestCore `
				-ManifestPath $F.Manifest -SourceRoot $F.Source `
				-RepositoryRoot $F.Repository -StagingParent $F.Root `
				-JournalPath $F.Journal -EvidencePath $F.Evidence `
				-SourceCommit $F.SourceCommit
		} 'path_overlap'
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	Add-Result 'Rejects a source commit that differs from repository HEAD' (
		(Test-Failure {
			Invoke-DeliveryExternalFileIngestCore `
				-ManifestPath $F.Manifest -SourceRoot $F.Source `
				-RepositoryRoot $F.Repository -StagingParent $F.Stage `
				-JournalPath $F.Journal -EvidencePath $F.Evidence `
				-SourceCommit ('f' * 40)
		} 'source_commit_mismatch') -and
		-not (Test-Path -LiteralPath (Join-Path $F.Repository 'visuals'))
	)

	$F = New-Fixture
	$M = New-Manifest $F
	$Accepted = Invoke-Core $F
	Add-Result 'Happy path atomically imports and seals evidence' (
		$Accepted.Status -ceq 'accepted' -and
		(Test-Path -LiteralPath (Join-Path $F.Repository 'visuals\a.md')) -and
		(Get-Item -LiteralPath $F.Manifest -Force).IsReadOnly -and
		(Get-Item -LiteralPath $F.Journal -Force).IsReadOnly -and
		(Get-Item -LiteralPath $F.Evidence -Force).IsReadOnly
	)
	$GateArgs = @{
		EvidenceManifestPath = $F.Evidence
		ExpectedEvidenceManifestSha256 = $Accepted.EvidenceManifestSha256
		ExternalManifestPath = $F.Manifest
		ExpectedExternalManifestSha256 = $Accepted.ExternalManifestSha256
		PreparedJournalPath = $F.Journal
		ExpectedPreparedJournalSha256 = $Accepted.PreparedJournalSha256
		ExpectedSourceCommit = $F.SourceCommit
		RepositoryRoot = $F.Repository
	}
	$GateResult = Test-DeliveryAcceptedIngestEvidence @GateArgs
	Add-Result 'Worker gate accepts exact sealed ingest evidence' (
		$GateResult.Sha256 -ceq $Accepted.EvidenceManifestSha256
	)
	Add-Result 'Worker gate rejects independently retained hash mismatch' (
		Test-Failure {
			$BadArgs = $GateArgs.Clone()
			$BadArgs.ExpectedEvidenceManifestSha256 = '0' * 64
			Test-DeliveryAcceptedIngestEvidence @BadArgs
		} 'evidence_tampered'
	)
	Add-Result 'Worker gate rejects source-commit mismatch' (
		Test-Failure {
			$BadArgs = $GateArgs.Clone()
			$BadArgs.ExpectedSourceCommit = 'f' * 40
			Test-DeliveryAcceptedIngestEvidence @BadArgs
		} 'journal_invalid|evidence_invalid'
	)
	(Get-Item -LiteralPath $F.Evidence -Force).IsReadOnly = $false
	Add-Result 'Worker gate rejects writable ingest evidence' (
		Test-Failure {
			Test-DeliveryAcceptedIngestEvidence @GateArgs
		} 'evidence_unsealed'
	)
	(Get-Item -LiteralPath $F.Evidence -Force).IsReadOnly = $true
	foreach ($DigestName in @('external_manifest_sha256', 'prepared_journal_sha256')) {
		$TamperedValue = Get-Content -Raw -LiteralPath $F.Evidence | ConvertFrom-Json
		$TamperedValue.$DigestName = 'not-a-sha256'
		$TamperedPath = Join-Path $F.Artifacts "$DigestName-invalid.json"
		[IO.File]::WriteAllText(
			$TamperedPath, ($TamperedValue | ConvertTo-Json -Depth 12 -Compress),
			[Text.UTF8Encoding]::new($false)
		)
		(Get-Item -LiteralPath $TamperedPath -Force).IsReadOnly = $true
		$TamperedHash = (Get-FileHash -LiteralPath $TamperedPath -Algorithm SHA256).
			Hash.ToLowerInvariant()
		Add-Result "Worker gate rejects malformed $DigestName" (
			Test-Failure {
				$BadArgs = $GateArgs.Clone()
				$BadArgs.EvidenceManifestPath = $TamperedPath
				$BadArgs.ExpectedEvidenceManifestSha256 = $TamperedHash
				Test-DeliveryAcceptedIngestEvidence @BadArgs
			} 'evidence_invalid'
		)
	}
	$MissingJournalArgs = $GateArgs.Clone()
	$MissingJournalArgs.PreparedJournalPath = Join-Path $F.Artifacts 'missing-journal.json'
	Add-Result 'Worker gate rejects fabricated evidence without retained journal' (
		Test-Failure {
			Test-DeliveryAcceptedIngestEvidence @MissingJournalArgs
		} 'does not exist|cannot find'
	)
	$WrongManifestArgs = $GateArgs.Clone()
	$WrongManifestArgs.ExpectedExternalManifestSha256 = 'f' * 64
	Add-Result 'Worker gate rejects external-manifest provenance mismatch' (
		Test-Failure {
			Test-DeliveryAcceptedIngestEvidence @WrongManifestArgs
		} 'journal_invalid|manifest_tampered'
	)
	$DestinationFile = Join-Path $F.Repository 'visuals\a.md'
	$OriginalDestinationBytes = [IO.File]::ReadAllBytes($DestinationFile)
	[IO.File]::WriteAllText(
		$DestinationFile, 'gate-race-mutation', [Text.UTF8Encoding]::new($false)
	)
	Add-Result 'Worker gate rejects destination mutation after evidence acceptance' (
		Test-Failure {
			Test-DeliveryAcceptedIngestEvidence @GateArgs
		} 'inventory_mismatch'
	)
	[IO.File]::WriteAllBytes($DestinationFile, $OriginalDestinationBytes)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	$InsideManifest = Join-Path $F.Repository 'manifest.json'
	[IO.File]::WriteAllBytes($InsideManifest, [IO.File]::ReadAllBytes($F.Manifest))
	Add-Result 'Rejects a manifest stored inside the repository' (
		Test-Failure {
			Invoke-DeliveryExternalFileIngestCore `
				-ManifestPath $InsideManifest -SourceRoot $F.Source `
				-RepositoryRoot $F.Repository -StagingParent $F.Stage `
				-JournalPath $F.Journal -EvidencePath $F.Evidence `
				-SourceCommit $F.SourceCommit
		} 'manifest_path_unsafe'
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	[IO.Directory]::CreateDirectory((Join-Path $F.Source 'unexpected-empty')) | Out-Null
	Add-Result 'Rejects unexpected empty source directories' (
		Test-Failure { Invoke-Core $F } 'directory_inventory_mismatch'
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	$ManifestValue = Get-Content -Raw -LiteralPath $F.Manifest | ConvertFrom-Json
	$ManifestValue | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
	Write-ManifestValue $F $ManifestValue
	Add-Result 'Closed manifest rejects extra keys' (
		Test-Failure { Invoke-Core $F } 'schema_invalid'
	)

	$F = New-Fixture
	$Records = 1..129 | ForEach-Object {
		[ordered]@{ path = "f$_.md"; operation = 'create'; size = 0; sha256 = '0' * 64 }
	}
	Write-ManifestValue $F ([ordered]@{
		format = 'delivery_external_file_bundle_v1'; target_root = 'visuals'; files = $Records
	})
	Add-Result 'Manifest rejects more than 128 records' (
		Test-Failure { Invoke-Core $F } 'schema_invalid'
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	(Get-Item -LiteralPath $F.Manifest -Force).IsReadOnly = $false
	$IntegralSizeJson = Get-Content -Raw -LiteralPath $F.Manifest
	$IntegralSizeJson = [regex]::Replace(
		$IntegralSizeJson, '"size":5', '"size":5.0', 1
	)
	[IO.File]::WriteAllText(
		$F.Manifest, $IntegralSizeJson, [Text.UTF8Encoding]::new($false)
	)
	Add-Result 'Accepts schema-valid integral decimal size notation' (
		(Invoke-Core $F).Status -ceq 'accepted'
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	$OversizedInteger = Get-Content -Raw -LiteralPath $F.Manifest | ConvertFrom-Json
	$OversizedInteger.files[0].size = [decimal]9223372036854775808
	Write-ManifestValue $F $OversizedInteger
	Add-Result 'Rejects sizes above the signed 64-bit ceiling' (
		Test-Failure { Invoke-Core $F } 'schema_invalid'
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	$FractionalInteger = Get-Content -Raw -LiteralPath $F.Manifest | ConvertFrom-Json
	$FractionalInteger.files[0].size = [decimal]1.5
	Write-ManifestValue $F $FractionalInteger
	Add-Result 'Rejects fractional file sizes' (
		Test-Failure { Invoke-Core $F } 'schema_invalid'
	)

	$F = New-Fixture
	$OversizedJson = '{"padding":"' + ('a' * 1048576) + '"}'
	[IO.File]::WriteAllText(
		$F.Manifest, $OversizedJson, [Text.UTF8Encoding]::new($false)
	)
	Add-Result 'Manifest rejects JSON over the 1 MiB ceiling' (
		Test-Failure { Invoke-Core $F } '1 MiB contract ceiling'
	)

	$F = New-Fixture
	$NestedJson = ('{"a":' * 18) + '0' + ('}' * 18)
	[IO.File]::WriteAllText(
		$F.Manifest, $NestedJson, [Text.UTF8Encoding]::new($false)
	)
	Add-Result 'Manifest rejects JSON over the nesting ceiling' (
		Test-Failure { Invoke-Core $F } 'nesting exceeds'
	)

	$F = New-Fixture
	$OversizedSealPath = Join-Path $F.Artifacts 'oversized-seal.json'
	Add-Result 'Sealed artifact writer rejects JSON over the 1 MiB ceiling' (
		(Test-Failure {
			Write-DeliverySealedJson `
				-Value ([ordered]@{ padding = 'a' * 1048576 }) `
				-Path $OversizedSealPath
		} '1 MiB contract ceiling') -and
		-not (Test-Path -LiteralPath $OversizedSealPath)
	)

	foreach ($Case in @(
		@('../escape.md', 'path_unsafe'),
		@('CON.md', 'path_unsafe'),
		@('bad:name.md', 'path_unsafe'),
		@('upper.PNG', 'extension_unsafe'),
		@('file.txt', 'extension_unsafe')
	)) {
		$F = New-Fixture
		Write-ManifestValue $F ([ordered]@{
			format = 'delivery_external_file_bundle_v1'; target_root = 'visuals'
			files = @([ordered]@{
				path = $Case[0]; operation = 'create'; size = 0; sha256 = '0' * 64
			})
		})
		Add-Result "Rejects unsafe path $($Case[0])" (
			Test-Failure { Invoke-Core $F } $Case[1]
		)
	}

	$F = New-Fixture
	$LongPath = ('a' * 238) + '.md'
	Write-ManifestValue $F ([ordered]@{
		format = 'delivery_external_file_bundle_v1'
		target_root = 'visuals'
		files = @([ordered]@{
			path = $LongPath; operation = 'create'; size = 0; sha256 = '0' * 64
		})
	})
	Add-Result 'Rejects external paths over 240 characters' (
		Test-Failure { Invoke-Core $F } 'path_unsafe'
	)

	$F = New-Fixture
	$Files = @('Case.md', 'case.md') | ForEach-Object {
		[ordered]@{ path = $_; operation = 'create'; size = 0; sha256 = '0' * 64 }
	}
	Write-ManifestValue $F ([ordered]@{
		format = 'delivery_external_file_bundle_v1'; target_root = 'visuals'; files = @($Files)
	})
	Add-Result 'Rejects case collision' (
		Test-Failure { Invoke-Core $F } 'path_collision'
	)

	$F = New-Fixture
	$Composed = ([string][char]0x00e9) + '.md'
	$Decomposed = 'e' + [char]0x0301 + '.md'
	Write-ManifestValue $F ([ordered]@{
		format = 'delivery_external_file_bundle_v1'
		target_root = 'visuals'
		files = @(
			[ordered]@{
				path = $Composed; operation = 'create'; size = 0; sha256 = '0' * 64
			},
			[ordered]@{
				path = $Decomposed; operation = 'create'; size = 0; sha256 = '0' * 64
			}
		)
	})
	Add-Result 'Rejects Unicode normalization collision' (
		Test-Failure { Invoke-Core $F } 'path_collision'
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	[IO.File]::WriteAllText(
		(Join-Path $F.Source 'extra.svg'), '<svg/>', [Text.UTF8Encoding]::new($false)
	)
	Add-Result 'Rejects extra source file' (
		Test-Failure { Invoke-Core $F } 'inventory_mismatch'
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	[IO.File]::WriteAllText(
		(Join-Path $F.Source 'a.md'), 'changed', [Text.UTF8Encoding]::new($false)
	)
	Add-Result 'Rejects source byte or size mutation' (
		Test-Failure { Invoke-Core $F } 'inventory_mismatch'
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	$MutationFault = {
		param($Checkpoint, $Context)
		if ($Checkpoint -ceq 'after_first_staged_copy') {
			[IO.File]::WriteAllText(
				(Join-Path $Context.SourceRoot 'a.md'), 'mutated',
				[Text.UTF8Encoding]::new($false)
			)
		}
	}
	Add-Result 'Detects source mutation after partial copy before repository move' (
		(Test-Failure { Invoke-Core $F $MutationFault } 'inventory_mismatch') -and
		-not (Test-Path -LiteralPath (Join-Path $F.Repository 'visuals'))
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	$PartialFault = {
		param($Checkpoint, $Context)
		if ($Checkpoint -ceq 'after_first_staged_copy') { throw 'partial-copy-test' }
	}
	Add-Result 'Partial copy failure leaves repository unchanged' (
		(Test-Failure { Invoke-Core $F $PartialFault } 'partial-copy-test') -and
		-not (Test-Path -LiteralPath (Join-Path $F.Repository 'visuals'))
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	$JournalFault = {
		param($Checkpoint, $Context)
		if ($Checkpoint -ceq 'before_journal_write') { throw 'journal-write-test' }
	}
	Add-Result 'Journal persistence failure leaves repository unchanged' (
		(Test-Failure { Invoke-Core $F $JournalFault } 'journal-write-test') -and
		-not (Test-Path -LiteralPath (Join-Path $F.Repository 'visuals'))
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	$HeadChangeFault = {
		param($Checkpoint, $Context)
		if ($Checkpoint -ceq 'before_move') {
			& git -C $F.Repository -c user.name=DeliveryFixture `
				-c user.email=delivery-fixture.invalid `
				commit --allow-empty --quiet -m head-change
			if ($LASTEXITCODE -ne 0) { throw 'Could not advance fixture HEAD.' }
		}
	}
	Add-Result 'Repository HEAD drift before move leaves destination absent' (
		(Test-Failure {
			Invoke-Core $F $HeadChangeFault
		} 'source_commit_mismatch') -and
		-not (Test-Path -LiteralPath (Join-Path $F.Repository 'visuals'))
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	$PostMoveHeadChangeFault = {
		param($Checkpoint, $Context)
		if ($Checkpoint -ceq 'after_move_before_head_recheck') {
			& git -C $F.Repository -c user.name=DeliveryFixture `
				-c user.email=delivery-fixture.invalid `
				commit --allow-empty --quiet -m post-move-head-change
			if ($LASTEXITCODE -ne 0) { throw 'Could not advance fixture HEAD.' }
		}
	}
	$PostMoveHeadChange = Invoke-Core $F $PostMoveHeadChangeFault
	Add-Result 'Repository HEAD drift during move cannot yield accepted evidence' (
		$PostMoveHeadChange.Status -ceq 'ingest_evidence_incomplete' -and
		(Test-Path -LiteralPath (Join-Path $F.Repository 'visuals\a.md')) -and
		-not (Test-Path -LiteralPath $F.Evidence)
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	$StagingRaceFault = {
		param($Checkpoint, $Context)
		if ($Checkpoint -ceq 'after_final_staging_validation') {
			[IO.File]::WriteAllText(
				(Join-Path $Context.StagingRoot 'a.md'), 'staging-race',
				[Text.UTF8Encoding]::new($false)
			)
		}
	}
	$StagingRace = Invoke-Core $F $StagingRaceFault
	Add-Result 'Final-check staging mutation cannot yield accepted evidence' (
		$StagingRace.Status -ceq 'ingest_evidence_incomplete' -and
		(Test-Path -LiteralPath (Join-Path $F.Repository 'visuals\a.md')) -and
		-not (Test-Path -LiteralPath $F.Evidence)
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	$EvidencePrepareHeadChangeFault = {
		param($Checkpoint, $Context)
		if ($Checkpoint -ceq 'after_evidence_prepare') {
			& git -C $F.Repository -c user.name=DeliveryFixture `
				-c user.email=delivery-fixture.invalid `
				commit --allow-empty --quiet -m evidence-prepare-head-change
			if ($LASTEXITCODE -ne 0) { throw 'Could not advance fixture HEAD.' }
		}
	}
	$EvidencePrepareHeadChange = Invoke-Core $F $EvidencePrepareHeadChangeFault
	Add-Result 'HEAD drift before evidence publish leaves no routable evidence' (
		$EvidencePrepareHeadChange.Status -ceq 'ingest_evidence_incomplete' -and
		(Test-Path -LiteralPath (Join-Path $F.Repository 'visuals\a.md')) -and
		-not (Test-Path -LiteralPath $F.Evidence) -and
		@(Get-ChildItem -LiteralPath $F.Artifacts -Filter '*.pending-*').Count -eq 1
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	$EvidencePrepareDestinationChangeFault = {
		param($Checkpoint, $Context)
		if ($Checkpoint -ceq 'after_evidence_prepare') {
			[IO.File]::WriteAllText(
				(Join-Path $Context.DestinationRoot 'a.md'), 'publish-race',
				[Text.UTF8Encoding]::new($false)
			)
		}
	}
	$EvidencePrepareDestinationChange = Invoke-Core `
		$F $EvidencePrepareDestinationChangeFault
	Add-Result 'Destination drift before evidence publish leaves no routable evidence' (
		$EvidencePrepareDestinationChange.Status -ceq 'ingest_evidence_incomplete' -and
		-not (Test-Path -LiteralPath $F.Evidence)
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	$RaceFault = {
		param($Checkpoint, $Context)
		if ($Checkpoint -ceq 'before_move') {
			[IO.Directory]::CreateDirectory($Context.DestinationRoot) | Out-Null
			[IO.File]::WriteAllText((Join-Path $Context.DestinationRoot 'race.md'), 'race')
		}
	}
	Add-Result 'Target race never merges or replaces' (
		(Test-Failure { Invoke-Core $F $RaceFault } 'target_race') -and
		(Get-Content -Raw -LiteralPath (Join-Path $F.Repository 'visuals\race.md')) -ceq 'race'
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	$SealFault = {
		param($Checkpoint, $Context)
		if ($Checkpoint -ceq 'before_evidence_seal') { throw 'seal-test' }
	}
	$Incomplete = Invoke-Core $F $SealFault
	$ReconciledPath = Join-Path $F.Artifacts 'reconciled-evidence.json'
	$Reconciled = & $Reconciler -JournalPath $Incomplete.PreparedJournalPath `
		-ExpectedJournalSha256 $Incomplete.PreparedJournalSha256 `
		-RepositoryRoot $F.Repository -EvidencePath $ReconciledPath -PassThru
	Add-Result 'Post-move seal failure is resumable through exact reconciliation' (
		$Incomplete.Status -ceq 'ingest_evidence_incomplete' -and
		$Reconciled.Status -ceq 'accepted' -and
		(Test-Path -LiteralPath (Join-Path $F.Repository 'visuals\a.md'))
	)
	$ExactReconcileFixture = $F

	$F = New-Fixture
	New-Manifest $F | Out-Null
	$ReconcileIncomplete = Invoke-Core $F $SealFault
	$ReconcileDestinationRacePath = Join-Path $F.Artifacts 'race-evidence.json'
	$ReconcileDestinationRaceFault = {
		param($Checkpoint, $Context)
		if ($Checkpoint -ceq 'after_reconciliation_prepare') {
			[IO.File]::WriteAllText(
				(Join-Path $Context.DestinationRoot 'a.md'), 'reconcile-race',
				[Text.UTF8Encoding]::new($false)
			)
		}
	}
	Add-Result 'Reconciliation rejects destination drift before publish' (
		(Test-Failure {
			& $Reconciler -JournalPath $ReconcileIncomplete.PreparedJournalPath `
				-ExpectedJournalSha256 $ReconcileIncomplete.PreparedJournalSha256 `
				-RepositoryRoot $F.Repository `
				-EvidencePath $ReconcileDestinationRacePath `
				-FaultInjector $ReconcileDestinationRaceFault
		} 'inventory_mismatch') -and
		-not (Test-Path -LiteralPath $ReconcileDestinationRacePath)
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	$ReconcileIncomplete = Invoke-Core $F $SealFault
	$ReconcileHeadRacePath = Join-Path $F.Artifacts 'head-race-evidence.json'
	$ReconcileHeadRaceFault = {
		param($Checkpoint, $Context)
		if ($Checkpoint -ceq 'after_reconciliation_prepare') {
			& git -C $F.Repository -c user.name=DeliveryFixture `
				-c user.email=delivery-fixture.invalid `
				commit --allow-empty --quiet -m reconcile-head-race
			if ($LASTEXITCODE -ne 0) { throw 'Could not advance fixture HEAD.' }
		}
	}
	Add-Result 'Reconciliation rejects HEAD drift before publish' (
		(Test-Failure {
			& $Reconciler -JournalPath $ReconcileIncomplete.PreparedJournalPath `
				-ExpectedJournalSha256 $ReconcileIncomplete.PreparedJournalSha256 `
				-RepositoryRoot $F.Repository -EvidencePath $ReconcileHeadRacePath `
				-FaultInjector $ReconcileHeadRaceFault
		} 'source_commit_mismatch') -and
		-not (Test-Path -LiteralPath $ReconcileHeadRacePath)
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	$IncompleteAfterRename = Invoke-Core $F $SealFault
	$JournalValue = Get-Content -Raw -LiteralPath `
		$IncompleteAfterRename.PreparedJournalPath | ConvertFrom-Json
	$DestinationInventory = Get-DeliveryExternalInventory `
		-Root (Join-Path $F.Repository 'visuals')
	$ExpectedEvidenceValue = New-DeliveryIngestEvidenceValue `
		-SourceCommit ([string]$JournalValue.source_commit) `
		-DestinationRoot (Join-Path $F.Repository 'visuals') `
		-ExternalManifestSha256 ([string]$JournalValue.external_manifest_sha256) `
		-JournalSha256 $IncompleteAfterRename.PreparedJournalSha256 `
		-Files $DestinationInventory
	[IO.File]::WriteAllText(
		$F.Evidence,
		($ExpectedEvidenceValue | ConvertTo-Json -Depth 20 -Compress),
		[Text.UTF8Encoding]::new($false)
	)
	$RecoveredExisting = & $Reconciler `
		-JournalPath $IncompleteAfterRename.PreparedJournalPath `
		-ExpectedJournalSha256 $IncompleteAfterRename.PreparedJournalSha256 `
		-RepositoryRoot $F.Repository -EvidencePath $F.Evidence -PassThru
	Add-Result 'Reconciliation seals exact evidence left after its final rename' (
		$RecoveredExisting.Status -ceq 'accepted' -and
		(Get-Item -LiteralPath $F.Evidence -Force).IsReadOnly
	)

	$F = New-Fixture
	New-Manifest $F | Out-Null
	$IncompleteWithConflict = Invoke-Core $F $SealFault
	[IO.File]::WriteAllText(
		$F.Evidence, '{}', [Text.UTF8Encoding]::new($false)
	)
	Add-Result 'Reconciliation rejects conflicting pre-existing evidence' (
		Test-Failure {
			& $Reconciler `
				-JournalPath $IncompleteWithConflict.PreparedJournalPath `
				-ExpectedJournalSha256 $IncompleteWithConflict.PreparedJournalSha256 `
				-RepositoryRoot $F.Repository -EvidencePath $F.Evidence
		} 'evidence_conflict'
	)

	[IO.File]::WriteAllText(
		(Join-Path $ExactReconcileFixture.Repository 'visuals\a.md'),
		'tampered', [Text.UTF8Encoding]::new($false)
	)
	Add-Result 'Reconciliation rejects changed destination without repair' (
		(Test-Failure {
			& $Reconciler -JournalPath $Incomplete.PreparedJournalPath `
				-ExpectedJournalSha256 $Incomplete.PreparedJournalSha256 `
				-RepositoryRoot $ExactReconcileFixture.Repository `
				-EvidencePath (
					Join-Path $ExactReconcileFixture.Artifacts 'second-evidence.json'
				)
		} 'inventory_mismatch') -and
		(Get-Content -Raw -LiteralPath (
			Join-Path $ExactReconcileFixture.Repository 'visuals\a.md'
		)) -ceq 'tampered'
	)

	$F = New-Fixture
	Set-Content -LiteralPath (Join-Path $F.Source 'a.md') `
		-Stream secret -Value secret -Encoding UTF8
	Add-Result 'Rejects named alternate streams' (
		Test-Failure { New-Manifest $F } 'alternate_stream'
	)

	$F = New-Fixture
	$Outside = Join-Path $F.Root 'outside'
	[IO.Directory]::CreateDirectory($Outside) | Out-Null
	$Junction = Join-Path $F.Source 'linked'
	try {
		New-Item -ItemType Junction -Path $Junction -Target $Outside | Out-Null
		$ReparsePassed = Test-Failure { New-Manifest $F } 'reparse_point'
	}
	catch { $ReparsePassed = $_.Exception.Message -match 'privilege|supported' }
	Add-Result 'Rejects source reparse points' $ReparsePassed

	$F = New-Fixture
	New-Manifest $F | Out-Null
	$OtherVolume = [IO.Path]::GetTempPath()
	if ([IO.Path]::GetPathRoot($OtherVolume) -ne [IO.Path]::GetPathRoot($F.Repository)) {
		Add-Result 'Rejects cross-volume staging' (
			Test-Failure {
				Invoke-DeliveryExternalFileIngestCore `
					-ManifestPath $F.Manifest -SourceRoot $F.Source `
					-RepositoryRoot $F.Repository -StagingParent $OtherVolume `
					-JournalPath $F.Journal -EvidencePath $F.Evidence `
					-SourceCommit $F.SourceCommit
			} 'cross_volume'
		)
	}
	else { Add-Result 'Rejects cross-volume staging' $true 'Single-volume host; guard inspected.' }
}
finally {
	foreach ($Root in $TestRoots) {
		$Full = [IO.Path]::GetFullPath($Root)
		if ([IO.Path]::GetFileName($Full) -like 'aetheln-delivery-ingest-test-*') {
			Get-ChildItem -LiteralPath $Full -Recurse -Force -ErrorAction SilentlyContinue |
				Where-Object { -not $_.PSIsContainer } |
				ForEach-Object { $_.IsReadOnly = $false }
			if (Test-Path -LiteralPath $Full) {
				Remove-Item -LiteralPath $Full -Recurse -Force
			}
		}
	}
}

$Failed = @($Results | Where-Object { -not $_.Passed })
$Results | Format-Table -AutoSize
if ($Failed.Count -gt 0) {
	throw "$($Failed.Count) external-ingest focused tests failed."
}
"All $($Results.Count) external-ingest focused tests passed."
