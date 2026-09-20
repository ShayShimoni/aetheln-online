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
	Assert-True (($Parsed.PSObject.Properties.Name -join ',') -ceq 'schemaVersion,repository,event,source,workflow,controller,policy,actions,run,selection,results,acceptance') 'Root receipt schema must be closed and ordered.'
	Assert-True ($Parsed.schemaVersion -ceq 'aetheln.ci-acceptance-receipt/v1') 'Receipt schema version should be exact.'
	Assert-True (($Parsed.workflow.PSObject.Properties.Name -join ',') -ceq 'id,revision,parents,sha256') 'Workflow schema must bind the API workflow identity and exact revision bytes.'
	Assert-True (($Parsed.actions.PSObject.Properties.Name -join ',') -ceq 'manifestSha256,items' -and ($Parsed.actions.items[0].PSObject.Properties.Name -join ',') -ceq 'uses,revision') 'Action schema must bind the deterministic full-SHA pin manifest.'
	Assert-True (($Parsed.results.checks[0].PSObject.Properties.Name -join ',') -ceq 'id,jobName,conclusion,nativeExitCode,infrastructureFailure,terminal,cleanupVerified,evidence') 'Result schema must bind native, infrastructure, terminal, cleanup, and evidence outcomes.'
	Assert-True (-not $Parsed.acceptance.authoritative -and -not $Parsed.acceptance.grantsAcceptance -and $Parsed.acceptance.shadow) 'Package 3A receipts must remain shadow-only and non-authoritative.'
	Assert-True ($Parsed.acceptance.terminal -and -not $Parsed.acceptance.infrastructureFailure -and $null -eq $Parsed.acceptance.cleanupVerified) 'A visual-only receipt should record terminal success without claiming native cleanup.'
	Assert-True ($Receipt.run.id -ceq '35533038331' -and $Receipt.run.attempt -eq 2) 'Run and attempt identity must round-trip exactly.'

	# The consumer must accept the producer's exact boundary output. This is a
	# real cross-script compatibility check, not two independent schema fixtures.
	. (Join-Path $RepositoryRoot 'scripts\ci\Invoke-CiAcceptanceAggregate.ps1')
	$ConsumerContext = [pscustomobject][ordered]@{
		schemaVersion = 'aetheln.ci-acceptance-context/v1'
		repository = $Parsed.repository; event = $Parsed.event; source = $Parsed.source; workflow = $Parsed.workflow
		actions = $Parsed.actions; controller = $Parsed.controller; policy = $Parsed.policy; run = $Parsed.run
	}
	$ConsumerRequirement = [pscustomobject][ordered]@{
		key = 'visual'; jobName = 'visual-package-proof'; selected = $true
		artifactName = 'ci-receipt-visual-35533038331-2'; checks = @('visual-package')
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
		@{ name='uppercase-policy'; action={ param($x) $x.policy.version = 'Shadow-v1' } },
		@{ name='invalid-actor'; action={ param($x) $x.event.triggeringActor = 'bad actor' } },
		@{ name='duplicate-selection'; action={ param($x) $x.selection.checks = @('visual-package','visual-package') } },
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

	foreach ($UnsupportedId in @('clean-package-provenance-smoke','content-reference-validation','controller-contract','controller-operational-proof','delivery-harness','native-client-server-compile','portable','unreal-editor-automation')) {
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
