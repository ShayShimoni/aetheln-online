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

### Post-marker observation and process contract

`DurationSeconds` is an enforced observation interval, not metadata only. After
the reconnect client emits its required reconnect marker, the runner continues
for the full configured interval while monitoring the server, the remaining
initial client (`client-2`), and the reconnect client (`client-1-reconnect`). A
runtime error or unexpected exit from any of those three processes during the
interval fails the run; successful marker collection alone does not end the
observation early.

The runner creates the server and client child runtimes through
`System.Diagnostics.ProcessStartInfo` with `UseShellExecute = $false` and
`CreateNoWindow = $true`. Packaged authority runs therefore do not create
console windows for those child processes.

The focused PowerShell fixture measures the successful post-marker interval,
asserts the no-window process configuration, and verifies that an early server
exit during the interval is rejected. Those checks validate runner
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

Local verification on 2026-08-11 passed the focused PowerShell fixture, all 15
required CI checks, the incremental `AethelnOnlineEditor Win64 Development`
compile, all six `Aetheln.NetworkSpike` contract tests, and
`Aetheln.GameCombat.NetworkSpike.Authority`. The advisory PSScriptAnalyzer gate
was skipped because that module was unavailable. These results validate the
bounded source baseline only; they are not packaged multiplayer evidence.

### Not yet performed

No real packaged dedicated-server-plus-two-client gameplay capture is claimed
by this unit or by the fixture smoke test. The fixture uses a fake process that
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
