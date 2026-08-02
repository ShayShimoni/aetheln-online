# Aetheln Online Future Visuals Plan

## Purpose

This non-canonical document is the handoff point for future visual-generation
sessions. Continue the visual language already established in this folder. Do
not restart the art direction or treat a new session as permission to redesign
it.

Repository inclusion preserves review material; it does not make any concept
canonical, production-ready, or approved for Unreal `Content/` or runtime use.
Consult `package-manifest.json` and `asset-provenance.md` before modifying or
deriving an imported asset.

The next visual pass should make the existing direction useful for the
two-player action-combat prototype. It should concentrate on combat readability,
the prototype arena, the first enemy, and missing gameplay UI states.

## Review Before Generating

Open these references first:

1. `README.md`
2. `generation-prompts.md`
3. `01-main-menu-concept.png`
4. `02-playable-peoples-lineup.png`
5. `03-aurin-bulwark-equipment.png`
6. `04-branmark-settlement.png`
7. `05-glasswake-reach.png`
8. `06-character-selection-concept.png`
9. `07-ui-style-system.png`
10. `ui-production-v2/README.md`
11. Every image in `ui-production-v2/previews/`

Also read the current canonical repository documents before generating
characters, enemies, combat behavior, equipment, locations, factions, or
progression:

- `../docs/documentation-index.md`
- `../docs/game-design-bible.md`
- The relevant specialized product document
- `../docs/next-steps-mmorpg-prototype.md`
- The relevant canonical technical document when the visual represents an
  implemented system

GitHub Issues remain the source of truth for current delivery status and
approved prototype decisions.

## Locked Visual Direction

All future visuals must look as though they belong to the package already in
this folder:

- Painterly stylized dark fantasy with grounded anatomy and readable
  silhouettes.
- Ancient monumental spaces visibly scarred by the Duskbreak.
- Charcoal smoked glass, worn blackened iron, cold silver edges, and restrained
  hairline ornament in the interface.
- Ember orange for focus, selection, urgency, and strong combat confirmation.
- Spectral cyan for secondary information and restrained supernatural effects.
- Darkness may establish atmosphere but must not hide characters, navigation,
  combat telegraphs, or interface focus.
- No flat-vector redesign, glossy science-fiction interface, ornamental excess,
  photorealistic style change, or unrelated fantasy aesthetic.

Use the existing V2 assets whenever a composition needs buttons, panels, slots,
status frames, loading indicators, reticles, or world markers. Generate a new
asset only when the required function is not already covered.

## Visual and Canonical Guardrails

Canonical repository documents continue to govern gameplay and implementation.
The character-presentation notes below record the owner-approved concept
direction for future visual studies without changing combat rules.

- The prototype uses pure free aim. Do not depict target lock, tab targeting,
  client-selected targets, or attacks that visually imply guaranteed tracking.
- Combat must remain readable enough for aim, timing, positioning, blocking,
  dodging, and interruption to matter.
- Aurin are fully human and have no innate supernatural anatomy.
- Kell concepts should read as large, powerfully built, masculine, and visibly
  non-human while remaining living organic-mineral people rather than stone
  golems. Presentation must not change authoritative combat-body rules.
- Vesh concepts use conventional visible hair with no required hood, a matte
  white angular full-face mask, only luminous eyes visible, and paired
  non-grasping back-veils. No face is visible through or around the mask.
- Male and female variants use identical combat rules and authoritative body
  standards. Appearance must never imply different statistics, hitboxes,
  reach, timing, or loot.
- Do not invent final faction names, colors, heraldry, capitals, level caps,
  tuning values, ability kits, item tiers, Doctrine skills, or unresolved
  progression rules.
- Before the approved faction stage, characters remain
  `FACTION UNASSIGNED`; Doctrine is unavailable.
- Do not depict equipped items dropping on PvP death.

## Current Review

The current package successfully establishes:

- Main-menu identity and environment mood.
- Reusable panels, buttons, slots, toggles, sliders, and loading treatment.
- Character-selection composition.
- Starter symbols for basic attack, dodge, block, health consumables, positive
  and negative status, free aim, interaction, and objectives.

The next pass should address these gaps:

- The HUD has not been tested over representative gameplay imagery.
- The free-aim reticle may disappear against bright or effect-heavy scenes.
- Enemy health, cast and interrupt information, hit confirmation, cooldown
  states, damage feedback, interaction prompts, death, and respawn presentation
  are not yet defined.
- Thin ornament and small text need validation at 1920 x 1080.
- Controller glyphs, keyboard bindings, text scaling, high-contrast focus, and
  color-vision checks need representative visual states.
- The current Kell selection render should be corrected in a later anatomy pass
  so the character reads as living organic-mineral rather than uniformly stone.

## Next Generation Batch

Complete the following in order. Review each result before continuing so errors
do not propagate into later images.

### 1. Prototype Combat Scene

Create a third-person gameplay composition containing:

- One player character.
- One approved prototype enemy.
- One small, controlled combat arena.
- Clear foreground, midground, and enemy separation.
- A camera angle appropriate for pure free-aim action combat.
- Space for the established HUD without hiding important gameplay.
- Readable attack, dodge, block, and interruption distances.

This is a gameplay-readability reference, not final environment production art.
Do not turn the prototype arena into a final faction location or open-world
territory.

