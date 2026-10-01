$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SourceScript = Join-Path $RepositoryRoot 'scripts/ci/Invoke-CiAcceptanceAggregate.ps1'
$SelectorSourceScript = Join-Path $RepositoryRoot 'scripts/ci/Get-CiSelection.ps1'
. $SourceScript
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:Assertions = 0
$script:Utf8 = New-Object System.Text.UTF8Encoding($false, $true)
$script:FixtureNonce = '6' * 64

function Assert-True {
	param([bool] $Condition, [string] $Message)
	$script:Assertions++
	if (-not $Condition) { throw $Message }
}

function Assert-Rejected {
	param([scriptblock] $Operation, [string] $Reason)
	$script:Assertions++
	$Failure = $null
	try { & $Operation } catch { $Failure = $_.Exception.Message }
	if ($Failure -cne $Reason) { throw "Expected '$Reason' but observed '$Failure'." }
}

function ConvertTo-FixtureBytes {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function returns one byte sequence.')]
	param($Value)
	return ,$script:Utf8.GetBytes(($Value | ConvertTo-Json -Depth 20 -Compress))
}

function New-FixtureZip {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The fixture is constructed only in memory.')]
	param([object[]] $Entries)
	$Buffer = New-Object IO.MemoryStream
	$Archive = New-Object IO.Compression.ZipArchive($Buffer, [IO.Compression.ZipArchiveMode]::Create, $true)
	try {
		foreach ($Spec in $Entries) {
			$Entry = $Archive.CreateEntry([string] $Spec.name, [IO.Compression.CompressionLevel]::Optimal)
			if ($Spec.PSObject.Properties.Name -ccontains 'externalAttributes') { $Entry.ExternalAttributes = [int] $Spec.externalAttributes }
			$Stream = $Entry.Open()
			try {
				[byte[]] $Bytes = @()
				if ($Spec.bytes -is [string]) { $Bytes = $script:Utf8.GetBytes([string] $Spec.bytes) }
				else { $Bytes = [byte[]] $Spec.bytes }
				$Stream.Write($Bytes, 0, $Bytes.Length)
			} finally { $Stream.Dispose() }
		}
	} finally { $Archive.Dispose() }
	return $Buffer.ToArray()
}

function Get-Sha256([byte[]] $Bytes) {
	$Algorithm = [Security.Cryptography.SHA256]::Create()
	try { return ([BitConverter]::ToString($Algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
	finally { $Algorithm.Dispose() }
}

function Set-FixtureSelectorBinding {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates only an in-memory test fixture binding.')]
	param($Context, $Artifact)
	$Context.selectorBinding = [pscustomobject][ordered]@{jobName='ci-selection-shadow';artifactId=[string]$Artifact.id;artifactName=[string]$Artifact.name;digest=[string]$Artifact.digest}
}

function Set-FixtureProducerBinding {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates only an in-memory test fixture binding.')]
	param($Context, [string]$Key, $Artifact)
	$Binding = @($Context.producerBindings | Where-Object { $_.key -ceq $Key })
	if ($Binding.Count -ne 1) { throw 'fixture_producer_binding_missing' }
	$Binding[0].artifactId = [string]$Artifact.id
	$Binding[0].artifactName = [string]$Artifact.name
	$Binding[0].digest = [string]$Artifact.digest
}

function New-FixtureActions {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory fixture.')]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function returns the complete action collection fixture.')]
	param()
	$Items = @(
		[pscustomobject][ordered]@{ uses = 'actions/checkout'; revision = ('4' * 40) },
		[pscustomobject][ordered]@{ uses = 'actions/upload-artifact/subpath'; revision = ('5' * 40) }
	)
	$Manifest = (($Items | ForEach-Object { $_.uses + '@' + $_.revision }) -join "`n") + "`n"
	return [pscustomobject][ordered]@{ manifestSha256 = Get-Sha256 $script:Utf8.GetBytes($Manifest); items = $Items }
}

function New-FixtureContext {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory fixture.')]
	param([string] $Kind = 'pull_request')
	$Classification = if ($Kind -ceq 'push') { 'post_merge_hosted_health' } else { 'pull_request_acceptance' }
	$Context = [pscustomobject][ordered]@{
		schemaVersion = 'aetheln.ci-acceptance-context/v1'
		repository = [pscustomobject][ordered]@{ fullName = 'ShayShimoni/aetheln-online' }
		event = [pscustomobject][ordered]@{ kind = $Kind; classification = $Classification; actor = 'dependabot[bot]'; triggeringActor = 'github-actions[bot]' }
		source = [pscustomobject][ordered]@{ baseRevision = ('a' * 40); headRevision = ('b' * 40); testedRevision = ('c' * 40) }
		workflow = [pscustomobject][ordered]@{ id = '1234'; revision = ('c' * 40); parents = @(('a' * 40), ('b' * 40)); sha256 = ('1' * 64) }
		actions = New-FixtureActions
		controller = [pscustomobject][ordered]@{ revision = ('a' * 40); blobOid = ('e' * 40); sha256 = ('2' * 64) }
		policy = [pscustomobject][ordered]@{ version = 'shadow-v1'; digest = ('3' * 64) }
		run = [pscustomobject][ordered]@{ id = '9001'; attempt = 2 }
		attemptAnchor = [pscustomobject][ordered]@{ schemaVersion='aetheln.current-attempt-anchor/v1'; runId='9001'; runAttempt=2; nonce=$script:FixtureNonce }
		selectorBinding = [pscustomobject][ordered]@{ jobName='ci-selection-shadow'; artifactId='200'; artifactName=('ci-selection-shadow-9001-2-' + $script:FixtureNonce); digest=('sha256:' + ('0' * 64)) }
		producerBindings = @()
	}
	return $Context
}

function New-FixtureSelectorReportData {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory fixture.')]
	param($Context, [string[]] $SelectedChecks = @())
	$Selected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	foreach ($CheckId in $SelectedChecks) { [void] $Selected.Add($CheckId) }
	$Obligations = @($script:SelectorCheckIds | ForEach-Object {
		$IsSelected = $Selected.Contains($_)
		[pscustomobject][ordered]@{ id=$_; selected=$IsSelected; reasons=@(if ($IsSelected) { 'fixture_path' }) }
	})
	$Report = [pscustomobject][ordered]@{
		schemaVersion='aetheln.ci-selection/v1'
		attemptAnchor=$Context.attemptAnchor
		policy=[pscustomobject][ordered]@{version=$Context.policy.version;digest=$Context.policy.digest;checkIds=@($script:SelectorCheckIds)}
		source=[pscustomobject][ordered]@{kind=$Context.event.kind;callerKind=$null;baseRevision=$Context.source.baseRevision;headRevision=$Context.source.headRevision;workflowRevision=$(if ($Context.event.kind -ceq 'pull_request') { $Context.workflow.revision } else { $null });revision=$null}
		execution=[pscustomobject][ordered]@{mode='accepted-base';controllerRevision=$Context.controller.revision;controllerBlobOid=$Context.controller.blobOid;controllerSha256=$Context.controller.sha256;checkoutAllowed=$false;complete=$true;reason='classified'}
		classification=[pscustomobject][ordered]@{changedPaths=@();entries=@();uncertainties=@()}
		selection=[pscustomobject][ordered]@{shadow=$true;authoritative=$false;obligations=$Obligations}
		legacyAuthority=[pscustomobject][ordered]@{authoritative=$true;engineRequired=$false;reason='portable_paths_only'}
		comparison=[pscustomobject][ordered]@{status='unavailable';differences=@('legacy_authority_not_observed')}
	}
	return ,(ConvertTo-FixtureBytes $Report)
}

function New-FixtureRequirements {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory fixture.')]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function returns the complete requirements fixture.')]
	param()
	return [pscustomobject][ordered]@{
		schemaVersion = 'aetheln.ci-acceptance-requirements/v1'
		jobs = @(
			[pscustomobject][ordered]@{ key = 'native'; jobName = 'trusted-candidate-compile'; artifactName = ('ci-receipt-native-9001-2-' + $script:FixtureNonce); checks = @('clean-package-provenance-smoke','native-client-server-compile') },
			[pscustomobject][ordered]@{ key = 'quality'; jobName = 'quality-gates'; artifactName = ('ci-receipt-quality-9001-2-' + $script:FixtureNonce); checks = @('content-reference-validation','controller-contract','controller-operational-proof','portable','unreal-editor-automation','visual-package') }
		)
	}
}

function New-FixtureVisualReport {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory fixture.')]
	param($Context)
	$Output = @('stdout: fixture pass')
	$CapturedBytes = $script:Utf8.GetByteCount($Output[0])
	$Results = @(
		[pscustomobject][ordered]@{
			id='visual-package'; path='.\visuals\Test-VisualPackage.ps1'; startedUtc='2026-09-20T20:00:00.0000000Z'; finishedUtc='2026-09-20T20:00:01.0000000Z'; nativeExitCode=0; conclusion='success'
			capture=[pscustomobject][ordered]@{maxLineUtf8Bytes=4096;maxLines=200;maxAggregateUtf8Bytes=131072;observedLineCount=1;capturedLineCount=1;capturedUtf8Bytes=$CapturedBytes;truncatedLineCount=0;droppedLineCount=0}; output=$Output
		},
		[pscustomobject][ordered]@{
			id='visual-package-regressions'; path='.\visuals\tests\Test-VisualPackageValidation.ps1'; startedUtc='2026-09-20T20:00:01.0000000Z'; finishedUtc='2026-09-20T20:00:02.0000000Z'; nativeExitCode=0; conclusion='success'
			capture=[pscustomobject][ordered]@{maxLineUtf8Bytes=4096;maxLines=200;maxAggregateUtf8Bytes=131072;observedLineCount=1;capturedLineCount=1;capturedUtf8Bytes=$CapturedBytes;truncatedLineCount=0;droppedLineCount=0}; output=$Output
		}
	)
	return [pscustomobject][ordered]@{schemaVersion='aetheln.visual-package-report/v1';repository=$Context.repository.fullName;revision=$Context.source.testedRevision;run=[pscustomobject][ordered]@{id=$Context.run.id;attempt=$Context.run.attempt};results=$Results;conclusion='success'}
}

function New-FixturePortableReport {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory report fixture.')]
	param($Context)
	$Names = @(
		'formatting-policy','markdown-links','source-control-policy','observability-contract','build-packaged-artifacts-tests','packaged-smoke-test-tests','network-authority-spike-tests','engine-runner-gate-tests','unreal-automation-tests','server-cook-reference-tests','target-composition-tests','build-provenance-tests','markdown-link-tests','formatting-policy-tests','observability-contract-tests','ci-suite-tests','engine-runner-post-command-state-tests','prototype-quality-workflow-tests','visual-package-evidence-tests','runner-scheduling-policy-tests','ci-selection-tests','ci-acceptance-receipt-tests','ci-acceptance-aggregate-tests','ci-acceptance-publisher-tests','ci-acceptance-context-tests','ci-activation-candidate-tests','compile-workspace-tests','engine-host-lease-tests','managed-compile-registration-tests','managed-compile-workspace-tests','managed-compile-integration-tests','routine-compile-deadline-tests','routine-compile-resources-tests','routine-compile-command-tests','routine-compile-gate-tests','psscriptanalyzer'
	)
	$Checks = @($Names | ForEach-Object { [pscustomobject][ordered]@{name=$_;tier=$(if($_-ceq'psscriptanalyzer'){'advisory'}else{'required'});status='passed';durationSeconds=0.01;command='fixture';message='passed'} })
	return [pscustomobject][ordered]@{schemaVersion=1;revision=$Context.source.testedRevision;startedUtc='2026-09-20T20:00:00.0000000Z';finishedUtc='2026-09-20T20:00:01.0000000Z';checks=$Checks;summary=[pscustomobject][ordered]@{total=$Checks.Count;passed=$Checks.Count;failed=0;skipped=0;requiredFailed=0}}
}

function New-FixtureEngineReport {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory report fixture.')]
	param($Context)
	$Names = @('runner-input-validation','managed-compile-workspace','repository-state-before-work','incremental-client-build','incremental-client-build-repository-state','incremental-server-build','incremental-server-build-repository-state','repository-state-at-completion')
	$Checks = @($Names | ForEach-Object { [pscustomobject][ordered]@{name=$_;tier='required';status='passed';durationSeconds=0.01;command='fixture';message='passed'} })
	$Builds = @(
		[pscustomobject][ordered]@{check='incremental-client-build';target='AethelnOnlineClient';platform='Win64';configuration='Development';intermediateBuildDirectoryPresentBeforeRun=$true;makefilePresentBeforeRun=$true;outputState='captured';lastObservedAction=1;observedTotalActions=1;actionCounterState='observed';plannedActionCount=1;observedTargetNames='AethelnOnlineClient';makefileObservation='not_observed';makefileReason=$null;makefileCreationCount=0;upToDateObserved=$false;executorSummaryCount=1},
		[pscustomobject][ordered]@{check='incremental-server-build';target='AethelnOnlineServer';platform='Linux';configuration='Development';intermediateBuildDirectoryPresentBeforeRun=$true;makefilePresentBeforeRun=$true;outputState='captured';lastObservedAction=1;observedTotalActions=1;actionCounterState='observed';plannedActionCount=1;observedTargetNames='AethelnOnlineServer';makefileObservation='not_observed';makefileReason=$null;makefileCreationCount=0;upToDateObserved=$false;executorSummaryCount=1}
	)
	$Workspace = [pscustomobject][ordered]@{schemaVersion=1;registrationId=('6'*32);registrationSha256=('4'*64);preparationReceiptSha256=('5'*64);revision=$Context.source.testedRevision;synchronized=$true}
	$Resources = [pscustomobject][ordered]@{schemaVersion=1;sampleIntervalMilliseconds=5000;recoveryFloorBytes=20GB;pressureThresholdBytes=2GB;sampleCount=2;measurementCount=4;maximumSampleGapMilliseconds=5000;consecutivePressureSamples=0;maximumConsecutivePressureSamples=0;minimumAvailableRamBytes=16GB;minimumCommitHeadroomBytes=16GB;physicalCores=8;targetAdmissionCount=2;minimumActionLimit=2;maximumActionLimit=4;failureReason=$null;volumes=@([pscustomobject][ordered]@{volumeId='volume-fixture';knownAllocationBytes=0;minimumAvailableBytes=50GB})}
	return [pscustomobject][ordered]@{schemaVersion=1;mode='Compile';policy='incremental-target-compilation';revision=$Context.source.testedRevision;runnerName='fixture-runner';startedUtc='2026-09-20T20:00:00.0000000Z';finishedUtc='2026-09-20T20:00:01.0000000Z';checks=$Checks;summary=[pscustomobject][ordered]@{total=$Checks.Count;passed=$Checks.Count;failed=0;skipped=0;requiredFailed=0};compileEvidence=[pscustomobject][ordered]@{schemaVersion=1;identity=[pscustomobject][ordered]@{engineGitRevision='71fe36aac5a8df5ccd66c763ffc902b29b6a9c43';engineGitRevisionStatus='verified';engineBuildVersionSha256=('2'*64);engineBuildVersionSha256Status='verified';linuxToolchainCompilerSha256=('3'*64);linuxToolchainCompilerSha256Status='verified';runnerName='fixture-runner';durationSeconds=0.01};builds=$Builds};managedWorkspace=$Workspace;compileResources=$Resources;supervisor=[pscustomobject][ordered]@{childExitCode=0;timedOut=$false;cleanupVerified=$true}}
}

