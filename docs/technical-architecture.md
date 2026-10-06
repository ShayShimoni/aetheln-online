# Aetheln Online Technical Architecture

## Document Status

This document is the canonical technical overview for Aetheln Online. It governs
implementation structure and system boundaries. The
[Game Design Bible](game-design-bible.md) and specialized product documents
govern player-facing behavior; this document explains how software must preserve
those rules.

Focused technical specifications define the details:

- [Combat and Networking Architecture](combat-and-networking-architecture.md)
- [World Runtime and Building](world-runtime-and-building.md)
- [Progression and Persistence Architecture](progression-and-persistence-architecture.md)
- [Security and Operations](security-and-operations.md)
- [Performance, Quality, and Delivery](performance-quality-and-delivery.md)
- [Architecture Decisions](architecture-decisions.md)

The documents establish boundaries and evidence gates, not final tuning. Values
marked `TBD`, candidate technologies, and unmeasured capacity hypotheses remain
unresolved.

## Architecture Goals

- Preserve responsive, pure-free-aim action combat while the server owns every
  consequential result.
- Prove movement, combat feel, latency tolerance, authority, observability, and
  build repeatability before expanding world or persistence scope.
- Separate gameplay presentation from authoritative simulation and durable
  state.
- Keep backend, infrastructure, identity, database, cache, messaging, hosting,
  orchestration, and anti-cheat integrations behind vendor-neutral boundaries.
- Make durable mutations transactional, idempotent, auditable, and safe when a
  process crashes or a request is retried.
- Keep regions, layers, instances, sanctuaries, and invasion spaces explicit so
  content streaming is never confused with server distribution.
- Require measured evidence before approving replication technology, server
  tick, bandwidth, population, recovery, or operating-cost assumptions.

## System Context

```text
Untrusted player device
    |
    | short-lived admission and gameplay commands
    v
Authoritative Unreal game-server process
    |
    | scoped service identity and validated commands
    v
Backend service boundary
    |-- identity and session admission
    |-- character and progression ownership
    |-- reward and economy ownership
    |-- world allocation and regional transfer
    `-- administration and support
    |
    | transactional state, outbox events, operational telemetry
    v
