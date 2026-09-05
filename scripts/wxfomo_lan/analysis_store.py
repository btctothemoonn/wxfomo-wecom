"""Private, single-writer SQLite persistence for local message analysis."""

import contextlib
import json
import math
import os
import sqlite3
import stat
import threading
import uuid

from .rules import RULE_CATALOG


LEASE_SECONDS = 15.0
MAXIMUM_ATTEMPTS = 5
_CADENCE_RANK = {"two_hour": 0, "six_hour": 1, "daily": 2}
_STABLE_ERROR_CODES = frozenset((
    "credential_unavailable", "rate_limited", "transport_error", "invalid_response",
    "request_invalid", "provider_unavailable",
))
_CREDENTIAL_STATUSES = frozenset(("configured", "unconfigured", "unsafe"))
_RULES_BY_ID = {rule["ruleId"]: rule for rule in RULE_CATALOG}


class _LeaseGuard(object):
    """Renew one writer lease without sharing the store's SQLite connection."""

    def __init__(self, path, instance_id, lease_generation, clock, interval):
        self.path = path
        self.instance_id = instance_id
        self.lease_generation = lease_generation
        self.clock = clock
        self.interval = interval
        self._ready = threading.Event()
        self._stop = threading.Event()
        self._lost = threading.Event()
        self._thread = None

    def _renew(self, connection):
        now = self.clock()
        if isinstance(now, bool):
            raise RuntimeError("analysis writer lease renewal failed")
        try:
            now = float(now)
        except (TypeError, ValueError):
            raise RuntimeError("analysis writer lease renewal failed")
        if not math.isfinite(now):
            raise RuntimeError("analysis writer lease renewal failed")
        connection.execute("BEGIN IMMEDIATE")
        updated = connection.execute(
            "UPDATE analysis_worker_state SET heartbeat_at=?, updated_at=? "
            "WHERE singleton_id=1 AND instance_id=? AND lease_generation=?",
            (now, now, self.instance_id, self.lease_generation),
        )
        if updated.rowcount != 1:
            connection.rollback()
            raise RuntimeError("analysis writer lease was lost")
        connection.commit()

    def _run(self):
        connection = None
        try:
            connection = sqlite3.connect(self.path, timeout=0.25)
            self._renew(connection)
        except Exception:
            if connection is not None and connection.in_transaction:
                connection.rollback()
            self._lost.set()
        finally:
            self._ready.set()
        try:
            while not self._lost.is_set() and not self._stop.wait(self.interval):
                try:
                    self._renew(connection)
                except Exception:
                    if connection is not None and connection.in_transaction:
                        connection.rollback()
                    self._lost.set()
        finally:
            if connection is not None:
                connection.close()

    def __enter__(self):
        self._thread = threading.Thread(target=self._run)
        self._thread.daemon = True
        self._thread.start()
        if not self._ready.wait(1.0):
            self._lost.set()
        self.check()
        return self

    def check(self):
        if self._lost.is_set():
            raise RuntimeError("analysis writer lease renewal failed")

    def __exit__(self, error_type, unused_error, unused_traceback):
        self._stop.set()
        if self._thread is not None:
            self._thread.join(1.0)
            if self._thread.is_alive():
                self._lost.set()
        if error_type is None:
            self.check()
        return False


