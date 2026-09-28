$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ScriptPath = Join-Path $RepositoryRoot 'scripts\ci\New-CiAcceptanceReceipt.ps1'
. $ScriptPath

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw $Message }
}

function Assert-Rejected([scriptblock] $Action, [string] $Reason) {
	try { & $Action; throw "Expected rejection '$Reason'." }
	catch {
		if ($_.Exception.Message -ceq "Expected rejection '$Reason'." -or $_.Exception.Message -cnotmatch ('^' + [regex]::Escape($Reason) + '(?::|$)')) { throw }
	}
}

$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('aetheln-acceptance-receipt-' + [guid]::NewGuid().ToString('N'))
$EvidenceRoot = Join-Path $FixtureRoot 'evidence'
$InputPath = Join-Path $FixtureRoot 'input.json'
$OutputPath = Join-Path $FixtureRoot 'ci-acceptance-receipt.json'
$Utf8 = New-Object Text.UTF8Encoding($false)

function Get-Sha256([string] $Path) {
	return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TestActionManifest {
	param([switch] $WithSubpath)
	$Items = @(
		[pscustomobject][ordered]@{ uses='actions/checkout'; revision=('1' * 40) },
		[pscustomobject][ordered]@{ uses=$(if ($WithSubpath) { 'actions/upload-artifact/subpath' } else { 'actions/upload-artifact' }); revision=('2' * 40) }
	)
	$Lines = ($Items | ForEach-Object { $_.uses + '@' + $_.revision }) -join "`n"
	$Hash = [Security.Cryptography.SHA256]::Create()
	try { $Digest = ([BitConverter]::ToString($Hash.ComputeHash($Utf8.GetBytes($Lines + "`n")))).Replace('-','').ToLowerInvariant() }
	finally { $Hash.Dispose() }
	return [pscustomobject][ordered]@{ manifestSha256=$Digest; items=$Items }
}

function Get-TestReceiptInput {
	param([string] $VisualSha256, [long] $VisualSize)
	return [pscustomobject][ordered]@{
		repository = [pscustomobject][ordered]@{ fullName = 'ShayShimoni/aetheln-online' }
		event = [pscustomobject][ordered]@{ kind = 'pull_request'; classification = 'pull_request_acceptance'; actor = 'owner'; triggeringActor = 'owner' }
		source = [pscustomobject][ordered]@{ baseRevision = ('a' * 40); headRevision = ('b' * 40); testedRevision = ('c' * 40) }
		workflow = [pscustomobject][ordered]@{ id = '9876543'; revision = ('c' * 40); parents = @(('a' * 40), ('b' * 40)); sha256 = ('d' * 64) }
		controller = [pscustomobject][ordered]@{ revision = ('a' * 40); blobOid = ('e' * 40); sha256 = ('f' * 64) }
		policy = [pscustomobject][ordered]@{ version = 'shadow-v1'; digest = ('1' * 64) }
		actions = Get-TestActionManifest
		run = [pscustomobject][ordered]@{ id = '35533038331'; attempt = 2 }
		attemptAnchor = [pscustomobject][ordered]@{ schemaVersion='aetheln.current-attempt-anchor/v1'; runId='35533038331'; runAttempt=2; nonce=('6' * 64) }
		selection = [pscustomobject][ordered]@{ checks = @('visual-package') }
		results = [pscustomobject][ordered]@{ checks = @(
			[pscustomobject][ordered]@{
				id = 'visual-package'; jobName = 'visual-package-proof'; conclusion = 'success'; nativeExitCode = $null
				infrastructureFailure = $null; terminal = $true; cleanupVerified = $null
				evidence = @([pscustomobject][ordered]@{ name = 'visual-package-report.json'; sha256 = $VisualSha256; sizeBytes = $VisualSize })
			}
		) }
	}
}

function New-TestVisualReport {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory fixture.')]
	param([string] $Conclusion = 'success', [string] $Revision = ('c' * 40))
	$Output = @('stdout: fixture pass')
	$CapturedBytes = $Utf8.GetByteCount($Output[0])
	$Results = @(
		[pscustomobject][ordered]@{
			id='visual-package'; path='.\visuals\Test-VisualPackage.ps1'; startedUtc='2026-09-20T20:00:00.0000000Z'; finishedUtc='2026-09-20T20:00:01.0000000Z'
			nativeExitCode=0; conclusion='success'
			capture=[pscustomobject][ordered]@{ maxLineUtf8Bytes=4096; maxLines=200; maxAggregateUtf8Bytes=131072; observedLineCount=1; capturedLineCount=1; capturedUtf8Bytes=$CapturedBytes; truncatedLineCount=0; droppedLineCount=0 }
			output=$Output
		},
		[pscustomobject][ordered]@{
			id='visual-package-regressions'; path='.\visuals\tests\Test-VisualPackageValidation.ps1'; startedUtc='2026-09-20T20:00:01.0000000Z'; finishedUtc='2026-09-20T20:00:02.0000000Z'
			nativeExitCode=0; conclusion='success'
			capture=[pscustomobject][ordered]@{ maxLineUtf8Bytes=4096; maxLines=200; maxAggregateUtf8Bytes=131072; observedLineCount=1; capturedLineCount=1; capturedUtf8Bytes=$CapturedBytes; truncatedLineCount=0; droppedLineCount=0 }
			output=$Output
		}
	)
	return [pscustomobject][ordered]@{
		schemaVersion='aetheln.visual-package-report/v1'; repository='ShayShimoni/aetheln-online'; revision=$Revision
		run=[pscustomobject][ordered]@{ id='35533038331'; attempt=2 }; results=$Results; conclusion=$Conclusion
	}
}

function New-TestPortableReport {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory fixture.')]
	param()
	$Names = @(
		'formatting-policy','markdown-links','source-control-policy','observability-contract','build-packaged-artifacts-tests',
		'packaged-smoke-test-tests','network-authority-spike-tests','engine-runner-gate-tests','unreal-automation-tests',
		'server-cook-reference-tests','target-composition-tests','build-provenance-tests','markdown-link-tests',
		'formatting-policy-tests','observability-contract-tests','ci-suite-tests','engine-runner-post-command-state-tests',
		'prototype-quality-workflow-tests','visual-package-evidence-tests','runner-scheduling-policy-tests','ci-selection-tests',
		'ci-acceptance-receipt-tests','ci-acceptance-aggregate-tests','ci-acceptance-publisher-tests','ci-acceptance-context-tests',
		'ci-activation-candidate-tests','compile-workspace-tests','engine-host-lease-tests',
		'managed-compile-registration-tests','managed-compile-workspace-tests','managed-compile-integration-tests',
		'routine-compile-deadline-tests','routine-compile-resources-tests','routine-compile-command-tests','routine-compile-gate-tests',
		'psscriptanalyzer'
	)
	$Checks = @($Names | ForEach-Object { [pscustomobject][ordered]@{name=$_;tier=$(if($_-ceq'psscriptanalyzer'){'advisory'}else{'required'});status='passed';durationSeconds=0.01;command='fixture';message='passed'} })
	return [pscustomobject][ordered]@{schemaVersion=1;revision=('c'*40);startedUtc='2026-09-20T20:00:00.0000000Z';finishedUtc='2026-09-20T20:00:01.0000000Z';checks=$Checks;summary=[pscustomobject][ordered]@{total=$Checks.Count;passed=$Checks.Count;failed=0;skipped=0;requiredFailed=0}}
}

function New-TestEngineReport {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory fixture.')]
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

function New-TestUnrealReport {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory fixture.')]
	param()
	$Tests = @(
		[pscustomobject][ordered]@{fullTestPath='Aetheln.GameCombat.NetworkSpike.Authority';state='Success';status='passed';durationSeconds=0.1;warningCount=0;errorCount=0},
		[pscustomobject][ordered]@{fullTestPath='Aetheln.Harness.ProjectAndModuleLoad';state='Success';status='passed';durationSeconds=0.1;warningCount=0;errorCount=0}
	)
	return [pscustomobject][ordered]@{schemaId='aetheln.unreal-automation';schemaVersion=1;mode='production';sourceRevision=('c'*40);engineRevision='71fe36aac5a8df5ccd66c763ffc902b29b6a9c43';projectName='AethelnOnline';filter='^Aetheln.Harness.ProjectAndModuleLoad$+^Aetheln.GameCombat.NetworkSpike.Authority$';timeoutSeconds=600;startedUtc='2026-09-20T20:00:00.0000000Z';finishedUtc='2026-09-20T20:00:01.0000000Z';processExitCode=0;repositoryCleanBefore=$true;repositoryCleanAfter=$true;outputs=[pscustomobject][ordered]@{unrealReport='TestResults/UnrealAutomation/index.json';log='Saved/Logs/AethelnUnrealAutomation.log'};tests=$Tests;summary=[pscustomobject][ordered]@{total=2;passed=2;passedWithWarnings=0;failed=0;notRun=0;missing=0;requiredFailed=0};result='passed';failureReason='none'}
}

function Write-Input($Value, [string] $Path = $InputPath) {
	[IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 12 -Compress) + "`n"), $Utf8)
}

