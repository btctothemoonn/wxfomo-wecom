import contextlib
import importlib.util
import io
import json
import logging
import math
import os
import signal
import sqlite3
import tempfile
import threading
import time
import unittest
from datetime import datetime, timezone
from unittest import mock

from scripts.wxfomo_lan.analysis_source import MessageSource
from scripts.wxfomo_lan.analysis_store import AnalysisStore
from scripts.wxfomo_lan.analysis_worker import AnalysisWorker
from scripts.wxfomo_lan.credentials import save_credential
from scripts.wxfomo_lan.minimax import AnalysisOutcome, MiniMaxError
from scripts.wxfomo_lan.scheduler import AnalysisWindow, latest_due_windows


INSTANCE_ONE = "11111111-1111-4111-8111-111111111111"
INSTANCE_TWO = "22222222-2222-4222-8222-222222222222"


def utc_timestamp(year, month, day, hour, minute):
    return datetime(year, month, day, hour, minute, tzinfo=timezone.utc).timestamp()


class FakeMiniMaxClient(object):
    def __init__(self):
        self.calls = []

    def analyze_window(self, messages, cadence, window_start, window_end):
        self.calls.append({
            "ids": [message["eventId"] for message in messages],
            "cadence": cadence,
            "start": window_start,
            "end": window_end,
        })
        return AnalysisOutcome(
            {
                "summary": "safe summary",
                "summarySourceMessageIDs": [messages[0]["eventId"]],
                "topics": [],
                "findings": [],
                "cryptoAddresses": [],
                "briefing": {
                    "version": 2, "kind": "market",
                    "quick_read": {
                        "focus": {"text": "safe summary", "source_message_ids": [messages[0]['eventId']]},
                        "news": {"text": "未提供", "source_message_ids": []},
                        "risk": {"text": "未提供", "source_message_ids": []},
                    },
                    "projects": [], "events": [], "gaps": [],
                    "business": {"progress": [], "notices": [], "blockers": [], "tasks": []},
                },
            },
            "MiniMax-M2.7",
            "provider-request-1",
            10,
            5,
        )


class RejectingClient(object):
    def __init__(self, code, retryable=False, retry_after=None):
        self.calls = 0
        self.code = code
        self.retryable = retryable
        self.retry_after = retry_after

    def analyze_window(self, messages, cadence, window_start, window_end):
        self.calls += 1
        raise MiniMaxError(self.code, self.retryable, self.retry_after)


class StoppingClient(FakeMiniMaxClient):
    def __init__(self, stop_event):
        super().__init__()
        self.stop_event = stop_event

    def analyze_window(self, messages, cadence, window_start, window_end):
        outcome = super().analyze_window(messages, cadence, window_start, window_end)
        self.stop_event.set()
        return outcome


class BlockingClient(FakeMiniMaxClient):
    def __init__(self, entered, release):
        super().__init__()
        self.entered = entered
        self.release = release

    def analyze_window(self, messages, cadence, window_start, window_end):
        self.entered.set()
        if not self.release.wait(2.0):
            raise AssertionError("test did not release provider")
        return super().analyze_window(messages, cadence, window_start, window_end)


class RecordingSource(object):
    def __init__(self, source):
        self.source = source
        self.after_limits = []

    def after_row_id(self, cursor, limit):
        self.after_limits.append(limit)
        return self.source.after_row_id(cursor, limit)

    def event_ids_in_window(self, start, end):
        return self.source.event_ids_in_window(start, end)

    def by_event_ids(self, ids):
        return self.source.by_event_ids(ids)


