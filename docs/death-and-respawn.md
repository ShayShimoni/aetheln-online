# Death, Respawn, and Reconnect

## Document Status

This is the implementation specification for
[Issue #21](https://github.com/ShayShimoni/aetheln-online/issues/21): a player
can die, respawn, and rejoin combat safely. Pull requests P1 to P4 deliver it
(see [Phased Delivery](#phased-delivery)). P1 added this document and the
server-side death state. P2 adds the server respawn. P3 and P4 are design only
until their pull requests land.

It is subordinate to
[Combat and Networking Architecture](combat-and-networking-architecture.md)
(Death, Logout, and Recovery Safety; Failure and Recovery) and the canonical
product documents, and it changes no product rule. It consumes the
`State.Dead` handoff in [Gameplay Ability System Foundation](gas-foundation.md)
(Lifecycle, Handoff to #21), the lethal notification in
[Attack Timeline and Three-Hit Combo](attack-timeline-and-combo.md) (Lethal
results), and the `State.Dead` bindings in [Dodge and Block](dodge-and-block.md)
(Disconnect, life state, and missing presentation). The owner set the respawn
delay, the restored values, the respawn location rule, the corpse rule, and the
dead camera rule on 2026-10-12
([issue #21 comment](https://github.com/ShayShimoni/aetheln-online/issues/21#issuecomment-6131998770)).
Every value is provisional, owner-set, and re-tuned at the P5 feel test, and a
`Provisional...` config key is a named placeholder, never final tuning. The
disconnect grace window (15 s, provisional) is P4's. C++ names for P3 and P4 are
proposed code names until their phase lands.

**Citations.** Repository `path:line` citations are valid at `develop`
revision `89a2111e`; the P2 code is cited by name, because it landed after that
revision. Engine citations are relative to the root of the pinned
UE 5.8.1 source, revision `71fe36aac5`. `GAS/` abbreviates
`Engine/Plugins/Runtime/GameplayAbilities/Source/GameplayAbilities/`,
`CMC.cpp` abbreviates
`Engine/Source/Runtime/Engine/Private/Components/CharacterMovementComponent.cpp`,
and `GM.cpp` abbreviates `Engine/Source/Runtime/Engine/Private/GameModeBase.cpp`.

## Decisions at a Glance

1. **One server-owned death transition per life.** The lethal notification
   (`UAethelnCombatTimelineSubsystem::OnLethalResult`) is the only trigger in
   P1. The transition re-reads authoritative Health and refuses a target whose
   Health is above zero. A target that already has `State.Dead` is a no-op, so
   repeated notifications cannot emit a second death.
2. **`State.Dead` comes from an effect, never a loose tag.** The combat
   document lets only server-owned effects or abilities of the owning issue
   apply a `State.<Name>` tag. `UAethelnDeathStateEffect` is infinite and grants
   `State.Dead` through the spec's dynamic granted tags, as the Guard break
   does (`Source/GameCombat/Private/AethelnBlockAbility.cpp:115-120`).
3. **Refusal reuses the existing bindings.** `State.Dead` already blocks every
   ability (`Source/GameCombat/Private/AethelnGameplayAbility.cpp:17`), resets
   the chain with `IncompatibleState`
   (`Source/GameCombat/Private/AethelnBasicChainAbility.cpp:11`), ends the
   dodge window and the block (`AethelnAbilitySystemComponent.cpp:870`,
   `AethelnBlockAbility.cpp:88`), and makes the target and the attacker not
   alive for contacts (`AethelnCombatTimelineSubsystem.cpp:60-67`). The death
   transition adds only what tags do not cover: it cancels every other active
   ability and stops movement.
4. **Movement stops on the server.** The transition calls `DisableMovement()`
   on the avatar's movement component (`CMC.cpp:2759-2770`). In `MOVE_None` the
   server's `PerformMovement` moves nothing (`CMC.cpp:2791`) and kills velocity
   (`CMC.cpp:1474-1479`). The owning client's later moves get corrections that
   carry the server movement mode, so the client converges. A client-side
   input block is presentation only and is not needed for authority.
5. **Players only.** The transition refuses an ASC whose owner is not a
   `PlayerState`. AI death belongs to
   [#20](https://github.com/ShayShimoni/aetheln-online/issues/20), not #21
   (lead decision, 2026-10-12). #21 applies nothing to an AI target. The #83
   enemy controller enters its own Dead state on the lethal notification
   without `State.Dead`, and AI death as a life state stays #20's.
6. **Respawn fails closed.** P2 respawns only when the delay is configured and
   valid and the server can restart the player (a controller, a game mode with a
   pawn class, and a maximum Health above zero). Otherwise the player stays dead
   and the server logs why. The restored values are the owner's decision (full
   Health, Endurance and Guard, provisional) and are fixed in the restoration
   effect, not config. Whether that fixed set is the declared lifecycle allowlist
   the canonical technical documents describe is an open owner decision (see
   [Open Decisions](#open-decisions)). No value is invented.
7. **Reconnect uses a carried snapshot, not PlayerState reuse.** The combat
   game mode stays on `AGameModeBase`, so a reconnect gets a fresh PlayerState
   (`Source/GameCombat/Public/AethelnCombatGameMode.h:10-17`). P4 keeps a
   server-side snapshot keyed by a stable player identity for the disconnect
   grace window (15 s, provisional and owner-set, see
   [Open Decisions](#open-decisions)) and applies it in place of initial
   attributes.

## Scope and Boundaries

| Owner | #21 does | #21 does not |
| --- | --- | --- |
| [#19](https://github.com/ShayShimoni/aetheln-online/issues/19) | Applies and removes `State.Dead`; owns the restoration allowlist and the reconnect carried state (closes T34). | Change the grant-once rule, the seam, or the avatar lifecycle. |
| [#60](https://github.com/ShayShimoni/aetheln-online/issues/60) | Binds `OnLethalResult`. | Change the lethal latch, the contact order, or the chain reset rules, except one: a death from a lethal contact ends the chain at the lethal contact time (the stamp that #60's A28 row deferred to #21 P2). |
| [#18](https://github.com/ShayShimoni/aetheln-online/issues/18) | Tests the integrated death case on top of #18's `State.Dead` bindings. | Change dodge or block cancellation. |
| [#20](https://github.com/ShayShimoni/aetheln-online/issues/20) | Nothing. | AI death and despawn (owned by #20), and AI attacks that kill a player. |
| [#83](https://github.com/ShayShimoni/aetheln-online/issues/83) | Nothing. | Apply `State.Dead`. #83 binds the same `OnLethalResult` and owned its signature change (the `ContactTime` parameter, merged in its P2, `docs/enemy-ai-and-navigation.md:356-363`). P1's handler took the three-argument form and ignored `ContactTime`; P2 uses it for the chain reset. |
| [#61](https://github.com/ShayShimoni/aetheln-online/issues/61) | Raises the authoritative death state that presentation reads. | HUD, death screen, and readability of the death cue. |

## Server Death Transition (P1, extended by P2)

`UAethelnDeathSubsystem` is a server-only `UWorldSubsystem` in GameCombat. It
uses the timeline's creation rule (Game and PIE worlds, not a client) and
binds `OnLethalResult` once in `Initialize`. The handler forwards to
`UAethelnDeathSubsystem::ApplyDeath(Victim, ActivationId, ContactTime)`, which:

1. Refuses unless the ASC's owner is authoritative and a `PlayerState`, the
   victim has no `State.Dead`, and its Health attribute exists and is zero or
   below.
2. (P2) For a death from a contact, ends the chain with `IncompatibleState`,
   stamped at the lethal contact time `C` from `OnLethalResult`
   (`ResetChain(IncompatibleState, C)`). A death with no contact (see
   [Follow-ups](#follow-ups)) has no `C`, and the chain ends at the processing
   time in step 3.
3. Applies `UAethelnDeathStateEffect`. The tag event ends any remaining chain
   (`IncompatibleState`), the dodge window, and the block at the processing
   time, before step 4.
4. Calls `CancelAllAbilities()` for any other active ability.
5. Calls `DisableMovement()` on the avatar's character movement.
6. (P2) Starts the respawn wait (see [Respawn](#respawn-p2)): a server life
   generation, the `Death` event, and the respawn deadline.

The emission loop that raises the notification iterates a local array of
committed results (`AethelnCombatTimelineSubsystem.cpp:234-235`, `:246`), and a
chain reset only stamps a reset time (`:144-151`), so the synchronous
transition does not invalidate the timeline's iteration. Since #60 P5
([PR #321](https://github.com/ShayShimoni/aetheln-online/pull/321)), the pass
sends held buffered-start records before emission, and interruption never runs
for a lethal target. A death raised during emission therefore finds no held
record, and its chain reset sends exactly one chain end.

**A buffered step that starts after the lethal contact.** A buffered step whose
start `B` falls in `C < B <= Now` still starts in pass step 1, and the pass
sends its held activation record to the owning client in step 5, before
emission raises `OnLethalResult`. That record is accepted and
presentation-only: no gameplay truth leaks, because the victim's contacts after
`C` fail `IsAlive` (Health is already zero). An interruption would drop the
record, because it stamps its reset at the contact time
([A28](attack-timeline-and-combo.md), interruption row). P1 reset the chain at
the processing time `Now`. P2 resets it at `C`, with the `ContactTime` that
#83 P2 added to `OnLethalResult`, so the chain's reset time and its current
step in the timeline are stamped at `C`, as an interruption stamps them. It does
not cancel the start: the record is already sent when the notification arrives.
Cancelling it would mean raising the lethal notification before the pass sends
held records, a change to the timeline's emission order that belongs to #60;
see [Residual Limitations](#residual-limitations). The lethal row of A28 records
the case.

**Replication.** The player ASC uses Mixed replication. The owning client gets
the death effect; every other client gets `State.Dead` as a minimal
replicated tag (`GAS/Private/GameplayEffect.cpp:3733-3736`, `:4663-4664`).
Health stays owner-only. P3 proves this with two clients.

**What death keeps.** Granted abilities, cooldown effects, and attribute
values stay. The Guard break ends on `State.Dead`
(`AethelnBlockAbility.cpp:121-126`, `:146`). Recovery delay effects (the
Endurance and Guard recovery delays) also persist through death under the
current default, in which a running delay keeps counting on the server clock
(`gas-foundation.md:402-404`); whether death removes a running delay is open
(see [Open Decisions](#open-decisions)) and stays `TBD`. Respawn restores only
Health, Endurance, and Guard (see [Respawn](#respawn-p2)).

## Respawn (P2)

The owner decisions below are provisional, owner-set, and re-tuned at the P5
feel test ([issue #21 comment](https://github.com/ShayShimoni/aetheln-online/issues/21#issuecomment-6131998770),
2026-10-12).

- **Server-owned wait.** The server stores a respawn deadline, the world time of
  the death plus `ProvisionalRespawnDelaySeconds` (owner-set, 5 s;
  `Config/DefaultGame.ini`, `[/Script/GameCombat.AethelnDeathSubsystem]`). The
  subsystem checks the deadlines in the world's post-actor tick, as the timeline
  does, on the world clock and in death order. A `FTimerManager` timer would
  tick at most once per engine frame, and a deadline also carries over to P4's
  snapshot. Unset (0), negative, or non-finite means no automatic respawn: the
  player stays dead and the server logs the reason. The client never requests or
  times a respawn.
- **One respawn per death.** Each death gets a server life generation (a
  counter in the subsystem; it is also the `Death` event's sequence). The wait
  is one entry per ASC, a new death replaces it, and it is removed when it
  fires, so a duplicate, a retry, or a request for a living player cannot respawn
  twice. `UAethelnDeathSubsystem::Respawn` refuses silently unless the ASC is a
  dead player's.
- **Fail closed.** `Respawn` leaves the player dead, and logs why, when the
  player has no controller, the world has no game mode, the game mode has no
  pawn class, or the maximum Health is not above zero (a restored Health of zero
  would make a living avatar with no Health). It checks all of this before it
  changes anything.
- **Order.** Unpossess the dead pawn, so #19's null-pawn path runs (chain
  `AvatarLost`, dodge cancel, `CancelAllAbilities`, avatar cleared) and the seam
  stays closed until the new avatar is possessed. Destroy the dead pawn. Apply
  `UAethelnRespawnRestorationEffect`, remove `UAethelnDeathStateEffect`, and then
  call the game mode's `RestartPlayer`, which spawns the game mode's default
  pawn at the start spot and possesses it. A living avatar therefore never
  exists with zero Health.
- **Restoration.** One instant `UAethelnRespawnRestorationEffect` overrides
  Health, Endurance, and Guard with the target's own maximum (an attribute-based
  magnitude on the Max attribute, so it needs no config and no tag). The maxima,
  the granted abilities (#19's flag holds), and the cooldown effects are not
  touched: death is not a cooldown reset, and a cooldown keeps counting through
  death and respawn. Recovery effects resume when `State.Dead` is removed.
- **Location.** The game mode's start selection. `AGameModeBase` keeps the
  start spot it chose at login (`GM.cpp:838-848`, `:1142-1144`, `:1167-1173`) and
  `RestartPlayer` uses it (`GM.cpp:1241-1261`), so the prototype respawns at the
  map's start point. The owner's rule is the nearest server-authoritative
  sanctuary or start point for the player's faction. Nearest-sanctuary needs the
  faction and sanctuary systems, so it stays `TBD` until they exist; no
  respawn point is invented.
- **Corpse.** The dead pawn is kept only during the delay, then destroyed.
  There is no loot on the body.
- **Dead camera.** While dead the controller keeps the dead pawn, so the view
  target stays on it and the server enters no spectator state. A client-side
  look lock and the respawn countdown are presentation (see
  [Residual Limitations](#residual-limitations)).
- **Stale state.** After respawn, tests check that no activation, chain,
  dodge window, invulnerability, Guard break, death effect, pawn reference, or
  already-hit record from the previous life remains (DoD3).
- **Telemetry.** A death emits one `Death` observability event
  (`EAethelnObservabilityCategory::Death`) with the lethal activation id as its
  correlation, no connection or player identity, and the life generation as its
  sequence, the way the timeline emits a hit. A death with no contact has no
  activation id. A missing sink changes no gameplay.

## Two-Player Replication and Feedback (P3, design)

- Two clients on the loopback network harness: player A dies, and both the
  owner and player B observe `State.Dead`; A's movement is corrected to
  `MOVE_None`; a respawn reaches both clients as a new avatar without
  `State.Dead`.
- A presentation-only death cue on the victim's ASC, as the result cue does.
  Losing it loses nothing authoritative. #61 owns the HUD.
- One run under simulated latency and packet loss.

## Reconnect and Carried State (P4, design)

T34 (`Aetheln.GameCombat.Lifecycle.ReconnectInterimGap`,
`Source/GameTests/Private/AethelnAbilityLifecycleTests.cpp:375-419`) pins
today's gap: a reconnect gets a fresh PlayerState, refilled attributes, no
effects, and a second grant. P4 closes it:

- On logout, the server stores a snapshot keyed by a stable player identity:
  attribute values, remaining cooldowns, the life state, the life generation,
  and the respawn deadline. It expires after the disconnect grace window
  (15 s, provisional and owner-set, issue #21 comment 6131998770; the combat
  document's general safe-logout and disconnect durations stay `TBD`).
- On login, a matching unexpired snapshot replaces the initial-attribute step
  for the fresh PlayerState. Abilities are granted once on the new
  PlayerState, as #19 requires.
- The identity key goes through an adapter (AGENTS.md: vendors stay behind
  adapters). P4 chooses the prototype identity key (lead decision, 2026-10-12).

### Disconnect edge cases

| Case | Resolved state |
| --- | --- |
| Disconnect while alive | Snapshot carries current values; reconnect is not a refill. |
| Disconnect while dead, reconnect before the deadline | Dead, with the same deadline and generation. |
| Disconnect while dead, deadline passes while away | Respawn waits for the reconnect; the player respawns once, through the normal order. |
| Disconnect during the respawn step | The respawn completes or does not start on the server; the reconnect sees one state, never both. |
| Reconnect after the grace window | No snapshot: treated as a new session under the persistence policy. |
| Lethal result while the connection is gone | The death transition runs; the avatar is server state, so disconnect is no escape. |

## Test Plan

| ID | Test | Phase | Proves |
| --- | --- | --- | --- |
| R1 | `Aetheln.GameCombat.Death.LethalNotificationAppliesDeath` | P1 | A lethal notification for a zero-Health player applies one death effect and one `State.Dead`; a repeat adds nothing; a living player and an AI target get no death state |
| R2 | `Aetheln.GameCombat.Death.DeadPlayerRefusesActions` | P1 | Death mid-chain ends the chain once with `IncompatibleState`, resolves no later contact, refuses the next press with `ActivationBlocked`, and sets the avatar's movement to `MOVE_None` |
| R3 | `Aetheln.GameCombat.Death.RespawnFailsClosed` | P2 | The ini delay is finite and positive; an unset, negative, or non-finite delay, a world with no game mode, and a maximum Health of zero each keep the player dead, with one logged refusal and no retry |
| R4 | `Aetheln.GameCombat.Death.RespawnAfterDelay` | P2 | No respawn before the deadline (death time plus the delay); then `State.Dead` and the death effect are gone, Health, Endurance, and Guard equal their maxima and the maxima did not move, a new pawn is the avatar and the corpse is destroyed, no ability is granted again, a cooldown keeps counting, no chain, dodge window, or other state from the previous life remains, one chain end overall, a second respawn is refused, and the player starts a chain again. The chain reset is stamped at the lethal contact time |
| R5 | Two-client death and respawn | P3 | AC2 and DoD1 |
| R6 | Reconnect while alive, dead, and respawning | P4 | AC5; T34 flips |
| R7 | `Aetheln.GameCombat.Death.GuardBreakThenDeath` | P2 | A real Guard break with a running chain, then death: the break effect and tag are gone, Guard stays zero and its recovery is kept and paused, one death effect, and the chain ends once as `IncompatibleState` |
| R8 | `Aetheln.GameCombat.Death.RespawnRefusesNonDeadAndNonPlayer` | P2 | A living player and a dead AI (`State.Dead` and zero Health, no `PlayerState` owner) are refused with nothing changed; a death from `ApplyDeath` with no contact starts the same wait and the same single respawn |
| R9 | `Aetheln.GameCombat.Death.LethalContactThenRespawn` | P2 | The real lethal path: an enemy swing kills the player, the chain reset is stamped at the committed result's contact time, one chain end, and the respawn follows the delay |
| R10 | `Aetheln.GameCombat.Death.DeathTelemetry` | P2 | One `Death` event per death with the lethal activation id, the life generation as its sequence, no identity, and no event for a repeated notification |

Dodge and block refusal while dead is already covered by D13
(`Aetheln.GameCombat.Defense.LifeStateCancelsDefense`), which reacts to the same
tag event. The real lethal path, an AI swing that kills the player through the
contact pipeline, is the lethal row of
`Aetheln.GameCombat.AttackTimeline.Interruption` (#60 P5): since P1 the player
dies, and death, not interruption, ends the chain once as `IncompatibleState`.

## Acceptance-Criteria Mapping

| Criterion | Phase |
| --- | --- |
| Server determines death from authoritative health | P1 (R1) |
| Death state and feedback replicate to all relevant clients | P1 server state on a replicated effect; P3 two-client proof and cue (R5) |
| Dead players cannot move or attack, and death/respawn cannot emit duplicate completion events | P1 death half (R1, R2); P2 respawn half (R3, R4, R8) |
| Respawn restores only intended attributes and abilities | P2 (R4) |
| Reconnect during death or respawn resolves to one valid state | P4 (R6) |
| DoD: two-player death and respawn paths are tested | P3 (R5) |
| DoD: disconnect edge cases are documented | P1 table above; P4 verifies (R6) |
| DoD: no stale activation, tag, effect, pawn reference, invulnerability, or already-hit state | P1 at death (R2); P2 after respawn (R4) |

## Phased Delivery

| Phase | Content | Depends on |
| --- | --- | --- |
| **P1** Death state | This document; `UAethelnDeathStateEffect`; `UAethelnDeathSubsystem`; R1, R2. | #60 P4 lethal notification (merged) |
| **P2** Respawn (delivered) | The delay config, life generation, restart order, restoration effect; R3, R4, R8, R9. A `Death` observability event (`EAethelnObservabilityCategory::Death`, `observability-and-crash-diagnostics.md:21`) with the activation id as correlation, as `Emit` does for hits (R10); the Guard-break-at-death row R7; the lethal-contact-time chain reset using `ContactTime` from `OnLethalResult`. | P1; the owner decisions of 2026-10-12 on delay, restoration, location, dead pawn, and camera |
| **P3** Replication | Two-client harness run, death cue; R5. | P2 |
| **P4** Reconnect | Carried snapshot behind an identity adapter; R6; T34 flipped. | P2; P4 chooses the identity key and implements the owner's 15 s provisional grace window |

## Open Decisions

Owner decisions of 2026-10-12, recorded on
[issue #21](https://github.com/ShayShimoni/aetheln-online/issues/21#issuecomment-6131998770).
All are provisional and owner-set, and are re-tuned at the P5 feel test:

- **Respawn delay:** `ProvisionalRespawnDelaySeconds` = 5 s.
- **Restoration:** full Health, Endurance, and Guard on respawn. Cooldowns keep
  counting: death is not a cooldown reset.
- **Respawn location:** the nearest server-authoritative sanctuary or start point
  for the player's faction. The prototype uses the game mode's start spot (see
  [Respawn](#respawn-p2)); the nearest-sanctuary rule is `TBD` until the faction
  and sanctuary systems exist.
- **Dead pawn:** a corpse only during the delay (the same 5 s), then destroyed.
  No loot on the body.
- **Dead camera:** the camera stays on the dead pawn, locked. No input is
  accepted, and the HUD shows the respawn countdown. No spectate in P2.
- **Disconnect grace window:** 15 s, provisional. The pawn stays in the world,
  server-controlled and attackable, and the player resumes it on reconnect. P4
  implements it.

Still open for the owner:

- Whether death removes a running recovery delay (#21, listed in
  `gas-foundation.md:1211`). P1 keeps the current default: the delay persists.
- Whether the owner's restoration (full Health, Endurance, and Guard) is the
  declared lifecycle allowlist that the canonical technical documents describe
  (`combat-and-networking-architecture.md:68` and `:270`, `gas-foundation.md:268`),
  or whether a separate allowlist declaration is wanted. P2 implements the three
  resources as a fixed set in the restoration effect, adds no allowlist config,
  and changes no canonical document.

Lead decisions (2026-10-12):

- **AI death is #20's.** #21 stays player-only. When #20 applies a death state
  to AI, `Aetheln.GameCombat.AttackTimeline.DamageAndLethalLatch`, which
  asserts that no other effect reaches the AI target, needs updating.
- **The reconnect identity key is decided in P4**, behind the identity
  adapter. P1 needs nothing for it.

## Residual Limitations

- **Activation record after the lethal contact.** See the buffered-step
  paragraph in Server Death Transition. Accepted and presentation-only. P2's
  reset at the contact time does not cancel the record, because the pass has
  already sent it. Cancelling it needs the lethal notification before the
  pass's held-record send, which changes #60's emission order and is not part
  of #21.
- **Recovery delay through death.** A running delay persists under the current
  default; the decision stays `TBD`.
- **Production initial attributes are all zero** (`ProvisionalInitialAttributes`,
  `TBD` until #107). Until they are set, a real server's maximum Health is zero,
  so a death there stays a death: the respawn refuses and logs, by design (see
  Respawn, Fail closed).
- **Guard break active at death** is covered by R7 (the break effect is removed
  while the death effect is applied, from `HandleDeadDuringBreak`,
  `AethelnBlockAbility.cpp:146`).
- **Dead camera and countdown are presentation, not in P2.** The server keeps
  the dead pawn possessed and enters no spectator state. A client-side look lock
  and the HUD countdown need the respawn deadline on the owning client, which
  the server does not replicate yet: the HUD's timed list reads active effects,
  and the death effect is infinite. #61 and P3 decide how the deadline reaches
  the owner (for example a replicated deadline or a timed effect). No value is
  invented here.
- **No `Respawn` event.** P2 emits `Death` only, as this spec's phased delivery
  assigns (the issue itself names no observability event). The `Respawn`
  category exists (`observability-and-crash-diagnostics.md:21`) and can be wired
  with P3's feedback.
- **A failed restart after the restore.** If the game mode cannot spawn a pawn
  after the checks pass, `Respawn` logs an error and returns false with the
  player alive and without a pawn (the seam rejects with `ConnectionClosed`).
  The checks make this unlikely, and the pawn spawn that remains is the
  engine's.
- **Respawn is not delayed for a disconnected player.** With the AGameModeBase
  base class, a logout normally destroys the controller and its PlayerState, so
  the wait's weak key goes invalid and the wait is dropped without a log. A
  PlayerState that outlives its controller reaches `Respawn`, which refuses and
  logs "no controller". P4's snapshot carries the deadline across a reconnect.
  Neither path is tested in P2.
- **Untested P2 paths.** No test covers the no-controller and no-pawn-class
  refusals, the error after `RestartPlayer` (no pawn), the death-order sort, two
  players due in one tick, or a second death after a respawn (life generation
  2 and its `Death` event sequence).

## Follow-ups

- **Non-contact death.** Death sources other than a contact, such as periodic
  effects later, are not wired yet. They enter death through the same public
  entry point, `UAethelnDeathSubsystem::ApplyDeath(Victim)`, with no activation
  id and no contact time. It stays callable from any server code, keeps the same
  refusal rules, and starts the same respawn wait (R8).