function New-FixtureUnrealReport {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory report fixture.')]
	param($Context)
	$Tests = @(
		[pscustomobject][ordered]@{fullTestPath='Aetheln.GameCombat.NetworkSpike.Authority';state='Success';status='passed';durationSeconds=0.1;warningCount=0;errorCount=0},
		[pscustomobject][ordered]@{fullTestPath='Aetheln.Harness.ProjectAndModuleLoad';state='Success';status='passed';durationSeconds=0.1;warningCount=0;errorCount=0}
	)
	return [pscustomobject][ordered]@{schemaId='aetheln.unreal-automation';schemaVersion=1;mode='production';sourceRevision=$Context.source.testedRevision;engineRevision='71fe36aac5a8df5ccd66c763ffc902b29b6a9c43';projectName='AethelnOnline';filter='^Aetheln.Harness.ProjectAndModuleLoad$+^Aetheln.GameCombat.NetworkSpike.Authority$';timeoutSeconds=600;startedUtc='2026-09-20T20:00:00.0000000Z';finishedUtc='2026-09-20T20:00:01.0000000Z';processExitCode=0;repositoryCleanBefore=$true;repositoryCleanAfter=$true;outputs=[pscustomobject][ordered]@{unrealReport='TestResults/UnrealAutomation/index.json';log='Saved/Logs/AethelnUnrealAutomation.log'};tests=$Tests;summary=[pscustomobject][ordered]@{total=2;passed=2;passedWithWarnings=0;failed=0;notRun=0;missing=0;requiredFailed=0};result='passed';failureReason='none'}
}

function New-FixtureReceipt {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory fixture.')]
	param($Context, $Requirement, [byte[]] $EvidenceBytes = $script:Utf8.GetBytes('raw-proof'))
	$Results = @($Requirement.checks | ForEach-Object {
		$RequiresNativeProof = $_ -cin @('clean-package-provenance-smoke','native-client-server-compile')
		$RequiresNativeExit = $RequiresNativeProof -or $_ -ceq 'unreal-editor-automation'
		$EvidenceName = switch ($_) { 'portable' {'ci-report.json'} 'native-client-server-compile' {'engine-runner-report.json'} 'unreal-editor-automation' {'unreal-automation-report.json'} 'visual-package' {'visual-package-report.json'} default { 'evidence/' + $_ + '.json' } }
		[pscustomobject][ordered]@{
			id = [string] $_; jobName = [string] $Requirement.jobName; conclusion = 'success'; nativeExitCode = if ($RequiresNativeExit) { 0 } else { $null }
			infrastructureFailure = $null; terminal = $true; cleanupVerified = if ($RequiresNativeProof) { $true } else { $null }
			evidence = @([pscustomobject][ordered]@{ name = $EvidenceName; sha256 = (Get-Sha256 $EvidenceBytes); sizeBytes = [long] $EvidenceBytes.Length })
		}
	})
	return [pscustomobject][ordered]@{
		schemaVersion = 'aetheln.ci-acceptance-receipt/v1'
		repository = $Context.repository
		event = $Context.event
		source = $Context.source
		workflow = $Context.workflow
		actions = $Context.actions
		controller = $Context.controller
		policy = $Context.policy
		run = $Context.run
		attemptAnchor = $Context.attemptAnchor
		selection = [pscustomobject][ordered]@{ checks = @($Requirement.checks) }
		results = [pscustomobject][ordered]@{ checks = $Results }
		acceptance = [pscustomobject][ordered]@{ shadow = $true; authoritative = $false; grantsAcceptance = $false; terminal = $true; infrastructureFailure = $false; cleanupVerified = $(if (@($Requirement.checks | Where-Object { $_ -cin @('clean-package-provenance-smoke','native-client-server-compile') }).Count -gt 0) { $true } else { $null }) }
	}
}

function New-FixtureVisualBoundary {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory fixture.')]
	param($Context, $Report = $null)
	if ($null -eq $Report) { $Report = New-FixtureVisualReport -Context $Context }
	$EvidenceBytes = ConvertTo-FixtureBytes $Report
	$Requirement = [pscustomobject][ordered]@{ key='visual';jobName='visual-package-proof';artifactName=('ci-receipt-visual-9001-2-' + $Context.attemptAnchor.nonce);checks=@('visual-package') }
	$Receipt = New-FixtureReceipt -Context $Context -Requirement $Requirement -EvidenceBytes $EvidenceBytes
	$ReceiptBytes = ConvertTo-FixtureBytes $Receipt
	$Archive = [pscustomobject][ordered]@{ entries=@(
		[pscustomobject][ordered]@{name='ci-acceptance-receipt.json';bytes=$ReceiptBytes;sizeBytes=[long]$ReceiptBytes.Length;sha256=(Get-Sha256 $ReceiptBytes)},
		[pscustomobject][ordered]@{name='visual-package-report.json';bytes=$EvidenceBytes;sizeBytes=[long]$EvidenceBytes.Length;sha256=(Get-Sha256 $EvidenceBytes)}
	) }
	return [pscustomobject][ordered]@{ requirement=$Requirement;receipt=$Receipt;archive=$Archive }
}

function New-FixtureSemanticBoundary {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory semantic fixture boundary.')]
	param($Context, [string]$CheckId, $Report)
	$EvidenceBytes = ConvertTo-FixtureBytes $Report
	$Requirement = [pscustomobject][ordered]@{key='semantic';jobName='semantic-proof';artifactName=('ci-receipt-semantic-9001-2-' + $Context.attemptAnchor.nonce);checks=@($CheckId)}
	$Receipt = New-FixtureReceipt -Context $Context -Requirement $Requirement -EvidenceBytes $EvidenceBytes
	$ReceiptBytes = ConvertTo-FixtureBytes $Receipt
	$Name = [string]$Receipt.results.checks[0].evidence[0].name
	$Archive = [pscustomobject][ordered]@{ entries=@(
		[pscustomobject][ordered]@{name='ci-acceptance-receipt.json';bytes=$ReceiptBytes;sizeBytes=[long]$ReceiptBytes.Length;sha256=(Get-Sha256 $ReceiptBytes)},
		[pscustomobject][ordered]@{name=$Name;bytes=$EvidenceBytes;sizeBytes=[long]$EvidenceBytes.Length;sha256=(Get-Sha256 $EvidenceBytes)}
	) }
	return [pscustomobject][ordered]@{requirement=$Requirement;receipt=$Receipt;archive=$Archive}
}

function New-FixtureApi {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory API fixture.')]
	param(
		$Context,
		$Requirements,
		[string[]] $SelectedChecks = @(),
		[byte[]] $SelectorReportBytes = $null,
		[hashtable] $Overrides = @{}
	)
	if ($null -eq $SelectorReportBytes) { $SelectorReportBytes = New-FixtureSelectorReportData -Context $Context -SelectedChecks $SelectedChecks }
	$Selected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
	foreach ($CheckId in $SelectedChecks) { [void]$Selected.Add($CheckId) }
	$Run = [pscustomobject][ordered]@{ id = 9001; run_attempt = 2; workflow_id = 1234; event = $Context.event.kind; head_sha = $Context.source.headRevision; status = 'in_progress'; conclusion = $null; actor = [pscustomobject][ordered]@{login=$Context.event.actor;id=101;node_id='ACTOR_fixture'}; triggering_actor = [pscustomobject][ordered]@{login=$Context.event.triggeringActor;id=102;node_id='TRIGGER_fixture'} }
	$WorkflowRuns = [pscustomobject][ordered]@{ total_count = 1; workflow_runs = @($Run) }
	$Jobs = New-Object System.Collections.Generic.List[object]
	$Artifacts = New-Object System.Collections.Generic.List[object]
	$Archives = @{}
	$ArtifactId = 200
	$StartedAt = '2026-09-20T20:00:00Z'
	$CompletedAt = '2026-09-20T20:10:00Z'
	$CreatedAt = '2026-09-20T20:09:00Z'
	$Jobs.Add([pscustomobject][ordered]@{id=100;name='ci-selection-shadow';status='completed';conclusion='success';run_id=9001;head_sha=$Context.source.headRevision;run_attempt=2;started_at=$StartedAt;completed_at=$CompletedAt;labels=@('windows-latest');runner_id=10;runner_name='GitHub Actions 1'})
	$SelectorArchive = New-FixtureZip @([pscustomobject]@{name='ci-selection-shadow.json';bytes=$SelectorReportBytes})
	$SelectorUrl = 'https://api.fixture/artifacts/200/zip'
	$Archives[$SelectorUrl] = $SelectorArchive
	$SelectorDigest = 'sha256:' + (Get-Sha256 $SelectorArchive)
	$SelectorArtifactName = 'ci-selection-shadow-' + $Context.run.id + '-' + $Context.run.attempt + '-' + $Context.attemptAnchor.nonce
	$Context.selectorBinding = [pscustomobject][ordered]@{jobName='ci-selection-shadow';artifactId='200';artifactName=$SelectorArtifactName;digest=$SelectorDigest}
	$Artifacts.Add([pscustomobject][ordered]@{id=200;name=$SelectorArtifactName;size_in_bytes=$SelectorArchive.Length;archive_download_url=$SelectorUrl;expired=$false;created_at=$CreatedAt;digest=$SelectorDigest;workflow_run=[pscustomobject][ordered]@{id=9001;head_sha=$Context.source.headRevision}})
	$ProducerBindings = New-Object System.Collections.Generic.List[object]
	foreach ($Requirement in $Requirements.jobs) {
		$ArtifactId++
		$SelectedSubset = @($Requirement.checks | Where-Object { $Selected.Contains([string]$_) })
		$Conclusion = if ($SelectedSubset.Count -gt 0) { 'success' } else { 'skipped' }
		$IsNative = $Requirement.jobName -ceq 'trusted-candidate-compile'
		[string[]] $Labels = if ($IsNative) { @('self-hosted','Windows','X64','aetheln-engine') } else { @('windows-latest') }
		$RunnerId = if ($Conclusion -ceq 'success') { 100 + $ArtifactId } else { 0 }
		$RunnerName = if ($Conclusion -cne 'success') { $null } elseif ($IsNative) { 'fixture-runner' } else { 'GitHub Actions 2' }
		$Jobs.Add([pscustomobject][ordered]@{ id = 100 + $ArtifactId; name = $Requirement.jobName; status = 'completed'; conclusion = $Conclusion; run_id=9001;head_sha=$Context.source.headRevision;run_attempt=2;started_at=$StartedAt;completed_at=$CompletedAt;labels=$Labels;runner_id=$RunnerId;runner_name=$RunnerName })
		if ($SelectedSubset.Count -eq 0) { continue }
		$SelectedRequirement = [pscustomobject][ordered]@{key=$Requirement.key;jobName=$Requirement.jobName;artifactName=$Requirement.artifactName;checks=$SelectedSubset}
		$Evidence = if ($SelectedSubset -ccontains 'native-client-server-compile') { ConvertTo-FixtureBytes (New-FixtureEngineReport -Context $Context) }
			elseif ($SelectedSubset -ccontains 'visual-package') { ConvertTo-FixtureBytes (New-FixtureVisualReport -Context $Context) }
			else { $script:Utf8.GetBytes('raw-proof') }
		$Receipt = New-FixtureReceipt -Context $Context -Requirement $SelectedRequirement -EvidenceBytes $Evidence
		$ArchiveEntries = New-Object System.Collections.Generic.List[object]
		$ArchiveEntries.Add([pscustomobject]@{ name = 'ci-acceptance-receipt.json'; bytes = (ConvertTo-FixtureBytes $Receipt) })
		foreach ($Result in $Receipt.results.checks) { $ArchiveEntries.Add([pscustomobject]@{ name = $Result.evidence[0].name; bytes = $Evidence }) }
		$Archive = New-FixtureZip $ArchiveEntries.ToArray()
		$Url = "https://api.fixture/artifacts/$ArtifactId/zip"
		$Archives[$Url] = $Archive
		$ArtifactDigest = 'sha256:' + (Get-Sha256 $Archive)
		$ProducerBindings.Add([pscustomobject][ordered]@{key=[string]$Requirement.key;jobName=[string]$Requirement.jobName;artifactId=[string]$ArtifactId;artifactName=[string]$Requirement.artifactName;digest=$ArtifactDigest})
		$Artifacts.Add([pscustomobject][ordered]@{ id = $ArtifactId; name = $Requirement.artifactName; size_in_bytes = $Archive.Length; archive_download_url = $Url; expired = $false; created_at=$CreatedAt; digest=$ArtifactDigest; workflow_run = [pscustomobject][ordered]@{ id = 9001; head_sha = $Context.source.headRevision } })
	}
	$Context.producerBindings = $ProducerBindings.ToArray()
	$State = @{}
	$State['/repos/ShayShimoni/aetheln-online/actions/runs/9001'] = ConvertTo-FixtureBytes $Run
	$WorkflowRunsUri = '/repos/ShayShimoni/aetheln-online/actions/workflows/1234/runs?event=' + $Context.event.kind + '&head_sha=' + $Context.source.headRevision + '&per_page=100&page=1'
	$State[$WorkflowRunsUri] = ConvertTo-FixtureBytes $WorkflowRuns
	$State['/repos/ShayShimoni/aetheln-online/actions/runs/9001/attempts/2/jobs?per_page=100&page=1'] = ConvertTo-FixtureBytes ([pscustomobject][ordered]@{ total_count = $Jobs.Count; jobs = $Jobs.ToArray() })
	$State['/repos/ShayShimoni/aetheln-online/actions/runs/9001/jobs?filter=all&per_page=100&page=1'] = ConvertTo-FixtureBytes ([pscustomobject][ordered]@{ total_count = $Jobs.Count; jobs = $Jobs.ToArray() })
	$State['/repos/ShayShimoni/aetheln-online/actions/runs/9001/artifacts?per_page=100&page=1'] = ConvertTo-FixtureBytes ([pscustomobject][ordered]@{ total_count = $Artifacts.Count; artifacts = $Artifacts.ToArray() })
	foreach ($Key in $Archives.Keys) { $State[$Key] = $Archives[$Key] }
	foreach ($Key in $Overrides.Keys) { $State[$Key] = $Overrides[$Key] }
	return { param([string] $Uri, [int] $RemainingMilliseconds, [int] $MaximumBytes) if ($RemainingMilliseconds -le 0) { throw 'api_deadline_exceeded' }; if (-not $State.ContainsKey($Uri)) { throw "fixture_uri_unexpected:$Uri" }; $Bytes = [byte[]] $State[$Uri]; if ($Bytes.Length -gt $MaximumBytes) { throw 'api_response_size_limit' }; return ,$Bytes }.GetNewClosure()
}

