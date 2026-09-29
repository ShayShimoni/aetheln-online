# Developer Environment and Derived Data Cache

This document is the canonical reference for reducing elapsed machine time of
the periodic clean Windows-client and Linux-server packaging milestone
(Issue #81) without weakening its clean-build, cooking, staging, archive,
registry-validation, provenance, or packaged-smoke semantics.

## Where clean-package time can go

A clean milestone run spends its time in a small set of categories. Do not
attribute the duration to any of them without evidence:

- C++ compilation of the client and dedicated-server targets by
  UnrealBuildTool (engine modules plus project modules under `-clean`).
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
  `not_configured`), and `engineRevision` (the verified canonical pinned
  engine commit, null otherwise). A failed boundary stops the run with the
  `host-tools-boundary` substep recorded as failed.
- `substeps`: bounded list of controller steps
  (`evidence-identity-resolution`, `host-tools-boundary`,
  `derived-data-cache-resolution`, `target-composition-gate`,
  `client-uat-build-cook-package`, `client-output-validation`,
  `server-uat-build-cook-package`, `server-output-validation`,
  `server-dependency-registry-dump`, `server-cooked-inventory-dump`,
  `server-cook-reference-gate`, `provenance-write`) with `startedUtc`,
  `durationSeconds`, and `status`.
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
  -HostToolsAttestationPath <file>` — skip rebuilding the host editor/engine
  tools by passing `-nocompileeditor`, which the pinned UE 5.8.1 source maps
  to `SkipBuildEditor` and which omits the editor targets from
  `BuildProjectCommand`. The client and server project targets still build
  with `-clean`, and every cook, stage, package, archive,
  registry-validation, provenance, and smoke phase still runs.
- An unset selection fails closed with `host_tools_configuration_required`
  (`Stage Provenance` runs no build phase and takes no host-tools
  parameters).

### Explicit non-clean host-tool provisioning

When the pinned engine checkout lacks host-tool products, an operator may run
`scripts/build/Invoke-HostToolProvisioning.ps1` with `-Execute`. This is a
separate, bounded source-build operation, not a packaging mode or CI fallback.
It requires clean controller and engine Git trees, the exact canonical engine
commit, and preflight plus per-target prelaunch comparison of every tracked
`Engine/` input with its `HEAD` blob. Any assume-unchanged or skip-worktree
index flag fails closed,
including flags that make `git status --porcelain` appear clean. Git's normal
checkout text normalization is applied when comparing file content. This
prelaunch check does not freeze the checkout against concurrent edits while
the build runs; the operator must retain exclusive control of the engine
source tree for the attempt. It also requires no unproven preexisting Win64
engine, engine-plugin, or UnrealBuildTool outputs and intermediates (tracked
source-support binaries and exact files
verified by SHA-1 against a pinned, tracked GitDependencies manifest are
allowed; a clean Git tree alone does not prove ignored product provenance),
the pinned MSVC/SDK paths, the existing shared engine-host `.lease`
file, and a new external evidence directory on the current operator's **F:**
volume. F: is a local operational constraint for this provisioner, not a
canonical contributor-machine layout. It runs only pinned `Build.bat`
`UnrealPak`, `ShaderCompileWorker`, and `UnrealEditor` Win64
Development targets. It passes explicit local-only executor flags and at most
`min(4, physical cores, floor((available RAM GiB - 6)/3),
floor((commit headroom GiB - 6)/3))` actions. It never runs UAT, invokes
`-clean`, explicitly removes existing engine outputs, or falls back to a
rebuild. Each target is admitted through the shared resource monitor, so the
receipt records three target admissions and the minimum/maximum admitted
action limits on a completed three-target attempt.

The attempt has one monotonic envelope: useful work stops by 330 minutes,
owned-tree cleanup and lease release must be proven by 340 minutes, and the
create-only local receipt must be written by 360 minutes. These are ceilings,
not expected runtime or permission to launch an engine run. The existing
resource monitor samples at five-second intervals, rejects three consecutive
low-RAM or low-commit samples, and maintains a 20 GiB free-space floor on each
involved physical volume. Any missing product, unproven selected toolchain,
nonzero exit, zero/unknown action plan, absent action progress, unchanged
required executable, deadline, pressure, or unproven cleanup fails closed. No automatic retry is
made; after a valid evidence root exists, failure logs/receipts remain on F:
for diagnosis. The shared host lease is released only when owned-child cleanup
is proven.
The shared lease is acquired **before** probing the engine source, tool inputs,
and outputs, then held through the build. In particular, the fresh-output
preflight rejects a reusable `UnrealBuildTool.dll`, its dependency CSV, and
generated .NET `bin`/`obj` products: the pinned engine's `Build.bat` calls
`BuildUBT.bat`, which can otherwise skip rebuilding UBT from source.
Normal `Setup.bat` hydration is not mistaken for a prior host build: only
manifest-listed Win64 engine/plugin files with matching content hashes pass;
unlisted, changed, case-colliding, or reparse-mediated files fail closed.

From a clean committed controller checkout, an authorized operator supplies
existing validated paths and a *new* F: evidence root:

```powershell
./scripts/build/Invoke-HostToolProvisioning.ps1 -Execute `
  -EngineRoot $AethelnEngineRoot `
  -EvidenceRoot $AethelnNewFDriveEvidenceRoot `
  -HostLeasePath $AethelnExistingHostLeasePath `
  -CompilerPath $AethelnPinnedClExe `
  -ResourceCompilerPath $AethelnPinnedRcExe
```

