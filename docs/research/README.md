# Historical Planning and Research

## Archive Status

This directory preserves project inputs and planning snapshots that predate or
sit outside the canonical documentation set. Its contents are
**non-authoritative**. Use the parent
[Documentation Index](../documentation-index.md) to find the current product,
technical, and delivery sources.

The files were organized under
[Issue #65](https://github.com/ShayShimoni/aetheln-online/issues/65). The issue
owns the archive cleanup, not the original research conclusions.

## Contents and Relationships

| Artifact | Historical relationship |
| --- | --- |
| [MMORPG feasibility research](mmorpg-feasibility.md) | Feasibility and tooling background considered before the canonical direction recorded by Issues #1 and #59; neither ticket names it as a deliverable. |
| [PvP MMORPG lore architecture](pvp-mmorpg-lore-architecture.md) | Historical comparison and superseded starter lore related to the product direction in Issue #1. Remaining faction-world decisions belong to Issue #54. |
| [Unreal Engine MMO-lite build planning](unreal-engine-mmo-lite-build-planning.md) | Historical implementation guidance superseded where necessary by the canonical architecture from Issue #59 and the current roadmap. |
| [Unreal Engine MMO-lite zero-budget plan](unreal-engine-mmo-lite-zero-budget-plan.md) | External planning research that could not inspect the project sources; it is not an implementation decision for Issues #5, #13, or #15. |
| [MMORPG development roadmap image](mmorpg-development-roadmap.md) | Generic historical roadmap illustration. The repository README defines the current delivery sequence. |
| [Phase 0 environment setup](phase-0-environment-setup.md) | Historical environment snapshot. Current project bootstrap and build evidence belong to Issues #13 and #15. |

## Routing Stale Recommendations

Archive statements remain historical even when they name a current product or
tool. Route them as follows instead of treating them as implementation
decisions:

- Iris, Replication Graph, and generic push-model recommendations route to
  candidate TC-001 in [Architecture Decisions](../architecture-decisions.md)
  and require equivalent packaged evidence owned by Issues #2 and #45.
- Launcher installation or binaries route to the
  [pinned source setup](../unreal-project-setup.md) and Issue #15. Launcher
  binaries are not the canonical packaged Linux dedicated-server path.
- Hardware baselines, player-count estimates, and capacity claims route to
  [Performance, Quality, and Delivery](../performance-quality-and-delivery.md)
  and Issue #45. Historical estimates are neither measured targets nor
  supported capacity.
- Backend, identity, data, messaging, hosting, orchestration, or anti-cheat
  recommendations route to the candidate registry and their owning issues.
  Historical examples do not select a vendor.

The maintained character and settlement codices remain in `output/pdf/` and
are not duplicated here.