$Context = New-FixtureContext
$Requirements = New-FixtureRequirements
$SelectorContext = [pscustomobject][ordered]@{
	kind='pull_request';runId=$Context.run.id;runAttempt=$Context.run.attempt
	baseRevision=$Context.source.baseRevision;headRevision=$Context.source.headRevision
	workflowRevision=$Context.workflow.revision;controllerRevision=$Context.controller.revision
}
$SelectorModule = New-Module -ArgumentList $SelectorSourceScript -ScriptBlock { param($Path) . $Path }
$RealSelectorShape = & $SelectorModule {
	param($SelectorContextValue, $AttemptAnchorValue)
	New-ConservativeSelection -Reason 'compatibility_fixture' -Context $SelectorContextValue -AttemptAnchor $AttemptAnchorValue
} $SelectorContext $Context.attemptAnchor
. $SourceScript
Assert-True ((@($RealSelectorShape.PSObject.Properties.Name) -join ',') -ceq 'schemaVersion,attemptAnchor,policy,source,execution,classification,selection,legacyAuthority,comparison') 'Aggregate selector compatibility must use the real selector root schema.'
$SelectorCompatibilityReport = ConvertFrom-StrictBoundedJson -Bytes (New-FixtureSelectorReportData -Context $Context)
$SelectorCompatibilityReport.attemptAnchor = $RealSelectorShape.attemptAnchor
$SelectorCompatibilitySelection = Read-AcceptedSelectorReport -ReportBytes (ConvertTo-FixtureBytes $SelectorCompatibilityReport) -Context $Context
Assert-True ($SelectorCompatibilitySelection.Count -eq 0) 'Aggregate must consume the canonical attemptAnchor emitted by the real selector contract.'
$Api = New-FixtureApi -Context $Context -Requirements $Requirements
$Aggregate = New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $Api -DeadlineSeconds 30
Assert-True ($Aggregate.schemaVersion -ceq 'aetheln.ci-acceptance-aggregate/v1') 'Aggregate schema identity changed.'
Assert-True ($Aggregate.decision.shadow -and -not $Aggregate.decision.authoritative -and -not $Aggregate.decision.grantsAcceptance) 'Aggregate must remain shadow-only and non-authoritative.'
Assert-True ($Aggregate.decision.evidenceClass -ceq 'pull_request_acceptance_candidate' -and $Aggregate.decision.complete) 'Complete PR evidence must remain only a candidate observation.'
Assert-True (@($Aggregate.receipts).Count -eq 0 -and @($Aggregate.jobs | Where-Object { -not $_.selected -and $_.conclusion -ceq 'skipped' }).Count -eq 2) 'Unsupported obligations must remain unselected and emit no opaque receipts.'
Assert-True ($Aggregate.selectorEvidence.job.name -ceq 'ci-selection-shadow' -and $Aggregate.selectorEvidence.artifact.name -ceq ('ci-selection-shadow-9001-2-' + $script:FixtureNonce) -and @($Aggregate.selectorEvidence.selectedChecks).Count -eq 0 -and $Aggregate.selectorEvidence.reportSha256 -cmatch '^[0-9a-f]{64}$') 'Aggregate output must retain exact same-attempt selector job, artifact, archive, and report provenance.'
Assert-True ($Aggregate.attemptAnchor.nonce -ceq $script:FixtureNonce -and $Aggregate.attemptAnchor.runId -ceq $Aggregate.run.id -and $Aggregate.attemptAnchor.runAttempt -eq $Aggregate.run.attempt) 'Aggregate output must preserve the exact current-attempt anchor.'
Assert-True ($Context.selectorBinding.artifactId -ceq $Aggregate.selectorEvidence.artifact.id -and $Context.selectorBinding.artifactName -ceq $Aggregate.selectorEvidence.artifact.name -and $Context.selectorBinding.digest -ceq $Aggregate.selectorEvidence.artifact.apiDigest -and @($Context.producerBindings).Count -eq 0) 'Aggregate must bind selector provenance directly and require no producer binding for an unselected requirement.'
Assert-True (@($Requirements.jobs | Where-Object { $_.PSObject.Properties.Name -ccontains 'selected' }).Count -eq 0) 'Requirements must expose producer capabilities without caller-controlled selection booleans.'

foreach ($AnchorCase in @(
	@{name='missing';mutate={param($x)$x.PSObject.Properties.Remove('attemptAnchor')}},
	@{name='legacy-property';mutate={param($x)$Anchor=$x.attemptAnchor;$x.PSObject.Properties.Remove('attemptAnchor');$x|Add-Member -NotePropertyName currentAttemptAnchor -NotePropertyValue $Anchor}},
	@{name='null';mutate={param($x)$x.attemptAnchor=$null}},
	@{name='short';mutate={param($x)$x.attemptAnchor.nonce='6'*63}},
	@{name='uppercase';mutate={param($x)$x.attemptAnchor.nonce='A'*64}},
	@{name='nonhex';mutate={param($x)$x.attemptAnchor.nonce='g'*64}},
	@{name='trailing-lf';mutate={param($x)$x.attemptAnchor.nonce=('6'*64)+"`n"}},
	@{name='all-zero';mutate={param($x)$x.attemptAnchor.nonce='0'*64}},
	@{name='run-replay';mutate={param($x)$x.attemptAnchor.runId='9000'}},
	@{name='attempt-replay';mutate={param($x)$x.attemptAnchor.runAttempt=1}}
)) {
	$BadContext=$Context|ConvertTo-Json -Depth 20|ConvertFrom-Json;& $AnchorCase.mutate $BadContext
	try { Assert-Rejected { Assert-AcceptanceContext $BadContext } $(if($AnchorCase.name-cin@('missing','legacy-property')){'context_schema_invalid'}else{'context_attempt_anchor_invalid'}) }
	catch { throw "Aggregate context anchor fixture '$($AnchorCase.name)' failed: $($_.Exception.Message)" }
}
Assert-True (-not (Test-Sha256 (('1' * 64) + "`n")) -and -not (Test-Revision (('a' * 40) + "`n"))) 'Fixed-length hexadecimal identities must reject a trailing LF.'

foreach ($SelectorAnchorCase in @(
	@{name='missing';reason='selector_evidence_report_invalid';mutate={param($x)$x.PSObject.Properties.Remove('attemptAnchor')}},
	@{name='legacy-property';reason='selector_evidence_report_invalid';mutate={param($x)$Anchor=$x.attemptAnchor;$x.PSObject.Properties.Remove('attemptAnchor');$x|Add-Member -NotePropertyName currentAttemptAnchor -NotePropertyValue $Anchor}},
	@{name='null';reason='selector_attempt_anchor_invalid';mutate={param($x)$x.attemptAnchor=$null}},
	@{name='attempt-replay';reason='selector_attempt_anchor_invalid';mutate={param($x)$x.attemptAnchor.runAttempt=1}},
	@{name='nonce-mismatch';reason='selector_attempt_anchor_mismatch';mutate={param($x)$x.attemptAnchor.nonce='7'*64}}
)) {
	$BadSelector=ConvertFrom-StrictBoundedJson -Bytes (New-FixtureSelectorReportData -Context $Context);& $SelectorAnchorCase.mutate $BadSelector
	try { Assert-Rejected { Read-AcceptedSelectorReport -ReportBytes (ConvertTo-FixtureBytes $BadSelector) -Context $Context } $SelectorAnchorCase.reason }
	catch { throw "Aggregate selector anchor fixture '$($SelectorAnchorCase.name)' failed: $($_.Exception.Message)" }
}

$NativeSelectorBytes = New-FixtureSelectorReportData -Context $Context -SelectedChecks @('native-client-server-compile')
$NativeSelected = Read-AcceptedSelectorReport -ReportBytes $NativeSelectorBytes -Context $Context
$NativeSubset = @($Requirements.jobs[0].checks | Where-Object { $NativeSelected.Contains([string]$_) })
Assert-True ($NativeSubset.Count -eq 1 -and $NativeSubset[0] -ceq 'native-client-server-compile') 'A mixed native/clean producer capability must derive only the selector-selected native obligation.'

$VisualApi = New-FixtureApi -Context $Context -Requirements $Requirements -SelectedChecks @('visual-package')
$VisualAggregate = New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $VisualApi -DeadlineSeconds 30
$VisualJob = @($VisualAggregate.jobs | Where-Object key -ceq 'quality')[0]
Assert-True ($VisualJob.selected -and (@($VisualJob.capabilityChecks).Count -gt 1) -and (@($VisualJob.selectedChecks) -join ',') -ceq 'visual-package') 'A mixed producer capability must derive the exact visual-only selected subset.'
Assert-True (@($VisualAggregate.receipts).Count -eq 1 -and (@($VisualAggregate.receipts[0].selectedChecks) -join ',') -ceq 'visual-package') 'Visual-only selected evidence must validate without claiming other producer capabilities.'
Assert-True (@($Context.producerBindings).Count -eq 1 -and $Context.producerBindings[0].key -ceq 'quality' -and $Context.producerBindings[0].jobName -ceq 'quality-gates' -and $Context.producerBindings[0].artifactId -ceq $VisualAggregate.receipts[0].artifactId -and $Context.producerBindings[0].artifactName -ceq $VisualAggregate.receipts[0].artifactName -and $Context.producerBindings[0].digest -ceq $VisualAggregate.receipts[0].artifactApiDigest) 'Selected producer evidence must match one direct uploader binding exactly.'

foreach ($SelectorBindingShapeCase in @(
	@{name='missing-root';reason='context_schema_invalid';mutate={param($x)$x.PSObject.Properties.Remove('selectorBinding')}},
	@{name='extra-field';reason='selector_binding_schema_invalid';mutate={param($x)$x.selectorBinding|Add-Member -NotePropertyName extra -NotePropertyValue 'x'}},
	@{name='wrong-job';reason='selector_binding_invalid';mutate={param($x)$x.selectorBinding.jobName='quality-gates'}},
	@{name='replayed-name';reason='selector_binding_invalid';mutate={param($x)$x.selectorBinding.artifactName='ci-selection-shadow-9001-1-' + $script:FixtureNonce}},
	@{name='nondecimal-id';reason='selector_binding_invalid';mutate={param($x)$x.selectorBinding.artifactId='0200'}},
	@{name='uppercase-digest';reason='selector_binding_invalid';mutate={param($x)$x.selectorBinding.digest='sha256:' + ('A' * 64)}},
	@{name='digest-trailing-lf';reason='selector_binding_invalid';mutate={param($x)$x.selectorBinding.digest='sha256:' + ('8' * 64) + "`n"}}
)) {
	$BindingContext=New-FixtureContext;$BindingApi=New-FixtureApi -Context $BindingContext -Requirements $Requirements;& $SelectorBindingShapeCase.mutate $BindingContext
	try { Assert-Rejected { New-CiAcceptanceAggregate -Context $BindingContext -Requirements $Requirements -ApiRequest $BindingApi -DeadlineSeconds 30 } $SelectorBindingShapeCase.reason }
	catch { throw "Aggregate selector binding fixture '$($SelectorBindingShapeCase.name)' failed: $($_.Exception.Message)" }
}

foreach ($SelectorBindingApiCase in @(
	@{name='wrong-id';mutate={param($x)$x.selectorBinding.artifactId='999'}},
	@{name='wrong-digest';mutate={param($x)$x.selectorBinding.digest='sha256:' + ('9' * 64)}}
)) {
	$BindingContext=New-FixtureContext;$BindingApi=New-FixtureApi -Context $BindingContext -Requirements $Requirements;& $SelectorBindingApiCase.mutate $BindingContext
	try { Assert-Rejected { New-CiAcceptanceAggregate -Context $BindingContext -Requirements $Requirements -ApiRequest $BindingApi -DeadlineSeconds 30 } 'selector_binding_api_mismatch' }
	catch { throw "Aggregate selector API binding fixture '$($SelectorBindingApiCase.name)' failed: $($_.Exception.Message)" }
}

$MissingProducerBindingContext=New-FixtureContext
$MissingProducerBindingApi=New-FixtureApi -Context $MissingProducerBindingContext -Requirements $Requirements -SelectedChecks @('visual-package')
$MissingProducerBindingContext.producerBindings=@()
Assert-Rejected { New-CiAcceptanceAggregate -Context $MissingProducerBindingContext -Requirements $Requirements -ApiRequest $MissingProducerBindingApi -DeadlineSeconds 30 } 'producer_binding_missing'

