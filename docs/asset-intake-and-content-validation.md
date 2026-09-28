# Asset Intake and Content Validation

## Purpose

This contract governs how source references, temporary prototype assets, runtime
candidates, and production-approved content enter Aetheln Online. Repository
presence, generation, import, or a successful cook never grants canonical or
production approval.

The machine-readable policy lives at
Config/ContentValidation/asset-intake-policy.json. Its closed schema is
Config/ContentValidation/asset-intake-policy.schema.json. The complete current
runtime-package registry lives at
Config/ContentValidation/runtime-asset-intake.json under the closed
Config/ContentValidation/runtime-asset-intake.schema.json contract.

## Lifecycle gates

Every asset is concept_reference, temporary_prototype, runtime_candidate, or
production_approved. Grandfathering requires an owner and recovery trigger and
never promotes temporary content.

| State | Permitted use | Entry evidence | Exit gate |
| --- | --- | --- | --- |
| `concept_reference` | Review and direction outside runtime `Content/` | Source record, author/provider, rights status, and owner | Rights and intended use are reviewed before prototype or candidate work |
| `temporary_prototype` | Time-bounded prototype use only | Explicit temporary owner, expiry or recovery trigger, source hash, and rights evidence | Full intake and validation are rerun; grandfathering alone cannot advance it |
| `runtime_candidate` | Reviewed development runtime and evidence generation | Complete provenance, matching rights, stable identity/version/audience, all applicable deterministic checks passed, named reviewer, and approval record | Production review accepts the exact revision and evidence |
| `production_approved` | Approved production use for the recorded scope | Runtime-candidate evidence plus explicit production reviewer and approval record | Any source, rights, version, audience, policy, or binary change returns the asset to review |

Normal forward flow is `concept_reference` to `temporary_prototype` or
`runtime_candidate`, then `runtime_candidate` to `production_approved`.
Temporary content is never promoted by age, repository presence, successful
import, or successful cook. Missing, expired, inconsistent, or incompatible
evidence blocks the transition and keeps the last defensible state.

Keep lifecycle and technical quality separate from author/provider, durable
source record, source version, license or permission evidence, modifications,
generation metadata when applicable, exact content SHA-256, reviewer, and
approval state. Automation must not download content, accept terms, infer a
license, or turn missing evidence into approval.

The intake record keeps technical validation separate from rights approval.
Every runtime candidate names the exact author or provider, durable source
record, source and tool version, permission or license evidence, modifications,
generation metadata or `not_applicable`, lowercase SHA-256, reviewer, and
approval state. A generated output follows the same rights review as any other
source. No marketplace, AI authoring system, DCC package, MCP bridge, or other
vendor/tool is selected by this policy; those decisions remain `TBD` until
their owning evidence and approval exist.

## Closed runtime registry

Every committed `.uasset` and `.umap` below `Content/` has exactly one registry
record. A record binds its repository path to the corresponding `/Game` package,
persistent stable ID, positive content version, audience, lifecycle, exact Git
LFS object SHA-256, source group, temporary-use owner and approval record, and
recovery trigger. An added, removed, renamed, duplicated, unhashed, or stale
package makes the portable registry check fail closed.

The current registry contains 51 packages and only facts recoverable from the
accepted Issue #13 and Issue #100 records:

| Source record | Packages | Current audience | Current lifecycle |
| --- | ---: | --- | --- |
| Issue #13 blank-project `StarterMap` | 1 | `shared` because it remains the documented server default map | `temporary_prototype` |
| Issue #100 Epic character-template closure | 39 | `client_only` under the approved local-only movement POC | `temporary_prototype` |
| Issue #100 Epic Level Prototyping closure | 6 | `client_only` under the approved local-only movement POC | `temporary_prototype` |
| Issue #100 repository-authored map and Blueprint POC packages | 3 | `client_only` | `temporary_prototype` |
| Issue #100 template-derived POC animation packages | 2 | `client_only` | `temporary_prototype` |

Issue #100 is permission for that exact one-time temporary closure, not an
independent conclusion about an Epic license. The registry names Epic as the
provider where known and does not infer individual authorship. Issue #13's
approved bootstrap created a blank project with no Starter Content; its record
does not imply production-art approval. All 51 records explicitly prohibit
promotion through grandfathering.

