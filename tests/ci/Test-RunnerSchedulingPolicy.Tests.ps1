[CmdletBinding()]
param()

# Sole purpose: validate the Issue #150 engine-runner scheduling contract:
# bounded schedule-only milestone phases that start only after the portable
# gates pass, FIFO queueing that cannot cancel pending or in-progress work,
# recorded trusted-compile queue-delay policy, trusted compile gated behind both
# the portable gates and the change-impact classifier, evidence separation per
# phase, and the absence of any manual or monolithic package/smoke entry point
# on that workflow. Issue #226 adds the pins for the separate, dispatch-only
# release workflow (TA-022) and the repository-wide workflow allowlists.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Workflow = Get-Content -LiteralPath (Join-Path $RepositoryRoot '.github\workflows\prototype-quality-gates.yml') -Raw
$VisualWorkflow = Get-Content -LiteralPath (Join-Path $RepositoryRoot '.github\workflows\visual-package-validation.yml') -Raw
$DeliveryWorkflow = Get-Content -LiteralPath (Join-Path $RepositoryRoot '.github\workflows\delivery-policy.yml') -Raw
$CiDocumentation = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'docs\continuous-integration.md') -Raw
$CheckoutAction = 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'
$DownloadAction = 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093'
$UploadAction = 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-MatchCount([string] $Text, [string] $Pattern, [int] $Expected, [string] $Message) {
	$Actual = [regex]::Matches($Text, $Pattern).Count
	Assert-True ($Actual -eq $Expected) "$Message Expected $Expected match(es), found $Actual."
}

$JobOrder = @('ci-selection-shadow', 'quality-gates', 'change-impact', 'trusted-candidate-compile', 'trusted-editor-automation', 'scheduled-client-package', 'scheduled-server-package', 'scheduled-provenance-validation', 'scheduled-packaged-smoke', 'visual-proof', 'portable-receipt-shadow', 'native-receipt-shadow', 'unreal-receipt-shadow', 'visual-receipt-shadow', 'ci-acceptance-shadow', 'ci-acceptance-authority')
$JobBodies = @{}
for ($Index = 1; $Index -lt $JobOrder.Count; $Index++) {
	$Start = $Workflow.IndexOf("  $($JobOrder[$Index - 1]):", [StringComparison]::Ordinal)
	$End = $Workflow.IndexOf("  $($JobOrder[$Index]):", [StringComparison]::Ordinal)
	Assert-True ($Start -ge 0 -and $End -gt $Start) "Workflow must define job '$($JobOrder[$Index - 1])' before '$($JobOrder[$Index])'."
	$JobBodies[$JobOrder[$Index - 1]] = $Workflow.Substring($Start, $End - $Start)
}
$JobBodies['ci-acceptance-authority'] = $Workflow.Substring($Workflow.IndexOf('  ci-acceptance-authority:', [StringComparison]::Ordinal))

$ReleaseWorkflowPath = Join-Path $RepositoryRoot '.github\workflows\release-packaging.yml'
Assert-True (Test-Path -LiteralPath $ReleaseWorkflowPath -PathType Leaf) 'The dispatch-only release packaging workflow must exist (TA-022).'
$ReleaseWorkflow = Get-Content -LiteralPath $ReleaseWorkflowPath -Raw

$AllowedRemoteActions = @($CheckoutAction, $DownloadAction, $UploadAction)
foreach ($WorkflowSource in @($Workflow, $VisualWorkflow, $DeliveryWorkflow, $ReleaseWorkflow)) {
	foreach ($ActionUse in @([regex]::Matches($WorkflowSource, '(?m)^\s+(?:- )?uses: (?<action>actions/[^@\s]+@[^\s]+)\r?$'))) {
		$Identity = [string] $ActionUse.Groups['action'].Value
		Assert-True ($Identity -cin $AllowedRemoteActions) "Remote action '$Identity' must belong to the reviewed checkout/download/upload allowlist."
		Assert-True ($Identity -cmatch '^actions/[a-z0-9-]+@[0-9a-f]{40}$') "Remote action '$Identity' must be pinned to one full lowercase commit SHA."
	}
}
# Issue #214: the delivery-policy job is hosted, read-only, and bounded; it
# never targets or queues behind the engine runner.
Assert-True ($DeliveryWorkflow -match '(?m)^    runs-on: windows-latest\r?$' -and $DeliveryWorkflow -match '(?m)^    timeout-minutes: 5\r?$' -and $DeliveryWorkflow -match '(?m)^permissions:\r?\n  contents: read\r?$' -and $DeliveryWorkflow -notmatch 'self-hosted|aetheln-engine|concurrency:|schedule:|workflow_dispatch') 'The delivery-policy workflow must stay a bounded, read-only, hosted pull-request job outside engine scheduling.'
Assert-MatchCount -Text $Workflow -Pattern ('(?m)^\s+uses: ' + [regex]::Escape($DownloadAction) + '\r?$') -Expected 10 -Message 'Downloader use must be limited to eight receipt inputs, aggregate selector, and dormant authority aggregate.'
foreach ($OutputName in @('report_artifact_id','report_artifact_name','report_artifact_digest','report_sha256','report_size_bytes')) {
	$CallBinding = [regex]::Escape('${{ jobs.validate.outputs.' + $OutputName + ' }}')
	Assert-True ($VisualWorkflow -match "(?ms)^      ${OutputName}:\r?\n        description:.*?\r?\n        value: $CallBinding\r?$" -and [regex]::Matches($VisualWorkflow, "(?m)^      ${OutputName}: ").Count -eq 1) "Reusable visual validation must expose raw report binding '$OutputName' through both output layers."
}

# No manual entry point exists on this workflow identity. Keeping a
# workflow_dispatch trigger would let an operator select an older branch that
# still carries the retired 1,440-minute PackagedSmoke job; the four phases are
# therefore schedule-only, and the monolithic gate is unreachable.
Assert-True ($Workflow -notmatch 'workflow_dispatch') 'Workflow must not declare or reference workflow_dispatch anywhere.'
Assert-True ($Workflow -match "(?m)^on:\r?\n  pull_request:\r?\n  push:\r?\n    branches:\r?\n      - develop\r?\n  schedule:\r?\n    - cron: '0 2 \* \* \*'\r?\n\r?\n") 'Workflow events must be exactly pull_request, push to develop, and the daily schedule.'
Assert-True ($Workflow -notmatch 'manual-packaged-smoke') 'Workflow must not define the retired manual-packaged-smoke job.'
Assert-True ($Workflow -notmatch 'engine-runner-manual-smoke-report') 'Workflow must not publish the retired manual smoke artifact.'
Assert-True ($Workflow -notmatch '-Mode PackagedSmoke') 'Workflow must not select the monolithic PackagedSmoke gate anywhere.'
Assert-MatchCount -Text $Workflow -Pattern 'timeout-minutes:\s*1440' -Expected 0 -Message 'No job may hold the engine runner for a 24-hour bound.'
Assert-MatchCount -Text $Workflow -Pattern '(?m)^\s+runs-on: \[self-hosted, Windows, X64, aetheln-engine\]\r?$' -Expected 6 -Message 'Exactly six jobs (trusted compile, trusted editor automation, and four phases) may target the engine runner.'
Assert-MatchCount -Text $Workflow -Pattern '(?m)^\s+runs-on: windows-latest\r?$' -Expected 9 -Message 'Exactly selector, portable gates, classifier, four receipt publishers, aggregate, and dormant authority run on GitHub-hosted Windows.'

# Every engine-runner concurrency block queues FIFO without cancelling pending
# or in-progress work. queue: single would silently cancel a pending trusted
# compile; cancel-in-progress: true would cancel healthy milestone work.
Assert-MatchCount -Text $Workflow -Pattern '(?m)^\s+group: aetheln-engine-runner\r?$' -Expected 6 -Message 'Exactly six jobs must share the engine-runner concurrency group.'
Assert-MatchCount -Text $Workflow -Pattern '(?m)^\s+queue: max\r?$' -Expected 6 -Message 'Every engine-runner concurrency block must use queue: max so pending jobs wait FIFO instead of being replaced.'
Assert-MatchCount -Text $Workflow -Pattern '(?m)^\s+cancel-in-progress: false\r?$' -Expected 6 -Message 'Every engine-runner concurrency block must keep cancel-in-progress: false.'
Assert-True ($Workflow -notmatch '(?m)^\s+cancel-in-progress: true\r?$') 'No engine job may cancel in-progress work.'

# No authoritative job-level predicate may silently skip after a failed,
# cancelled, or skipped prerequisite. The additive hosted aggregate always
# diagnoses every dependency conclusion. The dormant authority boundary also
# uses always() so an activated version fails red instead of becoming a skipped
# required check when its aggregate dependency is not successful.
Assert-True ($Workflow -notmatch 'cancelled\(\)' -and $Workflow -notmatch 'failure\(\)' -and $Workflow -notmatch 'success\(\)') 'Workflow must not use explicit status functions in job predicates.'
Assert-MatchCount -Text $Workflow -Pattern '(?m)^    if: always\(\)(?: && github\.event_name == ''pull_request'' && false)?\r?$' -Expected 2 -Message 'Only aggregate diagnosis and the dormant fail-closed authority boundary may bypass implicit success propagation.'
Assert-True (([string] $JobBodies['ci-acceptance-shadow']) -match '(?m)^    if: always\(\)\r?$') 'The live aggregate must retain its diagnostic always() predicate.'
Assert-True (([string] $JobBodies['ci-acceptance-authority']) -match "(?m)^    if: always\(\) && github\.event_name == 'pull_request' && false\r?$") 'The dormant authority boundary must evaluate failed or cancelled aggregate dependencies while remaining unreachable.'
foreach ($JobName in $JobOrder | Where-Object { $_ -notin @('ci-acceptance-shadow', 'ci-acceptance-authority') }) {
	Assert-True (([string] $JobBodies[$JobName]) -notmatch '(?m)^    if: always\(\)') "$JobName must not bypass prerequisite status with job-level always()."
}
$NeedsResultsOutsideEvidenceBoundaries = ($JobOrder | Where-Object { $_ -notin @('ci-acceptance-shadow', 'ci-acceptance-authority') } | ForEach-Object { [string] $JobBodies[$_] }) -join "`n"
Assert-True ($NeedsResultsOutsideEvidenceBoundaries -notmatch 'needs\.[a-z-]+\.result') 'Only the aggregate and dormant authority boundary may inspect dependency conclusions; no producer job may bypass normal prerequisite propagation.'
Assert-MatchCount -Text ([string] $JobBodies['ci-acceptance-shadow']) -Pattern 'needs\.(?:portable|native|unreal|visual)-receipt-shadow\.result' -Expected 4 -Message 'The aggregate must inspect exactly the four receipt publisher conclusions.'

