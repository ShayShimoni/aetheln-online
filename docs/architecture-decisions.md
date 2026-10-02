# Architecture Decisions

## Document Status

This is the canonical architecture decision registry for Aetheln Online.
[Issue #59](https://github.com/ShayShimoni/aetheln-online/issues/59) establishes
the baseline. Owning spikes and tasks attach evidence and update candidate
entries through reviewed documentation changes.

The registry records semantic decisions. It does not approve an implementation
merely because a product appears in research or an example.

## Status Model

- **Accepted:** governs implementation in its stated scope.
- **Candidate:** requires evidence before selection.
- **Rejected:** not allowed under current evidence and constraints.
- **Superseded:** replaced by a newer accepted entry with an explicit link.

Every accepted decision records:

- Decision and scope.
- Rationale and constraints.
- Owning issue and evidence.
- Alternatives considered.
- Consequences and implementation obligations.
- Revisit trigger.

## Accepted Decisions

### TA-001 - Unreal Engine 5.8 C++ Baseline

- **Status:** Accepted
- **Scope:** Prototype and current roadmap
- **Decision:** Use an Unreal Engine 5.8 C++ project. Support a Windows x64
  client and Linux x86-64 dedicated-server target.
- **Rationale:** The selected engine and server-authoritative prototype direction
  are established product constraints. C++ and a source engine build are
  required by Epic's current dedicated-server workflow.
- **Owner/evidence:** Issues
  [#13](https://github.com/ShayShimoni/aetheln-online/issues/13) and
  [#15](https://github.com/ShayShimoni/aetheln-online/issues/15) must pin and
  prove the exact engine revision and toolchains.
- **Rejected alternatives:** Reopening engine selection without new evidence;
  editor-only server evidence; an unversioned launcher-only production
  baseline.
- **Consequences:** Packaged target builds are part of the prototype gate.
- **Revisit trigger:** A blocking platform/toolchain fact or measured engine
  limitation that cannot be resolved within scope.

### TA-002 - Dedicated-Server Authority

- **Status:** Accepted
- **Scope:** All consequential gameplay
- **Decision:** Dedicated servers own movement validity, combat outcomes,
  territory policy enforcement, progression commands, rewards, and world
  objective results. Clients submit bounded intent and may predict only
  reversible presentation/state supported by the architecture.
- **Rationale:** Mandatory PvP, meaningful equipment, persistent rewards, and
  contested resources require one authoritative result.
- **Owner/evidence:** Issues
  [#2](https://github.com/ShayShimoni/aetheln-online/issues/2),
  [#40](https://github.com/ShayShimoni/aetheln-online/issues/40), and
  [#44](https://github.com/ShayShimoni/aetheln-online/issues/44).
- **Rejected alternatives:** Peer authority, client-claimed hits/damage, and
  client-generated reward outcomes.
- **Consequences:** Every rejection path is tested and observable.
- **Revisit trigger:** None for client authority; implementation mechanisms may
  evolve while preserving server ownership.

### TA-003 - CMC, GAS, and Pure Free Aim

- **Status:** Accepted
- **Scope:** Player and AI combat foundation
- **Decision:** Use `UCharacterMovementComponent` for predicted/reconciled
  player movement and the Gameplay Ability System for abilities and attributes.
  Player ASCs live on `PlayerState`; AI ASCs live on authoritative pawns.
  Combat is pure free aim and never accepts a client-selected target.
- **Rationale:** These responsibilities align with Unreal's multiplayer
  foundations and the confirmed player-facing combat identity.
- **Owner/evidence:** Issues #2 and #44; focused rules in
  [Combat and Networking Architecture](combat-and-networking-architecture.md).
- **Rejected alternatives:** A separate unmanaged transform authority,
  soft-lock or tab-target authority, pawn-lifetime player ability state, and
  animation-notify-owned hits.
- **Consequences:** Respawn/avatar reassignment, prediction, rollback, aim
  validation, and presentation correction require explicit tests.
- **Revisit trigger:** Measured engine behavior requires an adapter or extension;
  pure-free-aim and server-result constraints remain.

### TA-004 - Server-Owned Combat Timeline

- **Status:** Accepted
- **Scope:** Melee, projectiles, persistent areas, defense, and combat results
- **Decision:** The server owns activation time, windows, authored volumes,
  already-hit actors, ordering, and results. Animation and effects visualize
  the timeline.
- **Rationale:** Gameplay truth must survive missing presentation and resist
  client timing or contact claims.
- **Owner/evidence:** Issues #2 and #44.
- **Rejected alternatives:** Client animation notifies opening authoritative
  windows; client socket traces claiming contact.
- **Consequences:** Content versions and deterministic boundary tests are
  required.
- **Revisit trigger:** New action families require timeline semantics not
  represented by the current contract.

### TA-005 - Unreal Modules and Vendor Adapters

- **Status:** Accepted
- **Scope:** Source architecture
- **Decision:** Keep `GameCore`, `GameCombat`, `GameUI`, `GameNet`, and
  server-only `GameServer` with the dependency rules in
  [Technical Architecture](technical-architecture.md). Put selected vendor SDKs
  behind dedicated adapters/modules or plugins.
- **Rationale:** Gameplay ownership stays testable and vendor choices remain
  replaceable.
- **Owner/evidence:** Issues #13, #15, and #36.
- **Rejected alternatives:** Vendor SDK types in core gameplay data; client UI
  coupled to service or database access; server target hard-referencing
  client-only presentation.
- **Consequences:** Module dependency and cook validation become build gates.
- **Revisit trigger:** Measured compile/runtime constraints justify a documented
  module split or consolidation without crossing ownership boundaries.

### TA-006 - Staged Processes and Controlled Regional Travel

- **Status:** Accepted
- **Scope:** Runtime topology through 2.1
- **Decision:** Use one arena process for the prototype; hub, outdoor, and
  on-demand dungeon processes for 1.0; regional layers for 2.0; and isolated
  invasion coordination/subzones for 2.1. Regional handoff uses a short
  controlled travel state machine.
- **Rationale:** It makes authority and delivery scope explicit while allowing
  the project to prove one risk at a time.
- **Owner/evidence:** Issues #36, #44, #45, and #48.
- **Rejected alternatives:** One unbounded world process; seamless client-led
  cross-server position handoff; treating World Partition cells as servers.
- **Consequences:** Admission, checkpoint, lease, and transfer contracts precede
  regional travel.
- **Revisit trigger:** Measured topology evidence supports different process
  packing while preserving explicit region/instance authority.

### TA-007 - Fenced Transactional Persistence

- **Status:** Accepted
- **Scope:** Every durable character/economy mutation
- **Decision:** Use one logical ACID owner per mutation, a single active
  character lease with monotonically increasing fencing epoch, optimistic state
  versions, idempotency, immutable ledger/receipt records, and transactional
  outbox.
- **Rationale:** Crashes, retries, duplicate delivery, reconnect, and regional
  transfer must not duplicate or regress visible state.
- **Owner/evidence:** Issues #36, #40, and #44.
- **Rejected alternatives:** Direct client/database writes, cache as economy
  truth, analytics-driven grants, unfenced time-only leases, and unrelated
  multi-store writes presented as one transaction.
- **Consequences:** Failure injection, reconciliation, and migration evidence are
  release gates.
- **Revisit trigger:** A selected data architecture proves equivalent or
  stronger semantics and records the mapping in a reviewed decision.

### TA-008 - Sanctuary Precedence and Capital Isolation

- **Status:** Accepted
- **Scope:** Territory and hostile-action policy
- **Decision:** Mixed-region faction PvP is mandatory except in explicit
  protected/sanctuary subzones. The most-specific protection policy wins and is
  checked for source and target on activation and effect application. Capital
  military/invasion subzones cannot provide topology or authority access to
  beginner districts.
- **Rationale:** This implements the canonical world rules without an opt-in
  flag or boundary loopholes.
- **Owner/evidence:** Issues #40, #44, and #48.
- **Rejected alternatives:** Client PvP flags, effect-family exemptions,
  shared invasion/beginner topology, and guard AI as the sole protection.
- **Consequences:** Projectiles, areas, summons, periodic effects, forced
  movement, respawn, reconnect, and travel require boundary tests.
- **Revisit trigger:** Product design adds a new explicit policy type; protected
  starts and beginner isolation remain constraints.

### TA-009 - Separated Character Aggregates and Staged Faction State

- **Status:** Accepted
- **Scope:** Persistent character model
- **Decision:** Separate identity, appearance, permanent progression, Ember
  Rank, class/Skein, faction/Doctrine, inventory/equipment, cosmetics, and
  session state. Persist `Faction = Unassigned` before 2.0 and withhold Doctrine
  until the one-time faction choice.
- **Rationale:** Roadmap staging must not embed unavailable faction behavior or
  presentation choices in combat/progression data.
- **Owner/evidence:** Issues #36 and #48.
- **Rejected alternatives:** One undifferentiated character blob; implicit
  faction in class or location; race/sex affecting combat; pre-2.0 placeholder
  faction grants.
- **Consequences:** Character Level/Doctrine prerequisites remain an explicit
  open product decision.
- **Revisit trigger:** Faction delivery scope or selection policy changes
  through canonical product review.

### TA-010 - Prototype Quality Foundation

- **Status:** Accepted
- **Scope:** Delivery pipeline
- **Decision:** Establish foundational CI, automation, structured rejection
  telemetry, and performance capture in the prototype. Later releases expand
  rather than first introduce them.
- **Rationale:** Authority, latency, and performance cannot be proven
  retrospectively after system and content scale expand.
- **Owner/evidence:** Issues #16, #44, #45, and #48.
- **Rejected alternatives:** Deferring CI and instrumentation to 1.1; relying on
  editor-only manual tests.
- **Consequences:** The prototype gate includes packaged multi-process and
  measured evidence.
- **Revisit trigger:** Tooling may change after measured cost/reliability review;
  the gate remains.

### TA-011 - Repository-Scoped Engine Runner

- **Status:** Accepted
- **Scope:** Issue #16 engine-dependent GitHub Actions gates
- **Decision:** Use one repository-scoped GitHub Actions self-hosted runner on
  the current Windows development PC under the current owner account, labeled
  `[self-hosted, Windows, X64, aetheln-engine]`. Owner-authored, owner-triggered
  same-repository pull requests may run the supported-target compile gate,
  after the portable gates pass and only when the exact base/head change
  classification in TA-012 requires the engine. The packaged-smoke milestone
  runs at `02:00 UTC` from the protected default branch `main` as the four
  schedule-only phases decided in TA-012; the workflow declares no manual
  trigger.
- **Rationale:** The pinned Unreal source build, Visual Studio and Linux
  cross-toolchains, WSL topology, disk capacity, and local build paths are not
  available on ordinary GitHub-hosted runners. Repository scope and explicit
  trust predicates bound unreviewed code execution on the owner's machine.
- **Owner/evidence:** Issue #16 and the reviewed
  `.github/workflows/prototype-quality-gates.yml`,
  `scripts/ci/Invoke-EngineRunnerGate.ps1`, and focused fixture tests. A
  repository-scoped runner is registered, and GitHub Actions run `33161041115`
  provides candidate-specific live compile evidence for synthetic merge
  `d1edef0ceb0b83c610937713bd64b4425423fa74` (base
  `6f2e01204b6c76b9134d4a9fe0acc88320ecd680`, head
  `3f61f86feef3b8abe283845660eab92140588315`); the engine report SHA-256 is
  `BA69A43008B7E99CDEE257EC66B29CE600982AB46E71D7EE15FAD6D031E81253`.
  Scheduled phased packaged-smoke evidence remains outstanding.
- **Rejected alternatives:** Assuming `windows-latest` contains the pinned
  engine/toolchains; running engine jobs for fork or collaborator-authored
  pull requests; granting future collaborators runner access without a new
  review; storing local paths as repository secrets; uploading packaged builds,
  cook output, or full logs by default; treating `develop` as the schedule's
  activation branch.
- **Consequences:** The owner must provision and maintain the runner, pinned
  toolchains, WSL `Ubuntu` distribution and `aethelnqa` user. Non-secret
  `AETHELN_ENGINE_ROOT` and `AETHELN_LINUX_TOOLCHAIN_ROOT` paths are current-
  account user variables inherited by the runner process. Engine jobs serialize
  through one concurrency group, convert the packaged server path with WSL
  `wslpath`, publish only the redacted JSON report by default, and retain large
  archives/logs locally under per-run roots. The schedule becomes active only
  when the workflow reaches `main` through normal Git Flow; `develop` remains
  the integration branch. Artifact retention, local-output retention, scanner,
  SBOM, and signing decisions remain open.
- **Revisit trigger:** A collaborator needs runner access, the runner moves to a
  different host/account or trust domain, hosted/ephemeral infrastructure can
  reproduce the pinned toolchain, or measured cost, reliability, isolation, or
  capacity requires a different topology.

### TA-012 - Bounded Engine-Runner Scheduling with Phased Milestone and Durable Handoff

- **Status:** Accepted
- **Scope:** Issue #150 engine-runner scheduling for the prototype quality
  gates workflow
- **Decision:** `trusted-candidate-compile` outranks starting the next
  dependent scheduled milestone phase and never cancels in-progress work; it
  carries no absolute priority and never jumps ahead of an older queued
  pull-request job. The shared `aetheln-engine-runner` concurrency group
  uses `queue: max` with `cancel-in-progress: false` (FIFO by wait-start time,
  which GitHub documents without guaranteeing overall ordering). Expensive
  engine work starts only after the portable gates pass: milestone phase 1
  and `trusted-candidate-compile` both need `quality-gates` with the implicit
  success condition and no status-function bypass, so a portable failure,
  cancellation, or skip keeps every engine job off the runner. The workflow
  declares no manual trigger of any kind and the four phases are
  schedule-only: a manual trigger on this workflow identity would let an
  operator select an older branch that still carries the retired
  1,440-minute single-job gate, and no replacement manual workflow is
  provided. `trusted-candidate-compile` additionally needs the GitHub-hosted
  `change-impact` classifier (the reviewed full-SHA checkout action plus repository-owned
  PowerShell, no third-party action), which compares the exact pull-request
  base SHA and head SHA with a rename-free name-status diff and publishes
  `engine_required`. Compile is exempted only when every changed path is in
  the closed, case-sensitive portable-only set — `docs/**`, `visuals/**`,
  `output/pdf/**`, `tests/**` limited to `.ps1` and `.md` files, top-level
  `.md` files, and GitHub issue or pull-request template Markdown or YAML
  files, plus exactly `scripts/ci/Invoke-CiSuite.ps1`,
  `scripts/ci/Test-FormattingPolicy.ps1`,
  `scripts/ci/Test-MarkdownLinks.ps1`, and
  `.github/workflows/prototype-quality-gates.yml`. The lead's 2026-09-06
  applicability decision under the user's CI-improvement authorization adds
  only those four exact CI paths: Unreal compilation does not validate
  portable scheduling, policy checks, or workflow YAML logic. Required
  portable runner, formatting, Markdown, workflow, and scheduling-policy
  fixture suites plus independent review remain mandatory. Case variants,
  lookalikes, and extension substitutions are not exempt. The same date's
  independent applicability review adds exactly
  `scripts/build/Build-PackagedArtifacts.ps1`,
  `scripts/ci/Invoke-EngineRunnerGate.ps1`, and
  `scripts/ci/Initialize-CompileWorkspace.ps1`: their mandatory PR gates are
  the full portable suite and independent review. Compile never executes the
  packaging controller. Real Compile can validate wrapper and retention
  integration, so bounded live operational proof remains separately required;
  an exemption does not claim that proof passed. The same CI repair also adds
  exactly `scripts/build/Invoke-PackagedSmokeTest.ps1`: a compile does not execute
  its process supervision or JSONL evidence writer. Its mandatory portable smoke
  fixture suite and independent review cover those changes; real packaged-smoke
  evidence remains a separate required milestone. Revisit these exact exceptions
  if these scripts start generating engine inputs. Everything else,
  including `Source/**`, `Config/**`, `Content/**`, `Plugins/**`, other
  `scripts/**`, other `.github/workflows/**`, and `AethelnOnline.uproject`,
  requires compile; so does any mixed change containing an engine-required
  path. Every classifier uncertainty — invalid, missing, or identical SHAs,
  an unavailable commit, a Git error, an empty diff, or a quoted, rename, or
  copy entry — fails closed to `engine_required=true`; uncertainty can never
  become a successful exemption. A classifier infrastructure failure before
  the decision is published (a lost runner or a checkout error) is a red
  `change-impact` check that skips the compile rather than exempting it, and
  is not portable-exemption evidence. The owner, same-repository, and
  triggering-actor trust predicates stay enforced in addition to these
  prerequisites. The scheduled
  clean-package plus packaged-smoke milestone is split into four bounded
  phases whose job `timeout-minutes` are the total concurrency-holding bounds
  (client package 40 minutes, server package 40 minutes,
  registry/provenance validation 20 minutes, packaged smoke 20 minutes), each reacquiring the concurrency group, with a
  hard bound over the whole controlled gate-script interval: a supervising
  parent runs the complete phase body — setup, handoff validation, cleanup
  scanning, root accounting, manifest reads, payload hashing, smoke discovery,
  build/smoke work, and timeout finalization — in an owned kill-on-close child
  tree. Child mode requires a fresh 256-bit parent-issued nonce bound to the
  direct parent process ID and start time; inherited, partial, mismatched, or
  replayed credentials reject before phase work rather than bypassing the
  supervisor. The child keeps the cooperative absolute phase deadline (30/30/10/10
  minutes, every operation consuming remaining time from that one deadline);
  if any synchronous operation or the timeout finalization blocks across it,
  the parent stops and verifies the whole tree at the deadline plus a bounded
  finalization grace (`-PhaseFinalizeGraceSeconds`, default 120 s, capped at
  600), classifies `phase_timeout` or `phase_cleanup_failed`, and writes the
  bounded report itself. Upload is best effort within remaining job time, not
  guaranteed before platform cancellation; checkout/LFS and grace also consume
  that budget, and missing evidence never establishes success. Checkout/LFS
  and report upload sit only inside the job bound. The recorded
  40-minute value is the maximum trusted-compile queue delay attributable to one
  currently running scheduled phase, subject to platform assignment latency;
  total queue time can be longer when older jobs are already ahead.
  Phases exchange outputs only through a durable run-scoped handoff store
  under the non-secret `AETHELN_HANDOFF_ROOT` user variable (a local
  fixed-drive directory; UNC and network roots rejected), namespaced
  `<root>/<owner>/<repo>` with separate validated path components so distinct
  repositories cannot collide. The first phase atomically writes a closed
  run-context record binding repository, source SHA, run id/attempt, and
  runner name; later phases and cleanup validate it fail-closed. Atomic
  schema-v1 integrity manifests (same context plus expected consumers,
  normalized relative paths, sizes, lowercase SHA-256 digests) are validated
  as closed documents — exact property sets, duplicate-JSON-property and
  case-colliding-path rejection, exact manifest/actual path-set equality,
  overflow-safe totals — with reparse-point and containment revalidation of
  every path chain before use. Payload is capped at 64 GiB per run attempt,
  enforced cumulatively at publication (prior manifests are summed before a
  new one is accepted) and at consumption (the consumer's complete required
  manifest set is validated as one closed set and the run is rejected on an
  aggregate above the cap before any payload use), against a 256 GiB default
  total-root cap measured over the complete validated root. CI never deletes
  handoff content; it writes bounded cleanup-request records (48-hour
  abandonment threshold, eligibility only with a valid context and, for
  completion, a validated terminal marker) for external operational cleanup.
- **Context:** On 2026-09-01 a healthy scheduled packaged-smoke run held the
  sole engine runner for more than 13 hours while the required PR compile for
  PR #147 stayed queued, and GitHub's default single pending slot per
  concurrency group could silently cancel a pending trusted compile. GitHub
  Actions has no job priority; FIFO wait order under `queue: max` plus phase
  boundaries is the only cancellation-free bounding mechanism. `runner.temp`
  is emptied at the start and end of every job, so cross-phase state needs a
  durable documented medium.
- **Evidence:** Issue
  [#150](https://github.com/ShayShimoni/aetheln-online/issues/150) and its
  recorded lead decisions; current GitHub concurrency and variables
  documentation; focused fixture suites
  `tests/ci/Invoke-EngineRunnerGate.Tests.ps1`,
  `tests/build/Build-PackagedArtifacts.Tests.ps1`,
  `tests/ci/Test-RunnerSchedulingPolicy.Tests.ps1`, and
  `tests/ci/Test-PrototypeQualityWorkflow.Tests.ps1` (the classifier
  portable, engine-impact, fail-closed, and shallow fetch-then-classify
  matrix executed against fixture commits, including each exact portable CI
  path, case variants, lookalikes, other scripts and workflows, and mixed
  engine changes). Local fixtures are not proof of live workflow activation,
  engine execution, or scheduled milestone completion.
- **Alternatives:** `queue: max` alone (leaves the full 24-hour starvation);
  keeping an owner manual trigger on the same workflow identity (lets an
  older branch with the retired 1,440-minute job be selected); starting
  engine jobs in parallel with the portable gates (spends the sole runner on
  candidates that fail portable checks); a third-party path-filter action
  (unreviewed code deciding engine execution); a permissive or heuristic
  exemption list (an unclassified path must compile);
  shrinking the single job timeout (cancels healthy packaging); cooperative
  mid-run yielding via the GitHub API (credentials and checkpoint machinery on
  the runner); GitHub Actions artifacts as the handoff medium (multi-gigabyte
  packaged bytes are policy-bound to stay runner-local); relying on residual
  workspace state between jobs (dirty-workspace dependency).
- **Consequences:** The owner provisions `AETHELN_HANDOFF_ROOT` once and
  restarts the runner service; the first live scheduled run after merge is the
  independent operational proof, and the first live pull-request run of the
  merged workflow is the operational proof for the classifier path (a
  portable-only pull request must show `change-impact` green with
  `engine_required=false` and `trusted-candidate-compile` skipped). Trusted
  compile waits for the portable suite before it can
  queue for the runner. Phase evidence stays separate per job; a
  phase-deadline expiry — between controlled pre-work operations (the
  build/smoke grandchild is then never started), inside a single blocking
  synchronous operation or the timeout finalization (the supervisor hard bound
  interrupts it at deadline plus bounded grace), or during the build/smoke
  work — is an explicit `phase_timeout` failure with a retained bounded report
  and an owned, verified process-tree stop (kill-on-close Job Object first,
  bounded taskkill only as fallback, `phase_cleanup_failed` when the tree
  cannot be proven ended), and the next scheduled attempt restarts the
  milestone from clean inputs. Handoff cleanup is an external operational action driven by
  cleanup-request records.
- **Revisit trigger:** Retained phase evidence shows a bound is materially
  wrong, a second matching runner is registered, GitHub ships native job
  priority or changes concurrency queue semantics, or the milestone moves off
  the single-runner topology.

### TA-015 - Bounded Routine Compilation with Isolated Output Retention

- **Status:** Accepted
- **Scope:** Issue #150 routine CI execution and workspace isolation.
- **Decision:** Under the owner's explicit 2026-09-06 CI-redesign direction,
  cap portable CI at 30 minutes, trusted compile at 40 minutes with a shared
  30-minute controlled-work watchdog, client/server packaging at 40 minutes
  each with 30-minute watchdogs, and provenance/smoke at 20 minutes each with
  10-minute watchdogs. These are operational ceilings, not measured budgets.
  Supersede the former multi-hour TA-012 phase ceilings. Timeouts fail with
  retained evidence and owned-tree cleanup; no silent retry or longer fallback.
  Under the approved Issue #167 recovery, use a fresh exact-revision control
  checkout and an explicitly registered retained compile workspace, disjoint
  from `milestone/`. Never direct `actions/checkout` at a prepared linked
  worktree. Retained synchronization and input validation run under the shared
  host lease and compile supervisor; release requires verified child cleanup.
  Preserve compile outputs without an implicit cold fallback or arbitrary
  artifact transplant; milestone checkout and packaging keep clean semantics.
  Use a fresh run/attempt/job report outside the retained Compile checkout.
- **Rationale:** Routine cleanup repeatedly destroys useful C++ outputs, while
  DDC does not cache those object files. A bounded, isolated incremental lane
  can reuse trusted local outputs without mistaking a warm compile for a clean
  release milestone or allowing a stale report to satisfy a new run.
- **Owner/evidence:** Issue #150; workflow, scheduling-policy, retention-helper
  and engine-gate fixtures. Actual warm-engine runtime and default-branch
  activation remain separate evidence, not established by this decision.
- **Alternatives:** Blanket `clean: false` on a shared checkout (unbounded
  stale inputs and nightly cache destruction); unanchored Git clean exclusions
  (retain unrelated nested trees); reducing timeouts alone (does not improve
  build reuse); silently waiving compilation or relabeling partial packages.
- **Consequences:** A cold or significantly invalidated build can exceed the
  deadline and must be repaired/provisioned explicitly. No unattended cold
  bootstrap or arbitrary copied binaries are accepted as successful evidence.
  Local output identity and engine/toolchain reprovisioning remain the runner
  operator's responsibility. No new provider or hardware is selected.
- **Revisit trigger:** Measured warm runtime fails the cap, pinned inputs change,
  or the runner trust domain changes. Investigate first; never raise ceilings
  automatically.

### TA-013 - Measured Clean-Package Time with Identity-Bound Persistent DDC

- **Status:** Accepted
- **Scope:** The clean packaging milestone: `Build-PackagedArtifacts.ps1`,
  the engine-runner gate packaging modes, and runner cache configuration.
- **Decision:** Make clean-package cost measurable per run through a bounded
  machine-readable substep timing and cache-state record
  (`<LogRoot>/build-timing.json`), and allow an opt-in persistent local
  Derived Data Cache whose reuse is gated by an explicit identity record
  bound to the pinned engine build, Linux toolchain, and project. Any
  mismatched, corrupt, unverifiable, or unavailable cache state fails closed
  by default or takes the documented clean-isolated fallback (a fresh
  run-scoped cache with full re-derivation). Clean semantics are unchanged:
  `-clean` stays on every packaging command line, every target and phase
  still runs, and reused derived data is never relabeled as clean build
  evidence.
- **Context:** Issue #81 must reduce elapsed machine time of the periodic
  clean Windows-client and Linux-server packaging milestone. Attributing the
  duration (C++ compilation vs. cooking/DDC vs. staging/archiving vs.
  validation vs. smoke) requires per-substep evidence, and reusing derived
  data across runs requires an explicit, verifiable cache identity so a
  foreign or stale cache can never be adopted silently.
- **Evidence:** Portable fixture suites
  `tests/build/Build-PackagedArtifacts.Tests.ps1` (timing record shape, UAT
  step attribution, identity initialization/reuse, mismatch fail-closed,
  corrupt/unverifiable/unavailable states, clean-isolated fallback) and
  `tests/ci/Invoke-EngineRunnerGate.Tests.ps1` (DDC configuration validation
  and pass-through). Before/after clean-milestone timing at one source
  revision requires the lead-authorized engine runs and is recorded on
  Issue #81.
- **Alternatives:** Engine-default implicit DDC only (persists, but with no
  explicit identity, capacity, or fallback contract); binding the project
  source revision into the cache identity (defeats cross-commit reuse that
  Unreal's content-addressed keys already make safe); a Zen/shared DDC
  service, an Unreal-supported precompiled engine-binary boundary, or build
  acceleration/hardware (each requires measured evidence and an owner
  decision; see the evaluation ladder in
  [Developer Environment and DDC](developer-environment-and-ddc.md)).
- **Consequences:** Runner operators own cache provisioning, capacity, and
  deletion; CI never deletes or repairs a cache. A fail-closed default means
  a misconfigured cache stops the milestone visibly instead of running
  slower or dirtier. The timing record adds one small local JSON per run.
- **Owner:** Issue #81.
- **Revisit trigger:** Measured before/after evidence shows cooking is not
  the dominant cost (escalate to the engine-binary boundary or hardware
  rungs), or the milestone moves to a multi-runner or shared-cache topology.

### TA-014 - Attested Fail-Closed Prebuilt Host-Tools Boundary for Clean Packaging

- **Status:** Accepted
- **Scope:** The clean packaging milestone: `Build-PackagedArtifacts.ps1`
  (`-HostToolsBoundary`, `-EngineRevision`, `-HostToolsAttestationPath`,
  `-Stage AttestHostTools`), the engine-runner gate packaging modes
  (`AETHELN_HOST_TOOLS`, `AETHELN_ENGINE_REVISION`,
  `AETHELN_HOST_TOOLS_ATTESTATION`), and runner configuration.
- **Decision:** Allow the clean packaging milestone to skip rebuilding the
  host editor/engine tools by passing `-nocompileeditor` (which the pinned
  UE 5.8.1 source maps to `SkipBuildEditor`, omitting the editor targets
  from `BuildProjectCommand`) — but only behind an explicit, fail-closed,
  attested boundary. Host-tool provenance is proven by an external local
  attestation record produced solely by the explicit operator attestation
  step after an authorized provisioning build: it binds the repository's
  canonical pinned engine revision and the SHA-256 plus size of a closed
  required host-tool set, and every file must re-verify against the binaries
  on disk before the skip is applied; `Build.version` fields alone never
  prove provenance. There is no default host-tools behavior anywhere: a
  building invocation without an explicit selection fails closed
  (`host_tools_configuration_required`), the scheduled path requires the
  verified prebuilt attestation, and a full rebuild exists only as the
  separately named, operator-authorized `rebuild-authorized` /
  `-HostToolsBoundary Rebuild` selection — never as a fallback. A
  noncanonical `-EngineRevision` fails closed even when the checkout matches
  it. The client and server project targets keep `-clean`, and every cook,
  stage, package, archive, registry-validation, provenance, and smoke phase
  still runs.
- **Context:** Retained live evidence from the legacy scheduled run showed
  the UBT action graph dominated by the host editor/engine tool build, which
  DDC reuse (TA-013) cannot touch. Version-record field comparison cannot
  prove which commit produced the binaries (the source build carries
  `Changelist: 0` shared across commits), and an implicit rebuild default
  recreates the multi-hour failure mode the owner rejected.
- **Evidence:** Portable fixture suites
  `tests/build/Build-PackagedArtifacts.Tests.ps1` (skip only under a
  verified attestation; arbitrary binaries with matching version JSON,
  tampered tools, noncanonical or wrong-checkout revisions, dirty engines,
  manipulated/oversized/escaping/case-colliding attestation records, and
  missing selections all fail closed before UAT with bounded timing
  evidence) and `tests/ci/Invoke-EngineRunnerGate.Tests.ps1` (required
  configuration, attestation validation, runner-name forwarding, and
  pass-through). Before/after clean-milestone timing at one source revision
  requires the lead-authorized engine runs and is recorded on Issue #81.
- **Alternatives:** Version-record comparison (rejected: does not prove the
  producing commit); an implicit rebuild default (rejected: silent multi-hour
  rebuild on one missing variable); an installed/precompiled engine build
  distribution (changes the pinned engine artifact the runner consumes — a
  separate owner decision).
- **Consequences:** The runner operator provisions the host tools once per
  engine pin (the retained authorized legacy build is the one-time source)
  and runs the explicit attestation step tied to its retained evidence. A
  misconfigured, stale, or tampered state stops the milestone visibly. The
  timing record gains `hostTools` and bounded `identity` evidence
  (canonical engine SHA, `Build.version` hash, Linux compiler SHA-256,
  targets, validated runner name), and the runner report gains `runnerName`.
- **Owner:** Issue #81.
- **Revisit trigger:** The engine pin changes (re-provision and re-attest,
  update the controller's canonical pin and `AETHELN_ENGINE_REVISION`),
  measured evidence shows the boundary does not reduce the dominant cost, or
  the milestone moves to an installed engine build distribution.

### TA-016 - Revision-Bound Compile Applicability for Issue #151

- **Status:** Accepted upon independent review and merge of this decision;
  proposed until then.
- **Scope:** Only [Issue #151](https://github.com/ShayShimoni/aetheln-online/issues/151)
  as delivered by [PR #152](https://github.com/ShayShimoni/aetheln-online/pull/152),
  base `085932aa31856041a9c5544ba4f838a2f5e66e24`,
  head `278e334fda22a74f3aed9bff7128d358c7f315e1`, and
  merge `2919ceaaf30d89bd374c4124b7e1fe76e0c778cf`.
  The exact ten changed paths are below; every path is relative to
  `.agents/skills/orchestrate-delivery/`:

  - `SKILL.md`
  - `references/handoff-schemas.json`
  - `references/operating-contract.md`
  - `scripts/Get-DeliveryEventTelemetry.ps1`
  - `scripts/Invoke-DeliverySourceInspectionServer.ps1`
  - `scripts/Invoke-DeliveryStage.ps1`
  - `scripts/Validate-DeliveryHandoff.ps1`
  - `scripts/tests/Test-DeliveryHandoffValidation.ps1`
  - `scripts/tests/Test-DeliverySourceInspection.ps1`
  - `scripts/tests/Test-DeliveryStageLauncher.ps1`

- **Decision:** Under the owner's 2026-09-06 authorization to remove
  unnecessary CI work, successful Unreal target compilation is not an
  acceptance requirement for this exact historical change. Applicable proof
  comprises focused source-inspection, handoff-validation, and stage-launcher
  regressions; reproduction from retained initial/replacement events; and
  independent post-merge QA of the installed-Codex replacement path.
- **Rationale:** These protocol, PowerShell, documentation, and test changes
  neither supply nor generate Unreal compilation inputs. Compiling client and
  server targets does not exercise the closed source-reader schema,
  retry-neutral preflight rejection, pagination telemetry, or restricted
  replacement launch. The normal portable CI suite excludes this `.agents/`
  test harness, so a green portable report alone is also insufficient.
- **Owner/evidence:** Issue #151 and PR #152 bind the historical change and
  pre-publication focused regression/replay reports. Retained post-merge QA
  for the merge above records 33 source-inspection, 231 handoff-validation,
  and 275 stage-launcher passing rows, each with exit code zero. The retained
  supported-replacement evidence manifest has SHA-256
  `de3ca2563a68472fd02b5546714f0bd563967ebbf00a7753b14126f0c0fd0e6a`.
  These suite results and manifest do not by themselves establish
  installed-Codex acceptance. Final independent acceptance must reconcile the
  retained replacement-path events,
  audit evidence, and source identity; publication must also reconcile the
  current issue/PR event history. This decision does not declare Issue #151
  Done or unblock #139.
- **Alternatives:** Requiring an unrelated Unreal compile for these exact
  protocol changes; accepting ordinary portable CI without the delivery
  harness; exempting the entire `.agents/` directory or future changes to
  these paths. The latter two leave the relevant behavior unproven.
- **Consequences:** Earlier failed compilation remains failed operational
  evidence, and absent compilation evidence remains missing; neither becomes
  a pass. This decision changes no workflow, TA-012 closed classifier, future
  gate, trust predicate, retry budget, isolation rule, or packaged milestone.
  It creates no directory exemption or automatic waiver for a later revision,
  even at the same paths. Unreal/build infrastructure operational failures
  remain separately actionable, and this decision claims no measured speedup.
- **Revisit trigger:** Any different base/head/merge, path set, behavior that
  supplies engine inputs, or contradictory retained evidence requires a new
  applicability review. Future changes continue through the existing gates.

### TA-017 - Shadow-First CI Selection with Accepted-Base Control

- **Status:** Accepted
- **Scope:** Issue #167 CI selection, receipts, and later authority activation.
- **Decision:** Introduce selection shadow-first. Package 2 adds one independent
  pull-request-only hosted job and the reusable selector while preserving the
  existing `change-impact` authority exactly. The shadow has no dependency,
  outputs, consumer, self-hosted label, engine concurrency, or conclusion
  effect. Fetch exact base, head, and synthetic merge objects into a
  bare/no-checkout repository before the only sparse checkout, then execute
  only accepted-base controller bytes after verifying their Git blob OID and
  SHA-256. Never execute a candidate selector. Package 2 accepted policy
  `shadow-v1` had canonical digest
  `07bb90760bf493e25e40ac781143d07e701a113db3ede8bc7380490f6b85e9b6`.
  Package 3A corrects the overbroad clean-milestone mapping while remaining
  shadow-only; its candidate policy digest is
  `52f43ef45d9515bae76315026674ac0e052823b6dc63ec9ed008d093774c90a4`;
  every live report also binds the exact accepted controller revision, blob
  OID, and blob-byte SHA-256. The bootstrap
  `accepted_controller_unavailable` record selects all checks and is not
  equivalence evidence. The first meaningful later live comparison must use
  Package 2 as its accepted base. Receipt/aggregate work is additive and
  nonblocking first. Authority may move only in a subsequent wiring-only change
  that pins the exact observed accepted digests, changes no policy/controller
  bytes simultaneously, and passes an external checker not supplied by the
  candidate. Hosted uncertainty, unsupported obligations, or checkout-safety
  rejection must stop before any self-hosted runner queues. Private-repository
  object fetches use the ephemeral `github.token` only through a masked
  per-command header and never persist it. Unrecognized paths fail closed to
  every obligation. Reusable invocations preserve caller kind and workflow
  revision and apply the same ordered merge-parent validation as direct pull
  requests.
- **Stale event-base amendment:** GitHub may keep a pull request event's base
  SHA when the target branch advances before the tested synthetic merge is
  created. The shadow job fetches complete ancestry and derives the accepted
  controller and comparison revision from that immutable merge's first parent.
  Its second parent must equal the exact event head, and the event base must be
  an ancestor of the first parent. The sparse checkout, controller blob lookup,
  context controller revision, and report comparison base all use that verified
  first parent. A foreign or divergent first parent, wrong head parent, shallow
  graph, missing accepted controller, or inconsistent identity fails closed.
  During the staged rollout, the live closed selector context sets both
  `baseRevision` and `controllerRevision` to that first parent. This preserves
  compatibility with the previously accepted controller, which requires their
  equality and exact ordered merge parents. The event base remains an independent
  pre-checkout workflow ancestry witness; the candidate selector does not need
  that separate witness in its live context.
  The selector remains non-authoritative and does not alter legacy CI gates.
- **Historical Package 3A amendment:** Pin every approved remote action to its reviewed
  full commit SHA, implement and fixture-test exact per-job shadow receipt and
  bounded same-attempt aggregate contracts, and add a hosted direct-needs gap
  diagnostic as the sole job allowed a job-level `always()`. Package 3A does
  not emit receipts or execute the aggregate while truthful producers are
  missing; it publishes an explicit incomplete, non-authoritative,
  no-acceptance inventory instead. The known gap completes as a green
  diagnostic so healthy PRs are not permanently red, while unexpected
  reconciliation or publication errors still fail the job.
  The only Package 3A obligation with a supported semantic receipt is
  `visual-package`; producer and aggregate both validate its exact bounded raw
  report. Every other obligation rejects as unsupported until its own raw
  schema validator exists, so claimed exits plus opaque hashes cannot establish
  success. The aggregate does not accept caller-declared selection booleans: it
  obtains the exact same-attempt selector job/artifact through GitHub, validates
  the single accepted-selector report against controller, policy, source and
  workflow identities, and derives each producer's selected receipt subset.
  Run actors and downloaded artifact lengths are independently reconciled.
  Absolute archive, entry and expanded-byte ceilings remain authoritative;
  bounded valid evidence is not rejected solely for a high compression ratio.
  A monotonic aggregate deadline is enforced during streaming/decompression
  and after every request or bounded parse; progress cannot reset it.
  The planned receipt archives bound only their named raw evidence and stayed
  `shadow=true`, `authoritative=false`, and `grantsAcceptance=false`. Missing
  producers were not mapped to unrelated portable fixtures. At that stage the
  accepted-base selector exposed only the visual obligation to an additive
  reusable visual proof. Existing legacy selection and required gates remained
  authoritative. Because Package 3A changed selector bytes, it required a
  later no-controller-change observation before producer wiring or activation;
  Package 3A's fixture proof granted no authority. Package 3C below records the
  current receipt and aggregate wiring.
- **Package 3B pre-activation amendment:** A run/attempt suffix is routing
  metadata, not current-job provenance. GitHub's artifact record identifies the
  workflow run and head revision but does not identify the producing job or run
  attempt. The accepted-base selector must therefore generate a fresh 256-bit
  CSPRNG correlation nonce bound to the canonical run ID and attempt. Selector
  and receipt artifact names, reports, contexts, and aggregate output bind that
  same closed current-attempt anchor. The aggregate also requires each
  artifact's `created_at` to fall inside the exact successful current-attempt
  job interval, reconciles the job's run/head/attempt and native runner
  identity, and compares the API `sha256:` digest with the downloaded archive
  bytes. Missing, malformed, all-zero, replayed, duplicated, pre-job,
  post-job, or digest-mismatched evidence fails closed. Producer receipts and
  the aggregate remain shadow-only in this package. The normalized selector
  candidate for this amendment has SHA-256
  `605a3fc7a16e2664492a51bc44a3d267ee6e9955043811c1be4ce4c988f2fe4b`;
  it is not an accepted activation pin until this foundation is merged and a
  fresh accepted-base live shadow observation binds it.
- **Historical Package 3B shadow-wiring amendment:** The pull-request workflow
  supplied canonical run and attempt fields to the accepted-base selector,
  validated the returned closed anchor, exposed only its nonce as
  non-authoritative routing metadata, and uploaded the exact selector report
  under the nonce-suffixed artifact identity. The unavailable-controller
  fallback also used a fresh 32-byte CSPRNG nonce and had no deterministic
  fallback. That package deliberately did not emit receipts, execute the
  aggregate, add `actions: read`, or grant acceptance. Package 3C supersedes
  those wiring limitations and strengthens the run-identity anchor regexes to
  whole-input `\A...\z` matches. The earlier eight-obligation selector
  candidate was 39,772 LF-normalized bytes with digest
  `913411858dae63ff48de296ef59d4f5d84aeb43dc55759874f6cb4d03bb0a55d`.
  Reconciliation with the current accepted base additionally classifies the
  exact #181 content-validation launcher and two contract tests while keeping
  unwired lookalikes unclassified. This candidate is 40,236 LF-normalized
  bytes with digest
  `4e21f35a4791332176edd1f51c4ccf69115fb34bc2defda5b8e6716206aa2b46`.
  It changes the policy identity and requires new accepted-base observations
  after merge; neither digest grants activation authority.
- **Direct-delivery retirement amendment:** The earlier delivery harness was
  diagnostic only: it executed writable worktree files without complete
  source-byte or mid-run mutation protection. The harness and its unsupported
  `delivery-harness` obligation were retired on develop; the other CI
  obligations and evidence gates remain intact. The retirement selector's
  normalized digest is
  `a1be534a661508fdccae17ea7623b2c3f215119a07cdc66ef7ab8653a9925536`.
  It is historical identity, not a Package 3C activation pin.
- **Package 3C receipt and aggregate wiring amendment:**
  `ci-selection-shadow` now exposes the validated nonce, aggregate readiness,
  all eight exact obligation decisions, and its artifact ID/name/API digest as
  direct `needs` outputs. The portable, trusted native client/server compile,
  and reusable visual jobs expose their truthful raw artifact ID/name/digest
  plus inner report SHA-256/length. Three hosted receipt-publisher jobs download
  those exact artifacts by ID, validate the raw typed reports, and publish
  nonce-bound shadow receipts for `portable`, `controller-contract`,
  `controller-operational-proof`, `native-client-server-compile`, and
  `visual-package` only. The portable
  publisher proves `controller-contract` and `portable` from the same exact
  `ci-report.json`, limited to the selector-derived subset carried in its
  identity context; `controller-contract` additionally requires every required
  `tests/ci` suite to pass. The native publisher proves
  `controller-operational-proof` and `native-client-server-compile` from the
  same exact `engine-runner-report.json` under the same selector-derived
  subset rule; both results bind zero native exit, verified cleanup, and the
  `trusted-candidate-compile` runner identity, and the report is revalidated
  under each check id with its own reason suffix.
  `New-CiAcceptanceAggregateContext.ps1` builds closed identity contexts and,
  when the selector's chosen checks are a subset of those five live
  obligations, nonce-specific requirements with an exact selector binding and
  sorted producer bindings. Each binding carries the job name and exact
  artifact ID/name/digest from the named direct dependency. The aggregate
  independently reconciles those bindings with the current attempt's GitHub
  job/artifact API and downloaded bytes. Missing, duplicate, extra, unselected,
  swapped, replayed, malformed, unsorted, or digest-mismatched bindings fail
  closed. This direct producer binding resolves the earlier shared-nonce
  uploader ambiguity; interval checks remain additional temporal evidence.
- **Known producer-gap behavior:** When any selected obligation is outside the
  live portable/controller-contract/controller-operational-proof/native/visual subset, the aggregate is not called. The workflow
  still validates the selector identity and emits the exact selected
  unsupported set as a green `producer_contract_incomplete` record with
  `complete=false`, `shadow=true`, `authoritative=false`, and
  `grantsAcceptance=false`. The green result prevents a known incomplete shadow
  migration from making healthy pull requests permanently red; it is never an
  acceptance result. Any unexpected identity, semantic, reconciliation, or
  publication error remains red. `unreal-editor-automation`,
  `clean-package-provenance-smoke`, and `content-reference-validation` remain
  unsupported live obligations.
- Authority activation remains a later change. Package 3C includes a dormant
  `ci-acceptance-authority` job whose pull-request condition is hard-skipped by
  the exact predicate
  `always() && github.event_name == 'pull_request' && false`. When later
  activated, `always()` ensures a failed or cancelled aggregate executes this
  boundary rather than producing a skipped required check; the first guard and
  the authority validator both require the direct aggregate result to equal
  `success`. Its body accepts only a complete, nonce-bound, non-authoritative
  shadow aggregate and would emit a separate authority receipt, but it cannot run or grant
  acceptance in the Package 3C workflow. A workflow-only change selects
  `controller-contract` and `controller-operational-proof`, which now have
  truthful portable and native receipts, so an owner candidate can reach a
  complete shadow aggregate; the dormant predicate still makes the authority
  job unreachable and nothing grants acceptance. Package 3C
  deliberately publishes no activation policy or pre-reviewed activation
  template. The native producer wiring (which changed the requirements-template
  bytes) must first be shadow-observed on a fresh accepted base, or the
  selection boundary independently replaced
  with an equally fail-closed contract. Only a later accepted base may pin the
  exact one-workflow-file template and immutable controller, publisher,
  aggregate, requirements, checker, policy, and action identities.
- The activation checker executes from accepted-base bytes outside the
  candidate checkout and requires the trusted caller to provide the
  independently accepted base revision and policy SHA-256. It compares both
  pins before parsing the closed policy from the accepted Git object database,
  uses fixed absolute identities for Git and process-tree cleanup rather than
  candidate-influenced `PATH`, disables replacement-object and Git
  configuration redirection, validates the exact base/head/tested-merge tree
  relation, and accepts only the one live-workflow file whose bytes equal that
  pinned template. It emits bounded JSON only; it does not read a candidate
  policy or write through candidate-controlled filesystem paths. A fresh
  accepted-base observation after Package 3C merges must use two distinct pull
  requests. A supported-only change must exercise the exact selector, every
  selected raw producer and receipt publisher, the direct bindings, and a real
  complete shadow aggregate. A separate unsupported-selection change must
  exercise the exact green `producer_contract_incomplete` branch. Each record
  must bind the run/attempt, accepted base, head/tested-merge revisions,
  selector, raw, and receipt artifact IDs/names/API digests, aggregate or gap
  report SHA-256, attempt nonce, and final non-authority flags. Both are
  prerequisites for the next producer package, not proof that the current
  one-line activation is executable.
  Push and schedule emit `event_not_applicable` because they have no accepted
  event-specific selector producer and remain non-authoritative.
- Package 3C pins the workflow identity as `326989724` and the complete action
  manifest as
  `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1`,
  `actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093`,
  and
  `actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a`.
  Workflow-wide permission remains `contents: read`; only the live aggregate
  and dormant authority jobs receive job-scoped `actions: read` plus
  `contents: read`.
- **Policy identity:** The policy digest is SHA-256 over the accepted selector
  source after deterministic LF normalization, covering mappings, contexts,
  limits, uncertainty behavior, and attribute rules. The controller digest
  separately binds exact raw blob bytes.
- **Context:** Candidate-controlled path filters can suppress their own checks;
  combining selector edits with activation prevents comparison against accepted
  behavior. Paths also require raw rename/copy, revision attributes, LFS,
  case/Unicode collision, and Windows checkout analysis before expensive work
  is admitted. Current runs exposed an action-runtime Node 20 deprecation
  warning. That observation is an input for Package 3A's separately reviewed
  full-action-SHA pinning; Package 2 does not invent a replacement version.
- **Evidence:** `tests/ci/Get-CiSelection.Tests.ps1` covers closed schemas,
  raw NUL diff records, rename/copy sides, attributes, LFS routing, unsafe
  modes/paths, case/NFC collisions, bounds, accepted controller identity, and
  conservative output. Package 2 workflow fixtures proved the legacy normalized
  5,595-byte block at SHA-256
  `b69855c18bf8a8dd0a7e686b80d97d338c558b0868c27a05bf7cbdf9b3c04b6c`.
  Historically, Package 3A changed only the reviewed checkout action identity
  in that block;
  its current normalized identity is 5,633 bytes at SHA-256
  `f1ae549ac2b628df3a09b4d29d6b9f20e237e0c31cc3060ae44bf44923c3a9df`,
  and the shadow is independent with one attempt-bound artifact. Fixtures do
  not replace the first later live accepted-base comparison. Package 3A adds
  `New-CiAcceptanceReceipt.Tests.ps1` and
  `Invoke-CiAcceptanceAggregate.Tests.ps1` for identity, outcome, rerun,
  pagination, bounded JSON/archive, action-manifest, cleanup, and raw-evidence
  negative cases. Package 3C adds
  `Publish-CiAcceptanceReceipt.Tests.ps1` and
  `New-CiAcceptanceAggregateContext.Tests.ps1` for truthful publisher input,
  create-only output, selector/context identity, runtime requirements, and
  direct-binding adversarial coverage. Its reviewed action manifest contains
  full-SHA pins for `actions/checkout`, `actions/download-artifact`, and
  `actions/upload-artifact`.
- **Alternatives:** Candidate-tree selector execution; third-party path-filter
  authority; direct Package 2 replacement; simultaneous policy and activation
  edits; treating bootstrap/missing evidence as equivalence; letting unsafe or
  unsupported hosted classification fail only after engine admission.
- **Consequences:** Package 2 added diagnostic pull-request work without
  suppressing established checks. Package 3C adds hosted receipt publication
  and shadow aggregation for the supported subset; it does not replace legacy
  selection or required gates. Unsupported selections produce an explicit
  no-acceptance gap instead of a false aggregate. Visual validation retains its
  existing triggers and validators while exposing additive raw-evidence
  outputs through `workflow_call`. Activation remains a separate exact
  one-workflow-file reviewed package after fresh live observation. Artifact
  retention remains undecided and omitted.
- **Owner:** Issue #167.
- **Revisit trigger:** Pull-request merge identity or checkout semantics change,
  the accepted policy/check set changes, a required obligation gains a real
  producer, or live comparison contradicts this contract.

## Candidate Decisions

| ID | Candidate | Evidence required | Owner | Rejected until evidence | Revisit/decision trigger |
| --- | --- | --- | --- | --- | --- |
| TC-001 | Generic push-model replication, Replication Graph, or Iris | Equivalent packaged actor mix and scenarios; CPU, memory, bandwidth, correction, complexity, and failure behavior. The two-client prototype proves correctness only, not density or selection. | #2, #45 | Selecting a technology without the owning evidence, including Iris or Replication Graph from historical advice | Completed benchmark and reviewed record |
| TC-002 | Present-time validation or bounded rewind by action family | Melee, projectile, block/dodge ordering, clamping, abuse, CPU/memory, correction evidence | #2 | Unbounded rewind or client-claimed targets/hits | Pre-mandatory-PvP spike |
| TC-003 | Identity, backend framework, database, cache/message, hosting, orchestration | Thin working path; cost, complexity, Unreal integration, security, local flow, exit strategy | #36 | Treating Nakama, PostgreSQL, Redis, GameLift, EOS, or another vendor as selected | Issue #36 ADR |
| TC-004 | World Partition adoption per outdoor map | Editor/runtime memory, streaming, nav, cook, source-control, server reference evidence | #45 and map delivery issue | Global mandate; server-distribution interpretation | Representative outdoor-map measurement |
| TC-005 | Server tick, capacity, layers, and bandwidth | Representative combat and stress captures with explicit failure shape | #45 | Canonizing 32/64 players, a tick value, or bandwidth estimate | Approved performance baseline |
| TC-006 | Production backup, retention, RPO, and RTO | Data criticality, provider capability, restore drills, operating cost | #36, #40, #48 | Vendor-default recovery promises | Before public production |
| TC-007 | Anti-cheat and platform services | Threat coverage, platform support, privacy, cost, operations, false-positive handling, exit strategy | #40 | Treating client integrity as gameplay authority | Before external risk justifies integration |

## Rejected Architecture Alternatives

| Alternative | Reason |
| --- | --- |
| Soft-lock or client-selected authoritative targeting | Conflicts with pure free aim and server-resolved authored volumes |
| Optional mixed-territory PvP | Conflicts with canonical mandatory faction PvP; sanctuary is world policy, not player choice |
| Gear-equalized world combat as an assumed baseline | Conflicts with meaningful bounded equipment power |
| Conventional point-and-row talent tree | Conflicts with Forms, Threads, Keystone, and Doctrine |
| World Partition as server distribution | It is per-map content streaming and does not provide region authority or handoff |
| Client, analytics, cache, or message consumer as reward owner | Cannot provide the required authoritative ACID mutation |
| Shared privileged game-server key | Prevents least privilege, containment, and reliable attribution |
| Time-only character lease without fencing | A stale server can remain able to submit writes |
| Generated item inventory in 1.0 | The 1.0 slice proves permanent progress and bounded integer currency; inventory/equipment begins in 1.1 |
| CI, rejection telemetry, or performance instrumentation first added in 1.1 | Prototype evidence depends on them |
| Vendor selection from historical research | Issue #36 must produce current measured evidence and an ADR |
| Canonical capacity from planning estimates | Issue #45 must measure the representative scenario |

## Decision Evidence Template

```markdown
### <ID> - <Decision title>

- **Status:** Candidate | Accepted | Rejected | Superseded
- **Scope:** <affected stages and systems>
- **Decision:** <one clear statement>
- **Context:** <constraint and problem>
- **Evidence:** <links to reproducible measurements/prototypes>
- **Alternatives:** <options compared>
- **Consequences:** <costs, risks, and implementation obligations>
- **Owner:** <issue and accountable owner>
- **Revisit trigger:** <measurable condition>
```

Do not copy candidate product names into implementation guidance as though the
decision were accepted. When a candidate is selected, update the relevant
focused specification and this registry in the same reviewed change.

## Product Decisions Still Open

The architecture must not decide:

- Final faction names.
- Character Level and Doctrine prerequisite relationship.
- Glasswake Reach ownership.
- Level cap, curves, item tuning, PvP disparity, or reward values.
- Cross-faction grouping.
- Capital-invasion scheduling, capacity, victory, or recovery duration.
- Final regional population limits.

These remain in the canonical product documents until their owning design work
resolves them.