$UnselectedProducerBindingContext=New-FixtureContext
$UnselectedProducerBindingApi=New-FixtureApi -Context $UnselectedProducerBindingContext -Requirements $Requirements -SelectedChecks @('visual-package')
$UnselectedProducerBindingContext.producerBindings=@(
	[pscustomobject][ordered]@{key='native';jobName='trusted-candidate-compile';artifactId='201';artifactName=('ci-receipt-native-9001-2-' + $script:FixtureNonce);digest=('sha256:' + ('8' * 64))},
	$UnselectedProducerBindingContext.producerBindings[0]
)
Assert-Rejected { New-CiAcceptanceAggregate -Context $UnselectedProducerBindingContext -Requirements $Requirements -ApiRequest $UnselectedProducerBindingApi -DeadlineSeconds 30 } 'producer_binding_unselected'

$ExtraProducerBindingContext=New-FixtureContext
$ExtraProducerBindingApi=New-FixtureApi -Context $ExtraProducerBindingContext -Requirements $Requirements -SelectedChecks @('visual-package')
$ExtraProducerBindingContext.producerBindings=@(
	[pscustomobject][ordered]@{key='other';jobName='other-job';artifactId='999';artifactName=('ci-receipt-other-9001-2-' + $script:FixtureNonce);digest=('sha256:' + ('8' * 64))},
	$ExtraProducerBindingContext.producerBindings[0]
)
Assert-Rejected { New-CiAcceptanceAggregate -Context $ExtraProducerBindingContext -Requirements $Requirements -ApiRequest $ExtraProducerBindingApi -DeadlineSeconds 30 } 'producer_binding_unexpected'

$SwappedProducerBindingContext=New-FixtureContext
$SwappedProducerBindingApi=New-FixtureApi -Context $SwappedProducerBindingContext -Requirements $Requirements -SelectedChecks @('visual-package')
$SwappedProducerBindingContext.producerBindings[0].jobName='trusted-candidate-compile'
Assert-Rejected { New-CiAcceptanceAggregate -Context $SwappedProducerBindingContext -Requirements $Requirements -ApiRequest $SwappedProducerBindingApi -DeadlineSeconds 30 } 'producer_binding_requirement_mismatch'

foreach ($ProducerBindingApiCase in @(
	@{name='wrong-id';mutate={param($x)$x.producerBindings[0].artifactId='999'}},
	@{name='wrong-digest';mutate={param($x)$x.producerBindings[0].digest='sha256:' + ('9' * 64)}}
)) {
	$BindingContext=New-FixtureContext;$BindingApi=New-FixtureApi -Context $BindingContext -Requirements $Requirements -SelectedChecks @('visual-package');& $ProducerBindingApiCase.mutate $BindingContext
	try { Assert-Rejected { New-CiAcceptanceAggregate -Context $BindingContext -Requirements $Requirements -ApiRequest $BindingApi -DeadlineSeconds 30 } 'producer_binding_api_mismatch' }
	catch { throw "Aggregate producer API binding fixture '$($ProducerBindingApiCase.name)' failed: $($_.Exception.Message)" }
}

foreach ($ProducerBindingShapeCase in @(
	@{name='extra-field';reason='producer_binding_schema_invalid';mutate={param($x)$x.producerBindings[0]|Add-Member -NotePropertyName extra -NotePropertyValue 'x'}},
	@{name='replayed-name';reason='producer_binding_invalid';mutate={param($x)$x.producerBindings[0].artifactName='ci-receipt-quality-9001-1-' + $script:FixtureNonce}},
	@{name='uppercase-digest';reason='producer_binding_invalid';mutate={param($x)$x.producerBindings[0].digest='sha256:' + ('A' * 64)}},
	@{name='digest-trailing-lf';reason='producer_binding_invalid';mutate={param($x)$x.producerBindings[0].digest='sha256:' + ('8' * 64) + "`n"}}
)) {
	$BindingContext=New-FixtureContext;$BindingApi=New-FixtureApi -Context $BindingContext -Requirements $Requirements -SelectedChecks @('visual-package');& $ProducerBindingShapeCase.mutate $BindingContext
	try { Assert-Rejected { New-CiAcceptanceAggregate -Context $BindingContext -Requirements $Requirements -ApiRequest $BindingApi -DeadlineSeconds 30 } $ProducerBindingShapeCase.reason }
	catch { throw "Aggregate producer binding fixture '$($ProducerBindingShapeCase.name)' failed: $($_.Exception.Message)" }
}

$BothBindingsContext=New-FixtureContext
$BothBindingsApi=New-FixtureApi -Context $BothBindingsContext -Requirements $Requirements -SelectedChecks @('native-client-server-compile','visual-package')
$BothBindingsAggregate=New-CiAcceptanceAggregate -Context $BothBindingsContext -Requirements $Requirements -ApiRequest $BothBindingsApi -DeadlineSeconds 30
Assert-True (@($BothBindingsContext.producerBindings).Count -eq 2 -and (@($BothBindingsContext.producerBindings | ForEach-Object key) -join ',') -ceq 'native,quality' -and @($BothBindingsAggregate.receipts).Count -eq 2) 'Multiple selected producers must reconcile through one sorted direct binding each.'
$BothBindingsContext.producerBindings=@($BothBindingsContext.producerBindings[1],$BothBindingsContext.producerBindings[0])
Assert-Rejected { New-CiAcceptanceAggregate -Context $BothBindingsContext -Requirements $Requirements -ApiRequest $BothBindingsApi -DeadlineSeconds 30 } 'producer_bindings_not_sorted'

$DuplicateBindingContext=New-FixtureContext
$DuplicateBindingApi=New-FixtureApi -Context $DuplicateBindingContext -Requirements $Requirements -SelectedChecks @('native-client-server-compile','visual-package')
$DuplicateBindingContext.producerBindings[1].artifactId=$DuplicateBindingContext.producerBindings[0].artifactId
Assert-Rejected { New-CiAcceptanceAggregate -Context $DuplicateBindingContext -Requirements $Requirements -ApiRequest $DuplicateBindingApi -DeadlineSeconds 30 } 'producer_bindings_duplicate'

$VisualBoundary = New-FixtureVisualBoundary -Context $Context
$VisualResults = @(Assert-CiAcceptanceReceipt -Receipt $VisualBoundary.receipt -Context $Context -Requirement $VisualBoundary.requirement -Archive $VisualBoundary.archive)
Assert-True ($VisualResults.Count -eq 1 -and @($VisualResults[0]).Count -eq 1) 'The aggregate must accept exact, identity-bound visual semantic evidence.'
$MissingReceiptAnchor = New-FixtureVisualBoundary -Context $Context
$MissingReceiptAnchor.receipt.PSObject.Properties.Remove('attemptAnchor')
Assert-Rejected { Assert-CiAcceptanceReceipt -Receipt $MissingReceiptAnchor.receipt -Context $Context -Requirement $MissingReceiptAnchor.requirement -Archive $MissingReceiptAnchor.archive } 'receipt_schema_invalid'
$ReplayedReceiptAnchor = New-FixtureVisualBoundary -Context $Context
$ReplayedReceiptAnchor.receipt.attemptAnchor = $ReplayedReceiptAnchor.receipt.attemptAnchor | ConvertTo-Json -Depth 4 | ConvertFrom-Json
$ReplayedReceiptAnchor.receipt.attemptAnchor.runAttempt = 1
Assert-Rejected { Assert-CiAcceptanceReceipt -Receipt $ReplayedReceiptAnchor.receipt -Context $Context -Requirement $ReplayedReceiptAnchor.requirement -Archive $ReplayedReceiptAnchor.archive } 'context_attempt_anchor_invalid'
$MismatchedReceiptAnchor = New-FixtureVisualBoundary -Context $Context
$MismatchedReceiptAnchor.receipt.attemptAnchor = $MismatchedReceiptAnchor.receipt.attemptAnchor | ConvertTo-Json -Depth 4 | ConvertFrom-Json
$MismatchedReceiptAnchor.receipt.attemptAnchor.nonce = '7' * 64
Assert-Rejected { Assert-CiAcceptanceReceipt -Receipt $MismatchedReceiptAnchor.receipt -Context $Context -Requirement $MismatchedReceiptAnchor.requirement -Archive $MismatchedReceiptAnchor.archive } 'receipt_identity_mismatch:attemptAnchor'
$RepetitiveReport = New-FixtureVisualReport -Context $Context
$RepetitiveOutput = @(0..29 | ForEach-Object { 'stdout: ' + ('z' * 4000) })
$RepetitiveBytes = [long] (($RepetitiveOutput | ForEach-Object { $script:Utf8.GetByteCount($_) } | Measure-Object -Sum).Sum)
foreach ($Result in $RepetitiveReport.results) {
	$Result.output = $RepetitiveOutput
	$Result.capture.observedLineCount = $RepetitiveOutput.Count
	$Result.capture.capturedLineCount = $RepetitiveOutput.Count
	$Result.capture.capturedUtf8Bytes = $RepetitiveBytes
}
$RepetitiveBoundary = New-FixtureVisualBoundary -Context $Context -Report $RepetitiveReport
$RepetitiveArchiveBytes = New-FixtureZip @(
	[pscustomobject]@{name='ci-acceptance-receipt.json';bytes=(ConvertTo-FixtureBytes $RepetitiveBoundary.receipt)},
	[pscustomobject]@{name='visual-package-report.json';bytes=(ConvertTo-FixtureBytes $RepetitiveReport)}
)
$RepetitiveArchive = Read-StrictCiArchive -Bytes $RepetitiveArchiveBytes
$RepetitiveReceiptEntry = @($RepetitiveArchive.entries | Where-Object name -ceq 'ci-acceptance-receipt.json')[0]
$RepetitiveReceipt = ConvertFrom-StrictBoundedJson -Bytes $RepetitiveReceiptEntry.bytes
$RepetitiveResults = @(Assert-CiAcceptanceReceipt -Receipt $RepetitiveReceipt -Context $Context -Requirement $RepetitiveBoundary.requirement -Archive $RepetitiveArchive)
Assert-True ($RepetitiveResults.Count -eq 1 -and $RepetitiveArchiveBytes.Length -lt 10000) 'A schema-valid highly compressed visual evidence archive must be accepted under expanded-byte limits.'
$VisualExitLie = New-FixtureVisualBoundary -Context $Context
$VisualExitLie.receipt.results.checks[0].nativeExitCode = 0
Assert-Rejected { Assert-CiAcceptanceReceipt -Receipt $VisualExitLie.receipt -Context $Context -Requirement $VisualExitLie.requirement -Archive $VisualExitLie.archive } 'receipt_semantic_evidence_invalid:visual-package'
$VisualCleanupLie = New-FixtureVisualBoundary -Context $Context
$VisualCleanupLie.receipt.results.checks[0].cleanupVerified = $true
Assert-Rejected { Assert-CiAcceptanceReceipt -Receipt $VisualCleanupLie.receipt -Context $Context -Requirement $VisualCleanupLie.requirement -Archive $VisualCleanupLie.archive } 'receipt_semantic_evidence_invalid:visual-package'
$VisualAcceptanceCleanupLie = New-FixtureVisualBoundary -Context $Context
$VisualAcceptanceCleanupLie.receipt.acceptance.cleanupVerified = $true
Assert-Rejected { Assert-CiAcceptanceReceipt -Receipt $VisualAcceptanceCleanupLie.receipt -Context $Context -Requirement $VisualAcceptanceCleanupLie.requirement -Archive $VisualAcceptanceCleanupLie.archive } 'receipt_cleanup_invalid'

foreach ($Fixture in @(
	@{id='portable';report=(New-FixturePortableReport $Context);reason='receipt_semantic_evidence_failure:portable';mutate={param($x)$x.summary.requiredFailed=1}},
	@{id='native-client-server-compile';report=(New-FixtureEngineReport $Context);reason='receipt_semantic_evidence_invalid:native-client-server-compile';mutate={param($x)$x.supervisor.cleanupVerified=$false}},
	@{id='unreal-editor-automation';report=(New-FixtureUnrealReport $Context);reason='receipt_semantic_evidence_invalid:unreal-editor-automation';mutate={param($x)$x.tests[0].status='failed'}}
)) {
	$Boundary = New-FixtureSemanticBoundary -Context $Context -CheckId $Fixture.id -Report $Fixture.report
	$Validated = @(Assert-CiAcceptanceReceipt -Receipt $Boundary.receipt -Context $Context -Requirement $Boundary.requirement -Archive $Boundary.archive)
	Assert-True ($Validated.Count -eq 1 -and @($Validated[0]).Count -eq 1) "Aggregate must accept exact semantic evidence for '$($Fixture.id)'."
	$BadReport=$Fixture.report|ConvertTo-Json -Depth 20|ConvertFrom-Json;& $Fixture.mutate $BadReport
	$BadBoundary=New-FixtureSemanticBoundary -Context $Context -CheckId $Fixture.id -Report $BadReport
	Assert-Rejected { Assert-CiAcceptanceReceipt -Receipt $BadBoundary.receipt -Context $Context -Requirement $BadBoundary.requirement -Archive $BadBoundary.archive } $Fixture.reason
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
	$BadPortable=New-FixturePortableReport $Context;& $PortableTypeCase.mutate $BadPortable
	$Boundary=New-FixtureSemanticBoundary -Context $Context -CheckId 'portable' -Report $BadPortable
	try { Assert-Rejected { Assert-CiAcceptanceReceipt -Receipt $Boundary.receipt -Context $Context -Requirement $Boundary.requirement -Archive $Boundary.archive } 'receipt_semantic_evidence_invalid:portable' }
	catch { throw "Aggregate portable fixture '$($PortableTypeCase.name)' failed: $($_.Exception.Message)" }
}
$SkippedAnalyzer=New-FixturePortableReport $Context
$SkippedAnalyzer.checks[$SkippedAnalyzer.checks.Count-1].status='skipped';$SkippedAnalyzer.summary.passed--;$SkippedAnalyzer.summary.skipped++
$SkippedAnalyzerBoundary=New-FixtureSemanticBoundary -Context $Context -CheckId 'portable' -Report $SkippedAnalyzer
Assert-Rejected { Assert-CiAcceptanceReceipt -Receipt $SkippedAnalyzerBoundary.receipt -Context $Context -Requirement $SkippedAnalyzerBoundary.requirement -Archive $SkippedAnalyzerBoundary.archive } 'receipt_semantic_evidence_failure:portable'

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
	$BadNative=New-FixtureEngineReport $Context;& $NativeTypeCase.mutate $BadNative
	$Boundary=New-FixtureSemanticBoundary -Context $Context -CheckId 'native-client-server-compile' -Report $BadNative
	try { Assert-Rejected { Assert-CiAcceptanceReceipt -Receipt $Boundary.receipt -Context $Context -Requirement $Boundary.requirement -Archive $Boundary.archive } 'receipt_semantic_evidence_invalid:native-client-server-compile' }
	catch { throw "Aggregate native fixture '$($NativeTypeCase.name)' failed: $($_.Exception.Message)" }
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
	$BadUnreal=New-FixtureUnrealReport $Context;& $UnrealTypeCase.mutate $BadUnreal
	$Boundary=New-FixtureSemanticBoundary -Context $Context -CheckId 'unreal-editor-automation' -Report $BadUnreal
	try { Assert-Rejected { Assert-CiAcceptanceReceipt -Receipt $Boundary.receipt -Context $Context -Requirement $Boundary.requirement -Archive $Boundary.archive } 'receipt_semantic_evidence_invalid:unreal-editor-automation' }
	catch { throw "Aggregate Unreal fixture '$($UnrealTypeCase.name)' failed: $($_.Exception.Message)" }
}

