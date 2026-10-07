# Security and Operations

## Document Status

This document is the canonical technical security and operations baseline. It
defines trust boundaries and required controls without selecting identity,
hosting, anti-cheat, database, cache, message, or observability vendors.

[Issue #40](https://github.com/ShayShimoni/aetheln-online/issues/40) owns the
ranked multiplayer threat model and representative abuse tests.
[Issue #36](https://github.com/ShayShimoni/aetheln-online/issues/36) owns
vendor evaluation. Open risks and accepted exceptions require an owner,
evidence, and revisit trigger.

## Security Principles

- Treat every player device, packet, client clock, and client-provided gameplay
  value as untrusted.
- Authenticate the actor, authorize the specific object and function, validate
  current state, and enforce resource bounds for every consequential command.
- Give game servers and backend components short-lived, scoped workload
  identity; do not share one privileged service key.
- Make replay-sensitive credentials single use and short lived.
- Keep combat, territory, progression, reward, item, and economy outcomes server
  authoritative and observable.
- Use defense in depth. Anti-cheat augments server validation and detection; it
  never replaces them.
- Fail closed for identity, authorization, policy, version, lease, and durable
  mutation uncertainty.
- Minimize collected personal data and redact operational output by default.
- Exercise restore, reconciliation, credential rotation, and incident response
  before production depends on them.

## Threat-Model Method

The project uses data-flow and trust-boundary threat modeling informed by:

- [OWASP Threat Modeling](https://owasp.org/www-project-threat-modeling/)
- [OWASP API Security Top 10 2023](https://owasp.org/API-Security/editions/2023/en/0x11-t10/)
- [NIST Secure Software Development Framework](https://csrc.nist.gov/projects/ssdf)

For each release gate:

1. Identify valuable assets and safety properties.
2. Diagram data flows, actors, trust zones, stores, and external dependencies.
3. Enumerate abuse cases at every boundary.
4. Rank likelihood, impact, detectability, and cost to exploit.
5. Name preventive, detective, and recovery controls.
6. Assign tests, telemetry, an owner, accepted residual risk, and revisit
   trigger.
7. Re-review when topology, vendors, contracts, or gameplay value changes.

Threat modeling covers the game client, edge/admission, game servers, backend
services, data systems, admin plane, build/release chain, observability,
third-party integrations, and support processes.

## Protected Assets

- Account and character ownership.
- Session, admission, transfer, and workload credentials.
- Character authority leases and fencing epochs.
- Movement and combat integrity.
- Faction, territory, sanctuary, and invasion policy.
- Permanent progression, seasonal progression, currency, resources, items, and
  reward receipts.
- Server-only reward keys and signing material.
- Personal data and support records.
- Administrative access and economy-grant capability.
- Source, dependencies, build outputs, release provenance, and update channel.
- Audit evidence, backups, and reconciliation state.

## Required Abuse Cases

The ranked threat model includes at minimum:

- Broken object-level authorization across accounts, characters, items,
  receipts, parties, transfers, and support cases.
- Broken function-level authorization for grants, policy changes, allocation,
  moderation, and administration.
- Resource exhaustion through admissions, connections, packets, expensive
  queries, chat, allocation, reward retries, and world actions.
- Unsafe trust of third-party identity, webhooks, allocation responses,
  moderation results, or SDK callbacks.
- Stolen, replayed, expired, substituted, or cross-environment credentials.
- Forged movement, aim, hit, block, dodge, cooldown, damage, death, faction,
  territory, loadout, item, reward, banking, and transfer commands.
- Stale game-server authority and split-brain character writes.
- Reward replay, integer boundary abuse, collusion, kill trading, repeat-victim
  farming, and contested-resource manipulation.
- Sanctuary bypass through projectiles, areas, summons, periodic effects,
  knockback, reconnect, or policy-version mismatch.
- Protected-start and capital-topology traversal abuse.
- Admin-account takeover, unauthorized grants, missing attribution, log
  tampering, and support impersonation.
- Dependency, build-runner, artifact, signing, plugin, and update-channel
  compromise.

## Identity and Account Boundary

The selected identity provider remains a candidate. The adapter must:

- Validate issuer, audience, signature, expiry, nonce/state, and environment.
- Map external identity to an internal stable account identity.
- Avoid using email, display name, or provider username as authorization.
- Support revocation and compromised-account response.
- Separate authentication from character ownership authorization.
- Keep provider tokens out of game-server logs and persistent gameplay records.
- Define account-linking and recovery abuse controls before those features ship.

The player client never receives backend service credentials or direct database
access.

## PlayerAdmission Contract

`PlayerAdmission` is a short-lived, single-use capability for one destination.

| Field | Requirement |
| --- | --- |
| `AdmissionId` | Unique identity and single-use record |
| `AccountId` | Authenticated internal account |
| `CharacterId` | Character authorized for that account |
| `SessionId` | Current logical play session |
| `DestinationInstanceId` | Exact authorized instance |
| `BuildVersion` | Supported packaged build identity |
| `ProtocolVersion` | Compatible network/service protocol |
| `ContentVersion` | Required authoritative content set where applicable |
| `ExpiresAt` | Short bounded lifetime |
| `Nonce` | Unpredictable replay-resistant identity |
| `Issuer` and `Audience` | Authorized admission issuer and destination |
| `SchemaVersion` | Contract compatibility version |

The credential is integrity protected by the selected mechanism and transmitted
only over an authenticated confidential channel. Logs retain a redacted
admission reference, not bearer material.

The destination atomically consumes admission after verifying account,
character, session, instance, build/protocol/content versions, expiry, nonce,
issuer, and audience. Substitution or replay fails closed and emits a safe,
correlated security event.

Admission does not itself grant durable character mutation. The destination also
acquires the current
`CharacterAuthorityLease` defined in
[Progression and Persistence Architecture](progression-and-persistence-architecture.md).

## Service and Workload Authorization

Each deployed workload receives an environment-scoped identity and explicit
capabilities. Authorization considers:

- Service role.
- Instance or workload identity.
- Environment.
- Allowed audience and operation.
- Character lease/fencing epoch when applicable.
- Region, instance, or administrative scope.
- Build/protocol compatibility.
- Credential age and revocation state.

A game server may submit validated commands only for the instances and
characters it currently owns. Analytics and observability workloads have no
grant capability. Support tools use a separate restricted administrative API,
not game-server endpoints or direct data-store access.

Credential issuance, renewal, rotation, revocation, and failure behavior must be
automated and tested. Network allowlists may reduce exposure but are not the
authorization decision.

## API and Command Controls

Every externally or internally callable operation defines:

- Authentication and object/function authorization.
- Typed input schema, length/range limits, and canonicalization.
- Idempotency and replay behavior.
- Concurrency and state-version requirements.
- Rate and resource budgets.
- Timeout, cancellation, pagination, and maximum response size.
- Safe client error and richer redacted internal audit event.
- Version compatibility and retirement policy.

Bulk and search operations require tighter bounds than point reads. Indirect
object references are checked against the authenticated account or workload
scope. An opaque identifier is not authorization.

Third-party responses are untrusted input. Webhooks and callbacks verify origin,
integrity, replay state, schema, object ownership, and allowed state transition
before producing any internal command.

## Replay Protection

Replay-sensitive paths use the control appropriate to their semantics:

- Single-use nonce and consumption record for player admission.
- Monotonic sequences and bounded timing for gameplay input.
- Idempotency key and recorded result for persistent commands.
- Fencing epoch for character authority.
- Unique event/character key for reward receipts.
- Durable terminal state for regional transfer.
- Signed/versioned callback identity and delivery record for third-party events.

A duplicate may return the already committed safe result. It must not repeat the
visible effect.

## Resource Limits and DDoS Boundary

Controls are layered:

- Upstream provider and network-edge volumetric protection when a hosted
  environment exists.
- Connection, handshake, authentication, and admission limits before game
  allocation.
- Per-source, account, session, character, instance, operation, and service
  limits where meaningful.
- Packet size, frequency, sequence-window, and parsing budgets.
- Query complexity, result size, concurrency, and timeout limits.
- Bounded queues, circuit breakers, load shedding, and backpressure.
- Allocation quotas and admission refusal before unsafe oversubscription.

Application rate limiting is not volumetric DDoS protection. A future hosting
decision must document which layer absorbs network floods, who owns escalation,
and how source addresses and trusted proxy metadata are validated.

Limits begin as explicit hypotheses and become approved only after legitimate
traffic and abuse tests. A limit response is observable and avoids revealing
detection thresholds that aid evasion.

## Gameplay Integrity and Anti-Cheat

The authoritative server validates:

- Movement and rotation feasibility.
- Ability prerequisites, timing, resources, and cooldowns.
- Authored attack volumes and contact.
- Block, dodge, interruption, crowd control, death, and respawn.
- Faction, territory, sanctuary, objective, and invasion eligibility.
- Skein, Doctrine, inventory, equipment, item-stat, and reward rules.
- Contribution, repeat-victim, collusion, banking, and contested-resource rules.

Client integrity or commercial anti-cheat may add tamper detection and
investigation signals after an evidence-based selection. It does not authorize a
hit or make an impossible command valid.

Enforcement separates:

- Immediate authoritative rejection.
- Risk signals and confidence accumulation.
- Human review where required.
- Temporary containment or account action under an approved policy.
- Appeal, correction, and evidence retention.

Do not reveal server-only random keys, exact detection features, or sensitive
thresholds in client errors or routine logs.

## Secret and Key Management

- Secrets stay outside source control, committed examples, build logs, crash
  reports, telemetry, client packages, and content assets.
- Each environment and workload uses separate least-privilege material.
- Central secret storage and workload delivery remain vendor candidates.
- Rotation and emergency revocation are documented, automated, and exercised.
- Signing and reward keys carry explicit version identities; records store the
  version, never key material.
- Development uses non-production identities and data.
- Secret scanning runs locally where practical and in CI.
- Any exposure follows an incident runbook that rotates affected material and
  investigates use.

No service starts with a missing secret by silently choosing a weak default.

## Administrative Security

The admin plane is separate from player and game-server APIs.

Required controls:

- Strong administrator authentication and phishing-resistant multi-factor
  authentication when the platform supports it.
- Role and environment separation.
- Least privilege and time-bounded elevated access.
- Reauthentication or dual approval for high-impact economy, account, policy,
  and release actions as risk requires.
- Immutable attribution: administrator, reason, ticket/case, target, previous
  state, resulting state, time, and correlation.
- Bounded allowlisted commands rather than arbitrary data-store access.
- Alerting and periodic review of grants, reversals, identity changes, and
  permission changes.
- Tested break-glass access with post-event review.

Test administration in 1.2 does not weaken the underlying command and audit
boundary established earlier.

## Observability and Audit

Security-relevant events include:

- Authentication, admission, replay, and version rejection.
- Workload identity and authorization failure.
- Stale lease/fencing commands.
- Invalid movement, ability, combat, faction, policy, loadout, reward, and
  transfer claims.
- Rate and resource-limit action.
- Reward, currency, item, banking, and administrative mutation.
- Dependency, backup, restore, reconciliation, and release-policy failure.

Events use correlation, account/character pseudonymous identifiers where
appropriate, instance, build/protocol/content versions, policy version, command
identity, and a safe reason code. They exclude bearer material, personal
message content unless explicitly required and governed, server random keys,
and unrestricted payloads.

Audit data has integrity, access, retention, and time-synchronization controls.
Monitoring data cannot be used as an alternative authority store.

## Privacy and Data Governance

Before external playtesting, inventory:

- Personal and pseudonymous data collected.
- Purpose and legal basis by applicable jurisdiction.
- Storage and processing locations.
- Access roles and third parties.
- Retention and end-of-retention handling.
- User access, correction, portability, and account-closure workflows where
  required.
- Backup propagation and legal-hold behavior.

Collect only data required for the feature, security, operation, or legal
obligation. Do not place personal data in high-cardinality metrics labels or
unbounded logs. Production policy remains `TBD` until jurisdictions and service
providers are selected.

## Backup, Restore, and Reconciliation

The production design must define and test:

- Data inventory and criticality.
- Backup scope, frequency, retention, isolation, encryption, and access.
- Point-in-time recovery where required.
- Restore into an isolated environment.
- Application/schema compatibility.
- Integrity and reconciliation after restore.
- Credential and key dependencies.
- Game admission and economy freeze/degradation behavior during recovery.

Recovery point objective and recovery time objective remain `TBD`; they cannot
be inferred from a vendor default. A restore drill records date, versions,
dataset size, elapsed phases, verification, exceptions, owner, and follow-up
work.

Backups do not replace immutable ledgers, reward receipts, idempotency, or
reconciliation.

## Incident Response

Runbooks cover at minimum:

- Account or administrator compromise.
- Admission or workload credential exposure.
- Economy duplication or unauthorized grant.
- Stale-server or split-authority behavior.
- Sanctuary/protected-start bypass.
- Widespread cheating or denial of service.
- Data integrity, availability, or privacy incident.
- Compromised dependency, build runner, artifact, or signing path.

Each runbook names detection, triage, containment, evidence preservation,
communication, recovery, validation, escalation, and post-incident review.
High-impact containment commands are rehearsed in a non-production environment.

## Supply-Chain and Release Controls

Following the NIST SSDF baseline:

- Inventory direct and transitive source, binary, plugin, SDK, toolchain, and
  build-image dependencies.
- Pin versions and verify integrity through the ecosystem's supported
  mechanism.
- Generate an SBOM for releasable builds when tooling exists.
- Scan source, dependencies, packages, and build configuration under a
  documented policy.
- Use isolated, least-privilege build identities and protected release
  credentials.
- Record source revision, engine/toolchain, dependencies, build inputs, tests,
  and artifact digests as provenance.
- Sign release artifacts and verify them in the delivery path when the selected
  platform supports it.
- Review updates deliberately; automated version changes do not bypass build,
  test, compatibility, or security gates.
- Define emergency response for a vulnerable engine, plugin, SDK, or package.

The exact scanner, SBOM format, signing service, and release platform remain
vendor/tooling decisions.

Internal pre-release packages
([TA-022](architecture-decisions.md#ta-022---dispatch-only-release-packaging-on-a-separate-workflow-identity))
are built only on the owner's self-hosted runner, from an exact release head,
with read-only workflow credentials. Only redacted evidence reports leave the
runner; packaged bytes are never published, because release assets on this
public repository are world-downloadable. Their integrity rests on no
untrusted code ever running on that runner, so a workflow run from a fork pull
request is never approved while it is registered. Publishing packaged bytes
anywhere needs its own reviewed decision covering a path-leak scan, licensing,
signing, and that runner-trust risk.

## Required Security Tests

Automated or repeatable scenarios cover:

- Stolen, expired, replayed, substituted, and wrong-destination admission.
- Account/character and object/function authorization failures.
- Invalid and excessive gameplay commands.
- Forged hit, dodge, block, cooldown, faction, territory, loadout, reward, and
  transfer claims.
- Stale leases and concurrent servers.
- Currency boundaries, reward retries, collusion, and duplicate outbox delivery.
- Sanctuary and capital protection through every hostile-effect family.
- Rate limits, queue pressure, dependency timeouts, and admission load shedding.
- Secret and personal-data leakage checks in artifacts and observability.
- Unauthorized admin access and grant/reversal audit.
- Backup restore and authoritative reconciliation.
- Dependency inventory, policy, provenance, and artifact integrity.

Security tests join the same stage gates as functional and performance
evidence; a later security review cannot compensate for a missing authority
boundary in the prototype.

## Open Decisions

- Identity provider and account-recovery policy.
- Edge, DDoS, hosting, orchestration, and workload-identity providers.
- Anti-cheat technology and enforcement policy.
- Secret, signing, audit, observability, and incident platforms.
- Applicable privacy jurisdictions and retention schedules.
- Production RPO, RTO, backup frequency, and restore-drill cadence.
- Administrative approval thresholds and break-glass policy.

Selections require evidence, an owner, rejected alternatives, and a revisit
trigger in [Architecture Decisions](architecture-decisions.md).
