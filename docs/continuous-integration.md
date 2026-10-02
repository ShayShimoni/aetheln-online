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
finish out of order. No required check is removed.

Timing fixtures distinguish process initialization from the boundary under test.
Network negative waits keep their short deadline local to the selected wait;
observation and cleanup still execute the production code. Compile and phase
fixtures use a deterministic clock to test shared-budget accounting, together
with real process termination, bounded stage handshakes, and separate
uninstrumented whole-launch deadline probes. These are fixture controls, not
changes to production watchdogs or evidence of engine performance.

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
| `host-tool-provisioning-tests` (`tests/build/Invoke-HostToolProvisioning.Tests.ps1`) | Required | Fixture coverage for the bounded, fail-closed source-engine host-tool provisioner; it does not run an engine build. |
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
| `visual-package-evidence-tests` (`tests/ci/Invoke-VisualPackageValidation.Tests.ps1`) | Required | Streaming visual-validator capture, per-line and aggregate byte limits, create-only evidence publication, and pre-serialization fail-closed bounds. |
| `runner-scheduling-policy-tests` (`tests/ci/Test-RunnerSchedulingPolicy.Tests.ps1`) | Required | Bounded runner scheduling, milestone phase, and retained Compile workspace policy contracts. |
| `ci-selection-tests` (`tests/ci/Get-CiSelection.Tests.ps1`) | Required | Closed schema, raw rename/copy classification, revision attributes, checkout safety, conservative uncertainty, and bounded-output contracts for the non-authoritative selector. Runs as a serial barrier. |
| `ci-acceptance-receipt-tests` (`tests/ci/New-CiAcceptanceReceipt.Tests.ps1`) | Required | Closed, bounded, create-only shadow receipt production with exact source, workflow, controller, policy, action, run, result, cleanup, and raw-evidence bindings, including `controller-contract` revalidation of the exact `ci-report.json` and its fixed `tests/ci` suite subset. |
| `ci-acceptance-aggregate-tests` (`tests/ci/Invoke-CiAcceptanceAggregate.Tests.ps1`) | Required | Same-attempt GitHub run/job/artifact and accepted-selector reconciliation, strict JSON/archive parsing, derived obligation coverage, actor binding, `controller-contract` semantic and shared-evidence validation, and fail-closed rerun and missing-producer behavior. |
| `ci-acceptance-publisher-tests` (`tests/ci/Publish-CiAcceptanceReceipt.Tests.ps1`) | Required | Truthful portable (`portable` and `controller-contract`), native client/server compile, and visual receipt publication from one exact typed raw report and the selector-derived identity selection, including expected hash/length, closed identity context, attempt-bound output naming, create-only output, and path/reparse safety. |
| `ci-acceptance-context-tests` (`tests/ci/New-CiAcceptanceAggregateContext.Tests.ps1`) | Required | Closed selector-to-context translation, selector-derived identity `selection.checks`, live `controller-contract` gap coverage, workflow/action identity binding, nonce-derived runtime requirements, direct selector and producer artifact bindings, sorted uniqueness, selected-subset coverage, and create-only output behavior. |
| `ci-activation-candidate-tests` (`tests/ci/Test-CiActivationCandidate.Tests.ps1`) | Required | Accepted-base, no-checkout activation-candidate verification: independently pinned base and policy identities, exact one-file workflow scope, byte equality with the pre-reviewed activation template, immutable controller/evidence inputs, hostile-environment and stale-base rejection, and bounded stdout audit output. |
| `compile-workspace-tests` (`tests/ci/Initialize-CompileWorkspace.Tests.ps1`) | Required | Exact output retention across revisions, scoped cleanup, unsafe-path rejection and preserved tracked source. Runs as a serial barrier. |
| `engine-host-lease-tests` (`tests/ci/EngineRunnerHostLease.Tests.ps1`) | Required | Exclusive shared-host ownership, cleanup-bound release, stale-owner recovery, and deadline/resource propagation contracts. |
| `managed-compile-registration-tests` (`tests/ci/ManagedCompileRegistration.Tests.ps1`) | Required | Bounded, hash-bound operator registration parsing and retained path-handle validation. |
| `managed-compile-workspace-tests` (`tests/ci/ManagedCompileWorkspace.Tests.ps1`) | Required | Exact-revision retained-workspace synchronization, selected LFS materialization, input/path safety, and original-budget propagation. |
| `managed-compile-integration-tests` (`tests/ci/ManagedCompileIntegration.Tests.ps1`) | Required | Supervisor, lease, managed-workspace, resource-proof, cleanup, and fail-closed report integration contracts. |
| `routine-compile-deadline-tests` (`tests/ci/RoutineCompileDeadline.Tests.ps1`) | Required | Pre-checkout monotonic deadline construction, clock validation, grace, and non-resetting child-budget contracts. |
| `routine-compile-resources-tests` (`tests/ci/RoutineCompileResources.Tests.ps1`) | Required | Physical-volume recovery floors, sustained memory pressure, sampling, and per-target action admission. |
| `routine-compile-command-tests` (`tests/ci/RoutineCompileCommand.Tests.ps1`) | Required | Bounded asynchronous native/script command capture, literal argument binding, progress callbacks, and output limits. |
| `routine-compile-gate-tests` (`tests/ci/RoutineCompileGate.Tests.ps1`) | Required | Actual managed entrypoint against disposable Git fixtures, native receipt validation, deadline rejection before build, and cleanup proof. |
| `unreal-automation-tests` (`tests/ci/Invoke-UnrealAutomationTests.Tests.ps1`) | Required | Portable fixture regression tests for the headless Unreal runner's engine pin, discovery, repository-state, timeout, report validation, and fail-closed exit behavior. |
| `psscriptanalyzer` (`Invoke-ScriptAnalyzer` 1.25.0 over `scripts/` and `tests/`) | Advisory | PowerShell static analysis pinned to the hosted image's exact 1.25.0 module. Contributor machines without that exact version report `skipped`; Package 3C portable acceptance nevertheless requires the hosted report to record this check as `passed`, so a hosted analyzer failure or version skip cannot produce a portable receipt. |

Required checks fail the suite and the workflow. Ordinary advisory-check
failures are reported in the same machine-readable evidence without failing
the suite; runner infrastructure failures always fail closed. The live
supported-target compile and packaged-smoke jobs are also required gates when
their event and trust predicates select them.

The suite deliberately excludes `visuals/tests/`, which is owned by the frozen
`visual-package-validation.yml` workflow described below and only needs to run
when the visual package changes.

