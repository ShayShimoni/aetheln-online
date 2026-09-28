"""Synthetic tests for the pure bounded Unreal crash-context XML validator."""

import importlib.util
from pathlib import Path
import unittest


SOURCE = Path(__file__).resolve().parents[2] / "scripts/build/controlled_crash_xml.py"
SPEC = importlib.util.spec_from_file_location("controlled_crash_xml", SOURCE)
assert SPEC is not None and SPEC.loader is not None
xml = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(xml)

RUN_ID = "a" * 32
ENGINE_REVISION = "5.8.1-123+++UE5+Release"
ENGINE_GUID = "UECC-Linux-" + "b" * 32 + "_0000"
FIXED = {
    "AethelnObservabilitySchema": "aetheln.observability-event",
    "AethelnServerLifecycle": "crashing",
    "AethelnCrashContextState": "active",
    "AethelnCrashContextSchemaVersion": "1",
    "AethelnSourceRevision": "unknown",
    "AethelnBuildIdentity": "unknown",
    "AethelnBuildConfiguration": "Development",
    "AethelnToolchainIdentity": "unknown",
    "AethelnNetworkProfileSchema": "aetheln.network-profile",
    "AethelnNetworkProfileVersion": "1",
    "AethelnNetworkProfileId": "network-profile.unset",
    "AethelnServerInstance": "game-server",
    "AethelnConnectionPseudonym": "excluded",
}


def fixture():
    fields = {
        **FIXED,
        "AethelnEngineRevision": ENGINE_REVISION,
        "AethelnFlowKind": "prototype-authority",
        "AethelnCrashRunId": RUN_ID,
    }
    game_data = "".join(f"<{key}>{value}</{key}>" for key, value in fields.items())
    return (
        "<FGenericCrashContext><RuntimeProperties>"
        f"<ProcessId>27182</ProcessId><CrashGUID>{ENGINE_GUID}</CrashGUID>"
        "</RuntimeProperties><GameData>"
        f"{game_data}<Other>unrestricted-secret-do-not-emit</Other>"
        "</GameData><Unrestricted>secret-do-not-emit</Unrestricted>"
        "</FGenericCrashContext>"
    )


def validate(content, **expected):
    inputs = {
        "expected_process_id": 27182,
        "expected_crash_run_id": RUN_ID,
        "expected_engine_revision": ENGINE_REVISION,
        "expected_flow_kind": "prototype-authority",
    }
    inputs.update(expected)
    return xml.validate_crash_context_xml(content, **inputs)


