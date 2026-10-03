# Prototype Input, Camera, and Free-Aim Spike

## Status and scope

This is a preparatory contract for [Issue #82](https://github.com/ShayShimoni/aetheln-online/issues/82), not its completed feel study or an input-device approval. It inventories the implementation at `af5cb46ee5c7edc6e254c93f42650daa985c3afd` and gives the movement, combat, animation, UI, and automation owners a reproducible review plan. The [Game Design Bible](game-design-bible.md), [Combat and Networking Architecture](combat-and-networking-architecture.md), and [Prototype Game Brief](GameBrief.md) remain authoritative. This document does not change a gameplay rule or promote local POC tuning to the networked prototype.

The local movement POC pawn and the packaged authority-spike pawn are separate paths today. Their independent successes must not be described as a connected, player-operated, two-client combat loop. The proposed integration and feel checks below remain unrun.

## Current implementation inventory

The client-only, transient [`UAethelnPOCInputComponent`](../Source/GameUI/Private/AethelnPOCInputComponent.cpp) creates `UInputAction` objects and `IMC_POC_Movement` at runtime on the POC pawn. Its narrow [`IAethelnPlayerInputReceiver`](../Source/GameCore/Public/AethelnPlayerInputReceiver.h) interface passes local input to [`AAethelnPlayerCharacter`](../Source/GameCore/Private/AethelnPlayerCharacter.cpp); it has no combat-request method. The POC is a local movement and presentation experiment, not proof of predicted/reconciled sprint or combat under network conditions. [Movement POC](movement-poc.md) records its earlier owner feedback and limitations.

| Input or mode | Currently active in the movement POC | Boundary and status |
| --- | --- | --- |
| Move | Boolean `IA_POC_MoveForward`, `MoveBackward`, `MoveLeft`, `MoveRight` on W/S/A/D; opposed directions cancel and diagonals are normalized | The receiver converts camera-relative input into `AddMovementInput`; authoritative network bounds and corrections are not proved by this local POC. |
| Look and aim presentation | `IA_POC_Look` on Mouse2D, with Y negated and the first captured look sample suppressed | Controller yaw/pitch drives the spring-arm camera and reticle-facing steering. This is not a client-selected target or contact claim. |
| Zoom | `IA_POC_Zoom` on mouse wheel | Spring-arm distance, shoulder framing, owner-only mesh hiding, and close-camera presentation do not alter combat origins, collision, reach, or timing. |
| Jump | `IA_POC_Jump` on Space | Press, release, and cancellation reach the local receiver. Space remains jump even when a later combo follow-up is available on its own binding. |
| Sprint | `IA_POC_Sprint` on Left Shift | Predicted saved-move sprint flag (Issue #17); the server applies the walk/sprint speed caps and denies sprint while backpedaling or not walking. Jump takeoff and body facing, including Reticle aim steering as a second saved-move flag, are also simulated on the server; packaged multiplayer evidence remains Issue #17 work. |
| Reticle/Cursor | `IA_POC_ToggleControlMode` on Left Alt; `IA_POC_ViewportRecapture` on left mouse in Cursor mode | Reticle is the default, cursor hidden with a fixed center reticle. Cursor gates new gameplay input; a recapture click is consumed. Focus loss enters Cursor and recovery does not silently recapture. |
| Dodge | No POC input action or receiver method | Candidate action and handoff only; no binding, window, or success claim. |
| Basic attack | LMB is the product's remappable default, but no POC combat action is bound | The POC's left mouse mapping only recaptures from Cursor. The overlay labels primary attack as reserved. No click currently submits the authority-spike attack. |
| Defensive action and representative abilities | RMB is the product's remappable class-defense default; ability keys are not selected | No POC action, server request, or ability-key mapping is wired. The overlay labels RMB reserved. |

The [`UAethelnSpikeAuthorityComponent`](../Source/GameCombat/Private/AethelnSpikeAuthorityComponent.cpp) is a separate authority spike. Its current `FAethelnSpikeAttackIntent` carries schema/content versions, sequence, client timing sample, and quantized aim, with no target, contact, damage, or outcome fields. The packaged scenario submits it programmatically from [`AAethelnSpikeCharacter`](../Source/GameCombat/Private/AethelnSpikeCharacter.cpp), not from the POC input component. The server checks lifecycle, actor usability, versions, stale/duplicate sequence, timestamp bounds, finite unit aim, and consistency with authoritative controller view before trying the server ability; safe rejection reasons are recorded. The spike has no general ability identifier, press/release/charge states, or approved full `CombatActivation` transport yet. Its private provisional bounds and shape values are not canonical tuning. The spike-only invalid scenario probe is not a gameplay command.

Existing automated checks cover POC direction normalization/control-mode transitions and authority-spike rejection cases. They do not prove the integrated player-operated input path, controller behavior, camera-to-attack alignment, dodge, or a greybox feel result.

## Contract for the next integration

### Ownership, mode, and teardown

- `GameUI` owns local Enhanced Input actions, mapping-context installation, viewport capture, reticle/cursor state, and non-authoritative feedback. `GameCore` receives movement, look, zoom, jump, and provisional sprint intent through a presentation-neutral interface. `GameCombat` owns server-validated ability requests and outcomes; it must not import `GameUI` or let UI/animation decide hits.
- Install one owned mapping context per local player/pawn possession and remove that exact context when its owner is unpossessed, unregistered, destroyed, or leaves the local player during travel. The current POC also removes its context on focus loss; a later integration may instead disable it, but must enter Cursor mode, block new gameplay input, clear pending local state, and restore idempotently after valid focus/possession. Ignore keys held across restoration until release; suppress the first recaptured mouse delta and consume the recapture click.
- Reticle mode starts with a hidden cursor and fixed center reticle. Cursor mode blocks new move, look, zoom, jump, sprint, dodge, attack, defense, and ability presses; it clears pending local input and sends release/cancel where needed. It does **not** erase physical momentum, cancel an accepted server activation, or pause an authoritative timeline. Future CommonUI/dialogue layers must use stacked cursor ownership so closing one layer cannot recapture while another still owns Cursor mode. A UI-handled click never recaptures.
- Movement and camera remain independent of race, sex, body preset, appearance, and visual scale. One shared authoritative capsule, movement and combat rules, authored volumes, and accepted aim semantics apply to every presentation variant. Reticle placement, shoulder parallax, close-camera mesh hiding, animation offsets, and presentation sockets cannot change authority. Verify near-cover obstruction separately before claiming reticle/attack alignment.

### Candidate actions, not approved mappings

Keep the current active POC controls above distinct from proposed integration. The product approves remappable LMB primary attack, remappable RMB class defense, and Space jump. A dodge action and representative ability actions must be named, bound, and exercised in the integrated prototype, but their default keys, controller layout, chord behavior, remap UI, and accessibility targets remain unselected. Do not steal Space for a combo follow-up or treat the Cursor-mode LMB recapture as an attack. Compare candidate mappings in a hands-on study before promoting one.

### Bounded handoffs and feedback

| Producer to consumer | Required contract for integration | Prohibited shortcut |
| --- | --- | --- |
| Input to movement | Camera-relative movement and view orientation enter the CMC prediction/reconciliation path; sprint and later dodge require server-validated movement-state/prerequisite rules and saved-move integration where applicable. | A second client-owned transform authority, a client-local sprint speed write as multiplayer proof, or a client-asserted dodge outcome. |
| Input to combat/GAS | Send an allowed ability identity and press/release/charge phase, plus protocol/content version and bounded sequence/timing/aim sample as the action family permits. Server validates current connection/pawn/ability, ordering, time and aim limits, resources, cooldown, territory policy, and authored definition before creating a `CombatActivation`. | Selected target, claimed contact, trace shape/range/window, damage, cooldown result, block success, or arbitrary client timestamp authority. |
| Combat to animation/UI | Predicted cues are reversible and visibly distinguishable from accepted server state; accepted activation, correction/rejection reason, resource/cooldown state, and result references drive feedback. Animation notifies and camera effects remain presentation. | A montage notify opening a hit window, reticle color declaring a hit before server confirmation, or UI granting an outcome. |
| Integrated flow to automation | Exercise fresh/canceled presses across Reticle/Cursor, focus, possession, death/respawn, and reconnect; prove stale/duplicate/version/aim/time/availability rejections and no duplicate side effect. | Counting the existing programmatic packaged-spike attack as proof of a player-operated binding. |

The current spike validates one attack shape but does not yet implement the whole handoff table. The combat owner must extend its request and tests rather than simply exposing `SubmitAttack` to a new UI binding. Ability-specific prediction is opt-in only after rollback/correction tests. Numeric timing, aim, rate, and resource bounds remain `TBD` for their evidence owners; the existence of a provisional code value is not its approval.

## Reproducible greybox feel and authority study

Use the same exact source revision, pinned engine/toolchain, map, pawn/ability definition versions, hardware, display settings, process topology, and capture tooling across comparisons. Start with a warm local reference run, then the reviewed representative and harsh network profiles when available. Capture the server, two clients, and synchronized input/correction/activation/rejection evidence. A local one-player POC may supply directional feedback but cannot stand in for the packaged two-client gate.

1. In Reticle mode, traverse a greybox path while aiming across near cover, ramps, lateral/backward movement, jump/landing, zoom endpoints, and shoulder/close-camera transitions. Record intended aim, visible reticle, actual server-accepted direction, obstruction, correction, and any unreadable pose or telegraph.
2. Toggle Cursor with Left Alt, open overlapping future UI ownership layers when implemented, lose/recover focus, and recapture with an unhandled viewport click. Test held keys, first look delta, canceled actions, accepted attack continuation, gravity, and momentum. Record any phantom input or premature recapture.
3. With an integrated combat pawn, perform basic attack, defense, dodge, and representative abilities against an enemy and near-cover edge. Compare local cue, authoritative activation, rejection/correction, authored contact, and observed result. Vary aim during wind-up and repeat under the same network profiles; no claimed client target or hit may alter the result.
4. Repeat with mouse/keyboard and a controller candidate once a controller mapping exists. Record reachability, simultaneous move/look/action conflicts, cursor interaction, remap needs, and failure cases without claiming a supported controller layout or final accessibility target.

### Evidence record to complete during execution

| Field | Result or evidence link |
| --- | --- |
| Run date, reviewer, source revision, engine/toolchain, build/configuration | Not run; `TBD` |
| Map, character/ability definitions, hardware, display and capture settings | Not run; `TBD` |
| Server/client topology, network profile and measured latency/jitter/loss | Not run; `TBD` |
| Input-to-visible-action and input-to-server-accept/reject observations | Not run; `TBD` |
| Camera behavior, reticle readability, parallax/cover discrepancies | Not run; `TBD` |
| Movement and combat correction frequency/magnitude and recovery behavior | Not run; `TBD` (movement correction behavior: [Correction and rubber-banding](movement-poc.md#correction-and-rubber-banding)) |
| Mouse/keyboard and controller candidate observations, remap conflicts | Not run; `TBD` |
| Invalid/stale/duplicate/version/aim/time request failures and logs | Not run; `TBD` |
| Accepted/rejected candidate choices, limitations, owner, revisit trigger | Not run; `TBD` |

No latency, feel, accessibility, or controller result is inferred from this template. Issue #82 closes only after an actual reviewed study and focused integrated automated coverage; packaged multiplayer evidence and stage advancement retain their separate owners.

## Owner handoff and deferred decisions

- **Movement owner (#17):** supply one predicted/reconciled pawn path, saved-move sprint/dodge behavior where applicable, server bounds and correction telemetry. Preserve the local POC as learning evidence, not network acceptance.
- **Combat owner (Epic #6 children, with #2 authority input):** define versioned ability/phase request schema, server aim/orientation policy, GAS activation and authored windows, rejection tests, and a real input-to-request binding. Do not reuse the spike probe as gameplay data.
- **Animation/presentation owner:** align visible wind-up, active, recovery, dodge/block, and near-cover feedback to server-authored windows without moving authoritative contact or aim anchors.
- **UI owner:** implement stacked cursor ownership, reticle/correction/rejection presentation, remapping policy, and candidate controller layout only after review. Health, resource, and cooldown display must consume authoritative state.
- **Automation/evidence owners (#44, #45, #48):** run integrated two-client/local/network cases and record captures and decision evidence; distinguish editor, packaged, manual feel, and automated authority results.

Accepted constraints are pure free aim, server-owned outcomes, CMC/GAS ownership, gameplay-neutral appearance, and the product's Reticle/Cursor and LMB/RMB/Space defaults. Rejected shortcuts are target lock as authority, client hit or defense claims, animation-owned contact, a POC-only run as multiplayer proof, and invented device or tuning approval. Revisit this contract when the integrated pawn/request path exists, representative captures contradict an assumption, controller tests expose a conflict, or a reviewed product/architecture decision changes an owner boundary.
