# WeCom Rules and MiniMax Scheduled Analysis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add deterministic wxFomo rule annotations and durable MiniMax-M2.7 reports for aligned 2-hour, 6-hour, and 24-hour WeCom message windows while keeping the LAN workbench read-only.

**Architecture:** Keep the existing Swift 5.2 listener as the sole writer of `messages.sqlite3`. Add a dependency-free Python 3.7 analysis worker that reads that database, writes a separate `analysis.sqlite3`, calls MiniMax through its mainland Anthropic-compatible endpoint, and exposes only persisted projections through the existing authenticated read-only server.

**Tech Stack:** Swift 5.2 listener, Python 3.7 standard library (`sqlite3`, `urllib`, `http.server`, `unittest`), SQLite WAL, ES2018 browser modules, Node.js frontend tests, zsh launcher.

**Spec:** `docs/superpowers/specs/2026-09-04-wecom-rules-minimax-analysis-design.md`

## Global Constraints

- Preserve macOS 13 and Swift 5.2.4 compatibility; do not import the Swift 5.10 `WxFomoCore` package into the standalone listener.
- New Python production code must run on Python 3.7 and use no third-party packages.
- `wecom-group-listener.swift` remains the sole writer of `messages.sqlite3`; the analysis worker opens it with `mode=ro` and `PRAGMA query_only=ON`.
- The analysis worker is the sole writer of `analysis.sqlite3`; the LAN server opens it read-only and never calls MiniMax.
- Keep every browser endpoint GET/HEAD-only and preserve the existing LAN password behavior.
- Do not implement SignalHub transport in this plan; keep the read-only DTOs stable so a later SignalHub adapter can consume the same persisted results.
- Use `https://api.minimaxi.com/anthropic/v1/messages` and model `MiniMax-M2.7`; do not add automatic provider fallback.
- Never use, log, test, persist, or commit the MiniMax key exposed in chat. Automated network tests use a local fake server and dummy values only.
- The replacement key is entered locally with no terminal echo and stored under a `0700` directory in a `0600` regular file.
- Align all report windows to UTC+08:00 (`Asia/Shanghai`), persist UTC epoch seconds, use `[start, end)` boundaries, and skip empty windows.
- On startup or wake, create at most the latest missing 2-hour, 6-hour, and 24-hour job; never enumerate older missed windows.
- Preserve all messages in oversized windows by chronological chunking and hierarchical synthesis; do not sample or silently truncate.
- Treat group content as untrusted prompt data. Accept only validated structured JSON whose source IDs belong to the frozen input set.

## File Structure

### New production files

- `scripts/wxfomo_lan/rules.py`: immutable five-rule catalog and deterministic evaluator.
- `scripts/wxfomo_lan/analysis_source.py`: read-only message-source adapter for incremental and frozen-window reads.
- `scripts/wxfomo_lan/analysis_store.py`: private analysis schema, rule persistence, job queue, heartbeat, retry, and result transactions.
- `scripts/wxfomo_lan/scheduler.py`: UTC+08:00-aligned 2/6/24-hour window calculations.
- `scripts/wxfomo_lan/credentials.py`: safe MiniMax credential loading and atomic local saving.
- `scripts/wxfomo_lan/minimax.py`: Anthropic-compatible request construction, response validation, chunking, and error classification.
- `scripts/wxfomo_lan/analysis_worker.py`: orchestration of rule scans, scheduling, job execution, recovery, and sanitized logs.
- `scripts/wxfomo-analysis-worker.py`: command-line entry point for the persistent worker.
- `scripts/configure-wxfomo-ai.py`: non-echoing local credential configuration and explicit connection test.
- `scripts/configure-wxfomo-ai.command`: double-clickable macOS wrapper around the configuration tool.
- `scripts/wxfomo_lan/analysis.py`: read-only DTO repository for rules, annotations, alerts, priority items, analyses, settings, and diagnostics.

### New test files

- `scripts/test_wxfomo_rules.py`
- `scripts/test_wxfomo_analysis_store.py`
- `scripts/test_wxfomo_scheduler.py`
- `scripts/test_wxfomo_credentials.py`
- `scripts/test_wxfomo_minimax.py`
- `scripts/test_wxfomo_analysis_worker.py`

### Existing files to modify

- `scripts/wxfomo_lan/messages.py:176-510`: attach persisted analysis annotations to message DTOs without mutating the message source.
- `scripts/wxfomo_lan/server.py:25-270`: instantiate the LAN analysis repository and route read-only endpoints to it.
- `scripts/wxfomo-lan-server.py:15-150`: accept the analysis database path without accepting any AI credential path.
- `scripts/test_wxfomo_lan_server.py:20-2600`: add analysis fixtures, API projections, failure degradation, and secret-field scans.
- `web/wxfomo-lan/app.mjs:412-490`: render tags, severity, and priority on inbox message cards.
- `web/wxfomo-lan/pages.mjs:299-470,640-700,934-970`: render LAN alerts, scheduled analysis details, rules, and priority annotations.
- `web/wxfomo-lan/state.mjs:1-190`: retain live analysis diagnostics and normalize worker-specific dependency states.
- `web/wxfomo-lan/styles.css`: style rule tags, severity accents, report cadence, findings, and source messages.
- `scripts/test-wxfomo-lan-frontend.mjs`: cover the new DOM output and retain the no-write-controls assertion.
- `scripts/start-wxfomo-lan.sh:5-420`: start, supervise, and stop the analysis worker and pass its database to the web server.
- `scripts/test-wxfomo-lan-launcher.sh`: verify worker readiness, restart behavior, cleanup, and degraded operation without credentials.
- `scripts/test-wxfomo-lan-launcher-readiness.sh`: include every new production file in deployment-readiness fixtures.
- `README.md:406-470`: document local rules, schedules, key rotation/configuration, privacy, statuses, and startup behavior.

