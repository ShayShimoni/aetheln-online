# Prototype and 1.0 Scope Ledger

## Purpose and authority

This ledger is the normative inventory for Issue
[#71](https://github.com/ShayShimoni/aetheln-online/issues/71). It records one
disposition for every material contract cluster represented by Epic #1, its
exported child epics and issues, and the cross-stage owners those items cite.
An issue's mutually dependent acceptance clauses are one contract cluster here;
the issue remains the detailed implementation source.

Product documents govern player-facing behavior, technical documents govern
implementation contracts, roadmaps govern delivery order, and live issues and
Project 1 fields govern work state. Retained sources are limited to the
canonical documents listed in `docs/documentation-index.md`, `README.md`,
`docs/next-steps-mmorpg-prototype.md`, and the supplied live Project 1 export.
Personal todos and non-authoritative research are excluded. Historical material
may identify a contradiction but cannot supply a retained requirement.

Cross-referenced later tickets are included only to preserve ownership or a
revisit gate. Their later-stage implementation scope is not imported into the
prototype or 1.0.

## Dispositions

Every ledger row uses exactly one of these values:

- `canonical fact`
- `accepted architecture`
- `proposed product decision`
- `evidence-gated technical candidate`
- `tuning candidate`
- `legal/privacy dependency`
- `rejected contradiction`
- `deferred follow-up`

## Coverage audit

Each listed board item contributes one material contract cluster and maps to
one ledger row. Issue #71's named conflicts and unresolved decisions are
separate rows so they cannot be silently absorbed into another contract.

| Inventory group | Covered issues | Contract clusters | Ledger IDs |
| --- | --- | ---: | --- |
| Epic #1 and reconciliation | #1, #71 | 2 | P10-001, P10-040 |
| Foundation epic #5 | #5, #2, #13, #14, #15, #16, #59 | 7 | P10-002-P10-008 |
| Combat epic #6 | #6, #4, #17, #18, #19, #20, #21, #60, #61 | 9 | P10-009-P10-017 |
| Cooperative-world epic #7 | #7, #3, #22, #23, #24, #25, #26, #31 | 8 | P10-018-P10-025 |
| Backend epic #10 | #10, #27, #30, #35, #36, #37, #38, #40 | 8 | P10-026-P10-033 |
| Quality and gate owners | #12, #44, #45, #46, #48, #62 | 6 | P10-034-P10-038, P10-054 |
| Explicit later ownership | #50 | 1 | P10-039 |
| Issue #71 conflicts/TBDs | #1, #2, #7, #13, #15, #22-#25, #36, #40, #45, #48, #50, #59, #60, #62, canonical documents | 13 | P10-041-P10-053 |
| **Total** | **41 unique board items** | **54** | **P10-001-P10-054** |

## Exactly-one-disposition ledger

| ID | Source identity | Stage | Material requirement | Disposition | Canonical destination or evidence owner | Blocking or revisit condition |
| --- | --- | --- | --- | --- | --- | --- |
| P10-001 | Epic #1 | Cross-stage | Define the vertical slice, retain confirmed later scope, and resolve the party-size, first-completion, and prototype-entry decisions through #71. | proposed product decision | #1 and #71; future briefs | Blocks #13 readiness until #71 records approved answers or explicit blockers; #48 is not an entry prerequisite. |
| P10-002 | Epic #5 | Prototype Gate | Establish the reproducible UE5.8 C++ foundation, targets, safeguards, build paths, configuration boundaries, and prototype CI. | accepted architecture | `docs/technical-architecture.md`; #5 | Revisit only through a reviewed architecture decision; exact versions remain owned by #13/#15. |
| P10-003 | #2 | Prototype Gate | Compare replication and latency-validation candidates with equivalent packaged scenarios and record measured authority/network evidence. | evidence-gated technical candidate | #2; `docs/architecture-decisions.md` | No candidate, network profile, tick, history, bandwidth, or capacity value is accepted before reviewed evidence. |
| P10-004 | #13 | Prototype Gate | Pin the project identity, exact stable UE5.8 source/toolchains/plugins/configurations, template choice, module dependencies, and initial launch baseline. | evidence-gated technical candidate | #13 and #15 | Blocked by #71 and #13's other prerequisites; #48 occurs after prototype implementation. |
| P10-005 | #14 | Prototype Gate | Preserve Unreal ignore/LFS safeguards and keep generated content untracked. | accepted architecture | `AGENTS.md`, `docs/source-control.md`, #14 | Revisit only when repository asset policy changes through reviewed work. |
| P10-006 | #15 | Prototype Gate | Produce reproducible packaged Windows client and Linux dedicated-server artifacts with provenance and server/client reference boundaries. | evidence-gated technical candidate | #15 | Requires the versions pinned by #13/#15 and packaged verification; no deployment mechanism is selected here. |
| P10-007 | #16 | Prototype Gate | Run repository policy, formatting/static, target compilation, focused automation, packaged smoke, and dependency/secret checks in prototype CI. | accepted architecture | `docs/performance-quality-and-delivery.md`; #16 | Provider, runners, cadence, and retention remain evidence-owned implementation decisions. |
| P10-008 | #59 | Prototype Gate | Retain the published vendor-neutral technical baseline, public contracts, module boundaries, authority model, and evidence gates. | accepted architecture | Canonical technical documents and `docs/architecture-decisions.md` | Change only through a reviewed architecture decision synchronized across affected owners. |
| P10-009 | Epic #6 | Prototype Gate | Deliver responsive server-authoritative third-person action combat with pure free aim, one class, one enemy, death/respawn, and two-player completion. | canonical fact | `docs/game-design-bible.md`, `docs/combat-and-networking-architecture.md`, #6 | Prototype tuning and acceptance evidence remain owned by child issues and #48. |
| P10-010 | #4 | Prototype Gate | Two packaged clients complete one authoritative combat objective with readable feedback and observable rejection behavior. | canonical fact | #4; future prototype brief | Completion semantics remain blocked by P10-042 until #1/#71 approves the first PvE completion condition. |
| P10-011 | #17 | Prototype Gate | Implement predicted/reconciled third-person movement, camera, sprint, and bounded free-aim input without selected targets. | accepted architecture | `docs/combat-and-networking-architecture.md`; #17 | Exact movement and network bounds require implementation evidence. |
| P10-012 | #18 | Prototype Gate | Implement a server-owned dodge cost/cooldown and invulnerability window with deterministic invalid-request handling. | accepted architecture | `docs/combat-and-networking-architecture.md`; #18 | Resource identity and numeric window/distance/cooldown values remain TBD. |
| P10-013 | #19 | Prototype Gate | Use PlayerState-owned player GAS, authoritative-pawn AI GAS, server-owned effects, versioned activation, and reversible prediction only. | accepted architecture | `docs/combat-and-networking-architecture.md`; #19 | Resource identity, costs, cooldowns, and content values remain data-driven TBDs. |
| P10-014 | #20 | Prototype Gate | Provide one readable enemy with a server-owned attack timeline, authored volumes, deterministic contact, and one ephemeral completion result. | accepted architecture | `docs/combat-and-networking-architecture.md`; #20 | Durable rewards remain #30; completion semantics remain subject to P10-042. |
| P10-015 | #21 | Prototype Gate | Server-owned health determines death; replicated death/respawn/reconnect clears stale action state and cannot duplicate completion. | accepted architecture | `docs/combat-and-networking-architecture.md`; #21 | Exact respawn timing and restored values remain tuning candidates. |
| P10-016 | #60 | Prototype Gate | Implement the public `CombatActivation` request/record path, server timeline, authored volumes, already-hit state, three-hit chain, and deterministic outcomes. | accepted architecture | `docs/combat-and-networking-architecture.md`; #60 | Contract redesign requires synchronized architecture and ticket review; timings, ranges, costs, and damage stay TBD. |
| P10-017 | #61 | Prototype Gate | Present authoritative or explicitly predicted health, resource, cooldown, objective, correction, rejection, death, and completion feedback without UI authority. | accepted architecture | `docs/technical-architecture.md`; #61 | Resource identity and unresolved visual/accessibility targets remain TBD. |
| P10-018 | Epic #7 | 1.0 Cooperative Slice | Deliver a safe hub, outdoor objective, Hollow Choir dungeon, controlled travel, authoritative completion/reward, and safe return as distinct process roles. | canonical fact | `docs/world-and-settlements.md`, `docs/world-runtime-and-building.md`, #7 | Party size and first-completion condition must be approved through #1/#71 before dependent scope is implementation-ready. |
| P10-019 | #3 | 1.0 Cooperative Slice | Create one minimal account-owned character and enter the safe hub through replay-safe admission and current character authority. | canonical fact | #3; `docs/security-and-operations.md` | Exact presentation defaults and naming policy remain owned implementation/product decisions. |
| P10-020 | #22 | 1.0 Cooperative Slice | Build a representative safe mixed-city hub with stable identities and fail-closed, server-authoritative sanctuary policy. | canonical fact | `docs/world-and-settlements.md`, `docs/world-runtime-and-building.md`, #22 | Final faction-world city placement and population targets remain deferred/evidence-gated. |
| P10-021 | #23 | 1.0 Cooperative Slice | Build one controlled outdoor zone and authoritative objective with stable result/reward events, retries, and no faction-PvP flag. | canonical fact | #23; `docs/world-runtime-and-building.md` | Glasswake Reach classification and World Partition adoption remain owned follow-up/evidence decisions. |
| P10-022 | #24 | 1.0 Cooperative Slice | Build the Hollow Choir dungeon and Sevrin Vale encounter with server-owned combat, lifecycle, result, and per-character reward-event identity. | canonical fact | `docs/world-and-settlements.md`; #24 | First-completion condition remains blocked by P10-042; generated items remain 1.1. |
| P10-023 | #25 | 1.0 Cooperative Slice | Transfer parties between hub, outdoor, and dungeon roles using checkpoint, reservation, admission, fencing, source release, and idempotent recovery. | accepted architecture | `docs/world-runtime-and-building.md`; #25 | Allocator/provider and numeric timeout/capacity values remain evidence-owned. |
| P10-024 | #26 | 1.0 Cooperative Slice | Show one stable activity result and recorded 1.0 progress/currency receipt, then return through the controlled transfer path. | canonical fact | #26 and #30 | Exact progress/currency identities require explicit approval; UI repetition cannot grant value. |
| P10-025 | #31 | 1.0 Cooperative Slice | Provide authoritative, versioned, idempotent party formation and recovery without deciding future cross-faction grouping. | canonical fact | #31 | Maximum/target party size remains blocked by P10-041; vendor choice remains #36. |
| P10-026 | Epic #10 | Cross-stage | Establish staged backend, persistence, security, observability, restore, and operations foundations without a prototype persistent-account dependency. | accepted architecture | Canonical security/persistence documents; #10 | Provider choices and production operating targets require owning evidence and later review. |
| P10-027 | #27 | 1.0 Cooperative Slice | Persist identity, required appearance, approved slice progress, bounded integer currency, checkpoint/location, versions, leases, commands, audit, ledger, outbox, and reconciliation records. | accepted architecture | `docs/progression-and-persistence-architecture.md`; #27 | Exact progress/currency identities are blocking TBDs; Character Level remains #50/1.1. |
| P10-028 | #30 | 1.0 Cooperative Slice | Grant progress/currency once per RewardEventId and CharacterId through one atomic, auditable receipt/ledger/outbox transaction. | accepted architecture | `docs/progression-and-persistence-architecture.md`; #30 | Generated item state remains absent until 1.1; retention is not selected here. |
| P10-029 | #35 | 1.0 Cooperative Slice | Authenticate accounts, manage sessions, and issue single-use destination-bound PlayerAdmission without exposing bearer material. | accepted architecture | `docs/security-and-operations.md`; #35 | Identity provider remains unselected until #36 records an accepted decision. |
| P10-030 | #36 | 1.0 Cooperative Slice | Compare identity, backend, transactional data, messaging/cache, allocation/orchestration, and hosting candidates through a vendor-neutral thin path. | evidence-gated technical candidate | #36; `docs/architecture-decisions.md` | No vendor is selected by examples or research; acceptance requires reproducible evidence and an ADR. |
| P10-031 | #37 | 1.0 Cooperative Slice | Implement vendor-neutral CharacterAuthorityLease and fenced, versioned, idempotent PersistentCommand boundaries. | accepted architecture | `docs/progression-and-persistence-architecture.md`; #37 | Transport, serialization, database layout, and vendor SDKs remain adapter decisions. |
| P10-032 | #38 | Prototype Gate / 1.0 | Establish structured, redacted prototype observability and explicit 1.0 admission/persistence/transfer extensions without changing gameplay truth. | accepted architecture | `docs/security-and-operations.md`; #38 | Retention and vendor choices require privacy/operations review and evidence. |
| P10-033 | #40 | Prototype Gate | Produce the ranked staged threat/data-flow model, abuse cases, controls, tests, telemetry, owners, and residual-risk triggers. | evidence-gated technical candidate | #40 | High-risk exceptions require reviewed evidence; legal, vendor, tuning, and capacity conclusions remain outside this task. |
| P10-034 | Epic #12 | Cross-stage | Establish reproducible staged automation, performance, playtest, and evidence-based go/no-go gates. | accepted architecture | `docs/performance-quality-and-delivery.md`; #12 | Each stage requires measured or explicitly TBD budgets and a recorded #48 decision. |
| P10-035 | #44 | Prototype Gate | Automate packaged two-client/server lifecycle, authority, invalid-command, and reusable network-condition scenarios with machine-readable evidence. | accepted architecture | #44 | Exact profiles and thresholds require #2/#45 evidence and #48 review. |
| P10-036 | #45 | Prototype Gate | Measure client, server, replication, bandwidth, correction, and failure behavior with fully identified scenarios and approval status. | evidence-gated technical candidate | #45 | Hypotheses such as hardware, resolution, population, tick, and capacity are non-canonical until reviewed. |
| P10-037 | #48 | Cross-stage | Record evidence, participants, pass/no-go/exception, risk ownership, and follow-ups for each stage exit. | accepted architecture | `docs/performance-quality-and-delivery.md`; #48 | Prototype evaluation occurs after implementation and blocks advancement to 1.0, not entry into #13. |
| P10-038 | #62 | 1.0 Cooperative Slice | Demonstrate isolated backup restore and authoritative reconciliation for the implemented 1.0 data set without silent repair. | evidence-gated technical candidate | #62 | RPO, RTO, retention, scale, and provider mechanics remain TBD until evidence and accountable approval. |
| P10-039 | #50 | 1.1 Character Development | Add permanent Character Level and XP separately from Ember Rank through validated server events and versioned data. | deferred follow-up | #50; `docs/progression-loot-and-skein.md` | Revisit in 1.1; no Character Levels 1-3 or other level range is part of 1.0. |
| P10-040 | #71 | Cross-stage | Publish and reconcile separate prototype and 1.0 contracts from canonical documents and live board state, excluding personal todos. | proposed product decision | #71; future briefs, ledger, artifacts, index, and roadmap reconciliation | #13 can become a candidate only after #71 and its other prerequisites; external synchronization remains control-plane work. |
| P10-041 | #1 required decision; #31/#32 references | 1.0 Cooperative Slice | Target party size. | proposed product decision | #1 and #71; future prototype/1.0 briefs | **Blocking TBD:** approval must name the rule and canonical destination before party-size-dependent implementation is ready. |
| P10-042 | #1 required decision; #4/#20/#23/#24 references | Prototype / 1.0 | First PvE encounter completion condition. | proposed product decision | #1 and #71; future prototype/1.0 briefs | **Blocking TBD:** approve the authoritative completion condition and affected stage scope before dependent objectives are implementation-ready. |
| P10-043 | Issue #71 conflict; roadmap and #18/#19/#61 | Prototype Gate | Replace proposed fixed Health/Guard or current mana wording with an approved prototype resource identity. | proposed product decision | #1/#71; future prototype brief, then #18/#19/#61 | **Blocking TBD:** retain generic `prototype combat resource`; do not canonize Guard, mana, or stamina until reviewed. |
| P10-044 | Issue #71 conflict; README/roadmap and #13 | Prototype Gate | Choose project template and Starter Content policy. | accepted project decision | #13 consuming the reviewed #71 prototype brief | Resolved by #13: Blank C++ with no Starter Content was approved before project creation, then verified through project generation, Editor build, and starter-map launch. |
| P10-045 | Issue #71 conflict; #27/#50 and progression canon | 1.0 / 1.1 | Proposed 1.0 Character Levels 1-3. | rejected contradiction | #50 and canonical progression documents | Rejected for 1.0 because Character Level implementation is owned by 1.1/#50; revisit only through a synchronized product decision. |
| P10-046 | Issue #71 conflict; #7/#22-#25 and ADR runtime topology | 1.0 Cooperative Slice | Proposed two-role private runtime. | rejected contradiction | #7, #22-#25, `docs/world-runtime-and-building.md`, ADR accepted topology | Rejected because 1.0 retains distinct hub, outdoor, and on-demand dungeon roles; revisit only through synchronized architecture review. |
| P10-047 | Issue #71 conflict; combat architecture and #60 | Prototype Gate | Proposed `CombatIntent` request and server-record `CombatActivation` split. | rejected contradiction | `docs/combat-and-networking-architecture.md`; #60 | Rejected because the accepted public contract remains `CombatActivation`; reconsider only through a synchronized contract/architecture decision. |
| P10-048 | Issue #71 conflict; technical architecture/ADR and #13 | Prototype Gate | Proposed `GamePresentation` ownership and delayed `GameNet`. | rejected contradiction | `docs/technical-architecture.md`, ADR module decision, #13 | Rejected because the accepted baseline is `GameCore`, `GameCombat`, `GameUI`, `GameNet`, and server-only `GameServer`; revisit through ADR review. |
| P10-049 | Issue #71 conflict; canonical lore documents and #24/#54 | Cross-stage | Hollow Choirhouse, Hollow Choir, Ashen Choir, Lucent Choir, and Concord terminology or new lore. | deferred follow-up | Canonical lore documents; #24 for the dungeon and #54 for unresolved faction-world lore | Preserve each canonical term's existing meaning; do not conflate names or add lore. Any ambiguity blocks the affected content ticket, not unrelated prototype work. |
| P10-050 | Issue #71 conflict; AGENTS.md and canonical product documents | Cross-stage | Faction and Order working-name status. Under Issue #104, Crowned Ledger and Hundred Witnesses supersede Dawn Concordat and Unbound Flame as provisional faction display names, and Oathscar supersedes Skeinblade as the active initial Order working label. | deferred follow-up | Canonical product documents; final faction naming owned by #54 | Treat all recorded working names as non-final; do not invent a rename deadline or final replacement. Historical evidence keeps the earlier labels unchanged. |
| P10-051 | Issue #71 conflict; #13/#15/#36 | Prototype / 1.0 | Exact engine revision, compilers/SDKs/toolchains, plugins, backend/database/hosting stack, and deployment mechanics. | evidence-gated technical candidate | #13, #15, and #36; accepted ADR when evidence exists | Remains TBD until each owner records reproducible evidence and approval; examples do not select a tool or vendor. |
| P10-052 | Issue #71 conflict; #2/#40/#45/#48/#62 and related tickets | Cross-stage | Exact combat values, network profiles, tick/performance/hardware targets, rewards, retention, capacity, schedules, and go/no-go percentages. | tuning candidate | #2, #40, #45, #48, #62, and the applicable feature owner | Remains TBD until measured or explicitly approved with scenario, owner, evidence, and revisit trigger. |
| P10-053 | Issue #71 conflict; security/operations canon | Cross-stage | Legal/privacy conclusions, jurisdictions, processing locations, access, retention, and regional requirements. | legal/privacy dependency | Qualified legal/privacy review; #40 and applicable service/data owner | No planning prose is legal approval; blocks collection or operation requiring an unresolved policy and revisits when jurisdiction, data, or provider changes. |
| P10-054 | #46 | 1.0 Cooperative Slice | Produce controlled external-test distribution with access control, identified build provenance, privacy guidance, update and rollback behavior, uninstall behavior, and clean-machine install/run validation. | accepted architecture | #46; `docs/performance-quality-and-delivery.md`; `docs/security-and-operations.md` | The 1.0 external playtest is not ready until the implemented distribution path has recorded lifecycle and clean-machine evidence; provider and delivery mechanics remain evidence-owned. |

## Owned TBD register

| Decision | Current state | Accountable ticket | Canonical destination | Blocking effect | Evidence or review needed | Revisit trigger |
| --- | --- | --- | --- | --- | --- | --- |
| Target party size | Blocking `TBD` | #1/#71 | Prototype and 1.0 briefs | Party-size-dependent implementation and estimation are not ready. | Reviewed product decision covering formation, eligibility, travel, and content. | Before #1/#71 closes or a dependent ticket becomes ready. |
| First PvE completion condition | Blocking `TBD` | #1/#71 | Prototype and 1.0 briefs | The terminal objective contract cannot be finalized. | Reviewed product decision identifying the authoritative result and stage boundary. | Before #4/#20/#23/#24 completion work becomes ready. |
| Prototype combat resource identity | Blocking `TBD` | #1/#71 | Prototype brief; then #18/#19/#61 | Attribute, UI, cost, and recovery wording cannot be finalized. | Product review reconciling Health/Guard and mana-or-stamina wording. | Before GAS/HUD data contracts are implemented. |
| Template and Starter Content | Resolved: Blank C++, no Starter Content | #13 consuming #71 | Prototype brief and #13 record | No remaining bootstrap block. | Approval before project creation plus successful project generation, Editor build, and starter-map launch. | Revisit only through a reviewed project-content decision. |
| Exact 1.0 progress and currency identities | Blocking `TBD` | #27/#30 with #1/#71 product approval | 1.0 brief and persistence/reward data | Reward/persistence schemas cannot finalize these fields. | Product decision plus transaction/schema review. | Before #27/#30 schema implementation. |
| Toolchains, plugins, vendors, and deployment mechanics | Evidence-gated `TBD` | #13/#15/#36 | Architecture registry and owning tickets | Blocks only the implementation depending on the unresolved selection. | Reproducible spike/build evidence and accepted ADR. | At each owning ticket's decision gate. |
| Numeric tuning, budgets, capacity, retention, schedules, and gate thresholds | Evidence/product-gated `TBD` | #2/#40/#45/#48/#62 and feature owner | Versioned data, evidence record, or gate decision | Blocks claims or implementations requiring an approved value, not unrelated scaffolding. | Representative measurements or accountable product review. | When representative implementation/evidence exists or assumptions change. |
| Legal/privacy and regional-processing policy | Qualified-review dependency | #40 plus applicable data/service owner | Security/privacy records and affected ticket | Blocks collection or operation that requires an unresolved legal policy. | Data inventory, jurisdiction/provider facts, qualified review, and accountable approval. | New data class, jurisdiction, provider, use, or retention purpose. |

## Entry and exit boundary

Completion of #71 supplies the reviewed documentation prerequisite for #13,
subject to #13's other prerequisites and its owned evidence decisions. It does
not assert that #13 is ready while either blocking product TBD remains relevant
to its work. Issue #48 is the downstream evaluator of the implemented and
verified prototype. Its Prototype Gate decision controls advancement into the
1.0 cooperative slice; it is not a prerequisite for starting #13.