Source groups carry shared author/provider, source, permission, modification,
generation, reviewer, naming, import, and reimport evidence. Per-package records
carry the immutable binary hash and lifecycle evidence. The editor scanner
derives family applicability and technical observations from live Asset
Registry and object facts; the intake registry has no author-supplied family
applicability or pass field.

## Asset-class intake matrix

SourceAssets/ is the future source-only root for editable originals and intake
records. Content/ contains Unreal runtime packages. Moving a file there does
not approve it. Follow [Source Control](source-control.md) for LFS, locking,
naming, and recovery.

`SourceAssets/` is a reserved future root, not authority to add binaries in this
change. Until an asset-owning ticket authorizes a concrete source path, keep the
source outside runtime `Content/` and record its durable location without
committing private credentials or license material.

| Asset class | Source and runtime placement | Naming and ownership | Import and reimport record | Git LFS and locking | Recovery |
| --- | --- | --- | --- | --- | --- |
| Unreal map or package (`.umap`, `.uasset`) | Runtime package under its approved `/Game` audience/domain folder; editable upstream source remains separate | Unreal prefix plus descriptive PascalCase object name; intake record names the package/folder owner and stable ID owner | Exact source hash, importer/plugin and version, settings, dependencies, and change intent | LFS binary; lock before editing except reviewed OFPA external packages | Preserve every working copy, stop saves, coordinate the owner/lock, then validate map, references, cook, and stable IDs |
| DCC and layered source (`.blend`, `.psd`, `.psb`) | Source-only; never cooked | Descriptive source name linked to the runtime stable ID and owning ticket | DCC/tool version, units, axes, scale, export preset, and source hash | LFS binary and lockable | Retrieve the exact reviewed LFS object; never regenerate a missing object as a substitute |
| Interchange source (`.fbx`, source texture, source audio) | Source-only input; derived runtime package lives under `Content/` | Source name maps one-to-one to the intake record; runtime object uses its Unreal prefix | Importer version, color/normal/channel interpretation, compression, scale, skeleton or material mapping, and reimport preset | LFS binary and lockable | Preserve input and derived package, restore the reviewed source object, and rerun import plus family validation |
| Generated or procedural input/output | Source recipe/input and review record remain separate; only reviewed runtime output enters `Content/` | Stable ID identifies the governed output, not a prompt, seed, filename, or vendor | Tool/model/plugin version, parameters or graph version, authoritative seed owner when applicable, modifications, and hashes | Apply the underlying file type's LFS/lock rule | Preserve recipe, input, and output; a rerun is a new candidate until hashes and evidence are reviewed |
| Text policy, metadata, or intake record | Tracked text outside `Content/` unless Unreal runtime loading explicitly requires a governed data asset | Lowercase kebab-case file name; schema ID/version and owner are explicit | Record schema/tool version and review, not binary importer settings | Normal Git text with LF endings | Repair from reviewed text history without editing evidence to hide a failure |

New Unreal object names use the narrow conventional prefix for their class,
such as `DA_`, `DT_`, `BP_`, `WBP_`, `SM_`, `SK_`, `T_`, `M_`, `MI_`, `A_`,
or `NS_`, followed by a descriptive PascalCase name. The stable content ID is a
separate lowercase dotted identifier such as `content.world.objective`; package
or display renames never silently change it. The intake record owns any
exception so two packages cannot claim one identity.

Before first import or reimport, record the exact source hash, tool/importer and
version, deterministic settings, intended package, stable ID, content version,
audience, owner, and reviewer. A reimport is never an unreviewed overwrite: keep
the previous reviewed package and source recoverable, compare the resulting
dependencies and family evidence, and explicitly decide whether the content
version changes.

## Reference and cook boundaries

UAethelnPrimaryAssetDefinition supplies a stable content ID independent of
package renames, a positive content version, and one audience: Shared,
ServerOnly, or ClientOnly. Asset Manager scans maps, primary asset labels, and
the generic Aetheln definition. Chunk IDs remain unresolved.

The configured `Map`, `PrimaryAssetLabel`, and `AethelnContent` scans establish
discovery only. They do not approve content, select a chunking strategy, or
override the asset's governed audience. Authoritative definitions use stable
Primary Asset IDs and positive content versions. A missing or incompatible
version fails closed; it never falls back to a different gameplay definition.

