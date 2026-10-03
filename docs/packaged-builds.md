# Packaged Windows Client and Linux Server Builds

This guide defines the repeatable Issue #15 path for producing a Windows x64
client and Linux x86-64 dedicated server from the pinned Unreal Engine source
checkout. It complements [Unreal Project Setup and First Launch](unreal-project-setup.md),
which remains the source for the contributor prerequisites and Editor path.
Launcher engine binaries and Editor-only success do not satisfy this workflow.

## Supported build identity

| Component | Supported value |
| --- | --- |
| Unreal Engine source | Epic tag `5.8.1-release`, commit `71fe36aac5a8df5ccd66c763ffc902b29b6a9c43` |
| Project | `AethelnOnline` |
| Client target | `AethelnOnlineClient`, Win64, Development |
| Dedicated-server target | `AethelnOnlineServer`, Linux x86-64, Development |
| Visual Studio | Visual Studio 2022 17.14 |
| Windows compiler | MSVC `14.44.35207` toolset family |
| Windows SDK | `10.0.26100.0` |
| Linux cross-toolchain | `v26_clang-20.1.8-rockylinux8` |
| Project plugins | `GameplayAbilities`, `EnhancedInput`, and `CommonUI`; the server target denies `EnhancedInput` and `CommonUI` |
| Startup map | `/Game/Maps/StarterMap` |

The repository revision, exact resolved compiler and SDK versions, plugin
state, target/configuration, build command, and artifact identity must also be
captured for each run. Do not replace an unknown or unavailable value with an
estimate; record it as `TBD` or mark the run unsupported until it can be
resolved.

The vendor-neutral runtime attachment and redaction rules are defined in
[Structured Observability and Crash Diagnostics](observability-and-crash-diagnostics.md).
Packaged runs must pass their exact validated source, build, toolchain, and
network-profile identities into that attachment; an absent value remains
explicitly unknown and must not be inferred.

## Build entry points

Run the repository scripts from PowerShell at the repository root. Their
comment-based help is authoritative for the parameter set:

```powershell
Get-Help .\scripts\build\Build-PackagedArtifacts.ps1 -Full
Get-Help .\scripts\build\Write-BuildProvenance.ps1 -Full
Get-Help .\scripts\build\Invoke-PackagedSmokeTest.ps1 -Full
```

The scripts have separate responsibilities:

- `Build-PackagedArtifacts.ps1` validates target composition and performs the
  clean BuildCookRun paths for the supported Windows client and Linux server.
- `Write-BuildProvenance.ps1` records the inputs, revisions, resolved tools,
  configurations, commands, and produced artifacts needed to identify a run.
- `Invoke-PackagedSmokeTest.ps1` launches the packaged products, captures
  stdout and Unreal logs, checks the expected startup behavior, and returns a
  failing exit code when the smoke does not pass.

`Build-PackagedArtifacts.ps1` accepts the project descriptor as `ProjectPath`,
the cross-toolchain as `LinuxToolchainRoot`, and separate clean `ArchiveRoot`
and `LogRoot` directories. Both output directories must be absent or empty so
evidence from separate runs cannot be mixed. They should remain outside
tracked source paths. Never commit machine-specific engine paths, build
artifacts, logs, or credentials.

