"""Opt-in Signal sync scheduling. Importing this module starts nothing."""

import argparse
import concurrent.futures
import datetime
import hashlib
import json
import math
import os
import plistlib
import random
import signal
import sqlite3
import stat
import threading
import time
import urllib.parse
import uuid

from .cross_ca import address_mentions
from .signal_ca import CAReader, advance_ca, ca_state_changes, reconcile_ca
from .signal_contract import SyncError, encode_payload
from .signal_export import completed_after, prepare_reports
from .signal_outbox import SyncStore
from .signal_transport import (classify_response, load_sync_config,
                               send_payload)


SUPPORT = os.path.expanduser("~/Library/Application Support/wxFomo LAN")
DEFAULT_STORE = os.path.join(SUPPORT, "signalhub-sync", "outbox.sqlite3")
DEFAULT_MESSAGES = os.path.join(SUPPORT, "messages.sqlite3")
DEFAULT_ANALYSIS = os.path.join(SUPPORT, "analysis.sqlite3")
DEFAULT_CONFIG = os.path.join(SUPPORT, "signalhub-sync", "config.json")
CA_INTERVAL = 10.0
REPORT_INTERVAL = 60.0
HEARTBEAT_INTERVAL = 60.0
RECONCILE_INTERVAL = 60.0
CA_BUDGET = 2.0
SEND_ERRORS = frozenset(("transport_error", "provider_unavailable", "sync_unconfigured",
                         "response_invalid", "rate_limited", "replay"))


def retry_delay(attempt, jitter):
    base = min(300, 5 * (2 ** min(max(attempt - 1, 0), 6)))
    return min(300, base + jitter)


def choose_kind(has_fresh_ca, has_report, consecutive_ca):
    if has_report and (not has_fresh_ca or consecutive_ca >= 3):
        return "report"
    if has_fresh_ca:
        return "ca_alert"
    return "report" if has_report else None


def _epoch(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value) if math.isfinite(value) else None
    if isinstance(value, str):
        try:
            parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
            return parsed.timestamp() if parsed.tzinfo is not None else None
        except (ValueError, OverflowError, OSError):
            return None
    return None


def _iso(value):
    if value is None:
        return None
    return datetime.datetime.fromtimestamp(
        value, datetime.timezone.utc
    ).isoformat().replace("+00:00", "Z")


def _decision(action, code, retry_after=None, scope="item"):
    return {"action": action, "code": code, "retry_after": retry_after,
            "scope": scope}


def _readonly(path):
    try:
        uri = "file:{}?mode=ro".format(urllib.parse.quote(os.path.abspath(path)))
        connection = sqlite3.connect(uri, uri=True, timeout=0.25)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA query_only=ON")
        return connection
    except (OSError, sqlite3.Error, TypeError, ValueError):
        raise SyncError("source_unavailable")


def _source_stat(path):
    try:
        value = os.stat(path, follow_symlinks=False)
        if (not stat.S_ISREG(value.st_mode) or value.st_nlink != 1
                or value.st_uid != os.getuid()):
            raise SyncError("source_unsafe")
        return value.st_dev, value.st_ino
    except SyncError:
        raise
    except (OSError, TypeError, ValueError):
        raise SyncError("source_unavailable")


def report_watermark(path):
    connection = _readonly(path)
    try:
        row = connection.execute(
            "SELECT COALESCE(MAX(r.analysis_id),0) "
            "FROM analysis_results r JOIN analysis_jobs j ON j.job_id=r.job_id "
            "WHERE j.state='succeeded'"
        ).fetchone()
        return int(row[0])
    except (sqlite3.Error, TypeError, ValueError, OverflowError):
        raise SyncError("source_unavailable")
    finally:
        connection.close()


def message_watermark(path):
    connection = _readonly(path)
    try:
        return int(connection.execute("SELECT COALESCE(MAX(id),0) FROM messages").fetchone()[0])
    except (sqlite3.Error, TypeError, ValueError, OverflowError):
        raise SyncError("source_unavailable")
    finally:
        connection.close()