Do not generate this image until the first prototype class, equipment silhouette,
enemy role, and arena requirements are discoverable from canonical documents or
approved issue content. Preserve unknown decisions as TBD.

### 2. Combat HUD Readability Variants

Composite the established UI language over three representative gameplay
conditions:

1. Dark, low-contrast environment.
2. Bright environment or bright sky.
3. Effect-heavy combat moment with ember and spectral energy.

Include only approved prototype information. Expected functional areas are:

- Player health and approved combat resource.
- Enemy health.
- Free-aim reticle.
- Basic attack chain and approved active abilities.
- Dodge and block state.
- Cooldowns.
- Positive and negative status.
- Interaction or objective marker when applicable.

Create a stronger reticle variant if the current reticle fails any background
condition. It must remain neutral and must not imply target lock.

### 3. Combat Feedback State Sheet

Create a review sheet for:

- Valid hit confirmation.
- Blocked hit.
- Successful dodge or invulnerability feedback, only if the approved mechanics
  support it.
- Interrupt opportunity and successful interrupt.
- Ability unavailable and cooldown state.
- Low health.
- Positive and negative status.
- Invalid interaction or rejected action.
- Death, respawn timer, and respawn-ready state.

Essential states must differ by shape, motion treatment, luminance, or text as
well as color.

### 4. Prototype Enemy Concept

Create the enemy only after its combat role, attacks, scale, and silhouette
requirements are approved. Produce:

- Front, side, and rear views.
- Neutral pose and one readable attack pose.
- Clearly visible attack origin and dangerous body or weapon regions.
- Material and color notes consistent with the existing world.
- A silhouette that remains readable at gameplay camera distance.

Do not invent enemy lore, faction allegiance, loot, or final tuning.

### 5. Kell Anatomy Correction Sheet

Create a focused Kell reference that preserves the established identity while
clarifying:

- Living skin over most of the body.
- Mineral crown and selected mineral facial planes.
- Mineral concentration at the mantle, upper torso, and joints.
- A living, flexible body rather than a stone-golem construction.
- Male and female presentation under identical combat-body rules.

Treat this as a correction and production reference, not a redesign of the
people.

### 6. Accessibility and Input State Sheet

Show representative:

- Keyboard and mouse prompts.
- Controller prompts.
- Normal, hover, focused, pressed, disabled, and error states.
- Default and enlarged text.
- High-contrast focus.
- Reduced-motion alternative for animated emphasis.
- Color-vision-safe positive, negative, objective, and warning signals.

Validate the result at 1920 x 1080 rather than only at source resolution.

## Decisions Required Before Specific Assets

Do not invent the following merely to complete an image:

- The first prototype class.
- The first three active abilities.
- The exact attack-chain actions and weapon, if not yet approved.
- The prototype enemy and its attacks.
- Final resource names or values.
- Final item-quality colors and equipment tiers.
- Final faction, Doctrine, Skein, or heraldic visuals.

If these remain unresolved, generate neutral layout and readability studies or
pause that specific asset until a canonical decision exists.

## Output Structure

Continue using the existing `visuals` folder. Create a new production pass
folder only when generation begins:

```text
ui-production-v3/
  README.md
  prompts/
  source/
  assets/
  previews/
```

Use descriptive, ordered filenames:

```text
01-prototype-combat-dark.png
02-prototype-combat-bright.png
03-prototype-combat-effects.png
04-combat-feedback-states.png
05-prototype-enemy-sheet.png
06-kell-anatomy-correction.png
07-accessibility-input-states.png
```

Keep full-resolution generated sources separate from cropped or
transparency-processed runtime candidates. Keep review composites separate from
individual runtime assets. Do not bake labels, values, key bindings, cooldown
numbers, or character data into runtime artwork.

## Per-Asset Workflow

For every new asset:

1. Identify the canonical gameplay or UI purpose.
2. Resolve required approved details from repository documents and Issues.
3. Select the exact existing visual references.
4. Write and save the generation prompt.
5. Generate one focused concept or source asset.
6. Review anatomy, canon, semantics, readability, and visual continuity.
7. Correct the source before deriving variants.
8. Separate runtime artwork from live text and data.
9. Test the result at 1920 x 1080 over representative backgrounds.
10. Record the asset purpose, prompt, source, dimensions, processing, known
    limitations, and approval status in the V3 README.

## Acceptance Checklist

A visual is ready for implementation review only when:

- It visibly belongs to the existing Aetheln Online package.
- It follows all relevant canonical product constraints.
- It does not resolve a TBD decision without approval.
- Gameplay information remains readable on representative backgrounds.
- Meaning is not communicated by color alone.
- Essential text and focus remain legible at 1920 x 1080.
- UI artwork can support localization, input changes, and text scaling.
- The asset is separated from live labels, values, cooldowns, and character
  data where appropriate.
- Source and processed versions are preserved.
- The file has a documented purpose and known limitations.

## Resume Instruction for a Future Session

Start by reading this file and the references under **Review Before
Generating**. Inspect the current V2 previews visually. Check the repository and
relevant GitHub Issues for newly approved prototype decisions. Then continue
from the first incomplete item in **Next Generation Batch**.

Do not generate a large batch without reviewing each result. Do not replace the
established direction unless the user explicitly requests a redesign.
