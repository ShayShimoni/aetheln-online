# Networking Authority Spike: Unit 1

## Purpose and Scope

This delivery record covers unit 1 of
[Issue #2](https://github.com/ShayShimoni/aetheln-online/issues/2): the
replication-neutral authority baseline and its evidence contracts. It establishes
a controlled `/Game/Maps/StarterMap` scenario with one server, two distinct
clients, one damageable enemy, authoritative movement observation, one
server-resolved melee action, authoritative damage, an invalid-command
rejection, join in progress, disconnect cleanup, and reconnect with a new
connection identity.

This unit is scaffolding and an outcome-free authority proof. It does not select
a production replication implementation, latency-validation policy, rewind
policy, network profile, performance budget, or capacity target.

## Module Ownership and Authority Boundary

- `GameCombat` owns the spike GameMode, player and enemy runtime actors,
  `PlayerState`-owned Ability System Component, authoritative attributes, the
  bounded attack-intent contract, validation, melee resolution, damage, and
  lifecycle behavior.
- `GameNet` owns replication-neutral scenario, profile, candidate, rejection,
  provenance, lifecycle, and measurement evidence contracts. Its candidate seam
  configures replication only and does not own combat truth or measurements.
- `scripts/build/Invoke-NetworkAuthoritySpike.ps1` owns packaged-process
  orchestration and correlated JSON evidence. It observes server output; it does
  not manufacture gameplay outcomes or select candidates and policies.
- The client may submit only `FAethelnSpikeAttackIntent`: schema version,
  content version, monotonic sequence, client timestamp, and aim. Target, hit,
  damage, and other claimed outcomes are structurally absent. The server
  validates lifecycle, actor state, versions, sequence, timestamp, and aim,
  then resolves the attack volume and damage.

This boundary follows the canonical
[Combat and Networking Architecture](combat-and-networking-architecture.md):
clients request allowed actions, while the server owns combat truth.

## Stable Identities

The contracts align the runner and runtime around these identities:

| Concern | Identity |
| --- | --- |
| Evidence schema | `aetheln.network-authority-evidence`, version 1 |
| Scenario | `network-authority.baseline.v1` |
| Actor mix | `network-authority.actor-mix.v1` |
| Seed/config | `network-authority.seed-config.v1` |
| Map | `/Game/Maps/StarterMap` |
| Network profile schema | `aetheln.network-profile`, version 1 |
| Unset profile | `network-profile.unset` |
| Candidate schema | `aetheln.replication-candidate`, version 1 |
| Unselected candidate | `replication-candidate.unselected` |

Issue #44 extends the runner without replacing these unit-1 identities. When a
versioned scenario and profile catalog are supplied together, the runner emits
`aetheln.network-authority-evidence` version 2. Calls that omit both contracts
retain the version-1 interface and evidence shape.

## Issue #44 Versioned Fixture Contracts

The first Issue #44 wave adds a fixture-only contract around the existing
runner. It does not add a competing launcher, choose network tuning, or execute
a real packaged build. `NetworkProfileCatalogPath` and `ScenarioContractPath`
must be supplied together. Contract mode also requires `DeathPattern`,
`RespawnPattern`, and `ShutdownPattern`; each pattern carries the scenario,
selected profile, and run placeholders already required by the runner.

The profile catalog is a closed JSON object:

```json
{
  "schema_id": "aetheln.network-profile-catalog",
  "schema_version": 1,
  "selected_profile_id": "network-profile.clean",
  "profiles": [
    { "id": "network-profile.clean", "version": "catalog-v1", "kind": "clean", "runtime_config_identity": "network-emulation.clean", "server_arguments": ["<caller-supplied-clean-server-switch>"], "client_arguments": ["<caller-supplied-clean-client-switch>"] },
    { "id": "network-profile.representative", "version": "catalog-v1", "kind": "representative", "runtime_config_identity": "network-emulation.representative", "server_arguments": ["<caller-supplied-representative-server-switch>"], "client_arguments": ["<caller-supplied-representative-client-switch>"] },
    { "id": "network-profile.harsh", "version": "catalog-v1", "kind": "harsh", "runtime_config_identity": "network-emulation.harsh", "server_arguments": ["<caller-supplied-harsh-server-switch>"], "client_arguments": ["<caller-supplied-harsh-client-switch>"] },
    { "id": "network-profile.loss", "version": "catalog-v1", "kind": "loss", "runtime_config_identity": "network-emulation.loss", "server_arguments": ["<caller-supplied-loss-server-switch>"], "client_arguments": ["<caller-supplied-loss-client-switch>"] },
    { "id": "network-profile.duplication", "version": "catalog-v1", "kind": "duplication", "runtime_config_identity": "network-emulation.duplication", "server_arguments": ["<caller-supplied-duplication-server-switch>"], "client_arguments": ["<caller-supplied-duplication-client-switch>"] },
    { "id": "network-profile.reordering", "version": "catalog-v1", "kind": "reordering", "runtime_config_identity": "network-emulation.reordering", "server_arguments": ["<caller-supplied-reordering-server-switch>"], "client_arguments": ["<caller-supplied-reordering-client-switch>"] }
  ]
}
```

The catalog must contain exactly one case-sensitive identity for each of the
six kinds shown above, exactly one selected declared profile, a nonblank
version and runtime configuration identity for every profile, and only opaque
nonempty argument strings. The selected profile ID and runtime configuration
identity must match `ProfileId` and `NetworkConfigIdentity`. The runner appends
the selected opaque arguments literally after expanding only the caller-owned
runner argument templates. A recognized runner token such as `{RunId}` inside
a profile argument remains literal and cannot satisfy a required placeholder
missing from a caller-owned server or client template. The runner never
interprets profile arguments as latency, jitter, loss, duplication, reordering,
tick, history, bandwidth, or capacity values. It records only the counts and a
SHA-256 correlation digest of the exact opaque argument arrays supplied to the
process launches; raw arguments are excluded from evidence. Numeric network
fields remain JSON `null` until reviewed measured values exist.

The scenario contract is also closed and ordered:

```json
{
  "schema_id": "aetheln.network-authority-scenario",
  "schema_version": 1,
  "id": "network-authority.baseline.v1",
  "version": "scenario-v1",
  "lifecycle_stages": [
    "join",
    "play",
    "death",
    "respawn",
    "disconnect",
    "reconnect",
    "shutdown"
  ]
}
```

The ID must match `ScenarioId`, and the seven stages must appear exactly once
in that order. Contract evidence records stable ordinals; source revision and
build; scenario and profile IDs/versions; process role and client identity;
explicit nullable activation and sequence fields; a stage-specific
authoritative result; relative raw-log names; selected profile argument
counts/digest; and a deterministic lifecycle summary. Each invalid-command
rejection records its activation and authority sequence, authoritative result,
build, scenario, and profile identity.

Because `join` is observed in a client stream while authoritative `play` is
observed in the server stream, procedural waits do not establish their order.
In version-2 mode, `JoinInProgressPattern` and `DamagePattern` must each expose
a named `Sequence` capture containing a positive 64-bit integer authority
sequence. The join sequence must be strictly less than the play sequence; an
equal, reversed, missing, zero, or invalid sequence fails closed. Successful
evidence records those identities as `sequence_id` on the `join` and `play`
lifecycle stages. Stages without this cross-stream contract retain explicit
JSON `null` sequence identity. Same-log ordering checks continue to govern the
later authoritative stages.

Successful version-2 evidence also contains a closed `process_outcomes` array
with exactly one record for each runner-owned server or client process. Each
record contains only `process_role`, nullable `client_id`, `timed_out`,
`exit_code`, and `termination_state`. Successful records always set
`timed_out` to `false`, include the confirmed exit code, and use either
`exited` for a process that exited without runner termination or
`runner-terminated` for a still-running client the runner stopped during the
scenario or final cleanup. Paths, arguments, and free-form exceptions are not
part of this field.

Issue #16 may consume the version-2 fixture result as portable CI contract
evidence and owns the runner topology, invocation policy, and artifact
publication that expose it to downstream gates. Issue #16 must not reclassify
fixture output as real packaged multiplayer evidence or treat it as Issue #44
completion. Issue #48 may consume the same machine-readable result only as one
bounded input to the Prototype Gate decision; real representative packaged
scenario evidence remains separately required.

On failure, `failure_details` identifies `source_revision`, `build`, scenario
ID/version, profile ID/version, `process_role`, `client_id`, `observed_stage`,
activation/sequence when applicable, authoritative result, normalized reason,
exit code when available, timeout state, cleanup outcome, and relative raw-log
filenames. Absolute executable and log-root paths and raw profile arguments are
not published in version-2 evidence. Successful evidence sets
`failure_details` to JSON `null` and records successful controlled cleanup.

## Issue #45 Opt-In Performance Capture and Budget Contract

`PerformanceContractPath` is a separate opt-in input owned by
[Issue #45](https://github.com/ShayShimoni/aetheln-online/issues/45). It may be
supplied with or without the Issue #44 scenario/profile contracts, and calls
that omit it retain the existing version-1 and version-2 interfaces and
evidence shapes unchanged. The contract is a closed, versioned JSON object with
schema `aetheln.performance-capture-contract` version 1 containing exactly one
`capture` object and one `budgets` array.

The `capture` object binds future performance evidence to the exact run
identity. Its `source_revision`, `build`, `toolchain`, `hardware`, `topology`,
`environment`, `map`, `duration_seconds`, `actor_mix`, `scenario_id`, and
`profile_id`, and `network_config_identity` values must equal the corresponding
runner inputs exactly and case-sensitively. When the Issue #44 scenario/profile
contracts are supplied, `scenario_version`, `profile_version`, and
`profile_arguments_sha256` must bind the exact selected versions and opaque
argument digest; without those contracts, all three fields must be JSON `null`.
`evidence_references` must be a non-empty array of unique
whitespace-free tokens. `measurement_domains` must declare exactly the three
version-1 network-authority-runner subset domains with exactly these ordered
metrics:

- `client`: `client_memory_bytes`, `correction_count`,
  `correction_magnitude_centimeters`
- `server`: `server_game_thread_milliseconds`,
  `server_replication_cpu_milliseconds`, `server_memory_bytes`,
  `relevant_actor_count`, `destruction_event_count`
- `network`: `bandwidth_per_connection_bits_per_second`,
  `aggregate_bandwidth_bits_per_second`

This ten-metric subset is limited to fields the current network-authority
runner can bind. It does not replace or complete Issue #45's full performance
budget registry, which still requires client game/render/GPU timing, frame
pacing and hitches, loading and streaming, server worker and tick-overrun
behavior, failure shape, and network send/receive bursts and loss impact.

The `sampling` object must declare `sampling_rate_hz`, `server_tick_hz`,
`bandwidth_limit_kbps`, and `capacity_players`, and every one of those values
must remain JSON `null` in this wave.

The `budgets` array must contain exactly one closed record per version-1
network-authority-runner subset metric with `metric_id`, `domain`, `target`,
`warning_threshold`,
`failure_threshold`, `measurement_method`, `scenario_id`, `owner`,
`evidence_references`, `evidence_classification`, and `approval_status`.
`target`, `warning_threshold`, and `failure_threshold` must remain JSON `null`;
a populated value fails closed because no measurement authority exists yet.
`evidence_classification` must be `measured`, `modeled`, `hypothetical`, or
`unset`; an `unset` budget must declare no evidence references, and any other
classification must reference only tokens declared in the capture
`evidence_references`. `approval_status` must be exactly `unapproved`; the
contract and the fixture runner cannot approve or canonicalize a budget.

Contract input is limited to 1,048,576 bytes. Malformed JSON, oversized input,
duplicate JSON properties, missing or extra fields, unknown or duplicate
metrics, mismatched identities, populated numeric values, undeclared
evidence references, and self-approved budgets all fail closed before any
process launch. A validated contract adds one `performance_contract` summary
to the evidence document containing only the schema identity, the version-1
network-authority-runner measurement subset, the SHA-256 and fixed artifact
name of the exact validated
contract bytes, the budget count, `targets_defined = false`, `approval_status =
"unapproved"`, the evidence-reference count, and classification counts. Those
exact bytes are retained as `performance-contract.json` in the run log root.
Raw evidence-reference values, paths, and every numeric performance value are
excluded from the summary; the `measurements` object continues to publish
explicit `null` values only.

### Fixture flake policy

The runner performs no automatic retry. Every attempt uses a unique run ID and
an empty log root. A failed attempt and its raw logs remain evidence; a later
rerun is a separate attempt with a new identity and cannot erase or override
the failure. Missing, duplicate, reordered, wrong-client, stale-profile,
timeout, process-role, or cleanup evidence fails closed. Repeated or
non-deterministic fixture behavior blocks the gate for investigation instead
of being reclassified as a pass.

### Stable rejection vocabulary

Runtime logs and evidence use one shared, case-sensitive rejection vocabulary:

- `none`
- `stale-sequence`
- `duplicate-sequence`
- `incompatible-version`
- `timestamp-out-of-bounds`
- `impossible-aim-transition`
- `connection-closed`
- `actor-destroyed`
- `malformed-intent`
- `activation-blocked`

The runner accepts only these hyphenated values. An underscore spelling or any
unknown value fails the run before that reason can be admitted into evidence.

### Nullable measurement schema

The evidence `measurements` object mirrors
`FAethelnNetworkSpikeMeasurements` exactly:

- `server_game_thread_milliseconds`
- `server_replication_cpu_milliseconds`
- `client_memory_bytes`
- `server_memory_bytes`
- `bandwidth_per_connection_bits_per_second`
- `aggregate_bandwidth_bits_per_second`
- `correction_count`
- `correction_magnitude_centimeters`
- `relevant_actor_count`
- `destruction_event_count`
- `implementation_complexity`
- `failure_behavior`

Every key is always present. A value remains JSON `null` when the run does not
capture it; the runner never substitutes zero or another invented measurement.

### Provisional spike-only defaults

The unit currently uses a 2.0-second accepted timestamp delta, 175 cm attack
reach, 75 cm attack radius, and 25 damage. These are private, editable runtime
defaults used only to exercise the authority seam. They are unmeasured,
non-canonical, and are not approved balance, latency, reach, or damage tuning.

Runner provenance also correlates the run, source revision, build, toolchain,
hardware, topology, duration, profile, actor mix, map, and client/connection
lifecycle. `client-1` and `client-2` must receive distinct initial connection
identities. A reconnect uses `client-1-reconnect` and must receive a connection
identity different from the disconnected client.

## StarterMap GameMode Override

The spike is launched without changing `StarterMap` defaults by appending this
URL option to the map argument:

```text
/Game/Maps/StarterMap?game=/Script/GameCombat.AethelnNetworkSpikeGameMode
```

This is a run-specific override. It does not replace the project setup baseline
in [Unreal Project Setup](unreal-project-setup.md), where `StarterMap` uses
`AAethelnGameModeBase` by default.

## Verification Commands

Use the pinned engine and toolchain from
[Unreal Project Setup](unreal-project-setup.md). Keep the engine location local
and untracked:

```powershell
$AethelnEngineRoot = '<local-path-to-the-pinned-UE-5.8.1-source-tree>'
$AethelnProject = (Resolve-Path '.\AethelnOnline.uproject').Path
& (Join-Path $AethelnEngineRoot 'GenerateProjectFiles.bat') "-project=$AethelnProject" -game -engine -progress
& (Join-Path $AethelnEngineRoot 'Engine\Build\BatchFiles\Build.bat') AethelnOnlineEditor Win64 Development $AethelnProject -WaitMutex -NoHotReloadFromIDE
& (Join-Path $AethelnEngineRoot 'Engine\Binaries\Win64\UnrealEditor-Cmd.exe') $AethelnProject -unattended -nop4 -nullrhi -ExecCmds="Automation RunTests Aetheln.NetworkSpike; Quit" -TestExit="Automation Test Queue Empty" -log
& (Join-Path $AethelnEngineRoot 'Engine\Binaries\Win64\UnrealEditor-Cmd.exe') $AethelnProject -unattended -nop4 -nullrhi -ExecCmds="Automation RunTests Aetheln.GameCombat.NetworkSpike.Authority; Quit" -TestExit="Automation Test Queue Empty" -log
powershell -NoProfile -File tests/build/Invoke-NetworkAuthoritySpike.Tests.ps1
powershell -NoProfile -File scripts/ci/Invoke-CiSuite.ps1
git diff --check
```

For a packaged run, invoke
[`Invoke-NetworkAuthoritySpike.ps1`](../scripts/build/Invoke-NetworkAuthoritySpike.ps1)
with explicit packaged server/client executable paths, the StarterMap URL
option above, all required scenario and provenance identities, a unique empty
log directory, and runtime log patterns. The runner requires two clients,
correlates all placeholders, fails closed on missing observations or reused
connection identity, and writes
`network-authority-spike-evidence.json` beneath the supplied log root.

The server argument template must include the identity switches consumed by
the opt-in driver:

```text
-AethelnAuthorityScenario
-AethelnServerEndpoint={ServerEndpoint}
-AethelnServerMap={ServerMap}
-AethelnScenarioId={ScenarioId}
-AethelnProfileId={ProfileId}
-AethelnRunId={RunId}
-AethelnNetworkConfig={NetworkConfigIdentity}
-AethelnEnvironment={Environment}
```

Each client uses the same switches plus
`-AethelnSpikeClientId={ClientId}` and connects to
`{ServerEndpoint}?AethelnClientId={ClientId}`. The client label in the URL is
only a bounded correlation input; the server generates the connection ID.
The runner appends the required `SourceRevision`, `BuildIdentity`, and
`ToolchainIdentity` values to every server and client process. Each executable
records its engine-reported `BuildConfiguration`, so both sides retain the same
provenance-bound packaged-build context without trusting caller-supplied build
configuration text.
`Environment` is a separate closed runtime identity. Fixture runs may use
`local`; provenance-bound packaged multiplayer evidence must use `development`,
and the runner propagates that value to both server and clients.
Actual caller-selected packet-emulation switches, if any, remain additional
server/client arguments and must correspond to the supplied
`NetworkConfigIdentity`.

### Post-marker observation and process contract

`DurationSeconds` is an enforced observation interval, not metadata only. After
the reconnect client emits its required reconnect marker, the runner continues
for the full configured interval while monitoring the server, the remaining
initial client (`client-2`), and the reconnect client (`client-1-reconnect`). A
runtime error or unexpected exit from any of those three processes during the
interval fails the run; successful marker collection alone does not end the
observation early.

For the versioned scenario contract, the controlled-shutdown marker is
necessary but not sufficient. After matching the single correlated marker, the
runner waits only for the configured bounded timeout for the authoritative
server process to exit, requires exit code `0`, and only then publishes the
`shutdown` lifecycle stage with authoritative result `shutdown-complete`. A
server that emits the marker but remains alive fails closed and is terminated
during cleanup; the marker alone cannot prove controlled shutdown.

The packaged scenario driver is opt-in. It runs only when the spike GameMode URL
override and `-AethelnAuthorityScenario` are both present. Each client connects
with one bounded URL correlation value (`AethelnClientId=client-1`,
`client-2`, or `client-1-reconnect`) and receives a separate server-assigned
connection identity. The client label cannot select a target, claim a hit or
damage result, or grant command eligibility. Normal `StarterMap` behavior is
unchanged.

During this scenario, the server records correlated structured observations
only after it observes the corresponding authoritative state: connection,
movement, enemy spawn, melee resolution, damage application, disconnect
cleanup, and reconnect with a new connection.
The second client emits its join-in-progress observation only after the
replicated enemy exists locally. Ten bounded negative probes cover invalid
movement, aim, activation, hit, cooldown, dodge, block, resource, death, and
respawn claims. The probes expose rejection behavior only; they do not
implement deferred gameplay systems.

The runner owns the structured rejection-envelope parser. It requires schema
version 1, the rejection envelope and exact subject/reason vocabulary, a
nonzero authority sequence, the server-owned connection pseudonym mapped to
the second client, bounded public fields, exact run/build/toolchain/profile
identity, engine and Development configuration identity, and the explicit
metric environment. Legacy `AUTHORITY rejection` lines remain scenario control
diagnostics and cannot satisfy structured rejection evidence.

The packaged scenario does not transport or prove a command attempt after the
client disconnects. `connection-closed` remains part of the stable rejection
vocabulary and is directly covered by the closed-lifecycle authority validator
test; a `Logout` lifecycle observation must not be reported as rejected-command
evidence.

The runner supports the Issue #15 WSL topology through
`ServerLauncherExecutable` and `ServerLauncherArguments`. Launcher arguments
must contain both `{ServerExecutable}` and `{ServerArguments}`; the latter is
expanded into the complete packaged-server argument vector. A typical launch
uses `wsl.exe` with `--exec`, while Windows clients launch directly. A launcher
must also provide `ServerIdentityArguments`, `ServerCleanupArguments`, and a
`ServerProcessIdPattern` with a named `ProcessId` capture. The identity command
hashes the exact Linux executable path before launch. The launch command emits
the Linux descendant PID, and the cleanup command consumes
`{ServerProcessId}`, terminates that descendant, waits until it is absent, and
exits nonzero if absence cannot be confirmed. All launcher, control, server,
and client processes remain hidden, redirected, monitored, and cleaned up.

Every server/client argument vector carries the caller-supplied
`NetworkConfigIdentity`, and the server must confirm that identity at runtime.
The identity correlates the external network-emulation configuration; the
repository still chooses no latency, jitter, loss, tick, history, bandwidth,
or capacity number. Those evidence fields remain null until a measured profile
is reviewed.

The runner rejects missing or duplicate required records, mismatched
scenario/profile/run identities, unknown or category-inappropriate rejection
reasons, reused connections, reordered gameplay/lifecycle evidence, and early
process exits. Its explicit `fixture` evidence mode can produce only
`fixture-passed`; synthetic processes can never produce a packaged `passed`
result. Packaged mode produces only `packaged-candidate`, which requires a
fresh restricted verifier and approver before it can satisfy the ticket; the
runner never self-awards final packaged success. Packaged mode additionally requires the Issue #15 schema-v2 build
provenance document, an exact clean source revision and build identity, and
unique inventory hashes binding the exact normalized selected-client and
launcher-side server paths. A basename-only or merely hash-shaped inventory
entry is insufficient.
It creates the server and client child runtimes through
`System.Diagnostics.ProcessStartInfo` with `UseShellExecute = $false` and
`CreateNoWindow = $true`. Packaged authority runs therefore do not create
console windows for those child processes.

The focused PowerShell fixture measures the successful post-marker interval,
asserts the direct and launcher-mediated no-window process configurations, and
verifies that an early server exit during the interval is rejected. It also
requires all ten invalid-claim rejection records, the real disconnect and
reconnect lifecycle records, and the runtime network-configuration confirmation.
The launcher fixture uses a real descendant process, proves it is absent after
cleanup, fails closed when cleanup confirmation fails, and rejects a server
digest that does not match the exact provenance inventory entry. Those checks validate runner
orchestration and failure handling only. They do not replace the real packaged
dedicated-server-plus-client capture required for multiplayer evidence.

## Evidence Status

### Present in unit 1

Repository inspection establishes focused C++ automation for the neutral
profile, evidence identity, nullable measurements, candidate isolation,
validation capabilities, stable rejection reasons, and outcome-free authority
intent. It also establishes a PowerShell fixture test for runner correlation,
lifecycle, authority observations, rejection, provenance, explicit null
measurements, process cleanup, and fail-closed placeholder validation. The
fixture test is registered as a required check in the CI suite.

The Issue #44 first wave additionally establishes the versioned six-profile
catalog, exact seven-stage scenario contract, normalized version-2 failure
identity, opaque argument correlation, cleanup outcome, and negative fixtures
for missing, duplicate, reordered, wrong-client, stale-profile, timeout, and
role-specific failures. This is contract and orchestration coverage only.

Local verification on 2026-08-12 passed the focused PowerShell fixture, all 15
required CI checks, the incremental `AethelnOnlineEditor Win64 Development`
compile, all six `Aetheln.NetworkSpike` contract tests, and the focused
`Aetheln.GameCombat.NetworkSpike.Authority` test. The advisory PSScriptAnalyzer
gate was skipped because that module was unavailable. These results validate
the bounded source and orchestration baseline only; they are not packaged
multiplayer evidence.

### Not yet performed

No real packaged dedicated-server-plus-two-client gameplay capture is claimed
by this unit or by the Issue #44 fixture contract. The fixture uses a fake process that
emits expected log records; it validates orchestration and evidence handling,
not Unreal networking, replicated gameplay, combat feel, latency tolerance, or
packaged lifecycle behavior. A packaged run and its correlated raw logs and
JSON evidence remain required before Issue #2 can close.

All numeric network conditions, measurements, budgets, thresholds, tick rates,
history windows, bandwidth limits, and capacity values remain explicitly
`TBD`/null. The generic push-model, Replication Graph, and Iris candidates remain
unselected. Present-time melee is only the implemented baseline used to expose
the comparison seam; it is not the final selected latency policy. Bounded
rewind and the remaining projectile, block, and dodge coverage are not
implemented by this unit. No entry in
[Architecture Decisions](architecture-decisions.md) is added or changed.

## Continuation Ownership

- [Issue #44](https://github.com/ShayShimoni/aetheln-online/issues/44) owns the
  reusable executable packaged multiplayer scenarios and machine-readable
  lifecycle/authority evidence.
- [Issue #45](https://github.com/ShayShimoni/aetheln-online/issues/45) owns
  representative performance measurements and evidence-based budgets.
- [Issue #48](https://github.com/ShayShimoni/aetheln-online/issues/48) owns the
  prototype exit review, evidence assessment, exceptions, and go/no-go decision.
- Remaining Issue #2 work must implement and measure isolated generic
  push-model, Replication Graph, and Iris candidates, and compare present-time
  validation with bounded rewind under representative conditions before any
  candidate or latency policy is selected.

See [Continuous Integration](continuous-integration.md) for required gates and
evidence boundaries.
