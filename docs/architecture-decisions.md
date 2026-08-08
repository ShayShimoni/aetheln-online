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
  same-repository pull requests may run the supported-target compile gate. A
  packaged-smoke gate runs at `02:00 UTC` from the protected default branch
  `main`, and the repository owner may request the same gate manually.
- **Rationale:** The pinned Unreal source build, Visual Studio and Linux
  cross-toolchains, WSL topology, disk capacity, and local build paths are not
  available on ordinary GitHub-hosted runners. Repository scope and explicit
  trust predicates bound unreviewed code execution on the owner's machine.
- **Owner/evidence:** Issue #16 and the reviewed
  `.github/workflows/prototype-quality-gates.yml`,
  `scripts/ci/Invoke-EngineRunnerGate.ps1`, and focused fixture tests. This is
  implementation evidence only: zero self-hosted runners are currently
  registered, so live compile, scheduled smoke, manual smoke, and
  representative-branch acceptance evidence do not yet exist.
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