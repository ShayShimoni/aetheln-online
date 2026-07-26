# World Runtime and Building

## Document Status

This document is the canonical technical specification for world identifiers,
server processes, regions, layers, instances, territory policy, regional
transfer, Unreal world-building features, navigation, cooking, and asset
validation.

Player-facing territory and settlement rules remain governed by
[World and Settlements](world-and-settlements.md).

## World Runtime Principles

- A server process has authority only for its assigned instances and policy
  versions.
- World Partition streams content inside an Unreal map. It is not a mechanism
  for distributing one world simulation across servers.
- Regional transitions use explicit controlled travel and authority transfer.
- World identifiers are stable data identities, not display names or map
  package paths.
- Territory and sanctuary decisions are server authoritative.
- The most specific applicable policy wins, with protection taking precedence
  over a containing region's hostility.
- Capital military/invasion spaces and beginner districts are separate
  topology and authority domains.
- World-building features are adopted per map only after measured editor,
  runtime, cook, navigation, and server evidence.

## Stable World Identities

Every runtime or persistent reference uses stable, versioned identifiers for:

| Identity | Meaning |
| --- | --- |
| `RegionId` | Operational and travel boundary containing one or more maps or instances |
| `TerritoryId` | Ownership and faction-conflict boundary |
| `SubzoneId` | More-specific policy boundary inside a territory |
| `SettlementId` | Logical city, capital, outpost, or service location |
| `LayerId` | Capacity-managed copy of eligible regional content |
| `InstanceId` | One authoritative runtime simulation |
| `ObjectiveId` | Stable faction, PvE, invasion, or world objective |
| `PolicyId` | Territory-policy record identity |
| `PolicyVersion` | Immutable version used for an authoritative decision |

Display names, working faction names, map names, actor paths, coordinates, and
server addresses are not durable identities. A content rename must not orphan
character location, rewards, objectives, or audit history.

Hierarchical containment and valid transitions are data driven and validated.
An identifier alone does not prove the caller is inside or authorized for that
world object.

## Staged Runtime Topology

### Prototype

One arena process owns:

- Greybox arena.
- Two player connections.
- Representative enemy.
- Movement, combat, death, and respawn.
- Required rejection and performance telemetry.

There is no regional handoff or persistent open world in this stage.

### 1.0 Cooperative Vertical Slice

Separate authoritative process roles support:

- Safe hub.
- Outdoor objective zone.
- On-demand cooperative dungeon.

Travel uses a short controlled transition. A process may host more than one
compatible instance only if measurement and isolation tests approve it.

### 2.0 Faction Frontier

- Protected starting-region instances.
- Mixed-region layers created by measured capacity rules.
- Neutral settlements represented as sanctuary subzones within or adjacent to
  mixed regions.
- Layer placement considers faction population without inventing hidden combat
  bonuses.

Final layer ratios, player capacity, and placement incentives remain `TBD`.

### 2.1 Faction War

- Invasion coordination publishes the eligible campaign, objective, and policy
  version to participating military/invasion instances.
- Capital military routes do not share topology or authority access with
  protected beginner districts.
- Essential services remain reachable through protected domains even while
  military objectives change state.
- Invasion consequences are temporary and idempotently recoverable.

