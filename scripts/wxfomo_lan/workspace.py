"""Schema-aware, redacted read-only access to the wxFomo workspace store."""

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


SAFE_RULE_FIELDS = {"id", "name", "description", "priority", "condition", "actions"}
SAFE_INTENT_FIELDS = {"symbol", "tokenName", "network", "reason", "riskSummary"}
SAFE_WATCH_FIELDS = {
    "symbol", "name", "network", "priceUsd", "marketCapUsd", "liquidityUsd"
}
SAFE_ANALYSIS_FIELDS = {
    "summary", "topics", "findings", "sourceReferences", "uncertainties"
}

_IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$")
_EVENT_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,1023}$")
_SYMBOL_PATTERN = re.compile(r"^[A-Za-z0-9$-]{1,32}$")
_TIME_ZONE_PATTERN = re.compile(
    r"^[A-Za-z][A-Za-z0-9_+-]*(?:/[A-Za-z0-9][A-Za-z0-9_+-]*)+$"
)
_ALERT_SEVERITIES = {"information", "warning", "critical"}
_ANALYSIS_MODES = {
    "digest", "important_information", "action_items", "risks_and_opportunities", "custom"
}
_ANALYSIS_STATES = {
    "pending", "running", "retry_wait", "succeeded", "failed", "cancelled"
}
_CHAINS = {"sol", "eth", "base", "bsc", "robinhood"}
_NETWORKS = {
    "ethereum", "base", "bsc", "arbitrum", "polygon", "optimism", "avalanche",
    "robinhood", "evm", "solana",
}
_FAMILIES = {"evm", "solana"}
_WATCH_STATES = {"pending", "watching", "removed"}
_TRADE_STATES = {
    "detected", "rejected", "eligible", "simulated", "awaiting_confirmation", "quoted",
    "submitting", "pending", "confirmed", "failed", "unprotected_position",
}
_FINDING_CATEGORIES = {
    "key_claim", "action_item", "deadline", "risk", "opportunity", "disagreement",
    "open_question",
}
_EPISTEMIC_STATES = {"fact", "inference", "uncertain"}
_VALIDATION_WARNINGS = {
    "unknown_source_reference_removed", "uncited_claim_downgraded", "uncited_summary",
    "uncited_topic", "unknown_crypto_address_removed", "uncited_crypto_context",
    "missing_crypto_context",
}
_SECURITY_FLAG_VALUES = {"yes", "no", "true", "false", "0", "1"}
_ALLOWED_DISPLAY_FORMAT_CHARACTERS = frozenset("\u200c\u200d")
_ALERTS_SCHEMA = {
    "workspace_alerts": {
        "alert_id", "severity", "title", "body", "source_event_ids_json",
        "occurrence_count", "rule_id", "acknowledged_at", "created_at", "updated_at",
    }
}
_ALERT_CONTEXT_SCHEMA = {
    "crypto_address_incidents": {
        "family", "network", "normalized_address", "mention_count",
        "group_names_json", "alert_id", "latest_seen_at",
    }
}
_ANALYSES_SCHEMA = {
    "analysis_jobs": {
        "job_id", "mode", "state", "attempt", "maximum_attempts", "created_at",
        "updated_at",
    },
    "analysis_results": {"analysis_id", "job_id", "result_json"},
}
_MEME_SCHEMA = {
    "ca_watch_pool_items": {
        "family", "network", "normalized_address", "item_json", "state", "is_pinned",
        "latest_seen_at", "updated_at",
    }
}
_MESSAGE_RULES_SCHEMA = {
    "message_rules": {"rule_id", "rule_json", "priority", "is_enabled", "updated_at"}
}
_AUTOMATION_RULES_SCHEMA = {
    "trade_automation_rules": {"rule_id", "rule_json", "is_enabled", "updated_at"}
}
_TRADES_SCHEMA = {
    "trade_intents": {
        "intent_id", "rule_id", "state", "chain", "family", "token_address",
        "estimated_spend_usd", "intent_json", "created_at", "updated_at",
    }
}
_PROVIDERS_SCHEMA = {
    "ai_provider_configurations": {"configuration_json", "is_default", "created_at"}
}
_TRADING_CONFIGURATION_SCHEMA = {
    "trade_automation_configuration": {"singleton_id"}
}