def report_source_anchor(path, cursor):
    device, inode = _source_stat(path)
    connection = _readonly(path)
    try:
        maximum = int(connection.execute(
            "SELECT COALESCE(MAX(r.analysis_id),0) "
            "FROM analysis_results r JOIN analysis_jobs j ON j.job_id=r.job_id "
            "WHERE j.state='succeeded'"
        ).fetchone()[0])
        job_id = digest = None
        if cursor:
            row = connection.execute(
                "SELECT r.job_id,r.result_json FROM analysis_results r "
                "JOIN analysis_jobs j ON j.job_id=r.job_id "
                "WHERE j.state='succeeded' AND r.analysis_id=?", (cursor,)
            ).fetchone()
            if row is not None:
                job_id = row["job_id"]
                digest = hashlib.sha256(row["result_json"].encode("utf-8")).hexdigest()
            else:
                job_id, digest = "missing-anchor", "0" * 64
        return {"file_device": device, "file_inode": inode, "max_id": maximum,
                "cursor_id": cursor, "cursor_job_id": job_id,
                "cursor_digest": digest}
    except (sqlite3.Error, TypeError, ValueError, UnicodeError, OverflowError):
        raise SyncError("source_unavailable")
    finally:
        connection.close()


def message_source_anchor(path, cursor, previous=None):
    device, inode = _source_stat(path)
    connection = _readonly(path)
    try:
        tables = set(row[0] for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"))
        sequence = 0
        if "sqlite_sequence" in tables:
            row = connection.execute(
                "SELECT seq FROM sqlite_sequence WHERE name='messages'").fetchone()
            sequence = 0 if row is None else int(row[0])
        else:
            sequence = int(connection.execute(
                "SELECT COALESCE(MAX(id),0) FROM messages").fetchone()[0])
        anchor = None
        proof = None
        if cursor:
            anchor = connection.execute(
                "SELECT id,event_id,record_version FROM messages WHERE id=?", (cursor,)
            ).fetchone()
            old_event = previous.get("cursor_event_id") if isinstance(previous, dict) else None
            if anchor is None and old_event and "message_event_aliases" in tables:
                quarantined = False
                if "message_event_alias_quarantine" in tables:
                    quarantined = connection.execute(
                        "SELECT 1 FROM message_event_alias_quarantine "
                        "WHERE alias_event_id=? LIMIT 1", (old_event,)
                    ).fetchone() is not None
                if not quarantined:
                    anchor = connection.execute(
                        "SELECT m.id,m.event_id,m.record_version FROM message_event_aliases a "
                        "JOIN messages m ON m.id=a.message_id WHERE a.alias_event_id=?",
                        (old_event,),
                    ).fetchone()
                if anchor is not None:
                    aliases = [item[0] for item in connection.execute(
                        "SELECT alias_event_id FROM message_event_aliases WHERE message_id=? "
                        "ORDER BY alias_event_id", (anchor["id"],)).fetchall()]
                    proof = {
                        "previous": {"row_id": previous["cursor_row_id"],
                                     "event_id": previous["cursor_event_id"],
                                     "record_version": previous["cursor_record_version"]},
                        "current": {"row_id": anchor["id"], "event_id": anchor["event_id"],
                                    "record_version": anchor["record_version"]},
                        "canonical_aliases": aliases,
                    }
            if anchor is None:
                anchor = {"id": cursor, "event_id": "missing-anchor", "record_version": 1}
        snapshot = {
            "file_device": device, "file_inode": inode, "sqlite_sequence": sequence,
            "cursor_id": cursor, "cursor_row_id": None if anchor is None else anchor["id"],
            "cursor_event_id": None if anchor is None else anchor["event_id"],
            "cursor_record_version": None if anchor is None else anchor["record_version"],
        }
        return {"snapshot": snapshot, "merge_proofs": [] if proof is None else [proof]}
    except (sqlite3.Error, TypeError, ValueError, OverflowError):
        raise SyncError("source_unavailable")
    finally:
        connection.close()


def source_health(messages_path, analysis_path, now):
    def heartbeat(path, table):
        connection = _readonly(path)
        try:
            row = connection.execute(
                "SELECT heartbeat_at FROM {} WHERE singleton_id=1".format(table)
            ).fetchone()
            return None if row is None else _epoch(row[0])
        except (sqlite3.Error, TypeError, ValueError):
            return None
        finally:
            connection.close()
    result = {}
    for key, path, table, age in (
            ("listener", messages_path, "listener_state", 5),
            ("worker", analysis_path, "analysis_worker_state", 15)):
        try:
            value = heartbeat(path, table)
            result[key] = ("unknown" if value is None else
                           "online" if 0 <= now - value <= age else "offline")
        except SyncError:
            result[key] = "unknown"
    return result


class SyncService(object):
    """One bounded scheduler step; only its caller thread touches SyncStore."""

    def __init__(self, store, report_source, ca_source, transport, clock,
                 monotonic, random_delay, heartbeat_source=None,
                 anchor_source=None, device_id="local-device", store_id="local-store"):
        self.store = store
        self.report_source = report_source
        self.ca_source = ca_source
        self.transport = transport
        self.clock = clock
        self.monotonic = monotonic
        self.random_delay = random_delay
        self.heartbeat_source = heartbeat_source
        self.anchor_source = anchor_source
        self.device_id = device_id
        self.store_id = store_id
        self.report_executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        self.send_executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        self.report_future = None
        self.report_retry_cursor = None
        self.send_future = None
        self.send_context = None
        self.last_wall = None
        self.last_mono = None
        self.next_ca = None
        self.next_report = None
        self.next_reconcile = None
        self.next_heartbeat = None
        self.heartbeat_pending = False
        self.heartbeat_retry_mono = None
        self.heartbeat_yield_queue = False
        self.consecutive_ca = 0
        self.last_error = None
        self.last_ca_evaluated = None
        self.last_message_observed = None
        self.ca_detector = "unknown"
        self.reconcile_offset = 0
        self.next_quarantine_retry = None
        self.retry_mono = {}
        self.catchup_until_id = getattr(ca_source, "startup_row_id", None)
        if not isinstance(self.catchup_until_id, int):
            self.catchup_until_id = store.cursor("messages")

    def close(self):
        self.report_executor.shutdown(wait=True)
        self.send_executor.shutdown(wait=True)
        try:
            now, mono = float(self.clock()), float(self.monotonic())
            self._collect_report(now)
            self._collect_send(now, mono)
        except (SyncError, TypeError, ValueError, OverflowError):
            pass

    def _jitter(self):
        try:
            value = self.random_delay()
        except TypeError:
            value = self.random_delay
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return 0
        return max(0, min(300, value)) if math.isfinite(value) else 0

    def _record_channel_error(self, channel, cursor, code, now):
        self.last_error = code
        try:
            self.store.record_channel_error(channel, cursor, code, now)
        except SyncError:
            self.last_error = "store_write_failed"

    def _check_time(self, now, mono):
        if (not math.isfinite(now) or not math.isfinite(mono)
                or (self.last_wall is not None and now < self.last_wall)
                or (self.last_mono is not None and mono < self.last_mono)):
            raise SyncError("clock_invalid")
        status = self.store.status(now)
        deadline = status["globalRetryUntil"]
        if deadline is not None and deadline > now + 900:
            raise SyncError("clock_invalid")
        self.last_wall, self.last_mono = now, mono
        if self.next_ca is None:
            self.next_ca = mono
            self.next_report = mono
            self.next_reconcile = mono
            self.next_heartbeat = mono
            if deadline is not None and deadline > now:
                self.retry_mono["global"] = mono + (deadline - now)

    def _source_check(self, channel, now):
        if self.anchor_source is None:
            return
        previous = self.store.source_anchor(channel)
        try:
            value = self.anchor_source(channel, self.store.cursor(channel), previous)
        except TypeError:
            value = self.anchor_source(channel, self.store.cursor(channel))
        proofs = ()
        snapshot = value
        if isinstance(value, dict) and set(value) == {"snapshot", "merge_proofs"}:
            snapshot, proofs = value["snapshot"], value["merge_proofs"]
        self.store.check_source(channel, snapshot, now, merge_proofs=proofs)

    def _collect_report(self, now):
        if self.report_future is None or not self.report_future.done():
            return
        future, self.report_future = self.report_future, None
        retry_cursor, self.report_retry_cursor = self.report_retry_cursor, None
        try:
            items = future.result()
            if not isinstance(items, list) or len(items) > 10:
                raise SyncError("source_invalid")
            if retry_cursor is not None:
                matches = [item for item in items if isinstance(item, dict)
                           and item.get("cursor") == retry_cursor]
                if len(matches) != 1 or set(matches[0]) != {"cursor", "payload", "error_code"}:
                    raise SyncError("source_invalid")
                item = matches[0]
                if item["error_code"] is not None:
                    self.store.quarantine_source("reports", retry_cursor,
                                                 item["error_code"], now)
                    self.last_error = item["error_code"]
                    return
                if type(item["payload"]) is not bytes:
                    raise SyncError("source_invalid")
                self.store.enqueue_batch("reports", self.store.cursor("reports"),
                                         [item["payload"]], now)
                self.store.resolve_source_quarantine("reports", retry_cursor)
                if not self.store.source_quarantines("reports"):
                    self.store.clear_channel_error("reports")
                    if self.last_error is not None and self.last_error.startswith("source_"):
                        self.last_error = None
                return
            cursor = self.store.cursor("reports")
            payloads = []
            next_cursor = cursor
            quarantined = False
            for item in items:
                if (not isinstance(item, dict)
                        or set(item) != {"cursor", "payload", "error_code"}
                        or isinstance(item["cursor"], bool)
                        or not isinstance(item["cursor"], int)
                        or item["cursor"] <= next_cursor):
                    raise SyncError("source_invalid")
                if item["error_code"] is not None:
                    if not isinstance(item["error_code"], str):
                        raise SyncError("source_invalid")
                    self.store.quarantine_source("reports", item["cursor"],
                                                 item["error_code"], now)
                    self.last_error = item["error_code"]
                    quarantined = True
                else:
                    if type(item["payload"]) is not bytes:
                        raise SyncError("source_invalid")
                    payloads.append(item["payload"])
                next_cursor = item["cursor"]
            if next_cursor != cursor:
                self.store.enqueue_batch("reports", next_cursor, payloads, now)
            if not quarantined and not self.store.source_quarantines("reports"):
                self.store.clear_channel_error("reports")
                if self.last_error is not None and self.last_error.startswith("source_"):
                    self.last_error = None
        except SyncError as error:
            self._record_channel_error("reports", self.store.cursor("reports"),
                                       error.code, now)
        except Exception:
            self._record_channel_error("reports", self.store.cursor("reports"),
                                       "source_unavailable", now)

    def _schedule_report(self, now, mono):
        if self.report_future is not None or mono < self.next_report:
            return
        try:
            if "reports" in self.store.status(now)["channelPauses"]:
                return
            self._source_check("reports", now)
            cursor = self.store.cursor("reports")
            self.report_retry_cursor = None
            self.report_future = self.report_executor.submit(self.report_source, cursor)
            self.next_report = mono + REPORT_INTERVAL
        except SyncError as error:
            self.last_error = error.code
            self.next_report = mono + REPORT_INTERVAL

    def _schedule_report_retry(self, mono):
        if self.report_future is not None:
            return
        quarantines = sorted(self.store.source_quarantines("reports"),
                             key=lambda item: (item["at"], item["cursor"]))
        if (not quarantines or (self.next_quarantine_retry is not None
                                and mono < self.next_quarantine_retry)):
            return
        self.report_retry_cursor = quarantines[0]["cursor"]
        self.report_future = self.report_executor.submit(
            self.report_source, self.report_retry_cursor - 1)
        self.next_quarantine_retry = mono + 300

    @staticmethod
    def _mention_keys(row):
        keys = set()
        for mention in address_mentions(row.get("content")):
            if mention["network"] != "unknown":
                keys.add((mention["network"], mention["normalizedAddress"]))
        return keys

    @staticmethod
    def _valid_ca_row(row):
        return (isinstance(row, dict)
                and isinstance(row.get("row_id"), int)
                and not isinstance(row.get("row_id"), bool)
                and row["row_id"] > 0
                and isinstance(row.get("event_id"), str) and bool(row["event_id"])
                and isinstance(row.get("record_version"), int)
                and not isinstance(row.get("record_version"), bool)
                and row["record_version"] > 0
                and isinstance(row.get("content"), str))

    def _reconcile_rows(self, state, now, mono):
        if mono < self.next_reconcile:
            return state
        rows = sorted(state["mentions"].values(),
                      key=lambda item: (item.get("row_id", 0), item.get("event_id", "")))
        if rows:
            start = self.reconcile_offset % len(rows)
            selected = (rows[start:] + rows[:start])[:500]
            self.reconcile_offset = (start + len(selected)) % len(rows)
            current = self.ca_source.current_rows([row["event_id"] for row in selected])
            state = reconcile_ca(state, current, now)
        self.next_reconcile = mono + RECONCILE_INTERVAL
        return state

    def _ca_tick(self, now, mono):
        if mono < self.next_ca:
            return
        self.next_ca = mono + CA_INTERVAL
        old_state = self.store.ca_state()
        try:
            if "messages" in self.store.status(now)["channelPauses"]:
                self.ca_detector = "unknown"
                return
            self._source_check("messages", now)
            reconciliation_due = mono >= self.next_reconcile
            state = self._reconcile_rows(old_state, now, mono)
            if self.monotonic() - mono >= CA_BUDGET:
                raise SyncError("ca_budget_exceeded")
            cursor = self.store.cursor("messages")
            retry_cursor = None
            retry_row = None
            quarantined_this_tick = False
            quarantines = sorted(self.store.source_quarantines("messages"),
                                 key=lambda item: (item["at"], item["cursor"]))
            if reconciliation_due and quarantines:
                retry_cursor = quarantines[0]["cursor"]
                retried = self.ca_source.after_row_id(retry_cursor - 1, 1)
                if (isinstance(retried, list) and len(retried) == 1
                        and retried[0].get("row_id") == retry_cursor
                        and self._valid_ca_row(retried[0])):
                    retry_row = retried[0]
                else:
                    self.store.quarantine_source("messages", retry_cursor,
                                                 "source_invalid", now)
                    quarantined_this_tick = True
            fetched = self.ca_source.after_row_id(cursor, 499 if retry_row else 500)
            if not isinstance(fetched, list) or len(fetched) > (499 if retry_row else 500):
                raise SyncError("source_invalid")
            incoming = []
            for row in fetched:
                if self._valid_ca_row(row):
                    incoming.append(row)
                elif isinstance(row, dict) and isinstance(row.get("row_id"), int):
                    self.store.quarantine_source("messages", row["row_id"],
                                                 "source_invalid", now)
                    quarantined_this_tick = True
                else:
                    raise SyncError("source_invalid")
            if retry_row is not None:
                incoming.insert(0, retry_row)
            incoming_keys = set()
            for row in incoming:
                incoming_keys.update(self._mention_keys(row))
            relevant = []
            for row in state["mentions"].values():
                if any((item.get("network"), item.get("normalized_address")) in incoming_keys
                       for item in row.get("mentions", [])):
                    relevant.append(row["event_id"])
            requested = list(dict.fromkeys(
                [row.get("event_id") for row in incoming if row.get("event_id")] + relevant
            ))
            if len(requested) > 500:
                raise SyncError("candidate_recheck_too_large")
            checked = self.ca_source.current_rows(requested) if requested else []
            if self.monotonic() - mono >= CA_BUDGET:
                raise SyncError("ca_budget_exceeded")
            state = reconcile_ca(state, checked, now)
            incoming_ids = set(row.get("event_id") for row in incoming)
            current_incoming = []
            seen_rows = set()
            for row in checked:
                if (row.get("source_status", "current") == "current"
                        and row.get("requested_event_id", row.get("event_id")) in incoming_ids
                        and row.get("row_id") not in seen_rows):
                    seen_rows.add(row.get("row_id"))
                    current_incoming.append(row)
            result = advance_ca(state, current_incoming, now, self.catchup_until_id,
                                self.device_id, self.store_id)
            if self.monotonic() - mono >= CA_BUDGET:
                raise SyncError("ca_budget_exceeded")
            next_cursor = cursor
            if fetched:
                next_cursor = max(next_cursor, max(row["row_id"] for row in fetched
                                                   if isinstance(row, dict)
                                                   and isinstance(row.get("row_id"), int)))
            payloads = [encode_payload(item) for item in result["alerts"]]
            changes = ca_state_changes(old_state, result["state"])
            self.store.enqueue_batch("messages", next_cursor, payloads, now, changes)
            observed = [_epoch(row.get("observed_at")) for row in incoming]
            observed = [value for value in observed if value is not None and value <= now]
            if observed:
                self.last_message_observed = max(
                    [self.last_message_observed] + observed
                    if self.last_message_observed is not None else observed
                )
            self.last_ca_evaluated = now
            self.ca_detector = "online"
            if retry_row is not None:
                self.store.resolve_source_quarantine("messages", retry_cursor)
            if not self.store.source_quarantines("messages"):
                self.store.clear_channel_error("messages")
            elif quarantined_this_tick:
                self.last_error = "source_invalid"
                self.ca_detector = "unknown"
        except SyncError as error:
            self._record_channel_error("messages", self.store.cursor("messages"),
                                       error.code, now)
            self.ca_detector = ("unknown" if error.code.startswith("source_")
                                or error.code in ("ca_budget_exceeded", "outbox_full",
                                                  "ca_index_full") else "offline")

    def _heartbeat(self, now):
        store_status = self.store.status(now)
        health = {"listener": "unknown", "worker": "unknown"}
        if self.heartbeat_source is not None:
            try:
                supplied = self.heartbeat_source(now)
                if isinstance(supplied, dict):
                    health.update({key: supplied[key] for key in ("listener", "worker")
                                   if supplied.get(key) in ("online", "offline", "unknown")})
            except Exception:
                pass
        detector = self.ca_detector
        if detector != "unknown":
            detector = ("online" if self.last_ca_evaluated is not None
                        and now - self.last_ca_evaluated <= 30 else "offline")
        error = self.last_error
        if not isinstance(error, str) or not error.replace("_", "a").isalnum():
            error = None
        payload = {"schemaVersion": 2, "type": "heartbeat", "status": {
            "listener": health["listener"], "worker": health["worker"],
            "pendingReports": store_status["pendingReports"],
            "lastError": error, "caDetector": detector,
            "pendingAlerts": store_status["pendingAlerts"],
            "lastMessageObservedAt": _iso(self.last_message_observed),
            "lastCaEvaluatedAt": _iso(self.last_ca_evaluated),
        }}
        return encode_payload(payload)

    def _row_due(self, row, now, mono):
        deadline = row["next_attempt_at"]
        if deadline is None:
            return True
        key = (row["kind"], row["id"], row["revision"])
        if key not in self.retry_mono:
            remaining = deadline - now
            if remaining > 900:
                raise SyncError("clock_invalid")
            self.retry_mono[key] = mono + max(0, remaining)
        return mono >= self.retry_mono[key]

    def _fresh_ca(self, row, now):
        try:
            alert = json.loads(row["body"])["alert"]
        except (ValueError, TypeError, KeyError):
            return False
        triggered = _epoch(alert.get("triggeredAt"))
        expires = _epoch(alert.get("expiresAt"))
        return (alert.get("status") == "active" and not alert.get("catchup")
                and triggered is not None and expires is not None
                and 0 <= now - triggered <= 60 and now < expires)

    def _blocked(self, status, now, mono):
        if status["globalPause"] is not None or status["schemaPause"] is not None:
            return True
        deadline = status["globalRetryUntil"]
        if "global" in self.retry_mono:
            return mono < self.retry_mono["global"]
        if deadline is None or deadline <= now:
            return False
        if deadline - now > 900:
            raise SyncError("clock_invalid")
        self.retry_mono["global"] = mono + (deadline - now)
        return mono < self.retry_mono["global"]

    def _dispatch(self, now, mono):
        if self.send_future is not None:
            return
        status = self.store.status(now)
        if self._blocked(status, now, mono):
            return
        pending = [row for row in self.store.pending() if self._row_due(row, now, mono)]
        reports = [row for row in pending if row["kind"] == "report"]
        fresh = [row for row in pending if row["kind"] == "ca_alert"
                 and self._fresh_ca(row, now)]
        fresh.sort(key=lambda row: (row["created_at"], row["revision"]), reverse=True)
        old = [row for row in pending if row["kind"] == "ca_alert"
               and row not in fresh]
        selected = None
        kind = choose_kind(bool(fresh), bool(reports), self.consecutive_ca)
        if kind == "ca_alert":
            selected = fresh[0]
        elif kind == "report":
            selected = reports[0]
        elif old:
            selected = old[0]
        heartbeat_due = (self.heartbeat_pending and
                         (self.heartbeat_retry_mono is None
                          or mono >= self.heartbeat_retry_mono))
        if heartbeat_due and not (self.heartbeat_yield_queue and selected is not None):
            self.heartbeat_yield_queue = False
            body = self._heartbeat(now)
            self.send_context = {"heartbeat": True, "body": body}
            self.send_future = self.send_executor.submit(self.transport, body)
            return
        if selected is None:
            return
        self.consecutive_ca = self.consecutive_ca + 1 if selected["kind"] == "ca_alert" else 0
        self.heartbeat_yield_queue = False
        self.send_context = {"heartbeat": False, "row": selected,
                             "body": selected["body"]}
        self.send_future = self.send_executor.submit(self.transport, selected["body"])

    def _collect_send(self, now, mono):
        if self.send_future is None or not self.send_future.done():
            return
        future, context = self.send_future, self.send_context
        self.send_future = self.send_context = None
        try:
            expected = json.loads(context["body"])
        except (UnicodeError, ValueError, TypeError, RecursionError):
            decision = (_decision("retry", "transport_error") if context["heartbeat"]
                        else _decision("quarantine", "payload_invalid"))
        else:
            try:
                status, headers, response = future.result()
                decision = classify_response(expected, status, headers, response, now)
            except SyncError as error:
                decision = (_decision("quarantine", error.code)
                            if not context["heartbeat"] and error.code in (
                                "payload_invalid", "payload_sensitive")
                            else _decision("retry", "transport_error"))
            except Exception:
                decision = _decision("retry", "transport_error")
        if decision["action"] == "retry" and decision["retry_after"] is None:
            attempt = 1 if context["heartbeat"] else context["row"]["attempts"] + 1
            decision["retry_after"] = retry_delay(attempt, self._jitter())
        if context["heartbeat"]:
            if decision["scope"] == "global" and decision["action"] in ("retry", "pause"):
                self.store.apply_global_response(decision, now)
                if decision["action"] == "retry":
                    self.retry_mono["global"] = mono + decision["retry_after"]
            if decision["action"] == "ack":
                self.heartbeat_pending = False
                self.heartbeat_retry_mono = None
                self.heartbeat_yield_queue = False
                if self.last_error in SEND_ERRORS:
                    self.last_error = None
            else:
                self.last_error = decision["code"]
                self.heartbeat_yield_queue = True
                if decision["action"] == "retry" and decision["scope"] != "global":
                    self.heartbeat_retry_mono = mono + decision["retry_after"]
            return
        row = context["row"]
        self.store.apply_response(row["kind"], row["id"], row["revision"],
                                  decision, now)
        if decision["action"] == "retry":
            key = (row["kind"], row["id"], row["revision"])
            self.retry_mono[key] = mono + decision["retry_after"]
        if decision["action"] == "ack":
            if self.last_error in SEND_ERRORS:
                self.last_error = None
        else:
            self.last_error = decision["code"]

    def step(self):
        now, mono = float(self.clock()), float(self.monotonic())
        self._check_time(now, mono)
        self._collect_report(now)
        self._schedule_report_retry(mono)
        self._collect_send(now, mono)
        self._ca_tick(now, mono)
        self._schedule_report(now, mono)
        if mono >= self.next_heartbeat:
            self.heartbeat_pending = True
            self.next_heartbeat = mono + HEARTBEAT_INTERVAL
        self._dispatch(now, mono)
        status = self.store.status(now)
        detector = self.ca_detector
        if detector != "unknown" and (self.last_ca_evaluated is None
                                      or now - self.last_ca_evaluated > 30):
            detector = "offline"
        return {
            "pendingReports": status["pendingReports"],
            "pendingAlerts": status["pendingAlerts"],
            "lastError": self.last_error,
            "caDetector": detector,
            "lastMessageObservedAt": _iso(self.last_message_observed),
            "lastCaEvaluatedAt": _iso(self.last_ca_evaluated),
            "reportPreparing": self.report_future is not None,
            "sending": self.send_future is not None,
        }


def _uuid(value):
    try:
        return str(uuid.UUID(value))
    except (AttributeError, TypeError, ValueError):
        raise argparse.ArgumentTypeError("must be a UUID")


def _parser():
    parser = argparse.ArgumentParser(description="Opt-in wxFomo Signal synchronization.")
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--dry-run", action="store_true")
    modes.add_argument("--status", action="store_true")
    modes.add_argument("--initialize", action="store_true")
    modes.add_argument("--run", action="store_true")
    modes.add_argument("--render-launch-agent", metavar="PATH")
    parser.add_argument("--store", default=DEFAULT_STORE, metavar="PATH")
    parser.add_argument("--messages", default=DEFAULT_MESSAGES, metavar="PATH")
    parser.add_argument("--analysis", default=DEFAULT_ANALYSIS, metavar="PATH")
    parser.add_argument("--config", default=DEFAULT_CONFIG, metavar="PATH")
    parser.add_argument("--store-id", type=_uuid, metavar="UUID")
    parser.add_argument("--once", action="store_true", help=argparse.SUPPRESS)
    return parser


def _absolute(value):
    return isinstance(value, str) and os.path.isabs(value)


def _render(options):
    paths = (options.render_launch_agent, options.store, options.messages,
             options.analysis, options.config)
    if options.store_id is None or not all(_absolute(value) for value in paths):
        raise SyncError("arguments_invalid")
    entry = os.path.abspath(os.path.join(os.path.dirname(__file__), "..",
                                         "wxfomo-signal-sync.py"))
    arguments = [os.path.abspath(os.fspath(os.sys.executable)), entry, "--run",
                 "--store", options.store, "--messages", options.messages,
                 "--analysis", options.analysis, "--config", options.config,
                 "--store-id", options.store_id]
    value = {
        "Label": "com.wxfomo.signal-sync",
        "ProgramArguments": arguments,
        "RunAtLoad": False,
        "KeepAlive": False,
        "ProcessType": "Background",
    }
    try:
        with open(options.render_launch_agent, "xb") as stream:
            plistlib.dump(value, stream, sort_keys=True)
    except (OSError, TypeError, ValueError):
        raise SyncError("render_failed")


def _initialize(options):
    if options.store_id is None:
        raise SyncError("arguments_invalid")
    report_cursor = report_watermark(options.analysis)
    message_cursor = message_watermark(options.messages)
    completed_after(options.analysis, report_cursor, 1)
    CAReader(options.messages).after_row_id(message_cursor, 1)
    reports = report_source_anchor(options.analysis, report_cursor)
    messages = message_source_anchor(options.messages, message_cursor)
    store = SyncStore(options.store)
    try:
        now = time.time()
        store.initialize(report_cursor, message_cursor, now, store_id=options.store_id)
        store.check_source("reports", reports, now)
        store.check_source("messages", messages["snapshot"], now,
                           merge_proofs=messages["merge_proofs"])
        return {"mode": "initialized", "network": False,
                "reportCursor": report_cursor, "messageCursor": message_cursor}
    finally:
        store.close()


def _candidate_counts(options):
    if not os.path.exists(options.store):
        raise SyncError("store_uninitialized")
    store = SyncStore(options.store)
    try:
        report_cursor = store.cursor("reports")
        message_cursor = store.cursor("messages")
        reports = _readonly(options.analysis)
        messages = _readonly(options.messages)
        try:
            report_count = int(reports.execute(
                "SELECT COUNT(*) FROM analysis_results r JOIN analysis_jobs j "
                "ON j.job_id=r.job_id WHERE j.state='succeeded' AND r.analysis_id>?",
                (report_cursor,)).fetchone()[0])
            message_count = int(messages.execute(
                "SELECT COUNT(*) FROM messages WHERE id>?", (message_cursor,)
            ).fetchone()[0])
        except (sqlite3.Error, TypeError, ValueError, OverflowError):
            raise SyncError("source_unavailable")
        finally:
            reports.close()
            messages.close()
        return {"mode": "dry_run", "network": False,
                "reportCandidates": report_count, "messageCandidates": message_count,
                "reportBatchLimit": 10, "messageBatchLimit": 500}
    finally:
        store.close()


def _run(options):
    if options.store_id is None or not os.path.exists(options.store):
        raise SyncError("arguments_invalid")
    config = load_sync_config(options.config)
    store = SyncStore(options.store)
    try:
        identity = store.identity()
        if identity is None or identity["store_id"] != options.store_id:
            raise SyncError("identity_mismatch")
        store.bind_identity(options.store_id, config.device_id)
        reader = CAReader(options.messages)
        reader.startup_row_id = message_watermark(options.messages)
    except Exception:
        store.close()
        raise
    report_source = lambda cursor: prepare_reports(
        options.analysis, options.messages, cursor, config.device_id, options.store_id)
    transport = lambda body: send_payload(config, body)
    def anchors(channel, cursor, previous):
        if channel == "reports":
            return report_source_anchor(options.analysis, cursor)
        return message_source_anchor(options.messages, cursor, previous)
    health = lambda now: source_health(options.messages, options.analysis, now)
    service = SyncService(store, report_source, reader, transport, time.time,
                          time.monotonic, lambda: random.uniform(0, 1),
                          heartbeat_source=health, anchor_source=anchors,
                          device_id=config.device_id, store_id=options.store_id)
    stopping = threading.Event()
    old_handlers = {}
    try:
        if not options.once:
            for number in (signal.SIGINT, signal.SIGTERM):
                old_handlers[number] = signal.getsignal(number)
                signal.signal(number, lambda unused_number, unused_frame: stopping.set())
        last = None
        while not stopping.is_set():
            last = service.step()
            if options.once:
                break
            stopping.wait(0.25)
        return last
    finally:
        for number, handler in old_handlers.items():
            signal.signal(number, handler)
        service.close()
        store.close()


def main(argv=None):
    options = _parser().parse_args(argv)
    try:
        if options.render_launch_agent:
            _render(options)
            return 0
        if options.dry_run:
            print(json.dumps(_candidate_counts(options), sort_keys=True,
                             separators=(",", ":")))
            return 0
        if options.status:
            if not os.path.exists(options.store):
                raise SyncError("store_uninitialized")
            store = SyncStore(options.store)
            try:
                print(json.dumps(store.status(time.time()), sort_keys=True,
                                 separators=(",", ":")))
            finally:
                store.close()
            return 0
        if options.initialize:
            print(json.dumps(_initialize(options), sort_keys=True,
                             separators=(",", ":")))
            return 0
        if options.run:
            result = _run(options)
            if options.once:
                print(json.dumps(result, sort_keys=True, separators=(",", ":")))
            return 0
        raise SyncError("arguments_invalid")
    except SyncError as error:
        print(json.dumps({"error_code": error.code}, separators=(",", ":")),
              file=os.sys.stderr)
        return 1