foreach ($UnsupportedId in @('clean-package-provenance-smoke','content-reference-validation','controller-contract','controller-operational-proof')) {
	$UnsupportedRequirement = [pscustomobject][ordered]@{key='unsupported';jobName='unsupported-proof';selected=$true;artifactName=('ci-receipt-unsupported-9001-2-' + $Context.attemptAnchor.nonce);checks=@($UnsupportedId)}
	$UnsupportedBytes = $script:Utf8.GetBytes('opaque-proof')
	$UnsupportedReceipt = New-FixtureReceipt -Context $Context -Requirement $UnsupportedRequirement -EvidenceBytes $UnsupportedBytes
	$UnsupportedReceiptBytes = ConvertTo-FixtureBytes $UnsupportedReceipt
	$UnsupportedArchive = [pscustomobject][ordered]@{entries=@(
		[pscustomobject][ordered]@{name='ci-acceptance-receipt.json';bytes=$UnsupportedReceiptBytes;sizeBytes=[long]$UnsupportedReceiptBytes.Length;sha256=(Get-Sha256 $UnsupportedReceiptBytes)},
		[pscustomobject][ordered]@{name=$UnsupportedReceipt.results.checks[0].evidence[0].name;bytes=$UnsupportedBytes;sizeBytes=[long]$UnsupportedBytes.Length;sha256=(Get-Sha256 $UnsupportedBytes)}
	)}
	Assert-Rejected { Assert-CiAcceptanceReceipt -Receipt $UnsupportedReceipt -Context $Context -Requirement $UnsupportedRequirement -Archive $UnsupportedArchive } ('receipt_semantic_evidence_unsupported:' + $UnsupportedId)
}

foreach ($SemanticCase in @(
	@{reason='receipt_semantic_evidence_failure:visual-package';mutate={param($r)$r.conclusion='failure'}},
	@{reason='receipt_semantic_evidence_failure:visual-package';mutate={param($r)$r.results[0].nativeExitCode=13;$r.results[0].conclusion='failure'}},
	@{reason='receipt_semantic_evidence_invalid:visual-package';mutate={param($r)$r.repository='other/repository'}},
	@{reason='receipt_semantic_evidence_invalid:visual-package';mutate={param($r)$r.revision=('9' * 40)}},
	@{reason='receipt_semantic_evidence_invalid:visual-package';mutate={param($r)$r.run.attempt=3}},
	@{reason='receipt_semantic_evidence_failure:visual-package';mutate={param($r)$r.results[1].id='visual-package'}},
	@{reason='receipt_semantic_evidence_invalid:visual-package';mutate={param($r)$r.results[0].capture.capturedUtf8Bytes++}},
	@{reason='receipt_semantic_evidence_invalid:visual-package';mutate={param($r)$r.results[0].output=@('x' * 4097)}}
)) {
	$BadReport = New-FixtureVisualReport -Context $Context
	& $SemanticCase.mutate $BadReport
	$BadBoundary = New-FixtureVisualBoundary -Context $Context -Report $BadReport
	Assert-Rejected { Assert-CiAcceptanceReceipt -Receipt $BadBoundary.receipt -Context $Context -Requirement $BadBoundary.requirement -Archive $BadBoundary.archive } $SemanticCase.reason
}

$MalformedBoundary = New-FixtureVisualBoundary -Context $Context
$MalformedBytes = $script:Utf8.GetBytes('{"schemaVersion":')
$MalformedBoundary.receipt.results.checks[0].evidence[0].sha256 = Get-Sha256 $MalformedBytes
$MalformedBoundary.receipt.results.checks[0].evidence[0].sizeBytes = [long] $MalformedBytes.Length
$MalformedBoundary.archive.entries[1].bytes = $MalformedBytes; $MalformedBoundary.archive.entries[1].sha256 = Get-Sha256 $MalformedBytes; $MalformedBoundary.archive.entries[1].sizeBytes = [long] $MalformedBytes.Length
Assert-Rejected { Assert-CiAcceptanceReceipt -Receipt $MalformedBoundary.receipt -Context $Context -Requirement $MalformedBoundary.requirement -Archive $MalformedBoundary.archive } 'receipt_semantic_evidence_invalid:visual-package'

$MissingBoundary = New-FixtureVisualBoundary -Context $Context
$MissingBoundary.receipt.results.checks[0].evidence[0].name='other-report.json'; $MissingBoundary.archive.entries[1].name='other-report.json'
Assert-Rejected { Assert-CiAcceptanceReceipt -Receipt $MissingBoundary.receipt -Context $Context -Requirement $MissingBoundary.requirement -Archive $MissingBoundary.archive } 'receipt_semantic_evidence_missing:visual-package'
$DuplicateBoundary = New-FixtureVisualBoundary -Context $Context
$DuplicateBoundary.receipt.results.checks[0].evidence=@($DuplicateBoundary.receipt.results.checks[0].evidence[0],$DuplicateBoundary.receipt.results.checks[0].evidence[0])
Assert-Rejected { Assert-CiAcceptanceReceipt -Receipt $DuplicateBoundary.receipt -Context $Context -Requirement $DuplicateBoundary.requirement -Archive $DuplicateBoundary.archive } 'receipt_semantic_evidence_duplicate:visual-package'

$Push = New-FixtureContext 'push'
$Push.source.testedRevision = $Push.source.headRevision
$Push.workflow.revision = $Push.source.headRevision
$Push.workflow.parents = @($Push.source.baseRevision)
$Push.controller.revision = $Push.source.headRevision
$PushRequirements = New-FixtureRequirements
$PushApi = New-FixtureApi -Context $Push -Requirements $PushRequirements
$PushAggregate = New-CiAcceptanceAggregate -Context $Push -Requirements $PushRequirements -ApiRequest $PushApi -DeadlineSeconds 30
Assert-True ($PushAggregate.decision.evidenceClass -ceq 'post_merge_hosted_health' -and -not $PushAggregate.decision.grantsAcceptance) 'Push evidence must be health-only and never source acceptance.'
Assert-True (@($PushAggregate.receipts).Count -eq 0 -and @($PushAggregate.jobs | Where-Object { -not $_.selected -and $_.conclusion -ceq 'skipped' }).Count -eq 2) 'Unselected push work must be API-verified as skipped and emit no receipt.'
$PushWithoutBase = New-FixtureContext 'push'
$PushWithoutBase.source.baseRevision = $null
Assert-Rejected { New-CiAcceptanceAggregate -Context $PushWithoutBase -Requirements $PushRequirements -ApiRequest (New-FixtureApi -Context $PushWithoutBase -Requirements $PushRequirements) -DeadlineSeconds 30 } 'context_revision_invalid'
$PushWrongParent = New-FixtureContext 'push'
$PushWrongParent.source.testedRevision = $PushWrongParent.source.headRevision
$PushWrongParent.workflow.revision = $PushWrongParent.source.headRevision
$PushWrongParent.controller.revision = $PushWrongParent.source.headRevision
$PushWrongParent.workflow.parents = @(('f' * 40))
Assert-Rejected { New-CiAcceptanceAggregate -Context $PushWrongParent -Requirements $PushRequirements -ApiRequest (New-FixtureApi -Context $PushWrongParent -Requirements $PushRequirements) -DeadlineSeconds 30 } 'context_workflow_invalid'

Assert-Rejected { ConvertFrom-StrictBoundedJson -Bytes $script:Utf8.GetBytes('{"x":1,"\u0078":2}') -MaximumBytes 100 -MaximumDepth 4 -MaximumProperties 5 -MaximumArrayItems 5 } 'json_duplicate_property'
Assert-Rejected { ConvertFrom-StrictBoundedJson -Bytes $script:Utf8.GetBytes('{"x":1} trailing') -MaximumBytes 100 -MaximumDepth 4 -MaximumProperties 5 -MaximumArrayItems 5 } 'json_syntax_invalid'
Assert-Rejected { ConvertFrom-StrictBoundedJson -Bytes $script:Utf8.GetBytes('[[[[[0]]]]]') -MaximumBytes 100 -MaximumDepth 4 -MaximumProperties 5 -MaximumArrayItems 5 } 'json_depth_limit'
Assert-Rejected { ConvertFrom-StrictBoundedJson -Bytes $script:Utf8.GetBytes('[0,1,2]') -MaximumBytes 100 -MaximumDepth 4 -MaximumProperties 5 -MaximumArrayItems 2 } 'json_array_limit'
Assert-Rejected { ConvertFrom-StrictBoundedJson -Bytes $script:Utf8.GetBytes('{"a":1,"b":2}') -MaximumBytes 100 -MaximumDepth 4 -MaximumProperties 1 -MaximumArrayItems 5 } 'json_property_limit'

$ApiTarget = Resolve-AggregateRequestTarget -Uri '/repos/ShayShimoni/aetheln-online/actions/runs/9001' -ApiBaseUri 'https://api.github.com' -RequestKind 'Api'
Assert-True ($ApiTarget.uri.AbsoluteUri -ceq 'https://api.github.com/repos/ShayShimoni/aetheln-online/actions/runs/9001' -and $ApiTarget.sendAuthorization) 'Relative API paths must resolve only to the exact GitHub API origin with authorization.'
$StorageTarget = Resolve-AggregateRequestTarget -Uri 'https://results0123.blob.core.windows.net/actions-results/fixture?sig=redacted' -ApiBaseUri 'https://api.github.com' -RequestKind 'Artifact' -RedirectSource ([uri]'https://api.github.com/repos/ShayShimoni/aetheln-online/actions/artifacts/200/zip')
Assert-True (-not $StorageTarget.sendAuthorization -and $StorageTarget.uri.Scheme -ceq 'https') 'Artifact-storage redirects must be HTTPS and must never receive the bearer token.'
foreach ($UnsafeUri in @('http://api.github.com/repos/x','https://user@api.github.com/repos/x','https://api.github.com:444/repos/x','https://api.github.com.evil.example/repos/x','https://evil.example/api.github.com/repos/x','https://127.0.0.1/repos/x')) {
	Assert-Rejected { Resolve-AggregateRequestTarget -Uri $UnsafeUri -ApiBaseUri 'https://api.github.com' -RequestKind 'Artifact' } 'api_uri_invalid'
}
foreach ($UnsafeRedirect in @('http://results0123.blob.core.windows.net/x','https://user@results0123.blob.core.windows.net/x','https://results0123.blob.core.windows.net:444/x','https://blob.core.windows.net/x','https://results0123.blob.core.windows.net.evil.example/x','https://evil.example/x')) {
	Assert-Rejected { Resolve-AggregateRequestTarget -Uri $UnsafeRedirect -ApiBaseUri 'https://api.github.com' -RequestKind 'Artifact' -RedirectSource ([uri]'https://api.github.com/repos/x') } 'api_redirect_invalid'
}
Assert-Rejected { Resolve-AggregateRequestTarget -Uri 'https://other0123.blob.core.windows.net/x' -ApiBaseUri 'https://api.github.com' -RequestKind 'Artifact' -RedirectSource ([uri]'https://results0123.blob.core.windows.net/x') } 'api_redirect_invalid'

# The API callback contract supplies these arguments; this budget fixture intentionally ignores their values.
$BudgetFixture = { param([string]$Uri,[int]$Remaining,[int]$Maximum,[string]$Kind) $null = $Uri; $null = $Remaining; $null = $Maximum; $null = $Kind; return ,[byte[]](1,2,3) }
$RequestBudget = New-AggregateBudget -MaximumRequests 1 -MaximumNetworkBytes 100 -MaximumArchiveBytes 100 -MaximumExpandedBytes 100
[void](Invoke-AggregateApi -ApiRequest $BudgetFixture -Uri '/one' -Clock ([Diagnostics.Stopwatch]::StartNew()) -DeadlineSeconds 30 -MaximumBytes 10 -Budget $RequestBudget -RequestKind Api)
Assert-Rejected { Invoke-AggregateApi -ApiRequest $BudgetFixture -Uri '/two' -Clock ([Diagnostics.Stopwatch]::StartNew()) -DeadlineSeconds 30 -MaximumBytes 10 -Budget $RequestBudget -RequestKind Api } 'api_request_budget_exceeded'
$NetworkBudget = New-AggregateBudget -MaximumRequests 10 -MaximumNetworkBytes 5 -MaximumArchiveBytes 100 -MaximumExpandedBytes 100
[void](Invoke-AggregateApi -ApiRequest $BudgetFixture -Uri '/one' -Clock ([Diagnostics.Stopwatch]::StartNew()) -DeadlineSeconds 30 -MaximumBytes 10 -Budget $NetworkBudget -RequestKind Api)
Assert-Rejected { Invoke-AggregateApi -ApiRequest $BudgetFixture -Uri '/two' -Clock ([Diagnostics.Stopwatch]::StartNew()) -DeadlineSeconds 30 -MaximumBytes 10 -Budget $NetworkBudget -RequestKind Api } 'network_byte_budget_exceeded'
$BudgetArchiveBytes = New-FixtureZip @([pscustomobject]@{name='proof.json';bytes='12345'})
$ArchiveBudget = New-AggregateBudget -MaximumRequests 10 -MaximumNetworkBytes 100000 -MaximumArchiveBytes ($BudgetArchiveBytes.Length + 1) -MaximumExpandedBytes 100
[void](Read-StrictCiArchive -Bytes $BudgetArchiveBytes -Budget $ArchiveBudget)
Assert-Rejected { Read-StrictCiArchive -Bytes $BudgetArchiveBytes -Budget $ArchiveBudget } 'archive_byte_budget_exceeded'
$ExpandedBudget = New-AggregateBudget -MaximumRequests 10 -MaximumNetworkBytes 100000 -MaximumArchiveBytes 100000 -MaximumExpandedBytes 7
[void](Read-StrictCiArchive -Bytes $BudgetArchiveBytes -Budget $ExpandedBudget)
Assert-Rejected { Read-StrictCiArchive -Bytes $BudgetArchiveBytes -Budget $ExpandedBudget } 'archive_expanded_byte_budget_exceeded'

