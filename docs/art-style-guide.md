# Aetheln Online Art Style and Generation Guide

## Approved direction

Recorded on 2026-10-10 at the user's request for consistent future characters
and assets. The approved look is **polished stylized fantasy rendered as a
finished 3D sculpt**: solid volumes, clean surfaces, readable shapes, convincing
materials, soft lighting, and restrained color. This is the default rendering
direction for future asset generation unless the user requests a different
treatment.

This guide supersedes the painterly rendering instructions in the older
[visual package](../visuals/README.md),
[future visuals plan](../visuals/FUTURE-VISUALS-PLAN.md), and
[generation prompts](../visuals/generation-prompts.md). Their historical images
remain useful for subject matter, composition, and world mood. Use this guide
for the finish of newly generated characters and assets.

The user selected the male and female Kell below as the new race baseline.
Their revised anatomy, origin, and culture are canonical in
[Playable Peoples](playable-peoples.md#kell), with story connections in
[Characters and Factions](characters-and-factions.md) and
[World and Settlements](world-and-settlements.md). Earlier visual-package
anatomy notes and review judgments describe the superseded Kell direction.
Gameplay rules and other races' identities remain governed by the
[canonical design documents](documentation-index.md).

## Visual references

Open these images before generating. They are the primary examples of the
approved rendering finish and the selected Kell designs.

| Male Kell | Female Kell |
| --- | --- |
| ![Approved male Kell rendering reference](art-style-references/57-quartz-balanced-hands-feet.png) | ![Approved female Kell rendering reference](art-style-references/59-quartz-amethyst-female-refined.png) |
| [Image 57](art-style-references/57-quartz-balanced-hands-feet.png) and [saved prompt](art-style-references/57-quartz-balanced-hands-feet-prompt.txt) | [Image 59](art-style-references/59-quartz-amethyst-female-refined.png) and [saved prompt](art-style-references/59-quartz-amethyst-female-refined-prompt.txt) |

The reference files in `docs/art-style-references/` are preserved copies from
`visuals/race-explorations-2026-10-10/`, generated through the built-in image
workflow during this design session. The two approved PNGs and three exact
prompt records accompany this guide in Git; images use Git LFS. Older edit
inputs named in the prompts are historical lineage, not required inputs for
using these approved references. The complete exploration stays in its
original working folder.

These are generated raster concepts with a 3D appearance. They provide a visual
target for later modeling; they do not contain meshes, topology, rigs, or
validated equipment fits.

For a different character or asset, use these images as **rendering references
only**. Transfer the surface quality, lighting, clarity, and material depth.
Keep the new subject's own anatomy, proportions, palette, materials, clothing,
and identity. Ivory quartz, amethyst, horns, claws, and glowing eyes belong to
the selected Kell design and are not requirements for every asset.

The rendering change originated with the user's supplied `image_0.png` and
`image_1.png` references. The saved
[polish-pass prompt](art-style-references/47-quartz-polished-3d-style-prompt.txt)
records their roles. Later anatomy edits were separate decisions. Use the
approved pair above for the current visual target, rather than reverting to an
earlier exploration.

## Rendering rules

| Element | Target |
| --- | --- |
| Shape | Coherent sculpted volumes, strong silhouettes, clear overlapping forms, clean transitions, and intentional edge bevels. Curves and sharper planes should both read as solid geometry. |
| Surface detail | Broad forms carry the design. Add selective veins, grain, seams, wear, or small facets where the material needs them; keep detail density controlled. |
| Materials | Distinct, physically convincing responses: matte skin and cloth, appropriately reflective metal, fibrous wood, and mineral depth where relevant. Match roughness and translucency to each material. |
| Lighting | Soft directional key light, gentle fill, clear shading between overlapping forms, broad controlled highlights, and natural contact shadows. Keep enough light to inspect the asset. |
| Color | A restrained, coordinated palette with intentional light/dark material contrast. Recessed or secondary materials remain distinguishable without turning every surface into a different saturated color. |
| Glow | Localized emission only where the subject calls for it. Preserve the source shape, internal material depth, and surrounding shading; keep bloom from washing out the model. |
| Finish | A carefully modeled, shaded 3D fantasy asset shown in a clean render. Stylized proportions and shapes with convincing physical presence. |

Avoid painterly brushwork, illustrated highlights, sketch lines, canvas grain,
muddy shading, noisy microfacets, dense crack networks, gritty oversharpening,
and uniform plastic gloss. Do not substitute a photographic human or a flat
unshaded clay model for the fantasy sculpt finish.

For the selected Kell specifically, preserve the pale ivory outer quartz and
the deeper smoky amethyst interior. Their contrast should reveal the layered
body construction. Violet eye glow and restrained crystal light stay legible
without making the whole body bright purple.

## Presentation by asset type

These defaults extend the approved character treatment to other asset types.
They guide generation; individual new assets still need visual review.

| Asset | Default presentation |
| --- | --- |
| Character or creature anatomy | One complete subject in a neutral frontal A-pose, arms separated from the torso, hands readable, feet grounded. Use a near-orthographic view with little perspective distortion and a warm light-gray studio background. Keep the whole silhouette in frame and in focus. Adapt the pose to the creature's anatomy when necessary. |
| Armor and clothing | Show the complete set on its intended body with clear material separation and believable fit at the neck, shoulders, hands, and feet. Preserve the character beneath it. Let legendary designs use stronger shapes and controlled glow without obscuring construction. |
| Weapons and props | Show the complete object clearly against a neutral studio background, with a useful front or three-quarter view, readable edges, joints, grips, and materials. |
| Buildings and environment pieces | Carry over the sculpted forms, material clarity, and controlled detail at the appropriate scale. Use a neutral asset view or a clear contextual view according to the request. Atmosphere should preserve structure and silhouette readability. |
| UI imagery and item renders | Apply this finish to depicted objects and characters. Preserve the established interface layout, readable symbols, live text, and state colors. The rendering preference alone does not redesign controls or information hierarchy. |

Use subject-appropriate proportions. The approved male Kell is moderately
muscular; the female is less bulky with an athletic feminine silhouette. These
are reference-specific choices, not a common body template for every race.
Keep hands and feet balanced with the body and avoid exaggerated bulk unless
requested. Character appearance never changes authoritative combat rules.

## Reusable generation prompt

Replace the bracketed fields and attach the references with their roles made
explicit. Supply the subject description separately so the style block can be
reused across asset types.

```text
Create [SUBJECT AND APPROVED DESIGN] as a polished stylized fantasy 3D sculpt
render, matching the attached rendering reference's finish.

Reference roles: [DESIGN REFERENCE] defines the subject's identity, anatomy,
proportions, materials, palette, and equipment. [STYLE REFERENCE] defines only
rendering quality, surface finish, lighting, and material clarity. Transfer only
the traits explicitly assigned to each reference.

Build coherent solid volumes with clean contours, refined bevels, smooth form
transitions, and readable overlapping parts. Use physically convincing
material shading suited to [SUBJECT MATERIALS], controlled broad highlights,
soft directional light and fill, subtle occlusion, and grounded contact
shadows. Preserve material differences and a restrained coordinated palette.
Keep surface detail selective. Use localized glow only if specified in the
subject design, with dark material depth still visible around it.

Presentation: [POSE OR OBJECT VIEW], [BACKGROUND], complete subject in frame,
little perspective distortion, and clear focus across the asset. For character
anatomy use a neutral frontal A-pose on a warm light-gray studio background.

No painterly brushwork, sketch lines, canvas grain, muddy shading, noisy
microdetail, dense crack networks, gritty sharpening, excessive bloom, or
uniform plastic gloss. No borrowed anatomy or palette from the style reference.
No added text, watermark, props, clothing, or accessories unless requested.
```

## Reusable edit prompt

```text
Edit the attached approved image. Change only [REQUESTED CHANGE].

Preserve the subject's identity, all unaffected anatomy and proportions,
materials, palette, pose, framing, background, and lighting. Preserve the
polished stylized 3D sculpt finish: coherent solid volumes, clean surfaces,
refined bevels, distinct material responses, soft physical shading, restrained
color and glow, and grounded shadows. Keep all unchanged details aligned with
the approved image. Do not drift toward painted illustration or redesign
unrelated parts. Return [REQUESTED NUMBER OF IMAGES OR VIEWS].
```

## Generation and review workflow

1. Read this guide and the subject's current design requirements. Open the
   latest approved subject image and the style references; do not rely on a
   text description alone when an image is available.
2. State each reference's role: subject identity, rendering style, or a specific
   borrowed feature explicitly requested by the user. Keep those roles in the
   saved prompt.
3. For an edit, start from the latest approved image and name both the requested
   change and what must stay consistent. Keep refinements modest when the user
   asks for a small adjustment.
4. Generate the requested count; default to one focused result. Compare it
   against the approved references before deriving more views or variations.
5. Check the result: does it read as a solid 3D sculpt; are materials distinct;
   are color and glow controlled; is the subject's silhouette preserved; are
   anatomy and fit coherent; is the entire asset visible and readable?
6. Correct style drift before treating a new output as the reference for the
   next edit. Additional views must depict the same design, not independently
   reinvent its hidden parts.
7. Save each output and exact prompt under a new descriptive versioned filename
   in the working visual folder. Retain the source reference paths, intended
   change, and approval status. Preserve earlier images; a generated candidate
   becomes the approved reference only when the user selects it.

Keep image approval separate from mesh production. Turnarounds, topology,
rigging, equipment fitting, material setup, and in-engine validation follow
when the asset reaches those steps.
