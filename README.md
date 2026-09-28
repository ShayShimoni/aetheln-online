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
implementation. The reviewed stage contracts are the
[Prototype Game Brief](docs/GameBrief.md) and
[1.0 Cooperative Vertical-Slice Brief](docs/cooperative-vertical-slice-1.0-brief.md).
The [scope ledger](docs/prototype-and-1.0-scope-ledger.md) and
[supporting artifacts](docs/prototype-and-1.0-supporting-artifacts.md) provide traceability.

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
- The confirmed playable peoples are human Aurin, organic-mineral Kell, and
  dream-veiled Vesh. Culture, anatomy, and presentation never grant racial
  gameplay advantages or lock faction, class, or equipment access.
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
- [Playable Peoples](docs/playable-peoples.md)
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

- The reviewed prototype brief defines the core loop, combat identity, success
  criteria, explicit exclusions, and owned blocking decisions
- The supported Unreal Engine source revision, C++, repository safeguards, and
  accepted `GameCore`, `GameCombat`, `GameUI`, `GameNet`, and server-only
  `GameServer` boundaries form a repeatable baseline
- Two connected players can move, use pure free aim, perform a basic three-hit
  attack chain, dodge, use three representative active abilities, engage one
  readable enemy and one authoritative objective, take damage, die, and respawn
  in one greybox arena
- Movement and combat remain understandable under representative latency and packet loss
- The server rejects invalid movement, attacks, cooldown use, and damage
- Foundational CI, multiplayer automation, structured rejection telemetry, and
  performance instrumentation run
- Local build, multiplayer test, logging, and performance checks are documented

Issue #48 evaluates the implemented prototype against its exit criteria before
work advances to the 1.0 vertical slice. It is not an entry prerequisite for
Issue #13.

### 1.0.0 - Cooperative Vertical-Slice MVP

The MVP is the smallest externally playable version of the core experience:

- Account authentication, character creation, and session recovery
- Distinct safe-hub, outdoor-zone, and on-demand cooperative-dungeon runtime
  roles, with one representative objective and dungeon
- Responsive movement, aiming, abilities, dodge, damage, death, and respawn
- Readable enemy attacks and one server-authoritative boss encounter
- Party formation, world travel, completion flow, and return to the hub
- Minimal permanent progression plus bounded integer currency rewards with
  transactional, idempotent receipts
- Server-owned persistence APIs and validation of untrusted client actions
- Logging, crash reporting, multiplayer tests, and performance budgets
- A packaged build suitable for an external playtest

### Later Versions

- **1.1.0 - Character Development:** inventory, equipment, permanent Character
  Levels under Issue #50,
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

