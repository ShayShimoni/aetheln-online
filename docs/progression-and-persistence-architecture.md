# Progression and Persistence Architecture

## Document Status

This document is the canonical technical specification for durable character
state, authority leases, commands, rewards, currency, transactions, outbox
events, migrations, reconciliation, and staged persistence scope.

Player-facing progression, equipment, loot, and Skein rules remain governed by
[Progression, Loot, Skein Weaving, and Character Creation](progression-loot-and-skein.md).
Player-facing race anatomy and appearance categories remain governed by
[Playable Peoples](playable-peoples.md).
Database and backend products remain candidates until
[Issue #36](https://github.com/ShayShimoni/aetheln-online/issues/36) records an
accepted decision.

## Persistence Invariants

- One logical owner commits each ACID character/economy mutation.
- A game server writes durable state only through validated commands while it
  holds the current character lease and fencing epoch.
- State version, idempotency record, visible mutation, reward receipt when
  applicable, immutable ledger entry, and transactional outbox record commit
  together.
- Retrying a completed command returns its recorded result and never creates a
  duplicate visible grant.
- Commands from a stale server are rejected even if that server has not yet
  observed its lease expiry.
- Analytics, caches, message consumers, and clients never become economy truth.
- Schema, algorithm, table, content, and key versions needed to reproduce a
  decision are recorded.
- Durable integers use explicit bounds and overflow-safe arithmetic.
- Every administrative mutation is authorized, attributed, reasoned, and
  auditable.

## Staged Persistent Scope

### Prototype

The prototype does not require persistent accounts, progression, currency,
inventory, equipment, faction, or rewards. It proves runtime authority,
disconnect behavior, telemetry, and build/test repeatability.

### 1.0 Cooperative Vertical Slice

Persist only the state required to prove the cooperative loop:

- Identity and character linkage.
- Appearance fields required by the vertical slice.
- Permanent progression defined for the slice.
- Bounded integer currency balances and currency reward receipts.
- Session recovery and location/checkpoint state.
- Audit, idempotency, lease, transfer, outbox, and reconciliation records.

The 1.0 reward path grants permanent progress and bounded integer currency. It
does not introduce generated item inventory or equipment.

### 1.1 Character Development

Add:

- Item instances and ownership.
- Inventory containers and equipment.
- Item-power, affix, table, algorithm, and key versions.
- Unlocked and equipped Skein state.
- Expanded reward history, bad-luck state, and item reward receipts.

The 1.1 work extends the transaction, observability, migration, and automation
foundation established in 1.0.

### 2.0 Faction Frontier

- Existing characters persist `Faction = Unassigned` before the faction stage.
- The approved one-time faction choice is a fenced, idempotent durable command.
- Doctrine is unavailable while faction is unassigned.
- Faction progression, Doctrine state, contested resources, banking, objective
  contribution, and PvP reward receipts are added only with their validation
  and abuse controls.

The relationship between Character Level and Doctrine prerequisites remains an
open design decision. The persistence schema must not encode an assumed rule.

### 2.1 Faction War

Add versioned invasion contribution, reward, and temporary world-state records
without allowing capital outcomes to remove permanent character progress or
essential services.

## Character Aggregate Separation

The logical model separates:

| Logical concern | Examples | Independent concerns |
| --- | --- | --- |
| Identity | Character ID, account link, name | Ownership and naming policy |
| Appearance | Separately typed race and sex choices, body, constrained visual height, age presentation, face, skin, markings, voice, race features | Presentation only; race and sex never grant combat or Heritage access |
| Permanent progression | Character Level, experience, progression unlocks | Never seasonal; no specialization or weapon XP |
| Seasonal progression | Ember Rank and cycle identity | Compression/reset policy |
| Order and specialization | Permanent Order, current specialization, free-reset entitlement, learned abilities and compatible weapons, Order-mastery unlock ledger | Order and weapon access, rite choice, and atomic reset validation; mastery is not XP |
| Heritage | Learned traditions and equipped Heritage state | Race-independent unlock and effect validation |
| Skein | Forms, Threads, Keystone, equipped weave | Loadout validation independent of Order-choice persistence |
| Faction and Doctrine | `Unassigned` or faction identity, Doctrine unlocks/loadout | One-time choice and faction rules |
| Inventory and equipment | Item instances, containers, equipped slots | Begins in 1.1 |
| Cosmetics | Owned and equipped presentation | No combat authority |
| Session and location | Admission, instance, checkpoint, transfer | Ephemeral and recoverable |

Separation does not require a database or service per row. It requires explicit
ownership, independently versioned logical concerns, validation, and the
ability to evolve one concern without silently changing another, even when
several concerns are physically co-stored. A command changing more than one
concern checks their expected versions and commits their new state and versions
atomically; co-storage is not permission to overwrite unrelated concerns.

Race, sex, appearance, and cosmetics never feed authoritative attributes,
collision, reach, timing, loot probability, faction eligibility, or class
eligibility.

`RaceFeatures` is validated as a race-discriminated appearance block rather
than a shared list of nullable fields:

- Aurin store hair style, hair color, and hair-dye treatment.
- Kell store crown, mantle, mineral family, mineral finish, wear, engraving,
  and inlay.
- Vesh store hair, veil form, veil adornment, inner-light hue, and light
  pattern.

The exact transport and storage shape remains an implementation decision. The
semantic contract must reject fields that do not belong to the selected race
and must keep all appearance data outside combat, class, faction, progression,
and equipment authority.

Portable cultural pigments and adornment styles use shared marking, cosmetic,
or equipment data rather than a race-restricted feature field.

### Order, Specialization, and Heritage Commands

Order is a visible, permanent creation-time choice. The owner validates it at
creation and never treats a specialization reset or session transfer as an
Order change. Before specialization, the character's shared Order/learned
weapon kit remains valid without a selected specialization. Weapon traditions
are discrete compatible unlocks, not a weapon XP counter. Order mastery is an
idempotent, versioned unlock ledger, not a parallel experience or level track;
specialization has no XP track either. Unlock eligibility and learned Heritage
state are server-owned. Mender's Brace, Memory Nail, and Foreseen Path have the
same learnability and authoritative behavior for every race and sex; cultural
origin or appearance cannot grant an unlock or select a stronger effect.
Potential Order, specialization, or faction eligibility rules remain `TBD` and
must never create a race- or sex-specific exception.

The solo specialization rite is `Peaceful` and uses fixed temporary kits. Its
temporary equipment view and trial actions cannot write inventory, currency,
progression, any reward grant or receipt, or Order-mastery entries; practice
feedback is non-granting. Entry is a server-atomic safe transition that fences
new outside actions and resolves already accepted hits, effects, and other
consequential outcomes before capturing the exact pre-entry values for state
the trial may override, including loadout, combat state, and temporary effects.
If pending outcomes, expiry, or cooldown state cannot be resolved or preserved,
entry fails closed. Every terminal path, including success, abandonment,
failure, disconnect, and process recovery, restores trial-overridden state
before normal admission; it cannot erase committed outcomes or revive effects
expired under the approved time policy. No trial-only state may escape or be
accepted as a durable item or unlock. The snapshot and recovery mechanism must
survive the relevant failure modes, or fail closed while the pre-entry
authoritative state is recovered. A missing snapshot never licenses a guessed
restore or a specialization grant. Whether engaged players may enter, whether
rite time pauses outside durations, and absolute expiry/cooldown treatment are
product `TBD`s. Until approved, the server cannot admit a state whose elapsed
authoritative outcomes it cannot preserve. Tests must cover a pending accepted
hit, an effect or cooldown expiring across entry/exit, and disconnect and crash
recovery. The committed specialization choice follows validated successful exit
as a separate durable decision; it cannot implicitly commit trial state.

The owner records one early free-specialization-reset entitlement and consumes
it in the same fenced, version-checked, idempotent transaction that changes the
specialization and compatible loadout, including all affected logical versions
even if their records are co-stored. A duplicate command returns its recorded
result; concurrent or stale commands cannot obtain another free reset. The
early eligibility boundary is `TBD`. Once the free entitlement is spent or
ineligible, a later change requires an approved trainer and currency policy;
the trainer/location, currency, cost, and restrictions remain `TBD`, so no
undefined default authorizes a change. Order, weapon unlocks, Heritage,
Character Level, and prior mastery entries remain unchanged by a reset.

These are target-state contracts, not a new prototype persistence dependency.
The prototype stays a fixed Oathscar sword-and-shield character without the
rite, weapon-learning or Heritage persistence, Order-mastery ledger, or
inventory. The release stage that first enables each durable command must
specify its migration, authority checks, and recovery evidence before use.

## Versioning Model

Every durable aggregate has:

- Stable aggregate identity.
- Monotonic state version.
- Schema version.
- Created/updated audit metadata.
- Owning command or transaction identity for the latest change where useful.

Commands use optimistic concurrency through `ExpectedStateVersion`. Successful
mutation advances the state version exactly once. A version conflict returns the
current safe result or requires the caller to reload; concurrent state is never
replaced blindly.

Gameplay decisions also record the immutable data versions that affected them:

- Ability/content version.
- Progression and policy version.
- Reward algorithm and table version.
- Server-only random key version, never the key.
- Item budget and affix rule version.

## CharacterAuthorityLease Contract

Only one active game-server holder may issue character mutations.

| Field | Requirement |
| --- | --- |
| `CharacterId` | Durable aggregate identity |
| `HolderInstanceId` | Authorized game-server instance |
| `FencingEpoch` | Monotonically increasing authority generation |
| `StateVersion` | Character version observed when authority was acquired |
| `ExpiresAt` | Bounded lease lifetime |
| `LeaseVersion` | Concurrency/version field for renewal |
| `SchemaVersion` | Contract compatibility version |

Rules:

- Acquisition and transfer allocate a fencing epoch greater than every prior
  epoch for that character.
- Renewal can extend the same epoch only for the current authenticated holder.
- Every durable command includes the epoch; the persistence owner rejects an
  older epoch even if the stale server still believes its lease is valid.
- Expiry prevents further commands but does not alter durable state.
- Release is idempotent and cannot release a newer holder's lease.
- Reconnect and regional transfer follow explicit admission and transfer state
  machines; a client assertion cannot move the lease.

## PersistentCommand Contract

`PersistentCommand` is the vendor-neutral boundary for a game server or approved
service to request a durable mutation.

| Field | Requirement |
| --- | --- |
| `IdempotencyKey` | Stable key in a documented caller/operation scope |
| `CharacterId` | Target aggregate identity |
| `LeaseEpoch` | Current fencing epoch when game-server authority is required |
| `ExpectedStateVersion` | Optimistic concurrency precondition |
| `CommandType` | Versioned allowlisted semantic operation |
| `ValidatedPayload` | Bounded typed data, never arbitrary storage mutation |
| `IssuerIdentity` | Authenticated service/workload and instance identity |
| `CorrelationId` | Trace and audit correlation |
| `SchemaVersion` | Contract compatibility version |

The owner revalidates authorization, lease, versions, bounds, state transition,
and command-specific invariants. "Validated" describes the contract shape; it
does not permit trusting the caller's conclusion.

Idempotency is scoped and retained at least as long as a replay could otherwise
create a duplicate visible result. Final retention becomes an operational
decision based on protocol and audit requirements.

## Mutation Transaction

For one logical mutation, the authoritative owner atomically commits:

1. Current aggregate state and next state version.
2. Idempotency key and immutable recorded response.
3. Reward receipt when the command grants a reward.
4. Immutable currency/item/progression ledger entry as applicable.
5. Transactional outbox record for downstream consumers.
6. Audit metadata needed to explain the result.

The transaction either becomes visible in full or does not become visible.
Publishing analytics or a message is not part of the synchronous success path;
the committed outbox is.

Where a future workflow crosses owners, it uses a durable state machine with
idempotent compensating or completion behavior. It does not pretend a
distributed set of unrelated writes is one ACID transaction.

## Currency

Currency definitions are versioned data with:

- Stable currency identity.
- Signedness policy.
- Minimum and maximum balance.
- Allowed source and sink command types.
- Transferability and seasonal policy.
- Audit and reconciliation classification.

All arithmetic is checked before commit. A balance cannot overflow, underflow,
become negative when prohibited, or exceed a cap through concurrent retries.
Each delta records source/sink identity, previous and resulting balance,
transaction, command, character, and reason.

No client command directly sets a balance. Administration uses a separate
restricted grant/reversal path with approval and audit rules.

## RewardReceipt Contract

`RewardReceipt` is the immutable result for one eligible reward event and
character.

| Field | Requirement |
| --- | --- |
| Reward identity | Unique event/character key and receipt identity |
| `CharacterId` | Recipient identity |
| Source | Encounter/objective/source identity and type |
| Versions | Algorithm, table, content, policy, and server-only key version |
| Effective input | Canonical snapshot or stable hash plus retained reproducible inputs |
| Eligibility | Server-observed contribution and validation result |
| Committed result | Permanent progress, bounded currency, or items allowed by the release stage |
| `TransactionId` | Owning ACID transaction |
| State versions | Previous and committed aggregate versions |
| Status | Committed or explicit non-grant terminal result |
| `SchemaVersion` | Contract compatibility version |

The receipt never stores or exposes the secret random key. The same eligible
event/character key returns the same committed result. A rejected or ineligible
event cannot be replayed with client-changed inputs to manufacture eligibility.

## Deterministic Reward Processing

The authoritative owner:

1. Validates source completion and server-observed eligibility.
2. Looks up an existing receipt by event/character identity.
3. Loads the exact versioned reward rules.
4. Derives server randomness from stable event data and a server-only key when
   randomness is part of the stage.
5. Validates bounded progression, currency, item, affix, and state results.
6. Commits result, receipt, state, ledger, idempotency, and outbox atomically.
7. Returns the recorded receipt.

At 1.0 the result is restricted to permanent progression and bounded integer
currency. Item generation begins in 1.1 with the complete inventory/equipment
transaction boundary.

## Transactional Outbox

The outbox contains immutable facts produced by the committed transaction, for
example:

- Progression advanced.
- Currency granted or spent.
- Reward committed.
- Item created/equipped from 1.1.
- Faction selected from 2.0.
- Transfer checkpoint committed.

Consumers use event identity and consumer checkpoints to process at least once
without producing duplicate effects. Analytics, notifications, achievements,
and operational detection consume outbox facts asynchronously.

An outbox consumer cannot mutate the owning aggregate by editing the event. Any
follow-up change returns through an authorized idempotent command.

## Cache and Messaging Boundaries

- A cache may accelerate reads, leases, or routing only if the selected design
  preserves the durable owner and fencing guarantees.
- Cache loss must not create currency, items, progression, or authority.
- Message delivery may duplicate, delay, or reorder events; consumers are
  designed accordingly.
- A queue acknowledgment is not proof that character state committed.
- Database, cache, and message products remain vendor-neutral candidates.

## Migrations

Every schema change defines:

- Source and target schema versions.
- Forward application and compatibility window.
- Backfill or lazy-upgrade behavior.
- Read/write behavior during mixed deployment versions.
- Validation queries or invariants.
- Failure, retry, and forward-fix strategy.
- Backup and restore preconditions.
- Audit and completion evidence.

A lossy migration requires explicit approval and a tested recovery path.
Application rollback must account for data already committed by the newer
version.

Migration code is idempotent where possible and records per-batch progress.
Production recovery objectives remain `TBD` until
[Security and Operations](security-and-operations.md) evidence establishes
them.

## Reconciliation

Reconciliation compares authoritative records, not analytics estimates:

- Aggregate state versus immutable ledger totals.
- Reward receipts versus visible grants.
- Idempotency records versus committed responses.
- Outbox records versus consumer checkpoints.
- Current lease versus active instance/session records.
- Transfer terminal state versus source/destination authority.
- Inventory ownership versus equipment references from 1.1.

Discrepancies produce a quarantined, attributable operational case. Automated
repair is limited to proven idempotent completion rules. Economy grants or
reversals require restricted administrative commands and audit.

## Failure-Injection Requirements

Automated or repeatable tests fail the workflow:

- Before and after idempotency lookup.
- Before commit and immediately after commit.
- Before outbox dispatch and after duplicate dispatch.
- During currency arithmetic and version conflict.
- During reward generation and receipt return.
- During lease acquisition, renewal, transfer, expiry, and stale-server write.
- During checkpoint, destination admission, and source release.
- During migration batches and reconciliation.
- During database, cache, message, and game-server restarts.

Acceptance requires exactly-once visible state, not exactly-once network
delivery. The recorded response and audit trail must explain every terminal
outcome.

## Security and Privacy

- Access is least privilege by service and environment.
- Character identifiers used in telemetry follow the privacy classification and
  retention policy.
- Reward seeds, signing material, database credentials, and workload keys never
  appear in receipts, client errors, or ordinary logs.
- Read paths enforce account/character object authorization.
- Data access, correction, retention, and end-of-retention requirements are
  designed before production personal data is collected; legal jurisdiction
  and retention remain `TBD`.

Detailed controls live in
[Security and Operations](security-and-operations.md).

## Open Decisions

- Backend framework, database, cache, and message products.
- Logical-owner service decomposition after the Issue #36 spike.
- Exact permanent progression and currency included in the 1.0 slice.
- Character Level and Doctrine prerequisite relationship.
- Retention periods for idempotency, receipts, ledger, audit, and outbox.
- Trading, binding, mail, crafting, salvage, and player-to-player economy.
- Migration tooling and production recovery objectives.

No open decision changes the authority, transaction, fencing, idempotency, or
audit invariants in this document without a reviewed architecture decision.
