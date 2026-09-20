$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SourceScript = Join-Path $RepositoryRoot 'scripts/ci/Invoke-CiAcceptanceAggregate.ps1'
. $SourceScript
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:Assertions = 0
$script:Utf8 = New-Object System.Text.UTF8Encoding($false, $true)

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
	return [pscustomobject][ordered]@{
		schemaVersion = 'aetheln.ci-acceptance-context/v1'
		repository = [pscustomobject][ordered]@{ fullName = 'ShayShimoni/aetheln-online' }
		event = [pscustomobject][ordered]@{ kind = $Kind; classification = $Classification; actor = 'dependabot[bot]'; triggeringActor = 'github-actions[bot]' }
		source = [pscustomobject][ordered]@{ baseRevision = ('a' * 40); headRevision = ('b' * 40); testedRevision = ('c' * 40) }
		workflow = [pscustomobject][ordered]@{ id = '1234'; revision = ('c' * 40); parents = @(('a' * 40), ('b' * 40)); sha256 = ('1' * 64) }
		actions = New-FixtureActions
		controller = [pscustomobject][ordered]@{ revision = ('a' * 40); blobOid = ('e' * 40); sha256 = ('2' * 64) }
		policy = [pscustomobject][ordered]@{ version = 'shadow-v1'; digest = ('3' * 64) }
		run = [pscustomobject][ordered]@{ id = '9001'; attempt = 2 }
	}
}

