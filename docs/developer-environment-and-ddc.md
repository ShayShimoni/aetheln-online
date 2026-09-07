# Developer Environment and Derived Data Cache

This document is the canonical reference for reducing elapsed machine time of
the periodic clean Windows-client and Linux-server packaging milestone
(Issue #81) without weakening its clean-build, cooking, staging, archive,
registry-validation, provenance, or packaged-smoke semantics.

## Where clean-package time can go

A clean milestone run spends its time in a small set of categories. Do not
attribute the duration to any of them without evidence:

- C++ compilation of the client and dedicated-server targets by
  UnrealBuildTool (engine modules plus project modules under `-clean`), and,
  under the prebuilt host-tools boundary, the project editor modules the cook
  loads (built by the controller against the attested engine, never cleaned).
- Cooking, which derives platform content through the Derived Data Cache
  (DDC).
- Staging, pak creation, and archiving.
- Registry dumps and dedicated-server cook-reference validation.
- Provenance validation and packaged smoke.

Two evidence sources make the split measurable per run:

- `TestResults/engine-runner-report.json` records `durationSeconds` per gate
  check, so the CI phase jobs (`PackageClient`, `PackageServer`,
  `ValidateProvenance`, `SmokePhase`) are separable at job granularity.
- `<LogRoot>/build-timing.json`, written by
  `scripts/build/Build-PackagedArtifacts.ps1` on every run that resolves a
  valid `LogRoot` — including runs that fail closed on host-tools or
  cache-identity validation before any UAT process starts. Failures that
  occur before a valid `LogRoot` exists (invalid parameters, a dirty
  repository, a non-empty archive or log root) produce no record because
  there is no valid place to write one. The record carries controller
  substeps and, inside each UAT invocation, the timestamps of UAT's own
  `BUILD`/`COOK`/`STAGE`/`PACKAGE`/`ARCHIVE`
  `COMMAND STARTED`/`COMPLETED` boundary lines. That separates C++
  compilation time from cook time from stage/package/archive time within a
  single `BuildCookRun`.

### build-timing.json schema (version 3)

- `schemaVersion`, `stage`, `sourceRevision`, `configuration`, `map`,
  `startedUtc`, `finishedUtc`.
- `identity`: bounded normalized identifiers binding the run's inputs for
  before/after comparison — `engineGitRevision` with
  `engineGitRevisionStatus` (`verified`, `dirty`, or `unavailable`),
  `engineBuildVersionSha256` and `linuxToolchainCompilerSha256` each with a
  `verified`/`unavailable` status field, the fixed `targets` contract, and
  the gate-forwarded validated `runnerName` (null when not forwarded). No
  absolute machine paths are emitted; failed post-LogRoot runs retain
  whatever identity fields were verified.
- `derivedDataCache`: `mode` (`engine-default`, `persistent`, or
  `clean-isolated-fallback`), `status` (`not_configured`, `initialized`,
  `reused`, a `fallback_*` state naming the taken clean-isolated fallback, or
  a `failed_*` state naming the fail-closed stop; the state names are listed
  under Failure below), and the applied cache path (`appliedPath`, null when
  the engine default is used or the run failed closed).
- `hostTools`: `mode` (`rebuild`, `prebuilt`, `attest`, `not_applicable`, or
  `unresolved` on a run that failed before resolution), `status`
  (`authorized_rebuild`, `verified`, `written`, `no_build_phase`, or
  `not_configured`), `engineRevision` (the verified canonical pinned
  engine commit, null otherwise), and, once a prebuilt run has passed the
  project editor identity check, `projectEditorBuildId` (the BuildId shared
  by the project and engine editor manifests). A failed boundary stops the
  run with the `host-tools-boundary` substep recorded as failed.
- `substeps`: bounded list of controller steps
  (`evidence-identity-resolution`, `host-tools-boundary`,
  `derived-data-cache-resolution`, `target-composition-gate`,
  `client-uat-build-cook-package`, `client-output-validation`,
  `server-uat-build-cook-package`, `server-output-validation`,
  `server-dependency-registry-dump`, `server-cooked-inventory-dump`,
  `server-cook-reference-gate`, `provenance-write`; under the prebuilt
  boundary additionally `project-editor-preparation`,
  `project-editor-identity`, `host-tools-postpreparation-verification`,
  `client-project-clean`, `client-project-build`, `client-bootstrap-clean`,
  `client-bootstrap-build`, `server-project-clean`, `server-project-build`,
  and `host-tools-final-verification`) with `startedUtc`,
  `durationSeconds`, and `status`. Under the prebuilt boundary UAT runs no
  build, so C++ compilation time lives in the `*-project-*` and
  `project-editor-*` substeps and the `uatSteps` list carries no `BUILD`
  entry; under Rebuild it stays inside the UAT invocation's `BUILD` marker.
- `uatSteps`: bounded list (at most 64 captured marker events) of paired UAT
  step boundaries with `invocation`, `step`, `startedUtc`, `completedUtc`,
  and `durationSeconds`. Absent markers simply produce no entry; nothing is
  estimated.

The record is local run evidence under `LogRoot`. Never upload caches,
packages, raw logs, secrets, credentials, environment dumps, or local
machine paths.

## What the DDC does and does not accelerate

The Derived Data Cache stores derived content (compiled shaders, compressed
textures, and other cook outputs) keyed by content hashes that Unreal derives
from the source asset, target platform, and relevant settings. A warm DDC
accelerates cooking. It does not accelerate C++ compilation: UnrealBuildTool
never reads the DDC, and a `-clean` build recompiles the targets regardless
of cache state. Do not present a DDC change as compile-time evidence.

## Persistent local DDC with explicit identity

`Build-PackagedArtifacts.ps1` accepts an optional persistent local cache:

- `-DerivedDataCachePath <dir>` points cooking at a persistent local DDC by
  setting `UE-LocalDataCachePath` for the UAT invocations of that run (the
  previous environment value is restored afterward). Unset means unchanged
  engine-default DDC behavior.
- `-CacheFallback FailClosed|CleanIsolated` (default `FailClosed`) selects
  the behavior when the cache cannot be verified.

### Path contract (enforced by the build controller itself)

`Build-PackagedArtifacts.ps1` enforces the same DDC path contract as the CI
gate, so a direct call cannot bypass it: the configured path must be an
absolute non-UNC path on a local fixed drive, reached without reparse points
anywhere in the existing path chain, and disjoint from the repository,
engine, toolchain, archive, and log roots (in both directions). A violating
path is a configuration error: it always fails closed with an actionable
error and is recorded as `failed_path_invalid`; `-CacheFallback` never
rescues it.

### Identity model

Each DDC entry is content-addressed by Unreal itself, which binds platform,
target flavor, configuration-relevant settings, and asset content into the
cache key. The explicit identity record adds the bindings a key lookup cannot
defend by itself. `<cache root>/cache-identity.json` (schema version 2)
records:

- `engineGitRevision` — the exact engine source commit from
  `git rev-parse HEAD` in the engine root, which must be a Git checkout that
  is clean under `git status --porcelain=v1 --untracked-files=all`; and
  `engineBuildVersionSha256` — the SHA-256 of the pinned engine's
  `Engine/Build/Build.version`.
- `linuxToolchain` — the toolchain directory name — and
  `linuxToolchainCompilerSha256` — the SHA-256 content identity of the
  toolchain's clang compiler binary.
- `projectRepository` — the project repository's root-commit set
  (`git rev-list --max-parents=0 HEAD`), a stable non-colliding repository
  identity that never changes across project commits — and `project`, the
  project descriptor file name.
- `configuration` and `targets` — this controller's build configuration and
  fixed target/platform contract
  (`AethelnOnlineClient:Win64+AethelnOnlineServer:Linux`).
- `createdUtc`.

A new or empty cache root is initialized with this record (status
`initialized`). An existing cache is reused only when every identity field
matches the current invocation exactly (status `reused`); records from an
older schema are treated as corrupt and never reused.

**Cross-project-commit reuse boundary:** the project source revision is
deliberately not part of the identity. Reuse across project commits is
exactly the reuse Unreal's content-addressed cache-entry keys make safe: each
entry key binds asset content, platform, target flavor, and relevant
settings, so changed content misses and re-derives while unchanged content
hits. The identity record defends only what entry keys cannot — which engine
revision, toolchain content, repository, project, configuration, and target
set the cache as a whole belongs to.

### Failure, invalidation, corruption, and recovery

Any unverifiable cache state fails closed by default:

| State | Status | Behavior |
| --- | --- | --- |
| Identity fields differ (engine revision/upgrade, toolchain change, other repository or project, other configuration or targets) | `fallback_mismatch` | Fail closed, or clean-isolated fallback |
| `cache-identity.json` unparseable, incomplete, or from an older schema | `fallback_corrupt` | Fail closed, or clean-isolated fallback |
| Cache directory non-empty without an identity record | `fallback_unverifiable` | Fail closed, or clean-isolated fallback |
| Configured path exists but is not a directory | `fallback_unavailable` | Fail closed, or clean-isolated fallback |
| Engine has no `Build.version`, is not a Git checkout, or has local modifications | `fallback_engine_identity_unverifiable` | Fail closed, or clean-isolated fallback |
| Toolchain holds no clang compiler to content-hash | `fallback_toolchain_identity_unverifiable` | Fail closed, or clean-isolated fallback |
| Project repository root-commit identity unavailable | `fallback_project_identity_unverifiable` | Fail closed, or clean-isolated fallback |
| Path contract violated (relative, UNC, non-fixed drive, reparse-mediated, overlapping root) | `failed_path_invalid` | Always fail closed |

- **Fail closed (`FailClosed`, default):** the run stops before any UAT
  invocation with an actionable error and records the corresponding
  `failed_*` state (the table's `fallback_*` name with the `failed_` prefix,
  e.g. `failed_mismatch`) in `build-timing.json`. Nothing is deleted.
- **Clean fallback (`CleanIsolated`):** the run proceeds with a fresh empty
  run-scoped cache under `<LogRoot>/ddc-clean-isolated`, so everything is
  re-derived cleanly and the questionable cache is never read or written.
  The taken fallback is recorded in `build-timing.json`.
- **Invalidation:** delete the cache directory (or point at a new one); the
  next run re-initializes the identity record and re-derives content. An
  engine, toolchain, or project change invalidates implicitly through the
  identity mismatch.
- **Entry corruption:** individual derived-data entries are verified by
  Unreal against their content hashes and re-derived on mismatch; a corrupted
  entry degrades to a cache miss, not to wrong output.
- **Recovery:** always delete-and-reinitialize. No tool repairs a cache in
  place.

### Capacity

Capacity is owned by Unreal's local DDC maintenance (unused-file age cleanup
configured through the engine's DDC settings) plus external operational
cleanup of the cache directory. CI never deletes or invalidates the cache;
the runner gate only validates and forwards the configured path.

**Monitoring procedure (bounded, per clean milestone):** after each scheduled
clean milestone run, the runner operator records two numbers — the cache
size (`(Get-ChildItem -LiteralPath <cache root> -Recurse -File |
Measure-Object -Sum Length).Sum`) and the cache drive's free space
(`(New-Object System.IO.DriveInfo '<drive>').AvailableFreeSpace`) — alongside
that run's `build-timing.json`. That is the whole procedure; no service, no
polling.

**Threshold ownership:** the runner operator (the project owner) owns two
explicit thresholds and sets them from observed values, not from an assumed
hardware size: a cache-size ceiling and a free-space floor. Crossing either
one triggers the recovery action below (delete and re-initialize) or an owner
decision to re-point the cache at a larger volume. **Revisit trigger:** if
the recorded size still grows monotonically across three consecutive
milestone runs after Unreal's unused-file cleanup is configured, the operator
revisits the engine's DDC maintenance settings before considering hardware.

### Clean semantics are preserved

The packaging command lines keep `-clean`, every target and phase still runs,
and no reused or incremental output is ever relabeled as clean evidence. DDC
reuse changes how fast derived content is produced, not what is built or
validated.

## Prebuilt host-tools boundary

Retained live evidence from the legacy scheduled run showed the UBT action
graph dominated by the host editor/engine tool build (`AethelnOnlineEditor`
plus engine modules) that `BuildCookRun -build` performs so it can cook — not
by the client and server project targets themselves. The DDC does not touch
this cost; before/after attribution still requires the lead-authorized
`build-timing.json` milestone pair.

There is deliberately **no default host-tools behavior** for a build: every
building invocation of `Build-PackagedArtifacts.ps1` must choose explicitly,
so one missing selection can never silently launch another multi-hour host
editor/engine rebuild:

- `-HostToolsBoundary Rebuild` — the explicit, operator-authorized full
  host-tools rebuild (the host editor/engine tools rebuild as part of the
  UAT invocation). It is never a default or an automatic fallback.
- `-HostToolsBoundary Prebuilt -EngineRevision <canonical sha>
  -HostToolsAttestationPath <file>` — keep the attested host editor/engine
  tools and run UAT without its build agenda (`-skipbuild`, which the pinned
  UE 5.8.1 `ProjectParams` maps to `Build = false`, so `Project.Build`
  returns before assembling any target). The controller itself then owns
  every build the milestone needs (see the sequence below): the project
  editor modules the cook loads, the clean client and server project
  targets, and the Win64 client's `BootstrapPackagedGame` launcher. Every
  cook, stage, package, archive, registry-validation, provenance, and smoke
  phase still runs, and `-clean` stays on the UAT command line for the cook.
  `-nocompileeditor` alone was not sufficient: it only removed the editor
  targets from the agenda, so (a) nothing built the project editor modules
  the cook loads on a clean milestone checkout, and (b) the remaining agenda
  still cleaned and relinked `UnrealPak` (and `BootstrapPackagedGame`) on
  every run, rewriting its version and manifest files with a new BuildId and
  deleting the engine `UnrealPak.target` receipt, so the next prebuilt run
  failed closed against its own attestation.
- An unset selection fails closed with `host_tools_configuration_required`
  (`Stage Provenance` runs no build phase and takes no host-tools
  parameters).

### Host-tools attestation record

Provenance of the host binaries is proven by an external, local attestation
record — never inferred from `Build.version` fields, which many source
commits under the same release can share. The record lives outside the
repository and engine checkout (its path must satisfy the same external-path
contract as the DDC root) and is produced only by the explicit operator
attestation step:

```
Build-PackagedArtifacts.ps1 -Stage AttestHostTools `
  -HostToolsAttestationPath <file> `
  -ProvisioningEvidence "<reference to the retained successful provisioning build>" `
  <usual mandatory parameters>
```

The attestation step builds nothing. It requires the engine checkout to be
clean and at exactly the canonical pinned engine revision
(`71fe36aac5a8df5ccd66c763ffc902b29b6a9c43`, the pin recorded in
[Unreal Project Setup](unreal-project-setup.md) and enforced as a constant by
the build controller), refuses to overwrite an existing record (the record is
written atomically to a temporary sibling and moved into place), and writes
(schema version 1): the canonical `engineGitRevision`, the operator's
`provisioningEvidence` reference, `createdUtc`, and one entry per attested
file with its engine-relative `path`, lowercase SHA-256, and `sizeBytes`.
The attested set is not a hand-written list: it is derived from the pinned
engine's generated Unreal target receipts — the exact
`UnrealEditor` Win64 Development Editor receipt plus the `UnrealPak` and
`ShaderCompileWorker` Win64 Development Program receipts under
`Engine/Binaries/Win64` — whose validated non-symbol build products
(executables, dynamic libraries, module/resource manifests, and the receipts
themselves, including engine-plugin products outside `Engine/Binaries/Win64`)
form the complete closure the prebuilt boundary preserves. Symbol/debug and
link-time-only products are excluded; unknown product types, receipt metadata
mismatches, paths escaping the engine root, reparse-mediated paths, and
duplicate or case-colliding products fail closed, and receipt size, product
count, per-file size, and overflow-checked aggregate size are all bounded.
Run it once after an explicit authorized provisioning build that produced
all three engine receipts; never start a full rebuild merely to create the
record. The retained legacy outputs do not provide that receipt set: every
retained editor build was the project target `AethelnOnlineEditor`, whose
receipt lands under the project's `Binaries/Win64`, and no retained evidence
shows the engine `Engine/Binaries/Win64/UnrealEditor.target` ever existed.
Provisioning therefore has to build the engine `UnrealEditor`, `UnrealPak`,
and `ShaderCompileWorker` targets explicitly before the attestation step can
succeed (Issue #81 records the readiness evidence).

### Prebuilt consumption proofs

UAT is invoked with `-skipbuild` only after every proof passes; any failure
stops the run with an actionable error — the boundary never falls back
silently to another monolithic engine rebuild:

1. `-EngineRevision` equals the repository's canonical pinned engine
   revision — any other 40-character SHA fails closed as noncanonical, even
   when the checkout happens to match it.
2. The engine root is a Git checkout whose `git rev-parse HEAD` equals the
   canonical pin, clean under
   `git status --porcelain=v1 --untracked-files=all`.
3. The attestation record parses within its 8388608-byte bound under a
   strict JSON contract: duplicate or case-colliding property names at any
   object level, a schema version that is not the JSON integer `1`, a
   non-string or empty `provisioningEvidence`, a `createdUtc` that is not a
   bounded round-trip UTC timestamp, a non-array `files` value, and
   fractional, negative, or out-of-bound sizes all fail closed. It must bind
   the canonical engine revision and list exactly the receipt-derived host
   build-product closure, re-derived fresh from the on-disk receipts at
   verification time — a caller-supplied subset is never trusted, and
   missing, extra, duplicate, or case-colliding paths/properties, malformed
   records, path escapes, and reparse-mediated paths all fail closed.
4. Every attested file exists under the engine root, is reached without
   reparse points, and matches its attested size and SHA-256 exactly — an
   arbitrary binary with a matching version JSON fails here.

### Prebuilt build sequence

With the boundary verified, the controller runs this sequence for `-Stage
All`, `Client`, and `Server` (each scheduled job runs it on its own clean
`milestone/` checkout, so the editor preparation happens once per job):

1. **Project editor preparation** — `Engine/Build/BatchFiles/Build.bat
   AethelnOnlineEditor Win64 Development <project> -WaitMutex
   -NoHotReloadFromIDE -NoEngineChanges`, never `-Clean`. The cook runs in
   `UnrealEditor-Cmd.exe`, which loads every `.uproject` module compiled into
   a Win64 editor target; only this build produces them on a clean checkout.
   `-NoEngineChanges` makes UnrealBuildTool refuse, before executing any
   action, a graph that would modify an existing engine file (engine module
   relinks, engine manifest or version rewrites), so the attested products
   stay byte-identical by construction; new engine files and UnrealHeaderTool
   header generation are outside that guard and outside the attested closure.
   A `-Clean` here would be the engine-wiping path: a Shared-environment
   editor clean deletes `UnrealEditor*` products under the engine directory.
2. **Project editor identity** — the project `Binaries/Win64/UnrealEditor.modules`
   must exist, list at least one module, carry the same BuildId as the
   attested `Engine/Binaries/Win64/UnrealEditor.modules` (the module manager
   ignores manifests with another BuildId), name only existing product files,
   and contain every `.uproject` module whose descriptor type, target
   allow/deny lists, and platform allow/deny lists compile it into a Win64
   editor target (`Runtime`, `ServerOnly`, `ClientOnly`, `Editor`, and the
   other editor-loaded host types; `CookedOnly` and `Program` are excluded;
   an unknown type fails closed). `bBuildAllModules` on the engine target is
   not treated as a compatibility guarantee — this check is.
3. **Post-preparation attestation re-verification** — the same record is
   re-verified against the binaries on disk (contract-level proof, not UBT's
   claim).
4. **Per selected target: clean, then build** — two separate
   UnrealBuildTool invocations mirroring the pinned UAT cooked-target shapes
   (the editor preparation above carries no `-remoteini`, matching UAT's
   editor agenda): `<Target> <Platform> <Configuration> <project>
   -remoteini=<project dir> -Clean -NoHotReload -NoUBTMakefiles -WaitMutex`,
   then the same target without `-Clean`. The clean is a delete operation
   and proves no build:
   the controller asserts the target receipt is absent after the clean and
   present, parseable, and describing exactly the requested target, platform,
   configuration, and type — with its executable product on disk — after the
   build. Clean-mode scope (pinned `CleanMode.cs`): build products prefixed by
   the target name and its shared application name (`UnrealClient`,
   `UnrealServer`, `BootstrapPackagedGame`) under the engine, every plugin,
   and the project directory, plus their intermediate folders, makefiles,
   and `Intermediate/Build/SourceFileCache.bin`. None of those prefixes match
   `UnrealEditor*`, `UnrealPak*`, or `ShaderCompileWorker*`, but
   `-NoEngineChanges` does not guard clean deletions at all; the final
   re-verification below is the actual proof.
5. **Client bootstrap** (Client and All only) — `BootstrapPackagedGame Win64
   Shipping` is cleaned and built the same way (an engine program outside the
   attested closure). Windows staging wraps the client in this launcher only
   when `Engine/Binaries/Win64/BootstrapPackagedGame-Win64-Shipping.exe`
   exists; the UAT agenda used to build it, and staging would silently omit
   the launcher otherwise, so the controller asserts the executable is absent
   after the clean and present after the build. The server job does not
   build it: the old agenda did so there only because UAT defaults the client
   platform list to the host platform, and Linux staging never consumed it.
6. **UAT** — `BuildCookRun ... -skipbuild -cook -clean -stage -pak -archive`
   with the same target, platform, configuration, archive, and server
   never-cook arguments as before. Staging reads the receipts written in
   step 4.
7. **Final attestation re-verification** — after output validation (and the
   server registry dumps), before any `phase-*.json` or provenance is
   written. A host tool changed by anything in steps 4-6, UAT included, stops
   the run; the attestation is never regenerated to make changed products
   pass.

Compiler evidence moves with the build: under the prebuilt boundary the
`Compiler:` and `Resource Compiler:` lines are read from the controller's
client build log (`<LogRoot>/ubt/UBT-AethelnOnlineClient-Win64-<config>.txt`,
written through UBT's `-Log=`), because UAT never initializes a toolchain
without its build agenda; under Rebuild they still come from UAT's
`UBA-*.txt` sidecars. Each explicit invocation is recorded (label, executable,
exact arguments, console and UBT log names, start, duration, exit code) in
`build-timing.json`'s substeps, in the split-stage records (`phase-client.json`
and `phase-server.json`, schema version 2, `hostToolsMode` and
`buildInvocations`), and in `build-provenance.json` (schema version 3,
`build.hostToolsMode` and `build.explicitBuildInvocations`); the provenance
writer refuses a prebuilt record without invocations, a rebuild record with
them, or any invocation whose exit code is not zero. A cook or package that
passes is never reported as a successful build on its own.

The verified boundary is recorded in `build-timing.json` under `hostTools`,
and the exact UAT arguments (including `-skipbuild`) flow into the stage
records and provenance unchanged. Attestation and timing evidence keep
host-tool paths engine-relative. Runtime facts this sequence has not yet
measured on the engine runner: whether the preparation passes
`-NoEngineChanges` against the attested engine build, the duration of the
preparation, the two clean/build pairs, and the three attestation hash
passes inside each job's 30-minute watchdog, and whether the cook then
succeeds with the prepared modules.

## Runner configuration

On the approved engine runner the gate
(`scripts/ci/Invoke-EngineRunnerGate.ps1`) reads these machine-level
environment variables for the packaging modes (`PackagedSmoke`,
`PackageClient`, `PackageServer`):

- `AETHELN_DDC_ROOT` (optional) — existing local fixed-drive directory,
  disjoint from the repository, engine, toolchain, archive, log, and handoff
  roots. Invalid configuration fails closed with `ddc_root_invalid`.
- `AETHELN_DDC_FALLBACK` (optional) — `fail-closed` (default) or
  `clean-isolated`; anything else fails closed with `ddc_fallback_invalid`.
- `AETHELN_HOST_TOOLS` (**required**) — `prebuilt` for the scheduled clean
  milestone (requires the attestation below), or `rebuild-authorized` as the
  explicit, separately named operator authorization for a full host-tools
  rebuild. Unset fails closed with `host_tools_configuration_required`;
  anything else (including the retired implicit `rebuild`) fails closed with
  `host_tools_invalid`.
- `AETHELN_ENGINE_REVISION` — required with `prebuilt`: the full canonical
  pinned engine commit hash; missing or malformed fails closed with
  `engine_revision_invalid`.
- `AETHELN_HOST_TOOLS_ATTESTATION` — required with `prebuilt`: the
  attestation record file, an existing local fixed-drive file disjoint from
  every approved root; missing or invalid fails closed with
  `host_tools_attestation_invalid`.

The gate records a `ddc-cache-configuration` check (`ddc_configured` or
`ddc_not_configured`) and a `host-tools-configuration` check
(`host_tools_prebuilt` or `host_tools_rebuild_authorized`), forwards the
resolved values plus its validated runner name to
`Build-PackagedArtifacts.ps1` (which owns the fail-closed proofs), and
records the validated runner name in `engine-runner-report.json`. See
[Continuous Integration](continuous-integration.md) for the gate contract.

## Evaluation ladder beyond the local DDC

In the authorized evaluation order, the states of the remaining options:

1. **Persistent local DDC with explicit identity** — implemented above;
   before/after proof requires the lead-authorized measured engine runs.
2. **Local Zen/DDC service health and safe fallback** — the identity and
   fallback model above applies to the local cache directory; a Zen server
   endpoint adds an availability dependency and is only worth adopting with
   measured evidence that the plain local cache is the bottleneck. Runner
   service configuration is an owner/operator action, never performed by CI.
3. **Unreal-supported engine-binary boundary** — implemented as the explicit
   fail-closed prebuilt host-tools boundary above (UAT `-skipbuild` with
   controller-owned project builds in the pinned UE 5.8.1 source, gated on
   proof that the host tools belong to the exact clean pinned engine
   revision and re-verified after every build step). The pinned engine
   artifact the runner consumes is unchanged; before/after proof requires
   the lead-authorized measured engine runs.
4. **Build acceleration or hardware** — a later owner decision, justified
   only by measured evidence the earlier rungs cannot address.

Use `build-timing.json` and the engine-runner report from a before/after pair
of authorized clean milestone runs at the same source revision to attribute
time before proposing rungs 3 or 4.
