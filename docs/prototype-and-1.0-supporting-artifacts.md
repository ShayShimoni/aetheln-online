# Prototype and 1.0 Supporting Artifacts

## Purpose

These compact artifacts support the
[prototype brief](GameBrief.md), the
[1.0 brief](cooperative-vertical-slice-1.0-brief.md), and the normative
[scope ledger](prototype-and-1.0-scope-ledger.md). They route decisions,
evidence, and verification without replacing canonical product or technical
rules. (Trace: P10-040.)

## Product-decision register

| Decision | State | Owner and destination | Blocking effect |
| --- | --- | --- | --- |
| Target party size | Blocking TBD | #1/#71; both briefs | Party-size-dependent 1.0 implementation is not ready. |
| First PvE completion condition | Blocking TBD | #1/#71; both briefs | Prototype and 1.0 terminal objective contracts cannot finalize. |
| Prototype combat resource identity | Blocking TBD; use only `prototype combat resource` | #1/#71, then #18/#19/#61 | GAS attribute, cost, recovery, and HUD wording cannot finalize. |
| Project template and Starter Content | Approved and verified: Blank C++, no Starter Content | #13 consuming #71 | Bootstrap choice is resolved by recorded approval plus project generation, Editor build, and starter-map launch evidence. |
| Exact 1.0 progress and currency identities | Blocking TBD | #27/#30 with #1/#71 approval | Persistence and reward fields cannot finalize. |
| Toolchains, plugins, vendors, deployment | Evidence-gated TBD | #13/#15/#36 and an accepted ADR | Only dependent implementation is blocked. |
| Numeric tuning, budgets, capacity, retention, schedules, gate thresholds | Evidence/product-gated TBD | #2/#40/#45/#48/#62 and feature owner | No value may be claimed or locked before review. |
| Legal/privacy and regional processing | Qualified-review dependency | #40 plus affected data/service owner | Affected collection or operation is blocked pending review. |

The complete review, evidence, and revisit requirements remain in the ledger's
owned TBD register. (Trace: P10-041-P10-044, P10-051-P10-053.)

## Terminology glossary

