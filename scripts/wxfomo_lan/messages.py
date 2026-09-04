"""Read-only access to the private wxFomo message store."""

import base64
import datetime
import errno
import json
import math
import os
import re
import sqlite3
import stat
import time
import urllib.parse

from .security import public_https_links


DEFAULT_LIMIT = 50
MAX_LIMIT = 200
_CURSOR_CHARACTERS = re.compile(r"^[A-Za-z0-9_-]+$")
_INSTANCE_ID_PATTERN = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
)
MAX_GROUP_CONFIG_BYTES = 64 * 1024
LISTENER_HEARTBEAT_STALE_SECONDS = 5.0
_BOOTSTRAP_SCHEMA = {
    "conversations": {"id", "group_name", "message_count"},
    "messages": {
        "event_id",
        "group_name",
        "sender_display_name",
        "content",
        "message_type",
        "observed_at",
        "source_sequence",
    },
}
_MESSAGE_SCHEMA = {"messages": _BOOTSTRAP_SCHEMA["messages"]}


class InvalidCursor(ValueError):
    """Raised when an API cursor is not in the supported public format."""


class MessageSourceUnavailable(Exception):
    """Raised when the listener-owned SQLite message source cannot be read."""

    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def encode_cursor(observed_at, event_id):
    value = json.dumps(
        {"t": observed_at, "e": event_id}, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def decode_cursor(cursor):
    if not isinstance(cursor, str) or not cursor or "=" in cursor:
        raise InvalidCursor()
    if not _CURSOR_CHARACTERS.fullmatch(cursor):
        raise InvalidCursor()
    try:
        padding = "=" * (-len(cursor) % 4)
        decoded = base64.b64decode(
            (cursor + padding).encode("ascii"), altchars=b"-_", validate=True
        )
        value = json.loads(decoded.decode("utf-8"))
    except (UnicodeDecodeError, ValueError, TypeError):
        raise InvalidCursor()
    if (
        not isinstance(value, dict)
        or set(value) != {"t", "e"}
        or isinstance(value["t"], bool)
        or not isinstance(value["t"], (int, float))
        or not math.isfinite(value["t"])
        or not isinstance(value["e"], str)
        or not value["e"]
    ):
        raise InvalidCursor()
    return value["t"], value["e"]


def _escape_like(term):
    return term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _format_observed_at(timestamp):
    try:
        value = datetime.datetime.fromtimestamp(timestamp, datetime.timezone.utc)
    except (OverflowError, OSError, TypeError, ValueError):
        return None
    return value.isoformat().replace("+00:00", "Z")


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
    if "unable to open database file" in message:
        return "source_unavailable"
    return "source_error"


def _configured_groups(path):
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except (OSError, TypeError):
        return None
    try:
        current = os.fstat(descriptor)
        if not stat.S_ISREG(current.st_mode) or current.st_size > MAX_GROUP_CONFIG_BYTES:
            return None
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = None
            content = stream.read(MAX_GROUP_CONFIG_BYTES + 1)
    finally:
        if descriptor is not None:
            os.close(descriptor)
    if len(content) > MAX_GROUP_CONFIG_BYTES:
        return None
    try:
        text = content.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return None
    if "\x00" in text:
        return None
    result = []
    seen = set()
    for line in text.splitlines():
        group = line.strip()
        if group and not group.startswith("#") and group not in seen:
            seen.add(group)
            result.append(group)
    return result or None


class MessageRepository:
    """Queries the listener-owned SQLite database without ever mutating it."""

    def __init__(self, database_path, group_config_path):
        self.database_path = database_path
        self.group_config_path = group_config_path

    def _open(self):
        uri = "file:{}?mode=ro".format(
            urllib.parse.quote(os.path.abspath(self.database_path))
        )
        connection = sqlite3.connect(uri, uri=True, timeout=0.25)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA query_only=ON")
        return connection

    @staticmethod
    def _has_required_schema(connection, required):
        tables = {
            row["name"]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table'"
            ).fetchall()
        }
        if not set(required).issubset(tables):
            return False
        for table, required_columns in required.items():
            columns = {
                row["name"]
                for row in connection.execute(
                    "PRAGMA table_info({})".format(table)
                ).fetchall()
            }
            if not set(required_columns).issubset(columns):
                return False
        return True

    @staticmethod
    def _unavailable_bootstrap(configured, reason):
        return {
            "readOnly": True,
            "messageSource": {
                "available": False,
                "reason": reason,
                "listenerState": "unknown",
            },
            "listenerState": "unknown",
            "groups": [{"name": group, "count": 0} for group in (configured or [])],
            "counts": {"inbox": 0},
        }

    def bootstrap(self):
        configured = _configured_groups(self.group_config_path)
        try:
            connection = self._open()
        except (OSError, sqlite3.Error) as error:
            return self._unavailable_bootstrap(
                configured, _source_error_reason(error, self.database_path)
            )
        listener_snapshot = None
        listener_state = "unknown"
        heartbeat_at = None
        started_at = None
        listener_instance_id = None
        formatted_heartbeat_at = None
        formatted_started_at = None
        try:
            if not self._has_required_schema(connection, _BOOTSTRAP_SCHEMA):
                return self._unavailable_bootstrap(configured, "schema_incompatible")
            groups = connection.execute(
                """
                SELECT group_name AS name, message_count AS count
                FROM conversations
                ORDER BY id ASC
                """
            ).fetchall()
            inbox = connection.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
            try:
                state = connection.execute(
                    """
                    SELECT group_names_json, heartbeat_at, started_at, instance_id
                    FROM listener_state
                    WHERE singleton_id = 1
                    """
                ).fetchone()
            except sqlite3.Error:
                state = None
            if state is not None:
                try:
                    raw_groups = json.loads(state["group_names_json"])
                except (TypeError, ValueError):
                    raw_groups = None
                if (
                    isinstance(raw_groups, list)
                    and raw_groups
                    and all(isinstance(group, str) and group for group in raw_groups)
                ):
                    listener_snapshot = list(dict.fromkeys(raw_groups))
                raw_heartbeat = state["heartbeat_at"]
                raw_started = state["started_at"]
                raw_instance = state["instance_id"]
                if isinstance(raw_instance, str) and _INSTANCE_ID_PATTERN.fullmatch(
                    raw_instance.lower()
                ):
                    listener_instance_id = raw_instance.lower()
                if (
                    not isinstance(raw_started, bool)
                    and isinstance(raw_started, (int, float))
                    and math.isfinite(raw_started)
                ):
                    started_at = raw_started
                    formatted_started_at = _format_observed_at(raw_started)
                if (
                    not isinstance(raw_heartbeat, bool)
                    and isinstance(raw_heartbeat, (int, float))
                    and math.isfinite(raw_heartbeat)
                ):
                    heartbeat_at = raw_heartbeat
                    formatted_heartbeat_at = _format_observed_at(raw_heartbeat)
                if formatted_started_at is not None and formatted_heartbeat_at is not None:
                    heartbeat_age = time.time() - raw_heartbeat
                    listener_state = (
                        "active"
                        if -1.0 <= heartbeat_age <= LISTENER_HEARTBEAT_STALE_SECONDS
                        else "inactive"
                    )
        except sqlite3.Error as error:
            return self._unavailable_bootstrap(
                configured, _source_error_reason(error, self.database_path)
            )
        finally:
            connection.close()
        observed = [{"name": row["name"], "count": row["count"]} for row in groups]
        configured = listener_snapshot or configured
        if configured:
            counts_by_group = {group["name"]: group["count"] for group in observed}
            configured_set = set(configured)
            merged_groups = [
                {"name": group, "count": counts_by_group.get(group, 0)}
                for group in configured
            ]
            merged_groups.extend(
                group for group in observed if group["name"] not in configured_set
            )
        else:
            merged_groups = observed
        source = {
            "available": True,
            "listenerState": listener_state,
        }
        if heartbeat_at is not None and formatted_heartbeat_at is not None:
            source["heartbeatAt"] = formatted_heartbeat_at
        if started_at is not None and formatted_started_at is not None:
            source["startedAt"] = formatted_started_at
        if listener_instance_id is not None:
            source["instanceId"] = listener_instance_id
        return {
            "readOnly": True,
            "messageSource": source,
            "listenerState": listener_state,
            "groups": merged_groups,
            "counts": {"inbox": inbox},
        }

    def query(self, filters):
        limit = self._limit(filters.get("limit"))
        before = self._cursor(filters.get("before"))
        raw_after = filters.get("after")
        after = self._cursor(raw_after)
        if before is not None and after is not None:
            raise InvalidCursor()

        clauses = []
        parameters = []
        group = filters.get("group")
        if group:
            clauses.append("group_name = ?")
            parameters.append(group)
        term = filters.get("q")
        if term:
            pattern = "%{}%".format(_escape_like(term))
            clauses.append("(content LIKE ? ESCAPE '\\' OR sender_display_name LIKE ? ESCAPE '\\')")
            parameters.extend([pattern, pattern])
        if before is not None:
            clauses.append("(observed_at < ? OR (observed_at = ? AND event_id < ?))")
            parameters.extend([before[0], before[0], before[1]])
        if after is not None:
            clauses.append("(observed_at > ? OR (observed_at = ? AND event_id > ?))")
            parameters.extend([after[0], after[0], after[1]])

        direction = "ASC" if after is not None else "DESC"
        statement = """
            SELECT event_id, group_name, sender_display_name, content, message_type,
                   observed_at, source_sequence
            FROM messages
        """
        if clauses:
            statement += " WHERE " + " AND ".join(clauses)
        statement += " ORDER BY observed_at {} , event_id {} LIMIT ?".format(direction, direction)
        parameters.append(limit)

        try:
            connection = self._open()
        except (OSError, sqlite3.Error) as error:
            raise MessageSourceUnavailable(
                _source_error_reason(error, self.database_path)
            )
        try:
            if not self._has_required_schema(connection, _MESSAGE_SCHEMA):
                raise MessageSourceUnavailable("schema_incompatible")
            rows = connection.execute(statement, parameters).fetchall()
        except sqlite3.Error as error:
            raise MessageSourceUnavailable(
                _source_error_reason(error, self.database_path)
            )
        finally:
            connection.close()

        items = [self._message_dto(row) for row in rows]
        next_before = None
        latest_cursor = raw_after if after is not None else None
        if rows:
            oldest = rows[0] if after is not None else rows[-1]
            latest = rows[-1] if after is not None else rows[0]
            next_before = encode_cursor(oldest["observed_at"], oldest["event_id"])
            latest_cursor = encode_cursor(latest["observed_at"], latest["event_id"])
        return {
            "items": items,
            "nextBefore": next_before,
            "latestCursor": latest_cursor,
        }

    def by_event_ids(self, event_ids):
        """Return safe DTOs for exact persisted event IDs without a recency window."""
        unique_ids = []
        seen = set()
        for event_id in event_ids:
            if isinstance(event_id, str) and event_id and event_id not in seen:
                seen.add(event_id)
                unique_ids.append(event_id)
        if not unique_ids:
            return []
        try:
            connection = self._open()
        except (OSError, sqlite3.Error) as error:
            raise MessageSourceUnavailable(
                _source_error_reason(error, self.database_path)
            )
        by_id = {}
        try:
            if not self._has_required_schema(connection, _MESSAGE_SCHEMA):
                raise MessageSourceUnavailable("schema_incompatible")
            aliases_available = self._has_required_schema(
                connection,
                {"message_event_aliases": {"alias_event_id", "message_id"}},
            )
            quarantine_available = self._has_required_schema(
                connection,
                {"message_event_alias_quarantine": {"alias_event_id"}},
            )
            for start in range(0, len(unique_ids), 500):
                chunk = unique_ids[start:start + 500]
                placeholders = ",".join("?" for _item in chunk)
                rows = connection.execute(
                    """
                    SELECT event_id, group_name, sender_display_name, content,
                           message_type, observed_at, source_sequence
                    FROM messages
                    WHERE event_id IN ({})
                    """.format(placeholders),
                    chunk,
                ).fetchall()
                for row in rows:
                    by_id[row["event_id"]] = self._message_dto(row)
                if aliases_available:
                    quarantine_clause = ""
                    if quarantine_available:
                        quarantine_clause = """
                          AND NOT EXISTS(
                            SELECT 1 FROM message_event_alias_quarantine AS quarantine
                            WHERE quarantine.alias_event_id = aliases.alias_event_id
                          )
                        """
                    alias_rows = connection.execute(
                        """
                        SELECT aliases.alias_event_id AS event_id,
                               messages.group_name, messages.sender_display_name,
                               messages.content, messages.message_type,
                               messages.observed_at, messages.source_sequence
                        FROM message_event_aliases AS aliases
                        JOIN messages ON messages.id = aliases.message_id
                        WHERE aliases.alias_event_id IN ({})
                        {}
                        """.format(placeholders, quarantine_clause),
                        chunk,
                    ).fetchall()
                    for row in alias_rows:
                        if row["event_id"] not in by_id:
                            by_id[row["event_id"]] = self._message_dto(row)
        except sqlite3.Error as error:
            raise MessageSourceUnavailable(
                _source_error_reason(error, self.database_path)
            )
        finally:
            connection.close()
        return [by_id[event_id] for event_id in unique_ids if event_id in by_id]

    @staticmethod
    def _cursor(value):
        if value in (None, ""):
            return None
        return decode_cursor(value)

    @staticmethod
    def _limit(value):
        if value in (None, ""):
            return DEFAULT_LIMIT
        try:
            parsed = int(value)
        except (TypeError, ValueError):
            return DEFAULT_LIMIT
        return max(1, min(parsed, MAX_LIMIT))

    @staticmethod
    def _message_dto(row):
        result = {
            "eventId": row["event_id"],
            "group": row["group_name"],
            "sender": row["sender_display_name"] or "",
            "content": row["content"],
            "messageType": row["message_type"],
            "observedAt": _format_observed_at(row["observed_at"]),
            "sourceSequence": row["source_sequence"],
        }
        links = public_https_links(row["content"])
        if links:
            result["links"] = links
        return result
