[CmdletBinding()]
param()

# Sole purpose: validate the Issue #150 engine-runner scheduling contract —
# bounded scheduled milestone phases, FIFO queueing that cannot cancel pending
# or in-progress work, recorded trusted-compile queue-delay policy, and
# evidence separation per phase.

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

$JobOrder = @('quality-gates', 'trusted-candidate-compile', 'scheduled-client-package', 'scheduled-server-package', 'scheduled-provenance-validation', 'scheduled-packaged-smoke', 'manual-packaged-smoke')
$JobBodies = @{}
for ($Index = 1; $Index -lt $JobOrder.Count; $Index++) {
	$Start = $Workflow.IndexOf("  $($JobOrder[$Index - 1]):", [StringComparison]::Ordinal)
	$End = $Workflow.IndexOf("  $($JobOrder[$Index]):", [StringComparison]::Ordinal)
	Assert-True ($Start -ge 0 -and $End -gt $Start) "Workflow must define job '$($JobOrder[$Index - 1])' before '$($JobOrder[$Index])'."
	$JobBodies[$JobOrder[$Index - 1]] = $Workflow.Substring($Start, $End - $Start)
}
$JobBodies['manual-packaged-smoke'] = $Workflow.Substring($Workflow.IndexOf('  manual-packaged-smoke:', [StringComparison]::Ordinal))

# Every engine-runner concurrency block queues FIFO without cancelling pending
# or in-progress work. queue: single would silently cancel a pending trusted
# compile; cancel-in-progress: true would cancel healthy milestone work.
Assert-MatchCount $Workflow '(?m)^\s+group: aetheln-engine-runner\r?$' 6 'Exactly six jobs must share the engine-runner concurrency group.'
Assert-MatchCount $Workflow '(?m)^\s+queue: max\r?$' 6 'Every engine-runner concurrency block must use queue: max so pending jobs wait FIFO instead of being replaced.'
Assert-MatchCount $Workflow '(?m)^\s+cancel-in-progress: false\r?$' 6 'Every engine-runner concurrency block must keep cancel-in-progress: false.'
Assert-True ($Workflow -notmatch '(?m)^\s+cancel-in-progress: true\r?$') 'No engine job may cancel in-progress work.'