$ReceiptBytes = ConvertTo-FixtureBytes (New-FixtureReceipt -Context $Context -Requirement $Requirements.jobs[0])
$DuplicateArchive = New-FixtureZip @([pscustomobject]@{name='ci-acceptance-receipt.json';bytes=$ReceiptBytes},[pscustomobject]@{name='ci-acceptance-receipt.json';bytes=$ReceiptBytes})
Assert-Rejected { Read-StrictCiArchive -Bytes $DuplicateArchive } 'archive_path_collision'
$TraversalArchive = New-FixtureZip @([pscustomobject]@{name='../receipt.json';bytes='x'})
Assert-Rejected { Read-StrictCiArchive -Bytes $TraversalArchive } 'archive_path_invalid'
$CaseArchive = New-FixtureZip @([pscustomobject]@{name='Evidence/raw.json';bytes='x'},[pscustomobject]@{name='evidence/RAW.json';bytes='x'})
Assert-Rejected { Read-StrictCiArchive -Bytes $CaseArchive } 'archive_path_collision'
$LinkArchive = New-FixtureZip @([pscustomobject]@{name='link';bytes='target';externalAttributes=[int]0xA1FF0000})
Assert-Rejected { Read-StrictCiArchive -Bytes $LinkArchive } 'archive_link_rejected'
$ExpandedArchive = New-FixtureZip @([pscustomobject]@{name='evidence/a.txt';bytes=('a' * 100)},[pscustomobject]@{name='evidence/b.txt';bytes=('b' * 100)})
Assert-Rejected { Read-StrictCiArchive -Bytes $ExpandedArchive -MaximumExpandedBytes 150 } 'archive_expanded_size_limit'
$OversizedEntryArchive = New-FixtureZip @([pscustomobject]@{name='evidence/oversized.bin';bytes=(New-Object byte[] (4MB + 1))})
Assert-Rejected { Read-StrictCiArchive -Bytes $OversizedEntryArchive } 'archive_entry_size_limit'
$ExpandedBombSpecs = @(0..4 | ForEach-Object { [pscustomobject]@{name=('evidence/bomb-{0}.txt' -f $_);bytes=('z' * 4MB)} })
$ExpandedBombArchive = New-FixtureZip $ExpandedBombSpecs
Assert-Rejected { Read-StrictCiArchive -Bytes $ExpandedBombArchive } 'archive_expanded_size_limit'
Assert-True ($script:AggregateLimits.archiveEntryBytes -eq 4MB) 'Aggregate archive entries must retain the exact 4 MiB ceiling.'

$BadContext = New-FixtureContext
$BadContext | Add-Member -NotePropertyName surprise -NotePropertyValue $true
Assert-Rejected { New-CiAcceptanceAggregate -Context $BadContext -Requirements $Requirements -ApiRequest (New-FixtureApi -Context $BadContext -Requirements $Requirements) -DeadlineSeconds 30 } 'context_schema_invalid'
$BadActions = New-FixtureContext
$BadActions.actions.manifestSha256 = ('0' * 64)
Assert-Rejected { New-CiAcceptanceAggregate -Context $BadActions -Requirements $Requirements -ApiRequest (New-FixtureApi -Context $BadActions -Requirements $Requirements) -DeadlineSeconds 30 } 'context_actions_manifest_mismatch'
$IncompleteRequirements = New-FixtureRequirements
$IncompleteRequirements.jobs[1].checks = @($IncompleteRequirements.jobs[1].checks | Where-Object { $_ -cne 'visual-package' })
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $IncompleteRequirements -ApiRequest (New-FixtureApi -Context $Context -Requirements $IncompleteRequirements) -DeadlineSeconds 30 } 'requirements_check_coverage_incomplete'
$UnsafeAction = New-FixtureContext
$UnsafeAction.actions.items[1].uses = 'actions//subpath'
Assert-Rejected { New-CiAcceptanceAggregate -Context $UnsafeAction -Requirements $Requirements -ApiRequest (New-FixtureApi -Context $UnsafeAction -Requirements $Requirements) -DeadlineSeconds 30 } 'context_actions_invalid'

$PaginationBytes = ConvertTo-FixtureBytes ([pscustomobject][ordered]@{ total_count = 0; jobs = @([pscustomobject][ordered]@{ id = 1 }) })
$PaginationApi = { param([string] $Uri, [int] $RemainingMilliseconds, [int] $MaximumBytes) if ($Uri -cne '/fixture?per_page=100&page=1' -or $RemainingMilliseconds -le 0 -or $PaginationBytes.Length -gt $MaximumBytes) { throw 'pagination_fixture_invalid' }; return ,$PaginationBytes }.GetNewClosure()
Assert-Rejected { Get-PagedApiItems -ApiRequest $PaginationApi -BaseUri '/fixture' -PropertyName 'jobs' -Clock ([Diagnostics.Stopwatch]::StartNew()) -DeadlineSeconds 30 } 'api_pagination_count_mismatch'
$SlowDeadlineApi = { param([string] $Uri, [int] $RemainingMilliseconds, [int] $MaximumBytes) if ([string]::IsNullOrWhiteSpace($Uri) -or $RemainingMilliseconds -le 0 -or $MaximumBytes -lt 3) { throw 'deadline_fixture_invalid' }; Start-Sleep -Milliseconds 1100; return ,([byte[]](1,2,3)) }
$ExpiredDeadlineClock = [Diagnostics.Stopwatch]::StartNew()
Assert-Rejected { Invoke-AggregateApi -ApiRequest $SlowDeadlineApi -Uri '/slow' -Clock $ExpiredDeadlineClock -DeadlineSeconds 1 -MaximumBytes 16 } 'api_deadline_exceeded'
$DeadlineArchive = New-FixtureZip @([pscustomobject]@{name='deadline.txt';bytes='bounded'})
Assert-Rejected { Read-StrictCiArchive -Bytes $DeadlineArchive -Clock $ExpiredDeadlineClock -DeadlineSeconds 1 } 'api_deadline_exceeded'
$OriginalContextJson = $ContextJson
$OriginalRequirementsJson = $RequirementsJson
$OriginalOutputPath = $OutputPath
$OriginalDeadlineSeconds = $DeadlineSeconds
$MainOutputPath = Join-Path ([IO.Path]::GetTempPath()) ('aetheln-ci-acceptance-main-' + [guid]::NewGuid().ToString('N') + '.json')
$ExpiredOutputPath = Join-Path ([IO.Path]::GetTempPath()) ('aetheln-ci-acceptance-expired-' + [guid]::NewGuid().ToString('N') + '.json')
$ExpiredDuringWriteOutputPath = Join-Path ([IO.Path]::GetTempPath()) ('aetheln-ci-acceptance-write-expired-' + [guid]::NewGuid().ToString('N') + '.json')
$ExpiredAfterWriteOutputPath = Join-Path ([IO.Path]::GetTempPath()) ('aetheln-ci-acceptance-after-write-expired-' + [guid]::NewGuid().ToString('N') + '.json')
try {
	$Api = New-FixtureApi -Context $Context -Requirements $Requirements
	$ContextJson = $Context | ConvertTo-Json -Depth 20 -Compress
	$RequirementsJson = $Requirements | ConvertTo-Json -Depth 20 -Compress
	$OutputPath = $MainOutputPath
	$DeadlineSeconds = 10
	$MainClock = [Diagnostics.Stopwatch]::StartNew()
	$MainAggregate = Invoke-CiAcceptanceAggregateMain -ApiRequest $Api -Clock $MainClock
	Assert-True ((Test-Path -LiteralPath $MainOutputPath -PathType Leaf) -and $MainAggregate.decision.complete -and $MainClock.ElapsedMilliseconds -lt 10000) 'The real entrypoint must use one caller-visible clock through bounded parsing, aggregation, and final output.'
	$OutputPath = $ExpiredOutputPath
	$ExpiredMainClock = [Diagnostics.Stopwatch]::StartNew()
	Start-Sleep -Milliseconds 1100
	Assert-Rejected { Invoke-CiAcceptanceAggregateMain -ApiRequest $Api -Clock $ExpiredMainClock -OperationDeadlineSeconds 1 } 'api_deadline_exceeded'
	Assert-True (-not (Test-Path -LiteralPath $ExpiredOutputPath)) 'An entrypoint whose operation deadline has already expired must not publish output.'
	Assert-Rejected { Write-BoundedAggregate -Aggregate $Aggregate -Path $ExpiredOutputPath -Clock $ExpiredMainClock -DeadlineSeconds 1 } 'api_deadline_exceeded'
	Assert-True (-not (Test-Path -LiteralPath $ExpiredOutputPath)) 'An expired final-output deadline must be rejected before creating the output file.'
	$SlowFileWriter = { param([string] $TemporaryPath, [byte[]] $Bytes) [IO.File]::WriteAllBytes($TemporaryPath, $Bytes); Start-Sleep -Milliseconds 1100 }
	$WriteClock = [Diagnostics.Stopwatch]::StartNew()
	Assert-Rejected { Write-BoundedAggregate -Aggregate $Aggregate -Path $ExpiredDuringWriteOutputPath -Clock $WriteClock -DeadlineSeconds 1 -FileWriter $SlowFileWriter } 'api_deadline_exceeded'
	Assert-True (-not (Test-Path -LiteralPath $ExpiredDuringWriteOutputPath)) 'Crossing the deadline during output flush must not publish a complete-looking aggregate.'
	$TemporaryPattern = '.' + [IO.Path]::GetFileName($ExpiredDuringWriteOutputPath) + '.*.tmp'
	Assert-True (@(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($ExpiredDuringWriteOutputPath)) -Filter $TemporaryPattern -File).Count -eq 0) 'A failed final-output deadline must clean its private temporary file.'
	$OutputPath = $ExpiredAfterWriteOutputPath
	$AfterWriteDelay = { Start-Sleep -Milliseconds 10100 }
	Assert-Rejected { Invoke-CiAcceptanceAggregateMain -ApiRequest $Api -Clock ([Diagnostics.Stopwatch]::StartNew()) -AfterWrite $AfterWriteDelay -OperationDeadlineSeconds 10 } 'api_deadline_exceeded'
	Assert-True (-not (Test-Path -LiteralPath $ExpiredAfterWriteOutputPath)) 'Crossing the operation deadline after atomic publication but before entrypoint return must revoke that output.'
} finally {
	$ContextJson = $OriginalContextJson
	$RequirementsJson = $OriginalRequirementsJson
	$OutputPath = $OriginalOutputPath
	$DeadlineSeconds = $OriginalDeadlineSeconds
	foreach ($TemporaryPath in @($MainOutputPath, $ExpiredOutputPath, $ExpiredDuringWriteOutputPath, $ExpiredAfterWriteOutputPath)) {
		if (Test-Path -LiteralPath $TemporaryPath -PathType Leaf) { Remove-Item -LiteralPath $TemporaryPath -Force }
	}
}

$StaleRun = [pscustomobject][ordered]@{ id = 9001; run_attempt = 3; workflow_id = 1234; event = 'pull_request'; head_sha = $Context.source.headRevision; status = 'in_progress'; conclusion = $null; actor=[pscustomobject]@{login=$Context.event.actor}; triggering_actor=[pscustomobject]@{login=$Context.event.triggeringActor} }
$StaleApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{ '/repos/ShayShimoni/aetheln-online/actions/runs/9001' = (ConvertTo-FixtureBytes $StaleRun) }
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $StaleApi -DeadlineSeconds 30 } 'run_attempt_stale'

$InitialContext = New-FixtureContext
$InitialContext.run.attempt = 1
$InitialContext.attemptAnchor.runAttempt = 1
$InitialRequirements = New-FixtureRequirements
$InitialRequirements.jobs[0].artifactName = ('ci-receipt-native-9001-1-' + $script:FixtureNonce)
$InitialRequirements.jobs[1].artifactName = ('ci-receipt-quality-9001-1-' + $script:FixtureNonce)
$InitialActorMismatch = [pscustomobject][ordered]@{ id=9001;run_attempt=1;workflow_id=1234;event='pull_request';head_sha=$InitialContext.source.headRevision;status='in_progress';conclusion=$null;actor=[pscustomobject][ordered]@{login='wrong-actor';id=101};triggering_actor=[pscustomobject][ordered]@{login=$InitialContext.event.triggeringActor;id=102} }
$InitialActorApi = New-FixtureApi -Context $InitialContext -Requirements $InitialRequirements -Overrides @{ '/repos/ShayShimoni/aetheln-online/actions/runs/9001' = (ConvertTo-FixtureBytes $InitialActorMismatch) }
Assert-Rejected { New-CiAcceptanceAggregate -Context $InitialContext -Requirements $InitialRequirements -ApiRequest $InitialActorApi -DeadlineSeconds 30 } 'run_actor_mismatch'
$RerunTriggerMismatch = [pscustomobject][ordered]@{ id=9001;run_attempt=2;workflow_id=1234;event='pull_request';head_sha=$Context.source.headRevision;status='in_progress';conclusion=$null;actor=[pscustomobject][ordered]@{login=$Context.event.actor;id=101};triggering_actor=[pscustomobject][ordered]@{login='wrong-trigger';id=102} }
$RerunActorApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{ '/repos/ShayShimoni/aetheln-online/actions/runs/9001' = (ConvertTo-FixtureBytes $RerunTriggerMismatch) }
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $RerunActorApi -DeadlineSeconds 30 } 'run_actor_mismatch'