Hard-reference reachability is:

| Source audience | Allowed hard-reference audience |
| --- | --- |
| Shared | Shared |
| ServerOnly | Shared or ServerOnly |
| ClientOnly | Shared or ClientOnly |

Presentation variants use soft references where practical. Soft references are
denied by default: one declared rule must match the complete anchored source
package path, source audience, complete anchored target package path, and target
audience. The policy permits `shared` to `shared` or optional `client_only`
presentation, `server_only` to `shared` or `server_only`, and `client_only` to
`shared` or `client_only`. It does not permit `shared` to `server_only`. These
rules govern `/Game` package paths without inventing future product-folder
ownership; a partial, prefix-only, suffix-only, or audience-only match fails.

A hard-reference exception is denied by default and must name its owner,
justification, source and target audiences, reviewer, approval record, and
revisit trigger. It must still produce valid client and dedicated-server cook
separation.

Shared content must be in client and server cooks. Server-only content must be
absent from client, and client-only content absent from server. Broken
references, candidate or approved redirectors, duplicate IDs, invalid versions,
editor-only runtime dependencies, and undeclared hard-reference exceptions
fail validation.

`Shared` packages are required in both targets. `ServerOnly` packages are
required in the dedicated-server cook and prohibited from the client cook.
`ClientOnly` packages are required in the client cook and prohibited from the
dedicated-server cook. The existing dedicated-server dependency validator also
rejects hard reachability to UI, audio, Niagara, camera, input, and high-detail
presentation families; this intake comparator does not replace it.

## Rename, move, and recovery

A rename or move preserves the stable ID, updates every governed reference, and
increments the content version only when compatibility or behavior changes.
Before review, fix up redirectors in the Unreal Editor, rescan the Asset
Registry, and prove that no accepted runtime package depends on an unresolved
redirector. Never byte-edit or text-rewrite a `.uasset` or `.umap`.

Duplicate stable IDs, missing packages, broken soft or hard references,
unresolved candidate/approved redirectors, editor-only runtime dependencies,
and incompatible content versions fail closed. Preserve both sides of a
conflict, stop further asset saves, identify the current lock and owner, select
the authoritative result through editor review, reapply the losing intent when
required, and rerun identity, reference, map, and cook validation. A missing or
malformed LFS object is recovered through the exact approved object; it is not
recreated from memory or a different source.

## Validation family contract

Validation covers collision; LOD, HLOD, and Nanite suitability; texture PBR
channels, tiling, compression, mips, and streaming; material instances and
shader evidence; skeletal mesh, rig, morph, influence, socket, and animation
complexity; maps, Data Layers, PCG, navigation; and audience boundaries.

| Family | Deterministic checks | Stable failure code |
| --- | --- | --- |
| `collision` | Profile, simple/complex policy, and equivalent authoritative collision across presentation variants | `content.collision.failed` |
| `rendering_suitability` | LOD/HLOD applicability, Nanite suitability, and streaming evidence | `content.rendering_suitability.failed` |
| `texture` | PBR channel meaning, tiling, compression, mip, and streaming setup | `content.texture.failed` |
| `material` | Material-instance policy and shader-complexity evidence | `content.material.failed` |
| `skeletal_animation` | Rig compatibility, morph policy, influences, socket ownership, and animation complexity | `content.skeletal_animation.failed` |
| `map_world` | Map identity, Data Layers, PCG authority, and runtime/editor-only boundaries | `content.map_world.failed` |
| `navigation` | Server-required navigation data, streaming boundaries, and rebuild policy | `content.navigation.failed` |
| `reference_boundary` | Unique stable ID, redirectors, broken references, compatible versions, audience reachability, and hard-reference exceptions | `content.reference_boundary.failed` |

Applicability is explicit for every family. `not_applicable` requires evidence;
silence is not a pass. Deterministic violations are errors. An unresolved
quantitative threshold produces `non_promotion` even when every deterministic
check passes.

Maps remain owned by their map-delivery issues. This shared gate verifies map
identity, references, runtime/editor separation, Data Layer declarations, PCG
authority and version evidence, navigation audience, and cook reachability; it
does not choose per-map World Partition, HLOD, PCG, navigation, or gameplay
design. World Partition remains per-map streaming and never server distribution.
The live scanner records navigation audience as `evidence_unavailable`, so the
`navigation` family stays `non_promotion` until a producer binds governed
navigation packages to exact client/server cook evidence and the pinned-Editor
tests have run. Authored C++ fact tests do not establish that evidence.