# GitHub-hosted jobs carry explicit conservative bounds.
Assert-True (([string] $JobBodies['quality-gates']) -match '(?m)^\s+timeout-minutes: 30\r?$') 'quality-gates must declare an explicit 30-minute bound.'
Assert-True (([string] $JobBodies['change-impact']) -match '(?m)^\s+timeout-minutes: 10\r?$') 'change-impact must declare an explicit 10-minute bound.'
Assert-True (([string] $JobBodies['change-impact']) -match "(?m)^\s+if: github\.event_name == 'pull_request'\r?$") 'change-impact must run only for pull requests.'
Assert-True (([string] $JobBodies['change-impact']) -notmatch 'aetheln-engine-runner') 'change-impact must never hold the engine-runner concurrency group.'
$ShadowSelection = [string] $JobBodies['ci-selection-shadow']
Assert-True ($ShadowSelection -match "(?m)^\s+if: github\.event_name == 'pull_request'\r?$" -and $ShadowSelection -match '(?m)^\s+timeout-minutes: 10\r?$') 'Shadow selection must be pull-request-only and bounded to ten minutes.'
Assert-True ($ShadowSelection -match '(?m)^\s+continue-on-error: true\r?$') 'The selector itself must not control legacy job selection; dependent Package 3C evidence validation may still fail red.'
Assert-True ($ShadowSelection -notmatch '(?m)^\s+needs:' -and $ShadowSelection -notmatch 'self-hosted|aetheln-engine-runner') 'Shadow selection must have no predecessor or engine-runner admission surface.'
$ExpectedSelectorOutputs = @(
	'accepted_base_sha','attempt_nonce','aggregate_ready','clean_package_provenance_smoke_required','content_reference_validation_required',
	'controller_contract_required','controller_operational_proof_required',
	'native_client_server_compile_required','portable_required','unreal_editor_automation_required','visual_package_required',
	'selector_artifact_id','selector_artifact_name','selector_artifact_digest'
)
foreach ($OutputName in $ExpectedSelectorOutputs) {
	Assert-True ($ShadowSelection -match "(?m)^      ${OutputName}: ") "Shadow selection must expose Package 3C output '$OutputName'."
}
Assert-MatchCount -Text $ShadowSelection -Pattern '(?m)^      [a-z_]+: ' -Expected $ExpectedSelectorOutputs.Count -Message 'Shadow selection must expose only the reviewed Package 3C outputs.'
Assert-True ($ShadowSelection -match 'accepted_controller_unavailable' -and $ShadowSelection -match 'authoritative = \$false' -and $ShadowSelection -match 'checkoutAllowed = \$false') 'Bootstrap evidence must fail closed without pretending to be equivalence evidence.'
Assert-True ($ShadowSelection -match 'RandomNumberGenerator\]::Create\(\)' -and $ShadowSelection -match 'attemptAnchor = \[ordered\]@\{' -and $ShadowSelection -match "schemaVersion = 'aetheln\.current-attempt-anchor/v1'") 'The unavailable-controller fallback must still bind a fresh CSPRNG current-attempt anchor.'
Assert-True ($ShadowSelection -match "runId = '\$\{\{ github\.run_id \}\}'" -and $ShadowSelection -match "runAttempt = \[int\] '\$\{\{ github\.run_attempt \}\}'") 'Shadow selection must pass canonical run and attempt fields to the accepted-base selector.'
Assert-True ($ShadowSelection -match 'Assert-CurrentAttemptAnchor -Anchor \$Parsed\.attemptAnchor' -and $ShadowSelection -match 'attempt_nonce=\$AttemptNonce') 'Shadow selection must validate the current-attempt anchor before exposing its nonce.'
Assert-True ($ShadowSelection -match '(?m)^        id: selector_artifact\r?$' -and $ShadowSelection -match 'name: \$\{\{ steps\.selection\.outputs\.selector_artifact_name \}\}' -and $ShadowSelection -notmatch 'retention-days:') 'Shadow evidence must expose the direct artifact binding and use default retention.'
Assert-True ($ShadowSelection -match 'path: \$\{\{ runner\.temp \}\}/ci-selection-shadow\.json' -and $ShadowSelection -notmatch '(?m)^\s+path: .*\*') 'Shadow selection must upload exactly one bounded report file.'
Assert-True ($ShadowSelection -notmatch '(?m)^\s+if: always\(\)\r?$') 'A failed selector or anchor validator must not publish an invalid nonce-less selector artifact.'

# Package 3C adds four truthful receipt publishers and a hosted reconciler.
# Selection remains additive: every publisher is PR-only, bounded, directly
# downloads the selector and one raw producer by upload ID, and has no engine
# admission. Unsupported selected checks produce a green no-acceptance gap;
# the supported subset runs the real shadow aggregate and failures stay red.
$ReceiptContracts = @(
	@{ Job='portable-receipt-shadow'; Producer='quality-gates'; Predicate="needs\.ci-selection-shadow\.outputs\.portable_required == 'true'"; Key='portable'; ArtifactOutput='report_artifact_id' },
	@{ Job='native-receipt-shadow'; Producer='trusted-candidate-compile'; Predicate="\(needs\.ci-selection-shadow\.outputs\.native_client_server_compile_required == 'true' \|\| needs\.ci-selection-shadow\.outputs\.controller_operational_proof_required == 'true'\)"; Key='native'; ArtifactOutput='report_artifact_id' },
	@{ Job='unreal-receipt-shadow'; Producer='trusted-editor-automation'; Predicate="needs\.ci-selection-shadow\.outputs\.unreal_editor_automation_required == 'true'"; Key='unreal'; ArtifactOutput='automation_artifact_id' },
	@{ Job='visual-receipt-shadow'; Producer='visual-proof'; Predicate="needs\.ci-selection-shadow\.outputs\.visual_package_required == 'true'"; Key='visual'; ArtifactOutput='report_artifact_id' }
)
foreach ($Receipt in $ReceiptContracts) {
	$ReceiptBody = [string] $JobBodies[$Receipt.Job]
	Assert-True ($ReceiptBody -match "(?m)^    needs:\r?\n      - ci-selection-shadow\r?\n      - $([regex]::Escape($Receipt.Producer))\r?\n(?=    if: )" -and $ReceiptBody -match "(?m)^    if: github\.event_name == 'pull_request' && $($Receipt.Predicate)\r?$") "$($Receipt.Job) must be selected only for a pull request through the exact accepted selector output and raw producer."
	Assert-True ($ReceiptBody -match '(?m)^    runs-on: windows-latest\r?$' -and $ReceiptBody -match '(?m)^    timeout-minutes: 10\r?$' -and $ReceiptBody -notmatch 'self-hosted|aetheln-engine-runner|concurrency:') "$($Receipt.Job) must remain bounded and hosted."
	Assert-MatchCount -Text $ReceiptBody -Pattern ('(?m)^        uses: ' + [regex]::Escape($DownloadAction) + '\r?$') -Expected 2 -Message "$($Receipt.Job) must download selector and raw evidence by exact artifact ID."
	$ProducerId = [regex]::Escape('${{ needs.' + $Receipt.Producer + '.outputs.' + $Receipt.ArtifactOutput + ' }}')
	Assert-True ($ReceiptBody -match 'artifact-ids: \$\{\{ needs\.ci-selection-shadow\.outputs\.selector_artifact_id \}\}' -and $ReceiptBody -match ("artifact-ids: " + $ProducerId)) "$($Receipt.Job) must use direct needs artifact-ID bindings."
	Assert-True ($ReceiptBody -match 'scripts/ci/New-CiAcceptanceAggregateContext\.ps1' -and $ReceiptBody -match '-Mode Identity' -and $ReceiptBody -match 'scripts/ci/Publish-CiAcceptanceReceipt\.ps1' -and $ReceiptBody -match ("-ProducerKey " + [regex]::Escape($Receipt.Key) + ' `') -and $ReceiptBody -match ("-JobName " + [regex]::Escape($Receipt.Job) + ' `')) "$($Receipt.Job) must use the exact identity and receipt scripts with reviewed identities."
	Assert-True ($ReceiptBody -match ("ci-receipt-" + $Receipt.Key + '-') -and $ReceiptBody -match '\$\{\{ needs\.ci-selection-shadow\.outputs\.attempt_nonce \}\}') "$($Receipt.Job) receipt name must be bound to the selector nonce."
	foreach ($Output in @('artifact_id','artifact_name','artifact_digest')) { Assert-True ($ReceiptBody -match "(?m)^      ${Output}: ") "$($Receipt.Job) must expose direct upload output '$Output'." }
	Assert-True ($ReceiptBody -notmatch '(?m)^\s+if: always\(\)\r?$' -and $ReceiptBody -notmatch '(?m)^\s+continue-on-error:') "$($Receipt.Job) must fail red on unexpected publication failures."
}

$AggregateShadow = [string] $JobBodies['ci-acceptance-shadow']
Assert-True ($Workflow -notmatch 'delivery-harness|delivery_harness_required' -and $AggregateShadow -notmatch 'delivery-harness') 'Retired delivery harness must not be a live selector or aggregate obligation.'
Assert-True ($AggregateShadow -match '(?m)^    if: always\(\)\r?$' -and $AggregateShadow -notmatch '(?m)^    continue-on-error:') 'Acceptance aggregation must always diagnose dependencies while unexpected diagnostic failures remain visible.'
Assert-True ($AggregateShadow -match '(?m)^    runs-on: windows-latest\r?$' -and $AggregateShadow -match '(?m)^    timeout-minutes: 10\r?$') 'Acceptance aggregation must be bounded on GitHub-hosted Windows.'
Assert-True ($AggregateShadow -notmatch 'self-hosted|aetheln-engine-runner|concurrency:') 'Acceptance aggregation must never hold or target the engine runner.'
Assert-True ($AggregateShadow -match '(?ms)^    permissions:\r?\n      actions: read\r?\n      contents: read\r?$' -and $AggregateShadow -notmatch '(?m)^      [a-z-]+: write\r?$') 'Acceptance aggregation must have only job-scoped actions:read and contents:read.'
$AggregateNeedsMatch = [regex]::Match($AggregateShadow, '(?ms)^    needs:\r?\n(?<needs>(?:      - [a-z0-9-]+\r?\n)+)')
Assert-True $AggregateNeedsMatch.Success 'Acceptance aggregation must declare an explicit direct-needs list.'
$ActualAggregateNeeds = @([regex]::Matches($AggregateNeedsMatch.Groups['needs'].Value, '(?m)^      - (?<job>[a-z0-9-]+)\r?$') | ForEach-Object { [string] $_.Groups['job'].Value })
$ExpectedAggregateNeeds = @('ci-selection-shadow', 'quality-gates', 'change-impact', 'trusted-candidate-compile', 'trusted-editor-automation', 'scheduled-client-package', 'scheduled-server-package', 'scheduled-provenance-validation', 'scheduled-packaged-smoke', 'visual-proof', 'portable-receipt-shadow', 'native-receipt-shadow', 'unreal-receipt-shadow', 'visual-receipt-shadow')
Assert-True (($ActualAggregateNeeds -join ',') -ceq ($ExpectedAggregateNeeds -join ',')) 'Acceptance aggregation must directly need every raw producer and receipt publisher exactly once in the reviewed order.'
Assert-True ($AggregateShadow -match ('(?m)^        uses: ' + [regex]::Escape($DownloadAction) + '\r?$') -and $AggregateShadow -match 'artifact-ids: \$\{\{ needs\.ci-selection-shadow\.outputs\.selector_artifact_id \}\}') 'Acceptance aggregation must download its selector through the direct upload ID.'
foreach ($RequiredInput in @('scripts/ci/New-CiAcceptanceAggregateContext.ps1','scripts/ci/ci-acceptance-requirements.json','scripts/ci/Invoke-CiAcceptanceAggregate.ps1')) { Assert-True ($AggregateShadow -match [regex]::Escape($RequiredInput)) "Acceptance aggregation must use exact reviewed input '$RequiredInput'." }
Assert-True ($AggregateShadow -match 'Invoke-CiAcceptanceAggregateMain' -and $AggregateShadow -match "throw 'aggregate_shadow_decision_invalid'") 'A supported selection must execute the real aggregate and fail if its decision is not complete shadow evidence.'
Assert-True ($AggregateShadow -match 'producer_contract_incomplete' -and $AggregateShadow -match "throw 'aggregate_ready_contradiction'" -and $AggregateShadow -match 'acceptance_producer_gap:') 'Only a nonempty selected unsupported set may produce the explicit green producer gap.'
Assert-True ($AggregateShadow -match 'complete = \$false' -and $AggregateShadow -match 'shadow = \$true' -and $AggregateShadow -match 'authoritative = \$false' -and $AggregateShadow -match 'grantsAcceptance = \$false') 'Unsupported Package 3C selection must be explicitly shadow-only and non-granting.'
Assert-True ($AggregateShadow -notmatch 'grantsAcceptance = \$true|authoritative = \$true' -and $AggregateShadow -notmatch '(?ms)^      - name: Upload shadow acceptance diagnostic\r?\n        id: acceptance_artifact\r?\n        if: always\(\)') 'The live aggregate must never grant authority or upload after an unexpected reconciliation failure.'

