"""Non-launching, synthetic preflight seams for a future controlled capture.

These functions do not authorize a crash or establish package provenance. In
particular, a caller must independently bind the *bytes* of the executable to
the inventory, authenticate the direct Linux child and its events, prove a
fresh exclusive local report root, and establish local-only isolation before
any signal. No function here reads a log, crash artifact, or process command
line, launches a server, or sends a signal.
"""

import re
from typing import NamedTuple


_REVISION = re.compile(r"[0-9a-f]{40}\Z")
_SHA256 = re.compile(r"[0-9a-f]{64}\Z")
_CRASH_RUN = re.compile(r"[0-9a-f]{32}\Z")


class ControlledCrashCaptureError(RuntimeError):
    """A synthetic capture precondition could not be established."""


class PackageClaim(NamedTuple):
    source_revision: str
    engine_revision: str
    executable_relative_path: str
    executable_size: int
    executable_sha256: str


class ProcessIdentity(NamedTuple):
    pid: int
    start_ticks: int
    executable_device: int
    executable_inode: int


class ObservedEvent(NamedTuple):
    process: ProcessIdentity
    kind: str
    value: str


def _require(condition):
    if not condition:
        raise ControlledCrashCaptureError("Controlled crash preflight rejected.")


def _mapping_at(document, *keys):
    result = document
    for key in keys:
        _require(type(result) is dict and key in result)
        result = result[key]
    return result


def _safe_relative_path(value):
    return (
        type(value) is str
        and 0 < len(value) <= 512
        and all(part and part not in (".", "..") for part in value.split("/"))
        and all(char.isascii() and (char.isalnum() or char in "._-/") for char in value)
    )


def validate_package_claim(
    provenance,
    *,
    expected_source_revision,
    expected_engine_revision,
    executable_relative_path,
    observed_executable_size,
    observed_executable_sha256,
):
    """Check schema-v2 metadata equality, never assert that bytes are trusted.

    The observed size/digest must come from an independent trusted-byte proof;
    passing self-declared metadata here cannot authorize launch or triggering.
    Windows archive paths in provenance are intentionally *not* interpreted as
    Linux paths by this seam.
    """
    _require(type(expected_source_revision) is str and _REVISION.fullmatch(expected_source_revision))
    _require(type(expected_engine_revision) is str and _REVISION.fullmatch(expected_engine_revision))
    _require(_safe_relative_path(executable_relative_path))
    _require(type(observed_executable_size) is int and observed_executable_size > 0)
    _require(type(observed_executable_sha256) is str and _SHA256.fullmatch(observed_executable_sha256))
    _require(type(provenance) is dict and type(provenance.get("schemaVersion")) is int)
    _require(provenance["schemaVersion"] == 2)
    _require(_mapping_at(provenance, "source", "revision") == expected_source_revision)
    _require(_mapping_at(provenance, "source", "clean") is True)
    _require(_mapping_at(provenance, "build", "configuration") == "Development")
    _require(_mapping_at(provenance, "build", "serverPlatform") == "Linux")
    _require(_mapping_at(provenance, "build", "serverTarget") == "AethelnOnlineServer")
    _require(_mapping_at(provenance, "tools", "unreal", "repositoryRevision") == expected_engine_revision)
    inventory = _mapping_at(provenance, "artifacts", "inventory")
    _require(type(inventory) is list and 0 < len(inventory) <= 100000)
    matches = []
    for entry in inventory:
        _require(type(entry) is dict)
        if entry.get("path") == executable_relative_path:
            matches.append(entry)
    _require(len(matches) == 1)
    entry = matches[0]
    _require(entry.get("kind") == "server")
    _require(type(entry.get("sizeBytes")) is int and entry["sizeBytes"] == observed_executable_size)
    _require(type(entry.get("sha256")) is str and entry["sha256"] == observed_executable_sha256)
    return PackageClaim(
        expected_source_revision,
        expected_engine_revision,
        executable_relative_path,
        observed_executable_size,
        observed_executable_sha256,
    )


def _valid_process_identity(identity):
    return (
        type(identity) is ProcessIdentity
        and all(type(field) is int and field > 0 for field in identity)
    )


def parse_proc_start_ticks(stat_line, expected_pid):
    """Parse only the starttime identity from Linux /proc/<pid>/stat.

    The comm field may contain spaces or parentheses. Its text is neither
    returned nor logged. This parser alone does not prove ownership of a PID.
    """
    _require(type(expected_pid) is int and 0 < expected_pid <= 2147483647)
    _require(type(stat_line) is str and 0 < len(stat_line) <= 65536)
    prefix = f"{expected_pid} ("
    _require(stat_line.startswith(prefix))
    end = stat_line.rfind(") ")
    _require(end > len(prefix))
    fields = stat_line[end + 2 :].split()
    _require(len(fields) >= 20 and len(fields[0]) == 1)
    ticks = fields[19]
    _require(ticks.isascii() and ticks.isdecimal() and len(ticks) <= 20)
    result = int(ticks)
    _require(result > 0)
    return result


def require_same_process(initial, current):
    """Reject a reused PID, restarted child, or changed executable inode."""
    _require(_valid_process_identity(initial) and _valid_process_identity(current))
    _require(initial == current)
    return current


def require_ready_marker(events, expected_process):
    """Require one authenticated marker and readiness before any trigger.

    Events must already be *restricted, allowlisted* observations from one
    independently authenticated process stream. A caller-supplied process
    field or shared stdout pipe does not authenticate their origin, especially
    if descendants can inherit that pipe. This function never opens or copies
    unrestricted server output.
    The marker can precede readiness because registration can occur on the
    first world tick. Any context rotation or ambiguous second marker is
    rejected rather than silently selecting a possibly stale run.
    """
    _require(_valid_process_identity(expected_process))
    _require(type(events) in (list, tuple) and 0 < len(events) <= 64)
    ready = False
    marker = None
    for event in events:
        _require(type(event) is ObservedEvent and event.process == expected_process)
        if event.kind == "ready":
            _require(not ready and event.value == "")
            ready = True
        elif event.kind == "marker":
            _require(marker is None and type(event.value) is str)
            _require(_CRASH_RUN.fullmatch(event.value))
            marker = event.value
        else:
            _require(False)
    _require(ready and marker is not None)
    return marker
