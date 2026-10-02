# Repository Guidelines

## Documentation Authority

Before planning or changing gameplay, lore, progression, items, factions, world
structure, or delivery scope, read:

1. `docs/documentation-index.md`
2. `docs/game-design-bible.md`
3. The specialized canonical document for the system:
   - `docs/playable-peoples.md`
   - `docs/characters-and-factions.md`
   - `docs/world-and-settlements.md`
   - `docs/progression-loot-and-skein.md`
4. `README.md` and `docs/next-steps-mmorpg-prototype.md` for delivery order.

Before planning or changing engine structure, networking, combat implementation,
world runtime, persistence, security, operations, performance, testing, or
delivery infrastructure, also read:

1. `docs/technical-architecture.md`
2. The specialized canonical technical document:
   - `docs/combat-and-networking-architecture.md`
   - `docs/world-runtime-and-building.md`
   - `docs/progression-and-persistence-architecture.md`
   - `docs/security-and-operations.md`
   - `docs/performance-quality-and-delivery.md`
3. `docs/architecture-decisions.md`

Product documents govern player-facing behavior. Technical documents govern
implementation. Roadmaps govern delivery order, and GitHub Issues govern work
status. A technical recommendation must not silently change a canonical product
rule.

Canonical design documents override conflicting recommendations in historical
research reports. Historical documents remain useful as research, but must not
silently reintroduce rejected arena-only PvP, optional frontier PvP,
gear-equalized world combat, or traditional talent-tree assumptions.

Do not guess unresolved tuning values, final faction names, level caps, drop
rates, invasion schedules, or population limits. Preserve explicit `TBD`
decisions until evidence or user direction resolves them.

## Canonical Game Constraints

- The target game has two opposing player factions.
- Each faction has a protected starting territory and early quest campaign.
- Rival players meet after a progression threshold in mixed territories where
  open-world faction PvP is mandatory outside explicit server-authoritative
  sanctuary subzones. There is no opt-in flag.
- Neutral mixed cities are safe for both factions.
- Faction capitals support individual infiltration and organized invasions, but
  beginner districts and essential progression services remain protected.
- All playable races may join either faction and use every supported class.
- Every playable race supports male and female characters under identical
  combat rules. Race, sex, and appearance never change statistics,
  authoritative hitboxes, reach, timing, or loot probability.
- Factions provide distinct Doctrine skills and utilities. They must be
  asymmetrical in method but comparable in overall opportunity.
- Character Level is permanent and separate from seasonal Ember Rank.
- Skein Weaving uses ability Forms, Threads, a Keystone, and a Faction Doctrine;
  do not replace it with a conventional point-and-row talent tree.
- Equipment must create noticeable combat power and utility without replacing
  aim, timing, positioning, blocking, dodging, interruption, or judgment.
- Equipped items do not drop on PvP death. Only explicitly eligible unbanked
  contested resources may be placed at risk.
- Combat, progression, loot generation, PvP contribution, territory state, and
  reward grants are server authoritative, transactional, idempotent, and
  auditable.
- Working names such as Dawn Concordat and Unbound Flame are not final names.

Prototype deferral does not make a confirmed target feature optional. The
prototype still begins with one class and one controlled combat space because
movement, combat feel, latency tolerance, and authority must be proven before
the faction world is built.

## Project Structure & Module Organization

This repository contains planning, canonical design, canonical technical
architecture, and the pinned Unreal contributor setup under `docs/`, plus
rendered codices under `output/pdf/`. The Unreal project follows this layout:

- `Source/GameCore/` for gameplay framework classes.
- `Source/GameCombat/` for Gameplay Ability System abilities, effects, and combat traces.
- `Source/GameUI/` for CommonUI widgets and HUD code.
- `Source/GameNet/` for sessions and backend integration.
- `Source/GameServer/` for dedicated-server-only behavior.
- `Content/`, `Config/`, and `Plugins/` for Unreal assets, settings, and extensions.

Do not commit generated Unreal directories such as `Binaries/`, `DerivedDataCache/`, `Intermediate/`, or `Saved/`.

## Build, Test, and Development Commands

Use `docs/unreal-project-setup.md` as the source of truth for the pinned engine,
toolchain, project-generation command, Development Editor build, and first
launch. From the repository root in PowerShell:

```powershell
$AethelnEngineRoot = 'D:\UnrealEngine\UE-5.8.1-source-issue81-clean'
$AethelnProject = (Resolve-Path '.\AethelnOnline.uproject').Path
& (Join-Path $AethelnEngineRoot 'GenerateProjectFiles.bat') "-project=$AethelnProject" -game -engine -progress
& (Join-Path $AethelnEngineRoot 'Engine\Build\BatchFiles\Build.bat') AethelnOnlineEditor Win64 Development $AethelnProject -WaitMutex -NoHotReloadFromIDE
& (Join-Path $AethelnEngineRoot 'Engine\Binaries\Win64\UnrealEditor.exe') $AethelnProject /Game/Maps/StarterMap -log
```

