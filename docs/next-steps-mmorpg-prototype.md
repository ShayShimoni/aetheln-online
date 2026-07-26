# Aetheln Online Prototype Roadmap

The repository [README](../README.md#delivery-roadmap) defines release boundaries and the canonical dependency order. GitHub Issues remain the source of truth for work status, priority, ownership, and target version. This document expands the pre-1.0 prototype stage.

**Do not begin by building the full MMORPG. Build a small, networked action-combat prototype first.**

That recommendation follows from Unreal's architecture: multiplayer networking, dedicated servers, replicated abilities, online sessions, world streaming, inventory, UI, AI, and persistence are separate systems. Combining all of them immediately would make it difficult to learn what is failing. Unreal already provides appropriate foundations—client/server networking, the Gameplay Ability System, Lyra, and World Partition—but they should be introduced incrementally.

Reference: [Understanding the Unreal Engine Gameplay Ability System](https://dev.epicgames.com/documentation/en-us/unreal-engine/understanding-the-unreal-engine-gameplay-ability-system)

## 1. Define Your First Prototype

Your initial goal should be:

> **A two-player online action-RPG combat arena inspired by TERA-style combat, using temporary assets.**

The prototype should contain only:

- One playable character class
- Third-person movement and camera
- Soft lock-on or targeting
- One basic three-hit attack chain
- Dodge or evasive movement
- Three active abilities
- Health, mana, cooldowns, and damage
- One enemy type
- One small greybox arena
- Two players connecting locally
- Server-authoritative combat
- Basic death and respawn

Unreal's Gameplay Ability System is designed for RPG-style attributes, costs, cooldowns, status effects, animation, effects, and multiplayer replication, making it the appropriate basis for your combat system.

Reference: [Gameplay Ability System for Unreal Engine](https://dev.epicgames.com/documentation/unreal-engine/gameplay-ability-system-for-unreal-engine?lang=en-US)

### Do Not Build These Yet

- Open world
- Character creation
- Crafting
- Guilds
- Auction house
- Persistent accounts
- Large quest systems
- Multiple races or classes
- Hundreds of players
- Final graphics
- Cash shop
- Production dedicated-server hosting or deployment infrastructure

Those features come only after the combat prototype is enjoyable and stable.

## 2. Install the Minimum Toolset

Install these in this order:

1. **Epic Games Launcher**
2. **The supported stable Unreal Engine 5.8 release**
3. **Visual Studio with C++ development support**
4. **GitHub Desktop**
5. **Lyra Starter Game**
6. **Claude Code**
7. **Codex CLI or Codex IDE extension**
8. **Blender**, later when you begin creating original models

Use a stable Unreal release, not a Preview build. Epic states that Preview builds are not intended for project development because they may contain bugs or instability.

Reference: [Install Unreal Engine](https://dev.epicgames.com/documentation/en-us/unreal-engine/install-unreal-engine)

GitHub Desktop is useful for a beginner because it also installs Git LFS. Unreal projects contain large binary assets, and GitHub recommends Git LFS for large files rather than storing them normally in Git.

Reference: [About Git Large File Storage](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-git-large-file-storage)

Download Lyra as a **reference project**, not as the game you continuously modify. Lyra demonstrates multiplayer, a customized Gameplay Ability System, UI, locomotion, modular game features, inventory, equipment, and online integration.

Reference: [Lyra Sample Game](https://dev.epicgames.com/documentation/unreal-engine/lyra-sample-game-in-unreal-engine?lang=en-US)

## 3. Create Two Unreal Projects

### Project A: `LyraReference`

Download the untouched Lyra Starter Game.

Use it to study:

- Character input
- Abilities
- Dash implementation
- Health
- Animation
- Equipment
- Multiplayer flow
- UI
- Game feature plugins

Do not heavily edit this project.

### Project B: Aetheln Online prototype

Create a new **Games → Third Person → C++** project with Starter Content.

This is where your actual prototype will live.

Record the exact Unreal project name in [Issue #13](https://github.com/ShayShimoni/aetheln-online/issues/13) before creating it; do not introduce a second product or repository name.

Start with C++ enabled even though you will initially use many Blueprints. Adding C++ later can produce unnecessary restructuring, while a C++ project still permits extensive Blueprint development.

## 4. Finish Source-Control Safeguards Before Adding Unreal Assets

The GitHub repository and its `develop` integration branch already exist. Complete [Issue #14](https://github.com/ShayShimoni/aetheln-online/issues/14) before adding `.uasset` or `.umap` files.

The repository should contain:

- Unreal `.gitignore`
- Git LFS rules for `.uasset` and `.umap`
- `README.md`
- `AGENTS.md`
- `docs/GameBrief.md`
- Architecture and task documentation when their tickets require it

Use `AGENTS.md` as the shared project instruction file for Codex. Codex reads `AGENTS.md` before beginning work. Claude Code reads `CLAUDE.md`; Anthropic documents that `CLAUDE.md` can import `AGENTS.md`, allowing both agents to work from the same core instructions.

Reference: [Codex AGENTS.md Configuration](https://developers.openai.com/codex/agent-configuration/agents-md)

Your `CLAUDE.md` can begin with:

```md
@AGENTS.md

## Claude Code

Always start substantial Unreal Engine changes in plan mode.
Do not edit generated folders such as Binaries, DerivedDataCache,
Intermediate, or Saved.
```

## 5. Use Claude and Codex in Different Roles

Do not ask both agents to independently rewrite the same feature.

### Claude Code: Planning and Implementation

1. Give Claude one small task.
2. Start in Plan Mode.
3. Make Claude inspect the project and propose a file-by-file plan.
4. Review the plan.
5. Let Claude implement only the approved task.
6. Compile and test inside Unreal.

Claude's Plan Mode reads the codebase and proposes changes without editing files until the plan is approved.

Reference: [Claude Code Common Workflows](https://docs.anthropic.com/en/docs/claude-code/common-workflows)

### Codex: Review and Correction

After Claude completes the task:

1. Open the repository in Codex.
2. Run `/review`.
3. Ask it to examine:
   - Unreal lifecycle errors
   - Replication mistakes
   - Client/server authority
   - Null-pointer risks
   - Blueprint exposure
   - Performance problems
   - Missing tests
4. Apply verified fixes.
5. Compile again.
6. Commit the working version.

Codex's review mode can inspect uncommitted changes, commits, branches, or custom scopes and returns prioritized findings without modifying the working tree unless asked.

Reference: [Codex Code Review](https://developers.openai.com/codex/code-review)

## 6. Your First Four Milestones

### Milestone 1 — Technical Foundation

Complete:

- The one-page game brief and prototype success criteria
- Unreal source-control and Git LFS safeguards
- The UE5.8 C++ project and initial module boundaries
- The networking and server-authority spike
- Repeatable local client and dedicated-server builds

Do not add gameplay systems until the project opens, builds, launches, and supports the planned two-client test path.

### Milestone 2 — Replicated Movement

Build and validate:

- Third-person movement and camera
- Sprint
- Aiming or targeting
- Unreal Character Movement prediction and reconciliation
- Correct position and facing on both clients
- Behavior under representative latency

### Milestone 3 — Combat Framework

Add the Gameplay Ability System:

- Health
- Mana or stamina
- Basic attack ability
- Dodge ability
- Three skills
- Damage effects
- Cooldowns
- Death
- Respawn
- Server validation of damage, cooldowns, and invalid repeated actions

Test every combat increment with two editor clients. Both players must see the same ability, damage, death, and respawn results, and neither client may falsely modify authoritative state. Unreal's editor supports multiple-player and dedicated-server-style tests before paid hosting is needed.

Reference: [Testing and Debugging Networked Games](https://dev.epicgames.com/documentation/en-us/unreal-engine/testing-and-debugging-networked-games-in-unreal-engine)

### Milestone 4 — Playable Prototype Gate

Add:

- One small environment
- One enemy
- One short combat objective
- Basic UI
- Sound and temporary effects
- A two-player playtest under representative network conditions
- Recorded build, test, logging, and performance evidence

Evaluate the result against Issue #48. Only after the prototype passes that gate should work begin on the explorable world, persistence, authentication, cooperative dungeon, external playtest build, or production hosting required by the 1.0 vertical slice.

## Current Execution Order

1. Create a one-page `docs/GameBrief.md` under [Epic #1](https://github.com/ShayShimoni/aetheln-online/issues/1) answering:

   - What does the player do every 30 seconds?
   - What makes combat different?
   - Is targeting locked, soft-targeted, or fully aimed?
   - What are the first three abilities?
   - What is the camera behavior?
   - What causes victory and defeat?
   - What is explicitly outside the prototype?
   - What must work with two connected players?

2. Configure Git LFS and Unreal repository safeguards in [Issue #14](https://github.com/ShayShimoni/aetheln-online/issues/14).
3. Bootstrap the UE5.8 C++ project in [Issue #13](https://github.com/ShayShimoni/aetheln-online/issues/13).
4. Validate the Unreal networking and server-authority approach in [Issue #2](https://github.com/ShayShimoni/aetheln-online/issues/2).
5. Establish repeatable local client and dedicated-server builds in [Issue #15](https://github.com/ShayShimoni/aetheln-online/issues/15).
6. Implement replicated movement in [Issue #17](https://github.com/ShayShimoni/aetheln-online/issues/17).
7. Complete the minimal server-authoritative combat arena under [Epic #6](https://github.com/ShayShimoni/aetheln-online/issues/6).
8. Pass the prototype exit gate in [Issue #48](https://github.com/ShayShimoni/aetheln-online/issues/48) before starting the 1.0 vertical slice.

Install Unreal Engine 5.8, Visual Studio, Git LFS, and Lyra only when needed for the corresponding foundation ticket.

## First Gameplay Ticket

After the game brief and foundation tickets are complete, implement [Issue #17](https://github.com/ShayShimoni/aetheln-online/issues/17):

> **Create a replicated third-person character that can move, sprint, rotate with the camera, and appear correctly in a two-player Unreal Editor session.**