# The scheduled milestone is split into four bounded phases. Job
# timeout-minutes is the total concurrency-holding bound for the phase
# (480/720/60/120), and every phase runs its work under a cooperative script
# deadline (450/690/45/105) plus the gate's supervisor hard bound (deadline
# plus a finalization grace capped at 600 seconds) that together expire early
# enough inside the job bound to record and upload phase_timeout evidence
# before platform cancellation.
$PhaseContract = @(
	@{ Job = 'scheduled-client-package'; Needs = $null; JobTimeout = 480; Mode = 'PackageClient'; PhaseTimeout = '450'; Artifact = 'engine-runner-client-package-report' },
	@{ Job = 'scheduled-server-package'; Needs = 'scheduled-client-package'; JobTimeout = 720; Mode = 'PackageServer'; PhaseTimeout = '690'; Artifact = 'engine-runner-server-package-report' },
	@{ Job = 'scheduled-provenance-validation'; Needs = 'scheduled-server-package'; JobTimeout = 60; Mode = 'ValidateProvenance'; PhaseTimeout = '45'; Artifact = 'engine-runner-provenance-validation-report' },
	@{ Job = 'scheduled-packaged-smoke'; Needs = 'scheduled-provenance-validation'; JobTimeout = 120; Mode = 'SmokePhase'; PhaseTimeout = '105'; Artifact = 'engine-runner-scheduled-smoke-report' }
)
foreach ($Phase in $PhaseContract) {
	$Body = [string] $JobBodies[$Phase.Job]
	Assert-True ($Body -match "if:\s*github\.event_name == 'schedule'") "$($Phase.Job) must run only on the schedule event."
	if ($Phase.Needs) {
		Assert-True ($Body -match ('(?m)^\s+needs: ' + [regex]::Escape($Phase.Needs) + '\r?$')) "$($Phase.Job) must run strictly after $($Phase.Needs) and release the runner between phases."
	} else {
		Assert-True ($Body -notmatch '(?m)^\s+needs:') "$($Phase.Job) must be the first milestone phase."
	}
	Assert-True ($Body -match ('(?m)^\s+timeout-minutes: ' + $Phase.JobTimeout + '\r?$')) "$($Phase.Job) must be bounded by timeout-minutes $($Phase.JobTimeout)."
	Assert-MatchCount $Body ('(?m)^\s+-Mode ' + [regex]::Escape($Phase.Mode) + ' `\r?$') 1 "$($Phase.Job) must select mode $($Phase.Mode) exactly once."
	Assert-True ($Body -match ('(?m)^\s+-PhaseTimeoutMinutes ' + $Phase.PhaseTimeout + '\r?$')) "$($Phase.Job) must enforce the recorded $($Phase.PhaseTimeout)-minute script watchdog inside its job bound."
	Assert-True ([int] $Phase.PhaseTimeout -lt $Phase.JobTimeout) "$($Phase.Job) watchdog must expire before the total job bound so evidence is uploaded."
	Assert-MatchCount $Body ('(?m)^\s+name: ' + [regex]::Escape($Phase.Artifact) + '\r?$') 1 "$($Phase.Job) must upload its own distinct report artifact."
	Assert-True ($Body -match '(?m)^\s+if: always\(\)\r?$') "$($Phase.Job) must retain its report evidence even on failure or timeout."
	Assert-True ($Body -notmatch '(?m)^\s+-Mode (Compile|PackagedSmoke) `\r?$') "$($Phase.Job) must not select a non-phase gate mode."
	foreach ($Binding in @('-Repository ''\$\{\{ github\.repository \}\}''', '-RunId ''\$\{\{ github\.run_id \}\}''', '-RunAttempt ''\$\{\{ github\.run_attempt \}\}''', '-RunnerName ''\$\{\{ runner\.name \}\}''')) {
		Assert-True ($Body -match $Binding) "$($Phase.Job) must bind the exact handoff context ($Binding)."
	}
}

# Package phases need full Content LFS; the later phases consume only verified
# handoff payloads and must not depend on residual workspace or LFS state.
foreach ($Job in @('scheduled-client-package', 'scheduled-server-package')) {
	Assert-True (([string] $JobBodies[$Job]) -match 'git lfs pull --include "Content/\*\*"') "$Job must materialize every Unreal Content LFS object before packaging."
}

# The trusted compile lane keeps its own contract: no 24-hour bound, no
# handoff coupling, so an unset AETHELN_HANDOFF_ROOT can never affect it.
$TrustedCompile = [string] $JobBodies['trusted-candidate-compile']
Assert-True ($TrustedCompile -notmatch 'timeout-minutes:\s*1440') 'Trusted compile must not be a 24-hour job.'
Assert-True ($TrustedCompile -notmatch '-PhaseTimeoutMinutes' -and $TrustedCompile -notmatch '-RunId') 'Trusted compile must not depend on the scheduled handoff contract.'
Assert-MatchCount $Workflow 'timeout-minutes:\s*1440' 1 'Only the owner-dispatched manual milestone may keep the 24-hour bound.'

# Reports remain the only uploads.
$UploadPaths = @([regex]::Matches($Workflow, '(?m)^\s+path:\s*(TestResults/[^\r\n]+)\r?$') | ForEach-Object { $_.Groups[1].Value.Trim() })
Assert-True ($UploadPaths.Count -eq 7) 'Workflow must publish exactly one JSON report per portable or engine job.'
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

Write-Output 'PASS: scheduled milestone phases are bounded, FIFO-queued, evidence-separated, and cannot starve trusted compile for 24 hours'
Write-Output 'PASS: recorded queue-delay policy, handoff provisioning, and cleanup-request model are documented'
exit 0
