"""Synthetic, non-launching preflight tests for controlled crash capture."""

import importlib.util
from pathlib import Path
import unittest


SOURCE = Path(__file__).resolve().parents[2] / "scripts/build/controlled_crash_capture.py"
SPEC = importlib.util.spec_from_file_location("controlled_crash_capture", SOURCE)
assert SPEC is not None and SPEC.loader is not None
capture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(capture)

SOURCE_REVISION = "a" * 40
ENGINE_REVISION = "b" * 40
EXECUTABLE_SHA256 = "c" * 64
EXECUTABLE = "Linux/AethelnOnlineServer/Binaries/Linux/AethelnOnlineServer"
CRASH_RUN = "d" * 32


def provenance():
    return {
        "schemaVersion": 2,
        "source": {"revision": SOURCE_REVISION, "clean": True},
        "build": {
            "configuration": "Development",
            "serverPlatform": "Linux",
            "serverTarget": "AethelnOnlineServer",
        },
        "tools": {"unreal": {"repositoryRevision": ENGINE_REVISION}},
        "artifacts": {
            "inventory": [
                {"kind": "server", "path": EXECUTABLE, "sizeBytes": 100, "sha256": EXECUTABLE_SHA256},
                {"kind": "server", "path": "Linux/Engine/config.txt", "sizeBytes": 7, "sha256": "e" * 64},
            ]
        },
    }


class PackageClaimTests(unittest.TestCase):
    def validate(self, document=None, **overrides):
        arguments = dict(
            expected_source_revision=SOURCE_REVISION,
            expected_engine_revision=ENGINE_REVISION,
            executable_relative_path=EXECUTABLE,
            observed_executable_size=100,
            observed_executable_sha256=EXECUTABLE_SHA256,
        )
        arguments.update(overrides)
        return capture.validate_package_claim(provenance() if document is None else document, **arguments)

    def rejects(self, document=None, **overrides):
        with self.assertRaises(capture.ControlledCrashCaptureError):
            self.validate(document, **overrides)

    def test_exact_claim_passes_without_granting_launch_or_trigger(self):
        claim = self.validate()
        self.assertEqual(claim.source_revision, SOURCE_REVISION)
        self.assertEqual(claim.engine_revision, ENGINE_REVISION)
        self.assertEqual(claim.executable_relative_path, EXECUTABLE)
        self.assertFalse(hasattr(claim, "trigger_authorized"))

    def test_rejects_wrong_source_engine_configuration_and_target(self):
        for path, value in (
            (("source", "revision"), "f" * 40),
            (("source", "clean"), False),
            (("build", "configuration"), "Shipping"),
            (("build", "serverPlatform"), "Win64"),
            (("build", "serverTarget"), "AethelnOnlineClient"),
            (("tools", "unreal", "repositoryRevision"), None),
        ):
            with self.subTest(path=path):
                document = provenance()
                cursor = document
                for part in path[:-1]:
                    cursor = cursor[part]
                cursor[path[-1]] = value
                self.rejects(document)
        self.rejects(expected_source_revision="not-a-revision")
        self.rejects(expected_engine_revision="B" * 40)

    def test_inventory_requires_unique_exact_path_size_and_digest(self):
        self.rejects(observed_executable_size=101)
        self.rejects(observed_executable_sha256="e" * 64)
        self.rejects(executable_relative_path="/" + EXECUTABLE)
        self.rejects(executable_relative_path="Linux/../" + EXECUTABLE)
        document = provenance()
        document["artifacts"]["inventory"].append(document["artifacts"]["inventory"][0].copy())
        self.rejects(document)
        document = provenance()
        document["artifacts"]["inventory"][0]["path"] = "Linux/./AethelnOnlineServer"
        self.rejects(document)
        document = provenance()
        document["artifacts"]["inventory"][0]["sha256"] = "C" * 64
        self.rejects(document)
        document = provenance()
        document["artifacts"]["inventory"][0]["kind"] = "client"
        self.rejects(document)


class ProcessIdentityTests(unittest.TestCase):
    @staticmethod
    def stat_line(pid=137, start_ticks=123456, name="server (child)"):
        # Linux /proc/<pid>/stat fields 3..21 precede starttime (field 22).
        fields = ["S"] + ["0"] * 18 + [str(start_ticks)] + ["0"] * 3
        return f"{pid} ({name}) " + " ".join(fields)

    def test_process_stat_parser_handles_parentheses_without_command_text_output(self):
        self.assertEqual(capture.parse_proc_start_ticks(self.stat_line(), 137), 123456)

    def test_rejects_pid_reuse_malformed_and_missing_start_identity(self):
        for text in (self.stat_line(pid=138), "137 (server) S", self.stat_line(start_ticks=0), "137 server S"):
            with self.subTest(text=text):
                with self.assertRaises(capture.ControlledCrashCaptureError):
                    capture.parse_proc_start_ticks(text, 137)
        before = capture.ProcessIdentity(137, 123456, 8, 9)
        self.assertEqual(capture.require_same_process(before, capture.ProcessIdentity(137, 123456, 8, 9)), before)
        for after in (
            capture.ProcessIdentity(138, 123456, 8, 9),
            capture.ProcessIdentity(137, 123457, 8, 9),
            capture.ProcessIdentity(137, 123456, 8, 10),
        ):
            with self.assertRaises(capture.ControlledCrashCaptureError):
                capture.require_same_process(before, after)


class MarkerSequenceTests(unittest.TestCase):
    def setUp(self):
        self.identity = capture.ProcessIdentity(137, 123456, 8, 9)

    def event(self, kind, value=""):
        return capture.ObservedEvent(self.identity, kind, value)

    def test_one_marker_before_or_after_readiness_binds_only_its_id(self):
        for events in (
            [self.event("ready"), self.event("marker", CRASH_RUN)],
            [self.event("marker", CRASH_RUN), self.event("ready")],
        ):
            with self.subTest(events=events):
                self.assertEqual(capture.require_ready_marker(events, self.identity), CRASH_RUN)

    def test_missing_duplicate_foreign_and_bad_marker_reject(self):
        foreign = capture.ProcessIdentity(138, 123456, 8, 9)
        sequences = (
            [],
            [self.event("ready")],
            [self.event("marker", CRASH_RUN)],
            [self.event("marker", CRASH_RUN), self.event("marker", CRASH_RUN), self.event("ready")],
            [self.event("ready"), self.event("marker", CRASH_RUN), self.event("marker", CRASH_RUN)],
            [self.event("marker", CRASH_RUN), self.event("ready"), self.event("marker", "e" * 32)],
            [self.event("ready"), capture.ObservedEvent(foreign, "marker", CRASH_RUN)],
            [self.event("ready"), self.event("marker", "D" * 32)],
            [self.event("ready"), self.event("marker", CRASH_RUN), self.event("unknown")],
        )
        for events in sequences:
            with self.subTest(events=events):
                with self.assertRaises(capture.ControlledCrashCaptureError):
                    capture.require_ready_marker(events, self.identity)


if __name__ == "__main__":
    unittest.main()
