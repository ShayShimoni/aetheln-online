# Enemy AI and Navigation Foundation

## Document Status

This is the implementation specification for
[Issue #83](https://github.com/ShayShimoni/aetheln-online/issues/83): the
server-authoritative enemy AI and navigation foundation that
[Issue #20](https://github.com/ShayShimoni/aetheln-online/issues/20) needs for
the prototype's one enemy. It is phase P1 of the issue and contains no code.
Pull requests P2 to P4 deliver it (see [Phased Delivery](#phased-delivery)).

It is subordinate to
[Combat and Networking Architecture](combat-and-networking-architecture.md),
[World Runtime and Building](world-runtime-and-building.md), TA-002, TA-003,
TA-004, and TA-026 in [Architecture Decisions](architecture-decisions.md), and
the canonical product documents, and it changes no product rule. It consumes
the server-owned attack timeline of
[Attack Timeline and Three-Hit Combo](attack-timeline-and-combo.md) (Issue
#60) and the AI ability-system rules of
[Gameplay Ability System Foundation](gas-foundation.md) (Issue #19).

Every timing, range, distance, damage, and delay value stays `TBD`. A
`Provisional...` config key is a named placeholder that stays unset (0) in
production config, so the enemy fails closed until an owner approves values;
automation tests set their own. C++ names are proposed code names. "Greybox
enemy" and the ability's working name are not final names.

**Citations.** Repository `path:line` citations are valid at `develop`
revision `d950ac92`. Engine citations are relative to the root of the pinned
UE 5.8.1 source, revision `71fe36aac5`; `Runtime/` abbreviates
`Engine/Source/Runtime/`.

## Decisions at a Glance

| Topic | Decision |
| --- | --- |
| AI approach | A server-only C++ state machine in a project `AAIController` subclass (TA-026). No Behavior Tree, StateTree, or AI Perception asset in the prototype. |
| Ability system | The enemy's ASC stays on the authoritative pawn in Minimal replication (TA-003). The controller keeps `bWantsPlayerState = false`, so `FindForPawn` resolves the pawn's own ASC. |
| Attack | The enemy registers one step at a time directly on the #60 timeline, without the activation seam. A granted enemy attack ability supplies the ability id, content version, and step definition the timeline revalidates against. |
| Time | Every state transition is stamped with its authored server time, the same rule the timeline uses; frame rate never shifts a transition. |
| Perception | A server-side eligibility query over player pawns. No line-of-sight check in the controlled arena, matching the timeline's occlusion decision. |
| Target choice | Provisional rule for #20 to confirm: keep the current target while it stays eligible; otherwise the nearest eligible player, ties broken by the lower `PlayerId`. |
| Navigation | One static navmesh for the controlled arena, used only by the server. Path following with partial paths, the engine's block detection for stuck recovery, and a leash around the spawn point. |
| Death and reset | The enemy dies when it is not alive by the timeline's rule. After an authored delay it resets at its spawn point with its initial attributes. |
| Replication | Character movement, the attribute set, the timeline's result cues, and one small replicated presentation state. No RPC on any enemy class. |
| Completion | Out of scope. The first PvE completion condition (P10-042) stays a Blocking `TBD` owned by #1 and #71. |

## Scope and Boundaries

| Owner | #83 consumes or provides | #83 does not do |
| --- | --- | --- |
| [#60](https://github.com/ShayShimoni/aetheln-online/issues/60) | Consumes `RegisterStep`, `StampReset`, the contact pipeline, interruption, and `OnLethalResult`. Adds one interruption notification to the timeline (see [Interruption](#interruption)). | Change the total order, revalidation, the allowance, or the result path. |
| [#19](https://github.com/ShayShimoni/aetheln-online/issues/19) | Consumes `AAethelnCombatAICharacter`, `FindForPawn`, the grant validation pattern, and `UAethelnAttributeInitEffect`. | Change the activation seam or the PlayerState lifecycle. |
| [#20](https://github.com/ShayShimoni/aetheln-online/issues/20) | Provides the enemy, its attack lifecycle, and the target-choice mechanism. | Choose the final target rule, threat, telegraph content, or the completion result. |
| [#21](https://github.com/ShayShimoni/aetheln-online/issues/21) | Reads "not alive" the way the timeline does. | Player death, respawn, or reconnect. #83 never applies `State.Dead` itself (see [Death and Reset](#death-and-reset)). |
| [#45](https://github.com/ShayShimoni/aetheln-online/issues/45) | Records measurements (navmesh build time and size, server frame cost with the enemy). | Set budgets, thresholds, or population assumptions. |
| [#96](https://github.com/ShayShimoni/aetheln-online/issues/96), [#97](https://github.com/ShayShimoni/aetheln-online/issues/97) | Uses the existing placeholder capsule and mannequin only. | Enemy art, animation, or effects. |
| [#84](https://github.com/ShayShimoni/aetheln-online/issues/84) | Exposes the presentation state that animation reads. | Montages, sockets, notifies, or the authoring pipeline. |
| [#107](https://github.com/ShayShimoni/aetheln-online/issues/107) | Names every tuning key. | Choose any value. |

## Canon Anchors and Existing Code

- The prototype has one class, one enemy, and one controlled combat space
  (`docs/game-design-bible.md:537`; ledger row P10-014).
- AI ASCs live on authoritative pawns, and server code activates AI abilities
  directly (TA-003; [Pawn to ASC lookup and AI](gas-foundation.md#pawn-to-asc-lookup-and-ai)).
- The enemy registers its steps directly, without the seam
  ([Scope and Boundaries](attack-timeline-and-combo.md#scope-and-boundaries)).
- PvE threat formulas and tie-breaking weights are tuning `TBD`, and
  generalized threat is outside prototype runtime scope
  ([Relation, Collision, Engagement, Threat, and Taunt](combat-and-networking-architecture.md#relation-collision-engagement-threat-and-taunt)).
- Navigation ownership is explicit per map, server cooks carry the navigation
  data authoritative AI needs, and navmesh size, generation time, path cost,
  and recovery are measured
  ([Navigation and AI](world-runtime-and-building.md#navigation-and-ai)).

What the existing code fixes:

1. The timeline commits a contact only when the attacker's ASC holds a granted
   `UAethelnGameplayAbility` whose `ContentVersion` matches the record
   (`Source/GameCombat/Private/AethelnCombatTimelineSubsystem.cpp:329-331`).
   The enemy therefore needs a granted ability, not only a registered step.
2. `RegisterStep` accepts `ChainStep` 1 to 3 only (`:118`). The enemy has no
   chain and registers every step as `ChainStep = 1`. This is a known wart; the
   check is not widened.
3. `Interrupt` stamps the enemy's steps and then calls `ResetChain`
   (`:411-415`), which does nothing for an ASC without a chain
   (`Source/GameCombat/Private/AethelnAbilitySystemComponent.cpp:1284`). The
   enemy is never told it was interrupted.
4. `AttackPresentationState` is written only by the player chain
   (`AethelnAbilitySystemComponent.cpp:1210-1214`), so a directly registered
   enemy step gives observers nothing to read.
5. Every #60 and #18 fixture spawns `AAethelnCombatAICharacter` as a still
   dummy (`Source/GameTests/Private/AethelnChainTestFixture.cpp:129-138`). The
   base class must not gain a controller or start moving.
6. `AAIController` already defaults `bWantsPlayerState` to false
   (`Runtime/AIModule/Private/AIController.cpp:51`). The project controller
   sets it explicitly and a test pins it.
7. `UWorld::CreateWorld` creates a navigation system only for Editor worlds
   (`Runtime/Engine/Private/World.cpp:2850`), so the headless automation world
   has none and every move request fails there.
   `UNavigationSystemV1::Build` blocks until every navigation data is built
   (`Runtime/NavigationSystem/Private/NavigationSystem.cpp:4441-4500`).

## Class Layout

| Class | Module | Role |
| --- | --- | --- |
| `AAethelnEnemyCharacter` | GameCombat | Subclass of `AAethelnCombatAICharacter`. Sets `AIControllerClass` and `AutoPossessAI = PlacedInWorldOrSpawned`. On the server in `BeginPlay`: records its spawn transform as home, validates and grants the enemy attack ability once. Holds the replicated `FAethelnEnemyPresentationState`. Declares no RPC. |
| `UAethelnEnemyAttackAbility` | GameCombat | `UAethelnGameplayAbility` subclass that is never activated (`CanActivateAbility` is always false). It is the identity the timeline revalidates: ability id, `ContentVersion`, `ProvisionalStep`, `ProvisionalMaxSampleDistance`, `ProvisionalMaxSampleAngleDegrees`. `FindGrantProblem` applies the basic chain's step rules to the one step and refuses unset values, so production config fails closed. Clients read the same config to derive the attack phases. |
| `AAethelnEnemyController` | GameCombat | `AAIController` subclass, server only. Runs the state machine, the eligibility query, path following, the leash, stuck recovery, and death and reset. Writes the presentation state on its pawn. `bWantsPlayerState = false`. |
| `EAethelnEnemyState`, `FAethelnEnemyPresentationState` | GameCombat | The state enum and its replicated presentation struct (see [Replication](#replication)). |
| `UAethelnCombatTimelineSubsystem::OnTargetInterrupted` | GameCombat | New native multicast `(TargetAsc, ContactTime)`, raised once per committed interruption after the steps are stamped. |

The ability id is a new native tag, `Ability.Enemy.GreyboxStrike` (working
name; its semantic ID is proposed for #106). It follows the
`Ability.<Family>.<Name>` form of the shared actions, since an enemy has no
Order.

`GameCombat.Build.cs` gains the engine modules `AIModule` and
`NavigationSystem`. Both are engine runtime modules, not plugins, so the
`.uproject` and the global build environment do not change (TA-026).

## State Machine

The controller holds one state and its authoritative start time. It evaluates
once per controller tick on the server. When a transition is due at an
authored time `T` and the tick runs at `Now >= T`, the new state starts at `T`,
not at `Now`. Each transition below is checked in the order listed; the first
one that applies wins.

| State | Entered when | Behavior | Leaves to |
| --- | --- | --- | --- |
| `Idle` | Spawn, reset done | Stands at home. Runs the eligibility query. | `Engage` when a target is eligible |
| `Engage` | A target is chosen | Path-follows toward the target. Re-runs target choice each tick. | `Telegraph` when the target is within `ProvisionalAttackRange` and the enemy can attack; `Return` when no target is eligible, the enemy leaves its leash, or a move request fails |
| `Telegraph` | Attack chosen | Stops moving and faces the target. Lasts `ProvisionalTelegraphSeconds` (may be 0, then wind-up alone is the tell). | `Attack` at its end; `Engage` if the target stopped being eligible before the step started (no step is registered) |
| `Attack` | Step registered at `S` | Stays still. Wind-up, active, and recovery are the step's windows: `[S, S + ActiveStart)`, `[S + ActiveStart, S + ActiveEnd)`, `[S + ActiveEnd, S + RecoveryEnd)`. | `Engage` at `S + RecoveryEnd`; `Interrupted` on an interruption |
| `Interrupted` | Timeline interruption at contact time `C` | Stays still from `C` for `ProvisionalInterruptedSeconds`. | `Engage` at its end |
| `Dead` | Not alive | Stops moving and acting. Stamps any live step. | `Reset` after `ProvisionalRespawnSeconds` |
| `Return` | No eligible target, or outside the leash | Path-follows home. Ignores targets until home. | `Reset` at home, on a failed move request, or by [stuck recovery](#stuck-recovery) |
| `Reset` | Respawn, return home, or failed recovery | Teleports home if not already there, stops movement, re-applies the initial attributes, clears the target. Instant. | `Idle` |

Death is checked first in every state. A live step at the time of death is
stamped at the detection time with `StampReset`; a lethal contact already
makes the enemy not alive from its contact time, so the timeline drops its
later contacts anyway (step 1 of revalidation).

**Attack selection.** The enemy has one attack. It can attack when it is in
`Engage`, alive, the ability is granted, and the target is within
`ProvisionalAttackRange` of the enemy capsule. Recovery is the only gap
between attacks; any further cooldown is a tuning decision.

**Accepted aim.** At the step start the aim is the unit vector from the enemy
capsule to the target capsule. The timeline clamps its pitch and fixes the
combat frame for the step. The aim is never recomputed during the step.

**Step registration.** At the telegraph end `S`, the controller fills an
`FAethelnCombatActivationRecord` (new activation id, a per-enemy sequence from
1, the ability id and content version, `ChainStep = 1`, `StartServerTime = S`,
the aim, the capsule origin, the windows) and calls `RegisterStep` with the
ability's sampling bounds. A refused registration ends the attack: the enemy
returns to `Engage` and counts nothing.

## Perception and Target Eligibility

A player pawn is eligible when all of these hold on the server:

1. `FindForPawn` resolves an ASC owned by a `PlayerState`.
2. It is alive by the timeline's rule (no `State.Dead`, a Health attribute,
   Health above zero).
3. `UAethelnCombatTimelineSubsystem::IsHostile(enemy, target)` is true.
4. Its capsule is within `ProvisionalPerceptionRadius` of the enemy and within
   `ProvisionalLeashRadius` of the enemy's home.
5. The pawn is not being destroyed.

Candidates come from the game state's `PlayerArray`, never actor iteration.
Target choice runs over the eligible set: the current target if it is still
eligible, otherwise the nearest by capsule distance, with ties broken by the
lower `PlayerId`. A target lost by death, disconnect, pawn destruction,
leaving the leash, or leaving perception is dropped in the same tick, and the
choice runs again.

There is no line-of-sight check. The timeline makes the same choice for
contacts in the controlled arena (residual risk 9 of #60); both are revisited
when the arena gains cover.

## Navigation

### Prototype space

- The prototype space is the controlled greybox arena map. Until that map
  exists, P4 uses the server default map `/Game/Maps/StarterMap`.
- One `NavMeshBoundsVolume` covers the arena floor. The `RecastNavMesh` uses
  static runtime generation, is built in the editor, and is saved with the
  map. The arena has no dynamic obstacles, doors, or streaming, so no runtime
  rebuild is needed.
- Only the server queries navigation. Clients see enemy movement through
  character movement replication. Whether the client cook can drop the
  navigation data is a cook-audience question for #120 and stays open.
- Navmesh generation time, tile count, and memory are recorded in P4 for #45.

### Movement

- `Engage` uses `MoveToActor` with acceptance radius
  `ProvisionalAttackRange` and partial paths allowed, so a target on ground the
  enemy cannot reach still draws it to the nearest reachable point, where it
  waits.
- `Return` uses `MoveToLocation` to home, with partial paths not allowed.

### Invalid and unreachable destinations

- A move request that returns `Failed` (no navigation data, the enemy or the
  goal off the navmesh, no path at all) is an invalid destination. In `Engage`
  the target is dropped for that tick and the enemy moves to `Return`. In
  `Return` the enemy moves to `Reset`, which teleports it home.
- A partial path is not a failure. The enemy waits at its end until the target
  comes into range, moves, or stops being eligible.

### Stuck recovery

The engine's path-following block detection (`UPathFollowingComponent`,
`bUseBlockDetection` and its distance, interval, and sample count, engine
defaults) reports `Blocked` or `OffPath`. The first such result repaths once.
A second consecutive one moves the enemy to `Reset`. A successful move clears
the count. No project stuck detector is written.

### Spawn and reset boundary

Home is the spawn transform. The leash is a radius around home. An enemy whose
capsule leaves the leash with no eligible target, or whose only targets have
left it, moves to `Return`. `Reset` always ends at home with the initial
attributes, so a reset enemy never keeps damage, a target, or a live step.
Whether the enemy can be hit while it returns, and whether it heals on return,
are open product questions (see [Open Decisions](#open-decisions)); the
foundation implements "can be hit, heals at `Reset`".

## Interruption

`Interrupt` already stamps every step of the target at the contact time. #83
adds `OnTargetInterrupted(TargetAsc, ContactTime)` to the timeline, raised
once per committed interruption, after the stamping and before the target's
`ResetChain`. The enemy controller binds it for its own ASC and enters
`Interrupted` at the contact time. A player's chain needs nothing new: its
`ResetChain` already ends it.

The order is the timeline's: an interruption is committed during resolution,
in the canonical total order, so the enemy's state change follows the same
order as the contacts. An interruption that arrives while the enemy is `Dead`
is ignored.

## Death and Reset

The enemy is dead when it is not alive by the timeline's rule. The controller
reads this each tick; it does not bind `OnLethalResult` and does not apply
`State.Dead`, which #21 owns. If #21's lethal binding applies `State.Dead` to
enemies too, `Reset` must remove it through #21's removal path; P2 checks #21's
merged code before it lands.

`Reset` re-applies `ProvisionalInitialAttributes` with
`UAethelnAttributeInitEffect::ApplyTo`, the same path the AI base uses in
`BeginPlay`. It does not respawn a new actor: the pawn, its ASC, and its combat
identity stay, so no client sees a destroyed and re-created enemy.

## Replication

Everything the clients need is already replicated, except one struct:

| Data | Path | Audience |
| --- | --- | --- |
| Position and rotation | Character movement replication | All relevant clients |
| Health and the other attributes | The pawn's attribute set (Minimal mode replicates attributes, not effects) | All relevant clients |
| Contact results | `MulticastCombatResultCue` on the target's ASC | All relevant clients |
| State and attack timing | `FAethelnEnemyPresentationState` on `AAethelnEnemyCharacter` | All relevant clients |

`FAethelnEnemyPresentationState` holds the state, its server start time, the
ability id and content version of the current step, the step start time, the
accepted aim, and a wrapping attack counter so a repeated attack replicates as
a change. Clients derive wind-up, active, and recovery from the step start
time and the ability's configured windows, as observers of the player chain
do. Presentation never feeds back: no enemy class has a server RPC, the AI
controller does not exist on clients, and the ASC's stock client routes are
closed by #19.

## Server-Only Execution

- The controller is spawned only on the server (`AutoPossessAI` runs on
  authority), and its tick does nothing in a client world.
- `RegisterStep` already refuses a client world.
- The ability is never activated, so no GAS activation route exists for it.
- No enemy class declares a `Server`, `Client`, or `NetMulticast` function of
  its own; a reflection test pins this.

## Test Plan

Headless automation in `Source/GameTests`, beside the #60 tests, using the
same fixtures. Every test is written red first.

| ID | Package | Covers |
| --- | --- | --- |
| E1 | P2 | Server-only execution: a client-mode world never registers a step or changes state; the enemy classes declare no RPC; the controller's `bWantsPlayerState` is false and `FindForPawn` on the enemy returns its own ASC. |
| E2 | P2 | Grant validation: unset production config grants nothing and the enemy never attacks; a valid test definition is granted once. |
| E3 | P2 | Attack lifecycle: telegraph, then a step registered at the exact telegraph end, wind-up, active, recovery, and back to `Engage`, each at its authored time under uneven frame times. |
| E4 | P2 | Interruption ordering: a player hit inside the enemy step's interruptible window moves the enemy to `Interrupted` at the contact time and drops its later contacts; outside the window nothing changes; one notification per interruption. |
| E5 | P2 | Death and reset: a lethal hit during wind-up kills the enemy, its step makes no later contact, and after the respawn delay it is home with its initial attributes and no target. |
| E6 | P2 | Two-player contention: deterministic choice between equidistant players by `PlayerId`; the current target stays while eligible; the other player is chosen when it dies or leaves. |
| E7 | P2 | Target loss: death, pawn destruction, and leaving perception or the leash each drop the target in the same tick, including during `Telegraph` (no step registered). |
| E8 | P2 | Presentation: the replicated state, counter, and step timing match the server state; clients derive the same phases. |
| E9 | P3 | Unreachable and invalid destinations: a failed move request (no navigation data) moves `Engage` to `Return` and `Return` to `Reset`; the enemy ends home. |
| E10 | P3 | Stuck recovery: one `Blocked` result repaths, a second resets; a success clears the count. |
| E11 | P3 | Leash: leaving the leash returns the enemy home and restores it. |
| E12 | P3 | Real navmesh, if a headless world with navigation can build one: the enemy reaches a target across the floor. If not, this moves to P4 as PIE evidence. |
| E13 | P4 | Two PIE clients against a dedicated server in the prototype space: both see the same enemy state, health, and results, including under the supported network profiles. |

## Acceptance-Criteria Mapping

| #83 criterion | Covered by |
| --- | --- |
| Server owns perception, navigation, transitions, eligibility, attack selection, timing, damage, death, and reset | State machine, eligibility, navigation; E1, E3, E5, E7, E9-E11 |
| Reviewed AI approach selected from measured needs | TA-026; revisited with P4's measurements |
| Navmesh, runtime constraints, spawn and reset boundaries, stuck recovery, invalid destinations specified | [Navigation](#navigation) |
| Readable telegraph, wind-up, active, recovery, interruption, death, and reset states without notifies | State machine and replication; E3, E4, E5, E8 |
| Minimum replication; clients cannot drive AI or contact | [Replication](#replication), [Server-Only Execution](#server-only-execution); E1, E8 |
| Tests for target loss, unreachable paths, invalid commands, interruption ordering, death and reset, two-player contention, server-only execution | E1-E11 |
| DoD: one greybox enemy navigates and attacks in the prototype space | P4, once provisional values are approved |
| DoD: focused automation and repeatable multiplayer evidence | E1-E13 |
| DoD: budgets stay with #45 | Measurements only, P4 |

## Phased Delivery

1. **P1** (this document): design, TA-026, index link. Docs only.
2. **P2**: enemy character, enemy attack ability, interruption notification,
   controller state machine, eligibility and target choice, death and reset,
   presentation state, tests E1 to E8.
3. **P3**: navigation behavior (failed and partial paths, stuck recovery,
   leash return), tests E9 to E12.
4. **P4**: navmesh and one enemy in the prototype space, two-client evidence
   (E13), and measurements for #45. Needs approved provisional values.

## Open Decisions

All stay `TBD` until the named owner decides.

1. **Enemy step values:** windows, shape, damage, Guard pressure, interruptible
   window, whether it interrupts, sampling bounds (#107, #45).
2. **Enemy behavior values:** `ProvisionalTelegraphSeconds`,
   `ProvisionalInterruptedSeconds`, `ProvisionalRespawnSeconds`,
   `ProvisionalAttackRange`, `ProvisionalPerceptionRadius`,
   `ProvisionalLeashRadius` (#107, #45). The P4 greybox run needs approved
   provisional values.
3. **Enemy initial attributes** (#107; already `TBD` on the AI base).
4. **Target rule** (#20): the provisional rule above, or another.
5. **Interrupted enemy behavior** (#20): the foundation pauses for an authored
   time, then re-engages.
6. **Return behavior** (#20): whether a returning enemy can be hit, and whether
   it heals on return.
7. **Prototype space** (#20 with the arena owner): which map, if not
   `StarterMap`.
8. **Navigation data in the client cook** (#120).

## Residual Risks

1. No line of sight: an arena with cover needs a check, for both perception and
   contacts.
2. `ChainStep = 1` for every enemy step reuses a player-chain field.
3. The state machine is code, so new enemy behavior needs a programmer. TA-026
   names when to revisit.
4. The headless world has no navigation by default; real-navmesh coverage may
   come only from PIE evidence (E12, E13).