---

### Task 1: Deterministic wxFomo Rule Catalog

**Files:**
- Create: `scripts/wxfomo_lan/rules.py`
- Create: `scripts/test_wxfomo_rules.py`

**Interfaces:**
- Consumes: a normalized message body as `str`.
- Produces: `RULE_CATALOG_VERSION = 1` and `evaluate_message(content: str) -> dict` with keys `matchedRules`, `tags`, `priority`, `severity`, and `matchedTerms`.
- Produces: `rules_payload() -> dict` with `{available, reason, items, invalidRows}` for `/api/rules`.

- [ ] **Step 1: Write failing catalog and evaluator tests**

```python
import unittest

from scripts.wxfomo_lan.rules import evaluate_message, rules_payload


class RuleTests(unittest.TestCase):
    def test_risk_and_accumulation_can_both_match(self):
        result = evaluate_message("聪明钱加仓，但合约是 HONEYPOT，卖不掉")
        self.assertEqual(result["tags"], ["高风险", "资金信号"])
        self.assertEqual(result["priority"], 50)
        self.assertEqual(result["severity"], "critical")
        self.assertEqual(
            [item["ruleId"] for item in result["matchedRules"]],
            [
                "recommended.risk.contract-liquidity",
                "recommended.signal.accumulation",
            ],
        )

    def test_bare_addresses_require_the_whole_body(self):
        self.assertEqual(evaluate_message("0x" + "a" * 40)["tags"], ["CA"])
        self.assertNotIn("CA", evaluate_message("看这个 0x" + "a" * 40)["tags"])

    def test_market_report_and_chatter_boundaries(self):
        self.assertEqual(
            evaluate_message("MC: $2m\nLP: $100k\n地址：abc")["tags"],
            ["行情播报"],
        )
        self.assertEqual(evaluate_message("今天天气不错")["matchedRules"], [])

    def test_payload_exposes_exact_five_read_only_rules(self):
        payload = rules_payload()
        self.assertTrue(payload["available"])
        self.assertEqual(len(payload["items"]), 5)
        self.assertEqual([item["priority"] for item in payload["items"]], [50, 40, 30, 20, 10])
```

- [ ] **Step 2: Run the rule tests and verify the missing module failure**

Run: `python3 -m unittest scripts.test_wxfomo_rules -v`

Expected: FAIL with `ModuleNotFoundError: No module named 'scripts.wxfomo_lan.rules'`.

- [ ] **Step 3: Implement the immutable catalog and evaluator**

```python
RULE_CATALOG_VERSION = 1
RISK_KEYWORDS = (
    "貔貅", "honeypot", "rug", "撤池", "跑路", "黑名单",
    "冻结权限", "增发", "mint权限", "卖不掉",
)
EXIT_KEYWORDS = ("砸盘", "清仓", "出货", "割肉", "止损", "撤退")
ACCUMULATION_KEYWORDS = (
    "聪明钱", "smart money", "大额买入", "加仓", "建仓", "扫货",
    "重仓", "看好", "吸筹", "抄底",
)


def evaluate_message(content):
    normalized = unicodedata.normalize("NFC", content or "")
    folded = normalized.casefold()
    matches = []
    for rule in RULE_CATALOG:
        terms = rule["matcher"](normalized, folded)
        if terms:
            matches.append((rule, terms))
    return _evaluation_payload(matches)
```

Define the five rules in priority order with the exact IDs, names, keywords, regular expressions, tags, and severities from `RecommendedMessageRules.swift`. `_evaluation_payload` must preserve catalog order, de-duplicate tags and terms, choose the maximum priority, and choose `critical` over `warning` over `None`.

- [ ] **Step 4: Run the rule tests**

Run: `python3 -m unittest scripts.test_wxfomo_rules -v`

Expected: all rule tests PASS.

- [ ] **Step 5: Commit the deterministic rule engine**

```bash
git add scripts/wxfomo_lan/rules.py scripts/test_wxfomo_rules.py
git commit -m "feat: add deterministic WeCom message rules"
```

---

### Task 2: Analysis Database and Read-Only Message Source

**Files:**
- Create: `scripts/wxfomo_lan/analysis_source.py`
- Create: `scripts/wxfomo_lan/analysis_store.py`
- Create: `scripts/test_wxfomo_analysis_store.py`

**Interfaces:**
- Consumes: the existing listener schema in `messages.sqlite3`.
- Produces: `MessageSource(path).after(cursor, limit) -> list[dict]`, `event_ids_in_window(start, end) -> list[str]`, and `by_event_ids(ids) -> list[dict]`; type spelling in Python 3.7 code uses `typing.List`, not built-in generics.
- Produces: `AnalysisStore(path, instance_id, clock)` with `persist_rule_batch(records, cursor, catalog_version)`, `prepare_rule_scan(catalog_version)`, `rule_cursor()`, `heartbeat()`, `acquire()`, and `close()`.

- [ ] **Step 1: Write failing private-schema and atomic-batch tests**

```python
import sqlite3
import tempfile
import unittest

from scripts.wxfomo_lan.analysis_source import MessageSource
from scripts.wxfomo_lan.analysis_store import AnalysisStore
from scripts.wxfomo_lan.rules import evaluate_message


class AnalysisStoreTests(unittest.TestCase):
    def test_rule_batch_and_cursor_commit_together(self):
        store = AnalysisStore(self.analysis_path, "11111111-1111-4111-8111-111111111111", lambda: 1000.0)
        message = {"eventId": "event-1", "observedAt": 900.0, "content": "rug 加仓"}
        store.persist_rule_batch(
            [(message, evaluate_message(message["content"]))],
            (900.0, "event-1"),
            catalog_version=1,
        )
        self.assertEqual(store.rule_cursor(), (900.0, "event-1"))
        rows = sqlite3.connect(self.analysis_path).execute(
            "SELECT rule_id, priority FROM message_rule_matches ORDER BY priority DESC"
        ).fetchall()
        self.assertEqual(rows, [
            ("recommended.risk.contract-liquidity", 50),
            ("recommended.signal.accumulation", 30),
        ])

    def test_message_source_is_read_only_and_uses_half_open_window(self):
        source = MessageSource(self.message_path)
        self.assertEqual(source.event_ids_in_window(100.0, 200.0), ["inside"])
        with self.assertRaises(sqlite3.OperationalError):
            source._open().execute("DELETE FROM messages")
```