No numeric limit is invented. A quantitative threshold is accepted evidence or
literal TBD with an owner and revisit trigger. TBD produces a non-promotion
finding; it never erases a deterministic failure.

Collision complexity; LOD/HLOD/Nanite; texture memory/streaming; shader
complexity; bones, influences, morphs, and animation; map/Data Layer/PCG; and
navigation budgets remain literal `TBD`. Issue #45 and the owning map or content
ticket must supply accepted representative measurements before promotion. This
policy does not select Nanite, HLOD, PCG, a marketplace, an AI authoring system,
an MCP bridge, or another vendor/tool.

## Evidence and deferred gates

The closed version-2 content validator report records the exact clean repository
revision, engine tag and revision, engine binary and build-version hashes,
target, platform, configuration, Editor build command and log hashes, compiler
and resource-compiler versions and hashes, project, policy, intake-registry and
invocation hashes, Asset Registry source, audience, command, UTC timestamps,
counts, governed assets, findings, and result. Its target receipt and module
manifest descriptors each bind a canonical repository-relative path, positive
byte size, lowercase SHA-256, and nonblank build ID. Loaded project modules are
exactly `GameCore` then `GameTests`, with the same descriptor fields plus the
module name, and all four Editor artifacts share one build ID. The
top-level policy and intake hashes must equal their execution-provenance copies;
the engine identity must bind the exact tag and revision. Each finding names its
policy, asset, severity, reason, remediation, evidence field, and stable
diagnostic code. Counts cover assets, findings, errors, and non-promotion
outcomes. Each asset record includes lifecycle evidence, provenance/rights,
stable identity, content version, audience, and one result for every policy
family. Version-2 family results keep deterministic pass/fail separate from
promotion eligibility and enumerate every declared check exactly once.

The portable fixture suite produces a representative passing report and one
intentionally failing report for each policy family, then verifies missing
rights, lifecycle, approval, intake, and execution-provenance evidence fail
closed. These are contract fixtures, not evidence about a real asset. The local
entry point invokes the repository commandlet against the live Asset Registry;
its guarded snapshot mode exists only for deterministic wrapper and commandlet
tests and is identified as `test_snapshot` in the report.

Under the separately authorized engine gate, run the live local scanner. Its
wrapper first builds the exact `AethelnOnlineEditor Win64 Development` target
and derives the exact versioned toolchain and module evidence from that build:

    powershell -NoProfile -File scripts/content/Invoke-ContentValidation.ps1 -EngineRoot <UE-5.8.1-source> -OutputPath TestResults/content-validation-report.json

`-EngineRoot` is mandatory. The wrapper verifies the clean repository revision,
pinned engine tag/revision, binary and contract hashes, hashes the fresh Editor
build command and log, records the compiler/resource-compiler identities,
validates the target receipt, module manifest, and exact loaded project-module
set, then launches
`-run=GameTests.AethelnContentValidation`, and rejects stale, mismatched, or
malformed output. `-AssetRegistrySnapshotPath` is test-only and is rejected
unless `-AllowTestRegistrySnapshot` is also present; the guard is not authority
to substitute a fixture for live editor evidence.

After the separately authorized, serialized
`Build-PackagedArtifacts.ps1 -Stage All` run completes, capture only its two
canonical runtime registries:

```powershell
powershell -NoProfile -File scripts/build/Invoke-CookedInventoryCapture.ps1 `
  -ProjectPath AethelnOnline.uproject `
  -EngineRoot <UE-5.8.1-source> `
  -BuildProvenancePath <archive-root>/build-provenance.json `
  -ContentValidationReportPath TestResults/content-validation-report.json `
  -ClientCookedRegistryPath Saved/Cooked/WindowsClient/AethelnOnline/AssetRegistry.bin `
  -ServerCookedRegistryPath Saved/Cooked/LinuxServer/AethelnOnline/AssetRegistry.bin `
  -OutputRoot TestResults/cooked-inventory
