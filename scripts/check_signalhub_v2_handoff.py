"""Offline review of pinned synthetic fixtures; NOT a production validator/sender.

Run from the repository root: python3 -m scripts.check_signalhub_v2_handoff
No network, runtime database, credential loading, or production configuration.
Exit 1 keeps source-semantic findings visible even when wire checks pass.
"""

import copy
import datetime
import hashlib
import hmac
import json
import pathlib
import re
import unicodedata

from .wxfomo_lan.briefing import BriefingError, references, validate_briefing
from .wxfomo_lan.cross_ca import cross_ca_cards
from .wxfomo_lan.minimax import _address_evidence


FIXTURES = pathlib.Path(__file__).parent / "fixtures/signalhub-v2-handoff-8f6df4f"
NETWORKS = set("base bsc ethereum arbitrum polygon optimism avalanche solana".split())
REPORT_KEYS = "id revision cadence windowStart windowEnd generatedAt summary model sourceCount sourceComplete sourcesTruncated topics findings sources briefing scope sourceReferences caDiscussions caCoverage"
ALERT_KEYS = "id revision address network groups groupCount mentionCount uniqueStatementCount duplicateCount firstSeenAt lastSeenAt triggeredAt evaluatedAt expiresAt windowSeconds thresholdGroups status notificationVersion catchup"
HEARTBEAT_KEYS = "listener worker pendingReports lastError caDetector pendingAlerts lastMessageObservedAt lastCaEvaluatedAt"


class ReviewError(ValueError):
    pass


def require(condition, code):
    if not condition:
        raise ReviewError(code)


def exact(value, keys):
    require(type(value) is dict and set(value) == set(keys.split()), "object_keys")


def integer(value, minimum=0):
    require(type(value) is int and minimum <= value <= 9007199254740991, "integer")


def boolean(value):
    require(type(value) is bool, "boolean")


def text(value, maximum):
    require(isinstance(value, str) and bool(value.strip()), "text")
    try:
        size = len(value.encode("utf-16-le")) // 2
    except UnicodeError:
        raise ReviewError("unicode")
    require(size <= maximum, "text_limit")
    require(not any(unicodedata.category(c) == "Cc" and c not in "\t\r\n"
                    for c in value), "control_character")


def timestamp(value):
    text(value, 40)
    require(re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|\+00:00)", value), "utc_time")
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, OverflowError):
        raise ReviewError("utc_time")


def rows(value, maximum):
    require(type(value) is list and len(value) <= maximum, "array_limit")
    return value


def groups(value):
    for group in rows(value, 50):
        text(group, 200)
    require(len(set(value)) == len(value), "duplicate_group")


def scan_text(value):
    if isinstance(value, str):
        text(value, 262144)
    elif isinstance(value, dict):
        for key, child in value.items():
            text(key, 200)
            scan_text(child)
    elif isinstance(value, list):
        for child in value:
            scan_text(child)


def counting(value):
    for key in ("mentionCount", "uniqueStatementCount", "duplicateCount"):
        integer(value[key])
    require(value["mentionCount"] == value["uniqueStatementCount"] + value["duplicateCount"], "ca_count_equation")


def synthetic_evidence(briefing):
    """Literal test-only address evidence; never proof of an actual chat."""
    messages = []
    for project in briefing["projects"]:
        for address in project["addresses"]:
            for ref in address["source_message_ids"]:
                messages.append({"eventId": ref, "groupName": "合成证据群",
                                 "content": address["address"], "observedAt": 0})
    return _address_evidence(messages)


