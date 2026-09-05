"""Bounded, redacted, read-only projections of the LAN analysis store."""

import datetime
import errno
import json
import math
import os
import re
import sqlite3
import stat
import unicodedata
import urllib.parse

from .messages import MessageSourceUnavailable, merge_message_annotations
from .cross_ca import cross_ca_cards
from .rules import RULE_CATALOG, rules_payload


MAX_ROWS = 1000
MAX_ANALYSIS_REPORTS = 30
MAX_EVENT_IDS = 1000
MAX_JSON_BYTES = 64 * 1024
MAX_RESULT_ITEMS = 200
_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,1023}$")
_CADENCES = frozenset(("two_hour", "six_hour", "daily"))
_JOB_STATES = frozenset((
    "queued", "running", "retry_wait", "credential_required", "failed",
    "succeeded", "skipped_empty",
))
_ERROR_CODES = frozenset((
    "credential_unavailable", "rate_limited", "transport_error",
    "invalid_response", "request_invalid", "provider_unavailable",
))
_SEVERITIES = frozenset(("warning", "critical"))
_FINDING_CATEGORIES = frozenset((
    "key_claim", "action_item", "deadline", "risk", "opportunity",
    "disagreement", "open_question",
))
_EPISTEMIC_STATUSES = frozenset(("fact", "inference", "uncertain"))
_RULES_BY_ID = {rule["ruleId"]: rule for rule in RULE_CATALOG}

_MATCH_SCHEMA = {
    "message_rule_matches": {
        "event_id", "rule_id", "priority", "severity", "tags_json",
        "matched_terms_json", "created_at",
    }
}
_ALERT_SCHEMA = {
    "rule_alerts": {
        "alert_id", "event_id", "rule_id", "severity", "title",
        "occurrence_count", "created_at", "updated_at",
    }
}
_RULE_SCHEMA = {"analysis_worker_state": {"singleton_id", "rule_catalog_version"}}
_SETTINGS_SCHEMA = {
    "analysis_worker_state": {
        "singleton_id", "credential_status", "last_provider_success_at",
        "last_error_code",
    }
}
_DIAGNOSTICS_SCHEMA = {
    "analysis_worker_state": {
        "singleton_id", "heartbeat_at", "rule_cursor_time",
        "rule_cursor_event_id", "last_provider_success_at", "last_error_code",
    }
}
_DIAGNOSTICS_MATCH_SCHEMA = {"message_rule_matches": {"event_id"}}
_DIAGNOSTICS_JOB_SCHEMA = {"analysis_jobs": {"state"}}
_ANALYSES_SCHEMA = {
    "analysis_jobs": {
        "job_id", "cadence", "window_start", "window_end", "state",
        "source_event_ids_json", "attempt", "maximum_attempts",
        "next_attempt_at", "error_code", "created_at", "updated_at",
    },
    "analysis_results": {"analysis_id", "job_id", "result_json", "model"},
}


def _available(items, invalid_rows=0):
    result = {"available": True, "reason": None, "items": items}
    if invalid_rows:
        result["invalidRows"] = invalid_rows
    return result


def _unavailable(reason):
    return {"available": False, "reason": reason, "items": []}


def _permission_denied_for_path(path):
    candidate = os.path.abspath(path or ".")
    is_target = True
    while True:
        try:
            information = os.stat(candidate)
        except OSError as error:
            if error.errno in (errno.EACCES, errno.EPERM):
                return True
            if error.errno not in (errno.ENOENT, errno.ENOTDIR):
                return False
        else:
            required = os.R_OK
            if not is_target or stat.S_ISDIR(information.st_mode):
                required |= os.X_OK
            if not os.access(candidate, required):
                return True
        parent = os.path.dirname(candidate)
        if parent == candidate:
            return False
        candidate = parent
        is_target = False


def _source_error_reason(error, path):
    message = str(error).lower()
    if "locked" in message or "busy" in message:
        return "source_locked"
    if "malformed" in message or "not a database" in message:
        return "source_corrupt"
    if (
        isinstance(error, PermissionError)
        or getattr(error, "errno", None) in (errno.EACCES, errno.EPERM)
        or "permission denied" in message
        or "authorization denied" in message
        or "operation not permitted" in message
        or _permission_denied_for_path(path)
    ):
        return "source_permission_denied"
    if (
        isinstance(error, (FileNotFoundError, NotADirectoryError))
        or getattr(error, "errno", None) in (errno.ENOENT, errno.ENOTDIR)
        or "unable to open database file" in message
    ):
        return "source_unavailable"
    return "source_error"


