# Repository Guidelines

## Project Structure & Module Organization

This repository currently contains planning and lore material under `docs/`; no Unreal project, source tree, automated tests, or build scripts have been added yet. Keep research, architecture notes, and game-design documents in `docs/`. When implementation begins, follow the planned Unreal layout:

- `Source/GameCore/` for gameplay framework classes.
- `Source/GameCombat/` for Gameplay Ability System abilities, effects, and combat traces.
- `Source/GameUI/` for CommonUI widgets and HUD code.
- `Source/GameNet/` for sessions and backend integration.
- `Source/GameServer/` for dedicated-server-only behavior.
- `Content/`, `Config/`, and `Plugins/` for Unreal assets, settings, and extensions.

Do not commit generated Unreal directories such as `Binaries/`, `DerivedDataCache/`, `Intermediate/`, or `Saved/`.

## Build, Test, and Development Commands

There are no repository-defined build or test commands yet. Documentation changes should be checked with `git diff --check` once Git is initialized. After the `.uproject` is added, document exact engine-version-specific commands here. Expected workflows include building from Visual Studio, launching the project in Unreal Editor, testing multiplayer through Play In Editor (PIE), and packaging a Windows client plus Linux dedicated server.

## Coding Style & Naming Conventions

Use Unreal Engine C++ conventions: tabs for C++ indentation, PascalCase types and methods, `b` prefixes for booleans, and standard class prefixes such as `A`, `U`, `F`, and `E`. Prefer server-authoritative gameplay; clients may predict presentation but must not decide damage, cooldowns, or persistence. Use consistent Gameplay Tags such as `Ability.Melee.Combo1`, `State.Dodging`, and `Cooldown.Dodge`. Name Markdown files descriptively and use clear heading hierarchies.

## Testing Guidelines

Add focused automation tests beside each implemented system when practical. For networking changes, verify at least two PIE clients, replication, server authority, death/respawn, and behavior under simulated lag or packet loss. Record manual test steps in the pull request when automation is unavailable.

## Commit & Pull Request Guidelines

No Git history is available, so no existing commit convention can be inferred. Use short imperative subjects, for example `Add replicated sprint ability`. Keep commits scoped. Pull requests should explain intent, list verification performed, link relevant tasks, and include screenshots or video for visible gameplay or UI changes.