$AcceptanceAuthority = [string] $JobBodies['ci-acceptance-authority']
Assert-True ($AcceptanceAuthority -match "(?m)^    needs: ci-acceptance-shadow\r?\n    if: always\(\) && github\.event_name == 'pull_request' && false\r?$" -and $AcceptanceAuthority -match '(?m)^    timeout-minutes: 5\r?$') 'The future authority boundary must remain literally false, evaluate aggregate failure, and stay bounded.'
Assert-True ($AcceptanceAuthority -match '(?ms)^    permissions:\r?\n      actions: read\r?\n      contents: read\r?$' -and $AcceptanceAuthority -notmatch '(?m)^      [a-z-]+: write\r?$') 'The dormant authority boundary must remain read-only.'
Assert-True ($AcceptanceAuthority -match 'AETHELN_AGGREGATE_RESULT: \$\{\{ needs\.ci-acceptance-shadow\.result \}\}' -and $AcceptanceAuthority -match "throw 'acceptance_authority_dependency_invalid'") 'A failed or cancelled aggregate must execute the activated authority boundary and fail red rather than produce a skipped check.'

# The milestone is split into four bounded phases that run only on the daily
# schedule and only after the portable gates pass; pull requests and pushes
# cannot enter them and no manual trigger exists. Job timeout-minutes is the
# total concurrency-holding bound for the phase (40/40/20/20), and every
# phase runs its work under a cooperative script deadline (30/30/10/10) plus
# the gate's supervisor hard bound (deadline plus a finalization grace capped at
# 600 seconds). Reports are best effort within remaining platform job time;
# checkout/LFS and finalization also consume that budget.
$PhaseTrigger = "(?m)^\s+if: github\.event_name == 'schedule'\r?$"
$PhaseContract = @(
	@{ Job = 'scheduled-client-package'; Needs = 'quality-gates'; JobTimeout = 40; Mode = 'PackageClient'; PhaseTimeout = '30'; Artifact = 'engine-runner-client-package-report' },
	@{ Job = 'scheduled-server-package'; Needs = 'scheduled-client-package'; JobTimeout = 40; Mode = 'PackageServer'; PhaseTimeout = '30'; Artifact = 'engine-runner-server-package-report' },
	@{ Job = 'scheduled-provenance-validation'; Needs = 'scheduled-server-package'; JobTimeout = 20; Mode = 'ValidateProvenance'; PhaseTimeout = '10'; Artifact = 'engine-runner-provenance-validation-report' },
	@{ Job = 'scheduled-packaged-smoke'; Needs = 'scheduled-provenance-validation'; JobTimeout = 20; Mode = 'SmokePhase'; PhaseTimeout = '10'; Artifact = 'engine-runner-scheduled-smoke-report' }
)
foreach ($Phase in $PhaseContract) {
	$Body = [string] $JobBodies[$Phase.Job]
	Assert-MatchCount -Text $Body -Pattern '(?m)^\s+if: ' -Expected 2 -Message "$($Phase.Job) must declare exactly one job-level trigger predicate plus the report-upload predicate."
	Assert-True ($Body -match $PhaseTrigger) "$($Phase.Job) must run only on the schedule event."
	Assert-True ($Body -notmatch 'workflow_dispatch' -and $Body -notmatch 'pull_request' -and $Body -notmatch "'push'") "$($Phase.Job) must not be selectable by dispatch, pull requests, or pushes."
	Assert-True ($Body -notmatch 'always\(\)\s*&&' -and $Body -notmatch '(?m)^\s+if:\s*always\(\)\s*\|\|' -and $Body -notmatch 'cancelled\(\)' -and $Body -notmatch 'failure\(\)') "$($Phase.Job) must not bypass a skipped, cancelled, or failed predecessor."
	Assert-True ($Body -match ('(?m)^\s+needs: ' + [regex]::Escape($Phase.Needs) + '\r?$')) "$($Phase.Job) must run strictly after $($Phase.Needs) and release the runner between phases."
	Assert-MatchCount -Text $Body -Pattern '(?m)^\s+needs:' -Expected 1 -Message "$($Phase.Job) must declare exactly one predecessor."
	Assert-True ($Body -match ('(?m)^\s+timeout-minutes: ' + $Phase.JobTimeout + '\r?$')) "$($Phase.Job) must be bounded by timeout-minutes $($Phase.JobTimeout)."
	Assert-MatchCount -Text $Body -Pattern '(?m)^\s+timeout-minutes: ' -Expected 1 -Message "$($Phase.Job) must declare exactly one job bound."
	Assert-MatchCount -Text $Body -Pattern ('(?m)^\s+-Mode ' + [regex]::Escape($Phase.Mode) + ' `\r?$') -Expected 1 -Message "$($Phase.Job) must select mode $($Phase.Mode) exactly once."
	Assert-MatchCount -Text $Body -Pattern '(?m)^\s+-Mode ' -Expected 1 -Message "$($Phase.Job) must invoke the gate exactly once."
	Assert-True ($Body -match ('(?m)^\s+-PhaseTimeoutMinutes ' + $Phase.PhaseTimeout + '\r?$')) "$($Phase.Job) must enforce the recorded $($Phase.PhaseTimeout)-minute script watchdog inside its job bound."
	Assert-True ([int] $Phase.PhaseTimeout -lt $Phase.JobTimeout) "$($Phase.Job) watchdog must expire before the total job bound so evidence is uploaded."
	Assert-MatchCount -Text $Body -Pattern ('(?m)^\s+name: ' + [regex]::Escape($Phase.Artifact) + '\r?$') -Expected 1 -Message "$($Phase.Job) must upload its own distinct report artifact."
	Assert-True ($Body -match '(?m)^\s+if: always\(\)\r?$') "$($Phase.Job) must retain its report evidence even on failure or timeout."
	Assert-True ($Body -match '(?m)^\s+if-no-files-found: error\r?$') "$($Phase.Job) must fail closed when its report is missing."
	Assert-True ($Body -notmatch '(?m)^\s+-Mode (Compile|PackagedSmoke) `\r?$') "$($Phase.Job) must not select a non-phase gate mode."
	Assert-True ($Body -notmatch '-ArchiveRoot') "$($Phase.Job) must exchange packaged bytes only through the durable handoff store, not a run-local archive root."
	Assert-True ($Body -match '(?m)^\s+group: aetheln-engine-runner\r?$' -and $Body -match '(?m)^\s+queue: max\r?$' -and $Body -match '(?m)^\s+cancel-in-progress: false\r?$') "$($Phase.Job) must keep the shared FIFO, non-cancelling concurrency block."
	foreach ($Binding in @('-Repository ''\$\{\{ github\.repository \}\}''', '-RunId ''\$\{\{ github\.run_id \}\}''', '-RunAttempt ''\$\{\{ github\.run_attempt \}\}''', '-RunnerName ''\$\{\{ runner\.name \}\}''')) {
		Assert-True ($Body -match $Binding) "$($Phase.Job) must bind the exact handoff context ($Binding)."
	}
}

# Phase 1 is the only phase that depends on the portable job; the portable job
# itself runs on every event and depends on nothing, so a portable failure,
# cancellation, or skip stops the whole engine chain before it touches the
# runner.
Assert-True (([string] $JobBodies['quality-gates']) -notmatch '(?m)^\s+needs:') 'quality-gates must depend on nothing.'
Assert-MatchCount -Text ([string] $JobBodies['quality-gates']) -Pattern '(?m)^        if: always\(\)\r?$' -Expected 2 -Message 'quality-gates may use always() only to bind and upload its raw report.'
Assert-True (([string] $JobBodies['quality-gates']) -notmatch '(?m)^    if: ') 'quality-gates must run unconditionally on every event.'

# Package phases need full Content LFS; the later phases consume only verified
# handoff payloads and must not depend on residual workspace or LFS state.
foreach ($Job in @('scheduled-client-package', 'scheduled-server-package')) {
	Assert-True (([string] $JobBodies[$Job]) -match 'git lfs pull --include "Content/\*\*"') "$Job must materialize every Unreal Content LFS object before packaging."
}

# The trusted compile lane keeps its own contract: pull requests only, owner and
# same-repository trust, gated behind both the portable gates and the classifier
# (implicit success() on both), no 24-hour bound, no handoff coupling, so an
# unset AETHELN_HANDOFF_ROOT can never affect it.
$TrustedCompile = [string] $JobBodies['trusted-candidate-compile']
# TA-020: editor automation is a separate owner-only engine job after a
# successful compile, with its own 35-minute ceiling, the shared FIFO queue,
# and no status bypass, so it can never fail the compile job or skip the
# native receipt, and it is skipped whenever the compile is skipped.
$EditorAutomation = [string] $JobBodies['trusted-editor-automation']
Assert-True ($EditorAutomation -match '(?m)^    needs: trusted-candidate-compile\r?$' -and $EditorAutomation -match "github\.event_name == 'pull_request'" -and $EditorAutomation -match 'github\.event\.pull_request\.head\.repo\.full_name == github\.repository' -and $EditorAutomation -match 'github\.event\.pull_request\.user\.login == github\.repository_owner' -and $EditorAutomation -match 'github\.triggering_actor == github\.repository_owner') 'Editor automation must need the compile and keep the owner, same-repository, and triggering-actor trust.'
Assert-True ($EditorAutomation -match '(?m)^    timeout-minutes: 35\r?$' -and $EditorAutomation -notmatch 'timeout-minutes:\s*1440' -and $EditorAutomation -notmatch '(?m)^    if: always\(\)' -and $EditorAutomation -notmatch 'needs\.[a-z-]+\.result' -and $EditorAutomation -notmatch '-Mode ') 'Editor automation must keep its 35-minute ceiling, never bypass prerequisite status, and never invoke the engine gate.'
Assert-True ((($TrustedCompile -split '\r?\n' | Where-Object { $_ -notmatch '^\s*#' }) -join "`n") -notmatch 'AethelnOnlineEditor|automation_') 'The compile job must keep its pre-producer shape.'
Assert-True ($TrustedCompile -match '(?m)^\s+needs:\r?\n\s+- quality-gates\r?\n\s+- change-impact\r?$') 'Trusted compile must depend on exactly the portable gates and the change-impact classifier.'
Assert-True ($TrustedCompile -match "needs\.change-impact\.outputs\.engine_required == 'true'") 'Trusted compile must require the classifier to demand the engine.'
Assert-True ($TrustedCompile -match "github\.event_name == 'pull_request'") 'Trusted compile must remain a pull-request lane.'
Assert-True ($TrustedCompile -match 'github\.event\.pull_request\.head\.repo\.full_name == github\.repository' -and $TrustedCompile -match 'github\.event\.pull_request\.user\.login == github\.repository_owner' -and $TrustedCompile -match 'github\.triggering_actor == github\.repository_owner') 'Trusted compile must keep the owner and same-repository trust checks.'
Assert-True ($TrustedCompile -notmatch "github\.event_name == 'schedule'") 'Trusted compile must not be selectable by schedule.'
Assert-MatchCount -Text $TrustedCompile -Pattern '(?m)^        if: always\(\)\r?$' -Expected 2 -Message 'Trusted compile may use always() only on report binding and upload steps, never at job scope.'
Assert-True ($TrustedCompile -notmatch '(?m)^    if: always\(\)\r?$') 'Trusted compile must not bypass a failed, cancelled, or skipped prerequisite at job scope.'
Assert-True ($TrustedCompile -notmatch 'timeout-minutes:\s*1440') 'Trusted compile must not be a 24-hour job.'
Assert-True ($TrustedCompile -notmatch '-PhaseTimeoutMinutes' -and $TrustedCompile -notmatch '-RunId') 'Trusted compile must not depend on the scheduled handoff contract.'

