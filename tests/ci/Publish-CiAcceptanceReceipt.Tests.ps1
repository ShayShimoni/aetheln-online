$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ScriptPath = Join-Path $RepositoryRoot 'scripts\ci\Publish-CiAcceptanceReceipt.ps1'
. $ScriptPath

$script:PublisherUtf8 = New-Object Text.UTF8Encoding($false)
$script:PublisherNonce = '6' * 64

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw $Message }
}

function Assert-Rejected([scriptblock] $Action, [string] $Reason) {
	try { & $Action; throw "Expected rejection '$Reason'." }
	catch {
		if ($_.Exception.Message -ceq "Expected rejection '$Reason'." -or $_.Exception.Message -cnotmatch ('^' + [regex]::Escape($Reason) + '(?::|$)')) { throw }
	}
}

function Get-PublisherSha256([string] $Path) {
	return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TestActionManifest {
	$Items = @(
		[pscustomobject][ordered]@{ uses='actions/checkout'; revision=('1' * 40) },
		[pscustomobject][ordered]@{ uses='actions/download-artifact'; revision=('2' * 40) },
		[pscustomobject][ordered]@{ uses='actions/upload-artifact'; revision=('3' * 40) }
	)
	$Lines = ($Items | ForEach-Object { $_.uses + '@' + $_.revision }) -join "`n"
	$Hasher = [Security.Cryptography.SHA256]::Create()
	try { $Digest = ([BitConverter]::ToString($Hasher.ComputeHash($script:PublisherUtf8.GetBytes($Lines + "`n")))).Replace('-','').ToLowerInvariant() }
	finally { $Hasher.Dispose() }
	return [pscustomobject][ordered]@{ manifestSha256=$Digest; items=$Items }
}

function New-TestPublisherContext {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs and returns an in-memory publisher-context fixture without changing external state.')]
	param([string[]] $Selection = @('visual-package'))
	return [pscustomobject][ordered]@{
		schemaVersion = 'aetheln.ci-acceptance-context/v1'
		repository = [pscustomobject][ordered]@{ fullName='ShayShimoni/aetheln-online' }
		event = [pscustomobject][ordered]@{ kind='pull_request'; classification='pull_request_acceptance'; actor='owner'; triggeringActor='owner' }
		source = [pscustomobject][ordered]@{ baseRevision=('a'*40); headRevision=('b'*40); testedRevision=('c'*40) }
		workflow = [pscustomobject][ordered]@{ id='9876543'; revision=('c'*40); parents=@(('a'*40),('b'*40)); sha256=('d'*64) }
		controller = [pscustomobject][ordered]@{ revision=('a'*40); blobOid=('e'*40); sha256=('f'*64) }
		policy = [pscustomobject][ordered]@{ version='shadow-v1'; digest=('1'*64) }
		actions = Get-TestActionManifest
		run = [pscustomobject][ordered]@{ id='9001'; attempt=2 }
		attemptAnchor = [pscustomobject][ordered]@{ schemaVersion='aetheln.current-attempt-anchor/v1'; runId='9001'; runAttempt=2; nonce=$script:PublisherNonce }
		selection = [pscustomobject][ordered]@{ checks=@($Selection) }
	}
}

function New-TestPortableReport {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs and returns an in-memory portable-report fixture without changing external state.')]
	param()
	$Names = @(
		'formatting-policy','markdown-links','source-control-policy','observability-contract','build-packaged-artifacts-tests','host-tool-provisioning-tests',
		'packaged-smoke-test-tests','network-authority-spike-tests','engine-runner-gate-tests','unreal-automation-tests',
		'server-cook-reference-tests','target-composition-tests','build-provenance-tests','markdown-link-tests',
		'formatting-policy-tests','observability-contract-tests','ci-suite-tests','engine-runner-post-command-state-tests',
		'prototype-quality-workflow-tests','visual-package-evidence-tests','runner-scheduling-policy-tests','ci-selection-tests',
		'ci-acceptance-receipt-tests','ci-acceptance-aggregate-tests','ci-acceptance-publisher-tests','ci-acceptance-context-tests',
		'ci-activation-candidate-tests','compile-workspace-tests','engine-host-lease-tests',
		'managed-compile-registration-tests','managed-compile-workspace-tests','managed-compile-integration-tests',
		'routine-compile-deadline-tests','routine-compile-resources-tests','routine-compile-command-tests','routine-compile-gate-tests','release-packaging-tests',
		'board-integrity-tests','pull-request-policy-tests',
		'psscriptanalyzer'
	)
	$Checks = @($Names | ForEach-Object { [pscustomobject][ordered]@{name=$_;tier=$(if($_-ceq'psscriptanalyzer'){'advisory'}else{'required'});status='passed';durationSeconds=0.01;command='fixture';message='passed'} })
	return [pscustomobject][ordered]@{schemaVersion=1;revision=('c'*40);startedUtc='2026-09-20T20:00:00.0000000Z';finishedUtc='2026-09-20T20:00:01.0000000Z';checks=$Checks;summary=[pscustomobject][ordered]@{total=$Checks.Count;passed=$Checks.Count;failed=0;skipped=0;requiredFailed=0}}
}

function New-TestNativeReport {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs and returns an in-memory native-report fixture without changing external state.')]
	param()
	$Names = @('runner-input-validation','managed-compile-workspace','repository-state-before-work','incremental-client-build','incremental-client-build-repository-state','incremental-server-build','incremental-server-build-repository-state','repository-state-at-completion')
	$Checks = @($Names | ForEach-Object { [pscustomobject][ordered]@{name=$_;tier='required';status='passed';durationSeconds=0.01;command='fixture';message='passed'} })
	$Builds = @(
		[pscustomobject][ordered]@{check='incremental-client-build';target='AethelnOnlineClient';platform='Win64';configuration='Development';intermediateBuildDirectoryPresentBeforeRun=$true;makefilePresentBeforeRun=$true;outputState='captured';lastObservedAction=1;observedTotalActions=1;actionCounterState='observed';plannedActionCount=1;observedTargetNames='AethelnOnlineClient';makefileObservation='not_observed';makefileReason=$null;makefileCreationCount=0;upToDateObserved=$false;executorSummaryCount=1},
		[pscustomobject][ordered]@{check='incremental-server-build';target='AethelnOnlineServer';platform='Linux';configuration='Development';intermediateBuildDirectoryPresentBeforeRun=$true;makefilePresentBeforeRun=$true;outputState='captured';lastObservedAction=1;observedTotalActions=1;actionCounterState='observed';plannedActionCount=1;observedTargetNames='AethelnOnlineServer';makefileObservation='not_observed';makefileReason=$null;makefileCreationCount=0;upToDateObserved=$false;executorSummaryCount=1}
	)
	$Workspace = [pscustomobject][ordered]@{schemaVersion=1;registrationId=('6'*32);registrationSha256=('4'*64);preparationReceiptSha256=('5'*64);revision=('c'*40);synchronized=$true}
	$Resources = [pscustomobject][ordered]@{schemaVersion=1;sampleIntervalMilliseconds=5000;recoveryFloorBytes=20GB;pressureThresholdBytes=2GB;sampleCount=2;measurementCount=4;maximumSampleGapMilliseconds=5000;consecutivePressureSamples=0;maximumConsecutivePressureSamples=0;minimumAvailableRamBytes=16GB;minimumCommitHeadroomBytes=16GB;physicalCores=8;targetAdmissionCount=2;minimumActionLimit=2;maximumActionLimit=4;failureReason=$null;volumes=@([pscustomobject][ordered]@{volumeId='volume-fixture';knownAllocationBytes=0;minimumAvailableBytes=50GB})}
	return [pscustomobject][ordered]@{schemaVersion=1;mode='Compile';policy='incremental-target-compilation';revision=('c'*40);runnerName='fixture-runner';startedUtc='2026-09-20T20:00:00.0000000Z';finishedUtc='2026-09-20T20:00:01.0000000Z';checks=$Checks;summary=[pscustomobject][ordered]@{total=$Checks.Count;passed=$Checks.Count;failed=0;skipped=0;requiredFailed=0};compileEvidence=[pscustomobject][ordered]@{schemaVersion=1;identity=[pscustomobject][ordered]@{engineGitRevision='71fe36aac5a8df5ccd66c763ffc902b29b6a9c43';engineGitRevisionStatus='verified';engineBuildVersionSha256=('2'*64);engineBuildVersionSha256Status='verified';linuxToolchainCompilerSha256=('3'*64);linuxToolchainCompilerSha256Status='verified';runnerName='fixture-runner';durationSeconds=0.01};builds=$Builds};managedWorkspace=$Workspace;compileResources=$Resources;supervisor=[pscustomobject][ordered]@{childExitCode=0;timedOut=$false;cleanupVerified=$true}}
}

function New-TestVisualReport {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs and returns an in-memory visual-report fixture without changing external state.')]
	param()
	$Output = @('stdout: fixture pass')
	$CapturedBytes = $script:PublisherUtf8.GetByteCount($Output[0])
	$Results = @(
		[pscustomobject][ordered]@{id='visual-package';path='.\visuals\Test-VisualPackage.ps1';startedUtc='2026-09-20T20:00:00.0000000Z';finishedUtc='2026-09-20T20:00:01.0000000Z';nativeExitCode=0;conclusion='success';capture=[pscustomobject][ordered]@{maxLineUtf8Bytes=4096;maxLines=200;maxAggregateUtf8Bytes=131072;observedLineCount=1;capturedLineCount=1;capturedUtf8Bytes=$CapturedBytes;truncatedLineCount=0;droppedLineCount=0};output=$Output},
		[pscustomobject][ordered]@{id='visual-package-regressions';path='.\visuals\tests\Test-VisualPackageValidation.ps1';startedUtc='2026-09-20T20:00:01.0000000Z';finishedUtc='2026-09-20T20:00:02.0000000Z';nativeExitCode=0;conclusion='success';capture=[pscustomobject][ordered]@{maxLineUtf8Bytes=4096;maxLines=200;maxAggregateUtf8Bytes=131072;observedLineCount=1;capturedLineCount=1;capturedUtf8Bytes=$CapturedBytes;truncatedLineCount=0;droppedLineCount=0};output=$Output}
	)
	return [pscustomobject][ordered]@{schemaVersion='aetheln.visual-package-report/v1';repository='ShayShimoni/aetheln-online';revision=('c'*40);run=[pscustomobject][ordered]@{id='9001';attempt=2};results=$Results;conclusion='success'}
}

function New-TestUnrealReport {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs and returns an in-memory unreal-automation-report fixture without changing external state.')]
	param()
	$Tests = @(
		[pscustomobject][ordered]@{fullTestPath='Aetheln.GameCombat.NetworkSpike.Authority';state='Success';status='passed';durationSeconds=0.1;warningCount=0;errorCount=0},
		[pscustomobject][ordered]@{fullTestPath='Aetheln.Harness.ProjectAndModuleLoad';state='Success';status='passed';durationSeconds=0.1;warningCount=0;errorCount=0}
	)
	return [pscustomobject][ordered]@{schemaId='aetheln.unreal-automation';schemaVersion=1;mode='production';sourceRevision=('c'*40);engineRevision='71fe36aac5a8df5ccd66c763ffc902b29b6a9c43';projectName='AethelnOnline';filter='^Aetheln.Harness.ProjectAndModuleLoad$+^Aetheln.GameCombat.NetworkSpike.Authority$';timeoutSeconds=600;startedUtc='2026-09-20T20:00:00.0000000Z';finishedUtc='2026-09-20T20:00:01.0000000Z';processExitCode=0;repositoryCleanBefore=$true;repositoryCleanAfter=$true;outputs=[pscustomobject][ordered]@{unrealReport='TestResults/UnrealAutomation/index.json';log='Saved/Logs/AethelnUnrealAutomation.log'};tests=$Tests;summary=[pscustomobject][ordered]@{total=2;passed=2;passedWithWarnings=0;failed=0;notRun=0;missing=0;requiredFailed=0};result='passed';failureReason='none'}
}

function Get-PublisherCaseDefinition([string] $ProducerKey) {
	switch ($ProducerKey) {
		'portable' { return @{ checks=@('portable'); name='ci-report.json'; job='portable-receipt-shadow'; report=(New-TestPortableReport) } }
		'native' { return @{ checks=@('native-client-server-compile'); name='engine-runner-report.json'; job='native-receipt-shadow'; report=(New-TestNativeReport) } }
		'unreal' { return @{ checks=@('unreal-editor-automation'); name='unreal-automation-report.json'; job='unreal-receipt-shadow'; report=(New-TestUnrealReport) } }
		'visual' { return @{ checks=@('visual-package'); name='visual-package-report.json'; job='visual-receipt-shadow'; report=(New-TestVisualReport) } }
		default { throw 'test_producer_key_invalid' }
	}
}

function New-PublisherFixture {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates only caller-scoped disposable test inputs and output paths under the process temporary directory.')]
	param([string] $Root, [string] $ProducerKey, [string[]] $Selection = $null)
	$Definition = Get-PublisherCaseDefinition $ProducerKey
	if ($null -eq $Selection) { $Selection = $Definition.checks }
	[void] (New-Item -ItemType Directory -Path $Root)
	$EvidenceRoot = Join-Path $Root 'downloaded-evidence'
	[void] (New-Item -ItemType Directory -Path $EvidenceRoot)
	$ContextPath = Join-Path $Root 'context.json'
	$EvidencePath = Join-Path $EvidenceRoot $Definition.name
	[IO.File]::WriteAllText($ContextPath, ((New-TestPublisherContext -Selection $Selection | ConvertTo-Json -Depth 12 -Compress) + "`n"), $script:PublisherUtf8)
	[IO.File]::WriteAllText($EvidencePath, (($Definition.report | ConvertTo-Json -Depth 12 -Compress) + "`n"), $script:PublisherUtf8)
	$OutputRoot = Join-Path $Root ('ci-receipt-' + $ProducerKey + '-9001-2-' + $script:PublisherNonce)
	return [pscustomobject]@{
		ProducerKey=$ProducerKey; Selection=@($Selection); JobName=$Definition.job; ContextPath=$ContextPath; EvidenceRoot=$EvidenceRoot; EvidencePath=$EvidencePath
		EvidenceName=$Definition.name; EvidenceSha256=(Get-PublisherSha256 $EvidencePath); EvidenceSizeBytes=[long](Get-Item -LiteralPath $EvidencePath).Length; OutputRoot=$OutputRoot
	}
}

function Invoke-PublisherFixture($Fixture) {
	return Publish-CiAcceptanceReceipt -ContextPath $Fixture.ContextPath -ProducerKey $Fixture.ProducerKey -JobName $Fixture.JobName `
		-EvidenceRoot $Fixture.EvidenceRoot -ExpectedEvidenceSha256 $Fixture.EvidenceSha256 `
		-ExpectedEvidenceSizeBytes $Fixture.EvidenceSizeBytes -OutputRoot $Fixture.OutputRoot
}

$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('aetheln-receipt-publisher-' + [guid]::NewGuid().ToString('N'))
try {
	[void] (New-Item -ItemType Directory -Path $FixtureRoot)
	foreach ($ProducerKey in @('portable','native','unreal','visual')) {
		$Case = New-PublisherFixture -Root (Join-Path $FixtureRoot $ProducerKey) -ProducerKey $ProducerKey
		$CheckId = $Case.Selection[0]
		$Published = Invoke-PublisherFixture $Case
		Assert-True ($Published.artifactName -ceq (Split-Path -Leaf $Case.OutputRoot)) "The $CheckId publisher should return its exact artifact name."
		$Entries = @(Get-ChildItem -LiteralPath $Case.OutputRoot -Force)
		Assert-True ($Entries.Count -eq 2 -and @($Entries | Where-Object { -not $_.PSIsContainer }).Count -eq 2) "The $CheckId upload root must contain exactly receipt plus raw evidence."
		$ReceiptPath = Join-Path $Case.OutputRoot 'ci-acceptance-receipt.json'
		$Receipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json
		Assert-True ($Receipt.selection.checks.Count -eq 1 -and $Receipt.selection.checks[0] -ceq $CheckId -and (@($Published.checks) -join ',') -ceq $CheckId) "The $CheckId receipt must select exactly its supported obligation."
		Assert-True ($Receipt.acceptance.shadow -and -not $Receipt.acceptance.authoritative -and -not $Receipt.acceptance.grantsAcceptance) "The $CheckId receipt must remain shadow-only."
		Assert-True ((Get-PublisherSha256 (Join-Path $Case.OutputRoot $Case.EvidenceName)) -ceq $Case.EvidenceSha256) "The $CheckId receipt archive must preserve exact evidence bytes."
		if ($CheckId -ceq 'native-client-server-compile') {
			Assert-True ($Receipt.results.checks[0].nativeExitCode -eq 0 -and $Receipt.results.checks[0].cleanupVerified) 'Native receipt must bind zero exit and verified cleanup.'
		} elseif ($CheckId -ceq 'unreal-editor-automation') {
			# The harness exits zero only after both frozen tests pass; it owns no cleanup proof.
			Assert-True ($Receipt.results.checks[0].nativeExitCode -eq 0 -and $null -eq $Receipt.results.checks[0].cleanupVerified -and $null -eq $Receipt.acceptance.cleanupVerified) 'Unreal receipt must bind zero exit without inventing cleanup evidence.'
		} else {
			Assert-True ($null -eq $Receipt.results.checks[0].nativeExitCode -and $null -eq $Receipt.results.checks[0].cleanupVerified) "$CheckId must not invent native or cleanup evidence."
		}
	}

	# The portable producer covers controller-contract and portable from the one
	# ci-report.json; only the selector-derived subset is published, in ordinal order.
	foreach ($SelectionCase in @(
		@{ name='both'; selection=@('portable','controller-contract'); expected='controller-contract,portable' },
		@{ name='portable-only'; selection=@('portable'); expected='portable' },
		@{ name='contract-only'; selection=@('controller-contract'); expected='controller-contract' },
		@{ name='operational-dropped'; selection=@('portable','controller-operational-proof'); expected='portable' }
	)) {
		$Case = New-PublisherFixture -Root (Join-Path $FixtureRoot ('selection-' + $SelectionCase.name)) -ProducerKey portable -Selection $SelectionCase.selection
		$Published = Invoke-PublisherFixture $Case
		$Receipt = Get-Content -LiteralPath $Published.receiptPath -Raw | ConvertFrom-Json
		$Entries = @(Get-ChildItem -LiteralPath $Case.OutputRoot -Force)
		Assert-True ((@($Published.checks) -join ',') -ceq $SelectionCase.expected -and (@($Receipt.selection.checks) -join ',') -ceq $SelectionCase.expected -and (@($Receipt.results.checks | ForEach-Object { $_.id }) -join ',') -ceq $SelectionCase.expected) "Portable selection '$($SelectionCase.name)' must publish exactly the selector-derived subset."
		Assert-True ($Entries.Count -eq 2 -and @($Receipt.results.checks | Where-Object { @($_.evidence).Count -ne 1 -or $_.evidence[0].name -cne 'ci-report.json' -or $_.evidence[0].sha256 -cne $Case.EvidenceSha256 -or $_.evidence[0].sizeBytes -ne $Case.EvidenceSizeBytes -or $_.jobName -cne 'portable-receipt-shadow' -or $null -ne $_.nativeExitCode -or $null -ne $_.cleanupVerified }).Count -eq 0) "Portable selection '$($SelectionCase.name)' must bind every result to the one exact ci-report.json."
	}

	# The native producer covers controller-operational-proof and native-client-server-compile
	# from the one engine-runner-report.json; every result binds the real native exit and cleanup proof.
	foreach ($SelectionCase in @(
		@{ name='both'; selection=@('native-client-server-compile','controller-operational-proof'); expected='controller-operational-proof,native-client-server-compile' },
		@{ name='operational-only'; selection=@('controller-operational-proof'); expected='controller-operational-proof' },
		@{ name='contract-dropped'; selection=@('native-client-server-compile','controller-contract'); expected='native-client-server-compile' }
	)) {
		$Case = New-PublisherFixture -Root (Join-Path $FixtureRoot ('native-selection-' + $SelectionCase.name)) -ProducerKey native -Selection $SelectionCase.selection
		$Published = Invoke-PublisherFixture $Case
		$Receipt = Get-Content -LiteralPath $Published.receiptPath -Raw | ConvertFrom-Json
		$Entries = @(Get-ChildItem -LiteralPath $Case.OutputRoot -Force)
		Assert-True ((@($Published.checks) -join ',') -ceq $SelectionCase.expected -and (@($Receipt.selection.checks) -join ',') -ceq $SelectionCase.expected -and (@($Receipt.results.checks | ForEach-Object { $_.id }) -join ',') -ceq $SelectionCase.expected) "Native selection '$($SelectionCase.name)' must publish exactly the selector-derived subset."
		Assert-True ($Entries.Count -eq 2 -and @($Receipt.results.checks | Where-Object { @($_.evidence).Count -ne 1 -or $_.evidence[0].name -cne 'engine-runner-report.json' -or $_.evidence[0].sha256 -cne $Case.EvidenceSha256 -or $_.evidence[0].sizeBytes -ne $Case.EvidenceSizeBytes -or $_.jobName -cne 'native-receipt-shadow' -or $_.nativeExitCode -ne 0 -or $_.cleanupVerified -ne $true }).Count -eq 0) "Native selection '$($SelectionCase.name)' must bind every result to the one exact engine-runner-report.json with zero exit and verified cleanup."
	}

	$EmptySelection = New-PublisherFixture -Root (Join-Path $FixtureRoot 'selection-empty') -ProducerKey portable -Selection @('visual-package')
	Assert-Rejected { Invoke-PublisherFixture $EmptySelection } 'receipt_publisher_selection_empty'
	Assert-True (-not (Test-Path -LiteralPath $EmptySelection.OutputRoot)) 'A producer with no selected obligation must publish nothing.'

	foreach ($SelectionShapeCase in @(
		@{ name='missing'; mutate={ param($x) $x.PSObject.Properties.Remove('selection') } },
		@{ name='extra'; mutate={ param($x) $x.selection | Add-Member -NotePropertyName extra -NotePropertyValue $true } },
		@{ name='unknown'; mutate={ param($x) $x.selection.checks = @('portable','delivery-harness') } },
		@{ name='duplicate'; mutate={ param($x) $x.selection.checks = @('portable','portable') } },
		@{ name='not-array'; mutate={ param($x) $x.selection.checks = 'portable' } },
		@{ name='empty'; mutate={ param($x) $x.selection.checks = @() } },
		@{ name='non-string'; mutate={ param($x) $x.selection.checks = @(1) } }
	)) {
		$Shape = New-PublisherFixture -Root (Join-Path $FixtureRoot ('selection-shape-' + $SelectionShapeCase.name)) -ProducerKey portable
		$ShapeContext = New-TestPublisherContext -Selection @('portable'); & $SelectionShapeCase.mutate $ShapeContext
		[IO.File]::WriteAllText($Shape.ContextPath, (($ShapeContext | ConvertTo-Json -Depth 12 -Compress) + "`n"), $script:PublisherUtf8)
		try { Assert-Rejected { Invoke-PublisherFixture $Shape } 'receipt_publisher_context_invalid' }
		catch { throw "Publisher selection fixture '$($SelectionShapeCase.name)' failed: $($_.Exception.Message)" }
	}

	$Duplicate = New-PublisherFixture -Root (Join-Path $FixtureRoot 'duplicate') -ProducerKey visual
	[void] (Invoke-PublisherFixture $Duplicate)
	Assert-Rejected { Invoke-PublisherFixture $Duplicate } 'receipt_publisher_output_exists'

	$Missing = New-PublisherFixture -Root (Join-Path $FixtureRoot 'missing') -ProducerKey visual
	Remove-Item -LiteralPath $Missing.EvidencePath -Force
	Assert-Rejected { Invoke-PublisherFixture $Missing } 'receipt_publisher_evidence_inventory_invalid'

	$Extra = New-PublisherFixture -Root (Join-Path $FixtureRoot 'extra') -ProducerKey visual
	[IO.File]::WriteAllText((Join-Path $Extra.EvidenceRoot 'extra.txt'), 'extra', $script:PublisherUtf8)
	Assert-Rejected { Invoke-PublisherFixture $Extra } 'receipt_publisher_evidence_inventory_invalid'

	$WrongName = New-PublisherFixture -Root (Join-Path $FixtureRoot 'wrong-name') -ProducerKey visual
	Move-Item -LiteralPath $WrongName.EvidencePath -Destination (Join-Path $WrongName.EvidenceRoot 'wrong.json')
	Assert-Rejected { Invoke-PublisherFixture $WrongName } 'receipt_publisher_evidence_inventory_invalid'

	$WrongDigest = New-PublisherFixture -Root (Join-Path $FixtureRoot 'wrong-digest') -ProducerKey visual
	$WrongDigest.EvidenceSha256 = '0' * 64
	Assert-Rejected { Invoke-PublisherFixture $WrongDigest } 'receipt_publisher_evidence_digest_mismatch'

	$WrongSize = New-PublisherFixture -Root (Join-Path $FixtureRoot 'wrong-size') -ProducerKey visual
	$WrongSize.EvidenceSizeBytes++
	Assert-Rejected { Invoke-PublisherFixture $WrongSize } 'receipt_publisher_evidence_size_mismatch'

	$MalformedEvidence = New-PublisherFixture -Root (Join-Path $FixtureRoot 'malformed-evidence') -ProducerKey visual
	[IO.File]::WriteAllText($MalformedEvidence.EvidencePath, '{', $script:PublisherUtf8)
	$MalformedEvidence.EvidenceSha256 = Get-PublisherSha256 $MalformedEvidence.EvidencePath
	$MalformedEvidence.EvidenceSizeBytes = [long](Get-Item $MalformedEvidence.EvidencePath).Length
	Assert-Rejected { Invoke-PublisherFixture $MalformedEvidence } 'receipt_semantic_evidence_invalid:visual-package'

	# A harness report whose frozen test failed can never become an unreal receipt.
	$FailedUnreal = New-PublisherFixture -Root (Join-Path $FixtureRoot 'failed-unreal') -ProducerKey unreal
	$FailedUnrealReport = New-TestUnrealReport
	$FailedUnrealReport.tests[0].status = 'failed'
	[IO.File]::WriteAllText($FailedUnreal.EvidencePath, (($FailedUnrealReport | ConvertTo-Json -Depth 12 -Compress) + "`n"), $script:PublisherUtf8)
	$FailedUnreal.EvidenceSha256 = Get-PublisherSha256 $FailedUnreal.EvidencePath
	$FailedUnreal.EvidenceSizeBytes = [long](Get-Item $FailedUnreal.EvidencePath).Length
	Assert-Rejected { Invoke-PublisherFixture $FailedUnreal } 'receipt_semantic_evidence_invalid:unreal-editor-automation'

	$OversizedEvidence = New-PublisherFixture -Root (Join-Path $FixtureRoot 'oversized-evidence') -ProducerKey visual
	$EvidenceStream = New-Object IO.FileStream($OversizedEvidence.EvidencePath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
	try { $EvidenceStream.SetLength(4MB + 1) } finally { $EvidenceStream.Dispose() }
	Assert-Rejected { Publish-CiAcceptanceReceipt -ContextPath $OversizedEvidence.ContextPath -ProducerKey $OversizedEvidence.ProducerKey -JobName $OversizedEvidence.JobName -EvidenceRoot $OversizedEvidence.EvidenceRoot -ExpectedEvidenceSha256 ('0'*64) -ExpectedEvidenceSizeBytes (4MB + 1) -OutputRoot $OversizedEvidence.OutputRoot } 'receipt_publisher_evidence_size_invalid'

	$Unsupported = New-PublisherFixture -Root (Join-Path $FixtureRoot 'unsupported') -ProducerKey visual
	foreach ($UnsupportedKey in @('quality','Portable','portable-receipt-shadow')) {
		Assert-Rejected { Publish-CiAcceptanceReceipt -ContextPath $Unsupported.ContextPath -ProducerKey $UnsupportedKey -JobName $Unsupported.JobName -EvidenceRoot $Unsupported.EvidenceRoot -ExpectedEvidenceSha256 $Unsupported.EvidenceSha256 -ExpectedEvidenceSizeBytes $Unsupported.EvidenceSizeBytes -OutputRoot $Unsupported.OutputRoot } ('receipt_publisher_key_unsupported:' + $UnsupportedKey)
	}

	$MalformedContext = New-PublisherFixture -Root (Join-Path $FixtureRoot 'malformed-context') -ProducerKey visual
	[IO.File]::WriteAllText($MalformedContext.ContextPath, '{', $script:PublisherUtf8)
	Assert-Rejected { Invoke-PublisherFixture $MalformedContext } 'receipt_publisher_context_json_invalid'

	$DuplicateContext = New-PublisherFixture -Root (Join-Path $FixtureRoot 'duplicate-context') -ProducerKey visual
	[IO.File]::WriteAllText($DuplicateContext.ContextPath, '{"schemaVersion":"aetheln.ci-acceptance-context/v1","schemaVersion":"aetheln.ci-acceptance-context/v1"}', $script:PublisherUtf8)
	Assert-Rejected { Invoke-PublisherFixture $DuplicateContext } 'receipt_publisher_context_json_duplicate_property'

	$ExtraContext = New-PublisherFixture -Root (Join-Path $FixtureRoot 'extra-context') -ProducerKey visual
	$ExtraObject = New-TestPublisherContext
	$ExtraObject | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
	[IO.File]::WriteAllText($ExtraContext.ContextPath, (($ExtraObject | ConvertTo-Json -Depth 12 -Compress) + "`n"), $script:PublisherUtf8)
	Assert-Rejected { Invoke-PublisherFixture $ExtraContext } 'receipt_publisher_context_invalid'

	$OversizedContext = New-PublisherFixture -Root (Join-Path $FixtureRoot 'oversized-context') -ProducerKey visual
	[IO.File]::WriteAllBytes($OversizedContext.ContextPath, [byte[]]::new(65537))
	Assert-Rejected { Invoke-PublisherFixture $OversizedContext } 'receipt_publisher_context_limit'

	foreach ($IdentityCase in @(
		@{ name='wrong-repository'; mutate={param($x)$x.repository.fullName='evil/repository'}; reason='receipt_semantic_evidence_invalid:visual-package' },
		@{ name='wrong-revision'; mutate={param($x)$x.source.testedRevision=('9'*40);$x.workflow.revision=('9'*40)}; reason='receipt_semantic_evidence_invalid:visual-package' },
		@{ name='wrong-run'; mutate={param($x)$x.run.id='9002';$x.attemptAnchor.runId='9002'}; reason='receipt_semantic_evidence_invalid:visual-package' }
	)) {
		$Identity = New-PublisherFixture -Root (Join-Path $FixtureRoot $IdentityCase.name) -ProducerKey visual
		$Context = New-TestPublisherContext; & $IdentityCase.mutate $Context
		[IO.File]::WriteAllText($Identity.ContextPath, (($Context | ConvertTo-Json -Depth 12 -Compress) + "`n"), $script:PublisherUtf8)
		if ($IdentityCase.name -ceq 'wrong-run') { $Identity.OutputRoot = Join-Path (Split-Path -Parent $Identity.OutputRoot) ('ci-receipt-visual-9002-2-' + $script:PublisherNonce) }
		Assert-Rejected { Invoke-PublisherFixture $Identity } $IdentityCase.reason
	}

	$WrongOutput = New-PublisherFixture -Root (Join-Path $FixtureRoot 'wrong-output') -ProducerKey visual
	$WrongOutput.OutputRoot = Join-Path (Split-Path -Parent $WrongOutput.OutputRoot) 'wrong-artifact-name'
	Assert-Rejected { Invoke-PublisherFixture $WrongOutput } 'receipt_publisher_output_name_invalid'

	$OverlappingOutput = New-PublisherFixture -Root (Join-Path $FixtureRoot 'overlap') -ProducerKey visual
	$OverlappingOutput.OutputRoot = Join-Path $OverlappingOutput.EvidenceRoot ('ci-receipt-visual-9001-2-' + $script:PublisherNonce)
	Assert-Rejected { Invoke-PublisherFixture $OverlappingOutput } 'receipt_publisher_path_overlap'

	$TraversalOutput = New-PublisherFixture -Root (Join-Path $FixtureRoot 'traversal-output') -ProducerKey visual
	$TraversalOutput.OutputRoot = (Join-Path (Split-Path -Parent $TraversalOutput.OutputRoot) ('unused\..\ci-receipt-visual-9001-2-' + $script:PublisherNonce))
	Assert-Rejected { Invoke-PublisherFixture $TraversalOutput } 'receipt_publisher_path_traversal'

	$TraversalEvidence = New-PublisherFixture -Root (Join-Path $FixtureRoot 'traversal-evidence') -ProducerKey visual
	$TraversalEvidence.EvidenceRoot = Join-Path $TraversalEvidence.EvidenceRoot '..\downloaded-evidence'
	Assert-Rejected { Invoke-PublisherFixture $TraversalEvidence } 'receipt_publisher_path_traversal'

	$TraversalContext = New-PublisherFixture -Root (Join-Path $FixtureRoot 'traversal-context') -ProducerKey visual
	$TraversalContext.ContextPath = Join-Path (Split-Path -Parent $TraversalContext.ContextPath) 'unused\..\context.json'
	Assert-Rejected { Invoke-PublisherFixture $TraversalContext } 'receipt_publisher_path_traversal'

	$MissingOutputParent = New-PublisherFixture -Root (Join-Path $FixtureRoot 'missing-output-parent') -ProducerKey visual
	$MissingOutputParent.OutputRoot = Join-Path (Join-Path (Split-Path -Parent $MissingOutputParent.OutputRoot) 'absent') ('ci-receipt-visual-9001-2-' + $script:PublisherNonce)
	Assert-Rejected { Invoke-PublisherFixture $MissingOutputParent } 'receipt_publisher_output_parent_invalid'

	$HostileEnvironment = New-PublisherFixture -Root (Join-Path $FixtureRoot 'hostile-environment') -ProducerKey visual
	$SavedEnvironment = @{}
	foreach ($Name in @('AETHELN_RECEIPT_CONTEXT','AETHELN_RECEIPT_EVIDENCE_ROOT','AETHELN_RECEIPT_OUTPUT_ROOT','INPUTPATH','EVIDENCEROOT','OUTPUTPATH')) {
		$SavedEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
		[Environment]::SetEnvironmentVariable($Name, (Join-Path $FixtureRoot 'attacker-controlled'), 'Process')
	}
	try { [void] (Invoke-PublisherFixture $HostileEnvironment) }
	finally { foreach ($Name in $SavedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($Name, $SavedEnvironment[$Name], 'Process') } }
	Assert-True (Test-Path -LiteralPath (Join-Path $HostileEnvironment.OutputRoot 'ci-acceptance-receipt.json') -PathType Leaf) 'Hostile ambient overrides must not redirect publication.'

	$Cli = New-PublisherFixture -Root (Join-Path $FixtureRoot 'cli') -ProducerKey portable
	& $ScriptPath -ContextPath $Cli.ContextPath -ProducerKey $Cli.ProducerKey -JobName $Cli.JobName -EvidenceRoot $Cli.EvidenceRoot `
		-ExpectedEvidenceSha256 $Cli.EvidenceSha256 -ExpectedEvidenceSizeBytes $Cli.EvidenceSizeBytes -OutputRoot $Cli.OutputRoot
	Assert-True (Test-Path -LiteralPath (Join-Path $Cli.OutputRoot 'ci-acceptance-receipt.json') -PathType Leaf) 'The script entry point must publish the same bounded receipt as the function entry point.'

	$JunctionTarget = Join-Path $FixtureRoot 'junction-target'
	[void] (New-Item -ItemType Directory -Path $JunctionTarget)
	$JunctionFile = Join-Path $JunctionTarget 'visual-package-report.json'
	[IO.File]::WriteAllText($JunctionFile, ((New-TestVisualReport | ConvertTo-Json -Depth 12 -Compress) + "`n"), $script:PublisherUtf8)
	$JunctionRoot = Join-Path $FixtureRoot 'junction-evidence'
	[void] (New-Item -ItemType Junction -Path $JunctionRoot -Target $JunctionTarget)
	$JunctionCase = New-PublisherFixture -Root (Join-Path $FixtureRoot 'junction-case') -ProducerKey visual
	Assert-Rejected { Publish-CiAcceptanceReceipt -ContextPath $JunctionCase.ContextPath -ProducerKey $JunctionCase.ProducerKey -JobName $JunctionCase.JobName -EvidenceRoot $JunctionRoot -ExpectedEvidenceSha256 (Get-PublisherSha256 $JunctionFile) -ExpectedEvidenceSizeBytes ([long](Get-Item $JunctionFile).Length) -OutputRoot $JunctionCase.OutputRoot } 'receipt_publisher_reparse_path_invalid'

	$OutputJunctionTarget = Join-Path $FixtureRoot 'output-junction-target'
	[void] (New-Item -ItemType Directory -Path $OutputJunctionTarget)
	$OutputJunction = Join-Path $FixtureRoot 'output-junction'
	[void] (New-Item -ItemType Junction -Path $OutputJunction -Target $OutputJunctionTarget)
	$OutputJunctionCase = New-PublisherFixture -Root (Join-Path $FixtureRoot 'output-junction-case') -ProducerKey visual
	$OutputJunctionCase.OutputRoot = Join-Path $OutputJunction ('ci-receipt-visual-9001-2-' + $script:PublisherNonce)
	Assert-Rejected { Invoke-PublisherFixture $OutputJunctionCase } 'receipt_publisher_reparse_path_invalid'

	$ContextJunctionTarget = Join-Path $FixtureRoot 'context-junction-target'
	[void] (New-Item -ItemType Directory -Path $ContextJunctionTarget)
	$ContextJunctionFile = Join-Path $ContextJunctionTarget 'context.json'
	[IO.File]::WriteAllText($ContextJunctionFile, ((New-TestPublisherContext | ConvertTo-Json -Depth 12 -Compress) + "`n"), $script:PublisherUtf8)
	$ContextJunction = Join-Path $FixtureRoot 'context-junction'
	[void] (New-Item -ItemType Junction -Path $ContextJunction -Target $ContextJunctionTarget)
	$ContextJunctionCase = New-PublisherFixture -Root (Join-Path $FixtureRoot 'context-junction-case') -ProducerKey visual
	$ContextJunctionCase.ContextPath = Join-Path $ContextJunction 'context.json'
	Assert-Rejected { Invoke-PublisherFixture $ContextJunctionCase } 'receipt_publisher_reparse_path_invalid'
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
}

$ContextSource = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'scripts\ci\New-CiAcceptanceAggregateContext.ps1'))
$ContextListMatch = [regex]::Match($ContextSource, '\$script:AggregateContextCheckIds = @\(([^)]*)\)')
Assert-True $ContextListMatch.Success 'Aggregate context check-id list must be discoverable for lockstep validation.'
$ContextCheckIds = @([regex]::Matches($ContextListMatch.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
Assert-True ($ContextCheckIds.Count -eq 8 -and $script:PublisherCheckIds.Count -eq 8) 'Aggregate context and publisher must both declare exactly eight check ids.'
$SortedContextCheckIds = [string[]] $ContextCheckIds
[Array]::Sort($SortedContextCheckIds, [StringComparer]::Ordinal)
$SortedPublisherCheckIds = [string[]] $script:PublisherCheckIds
[Array]::Sort($SortedPublisherCheckIds, [StringComparer]::Ordinal)
for ($Index = 0; $Index -lt 8; $Index++) {
	Assert-True ($SortedContextCheckIds[$Index] -ceq $SortedPublisherCheckIds[$Index]) "Aggregate context and publisher check ids must match in lockstep (index $Index)."
}

# The aggregate filters each template job's checks by selection in template order; the publisher filters its contract checks in
# contract order. Both must agree per job key or the receipt fails receipt_selection_mismatch.
$RequirementsTemplate = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts\ci\ci-acceptance-requirements.json') -Raw | ConvertFrom-Json
Assert-True (@($RequirementsTemplate.jobs).Count -eq @($script:PublisherContracts.Keys).Count) 'Publisher contracts and requirements template must declare the same number of jobs.'
foreach ($TemplateJob in @($RequirementsTemplate.jobs)) {
	Assert-True (@($script:PublisherContracts.Keys) -ccontains $TemplateJob.key) "Publisher must declare a contract for requirements-template job '$($TemplateJob.key)'."
	$ContractChecks = @($script:PublisherContracts[$TemplateJob.key].Checks)
	Assert-True ((@($TemplateJob.checks | Where-Object { $ContractChecks -ccontains $_ }) -join "`n") -ceq ($ContractChecks -join "`n")) "Publisher contract '$($TemplateJob.key)' checks must be an in-order subset of the requirements-template job checks."
}

Write-Output 'PASS: CI acceptance receipt publisher validates exact supported evidence and emits bounded shadow-only upload roots'
