# Unreal Project Setup and First Launch

This guide is the contributor workflow for the `AethelnOnline` C++ bootstrap.
It records the approved engine revision, toolchains, template, modules,
project-generation command, Development Editor build, and first launch.

## Pinned baseline

| Component | Pin |
| --- | --- |
| Unreal Engine source | [Private Aetheln fork](https://github.com/ShayShimoni/UnrealEngine), commit `9ab6767ecaaa724d01371ffaea14317311ae8371`, descended from Epic tag `5.8.1-release` at `71fe36aac5a8df5ccd66c763ffc902b29b6a9c43` |
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

1. Obtain authorized access to Epic's Unreal Engine source and the private Aetheln fork; check out the exact Aetheln engine commit. Do not move Epic's tag.
2. Install Visual Studio 2022 17.14 with the pinned MSVC toolset and Windows SDK.
3. Run the normal source-engine dependency and project-file setup.
4. Install the pinned Linux cross-toolchain before Linux server packaging.
5. Initialize Git LFS for this repository before editing Unreal assets.

Engine and repository locations differ between contributors. Keep those paths
in the current shell or another local, untracked configuration. Never commit
machine-specific paths, endpoints, credentials, access tokens, or other
secrets.

## Verify the source revision

Set explicit local roots from a PowerShell session at the repository root:

```powershell
$AethelnEngineRoot = 'F:\UnrealEngine\UE-5.8.1-source'
$AethelnRepoRoot = (Resolve-Path '.').Path
$AethelnProject = Join-Path $AethelnRepoRoot 'AethelnOnline.uproject'

git -C $AethelnEngineRoot rev-parse 'refs/tags/5.8.1-release^{commit}'
# Expected Epic base: 71fe36aac5a8df5ccd66c763ffc902b29b6a9c43

git -C $AethelnEngineRoot rev-parse HEAD
# Expected Aetheln pin: 9ab6767ecaaa724d01371ffaea14317311ae8371

git -C $AethelnEngineRoot merge-base --is-ancestor 71fe36aac5a8df5ccd66c763ffc902b29b6a9c43 HEAD
if ($LASTEXITCODE -ne 0) { throw 'Engine pin is not descended from the Epic 5.8.1-release base.' }

git -C $AethelnEngineRoot status --porcelain=v1 --untracked-files=all
# Expected: no output
```

Stop if either revision differs, ancestry fails, or the source checkout is dirty.
Do not substitute a preview, launcher binary, or another UE 5.8 revision. Host
tools built under the Epic base commit do not attest the custom engine pin.

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