Review `host-tool-provisioning-receipt.json` and each target's local `build.log`
before using a successful receipt as `-ProvisioningEvidence` for the **separate**
`Build-PackagedArtifacts.ps1 -Stage AttestHostTools` step below. The provisioner
checks target-receipt metadata and referenced product closure before reporting
success, but never creates an attestation. An existing mixed-output engine checkout is
ineligible: use a separate fresh pinned checkout; this command never cleans or
deletes those outputs. If the tools already exist unchanged and UBT
performs zero actions, the provisioner does not relabel that incremental result
as newly provisioned; use independently retained successful build evidence or
escalate the non-clean provisioning gap. A successful provisioner fixture test
does not prove a real engine run, clean Editor reproduction, packaged build,
cache speedup, or Issue #81 completion.

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
form the complete closure `-nocompileeditor` would skip. Symbol/debug and
link-time-only products are excluded; unknown product types, receipt metadata
mismatches, paths escaping the engine root, reparse-mediated paths, and
duplicate or case-colliding products fail closed, and receipt size, product
count, per-file size, and overflow-checked aggregate size are all bounded.
Run it once after an explicit authorized provisioning/rebuild — the retained
evidence of the authorized legacy build qualifies as the one-time host-tool
source; never start a full rebuild merely to create the record.

### Prebuilt consumption proofs

`-nocompileeditor` is added only after every proof passes; any failure stops
the run with an actionable error — the boundary never falls back silently to
another monolithic engine rebuild:

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

The verified boundary is recorded in `build-timing.json` under `hostTools`,
and the exact UAT arguments (including `-nocompileeditor`) flow into the
stage records and provenance unchanged. Attestation and timing evidence keep
host-tool paths engine-relative.

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

### Shared-DDC decision record (candidate only)

**Current topology evidence (2026-09-28):** GitHub lists one registered
Windows engine runner for this repository; Issue #81 records the current
owner-operated clean-package path, but no measured second contributor/cook host
or shared-cache traffic. This is a dated inventory, not a claim that no other
contributors exist. A cache shared between processes on that one host would
add no cross-machine reuse; the local DDC remains the working baseline. No
shared endpoint, provider, namespace, or budget is approved.

