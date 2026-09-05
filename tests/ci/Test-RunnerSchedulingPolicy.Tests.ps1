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
Assert-True (([string] $JobBodies['quality-gates']) -match '(?m)^\s+timeout-minutes: 60\r?$') 'quality-gates must declare an explicit 60-minute bound.'
Assert-True (([string] $JobBodies['change-impact']) -match '(?m)^\s+timeout-minutes: 10\r?$') 'change-impact must declare an explicit 10-minute bound.'
Assert-True (([string] $JobBodies['change-impact']) -match "(?m)^\s+if: github\.event_name == 'pull_request'\r?$") 'change-impact must run only for pull requests.'
Assert-True (([string] $JobBodies['change-impact']) -notmatch 'aetheln-engine-runner') 'change-impact must never hold the engine-runner concurrency group.'

# The milestone is split into four bounded phases that run only on the daily
# schedule and only after the portable gates pass; pull requests and pushes
# cannot enter them and no manual trigger exists. Job timeout-minutes is the
# total concurrency-holding bound for the phase (480/720/60/120), and every
# phase runs its work under a cooperative script deadline (450/690/45/105) plus
# the gate's supervisor hard bound (deadline plus a finalization grace capped at
# 600 seconds) that together expire early enough inside the job bound to record
# and upload phase_timeout evidence before platform cancellation.
$PhaseTrigger = "(?m)^\s+if: github\.event_name == 'schedule'\r?$"
$PhaseContract = @(
	@{ Job = 'scheduled-client-package'; Needs = 'quality-gates'; JobTimeout = 480; Mode = 'PackageClient'; PhaseTimeout = '450'; Artifact = 'engine-runner-client-package-report' },
	@{ Job = 'scheduled-server-package'; Needs = 'scheduled-client-package'; JobTimeout = 720; Mode = 'PackageServer'; PhaseTimeout = '690'; Artifact = 'engine-runner-server-package-report' },
	@{ Job = 'scheduled-provenance-validation'; Needs = 'scheduled-server-package'; JobTimeout = 60; Mode = 'ValidateProvenance'; PhaseTimeout = '45'; Artifact = 'engine-runner-provenance-validation-report' },
	@{ Job = 'scheduled-packaged-smoke'; Needs = 'scheduled-provenance-validation'; JobTimeout = 120; Mode = 'SmokePhase'; PhaseTimeout = '105'; Artifact = 'engine-runner-scheduled-smoke-report' }
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

# Reports remain the only uploads.
$UploadPaths = @([regex]::Matches($Workflow, '(?m)^\s+path:\s*(TestResults/[^\r\n]+)\r?$') | ForEach-Object { $_.Groups[1].Value.Trim() })
Assert-True ($UploadPaths.Count -eq 6) 'Workflow must publish exactly one JSON report per portable or engine job.'
foreach ($UploadPath in $UploadPaths) {
	Assert-True ($UploadPath -match '^TestResults/(ci-report|engine-runner-report)\.json$') "Upload path '$UploadPath' must be an approved JSON report."
}
Assert-True ($Workflow -notmatch '(?m)^\s+path:\s*.*(?:archives?|logs?|Saved|StagedBuilds)') 'Workflow must not upload packages, archives, logs, or generated Unreal output.'

# The decided scheduling policy values are recorded in canonical documentation
# with truthful semantics: the 12-hour value is the maximum delay attributable
# to one currently running scheduled phase, not an absolute guarantee.
Assert-True ($CiDocumentation -match '(?i)maximum\s+trusted-compile\s+queue\s+delay') 'CI documentation must record the trusted-compile queue-delay policy.'
Assert-True ($CiDocumentation -match '(?i)12-hour|12\s*hours') 'CI documentation must record the 12-hour queue-delay value.'
Assert-True ($CiDocumentation -match '(?i)attributable\s+to\s+one\s+currently\s+running\s+scheduled\s+phase') 'CI documentation must scope the 12-hour value to a single running scheduled phase.'
Assert-True ($CiDocumentation -match '(?i)no\s+absolute\s+priority\s+guarantee') 'CI documentation must state that this topology has no absolute priority guarantee.'
Assert-True ($CiDocumentation -match '(?i)total\s+queue\s+time\s+can\s+be\s+longer') 'CI documentation must state that older queued jobs can extend the total wait.'
Assert-True ($CiDocumentation -match 'AETHELN_HANDOFF_ROOT') 'CI documentation must document the durable handoff root provisioning.'
foreach ($Value in @('480', '720', '60', '120')) {
	Assert-True ($CiDocumentation -match $Value) "CI documentation must record the $Value-minute total phase bound."
}
foreach ($Value in @('450', '690', '45', '105')) {
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

Write-Output 'PASS: milestone phases are bounded, FIFO-queued, evidence-separated, schedule-only, gated behind portable success, and cannot starve trusted compile for 24 hours'
Write-Output 'PASS: trusted compile requires portable success and an engine-impacting change; no manual or monolithic package/smoke entry point remains'
exit 0
