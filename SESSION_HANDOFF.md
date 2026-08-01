# Session Handoff: Playable Movement POC

Updated: 2026-08-01

## Objective

Continue GitHub issue [#100](https://github.com/ShayShimoni/aetheln-online/issues/100), the local-only playable movement POC under Epic #6. This is a temporary learning exception before networked movement issue #17. It does not prove multiplayer movement or approve production art.

## Repository state

- Repository: the root of the current checkout
- Branch: `codex/100-reticle-cursor-poc`
- Baseline POC commit: `1ab315e` (`feat(movement): #100 add playable movement POC`)
- Integration base at publication: `origin/develop` commit `7053bcb`
- The current follow-up authorizes implementation only. Do not commit, push,
  publish, or merge without separate authorization.
- Inspect `git log`, the live issue, and the live pull request for the final publication identifiers and check state
- Issue #100 is `In Progress` pending owner hands-on confirmation.
- Do not change branches, pull, deploy, remove files, or resolve the unrelated config change without explicit user authority

## Current playable result

`/Game/Maps/MovementPOC` launches a possessed Quinn third-person character in a bright greybox traversal course with working collision, ramps, steps, walls, and a continuous safety floor.

Controls:

- `WASD`: camera-relative movement
- Reticle mode starts captured with a fixed center reticle, hidden cursor,
  camera-relative movement, and camera-facing steering
- `Left Alt`: toggle unlocked Cursor mode
- Unhandled viewport `LMB` in Cursor mode: recapture Reticle mode without
  forwarding the click as gameplay input
- `LMB` primary attack and `RMB` defensive action are reserved but inactive
- `Space`: jump, including the tuned landing buffer
- `Left Shift`: standalone-only sprint; backward movement cannot sprint
- Mouse wheel: camera zoom in consistent 40 cm steps

Final camera zoom tuning:

- Default spring-arm distance: 400 cm
- Minimum: 0 cm, producing a first-person-like view
- Maximum: 700 cm
- Step: 40 cm per wheel notch in both directions
- Every visible third-person distance uses a 35 cm local-right shoulder offset
  and 120 cm target height so Quinn stays below-left of the fixed reticle
- Wheel requests use 40 cm steps, animate at a constant 400 cm/s, and replace
  queued travel from the currently displayed distance so scrolling stops promptly
- At 50 cm Quinn hides and the camera recenters; the hidden transition then
  lowers linearly to the 70 cm first-person target height at 0 cm
- Requested zoom alone drives shoulder framing; spring-arm collision does not
  oscillate the offset
- Requested or resolved distance at 50 cm hides Quinn only for the owner;
  restoration waits until both reach 60 cm
- Camera collision, 90-degree FOV, and no-lag behavior remain unchanged; target
  height now transitions from 120 cm in third person to 70 cm at the first-person endpoint

Owner feedback at handoff:

- The owner said the course and prior camera behavior seemed good.
- After the final 0-700 cm / 10 cm-step change, the owner confirmed: "the camera zoom now ok."
- The owner later supplied zoom-sequence screenshots showing the reticle crossing
  Quinn's head and TERA references showing the desired below-left character
  composition. The persistent shoulder framing and linear transition address
  that feedback; fresh hands-on confirmation is pending.

## Reticle, cursor, and close-camera follow-up scope

The zoom follow-up modifies:

- `Source/GameCore/Private/AethelnPlayerCharacter.cpp`
- `Source/GameCore/Public/AethelnPlayerCharacter.h`
- `Source/GameCore/Public/AethelnPlayerInputReceiver.h`
- `Source/GameUI/Private/AethelnPOCInputComponent.cpp`
- `Source/GameUI/Public/AethelnPOCInputComponent.h`
- `Source/GameUI/Private/AethelnPOCOverlayWidget.cpp`
- `docs/movement-poc.md`
- `SESSION_HANDOFF.md` (this file)

The implementation keeps Enhanced Input inside client-only `GameUI`. `GameCore` receives only a neutral float zoom intent and does not include or link Enhanced Input.

## Important unrelated worktree change

`Config/DefaultEngine.ini` contains an unrelated Editor-generated modification from launching Unreal. It may contain generated authentication-like configuration. Preserve it, do not print its contents, and do not include it in the POC commit. Ask the user for explicit permission before removing or overwriting the exact generated block.

Because of this unrelated file, run scoped diff checks that exclude `Config/DefaultEngine.ini` until it is resolved.

## Verification state for the current follow-up

The current reticle/cursor and close-camera implementation has completed these
automated gates:

- Test-first evidence: directional input automation failed while mouse-button
  movement remained, then passed after its removal
- `AethelnOnlineEditor Win64 Development`: passed
- Full `Aetheln.POC` automation: 9/9 passed
- Full-Editor `validate-target`: 21 actors; 0 static-geometry, presentation, or movement failures
- Scoped `AethelnOnlineServer Win64 Development -Module=GameCore+GameCombat+GameNet+GameServer -NoLink`: passed
- Scoped `git diff --check`, excluding the unrelated config change: passed
- Owner PIE and Standalone confirmation remains pending

The earlier PR review added a regression for the now-removed both-button
forward shortcut. The current follow-up removes all mouse-button movement and
orbit intent; WASD remains the only directional input in this POC.

The usual Unreal platform discovery output still reports unavailable non-Windows SDKs, including VisionOS. Win64 is valid, the requested checks exit successfully, and this is not a regression introduced by the POC.

## Recommended next steps

1. Run focused and full `Aetheln.POC` automation, the Development Editor build,
   full-Editor target validation, scoped Server module compile, and scoped diff
   checks.
2. Launch `/Game/Maps/MovementPOC` for owner hands-on confirmation in PIE and
   Standalone, including focus loss, held inputs, the complete zoom path,
   corridor collision, and corner behavior.
3. Record subjective camera and input tuning feedback on issue #100 and keep it
   `In Progress` until the owner confirms the result.
4. Keep the unrelated `Config/DefaultEngine.ini` modification out of Git and
   all verification output.

## POC exclusions still in force

No controller, crouch, NPC interaction, cinematic dialogue cameras, interactive
menus, CommonUI cursor-ownership stack, combat execution, multiplayer proof,
audio, persistence, packaging, custom Aetheln art, or canonical performance
claim. Shoulder parallax and near-cover attack obstruction remain future combat
concerns; this POC does not prove reticle-to-attack alignment. Quinn remains a
temporary engine mannequin. Issue #17 still owns predicted, replicated,
server-validated movement.
