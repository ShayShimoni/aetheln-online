# Unreal Project Setup and First Launch

This guide is the contributor workflow for the `AethelnOnline` C++ bootstrap.
It records the approved engine revision, toolchains, template, modules,
project-generation command, Development Editor build, and first launch.

## Pinned baseline

| Component | Pin |
| --- | --- |
| Unreal Engine source | Epic tag `5.8.1-release`, commit `71fe36aac5a8df5ccd66c763ffc902b29b6a9c43` |
| Project | `AethelnOnline` |
| Template | Blank C++, no Starter Content |
| Visual Studio | Visual Studio 2022 17.14 |
| Compiler | MSVC `14.44.35207` toolset family |
| Windows SDK | `10.0.26100.0` |
| Linux cross-toolchain | `v26_clang-20.1.8-rockylinux8` |

The project defines Development Game, Client, Editor, and Server targets. Issue
#13 exercises project generation and the Editor target. The repeatable clean
Win64 client and Linux dedicated-server package workflow is documented in
[Packaged Builds](packaged-builds.md).

The project enables the `GameplayAbilities`, `EnhancedInput`, and `CommonUI`
plugins. `EnhancedInput` and `CommonUI` are denied for the dedicated-server
target so its module graph does not acquire client input or presentation code.
`GameplayTags` and `GameplayTasks` are engine modules. `CommonInput` is supplied
by the `CommonUI` plugin; it is not a separate project plugin.

The minimal plugin defaults are recorded in
[`DefaultEngine.ini`](../Config/DefaultEngine.ini) and
[`DefaultInput.ini`](../Config/DefaultInput.ini):
`CommonGameViewportClient` integrates CommonUI with the game viewport, while
`EnhancedPlayerInput` and `EnhancedInputComponent` select Enhanced Input's base
classes. These defaults do not define gameplay input mappings, bindings, or
broader UI design.

## Local prerequisites

