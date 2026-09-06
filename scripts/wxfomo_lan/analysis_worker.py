"""Deterministic orchestration for local rules and scheduled MiniMax analysis."""

import json
import logging
import math
import threading
import time
from collections import namedtuple

from .credentials import CredentialError, load_credential
from .minimax import MiniMaxClient, MiniMaxError
from .deepseek import DeepSeekClient
from .rules import RULE_CATALOG_VERSION, evaluate_message
from .scheduler import latest_due_windows
from .briefing import BriefingError, validate_briefing


RULE_BATCH_SIZE = 200
RETRY_DELAYS = (60.0, 300.0, 900.0, 3600.0)
DEFAULT_RATE_LIMIT_DELAY = 5 * 3600.0
_STABLE_ERROR_CODES = frozenset((
    "credential_unavailable", "rate_limited", "transport_error", "invalid_response",
    "request_invalid", "provider_unavailable",
))
_LOG_FIELDS = frozenset((
    "event", "job_id", "cadence", "source_count", "attempt", "error_code",
    "provider_request_id", "rule_messages_processed", "jobs_created",
    "jobs_completed",
))


WorkerTick = namedtuple(
    "WorkerTick", ("rule_messages_processed", "jobs_created", "jobs_completed")
)


class AnalysisWorker(object):
    """Run rule catch-up, scheduling, and at most one queued analysis per tick."""

    def __init__(
        self,
        source,
        store,
        credentials_path,
        client=None,
        clock=time.time,
        logger=None,
        stop_event=None,
        lease_heartbeat_interval=5.0,
    ):
        self.source = source
        self.store = store
        self.credentials_path = credentials_path
        self.client = client
        self.clock = clock
        self.logger = logger or logging.getLogger(__name__)
        self.stop_event = stop_event or threading.Event()
        self.lease_heartbeat_interval = lease_heartbeat_interval
        self._recovered = False
        self._scheduled_windows = {}

    def _log(self, event, **fields):
        record = {"event": event}
        for name, value in fields.items():
            if name in _LOG_FIELDS and value is not None:
                record[name] = value
        self.logger.info(
            json.dumps(record, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
        )

    def _process_rule_batches(self):
        self.store.prepare_rule_scan(RULE_CATALOG_VERSION)
        processed = 0
        while True:
            rows = self.source.after_row_id(self.store.rule_row_id_cursor(), RULE_BATCH_SIZE)
            if not rows:
                return processed
            messages = [message for unused_row_id, message in rows]
            records = [
                (message, evaluate_message(message.get("content", "")))
                for message in messages
            ]
            # Retain the observed-time watermark for existing diagnostics only.
            # Actual progress follows insertion IDs, including late notifications.
            cursor = max((message["observedAt"], message["eventId"]) for message in messages)
            previous_cursor = self.store.rule_cursor()
            if previous_cursor is not None:
                cursor = max(previous_cursor, cursor)
            self.store.persist_rule_batch(
                records,
                cursor,
                RULE_CATALOG_VERSION,
                row_id=rows[-1][0],
            )
            processed += len(messages)
            if len(messages) < RULE_BATCH_SIZE:
                return processed

    def _schedule_latest_windows(self, timestamp):
        created = 0
        for window in latest_due_windows(timestamp):
            if self._scheduled_windows.get(window.cadence) == window:
                continue
            event_ids = self.source.event_ids_in_window(window.start, window.end)
            job = self.store.ensure_job(window, event_ids)
            self._scheduled_windows[window.cadence] = window
            created += int(job.get("was_created", False))
        return created

    def _load_credential(self):
        try:
            credential = load_credential(self.credentials_path)
        except FileNotFoundError:
            self.store.refresh_credential("unconfigured", None)
            return None, False
        except (CredentialError, OSError):
            self.store.refresh_credential("unsafe", None)
            return None, False
        self.store.refresh_credential("configured", credential.revision)
        blocked = self.store.credential_revision_rejected(credential.revision)
        return credential, blocked

    @staticmethod
    def _stable_error_code(error):
        if error.code in _STABLE_ERROR_CODES:
            return error.code
        return "invalid_response"

    @staticmethod
    def _rate_limit_delay(error):
        delay = error.retry_after
        if (
            isinstance(delay, bool) or not isinstance(delay, (int, float))
            or not math.isfinite(float(delay)) or float(delay) < 0
        ):
            return DEFAULT_RATE_LIMIT_DELAY
        return float(delay)

    def _failure(self, job, error, credential_revision, timestamp):
        # Backoff starts when the request fails, not before a slow provider call.
        timestamp = self.clock()
        code = self._stable_error_code(error)
        if code == "credential_unavailable":
            self.store.credential_required(job, credential_revision, code)
        elif code == "rate_limited":
            delay = self._rate_limit_delay(error)
            retry_at = timestamp + delay
            self.store.retry_job(job, code, retry_at, provider_not_before=retry_at)
        elif error.retryable and code in ("transport_error", "provider_unavailable"):
            delay = RETRY_DELAYS[min(job["attempt"] - 1, len(RETRY_DELAYS) - 1)]
            self.store.retry_job(job, code, timestamp + delay)
        else:
            self.store.fail_job(job, code)
        self._log(
            "job_failed",
            job_id=job["job_id"],
            cadence=job["cadence"],
            source_count=len(job["source_event_ids"]),
            attempt=job["attempt"],
            error_code=code,
        )
        return code

    def _process_one_job(self, timestamp):
        credential, blocked = self._load_credential()
        if blocked:
            return "credential_blocked"
        job = self.store.claim_next_job(timestamp)
        if job is None:
            return None
        if credential is None:
            self.store.credential_required(job, None, "credential_unavailable")
            self._log(
                "job_failed",
                job_id=job["job_id"],
                cadence=job["cadence"],
                source_count=len(job["source_event_ids"]),
                attempt=job["attempt"],
                error_code="credential_unavailable",
            )
            return "credential_unavailable"

        messages = self.source.by_event_ids(job["source_event_ids"])
        if [message["eventId"] for message in messages] != job["source_event_ids"]:
            return self._failure(
                job,
                MiniMaxError("request_invalid", False, None),
                credential.revision,
                timestamp,
            )
        client_type = DeepSeekClient if credential.provider == 'deepseek' else MiniMaxClient
        client = self.client or client_type(credential.api_key)
        try:
            with self.store.lease_guard(self.lease_heartbeat_interval) as lease:
                outcome = client.analyze_window(
                    messages, job["cadence"], job["window_start"], job["window_end"]
                )
                # Legacy decoding remains available to old readers, but a newly
                # completed job must never silently fall back to that template.
                try:
                    validate_briefing(outcome.result.get('briefing'), frozenset(job['source_event_ids']))
                except BriefingError:
                    raise MiniMaxError('invalid_response', False, None)
                lease.check()
        except MiniMaxError as error:
            return self._failure(job, error, credential.revision, timestamp)
        self.store.complete_job(
            job,
            outcome.result,
            model=outcome.model,
            provider_request_id=outcome.provider_request_id,
            input_tokens=outcome.input_tokens,
            output_tokens=outcome.output_tokens,
        )
        self._log(
            "job_succeeded",
            job_id=job["job_id"],
            cadence=job["cadence"],
            source_count=len(job["source_event_ids"]),
            attempt=job["attempt"],
            provider_request_id=outcome.provider_request_id,
        )
        return "succeeded"

    def run_once(self, now=None):
        timestamp = self.clock() if now is None else now
        self.store.heartbeat(timestamp)
        if not self._recovered:
            self.store.recover_interrupted_jobs()
            self._recovered = True
        rule_count = self._process_rule_batches()
        created = self._schedule_latest_windows(timestamp)
        outcome = self._process_one_job(timestamp)
        tick = WorkerTick(rule_count, created, int(outcome == "succeeded"))
        if any(tick):
            self._log(
                "tick_completed",
                rule_messages_processed=tick.rule_messages_processed,
                jobs_created=tick.jobs_created,
                jobs_completed=tick.jobs_completed,
            )
        return tick

    def run_forever(self, poll_interval=1.0):
        if (
            isinstance(poll_interval, bool)
            or not isinstance(poll_interval, (int, float))
            or not math.isfinite(float(poll_interval))
            or float(poll_interval) <= 0
        ):
            raise ValueError("poll interval must be positive and finite")
        interval = float(poll_interval)
        while not self.stop_event.is_set():
            started = self.clock()
            self.run_once()
            elapsed = max(0.0, self.clock() - started)
            self.stop_event.wait(max(0.0, interval - elapsed))