Every build requires an explicit host-tools choice. The following Development
build invocation selects `Prebuilt`, which requires the canonical engine
revision and an existing external host-tools attestation record. That record
must have been produced with `-Stage AttestHostTools` after an authorized,
successful provisioning build, referencing its retained evidence; see
[Host-tools attestation record](developer-environment-and-ddc.md#host-tools-attestation-record).
If the pinned checkout lacks host products, the optional operator-only
[non-clean host-tool provisioner](developer-environment-and-ddc.md#explicit-non-clean-host-tool-provisioning)
can produce bounded local build evidence without running UAT or changing this
clean packaging contract. Provisioning does not create the attestation or
replace the separate attestation review step.
Substitute the local roots, enter that existing record's path when prompted,
and capture the actual full repository `HEAD` for the run:

```powershell
$AethelnRevision = git rev-parse HEAD
$AethelnHostToolsAttestationPath = Read-Host 'Existing host-tools attestation file path'
.\scripts\build\Build-PackagedArtifacts.ps1 `
  -ProjectPath .\AethelnOnline.uproject `
  -EngineRoot 'D:\UnrealEngine\UE-5.8.1-source-issue81-clean' `
  -LinuxToolchainRoot 'C:\UnrealToolchains\v26_clang-20.1.8-rockylinux8' `
  -ArchiveRoot 'D:\Builds\aetheln-run-001' `
  -LogRoot 'D:\BuildLogs\aetheln-run-001' `
  -SourceRevision $AethelnRevision `
  -HostToolsBoundary Prebuilt `
  -EngineRevision '71fe36aac5a8df5ccd66c763ffc902b29b6a9c43' `
  -HostToolsAttestationPath $AethelnHostToolsAttestationPath `
  -Configuration Development `
  -Map /Game/Maps/StarterMap
```

For a separately operator-authorized full host-tools rebuild, replace the
three host-tools arguments with `-HostToolsBoundary Rebuild`. There is no
default or automatic rebuild fallback: an omitted selection or an unverified
prebuilt attestation stops the build.

The script produces `WindowsClient` and `LinuxServer` below `ArchiveRoot` and
writes `build-provenance.json` beside them. Provenance generation is part of
the build entry point; `Write-BuildProvenance.ps1` remains independently
callable for validation and focused testing but is not an extra normal build
step.

Release builds add one optional input, `-BuildNumber`, accepted only by
`-Stage Provenance` and by `Write-BuildProvenance.ps1`. It must be a positive
integer of at most ten digits without a leading zero. An invalid value fails as
`build_number_invalid`, and passing it to any other stage fails as
`build_number_stage_invalid`. The writer then reads the committed
`ProjectVersion` from `Config/DefaultGame.ini` of the verified clean `HEAD` and
appends one closed `release` block after the existing properties:

```json
"release": {
  "schemaVersion": 1,
  "projectVersion": "1.0.0-alpha.1",
  "buildNumber": 7,
  "buildVersion": "1.0.0-alpha.1+7"
}
```

The read is case-sensitive and strict: exactly one `ProjectVersion=` line in
`[/Script/EngineSettings.GeneralProjectSettings]`, holding SemVer without build
metadata. Section headers are matched after trailing whitespace is trimmed, as
the engine does. A file with a line continuation (a trailing `\`) or a `{...}`
block fails closed, because the engine joins those lines. A missing value fails
closed as `project_version_missing`, and any other malformed or ambiguous value
as `project_version_invalid`. The reader is a line-oriented approximation of
the engine's ini parser; the release smoke evidence checks the network version
that both packages actually log. The committed
`ProjectVersion` never carries `+<build>`; the build number lives only in the
provenance. Without `-BuildNumber` the document has no `release` block,
`ProjectVersion` is not read, and the output is unchanged. `host.buildIdentity`
keeps its `AethelnOnline@<revision>/<configuration>` format in both cases
because the network authority spike compares it byte for byte.

For Linux cooking, the proven UAT invocation requires this exact cooker
override:

```text
-AdditionalCookerOptions=-ini:Input:[/Script/CommonUI.CommonUIInputSettings]:DefaultVirtualPointerClass=None
```

The build wrapper also supplies server-only `-NeverCookDir` exclusions for the
CommonUI, EnhancedInput, and Interchange plugin content roots. Those plugins are
not server runtime dependencies; excluding their content prevents standalone
client/editor presentation assets from entering the Linux server archive. The
cook-reference gate independently fails if any such package is still present.

The override prevents the Linux dedicated-server cook from resolving
CommonUI's client-only default virtual pointer class. Keep it on the Linux UAT
cook/package path even though the dedicated-server target excludes the client
presentation plugins. Removing it requires new clean-cook evidence.

After the Linux cook, the build runs two fail-closed `DumpAssetRegistry` gates:

- The dependency gate dumps
  `Saved/Cooked/LinuxServer/AethelnOnline/Metadata/DevelopmentAssetRegistry.bin`
  with object path, package name, class, dependency details, and package data.
  `Validate-ServerCookReferences.ps1` rejects client-only CommonUI,
  EnhancedInput, Slate, UMG, and related script or content dependencies.
- The cooked-inventory gate separately dumps
  `Saved/Cooked/LinuxServer/AethelnOnline/AssetRegistry.bin` with package names.
  It rejects forbidden client-only packages from the exact runtime cooked
  inventory, including packages that have no dependency edge in the
  development registry.

The reports and command logs are stored under `LogRoot` as
`server-dependency-registry-dump`, `server-cooked-inventory-dump`, and their
corresponding `.log` files. Missing or malformed reports fail the build.

## Clean build and package procedure

1. Verify the source-engine tag and commit as described in
   [Unreal Project Setup and First Launch](unreal-project-setup.md#verify-the-source-revision).
2. Confirm the pinned Visual Studio workload, MSVC toolset, Windows SDK, and
   Linux cross-toolchain are installed and discoverable.
3. Choose new, empty output and log directories for the run. A clean rebuild
   must not reuse staged, cooked, or packaged output from an earlier run.
4. Run `Build-PackagedArtifacts.ps1` for both supported artifacts using the
   exact syntax reported by `Get-Help`. Preserve its complete command output
   and exit code.
5. Confirm `build-provenance.json` was written for the run. The record must connect the
   repository and engine revisions to the exact client and server artifacts.
6. Run `Invoke-PackagedSmokeTest.ps1` using the packaged outputs and a distinct
   smoke-log directory. Preserve the command, exit code, stdout, and Unreal log
   paths.

A repeatable result means a second run from clean output roots produces both
supported artifacts and passes the same smoke procedure. A successful
incremental rebuild is useful feedback but is not clean-rebuild evidence.

## Manual launch and troubleshooting

The smoke orchestrator runs on Windows, launches the packaged Linux server via
WSL, and then launches two distinct packaged Windows client processes. The
server executable must be expressed as a WSL path; the client and evidence
roots use Windows paths. Unreal's UDP connection must use the WSL guest address,
not `127.0.0.1`. Resolve the first address immediately before the smoke:

```powershell
$AethelnWslIp = ((wsl.exe -d Ubuntu -u aethelnqa -- hostname -I).Trim() -split '\s+')[0]
$AethelnServerEndpoint = "${AethelnWslIp}:7777"
```

The final passing invocation used redirected stdout and the following packaged
log signatures:

```powershell
.\scripts\build\Invoke-PackagedSmokeTest.ps1 `
  -ServerExecutable '/mnt/d/Builds/aetheln-run-001/LinuxServer/Linux/AethelnOnlineServer.sh' `
  -ServerLauncherExecutable 'wsl.exe' `
  -ServerLauncherArguments @('-d', 'Ubuntu', '-u', 'aethelnqa', '--exec', '{ServerExecutable}', '{ServerMap}', '-port=7777', '-stdout', '-FullStdOutLogOutput') `
  -ClientExecutable 'D:\Builds\aetheln-run-001\WindowsClient\Windows\AethelnOnlineClient.exe' `
  -ClientBaseArguments @('{ServerEndpoint}', '-stdout', '-FullStdOutLogOutput') `
  -ServerEndpoint $AethelnServerEndpoint `
  -ServerMap '/Game/Maps/StarterMap' `
  -LogRoot 'D:\SmokeLogs\aetheln-run-001' `
  -ServerReadyPattern 'GameNetDriver.*Listening' `
  -ServerClientConnectedPattern 'AddClientConnection:.*RemoteAddr: (?<ConnectionId>[^,]+)' `
  -ClientConnectedPattern 'Welcomed by server' `
  -ClientMapPattern 'LoadMap:.*StarterMap' `
  -TimeoutSeconds 120
```

Confirm the archive's actual executable paths before running; UAT may include
additional platform or project directories under each archive. The launcher
arguments must retain `{ServerExecutable}` and `{ServerMap}`; they may also use
`{ServerEndpoint}`. Client arguments must retain `{ServerEndpoint}`. Optional
`ServerLogPath` and `ClientLogPath` values must be native to the process that
writes them; a Windows `LogRoot` is never passed into WSL implicitly. The
server-connection regex must capture a named `ConnectionId`, and the smoke
requires two distinct captured transport identities. On success the script
writes correlated JSONL records to `smoke-evidence.jsonl`; on failure it
reports the relevant process and redirected stdout/stderr evidence.

When reproducing a failure manually, launch the packaged server first with its
console/stdout and log output enabled, then launch the packaged Windows client
against the explicit local server address. Preserve the full commands used;
do not rely on shell history as evidence.

For every failure, inspect the per-target UAT log, Unreal process log, and the
top-level script transcript. Report the first causal error with its file path
and line or timestamp where available, rather than only the final AutomationTool
exit summary. Useful evidence includes:

- script name, arguments, exit code, start/end time, and host platform;
- target, platform, configuration, engine and repository revision;
- UAT/build/cook/stage/package logs and the produced artifact path;
- isolated `client-automationtool` and `server-automationtool` directories;
  exact MSVC and Windows resource-compiler provenance is read from the client
  invocation's `UBA-*.txt` sidecars rather than inferred from shared or stale
  AutomationTool logs;
- server and client stdout plus Unreal log paths for the smoke run;
- whether the failure reproduces from a new clean output root.

Logs and provenance must be actionable and redacted. They must not contain
credentials, tokens, private keys, local secret configuration, or unrelated
environment-variable dumps.

## Smoke evidence and limitations

Current local evidence verifies the clean Linux dedicated-server package and
cook, including both asset-registry gates, and the packaged Windows client
package and launch. The final WSL smoke also passed on
`/Game/Maps/StarterMap`: the Linux server listened, two packaged Windows client
processes connected through the WSL guest IP, the server reported two distinct
connection identities, and both clients reported the welcome and map-load
events. The correlated result is recorded in `smoke-evidence.jsonl` alongside
the redirected process logs.

This evidence proves the Issue #15 packaging and startup path. Record the exact
observed behavior rather than claiming gameplay that the current prototype
does not yet implement.

This foundation does not by itself prove multiplayer authority, combat,
replication performance, capacity, harsh-network behavior, CI portability, or
production deployment. Those conclusions remain downstream:

- Issue #2 consumes equivalent packaged artifacts for networking and
  replication evidence.
- Issue #44 owns packaged multi-process multiplayer automation.
- Issue #45 owns measured client, server, bandwidth, build/cook, and artifact
  performance baselines.

Any unavailable runner, host, toolchain, launch path, or unimplemented gameplay
step must be listed as a limitation with an owner and follow-up issue. Do not
convert an untested assumption into a supported configuration.