### Historical Issue #151 compile applicability

[TA-016](architecture-decisions.md#ta-016---revision-bound-compile-applicability-for-issue-151)
records the proposed acceptance boundary for the exact ten-path
[PR #152](https://github.com/ShayShimoni/aetheln-online/pull/152) change:
base `085932aa31856041a9c5544ba4f838a2f5e66e24`,
head `278e334fda22a74f3aed9bff7128d358c7f315e1`,
merge `2919ceaaf30d89bd374c4124b7e1fe76e0c778cf`.
It takes effect only after independent review and merge of the decision.
For that historical protocol change, focused source-inspection, handoff, and
launcher regressions, retained-event reproduction, and independent
installed-Codex replacement-path QA establish the relevant behavior. Unreal
compilation does not exercise it, and ordinary portable CI excluded its
historical delivery harness. Final independent acceptance and pre-publication
event-history reconciliation remain required; this record does not close Issue
#151.

Earlier failed or missing compile evidence retains that status. TA-016 adds
no `.agents/` directory exemption, alters no classifier or future gate, and
cannot waive compilation for a future revision, including the same paths.
The retirement below separately changes the current classifier without
changing that historical decision.

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

The independent `ci-selection-shadow` job runs only for pull requests on
GitHub-hosted `windows-latest` and is bounded at 10 minutes. It has no `needs`,
self-hosted labels, or engine concurrency. Package 3C exposes the accepted-base
decisions to additive visual proof, truthful receipt publishers, and the shadow
aggregate only; no existing authoritative job consumes them. The selector
result cannot start, skip, cancel, or change the conclusion of any existing
authoritative job. Job-level `continue-on-error` keeps the selector itself
observational, but a selector failure or missing artifact prevents its dependent
Package 3C evidence from reconciling and therefore makes that new evidence path
red. It does not silently produce acceptance. The legacy
`change-impact` job remains the sole selection authority. Historically,
Package 3A changed only its remote checkout action identity to the reviewed
full SHA; after LF normalization that block from `change-impact:` through the
`trusted-candidate-compile` explanatory comment was exactly 5,633 UTF-8 bytes
with SHA-256
`f1ae549ac2b628df3a09b4d29d6b9f20e237e0c31cc3060ae44bf44923c3a9df`.
TA-018 (2026-10-02) then removed the six controller paths from the
portable-only set; the current normalized block is exactly 5,395 UTF-8 bytes
with SHA-256
`e4a7bc5968f066178d1b78cb26d15df06f60af50696cda51b8e758ca8a38c805`.

Every engine job depends on `quality-gates`: `trusted-candidate-compile` and
milestone phase 1 (`scheduled-client-package`) declare `needs: quality-gates`
with the implicit success condition and no status-function bypass, so a
portable failure, cancellation, or skip keeps every engine job off the
self-hosted runner. Phases 2 to 4 chain through phase 1.

### Pull-request change-impact classifier

The `change-impact` job (GitHub-hosted `windows-latest`, `pull_request` only,
bounded at 10 minutes) decides whether a pull request needs trusted Unreal
compilation. It uses the reviewed
`actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1`
(v7.0.1) and repository-owned PowerShell only; no third-party action. The exact pull-request base SHA and head SHA
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
- Exactly `scripts/build/Build-PackagedArtifacts.ps1` and
  `scripts/build/Invoke-PackagedSmokeTest.ps1`

Until 2026-10-02 the set also exempted exactly `scripts/ci/Invoke-CiSuite.ps1`,
`scripts/ci/Test-FormattingPolicy.ps1`, `scripts/ci/Test-MarkdownLinks.ps1`,
`scripts/ci/Invoke-EngineRunnerGate.ps1`,
`scripts/ci/Initialize-CompileWorkspace.ps1`, and
`.github/workflows/prototype-quality-gates.yml` (the lead's 2026-09-06
applicability decision recorded in TA-012). Unreal compilation does not
validate portable scheduling, policy checks, or workflow YAML logic, and the
required portable suite (including its runner, formatting, Markdown, workflow,
and scheduling-policy fixture suites) plus independent review remain mandatory
for those files. TA-018 nevertheless removes those six paths from the exempt
set: a pull request that changes only controller files now runs the real
supervised compile so the native producer can publish
`controller-operational-proof`. The compile is operational proof that the
candidate controller drove the engine runner, not validation of its YAML or
scheduling logic. This is not a blanket scripts or workflow exemption: matching
uses exact case-sensitive paths, not prefixes, filename lookalikes, or
extension substitutions. Passing local fixtures does not prove live workflow
activation, engine execution, or scheduled milestone completion.

The two remaining exact orchestration exemptions follow the owner's CI-redesign
authorization and independent applicability review on 2026-09-06. Their PR
gates are the full required portable suite (including packaging, smoke, and
post-command-state fixtures) plus independent review. Compile does not execute
the packaging controller or smoke evidence writer, and a `scripts/build/`
change co-selects the unsupported `clean-package-provenance-smoke` obligation,
so a compile could not become operational proof for it. Revisit these
exceptions if an orchestration script begins generating engine inputs. A
simultaneous engine-input change still requires compilation.

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

### Pull-request shadow selector (Issue #167 Package 2)

The shadow job fetches the exact pull-request event base, head, and synthetic
workflow merge with complete ancestry into a fresh bare/no-checkout control
repository. It verifies that the merge has exactly two parents, its second
parent is the event head, and the event base is an ancestor of its first parent.
The verified first parent is the accepted comparison and controller revision;
the event base may be older when the target branch advances before the run.
Only after those identities and relationships are verified does the reviewed
`actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1`
sparsely check out `scripts/ci/Get-CiSelection.ps1` from the exact accepted
first parent into a separate run/attempt control path. No candidate selector,
repository script, filter, or hook is checked out or executed. When the
accepted-base controller exists, its Git blob OID and SHA-256 are recorded and
the checked-out bytes must match that blob before PowerShell executes them.
The controller reads the candidate trees from the bare object database;
`execution.checkoutAllowed` is always `false`.
Private-repository fetches use the ephemeral per-run `github.token` only as a
masked, per-command HTTP authorization header. The token is not embedded in a
remote URL, persisted by checkout, written to Git configuration, or included
in the report.

The Package 2 bootstrap base does not contain the selector. That expected case
writes a closed `aetheln.ci-selection/v1` record with
`execution.mode=accepted_controller_unavailable`, null controller OID/SHA-256,
every check conservatively selected, `selection.shadow=true`,
`selection.authoritative=false`, legacy authority `not_observed`, and
comparison `unavailable`; its policy digest is 64 zeroes because no accepted
policy/controller exists at that accepted first parent. This is a diagnostic bootstrap boundary, not a
comparison, equivalence, or selector-acceptance claim. A later pull request is
the first meaningful live comparison after this controller is accepted-base
code.

The CLI accepts `-ContextJson`, `-OutputPath`, and `-RepositoryRoot`. The
Package 3B pre-activation controller requires canonical `runId` and
`runAttempt` fields in every event context. A pull-request context otherwise
has exactly `kind`, `baseRevision`, `headRevision`, `workflowRevision`, and
`controllerRevision`; revisions are 40 lowercase hex Git IDs. The workflow
requires the event base to be an ancestor of the verified merge first parent,
and the second parent to equal the event head. The live context passes the
verified first parent as both
`baseRevision` and `controllerRevision`, matching the previously accepted
controller's closed input contract while this workflow change is reviewed.
The event base is retained separately in the workflow preflight and is checked
before checkout; it is not a selector-context field in the live job. The
selector retains its strict base/controller equality and ordered parent checks.
The report's `source.baseRevision` and comparison diff use the accepted first
parent.
Missing ancestry or any conflicting parent/controller identity fails closed.
The closed output roots are `schemaVersion`, `attemptAnchor`,
`policy`, `source`, `execution`, `classification`, `selection`,
`legacyAuthority`, and `comparison`. `attemptAnchor` uses
`aetheln.current-attempt-anchor/v1` and binds the canonical run and attempt to a
fresh, nonzero, 64-lowercase-hex nonce generated from exactly 32 CSPRNG bytes.
RNG failure has no deterministic fallback and publishes no selector report.
Package 3C retains that accepted-base execution boundary and completes the
non-authoritative wiring around it. The workflow supplies the canonical run ID
and integer attempt, validates the returned anchor's exact closed schema and
native types, and rejects a mismatched or all-zero nonce before publishing
anything. `ci-selection-shadow` exposes the nonce, `aggregate_ready`, every one
of the eight `*_required` decisions, and the selector archive's exact artifact
ID, nonce-suffixed name, and API digest through direct `needs` outputs. The
unavailable-controller fallback uses the same fresh 32-byte CSPRNG rule and has
no deterministic nonce fallback. None of these outputs is acceptance
authority. The historical Package 3A policy `shadow-v1` had canonical digest
`52f43ef45d9515bae76315026674ac0e052823b6dc63ec9ed008d093774c90a4`
and exactly these historical check IDs: `portable`, `visual-package`,
`delivery-harness`,
`native-client-server-compile`, `unreal-editor-automation`,
`content-reference-validation`, `controller-contract`,
`controller-operational-proof`, and `clean-package-provenance-smoke`.
Obligations contain exactly `id`, `selected`, and `reasons`. Success reasons
are `path:<path>`, `attribute:<path>`, or `scheduled_event`; uncertainty keeps
the fail-closed reason token that caused it, never an empty successful result.
Reusable-call contexts additionally preserve the closed `callerKind` plus the
caller workflow revision. A called pull request validates the same ordered
accepted-base/head parents; its caller must check any separate event-base
ancestry witness before executing the selector. Called pushes bind workflow and
controller revisions to the head; called schedules bind both to the scheduled
revision. The `source`
record retains `callerKind` instead of collapsing called events into an
ambiguous generic context.

Paths outside the closed documented/controller/visual/agent-tooling/engine/build
families fail closed as `path_unclassified`, producing an all-obligations
conservative report. Adding a new repository root therefore cannot silently
inherit portable-only treatment. Agent-tooling and build-test paths retain
portable proof; build scripts retain controller-operational and clean-package
proof. Production CI scripts and workflows select both controller
contract and operational proof; plugin Content also selects content-reference
validation. Ordinary source, plugin source, and the project descriptor select
native client/server compilation plus Unreal Editor automation, but not a
clean milestone. Runtime Config, Content, and plugin Content add
content/reference validation without selecting a clean milestone. Schedule,
build-controller, and unknown/conservative cases retain clean package,
provenance, and smoke selection. The production visual-evidence controller
selects visual validation as well as controller contract and operational proof,
so changing the wrapper cannot skip execution of the two real validators.
The digest is SHA-256 over the accepted selector source after deterministic LF
normalization, so changes to mappings, contexts, limits, uncertainty behavior,
or attribute rules change the policy identity. `controllerSha256` separately
binds the exact unnormalized blob bytes that executed.

The Package 3B pre-activation selector candidate had canonical normalized digest
`605a3fc7a16e2664492a51bc44a3d267ee6e9955043811c1be4ce4c988f2fe4b`.
The direct-delivery retirement candidate on develop has normalized digest
`a1be534a661508fdccae17ea7623b2c3f215119a07cdc66ef7ab8653a9925536`
and eight check IDs: `portable`, `visual-package`,
`native-client-server-compile`, `unreal-editor-automation`,
`content-reference-validation`, `controller-contract`,
`controller-operational-proof`, and `clean-package-provenance-smoke`.
Package 3C also strengthens the run-identity anchor regexes to whole-input
`\A...\z` matches. Its earlier selector candidate was 39,772 LF-normalized
bytes with digest
`913411858dae63ff48de296ef59d4f5d84aeb43dc55759874f6cb4d03bb0a55d`.
The current-base reconciliation explicitly classifies the exact #181
content-validation launcher and two contract tests, while new unwired paths
still fail closed. This candidate is 40,236 LF-normalized bytes with digest
`4e21f35a4791332176edd1f51c4ccf69115fb34bc2defda5b8e6716206aa2b46`.
This is a different policy identity and requires fresh accepted-base live
shadow observations after merge before any later producer or activation change.
The #181, #87, and #81 suite additions remain outside this manifest until
their source pull requests are accepted on the integration branch; the three
existing portable/receipt/aggregate lists and the two byte-identical
`controller-contract` suite subsets in the receipt producer and aggregate must
change together at that time.

Classification uses binary `git diff --raw -z --no-abbrev --no-ext-diff
--no-textconv --find-renames --find-copies-harder`. Rename/copy entries classify
both paths and preserve status, score, modes, OIDs, and paths. The head tree
allows regular blob modes `100644` and `100755` only. Submodules, symlinks,
absolute/backslash/traversal paths, Windows reserved/invalid components,
trailing dot/space, overlong components, and ordinal case-insensitive or
Unicode-NFC collisions fail closed before any runner can consume the result.

Attributes are read from each exact revision with `git check-attr --source`
for `filter`, `diff`, `merge`, and `text`. System attributes are disabled, an
empty explicit attributes file is used, and repository `info/attributes` is
rejected. A `.gitattributes` change compares effective attributes across every
bounded base/head path. LFS Content selects content-reference and native
compile; LFS visuals select visual validation. `.lfsconfig` changes are
unsupported and conservative.

Each Git operation is bounded to two minutes, stdin and stdout to 8 MiB, stderr to
64 KiB, raw diff and tree entries to 4,096 each, one path to 4,096 UTF-8 bytes,
and the final JSON to 4 MiB at maximum JSON depth 16. Package 3C uploads exactly
`ci-selection-shadow.json` as
`ci-selection-shadow-<run-id>-<run-attempt>-<nonce>` with no `retention-days`
override. The workflow rejects an anchor whose run, attempt, schema, or nonce
does not match the current invocation before exposing the nonce to the upload
name. Selected receipt publishers download this artifact by its direct artifact
ID and carry the same anchor into their closed identity context. The aggregate
also receives the selector job name, artifact ID, exact name, and API digest as
a direct binding, then independently reconciles that binding with the GitHub
run, job, artifact, and downloaded bytes. The predictable Package 3A name is no
longer emitted and is insufficient authority evidence.
Evidence unavailable outside this controlled process/artifact boundary is
unavailable evidence, never an implicit selector pass.
Because the shadow job has no dependency on `change-impact`, its own record
uses `legacyAuthority.reason=not_observed`, a null legacy engine decision, and
`comparison.status=unavailable`. Package 2 never fabricates an in-job legacy
comparison; later receipt aggregation may compare actual same-attempt job
evidence without granting the shadow selector authority.

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
| `ci-selection-shadow` | `pull_request` | None | Diagnostic only; exact accepted-base controller bytes, never candidate selector bytes. | Produce the closed current-attempt selector artifact and expose its nonce, all eight required decisions, aggregate readiness, and exact artifact ID/name/digest as non-authoritative direct outputs. |
| `visual-proof` | `pull_request` | `ci-selection-shadow` | Runs only when the accepted-base selector selects `visual-package`; the reusable call remains additive and non-authoritative. | Execute both existing visual validators and expose the exact raw report artifact ID/name/digest plus inner report SHA-256/length. |
| `portable-receipt-shadow` | `pull_request` | `ci-selection-shadow`, `quality-gates` | Runs only when `portable` is selected and both direct producers succeed. | Download the selector and portable report by exact artifact ID, validate their direct name/digest metadata, verify the inner report hash/length, then publish one nonce-bound receipt whose checks are the selector-derived subset of {`controller-contract`, `portable`}, every result bound to the one raw `ci-report.json`. The aggregate later verifies each archive digest against GitHub's API and downloaded bytes. |
| `native-receipt-shadow` | `pull_request` | `ci-selection-shadow`, `trusted-candidate-compile` | Runs only when `native-client-server-compile` or `controller-operational-proof` is selected and the compile succeeds. | Apply the same direct binding and truthful publication contract to the exact compile report, publishing the selector-derived subset of {`controller-operational-proof`, `native-client-server-compile`} with every result bound to the one raw `engine-runner-report.json`, successful native exit, and cleanup proof. `controller-operational-proof` attests that the candidate controller at the tested revision ran the real supervised Compile gate on the engine runner with resource monitoring and verified cleanup in this attempt; it is the same exact report, revalidated under its own check id. The self-hosted producer hashes the report with the portable .NET SHA-256 API because that runner's Windows PowerShell environment does not expose `Get-FileHash`; its upload retains the static report artifact name even if identity binding fails. |
| `visual-receipt-shadow` | `pull_request` | `ci-selection-shadow`, `visual-proof` | Runs only when visual validation is selected and succeeds. | Apply the same direct binding and truthful publication contract to the exact bounded visual report. |
| `ci-acceptance-shadow` | `pull_request`/`push`/`schedule` | Every current producer and receipt publisher directly | GitHub-hosted, bounded, the sole enabled job-level `always()`, and the only live job with job-scoped `actions: read`; never joins engine concurrency. The dormant authority boundary has the second structural `always()`. | On a PR whose selected obligations are all in the portable/controller-contract/controller-operational-proof/native/visual supported subset, execute the real shadow aggregate with direct selector and producer bindings. If any selected obligation lacks a live producer contract, publish the explicit green `producer_contract_incomplete` no-acceptance gap. Non-PR events publish `event_not_applicable`. Unexpected identity, reconciliation, semantic, or publication errors remain red. |
| `ci-acceptance-authority` | `pull_request` | `ci-acceptance-shadow` | Hard-skipped by the literal `always() && github.event_name == 'pull_request' && false`; job-scoped `actions: read` is dormant. | Reserved activation boundary: when later enabled, it still runs after a failed or cancelled aggregate and fails unless `needs.ci-acceptance-shadow.result` is exactly `success`; only a complete, nonce-bound reconciled shadow aggregate could produce an authority receipt. It grants nothing in the live Package 3C workflow. |
| `trusted-candidate-compile` | `pull_request` | `quality-gates`, `change-impact` | `engine_required == 'true'`, the head repository is this repository, the PR author is the repository owner, and `github.triggering_actor` is the repository owner. | Incrementally compile the supported Windows client and Linux server targets without packaging. |
| `scheduled-client-package` | `schedule` at `02:00 UTC` daily | `quality-gates` | Schedule-only; the schedule exists only on the protected default branch once this workflow reaches `main` through normal Git Flow. | Milestone phase 1: clean-package the Windows client and publish it to the durable handoff store. |
| `scheduled-server-package` | `schedule` | `scheduled-client-package` | Same as phase 1. | Milestone phase 2: clean-package the Linux dedicated server, dump its registry evidence, and publish both to the handoff store. |
| `scheduled-provenance-validation` | `schedule` | `scheduled-server-package` | Same as phase 1. | Milestone phase 3: verify both handoff payloads, validate server cook references, and write bound provenance. |
| `scheduled-packaged-smoke` | `schedule` | `scheduled-provenance-validation` | Same as phase 1. | Milestone phase 4: verify every handoff payload and smoke the packaged client/server pair. |

Package 3C pins this workflow's numeric GitHub identity as `326989724` and its
complete remote-action manifest as
`actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1`,
`actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093`,
and
`actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a`.
`New-CiAcceptanceAggregateContext.ps1` validates the accepted selector and
those workflow/action identities. Identity mode creates the closed context used
by each receipt publisher, including `selection.checks`: every obligation the
selector selected, in selector order, copied from the selector report bytes
rather than from workflow booleans. Each publisher keeps only the obligations
its typed report can prove. The aggregate context never carries that
`selection`. Aggregate mode additionally combines the static
`ci-acceptance-requirements.json` template with the current nonce, validates
the direct selector binding and sorted direct producer bindings, and writes
both the aggregate context and nonce-specific runtime requirements. The
template maps all eight obligations to their intended receipt jobs; it does not
claim that every mapped semantic producer is implemented. The selector report
and repository requirements template are UTF-8 without BOM and require exactly
one trailing LF, matching their production writers. Embedded action and direct
binding JSON remains compact with no leading or trailing whitespace; generated
identity, aggregate, and runtime-requirements outputs add no line terminator.
Receipt jobs invoke the context builder in-process with PowerShell splatting;
they never forward JSON through a nested native `powershell.exe` command line,
where Windows PowerShell 5.1 would strip embedded JSON quotes.

`aggregate_ready=true` only when every selected obligation is in the currently
wired semantic subset: `controller-contract`, `controller-operational-proof`,
`native-client-server-compile`, `portable`, and `visual-package`. In that case the aggregate derives the selected producer set
from the selector report, requires the corresponding direct `needs` binding,
and verifies each binding's job name and exact artifact ID/name/digest against
the same-attempt GitHub API record and downloaded archive. Missing, duplicate,
extra, unselected, swapped, replayed, malformed, unsorted, or digest-mismatched
bindings fail the job. The native binding is required when either
`native-client-server-compile` or `controller-operational-proof` is selected;
any selector output pair other than exact `true`/`false` values fails closed as
`producer_direct_binding_invalid:native`. If the selector chooses any of the other three
obligations, `aggregate_ready=false` and the workflow validates the selector
identity before publishing a green, explicitly incomplete
`producer_contract_incomplete` record with
`complete=false`, `shadow=true`, `authoritative=false`, and
`grantsAcceptance=false`. The green result means the known producer gap did not
break unrelated pull requests; it is not acceptance. Any unexpected failure
outside that exact branch stays red.

Package 3C does not activate authority. The dormant
`ci-acceptance-authority` job is deliberately hard-skipped by one literal
`false` in the `always() && github.event_name == 'pull_request' && false`
predicate. The `always()` status function is part of the reviewed dormant
template: after activation, failed or cancelled aggregate evidence runs this
boundary and fails red rather than becoming a skipped required check. The job
also requires the direct aggregate result to equal `success` before accepting
any output.

After Package 3C merges, two separate fresh accepted-base pull-request
observations are mandatory before the next producer or activation package:

1. A supported-only change must exercise the accepted selector, every selected
   raw producer and receipt publisher, their direct bindings, and the real
   complete shadow aggregate.
2. An unsupported-selection change must exercise the exact green
   `producer_contract_incomplete` branch and prove it remains explicitly
   incomplete and non-granting.

For both observations, record the exact run and attempt, accepted base, head and
tested-merge revisions, selector artifact ID/name/API digest, every selected raw
and receipt artifact ID/name/API digest, aggregate or gap report SHA-256, the
attempt nonce, and the final `complete`, `shadow`, `authoritative`, and
`grantsAcceptance` values. One observation cannot substitute for the other.
A supported-only observation that exercises both controller obligations needs an
owner pull request that changes a `scripts/ci/` file or the live workflow
without any `scripts/build/` path: it selects `portable`,
`controller-contract`, and `controller-operational-proof`, the classifier
requires the compile, and the expected result is `aggregate_ready=true`, a
`native-receipt-shadow` receipt carrying only `controller-operational-proof`, a
portable receipt carrying `controller-contract` and `portable`, and a
`complete=true`, `shadow=true`, `authoritative=false`, `grantsAcceptance=false`
aggregate report. A `scripts/build/` change still co-selects the unsupported
`clean-package-provenance-smoke` and takes the gap branch. A non-owner pull
request that selects `controller-operational-proof` skips the compile under the
trust predicates and fails red at `producer_direct_binding_invalid:native`, the
same pre-existing behavior as `native-client-server-compile`.
Push and schedule runs have no accepted event-specific selector producer: they
emit `event_not_applicable` and remain non-authoritative.

That observation is necessary but not sufficient for activation. Changing the
live workflow itself selects `controller-contract` and
`controller-operational-proof`, which now both have truthful receipt producers
(portable and native). The requirements-template bytes changed with the native
producer, so activation pins still come only after a fresh accepted-base
observation of this wiring; no activation policy or template is published.
No Package 3C activation policy or pre-reviewed template is published. Before a
one-file activation can exist, a separate reviewed package must either add and
shadow-observe a truthful controller-operational receipt or replace this selection boundary
  with an independently justified, fail-closed contract. Only after that work may
  an accepted-base policy pin a template whose only candidate delta is the final
  literal `false` to `true` in the dormant predicate, while controller,
  publisher, aggregate,
requirements, checker, action pins, and every other dependency remain
immutable. The accepted-base external checker and trusted caller must then
approve the candidate.

The four phases are schedule-only and keep the same `needs` chain, job
bounds, concurrency block, handoff contract, and per-phase artifacts. There is
no single-job package and smoke entry point: no workflow job selects the
gate's `PackagedSmoke` mode or holds the engine runner for a 24-hour bound.
Pull requests and pushes cannot start any of the four phases, and no manual
trigger exists.

Per event, the jobs that can run are:

| Event | `ci-selection-shadow` | `quality-gates` | `change-impact` | `trusted-candidate-compile` | Phases 1 to 4 |
| --- | --- | --- | --- | --- | --- |
| `pull_request` | Runs independently; diagnostic only | Runs | Runs | Only after both authoritative prerequisites succeed, `engine_required == 'true'`, and the trust predicate holds | Skipped |
| `push` to `develop` | Skipped | Runs | Skipped | Skipped | Skipped |
| `schedule` | Skipped | Runs | Skipped | Skipped | Phase 1 only after `quality-gates` succeeds; each later phase only after its predecessor succeeds |

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

The Compile workflow step runs from a fresh, exact-revision
`compile-control-<run>-<attempt>/` checkout. The operator registers a separate
retained compile workspace; `actions/checkout` never manages that directory.
Immediately before that checkout, the workflow records UTC evidence and the
host's monotonic timestamp in `AETHELN_COMPILE_STARTED_UTC` and
`AETHELN_COMPILE_STARTED_TIMESTAMP`. A manual equivalent must capture both on
the same host before staging; a launch-time replacement is not evidence that
checkout time was charged. The command uses run-scoped evidence and explicit
operator configuration:

```powershell
$RunRoot = Join-Path '${{ runner.temp }}' 'aetheln-engine-${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}'
powershell -NoProfile -File scripts/ci/Invoke-EngineRunnerGate.ps1 `
  -Mode Compile `
  -RepositoryRoot '${{ github.workspace }}/compile-control-${{ github.run_id }}-${{ github.run_attempt }}' `
  -SourceRevision '${{ github.sha }}' `
  -Repository '${{ github.repository }}' `
  -RunnerName '${{ runner.name }}' `
  -ManagedWorkspaceRoot $env:AETHELN_MANAGED_COMPILE_ROOT `
  -ManagedWorkspaceRegistrationPath $env:AETHELN_MANAGED_COMPILE_REGISTRATION `
  -ManagedWorkspaceRegistrationSha256 $env:AETHELN_MANAGED_COMPILE_REGISTRATION_SHA256 `
  -HostLeasePath $env:AETHELN_ENGINE_HOST_LEASE `
  -CompileStartedUtc $env:AETHELN_COMPILE_STARTED_UTC `
  -CompileStartedTimestamp $env:AETHELN_COMPILE_STARTED_TIMESTAMP `
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
covering checkout, input discovery, both targets and diagnostics. The workflow
captures UTC evidence and the host's monotonic timestamp before control checkout;
the parent, lease acquisition, synchronization and build child retain that same
anchor. Wall-clock adjustments cannot grant more time or prematurely expire the
managed budget. The supervisor owns
and stops its child tree on expiry; a timeout is failure, never compile
success or clean-package evidence. No automatic timeout increase or cold-build
retry is permitted.

Issue #167 separates disposable control source, the operator-registered retained
compile workspace, and `milestone/` for the four scheduled phases. A prepared
linked worktree has a `.git` file, not a clone's `.git` directory; pointing
`actions/checkout` at it can delete its prepared outputs even with cleaning
disabled. The workflow therefore checks out only a fresh run/attempt control
directory, with exact `github.sha`, LFS disabled, no persisted credentials and
a five-minute checkout limit. Every milestone checkout uses
`fetch-depth: 0` so the DDC repository identity from
`git rev-list --max-parents=0 HEAD` resolves the actual root-commit set across
source revisions instead of a shallow checkout boundary. This preserves the
identity input; it does not prove cache reuse or a runtime improvement.
Milestone checkout retains default cleaning and packaging retains `-clean`.
It cannot erase Compile outputs. The managed path acquires the same exclusive
host lease as preparation before synchronization and holds it until the owned
child tree is proven quiescent. Registration validation, exact local Git
import/non-force detached checkout, input validation and both native builds
run inside the compile supervisor's original deadline. A missing or false
cleanup proof never releases the lease; handles close but the held journal
remains for explicit recovery. No implicit cleanup, reset, output copying or
cold-workspace fallback is performed. `Initialize-CompileWorkspace.ps1` remains
a separately tested legacy helper, not an automatic managed-workspace step.

Before synchronization, routine admission resolves the control, target, engine,
toolchain, evidence, temporary and Git-common roots to unique physical volumes.
Each volume must retain more than its known allocations plus a 20 GiB recovery
floor. Five-second monotonic samples stop on disk-floor failure or three
consecutive samples below 2 GiB available RAM or commit headroom. Each target
refreshes admission and limits local-only UBA actions to the minimum of four,
physical cores, and the RAM/commit capacities after a 6 GiB reserve at 3 GiB per
action. Invalid or unavailable measurements fail closed. The outer supervisor
still bounds a stalled resource probe; sampling is not a replacement watchdog.

Scheduled phase child mode is not authorized by a reusable environment marker.
The parent creates a fresh 256-bit nonce for each launch and binds it to the
direct parent process ID and that process's UTC start ticks through matching
internal parameters and process-scoped environment values. The child accepts
only exact canonical values and byte-identical nonce bindings; an inherited,
partial, mismatched, uppercase, stale, or replayed credential fails
`phase_supervisor_auth_invalid` before phase work. The parent restores every
prior value in `finally`. This authentication protects the supervisor boundary;
it does not turn candidate workflow code into an independent trust authority.

Managed commands use asynchronous, bounded output capture with deadline/resource
callbacks while running and draining streams. Each native build must produce a
bounded, validated receipt and log, and its recorded exit must match the wrapper
exit. A successful parent report requires unique passed client and server checks,
the revision/registration-bound synchronized workspace proof, two healthy target
admissions and verified child-tree cleanup. Missing, skipped, duplicate or
contradictory success evidence fails the gate; a partial failure report remains
available for diagnosis.

Provision these repository variables explicitly; the workflow maps them into
only the compile step, and none is a secret:

| Variable | Meaning |
| --- | --- |
| `AETHELN_MANAGED_COMPILE_ROOT` | Absolute prepared local target directory |
| `AETHELN_MANAGED_COMPILE_REGISTRATION` | Absolute operator-owned JSON registration outside `.git` |
| `AETHELN_MANAGED_COMPILE_REGISTRATION_SHA256` | Exact lowercase SHA-256 of that registration |
| `AETHELN_ENGINE_HOST_LEASE` | The same absolute `.lease` file used by preparation |

Registration schema 1 is closed: `schemaVersion`, `registrationId` (32 lowercase
hex characters), `repository`, `targetRoot`, `gitCommonDirectory`, and
`preparationReceiptSha256` (64 lowercase hex characters). Its bounded reader
retains the file and directory handles and verifies the configured hash and
repository/root tuple. The synchronizer independently verifies the actual Git
common directory, exact control and resulting target revisions, clean index,
tracked bytes, selected input collisions and unsafe paths. Operator registration
authorizes the existing trusted Git contexts, including normal hooks/filters;
it is not candidate self-certification or permission to adopt a new LFS endpoint.

Selected compile-input LFS files must already contain the committed OID and
size; missing hydration fails `managed_workspace_lfs_hydration_required`.
Unrelated LFS assets may remain exact committed pointers. No endpoint fallback
or network hydration is inferred. Changed LFS material requiring provisioning
therefore remains an explicit recovery condition until bounded trusted hydration
is operationally verified. Retained tracked text must preserve committed bytes;
the prepared target uses byte-preserving checkout settings.

Required serial fixtures cover `engine-host-lease-tests`,
`managed-compile-registration-tests`, `managed-compile-workspace-tests`,
`managed-compile-integration-tests`, `routine-compile-deadline-tests`,
`routine-compile-resources-tests`, `routine-compile-command-tests`, and
`routine-compile-gate-tests`. The latter includes the real managed entrypoint
against disposable Git fixtures and a fake native build wrapper. These passes do not certify registration
deployment or an actual hosted compile. Initial preparation measurements and
future routine runs remain separate evidence.

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
- Package 3C emits attempt-specific
  `ci-receipt-<job-key>-<run-id>-<run-attempt>-<nonce>` archives for the three
  truthful live semantic producers: portable quality, native client/server
  compile, and visual validation. Together they cover five obligations: the
  portable producer covers both `portable` and `controller-contract` from the
  same report, and the native producer covers both
  `native-client-server-compile` and `controller-operational-proof` from the
  same compile report. Each archive contains exactly one closed
  `ci-acceptance-receipt.json` and the one typed raw report named by it. Before
  publication, the producer exposes its raw archive ID/name/API digest and
  inner report SHA-256/length as direct outputs; the receipt publisher downloads
  that exact artifact by ID, verifies both layers, and creates a new
  nonce-suffixed output root. No successful summary or opaque digest can replace
  typed raw evidence.
- `portable` revalidates the exact `ci-report.json` inventory and required
  conclusions; the `controller-contract` receipt independently revalidates the
  25-suite `tests/ci` subset of that same exact `ci-report.json`, and the
  acceptance aggregate additionally requires that receipt alongside the
  portable, native, and visual receipts; `native-client-server-compile`
  revalidates the exact
  `engine-runner-report.json`, both compile targets, runner identity, native
  exit, supervisor, managed workspace, resource proof, and cleanup; the runner
  identity compared against the report is the self-hosted
  `trusted-candidate-compile` job's `runner_name`, which the aggregate resolves
  from the attempt jobs and validates (success, interval, exact labels) before
  it accepts the hosted `native-receipt-shadow` publisher's receipt;
  `controller-operational-proof` revalidates that same exact
  `engine-runner-report.json` under its own check id (reasons
  `receipt_semantic_evidence_invalid|failure:controller-operational-proof`)
  against the same bound compile job, so a receipt carrying both native
  obligations validates the one report once per result; and
  `visual-package` revalidates the exact bounded
  `aetheln.visual-package-report/v1`. The aggregate contains a semantic adapter
  for `unreal-editor-automation`, but no live Package 3C receipt publisher feeds
  it, so it remains unsupported along with
  `clean-package-provenance-smoke` and `content-reference-validation`. Selection of any
  unsupported obligation follows the
  explicit `producer_contract_incomplete` no-acceptance path.
- Selector, receipt, aggregate, and future authority artifacts all bind the same
  closed `attemptAnchor`. Artifact timestamps, direct artifact ID/name/digest,
  API/download digests, exact job run/head/attempt identity, and native runner
  identity are mandatory. No receipt or aggregate may override a native exit,
  infrastructure failure, missing producer, skipped selected job, partial
  rerun, newer attempt, cleanup failure, or binding mismatch. All Package 3C
  receipts and aggregates remain shadow-only and grant no acceptance.
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
  `Content/Maps/StarterMap.umap`. Client/server packaging jobs fetch `Content/**`.
  The compile control checkout does not fetch LFS; its registered retained
  workspace must supply verified, materialized compile inputs. Missing selected
  LFS inputs fail closed and require explicit provisioning. Provenance validation
  and scheduled smoke consume
  the verified handoff payloads and do not fetch LFS Content.
- Artifact retention periods remain an open decision and are not configured.

## Secret Policy

- The workflow default remains `permissions: contents: read` and consumes no
  repository or organization secrets. Package 3C adds `actions: read` only to
  `ci-acceptance-shadow`, which actually reconciles same-run jobs and artifacts,
  and to the hard-skipped `ci-acceptance-authority` boundary. Other jobs inherit
  the read-only default. Receipt publishers use direct `needs` outputs and
  exact-ID same-run artifact downloads; they do not receive broader workflow
  permissions.
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

`.github/workflows/visual-package-validation.yml` continues to own validation
of the non-canonical visual package. It retains its path-filtered pull-request
and `develop` push triggers for visual inputs, attribute policy, its workflow,
and the production visual-evidence controller. It retains both validators and
exposes an additive `workflow_call` entry point. Package 3C calls it only when
the exact accepted-base shadow selector selects `visual-package`; that call
remains non-authoritative and preserves both direct triggers. The reusable
workflow now exposes its raw artifact ID/name/digest and inner report
SHA-256/length so `visual-receipt-shadow` can bind the truthful report directly.
The visual workflow still does not run the portable suite. Both validators execute through
`scripts/ci/Invoke-VisualPackageValidation.ps1`, which reduces output while it
streams, caps each captured line and validator aggregate, rejects unsafe report
budgets before serialization, and publishes one create-only, attempt-specific
`visual-package-report.json`. Direct visual triggers remain authoritative; only
the selector-requested reusable call neutralizes its conclusion. The reusable
call removes no existing authority and creates no bypass.

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

`ci-selection-shadow.json` uses the closed `aetheln.ci-selection/v1` schema
documented under
[Pull-request shadow selector](#pull-request-shadow-selector-issue-167-package-2).
It is diagnostic, non-authoritative evidence. Package 3C exposes all eight
selection decisions, aggregate readiness, the attempt nonce, and the selector
artifact's exact ID/name/digest to direct downstream `needs`; no authoritative
job reads them. Only a separately reviewed, accepted-base-checked activation
may consume a complete reconciled result.

`visual-package-report.json` uses `aetheln.visual-package-report/v1`. It binds
the repository, tested revision, run and attempt, both validator identities,
native exits, conclusions, timing, capture ceilings, truncation/drop counters,
and bounded captured output. The workflow uploads only that exact file and
fails if it is missing; validator failure is still preserved in the report
before the direct job fails or the explicitly non-authoritative reusable job is
neutralized.

The live Package 3C `ci-acceptance-receipt.json` contract uses
`aetheln.ci-acceptance-receipt/v1`. It binds the repository, event actors,
base/head/tested revision, workflow and ordered parents, accepted controller and
policy, reviewed full-SHA action manifest, run/attempt, selected obligation
IDs, normalized result state, native exit, infrastructure and cleanup state,
the exact closed current-attempt anchor, and SHA-256/length of every raw
evidence file. One receipt belongs to one named receipt-publisher job. The live
publisher takes a producer key, not a check ID: `portable` may prove
`controller-contract` and `portable` from `ci-report.json`, `native` proves
`native-client-server-compile`, and `visual` proves `visual-package`. It
publishes the ordinal-sorted intersection of that fixed set with the identity
context's selector-derived `selection.checks`, drops selected obligations the
key cannot prove, and rejects an empty intersection. Every published result
names the same single typed report; a repeated evidence name is accepted only
when name, SHA-256, and size are all identical, and the archive still holds
that one file. Producer and aggregate independently revalidate the typed bytes
for every result. Every receipt remains
shadow-only and cannot grant acceptance. `unreal-editor-automation`,
`clean-package-provenance-smoke`, and `content-reference-validation`
remain unsupported until their real producer schemas, publishers, direct
artifact bindings, and validators are wired together. An opaque digest or
successful summary cannot substitute.

`aetheln.ci-acceptance-aggregate/v1` is the live hosted shadow reconciliation
record for a selector whose selected obligations are all in the supported
portable/controller-contract/native/visual subset. It does not trust caller-supplied job-selection
booleans. Instead, it requires the exact successful current-attempt
`ci-selection-shadow` job, downloads the uniquely named current-attempt
`ci-selection-shadow-<run-id>-<run-attempt>-<nonce>` artifact through bounded GitHub API
reads, requires that archive to contain only `ci-selection-shadow.json`, and
cross-binds that report to the accepted controller, policy, source and workflow
identities and the aggregate context's attempt anchor. The context contains a
direct selector binding `{jobName, artifactId, artifactName, digest}` and a
sorted direct producer-binding entry
`{key, jobName, artifactId, artifactName, digest}` for each selected live
producer. The aggregate requires those direct `needs` values to match the exact
API artifacts; missing, duplicate, extra, unselected, swapped, replayed, or
wrong bindings fail closed. Producer-job selection and receipt check IDs are
then derived from the selector report. A requirements job may cover multiple
obligations; only its selected subset is required in the receipt. The aggregate
also cross-checks both run actors, the newest matching workflow run, exact
attempt, direct producer conclusions, nonce-suffixed artifact identities, exact
job run/head/attempt and timestamps, native runner identity, receipt identities,
and raw archive contents. An
artifact's `created_at` must fall within its exact current job interval. The API
`sha256:` digest must equal the downloaded archive SHA-256; size-only matching
is insufficient. Archive safety uses absolute 32 MiB compressed, 64-entry,
4 MiB per-entry and 16 MiB total-expanded ceilings plus exact streamed lengths;
it does not reject valid bounded evidence merely for a high compression ratio.
One monotonic aggregate deadline is rechecked during API streaming and archive
expansion and immediately after every request and bounded parse; incremental
progress cannot reset that deadline.
Missing truthful producers or selector evidence, partial reruns, newer attempts,
malformed or contradictory evidence, and selected jobs that are skipped are no
acceptance. PR output is only an acceptance candidate; push output is only
post-merge hosted health.

The direct selector and producer bindings close the earlier shared-nonce
uploader ambiguity for these three live publishers: the downstream job receives
each exact artifact identity from its named producer through `needs`, and the
aggregate independently confirms that identity against GitHub. Interval checks
remain additional temporal correlation, not the sole job binding. The result is
still shadow-only because authority activation is a separate accepted-base,
one-workflow-file decision and four selector obligations still have no live
receipt contract.

When any unsupported obligation is selected, Package 3C deliberately does not
call the aggregate. A validation-only gap mode binds the selector's current
run, attempt, nonce, accepted comparison base, head, and tested revision, then
computes the exact selected unsupported set and emits
`aetheln.ci-acceptance-shadow-gap/v2` with
reason `producer_contract_incomplete`. That known gap is green and explicitly
non-authoritative; it creates no aggregate context or receipt. The
`accepted_controller_unavailable` fallback is valid only with its exact
zero-digest, null-controller, all-eight-selected, no-checkout diagnostic shape.
Contradictions and unexpected errors are red. The selector
job is pull-request-only, so push and scheduled runs use the similarly
non-authoritative `event_not_applicable` gap until an accepted event-specific
selector producer is implemented and observed.

`scripts/ci/Test-CiActivationCandidate.ps1` is the accepted-base external
activation-checker foundation. It treats the candidate repository as inert Git objects:
candidate scripts, hooks, policies, and workflows are never imported, sourced,
checked out, or executed. Its trusted caller must supply the independently
accepted base revision and policy SHA-256; the checker compares both before it
parses a closed policy from the fixed path in the exact accepted-base tree.
Git and process-tree cleanup use fixed absolute executable identities rather
than `PATH`. The checker disables Git replacement objects and inherited
configuration redirection, applies in-flight stdout/stderr/time limits, and
requires an exact base-ancestor/head/tested-merge relationship with ordered
parents and an identical head/tested tree. The candidate diff must contain only
the one live workflow path, and that workflow's bytes must equal the pinned
pre-reviewed activation template supplied by a later accepted base. Every
pinned controller/evidence input must retain its exact accepted blob and
SHA-256. The checker emits bounded UTF-8 JSON to stdout; it does not accept a
candidate policy path or write through a candidate-controlled filesystem path.
These checks establish activation-candidate conformance only. They do not make
fixture evidence authoritative or replace the required live shadow observation
and independent review. Package 3C adds the real
`scripts/ci/ci-acceptance-requirements.json` template and the dormant live
authority boundary, but deliberately does not add
`scripts/ci/activation/ci-activation-policy.json`, an activation workflow
template, or a trusted caller. A workflow-only activation selects
`controller-contract` and `controller-operational-proof`, which now have
truthful portable and native receipt producers, so a complete shadow aggregate
is reachable for an owner candidate; the dormant predicate still hard-skips the
authority job and nothing grants acceptance. The native producer wiring must be
shadow-observed on a fresh accepted base first.
Only a later accepted base may then add the exact policy/template pins and
trusted caller; its activation candidate may change only the live workflow,
must byte-match that pinned template, and may not modify any dependency it
relies on.

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
Before relaying a private scheduled-phase child report, the supervisor parent
requires the exact ordered, closed report/check/summary/compile-evidence schema;
binds mode, policy, revision, runner and timestamps; and verifies the
mode-specific build/check relationships. Missing, extra, reordered, mistyped,
or inconsistent fields reject as `phase_report_invalid`, including an otherwise
complete list of successful checkpoints. Canonical failure reports remain
relayable for diagnosis.

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