def validate_report(report):
    exact(report, REPORT_KEYS)
    require(report["cadence"] in ("two_hour", "six_hour", "daily"), "cadence")
    require(timestamp(report["windowStart"]) < timestamp(report["windowEnd"]), "window")
    timestamp(report["generatedAt"])
    text(report["summary"], 10000)
    text(report["model"], 256)
    integer(report["sourceCount"])
    boolean(report["sourceComplete"])
    boolean(report["sourcesTruncated"])
    require(report["sourcesTruncated"] == (report["sourceCount"] > 0), "source_truncation")
    require(report["topics"] == report["findings"] == report["sources"] == [], "raw_or_legacy_sources")
    scope = report["scope"]
    exact(scope, "groupNames timeZone timeBasis dataCutoff frozenCount analyzedCount readableCount missingCount unknownTimeCount completeChatHistory externalVerification")
    groups(scope["groupNames"])
    require(scope["timeZone"] == "Asia/Shanghai" and scope["timeBasis"] == "notification_observed_at", "scope_time_basis")
    for key in ("frozenCount", "analyzedCount", "readableCount", "missingCount", "unknownTimeCount"):
        integer(scope[key])
    require(scope["frozenCount"] == scope["analyzedCount"] == report["sourceCount"], "frozen_count")
    require(scope["readableCount"] + scope["missingCount"] == scope["frozenCount"], "coverage_count")
    require(scope["unknownTimeCount"] <= scope["readableCount"], "unknown_time_count")
    require(scope["completeChatHistory"] is False and scope["externalVerification"] is False, "false_completeness")
    require(not scope["missingCount"] or report["sourceComplete"] is False, "missing_sources_complete")
    if scope["dataCutoff"] is not None:
        timestamp(scope["dataCutoff"])
    metadata = rows(report["sourceReferences"], 500)
    ids = set()
    for ref in metadata:
        exact(ref, "id group sender observedAt available")
        text(ref["id"], 32)
        require(re.fullmatch(r"M[0-9]{4,}", ref["id"]), "reference_id")
        require(1 <= int(ref["id"][1:]) <= report["sourceCount"], "reference_range")
        require(ref["id"] not in ids, "duplicate_reference")
        ids.add(ref["id"])
        boolean(ref["available"])
        if not ref["available"]:
            require(all(ref[k] is None for k in ("group", "sender", "observedAt")), "missing_identity")
        for key in ("group", "sender"):
            if ref[key] is not None:
                text(ref[key], 200)
        if ref["observedAt"] is not None:
            timestamp(ref["observedAt"])
    briefing = report["briefing"]
    validate_briefing(briefing, ids, synthetic_evidence(briefing))
    used = set(references(briefing))
    for ca in rows(report["caDiscussions"], 50):
        exact(ca, "address network groups mentionCount uniqueStatementCount duplicateCount summary sourceMessageIDs")
        text(ca["address"], 128)
        require(ca["network"] in NETWORKS | {"unknown"}, "network")
        groups(ca["groups"])
        counting(ca)
        if ca["summary"] is not None:
            text(ca["summary"], 2000)
        used.update(rows(ca["sourceMessageIDs"], 5))
    require(used == ids, "reference_closure")
    coverage = report["caCoverage"]
    exact(coverage, "sourcesComplete totalItems exportedItems truncated")
    boolean(coverage["sourcesComplete"])
    boolean(coverage["truncated"])
    integer(coverage["totalItems"])
    integer(coverage["exportedItems"])
    require(coverage["sourcesComplete"] == report["sourceComplete"], "ca_sources_complete")
    require(coverage["exportedItems"] == len(report["caDiscussions"]) <= coverage["totalItems"], "ca_coverage")
    require(coverage["truncated"] == (coverage["exportedItems"] < coverage["totalItems"]), "ca_truncation")


def validate_payload(value):
    kind = value.get("type")
    child_key = {"report": "report", "ca_alert": "alert", "heartbeat": "status"}.get(kind)
    require(child_key is not None, "type")
    exact(value, "schemaVersion type " + child_key)
    require(type(value["schemaVersion"]) is int and value["schemaVersion"] == 2, "version")
    scan_text(value)
    require(len(json.dumps(value, ensure_ascii=False, allow_nan=False).encode("utf-8")) <= 262144, "body_limit")
    item = value[child_key]
    if kind != "heartbeat":
        text(item["id"], 1024)
        require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]*", item["id"]), "object_id")
        integer(item["revision"], 1)
    if kind == "report":
        validate_report(item)
    elif kind == "ca_alert":
        exact(item, ALERT_KEYS)
        text(item["address"], 128)
        require(item["network"] in NETWORKS, "network")
        groups(item["groups"])
        integer(item["groupCount"], 2)
        require(item["groupCount"] == len(item["groups"]), "group_count")
        counting(item)
        for key in ("windowSeconds", "thresholdGroups", "notificationVersion"):
            integer(item[key])
        require(item["windowSeconds"] == 3600 and item["thresholdGroups"] == 2, "ca_parameters")
        require(item["notificationVersion"] in (0, 1) and item["notificationVersion"] <= item["revision"], "notification_version")
        boolean(item["catchup"])
        require(not item["catchup"] or item["notificationVersion"] == 0, "catchup_notification")
        times = {key: timestamp(item[key]) for key in ("firstSeenAt", "lastSeenAt", "triggeredAt", "evaluatedAt", "expiresAt")}
        require(item["status"] in ("active", "expired"), "alert_status")
        require(times["firstSeenAt"] <= times["lastSeenAt"] <= times["evaluatedAt"], "alert_time_order")
        require(times["triggeredAt"] <= times["evaluatedAt"], "trigger_time")
        if item["status"] == "active":
            require(times["evaluatedAt"] - 3600 < times["firstSeenAt"] and times["evaluatedAt"] < times["expiresAt"], "active_window")
    else:
        exact(item, HEARTBEAT_KEYS)
        for key in ("listener", "worker", "caDetector"):
            require(item[key] in ("online", "offline", "unknown"), "process_state")
        for key in ("pendingReports", "pendingAlerts"):
            integer(item[key])
        for key in ("lastMessageObservedAt", "lastCaEvaluatedAt"):
            if item[key] is not None:
                timestamp(item[key])
        if item["lastError"] is not None:
            require(re.fullmatch(r"[a-z][a-z0-9_]{0,79}", item["lastError"]), "error_code")