def _merge_schema(*schemas):
    merged = {}
    for schema in schemas:
        for table, columns in schema.items():
            merged.setdefault(table, set()).update(columns)
    return merged


# Market and priority remain optional. Every column read by the required native-backed
# endpoints is centralized here so health checks cannot drift behind their SELECTs.
_WORKSPACE_HEALTH_SCHEMA = _merge_schema(
    {"workspace_schema_migrations": {"version", "applied_at"}},
    _ALERTS_SCHEMA,
    _ALERT_CONTEXT_SCHEMA,
    _ANALYSES_SCHEMA,
    _MEME_SCHEMA,
    _MESSAGE_RULES_SCHEMA,
    _AUTOMATION_RULES_SCHEMA,
    _TRADES_SCHEMA,
    _PROVIDERS_SCHEMA,
    _TRADING_CONFIGURATION_SCHEMA,
)


def _reject_json_constant(_value):
    raise ValueError("nonstandard_json_constant")


def _valid_json_value(value):
    if value is None or isinstance(value, (bool, int, str)):
        return True
    if isinstance(value, float):
        return math.isfinite(value)
    if isinstance(value, list):
        return all(_valid_json_value(item) for item in value)
    if isinstance(value, dict):
        return all(
            isinstance(key, str) and _valid_json_value(item)
            for key, item in value.items()
        )
    return False


def _strict_json_loads(blob):
    value = json.loads(blob, parse_constant=_reject_json_constant)
    if not _valid_json_value(value):
        raise ValueError("invalid_json_value")
    return value


