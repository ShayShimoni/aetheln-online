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
| `build-packaged-artifacts-tests` (`tests/build/Build-PackagedArtifacts.Tests.ps1`) | Required | Focused automation for the packaging entry point. |
| `packaged-smoke-test-tests` (`tests/build/Invoke-PackagedSmokeTest.Tests.ps1`) | Required | Focused automation for the smoke orchestrator logic. |
| `server-cook-reference-tests` (`tests/build/Validate-ServerCookReferences.Tests.ps1`) | Required | Focused automation for server cook reference rules. |
| `target-composition-tests` (`tests/build/Validate-TargetComposition.Tests.ps1`) | Required | Focused automation for client/server module composition rules. |
| `build-provenance-tests` (`tests/build/Write-BuildProvenance.Tests.ps1`) | Required | Focused automation for build provenance recording. |
| `markdown-link-tests` (`tests/ci/Test-MarkdownLinks.Tests.ps1`) | Required | Fixture regression tests for the link checker itself. |
| `formatting-policy-tests` (`tests/ci/Test-FormattingPolicy.Tests.ps1`) | Required | Fixture regression tests for the formatting checker itself. |
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

`.github/workflows/prototype-quality-gates.yml` runs the portable suite on every
pull request and on pushes to `develop`, on a GitHub-hosted `windows-latest`
runner. That job checks out without LFS smudge, fetches only the
`Content/Maps/StarterMap.umap` LFS object required by the source-control policy
check, runs the local invocation above, and always uploads
`TestResults/ci-report.json` as the `ci-report` artifact.
The required `unreal-automation-tests` check exercises portable fixtures and
does not launch Unreal Engine. The GitHub-hosted portable job does not run the
real engine automation tests.

Engine-dependent jobs use a repository-scoped Windows self-hosted runner with
labels `[self-hosted, Windows, X64, aetheln-engine]` and serialize through the
`aetheln-engine-runner` concurrency group without cancelling an active engine
job. Before compiling, packaging, or cooking, each selected engine job fetches
all Unreal Content LFS objects with `git lfs pull --include "Content/**"`.
Their event and trust contract is:

| Job | Event | Trust predicate | Gate |
| --- | --- | --- | --- |
| `trusted-candidate-compile` | `pull_request` | The head repository is this repository, the PR author is the repository owner, and `github.triggering_actor` is the repository owner. | Incrementally compile the supported Windows client and Linux server targets without packaging. |
| `scheduled-packaged-smoke` | `schedule` at `02:00 UTC` daily | The schedule exists only on the protected default branch once this workflow reaches `main` through normal Git Flow. | Clean-package both supported targets once and smoke those packaged outputs. |
| `manual-packaged-smoke` | `workflow_dispatch` | `github.triggering_actor` is the repository owner. | Owner-requested clean package and packaged smoke. |

`develop` remains the integration branch. Merely adding the schedule on a
feature or `develop` branch does not activate it; GitHub schedules run from the
default branch. Fork pull requests, collaborator-authored pull requests, and
collaborator-triggered reruns cannot select the engine jobs. Future collaborator
access requires a separate security and topology review.

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

- Portable checks use GitHub-hosted `windows-latest`; engine jobs require the
  repository-scoped self-hosted runner on the current Windows development PC,
  running under the current owner account.
- All CI scripts target Windows PowerShell 5.1 as the compatibility floor.
  `pwsh` (PowerShell 7) is not assumed on hosted runners or contributor
  machines.
- The owner must provision the pinned Unreal Engine 5.8.1 source build, Visual
  Studio toolchain, Windows SDK, Linux cross-toolchain, WSL distribution
  `Ubuntu`, WSL user `aethelnqa`, Git, and Git LFS before live execution.
- The current account must define non-secret user-level variables
  `AETHELN_ENGINE_ROOT` and `AETHELN_LINUX_TOOLCHAIN_ROOT`. The runner process
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

```powershell
powershell -NoProfile -File scripts/ci/Invoke-EngineRunnerGate.ps1 `
  -Mode PackagedSmoke `
  -RepositoryRoot '${{ github.workspace }}' `
  -SourceRevision '${{ github.sha }}' `
  -ArchiveRoot (Join-Path $RunRoot 'archives') `
  -LogRoot (Join-Path $RunRoot 'logs')
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

`PackagedSmoke` is the explicit scheduled or owner-requested milestone policy.
It reports `policy = clean-package-and-smoke` and invokes
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
  engine job uploads only `TestResults/engine-runner-report.json`, with distinct
  compile, scheduled-smoke, and manual-smoke artifact names.
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
in [Architecture Decisions](architecture-decisions.md). Owner provisioning and
live evidence remain outstanding operational prerequisites, not architecture
decisions.

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
`mode` (`Compile` or `PackagedSmoke`), `policy`
(`incremental-target-compilation` or `clean-package-and-smoke`), `revision`,
`startedUtc`, `finishedUtc`, a `checks` array, and `summary`. Each check contains
`name`, the required `tier`, `status`, `durationSeconds`, a stable `command`,
and a redacted `message`. The summary contains `total`, `passed`, `failed`,
`skipped`, and `requiredFailed`. Input validation and repository-state checks
are present in both modes. `Compile` records separate incremental client and
server build checks; `PackagedSmoke` records one clean packaged client/server
build and one packaged-smoke check.
