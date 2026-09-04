# Issue #95 Opening-Screen Visual Review and CommonUI Plan

## Status, scope, and authority

This is a non-canonical visual-review and implementation-planning report for
Issue #95. It does not approve runtime UI, promote files into `Content/`, grant
production or publication rights, or change canonical product rules.

The review uses the repository's canonical design documents, the visual-package
governance files, the original seven concepts, the editable UI-production
studies, and the opening-flow V2 previews and supporting assets. Product facts
come from `docs/game-design-bible.md`, `docs/playable-peoples.md`, and
`docs/characters-and-factions.md`. Delivery boundaries come from Issues #3,
#53, and #95. Visual observations come from the inspected package material
listed below. Recommendations are proposed implementation contracts, not proof
of Unreal behavior.

Sources reviewed:

- `01-main-menu-concept.png` through `07-ui-style-system.png`.
- `ui-production/screens/main-menu.svg`, `settings.svg`,
  `accessibility.svg`, and `character-selection.svg`.
- `ui-production/screen-flow.md`, `unreal-commonui-spec.md`, UI tokens, and the
  UI-production README.
- Opening-flow V2 previews for main menu, settings, accessibility, character
  selection, dialog/tooltip, and loading.
- Supporting menu and selection backgrounds, logo, four button states, panel,
  selection-card frame, loading indicator, Kell selection render, slider, and
  toggles.

HUD, inventory, and gameplay-icon previews are excluded from opening-screen
implementation scope. They may inform visual consistency only.

## Evidence limits and approval gate

Observed statements describe visible static evidence. Recommended statements
describe a proposed CommonUI contract. A static image cannot validate focus
order, keyboard or controller navigation, safe zones, localization expansion,
contrast on the Unreal display pipeline, ultrawide behavior, scalable layout,
reduced motion, status announcements, or runtime state ownership. Those require
implementation and Unreal testing.

Every reviewed asset has provenance, authorship, permission, and license state
`Pending/TBD`. Pending/TBD provenance prohibits production, distribution,
publication, runtime use, `Content/` import, and asset approval. Reference-only
review is allowed. Potential internal prototype use requires explicit owner
approval first. Any publication, distribution, or runtime reuse requires
replacement or documented rights clearance. The package remains
`packageStatus: non-canonical`.

## Canonical and delivery guardrails

Identity, race, sex, appearance, class/Skein, faction/Doctrine, permanent
Character Level, seasonal Ember Rank, inventory/equipment, cosmetics, and
session state remain separate data concerns. Aurin, Kell, and Vesh each support
male and female characters, every supported class, and eventually either
faction. Race, sex, and appearance never alter statistics, authoritative
hitboxes, reach, timing, collision, traces, or loot probability.

Before the 2.0 faction stage, persist `Faction = Unassigned` and expose no
Doctrine selection. Do not infer final faction names, heraldry, colors, tuning,
customization depth, or unsupported options from concept art. Every unresolved
choice remains TBD.

Issue #3 owns minimal initial entry: name, one supported initial class,
server-owned deferred defaults, and safe-hub entry. Issue #53 later owns the
full Aurin/Kell/Vesh, male/female, and appearance editor. Issue #95 only reviews
visuals and proposes CommonUI structure; it implements neither flow.

## Opening-screen assessment

