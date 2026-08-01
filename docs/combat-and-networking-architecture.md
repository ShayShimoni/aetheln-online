# Combat and Networking Architecture

## Document Status

This document is the canonical technical specification for movement, abilities,
free-aim combat, replication, prediction, correction, and latency validation.
Player-facing combat goals remain governed by the
[Game Design Bible](game-design-bible.md).
Player-facing body, rig, and animation-presentation rules remain governed by
[Playable Peoples](playable-peoples.md).

Technology selections that require measurement remain candidates in
[Architecture Decisions](architecture-decisions.md).

## Combat Invariants

- Combat uses pure free aim. The client never selects an authoritative target.
- The server never accepts a client-claimed hit, damage value, defensive
  outcome, resource result, death, or reward.
- Movement validity is owned by the authoritative
  `UCharacterMovementComponent` simulation.
- Ability state is owned by the Gameplay Ability System and the server-owned
  combat timeline.
- Authored gameplay windows and volumes determine attacks. Animation, sockets,
  Niagara, audio, and camera feedback visualize the result but do not create it.
- Appearance, race, sex, cosmetics, and client visual scale never change
  authoritative collision, reach, timing, or damage.
- Kell crown and mantle bones and Vesh back-veil bones are visual-only
  auxiliaries. They never drive combat collision, authoritative traces, shared
  weapon-presentation sockets, root motion, authored contact timing, or
  gameplay state.
- Presentation sockets and camera or aim-presentation anchors never establish
  gameplay windows, volumes, contacts, trace origins, or selected targets.
- Territory policy is checked both when a hostile action activates and when an
  effect would apply.

## Local Control Modes

The owning client starts gameplay in Reticle mode: hidden cursor, fixed center
reticle, camera-relative movement, camera-directed aim, and continuous
camera-facing steering intent. Cursor mode is a local input gate. Entering it
clears pending movement, jump, sprint, zoom, and look input and requires fresh
presses after recapture, but it does not pause physics, remove existing
momentum, cancel accepted abilities, or stop server-owned timelines.

Left Alt provides the prototype toggle. Future CommonUI screens and dialogue
flows must use stacked cursor-ownership requests rather than independent
booleans. An unhandled viewport click may recapture gameplay; a UI-handled click
must not. Focus loss enters Cursor mode, and focus recovery remains there until
an explicit recapture.

Close-camera shoulder offset and owner-only mesh hiding are presentation. They
never modify the authoritative aim direction, attack origin, authored volume,
collision, reach, or timeline. Shoulder-camera parallax and attacks obstructed
by near cover require separate combat validation; the movement prototype does
not prove reticle-to-attack alignment.

## Runtime Ownership

### Character Movement Component

`UCharacterMovementComponent` owns predicted and reconciled player movement.
Custom movement extends its saved-move and network-prediction paths rather than
creating a second uncoordinated transform authority.

The server validates:

- Movement mode and allowed transitions.
- Acceleration, speed, rotation, and displacement constraints.
- Sprint, dodge, root, knockback, and other state prerequisites.
- Collision and world-policy restrictions.
- Sequence ordering and stale or duplicated movement input.

The owning client may predict ordinary movement and supported custom movement.
Remote clients interpolate replicated authoritative state.

### Gameplay Ability System

- A player character's Ability System Component lives on `PlayerState` so
  authoritative ability and attribute state can survive pawn death and
  respawn.
- The possessed pawn provides avatar-specific movement, collision, animation,
  and equipment presentation.
- AI Ability System Components live on their authoritative pawns unless a future
  persistence requirement justifies a different owner.
- Gameplay Tags are the shared vocabulary for activation requirements,
  cancellation, immunities, crowd control, cooldowns, and territory-policy
  gates.
- Gameplay Effects own attribute changes. Direct client-authored attribute
  writes are prohibited.

The implementation must define and test possession, respawn, avatar reassignment,
attribute initialization, and replication for the `PlayerState`-owned component.