$Newer = [pscustomobject][ordered]@{ id = 9002; run_attempt = 1; workflow_id = 1234; event = 'pull_request'; head_sha = $Context.source.headRevision; status = 'in_progress'; conclusion = $null }
$NewerRuns = [pscustomobject][ordered]@{ total_count = 2; workflow_runs = @($Newer, [pscustomobject][ordered]@{id=9001;run_attempt=2;workflow_id=1234;event='pull_request';head_sha=$Context.source.headRevision;status='in_progress';conclusion=$null}) }
$RunsUri = '/repos/ShayShimoni/aetheln-online/actions/workflows/1234/runs?event=pull_request&head_sha=' + $Context.source.headRevision + '&per_page=100&page=1'
$NewerApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{ $RunsUri = (ConvertTo-FixtureBytes $NewerRuns) }
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $NewerApi -DeadlineSeconds 30 } 'newer_workflow_run_observed'

$AttemptJobsUri = '/repos/ShayShimoni/aetheln-online/actions/runs/9001/attempts/2/jobs?per_page=100&page=1'
$AllJobsUri = '/repos/ShayShimoni/aetheln-online/actions/runs/9001/jobs?filter=all&per_page=100&page=1'
$ArtifactsUri = '/repos/ShayShimoni/aetheln-online/actions/runs/9001/artifacts?per_page=100&page=1'
$SelectorJob = [pscustomobject][ordered]@{id=100;name='ci-selection-shadow';status='completed';conclusion='success';run_id=9001;head_sha=$Context.source.headRevision;run_attempt=2;started_at='2026-09-20T20:00:00Z';completed_at='2026-09-20T20:10:00Z';labels=[string[]]@('windows-latest');runner_id=10;runner_name='GitHub Actions 1'}
$NativeJob = [pscustomobject][ordered]@{id=301;name='trusted-candidate-compile';status='completed';conclusion='skipped';run_attempt=2}
$QualityJob = [pscustomobject][ordered]@{id=302;name='quality-gates';status='completed';conclusion='skipped';run_attempt=2}
$ProducerJobs = @($NativeJob,$QualityJob)
Assert-True ($null -ne (Get-CurrentApiJobInterval -Job $SelectorJob -Context $Context -ExpectedConclusion 'success')) 'A fully bound current selector job must expose a valid artifact interval.'
$SkippedTimestampQuirkJob=$SelectorJob|ConvertTo-Json -Depth 8|ConvertFrom-Json
$SkippedTimestampQuirkJob.name='quality-gates';$SkippedTimestampQuirkJob.conclusion='skipped';$SkippedTimestampQuirkJob.started_at='2026-09-20T16:44:46Z';$SkippedTimestampQuirkJob.completed_at='2026-09-20T16:44:45Z';$SkippedTimestampQuirkJob.runner_id=0;$SkippedTimestampQuirkJob.runner_name=$null
Assert-True ($null -ne (Get-CurrentApiJobInterval -Job $SkippedTimestampQuirkJob -Context $Context -ExpectedConclusion 'skipped')) 'An exact skipped job must tolerate GitHub reporting completed_at one second before started_at.'
foreach ($JobIdentityCase in @(
	@{name='run-id-string';mutate={param($x)$x.run_id='9001'}},
	@{name='wrong-head';mutate={param($x)$x.head_sha='9'*40}},
	@{name='attempt-string';mutate={param($x)$x.run_attempt='2'}},
	@{name='started-type';mutate={param($x)$x.started_at=1}},
	@{name='reverse-interval';mutate={param($x)$x.completed_at='2026-09-20T19:59:59Z'}},
	@{name='labels-scalar';mutate={param($x)$x.labels='windows-latest'}},
	@{name='labels-duplicate';mutate={param($x)$x.labels=[string[]]@('windows-latest','windows-latest')}},
	@{name='runner-id-zero';mutate={param($x)$x.runner_id=0}},
	@{name='runner-name-null';mutate={param($x)$x.runner_name=$null}}
)) {
	$BadJob=$SelectorJob|ConvertTo-Json -Depth 8|ConvertFrom-Json;& $JobIdentityCase.mutate $BadJob
	try { Assert-Rejected { Get-CurrentApiJobInterval -Job $BadJob -Context $Context -ExpectedConclusion 'success' } 'api_job_identity_invalid' }
	catch { throw "Aggregate job identity fixture '$($JobIdentityCase.name)' failed: $($_.Exception.Message)" }
}
$BoundNativeJob=$SelectorJob|ConvertTo-Json -Depth 8|ConvertFrom-Json
$BoundNativeJob.name='trusted-candidate-compile';$BoundNativeJob.labels=[string[]]@('self-hosted','Windows','X64','aetheln-engine');$BoundNativeJob.runner_name='fixture-runner'
Assert-True ($null -ne (Get-CurrentApiJobInterval -Job $BoundNativeJob -Context $Context -ExpectedConclusion 'success')) 'The native job must bind the exact managed runner labels.'
$BadNativeLabels=$BoundNativeJob|ConvertTo-Json -Depth 8|ConvertFrom-Json;$BadNativeLabels.labels=[string[]]@('self-hosted','Windows','X64')
Assert-Rejected { Get-CurrentApiJobInterval -Job $BadNativeLabels -Context $Context -ExpectedConclusion 'success' } 'native_job_labels_invalid'
$NativeRunnerBytes=ConvertTo-FixtureBytes (New-FixtureEngineReport $Context)
Assert-Rejected { Assert-EngineRunnerSemanticEvidence -Bytes $NativeRunnerBytes -Context $Context -ExpectedRunnerName 'different-runner' } 'receipt_semantic_evidence_invalid:native-client-server-compile'

$VisualArtifactSourceApi=New-FixtureApi -Context $Context -Requirements $Requirements -SelectedChecks @('visual-package')
$VisualArtifactListing=ConvertFrom-StrictBoundedJson -Bytes (& $VisualArtifactSourceApi $ArtifactsUri 30000 1048576)
$VisualReceiptArtifact=@($VisualArtifactListing.artifacts|Where-Object{$_.name -ceq $Requirements.jobs[1].artifactName})[0]
$ReplayedVisualReceiptArtifact=$VisualReceiptArtifact|ConvertTo-Json -Depth 8|ConvertFrom-Json
$ReplayedVisualReceiptArtifact.id=999;$ReplayedVisualReceiptArtifact.name='ci-receipt-quality-9001-2-' + ('7'*64)
$VisualArtifactListing.artifacts=@($VisualArtifactListing.artifacts)+@($ReplayedVisualReceiptArtifact);$VisualArtifactListing.total_count=$VisualArtifactListing.artifacts.Count
$DuplicateReceiptAnchorApi=New-FixtureApi -Context $Context -Requirements $Requirements -SelectedChecks @('visual-package') -Overrides @{$ArtifactsUri=(ConvertTo-FixtureBytes $VisualArtifactListing)}
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $DuplicateReceiptAnchorApi -DeadlineSeconds 30 } 'artifact_identity_ambiguous'

$UnselectedArtifactSourceApi=New-FixtureApi -Context $Context -Requirements $Requirements
$UnselectedArtifactListing=ConvertFrom-StrictBoundedJson -Bytes (& $UnselectedArtifactSourceApi $ArtifactsUri 30000 1048576)
$ReplayedUnselectedArtifact=$VisualReceiptArtifact|ConvertTo-Json -Depth 8|ConvertFrom-Json
$ReplayedUnselectedArtifact.id=998;$ReplayedUnselectedArtifact.name='ci-receipt-quality-9001-2-' + ('7'*64)
$UnselectedArtifactListing.artifacts=@($UnselectedArtifactListing.artifacts)+@($ReplayedUnselectedArtifact);$UnselectedArtifactListing.total_count=$UnselectedArtifactListing.artifacts.Count
$ReplayedUnselectedArtifactApi=New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{$ArtifactsUri=(ConvertTo-FixtureBytes $UnselectedArtifactListing)}
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $ReplayedUnselectedArtifactApi -DeadlineSeconds 30 } 'unselected_artifact_observed'

$MissingSelectorJobs = [pscustomobject][ordered]@{total_count=2;jobs=$ProducerJobs}
$MissingSelectorApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{$AttemptJobsUri=(ConvertTo-FixtureBytes $MissingSelectorJobs)}
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $MissingSelectorApi -DeadlineSeconds 30 } 'selector_job_identity_ambiguous'
$WrongNameSelectorJobs = [pscustomobject][ordered]@{total_count=3;jobs=@([pscustomobject][ordered]@{id=100;name='ci-selection-shadow-wrong';status='completed';conclusion='success';run_attempt=2},$NativeJob,$QualityJob)}
$WrongNameSelectorApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{$AttemptJobsUri=(ConvertTo-FixtureBytes $WrongNameSelectorJobs)}
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $WrongNameSelectorApi -DeadlineSeconds 30 } 'selector_job_identity_ambiguous'
$SkippedSelector = [pscustomobject][ordered]@{id=100;name='ci-selection-shadow';status='completed';conclusion='skipped';run_attempt=2}
$SkippedSelectorJobs = [pscustomobject][ordered]@{total_count=3;jobs=@($SkippedSelector,$NativeJob,$QualityJob)}
$SkippedSelectorApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{$AttemptJobsUri=(ConvertTo-FixtureBytes $SkippedSelectorJobs)}
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $SkippedSelectorApi -DeadlineSeconds 30 } 'selector_job_not_success'
$DuplicateSelectorJobs = [pscustomobject][ordered]@{total_count=4;jobs=@($SelectorJob,[pscustomobject][ordered]@{id=101;name='ci-selection-shadow';status='completed';conclusion='success';run_attempt=2},$NativeJob,$QualityJob)}
$DuplicateSelectorApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{$AttemptJobsUri=(ConvertTo-FixtureBytes $DuplicateSelectorJobs)}
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $DuplicateSelectorApi -DeadlineSeconds 30 } 'selector_job_identity_ambiguous'
$StaleSelector = [pscustomobject][ordered]@{id=100;name='ci-selection-shadow';status='completed';conclusion='success';run_attempt=1}
$StaleSelectorJobs = [pscustomobject][ordered]@{total_count=3;jobs=@($StaleSelector,$NativeJob,$QualityJob)}
$StaleSelectorApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{$AttemptJobsUri=(ConvertTo-FixtureBytes $StaleSelectorJobs)}
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $StaleSelectorApi -DeadlineSeconds 30 } 'selector_job_attempt_mismatch'
$NewerSelectorHistory = [pscustomobject][ordered]@{total_count=4;jobs=@($SelectorJob,[pscustomobject][ordered]@{id=99;name='ci-selection-shadow';status='completed';conclusion='success';run_attempt=3},$NativeJob,$QualityJob)}
$NewerSelectorHistoryApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{$AllJobsUri=(ConvertTo-FixtureBytes $NewerSelectorHistory)}
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $NewerSelectorHistoryApi -DeadlineSeconds 30 } 'newer_selector_attempt_observed'

