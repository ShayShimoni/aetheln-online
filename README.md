# Aetheln Online

Aetheln Online is an online multiplayer fantasy game project.

## Product direction

The first target is an **MMO-lite vertical slice**, not a full seamless-world MMORPG. The goal is to prove the core combat, multiplayer loop, progression, and technical architecture before expanding the world.

## Initial MVP scope

- Account login and character creation
- One shared hub town
- One outdoor adventure zone
- One instanced cooperative dungeon
- Two playable classes initially
- Real-time combat with abilities, dodge, block, and readable enemy attacks
- Server-authoritative multiplayer
- Persistent character progression, inventory, and equipment
- Party formation and cooperative matchmaking
- Basic chat and friends functionality
- One small PvP prototype
- Logging, crash reporting, and basic administration tools

## Deferred until after MVP

- Seamless open world
- Auction house and deep crafting economy
- Player housing
- Guild wars and sieges
- Large raids
- Mount, pet, and companion systems
- Large cosmetic and transmog pipelines

## Delivery phases

1. **Prototype:** movement, camera, combat, and one networked encounter.
2. **Vertical slice:** hub, adventure zone, dungeon, progression, and party flow.
3. **Pre-alpha:** repeatable content pipeline, additional content, tooling, and stability.
4. **Alpha:** progression balance, social systems, performance, and longer sessions.
5. **Beta:** scale, security, operations, onboarding, and support readiness.
6. **Launch:** stable live service and sustainable release cadence.

## Work management

GitHub Issues are the source of truth for user stories, bugs, and technical tasks.

Recommended board flow:

`Backlog → Ready → In Progress → Code Review → Done`

Each user story should contain acceptance criteria and a definition of done. Pull requests should link their issue using `Closes #<issue-number>`.

## Current status

Repository initialized for planning. Engine, backend stack, hosting model, and art pipeline remain explicit architecture decisions to validate through prototype work.