def unique_object(pairs):
    value = {}
    for key, child in pairs:
        require(key not in value, "duplicate_json_key")
        value[key] = child
    return value


def load_fixtures():
    manifest = json.loads((FIXTURES / "manifest.json").read_text(encoding="utf-8"))
    result = {}
    for name, expected in manifest["files"].items():
        body = (FIXTURES / name).read_bytes()
        actual = hashlib.sha1(b"blob " + str(len(body)).encode("ascii") + b"\0" + body).hexdigest()
        require(actual == expected, "fixture_blob_mismatch")
        result[name] = json.loads(body.decode("utf-8"), object_pairs_hook=unique_object)
    return result


def verify_vectors(fixtures):
    vectors = fixtures["signature.example.json"]
    require({v["type"] for v in vectors["vectors"]} == {"report", "ca_alert", "heartbeat"}, "vector_types")
    for vector in vectors["vectors"]:
        body = vector["body"].encode("utf-8")
        canonical = json.dumps(fixtures[vector["fixture"]], ensure_ascii=False, allow_nan=False,
                               sort_keys=True, separators=(",", ":")).encode("utf-8")
        require(body == canonical, "vector_canonical_bytes")
        digest = hashlib.sha256(body).hexdigest()
        require(digest == vector["bodySha256"], "vector_digest")
        signed = "\n".join(("POST", "/api/wecom/ingest", vector["device"], vector["timestamp"], vector["nonce"], digest))
        actual = hmac.new(vectors["secret"].encode("utf-8"), signed.encode("utf-8"), hashlib.sha256).hexdigest()
        require(hmac.compare_digest(actual, vector["signature"]), "vector_signature")
    return len(vectors["vectors"])


def verify_negative_cases(fixtures):
    cases = [
        ("report.example.json", ("schemaVersion",), 1),
        ("report.example.json", ("report", "revision"), True),
        ("report.example.json", ("report", "sources"), [{"content": "synthetic raw"}]),
        ("report.example.json", ("report", "scope", "missingCount"), 0),
        ("report.example.json", ("report", "sourceComplete"), True),
        ("report.example.json", ("report", "sourceReferences", 0, "content"), "synthetic raw"),
        ("report.example.json", ("report", "sourceReferences", 2, "sender"), "invented"),
        ("report.example.json", ("report", "sourceReferences", 0, "sender"), "a" * 201),
        ("report.example.json", ("report", "sourceReferences", 0, "id"), "M9999"),
        ("report.example.json", ("report", "caCoverage", "exportedItems"), 0),
        ("report.example.json", ("report", "caDiscussions", 0, "duplicateCount"), 2),
        ("report.example.json", ("report", "briefing", "quick_read", "focus", "source_message_ids"), []),
        ("report.example.json", ("report", "briefing", "quick_read", "focus", "text"), "\ud800"),
        ("report.example.json", ("report", "briefing", "quick_read", "focus", "text"), "a\x00b"),
        ("report.example.json", ("report", "briefing", "quick_read", "focus", "text"), "a" * 601),
        ("ca-alert.example.json", ("alert", "network"), "unknown"),
        ("ca-alert.example.json", ("alert", "groups"), ["同一群", "同一群"]),
        ("ca-alert.example.json", ("alert", "catchup"), True),
        ("ca-alert.example.json", ("alert", "notificationVersion"), 2),
        ("ca-alert.example.json", ("alert", "firstReceivedAt"), "2026-09-06T00:00:00Z"),
        ("ca-alert.example.json", ("alert", "evaluatedAt"), "2026-09-06T01:10:00Z"),
        ("heartbeat.example.json", ("status", "pendingReports"), -1),
        ("heartbeat.example.json", ("status", "pendingAlerts"), True),
        ("heartbeat.example.json", ("status", "lastError"), "Exception: private data"),
    ]
    for filename, path, replacement in cases:
        value = copy.deepcopy(fixtures[filename])
        target = value
        for key in path[:-1]:
            target = target[key]
        target[path[-1]] = replacement
        try:
            validate_payload(value)
        except (ReviewError, BriefingError):
            continue
        raise ReviewError("negative_not_rejected:" + filename + "/" + "/".join(map(str, path)))
    return len(cases)


