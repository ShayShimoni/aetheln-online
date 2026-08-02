# Aetheln Online UI Production Kit

This kit converts the approved stylized-dark-fantasy menu concepts into
editable source assets and implementation specifications.

## Contents

- `backgrounds/` - clean 16:9 painted plates without UI or text.
- `assets/` - editable SVG logo and reusable control sources.
- `screens/` - deterministic 1920x1080 screen-layout sources.
- `ui-tokens.json` - colors, type scale, spacing, radii, borders, animation,
  and safe-zone values.
- `font-recommendations.md` - open-font choices and licensing references.
- `screen-flow.md` - opening-menu navigation and required states.
- `unreal-commonui-spec.md` - widget hierarchy, input behavior, and import
  guidance.

## Source Status

The SVG files are design sources. Keep them editable until the Unreal project
defines its final texture-density and import rules. Export raster UI textures
from these sources only after the target resolution, DPI policy, compression,
and nine-slice margins are verified in Unreal Engine.

The two PNG backgrounds were produced using the built-in image-generation
workflow. Their final briefs were:

1. A clean Glasswake Reach main-menu plate with a dark, low-detail left zone
   and the wounded Waking Star on the right.
2. An empty safe-hub character-selection terrace with a central circular stage
   and low-detail side zones.

## Accessibility Baseline

- All essential focus states combine color, border thickness, corner markers,
  and luminance.
- Minimum body text target: 24 px at 1920x1080.
- Minimum primary control height target: 64 px.
- Minimum contrast target: WCAG 2.2 AA as a design check, followed by testing
  on the actual game display pipeline.
- Motion is decorative only and must support a reduced-motion setting.
- Color never communicates faction, hostility, selection, or error by itself.

## Canonical Limits

- Faction names, colors, and heraldry remain working or unresolved.
- Pre-2.0 characters display `FACTION UNASSIGNED`; Doctrine is not shown.
- Race and sex never imply different statistics, reach, collision, or loot.

