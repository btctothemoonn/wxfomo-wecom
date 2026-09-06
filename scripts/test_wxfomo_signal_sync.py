import json
import os
import pathlib
import plistlib
import sqlite3
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest import mock

from scripts.wxfomo_lan.signal_contract import SyncError, encode_payload


FIXTURES = pathlib.Path(__file__).parent / "fixtures" / "signalhub-v2-handoff-8f6df4f"


def fixture_body(name):
    return encode_payload(json.loads((FIXTURES / name).read_text(encoding="utf-8")))


def create_sources(root):
    messages = os.path.join(root, "messages.sqlite3")
    analysis = os.path.join(root, "analysis.sqlite3")
    db = sqlite3.connect(messages)
    db.executescript("""
      CREATE TABLE messages(
        id INTEGER PRIMARY KEY AUTOINCREMENT,event_id TEXT UNIQUE NOT NULL,
        record_version INTEGER NOT NULL,group_name TEXT NOT NULL,
        sender_display_name TEXT,content TEXT NOT NULL,observed_at REAL,inserted_at REAL);
      CREATE TABLE message_event_aliases(alias_event_id TEXT PRIMARY KEY,message_id INTEGER);
      CREATE TABLE listener_state(singleton_id INTEGER PRIMARY KEY,heartbeat_at REAL);
      INSERT INTO messages(event_id,record_version,group_name,sender_display_name,content,
                           observed_at,inserted_at)
        VALUES('event-1',1,'alpha','alice','hello',1000,1000);
      INSERT INTO listener_state VALUES(1,1000);
    """)
    db.commit(); db.close()
    db = sqlite3.connect(analysis)
    db.executescript("""
      CREATE TABLE analysis_jobs(
        job_id TEXT PRIMARY KEY,state TEXT,cadence TEXT,window_start REAL,
        window_end REAL,source_event_ids_json TEXT);
      CREATE TABLE analysis_results(
        analysis_id INTEGER PRIMARY KEY,job_id TEXT,result_json TEXT,model TEXT,
        created_at REAL);
      CREATE TABLE analysis_worker_state(singleton_id INTEGER PRIMARY KEY,heartbeat_at REAL);
      INSERT INTO analysis_jobs VALUES('job-1','succeeded','2h',0,1,'[]');
      INSERT INTO analysis_results VALUES(7,'job-1','{}','fixture',1000);
      INSERT INTO analysis_worker_state VALUES(1,990);
    """)
    db.commit(); db.close()
    os.chmod(messages, 0o600); os.chmod(analysis, 0o600)
    return messages, analysis


