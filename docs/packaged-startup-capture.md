# Packaged startup capture (Issue #45, bounded first measurement)

`Invoke-PackagedSmokeTest.ps1` keeps its existing two-client smoke behavior by
default. To record an additional local measurement, append these parameters to
an otherwise valid packaged-smoke invocation:

```powershell
-CaptureStartup `
-BuildProvenancePath '<run>/build-provenance.json' `
-ServerProvenanceExecutable '<host-visible Linux-server archive>/AethelnOnlineServer.sh'
```

For this capture, set `-ClientExecutable` to the provenance-listed inner game
binary `WindowsClient/AethelnOnline/Binaries/Win64/AethelnOnlineClient.exe`,
not the root `WindowsClient/AethelnOnlineClient.exe` bootstrap. Unreal's root
bootstrap can launch the inner process and wait, so measuring the root process
would report bootstrap CPU and memory rather than game-client CPU and memory.
Capture mode rejects the root or any unrecognized Win64 client layout before
launch. Direct inner-binary execution and its working-directory/content behavior
still require a bounded real package run; no such run is implied by the
synthetic tests here.

Use the same clean package and provenance record that the packaging/provenance
gate validated. The host-visible server path must be the actual packaged file
corresponding to the Linux path passed as `-ServerExecutable`; `wsl.exe` is not
that file. Capture mode supports the default WSL `/mnt/<drive>/...` mapping
only and checks it against that exact host path. The opt-in rejects absent,
duplicate, or mismatched executable
inventory identities before launching, hashes the exact provenance bytes it
parsed, and rechecks provenance and both
executable hashes after the smoke. Each run needs its own absent or empty
`-LogRoot`; neither the smoke evidence nor the capture is overwritten. The
temporary file is created relative to a held output-directory handle with
reparse traversal refused, then published by a create-only same-directory
rename from that file handle after a complete write. All held ancestors and
the temporary file are rechecked against their expected paths; failed
temporary evidence is discarded by handle. A moved or replaced output
ancestor fails closed instead of redirecting creation, publication, or cleanup
into another directory.

After both clients confirm the map while the server launcher and both client
processes are alive, the script snapshots the direct Windows client processes:
PID/start identity, cumulative CPU time, working set, peak working set, and
private bytes. It writes `startup-capture.json` only after successful process
cleanup. The record binds its source revision, configuration, executable
identities, provenance SHA-256, scenario/map, and final smoke-evidence SHA-256.
It also records the actual live Windows launcher path, PID, and hash. Because
the launcher is configurable, its stdout and the declared Linux path do not
attest the actual Linux process or process-to-host topology. Both remain
explicitly `unknown`, even when the configured launcher is `wsl.exe`.
The launch-to-map value is an **upper bound from host launch to stdout
observation**, not an Unreal-internal map-load timer; polling and waiting for
the other connection can increase it. Use it only for comparable runs with
the same observation method.

This is not the full Issue #45 budget baseline. `wsl.exe` is a launcher, so
Linux server simulation, replication, and memory metrics remain `unknown`.
Frame/render/GPU times, streaming, bandwidth, network impairment, actor mix,
and representative combat also remain `unknown`; no server, player-capacity,
or bandwidth budget follows from this capture. Hardware detail beyond the
recorded host basics, full topology, controlled network profile, and reviewed
thresholds must be attached to later representative captures before Issue #45
or Prototype Gate acceptance can be claimed.