The test fixture creates messages at `99.9`, `100.0`, `199.9`, and `200.0` and expects only IDs in `[100.0, 200.0)`.

- [ ] **Step 2: Run the storage tests and verify the missing module failure**

Run: `python3 -m unittest scripts.test_wxfomo_analysis_store -v`

Expected: FAIL because `analysis_source` and `analysis_store` do not exist.

- [ ] **Step 3: Implement safe read-only message access**

```python
def _open(self):
    uri = "file:{}?mode=ro".format(urllib.parse.quote(os.path.abspath(self.path)))
    connection = sqlite3.connect(uri, uri=True, timeout=0.25)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only=ON")
    return connection


def event_ids_in_window(self, start, end):
    with self._open() as connection:
        rows = connection.execute(
            "SELECT event_id FROM messages WHERE observed_at >= ? AND observed_at < ? "
            "ORDER BY observed_at, event_id",
            (start, end),
        ).fetchall()
    return [row["event_id"] for row in rows]
```

`after` uses `(observed_at > ?) OR (observed_at = ? AND event_id > ?)` and returns safe dictionaries containing only event ID, group, sender, content, message type, and observed time. `by_event_ids` preserves the frozen ID order and rejects non-string or empty IDs.

- [ ] **Step 4: Implement the versioned analysis schema and atomic rule persistence**

Create the exact tables from the design: `analysis_schema_migrations`, `analysis_worker_state`, `message_rule_matches`, `rule_alerts`, `analysis_jobs`, and `analysis_results`. Add unique constraints on `(event_id, rule_id)`, `(cadence, window_start, window_end)`, and `analysis_results.job_id`. `analysis_worker_state` also stores `rule_catalog_version`, `provider_not_before`, `credential_status`, `last_provider_success_at`, and `last_error_code`; `analysis_jobs` stores the safe credential-file revision used by a credential failure so an unchanged rejected key cannot loop.

```python
def persist_rule_batch(self, records, cursor, catalog_version):
    with self.connection:
        for message, evaluation in records:
            self.connection.execute(
                "DELETE FROM message_rule_matches WHERE event_id = ?",
                (message["eventId"],),
            )
            self.connection.execute(
                "DELETE FROM rule_alerts WHERE event_id = ?",
                (message["eventId"],),
            )
            self._insert_matches_and_alerts(message, evaluation)
        self.connection.execute(
            "UPDATE analysis_worker_state SET rule_catalog_version=?, "
            "rule_cursor_time=?, rule_cursor_event_id=?, updated_at=? "
            "WHERE singleton_id=1",
            (catalog_version, cursor[0], cursor[1], self.clock()),
        )
```

`prepare_rule_scan` compares the persisted catalog version with `RULE_CATALOG_VERSION`; a version change clears only rule matches, alerts, and the rule cursor before replaying all messages. `acquire()` uses a heartbeat lease and rejects a second non-stale writer instance. File initialization must enforce a `0700` real parent directory and a `0600` single-link regular database file.

- [ ] **Step 5: Run storage tests and inspect schema constraints**

Run: `python3 -m unittest scripts.test_wxfomo_analysis_store -v`

Expected: all tests PASS, including duplicate event/rule and second-writer rejection tests.

- [ ] **Step 6: Commit the analysis storage boundary**

```bash
git add scripts/wxfomo_lan/analysis_source.py scripts/wxfomo_lan/analysis_store.py scripts/test_wxfomo_analysis_store.py
git commit -m "feat: persist WeCom rule analysis privately"
```

---

### Task 3: UTC+08:00 Windows and Durable Job Scheduling

**Files:**
- Create: `scripts/wxfomo_lan/scheduler.py`
- Create: `scripts/test_wxfomo_scheduler.py`
- Modify: `scripts/wxfomo_lan/analysis_store.py`
- Modify: `scripts/test_wxfomo_analysis_store.py`

**Interfaces:**
- Consumes: a UTC epoch `now` and cadence name `two_hour`, `six_hour`, or `daily`.
- Produces: immutable `AnalysisWindow(cadence, start, end, due_at)`.
- Produces: `latest_due_window(cadence, now) -> AnalysisWindow` and `latest_due_windows(now) -> tuple`.
- Extends `AnalysisStore` with `ensure_job(window, source_event_ids)`, `recover_interrupted_jobs()`, `claim_next_job(now)`, `retry_job(...)`, `credential_required(...)`, `fail_job(...)`, and `complete_job(...)`.

- [ ] **Step 1: Write failing alignment and backfill tests**

```python
from datetime import datetime, timezone

from scripts.wxfomo_lan.scheduler import latest_due_windows


def utc_timestamp(year, month, day, hour, minute):
    return datetime(year, month, day, hour, minute, tzinfo=timezone.utc).timestamp()


class SchedulerTests(unittest.TestCase):
    def test_midnight_grace_staggers_three_windows(self):
        now = utc_timestamp(2026, 9, 3, 16, 16)  # 2026-09-04 00:16 +08:00
        windows = latest_due_windows(now)
        self.assertEqual([window.cadence for window in windows], ["two_hour", "six_hour", "daily"])
        self.assertEqual([window.due_at - window.end for window in windows], [300, 600, 900])

    def test_wake_returns_only_latest_window_per_cadence(self):
        windows = latest_due_windows(utc_timestamp(2026, 9, 4, 8, 30))
        self.assertEqual(len(windows), 3)
        self.assertEqual(windows[0].end - windows[0].start, 2 * 3600)
        self.assertEqual(windows[1].end - windows[1].start, 6 * 3600)
        self.assertEqual(windows[2].end - windows[2].start, 24 * 3600)
```