class CrashXmlTests(unittest.TestCase):
    def rejects(self, content, **expected):
        with self.assertRaises(xml.CrashContextXmlError) as captured:
            validate(content, **expected)
        self.assertEqual(str(captured.exception), "Crash XML validation rejected.")

    def test_exact_allowlisted_result(self):
        result = validate(fixture().encode("utf-8"))
        self.assertEqual(
            result,
            {
                "SchemaVersion": 1,
                "ProcessId": 27182,
                "EngineCrashGuid": ENGINE_GUID,
                "CrashRunId": RUN_ID,
                "BuildConfiguration": "Development",
                "EngineRevision": ENGINE_REVISION,
                "NetworkProfileId": "network-profile.unset",
                "FlowKind": "prototype-authority",
            },
        )
        self.assertNotIn("secret-do-not-emit", str(result))

    def test_identity_mismatch_and_trusted_input_validation(self):
        good = fixture().encode("utf-8")
        for key, value in (
            ("expected_process_id", 27183),
            ("expected_process_id", True),
            ("expected_process_id", 0),
            ("expected_crash_run_id", "c" * 32),
            ("expected_crash_run_id", "A" * 32),
            ("expected_crash_run_id", []),
            ("expected_engine_revision", "5.8.2-123+++UE5+Release"),
            ("expected_engine_revision", []),
            ("expected_flow_kind", "admission"),
            ("expected_flow_kind", "not-a-flow"),
            ("expected_flow_kind", []),
        ):
            with self.subTest(key=key, value=value):
                self.rejects(good, **{key: value})

    def test_missing_duplicate_nested_and_unsafe_fields(self):
        base = fixture()
        modifications = (
            base.replace("<ProcessId>27182</ProcessId>", ""),
            base.replace("</ProcessId>", "</ProcessId><ProcessId>27182</ProcessId>"),
            base.replace(f"<CrashGUID>{ENGINE_GUID}</CrashGUID>", ""),
            base.replace(f"<AethelnCrashRunId>{RUN_ID}</AethelnCrashRunId>", ""),
            base.replace("</AethelnCrashRunId>", f"</AethelnCrashRunId><AethelnCrashRunId>{RUN_ID}</AethelnCrashRunId>"),
            base.replace("<Other>unrestricted-secret-do-not-emit</Other>", "<Other>one</Other><Other>two</Other>"),
            base.replace("</GameData>", "<AethelnSecret>hidden</AethelnSecret></GameData>"),
            base.replace("</GameData>", "<aethelnSecret>hidden</aethelnSecret></GameData>"),
            base.replace("</GameData>", '<x:Other xmlns:x="urn:bad">value</x:Other></GameData>'),
            base.replace("<Other>unrestricted-secret-do-not-emit</Other>", "<Other><AethelnCrashRunId>value</AethelnCrashRunId></Other>"),
            base.replace(f"<AethelnCrashRunId>{RUN_ID}</AethelnCrashRunId>", f"<AethelnCrashRunId><Nested>{RUN_ID}</Nested></AethelnCrashRunId>"),
            base.replace("<GameData>", '<GameData bad="value">'),
            base.replace("<FGenericCrashContext>", '<FGenericCrashContext bad="value">'),
            base.replace("<AethelnCrashContextState>active</AethelnCrashContextState>", "<AethelnCrashContextState>stale</AethelnCrashContextState>"),
            base.replace("<AethelnConnectionPseudonym>excluded</AethelnConnectionPseudonym>", "<AethelnConnectionPseudonym>user@example.com</AethelnConnectionPseudonym>"),
            base.replace("UECC-Linux-", "UECC-SecretAccount-"),
        )
        for index, changed in enumerate(modifications):
            with self.subTest(case=index):
                self.rejects(changed.encode("utf-8"))

    def test_malformed_dtd_entity_and_bounds(self):
        base = fixture()
        for content in (
            b"",
            b"x" * 1048577,
            b"\x00" + base.encode("utf-8"),
            base[:-1].encode("utf-8"),
            base.replace(
                "<FGenericCrashContext>",
                '<!DOCTYPE FGenericCrashContext [<!ENTITY x "text">]><FGenericCrashContext>',
            ).encode("utf-8"),
            base.replace(
                "<FGenericCrashContext>",
                '<!DOCTYPE FGenericCrashContext SYSTEM "file:///unavailable"><FGenericCrashContext>',
            ).encode("utf-8"),
            base.replace(
                "<FGenericCrashContext>",
                '<!DOCTYPE FGenericCrashContext [<!ENTITY x "text">]><FGenericCrashContext>',
            ).encode("utf-16"),
            base.replace("<Other>unrestricted-secret-do-not-emit</Other>", "<Other>&undeclared;</Other>").encode("utf-8"),
            base.replace("<FGenericCrashContext>", "<OtherRoot>").replace("</FGenericCrashContext>", "</OtherRoot>").encode("utf-8"),
        ):
            with self.subTest(size=len(content)):
                self.rejects(content)
        self.rejects(base)

    def test_valid_xml_at_exact_byte_ceiling(self):
        base = fixture().encode("utf-8")
        padding = b"<!--" + b"p" * (1048576 - len(base) - 7) + b"-->"
        self.assertEqual(len(base + padding), 1048576)
        self.assertEqual(validate(base + padding)["ProcessId"], 27182)

    def test_cdata_and_standard_escapes_are_text(self):
        content = fixture().replace(f"<AethelnCrashRunId>{RUN_ID}</AethelnCrashRunId>", f"<AethelnCrashRunId><![CDATA[{RUN_ID}]]></AethelnCrashRunId>")
        self.assertEqual(validate(content.encode("utf-8"))["CrashRunId"], RUN_ID)

    def test_unrelated_nested_engine_data_is_ignored(self):
        content = fixture().replace(
            "<Other>unrestricted-secret-do-not-emit</Other>",
            "<Other><Nested>unrestricted-secret-do-not-emit</Nested></Other>",
        )
        result = validate(content.encode("utf-8"))
        self.assertNotIn("secret-do-not-emit", str(result))


if __name__ == "__main__":
    unittest.main()