Local engine paths must remain untracked. Issue #13 owns project generation,
the Editor build/open path, map/default-game-mode setup, and initial-launch
evidence. Issue #15 owns clean Win64 client/Linux server builds, cooking,
packaging, and their evidence. Run the repository-defined automated checks with
`powershell -NoProfile -File scripts/ci/Invoke-CiSuite.ps1`;
`docs/continuous-integration.md` records the required and advisory gates.
Check documentation changes with `git diff --check`.

## Coding Style & Naming Conventions

Use Unreal Engine C++ conventions: tabs for C++ indentation, PascalCase types and methods, `b` prefixes for booleans, and standard class prefixes such as `A`, `U`, `F`, and `E`. Prefer server-authoritative gameplay; clients may predict presentation but must not decide damage, cooldowns, or persistence. Use consistent Gameplay Tags such as `Ability.Melee.Combo1`, `State.Dodging`, and `Cooldown.Dodge`. Name Markdown files descriptively and use clear heading hierarchies.

Use `UCharacterMovementComponent` for predicted/reconciled player movement and
GAS for abilities. Player ASCs live on `PlayerState`; AI ASCs live on the
authoritative pawn. Combat uses pure free aim: the server resolves authored
attack volumes and never accepts a client-selected target or claimed hit.
Animation and effects visualize the server-owned attack timeline but do not
create gameplay truth.

Keep identity, appearance, race, sex, class/Skein, faction/Doctrine, permanent
Character Level, seasonal Ember Rank, inventory/equipment, cosmetics, and
session state as separate data concerns. Do not embed presentation choices
inside class abilities or authoritative combat calculations. Persist
`Faction = Unassigned` before the 2.0 faction stage; Doctrine remains
unavailable until the approved one-time faction choice.

Keep loot tables, item-power budgets, affix rules, Skein options, Doctrine
options, territory policy, and progression thresholds data driven. The client
may request an allowed action but must never generate an item, choose a drop,
grant progression, claim a hit, or decide whether an area permits PvP.

Keep identity, backend, data, messaging, hosting, orchestration, and anti-cheat
vendors behind adapters until an accepted architecture decision selects them.
World Partition is per-map content streaming, not server distribution.

## Testing Guidelines

Add focused automation tests beside each implemented system when practical. For networking changes, verify at least two PIE clients, replication, server authority, death/respawn, and behavior under simulated lag or packet loss. Record manual test steps in the pull request when automation is unavailable.

When the applicable systems exist, also verify:

- Protected faction starts cannot be entered or attacked by rivals.
- Mixed-territory PvP cannot be disabled.
- Safe-city boundaries reject hostile actions.
- Capital invasions cannot expose beginner districts or permanently disable
  essential services.
- Male and female variants use equivalent authoritative collision, reach, and
  timing.
- Skein and Doctrine combinations are validated by the server.
- Reward retries cannot duplicate items, currency, progression, or contested
  resources.
- Repeat-victim and collusion cases provide no exploitable PvP reward.
- Equipment advantages remain meaningful without destroying readable
  counterplay under representative latency.

## Environment Strategy

During prototype, use only:

- `local` for contributor machines, local services, and developer-specific configuration.
- `development` for multiplayer, backend, and `develop` branch integration testing.

Keep `QA` as a board status, not an environment. Add `staging` for external playtests or release candidates and `production` only for a public service. Isolate endpoints, credentials, databases, and logs. Commit example configuration only; keep secrets outside the repository.

## Direct Delivery Requests

Handle `next`, `resume`, `continue`, `audit`, `status`, and targeted issue
requests directly under the repository guidance. Use independent subagents for
bounded, parallel work when appropriate. A short request does not itself
authorize a commit, push, pull-request publication, merge, branch change, pull,
deployment, deletion, or migration.

## Commit & Pull Request Guidelines

Follow the scoped Conventional Commit-style subjects established by repository
history: `type(scope): #<issue> <imperative summary>`, for example
`feat(combat): #17 add replicated sprint ability`. Keep commits scoped. Pull
requests follow [.github/PULL_REQUEST_TEMPLATE.md](.github/PULL_REQUEST_TEMPLATE.md):
explain intent, link the ticket, list exact verification, name the review focus,
record review evidence and residual limitations, and include screenshots or
video for visible gameplay or UI changes.