class AnalysisStore(object):
    """Owns the versioned analysis database; it never opens messages.sqlite3."""

    def __init__(self, path, instance_id, clock):
        self.path = os.path.abspath(path)
        self.instance_id = instance_id
        self.clock = clock
        self._lease_generation = None
        self._parent_fd = None
        self._parent_fd, database_name, database_identity = self._prepare_database_file()
        try:
            self.connection = sqlite3.connect(self.path, timeout=0.25)
            opened_stat = os.lstat(self.path)
            descriptor_stat = os.stat(
                database_name, dir_fd=self._parent_fd, follow_symlinks=False
            )
            if (
                not stat.S_ISREG(opened_stat.st_mode)
                or opened_stat.st_nlink != 1
                or (opened_stat.st_dev, opened_stat.st_ino) != database_identity
                or (descriptor_stat.st_dev, descriptor_stat.st_ino) != database_identity
            ):
                raise RuntimeError("analysis database changed while opening")
            self.connection.execute("PRAGMA foreign_keys=ON")
            self._create_schema()
        except Exception:
            if getattr(self, "connection", None) is not None:
                self.connection.close()
                self.connection = None
            os.close(self._parent_fd)
            self._parent_fd = None
            raise

    def _prepare_database_file(self):
        parent = os.path.dirname(self.path)
        try:
            os.mkdir(parent, 0o700)
        except FileNotFoundError:
            os.makedirs(parent, mode=0o700)
        except FileExistsError:
            pass
        parent_stat = os.lstat(parent)
        if (
            stat.S_ISLNK(parent_stat.st_mode) or not stat.S_ISDIR(parent_stat.st_mode)
            or parent_stat.st_uid != os.geteuid()
            or stat.S_IMODE(parent_stat.st_mode) != 0o700
        ):
            raise RuntimeError("analysis parent must be an owned 0700 real directory")
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        parent_fd = os.open(parent, flags)
        try:
            current_parent = os.fstat(parent_fd)
            if (
                not stat.S_ISDIR(current_parent.st_mode)
                or current_parent.st_uid != os.geteuid()
                or stat.S_IMODE(current_parent.st_mode) != 0o700
            ):
                raise RuntimeError("analysis parent changed while opening")
            database_name = os.path.basename(self.path)
            try:
                database_stat = os.stat(
                    database_name, dir_fd=parent_fd, follow_symlinks=False
                )
                exists = True
            except FileNotFoundError:
                exists = False
                open_flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
                open_flags |= getattr(os, "O_NOFOLLOW", 0)
                descriptor = os.open(database_name, open_flags, 0o600, dir_fd=parent_fd)
                try:
                    database_stat = os.fstat(descriptor)
                    os.fchmod(descriptor, 0o600)
                finally:
                    os.close(descriptor)
            if (
                not stat.S_ISREG(database_stat.st_mode)
                or database_stat.st_nlink != 1
                or (exists and (
                    database_stat.st_uid != os.geteuid()
                    or stat.S_IMODE(database_stat.st_mode) != 0o600
                ))
            ):
                raise RuntimeError("analysis database must be an owned 0600 single-link regular file")
            return parent_fd, database_name, (database_stat.st_dev, database_stat.st_ino)
        except Exception:
            os.close(parent_fd)
            raise

    def _create_schema(self):
        now = self.clock()
        with self.connection:
            self.connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS analysis_schema_migrations(
                  version INTEGER PRIMARY KEY,
                  applied_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS analysis_worker_state(
                  singleton_id INTEGER PRIMARY KEY CHECK(singleton_id = 1),
                  instance_id TEXT,
                  heartbeat_at REAL,
                  rule_cursor_time REAL,
                  rule_cursor_event_id TEXT,
                  rule_cursor_row_id INTEGER NOT NULL DEFAULT 0,
                  rule_catalog_version INTEGER,
                  provider_not_before REAL,
                  credential_status TEXT,
                  last_provider_success_at REAL,
                  last_error_code TEXT,
                  lease_generation INTEGER NOT NULL DEFAULT 0,
                  updated_at REAL NOT NULL,
                  CHECK ((rule_cursor_time IS NULL) = (rule_cursor_event_id IS NULL))
                );
                CREATE TABLE IF NOT EXISTS message_rule_matches(
                  event_id TEXT NOT NULL,
                  rule_id TEXT NOT NULL,
                  priority INTEGER NOT NULL,
                  severity TEXT,
                  tags_json TEXT NOT NULL,
                  matched_terms_json TEXT NOT NULL,
                  created_at REAL NOT NULL,
                  UNIQUE(event_id, rule_id)
                );
                CREATE TABLE IF NOT EXISTS rule_alerts(
                  alert_id INTEGER PRIMARY KEY AUTOINCREMENT,
                  event_id TEXT NOT NULL,
                  rule_id TEXT NOT NULL,
                  severity TEXT NOT NULL,
                  title TEXT NOT NULL,
                  occurrence_count INTEGER NOT NULL DEFAULT 1,
                  created_at REAL NOT NULL,
                  updated_at REAL NOT NULL,
                  UNIQUE(event_id, rule_id)
                );
                CREATE TABLE IF NOT EXISTS analysis_jobs(
                  job_id TEXT PRIMARY KEY,
                  cadence TEXT NOT NULL,
                  window_start REAL NOT NULL,
                  window_end REAL NOT NULL,
                  state TEXT NOT NULL,
                  source_event_ids_json TEXT NOT NULL,
                  attempt INTEGER NOT NULL DEFAULT 0,
                  maximum_attempts INTEGER NOT NULL,
                  next_attempt_at REAL,
                  error_code TEXT,
                  credential_file_revision TEXT,
                  claim_token TEXT,
                  claim_owner TEXT,
                  claim_lease_generation INTEGER,
                  created_at REAL NOT NULL,
                  updated_at REAL NOT NULL,
                  UNIQUE(cadence, window_start, window_end)
                );
                CREATE TABLE IF NOT EXISTS analysis_results(
                  analysis_id INTEGER PRIMARY KEY AUTOINCREMENT,
                  job_id TEXT NOT NULL,
                  result_json TEXT NOT NULL,
                  model TEXT,
                  provider_request_id TEXT,
                  input_tokens INTEGER,
                  output_tokens INTEGER,
                  created_at REAL NOT NULL,
                  updated_at REAL NOT NULL,
                  UNIQUE(job_id),
                  FOREIGN KEY(job_id) REFERENCES analysis_jobs(job_id) ON DELETE CASCADE
                );
                """
            )
            self.connection.execute(
                "INSERT OR IGNORE INTO analysis_schema_migrations(version, applied_at) "
                "VALUES (?, ?)", (1, now)
            )
            self.connection.execute(
                "INSERT OR IGNORE INTO analysis_worker_state(singleton_id, updated_at) "
                "VALUES (1, ?)", (now,)
            )
            columns = {
                row[1] for row in self.connection.execute(
                    "PRAGMA table_info(analysis_worker_state)"
                ).fetchall()
            }
            if "lease_generation" not in columns:
                self.connection.execute(
                    "ALTER TABLE analysis_worker_state ADD COLUMN "
                    "lease_generation INTEGER NOT NULL DEFAULT 0"
                )
            if "rule_cursor_row_id" not in columns:
                # The old observed-time watermark cannot identify late inserts.
                # Begin a safe replay rather than infer an insertion position.
                self.connection.execute(
                    "ALTER TABLE analysis_worker_state ADD COLUMN "
                    "rule_cursor_row_id INTEGER NOT NULL DEFAULT 0"
                )
            job_columns = {
                row[1] for row in self.connection.execute(
                    "PRAGMA table_info(analysis_jobs)"
                ).fetchall()
            }
            for column, declaration in (
                    ("claim_token", "TEXT"),
                    ("claim_owner", "TEXT"),
                    ("claim_lease_generation", "INTEGER")):
                if column not in job_columns:
                    self.connection.execute(
                        "ALTER TABLE analysis_jobs ADD COLUMN %s %s" % (column, declaration)
                    )
            self.connection.execute(
                "INSERT OR IGNORE INTO analysis_schema_migrations(version, applied_at) "
                "VALUES (?, ?)", (2, now)
            )
            self.connection.execute(
                "INSERT OR IGNORE INTO analysis_schema_migrations(version, applied_at) "
                "VALUES (?, ?)", (3, now)
            )

    @staticmethod
    def _json(value):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))

    @staticmethod
    def _finite_timestamp(value, name):
        if isinstance(value, bool):
            raise ValueError("%s must be a finite timestamp" % name)
        try:
            value = float(value)
        except (TypeError, ValueError):
            raise ValueError("%s must be a finite timestamp" % name)
        if not math.isfinite(value):
            raise ValueError("%s must be a finite timestamp" % name)
        return value

    @staticmethod
    def _claim(job, claim_token=None):
        if isinstance(job, dict):
            if claim_token is None:
                claim_token = job.get("claim_token")
            job = job.get("job_id")
        if not isinstance(job, str) or not job:
            raise ValueError("job ID is required")
        if not isinstance(claim_token, str) or not claim_token:
            raise ValueError("running job claim token is required")
        return job, claim_token

    @staticmethod
    def _error_code(error_code):
        if error_code not in _STABLE_ERROR_CODES:
            raise ValueError("error code is not stable")
        return error_code

    @staticmethod
    def _credential_revision(revision):
        if revision is not None and (
                not isinstance(revision, str) or not revision
                or len(revision) > 256):
            raise ValueError("credential revision must be a safe string")
        if revision is not None:
            parts = revision.split(":")
            if len(parts) != 4 or any(
                    not part.isdigit() or str(int(part)) != part for part in parts):
                raise ValueError("credential revision must be safe file metadata")
        return revision

    @staticmethod
    def _frozen_event_ids(source_event_ids):
        if not isinstance(source_event_ids, (list, tuple)):
            raise ValueError("source event IDs must be a list or tuple")
        event_ids = list(source_event_ids)
        if any(not isinstance(event_id, str) or not event_id for event_id in event_ids):
            raise ValueError("source event IDs must be non-empty strings")
        if len(set(event_ids)) != len(event_ids):
            raise ValueError("source event IDs must be unique")
        return event_ids

    @staticmethod
    def _job_from_row(row):
        if row is None:
            return None
        return {
            "job_id": row[0], "cadence": row[1], "window_start": row[2],
            "window_end": row[3], "state": row[4],
            "source_event_ids": json.loads(row[5]), "attempt": row[6],
            "maximum_attempts": row[7], "next_attempt_at": row[8],
            "error_code": row[9], "credential_file_revision": row[10],
            "created_at": row[11], "updated_at": row[12],
            "claim_token": row[13], "claim_owner": row[14],
            "claim_lease_generation": row[15],
        }

    def _job_row(self, job_id):
        return self.connection.execute(
            "SELECT job_id, cadence, window_start, window_end, state, "
            "source_event_ids_json, attempt, maximum_attempts, next_attempt_at, "
            "error_code, credential_file_revision, created_at, updated_at, "
            "claim_token, claim_owner, claim_lease_generation "
            "FROM analysis_jobs WHERE job_id=?", (job_id,)
        ).fetchone()

    def _require_running_claim(self, job_id, claim_token):
        row = self.connection.execute(
            "SELECT attempt, maximum_attempts FROM analysis_jobs "
            "WHERE job_id=? AND state='running' AND claim_token=?", (job_id, claim_token)
        ).fetchone()
        if row is None:
            raise ValueError("job claim was lost")
        return row

    def ensure_job(self, window, source_event_ids):
        """Persist one immutable source snapshot for an aligned window."""
        cadence = getattr(window, "cadence", None)
        if cadence not in _CADENCE_RANK:
            raise ValueError("unknown cadence")
        start = self._finite_timestamp(getattr(window, "start", None), "window start")
        end = self._finite_timestamp(getattr(window, "end", None), "window end")
        due_at = self._finite_timestamp(getattr(window, "due_at", None), "window due_at")
        if start >= end or due_at < end:
            raise ValueError("invalid analysis window")
        event_ids = self._frozen_event_ids(source_event_ids)
        with self._writer_transaction():
            was_created = False
            existing = self.connection.execute(
                "SELECT job_id FROM analysis_jobs WHERE cadence=? AND window_start=? "
                "AND window_end=?", (cadence, start, end)
            ).fetchone()
            if existing is None:
                was_created = True
                now = self.clock()
                state = "queued" if event_ids else "skipped_empty"
                self.connection.execute(
                    "INSERT INTO analysis_jobs(job_id, cadence, window_start, window_end, "
                    "state, source_event_ids_json, maximum_attempts, next_attempt_at, "
                    "created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (str(uuid.uuid4()), cadence, start, end, state, self._json(event_ids),
                     MAXIMUM_ATTEMPTS, due_at if event_ids else None, now, now),
                )
                existing = self.connection.execute(
                    "SELECT job_id FROM analysis_jobs WHERE cadence=? AND window_start=? "
                    "AND window_end=?", (cadence, start, end)
                ).fetchone()
            job = self._job_from_row(self._job_row(existing[0]))
            job["was_created"] = was_created
            return job

    def refresh_credential(self, status, revision):
        """Record public credential state and wake jobs only for a new safe revision."""
        if status not in _CREDENTIAL_STATUSES:
            raise ValueError("credential status is not public and stable")
        revision = self._credential_revision(revision)
        with self._writer_transaction():
            now = self.clock()
            requeued = 0
            if revision is not None:
                updated = self.connection.execute(
                    "UPDATE analysis_jobs SET state='queued', attempt=0, next_attempt_at=NULL, "
                    "error_code=NULL, credential_file_revision=NULL, updated_at=? "
                    "WHERE state='credential_required' AND "
                    "(credential_file_revision IS NULL OR credential_file_revision<>?)",
                    (now, revision),
                )
                requeued = updated.rowcount
            self.connection.execute(
                "UPDATE analysis_worker_state SET credential_status=?, updated_at=? "
                "WHERE singleton_id=1", (status, now),
            )
            return requeued

    def credential_revision_rejected(self, revision):
        """Return whether this exact safe file revision is awaiting replacement."""
        revision = self._credential_revision(revision)
        if revision is None:
            return False
        row = self.connection.execute(
            "SELECT 1 FROM analysis_jobs WHERE state='credential_required' "
            "AND credential_file_revision=? LIMIT 1", (revision,)
        ).fetchone()
        return row is not None

    def lease_guard(self, interval=5.0):
        """Return a provider-operation guard backed by an independent connection."""
        if (
            isinstance(interval, bool) or not isinstance(interval, (int, float))
            or not math.isfinite(float(interval)) or float(interval) <= 0
            or float(interval) >= LEASE_SECONDS
        ):
            raise ValueError("lease heartbeat interval must be below the lease duration")
        if self._lease_generation is None:
            self.acquire()
        return _LeaseGuard(
            self.path,
            self.instance_id,
            self._lease_generation,
            self.clock,
            float(interval),
        )

    def recover_interrupted_jobs(self):
        """Return only claims whose owner lease has expired to the queue."""
        with self._writer_transaction():
            now = self.clock()
            updated = self.connection.execute(
                "UPDATE analysis_jobs SET state='queued', next_attempt_at=NULL, "
                "claim_token=NULL, claim_owner=NULL, claim_lease_generation=NULL, "
                "updated_at=? WHERE state='running' AND (claim_owner IS NULL "
                "OR claim_lease_generation IS NULL OR NOT EXISTS (SELECT 1 "
                "FROM analysis_worker_state AS owner WHERE owner.singleton_id=1 "
                "AND owner.instance_id=analysis_jobs.claim_owner "
                "AND owner.lease_generation=analysis_jobs.claim_lease_generation "
                "AND owner.heartbeat_at IS NOT NULL "
                "AND owner.heartbeat_at + ? >= ?))",
                (now, LEASE_SECONDS, now),
            )
            return updated.rowcount

    def claim_next_job(self, now):
        """Atomically claim the highest-priority runnable job, if the provider permits it."""
        now = self._finite_timestamp(now, "now")
        with self._writer_transaction():
            cooldown = self.connection.execute(
                "SELECT provider_not_before FROM analysis_worker_state WHERE singleton_id=1"
            ).fetchone()[0]
            if cooldown is not None and cooldown > now:
                return None
            row = self.connection.execute(
                "SELECT job_id FROM analysis_jobs WHERE state IN ('queued', 'retry_waiting') "
                "AND (next_attempt_at IS NULL OR next_attempt_at <= ?) "
                "ORDER BY CASE WHEN next_attempt_at IS NULL THEN 0 ELSE 1 END, "
                "next_attempt_at, window_end, "
                "CASE cadence WHEN 'two_hour' THEN 0 WHEN 'six_hour' THEN 1 ELSE 2 END "
                "LIMIT 1", (now,)
            ).fetchone()
            if row is None:
                return None
            claim_token = str(uuid.uuid4())
            updated = self.connection.execute(
                "UPDATE analysis_jobs SET state='running', attempt=attempt+1, "
                "claim_token=?, claim_owner=?, claim_lease_generation=?, updated_at=? "
                "WHERE job_id=? AND state IN ('queued', 'retry_waiting')",
                (claim_token, self.instance_id, self._lease_generation, self.clock(), row[0]),
            )
            if updated.rowcount != 1:
                return None
            return self._job_from_row(self._job_row(row[0]))

    def retry_job(self, job, error_code, next_attempt_at, provider_not_before=None,
                  claim_token=None):
        """Put a running job into retry waiting without retaining supplier text."""
        job_id, claim_token = self._claim(job, claim_token)
        error_code = self._error_code(error_code)
        next_attempt_at = self._finite_timestamp(next_attempt_at, "next attempt")
        if provider_not_before is not None:
            provider_not_before = self._finite_timestamp(
                provider_not_before, "provider not before"
            )
        with self._writer_transaction():
            attempt, maximum_attempts = self._require_running_claim(job_id, claim_token)
            now = self.clock()
            state = "failed" if attempt >= maximum_attempts else "retry_waiting"
            updated = self.connection.execute(
                "UPDATE analysis_jobs SET state=?, next_attempt_at=?, error_code=?, "
                "claim_token=NULL, claim_owner=NULL, claim_lease_generation=NULL, "
                "updated_at=? WHERE job_id=? AND state='running' AND claim_token=?",
                (state, next_attempt_at if state == "retry_waiting" else None,
                 error_code, now, job_id, claim_token),
            )
            if updated.rowcount != 1:
                raise ValueError("job claim was lost")
            if provider_not_before is not None:
                self.connection.execute(
                    "UPDATE analysis_worker_state SET provider_not_before=CASE "
                    "WHEN provider_not_before IS NULL OR provider_not_before < ? THEN ? "
                    "ELSE provider_not_before END, last_error_code=?, updated_at=? "
                    "WHERE singleton_id=1",
                    (provider_not_before, provider_not_before, error_code, now),
                )
            else:
                self.connection.execute(
                    "UPDATE analysis_worker_state SET last_error_code=?, updated_at=? "
                    "WHERE singleton_id=1", (error_code, now),
                )
            return self._job_from_row(self._job_row(job_id))

    def credential_required(self, job, credential_file_revision=None,
                            error_code="credential_unavailable", claim_token=None):
        """Stop automatic retries until the credential file changes."""
        job_id, claim_token = self._claim(job, claim_token)
        error_code = self._error_code(error_code)
        credential_file_revision = self._credential_revision(
            credential_file_revision
        )
        with self._writer_transaction():
            self._require_running_claim(job_id, claim_token)
            now = self.clock()
            updated = self.connection.execute(
                "UPDATE analysis_jobs SET state='credential_required', next_attempt_at=NULL, "
                "error_code=?, credential_file_revision=?, claim_token=NULL, "
                "claim_owner=NULL, claim_lease_generation=NULL, updated_at=? "
                "WHERE job_id=? AND state='running' AND claim_token=?",
                (error_code, credential_file_revision, now, job_id, claim_token),
            )
            if updated.rowcount != 1:
                raise ValueError("job claim was lost")
            self.connection.execute(
                "UPDATE analysis_worker_state SET last_error_code=?, updated_at=? "
                "WHERE singleton_id=1",
                (error_code, now),
            )
            return self._job_from_row(self._job_row(job_id))

    def fail_job(self, job, error_code="invalid_response", claim_token=None):
        """Permanently fail a running job with a stable, non-secret error code."""
        job_id, claim_token = self._claim(job, claim_token)
        error_code = self._error_code(error_code)
        with self._writer_transaction():
            self._require_running_claim(job_id, claim_token)
            now = self.clock()
            updated = self.connection.execute(
                "UPDATE analysis_jobs SET state='failed', next_attempt_at=NULL, "
                "error_code=?, claim_token=NULL, claim_owner=NULL, "
                "claim_lease_generation=NULL, updated_at=? WHERE job_id=? "
                "AND state='running' AND claim_token=?",
                (error_code, now, job_id, claim_token),
            )
            if updated.rowcount != 1:
                raise ValueError("job claim was lost")
            self.connection.execute(
                "UPDATE analysis_worker_state SET last_error_code=?, updated_at=? "
                "WHERE singleton_id=1", (error_code, now),
            )
            return self._job_from_row(self._job_row(job_id))

    def complete_job(self, job, result, model=None, provider_request_id=None,
                     input_tokens=None, output_tokens=None, claim_token=None):
        """Atomically store one validated result and mark its job successful."""
        job_id, claim_token = self._claim(job, claim_token)
        if not isinstance(result, dict):
            raise ValueError("analysis result must be an object")
        try:
            result_json = self._json(result)
        except (TypeError, ValueError):
            raise ValueError("analysis result must be JSON serializable")
        for value, name in ((input_tokens, "input tokens"), (output_tokens, "output tokens")):
            if value is not None and (not isinstance(value, int) or isinstance(value, bool) or value < 0):
                raise ValueError("%s must be a non-negative integer" % name)
        for value, name in ((model, "model"), (provider_request_id, "provider request ID")):
            if value is not None and (not isinstance(value, str) or len(value) > 256):
                raise ValueError("%s must be a safe string" % name)
        with self._writer_transaction():
            self._require_running_claim(job_id, claim_token)
            now = self.clock()
            updated = self.connection.execute(
                "UPDATE analysis_jobs SET state='succeeded', next_attempt_at=NULL, "
                "error_code=NULL, claim_token=NULL, claim_owner=NULL, "
                "claim_lease_generation=NULL, updated_at=? WHERE job_id=? "
                "AND state='running' AND claim_token=?", (now, job_id, claim_token),
            )
            if updated.rowcount != 1:
                raise ValueError("job claim was lost")
            self.connection.execute(
                "INSERT INTO analysis_results(job_id, result_json, model, provider_request_id, "
                "input_tokens, output_tokens, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (job_id, result_json, model, provider_request_id, input_tokens,
                 output_tokens, now, now),
            )
            self.connection.execute(
                "UPDATE analysis_worker_state SET last_provider_success_at=?, "
                "last_error_code=NULL, updated_at=? WHERE singleton_id=1", (now, now),
            )
            return self._job_from_row(self._job_row(job_id))

    def _insert_matches_and_alerts(self, message, evaluation):
        event_id = message["eventId"]
        created_at = self.clock()
        tags_json = self._json(evaluation.get("tags", []))
        terms_json = self._json(evaluation.get("matchedTerms", []))
        for match in evaluation.get("matchedRules", []):
            rule_id = match["ruleId"]
            rule = _RULES_BY_ID.get(rule_id, {})
            self.connection.execute(
                "INSERT INTO message_rule_matches("
                "event_id, rule_id, priority, severity, tags_json, matched_terms_json, created_at"
                ") VALUES (?, ?, ?, ?, ?, ?, ?)",
                (event_id, rule_id, match["priority"], rule.get("severity"),
                 tags_json, terms_json, created_at),
            )
            if rule.get("severity"):
                self.connection.execute(
                    "INSERT INTO rule_alerts("
                    "event_id, rule_id, severity, title, occurrence_count, created_at, updated_at"
                    ") VALUES (?, ?, ?, ?, 1, ?, ?)",
                    (event_id, rule_id, rule["severity"], rule["name"],
                     created_at, created_at),
                )

    def persist_rule_batch(self, records, cursor, catalog_version, row_id=None):
        if (
            not isinstance(cursor, tuple) or len(cursor) != 2
            or not isinstance(cursor[1], str) or not cursor[1]
        ):
            raise ValueError("cursor must contain an observed time and event ID")
        if row_id is not None and (
            not isinstance(row_id, int) or isinstance(row_id, bool) or row_id <= 0
        ):
            raise ValueError("row ID cursor must be a positive integer")
        with self._writer_transaction():
            for message, evaluation in records:
                self.connection.execute(
                    "DELETE FROM message_rule_matches WHERE event_id = ?",
                    (message["eventId"],),
                )
                self.connection.execute(
                    "DELETE FROM rule_alerts WHERE event_id = ?", (message["eventId"],)
                )
                self._insert_matches_and_alerts(message, evaluation)
            self.connection.execute(
                "UPDATE analysis_worker_state SET rule_catalog_version=?, "
                "rule_cursor_time=?, rule_cursor_event_id=?, "
                "rule_cursor_row_id=COALESCE(?, rule_cursor_row_id), updated_at=? "
                "WHERE singleton_id=1",
                (catalog_version, cursor[0], cursor[1], row_id, self.clock()),
            )

    def prepare_rule_scan(self, catalog_version):
        with self._writer_transaction():
            row = self.connection.execute(
                "SELECT rule_catalog_version FROM analysis_worker_state WHERE singleton_id=1"
            ).fetchone()
            if row[0] == catalog_version:
                return False
            self.connection.execute("DELETE FROM message_rule_matches")
            self.connection.execute("DELETE FROM rule_alerts")
            self.connection.execute(
                "UPDATE analysis_worker_state SET rule_catalog_version=?, "
                "rule_cursor_time=NULL, rule_cursor_event_id=NULL, rule_cursor_row_id=0, "
                "updated_at=? "
                "WHERE singleton_id=1", (catalog_version, self.clock())
            )
        return True

    @contextlib.contextmanager
    def _writer_transaction(self):
        if self._lease_generation is None:
            self.acquire()
        self.connection.execute("BEGIN IMMEDIATE")
        try:
            owner = self.connection.execute(
                "SELECT 1 FROM analysis_worker_state WHERE singleton_id=1 "
                "AND instance_id=? AND lease_generation=?",
                (self.instance_id, self._lease_generation),
            ).fetchone()
            if owner is None:
                raise RuntimeError("analysis writer lease was lost")
            yield
        except Exception:
            self.connection.rollback()
            raise
        else:
            self.connection.commit()

    def rule_cursor(self):
        row = self.connection.execute(
            "SELECT rule_cursor_time, rule_cursor_event_id "
            "FROM analysis_worker_state WHERE singleton_id=1"
        ).fetchone()
        if row[0] is None:
            return None
        return row[0], row[1]

    def rule_row_id_cursor(self):
        return self.connection.execute(
            "SELECT rule_cursor_row_id FROM analysis_worker_state WHERE singleton_id=1"
        ).fetchone()[0]

    def heartbeat(self, timestamp=None):
        if self._lease_generation is None:
            self.acquire()
        now = self.clock() if timestamp is None else self._finite_timestamp(
            timestamp, "heartbeat"
        )
        self.connection.execute("BEGIN IMMEDIATE")
        try:
            updated = self.connection.execute(
                "UPDATE analysis_worker_state SET heartbeat_at=?, updated_at=? "
                "WHERE singleton_id=1 AND instance_id=? AND lease_generation=?",
                (now, now, self.instance_id, self._lease_generation),
            )
            if updated.rowcount != 1:
                raise RuntimeError("analysis writer lease was lost")
        except Exception:
            self.connection.rollback()
            raise
        else:
            self.connection.commit()

    def acquire(self):
        now = self.clock()
        try:
            self.connection.execute("BEGIN IMMEDIATE")
            row = self.connection.execute(
                "SELECT instance_id, heartbeat_at FROM analysis_worker_state "
                "WHERE singleton_id=1"
            ).fetchone()
            active_elsewhere = (
                row[0] is not None and row[0] != self.instance_id
                and row[1] is not None and now - row[1] <= LEASE_SECONDS
            )
            if active_elsewhere:
                self.connection.rollback()
                raise RuntimeError("analysis writer lease is held by another instance")
            self.connection.execute(
                "UPDATE analysis_worker_state SET instance_id=?, heartbeat_at=?, "
                "lease_generation=lease_generation+1, updated_at=? WHERE singleton_id=1",
                (self.instance_id, now, now)
            )
            generation = self.connection.execute(
                "SELECT lease_generation FROM analysis_worker_state WHERE singleton_id=1"
            ).fetchone()[0]
            self.connection.commit()
            self._lease_generation = generation
        except Exception:
            if self.connection.in_transaction:
                self.connection.rollback()
            raise

    def close(self):
        if getattr(self, "connection", None) is not None:
            self.connection.close()
            self.connection = None
        if self._parent_fd is not None:
            os.close(self._parent_fd)
            self._parent_fd = None