| Candidate | Fit and access boundary | Cost and failure/poisoning boundary |
| --- | --- | --- |
| Local DDC only | Fits the evidenced single-runner topology; write access stays within local filesystem permissions. | Uses local SSD capacity and re-derivation time; no network service. A compromised local writer can still corrupt its cache, so use the identity and clean-isolated recovery above. |
| SMB fileshare | Revisit for multiple measured cooks on a trusted LAN/VPN. Require authenticated accounts, restrictive share and filesystem ACLs, and protected transport; do not expose SMB to the public internet. | Host/disk, monitoring, network, and operator costs are `TBD`. A disconnected/slow share must be tested against an isolated local re-derivation path. Any writer with share permissions can poison or delete entries; a namespace/path name alone is not authorization. |
| Shared Zen server | Revisit for multiple trusted LAN/VPN cooks with measured latency and cache-hit benefit. Epic states this server is unauthenticated: any reachable user has read/write/delete access, and Zen namespaces do **not** enforce access control. Do not expose it to the internet or untrusted contributors. | Server/storage/network/operations costs are `TBD`. Epic expects local cache to preserve access during shared-layer downtime, at lower performance; verify that behavior in this project's graph. A reachable malicious writer can poison, corrupt, or erase shared data. |
| Unreal Cloud DDC | Candidate only if remote/multi-region cooks justify an internet-reachable service. Require HTTPS, OIDC authentication, and least-privilege namespace ACLs; never use its unauthenticated example configuration. | Storage, database, identity, network/egress, operations, and recovery costs are `TBD`. Test outage and local re-derivation behavior; compromised write credentials can still poison a namespace. Cloud DDC is not a source-of-truth or build-provenance store. |

Before selecting any shared layer, the Issue #81 owner must record actual
contributor/runner locations and trust domains, cold/warm cook hit rates and
elapsed times on identical inputs, cache bytes and growth, network latency and
transfer, a cost estimate, and outage/recovery tests. Test a wrong-identity or
malicious-write candidate in an isolated namespace without exposing the
production cache; untrusted PR code must not publish to a trusted shared
cache. A successful DDC lookup is not evidence that a package came from
trusted source: exact source/engine/toolchain identity, clean target builds,
artifact provenance, and packaged smoke remain independent gates. The owner
revisits this `TBD` when a second independent cook host is measured, local
capacity or re-derivation becomes material, or the trust topology changes.

These candidate properties follow Epic's [shared Zen guidance](https://dev.epicgames.com/documentation/en-us/unreal-engine/set-up-zen-storage-server-as-shared-ddc-for-unreal-engine),
[Cloud DDC deployment and ACL guidance](https://dev.epicgames.com/documentation/en-us/unreal-engine/how-to-set-up-a-cloud-type-derived-data-cache-for-unreal-engine),
and [DDC overview](https://dev.epicgames.com/documentation/en-us/unreal-engine/using-derived-data-cache-in-unreal-engine);
Microsoft documents [SMB access and transport controls](https://learn.microsoft.com/en-us/windows-server/storage/file-server/smb-security).
The no-selection conclusion is an inference from this project's current
single-runner evidence, not an Epic or Microsoft recommendation for every
team.

In the authorized evaluation order, the states of the remaining options:

1. **Persistent local DDC with explicit identity** — implemented above;
   before/after proof requires the lead-authorized measured engine runs.
2. **Local Zen/DDC service health and safe fallback** — the identity and
   fallback model above applies to the local cache directory; a Zen server
   endpoint adds an availability dependency and is only worth adopting with
   measured evidence that the plain local cache is the bottleneck. Runner
   service configuration is an owner/operator action, never performed by CI.
3. **Unreal-supported engine-binary boundary** — implemented as the explicit
   fail-closed prebuilt host-tools boundary above (`-nocompileeditor` /
   `SkipBuildEditor` in the pinned UE 5.8.1 source, gated on proof that the
   host tools belong to the exact clean pinned engine revision). The pinned
   engine artifact the runner consumes is unchanged; before/after proof
   requires the lead-authorized measured engine runs.
4. **Build acceleration or hardware** — a later owner decision, justified
   only by measured evidence the earlier rungs cannot address.

Use `build-timing.json` and the engine-runner report from a before/after pair
of authorized clean milestone runs at the same source revision to attribute
time before proposing rungs 3 or 4.
