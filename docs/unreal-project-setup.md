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
#13 exercises project generation and the Editor target. Clean Win64 client and
Linux server builds remain downstream issue #15 work.

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
3. Run the normal source-engine dependency and project-file setup.
4. Install the pinned Linux cross-toolchain before downstream Linux server
   work.
5. Initialize Git LFS for this repository before editing Unreal assets.

Engine and repository locations differ between contributors. Keep those paths
in the current shell or another local, untracked configuration. Never commit
machine-specific paths, endpoints, credentials, access tokens, or other
secrets.

## Verify the source revision

Set explicit local roots from a PowerShell session at the repository root:

```powershell
$AethelnEngineRoot = 'D:\UnrealEngine\UE-5.8.1-source'
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

## Repository hygiene and delivery boundary

Keep `Binaries/`, `DerivedDataCache/`, `Intermediate/`, `Saved/`, generated
solutions and IDE output, and logs untracked.

Issue #13 owns project generation, the Development Editor build/open workflow,
the starter map and default-game-mode configuration, and initial-launch
evidence. Issue #15 owns clean Win64 client builds, clean Linux dedicated-server
builds, cooking, packaging, and their evidence. An issue #13 Editor launch does
not prove issue #15 has passed.
