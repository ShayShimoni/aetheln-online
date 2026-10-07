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
- **Decision:** Keep `GameCore`, `GameCombat`, `GameUI`, `GameNet`,
  server-only `GameServer`, and editor-only `GameTests` with the dependency
  rules in [Technical Architecture](technical-architecture.md). Put selected
  vendor SDKs behind dedicated adapters/modules or plugins.
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
  runs on Saturday at `02:00 UTC` (weekly since the 2026-10-06 amendment
  below) from the protected default branch as the four schedule-only phases
  decided in TA-012; the workflow declares no manual trigger. The default
  branch was `main` when this was accepted and has been `develop` since
  2026-10-03 (see the amendment below).
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
  activation branch (rejected while `main` was the default branch; superseded
  by the amendment below).
- **Consequences:** The owner must provision and maintain the runner, pinned
  toolchains, WSL `Ubuntu` distribution and `aethelnqa` user. Non-secret
  `AETHELN_ENGINE_ROOT` and `AETHELN_LINUX_TOOLCHAIN_ROOT` paths are current-
  account user variables inherited by the runner process. Engine jobs serialize
  through one concurrency group, convert the packaged server path with WSL
  `wslpath`, publish only the redacted JSON report by default, and retain large
  archives/logs locally under per-run roots. The schedule runs from the default
  branch, now `develop` (see the amendment below), which is also the
  integration branch. Artifact retention, local-output retention, scanner,
  SBOM, and signing decisions remain open.
