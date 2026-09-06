"""Private durable Signal outbox; it never opens either source database."""

import hashlib
import json
import math
import os
import re
import sqlite3

from .credentials import (CredentialError, _entry_metadata, _safe_private_parent,
                          _validate_file)
from .signal_contract import SyncError, encode_payload


MAX_ITEMS = 1000
MAX_BYTES = 128 * 1024 * 1024
MAX_CA_BYTES = 32 * 1024 * 1024
APPLICATION_ID = 0x57584653
SCHEMA_VERSION = 1
CHANNELS = frozenset(("reports", "messages"))
KINDS = frozenset(("report", "ca_alert"))
TABLE_COLUMNS = {
    "sync_state": {"key", "value"},
    "outbox": {"kind", "id", "revision", "body", "body_sha256", "state",
               "attempts", "next_attempt_at", "error_code", "created_at"},
    "ca_mentions": {"key", "value"},
    "ca_episodes": {"key", "value"},
    "ca_meta": {"key", "value"},
}


def _number(value, code="store_invalid"):
    if (isinstance(value, bool) or not isinstance(value, (int, float))
            or not math.isfinite(value)):
        raise SyncError(code)
    return value


def _integer(value, code="store_invalid"):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise SyncError(code)
    return value


def _json(value):
    try:
        return json.dumps(value, ensure_ascii=False, allow_nan=False,
                          sort_keys=True, separators=(",", ":"))
    except (TypeError, ValueError, OverflowError, RecursionError):
        raise SyncError("state_change_invalid")


def _payload(body):
    if type(body) is not bytes:
        raise SyncError("payload_invalid")
    try:
        value = json.loads(body.decode("utf-8"))
        if encode_payload(value) != body:
            raise SyncError("payload_invalid")
        kind = value["type"]
        if kind == "heartbeat":
            raise SyncError("payload_invalid")
        item = value["report" if kind == "report" else "alert"]
        return kind, item["id"], item["revision"], hashlib.sha256(body).hexdigest()
    except SyncError:
        raise
    except (UnicodeError, ValueError, TypeError, KeyError, RecursionError):
        raise SyncError("payload_invalid")


def _text(value):
    return isinstance(value, str) and bool(value)