Vendor-neutral data, messaging, analytics, and hosting adapters
```

The player device is always untrusted. A game server is trusted to simulate its
assigned instance only while it holds valid workload identity and character
authority leases. Backend services are trusted only for their declared
capability. Analytics and observability consumers never grant gameplay state.

## Trust Zones

| Zone | Trust level | Allowed responsibility | Prohibited authority |
| --- | --- | --- | --- |
| Player client | Untrusted | Input, local prediction, presentation, requests | Hits, damage, policy, rewards, persistence |
| Edge and admission | Hostile-facing | Authentication handoff, throttling, routing, single-use admission | Character or economy mutation |
| Game server | Scoped authority | Simulation for assigned world instances and connected characters | Cross-instance or durable mutation without lease and service validation |
| Gameplay backend | Service-scoped | Durable character, reward, transfer, and policy commands | Undeclared cross-service access |
| Data systems | Restricted | Transactional storage, outbox delivery, backups | Direct player access |
| Analytics and observability | Non-authoritative | Metrics, traces, audit review, detection | Gameplay decisions or reward grants |
| Administration plane | Highly restricted | Approved support and operational actions | Unattributed or unaudited grants |

Every boundary validates identity, authorization, version, replay protection,
resource limits, and input shape. Network location alone never establishes
trust.

## Process Topology

### Prototype

- One dedicated arena server process.
- Two Windows x64 clients for the required multiplayer path.
- Local or development-only supporting services when a spike requires them.
- No persistent account, inventory, or production hosting dependency.

### 1.0 Cooperative Vertical Slice

- Safe-hub server process.
- Outdoor-objective server process.
- On-demand cooperative-dungeon server processes.
- Vendor-neutral admission, character, progression, currency, allocation, and
  transfer boundaries.
- Short controlled travel transitions between authoritative processes.

### 1.1 Character Development

- The 1.0 topology extended with item inventory, equipment, Skein data, reward
  generation, and migration/reconciliation operations.
- Existing automation, rejection telemetry, and performance instrumentation are
  expanded for the larger persistent state.

### 2.0 Faction Frontier

- Protected faction-start processes.
- Mixed-region processes with one or more measured regional layers.
- Neutral-city sanctuary subzones governed by server-authoritative territory
  policy.
- `Faction` changes from `Unassigned` through the approved one-time selection
  flow; Doctrine becomes available only after that choice.

### 2.1 Faction War

- Capital and invasion gameplay use explicitly isolated military/invasion
  subzones.
- Beginner districts and essential progression services remain separate
  topology and authority domains.
- Invasion state coordinates eligible objectives and temporary consequences
  without granting access to protected beginner content.

These stages are delivery boundaries, not promises that each process maps
one-to-one to a physical host. Allocation and orchestration remain vendor
candidates until [Issue #36](https://github.com/ShayShimoni/aetheln-online/issues/36)
records evidence and an accepted decision.

## Platform and Build Baseline

- Supported player target: Windows x64 client.
- Supported authoritative target: Linux x86-64 dedicated server.
- Engine family: Unreal Engine 5.8 with C++ project support.
- Issues [#13](https://github.com/ShayShimoni/aetheln-online/issues/13) and
  [#15](https://github.com/ShayShimoni/aetheln-online/issues/15) must pin the
  exact engine source revision, Visual Studio/compiler version, Windows SDK,
  Linux cross-toolchain, required plugins, and supported build configurations.
- A packaged server and packaged clients, not editor-only success, are required
  evidence for the prototype gate.

Epic's current
[dedicated-server workflow](https://dev.epicgames.com/documentation/en-us/unreal-engine/setting-up-dedicated-servers-in-unreal-engine)
requires a C++ project and a source build of Unreal Engine. The repository must
record the exact reproducible inputs rather than relying on an unversioned
launcher installation.

## Unreal Module Boundaries

| Module | Responsibility | May depend on | Must not own |
| --- | --- | --- | --- |
| `GameCore` | Framework types, shared identifiers, tags, policy interfaces, data definitions | Unreal runtime foundations | Combat implementation, vendor SDKs, UI |
| `GameCombat` | GAS abilities/effects, attack timelines, combat traces, health, death | `GameCore`, required GAS/runtime modules; private `GameNet` dependency for the structured observability service only ([TA-021](architecture-decisions.md#ta-021---private-gamecombat-dependency-on-the-gamenet-observability-service)) | Persistence, sessions, vendor SDKs |
| `GameUI` | CommonUI screens, HUD, presentation view models | `GameCore`; presentation-safe combat interfaces | Authority decisions, direct service or database access |
| `GameNet` | Sessions, admission, transfer client/server adapters, protocol boundaries, structured observability service | `GameCore`; vendor-neutral interfaces | Combat truth, durable state ownership |
| `GameServer` | Dedicated-server composition, allocation hooks, service adapters, server-only orchestration | `GameCore`, `GameCombat`, `GameNet` | Client presentation assets |
| `GameTests` | Editor-only automation module: project and module load tests (#85), GAS, combat, and observability tests (#19), and the content-validation commandlet and its tests (#120). Module type `Editor`, listed only by the Editor target ([TA-023](architecture-decisions.md#ta-023---editor-only-gametests-module-for-project-automation-and-content-validation)) | Private dependencies only: project modules the Editor target lists, and the engine and engine-plugin modules (runtime, developer, or editor) that its tests and commandlet need. An engine third-party library needs a TA-023 justification; today only OpenSSL, for SHA-256 provenance checks | Gameplay, runtime, or server code; anything a game, client, or server target loads |

Rules:

- Shared modules expose narrow interfaces and data contracts; they do not import
  a vendor SDK to avoid an adapter.
- Vendor SDKs live in dedicated adapter modules or plugins selected by an
  accepted architecture decision.
- `GameServer` is excluded from client targets.
- `GameTests` is listed only by the Editor target, and no other module depends
  on it.
- Server builds must not acquire hard references to client-only UI, audio,
  Niagara, camera, or high-detail art assets.
- Gameplay data is versioned and loaded through Unreal's Asset Manager where
  appropriate; authoritative code validates every referenced content version.
- Circular module dependencies are prohibited.

## State Ownership

| State | Authoritative owner | Durable? | Client behavior |
| --- | --- | --- | --- |
| Input intent | Current client connection | No | Produces bounded commands |
| Movement simulation | Current game server through CMC | No | Predicts and reconciles |
| Ability activation state | Current game server through GAS and attack timeline | No | May predict supported reversible presentation |
| Hits, damage, control, death | Current game server | No, except resulting durable commands | Displays replicated result |
| Territory and sanctuary policy | Versioned world-policy owner, enforced by game server | Policy is durable | Displays current policy |
| Identity and admission | Identity/session boundary | Yes | Presents credential once |
| Character authority | Character owner through a fenced lease | Yes | No direct control |
| Permanent progression and currency | Logical persistence/economy owner | Yes | Requests validated command |
| Inventory and equipment | Logical persistence/economy owner from 1.1 | Yes | Requests validated command |
| Reward outcome | Logical persistence/economy owner | Yes | Displays recorded receipt |
| Analytics and telemetry | Observability pipeline | Yes by retention policy | Emits bounded, redacted events |

An in-memory game-server result is not durable merely because it replicated to
a client. Durable changes complete only when their owning service commits the
validated command.

## Character Data Separation

The durable model keeps these concerns independently versioned:

- Identity and account linkage.
- Appearance and presentation choices.
- Permanent Character Level and experience.
- Seasonal Ember Rank.
- Class, learned abilities, and Skein loadout.
- Faction membership and Doctrine.
- Inventory and equipment.
- Cosmetics.
- Ephemeral session, admission, instance, and transfer state.

Before the 2.0 faction stage, persistent characters use
`Faction = Unassigned`. Doctrine is unavailable until the approved one-time
faction selection. No class or combat record may embed appearance, race, sex, or
faction as an implicit property.

## Public Contract Principles

The architecture defines semantic contracts without selecting serialization,
transport, database layout, or vendor APIs. Every contract includes:

- Stable identity and correlation.
- Schema or protocol version.
- Issuer and authorized consumer.
- Explicit expiry or terminal state where relevant.
- Validation and replay behavior.
- Observable rejection reasons safe for the caller.
- Internal audit detail that does not expose secrets.

The initial contract set is:

- `CombatActivation`
- `PlayerAdmission`
- `CharacterAuthorityLease`
- `PersistentCommand`
- `RewardReceipt`
- `RegionTransfer`
- `TerritoryPolicy`

Their required fields and invariants are defined in the focused specifications.
Compatibility rules are defined before any contract crosses a deployed process
boundary.

## Deployment and Configuration

The environment strategy remains:

- `local` for contributor machines and developer-specific services.
- `development` for shared multiplayer/backend integration.
- `staging` only when external playtests or release candidates require it.
- `production` only when a public service exists.

`QA` is a work status, not an environment. Endpoints, credentials, data, logs,
and workload identities are isolated between environments. Only redacted
examples and schemas are committed. Deployment topology must support rollback
of application code and forward-safe handling of already committed data.

## Architecture Evidence Gates

| Gate | Evidence required | Owning work |
| --- | --- | --- |
| Engine/build baseline | Pinned toolchain; packaged Windows clients and Linux server | #13, #15 |
| Movement/combat authority | Two clients; invalid-command rejection; representative and harsh network profiles | #2, #44 |
| Replication selection | Same actor mix measured with generic push model, Replication Graph, and Iris | #2, #45 |
| Latency validation | Present-time and bounded-rewind comparison for melee, projectiles, block, and dodge | #2 |
| Backend selection | Working thin path, cost/complexity/security/exit evidence, ADR | #36 |
| Threat controls | Ranked threat model and observable representative rejections | #40 |
| Persistence safety | Retry/crash tests, fencing, reconciliation, and restore evidence | #36, #44 |
| Performance budgets | Reproducible client/server/network captures; modeled values labeled | #45 |
| Stage advancement | Evidence owner, review date, decision, and exceptions | #48 |

The complete milestone criteria live in
[Performance, Quality, and Delivery](performance-quality-and-delivery.md).

## Decision Management

[Architecture Decisions](architecture-decisions.md) is the canonical registry.
An accepted decision names its scope, rationale, owning issue, rejected
alternatives, and revisit trigger. A candidate is not an implementation choice.

The following must remain evidence-gated:

- Generic push-model replication, Replication Graph, or Iris.
- Present-time validation or bounded rewind by combat action type.
- Identity, backend framework, database, cache/message system, hosting, and
  orchestration vendors.
- World Partition adoption for each outdoor map.
- Server tick, per-instance population, layer rules, and bandwidth budgets.
- Production recovery point and recovery time objectives.
- Anti-cheat vendors and platform services.

## Failure Principles

- Fail closed for authorization, territory policy, stale leases, incompatible
  versions, and invalid persistent commands.
- Make retries safe through idempotency and terminal-state records.
- Prefer bounded degradation for analytics, cosmetics, and non-authoritative
  presentation; their failure must not alter gameplay truth.
- Reject new admissions when capacity or dependencies cannot safely serve them.
- Preserve an auditable path for authoritative rejection, reward, transfer, and
  administrative events.
- Never silently repair economy state from analytics data.

## Open Evidence Questions

- Exact relationship between Character Level and Doctrine prerequisites.
- Final faction selection and faction-change rules.
- Final server tick, regional/layer population, and bandwidth targets.
- Replication implementation and latency-compensation policy.
- Backend and infrastructure vendors.
- Regional boundary layout and Glasswake Reach ownership.
- Production backup frequency, retention, RPO, and RTO.
- Cross-faction grouping and capital-invasion scheduling/capacity.

These questions remain open until their product owner or evidence issue records
an accepted decision.