# Operational caps and disjoint workspaces prevent repeated cold checkouts.
$SuiteSource = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts/ci/Invoke-CiSuite.ps1') -Raw
Assert-True ($SuiteSource -match "name = 'compile-workspace-tests'; tier = 'required'; script = 'tests/ci/Initialize-CompileWorkspace.Tests.ps1'") 'Retention helper fixtures must be a required serial CI gate.'
Assert-True ($TrustedCompile -match '(?m)^    timeout-minutes: 40\r?$') 'Compile must have a 40-minute whole-job cap.'
Assert-True ($TrustedCompile -match '-CompileTimeoutMinutes 30') 'Both compile targets must share the 30-minute watchdog.'
function Assert-ManagedCompileWorkflow([string] $Body) {
	$Control = 'compile-control-${{ github.run_id }}-${{ github.run_attempt }}'
	$CaptureMatch = [regex]::Match($Body, '(?ms)^      - name: Capture routine compile deadline\r?\n(?<capture>.*?)(?=^      - |\z)')
	Assert-True $CaptureMatch.Success 'Compile must capture its original budget before checkout.'
	$Capture = $CaptureMatch.Groups['capture'].Value
	$CheckoutPosition = $Body.IndexOf("uses: $CheckoutAction")
	Assert-True ($CheckoutPosition -gt $CaptureMatch.Index) 'Checkout must consume the original compile budget.'
	Assert-True ($Capture.Contains('working-directory: ${{ runner.temp }}')) 'Before checkout the capture step must use existing runner.temp, not the absent control checkout.'
	Assert-True ($Capture.Contains('[Diagnostics.Stopwatch]::GetTimestamp()') -and $Capture.Contains('[DateTime]::UtcNow.ToString(''o'', [Globalization.CultureInfo]::InvariantCulture)')) 'Capture must include both monotonic and UTC anchors.'
	Assert-True ($Capture.Contains('[IO.File]::AppendAllText($env:GITHUB_ENV,') -and $Capture.Contains('AETHELN_COMPILE_STARTED_UTC=') -and $Capture.Contains('AETHELN_COMPILE_STARTED_TIMESTAMP=')) 'Both nonsecret original anchors must be published for the gate.'
	Assert-True ($Body.Contains('-CompileStartedUtc $env:AETHELN_COMPILE_STARTED_UTC') -and $Body.Contains('-CompileStartedTimestamp $env:AETHELN_COMPILE_STARTED_TIMESTAMP')) 'Gate must receive both original anchors without resetting staging time.'
	Assert-True ($Body.Contains('path: ' + $Control) -and $Body.Contains('working-directory: ' + $Control)) 'Only a fresh run/attempt control checkout may be managed by actions/checkout.'
	Assert-True ($Body.Contains('ref: ${{ github.sha }}') -and $Body.Contains('persist-credentials: false') -and $Body.Contains('lfs: false')) 'Control checkout must be exact-revision, LFS-disabled and without persisted credentials.'
	Assert-True ($Body -match '(?m)^        timeout-minutes: 5\r?$') 'Control checkout must have a bounded staging interval.'
	Assert-True ($Body -notmatch 'Initialize-CompileWorkspace|git lfs pull|clean: false') 'Retained preparation must stay inside the supervised gate, never workflow cleanup or hydration.'
	foreach ($Binding in @(
		@('ManagedWorkspaceRoot', 'AETHELN_MANAGED_COMPILE_ROOT'),
		@('ManagedWorkspaceRegistrationPath', 'AETHELN_MANAGED_COMPILE_REGISTRATION'),
		@('ManagedWorkspaceRegistrationSha256', 'AETHELN_MANAGED_COMPILE_REGISTRATION_SHA256'),
		@('HostLeasePath', 'AETHELN_ENGINE_HOST_LEASE')
	)) {
		Assert-True ($Body.Contains('-' + $Binding[0] + ' $env:' + $Binding[1])) 'Managed workspace parameters must bind operator configuration through environment values.'
		Assert-True ($Body.Contains($Binding[1] + ': ${{ vars.' + $Binding[1] + ' }}')) 'Every managed-workspace value must have an explicit repository-variable binding.'
	}
	Assert-True ($Body.Contains('-Repository ''${{ github.repository }}''')) 'The managed registration must bind the exact repository.'
}
Assert-ManagedCompileWorkflow $TrustedCompile
foreach ($Mutation in @(
	@('path: compile-control-', 'path: compile-'),
	@('ref: ${{ github.sha }}', 'ref: develop'),
	@('persist-credentials: false', 'persist-credentials: true'),
	@('-HostLeasePath $env:AETHELN_ENGINE_HOST_LEASE', '-HostLeasePath omitted'),
	@('name: Capture routine compile deadline', 'name: Missing capture'),
	@('working-directory: ${{ runner.temp }}', 'working-directory: missing-control'),
	@('[Diagnostics.Stopwatch]::GetTimestamp()', '0'),
	@('-CompileStartedTimestamp $env:AETHELN_COMPILE_STARTED_TIMESTAMP', '-CompileStartedTimestamp 0'),
	@('-CompileStartedUtc $env:AETHELN_COMPILE_STARTED_UTC', '-CompileStartedUtc missing')
)) {
	$Rejected = $false
	try { Assert-ManagedCompileWorkflow ($TrustedCompile.Replace($Mutation[0], $Mutation[1])) } catch { $Rejected = $true }
	Assert-True $Rejected 'Unsafe control checkout or missing ownership binding must be rejected.'
}
$CaptureBlock = [regex]::Match($TrustedCompile, '(?ms)^      - name: Capture routine compile deadline\r?\n.*?(?=^      - )').Value
$ReorderedCapture = $TrustedCompile.Replace($CaptureBlock, '').Replace('      - name: Compile supported client and server targets', $CaptureBlock + '      - name: Compile supported client and server targets')
$Rejected = $false
try { Assert-ManagedCompileWorkflow $ReorderedCapture } catch { $Rejected = $true }
Assert-True $Rejected 'Capturing after checkout must be rejected even when both anchors and arguments remain present.'
Assert-True ($TrustedCompile -match '-ReportPath \(Join-Path \$RunRoot') 'Compile must write fresh run-scoped evidence.'
foreach ($Phase in $PhaseContract) {
	$Body = [string] $JobBodies[$Phase.Job]
	Assert-True ($Body -match '(?m)^          path: milestone\r?$' -and $Body -match 'working-directory: milestone') 'Every milestone checkout must be a sibling of compile.'
	Assert-True ($Body -notmatch 'clean: false') 'Milestone checkout must retain default clean behavior.'
	Assert-True ($Body.Contains("-RepositoryRoot '" + '${{ github.workspace }}/milestone' + "'")) 'Milestone scripts must receive their own checkout root.'
	Assert-True ($Body -match 'path: milestone/TestResults/engine-runner-report.json') 'Milestone uploads only its own report.'
}
$ReportUploads = @([regex]::Matches($Workflow, '(?m)^          path: (.+(?:ci-report|engine-runner-report)\.json)\r?$'))
Assert-True ($ReportUploads.Count -eq 6) 'Exactly six precise report-only uploads must remain.'
Assert-True ($TrustedCompile.Contains('path: ${{ runner.temp }}/aetheln-engine-${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}/engine-runner-report.json')) 'Compile upload must bind run, attempt and job outside retained checkout.'
Assert-True ($Workflow -notmatch '(?m)^          path: .*\*') 'Artifact paths must never upload wildcard build trees.'

# Issue #226 (TA-022): the separate, dispatch-only release workflow. GitHub runs
# a dispatched workflow from the YAML at the selected ref, so these pins catch
# honest drift in this tree only. They cannot stop an approved fork run or a
# direct push; the GitHub settings and operator rules in TA-022 do that.
$ReleasePredicate = "github.event_name == 'workflow_dispatch' && github.repository == 'ShayShimoni/aetheln-online' && startsWith(github.ref, 'refs/heads/release/') && github.actor == github.repository_owner && github.triggering_actor == github.repository_owner && github.run_attempt == '1'"
$ReleasePhases = @(
	@{ Job = 'release-client-package'; Needs = 'release-gates'; Scheduled = 'scheduled-client-package'; Artifact = 'release-client-package-report'; Package = $true },
	@{ Job = 'release-server-package'; Needs = 'release-client-package'; Scheduled = 'scheduled-server-package'; Artifact = 'release-server-package-report'; Package = $true },
	@{ Job = 'release-provenance-validation'; Needs = 'release-server-package'; Scheduled = 'scheduled-provenance-validation'; Artifact = 'release-provenance-validation-report'; Package = $false },
	@{ Job = 'release-packaged-smoke'; Needs = 'release-provenance-validation'; Scheduled = 'scheduled-packaged-smoke'; Artifact = 'release-packaged-smoke-report'; Package = $false }
)

$ReleaseBuildNumberLine = '            -BuildNumber ''${{ github.run_number }}'' `' + "`n"

function ConvertTo-LfText([string] $Text) { return $Text.Replace("`r`n", "`n") }

function Get-WorkflowJobBody([string] $Text) {
	# One body per two-space key of the top-level jobs mapping (LF text).
	$JobsMatch = [regex]::Match($Text, '(?ms)^jobs:\n(?<jobs>.*?)(?=^\S|\z)')
	Assert-True $JobsMatch.Success 'Every workflow must declare a top-level jobs mapping.'
	$JobsText = $JobsMatch.Groups['jobs'].Value
	$Headers = @([regex]::Matches($JobsText, '(?m)^  (?<name>[A-Za-z0-9_-]+):$'))
	$Bodies = [ordered]@{}
	for ($Index = 0; $Index -lt $Headers.Count; $Index++) {
		$End = if ($Index + 1 -lt $Headers.Count) { $Headers[$Index + 1].Index } else { $JobsText.Length }
		$Bodies[$Headers[$Index].Groups['name'].Value] = $JobsText.Substring($Headers[$Index].Index, $End - $Headers[$Index].Index)
	}
	return $Bodies
}

function Get-StepBlock([string] $JobBody) {
	$StepsMatch = [regex]::Match($JobBody, '(?ms)^    steps:\n(?<steps>.*)\z')
	if (-not $StepsMatch.Success) { return @() }
	return @([regex]::Split($StepsMatch.Groups['steps'].Value, '(?m)^(?=      - )') | Where-Object { $_.Length -gt 0 } | ForEach-Object { $_.TrimEnd([char] 10) + "`n" })
}

function Get-ReleaseUploadStep([string] $Name, [string] $Condition, [string] $Artifact, [string] $Path) {
	return (@(('      - name: ' + $Name), ('        if: ' + $Condition), ('        uses: ' + $UploadAction), '        with:', ('          name: ' + $Artifact), ('          path: ' + $Path), '          if-no-files-found: error', '          retention-days: 90', '') -join "`n")
}

function Edit-WorkflowText([string] $Text, [string] $Old, [string] $New) {
	$Index = $Text.IndexOf($Old, [StringComparison]::Ordinal)
	if ($Index -lt 0) { throw "Mutation anchor not found: $Old" }
	return $Text.Substring(0, $Index) + $New + $Text.Substring($Index + $Old.Length)
}

function Test-UntrustedWorkflowInterpolation([string] $Text) {
	# Match the entire expression, including single braces in format strings.
	foreach ($Expression in [regex]::Matches($Text, '(?s)\$\{\{.*?\}\}')) {
		if ($Expression.Value -match 'github\s*(?:\.\s*(?:event|head_ref|base_ref|ref)|\[\s*[''"](?:event|head_ref|base_ref|ref)[A-Za-z0-9_]*[''"]\s*\])') { return $true }
	}
	return $false
}

function Test-WorkflowWritePermission([string] $Text) {
	# Flow-form permission mappings are intentionally outside the reviewed form.
	return ($Text -match '(?m)^[ \t]+[''"]?[a-z-]+[''"]?\s*:[ \t]*[''"]?write\b|write-all|(?m)^\s*[''"]?permissions[''"]?\s*:\s*\{')
}