try {
	[void] (New-Item -ItemType Directory -Path $EvidenceRoot -Force)
	$VisualPath = Join-Path $EvidenceRoot 'visual-package-report.json'
	[IO.File]::WriteAllText($VisualPath, ((New-TestVisualReport | ConvertTo-Json -Depth 10 -Compress) + "`n"), $Utf8)
	$VisualSize = (Get-Item -LiteralPath $VisualPath).Length
	$VisualSha256 = Get-Sha256 $VisualPath
	$ReceiptInput = Get-TestReceiptInput -VisualSha256 $VisualSha256 -VisualSize $VisualSize
	Write-Input $ReceiptInput

	$Receipt = New-CiAcceptanceReceipt -InputPath $InputPath -EvidenceRoot $EvidenceRoot -OutputPath $OutputPath
	Assert-True (Test-Path -LiteralPath $OutputPath -PathType Leaf) 'A valid receipt should be published.'
	$Bytes = [IO.File]::ReadAllBytes($OutputPath)
	Assert-True ($Bytes.Length -le 65536 -and $Bytes[0] -ne 0xEF) 'Receipt must be bounded UTF-8 without BOM.'
	$Parsed = [Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json
	Assert-True (($Parsed.PSObject.Properties.Name -join ',') -ceq 'schemaVersion,repository,event,source,workflow,controller,policy,actions,run,attemptAnchor,selection,results,acceptance') 'Root receipt schema must be closed and ordered.'
	Assert-True ($Parsed.schemaVersion -ceq 'aetheln.ci-acceptance-receipt/v1') 'Receipt schema version should be exact.'
	Assert-True (($Parsed.workflow.PSObject.Properties.Name -join ',') -ceq 'id,revision,parents,sha256') 'Workflow schema must bind the API workflow identity and exact revision bytes.'
	Assert-True (($Parsed.actions.PSObject.Properties.Name -join ',') -ceq 'manifestSha256,items' -and ($Parsed.actions.items[0].PSObject.Properties.Name -join ',') -ceq 'uses,revision') 'Action schema must bind the deterministic full-SHA pin manifest.'
	Assert-True (($Parsed.results.checks[0].PSObject.Properties.Name -join ',') -ceq 'id,jobName,conclusion,nativeExitCode,infrastructureFailure,terminal,cleanupVerified,evidence') 'Result schema must bind native, infrastructure, terminal, cleanup, and evidence outcomes.'
	Assert-True (-not $Parsed.acceptance.authoritative -and -not $Parsed.acceptance.grantsAcceptance -and $Parsed.acceptance.shadow) 'Package 3A receipts must remain shadow-only and non-authoritative.'
	Assert-True ($Parsed.acceptance.terminal -and -not $Parsed.acceptance.infrastructureFailure -and $null -eq $Parsed.acceptance.cleanupVerified) 'A visual-only receipt should record terminal success without claiming native cleanup.'
	Assert-True ($Receipt.run.id -ceq '35533038331' -and $Receipt.run.attempt -eq 2) 'Run and attempt identity must round-trip exactly.'
	Assert-True ($Receipt.attemptAnchor.runId -ceq $Receipt.run.id -and $Receipt.attemptAnchor.runAttempt -eq $Receipt.run.attempt -and $Receipt.attemptAnchor.nonce -ceq ('6' * 64)) 'The receipt must bind the exact nonzero current-attempt nonce.'

	# The consumer must accept the producer's exact boundary output. This is a
	# real cross-script compatibility check, not two independent schema fixtures.
	. (Join-Path $RepositoryRoot 'scripts\ci\Invoke-CiAcceptanceAggregate.ps1')
	$ConsumerContext = [pscustomobject][ordered]@{
		schemaVersion = 'aetheln.ci-acceptance-context/v1'
		repository = $Parsed.repository; event = $Parsed.event; source = $Parsed.source; workflow = $Parsed.workflow
		actions = $Parsed.actions; controller = $Parsed.controller; policy = $Parsed.policy; run = $Parsed.run; attemptAnchor = $Parsed.attemptAnchor
		selectorBinding = [pscustomobject][ordered]@{ jobName='ci-selection-shadow'; artifactId='1001'; artifactName=('ci-selection-shadow-35533038331-2-' + ('6' * 64)); digest=('sha256:' + ('7' * 64)) }
		producerBindings = @([pscustomobject][ordered]@{ key='visual'; jobName='visual-package-proof'; artifactId='2001'; artifactName=('ci-receipt-visual-35533038331-2-' + ('6' * 64)); digest=('sha256:' + ('8' * 64)) })
	}
	$ConsumerRequirement = [pscustomobject][ordered]@{
		key = 'visual'; jobName = 'visual-package-proof'; selected = $true
		artifactName = ('ci-receipt-visual-35533038331-2-' + ('6' * 64)); checks = @('visual-package')
	}
	$ConsumerArchive = [pscustomobject][ordered]@{ entries = @(
		[pscustomobject][ordered]@{ name='ci-acceptance-receipt.json'; bytes=$Bytes; sizeBytes=[long]$Bytes.Length; sha256=(Get-AcceptanceSha256 $Bytes) },
		[pscustomobject][ordered]@{ name='visual-package-report.json'; bytes=[IO.File]::ReadAllBytes($VisualPath); sizeBytes=[long]$VisualSize; sha256=$VisualSha256 }
	) }
	Assert-AcceptanceContext $ConsumerContext
	$ConsumerResultEnvelope = @(Assert-CiAcceptanceReceipt -Receipt $Parsed -Context $ConsumerContext -Requirement $ConsumerRequirement -Archive $ConsumerArchive)
	Assert-True ($ConsumerResultEnvelope.Count -eq 1 -and @($ConsumerResultEnvelope[0]).Count -eq 1) 'The aggregate consumer must accept the producer receipt and exact semantic evidence at their shared boundary.'
	$OutputPath = Join-Path $FixtureRoot 'ci-acceptance-receipt.json'

	Assert-Rejected { New-CiAcceptanceReceipt -InputPath $InputPath -EvidenceRoot $EvidenceRoot -OutputPath $OutputPath } 'receipt_exists'
	Remove-Item -LiteralPath $OutputPath -Force
	$SecondOutput = Join-Path $FixtureRoot 'repeat\ci-acceptance-receipt.json'
	[void] (New-CiAcceptanceReceipt -InputPath $InputPath -EvidenceRoot $EvidenceRoot -OutputPath $SecondOutput)
	Assert-True ([Convert]::ToBase64String($Bytes) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($SecondOutput))) 'Identical accepted inputs and evidence must produce deterministic receipt bytes.'
	Remove-Item -LiteralPath $SecondOutput -Force

	$Duplicate = [IO.File]::ReadAllText($InputPath).Replace('"repository":{', '"repository":{"fullName":"evil/repo","fullName":"ShayShimoni/aetheln-online"},"discarded":{')
	$DuplicatePath = Join-Path $FixtureRoot 'duplicate.json'; [IO.File]::WriteAllText($DuplicatePath, $Duplicate, $Utf8)
	Assert-Rejected { New-CiAcceptanceReceipt -InputPath $DuplicatePath -EvidenceRoot $EvidenceRoot -OutputPath $OutputPath } 'receipt_json_duplicate_property'
	Assert-True (-not (Test-Path -LiteralPath $OutputPath)) 'Invalid duplicate JSON must not publish output.'

	foreach ($Mutation in @(
		@{ name='extra-root'; action={ param($x) Add-Member -InputObject $x -NotePropertyName extra -NotePropertyValue $true } },
		@{ name='wrong-parent'; action={ param($x) $x.workflow.parents[0] = ('9' * 40) } },
		@{ name='workflow-id'; action={ param($x) $x.workflow.id = '0' } },
		@{ name='workflow-id-overflow'; action={ param($x) $x.workflow.id = '99999999999999999999' } },
		@{ name='stale-controller'; action={ param($x) $x.controller.revision = ('9' * 40) } },
		@{ name='action-manifest'; action={ param($x) $x.actions.manifestSha256 = ('0' * 64) } },
		@{ name='action-short-revision'; action={ param($x) $x.actions.items[0].revision = ('1' * 39) } },
		@{ name='action-duplicate'; action={ param($x) $x.actions.items[1].uses = $x.actions.items[0].uses } },
		@{ name='wrong-attempt'; action={ param($x) $x.run.attempt = '2' } },
		@{ name='run-id-overflow'; action={ param($x) $x.run.id = '99999999999999999999' } },
		@{ name='anchor-missing'; action={ param($x) $x.PSObject.Properties.Remove('attemptAnchor') } },
		@{ name='anchor-legacy-property'; action={ param($x) $Anchor=$x.attemptAnchor; $x.PSObject.Properties.Remove('attemptAnchor'); $x | Add-Member -NotePropertyName currentAttemptAnchor -NotePropertyValue $Anchor } },
		@{ name='anchor-null'; action={ param($x) $x.attemptAnchor = $null } },
		@{ name='anchor-short'; action={ param($x) $x.attemptAnchor.nonce = ('6' * 63) } },
		@{ name='anchor-uppercase'; action={ param($x) $x.attemptAnchor.nonce = ('A' * 64) } },
		@{ name='anchor-nonhex'; action={ param($x) $x.attemptAnchor.nonce = ('g' * 64) } },
		@{ name='anchor-trailing-newline'; action={ param($x) $x.attemptAnchor.nonce = (('6' * 64) + "`n") } },
		@{ name='anchor-all-zero'; action={ param($x) $x.attemptAnchor.nonce = ('0' * 64) } },
		@{ name='anchor-run-replay'; action={ param($x) $x.attemptAnchor.runId = '35533038330' } },
		@{ name='anchor-attempt-replay'; action={ param($x) $x.attemptAnchor.runAttempt = 1 } },
		@{ name='uppercase-policy'; action={ param($x) $x.policy.version = 'Shadow-v1' } },
		@{ name='invalid-actor'; action={ param($x) $x.event.triggeringActor = 'bad actor' } },
		@{ name='duplicate-selection'; action={ param($x) $x.selection.checks = @('visual-package','visual-package') } },
		@{ name='retired-delivery-harness'; action={ param($x) $x.selection.checks = @('delivery-harness'); $x.results.checks[0].id = 'delivery-harness' } },
		@{ name='unexpected-result'; action={ param($x) $x.results.checks[0].id = 'portable' } },
		@{ name='invalid-producer-job'; action={ param($x) $x.results.checks[0].jobName = '' } },
		@{ name='failed-result'; action={ param($x) $x.results.checks[0].conclusion = 'failure' } },
		@{ name='nonterminal'; action={ param($x) $x.results.checks[0].terminal = $false } },
		@{ name='native-summary-lie'; action={ param($x) $x.results.checks[0].nativeExitCode = 7 } },
		@{ name='infrastructure-summary-lie'; action={ param($x) $x.results.checks[0].infrastructureFailure = 'runner_lost' } },
		@{ name='cleanup-summary-lie'; action={ param($x) $x.results.checks[0].cleanupVerified = $false } },
		@{ name='evidence-digest'; action={ param($x) $x.results.checks[0].evidence[0].sha256 = ('0' * 64) } },
		@{ name='evidence-size'; action={ param($x) $x.results.checks[0].evidence[0].sizeBytes++ } },
		@{ name='evidence-traversal'; action={ param($x) $x.results.checks[0].evidence[0].name = '../report.json' } },
		@{ name='evidence-absolute'; action={ param($x) $x.results.checks[0].evidence[0].name = 'C:/report.json' } }
	)) {
		$Candidate = Get-TestReceiptInput -VisualSha256 $VisualSha256 -VisualSize $VisualSize
		& $Mutation.action $Candidate
		$Path = Join-Path $FixtureRoot ($Mutation.name + '.json'); Write-Input $Candidate $Path
		Assert-Rejected { New-CiAcceptanceReceipt -InputPath $Path -EvidenceRoot $EvidenceRoot -OutputPath $OutputPath } 'receipt_invalid'
		Assert-True (-not (Test-Path -LiteralPath $OutputPath)) "Invalid case '$($Mutation.name)' must not publish output."
	}

	$Missing = Get-TestReceiptInput -VisualSha256 $VisualSha256 -VisualSize $VisualSize; $Missing.results.checks[0].PSObject.Properties.Remove('terminal')
	$MissingPath = Join-Path $FixtureRoot 'missing.json'; Write-Input $Missing $MissingPath
	Assert-Rejected { New-CiAcceptanceReceipt -InputPath $MissingPath -EvidenceRoot $EvidenceRoot -OutputPath $OutputPath } 'receipt_invalid'

	$OversizePath = Join-Path $FixtureRoot 'oversize.json'; [IO.File]::WriteAllBytes($OversizePath, [byte[]]::new(65537))
	Assert-Rejected { New-CiAcceptanceReceipt -InputPath $OversizePath -EvidenceRoot $EvidenceRoot -OutputPath $OutputPath } 'receipt_input_limit'

	$OversizeEvidenceRoot = Join-Path $FixtureRoot 'oversize-evidence-root'; [void] (New-Item -ItemType Directory -Path $OversizeEvidenceRoot)
	$OversizeEvidencePath = Join-Path $OversizeEvidenceRoot 'visual-package-report.json'
	$OversizeEvidenceStream = New-Object IO.FileStream($OversizeEvidencePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
	try { $OversizeEvidenceStream.SetLength(4MB + 1) } finally { $OversizeEvidenceStream.Dispose() }
	$OversizeEvidence = Get-TestReceiptInput -VisualSha256 (Get-Sha256 $OversizeEvidencePath) -VisualSize (4MB + 1)
	$OversizeEvidenceInput = Join-Path $FixtureRoot 'oversize-evidence.json'; Write-Input $OversizeEvidence $OversizeEvidenceInput
	Assert-Rejected { New-CiAcceptanceReceipt -InputPath $OversizeEvidenceInput -EvidenceRoot $OversizeEvidenceRoot -OutputPath $OutputPath } 'receipt_invalid'

	foreach ($SemanticFixture in @(
		@{id='portable';name='ci-report.json';report=(New-TestPortableReport);native=$null;cleanup=$null},
		@{id='native-client-server-compile';name='engine-runner-report.json';report=(New-TestEngineReport);native=0;cleanup=$true},
		@{id='unreal-editor-automation';name='unreal-automation-report.json';report=(New-TestUnrealReport);native=0;cleanup=$null}
	)) {
		$SemanticPath = Join-Path $EvidenceRoot $SemanticFixture.name
		[IO.File]::WriteAllText($SemanticPath, (($SemanticFixture.report | ConvertTo-Json -Depth 12 -Compress) + "`n"), $Utf8)
		$SemanticInput = Get-TestReceiptInput -VisualSha256 (Get-Sha256 $SemanticPath) -VisualSize ((Get-Item $SemanticPath).Length)
		$SemanticInput.selection.checks[0] = $SemanticFixture.id
		$SemanticInput.results.checks[0].id = $SemanticFixture.id
		$SemanticInput.results.checks[0].nativeExitCode = $SemanticFixture.native
		$SemanticInput.results.checks[0].cleanupVerified = $SemanticFixture.cleanup
		$SemanticInput.results.checks[0].evidence[0].name = $SemanticFixture.name
		$SemanticInputPath = Join-Path $FixtureRoot ('supported-' + $SemanticFixture.id + '.json'); Write-Input $SemanticInput $SemanticInputPath
		$SemanticOutput = Join-Path $FixtureRoot ($SemanticFixture.id + '\ci-acceptance-receipt.json')
		$SemanticReceipt = New-CiAcceptanceReceipt -InputPath $SemanticInputPath -EvidenceRoot $EvidenceRoot -OutputPath $SemanticOutput
		Assert-True ($SemanticReceipt.results.checks[0].id -ceq $SemanticFixture.id -and $SemanticReceipt.acceptance.shadow -and -not $SemanticReceipt.acceptance.authoritative -and -not $SemanticReceipt.acceptance.grantsAcceptance) "Supported semantic receipt '$($SemanticFixture.id)' must stay shadow-only."
		$BadReport = $SemanticFixture.report | ConvertTo-Json -Depth 12 | ConvertFrom-Json
		if ($SemanticFixture.id -ceq 'portable') { $BadReport.summary.requiredFailed = 1 }
		elseif ($SemanticFixture.id -ceq 'native-client-server-compile') { $BadReport.supervisor.cleanupVerified = $false }
		else { $BadReport.tests[0].status = 'failed' }
		[IO.File]::WriteAllText($SemanticPath, (($BadReport | ConvertTo-Json -Depth 12 -Compress) + "`n"), $Utf8)
		$SemanticInput.results.checks[0].evidence[0].sha256 = Get-Sha256 $SemanticPath
		$SemanticInput.results.checks[0].evidence[0].sizeBytes = (Get-Item $SemanticPath).Length
		Write-Input $SemanticInput $SemanticInputPath
		$FailureKind = if ($SemanticFixture.id -ceq 'portable') { 'failure' } else { 'invalid' }
		Assert-Rejected { New-CiAcceptanceReceipt -InputPath $SemanticInputPath -EvidenceRoot $EvidenceRoot -OutputPath (Join-Path $FixtureRoot ('bad-' + $SemanticFixture.id + '\ci-acceptance-receipt.json')) } ('receipt_semantic_evidence_' + $FailureKind + ':' + $SemanticFixture.id)
	}

	foreach ($PortableTypeCase in @(
		@{name='schema-string';mutate={param($x)$x.schemaVersion='1'}},
		@{name='check-duration-boolean';mutate={param($x)$x.checks[0].durationSeconds=$true}},
		@{name='check-duration-string';mutate={param($x)$x.checks[0].durationSeconds='0.01'}},
		@{name='summary-total-string';mutate={param($x)$x.summary.total=[string]$x.summary.total}},
		@{name='summary-passed-string';mutate={param($x)$x.summary.passed=[string]$x.summary.passed}},
		@{name='summary-failed-string';mutate={param($x)$x.summary.failed='0'}},
		@{name='summary-skipped-string';mutate={param($x)$x.summary.skipped='0'}},
		@{name='summary-required-failed-string';mutate={param($x)$x.summary.requiredFailed='0'}}
	)) {
		$BadPortable = New-TestPortableReport; & $PortableTypeCase.mutate $BadPortable
		$BadPortableBytes = $Utf8.GetBytes(($BadPortable | ConvertTo-Json -Depth 12 -Compress) + "`n")
		try { Assert-Rejected { Assert-AcceptancePortableEvidence -Bytes $BadPortableBytes -Identity (Get-TestReceiptInput -VisualSha256 ('0'*64) -VisualSize 0) } 'receipt_semantic_evidence_invalid:portable' }
		catch { throw "Portable type fixture '$($PortableTypeCase.name)' failed: $($_.Exception.Message)" }
	}
	$SkippedAnalyzer = New-TestPortableReport
	$SkippedAnalyzer.checks[$SkippedAnalyzer.checks.Count - 1].status = 'skipped'
	$SkippedAnalyzer.summary.passed--
	$SkippedAnalyzer.summary.skipped++
	$SkippedAnalyzerBytes = $Utf8.GetBytes(($SkippedAnalyzer | ConvertTo-Json -Depth 12 -Compress) + "`n")
	Assert-Rejected { Assert-AcceptancePortableEvidence -Bytes $SkippedAnalyzerBytes -Identity (Get-TestReceiptInput -VisualSha256 ('0'*64) -VisualSize 0) } 'receipt_semantic_evidence_failure:portable'

	foreach ($NativeTypeCase in @(
		@{name='schema-string';mutate={param($x)$x.schemaVersion='1'}},
		@{name='managed-check-omitted';mutate={param($x)$x.checks=@($x.checks|Where-Object name -cne 'managed-compile-workspace');$x.summary.total--;$x.summary.passed--}},
		@{name='workspace-omitted';mutate={param($x)$x.PSObject.Properties.Remove('managedWorkspace')}},
		@{name='workspace-extra-field';mutate={param($x)$x.managedWorkspace|Add-Member -NotePropertyName extra -NotePropertyValue $true}},
		@{name='workspace-schema-string';mutate={param($x)$x.managedWorkspace.schemaVersion='1'}},
		@{name='workspace-registration-id';mutate={param($x)$x.managedWorkspace.registrationId='not-a-registration'}},
		@{name='workspace-registration-sha-type';mutate={param($x)$x.managedWorkspace.registrationSha256=$true}},
		@{name='workspace-preparation-sha';mutate={param($x)$x.managedWorkspace.preparationReceiptSha256='bad'}},
		@{name='workspace-revision';mutate={param($x)$x.managedWorkspace.revision=('d'*40)}},
		@{name='workspace-synchronized-type';mutate={param($x)$x.managedWorkspace.synchronized='true'}},
		@{name='resources-omitted';mutate={param($x)$x.PSObject.Properties.Remove('compileResources')}},
		@{name='resources-extra-field';mutate={param($x)$x.compileResources|Add-Member -NotePropertyName extra -NotePropertyValue 1}},
		@{name='resources-schema-string';mutate={param($x)$x.compileResources.schemaVersion='1'}},
		@{name='resources-sample-interval';mutate={param($x)$x.compileResources.sampleIntervalMilliseconds=4999}},
		@{name='resources-recovery-floor-string';mutate={param($x)$x.compileResources.recoveryFloorBytes='21474836480'}},
		@{name='resources-pressure-threshold';mutate={param($x)$x.compileResources.pressureThresholdBytes=1GB}},
		@{name='resources-failure';mutate={param($x)$x.compileResources.failureReason='resource_pressure'}},
		@{name='resources-sample-count-string';mutate={param($x)$x.compileResources.sampleCount='2'}},
		@{name='resources-measurement-string';mutate={param($x)$x.compileResources.measurementCount='4'}},
		@{name='resources-measurement-relationship';mutate={param($x)$x.compileResources.measurementCount=1}},
		@{name='resources-gap-string';mutate={param($x)$x.compileResources.maximumSampleGapMilliseconds='5000'}},
		@{name='resources-pressure';mutate={param($x)$x.compileResources.consecutivePressureSamples=3;$x.compileResources.maximumConsecutivePressureSamples=3}},
		@{name='resources-maximum-pressure-string';mutate={param($x)$x.compileResources.maximumConsecutivePressureSamples='0'}},
		@{name='resources-pressure-relationship';mutate={param($x)$x.compileResources.consecutivePressureSamples=1}},
		@{name='resources-ram-string';mutate={param($x)$x.compileResources.minimumAvailableRamBytes='17179869184'}},
		@{name='resources-commit-string';mutate={param($x)$x.compileResources.minimumCommitHeadroomBytes='17179869184'}},
		@{name='resources-cores-string';mutate={param($x)$x.compileResources.physicalCores='8'}},
		@{name='resources-admissions';mutate={param($x)$x.compileResources.targetAdmissionCount=1}},
		@{name='resources-min-action-string';mutate={param($x)$x.compileResources.minimumActionLimit='2'}},
		@{name='resources-max-action-string';mutate={param($x)$x.compileResources.maximumActionLimit='4'}},
		@{name='resources-action-relationship';mutate={param($x)$x.compileResources.minimumActionLimit=4;$x.compileResources.maximumActionLimit=2}},
		@{name='resources-volumes-empty';mutate={param($x)$x.compileResources.volumes=@()}},
		@{name='resources-volume-extra-field';mutate={param($x)$x.compileResources.volumes[0]|Add-Member -NotePropertyName extra -NotePropertyValue 1}},
		@{name='resources-volume-id-empty';mutate={param($x)$x.compileResources.volumes[0].volumeId=''}},
		@{name='resources-volume-duplicate';mutate={param($x)$x.compileResources.volumes=@($x.compileResources.volumes[0],($x.compileResources.volumes[0]|ConvertTo-Json|ConvertFrom-Json))}},
		@{name='resources-volume-allocation-string';mutate={param($x)$x.compileResources.volumes[0].knownAllocationBytes='0'}},
		@{name='resources-volume-minimum-string';mutate={param($x)$x.compileResources.volumes[0].minimumAvailableBytes='53687091200'}},
		@{name='resources-disk-floor';mutate={param($x)$x.compileResources.volumes[0].minimumAvailableBytes=20GB}},
		@{name='check-duration-boolean';mutate={param($x)$x.checks[0].durationSeconds=$true}},
		@{name='check-duration-string';mutate={param($x)$x.checks[0].durationSeconds='0.01'}},
		@{name='summary-total-string';mutate={param($x)$x.summary.total=[string]$x.summary.total}},
		@{name='supervisor-exit-string';mutate={param($x)$x.supervisor.childExitCode='0'}},
		@{name='supervisor-timeout-string';mutate={param($x)$x.supervisor.timedOut='false'}},
		@{name='build-presence-string';mutate={param($x)$x.compileEvidence.builds[0].intermediateBuildDirectoryPresentBeforeRun='true'}},
		@{name='build-action-counter-string';mutate={param($x)$x.compileEvidence.builds[0].lastObservedAction='1'}},
		@{name='build-action-state-contradiction';mutate={param($x)$x.compileEvidence.builds[0].actionCounterState='not_observed'}},
		@{name='build-makefile-contradiction';mutate={param($x)$x.compileEvidence.builds[0].makefileObservation='created'}},
		@{name='build-up-to-date-string';mutate={param($x)$x.compileEvidence.builds[0].upToDateObserved='false'}},
		@{name='build-executor-count-string';mutate={param($x)$x.compileEvidence.builds[0].executorSummaryCount='1'}}
	)) {
		$BadNative = New-TestEngineReport; & $NativeTypeCase.mutate $BadNative
		$BadNativeBytes = $Utf8.GetBytes(($BadNative | ConvertTo-Json -Depth 12 -Compress) + "`n")
		try { Assert-Rejected { Assert-AcceptanceEngineRunnerEvidence -Bytes $BadNativeBytes -Identity (Get-TestReceiptInput -VisualSha256 ('0'*64) -VisualSize 0) } 'receipt_semantic_evidence_invalid:native-client-server-compile' }
		catch { throw "Native type fixture '$($NativeTypeCase.name)' failed: $($_.Exception.Message)" }
	}

	foreach ($UnrealTypeCase in @(
		@{name='schema-string';mutate={param($x)$x.schemaVersion='1'}},
		@{name='timeout-string';mutate={param($x)$x.timeoutSeconds='600'}},
		@{name='exit-string';mutate={param($x)$x.processExitCode='0'}},
		@{name='clean-before-string';mutate={param($x)$x.repositoryCleanBefore='true'}},
		@{name='test-duration-string';mutate={param($x)$x.tests[0].durationSeconds='0.1'}},
		@{name='warning-count-string';mutate={param($x)$x.tests[0].warningCount='0'}},
		@{name='summary-passed-string';mutate={param($x)$x.summary.passed='2'}},
		@{name='summary-relationship';mutate={param($x)$x.summary.total=3}}
	)) {
		$BadUnreal = New-TestUnrealReport; & $UnrealTypeCase.mutate $BadUnreal
		$BadUnrealBytes = $Utf8.GetBytes(($BadUnreal | ConvertTo-Json -Depth 12 -Compress) + "`n")
		try { Assert-Rejected { Assert-AcceptanceUnrealAutomationEvidence -Bytes $BadUnrealBytes -Identity (Get-TestReceiptInput -VisualSha256 ('0'*64) -VisualSize 0) } 'receipt_semantic_evidence_invalid:unreal-editor-automation' }
		catch { throw "Unreal type fixture '$($UnrealTypeCase.name)' failed: $($_.Exception.Message)" }
	}

	foreach ($UnsupportedId in @('clean-package-provenance-smoke','content-reference-validation','controller-contract','controller-operational-proof')) {
		$Unsupported = Get-TestReceiptInput -VisualSha256 $VisualSha256 -VisualSize $VisualSize
		$Unsupported.selection.checks[0] = $UnsupportedId; $Unsupported.results.checks[0].id = $UnsupportedId
		if ($UnsupportedId -in @('clean-package-provenance-smoke','native-client-server-compile')) { $Unsupported.results.checks[0].nativeExitCode=0; $Unsupported.results.checks[0].cleanupVerified=$true }
		$UnsupportedPath = Join-Path $FixtureRoot ('unsupported-' + $UnsupportedId + '.json'); Write-Input $Unsupported $UnsupportedPath
		Assert-Rejected { New-CiAcceptanceReceipt -InputPath $UnsupportedPath -EvidenceRoot $EvidenceRoot -OutputPath $OutputPath } ('receipt_semantic_evidence_unsupported:' + $UnsupportedId)
	}
	$VisualSummaryLie = Get-TestReceiptInput -VisualSha256 $VisualSha256 -VisualSize $VisualSize
	$VisualSummaryLie.results.checks[0].nativeExitCode = 0
	$VisualSummaryLiePath = Join-Path $FixtureRoot 'visual-native-summary-lie.json'; Write-Input $VisualSummaryLie $VisualSummaryLiePath
	Assert-Rejected { New-CiAcceptanceReceipt -InputPath $VisualSummaryLiePath -EvidenceRoot $EvidenceRoot -OutputPath $OutputPath } 'receipt_semantic_evidence_invalid:visual-package'

	$WrongNamePath = Join-Path $EvidenceRoot 'wrong-visual-report.json'
	[IO.File]::WriteAllBytes($WrongNamePath, [IO.File]::ReadAllBytes($VisualPath))
	foreach ($SemanticCase in @(
		@{ name='report-failure'; reason='receipt_semantic_evidence_failure:visual-package'; mutate={ param($r) $r.conclusion='failure' } },
		@{ name='validator-failure'; reason='receipt_semantic_evidence_failure:visual-package'; mutate={ param($r) $r.results[0].nativeExitCode=7; $r.results[0].conclusion='failure' } },
		@{ name='wrong-repository'; reason='receipt_semantic_evidence_invalid:visual-package'; mutate={ param($r) $r.repository='evil/repository' } },
		@{ name='wrong-revision'; reason='receipt_semantic_evidence_invalid:visual-package'; mutate={ param($r) $r.revision=('9' * 40) } },
		@{ name='wrong-run'; reason='receipt_semantic_evidence_invalid:visual-package'; mutate={ param($r) $r.run.id='9002' } },
		@{ name='duplicate-validator'; reason='receipt_semantic_evidence_failure:visual-package'; mutate={ param($r) $r.results[1].id='visual-package' } },
		@{ name='capture-count-lie'; reason='receipt_semantic_evidence_invalid:visual-package'; mutate={ param($r) $r.results[0].capture.capturedLineCount=0 } },
		@{ name='capture-byte-lie'; reason='receipt_semantic_evidence_invalid:visual-package'; mutate={ param($r) $r.results[0].capture.capturedUtf8Bytes++ } }
	)) {
		$SemanticReport = New-TestVisualReport
		& $SemanticCase.mutate $SemanticReport
		[IO.File]::WriteAllText($VisualPath, (($SemanticReport | ConvertTo-Json -Depth 10 -Compress) + "`n"), $Utf8)
		$SemanticSize = (Get-Item -LiteralPath $VisualPath).Length
		$SemanticDigest = Get-Sha256 $VisualPath
		$SemanticInput = Get-TestReceiptInput -VisualSha256 $SemanticDigest -VisualSize $SemanticSize
		$SemanticInputPath = Join-Path $FixtureRoot ($SemanticCase.name + '.json'); Write-Input $SemanticInput $SemanticInputPath
		Assert-Rejected { New-CiAcceptanceReceipt -InputPath $SemanticInputPath -EvidenceRoot $EvidenceRoot -OutputPath $OutputPath } $SemanticCase.reason
		Assert-True (-not (Test-Path -LiteralPath $OutputPath)) "Semantic contradiction '$($SemanticCase.name)' must not publish a receipt."
	}

	[IO.File]::WriteAllText($VisualPath, ((New-TestVisualReport | ConvertTo-Json -Depth 10 -Compress) + "`n"), $Utf8)
	$VisualSize = (Get-Item -LiteralPath $VisualPath).Length; $VisualSha256 = Get-Sha256 $VisualPath
	$MissingSemantic = Get-TestReceiptInput -VisualSha256 (Get-Sha256 $WrongNamePath) -VisualSize ((Get-Item $WrongNamePath).Length)
	$MissingSemantic.results.checks[0].evidence[0].name = 'wrong-visual-report.json'
	$MissingSemanticPath = Join-Path $FixtureRoot 'missing-semantic.json'; Write-Input $MissingSemantic $MissingSemanticPath
	Assert-Rejected { New-CiAcceptanceReceipt -InputPath $MissingSemanticPath -EvidenceRoot $EvidenceRoot -OutputPath $OutputPath } 'receipt_semantic_evidence_missing:visual-package'
	$DuplicateSemantic = Get-TestReceiptInput -VisualSha256 $VisualSha256 -VisualSize $VisualSize
	$DuplicateSemantic.results.checks[0].evidence = @($DuplicateSemantic.results.checks[0].evidence[0], $DuplicateSemantic.results.checks[0].evidence[0])
	$DuplicateSemanticPath = Join-Path $FixtureRoot 'duplicate-semantic.json'; Write-Input $DuplicateSemantic $DuplicateSemanticPath
	Assert-Rejected { New-CiAcceptanceReceipt -InputPath $DuplicateSemanticPath -EvidenceRoot $EvidenceRoot -OutputPath $OutputPath } 'receipt_semantic_evidence_duplicate:visual-package'

	[IO.File]::WriteAllText($VisualPath, ((New-TestVisualReport -Revision ('b' * 40) | ConvertTo-Json -Depth 10 -Compress) + "`n"), $Utf8)
	$VisualSize = (Get-Item -LiteralPath $VisualPath).Length; $VisualSha256 = Get-Sha256 $VisualPath
	$Push = Get-TestReceiptInput -VisualSha256 $VisualSha256 -VisualSize $VisualSize
	$Push.event.kind = 'push'; $Push.event.classification = 'post_merge_hosted_health'
	$Push.event.actor = 'github-actions[bot]'; $Push.event.triggeringActor = 'github-actions[bot]'
	$Push.source.testedRevision = $Push.source.headRevision; $Push.workflow.revision = $Push.source.headRevision
	$Push.workflow.parents = @($Push.source.baseRevision); $Push.controller.revision = $Push.source.headRevision
	$Push.actions = Get-TestActionManifest -WithSubpath
	$PushPath = Join-Path $FixtureRoot 'push.json'; Write-Input $Push $PushPath
	$PushReceipt = New-CiAcceptanceReceipt -InputPath $PushPath -EvidenceRoot $EvidenceRoot -OutputPath $OutputPath
	Assert-True ($PushReceipt.event.classification -ceq 'post_merge_hosted_health' -and -not $PushReceipt.acceptance.grantsAcceptance) 'Push receipt should be hosted health only, never source acceptance.'
	Remove-Item -LiteralPath $OutputPath -Force
	$Push.workflow.parents[0] = ('8' * 40); Write-Input $Push $PushPath
	Assert-Rejected { New-CiAcceptanceReceipt -InputPath $PushPath -EvidenceRoot $EvidenceRoot -OutputPath $OutputPath } 'receipt_invalid'
}
finally {
	if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force }
}

Write-Output 'PASS: acceptance receipt schema, identities, outcomes, evidence binding, bounds, and shadow-only contract'
