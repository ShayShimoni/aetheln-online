# Attack Timeline and Three-Hit Combo

## Document Status

This is the implementation specification for
[Issue #60](https://github.com/ShayShimoni/aetheln-online/issues/60): the
server-owned, pure-free-aim attack timeline, the authored contact pipeline, and
the Oathscar sword-and-shield three-hit basic chain. It is phase P1 of the
issue and contains no code. Pull requests P2 to P7 deliver it (see
[Phased Delivery](#phased-delivery)).

It is subordinate to
[Combat and Networking Architecture](combat-and-networking-architecture.md),
TA-002, TA-003, TA-004, TC-002, and TC-008 in
[Architecture Decisions](architecture-decisions.md), and the canonical product
documents, and it changes no product rule. It consumes the versioned activation
seam specified in [Gameplay Ability System Foundation](gas-foundation.md)
(Issue #19) and closes findings F1 and F2 of the
[Input, Camera, and Free-Aim Spike](input-camera-free-aim-spike.md) (Issue #82)
at the policy level. Every timing, range, shape, damage, cost, aim, timestamp,
and sampling value stays `TBD`; a `Provisional...` config key is a named
placeholder, never tuning. C++ names are proposed code names. Oathscar, Gate
Step, Sworn Rebuke, Hold the Line, Endurance, and Guard are working names.

**Citations.** Repository `path:line` citations are valid at `develop`
revision `ab296d0`; citations into the combat document and the #19
specification use section names, because lines move. Engine citations are
relative to the root of the pinned UE 5.8.1 source, revision `71fe36aac5`.
`GAS/` abbreviates
`Engine/Plugins/Runtime/GameplayAbilities/Source/GameplayAbilities/`,
`GAS-UHT/` abbreviates
`Engine/Plugins/Runtime/GameplayAbilities/Intermediate/Build/Win64/UnrealEditor/Inc/GameplayAbilities/UHT/`
(Unreal Header Tool output of a local build of that revision, not checked-in
source), `Runtime/` abbreviates `Engine/Source/Runtime/`, and `CMC.cpp`
abbreviates `Runtime/Engine/Private/Components/CharacterMovementComponent.cpp`.

## Decisions at a Glance

1. **One activation per hit.** Each hit of the chain is its own accepted
   request, its own GAS activation, its own `ActivationId`, and its own
   `CombatActivation` record. The client always sends the same `AbilityId`;
   the server chooses the step. #19's step 7 stays unchanged.
2. **The activation ends when the buffer opens.** A step's activation of the
   chain's single `InstancedPerActor` instance lasts from its start to its
   authored buffer-open offset, so #19's single-instance rule rejects early
   presses and allows exactly one buffered press. Recovery and the link window
   continue on the server timeline after the activation ends.
3. **Request schema 2** adds a bounded aim and a client time sample, checked
   for every request through the seam. Aim is converted into a server-bounded
   direction: accepted, clamped and recorded as corrected, or rejected. Exact
   equality is gone (F1); temporal, angular, and angular-rate bounds exist
   (F2). All bounds are `TBD`.
4. **One world-level driver.** A server-only world subsystem sweeps every
   registered step after actor tick, from the server capsule pose, and resolves
   the frame's contacts in one canonical total order, never in actor-iteration
   or packet order. Resets carry a time, so a frame that spans a window and a
   reset cannot drop an earlier hit.
5. **Contacts resolve on the capsule** through a dedicated combat query
   channel. Meshes, sockets, montages, and notifies never create a contact.
6. **Present-time validation.** No rewind in the prototype; TC-002 stays with
   #2. Windows are judged at server receive time.
7. **Nothing is predicted.** The chain is `ServerOnly` in both policies. The
   client may play cosmetic anticipation that the outcome, record, and
   chain-end messages correct or cancel.
8. **Owner-only reliable messages** carry the outcome, the activation record,
   and chain ends; a skip-owner replicated state carries the readable phase to
   observers; an unreliable multicast carries presentation-safe result cues.
9. **The replicated-data cache residual closes** by overriding the four
   virtual `_Implementation` functions that write it (two target-data and two
   replicated-event RPCs) on the project ASC, as #19 closes the other stock
   routes.
10. **Tuning is config data.** Steps, windows, shapes, and bounds are `Config`
    properties validated at grant time and failing closed, matching #19 until
    #84 and #106 supply the asset and registry pipeline.

## Scope and Boundaries

#60 owns the attack request extension, the server timeline, authored contacts,
the deterministic contact order, the already-hit allowance, Wrought damage
application, interruption, the lethal latch, and the three-hit chain
(`docs/characters-and-factions.md:309-310`;
`docs/prototype-and-1.0-scope-ledger.md:75`). The table lists what it consumes
and what it leaves to other owners.

| Owner | #60 consumes or provides | #60 does not do |
| --- | --- | --- |
| [#19](https://github.com/ShayShimoni/aetheln-online/issues/19) | Consumes the seam, rate bucket, outcome RPC, base ability, cost and cooldown overrides, grant validation, `FindForPawn`, and `State.Dead` (see [Dependencies on #19](#dependencies-on-19)). Adds one `ResetChain(AvatarLost)` call to the PlayerState's null-pawn case. | Reorder or change #19's existing seam steps, or change what #19's lifecycle grants, initializes, or cancels. |
| [#18](https://github.com/ShayShimoni/aetheln-online/issues/18) | Provides the avoidance step and an authored avoidance-tag set that #18 fills with its dodge invulnerability tag; a dodge activation resets the chain like any other action. | Dodge cost, window, movement, or tags. |
| [#20](https://github.com/ShayShimoni/aetheln-online/issues/20) | Provides the step definition, timeline driver, contact pipeline, and result path; the enemy registers its steps directly, without the seam. | Enemy behavior, target choice, or telegraph content. |
| [#21](https://github.com/ShayShimoni/aetheln-online/issues/21) | Latches lethal results and raises one lethal notification per target; treats `State.Dead` and zero Health as not alive. | Apply `State.Dead`, run death, respawn, or reconnect. |
| [#61](https://github.com/ShayShimoni/aetheln-online/issues/61), [#97](https://github.com/ShayShimoni/aetheln-online/issues/97) | Provides the outcome, record, chain-end, phase state, and result cues. | Presentation, HUD, `GameplayCue.*` tags. |
| [#82](https://github.com/ShayShimoni/aetheln-online/issues/82) | Closes F1 and F2 by policy; supplies the left-mouse primary-attack binding in P6 and the attack scenario S5 needs. | Camera, reticle, controller layout, feel study. |
| [#84](https://github.com/ShayShimoni/aetheln-online/issues/84) | Hands over the step data layout as the starting point for authored assets. | The authoring pipeline. |
| [#2](https://github.com/ShayShimoni/aetheln-online/issues/2), [#45](https://github.com/ShayShimoni/aetheln-online/issues/45) | Records rejection and correction rates for their profiles. | Rewind, network profiles, numeric bounds. |
| [#17](https://github.com/ShayShimoni/aetheln-online/issues/17) | Owner question 4: movement commitment during attacks. | Predicted movement changes. |
| [#106](https://github.com/ShayShimoni/aetheln-online/issues/106), [#107](https://github.com/ShayShimoni/aetheln-online/issues/107) | Stable IDs and tuning. | Final values. |

## Canon Anchors and Existing Code

The canon fixes the shape of the work:

- Melee uses server-resolved swept volumes during authored windows on a
  server-owned timeline; animation, sockets, effects, and camera visualize it
  (`docs/game-design-bible.md:299-311`; TA-004; Server-Owned Attack Timeline
  in the combat document).
- Input provides view orientation, the ability identifier, the phase, and a
  bounded sequence and timing sample; never a victim, contact, result, shape,
  distance, or window (Pure Free Aim in the combat document).
- "Input buffering supports deliberate combo timing without automating the
  rotation" (`docs/game-design-bible.md:308-309`). Attacks may restrict
  movement differently (`:305-307`).
- Contacts follow the shared defense order and the canonical total order
  (Damage Families and Deterministic Defense in the combat document).

Existing code at `ab296d0`:

| Existing code | Disposition |
| --- | --- |
| Spike attack window and query (`Source/GameCombat/Private/AethelnSpikeAuthorityComponent.cpp:375-471`, `:473-625`) | Reuse the ideas only: a server-issued attack id, an already-hit set, effects applied by the server. Replace the rest: one overlap sphere at actor location plus aim (`:530-539`) against `AllDynamicObjects` (`:537`), which would accept a mesh overlap because the engine's `CharacterMesh` profile is a query-enabled `Pawn` object (`Engine/Config/BaseEngine.ini:3112`); exact aim equality (F1). The spike files stay untouched. |
| #19 P2 (`Source/GameCombat/Public/AethelnAbilitySystemComponent.h:14-26`, `Source/GameCombat/Public/AethelnPlayerState.h`, `Source/GameCombat/Private/AethelnCombatAttributeSet.cpp`, `Source/GameCore/Public/AethelnGameplayTags.h:12-29`) | Build on them. The seam (#19 P3) and cost and cooldown (#19 P4) are not on `develop` yet; this document designs against their specification. |
| `AAethelnCombatAICharacter` (`Source/GameCombat/Public/AethelnCombatAICharacter.h:18-19`) | The headless target dummy for #60 tests; no AI behavior. |
| Input component and receiver (#82 AC1) | Left mouse is only the Cursor-mode recapture today; Reticle-mode left mouse does nothing. P6 adds the attack there. |

## Class Layout

| Class or file | Module | Responsibility |
| --- | --- | --- |
| `AethelnGameplayTags` (extend) | GameCore | `Ability.Oathscar.SwordShieldBasicChain` (`order.oathscar.ability.sword_shield_basic_chain`), `State.Oathscar.SwordShieldBasicChain` (commitment state), `Damage.Wrought` (`combat.damage.wrought`), `SetByCaller.Damage.Wrought`. The PR that adds each tag adds its row to the Initial entries table in the combat document. |
| `IAethelnCombatInputSink` | GameCore | Presentation-safe client entry: `RequestAbilityPress(FGameplayTag AbilityId)`. No GAS type, so GameUI can call it. |
| `AethelnActivationTypes.h` (extend) | GameCombat | Request schema 2, every field initialized; two appended `EAethelnActivationResult` values. |
| `AethelnAttackTypes.h` | GameCombat | `FAethelnAttackStepDefinition`, `FAethelnCombatActivationRecord`, `FAethelnAttackPresentationState`, `FAethelnCombatResultCue`, `EAethelnAimCorrection`, `EAethelnChainEndReason`. |
| `AethelnAttackTimeline` (namespace, pure functions) | GameCombat | Window evaluation, sweep segment clipping and sub-stepping, aim bounding. Headless-testable with injected times. |
| `UAethelnBasicChainAbility` | GameCombat | Derives from `UAethelnGameplayAbility` (`InstancedPerActor`). Each activation selects the step from the chain state, waits for a buffered start, registers the step with the subsystem, and ends at buffer-open. |
| `UAethelnAbilitySystemComponent` (extend) | GameCombat | Aim and time validation (steps 6a to 6d), per-connection last accepted raw aim and time, chain state and `ResetChain`, owner RPCs, the replicated phase state, the result-cue multicast, the four replicated-data overrides. |
| `AAethelnPlayerState` (extend) | GameCombat | Implements `IAethelnCombatInputSink`; calls `ResetChain(AvatarLost)` in its null-pawn case. |
| `UAethelnCombatTimelineSubsystem` | GameCombat | `UWorldSubsystem`, active on the server. Registered steps, activation ordinals, combat entity ids, per-frame sampling, the contact queue, resolution, already-hit records, the lethal notification. |
| `UAethelnDamageEffect` | GameCombat | Instant effect: negated Health modifier from `SetByCaller.Damage.Wrought`, asset tag `Damage.Wrought`. |
| `UAethelnPOCInputComponent` (extend) | GameUI | P6: primary-attack action on left mouse, Reticle mode only, never the recapture press. |

## Request Contract

### Schema 2

```cpp
/** Client intent only. No target, hit, contact, damage, magnitude, cost, cooldown, shape, range, window or attribute field. */
USTRUCT()
struct GAMECOMBAT_API FAethelnCombatActivationRequest
{
	GENERATED_BODY()

	UPROPERTY() uint8 SchemaVersion = 2;
	UPROPERTY() FGameplayTag AbilityId;
	UPROPERTY() uint32 ContentVersion = 0;
	UPROPERTY() EAethelnActivationPhase Phase = EAethelnActivationPhase::Press;
	UPROPERTY() uint32 Sequence = 0;
	UPROPERTY() FVector_NetQuantizeNormal Aim = FVector_NetQuantizeNormal(ForceInitToZero); // new: control-rotation unit vector at press, pitch included
	UPROPERTY() double ClientServerTimeSeconds = 0.0;  // new: client's estimate of server world time at press
};
```

`Aim` is initialized explicitly because the vector's default constructor leaves
it uninitialized (`Runtime/Core/Public/Math/Vector.h:150`;
`Runtime/Engine/Classes/Engine/NetSerialization.h:544-546`).

- **Why these two fields.** #19 deferred aim and any timestamp to #60 with a
  schema bump (Input-contract findings in the #19 specification). The aim is
  the control-rotation vector the #82 contract names as the aim
  representation (#82 AC6). `FVector_NetQuantizeNormal` is the engine's
  quantized unit vector (`Runtime/Engine/Classes/Engine/NetSerialization.h:540`),
  as the spike already uses. The time sample is the value of
  `AGameStateBase::GetServerWorldTimeSeconds` on the client
  (`Runtime/Engine/Classes/GameFramework/GameStateBase.h:72`): local world time
  plus a delta (`Runtime/Engine/Private/GameStateBase.cpp:144-150`). The
  server replicates its world time every 0.1 s by default (`:36`, `:65-67`),
  and the client derives a smoothed running delta from each update
  (`:164-193`). The sample therefore carries a latency-dependent error and can
  step back slightly between presses; the bounds must tolerate both.
- **No step field.** Every hit sends the chain's `AbilityId`. The server
  chooses the step from its own chain state.
- **#19 changes.** T10 (`RequestShape`) asserts exactly five reflected fields
  with no aim. P2 changes it to seven fields, allows only `Aim` and
  `ClientServerTimeSeconds` as additions, and keeps every other forbidden
  name. Every other #19 fixture and text change is listed in
  [Dependencies on #19](#dependencies-on-19).
- **Client fill.** `RequestActivation(AbilityId, Phase)` reads the owning
  controller's control rotation and the game state's server time, and calls
  `FlushServerMoves()` on the avatar's movement component before sending
  (`Runtime/Engine/Classes/GameFramework/CharacterMovementComponent.h:2897`;
  `CMC.cpp:13429-13454` sends a held pending move). Flushing makes the server's
  control rotation fresher; it is a mitigation, not authority.

### Input path across modules

GameUI may depend only on GameCore and presentation-safe interfaces
(`docs/technical-architecture.md:157`), and the GameCore pawn stays free of
GAS. The path is therefore:

1. GameUI's input component handles a left-mouse `Started` only in Reticle
   mode, and never for a press that performed a Cursor-mode recapture: the
   recapture marks the press consumed until its release, so the same click
   cannot reach the attack handler after the mode switch.
2. It casts the local controller's `PlayerState` to `IAethelnCombatInputSink`
   and calls `RequestAbilityPress(Ability.Oathscar.SwordShieldBasicChain)`.
3. `AAethelnPlayerState` forwards to its ASC's `RequestActivation`, which fills
   schema 2 and sends `ServerSubmitActivation`.

Space remains jump, the binding stays remappable under #82's candidate rules,
and Cursor mode blocks the press without cancelling an accepted step
(`docs/game-design-bible.md:163-174`).

### Validation additions

Steps 6a to 6d run after #19's step 6 and before step 7, so identity, sequence,
and version reasons keep their precedence. They apply to every request through
the seam, for every ability (the chain, Gate Step, Sworn Rebuke, Hold the Line)
and both phases, not only to the chain. Each rejection has one reason and no
side effect.

| Step | Check | Rejection result |
| --- | --- | --- |
| 6a | `ClientServerTimeSeconds` is finite, within `[Now - ProvisionalTimestampMaxAgeSeconds, Now + ProvisionalTimestampMaxLeadSeconds]` of the server world time, and not lower than the last accepted request's sample minus `ProvisionalTimestampRegressionToleranceSeconds` | `TimestampOutOfBounds` (new) |
| 6b | `Aim` is finite, non-zero, and unit within `ProvisionalAimUnitTolerance` | `MalformedRequest` |
| 6c | The angle between `Aim` and the reference `R` (the vector of the avatar controller's current server control rotation) is at most `ProvisionalAimHardBoundDegrees` | `ImpossibleAimTransition` (new) |
| 6d | The angle between `Aim` and the last accepted request's raw `Aim` is at most `ProvisionalAimSoftBoundDegrees + ProvisionalAimMaxRateDegreesPerSecond * max(0, Interval)`, where `Interval` is the client-time difference between the two samples (skipped for the first accepted request) | `ImpossibleAimTransition` |

Step 6d compares raw aim with raw aim, never with a corrected aim, so a press
clamped toward a lagging `R` cannot make the next legitimate press look like
an impossible turn. The soft-bound term absorbs quantization and the zero or
negative intervals that the 6a regression tolerance allows; with a zero
interval, any turn beyond the soft bound is rejected.

On acceptance, the accepted aim is:

- `Aim` itself when its angle to `R` is at most
  `ProvisionalAimSoftBoundDegrees` (correction `None`);
- otherwise `R` rotated toward `Aim` along their great circle by exactly the
  soft bound (correction `AimCorrected`).

The soft bound is at most the hard bound; equal values give no correction band.
The last accepted raw aim and client time advance only at #19's step 10, with
`LastAcceptedSequence`, and live for one PlayerState lifetime. Steps 6a to 6d
extend #19's static pure validator; the signature change is in
[Dependencies on #19](#dependencies-on-19).

**Why this closes F1 and F2.** The server reference comes from the last
processed movement packet (`CMC.cpp:10027-10036` sets control rotation only
inside a positive-delta server move), so it can lag the reliable request. A
bounded difference tolerates that lag where exact equality rejected it, and it
is the server-bounded direction the canon asks for: the server records the
accepted direction and whether it corrected it. F2's temporal bound is step 6a
and its angular bounds are 6c and 6d. Both stay plausibility checks: the
reference and the time sample are client-derived, so neither proves intent.
#82 S5 measures the correction and rejection rates (P6). The record carries the
accepted direction and the correction result, which closes #82 F11. A2
replaces #82's planned spike tests `Aetheln.GameCombat.NetworkSpike.AimAfterLook`
and `Aetheln.GameCombat.NetworkSpike.AimRateBound`.

## Server-Owned Attack Timeline

### Step definition

Each of the three steps has these authored values. Offsets are seconds from the
step's authoritative start; every value is `TBD`.

| Value | Meaning |
| --- | --- |
| `ActiveStart`, `ActiveEnd` | The active window `[ActiveStart, ActiveEnd)`; wind-up is `[0, ActiveStart)` |
| `BufferOpen` | The activation ends here; from here a press is accepted as the next step |
| `LinkOpen`, `LinkClose` | The next step may start in `[LinkOpen, LinkClose)`; absent on the final step |
| `RecoveryEnd` | Recovery is `[ActiveEnd, RecoveryEnd)` |
| `CancelOpen` | The commitment tag is held in `[0, CancelOpen)` |
| `InterruptibleUntil` (P5) | An interrupting result cancels the step in `[0, InterruptibleUntil)`; 0 means never |
| `Shape`, `ShapeExtent` | Sphere, capsule, or box, with its extent |
| `PathStart`, `PathEnd` | Shape transforms in the combat frame at `ActiveStart` and `ActiveEnd` |
| `MaxAimPitchDegrees` | Pitch clamp applied to the accepted aim when building the combat frame |
| `WroughtDamage` | One Wrought component per contact |
| `MaxTargets` | The bounded number of targets one activation may record |
| `bInterruptsTarget` (P5) | Whether this step's committed hit interrupts the target |

**One result per target per activation.** The chain has one active window per
step, and a target gets at most one result from each activation, however many
sub-sweeps or frames it stays inside the shape. This is fixed for the
prototype chain, not tuned. Authored re-hits would need re-hit slots and a
re-hit interval rule; none is designed, and adding them is a content-version
and design change.

Grant validation (extending #19's) refuses the chain unless there are exactly
three steps, every value is finite, and:

- `0 <= ActiveStart < ActiveEnd <= BufferOpen`;
- non-final steps: `BufferOpen <= LinkOpen <= RecoveryEnd <= LinkClose` and
  `LinkOpen < LinkClose`, so a buffered start and a timeout never share an
  instant;
- final step: `BufferOpen == RecoveryEnd`, no link values;
- `ActiveEnd <= CancelOpen <= RecoveryEnd`;
- extents are positive, damage is non-negative, `MaxTargets >= 1`, and the
  pitch clamp is within `[0, 90]`;
- the chain's own `ActivationBlockedTags` do not contain its commitment tag,
  and every tag in them is also an authored reset tag (see [Resets](#resets)),
  so a blocking tag added while a buffered step waits resets the chain instead
  of letting the step start.

P5 adds `InterruptibleUntil` and `bInterruptsTarget` to the step struct, with
the rule `0 <= InterruptibleUntil <= RecoveryEnd`, extends A5, and bumps the
chain's `ContentVersion`.

`LinkClose >= RecoveryEnd` keeps a late press out of recovery: after the link
closes, the character is already free and the press starts a new chain.
Whether that is the right reading of "late" in the issue's criteria is owner
question 8.

### Chain progression and buffering

The ASC holds one server-only `FAethelnChainState`: the current step index, its
start time, and its content version. The seam evaluates a press at server time
`t` with every boundary up to `t` already applied (see
[Timeline driver](#timeline-driver-and-clock)). `S` is the current step's start.
Every activation gets a new `ActivationId`, as the spike does per accepted
intent (`Source/GameCombat/Private/AethelnSpikeAuthorityComponent.cpp:431`);
the id is per activation, not per instance.

| Press at `t` | Seam outcome | Effect |
| --- | --- | --- |
| No chain state | `Accepted` | Step 1 starts at `t` |
| `t < S + BufferOpen` (activation still active) | `ActivationBlocked` (#19 step 7) | Nothing; this is an early press |
| `S + BufferOpen <= t < S + LinkOpen` | `Accepted`, cost committed now | The instance activates again, waits, and starts the next step at `S + LinkOpen` (buffered) |
| Another press while that activation waits | `ActivationBlocked` (#19 step 7) | Nothing; one buffered press at most |
| `S + LinkOpen <= t < S + LinkClose` | `Accepted` | The next step starts at `t`; the rest of the current recovery is cancelled |
| `t >= S + LinkClose`, or the final step has ended | `Accepted` | The chain timed out or completed; step 1 starts at `t` |

Rules:

- **No automation.** A press drives one step. Nothing repeats a held button,
  and the buffer holds one press.
- **Commit at acceptance.** A buffered press runs #19's steps 8 to 10 when it
  arrives, so `Accepted` always means committed. If the chain resets before
  the buffered step starts, the step never starts and its cost (if any) is not
  refunded (owner question 5).
- **Buffered aim.** A buffered step uses the aim accepted at its press, which
  is at most `LinkOpen - BufferOpen` old when the step starts.
- **No cooldown on the chain.** Cadence is bounded by the timeline, the
  single-instance rule, and #19's rate bucket, which closes F3 for the chain. A
  positive chain cooldown would block the next hit, because every hit commits
  (dependency 2). This is a structural consequence, not a tuning value; a
  chain-level restart delay, if one is ever wanted, stays `TBD` (#107).
- **Final-step presses.** The final step's activation lasts until its recovery
  ends, so every press during it is an early press. Buffering into a new chain
  is owner question 7.

### Cancel rules and commitment

The step holds `State.Oathscar.SwordShieldBasicChain` in `[0, CancelOpen)`.
Abilities that the chain commits against list it in their
`ActivationBlockedTags` (`GAS/Public/Abilities/GameplayAbility.h:755`), so #19's
step 8 rejects them with `ActivationBlocked`. After `CancelOpen` another action
may activate if its own tags allow it, and its activation resets the chain.
Which actions are blocked, and which may cancel recovery, is content data `TBD`
with #18 (#19 open decision 6).

The tag is added and removed by the timeline as a loose server tag, not as
`ActivationOwnedTags`, because those last for the whole activation
(`GAS/Private/Abilities/GameplayAbility.cpp:990`) and the activation ends
before recovery does.

### Resets

Every reset goes through one `ResetChain(Reason, ResetTime)`. It cancels a
running or waiting chain activation, removes the commitment tag, stamps the
registered step with `ResetTime`, clears the phase state, and sends one
`ClientChainEnded` to the owner. The next press is step 1.

- **Reset time.** Timeline resets use their exact authored time
  (`S + RecoveryEnd`, `S + LinkClose`). An interruption uses the contact time
  of the interrupting result. Every other reset uses the server time at which
  it is processed.
- **No mid-frame removal.** A reset never removes a step from the subsystem
  during a frame. The frame pass still sweeps the step up to its reset time,
  and revalidation accepts only contacts earlier than it (see
  [Timeline driver](#timeline-driver-and-clock)); the step is removed after the
  pass.
- **Idempotent.** The first reset of a chain ends it; later calls for the same
  chain do nothing. For example, #19's `CancelAllAbilities` ending the
  activation and the explicit `AvatarLost` call produce exactly one
  `ClientChainEnded`.

| Reason | Trigger |
| --- | --- |
| `Completed` | The final step's recovery ended |
| `Timeout` | A non-final step's link window closed with no press |
| `Interrupted` | A committed interrupting result arrived inside `InterruptibleUntil` (P5) |
| `AvatarLost` | #19's null-pawn case (unpossession, destroy while possessed, logout, disconnect); it already cancels all abilities |
| `IncompatibleState` | `State.Dead`, an authored reset tag, or any tag in the chain's `ActivationBlockedTags` was added, through `RegisterGameplayTagEvent` (`GAS/Public/AbilitySystemComponent.h:720`) |
| `OtherAction` | Any other ability activated on the ASC, through `AbilityActivatedCallbacks` (`GAS/Public/AbilitySystemComponent.h:542`, broadcast at `GAS/Private/AbilitySystemComponent_Abilities.cpp:2554-2557`) |

`AbilityActivatedCallbacks` fires from `PreActivate`
(`GAS/Private/Abilities/GameplayAbility.cpp:997`), before the other ability
commits, so an activation that then fails its commit (#19 `InternalFailure`)
would still reset the chain. P3 either resets only on the other ability's
committed activation or pins this behavior in A8.

#18 may call `ResetChain(OtherAction)` directly if its dodge is not a GAS
ability.

### Timeline driver and clock

`UAethelnCombatTimelineSubsystem` binds `FWorldDelegates::OnWorldPostActorTick`
(`Runtime/Engine/Classes/Engine/World.h:4526-4527`, broadcast at
`Runtime/Engine/Private/LevelTick.cpp:1905-1906`), so it runs after movement
and actor ticks. The delegate is static and every world in the process
broadcasts it, including client worlds in single-process PIE. The handler
therefore returns unless the broadcasting world is the subsystem's own world
and that world is not a client (`GetNetMode() != NM_Client`). `Now` is always
that world's `GetTimeSeconds()`; the delegate's `DeltaSeconds` is never used.

Each frame the pass:

1. **Sweeps.** For every registered step, in activation-ordinal order, it
   sweeps the active window over
   `(LastSample, min(Now, S + ActiveEnd, ResetTime)]` and queues contact
   candidates. Steps reset earlier in the frame are still swept up to their
   reset time.
2. **Resolves.** It sorts the queue in the canonical total order and resolves
   it. Revalidation accepts a candidate only if its contact time is earlier
   than its activation's reset time (if any). An interruption or lethal result
   committed during resolution stamps its reset at its contact time, so it
   invalidates only the victim's later contacts.
3. **Applies boundaries.** It applies every boundary up to and including `Now`
   (commitment end, activation end at `BufferOpen`, `Timeout` at `LinkClose`,
   `Completed` at `RecoveryEnd`), each stamped with its authored time. These
   times are never earlier than `ActiveEnd`, so they cannot invalidate the
   frame's contacts.
4. **Emits** records, cues, telemetry, and lethal notifications from committed
   results, and removes the steps that were reset.

Rules:

- **One clock.** All windows use server world time. The client time sample is
  never a window input.
- **Half-open windows.** A boundary belongs to the window it opens. A contact
  at exactly `ActiveEnd` is outside the active window.
- **Requests see the last pass's time.** RPCs are dispatched before the world
  time advances (`Runtime/Engine/Private/LevelTick.cpp:1574` before `:1610`),
  so a request reads the previous frame's `Now`, and the previous pass has
  already applied every boundary up to that time. If a request ever reads a
  later time (for example a delayed bunch processed after the pass), the seam
  first applies the requester's boundaries up to that time.
- **Requests before contacts.** A request processed in a frame is validated
  before that frame's contacts resolve, and a reset it causes is stamped with
  the previous frame's time, so it invalidates all of this frame's contacts
  from that chain. This is the declared rule for a dodge or block request and
  a contact in the same frame.
- **Missing presentation changes nothing.** The driver needs no mesh, montage,
  notify, or effect; headless tests run the full timeline.
- **No skipped windows or dropped hits.** A long frame that spans a whole
  active window still sweeps it once, clipped to its exact bounds. A frame that
  also spans `RecoveryEnd` or `LinkClose`, or a mid-frame external reset, keeps
  every contact that came before the reset time.

## Authored Volumes and Hit Resolution

### Combat frame and sweeps

The combat frame's origin is the attacker's authoritative capsule center at the
sample time; its rotation is the accepted aim's yaw and its pitch clamped to
`MaxAimPitchDegrees`, fixed for the step. The shape moves from `PathStart` to
`PathEnd` across the active window. Root motion, motion warping, sockets, and
camera anchors never move it (Combat Invariants in the combat document).

Engine sweeps translate a shape at one fixed rotation (`Rot` in
`Runtime/Engine/Classes/Engine/World.h:2325`), so the driver sub-steps a
segment until each sub-sweep's rotation change and travel stay within
`ProvisionalMaxSampleAngleDegrees` and `ProvisionalMaxSampleDistance` (`TBD`
sampling budget), sweeping each at its start rotation. A hit's contact time is
the segment start plus the hit's sweep fraction times the segment duration.

The server holds only end-of-frame capsule positions. Within one frame's
segment, the combat-frame origin of each sub-step is interpolated linearly
between the attacker's capsule center at the previous sample and at `Now`;
targets are swept where they are at `Now`.

### Target query

- A project trace channel, `AethelnCombatQuery`, defaults to `Ignore`.
  Character capsules respond to it with `ECR_Overlap`, set in C++ on the
  GameCore pawn and the AI base; mesh profiles keep the default. Overlap, not
  block, is required: a multi sweep generates nothing after its first blocking
  hit (`Runtime/Engine/Classes/Engine/World.h:2313-2315`), which would cap a
  swing at one target. The driver sweeps with `SweepMultiByChannel` (`:2325`).
- A hit counts only if its component is the target character's capsule. This
  second check keeps a misconfigured mesh from creating a contact.
- The attacker and its own avatar are ignored. The ASC is found with
  `FindForPawn`.
- **Occlusion (decision).** Nothing blocks the channel, so a sweep is not
  stopped by world geometry, and the prototype adds no line-of-sight check:
  authored melee reach in a controlled arena. The canon notes that attacks
  obstructed by near cover need separate validation (Local Control Modes in
  the combat document); this stays residual risk 9 and is revisited when the
  arena gains cover or a shape can reach through a wall.

### Total order

Candidates sort by contact time, then activation ordinal (a server-global
counter issued at step start, unique across connections and AI), then result
slot (always 0 for the chain: one active window per step), then target combat
id (a server-issued id per ASC). This is the canonical key (Damage Families and
Deterministic Defense in the combat document) without the periodic-effect
terms, which melee does not use. A second candidate with the same activation
and target is a duplicate.

### Resolution order (prototype subset)

For each candidate, in order:

1. **Revalidate.** The activation was not reset at or before the contact time,
   the attacker and target are alive (no `State.Dead` and Health above zero,
   which fails closed until #21), the relation is hostile (see
   [Relation](#relation)), and the content version is the activation's.
   Territory policy is 2.x and is not checked.
2. **Allowance.** Reject the candidate if this target already has a result
   for this activation, or if the activation's record already holds
   `MaxTargets` targets. Never evict a record while the activation's step is
   registered. Record the accepted contact.
3. **Avoidance.** A target holding any tag in the authored avoidance set
   (empty until #18) yields a recorded `Avoided` result and nothing else.
4. **Directional defense.** With no active directional defense on the target,
   this step passes. Block resolution, Guard pressure, and Guard break arrive
   with Hold the Line (P7, owner question 3).
5. **Family mitigation.** Wrought has no mitigation inputs in the prototype;
   the step exists in code order and applies none. No value is invented.
6. **Ward.** Not prototype scope; no attribute exists.
7. **Health.** Apply `UAethelnDamageEffect` from the attacker's ASC with the
   authored magnitude. The attribute set clamps at zero. If Health is now zero,
   latch the result as lethal. Then, for a non-lethal target, apply
   interruption if the step authors it.
8. **Commit.** Store the result under (activation, target, slot, component
   ordinal 0), raise the lethal notification once per target, and emit the cue
   and telemetry.

Duplicate, reordered, or replayed candidates converge on the recorded result
and never repeat damage, interruption, or a cue.

### Lethal results

The subsystem exposes a native multicast `OnLethalResult(TargetAsc,
ActivationId)`, raised once per target from the committed result. #21 binds it
and applies `State.Dead`. Until #21 lands nothing binds it, and a zero-Health
target is not alive to step 1, so it takes no further results and its attacks
fail revalidation.

### Interruption

A committed result with `bInterruptsTarget` resets the target's chain with
`Interrupted`, stamped at the contact time, if the target's current step is
inside its interruptible window at that contact time
(`ContactTime < TargetStepStart + InterruptibleUntil`). Both fields arrive in
P5. The same mechanism serves #20's enemy steps and Sworn Rebuke's authored
rule.
Resolve and control families are not prototype scope.

### Relation

The prototype is two players against one enemy (`docs/GameBrief.md:24-27`),
before factions (`Faction = Unassigned`). The default relation is: self
excluded, player to player friendly (no result), player and AI enemy hostile.
One server function decides it, so faction and territory policy replace it
later. Owner question 1 confirms the default.

## Lag Compensation

The prototype validates at present time. Windows are judged when the server
processes the request, and contacts against target capsules as the server holds
them in that frame. Bounded rewind is TC-002 and stays with #2 until it
measures fairness, abuse, and cost.

Consequences the owner should expect:

- An attacker sees remote targets in the past, so a hit that looked clean
  locally can miss a moving target on the server. The rejection and miss
  rates go into P6 evidence; volumes are tuned with that evidence, not
  enlarged by guess.
- A press reaches the server about half a round trip late, so links and
  buffers are judged later than the player pressed. The buffer window absorbs
  part of that; its size is `TBD` with #45.

When #2 selects rewind for melee, contact resolution reconstructs target
capsules at a bounded historical time, and the record gains a validation-mode
field with a schema bump. #60 builds no history store.

## Prediction Policy

- The chain is `ServerOnly` in both net policies; #19's grant validation
  enforces it. It is not on TC-008's prediction list.
- The client predicts no cost, cooldown, tag, contact, already-hit state,
  damage, interruption, or chain step as owned state.
- Allowed cosmetic anticipation, owned by #61 and #97: start a wind-up
  presentation at press; guess the next step from the last record. A rejected
  outcome cancels it; the record realigns it; a chain end stops it.
- No gameplay window derives from a montage, notify, or the montage RPCs
  (Closing the Stock Routes in the #19 specification).

## Replication and Outcome Reporting

### CombatActivation record

`FAethelnCombatActivationRecord` is sent once per started step, to the owner
only, by `UFUNCTION(Client, Reliable) ClientCombatActivation`. Canon leaves
serialization and transport open (CombatActivation Contract in the combat
document); this is #60's choice for the prototype and does not change the
contract.

| Canon field | Record field |
| --- | --- |
| `ActivationId` | `FGuid ActivationId`, created by the ability (#19), unique per step |
| `SequenceId` | `uint32 Sequence` of the accepted request |
| `InstigatorId` | `uint32 InstigatorCombatId`, server-issued, opaque to clients |
| `AuthoritativeStartTime` | `double StartServerTime` |
| `AbilityId` | `FGameplayTag AbilityId` |
| `ContentVersion` | `uint32 ContentVersion` |
| `ActiveWindows` | `uint8 ChainStep` and the step's windows as typed offsets (wind-up, active, recovery, buffer, link, commitment, interruptible) |
| `AttackShapes` | The shape identity is (ability, content version, step); the resolved frame is `AcceptedAim` with the capsule origin |
| `CorrectionResult` | `EAethelnAimCorrection` (`None` or `AimCorrected`); rejected requests get no record, only their outcome |
| `ResultReferences` | Kept in the server's result record for audit; results reach clients as cues |
| `SchemaVersion` | `uint8 SchemaVersion = 1` |

### Owner messages

| Message | When | Reliability |
| --- | --- | --- |
| `ClientActivationOutcome(Sequence, Result)` (#19) | Every request | Reliable, owner only |
| `ClientCombatActivation(Record)` | Every step start, immediate or buffered | Reliable, owner only |
| `ClientChainEnded(ActivationId, Reason)` | Every reset | Reliable, owner only |

Each accepted request produces at most one record and one chain end, and the
rate bucket bounds requests, so the reliable volume stays bounded. A buffered
step's record arrives after its outcome, at `LinkOpen`. Outcomes keep #19's
ordering rule, because every request still gets its outcome on arrival.

### Observers

`FAethelnAttackPresentationState` on the ASC, `COND_SkipOwner`, holds the
ability id, content version, chain step, start time, accepted aim, a wrapping
activation counter, and the end reason. Observers derive wind-up, active, and
recovery phases from the start time and the authored windows, which gives the
readable cues canon requires (Secure Stealth and Opponent Readability in the
combat document). For players it replicates from the always-relevant
PlayerState (residual risk 4).

### Result cues

`UFUNCTION(NetMulticast, Unreliable) MulticastCombatResultCue` on the target's
ASC carries the source avatar, the outcome (`Hit`, `Avoided`, later `Blocked`
and `GuardBroken`), the family tag, whether it was lethal, and the
server-computed contact location. It carries no damage amount and no
attribute value; Health stays owner-only (#19) until #61 decides opponent
visibility. Losing a cue loses presentation only; attributes and death
replicate separately. The attacker gets no reliable hit confirmation in the
prototype: the unreliable cue is its only hit signal, and #61 treats it as
presentation.

### Bounded presentation correction

The client never sends a correction back and never amends a record. Correction
is bounded by construction: the aim difference is at most the hard bound, the
start-time difference is at most the timestamp bounds plus any buffer wait,
and a rejection or chain end cancels the presentation outright.

## Rejection Reasons and Telemetry

The attack path reuses #19's results and adds two, appended to
`EAethelnActivationResult`. Both map to existing safe reasons
(`Source/GameNet/Public/AethelnObservability.h:68-69`), so the GameNet
vocabulary does not change.

| Result | Attack-path cause | Subject category | Safe reason |
| --- | --- | --- | --- |
| `RateLimited` | Bucket empty | Ability | `RateLimited` |
| `ConnectionClosed`, `ActorDestroyed` | No avatar, dying avatar | Ability | same |
| `IncompatibleVersion` | Schema or content version | Ability | same |
| `StaleSequence`, `DuplicateSequence` | Sequence | Ability | same |
| `MalformedRequest` | Unknown ability, malformed aim, unsupported phase | Ability | same |
| `TimestampOutOfBounds` (new) | Step 6a | Ability | `TimestampOutOfBounds` |
| `ImpossibleAimTransition` (new) | Steps 6c, 6d | Aim | `ImpossibleAimTransition` |
| `ActivationBlocked` | Early press, second buffered press, commitment tag, `State.Dead` | Ability | same |
| `InsufficientResource` | Chain cost, if any | Resource | `ActivationBlocked` |
| `InternalFailure` | Commit failed | Ability | same |
| `Accepted` | Accepted, with or without correction | Ability | `Accepted` |

Telemetry additions, using the #19 emission rules and allowlisted correlation
(`docs/observability-and-crash-diagnostics.md:30-48`):

- An `AimCorrected` acceptance also emits one correction event (subject `Aim`,
  reason `Corrected`) and one `CorrectionCount` metric sample. P2 adds and
  tests this with the two new rejections (A16).
- Each committed result emits one event (subject `Hit`, reason `Accepted`)
  with the activation id, ability id, and request sequence. Target identity is
  not an allowlisted field and is not logged. P4 adds and tests this (A24).
- The four refused replicated-data routes emit a metric only and draw from the
  bucket, like #19's refused stock routes.
- AI activations have no client sequence, and the contract drops events with
  sequence 0, so #20 issues a server sequence for its events.
- Content version in correlation stays with #38 (#19 open decision 9); the
  record carries it meanwhile.

## Closing the Replicated-Data Cache Residual

#19 left a residual to #60: a hostile client can grow the server's replicated
ability-data cache (`AbilityTargetDataMap`) on keys it chooses. Four
client-callable reliable server RPCs write it:

| RPC | Declaration | Cache write | Generated virtual `_Implementation` |
| --- | --- | --- | --- |
| `ServerSetReplicatedTargetData` | `GAS/Public/AbilitySystemComponent.h:1572-1573` | `FindOrAdd` (`GAS/Private/AbilitySystemComponent_Abilities.cpp:4011-4012`) | `GAS-UHT/AbilitySystemComponent.generated.h:75` |
| `ServerSetReplicatedTargetDataCancelled` | `:1576-1577` | `FindOrAdd` (`:4051-4052`) | `:73` |
| `ServerSetReplicatedEvent` | `:1554-1555` | Through `InvokeReplicatedEvent` (`:3934-3938`), which calls `FindOrAdd` (`:3950`) | `:80` |
| `ServerSetReplicatedEventWithPayload` | `:1558-1559` | Through `InvokeReplicatedEventWithPayload` (`:3941-3946`), which calls `FindOrAdd` (`:3968`) | `:78` |

The container cannot be purged from a game module: its `Remove` is not
exported and its storage is private
(`GAS/Public/Abilities/GameplayAbilityTypes.h:554-567`). The input RPCs are
bounded and stay open: `ServerSetInputPressed` and `ServerSetInputReleased`
only update a spec that already exists
(`GAS/Private/AbilitySystemComponent_Abilities.cpp:2885-2902`).

The header declares the RPCs without `virtual`, but the generated
`_Implementation` functions are virtual. P2 overrides all four on
`UAethelnAbilitySystemComponent` to refuse unconditionally: no cache write,
one token from the connection's bucket, a metric only, no reply. This mirrors
#19's stock-route refusals. `_Validate` is not overridden: returning false
there disconnects the client, which is harsher than the other routes. The
batch route already calls the same virtual target-data implementation
(`GAS/Private/AbilitySystemComponent_Abilities.cpp:4199`) and is closed by #19.
P2 starts by compiling the overrides; if a virtual declaration does not
reproduce, P2 stops and reports. P2 also corrects the #19 specification (see
[Dependencies on #19](#dependencies-on-19)). No #60 ability uses target-data or
replicated-event tasks.

## Attribute Re-clamp Behavior

An Issue #60 comment from #19 P2 asks this issue to settle what happens when a
maximum is lowered while the current value includes a positive temporary
modifier. Today the re-clamp writes the new maximum as the base
(`Source/GameCombat/Private/AethelnCombatAttributeSet.cpp:66-80`, through
`:43-52`): base 50 with a +30 modifier and the maximum lowered to 70 gives base
70, so when the modifier expires the value is 70 instead of 50, a free
restoration.

**Recommendation (owner question 2):** a lowered maximum never raises a base.
The re-clamp writes `min(Base, NewMax)`. When the base is already within the
new maximum, it rewrites the unchanged base, which re-evaluates the current
value: the aggregator broadcasts dirty on every base write with no equality
check (`GAS/Private/GameplayEffectAggregator.cpp:438-445`), the dirty chain
recomputes the current value (`GAS/Private/GameplayEffect.cpp:4022-4031`), and
`PreAttributeChange` clamps it to the new maximum. The example then gives
current 70 and base 50, and 50 after the modifier expires.

Damage and Guard pressure lower current values only, and #60 adds no effect
that modifies a maximum or adds a duration modifier to a current value. The fix
therefore lands with the first PR that adds such an effect, with its test; P4
adds A18 so a #60 change cannot introduce one silently.

## Data-Driven Tuning

All values are `TBD`. A PR may add a placeholder value so the game runs; a
placeholder is reviewed as a placeholder, not approved tuning. Ini now,
assets with #84 and generation with #106 later, as in #19. Every authoritative
change bumps the chain's `ContentVersion`.

| Config section | Keys |
| --- | --- |
| `[/Script/GameCombat.AethelnBasicChainAbility]` | `ContentVersion`; `ProvisionalEnduranceCost` (optional); `ProvisionalSteps` (three step structs with the values in [Step definition](#step-definition)); `ProvisionalMaxSampleAngleDegrees`; `ProvisionalMaxSampleDistance` |
| `[/Script/GameCombat.AethelnAbilitySystemComponent]` | `ProvisionalAimSoftBoundDegrees`; `ProvisionalAimHardBoundDegrees`; `ProvisionalAimMaxRateDegreesPerSecond`; `ProvisionalAimUnitTolerance`; `ProvisionalTimestampMaxAgeSeconds`; `ProvisionalTimestampMaxLeadSeconds`; `ProvisionalTimestampRegressionToleranceSeconds` |
| `Config/DefaultEngine.ini` | The `AethelnCombatQuery` trace channel with default response `Ignore` (structure, not tuning) |

The seam refuses to start with non-finite bounds, a soft bound above the hard
bound, bounds outside `[0, 180]`, non-positive unit or age tolerances, or a
negative lead or regression tolerance; the chain's grant
validation is in [Step definition](#step-definition). Both fail closed. The
seam keys live in shared `DefaultGame.ini` for the reason #19 gives
(`Runtime/Core/Private/Misc/ConfigContext.cpp:853`).

## Dependencies on #19

1. **The seam (P3) and cost and cooldown (P4)** must be on `develop` before
   any #60 code PR that touches the ASC or the abilities.
2. **Zero cooldown.** The base ability's `ApplyCooldown` applies no effect, and
   `CheckCooldown` passes, when the configured duration is zero; grant
   validation accepts zero. If #19 P4 does not already behave this way, #60 P3
   adds it with a test.
3. **Validator signature (P2).** #19's static pure validator for steps 1 to 7
   gains these inputs: the server reference aim vector, the last accepted raw
   aim, the last accepted client time, and the aim and timestamp bounds. Its
   result gains the accepted aim and the correction value. Step 10 also
   advances the last accepted raw aim and client time. #19's existing steps are
   not reordered or changed; 6a to 6d are an insertion its specification
   anticipates.
4. **Fixtures (P2).** Steps 6a to 6d apply to every request, so every #19 test
   that sends a seam request must build one with a valid aim and time sample,
   or it fails at 6a or 6b: T11, T12, T14, T16 to T21, and T31. T11's existing
   rows keep their expected results with valid fixtures. T10 changes from five
   fields to seven (A1).
5. **Specification text (P2).** P2 corrects the #19 specification where
   schema 2 and the route closure make it wrong: Decision 4 and the struct
   comment ("no ... aim" field), the T10 row, Open Decision 4 (the aim policy
   is now decided here), the "Which messages draw from the bucket" bullet (the
   four replicated-data routes now draw from it), the RPC table rows for the
   target-data and replicated-event RPCs (they are refusable, and the
   replicated-event RPCs do write the cache), and the Known Interim Gaps entry
   for target-data cache growth.
6. **Lifecycle hook (P3).** The PlayerState's null-pawn case gains one
   `ResetChain(AvatarLost)` call. Nothing else in #19's lifecycle changes.

## Test Plan

Names follow `Aetheln.<Area>.<Group>.<Case>`, as in #19, with the same kinds.
**H** is a headless authority world with the in-memory sink, in the editor-only
`GameTests` module. **P** is PIE with a dedicated server and two clients;
without a multi-client harness these are manual steps recorded in the PR,
under the #82 conditions C1 and C2 (one run per #44 catalog kind). **K** is a
packaged run. Tests that pin a policy set their own values, never tuning.

| # | Test | PR | Kind | What it proves |
| --- | --- | --- | --- | --- |
| A1 | `Aetheln.GameCombat.ActivationSeam.RequestShape` (T10 update) | P2 | H | Seven reflected fields; `Aim` and `ClientServerTimeSeconds` are the only additions; no target, hit, contact, damage, shape, range, window, or attribute field |
| A2 | `Aetheln.GameCombat.AttackTimeline.AimAndTimeValidation` | P2 | H | Steps 6a to 6d with an injected clock and reference: time at and beyond each age and lead bound, non-finite, regressing within and beyond the regression tolerance; zero, non-unit, non-finite aim; soft-bound accept, clamp exactly to the soft bound, hard-bound reject; rate bound measured raw to raw (a corrected previous press does not cause a false rejection); zero and negative intervals; precedence after step 6; the same checks for a non-chain ability and a Release; no state advance on rejection |
| A3 | `Aetheln.GameCombat.AttackTimeline.ReplicatedDataRoutesRefused` | P2 | H | All four implementations (target data, target data cancelled, replicated event, replicated event with payload) write no cache entry, draw one token each, emit a metric only, and send nothing; the input RPCs are unaffected |
| A4 | `Aetheln.GameCombat.AttackTimeline.WindowEvaluation` | P3 (sweep rows P4) | H | Pure evaluator: inclusive starts and exclusive ends at exact boundaries; a frame spanning a whole window sweeps it once; clipping; sub-step counts honor the sampling bounds; one frame spanning the final step's remaining active window and its `RecoveryEnd`, and one spanning a non-final active window and its `LinkClose`, both still resolve the hit |
| A5 | `Aetheln.GameCombat.AttackTimeline.StepDefinitionFailsClosed` | P3 (P5 rows) | H | Grant refused for a wrong step count, each ordering violation including `LinkOpen == LinkClose`, non-finite or negative values, empty extents, `MaxTargets` below 1, a self-blocking commitment tag, and a blocking tag that is not a reset tag; P5 adds the `InterruptibleUntil` rows |
| A6 | `Aetheln.GameCombat.AttackTimeline.ChainProgression` | P3 | H | Injected clock: steps 1, 2, 3 in order; buffered press starts at `LinkOpen`; link press starts at once; early and second buffered presses get `ActivationBlocked` with no commit; a press after `LinkClose` or after the final step starts step 1; each step has its own activation id and sequence; a replayed accepted chain request neither advances the step nor commits |
| A7 | `Aetheln.GameCombat.AttackTimeline.ChainResets` | P3 | H | Timeout, completion, interruption (test result), unpossession, avatar destruction, `State.Dead` added through the test seam, and another ability's activation each reset with the right reason and reset time; a waiting buffered step never starts; the next press is step 1; two reset paths for one chain send one chain end; from P4, a mid-frame external reset drops only contacts at or after its reset time |
| A8 | `Aetheln.GameCombat.AttackTimeline.CommitmentWindow` | P3 | H | The commitment tag exists exactly in `[0, CancelOpen)`; a test ability blocked by it is refused before and allowed after, and its activation resets the chain |
| A9 | `Aetheln.GameCombat.AttackTimeline.ContactOnCapsuleOnly` | P4 | H | A sweep through a target capsule yields a contact; a shape overlapping only a query-enabled mesh yields none; the attacker is never its own target |
| A10 | `Aetheln.GameCombat.AttackTimeline.AlreadyHitAllowance` | P4 | H | A target inside the shape across several sub-sweeps and frames gets exactly one result per activation; a second activation can hit it again; a full record (`MaxTargets`) rejects new targets without eviction; a replayed candidate converges |
| A11 | `Aetheln.GameCombat.AttackTimeline.DeterministicOrdering` | P4 | H | Two attackers' same-frame contacts on one target resolve by the total order; reversing registration and tick order changes nothing |
| A12 | `Aetheln.GameCombat.AttackTimeline.DamageAndLethalLatch` | P4 | H | Health changes only through the damage effect by the test magnitude; it clamps at zero; the lethal notification fires once; a zero-Health target takes no further result |
| A13 | `Aetheln.GameCombat.AttackTimeline.DeadLifeStateRejected` | P4 | H | An attacker with `State.Dead` (test seam) is refused with `ActivationBlocked`; a target with it yields no result |
| A14 | `Aetheln.GameCombat.AttackTimeline.AvoidanceAndRelation` | P4 | H | A target with a test avoidance tag yields a recorded `Avoided` and no damage; a friendly player target yields nothing |
| A15 | `Aetheln.GameCombat.AttackTimeline.Interruption` | P5 | H | An interrupting result inside `InterruptibleUntil` resets the target's chain; outside it does not; a lethal target is not interrupted |
| A16 | `Aetheln.GameCombat.AttackTimeline.RejectionAndCorrectionTelemetry` | P2 | H | `TimestampOutOfBounds`, `ImpossibleAimTransition`, and the aim correction emit the events and metric in the tables; refused replicated-data routes are metric-only; the public copy has no diagnostic code |
| A17 | `Aetheln.GameCombat.AttackTimeline.RunsWithoutPresentation` | P3 | H | A step with no mesh, montage, or notify advances, ends, and (from P4) resolves contacts |
| A18 | `Aetheln.GameCombat.AttackTimeline.NoMaximumModifiers` | P4 | H | No #60 effect modifies a `Max*` attribute or adds a duration modifier to a current value |
| A19 | `Aetheln.GameCombat.Net.AttackOutcomeRouting` | P6 | P | The owner receives the outcome, record, and chain end; the other client receives the phase state but no record; both see result cues |
| A20 | `Aetheln.GameCombat.Net.ChainUnderProfiles` | P6 | P | The full chain and a buffered link under C1 and each C2 kind: no double commit or damage, deterministic resets, recorded correction, rejection (including `ImpossibleAimTransition`, for #82 S5), and miss rates |
| A21 | `Aetheln.GameCombat.Net.DisconnectMidChain` | P6 | P | Disconnect during wind-up, active, and a buffered wait: no result after avatar loss and no stale chain state for the new PlayerState |
| A22 | `Aetheln.POC.Input.AttackBindingSubmitsControlAim` | P6 | H | A Reticle-mode press builds a request with the control-rotation aim including pitch; Cursor mode blocks it; the recapture click is never an attack; a fresh press is needed after recapture |
| A23 | Packaged two-client run of the chain | later | K | Evidence for #2 and #48; not required to merge #60 |
| A24 | `Aetheln.GameCombat.AttackTimeline.HitTelemetry` | P4 | H | One hit event per committed result with the activation id, ability id, and sequence; no target identity |

CI runs a frozen two-test filter (`scripts/ci/Invoke-UnrealAutomationTests.ps1:14-15`),
so each code PR records local automation evidence at its exact head on the
pinned engine, as #19 does. P2 to P5 run `Aetheln.GameCombat`; P3 and P4 also
run `Aetheln.Movement` and `Aetheln.POC`, because they change GameCore (tags,
capsule response). P6 runs `Aetheln.POC` and records the manual PIE steps. No
#60 PR changes the GameNet vocabulary.

## Acceptance-Criteria Mapping

| Issue #60 criterion | Tests and text |
| --- | --- |
| No request field names an authoritative target or claims a hit | A1, A3; [Request Contract](#request-contract) |
| A valid sequence produces the three-hit chain and resets after timeout, interruption, unpossession, or incompatible action state | A6, A7, A8, A15, A20 |
| Early, late, duplicate, stale, impossible, and version-mismatched activations are rejected deterministically and do not spend or grant twice | A2 (late time sample, impossible aim), A6 (early press, replay), #19 T11 and T12 (duplicate, stale, version), A20. The reading of "late" is pending owner question 8: a late follow-up press is accepted as a new chain, not rejected. |
| An already-dead life state supplied through the test seam is rejected | A13 |
| Each activation damages every eligible target no more than the authored number of times | A10, A11, A20 |
| Server correction gives a bounded presentation correction without client state overwriting authority | A2, A19; [Bounded presentation correction](#bounded-presentation-correction) |
| Automated tests cover success, combo boundaries, duplicates, invalid windows, interruption, already-dead rejection, disconnect, and representative latency or loss | Automated: A4, A6, A7 (including unpossession and avatar destruction), A10, A13, A15. Latency, loss, and a real disconnect are covered only by manual PIE (A20, A21) until owner question 9 is answered. |

## Phased Delivery

Each PR targets `develop`, uses `Refs #60`, stays small, and leaves the spike
files untouched.

| PR | Scope | Depends on |
| --- | --- | --- |
| **P1** | This document and the index entry. Docs only. | Lead review |
| **P2** Request and aim | Schema 2, steps 6a to 6d in the pure validator, last accepted raw aim and time, the two result values, rejection and correction telemetry, client fill with `FlushServerMoves`, the four replicated-data overrides, the #19 fixture and specification changes (dependencies 3 to 5); A1 to A3, A16. | #19 P3 |
| **P3** Timeline and chain | Tags, step definition and grant validation, `UAethelnBasicChainAbility`, chain state and `ResetChain`, the commitment tag, the subsystem's boundary pass, owner record and chain-end RPCs, the observer phase state, the PlayerState hook, the zero-cooldown delta if needed; A4 to A8, A17. No contacts yet. | P2, #19 P4 |
| **P4** Contacts and damage | Combat query channel and `ECR_Overlap` capsule responses, sweeps, total order, time-aware revalidation, allowance records, relation default, avoidance hook, damage effect, lethal latch, result cues, hit telemetry; A9 to A14, A18, A24, and the sweep rows of A4 and A7. | P3 |
| **P5** Interruption | `InterruptibleUntil` and `bInterruptsTarget` added to the step struct with a content-version bump; A15 and the A5 rows. | P4 |
| **P6** Binding and two-client evidence | `IAethelnCombatInputSink`, the PlayerState implementation, the GameUI binding; A19 to A22; the #82 S5 attack scenario. | P5, #19 P5 (input-enabled pawn under the combat game mode) |
| **P7** Representative actives (owner-gated) | Gate Step and Sworn Rebuke contacts, Hold the Line's block, Guard pressure, and Guard break, on the same timeline. Gate Step's advance also needs #17. | P6 and owner question 3 |

## Open Questions for the Owner

1. **Prototype relation.** May one player's attacks hit the other player in the
   prototype arena? Recommendation: no; players are friendly and the enemy is
   hostile until faction policy exists.
2. **Re-clamp behavior.** Should a lowered maximum never raise a base value, as
   recommended in [Attribute Re-clamp Behavior](#attribute-re-clamp-behavior)?
3. **Representative actives.** Do Gate Step and Sworn Rebuke contacts and Hold
   the Line's Guard result stay in #60 as P7, or move to a follow-up issue?
   Recommendation: a follow-up issue, because #60's criteria cover only the
   chain and Gate Step needs movement validation with #17.
4. **Movement commitment.** Ship P3 to P6 with attacks that do not restrict
   movement, and add authored restrictions later with #17's predicted
   movement? A server-only restriction would cause a correction on every
   attack. Recommendation: yes.
5. **Buffered cost.** A buffered hit commits at its press; if the chain resets
   before it starts, nothing is refunded. Accept this? It matters only if the
   chain costs Endurance, which is #107 tuning. Recommendation: accept.
6. **Block action owner.** #60 resolves directional block for an active
   defense state. Which issue owns the right-mouse block action itself (#18,
   #60 P7, or a new issue)?
7. **Restart buffer.** May a press during the third hit's recovery be buffered
   into a new chain? Recommendation: no for the prototype; a press after the
   final recovery starts step 1.
8. **Meaning of "late" in the acceptance criteria.** The criterion says early,
   late, and other invalid activations are rejected. In this design, "late"
   means a request whose time sample is older than the allowed bound; it is
   rejected with `TimestampOutOfBounds`. A follow-up press that arrives after
   the link window closes is not rejected: the chain has already reset, so the
   press starts a new chain at step 1. Confirm this reading, or require that a
   late follow-up be rejected? Rejection would need `LinkClose < RecoveryEnd`
   and a lock tag held from `LinkClose` to `RecoveryEnd`. Recommendation:
   confirm; rejecting a press after the character is free would feel like
   dropped input.
9. **Automated latency, loss, and disconnect coverage.** The criterion asks for
   automated tests of disconnect and of representative latency or packet loss.
   The design automates unpossession and avatar destruction (A7) but covers
   latency, loss, and a real disconnect only with manual two-client PIE runs
   (A20, A21), following #19's precedent. Accept manual PIE evidence for those
   cases, or require headless automation? Recommendation: require headless
   rows, because the pure validator and the injected clock make them cheap.
   P3 and P4 would add rows that deliver chain requests with added delay around
   `BufferOpen`, `LinkOpen`, and `LinkClose`; duplicated, out-of-order, and
   dropped requests; and a PlayerState teardown mid-chain. AC7 would map to
   those rows, and A20 and A21 would stay as supplementary PIE evidence.

Decisions that belong to other owners, recorded so they are not lost: rewind
and any client-time window evaluation (#2, TC-002); every numeric bound,
window, and sampling budget (#45, #107); server sequences for AI telemetry
(#20); content version in observability correlation (#38); data assets (#84)
and generation (#106).

## Residual Risks and Known Gaps

1. **Present-time unfairness.** Moving targets can be missed at latency (see
   [Lag Compensation](#lag-compensation)). Owner: #2.
2. **Aim plausibility only.** The reference rotation and the time sample are
   client-derived, so the bounds limit forgery rather than prevent it. A wide
   soft bound lets a client nudge aim within it. Owner: #2.
3. **Frame-dependent sampling.** Contact existence can differ with server frame
   time for thin or fast shapes; ordering uses sweep fractions, existence uses
   the sampling budget. Owner: #45.
4. **PlayerState relevancy.** Phase state and cues replicate from an
   always-relevant PlayerState, which does not scale. Owner: TC-001, #45.
5. **Build-output citation.** The replicated-data cache closure relies on
   virtual declarations seen in local Unreal Header Tool output. P2 confirms by
   compiling.
6. **No movement commitment** until owner question 4 is resolved with #17.
7. **No death transition** until #21: a zero-Health actor is inert to #60 but
   is not dead.
8. **Reconnect refill** (#19 T34) also restores a chain-free state; #21 owns it.
9. **No occlusion.** Melee sweeps are not stopped by world geometry, so a shape
   that reaches through thin cover still hits. Canon asks for near-cover
   validation; revisit when the arena gains cover (see
   [Target query](#target-query)).