function Assert-ReleaseWorkflow([string] $Source) {
	$Text = ConvertTo-LfText $Source
	$TopKeys = @([regex]::Matches($Text, '(?m)^(?<key>[^\s#:][^:\n]*):') | ForEach-Object { $_.Groups['key'].Value })
	Assert-True (($TopKeys -join ',') -ceq 'name,on,permissions,jobs') 'Release packaging must have exactly the reviewed name, on, permissions and jobs top-level keys.'
	Assert-True (-not (Test-WorkflowWritePermission $Text)) 'Release packaging must not grant write or use flow-form permissions.'
	Assert-True (-not (Test-UntrustedWorkflowInterpolation $Text)) 'Release packaging must not interpolate event or ref data inside any expression.'
	Assert-True ($Text -match '(?m)^on:\n  workflow_dispatch:\n\npermissions:\n  contents: read\n\njobs:$') 'Release packaging must declare only the input-free workflow_dispatch trigger and an explicit top-level contents: read.'
	foreach ($Rule in @(
		@('(?m)^\s+inputs:', 'dispatch inputs'),
		@('\binputs\.', 'an inputs expression'),
		@('pull_request', 'a pull-request trigger'),
		@('(?m)^\s+(?:push|schedule|issue_comment|merge_group):', 'another trigger'),
		@('workflow_run|workflow_call|repository_dispatch', 'a chained trigger'),
		@('\bsecrets\.', 'a secret'),
		@('\bvars\.', 'a repository variable'),
		@('continue-on-error', 'continue-on-error'),
		@('(?m)^\s+clean:', 'a checkout clean key'),
		@('download-artifact|actions/cache', 'an artifact or cache input'),
		@('(?-i)(?m)^[ \t]+[a-z-]+:[ \t]*write\b|write-all', 'a write permission'),
		@('(?m)^    (?:permissions|uses):', 'a job-level permission or reusable workflow'),
		@('\$\{\{\s*github\.(?:event|head_ref|base_ref|ref)', 'an event or ref interpolation'),
		@('cancel-in-progress: true', 'a cancelling concurrency block'),
		@('-ArchiveRoot|-HostLeasePath|-ManagedWorkspace', 'a run-local archive, host lease, or managed-workspace parameter')
	)) {
		Assert-True ($Text -notmatch $Rule[0]) "Release packaging must not contain $($Rule[1])."
	}
	foreach ($Use in [regex]::Matches($Text, '(?m)^\s+(?:- )?uses: (?<action>\S+)$')) {
		Assert-True ($Use.Groups['action'].Value -cin @($CheckoutAction, $UploadAction)) "Release packaging may use only the pinned checkout and upload actions, not '$($Use.Groups['action'].Value)'."
	}
	foreach ($JobIf in [regex]::Matches($Text, '(?m)^    if: (?<value>.*)$')) {
		Assert-True ($JobIf.Groups['value'].Value -notmatch 'always\(|success\(|failure\(|cancelled\(|needs\.') 'No release job-level condition may use a status function or read a dependency result.'
	}
	Assert-MatchCount -Text $Text -Pattern '(?m)^    if: ' -Expected 4 -Message 'Only the four engine jobs may carry a job-level condition.'
	Assert-MatchCount -Text $Text -Pattern '(?m)^    runs-on: \[self-hosted, Windows, X64, aetheln-engine\]$' -Expected 4 -Message 'Exactly the four release phases may target the engine runner.'
	Assert-MatchCount -Text $Text -Pattern ('(?m)^\s+uses: ' + [regex]::Escape($UploadAction) + '$') -Expected 6 -Message 'Release packaging must upload exactly six reports.'
	Assert-MatchCount -Text $Text -Pattern '-BuildNumber' -Expected 1 -Message 'Only the provenance phase may pass the build number.'
	foreach ($Step in @([regex]::Split($Text, '(?m)^(?=      - )'))) {
		$StepIf = [regex]::Match($Step, '(?m)^        if: (?<value>.*)$')
		if ($StepIf.Success) { Assert-True ($Step.Contains('uses: ' + $UploadAction) -and $StepIf.Groups['value'].Value -cin @('always()', "always() && steps.suite.outcome != 'skipped'")) 'Only report uploads may run after a failed step.' }
		if ($Step.Contains('uses: ' + $UploadAction)) { Assert-True ($Step.Contains("          if-no-files-found: error`n") -and $Step.Contains("          retention-days: 90`n") -and $Step -notmatch '(?m)^          path: .*\*') 'Every release upload must be one exact file, fail when it is missing, and keep the 90-day retention.' }
	}

	$Jobs = Get-WorkflowJobBody $Text
	Assert-True ((@($Jobs.Keys) -join ',') -ceq 'release-gates,release-client-package,release-server-package,release-provenance-validation,release-packaged-smoke') 'Release packaging must define exactly the hosted guard job and the four phase jobs, in order.'
	$GatesBody = [string] $Jobs['release-gates']
	$GatesStepsIndex = $GatesBody.IndexOf('    steps:', [StringComparison]::Ordinal)
	Assert-True ($GatesStepsIndex -gt 0 -and $GatesBody.Substring(0, $GatesStepsIndex) -ceq (@('  release-gates:', '    runs-on: windows-latest', '    timeout-minutes: 30', '') -join "`n")) 'release-gates must stay a 30-minute hosted job with no condition, predecessor, environment, or runner admission.'
	$ExpectedGatesSteps = @(
		(@(('      - uses: ' + $CheckoutAction), '        with:', '          ref: ${{ github.sha }}', '          lfs: false', '          persist-credentials: false', '') -join "`n"),
		(@('      - name: Refuse anything but an owner dispatch of a matching release head', '        shell: powershell', '        run: powershell -NoProfile -File scripts/ci/Invoke-ReleasePackaging.ps1 -Mode Guard', '') -join "`n"),
		(@('      - name: Fetch StarterMap LFS object', '        shell: powershell', '        run: git lfs pull --include "Content/Maps/StarterMap.umap"', '') -join "`n"),
		(@('      - name: Run CI suite', '        id: suite', '        shell: powershell', '        run: powershell -NoProfile -File scripts/ci/Invoke-CiSuite.ps1', '') -join "`n"),
		(Get-ReleaseUploadStep -Name 'Upload machine-readable report' -Condition "always() && steps.suite.outcome != 'skipped'" -Artifact 'release-ci-report' -Path 'TestResults/ci-report.json')
	)
	$GatesSteps = @(Get-StepBlock $GatesBody)
	Assert-True ($GatesSteps.Count -eq $ExpectedGatesSteps.Count) 'release-gates must keep exactly its five reviewed steps.'
	for ($Index = 0; $Index -lt $ExpectedGatesSteps.Count; $Index++) {
		Assert-True ($GatesSteps[$Index] -ceq $ExpectedGatesSteps[$Index]) ("release-gates step {0} must match the reviewed text: checkout at the dispatched SHA, the guard as the first and only command of its own step, then the LFS fetch, the portable suite, and the report upload." -f ($Index + 1))
	}

	$EngineCheckout = @(('      - uses: ' + $CheckoutAction), '        with:', '          ref: ${{ github.sha }}', '          lfs: false', '          path: milestone', '          fetch-depth: 0', '          persist-credentials: false', '') -join "`n"
	$PluginRefusal = '          if (-not [string]::IsNullOrEmpty($env:UE_ADDITIONAL_PLUGIN_PATHS)) { Write-Output ''private_plugin_paths_set''; exit 1 }' + "`n"
	$BuildNumberLine = $ReleaseBuildNumberLine
	$EvidenceStep = @('      - name: Record release version evidence', '        id: release_evidence', '        timeout-minutes: 2', '        shell: powershell', '        run: powershell -NoProfile -File scripts/ci/Invoke-ReleasePackaging.ps1 -Mode Evidence -OutputPath TestResults/release-evidence.json', '') -join "`n"
	foreach ($Phase in $ReleasePhases) {
		$Body = [string] $Jobs[$Phase.Job]
		Assert-True ($Body -notmatch 'always\(\)\s*(?:&&|\|\|)') "$($Phase.Job) must not combine always() with another condition."
		$Scheduled = ConvertTo-LfText ([string] $JobBodies[$Phase.Scheduled])
		$ScheduledTimeout = [regex]::Match($Scheduled, '(?m)^    timeout-minutes: (?<value>\d+)$').Groups['value'].Value
		Assert-True ($ScheduledTimeout.Length -gt 0) "$($Phase.Scheduled) must declare its job bound."
		$ExpectedHead = @(('  {0}:' -f $Phase.Job), ('    needs: {0}' -f $Phase.Needs), ('    if: ' + $ReleasePredicate), '    runs-on: [self-hosted, Windows, X64, aetheln-engine]', ('    timeout-minutes: ' + $ScheduledTimeout), '    env:', "      UE_ADDITIONAL_PLUGIN_PATHS: ''", '    defaults:', '      run:', '        working-directory: milestone', '    concurrency:', '      group: aetheln-engine-runner', '      queue: max', '      cancel-in-progress: false', '') -join "`n"
		$StepsIndex = $Body.IndexOf('    steps:', [StringComparison]::Ordinal)
		Assert-True ($StepsIndex -gt 0 -and $Body.Substring(0, $StepsIndex) -ceq $ExpectedHead) "$($Phase.Job) must need exactly $($Phase.Needs), carry exactly the six-clause release predicate, keep the scheduled $ScheduledTimeout-minute bound, pin the private plugin path empty, and join the FIFO engine-runner group."
		$ScheduledSteps = @(Get-StepBlock $Scheduled)
		$ScheduledGate = @($ScheduledSteps | Where-Object { $_.Contains('scripts/ci/Invoke-EngineRunnerGate.ps1') })
		Assert-True ($ScheduledGate.Count -eq 1) "$($Phase.Scheduled) must invoke the gate exactly once."
		# Parity: the release gate step is the scheduled one plus only the
		# reviewed additions (plugin refusal on cooks, build number on provenance).
		$ExpectedGateTail = $ScheduledGate[0] -replace '^[^\n]*\n', ''
		if ($Phase.Package) { $ExpectedGateTail = $ExpectedGateTail.Replace("        run: |`n", "        run: |`n" + $PluginRefusal) }
		if ($Phase.Job -ceq 'release-provenance-validation') { $ExpectedGateTail = $ExpectedGateTail.Replace('            -PhaseTimeoutMinutes', $BuildNumberLine + '            -PhaseTimeoutMinutes') }
		$Expected = @($EngineCheckout)
		if ($Phase.Package) { $Expected += @($ScheduledSteps | Where-Object { $_.Contains('git lfs pull --include "Content/**"') }) }
		$Expected += 'gate'
		if ($Phase.Job -ceq 'release-packaged-smoke') { $Expected += $EvidenceStep }
		$Expected += Get-ReleaseUploadStep -Name 'Upload engine-runner report' -Condition 'always()' -Artifact $Phase.Artifact -Path 'milestone/TestResults/engine-runner-report.json'
		if ($Phase.Job -ceq 'release-packaged-smoke') { $Expected += Get-ReleaseUploadStep -Name 'Upload release evidence' -Condition 'always()' -Artifact 'release-evidence' -Path 'milestone/TestResults/release-evidence.json' }
		$Steps = @(Get-StepBlock $Body)
		Assert-True ($Steps.Count -eq $Expected.Count) "$($Phase.Job) must keep exactly its reviewed steps."
		for ($Index = 0; $Index -lt $Expected.Count; $Index++) {
			if ($Expected[$Index] -ceq 'gate') {
				Assert-True ($Steps[$Index] -match '^      - name: [^\n]+\n' -and ($Steps[$Index] -replace '^[^\n]*\n', '') -ceq $ExpectedGateTail) "$($Phase.Job) must run the scheduled gate invocation with the same mode, bindings, and watchdog, changed only by the reviewed release additions."
			} else {
				Assert-True ($Steps[$Index] -ceq $Expected[$Index]) ("{0} step {1} must match the reviewed text." -f $Phase.Job, ($Index + 1))
			}
		}
	}
}