Add store tests proving repeated `ensure_job` calls return the same job, empty windows become `skipped_empty`, stale `running` jobs recover to `queued`, and a global provider cooldown prevents `claim_next_job` before `provider_not_before`.

- [ ] **Step 2: Run the scheduler tests and verify failure**

Run: `python3 -m unittest scripts.test_wxfomo_scheduler scripts.test_wxfomo_analysis_store -v`

Expected: FAIL because scheduler and job methods are missing.

- [ ] **Step 3: Implement fixed-offset aligned windows**

```python
SHANGHAI_OFFSET = 8 * 3600
CADENCES = {
    "two_hour": (2 * 3600, 5 * 60),
    "six_hour": (6 * 3600, 10 * 60),
    "daily": (24 * 3600, 15 * 60),
}


def latest_due_window(cadence, now):
    duration, grace = CADENCES[cadence]
    local_now = now + SHANGHAI_OFFSET
    latest_end = int((local_now - grace) // duration) * duration
    end = float(latest_end - SHANGHAI_OFFSET)
    return AnalysisWindow(cadence, end - duration, end, end + grace)
```

Return windows in `two_hour`, `six_hour`, `daily` order. Raise `ValueError` for non-finite timestamps and unknown cadences.

- [ ] **Step 4: Implement durable queue transitions**

Use `BEGIN IMMEDIATE` transactions to claim one job. Sort runnable work by `next_attempt_at`, `window_end`, then cadence rank. `retry_job` records only a stable error code and updates `provider_not_before` when rate limited. `complete_job` inserts one validated result and marks the job succeeded in the same transaction.

- [ ] **Step 5: Run scheduler and storage tests**

Run: `python3 -m unittest scripts.test_wxfomo_scheduler scripts.test_wxfomo_analysis_store -v`

Expected: all tests PASS.

- [ ] **Step 6: Commit durable scheduling**

```bash
git add scripts/wxfomo_lan/scheduler.py scripts/wxfomo_lan/analysis_store.py scripts/test_wxfomo_scheduler.py scripts/test_wxfomo_analysis_store.py
git commit -m "feat: schedule durable 2h 6h and daily analyses"
```

---

### Task 4: Safe Local MiniMax Credentials

**Files:**
- Create: `scripts/wxfomo_lan/credentials.py`
- Create: `scripts/configure-wxfomo-ai.py`
- Create: `scripts/configure-wxfomo-ai.command`
- Create: `scripts/test_wxfomo_credentials.py`

**Interfaces:**
- Produces: `Credential(api_key, revision)` where `revision` is derived only from safe file metadata and is never returned by the web API.
- Produces: `load_credential(path) -> Credential`, `save_credential(path, api_key) -> None`, and `credential_status(path) -> str`.
- CLI accepts only `--credentials PATH` and `--test-connection`; it never accepts a key argument.

- [ ] **Step 1: Write failing permission, symlink, and no-echo tests**

```python
class CredentialTests(unittest.TestCase):
    def test_save_creates_private_directory_and_file(self):
        save_credential(self.path, "dummy-plan-key")
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(self.path)).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)
        self.assertEqual(load_credential(self.path).api_key, "dummy-plan-key")

    def test_world_readable_or_symlink_credentials_are_rejected(self):
        save_credential(self.path, "dummy-plan-key")
        os.chmod(self.path, 0o644)
        with self.assertRaises(CredentialError):
            load_credential(self.path)

    def test_cli_reads_twice_with_getpass_and_never_prints_key(self):
        with mock.patch("getpass.getpass", side_effect=["dummy-plan-key", "dummy-plan-key"]):
            output = io.StringIO()
            with redirect_stdout(output):
                self.assertEqual(configure.main(["--credentials", self.path]), 0)
        self.assertNotIn("dummy-plan-key", output.getvalue())
```

- [ ] **Step 2: Run credential tests and verify failure**

Run: `python3 -m unittest scripts.test_wxfomo_credentials -v`

Expected: FAIL because the credential module and CLI are missing.

- [ ] **Step 3: Implement safe load and atomic save**

Use `lstat`, `openat`, `O_NOFOLLOW`, owner checks, link-count checks, and mode checks before reading. Save to a random same-directory temporary file with `0600`, `fsync` the file, `os.replace` it, then `fsync` the `0700` directory.

```python
def save_credential(path, api_key):
    value = api_key.strip()
    if not value:
        raise CredentialError("credential_empty")
    parent = _safe_private_parent(path, create=True)
    payload = json.dumps({"miniMaxAPIKey": value}, separators=(",", ":")).encode("utf-8")
    _atomic_private_write(parent, os.path.basename(path), payload)
```

Derive `Credential.revision` from the verified file's device, inode, nanosecond modification time, and byte size so an unchanged rejected key is not retried after a worker restart. Do not expose that revision in logs or APIs.

- [ ] **Step 4: Implement the local interactive wrappers**

`configure-wxfomo-ai.py` prompts twice with `getpass.getpass`, rejects mismatches, saves only after both entries match, and prints only success/failure status. `configure-wxfomo-ai.command` resolves its own directory and executes `/usr/bin/python3` without placing the key in arguments or environment variables.

- [ ] **Step 5: Run credential tests and shell syntax checks**

Run: `python3 -m unittest scripts.test_wxfomo_credentials -v`

Run: `zsh -n scripts/configure-wxfomo-ai.command`

Expected: all tests PASS and zsh reports no syntax error.

- [ ] **Step 6: Commit private credential management**