class WorkerTests(unittest.TestCase):
    def test_new_job_never_persists_a_legacy_provider_result(self):
        class LegacyClient(FakeMiniMaxClient):
            def analyze_window(self, *args):
                outcome = super().analyze_window(*args)
                outcome.result.pop('briefing', None)
                return outcome
        tick = self.worker(client=LegacyClient(), logger=mock.Mock()).run_once()
        self.assertEqual(tick.jobs_completed, 0)
        self.assertEqual(self.store.connection.execute('SELECT COUNT(*) FROM analysis_results').fetchone()[0], 0)
        self.assertEqual(self.store.connection.execute("SELECT error_code FROM analysis_jobs WHERE state='failed'").fetchone()[0], 'invalid_response')

    def test_retry_wait_starts_after_slow_provider_failure(self):
        clock = self.clock_value
        class SlowFailure:
            def analyze_window(self, *args):
                clock[0] += 90
                raise MiniMaxError('transport_error', True, None)
        self.worker(client=SlowFailure(), logger=mock.Mock()).run_once()
        row = self.store.connection.execute(
            "SELECT next_attempt_at FROM analysis_jobs WHERE state='retry_waiting'"
        ).fetchone()
        self.assertEqual(row[0] - clock[0], 60)

    def test_unchanged_windows_are_not_read_again_but_new_windows_are(self):
        class CountingSource(MessageSource):
            reads = 0
            def event_ids_in_window(self, start, end):
                self.reads += 1
                return super().event_ids_in_window(start, end)
        source = CountingSource(self.message_path)
        worker = self.worker(source=source, client=FakeMiniMaxClient())
        self.assertEqual(worker._schedule_latest_windows(self.now), 3)
        self.assertEqual(worker._schedule_latest_windows(self.now + 60), 0)
        self.assertEqual(source.reads, 3)
        self.assertEqual(worker._schedule_latest_windows(self.now + 21600), 2)
        self.assertEqual(source.reads, 5)

    def test_source_read_releases_database_connection(self):
        source = MessageSource(self.message_path)
        connections = []
        original = source._open
        def capture():
            connection = original()
            connections.append(connection)
            self.addCleanup(connection.close)
            return connection
        source._open = capture
        source.event_ids_in_window(0, self.now)
        with self.assertRaises(sqlite3.ProgrammingError):
            connections[0].execute('SELECT 1')

    def test_idle_ticks_do_not_repeat_logs(self):
        logger = mock.Mock()
        worker = self.worker(client=FakeMiniMaxClient(), logger=logger)
        for _ in range(3):
            worker.run_once()
        logger.reset_mock()
        self.assertEqual(tuple(worker.run_once()), (0, 0, 0))
        logger.info.assert_not_called()

    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.message_path = os.path.join(self.temporary_directory.name, "messages.sqlite3")
        self.analysis_path = os.path.join(
            self.temporary_directory.name, "analysis", "analysis.sqlite3"
        )
        self.credentials_path = os.path.join(
            self.temporary_directory.name, "credentials", "minimax.json"
        )
        self.now = utc_timestamp(2026, 9, 3, 16, 16)
        self.clock_value = [self.now]
        self._create_messages(3)
        save_credential(self.credentials_path, "dummy-worker-key")
        self.store = AnalysisStore(
            self.analysis_path, INSTANCE_ONE, lambda: self.clock_value[0]
        )
        self.addCleanup(self.store.close)

    def _create_messages(self, count):
        connection = sqlite3.connect(self.message_path)
        connection.execute(
            """CREATE TABLE messages(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id TEXT NOT NULL UNIQUE, group_name TEXT NOT NULL,
                sender_display_name TEXT, content TEXT NOT NULL,
                message_type TEXT NOT NULL, observed_at REAL NOT NULL
            )"""
        )
        rows = []
        for index in range(count):
            rows.append((
                "event-{0:03d}".format(index),
                "group",
                "sender",
                "rug message {0}".format(index),
                "text",
                self.now - 1800 + index,
            ))
        connection.executemany(
            "INSERT INTO messages(event_id, group_name, sender_display_name, content, "
            "message_type, observed_at) VALUES (?, ?, ?, ?, ?, ?)", rows
        )
        connection.commit()
        connection.close()

    def worker(self, client=None, credentials_path=None, source=None, logger=None):
        return AnalysisWorker(
            source or MessageSource(self.message_path),
            self.store,
            credentials_path or self.credentials_path,
            client=client,
            clock=lambda: self.clock_value[0],
            logger=logger,
        )

    def job_states(self):
        return [row[0] for row in self.store.connection.execute(
            "SELECT state FROM analysis_jobs ORDER BY window_end, "
            "CASE cadence WHEN 'two_hour' THEN 0 WHEN 'six_hour' THEN 1 ELSE 2 END"
        ).fetchall()]

    def _old_job(self):
        return self.store.ensure_job(
            AnalysisWindow("two_hour", self.now - 10800, self.now - 3600, self.now - 3300),
            ["event-000"],
        )

    def _isolated_old_job(self):
        observed_at = self.now - 100000.0
        connection = sqlite3.connect(self.message_path)
        connection.execute("DELETE FROM messages WHERE event_id<>'event-000'")
        connection.execute(
            "UPDATE messages SET observed_at=? WHERE event_id='event-000'", (observed_at,)
        )
        connection.commit()
        connection.close()
        return self.store.ensure_job(
            AnalysisWindow(
                "two_hour", observed_at - 10.0, observed_at + 10.0, observed_at + 310.0
            ),
            ["event-000"],
        )

    def test_tick_backfills_rules_and_runs_due_jobs_serially(self):
        client = FakeMiniMaxClient()
        tick = self.worker(client=client).run_once()
        self.assertEqual(tick.rule_messages_processed, 3)
        self.assertEqual(tick.jobs_created, 3)
        self.assertEqual(tick.jobs_completed, 1)
        self.assertEqual(self.job_states().count("succeeded"), 1)
        self.assertEqual(self.job_states().count("queued"), 2)
        self.assertEqual(len(client.calls), 1)

    def test_missing_credentials_keeps_rules_and_marks_only_claimed_job(self):
        missing = os.path.join(self.temporary_directory.name, "missing", "key.json")
        tick = self.worker(credentials_path=missing).run_once()
        self.assertEqual(tick.rule_messages_processed, 3)
        self.assertEqual(
            self.job_states(), ["credential_required", "queued", "queued"]
        )
        status = self.store.connection.execute(
            "SELECT credential_status FROM analysis_worker_state WHERE singleton_id=1"
        ).fetchone()[0]
        self.assertEqual(status, "unconfigured")

    def test_unchanged_rejected_credential_is_not_retried(self):
        self._old_job()
        client = RejectingClient("credential_unavailable")
        worker = self.worker(client=client)
        worker.run_once()
        worker.run_once()
        self.assertEqual(client.calls, 1)
        rejected = self.store.connection.execute(
            "SELECT state, credential_file_revision FROM analysis_jobs "
            "WHERE window_end=?", (self.now - 3600,)
        ).fetchone()
        self.assertEqual(rejected[0], "credential_required")
        self.assertTrue(rejected[1])

    def test_missing_then_new_credential_starts_transport_backoff_at_one_minute(self):
        missing = os.path.join(self.temporary_directory.name, "missing", "key.json")
        self.worker(credentials_path=missing).run_once()
        row = self.store.connection.execute(
            "SELECT job_id FROM analysis_jobs WHERE state='credential_required'"
        ).fetchone()
        save_credential(missing, "dummy-new-key")
        self.worker(
            client=RejectingClient("transport_error", True), credentials_path=missing
        ).run_once()
        state = self.store.connection.execute(
            "SELECT attempt, state, next_attempt_at FROM analysis_jobs WHERE job_id=?",
            (row[0],),
        ).fetchone()
        self.assertEqual(state, (1, "retry_waiting", self.now + 60.0))

    def test_rejected_then_revised_credential_starts_transport_backoff_at_one_minute(self):
        self.worker(client=RejectingClient("credential_unavailable")).run_once()
        row = self.store.connection.execute(
            "SELECT job_id FROM analysis_jobs WHERE state='credential_required'"
        ).fetchone()
        save_credential(self.credentials_path, "dummy-revised-key")
        self.worker(client=RejectingClient("provider_unavailable", True)).run_once()
        state = self.store.connection.execute(
            "SELECT attempt, state, next_attempt_at FROM analysis_jobs WHERE job_id=?",
            (row[0],),
        ).fetchone()
        self.assertEqual(state, (1, "retry_waiting", self.now + 60.0))

    def test_changed_credential_revision_requeues_rejected_job(self):
        job = self._old_job()
        rejected = RejectingClient("credential_unavailable")
        self.worker(client=rejected).run_once()
        save_credential(self.credentials_path, "dummy-replacement-key")
        succeeding = FakeMiniMaxClient()
        tick = self.worker(client=succeeding).run_once()
        self.assertEqual(tick.jobs_completed, 1)
        self.assertEqual(len(succeeding.calls), 1)
        state = self.store.connection.execute(
            "SELECT state FROM analysis_jobs WHERE job_id=?", (job["job_id"],)
        ).fetchone()[0]
        self.assertEqual(state, "succeeded")

    def test_multi_day_gap_creates_only_latest_window_for_each_cadence(self):
        client = FakeMiniMaxClient()
        self.worker(client=client).run_once(now=self.now + 7 * 86400)
        rows = self.store.connection.execute(
            "SELECT cadence, window_start, window_end FROM analysis_jobs"
        ).fetchall()
        expected = latest_due_windows(self.now + 7 * 86400)
        self.assertEqual(len(rows), 3)
        self.assertEqual(
            set(rows), set((window.cadence, window.start, window.end) for window in expected)
        )

    def test_empty_windows_are_persisted_without_provider_calls(self):
        connection = sqlite3.connect(self.message_path)
        connection.execute("DELETE FROM messages")
        connection.commit()
        connection.close()
        client = FakeMiniMaxClient()
        tick = self.worker(client=client).run_once()
        self.assertEqual(tick.jobs_created, 3)
        self.assertEqual(self.job_states(), ["skipped_empty"] * 3)
        self.assertEqual(client.calls, [])

    def test_first_tick_recovers_a_claim_from_an_expired_process(self):
        old_job = self._old_job()
        stale_claim = self.store.claim_next_job(self.now)
        self.assertEqual(stale_claim["job_id"], old_job["job_id"])
        self.store.close()
        self.clock_value[0] += 16
        replacement = AnalysisStore(
            self.analysis_path, INSTANCE_TWO, lambda: self.clock_value[0]
        )
        self.store = replacement
        self.addCleanup(replacement.close)
        tick = self.worker(client=FakeMiniMaxClient()).run_once()
        self.assertEqual(tick.jobs_completed, 1)
        state = replacement.connection.execute(
            "SELECT state FROM analysis_jobs WHERE job_id=?", (old_job["job_id"],)
        ).fetchone()[0]
        self.assertEqual(state, "succeeded")

    def test_provider_call_renews_lease_on_an_independent_connection(self):
        self.store.close()
        entered = threading.Event()
        release = threading.Event()
        old_client = BlockingClient(entered, release)
        old_errors = []

        def run_old_worker():
            store = AnalysisStore(self.analysis_path, INSTANCE_ONE, lambda: self.clock_value[0])
            try:
                worker = AnalysisWorker(
                    MessageSource(self.message_path),
                    store,
                    self.credentials_path,
                    client=old_client,
                    clock=lambda: self.clock_value[0],
                    lease_heartbeat_interval=0.01,
                )
                worker.run_once()
            except Exception as error:
                old_errors.append(error)
            finally:
                store.close()

        thread = threading.Thread(target=run_old_worker)
        thread.start()
        self.assertTrue(entered.wait(1.0))
        self.clock_value[0] += 16.0
        deadline = time.monotonic() + 1.0
        heartbeat = None
        while time.monotonic() < deadline:
            observer = sqlite3.connect(self.analysis_path)
            heartbeat = observer.execute(
                "SELECT heartbeat_at FROM analysis_worker_state WHERE singleton_id=1"
            ).fetchone()[0]
            observer.close()
            if heartbeat == self.clock_value[0]:
                break
            threading.Event().wait(0.005)
        self.assertEqual(heartbeat, self.clock_value[0])

        second_client = FakeMiniMaxClient()
        second_store = AnalysisStore(
            self.analysis_path, INSTANCE_TWO, lambda: self.clock_value[0]
        )
        try:
            second_worker = AnalysisWorker(
                MessageSource(self.message_path),
                second_store,
                self.credentials_path,
                client=second_client,
                clock=lambda: self.clock_value[0],
                lease_heartbeat_interval=0.01,
            )
            with self.assertRaises(RuntimeError):
                second_worker.run_once()
        finally:
            second_store.close()
            release.set()
            thread.join(2.0)
        self.assertFalse(thread.is_alive())
        self.assertEqual(old_errors, [])
        self.assertEqual(len(old_client.calls), 1)
        self.assertEqual(second_client.calls, [])

    def test_lost_provider_lease_prevents_result_write_and_leaks_no_details(self):
        self.store.close()
        entered = threading.Event()
        release = threading.Event()
        client = BlockingClient(entered, release)
        errors = []
        stream = io.StringIO()
        logger = logging.getLogger("wxfomo-lost-lease-{0}".format(id(self)))
        logger.handlers = []
        logger.propagate = False
        logger.setLevel(logging.INFO)
        logger.addHandler(logging.StreamHandler(stream))

        def run_worker():
            store = AnalysisStore(self.analysis_path, INSTANCE_ONE, lambda: self.clock_value[0])
            try:
                AnalysisWorker(
                    MessageSource(self.message_path),
                    store,
                    self.credentials_path,
                    client=client,
                    clock=lambda: self.clock_value[0],
                    logger=logger,
                    lease_heartbeat_interval=0.005,
                ).run_once()
            except Exception as error:
                errors.append(error)
            finally:
                store.close()

        thread = threading.Thread(target=run_worker)
        thread.start()
        self.assertTrue(entered.wait(1.0))
        takeover = sqlite3.connect(self.analysis_path)
        takeover.execute(
            "UPDATE analysis_worker_state SET instance_id=?, "
            "lease_generation=lease_generation+1 WHERE singleton_id=1",
            (INSTANCE_TWO,),
        )
        takeover.commit()
        takeover.close()
        threading.Event().wait(0.03)
        release.set()
        thread.join(2.0)

        self.assertFalse(thread.is_alive())
        self.assertEqual(len(errors), 1)
        self.assertIsInstance(errors[0], RuntimeError)
        connection = sqlite3.connect(self.analysis_path)
        result_count = connection.execute("SELECT COUNT(*) FROM analysis_results").fetchone()[0]
        running_count = connection.execute(
            "SELECT COUNT(*) FROM analysis_jobs WHERE state='running'"
        ).fetchone()[0]
        connection.close()
        self.assertEqual((result_count, running_count), (0, 1))
        for sensitive in ("dummy-worker-key", "rug message", "header", "body", "content"):
            self.assertNotIn(sensitive, stream.getvalue())

    def test_rate_limit_blocks_every_job_until_global_cooldown_expires(self):
        self._old_job()
        client = RejectingClient("rate_limited", True, 18000.0)
        worker = self.worker(client=client)
        worker.run_once()
        worker.run_once(now=self.now + 17999.0)
        self.assertEqual(client.calls, 1)
        not_before = self.store.connection.execute(
            "SELECT provider_not_before FROM analysis_worker_state WHERE singleton_id=1"
        ).fetchone()[0]
        self.assertEqual(not_before, self.now + 18000.0)

    def test_retryable_failures_use_bounded_backoff_and_stop_after_five_attempts(self):
        job = self._isolated_old_job()
        client = RejectingClient("transport_error", True)
        worker = self.worker(client=client)
        expected_delays = [60.0, 300.0, 900.0, 3600.0]
        for expected_delay in expected_delays:
            worker.run_once(now=self.clock_value[0])
            row = self.store.connection.execute(
                "SELECT state, next_attempt_at FROM analysis_jobs WHERE job_id=?",
                (job["job_id"],),
            ).fetchone()
            self.assertEqual(row, ("retry_waiting", self.clock_value[0] + expected_delay))
            self.clock_value[0] += expected_delay
        worker.run_once(now=self.clock_value[0])
        row = self.store.connection.execute(
            "SELECT state, attempt, error_code FROM analysis_jobs WHERE job_id=?",
            (job["job_id"],),
        ).fetchone()
        self.assertEqual(row, ("failed", 5, "transport_error"))
        self.assertEqual(client.calls, 5)

    def test_nonretryable_request_failure_is_permanent(self):
        job = self._old_job()
        client = RejectingClient("request_invalid", False)
        self.worker(client=client).run_once()
        row = self.store.connection.execute(
            "SELECT state, attempt, error_code FROM analysis_jobs WHERE job_id=?",
            (job["job_id"],),
        ).fetchone()
        self.assertEqual(row, ("failed", 1, "request_invalid"))
        self.assertEqual(client.calls, 1)

    def test_rule_scan_uses_two_hundred_message_batches_until_caught_up(self):
        connection = sqlite3.connect(self.message_path)
        rows = [(
            "bulk-{0:03d}".format(index), "group", "sender", "plain", "text",
            self.now - 4000 + index,
        ) for index in range(205)]
        connection.executemany(
            "INSERT INTO messages(event_id, group_name, sender_display_name, content, "
            "message_type, observed_at) VALUES (?, ?, ?, ?, ?, ?)", rows
        )
        connection.commit()
        connection.close()
        source = RecordingSource(MessageSource(self.message_path))
        tick = self.worker(client=FakeMiniMaxClient(), source=source).run_once()
        self.assertEqual(tick.rule_messages_processed, 208)
        self.assertTrue(source.after_limits)
        self.assertEqual(set(source.after_limits), {200})
        self.assertEqual(self.store.rule_cursor()[1], "event-002")

    def test_late_insert_gets_rules_without_changing_frozen_windows(self):
        # An earlier deliveredAt must not hide a newly inserted risk notification.
        worker = self.worker(client=FakeMiniMaxClient())
        worker.run_once()
        with sqlite3.connect(self.message_path) as connection:
            connection.execute(
                "INSERT INTO messages(event_id, group_name, sender_display_name, content, "
                "message_type, observed_at) VALUES (?, ?, ?, ?, ?, ?)",
                ("late-event", "group", "sender", "rug", "text", self.now - 2000),
            )
        tick = worker.run_once()
        self.assertEqual(tick.rule_messages_processed, 1)
        self.assertEqual(self.store.connection.execute(
            "SELECT priority FROM message_rule_matches WHERE event_id='late-event'"
        ).fetchall(), [(50,)])
        self.assertEqual(self.store.connection.execute(
            "SELECT severity FROM rule_alerts WHERE event_id='late-event'"
        ).fetchall(), [("critical",)])
        self.assertTrue(all("late-event" not in json.loads(row[0]) for row in
                            self.store.connection.execute(
                                "SELECT source_event_ids_json FROM analysis_jobs")))
        self.assertEqual(set(MessageSource(self.message_path).by_event_ids(["late-event"])[0]),
                         {"eventId", "groupName", "senderDisplayName", "content",
                          "messageType", "observedAt"})

    def test_restart_processes_late_insert_once_and_preserves_existing_alerts(self):
        # Persisted insertion progress must survive a real store close/reopen.
        self.worker(client=FakeMiniMaxClient()).run_once()
        original_alerts = self.store.connection.execute(
            "SELECT alert_id, event_id FROM rule_alerts ORDER BY alert_id"
        ).fetchall()
        self.store.close()
        with sqlite3.connect(self.message_path) as connection:
            connection.execute(
                "INSERT INTO messages(event_id, group_name, sender_display_name, content, "
                "message_type, observed_at) VALUES (?, ?, ?, ?, ?, ?)",
                ("late-after-restart", "group", "sender", "rug", "text", self.now - 2000),
            )
        self.store = AnalysisStore(self.analysis_path, INSTANCE_ONE,
                                   lambda: self.clock_value[0])
        self.addCleanup(self.store.close)
        worker = self.worker(client=FakeMiniMaxClient())
        self.assertEqual(worker.run_once().rule_messages_processed, 1)
        self.assertEqual(worker.run_once().rule_messages_processed, 0)
        self.assertEqual(self.store.connection.execute(
            "SELECT alert_id, event_id FROM rule_alerts WHERE event_id<>'late-after-restart' "
            "ORDER BY alert_id"
        ).fetchall(), original_alerts)
        self.assertEqual(self.store.connection.execute(
            "SELECT COUNT(*) FROM rule_alerts WHERE event_id='late-after-restart'"
        ).fetchone()[0], 1)

    def test_disappeared_frozen_message_fails_without_substituting_source(self):
        job = self._old_job()
        connection = sqlite3.connect(self.message_path)
        connection.execute("DELETE FROM messages WHERE event_id='event-000'")
        connection.commit()
        connection.close()
        client = FakeMiniMaxClient()
        self.worker(client=client).run_once()
        row = self.store.connection.execute(
            "SELECT state, source_event_ids_json, error_code FROM analysis_jobs WHERE job_id=?",
            (job["job_id"],),
        ).fetchone()
        self.assertEqual(row, ("failed", '["event-000"]', "request_invalid"))
        self.assertEqual(client.calls, [])

    def test_logs_contain_only_stable_fields_and_no_sensitive_values(self):
        stream = io.StringIO()
        logger = logging.getLogger("wxfomo-worker-test-{0}".format(id(self)))
        logger.handlers = []
        logger.propagate = False
        logger.setLevel(logging.INFO)
        logger.addHandler(logging.StreamHandler(stream))
        self.worker(client=FakeMiniMaxClient(), logger=logger).run_once()
        output = stream.getvalue()
        self.assertIn("provider-request-1", output)
        for sensitive in ("dummy-worker-key", "rug message", "X-Api-Key", "content"):
            self.assertNotIn(sensitive, output)

    def test_forever_loop_stops_cleanly_after_signal_event(self):
        stop_event = threading.Event()
        client = StoppingClient(stop_event)
        worker = AnalysisWorker(
            MessageSource(self.message_path),
            self.store,
            self.credentials_path,
            client=client,
            clock=lambda: self.clock_value[0],
            stop_event=stop_event,
        )
        worker.run_forever(1.0)
        self.assertEqual(len(client.calls), 1)
        self.assertEqual(self.job_states().count("succeeded"), 1)


