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
- The Unreal automation harness, owned by
  [Issue #85](https://github.com/ShayShimoni/aetheln-online/issues/85).

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
| `engine-runner-gate-tests` (`tests/ci/Invoke-EngineRunnerGate.Tests.ps1`) | Required | Fixture regression tests for engine-runner input validation, command selection, redacted failures, report schema, and exit codes. |
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

Engine-dependent jobs use a repository-scoped Windows self-hosted runner with
labels `[self-hosted, Windows, X64, aetheln-engine]` and serialize through the
`aetheln-engine-runner` concurrency group. Their event and trust contract is:

| Job | Event | Trust predicate | Gate |
| --- | --- | --- | --- |
| `trusted-candidate-compile` | `pull_request` | The head repository is this repository, the PR author is the repository owner, and `github.triggering_actor` is the repository owner. | Compile the supported Windows client and Linux server targets. |
| `scheduled-packaged-smoke` | `schedule` at `02:00 UTC` daily | The schedule exists only on the protected default branch once this workflow reaches `main` through normal Git Flow. | Build both supported targets and run packaged smoke. |
| `manual-packaged-smoke` | `workflow_dispatch` | `github.triggering_actor` is the repository owner. | Owner-requested build and packaged smoke. |

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

There are currently zero registered self-hosted runners. Therefore no live
supported-target compile, scheduled smoke, manual smoke, or representative-
branch engine-runner evidence exists. Repository-owner provisioning is an
external prerequisite and is not performed or proven by Issue #16's repository
changes.

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

Both modes call `scripts/build/Build-PackagedArtifacts.ps1` for the Development
Windows client and Linux server using `/Game/Maps/StarterMap`. `PackagedSmoke`
also discovers exactly one packaged client and one
`AethelnOnlineServer.sh`, converts the server path with
`wsl.exe -d Ubuntu -u aethelnqa -- wslpath <WindowsPath>`, requires exactly one
absolute WSL path, obtains an IPv4 WSL guest address, and invokes
`Invoke-PackagedSmokeTest.ps1` with two Windows clients and a 120-second timeout.
Archive and log roots must be empty or absent, outside the repository, and
unique to the workflow run/job.

These commands implement Issue #16's repository side of the gates. They do not
prove that the owner provisioned a runner or that either mode has executed
successfully on a representative branch.

## Artifact Policy

- The portable workflow uploads `TestResults/ci-report.json`. Each selected
  engine job uploads only `TestResults/engine-runner-report.json`, with distinct
  compile, scheduled-smoke, and manual-smoke artifact names.
- Large generated artifacts such as `Saved/`, `StagedBuilds/`, packaged archives,
  cook output, and detailed logs remain local to the self-hosted runner and are
  never uploaded by default. The owner may inspect or remove the per-run paths
  locally after evidence review.
- The LFS fetch is limited to `Content/Maps/StarterMap.umap`; the workflow
  does not smudge the full LFS object set.
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

`TestResults/engine-runner-report.json` uses schema version 1 and contains
`mode` (`Compile` or `PackagedSmoke`), `revision`, `startedUtc`, `finishedUtc`,
a `checks` array, and `summary`. Each check contains `name`, the required
`tier`, `status`, `durationSeconds`, a stable `command`, and a redacted
`message`. The summary contains `total`, `passed`, `failed`, `skipped`, and
`requiredFailed`. Input validation and supported client/server build are
present in both modes; packaged smoke is present only in `PackagedSmoke` mode.