function Assert-RepositoryWorkflowSet([hashtable] $Workflows) {
	Assert-True ((@($Workflows.Keys | Sort-Object) -join ',') -ceq 'delivery-policy.yml,prototype-quality-gates.yml,release-packaging.yml,visual-package-validation.yml') 'The workflow set is closed: a new workflow file needs its own reviewed pins.'
	foreach ($Name in @($Workflows.Keys)) {
		$Text = ConvertTo-LfText ([string] $Workflows[$Name])
		Assert-True ($Text -match '(?m)^permissions:\n(?:  [a-z-]+: (?:read|none)\n)+' -and $Text -cnotmatch 'write-all|read-all' -and -not (Test-WorkflowWritePermission $Text)) "$Name must declare an explicit top-level permissions block and grant no write permission."
		foreach ($Use in [regex]::Matches($Text, '(?m)^\s+(?:- )?[''"]?uses[''"]?\s*:\s*(?<action>[^\n]+)$')) {
			Assert-True ($Use.Groups['action'].Value.Trim() -cin @($CheckoutAction, $DownloadAction, $UploadAction, './.github/workflows/visual-package-validation.yml')) "$Name uses an action or reusable workflow outside the reviewed allowlist."
		}
		$OnMatch = [regex]::Match($Text, '(?ms)^on:\n(?<body>.*?)(?=^\S)')
		Assert-True ($OnMatch.Success -and [regex]::Matches($Text, '(?m)^on:').Count -eq 1) "$Name must declare its triggers as one top-level on: mapping."
		$Triggers = @([regex]::Matches($OnMatch.Groups['body'].Value, '(?m)^  (?<event>[^\s:#]+):') | ForEach-Object { $_.Groups['event'].Value })
		Assert-True ($Triggers.Count -ge 1) "$Name must declare at least one trigger."
		foreach ($Trigger in $Triggers) {
			Assert-True ($Trigger -cin @('pull_request', 'push', 'schedule', 'workflow_call', 'workflow_dispatch')) "$Name must not use the '$Trigger' trigger."
		}
		Assert-True (($Name -ceq 'release-packaging.yml') -or ($Text -notmatch 'workflow_dispatch')) "Only release-packaging.yml may declare or mention workflow_dispatch; $Name does."
		foreach ($RunsOn in [regex]::Matches($Text, '(?m)^\s+runs-on:(?<value>.*)$')) {
			$Value = $RunsOn.Groups['value'].Value.Trim()
			$EngineWorkflow = $Name -cin @('prototype-quality-gates.yml', 'release-packaging.yml')
			Assert-True (($Value -ceq 'windows-latest') -or ($EngineWorkflow -and $Value -ceq '[self-hosted, Windows, X64, aetheln-engine]')) "$Name may target only windows-latest, or the exact engine label set in an engine workflow; found '$Value'."
		}
		foreach ($Job in (Get-WorkflowJobBody $Text).GetEnumerator()) {
			if ($Job.Value -match 'self-hosted') {
				Assert-True (-not (Test-UntrustedWorkflowInterpolation $Job.Value)) "$Name job $($Job.Key) runs on the engine runner and must not interpolate event or ref data."
			}
		}
	}
}

$ReleaseWorkflowLf = ConvertTo-LfText $ReleaseWorkflow
Assert-ReleaseWorkflow $ReleaseWorkflowLf
$ReleaseMutations = @(
	@{ Name = 'append a top-level environment'; Old = $null; New = "`nenv:`n  PSModulePath: fixture`n" },
	@{ Name = 'prepend a top-level environment'; Old = "on:`n"; New = "env:`n  GIT_CONFIG_PARAMETERS: fixture`n`non:`n" },
	@{ Name = 'add top-level defaults'; Old = "on:`n"; New = "defaults:`n  run:`n    shell: powershell`n`non:`n" },
	@{ Name = 'drop the ref prefix clause'; Old = "startsWith(github.ref, 'refs/heads/release/') && "; New = '' },
	@{ Name = 'widen the ref prefix'; Old = "'refs/heads/release/'"; New = "'refs/heads/'" },
	@{ Name = 'drop the repository clause'; Old = "github.repository == 'ShayShimoni/aetheln-online' && "; New = '' },
	@{ Name = 'drop the attempt clause'; Old = " && github.run_attempt == '1'"; New = '' },
	@{ Name = 'prefix always() to an engine predicate'; Old = '    if: github.event_name'; New = '    if: always() && github.event_name' },
	@{ Name = 'give the guard job a status condition'; Old = "  release-gates:`n"; New = "  release-gates:`n    if: always()`n" },
	@{ Name = 'add a pull-request trigger'; Old = "  workflow_dispatch:`n"; New = "  workflow_dispatch:`n  pull_request:`n" },
	@{ Name = 'add dispatch inputs'; Old = "  workflow_dispatch:`n"; New = "  workflow_dispatch:`n    inputs:`n      target:`n        type: string`n" },
	@{ Name = 'persist checkout credentials'; Old = 'persist-credentials: false'; New = 'persist-credentials: true' },
	@{ Name = 'check out a moving ref'; Old = 'ref: ${{ github.sha }}'; New = 'ref: develop' },
	@{ Name = 'cancel in-progress engine work'; Old = 'cancel-in-progress: false'; New = 'cancel-in-progress: true' },
	@{ Name = 'continue past a refused guard'; Old = "-Mode Guard`n"; New = "-Mode Guard`n        continue-on-error: true`n" },
	@{ Name = 'mask the guard exit code'; Old = '-Mode Guard'; New = '-Mode Guard; exit 0' },
	@{ Name = 'add a command to the guard step'; Old = '        run: powershell -NoProfile -File scripts/ci/Invoke-ReleasePackaging.ps1 -Mode Guard'; New = "        run: |`n          Write-Output starting`n          powershell -NoProfile -File scripts/ci/Invoke-ReleasePackaging.ps1 -Mode Guard" },
	@{ Name = 'run a step before the guard'; Old = '      - name: Refuse anything'; New = "      - name: Early step`n        shell: powershell`n        run: git --version`n      - name: Refuse anything" },
	@{ Name = 'drop needs: release-gates'; Old = "    needs: release-gates`n"; New = '' },
	@{ Name = 'disable checkout cleaning'; Old = "          path: milestone`n"; New = "          path: milestone`n          clean: false`n" },
	@{ Name = 'download an artifact'; Old = '      - name: Fetch Unreal Content LFS objects'; New = ('      - uses: ' + $DownloadAction + "`n        with:`n          name: release-ci-report`n      - name: Fetch Unreal Content LFS objects") },
	@{ Name = 'restore a cache'; Old = '      - name: Fetch Unreal Content LFS objects'; New = ("      - uses: actions/cache@0123456789abcdef0123456789abcdef01234567`n        with:`n          path: milestone/Saved`n          key: release`n" + '      - name: Fetch Unreal Content LFS objects') },
	@{ Name = 'read a repository variable'; Old = "      UE_ADDITIONAL_PLUGIN_PATHS: ''`n"; New = "      UE_ADDITIONAL_PLUGIN_PATHS: ''`n" + '      AETHELN_ROOT: ${{ vars.AETHELN_HANDOFF_ROOT }}' + "`n" },
	@{ Name = 'read a secret'; Old = "      UE_ADDITIONAL_PLUGIN_PATHS: ''`n"; New = "      UE_ADDITIONAL_PLUGIN_PATHS: ''`n" + '      AETHELN_TOKEN: ${{ secrets.GITHUB_TOKEN }}' + "`n" },
	@{ Name = 'raise a job permission'; Old = "  release-gates:`n"; New = "  release-gates:`n    permissions:`n      actions: write`n" },
	@{ Name = 'raise the workflow permission'; Old = "  contents: read`n"; New = "  contents: write`n" },
	@{ Name = 'interpolate the ref into an engine run'; Old = "-SourceRevision '`${{ github.sha }}'"; New = "-SourceRevision '`${{ github.ref }}'" },
	@{ Name = 'interpolate event data into an engine run'; Old = "-RunnerName '`${{ runner.name }}'"; New = "-RunnerName '`${{ github.event.sender.login }}'" },
	@{ Name = 'drop the build number'; Old = $ReleaseBuildNumberLine; New = '' },
	@{ Name = 'pass the build number to the smoke phase'; Old = ('            -Mode SmokePhase `' + "`n"); New = ('            -Mode SmokePhase `' + "`n" + $ReleaseBuildNumberLine) },
	@{ Name = 'drop the private plugin path pin'; Old = "    env:`n      UE_ADDITIONAL_PLUGIN_PATHS: ''`n"; New = '' },
	@{ Name = 'drop the private plugin path refusal'; Old = ('          if (-not [string]::IsNullOrEmpty($env:UE_ADDITIONAL_PLUGIN_PATHS)) { Write-Output ''private_plugin_paths_set''; exit 1 }' + "`n"); New = '' },
	@{ Name = 'raise a phase bound'; Old = '    timeout-minutes: 40'; New = '    timeout-minutes: 45' },
	@{ Name = 'raise a phase watchdog'; Old = '-PhaseTimeoutMinutes 30'; New = '-PhaseTimeoutMinutes 35' },
	@{ Name = 'select the monolithic gate'; Old = '-Mode PackageServer'; New = '-Mode PackagedSmoke' },
	@{ Name = 'combine always() on an engine upload'; Old = "        if: always()`n"; New = "        if: always() && true`n" },
	@{ Name = 'relax a non-upload step'; Old = "        id: release_evidence`n"; New = "        id: release_evidence`n        if: always()`n" },
	@{ Name = 'rename the evidence step'; Old = ('      - name: Record release version evidence' + "`n"); New = ('      - name: Skipped evidence' + "`n") },
	@{ Name = 'drop the evidence command'; Old = ' -Mode Evidence -OutputPath TestResults/release-evidence.json'; New = ' -Mode Guard' },
	@{ Name = 'shorten retention'; Old = 'retention-days: 90'; New = 'retention-days: 30' },
	@{ Name = 'upload a wildcard'; Old = 'path: milestone/TestResults/release-evidence.json'; New = 'path: milestone/TestResults/*' },
	@{ Name = 'upload packaged bytes'; Old = 'path: milestone/TestResults/engine-runner-report.json'; New = 'path: milestone/Saved' },
	@{ Name = 'route the guard to a runner label'; Old = '    runs-on: windows-latest'; New = '    runs-on: self-hosted' }
)
foreach ($Mutation in $ReleaseMutations) {
	$Mutated = if ($null -eq $Mutation.Old) { $ReleaseWorkflowLf + $Mutation.New } else { Edit-WorkflowText -Text $ReleaseWorkflowLf -Old $Mutation.Old -New $Mutation.New }
	$Rejected = $false
	try { Assert-ReleaseWorkflow $Mutated } catch { $Rejected = $true }
	Assert-True $Rejected "Release workflow mutation '$($Mutation.Name)' must be rejected."
}