1. Obtain Epic's Unreal Engine source and check out the exact tag and commit.
2. Install Visual Studio 2022 17.14 with the pinned MSVC toolset and Windows SDK.
3. Hydrate the pinned source engine's dependencies with its normal `Setup.bat`
   before generating project files or building. Hydration supplies source
   dependencies; it is not evidence that host tools have been built. For a
   bounded fresh-host-tool attempt that intentionally omits `Setup.bat`'s
   machine setup, use the [direct GitDependencies hydration path](developer-environment-and-ddc.md#explicit-non-clean-host-tool-provisioning)
   and record the skipped setup steps.
4. If an operator has authorized the optional fresh host-tool provisioner,
   follow [its prerequisites and command](developer-environment-and-ddc.md#explicit-non-clean-host-tool-provisioning)
   after dependency hydration and **before** `GenerateProjectFiles.bat` or
   `Build.bat`. Project generation can create UnrealBuildTool outputs that make
   that provisioner's fresh-output preflight ineligible; do not assume every
   project-generation run creates them. Otherwise continue with project
   generation and the Development Editor build below.
5. Install the pinned Linux cross-toolchain before Linux server packaging.
6. Initialize Git LFS for this repository before editing Unreal assets.

Engine and repository locations differ between contributors. Keep those paths
in the current shell or another local, untracked configuration. Never commit
machine-specific paths, endpoints, credentials, access tokens, or other
secrets.

| Local data | Examples | Created by | Repository disposition |
| --- | --- | --- | --- |
| Engine source dependencies | Pinned, manifest-listed engine support files | Source-engine `Setup.bat` or direct GitDependencies hydration | Remain in the local engine checkout; hydration is not a host-tool build. |
| Engine host build products | UnrealBuildTool, UnrealPak, ShaderCompileWorker, UnrealEditor products and engine intermediates | Pinned source-engine build steps; project generation may also produce UnrealBuildTool outputs | Remain in the local engine checkout; the fresh provisioner checks their provenance before a build. |
| Project generated files | `Binaries/`, `Intermediate/`, generated solutions and IDE state | Project generation, Editor builds, and Unreal tools | Keep ignored and untracked in the project checkout. |
| Local Derived Data Cache | Derived shaders, textures, and cook content | Unreal's derivation during Editor use or cooking | Keep local and untracked; the optional persistent cache has a separate identity and recovery contract. |

## Verify the source revision

Set explicit local roots from a PowerShell session at the repository root:

```powershell
$AethelnEngineRoot = (Resolve-Path -LiteralPath (Read-Host 'Pinned Unreal Engine source checkout')).Path
$AethelnRepoRoot = (Resolve-Path '.').Path
$AethelnProject = Join-Path $AethelnRepoRoot 'AethelnOnline.uproject'

git -C $AethelnEngineRoot describe --tags --exact-match HEAD
# Expected: 5.8.1-release

git -C $AethelnEngineRoot rev-parse HEAD
# Expected: 71fe36aac5a8df5ccd66c763ffc902b29b6a9c43
```

Stop if either value differs. Do not substitute a preview, launcher binary, or
another UE 5.8 revision.

## Generate and build

Generate the Visual Studio project files from the pinned source engine:

```powershell
& (Join-Path $AethelnEngineRoot 'GenerateProjectFiles.bat') `
  "-project=$AethelnProject" -game -engine -progress
```

Build the Development Editor target:

```powershell
& (Join-Path $AethelnEngineRoot 'Engine\Build\BatchFiles\Build.bat') `
  AethelnOnlineEditor Win64 Development $AethelnProject `
  -WaitMutex -NoHotReloadFromIDE
```

### Recovery while CI shares the engine

Until the [TA-020 isolation direction](architecture-decisions.md) is deployed
and verified, CI and contributor builds share writable engine outputs. A CI
editor build can refresh the engine BuildId even when later project work
fails, leaving a previously built contributor project unable to load its game
modules.

Wait for the lead to release the shared engine, close the affected editor,
and run the normal Development Editor `Build.bat` command above for that
project. Confirm the build succeeds and the project's module manifest matches
the current engine editor BuildId, then relaunch. Do not hand-edit generated
`.modules` files or pin a BuildId to bypass the mismatch. The earlier observed
recovery time is not a build-duration guarantee.

The lead selected an independent runner source-engine tree in
[Issue #238](https://github.com/ShayShimoni/aetheln-online/issues/238#issuecomment-5976376517);
capacity, provisioning and CI-to-contributor isolation proof remain pending.
After deployment, use the locally configured contributor engine root for these
build and launch commands. CI uses its separately provisioned runner root;
engine/plugin binaries, generated files and intermediates must not share
writable aliases. Each root retains its own applicable identity and
provisioning evidence. Until that separation is verified, continue to
serialize shared-engine consumers. Even afterward, reserve a quiet host for
performance captures.

## First launch

Open the committed starter map:

```powershell
& (Join-Path $AethelnEngineRoot 'Engine\Binaries\Win64\UnrealEditor.exe') `
  $AethelnProject /Game/Maps/StarterMap -log
```

For a non-interactive first-load smoke check:

```powershell
& (Join-Path $AethelnEngineRoot 'Engine\Binaries\Win64\UnrealEditor-Cmd.exe') `
  $AethelnProject /Game/Maps/StarterMap -game -nullrhi -unattended -nop4 `
  -nosplash -stdout -FullStdOutLogOutput -ExecCmds='Quit'
```

For issue #13 evidence, confirm project generation completes, the Development
Editor build completes, the Editor loads `/Game/Maps/StarterMap`, the map uses
`AAethelnGameModeBase`, and the initial launch reports no bootstrap-blocking
errors.

### Optional private art

Licensed and generated art lives in the private `aetheln-art` repository as
the `AethelnArt` content plugin (TA-019 in
[Architecture Decisions](architecture-decisions.md)). The project files never
name it. Collaborators with access clone it anywhere, for example
`D:\aetheln-art`. Before opening the editor, set the editor-only variable
`UE_ADDITIONAL_PLUGIN_PATHS` in the PowerShell session that launches it:

```powershell
$env:UE_ADDITIONAL_PLUGIN_PATHS = (Resolve-Path '<art-clone>\Plugins').Path
& (Join-Path $AethelnEngineRoot 'Engine\Binaries\Win64\UnrealEditor.exe') `
  $AethelnProject /Game/Maps/StarterMap -log
Remove-Item Env:UE_ADDITIONAL_PLUGIN_PATHS -ErrorAction SilentlyContinue
```

`$env:` changes only the current process and its children, and the last line
clears it from the session once the editor has started.

- Separate multiple plugin roots with `;` on Windows (`:` on Linux and macOS).
- The content-only plugin needs no build.
- If the art path is missing, `Resolve-Path` reports an error and the editor
  launches without the art.
- To browse `/AethelnArt/`, enable **Show Plugin Content** in the Content
  Browser settings.
- CI scripts and workflows never set the variable.

**Never set `UE_ADDITIONAL_PLUGIN_PATHS` persistently** (user or machine
environment), and especially not on the runner host. Editor-binary cook and
automation jobs would then load private art, and package artifacts are
uploaded from this public repository.

Never reference `/AethelnArt/` assets from
public `Content/`, `Config/`, `Source/`, `Plugins/`, or the `.uproject`; the
`formatting-policy` check rejects it.

### Second-workspace reproduction record for Issue #81

From a separate clean workspace or contributor machine, retain a local record
of the following sequence. Publish only a redacted summary and evidence
references; keep exact local paths and raw command output outside tracked docs.

1. Record the committed project SHA and pinned engine SHA, plus clean Git
   status for both checkouts. Record OS/build, CPU, memory, available disk, and
   the observed Visual Studio, MSVC, and Windows SDK versions as host facts,
   not canonical minimum hardware requirements.
2. Record source dependency hydration and whether optional fresh host-tool
   provisioning was used. If used, retain its receipt and logs locally and
   record its outcome; a successful provisioner receipt does not prove project
   generation, the Development Editor build, or Editor launch.
   For the Issue #81 F: bootstrap, use the separately registered pinned engine
   worktree and byte-verified dependency cache on the verified external NTFS
   volume. Require at least 600 GiB free before that preparation and at least
   300 GiB after hydration before compiling; these are operating thresholds,
   not engine-size estimates. Do not import the failed D: native intermediates
   or binaries.
3. Use a separate, clean project workspace for this reproduction; keep its
   generated project outputs and packages on F: as well. Run the
   project-generation and Development Editor commands above. For each,
   retain the exact resolved command, start/end times or elapsed time, exit
   code, and a concise failure summary when applicable. Confirm the
   `/Game/Maps/StarterMap` load separately if it was attempted.
4. Record whether DDC was engine-default, a verified persistent local cache,
   or not applicable to the measured step; note cold/warm state when known.
   Record D: and F: free space before and after each stage, the relevant
   product/checkpoint identities, and whether the native build was fresh or a
   verified continuation. Do not count host-tool provisioning, Editor build,
   and launch as one undifferentiated success.
   Confirm generated project directories and solutions remain ignored and
   untracked. Keep any failed step and the next required action explicit.

The second-workspace record does not substitute for Issue #15 packaged
client/server evidence or Issue #16 CI runner feasibility.

## Headless Unreal automation

After the Development Editor target is available, run the repository-owned
Issue #85 smoke and server-authority tests through the pinned source engine:

```powershell
powershell -NoProfile -File scripts/ci/Invoke-UnrealAutomationTests.ps1 `
  -EngineRoot $AethelnEngineRoot
```

`-EngineRoot` is an explicit, non-secret local path. The runner defaults to a
600-second timeout and fails closed unless it discovers and passes exactly
`Aetheln.Harness.ProjectAndModuleLoad` and
`Aetheln.GameCombat.NetworkSpike.Authority`. See
[Unreal Automation](unreal-automation.md) for the exact filter, output paths,
normalized report schema, and all nonzero exit conditions.

## Derived Data Cache

Cooking and packaged builds can reuse a persistent local Derived Data Cache
to avoid re-deriving unchanged content. The cache is opt-in, bound to the
exact clean pinned engine revision, toolchain content, repository, project,
configuration, and targets through an explicit identity record, and fails
closed (or takes a documented clean fallback) when its identity cannot be
verified. See
[Developer Environment and DDC](developer-environment-and-ddc.md) for the
identity model, path contract, fallback behavior, capacity and recovery
guidance, and the `build-timing.json` measurement record.

## Prebuilt host-tools boundary

Every packaged build must choose its host-tools behavior explicitly:
`-HostToolsBoundary Rebuild` (the explicit operator-authorized full rebuild)
or `-HostToolsBoundary Prebuilt -EngineRevision <canonical pinned commit>
-HostToolsAttestationPath <record>`; a missing selection fails closed. The
prebuilt boundary skips rebuilding the host editor/engine tools only after a
fail-closed proof: the engine root must be a clean Git checkout at exactly
the canonical approved engine revision recorded in this document's version
table, and every required host tool must match the size and SHA-256 recorded
in the external attestation record, which is produced only by the explicit
operator attestation step (`-Stage AttestHostTools`) after an authorized
provisioning build. The client and server project targets always build with
`-clean`. See
[Developer Environment and DDC](developer-environment-and-ddc.md) for the
attestation and boundary contract.

## Repository hygiene and delivery boundary

Keep `Binaries/`, `DerivedDataCache/`, `Intermediate/`, `Saved/`, generated
solutions and IDE output, and logs untracked.

Issue #13 owns project generation, the Development Editor build/open workflow,
the starter map and default-game-mode configuration, and initial-launch
evidence. Issue #15 owns clean Win64 client builds, clean Linux dedicated-server
builds, cooking, packaging, and their evidence. Follow
[Packaged Builds](packaged-builds.md) for that workflow. An issue #13 Editor
launch does not prove issue #15 has passed.
