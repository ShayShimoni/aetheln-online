# Aetheln Online

Aetheln Online is a server-authoritative multiplayer fantasy action RPG. The first goal is a focused MMO-lite vertical slice that proves the combat, cooperative loop, persistence, and technical architecture before the project expands in scale.

## Delivery Roadmap

Release numbers describe player-facing deliverables. The GitHub project phases describe the work needed to reach them. The prototype is a pre-release validation gate, not the full MVP.

### Prototype Gate - Pre-1.0

The prototype proves the technical foundation and core combat before persistence, world scale, or social systems expand:

- A one-page game brief defines the core loop, combat identity, target party size, success criteria, and explicit exclusions
- Unreal Engine 5.8, C++, repository safeguards, and module boundaries form a repeatable baseline
- Two connected players can move, aim, attack, dodge, take damage, die, and respawn in one greybox arena
- Movement and combat remain understandable under representative latency and packet loss
- The server rejects invalid movement, attacks, cooldown use, and damage
- Local build, multiplayer test, logging, and performance checks are documented

The prototype must satisfy the agreed exit criteria before work advances to the 1.0 vertical slice.

### 1.0.0 - Cooperative Vertical-Slice MVP

The MVP is the smallest externally playable version of the core experience:

- Account authentication, character creation, and session recovery
- One shared hub, one outdoor objective, and one cooperative dungeon
- Responsive movement, aiming, abilities, dodge, damage, death, and respawn
- Readable enemy attacks and one server-authoritative boss encounter
- Party formation, world travel, completion flow, and return to the hub
- Minimal persistent progression and safe, auditable reward grants
- Server-owned persistence APIs and validation of untrusted client actions
- Logging, crash reporting, multiplayer tests, and performance budgets
- A packaged build suitable for an external playtest

### Later Versions

- **1.1.0 - Core Expansion:** CI quality gates, inventory, equipment, cooperative matchmaking, and structured playtest triage.
- **1.2.0 - Social and Operations:** text chat, friends, and test administration or account-recovery tools.
- **2.0.0 - PvP Expansion:** an isolated arena, PvP combat rules, balance telemetry, and exploit testing.

PvP is not part of the prototype or 1.0 MVP gate. Large raids, seamless open-world technology, guild wars, housing, auction systems, deep crafting, mounts, pets, and large cosmetic pipelines remain outside the current roadmap.

## Execution Order

Complete roadmap work in dependency order:

1. Finish the game brief and prototype success criteria under [Epic #1](https://github.com/ShayShimoni/aetheln-online/issues/1).
2. Configure Unreal source-control and Git LFS safeguards in [Issue #14](https://github.com/ShayShimoni/aetheln-online/issues/14).
3. Bootstrap and verify the Unreal Engine 5.8 C++ project in [Issue #13](https://github.com/ShayShimoni/aetheln-online/issues/13).
4. Record Unreal Engine 5.8 as the selected engine and validate its networking, authority, latency, disconnect, and hosting approach in [Issue #2](https://github.com/ShayShimoni/aetheln-online/issues/2).
5. Establish repeatable local client and dedicated-server builds in [Issue #15](https://github.com/ShayShimoni/aetheln-online/issues/15).
6. Implement and validate replicated third-person movement in [Issue #17](https://github.com/ShayShimoni/aetheln-online/issues/17).
7. Build the smallest server-authoritative combat arena through [Epic #6](https://github.com/ShayShimoni/aetheln-online/issues/6).
8. Evaluate the prototype against the exit criteria in [Issue #48](https://github.com/ShayShimoni/aetheln-online/issues/48) before beginning the 1.0 vertical slice.

The [GitHub Issues backlog](https://github.com/ShayShimoni/aetheln-online/issues) remains the source of truth for work status, priority, ownership, and target version. This roadmap defines stage boundaries and dependencies.

## Repository Structure

The repository currently contains planning and contribution infrastructure:

- `.github/ISSUE_TEMPLATE/` - user story, bug, and technical-task templates
- `.gitignore` - Unreal Engine, IDE, build-output, and local-secret exclusions
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

The repository is in planning and technical-foundation setup. Implementation has not started. The next deliverable is the game brief under Epic #1, followed by the foundation and gameplay work in the dependency order above.
