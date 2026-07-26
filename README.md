# Aetheln Online

Aetheln Online is a server-authoritative fantasy action MMORPG built around two
opposing factions, permanent character development, meaningful equipment, and
mandatory open-world PvP in mixed territories. New characters begin inside
separate protected faction homelands; safe neutral cities connect the wider
world, while contested regions and invasion-enabled faction capitals create the
long-term conflict.

The first delivery goal remains a focused MMO-lite vertical slice. It proves
combat, cooperation, persistence, and technical architecture before the project
attempts the full faction world.

Read the [documentation index](docs/documentation-index.md) and
[canonical game-design bible](docs/game-design-bible.md) for the current product
direction. Read the
[technical architecture](docs/technical-architecture.md) before planning
implementation.

## Canonical Design

- Two opposing factions have distinct protected starting territories, quests,
  skills, and utility progression.
- Rival factions meet in mixed territories where open-world PvP is mandatory
  and cannot be disabled except inside explicit server-authoritative sanctuary
  subzones.
- Neutral mixed cities are safe. Faction capitals allow difficult individual
  infiltration and organized invasions without exposing beginner districts.
- Every playable race supports male and female characters. Race and sex do not
  change combat statistics, class access, faction access, or authoritative
  hitboxes.
- Permanent Character Levels are separate from seasonal Ember Rank.
- Skein Weaving uses ability Forms, action-to-action Threads, a Keystone, and a
  Faction Doctrine instead of a traditional talent tree.
- Equipment provides noticeable power, recovery, speed, and utility within
  controlled limits. Aim, timing, positioning, blocking, dodging, interruption,
  and judgment remain decisive.
- The server owns combat outcomes, progression, item generation, loot grants,
  contested-resource loss, and faction rewards.
- Combat uses pure free aim. The server resolves authored attack volumes and
  never accepts a client-selected target or claimed hit.

Detailed rules live in:

- [Game Design Bible](docs/game-design-bible.md)
- [Characters and Factions](docs/characters-and-factions.md)
- [World and Settlements](docs/world-and-settlements.md)
- [Progression, Loot, Skein Weaving, and Character Creation](docs/progression-loot-and-skein.md)

## Canonical Architecture

The [technical architecture overview](docs/technical-architecture.md) defines
system context, trust zones, state ownership, Unreal module boundaries, staged
topology, public contracts, and evidence gates.

Focused specifications cover:

- [Combat and Networking](docs/combat-and-networking-architecture.md)
- [World Runtime and Building](docs/world-runtime-and-building.md)
- [Progression and Persistence](docs/progression-and-persistence-architecture.md)
- [Security and Operations](docs/security-and-operations.md)
- [Performance, Quality, and Delivery](docs/performance-quality-and-delivery.md)
- [Architecture Decisions](docs/architecture-decisions.md)

Product documents govern player behavior. Technical documents govern
implementation. Roadmaps govern delivery order, while GitHub Issues govern work
status, priority, and ownership. Historical research is non-authoritative.

## Delivery Roadmap

Release numbers describe player-facing deliverables. The GitHub project phases describe the work needed to reach them. The prototype is a pre-release validation gate, not the full MVP.

### Prototype Gate - Pre-1.0

The prototype proves the technical foundation and core combat before persistence, world scale, or social systems expand:

- A one-page game brief defines the core loop, combat identity, target party size, success criteria, and explicit exclusions
- Unreal Engine 5.8, C++, repository safeguards, and module boundaries form a repeatable baseline
- Two connected players can move, use pure-free-aim attacks, dodge, take damage,
  die, and respawn in one greybox arena
- Movement and combat remain understandable under representative latency and packet loss
- The server rejects invalid movement, attacks, cooldown use, and damage
- Foundational CI, multiplayer automation, structured rejection telemetry, and
  performance instrumentation run
- Local build, multiplayer test, logging, and performance checks are documented

The prototype must satisfy the agreed exit criteria before work advances to the 1.0 vertical slice.

### 1.0.0 - Cooperative Vertical-Slice MVP

The MVP is the smallest externally playable version of the core experience:

- Account authentication, character creation, and session recovery
- One representative safe hub, one outdoor objective, and one cooperative
  dungeon
- Responsive movement, aiming, abilities, dodge, damage, death, and respawn
- Readable enemy attacks and one server-authoritative boss encounter
- Party formation, world travel, completion flow, and return to the hub
- Minimal permanent progression plus bounded integer currency rewards with
  transactional, idempotent receipts
- Server-owned persistence APIs and validation of untrusted client actions
- Logging, crash reporting, multiplayer tests, and performance budgets
- A packaged build suitable for an external playtest

### Later Versions

- **1.1.0 - Character Development:** inventory, equipment, permanent levels,
  initial Skein Weaving, expanded CI/automation coverage, and structured
  playtest triage.
- **1.2.0 - Social and Operations:** cooperative matchmaking, text chat,
  friends, and test administration or account-recovery tools.