| Screen | Observed visual suitability | Legibility and contrast | Focus order and keyboard/controller navigation | Safe zones and localization expansion | Ultrawide and scalable layout | Required Unreal validation |
| --- | --- | --- | --- | --- | --- | --- |
| Main menu | Strong dark-fantasy identity, clear vertical grouping, and conspicuous orange focus. `CONTINUE` appears disabled. | Primary actions read clearly; small build text and bottom input hints are marginal. State must not depend on orange alone. | Proposed initial focus is `PLAY`, never a disabled action. Explicit up/down order; Accept activates; Back follows the root exit policy; mouse hover must not steal controller focus. Disabled actions are skipped and expose a reason. | Keep logo, actions, build text, and prompts inside `SafeZone`. Localize every label; allow multiline expansion and avoid baked text and forced spacing. | Use a bounded responsive content column over aspect-preserving background crop/fill. Do not stretch the baked 16:9 composition; unused ultrawide space is preferable to distortion. | Verify visible focus, device switching, disabled reasons, text scaling, longest translations, safe-zone clipping, and contrast at all target resolutions. |
| Character roster/selection | Roster cards, central preview, details, and bottom actions are distinct. Highlight and `ENTER WORLD` focus are clear. The concepts wrongly risk treating race cards as saved-character records. | Level, details, and faction presentation require readable scrims. The V2 sample correctly says Level 1 and Faction Unassigned, but does not prove state separation. | Initial focus restores the selected character's `ENTER WORLD` action or first valid roster item. Use explicit list/action-bar transitions. `DELETE` requires a modal confirmation; Back never deletes. | Replace the fixed bottom row with wrapping or adaptive actions. Roster cards and details must grow or scroll at large text sizes and under longer translations. | Switch between columns and stacked regions based on available width. Background and character render are presentation layers, not geometry authorities. | Verify empty/full roster states, focus restoration, destructive confirmation, long names, bidirectional text, safe zones, and controller reachability. |
| Minimal character entry (#3) | No concept may redefine this as the full editor. A restrained name/class form can reuse the visual vocabulary. | Labels, validation errors, deferred values, and server responses need persistent readable presentation. | Initial focus is the name field or first valid action. Accept submits only valid allowed fields; Back confirms abandonment when dirty. Pending requests disable duplicate submission and preserve focus. | Rows grow vertically, error text wraps, and the action footer remains reachable in a scroll container. | Use a centered bounded form that stacks at narrow widths and remains independent from background crop. | Verify only name and the one supported initial class are submitted, server-owned defaults are displayed accurately, and no faction/Doctrine or #53 controls appear. |
| Settings | Modal framing and row separation are legible; the orange focus and cyan state indicators are redundant. Exact settings and values are TBD. | Small slider handles, footer copy, and hue-heavy state treatment need stronger shape/text cues and contrast validation. | Deterministic order is category navigation, rows, then footer. Up/down changes rows; left/right changes tabs, sliders, and segmented values. Apply/Reset/Back behavior must be explicit. | Descriptions wrap; rows grow; large text uses scrolling while persistent footer actions remain accessible. All labels and values are localized. | Responsive panel width and capped line length replace fixed coordinates. Ornamental panels use validated nine-slice margins. | Verify focus traps, dirty-state confirmation, device prompts, values, persistence, reset behavior, resolution rollback, contrast, and text scaling. |
| Accessibility | Editable studies provide useful text-size, high-contrast focus, reduced-motion, color-vision, and subtitle-background references. Available features and defaults remain TBD. | Controls cannot rely on color; explanatory copy and current values must remain readable at large text scale. V2 preview discoverability is weaker because it omits descriptions. | Same explicit settings navigation; every toggle and slider has a semantic label and state. Focus remains visible under high-contrast and color-vision modes. | Permit substantial expansion, multiline descriptions, font fallback, bidirectional layout, and vertically growing rows. | Use responsive rows and scrolling; preserve controls within safe zones without shrinking text below policy. | Verify supported features in Unreal, contrast, screen-readable labels/status where available, reduced motion, subtitles, large text, and no navigation traps. |
| Dialog/tooltip and errors | Panel and ornament vocabulary can produce clear overlays, but static previews do not define modal semantics. | Dialog title, consequence, error, and button labels require a contrast scrim and clear hierarchy. Tooltips cannot be the sole source of required information. | Modal captures focus, defaults to the safest action, and restores the invoking control on close. Accept confirms the focused action; Back cancels when safe. | Dialog text wraps and scrolls if necessary. Buttons reflow instead of clipping. Keep all content inside `SafeZone`. | Size to content within bounded minimum/maximum dimensions; do not scale a raster panel uniformly. | Verify focus containment/restoration, destructive wording, async error states, device prompts, long translations, and assistive labels. |
| Loading | Logo, indicator, label, progress line, and tip form a coherent hierarchy. | Tip and progress line have weak contrast over scenery; add a scrim and readable status. | Normally non-focusable. If cancellation is supported, its action and focus policy are TBD and must be explicit. | Localized status and tips wrap inside a bounded safe region. Never bake text into the background. | Preserve background aspect ratio with crop/fill; status layout remains stable at 1280×720 through ultrawide and 4K. | Verify determinate, indeterminate, failure, transition, cancellation if supported, status announcement where available, and reduced-motion alternatives. |

## Per-asset classification

“Potential internal prototype” never means approved: it is allowed only after
owner approval. “Replacement/clearance required” applies before publication,
distribution, runtime use, or `Content/` promotion.

| Reviewed asset | Visual suitability | Rights/provenance state | Allowed current use |
| --- | --- | --- | --- |
| `01-main-menu-concept.png` | Suitable identity/composition reference; fixed baked layout and unvalidated labels conflict with responsive implementation. | Pending/TBD: authorship, permission, and license evidence unresolved. | Reference-only; potential internal prototype only after owner approval; replacement or rights clearance required before publication/runtime. |
| `02-playable-peoples-lineup.png` | Character identity reference only; cannot establish selectable options, layout, or combat differences. | Pending/TBD. | Reference-only; replacement or rights clearance required before publication/runtime. |
| `03-aurin-bulwark-equipment.png` | Equipment identity reference; outside opening-screen implementation and cannot define class availability. | Pending/TBD. | Reference-only; replacement or rights clearance required before publication/runtime. |
| `04-branmark-settlement.png` | Mood/background reference; does not declare a final capital or safe-hub layout. | Pending/TBD. | Reference-only; potential internal prototype only after owner approval; replacement or rights clearance required before publication/runtime. |
| `05-glasswake-reach.png` | Mood/background reference; outside interactive opening-screen geometry. | Pending/TBD. | Reference-only; potential internal prototype only after owner approval; replacement or rights clearance required before publication/runtime. |
| `06-character-selection-concept.png` | Useful composition reference; conflicts by presenting race cards as character records and implying options beyond Issue #3. | Pending/TBD. | Reference-only; replacement or rights clearance required before publication/runtime. |
| `07-ui-style-system.png` | Strongest component vocabulary and state reference; small text and color reliance need accessibility revision. | Pending/TBD. | Reference-only; potential internal-prototype styling guide only after owner approval; replacement or rights clearance required for reuse. |
| `ui-production/screens/main-menu.svg` | Useful editable layout study; hard-coded positions, labels, logo, and background are not scalable runtime UI. | Pending/TBD. | Reference-only; never direct runtime import without clearance. |
| `ui-production/screens/character-selection.svg` | Useful hierarchy and canonical reminder text; race-card model conflicts with saved-character semantics and Issue #3. | Pending/TBD. | Reference-only; replacement or rights clearance required before publication/runtime. |
| `ui-production/screens/accessibility.svg` | Useful functional reference for text size, focus, reduced motion, color vision, and subtitle background; options remain TBD. | Pending/TBD. | Reference-only; replacement or rights clearance required before publication/runtime. |
| `ui-production/screens/settings.svg` | Useful row/tab/layout reference; settings, defaults, ranges, and confirmation behavior remain TBD. | Pending/TBD. | Reference-only; replacement or rights clearance required before publication/runtime. |
| `main-menu-v2-preview.png` | Polished visual target but baked and non-responsive. | Pending/TBD. | Reference-only; potential internal-prototype comparison only after owner approval; replacement or rights clearance required. |
| `character-selection-v2-preview.png` | Polished roster-stage reference; fixed portraits and Kell presentation cannot define supported creation options. | Pending/TBD. | Reference-only; replacement or rights clearance required before publication/runtime. |
| `accessibility-v2-preview.png` | Useful density/state preview; settings and navigation are unconfirmed. | Pending/TBD. | Reference-only; replacement or rights clearance required before publication/runtime. |
| `settings-v2-preview.png` | Useful modal treatment; mixes unconfirmed display, audio, and accessibility values. | Pending/TBD. | Reference-only; replacement or rights clearance required before publication/runtime. |
| Dialog/tooltip V2 preview | Useful overlay hierarchy reference; no proof of focus capture, restoration, or accessible semantics. | Pending/TBD. | Reference-only; replacement or rights clearance required before publication/runtime. |
| `loading-v2-preview.png` | Suitable mood/composition reference; progress semantics, motion, contrast, and baked tip require redesign. | Pending/TBD. | Reference-only; replacement or rights clearance required before publication/runtime. |
| Menu/selection backgrounds | Atmospheric presentation only; baked 16:9 composition must not determine interactive geometry. | Pending/TBD. | Reference-only; potential internal prototype only after owner approval; replacement or rights clearance required. |
| Logo/wordmark | Useful placement reference; final logo and font rights remain TBD. | Pending/TBD. | Reference-only; replacement or rights clearance required before publication/runtime. |
| Normal, hover, focused, pressed, and disabled buttons | Orange outline and corner markers are a useful reusable focus language; text/state semantics must be rebuilt. | Pending/TBD. | Reference-only styling guide; potential internal prototype only after owner approval; replacement or clearance required for direct reuse. |
| Panel and selection-card frame | Natural CommonUI style references; require validated nine-slice/material treatment. | Pending/TBD. | Reference-only; potential internal prototype only after owner approval; replacement or clearance required for direct reuse. |
| Loading indicator, slider, and toggles | Useful state vocabulary; motion, hit targets, values, contrast, and semantics need runtime design. | Pending/TBD. | Reference-only; potential internal prototype only after owner approval; replacement or clearance required for direct reuse. |
| Kell selection render | Useful composition sample only; cannot define default race, sex, appearance, class, or combat properties. | Pending/TBD. | Reference-only; replacement or rights clearance required before publication/runtime. |

## Issue #3 minimal entry contract

The proposed Issue #3 screen contains only a localized character-name field,
the one supported initial class once canonically selected, validation/status
text, and Back/Create actions. The server owns all deferred defaults and the
safe-hub entry result. Read-only presentation may say appearance is deferred
and `Faction = Unassigned`, but must not imply selectable race, sex, appearance,
faction, Doctrine, progression, equipment, or cosmetic options.

Submission is idempotent from the UI perspective: one pending request disables
duplicate submission and displays server response or recoverable error. Exact
initial class, initial appearance/default presentation, name rules, and error
copy remain TBD.

## Issue #53 later editor contract

Issue #53 later owns separate Aurin/Kell/Vesh selection; male/female selection;
and separate race, sex, body, face, hair, markings, and voice editing. Those
fields remain independent from class, faction, Doctrine, progression,
equipment, cosmetics, and session state, and have no combat effects. This later
editor is not pulled into Issue #95 or Issue #3. Final customization depth and
available choices remain TBD.

## Proposed CommonUI structure

A root CommonUI policy should host `W_RootLayout` with independent activatable
layers:

1. Game layer.
2. Menu layer for the opening flow.
3. Modal layer for confirmations and errors.
4. Notification layer for non-modal status.
5. Loading layer above transitions.

Proposed `UCommonActivatableWidget` screens are Opening/MainMenu,
CharacterRoster, MinimalCharacterEntry, Settings, Accessibility, Dialog/Error,
and Loading. A destructive-action confirmation is modal. Reusable
`CommonButtonBase`, settings-row, roster-card, confirmation-dialog,
input-prompt, tooltip, and loading-status widgets are non-activatable building
blocks. Style assets remain replaceable and carry no product authority.

Every screen follows this hierarchy:

`SafeZone` → responsive scale/container → optional background art → contrast
scrim → semantic content panel.

Main menu uses a logo and vertical action list. Character roster uses an
adaptive roster list, preview viewport, details panel, and action bar. Settings
and accessibility use category navigation, a scrollable row list, and a
persistent footer. Loading is normally non-focusable and exposes determinate or
indeterminate status semantically.

## Interaction contract

- Default focus is deterministic: `PLAY`, the selected character's
  `ENTER WORLD`, or the first valid field/action. It is never disabled.
- Up/down traverses vertical lists. Left/right changes tabs, sliders, and
  segmented values. Focus wraps only where later documented; wrap policy is
  TBD.
- Accept activates the focused control. Back closes the top modal or screen,
  prompts before abandoning dirty settings or deletion, and never quits from a
  nested screen.
- A modal captures focus, selects the safest default, and restores the exact
  invoking control after close.
- Mouse hover does not steal controller focus. Input prompts update to the
  active device without moving focus.
- Disabled actions are skipped and provide a visible, localizable reason.
- Pending server requests prevent duplicate actions, preserve context, and
  return focus to the actionable error/retry path.

## Scaling, safe zones, localization, and accessibility

Author geometry in responsive containers rather than absolute coordinates. Use
CommonUI platform traits and the project's DPI scaling policy. Essential text
and controls remain inside `SafeZone`; readable line widths are capped; settings
copy wraps; rows grow vertically; and large-text layouts use scroll boxes.
Raster frames require validated nine-slice margins. Backgrounds preserve aspect
ratio through a documented crop/fill policy and never encode controls.

Validate at 1280×720, 1920×1080, 2560×1440, 3440×1440, and 3840×2160, plus
16:10 and 32:9 coverage. Ultrawide layouts add or crop presentation outside a
bounded content region without stretching ornamentation or moving controls
outside safe zones.

All visible strings are localized text, never baked into textures. Allow
multiline labels and substantial expansion; support bidirectional layout and
font fallback; avoid forced all-caps or letter spacing where it harms scripts.
State never relies on color alone: focus outline, corner/icon cues, text, and
shape remain redundant. Validate text/control contrast in Unreal. Provide
reduced-motion loading and focus presentation, plus screen-readable labels and
status where Unreal support permits.

## Asset-to-widget mapping and import risks

| Visual source | Proposed widget/style mapping | Import risk and gate |
| --- | --- | --- |
| Menu and selection backgrounds | Non-interactive background brush/material behind scrim | Baked 16:9 crop, contrast, resolution, rights, and memory require validation; no import while Pending/TBD. |
| Logo | Main-menu image slot with replaceable brush | Final wordmark and font/license are TBD; never bake layout around it. |
| Button states | `CommonButtonBase` style and semantic state cues | Validate focus versus hover, disabled reason, nine-slice margins, contrast, and rights. |
| Panel and selection-card frame | Nine-slice/material panel and roster-card style | Uniform raster scaling will distort ornament; margins, DPI behavior, and rights require validation. |
| Slider and toggles | CommonUI settings controls | Rebuild semantics, input increments, hit targets, labels, and disabled state; artwork is not behavior. |
| Loading indicator | Loading-status presentation | Provide reduced-motion and determinate/indeterminate alternatives; motion and rights remain TBD. |
| Kell render | Replaceable preview presentation | Cannot establish supported options or combat geometry; rights and final character asset remain TBD. |

No mapping grants import or runtime approval.

## Testable acceptance checklist

- [ ] Keyboard and controller reach every enabled control with no focus trap.
- [ ] Focus remains visible and restores to the invoking control after overlays.
- [ ] Accept, Back, dirty-settings prompts, and destructive confirmations behave
      consistently.
- [ ] Disabled actions are skipped and expose localizable reasons.
- [ ] Device prompts update without stealing focus.
- [ ] Large text and longest supported localized strings do not clip or overlap.
- [ ] Bidirectional text and font fallback remain usable.
- [ ] Safe zones retain every essential control at each target resolution.
- [ ] 1280×720, 1920×1080, 2560×1440, 3440×1440, and 3840×2160 layouts pass.
- [ ] Ultrawide adds/crops presentation without stretching ornament or escaping
      the bounded content layout.
- [ ] Raster frames use validated nine-slice margins; backgrounds encode no
      controls.
- [ ] Contrast is validated in Unreal and state never relies on color alone.
- [ ] Loading supports determinate, indeterminate, failure, and reduced-motion
      states, plus cancel behavior only if later approved.
- [ ] Issue #3 submits only allowed fields and displays server-owned defaults.
- [ ] No faction/Doctrine or Issue #53 appearance controls leak into the minimal
      flow; faction remains Unassigned before 2.0.
- [ ] Race, sex, and appearance remain combat-neutral and separate from class,
      progression, equipment, cosmetics, and session state.
- [ ] No reviewed asset enters `Content/` or runtime while provenance is
      Pending/TBD.
- [ ] Visual package, regression, formatting, Markdown-link, full CI, and
      `git diff --check` checks pass after all sequential packages are applied.
- [ ] Final scope contains only the five Issue #95 governance/report paths, and
      the manifest remains non-canonical with exact hashes, byte lengths, and
      counts.

## Blockers and unresolved TBD decisions

- Rights/license evidence and allowed internal-prototype terms for every asset
  class.
- Final logo/wordmark, production backgrounds, typography licensing, and font
  fallback coverage.
- The exact supported initial class and initial appearance/default presentation
  for Issue #3.
- Character-slot count, roster empty/full states, deletion policy and wording,
  Continue semantics, and account/session error behavior.
- Settings inventory, defaults, ranges, persistence, reset behavior, and
  resolution-confirmation timeout.
- Accessibility feature support and defaults.
- Loading progress availability, tips, transition/error/cancel behavior, and
  status-announcement support.
- Exact DPI curve, safe-zone margins, minimum resolution, ultrawide crop rules,
  focus-wrap behavior, and localization expansion targets.
- Final faction names, heraldry, colors, tuning, customization depth, and all
  unsupported options.

These blockers prevent approval but do not prevent reference-only planning.
