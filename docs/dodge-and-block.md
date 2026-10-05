# Dodge and Block

## Document Status

This is the implementation specification for
[Issue #18](https://github.com/ShayShimoni/aetheln-online/issues/18): the
player's server-validated dodge and the right-mouse directional block. It is
phase P1 of the issue and contains no code. Pull requests P2 to P5 deliver it
(see [Phased Delivery](#phased-delivery)). The owner decisions already made
are recorded in [Owner Decisions](#owner-decisions); the questions still open
are in [Open Decisions](#open-decisions), each with a recommended answer.

It is subordinate to
[Combat and Networking Architecture](combat-and-networking-architecture.md),
TA-002, TA-003, TA-004, TC-002, and TC-008 in
[Architecture Decisions](architecture-decisions.md), and the canonical product
documents, and it changes no product rule. It consumes the activation seam in
[Gameplay Ability System Foundation](gas-foundation.md) (Issue #19) and the
contact pipeline in [Attack Timeline and Three-Hit Combo](attack-timeline-and-combo.md)
(Issue #60). Every distance, duration, window, arc, cost, cooldown, and Guard
value stays `TBD`; a `Provisional...` config key is a named placeholder, never
tuning. C++ names are proposed code names. Guard, Endurance, Hold the Line, and
Oathscar are working names.

**Citations.** Repository `path:line` citations are valid at `develop`
revision `f173388`; citations into the combat document and the #19 and #60
specifications use section names, because lines move. Engine citations are
relative to the root of the pinned UE 5.8.1 source, revision `71fe36aac5`.
`GAS/` abbreviates
`Engine/Plugins/Runtime/GameplayAbilities/Source/GameplayAbilities/`,
`Runtime/` abbreviates `Engine/Source/Runtime/`, `CMC.h` abbreviates
`Runtime/Engine/Classes/GameFramework/CharacterMovementComponent.h`, and
`CMC.cpp` abbreviates
`Runtime/Engine/Private/Components/CharacterMovementComponent.cpp`.

## Decisions at a Glance

1. **The dodge is a predicted CMC movement with a server-owned window.** The
   owning client predicts only the displacement, through a saved-move flag, as
   the Prediction Matrix allows for supported custom movement. Cost, cooldown,
   tags, and the invulnerability window are never predicted.
2. **The dodge request rides the movement stream.** The flagged move is the
   request. The server decides it while simulating that move, so the commit
   (cost, cooldown, window) and the start of the displacement happen in one
   server step and can never disagree. Engine move ordering rejects duplicate
   and reordered copies. This adds a movement-carried entry to #19's seam
   (Technical decision T1; the alternative is recorded beside it).
3. **Two clocks, on purpose.** The displacement advances in the client's move
   time, so prediction and the server compute the same path. The
   invulnerability window advances on server world time from the server step
   that accepted the dodge, so a client cannot stretch it by withholding moves.
4. **Avoidance is time-exact.** A contact is avoided if its contact time lies
   inside the target's invulnerability window. The window tag stays for gating
   and observers. This asks one change of #60 P4.
5. **The block is a held seam ability.** Right mouse sends a seam `Press` and a
   `Release` (`bAcceptsRelease`). Nothing is predicted.
6. **One defense slot per ASC.** While active, the block registers the
   three things the owner required of it: the defense state tag
   (`State.Blocking`, with its server-time interval), an authored arc, and a
   Guard-consequence hook that #60 calls once per blocked hit. #260's Hold the
   Line uses the same slot.
7. **The block arc is measured from server state.** The incoming direction is
   the yaw-only vector from the defender's capsule center to the attacker's
   combat-frame origin at the contact time, compared with the defender's
   server-simulated actor yaw, never the client control rotation.
8. **A blocked contact never resolves twice.** The hook applies Guard pressure
   once; a Guard break ends the block at the contact time and affects only
   later contacts.
9. **Life state cancels defense.** `State.Dead`, avatar loss, and teardown
   end the dodge window and the block at the time they are processed.
   Invulnerability is never revived.
10. **Tuning is config data,** validated at grant time and failing closed, as
    in #19 and #60.

## Scope and Boundaries

#18 owns the dodge (cost and cooldown, authoritative invulnerability,
correction, and network-condition tests; `docs/combat-and-networking-architecture.md`
Prototype Boundary and Existing Owners; `docs/characters-and-factions.md:349`;
`docs/prototype-and-1.0-scope-ledger.md:71`) and, by the owner decision of
2026-10-05, the right-mouse block action.

| Owner | #18 consumes or provides | #18 does not do |
| --- | --- | --- |
| [#19](https://github.com/ShayShimoni/aetheln-online/issues/19) | Consumes the seam, rate bucket, base ability, cost and cooldown (P4), grant validation, `FindForPawn`, `State.Dead`. Adds a movement-carried seam entry (T1) and a second owner outcome RPC (see [Dependencies on #19](#dependencies-on-19)). | Change #19's existing validation steps or lifecycle. |
| [#60](https://github.com/ShayShimoni/aetheln-online/issues/60) | Provides the dodge invulnerability window and tag for the avoidance step, and the defense slot (tag, arc, hook) for the defense step. Consumes the timeline driver's boundary pass and the requests-before-contacts rule. Dodge and block activations reset the chain like any other action. | Contacts, the contact order, damage, the already-hit records, or deciding "blocked or not" (#60 does, against #18's defense state). |
| [#260](https://github.com/ShayShimoni/aetheln-online/issues/260) | Provides the defense slot Hold the Line reuses. | Hold the Line, Gate Step, or Sworn Rebuke behavior. |
| [#17](https://github.com/ShayShimoni/aetheln-online/issues/17) | Extends the project movement component with the dodge movement on `FLAG_Custom_2`. Asks #17 for an airborne facing bound (Q12). | Sprint, jump, facing, or other movement rules. |
| [#21](https://github.com/ShayShimoni/aetheln-online/issues/21) | Ends the dodge window and the block when `State.Dead` is added, tested through the test seam. | Apply `State.Dead`, run death, respawn, or reconnect, or test the integrated death and respawn case. |
| [#61](https://github.com/ShayShimoni/aetheln-online/issues/61), [#97](https://github.com/ShayShimoni/aetheln-online/issues/97) | Provides outcomes, replicated state tags, corrections, and result cues to present. | HUD, animation, effects, `GameplayCue.*` tags. |
| [#82](https://github.com/ShayShimoni/aetheln-online/issues/82) | Decides the dodge transport (T1) and supplies the dodge and right-mouse bindings in P5. | Camera, reticle, controller layout, remapping UI. |
| [#20](https://github.com/ShayShimoni/aetheln-online/issues/20) | Tests use enemy steps registered directly with #60's driver as the attacker. | Enemy behavior. |
| [#2](https://github.com/ShayShimoni/aetheln-online/issues/2), [#45](https://github.com/ShayShimoni/aetheln-online/issues/45) | Records rejection and correction rates for their profiles. | Rewind, network profiles, numeric bounds. |
| [#106](https://github.com/ShayShimoni/aetheln-online/issues/106), [#107](https://github.com/ShayShimoni/aetheln-online/issues/107) | Stable IDs and tuning. | Final values. |
| [#115](https://github.com/ShayShimoni/aetheln-online/issues/115) | Nothing. | The stale `prototype combat resource` wording in the brief, ledger, and roadmap. |

## Canon Anchors and Existing Code

The canon fixes the shape of the work:

- "Dodges grant a server-validated defensive window"; "Blocks are directional
  and consume a defensive resource" (`docs/game-design-bible.md:303-304`).
- Right mouse defaults to the class defensive action, remappable
  (`docs/game-design-bible.md:166-167`); Space stays jump. The prototype
  contract is "directional block, the shared prototype dodge"
  (`docs/characters-and-factions.md:311`).
- Guard: "Stability while actively defending. Guard pressure can break a
  block or defensive stance; Guard is not bonus Health and does not passively
  absorb every hit" (`docs/game-design-bible.md:186`). Directional defense loses
  to "valid angle, timing, Guard pressure, or an authored unblockable rule"
  (`docs/characters-and-factions.md:269-270`).
- The defense order resolves avoidance, including "the server-owned dodge
  window", before directional block, then applies Guard pressure once; a Guard
  break does not re-score the same contact (Damage Families and Deterministic
  Defense in the combat document).
- The server validates "sprint, dodge, root, knockback, and other state
  prerequisites", and custom movement extends the saved-move and prediction
  paths (Runtime Ownership in the combat document). Block and dodge outcomes
  are requested and presented by the client and ordered and resolved by the
  server (Prediction Matrix).
- Respawn never revives stale invulnerability, and disconnect is never an
  instant escape (Death, Logout, and Recovery Safety).
- A committed dodge result is what may trigger later content; "a predicted
  dodge alone cannot trigger it" (`docs/characters-and-factions.md:289`).

**Resource identity.** The ledger's P10-043 row and Issue #18's 2026-07-29
note predate Issues #103 and #105. Guard is the canonical
`combat.resource.guard` (`docs/game-design-bible.md:186`), and the Bible
assigns the stale wording to #115 (`:285-291`). #18 edits none of it, as #19
did.

Existing code at `f173388`:

| Existing code | Disposition |
| --- | --- |
| Project movement component and saved move (`Source/GameCore/Private/AethelnCharacterMovementComponent.cpp:23-114`) | Extend. `FLAG_Custom_0` is sprint and `FLAG_Custom_1` aim steering (`:80-92`, `:329-334`); `FLAG_Custom_2` and `FLAG_Custom_3` are free (`docs/movement-poc.md:242-244`). Reuse the jump-takeoff pattern: the result is derived inside the simulation from the move's own acceleration and control yaw (`:200-231`), so prediction, replay, and the server agree. |
| Headless prediction pair (`Source/GameCore/Private/AethelnCharacterMovementComponent.cpp:688-800`) | Reuse for the movement tests: client, server, and simulated proxy in one world, with the server's position-error check per move. |
| Input receiver (`Source/GameCore/Public/AethelnPlayerInputReceiver.h:23-30`) | Extend with a dodge press. It has no combat, dodge, or defense method today (`docs/input-camera-free-aim-spike.md:26`). |
| #19 P2 and P3 (`Source/GameCombat/Public/AethelnAbilitySystemComponent.h:58-142`, `Source/GameCombat/Public/AethelnGameplayAbility.h:15-100`, `Source/GameCombat/Public/AethelnActivationTypes.h:26-66`) | Build on them: the seam, validator, rate bucket, choke point, `CommitAbility` result slot, and owner outcome. Cost and cooldown (#19 P4) are not on `develop` yet; this document designs against their specification. |
| Guard and Endurance attributes (`Source/GameCombat/Public/AethelnCombatAttributeSet.h:29-30`, `:70-74`) | Use as they are. Only Gameplay Effects change them. |
| Observability subjects (`Source/GameNet/Public/AethelnObservability.h:46-47`) | `Dodge` and `Block` already exist; no vocabulary change. |
| Spike classes | Untouched. |

## Class Layout

| Class or file | Module | Responsibility |
| --- | --- | --- |
| `AethelnGameplayTags` (extend) | GameCore | `Ability.Dodge`, `Cooldown.Dodge`, `State.Dodging`, `State.DodgeInvulnerable`, `Ability.Block`, `Cooldown.Block`, `State.Blocking`, `State.GuardBroken`, `SetByCaller.Pressure.Guard`. Shared actions use `<Family>.<Name>` (Gameplay Tag conventions in the combat document). Each PR that adds a tag adds its Initial entries row; the semantic IDs are #106's (Q13). |
| `IAethelnMovementActionAuthority` | GameCore | Policy interface the movement component calls; plain types only, no GAS. `GetDodgeMovementDefinition()`, `CanPredictDodge()` (client, local gate), `TryAuthorizeDodge(const FAethelnDodgeStartRequest&)` (server). |
| `FAethelnDodgeMovementDefinition`, `FAethelnDodgeStartRequest` | GameCore | Distance, move duration, and content version; the request is the move's client timestamp, the client's content version, and whether the movement state allows a start. |
| `UAethelnCharacterMovementComponent` (extend) | GameCore | Dodge intent on `FLAG_Custom_2`, dodge simulation state, the displacement, a custom move-data container (content version on flagged moves) and move-response container (dodge state on corrections), `EndDodgeForAuthority()`. |
| `IAethelnPlayerInputReceiver`, `AAethelnPlayerCharacter` (extend) | GameCore | `ReceiveDodgePressed()`: sets the dodge intent when the local gate passes. |
| `AethelnDefenseTypes.h` | GameCombat | `FAethelnDodgeDefinition`, `FAethelnActiveDefense`, `FAethelnBlockedContact`, `EAethelnBlockConsequence`. |
| `UAethelnDodgeAbility` | GameCombat | Movement-carried ability. Commits cost and cooldown, opens the server windows, ends at `ActionEnd`, and ends an active block (Q10). |
| `UAethelnBlockAbility` | GameCombat | Held ability (`bAcceptsRelease`). Registers and clears the defense slot, owns the Guard hook and the Guard break. |
| `UAethelnGuardPressureEffect` | GameCombat | Instant effect: negated Guard modifier from `SetByCaller.Pressure.Guard`. |
| `UAethelnAbilitySystemComponent` (extend) | GameCombat | The movement-carried seam entry and its owner outcome RPC; the defense slot (`GetActiveDefense`); the avoidance window (`IsAvoidingAt`); the `State.Dead` binding that ends defense. |
| `AAethelnPlayerState` (extend) | GameCombat | Implements `IAethelnMovementActionAuthority` by forwarding to its ASC. |
| `IAethelnCombatInputSink` (#60 P6, extend) | GameCore | P5 adds `RequestAbilityRelease(FGameplayTag AbilityId)` beside #60's press. |
| `UAethelnPOCInputComponent` (extend) | GameUI | P5: dodge press (key per Q1) and right-mouse hold, Reticle mode only; Cursor entry releases a held block. |

GameCore stays free of GAS: the movement component reaches the authority only
through the interface, found through `CharacterOwner->GetPlayerState()`. A
pawn without an authority (an AI pawn, or any pawn before P3) never starts a
dodge: the server fails closed.

## The Dodge

### Request and transport

The press sets `bWantsToDodge` on the owning client's movement component, but
only when `CanPredictDodge()` passes. That local gate reads the owner-replicated
cooldown tag and Endurance and the local movement state. It decides whether to
send a request and predict; it is not GAS prediction. The next saved move
carries `FLAG_Custom_2`, and the flag is cleared after that move, so it marks
exactly one move: the start move.

- **Delivery.** Moves with different flags never combine
  (`FSavedMove_Character::CanCombineWith` compares compressed flags, as the
  project relies on at `Source/GameCore/Private/AethelnCharacterMovementComponent.cpp:78-79`).
  A move whose flags differ from the last acknowledged move is important
  (`CMC.cpp:12975-12983`), so the engine resends it with the next packet as the
  old important move (`CMC.h:2598-2601`).
- **Ordering.** The server simulates a move only if its client timestamp passes
  `VerifyClientTimeStamp` (`CMC.cpp:9995`) and only for a positive delta
  (`:10027`). A duplicated copy or an older reordered move is therefore never
  simulated twice, and a zero-delta flagged move is never processed. The engine
  handles client timestamp resets (`CMC.h:2487-2490`), so #18 adds no
  timestamp rule of its own.
- **Content version.** A custom move-data container
  (`CMC.h:2702`) serializes the client's dodge `ContentVersion` on flagged
  moves only.

**Why not a reliable seam request.** A seam RPC on the PlayerState's ASC and
the unreliable move on the pawn travel on different channels with no ordering
between them. When a packet is lost, the old move resent with the next packet
can reach the server before the reliable resend. The server would then either
simulate the move without a dodge and correct the client, or commit a dodge
with no paired move. Carrying the request in the move keeps commit and
displacement in one server step.

### Technical decision T1: the movement-carried seam entry

The dodge is a `UAethelnGameplayAbility` that reaches the seam only through a
server-internal entry, `ProcessMovementCarriedRequest`. It is called only by
the authority interface, only on the server, and only from the server's
simulation of a received move, never from a client replay (the client replays
through `MoveAutonomous` too, `CMC.cpp:8606-8686`). It runs #19's steps with
these substitutions:

| #19 step | Movement-carried entry |
| --- | --- |
| 1 Rate bucket | Unchanged: every flagged move processed draws one token from the connection's bucket, before any lookup |
| 2 Lifecycle | Unchanged |
| 3 Schema version | Not applicable: the move protocol is build-identical (#82 F10, residual risk 4) |
| 4 Sequence | Replaced by the engine's move-timestamp rule (above) |
| 5 Ability lookup | Unchanged; the ability must be flagged movement-carried |
| 6 Content version | The flagged move's dodge `ContentVersion` against the granted ability |
| 7 Phase and instance | `Press` only. The single instance must be inactive, and the movement state must allow a start (no dodge in progress and, under Q3, on the ground). Otherwise `ActivationBlocked` |
| 8 to 10 | Unchanged: cooldown, cost, and tags; activate inside the seam scope; commit; accept |

`ServerSubmitActivation` refuses a movement-carried ability with
`MalformedRequest`, so each ability has exactly one route. The choke point is
unchanged: the entry opens the seam scope for the dodge's spec handle only.

**Alternative (not recommended).** The dodge is not an ability. The server's
movement hook applies #19's shared cost and cooldown effects and replicated
loose tags directly, keeps its own config and content version, and calls
#60's `ResetChain(OtherAction)` itself (the #60 specification allows this).
That leaves #19's seam text unchanged but re-implements step 8 (cooldown,
cost bounds, blocking tags, cheat handling) outside the ability, and #60
loses the activation callback. T1 keeps one eligibility path, so this design
recommends it. Because T1 amends #19's "only way a client starts an ability"
text, it is listed for #19 sign-off in [Open Decisions](#open-decisions).

### Predicted displacement

The dodge runs inside the movement simulation, in
`UpdateCharacterStateBeforeMovement` (called from `PerformMovement`,
`CMC.cpp:2874`), on every path: client prediction, client replay, and the
server.

- **Start predicate.** The flag is set, no dodge is in progress, and the
  character is walking (Q3). On the client and in replay that is enough, because the
  flag itself records the client's decision to predict. On the server the
  authority must also accept. The start applies from the beginning of the
  flagged move.
- **Direction.** The yaw-only direction of the move's own acceleration (after
  `ConstrainInputAcceleration`, as the jump takeoff uses), fixed for the whole
  dodge. With no input, the neutral direction applies (Q2). Remote clients see
  the server's path through replicated movement.
- **Displacement.** While the dodge is in progress, walking physics runs with
  its velocity set to `Direction * Distance / MoveDuration`, ignoring input
  acceleration. Elapsed time advances by each move's delta; the move that
  reaches `MoveDuration` covers only the remaining time, so the path on open
  ground is exactly `Distance`. Floors, steps, and slopes follow engine walking
  rules; collision shortens the path the same way on client and server.
  Leaving the ground ends the dodge. Facing rules are unchanged.
- **Correction.** The dodge state (in progress, elapsed time, direction) is
  part of the server's correction, through a custom move-response container
  (`CMC.h:2728`; `Runtime/Engine/Classes/GameFramework/CharacterMovementReplication.h:343-367`).
  The client restores it before replaying, and does not restore dodge state from
  its saved moves. A refused dodge is therefore corrected once: the server
  corrects at or after the flagged move, which acknowledges that move, so replay
  never applies it again.
- **Server end.** `EndDodgeForAuthority()` ends a dodge on the server outside a
  move (life state, avatar loss). The owner is corrected; this is never
  predicted.

**Consistency across clients** follows: the owning client and the server run
the same start move, the same direction, and the same per-move displacement.
Simulated proxies interpolate the server's replicated movement. A difference
appears only when the server refuses a predicted start, and then the
correction converges on the server.

### Server-owned windows

Let `S` be the server world time at which the server processed the accepted
flagged move. Moves are dispatched before the world time advances, so `S` is
the previous frame's time, as for any request. #60's
**requests before contacts** rule therefore decides a dodge and a contact in
the same frame: the dodge is validated first and is stamped with that earlier
time.

| Value | Meaning |
| --- | --- |
| `InvulnerableStart`, `InvulnerableEnd` | Invulnerability is `[S + InvulnerableStart, S + InvulnerableEnd)` on server world time |
| `ActionEnd` | The activation ends and `State.Dodging` is removed at `S + ActionEnd` |
| `Distance`, `MoveDuration` | The displacement, in client move time |

- **The window ignores the displacement.** Withheld, delayed, or bunched moves
  change when the displacement finishes on the server. They never move the
  window, which is fixed at acceptance.
- **Tags.** `State.Dodging` lasts `[S, S + ActionEnd)`, and
  `State.DodgeInvulnerable` lasts the invulnerability window. Both are loose
  tags with `EGameplayTagReplicationState::TagOnly`
  (`GAS/Public/AbilitySystemComponent.h:656`;
  `GAS/Public/GameplayEffectTypes.h:1050-1057`), so the owner and observers can
  present them. #60's timeline driver applies their boundaries at exact times,
  and the seam applies a requester's due boundaries before it validates, as #60
  specifies for its own (dependency 1 on #60).
- **Avoidance query.** `IsAvoidingAt(ContactTime)` is true if
  `S + InvulnerableStart <= ContactTime < S + InvulnerableEnd`. Half-open:
  the start belongs to the window, the end does not.
- **Grant validation** refuses the dodge unless every value is finite,
  `Distance > 0`, `MoveDuration > 0`,
  `0 <= InvulnerableStart < InvulnerableEnd <= ActionEnd`, and
  `MoveDuration <= ActionEnd`, and unless the ability is movement-carried,
  `Press`-only, and lists `State.Dead` among its blocking tags. If Q4 is
  adopted, it also requires a positive cost or a positive cooldown.

### Cost and cooldown

#19 P4 commits them: `CommitAbility` applies one Endurance cost (optional) and
one `Cooldown.Dodge` effect at acceptance, inside the server move. Both are
`TBD` (#107). A refused dodge spends nothing. Nothing is refunded if the
displacement is later cut short, because the commit and the window are
already authoritative.

### Rejections

Each flagged move the server processes gets one outcome. Rejections have no
side effect.

| Case | Result |
| --- | --- |
| Duplicated or reordered move copy | Never simulated; no outcome (transport, not a request) |
| Flag on a zero-delta move | Never simulated; no outcome |
| Bucket empty | `RateLimited` (#19's limited-window policy) |
| No avatar, or a dying avatar | `ConnectionClosed`, `ActorDestroyed` |
| Content version mismatch | `IncompatibleVersion` |
| Dodge already in progress, ability active, airborne (Q3), or a blocking tag such as `State.Dead` | `ActivationBlocked` |
| `Cooldown.Dodge` present | `OnCooldown` |
| Endurance below cost | `InsufficientResource` |
| Commit failed | `InternalFailure` |

Repeated presses during a dodge or its cooldown are therefore rejected
deterministically, and a hostile client that flags every move is bounded by the
bucket.

### Disconnect, life state, and missing presentation

- **Avatar loss** (unpossession, destroy while possessed, logout, disconnect)
  reaches #19's null-pawn case, which cancels all abilities. Ending the dodge
  ability closes the windows at the processing time. Nothing carries over to a
  new avatar or a new PlayerState.
- **`State.Dead`**, added through the test seam until #21 applies it, is bound
  with `RegisterGameplayTagEvent` (`GAS/Public/AbilitySystemComponent.h:720`)
  as #60 binds it. It cancels the dodge ability (closing the windows at that
  time), calls `EndDodgeForAuthority()`, and blocks new dodges. #21 owns the
  integrated death and respawn case.
- **Missing presentation changes nothing.** No montage, notify, root motion,
  or effect is read. Animation visualizes the server windows and the
  replicated movement.

## The Block

### Activation through the seam

Right mouse sends `RequestActivation(Ability.Block, Press)` on press and
`Release` on release, through #60's input sink. `UAethelnBlockAbility` sets
`bAcceptsRelease`, so #19's step 7 governs both phases:

- A `Press` while the block is active is `ActivationBlocked`.
- A valid `Release` is accepted and ends the block.
- A `Release` while the block is not active (after a Guard break, death, or a
  dodge) is `ActivationBlocked`. It is benign, and the client treats it as
  "already lowered".
- Duplicated and reordered requests get #19's sequence reasons; after #60 P2,
  steps 6a to 6d apply to both phases.

On acceptance at server time `S`, `CommitAbility` applies the optional
Endurance cost and the `Cooldown.Block` effect (both `TBD`; a zero cooldown
needs #19 P4's zero-cooldown behavior, #60 dependency 2), and the ability
registers the defense slot. The block holds until a `Release`, a Guard break,
a dodge (Q10), `State.Dead`, or avatar loss. The client ends it only through
a seam `Release`: the abilities are `ServerOnly` in both policies. On Cursor-mode entry the client
sends a `Release` for a held block, as the #82 contract requires
(`docs/input-camera-free-aim-spike.md:135`).

### Defense state exposed to #60

The owner decision requires the block to expose exactly three things to #60:
a defense state tag, an authored defense arc, and a server hook for the Guard
consequence. They live in one server-only slot on the ASC, which #260's Hold
the Line also uses:

```cpp
/** The one active directional defense on an ASC. Server only. */
struct GAMECOMBAT_API FAethelnActiveDefense
{
	FGameplayTag StateTag;                    // State.Blocking (Hold the Line: its own state tag)
	double ActiveFromServerTime = 0.0;        // inclusive: S + RaiseSeconds
	double ActiveUntilServerTime = TNumericLimits<double>::Max(); // exclusive: set on release, break, or cancel
	float ArcHalfAngleDegrees = 0.0f;         // authored, TBD
	TDelegate<EAethelnBlockConsequence(const FAethelnBlockedContact&)> OnBlockedHit; // #60 calls it once per blocked contact
};
```

- **State tag.** `State.Blocking` is a loose `TagOnly` tag held while the slot
  is registered, for gating and observers. #60 evaluates the state at the
  contact time against the slot's interval, not the tag's presence at
  resolution time. That makes the boundary exact: a release processed in a
  frame is stamped with the previous frame's time, so under the
  requests-before-contacts rule none of that frame's contacts are blocked.
- **Arc.** A contact is inside the arc when the angle between the defender's
  actor yaw and the incoming direction is at most `ArcHalfAngleDegrees`
  (inclusive). The incoming direction is the horizontal vector from the
  defender's capsule center to the attacker's combat-frame origin at the
  contact time. #60 already interpolates that origin per sub-step and holds
  defenders at their end-of-frame pose. A zero-length direction is outside
  (fails closed). The actor yaw is server-simulated and rate-limited on the
  ground; the control rotation is client-supplied and is never used.
- **One slot.** Registering while a slot is active fails closed. Block and Hold
  the Line block each other (Q10), so this cannot happen through content.

### The Guard hook

```cpp
struct GAMECOMBAT_API FAethelnBlockedContact
{
	TWeakObjectPtr<UAethelnAbilitySystemComponent> Source; // attacker's ASC; effects are applied from it
	FGuid ActivationId;
	FGameplayTag AbilityId;
	uint32 ContentVersion = 0;
	double ContactTime = 0.0;
	float GuardPressure = 0.0f;   // the attack's authored pressure (Q7), TBD
};

enum class EAethelnBlockConsequence : uint8 { Blocked, GuardBroken };
```

#60 calls `OnBlockedHit` once per blocked contact; its allowance records stop
a duplicate, reordered, or replayed candidate from reaching the hook again.
The block's hook:

1. Applies `UAethelnGuardPressureEffect` from the attacker's ASC with
   `GuardPressure`. The attribute set clamps Guard at zero.
2. If Guard is now zero, breaks the guard: sets the slot's
   `ActiveUntilServerTime` to the contact time, ends the block activation,
   and removes `State.Blocking`. Under the Q8 recommendation it also adds
   `State.GuardBroken` for `GuardBreakSeconds` (`TBD`), which the block lists
   among its blocking tags. It returns `GuardBroken`.
3. Otherwise returns `Blocked`.

#60 records the returned consequence and stops resolving that contact. Under
the Q6 recommendation that means no family mitigation, no Ward, and no Health
change; if the owner chooses chip damage instead, the consequence gains the
part that continues. The same contact is never re-scored. Because the slot's
end equals the contact time and is exclusive, a later contact, including one at
the same time that sorts later in #60's total order, sees the broken state.
This follows the canon rule that the contact-level defense snapshot does not
change halfway through a contact.

### Interaction with #60 contacts

- **Order.** Avoidance resolves before the block. A target inside its dodge
  window yields `Avoided`, and the hook is not called. An accepted dodge also
  ends the block (Q10).
- **No friendly fire.** Only enemy steps reach a player's defense in the
  prototype (owner decision 3). The tests use enemy steps registered directly
  with #60's driver.
- **Unblockable attacks.** An authored unblockable rule would skip step 4; no
  prototype attack has one, so none is designed.
- **Prediction.** The client may show a raise at press; a rejection outcome
  cancels it. Guard, the slot, and results are never predicted.

## Prediction Policy

- **Predicted:** the dodge displacement only, as supported custom movement
  with saved moves (Prediction Matrix). The flag records the client's decision
  to predict, and the server's correction is authoritative.
- **Not predicted:** cost, cooldown, `State.*` tags, the invulnerability
  window, the block state, Guard, and every contact result. Both abilities are
  `ServerOnly` in both policies. TC-008 is untouched.
- **Local gate:** reading the owner-replicated cooldown tag and Endurance to
  decide whether to press-predict is presentation logic. A stale local view
  produces a refused dodge and one correction, which P5 measures.

## Replication and Outcome Reporting

| Message or state | To | Reliability |
| --- | --- | --- |
| `ClientMovementActivationOutcome(float ClientTimeStamp, EAethelnActivationResult Result)` (new) | Owner, per processed flagged move | Reliable |
| `ClientActivationOutcome(Sequence, Result)` (#19) | Owner, per block request | Reliable |
| Movement correction with dodge state | Owner | Engine move response |
| Replicated movement | Observers | Engine |
| `State.Dodging`, `State.DodgeInvulnerable`, `State.Blocking`, `State.GuardBroken` | Owner and observers | Loose `TagOnly` tags |
| Result cues `Avoided`, `Blocked`, `GuardBroken` | Everyone relevant | #60's unreliable multicast |

- **A separate outcome RPC.** Movement-carried outcomes do not share #19's
  sequence space; #19's client rule ("an outcome for any later sequence means
  every earlier pending request was suppressed") would break if they did. The
  client matches movement-carried outcomes to its pending flagged moves in
  order. They are reliable for #19's reason: they are the only reason signal
  #61 gets. Their volume is bounded by the bucket, and a rate-limited window
  sends at most one.
- **Opponents see state, not values.** Guard stays owner-only (#19); the
  defense and Guard-break cues are canon readability cues.

## Observability Events

The #19 emission rules apply: one event and one metric per outcome, resolved
at emit time, never changing gameplay when the sink fails, with allowlisted
correlation only. No GameNet vocabulary changes.

| Event | Subject | Safe reason | Correlation |
| --- | --- | --- | --- |
| Dodge accepted | `Dodge` | `Accepted` | Activation id, ability id, server ordinal |
| Dodge rejected | `Dodge`; `Cooldown` for `OnCooldown`; `Resource` for `InsufficientResource` | #19's mapping | Ability id from step 5, server ordinal |
| Block press or release accepted | `Block` | `Accepted` | #19 seam fields |
| Block rejected | `Block`; `Cooldown`; `Resource` | #19's mapping | #19 seam fields |
| Committed `Avoided` result (#60 emits) | `Dodge` | `Accepted` | The attack's activation id, ability id, sequence |
| Committed `Blocked` or `GuardBroken` result (#60 emits) | `Block` | `Accepted` | Same |

- **Server ordinal.** Movement-carried requests have no client sequence, and
  the contract drops events with sequence 0. The ASC therefore issues a
  per-PlayerState movement-activation ordinal, starting at 1, as #60 notes #20
  must do for AI.
- **Bounded volume.** Every flagged move draws from the bucket, so a flood
  enters #19's limited window: one event, one outcome, and two metric samples
  at most.
- **No target identity** and no Guard value appear in any event; the Guard
  break is visible in the cue and the result record.
- **Corrections** from refused predicted dodges are movement corrections,
  counted by the movement correction telemetry (#17, #2), not new #18 events.

## Data-Driven Tuning

All values are `TBD`. A PR may add a placeholder so the game runs; it is
reviewed as a placeholder, not approved tuning. Every authoritative change
bumps the ability's `ContentVersion`.

| Config section | Keys |
| --- | --- |
| `[/Script/GameCombat.AethelnDodgeAbility]` | `ContentVersion`; `ProvisionalEnduranceCost` (optional); `ProvisionalCooldownSeconds`; `ProvisionalDodge` (`Distance`, `MoveDuration`, `InvulnerableStart`, `InvulnerableEnd`, `ActionEnd`) |
| `[/Script/GameCombat.AethelnBlockAbility]` | `ContentVersion`; `ProvisionalEnduranceCost` (optional); `ProvisionalCooldownSeconds`; `ProvisionalRaiseSeconds`; `ProvisionalArcHalfAngleDegrees`; `ProvisionalGuardBreakSeconds` |
| Guard pressure | Per Q7: an attack-authored `GuardPressure` on #60's step definition |

The movement component reads the dodge's distance, move duration, and content
version from the ability through the authority interface, so one definition
serves client and server. Block grant validation requires finite values,
`RaiseSeconds >= 0`, `0 < ArcHalfAngleDegrees <= 180`,
`GuardBreakSeconds >= 0`, `bAcceptsRelease`, and `State.Dead` among its
blocking tags, plus the tags the adopted Q8 and Q10 answers name. Both fail
closed. The keys live in shared `Config/DefaultGame.ini` for #19's reason.

## Dependencies on #19

1. **Cost and cooldown (P4)** must be on `develop` before P3 and P4. Zero
   cooldown behaves as #60 dependency 2 states.
2. **Movement-carried entry (P3, T1).** P3 adds `ProcessMovementCarriedRequest`,
   the movement-carried ability flag, the `ServerSubmitActivation` refusal of
   such abilities, the new outcome RPC, and the server ordinal. P3 updates the
   #19 specification: Decision 4 and Activation Seam (a second, server-internal
   transport into the same pipeline), Validation order (the substitution
   table), Rejection Telemetry (the ordinal, and the subject category for
   ordinary results taken from the ability: `Dodge`, `Block`, otherwise
   `Ability`), and Closing the Stock Routes (the entry is the only
   server-internal route that opens a seam scope). P3 adds rows to T11 (a seam
   request for a movement-carried ability is `MalformedRequest`), T13 (the
   entry opens a scope only for its own spec), T15 (the flag requires
   `Press`-only and no `bAcceptsRelease`), and T21 (ordinal events).
3. **Life state.** #18 binds `State.Dead` for its own abilities; #19's lifecycle
   is unchanged.
4. **Open Decision 6** (blocking and cancel relations) is answered for dodge
   and block by Q10.

## Dependencies on #60

1. **P3: boundaries.** The timeline driver applies #18's window boundaries
   (pass step 4), and the seam and the movement-carried entry apply a
   requester's due boundaries before validating. P3 exposes a boundary
   registration for timelines that are not chain steps.
2. **P4: time-exact avoidance.** Step 3 asks `IsAvoidingAt(ContactTime)`;
   `State.DodgeInvulnerable` joins the authored avoidance-tag set for observers
   and gating.
3. **P4: the defense step.** Step 4 reads `GetActiveDefense()`, evaluates the
   slot's interval at the contact time and the arc as defined above, calls
   `OnBlockedHit` once, records its consequence, and ends that contact's
   resolution. #60 P4's test defense state uses the same slot.
4. **Guard pressure (Q7).** If attack-authored, #60's step definition gains
   `GuardPressure` with a content-version bump, in whichever of #60 P4 and #18
   P4 lands second.
5. **Result events.** The committed-result event uses subject `Dodge` for
   `Avoided` and `Block` for `Blocked` and `GuardBroken`.

## Test Plan

Names follow `Aetheln.<Area>.<Group>.<Case>`, as in #19 and #60. **H** is a
headless authority world with an injected clock and the in-memory sink. **P**
is PIE with a dedicated server and two clients, recorded as manual steps.
**K** is a packaged run. Tests that pin a policy set their own values, never
tuning. Pure movement tests live beside the movement component, because
GameCore cannot depend on GameCombat; they use a test authority and keep the
existing `Aetheln.Movement.Net` group. Everything that touches the ASC lives in
`GameTests` as `Aetheln.GameCombat.Defense.*`. That needs a test-only accessor
on the movement component (P2) so `GameTests` can drive client moves, as the
movement tests do through `friend`.

The network-condition cases are automated simulations (owner decision 4). A
scripted delivery queue feeds the server through the engine's
`ServerMove_PerformMovement` (public, `CMC.h:2608`), so the timestamp rules run
for real. It delays, duplicates, reorders, and drops moves and seam requests
against the injected clock: **normal** delivers in order at once, **high
latency** delays every message by a fixed test interval, and **packet loss**
drops chosen copies and models a reliable resend as a later arrival.

| # | Test | PR | Kind | What it proves |
| --- | --- | --- | --- | --- |
| D1 | `Aetheln.Movement.Net.DodgeFlagRoundTrip` | P2 | H | `FLAG_Custom_2` marks only the start move; it does not combine with neighbors; the move is important; the server restores it; sprint and aim flags are unchanged |
| D2 | `Aetheln.Movement.Net.DodgeDisplacementParity` | P2 | H | Prediction pair, test authority accepting: forward, lateral, diagonal, backward, and neutral input, with sprint, aim steering, and a turned camera. Every move is accepted; the path equals the test distance on open ground; the direction stays fixed; the proxy converges on the server |
| D3 | `Aetheln.Movement.Net.DodgeCorrectionReplay` | P2 | H | A forced correction mid-dodge restores dodge state from the response and replays the same path, once and repeatedly; saved moves never restore dodge state |
| D4 | `Aetheln.Movement.Net.DodgeRefusedRollsBack` | P2 | H | Test authority refuses: the server moves without a dodge, corrects at the flagged move, the replay does not reapply it, and the client ends at the server's position |
| D5 | `Aetheln.Movement.Net.DodgeDeliveryConditions` | P2 | H | Normal, high-latency, and packet-loss delivery; a duplicated copy is simulated once; an older reordered move is dropped; a lost first copy is processed once from the old-move resend; all copies lost gives no dodge and no authority call; a zero-delta flagged move is not processed; the authority is called at most once per dodge |
| D6 | `Aetheln.Movement.Net.DodgeGroundAndCollision` | P2 | H | A wall shortens the path equally on both sides; leaving a ledge ends the dodge; an airborne flag does not start one (Q3 pinned with a test policy); no authority means no dodge |
| D7 | `Aetheln.GameCombat.Defense.DodgeDefinitionFailsClosed` | P3 | H | Grant refused for non-finite or non-positive values, each ordering violation, `MoveDuration > ActionEnd`, a missing movement-carried flag, missing blocking tags, and (if Q4) zero cost with zero cooldown |
| D8 | `Aetheln.GameCombat.Defense.DodgeMovementCarriedRoute` | P3 | H | The dodge activates only through the entry; `ServerSubmitActivation` for it is `MalformedRequest`; the stock routes stay refused; the scope opens for the dodge spec only; content version mismatch is `IncompatibleVersion`; precedence follows the substitution table |
| D9 | `Aetheln.GameCombat.Defense.DodgeCostCooldownAndRepeats` | P3 | H | Acceptance applies one cost and one cooldown; flagged moves during the dodge give `ActivationBlocked`, during the cooldown `OnCooldown`, with low Endurance `InsufficientResource`; rejections have no side effect; one outcome per processed flagged move; each draws one token |
| D10 | `Aetheln.GameCombat.Defense.DodgeWindowBoundaries` | P3 | H | `S` is the processing time; `IsAvoidingAt` is true at `S + InvulnerableStart` and false at `S + InvulnerableEnd`; each tag exists exactly over its window; a request at exactly `S + ActionEnd` is not blocked by the dodge; withheld moves neither extend nor shorten the window |
| D11 | `Aetheln.GameCombat.Defense.DodgeEndToEnd` | P3 | H | A client pawn and a server pawn with the real PlayerState authority: an accepted dodge produces no correction and the predicted path; a predicted dodge refused for cooldown rolls back with one correction; the owner receives one outcome per flagged move |
| D12 | `Aetheln.GameCombat.Defense.NetworkConditionsDodge` | P3 | H | The D5 profiles with the real authority: each dodge commits at most once, with no double cost or cooldown; the window starts at server arrival; outcomes arrive in order; a dropped flagged move commits nothing |
| D13 | `Aetheln.GameCombat.Defense.LifeStateCancelsDefense` | P3 (block rows P4) | H | `State.Dead` added through the test seam ends an active dodge window at that time, ends the server displacement, and ends a held block; later dodge and block requests get `ActivationBlocked`; re-possession revives no invulnerability or defense |
| D14 | `Aetheln.GameCombat.Defense.TeardownMidDodgeAndBlock` | P3 (block rows P4) | H | Unpossession, avatar destruction, and PlayerState teardown during the window and during a held block: one end, no window or slot afterwards, and a new PlayerState starts clean |
| D15 | `Aetheln.GameCombat.Defense.DodgeTelemetry` | P3 | H | Events and metrics per the table with a nonzero ordinal; a flood of flagged moves stays within #19's window bound; the public copy has no diagnostic code |
| D16 | `Aetheln.GameCombat.Defense.RunsWithoutPresentation` | P3 (block rows P4) | H | Dodge and block run, end, and (from P4) resolve contacts with no mesh, montage, or notify |
| D17 | `Aetheln.GameCombat.Defense.BlockDefinitionFailsClosed` | P4 | H | Grant refused for each invalid value and for missing `bAcceptsRelease` or blocking tags |
| D18 | `Aetheln.GameCombat.Defense.BlockHoldAndRelease` | P4 | H | Press registers the slot from `S + RaiseSeconds`; Release ends it at the stamped time; Press while active and Release while inactive give `ActivationBlocked` with no side effect; a replayed Release gets a sequence reason; cost and cooldown apply once |
| D19 | `Aetheln.GameCombat.Defense.BlockArcAndBoundaries` | P4 | H | Pure evaluator: inside exactly at the half-angle, outside just beyond; zero-length direction outside; contact at `S + RaiseSeconds` blocked; contact at the release time not blocked; the defender's actor yaw counts and the control rotation does not |
| D20 | `Aetheln.GameCombat.Defense.BlockedContactCallsGuardHookOnce` | P4 | H | An enemy test step hits a blocking target facing it: `Blocked`, one hook call, Guard lowered once, Health unchanged; facing away gives an ordinary hit; duplicated and reordered candidates call the hook no second time |
| D21 | `Aetheln.GameCombat.Defense.GuardBreak` | P4 | H | Pressure at or above Guard: the contact is still blocked, Guard is zero, `GuardBroken` is recorded, the block ends at the contact time, `State.GuardBroken` lasts the test duration, a Press is refused meanwhile, and a later contact in the same frame, including a same-time one later in the total order, is not blocked |
| D22 | `Aetheln.GameCombat.Defense.AvoidanceBeatsContact` | P4 | H | An enemy contact inside the window is `Avoided` with no damage, no Guard change, and no hook call; at the window end it hits; a dodge processed in the same frame as a contact follows the requests-before-contacts rule |
| D23 | `Aetheln.GameCombat.Defense.ActionRelations` | P4 | H | The adopted Q10 relations with test tags: a dodge ends a block; a block is refused during `State.Dodging`; the chain's commitment tag blocks both; a dodge or block activation resets the chain (`OtherAction`); a second defense slot fails closed |
| D24 | `Aetheln.GameCombat.Defense.NetworkConditionsBlock` | P4 | H | Press and Release under normal, high-latency, and packet-loss delivery around enemy contacts: blocked exactly when the server arrival precedes the contact under the stamping rule; duplicated and reordered requests get sequence reasons; the hook never runs twice |
| D25 | `Aetheln.GameCombat.Defense.DefenseResultTelemetry` | P4 | H | `Avoided`, `Blocked`, and `GuardBroken` emit the events in the table, with no target identity and no Guard value |
| D26 | `Aetheln.POC.Input.DodgeAndBlockBindings` | P5 | H | A dodge press sets the flag only in Reticle mode and when the local gate passes; right mouse maps to Press and Release; Cursor entry releases a held block; the recapture click is never a block |
| D27 | `Aetheln.GameCombat.Net.DodgeAndBlockTwoClients` | P5 | P | Additional PIE evidence under #82 C1 and C2: the owner's predicted dodge and the other client's view follow the same path; outcomes go to the owner only; both clients see the tags and cues; refused-dodge correction rates recorded |
| D28 | Packaged two-client dodge and block run | later | K | Evidence for #2 and #48; not required to merge #18 |

CI runs a frozen two-test filter (`scripts/ci/Invoke-UnrealAutomationTests.ps1:14-15`),
so each code PR records local automation evidence at its exact head on the
pinned engine, as #19 and #60 do: P2 runs `Aetheln.Movement`; P3 and P4 run
`Aetheln.GameCombat` and `Aetheln.Movement`; P5 runs `Aetheln.POC` and records
the manual PIE steps.

## Acceptance-Criteria Mapping

| Issue #18 item | Tests and text |
| --- | --- |
| AC1 Dodge consumes the configured resource or cooldown | D7, D9, D12; [Cost and cooldown](#cost-and-cooldown) |
| AC2 Direction and distance are consistent across clients | D2, D3, D5, D6, D11, D27; [Predicted displacement](#predicted-displacement) |
| AC3 Server owns the invulnerability window | D10, D12, D13; [Server-owned windows](#server-owned-windows) |
| AC4 Damage during valid invulnerability is rejected | D10, D22 |
| AC5 Invalid repeated dodge requests are rejected | D5, D8, D9, D12; [Rejections](#rejections) |
| DoD1 Normal, high-latency, and packet-loss cases are tested | Automated (owner decision 4): D5, D12, D24. D27 is additional PIE evidence. |
| DoD2 The server-owned authored window is authoritative; animation only visualizes it | D10, D16; [Prediction Policy](#prediction-policy) |
| DoD3 Boundary timestamp, duplicate/reordered request, cooldown, distance, disconnect, and missing-presentation cases | Boundaries D10, D19, D21; duplicate and reordered D5, D12, D24; cooldown D9; distance D2, D6; disconnect D14, D27; missing presentation D16 |
| DoD4 Life-state cancellation through an authoritative test seam; #21 owns integrated death and respawn | D13; [Disconnect, life state, and missing presentation](#disconnect-life-state-and-missing-presentation) |
| Owner decisions 1, 2, 5: the block and its exposure to #60 | D18 to D21, D23; [The Block](#the-block) |

## Phased Delivery

Each PR targets `develop`, uses `Refs #18`, stays small, and leaves the spike
files untouched.

| PR | Scope | Depends on |
| --- | --- | --- |
| **P1** | This document and the index entry. Docs only. | Lead review |
| **P2** Dodge movement | GameCore only: the authority interface and definition structs, `FLAG_Custom_2`, dodge simulation state, displacement, custom move-data and move-response containers, `EndDodgeForAuthority`, the receiver method, the test accessor; D1 to D6 with a test authority; the `docs/movement-poc.md` flag note. No game code implements the authority yet, so no dodge runs in game. | P1 |
| **P3** Dodge authority | Dodge tags, `UAethelnDodgeAbility`, the movement-carried entry and outcome RPC, the ordinal, the PlayerState authority, windows and boundaries, `IsAvoidingAt`, the `State.Dead` binding, telemetry, the #19 specification and fixture changes; D7 to D16 (dodge rows). | P2, #19 P4, #60 P3 (boundary registration) |
| **P4** Block and contact integration | Block tags, `UAethelnBlockAbility`, the defense slot, `UAethelnGuardPressureEffect`, the Guard hook and break, the Q10 relations; D13, D14, D16 block rows, D17 to D25. | P3, #60 P4, the answers to Q6 to Q8 and Q10 |
| **P5** Bindings and two-client evidence | The receiver and input-sink release, the GameUI dodge key and right-mouse hold, Cursor-entry release; D26, D27. | P4, #60 P6 (input sink), #19 P5 (input-enabled pawn), Q1 |

Guard and Endurance recovery are not #18 phases unless the owner assigns them
(Q9).

## Owner Decisions

Recorded as decided. Decisions 1, 2, and 5 are on
[#18](https://github.com/ShayShimoni/aetheln-online/issues/18) from the #60
design review (PR #258); decisions 3 and 4 were made on
[#60](https://github.com/ShayShimoni/aetheln-online/issues/60) as OQ1 and OQ9
(owner, 2026-10-05).

| # | Decision | Where it applies |
| --- | --- | --- |
| 1 | #18 owns the right-mouse block action alongside dodge. | [The Block](#the-block) |
| 2 | #60 only resolves whether an incoming hit is blocked against an active defense state. | [Defense state exposed to #60](#defense-state-exposed-to-60), [Dependencies on #60](#dependencies-on-60) |
| 3 | No friendly fire in the prototype. | [Interaction with #60 contacts](#interaction-with-60-contacts); enemy attackers in D20 to D24 |
| 4 | Network-condition tests are automated simulations. | D5, D12, D24; [Test Plan](#test-plan) |
| 5 | #18's block must expose to #60 three things: a defense state tag, an authored defense arc, and a server hook for the Guard consequence of a blocked hit, which #60 calls once per blocked hit. | [Defense state exposed to #60](#defense-state-exposed-to-60), [The Guard hook](#the-guard-hook) |

## Open Decisions

All stay open until the named owner decides.

**Tuning (`TBD`; owners #107, with #45 for budgets and network bounds):**
dodge distance and move duration; the invulnerability window start and end;
the dodge action end; dodge Endurance cost and cooldown; block raise time; block
arc half-angle; block Endurance cost and cooldown; Guard pressure per attack;
Guard break duration; the rate-bucket values (#45).

**Product questions, each with a recommended answer:**

| # | Question | Recommendation |
| --- | --- | --- |
| Q1 | Which key is the default dodge binding? | One remappable key, default Left Ctrl: Space is jump, Left Shift sprint, Left Alt the Cursor toggle, and the mouse buttons are attack and block. |
| Q2 | Where does a dodge with no movement input go? | Backward relative to the camera yaw (a backstep), with the same authored distance. |
| Q3 | Can the player dodge while airborne? | No. A flagged move while not walking gets `ActivationBlocked`. |
| Q4 | Must a dodge always cost Endurance or have a cooldown? | Yes. Grant validation refuses a dodge whose cost and cooldown are both zero, so the acceptance criterion always holds; the values stay with #107. |
| Q5 | Does blocking restrict movement speed or turning? | No, not in the prototype phases. Authored restrictions come later with #17's predicted movement, as for attacks (#60 OQ4). |
| Q6 | Does a blocked hit deal any Health damage (chip)? | No. A blocked contact stops at the defense step. |
| Q7 | Where does Guard pressure come from? | From the attack: each attack step authors its `GuardPressure` (canon gives Gate Step authored Guard pressure, `docs/characters-and-factions.md:313-314`). The alternative, a defense-side conversion of blocked damage, would replace one hook field. |
| Q8 | What does a Guard break do, and can the block be raised with zero Guard? | It ends the block and prevents raising it again for an authored duration, with no stagger or interruption (those stay per-step #60 rules). A Press with zero Guard gets `InsufficientResource`. |
| Q9 | Who owns Guard and Endurance recovery? No issue does today (`docs/gas-foundation.md` Cost and cooldown: "resource recovery is not #19 scope"). Without it, Guard only falls until #21's respawn allowlist. | A new ticket under #19's resource grammar owns passive and delayed server-clock recovery for both, with values from #107, before P5's feel evidence. #18 does not design it. |
| Q10 | Blocking and cancel relations (#19 Open Decision 6, for dodge and block). | An accepted dodge ends a held block. A block is refused while `State.Dodging` holds. The chain's commitment tag blocks both, and their activation after `CancelOpen` resets the chain. An attack press while blocking is refused (release first). Block and Hold the Line block each other. |
| Q11 | Is a perfect block or parry in scope? | No. The canon places it in a Thread (`docs/characters-and-factions.md:287`), outside the default prototype. |
| Q12 | Must #17 bound airborne facing before the block lands? Airborne aim tracking sets server facing with no rate limit (`docs/movement-poc.md:270-275`), so a jumping blocker could swing the arc instantly. | Yes: #17 bounds it before P4 merges, or the owner accepts the risk for the prototype (residual risk 3). |
| Q13 | Semantic IDs for the shared dodge and block actions. | Proposed for #106: `combat.action.dodge` and `combat.action.block`. The tags do not wait on the IDs. |

**Technical decision for #19 sign-off:**

| # | Decision | Recommendation |
| --- | --- | --- |
| T1 | Carry the dodge request on the movement stream into a movement-carried seam entry, or make the dodge a non-ability movement action that applies #19's effects directly. | The movement-carried entry (see [Technical decision T1](#technical-decision-t1-the-movement-carried-seam-entry)). It keeps one eligibility path, and the #19 text changes are listed in [Dependencies on #19](#dependencies-on-19). |

Decisions that belong to other owners, recorded so they are not lost: rewind
for dodge and block ordering (#2, TC-002); every numeric value (#45, #107);
the remapping mechanism and controller layout (#82); display names.

## Residual Risks and Known Gaps

1. **Present-time unfairness.** The press reaches the server about half a
   round trip late, and the window starts there. A dodge that looked timely
   locally can still be hit. Owner: #2 (TC-002).
2. **Client move time.** The displacement follows client move timestamps, and
   engine time-discrepancy detection is off (#82 F8), so a fast client clock
   finishes the displacement sooner in server time. The window is unaffected.
   Owners: #17, #2.
3. **Airborne facing** has no rate bound, which matters for the block arc
   (Q12). Owner: #17.
4. **Move data has no schema version** (#82 F10). The dodge field in the
   custom move data relies on build-identical clients and servers.
5. **No resource recovery** until Q9 is answered.
6. **Refused predictions are visible.** A stale local gate produces one
   correction. P5 records the rate.
7. **PlayerState relevancy.** The state tags replicate from an always-relevant
   PlayerState, which does not scale. Owners: TC-001, #45.
8. **Outcome keys repeat across timestamp resets.** The client matches
   movement-carried outcomes by order; the key alone is not unique.
9. **No death transition** until #21. A zero-Health target is inert to #60 but
   still holds its defense state until `State.Dead` arrives.