The physical host, allocator, and orchestration products remain candidates
owned by [Issue #36](https://github.com/ShayShimoni/aetheln-online/issues/36).

## TerritoryPolicy Contract

`TerritoryPolicy` is the immutable, versioned policy a server uses for a world
decision.

| Field | Requirement |
| --- | --- |
| `PolicyId` and `PolicyVersion` | Stable identity and exact immutable version |
| World hierarchy | `RegionId`, `TerritoryId`, optional `SubzoneId`, `SettlementId`, and objective scope |
| Ownership | Neutral, faction-owned, or other explicit canonical ownership state |
| PvP policy | Protected, mandatory faction PvP, or other future explicit state |
| Sanctuary policy | Hostile activation/effect restrictions and boundary behavior |
| Invasion policy | Eligible routes, actors, objectives, and temporary states |
| Respawn policy | Protected spawn, reinforcement, and re-entry rules |
| Banking policy | Eligible services and transactional boundaries |
| Resource-risk policy | Eligible unbanked resource categories; values remain tuning data |
| Effective interval | Activation and retirement metadata |
| Schema version | Compatibility version |

The server records the policy version with consequential hostile-action,
objective, banking, contested-resource, and reward decisions. A live policy
change does not rewrite historical decisions.

## Policy Resolution and Sanctuary Precedence

Policy resolution:

1. Resolve authoritative source and target world locations.
2. Load the matching region and territory policy.
3. Apply matching subzone, settlement, objective, respawn, or invasion policy
   from least to most specific.
4. Let an explicit protection rule override a containing mandatory-PvP rule.
5. Reject when required policy data is missing, incompatible, or ambiguous.
6. Record the effective policy identity and version.

Mixed-region faction PvP is mandatory except inside explicit
server-authoritative sanctuary or protected subzones. This is not a player flag
and cannot be disabled by client preference.

A hostile action is rejected when either its authoritative source or intended
target is protected. The same check applies:

- At ability activation.
- At trace, projectile, or persistent-area contact.
- At Gameplay Effect application and periodic ticks.
- When a summon, pet, trap, or proxy acts.
- Before hostile forced movement, pull, knockback, displacement, or terrain
  interaction.
- When a source, target, or persistent effect crosses a boundary after
  activation.

A projectile fired outside a sanctuary does not gain permission to damage a
protected target inside it. An area created before a policy change revalidates
each gameplay application. Client-side visual effects may finish harmlessly,
but they never bypass server rejection.

Respawn protection is a more-specific protected policy. It must prevent
immediate hostile effects and cannot award normal kill or objective value.

## Protected Starts and Capital Isolation

Protected faction starts and capital military spaces are different domains:

- Beginner districts have no valid rival admission route.
- Ordinary regional travel cannot allocate a rival player into protected start
  instances.
- Invasion tickets authorize only named invasion/military destinations.
- Invasion routes, streaming connections, teleporters, and fallback spawns
  cannot resolve into beginner content.
- Military objectives cannot mutate beginner quest, spawn, or essential-service
  authority.
- A failed or expired invasion transition returns to an authorized safe
  destination; it does not fall through into a protected district.

Tests cover direct travel, party travel, reconnect, stale tickets, coordinate
spoofing, projectiles, persistent effects, summons, knockback, respawn, map
fallbacks, and administrative travel.

## Regional Transfer State Machine

Regional handoff uses a short controlled travel transition:

```text
Requested
    -> SourceValidated
    -> CheckpointCommitted
    -> DestinationReserved
    -> AdmissionIssued
    -> DestinationAdmitted
    -> LeaseAdvanced
    -> SourceReleased
    -> Completed

Any non-terminal state -> Failed or Expired through an idempotent recovery path
```

Required behavior:

1. The source validates eligibility, combat/travel restrictions, destination,
   and current character lease.
2. The persistence owner commits an authoritative checkpoint and state version.
3. Allocation reserves a destination instance with compatible build, protocol,
   content, and policy versions.
4. Admission issues a short-lived, single-use destination credential.
5. The destination validates the credential and checkpoint without trusting
   client-supplied character state.
6. Character authority advances to a higher fencing epoch for the destination.
7. The source loses mutation authority and releases its lease idempotently.
8. A durable terminal result supports safe retry and reconciliation.

The source cannot continue writing after the fencing epoch advances. The
destination cannot expose gameplay until it holds current authority. Crash
recovery resolves the durable transfer record rather than accepting whichever
server reports first.

## RegionTransfer Contract

| Field | Requirement |
| --- | --- |
| `TransferId` | Globally unique stable identity and idempotency scope |
| `CharacterId` | Durable character identity |
| Source | Source region, layer, instance, policy, and lease epoch |
| Destination | Destination region and requested instance role; resolved instance when allocated |
| `CheckpointVersion` | Committed character state version |
| `AdmissionReference` | Reference to single-use admission, not the secret credential in logs |
| Lease transition | Previous and next fencing epochs |
| `ExpiresAt` | Bounded completion window |
| `TerminalStatus` | Completed, failed, or expired with safe reason |
| `SchemaVersion` | Compatibility version |

Terminal results are immutable. Retrying the same transfer returns or advances
the recorded state; it does not create a second active authority path.

## World Partition Boundary

World Partition may be adopted for an outdoor map only when measurements show
it improves that map's content workflow and runtime behavior. It remains
per-map content streaming inside one Unreal world.

Evidence includes:

- Editor load and save behavior for representative content.
- Runtime client and dedicated-server memory.
- Streaming hitches and frame time.
- Network relevancy interactions and actor lifecycle.
- Navigation generation and runtime behavior.
- Cook time, package size, and deterministic build behavior.
- Team concurrency and merge behavior.
- Server/client asset-reference separation.

Reference:
[World Partition in Unreal Engine](https://dev.epicgames.com/documentation/en-us/unreal-engine/world-partition-in-unreal-engine).

Regional server boundaries are designed independently. A World Partition cell
is not a region, layer, instance, lease, policy, or transfer boundary.

## OFPA, Data Layers, HLOD, and PCG

### One File Per Actor

OFPA is preferred where it measurably reduces content-authoring contention.
Actor ownership, naming, validation, and external-actor source-control behavior
must be documented before a map is opened to broad production work.

### Data Layers

Data Layers represent authored world variants such as development views,
quest/invasion presentation, or other explicitly supported states. They do not
grant gameplay authority. A server validates any state that affects collision,
navigation, objectives, sanctuary, or access.

Runtime Data Layer changes are versioned and tested for join-in-progress,
reconnect, replication, save compatibility, and cook inclusion.

### Hierarchical Level of Detail

HLOD is a performance and streaming representation. It must preserve gameplay
collision and occlusion policy or use an explicit server-safe representation.
Generated HLOD artifacts follow the repository's future source-control policy.

### Procedural Content Generation

PCG may assist authored environment production. Runtime procedural output cannot
silently define authoritative objectives, collision, rewards, travel, policy,
or spawn eligibility.

Any deterministic runtime use records:

- Graph/content version.
- Authoritative seed ownership.
- Cook and replication behavior.
- Navigation and collision results.
- Migration or rebuild policy.

Client-provided seeds are never authoritative.

## Navigation and AI

- Navigation ownership is explicit per map and instance.
- Dedicated-server cooks include the data required for authoritative AI and
  movement without client-only presentation assets.
- Dynamic obstacles, streaming boundaries, Data Layers, doors, invasion gates,
  and destroyed objectives have automated or repeatable navigation checks.
- AI cannot path through a protected or inaccessible topology solely because a
  navigation mesh connects it.
- Navmesh size, generation time, runtime memory, path cost, and recovery under
  streaming are measured.
- Server-owned AI uses the same territory and hostile-effect policy checks as a
  player action.

## Asset Management and References

Before content production expands, define:

- Asset Manager rules and Primary Asset types.
- Stable Primary Asset IDs for gameplay definitions.
- Soft-reference rules for maps, characters, abilities, items, objectives, and
  presentation variants.
- Server-required, shared, and client-only asset categories.
- Cook inclusion/exclusion and chunk policy.
- Redirector and rename validation.
- Missing, duplicate, and invalid reference handling.

Authoritative gameplay definitions record a content version. A missing or
incompatible definition fails closed rather than falling back to a different
damage, policy, loot, or collision rule.

## Content Validation Gates

Automated validation grows with the content but begins before production volume:

- Required Primary Asset identity and version.
- No hard server dependency on client-only UI, audio, camera, Niagara, or
  high-detail visual assets.
- Collision profiles and simple-versus-complex collision policy.
- Equivalent authoritative collision and timing across presentation variants.
- Material feature and shader-complexity budgets when measured.
- Skeletal mesh bone, influence, morph, and animation-complexity budgets when
  measured.
- LOD and HLOD presence and transition checks for applicable assets.
- Map, Data Layer, navigation, spawn, sanctuary, and travel validation.
- Dedicated-server and client cook completeness.
- No editor-only asset required at runtime.

Numeric content budgets remain hypotheses until
[Issue #45](https://github.com/ShayShimoni/aetheln-online/issues/45) records
representative captures.

## Failure and Recovery

- Missing policy, map, or content version rejects admission or the affected
  authoritative action.
- An unavailable destination leaves the source authoritative until a durable
  lease transition succeeds.
- A source crash after checkpointing is recovered from the transfer and lease
  records.
- A destination crash after lease advancement cannot make the stale source
  current again.
- A layer closure drains or transfers characters through the same state machine.
- An invasion-coordination failure preserves beginner protection and essential
  services.

## Open Decisions

- Final region boundaries and Glasswake Reach ownership.
- Which outdoor maps adopt World Partition.
- Layer population, placement, drain, and faction-balance rules.
- Process-to-host packing and allocation provider.
- Cross-faction group travel.
- Capital routes, invasion capacity, scheduling, and recovery.
- Navigation generation approach for final outdoor maps.
- Cook chunking and delivery policy.

These remain `TBD` until their owning design or evidence work records a decision.