class SignalSyncCLITests(unittest.TestCase):
    def test_no_mode_never_starts_daemon_or_network(self):
        result = subprocess.run(
            [sys.executable, "scripts/wxfomo-signal-sync.py"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3,
            universal_newlines=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")

    def test_retry_and_fairness_kernels_match_the_approved_rules(self):
        from scripts.wxfomo_lan.signal_sync import choose_kind, retry_delay
        self.assertEqual([retry_delay(attempt, 3) for attempt in (0, 1, 2, 7, 99)],
                         [8, 8, 13, 300, 300])
        self.assertEqual(choose_kind(True, True, 0), "ca_alert")
        self.assertEqual(choose_kind(True, True, 3), "report")
        self.assertEqual(choose_kind(False, True, 0), "report")
        self.assertEqual(choose_kind(True, False, 99), "ca_alert")
        self.assertIsNone(choose_kind(False, False, 0))

    def test_render_only_writes_a_disabled_plist_with_absolute_arguments(self):
        with tempfile.TemporaryDirectory() as root:
            target = os.path.join(root, "com.wxfomo.signal-sync.plist")
            paths = {name: os.path.join(root, name) for name in
                     ("outbox.sqlite3", "messages.sqlite3", "analysis.sqlite3", "config.json")}
            result = subprocess.run([
                sys.executable, "scripts/wxfomo-signal-sync.py",
                "--render-launch-agent", target,
                "--store", paths["outbox.sqlite3"],
                "--messages", paths["messages.sqlite3"],
                "--analysis", paths["analysis.sqlite3"],
                "--config", paths["config.json"],
                "--store-id", "00000000-0000-4000-8000-000000000001",
            ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3,
                universal_newlines=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            value = plistlib.loads(pathlib.Path(target).read_bytes())
            self.assertFalse(value["RunAtLoad"])
            self.assertNotIn("launchctl", " ".join(value["ProgramArguments"]))
            self.assertTrue(all(os.path.isabs(item) for item in value["ProgramArguments"]
                                if "/" in item))

    def test_initialize_records_both_current_watermarks_and_strict_anchors(self):
        from scripts.wxfomo_lan.signal_outbox import SyncStore
        with tempfile.TemporaryDirectory() as root:
            messages, analysis = create_sources(root)
            store_path = os.path.join(root, "private", "outbox.sqlite3")
            result = subprocess.run([
                sys.executable, "scripts/wxfomo-signal-sync.py", "--initialize",
                "--store", store_path, "--messages", messages, "--analysis", analysis,
                "--store-id", "00000000-0000-4000-8000-000000000001",
            ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3,
                universal_newlines=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            store = SyncStore(store_path)
            self.addCleanup(store.close)
            self.assertEqual((store.cursor("reports"), store.cursor("messages")), (7, 1))
            self.assertEqual(store.identity()["store_id"],
                             "00000000-0000-4000-8000-000000000001")
            self.assertEqual(store.source_anchor("reports")["cursor_job_id"], "job-1")
            self.assertEqual(store.source_anchor("messages")["cursor_event_id"], "event-1")
            self.assertEqual(store.pending(), [])

    def test_status_and_dry_run_never_load_config_or_send(self):
        with tempfile.TemporaryDirectory() as root:
            messages, analysis = create_sources(root)
            store_path = os.path.join(root, "private", "outbox.sqlite3")
            common = ["--store", store_path, "--messages", messages,
                      "--analysis", analysis, "--config", os.path.join(root, "missing.json")]
            initialize = subprocess.run([
                sys.executable, "scripts/wxfomo-signal-sync.py", "--initialize",
                "--store-id", "00000000-0000-4000-8000-000000000001",
            ] + common, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3,
                universal_newlines=True)
            self.assertEqual(initialize.returncode, 0, initialize.stderr)
            for mode in ("--status", "--dry-run"):
                result = subprocess.run([sys.executable, "scripts/wxfomo-signal-sync.py", mode] + common,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        timeout=3, universal_newlines=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("secret", result.stdout.lower())
                self.assertNotIn("content", result.stdout.lower())

    def test_message_anchor_emits_only_exact_alias_merge_evidence(self):
        from scripts.wxfomo_lan.signal_sync import message_source_anchor
        with tempfile.TemporaryDirectory() as root:
            messages, unused = create_sources(root)
            db = sqlite3.connect(messages)
            db.execute("INSERT INTO messages(event_id,record_version,group_name,content) "
                       "VALUES('old-event',1,'old','old')")
            db.commit(); db.close()
            previous = message_source_anchor(messages, 2)["snapshot"]
            db = sqlite3.connect(messages)
            db.execute("DELETE FROM messages WHERE id=2")
            db.execute("INSERT INTO message_event_aliases VALUES('old-event',1)")
            db.commit(); db.close()
            merged = message_source_anchor(messages, 2, previous)
            self.assertEqual(merged["snapshot"]["cursor_event_id"], "event-1")
            self.assertEqual(merged["merge_proofs"][0]["canonical_aliases"], ["old-event"])


class Clock(object):
    def __init__(self, value=1000.0):
        self.value = value
    def __call__(self):
        return self.value


class EmptyCA(object):
    startup_row_id = 0
    def after_row_id(self, cursor, limit):
        return []
    def current_rows(self, ids):
        return []


class SignalSyncServiceTests(unittest.TestCase):
    def store(self, root):
        from scripts.wxfomo_lan.signal_outbox import SyncStore
        value = SyncStore(os.path.join(root, "private", "outbox.sqlite3"))
        value.initialize(0, 0, 1000)
        self.addCleanup(value.close)
        return value

    def test_heartbeat_runs_on_its_own_schedule_and_429_blocks_all_sends(self):
        from scripts.wxfomo_lan.signal_sync import SyncService
        clock = Clock()
        monotonic = Clock()
        replies = [(429, {"Retry-After": "60"}, b""), (200, {}, b'{"ok":true}')]
        sent = []
        def transport(body):
            sent.append(json.loads(body))
            return replies.pop(0)
        with tempfile.TemporaryDirectory() as root:
            store = self.store(root)
            store.enqueue_batch("reports", 1, [fixture_body("report.example.json")], 1000)
            service = SyncService(store, lambda cursor: [], EmptyCA(), transport,
                                  clock, monotonic, lambda: 0)
            self.addCleanup(service.close)
            service.step()
            for _ in range(100):
                if service.send_future is not None and service.send_future.done():
                    break
                time.sleep(.001)
            service.step()
            self.assertEqual(sent[0]["type"], "heartbeat")
            self.assertTrue(store.status(clock())["globalRetryActive"])
            self.assertEqual(len(sent), 1)
            clock.value += 59
            monotonic.value += 59
            service.step()
            self.assertEqual(len(sent), 1)
            clock.value += 100
            monotonic.value += .5
            service.step()
            self.assertEqual(len(sent), 1)

    def test_non_global_heartbeat_retry_yields_to_a_queued_report(self):
        from scripts.wxfomo_lan.signal_sync import SyncService
        sent = []
        replies = [(500, {}, b""),
                   (200, {}, b'{"ok":true,"id":"wecom:macbook-pro-linn:3e0f8a42-0b42-4c77-9e8a-6c1d0f4e0a21:4b72163cd608de0f34d24d63097b709474b835f142949f68ae7b132a7aa25c88","revision":42,"disposition":"stored"}')]
        def transport(body):
            sent.append(json.loads(body)["type"])
            return replies.pop(0)
        with tempfile.TemporaryDirectory() as root:
            store = self.store(root)
            store.enqueue_batch("reports", 1, [fixture_body("report.example.json")], 1000)
            service = SyncService(store, lambda cursor: [], EmptyCA(), transport,
                                  Clock(), Clock(), lambda: 0)
            self.addCleanup(service.close)
            service.step()
            for _ in range(100):
                if service.send_future is not None and service.send_future.done(): break
                time.sleep(.001)
            service.step()
            for _ in range(100):
                if len(sent) >= 2: break
                time.sleep(.001)
            self.assertEqual(sent, ["heartbeat", "report"])

    def test_run_rejects_a_store_id_different_from_initialized_identity(self):
        from scripts.wxfomo_lan import signal_sync
        from scripts.wxfomo_lan.signal_outbox import SyncStore
        from scripts.wxfomo_lan.signal_transport import INGEST_URL, SyncConfig
        with tempfile.TemporaryDirectory() as root:
            store_path = os.path.join(root, "private", "outbox.sqlite3")
            store = SyncStore(store_path)
            store.initialize(0, 0, 1000,
                             store_id="00000000-0000-4000-8000-000000000001")
            store.close()
            options = types.SimpleNamespace(
                store=store_path, config=os.path.join(root, "unused.json"),
                messages=os.path.join(root, "unused-messages.sqlite3"),
                analysis=os.path.join(root, "unused-analysis.sqlite3"), once=True,
                store_id="00000000-0000-4000-8000-000000000002")
            config = SyncConfig(INGEST_URL, "fixture-device", "x" * 32)
            with mock.patch.object(signal_sync, "load_sync_config", return_value=config):
                with self.assertRaises(SyncError) as caught:
                    signal_sync._run(options)
            self.assertEqual(caught.exception.code, "identity_mismatch")

    def test_report_preparation_and_network_each_have_one_worker(self):
        from scripts.wxfomo_lan.signal_sync import SyncService
        with tempfile.TemporaryDirectory() as root:
            service = SyncService(self.store(root), lambda cursor: [], EmptyCA(),
                                  lambda body: (200, {}, b'{"ok":true}'),
                                  Clock(), Clock(), lambda: 0)
            self.addCleanup(service.close)
            self.assertEqual(service.report_executor._max_workers, 1)
            self.assertEqual(service.send_executor._max_workers, 1)

    def test_ca_tick_rereads_candidates_commits_cursor_and_never_writes_source(self):
        from scripts.wxfomo_lan.signal_ca import CAReader
        from scripts.wxfomo_lan.signal_sync import SyncService
        from scripts.wxfomo_lan.signal_transport import INGEST_URL, SyncConfig, send_payload
        address = "0x" + "Ab" * 20
        with tempfile.TemporaryDirectory() as root:
            messages, unused_analysis = create_sources(root)
            db = sqlite3.connect(messages)
            db.execute("INSERT INTO messages(event_id,record_version,group_name,sender_display_name,"
                       "content,observed_at,inserted_at) VALUES(?,?,?,?,?,?,?)",
                       ("event-2", 1, "alpha", "alice", "Base CA: " + address, 1000, 1000))
            db.execute("INSERT INTO messages(event_id,record_version,group_name,sender_display_name,"
                       "content,observed_at,inserted_at) VALUES(?,?,?,?,?,?,?)",
                       ("event-3", 1, "beta", "bob", "Base CA: " + address, 1001, 1001))
            db.commit(); db.close()
            relay = messages + ".relay.json"
            pathlib.Path(relay).write_text('{"version":1,"afterRowId":99}', encoding="utf-8")
            before_db = pathlib.Path(messages).read_bytes()
            before_relay = pathlib.Path(relay).read_bytes()
            reader = CAReader(messages)
            original = reader.current_rows
            reread = []
            def recorded(ids):
                reread.append(list(ids))
                return original(ids)
            reader.current_rows = recorded
            store = self.store(root)
            requests = []
            class Response(object):
                status = 200
                headers = {}
                def __init__(self, raw): self.raw = raw
                def read(self, unused_size):
                    raw, self.raw = self.raw, b""
                    return raw
                def close(self): pass
            def fake_http(request, timeout):
                value = json.loads(request.data)
                requests.append((request.full_url, value["type"]))
                if value["type"] == "heartbeat":
                    response = {"ok": True}
                else:
                    item = value["alert"]
                    response = {"ok": True, "id": item["id"],
                                "revision": item["revision"], "disposition": "stored"}
                return Response(json.dumps(response, separators=(",", ":")).encode("utf-8"))
            config = SyncConfig(INGEST_URL, "fixture-device", "x" * 32)
            transport = lambda body: send_payload(config, body, transport=fake_http)
            service = SyncService(store, lambda cursor: [], reader, transport,
                                  Clock(1001), Clock(1001), lambda: 0,
                                  device_id="fixture-device",
                                  store_id="00000000-0000-4000-8000-000000000001")
            self.addCleanup(service.close)
            service.step()
            self.assertEqual(store.cursor("messages"), 3)
            self.assertEqual(store.status(1001)["pendingAlerts"], 1)
            self.assertTrue(any(set(ids) >= {"event-2", "event-3"} for ids in reread))
            for _ in range(100):
                if service.send_future is not None and service.send_future.done(): break
                time.sleep(.001)
            service.step()
            for _ in range(100):
                if service.send_future is not None and service.send_future.done(): break
                time.sleep(.001)
            service.step()
            self.assertEqual(store.status(1001)["pendingAlerts"], 0)
            self.assertEqual(requests, [(INGEST_URL, "heartbeat"), (INGEST_URL, "ca_alert")])
            self.assertEqual(pathlib.Path(messages).read_bytes(), before_db)
            self.assertEqual(pathlib.Path(relay).read_bytes(), before_relay)

    def test_report_discovery_rejects_more_than_ten_without_advancing(self):
        from scripts.wxfomo_lan.signal_sync import SyncService
        rows = [{"cursor": index, "payload": fixture_body("report.example.json"),
                 "error_code": None} for index in range(1, 12)]
        with tempfile.TemporaryDirectory() as root:
            store = self.store(root)
            service = SyncService(store, lambda cursor: rows, EmptyCA(),
                                  lambda body: (200, {}, b'{"ok":true}'),
                                  Clock(), Clock(), lambda: 0)
            self.addCleanup(service.close)
            service.step()
            for _ in range(100):
                if service.report_future is not None and service.report_future.done():
                    break
                time.sleep(.001)
            status = service.step()
            self.assertEqual(store.cursor("reports"), 0)
            self.assertEqual(status["lastError"], "source_invalid")

    def test_bad_report_is_durably_located_does_not_block_later_and_can_retry(self):
        from scripts.wxfomo_lan.signal_sync import SyncService
        body = fixture_body("report.example.json")
        calls = []
        def reports(cursor):
            calls.append(cursor)
            if len(calls) == 1:
                return [{"cursor": 1, "payload": None, "error_code": "source_invalid"},
                        {"cursor": 2, "payload": body, "error_code": None}]
            return [{"cursor": 1, "payload": body, "error_code": None}]
        clock = Clock()
        with tempfile.TemporaryDirectory() as root:
            store = self.store(root)
            service = SyncService(store, reports, EmptyCA(),
                                  lambda unused: (_ for _ in ()).throw(RuntimeError()),
                                  clock, clock, lambda: 0)
            self.addCleanup(service.close)
            service.step()
            for _ in range(100):
                if service.report_future is not None and service.report_future.done(): break
                time.sleep(.001)
            service.step()
            self.assertEqual(store.cursor("reports"), 2)
            self.assertEqual(store.source_quarantines("reports")[0]["cursor"], 1)
            clock.value += 60
            service.step()
            for _ in range(100):
                if service.report_future is not None and service.report_future.done(): break
                time.sleep(.001)
            service.step()
            self.assertEqual(calls, [0, 0, 2])
            self.assertEqual(store.source_quarantines("reports"), [])

    def test_fake_https_transport_is_signed_and_never_changes_host(self):
        from scripts.wxfomo_lan.signal_transport import INGEST_URL, SyncConfig, send_payload
        seen = []
        class Response(object):
            status = 200
            headers = {}
            def __init__(self): self.remaining = b'{"ok":true}'
            def read(self, unused_size):
                value, self.remaining = self.remaining, b""
                return value
            def close(self): pass
        def fake_http(request, timeout):
            seen.append((request.full_url, timeout, request.get_header("X-wecom-signature")))
            return Response()
        body = fixture_body("heartbeat.example.json")
        result = send_payload(SyncConfig(INGEST_URL, "fixture-device", "x" * 32),
                              body, transport=fake_http)
        self.assertEqual(result[0], 200)
        self.assertEqual(seen[0][0], INGEST_URL)
        self.assertTrue(seen[0][2])

    def test_health_uses_listener_five_and_worker_fifteen_second_thresholds(self):
        from scripts.wxfomo_lan.signal_sync import source_health
        with tempfile.TemporaryDirectory() as root:
            messages, analysis = create_sources(root)
            self.assertEqual(source_health(messages, analysis, 1005),
                             {"listener": "online", "worker": "online"})
            self.assertEqual(source_health(messages, analysis, 1006),
                             {"listener": "offline", "worker": "offline"})

    def test_ca_budget_and_clock_rollback_fail_without_advancing_cursor(self):
        from scripts.wxfomo_lan.signal_sync import SyncService
        class Rows(EmptyCA):
            def after_row_id(self, cursor, limit):
                return [{"row_id": 1, "event_id": "e1", "record_version": 1,
                         "group": "alpha", "sender": "a",
                         "content": "Base CA: " + "0x" + "ab" * 20,
                         "observed_at": 1000, "inserted_at": 1000}]
            def current_rows(self, ids): return self.after_row_id(0, 500)
        class Mono(object):
            def __init__(self): self.values = [1000, 1003, 999]
            def __call__(self):
                return self.values.pop(0) if self.values else 999
        with tempfile.TemporaryDirectory() as root:
            store = self.store(root)
            mono = Mono()
            service = SyncService(store, lambda cursor: [], Rows(),
                                  lambda body: (200, {}, b'{"ok":true}'),
                                  Clock(), mono, lambda: 0)
            self.addCleanup(service.close)
            status = service.step()
            self.assertEqual(store.cursor("messages"), 0)
            self.assertEqual(status["lastError"], "ca_budget_exceeded")
            with self.assertRaises(SyncError) as caught:
                service.step()
            self.assertEqual(caught.exception.code, "clock_invalid")

    def test_bad_message_row_is_located_without_blocking_and_retried_on_reconcile(self):
        from scripts.wxfomo_lan.signal_sync import SyncService
        def row(number, content):
            return {"row_id": number, "event_id": "e" + str(number),
                    "record_version": 1, "group": "g", "sender": "s",
                    "content": content, "observed_at": 1000, "inserted_at": 1000}
        class Repairable(EmptyCA):
            def __init__(self): self.calls = 0
            def after_row_id(self, cursor, limit):
                self.calls += 1
                if self.calls == 1:
                    return [row(1, 123), row(2, "ordinary")]
                if cursor == 0:
                    return [row(1, "repaired")]
                return []
            def current_rows(self, ids):
                return [row(int(item[1:]), "ordinary") for item in ids]
        clock = Clock()
        with tempfile.TemporaryDirectory() as root:
            store = self.store(root)
            source = Repairable()
            service = SyncService(store, lambda cursor: [], source,
                                  lambda body: (200, {}, b'{"ok":true}'),
                                  clock, clock, lambda: 0)
            self.addCleanup(service.close)
            service.step()
            self.assertEqual(store.cursor("messages"), 2)
            self.assertEqual(store.source_quarantines("messages")[0]["cursor"], 1)
            clock.value += 60
            service.step()
            self.assertEqual(store.source_quarantines("messages"), [])


if __name__ == "__main__":
    unittest.main()