```bash
git add scripts/wxfomo_lan/credentials.py scripts/configure-wxfomo-ai.py scripts/configure-wxfomo-ai.command scripts/test_wxfomo_credentials.py
git commit -m "feat: configure MiniMax credentials privately"
```

---

### Task 5: MiniMax Anthropic-Compatible Client and Result Validation

**Files:**
- Create: `scripts/wxfomo_lan/minimax.py`
- Create: `scripts/test_wxfomo_minimax.py`
- Modify: `scripts/configure-wxfomo-ai.py`
- Modify: `scripts/test_wxfomo_credentials.py`

**Interfaces:**
- Produces: `MiniMaxClient(api_key, base_url=MAINLAND_BASE_URL, model=DEFAULT_MODEL, transport=None)`.
- Produces: `analyze_window(messages, cadence, window_start, window_end) -> AnalysisOutcome`.
- Produces: `test_connection() -> dict` returning only model and provider request ID.
- Raises: `MiniMaxError(code, retryable, retry_after)` with stable codes only.

- [ ] **Step 1: Write failing request, validation, and chunk tests**

```python
class MiniMaxTests(unittest.TestCase):
    def test_request_uses_mainland_anthropic_endpoint(self):
        transport = RecordingTransport(valid_response(["event-1"]))
        client = MiniMaxClient("dummy-plan-key", transport=transport)
        outcome = client.analyze_window([message("event-1")], "two_hour", 0.0, 7200.0)
        self.assertEqual(transport.request.full_url, "https://api.minimaxi.com/anthropic/v1/messages")
        self.assertEqual(transport.request.get_header("X-api-key"), "dummy-plan-key")
        self.assertEqual(outcome.result["summarySourceMessageIds"], ["event-1"])

    def test_invented_source_id_is_rejected(self):
        transport = RecordingTransport(valid_response(["invented-id"]))
        client = MiniMaxClient("dummy-plan-key", transport=transport)
        with self.assertRaisesRegex(MiniMaxError, "invalid_source_reference"):
            client.analyze_window([message("event-1")], "two_hour", 0.0, 7200.0)

    def test_oversized_single_message_is_segmented_without_dropping_content(self):
        original = "中" * 240
        chunks = chunk_messages([message("a", original)], 140)
        segments = [item for chunk in chunks for item in chunk]
        self.assertTrue(all(item["eventId"] == "a" for item in segments))
        self.assertEqual("".join(item["content"] for item in segments), original)
        self.assertEqual(
            [item["segmentIndex"] for item in segments],
            list(range(1, len(segments) + 1)),
        )
```

Add a local `ThreadingHTTPServer` fake covering `thinking` plus `text` response blocks, 400, 401, 429 with `Retry-After`, 500, invalid JSON, oversized response, and a closed connection. Dummy request headers must never be printed by the test server.

- [ ] **Step 2: Run MiniMax tests and verify failure**

Run: `python3 -m unittest scripts.test_wxfomo_minimax -v`

Expected: FAIL because `minimax.py` does not exist.

- [ ] **Step 3: Implement request construction and error classification**

```python
MAINLAND_BASE_URL = "https://api.minimaxi.com/anthropic"
DEFAULT_MODEL = "MiniMax-M2.7"


def _request_body(self, system_prompt, input_document):
    return {
        "model": self.model,
        "max_tokens": 8192,
        "stream": False,
        "system": system_prompt,
        "messages": [{"role": "user", "content": json.dumps(input_document, ensure_ascii=False)}],
    }
```

Set `Content-Type: application/json`, `X-Api-Key`, and `anthropic-version: 2023-06-01`. The production constructor rejects non-HTTPS base URLs; tests opt into a loopback-only insecure endpoint through a private test flag. Bound encoded requests and responses before parsing.

- [ ] **Step 4: Implement strict result projection and source validation**

Accept exactly `summary`, `summary_source_message_ids`, `topics`, `findings`, and `crypto_addresses` from model text. Convert them to the browser DTO casing only after validation. Reject unknown finding categories/statuses, non-string IDs, references outside the frozen set, and addresses outside deterministic local evidence. Strip one outer Markdown JSON fence but do not accept arbitrary prose around JSON.

- [ ] **Step 5: Implement chronological chunking and hierarchical synthesis**

If one complete message cannot fit the request budget, split its content into ordered UTF-8-safe segments carrying the same original `eventId` plus `segmentIndex` and `segmentCount`; concatenating the segments must reproduce the original content exactly. `analyze_window` analyzes each chronological chunk, then merges bounded batches of intermediate results until one validated result remains. Every intermediate source reference remains an original event ID.

- [ ] **Step 6: Add an explicit connection-test path to the credential CLI**

When and only when `--test-connection` is supplied, load the saved key and call `MiniMaxClient.test_connection()`. Print `MiniMax-M2.7 连接成功` plus a provider request ID when present; never print headers, response bodies, or key-derived values.

- [ ] **Step 7: Run MiniMax and credential tests**

Run: `python3 -m unittest scripts.test_wxfomo_minimax scripts.test_wxfomo_credentials -v`

Expected: all tests PASS without external network access.

- [ ] **Step 8: Commit the MiniMax client**

```bash
git add scripts/wxfomo_lan/minimax.py scripts/test_wxfomo_minimax.py scripts/configure-wxfomo-ai.py scripts/test_wxfomo_credentials.py
git commit -m "feat: analyze message windows with MiniMax"
```

---

### Task 6: Persistent Analysis Worker

**Files:**
- Create: `scripts/wxfomo_lan/analysis_worker.py`
- Create: `scripts/wxfomo-analysis-worker.py`
- Create: `scripts/test_wxfomo_analysis_worker.py`
- Modify: `scripts/wxfomo_lan/analysis_store.py`
- Modify: `scripts/test_wxfomo_analysis_store.py`

