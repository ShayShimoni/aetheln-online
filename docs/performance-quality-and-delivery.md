# Performance, Quality, and Delivery

## Document Status

This document is the canonical technical specification for performance budgets,
profiling evidence, automation, CI, observability, scalability validation, and
stage exit criteria.

[Issue #45](https://github.com/ShayShimoni/aetheln-online/issues/45) owns measured
client, server, and bandwidth budgets.
[Issue #44](https://github.com/ShayShimoni/aetheln-online/issues/44) owns
multiplayer automation.
[Issue #16](https://github.com/ShayShimoni/aetheln-online/issues/16) owns CI
execution, runner requirements, and evidence publication.
[Issue #48](https://github.com/ShayShimoni/aetheln-online/issues/48) owns the
recorded go/no-go evaluation for each stage.

## Quality Principles

- Establish build, test, rejection telemetry, and performance instrumentation
  in the prototype; later stages expand their coverage.
- Treat editor-only success as development feedback, not packaged-build
  evidence.
- Label every capacity, tick, bandwidth, and cost value as measured, modeled, or
  hypothetical.
- Compare changes using the same scenario, actor mix, build configuration,
  hardware, topology, network profile, and capture method.
- Automate deterministic rules at the lowest reliable level and add
  multi-process coverage when behavior crosses process boundaries.
- Preserve exact command output and evidence references for stage decisions.
- A calendar target does not pass a release gate.

## Initial Client Target

The first client baseline targets:

- 1920 x 1080 presentation.
- 60 frames per second.
- Current development PC: Intel Core i7-9750H, NVIDIA RTX 2060, and 32 GB RAM.

This is a baseline target for the current project environment, not the final
minimum or recommended specification. The capture records quality settings,
resolution scale, display mode, driver, operating system, thermals where
relevant, map, player/AI/effect mix, duration, and packaged build identity.

Issue #45 converts the target into measured game-thread, render-thread, GPU,
memory, streaming, and hitch budgets. No subsystem budget is invented before
the representative capture.

## Initial World-Combat Hypothesis

Planning may use:

- 32 players for the initial representative world-combat hypothesis.
- 64 players for a stress test.

These are experiment sizes, not approved regional or instance capacity.
Player capacity, server tick, actor count, and bandwidth become canonical only
after Issue #45 records measurements and an accepted decision. Tests include
representative AI, projectiles, persistent areas, objectives, policy state, and
combat activity rather than idle connected clients.

## Budget Registry

Issue #45 maintains a versioned registry with:

| Domain | Required measurements |
| --- | --- |
| Client frame | Game thread, render thread, GPU, frame pacing, hitches |
| Client memory | Working set, UObject/assets, streaming peaks |
| Loading/streaming | Startup, travel, map load, streaming stalls |
| Server simulation | Game thread, worker tasks, tick duration, overruns |
| Replication | CPU, relevant actors, properties/events, corrections |
| Server memory | Base process, per player, AI, projectiles, areas, instances |
| Network | Per-player and aggregate send/receive, bursts, packet loss impact |
| Backend | Latency, throughput, error rate, saturation, queue depth |
| Persistence | Transaction latency, conflicts, retries, outbox lag |
| Build/cook | Compile, cook, package time, artifact size |

Every budget includes target, warning threshold, failure threshold, capture
method, scenario, owner, evidence link, and approval status. Until measured, the
entry is explicitly `TBD`.

The first executable Issue #45 wave adds an opt-in, versioned
`aetheln.performance-capture-contract` (version 1) to the network-authority
runner via `PerformanceContractPath`; its exact shape and fail-closed rules are
specified in
[Networking Authority Spike](networking-authority-spike.md#issue-45-opt-in-performance-capture-and-budget-contract).
The contract binds future capture evidence to the exact source revision,
packaged-build identity, toolchain, hardware, topology, environment, map,
duration, actor mix, scenario, network profile, and evidence references, and
carries one budget record per version-1 network-authority-runner subset metric
with metric identity and domain, target, warning threshold, failure threshold,
measurement method, scenario, accountable owner, evidence references, an
evidence classification (`measured`, `modeled`, `hypothetical`, or `unset`),
and an approval status. In this wave every target, warning threshold, failure
threshold, capacity, tick rate, sampling rate, bandwidth value, and
player-count value remains `null`/`TBD`, and every budget remains
`unapproved`: fixture evidence validates the contract but cannot approve or
canonicalize any budget. Mismatched identity, populated numeric values,
duplicate or missing budgets, undeclared evidence references, and self-approved
entries fail closed before launch. Each accepted run retains the exact validated
contract bytes and publishes their SHA-256 plus the fixed artifact name so later
review can detect replacement or drift without exposing raw evidence references
in the summary. This bounded subset does not replace or complete the broader
Issue #45 registry above; the remaining client timing, frame-pacing, hitch,
loading/streaming, server worker/tick-overrun/failure, and network burst/loss
domains require later representative capture work.

## Evidence Record

Each performance or scalability result records:

- Date and owning issue.
- Source revision and packaged build/configuration.
- Exact Unreal Engine source revision, compiler, SDK, and plugins.
- Client and server hardware/operating system.
- Process-to-host topology and environment.
- Map, scenario, duration, warm-up, player count, faction mix, and actor mix.
- Network profile.
- Content, policy, protocol, and schema versions where relevant.
- Unreal Insights, Networking Insights, service, and host capture references.
- Median, percentile, worst-case/hitch, and failure behavior appropriate to the
  metric.
- Measured limitations and follow-up work.

A screenshot without the scenario metadata is not a reproducible baseline.

## Network Profiles

Version-controlled profiles represent:

- Clean local/reference networking.
- Representative latency and jitter.
- Representative loss and packet reordering/duplication where the tooling
  supports them.
- Harsh validation conditions.
- Disconnect, reconnect, destination failure, and dependency interruption.

Numeric profile values are added by Issues #2 and #45 after evidence review.
The same profiles are used in local reproduction, automation, performance
captures, and gate reports where supported.

## Automation Layers

### Static and Content Validation

- Formatting and indentation.
- Compile and header/tool generation.
- Lint/static analysis adopted by the repository.
- Module dependency and server/client reference rules.
- Gameplay Tag, Primary Asset, policy, collision, LOD, map, navigation, and cook
  validation as their systems exist.
- Secret, dependency, and release-policy checks.

### Focused Automation

- Data rule and serialization compatibility.
- Movement state transitions.
- GAS prerequisites, effects, tags, resources, cooldowns, death, and respawn.
- Attack timeline, already-hit, defensive ordering, and territory checks.
- Progression, currency, item, reward, idempotency, fencing, and migration
  rules as their stages exist.

### Functional and Integration Tests

- Possession, respawn, avatar reassignment, and replication.
- Safe hub, outdoor objective, dungeon completion, checkpoint, and travel.
- Backend authorization and transaction boundaries.
- Sanctuary, protected start, objective, and capital isolation.

### Multi-Process Tests

- Packaged dedicated server with at least two clients.
- Join, admission, play, death, respawn, disconnect, reconnect, and shutdown.
- Regional transfer and destination/source failure.
- Gauntlet scenarios where it can provide deterministic orchestration.
- Representative and harsh network profiles.

### Performance and Scalability

- Repeatable client and server captures.
- Replication-candidate benchmark.
- Combat and actor-density steps.
- Persistence and service concurrency.
- Soak, churn, allocation, and recovery.

### Manual Evidence

Manual checks are permitted when a subjective or platform interaction cannot be
automated. The test record includes exact setup, steps, expected result, build,
participants, captures, and outcome. Manual evidence does not excuse an
automatable authority or transaction invariant.

## CI Foundation

The prototype CI path begins when the Unreal project exists and includes the
applicable subset of:

1. Repository and generated-artifact policy checks.
2. Formatting/indentation and static checks.
3. Supported client and server target compilation.
4. Focused automation.
5. Packaged-build smoke test on a scheduled or appropriately provisioned path.
6. Artifact, dependency, and secret policy checks.
7. Machine-readable test and performance evidence publication.

Issue #16 may establish repository policy, formatting, static, and focused
automation checks as soon as Issue #13 provides the project. Its
supported-target compilation and packaged-build smoke gates consume the
source-build and packaging path owned by Issue #15; editor-only or launcher
binary evidence cannot satisfy those gates.

Later stages expand this foundation with persistence services, content
validation, migrations, multi-process scenarios, platform packaging, security
tests, and scalability suites. CI quality gates are not deferred for first
introduction in 1.1.

The repository-policy, formatting, static-check, focused-automation,
supported-target compilation, and packaged-build smoke paths now have exact
commands and runner requirements in
[Continuous Integration](continuous-integration.md). Engine-dependent jobs use
the accepted repository-scoped Windows self-hosted topology; multiplayer
automation remains owned by Issue #44 and is not supplied by the packaged-smoke
gate.

Runner provisioning is an external operational responsibility and is not
performed or proven by Issue #16 or Issue #127 repository changes.
Representative engine-runner evidence is commit-specific and must come from
the artifacts uploaded by the corresponding GitHub run. An earlier or
in-progress run does not establish that the unpublished incremental candidate
has completed successfully. The `02:00 UTC` schedule becomes active only after
the workflow reaches the protected default branch `main` through normal Git
Flow; `develop` remains the integration branch.

## Change Gates

Required checks are proportional to risk but explicit:

- Documentation-only changes: link/anchor validation, `git diff --check`,
  contradiction/staleness searches, and diff review.
- Gameplay changes: compile, focused automation, applicable full suite,
  two-client server-authority smoke, and network-profile evidence.
- Persistence/economy changes: focused transaction/idempotency tests,
  failure-injection suite, migration/reconciliation checks, and authorization.
- World/content changes: asset/map/cook/navigation validation, server/client
  reference checks, streaming and policy tests.
- Infrastructure/security changes: configuration validation, least-privilege
  tests, recovery/rollback evidence, and dependency policy.
- Performance-sensitive changes: before/after capture using the registered
  scenario.

Flaky tests are not silently retried until green. They are made deterministic
or quarantined with owner, scope, evidence, and resolution target.

## Rejection Telemetry

The prototype emits structured, redacted, correlated events for:

- Invalid movement, rotation, ability, cooldown, hit, dodge, block, resource,
  death, and respawn claims.
- Protocol/content mismatch and stale/duplicate sequence.
- Admission, authorization, policy, rate, and resource rejection.

Later stages add:

- Character version and lease rejection.
- Faction, territory, sanctuary, loadout, reward, banking, item, and transfer
  rejection.
- Repeat-victim, collusion, and suspicious reciprocal activity.

Dashboards distinguish expected user error, network correction, implementation
defect, capacity failure, and potential abuse where evidence permits. Logs do
not expose sensitive detection details or credentials.

## Observability Baseline

Correlated observability covers:

- Client build and network profile.
- Game-server instance, map, region/layer, policy, and actor mix.
- Admission and session state.
- Combat activation and correction.
- Server tick and replication.
- Backend command, transaction, outbox, and dependency state.
- Regional transfer and lease epoch.
- Crash and controlled shutdown.

Metric cardinality is bounded. Traces and logs are sampled or retained by
explicit policy. Character/account identifiers are pseudonymized or excluded
where the diagnostic purpose does not require them.

## Scalability Test Progression

1. Single server and two clients prove correctness.
2. Increase representative combat actors on one instance.
3. Add join/leave churn, AI, projectiles, areas, objectives, and policy changes.
4. Compare replication candidates with the identical mix.
5. Test multiple instances and supporting-service concurrency.
6. Add regional transfer and layer placement.
7. Run the 32-player world-combat hypothesis.
8. Run a 64-player stress test to identify failure shape, not to declare
   support.
9. Add representative capital-invasion coordination only for the 2.1 gate.

The two-client correctness step cannot support a density or capacity
conclusion. Replication candidates are selected only after equivalent packaged
actor mixes and scenarios are measured and reviewed through Issues #2 and #45;
progression through this list does not select a technology by itself.

At each step, correctness and observable rejection are checked alongside
throughput. Overload must degrade through explicit admission, queue, or
allocation behavior rather than corrupted authority.

## Prototype Exit Criteria

Required evidence:

- Exact UE 5.8 source/toolchain baseline and repeatable build instructions.
- Packaged Windows x64 clients and Linux x86-64 dedicated server.
- Two players can move, use pure-free-aim combat, dodge, take damage, die, and
  respawn in the greybox arena.
- CMC prediction/reconciliation and GAS authority behave under clean,
  representative, and harsh profiles.
- Invalid movement, ability, hit, dodge, block, cooldown, and damage claims are
  rejected and observable.
- Build, CI, automation, rejection telemetry, and performance capture paths run.
- Replication and latency-compensation candidates have a recorded plan or
  evidence required by the stage decision.
- Client/server/network baseline captures name all limitations.
- Issue #48 records owner, evidence, review date, exceptions, and go/no-go
  decision.

## 1.0 Cooperative Slice Exit Criteria

- Authentication, admission, character ownership, reconnect, and session
  recovery are validated.
- Hub, outdoor objective, dungeon allocation, travel, completion, and return
  work in packaged multi-process tests.
- Permanent progress and bounded integer currency rewards are transactional,
  idempotent, fenced, auditable, and reconcilable.
- Item inventory/equipment is not required before 1.1.
- Service authorization, workload identity, version compatibility, and
  resource limits are tested.
- Backup restore and authoritative reconciliation are demonstrated for the data
  introduced by the slice.
- Client/server/network/backend budgets pass or have explicit owned exceptions.
- An external playtest build and evidence package exist.

## 1.1 Character Development Exit Criteria

- Permanent Character Level remains separate from seasonal Ember Rank.
- Inventory, equipment, generated items, Skein unlocks/loadouts, and reward
  receipts are transactionally safe and migratable.
- Retry and crash injection produce exactly-once visible rewards.
- Server rejects invalid item budgets, affixes, caps, equipment, and Skein.
- Appearance variants retain equivalent authoritative combat behavior.
- Equipment is meaningful without destroying readable counterplay under the
  representative network profiles.

## 2.0 Faction Frontier Exit Criteria

- The one-time transition from `Faction = Unassigned` is authorized,
  idempotent, and audited; Doctrine remains unavailable before it.
- Protected starts reject rival admission and travel.
- Mixed-territory faction PvP is mandatory except in explicit sanctuary
  subzones.
- Sanctuary tests cover projectiles, areas, summons, periodic effects, forced
  movement, respawn protection, and boundary changes.
- Territory objectives, banking, contested resources, PvP contribution,
  repeat-victim, disparity, and collusion controls are tested.
- Regional layer placement and transfers pass correctness, load, failure, and
  fencing tests.
- Representative opposing-population performance is measured.

## 2.1 Faction War Exit Criteria

- Capital military/invasion topology cannot grant access to beginner districts.
- Essential services remain available under every invasion state and failure.
- Defender alert/travel, invasion objectives, temporary results, reset, and
  recovery are observable and idempotent.
- Projectiles, persistent effects, summons, forced movement, respawn, reconnect,
  and stale admission cannot cross protected boundaries.
- Representative guards, objectives, attackers, defenders, and effects meet
  measured capacity and performance criteria.
- Exploit, restore, reconciliation, and incident scenarios pass.

## Open Decisions

- Final client minimum/recommended specifications and quality tiers.
- Approved server tick, population, actor, bandwidth, and latency budgets.
- Supported network-profile thresholds.
- Artifact retention and local engine-output retention policy.
- Performance exception policy and regression thresholds.
- Final 2.0 layer and 2.1 invasion capacity.

No numeric capacity becomes canonical without Issue #45 evidence and an
accepted entry in [Architecture Decisions](architecture-decisions.md).
