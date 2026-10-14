# Death, Respawn, and Reconnect

## Document Status

This is the implementation specification for
[Issue #21](https://github.com/ShayShimoni/aetheln-online/issues/21): a player
can die, respawn, and rejoin combat safely. Pull requests P1 to P4b deliver it
(see [Phased Delivery](#phased-delivery)). P1 added this document and the
server-side death state. P2 adds the server respawn. P3 adds the two-client
proof and the death cue. P4 adds the reconnect carried snapshot. P4b keeps the
disconnected player's pawn in the world for the grace window, issues the
reconnect key and refuses a duplicate live key (see
[P4b](#p4b-grace-window-pawn-retention-delivered)).

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
disconnect grace window (15 s, provisional) is P4's and P4b's.

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
   effect, not config. That fixed set is the declared lifecycle allowlist the
   canonical technical documents describe (owner decision, option A, see
   [Open Decisions](#open-decisions)): there is no allowlist config, and a later
   change is a code change with review. No value is invented.
7. **Reconnect uses a carried snapshot, not PlayerState reuse.** The combat
   game mode stays on `AGameModeBase`, so a reconnect gets a fresh PlayerState
   (`Source/GameCombat/Public/AethelnCombatGameMode.h:10-17`). For the
   disconnect grace window (15 s, provisional and owner-set, see
   [Open Decisions](#open-decisions)) P4b keeps the old PlayerState,
   unreplicated, and its pawn in the world under a server-issued reconnect key
   that the client presents. At the reconnect the server takes a snapshot of the
   kept PlayerState and applies it to the fresh one in place of the initial
   attributes, and the player resumes the same pawn (see
   [Reconnect and Carried State](#reconnect-and-carried-state-p4-and-p4b)).

## Scope and Boundaries

| Owner | #21 does | #21 does not |
| --- | --- | --- |
| [#19](https://github.com/ShayShimoni/aetheln-online/issues/19) | Applies and removes `State.Dead`; owns the restoration allowlist and the reconnect carried state (closes T34). | Change the grant-once rule, the seam, or the avatar lifecycle. |
| [#60](https://github.com/ShayShimoni/aetheln-online/issues/60) | Binds `OnLethalResult`. | Change the lethal latch, the contact order, or the chain reset rules, except one: a death from a lethal contact ends the chain at the lethal contact time (the stamp that #60's A28 row deferred to #21 P2). |
| [#18](https://github.com/ShayShimoni/aetheln-online/issues/18) | Tests the integrated death case on top of #18's `State.Dead` bindings. | Change dodge or block cancellation. |
| [#20](https://github.com/ShayShimoni/aetheln-online/issues/20) | Nothing. | AI death and despawn (owned by #20), and AI attacks that kill a player. |
| [#83](https://github.com/ShayShimoni/aetheln-online/issues/83) | Nothing. | Apply `State.Dead`. #83 binds the same `OnLethalResult` and owned its signature change (the `ContactTime` parameter, merged in its P2, [Death and Reset](enemy-ai-and-navigation.md#death-and-reset)). P1's handler took the three-argument form and ignored `ContactTime`; P2 uses it for the chain reset. |
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
Health and MaxHealth reach every client, and Endurance and Guard stay
owner-only (owner decision on [#61](https://github.com/ShayShimoni/aetheln-online/issues/61#issuecomment-6131999614)). P3 proves that split with two
clients (see [Two-Player Replication and Feedback](#two-player-replication-and-feedback-p3-delivered)).

**What death keeps.** Granted abilities, cooldown effects, and attribute
values stay. The Guard break ends on `State.Dead`
(`AethelnBlockAbility.cpp:121-126`, `:146`). Recovery delay effects (the
Endurance and Guard recovery delays) also persist through death under the
current default, in which a running delay keeps counting on the server clock
(`gas-foundation.md:402-404`); whether death removes a running delay is open
(see [Open Decisions](#open-decisions)) and stays `TBD`. Respawn restores only
Health, Endurance, and Guard (see [Respawn](#respawn-p2)).

**Stance buffs end at death (#260).** The owner's stance buffs (Attack Stance
and Defense Stance) are removed on death
([issue #260](https://github.com/ShayShimoni/aetheln-online/issues/260#issuecomment-6142715904)).
#260 P4 gives each stance effect a removal tag requirement on `State.Dead`, so
step 3's death effect removes the active stance at the processing time and
#21 adds no code for it. Respawn does not bring a stance back: the restoration
stays the fixed Health, Endurance, and Guard set, which the owner declared the
restoration allowlist (option A,
[issue #21](https://github.com/ShayShimoni/aetheln-online/issues/21#issuecomment-6142791700)).
The specification and test (K11) are in
[Representative Oathscar Actives](gas-foundation.md#representative-oathscar-actives-260).

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

## Two-Player Replication and Feedback (P3, delivered)

**Harness.** The movement loopback harness
(`Source/GameCore/Public/AethelnMovementLoopbackHarness.h`) scripts character
movement packets inside one world and has no net driver, so it cannot show
property replication, replication conditions, or RPC delivery. R5 therefore
uses the engine's CQTest PIE network component (`FPIENetworkComponent`,
`Engine/Source/Developer/CQTest/Public/Components/PIENetworkComponent.h`): one
dedicated server and two clients as PIE worlds in the editor process, on real
net drivers over loopback, with `AAethelnCombatGameMode`. Replication,
relevancy, conditions, RPCs, and character movement corrections are the
engine's own. It simulates no input device and no separate process, and it
plays CQTest's new unsaved map, so its two net GUID cache warnings about that
map are expected by the test. The test is declared with
`IMPLEMENT_SIMPLE_AUTOMATION_TEST`, as the CI discovery scan requires, and
queues the component's latent steps itself. Attribute values are the test
fixture values (`MakeTestInitValues`), because the ini's initial attributes
are zero until #107. Client 0 is player A, the victim; client 1 is player B.

- `Aetheln.GameCombat.Death.TwoClientDeathAndRespawn`: the server kills A
  through the timeline's lethal notification and repeats the notification. A's
  own client and B's client both observe `State.Dead` on A. A's own client is
  corrected to `MOVE_None`; `ReplicatedMovementMode` is simulated-only, so the
  owner can only reach it through a move correction. The server respawns A no
  earlier than the death time plus `ProvisionalRespawnDelaySeconds` (a lower
  bound read from config; R4 owns the exact deadline). Both clients then
  receive A's new avatar, used by their copy of A's ASC, without `State.Dead`,
  and A's own client receives the restored Health.
- **Health split** (owner decision on
  [#61](https://github.com/ShayShimoni/aetheln-online/issues/61#issuecomment-6131999614)):
  B's client receives A's Health and MaxHealth. B's copy of A's Endurance,
  MaxEndurance, Guard, and MaxGuard keeps the class defaults: they change in the
  same server frame and attribute set as Health, so they would have arrived with
  it had they replicated to a non-owner.
- **Death cue.** `UAethelnAbilitySystemComponent::MulticastDeathCue`
  (`NetMulticast`, `Unreliable`) on the victim's ASC, with the `OnDeathCue`
  delegate on every client and the server, as the result cue does. It carries no
  attribute value and no gameplay truth. `ApplyDeath` raises it once, after the
  death effect, the ability cancel, and the movement stop; a refused repeat
  never reaches it. Losing it loses nothing authoritative. R1 checks one cue per
  death and none for a repeated notification; R5 checks that the server raised
  one and, on the clean link, that each client received it once. #61 owns the
  HUD; P3 adds no widget.
- **Latency and loss.**
  `Aetheln.GameCombat.Death.TwoClientDeathAndRespawnImpaired` runs the same
  steps with `PktLag=100` (ms) and `PktLoss=5` (percent) on the server's and
  both clients' net drivers. CQTest applies the settings after the client
  worlds exist, so the connection handshake is not under loss. These are test
  settings, not the #45 network profile. The impaired run proves that the
  paths that recover from loss settle under lag and loss: `State.Dead`, the
  replicated attributes, the `MOVE_None` correction (it travels on the
  unreliable `ClientMoveResponsePacked` and settles because the server repeats
  it), and the new avatar. It checks only
  that no client receives a second cue; cue delivery is covered by the clean
  link and R1, because the cue is unreliable by design. The loss is random
  with no fixed seed.

## Reconnect and Carried State (P4 and P4b)

T34 (`Aetheln.GameCombat.Lifecycle.ReconnectInterimGap`,
`Source/GameTests/Private/AethelnAbilityLifecycleTests.cpp`) pinned the gap in
P2: a reconnect got a fresh PlayerState, refilled attributes, no effects, and a
second grant. P4 builds the transfer that closes it: a snapshot of the old
PlayerState applied to the new one. P4b keeps the old PlayerState and its pawn
in the world for the grace window and takes the snapshot at the reconnect (see
[P4b](#p4b-grace-window-pawn-retention-delivered)). The test keeps its name, so
the citations to it stay valid, and now asserts the carried values and the
resumed pawn through the production logout. The combat game mode stays on
`AGameModeBase` (see [Decisions at a Glance](#decisions-at-a-glance), item 7);
the kept players and the snapshots live in `UAethelnDeathSubsystem` beside the
respawn wait.

**Every client presents a key (P4b).** At login the server issues each player
a reconnect key and sends it to that player's own connection, and the client
presents it at its next login (see [Identity key](#identity-key-prototype)).
A client can still omit or change the key at a rejoin. It then starts a new
session, as any new player does, because without an authenticated identity
(#35) the server cannot tell that it is the same person. The disconnect itself
escapes nothing: the old PlayerState and pawn stay in the world, attackable,
until the grace window ends.

- **Capture.** At the reconnect, `UAethelnDeathSubsystem::TakeOverRetained`
  calls `UAethelnDeathSubsystem::CaptureCarriedState` on the kept PlayerState,
  before anything re-points the pawn (re-pointing runs the kept PlayerState's
  null-pawn case, which cancels its abilities). The kept ASC still holds its
  attributes and effects, which kept running while the player was away. The
  snapshot holds the six attribute values; every active
  `UAethelnCooldownEffect` with its granted tags and its end time on the world
  clock (that one effect class is the shared timed state: ability cooldowns, the
  Guard break, and the recovery delays); the life state; and, for a dead
  player, the respawn wait (deadline and life generation), moved out of the
  pending map. The grace window is `ProvisionalDisconnectGraceSeconds` (15 s,
  provisional and owner-set, issue #21 comment 6131998770;
  `Config/DefaultGame.ini`, `[/Script/GameCombat.AethelnDeathSubsystem]`). The
  combat document's general safe-logout and disconnect durations stay `TBD`.
  Unset (0), negative, or non-finite means nothing is kept at logout and the
  server logs why: the engine destroys the pawn and the PlayerState, and a
  reconnect is a new session.
- **Restore.** On the new PlayerState's first possession,
  `UAethelnDeathSubsystem::RestoreCarriedState` replaces the initial-attribute
  step. It consumes the snapshot (one reconnect takes it), checks the window,
  applies the same six values through `UAethelnAttributeInitEffect` (maxima
  first), and reapplies each timed state for its remaining time. A timed state
  keeps counting on the server clock while the player is away: it is neither
  paused nor reset. For a dead player it applies the death effect, cancels
  abilities, calls `DisableMovement` on the avatar (the resumed corpse, or a new
  pawn when the corpse is already gone), and re-adds the respawn wait with the
  same deadline and life generation. The engine's restart can reset the pawn's
  movement mode after the restore, so the world's post-actor tick also holds any
  pawn with a pending respawn wait at `MOVE_None`. It raises no death cue, emits
  no `Death` event, and advances no generation. Abilities are granted once and
  recovery is started once on the new PlayerState, as #19 requires.
- **A carried Guard break meets death.** The block ability binds the dead tag
  only when it applies a break itself, so a carried break has no binding.
  `ApplyDeath` therefore removes `State.GuardBroken` too, which is a no-op for a
  live break that the ability's binding already ended.
- **Not carried.** The stagger a successful Parry puts on its attacker
  (`UAethelnStaggerEffect`, a duration effect on a player attacker) is not
  carried, so a keyed reconnect ends it; the capture names it in a warning. The
  stance buffs of #260 are not named by the snapshot either (they are carried
  only if #260 builds them on the shared timed-state effect, which the death
  removal rule still ends; the choice is open in `gas-foundation.md`). The
  recovery effects themselves (the new PlayerState starts them) and anything
  the snapshot does not name are not carried either.
- **Location.** The pawn is not part of the snapshot: the player resumes the
  same pawn where it stands (P4b). Only when the kept pawn is gone (a dead
  player's corpse is removed at the respawn deadline) does the reconnect start
  at the game mode's start spot.
- **Server authority.** The client presents at most the reconnect key (see
  below). Nothing a client sends is a state value, and the restored values come
  only from the server's own kept player. A key that names no kept player, an
  expired one, or no key at all gets the initial attributes.
- **Uncarried effects are named.** The capture walks every active non-instant
  effect. The shared timed-state effect is carried, the death effect is the life
  state, and the recovery effects are started again by the new PlayerState. Any
  other duration effect would be ended by a reconnect, so the capture logs a
  warning naming it, and `...Death.ReconnectNamesUncarriedEffects` fails when
  that warning is missing. The Parry stagger (`UAethelnStaggerEffect`) already
  falls here. A future debuff or stance on another class cannot be cleansed
  silently either, and a duration modifier on a maximum would show there too.

### Identity key (prototype)

`AAethelnCombatGameMode::ResolveReconnectKey` reads the reconnect identity and
`AAethelnCombatGameMode::IssueReconnectKey` makes it (lead decision, 2026-10-12:
P4 chooses the key, behind a seam, never a vendor identity). The prototype key
is the opaque `ReconnectKey` login option, 1 to 64 characters of `A-Z`, `a-z`,
`0-9`, `-` and `_`, and a missing or malformed option means no key and so no
carry. The key is server-issued and client-presented, and the kept player is
server-held:

- **Issued.** `AAethelnCombatGameMode::InitNewPlayer` stamps a key on the new
  PlayerState before the first possession. It takes the presented key only when
  that key names a player kept inside its grace window; every other login gets
  a new key from `IssueReconnectKey` (32 random hexadecimal digits from
  `FGuid::NewGuid`). So no client chooses its own key, and two connected
  players never share one. The key lives in a server-only member that no
  replication or RPC sets, and it names a kept player without carrying a value.
- **Sent to the owner only.** `AAethelnCombatGameMode::PostLogin` sends the key
  through `AAethelnPlayerController::ClientReceiveReconnectKey`, a reliable
  client RPC, which reaches only that controller's own connection. It is never
  replicated to other clients
  (`...Death.TwoClientReconnectKeyReachesOwner`).
- **Stored and presented by the client.** `UAethelnLocalPlayer` (GameNet,
  `Config/DefaultEngine.ini` `LocalPlayerClassName` for the game and the editor)
  keeps the key in memory and returns `ReconnectKey=<key>` from
  `GetGameLoginOptions`, which the engine appends to the next join URL
  (`Engine/Source/Runtime/Engine/Private/PendingNetGame.cpp:334-339`). The key
  is lost when the client process ends.

- **Why this key.** `GetPlayerId()` is new for every PlayerState, so it cannot
  survive a reconnect. The online subsystem's `FUniqueNetIdRepl` is a vendor
  identity (AGENTS.md: vendors stay behind adapters until a decision selects
  one), and a stable value is not guaranteed without a selected online service. The remote address is
  shared by players behind one NAT and by every loopback client in the tests.
  The `Name` option is a display name, not unique. A named login option is the
  only stable string in the engine's login path that no vendor owns, and it
  keeps the seam one function.
- **Limits.** The key is server-issued but unauthenticated. It names a player
  the server already holds and carries no state, but a client that drops or
  changes its key starts a new session (the fresh start an authenticated
  identity prevents), and a client that learns another player's key could take
  that player inside the grace window. The key is a bearer capability, and the
  engine logs the login options at `LogNet`
  (`Engine/Source/Runtime/Engine/Private/World.cpp:7508`, `:7577`), so a
  presented key sits in default server logs. The observability events and the
  project's own log lines carry no key.
- **Duplicate live key** (lead decision, 2026-10-14, issue #21 comment
  6167754445). `AAethelnCombatGameMode::PreLogin` refuses a login that presents
  the key of a connected player, and never kicks the connected player: with an
  unauthenticated key, a kick would let anyone who learns a key end that
  player's session. A crashed client therefore waits for its old connection to
  time out (`ConnectionTimeout=60.0`, `Engine/Config/BaseEngine.ini:1855`), and
  its rejoin then falls inside the grace window
  (`...Death.ReconnectRefusesLiveKey`).
- **Exception record** (`security-and-operations.md`: an accepted exception
  names an owner, evidence and a revisit trigger). Owner: issue #35 (authenticate
  accounts and manage sessions) replaces `ResolveReconnectKey` and
  `IssueReconnectKey`, and issue #36 (the identity and backend vendor spike)
  decides the vendor. Evidence: this section and
  `...Death.ReconnectKeyIsClientPresented`, `...ReconnectLoginStampsKey`,
  `...ReconnectRefusesLiveKey`, `...TwoClientReconnectKeyReachesOwner`.
  Trigger: before any build leaves `local` or `development` (AGENTS.md,
  Environment Strategy), the key must be authenticated and kept out of the logs.

### Disconnect edge cases

| Case | Resolved state |
| --- | --- |
| Disconnect while alive | The pawn stays where it stood; the reconnect resumes it with the current values and the remaining timed states; reconnect is not a refill (`...Death.ReconnectCarriesLivingState`). |
| Disconnect while dead, reconnect before the deadline | The reconnect resumes the corpse, dead, with the same deadline and generation (`...Death.ReconnectDeadKeepsDeadline`). |
| Disconnect while dead, deadline passes while away | The corpse is removed at the deadline (the owner's corpse rule) and the respawn waits for the reconnect; the player respawns once, through the normal order, on the first tick after the reconnect (`...Death.ReconnectAfterDeadlineRespawnsOnce`). |
| Disconnect during the respawn step | The respawn step runs inside one world tick and a logout happens between ticks, so the reconnect sees either the player before the step (dead, with the wait) or after it (alive, restored, no wait), never both (`...Death.ReconnectRespawnStepIsAtomic`). |
| Reconnect after the grace window | At the end of the window the kept pawn and PlayerState leave the world, with any respawn wait; the reconnect is a new session under the persistence policy (`...Death.ReconnectAfterGraceIsNewSession`). |
| Lethal result while the connection is gone | The kept pawn is attackable: a contact resolves to the kept ASC, and a lethal result is a real death with its respawn wait, which the reconnect carries (`...Death.GraceKeepsAttackablePawn`). |
| A hard drop before the connection timeout | A crash or a pulled cable does not close the connection until `ConnectionTimeout=60.0` (`Engine/Config/BaseEngine.ini:1855`), so the old pawn stays possessed for up to 60 s. A rejoin with the same key inside that time is refused at `PreLogin` (lead decision, see [Identity key](#identity-key-prototype)); after the timeout the old player is kept, and the rejoin resumes it inside the grace window (`...Death.ReconnectRefusesLiveKey`). |
| A rejoin without the key, or with another key | A new session, as for any new player (no authenticated identity until #35). The old pawn and PlayerState stay attackable until the window ends (`...Death.ReconnectKeyIsClientPresented`). |

### P4b: grace-window pawn retention (delivered)

The owner's rule (issue #21 comment 6131998770, restated in comment 6133925614):
during the 15 s grace window the pawn stays in the world, server-controlled and
attackable, and the player resumes it on reconnect. P4 (PR #357) merged as
partial and named this phase. The engine's logout chain is the controller's
destruction (`APlayerController::Destroyed`,
`Engine/Source/Runtime/Engine/Private/PlayerController.cpp:1633-1641`, and
`AController::Destroyed`, `Controller.cpp:595-612`): `PawnLeavingGame`, then the
game mode's `Logout`, then `CleanupPlayerState`. P4b hooks two of its virtual
steps, with one predicate, `UAethelnDeathSubsystem::CanRetain` (the server, a
player past its first possession, a reconnect key, and a finite grace window
above zero), so the two hooks never disagree:

- **Keep the pawn.** `AAethelnPlayerController` (the combat game mode's
  controller class) overrides `PawnLeavingGame` (`PlayerController.h:2054`),
  which would destroy the pawn. For a kept player it unpossesses the pawn (no
  controller drives it, so no input reaches it) and points it back at the kept
  PlayerState. `APawn::UnPossessed` clears the pawn's PlayerState
  (`Engine/Source/Runtime/Engine/Private/Pawn.cpp:719`), and
  `UAethelnAbilitySystemComponent::FindForPawn` resolves the ASC through it
  (`AethelnAbilitySystemComponent.cpp:246`). Re-pointing it runs
  `HandlePawnSet`, which makes the kept pawn the kept ASC's avatar again, so a
  contact on the kept pawn resolves to the kept ASC.
- **Keep the old PlayerState, unreplicated.** `AAethelnPlayerState` overrides
  `OnDeactivated` (`PlayerState.cpp:128-132`; the engine comment at
  `PlayerController.cpp:1396` says a game can override it), which
  `CleanupPlayerState` calls (`PlayerController.cpp:1392-1398`) and which would
  destroy it. `UAethelnDeathSubsystem::RetainForGrace` keeps it as the engine
  keeps an inactive player (`AGameMode::AddInactivePlayer`,
  `Engine/Source/Runtime/Engine/Private/GameMode.cpp:601-618`): out of the game
  state's player list and no longer replicated, so clients drop their copy. It
  also marks it inactive (`APlayerState::SetIsInactive`), clears its owner (the
  controller being destroyed) and stops the pawn's movement. The kept PlayerState keeps its ASC, effects and respawn wait
  running. This is not PlayerState reuse (item 7 stands).
- **Attackable and killable.** Damage, death and respawn rules apply to the
  kept pawn unchanged: a lethal result is a real death (`ApplyDeath` on the kept
  ASC, the death effect, the respawn wait, the `Death` event). While the player
  is away the respawn does not run: at the deadline the corpse is removed (the
  owner's corpse rule) and the wait stays for the reconnect.
- **Resume at the reconnect.** `AAethelnCombatGameMode::RestartPlayer` calls
  `UAethelnDeathSubsystem::TakeOverRetained` for a player whose key names a kept
  player inside the window. It captures the kept PlayerState's state (P4's
  snapshot), detaches the kept pawn, destroys the kept PlayerState, and returns
  the pawn. The game mode then possesses it through the engine's own finish step
  (`SetPawn` and `FinishRestartPlayer`, as `RestartPlayerAtPlayerStart` does),
  and the fresh PlayerState's first possession restores the snapshot. The
  player resumes the same pawn, where it stands. Without a kept pawn (the
  corpse was removed at the deadline) the engine's restart spawns one.
- **End of the window.** The subsystem's post-actor tick removes a kept player
  whose window has ended: the kept pawn is destroyed, the respawn wait dropped,
  and the kept PlayerState destroyed. Nothing is carried past the window.
- **Key producer and duplicate key.** See
  [Identity key](#identity-key-prototype).

## Test Plan

| ID | Test | Phase | Proves |
| --- | --- | --- | --- |
| R1 | `Aetheln.GameCombat.Death.LethalNotificationAppliesDeath` | P1 | A lethal notification for a zero-Health player applies one death effect and one `State.Dead`; a repeat adds nothing; a living player and an AI target get no death state. (P3) The server raises one death cue for the death and none for the repeat |
| R2 | `Aetheln.GameCombat.Death.DeadPlayerRefusesActions` | P1 | Death mid-chain ends the chain once with `IncompatibleState`, resolves no later contact, refuses the next press with `ActivationBlocked`, and sets the avatar's movement to `MOVE_None` |
| R3 | `Aetheln.GameCombat.Death.RespawnFailsClosed` | P2 | The ini delay is finite and positive; an unset, negative, or non-finite delay, a world with no game mode, and a maximum Health of zero each keep the player dead, with one logged refusal and no retry |
| R4 | `Aetheln.GameCombat.Death.RespawnAfterDelay` | P2 | No respawn before the deadline (death time plus the delay); then `State.Dead` and the death effect are gone, Health, Endurance, and Guard equal their maxima and the maxima did not move, a new pawn is the avatar and the corpse is destroyed, no ability is granted again, a cooldown keeps counting, no chain, dodge window, or other state from the previous life remains, one chain end overall, a second respawn is refused, and the player starts a chain again. The chain reset is stamped at the lethal contact time |
| R5 | `Aetheln.GameCombat.Death.TwoClientDeathAndRespawn`, `Aetheln.GameCombat.Death.TwoClientDeathAndRespawnImpaired` | P3 | AC2 and DoD1 on a dedicated server with two PIE clients: both clients see `State.Dead` on the victim, the owner is corrected to `MOVE_None`, the server respawns no earlier than the configured delay, and both clients receive the new avatar without `State.Dead`; B receives the victim's Health and MaxHealth but not its Endurance or Guard; on a clean link the death cue reaches each client once; the impaired run repeats the steps at 100 ms lag and 5 % loss |
| R6 | `Aetheln.GameCombat.Death.ReconnectCarriesLivingState`, `...ReconnectDeadKeepsDeadline`, `...ReconnectAfterDeadlineRespawnsOnce`, `...ReconnectRespawnStepIsAtomic`, `...ReconnectAfterGraceIsNewSession`, `...ReconnectKeyIsClientPresented`, `...ReconnectLoginStampsKey`, `...ReconnectThroughControllerDestroy`, `...ReconnectNamesUncarriedEffects`, `...ReconnectDuplicatesNothing`; T34 `Aetheln.GameCombat.Lifecycle.ReconnectInterimGap` flipped | P4, extended by P4b | AC5; T34 flips. Every logout in these tests is the production chain, the controller's destruction. Each row of the edge-case table; reconnect is not a refill and clears no timed state (cooldown, Guard break, recovery delay) and carries maxima that differ from the initial values; (P4b) the reconnect resumes the same pawn where it stood, the kept PlayerState is removed, and the resumed pawn resolves to the fresh ASC; a dead player resumes its corpse with the same deadline and generation, and respawns once; a corpse whose deadline passes while the player is away is removed at the deadline; at the end of the window the kept pawn and PlayerState are removed and the reconnect is a new session, dead or alive; an invalid window keeps no pawn and is a new session; the restored values come only from the server's kept player, and another key or none never takes it; the server issues a key for a login without one, with a malformed one, or with one that names no kept player, keeps a presented key that names a kept player, and the local player presents its key in its login options; an effect the snapshot does not carry is named; a reconnect adds no death cue (observed from before the restore), no `Death` event, no life generation, and no second grant |
| R11 | `Aetheln.GameCombat.Death.GraceKeepsAttackablePawn`, `...ReconnectRefusesLiveKey`, `...TwoClientReconnectKeyReachesOwner` | P4b | The owner's grace rule: after the logout the pawn stays in the world with no controller, resolves to the kept ASC and is its avatar, and the kept PlayerState is inactive and unreplicated; an enemy swing through the real contact pipeline kills the kept pawn, a real death with its respawn wait; the reconnect resumes the corpse with the same deadline and generation, and the player respawns once. The lead's duplicate-key rule: a login with a connected player's key is refused at `PreLogin` and the connected player keeps its controller, pawn and key; a key that names nobody, no key, and the key of a kept player are accepted. On a dedicated server with two PIE clients, each client's local player holds the key the server issued to it, never the other's, and no client's copy of a PlayerState carries a key |
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
| Reconnect during death or respawn resolves to one valid state | P4 (R6) and P4b (R6, R11): every client presents a server-issued key, the pawn stays attackable for the grace window, and the reconnect resumes it |
| DoD: two-player death and respawn paths are tested | P3 (R5) |
| DoD: disconnect edge cases are documented | P1 table above; P4 and P4b verify every row (R6, R11) |
| DoD: no stale activation, tag, effect, pawn reference, invulnerability, or already-hit state | P1 at death (R2); P2 after respawn (R4) |

## Phased Delivery

| Phase | Content | Depends on |
| --- | --- | --- |
| **P1** Death state | This document; `UAethelnDeathStateEffect`; `UAethelnDeathSubsystem`; R1, R2. | #60 P4 lethal notification (merged) |
| **P2** Respawn (delivered) | The delay config, life generation, restart order, restoration effect; R3, R4, R8, R9. A `Death` observability event (`EAethelnObservabilityCategory::Death`, `observability-and-crash-diagnostics.md:21`) with the activation id as correlation, as `Emit` does for hits (R10); the Guard-break-at-death row R7; the lethal-contact-time chain reset using `ContactTime` from `OnLethalResult`. | P1; the owner decisions of 2026-10-12 on delay, restoration, location, dead pawn, and camera |
| **P3** Replication (delivered) | Two-client PIE run on CQTest's network component, the Health split, the death cue, the impaired run; R5 and the R1 cue rows. | P2; #61's Health decision (PR #343) |
| **P4** Reconnect (delivered as partial) | Carried snapshot behind an identity seam (`ResolveReconnectKey`); the 15 s provisional grace window; R6; T34 flipped. | P2; P4 chose the prototype identity key |
| **P4b** Grace-window pawn retention (delivered) | Keep the pawn (`PawnLeavingGame`) and the old PlayerState unreplicated (`OnDeactivated`) for the grace window, re-point the kept pawn to the kept ASC, capture at the reconnect and resume the same pawn, remove the kept player at the end of the window, the server-issued key and its client producer, the duplicate-key refusal; R6 through the production logout, R11. | P4; the lead's duplicate-key rule (2026-10-14) |

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
  builds the snapshot transfer and the window; P4b keeps the pawn (see
  [P4b](#p4b-grace-window-pawn-retention-delivered)).

Later owner decisions:

- **Restoration allowlist (option A,
  [issue #21 comment](https://github.com/ShayShimoni/aetheln-online/issues/21#issuecomment-6142791700)):**
  the fixed Health, Endurance, and Guard set in
  `UAethelnRespawnRestorationEffect` is the declared lifecycle allowlist that
  the canonical technical documents describe
  (`combat-and-networking-architecture.md:68` and `:270`, `gas-foundation.md:268`).
  There is no allowlist config; a later change is a code change with review.
- **Health visibility
  ([issue #61 comment](https://github.com/ShayShimoni/aetheln-online/issues/61#issuecomment-6131999614)):**
  Health and MaxHealth are public; Endurance and Guard stay owner-only. R5
  proves the split on two clients.

Still open for the owner:

- Whether death removes a running recovery delay (#21, listed in
  `gas-foundation.md:1211`). P1 keeps the current default: the delay persists.

Lead decisions (2026-10-12):

- **AI death is #20's.** #21 stays player-only. When #20 applies a death state
  to AI, `Aetheln.GameCombat.AttackTimeline.DamageAndLethalLatch`, which
  asserts that no other effect reaches the AI target, needs updating.
- **The reconnect identity key is decided in P4**: the `ReconnectKey` login
  option behind `ResolveReconnectKey`, unauthenticated and prototype only (see
  [Identity key](#identity-key-prototype)).

Lead decision (2026-10-14,
[issue #21 comment](https://github.com/ShayShimoni/aetheln-online/issues/21#issuecomment-6167754445)):

- **Duplicate live key: refuse the login at `PreLogin`, never kick.** A login
  presenting a key bound to a connected PlayerState is refused; the connected
  session is never kicked, because an unauthenticated key must not be a kick
  vector. A crashed client waits for its old connection to time out (60 s) and
  is then inside the grace window (see [Identity key](#identity-key-prototype)).

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
  and the death effect is infinite. P3 replicates no deadline (its cue carries
  none); #61 decides how the deadline reaches the owner (for example a
  replicated deadline or a timed effect). No value is invented here.
- **No `Respawn` event.** P2 emits `Death` only, as this spec's phased delivery
  assigns (the issue itself names no observability event). The `Respawn`
  category exists (`observability-and-crash-diagnostics.md:21`) and is not wired:
  P3 adds only the presentation death cue.
- **A failed restart after the restore.** If the game mode cannot spawn a pawn
  after the checks pass, `Respawn` logs an error and returns false with the
  player alive and without a pawn (the seam rejects with `ConnectionClosed`).
  The checks make this unlikely, and the pawn spawn that remains is the
  engine's.
- **A disconnected player is not respawned while away.** A dead player's corpse
  is removed at the deadline and the respawn waits for the reconnect (R6). A
  logout with an invalid grace window drops the wait with the PlayerState, and
  the next login is a new session.
- **Other clients do not see the kept player's attributes or death (P4b).** The
  kept PlayerState is unreplicated, as the engine keeps an inactive player, so
  while the player is away other clients still see the kept pawn and its
  movement but no longer receive its Health, its `State.Dead` tag or its death
  cue, which live on the PlayerState's ASC. The server state is authoritative
  and the reconnect replicates it to every client (P3's replication). Showing an
  away player's Health or death to others would need the kept PlayerState to
  stay replicated; that choice and its presentation belong to #61.
- **AI does not pick an away player as a new target (P4b).** The #83 enemy
  chooses new targets among connected players' pawns
  (`AethelnEnemyController.cpp:176-187`), so it ignores a kept pawn it was not
  already chasing; one it already targets stays eligible. Player attacks reach
  the kept pawn through the same contact pipeline. A rule for AI and away
  players belongs to #20 and #83.
- **A keyless rejoin is a new session (P4b).** A client that drops or changes
  its key starts as a new player, because nothing authenticates who it is. The
  old pawn and state stay attackable until the window ends, so the disconnect
  escapes nothing, but the new session does not inherit the old state. #35's
  authenticated identity closes this.
- **The reconnect key is unauthenticated and logged.** See
  [Identity key](#identity-key-prototype) for the exception record.
- **A crashed client waits up to 60 s (P4b).** The lead's rule refuses a rejoin
  while the old connection is alive, so a crashed client rejoins only after the
  engine's connection timeout; its pawn stays possessed, still and attackable,
  until then, and the grace window starts at the timeout.
- **A keyed reconnect ends a Parry stagger (P4).** `UAethelnStaggerEffect` is
  not carried, so a staggered player who reconnects with a key is no longer
  staggered. The capture warns, and `...Death.ReconnectNamesUncarriedEffects`
  guards the warning; carrying it is a later decision.
- **The location is carried only through the kept pawn (P4b).** Inside the
  window the player resumes the same pawn where it stands. After the window, or
  after a dead player's corpse is removed, a reconnect starts at the game mode's
  start spot; position beyond the window belongs to the persistence design.
- **Kept players live in the world (P4, P4b).** They are lost with the world,
  at a map travel or a server restart, and a persistence policy for them stays
  `TBD`.
- **R6 and R11 run the reconnect in one authority world (P4, P4b).** The logout
  is the production chain (the controller's destruction, with no connection),
  and the login is a new controller with a fresh PlayerState started by the game
  mode. `FPIENetworkComponent` can late-join a new client but cannot close one
  client and connect it again with login options, so there is no two-client PIE
  reconnect test. The real connection close (`APlayerController::OnNetCleanup`,
  which clears the player and destroys the controller) reaches the same chain,
  and the network side of a reconnect (the new connection's replication of the
  restored state) is covered by P3's replication of the same state. The key's
  delivery to its owner is proven on two PIE clients
  (`TwoClientReconnectKeyReachesOwner`); its presentation in a real rejoin URL is
  covered by the local player's login options (`ReconnectLoginStampsKey`).
- **Untested P2 paths.** No test covers the no-controller and no-pawn-class
  refusals, the error after `RestartPlayer` (no pawn), the death-order sort, two
  players due in one tick, or a second death after a respawn (life generation
  2 and its `Death` event sequence).
- **R5 runs in one editor process.** The server and both clients are PIE worlds
  with real net drivers over loopback, not separate packaged processes, and no
  input device drives the pawns. The impaired run uses one fixed setting, not
  the #45 network profile; packaged multi-process evidence stays with #44 and
  #45. R5 kills A through the lethal notification, not through a player's
  swing (R9 covers the real lethal path on the server).

## Follow-ups

- **Non-contact death.** Death sources other than a contact, such as periodic
  effects later, are not wired yet. They enter death through the same public
  entry point, `UAethelnDeathSubsystem::ApplyDeath(Victim)`, with no activation
  id and no contact time. It stays callable from any server code, keeps the same
  refusal rules, and starts the same respawn wait (R8).