**Interfaces:**
- Consumes: `MessageSource`, `AnalysisStore`, `latest_due_windows`, `load_credential`, `evaluate_message`, and `MiniMaxClient`.
- Produces: `AnalysisWorker.run_once(now=None) -> WorkerTick` and `run_forever(poll_interval=1.0)`.
- CLI arguments: `--message-database`, `--analysis-database`, `--credentials`, `--instance-id`, `--poll-interval`, and test-only `--once`.

- [ ] **Step 1: Write failing orchestration tests with fake time and provider**

```python
class WorkerTests(unittest.TestCase):
    def test_tick_backfills_rules_and_runs_due_jobs_serially(self):
        worker = self.worker(now=self.midnight_plus_sixteen, client=FakeMiniMaxClient())
        tick = worker.run_once()
        self.assertEqual(tick.rule_messages_processed, 3)
        self.assertEqual(tick.jobs_created, 3)
        self.assertEqual(tick.jobs_completed, 1)
        self.assertEqual(self.store.job_states().count("succeeded"), 1)
        self.assertEqual(self.store.job_states().count("queued"), 2)

    def test_missing_credentials_keeps_rules_and_marks_job(self):
        worker = self.worker(now=self.midnight_plus_sixteen, credentials_path=self.missing_path)
        tick = worker.run_once()
        self.assertEqual(tick.rule_messages_processed, 3)
        self.assertEqual(self.store.job_states(), ["credential_required", "queued", "queued"])

    def test_unchanged_rejected_credential_is_not_retried(self):
        client = RejectingClient("credential_unavailable")
        worker = self.worker(now=self.midnight_plus_sixteen, client=client)
        worker.run_once()
        worker.run_once()
        self.assertEqual(client.calls, 1)
```

Add tests for one latest backfill per cadence after a multi-day gap, empty-window skip, process recovery, 429 global cooldown, one-request-at-a-time behavior, sanitized logs, and source disappearance without message loss.

- [ ] **Step 2: Run worker tests and verify failure**

Run: `python3 -m unittest scripts.test_wxfomo_analysis_worker -v`

Expected: FAIL because worker modules are missing.

- [ ] **Step 3: Implement one deterministic worker tick**

```python
def run_once(self, now=None):
    timestamp = self.clock() if now is None else now
    self.store.heartbeat(timestamp)
    rule_count = self._process_rule_batches()
    created = self._schedule_latest_windows(timestamp)
    outcome = self._process_one_job(timestamp)
    return WorkerTick(rule_count, created, int(outcome == "succeeded"))
```

`_process_rule_batches` first calls `prepare_rule_scan(RULE_CATALOG_VERSION)`, reads at most 200 messages per database transaction, and repeats until caught up. `_schedule_latest_windows` calls `event_ids_in_window` and `ensure_job`. `_process_one_job` claims at most one job, loads its exact frozen IDs, revalidates them against the source, loads the credential safely, and calls the injected MiniMax client.

- [ ] **Step 4: Implement credential revision, retries, and sanitized logging**

Persist the safe file-metadata revision used by a 401/403 attempt so an unchanged key cannot loop. On a new credential-file revision, move matching `credential_required` jobs back to `queued`. Each tick writes only `configured`, `unconfigured`, or `unsafe` to `credential_status`; successful calls update `last_provider_success_at`, and failures update only `last_error_code`. Map `MiniMaxError` to store transitions from Task 3; log only job ID, cadence, counts, attempt, stable error code, and provider request ID.

- [ ] **Step 5: Implement the Python 3.7 CLI and durable loop**

The entry point validates UUID and positive poll interval, installs SIGINT/SIGTERM handlers, refuses an active second worker lease, runs one tick per second, and exits nonzero on storage/schema/ownership failures. `--once` executes exactly one tick for tests and diagnostics.

- [ ] **Step 6: Run worker and dependency tests**

Run: `python3 -m unittest scripts.test_wxfomo_analysis_worker scripts.test_wxfomo_analysis_store scripts.test_wxfomo_scheduler scripts.test_wxfomo_minimax -v`

Expected: all tests PASS.

- [ ] **Step 7: Commit the persistent worker**

```bash
git add scripts/wxfomo_lan/analysis_worker.py scripts/wxfomo-analysis-worker.py scripts/test_wxfomo_analysis_worker.py scripts/wxfomo_lan/analysis_store.py scripts/test_wxfomo_analysis_store.py
git commit -m "feat: run durable scheduled WeCom analysis"
```

---

### Task 7: Read-Only Analysis API Projections

**Files:**
- Create: `scripts/wxfomo_lan/analysis.py`
- Modify: `scripts/wxfomo_lan/messages.py:176-510`
- Modify: `scripts/wxfomo_lan/server.py:25-270`
- Modify: `scripts/wxfomo-lan-server.py:15-150`
- Modify: `scripts/test_wxfomo_lan_server.py`

**Interfaces:**
- Produces: `AnalysisRepository(database_path)` with `annotations(event_ids)`, `alerts()`, `priority(messages)`, `analyses(messages)`, `rules()`, `settings_status()`, and `diagnostics()`.
- Extends: `ServerOptions.analysis_database`.
- Preserves: every existing API field; new message fields are additive.

- [ ] **Step 1: Add failing server fixtures and endpoint assertions**

```python
def test_lan_analysis_populates_existing_read_only_pages(self):
    message = self.authorized_json("/api/messages?limit=1")["items"][0]
    self.assertEqual(message["tags"], ["高风险"])
    self.assertEqual(message["severity"], "critical")
    self.assertEqual(self.authorized_json("/api/rules")["items"][0]["priority"], 50)
    self.assertEqual(self.authorized_json("/api/alerts")["items"][0]["sourceMessages"][0]["eventId"], message["eventId"])
    self.assertEqual(self.authorized_json("/api/priority")["items"][0]["priority"], 50)
    self.assertEqual(self.authorized_json("/api/analyses")["items"][0]["cadence"], "two_hour")

def test_analysis_api_never_exposes_credentials_or_revision(self):
    serialized = json.dumps({
        path: self.authorized_json(path)
        for path in ("/api/messages", "/api/analyses", "/api/settings/status", "/api/diagnostics")
    })
    self.assertNotIn("dummy-plan-key", serialized)
    self.assertNotIn("credentialRevision", serialized)
```