def source_semantic_findings(fixtures):
    """Reproduce the nickname-based count boundary with synthetic text only."""
    report = fixtures["report.example.json"]["report"]
    card = report["caDiscussions"][0]
    available = [ref for ref in report["sourceReferences"] if ref["available"]]
    require(len(available) == report["scope"]["readableCount"] == card["mentionCount"] == 2,
            "reproduction_precondition")
    messages = [dict(eventId=ref["id"], group=ref["group"], sender=ref["sender"],
                     content="Base CA: " + card["address"], observedAt=ref["observedAt"])
                for ref in available]
    different_speakers = cross_ca_cards(messages, [])["items"][0]
    same_speaker_messages = copy.deepcopy(messages)
    same_speaker_messages[1]["sender"] = same_speaker_messages[0]["sender"]
    same_speaker = cross_ca_cards(same_speaker_messages, [])["items"][0]
    require((different_speakers["uniqueStatementCount"], different_speakers["duplicateCount"]) == (2, 0), "mac_dedup_reproduction")
    require((same_speaker["uniqueStatementCount"], same_speaker["duplicateCount"]) == (1, 1), "mac_dedup_control")
    if (card["uniqueStatementCount"], card["duplicateCount"]) != (2, 0):
        return ["report.example.json: uniqueStatementCount/duplicateCount are 1/1; two distinct supplied nicknames require 2/0 under current Mac rules"]
    return []


def main():
    fixtures = load_fixtures()
    bodies = [value for name, value in fixtures.items() if name != "signature.example.json"]
    for value in bodies:
        validate_payload(value)
    vectors = verify_vectors(fixtures)
    rejected = verify_negative_cases(fixtures)
    emoji = copy.deepcopy(fixtures["report.example.json"])
    emoji["report"]["briefing"]["quick_read"]["focus"]["text"] = "\U0001f680" * 600
    validate_payload(emoji)
    original = fixtures["report.example.json"]["report"]
    changed_address = copy.deepcopy(original["briefing"])
    changed_address["projects"][0]["addresses"][0]["address"] = changed_address["projects"][0]["addresses"][0]["address"].lower()
    try:
        validate_briefing(changed_address, {ref["id"] for ref in original["sourceReferences"]},
                          synthetic_evidence(original["briefing"]))
    except BriefingError as error:
        require(error.code == "invalid_address_reference", "address_case_error")
    else:
        raise ReviewError("address_case_change_not_rejected")
    try:
        json.loads('{"schemaVersion":2,"schemaVersion":1}', object_pairs_hook=unique_object)
    except ReviewError:
        pass
    else:
        raise ReviewError("duplicate_json_not_rejected")
    early_close = copy.deepcopy(fixtures["ca-alert-expired.example.json"])
    early_close["alert"]["evaluatedAt"] = "2026-09-06T00:40:00.000Z"
    validate_payload(early_close)
    active = fixtures["ca-alert.example.json"]["alert"]
    closed = fixtures["ca-alert-expired.example.json"]["alert"]
    require({k: v for k, v in active.items() if k not in ("revision", "status", "evaluatedAt")} ==
            {k: v for k, v in closed.items() if k not in ("revision", "status", "evaluatedAt")}, "closed_snapshot")
    require(closed["revision"] > active["revision"], "revision_sequence")
    findings = source_semantic_findings(fixtures)
    print("Pinned blobs: {}/{} exact; v2 fixture structures/closures/count equations: {}/{} PASS".format(len(fixtures), len(fixtures), len(bodies), len(bodies)))
    print("Python canonical bytes/SHA256/HMAC: {}/{} PASS; illegal variants rejected: {}".format(vectors, vectors, rejected))
    print("Mac market/business briefing, 600 supplementary characters, address-case guard, duplicate JSON rejection, early close, closed snapshot, and dedup A/B: PASS")
    for finding in findings:
        print("REVIEW FINDING: " + finding)
    print("Source-semantic findings: {}; production/receiver/browser tests: NOT RUN".format(len(findings)))
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