Releases follow [Releases and versioning](docs/delivery-workflow.md#releases-and-versioning).
Feature and fix PRs target `develop`. `main` receives only `release/*` and
`hotfix/*` PRs, and only when a build is distributed to players. Internal
pre-release tags (`vX.Y.Z-alpha.N`, `-beta.N`, `-rc.N`) stay on `release/*`
branches. Board moves: `Done` issues move to `Release Candidate` when a
release branch containing them is cut, with the `Release` field set to its
tag. They move to `Released` once that release reaches players, is merged
to `main` and tagged, and is back-merged into `develop`.

## Delivery Evidence and Authority

[Delivery Workflow](docs/delivery-workflow.md) defines the evidence-based
project statuses, issue and dependency synchronization, and merge gates. Keep
independent-agent technical review, explicitly required human review, CI
verification, and owner merge authorization separate. Never label agent review
as human approval or claim a self-authored PR was `APPROVED` by its author.
`Dev Done` needs a reviewed and verified merge; `QA` and `Done` need distinct
post-merge evidence. For PRs targeting `develop`, an issue reference and manual
Development link track the issue; a `Closes #<issue>` line does not link or
auto-close it there. Do not close an issue or advance its board status merely
because a PR merged.

The project board is the source of truth for work status. It must reflect
current reality at all times. Update it in the same step as every action
that changes an issue's real state: work started, PR opened, PR merged, QA
result, blocker found or cleared. Correct any drift the moment it is noticed.
Only the lead moves the board; parallel lanes report to the lead.

Keep state durable so any later session can resume without loss. When work
starts, pauses, hands off, or changes state, record on the issue: the branch,
the worktree name (never a machine path), the head SHA, what is verified, open
decisions, and the next step. When commit and push are authorized, push work
in progress. Otherwise record what is uncommitted and where.

Board moves, made in the same step as the action:

- When the lead starts implementation on an issue, directly or through a lane,
  move the issue to `In Progress` before the work begins. Review, QA, and
  audit work does not move an issue back to `In Progress`.
- Open a PR only after developer verification is complete and recorded. Do
  not keep draft PRs open. When the PR opens, move the issue to `Code Review`.
  It stays there while CI, review, fixes, and owner authorization run; waiting
  on those gates is not `Blocked`.
- Every open feature or fix PR into `develop` has its issue in `Code Review`,
  so those PRs match the `Code Review` cards one to one. `release/*`,
  `hotfix/*`, and back-merge PRs follow
  [Releases and versioning](docs/delivery-workflow.md#releases-and-versioning).
- Move the issue to `Dev Done` only after the PR is reviewed, verified, and
  merged. For an issue that needs several PRs, return it to `In Progress`
  after a partial merge, and move it to `Code Review` again when the next PR
  opens.
- Every `Blocked` issue has a current `Blocked Reason`. A `Blocked` issue has
  no open PR: close the PR unmerged, keep its branch unchanged (no
  force-push, so the PR can be reopened), and record on the issue how to
  resume.
- When work starts on a `Blocked` issue, including work to remove its
  blocker, clear the reason and move it to `In Progress`. If the reason still
  holds when that work stops, return it to `Blocked` with the reason. When a
  separate issue tracks the blocker, that issue moves instead.
- An issue that is deliberately parked, rather than waiting on a named
  blocker, moves to `Backlog`.
- An issue moves from `Dev Done` to `QA` only when a QA round actually
  starts on it, and stays in `QA` only while that round runs. When the round
  ends: all boxes checked moves it to `Done`; a failed criterion that needs a
  fix moves it to `In Progress`; a criterion waiting on a decision, a
  dependency, or an engine QA run moves it to `Blocked` with the reason.
- Check each acceptance-criteria checkbox as soon as QA on the merged
  `develop` revision verifies that criterion, not only when the issue moves
  to `Done`. Where QA is explicitly not applicable, the distinct acceptance
  verification required by the delivery workflow takes QA's place. Check a
  box only when recorded evidence covers that criterion, and in the same step
  post or link the comment naming the run or check and the `develop` commit.
- When every acceptance and definition-of-done box is checked and the
  workflow's `Done` entry evidence is recorded, move the issue to `Done` in
  the same step. Never move an issue to `Done` with an unchecked box. An issue
  in `Done`, `Release Candidate`, or `Released` with an unchecked box returns
  to the status its evidence supports.

Keep local branches and worktrees in sync with the remote. GitHub deletes a
PR's head branch on merge. In the same step as the merge, run
`git fetch --prune` and clean up the local worktree and branch under
[Completed Delivery Branch Cleanup](docs/source-control.md#completed-delivery-branch-cleanup).
On 2026-10-03 the owner gave standing authorization for that cleanup of
merged PR head branches, so no per-ref request is needed when every check
there passes. Before removing a worktree, also confirm that
`git status --porcelain --ignored` shows no untracked files and no ignored
evidence such as `Saved/` logs or automation reports; ignored build output
(`Binaries/`, `Intermediate/`, `DerivedDataCache/`) may go. Keep worktrees
that hold preserved evidence or are engine or compile workspaces until the
issue that owns them is `Done`, and record any kept worktree's name and state
on the issue.