| Term | Use in this scope | Authority |
| --- | --- | --- |
| Hollow Choirhouse | A named place in the Glasswake/Duskvigil material; do not silently substitute it for the dungeon name. | P10-049; [World and Settlements](world-and-settlements.md) |
| Hollow Choir | The initial cooperative dungeon containing the Sevrin Vale encounter. | P10-022, P10-049; [World and Settlements](world-and-settlements.md#the-hollow-choir) |
| Ashen Choir | The hostile remnant of the Lucent Choir and enemy of both future player factions. | P10-049; [Characters and Factions](characters-and-factions.md#the-ashen-choir) |
| Lucent Choir | The historical group whose ritual caused the Duskbreak; it is not the current dungeon or player faction. | P10-049; [Game Design Bible](game-design-bible.md) |
| Concord | The old legal and religious structure governing Ember use; it is not identical to the Crowned Ledger (previously recorded as Dawn Concordat). | P10-049; [Characters and Factions](characters-and-factions.md#the-concord) |
| Crowned Ledger | The working player-faction display name for stable ID `faction.crowned_ledger`, superseding Dawn Concordat under Issue #104. Not a final name; final faction naming is owned by #54. | P10-050; [Characters and Factions](characters-and-factions.md#crowned-ledger---working-name) |
| Hundred Witnesses | The working player-faction display name for stable ID `faction.hundred_witnesses`, superseding Unbound Flame under Issue #104. Not a final name; final faction naming is owned by #54. | P10-050; [Characters and Factions](characters-and-factions.md#hundred-witnesses---working-name) |
| Dawn Concordat | Historical working faction name superseded by Crowned Ledger under Issue #104; retained only in historical evidence. | P10-050; [Characters and Factions](characters-and-factions.md#crowned-ledger---working-name) |
| Unbound Flame | Historical working faction name superseded by Hundred Witnesses under Issue #104; retained only in historical evidence. | P10-050; [Characters and Factions](characters-and-factions.md#hundred-witnesses---working-name) |
| Oathscar | The active initial Order/class working label, superseding Skeinblade under Issue #104. Stable ID `order.oathscar`. | P10-050; [Game Design Bible](game-design-bible.md) |
| Skeinblade | Historical class working label superseded by Oathscar under Issue #104; retained only in historical evidence. | P10-050; [Game Design Bible](game-design-bible.md) |

These definitions distinguish existing uses only and add no lore.

## Player and recovery state diagrams

### Prototype life and respawn

```text
Join arena
    |
    v
Alive and server-authorized
    |  valid activation      invalid or stale request
    |---------------------> Server combat timeline
    |                              |
    |                              +--> reject and record telemetry
    v
Server health reaches death
    |
    v
Dead; stale action state cleared
    |
    v
Server-authorized respawn or reconnect recovery
    |
    +--> Alive with authoritative restored state
```

The server owns every transition and completion remains ephemeral. Exact
respawn timing and restored values are tuning TBDs. (Trace: P10-013-P10-017,
P10-052.)

### 1.0 admission, transfer, reward, and recovery

```text
Authenticate -> Select owned character -> Single-use PlayerAdmission
                                            |
                                            v
                                  Acquire current authority lease
                                            |
                                            v
                                  Admit to safe hub
                                            |
                 +--------------------------+-------------------------+
                 | controlled travel                                  |
                 v                                                    |
Validate -> Checkpoint -> Reserve -> Admit destination -> Fence lease |
                 |                                      |             |
                 | failure                              v             |
                 +--> durable retry/reconcile       Release source <---+
                                                        |
                                                        v
                                             Authoritative completion
                                                        |
                                                        v
                                      Atomic reward receipt and outbox
                                                        |
                           +----------------------------+------------------+
                           | retry returns recorded result                 |
                           v                                               v
                    Safe return transfer                     Restore and reconcile
```

A destination is not playable before current authority is held; a stale source
cannot resume mutation authority. Duplicate reward delivery returns the recorded
result rather than granting twice. Restore occurs in isolation and requires
authoritative reconciliation without silent repair. (Trace: P10-023, P10-027-
P10-031, P10-038.)

## Release-content matrix

| Capability | Prototype | 1.0 | 1.1 | 1.2 | 2.0 | 2.1 |
| --- | --- | --- | --- | --- | --- | --- |
| Packaged server-authoritative arena combat and evidence | Deliver | Retain | Retain | Retain | Retain | Retain |
| Minimal character, authentication, safe hub, party, outdoor objective, Hollow Choir, controlled travel | Excluded | Deliver | Retain | Retain | Retain | Retain |
| Approved permanent slice progress and bounded integer currency | Excluded | Deliver | Retain | Retain | Retain | Retain |
| Character Level and XP | Excluded | Excluded | Deliver under #50 | Retain | Retain | Retain |
| Inventory, equipment, generated items, Skein implementation | Excluded | Excluded | Deliver | Retain | Retain | Retain |
| Matchmaking, chat, friends, test administration/account recovery tools | Excluded | Excluded | Excluded | Deliver | Retain | Retain |
| Faction assignment, Doctrine, protected starts, mixed-territory mandatory PvP | Excluded | `Faction = Unassigned`; no Doctrine | Same | Same | Deliver | Retain |
| Capital infiltration, organized invasions, war operations | Excluded | Excluded | Excluded | Excluded | Excluded | Deliver |

"Excluded" means outside that delivery stage, not rejected from the target game.
(Trace: P10-009, P10-018-P10-039, P10-045.)

## Threat and data inventory

The detailed Issue #40 baseline, boundaries, abuse register, risk decisions, and
follow-up specifications are in the [Staged Multiplayer Threat Model](staged-multiplayer-threat-model.md).

| Asset or data | Boundary and principal risks | Owner/evidence |
| --- | --- | --- |
| Source, dependencies, build artifacts, configuration, release provenance | Tampering, vulnerable dependency, secret leakage, incompatible build | #13/#15/#16/#40/#46; P10-004-P10-007, P10-033, P10-054 |
| Prototype movement and combat requests, `CombatActivation`, telemetry | Forged action, replay, stale state, client-claimed result, sensitive log content | #40/#60/#62; P10-016, P10-032, P10-033 |
| Account, character ownership, session, `PlayerAdmission` | Broken object authorization, credential replay/substitution, cross-environment use | #27/#35/#40; P10-027, P10-029, P10-033 |
| Party, checkpoint, transfer, destination reservation | Unauthorized membership, admission replay, stale source, split authority, interrupted transfer | #25/#31/#35/#37/#40; P10-023, P10-025, P10-029, P10-031, P10-033 |
| `CharacterAuthorityLease`, fencing epoch, `PersistentCommand` | Stale-server mutation, version conflict, privilege escalation | #27/#37/#40; P10-027, P10-031, P10-033 |
| Currency, progress, reward receipt, ledger, outbox | Duplicate grant, overflow/underflow, replay, audit loss, inconsistent consumers | #27/#30/#40; P10-027, P10-028, P10-033 |
| Backup, restore, reconciliation, operational evidence | Unrestorable data, silent repair, excessive access/retention, evidence loss | #38/#40/#62; P10-032, P10-033, P10-038 |

This inventory selects no provider, retention period, jurisdiction, or legal
conclusion. Data minimization, access, processing location, and retention remain
subject to the affected owner and qualified privacy/legal review. (Trace:
P10-030, P10-051-P10-053; canonical owner:
[Security and Operations](security-and-operations.md).)

## Test matrix

Detailed adversarial fixtures, authoritative oracles, telemetry, automation
status, and evidence boundaries are in the [Staged Multiplayer Threat Model](staged-multiplayer-threat-model.md#representative-test-plan).

| Requirement | Verification class | Evidence owner |
| --- | --- | --- |
| Packaged server plus two clients complete the prototype scenario | Packaged automation and gate review | #4/#44/#48; P10-010, P10-035, P10-037 |
| Movement, free aim, combat timeline, dodge, death/respawn | Focused automation, network-condition runs, manual readability | #17-#21/#45; P10-011-P10-015, P10-036 |
| Three-hit chain and `CombatActivation` outcomes | Focused deterministic automation | #60; P10-016 |
| HUD authority, correction, rejection, objective and death feedback | Automated state checks plus manual readability/accessibility review | #61; P10-017 |
| Authentication, ownership, admission, party recovery | Security and packaged integration | #3/#31/#35/#40; P10-019, P10-025, P10-029, P10-033 |
| Hub/outdoor/dungeon transfer and safe return | Packaged multi-process, failure injection, recovery | #22-#26; P10-020-P10-024 |
| Atomic progress/currency reward under retry/crash | Transaction, boundary, idempotency, reconciliation | #27/#30/#37; P10-027, P10-028, P10-031 |
| Restore of the implemented 1.0 data set | Isolated restore and authoritative reconciliation | #62; P10-038 |
| External-test distribution, access, build identity, privacy guidance, update/rollback/uninstall, and clean-machine behavior | Packaged clean-machine and lifecycle evidence | #46; P10-054 |
| Performance, network, capacity and gate claims | Evidence-gated measurement and #48 review | #2/#45/#48; P10-003, P10-036, P10-037, P10-052 |
| Legal/privacy-dependent collection or operation | Qualified review before affected use | #40 and affected owner; P10-053 |

Exact scenarios and thresholds stay with their evidence tickets. This matrix
does not mark an unrun check as passed.

## Asset-provenance register

No asset is approved by this template. Each temporary or intended production
asset must receive a row before use or distribution.

The imported non-canonical visual-development package maintains its detailed
records in [`visuals/asset-provenance.md`](../visuals/asset-provenance.md). Those
records supplement this register; repository inclusion does not constitute
creative, production, legal, or runtime approval.

| Asset ID | Source and author | License or permission evidence | Reviewed version/hash | Review status | Owner | Permitted stage/use | Replacement status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| TBD | TBD | TBD | TBD | Pending | TBD | Not approved | TBD |
| Visual-development package | See package provenance register | See package provenance register | See package manifest and provenance register | Imported; non-canonical | #94 and the affected asset owner | Review and production planning only; not approved for Unreal `Content/` | Per-asset review required |

Review status must distinguish pending, approved with scope, rejected, and
expired. Record source files and derived outputs separately when their license,
attribution, or permitted use differs. Provider terms, trademark, personal data,
and regional-processing questions require the applicable qualified review; a
repository entry is not legal approval. (Trace: P10-005, P10-006, P10-007,
P10-053.)
