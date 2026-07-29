# Prototype Game Brief

## Contract status

This brief is the concise product contract for the pre-1.0 Prototype Gate. The
[scope ledger](prototype-and-1.0-scope-ledger.md) is the normative inventory;
the canonical product and technical documents retain detailed authority. Issue
#71 supplies the reviewed documentation prerequisite for Issue #13, subject to
#13's other prerequisites. Issue #48 evaluates the implemented prototype and
controls advancement into 1.0; it is not an entry prerequisite for #13.
(Trace: P10-001, P10-037, P10-040.)

## Purpose

Prove that a packaged dedicated server and two packaged clients can deliver
readable, responsive, server-authoritative third-person action combat in one
controlled arena. The prototype validates combat feel, authority, rejection
behavior, latency tolerance, and evidence collection before persistent accounts
or the cooperative world are introduced. It is a technical validation space,
not the target faction-PvP model. (Trace: P10-002, P10-006, P10-009, P10-034.)

## Player loop

1. Two clients join one dedicated-server arena.
2. Each player moves, aims with pure free aim, uses a basic three-hit chain,
   dodges, and uses three representative active abilities.
3. The players engage one readable enemy and one authoritative objective.
4. Server-owned health drives death, respawn, reconnect cleanup, and the
   ephemeral activity result.
5. The HUD presents health, the prototype combat resource, cooldowns, objective
   state, corrections, rejections, death, and completion without owning any
   outcome.

The authoritative first PvE completion condition is a blocking TBD owned by
#1/#71. No objective implementation may infer whether completion means enemy
defeat, interaction, survival, or another terminal result. (Trace: P10-010-
P10-017, P10-042, P10-043.)

## Combat and authority contract

- Movement uses predicted and reconciled third-person movement; combat is pure
  free aim and accepts neither a selected target nor a client-claimed hit.
- Player abilities use PlayerState-owned GAS. The server owns activation,
  authored attack volumes, already-hit state, costs, cooldowns, damage, death,
  and objective results.
- The public combat record remains `CombatActivation`; this brief does not
  introduce a `CombatIntent` split.
- Animation, effects, and UI present server-owned truth and may predict only
  reversible presentation.
- Invalid, stale, duplicate, out-of-window, or otherwise unauthorized requests
  are rejected deterministically and observably.

Exact timings, ranges, costs, damage, movement bounds, network profiles, and
performance thresholds remain evidence or tuning TBDs. The prototype combat
resource is deliberately unnamed: Guard, mana, and stamina are not approved.
(Trace: P10-003, P10-011-P10-017, P10-043, P10-047, P10-052; canonical owner:
[Combat and Networking Architecture](combat-and-networking-architecture.md).)

## Foundation boundary

The accepted module baseline is `GameCore`, `GameCombat`, `GameUI`,
`GameNet`, and server-only `GameServer`. Exact engine revision, compiler,
SDK, plugin, build, and deployment mechanics remain owned by #13/#15. Issue
#13 approved and verified a Blank C++ project with no Starter Content. (Trace:
P10-002, P10-004, P10-006, P10-008, P10-044, P10-048, P10-051; canonical owner:
[Technical Architecture](technical-architecture.md).)

## Acceptance contract

Prototype evidence must show:

- a packaged dedicated server and two packaged clients completing the
  authoritative combat scenario;
- movement, pure-free-aim combat, dodge, the three-hit chain, representative
  abilities, enemy behavior, death, respawn, and readable HUD feedback;
- deterministic server rejection and structured, redacted rejection telemetry;
- focused authority, lifecycle, invalid-command, and network-condition
  automation with machine-readable evidence;
- identified client, server, replication, bandwidth, correction, and failure
  captures under reviewed scenarios; and
- a recorded Issue #48 review containing evidence, participants, decision,
  exceptions, risk owners, and follow-ups.

Issue #48 owns the final pass, no-go, or exception decision. This brief does not
invent numeric thresholds or claim that the gate has passed. (Trace: P10-007,
P10-010, P10-032-P10-037, P10-052.)

## Explicit exclusions

The prototype has no dependency on persistent accounts, durable character
progress, currency, inventory, equipment, generated items, Skein loadouts,
parties, hub/outdoor/dungeon travel, factions, Doctrine, open-world PvP,
production hosting, or vendor selection. These are staged later rather than
rejected from the target game. (Trace: P10-018-P10-031, P10-039, P10-045,
P10-046, P10-051; release allocation:
[Supporting artifacts](prototype-and-1.0-supporting-artifacts.md#release-content-matrix).)

## Blocking decisions

| Decision | Owner | Blocking effect |
| --- | --- | --- |
| Target party size | #1/#71 | Blocks party-size-dependent 1.0 work; the prototype does not select it. |
| First PvE completion condition | #1/#71 | Blocks final objective contracts in the prototype and 1.0. |
| Prototype combat resource identity | #1/#71 | Blocks final GAS attribute, cost, recovery, and HUD wording. |

These decisions require reviewed updates to their canonical destinations; brief
prose alone cannot resolve them. (Trace: P10-041-P10-043.)