def _timestamp(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if not math.isfinite(float(value)):
        return None
    try:
        instant = datetime.datetime.fromtimestamp(value, datetime.timezone.utc)
    except (OSError, OverflowError, TypeError, ValueError):
        return None
    return instant.isoformat().replace("+00:00", "Z")


def _identifier(value):
    if not isinstance(value, str) or not _IDENTIFIER.fullmatch(value):
        return None
    return value


def _text(value, maximum=4096):
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError:
        return None
    if len(encoded) > maximum:
        return None
    for character in value:
        if character == "\n":
            continue
        category = unicodedata.category(character)
        if category in ("Cc", "Cs") or (
            category == "Cf" and character not in "\u200c\u200d"
        ):
            return None
    return value


def _nonnegative_integer(value):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return value


def _json_value(blob, maximum=MAX_JSON_BYTES):
    if isinstance(blob, bytes):
        if maximum is not None and len(blob) > maximum:
            return None
        try:
            blob = blob.decode("utf-8")
        except UnicodeDecodeError:
            return None
    if not isinstance(blob, str):
        return None
    try:
        if maximum is not None and len(blob.encode("utf-8")) > maximum:
            return None
        return json.loads(
            blob,
            parse_constant=lambda unused: (_ for _ in ()).throw(ValueError()),
        )
    except (RecursionError, UnicodeEncodeError, ValueError, TypeError):
        return None


def _string_list(value, validator=_identifier, maximum=MAX_RESULT_ITEMS):
    if not isinstance(value, list) or (maximum is not None and len(value) > maximum):
        return None
    result = []
    seen = set()
    for item in value:
        safe = validator(item)
        if safe is None:
            return None
        if safe not in seen:
            seen.add(safe)
            result.append(safe)
    return result


def _project_result(value, frozen_ids):
    if not isinstance(value, dict):
        return None
    allowed_sources = set(frozen_ids)

    def sources(document):
        result = _string_list(document.get("sourceMessageIDs"))
        if result is None or any(item not in allowed_sources for item in result):
            return None
        return result

    summary = _text(value.get("summary"), MAX_JSON_BYTES)
    summary_sources = _string_list(value.get("summarySourceMessageIDs"))
    if (
        summary is None
        or summary_sources is None
        or any(item not in allowed_sources for item in summary_sources)
    ):
        return None
    result = {
        "summary": summary,
        "summarySourceMessageIDs": summary_sources,
        "sourceReferences": list(summary_sources),
        "uncertainties": [],
        "topics": [],
        "findings": [],
        "cryptoAddresses": [],
    }
    collections = value.get("topics"), value.get("findings"), value.get("cryptoAddresses")
    if any(not isinstance(collection, list) or len(collection) > MAX_RESULT_ITEMS
           for collection in collections):
        return None
    for topic in value["topics"]:
        if not isinstance(topic, dict):
            return None
        topic_sources = sources(topic)
        title = _text(topic.get("title"))
        topic_summary = _text(topic.get("summary"))
        if topic_sources is None or title is None or topic_summary is None:
            return None
        projected_topic = {
            "title": title,
            "summary": topic_summary,
            "sourceMessageIDs": topic_sources,
            "sourceReferences": list(topic_sources),
        }
        topic_id = _identifier(topic.get("topicID"))
        projected_topic["topicID"] = topic_id
        projected_topic["topicId"] = topic_id
        result["topics"].append(projected_topic)
    for finding in value["findings"]:
        if not isinstance(finding, dict):
            return None
        finding_sources = sources(finding)
        category = finding.get("category")
        status = finding.get("epistemicStatus")
        text = _text(finding.get("text"))
        if (
            finding_sources is None or category not in _FINDING_CATEGORIES
            or status not in _EPISTEMIC_STATUSES or text is None
        ):
            return None
        projected_finding = {
            "category": category,
            "text": text,
            "epistemicStatus": status,
            "sourceMessageIDs": finding_sources,
            "sourceReferences": list(finding_sources),
        }
        finding_id = _identifier(finding.get("findingID"))
        projected_finding["findingID"] = finding_id
        projected_finding["findingId"] = finding_id
        result["findings"].append(projected_finding)
    for address in value["cryptoAddresses"]:
        if not isinstance(address, dict):
            return None
        address_sources = sources(address)
        original = _identifier(address.get("address"))
        normalized = _identifier(address.get("normalizedAddress"))
        context = _text(address.get("contextSummary"))
        status = address.get("epistemicStatus")
        if (
            address_sources is None or original is None or normalized is None
            or context is None
            or status not in _EPISTEMIC_STATUSES
        ):
            return None
        result["cryptoAddresses"].append({
            "address": original,
            "normalizedAddress": normalized,
            "contextSummary": context,
            "epistemicStatus": status,
            "sourceMessageIDs": address_sources,
            "sourceReferences": list(address_sources),
        })
    return result


def _source_message_ids(item, frozen_ids):
    """Bound message hydration while preferring the result's verified citations."""
    groups = [item["sourceReferences"]]
    groups.extend(card["sourceMessageIDs"] for card in item.get("crossGroupCA", {}).get("items", ()))
    for name in ("topics", "findings", "cryptoAddresses"):
        groups.extend(document["sourceReferences"] for document in item.get(name, ()))
    groups.append(frozen_ids)
    selected = []
    seen = set()
    for group in groups:
        for event_id in group:
            if event_id not in seen:
                seen.add(event_id)
                selected.append(event_id)
                if len(selected) == MAX_EVENT_IDS:
                    return selected
    return selected


class AnalysisRepository(object):
    """Reads only public-safe analysis state and never opens AI credentials."""

    def __init__(self, database_path):
        self.database_path = database_path

    def _open(self):
        uri = "file:{}?mode=ro".format(
            urllib.parse.quote(os.path.abspath(self.database_path or ""))
        )
        connection = sqlite3.connect(uri, uri=True, timeout=0.25)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA query_only=ON")
        return connection

    @staticmethod
    def _has_required_schema(connection, required):
        tables = {
            row["name"] for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        }
        if not set(required).issubset(tables):
            return False
        for table, required_columns in required.items():
            columns = {
                row["name"] for row in connection.execute(
                    "PRAGMA table_info({})".format(table)
                ).fetchall()
            }
            if not set(required_columns).issubset(columns):
                return False
        return True

    def _rows(self, required, statement, parameters=()):
        try:
            connection = self._open()
        except (OSError, sqlite3.Error) as error:
            return _source_error_reason(error, self.database_path), None
        try:
            if not self._has_required_schema(connection, required):
                return "schema_incompatible", None
            return None, connection.execute(statement, parameters).fetchall()
        except sqlite3.Error as error:
            return _source_error_reason(error, self.database_path), None
        finally:
            connection.close()

    def annotations(self, event_ids):
        unique_ids = []
        seen = set()
        for event_id in event_ids:
            safe = _identifier(event_id)
            if safe is not None and safe not in seen and len(unique_ids) < MAX_EVENT_IDS:
                seen.add(safe)
                unique_ids.append(safe)
        if not unique_ids:
            return {}
        grouped = {}
        for start in range(0, len(unique_ids), 200):
            chunk = unique_ids[start:start + 200]
            placeholders = ",".join("?" for unused in chunk)
            reason, rows = self._rows(
                _MATCH_SCHEMA,
                "SELECT event_id, rule_id, priority, severity, tags_json, "
                "matched_terms_json FROM message_rule_matches WHERE event_id IN ({}) "
                "ORDER BY priority DESC, rule_id ASC LIMIT {}".format(
                    placeholders, MAX_ROWS
                ),
                chunk,
            )
            if reason:
                return {}
            for row in rows:
                event_id = _identifier(row["event_id"])
                rule_id = _identifier(row["rule_id"])
                priority = _nonnegative_integer(row["priority"])
                severity = row["severity"]
                tags = _string_list(_json_value(row["tags_json"]), _text)
                terms = _string_list(_json_value(row["matched_terms_json"]), _text)
                rule = _RULES_BY_ID.get(rule_id)
                if (
                    event_id not in seen or rule is None or priority is None
                    or severity not in _SEVERITIES | {None}
                    or tags is None or terms is None
                ):
                    continue
                item = grouped.setdefault(event_id, {
                    "tags": [], "matchedRules": [], "priority": None,
                    "severity": None, "matchedTerms": [],
                })
                if not any(match["ruleId"] == rule_id for match in item["matchedRules"]):
                    item["matchedRules"].append({
                        "ruleId": rule_id, "name": rule["name"], "priority": priority,
                    })
                for name, values in (("tags", tags), ("matchedTerms", terms)):
                    for value in values:
                        if value not in item[name]:
                            item[name].append(value)
                item["priority"] = priority if item["priority"] is None else max(
                    item["priority"], priority
                )
                if severity == "critical" or (
                    severity == "warning" and item["severity"] is None
                ):
                    item["severity"] = severity
        return grouped

    def rules(self):
        reason, rows = self._rows(
            _RULE_SCHEMA,
            "SELECT rule_catalog_version FROM analysis_worker_state "
            "WHERE singleton_id=1 LIMIT 1",
        )
        if reason:
            return _unavailable(reason)
        if not rows or rows[0]["rule_catalog_version"] != 1:
            return _unavailable("schema_incompatible")
        result = rules_payload()
        result["readOnly"] = True
        result["source"] = "local_default"
        for item in result["items"]:
            item["id"] = item["ruleId"]
            item["updatedAt"] = None
            item["readOnly"] = True
            item["source"] = "local_default"
        return result

    def alerts(self):
        reason, rows = self._rows(
            _ALERT_SCHEMA,
            "SELECT alert_id, event_id, rule_id, severity, title, occurrence_count, "
            "created_at, updated_at FROM rule_alerts "
            "ORDER BY updated_at DESC, alert_id DESC LIMIT {}".format(MAX_ROWS),
        )
        if reason:
            return _unavailable(reason)
        items = []
        invalid_rows = 0
        for row in rows:
            event_id = _identifier(row["event_id"])
            rule_id = _identifier(row["rule_id"])
            severity = row["severity"]
            title = _text(row["title"])
            count = _nonnegative_integer(row["occurrence_count"])
            created_at = _timestamp(row["created_at"])
            updated_at = _timestamp(row["updated_at"])
            if (
                event_id is None or rule_id not in _RULES_BY_ID
                or severity not in _SEVERITIES or title is None or count is None
                or created_at is None or updated_at is None
            ):
                invalid_rows += 1
                continue
            items.append({
                "alertId": str(row["alert_id"]),
                "severity": severity,
                "title": title,
                "body": None,
                "sourceEventIds": [event_id],
                "occurrenceCount": count,
                "ruleId": rule_id,
                "acknowledgedAt": None,
                "createdAt": created_at,
                "updatedAt": updated_at,
            })
        return _available(items, invalid_rows)

    def priority(self, messages):
        reason, rows = self._rows(
            _MATCH_SCHEMA,
            "SELECT event_id, MAX(priority) AS priority, MAX(created_at) AS created_at "
            "FROM message_rule_matches GROUP BY event_id "
            "ORDER BY priority DESC, created_at DESC, event_id ASC LIMIT {}".format(
                MAX_ROWS
            ),
        )
        if reason:
            return _unavailable(reason)
        event_ids = [row["event_id"] for row in rows if _identifier(row["event_id"])]
        annotations = self.annotations(event_ids)
        valid_event_ids = [event_id for event_id in event_ids if event_id in annotations]
        invalid_rows = len(event_ids) - len(valid_event_ids)
        try:
            source_messages = messages.by_event_ids(valid_event_ids)
        except MessageSourceUnavailable:
            source_messages = []
        merged = merge_message_annotations(source_messages, annotations)
        merged.sort(
            key=lambda item: (
                item.get("priority", -1), item.get("observedAt") or ""
            ),
            reverse=True,
        )
        return _available(
            merged,
            invalid_rows,
        )

    def analyses(self, messages):
        reason, rows = self._rows(
            _ANALYSES_SCHEMA,
            "SELECT jobs.job_id, jobs.cadence, jobs.window_start, jobs.window_end, "
            "jobs.state, jobs.source_event_ids_json, jobs.attempt, "
            "jobs.maximum_attempts, jobs.next_attempt_at, jobs.error_code, "
            "jobs.created_at, jobs.updated_at, results.analysis_id, "
            "results.result_json, results.model FROM analysis_jobs AS jobs "
            "LEFT JOIN analysis_results AS results ON results.job_id=jobs.job_id "
            "ORDER BY jobs.window_end DESC, jobs.job_id ASC LIMIT {}".format(MAX_ANALYSIS_REPORTS),
        )
        if reason:
            return _unavailable(reason)
        items = []
        invalid_rows = 0
        for row in rows:
            job_id = _identifier(row["job_id"])
            cadence = row["cadence"]
            state = "retry_wait" if row["state"] == "retry_waiting" else row["state"]
            # Frozen windows contain the entire analysis input, not result items.
            # Validate the full snapshot; limit only the messages returned below.
            source_ids = _string_list(
                _json_value(row["source_event_ids_json"], maximum=None), maximum=None
            )
            attempt = _nonnegative_integer(row["attempt"])
            maximum_attempts = _nonnegative_integer(row["maximum_attempts"])
            window_start = _timestamp(row["window_start"])
            window_end = _timestamp(row["window_end"])
            created_at = _timestamp(row["created_at"])
            updated_at = _timestamp(row["updated_at"])
            if (
                job_id is None or cadence not in _CADENCES or state not in _JOB_STATES
                or source_ids is None or attempt is None or maximum_attempts is None
                or window_start is None or window_end is None or created_at is None
                or updated_at is None
            ):
                invalid_rows += 1
                continue
            item = {
                "analysisId": str(row["analysis_id"])
                if row["analysis_id"] is not None else None,
                "jobId": job_id,
                "mode": "digest",
                "cadence": cadence,
                "windowStart": window_start,
                "windowEnd": window_end,
                "state": state,
                "attempt": attempt,
                "maximumAttempts": maximum_attempts,
                "nextAttemptAt": _timestamp(row["next_attempt_at"]),
                "errorCode": row["error_code"]
                if row["error_code"] in _ERROR_CODES else None,
                "createdAt": created_at,
                "updatedAt": updated_at,
                "sourceReferences": [],
                "uncertainties": [],
            }
            model = _text(row["model"], 256)
            if model is not None:
                item["model"] = model
            if row["result_json"] is not None:
                projected = _project_result(_json_value(row["result_json"]), source_ids)
                if projected is None:
                    invalid_rows += 1
                    continue
                item.update(projected)
            try:
                all_sources = messages.by_event_ids(source_ids)
            except MessageSourceUnavailable:
                all_sources = []
            source_map = {message["eventId"]: message for message in all_sources}
            item["crossGroupCA"] = cross_ca_cards(all_sources, item.get("cryptoAddresses", []))
            item["crossGroupCA"]["sourcesComplete"] = len(source_map) == len(source_ids)
            message_ids = _source_message_ids(item, source_ids)
            source_messages = [source_map[event_id] for event_id in message_ids if event_id in source_map]
            item["sourceMessages"] = merge_message_annotations(
                source_messages, self.annotations(message_ids)
            )
            items.append(item)
        return _available(items, invalid_rows)

    def settings_status(self):
        reason, rows = self._rows(
            _SETTINGS_SCHEMA,
            "SELECT credential_status, last_provider_success_at, last_error_code "
            "FROM analysis_worker_state WHERE singleton_id=1 LIMIT 1",
        )
        if reason or not rows:
            return {
                "available": False,
                "reason": reason or "schema_incompatible",
                "aiConfigured": False,
                "providerNames": [],
                "protocol": "anthropic_compatible",
                "model": "MiniMax-M2.7",
            }
        credential_status = rows[0]["credential_status"]
        if credential_status not in ("configured", "unconfigured", "unsafe", None):
            return {
                "available": False, "reason": "schema_incompatible",
                "aiConfigured": False, "providerNames": [],
                "protocol": "anthropic_compatible", "model": "MiniMax-M2.7",
            }
        return {
            "available": True,
            "reason": None,
            "aiConfigured": credential_status == "configured",
            "providerNames": ["MiniMax-M2.7"]
            if credential_status == "configured" else [],
            "protocol": "anthropic_compatible",
            "model": "MiniMax-M2.7",
            "credentialStatus": credential_status or "unconfigured",
            "lastProviderSuccessAt": _timestamp(rows[0]["last_provider_success_at"]),
            "lastErrorCode": rows[0]["last_error_code"]
            if rows[0]["last_error_code"] in _ERROR_CODES else None,
        }

    def diagnostics(self):
        settings = self.settings_status()
        reason, rows = self._rows(
            _DIAGNOSTICS_SCHEMA,
            "SELECT heartbeat_at, rule_cursor_time, rule_cursor_event_id, "
            "last_provider_success_at, last_error_code FROM analysis_worker_state "
            "WHERE singleton_id=1 LIMIT 1",
        )
        source = {"available": reason is None and bool(rows), "reason": reason}
        if not rows and reason is None:
            source["reason"] = "schema_incompatible"
        result = {
            "available": True,
            "reason": None,
            "items": [],
            "sources": {"analysis": source},
            "analysisWorker": {
                "active": False,
                "heartbeatAt": None,
                "ruleCursorTime": None,
                "ruleCursorEventId": None,
                "lastProviderSuccessAt": None,
                "lastErrorCode": None,
            },
            "aiConfigured": settings["aiConfigured"],
            "providerNames": settings["providerNames"],
            "ruleEvaluation": {
                "messageCount": 0,
                "cursorTime": None,
                "cursorEventId": None,
            },
            "jobCounts": {
                "queued": 0,
                "running": 0,
                "retryWait": 0,
                "credentialRequired": 0,
                "failed": 0,
                "succeeded": 0,
                "skippedEmpty": 0,
            },
        }
        if rows:
            row = rows[0]
            heartbeat = row["heartbeat_at"]
            result["analysisWorker"].update({
                "heartbeatAt": _timestamp(heartbeat),
                "ruleCursorTime": _timestamp(row["rule_cursor_time"]),
                "ruleCursorEventId": _identifier(row["rule_cursor_event_id"]),
                "lastProviderSuccessAt": _timestamp(row["last_provider_success_at"]),
                "lastErrorCode": row["last_error_code"]
                if row["last_error_code"] in _ERROR_CODES else None,
            })
            result["ruleEvaluation"].update({
                "cursorTime": _timestamp(row["rule_cursor_time"]),
                "cursorEventId": _identifier(row["rule_cursor_event_id"]),
            })
            if isinstance(heartbeat, (int, float)) and not isinstance(heartbeat, bool):
                result["analysisWorker"]["active"] = (
                    math.isfinite(float(heartbeat))
                    and abs(datetime.datetime.now(datetime.timezone.utc).timestamp()
                            - float(heartbeat)) <= 15.0
                )
        match_reason, match_rows = self._rows(
            _DIAGNOSTICS_MATCH_SCHEMA,
            "SELECT COUNT(DISTINCT event_id) AS message_count "
            "FROM message_rule_matches",
        )
        result["sources"]["ruleMatches"] = {
            "available": match_reason is None,
            "reason": match_reason,
        }
        if match_rows:
            count = _nonnegative_integer(match_rows[0]["message_count"])
            if count is not None:
                result["ruleEvaluation"]["messageCount"] = count
        job_reason, job_rows = self._rows(
            _DIAGNOSTICS_JOB_SCHEMA,
            "SELECT state, COUNT(*) AS item_count FROM analysis_jobs "
            "GROUP BY state LIMIT {}".format(MAX_ROWS),
        )
        result["sources"]["analysisJobs"] = {
            "available": job_reason is None,
            "reason": job_reason,
        }
        job_names = {
            "queued": "queued",
            "running": "running",
            "retry_wait": "retryWait",
            "retry_waiting": "retryWait",
            "credential_required": "credentialRequired",
            "failed": "failed",
            "succeeded": "succeeded",
            "skipped_empty": "skippedEmpty",
        }
        for job_row in job_rows or ():
            output_name = job_names.get(job_row["state"])
            count = _nonnegative_integer(job_row["item_count"])
            if output_name is not None and count is not None:
                result["jobCounts"][output_name] += count
        return result
