# Death, Respawn, and Reconnect

## Document Status

This is the implementation specification for
[Issue #21](https://github.com/ShayShimoni/aetheln-online/issues/21): a player
can die, respawn, and rejoin combat safely. Pull requests P1 to P4 deliver it
(see [Phased Delivery](#phased-delivery)). P1 adds this document and the
server-side death state. P2 to P4 are design only until their pull requests
land.

It is subordinate to
[Combat and Networking Architecture](combat-and-networking-architecture.md)
(Death, Logout, and Recovery Safety; Failure and Recovery) and the canonical
product documents, and it changes no product rule. It consumes the
`State.Dead` handoff in [Gameplay Ability System Foundation](gas-foundation.md)
(Lifecycle, Handoff to #21), the lethal notification in
[Attack Timeline and Three-Hit Combo](attack-timeline-and-combo.md) (Lethal
results), and the `State.Dead` bindings in [Dodge and Block](dodge-and-block.md)
(Disconnect, life state, and missing presentation). The respawn delay, the
restored values, the respawn location, and the disconnect grace window stay
`TBD`; a `Provisional...` config key is a named placeholder, never tuning.
C++ names are proposed code names until their phase lands.

**Citations.** Repository `path:line` citations are valid at `develop`
revision `b55dad2`. Engine citations are relative to the root of the pinned
UE 5.8.1 source, revision `71fe36aac5`. `GAS/` abbreviates
`Engine/Plugins/Runtime/GameplayAbilities/Source/GameplayAbilities/` and
`CMC.cpp` abbreviates
`Engine/Source/Runtime/Engine/Private/Components/CharacterMovementComponent.cpp`.

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
   does (`Source/GameCombat/Private/AethelnBlockAbility.cpp:113-118`).
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
5. **Players only in P1.** The transition refuses an ASC whose owner is not a
   `PlayerState`. A zero-Health AI target stays inert, as it is today (see
   [Open Decisions](#open-decisions)).
6. **Respawn and restored values fail closed.** P2 respawns only when both the
   delay and the restoration allowlist are configured and valid. With either
   unset, the player stays dead and the server logs why. No value is invented.
7. **Reconnect uses a carried snapshot, not PlayerState reuse.** The combat
   game mode stays on `AGameModeBase`, so a reconnect gets a fresh PlayerState
   (`Source/GameCombat/Public/AethelnCombatGameMode.h:10-17`). P4 keeps a
   server-side snapshot keyed by a stable player identity for a `TBD` grace
   window and applies it in place of initial attributes.

## Scope and Boundaries

| Owner | #21 does | #21 does not |
| --- | --- | --- |
| [#19](https://github.com/ShayShimoni/aetheln-online/issues/19) | Applies and removes `State.Dead`; owns the restoration allowlist and the reconnect carried state (closes T34). | Change the grant-once rule, the seam, or the avatar lifecycle. |
| [#60](https://github.com/ShayShimoni/aetheln-online/issues/60) | Binds `OnLethalResult`. | Change the lethal latch, contact order, or chain reset rules. |
| [#18](https://github.com/ShayShimoni/aetheln-online/issues/18) | Tests the integrated death case on top of #18's `State.Dead` bindings. | Change dodge or block cancellation. |
| [#20](https://github.com/ShayShimoni/aetheln-online/issues/20) | Nothing in P1. | AI death and despawn, and AI attacks that kill a player. |
| [#61](https://github.com/ShayShimoni/aetheln-online/issues/61) | Raises the authoritative death state that presentation reads. | HUD, death screen, and readability of the death cue. |

## Server Death Transition (P1)

`UAethelnDeathSubsystem` is a server-only `UWorldSubsystem` in GameCombat. It
uses the timeline's creation rule (Game and PIE worlds, not a client) and
binds `OnLethalResult` once in `Initialize`. The handler forwards to
`UAethelnDeathSubsystem::ApplyDeath(Victim)`, which:

1. Refuses unless the ASC's owner is authoritative and a `PlayerState`, the
   victim has no `State.Dead`, and its Health attribute exists and is zero or
   below.
2. Applies `UAethelnDeathStateEffect`. The tag event ends the chain
   (`IncompatibleState`), the dodge window, and the block at the processing
   time, before step 3.
3. Calls `CancelAllAbilities()` for any other active ability.
4. Calls `DisableMovement()` on the avatar's character movement.

The emission loop that raises the notification iterates a local array of
committed results (`AethelnCombatTimelineSubsystem.cpp:231-240`), and a chain
reset only stamps a reset time (`:141-148`), so the synchronous transition does
not invalidate the timeline's iteration.

**Replication.** The player ASC uses Mixed replication. The owning client gets
the death effect; every other client gets `State.Dead` as a minimal
replicated tag (`GAS/Private/GameplayEffect.cpp:3733-3736`, `:4663-4664`).
Health stays owner-only. P3 proves this with two clients.

**What death keeps.** Granted abilities, cooldown effects, and attribute
values stay. The Guard break ends on `State.Dead`
(`AethelnBlockAbility.cpp:119-124`, `:144`). Which values respawn restores is P2's
allowlist.

## Respawn (P2, design)

- **Server-owned schedule.** On a death, the server records a respawn deadline
  of death time plus `ProvisionalRespawnDelaySeconds`. Unset (0), negative, or
  non-finite means no automatic respawn: the player stays dead and the server
  logs the reason. The client never requests or times a respawn.
- **One respawn per death.** Each death gets a server life generation. The
  respawn runs only for the current generation, so a duplicate timer, a
  reconnect, or a retry cannot respawn twice or respawn a living player.
- **Avatar.** The game mode restarts the player with a new pawn at a player
  start. The dead pawn is unpossessed first, so #19's null-pawn path runs
  (chain `AvatarLost`, dodge cancel, `CancelAllAbilities`, avatar cleared). What
  happens to the dead pawn (destroyed at once or kept as a corpse for a time)
  and where the player respawns are open decisions.
- **Restoration allowlist.** One instant `UAethelnRespawnRestorationEffect`
  sets exactly the allowlisted attributes from config
  (`ProvisionalRespawnRestoration`, values `TBD`). An unset or invalid
  allowlist, including a restored Health of zero, refuses the respawn. Abilities
  are never granted again (#19's flag holds). Whether cooldowns clear is part of
  the allowlist decision.
- **Order.** Restore the allowlisted values, then remove the death effect, then
  possess the new pawn. A living avatar therefore never exists with zero
  Health, and the seam stays closed until the new avatar is possessed.
- **Stale state.** After respawn, tests check that no activation, chain,
  dodge window, invulnerability, Guard break, death effect, pawn reference, or
  already-hit record from the previous life remains (DoD3).

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
  (`TBD` in the combat document).
- On login, a matching unexpired snapshot replaces the initial-attribute step
  for the fresh PlayerState. Abilities are granted once on the new
  PlayerState, as #19 requires.
- The identity key goes through an adapter (AGENTS.md: vendors stay behind
  adapters). Which identity the prototype uses is an open decision.

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
| R3 | Respawn schedule and fail-closed config | P2 | Unset delay or allowlist keeps the player dead; one respawn per generation |
| R4 | Respawn restoration and stale state | P2 | Only allowlisted values change; DoD3 list is clear |
| R5 | Two-client death and respawn | P3 | AC2 and DoD1 |
| R6 | Reconnect while alive, dead, and respawning | P4 | AC5; T34 flips |

Dodge and block refusal while dead is already covered by D13
(`Aetheln.GameCombat.Defense.LifeStateCancelsDefense`), which reacts to the same
tag event.

## Acceptance-Criteria Mapping

| Criterion | Phase |
| --- | --- |
| Server determines death from authoritative health | P1 (R1) |
| Death state and feedback replicate to all relevant clients | P1 server state on a replicated effect; P3 two-client proof and cue (R5) |
| Dead players cannot move or attack, and death/respawn cannot emit duplicate completion events | P1 death half (R1, R2); P2 respawn half (R3) |
| Respawn restores only intended attributes and abilities | P2 (R4) |
| Reconnect during death or respawn resolves to one valid state | P4 (R6) |
| DoD: two-player death and respawn paths are tested | P3 (R5) |
| DoD: disconnect edge cases are documented | P1 table above; P4 verifies (R6) |
| DoD: no stale activation, tag, effect, pawn reference, invulnerability, or already-hit state | P1 at death (R2); P2 after respawn (R4) |

## Phased Delivery

| Phase | Content | Depends on |
| --- | --- | --- |
| **P1** Death state | This document; `UAethelnDeathStateEffect`; `UAethelnDeathSubsystem`; R1, R2. | #60 P4 lethal notification (merged) |
| **P2** Respawn | Delay and allowlist config, life generation, restart order, restoration effect; R3, R4. | P1; owner decisions on delay, allowlist, location, dead pawn |
| **P3** Replication | Two-client harness run, death cue; R5. | P2 |
| **P4** Reconnect | Carried snapshot behind an identity adapter; R6; T34 flipped. | P2; owner decision on identity and grace window |

## Open Decisions

Owner decisions (none blocks P1):

- Respawn delay (`ProvisionalRespawnDelaySeconds`).
- The restoration allowlist and values: which of Health, Endurance, and Guard,
  and whether cooldowns clear.
- Respawn location, and what happens to the dead pawn (destroyed or kept as a
  corpse, and for how long).
- Whether a dead player keeps the dead pawn's camera or spectates.
- The disconnect grace window (already `TBD` in the combat document).

Technical or ownership decisions for the lead:

- AI death: whether a zero-Health AI gets `State.Dead` in a later #21 phase or
  in #20. Applying it would add an effect to the AI target that
  `Aetheln.GameCombat.AttackTimeline.DamageAndLethalLatch` currently asserts
  never arrives.
- The prototype identity key for the reconnect snapshot.
- Death sources other than a contact (periodic effects later) need their own
  call into the same transition.
