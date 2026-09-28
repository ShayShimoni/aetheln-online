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

## Skein Build Compilation and Saved Presets

This is a target-state server contract for the 1.1 character-development path,
not a prototype runtime requirement or permission to activate unfinished
content. The character owner persists choices and owned items; the authoritative
game server compiles their executable meaning from an approved, immutable
content snapshot. Clients submit stable IDs and requested changes, never an
effect graph, stat total, hit rule, compiled plan, or claimed validation result.

### Durable Choices and Transient Execution Plan

Durable character truth contains the permanent Order, current specialization,
learned abilities and compatible weapons, unlock ledgers, unlocked Forms,
Threads, Keystones and later Doctrine, selected weave and Heritage state,
saved preset definitions, item-instance ownership and equipped references,
and the independent aggregate versions. It also records the content/manifest
version references needed to interpret a committed choice. It does **not**
store a compiled `BuildExecutionPlan`, temporary GAS handles, active effects,
cooldowns, combat-resource values, pending activations, or client predictions
as durable choices. Runtime recovery reconstructs from committed truth and
authoritative lifecycle records; a client cache cannot repair either.

For the initial implementation, a character may save at most **three** named
presets. This is a bounded implementation limit, not an assertion that three
weaves are simultaneously active or that the eventual product limit is final.
A preset stores selected IDs and explicit item-instance references where the
approved preset policy allows equipment changes, plus its own version; it is
not a copy of owned items, unlocks, entitlement, or an executable plan. A saved
preset can become stale as ownership, unlocks, compatibility, content, or
policy changes. Saving or selecting it is a fenced, idempotent, version-checked
command; selection recompiles and revalidates the entire resulting build.
Missing or invalid references preserve the prior active build. The active
Form, Thread, Heritage, and other slot counts, preset-change location/cost,
and equipment-preset policy remain `TBD` until their owners approve them.

`BuildExecutionPlan` is an immutable, server-only snapshot for one committed
character state and content epoch. It binds the character and relevant state
versions, exact registry/manifest and definition versions, authorized Order,
specialization, learned weapon actions, selected Forms and Keystone,
restricted Threads and Heritage hooks, equipped item effects, and later
Doctrine only when faction choice and eligibility permit it. It contains the
resolved ability and effect definitions, declared writers/listeners, proc
ancestry and finite root budgets, and the activation permissions the server
will enforce. It never grants a missing unlock or changes a permanent Order.
An unspecialized character with an empty weave must still compile its valid
shared Order and learned-weapon base kit; no optional Skein choice may be
required just to play that base kit.

Compilation consumes one closed, versioned registry/content snapshot. The
server resolves each submitted ID and compatible version, checks ownership,
unlock and maturity, specialization and weapon compatibility, equipment
instance ownership and equip rules, unique authoritative writers, listener
targets, cycles, and every aggregate root budget. It permits at most one
selected Form for each ability unless a later explicitly approved
compatible-Form system governs that ability; this rule is independent of the
still-`TBD` total active-slot count. Executable combinations
must be named by a versioned manifest containing the root and **all** attached
members, including Threads, with exactly matching participant references; a
valid individual definition does not authorize an unlisted combination.
Definitions and manifests lacking approved finite limits or the required
implementation maturity cannot become executable.
`TBD` budgets, missing manifests, mixed-version references, unresolved
Heritage/Doctrine eligibility, or unsupported item hooks reject compilation
for the affected choice rather than defaulting to permission. The registry's
design intent alone is not implementation or runtime evidence.

### Atomic ChangeEquipmentAndBuild

`ChangeEquipmentAndBuild` is one semantic durable command for any operation
that must change equipment and the active build together, including preset
selection that changes both. Its request binds character, authenticated
issuer, current lease/fencing epoch, stable idempotency key, expected versions
of **every** affected logical concern, exact proposed IDs/item instances, and
the accepted content epoch. The owner verifies account/character authority,
safe-service and combat-state eligibility under approved policy, item ownership
and equip legality, all unlocks and compatibility, and the fully compiled
candidate before commit. The durable owner revalidates the candidate against
its accepted content snapshot or a verifiable trusted compiler result; it does
not trust a caller's `ValidatedPayload` or claimed plan digest. A client cannot
split one intended equipment/build change into independent writes and observe
an intermediate executable mix.

The game server fences new activations and reaches a server-owned safe switch
boundary before changing the active plan. Already accepted activations and
effects finish or cancel only under their pinned, authored lifecycle rules;
their results cannot be reinterpreted under the proposed plan or erased by a
disconnect. If safe quiescence cannot be established under an approved policy,
the command rejects or defers without changing the durable choices. The
logical owner then atomically commits equipped references, active weave,
selected preset if any, each affected next version, idempotency response,
audit and outbox. A failed validation or transaction leaves the prior durable
state and active plan unchanged. Concurrent proposals with stale expected
versions or stale fencing epochs fail; a duplicate completed key returns its
recorded result, not a second switch.

After a successful commit, the server activates only the candidate matching
the **committed** versions and content epoch, then retires the old plan once
its authorized in-flight work is drained. No activation runs with newly
committed equipment under the old plan, or with old equipment under the new
plan. If the server crashes or loses authority between commit and activation,
admission and combat remain fenced until the current holder reloads the
recorded command result and recompiles from committed truth. A commit is not
silently undone because a local plan swap failed; any reversal is a new
authorized, versioned command. Client disconnect cannot turn a pending
request into a second commit or release an old plan's accepted result.

### Admission Pins, Deny Overlay, and Recovery

Admission pins one mutually compatible schema, registry/manifest, content,
item-rule, and policy version set for the holder's executable plan. The server
checks that set against the durable choices before allowing activation. A
mixed deployment does not silently reinterpret old IDs under new definitions.
Version migration must specify source/target mappings, eligibility,
idempotent per-character progress, dual-read/write window where supported,
and negative tests for changed or removed options before enabling the new
content. No production legacy mapping is assumed here. An unmapped or lossy
choice is quarantined for approved migration or explicitly rejected; it is
never converted into a stronger or free choice by guesswork.

A versioned emergency activation-deny overlay is evaluated by the server at
admission and each new activation, even for a previously pinned plan. It can
remove permission immediately but never add an unlock or rewrite durable
state. Already accepted work follows its authored cancellation and policy
rules; emergency handling must not erase a committed hit or grant. If a pinned
definition becomes denied, the server fences affected activations and tries
only an explicitly approved, fully compilable safe base-kit plan under the
current policy. That degraded plan is transient and cannot mutate presets or
equipment. If no such plan exists, admission or further combat is denied with
a safe reason, while durable choices remain intact for repair. A rollback of
code or content repeats version compatibility and deny checks; it does not
assume that newer committed data can be read by older code or downgrade data
in place.

Required implementation tests cover duplicate and stale keys, two concurrent
equipment/build proposals, stale lease or authority loss before and after
commit, disconnect during an accepted activation, invalid/missing and
cross-version IDs, cyclic or over-budget manifests, conflicting writers,
two Forms selected for one ability without an approved combination rule,
removed item ownership, stale preset selection, denied content during an
in-flight activation, crash between commit and plan activation, migration
failure, and rollback with newer durable data. Each case checks that the
visible committed choice, active plan, recorded response, and accepted combat
results agree. These are test contracts, not a claim that a runtime compiler,
migrations, or packaged tests already exist.

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
