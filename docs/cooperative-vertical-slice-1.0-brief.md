# 1.0 Cooperative Vertical-Slice Brief

## Contract status

This brief defines the 1.0 cooperative slice separately from the pre-1.0
prototype. The [scope ledger](prototype-and-1.0-scope-ledger.md) is the
normative inventory, and specialized canonical documents retain detailed
authority. Issue #48 must evaluate the implemented prototype before 1.0
advances. (Trace: P10-018, P10-037, P10-040.)

## Slice outcome

A player authenticates, creates one minimal account-owned character, enters a
safe hub, forms and recovers an authoritative party, travels through controlled
hub, outdoor-zone, and dungeon runtime roles, completes one outdoor objective
and the Hollow Choir dungeon with Sevrin Vale, receives one authoritative
slice-approved result, and returns safely. A packaged build supports an external
playtest and recovery evidence. (Trace: P10-018-P10-025, P10-029, P10-038,
P10-054.)

The target party size and first PvE completion condition are blocking TBDs owned
by #1/#71. The slice must not infer either value or terminal condition. (Trace:
P10-041, P10-042.)

## Player journey

1. Authentication establishes account identity and character ownership.
2. Replay-safe admission creates or loads one minimal character and grants
   current authority before safe hub entry.
3. The player forms or rejoins an authoritative, versioned, idempotent party.
4. The party travels from the hub to one controlled outdoor zone and completes
   one authoritative outdoor objective.
5. Controlled transfer moves the party through reservation, checkpoint,
   destination admission, authority fencing, and source release.
6. The party enters the Hollow Choir, faces Sevrin Vale under server-owned
   combat and encounter lifecycle, and reaches the approved completion result.
7. One stable result grants approved slice-specific permanent progress and
   bounded integer currency exactly once, then the party returns through the
   controlled travel path.

The exact identities of 1.0 permanent progress and currency are blocking TBDs
owned by #27/#30 with #1/#71 product approval. UI repetition, retries, reconnect,
or process failure cannot grant additional value. (Trace: P10-019, P10-021-
P10-025, P10-027-P10-030, P10-042.)

## Runtime and authority boundary

The accepted topology has distinct hub, outdoor-zone, and on-demand dungeon
process roles. A proposed two-role private runtime is rejected. Transfers use
stable identities, authoritative checkpoints, compatible reservations,
single-use destination admission, a higher fencing epoch, idempotent source
release, and a durable terminal result. World Partition, if later accepted for
a map through evidence, is content streaming and not server distribution.
(Trace: P10-018, P10-020-P10-023, P10-046; canonical owner:
[World Runtime and Building](world-runtime-and-building.md).)

The server owns combat, sanctuary policy, party state, encounter lifecycle,
completion, rewards, and persistent mutations. Clients request allowed actions
and present results; they never choose a reward, claim a hit, move authority, or
write durable state. (Trace: P10-020-P10-025, P10-027-P10-031.)

## Persistence and recovery boundary

The 1.0 durable set is limited to identity, required appearance, approved
slice-specific progress, bounded integer currency, checkpoint/location,
versions, authority leases, commands, audit records, reward receipts, ledger,
outbox, and reconciliation records. Reward mutation is atomic, auditable, and
idempotent per `RewardEventId` and character. Authentication,
`PlayerAdmission`, `CharacterAuthorityLease`, and `PersistentCommand`
remain vendor-neutral contracts. (Trace: P10-019, P10-027-P10-031; canonical
owners: [Progression and Persistence Architecture](progression-and-persistence-architecture.md)
and [Security and Operations](security-and-operations.md).)

Recovery must cover reconnect, stale authority, interrupted transfer, duplicate
reward delivery, isolated backup restore, and authoritative reconciliation
without silent repair. Exact retention, RPO, RTO, capacity, providers, and
regional-processing policy remain evidence or qualified-review TBDs. (Trace:
P10-023, P10-028-P10-033, P10-038, P10-052, P10-053.)

## Acceptance contract

The 1.0 evidence package must demonstrate:

- authentication, ownership, admission, reconnect, and session recovery;
- packaged multi-process hub, outdoor objective, dungeon, controlled travel,
  completion, reward, and safe-return flows;
- versioned and idempotent party formation and recovery;
- exactly-once visible progress and bounded integer currency under retry and
  crash injection;
- stale-lease rejection, fenced authority transfer, restore, and
  reconciliation for the implemented data set;
- security, redaction, dependency, compatibility, and resource-control checks;
- identified performance evidence or explicit owned exceptions; and
- controlled external-test distribution and access, identified build
  provenance, privacy guidance, update/rollback/uninstall behavior, and
  clean-machine install/run evidence.

No numeric success threshold, vendor, legal conclusion, schedule, or gate result
is approved by this brief. (Trace: P10-024-P10-038, P10-051-P10-054.)

## Explicit exclusions and later ownership

- Character Level and XP begin in 1.1 under #50; no Character Levels 1-3 are
  part of 1.0.
- Inventory, equipment, generated items, and Skein implementation begin in 1.1.
- Social expansion begins in 1.2.
- Faction systems begin in 2.0. Before then, persistent characters remain
  `Faction = Unassigned` and Doctrine is unavailable.
- Mandatory mixed-territory PvP and the wider faction world are confirmed
  target features, not 1.0 content.

(Trace: P10-028, P10-039, P10-045, P10-049, P10-050; canonical owners:
[Progression, Loot, and Skein Weaving](progression-loot-and-skein.md) and
[Characters and Factions](characters-and-factions.md).)

## Blocking decisions

| Decision | Owner | Blocking effect |
| --- | --- | --- |
| Target party size | #1/#71 | Party formation, eligibility, travel, content validation, and estimates cannot finalize. |
| First PvE completion condition | #1/#71 | Outdoor and Hollow Choir terminal objective contracts cannot finalize. |
| Exact slice progress and currency identities | #27/#30 with #1/#71 | Persistent schema and reward contracts cannot finalize these fields. |

Resolution requires a reviewed product decision at the named canonical
destination. (Trace: P10-041, P10-042, and the owned TBD register.)