def _format_timestamp(timestamp):
    if timestamp is None:
        return None
    if isinstance(timestamp, bool) or not isinstance(timestamp, (int, float)):
        return None
    if not math.isfinite(timestamp):
        return None
    try:
        value = datetime.datetime.fromtimestamp(timestamp, datetime.timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None
    return value.isoformat().replace("+00:00", "Z")


def _identifier(value):
    if not isinstance(value, str) or not _IDENTIFIER_PATTERN.fullmatch(value):
        return None
    return value


def _event_id(value):
    if not isinstance(value, str) or not _EVENT_ID_PATTERN.fullmatch(value):
        return None
    return value


def _symbol(value):
    if not isinstance(value, str) or not _SYMBOL_PATTERN.fullmatch(value):
        return None
    return value


def _display_text(value, maximum_length=4096):
    if (
        not isinstance(value, str)
        or not value.strip()
        or len(value) > maximum_length
    ):
        return None
    for character in value:
        if character == "\n":
            continue
        category = unicodedata.category(character)
        if category in {"Cc", "Cs"} or (
            category == "Cf" and character not in _ALLOWED_DISPLAY_FORMAT_CHARACTERS
        ):
            return None
    return value


def _time_zone(value):
    if not isinstance(value, str) or not _TIME_ZONE_PATTERN.fullmatch(value):
        return None
    return value


def _enum_value(value, allowed):
    return value if isinstance(value, str) and value in allowed else None


def _safe_number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if isinstance(value, float) and not math.isfinite(value):
        return None
    return value


def _safe_boolean(value):
    return value if isinstance(value, bool) else None


def _validated_list(value, validator, maximum_items=200):
    if not isinstance(value, list):
        return []
    result = []
    for item in value[:maximum_items]:
        safe_item = validator(item)
        if safe_item is not None:
            result.append(safe_item)
    return result


def _decode_object(blob):
    try:
        if isinstance(blob, bytes):
            blob = blob.decode("utf-8")
        value = _strict_json_loads(blob)
    except (UnicodeDecodeError, ValueError, TypeError):
        return None
    return value if isinstance(value, dict) else None


def _copy_validated(result, output_name, source, validator, source_name=None):
    value = validator(source.get(source_name or output_name))
    if value is not None:
        result[output_name] = value


def _copy_number(result, output_name, source, source_name=None):
    value = _safe_number(source.get(source_name or output_name))
    if value is not None:
        result[output_name] = value


def _copy_boolean(result, output_name, source, source_name=None):
    value = _safe_boolean(source.get(source_name or output_name))
    if value is not None:
        result[output_name] = value


def _project_time_window(value):
    if not isinstance(value, dict):
        return None
    result = {}
    _copy_number(result, "startMinuteOfDay", value)
    _copy_number(result, "endMinuteOfDay", value)
    weekdays = value.get("weekdays")
    if isinstance(weekdays, list):
        result["weekdays"] = [
            item for item in weekdays[:7]
            if isinstance(item, int) and not isinstance(item, bool) and 1 <= item <= 7
        ]
    _copy_validated(result, "timeZoneIdentifier", value, _time_zone)
    return result


def _project_rule_condition(value):
    if not isinstance(value, dict):
        return None
    result = {}
    for name in ("groups", "senders", "includeKeywords", "excludeKeywords"):
        result[name] = _validated_list(value.get(name), _display_text)
    result["messageTypes"] = _validated_list(
        value.get("messageTypes"), lambda item: _enum_value(item, {"text", "media", "system", "unknown"})
    )
    regular_expressions = value.get("regularExpressions")
    if isinstance(regular_expressions, list):
        result["regularExpressionCount"] = min(len(regular_expressions), 1000)
    for name in ("includeKeywordMode", "regularExpressionMode"):
        _copy_validated(
            result, name, value, lambda item: _enum_value(item, {"any", "all"})
        )
    windows = value.get("timeWindows")
    result["timeWindows"] = []
    if isinstance(windows, list):
        result["timeWindows"] = [
            projected for projected in (_project_time_window(item) for item in windows[:50])
            if projected is not None
        ]
    _copy_boolean(result, "caseSensitive", value)
    return result


def _project_rule_action(value):
    if not isinstance(value, dict):
        return None
    action_type = value.get("type")
    if action_type not in {
        "add_tag", "suppress", "capture", "enqueue_summary", "local_alert", "invoke_script"
    }:
        return None
    result = {"type": action_type}
    if action_type == "add_tag":
        _copy_validated(result, "tag", value, _display_text)
    elif action_type == "enqueue_summary":
        _copy_validated(
            result, "configurationId", value, _identifier, "configuration_id"
        )
    elif action_type == "local_alert":
        severity = value.get("severity")
        if severity in {"information", "warning", "critical"}:
            result["severity"] = severity
        _copy_validated(result, "title", value, _display_text)
    elif action_type == "invoke_script":
        _copy_validated(result, "scriptId", value, _identifier, "script_id")
    return result


def _project_message_rule(document):
    result = {}
    if "id" in SAFE_RULE_FIELDS:
        _copy_validated(result, "id", document, _identifier)
    for name in ("name", "description"):
        if name in SAFE_RULE_FIELDS:
            _copy_validated(result, name, document, _display_text)
    if "priority" in SAFE_RULE_FIELDS:
        _copy_number(result, "priority", document)
    condition = _project_rule_condition(document.get("condition"))
    if "condition" in SAFE_RULE_FIELDS and condition is not None:
        result["condition"] = condition
    actions = document.get("actions")
    if "actions" in SAFE_RULE_FIELDS and isinstance(actions, list):
        result["actions"] = [
            projected for projected in (_project_rule_action(item) for item in actions[:100])
            if projected is not None
        ]
    return result


def _project_protection_order(value):
    if not isinstance(value, dict):
        return None
    result = {}
    _copy_validated(result, "id", value, _identifier)
    if value.get("kind") in {"take_profit", "stop_loss"}:
        result["kind"] = value["kind"]
    _copy_number(result, "triggerPercent", value)
    _copy_number(result, "sellPercent", value)
    return result


def _project_automation_rule(document):
    result = {}
    _copy_validated(result, "id", document, _identifier)
    _copy_validated(result, "name", document, _display_text)
    condition = {}
    condition["allowedChains"] = _validated_list(
        document.get("allowedChains"), lambda item: _enum_value(item, _CHAINS), 20
    )
    condition["groups"] = _validated_list(document.get("groups"), _display_text)
    condition["senders"] = _validated_list(document.get("senders"), _display_text)
    for name in (
        "aggregationWindowSeconds", "minimumMentions", "minimumDistinctGroups",
        "minimumMarketCapUSD", "maximumMarketCapUSD", "minimumLiquidityUSD",
        "minimumHolderCount", "maximumRugRatio",
    ):
        _copy_number(condition, name, document)
    _copy_boolean(condition, "requireSecurityData", document)
    result["condition"] = condition

    action = {"type": "trade"}
    for name in (
        "inputAmountNative", "maximumSlippagePercent", "maximumTradesPerDay",
        "tokenCooldownSeconds",
    ):
        _copy_number(action, name, document)
    _copy_boolean(action, "antiMEV", document)
    orders = document.get("protectionOrders")
    action["protectionOrders"] = []
    if isinstance(orders, list):
        action["protectionOrders"] = [
            projected for projected in (_project_protection_order(item) for item in orders[:10])
            if projected is not None
        ]
    result["actions"] = [action]
    return result


def _project_topic(value):
    if not isinstance(value, dict):
        return None
    result = {}
    _copy_validated(result, "topicId", value, _identifier, "topicID")
    _copy_validated(result, "title", value, _display_text)
    _copy_validated(result, "summary", value, _display_text)
    result["sourceReferences"] = _validated_list(
        value.get("sourceMessageIDs"), _event_id
    )
    if "title" not in result and "summary" not in result:
        return None
    return result


def _project_finding(value):
    if not isinstance(value, dict):
        return None
    result = {}
    _copy_validated(result, "findingId", value, _identifier, "findingID")
    _copy_validated(
        result, "category", value, lambda item: _enum_value(item, _FINDING_CATEGORIES)
    )
    _copy_validated(result, "text", value, _display_text)
    _copy_validated(
        result, "epistemicStatus", value,
        lambda item: _enum_value(item, _EPISTEMIC_STATES),
    )
    result["sourceReferences"] = _validated_list(
        value.get("sourceMessageIDs"), _event_id
    )
    if "text" not in result:
        return None
    return result


def _project_analysis(document):
    result = {}
    if "summary" in SAFE_ANALYSIS_FIELDS:
        _copy_validated(result, "summary", document, _display_text)
    topics = document.get("topics")
    if "topics" in SAFE_ANALYSIS_FIELDS and isinstance(topics, list):
        result["topics"] = [
            projected for projected in (_project_topic(item) for item in topics[:200])
            if projected is not None
        ]
    findings = document.get("findings")
    if "findings" in SAFE_ANALYSIS_FIELDS and isinstance(findings, list):
        result["findings"] = [
            projected for projected in (_project_finding(item) for item in findings[:500])
            if projected is not None
        ]
    if "sourceReferences" in SAFE_ANALYSIS_FIELDS:
        result["sourceReferences"] = _validated_list(
            document.get("summarySourceMessageIDs", document.get("sourceReferences")),
            _event_id,
        )
    if "uncertainties" in SAFE_ANALYSIS_FIELDS:
        result["uncertainties"] = _validated_list(
            document.get("validationWarnings", document.get("uncertainties")),
            lambda item: _enum_value(item, _VALIDATION_WARNINGS),
        )
    return result


def _project_market_snapshot(value):
    if not isinstance(value, dict):
        return {}
    result = {}
    _copy_validated(result, "symbol", value, _symbol)
    _copy_validated(result, "name", value, _display_text)
    _copy_validated(
        result, "network", value, lambda item: _enum_value(item, _CHAINS), "chain"
    )
    for output_name, source_name in (
        ("priceUsd", "priceUSD"),
        ("marketCapUsd", "marketCapUSD"),
        ("liquidityUsd", "liquidityUSD"),
    ):
        _copy_number(result, output_name, value, source_name)
    return {name: result[name] for name in SAFE_WATCH_FIELDS if name in result}


def _project_security_snapshot(value):
    if not isinstance(value, dict):
        return None
    result = {}
    for name in ("openSource", "ownerRenounced", "isHoneypot"):
        _copy_validated(
            result, name, value, lambda item: _enum_value(item, _SECURITY_FLAG_VALUES)
        )
    for name in ("mintRenounced", "freezeRenounced", "washTrading"):
        _copy_boolean(result, name, value)
    for name in (
        "rugRatio", "top10HolderRate", "devTeamHoldRate", "suspectedInsiderHoldRate",
        "buyTax", "sellTax",
    ):
        _copy_number(result, name, value)
    return result


def _project_trade_intent(document, fallback_network):
    result = {}
    if "symbol" in SAFE_INTENT_FIELDS:
        _copy_validated(result, "symbol", document, _symbol, "tokenSymbol")
    if "tokenName" in SAFE_INTENT_FIELDS:
        _copy_validated(result, "tokenName", document, _display_text)
    if "network" in SAFE_INTENT_FIELDS:
        network = _enum_value(document.get("chain"), _CHAINS) or _enum_value(
            fallback_network, _CHAINS
        )
        if network is not None:
            result["network"] = network
    if "reason" in SAFE_INTENT_FIELDS:
        reason = _display_text(document.get("failureReason"))
        if reason is None:
            reasons = _validated_list(document.get("rejectionReasons"), _display_text, 1)
            reason = reasons[0] if reasons else None
        if reason is not None:
            result["reason"] = reason
    if "riskSummary" in SAFE_INTENT_FIELDS:
        risk = _project_security_snapshot(document.get("securitySnapshot"))
        if risk is not None:
            result["riskSummary"] = risk
    return result


def _available(items, invalid_rows=0):
    result = {"available": True, "reason": None, "items": items}
    if invalid_rows:
        result["invalidRows"] = invalid_rows
    return result


def _unavailable(reason):
    return {"available": False, "reason": reason, "items": []}


def _permission_denied_for_path(path):
    candidate = os.path.abspath(path)
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
    ):
        return "source_unavailable"
    if "unable to open database file" in message:
        return "source_unavailable"
    return "source_error"


