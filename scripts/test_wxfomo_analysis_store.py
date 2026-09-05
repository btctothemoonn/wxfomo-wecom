import os
import sqlite3
import stat
import tempfile
import unittest

from scripts.wxfomo_lan.analysis_source import MessageSource
from scripts.wxfomo_lan.analysis_store import AnalysisStore
from scripts.wxfomo_lan.rules import evaluate_message
from scripts.wxfomo_lan.scheduler import AnalysisWindow


class AnalysisStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.message_path = os.path.join(
            self.temporary_directory.name, "messages.sqlite3"
        )
        self.analysis_directory = os.path.join(
            self.temporary_directory.name, "analysis"
        )
        self.analysis_path = os.path.join(self.analysis_directory, "analysis.sqlite3")
        self._create_messages()

    def _create_messages(self):
        connection = sqlite3.connect(self.message_path)
        self.addCleanup(connection.close)
        connection.execute(
            """CREATE TABLE messages(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id TEXT NOT NULL UNIQUE, group_name TEXT NOT NULL,
                sender_display_name TEXT, content TEXT NOT NULL,
                message_type TEXT NOT NULL, observed_at REAL NOT NULL
            )"""
        )
        connection.executemany(
            "INSERT INTO messages(event_id, group_name, sender_display_name, content, "
            "message_type, observed_at) VALUES (?, ?, ?, ?, ?, ?)",
            [
                ("before", "甲群", "甲", "before", "text", 99.9),
                ("inside", "甲群", "乙", "inside", "text", 100.0),
                ("later", "乙群", "丙", "later", "media", 199.9),
                ("after", "乙群", "丁", "after", "text", 200.0),
            ],
        )
        connection.commit()

    def test_message_source_is_read_only_and_uses_half_open_window(self):
        source = MessageSource(self.message_path)
        self.assertEqual(source.event_ids_in_window(100.0, 200.0), ["inside", "later"])
        with self.assertRaises(sqlite3.OperationalError):
            source._open().execute("DELETE FROM messages")

    def test_message_source_preserves_cursor_and_frozen_id_order(self):
        source = MessageSource(self.message_path)
        self.assertEqual(
            [item["eventId"] for item in source.after(None, 2)], ["before", "inside"]
        )
        self.assertEqual(
            source.after((100.0, "inside"), 10),
            [{
                "eventId": "later", "groupName": "乙群", "senderDisplayName": "丙",
                "content": "later", "messageType": "media", "observedAt": 199.9,
            }, {
                "eventId": "after", "groupName": "乙群", "senderDisplayName": "丁",
                "content": "after", "messageType": "text", "observedAt": 200.0,
            }],
        )
        self.assertEqual(
            [item["eventId"] for item in source.by_event_ids(["after", "inside"])],
            ["after", "inside"],
        )
        with self.assertRaises(ValueError):
            source.by_event_ids([""])

    def test_rule_batch_and_cursor_commit_together(self):
        store = AnalysisStore(
            self.analysis_path, "11111111-1111-4111-8111-111111111111", lambda: 1000.0
        )
        self.addCleanup(store.close)
        message = {"eventId": "event-1", "observedAt": 900.0, "content": "rug 加仓"}
        store.persist_rule_batch(
            [(message, evaluate_message(message["content"]))],
            (900.0, "event-1"), catalog_version=1, row_id=8,
        )
        self.assertEqual(store.rule_cursor(), (900.0, "event-1"))
        self.assertEqual(store.rule_row_id_cursor(), 8)
        rows = sqlite3.connect(self.analysis_path).execute(
            "SELECT rule_id, priority FROM message_rule_matches ORDER BY priority DESC"
        ).fetchall()
        self.assertEqual(rows, [
            ("recommended.risk.contract-liquidity", 50),
            ("recommended.signal.accumulation", 30),
        ])

    def test_failed_rule_batch_does_not_advance_insertion_cursor(self):
        # A failed later match must not skip the batch after a restart.
        store = AnalysisStore(
            self.analysis_path, "11111111-1111-4111-8111-111111111111", lambda: 1000.0
        )
        self.addCleanup(store.close)
        message = {"eventId": "event-1", "observedAt": 900.0, "content": "rug"}
        invalid = {"matchedRules": [{"ruleId": "invalid", "priority": None}]}
        with self.assertRaises(sqlite3.IntegrityError):
            store.persist_rule_batch(
                [(message, evaluate_message("rug")), ({"eventId": "event-2"}, invalid)],
                (901.0, "event-2"), 1, row_id=9,
            )
        self.assertEqual(store.rule_row_id_cursor(), 0)
        self.assertIsNone(store.rule_cursor())
        self.assertEqual(store.connection.execute(
            "SELECT COUNT(*) FROM message_rule_matches"
        ).fetchone()[0], 0)

    def test_legacy_time_cursor_migrates_to_unscanned_insertion_cursor(self):
        # Guessing an insertion watermark from the old clock can lose late rows.
        os.mkdir(self.analysis_directory, 0o700)
        with sqlite3.connect(self.analysis_path) as connection:
            connection.execute("""CREATE TABLE analysis_worker_state(
                singleton_id INTEGER PRIMARY KEY, instance_id TEXT, heartbeat_at REAL,
                rule_cursor_time REAL, rule_cursor_event_id TEXT, rule_catalog_version INTEGER,
                provider_not_before REAL, credential_status TEXT, last_provider_success_at REAL,
                last_error_code TEXT, updated_at REAL NOT NULL
            )""")
            connection.execute(
                "INSERT INTO analysis_worker_state(singleton_id, rule_cursor_time, "
                "rule_cursor_event_id, rule_catalog_version, updated_at) "
                "VALUES (1, 9999.0, 'old-cursor', 1, 1000.0)"
            )
        os.chmod(self.analysis_path, 0o600)
        store = AnalysisStore(
            self.analysis_path, "11111111-1111-4111-8111-111111111111", lambda: 1000.0
        )
        self.addCleanup(store.close)
        self.assertFalse(store.prepare_rule_scan(1))
        self.assertEqual(store.rule_cursor(), (9999.0, "old-cursor"))
        source = MessageSource(self.message_path)
        self.assertEqual([message["eventId"] for unused_id, message in
                          source.after_row_id(store.rule_row_id_cursor(), 10)],
                         ["before", "inside", "later", "after"])

    def test_replaying_an_event_replaces_matches_without_duplicates(self):
        store = AnalysisStore(
            self.analysis_path, "11111111-1111-4111-8111-111111111111", lambda: 1000.0
        )
        self.addCleanup(store.close)
        message = {"eventId": "event-1", "observedAt": 900.0, "content": "rug"}
        record = (message, evaluate_message(message["content"]))
        store.persist_rule_batch([record], (900.0, "event-1"), 1)
        store.persist_rule_batch([record], (900.0, "event-1"), 1)
        count = store.connection.execute(
            "SELECT COUNT(*) FROM message_rule_matches WHERE event_id = 'event-1'"
        ).fetchone()[0]
        self.assertEqual(count, 1)

    def test_second_non_stale_writer_is_rejected_and_files_are_private(self):
        first = AnalysisStore(
            self.analysis_path, "11111111-1111-4111-8111-111111111111", lambda: 1000.0
        )
        self.addCleanup(first.close)
        first.acquire()
        second = AnalysisStore(
            self.analysis_path, "22222222-2222-4222-8222-222222222222", lambda: 1000.0
        )
        self.addCleanup(second.close)
        with self.assertRaises(RuntimeError):
            second.acquire()
        self.assertEqual(stat.S_IMODE(os.stat(self.analysis_directory).st_mode), 0o700)
        database_stat = os.stat(self.analysis_path)
        self.assertEqual(stat.S_IMODE(database_stat.st_mode), 0o600)
        self.assertEqual(database_stat.st_nlink, 1)

    def test_stale_owner_cannot_change_data_after_takeover(self):
        now = [1000.0]
        first = AnalysisStore(
            self.analysis_path, "11111111-1111-4111-8111-111111111111", lambda: now[0]
        )
        self.addCleanup(first.close)
        first.acquire()
        message = {"eventId": "event-1", "observedAt": 900.0, "content": "rug"}
        first.persist_rule_batch(
            [(message, evaluate_message(message["content"]))], (900.0, "event-1"), 1
        )
        now[0] = 1016.0
        second = AnalysisStore(
            self.analysis_path, "22222222-2222-4222-8222-222222222222", lambda: now[0]
        )
        self.addCleanup(second.close)
        second.acquire()
        new_message = {"eventId": "event-2", "observedAt": 901.0, "content": "加仓"}
        with self.assertRaises(RuntimeError):
            first.persist_rule_batch(
                [(new_message, evaluate_message(new_message["content"]))],
                (901.0, "event-2"), 2,
            )
        with self.assertRaises(RuntimeError):
            first.heartbeat()
        self.assertEqual(first.rule_cursor(), (900.0, "event-1"))
        self.assertEqual(
            second.connection.execute(
                "SELECT COUNT(*) FROM message_rule_matches WHERE event_id = 'event-2'"
            ).fetchone()[0], 0,
        )

    def test_existing_unsafe_parent_is_rejected_without_permission_change(self):
        unsafe_parent = os.path.join(self.temporary_directory.name, "shared")
        os.mkdir(unsafe_parent, 0o755)
        os.chmod(unsafe_parent, 0o755)
        path = os.path.join(unsafe_parent, "analysis.sqlite3")
        with self.assertRaises(RuntimeError):
            AnalysisStore(
                path, "11111111-1111-4111-8111-111111111111", lambda: 1000.0
            )
        self.assertEqual(stat.S_IMODE(os.stat(unsafe_parent).st_mode), 0o755)
        self.assertFalse(os.path.exists(path))

    def test_catalog_change_clears_rule_data_and_cursor_for_replay(self):
        store = AnalysisStore(
            self.analysis_path, "11111111-1111-4111-8111-111111111111", lambda: 1000.0
        )
        self.addCleanup(store.close)
        message = {"eventId": "event-1", "observedAt": 900.0, "content": "rug"}
        store.persist_rule_batch(
            [(message, evaluate_message(message["content"]))], (900.0, "event-1"), 1,
            row_id=8,
        )
        self.assertTrue(store.prepare_rule_scan(2))
        self.assertIsNone(store.rule_cursor())
        self.assertEqual(store.rule_row_id_cursor(), 0)
        self.assertEqual(
            store.connection.execute("SELECT COUNT(*) FROM message_rule_matches").fetchone()[0], 0
        )

    def test_ensure_job_reuses_window_and_preserves_frozen_event_ids(self):
        # This catches replacing a window's immutable source-event snapshot on a later wake.
        store = AnalysisStore(
            self.analysis_path, "11111111-1111-4111-8111-111111111111", lambda: 1000.0
        )
        self.addCleanup(store.close)
        window = AnalysisWindow("two_hour", 0.0, 7200.0, 7500.0)
        first = store.ensure_job(window, ["event-1", "event-2"])
        second = store.ensure_job(window, ["new-event"])
        self.assertEqual(first["job_id"], second["job_id"])
        self.assertEqual(second["state"], "queued")
        self.assertEqual(second["source_event_ids"], ["event-1", "event-2"])

    def test_ensure_job_reports_only_the_durable_insert_as_created(self):
        # This catches a restarted worker reporting an existing window as newly created.
        store = AnalysisStore(
            self.analysis_path, "11111111-1111-4111-8111-111111111111", lambda: 1000.0
        )
        self.addCleanup(store.close)
        window = AnalysisWindow("two_hour", 0.0, 7200.0, 7500.0)

        self.assertTrue(store.ensure_job(window, ["event-1"])["was_created"])
        self.assertFalse(store.ensure_job(window, ["event-2"])["was_created"])

    def test_new_credential_revision_requeues_only_rejected_jobs_from_old_revision(self):
        # This catches unchanged rejected credentials looping or unrelated jobs moving.
        store = AnalysisStore(
            self.analysis_path, "11111111-1111-4111-8111-111111111111", lambda: 1000.0
        )
        self.addCleanup(store.close)
        rejected = store.ensure_job(
            AnalysisWindow("two_hour", 0.0, 7200.0, 7500.0), ["event-1"]
        )
        queued = store.ensure_job(
            AnalysisWindow("six_hour", 0.0, 21600.0, 22200.0), ["event-2"]
        )
        claimed = store.claim_next_job(30000.0)
        store.credential_required(claimed, "1:2:3:4")

        self.assertTrue(store.credential_revision_rejected("1:2:3:4"))
        self.assertFalse(store.credential_revision_rejected("1:2:3:5"))
        self.assertEqual(store.refresh_credential("configured", "1:2:3:4"), 0)
        self.assertEqual(
            store.connection.execute(
                "SELECT state FROM analysis_jobs WHERE job_id=?", (rejected["job_id"],)
            ).fetchone()[0],
            "credential_required",
        )
        self.assertEqual(store.refresh_credential("configured", "1:2:3:5"), 1)
        self.assertFalse(store.credential_revision_rejected("1:2:3:4"))
        retry_series = store.connection.execute(
            "SELECT attempt FROM analysis_jobs WHERE job_id=?", (rejected["job_id"],)
        ).fetchone()[0]
        self.assertEqual(retry_series, 0)
        states = dict(store.connection.execute(
            "SELECT job_id, state FROM analysis_jobs"
        ).fetchall())
        self.assertEqual(states[rejected["job_id"]], "queued")
        self.assertEqual(states[queued["job_id"]], "queued")

    def test_credential_status_accepts_only_public_safe_states(self):
        # This catches secret-bearing or implementation-specific status values being stored.
        store = AnalysisStore(
            self.analysis_path, "11111111-1111-4111-8111-111111111111", lambda: 1000.0
        )
        self.addCleanup(store.close)
        for status in ("configured", "unconfigured", "unsafe"):
            self.assertEqual(store.refresh_credential(status, None), 0)
            stored = store.connection.execute(
                "SELECT credential_status FROM analysis_worker_state WHERE singleton_id=1"
            ).fetchone()[0]
            self.assertEqual(stored, status)
        with self.assertRaises(ValueError):
            store.refresh_credential("dummy-secret-value", None)
        with self.assertRaises(ValueError):
            store.refresh_credential("configured", "dummy-secret-value")

    def test_empty_window_is_terminally_skipped(self):
        # This catches submitting an empty window to the provider.
        store = AnalysisStore(
            self.analysis_path, "11111111-1111-4111-8111-111111111111", lambda: 1000.0
        )
        self.addCleanup(store.close)
        job = store.ensure_job(AnalysisWindow("daily", 0.0, 86400.0, 87300.0), [])
        self.assertEqual(job["state"], "skipped_empty")
        self.assertIsNone(store.claim_next_job(90000.0))

    def test_recover_interrupted_running_job_requeues_it(self):
        # This catches recovery treating an active worker's claim as interrupted.
        now = [1000.0]
        store = AnalysisStore(
            self.analysis_path, "11111111-1111-4111-8111-111111111111", lambda: now[0]
        )
        self.addCleanup(store.close)
        job = store.ensure_job(AnalysisWindow("six_hour", 0.0, 21600.0, 22200.0), ["event-1"])
        claimed = store.claim_next_job(22200.0)
        self.assertEqual(claimed["job_id"], job["job_id"])
        self.assertIsInstance(claimed["claim_token"], str)
        self.assertEqual(store.recover_interrupted_jobs(), 0)
        now[0] = 1016.0
        self.assertEqual(store.recover_interrupted_jobs(), 1)
        recovered = store.claim_next_job(22200.0)
        self.assertEqual(recovered["job_id"], job["job_id"])

    def test_provider_cooldown_blocks_all_queued_jobs_until_expiry(self):
        # This catches a rate limit only delaying the job that received it.
        store = AnalysisStore(
            self.analysis_path, "11111111-1111-4111-8111-111111111111", lambda: 1000.0
        )
        self.addCleanup(store.close)
        first = store.ensure_job(AnalysisWindow("two_hour", 0.0, 7200.0, 7500.0), ["event-1"])
        second = store.ensure_job(
            AnalysisWindow("six_hour", 0.0, 21600.0, 22200.0), ["event-2"]
        )
        claimed = store.claim_next_job(30000.0)
        store.retry_job(
            claimed, "rate_limited", next_attempt_at=48000.0,
            provider_not_before=48000.0,
        )
        self.assertIsNone(store.claim_next_job(47999.0))
        after_cooldown = store.claim_next_job(48000.0)
        self.assertEqual(after_cooldown["job_id"], second["job_id"])

    def test_stale_claim_cannot_complete_recovered_job_or_insert_result(self):
        # This catches an old worker completing a job after another claim supersedes it.
        now = [1000.0]
        store = AnalysisStore(
            self.analysis_path, "11111111-1111-4111-8111-111111111111", lambda: now[0]
        )
        self.addCleanup(store.close)
        store.ensure_job(AnalysisWindow("two_hour", 0.0, 7200.0, 7500.0), ["event-1"])
        stale = store.claim_next_job(8000.0)
        now[0] = 1016.0
        self.assertEqual(store.recover_interrupted_jobs(), 1)
        current = store.claim_next_job(8000.0)
        self.assertNotEqual(stale["claim_token"], current["claim_token"])
        with self.assertRaises(ValueError):
            store.complete_job(stale, {"summary": "old worker"})
        self.assertEqual(
            store.connection.execute("SELECT COUNT(*) FROM analysis_results").fetchone()[0], 0
        )
        self.assertEqual(
            store.complete_job(current, {"summary": "current worker"})["state"], "succeeded"
        )

    def test_running_transitions_reject_a_job_id_without_its_claim_token(self):
        # This catches a caller bypassing the per-claim fencing token with just a job ID.
        store = AnalysisStore(
            self.analysis_path, "11111111-1111-4111-8111-111111111111", lambda: 1000.0
        )
        self.addCleanup(store.close)
        store.ensure_job(AnalysisWindow("two_hour", 0.0, 7200.0, 7500.0), ["event-1"])
        retry = store.claim_next_job(8000.0)
        with self.assertRaises(ValueError):
            store.retry_job(retry["job_id"], "transport_error", 9000.0)
        with self.assertRaises(ValueError):
            store.credential_required(retry["job_id"])
        with self.assertRaises(ValueError):
            store.fail_job(retry["job_id"])
        with self.assertRaises(ValueError):
            store.complete_job(retry["job_id"], {"summary": "bypass"})


if __name__ == "__main__":
    unittest.main()
