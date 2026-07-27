# Aetheln Online Documentation Index

## Canonical Product and Design Documents

These documents govern player-facing behavior, lore, progression, and world
rules. Read the Bible first, then the specialized document for the system.

1. [Game Design Bible](game-design-bible.md)
2. [Characters and Factions](characters-and-factions.md)
3. [World, Settlements, and Open-World PvP](world-and-settlements.md)
4. [Progression, Loot, and Skein Weaving](progression-loot-and-skein.md)

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

## Delivery and Work Status

- [Repository Roadmap](../README.md) defines release boundaries and dependency
  order.
- [Prototype Roadmap](next-steps-mmorpg-prototype.md) expands the pre-1.0
  prototype.
- [GitHub Issues](https://github.com/ShayShimoni/aetheln-online/issues) govern
  work status, ownership, priority, and target version.

## Rendered Artifacts

- [Character Codex](../output/pdf/champions_of_the_first_cycle.pdf)
- [Settlement Codex](../output/pdf/Settlements_of_Aetheln_City_and_Village_Codex.pdf)

The PDF codices are rendered artifacts of the canonical Markdown character and
settlement documents.

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