Add cases for missing, locked, corrupt, permission-denied, and schema-incompatible analysis databases. Existing messages must remain available when annotations are unavailable.

- [ ] **Step 2: Run focused server tests and verify failure**

Run: `python3 -m unittest scripts.test_wxfomo_lan_server.LanServerTests -v`

Expected: FAIL because `analysis_database` and LAN analysis projections are absent.

- [ ] **Step 3: Implement the read-only `AnalysisRepository`**

Open `analysis.sqlite3` with `mode=ro` and `PRAGMA query_only=ON`. Validate only the tables needed by each endpoint so one damaged optional table does not hide healthy data. Bound result counts and JSON sizes; skip invalid rows while increasing `invalidRows`.

```python
def annotations(self, event_ids):
    rows = self._bounded_rows_for_ids(event_ids)
    grouped = {}
    for row in rows:
        item = grouped.setdefault(row["event_id"], _empty_annotation())
        _merge_match(item, row)
    return grouped
```

- [ ] **Step 4: Merge annotations into message and source DTOs**

After `MessageRepository.query` returns rows, the server requests annotations for only those event IDs and adds `tags`, `matchedRules`, `priority`, `severity`, and `matchedTerms`. Apply the same helper to `by_event_ids` results used by alerts and analyses. An unavailable analysis source adds no fake tags and never turns `/api/messages` into a 503.

- [ ] **Step 5: Route LAN analysis separately from the optional native workspace**

Use `AnalysisRepository` for `/api/rules`, `/api/alerts`, `/api/priority`, and `/api/analyses`. Continue using the native `WorkspaceRepository` for Meme, market, trading, automations, and speech/trading settings. `/api/settings/status` remains renderable when the optional native workspace is absent: its top-level availability follows the LAN analysis source, `aiConfigured` and `providerNames` come from `analysis_worker_state`, and `nativeSettingsDependency` reports the separate speech/trading source. Merge diagnostics the same way without opening the credentials file in the web process.

- [ ] **Step 6: Run backend regression and method-safety tests**

Run: `python3 -m unittest scripts.test_wxfomo_lan_server -v`

Expected: all server tests PASS; POST/PUT/PATCH/DELETE still return 405 and all existing security headers remain unchanged.

- [ ] **Step 7: Commit the read-only API**

```bash
git add scripts/wxfomo_lan/analysis.py scripts/wxfomo_lan/messages.py scripts/wxfomo_lan/server.py scripts/wxfomo-lan-server.py scripts/test_wxfomo_lan_server.py
git commit -m "feat: expose WeCom analysis in read-only API"
```

---

### Task 8: Rule Annotations and Scheduled Reports in the Workbench

**Files:**
- Modify: `web/wxfomo-lan/app.mjs:412-490`
- Modify: `web/wxfomo-lan/pages.mjs:1-980`
- Modify: `web/wxfomo-lan/state.mjs:1-190`
- Modify: `web/wxfomo-lan/styles.css`
- Modify: `scripts/test-wxfomo-lan-frontend.mjs`

**Interfaces:**
- Consumes: additive message fields and the `/api/rules`, `/api/alerts`, `/api/priority`, `/api/analyses`, `/api/settings/status`, and `/api/diagnostics` DTOs from Task 7.
- Produces: read-only DOM only; no new form submission or mutating fetch.

- [ ] **Step 1: Add failing DOM tests for annotations and reports**

```javascript
function testRuleAnnotationsRenderWithoutWriteControls() {
  const root = fakeRoot();
  renderPriority({
    root,
    payload: { available: true, items: [{
      content: "rug 加仓", group: "甲群", sender: "阿甲",
      observedAt: "2026-09-04T00:00:00Z", tags: ["高风险", "资金信号"],
      priority: 50, severity: "critical",
    }] },
    api: {},
  });
  assert.ok(root.textContent.includes("高风险"));
  assert.ok(root.textContent.includes("优先级 50"));
  assert.strictEqual(descendants(root).filter((node) => node.attributes["data-write-action"]).length, 0);
}
```

Add analysis tests for cadence labels `2 小时`, `6 小时`, `24 小时`, window times, `credential_required`, retry waiting, topics/findings/CA, and source message bodies. Add inbox-card test coverage by exporting a focused `MessageRuleBadges(document, message)` helper.

- [ ] **Step 2: Run frontend tests and verify failure**

Run: `node scripts/test-wxfomo-lan-frontend.mjs`

Expected: FAIL because the new fields and helper are not rendered.

- [ ] **Step 3: Render inbox badges and priority metadata**

Add one badge row above the message body. Use text-only labels, severity-specific classes, and a maximum visible tag count with an overflow count; keep the full text in accessible `aria-label` content. Do not inject HTML from API strings.

- [ ] **Step 4: Extend analyses, alerts, rules, provider, and diagnostics pages**

Map job states to Chinese read-only labels, show cadence and `[windowStart, windowEnd)` explicitly, render only validated fields, and attach source messages beneath relevant summaries/findings. Configuration center shows `MiniMax-M2.7` plus configured/unconfigured state but no credential metadata.

- [ ] **Step 5: Add scoped styles without changing the existing layout**

Add `.message-rule-badges`, `.rule-tag`, `.severity-critical`, `.severity-warning`, `.analysis-cadence`, `.analysis-window`, and `.analysis-source-list`. Reuse existing theme variables and preserve narrow-window scrolling and focus visibility.

