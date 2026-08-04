# Continuous Integration

## Purpose and Ownership

This document records the prototype continuous-integration quality gates
introduced by [Issue #16](https://github.com/ShayShimoni/aetheln-online/issues/16),
which owns CI execution, runner requirements, and evidence publication under
[Performance, Quality, and Delivery](performance-quality-and-delivery.md).
This wave establishes the hosted-runner subset of the CI Foundation:
repository and generated-artifact policy checks, formatting/indentation and
available static checks, focused automation, artifact/dependency/secret
policy checks, and machine-readable evidence publication.

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
| `psscriptanalyzer` (`Invoke-ScriptAnalyzer` over `scripts/` and `tests/`) | Advisory | PowerShell static analysis. Advisory because the module is not guaranteed on contributor machines (the check reports `skipped` when it is absent) and the pre-existing finding baseline has not been triaged into a gate. |

Required checks fail the suite and the workflow. Advisory checks are reported
in the same machine-readable evidence but never fail the suite.

The suite deliberately excludes two existing test groups:

- `.agents/skills/orchestrate-delivery/scripts/tests/` exercises delivery
  orchestration tooling, not the shipped repository, and has its own harness.
- `visuals/tests/` is owned by the frozen `visual-package-validation.yml`
  workflow described below and only needs to run when the visual package
  changes.

## Workflow Execution

`.github/workflows/prototype-quality-gates.yml` runs the suite on every pull
request and on pushes to `develop`, on a GitHub-hosted `windows-latest`
runner. The job checks out without LFS smudge, fetches only the
`Content/Maps/StarterMap.umap` LFS object required by the source-control
policy check, runs the local invocation above, and always uploads
`TestResults/ci-report.json` as the `ci-report` artifact.

Failures are actionable from the job log: the runner prints the failing check
name, the exact child command, and the captured output tail, and the same
detail is preserved in the uploaded JSON report.

## Runner Constraints

- Hosted `windows-latest` runners provide Git, Git LFS, and Windows
  PowerShell; no other tooling is assumed.
- All CI scripts target Windows PowerShell 5.1 as the compatibility floor.
  `pwsh` (PowerShell 7) is not assumed on hosted runners or contributor
  machines.
- Hosted runners are not assumed to provide the pinned Unreal Engine source
  build, the Visual Studio toolchain, the Linux cross-toolchain, WSL, or the
  disk and time capacity those require.

## Deferred Engine-Dependent Gates

Two CI Foundation gates remain open acceptance criteria of Issue #16 and are
not satisfied by this wave:

- **Supported client and server compile gate.** Requires the pinned Unreal
  Engine 5.8.1 source checkout, MSVC toolset, Windows SDK, and Linux
  cross-toolchain recorded in
  [Packaged Windows Client and Linux Server Builds](packaged-builds.md) and
  [Unreal Project Setup and First Launch](unreal-project-setup.md), and
  consumes the Issue #15 build entry points.
- **Packaged-build smoke gate.** Consumes the Issue #15 packaging and
  `Invoke-PackagedSmokeTest.ps1` path on a scheduled or appropriately
  provisioned runner.

Hosted runners cannot be assumed to satisfy either gate, so both wait on the
open runner-topology decision below. Editor-only or launcher-binary evidence
cannot satisfy them.

## Artifact Policy

- The workflow uploads only `TestResults/ci-report.json` by default. Large
  generated artifacts such as `Saved/`, `StagedBuilds/`, packaged archives,
  cook output, and logs beyond the report are never uploaded by default.
- The LFS fetch is limited to `Content/Maps/StarterMap.umap`; the workflow
  does not smudge the full LFS object set.
- Artifact retention periods remain an open decision and are not configured.

## Secret Policy

- The workflow declares `permissions: contents: read` and consumes no
  repository or organization secrets.
- No step prints environment variables or credentials; failure output is
  limited to captured check output.
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

- CI provider, runner topology, artifact retention, and scheduled-suite
  cadence.
- The exact secret scanner and SBOM format.

Running on GitHub-hosted runners here is an interim execution path, not an
accepted CI-provider or runner-topology decision; those require an accepted
entry in [Architecture Decisions](architecture-decisions.md).

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
