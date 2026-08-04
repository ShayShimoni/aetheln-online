# Aetheln Online Documentation Index

## Canonical Product and Design Documents

These documents govern player-facing behavior, lore, progression, and world
rules. Read the Bible first, then the specialized document for the system.

1. [Game Design Bible](game-design-bible.md)
2. [Playable Peoples](playable-peoples.md)
3. [Characters and Factions](characters-and-factions.md)
4. [World, Settlements, and Open-World PvP](world-and-settlements.md)
5. [Progression, Loot, and Skein Weaving](progression-loot-and-skein.md)

## Canonical Technical Documents

These documents govern implementation boundaries. They must implement the
canonical product rules rather than redefine them.

1. [Technical Architecture](technical-architecture.md)
2. [Combat and Networking Architecture](combat-and-networking-architecture.md)
3. [World Runtime and Building](world-runtime-and-building.md)
4. [Progression and Persistence Architecture](progression-and-persistence-architecture.md)
5. [Security and Operations](security-and-operations.md)
6. [Performance, Quality, and Delivery](performance-quality-and-delivery.md)
7. [Architecture Decisions](architecture-decisions.md)

## Stage Contracts and Traceability

After reading the applicable canonical product and technical documents, read
these documents in order:

1. [Prototype and 1.0 Scope Ledger](prototype-and-1.0-scope-ledger.md) records
   the normative Issue #71 inventory and requirement dispositions.
2. [Prototype Game Brief](GameBrief.md) summarizes the pre-1.0 prototype stage
   contract.
3. [1.0 Cooperative Vertical-Slice Brief](cooperative-vertical-slice-1.0-brief.md)
   summarizes the separate 1.0 stage contract.
4. [Prototype and 1.0 Supporting Artifacts](prototype-and-1.0-supporting-artifacts.md)
   provides subordinate decision, terminology, state, release, threat, test,
   and provenance traceability.

The briefs summarize stage contracts and do not override the specialized
canonical product or technical documents.

## Delivery and Work Status

- [Repository Roadmap](../README.md) defines release boundaries and dependency
  order.
- [Prototype Roadmap](next-steps-mmorpg-prototype.md) expands the pre-1.0
  prototype.
- [Playable Movement POC](movement-poc.md) records the temporary local
  movement-feel exception, imported asset provenance, and verification evidence
  for issue #100.
- [Continuous Integration](continuous-integration.md) records the Issue #16
  prototype CI quality gates, required-versus-advisory checks, runner
  constraints, and machine-readable evidence path.
- [GitHub Issues](https://github.com/ShayShimoni/aetheln-online/issues) govern
  work status, ownership, priority, and target version.

## Rendered Artifacts

- [Character Codex](../output/pdf/champions_of_the_first_cycle.pdf)
- [Settlement Codex](../output/pdf/Settlements_of_Aetheln_City_and_Village_Codex.pdf)

The PDF codices are rendered artifacts of the canonical Markdown character and
settlement documents.

## Non-Canonical Visual Development

- [Visual-development package](../visuals/README.md) describes the imported
  concepts and editable UI studies.
- [Asset provenance](../visuals/asset-provenance.md) records source, processing,
  and review status for the imported package.
- [Future visuals plan](../visuals/FUTURE-VISUALS-PLAN.md) governs continuation
  of the established visual language.

These files support review and production planning. They do not override the
canonical product or technical documents, and repository inclusion does not
approve an asset for Unreal `Content/` or runtime use.

## Historical Research Archive

- [Historical planning and research](research/README.md)

The archive preserves feasibility, lore, delivery, environment, and roadmap
background under Issue
[#65](https://github.com/ShayShimoni/aetheln-online/issues/65). Archive contents
are non-authoritative and must not override canonical product, technical, or
delivery documents.

## Decision Precedence

When documents disagree:

1. Explicit user-approved product decisions and the canonical Game Design
   Bible define player-facing behavior.
2. The specialized canonical product document defines detailed system behavior.
3. The technical overview and specialized technical document define
   implementation, with accepted entries in the architecture registry governing
   evidence-based technical choices.
4. The repository and prototype roadmaps define delivery order and stage
   boundaries.
5. GitHub Issues define current work status, not product or architecture rules.
6. Supporting research, older planning reports, and historical artifacts are
   background only.

If a technical constraint appears unable to implement a product rule, record the
conflict and obtain a reviewed product or architecture decision. Do not silently
change the product rule or revive a rejected historical recommendation.