function New-FixtureRequirements {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory fixture.')]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function returns the complete requirements fixture.')]
	param()
	return [pscustomobject][ordered]@{
		schemaVersion = 'aetheln.ci-acceptance-requirements/v1'
		jobs = @(
			[pscustomobject][ordered]@{ key = 'native'; jobName = 'trusted-candidate-compile'; selected = $false; artifactName = 'ci-receipt-native-9001-2'; checks = @('clean-package-provenance-smoke','native-client-server-compile') },
			[pscustomobject][ordered]@{ key = 'quality'; jobName = 'quality-gates'; selected = $false; artifactName = 'ci-receipt-quality-9001-2'; checks = @('content-reference-validation','controller-contract','controller-operational-proof','delivery-harness','portable','unreal-editor-automation','visual-package') }
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

function New-FixtureReceipt {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory fixture.')]
	param($Context, $Requirement, [byte[]] $EvidenceBytes = $script:Utf8.GetBytes('raw-proof'))
	$Results = @($Requirement.checks | ForEach-Object {
		$RequiresNativeProof = $_ -cin @('clean-package-provenance-smoke','native-client-server-compile')
		$EvidenceName = if ($_ -ceq 'visual-package') { 'visual-package-report.json' } else { 'evidence/' + $_ + '.json' }
		[pscustomobject][ordered]@{
			id = [string] $_; jobName = [string] $Requirement.jobName; conclusion = 'success'; nativeExitCode = if ($RequiresNativeProof) { 0 } else { $null }
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
	$Requirement = [pscustomobject][ordered]@{ key='visual';jobName='visual-package-proof';selected=$true;artifactName='ci-receipt-visual-9001-2';checks=@('visual-package') }
	$Receipt = New-FixtureReceipt -Context $Context -Requirement $Requirement -EvidenceBytes $EvidenceBytes
	$ReceiptBytes = ConvertTo-FixtureBytes $Receipt
	$Archive = [pscustomobject][ordered]@{ entries=@(
		[pscustomobject][ordered]@{name='ci-acceptance-receipt.json';bytes=$ReceiptBytes;sizeBytes=[long]$ReceiptBytes.Length;sha256=(Get-Sha256 $ReceiptBytes)},
		[pscustomobject][ordered]@{name='visual-package-report.json';bytes=$EvidenceBytes;sizeBytes=[long]$EvidenceBytes.Length;sha256=(Get-Sha256 $EvidenceBytes)}
	) }
	return [pscustomobject][ordered]@{ requirement=$Requirement;receipt=$Receipt;archive=$Archive }
}

function New-FixtureApi {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The function constructs an in-memory API fixture.')]
	param(
		$Context,
		$Requirements,
		[hashtable] $Overrides = @{}
	)
	$Run = [pscustomobject][ordered]@{ id = 9001; run_attempt = 2; workflow_id = 1234; event = $Context.event.kind; head_sha = $Context.source.headRevision; status = 'in_progress'; conclusion = $null }
	$WorkflowRuns = [pscustomobject][ordered]@{ total_count = 1; workflow_runs = @($Run) }
	$Jobs = New-Object System.Collections.Generic.List[object]
	$Artifacts = New-Object System.Collections.Generic.List[object]
	$Archives = @{}
	$ArtifactId = 200
	foreach ($Requirement in $Requirements.jobs) {
		$ArtifactId++
		$Conclusion = if ($Requirement.selected) { 'success' } else { 'skipped' }
		$Jobs.Add([pscustomobject][ordered]@{ id = 100 + $ArtifactId; name = $Requirement.jobName; status = 'completed'; conclusion = $Conclusion; run_attempt = 2 })
		if (-not $Requirement.selected) { continue }
		$Evidence = $script:Utf8.GetBytes('raw-proof')
		$Receipt = New-FixtureReceipt -Context $Context -Requirement $Requirement -EvidenceBytes $Evidence
		$ArchiveEntries = New-Object System.Collections.Generic.List[object]
		$ArchiveEntries.Add([pscustomobject]@{ name = 'ci-acceptance-receipt.json'; bytes = (ConvertTo-FixtureBytes $Receipt) })
		foreach ($Result in $Receipt.results.checks) { $ArchiveEntries.Add([pscustomobject]@{ name = $Result.evidence[0].name; bytes = $Evidence }) }
		$Archive = New-FixtureZip $ArchiveEntries.ToArray()
		$Url = "https://api.fixture/artifacts/$ArtifactId/zip"
		$Archives[$Url] = $Archive
		$Artifacts.Add([pscustomobject][ordered]@{ id = $ArtifactId; name = $Requirement.artifactName; size_in_bytes = $Archive.Length; archive_download_url = $Url; expired = $false; workflow_run = [pscustomobject][ordered]@{ id = 9001; head_sha = $Context.source.headRevision } })
	}
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
$Api = New-FixtureApi -Context $Context -Requirements $Requirements
$Aggregate = New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $Api -DeadlineSeconds 30
Assert-True ($Aggregate.schemaVersion -ceq 'aetheln.ci-acceptance-aggregate/v1') 'Aggregate schema identity changed.'
Assert-True ($Aggregate.decision.shadow -and -not $Aggregate.decision.authoritative -and -not $Aggregate.decision.grantsAcceptance) 'Aggregate must remain shadow-only and non-authoritative.'
Assert-True ($Aggregate.decision.evidenceClass -ceq 'pull_request_acceptance_candidate' -and $Aggregate.decision.complete) 'Complete PR evidence must remain only a candidate observation.'
Assert-True (@($Aggregate.receipts).Count -eq 0 -and @($Aggregate.jobs | Where-Object { -not $_.selected -and $_.conclusion -ceq 'skipped' }).Count -eq 2) 'Unsupported obligations must remain unselected and emit no opaque receipts.'

$VisualBoundary = New-FixtureVisualBoundary -Context $Context
$VisualResults = @(Assert-CiAcceptanceReceipt -Receipt $VisualBoundary.receipt -Context $Context -Requirement $VisualBoundary.requirement -Archive $VisualBoundary.archive)
Assert-True ($VisualResults.Count -eq 1 -and @($VisualResults[0]).Count -eq 1) 'The aggregate must accept exact, identity-bound visual semantic evidence.'
$VisualExitLie = New-FixtureVisualBoundary -Context $Context
$VisualExitLie.receipt.results.checks[0].nativeExitCode = 0
Assert-Rejected { Assert-CiAcceptanceReceipt -Receipt $VisualExitLie.receipt -Context $Context -Requirement $VisualExitLie.requirement -Archive $VisualExitLie.archive } 'receipt_semantic_evidence_invalid:visual-package'
$VisualCleanupLie = New-FixtureVisualBoundary -Context $Context
$VisualCleanupLie.receipt.results.checks[0].cleanupVerified = $true
Assert-Rejected { Assert-CiAcceptanceReceipt -Receipt $VisualCleanupLie.receipt -Context $Context -Requirement $VisualCleanupLie.requirement -Archive $VisualCleanupLie.archive } 'receipt_semantic_evidence_invalid:visual-package'
$VisualAcceptanceCleanupLie = New-FixtureVisualBoundary -Context $Context
$VisualAcceptanceCleanupLie.receipt.acceptance.cleanupVerified = $true
Assert-Rejected { Assert-CiAcceptanceReceipt -Receipt $VisualAcceptanceCleanupLie.receipt -Context $Context -Requirement $VisualAcceptanceCleanupLie.requirement -Archive $VisualAcceptanceCleanupLie.archive } 'receipt_cleanup_invalid'

foreach ($UnsupportedId in @('clean-package-provenance-smoke','content-reference-validation','controller-contract','controller-operational-proof','delivery-harness','native-client-server-compile','portable','unreal-editor-automation')) {
	$UnsupportedRequirement = [pscustomobject][ordered]@{key='unsupported';jobName='unsupported-proof';selected=$true;artifactName='ci-receipt-unsupported-9001-2';checks=@($UnsupportedId)}
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
$PushRequirements.jobs[0].selected = $false
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

$ReceiptBytes = ConvertTo-FixtureBytes (New-FixtureReceipt -Context $Context -Requirement $Requirements.jobs[0])
$DuplicateArchive = New-FixtureZip @([pscustomobject]@{name='ci-acceptance-receipt.json';bytes=$ReceiptBytes},[pscustomobject]@{name='ci-acceptance-receipt.json';bytes=$ReceiptBytes})
Assert-Rejected { Read-StrictCiArchive -Bytes $DuplicateArchive } 'archive_path_collision'
$TraversalArchive = New-FixtureZip @([pscustomobject]@{name='../receipt.json';bytes='x'})
Assert-Rejected { Read-StrictCiArchive -Bytes $TraversalArchive } 'archive_path_invalid'
$CaseArchive = New-FixtureZip @([pscustomobject]@{name='Evidence/raw.json';bytes='x'},[pscustomobject]@{name='evidence/RAW.json';bytes='x'})
Assert-Rejected { Read-StrictCiArchive -Bytes $CaseArchive } 'archive_path_collision'
$LinkArchive = New-FixtureZip @([pscustomobject]@{name='link';bytes='target';externalAttributes=[int]0xA1FF0000})
Assert-Rejected { Read-StrictCiArchive -Bytes $LinkArchive } 'archive_link_rejected'
$BombArchive = New-FixtureZip @([pscustomobject]@{name='evidence/bomb.txt';bytes=('z' * 200000)})
Assert-Rejected { Read-StrictCiArchive -Bytes $BombArchive -MaximumCompressionRatio 10 } 'archive_compression_ratio_limit'
$ExpandedArchive = New-FixtureZip @([pscustomobject]@{name='evidence/a.txt';bytes=('a' * 100)},[pscustomobject]@{name='evidence/b.txt';bytes=('b' * 100)})
Assert-Rejected { Read-StrictCiArchive -Bytes $ExpandedArchive -MaximumExpandedBytes 150 -MaximumCompressionRatio 1000 } 'archive_expanded_size_limit'
$OversizedEntryArchive = New-FixtureZip @([pscustomobject]@{name='evidence/oversized.bin';bytes=(New-Object byte[] (4MB + 1))})
Assert-Rejected { Read-StrictCiArchive -Bytes $OversizedEntryArchive -MaximumCompressionRatio 100000 } 'archive_entry_size_limit'
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

$StaleRun = [pscustomobject][ordered]@{ id = 9001; run_attempt = 3; workflow_id = 1234; event = 'pull_request'; head_sha = $Context.source.headRevision; status = 'in_progress'; conclusion = $null }
$StaleApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{ '/repos/ShayShimoni/aetheln-online/actions/runs/9001' = (ConvertTo-FixtureBytes $StaleRun) }
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $StaleApi -DeadlineSeconds 30 } 'run_attempt_stale'

$Newer = [pscustomobject][ordered]@{ id = 9002; run_attempt = 1; workflow_id = 1234; event = 'pull_request'; head_sha = $Context.source.headRevision; status = 'in_progress'; conclusion = $null }
$NewerRuns = [pscustomobject][ordered]@{ total_count = 2; workflow_runs = @($Newer, [pscustomobject][ordered]@{id=9001;run_attempt=2;workflow_id=1234;event='pull_request';head_sha=$Context.source.headRevision;status='in_progress';conclusion=$null}) }
$RunsUri = '/repos/ShayShimoni/aetheln-online/actions/workflows/1234/runs?event=pull_request&head_sha=' + $Context.source.headRevision + '&per_page=100&page=1'
$NewerApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{ $RunsUri = (ConvertTo-FixtureBytes $NewerRuns) }
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $NewerApi -DeadlineSeconds 30 } 'newer_workflow_run_observed'

$PartialJobs = [pscustomobject][ordered]@{ total_count = 1; jobs = @([pscustomobject][ordered]@{id=101;name='quality-gates';status='completed';conclusion='success';run_attempt=2}) }
$AttemptJobsUri = '/repos/ShayShimoni/aetheln-online/actions/runs/9001/attempts/2/jobs?per_page=100&page=1'
$PartialApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{ $AttemptJobsUri = (ConvertTo-FixtureBytes $PartialJobs) }
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $PartialApi -DeadlineSeconds 30 } 'partial_rerun_missing_job'

$FailedJobs = [pscustomobject][ordered]@{ total_count = 2; jobs = @([pscustomobject][ordered]@{id=101;name='quality-gates';status='completed';conclusion='failure';run_attempt=2},[pscustomobject][ordered]@{id=102;name='trusted-candidate-compile';status='completed';conclusion='success';run_attempt=2}) }
$FailedApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{ $AttemptJobsUri = (ConvertTo-FixtureBytes $FailedJobs) }
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $FailedApi -DeadlineSeconds 30 } 'job_conclusion_not_expected'

$AllJobsUri = '/repos/ShayShimoni/aetheln-online/actions/runs/9001/jobs?filter=all&per_page=100&page=1'
$MalformedHistory = [pscustomobject][ordered]@{ total_count = 2; jobs = @([pscustomobject][ordered]@{id=101;name='quality-gates';status='completed';conclusion='success';run_attempt='2'},[pscustomobject][ordered]@{id=102;name='trusted-candidate-compile';status='completed';conclusion='success';run_attempt=2}) }
$MalformedHistoryApi = New-FixtureApi -Context $Context -Requirements $Requirements -Overrides @{ $AllJobsUri = (ConvertTo-FixtureBytes $MalformedHistory) }
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $Requirements -ApiRequest $MalformedHistoryApi -DeadlineSeconds 30 } 'api_job_schema_invalid'

$BadRequirement = New-FixtureRequirements
$BadRequirement.jobs[0].artifactName = $BadRequirement.jobs[1].artifactName
Assert-Rejected { New-CiAcceptanceAggregate -Context $Context -Requirements $BadRequirement -ApiRequest (New-FixtureApi -Context $Context -Requirements $BadRequirement) -DeadlineSeconds 30 } 'requirements_identity_collision'

Write-Output "PASS: $script:Assertions acceptance aggregate assertions"
