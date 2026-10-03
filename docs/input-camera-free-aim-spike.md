# Prototype Input, Camera, and Free-Aim Spike

## Status and scope

This is the phase 1 (code-reading, no engine) contract for [Issue #82](https://github.com/ShayShimoni/aetheln-online/issues/82). It inventories the implementation at `688b6b11151b649a4c8d0a9f2fd6f817d0de0ac6` and supersedes the earlier inventory taken at `af5cb46ee5c7edc6e254c93f42650daa985c3afd`. Every `file:line` reference below is valid at that revision. It is not a completed feel study, controller evaluation, or input-device approval. The [Game Design Bible](game-design-bible.md), [Combat and Networking Architecture](combat-and-networking-architecture.md), [Architecture Decisions](architecture-decisions.md), and [Prototype Game Brief](GameBrief.md) remain authoritative. This document does not change a gameplay rule or promote local POC tuning to the networked prototype.

Phase 1 addresses acceptance criteria 1 (inventory), 2 (presentation independence), 3 (request audit), and 6 (owner input contract) from source evidence. Criteria 4 (greybox feel scenario) and 5 (controller and mouse/keyboard evaluation), and the definition-of-done item for focused automated request coverage, need the engine and are planned in [Phase 2 plan](#phase-2-plan-engine).

The local movement POC pawn and the packaged authority-spike pawn are separate paths today. Their independent successes must not be described as a connected, player-operated, two-client combat loop.

Source files cited below, by basename:

- Input and UI: [`AethelnPOCInputComponent.h`](../Source/GameUI/Public/AethelnPOCInputComponent.h), [`AethelnPOCInputComponent.cpp`](../Source/GameUI/Private/AethelnPOCInputComponent.cpp), [`AethelnPOCOverlayWidget.cpp`](../Source/GameUI/Private/AethelnPOCOverlayWidget.cpp)
- Pawn and movement: [`AethelnPlayerInputReceiver.h`](../Source/GameCore/Public/AethelnPlayerInputReceiver.h), [`AethelnPlayerCharacter.cpp`](../Source/GameCore/Private/AethelnPlayerCharacter.cpp), [`AethelnCharacterMovementComponent.cpp`](../Source/GameCore/Private/AethelnCharacterMovementComponent.cpp)
- Authority spike: [`AethelnSpikeAuthorityTypes.h`](../Source/GameCombat/Public/AethelnSpikeAuthorityTypes.h), [`AethelnSpikeAuthorityComponent.h`](../Source/GameCombat/Public/AethelnSpikeAuthorityComponent.h), [`AethelnSpikeAuthorityComponent.cpp`](../Source/GameCombat/Private/AethelnSpikeAuthorityComponent.cpp), [`AethelnSpikeMeleeAbility.cpp`](../Source/GameCombat/Private/AethelnSpikeMeleeAbility.cpp), [`AethelnSpikeCharacter.cpp`](../Source/GameCombat/Private/AethelnSpikeCharacter.cpp), [`AethelnSpikePlayerState.cpp`](../Source/GameCombat/Private/AethelnSpikePlayerState.cpp), [`AethelnNetworkSpikeGameMode.cpp`](../Source/GameCombat/Private/AethelnNetworkSpikeGameMode.cpp), [`AethelnNetworkSpikeAuthorityTests.cpp`](../Source/GameCombat/Private/AethelnNetworkSpikeAuthorityTests.cpp)
- Configuration: [`DefaultInput.ini`](../Config/DefaultInput.ini)

## AC1: Enhanced Input inventory

### Ownership and lifecycle

- **No input assets.** No `IA_*` or `IMC_*` asset exists under `Content/`. Every action and the single mapping context are transient objects created in code by `InitializeActions` (`AethelnPOCInputComponent.cpp:228-303`). `DefaultInput.ini` only selects `EnhancedPlayerInput` and `EnhancedInputComponent` as the default classes; there is no Enhanced Input user-settings or player-mappable-key configuration.
- **Owner.** `UAethelnPOCInputComponent` (`GameUI`, `UCLASS(Transient)`, `AethelnPOCInputComponent.h:20-25`) owns all actions, the context, the overlay widget, viewport capture, and Reticle/Cursor mode. The `BP_MovementPOCCharacter` asset (a thin `AAethelnPlayerCharacter` Blueprint) selects it through `OverrideInputComponentClass`, and `BP_MovementPOCGameMode` uses that Blueprint as its default pawn; the `MovementPOC` map uses that game mode. These asset facts were read from the assets' serialized names, not by opening the editor. The engine creates the override input component when the pawn restarts under a local player controller and destroys it on unpossession.
- **Binding.** `BindReceiver` binds only when the owner pawn has a local `APlayerController` and implements `IAethelnPlayerInputReceiver` (`AethelnPOCInputComponent.cpp:305-353`). The receiver interface (`AethelnPlayerInputReceiver.h:23-30`) has move, look, zoom, aim-steering, jump started/stopped/canceled, and sprint methods only; it has no combat, dodge, defense, or ability method.
- **Add.** `ActivateLocalPlayerResources` adds `IMC_POC_Movement` to the local player's `UEnhancedInputLocalPlayerSubsystem` at **priority 0** with `bIgnoreAllPressedKeysUntilRelease = true` (`AethelnPOCInputComponent.cpp:69-74`, `:368-380`). It runs from `OnRegister` (`:186`) and `ApplicationHasReactivated` (`:453-457`). A `bContextApplied` guard prevents a duplicate add.
- **Remove.** `ReleaseLocalPlayerResources` removes that exact context (`:410-417`) and the overlay widget (`:421-425`) after forcing Cursor mode (`:398`). It runs from `OnUnregister` (`:189-194`), `OnComponentDestroyed` (`:196-205`, which also clears bindings), and `ApplicationWillDeactivate` (`:448-451`). Reactivation restores the context in Cursor mode, so focus recovery does not silently recapture.
- **Packaged authority pawn.** `AAethelnNetworkSpikeGameMode` spawns the C++ `AAethelnSpikeCharacter` directly (`AethelnNetworkSpikeGameMode.cpp:30`). It sets no override input component, so it gets the default Enhanced Input component with no mapping context: the packaged spike has **no player input at all**. Its only movement is a scripted `AddMovementInput` (`AethelnSpikeCharacter.cpp:60-63`) and its only attack is a timed programmatic `SubmitFreeAimAttack(GetActorForwardVector())` (`:76-80`).

### Active actions in `IMC_POC_Movement`

No mapping has an explicit trigger object, so Enhanced Input's implicit default (down) trigger behavior applies to every mapping. The only modifier in the project is `UInputModifierNegate` on the look Y axis. No gamepad, touch, or alternative key is mapped.

| Purpose | Action (value type) | Key (`AethelnPOCInputComponent.cpp`) | Modifiers | Bound events and handler | Cursor-mode gate | Consumer |
| --- | --- | --- | --- | --- | --- | --- |
| Movement | `IA_POC_MoveForward`, `IA_POC_MoveBackward`, `IA_POC_MoveLeft`, `IA_POC_MoveRight` (Boolean, `:235-257`) | W, S, A, D (`:286-289`) | None | Started sets a held flag; Completed and Canceled clear it (`:332-343`, `:561-631`) | Started ignored in Cursor mode; release always clears | `BuildMovementInput` cancels opposed keys and clamps to unit length (`:32-43`); `TickComponent` sends it every tick while non-zero (`:207-226`, `:498-513`) to `ReceiveMoveInput`, which applies control-yaw-relative `AddMovementInput` with backpedal scaling (`AethelnPlayerCharacter.cpp:735-758`) |
| Camera and free aim | `IA_POC_Look` (Axis2D, `Cumulative`, `:259-261`) | Mouse2D (`:291-293`) | Negate Y only (`:23-30`, `:294`); no scalar, dead-zone, or smoothing modifier | Triggered (`:330`, `:633-645`); first sample after each Reticle entry suppressed (`:58-67`, `:483`) | Ignored in Cursor mode | `ReceiveLookInput` adds controller yaw and pitch (`AethelnPlayerCharacter.cpp:760-764`). Control rotation is the aim representation. Look sensitivity uses engine defaults; the project sets none. |
| Camera zoom | `IA_POC_Zoom` (Axis1D, `:263-264`) | Mouse wheel axis (`:295`) | None | Triggered (`:331`, `:647-658`) | Ignored in Cursor mode | `ReceiveCameraZoomInput` sets the desired spring-arm distance (`AethelnPlayerCharacter.cpp:766-779`) |
| Jump | `IA_POC_Jump` (Boolean, `:278-279`) | Space (`:301`) | None | Started, Completed, Canceled (`:346-348`, `:675-703`) | Started ignored in Cursor mode; release and cancel always pass | `Jump` with a landing buffer, `StopJumping`, buffer clear (`AethelnPlayerCharacter.cpp:786-816`) |
| Sprint | `IA_POC_Sprint` (Boolean, `:281-282`) | Left Shift (`:302`) | None | Started sets intent; Completed and Canceled clear it (`:349-351`, `:705-724`) | Started ignored in Cursor mode; release always clears | `bWantsToSprint` (`AethelnPlayerCharacter.cpp:1020-1027`), sent as saved-move `FLAG_Custom_0` |
| Reticle/Cursor toggle | `IA_POC_ToggleControlMode` (Boolean, `:266-270`) | Left Alt (`:296`) | None | Started (`:344`, `:660-664`) | Always active | `ApplyControlMode` (`:467-496`) |
| Recapture | `IA_POC_ViewportRecapture` (Boolean, `:272-276`) | Left mouse button (`:297-299`) | None | Started (`:345`, `:666-673`) | Acts only in Cursor mode; in Reticle mode the same press does nothing | Returns to Reticle mode |
| Aim steering (no key) | None; set by mode | Reticle entry sets it, Cursor entry clears it (`:433`, `:484-487`) | Not applicable | Not applicable | Cleared in Cursor mode | `bWantsAimSteering` (`AethelnPlayerCharacter.cpp:891-899`), sent as saved-move `FLAG_Custom_1` |

Cursor entry also clears move, sprint, jump, and aim-steering state, stops the movement tick, and flushes pressed keys (`AethelnPOCInputComponent.cpp:429-446`, `:473-479`). Reticle mode hides the cursor, captures the mouse permanently including the initial mouse-down, and uses game-only input; Cursor mode shows the cursor, releases capture, and uses game-and-UI input without locking (`:515-559`). The overlay's control legend is hard-coded text and labels primary attack and defense as reserved (`AethelnPOCOverlayWidget.cpp:47-52`).

### Required inputs with no action (gaps)

| Input | Product rule | Exists today | Gap and owner |
| --- | --- | --- | --- |
| Basic attack | Left mouse by default, remappable | No action, receiver method, or binding to the attack request | Binding `TBD`; combat owner with [#60](https://github.com/ShayShimoni/aetheln-online/issues/60). Left mouse is currently only the Cursor-mode recapture. |
| Class defense (directional block) | Right mouse by default, remappable | No action, receiver method, or request | Binding `TBD`; [#18](https://github.com/ShayShimoni/aetheln-online/issues/18) and #60 |
| Dodge | Server-validated defensive window | No action, receiver method, saved-move flag, or request | Key and transport `TBD`; [#18](https://github.com/ShayShimoni/aetheln-online/issues/18) |
| Three representative abilities | Remappable ability bindings; Space stays jump | No action, receiver method, or ability-identified request | Keys `TBD`; #60 and [#19](https://github.com/ShayShimoni/aetheln-online/issues/19) |
| Controller | Not committed | No gamepad key is mapped; Cursor toggle and recapture need a keyboard or mouse | Layout `TBD`; UI owner after the phase 2 evaluation |
| Remapping | LMB/RMB defaults are remappable | Impossible: actions are transient code objects without player-mappable key settings | Asset-based actions and contexts with player-mappable settings are a candidate, not a decision |
| Player-operated authority pawn | Required for integrated evidence | The packaged spike pawn has no input component | Integration owner (combat with #17) |

## AC2: Camera and aim independent of presentation and collision

No race, sex, body, or appearance concept exists in `Source/` (a case-insensitive search for race, sex, gender, appearance, female, and male finds nothing), so no such value can reach camera, aim, or collision code today. The positive evidence is:

| Property | Evidence |
| --- | --- |
| Authoritative capsule is fixed in C++, not taken from the mesh | `AethelnPlayerCharacter.cpp:675` |
| Body never copies controller rotation directly; facing is a movement-simulation decision | `AethelnPlayerCharacter.cpp:677-679`; `AethelnCharacterMovementComponent.cpp:234-293` |
| Camera boom attaches to the capsule root and follows control rotation; the camera adds no rotation | `AethelnPlayerCharacter.cpp:695-707` |
| Zoom, shoulder offset, target height, and mesh hiding run only on the locally controlled client and change only boom offsets and owner-only mesh visibility | `AethelnPlayerCharacter.cpp:724-733`, `:901-938` |
| Dedicated server disables pawn tick, so no presentation code runs there | `AethelnPlayerCharacter.cpp:718-721` |
| Presentation yaw rotates only the mesh, locally | `AethelnPlayerCharacter.cpp:993-1018` |
| Spring-arm collision probing moves only the camera, not the capsule | `AethelnPlayerCharacter.cpp:700` |
| Movement direction comes from control yaw, not the camera or mesh | `AethelnPlayerCharacter.cpp:940-946` |
| Backpedal, speed caps, and facing are judged from move acceleration and control yaw | `AethelnCharacterMovementComponent.cpp:127-169`, `:248-293` |
| Server aim comes from controller control rotation | `AethelnSpikeAuthorityComponent.cpp:385-391` |
| Attack origin is the actor (capsule) location plus aim; the query shape is a server-side value | `AethelnSpikeAuthorityComponent.cpp:530-539` |

Limits of this evidence:

- Only one presentation variant (`SKM_Quinn_Simple`) exists, so the male/female equivalence test required by [Automation and Manual Validation](combat-and-networking-architecture.md#automation-and-manual-validation) cannot run yet.
- The reticle is a fixed screen-center glyph (`AethelnPOCOverlayWidget.cpp:63-64`), so it marks the camera's forward ray. The server attack ray starts at the capsule and is parallel to it, offset by arm length, target height, and shoulder offset. Near cover can block one ray and not the other. This is a readability question for phase 2, not an authority defect.

## AC3: Client-to-server request audit

### Requests

| Request | Transport | Fields and versioning | Client-side bounds | Server validation | Server-owned results |
| --- | --- | --- | --- | --- | --- |
| Character movement (`ServerMove`, engine) | Unreliable CMC saved moves | Engine move data: client timestamp, quantized acceleration, client location, compressed flags, control rotation, movement base and mode. Project adds only `FLAG_Custom_0` (sprint) and `FLAG_Custom_1` (aim steering) (`AethelnCharacterMovementComponent.cpp:80-92`); `FLAG_Custom_2` and `FLAG_Custom_3` are unused. No project-level schema version. | Move input clamped to unit length (`AethelnPOCInputComponent.cpp:42`, `AethelnPlayerCharacter.cpp:744`) | Flags restored, not trusted for outcome (`AethelnCharacterMovementComponent.cpp:329-334`); acceleration clamped to maximum (`:304-316`); sprint and backpedal caps computed on the server (`:127-156`); facing derived at the rotation rate (`:248-293`); engine timestamp checks and position-error correction with client position not authoritative ([Correction and rubber-banding](movement-poc.md#correction-and-rubber-banding)) | Position, velocity, speed cap, movement mode, facing |
| `ServerSubmitAttack` (spike) | Reliable server RPC on `UAethelnSpikeAuthorityComponent` (`AethelnSpikeAuthorityComponent.h:46-47`) | `FAethelnSpikeAttackIntent`: `SchemaVersion` (uint8), `ContentVersion` (uint32), `Sequence` (uint32), `ClientTimestampSeconds` (double), `Aim` (quantized normal) (`AethelnSpikeAuthorityTypes.h:51-71`) | Client fills sequence, replicated server time, and aim (`AethelnSpikeAuthorityComponent.cpp:187-210`) | In order (`:221-275`): lifecycle ready; actor has authority, is not being destroyed, and has an ASC (`:380-383`); exact schema and content version; duplicate of last accepted; zero or lower sequence is stale; finite timestamp within `ProvisionalMaximumTimestampDeltaSeconds`; finite, non-zero unit aim within `AimUnitTolerance`; aim equal to the server's control-rotation vector within `AimUnitTolerance`. Then GAS activation of a server-only ability (`:443`); only success advances `LastAcceptedSequence` (`:470`). Safe rejection reasons are replicated and emitted as observability events. | Attack window and identity (`:430-433`), query origin and shape (`:530-539`), already-hit set (`:549`, `:560`), damage effect (`:561-572`), rejection reason |
| `ServerSubmitScenarioProbe` (spike-only) | Reliable server RPC (`AethelnSpikeAuthorityComponent.h:49-50`) | `FAethelnSpikeScenarioProbe` with claimed movement, aim, outcome, and magnitude (`AethelnSpikeAuthorityTypes.h:77-99`), deliberately separate from the intent | Sent only when the client runs the scenario flag (`AethelnSpikeAuthorityComponent.cpp:174-180`) | Ignored unless the **server** has the scenario flag (`:289-296`); otherwise validated, logged, and never applied (`:298-368`) | Nothing; rejection evidence only |
| GAS generic activation (engine) | ASC remote-activation RPCs on the player state | Not project-defined | Not applicable | The server-only melee ability is granted to the player ASC (`AethelnSpikePlayerState.cpp:33-37`). If a client reaches it through the engine path, `ExecuteActiveAttack` resolves nothing unless a validated intent opened the window (`AethelnSpikeAuthorityComponent.cpp:478-511`). | Same as above |

**Ownership confirmation.** No request carries a target, contact, hit, damage, cooldown, resource, block, or dodge result. The intent's five fields are structurally pinned and target, hit, and damage fields are asserted absent by `Aetheln.GameCombat.NetworkSpike.Authority` (`AethelnNetworkSpikeAuthorityTests.cpp:178-189`). The client timestamp is a plausibility check only; nothing rewinds to it. The server derives speed, backpedal, facing, attack origin, query, already-hit state, and damage. No cooldown, resource, dodge, or block exists yet, so none can be client-owned.

### Findings

Findings come from code reading at the pinned revision and are unmeasured. No finding shows a client-owned outcome, so none is rated high.

| ID | Severity | Finding | Evidence | Owner and next step |
| --- | --- | --- | --- | --- |
| F1 | Medium | Aim equality can reject legitimate presses. The server requires the intent aim to equal its current control rotation within `AimUnitTolerance`. Control rotation reaches the server only with the next unreliable movement packet, while the attack uses a separate reliable RPC. Any look motion between the last processed move and the press can produce `ImpossibleAimTransition`. The packaged scenario never exercises this: it submits the actor forward vector on a timer with no look input. | `AethelnSpikeAuthorityComponent.cpp:268-273`, `:385-391`; `AethelnSpikeCharacter.cpp:76-80` | Combat owner (#2, #60) chooses the policy, for example binding the request to a move or bounding the difference. First phase 2 measurement (S5). |
| F2 | Medium | No angular or temporal aim bound. The architecture requires rejecting impossible orientation changes outside temporal and angular bounds. `ImpossibleAimTransition` only checks consistency with the current control rotation, and control rotation itself has no server rate bound, so instant snaps are accepted. | `AethelnSpikeAuthorityComponent.cpp:268-273`; [Pure Free Aim](combat-and-networking-architecture.md#pure-free-aim) | Combat owner (#2, #60). Bound values `TBD`. Decide together with F1. |
| F3 | Medium | No rate limit or cooldown on attack requests. The ability activates and ends synchronously, nothing commits a cooldown, and the RPC is reliable, so the client controls how often a server query and effect run. The architecture lists "rate or resource limit exceeded" as a rejection category; the spike has no such reason. | `AethelnSpikeMeleeAbility.cpp:6-28`; `AethelnSpikeAuthorityTypes.h:7-20`; `AethelnSpikeAuthorityComponent.h:46-47` | #19 (cooldowns) and #60. Close before any player binding submits attacks. |
| F4 | Low | Rejection paths lack behavioral tests: stale sequence, timestamp out of bounds, content-version mismatch, and non-unit aim. Only reason-string stability is covered for stale and timestamp. The version case asserts no damage but not the reason. | `AethelnNetworkSpikeAuthorityTests.cpp:495-517` | Phase 2 test `ValidateIntentMatrix`. |
| F5 | Low | Sequence policy is open. Any forward gap is accepted; a client that jumps to the maximum value rejects all of its later requests as stale (self-only); wrap is unhandled. Accepted sequences cannot be replayed. | `AethelnSpikeAuthorityComponent.cpp:243-250` | Combat owner. Policy `TBD`. |
| F6 | Low | `LastRejection` replicates to every client that sees the pawn, not only its owner. | `AethelnSpikeAuthorityComponent.cpp:657-661` | Combat owner. Owner-only replication when the request leaves the spike. |
| F7 | Low | The probe RPC with claimed-outcome fields is compiled into every build. It is inert unless the server runs the scenario flag. | `AethelnSpikeAuthorityComponent.cpp:174-180`, `:289-296` | Keep it off the player pawn path or compile it out of non-test builds when the spike pawn becomes playable. |
| F8 | Low | Carried from the movement POC: engine movement time-discrepancy detection is off, and airborne aim-tracking facing has no rate limit. | [Movement baseline](movement-poc.md#movement-baseline); [Correction and rubber-banding](movement-poc.md#correction-and-rubber-banding) | #17 and #2. |
| F9 | Info | The intent has no ability identity and no press, release, or charge phase; one ability class is hard-wired. Defense, dodge, and abilities have no request path. | `AethelnSpikeAuthorityTypes.h:51-71`; `AethelnSpikeAuthorityComponent.cpp:443` | Combat owner extends the request; do not expose `SubmitAttack` to a binding as-is. |
| F10 | Info | Movement flag meanings are a protocol contract without a project schema version; they rely on matching client and server builds. | `AethelnCharacterMovementComponent.cpp:80-92`, `:329-334` | Revisit when a flag is added or reassigned. |
| F11 | Info | The resolved query uses the client's quantized aim after it matched the server view; the accepted direction is recorded only in scenario logs. The architecture asks to record the accepted direction and correction result. | `AethelnSpikeAuthorityComponent.cpp:123-171`, `:530` | Combat owner, with the `CombatActivation` record. |

## AC6: Owner input contract

| Owner | Exact inputs needed | Source today | Missing for integration | Must not consume or own |
| --- | --- | --- | --- | --- |
| Movement ([#17](https://github.com/ShayShimoni/aetheln-online/issues/17)) | Unit-clamped 2D move vector (X right, Y forward); control yaw and pitch; sprint intent; aim-steering intent; jump started, stopped, canceled | `IAethelnPlayerInputReceiver` (`AethelnPlayerInputReceiver.h:23-30`); saved-move flags (`AethelnCharacterMovementComponent.cpp:80-92`) | Dodge request and its direction source (`TBD`, #18) | Speeds, body rotation, client position authority, dodge success |
| Combat and GAS (#2, #18, #19, #60) | Ability identity; press, release, or charge phase; aim as the control-rotation unit vector at press, including pitch; per-pawn sequence; client timing sample; schema and content version; Reticle-mode gate with a fresh press after recapture; defense hold state | Spike intent covers version, sequence, timing, and aim only | Ability identity, phase, defense state, aim policy (F1, F2), rate and cooldown (F3), resource and territory-policy validation | Target, contact, trace shape, range, window, damage, cooldown result, block or dodge outcome |
| Animation and presentation | Replicated velocity, acceleration, movement mode, and rotation mode; local presentation yaw on the owning client; accepted activation and window phase; correction or rejection to cancel a predicted cue | Replicated movement; rotation-mode flags read by the locomotion Blueprint (`AethelnCharacterMovementComponent.cpp:254-258`); local mesh yaw (`AethelnPlayerCharacter.cpp:993-1018`) | Server timeline phases and correction events (#60); rotation mode for remote clients | Raw device input for gameplay timing; notifies opening hit windows |
| UI feedback ([#61](https://github.com/ShayShimoni/aetheln-online/issues/61)) | Control mode; reticle placement; cursor-ownership requests; binding labels; safe rejection reason; authoritative health, resource, and cooldown; correction indication | Mode and reticle (`AethelnPOCInputComponent.cpp:490-493`); replicated `LastRejection` | Stacked cursor ownership; labels derived from mappings instead of fixed text; resource and cooldown state; correction display | Declaring a hit before confirmation; granting an outcome |
| Automation and evidence ([#44](https://github.com/ShayShimoni/aetheln-online/issues/44), [#45](https://github.com/ShayShimoni/aetheln-online/issues/45), [#48](https://github.com/ShayShimoni/aetheln-online/issues/48)) | Pure input seams; server validation entry points; flag pack and restore; scenario and profile identities; safe-reason observability events with sequence | `BuildMovementInput`, control-mode and look-suppression helpers (`AethelnPOCInputComponent.cpp:32-74`); static `ValidateIntent` and `ProcessServerIntent`; movement friend tests; scenario command-line identities; observability events | A testable view of the built mapping context; an injectable player-operated attack path; a player-operated packaged scenario | Counting the programmatic packaged attack as proof of a player binding |

### Integration rules

- `GameUI` owns local actions, mapping-context installation, viewport capture, Reticle/Cursor state, and non-authoritative feedback. `GameCore` receives movement, look, zoom, jump, and sprint intent through the presentation-neutral receiver. `GameCombat` owns server-validated ability requests and outcomes; it must not import `GameUI` or let UI or animation decide hits.
- Install one owned mapping context per local player and possession, and remove that exact context when its owner is unpossessed, unregistered, destroyed, or loses focus. A later integration may disable instead of remove on focus loss, but must enter Cursor mode, block new gameplay input, clear pending local state, restore idempotently, ignore keys held across restoration, suppress the first recaptured mouse delta, and consume the recapture click.
- Cursor mode blocks new move, look, zoom, jump, sprint, dodge, attack, defense, and ability presses and sends release or cancel where needed. It does not erase momentum, cancel an accepted server activation, or pause an authoritative timeline. Future CommonUI and dialogue layers use stacked cursor ownership. A UI-handled click never recaptures.
- Candidate actions are not approved mappings. The product approves remappable LMB primary attack, remappable RMB class defense, and Space jump. Dodge and ability keys, controller layout, chord behavior, remap UI, and accessibility targets remain unselected. Do not steal Space for a combo follow-up or treat the Cursor-mode recapture click as an attack.
- Numeric timing, aim, rate, and resource bounds remain `TBD` for their evidence owners. A provisional code value is not its approval.

## Phase 2 plan (engine)

### Preconditions

- Use one exact source revision, the pinned engine and toolchain from [Unreal Project Setup](unreal-project-setup.md), the same hardware, display settings, and capture tooling across a comparison. Discard the first warm-up run, as [Verification and feedback](movement-poc.md#verification-and-feedback) requires.
- Steps S1 to S4 can run now on the `MovementPOC` map with the POC pawn. Step S5 needs a player-operated attack binding on a pawn with the authority component (#60 and the combat owner). Step S6 needs a candidate gamepad mapping.
- The POC pawn has no observability seam; correction events exist only on the spike pawn's movement component. Until one pawn has both, record POC corrections visually and spike corrections from events, and say which pawn produced each record.

### Network conditions

| Condition | Topology | Emulation | Use |
| --- | --- | --- | --- |
| C0 local reference | Standalone PIE, one player | None | Baseline feel and camera |
| C1 networked clean | PIE net mode "Play As Client" with two players and a separate server; record whether it runs under one process | None | Prediction and correction without added impairment |
| C2 networked impaired | Same as C1 | Editor network emulation or the `Net PktLag`, `Net PktLagVariance`, `Net PktLoss`, `Net PktOrder`, and `Net PktDup` console commands, applied to the side recorded with the result | One run per #44 catalog kind (`clean`, `representative`, `harsh`, `loss`, `duplication`, `reordering`) |
| C3 packaged | The existing packaged two-client runner ([Networking Authority Spike](networking-authority-spike.md)) | Caller-supplied profile arguments | Authority evidence only, not feel |

Emulation values are recorded verbatim with each result. They are reviewer choices for one run, not network profiles. Numeric profile values remain `TBD` until [#45](https://github.com/ShayShimoni/aetheln-online/issues/45) records them.

### Greybox feel scenario

For each step, record the condition, device, reviewer, and every field in the [evidence record](#evidence-record-to-complete-during-execution). Use `p.NetShowCorrections 1`, `stat unit`, `stat net`, and Unreal Insights with Networking Insights where they apply. No numeric target exists for latency, correction, or readability; record observations, not pass or fail against invented thresholds.

1. **S1 Movement and camera.** In Reticle mode, traverse the course loop with forward, strafe, backpedal, and diagonal movement, sprint, jumps including a landing-buffered jump, and aim-steered strafing. Sweep zoom across its full range and pass the camera corridor and obstacles. Record camera pops, collision pulls, shoulder transitions, mesh hiding, and any unreadable pose.
2. **S2 Aim readability.** Aim the reticle at fixed markers across near cover, ramps, and range. Compare the reticle point with the server's control-rotation ray from the capsule. This needs a reviewed debug visualization of that ray, which does not exist yet. Record parallax and obstruction mismatches.
3. **S3 Correction behavior.** Repeat S1 under C1 and each C2 kind. Record correction frequency, visible magnitude, recovery, and rubber-banding per course segment.
4. **S4 Mode and failure cases.** Toggle Cursor with Left Alt, hold keys across the toggle, lose and recover window focus, and recapture with a viewport click. Record phantom input, premature recapture, a consumed or leaked recapture click, the first look delta, and momentum and gravity during Cursor mode.
5. **S5 Attack request.** With a player-operated binding, attack while sweeping aim, while still, and during movement, under C0, C1, and each C2 kind. Record input-to-visible-action, input-to-server accept or reject, every rejection reason, and specifically the `ImpossibleAimTransition` rate (F1). Vary aim during wind-up; no client-claimed target or hit may change the result.
6. **S6 Device comparison.** Run S1, S4, and S5 with mouse and keyboard and with the candidate controller mapping; see [Controller and mouse/keyboard evaluation](#controller-and-mousekeyboard-evaluation).

Input latency has no in-engine marker today. Record the method with each value, for example frame counting on a capture whose frame rate is recorded. An in-engine input marker is reviewed phase 2 instrumentation, not an assumption.

### Evidence record to complete during execution

| Field | Result or evidence link |
| --- | --- |
| Run date, reviewer, source revision, engine/toolchain, build/configuration | Not run; `TBD` |
| Map, pawn, character/ability definitions, hardware, display and capture settings | Not run; `TBD` |
| Condition (C0 to C3), topology, emulation settings verbatim, measured latency/jitter/loss | Not run; `TBD` |
| Input-to-visible-action and input-to-server-accept/reject observations, with method | Not run; `TBD` |
| Camera behavior, reticle readability, parallax/cover discrepancies | Not run; `TBD` |
| Movement and combat correction frequency/magnitude and recovery behavior | Not run; `TBD` (movement correction behavior: [Correction and rubber-banding](movement-poc.md#correction-and-rubber-banding)) |
| Mouse/keyboard and controller candidate observations, remap conflicts | Not run; `TBD` |
| Invalid/stale/duplicate/version/aim/time request failures and logs | Not run; `TBD` |
| Accepted/rejected candidate choices, limitations, owner, revisit trigger | Not run; `TBD` |

No latency, feel, accessibility, or controller result is inferred from this template.

### Request-validation automation to add

Names follow the existing `Aetheln.<Area>.<Group>.<Case>` convention. Tests that pin a policy use the configured value, never a literal tuning number.

| Test | Covers | Can start |
| --- | --- | --- |
| `Aetheln.GameCombat.NetworkSpike.ValidateIntentMatrix` | Table test of static `ValidateIntent`: zero, lower, and equal sequence; schema and content version mismatch; timestamp at and beyond the bound on both sides; non-finite timestamp; zero, non-unit, and non-finite aim; reason precedence (F4) | Now |
| `Aetheln.GameCombat.NetworkSpike.RejectionHasNoSideEffect` | Stale, timestamp, and content-version rejections through `ProcessServerIntent` open no window, create no activation identity, and deal no damage (F4) | Now |
| `Aetheln.GameCombat.NetworkSpike.DirectAbilityActivationResolvesNothing` | Activating the melee ability on the ASC without a validated intent produces no overlap, effect, or damage | Now |
| `Aetheln.GameCombat.NetworkSpike.AimAfterLook` | Server control rotation changes after the intent is built; pins current behavior, then the chosen F1 policy | Now (current behavior); policy after F1 decision |
| `Aetheln.GameCombat.NetworkSpike.AimRateBound` | Aim change beyond the configured bound is rejected (F2) | After the bound exists |
| `Aetheln.GameCombat.NetworkSpike.RequestRateBound` | Requests inside the cooldown or rate window are rejected with a stable reason and no second effect (F3) | After #19/#60 add cooldown or rate rules |
| `Aetheln.GameCombat.NetworkSpike.SequencePolicy` | Large gaps and maximum value follow the chosen policy (F5) | After the policy exists |
| `Aetheln.POC.Input.MappingInventory` | The built context holds exactly the inventoried actions, keys, value types, and modifiers, with no trigger objects, so this document cannot drift silently | Now (needs a test seam for the built context) |
| `Aetheln.POC.Input.ContextLifecycle` | One add at priority 0 with ignore-pressed-keys; exact removal on unregister, destroy, and deactivate; reactivation in Cursor mode without a duplicate context | Now |
| `Aetheln.POC.Input.CursorModeGatesPresses` | Every started handler is inert in Cursor mode, and every release handler still clears state | Now |
| `Aetheln.Movement.Net.UnusedFlagsIgnored` | A move with `FLAG_Custom_2` or `FLAG_Custom_3` set changes no server speed, facing, or state | Now |
| `Aetheln.GameCombat.Input.AttackBindingSubmitsControlAim` | A bound press builds an intent whose aim is the control-rotation vector including pitch, blocked in Cursor mode and after a recapture click | After the attack binding exists |

### Controller and mouse/keyboard evaluation

1. Add a candidate gamepad mapping to the context as reviewed engine work. Record the keys and any dead-zone or sensitivity values used as candidate values for that run only.
2. Run S1, S4, and S5 with each device under the same conditions and reviewer.
3. Record reachability of simultaneous move, look, sprint, jump, attack, defense, dodge, and ability input; binding conflicts such as Left Alt, the recapture click, and Space; how a controller-only player leaves Cursor mode (today only Left Alt or a mouse click can); remap needs; and failure cases.
4. Do not record pass or fail against a tuning or accessibility target, and make no platform or supported-layout claim. Promoting a layout needs accountable approval.

### Steps that need the owner

| Step | Owner judgement needed | Agent-runnable |
| --- | --- | --- |
| S1, S2, S5, S6 | Subjective feel, aim readability, attack feel, device comfort | Setup, captures, logs, counts |
| S3, S4 | Whether corrections and failure cases are acceptable | Reproduction and recording |
| Candidate mappings and any tuning change | Approval before promotion to canon | Proposal only |
| Request-validation tests | None | Implementation and runs |

## Decision record scaffolding

### Accepted

- From canon, not new here: pure free aim; server-owned movement validity, hits, damage, cooldowns, and defense; CMC saved moves for custom movement intent; GAS with player ASCs on `PlayerState`; Reticle default with a Cursor gate; remappable LMB primary, remappable RMB defense, and Space jump; presentation-only camera, shoulder, and mesh hiding.
- Already implemented and reviewed under #17: sprint and aim steering as saved-move flags with server-derived speed and facing.
- POC only: transient, code-created actions and one priority-0 context. This is acceptable for the local POC and is not an integration decision.

### Rejected

- Target lock or soft lock as authority; client hit, contact, or defense claims; animation-owned contact.
- A POC-only or programmatic run as multiplayer or player-binding proof.
- Exposing the current `SubmitAttack` to a UI binding without ability identity, phase, aim policy, and rate rules.
- Space for a combo follow-up; the recapture click as an attack.
- Invented device, tuning, accessibility, or network-profile values.

### Open (`TBD`)

- Dodge, defense, and ability keys; controller layout; remapping mechanism.
- Aim policy (F1, F2), rate and cooldown rules (F3), sequence policy (F5).
- Numeric timing, aim, rate, resource, and network-profile values.

### Limitations

- Phase 1 is code reading at one revision; nothing was built, run, or measured.
- Asset facts come from serialized names, not the editor.
- The player-operated pawn and the authority pawn are separate; no player input reaches the attack request.
- One presentation variant exists, so variant equivalence is unproven.

### Revisit triggers

- A player-operated attack binding or a merged player/authority pawn exists.
- Phase 2 measures F1 or reticle parallax and contradicts an assumption.
- A gamepad mapping, asset-based actions, or player-mappable keys are introduced.
- #45 records network profiles, or #19/#60 add cooldown, rate, or timeline rules.
- A second presentation variant arrives.
- A saved-move flag is added or reassigned.
- A reviewed product or architecture decision changes an owner boundary.

## Owner handoff

- **Movement owner (#17):** keep one predicted and reconciled pawn path; add dodge through saved moves where applicable; supply correction telemetry on the player-operated pawn.
- **Combat owner (Epic #6 children, with #2):** resolve F1 to F3, F5, F6, F9, and F11; define the versioned ability and phase request; add the player-operated binding and its tests. Do not reuse the spike probe as gameplay data.
- **Animation and presentation owner:** align wind-up, active, recovery, dodge, block, and near-cover feedback to server-authored windows without moving authoritative contact or aim anchors.
- **UI owner (#61):** implement stacked cursor ownership, mapping-derived labels, reticle, correction, and rejection presentation, and a candidate controller layout only after review. Health, resource, and cooldown display consume authoritative state.
- **Automation and evidence owners (#44, #45, #48):** run the phase 2 conditions and captures; distinguish editor, packaged, manual feel, and automated authority results.

Issue #82 closes only after an actual reviewed study and focused integrated automated coverage; packaged multiplayer evidence and stage advancement keep their separate owners.