$RepositoryWorkflows = @{}
foreach ($WorkflowFile in @(Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot '.github\workflows') -Force)) {
	$RepositoryWorkflows[$WorkflowFile.Name] = if ($WorkflowFile.PSIsContainer) { '' } else { ConvertTo-LfText (Get-Content -LiteralPath $WorkflowFile.FullName -Raw) }
}
Assert-RepositoryWorkflowSet $RepositoryWorkflows
$RepositoryMutations = @(
	@{ Name = 'grant write through a single-quoted permission key'; File = 'delivery-policy.yml'; Old = "permissions:`n  contents: read`n"; New = "permissions:`n  contents: read`n  'actions': write`n" },
	@{ Name = 'grant write through a double-quoted permission key'; File = 'delivery-policy.yml'; Old = "permissions:`n  contents: read`n"; New = "permissions:`n  contents: read`n  `"actions`": write`n" },
	@{ Name = 'call an external workflow through a single-quoted uses key'; File = 'delivery-policy.yml'; Old = "jobs:`n"; New = "jobs:`n  external:`n    'uses': someone/repo/.github/workflows/x.yml@0123456789abcdef0123456789abcdef01234567`n" },
	@{ Name = 'call an external action through a double-quoted uses key'; File = 'delivery-policy.yml'; Old = ('uses: ' + $CheckoutAction); New = '"uses": someone/action@0123456789abcdef0123456789abcdef01234567' },
	@{ Name = 'grant quoted write'; File = 'delivery-policy.yml'; Old = "permissions:`n  contents: read`n"; New = "permissions:`n  contents: read`n  actions: 'write'`n" },
	@{ Name = 'grant flow-form write'; File = 'prototype-quality-gates.yml'; Old = "    permissions:`n      actions: read`n"; New = "    permissions: { actions: write, contents: read }`n" },
	@{ Name = 'call an external reusable workflow'; File = 'delivery-policy.yml'; Old = "jobs:`n"; New = "jobs:`n  external:`n    uses: someone/repo/.github/workflows/x.yml@0123456789abcdef0123456789abcdef01234567`n" },
	@{ Name = 'call an external step action'; File = 'delivery-policy.yml'; Old = ('uses: ' + $CheckoutAction); New = 'uses: someone/action@0123456789abcdef0123456789abcdef01234567' },
	@{ Name = 'nest event interpolation in toJSON'; File = 'prototype-quality-gates.yml'; Old = '${{ runner.name }}'; New = '${{ toJSON(github.event) }}' },
	@{ Name = 'nest head_ref interpolation in format'; File = 'prototype-quality-gates.yml'; Old = '${{ runner.name }}'; New = '${{ format(''{0}'', github.head_ref) }}' },
	@{ Name = 'index head_ref in an expression'; File = 'prototype-quality-gates.yml'; Old = '${{ runner.name }}'; New = '${{ github[''head_ref''] }}' },
	@{ Name = 'retain refusal of ref_name interpolation'; File = 'prototype-quality-gates.yml'; Old = '${{ runner.name }}'; New = '${{ github.ref_name }}' },
	@{ Name = 'index ref_name in an expression'; File = 'prototype-quality-gates.yml'; Old = '${{ runner.name }}'; New = '${{ github[''ref_name''] }}' },
	@{ Name = 'add a workflow file'; File = 'extra.yml'; Old = $null; New = "name: Extra`n" },
	@{ Name = 'add an issue_comment trigger'; File = 'delivery-policy.yml'; Old = "on:`n  pull_request:`n"; New = "on:`n  issue_comment:`n  pull_request:`n" },
	@{ Name = 'switch to pull_request_target'; File = 'delivery-policy.yml'; Old = "  pull_request:`n    types:"; New = "  pull_request_target:`n    types:" },
	@{ Name = 'add a second dispatch workflow'; File = 'visual-package-validation.yml'; Old = "on:`n  workflow_call:`n"; New = "on:`n  workflow_dispatch:`n  workflow_call:`n" },
	@{ Name = 'target a bare self-hosted label'; File = 'delivery-policy.yml'; Old = '    runs-on: windows-latest'; New = '    runs-on: self-hosted' },
	@{ Name = 'target the engine labels from a hosted workflow'; File = 'visual-package-validation.yml'; Old = '    runs-on: windows-latest'; New = '    runs-on: [self-hosted, Windows, X64, aetheln-engine]' },
	@{ Name = 'target a runs-on expression'; File = 'delivery-policy.yml'; Old = '    runs-on: windows-latest'; New = '    runs-on: ${{ github.event.inputs.runner }}' },
	@{ Name = 'target a runner group mapping'; File = 'delivery-policy.yml'; Old = "    runs-on: windows-latest`n"; New = "    runs-on:`n      group: aetheln`n" },
	@{ Name = 'drop the top-level permissions'; File = 'delivery-policy.yml'; Old = "permissions:`n  contents: read`n"; New = '' },
	@{ Name = 'grant write-all'; File = 'delivery-policy.yml'; Old = "permissions:`n  contents: read`n"; New = "permissions: write-all`n" },
	@{ Name = 'grant a job-level write'; File = 'prototype-quality-gates.yml'; Old = "    permissions:`n      actions: read`n"; New = "    permissions:`n      actions: write`n" },
	@{ Name = 'interpolate event data in a scheduled engine job'; File = 'prototype-quality-gates.yml'; Old = "-RunnerName '`${{ runner.name }}'"; New = "-RunnerName '`${{ github.event.sender.login }}'" },
	@{ Name = 'interpolate the head ref in a release engine job'; File = 'release-packaging.yml'; Old = "-RunnerName '`${{ runner.name }}'"; New = "-RunnerName '`${{ github.head_ref }}'" }
)
foreach ($Mutation in $RepositoryMutations) {
	$Copy = @{}
	foreach ($Key in $RepositoryWorkflows.Keys) { $Copy[$Key] = $RepositoryWorkflows[$Key] }
	$Copy[$Mutation.File] = if ($null -eq $Mutation.Old) { $Mutation.New } else { Edit-WorkflowText -Text $Copy[$Mutation.File] -Old $Mutation.Old -New $Mutation.New }
	$Rejected = $false
	try { Assert-RepositoryWorkflowSet $Copy } catch { $Rejected = $true }
	Assert-True $Rejected "Repository workflow mutation '$($Mutation.Name)' must be rejected."
}

# The decided scheduling policy values are recorded in canonical documentation

function Assert-ReportOnlyUpload([string] $Text) {
	$Blocks = @([regex]::Split($Text, '(?m)^      - ') | Where-Object { $_ -match '(?m)^\s*uses: actions/upload-artifact@' })
	Assert-True ($Blocks.Count -eq 14) 'Exactly seven raw reports, selector, four receipts, aggregate, and hard-disabled authority receipt must exist.'
	$Allowed = @(
		'TestResults/ci-report.json',
		'milestone/TestResults/engine-runner-report.json',
		'${{ runner.temp }}/aetheln-engine-${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}/engine-runner-report.json',
		'${{ runner.temp }}/aetheln-engine-${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}/unreal-automation-report.json',
		'${{ runner.temp }}/ci-selection-shadow.json',
		'${{ runner.temp }}/${{ steps.receipt_identity.outputs.artifact_name }}',
		'${{ runner.temp }}/ci-acceptance-shadow.json',
		'${{ runner.temp }}/ci-acceptance-authority.json'
	)
	foreach ($Block in $Blocks) {
		$Paths = @([regex]::Matches($Block, '(?m)^          path: ([^\r\n]+)\r?$'))
		Assert-True ($Paths.Count -eq 1) 'Every artifact step must declare exactly one path.'
		Assert-True ($Allowed -ccontains $Paths[0].Groups[1].Value) 'Every uploaded artifact must be an exact approved report path.'
	}
}
Assert-ReportOnlyUpload $Workflow
$ExtraUpload = $Workflow + [Environment]::NewLine + (@("      - uses: $UploadAction", '        with:', '          name: unexpected-payload', '          path: Saved') -join [Environment]::NewLine)
$ExtraRejected = $false
try { Assert-ReportOnlyUpload $ExtraUpload } catch { $ExtraRejected = $true }
Assert-True $ExtraRejected 'An added directory upload must fail even while all six reports remain.'
$WrongUpload = $Workflow.Replace('path: milestone/TestResults/engine-runner-report.json', 'path: Saved')
$WrongRejected = $false
try { Assert-ReportOnlyUpload $WrongUpload } catch { $WrongRejected = $true }
Assert-True $WrongRejected 'Replacing a report with a generated directory must fail.'
# with truthful semantics: the 40-minute value is the maximum delay attributable
# to one currently running scheduled phase, not an absolute guarantee.
Assert-True ($CiDocumentation -match '(?i)maximum\s+trusted-compile\s+queue\s+delay') 'CI documentation must record the trusted-compile queue-delay policy.'
Assert-True ($CiDocumentation -match '(?i)40-minute|40\s*minutes') 'CI documentation must record the 40-minute queue-delay value.'
Assert-True ($CiDocumentation -match '(?i)attributable\s+to\s+one\s+currently\s+running\s+scheduled\s+phase') 'CI documentation must scope the 40-minute value to a single running scheduled phase.'
Assert-True ($CiDocumentation -match '(?i)no\s+absolute\s+priority\s+guarantee') 'CI documentation must state that this topology has no absolute priority guarantee.'
Assert-True ($CiDocumentation -match '(?i)total\s+queue\s+time\s+can\s+be\s+longer') 'CI documentation must state that older queued jobs can extend the total wait.'
Assert-True ($CiDocumentation -match 'AETHELN_HANDOFF_ROOT') 'CI documentation must document the durable handoff root provisioning.'
foreach ($Value in @('40', '20')) {
	Assert-True ($CiDocumentation -match $Value) "CI documentation must record the $Value-minute total phase bound."
}
foreach ($Value in @('30', '10')) {
	Assert-True ($CiDocumentation -match $Value) "CI documentation must record the $Value-minute script watchdog."
}
Assert-True ($CiDocumentation -match 'phase_timeout') 'CI documentation must record the phase_timeout failure semantics.'
Assert-True ($CiDocumentation -match 'phase_cleanup_failed') 'CI documentation must record the fail-closed process-tree cleanup semantics.'
Assert-True ($CiDocumentation -match '(?i)cleanup-request') 'CI documentation must record the no-deletion cleanup-request model.'

# Documentation must not advertise any manual or monolithic entry point, and
# must record the portable-first dependency chain and the classifier contract.
Assert-True ($CiDocumentation -notmatch 'manual-packaged-smoke') 'CI documentation must not advertise the retired manual-packaged-smoke job.'
Assert-True ($CiDocumentation -notmatch '(?i)24-hour\s+manual|manual\s+24-hour|owner-dispatched\s+24-hour') 'CI documentation must not advertise a 24-hour manual milestone.'
Assert-True ($CiDocumentation -notmatch 'engine-runner-manual-smoke-report') 'CI documentation must not advertise the retired manual smoke artifact.'
# Issue #226 narrows the dispatch-wording pin: only the release packaging
# section may describe the separate dispatch-only release workflow.
$ReleaseDocSection = [regex]::Match($CiDocumentation, '(?ms)^### Release packaging \(Issue #226\)\r?\n.*?(?=^#{1,3} |\z)')
Assert-True ($ReleaseDocSection.Success -and [regex]::Matches($CiDocumentation, '(?m)^### Release packaging \(Issue #226\)\r?$').Count -eq 1) 'CI documentation must contain exactly one release packaging section (TA-022).'
$CiDocumentationOutsideRelease = $CiDocumentation.Remove($ReleaseDocSection.Index, $ReleaseDocSection.Length)
foreach ($Term in @('release-packaging.yml', 'workflow_dispatch', 'release/*', 'no inputs', 'run_number', 'contents: read', 'aetheln-engine-runner', 'release-gates', 'retention-days: 90', 'release-evidence.json', 'LogNetVersion', 'local engine or editor build', 'attestation', 'release_guard_passed', 'release_event_invalid', 'release_repository_invalid', 'release_actor_invalid', 'release_attempt_invalid', 'release_ref_invalid', 'build_number_invalid', 'project_version_missing', 'project_version_invalid', 'project_version_override', 'project_version_branch_mismatch', 'release_evidence_passed', 'net_version_missing', 'net_version_line_invalid', 'net_version_mismatch', 'net_version_project_mismatch')) {
	Assert-True ($ReleaseDocSection.Value.Contains($Term)) "The CI release packaging section must record '$Term'."
}
Assert-True ($CiDocumentationOutsideRelease -notmatch 'workflow_dispatch' -and $CiDocumentationOutsideRelease -notmatch '(?i)owner-dispatched|owner\s+dispatch') 'CI documentation outside the release packaging section must not advertise a manual dispatch entry point.'
Assert-True ($CiDocumentation -match '(?i)schedule-only') 'CI documentation must record that the four phases are schedule-only.'
Assert-True ($CiDocumentation -match '(?i)needs:?\s*`?quality-gates`?') 'CI documentation must record that phase 1 depends on the portable gates.'
Assert-True ($CiDocumentation -match 'change-impact' -and $CiDocumentation -match 'engine_required') 'CI documentation must record the change-impact classifier and its engine_required output.'
foreach ($Reason in @('portable_paths_only', 'engine_paths_changed', 'invalid_sha', 'identical_shas', 'commit_unavailable', 'diff_failed', 'empty_diff', 'unexpected_diff_entry', 'classifier_error')) {
	Assert-True ($CiDocumentation -match [regex]::Escape($Reason)) "CI documentation must record the classifier reason code $Reason."
}
foreach ($Path in @('docs/\*\*', 'visuals/\*\*', 'output/pdf/\*\*', 'tests/\*\*', '\.github/workflows/\*\*', 'AethelnOnline\.uproject')) {
	Assert-True ($CiDocumentation -match $Path) "CI documentation must record the classifier path rule for $Path."
}

# The accepted architecture decisions must describe the same current policy as
# the workflow and CI documentation: no manual entry point, portable gates
# before selected engine work, exact base/head classification with the closed
# portable-only exemption, uncertainty never becoming a successful exemption,
# a classifier infrastructure failure distinguished from an exemption, and the
# trust checks still enforced. Historical context (the 2026-09-01 starvation)
# stays historical.
$ArchitectureDecisions = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'docs\architecture-decisions.md') -Raw
function Get-DecisionSection([string] $Id) {
	$Match = [regex]::Match($ArchitectureDecisions, "(?ms)^### $Id .*?(?=^### |^## )")
	Assert-True $Match.Success "Architecture decisions must contain an accepted $Id entry."
	return $Match.Value
}
$RunnerDecision = Get-DecisionSection 'TA-011'
$SchedulingDecision = Get-DecisionSection 'TA-012'
$SelectionDecision = Get-DecisionSection 'TA-017'
Assert-True ($SchedulingDecision -match '(?m)^- \*\*Status:\*\* Accepted\r?$' -and $RunnerDecision -match '(?m)^- \*\*Status:\*\* Accepted\r?$') 'TA-011 and TA-012 must remain accepted decisions.'
Assert-True ($SelectionDecision -match '(?m)^- \*\*Status:\*\* Accepted\r?$') 'TA-017 must record the accepted shadow-first selector decision.'
foreach ($Contract in @('shadow-first', 'accepted-base', '07bb90760bf493e25e40ac781143d07e701a113db3ede8bc7380490f6b85e9b6', 'wiring-only', 'external checker', 'before any self-hosted runner queues')) {
	Assert-True ($SelectionDecision -match [regex]::Escape($Contract)) "TA-017 must record the selector activation contract '$Contract'."
}
Assert-True ($CiDocumentation -match 'accepted_controller_unavailable' -and $CiDocumentation -match '5,395' -and $CiDocumentation -match 'e4a7bc5968f066178d1b78cb26d15df06f60af50696cda51b8e758ca8a38c805') 'CI documentation must record the bootstrap boundary and exact TA-018 legacy block identity.'
foreach ($Limit in @('two minutes', '8 MiB', '64 KiB', '4,096', '4 MiB')) {
	Assert-True ($CiDocumentation -match [regex]::Escape($Limit)) "CI documentation must record selector limit '$Limit'."
}
# TA-022 is the only decision that may describe the dispatch-only release
# workflow; it records the owner's runner-trust risk acceptance, the fork rule,
# the release/* ruleset text, and the stale-branch evidence.
$ReleaseDecision = Get-DecisionSection 'TA-022'
Assert-True ($ReleaseDecision -match '(?m)^- \*\*Status:\*\* Accepted\r?$') 'TA-022 must record the accepted dispatch-only release workflow.'
foreach ($Term in @('release-packaging.yml', 'workflow_dispatch', 'older branch', 'contents: read', 'TA-012', '2026-10-03', 'runner 21', 'never approve a workflow run from a fork pull request', 'leaves the owner', 'force-push', 'deletion', '`quality-gates`', 'no bypass actors', 'update or delete', 'zero remote branches')) {
	Assert-True ($ReleaseDecision.IndexOf($Term, [StringComparison]::OrdinalIgnoreCase) -ge 0) "TA-022 must record '$Term'."
}
Assert-True ($SchedulingDecision -match 'TA-022') 'TA-012 must point to the separate TA-022 release workflow.'
$ArchitectureDecisionsOutsideRelease = $ArchitectureDecisions.Replace($ReleaseDecision, '')
Assert-True ($ArchitectureDecisionsOutsideRelease -notmatch 'workflow_dispatch' -and $ArchitectureDecisionsOutsideRelease -notmatch '(?i)owner-dispatched|owner\s+dispatch') 'Architecture decisions outside TA-022 must not describe a manual dispatch entry point.'
Assert-True ($ArchitectureDecisions -notmatch '(?i)queued\s+manual') 'TA-012 must not describe older queued manual jobs; no manual job can exist.'
Assert-True ($RunnerDecision -notmatch '(?i)request\s+the\s+same\s+gate\s+manually' -and $RunnerDecision -notmatch '(?i)manual\s+packaged-smoke') 'TA-011 must not offer or await a manual packaged-smoke gate.'
Assert-True ($SchedulingDecision -match '(?i)schedule-only' -and $SchedulingDecision -match '(?i)no\s+manual') 'TA-012 must record that the milestone phases are schedule-only with no manual trigger.'
Assert-True ($SchedulingDecision -match '(?i)older\s+branch') 'TA-012 must record why no manual trigger may exist on this workflow identity.'
Assert-True ($SchedulingDecision -match '`quality-gates`' -and $SchedulingDecision -match '(?i)portable') 'TA-012 must record that portable gates run before selected engine work.'
Assert-True ($SchedulingDecision -match '`change-impact`' -and $SchedulingDecision -match '`engine_required`') 'TA-012 must record the change-impact classifier and its engine_required output.'
Assert-True ($SchedulingDecision -match '(?i)exact\s+(pull-request\s+)?base\s+(SHA\s+)?and\s+head') 'TA-012 must record the exact base/head SHA comparison.'
foreach ($Path in @('docs/\*\*', 'visuals/\*\*', 'output/pdf/\*\*', 'tests/\*\*', '\.github/workflows/\*\*', 'AethelnOnline\.uproject')) {
	Assert-True ($SchedulingDecision -match $Path) "TA-012 must record the classifier path rule for $Path."
}
Assert-True ($SchedulingDecision -match '(?i)uncertainty[^.]*engine_required=true|engine_required=true[^.]*uncertainty') 'TA-012 must record that classifier uncertainty selects compile, never a successful exemption.'
Assert-True ($SchedulingDecision -match '(?i)infrastructure\s+failure|classifier\s+job\s+(itself\s+)?fails') 'TA-012 must distinguish a classifier infrastructure failure from a portable exemption.'
Assert-True ($SchedulingDecision -match '(?i)trust\s+(predicate|checks?)') 'TA-012 must record that the trust checks remain enforced.'
Assert-True ($SchedulingDecision -match '2026-09-01') 'TA-012 must preserve the historical starvation context.'
foreach ($Value in @('40 minutes', '20 minutes', '30/30/10/10', '64 GiB', 'AETHELN_HANDOFF_ROOT', 'queue: max', 'cancel-in-progress: false')) {
	Assert-True ($SchedulingDecision -match [regex]::Escape($Value)) "TA-012 must preserve the accepted value '$Value'."
}
Assert-True ($SchedulingDecision -match 'Test-PrototypeQualityWorkflow\.Tests\.ps1') 'TA-012 must cite the classifier fixture suite as evidence.'