def _identity_value(store_id, device_id=None):
    if (not isinstance(store_id, str)
            or not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
                                store_id)):
        raise SyncError("identity_invalid")
    if (device_id is not None and (not isinstance(device_id, str)
            or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", device_id))):
        raise SyncError("identity_invalid")
    return {"store_id": store_id, "device_id": device_id}


def _mention_value(value):
    keys = {"row_id", "event_id", "record_version", "group", "observed_at",
            "inserted_at", "time_status", "catchup", "mentions"}
    if not isinstance(value, dict) or set(value) != keys:
        raise SyncError("state_change_invalid")
    _integer(value["row_id"], "state_change_invalid")
    _integer(value["record_version"], "state_change_invalid")
    if value["row_id"] < 1 or value["record_version"] < 1:
        raise SyncError("state_change_invalid")
    if not _text(value["event_id"]) or not _text(value["group"]):
        raise SyncError("state_change_invalid")
    for name in ("observed_at", "inserted_at"):
        if value[name] is not None:
            _number(value[name], "state_change_invalid")
    if value["time_status"] not in ("valid", "unknown", "future"):
        raise SyncError("state_change_invalid")
    if type(value["catchup"]) is not bool or not isinstance(value["mentions"], list):
        raise SyncError("state_change_invalid")
    mention_keys = {"address", "normalized_address", "network", "statement_digest"}
    for item in value["mentions"]:
        if not isinstance(item, dict) or set(item) != mention_keys:
            raise SyncError("state_change_invalid")
        if not all(_text(item[name]) for name in mention_keys):
            raise SyncError("state_change_invalid")
        if not re.fullmatch(r"[0-9a-f]{64}", item["statement_digest"]):
            raise SyncError("state_change_invalid")


def _episode_value(value):
    keys = {"sequence", "revision", "triggered_at", "address", "last_valid_alert",
            "cooldown_until", "catchup", "notification_version", "status"}
    if not isinstance(value, dict) or set(value) != keys:
        raise SyncError("state_change_invalid")
    for name in ("sequence", "revision", "notification_version"):
        _integer(value[name], "state_change_invalid")
    for name in ("triggered_at", "cooldown_until"):
        _number(value[name], "state_change_invalid")
    if not _text(value["address"]) or type(value["catchup"]) is not bool:
        raise SyncError("state_change_invalid")
    if value["status"] not in ("active", "expired"):
        raise SyncError("state_change_invalid")
    try:
        encode_payload({"schemaVersion": 2, "type": "ca_alert",
                        "alert": value["last_valid_alert"]})
    except SyncError:
        raise SyncError("state_change_invalid")
    alert = value["last_valid_alert"]
    if (value["sequence"] < 1 or value["revision"] < alert["revision"]
            or value["address"] != alert["address"]
            or value["catchup"] != alert["catchup"]
            or value["notification_version"] != alert["notificationVersion"]
            or value["cooldown_until"] < value["triggered_at"]
            or (value["status"] == "active"
                and (alert["status"] != "active" or value["revision"] != alert["revision"]))
            or (value["status"] == "expired"
                and (alert["status"] != "active" or value["revision"] != alert["revision"] + 1))):
        raise SyncError("state_change_invalid")


def _validated_changes(changes):
    if not isinstance(changes, (list, tuple)):
        raise SyncError("state_change_invalid")
    result = []
    meta_keys = frozenset(("next_episode", "skipped_expired",
                           "unknown_time_count", "future_time_count"))
    for change in changes:
        if not isinstance(change, dict) or change.get("op") not in (
                "upsert_mention", "delete_mention", "upsert_episode", "set_ca_meta"):
            raise SyncError("state_change_invalid")
        operation = change["op"]
        expected = {"op", "key"} if operation == "delete_mention" else {"op", "key", "value"}
        if set(change) != expected or not _text(change.get("key")):
            raise SyncError("state_change_invalid")
        if operation == "upsert_mention":
            _mention_value(change["value"])
            if change["key"] != "row:{}".format(change["value"]["row_id"]):
                raise SyncError("state_change_invalid")
        elif operation == "upsert_episode":
            _episode_value(change["value"])
        elif operation == "set_ca_meta":
            if change["key"] not in meta_keys:
                raise SyncError("state_change_invalid")
            _integer(change["value"], "state_change_invalid")
        result.append(copy_change(change))
    return result


def copy_change(value):
    return json.loads(_json(value))


def _channel_error_value(value):
    if (not isinstance(value, dict) or set(value) != {"cursor", "code", "at"}
            or not isinstance(value.get("code"), str)
            or not re.fullmatch(r"[a-z][a-z0-9_]{0,79}", value["code"])):
        raise SyncError("store_corrupt")
    _integer(value["cursor"], "store_corrupt")
    _number(value["at"], "store_corrupt")
    return copy_change(value)


def _source_snapshot(channel, value):
    common = {"file_device", "file_inode", "cursor_id"}
    report_keys = common | {"max_id", "cursor_job_id", "cursor_digest"}
    message_keys = common | {"sqlite_sequence", "cursor_row_id",
                             "cursor_event_id", "cursor_record_version"}
    expected = report_keys if channel == "reports" else message_keys
    if not isinstance(value, dict) or set(value) != expected:
        raise SyncError("source_anchor_invalid")
    for name in common:
        _integer(value[name], "source_anchor_invalid")
    if channel == "reports":
        _integer(value["max_id"], "source_anchor_invalid")
        empty = value["cursor_id"] == 0
        if empty != (value["cursor_job_id"] is None and value["cursor_digest"] is None):
            raise SyncError("source_anchor_invalid")
        if not empty and (not _text(value["cursor_job_id"])
                          or not isinstance(value["cursor_digest"], str)
                          or not re.fullmatch(r"[0-9a-f]{64}", value["cursor_digest"])):
            raise SyncError("source_anchor_invalid")
    else:
        _integer(value["sqlite_sequence"], "source_anchor_invalid")
        anchor = (value["cursor_row_id"], value["cursor_event_id"],
                  value["cursor_record_version"])
        if value["cursor_id"] == 0:
            if anchor != (None, None, None):
                raise SyncError("source_anchor_invalid")
        else:
            if (isinstance(anchor[0], bool) or not isinstance(anchor[0], int)
                    or anchor[0] < 1 or not _text(anchor[1])
                    or isinstance(anchor[2], bool) or not isinstance(anchor[2], int)
                    or anchor[2] < 1):
                raise SyncError("source_anchor_invalid")
    return copy_change(value)


def _message_anchor(snapshot):
    return {"row_id": snapshot["cursor_row_id"],
            "event_id": snapshot["cursor_event_id"],
            "record_version": snapshot["cursor_record_version"]}


def _valid_merge(previous, current, proofs):
    if not isinstance(proofs, (list, tuple)):
        raise SyncError("source_anchor_invalid")
    keys = {"previous", "current", "canonical_aliases"}
    anchor_keys = {"row_id", "event_id", "record_version"}
    for proof in proofs:
        if not isinstance(proof, dict) or set(proof) != keys:
            raise SyncError("source_anchor_invalid")
        if (not isinstance(proof["previous"], dict)
                or set(proof["previous"]) != anchor_keys
                or not isinstance(proof["current"], dict)
                or set(proof["current"]) != anchor_keys
                or not isinstance(proof["canonical_aliases"], list)
                or not all(_text(item) for item in proof["canonical_aliases"])):
            raise SyncError("source_anchor_invalid")
        if (proof["previous"] == previous and proof["current"] == current
                and previous["event_id"] in proof["canonical_aliases"]
                and current["row_id"] <= previous["row_id"]
                and current["record_version"] >= 1):
            return True
    return False


class SyncStore(object):
    """Single-owner SQLite store for fixed bytes, checkpoints and CA state."""

    def __init__(self, path, max_items=MAX_ITEMS, max_bytes=MAX_BYTES,
                 max_ca_bytes=MAX_CA_BYTES):
        try:
            self.path = os.path.abspath(os.fspath(path))
        except (TypeError, ValueError, OSError):
            raise SyncError("store_unsafe")
        self.max_items = _integer(max_items)
        self.max_bytes = _integer(max_bytes)
        self.max_ca_bytes = _integer(max_ca_bytes)
        self.connection = None
        parent = None
        descriptor = None
        created = False
        try:
            parent, name = _safe_private_parent(self.path, create=True)
            metadata = _entry_metadata(parent, name)
            if metadata is None:
                created = True
                flags = os.O_RDWR | os.O_CREAT | os.O_EXCL
                flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
                descriptor = os.open(name, flags, 0o600, dir_fd=parent)
                os.fchmod(descriptor, 0o600)
                os.close(descriptor)
                descriptor = None
                metadata = _entry_metadata(parent, name)
            _validate_file(metadata)
            self.connection = sqlite3.connect(self.path, timeout=1.0)
            self.connection.row_factory = sqlite3.Row
            application_id = self.connection.execute("PRAGMA application_id").fetchone()[0]
            user_version = self.connection.execute("PRAGMA user_version").fetchone()[0]
            if ((not created and application_id != APPLICATION_ID)
                    or application_id not in (0, APPLICATION_ID)
                    or user_version not in (0, SCHEMA_VERSION)):
                raise SyncError("store_schema_incompatible")
            if not created:
                self._validate_schema()
            self.connection.execute("PRAGMA foreign_keys=ON")
            self.connection.execute("PRAGMA journal_mode=DELETE")
            self.connection.execute("PRAGMA synchronous=FULL")
            if created:
                self._schema()
            after = os.stat(self.path, follow_symlinks=False)
            _validate_file(after)
            if (metadata.st_dev, metadata.st_ino) != (after.st_dev, after.st_ino):
                raise SyncError("store_unsafe")
        except SyncError:
            self.close()
            raise
        except (CredentialError, OSError, sqlite3.Error, TypeError, ValueError):
            self.close()
            raise SyncError("store_unsafe")
        finally:
            if descriptor is not None:
                os.close(descriptor)
            if parent is not None:
                os.close(parent)

    def _schema(self):
        self.connection.executescript("""
          CREATE TABLE IF NOT EXISTS sync_state(
            key TEXT PRIMARY KEY, value TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS outbox(
            kind TEXT NOT NULL, id TEXT NOT NULL, revision INTEGER NOT NULL,
            body BLOB NOT NULL, body_sha256 TEXT NOT NULL,
            state TEXT NOT NULL CHECK(state IN ('pending','acked','quarantined')),
            attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at REAL,
            error_code TEXT, created_at REAL NOT NULL,
            PRIMARY KEY(kind,id,revision));
          CREATE INDEX IF NOT EXISTS outbox_due ON outbox(state,next_attempt_at);
          CREATE TABLE IF NOT EXISTS ca_mentions(key TEXT PRIMARY KEY,value TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS ca_episodes(key TEXT PRIMARY KEY,value TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS ca_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        """)
        self.connection.execute("PRAGMA application_id={}".format(APPLICATION_ID))
        self.connection.execute("PRAGMA user_version={}".format(SCHEMA_VERSION))
        self.connection.commit()

    def _validate_schema(self):
        tables = set(row[0] for row in self.connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ))
        if not set(TABLE_COLUMNS).issubset(tables):
            raise SyncError("store_schema_incompatible")
        for table, expected in TABLE_COLUMNS.items():
            columns = set(row[1] for row in self.connection.execute(
                "PRAGMA table_info({})".format(table)
            ))
            if columns != expected:
                raise SyncError("store_schema_incompatible")
        index = self.connection.execute(
            "SELECT 1 FROM sqlite_master WHERE type='index' AND name='outbox_due'"
        ).fetchone()
        if index is None:
            raise SyncError("store_schema_incompatible")

    def close(self):
        if self.connection is not None:
            self.connection.close()
            self.connection = None

    def _require_open(self):
        if self.connection is None:
            raise SyncError("store_closed")

    def _get(self, key):
        try:
            row = self.connection.execute(
                "SELECT value FROM sync_state WHERE key=?", (key,)
            ).fetchone()
            return None if row is None else json.loads(row[0])
        except sqlite3.Error:
            raise SyncError("store_read_failed")
        except (TypeError, ValueError, RecursionError):
            raise SyncError("store_corrupt")

    def _set(self, key, value):
        self.connection.execute(
            "INSERT OR REPLACE INTO sync_state(key,value) VALUES(?,?)",
            (key, _json(value)),
        )

    def initialize(self, report_cursor, message_cursor, now, store_id=None):
        self._require_open()
        _integer(report_cursor)
        _integer(message_cursor)
        _number(now)
        identity = None if store_id is None else _identity_value(store_id)
        try:
            self.connection.execute("BEGIN IMMEDIATE")
            if self._get("initialized") is not None:
                raise SyncError("already_initialized")
            self._set("cursor:reports", report_cursor)
            self._set("cursor:messages", message_cursor)
            self._set("initialized", {"at": now})
            if identity is not None:
                self._set("sync_identity", identity)
            self.connection.commit()
        except SyncError:
            self.connection.rollback()
            raise
        except (OSError, sqlite3.Error):
            self.connection.rollback()
            raise SyncError("store_write_failed")

    def identity(self):
        self._require_open()
        value = self._get("sync_identity")
        if value is None:
            return None
        if not isinstance(value, dict) or set(value) != {"store_id", "device_id"}:
            raise SyncError("store_corrupt")
        try:
            return _identity_value(value["store_id"], value["device_id"])
        except SyncError:
            raise SyncError("store_corrupt")

    def bind_identity(self, store_id, device_id=None):
        self._require_open()
        requested = _identity_value(store_id, device_id)
        current = self.identity()
        if current is not None and (current["store_id"] != requested["store_id"]
                or (current["device_id"] is not None and device_id is not None
                    and current["device_id"] != device_id)):
            raise SyncError("identity_mismatch")
        value = requested if current is None else dict(
            current, device_id=current["device_id"] or device_id)
        try:
            self.connection.execute("BEGIN IMMEDIATE")
            self._set("sync_identity", value)
            self.connection.commit()
        except (OSError, sqlite3.Error):
            self.connection.rollback()
            raise SyncError("store_write_failed")
        return copy_change(value)

    def cursor(self, channel):
        self._require_open()
        if channel not in CHANNELS:
            raise SyncError("channel_invalid")
        value = self._get("cursor:" + channel)
        if value is None:
            raise SyncError("store_uninitialized")
        return _integer(value)

    def enqueue_batch(self, channel, next_cursor, payloads, now, state_changes=()):
        self._require_open()
        if channel not in CHANNELS:
            raise SyncError("channel_invalid")
        _integer(next_cursor)
        _number(now)
        if not isinstance(payloads, (list, tuple)):
            raise SyncError("payload_invalid")
        parsed_by_key = {}
        for raw in payloads:
            parsed = _payload(raw)
            key = parsed[:3]
            existing = parsed_by_key.get(key)
            if existing is not None and existing[1] != raw:
                raise SyncError("payload_conflict")
            parsed_by_key[key] = (parsed, raw)
        parsed = list(parsed_by_key.values())
        changes = _validated_changes(state_changes)
        if changes and channel != "messages":
            raise SyncError("state_change_invalid")
        try:
            self.connection.execute("BEGIN IMMEDIATE")
            current = self.cursor(channel)
            if next_cursor < current:
                raise SyncError("cursor_invalid")
            active = self.connection.execute(
                "SELECT COUNT(*),COALESCE(SUM(LENGTH(body)),0) FROM outbox "
                "WHERE state IN ('pending','quarantined')"
            ).fetchone()
            source_quarantine_count = self.connection.execute(
                "SELECT COUNT(*) FROM sync_state WHERE key LIKE 'quarantine:%'"
            ).fetchone()[0]
            extra_items = 0
            extra_bytes = 0
            for (kind, identifier, revision, digest), raw in parsed:
                expected_channel = "reports" if kind == "report" else "messages"
                if channel != expected_channel:
                    raise SyncError("channel_invalid")
                existing = self.connection.execute(
                    "SELECT body,body_sha256 FROM outbox WHERE kind=? AND id=? AND revision=?",
                    (kind, identifier, revision),
                ).fetchone()
                if existing is not None:
                    if existing["body_sha256"] != digest or bytes(existing["body"]) != raw:
                        raise SyncError("payload_conflict")
                    continue
                extra_items += 1
                extra_bytes += len(raw)
            if (active[0] + source_quarantine_count + extra_items > self.max_items
                    or active[1] + extra_bytes > self.max_bytes):
                raise SyncError("outbox_full")
            for (kind, identifier, revision, digest), raw in parsed:
                self.connection.execute(
                    "INSERT OR IGNORE INTO outbox(kind,id,revision,body,body_sha256,state,"
                    "next_attempt_at,created_at) VALUES(?,?,?,?,?,'pending',?,?)",
                    (kind, identifier, revision, sqlite3.Binary(raw), digest, now, now),
                )
            for change in changes:
                operation, key = change["op"], change["key"]
                if operation == "delete_mention":
                    self.connection.execute("DELETE FROM ca_mentions WHERE key=?", (key,))
                    continue
                table = {"upsert_mention": "ca_mentions",
                         "upsert_episode": "ca_episodes",
                         "set_ca_meta": "ca_meta"}[operation]
                self.connection.execute(
                    "INSERT OR REPLACE INTO {}(key,value) VALUES(?,?)".format(table),
                    (key, _json(change["value"])),
                )
            ca_bytes = sum(self.connection.execute(
                "SELECT COALESCE(SUM(LENGTH(CAST(key AS BLOB))+"
                "LENGTH(CAST(value AS BLOB))),0) FROM " + table
            ).fetchone()[0] for table in ("ca_mentions", "ca_episodes", "ca_meta"))
            if ca_bytes > self.max_ca_bytes:
                raise SyncError("ca_index_full")
            self._set("cursor:" + channel, next_cursor)
            self.connection.commit()
        except SyncError:
            self.connection.rollback()
            raise
        except (OSError, sqlite3.Error):
            self.connection.rollback()
            raise SyncError("store_write_failed")

    def pending(self, kind=None):
        self._require_open()
        if kind is not None and kind not in ("report", "ca_alert"):
            raise SyncError("kind_invalid")
        statement = ("SELECT kind,id,revision,body,attempts,next_attempt_at,error_code,created_at "
                     "FROM outbox WHERE state='pending'")
        parameters = ()
        if kind is not None:
            statement += " AND kind=?"
            parameters = (kind,)
        statement += " ORDER BY created_at,kind,id,revision LIMIT 1000"
        try:
            rows = self.connection.execute(statement, parameters).fetchall()
            return [dict(row, body=bytes(row["body"])) for row in rows]
        except (sqlite3.Error, TypeError, ValueError):
            raise SyncError("store_read_failed")

    def ca_state(self):
        self._require_open()
        result = {"mentions": {}, "episodes": {}, "meta": {}}
        for table, key in (("ca_mentions", "mentions"),
                           ("ca_episodes", "episodes"), ("ca_meta", "meta")):
            try:
                rows = self.connection.execute(
                    "SELECT key,value FROM {} ORDER BY key".format(table)
                ).fetchall()
                result[key] = {row["key"]: json.loads(row["value"]) for row in rows}
            except sqlite3.Error:
                raise SyncError("store_read_failed")
            except (TypeError, ValueError, RecursionError):
                raise SyncError("store_corrupt")
        result["meta"].setdefault("next_episode", 1)
        result["meta"].setdefault("skipped_expired", 0)
        return result

    @staticmethod
    def _decision(value):
        if (not isinstance(value, dict)
                or set(value) != {"action", "code", "retry_after", "scope"}
                or value["action"] not in ("ack", "retry", "quarantine", "pause")
                or value["scope"] not in ("item", "global", "schema")
                or (value["code"] is not None and
                    (not isinstance(value["code"], str)
                     or not re.fullmatch(
                         r"[a-z][a-z0-9_]{0,79}", value["code"]
                     )))):
            raise SyncError("decision_invalid")
        retry = value["retry_after"]
        if retry is not None:
            _number(retry, "decision_invalid")
            if not 0 <= retry <= 900:
                raise SyncError("decision_invalid")
        if (value["action"] == "ack"
                and (value["code"] is not None or retry is not None
                     or value["scope"] != "item")):
            raise SyncError("decision_invalid")
        if value["action"] == "quarantine" and value["scope"] != "item":
            raise SyncError("decision_invalid")
        if value["action"] == "pause" and value["scope"] not in ("global", "schema"):
            raise SyncError("decision_invalid")
        if value["action"] == "retry" and value["scope"] not in ("item", "global"):
            raise SyncError("decision_invalid")
        return copy_change(value)

    def apply_response(self, kind, identifier, revision, decision, now):
        self._require_open()
        if kind not in KINDS or not _text(identifier):
            raise SyncError("response_mismatch")
        _integer(revision, "response_mismatch")
        _number(now)
        decision = self._decision(decision)
        try:
            self.connection.execute("BEGIN IMMEDIATE")
            row = self.connection.execute(
                "SELECT state,attempts FROM outbox WHERE kind=? AND id=? AND revision=?",
                (kind, identifier, revision),
            ).fetchone()
            if row is None:
                raise SyncError("response_mismatch")
            if row["state"] == "acked" and decision["action"] == "ack":
                self.connection.commit()
                return
            if row["state"] != "pending":
                raise SyncError("response_state_invalid")
            attempts = row["attempts"] + 1
            action = decision["action"]
            if action == "ack":
                self.connection.execute(
                    "UPDATE outbox SET state='acked',attempts=?,next_attempt_at=NULL,"
                    "error_code=NULL WHERE kind=? AND id=? AND revision=?",
                    (attempts, kind, identifier, revision),
                )
            elif action == "quarantine":
                self.connection.execute(
                    "UPDATE outbox SET state='quarantined',attempts=?,next_attempt_at=NULL,"
                    "error_code=? WHERE kind=? AND id=? AND revision=?",
                    (attempts, decision["code"], kind, identifier, revision),
                )
            elif action == "retry":
                delay = decision["retry_after"]
                if delay is None:
                    delay = min(900, 2 ** min(attempts, 9))
                deadline = now + delay
                self.connection.execute(
                    "UPDATE outbox SET attempts=?,next_attempt_at=?,error_code=? "
                    "WHERE kind=? AND id=? AND revision=?",
                    (attempts, deadline, decision["code"], kind, identifier, revision),
                )
                if decision["scope"] == "global":
                    previous = self._get("global_retry_until") or 0
                    self._set("global_retry_until", max(previous, deadline))
                    self._set("global_retry_code", decision["code"])
            else:
                pause = {"code": decision["code"], "at": now}
                if decision["scope"] == "global":
                    self._set("global_pause", pause)
                else:
                    self._set("schema_pause:v2", pause)
                self.connection.execute(
                    "UPDATE outbox SET attempts=?,next_attempt_at=NULL,error_code=? "
                    "WHERE kind=? AND id=? AND revision=?",
                    (attempts, decision["code"], kind, identifier, revision),
                )
            self.connection.commit()
        except SyncError:
            self.connection.rollback()
            raise
        except (OSError, sqlite3.Error):
            self.connection.rollback()
            raise SyncError("store_write_failed")

    def apply_global_response(self, decision, now):
        """Persist a heartbeat's global retry/pause without inventing an item ID."""
        self._require_open()
        _number(now)
        decision = self._decision(decision)
        if decision["scope"] != "global" or decision["action"] not in ("retry", "pause"):
            raise SyncError("decision_invalid")
        try:
            self.connection.execute("BEGIN IMMEDIATE")
            if decision["action"] == "retry":
                delay = decision["retry_after"]
                if delay is None:
                    delay = 5
                deadline = now + delay
                previous = self._get("global_retry_until") or 0
                self._set("global_retry_until", max(previous, deadline))
                self._set("global_retry_code", decision["code"])
            else:
                self._set("global_pause", {"code": decision["code"], "at": now})
            self.connection.commit()
        except SyncError:
            self.connection.rollback()
            raise
        except (OSError, sqlite3.Error):
            self.connection.rollback()
            raise SyncError("store_write_failed")

    def record_channel_error(self, channel, cursor, code, now):
        """Persist a bounded retry location, never the offending source row."""
        self._require_open()
        if channel not in CHANNELS:
            raise SyncError("channel_invalid")
        _integer(cursor)
        _number(now)
        if not isinstance(code, str) or not re.fullmatch(r"[a-z][a-z0-9_]{0,79}", code):
            raise SyncError("state_change_invalid")
        try:
            self.connection.execute("BEGIN IMMEDIATE")
            self._set("error:" + channel,
                      {"cursor": cursor, "code": code, "at": now})
            self.connection.commit()
        except (OSError, sqlite3.Error):
            self.connection.rollback()
            raise SyncError("store_write_failed")

    def clear_channel_error(self, channel):
        self._require_open()
        if channel not in CHANNELS:
            raise SyncError("channel_invalid")
        try:
            self.connection.execute("DELETE FROM sync_state WHERE key=?",
                                    ("error:" + channel,))
            self.connection.commit()
        except (OSError, sqlite3.Error):
            self.connection.rollback()
            raise SyncError("store_write_failed")

    def quarantine_source(self, channel, cursor, code, now):
        self._require_open()
        if channel not in CHANNELS:
            raise SyncError("channel_invalid")
        _integer(cursor)
        _number(now)
        if not isinstance(code, str) or not re.fullmatch(r"[a-z][a-z0-9_]{0,79}", code):
            raise SyncError("state_change_invalid")
        try:
            self.connection.execute("BEGIN IMMEDIATE")
            key = "quarantine:{}:{}".format(channel, cursor)
            if self._get(key) is None:
                item_count = self.connection.execute(
                    "SELECT COUNT(*) FROM outbox WHERE state IN ('pending','quarantined')"
                ).fetchone()[0]
                source_count = self.connection.execute(
                    "SELECT COUNT(*) FROM sync_state WHERE key LIKE 'quarantine:%'"
                ).fetchone()[0]
                if item_count + source_count >= self.max_items:
                    raise SyncError("outbox_full")
            self._set("error:" + channel,
                      {"cursor": cursor, "code": code, "at": now})
            self._set(key,
                      {"cursor": cursor, "code": code, "at": now})
            self.connection.commit()
        except SyncError:
            self.connection.rollback()
            raise
        except (OSError, sqlite3.Error):
            self.connection.rollback()
            raise SyncError("store_write_failed")

    def source_quarantines(self, channel):
        self._require_open()
        if channel not in CHANNELS:
            raise SyncError("channel_invalid")
        prefix = "quarantine:" + channel + ":"
        try:
            rows = self.connection.execute(
                "SELECT value FROM sync_state WHERE key LIKE ? ORDER BY key",
                (prefix + "%",)).fetchall()
            return [_channel_error_value(json.loads(row[0])) for row in rows]
        except sqlite3.Error:
            raise SyncError("store_read_failed")
        except (TypeError, ValueError, RecursionError):
            raise SyncError("store_corrupt")

    def resolve_source_quarantine(self, channel, cursor):
        self._require_open()
        if channel not in CHANNELS:
            raise SyncError("channel_invalid")
        _integer(cursor)
        try:
            self.connection.execute(
                "DELETE FROM sync_state WHERE key=?",
                ("quarantine:{}:{}".format(channel, cursor),))
            self.connection.commit()
        except (OSError, sqlite3.Error):
            self.connection.rollback()
            raise SyncError("store_write_failed")

    def status(self, now):
        self._require_open()
        _number(now)
        try:
            rows = self.connection.execute(
                "SELECT state,kind,COUNT(*) AS count,COALESCE(SUM(LENGTH(body)),0) AS bytes "
                "FROM outbox GROUP BY state,kind"
            ).fetchall()
        except sqlite3.Error:
            raise SyncError("store_read_failed")
        counts = {(row["state"], row["kind"]): row for row in rows}
        pending_reports = counts.get(("pending", "report"))
        pending_alerts = counts.get(("pending", "ca_alert"))
        quarantined = sum(row["count"] for row in rows if row["state"] == "quarantined")
        retained_bytes = sum(row["bytes"] for row in rows
                             if row["state"] in ("pending", "quarantined"))
        channel_pauses = {}
        channel_errors = {}
        for channel in sorted(CHANNELS):
            pause = self._get("pause:" + channel)
            if pause is not None:
                channel_pauses[channel] = pause
            error = self._get("error:" + channel)
            if error is not None:
                channel_errors[channel] = _channel_error_value(error)
        deadline = self._get("global_retry_until")
        quarantines = {channel: self.source_quarantines(channel)
                       for channel in sorted(CHANNELS)}
        return {
            "initialized": self._get("initialized") is not None,
            "cursors": {channel: self._get("cursor:" + channel) for channel in sorted(CHANNELS)},
            "pendingReports": 0 if pending_reports is None else pending_reports["count"],
            "pendingAlerts": 0 if pending_alerts is None else pending_alerts["count"],
            "quarantined": quarantined, "retainedBytes": retained_bytes,
            "globalRetryUntil": deadline,
            "globalRetryActive": deadline is not None and now < deadline,
            "globalRetryCode": self._get("global_retry_code"),
            "globalPause": self._get("global_pause"),
            "schemaPause": self._get("schema_pause:v2"),
            "channelPauses": channel_pauses, "channelErrors": channel_errors,
            "sourceQuarantines": quarantines,
        }

    def _pause_source(self, channel, now):
        self.connection.execute("BEGIN IMMEDIATE")
        self._set("pause:" + channel,
                  {"code": "source_generation_changed", "at": now})
        self.connection.commit()

    def source_anchor(self, channel):
        self._require_open()
        if channel not in CHANNELS:
            raise SyncError("channel_invalid")
        value = self._get("source:" + channel)
        return None if value is None else copy_change(value)

    def check_source(self, channel, snapshot, now, merge_proofs=()):
        """Persist strict caller-supplied source anchors without opening the source."""
        self._require_open()
        if channel not in CHANNELS:
            raise SyncError("channel_invalid")
        _number(now)
        snapshot = _source_snapshot(channel, snapshot)
        if snapshot["cursor_id"] != self.cursor(channel):
            raise SyncError("source_anchor_invalid")
        previous = self._get("source:" + channel)
        changed = previous != snapshot
        maximum = "max_id" if channel == "reports" else "sqlite_sequence"
        mismatch = snapshot[maximum] < snapshot["cursor_id"]
        if previous is not None:
            mismatch = mismatch or ((previous["file_device"], previous["file_inode"])
                                    != (snapshot["file_device"], snapshot["file_inode"]))
            mismatch = mismatch or snapshot[maximum] < previous[maximum]
            mismatch = mismatch or snapshot["cursor_id"] < previous["cursor_id"]
            if snapshot["cursor_id"] == previous["cursor_id"]:
                if channel == "reports":
                    mismatch = mismatch or any(
                        snapshot[name] != previous[name]
                        for name in ("cursor_job_id", "cursor_digest")
                    )
                else:
                    old_anchor = _message_anchor(previous)
                    new_anchor = _message_anchor(snapshot)
                    if old_anchor != new_anchor:
                        mismatch = mismatch or not _valid_merge(
                            old_anchor, new_anchor, merge_proofs
                        )
        if mismatch:
            try:
                self._pause_source(channel, now)
            except (OSError, sqlite3.Error):
                self.connection.rollback()
                raise SyncError("store_write_failed")
            raise SyncError("source_generation_changed")
        try:
            self.connection.execute("BEGIN IMMEDIATE")
            self._set("source:" + channel, snapshot)
            self.connection.commit()
        except (OSError, sqlite3.Error):
            self.connection.rollback()
            raise SyncError("store_write_failed")
        return {"status": "ok", "changed": changed}