1. Complete and review the briefs, scope ledger, and supporting artifacts in
   [Issue #71](https://github.com/ShayShimoni/aetheln-online/issues/71),
   resolving or explicitly blocking its owned product decisions.
2. Configure Unreal source-control and Git LFS safeguards in [Issue #14](https://github.com/ShayShimoni/aetheln-online/issues/14).
3. Publish and maintain the canonical technical baseline in [Issue #59](https://github.com/ShayShimoni/aetheln-online/issues/59).
4. After Issue #71 and Issue #13's other prerequisites are satisfied, bootstrap
   and verify the supported Unreal Engine C++ project in [Issue #13](https://github.com/ShayShimoni/aetheln-online/issues/13).
5. After the pinned project exists, begin the design and editor-prototype work
   for [Issue #2](https://github.com/ShayShimoni/aetheln-online/issues/2), and
   begin the repository, formatting, static-analysis, and focused-automation
   foundation for [Issue #16](https://github.com/ShayShimoni/aetheln-online/issues/16).
   This early work is not Issue #2's final packaged evidence.
6. Use the pinned Unreal source engine to establish repeatable packaged Windows
   client and Linux dedicated-server builds in
   [Issue #15](https://github.com/ShayShimoni/aetheln-online/issues/15);
   launcher binaries are not the canonical packaged-server path.
7. Complete Issue #16's supported-target and packaged-smoke gates using Issue
   #15's build path, then complete Issue #2's final equivalent packaged
   comparisons and closure evidence using Issue #15's artifacts.
8. Build the smallest server-authoritative combat arena through
   [Epic #6](https://github.com/ShayShimoni/aetheln-online/issues/6), with
   [Issue #17](https://github.com/ShayShimoni/aetheln-online/issues/17) as its
   first actionable child rather than a separately counted roadmap step.
9. Evaluate the prototype against the exit criteria in [Issue #48](https://github.com/ShayShimoni/aetheln-online/issues/48) before beginning the 1.0 vertical slice.

The [GitHub Issues backlog](https://github.com/ShayShimoni/aetheln-online/issues) remains the source of truth for work status, priority, ownership, and target version. This roadmap defines stage boundaries and dependencies.

## Repository Structure

The repository currently contains planning and contribution infrastructure:

- `.github/ISSUE_TEMPLATE/` - user story, bug, and technical-task templates
- `.gitignore` - Unreal Engine, IDE, build-output, and local-secret exclusions
- `.gitattributes` - Git LFS and locking rules for Unreal binary assets
- `docs/documentation-index.md` - document authority and reading order
- `docs/GameBrief.md` and `docs/cooperative-vertical-slice-1.0-brief.md` -
  reviewed prototype and 1.0 stage contracts
- `docs/prototype-and-1.0-scope-ledger.md` and
  `docs/prototype-and-1.0-supporting-artifacts.md` - requirement dispositions
  and traceability
- `docs/game-design-bible.md` - canonical product and gameplay direction
- `docs/playable-peoples.md` - playable anatomy, culture, customization, and
  presentation contracts
- `docs/characters-and-factions.md` - faction ideologies and character loyalties
- `docs/world-and-settlements.md` - territory, city, and invasion rules
- `docs/progression-loot-and-skein.md` - progression, builds, equipment, and
  server-side reward rules
- `docs/technical-architecture.md` - canonical technical overview and system
  boundaries
- `docs/*-architecture.md` plus `docs/security-and-operations.md` and
  `docs/performance-quality-and-delivery.md` - focused implementation
  specifications and decision registry
- `docs/source-control.md` - Unreal asset locking and verification workflow
- `docs/unreal-project-setup.md` - pinned UE 5.8 project setup, build, and
  first-launch workflow
- `visuals/` - non-canonical visual-development concepts, editable UI studies,
  package provenance, and validation tooling; these assets remain outside
  Unreal `Content/` until separately reviewed for implementation
- `output/pdf/` - rendered copies of maintained PDF codices
- `README.md` - product scope, roadmap, and contributor entry point

The planned Unreal Engine layout uses `Source/` for C++ modules, `Content/` for game assets, `Config/` for tracked defaults, and `Plugins/` for project extensions. Generated directories such as `Binaries/`, `DerivedDataCache/`, `Intermediate/`, and `Saved/` must not be committed.

## Getting Started

```powershell
git lfs install
git clone --branch develop https://github.com/ShayShimoni/aetheln-online.git
cd aetheln-online
```

Review the [Unreal source-control workflow](docs/source-control.md) before
adding or editing `.uasset` and `.umap` files.

Review the [visual-development package](visuals/README.md), its
[provenance register](visuals/asset-provenance.md), and the
[future visuals plan](visuals/FUTURE-VISUALS-PLAN.md) before using or extending
the imported concepts. Repository inclusion records and preserves the package;
it does not make an image canonical, production-ready, or approved for Unreal
runtime use.

Before adding or promoting runtime content, follow the
[asset intake and content-validation contract](docs/asset-intake-and-content-validation.md).
Repository presence or successful import never grants production approval.

Use the [pinned Unreal project setup guide](docs/unreal-project-setup.md) to
verify the engine revision, generate project files, build the Development
Editor target, and launch the starter map. Issue #15 owns clean client/server
builds, cooking, and packaging. Run the repository-defined automated checks
with `powershell -NoProfile -File scripts/ci/Invoke-CiSuite.ps1`;
[docs/continuous-integration.md](docs/continuous-integration.md) records the
required and advisory gates.

## Work Management

[GitHub Issues](https://github.com/ShayShimoni/aetheln-online/issues) are the source of truth for epics, stories, features, tasks, and defects. Work is planned in the [Aetheln Online Development project](https://github.com/users/ShayShimoni/projects/1).

Board workflow:

`Backlog -> Open -> In Progress -> Code Review -> Dev Done -> QA -> Done`

Use `Blocked` only when work cannot progress, and populate `Blocked Reason`. Priorities range from `P0 - Must` to `P3 - Later`; `Target Version` records the intended release. Pull requests should describe the change, report exact verification, link the relevant issue, and use `Closes #<issue-number>` when appropriate.

## Current Status

The repository has moved from planning into technical-foundation
implementation. The canonical documentation contract in Issue #71 is complete,
and the pinned Unreal Engine C++ bootstrap delivered through Issue #13 is
present in the repository while that issue completes its remaining board
lifecycle. The canonical direction includes the faction world, mandatory
mixed-territory PvP, Skein Weaving, bounded equipment power, and distinct,
gameplay-neutral presentation for the Aurin, Kell, and Vesh. Delivery continues
through the dependency order above and the live GitHub Issues board.