# TA-020 records the editor job ceiling, the worst-case owner pull-request hold
# (compile plus editor ceilings), and the engine-runner job count; each figure
# is derived from the workflow so a ceiling change cannot leave TA-020 stale.
$EditorDecision = (Get-DecisionSection 'TA-020') -replace '\s+', ' '
$EditorCeiling = [int] [regex]::Match($EditorAutomation, '(?m)^    timeout-minutes: (\d+)\r?$').Groups[1].Value
$CompileCeiling = [int] [regex]::Match($TrustedCompile, '(?m)^    timeout-minutes: (\d+)\r?$').Groups[1].Value
$EngineJobCount = [regex]::Matches($Workflow, '(?m)^\s+runs-on: \[self-hosted, Windows, X64, aetheln-engine\]\r?$').Count
$EngineJobWord = @('zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine')[$EngineJobCount]
Assert-True ($EditorDecision.Contains('- **Status:** Accepted -') -and $EditorCeiling -gt 0 -and $CompileCeiling -gt 0) 'TA-020 must be accepted and both engine pull-request jobs must declare a job ceiling.'
foreach ($Figure in @("has a $EditorCeiling-minute job ceiling", "up to $($CompileCeiling + $EditorCeiling) minutes ($CompileCeiling-minute compile plus $EditorCeiling-minute editor automation)", "now has $EngineJobWord jobs")) {
	Assert-True ($EditorDecision.Contains($Figure)) "TA-020 must record the workflow figure '$Figure'."
}

# The portable CI exemption is a closed applicability decision, not a blanket
# scripts/workflows exemption or a replacement for independent review. TA-018
# (2026-10-02) partially reverses TA-012: controller scripts and the live
# workflow compile again so the native producer can publish
# controller-operational-proof; only the two packaging scripts stay exempt.
$OperationalProofDecision = Get-DecisionSection 'TA-018'
Assert-True ($OperationalProofDecision -match '(?m)^- \*\*Status:\*\* Accepted\r?$' -and $OperationalProofDecision -match '2026-10-02' -and $OperationalProofDecision -match 'TA-012' -and $OperationalProofDecision -match '`controller-operational-proof`') 'TA-018 must record the accepted 2026-10-02 partial reversal of TA-012 for controller-operational-proof.'
foreach ($Path in @('scripts/build/Build-PackagedArtifacts.ps1', 'scripts/build/Invoke-PackagedSmokeTest.ps1')) {
	Assert-True ($SchedulingDecision.Contains('`' + $Path + '`')) "TA-012 must record the exact portable CI exemption '$Path'."
	Assert-True ($OperationalProofDecision.Contains('`' + $Path + '`')) "TA-018 must record that '$Path' remains exempt."
	Assert-True ($CiDocumentation.Contains('`' + $Path + '`')) "CI documentation must record the exact portable CI exemption '$Path'."
}
$PortableCiPathsBlock = [regex]::Match($Workflow, '(?ms)^\s*\$PortableCiPaths = @\((?<list>.*?)\)\r?$')
Assert-True ($PortableCiPathsBlock.Success -and ((@([regex]::Matches($PortableCiPathsBlock.Groups['list'].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) -join ',') -ceq 'scripts/build/Build-PackagedArtifacts.ps1,scripts/build/Invoke-PackagedSmokeTest.ps1')) 'The workflow portable-only CI path list must contain exactly the two packaging scripts.'
foreach ($Path in @('scripts/ci/Invoke-CiSuite.ps1', 'scripts/ci/Test-FormattingPolicy.ps1', 'scripts/ci/Test-MarkdownLinks.ps1', 'scripts/ci/Invoke-EngineRunnerGate.ps1', 'scripts/ci/Initialize-CompileWorkspace.ps1', '.github/workflows/prototype-quality-gates.yml')) {
	Assert-True ($SchedulingDecision.Contains('`' + $Path + '`') -and $OperationalProofDecision.Contains('`' + $Path + '`')) "TA-012 must keep its historical exemption of '$Path' and TA-018 must record its removal."
	Assert-True ($CiDocumentation.Contains('`' + $Path + '`')) "CI documentation must record that '$Path' compiles again."
}
foreach ($Document in @($SchedulingDecision, $CiDocumentation)) {
	Assert-True ($Document -match '(?i)case-sensitive') 'The portable CI allowlist must remain case-sensitive.'
	Assert-True ($Document -match '(?i)independent\s+review') 'Portable CI classification must retain independent review.'
	Assert-True ($Document -match '(?i)Unreal\s+compilation\s+does\s+not\s+validate') 'The applicability decision must explain why Unreal compilation is not the portable CI check.'
	Assert-True ($Document -match '(?i)other\s+`scripts/\*\*`' -and $Document -match '(?i)other\s+`\.github/workflows/\*\*`') 'The documentation must keep other scripts and workflows engine-required.'
}

Write-Output 'PASS: milestone phases are bounded, FIFO-queued, evidence-separated, schedule-only, gated behind portable success, and cannot starve trusted compile for 24 hours'
Write-Output 'PASS: trusted compile requires portable success and an engine-impacting change; no manual or monolithic package/smoke entry point remains'
Write-Output 'PASS: accepted decisions TA-011 and TA-012 describe the same schedule-only, portable-first, fail-closed selective gates as the workflow and CI documentation'
Write-Output 'PASS: Package 3C receipt and aggregate jobs remain PR-selected, directly bound, hosted, bounded, non-authoritative, and isolated from engine scheduling'
Write-Output 'PASS: the TA-022 release workflow is dispatch-only, guard-first, owner- and release/*-gated, attempt-1, read-only, parity-bound to the scheduled phases, and uploads only six reports; every pin fails red under mutation'
Write-Output 'PASS: repository workflows keep closed trigger, file, runs-on, and permission allowlists, and no engine job interpolates event or ref data'
exit 0
