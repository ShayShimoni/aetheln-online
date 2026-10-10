---
name: aetheln-imagegen
description: Generate or edit Aetheln character and asset imagery with the approved stylized 3D finish, reference fidelity, versioned prompts, and visual review. Use for raster art generation and polish; exclude lore-only and code-only changes.
---

# Aetheln Image Generation

Create consistent polished stylized fantasy images that feel like solid,
carefully modeled 3D assets. Apply this workflow to characters, creatures,
armor, clothing, weapons, props, buildings, and environment art.

## Authority and reference selection

- Read the current [Art Style and Generation Guide](../../../docs/art-style-guide.md).
  It remains the rendering source of truth; use its current prompt blocks and
  presentation defaults rather than maintaining a second copy here.
- For race imagery, read the relevant section of
  [Playable Peoples](../../../docs/playable-peoples.md) and open its approved
  visual baseline. For other subjects, locate their approved design reference
  and relevant canonical requirements.
- Open the actual subject image and approved rendering references before
  prompting. Do not select a baseline merely because it has the highest version
  number. Consult selection or approval records.
- During a user-directed redesign, use the most recently selected exploration
  and the user's latest corrections. Record its exploratory status separately
  from written canon. Rendering work alone does not authorize a lore revision.
- Give every input an explicit role: edit target, subject identity, rendering
  finish, or a specific borrowed feature. A style reference supplies finish,
  lighting and material quality, not another race's anatomy or palette.
- Keep external user reference images outside the repository. Repository art
  references use selected Aetheln-generated results only; do not embed external
  reference copies, branded filenames, or links in repository art records.

## Prepare the generation

1. Identify the requested change, count, and design invariants. For an edit,
   preserve unaffected anatomy, proportions, face, patterns, materials,
   equipment, pose and framing. Apply only the user's requested changes.
2. Build the prompt from the guide's reusable generation or edit block. Name
   references by input index and explain their roles. State the subject design
   separately from the rendering treatment.
3. Describe the 3D treatment concretely: continuous sculpted volumes, clean
   contours, broad physical light gradients, distinct material responses,
   readable occlusion and grounded contact shadows. The words "3D render"
   alone are insufficient to control the finish.
4. Keep surface detail selective. For fur or hair, use broad clean clumps and
   restrained strand detail; preserve meaningful silhouettes and color patterns.
   For skin, stone, wood and metal, preserve material character without dense
   pores, microfacets, cracks, grain or scratches covering every surface.
   Incidental texture noise is not a design invariant.
5. Save the exact submitted prompt under a new versioned filename outside the
   Git worktree before calling the tool. Use the generator's output directory
   or a user-approved external working folder. Save each variant's prompt
   separately and preserve previous images, prompts, and full input lineage
   there.

Use the available built-in image generation tool by default. Inspect local
edit targets with the image viewer before editing. Follow the available
`imagegen` skill for tool mechanics when applicable. Issue one generation call
per requested variant; default to one focused result when no count is given.
Use studio backgrounds unless the user or asset presentation calls for another
treatment. Request transparency only when required. Do not switch to a CLI/API
fallback without the user's explicit request or confirmation.

## Review before continuing

Inspect the returned image beside the selected subject and style references:

- **3D presence:** broad shading describes tangible volumes; highlights and
  shadows follow geometry instead of painted streaks or outlined strands.
- **Detail control:** primary forms remain readable at full-asset viewing size.
  Dense fur layers, tiny facets or repeated fine highlights do not dominate.
- **Materials:** surfaces have appropriate roughness and depth; they remain
  distinct without uniform plastic gloss or a flat unshaded clay appearance.
- **Design fidelity:** face, anatomy, silhouette, pattern placement and palette
  match the assigned subject reference except for requested changes.
- **Presentation:** the complete requested asset is visible, hands and feet are
  readable where relevant, and color, glow and lighting do not obscure it.

If the image drifts toward painting, name the visible cause and make a focused
correction to surface detail or shading. Do not repeat the same generic style
adjectives or silently redesign anatomy. Inspect the correction again before
using it as an input for further views. Report remaining mismatches candidly.

## Save and hand off

- Keep candidates and revision records outside the Git worktree. Record the
  exact prompt, input paths and roles, intended change, generation method,
  returned source path, visual review and selection status there.
- When the user selects a result, copy only that output and its suitable
  standalone or current-result prompt into `docs/art-style-references/`.
  Verify the image copy against the generated source with SHA-256 and record
  its selection status. Keep superseded candidates outside the repository.
- Preserve submitted prompts exactly in the external record. An exact prompt
  may enter the repository only if it contains no prohibited external
  references. Otherwise provide a clearly labeled rewritten reusable prompt
  based on the selected result; do not label it exact or erase the original
  lineage. Storage cleanup does not establish rights clearance.
- Present the result with the saved image and prompt paths. A generated image
  remains a candidate until the user selects it; selection does not prove mesh,
  topology, rigging, equipment fit or in-engine readiness.
- Keep this workflow within image generation scope. Canonical design updates,
  tracker changes and Git publication follow their own authorized workflows.
