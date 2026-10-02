# Playable Movement POC

## Status and intent

GitHub issue [#100](https://github.com/ShayShimoni/aetheln-online/issues/100)
is a one-time P0 Prototype Gate learning exception under Epic #6. It validates
local movement, camera, animation, and traversal feel before the networked
movement story. Issue #17 remains in Backlog and still owns saved-move
prediction, replication, server validation, correction, and multiplayer
evidence.

This POC is temporary. Quinn is an engine mannequin, not an approved Aetheln
race, sex, class, silhouette, animation set, or combat property. None of the
imported content has production-art approval.

## Pinned source and migration

- Engine tag: `5.8.1-release`
- Engine commit: `71fe36aac5a8df5ccd66c763ffc902b29b6a9c43`
- Temporary source project used for this run:
  `<system-temp>/AethelnMovementPOC-100-20260729`
- Third Person template source:
  `Templates/TP_ThirdPersonBP`
- Quinn source:
  `Templates/TemplateResources/High/Characters/Content`
- Greybox source:
  `Templates/TemplateResources/High/LevelPrototyping/Content`
- Reproducible audit/authoring helper: `scripts/build_movement_poc.py`

The temporary project was created outside the repository. Unreal Asset Tools
resolved the roots below, then migrated the audited hard-package closure with
dependency expansion disabled. This prevents editor-preview soft references
from broadening the import while retaining the exact package paths:

- `/Game/Characters/Mannequins/Meshes/SKM_Quinn_Simple`
- `/Game/Characters/Mannequins/Anims/Unarmed/ABP_Unarmed`
- `/Game/LevelPrototyping/Meshes/SM_Cube`
- `/Game/LevelPrototyping/Meshes/SM_Ramp`

The source closure contained 45 packages and 37,949,238 bytes. Unreal's
migration save produced 37,976,766 bytes in the repository. All imported
`.uasset` files inherit the repository's LFS and locking attributes.

## Imported dependency inventory

The character closure contains 39 packages:

- Unarmed animation:
  `ABP_Unarmed`, `BS_Idle_Walk_Run`, `MM_Idle`
- Jog clips:
  `MF_Unarmed_Jog_Bwd`, `MF_Unarmed_Jog_Bwd_Left`,
  `MF_Unarmed_Jog_Bwd_Right`, `MF_Unarmed_Jog_Fwd`,
  `MF_Unarmed_Jog_Fwd_Left`, `MF_Unarmed_Jog_Fwd_Right`,
  `MF_Unarmed_Jog_Left`, `MF_Unarmed_Jog_Right`
- Walk clips:
  `MF_Unarmed_Walk_Bwd`, `MF_Unarmed_Walk_Bwd_Left`,
  `MF_Unarmed_Walk_Bwd_Right`, `MF_Unarmed_Walk_Fwd`,
  `MF_Unarmed_Walk_Fwd_Left`, `MF_Unarmed_Walk_Fwd_Right`,
  `MF_Unarmed_Walk_Left`, `MF_Unarmed_Walk_Right`
- Jump clips: `MM_Fall_Loop`, `MM_Jump`, `MM_Land`
- Materials: `M_Mannequin`, `MI_Quinn_01`, `MI_Quinn_02`
- Meshes and skeleton: `SKM_Quinn_Simple`, `SK_Mannequin`
- Rigs: `CR_Mannequin_FootIK`, `PA_Mannequin`
- Shared base-material textures:
  `T_Manny_01_BN`, `T_Manny_01_D`, `T_Manny_01_MRA`,
  `T_UE_Logo_M`
- Quinn textures:
  `T_Quinn_01_D`, `T_Quinn_01_MRA`, `T_Quinn_01_N`,
  `T_Quinn_02_D`, `T_Quinn_02_MRA`, `T_Quinn_02_N`

The three `T_Manny_01_*` files are hard dependencies of the shared mannequin
base material; no Manny mesh or material instance was imported.

The Level Prototyping closure contains six packages:

- Meshes: `SM_Cube`, `SM_Ramp`
- Materials: `M_PrototypeGrid`, `MF_ProcGrid`,
  `MI_PrototypeGrid_Gray`
- Texture: `T_GridChecker_A`

Seven soft-only editor/preview dependencies were explicitly excluded:
`SKM_Manny_Simple`, `CR_Mannequin_Body`, `MI_Manny_01_New`,
`MI_Manny_02_New`, `T_Manny_02_BN`, `T_Manny_02_D`, and
`T_Manny_02_MRA`. No combat, weapon, death, touch, variant, template
Blueprint, template map, or template input asset was imported.

## Runtime composition

`/Game/Maps/MovementPOC` is a classic, non-World-Partition map with OFPA
disabled. It has 21 actors:

- 17 static, non-ticking greybox geometry actors using two meshes and one
  shared grid material
- one `PlayerStart`
- one movable directional light
- one movable real-time skylight
- one sky-atmosphere actor

The course is approximately 60 m square. A single continuous safety floor sits
under the complete traversal loop. The course includes:

- two 18.4-degree ramps and a raised platform
- four 25 cm step increments, below the 45 cm character step limit
- a 300 cm-wide camera corridor
- three camera-collision obstacles
- four perimeter safety walls

There are no navigation bounds, combat actors, effects, audio, or interactive
actors. The map overrides its game mode only through
`BP_MovementPOCGameMode`; the project-wide game mode remains
`AAethelnGameModeBase`.

The 15 box-based actors use `/Engine/BasicShapes/Cube`, including its
engine-native simple collision. PIE feedback proved that the migrated
Level Prototyping `SM_Cube` body did not block the character despite valid
component profiles, so that asset remains in the audited migration inventory
but is no longer referenced by the runtime map. The migrated template ramp
could not produce a valid simple or convex hull through Unreal's mesh-editor
tooling, so its two static POC instances use complex-as-simple collision. This
bounded fallback preserves the authored slope and is not a production collision
or performance approval.

`/Game/POC/ABP_MovementPOCLocomotion` is a POC-only derivative of the
untouched migrated `ABP_Unarmed`. Camera-facing pure lateral movement selected
the template's extreme -90/+90-degree side clips, which owner feedback found
visually ambiguous. A first POC pass forced the template's -45/+45-degree
direction clamp, but that prevented a true backward pose. The current derivative
restores the template movement-mode selector: travel-facing movement uses the
clamp, while camera-facing aim and S backpedaling use raw direction. In the
POC-only BlendSpace, the ambiguous pure-left/right samples at -90/+90 degrees
use the corresponding forward-left/right clips; the authored backward and
backward-diagonal samples remain intact. This changes only temporary
presentation; movement trajectory, camera aim, capsule collision, and authority
remain separate.

`/Game/POC/BS_MovementPOCLocomotion` is a POC-only derivative of the untouched
migrated `BS_Idle_Walk_Run`. The template limited sample-weight changes to
5/sec and eased them in and out, creating a visible delay after a direction
key changed. Fully disabling smoothing made turns visually rigid. The bounded
POC tuning uses a faster 12/sec sample-weight transition without ease-in/out,
so the pose blends briefly without delaying movement.

`EditorStartupMap` and `GameDefaultMap` point to `MovementPOC`.
`ServerDefaultMap` deliberately remains `StarterMap`.

## Movement baseline

- Capsule: 42 cm radius, 96 cm half-height
- Walk: 500 cm/s
- Backpedal: 350 cm/s (70% movement scale); backward and backward-diagonal
  movement cannot sprint
- Provisional forward/lateral sprint: 700 cm/s
- Jump velocity: 500 cm/s
- Landing jump buffer: 0.20 seconds
- Air control: 0.0; horizontal trajectory locks after takeoff
- Falling braking: 0.0; locked horizontal takeoff momentum persists until
  landing instead of decelerating in mid-air
- Maximum acceleration: 10,000 cm/s²
- Ground friction: 16
- Camera-facing rotation: 720 degrees/s. Reticle mode continuously steers Quinn
  toward camera-forward while WASD remains camera relative. S backpedals
  without a 180-degree reverse turn, and A/D remain strafes while the
  visible mesh adds up to 35 degrees of proportional yaw toward lateral ground
  travel (about 25 degrees for a normalized forward diagonal). This stronger
  body angle blends in and out without changing movement, aim, collision, or
  the camera. Movement trajectory changes immediately; the lower facing rate
  smooths only the visible ground turn.
- A jump uses the normalized direction held at takeoff. Airborne input cannot
  redirect the trajectory. Reticle camera movement may turn capsule
  facing while airborne without changing velocity. Diagonal aimed jumps with
  positive forward input add up to 25 degrees of local, presentation-only mesh
  yaw toward the locked takeoff direction; it blends in and returns after
  landing without changing collision or aim. Pure lateral aimed jumps instead
  snap the whole body to the locked travel direction. While Reticle mode remains active,
  later camera-yaw changes rotate that airborne body angle by the same amount
  without redirecting velocity. Separate camera-facing head
  tracking is deferred. Backward aimed jumps add no local yaw and retain
  camera-forward body facing.
- A Space press during the final 0.20 seconds before landing is retained once
  and consumed on landing. Both buffered and just-grounded jumps replace the
  previous horizontal velocity with the latest held camera-relative direction,
  so an airborne right-to-left input change launches the next jump left without
  allowing steering during the current jump. Free-running jump takeoff also
  snaps capsule/body yaw to that resolved direction, avoiding incremental turns
  across rapid landing jumps. Backpedal takeoff snaps the body to camera-forward
  while velocity remains backward. Aimed takeoff snaps its base yaw to camera
  aim; only a forward-plus-lateral takeoff layers the 25-degree directional
  mesh turn on top. Expired, canceled, focus-lost, unpossessed, and teardown
  requests are discarded.
- Camera: default 400 cm collision-aware spring arm, dynamic target height,
  90-degree FOV, no camera lag, and bounded mouse-wheel zoom from 0 cm to
  700 cm in consistent 40 cm requested steps animated at a constant 400 cm/s.
  Each wheel event replaces any remaining queued travel with one step from the
  currently displayed distance, so releasing the wheel cannot leave a long
  camera glide. Every visible third-person frame uses a 35 cm local-right shoulder offset and
  a 120 cm target height so Quinn remains below-left of the fixed reticle, as in
  the approved action-camera reference. At 50 cm the mesh hides and framing
  recenters; from 50 cm to the 0 cm endpoint, the hidden first-person camera
  lowers linearly to its 70 cm eye-level target height. Only the animated
  requested zoom drives framing. Quinn hides from the owning local camera
  when requested or collision-compressed distance reaches 50 cm and restores
  only after both reach 60 cm.
- Input: Reticle mode is the default, with a hidden cursor, fixed reticle,
  camera-relative WASD, and camera-facing steering. Left Alt toggles unlocked
  Cursor mode; an unhandled viewport click recaptures Reticle mode. Focus loss
  enters Cursor mode and focus recovery does not recapture automatically.
  Cursor mode blocks new movement, look, zoom, jump, and sprint input while
  physics and accepted movement continue naturally. Recapture consumes the
  click and first mouse delta and requires fresh key presses. Space jumps, Left
  Shift sprints forward or laterally, and the wheel zooms. LMB primary attack
  and RMB defensive action are reserved but inactive in this movement POC.

The runtime input actions and mapping context are transient and retained by the
POC input component. They are scoped to the POC pawn Blueprint, removed on
teardown or focus loss, and restored without duplication in Cursor mode after
focus returns.
Jump and sprint state are cleared on cancellation, focus loss, unpossession,
component destruction, and PIE shutdown.

Sprint is deliberately disabled while backpedaling. Issue #17 replicates it:
`UAethelnCharacterMovementComponent` packs sprint intent into the predicted
saved move as `FLAG_Custom_0`, and the server grants sprint speed only while
walking with non-zero acceleration that is not backward relative to control
yaw. Any other sprint request simulates walk speed, and a client that predicted
sprint anyway is corrected. Clients never send speeds. `Aetheln.Movement.Net.*`
covers the flag round trip, the server speed clamp, and rejected requests.

## Verification and feedback

The mouse-button observations in the historical tuning table below describe
the earlier control scheme that produced the retained facing and jump tuning.
The current Reticle/Cursor scheme supersedes those bindings without discarding
the accepted movement behavior.

Automated evidence for this branch:

- pre-change `StarterMap` headless load: passed
- post-change `StarterMap` headless load: passed
- `MovementPOC` headless load: passed with its POC game mode and no missing
  content
- `AethelnOnlineEditor Win64 Development`: passed
- `AethelnOnlineServer Win64 Development` project modules with `-NoLink`:
  compile-only client-module leakage check; this is not issue #15 linking,
  packaging, or packaged-server evidence
- no `__ExternalActors__`, `__ExternalObjects__`, generated directories, or
  unapproved asset families were introduced

The first shader/DDC run is a warm-up and must be discarded before judging
feel. The owner completed the local one-player PIE feedback and bounded tuning
pass. The final confirmation reported that the course, movement, camera, and
mouse-wheel zoom felt good:

| Area | Feedback | Bounded tuning |
| --- | --- | --- |
| Acceleration and braking | W+A/W+D direction changes eased into the turn; full air control allowed unwanted navigation, while zero air control plus falling braking stopped forward momentum | Maximum acceleration 10,000 cm/s² and ground friction 16 on ground; air control 0 and falling braking 0 lock and preserve takeoff trajectory; owner confirmed final feel |
| Turn rate | Instant rotation and zero animation smoothing looked rigid; S also rotated Quinn 180 degrees, lateral-to-S left the body sideways, the first 1,080-degree/s tuning still felt rigid in free running, LMB orbit redirected held movement as controller yaw changed, and grounded RMB strafing did not show enough body angle | Ground facing reduced to 720 degrees/s while trajectory response stays immediate; fast 12/sec non-eased presentation blend, camera-aligned S backpedal, an LMB-only movement-yaw lock, up to 35 degrees of presentation-only grounded RMB strafe yaw, airborne RMB/both facing control without trajectory steering, and instant free-jump takeoff facing; owner confirmed final feel |
| Camera distance and pitch | Owner confirmed the base camera and course traversal felt good, then requested fine mouse-wheel control from a first-person-like endpoint to a substantially farther overview | Bounded 0-700 cm spring-arm zoom using consistent 10 cm steps; the local mannequin hides at 50 cm or closer and returns when zooming out; owner confirmed final zoom feel |
| Sprint | Backpedaling at the forward or sprint pace felt unnatural | Backward and backward-diagonal input uses a 70% scale for 350 cm/s, and Shift cannot raise the backward cap; owner confirmed final feel |
| Jump | A direction change followed by Space at landing worked inconsistently because the press could arrive just before or after the grounded transition; rapid free and backward chains moved correctly but body facing turned only partway; forward RMB diagonals needed a stronger pose; pure RMB lateral jumps faced camera-forward, then could not follow later RMB camera turns after travel-facing takeoff was added | A one-shot 0.20-second landing buffer handles timing; free and pure-lateral RMB takeoff snap the whole body to travel yaw; pure-lateral RMB body yaw then tracks camera-yaw deltas while velocity stays locked; backward takeoff snaps camera-forward; and forward-diagonal RMB/both applies up to 25 degrees of local mesh yaw; independent camera-facing head tracking is deferred; owner confirmed final feel |
| Animation sliding | Camera-facing A/D returned to the same-side pose when raw -90/+90 samples were restored; removing all smoothing also made transitions unnatural | POC -90/+90 samples use distinct forward-left/right clips, backward samples remain authored, and transitions use a fast 12/sec non-eased blend; owner confirmed final feel |
| Layout and snagging | Owner traversed the final course and reported that it seemed good, with no remaining snagging or falling issue | No additional layout tuning required |

After the bounded tuning pass, the applicable build, target validation, asset,
automation, server-leakage, and hands-on checks passed. Publication and review
still govern advancement beyond local implementation evidence.
