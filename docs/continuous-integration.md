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
(`TestResults/` is gitignored), and exits nonzero exactly when a required
check fails. Individual checks can also be run directly, for example:

```powershell
powershell -NoProfile -File scripts/ci/Test-FormattingPolicy.ps1
powershell -NoProfile -File scripts/ci/Test-MarkdownLinks.ps1
powershell -NoProfile -File scripts/tests/Test-SourceControlPolicy.ps1
powershell -NoProfile -File scripts/tests/Test-ObservabilityContract.ps1
```

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
| `engine-runner-gate-tests` (`tests/ci/Invoke-EngineRunnerGate.Tests.ps1`) | Required | Fixture regression tests for engine-runner input validation, command selection, repository-state enforcement, redacted failures, report schema, and exit codes. |
| `unreal-automation-tests` (`tests/ci/Invoke-UnrealAutomationTests.Tests.ps1`) | Required | Portable fixture regression tests for the headless Unreal runner's engine pin, discovery, repository-state, timeout, report validation, and fail-closed exit behavior. |
| `psscriptanalyzer` (`Invoke-ScriptAnalyzer` over `scripts/` and `tests/`) | Advisory | PowerShell static analysis. Advisory because the module is not guaranteed on contributor machines (the check reports `skipped` when it is absent) and the pre-existing finding baseline has not been triaged into a gate. |

Required checks fail the suite and the workflow. Advisory checks are reported
in the same machine-readable evidence but never fail the suite. The live
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
GitHub-hosted `windows-latest` runner bounded at 60 minutes (the suite takes
about 13 minutes). That job checks out without LFS smudge, fetches only the
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
  top-level `.github/PULL_REQUEST_TEMPLATE.md`; never `.github/workflows/**`

Everything else requires compile, including `Source/**`, `Config/**`,
`Content/**`, `Plugins/**`, `scripts/**`, every workflow file, and
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

The recorded **12-hour** value is therefore precise: it is the maximum
trusted-compile queue delay **attributable to one currently running scheduled
phase** (the longest total phase bound, the 720-minute server package),
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
writes the bounded report itself — so a timeout report is written and uploaded
before the platform cancels the job (deadline plus grace stays below every job
bound). Checkout/LFS and the report upload sit only inside the workflow job
bound; no report can be preserved if the platform kills the job before the
gate script starts:

| Phase | Total job bound (`timeout-minutes`) | Script watchdog (`-PhaseTimeoutMinutes`) |
| --- | --- | --- |
| Client package | 480 minutes (8 hours) | 450 |
| Server package | 720 minutes (12 hours) | 690 |
| Registry/provenance validation | 60 minutes (1 hour) | 45 |
| Packaged smoke | 120 minutes (2 hours) | 105 |

Reaching the deadline is an explicit `phase_timeout` failure, whether it
expires during controlled pre-work between operations (the bounded report is
still written and retained, and the build/smoke grandchild is not started),
inside a single blocking synchronous operation (the supervisor hard bound
interrupts it), or during the build/smoke work: on timeout the gate disposes
the owning kill-on-close Job Object first, verifies the tree
ended (bounded `taskkill /T /F` is only a fallback), rejects partial outputs
(an unpublished integrity manifest can never be consumed, and a timed-out
smoke never publishes a completion marker), retains the bounded report through
the `if: always()` upload, and the next scheduled attempt restarts the
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
  GitHub-hosted `windows-latest` with explicit job bounds (60 and 10 minutes);
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

The exact workflow wrapper commands are:

```powershell
powershell -NoProfile -File scripts/ci/Invoke-EngineRunnerGate.ps1 `
  -Mode Compile `
  -RepositoryRoot '${{ github.workspace }}' `
  -SourceRevision '${{ github.sha }}' `
  -ArchiveRoot (Join-Path $RunRoot 'archives') `
  -LogRoot (Join-Path $RunRoot 'logs')
```

Each milestone phase invokes the gate with its phase mode (`PackageClient`,
`PackageServer`, `ValidateProvenance`, or `SmokePhase`), the handoff context,
and its recorded watchdog; phase 1 is:

```powershell
powershell -NoProfile -File scripts/ci/Invoke-EngineRunnerGate.ps1 `
  -Mode PackageClient `
  -RepositoryRoot '${{ github.workspace }}' `
  -SourceRevision '${{ github.sha }}' `
  -LogRoot (Join-Path $RunRoot 'logs') `
  -Repository '${{ github.repository }}' `
  -RunId '${{ github.run_id }}' `
  -RunAttempt '${{ github.run_attempt }}' `
  -RunnerName '${{ runner.name }}' `
  -PhaseTimeoutMinutes 450
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

Archive and log roots for both modes must be empty or absent, outside the
repository, and unique to the workflow run/job. These commands implement the
repository side of the policies. They do not prove that the owner provisioned
a runner or that either policy has executed successfully on a representative
branch. In particular, an earlier heavyweight run does not validate the new
incremental compile policy.

## Artifact Policy

- The portable workflow uploads `TestResults/ci-report.json`. Each selected
  engine job uploads only `TestResults/engine-runner-report.json`, with a
  distinct artifact name per job: compile and the four milestone phases
  (client package, server package, provenance validation, scheduled smoke).
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
  `Content/Maps/StarterMap.umap`. Each engine job fetches `Content/**` so all
  Unreal Content required by compilation, cooking, and packaging is
  materialized.
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

`TestResults/engine-runner-report.json` uses schema version 1 and contains
`mode` (`Compile`, `PackagedSmoke`, `PackageClient`, `PackageServer`,
`ValidateProvenance`, or `SmokePhase`), `policy`
(`incremental-target-compilation` or `clean-package-and-smoke`), `revision`,
`startedUtc`, `finishedUtc`, a `checks` array, and `summary`. Each check contains
`name`, the required `tier`, `status`, `durationSeconds`, a stable `command`,
and a redacted `message`. The summary contains `total`, `passed`, `failed`,
`skipped`, and `requiredFailed`. Input validation and repository-state checks
are present in every mode. `Compile` records separate incremental client and
server build checks; `PackagedSmoke` records one clean packaged client/server
build and one packaged-smoke check. The scheduled phase modes additionally
record handoff validation, storage accounting or manifest consume/publish
checks, the phase gate itself, and (for `SmokePhase`) milestone completion.