class WorkspaceRepository:
    """Reads only explicitly configured workspace and configuration sources."""

    def __init__(self, database_path, configuration_path):
        self.database_path = database_path
        self.configuration_path = configuration_path

    def _open(self):
        uri = "file:{}?mode=ro".format(
            urllib.parse.quote(os.path.abspath(self.database_path))
        )
        connection = sqlite3.connect(uri, uri=True, timeout=0.25)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA query_only=ON")
        return connection

    @staticmethod
    def _schema(connection):
        rows = connection.execute(
            "SELECT name, sql FROM sqlite_master WHERE type = 'table'"
        ).fetchall()
        return {row["name"] for row in rows}

    @staticmethod
    def _has_required_schema(connection, required):
        tables = WorkspaceRepository._schema(connection)
        if not set(required).issubset(tables):
            return False
        for table, required_columns in required.items():
            columns = {
                row["name"]
                for row in connection.execute("PRAGMA table_info({})".format(table)).fetchall()
            }
            if not set(required_columns).issubset(columns):
                return False
        return True

    def _rows(self, required, statement):
        try:
            connection = self._open()
        except (OSError, sqlite3.Error) as error:
            return _source_error_reason(error, self.database_path), None
        try:
            if not self._has_required_schema(connection, required):
                return "schema_incompatible", None
            return None, connection.execute(statement).fetchall()
        except sqlite3.Error as error:
            return _source_error_reason(error, self.database_path), None
        finally:
            connection.close()

    def priority(self):
        return _unavailable("source_unavailable")

    def alerts(self):
        reason, rows = self._rows(
            _ALERTS_SCHEMA,
            """
            SELECT alert_id, severity, title, body, source_event_ids_json,
                   occurrence_count, rule_id, acknowledged_at, created_at, updated_at
            FROM workspace_alerts
            ORDER BY created_at DESC, alert_id ASC
            """,
        )
        if reason:
            return _unavailable(reason)
        contexts = self._alert_token_contexts()
        items = []
        invalid_rows = 0
        for row in rows:
            try:
                source_event_ids = _strict_json_loads(row["source_event_ids_json"])
            except (UnicodeDecodeError, ValueError, TypeError):
                invalid_rows += 1
                continue
            if not isinstance(source_event_ids, list):
                invalid_rows += 1
                continue
            source_event_ids = _validated_list(source_event_ids, _event_id)
            item = {
                    "alertId": _identifier(row["alert_id"]),
                    "severity": _enum_value(row["severity"], _ALERT_SEVERITIES),
                    "title": _display_text(row["title"]),
                    "body": _display_text(row["body"]) if row["body"] is not None else None,
                    "sourceEventIds": source_event_ids,
                    "occurrenceCount": row["occurrence_count"],
                    "ruleId": _identifier(row["rule_id"]) if row["rule_id"] is not None else None,
                    "acknowledgedAt": _format_timestamp(row["acknowledged_at"]),
                    "createdAt": _format_timestamp(row["created_at"]),
                    "updatedAt": _format_timestamp(row["updated_at"]),
                }
            context = contexts.get(item["alertId"])
            if context is not None:
                item["tokenContext"] = context
            items.append(item)
        return _available(items, invalid_rows)

    def _alert_token_contexts(self):
        reason, rows = self._rows(
            _ALERT_CONTEXT_SCHEMA,
            """
            SELECT family, network, normalized_address, mention_count,
                   group_names_json, alert_id, latest_seen_at
            FROM crypto_address_incidents
            ORDER BY latest_seen_at DESC, alert_id ASC
            """,
        )
        if reason:
            return {}
        contexts = {}
        for row in rows:
            try:
                alert_id = _identifier(row["alert_id"])
                groups = _strict_json_loads(row["group_names_json"])
                mention_count = row["mention_count"]
                if (
                    alert_id in contexts
                    or not isinstance(groups, list)
                    or isinstance(mention_count, bool)
                    or not isinstance(mention_count, int)
                    or mention_count < 0
                ):
                    continue
                contexts[alert_id] = {
                    "family": _enum_value(row["family"], _FAMILIES),
                    "network": _enum_value(row["network"], _NETWORKS),
                    "address": _identifier(row["normalized_address"]),
                    "mentionCount": mention_count,
                    "groupNames": _validated_list(groups, _display_text),
                }
            except (UnicodeDecodeError, ValueError, TypeError):
                continue
        return contexts

    def analyses(self):
        reason, rows = self._rows(
            _ANALYSES_SCHEMA,
            """
            SELECT analysis_jobs.job_id, analysis_jobs.mode, analysis_jobs.state,
                   analysis_jobs.attempt, analysis_jobs.maximum_attempts,
                   analysis_jobs.created_at, analysis_jobs.updated_at,
                   analysis_results.analysis_id, analysis_results.result_json
            FROM analysis_jobs
            LEFT JOIN analysis_results ON analysis_results.job_id = analysis_jobs.job_id
            ORDER BY analysis_jobs.created_at DESC, analysis_jobs.job_id ASC
            """,
        )
        if reason:
            return _unavailable(reason)
        items = []
        invalid_rows = 0
        for row in rows:
            item = {
                "analysisId": _identifier(row["analysis_id"])
                if row["analysis_id"] is not None else None,
                "jobId": _identifier(row["job_id"]),
                "mode": _enum_value(row["mode"], _ANALYSIS_MODES),
                "state": _enum_value(row["state"], _ANALYSIS_STATES),
                "attempt": row["attempt"],
                "maximumAttempts": row["maximum_attempts"],
                "createdAt": _format_timestamp(row["created_at"]),
                "updatedAt": _format_timestamp(row["updated_at"]),
            }
            if row["result_json"] is not None:
                document = _decode_object(row["result_json"])
                if document is None:
                    invalid_rows += 1
                    continue
                item.update(_project_analysis(document))
            items.append(item)
        return _available(items, invalid_rows)

    def meme(self):
        reason, rows = self._rows(
            _MEME_SCHEMA,
            """
            SELECT family, network, normalized_address, item_json, state, is_pinned,
                   latest_seen_at, updated_at
            FROM ca_watch_pool_items
            ORDER BY is_pinned DESC, latest_seen_at DESC, normalized_address ASC
            """,
        )
        if reason:
            return _unavailable(reason)
        items = []
        invalid_rows = 0
        for row in rows:
            document = _decode_object(row["item_json"])
            if document is None:
                invalid_rows += 1
                continue
            item = {
                "family": _enum_value(row["family"], _FAMILIES),
                "network": _enum_value(row["network"], _NETWORKS),
                "address": _identifier(row["normalized_address"]),
                "state": _enum_value(row["state"], _WATCH_STATES),
                "isPinned": bool(row["is_pinned"]),
                "latestSeenAt": _format_timestamp(row["latest_seen_at"]),
                "updatedAt": _format_timestamp(row["updated_at"]),
            }
            snapshot = document.get("currentSnapshot")
            if not isinstance(snapshot, dict):
                snapshot = document.get("entrySnapshot")
            item.update(_project_market_snapshot(snapshot))
            mention_count = document.get("mentionCount")
            if (
                isinstance(mention_count, int)
                and not isinstance(mention_count, bool)
                and mention_count >= 0
            ):
                item["mentionCount"] = mention_count
            group_names = document.get("groupNames")
            if isinstance(group_names, list):
                item["groupNames"] = _validated_list(group_names, _display_text)
            items.append(item)
        return _available(items, invalid_rows)

    def market(self):
        required = {"market_snapshots": {"snapshot_json", "captured_at"}}
        reason, rows = self._rows(
            required,
            """
            SELECT snapshot_json, captured_at
            FROM market_snapshots
            ORDER BY captured_at DESC
            """,
        )
        if reason:
            return _unavailable(reason)
        items = []
        invalid_rows = 0
        for row in rows:
            document = _decode_object(row["snapshot_json"])
            if document is None:
                invalid_rows += 1
                continue
            item = _project_market_snapshot(document)
            item["capturedAt"] = _format_timestamp(row["captured_at"])
            items.append(item)
        return _available(items, invalid_rows)

    def rules(self):
        return self._rules_from_table("message_rules")

    def automations(self):
        return self._rules_from_table("trade_automation_rules")

    def _rules_from_table(self, table):
        if table == "message_rules":
            required = _MESSAGE_RULES_SCHEMA
            statement = """
                SELECT rule_id, rule_json, priority, is_enabled, updated_at
                FROM message_rules
                ORDER BY priority DESC, rule_id ASC
            """
        else:
            required = _AUTOMATION_RULES_SCHEMA
            statement = """
                SELECT rule_id, rule_json, is_enabled, updated_at
                FROM trade_automation_rules
                ORDER BY updated_at DESC, rule_id ASC
            """
        reason, rows = self._rows(required, statement)
        if reason:
            return _unavailable(reason)
        items = []
        invalid_rows = 0
        for row in rows:
            document = _decode_object(row["rule_json"])
            if document is None:
                invalid_rows += 1
                continue
            if table == "message_rules":
                item = _project_message_rule(document)
            else:
                item = _project_automation_rule(document)
            item["ruleId"] = _identifier(row["rule_id"])
            item["isEnabled"] = bool(row["is_enabled"])
            item["updatedAt"] = _format_timestamp(row["updated_at"])
            if table == "message_rules" and "priority" not in item:
                item["priority"] = row["priority"]
            items.append(item)
        return _available(items, invalid_rows)

    def trades(self):
        reason, rows = self._rows(
            _TRADES_SCHEMA,
            """
            SELECT intent_id, rule_id, state, chain, family, token_address,
                   estimated_spend_usd, intent_json, created_at, updated_at
            FROM trade_intents
            ORDER BY created_at DESC, intent_id ASC
            """,
        )
        if reason:
            return _unavailable(reason)
        items = []
        invalid_rows = 0
        for row in rows:
            document = _decode_object(row["intent_json"])
            if document is None:
                invalid_rows += 1
                continue
            item = {
                "intentId": _identifier(row["intent_id"]),
                "ruleId": _identifier(row["rule_id"]),
                "state": _enum_value(row["state"], _TRADE_STATES),
                "chain": _enum_value(row["chain"], _CHAINS)
                if row["chain"] is not None else None,
                "family": _enum_value(row["family"], _FAMILIES),
                "tokenAddress": _identifier(row["token_address"]),
                "estimatedSpendUsd": row["estimated_spend_usd"],
                "createdAt": _format_timestamp(row["created_at"]),
                "updatedAt": _format_timestamp(row["updated_at"]),
            }
            item.update(_project_trade_intent(document, row["chain"]))
            items.append(item)
        return _available(items, invalid_rows)

    def settings_status(self):
        configuration_reason, document = self._configuration_result()
        if configuration_reason:
            return self._settings_unavailable(configuration_reason)
        workspace_reason = self._workspace_health()
        if workspace_reason:
            return self._settings_unavailable(workspace_reason)
        provider_reason, provider_names = self._provider_names()
        if provider_reason:
            return self._settings_unavailable(provider_reason)
        trading_reason, trading_configured = self._trading_configured()
        if trading_reason:
            return self._settings_unavailable(trading_reason)
        configured_keys = document.get("aiProviderAPIKeys", {})
        ai_configured = isinstance(configured_keys, dict) and any(
            isinstance(value, str) and bool(value.strip()) for value in configured_keys.values()
        )
        speech = document.get("speech", {})
        speech_configured = isinstance(speech, dict) and any(
            isinstance(speech.get(name), str) and bool(speech[name].strip())
            for name in ("volcengineSeedAPIKey", "apiKey")
        )
        return {
            "available": True,
            "reason": None,
            "aiConfigured": ai_configured,
            "speechConfigured": speech_configured,
            "providerNames": provider_names,
            "tradingConfigured": trading_configured,
        }

    @staticmethod
    def _settings_unavailable(reason):
        return {
            "available": False,
            "reason": reason,
            "aiConfigured": False,
            "speechConfigured": False,
            "providerNames": [],
            "tradingConfigured": False,
        }

    def _configuration_result(self):
        try:
            with open(self.configuration_path, "r", encoding="utf-8") as stream:
                value = json.load(stream, parse_constant=_reject_json_constant)
        except OSError as error:
            return _source_error_reason(error, self.configuration_path), None
        except (UnicodeDecodeError, ValueError):
            return "source_corrupt", None
        if not isinstance(value, dict) or not _valid_json_value(value):
            return "source_corrupt", None
        return None, value

    def _configuration_document(self):
        return self._configuration_result()[1]

    def _provider_names(self):
        reason, rows = self._rows(
            _PROVIDERS_SCHEMA,
            """
            SELECT configuration_json
            FROM ai_provider_configurations
            ORDER BY is_default DESC, created_at ASC
            """,
        )
        if reason:
            return reason, []
        names = []
        for row in rows:
            document = _decode_object(row["configuration_json"])
            if document is None:
                continue
            name = _display_text(document.get("displayName"))
            if name is not None:
                names.append(name.strip())
        return None, names

    def _trading_configured(self):
        reason, rows = self._rows(
            _TRADING_CONFIGURATION_SCHEMA,
            "SELECT singleton_id FROM trade_automation_configuration LIMIT 1",
        )
        return reason, reason is None and bool(rows)

    def diagnostics(self, message_source=None):
        workspace_reason = self._workspace_health()
        configuration_reason, _document = self._configuration_result()
        sources = {
            "workspace": {
                "available": workspace_reason is None,
                "reason": workspace_reason,
            },
            "configuration": {
                "available": configuration_reason is None,
                "reason": configuration_reason,
            },
        }
        if message_source is not None:
            sources["messages"] = {
                "available": bool(message_source.get("available")),
                "reason": message_source.get("reason")
                if not message_source.get("available") else None,
            }
        return {
            "available": True,
            "reason": None,
            "items": [],
            "sources": sources,
            "listenerState": message_source.get("listenerState", "unknown")
            if message_source is not None else "unknown",
        }

    def _workspace_health(self):
        try:
            connection = self._open()
        except (OSError, sqlite3.Error) as error:
            return _source_error_reason(error, self.database_path)
        try:
            if not self._has_required_schema(connection, _WORKSPACE_HEALTH_SCHEMA):
                return "schema_incompatible"
        except sqlite3.Error as error:
            return _source_error_reason(error, self.database_path)
        finally:
            connection.close()
        return None