$SelectorReportBytes = New-FixtureSelectorReportData -Context $Context
$SelectorArchiveBytes = New-FixtureZip @([pscustomobject]@{name='ci-selection-shadow.json';bytes=$SelectorReportBytes})
$SelectorUrl = 'https://api.fixture/artifacts/200/zip'
$SelectorArtifact = [pscustomobject][ordered]@{id=200;name=('ci-selection-shadow-9001-2-' + $script:FixtureNonce);size_in_bytes=$SelectorArchiveBytes.Length;archive_download_url=$SelectorUrl;expired=$false;created_at='2026-09-20T20:09:00Z';digest=('sha256:' + (Get-Sha256 $SelectorArchiveBytes));workflow_run=[pscustomobject][ordered]@{id=9001;head_sha=$Context.source.headRevision}}
$MissingSelectorArtifactApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{$ArtifactsUri=(ConvertTo-FixtureBytes ([pscustomobject][ordered]@{total_count=0;artifacts=@()}))}
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $MissingSelectorArtifactApi -DeadlineSeconds 30 } 'selector_artifact_identity_ambiguous'
$WrongNameSelectorArtifact = $SelectorArtifact | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$WrongNameSelectorArtifact.name = ('ci-selection-shadow-9001-1-' + $script:FixtureNonce)
$WrongNameSelectorArtifactApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{$ArtifactsUri=(ConvertTo-FixtureBytes ([pscustomobject][ordered]@{total_count=1;artifacts=@($WrongNameSelectorArtifact)}))}
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $WrongNameSelectorArtifactApi -DeadlineSeconds 30 } 'selector_artifact_identity_ambiguous'
$DuplicateSelectorArtifactApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{$ArtifactsUri=(ConvertTo-FixtureBytes ([pscustomobject][ordered]@{total_count=2;artifacts=@($SelectorArtifact,$SelectorArtifact)}))}
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $DuplicateSelectorArtifactApi -DeadlineSeconds 30 } 'selector_artifact_identity_ambiguous'
$WrongNonceSelectorArtifact = $SelectorArtifact | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$WrongNonceSelectorArtifact.id = 201
$WrongNonceSelectorArtifact.name = 'ci-selection-shadow-9001-2-' + ('7' * 64)
$DuplicateAnchorSelectorApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{$ArtifactsUri=(ConvertTo-FixtureBytes ([pscustomobject][ordered]@{total_count=2;artifacts=@($SelectorArtifact,$WrongNonceSelectorArtifact)}))}
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $DuplicateAnchorSelectorApi -DeadlineSeconds 30 } 'selector_artifact_identity_ambiguous'
foreach ($ArtifactProofCase in @(
	@{name='before-job';reason='selector_artifact_created_at_invalid';mutate={param($x)$x.created_at='2026-09-20T19:59:59Z'}},
	@{name='after-job';reason='selector_artifact_created_at_invalid';mutate={param($x)$x.created_at='2026-09-20T20:10:01Z'}},
	@{name='timestamp-type';reason='selector_artifact_created_at_invalid';mutate={param($x)$x.created_at=1}},
	@{name='digest-shape';reason='selector_artifact_digest_invalid';mutate={param($x)$x.digest='sha256:' + ('A' * 64)}},
	@{name='digest-trailing-lf';reason='selector_artifact_digest_invalid';mutate={param($x)$x.digest='sha256:' + ('8' * 64) + "`n"}},
	@{name='digest-mismatch';reason='selector_artifact_digest_mismatch';mutate={param($x)$x.digest='sha256:' + ('0' * 64)}}
)) {
	$BadProofArtifact=$SelectorArtifact|ConvertTo-Json -Depth 8|ConvertFrom-Json;& $ArtifactProofCase.mutate $BadProofArtifact
	$BadProofApi=New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{$ArtifactsUri=(ConvertTo-FixtureBytes ([pscustomobject][ordered]@{total_count=1;artifacts=@($BadProofArtifact)}))}
	if ($ArtifactProofCase.name -ceq 'digest-mismatch') { Set-FixtureSelectorBinding -Context $Context -Artifact $BadProofArtifact }
	try { Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $BadProofApi -DeadlineSeconds 30 } $ArtifactProofCase.reason }
	catch { throw "Aggregate artifact proof fixture '$($ArtifactProofCase.name)' failed: $($_.Exception.Message)" }
}
foreach ($ArtifactIdentityCase in @(
	@{name='wrong-run';mutate={param($x)$x.workflow_run.id=9002}},
	@{name='wrong-head';mutate={param($x)$x.workflow_run.head_sha=('9' * 40)}},
	@{name='expired';mutate={param($x)$x.expired=$true}}
)) {
	$BadSelectorArtifact = $SelectorArtifact | ConvertTo-Json -Depth 8 | ConvertFrom-Json
	& $ArtifactIdentityCase.mutate $BadSelectorArtifact
	$BadSelectorArtifactApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{$ArtifactsUri=(ConvertTo-FixtureBytes ([pscustomobject][ordered]@{total_count=1;artifacts=@($BadSelectorArtifact)}))}
	Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $BadSelectorArtifactApi -DeadlineSeconds 30 } 'selector_artifact_identity_mismatch'
}
$ExtraSelectorArchive = New-FixtureZip @([pscustomobject]@{name='ci-selection-shadow.json';bytes=$SelectorReportBytes},[pscustomobject]@{name='extra.txt';bytes='x'})
$ExtraSelectorArtifact = $SelectorArtifact | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$ExtraSelectorArtifact.size_in_bytes = $ExtraSelectorArchive.Length
$ExtraSelectorArtifact.digest = 'sha256:' + (Get-Sha256 $ExtraSelectorArchive)
$ExtraSelectorArchiveApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{$SelectorUrl=$ExtraSelectorArchive;$ArtifactsUri=(ConvertTo-FixtureBytes ([pscustomobject][ordered]@{total_count=1;artifacts=@($ExtraSelectorArtifact)}))}
Set-FixtureSelectorBinding -Context $Context -Artifact $ExtraSelectorArtifact
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $ExtraSelectorArchiveApi -DeadlineSeconds 30 } 'selector_archive_entries_invalid'
$WrongEntrySelectorArchive = New-FixtureZip @([pscustomobject]@{name='wrong.json';bytes=$SelectorReportBytes})
$WrongEntrySelectorArtifact = $SelectorArtifact | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$WrongEntrySelectorArtifact.size_in_bytes = $WrongEntrySelectorArchive.Length
$WrongEntrySelectorArtifact.digest = 'sha256:' + (Get-Sha256 $WrongEntrySelectorArchive)
$WrongEntrySelectorArchiveApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{$SelectorUrl=$WrongEntrySelectorArchive;$ArtifactsUri=(ConvertTo-FixtureBytes ([pscustomobject][ordered]@{total_count=1;artifacts=@($WrongEntrySelectorArtifact)}))}
Set-FixtureSelectorBinding -Context $Context -Artifact $WrongEntrySelectorArtifact
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $WrongEntrySelectorArchiveApi -DeadlineSeconds 30 } 'selector_archive_entries_invalid'
$BadSelectorReport = ConvertFrom-StrictBoundedJson -Bytes $SelectorReportBytes
$BadSelectorReport.execution.controllerSha256 = ('9' * 64)
$BadSelectorReportArchive = New-FixtureZip @([pscustomobject]@{name='ci-selection-shadow.json';bytes=(ConvertTo-FixtureBytes $BadSelectorReport)})
$BadSelectorReportArtifact = $SelectorArtifact | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$BadSelectorReportArtifact.size_in_bytes = $BadSelectorReportArchive.Length
$BadSelectorReportArtifact.digest = 'sha256:' + (Get-Sha256 $BadSelectorReportArchive)
$BadSelectorReportApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{$SelectorUrl=$BadSelectorReportArchive;$ArtifactsUri=(ConvertTo-FixtureBytes ([pscustomobject][ordered]@{total_count=1;artifacts=@($BadSelectorReportArtifact)}))}
Set-FixtureSelectorBinding -Context $Context -Artifact $BadSelectorReportArtifact
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $BadSelectorReportApi -DeadlineSeconds 30 } 'selector_evidence_report_invalid'
$BadSelectorDigest = ConvertFrom-StrictBoundedJson -Bytes $SelectorReportBytes
$BadSelectorDigest.policy.digest = ('8' * 64)
$BadSelectorDigestArchive = New-FixtureZip @([pscustomobject]@{name='ci-selection-shadow.json';bytes=(ConvertTo-FixtureBytes $BadSelectorDigest)})
$BadSelectorDigestArtifact = $SelectorArtifact | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$BadSelectorDigestArtifact.size_in_bytes = $BadSelectorDigestArchive.Length
$BadSelectorDigestArtifact.digest = 'sha256:' + (Get-Sha256 $BadSelectorDigestArchive)
$BadSelectorDigestApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{$SelectorUrl=$BadSelectorDigestArchive;$ArtifactsUri=(ConvertTo-FixtureBytes ([pscustomobject][ordered]@{total_count=1;artifacts=@($BadSelectorDigestArtifact)}))}
Set-FixtureSelectorBinding -Context $Context -Artifact $BadSelectorDigestArtifact
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $BadSelectorDigestApi -DeadlineSeconds 30 } 'selector_evidence_report_invalid'
$BadSelectorSource = ConvertFrom-StrictBoundedJson -Bytes $SelectorReportBytes
$BadSelectorSource.source.headRevision = ('7' * 40)
$BadSelectorSourceArchive = New-FixtureZip @([pscustomobject]@{name='ci-selection-shadow.json';bytes=(ConvertTo-FixtureBytes $BadSelectorSource)})
$BadSelectorSourceArtifact = $SelectorArtifact | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$BadSelectorSourceArtifact.size_in_bytes = $BadSelectorSourceArchive.Length
$BadSelectorSourceArtifact.digest = 'sha256:' + (Get-Sha256 $BadSelectorSourceArchive)
$BadSelectorSourceApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{$SelectorUrl=$BadSelectorSourceArchive;$ArtifactsUri=(ConvertTo-FixtureBytes ([pscustomobject][ordered]@{total_count=1;artifacts=@($BadSelectorSourceArtifact)}))}
Set-FixtureSelectorBinding -Context $Context -Artifact $BadSelectorSourceArtifact
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $BadSelectorSourceApi -DeadlineSeconds 30 } 'selector_evidence_report_invalid'
$VisualSelectorReportBytes = New-FixtureSelectorReportData -Context $Context -SelectedChecks @('visual-package')
$VisualSelectorArchiveBytes = New-FixtureZip @([pscustomobject]@{name='ci-selection-shadow.json';bytes=$VisualSelectorReportBytes})
$VisualSelectorArtifact = [pscustomobject][ordered]@{id=200;name=('ci-selection-shadow-9001-2-' + $script:FixtureNonce);size_in_bytes=$VisualSelectorArchiveBytes.Length;archive_download_url=$SelectorUrl;expired=$false;created_at='2026-09-20T20:09:00Z';digest=('sha256:' + (Get-Sha256 $VisualSelectorArchiveBytes));workflow_run=[pscustomobject][ordered]@{id=9001;head_sha=$Context.source.headRevision}}
$BadReceiptSizeArtifact = [pscustomobject][ordered]@{id=202;name=('ci-receipt-quality-9001-2-' + $script:FixtureNonce);size_in_bytes=1;archive_download_url='https://api.fixture/artifacts/202/zip';expired=$false;created_at='2026-09-20T20:09:00Z';digest=('sha256:' + ('0' * 64));workflow_run=[pscustomobject][ordered]@{id=9001;head_sha=$Context.source.headRevision}}
$BadReceiptSizeApi = New-FixtureApi -Context $Context -Requirements $Requirements -SelectedChecks @('visual-package') -Overrides @{$SelectorUrl=$VisualSelectorArchiveBytes;$ArtifactsUri=(ConvertTo-FixtureBytes ([pscustomobject][ordered]@{total_count=2;artifacts=@($VisualSelectorArtifact,$BadReceiptSizeArtifact)}))}
Set-FixtureSelectorBinding -Context $Context -Artifact $VisualSelectorArtifact
Set-FixtureProducerBinding -Context $Context -Key 'quality' -Artifact $BadReceiptSizeArtifact
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $BadReceiptSizeApi -DeadlineSeconds 30 } 'artifact_size_mismatch'

$PartialJobs = [pscustomobject][ordered]@{ total_count = 2; jobs = @($SelectorJob,[pscustomobject][ordered]@{id=101;name='quality-gates';status='completed';conclusion='success';run_attempt=2}) }
$PartialApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{ $AttemptJobsUri = (ConvertTo-FixtureBytes $PartialJobs) }
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $PartialApi -DeadlineSeconds 30 } 'partial_rerun_missing_job'

$FailedJobs = [pscustomobject][ordered]@{ total_count = 3; jobs = @($SelectorJob,[pscustomobject][ordered]@{id=101;name='quality-gates';status='completed';conclusion='failure';run_attempt=2},[pscustomobject][ordered]@{id=102;name='trusted-candidate-compile';status='completed';conclusion='success';run_attempt=2}) }
$FailedApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{ $AttemptJobsUri = (ConvertTo-FixtureBytes $FailedJobs) }
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $FailedApi -DeadlineSeconds 30 } 'job_conclusion_not_expected'

$MalformedHistory = [pscustomobject][ordered]@{ total_count = 3; jobs = @([pscustomobject][ordered]@{id=100;name='ci-selection-shadow';status='completed';conclusion='success';run_attempt=2},[pscustomobject][ordered]@{id=101;name='quality-gates';status='completed';conclusion='success';run_attempt='2'},[pscustomobject][ordered]@{id=102;name='trusted-candidate-compile';status='completed';conclusion='success';run_attempt=2}) }
$MalformedHistoryApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{ $AllJobsUri = (ConvertTo-FixtureBytes $MalformedHistory) }
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $MalformedHistoryApi -DeadlineSeconds 30 } 'api_job_schema_invalid'

$BadRequirement = New-FixtureRequirements
$BadRequirement.jobs[0].jobName = $BadRequirement.jobs[1].jobName
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $BadRequirement -ApiRequest (New-FixtureApi -Context $Context -Requirements $BadRequirement) -DeadlineSeconds 30 } 'requirements_identity_collision'
$RetiredRequirement = New-FixtureRequirements
$RetiredRequirement.jobs[1].checks += 'delivery-harness'
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $RetiredRequirement -ApiRequest (New-FixtureApi -Context $Context -Requirements $RetiredRequirement) -DeadlineSeconds 30 } 'requirements_check_invalid'
$ReservedSelectorJob = New-FixtureRequirements
$ReservedSelectorJob.jobs[0].jobName = 'ci-selection-shadow'
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $ReservedSelectorJob -ApiRequest (New-FixtureApi -Context $Context -Requirements $ReservedSelectorJob) -DeadlineSeconds 30 } 'requirements_selector_identity_reserved'
$ReservedSelectorArtifact = New-FixtureRequirements
$ReservedSelectorArtifact.jobs[0].artifactName = ('ci-selection-shadow-9001-2-' + $script:FixtureNonce)
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $ReservedSelectorArtifact -ApiRequest (New-FixtureApi -Context $Context -Requirements $ReservedSelectorArtifact) -DeadlineSeconds 30 } 'requirements_selector_identity_reserved'
$NonCanonicalReceiptArtifact = New-FixtureRequirements
$NonCanonicalReceiptArtifact.jobs[0].artifactName = 'ci-receipt-native-custom'
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $NonCanonicalReceiptArtifact -ApiRequest (New-FixtureApi -Context $Context -Requirements $NonCanonicalReceiptArtifact) -DeadlineSeconds 30 } 'requirements_artifact_name_invalid'


# Live run 36935862210 (PR #194) failed with api_response_type_invalid: the default bounded HTTP reader returned
# $Output.ToArray() without the unary comma, so PowerShell unrolled the byte[] into Object[] before the type guard.
# Fixture callbacks already return ,$Bytes, so only a live request exercised the defect. Keep the guard strict and
# pin the production reader to the comma form; a wrapper that unrolls the array must stay rejected.
$UnrolledFixture = { param([string]$Uri,[int]$Remaining,[int]$Maximum,[string]$Kind) $null = $Uri; $null = $Remaining; $null = $Maximum; $null = $Kind; return [byte[]](1,2,3) }
Assert-Rejected { Invoke-AggregateApi -ApiRequest $UnrolledFixture -Uri '/unrolled' -Clock ([Diagnostics.Stopwatch]::StartNew()) -DeadlineSeconds 30 -MaximumBytes 10 -Budget (New-AggregateBudget) -RequestKind Api } 'api_response_type_invalid'
$ReaderSource = [IO.File]::ReadAllText($SourceScript)
$ReaderStart = $ReaderSource.IndexOf('function Invoke-DefaultBoundedApiRequest', [StringComparison]::Ordinal)
$ReaderEnd = $ReaderSource.IndexOf('function Get-RemainingMilliseconds', [StringComparison]::Ordinal)
Assert-True ($ReaderStart -ge 0 -and $ReaderEnd -gt $ReaderStart) 'The default bounded API reader must remain a distinct function ahead of Get-RemainingMilliseconds.'
$ReaderBody = $ReaderSource.Substring($ReaderStart, $ReaderEnd - $ReaderStart)
Assert-True ($ReaderBody.Contains('return ,$Output.ToArray()') -and -not $ReaderBody.Contains('return $Output.ToArray()')) 'The default bounded API reader must return the response byte[] with the unary comma so the aggregate type guard receives a byte[] from live GitHub requests.'

Write-Output "PASS: $script:Assertions acceptance aggregate assertions"