- [ ] **Step 6: Run frontend tests**

Run: `node scripts/test-wxfomo-lan-frontend.mjs`

Expected: all frontend tests PASS, including existing public-link and no-write-action safety tests.

- [ ] **Step 7: Commit the workbench presentation**

```bash
git add web/wxfomo-lan/app.mjs web/wxfomo-lan/pages.mjs web/wxfomo-lan/state.mjs web/wxfomo-lan/styles.css scripts/test-wxfomo-lan-frontend.mjs
git commit -m "feat: show WeCom rules and MiniMax reports"
```

---

### Task 9: Launcher Integration, Documentation, and End-to-End Verification

**Files:**
- Modify: `scripts/start-wxfomo-lan.sh:5-420`
- Modify: `scripts/test-wxfomo-lan-launcher.sh`
- Modify: `scripts/test-wxfomo-lan-launcher-readiness.sh`
- Modify: `README.md:406-470`

**Interfaces:**
- Consumes: worker entry point and analysis-aware web server.
- Produces: one launcher command that supervises listener, worker, and server while preserving current arguments and password.
- Adds launcher options: `--analysis-database PATH` and `--ai-credentials PATH`.

- [ ] **Step 1: Add failing launcher tests for the third child process**

Extend the fixture copy list with every new production file. Start without credentials and assert:

```zsh
worker_pid=$(wait_for_child "$launcher_pid" "wxfomo-analysis-worker.py") \
  || fail "analysis worker did not start"
kill -0 "$worker_pid" 2>/dev/null || fail "analysis worker is not running"
assert_analysis_status "$host" "$port" "$token_file" "false"
```

Add cases proving launcher cleanup terminates the worker, a killed worker is restarted with bounded backoff, a worker storage failure is visible and cannot be reported as ready, and raw message monitoring remains available when AI is unconfigured.

- [ ] **Step 2: Run launcher tests and verify failure**

Run: `zsh scripts/test-wxfomo-lan-launcher.sh`

Run: `zsh scripts/test-wxfomo-lan-launcher-readiness.sh`

Expected: FAIL because the launcher does not know the worker or its deployed files.

- [ ] **Step 3: Add worker paths, arguments, lifecycle, and readiness**

Default to:

```zsh
analysis_database="$user_home/Library/Application Support/wxFomo LAN/analysis.sqlite3"
ai_credentials="$user_home/Library/Application Support/wxFomo LAN/ai-credentials.json"
analysis_instance_id=$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')
```

Start the listener first, then the worker, then the server. Add `worker_pid` to signal forwarding and cleanup. Monitor worker liveness separately and restart it with the same bounded `1, 2, 4, 8` second backoff policy used for the server. Readiness requires active listener and worker heartbeats but does not require an AI key.

- [ ] **Step 4: Update deployment-readiness checks and user documentation**

Document:

1. revoke the key exposed in chat and create a new Token Plan key;
2. double-click `scripts/configure-wxfomo-ai.command` or run `python3 scripts/configure-wxfomo-ai.py`;
3. optionally run the explicit connection test;
4. start with the same `scripts/start-wxfomo-lan.sh --allow-lan` command;
5. expect 2-hour reports at even-hour `:05`, 6-hour reports at `00/06/12/18:10`, and daily reports at `00:15` Beijing time;
6. understand that monitored group content is sent to MiniMax but credentials remain local.

- [ ] **Step 5: Run all automated tests**

Run: `python3 -m unittest discover -s scripts -p 'test_wxfomo_*.py' -v`

Run: `node scripts/test-wxfomo-lan-frontend.mjs`

Run: `zsh scripts/test-message-event-consumer.sh`

Run: `zsh scripts/test-wecom-group-listener.sh`

Run: `zsh scripts/test-wxfomo-lan-launcher.sh`

Run: `zsh scripts/test-wxfomo-lan-launcher-readiness.sh`

Expected: every command exits 0; no test contacts MiniMax or uses a real credential.

- [ ] **Step 6: Run repository and secret hygiene checks**

Run: `git diff --check`

Run: `plan_key_prefix='sk''-cp-'; git grep -n -E "${plan_key_prefix}[A-Za-z0-9_-]{20,}"`

Expected: no output from either command.

- [ ] **Step 7: Commit launcher and documentation integration**

```bash
git add scripts/start-wxfomo-lan.sh scripts/test-wxfomo-lan-launcher.sh scripts/test-wxfomo-lan-launcher-readiness.sh README.md
git commit -m "feat: supervise scheduled MiniMax analysis"
```

- [ ] **Step 8: Restart the local service without using a real key**

Resolve the exact current launcher PID and child PIDs with `ps`; terminate only that launcher, then start the updated `scripts/start-wxfomo-lan.sh --allow-lan`. Verify `/api/bootstrap`, `/api/rules`, `/api/diagnostics`, and raw messages with the existing password. Expected: listener and worker are active, rules are available, and AI status is `unconfigured`.

- [ ] **Step 9: Ask the user to configure a newly rotated key locally**

Have the user run the double-clickable configuration command. Do not ask them to paste the new key into chat. After they report completion, run only the explicit connection test and verify it reports model and success without printing the key.

- [ ] **Step 10: Complete real end-to-end acceptance**

Use the test clock through the in-process worker test seam to create one harmless report window from non-sensitive fixture messages, then verify the live workbench displays the job, result, cadence, source IDs, and source messages. Confirm a second scheduler tick does not duplicate the same window and that POST remains 405.

- [ ] **Step 11: Commit any acceptance-only documentation corrections**

If live acceptance required documentation wording changes, stage only `README.md` and commit:

```bash
git add README.md
git commit -m "docs: clarify MiniMax analysis setup"
```

If no documentation changed, record the verified commands and outcomes in the final handoff without creating an empty commit.