- **Amendment (2026-10-05, scheduled runs follow the default branch, issue
  #228):** GitHub runs scheduled workflows only from the default branch, and
  the owner made `develop` the default branch on 2026-10-03 (recorded on
  [Issue #16](https://github.com/ShayShimoni/aetheln-online/issues/16)).
  Scheduled runs 37106216412 (2026-10-03), 37186384030 (2026-10-04), and
  37281226888 (2026-10-05) ran on `develop`; the earlier runs, through
  36980533796 on 2026-10-02, ran on `main`. This replaces the original
  consequence that kept the schedule off `develop` until the workflow reached
  `main` through Git Flow. What changes: each scheduled run executes the
  workflow at the head of `develop` when GitHub starts it, which can be hours
  after the nominal `02:00 UTC`. A change to the schedule or to a phase takes
  effect when it merges to `develop`, and the four phases package that head,
  not the contents of `main`. The copy of the workflow on `main` is not scheduled.
  Release packaging stays on `release/*` through TA-022. The scheduled jobs
  guard only on the `schedule` event, so no workflow condition or test pins
  `main` for the schedule, and none changed.
- **Amendment (2026-10-06, weekly schedule, issue #264):** The owner moved the
  scheduled milestone from daily to weekly, on Saturday at `02:00 UTC` (cron
  `0 2 * * 6`). At prototype stage, packaging-only changes are rare. Owner
  pull requests with engine-impacting changes already compile, but a pull
  request limited to portable-only paths or to the two exact packaging-script
  exemptions (`scripts/build/Build-PackagedArtifacts.ps1` and
  `scripts/build/Invoke-PackagedSmokeTest.ps1`) is exercised on the engine
  only by the scheduled and release packaging runs (TA-022). Weekly stretches
  that gap from at most a day to at most a week; the owner accepted weekly on
  2026-10-06. The owner estimated about one to two hours of runner time per
  run (the 40/40/20/20-minute phase ceilings sum to two hours; no healthy
  phased run has been measured yet), and a run could start late enough to
  overlap the owner's working hours. The four phases, their bounds, the
  handoff and evidence contracts, and the CI authority predicate are
  unchanged.
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
  provided on this identity. TA-022 (2026-10-03) later adds internal release
  packaging on a separate workflow identity. `trusted-candidate-compile` additionally needs the GitHub-hosted
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
  only those four exact CI paths (historical; TA-018 later narrowed the
  exempt list): Unreal compilation does not validate
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
  if these scripts start generating engine inputs. TA-018 (2026-10-02)
  partially reverses this applicability decision: the six controller paths
  (`scripts/ci/Invoke-CiSuite.ps1`, `scripts/ci/Test-FormattingPolicy.ps1`,
  `scripts/ci/Test-MarkdownLinks.ps1`, `scripts/ci/Invoke-EngineRunnerGate.ps1`,
  `scripts/ci/Initialize-CompileWorkspace.ps1`, and
  `.github/workflows/prototype-quality-gates.yml`) require compile again so
  the native producer can publish `controller-operational-proof`; only the two
  `scripts/build/` paths remain exempt. Everything else,
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
  and report upload sit only inside the job bound. TA-020 (2026-10-02) adds a
  sixth engine-runner job, `trusted-editor-automation`, with a 45-minute
  ceiling (35 minutes before the 2026-10-03 re-sync amendment) after a
  successful trusted compile; a scheduled phase that queues while it runs
  waits at most those 45 minutes for it. The recorded
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
  TA-020 adds the owner-only `trusted-editor-automation` job at 45 minutes
  since its 2026-10-03 re-sync amendment (its step bounds plus a 3-minute
  margin) and leaves every watchdog here unchanged.
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
  Receipt publishers and the shadow aggregate bind their base to the same
  verified first parent through the selector's `accepted_base_sha` output,
  never the raw event base. GitHub does not refresh the event base when the
  target branch moves, so that binding failed every pull request behind its
  base with `selector_identity_mismatch`, on every rerun. The selector diffs
  the first parent against the tested merge, not the head, so a head behind its
  target is not charged with reversed upstream changes. Because the selector is
  accepted-base code, that diff applies only to runs whose accepted base
  already contains it. A conservative fallback report, for example after
  `path_unclassified`, carries the same accepted-controller blob OID and
  SHA-256 as a classified report. Both come from the trusted control
  repository, never from the candidate. The workflow's identity check
  therefore accepts it, and the all-selected selection fails safe instead of
  failing the selector job.
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
- **Amendment (2026-10-05, selector aligned with `change-impact`, issue
  #231):** the selector and `change-impact` disagreed for two path classes,
  and the producer-gap path failed with `producer_direct_binding_invalid:native`
  because the selector required a native receipt for a compile that
  `change-impact` skipped. This reverses the reconciliation rule above that
  kept unwired lookalikes unclassified, for one class: new
  `tests/content/*.ps1` and `tests/content/*.md` files, nested ones included,
  are now portable, as every other `tests/**/*.ps1|md` path already was. Any
  other `tests/content/` file, such as a `.json` fixture, still fails closed as
  `path_unclassified`. The two packaging scripts
  `scripts/build/Build-PackagedArtifacts.ps1` and
  `scripts/build/Invoke-PackagedSmokeTest.ps1` no longer select
  `controller-operational-proof`; they select `portable` and
  `clean-package-provenance-smoke` only, because the Compile gate never runs
  them. The match is exact and case-sensitive, so a case variant of either
  filename keeps operational proof. The `change-impact` block and the
  authority predicate are unchanged. The selector candidate is 41,492
  LF-normalized bytes with digest
  `40cb0f0c2aeee97557d0d939d63ce7e1b68274338033304a4c11a7626a70313d`. It is a
  new policy identity and grants no activation authority; the earlier
  digests above stay as recorded, and `docs/continuous-integration.md` holds
  the detail.
- **Package 3C receipt and aggregate wiring amendment:**
  `ci-selection-shadow` now exposes the validated nonce, aggregate readiness,
  all eight exact obligation decisions, and its artifact ID/name/API digest as
  direct `needs` outputs. The portable, trusted native client/server compile,
  and reusable visual jobs expose their truthful raw artifact ID/name/digest
  plus inner report SHA-256/length; the separate `trusted-editor-automation`
  job (TA-020) exposes the normalized `unreal-automation-report` from the
  frozen two-test harness run in the managed compile workspace. Four hosted
  receipt-publisher jobs download those exact artifacts by ID, validate the raw
  typed reports, and publish nonce-bound shadow receipts for `portable`,
  `controller-contract`, `controller-operational-proof`,
  `native-client-server-compile`, `unreal-editor-automation`, and
  `visual-package` only. The portable
  publisher proves `controller-contract` and `portable` from the same exact
  `ci-report.json`, limited to the selector-derived subset carried in its
  identity context; `controller-contract` additionally requires every required
  `tests/ci` suite to pass. The native publisher proves
  `controller-operational-proof` and `native-client-server-compile` from the
  same exact `engine-runner-report.json` under the same selector-derived
  subset rule; both results bind zero native exit, verified cleanup, and the
  `trusted-candidate-compile` runner identity, and the report is revalidated
  under each check id with its own reason suffix. The unreal publisher proves
  `unreal-editor-automation` from the exact `unreal-automation-report.json`
  with zero native exit and no cleanup claim; its runner identity is covered by
  the native receipt the selector always co-selects. The editor build and
  harness run in their own engine-runner job after a successful compile (see
  TA-020), so an automation failure leaves the compile job and native receipt
  intact while the unreal receipt reports the fixed `automation_reason` and
  fails red at its raw binding check. Host-lease wrapping remains a follow-up.
  `New-CiAcceptanceAggregateContext.ps1` builds closed identity contexts and,
  when the selector's chosen checks are a subset of those six live
  obligations, nonce-specific requirements with an exact selector binding and
  sorted producer bindings. Each binding carries the job name and exact
  artifact ID/name/digest from the named direct dependency. The aggregate
  independently reconciles those bindings with the current attempt's GitHub
  job/artifact API and downloaded bytes. Missing, duplicate, extra, unselected,
  swapped, replayed, malformed, unsorted, or digest-mismatched bindings fail
  closed. This direct producer binding resolves the earlier shared-nonce
  uploader ambiguity; interval checks remain additional temporal evidence.
- **Known producer-gap behavior:** When any selected obligation is outside the
  live portable/controller-contract/controller-operational-proof/native/unreal/visual subset, the aggregate is not called. The workflow
  still validates the selector identity and the direct bindings of every
  selected live producer, so a failed or skipped required receipt remains red
  rather than hiding behind the gap, and emits the exact selected
  unsupported set as a green `producer_contract_incomplete` record
  (`aetheln.ci-acceptance-shadow-gap/v3`, carrying the checked
  `liveBindings`) with
  `complete=false`, `shadow=true`, `authoritative=false`, and
  `grantsAcceptance=false`. The green result prevents a known incomplete shadow
  migration from making healthy pull requests permanently red; it is never an
  acceptance result. Any unexpected identity, semantic, reconciliation, or
  publication error remains red. `clean-package-provenance-smoke` and
  `content-reference-validation` remain unsupported live obligations. The gap
  path checks only job success, the exact artifact name, and the artifact ID and
  digest format; it does not do the aggregate's artifact-API and byte
  reconciliation, and `liveBindings` is informational. A
  publisher-contract test ties the three selector-facing lists (the workflow
  live list, the context builder live list and the aggregate unsupported list)
  and the aggregate's inline exactly-one-evidence list to the checks the
  publishers can prove, so shipping a producer fails that test until those
  lists move together. Two other copies are not covered by it. The receipt
  builder's unsupported-check list fails closed: a stale entry makes the builder
  throw `receipt_semantic_evidence_unsupported:<id>`. The receipt builder's
  inline evidence list is inert, because its strict evidence-name ordering
  check still rejects a repeated evidence entry.
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
  in that block
  (5,633 bytes at SHA-256
  `f1ae549ac2b628df3a09b4d29d6b9f20e237e0c31cc3060ae44bf44923c3a9df`);
  TA-018 removed the six controller paths from its portable-only set, so its
  current normalized identity is 5,395 bytes at SHA-256
  `e4a7bc5968f066178d1b78cb26d15df06f60af50696cda51b8e758ca8a38c805`,
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

### TA-018 - Compile Controller Changes for Operational Proof

- **Status:** Accepted
- **Scope:** Issue #167 Package 3C `controller-operational-proof` producer and
  the `change-impact` portable-only exemption list in
  `.github/workflows/prototype-quality-gates.yml`.
- **Decision (2026-10-02):** Under the owner's direction for the
  `controller-operational-proof` producer, partially reverse the TA-012
  applicability decision of 2026-09-06. Remove exactly
  `scripts/ci/Invoke-CiSuite.ps1`, `scripts/ci/Test-FormattingPolicy.ps1`,
  `scripts/ci/Test-MarkdownLinks.ps1`, `scripts/ci/Invoke-EngineRunnerGate.ps1`,
  `scripts/ci/Initialize-CompileWorkspace.ps1`, and
  `.github/workflows/prototype-quality-gates.yml` from the closed
  case-sensitive portable-only set, so a pull request that changes only those
  controller files publishes `engine_required=true` and runs
  `trusted-candidate-compile`. Exactly
  `scripts/build/Build-PackagedArtifacts.ps1` and
  `scripts/build/Invoke-PackagedSmokeTest.ps1` remain exempt: a
  `scripts/build/` change co-selects the unsupported
  `clean-package-provenance-smoke` obligation and takes the green gap branch,
  so no compile could turn it into proof. Every other TA-012 rule (uncertainty
  fails closed to `engine_required=true`, lookalikes and case variants compile,
  trust predicates, portable gates before engine work, phase bounds) is
  unchanged. The accepted-base selector `scripts/ci/Get-CiSelection.ps1` is
  unchanged, so its digest and pinned blob are unaffected.
- **Why:** `controller-operational-proof` attests that the candidate
  controller at the tested revision ran the real supervised Compile gate on
  the engine runner with resource monitoring and verified cleanup in this
  attempt; its only truthful producer is the `trusted-candidate-compile`
  report republished by `native-receipt-shadow`. The selector selects it for
  every `scripts/ci/` or live-workflow change, but the exemption skipped that
  producer, so the aggregate failed red at
  `producer_direct_binding_invalid:native` and activation could never obtain
  proof. Unreal compilation still does not validate portable scheduling,
  policy checks, or workflow YAML logic; the required portable suite and
  independent review remain the gates for that logic. The compile is
  operational proof of the controller, not a substitute for them.
- **Cost:** one incremental Windows client plus Linux server compile on the
  self-hosted `aetheln-engine` runner per owner controller pull request,
  behind the existing `quality-gates` success requirement and the FIFO
  `aetheln-engine-runner` queue.
- **Alternatives:** a new green gap reason for "selected but compile skipped"
  (hides the missing proof); accepting the red native binding (makes every
  controller pull request permanently red); adding `hostLease` to the engine
  report (changes the closed report shape in both validators and the gate).
- **Consequences:** a non-owner pull request that selects
  `controller-operational-proof` still skips the compile under the trust
  predicates and fails red at the native binding, the pre-existing
  `native-client-server-compile` behavior now reachable for controller-only
  changes. A pull request that touches only
  `scripts/ci/Invoke-EngineRunnerGate.ps1` or
  `scripts/ci/Initialize-CompileWorkspace.ps1` now compiles but still lands in
  the green `producer_contract_incomplete` gap, because the accepted selector
  co-selects the unsupported `clean-package-provenance-smoke` for those two
  paths exactly as it does for `scripts/build/`; the owner directed their
  removal from the exempt set, so that compile cost without operational proof
  is recorded here rather than hidden. Authority stays off: the `ci-acceptance-authority` predicate remains
  literally `always() && github.event_name == 'pull_request' && false`, and no
  receipt or aggregate grants acceptance.
- **Amendment (2026-10-05, issue #231):** the statement above that the
  accepted-base selector is unchanged was true on 2026-10-02 and stays as
  recorded. The selector has since stopped selecting
  `controller-operational-proof` for exactly the two exempt packaging
  scripts, so a packaging-only pull request selects `portable` and
  `clean-package-provenance-smoke` and takes the green gap branch this
  decision assumed. The exempt list, the controller paths, and the compile
  decision are unchanged, so the revisit trigger below is not met. The
  selector digest changed; the TA-017 amendment of the same date records it.
- **Owner:** Issue #167.
- **Revisit trigger:** the selector stops selecting
  `controller-operational-proof` for these paths, the producer moves off the
  compile report, or the per-PR compile becomes a measured engine-runner
  bottleneck.

### TA-019 - Private Art Plugin Loaded Only by Local Editor Sessions

- **Status:** Accepted. Basis: on 2026-10-02 the owner approved splitting art
  into a private repository and delegated the loading mechanism to the lead.
  Human review of the implementing pull request is still pending.
- **Scope:** Issue #201 art storage boundary: the private `aetheln-art`
  repository, local editor launch, and the `formatting-policy` check.
- **Decision (2026-10-02):** Fab Standard License, Megascans, paid-pack, and
  AI-generated art live only in the private `ShayShimoni/aetheln-art`
  repository as the content-only plugin `Plugins/AethelnArt`. The plugin has
  no modules, sets `CanContainContent`, is enabled by default, and uses LFS
  rules that mirror this repository. The public project does not name it at
  all: `AethelnOnline.uproject` gains no `Plugins` entry and no
  `AdditionalPluginDirectories` key. A contributor with access loads it for a
  local editor session only. They set the editor-only environment variable
  `UE_ADDITIONAL_PLUGIN_PATHS` on the launching shell process to the plugin
  folder of their clone, as shown in
  [Unreal Project Setup](unreal-project-setup.md). Public `Content/`,
  `Config/`, `Source/`, `Plugins/`, and the `.uproject` never reference
  `AethelnArt`; art-dependent maps live inside the private plugin.
- **Epic template content stays public:** Mannequins and LevelPrototyping
  come from the engine `Templates` folder, so they are UE EULA "Examples",
  which section 4(b) allows distributing. They remain under the UE EULA, not
  a repository license.
- **Context:** The repository became public on 2026-10-02. Per Epic's Fab
  licensing documentation, the Fab Standard License allows sharing through a
  private repository with project collaborators but forbids standalone
  redistribution, which a public repository is. The Fab EULA text itself was
  not retrievable during research, and this record is not legal advice. No
  Fab, Megascans, or paid content was ever committed, so no history rewrite
  is needed.
- **Evidence:** Static reading of the pinned 5.8.1 engine source, with paths
  relative to the engine root:
  - `Engine/Source/Runtime/Projects/Private/PluginManager.cpp`: the
    `GetAdditionalExternalPluginsByEnvVar` function reads
    `UE_ADDITIONAL_PLUGIN_PATHS` only under `WITH_EDITOR`. It returns nothing
    in game, client, or server builds.
  - `GetPluginPathsByEnv` splits the value on `;` on Windows and on `:`
    elsewhere.
  - `DiscoverAllPlugins` adds each path as an external discovery root.
    `ReadPluginsInDirectory` skips a missing directory.
  - External plugins count as project plugins, so `EnabledByDefault` applies.
  - A content-only plugin needs no UBT or compile step.
  - Repository CI scripts and workflows never set this variable. CI could see
    private art only if a host set it persistently; see Consequences.
- **Alternatives:**
  - The `.uproject` key `AdditionalPluginDirectories` is rejected. Both
    trust-boundary input checks deliberately refuse any
    `AdditionalPluginDirectories` or `AdditionalRootDirectories` key:
    `scripts/ci/ManagedCompileWorkspace.ps1:243`
    (`managed_workspace_external_descriptor_root`) and
    `scripts/ci/InitialPreparation.Input.ps1:213`
    (`input_external_descriptor_root`). Tests pin both. A relative
    `../aetheln-art` path could also resolve to a real private clone on the
    runner host.
  - A git submodule at `Plugins/AethelnArt` or `Content/Art` is rejected.
    `scripts/ci/Get-CiSelection.ps1:326` throws `checkout_unsupported_entry`
    on any gitlink, and both `scripts/ci/InitialPreparation.Input.ps1:65` and
    `scripts/ci/ManagedCompileWorkspace.ps1:127` reject `.gitmodules`. Fork
    clones would also get a broken pointer.
  - A gitignored clone inside the tree is rejected.
    `scripts/ci/InitialPreparation.Input.ps1:105-106` and
    `scripts/ci/ManagedCompileWorkspace.ps1:330-331` run
    `git ls-files --others` without `--exclude-standard` over `Content`,
    `Plugins`, and the other build inputs. They fail with
    `input_untracked_build_input` and `managed_workspace_untracked_input`.
  - Perforce or Diversion stays the escape hatch if LFS quota or binary size
    becomes the bottleneck.
- **Consequences:**
  - Hosted jobs, fork pull requests, `trusted-candidate-compile`, and the
    scheduled engine jobs are unchanged and never load the art.
  - Rule 4 of `scripts/ci/Test-FormattingPolicy.ps1` fails when a tracked
    `Content/`, `Config/`, `Source/`, or `Plugins/` file, or the `.uproject`,
    matches `AethelnArt`. It also fails when a tracked file in those paths is
    missing from the work tree.
  - The rule scans text and hydrated binary assets. It counts and reports LFS
    pointer files: files of 1 KiB or less with the spec version, `oid sha256:`,
    and `size` lines.
  - Only the hosted `quality-gates` job runs the rule. It fetches only
    `Content/Maps/StarterMap.umap` from LFS. Hosted CI therefore scans text
    files plus that one map. A full binary `Content/` scan is local-only
    today, and no runner job runs this check.
  - The byte match finds ANSI (single-byte) names only. A non-ASCII path stored
    as a UTF-16 `FString` inside an asset is not detected.
  - Never set `UE_ADDITIONAL_PLUGIN_PATHS` persistently, at user or machine
    scope, and especially not on the runner host. Editor-binary cook and
    automation jobs would then load private art. Scheduled package artifacts
    are uploaded from this public repository. Nothing enforces this today;
    see the follow-ups.
  - The rule lives in an existing check because adding a check name changes
    the closed portable, receipt, and aggregate check lists. It is under
    `scripts/ci/`, so editing it also selects the trusted compile (TA-018).
  - Private LFS storage shares the account's 10 GiB quota with this
    repository.
- **Follow-up (not implemented):**
  - Packaging or cooking with the art. The cook commandlet runs in an editor
    (`WITH_EDITOR`) binary, so the same variable could serve a scheduled
    trusted-runner packaging job. That job would clone `aetheln-art` with a
    fine-grained read-only token, stored as a secret that `pull_request` jobs
    never receive.
  - A `/AethelnArt/` dependency assertion in
    `scripts/build/Validate-ServerCookReferences.ps1`.
  - Hydrated `Content/` scanning in CI, for example by running the rule in an
    LFS-pulling job.
  - Guard against a persistent `UE_ADDITIONAL_PLUGIN_PATHS`: pin it empty in
    the workflow `env`, or fail the engine-runner gate when it is non-empty.
- **Owner:** Issue #201, including the follow-ups until they move to their own
  issue. #202 and #203 consume this boundary. Intake and provenance follow #120
  and the `visuals/asset-provenance.md` model.
- **Revisit trigger:** The first licensed asset needs a public reference, LFS
  quota or binary size forces another VCS, or an engine upgrade changes
  `UE_ADDITIONAL_PLUGIN_PATHS` handling.

### TA-020 - Separate Engine-Runner Job for Unreal Editor Automation

- **Status:** Accepted
- **Scope:** Issue #167 Package 3C `unreal-editor-automation` producer and the
  engine-runner operational ceilings recorded in TA-012 and TA-015.
- **Decision (2026-10-02):** Under the lead's direction, run the editor build,
  the frozen two-test harness, residue cleanup, report binding and upload, and
  the outcome report in a new self-hosted job, `trusted-editor-automation`,
  instead of inside `trusted-candidate-compile`. The job needs
  `trusted-candidate-compile` (so it runs only after a successful compile and
  is skipped, not failed, when the compile is skipped or fails), keeps the
  same pull-request, same-repository, owner, and triggering-actor predicates,
  targets `[self-hosted, Windows, X64, aetheln-engine]`, joins the
  `aetheln-engine-runner` group with `queue: max` and
  `cancel-in-progress: false`, and had a 35-minute job ceiling: its step
  bounds (editor build 15, harness 12, residue cleanup 2, bind 1, upload 1,
  outcome 1) plus a 3-minute margin, raised by the re-sync amendment below.
  Every step continues on error. It reused the registered managed compile
  workspace only after verifying that the workspace still held the tested
  revision and was clean, and failed with a fixed reason otherwise; the re-sync
  amendment below replaces that check with a leased re-sync.
  `trusted-candidate-compile` returns to its
  pre-producer shape, and the TA-015 30-minute compile watchdog is unchanged.
  The engine runner now has six jobs.
- **Evidence:** first live runs on runner 21. The `trusted-candidate-compile`
  step "Compile supported client and server targets" took 102 s on PR #204 (a
  CI-script change) and 503 s on PR #205 (a Source change). Inside the compile
  job, the editor build would have needed the compile to finish within about
  6 minutes of the job's start to fit the remaining 40-minute budget, so it
  would have been skipped on exactly the Source pull requests it exists to
  cover. A separate job gives the editor build its full budget even when the
  compile uses its whole 30-minute watchdog.
- **Cost:** an owner engine pull request can hold the runner for up to
  85 minutes (40-minute compile plus 45-minute editor automation) when no
  older waiter queued between the two jobs (75 minutes before the re-sync
  amendment). A scheduled phase that queues while the editor job runs waits
  at most 45 minutes for it; the recorded 40-minute trusted-compile queue
  delay attributable to one running scheduled phase is unchanged. Workspace
  race (history, resolved by the re-sync amendment): when another owner pull
  request's compile, or a newer push to the same pull request, entered the
  engine queue during this pull request's compile window, it could re-sync the
  managed workspace before the editor job started. The editor-build step then
  stopped with `editor_workspace_revision_changed` instead of building another
  revision; the editor job still succeeded because every step continues on
  error, and only `unreal-receipt-shadow` failed, when it was selected.
  Recovery took a full workflow re-run, because re-running only the failed
  jobs skipped the successful editor job.
- **Alternatives:** lowering the editor or harness bounds (unmeasured, and
  would still skip on slow compiles); a budget-skip that publishes a green gap
  (reintroduces the exemption TA-018 removed); raising the compile job ceiling
  (TA-015 forbids raising ceilings without retained evidence).
- **Consequences:** a failure in the editor automation job never affects the
  compile job or `native-receipt-shadow`; `unreal-receipt-shadow` needs the new
  job and fails red at its raw binding check, printing the fixed
  `automation_reason`, when no report was uploaded. The job first ran outside
  the engine host lease and only checked the workspace revision; the re-sync
  amendment below wraps the re-sync and editor build in the lease and replaces
  the check with a real re-sync through `Sync-ManagedCompileWorkspace`
  (`scripts/ci/ManagedCompileWorkspace.ps1`), as the gate's managed compile
  path in `Invoke-EngineRunnerGate.ps1` does. Record editor-build and
  harness durations from the first live runs. Authority stays off.
- **Amendment (2026-10-02, shared engine tree):** the editor build shares
  the pinned engine tree with contributor builds. This amendment removes the
  source-code-access plugin flip. It does not make the job leave the engine
  unchanged. Residual cost: every CI editor run still relinks
  `UnrealEditor-NetCore.dll` and rewrites the engine editor BuildId. A
  contributor editor built before that run then needs a rebuild of about
  30 seconds before it loads again. `-NoEngineChanges` is deferred (see
  *Deferred fail-closed* below).
  - *Incident:* the run 37056028961 editor build passed
    `-Compiler=VisualStudio2022` and relinked
    `UnrealEditor-VisualStudioCodeSourceCodeAccess.dll`, which rewrote the
    engine editor BuildId in `UnrealEditor.version`. The next contributor build
    relinked it again and produced another BuildId, which invalidated the
    editor binaries of every other worktree. Cause:
    `VisualStudioCodeSourceCodeAccess.Build.cs` emits `VSACCESSOR_HAS_DTE=1`
    only when `WindowsPlatform.ToolChain` is `VisualStudio2022` (and the DTE
    registry key exists), and `0` otherwise. The CI build resolved
    `VisualStudio2022`; contributor builds, which pass no `-Compiler`
    (`docs/unreal-project-setup.md`), resolve `VisualStudio`. The flip recurs on
    every switch between a CI editor build and a contributor build.
  - *NetCore regeneration (recurring, cause unknown):* both observed CI editor
    runs (37056028961 and 37061874410, the PR #207 run) rewrote
    `Engine/Intermediate/Build/Win64/UnrealEditor/Inc/NetCore/UHT/NetCore.init.gen.cpp`
    and relinked `UnrealEditor-NetCore.dll`, which rewrote the BuildId. The
    trigger is that NetCore's UHT output alternates between two package body
    hashes. That has been seen only when CI and contributor builds alternate,
    never across consecutive builds of one project. Each run also flipped the
    plugin definition, which the compiler alignment below removes. Only the package registration body hash changed: it went to
    `0xF26BCE42` in the first run and to `0x6C2D6518` in the second. The
    declarations hash (`0x12F0F921`) and every per-header NetCore `.gen.cpp`
    (unchanged since the engine build) stayed the same. The contributor editor
    build that followed the second run flipped the definition back but left
    NetCore and its DLL alone. No CI argument explains the difference:
    - The arguments only CI passed were `-UBA -UBADisableRemote -NoXGE -NoSNDBS
      -NoFASTBuild -MaxParallelActions=4`, the compiler pins, and, before this
      change, `-Compiler=`. CI also sets child-only dotnet and toolchain
      environment variables and builds a project on another drive.
    - None of these reaches UHT. Both logs invoke the internal UHT with only
      the project, the manifest, and `-WarningsAsErrors`.
    - The CI and contributor `AethelnOnlineEditor.uhtmanifest` files are
      identical for all 588 engine modules, NetCore included (headers,
      definitions, dependencies, output directory). They also have the same
      target settings, with the UHT input cache off (it is enabled only by
      `-EnableUHTInputCache` or `IsBuildMachine=1`), and no UHT plugins. Only
      the four project modules' paths differ.
    - UHT writes an output only when its bytes differ. Header ordering is ruled
      out, because UHT sorts headers before it combines body hashes. Monolithic
      client and server builds always produce `0x6C2D6518`.
    - The two contributor builds ran full-target UHT on identical project
      sources and each left whatever value they found. A deterministic
      generator could not have matched both values, so the input that varies
      between UHT runs is not yet identified.
  - *Compiler alignment:* for `AethelnOnlineEditor` only,
    `InitialPreparation.BuildInvocation.ps1` no longer passes `-Compiler=` and
    keeps `-CompilerVersion=14.44.35207 -WindowsSDKVersion=10.0.26100.0`. In the
    pinned UnrealBuildTool (`Platform/Windows/UEBuildWindows.cs`), `Compiler`
    stays `Default`, so `GetDefaultCompiler` has no `PreferredCompilers`, and
    `GetDefaultToolchain` finds no project-file format, an empty
    `BuildConfiguration.xml`, and no `PreferredAccessor` in the EditorSettings
    hierarchy. It returns `WindowsCompiler.VisualStudio`, an alias of
    `VisualStudio2026`. `ToolChain` then copies the MSVC compiler.
    `MicrosoftPlatformSDK.FindToolChainInstallations(VisualStudio2026)` also
    adds the VS 2022 toolsets, and the version pin selects the same MSVC 14.44
    toolset that contributors use (both logs report product 14.44.35228).
    That resolution reads host configuration, so a `PreferredCompilers`,
    project-file format, or `PreferredAccessor` setting for the runner account
    would change it. Contributor builds on the same host under the same user
    account read the same inputs. A contributor can bring the plugin flip back
    by preferring VS 2022 in the per-account `BuildConfiguration.xml` or by
    setting `PreferredAccessor` to VS 2022 in the user-level
    `EditorSettings.ini`. The plugin-header hash monitoring below would catch
    that.
    Client and server compile invocations, and the compile host proof's
    `requiredWindowsArguments`, keep `-Compiler=VisualStudio2022`: those targets
    write their UHT and definition outputs under the project's `Intermediate`
    and do not build the editor-only plugin.
  - *Deferred fail-closed:* the editor target does not pass
    `-NoEngineChanges` yet. The NetCore regeneration happens on every CI editor
    run, so the flag would turn `unreal-receipt-shadow` and
    `ci-acceptance-shadow` red on every owner Source pull request. A test pins
    that the flag is absent. The mapping is ready for when the NetCore
    follow-up lands. With the flag, if an outdated action would rewrite an
    existing file under `Engine/`, UBT (`Modes/BuildMode.cs`) logs the file
    list and exits 5 (`CompilationResult.FailedDueToEngineChange`), and
    `Build.bat` passes that code through. The editor-build step already maps
    exit 5 without a capture failure to the fixed reason
    `editor_build_engine_changes_required`, and an executed fixture covers it.
    Every other nonzero exit stays `editor_build_failed`. The file list holds
    engine paths, so it would stay in the runner-local `build.log`. Even
    enabled, UBT runs the check after it creates the makefile, so UHT outputs
    and `Definitions.*.h` headers may already be written. The flag stops
    engine compile, link, and BuildId rewrites only.
  - *Monitoring:* before and after CI editor runs, hash `NetCore.init.gen.cpp`
    and the plugin header
    `Engine/Plugins/Developer/VisualStudioCodeSourceCodeAccess/Intermediate/Build/Win64/x64/UnrealEditor/Development/VSCSCA/Definitions.VSCSCA.h`.
    Follow-up (required): find what varies the NetCore package body hash. Run
    UHT repeatedly against a scratch engine copy with the same manifest, then
    compare the per-header body hashes and the exported header set, and align
    or pin whatever input varies.
  - *Follow-ups:* package jobs are unchanged. In `rebuild-authorized` mode,
    `scripts/build/HostToolProvisioning.Policy.ps1` passes
    `-Compiler=VisualStudio2022` when it rebuilds host `UnrealEditor`, so it can
    flip the same definition. Align it separately. Longer term, give each
    consumer an isolated or installed engine tree, which removes both
    exposures. Live proof is still pending: the next CI editor run should show
    no plugin relink, which leaves NetCore as the only engine rebuild.
- **Amendment (2026-10-03, workspace re-sync, issue #236):** on 2026-10-03
  the workspace race hit two of seven parallel pull requests (PR #227, run
  37132326052; PR #232, run 37131973257), and each recovery cost a full
  compile cycle on the single runner. The job now checks out its own
  exact-revision control source at `github.sha` into
  `editor-control-<run>-<attempt>` with the compile job's checkout inputs (no
  persisted credentials, no LFS, 5 minutes). In one 20-minute step it then
  takes the engine host lease, re-syncs the registered managed workspace to
  that revision, and builds the editor. The control-checkout copy of
  `scripts/ci/Sync-EditorAutomationWorkspace.ps1` validates the registration,
  calls `Sync-ManagedCompileWorkspace` with the registered trust tuple, and
  keeps the revision and clean checks as post-sync assertions; the build uses
  the control-checkout copy of `InitialPreparation.BuildInvocation.ps1`.
  - *Lease:* lease wait, sync, and build share one 17-minute deadline. The
    sync child and the build each run in an owned kill-on-close Job Object
    (`Aetheln.PreparationJob`) that stops at that deadline, and the step
    releases the lease only after each job is proven empty, within the step
    bound. Nothing is stopped by name or command line. An unproven cleanup or
    a failed release keeps the held journal for explicit recovery, as the
    compile does, and records `editor_host_lease_release_failed`. The harness
    and residue cleanup still run outside the lease, serialized by the engine
    queue. Residue cleanup is skipped when the lease state is unknown or held
    by someone else (issue #243): after `editor_host_lease_failed` or
    `editor_host_lease_release_failed`, a skipped editor step, or an
    interrupted one that recorded no reason.
  - *Reasons:* `editor_host_lease_failed`, `editor_workspace_sync_failed`,
    `editor_build_timeout`, `editor_host_lease_release_failed`, and
    `editor_control_checkout_failed` join the fixed vocabulary; the lease or
    sync module's own fixed code is printed as one
    `editor_build_detail code=<code>` line. `editor_build_timeout` means only
    that the build reached the deadline: a lease wait that reaches it records
    `editor_host_lease_failed`, and a sync that times out records
    `editor_workspace_sync_failed` with no detail code. Issue #243 adds
    `editor_sync_time_insufficient`, recorded when less than the provisional
    fixed 5-minute minimum remains after the lease is taken, before any
    checkout starts.
  - *Ceiling:* the job now has a 45-minute job ceiling: its step bounds
    (control checkout 5, re-sync and editor build 20, harness 12, residue
    cleanup 2, bind 1, upload 1, outcome 1) plus a 3-minute margin. The added
    10 minutes pay for the new checkout and re-sync work, not for a slower
    build. An owner engine pull request can now hold the runner for up to
    85 minutes (40-minute compile plus 45-minute editor automation).
  - *Pending evidence:* one live observation of two compile-selecting pull
    requests pushed together that both reach a green `unreal-receipt-shadow`.
    Authority stays off.
- **Amendment (2026-10-04, runner engine isolation):** the lead selected an
  independently writable runner source-engine tree for
  [Issue #238](https://github.com/ShayShimoni/aetheln-online/issues/238#issuecomment-5976376517).
  This is the architectural direction; capacity, provisioning, deployment and
  isolation proof remain pending. The shared-tree behavior above still applies
  until the new route is deployed and verified.
  - *Roles and identity:* keep contributor builds and editor launches on the
    contributor engine root; route CI compile, editor automation and packaging
    to the independently provisioned runner engine root. Preserve the pinned
    engine source and toolchain identities, clean Git checkout at exactly the
    pinned revision and automatic BuildId stale-module refusal. Do not pin a
    BuildId or weaken the loader.
    Keep root paths in local configuration. Bind each role's registration,
    compile proof, host-tool attestation and cache identity to its actual root
    and verified inputs; do not reuse evidence from the other root.
  - *Output separation:* engine and plugin binaries, generated source,
    intermediates and module manifests must have no shared writable aliases,
    including hardlinks or junctions. A second path to the same writable
    outputs is not isolation. Existing admission, queue, lease and failure
    rules remain in force; this amendment does not change CI authority.
  - *Provisioning gate:* measure available active-storage capacity, the
    supported engine payload and peak build space before copying or building.
    Preliminary, metadata-only evidence on the Issue #238 thread shows about
    95 GiB free on the active volume against about 212 GiB of logical engine
    data, so a plain full duplicate does not fit; this does not resolve the
    provisioning `TBD`. Capacity and provisioning are not yet approved or
    complete. Retain the
    working contributor tree and its evidence; this decision authorizes no
    deletion or relocation. An installed artifact is a possible later
    optimization; its size, construction peak, duration and supported-target
    validation remain `TBD`.
  - *Deployment proof:* bind both roots, project revisions, engine/toolchain
    identities and contributor DLL/manifest hashes before a CI editor build,
    such as the first editor build on the newly provisioned tree. Require
    evidence that the runner root's engine BuildId or NetCore outputs changed
    during that run; a no-op build does not qualify. Require the contributor
    engine's BuildId and relevant output hashes, and the contributor project's
    DLLs and manifests, to remain unchanged. Then launch that contributor project
    without rebuilding or restamping it and verify its modules and map load.
    Cover a CI failure after engine metadata work as well; a no-op build or
    successful CI result alone does not prove isolation. Record the new
    runner's provisioning and applicable build/automation evidence separately.
  - *Interim operation:* serialize shared-engine consumers until deployment.
    The procedure is lead/owner-coordinated outside the repository: the lead
    holds the engine and announces its release in the delivery status or
    issue. Recover an affected contributor project with the normal Development
    Editor `Build.bat` command in
    [Unreal Project Setup](unreal-project-setup.md), compare `BuildId` in the
    project and engine `UnrealEditor.modules` files, then relaunch. Never repair
    this by hand-editing generated manifests. Even after file isolation,
    performance captures require a quiet host because CI still competes for
    CPU, memory, storage and GPU resources.
  - *Rationale and alternatives:* a BuildId pin was rejected: CI would still
    write the shared NetCore DLLs, so serialization would remain, and it would
    remove stale-binary refusal. An installed engine is a later optimization
    (`TBD`). The NetCore root-cause fix plus `-NoEngineChanges` remains the
    TA-020 follow-up and does not isolate the trees. An unverified external
    hypothesis on Issue #238 (comment, 2026-10-04 05:02Z) attributes the
    NetCore output variance to a UHT race and proposes workarounds (enable the
    UHT input cache, or change `UhtHeaderFile.cs`). It is under evaluation; if
    confirmed, it triggers the TA-020 revisit before provisioning.
  - *Amendment owner and revisit:* Issue #238; revisit when the runner route
    is deployed and proven, or if capacity proves infeasible.
- **Amendment (2026-10-05, UHT input cache, issue #238):** the NetCore
  variance has a root cause and a fix. This amendment supersedes the
  2026-10-02 *NetCore regeneration (recurring, cause unknown)* analysis, the
  residual-cost statement in that amendment's lead-in ("every CI editor run
  still relinks `UnrealEditor-NetCore.dll` and rewrites the engine editor
  BuildId") and the 2026-10-04 treatment of the UHT-race report as an
  unverified hypothesis. It
  also changes the 2026-10-04 isolation direction as described below; it
  does not otherwise alter that amendment.
  - *Root cause:* a race in `UhtHeaderFile.cs`
    (`Engine/Source/Programs/Shared/EpicGames.UHT/Types/UhtHeaderFile.cs`).
    UHT reads and parses headers in parallel. `AddReferencedHeader` sets the
    `Referenced` export flag on a same-module header while holding the lock of
    the referring header, which does not protect that flag, and `Reset` clears
    the flag without a lock. The flag decides whether NetCore's only
    non-reflected header, `PushModel.h`, is exported, so it changes the
    `NetCore.init.gen.cpp` bodies hash between `0x6C2D6518` (flag lost) and
    `0xF26BCE42` (flag kept). Any flip rewrites that file, recompiles and
    relinks `UnrealEditor-NetCore.dll`, and restamps the shared engine
    BuildId, after which a contributor editor built earlier stops loading.
    An external user reported the race on the Issue #238 thread (and in an
    Epic Forums report); the lead's read of the pinned engine source confirms
    the code path, and the fix below was verified on live builds. The
    standalone idle harness did not reproduce the flip (10/10 default runs gave
    `0x6C2D6518`), the flip rate under load is unmeasured, and the
    kept/lost mapping of the two values is inferred from the source and the CI
    history. The absolute hash values depend on host and source line endings;
    the values above are this host's.
  - *Corrections to the 2026-10-02 amendment:* the UHT input cache is off
    on this host unless configured: `IsBuildMachine` is not set and UBT never
    sets it, and every inspected CI manifest had the cache off. A cache-off CI
    client build wrote
    `0xF26BCE42` on 2026-10-04, so "monolithic client and server builds always
    produce `0x6C2D6518`" does not hold. The contributor builds that left the
    value unchanged logged `Generated code is up to date`, so UHT did not run
    and they were not evidence of a deterministic generator. Cache-off UHT is
    the nondeterministic state.
  - *Fix:* set `bEnableUHTInputCache` to `true` for every builder in the
    engine's git-ignored UBT configuration file. The exact path and content
    are:

    ```text
    <engine root>\Engine\Saved\UnrealBuildTool\BuildConfiguration.xml
    ```

    ```xml
    <?xml version="1.0" encoding="utf-8" ?>
    <Configuration xmlns="https://www.unrealengine.com/BuildConfiguration">
      <UEBuildConfiguration>
        <bEnableUHTInputCache>true</bEnableUHTInputCache>
      </UEBuildConfiguration>
    </Configuration>
    ```

    With the cache read enabled, UHT re-applies `Referenced` after all parsing
    (`Resolve` in the `InvalidCheck` phase), so the result is `0xF26BCE42` on
    every run. No engine source edit is needed and the pinned clean checkout
    stays clean: the file lives under `Saved/`, which the engine's own
    `.gitignore` ignores, and the repository's engine cleanliness checks run
    `git status --porcelain --untracked-files=all` without `--ignored`.
  - *Provisioning requirement:* this file is now part of the provisioning of
    every engine tree that CI or contributors build: the runner's engine root
    and each contributor engine root (the same tree today). It is host
    configuration outside version control, so re-provisioning or recreating
    an engine tree loses it silently. Apply it in the same step that creates or
    restores the tree; the contributor step is in
    [Unreal Project Setup](unreal-project-setup.md#enable-the-uht-input-cache).
    UBT reads later configuration files (ProgramData, AppData, LocalAppData,
    Documents and the project `Saved/UnrealBuildTool/BuildConfiguration.xml`)
    after the engine file, so none of them may set the flag to `false`. With
    the cache on, UHT also writes git-ignored `.inputcache.data` files under the
    engine and project `Intermediate` folders; they are shared mutable state,
    serialized only by the host lease or UBT's `-WaitMutex`.
    CI scripts do not repeat the setting. A fail-closed pre-check of the file,
    or an `-EnableUHTInputCache` argument in
    `InitialPreparation.BuildInvocation.ps1` (one `command_line_changed`
    makefile reload), is a possible follow-up and is not implemented.
  - *Never use `-ForceHeaderGeneration`:* it turns the input-cache read off
    (`UEBuildTarget.cs`), which removes the re-apply step and brings the race
    back. Do not pass it for any build against these engine trees.
  - *Rejected for this problem:* a CI-only `-EnableUHTInputCache` (a
    contributor full UHT run could still flip the shared NetCore), a per-user
    `AppData` configuration file (it breaks if the runner changes account and
    does not cover other accounts), `-NoGoWide` (not reachable from UBT's
    internal UHT, and deterministic only at the other value), and an engine
    source edit of `UhtHeaderFile.cs` (it breaks the pinned clean-source
    check).
  - *Evidence:* the setting was applied on 2026-10-04 at 22:09Z and the engine
    tree stayed clean. One expected, one-time flip followed on the first
    compile after the fix (PR #242's CI build, 22:35Z): the shared engine
    BuildId changed from `5aaac352` to `5e7e5279` and NetCore settled on
    `0xF26BCE42`. Six local editor builds of the issue-19 branch followed;
    three ran full-target UHT with input-cache reads (UBT logs 23:42Z with 588
    cache reads, then 23:46Z and 00:47Z with 593 each) and three found the
    generated code up to date. After them, the engine
    `NetCore.init.gen.cpp` (22:35:34Z) and `UnrealEditor.modules` (22:35:58Z)
    were untouched and the BuildId stayed `5e7e5279`. The standalone harness
    also produced `0xF26BCE42` on 10/10 cold-cache runs. PR #245's compile run
    37242860365 (`trusted-candidate-compile` and `trusted-editor-automation` on
    runner 21) is weaker evidence: UHT did not run (generated code up to date)
    and the BuildId was unchanged, which shows no regression, not determinism.
    Expect one more one-time flip on any engine tree where the setting is first
    applied; it is not a regression.
  - *Effect on the isolation direction:* the 2026-10-04 amendment chose an
    independently writable runner source-engine tree to stop shared engine
    writes from churning the BuildId. With the NetCore flip removed, a
    dedicated writable second engine tree is no longer needed for this
    problem, and its capacity, provisioning and deployment-proof work is not
    required to resolve Issue #238. The option is not deleted: it remains the
    recorded alternative, with its pending items unapproved and unscheduled.
    Revisit it, and the 2026-10-04 isolation requirements, if any of these
    holds: the engine BuildId changes across a CI editor run or contributor
    build with the setting confirmed present; a different cause of shared
    engine writes appears; a measured contention cost from serializing
    shared-engine consumers justifies the storage; or an engine upgrade
    changes the UHT input-cache path or fixes the race upstream (then
    re-evaluate the setting itself). Serialization of shared-engine users
    through the existing host lease and queue stays a standing rule: the cache
    makes the BuildId deterministic but does not make concurrent engine writes
    safe. The recovery procedure above remains the fallback for any unexplained
    BuildId mismatch, and performance captures still require a quiet host.
  - *Follow-ups:* `-NoEngineChanges` stays off on the editor target. The
    revisit trigger "the NetCore follow-up identifies the varying UHT input"
    is met, but this amendment changes no script or test, so the flag and its
    pinning test remain until a separate change enables them (fixed reason
    `editor_build_engine_changes_required`). Keep the monitoring above and
    expect `NetCore.init.gen.cpp` to hold `0xF26BCE42`. Remove the setting only
    after a pinned engine revision contains an upstream fix for the race, and
    record that in a new amendment.
- **Owner:** Issue #167.
- **Revisit trigger:** measured editor-build or harness durations approach
  their step bounds, the leased re-sync fails or keeps the lease in practice,
  the combined compile plus editor hold becomes a measured scheduling bottleneck,
  the NetCore follow-up identifies the varying UHT input (then enable
  `-NoEngineChanges`), or the plugin definition header still changes across
  a CI editor run.

### TA-021 - Private GameCombat Dependency on the GameNet Observability Service

- **Status:** Accepted
- **Acceptance:** Accepted 2026-10-03 by the delivery lead under the owner's
  delegated authority.
- **Scope:** `GameCombat` module dependencies and the structured observability
  producers added by issue #38.
- **Decision (2026-10-03):** `GameCombat` keeps a private dependency on
  `GameNet` (`PrivateDependencyModuleNames.Add("GameNet")` in
  `Source/GameCombat/GameCombat.Build.cs`). The edge exists only so
  authoritative combat and movement producers can emit structured events
  through `UAethelnObservabilitySubsystem` (`AethelnObservability.h` and
  `AethelnObservabilitySubsystem.h`). The only other `GameNet` types it uses
  come in through those headers for the observability build context:
  `FAethelnNetworkProfile` and `AethelnNetworkSpike::UnsetNetworkProfileId`
  from `AethelnNetworkProfile.h`, which `AethelnObservability.h` includes, passed
  only into `SetBuildContext`. `GameCombat` exposes no `GameNet` type in its
  public headers.
- **Context:** Commit `186b4f89` (#38) added the edge without a record, and the
  issue #13 QA (AC6, DoD4) found it outside the `GameCombat` row of
  [Technical Architecture](technical-architecture.md). The producers are
  `AethelnSpikeCharacter`, `AethelnSpikeMovementComponent`,
  `AethelnSpikeAuthorityComponent`, and `AethelnNetworkSpikeGameMode`, plus the
  `AethelnNetworkSpikeAuthorityTests` automation test. Producers only enqueue,
  and sink failure never changes gameplay truth
  ([Observability and Crash Diagnostics](observability-and-crash-diagnostics.md)).
- **Evidence:** All direct `GameNet` includes in `Source/GameCombat/` are the
  two observability headers, in `Private/` source files only.
  `AethelnNetworkSpikeGameMode.cpp` and `AethelnSpikeCharacter.cpp` build an
  `FAethelnNetworkProfile` only to pass the network profile id to
  `UAethelnObservabilitySubsystem::SetBuildContext`. `GameNet.Build.cs`
  depends only on `Core`, `CoreUObject`, and `Engine`, so the edge is
  one-directional and adds no cycle. `GameServer` already depends on both
  modules.
- **Alternatives:** Move the observability service, or an emission interface,
  into `GameCore` so `GameCombat` needs no `GameNet` edge (deferred: a C++ move
  with no behavior change). Drop the combat producers (rejected: #38 requires
  correlated movement and combat activations, corrections, and rejection
  reason codes).
- **Consequences:** The `GameCombat` row in Technical Architecture lists the
  private edge, and the `GameNet` row lists the observability service.
  `GameNet` must never depend on `GameCombat`. The edge gives `GameCombat` no
  session, admission, or transfer access, and `GameNet` still owns no combat
  truth.
- **Owner:** Issues #13 and #38.
- **Revisit trigger:** `GameCombat` needs a `GameNet` type beyond those the
  observability headers bring in, `GameNet` needs a `GameCombat` type, or a
  reviewed change moves the observability service into `GameCore` or its own
  module.

### TA-022 - Dispatch-Only Release Packaging on a Separate Workflow Identity

- **Status:** Accepted
- **Acceptance:** Accepted 2026-10-03 by the delivery lead under the owner's
  delegated authority, after an independent security review of the
  self-hosted runner exposure. The owner accepted the runner-trust risk below
  on 2026-10-03.
- **Scope:** Internal pre-release packaging from `release/*` branches (issue
  #226).
- **Decision (2026-10-03):** `.github/workflows/release-packaging.yml`
  packages internal pre-releases. Its only trigger is `workflow_dispatch`, with
  no inputs. A hosted `release-gates` job refuses, red, anything but a dispatch
  by the repository owner of exactly `refs/heads/release/v<ProjectVersion>` in
  this repository on run attempt 1, and then runs the portable suite. Four
  engine jobs copy the TA-012 scheduled phases (gate, modes, bounds, handoff,
  and the `aetheln-engine-runner` group), and each repeats a literal six-clause
  trust predicate. The token is `contents: read`, checkouts do not persist
  credentials, and only six redacted reports are uploaded, kept for 90 days.
  Packaged bytes are never published, not even as a GitHub pre-release,
  because release assets on a public repository are world-downloadable;
  packages stay in the durable handoff store on the runner host. The build
  number is this workflow's `run_number`. The committed `ProjectVersion` has no
  `+<build>`; the build version lives in the provenance `release` block and
  the release evidence. Re-runs are refused, so one build number names one
  package. `prototype-quality-gates.yml` is unchanged and keeps no manual
  trigger.
- **Context:** TA-012 forbids a manual trigger on `prototype-quality-gates.yml`
  for the older branch reason: GitHub runs a dispatched workflow from the YAML
  at the selected ref, so an older branch that still carries the retired
  1,440-minute single-job gate could be selected. A new workflow identity has
  no such older copies. On 2026-10-03, 12 stale remote branches still declared
  that retired job. The owner deleted them that day (they are preserved
  locally as archive refs and a verified bundle), and a check after pruning
  found zero remote branches whose workflows declare `workflow_dispatch`. This
  decision reverses TA-012's clause that no replacement manual workflow is
  provided.
- **Runner trust and risk acceptance:** Release-package integrity rests on no
  untrusted code ever running on runner 21. That runner also runs
  owner-authored pull-request heads, including agent-written ones, under the
  owner's OS account and GitHub credentials, against the shared engine tree,
  DDC, handoff store, and `milestone/.git`, interleaved with release phases by
  design. The actor clauses cannot tell the human owner from an agent or a
  local process that uses the owner's credentials. The controls are: approval
  for every fork pull-request workflow run from an external contributor
  (verified 2026-10-03), the owner and same-repository predicates, and a
  standing rule to never approve a workflow run from a fork pull request while
  runner 21 is registered. Owner-authored pull requests, agent-written ones
  included, are trusted code. The owner accepted this risk on 2026-10-03 for
  internal builds that never leave the owner's control.
- **Release branch protection:** Before the first push of a release branch, a
  ruleset on `release/*` is created with these rules: block force-push, block
  deletion, require the `quality-gates` status check, and no bypass actors.
  Land `ProjectVersion` through a reviewed PR into `develop` before the cut;
  verify the resulting head's passing `quality-gates` check before pushing
  the release branch. Later version changes use a reviewed PR into the release
  branch, never an unchecked direct commit. The owner checks the remote head
  SHA against the reviewed head immediately before every dispatch: the ruleset
  does not prevent a writer from adding commits. Do not postpone protection
  until after the first push.
  After any security fix to `release-packaging.yml` or
  `scripts/ci/Invoke-ReleasePackaging.ps1`, update or delete every existing
  `release/*` branch, because each keeps its older copy and stays
  dispatchable.
- **Operator rules:** Run no local engine or editor build against the runner's
  engine root while a release dispatch is queued or running; nothing
  serializes it, and attestation runs only at stage start. A
  `trusted-editor-automation` job that runs between release phases relinks an
  attested engine module, so the next package phase is expected to fail closed
  on host-tools attestation; dispatch again.
- **Evidence:** Issue
  [#226](https://github.com/ShayShimoni/aetheln-online/issues/226), its design,
  and its independent security review.
  `tests/ci/Test-RunnerSchedulingPolicy.Tests.ps1` pins the exact predicate,
  the guard-first step, parity with the scheduled phases, the six uploads, and
  repository-wide allowlists for workflow files, triggers, `runs-on` labels,
  and permissions, each with a mutation case.
  `tests/ci/Invoke-ReleasePackaging.Tests.ps1` covers the guard and evidence
  modes. These pins catch honest drift only; they cannot stop an approved fork
  run or a direct push, which the settings and rules above control. The first
  dispatched run is the operational proof and is recorded on issue #226.
- **Alternatives:** A dispatch trigger on `prototype-quality-gates.yml`
  (rejected: the older branch risk); a reusable workflow or composite action
  shared with the scheduled jobs (rejected: it renames the scheduled checks;
  it also broke the preparation admission rule against job-level `uses:`,
  which issue #229 relaxed on 2026-10-05 for local `./.github/workflows/`
  calls only, so the rename ground alone keeps it rejected); dispatch
  inputs for the version or ref (rejected: an injection surface, and the
  version comes from the commit); tag refs (rejected: tags mark a tested
  commit after release QA); publishing packages as a GitHub pre-release
  (rejected: world-downloadable on a public repository).
- **Consequences:** One more FIFO waiter in `aetheln-engine-runner`, with the
  same bounds. Each run reserves 64 GiB of the shared handoff cap until its
  cleanup request is acted on. The immediate kill switch is disabling the
  workflow; the permanent rollback is reverting it.
- **Owner:** Issue #226.
- **Revisit trigger:** Any package leaves the owner's control (external
  testers, a public download, or a store), a collaborator gains write access, a
  second matching runner is registered, or `hotfix/*` packaging is needed.

### TA-023 - Editor-Only GameTests Module for Project Automation and Content Validation

- **Status:** Accepted
- **Acceptance:** Accepted 2026-10-06 by the delivery lead under the owner's
  delegated authority.
- **Scope:** Responsibility, dependencies, and target membership of the
  `GameTests` module.
- **Decision (2026-10-06):** `GameTests` is the editor-only automation module.
  It hosts the project and module load harness (#85), the GAS foundation,
  combat, and activation-seam tests with their observability assertions (#19),
  and the content-validation commandlet with its tests (#120). Its dependency
  rule, recorded in the `GameTests` row of
  [Technical Architecture](technical-architecture.md#unreal-module-boundaries):
  - Dependencies are private only. The module has no `Public/` folder and
    exports nothing.
  - It may depend on the project modules the Editor target lists, and on the
    engine and engine-plugin modules (runtime, developer, or editor) that its
    tests and the commandlet need.
  - No other module may depend on it.
  - Only `AethelnOnlineEditor.Target.cs` lists it. The Game, Client, and Server
    targets never do.
  - An engine third-party library needs a justification in this entry. The only
    one today is OpenSSL. The content-validation scanner verifies
    caller-supplied SHA-256 provenance of its bounded JSON inputs and of the
    files it binds by hashing their bytes with OpenSSL `SHA256()`. The pinned
    engine has no desktop SHA-256 in `Core`: the only definition of
    `FPlatformMisc::GetSHA256Signature` is the generic one, which fails a
    `checkf` with "No SHA256 Platform implementation". The build rule links
    OpenSSL only on Win64, Mac, and Linux and sets
    `AETHELN_CONTENT_VALIDATION_WITH_OPENSSL`; other platforms fail closed.
- **Context:** PR #219 recorded `GameTests` on 2026-10-03 as project and module
  load tests that depend only on `Core`. Three later changes widened it without
  updating the row:
  - `30f011f` (#120, merged in PR #235) added `AssetRegistry`, `CoreUObject`,
    `DesktopPlatform`, `Engine`, `GameCore`, `Json`, `NavigationSystem`,
    `PhysicsCore`, and OpenSSL for the content-validation commandlet.
  - `cc65f1f` (#19, merged in PR #251) moved the GAS foundation tests out of
    `GameCombat` and added `GameCombat`, `GameplayAbilities`, and
    `GameplayTags`, so the shipping Client and Server targets carry no test
    class.
  - `3f839ed` (#19, merged in PR #261) added `GameNet`, for the activation-seam
    tests that assert rejection telemetry through the observability subsystem
    and its in-memory sink.

  The issue #13 QA on 2026-10-06 found the row stale (AC6, DoD4).
- **Evidence:** On `develop` `f173388`, `Source/GameTests/GameTests.Build.cs`
  lists only private dependencies, `AethelnOnline.uproject` declares the module
  `Type: Editor`, and only `Source/AethelnOnlineEditor.Target.cs` lists it in
  `ExtraModuleNames`. No other `.Build.cs` names `GameTests`. The OpenSSL
  reason is pinned by `tests/content/Invoke-ContentValidationCommand.Tests.ps1`:
  the scanner must call `SHA256(` and must not call `GetSHA256Signature`, and
  the build rule must add the OpenSSL dependency. The engine stub is in
  `Engine/Source/Runtime/Core/Private/GenericPlatform/GenericPlatformMisc.cpp`
  of the pinned source.
- **Target boundary enforcement:** No automated check enforces the `GameTests`
  target boundary today. `scripts/build/Validate-TargetComposition.ps1` reads
  only the Game, Client, and Server targets. It rejects only `GameServer` in a
  Game or Client target and `GameUI` in the Server target. The required CI
  check `target-composition-tests` runs that validator against synthetic
  fixtures only. The repository's real targets are validated only by the
  `target-composition-gate` step of `scripts/build/Build-PackagedArtifacts.ps1`
  during packaging. Until the validator also rejects `GameTests` in the Game,
  Client, and Server targets, review of the target files and this entry
  enforces the boundary.
- **Alternatives:** Keep `GameTests` at `Core` only and move the tests
  elsewhere (rejected: the GAS tests would return to `GameCombat` and ship test
  classes in the Client and Server targets, which `cc65f1f` removed, and the
  commandlet would need another editor module with the same dependencies).
  Per-area test modules, such as separate combat-test and content-validation
  editor modules (deferred: more `.uproject` and Editor-target entries under
  the same boundary rule, with no measured compile or ownership problem today).
  Hash with the engine's `Core` SHA-256 (rejected: the generic stub fails a
  `checkf` on every desktop platform).
- **Consequences:** The `GameTests` row in Technical Architecture states the
  rule, and a Rules bullet keeps the module out of non-Editor targets. A new
  dependency that fits the rule needs no new entry. A new engine third-party
  library does. `docs/gas-foundation.md` refers to the row instead of listing
  dependencies. The content-validation provenance contract
  ([Asset Intake and Content Validation](asset-intake-and-content-validation.md))
  binds exactly `GameCore` then `GameTests` as loaded project modules, so moving
  the commandlet out of `GameTests` changes that contract. Follow-up: extend
  `scripts/build/Validate-TargetComposition.ps1` and its tests to reject
  `GameTests` in the Game, Client, and Server targets.
- **Owner:** Issues #13, #19, #85, and #120.
- **Revisit trigger:** A non-Editor target or another module needs `GameTests`
  code, another engine third-party library is proposed, `GameTests` compile
  time becomes a measured bottleneck for the Editor build or CI editor
  automation, a per-area test split is proposed, or the pinned engine gains a
  desktop SHA-256 in `Core`.

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
| TC-008 | Per-ability GAS prediction eligibility. First candidate (Issue #19, PR P6): predict Hold the Line's activation, its Endurance cost (if it has one), its cooldown, and its own state tag as a self-only reversible path, using the engine's `LocalPredicted` execution policy with the `ServerOnlyTermination` security policy. Every other ability stays server-only until it is added to an approved prediction list with its own evidence, and contact, Guard, damage, control, and death results are never predicted. See [Gameplay Ability System Foundation](gas-foundation.md) | The two-client PIE feel test of the server-only abilities (#19 PR P5); rollback evidence under the supported network profiles for rejection, acceptance, and loss: a rejected prediction removes the predicted cost, cooldown, and tag, and an accepted one converges with no double cost; a compile-level check that the project ASC can reach the engine's batched-activation data | #19 (owner decision after the feel test); #2 and #45 for network profiles | Predicting any ability without tested rollback; predicting a contact, Guard, damage, control, or death result; granting `LocalPredicted` to an ability not on an approved prediction list | The owner's decision, after the P5 feel test, on whether #19 can close without P6. If the owner closes #19 without P6, the row stays Candidate until a later ability requests prediction |

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
