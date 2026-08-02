# Aetheln Online UI Production V2

This pass replaces the flat SVG interpretation with painted raster assets that
match the visual language of `01-main-menu-concept.png`: aged iron, smoked
glass, hairline ornament, cold silver typography, and restrained ember light.

## Review first

Open `previews/main-menu-v2-preview.png`. It is assembled from the separate
production assets in this folder; it is not a newly painted one-piece screen.

## Runtime assets

| File | Purpose | Pixel size |
| --- | --- | --- |
| `assets/main-menu-background.png` | Clean cinematic menu background | 1672 x 941 |
| `assets/logo.png` | Transparent Aetheln Online title lockup | 1574 x 576 |
| `assets/button-normal.png` | Default primary menu button | 1759 x 299 |
| `assets/button-hover.png` | Pointer-hover state | 1759 x 300 |
| `assets/button-focused.png` | Keyboard/controller focus state | 1758 x 299 |
| `assets/button-disabled.png` | Unavailable state | 1759 x 299 |
| `assets/panel-large.png` | Large smoky-glass modal or settings panel | 1307 x 988 |
| `assets/selection-card-frame.png` | Transparent portrait/roster frame | 960 x 1460 |
| `assets/hud-status-frame.png` | Empty health, mana, or progression bar frame | 2104 x 344 |
| `assets/slot-frame.png` | Ability, equipment, and inventory slot frame | 984 x 1069 |
| `assets/slider-cyan-65.png` | Example settings slider at 65 percent | 1854 x 211 |
| `assets/toggle-off.png` | Settings toggle, inactive state | 1290 x 445 |
| `assets/toggle-on.png` | Settings toggle, active state | 1308 x 477 |
| `assets/loading-indicator.png` | Circular ember loading indicator | 1142 x 1132 |
| `assets/kell-female-selection.png` | Transparent Kell character-selection render | 443 x 1458 |
| `assets/character-selection-stage.png` | Clean character-selection environment | 1672 x 941 |
| `assets/icon-basic-attack.png` | Generic basic attack action icon | 973 x 980 |
| `assets/icon-dodge.png` | Generic evasive movement icon | 947 x 964 |
| `assets/icon-block.png` | Generic block or guard icon | 841 x 1148 |
| `assets/icon-health-consumable.png` | Generic health consumable icon | 585 x 1071 |
| `assets/icon-buff.png` | Generic positive-status icon | 585 x 1101 |
| `assets/icon-debuff.png` | Generic negative-status icon | 700 x 1115 |
| `assets/reticle-free-aim.png` | Neutral free-aim reticle | 628 x 637 |
| `assets/marker-interact.png` | Neutral world-interaction marker | 487 x 855 |
| `assets/marker-objective.png` | Neutral objective marker | 579 x 1213 |

Button text is intentionally not baked into the artwork. Render labels in the
UI so localization, accessibility scaling, and state changes remain possible.
Use the focused asset for controller/keyboard focus. A pressed state can use the
focused texture with a 98% content scale and a short luminance reduction.

## Source and rebuild files

- `chroma-sources/` retains the full-resolution generated source images.
- `remove-chroma.ps1` removes the generated green backdrop, despills edges, and
  crops each image to its painted bounds.
- `build-preview.ps1` assembles the menu preview from the separate PNG assets.
- `build-screen-previews.ps1` assembles the extended settings, accessibility,
  character-selection, dialog, loading, HUD, and inventory previews.
- `build-gameplay-assets-preview.ps1` assembles the gameplay icon and marker
  review sheet.

## Screen previews

- `previews/main-menu-v2-preview.png`
- `previews/settings-v2-preview.png`
- `previews/accessibility-v2-preview.png`
- `previews/character-selection-v2-preview.png`
- `previews/dialog-tooltip-v2-preview.png`
- `previews/loading-v2-preview.png`
- `previews/hud-v2-preview.png`
- `previews/inventory-v2-preview.png`
- `previews/gameplay-icons-v2-preview.png`

These are composition targets made from separate assets, not flattened
replacements for runtime widgets. Labels, values, fills, item icons, ability
icons, and character data should remain live.

The assets use straight-alpha PNG transparency. Before final Unreal integration,
set UI textures to an interface-appropriate compression profile, disable mipmaps
where the target resolution does not require them, and verify nine-slice margins
inside the target CommonUI widget rather than guessing margins from this preview.

## Art direction lock

- Painterly stylized dark fantasy, not flat vector UI.
- Charcoal smoked glass and worn blackened iron.
- Silver-grey edges with minimal ornament.
- Ember orange only for focus, selection, and urgent emphasis.
- No faction symbolism or final faction names in global menu chrome.
- Race, sex, appearance, class, faction, level, and seasonal rank remain
separate presentation fields. Character appearance never implies combat
statistics.

The gameplay symbols are a canon-safe starter set. They establish semantic and
visual direction only; final class abilities, item quality tiers, Doctrine
skills, and faction symbols remain intentionally TBD.
