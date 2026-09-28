# Controlled local crash capture: validation seam and remaining gate

This is an Issue #148 implementation note subordinate to
[Structured Observability and Crash Diagnostics](observability-and-crash-diagnostics.md),
[Security and Operations](security-and-operations.md), and
[Packaged Builds](packaged-builds.md). It does **not** authorize a live crash or
claim that local-only report generation has been established.

`scripts/build/Read-BoundedCrashContext.ps1` exposes the pure
`ConvertFrom-BoundedCrashContextXml` function. It accepts at most 1 MiB of
already acquired XML bytes plus independently supplied Linux process ID,
observed Aetheln marker ID, engine revision, and closed flow kind. It prohibits
DTD/entity expansion, rejects malformed, missing, duplicate, nested, stale, or
out-of-contract fields, and emits only the approved bounded identity subset.
It never opens a path, prints XML, reads a log, or touches a dump. The focused
synthetic fixture is `tests/build/Read-BoundedCrashContext.Tests.ps1`.

`scripts/build/controlled_crash_acquire.py` is a separate Linux-only,
in-process acquisition seam. Given a caller-verified fresh, exclusive root and
one expected report-folder name, it opens only `CrashContext.runtime-xml` with
anchored directory handles, rejects symlinks, nonregular or hard-linked XML,
ambiguous folders, oversized files, and detected identity or content changes,
then returns at most 1 MiB of bytes. Its focused synthetic tests are
`tests/build/test_controlled_crash_acquire.py`. The caller must still prove
local-filesystem residency, stable trusted ancestors, root ownership and
freshness.

`scripts/build/controlled_crash_capture.py` supplies only non-launching
preflight checks for schema-v2 package metadata, independently observed
executable size and digest, Linux PID/start/executable identity, and an
unambiguous marker plus readiness. A supplied event identity or shared stdout
pipe does not by itself authenticate the marker's writer. The companion
`scripts/build/controlled_crash_xml.py` is a pure validator for already
acquired XML, intended to run inside that restricted Python process against
the closed allowlist; it does not acquire a file or prove that the XML came
from the owned child. Their synthetic fixtures
are in `tests/build/test_controlled_crash_capture.py` and
`tests/build/test_controlled_crash_xml.py`. No component here launches or
signals a server, establishes no-egress or CrashReportClient suppression, or
publishes a capture. Do not pass raw XML from the restricted process to the
separate PowerShell validator. There is still no live capture runner or
controlled-crash proof.

The XML `CrashGUID` is an engine-generated `UECC-...` identity. A launch
`-CrashGUID=` override names the separate crash-info folder. Neither is the
server-generated `AethelnCrashRunId`. Do not require these three identities to
match. `RuntimeProperties/ProcessId` must instead match the verified **Linux
server child**, not a Windows `wsl.exe` launcher PID; `GameData/AethelnCrashRunId`
must equal the last unambiguous marker observed before any trigger.

Before a capture runner can call the parser or trigger a failure, it must prove
all of the following on one exact packaged Linux Development server:

1. Clean source, pinned engine, package inventory, executable bytes, build
   provenance, and profile are independently bound to the launched child.
2. A fresh exclusive `Saved/Crashes` root and unique report folder are owned
   by that child. No symlink/reparse-point or ancestor substitution can redirect
   acquisition; XML is opened by an anchored, no-follow handle and size-bound
   before bytes reach the parser.
3. The direct Linux PID **and start identity** are recorded and rechecked
   immediately before a signal. The child must have reached readiness and
   emitted exactly one observed marker before the trigger; either event may
   occur first. No replacement, missing, or ambiguous marker is accepted.
4. The child is isolated from egress, CrashReportClient is absent, local-only
   report-generation suppression overrides are verified against pinned engine
   source, `RLIMIT_CORE=0` is effective in the child, and `core_pattern` is not
   a pipe. These are preconditions, not assumptions from config text alone.
5. An owner-approved signal/trigger targets only that verified child, with
   bounded startup, readiness, signal, report, and cleanup deadlines. Failure
   at any gate leaves the original restricted evidence intact and unpublished.

Do not reuse the packaged smoke launcher's expanded argument logging or treat
its WSL PID as server identity. Do not open, parse, hash, copy, or publish a
core, minidump, `Diagnostics`, command line, or unrestricted server log. The
parser's output is **not** proof of process/package provenance, no-egress, a
controlled failure, independent review, or post-merge QA. Those gates remain
open until a separate safe runner and an exact package exist.
