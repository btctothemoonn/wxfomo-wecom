"""Pure rolling cross-group CA detection and read-only source access."""

import copy
import datetime
import hashlib
import json
import math
import os
import sqlite3
import unicodedata
import urllib.parse

from .cross_ca import address_mentions
from .minimax import _EVM_ADDRESS
from .relay import attribute_message, load_boundary
from .signal_contract import SyncError


WINDOW_SECONDS = 3600
COOLDOWN_SECONDS = 1800
MAX_BATCH = 500
KNOWN_NETWORKS = frozenset((
    "base", "bsc", "ethereum", "arbitrum", "polygon", "optimism",
    "avalanche", "solana",
))


def _timestamp(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    value = float(value)
    return value if math.isfinite(value) else None


def _iso(value):
    return datetime.datetime.fromtimestamp(
        value, datetime.timezone.utc
    ).isoformat().replace("+00:00", "Z")


def _bucket_key(network, normalized, group=""):
    scope = group if network == "unknown" else ""
    return json.dumps([network, normalized, scope], ensure_ascii=False,
                      separators=(",", ":"))


def _statement_digest(message):
    content = message.get("content")
    if not isinstance(content, str):
        content = ""
    canonical = " ".join(unicodedata.normalize("NFC", content).split())
    canonical = _EVM_ADDRESS.sub(lambda match: match.group(0).lower(), canonical)
    sender = message.get("sender")
    identity = sender.strip() if isinstance(sender, str) else ""
    if not identity:
        identity = "event:" + str(message.get("event_id") or "")
    return hashlib.sha256((identity + "\0" + canonical).encode("utf-8")).hexdigest()


def _time_status(observed_at, now):
    if observed_at is None:
        return "unknown"
    if observed_at > now:
        return "future"
    return "valid"


def _project_row(message, now):
    row_id = message.get("row_id")
    version = message.get("record_version")
    event_id = message.get("event_id")
    if (isinstance(row_id, bool) or not isinstance(row_id, int) or row_id < 1
            or isinstance(version, bool) or not isinstance(version, int) or version < 1
            or not isinstance(event_id, str) or not event_id):
        return None
    group = message.get("group")
    group = group if isinstance(group, str) and group else "未知群"
    observed_at = _timestamp(message.get("observed_at"))
    inserted_at = _timestamp(message.get("inserted_at"))
    digest = _statement_digest(message)
    mentions = []
    for item in address_mentions(message.get("content")):
        mentions.append({
            "address": item["address"],
            "normalized_address": item["normalizedAddress"],
            "network": item["network"],
            "statement_digest": digest,
        })
    return {
        "row_id": row_id,
        "event_id": event_id,
        "record_version": version,
        "group": group,
        "observed_at": observed_at,
        "inserted_at": inserted_at,
        "time_status": _time_status(observed_at, now),
        "mentions": mentions,
    }


def _state(value):
    value = copy.deepcopy(value) if isinstance(value, dict) else {}
    mentions = value.get("mentions")
    episodes = value.get("episodes")
    meta = value.get("meta")
    value["mentions"] = mentions if isinstance(mentions, dict) else {}
    value["episodes"] = episodes if isinstance(episodes, dict) else {}
    value["meta"] = meta if isinstance(meta, dict) else {}
    meta = value["meta"]
    if isinstance(meta.get("next_episode"), bool) or not isinstance(meta.get("next_episode"), int):
        meta["next_episode"] = 1
    if isinstance(meta.get("skipped_expired"), bool) or not isinstance(meta.get("skipped_expired"), int):
        meta["skipped_expired"] = 0
    return value


def _refresh_rows(state, now):
    kept = {}
    for key, row in state["mentions"].items():
        if not isinstance(row, dict):
            continue
        observed = _timestamp(row.get("observed_at"))
        inserted = _timestamp(row.get("inserted_at"))
        if row.get("time_status") not in ("valid", "unknown", "future"):
            row["time_status"] = _time_status(observed, now)
        expiry_basis = (observed if row["time_status"] == "valid" else inserted)
        if expiry_basis is not None and expiry_basis <= now - WINDOW_SECONDS:
            continue
        kept[key] = row
    state["mentions"] = kept
    state["meta"]["unknown_time_count"] = sum(
        row.get("time_status") == "unknown" for row in kept.values()
    )
    state["meta"]["future_time_count"] = sum(
        row.get("time_status") == "future" for row in kept.values()
    )


def _bucket_mentions(state, now):
    buckets = {}
    for row in state["mentions"].values():
        observed = _timestamp(row.get("observed_at"))
        if row.get("time_status") != "valid" or not (now - WINDOW_SECONDS < observed <= now):
            continue
        for mention in row.get("mentions", []):
            network = mention.get("network")
            normalized = mention.get("normalized_address")
            if not isinstance(network, str) or not isinstance(normalized, str):
                continue
            key = _bucket_key(network, normalized, row.get("group") or "未知群")
            buckets.setdefault(key, []).append(dict(
                row_id=row.get("row_id"), event_id=row.get("event_id"),
                group=row.get("group") or "未知群", observed_at=observed,
                address=mention.get("address"), network=network,
                normalized_address=normalized,
                statement_digest=mention.get("statement_digest"),
                catchup=bool(row.get("catchup")),
            ))
    return buckets


def qualifying_expiry(mentions, now):
    latest_by_group = {}
    for item in mentions:
        if now - WINDOW_SECONDS < item["observed_at"] <= now:
            group = item["group"]
            latest_by_group[group] = max(latest_by_group.get(group, 0),
                                         item["observed_at"])
    if len(latest_by_group) < 2:
        return None
    return sorted(latest_by_group.values(), reverse=True)[1] + WINDOW_SECONDS


def _snapshot(items, now):
    by_event = {}
    for item in sorted(items, key=lambda value: (value["row_id"], value["event_id"])):
        by_event.setdefault(item["event_id"], item)
    items = list(by_event.values())
    groups = sorted(set(item["group"] for item in items))
    statements = set(item["statement_digest"] for item in items)
    expiry = qualifying_expiry(items, now)
    if expiry is None:
        return None
    first = min(items, key=lambda item: (item["row_id"], item["event_id"]))
    return {
        "address": first["address"], "network": first["network"],
        "groups": groups, "groupCount": len(groups),
        "mentionCount": len(items), "uniqueStatementCount": len(statements),
        "duplicateCount": len(items) - len(statements),
        "firstSeenAt": _iso(min(item["observed_at"] for item in items)),
        "lastSeenAt": _iso(max(item["observed_at"] for item in items)),
        "expiresAt": _iso(expiry),
        "catchup": any(item["catchup"] for item in items),
    }


def _payload(alert):
    return {"schemaVersion": 2, "type": "ca_alert", "alert": alert}


def _evaluate(state, now, device_id, store_id):
    alerts = []
    buckets = _bucket_mentions(state, now)
    keys = set(buckets) | set(state["episodes"])
    for key in sorted(keys):
        episode = state["episodes"].get(key)
        snapshot = _snapshot(buckets.get(key, []), now)
        if snapshot is not None and snapshot["network"] not in KNOWN_NETWORKS:
            snapshot = None
        if snapshot is None:
            if isinstance(episode, dict) and episode.get("status") == "active":
                alert = copy.deepcopy(episode["last_valid_alert"])
                alert.update(revision=episode["revision"] + 1, evaluatedAt=_iso(now),
                             status="expired")
                episode["revision"] = alert["revision"]
                episode["status"] = "expired"
                alerts.append(_payload(alert))
            continue
        material = {name: snapshot[name] for name in (
            "groups", "groupCount", "mentionCount", "uniqueStatementCount",
            "duplicateCount", "firstSeenAt", "lastSeenAt", "expiresAt",
        )}
        if not isinstance(episode, dict) or episode.get("status") != "active":
            sequence = state["meta"]["next_episode"]
            state["meta"]["next_episode"] = sequence + 1
            catchup = snapshot["catchup"]
            cooldown_until = now + COOLDOWN_SECONDS
            prior_cooldown = episode.get("cooldown_until", 0) if isinstance(episode, dict) else 0
            notification = 0 if catchup or now < prior_cooldown else 1
            alert = dict(
                id="wecom-ca:{}:{}:{}".format(device_id, store_id, sequence),
                revision=1, address=snapshot["address"], network=snapshot["network"],
                groups=snapshot["groups"], groupCount=snapshot["groupCount"],
                mentionCount=snapshot["mentionCount"],
                uniqueStatementCount=snapshot["uniqueStatementCount"],
                duplicateCount=snapshot["duplicateCount"],
                firstSeenAt=snapshot["firstSeenAt"], lastSeenAt=snapshot["lastSeenAt"],
                triggeredAt=_iso(now), evaluatedAt=_iso(now), expiresAt=snapshot["expiresAt"],
                windowSeconds=WINDOW_SECONDS, thresholdGroups=2, status="active",
                notificationVersion=notification, catchup=catchup,
            )
            state["episodes"][key] = {
                "sequence": sequence, "revision": 1, "triggered_at": now,
                "address": snapshot["address"], "last_valid_alert": copy.deepcopy(alert),
                "cooldown_until": cooldown_until, "catchup": catchup,
                "notification_version": notification, "status": "active",
            }
            alerts.append(_payload(alert))
            continue
        previous = episode["last_valid_alert"]
        previous_material = {name: previous[name] for name in material}
        if material == previous_material:
            continue
        alert = copy.deepcopy(previous)
        alert.update(material)
        alert.update(revision=episode["revision"] + 1, evaluatedAt=_iso(now), status="active")
        episode["revision"] = alert["revision"]
        episode["last_valid_alert"] = copy.deepcopy(alert)
        alerts.append(_payload(alert))
    return alerts


def advance_ca(state, messages, now, catchup_until_id, device_id, store_id):
    """Project one source batch and derive only materially changed alert revisions."""
    now = _timestamp(now)
    if now is None:
        raise SyncError("ca_time_invalid")
    result = _state(state)
    _refresh_rows(result, now)
    last_row_id = 0
    skipped = 0
    for message in messages:
        if not isinstance(message, dict):
            raise SyncError("ca_row_invalid")
        row = _project_row(message, now)
        raw_id = message.get("row_id") if isinstance(message, dict) else None
        if isinstance(raw_id, int) and not isinstance(raw_id, bool):
            last_row_id = max(last_row_id, raw_id)
        if row is None:
            raise SyncError("ca_row_invalid")
        expired_catchup = (row["row_id"] <= catchup_until_id
                           and row["observed_at"] is not None
                           and row["observed_at"] <= now - WINDOW_SECONDS)
        if expired_catchup:
            skipped += int(bool(row["mentions"]))
            continue
        row["catchup"] = (row["row_id"] <= catchup_until_id
                          or (row["inserted_at"] is not None
                              and now - row["inserted_at"] > 60))
        for old_key, old in list(result["mentions"].items()):
            if old.get("row_id") == row["row_id"] or old.get("event_id") == row["event_id"]:
                del result["mentions"][old_key]
        result["mentions"]["row:{}".format(row["row_id"])] = row
    result["meta"]["skipped_expired"] += skipped
    _refresh_rows(result, now)
    alerts = _evaluate(result, now, device_id, store_id)
    return {"state": result, "alerts": alerts, "last_row_id": last_row_id,
            "skipped_expired": skipped}


def reconcile_ca(state, source_rows, now):
    """Apply an explicit source re-read; source failure must be raised by CAReader."""
    now = _timestamp(now)
    if now is None:
        raise SyncError("ca_time_invalid")
    result = _state(state)
    for source in source_rows:
        if not isinstance(source, dict):
            continue
        requested = source.get("requested_event_id", source.get("event_id"))
        status = source.get("source_status", "current")
        if status in ("missing", "quarantined"):
            for key, row in list(result["mentions"].items()):
                if row.get("event_id") == requested:
                    del result["mentions"][key]
            continue
        row = _project_row(source, now)
        if row is None:
            continue
        carried_catchup = False
        keep_future_isolation = False
        for key, old in list(result["mentions"].items()):
            if (old.get("event_id") == requested or old.get("event_id") == row["event_id"]
                    or old.get("row_id") == row["row_id"]):
                carried_catchup = carried_catchup or bool(old.get("catchup"))
                keep_future_isolation = keep_future_isolation or (
                    old.get("time_status") == "future"
                    and old.get("observed_at") == row.get("observed_at")
                    and old.get("record_version") == row.get("record_version")
                )
                del result["mentions"][key]
        row["catchup"] = carried_catchup
        if keep_future_isolation:
            row["time_status"] = "future"
        result["mentions"]["row:{}".format(row["row_id"])] = row
    _refresh_rows(result, now)
    return result


def ca_state_changes(old, new):
    """Return the four typed operations accepted by the durable outbox."""
    before, after = _state(old), _state(new)
    changes = []
    for key in sorted(set(before["mentions"]) - set(after["mentions"])):
        changes.append({"op": "delete_mention", "key": key})
    for key in sorted(after["mentions"]):
        if before["mentions"].get(key) != after["mentions"][key]:
            changes.append({"op": "upsert_mention", "key": key,
                            "value": copy.deepcopy(after["mentions"][key])})
    for key in sorted(after["episodes"]):
        if before["episodes"].get(key) != after["episodes"][key]:
            changes.append({"op": "upsert_episode", "key": key,
                            "value": copy.deepcopy(after["episodes"][key])})
    for key in sorted(after["meta"]):
        if before["meta"].get(key) != after["meta"][key]:
            changes.append({"op": "set_ca_meta", "key": key,
                            "value": copy.deepcopy(after["meta"][key])})
    return changes


class CAReader(object):
    """Bounded, query-only access to the listener-owned message database."""

    _COLUMNS = frozenset((
        "id", "event_id", "record_version", "group_name", "sender_display_name",
        "content", "observed_at", "inserted_at",
    ))

    def __init__(self, path):
        self.path = os.fspath(path)
        self.relay_boundary = load_boundary(self.path)

    def _open(self):
        try:
            connection = sqlite3.connect(
                "file:{}?mode=ro".format(urllib.parse.quote(os.path.abspath(self.path))),
                uri=True, timeout=0.25,
            )
            connection.row_factory = sqlite3.Row
            connection.execute("PRAGMA query_only=ON")
            columns = set(row[1] for row in connection.execute("PRAGMA table_info(messages)"))
            if not self._COLUMNS.issubset(columns):
                connection.close()
                raise SyncError("source_schema_incompatible")
            return connection
        except SyncError:
            raise
        except (OSError, sqlite3.Error):
            raise SyncError("source_unavailable")

    def _dto(self, row):
        item = {"sender": row["sender_display_name"] or "", "content": row["content"]}
        item = attribute_message(item, row["id"], self.relay_boundary, "sender")
        return {
            "row_id": row["id"], "event_id": row["event_id"],
            "record_version": row["record_version"], "group": row["group_name"],
            "sender": item["sender"], "content": item["content"],
            "observed_at": row["observed_at"], "inserted_at": row["inserted_at"],
        }

    @staticmethod
    def _limit(limit):
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= MAX_BATCH:
            raise SyncError("source_query_invalid")
        return limit

    def after_row_id(self, cursor, limit):
        self._limit(limit)
        if isinstance(cursor, bool) or not isinstance(cursor, int) or cursor < 0:
            raise SyncError("source_query_invalid")
        connection = self._open()
        try:
            rows = connection.execute(
                "SELECT id,event_id,record_version,group_name,sender_display_name,"
                "content,observed_at,inserted_at FROM messages WHERE id>? ORDER BY id LIMIT ?",
                (cursor, limit),
            ).fetchall()
            return [self._dto(row) for row in rows]
        except sqlite3.Error:
            raise SyncError("source_unavailable")
        finally:
            connection.close()

    def current_rows(self, ids):
        if not isinstance(ids, (list, tuple)) or len(ids) > MAX_BATCH or any(
                not isinstance(item, str) or not item for item in ids):
            raise SyncError("source_query_invalid")
        unique = list(dict.fromkeys(ids))
        if not unique:
            return []
        connection = self._open()
        try:
            placeholders = ",".join("?" for _ in unique)
            exact = connection.execute(
                "SELECT id,event_id,record_version,group_name,sender_display_name,"
                "content,observed_at,inserted_at FROM messages WHERE event_id IN ({})".format(placeholders),
                unique,
            ).fetchall()
            exact_by_id = {row["event_id"]: row for row in exact}
            tables = set(row[0] for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ))
            aliases = {}
            quarantined = set()
            if "message_event_aliases" in tables:
                rows = connection.execute(
                    "SELECT a.alias_event_id,m.id,m.event_id,m.record_version,m.group_name,"
                    "m.sender_display_name,m.content,m.observed_at,m.inserted_at "
                    "FROM message_event_aliases a JOIN messages m ON m.id=a.message_id "
                    "WHERE a.alias_event_id IN ({})".format(placeholders), unique,
                ).fetchall()
                aliases = {row["alias_event_id"]: row for row in rows}
            if "message_event_alias_quarantine" in tables:
                quarantined = set(row[0] for row in connection.execute(
                    "SELECT alias_event_id FROM message_event_alias_quarantine "
                    "WHERE alias_event_id IN ({})".format(placeholders), unique,
                ))
            result = []
            for requested in unique:
                row = exact_by_id.get(requested)
                status = "current"
                if row is None and requested in quarantined:
                    result.append({"event_id": requested, "requested_event_id": requested,
                                   "source_status": "quarantined"})
                    continue
                if row is None:
                    row = aliases.get(requested)
                if row is None:
                    result.append({"event_id": requested, "requested_event_id": requested,
                                   "source_status": "missing"})
                    continue
                item = self._dto(row)
                item.update(requested_event_id=requested, source_status=status)
                result.append(item)
            return result
        except sqlite3.Error:
            raise SyncError("source_unavailable")
        finally:
            connection.close()
