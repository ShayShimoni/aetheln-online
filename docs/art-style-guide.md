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

The user also selected the updated male and female Aurin below on 2026-10-10.
They establish the current Human race visual baseline in
[Playable Peoples](playable-peoples.md#aurin). Preserve the cleaner facial
planes and controlled skin, hair, and cloth detail when deriving new Aurin
views. Their approval changes visual references, not Aurin biology or story.

## Visual references

Open the selected Aetheln-generated images for the subject before generating.
The approved Aurin and Kell pairs are examples of the rendering finish and
current race designs. Vesh redesign status is identified separately below.

### Aurin

| Male Aurin | Female Aurin |
| --- | --- |
| ![Approved male Aurin](art-style-references/aurin-male-approved-2026-10-10.png) | ![Approved female Aurin](art-style-references/aurin-female-approved-2026-10-10.png) |
| [Male v06](art-style-references/aurin-male-approved-2026-10-10.png) and [exact prompt](art-style-references/aurin-male-approved-2026-10-10-prompt.txt) | [Female v13](art-style-references/aurin-female-approved-2026-10-10.png) and [exact prompt](art-style-references/aurin-female-approved-2026-10-10-prompt.txt) |

The [Aurin approval record](art-style-references/aurin-approved-design-2026-10-10.md)
records byte-preserved copies from the 2026-10-10 Human exploration, exact
prompts, generation provenance, and the user's selection. Open this pair for
future Aurin body, clothing, armor, or character views. Use coherent sculpted
forms, subtle skin detail, simplified mature facial planes, and clean hair and
cloth shading. Preserve the selected design when making additional views.
These example faces, hairstyles, and body builds do not constrain the broader
canonical Human customization range.

### Kell

| Male Kell | Female Kell |
| --- | --- |
| ![Approved male Kell rendering reference](art-style-references/57-quartz-balanced-hands-feet.png) | ![Approved female Kell rendering reference](art-style-references/59-quartz-amethyst-female-refined.png) |
| [Image 57](art-style-references/57-quartz-balanced-hands-feet.png) and [saved prompt](art-style-references/57-quartz-balanced-hands-feet-prompt.txt) | [Image 59](art-style-references/59-quartz-amethyst-female-refined.png) and [saved prompt](art-style-references/59-quartz-amethyst-female-refined-prompt.txt) |

The Kell pair in `docs/art-style-references/` contains the selected results
from the built-in image workflow. The two approved PNGs and their saved
prompts accompany this guide; images use Git LFS. Earlier explorations and
full generation lineage are retained outside the repository. Use the selected
pair as the input for future Kell views.

These are generated raster concepts with a 3D appearance. They provide a visual
target for later modeling; they do not contain meshes, topology, rigs, or
validated equipment fits.

For a different character or asset, use these images as **rendering references
only**. Transfer the surface quality, lighting, clarity, and material depth.
Keep the new subject's own anatomy, proportions, palette, materials, clothing,
and identity. Ivory quartz, amethyst, horns, claws, and glowing eyes belong to
the selected Kell design and are not requirements for every asset.

### Vesh redesign

| Selected male Vesh | Current female Vesh candidate |
| --- | --- |
| ![Selected male Vesh](art-style-references/vesh-male-selected-2026-10-10.png) | ![Current female Vesh candidate](art-style-references/vesh-female-current-2026-10-10.png) |

The [character results record](art-style-references/character-results-2026-10-10.md)
identifies the saved prompts and selection status. The male uses the selected
black coat, white patterns and golden eyes. The female applies that palette to
the current redesigned body; final female approval remains pending. The revised
Vesh origins, spirit relationship, culture, and anatomy are now canonical in
[Playable Peoples](playable-peoples.md#vesh), with connected stories in the
character and settlement documents. Final female visual approval and production
readiness remain separate from that written lore revision.

## Reference and storage boundary

Keep pasted external user reference images outside the repository. Repository
art references contain selected Aetheln-generated results only, with their
selection status recorded. Do not embed external reference copies, branded
filenames, or links in repository art records.

Save candidates, exact submitted prompts and full input lineage outside the
Git worktree, in the generator's output directory or a user-approved external
working folder. On selection, copy only the chosen output and a suitable
standalone or current-result prompt into `docs/art-style-references/`. Retain
an exact prompt in the repository only when it contains no prohibited external
references. If a new reusable prompt is written from the selected result,
label it as rewritten; keep the genuine submitted prompt and lineage outside
the repository. This storage boundary does not establish rights clearance or
change how the images were created.

## Rendering rules

| Element | Target |
| --- | --- |
| Shape | Coherent sculpted volumes, strong silhouettes, clear overlapping forms, clean transitions, and intentional edge bevels. Curves and sharper planes should both read as solid geometry. |
| Surface detail | Broad forms carry the design. Add selective veins, grain, seams, wear, or small facets where the material needs them; keep detail density controlled. Faces use clean sculpted planes with restrained wrinkles and fine texture, as in the approved Aurin pair. |
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
   outside the Git worktree, following the reference and storage boundary
   above. Retain source reference paths, intended change, review and approval
   status in that external record. Copy selected results into the repository
   only after selection; a generated candidate is not automatically approved.

Keep image approval separate from mesh production. Turnarounds, topology,
rigging, equipment fitting, material setup, and in-engine validation follow
when the asset reaches those steps.
