[CmdletBinding()]
param()

# Sole purpose: validate the Issue #150 engine-runner scheduling contract —
# bounded schedule-only milestone phases that start only after the portable
# gates pass, FIFO queueing that cannot cancel pending or in-progress work,
# recorded trusted-compile queue-delay policy, trusted compile gated behind both
# the portable gates and the change-impact classifier, evidence separation per
# phase, and the absence of any manual or monolithic package/smoke entry point.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Workflow = Get-Content -LiteralPath (Join-Path $RepositoryRoot '.github\workflows\prototype-quality-gates.yml') -Raw
$CiDocumentation = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'docs\continuous-integration.md') -Raw

function Assert-True([bool] $Condition, [string] $Message) {
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-MatchCount([string] $Text, [string] $Pattern, [int] $Expected, [string] $Message) {
	$Actual = [regex]::Matches($Text, $Pattern).Count
	Assert-True ($Actual -eq $Expected) "$Message Expected $Expected match(es), found $Actual."
}

$JobOrder = @('quality-gates', 'change-impact', 'trusted-candidate-compile', 'scheduled-client-package', 'scheduled-server-package', 'scheduled-provenance-validation', 'scheduled-packaged-smoke')
$JobBodies = @{}
for ($Index = 1; $Index -lt $JobOrder.Count; $Index++) {
	$Start = $Workflow.IndexOf("  $($JobOrder[$Index - 1]):", [StringComparison]::Ordinal)
	$End = $Workflow.IndexOf("  $($JobOrder[$Index]):", [StringComparison]::Ordinal)
	Assert-True ($Start -ge 0 -and $End -gt $Start) "Workflow must define job '$($JobOrder[$Index - 1])' before '$($JobOrder[$Index])'."
	$JobBodies[$JobOrder[$Index - 1]] = $Workflow.Substring($Start, $End - $Start)
}
$JobBodies['scheduled-packaged-smoke'] = $Workflow.Substring($Workflow.IndexOf('  scheduled-packaged-smoke:', [StringComparison]::Ordinal))

# No manual entry point exists on this workflow identity. Keeping a
# workflow_dispatch trigger would let an operator select an older branch that
# still carries the retired 1,440-minute PackagedSmoke job; the four phases are
# therefore schedule-only, and the monolithic gate is unreachable.
Assert-True ($Workflow -notmatch 'workflow_dispatch') 'Workflow must not declare or reference workflow_dispatch anywhere.'
Assert-True ($Workflow -match "(?m)^on:\r?\n  pull_request:\r?\n  push:\r?\n    branches:\r?\n      - develop\r?\n  schedule:\r?\n    - cron: '0 2 \* \* \*'\r?\n\r?\n") 'Workflow events must be exactly pull_request, push to develop, and the daily schedule.'
Assert-True ($Workflow -notmatch 'manual-packaged-smoke') 'Workflow must not define the retired manual-packaged-smoke job.'
Assert-True ($Workflow -notmatch 'engine-runner-manual-smoke-report') 'Workflow must not publish the retired manual smoke artifact.'
Assert-True ($Workflow -notmatch '-Mode PackagedSmoke') 'Workflow must not select the monolithic PackagedSmoke gate anywhere.'
Assert-MatchCount $Workflow 'timeout-minutes:\s*1440' 0 'No job may hold the engine runner for a 24-hour bound.'
Assert-MatchCount $Workflow '(?m)^\s+runs-on: \[self-hosted, Windows, X64, aetheln-engine\]\r?$' 5 'Exactly five jobs (trusted compile plus four phases) may target the engine runner.'
Assert-MatchCount $Workflow '(?m)^\s+runs-on: windows-latest\r?$' 2 'Exactly two jobs (portable gates and the classifier) run on the GitHub-hosted runner.'

# Every engine-runner concurrency block queues FIFO without cancelling pending
# or in-progress work. queue: single would silently cancel a pending trusted
# compile; cancel-in-progress: true would cancel healthy milestone work.
Assert-MatchCount $Workflow '(?m)^\s+group: aetheln-engine-runner\r?$' 5 'Exactly five jobs must share the engine-runner concurrency group.'
Assert-MatchCount $Workflow '(?m)^\s+queue: max\r?$' 5 'Every engine-runner concurrency block must use queue: max so pending jobs wait FIFO instead of being replaced.'
Assert-MatchCount $Workflow '(?m)^\s+cancel-in-progress: false\r?$' 5 'Every engine-runner concurrency block must keep cancel-in-progress: false.'
Assert-True ($Workflow -notmatch '(?m)^\s+cancel-in-progress: true\r?$') 'No engine job may cancel in-progress work.'

# No job-level predicate may bypass a failed, cancelled, or skipped
# prerequisite: needs edges use the implicit success() only. always() is
# permitted solely as the bare step-level predicate on report uploads.
Assert-True ($Workflow -notmatch 'cancelled\(\)' -and $Workflow -notmatch 'failure\(\)' -and $Workflow -notmatch 'success\(\)') 'Workflow must not use explicit status functions in job predicates.'
Assert-MatchCount $Workflow 'always\(\)' ([regex]::Matches($Workflow, '(?m)^\s+if: always\(\)\r?$').Count) 'always() may appear only as the bare step-level upload predicate.'
Assert-True ($Workflow -notmatch 'needs\.[a-z-]+\.result') 'Workflow must not inspect needs results to run after a failed or skipped prerequisite.'

# GitHub-hosted jobs carry explicit conservative bounds.
Assert-True (([string] $JobBodies['quality-gates']) -match '(?m)^\s+timeout-minutes: 30\r?$') 'quality-gates must declare an explicit 30-minute bound.'
Assert-True (([string] $JobBodies['change-impact']) -match '(?m)^\s+timeout-minutes: 10\r?$') 'change-impact must declare an explicit 10-minute bound.'
Assert-True (([string] $JobBodies['change-impact']) -match "(?m)^\s+if: github\.event_name == 'pull_request'\r?$") 'change-impact must run only for pull requests.'
Assert-True (([string] $JobBodies['change-impact']) -notmatch 'aetheln-engine-runner') 'change-impact must never hold the engine-runner concurrency group.'

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
	Assert-MatchCount $Body '(?m)^\s+if: ' 2 "$($Phase.Job) must declare exactly one job-level trigger predicate plus the report-upload predicate."
	Assert-True ($Body -match $PhaseTrigger) "$($Phase.Job) must run only on the schedule event."
	Assert-True ($Body -notmatch 'workflow_dispatch' -and $Body -notmatch 'pull_request' -and $Body -notmatch "'push'") "$($Phase.Job) must not be selectable by dispatch, pull requests, or pushes."
	Assert-True ($Body -notmatch 'always\(\)\s*&&' -and $Body -notmatch '(?m)^\s+if:\s*always\(\)\s*\|\|' -and $Body -notmatch 'cancelled\(\)' -and $Body -notmatch 'failure\(\)') "$($Phase.Job) must not bypass a skipped, cancelled, or failed predecessor."
	Assert-True ($Body -match ('(?m)^\s+needs: ' + [regex]::Escape($Phase.Needs) + '\r?$')) "$($Phase.Job) must run strictly after $($Phase.Needs) and release the runner between phases."
	Assert-MatchCount $Body '(?m)^\s+needs:' 1 "$($Phase.Job) must declare exactly one predecessor."
	Assert-True ($Body -match ('(?m)^\s+timeout-minutes: ' + $Phase.JobTimeout + '\r?$')) "$($Phase.Job) must be bounded by timeout-minutes $($Phase.JobTimeout)."
	Assert-MatchCount $Body '(?m)^\s+timeout-minutes: ' 1 "$($Phase.Job) must declare exactly one job bound."
	Assert-MatchCount $Body ('(?m)^\s+-Mode ' + [regex]::Escape($Phase.Mode) + ' `\r?$') 1 "$($Phase.Job) must select mode $($Phase.Mode) exactly once."
	Assert-MatchCount $Body '(?m)^\s+-Mode ' 1 "$($Phase.Job) must invoke the gate exactly once."
	Assert-True ($Body -match ('(?m)^\s+-PhaseTimeoutMinutes ' + $Phase.PhaseTimeout + '\r?$')) "$($Phase.Job) must enforce the recorded $($Phase.PhaseTimeout)-minute script watchdog inside its job bound."
	Assert-True ([int] $Phase.PhaseTimeout -lt $Phase.JobTimeout) "$($Phase.Job) watchdog must expire before the total job bound so evidence is uploaded."
	Assert-MatchCount $Body ('(?m)^\s+name: ' + [regex]::Escape($Phase.Artifact) + '\r?$') 1 "$($Phase.Job) must upload its own distinct report artifact."
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
Assert-MatchCount ([string] $JobBodies['quality-gates']) '(?m)^\s+if: ' 1 'quality-gates must run unconditionally on every event; its only predicate is the report-upload always().'

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
Assert-True ($TrustedCompile -match '(?m)^\s+needs:\r?\n\s+- quality-gates\r?\n\s+- change-impact\r?$') 'Trusted compile must depend on exactly the portable gates and the change-impact classifier.'
Assert-True ($TrustedCompile -match "needs\.change-impact\.outputs\.engine_required == 'true'") 'Trusted compile must require the classifier to demand the engine.'
Assert-True ($TrustedCompile -match "github\.event_name == 'pull_request'") 'Trusted compile must remain a pull-request lane.'
Assert-True ($TrustedCompile -match 'github\.event\.pull_request\.head\.repo\.full_name == github\.repository' -and $TrustedCompile -match 'github\.event\.pull_request\.user\.login == github\.repository_owner' -and $TrustedCompile -match 'github\.triggering_actor == github\.repository_owner') 'Trusted compile must keep the owner and same-repository trust checks.'
Assert-True ($TrustedCompile -notmatch "github\.event_name == 'schedule'") 'Trusted compile must not be selectable by schedule.'
Assert-MatchCount $TrustedCompile 'always\(\)' 1 'Trusted compile may use always() only on its report upload, never to bypass a failed, cancelled, or skipped prerequisite.'
Assert-True ($TrustedCompile -match '(?m)^\s+if: always\(\)\r?$') 'Trusted compile must retain its report evidence on failure.'
Assert-True ($TrustedCompile -notmatch 'timeout-minutes:\s*1440') 'Trusted compile must not be a 24-hour job.'
Assert-True ($TrustedCompile -notmatch '-PhaseTimeoutMinutes' -and $TrustedCompile -notmatch '-RunId') 'Trusted compile must not depend on the scheduled handoff contract.'

# Operational caps and disjoint workspaces prevent repeated cold checkouts.
$SuiteSource = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts/ci/Invoke-CiSuite.ps1') -Raw
Assert-True ($SuiteSource -match "name = 'compile-workspace-tests'; tier = 'required'; script = 'tests/ci/Initialize-CompileWorkspace.Tests.ps1'") 'Retention helper fixtures must be a required serial CI gate.'
Assert-True ($TrustedCompile -match '(?m)^    timeout-minutes: 40\r?$') 'Compile must have a 40-minute whole-job cap.'
Assert-True ($TrustedCompile -match '-CompileTimeoutMinutes 30') 'Both compile targets must share the 30-minute watchdog.'
Assert-True ($TrustedCompile -match '(?m)^          path: compile\r?$' -and $TrustedCompile -match '(?m)^          clean: false\r?$') 'Only the dedicated compile checkout may retain outputs.'
Assert-True ($TrustedCompile -match 'Initialize-CompileWorkspace.ps1' -and $TrustedCompile -match 'working-directory: compile') 'Compile must execute the exact-retention helper inside its own checkout.'
Assert-True ($TrustedCompile.IndexOf('Initialize-CompileWorkspace.ps1') -lt $TrustedCompile.IndexOf('git lfs pull')) 'Retention preflight must run before engine inputs are used.'
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

# The decided scheduling policy values are recorded in canonical documentation

function Assert-ReportOnlyUploads([string] $Text) {
	$Blocks = @([regex]::Split($Text, '(?m)^      - ') | Where-Object { $_ -match '(?m)^\s*uses: actions/upload-artifact@' })
	Assert-True ($Blocks.Count -eq 6) 'Exactly six artifact-upload steps must exist.'
	$Allowed = @(
		'TestResults/ci-report.json',
		'milestone/TestResults/engine-runner-report.json',
		'${{ runner.temp }}/aetheln-engine-${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}/engine-runner-report.json'
	)
	foreach ($Block in $Blocks) {
		$Paths = @([regex]::Matches($Block, '(?m)^          path: ([^\r\n]+)\r?$'))
		Assert-True ($Paths.Count -eq 1) 'Every artifact step must declare exactly one path.'
		Assert-True ($Allowed -ccontains $Paths[0].Groups[1].Value) 'Every uploaded artifact must be an exact approved report path.'
	}
}
Assert-ReportOnlyUploads $Workflow
$ExtraUpload = $Workflow + [Environment]::NewLine + (@('      - uses: actions/upload-artifact@v4', '        with:', '          name: unexpected-payload', '          path: Saved') -join [Environment]::NewLine)
$ExtraRejected = $false
try { Assert-ReportOnlyUploads $ExtraUpload } catch { $ExtraRejected = $true }
Assert-True $ExtraRejected 'An added directory upload must fail even while all six reports remain.'
$WrongUpload = $Workflow.Replace('path: milestone/TestResults/engine-runner-report.json', 'path: Saved')
$WrongRejected = $false
try { Assert-ReportOnlyUploads $WrongUpload } catch { $WrongRejected = $true }
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
Assert-True ($CiDocumentation -notmatch 'workflow_dispatch' -and $CiDocumentation -notmatch '(?i)owner-dispatched|owner\s+dispatch') 'CI documentation must not advertise a manual dispatch entry point.'
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
Assert-True ($SchedulingDecision -match '(?m)^- \*\*Status:\*\* Accepted\r?$' -and $RunnerDecision -match '(?m)^- \*\*Status:\*\* Accepted\r?$') 'TA-011 and TA-012 must remain accepted decisions.'
Assert-True ($ArchitectureDecisions -notmatch 'workflow_dispatch' -and $ArchitectureDecisions -notmatch '(?i)owner-dispatched|owner\s+dispatch') 'Architecture decisions must not describe a manual dispatch entry point.'
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

# The portable CI exemption is a closed applicability decision, not a blanket
# scripts/workflows exemption or a replacement for independent review.
foreach ($Path in @('scripts/ci/Invoke-CiSuite.ps1', 'scripts/ci/Test-FormattingPolicy.ps1', 'scripts/ci/Test-MarkdownLinks.ps1', '.github/workflows/prototype-quality-gates.yml', 'scripts/build/Build-PackagedArtifacts.ps1', 'scripts/build/Invoke-PackagedSmokeTest.ps1', 'scripts/ci/Invoke-EngineRunnerGate.ps1', 'scripts/ci/Initialize-CompileWorkspace.ps1')) {
	Assert-True ($SchedulingDecision.Contains('`' + $Path + '`')) "TA-012 must record the exact portable CI exemption '$Path'."
	Assert-True ($CiDocumentation.Contains('`' + $Path + '`')) "CI documentation must record the exact portable CI exemption '$Path'."
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
exit 0
