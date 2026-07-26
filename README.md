# Aetheln Online

Aetheln Online is a server-authoritative multiplayer fantasy action RPG. The first goal is a focused MMO-lite vertical slice that proves the combat, cooperative loop, persistence, and technical architecture before the project expands in scale.

## Release Plan

### 1.0.0 - MVP

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

Large raids, seamless open-world technology, guild wars, housing, auction systems, deep crafting, mounts, pets, and large cosmetic pipelines remain outside the current roadmap.

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

No Unreal project, build command, or automated test command is available yet. The engine, networking, backend, and hosting spikes must be completed before implementation commands are documented.

## Work Management

[GitHub Issues](https://github.com/ShayShimoni/aetheln-online/issues) are the source of truth for epics, stories, features, tasks, and defects. Work is planned in the [Aetheln Online Development project](https://github.com/users/ShayShimoni/projects/1).

Board workflow:

`Backlog -> Open -> In Progress -> Code Review -> Dev Done -> QA -> Done`

Use `Blocked` only when work cannot progress, and populate `Blocked Reason`. Priorities range from `P0 - Must` to `P3 - Later`; `Target Version` records the intended release. Pull requests should describe the change, report exact verification, link the relevant issue, and use `Closes #<issue-number>` when appropriate.

## Current Status

The repository is in planning and technical-foundation setup. All current tickets are prioritized and versioned; implementation has not started.