- **2.0.0 - Faction Frontier:** the one-time choice from
  `Faction = Unassigned`, two faction identities, representative starting
  experiences, one mixed territory with mandatory PvP, a safe neutral city,
  contested resources, PvP rewards, balance telemetry, and exploit testing.
- **2.1.0 - Faction War:** expanded faction territories, individual capital
  infiltration, organized capital invasions, territory objectives, and war
  operations.

Open-world faction PvP is mandatory in the target game, but it is not part of
the prototype or 1.0 MVP gate. Those early stages first prove the combat and
server authority on which fair world PvP depends. Large raids, guild systems,
housing, auction systems, deep crafting, mounts, pets, and large cosmetic
pipelines remain outside the current delivery roadmap. The final world may use
regional servers and streaming; "open world" does not require one unbounded
simulation process.

## Execution Order

Complete roadmap work in dependency order:

1. Finish the game brief and prototype success criteria under [Epic #1](https://github.com/ShayShimoni/aetheln-online/issues/1).
2. Configure Unreal source-control and Git LFS safeguards in [Issue #14](https://github.com/ShayShimoni/aetheln-online/issues/14).
3. Publish and maintain the canonical technical baseline in [Issue #59](https://github.com/ShayShimoni/aetheln-online/issues/59).
4. Bootstrap and verify the Unreal Engine 5.8 C++ project in [Issue #13](https://github.com/ShayShimoni/aetheln-online/issues/13).
5. Record Unreal Engine 5.8 as the selected engine and validate its networking, authority, latency, disconnect, and hosting approach in [Issue #2](https://github.com/ShayShimoni/aetheln-online/issues/2).
6. Establish repeatable local client and dedicated-server builds in [Issue #15](https://github.com/ShayShimoni/aetheln-online/issues/15).
7. Implement and validate replicated third-person movement in [Issue #17](https://github.com/ShayShimoni/aetheln-online/issues/17).
8. Build the smallest server-authoritative combat arena through [Epic #6](https://github.com/ShayShimoni/aetheln-online/issues/6).
9. Evaluate the prototype against the exit criteria in [Issue #48](https://github.com/ShayShimoni/aetheln-online/issues/48) before beginning the 1.0 vertical slice.

The [GitHub Issues backlog](https://github.com/ShayShimoni/aetheln-online/issues) remains the source of truth for work status, priority, ownership, and target version. This roadmap defines stage boundaries and dependencies.

## Repository Structure

The repository currently contains planning and contribution infrastructure:

- `.github/ISSUE_TEMPLATE/` - user story, bug, and technical-task templates
- `.gitignore` - Unreal Engine, IDE, build-output, and local-secret exclusions
- `docs/documentation-index.md` - document authority and reading order
- `docs/game-design-bible.md` - canonical product and gameplay direction
- `docs/characters-and-factions.md` - faction ideologies and character loyalties
- `docs/world-and-settlements.md` - territory, city, and invasion rules
- `docs/progression-loot-and-skein.md` - progression, builds, equipment, and
  server-side reward rules
- `docs/technical-architecture.md` - canonical technical overview and system
  boundaries
- `docs/*-architecture.md` plus `docs/security-and-operations.md` and
  `docs/performance-quality-and-delivery.md` - focused implementation
  specifications and decision registry
- `output/pdf/` - rendered copies of maintained PDF codices
- `README.md` - product scope, roadmap, and contributor entry point

The planned Unreal Engine 5.8 layout uses `Source/` for C++ modules, `Content/` for game assets, `Config/` for tracked defaults, and `Plugins/` for project extensions. Generated directories such as `Binaries/`, `DerivedDataCache/`, `Intermediate/`, and `Saved/` must not be committed.

## Getting Started

```powershell
git clone --branch develop https://github.com/ShayShimoni/aetheln-online.git
cd aetheln-online
```

No Unreal project, build command, or automated test command is available yet. Issues #13 and #15 will establish and document the supported build and launch paths.

## Work Management

[GitHub Issues](https://github.com/ShayShimoni/aetheln-online/issues) are the source of truth for epics, stories, features, tasks, and defects. Work is planned in the [Aetheln Online Development project](https://github.com/users/ShayShimoni/projects/1).

Board workflow:

`Backlog -> Open -> In Progress -> Code Review -> Dev Done -> QA -> Done`

Use `Blocked` only when work cannot progress, and populate `Blocked Reason`. Priorities range from `P0 - Must` to `P3 - Later`; `Target Version` records the intended release. Pull requests should describe the change, report exact verification, link the relevant issue, and use `Closes #<issue-number>` when appropriate.

## Current Status

The repository is in planning and technical-foundation setup. Implementation
has not started. The canonical direction now includes the faction world,
mandatory mixed-territory PvP, Skein Weaving, and bounded equipment power. The
next delivery gate remains the game brief under Epic #1, followed by the
foundation and gameplay work in the dependency order above.
