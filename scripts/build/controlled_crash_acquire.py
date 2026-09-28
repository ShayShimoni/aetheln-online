"""Acquire one Unreal crash-context XML without touching other artifacts.

The caller owns local-filesystem proof, creation, exclusivity, and freshness of
``trusted_root``, and must provide the single expected report-folder name.
This module does not
launch, signal, trigger, parse, log, or publish anything. Its returned bytes
still require the separate closed-schema crash-context validator.
"""

import os
from pathlib import Path
import stat
import sys


MAX_XML_BYTES = 1048576
XML_NAME = "CrashContext.runtime-xml"


class CrashContextAcquisitionError(RuntimeError):
    """The report cannot be acquired under this bounded file contract."""


def _identity_matches(left, right):
    return (left.st_dev, left.st_ino, left.st_mode) == (
        right.st_dev,
        right.st_ino,
        right.st_mode,
    )


def _unchanged(left, right):
    return _identity_matches(left, right) and (
        left.st_size,
        left.st_mtime_ns,
        left.st_ctime_ns,
        left.st_nlink,
    ) == (
        right.st_size,
        right.st_mtime_ns,
        right.st_ctime_ns,
        right.st_nlink,
    )


def _require(condition):
    if not condition:
        raise CrashContextAcquisitionError("Crash XML acquisition rejected.")


def _read_from_fds(root_path, report_name):
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    file_flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC
    root_fd = os.open(root_path, directory_flags)
    try:
        root_before = os.fstat(root_fd)
        _require(stat.S_ISDIR(root_before.st_mode))
        _require(_identity_matches(root_before, os.stat(root_path, follow_symlinks=False)))
        # A fresh, run-exclusive root has one report directory and no other
        # entries. Listing names never opens another report or its contents.
        _require(os.listdir(root_fd) == [report_name])
        report_before = os.stat(report_name, dir_fd=root_fd, follow_symlinks=False)
        _require(stat.S_ISDIR(report_before.st_mode))
        report_fd = os.open(report_name, directory_flags, dir_fd=root_fd)
        try:
            _require(_identity_matches(report_before, os.fstat(report_fd)))
            xml_before = os.stat(XML_NAME, dir_fd=report_fd, follow_symlinks=False)
            _require(stat.S_ISREG(xml_before.st_mode))
            _require(xml_before.st_nlink == 1)
            _require(0 < xml_before.st_size <= MAX_XML_BYTES)
            xml_fd = os.open(XML_NAME, file_flags, dir_fd=report_fd)
            try:
                _require(_identity_matches(xml_before, os.fstat(xml_fd)))
                chunks = []
                remaining = xml_before.st_size
                while remaining:
                    chunk = os.read(xml_fd, min(65536, remaining))
                    _require(bool(chunk))
                    chunks.append(chunk)
                    remaining -= len(chunk)
                _require(os.read(xml_fd, 1) == b"")
                xml_after = os.fstat(xml_fd)
                _require(_unchanged(xml_before, xml_after))
                _require(_unchanged(xml_before, os.stat(XML_NAME, dir_fd=report_fd, follow_symlinks=False)))
            finally:
                os.close(xml_fd)
            _require(_unchanged(report_before, os.fstat(report_fd)))
            _require(_unchanged(report_before, os.stat(report_name, dir_fd=root_fd, follow_symlinks=False)))
        finally:
            os.close(report_fd)
        _require(_unchanged(root_before, os.fstat(root_fd)))
        _require(_unchanged(root_before, os.stat(root_path, follow_symlinks=False)))
        _require(os.listdir(root_fd) == [report_name])
        return b"".join(chunks)
    finally:
        os.close(root_fd)


def acquire_crash_context_xml(trusted_root, report_folder):
    """Return at most 1 MiB of XML bytes from one Linux report folder.

    ``trusted_root`` must be an absolute, fresh, exclusive, caller-owned local
    directory with trusted ancestors. This function detects identity/mutation
    races but does not prove those caller preconditions or authenticate report
    contents.
    """
    try:
        _require(sys.platform == "linux")
        root_path = os.fspath(trusted_root)
        _require(isinstance(root_path, str) and os.path.isabs(root_path))
        _require(".." not in Path(root_path).parts)
        _require(isinstance(report_folder, str))
        _require(0 < len(report_folder) <= 128)
        _require(report_folder not in (".", ".."))
        _require(all(char.isascii() and (char.isalnum() or char in "._-") for char in report_folder))
        return _read_from_fds(root_path, report_folder)
    except (OSError, TypeError, ValueError):
        raise CrashContextAcquisitionError("Crash XML acquisition rejected.") from None
