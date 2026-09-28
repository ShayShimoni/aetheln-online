"""Synthetic Linux-only tests for bounded crash-context acquisition."""

import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[2] / "scripts/build/controlled_crash_acquire.py"
SPEC = importlib.util.spec_from_file_location("controlled_crash_acquire", SOURCE)
assert SPEC is not None and SPEC.loader is not None
acquire = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(acquire)


class ImportSafetyTests(unittest.TestCase):
    def test_windows_discovery_does_not_need_linux_open_flags(self):
        names = ("O_DIRECTORY", "O_NOFOLLOW", "O_CLOEXEC", "O_NONBLOCK")
        saved = {name: getattr(os, name) for name in names if hasattr(os, name)}
        try:
            for name in saved:
                delattr(os, name)
            with patch.object(sys, "platform", "win32"):
                windows_module = importlib.util.module_from_spec(SPEC)
                SPEC.loader.exec_module(windows_module)
                with self.assertRaises(windows_module.CrashContextAcquisitionError):
                    windows_module.acquire_crash_context_xml("C:/scratch", "CrashReport-one")
        finally:
            for name, value in saved.items():
                setattr(os, name, value)


@unittest.skipUnless(sys.platform == "linux", "Linux dirfd behavior required")
class CrashContextAcquisitionTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name) / "fresh"
        self.root.mkdir()
        self.report = self.root / "CrashReport-one"
        self.report.mkdir()
        self.xml = self.report / "CrashContext.runtime-xml"
        self.xml.write_bytes(b"<FGenericCrashContext/>")

    def read(self, report="CrashReport-one"):
        return acquire.acquire_crash_context_xml(self.root, report)

    def rejects(self, report="CrashReport-one"):
        with self.assertRaises(acquire.CrashContextAcquisitionError):
            self.read(report)

    def test_only_xml_is_read_and_returned(self):
        (self.report / "minidump.dmp").write_bytes(b"never-read")
        (self.report / "Diagnostics.txt").write_bytes(b"never-read")
        (self.report / "server.log").write_bytes(b"never-read")
        actual_open = os.open
        opened = []

        def recording_open(path, flags, **kwargs):
            opened.append(os.fspath(path))
            return actual_open(path, flags, **kwargs)

        with patch.object(acquire.os, "open", side_effect=recording_open):
            self.assertEqual(self.read(), b"<FGenericCrashContext/>")
        self.assertEqual(opened, [str(self.root), "CrashReport-one", "CrashContext.runtime-xml"])

    def test_exact_size_ceiling(self):
        self.xml.write_bytes(b"x" * 1048576)
        self.assertEqual(len(self.read()), 1048576)
        self.xml.write_bytes(b"x" * 1048577)
        self.rejects()
        self.xml.write_bytes(b"")
        self.rejects()

    def test_report_name_must_be_one_safe_component(self):
        for name in ("", ".", "..", "../outside", "x/y", "x\\y", "x\x00y", "/tmp/report"):
            with self.subTest(name=name):
                self.rejects(name)
        with self.assertRaises(acquire.CrashContextAcquisitionError):
            acquire.acquire_crash_context_xml("relative-root", "CrashReport-one")

    def test_ambiguous_or_missing_report_rejected(self):
        self.rejects("CrashReport-other")
        (self.root / "CrashReport-two").mkdir()
        self.rejects()

    def test_root_report_and_xml_symlinks_rejected(self):
        alias = Path(self.scratch.name) / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(acquire.CrashContextAcquisitionError):
            acquire.acquire_crash_context_xml(alias, "CrashReport-one")
        old_report = Path(self.scratch.name) / "old-report"
        self.report.rename(old_report)
        self.report.symlink_to(old_report, target_is_directory=True)
        self.rejects()
        self.report.unlink()
        old_report.rename(self.report)
        self.xml.unlink()
        self.xml.symlink_to(self.report / "Diagnostics.txt")
        self.rejects()

    def test_nonregular_xml_rejected_without_blocking(self):
        self.xml.unlink()
        os.mkfifo(self.xml)
        self.rejects()
        self.xml.unlink()
        self.xml.mkdir()
        self.rejects()

    def test_hardlinked_xml_rejected(self):
        os.link(self.xml, self.report / "alias.xml")
        self.rejects()

    def test_xml_replacement_before_open_rejected(self):
        original_open = os.open
        replaced = False

        def replacing_open(path, flags, **kwargs):
            nonlocal replaced
            if path == "CrashContext.runtime-xml" and not replaced:
                replaced = True
                self.xml.rename(self.report / "old.xml")
                self.xml.write_bytes(b"<replacement/>")
            return original_open(path, flags, **kwargs)

        with patch.object(acquire.os, "open", side_effect=replacing_open):
            self.rejects()

    def test_in_place_mutation_during_read_rejected(self):
        original_read = os.read
        mutated = False

        def changing_read(fd, length):
            nonlocal mutated
            content = original_read(fd, length)
            if not mutated:
                mutated = True
                self.xml.write_bytes(b"<changed/>")
            return content

        with patch.object(acquire.os, "read", side_effect=changing_read):
            self.rejects()

    def test_xml_replacement_during_read_rejected(self):
        original_read = os.read
        replaced = False

        def replacing_read(fd, length):
            nonlocal replaced
            content = original_read(fd, length)
            if not replaced:
                replaced = True
                self.xml.rename(self.report / "old.xml")
                self.xml.write_bytes(b"<replacement/>")
            return content

        with patch.object(acquire.os, "read", side_effect=replacing_read):
            self.rejects()

    def test_report_replacement_during_read_rejected(self):
        original_read = os.read
        replaced = False

        def replacing_read(fd, length):
            nonlocal replaced
            content = original_read(fd, length)
            if not replaced:
                replaced = True
                self.report.rename(self.root / "old-report")
                self.report.mkdir()
                (self.report / "CrashContext.runtime-xml").write_bytes(b"<replacement/>")
            return content

        with patch.object(acquire.os, "read", side_effect=replacing_read):
            self.rejects()

    def test_root_replacement_during_read_rejected(self):
        original_read = os.read
        replaced = False

        def replacing_read(fd, length):
            nonlocal replaced
            content = original_read(fd, length)
            if not replaced:
                replaced = True
                self.root.rename(Path(self.scratch.name) / "old-root")
                self.root.mkdir()
                replacement = self.root / "CrashReport-one"
                replacement.mkdir()
                (replacement / "CrashContext.runtime-xml").write_bytes(b"<replacement/>")
            return content

        with patch.object(acquire.os, "read", side_effect=replacing_read):
            self.rejects()


if __name__ == "__main__":
    unittest.main()
