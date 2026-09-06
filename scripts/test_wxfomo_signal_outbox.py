import copy
import json
import os
import pathlib
import sqlite3
import stat
import tempfile
import unittest

from scripts.wxfomo_lan.signal_contract import SyncError, encode_payload


FIXTURES = pathlib.Path(__file__).parent / "fixtures" / "signalhub-v2-handoff-8f6df4f"


def body(name="report.example.json"):
    return encode_payload(json.loads((FIXTURES / name).read_text(encoding="utf-8")))


def report_body(identifier, summary=None):
    value = json.loads((FIXTURES / "report.example.json").read_text(encoding="utf-8"))
    value["report"]["id"] = identifier
    if summary is not None:
        value["report"]["summary"] = summary
    return encode_payload(value)


def report_snapshot(max_id=10, cursor_id=0, job_id=None, digest=None,
                    device=1, inode=2):
    return {"file_device": device, "file_inode": inode, "max_id": max_id,
            "cursor_id": cursor_id, "cursor_job_id": job_id,
            "cursor_digest": digest}


def message_snapshot(sequence=10, cursor_id=0, row_id=None, event_id=None,
                     version=None, device=3, inode=4):
    return {"file_device": device, "file_inode": inode,
            "sqlite_sequence": sequence, "cursor_id": cursor_id,
            "cursor_row_id": row_id, "cursor_event_id": event_id,
            "cursor_record_version": version}


class SyncStoreTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = os.path.join(self.directory.name, "signalhub-sync", "outbox.sqlite3")

    def store(self, **kwargs):
        from scripts.wxfomo_lan.signal_outbox import SyncStore
        value = SyncStore(self.path, **kwargs)
        self.addCleanup(value.close)
        return value

    def test_fixed_payload_and_cursor_survive_restart(self):
        value = self.store()
        value.initialize(0, 0, 1000)
        report = body()
        value.enqueue_batch("reports", 1, [report], 1000)
        value.close()
        restored = self.store()
        self.assertEqual(restored.cursor("reports"), 1)
        self.assertEqual(restored.pending()[0]["body"], report)
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(self.path)).st_mode), 0o700)

    def test_initialization_is_one_time_and_channels_are_separate(self):
        value = self.store()
        value.initialize(7, 9, 1000)
        self.assertEqual((value.cursor("reports"), value.cursor("messages")), (7, 9))
        with self.assertRaises(SyncError) as caught:
            value.initialize(0, 0, 1001)
        self.assertEqual(caught.exception.code, "already_initialized")
        self.assertEqual((value.cursor("reports"), value.cursor("messages")), (7, 9))

    def test_sync_identity_is_bound_across_restart_and_changes_are_rejected(self):
        store_id = "00000000-0000-4000-8000-000000000001"
        value = self.store()
        value.initialize(0, 0, 1000, store_id=store_id)
        self.assertEqual(value.identity(), {"store_id": store_id, "device_id": None})
        value.bind_identity(store_id, "device-one")
        value.close()
        restored = self.store()
        self.assertEqual(restored.identity(),
                         {"store_id": store_id, "device_id": "device-one"})
        for changed in (("00000000-0000-4000-8000-000000000002", "device-one"),
                        (store_id, "device-two")):
            with self.subTest(changed=changed), self.assertRaises(SyncError) as caught:
                restored.bind_identity(*changed)
            self.assertEqual(caught.exception.code, "identity_mismatch")

    def test_forty_items_are_returned_in_stable_order_and_survive_restart(self):
        value = self.store()
        value.initialize(0, 0, 1000)
        payloads = [report_body("wecom-report:d:s:{:02d}".format(index))
                    for index in range(40)]
        value.enqueue_batch("reports", 40, payloads, 1000)
        value.close()
        restored = self.store()
        rows = restored.pending("report")
        self.assertEqual(len(rows), 40)
        self.assertEqual([row["id"] for row in rows],
                         sorted(row["id"] for row in rows))
        self.assertTrue(all(row["next_attempt_at"] == 1000 for row in rows))

    def test_same_version_is_idempotent_but_different_bytes_roll_back_cursor(self):
        value = self.store()
        value.initialize(0, 0, 1000)
        first = report_body("wecom-report:d:s:fixed", "first")
        conflict = report_body("wecom-report:d:s:fixed", "second")
        value.enqueue_batch("reports", 1, [first], 1000)
        value.enqueue_batch("reports", 2, [first], 1001)
        self.assertEqual((value.cursor("reports"), len(value.pending())), (2, 1))
        with self.assertRaises(SyncError) as caught:
            value.enqueue_batch("reports", 3, [conflict], 1002)
        self.assertEqual(caught.exception.code, "payload_conflict")
        self.assertEqual(value.cursor("reports"), 2)

    def test_duplicate_or_conflicting_items_inside_one_batch_are_preflighted(self):
        value = self.store(max_items=1)
        value.initialize(0, 0, 1000)
        first = report_body("wecom-report:d:s:fixed", "first")
        conflict = report_body("wecom-report:d:s:fixed", "second")
        value.enqueue_batch("reports", 1, [first, first], 1000)
        self.assertEqual(len(value.pending()), 1)
        with self.assertRaises(SyncError) as caught:
            value.enqueue_batch("reports", 2, [first, conflict], 1001)
        self.assertEqual(caught.exception.code, "payload_conflict")
        self.assertEqual(value.cursor("reports"), 1)

    def test_invalid_late_item_quota_and_write_failure_never_advance_cursor(self):
        value = self.store(max_items=1)
        value.initialize(0, 0, 1000)
        with self.assertRaises(SyncError):
            value.enqueue_batch("reports", 2, [body(), b"not-json"], 1000)
        self.assertEqual((value.cursor("reports"), value.pending()), (0, []))
        value.enqueue_batch("reports", 1, [body()], 1000)
        with self.assertRaises(SyncError) as caught:
            value.enqueue_batch("reports", 2, [report_body("wecom-report:d:s:2")], 1001)
        self.assertEqual(caught.exception.code, "outbox_full")
        self.assertEqual(value.cursor("reports"), 1)

        value.connection.execute("PRAGMA query_only=ON")
        with self.assertRaises(SyncError) as caught:
            value.enqueue_batch("reports", 2, [], 1002)
        self.assertEqual(caught.exception.code, "store_write_failed")
        self.assertEqual(value.cursor("reports"), 1)

    def test_byte_quota_uses_pending_and_quarantined_bodies(self):
        first = body()
        second = report_body("wecom-report:d:s:2")
        value = self.store(max_items=10, max_bytes=len(first) + len(second) - 1)
        value.initialize(0, 0, 1000)
        value.enqueue_batch("reports", 1, [first], 1000)
        decision = {"action": "quarantine", "code": "request_invalid",
                    "retry_after": None, "scope": "item"}
        value.apply_response("report", json.loads(first)["report"]["id"], 1,
                             decision, 1001)
        with self.assertRaises(SyncError) as caught:
            value.enqueue_batch("reports", 2, [second], 1002)
        self.assertEqual(caught.exception.code, "outbox_full")

    def test_ack_is_retained_and_only_exact_matching_response_changes_state(self):
        value = self.store()
        value.initialize(0, 0, 1000)
        raw = body()
        identifier = json.loads(raw)["report"]["id"]
        value.enqueue_batch("reports", 1, [raw], 1000)
        ack = {"action": "ack", "code": None, "retry_after": None, "scope": "item"}
        with self.assertRaises(SyncError):
            value.apply_response("report", identifier + "-wrong", 1, ack, 1001)
        self.assertEqual(len(value.pending()), 1)
        value.apply_response("report", identifier, 1, ack, 1001)
        self.assertEqual(value.pending(), [])
        row = value.connection.execute(
            "SELECT state,body FROM outbox WHERE kind='report' AND id=?", (identifier,)
        ).fetchone()
        self.assertEqual((row["state"], bytes(row["body"])), ("acked", raw))

    def test_retry_global_pause_and_deadline_survive_restart(self):
        value = self.store()
        value.initialize(0, 0, 1000)
        first = body()
        identifier = json.loads(first)["report"]["id"]
        value.enqueue_batch("reports", 1, [first], 1000)
        value.apply_response("report", identifier, 1, {
            "action": "retry", "code": "rate_limited", "retry_after": 120,
            "scope": "global"}, 1001)
        self.assertEqual(value.pending()[0]["next_attempt_at"], 1121)
        value.apply_response("report", identifier, 1, {
            "action": "pause", "code": "authentication_failed", "retry_after": None,
            "scope": "global"}, 1002)
        value.close()
        restored = self.store()
        status = restored.status(1003)
        self.assertEqual(status["globalRetryUntil"], 1121)
        self.assertEqual(status["globalPause"]["code"], "authentication_failed")
        self.assertEqual(status["pendingReports"], 1)

    def test_ca_state_changes_are_atomic_validated_and_reconstructed(self):
        from scripts.wxfomo_lan.signal_ca import advance_ca, ca_state_changes
        address = "0x" + "Ab" * 20
        def item(row_id, group):
            return {"row_id": row_id, "event_id": "e" + str(row_id),
                    "record_version": 1, "group": group, "sender": "猫",
                    "content": "Base CA: " + address, "observed_at": 1000 + row_id,
                    "inserted_at": 1000 + row_id}
        result = advance_ca({}, [item(1, "甲群"), item(2, "乙群")], 1010, 0,
                            "d", "s")
        changes = ca_state_changes({}, result["state"])
        value = self.store()
        value.initialize(0, 0, 1000)
        value.enqueue_batch("messages", 2, [encode_payload(result["alerts"][0])],
                            1010, changes)
        self.assertEqual(value.ca_state(), result["state"])
        bad = [{"op": "set_ca_meta", "key": "next_episode",
                "value": {"content": "PRIVATE"}}]
        with self.assertRaises(SyncError) as caught:
            value.enqueue_batch("messages", 3, [], 1011, bad)
        self.assertEqual(caught.exception.code, "state_change_invalid")
        self.assertEqual(value.cursor("messages"), 2)

    def test_failure_after_payload_and_mention_writes_rolls_back_the_whole_batch(self):
        from scripts.wxfomo_lan.signal_ca import advance_ca, ca_state_changes
        address = "0x" + "ab" * 20
        rows = [{"row_id": index, "event_id": "e" + str(index),
                 "record_version": 1, "group": group, "sender": "猫",
                 "content": "Base: " + address, "observed_at": 1000 + index,
                 "inserted_at": 1000 + index}
                for index, group in ((1, "甲群"), (2, "乙群"))]
        derived = advance_ca({}, rows, 1010, 0, "d", "s")
        value = self.store()
        value.initialize(0, 0, 1000)
        value.connection.execute("""
          CREATE TRIGGER fail_episode BEFORE INSERT ON ca_episodes
          BEGIN SELECT RAISE(ABORT,'synthetic'); END
        """)
        with self.assertRaises(SyncError) as caught:
            value.enqueue_batch("messages", 2,
                                [encode_payload(derived["alerts"][0])], 1010,
                                ca_state_changes({}, derived["state"]))
        self.assertEqual(caught.exception.code, "store_write_failed")
        self.assertEqual(value.cursor("messages"), 0)
        self.assertEqual(value.pending(), [])
        self.assertEqual(value.ca_state()["mentions"], {})

    def test_ca_index_quota_rolls_back_payload_and_cursor(self):
        value = self.store(max_ca_bytes=10)
        value.initialize(0, 0, 1000)
        change = {"op": "upsert_mention", "key": "row:1", "value": {
            "row_id": 1, "event_id": "e1", "record_version": 1, "group": "甲群",
            "observed_at": 1000.0, "inserted_at": 1000.0, "time_status": "valid",
            "catchup": False, "mentions": []}}
        with self.assertRaises(SyncError) as caught:
            value.enqueue_batch("messages", 1, [], 1000, [change])
        self.assertEqual(caught.exception.code, "ca_index_full")
        self.assertEqual((value.cursor("messages"), value.ca_state()["mentions"]), (0, {}))

    def test_ca_changes_require_message_channel_and_malformed_values_fail_closed(self):
        value = self.store()
        value.initialize(0, 0, 1000)
        valid = {"op": "upsert_mention", "key": "row:1", "value": {
            "row_id": 1, "event_id": "e1", "record_version": 1, "group": "甲群",
            "observed_at": 1000.0, "inserted_at": 1000.0, "time_status": "valid",
            "catchup": False, "mentions": []}}
        with self.assertRaises(SyncError) as caught:
            value.enqueue_batch("reports", 1, [], 1000, [valid])
        self.assertEqual(caught.exception.code, "state_change_invalid")
        with self.assertRaises(SyncError) as caught:
            value.enqueue_batch("messages", 1, [], 1000, [{
                "op": "upsert_mention", "key": "row:1", "value": 1
            }])
        self.assertEqual(caught.exception.code, "state_change_invalid")
        self.assertEqual((value.cursor("reports"), value.cursor("messages")), (0, 0))

    def test_schema_pause_is_persisted_without_quarantining_the_item(self):
        value = self.store()
        value.initialize(0, 0, 1000)
        raw = body()
        identifier = json.loads(raw)["report"]["id"]
        value.enqueue_batch("reports", 1, [raw], 1000)
        value.apply_response("report", identifier, 1, {
            "action": "pause", "code": "unsupported_schema", "retry_after": None,
            "scope": "schema"}, 1001)
        self.assertEqual(value.status(1002)["schemaPause"]["code"],
                         "unsupported_schema")
        self.assertEqual(len(value.pending()), 1)

    def test_heartbeat_global_response_persists_without_fake_item_identity(self):
        value = self.store()
        value.initialize(0, 0, 1000)
        value.apply_global_response({
            "action": "retry", "code": "rate_limited", "retry_after": 120,
            "scope": "global"}, 1000)
        self.assertEqual(value.status(1001)["globalRetryUntil"], 1120)
        value.apply_global_response({
            "action": "pause", "code": "authentication_failed", "retry_after": None,
            "scope": "global"}, 1002)
        self.assertEqual(value.status(1003)["globalPause"]["code"],
                         "authentication_failed")
        self.assertEqual(value.connection.execute("SELECT COUNT(*) FROM outbox").fetchone()[0], 0)

    def test_channel_error_keeps_only_typed_retry_location_and_survives_restart(self):
        value = self.store()
        value.initialize(7, 9, 1000)
        value.record_channel_error("reports", 8, "source_invalid", 1001)
        self.assertEqual(value.status(1002)["channelErrors"], {
            "reports": {"cursor": 8, "code": "source_invalid", "at": 1001}
        })
        value.close()
        restored = self.store()
        self.assertEqual(restored.status(1002)["channelErrors"]["reports"]["cursor"], 8)
        restored.clear_channel_error("reports")
        self.assertEqual(restored.status(1003)["channelErrors"], {})
        restored.quarantine_source("reports", 8, "source_invalid", 1004)
        self.assertEqual(restored.source_quarantines("reports"), [{
            "cursor": 8, "code": "source_invalid", "at": 1004
        }])
        restored.resolve_source_quarantine("reports", 8)
        self.assertEqual(restored.source_quarantines("reports"), [])

    def test_source_quarantine_count_uses_the_persistent_item_budget(self):
        value = self.store(max_items=1)
        value.initialize(0, 0, 1000)
        value.quarantine_source("reports", 1, "source_invalid", 1001)
        with self.assertRaises(SyncError) as caught:
            value.quarantine_source("reports", 2, "source_invalid", 1002)
        self.assertEqual(caught.exception.code, "outbox_full")
        with self.assertRaises(SyncError) as caught:
            value.enqueue_batch("reports", 1, [body()], 1002)
        self.assertEqual(caught.exception.code, "outbox_full")
        self.assertEqual([item["cursor"] for item in value.source_quarantines("reports")], [1])

    def test_source_anchors_detect_rollback_identity_and_changed_report_anchor(self):
        value = self.store()
        value.initialize(0, 0, 1000)
        value.check_source("reports", report_snapshot(), 1000)
        self.assertEqual(value.source_anchor("reports"), report_snapshot())
        value.check_source("reports", report_snapshot(max_id=11), 1001)
        for changed in (report_snapshot(max_id=9), report_snapshot(max_id=11, inode=99)):
            with self.subTest(changed=changed), self.assertRaises(SyncError) as caught:
                value.check_source("reports", changed, 1002)
            self.assertEqual(caught.exception.code, "source_generation_changed")
        self.assertEqual(value.status(1003)["channelPauses"]["reports"]["code"],
                         "source_generation_changed")

        separate = self.store_at("other.sqlite3")
        separate.initialize(1, 0, 1000)
        digest = "a" * 64
        separate.check_source("reports", report_snapshot(
            cursor_id=1, job_id="job-1", digest=digest), 1000)
        changed = report_snapshot(cursor_id=1, job_id="job-2", digest="b" * 64)
        with self.assertRaises(SyncError):
            separate.check_source("reports", changed, 1001)

    def test_source_maximum_below_cursor_pauses_even_when_previous_anchor_exists(self):
        value = self.store()
        value.initialize(0, 0, 1000)
        value.check_source("reports", report_snapshot(max_id=10), 1000)
        value.enqueue_batch("reports", 20, [], 1001)
        with self.assertRaises(SyncError) as caught:
            value.check_source("reports", report_snapshot(
                max_id=15, cursor_id=20, job_id="synthetic-20", digest="a" * 64
            ), 1002)
        self.assertEqual(caught.exception.code, "source_generation_changed")
        self.assertEqual(value.status(1003)["channelPauses"]["reports"]["code"],
                         "source_generation_changed")

    def store_at(self, name, **kwargs):
        from scripts.wxfomo_lan.signal_outbox import SyncStore
        value = SyncStore(os.path.join(self.directory.name, name), **kwargs)
        self.addCleanup(value.close)
        return value

    def test_message_sequence_cannot_rollback_and_alias_change_needs_exact_proof(self):
        value = self.store()
        value.initialize(0, 10, 1000)
        before = message_snapshot(cursor_id=10, row_id=10, event_id="old", version=1)
        value.check_source("messages", before, 1000)
        after = message_snapshot(sequence=11, cursor_id=10, row_id=8,
                                 event_id="canonical", version=2)
        with self.assertRaises(SyncError):
            value.check_source("messages", after, 1001)
        proof = {"previous": {"row_id": 10, "event_id": "old", "record_version": 1},
                 "current": {"row_id": 8, "event_id": "canonical", "record_version": 2},
                 "canonical_aliases": ["old"]}
        value.check_source("messages", after, 1001, merge_proofs=[proof])
        with self.assertRaises(SyncError):
            value.check_source("messages", message_snapshot(
                sequence=9, cursor_id=10, row_id=8, event_id="canonical", version=2
            ), 1002, merge_proofs=[proof])
        self.assertEqual(value.status(1003)["channelPauses"]["messages"]["code"],
                         "source_generation_changed")

    def test_same_anchors_cannot_detect_a_backup_preserving_all_checked_values(self):
        value = self.store()
        value.initialize(0, 0, 1000)
        snapshot = report_snapshot()
        value.check_source("reports", snapshot, 1000)
        self.assertEqual(value.check_source("reports", copy.deepcopy(snapshot), 1001),
                         {"status": "ok", "changed": False})

    def test_existing_foreign_database_symlink_hardlink_and_unsafe_parent_are_rejected(self):
        from scripts.wxfomo_lan.signal_outbox import SyncStore
        foreign = os.path.join(self.directory.name, "foreign.sqlite3")
        connection = sqlite3.connect(foreign)
        connection.execute("CREATE TABLE sentinel(value TEXT)")
        self.assertEqual(connection.execute("PRAGMA journal_mode=WAL").fetchone()[0], "wal")
        connection.close()
        os.chmod(foreign, 0o600)
        with self.assertRaises(SyncError) as caught:
            SyncStore(foreign)
        self.assertEqual(caught.exception.code, "store_schema_incompatible")
        connection = sqlite3.connect(foreign)
        self.assertIsNotNone(connection.execute(
            "SELECT name FROM sqlite_master WHERE name='sentinel'"
        ).fetchone())
        self.assertIsNone(connection.execute(
            "SELECT name FROM sqlite_master WHERE name='outbox'"
        ).fetchone())
        self.assertEqual(connection.execute("PRAGMA journal_mode").fetchone()[0], "wal")
        connection.close()

        target = os.path.join(self.directory.name, "target")
        pathlib.Path(target).write_bytes(b"")
        os.chmod(target, 0o600)
        link = os.path.join(self.directory.name, "link")
        os.symlink(target, link)
        with self.assertRaises(SyncError):
            SyncStore(link)
        hard = os.path.join(self.directory.name, "hard")
        os.link(target, hard)
        with self.assertRaises(SyncError):
            SyncStore(hard)

        unsafe = os.path.join(self.directory.name, "unsafe")
        os.mkdir(unsafe, 0o755)
        with self.assertRaises(SyncError):
            SyncStore(os.path.join(unsafe, "outbox.sqlite3"))

        impostor = os.path.join(self.directory.name, "impostor.sqlite3")
        connection = sqlite3.connect(impostor)
        connection.execute("PRAGMA application_id={}".format(0x57584653))
        connection.execute("PRAGMA user_version=1")
        connection.execute("CREATE TABLE sync_state(key TEXT PRIMARY KEY,value TEXT)")
        connection.commit()
        connection.close()
        os.chmod(impostor, 0o600)
        with self.assertRaises(SyncError) as caught:
            SyncStore(impostor)
        self.assertEqual(caught.exception.code, "store_schema_incompatible")


if __name__ == "__main__":
    unittest.main()
