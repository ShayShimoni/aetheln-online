# Aetheln Online Visual Direction Package

## Direction

Stylized dark fantasy with grounded anatomy, exaggerated but readable
silhouettes, painterly hand-crafted materials, ancient monumental spaces, and
restrained supernatural color.

The world should feel beautiful and mythic while visibly carrying the scars of
the Duskbreak. Darkness establishes atmosphere without hiding characters,
combat telegraphs, navigation, or interface focus.

## Package

1. `01-main-menu-concept.png` - title screen and main-menu composition.
2. `02-playable-peoples-lineup.png` - male and female Aurin, Kell, and Vesh
   visual-identity study.
3. `03-aurin-bulwark-equipment.png` - one fitted armor identity with pavise and
   spear.
4. `04-branmark-settlement.png` - Branmark environment exploration without
   declaring it the final faction capital.
5. `05-glasswake-reach.png` - glass-scarred landscape and Ember-seeded life.
6. `06-character-selection-concept.png` - pre-faction character-selection UI.
7. `07-ui-style-system.png` - reusable menu components, states, materials, and
   palette.

Issue #114 adds ten original dark-fantasy references:

1. `01-overall-mood-key.png` - palette, weather, material, memory-damage, and
   negative-space direction.
2. `02-aurin-playable-study.png` - combat-neutral Aurin presentation study.
3. `03-kell-playable-study.png` - muscular, imposing, strongly non-human Kell
   presentation study.
4. `04-vesh-playable-study.png` - regular-haired, hoodless Vesh wearing a
   removable matte-white full-face mask with only eye-light visible.
5. `05-oathscar-combat-sheet.png` - Oathscar weapon, stance, motion, effect,
   resource, Peak, and counterplay language.
6. `06-nullwright-combat-sheet.png` - Nullwright visual combat language.
7. `07-hushblade-combat-sheet.png` - Hushblade visual combat language.
8. `08-gravecant-combat-sheet.png` - Gravecant visual combat language.
9. `09-blackfletch-combat-sheet.png` - Blackfletch visual combat language.
10. `10-combat-readability-scene.png` - gameplay-distance telegraph, block,
    dodge-lane, effect-geometry, and negative-space study without target lock.

## UI Production Kit

`ui-production/` turns the approved menu direction into editable source
material: clean background plates, SVG logo and controls, four 1920x1080 screen
layouts, design tokens, navigation flow, font guidance, and an Unreal CommonUI
implementation specification.

## Palette

- Charcoal black: `#101419`
- Cold slate: `#303943`
- Iron gray: `#55585A`
- Smoke glass: `#20272C`
- Parchment: `#D8D0BE`
- Ember orange: `#D76A28`
- Spectral cyan: `#55B8C4`
- Muted rust: `#7A3B2D`
- Dusk plum: `#4B354F`

Ember orange is the primary focus and active-state accent. Spectral cyan is a
secondary informational or supernatural accent. Required information must
never rely on color alone.

## Canonical Guardrails

- Aurin remain fully human with no innate supernatural anatomy.
- Kell are living organic-mineral people, not stone golems. Living skin covers
  most of the body; mineral anatomy is concentrated at the crown, selected
  facial planes, mantle, upper torso, and joints. A muscular, masculine, large,
  strongly non-human presentation is allowed only inside the shared playable
  scale and combat envelope.
- Vesh have two reflective eyes, a flush mouth seam, conventional hair,
  restrained subdermal light, and paired non-grasping back-veils. The white
  full-face mask shown in the new study is removable presentation equipment:
  it hides the face while worn but does not replace the underlying anatomy.
- Every people supports male and female characters, every class, and either
  faction.
- Visual appearance never changes authoritative collision, reach, traces,
  timing, statistics, or loot.
- Final faction names, heraldry, colors, capitals, and unresolved tuning remain
  open and are deliberately absent.

## Status

These images are visual-development concepts, not production-ready game assets.
They establish direction for review. Character turnarounds, shared-rig
overlays, equipment fit tests, material breakdowns, accessibility validation,
and Unreal implementation remain separate production steps.