```

Use a new or empty `OutputRoot`; capture refuses to mix with or overwrite prior
evidence. Live capture rejects every other registry path. Before invoking
`DumpAssetRegistry`, it copies the exact client and server registry bytes to
`TestResults/cooked-inventory/client/AssetRegistry.bin` and
`TestResults/cooked-inventory/server/AssetRegistry.bin`, and copies the exact
build provenance to `TestResults/cooked-inventory/build-provenance.json`. The
command reads only the staged registry copies. Each closed version-2 inventory
manifest binds the canonical source path, manifest-relative staged path,
positive byte size, lowercase SHA-256, target, build platform, cook platform,
build-provenance digest and source revision, cook and capture commands, and
every inventory page. Source registries, staged copies, build provenance,
project, policy, intake, report, engine build identity, and executing dump
command are checked before and after capture; any same-path mutation or drift
fails the run.

The packaging producer (`Build-PackagedArtifacts.ps1`) hashes each canonical
`AssetRegistry.bin` immediately after that target's own cook and records the
receipt (relative path, byte size, SHA-256, target, platform, cook platform, and
source revision) in its stage record and in `build.cookedRegistries` of
`build-provenance.json`. Capture refuses registry bytes that differ from the
matching receipt, and the comparator refuses a manifest whose registry size or
digest differs from it, so a stale, substituted, cross-target, or cross-revision
registry cannot be attested by a self-consistent manifest. If a registry is
missing or was rewritten after its receipt (for example by a later cook in the
same workspace), live capture fails closed rather than accepting other bytes.

Compare those immutable captures with:

```powershell
powershell -NoProfile -File scripts/build/Validate-ContentCookEvidence.ps1 `
  -ContentValidationReportPath TestResults/content-validation-report.json `
  -ClientCookedInventoryDirectory TestResults/cooked-inventory/client `
  -ServerCookedInventoryDirectory TestResults/cooked-inventory/server `
  -BuildProvenancePath TestResults/cooked-inventory/build-provenance.json `
  -OutputPath TestResults/content-cook-evidence.json
```

The comparator accepts a policy-consistent `non_promotion` report so deterministic
client/server boundaries can still be measured while quantitative budgets remain
`TBD`. Its output preserves `non_promotion`; it never converts that result into a
promotion-capable pass. A report containing a deterministic error remains blocked.

The comparator creates private immutable snapshots of the report, policy,
intake registry, build provenance, staged cooked registries, manifests, and
pages before parsing. It rejects an output path that could overwrite an input,
including one that traverses a junction or other reparse point, holds
deny-write locks on every input while it publishes, refuses to publish over a
hardlink alias of an input, and holds every output ancestor unrenameable until
publication is verified. It creates the pending evidence by handle, proves
through that handle that the file sits inside the held parent (so an empty
parent converted to a mount point is detected), and renames that exact file
object into place relative to the held parent handle; it never deletes a path,
and a failed publication deletes only the file object it created. It rechecks
the complete source file set before and after validation, and emits
version-3 evidence carrying both registry attestations. Neither capture nor
comparison builds, cooks, packages, downloads content, or accepts terms.
Fixture success is not representative cook evidence.

Run portable checks with:

    powershell -NoProfile -File tests/content/Invoke-ContentValidation.Tests.ps1
    powershell -NoProfile -File tests/content/Invoke-ContentValidationCommand.Tests.ps1
    powershell -NoProfile -File tests/build/Invoke-CookedInventoryCapture.Tests.ps1
    powershell -NoProfile -File tests/build/Validate-ContentCookEvidence.Tests.ps1

Malformed policy, report, or registry data fails closed. Fix the source issue
and rerun; never edit evidence to suppress a finding. Under Issue #16
coordination, all four portable content-validation suites are default required
checks in `Invoke-CiSuite.ps1`. Clean packaging or cook execution remains
separately authority-gated.

The comparator hashes the accepted content-validation report, build provenance,
both staged registries, both closed manifests, and every inventory page into
its machine-readable result. The inputs must come from the same clean source
revision and pinned engine/toolchain as the report. A fixture cannot prove that
binding: real client and dedicated-server cook evidence remains deferred,
together with the pinned-engine compile and editor execution gates. Issue #15
owns build/cook execution, Issue #16 owns CI execution and publication, and the
lead orchestrator owns shared-runner allocation.
