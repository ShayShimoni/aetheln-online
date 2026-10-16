# Enemy AI and Navigation Foundation

## Document Status

This is the implementation specification for
[Issue #83](https://github.com/ShayShimoni/aetheln-online/issues/83): the
server-authoritative enemy AI and navigation foundation that
[Issue #20](https://github.com/ShayShimoni/aetheln-online/issues/20) needs for
the prototype's one enemy. It is phase P1 of the issue and contains no code.
Pull requests P2, P3, and P4 deliver it (see [Phased Delivery](#phased-delivery)).

It is subordinate to
[Combat and Networking Architecture](combat-and-networking-architecture.md),
[World Runtime and Building](world-runtime-and-building.md), TA-002, TA-003,
TA-004, and TA-026 in [Architecture Decisions](architecture-decisions.md), and
the canonical product documents, and it changes no product rule. It consumes
the server-owned attack timeline of
[Attack Timeline and Three-Hit Combo](attack-timeline-and-combo.md) (Issue
#60) and the AI ability-system rules of
[Gameplay Ability System Foundation](gas-foundation.md) (Issue #19).

Every timing, range, distance, damage, and delay value stays `TBD` as tuning.
The owner approved the P3 greybox run on provisional values: the values the E1
to E11 tests used moved unchanged into `Config/DefaultGame.ini`, marked
provisional, with no new number
([decision](https://github.com/ShayShimoni/aetheln-online/issues/83#issuecomment-6156988023)).
A `Provisional...` config key holds one of them; the feel test re-tunes them,
and a change to any authoritative step field bumps the attack's
`ContentVersion`. The config is each value's only place: no test supplies the
provisional values and this document repeats none. Scenario tests override single
instance values and derive expectations from the step geometry, so a re-tune must
update those expectations in the same change.

Two groups of keys gate the enemy, so a key that is unset, zero, or invalid fails
closed:

- The attack ability's `ContentVersion`, step values, and sampling bounds. Unset,
  the ability's grant is refused, and the enemy never attacks.
- The controller's `ProvisionalRespawnSeconds`, `ProvisionalAttackRange`,
  `ProvisionalPerceptionRadius`, and `ProvisionalLeashRadius`. Zero is unset:
  the controller then decides nothing.

`ProvisionalTelegraphSeconds` and `ProvisionalInterruptedSeconds` do not gate:
0 is a valid value for both (no separate tell, no pause).

C++ names are proposed code names. "Greybox enemy" and the ability's working
name are not final names.

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
| Time | The timeline pass drives the controller, in pass step 1, so an enemy step is swept and resolved in the same pass and the same total order as every other contact. Transitions are stamped with their authored times; results committed later in the pass move the enemy back to their contact time. A reset takes effect after the pass's emission, so the pass resolves against the pre-reset enemy. |
| Perception | A server-side eligibility query over player pawns. No line-of-sight check in the controlled arena, matching the timeline's occlusion decision. |
| Target choice | Provisional rule for #20 to confirm: keep the current target while it stays eligible; otherwise the nearest eligible player, ties broken by the lower `PlayerId`. |
| Navigation | One static navmesh for the controlled arena, used only by the server. Path following with partial paths, the engine's block detection for stuck recovery, and a leash around the spawn point. |
| Death and reset | The enemy dies at its lethal contact time. After an authored delay from that time it resets at its spawn point with its initial attributes. |
| Replication | Character movement, the timeline's result cues, and one small replicated presentation state that includes the server-owned `Telegraph` state. No RPC on any enemy class. Enemy Endurance and Guard replicate `COND_OwnerOnly` and reach no client. Enemy Health and MaxHealth follow the #61 decision ([comment](https://github.com/ShayShimoni/aetheln-online/issues/61#issuecomment-6131999614)): `COND_None`, public to every relevant client (see [Replication](#replication)). |
| Completion | Out of scope. The first PvE completion condition (P10-042) stays a Blocking `TBD` owned by #1 and #71. |

## Scope and Boundaries

| Owner | #83 consumes or provides | #83 does not do |
| --- | --- | --- |
| [#60](https://github.com/ShayShimoni/aetheln-online/issues/60) | Consumes `RegisterStep`, `StampReset`, the contact pipeline, interruption, and the lethal notification. Adds pass-start, pass-end, and interruption notifications, and adds the contact time to the lethal notification (see [Timing](#timing)). | Change the total order, revalidation, the allowance, or the result path. |
| [#19](https://github.com/ShayShimoni/aetheln-online/issues/19) | Consumes `AAethelnCombatAICharacter`, `FindForPawn`, the grant validation, and `UAethelnAttributeInitEffect`. | Change the activation seam or the PlayerState lifecycle. |
| [#20](https://github.com/ShayShimoni/aetheln-online/issues/20) | Provides the enemy, its attack lifecycle, and the target-choice mechanism. | Choose the final target rule, threat, telegraph content, or the completion result. |
| [#21](https://github.com/ShayShimoni/aetheln-online/issues/21) | Binds the same lethal notification #21 binds. | Player death, respawn, or reconnect. #83 never applies `State.Dead` itself (see [Death and Reset](#death-and-reset)). |
| [#84](https://github.com/ShayShimoni/aetheln-online/issues/84) | Owns the server `Telegraph` state and replicates it in `FAethelnEnemyPresentationState`; the #84 binding's telegraph and wind-up only visualize that state and the step's phases. | Montages, sockets, notifies, or the authoring pipeline. |
| [#120](https://github.com/ShayShimoni/aetheln-online/issues/120) | Names the navigation data the prototype space needs in `MovementPOC`, which the `navigation` content-validation family reviews. P4 adds them (see [Navigation](#navigation)). | Change the content-validation gate. |
| [#45](https://github.com/ShayShimoni/aetheln-online/issues/45) | Records measurements (navmesh build time and size, server frame cost with the enemy). | Set budgets, thresholds, or population assumptions. |
| [#96](https://github.com/ShayShimoni/aetheln-online/issues/96), [#97](https://github.com/ShayShimoni/aetheln-online/issues/97) | Uses the existing placeholder capsule and mannequin only. | Enemy art, animation, or effects. |
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
4. `Interrupt` takes the target's step at the contact time to be the first
   registered step whose interval from its start to its reset time holds that
   time (`:403-406`). A step that is never stamped stays registered and holds
   every later time, so the controller stamps every enemy step when it ends.
5. `AttackPresentationState` is written only by the player chain
   (`AethelnAbilitySystemComponent.cpp:1210-1214`), so a directly registered
   enemy step gives observers nothing to read.
6. The pass runs on `OnWorldPostActorTick`, after every actor and controller
   tick ([Timeline driver and clock](attack-timeline-and-combo.md#timeline-driver-and-clock)).
   A controller that decided in its own tick could pass a time the pass has not
   yet resolved.
7. Every #60 and #18 fixture spawns `AAethelnCombatAICharacter` as a still
   dummy (`Source/GameTests/Private/AethelnChainTestFixture.cpp:129-138`). The
   base class must not gain a controller or start moving.
8. `AAIController` already defaults `bWantsPlayerState` to false
   (`Runtime/AIModule/Private/AIController.cpp:51`). The project controller
   sets it explicitly and a test pins it.
9. `UWorld::CreateWorld` creates a navigation system only for Editor worlds
   (`Runtime/Engine/Private/World.cpp:2850`), so the headless automation world
   has none and every move request fails there.
   `UNavigationSystemV1::Build` blocks until every navigation data is built
   (`Runtime/NavigationSystem/Private/NavigationSystem.cpp:4441-4500`).

## Class Layout

| Class | Module | Role |
| --- | --- | --- |
| `AAethelnEnemyCharacter` | GameCombat | Subclass of `AAethelnCombatAICharacter`. Sets `AIControllerClass` and `AutoPossessAI = PlacedInWorldOrSpawned`. On the server in `BeginPlay`: records its spawn transform as home, validates and grants the enemy attack ability once. Holds the replicated `FAethelnEnemyPresentationState`. Declares no RPC. |
| `UAethelnEnemyAttackAbility` | GameCombat | `UAethelnGameplayAbility` subclass that is never activated (`CanActivateAbility` is always false). It is the identity the timeline revalidates: ability id, `ContentVersion`, `ProvisionalStep`, `ProvisionalMaxSampleDistance`, `ProvisionalMaxSampleAngleDegrees`. Clients read the same config to derive the attack phases. |
| `AAethelnEnemyController` | GameCombat | `AAIController` subclass, server only. Runs the state machine, the eligibility query, path following, the leash, stuck recovery, and death and reset. Writes the presentation state on its pawn. `bWantsPlayerState = false`. |
| `EAethelnEnemyState`, `FAethelnEnemyPresentationState` | GameCombat | The state enum and its replicated presentation struct (see [Replication](#replication)). |
| Timeline notifications | GameCombat | `OnPassStart(Now)`, `OnPassEnd(Now)`, `OnTargetInterrupted(TargetAsc, ContactTime)`, and `OnLethalResult` with the contact time added (see [Timing](#timing)). |

**Grant rules for the one step.** `FindGrantProblem` applies the base rules of
`UAethelnGameplayAbility` and then:

- no Endurance cost, no cooldown, and no Release route, because the ability is
  never activated;
- sampling bounds that are finite and above zero;
- every step value finite and not negative;
- `ActiveStart < ActiveEnd`, `ActiveEnd <= CancelOpen <= RecoveryEnd`, and
  `InterruptibleUntil <= RecoveryEnd`;
- the final-step form of the basic chain: `BufferOpen == RecoveryEnd` and both
  link offsets 0. The enemy has no chain, so buffer and link offsets carry no
  meaning; the form only pins them. `CancelOpen` holds no commitment tag for an
  enemy either;
- a valid shape and extent, finite non-negative damage and Guard pressure, at
  least one target, and a pitch clamp of at most 90 degrees.

These are the basic chain's per-step rules with `bFinalStep` set; P2 moves them
into one shared function so both abilities use the same code.

**Ability identity.** P2 assigns the semantic ID
`enemy.greybox.ability.strike` (working name, proposed for #106, as new IDs
are), adds the mapping row to the
[Initial entries](combat-and-networking-architecture.md#gameplay-tag-and-content-version-conventions)
table, and adds the test entry that pins the tag to that ID. The tag form follows
from the ID: an enemy-scoped ID (`enemy.<enemy>.` prefix) gives
`<Family>.Enemy.<Enemy>.<Name>`, here `Ability.Enemy.Greybox.Strike`. The
`Enemy` segment keeps enemy tags apart from Order-scoped tags, so the mapping
stays one to one. The convention's Order-scope paragraph states this
enemy-scope rule.

`GameCombat.Build.cs` gains the engine runtime module `AIModule`, which brings
`NavigationSystem` as its own public dependency. Neither is a plugin, so the
`.uproject` does not change (TA-026).

## State Machine

The controller holds one state and its authoritative start time. Seven states
exist; `Reset` is an instant action, not a state.

| State | Entered when | Behavior | Leaves to |
| --- | --- | --- | --- |
| `Idle` | Spawn, reset done | Stands at home. Runs the eligibility query. | `Engage` when a target is eligible, or `Telegraph` when that target is already in range and the enemy can attack |
| `Engage` | A target is chosen | Path-follows toward the target. Re-runs target choice. | `Telegraph` when the target is within `ProvisionalAttackRange` and the enemy can attack; `Return` when no target is eligible (a target beyond the leash is not eligible) or a move request fails |
| `Telegraph` | Attack chosen | Stops moving and faces the target. Lasts `ProvisionalTelegraphSeconds`. No step is registered yet. | `Attack` at its end; `Engage` if the target stopped being eligible before the step started (no step is registered) |
| `Attack` | Step registered at `S` | Stays still. Wind-up, active, and recovery are the step's windows: `[S, S + ActiveStart)`, `[S + ActiveStart, S + ActiveEnd)`, `[S + ActiveEnd, S + RecoveryEnd)`. | `Engage` at `S + RecoveryEnd`; `Interrupted` on an interruption |
| `Interrupted` | Timeline interruption at contact time `C` | Stays still from `C` for `ProvisionalInterruptedSeconds`. | `Engage` at its end |
| `Dead` | Lethal contact at `C` | Stops moving and acting. | `Reset` at `C + ProvisionalRespawnSeconds` |
| `Return` | No eligible target (a target beyond the leash is not eligible), or a failed move request in `Engage` | Path-follows home. Ignores targets until home. | `Reset` at home, on a failed move request, or by [stuck recovery](#stuck-recovery) |

`Reset` teleports the enemy home if it is not already there, stops movement,
re-applies the initial attributes, clears the target, and enters `Idle` at the
reset time. A reset decided in pass step 1 takes effect after the pass's
emission (see [Timing](#timing)).

Every exit from `Attack` stamps the step's reset at the exit time (recovery
end, interruption, or death), so no enemy step stays registered after it ends.

**Attack selection.** The enemy has one attack. It can attack when it is in
`Idle` or `Engage`, alive, the ability is granted, and the target is within
`ProvisionalAttackRange`. Range is the horizontal (2D) distance between the
two capsule centers, the same measure as the engine's reach test, which adds
only a height check that changes nothing on the flat arena floor. Recovery is the only gap
between attacks; any further cooldown is a tuning decision.

**Accepted aim.** The aim is the unit vector from the enemy capsule to the
target capsule, read from their server positions at the pass time `Now` when
the step registers (the step start `S` may be slightly earlier). The timeline clamps its pitch and fixes the
combat frame for the step. The aim is never recomputed during the step.

**Step registration.** At the telegraph end `S`, the controller fills an
`FAethelnCombatActivationRecord` (new activation id, a per-enemy sequence from
1, the ability id and content version, `ChainStep = 1`, `StartServerTime = S`,
the aim, the capsule origin, the windows) and calls `RegisterStep` with the
ability's sampling bounds. A refused registration ends the attack: the enemy
returns to `Engage` at `S`, and neither the sequence nor the attack counter
advances.

### Timing

The controller makes no decision in its own tick. The timeline pass drives it:

1. In pass step 1, after the players' buffered starts and before the sweeps,
   the subsystem raises `OnPassStart(Now)`. It is raised before the pass
   sorts its steps and snapshots their activation ids
   (the sort and the id snapshot right after `OnPassStart` in `HandlePostActorTick`), so a step registered in it
   is part of this pass. Each bound enemy controller, in the
   order they were bound, applies every transition due up to `Now`. A
   transition due at an authored time `T <= Now` starts its state at `T`; a
   transition that depends on positions (perception, range) starts at `Now`.
2. A step whose telegraph ended at `S <= Now` registers in that call with start
   `S`. The same pass sweeps it from `S` and resolves its contacts together with
   every other contact of the frame, in the one total order. The controller
   never registers a step anywhere else, so no step starts inside time a pass
   has already resolved.
3. Path-following results that arrive during the actor tick are only recorded,
   and only for the controller's current move request (matched by request id);
   a result recorded for the current request id is applied at the next pass start,
   and `Aborted` changes nothing (`DecideMoveRecovery`). A request that finishes
   inside `MoveTo` itself (`Failed` or `AlreadyAtGoal`) is handled from the
   return code, not from the callback: the controller stores the new request id
   only after `MoveTo` returns, so that synchronous callback is dropped.
4. A reset decided in pass step 1 (respawn, return home, a failed move request
   in `Return`, or stuck recovery) does not move or heal the enemy there. It is
   pending until the subsystem raises `OnPassEnd(Now)` after the pass's
   emission and before it removes the reset steps (a reset touches no step); then the enemy is teleported home,
   healed, and enters `Idle` at the reset time. So every contact of the pass
   resolves against the enemy's pre-reset position and Health, and the pass
   makes no further decision for that enemy.

When the controller advances in pass step 1, it knows every result up to the
previous pass. This pass may then commit results for times between the
previous pass and `Now` that come before the state the controller just
entered. Those late results win:

- **Late interruption.** An interruption at contact time `C`, raised during
  resolution, moves the enemy to `Interrupted` at `C`, whatever state the
  controller reached after `C`. The timeline has already stamped every enemy
  step at `C`, so a step the controller started after `C` never started: its
  contacts fail revalidation, and the controller drops it. Its sequence number
  stays used, and its attack counter has advanced. Clients never see that
  step as an attack, because replication happens after the pass.
- **Late death.** A lethal result at contact time `C`, raised during emission,
  moves the enemy to `Dead` at `C`. A step started after `C` makes no contact,
  because the enemy is not alive when its contacts resolve.

An interruption or a lethal result that arrives while the enemy is already
`Dead` is ignored. A late interruption or a late lethal result cancels a
pending reset: the enemy stays where it is, with the Health it has.

## Perception and Target Eligibility

A player pawn is eligible when all of these hold on the server:

1. `FindForPawn` resolves an ASC owned by a `PlayerState`.
2. It is alive by the timeline's rule (no `State.Dead`, a Health attribute,
   Health above zero).
3. `UAethelnCombatTimelineSubsystem::IsHostile(enemy, target)` is true.
4. Its capsule is within `ProvisionalPerceptionRadius` of the enemy and within
   `ProvisionalLeashRadius` of the enemy's home.
5. The pawn is not being destroyed.

Candidates are the pawns of the world's player controllers. The choice does
not depend on their order: the current target if it is still eligible,
otherwise the nearest by capsule distance, with ties broken by the lower
`PlayerId`. A target lost by death, disconnect, pawn destruction, leaving the
leash, or leaving perception is dropped at the next pass start, and the choice
runs again.

There is no line-of-sight check. The timeline makes the same choice for
contacts in the controlled arena (residual risk 9 of #60); both are revisited
when the arena gains cover.

## Navigation

### Prototype space

- The prototype space is `/Game/Maps/MovementPOC`, the project's
  `GameDefaultMap` and editor startup map (owner decision on
  [#83](https://github.com/ShayShimoni/aetheln-online/issues/83#issuecomment-6156988023)).
  `ServerDefaultMap` is still `StarterMap` by an earlier decision
  ([Movement POC](movement-poc.md)); changing it is a separate decision. The
  two-client automation (E13) runs on CQTest's generated map, which the owner
  allowed.
- One `NavMeshBoundsVolume` covers the arena floor. The `RecastNavMesh` uses
  static runtime generation, is built in the editor, and is saved with the
  map. The arena has no dynamic obstacles, doors, or streaming, so no runtime
  rebuild is needed. P4 adds them to `MovementPOC.umap`, a lockable LFS binary
  ([Source Control](source-control.md)): the volume, the built mesh, and the one
  placed enemy, saved under the lock. They were authored headless, with the
  `AethelnPrototypeSpaceAuthoring` commandlet (see [Authoring the map](#authoring-the-map)).
  P3 proved the mesh and the enemy walking on it on a built headless arena
  instead (E12, [Measurements](#measurements)); E14 proves the saved map itself.
- Only the server queries navigation. Clients see enemy movement through
  character movement replication.
- `MovementPOC` is governed content. Its navigation data falls under the #120
  `navigation` content-validation family (navigation data audience, streaming
  boundaries, runtime rebuild policy). That family stays `non_promotion` until
  a producer binds governed navigation packages to exact client and server
  cook evidence and the pinned-Editor tests have run
  ([Asset Intake and Content Validation](asset-intake-and-content-validation.md)).
  P4 changes the map, so it follows the #120 map-change rules (see
  [#120 review of the map change](#120-review-of-the-map-change)) and does not
  claim the family passes. Whether the client cook can drop the navigation data
  stays open for #120.
- Navmesh generation time, tile count, and memory are recorded in P3 for #45,
  and the `MovementPOC` mesh's build time and tile count in P4
  ([Measurements](#measurements)).

### Authoring the map

The map is authored headless, because the Editor may be open and an Editor
session on a binary map cannot be merged. `UAethelnPrototypeSpaceAuthoringCommandlet`
(`Source/GameTests`, Editor module) loads `/Game/Maps/MovementPOC` and adds the
`NavMeshBoundsVolume` (a box over the whole floor), the `RecastNavMesh` (the
navigation build creates it), and one `AAethelnEnemyCharacter` on open floor, then
saves the map. It refuses a map that already has any of the three. Take the LFS
lock on `Content/Maps/MovementPOC.umap` first, run it under the engine lock, then
update the registry hash (see below):

```powershell
& (Join-Path $AethelnEngineRoot 'Engine\Binaries\Win64\UnrealEditor-Cmd.exe') $AethelnProject `
  -run=AethelnPrototypeSpaceAuthoring -unattended -nop4 -nullrhi
```

The box size and the enemy position are fixture geometry (the course is described
in [Movement POC](movement-poc.md)), not tuning. E14 pins them by what they must
do: the volume covers the floor inside the walls, the enemy and the player start
stand on the mesh, and a complete path joins them.

### #120 review of the map change

`MovementPOC` is a governed runtime package, so changing it is a content change
under [Asset Intake and Content Validation](asset-intake-and-content-validation.md):

- Lock before editing, and release after the PR merges (the lock is released
  only then so that nobody saves the map in between).
- The registry record (`Config/ContentValidation/runtime-asset-intake.json`)
  carries the new exact LFS object SHA-256 in both places, a new content version
  because the map's behavior changed (the source group's own rule: review every
  resulting hash as a new content version), and the change in the source group's
  `modifications`. The registry check fails closed on a stale hash.
- The map stays `temporary_prototype` and `client_only`: nothing here is
  production approval, and the dedicated server's `ServerDefaultMap` is still
  `StarterMap`. Whether a map that now carries server-relevant navigation data
  and an enemy keeps the `client_only` audience is open for #120 and is recorded
  in [Open Decisions](#open-decisions).
- The content validation run (`scripts/content/Invoke-ContentValidation.ps1`)
  now finds a navigation data actor in the map, so the `navigation` family
  becomes applicable instead of `not_applicable`. It stays `non_promotion`: the
  navigation audience evidence is unavailable and the quantitative policy is
  `TBD`. This PR does not claim the family passes.
  The run on the P4 head: result `non_promotion`, 51 governed packages, 108
  findings, 0 errors, and the `navigation` family reported `non_promotion` for
  `MovementPOC` (`content.navigation.non_promotion`, evidence unavailable).

### Movement

- `Engage` moves toward the target actor with acceptance radius
  `ProvisionalAttackRange` and partial paths allowed, so a target on ground the
  enemy cannot reach still draws it to the nearest reachable point, where it
  waits. The reach test excludes both capsule radii, so path following stops at
  the same 2D capsule-center distance the attack-range check uses.
- `Return` uses `MoveToLocation` to home, with partial paths not allowed.

### Invalid and unreachable destinations

- A move request that returns `Failed` (no navigation data, the enemy or the
  goal off the navmesh, no path at all) is an invalid destination. In `Engage`
  the target is dropped and the enemy moves to `Return`. In `Return` the enemy
  resets, which teleports it home.
- A partial path is not a failure. The enemy waits at its end until the target
  comes into range, moves, or stops being eligible.

### Stuck recovery

The engine's path-following block detection (`UPathFollowingComponent`,
`bUseBlockDetection` and its distance, interval, and sample count, engine
defaults) reports `Blocked` or `OffPath`. The first such result repaths once.
A second consecutive one resets the enemy. A successful move clears the count.
No project stuck detector is written; the policy is one pure function, tested
directly.

### Spawn and reset boundary

Home is the spawn transform. The leash is a radius around home. An enemy whose
targets have all left the leash moves to `Return`. `Reset` always ends at home
with the initial attributes, so a reset enemy never keeps damage, a target, or
a live step. Whether the enemy can be hit while it returns, and whether it
heals on return, are open product questions (see
[Open Decisions](#open-decisions)); the foundation implements "can be hit,
heals at `Reset`".

## Interruption

`Interrupt` already stamps every step of the target at the contact time. #83
adds `OnTargetInterrupted(TargetAsc, ContactTime)` to the timeline, raised
once per committed interruption, after the stamping and before the target's
`ResetChain`. The enemy controller binds it for its own ASC and enters
`Interrupted` at the contact time, including the late case in
[Timing](#timing). A player's chain needs nothing new: its `ResetChain`
already ends it.

During `Telegraph` the enemy has no registered step, so a player hit then
cannot interrupt it: `Interrupt` finds no step at the contact time. This is
the foundation's provisional behavior and an open #20 decision (see
[Open Decisions](#open-decisions)).

## Death and Reset

The controller binds the timeline's lethal notification for its own ASC. P2
adds the contact time to that notification:
`OnLethalResult(TargetAsc, ActivationId, ContactTime)`. #21 binds the same
notification; both are merged. #21's handler acts on players only and applies
nothing to an AI target
([Death and Respawn](death-and-respawn.md)), so the enemy's own state machine
is the only reader of an enemy's lethal result. The enemy enters `Dead` at the
lethal contact time, and its respawn delay runs from that time. The controller
does not apply `State.Dead`, which #21 owns for players, so `Reset` has none to
remove.

One exception: if the enemy stops being alive without a lethal result (for
example a test or a later effect sets Health to zero), the controller notices
it at the next pass start and enters `Dead` at that pass time.

After the pass's emission, `Reset` re-applies `ProvisionalInitialAttributes` with
`UAethelnAttributeInitEffect::ApplyTo`, the same path the AI base uses in
`BeginPlay`. It does not respawn a new actor: the pawn, its ASC, and its combat
identity stay, so no client sees a destroyed and re-created enemy.

## Replication

Position, result cues, and the presentation struct reach clients. Enemy Endurance and Guard do not. Enemy Health and MaxHealth follow the #61 decision ([comment](https://github.com/ShayShimoni/aetheln-online/issues/61#issuecomment-6131999614)): they replicate `COND_None` and reach every relevant client:

| Data | Path | Audience |
| --- | --- | --- |
| Position and rotation | Character movement replication | All relevant clients |
| Health and MaxHealth | The pawn's attribute set (Minimal mode replicates attributes, not effects); `COND_None` since the owner decision on #61 | All relevant clients |
| Endurance, Guard and their maxima | The same attribute set, `COND_OwnerOnly`; an AI pawn has no owning client | No client |
| Contact results | `MulticastCombatResultCue` on the target's ASC | All relevant clients |
| State and attack timing | `FAethelnEnemyPresentationState` on `AAethelnEnemyCharacter` | All relevant clients |

`FAethelnEnemyPresentationState` holds the state, its server start time, the
ability id and content version of the current step, the step start time, the
accepted aim, and a wrapping attack counter so a repeated attack replicates as
a change. The step fields are never cleared: they describe the most recent step in every state and are current only while `State` is `Attack`, so clients key on `State`. The server-owned `Telegraph` state and its start time are the tell;
clients derive wind-up, active, and recovery from the step start time and the
ability's configured windows, as observers of the player chain do. A reset
shows as `Idle` at home. Presentation never feeds back: no enemy class has a
server RPC, the AI controller does not exist on clients, and the ASC's stock
client routes are closed by #19.

## Server-Only Execution

- The controller is spawned only on the server (`AutoPossessAI` runs on
  authority), and the timeline pass that drives it does not run in a client
  world.
- `RegisterStep` already refuses a client world.
- The ability is never activated, so no GAS activation route exists for it.
- No enemy class declares a `Server`, `Client`, or `NetMulticast` function of
  its own; a reflection test pins this.

## Test Plan

Headless automation in `Source/GameTests`, beside the #60 tests, using the
same fixtures. Every test is written red first. Test names are under
`Aetheln.GameCombat.EnemyAI`.

| ID | Package | Covers |
| --- | --- | --- |
| E1 | P2 | Server-only execution (`ServerOnly`): a client-mode world never registers a step or changes state; the enemy classes declare no RPC; the controller's `bWantsPlayerState` is false and `FindForPawn` on the enemy returns its own ASC. |
| E2 | P2 | Grant validation and invalid commands (`ServerOnly`): an unset attack definition (the production class with its config cleared) grants nothing and the enemy never attacks; unset controller config decides nothing; the promoted production definition is granted once; `TryActivateAbility` on the enemy attack is refused; a refused `RegisterStep` returns the enemy to `Engage` with no sequence or counter advance. |
| E3 | P2 | Attack lifecycle (`AttackLifecycle`): telegraph, then a step registered at the exact telegraph end under an uneven frame, its contact at the authored time, recovery, and the next telegraph; the ended step is stamped and removed. |
| E4 | P2 | Interruption ordering (`Interruption`): a player hit inside the enemy step's interruptible window moves the enemy to `Interrupted` at the contact time and drops its later contacts; outside the window nothing changes; one notification per interruption; the late case, where one long frame takes the controller past recovery end and into a new step before the pass commits the earlier interruption, ends `Interrupted` at the contact time with the new step never started; a late interruption cancels a reset the controller decided in the same pass. |
| E5 | P2 | Death and reset (`DeathAndReset`): a lethal hit during wind-up kills the enemy at the contact time, its step makes no later contact, and at the contact time plus the respawn delay it is home with its initial attributes and no target; a player contact in the respawn pass resolves against the dead, pre-reset enemy; Health set to zero without a lethal result kills the enemy at the pass time; a late lethal result cancels a return reset decided in the same pass, with no heal and the respawn timed from the contact. |
| E6 | P2 | Two-player contention (`TargetChoice`): deterministic choice between equidistant players by `PlayerId`, whichever controller comes first; the current target stays while eligible; the other player is chosen when it dies. |
| E7 | P2 | Target loss (`TargetLoss`): leaving perception, pawn destruction, and leaving the leash during `Telegraph` each drop the target with no step registered, and the enemy resets home. |
| E8 | P2 | Presentation (`AttackLifecycle`, `ServerOnly`): the replicated state, counter, and step timing match the server state; the struct replicates. |
| E9 | P2 | Unreachable and invalid destinations (`Navigation`): a failed move request (no navigation data) moves `Engage` to `Return` and resets the enemy home. |
| E10 | P2 | Stuck recovery (`Navigation`): the pure policy repaths on the first `Blocked` or `OffPath` and resets on the second; other results change nothing. |
| E11 | P2 | Leash (`TargetLoss`): a target outside the leash is dropped, and the enemy returns home and is restored. |
| E12 | P3 | Real navmesh (`RealNavmesh`, `NavigationMeasurements`): a headless world with a built navigation mesh, because one builds (the test adds the navigation system as a map load does, then calls `Build()`). The enemy reaches a target across the floor, and stuck recovery acts on a real `Blocked` result: the first repaths, the second resets the enemy home. The fixture world does not run the scheduled ticks of the enemy's movement and path following components, so the test ticks both by hand (residual risk 4). |
| E13 | P3 | Two PIE clients against a dedicated server (`TwoClientEnemy`, `TwoClientEnemyImpaired`), on CQTest's generated map: both see the same enemy state and attack timing, public Health and MaxHealth, death and reset, and result cues, on a clean link. Under a fixture impairment (100 ms lag, 5 % loss) it requires the attack (not the telegraph), Health, death, and reset, and only bounds the cue count, which is unreliable. Not the #45 network profiles. |
| E14 | P4 | The prototype space (`PrototypeSpace`): the saved `MovementPOC` loads in the Editor world and holds one navigation bounds volume that covers the floor inside the walls, the player start, and the enemy; one static `RecastNavMesh` saved with built tiles; and one placed `AAethelnEnemyCharacter` that is the production class with the enemy controller class, possesses on spawn, and, begun by hand because a loaded Editor world does not begin play, has its home, its initial Health, and its granted attack. The enemy and the player start stand on the mesh, and a complete (not partial) path query joins them. The test never saves the map. An Editor-loaded world does not initialise its actors, so the test also runs the component initialisation a game world performs before it spawns the controller, and it requires, and so ignores, the engine's `UCrowdManager` teardown warning that a world holding a built `RecastNavMesh` logs when it is replaced; any other warning still fails it. |
| C1 | P3 | Config (`ProvisionalConfig`): every promoted value is in `Config/DefaultGame.ini` and reaches the class defaults. |

## Measurements

Recorded for [#45](https://github.com/ShayShimoni/aetheln-online/issues/45) by
P3. They set no budget, threshold, or population assumption, and no test passes
or fails on them. They come from `NavigationMeasurements`, which logs lines
starting with `AETHELN_MEASURE`, on a developer machine (Intel Core i7-9750H,
6 cores, Windows 11) in the Unreal Editor's headless automation world: no
rendering, no networking, one player, one enemy, the fixture arena of E12 (a
3000 by 1000 unit floor under one `NavMeshBoundsVolume`), the engine's default
navigation agent (radius 35), and static runtime generation.

| What | Value |
| --- | --- |
| Navigation system added to the world and mesh built, wall time | 2.6 to 10.2 ms over three runs |
| Tiles in the mesh, and tiles holding data | 24, and 8 |
| Memory the mesh reports (`LogMemUsed`) | 4160 bytes |
| World tick, no enemy, 300 frames of 1/60 s | average 38 to 45 microseconds, worst 0.7 to 1.4 ms |
| World tick, one enemy engaging one player, 300 frames | average 72 to 89 microseconds, worst 0.3 to 1.8 ms |

The tick figures include the hand tick of the enemy's movement and path
following components (see E12), the timeline pass, and the controller's
decisions. They say nothing about a real map, several enemies, a client load, or a
packaged server; #45 owns those. The raw logs are in the issue's delivery
evidence (`issue-83-p3`).

### MovementPOC mesh (P4)

Recorded by P4 on the same machine, from the authoring commandlet's
`AETHELN_MEASURE` line (headless Editor, no rendering). The map is the 6000 unit
square course (`NavMeshBoundsVolume` of 6000 by 6000 by 600 units), the engine's
default agent (radius 35), static runtime generation. These are measurements, not
budgets.

| What | Value |
| --- | --- |
| Navigation build, wall time | 43.0 ms |
| Tiles in the mesh, and tiles holding data | 147, and 40 |

The raw logs are in the issue's delivery evidence (`issue-83-p4`).

## Acceptance-Criteria Mapping

| #83 criterion | Covered by |
| --- | --- |
| Server owns perception, navigation, transitions, eligibility, attack selection, timing, damage, death, and reset | State machine, timing, eligibility, navigation; E1, E3, E5, E7, E9-E11 |
| Reviewed AI approach selected from measured needs | TA-026 derives the needs from the documents and the code, and P3 records the first measurements ([Measurements](#measurements)): navmesh build time and size, and the server tick cost with one enemy. The box is the owner's to check; no candidate framework was timed against the state machine. |
| Navmesh, runtime constraints, spawn and reset boundaries, stuck recovery, invalid destinations specified | [Navigation](#navigation) |
| Readable telegraph, wind-up, active, recovery, interruption, death, and reset states without notifies | State machine and replication; E3, E4, E5, E8 |
| Minimum replication; clients cannot drive AI or contact | [Replication](#replication), [Server-Only Execution](#server-only-execution); E1, E8 |
| Tests for target loss, unreachable paths, invalid commands, interruption ordering, death and reset, two-player contention, server-only execution | E1-E11 |
| DoD: one greybox enemy navigates and attacks in the prototype space | On the provisional values: E12 (headless arena) and E13 in P3, and in P4 the enemy, the bounds volume, and the built mesh in `MovementPOC.umap` itself (E14). E14 does not show the enemy moving or attacking in `MovementPOC`; that is a later evidence item. The box stays open until a post-merge QA round on the `develop` revision shows the enemy navigating and attacking there, never because P4 merged. That round needs the #107 player values applied by the issue that owns them, or a recorded fixture method: in a real session the enemy stays Idle until the player initial attributes exist (open decision 10). |
| DoD: focused automation and repeatable multiplayer evidence | E1-E14 |
| DoD: budgets stay with #45 | Measurements only, P3 |

## Phased Delivery

1. **P1** (this document): design, TA-026, index link. Docs only.
2. **P2**: enemy character, enemy attack ability, the timeline notifications,
   the controller state machine, eligibility and target choice, navigation
   behavior (failed and partial paths, stuck recovery, leash return), death
   and reset, presentation state, the ability's semantic ID and mapping row,
   and tests E1 to E11.
3. **P3**: the provisional values in config, real-navmesh and two-client
   evidence (E12, E13), and measurements for #45. E13 needs clients to see enemy
   Health: the #61 change already provides it, so P3 needs no replication
   change. The navmesh volume and the enemy in `MovementPOC.umap` moved to P4.
4. **P4, prototype space in the map**: a `NavMeshBoundsVolume`, a built
   `RecastNavMesh`, and the placed enemy in `MovementPOC.umap`, saved under the LFS
   lock by the headless authoring commandlet, E14, the registry update, and the
   #120 map-change review (see [Navigation](#navigation)). The lead deferred it
   from P3 to this named package, a delivery-order decision under the standing
   lead authority
   ([PR 355 review](https://github.com/ShayShimoni/aetheln-online/pull/355#issuecomment-6158560412));
   the owner's choice of `MovementPOC` is unchanged. P4 does not close the DoD
   box for the enemy in the prototype space: E14 does not show the enemy moving
   or attacking in `MovementPOC`, and the box stays open until a post-merge QA
   round on `develop` does (see the mapping above).

## Open Decisions

All stay `TBD` as tuning until the named owner decides. Items 1 to 3 have
owner-approved provisional values in config (decision 1 on
[#83](https://github.com/ShayShimoni/aetheln-online/issues/83#issuecomment-6156988023)),
which the feel test re-tunes.

1. **Enemy step values:** windows, shape, damage, Guard pressure, interruptible
   window, whether it interrupts, sampling bounds (#107, #45). Provisional.
2. **Enemy behavior values:** `ProvisionalTelegraphSeconds`,
   `ProvisionalInterruptedSeconds`, `ProvisionalRespawnSeconds`,
   `ProvisionalAttackRange`, `ProvisionalPerceptionRadius`,
   `ProvisionalLeashRadius` (#107, #45). Provisional. The strike's reach is the
   path end plus the shape radius plus the target capsule radius, which is less
   than the provisional attack range, so an enemy that stops at the edge of that
   range swings and misses; the feel test decides which value moves.
3. **Enemy initial attributes** (#107; `TBD` on the AI base, provisional on
   `AAethelnEnemyCharacter`).
4. **Target rule** (#20): the provisional rule above, or another.
5. **Interrupted enemy behavior** (#20): the foundation pauses for an authored
   time, then re-engages.
6. **Hits during the telegraph** (#20): the foundation's provisional behavior
   is that a hit during `Telegraph` cannot interrupt the enemy, because no step
   is registered yet. The alternative is that such a hit cancels the telegraph.
7. **Return behavior** (#20): whether a returning enemy can be hit, and whether
   it heals on return.
8. **Prototype space:** resolved. `MovementPOC` (owner decision on #83). Whether
   `ServerDefaultMap` follows is a separate decision.
9. **Navigation data in the client cook** (#120).
10. **Player initial attributes** (#107): decided by the owner as provisional
    values on
    [#107](https://github.com/ShayShimoni/aetheln-online/issues/107#issuecomment-6176507597)
    (2026-10-14); this document does not restate them. They are not applied yet:
    `AAethelnPlayerState` stays at zero in config, and P4 applies nothing because
    E14 needs no live player. The config change stays with the issue that owns the
    player attribute defaults. An eligible target needs Health above zero, so until
    that change lands the enemy placed in `MovementPOC` stands Idle at home and
    targets no real player. E13 applies fixture values by hand. The interactive
    two-client run waits on it.
11. **`MovementPOC` audience** (#120): the registry lists the map as
    `client_only`, which was true while it held only client-side course
    geometry. It now carries navigation data and a server-driven enemy, and
    `ServerDefaultMap` is still `StarterMap`. Whether the audience changes, and
    when, is #120's decision with the `ServerDefaultMap` one.

## Residual Risks

1. No line of sight: an arena with cover needs a check, for both perception and
   contacts.
2. `ChainStep = 1` for every enemy step reuses a player-chain field.
3. The state machine is code, so new enemy behavior needs a programmer. TA-026
   names when to revisit.
4. The headless fixture world has no navigation by default; E12 adds it. The
   arena there is fixture geometry, not `MovementPOC`. In that world the
   scheduled ticks of the enemy's movement and path following components never
   run (the cause is not found; a plain tick function does run), so E12 ticks
   both by hand. No automated test walks an enemy under its scheduled ticks:
   E13 runs in a real PIE world but holds the enemy still on a floorless map.
5. An enemy whose every path request fails resets at most once per pass while
   a target stays eligible. E9 still shows this with no navigation data; the
   built-mesh run (E12) reaches its target and shows no such fast loop, so P3
   adds no back-off. `MovementPOC` now has a built mesh (P4), so on that map a
   target on the mesh draws no failed request; the fast case remains only on a
   map with no navigation data, where no enemy is placed. A slower cycle remains where a target stays eligible behind
   an obstacle the mesh does not know: the enemy is blocked, repaths, is blocked,
   resets home, then Idle engages again, once per block-detection window (about
   5 s each). Whether that needs a back-off or a different give-up is a #20
   behavior to decide, with #45.
6. Several enemies advance in the order they bound to the pass. Their steps'
   ordinals follow that order, which decides exact-time ties.
7. `MovementPOC.umap` carries the `NavMeshBoundsVolume`, the built
   `RecastNavMesh`, and the placed enemy since P4, but `ServerDefaultMap` still
   names `StarterMap`, so a dedicated server does not load the map by default;
   E13 runs on CQTest's generated map. The #120 `navigation` family stays
   `non_promotion` (see [#120 review of the map change](#120-review-of-the-map-change)).
   On a built mesh a target between the attack range and the perception radius
   draws no fast failed-path loop (E12); Risk 5 records the slower blocked-and-reset
   cycle that remains.
