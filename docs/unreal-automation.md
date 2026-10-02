# Unreal Automation

## Purpose and ownership

[Issue #85](https://github.com/ShayShimoni/aetheln-online/issues/85) provides
the repository-owned Windows PowerShell 5.1 harness for deterministic,
headless Unreal automation against the pinned source engine. It establishes
one project/module-load smoke test, one focused server-authority regression
test, exact discovery, fail-closed exit behavior, and normalized local
evidence.

This harness is focused editor automation. Issue #16 owns CI runner topology
and evidence publication. Issue #44 remains responsible for packaged
dedicated-server/two-client lifecycle, Gauntlet, and representative or harsh
network-profile scenarios. Issue #45 remains responsible for measured
performance evidence and budgets.

## Frozen harness contract

| Item | Required value |
| --- | --- |
| Runner | `scripts/ci/Invoke-UnrealAutomationTests.ps1` |
| Compatibility floor | Windows PowerShell 5.1 |
| Engine tag | `5.8.1-release` |
| Engine commit | `71fe36aac5a8df5ccd66c763ffc902b29b6a9c43` |
| Project | `AethelnOnline` |
| Mode | `production` |
| Schema | `aetheln.unreal-automation`, version `1` |
| Filter | `^Aetheln.Harness.ProjectAndModuleLoad$+^Aetheln.GameCombat.NetworkSpike.Authority$` |
| Default timeout | 600 seconds |

The filter must discover exactly one record for each required full test path
and no other record:

| Full test path | Purpose |
| --- | --- |
| `Aetheln.Harness.ProjectAndModuleLoad` | Deterministic smoke coverage that the project and required automation modules load. |
| `Aetheln.GameCombat.NetworkSpike.Authority` | Focused coverage that the networking spike preserves server authority and can expose an authority regression. |

Zero discovered tests, a missing expected path, more than one record for an
expected path, or any unexpected path is a discovery failure. The runner does
not treat an empty, partial, duplicated, or broadened result set as success.

## Local prerequisites and invocation

Use a clean committed repository workspace and the exact source-engine checkout
from [Unreal Project Setup](unreal-project-setup.md). Build the Development
Editor target before running the tests. The engine root is a local absolute
path, not a credential; keep it outside tracked configuration.

From the repository root:

```powershell
$AethelnEngineRoot = 'D:\UnrealEngine\UE-5.8.1-source-issue81-clean'
powershell -NoProfile -File scripts/ci/Invoke-UnrealAutomationTests.ps1 `
  -EngineRoot $AethelnEngineRoot
```

`-EngineRoot` is required. `-TimeoutSeconds` is the only optional public
parameter and defaults to 600:

```powershell
powershell -NoProfile -File scripts/ci/Invoke-UnrealAutomationTests.ps1 `
  -EngineRoot $AethelnEngineRoot `
  -TimeoutSeconds 600
```

The runner validates both the `5.8.1-release` tag and exact engine commit
before starting Unreal. It records the repository source revision and requires
the tracked and non-ignored repository state to be clean before and after the
run. A revision change or repository drift is a failure.

## Generated outputs

| Path | Contents |
| --- | --- |
| `TestResults/UnrealAutomation/index.json` | Raw Unreal Automation report consumed for discovery and result validation. |
| `TestResults/unreal-automation-report.json` | Repository-normalized runner evidence. |
| `Saved/Logs/AethelnUnrealAutomation.log` | Detailed headless editor log for local diagnosis. |

`TestResults/`, `Saved/`, and `*.log` are ignored by repository policy. Do not
commit these generated files. Issue #85 does not decide upload retention, local
log retention, scanning, SBOM, or artifact signing policy.

## Normalized report schema

`TestResults/unreal-automation-report.json` is a versioned JSON object with
these top-level fields:

| Field | Meaning |
| --- | --- |
| `schemaId` | Constant `aetheln.unreal-automation`. |
| `schemaVersion` | Integer `1`. |
| `mode` | Constant `production` for the real engine run. |
| `sourceRevision` | Full repository revision tested. |
| `engineRevision` | Exact engine commit `71fe36aac5a8df5ccd66c763ffc902b29b6a9c43`. |
| `projectName` | Constant `AethelnOnline`. |
| `filter` | The exact frozen two-test filter. |
| `timeoutSeconds` | Effective timeout, defaulting to `600`. |
| `startedUtc`, `finishedUtc` | UTC timestamps bounding the run. |
| `processExitCode` | Exit code returned by the headless editor process. |
| `repositoryCleanBefore`, `repositoryCleanAfter` | Whether the required repository cleanliness checks passed at each boundary. |
| `outputs` | Repository-relative raw report and log paths. |
| `tests` | One normalized record per discovered test. |
| `summary` | Aggregate discovery and outcome counts. |
| `result` | Overall runner result. |
| `failureReason` | Required string: exactly `none` on success, otherwise one allowed fail-closed code. |

`outputs` contains exactly `unrealReport` and `log`, pointing to
`TestResults/UnrealAutomation/index.json` and
`Saved/Logs/AethelnUnrealAutomation.log`. The normalized report path is the
file containing this object and is not repeated inside `outputs`.

Each `tests[]` record contains:

- `fullTestPath`
- `state`
- `status`
- `durationSeconds`
- `warningCount`
- `errorCount`

The report preserves Unreal's state and status for review while normalizing
duration, warning, and error counts. Warnings remain visible rather than being
discarded.

`summary` contains `total`, `passed`, `passedWithWarnings`, `failed`,
`notRun`, `missing`, and `requiredFailed`. The discovery contract requires
`total` to represent exactly the two expected unique tests and `missing` to be
zero. Any failed or not-run required test, missing test, duplicate, or
unexpected result prevents success.

## Fail-closed behavior

The PowerShell process exits `0` only when preflight validation succeeds,
exact discovery succeeds, both required tests pass, the raw report is valid,
the editor exits successfully, and the repository remains at the same clean
revision. Every other outcome is nonzero.

| `failureReason` | Failure | Required behavior |
| --- | --- | --- |
| `preflight` | General input or prerequisite validation | Fail before launch when a required production precondition other than the separately coded engine pin or repository state is invalid. |
| `engine-pin` | Engine-pin mismatch | Reject a checkout whose exact tag or commit differs from the pinned engine. |
| `repository-dirty` | Dirty repository before launch | Do not start the editor; record the failed cleanliness boundary. |
| `process-start` | Process start failure | Fail when the headless editor cannot be started. |
| `timeout` | Timeout | Terminate the bounded run, record the timeout reason, and exit nonzero. |
| `editor-exit` | Editor exit failure | Treat a nonzero editor process exit as failure even if partial output exists. |
| `missing-report` | Missing report | Fail when `index.json` is absent. |
| `invalid-report` | Invalid report | Fail when `index.json` is unreadable, malformed, or lacks the required result structure. |
| `discovery-mismatch` | Zero, duplicate, missing, or unexpected discovery | Fail unless exactly one result exists for each frozen full test path and no other result exists. |
| `test-failure` | Failed or not-run test | Count the required failure and exit nonzero. |
| `repository-drift` | Repository revision or state drift | Fail if the revision changes or tracked/non-ignored state is dirty after execution. |

The normalized report and detailed local log are diagnostic evidence; neither
can override a nonzero runner result.

## CI and downstream boundary

The portable CI suite registers `unreal-automation-tests`
(`tests/ci/Invoke-UnrealAutomationTests.Tests.ps1`) as a required fixture
check. It validates the PowerShell runner contract without requiring Unreal
Engine. The GitHub-hosted `windows-latest` portable job does not run the real
engine automation.

The real run is engine-dependent and fits the accepted Issue #16
repository-scoped self-hosted Windows runner labeled
`[self-hosted, Windows, X64, aetheln-engine]`. That topology owns the pinned
source engine and can pass its local non-secret path explicitly through
`-EngineRoot`; it must preserve the existing owner/trust, serialization,
revision, and clean-workspace controls. Live execution evidence is
commit-specific and cannot be inferred from fixture coverage.

Issue #167 Package 3C wires that run into the owner-only
`trusted-candidate-compile` job. After a passing compile, the job builds the
`AethelnOnlineEditor` Win64 target in the registered managed compile workspace,
runs this harness from that workspace with `-EngineRoot` set to the runner's
engine root and the default 600-second timeout, and uploads the normalized
`TestResults/unreal-automation-report.json` as the `unreal-automation-report`
artifact. Harness output goes to runner-local files and Unreal writes its log
to the `-abslog` file under `Saved/`; both contain absolute runner paths and
this repository is public, so the job log shows only a path-free summary.
After the run, the job removes the untracked compile-input files the editor
may have written, because the next managed workspace sync rejects them. These
steps continue on error: a failed build, harness run, or cleanup uploads no
report and never fails the compile job. The hosted `unreal-receipt-shadow` job
publishes a shadow-only `unreal-editor-automation` receipt from the report, or
fails red when it is missing. The filter, report schema, and engine pin are
unchanged, and nothing grants acceptance.

Issue #44 must reuse this automation foundation for its downstream packaged
dedicated-server/two-client lifecycle, Gauntlet orchestration, and network-
profile scenarios rather than create a second test system. Those packaged
multi-process scenarios are not satisfied by the two focused Issue #85 tests.
The first Issue #44 fixture wave extends the existing
`Invoke-NetworkAuthoritySpike.ps1` orchestration contract with versioned
scenario/profile inputs and normalized lifecycle/failure evidence. It does not
change this harness's frozen two-test discovery filter, launch Unreal, or prove
packaged execution. A real packaged scenario remains a separate evidence gate.
Issue #45 separately owns performance captures, thresholds, and evidence; this
harness does not establish a performance budget.

Artifact retention, local-output retention, scanner/SBOM selection, and
artifact signing remain open decisions in
[Continuous Integration](continuous-integration.md) and
[Performance, Quality, and Delivery](performance-quality-and-delivery.md).