def _load_cli_module():
    path = os.path.join(os.path.dirname(__file__), "wxfomo-analysis-worker.py")
    spec = importlib.util.spec_from_file_location("wxfomo_analysis_worker_cli", path)
    module = importlib.util.module_from_spec(spec)
    script_directory = os.path.dirname(path)
    sys_path = list(os.sys.path)
    os.sys.path.insert(0, script_directory)
    try:
        spec.loader.exec_module(module)
    finally:
        os.sys.path[:] = sys_path
    return module


class WorkerCLITests(unittest.TestCase):
    def test_cli_rejects_invalid_uuid_and_nonpositive_or_nonfinite_interval(self):
        cli = _load_cli_module()
        cases = [
            ["--instance-id", "not-a-uuid", "--once"],
            ["--instance-id", INSTANCE_ONE, "--poll-interval", "0", "--once"],
            ["--instance-id", INSTANCE_ONE, "--poll-interval", "nan", "--once"],
            ["--instance-id", INSTANCE_ONE, "--poll-interval", str(math.inf), "--once"],
        ]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                with contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as raised:
                        cli.parse_options(arguments)
                self.assertEqual(raised.exception.code, 2)

    def test_once_executes_exactly_one_tick_and_closes_store(self):
        cli = _load_cli_module()
        calls = []

        class FakeStore(object):
            def __init__(self, path, instance_id, clock):
                calls.append(("store", path, instance_id))

            def close(self):
                calls.append(("close",))

        class FakeWorker(object):
            def __init__(self, source, store, credentials_path, clock, logger, stop_event):
                calls.append(("worker", credentials_path))

            def run_once(self):
                calls.append(("once",))

            def run_forever(self, poll_interval):
                calls.append(("forever", poll_interval))

        with mock.patch.object(cli, "AnalysisStore", FakeStore), mock.patch.object(
            cli, "MessageSource", lambda path: ("source", path)
        ), mock.patch.object(cli, "AnalysisWorker", FakeWorker):
            self.assertEqual(cli.main([
                "--message-database", "/tmp/messages",
                "--analysis-database", "/tmp/analysis",
                "--credentials", "/tmp/credentials",
                "--instance-id", INSTANCE_ONE,
                "--once",
            ]), 0)
        self.assertEqual([item[0] for item in calls].count("once"), 1)
        self.assertNotIn("forever", [item[0] for item in calls])
        self.assertEqual(calls[-1], ("close",))

    def test_signal_handler_requests_clean_loop_exit(self):
        cli = _load_cli_module()
        handlers = {}
        event = threading.Event()
        with mock.patch.object(
            cli.signal, "signal", side_effect=lambda number, handler: handlers.setdefault(number, handler)
        ):
            cli.install_signal_handlers(event)
        handlers[signal.SIGTERM](signal.SIGTERM, None)
        self.assertTrue(event.is_set())

    def test_storage_database_error_exits_nonzero_without_exception_details(self):
        cli = _load_cli_module()
        output = io.StringIO()
        with mock.patch.object(
            cli, "AnalysisStore", side_effect=sqlite3.DatabaseError("secret schema body")
        ), contextlib.redirect_stderr(output):
            result = cli.main([
                "--instance-id", INSTANCE_ONE,
                "--message-database", "/tmp/messages",
                "--analysis-database", "/tmp/analysis",
                "--credentials", "/tmp/credentials",
                "--once",
            ])
        self.assertEqual(result, 1)
        self.assertNotIn("secret schema body", output.getvalue())


if __name__ == "__main__":
    unittest.main()
