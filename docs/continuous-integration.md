# Continuous Integration

## Purpose and Ownership

This document records the prototype continuous-integration quality gates
introduced by [Issue #16](https://github.com/ShayShimoni/aetheln-online/issues/16),
which owns CI execution, runner requirements, and evidence publication under
[Performance, Quality, and Delivery](performance-quality-and-delivery.md).
The CI Foundation includes repository and generated-artifact policy checks,
formatting/indentation and available static checks, focused automation,
artifact/dependency/secret policy checks, supported-target compilation,
packaged-build smoke, and machine-readable evidence publication.

This document and workflow do not implement:

- Rejection telemetry, owned by
  [Issue #38](https://github.com/ShayShimoni/aetheln-online/issues/38).
- Executable multiplayer scenarios, owned by
  [Issue #44](https://github.com/ShayShimoni/aetheln-online/issues/44).
- Measured performance budgets, owned by
  [Issue #45](https://github.com/ShayShimoni/aetheln-online/issues/45).

[Issue #85](https://github.com/ShayShimoni/aetheln-online/issues/85) supplies
the repository-owned headless Unreal automation harness described in
[Unreal Automation](unreal-automation.md). Issue #16 owns where and when CI
invokes that engine-dependent harness; Issues #44 and #45 retain their
multiplayer-scenario and performance-evidence scopes.

## Local Invocation

Run the full suite from the repository root:

```powershell
powershell -NoProfile -File scripts/ci/Invoke-CiSuite.ps1
```

The runner executes every check in a child Windows PowerShell process, prints
a summary table plus the command and captured output tail for each failure,
writes the machine-readable report to `TestResults/ci-report.json`
(`TestResults/` is gitignored), and exits nonzero when a required check or the
runner infrastructure fails. Ordinary advisory-check failures alone do not
fail the suite. Individual checks can also be run directly, for example:

```powershell
powershell -NoProfile -File scripts/ci/Test-FormattingPolicy.ps1
powershell -NoProfile -File scripts/ci/Test-MarkdownLinks.ps1
powershell -NoProfile -File scripts/tests/Test-SourceControlPolicy.ps1
powershell -NoProfile -File scripts/tests/Test-ObservabilityContract.ps1
```

The portable runner uses at most two concurrent checks from this closed set:
`build-packaged-artifacts-tests`, `network-authority-spike-tests`,
`engine-runner-gate-tests`, and `unreal-automation-tests`.
`packaged-smoke-test-tests` remains required but runs serially: its package-process
quiescence fixture exposed an unresolved concurrent-run failure. Its concurrency
eligibility is withdrawn, not its assertions or deadlines. A passing serial run
does not establish the cause of that failure. Every other check is also a serial
barrier: preceding checks
finish before it starts, and subsequent checks wait for it to finish. Checks
launch in manifest order, and report rows retain that order even when checks
finish out of order. No check or existing fixture deadline is removed.

Each hidden check process tree belongs to a private kill-on-close Windows Job
Object before the check starts. Parent termination closes its owned trees,
not unrelated PowerShell processes. After the root exits, job accounting has a
bounded five-second monotonic quiescence grace; a transient termination count
does not replace the check's actual exit code or completed-result requirement.
This grace is separate from the bootstrap's five-second post-exit pipe drain.
A persistent descendant, incomplete result,
or launch/capture failure fails the suite even for an advisory check. Both
output streams are drained concurrently; diagnostics written before a
post-exit pipe failure are retained. Module-unavailable skips keep their
explicit reasons. This scheduling improvement runs fixture processes, not
Unreal builds, and does not establish an engine compile or packaging speedup.

With the pinned source engine already built, run the real headless Unreal tests
locally by passing its explicit non-secret path:

```powershell
$AethelnEngineRoot = 'D:\UnrealEngine\UE-5.8.1-source'
powershell -NoProfile -File scripts/ci/Invoke-UnrealAutomationTests.ps1 `
  -EngineRoot $AethelnEngineRoot
```

The default timeout is 600 seconds. Full discovery, result, output, and failure
semantics are documented in [Unreal Automation](unreal-automation.md).

## Required and Advisory Checks

| Check | Tier | What it gates |
| --- | --- | --- |
| `formatting-policy` (`scripts/ci/Test-FormattingPolicy.ps1`) | Required | Tracked text is stored LF, no merge-conflict markers, tab indentation in `Source/` C++. Deterministic repository policy. |
| `markdown-links` (`scripts/ci/Test-MarkdownLinks.ps1`) | Required | Relative links and heading anchors in tracked Markdown resolve. Deterministic documentation gate. |
| `source-control-policy` (`scripts/tests/Test-SourceControlPolicy.ps1`) | Required | LFS ownership, generated-artifact exclusions, and sensitive-path (dependency/secret) tracking policy. |
| `observability-contract` (`scripts/tests/Test-ObservabilityContract.ps1`) | Required | Closed observability vocabulary, bounded/redacted event shape, explicit environment/retention boundaries, and downstream ownership. |
| `build-packaged-artifacts-tests` (`tests/build/Build-PackagedArtifacts.Tests.ps1`) | Required | Focused automation for the packaging entry point. |
| `packaged-smoke-test-tests` (`tests/build/Invoke-PackagedSmokeTest.Tests.ps1`) | Required | Focused automation for the smoke orchestrator logic. |
| `server-cook-reference-tests` (`tests/build/Validate-ServerCookReferences.Tests.ps1`) | Required | Focused automation for server cook reference rules. |
| `target-composition-tests` (`tests/build/Validate-TargetComposition.Tests.ps1`) | Required | Focused automation for client/server module composition rules. |
| `build-provenance-tests` (`tests/build/Write-BuildProvenance.Tests.ps1`) | Required | Focused automation for build provenance recording. |
| `network-authority-spike-tests` (`tests/build/Invoke-NetworkAuthoritySpike.Tests.ps1`) | Required | Fixture-only validation of the existing authority runner, including versioned six-profile selection, exact join/play/death/respawn/disconnect/reconnect/shutdown ordering, normalized role/stage failures, and cleanup evidence. It does not execute packaged Unreal processes. |
| `markdown-link-tests` (`tests/ci/Test-MarkdownLinks.Tests.ps1`) | Required | Fixture regression tests for the link checker itself. |
| `formatting-policy-tests` (`tests/ci/Test-FormattingPolicy.Tests.ps1`) | Required | Fixture regression tests for the formatting checker itself. |
| `observability-contract-tests` (`tests/ci/Test-ObservabilityContract.Tests.ps1`) | Required | Fixture regression tests proving the observability checker accepts the bounded contract and fails closed on a sensitive free-form field. |
| `ci-suite-tests` (`tests/ci/Invoke-CiSuite.Tests.ps1`) | Required | Fixture regression tests for the runner, report schema, and exit codes. |
| `engine-runner-gate-tests` (`tests/ci/Invoke-EngineRunnerGate.Tests.ps1`) | Required | Fixture regression tests for engine-runner input validation, command selection, repository-state enforcement, redacted failures, report schema, report-only compile evidence extraction, and exit codes. |
| `engine-runner-post-command-state-tests` (`tests/ci/Invoke-EngineRunnerPostCommandState.Tests.ps1`) | Required | Fixture regression tests for repository-state checks after engine commands, including command failures. |
| `prototype-quality-workflow-tests` (`tests/ci/Test-PrototypeQualityWorkflow.Tests.ps1`) | Required | Workflow event, trust, dependency, artifact, checkout, and change-impact classification contracts. |
| `runner-scheduling-policy-tests` (`tests/ci/Test-RunnerSchedulingPolicy.Tests.ps1`) | Required | Bounded runner scheduling, milestone phase, and retained Compile workspace policy contracts. |
| `compile-workspace-tests` (`tests/ci/Initialize-CompileWorkspace.Tests.ps1`) | Required | Exact output retention across revisions, scoped cleanup, unsafe-path rejection and preserved tracked source. Runs as a serial barrier. |
| `unreal-automation-tests` (`tests/ci/Invoke-UnrealAutomationTests.Tests.ps1`) | Required | Portable fixture regression tests for the headless Unreal runner's engine pin, discovery, repository-state, timeout, report validation, and fail-closed exit behavior. |
| `psscriptanalyzer` (`Invoke-ScriptAnalyzer` over `scripts/` and `tests/`) | Advisory | PowerShell static analysis. Advisory because the module is not guaranteed on contributor machines (the check reports `skipped` when it is absent) and the pre-existing finding baseline has not been triaged into a gate. |

Required checks fail the suite and the workflow. Ordinary advisory-check
failures are reported in the same machine-readable evidence without failing
the suite; runner infrastructure failures always fail closed. The live
supported-target compile and packaged-smoke jobs are also required gates when
their event and trust predicates select them.

The suite deliberately excludes two existing test groups:

- `.agents/skills/orchestrate-delivery/scripts/tests/` exercises delivery
  orchestration tooling, not the shipped repository, and has its own harness.
- `visuals/tests/` is owned by the frozen `visual-package-validation.yml`
  workflow described below and only needs to run when the visual package
  changes.

## Workflow Execution

`.github/workflows/prototype-quality-gates.yml` accepts exactly three events:
`pull_request`, `push` to `develop`, and the daily `schedule`. It declares no
manual trigger: a manual trigger on this workflow identity would let an
operator select an older branch that still carries the retired 1,440-minute
`PackagedSmoke` job, so none exists and no replacement manual workflow is
provided. The `quality-gates` job runs the portable suite on every event, on a
GitHub-hosted `windows-latest` runner bounded at 30 minutes. That job checks
out without LFS smudge, fetches only the
`Content/Maps/StarterMap.umap` LFS object required by the source-control policy
check, runs the local invocation above, and always uploads
`TestResults/ci-report.json` as the `ci-report` artifact.
The required `unreal-automation-tests` check exercises portable fixtures and
does not launch Unreal Engine. The GitHub-hosted portable job does not run the
real engine automation tests.

Every engine job depends on `quality-gates`: `trusted-candidate-compile` and
milestone phase 1 (`scheduled-client-package`) declare `needs: quality-gates`
with the implicit success condition and no status-function bypass, so a
portable failure, cancellation, or skip keeps every engine job off the
self-hosted runner. Phases 2 to 4 chain through phase 1.

### Pull-request change-impact classifier

The `change-impact` job (GitHub-hosted `windows-latest`, `pull_request` only,
bounded at 10 minutes) decides whether a pull request needs trusted Unreal
compilation. It uses `actions/checkout@v4` and repository-owned PowerShell
only; no third-party action. The exact pull-request base SHA and head SHA
enter the script through `env` (never interpolated into the script body), the
script verifies both commits are present (fetching each by SHA from `origin`
only when missing), and diffs the two trees with
`git diff --name-status --no-renames <base> <head>` so every entry is an
add, modify, delete, or type change. It publishes the job output
`engine_required` (`true` or `false`) plus a stable `reason` code and one
concise `GITHUB_STEP_SUMMARY` line.

`engine_required=false` is emitted only when every changed path belongs to
this closed, case-sensitive portable-only set:

- `docs/**`
- `visuals/**`
- `output/pdf/**`
- `tests/**` when every changed file there is `.ps1` or `.md`
- top-level `.md` files
- GitHub issue or pull-request template Markdown or YAML files under
  `.github/ISSUE_TEMPLATE/` or `.github/PULL_REQUEST_TEMPLATE/`, or the
  top-level `.github/PULL_REQUEST_TEMPLATE.md`
- Exactly `scripts/ci/Invoke-CiSuite.ps1`,
  `scripts/ci/Test-FormattingPolicy.ps1`,
  `scripts/ci/Test-MarkdownLinks.ps1`, and
  `.github/workflows/prototype-quality-gates.yml`
- Exactly `scripts/build/Build-PackagedArtifacts.ps1`,
  `scripts/ci/Invoke-EngineRunnerGate.ps1`, and
  `scripts/ci/Initialize-CompileWorkspace.ps1`

The four exact CI paths are the lead's 2026-09-06 applicability decision under
the user's CI-improvement authorization, recorded in TA-012. Unreal compilation
does not validate portable scheduling, policy checks, or workflow YAML logic.
The required portable suite (including its runner, formatting, Markdown,
workflow, and scheduling-policy fixture suites) and independent review remain
mandatory for these changes. This is not a blanket scripts or workflow
exemption: matching uses exact case-sensitive paths, not prefixes, filename
lookalikes, or extension substitutions. Passing local fixtures does not prove
live workflow activation, engine execution, or scheduled milestone completion.

The three exact orchestration additions follow the owner's CI-redesign
authorization and independent applicability review on 2026-09-06. Their PR
gates are the full required portable suite (including packaging, gate,
post-command-state and retention fixtures) plus independent review. Compile
does not execute the packaging controller; it does exercise the wrapper and
retention helper against a real engine, so that integration coverage remains
an explicitly separate bounded operational proof, not an asserted pass.
Revisit these exceptions if an orchestration script begins generating engine
inputs. A simultaneous engine-input change still requires compilation.

Everything else requires compile, including `Source/**`, `Config/**`,
`Content/**`, `Plugins/**`, other `scripts/**`, other `.github/workflows/**`, and
`AethelnOnline.uproject`. Mixed changes require compile. The step always exits
0 so the decision is always published, and every uncertainty fails closed to
`engine_required=true`:

| `reason` | `engine_required` | Meaning |
| --- | --- | --- |
| `portable_paths_only` | `false` | Every changed path is in the portable-only set. |
| `engine_paths_changed` | `true` | At least one changed path is outside the set (the summary lists up to 20). |
| `invalid_sha` | `true` | A SHA is missing or is not exactly 40 lowercase hex characters. |
| `identical_shas` | `true` | Base and head SHAs are equal. |
| `commit_unavailable` | `true` | A commit is absent locally and could not be fetched from `origin`. |
| `diff_failed` | `true` | Git returned a nonzero exit code for the diff. |
| `empty_diff` | `true` | The diff produced no entries. |
| `unexpected_diff_entry` | `true` | An entry was not `A`/`M`/`D`/`T` with a plain path (quoted, rename, or copy entries). |
| `classifier_error` | `true` | Any other exception inside the classifier. |

If the classifier job itself fails before the script publishes an output (a
lost runner or a checkout error), `trusted-candidate-compile` is skipped, not
run; the failed `change-impact` check is visible on the pull request and a
rerun restores the decision. This is the one path where uncertainty does not
produce a compile, and it never bypasses the portable gates.

Engine-dependent jobs use a repository-scoped Windows self-hosted runner with
labels `[self-hosted, Windows, X64, aetheln-engine]` and serialize through the
`aetheln-engine-runner` concurrency group with `queue: max` and
`cancel-in-progress: false`, so queued engine jobs wait in FIFO order by
wait-start time (GitHub documents this ordering without guaranteeing it
absolutely) and never cancel a pending or in-progress engine job. Before compiling, packaging, or cooking, each engine job that
builds fetches all Unreal Content LFS objects with
`git lfs pull --include "Content/**"`. Their event, dependency, and trust
contract is:

| Job | Event | `needs` | Trust predicate | Gate |
| --- | --- | --- | --- | --- |
| `trusted-candidate-compile` | `pull_request` | `quality-gates`, `change-impact` | `engine_required == 'true'`, the head repository is this repository, the PR author is the repository owner, and `github.triggering_actor` is the repository owner. | Incrementally compile the supported Windows client and Linux server targets without packaging. |
| `scheduled-client-package` | `schedule` at `02:00 UTC` daily | `quality-gates` | Schedule-only; the schedule exists only on the protected default branch once this workflow reaches `main` through normal Git Flow. | Milestone phase 1: clean-package the Windows client and publish it to the durable handoff store. |
| `scheduled-server-package` | `schedule` | `scheduled-client-package` | Same as phase 1. | Milestone phase 2: clean-package the Linux dedicated server, dump its registry evidence, and publish both to the handoff store. |
| `scheduled-provenance-validation` | `schedule` | `scheduled-server-package` | Same as phase 1. | Milestone phase 3: verify both handoff payloads, validate server cook references, and write bound provenance. |
| `scheduled-packaged-smoke` | `schedule` | `scheduled-provenance-validation` | Same as phase 1. | Milestone phase 4: verify every handoff payload and smoke the packaged client/server pair. |

The four phases are schedule-only and keep the same `needs` chain, job
bounds, concurrency block, handoff contract, and per-phase artifacts. There is
no single-job package and smoke entry point: no workflow job selects the
gate's `PackagedSmoke` mode or holds the engine runner for a 24-hour bound.
Pull requests and pushes cannot start any of the four phases, and no manual
trigger exists.

Per event, the jobs that can run are:

| Event | `quality-gates` | `change-impact` | `trusted-candidate-compile` | Phases 1 to 4 |
| --- | --- | --- | --- | --- |
| `pull_request` | Runs | Runs | Only after both prerequisites succeed, `engine_required == 'true'`, and the trust predicate holds | Skipped |
| `push` to `develop` | Runs | Skipped | Skipped | Skipped |
| `schedule` | Runs | Skipped | Skipped | Phase 1 only after `quality-gates` succeeds; each later phase only after its predecessor succeeds |

`develop` remains the integration branch. Merely adding the schedule on a
feature or `develop` branch does not activate it; GitHub schedules run from the
default branch. Fork pull requests, collaborator-authored pull requests, and
collaborator-triggered reruns cannot select the engine jobs. Future collaborator
access requires a separate security and topology review.

## Engine-Runner Scheduling Policy (Issue #150)

Recorded priority: `trusted-candidate-compile` outranks *starting* the next
dependent scheduled milestone phase; it never cancels an in-progress phase
merely because a pull request queued, and it does not jump ahead of an older
queued pull-request job. This topology has **no absolute priority
guarantee**: GitHub Actions has no job priority, `queue: max` orders waiting
jobs FIFO by wait-start time while GitHub does not guarantee overall ordering,
and runner assignment adds platform latency.

The recorded **40-minute** value is therefore precise: it is the maximum
trusted-compile queue delay **attributable to one currently running scheduled
phase** (the longest total phase bound, the 40-minute client or server package),
subject to platform assignment latency. Total queue time can be longer when
older jobs are already ahead in the queue (for example earlier pull-request
compiles, or a scheduled milestone whose next phase queued earlier). These
bounds are
revisited only from retained phase evidence and are never silently raised.

The mechanism: each scheduled phase job reacquires the `aetheln-engine-runner`
concurrency group, so a trusted compile that queued during phase *k* starts
before the dependent phase *k+1*, whose queue wait starts only when phase *k*
completes. Each job `timeout-minutes` is the **total concurrency-holding
bound** for that phase — checkout, LFS materialization, the gate script, and
evidence upload all fit inside it — and the gate enforces a **hard bound over
its whole controlled script interval**. A supervising parent re-invokes the
gate as a child tree owned by a kill-on-close Windows Job Object; the complete
phase body — setup, handoff validation, cleanup scanning, root accounting,
manifest reads, payload hashing, smoke discovery, the build/smoke work, and
timeout finalization — runs inside that tree. The child keeps the cooperative
**absolute script-phase deadline** established immediately after input
validation (every operation consumes the remaining time from that single
deadline; the build/smoke grandchild never receives a fresh full watchdog
duration and is never started once the deadline has expired), which yields
precise per-check timeout evidence while operations stay responsive. If any
single synchronous operation — a payload hash, a JSON read, a direct Git call,
a discovery or cleanup scan — or the post-timeout finalization itself blocks
across the deadline, the parent stops and verifies the whole child tree at the
deadline plus a bounded finalization grace (`-PhaseFinalizeGraceSeconds`,
default 120 seconds, validated and capped at 600), classifies `phase_timeout`
(or `phase_cleanup_failed` when tree termination cannot be verified), and
writes the bounded report itself. Publication is best effort within remaining
job time, not guaranteed before platform cancellation: checkout/LFS and grace
also consume that budget. Missing evidence never establishes success.
Checkout/LFS and the report upload sit only inside the workflow job
bound; no report can be preserved if the platform kills the job before the
gate script starts:

| Phase | Total job bound (`timeout-minutes`) | Script watchdog (`-PhaseTimeoutMinutes`) |
| --- | --- | --- |
| Client package | 40 minutes | 30 |
| Server package | 40 minutes | 30 |
| Registry/provenance validation | 20 minutes | 10 |
| Packaged smoke | 20 minutes | 10 |

Reaching the deadline is an explicit `phase_timeout` failure, whether it
expires during controlled pre-work between operations (the bounded report is
still written and retained, and the build/smoke grandchild is not started),
inside a single blocking synchronous operation (the supervisor hard bound
interrupts it), or during the build/smoke work: on timeout the gate terminates
the owned Job Object and verifies its active-process count reaches zero while
retaining the handle. Bounded `taskkill /T /F` is only a fallback and must be
followed by the same owned-job accounting before disposal. The gate rejects partial outputs
(an unpublished integrity manifest can never be consumed, and a timed-out
smoke never publishes a completion marker), attempts to retain the bounded report
through the `if: always()` upload within the remaining platform budget, and the next scheduled attempt restarts the
complete milestone from clean inputs. If the gate cannot prove the process
tree ended, it fails closed as `phase_cleanup_failed` instead of releasing the
concurrency group as a plain timeout. A newly queued pull request never
cancels healthy in-progress work, and a later phase can never convert an
earlier phase's failure or timeout into success.

### Durable run-scoped handoff store

`runner.temp` is emptied at the beginning and end of every job, so milestone
phases exchange packaged bytes only through a durable store under the
non-secret user-level variable `AETHELN_HANDOFF_ROOT` (provisioned once by the
owner exactly like the engine and toolchain variables; the runner service must
be restarted after defining it). The configured absolute path is never printed
in uploaded evidence. The root must be an existing directory on a local fixed
drive — UNC, network, mapped, and other non-local roots are rejected — outside
the repository, engine root, toolchain root, `runner.temp`, and workspace,
with no reparse points, accessible only to the runner account. Before every
create, read, hash, write, consume, or cleanup traversal the gate revalidates
each existing path component from the configured root down (resolved
containment plus no reparse point anywhere on the chain), and every recursive
walk refuses to follow reparse points.

Each run attempt owns exactly one directory,
`<root>/<owner>/<repo>/run-<run id>-attempt-<run attempt>` (owner and
repository are separate validated path components, so distinct repositories
can never collide), never reused or overwritten. When the first phase reserves
the run directory it atomically writes a closed schema-v1 **run-context
record** binding the exact repository, source SHA, run id, run attempt, and
producing runner name; every later phase validates that record fail-closed
before any work. Every producing phase writes its payload and then an atomic
schema-v1 **integrity manifest** binding the same context plus expected
consuming phases, normalized relative file paths, byte sizes, total bytes, and
lowercase SHA-256 digests. Manifests, run-context records, and completion
markers are validated as **closed** documents: exactly the allowed properties
with validated types and ranges, duplicate JSON properties rejected, unique
canonical relative paths with no duplicate or case-colliding entries, and
overflow-safe byte accounting. Every consumer revalidates the complete
manifest and payload before any use — including exact path-set equality
between the manifest and the actual payload files, so an omitted, extra,
duplicated, or substituted file always fails — with stable reason codes
(`handoff_root_unset`, `handoff_root_invalid`, `handoff_context_invalid`,
`handoff_conflict`, `handoff_missing`, `handoff_schema_invalid`,
`handoff_context_mismatch`, `handoff_runner_mismatch`,
`handoff_digest_mismatch`, `handoff_size_exceeded`, `handoff_payload_invalid`,
`handoff_storage_exhausted`, `phase_timeout`, `phase_cleanup_failed`). The
runner-name binding makes a future second matching runner fail closed instead
of silently missing or accepting foreign state. An unset or invalid
`AETHELN_HANDOFF_ROOT` fails only the scheduled phase jobs with a stable
redacted setup code; portable checks and `trusted-candidate-compile` are
unaffected.

Bounds: at most **64 GiB** of payload per run attempt — one cap per run
attempt, enforced cumulatively at both publication and consumption
(`handoff_size_exceeded` above it): publication sums every previously
committed manifest before accepting a new one, and consumption validates the
complete required manifest set for the consumer as one closed set, rejecting
the run with overflow-safe aggregate accounting before any phase directory is
handed to the consumer. Before
creating a new run directory the first phase measures the **complete
validated handoff root** — every repository scope counts, reparse points are
never traversed or counted — and fails closed as `handoff_storage_exhausted`
when the committed bytes plus the 64 GiB reservation exceed the configured
total-root cap (default **256 GiB**), retaining the cleanup-request evidence.

CI never deletes anything under the handoff root. Instead the first and last
phases write bounded **cleanup-request** records under
`<root>/<owner>/<repo>/cleanup-requests/`, listing each exact resolved run
directory with its state (`completed` with its terminal `passed`/`failed`
completion state, `abandoned` after 48 hours, `active`, or `invalid`), age,
measured bytes, manifest digests, and cleanup eligibility. Eligibility always
requires a valid run-context record: `completed` additionally requires a
closed, context-matching completion marker with a terminal state, and
`abandoned` requires a valid context plus the age threshold. Directories with
a missing, malformed, mismatched, or duplicate-property context, marker, or
manifest, and directories with any descendant reparse or containment concern
(classified without traversing them), are marked `invalid` and never
cleanup-eligible. Acting on a cleanup request is an external operational
action, exactly like provisioning the runner variable itself.

Failures are actionable from the job log and uploaded report without exposing
raw local output: checks record a stable command label and reason code plus a
sanitized tail of at most 20 nonblank diagnostic lines and 4,096 characters.
Known repository, engine, toolchain, archive, log, client, server, and endpoint
values are replaced before serialization. Only diagnostic-shaped error,
failure, warning, timeout, exception, or tool-code lines are eligible;
credential-like, environment-assignment, environment-table, known token-
format, and high-entropy values are discarded or redacted. The wrapper exits
nonzero when a required check fails.

## Runner Constraints

- Portable checks and the pull-request change-impact classifier use
  GitHub-hosted `windows-latest` with explicit job bounds (30 and 10 minutes);
  engine jobs require the repository-scoped self-hosted runner on the current
  Windows development PC, running under the current owner account.
- All CI scripts target Windows PowerShell 5.1 as the compatibility floor.
  `pwsh` (PowerShell 7) is not assumed on hosted runners or contributor
  machines.
- The owner must provision the pinned Unreal Engine 5.8.1 source build, Visual
  Studio toolchain, Windows SDK, Linux cross-toolchain, WSL distribution
  `Ubuntu`, WSL user `aethelnqa`, Git, and Git LFS before live execution.
- The current account must define non-secret user-level variables
  `AETHELN_ENGINE_ROOT`, `AETHELN_LINUX_TOOLCHAIN_ROOT`, and (for the
  milestone phases) `AETHELN_HANDOFF_ROOT`. The runner process
  must be restarted after variable changes so they are inherited as process
  variables. Values are local absolute paths and must never be committed,
  uploaded, or printed as credentials.
- No GitHub secret is required by the engine wrapper. Workflow permissions
  remain `contents: read`.

Runner provisioning is an external operational responsibility and is not
performed or proven by Issue #16 or Issue #127 repository changes.
Representative engine-runner evidence is commit-specific and must come from
the artifacts uploaded by the corresponding GitHub run. An earlier or
in-progress run does not establish that the unpublished incremental candidate
has completed successfully.

## Unreal Automation Harness

The production PowerShell 5.1 runner is
`scripts/ci/Invoke-UnrealAutomationTests.ps1`. It requires an explicit
`-EngineRoot` for the source engine pinned to tag `5.8.1-release` and commit
`71fe36aac5a8df5ccd66c763ffc902b29b6a9c43`; `-TimeoutSeconds` is optional and
defaults to 600. It runs exactly the project/module-load smoke test and focused
network-spike authority test under the frozen filter, validates exact discovery,
and exits nonzero on every preflight, process, discovery, report, or test
failure. The detailed contract and normalized report schema are in
[Unreal Automation](unreal-automation.md).

This production run is attainable on the accepted Issue #16 repository-scoped
self-hosted Windows topology because that machine owns the pinned source engine
and toolchain. A workflow integration must pass the local non-secret engine
path explicitly and preserve the existing owner/trust predicates, serialization,
revision checks, and clean-workspace enforcement. This document does not claim
that a GitHub-hosted runner has the engine or that the real automation run is
part of the portable job.

Issue #44 remains responsible for packaged dedicated-server/two-client lifecycle,
Gauntlet, and representative or harsh network-profile scenarios; those scenarios
reuse this harness rather than creating a second test system. Issue #45 remains
responsible for measured performance evidence and budgets.

The required portable `network-authority-spike-tests` check covers only the
versioned scenario/profile contract and fake-process orchestration. Its six
profile kinds carry caller-supplied opaque switches; the repository does not
invent numeric network conditions. A passing fixture report is neither a real
packaged run nor Issue #44 completion, and it cannot select a network profile,
satisfy Issue #48's prototype exit decision, or authorize packaged smoke.

## Engine-Dependent Gates

The Compile workflow step runs from the `compile/` checkout with this exact
wrapper command and run-scoped evidence destination:

```powershell
$RunRoot = Join-Path '${{ runner.temp }}' 'aetheln-engine-${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}'
powershell -NoProfile -File scripts/ci/Invoke-EngineRunnerGate.ps1 `
  -Mode Compile `
  -RepositoryRoot '${{ github.workspace }}/compile' `
  -SourceRevision '${{ github.sha }}' `
  -ArchiveRoot (Join-Path $RunRoot 'archives') `
  -LogRoot (Join-Path $RunRoot 'logs') `
  -CompileTimeoutMinutes 30 `
  -ReportPath (Join-Path $RunRoot 'engine-runner-report.json')
```

Each milestone phase invokes the gate with its phase mode (`PackageClient`,
`PackageServer`, `ValidateProvenance`, or `SmokePhase`), the handoff context,
and its recorded watchdog. Each step runs from `milestone/`; phase 1 is:

```powershell
$RunRoot = Join-Path '${{ runner.temp }}' 'aetheln-engine-${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}'
powershell -NoProfile -File scripts/ci/Invoke-EngineRunnerGate.ps1 `
  -Mode PackageClient `
  -RepositoryRoot '${{ github.workspace }}/milestone' `
  -SourceRevision '${{ github.sha }}' `
  -LogRoot (Join-Path $RunRoot 'logs') `
  -Repository '${{ github.repository }}' `
  -RunId '${{ github.run_id }}' `
  -RunAttempt '${{ github.run_attempt }}' `
  -RunnerName '${{ runner.name }}' `
  -PhaseTimeoutMinutes 30
```

### Compile Policy

`Compile` is the routine pull-request policy. It reports
`policy = incremental-target-compilation` and invokes the pinned engine's
`Engine/Build/BatchFiles/Build.bat` sequentially with these exact target
vectors, where `$AethelnProject` is the resolved
`AethelnOnline.uproject` path:

```powershell
& $BuildBatch AethelnOnlineClient Win64 Development $AethelnProject -WaitMutex -NoHotReloadFromIDE
& $BuildBatch AethelnOnlineServer Linux Development $AethelnProject -WaitMutex -NoHotReloadFromIDE
```

The server command runs only after the client command succeeds. This mode does
not invoke `BuildCookRun`, `RunUAT`, or `Build-PackagedArtifacts.ps1`, and it
does not request clean, cook, stage, package, pak, or archive phases. It is an
incremental target-compilation gate, not proof of a clean package or runnable
packaged build.

Before the first target, between the two targets, and after the final target,
the wrapper requires both of the following:

- `git rev-parse HEAD` returns exactly one full 40-hex revision equal to the
  supplied `SourceRevision` (`${{ github.sha }}` in the workflow).
- `git status --porcelain --untracked-files=all` reports no tracked or
  non-ignored changes.

A revision change or repository drift fails closed and stops the remaining
work. Ignored Unreal intermediates, including the generated directories
excluded by source-control policy, do not appear in this status check. They may
be reused by the incremental compiler and are never deleted by this gate.

### Retained Compile workspace and operational limit

The 2026-09-06 owner-directed CI redesign selects operational safety limits,
not measured performance budgets. Portable CI has a 30-minute job cap.
Compile has a 40-minute job cap and one 30-minute controlled-work deadline
covering input discovery, both targets and diagnostics. The supervisor owns
and stops its child tree on expiry; a timeout is failure, never compile
success or clean-package evidence. No automatic timeout increase or cold-build
retry is permitted.

All self-hosted checkouts are siblings: `compile/` for trusted PR compilation
and `milestone/` for the four scheduled phases. Every milestone checkout uses
`fetch-depth: 0` so the DDC repository identity from
`git rev-list --max-parents=0 HEAD` resolves the actual root-commit set across
source revisions instead of a shallow checkout boundary. This preserves the
identity input; it does not prove cache reuse or a runtime improvement.
Milestone checkout retains default cleaning and packaging retains `-clean`.
It cannot erase Compile outputs. Compile alone uses `clean: false`, then
`Initialize-CompileWorkspace.ps1` before LFS or engine use. That helper
preserves tracked files and only the exact root `Binaries/` and
`Intermediate/Build/` generated trees. It rejects unsafe paths and cleans
other untracked/ignored debris; nested directories merely named Binaries are
not exceptions. Repository status alone cannot inspect ignored inputs.

Retained outputs belong to the trusted owner-only runner workspace; their
presence is not proof of provenance, identity or speedup. UBT remains
responsible for rebuilding changed source/rules. Engine/toolchain changes
require explicit reprovisioning; do not transplant arbitrary outputs or adopt
a foreign cache as trusted. A cold or heavily invalidated build may fail the
operational deadline; that failure remains visible and does not waive the
required target gate.

Compile writes an explicit fresh report under
`runner.temp/aetheln-engine-<run>-<attempt>-<job>/engine-runner-report.json`.
Its upload uses exactly that path, never a report left in the retained
checkout. Explicit evidence destinations are create-only; pre-existing
evidence is not overwritten. Scheduled uploads use only
`milestone/TestResults/engine-runner-report.json`.

The old multi-hour limits are superseded, not reinterpreted as measured
speedups. A clean milestone that cannot finish within these operational
limits remains unproven; incremental compilation never substitutes for it.

### Compile evidence (report-only)

Every gate process that writes its own report (`Compile`, `PackagedSmoke`,
and the supervised scheduled-phase child) records a report-only
`compileEvidence` object so a cold candidate can later be distinguished from
possible incremental reuse. It changes no compile, cleanup, scheduling,
timeout, host-tools, cache, or trust behavior, adds no check, and uploads no
new artifact; the report-only artifact policy owned by
[Issue #149](https://github.com/ShayShimoni/aetheln-online/issues/149) is
unchanged.

Observations are separated from inference:

- **Compile input identity** uses the same field names, commands, and
  `verified`/`dirty`/`unavailable` vocabulary as the build controller's
  `build-timing.json`: engine Git revision (`git rev-parse HEAD` plus a
  porcelain status of the engine checkout), the SHA-256 of
  `Engine/Build/Build.version`, the SHA-256 of the Linux cross compiler, and
  the validated runner name. Values are normalized identifiers only; an engine
  root that is not a Git checkout, a missing version file, or an absent
  compiler is recorded as `unavailable` with a `null` value, never guessed.
  The resolution's own `durationSeconds` is recorded (one engine-tree
  `git status` per gate process; about 2.5 seconds on the current runner when
  warm).
- **Pre-run presence** (`intermediateBuildDirectoryPresentBeforeRun`,
  `makefilePresentBeforeRun`) records only whether
  `Intermediate/Build/<platform>` and the target's `Development/Makefile.bin`
  existed before the target ran. Presence is not proof of reusable object
  identity or of a successful warm compile. The legacy single-job
  `PackagedSmoke` builds both platforms in one controller invocation, so its
  presence fields are `null`.
- **UBT observations** are extracted from the captured build output through a
  closed allowlist and carry no raw text, command lines, or paths: the last
  `[n/total]` action counter seen in output order (`actionCounterState`
  `observed`, or `not_observed` when no well-formed counter appeared), the
  planned action count from the executor line, `Creating makefile for ...`
  lines with the pinned UnrealBuildTool reason mapped to a token (unknown
  reasons become `other`), the `Target is up to date` marker, the count of
  executor summaries, and observed target names from the closed allowlist
  (`AethelnOnlineClient`, `AethelnOnlineServer`, `AethelnOnlineEditor`,
  `UnrealEditor`, `UnrealPak`, `ShaderCompileWorker`, else `other`).
  Reuse of an existing makefile is not logged by UnrealBuildTool at the
  default verbosity, so `makefileObservation` is `created` or
  `not_observed`; a present makefile plus `not_observed` is a candidate for
  reuse, not evidence of it. Malformed, out-of-range, or oversized counters
  are ignored rather than coerced.

Ordinary build failures keep their observations because the entry is recorded
before the repository-state check that stops the gate. When the packaging
child is stopped at the cooperative deadline its entry is `outputState =
unavailable`; the parent-written hard-timeout report carries
`compileEvidence = null`. Platform hard-kill or runner-loss reporting is not
guaranteed by this record; Compile uses the separate owned-process supervision described above. Neither the
portable fixtures nor this record establish any speedup: before/after proof
still requires the lead-authorized live milestone pair.

### PackagedSmoke Policy

`PackagedSmoke` is a retained gate-script mode with no workflow entry point:
no job in `prototype-quality-gates.yml` selects it, and the milestone runs
only as the four bounded phases above. When invoked directly, it reports
`policy = clean-package-and-smoke` and invokes
`scripts/build/Build-PackagedArtifacts.ps1` exactly once for the Development
Windows client and Linux server, using `/Game/Maps/StarterMap` and the supplied
`ArchiveRoot`. That packaging entry point owns its clean build, cook, stage,
package, and archive work.

After packaging, the wrapper verifies the revision and clean tracked/non-ignored
repository status. It then discovers exactly one packaged Windows client and
one `AethelnOnlineServer.sh` under that same `ArchiveRoot`; it does not rebuild
or select outputs from a different archive. The server path is converted with
`wsl.exe -d Ubuntu -u aethelnqa -- wslpath <WindowsPath>`, which must return
exactly one absolute WSL path. The wrapper obtains an IPv4 WSL guest address
and invokes `Invoke-PackagedSmokeTest.ps1` against that packaged client/server
pair with two Windows clients and a 120-second timeout. A final revision and
repository-status check runs after smoke.

### Derived Data Cache configuration

For the packaging modes (`PackagedSmoke`, `PackageClient`, `PackageServer`)
the gate reads two optional machine-level environment variables on the
runner and records a `ddc-cache-configuration` check:

- `AETHELN_DDC_ROOT` — an existing local fixed-drive directory used as the
  persistent Derived Data Cache root. It must be disjoint from the
  repository, engine, toolchain, archive, log, and handoff roots; a UNC,
  relative, reparse-point, missing, or overlapping path fails closed with
  `ddc_root_invalid`. Unset (`ddc_not_configured`) leaves engine-default DDC
  behavior unchanged.
- `AETHELN_DDC_FALLBACK` — `fail-closed` (default) or `clean-isolated`.
  Any other value fails closed with `ddc_fallback_invalid`.

A valid configuration (`ddc_configured`) is forwarded to
`Build-PackagedArtifacts.ps1` as `-DerivedDataCachePath` and
`-CacheFallback`. Cache identity validation, the DDC path contract, the
clean-isolated fallback, and the recorded cache states are owned by the
build controller and documented in
[Developer Environment and DDC](developer-environment-and-ddc.md). The gate
never deletes or invalidates the cache. `ValidateProvenance` and
`SmokePhase` do not cook and ignore this configuration.

The same packaging modes require an explicit host-tools selection and record
a `host-tools-configuration` check — unset configuration fails closed so one
missing runner variable can never silently launch another multi-hour host
editor/engine rebuild:

- `AETHELN_HOST_TOOLS` (**required**) — `prebuilt` (`host_tools_prebuilt`)
  for the scheduled clean milestone, or `rebuild-authorized`
  (`host_tools_rebuild_authorized`) as the explicit, separately named
  operator authorization for a full host-tools rebuild. Unset fails closed
  with `host_tools_configuration_required`; any other value (including the
  retired implicit `rebuild`) fails closed with `host_tools_invalid`.
- `AETHELN_ENGINE_REVISION` — required with `prebuilt`: the full
  40-character canonical pinned engine commit; missing or malformed fails
  closed with `engine_revision_invalid`.
- `AETHELN_HOST_TOOLS_ATTESTATION` — required with `prebuilt`: the external
  host-tools attestation record file (an existing local fixed-drive file
  disjoint from every approved root); missing or invalid fails closed with
  `host_tools_attestation_invalid`.

A valid `prebuilt` selection is forwarded to `Build-PackagedArtifacts.ps1`
as `-HostToolsBoundary Prebuilt -EngineRevision <sha>
-HostToolsAttestationPath <file>`, and `rebuild-authorized` as
`-HostToolsBoundary Rebuild`; the gate also forwards its validated runner
name as `-RunnerName`. The build controller owns the fail-closed attestation
proof that the host editor/tools belong to the exact clean canonical pinned
engine revision before skipping their rebuild. See
[Developer Environment and DDC](developer-environment-and-ddc.md).

Every `Build-PackagedArtifacts.ps1` run that resolves a valid `LogRoot` also
writes a bounded machine-readable substep timing and cache-state record to
`<LogRoot>/build-timing.json` — including runs that fail closed on
host-tools or cache-identity validation before any UAT process starts —
separating C++ compilation, cook, stage, package, and archive time inside
each UAT invocation from the controller's validation and provenance
substeps.

Archive and log roots for both modes must be empty or absent, outside the
repository, and unique to the workflow run/job. These commands implement the
repository side of the policies. They do not prove that the owner provisioned
a runner or that either policy has executed successfully on a representative
branch. In particular, an earlier heavyweight run does not validate the new
incremental compile policy.

## Artifact Policy

- The portable workflow uploads `TestResults/ci-report.json`. Compile uploads
  only the fresh report at
  `runner.temp/aetheln-engine-<run>-<attempt>-<job>/engine-runner-report.json`.
  Each scheduled phase uploads only
  `milestone/TestResults/engine-runner-report.json`. The five engine jobs keep
  distinct artifact names: compile, client package, server package, provenance
  validation, and scheduled smoke. Every engine upload uses
  `if-no-files-found: error`; missing evidence cannot establish success.
- Headless Unreal automation generates
  `TestResults/UnrealAutomation/index.json`,
  `TestResults/unreal-automation-report.json`, and
  `Saved/Logs/AethelnUnrealAutomation.log`. These paths remain ignored and are
  not added to the portable artifact contract by Issue #85.
- Large generated artifacts such as `Saved/`, `StagedBuilds/`, packaged archives,
  cook output, and detailed logs remain local to the self-hosted runner and are
  never uploaded by default. The owner may inspect or remove the per-run paths
  locally after evidence review.
- The portable job's LFS fetch is limited to
  `Content/Maps/StarterMap.umap`. Compile and the client/server packaging jobs
  fetch `Content/**` so Unreal Content required by compilation, cooking, and
  packaging is materialized. Provenance validation and scheduled smoke consume
  the verified handoff payloads and do not fetch LFS Content.
- Artifact retention periods remain an open decision and are not configured.

## Secret Policy

- The workflow declares `permissions: contents: read` and consumes no
  repository or organization secrets.
- No step prints environment variables or credentials; engine failures expose
  only stable reason codes, command labels, and the bounded sanitized
  diagnostic tail. Full captured build and smoke output remains runner-local.
- Sensitive-path policy (ignored secret material, prohibited tracked
  patterns) is enforced by `scripts/tests/Test-SourceControlPolicy.ps1` as a
  required check.
- A dedicated secret scanner and SBOM tooling remain open vendor decisions in
  [Security and Operations](security-and-operations.md); this workflow does
  not select them.

## Open Decisions

The following remain open exactly as recorded in
[Performance, Quality, and Delivery](performance-quality-and-delivery.md) and
[Security and Operations](security-and-operations.md); this workflow does not
decide them:

- Artifact retention policy.
- The exact secret scanner and SBOM format.
- Artifact signing and the retention policy for local engine logs and archives.

The repository-scoped self-hosted topology and `02:00 UTC` cadence are accepted
in [Architecture Decisions](architecture-decisions.md). A compile-capable
runner is registered, and commit-specific live compile evidence exists for
GitHub Actions run `33161041115`. Ongoing runner maintenance, packaging-only
prerequisites, and scheduled phased packaged-smoke evidence remain outstanding
operational responsibilities, not architecture decisions.

## Relationship to Visual Package Validation

`.github/workflows/visual-package-validation.yml` is unchanged and continues
to own validation of the non-canonical visual package. The prototype quality
gates workflow does not run the visuals validation scripts, and the visual
workflow does not run this suite.

## Machine-Readable Evidence

`TestResults/ci-report.json` contains `schemaVersion`, the `revision` the
suite ran against, `startedUtc`/`finishedUtc`, one record per check with
`name`, `tier`, `status` (`passed`, `failed`, or `skipped`),
`durationSeconds`, the exact `command`, and a captured output `message`, plus
a `summary` with `total`, `passed`, `failed`, `skipped`, and `requiredFailed`
counts.

`TestResults/unreal-automation-report.json` uses the separate normalized schema
documented in [Unreal Automation](unreal-automation.md). Its raw Unreal report
and log remain repository-local ignored output unless Issue #16 separately
selects and redacts evidence for publication.

`engine-runner-report.json` uses schema version 1 at the per-job locations
listed in [Artifact Policy](#artifact-policy). Without an explicit `ReportPath`,
the gate writes it under the selected repository's `TestResults/` directory;
the Compile workflow always supplies its fresh run-scoped path. It contains
`mode` (`Compile`, `PackagedSmoke`, `PackageClient`, `PackageServer`,
`ValidateProvenance`, or `SmokePhase`), `policy`
(`incremental-target-compilation` or `clean-package-and-smoke`), `revision`,
`runnerName` (the validated runner name, null when not provided or invalid),
`startedUtc`, `finishedUtc`, a `checks` array, and `summary`. Each check contains
`name`, the required `tier`, `status`, `durationSeconds`, a stable `command`,
and a redacted `message`. The summary contains `total`, `passed`, `failed`,
`skipped`, and `requiredFailed`. Input validation and repository-state checks
are present in every mode. `Compile` records separate incremental client and
server build checks; `PackagedSmoke` records one clean packaged client/server
build and one packaged-smoke check. The packaging modes record one
`ddc-cache-configuration` check and one `host-tools-configuration` check.
The scheduled phase modes additionally
record handoff validation, storage accounting or manifest consume/publish
checks, the phase gate itself, and (for `SmokePhase`) milestone completion.

The report additionally carries `compileEvidence` (schema version 1 of that
object; the report schema version is unchanged): `identity`
(`engineGitRevision`, `engineGitRevisionStatus`, `engineBuildVersionSha256`,
`engineBuildVersionSha256Status`, `linuxToolchainCompilerSha256`,
`linuxToolchainCompilerSha256Status`, `runnerName`, `durationSeconds`) and
`builds`, one flat entry per build check in run order (`check`, `target`,
`platform`, `configuration`, `intermediateBuildDirectoryPresentBeforeRun`,
`makefilePresentBeforeRun`, `outputState`, `lastObservedAction`,
`observedTotalActions`, `actionCounterState`, `plannedActionCount`,
`observedTargetNames`, `makefileObservation`, `makefileReason`,
`makefileCreationCount`, `upToDateObserved`, `executorSummaryCount`). It is
`null` in the parent-written hard-timeout report. See
[Compile evidence (report-only)](#compile-evidence-report-only) for the
observation/inference boundary.

`<LogRoot>/build-timing.json` is the per-run substep timing and cache-state
record written by `Build-PackagedArtifacts.ps1`. It is local run evidence and
is not uploaded; its schema is documented in
[Developer Environment and DDC](developer-environment-and-ddc.md).
