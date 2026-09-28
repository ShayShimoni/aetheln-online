"""Validate already acquired Unreal crash XML under a closed identity schema.

This pure component does not acquire files or establish process, package,
marker, or crash provenance. The caller must prove those boundaries first.
Only the bounded, approved identity subset may leave this function.
"""

import re
from xml.etree import ElementTree
from xml.parsers import expat


MAX_XML_BYTES = 1048576
ALLOWED_FLOWS = frozenset(
    (
        "prototype-authority",
        "admission",
        "lease",
        "persistent-command",
        "transaction",
        "outbox",
        "reward",
        "transfer",
        "allocation",
        "dependency",
        "restore",
        "reconciliation",
    )
)
FIXED_GAME_DATA = {
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
ALLOWED_GAME_DATA = frozenset(FIXED_GAME_DATA) | {
    "AethelnEngineRevision",
    "AethelnFlowKind",
    "AethelnCrashRunId",
}


class CrashContextXmlError(ValueError):
    """The bounded XML or its independently supplied identity was rejected."""


def _reject(*_args):
    raise CrashContextXmlError("Crash XML validation rejected.")


def _parse_without_dtd(xml_bytes):
    builder = ElementTree.TreeBuilder()
    parser = expat.ParserCreate()
    parser.StartElementHandler = builder.start
    parser.EndElementHandler = builder.end
    parser.CharacterDataHandler = builder.data
    parser.StartDoctypeDeclHandler = _reject
    parser.EntityDeclHandler = _reject
    parser.ExternalEntityRefHandler = _reject
    parser.SetParamEntityParsing(expat.XML_PARAM_ENTITY_PARSING_NEVER)
    try:
        parser.Parse(xml_bytes, True)
        return builder.close()
    except (expat.ExpatError, TypeError, ValueError):
        _reject()


def _only_child(parent, name):
    matches = [child for child in parent if child.tag == name]
    if len(matches) != 1 or matches[0].attrib:
        _reject()
    return matches[0]


def _only_text(parent, name):
    node = _only_child(parent, name)
    if len(node) or node.text is None or not 0 < len(node.text) <= 128:
        _reject()
    return node.text


def validate_crash_context_xml(
    xml_bytes,
    expected_process_id,
    expected_crash_run_id,
    expected_engine_revision,
    expected_flow_kind,
):
    """Return only validated identifiers from at most 1 MiB of XML bytes.

    Expected values must come from independently verified launch and marker
    evidence. The engine-generated XML CrashGUID is intentionally independent
    from the marker ID and the launch report-folder override.
    """
    if type(xml_bytes) is not bytes or not 0 < len(xml_bytes) <= MAX_XML_BYTES:
        _reject()
    if type(expected_process_id) is not int or not 1 <= expected_process_id <= 2147483647:
        _reject()
    if type(expected_crash_run_id) is not str or not re.fullmatch(r"[0-9a-f]{32}", expected_crash_run_id):
        _reject()
    if type(expected_engine_revision) is not str or not re.fullmatch(r"[A-Za-z0-9.+_-]{1,128}", expected_engine_revision):
        _reject()
    if type(expected_flow_kind) is not str or expected_flow_kind not in ALLOWED_FLOWS:
        _reject()

    root = _parse_without_dtd(xml_bytes)
    if root is None or root.tag != "FGenericCrashContext" or root.attrib:
        _reject()
    runtime = _only_child(root, "RuntimeProperties")
    game_data = _only_child(root, "GameData")
    pid = _only_text(runtime, "ProcessId")
    if not re.fullmatch(r"[1-9][0-9]{0,9}", pid) or pid != str(expected_process_id):
        _reject()
    engine_guid = _only_text(runtime, "CrashGUID")
    if not re.fullmatch(r"UECC-Linux-[0-9A-Fa-f]{32}_[0-9]{4}", engine_guid):
        _reject()

    seen = set()
    for child in game_data:
        name = child.tag
        if child.attrib or ":" in name or name in seen:
            _reject()
        seen.add(name)
        if name.casefold().startswith("aetheln") and name not in ALLOWED_GAME_DATA:
            _reject()
        if any(
            descendant.tag.casefold().startswith("aetheln")
            for descendant in child.iter()
            if descendant is not child
        ):
            _reject()

    for name, value in FIXED_GAME_DATA.items():
        if _only_text(game_data, name) != value:
            _reject()
    crash_run_id = _only_text(game_data, "AethelnCrashRunId")
    if not re.fullmatch(r"[0-9a-f]{32}", crash_run_id) or crash_run_id != expected_crash_run_id:
        _reject()
    flow_kind = _only_text(game_data, "AethelnFlowKind")
    if flow_kind != expected_flow_kind:
        _reject()
    engine_revision = _only_text(game_data, "AethelnEngineRevision")
    if engine_revision != expected_engine_revision:
        _reject()

    return {
        "SchemaVersion": 1,
        "ProcessId": expected_process_id,
        "EngineCrashGuid": engine_guid,
        "CrashRunId": crash_run_id,
        "BuildConfiguration": "Development",
        "EngineRevision": engine_revision,
        "NetworkProfileId": "network-profile.unset",
        "FlowKind": flow_kind,
    }