Reference:
[Understanding the Unreal Engine Gameplay Ability System](https://dev.epicgames.com/documentation/en-us/unreal-engine/understanding-the-unreal-engine-gameplay-ability-system).

## Pure Free Aim

Input provides intent:

- View orientation and movement.
- Ability identifier.
- Press, release, or charge state.
- A bounded client sequence and timing sample where the protocol allows it.

Input does not provide:

- Selected victim.
- Claimed contact point or surface.
- Claimed damage, stagger, block, dodge, or critical result.
- An arbitrary trace shape, distance, or active window.

The server resolves the authored attack definition for the validated ability
and content version. For melee, it evaluates authoritative swept shapes during
the active windows. For projectiles and persistent areas, it spawns and
simulates server-owned gameplay actors or server-owned lightweight simulation
state.

A camera-relative request is converted into a server-bounded aim direction.
The implementation records the accepted direction and correction result. It
rejects impossible orientation changes or inputs outside the allowed temporal
and angular bounds.

## Server-Owned Attack Timeline

Every accepted combat activation creates an authoritative timeline containing:

- Activation and sequence identity.
- Instigator and authoritative start time.
- Ability and content-definition version.
- Wind-up, active, recovery, cancel, and defensive windows.
- Authored shapes, transforms, and sampling rules.
- Resource, cooldown, and prerequisite state.
- Actors already affected when a rule permits only one result per activation.
- Block, dodge, interruption, crowd-control, and death ordering.
- Authoritative results and any client correction.

The timeline advances on the server even when a cosmetic montage or effect is
missing. Animation notifies may request presentation transitions or help sample
an authored pose, but a notify received from a client cannot open a gameplay
window.

Root motion and motion warping require explicit network validation. They do not
move an attack volume beyond the server's accepted character state.

## CombatActivation Contract

`CombatActivation` is the versioned authoritative record sent or replicated to
the consumers that need to present or audit one activation.

| Field | Requirement |
| --- | --- |
| `ActivationId` | Globally unique or instance-unique stable identity with documented scope |
| `SequenceId` | Monotonic identity within the actor/connection scope |
| `InstigatorId` | Authoritative actor identity |
| `AuthoritativeStartTime` | Server time in the instance clock domain |
| `AbilityId` | Stable gameplay ability/content identity |
| `ContentVersion` | Exact authored definition used by the server |
| `ActiveWindows` | Versioned offsets and semantic window types |
| `AttackShapes` | Authored shape identities and resolved server transforms, not client input |
| `CorrectionResult` | Accepted, corrected, or rejected with safe reason code |
| `ResultReferences` | Server result identities where required for audit or presentation |
| `SchemaVersion` | Contract compatibility version |

Serialization and transport remain undecided. A client copy is presentation
state, not a capability to amend the authoritative record.

## Prediction Matrix

| Behavior | Owning client | Server | Other clients |
| --- | --- | --- | --- |
| Ordinary movement | Predict, then reconcile | Validate and simulate | Interpolate |
| Supported custom movement | Predict with saved move | Validate and simulate | Interpolate |
| GAS activation | Predict when the ability supports rollback | Accept, correct, or reject | Observe accepted activation |
| Montage and cues | Predict presentation | Confirm authoritative timeline | Observe replicated presentation |
| Reversible costs/cooldowns | Predict only through supported GAS prediction | Commit or roll back | Observe committed state |
| Attack contact | Optional cosmetic anticipation only | Resolve authored volumes | Observe result |
| Damage/healing | Never authoritative | Calculate and apply | Observe result |
| Block/dodge outcome | Request/predict presentation | Order and resolve | Observe result |
| Crowd control/death/respawn | Never authoritative | Resolve and transition | Observe result |
| Rewards/persistent outcomes | Never predict as owned state | Submit validated durable command | Observe recorded receipt |

Prediction is enabled per ability only after rollback and correction behavior is
tested under the supported network profiles. A predicted visual effect must not
be mistaken for a confirmed hit.

## Ordering and Defensive Resolution

The authoritative timeline defines a deterministic order for:

1. Validate activation and territory policy.
2. Commit authoritative costs and cooldown rules.
3. Advance movement and combat windows using the server clock.
4. Resolve defensive state applicable to each sampled contact.
5. Resolve block direction, dodge/invulnerability, interruption, or immunity.
6. Apply effects and record already-hit state.
7. Resolve death and cancellation.
8. Emit authoritative presentation and audit events.

The exact rule between simultaneous events is content data or an explicit combat
decision, never frame-order accident. Tests must cover boundary timestamps,
multiple contacts, repeated packets, actor destruction, disconnect, and death
during an active window.

## Corrections and Rejections

The client receives enough information to return to authoritative state without
learning sensitive detection rules.

Correction categories include:

- Stale or duplicated sequence.
- Invalid movement or orientation.
- Ability unavailable, blocked, or on cooldown.
- Insufficient authoritative resource.
- Incompatible content/protocol version.
- Territory policy rejection.
- Target/effect no longer valid.
- Timestamp outside accepted bounds.
- Rate or resource limit exceeded.

Telemetry correlates connection, character, instance, activation, ability,
content version, network profile, and safe reason code. Sensitive anti-abuse
features and secrets are excluded from client errors and ordinary logs.

Repeated rejection is an observable security signal, not proof by itself that a
player is cheating.

## Replication Strategy Gate

[Issue #2](https://github.com/ShayShimoni/aetheln-online/issues/2) must implement
the same representative actor mix and scenarios with:

1. Generic Unreal replication using push-model updates where appropriate.
2. Replication Graph.
3. Iris.

Iris and Replication Graph are mutually exclusive paths for this selection.
Neither is canonical until the benchmark records:

- Server game-thread and replication CPU.
- Client and server memory.
- Bandwidth per connection and total.
- Correction frequency and magnitude.
- Relevant actor count and actor-type mix.
- Dormancy, relevancy, prioritization, join-in-progress, and destruction
  behavior.
- Implementation and debugging complexity.
- Failure behavior during loss, stalls, overload, reconnect, and travel.

The actor mix includes players, AI, projectiles, persistent areas, objectives,
world-policy state, and representative cosmetic replication boundaries.
Measurements must distinguish editor from packaged builds.

The required two-client prototype establishes correctness and capture
instrumentation only. It does not establish player or actor density, instance
capacity, or a replication-technology selection. Selection requires equivalent
packaged candidate runs with the same actor mix and scenarios, followed by
reviewed evidence owned by Issues #2 and #45.

References:

- [Unreal Engine 5.8 release notes](https://dev.epicgames.com/documentation/unreal-engine/unreal-engine-5-8-release-notes)
- [Migrating to Iris](https://dev.epicgames.com/documentation/en-us/unreal-engine/migrate-to-iris-in-unreal-engine)

## Latency-Compensation Evidence Gate

Before mandatory faction PvP, Issue #2 compares present-time server validation
with bounded server rewind for each eligible action family.

The spike covers:

- Swept melee volumes and multi-window attacks.
- Projectiles with server-owned trajectories.
- Directional block and dodge ordering.
- Moving, interrupting, and dying targets.
- Client timestamps mapped to the server clock.
- Timestamp clamping, history length, and discontinuities.
- Teleports, regional transfers, possession changes, and respawn.
- High latency, jitter, loss, duplication, and reordered input.
- Abuse cases such as forged old timestamps or view changes.

Rewind never accepts a client-selected target or claimed contact. The server
reconstructs bounded historical state, applies current policy and eligibility
rules, and records which validation mode produced the outcome.

History duration, eligible shapes, timestamp allowance, and precedence rules
remain `TBD` until the spike measures fairness, exploit surface, CPU, memory,
and player-facing corrections.

## Network Profiles and Evidence

Versioned profiles include:

- Clean local/reference conditions.
- Representative development latency and jitter.
- Representative packet loss and duplication.
- Harsh but supported validation conditions.
- Explicit unsupported or disconnect thresholds once evidence exists.

The repository must not invent numeric values before Issue #2 and
[Issue #45](https://github.com/ShayShimoni/aetheln-online/issues/45) record them.
Every result names build, hardware, topology, player/actor mix, map, duration,
and capture tooling.

## Automation and Manual Validation

The prototype requires:

- Packaged dedicated server and two packaged clients.
- Multi-process Gauntlet scenarios where automation supports the path.
- Unreal Insights and Networking Insights captures for representative runs.
- Focused automation for ability prerequisites, costs, cooldowns, effect
  application, death, respawn, and policy rejection.
- Invalid movement, aim, activation, hit, dodge, block, cooldown, and repeated
  command cases.
- Equivalence tests for male and female presentation variants when those assets
  exist.
- Manual feel/readability evidence where automation cannot judge the result.

Epic's
[network testing guidance](https://dev.epicgames.com/documentation/en-us/unreal-engine/testing-and-debugging-networked-games-in-unreal-engine)
is the starting point. Exact commands are added by Issues #13, #15, and #44
when the Unreal project exists.

## Failure and Recovery

- A disconnected client stops producing valid commands immediately.
- Reconnection creates a new authenticated connection and admission decision;
  it does not revive an old transport session by assertion.
- A dead or destroyed pawn cannot continue an active timeline unless the
  authored server rule explicitly permits a surviving server-owned effect.
- Join-in-progress receives current authoritative state, not a replay of
  unconfirmed client prediction.
- Version mismatch fails closed with an actionable safe error.
- An overloaded server rejects new work or admission before it silently stops
  enforcing authority.

## Open Decisions

- Replication implementation after the three-way benchmark.
- Present-time versus bounded-rewind policy by action family.
- Supported network-profile thresholds.
- Server tick and combat-history sampling.
- Projectile simulation representation at representative scale.
- Exact simultaneous-event ordering where game design has not resolved it.
- Ability-specific prediction and rollback eligibility.

These decisions require linked evidence and an accepted entry in
[Architecture Decisions](architecture-decisions.md).
