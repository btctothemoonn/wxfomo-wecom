import datetime
import http.client
import importlib.util
import io
import json
import os
import re
import stat
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
from contextlib import redirect_stderr
from html.parser import HTMLParser
from unittest import mock

from scripts.wxfomo_lan import security
from scripts.wxfomo_lan.analysis import AnalysisRepository
from scripts.wxfomo_lan.messages import (
    MessageRepository,
    MessageSourceUnavailable,
    decode_cursor,
    encode_cursor,
    merge_message_annotations,
)
from scripts.wxfomo_lan.server import ServerOptions, create_server


class FrontendSecurityParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.external_assets = []
        self.enabled_write_actions = []

    def handle_starttag(self, tag, attributes):
        values = dict(attributes)
        for name in ("src", "href"):
            value = values.get(name, "")
            if value.startswith(("http://", "https://")):
                self.external_assets.append(value)
        if "data-write-action" in values and "disabled" not in values:
            self.enabled_write_actions.append((tag, values["data-write-action"]))


def load_cli_module():
    script_path = os.path.join(os.path.dirname(__file__), "wxfomo-lan-server.py")
    scripts_directory = os.path.dirname(script_path)
    sys.path.insert(0, scripts_directory)
    try:
        specification = importlib.util.spec_from_file_location("wxfomo_lan_server_cli", script_path)
        module = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(module)
        return module
    finally:
        sys.path.pop(0)


class LanServerTests(unittest.TestCase):
    def test_scope_uses_frozen_input_and_local_references_not_visible_sample_count(self):
        path = os.path.join(self.temporary_directory.name, 'scope-analysis.sqlite3')
        self.create_analysis_fixture(path)
        with sqlite3.connect(path) as connection:
            connection.execute('UPDATE analysis_jobs SET source_event_ids_json=?',
                               (json.dumps(['event-a', 'missing', 'event-c']),))
        report = AnalysisRepository(path).analyses(MessageRepository(self.message_database, self.group_config_path))['items'][0]
        scope = report.get('scope', {})
        self.assertEqual(scope.get('analyzedCount'), 3)
        self.assertEqual(scope['readableCount'], 2)
        self.assertEqual(scope['missingCount'], 1)
        self.assertEqual(scope['timeZone'], 'Asia/Shanghai')
        self.assertFalse(scope['completeChatHistory'])
        self.assertFalse(scope['externalVerification'])
        self.assertEqual({m['eventId']: m['referenceId'] for m in report['sourceMessages']},
                         {'event-a': 'M0001', 'event-c': 'M0003'})

    def test_analysis_list_covers_three_shanghai_dates_without_deleting_history(self):
        path = os.path.join(self.temporary_directory.name, 'bounded-analysis.sqlite3')
        self.create_analysis_fixture(path)
        with sqlite3.connect(path) as connection:
            for index in range(35):
                connection.execute(
                    "INSERT INTO analysis_jobs SELECT ?, cadence, window_start, "
                    "window_end, state, source_event_ids_json, attempt, maximum_attempts, "
                    "next_attempt_at, error_code, credential_file_revision, created_at, updated_at "
                    "FROM analysis_jobs WHERE job_id='job-analysis-1'", ('copy-{}'.format(index),))
            for job_id, end in (
                ('too-old', '2024-08-31T15:59:59+00:00'),
                ('oldest-included', '2024-08-31T16:00:00+00:00'),
                ('tomorrow', '2024-09-03T16:00:00+00:00'),
            ):
                connection.execute(
                    "INSERT INTO analysis_jobs SELECT ?, cadence, window_start, ?, "
                    "state, source_event_ids_json, attempt, maximum_attempts, "
                    "next_attempt_at, error_code, credential_file_revision, created_at, updated_at "
                    "FROM analysis_jobs WHERE job_id='job-analysis-1'",
                    (job_id, datetime.datetime.fromisoformat(end).timestamp()))
            original_result = connection.execute('SELECT result_json FROM analysis_results').fetchone()[0]
        repository = AnalysisRepository(path)
        messages = MessageRepository(self.message_database, self.group_config_path)
        payload = repository.analyses(messages)
        self.assertEqual(len(payload['items']), 37, 'three days must not be truncated at 30 jobs')
        self.assertIn('oldest-included', {item['jobId'] for item in payload['items']})
        self.assertNotIn('too-old', {item['jobId'] for item in payload['items']})
        self.assertNotIn('tomorrow', {item['jobId'] for item in payload['items']})
        self.assertEqual(payload['dateRange'], {'minDate': '2024-09-01', 'maxDate': '2024-09-03',
                                              'timeZone': 'Asia/Shanghai', 'dateBasis': 'windowEnd'})
        self.analysis_now.return_value = datetime.datetime.fromisoformat('2024-09-03T16:00:00+00:00').timestamp()
        next_day = repository.analyses(messages)
        self.assertEqual(next_day['dateRange']['minDate'], '2024-09-02')
        self.assertEqual(next_day['dateRange']['maxDate'], '2024-09-04')
        self.assertNotIn('oldest-included', {item['jobId'] for item in next_day['items']})
        self.assertIn('tomorrow', {item['jobId'] for item in next_day['items']})
        with sqlite3.connect(path) as connection:
            self.assertEqual(connection.execute('SELECT COUNT(*) FROM analysis_jobs').fetchone()[0], 39)
            self.assertEqual(connection.execute('SELECT result_json FROM analysis_results').fetchone()[0], original_result)

    def test_ca_cards_use_full_frozen_scope_and_keep_sources(self):
        path = os.path.join(self.temporary_directory.name, 'analysis-ca.sqlite3')
        self.create_analysis_fixture(path)
        address = '0x' + 'a' * 40
        with sqlite3.connect(self.message_database) as connection:
            connection.execute("UPDATE messages SET content=?, sender_display_name='猫'", ('Base: '+address,))
            connection.execute("UPDATE messages SET group_name='另一个群' WHERE event_id='event-b'")
        with sqlite3.connect(path) as connection:
            connection.execute("UPDATE analysis_jobs SET source_event_ids_json=?", (json.dumps(['event-a','event-b','event-c']),))
        report = AnalysisRepository(path).analyses(MessageRepository(self.message_database, self.group_config_path))['items'][0]
        card = report['crossGroupCA']['items'][0]
        self.assertEqual(card['mentionCount'], 3)
        self.assertEqual(card['uniqueStatementCount'], 1)
        self.assertTrue(report['crossGroupCA']['sourcesComplete'])
        self.assertTrue(set(card['sourceMessageIDs']).issubset({m['eventId'] for m in report['sourceMessages']}))
        with sqlite3.connect(self.message_database) as connection:
            connection.execute("DELETE FROM messages WHERE event_id='event-b'")
        partial = AnalysisRepository(path).analyses(MessageRepository(self.message_database, self.group_config_path))['items'][0]
        self.assertFalse(partial['crossGroupCA']['sourcesComplete'])

    def test_summary_lite_has_no_market_or_trading_apis(self):
        for path in ('/api/meme', '/api/market', '/api/trades', '/api/automations'):
            status, _, _ = self.request('GET', path, {'Authorization': 'Bearer test-token'})
            self.assertEqual(status, 404, path)
        settings = self.authorized_json('/api/settings/status')
        self.assertNotIn('tradingConfigured', settings)
        self.assertNotIn('speechConfigured', settings)
        self.assertNotIn('nativeSettingsDependency', settings)
        diagnostics = self.authorized_json('/api/diagnostics')
        self.assertNotIn('workspace', diagnostics.get('sources', {}))
        self.assertNotIn('configuration', diagnostics.get('sources', {}))

    def setUp(self):
        # Freeze only the analysis read-window clock; listener liveness uses real time.
        analysis_clock = mock.patch('scripts.wxfomo_lan.analysis.current_time', return_value=1725364800, create=True)
        self.analysis_now = analysis_clock.start()
        self.addCleanup(analysis_clock.stop)
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.token_path = os.path.join(self.temporary_directory.name, "private", "token")
        self.static_root = os.path.abspath(
            os.path.join(os.path.dirname(__file__), "..", "web", "wxfomo-lan")
        )
        self.message_database = os.path.join(self.temporary_directory.name, "messages.sqlite3")
        self.group_config_path = os.path.join(
            self.temporary_directory.name, "wecom-groups.txt"
        )
        self.create_message_fixture(self.message_database)
        self.server = create_server(
            ServerOptions(
                host="127.0.0.1",
                port=0,
                token="test-token",
                static_root=self.static_root,
                message_database=self.message_database,
                group_config_path=self.group_config_path,
                workspace_database=os.path.join(self.temporary_directory.name, "workspace.sqlite3"),
                configuration_path=os.path.join(self.temporary_directory.name, "configuration-center.json"),
            )
        )
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()
        self.addCleanup(self.stop_server)

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, method, path, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port)
        connection.request(method, path, headers=headers or {})
        response = connection.getresponse()
        body = response.read().decode("utf-8")
        result = response.status, dict(response.getheaders()), body
        connection.close()
        return result

    def request_from_server(self, server, method, path, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", server.server_port)
        connection.request(method, path, headers=headers or {})
        response = connection.getresponse()
        body = response.read().decode("utf-8")
        result = response.status, dict(response.getheaders()), body
        connection.close()
        return result

    def authorized_json(self, path):
        status, _, body = self.request(
            "GET", path, {"Authorization": "Bearer test-token"}
        )
        self.assertEqual(status, 200)
        return json.loads(body)

    def create_message_fixture(self, path):
        connection = sqlite3.connect(path)
        self.addCleanup(connection.close)
        connection.executescript(
            """
            CREATE TABLE conversations(
              id INTEGER PRIMARY KEY,
              group_name TEXT NOT NULL,
              message_count INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE messages(
              id INTEGER PRIMARY KEY,
              event_id TEXT NOT NULL UNIQUE,
              conversation_id INTEGER NOT NULL,
              group_name TEXT NOT NULL,
              sender_display_name TEXT,
              content TEXT NOT NULL,
              message_type TEXT NOT NULL,
              observed_at REAL NOT NULL,
              source_sequence INTEGER
            );
            """
        )
        connection.executemany(
            "INSERT INTO conversations(id, group_name, message_count) VALUES (?, ?, ?)",
            [(1, "甲群", 2), (2, "乙群", 1)],
        )
        connection.executemany(
            """
            INSERT INTO messages(
              id, event_id, conversation_id, group_name, sender_display_name, content,
              message_type, observed_at, source_sequence
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                (1, "event-a", 1, "甲群", "阿甲", "beta message", "text", 1725256800, 39),
                (2, "event-b", 1, "甲群", "阿乙", "alpha message", "text", 1725256800, 40),
                (3, "event-c", 2, "乙群", "阿丙", "gamma message", "media", 1725256800, 41),
            ],
        )
        connection.commit()

    def create_analysis_fixture(self, path):
        connection = sqlite3.connect(path)
        connection.executescript(
            """
            CREATE TABLE analysis_worker_state(
              singleton_id INTEGER PRIMARY KEY,
              instance_id TEXT,
              heartbeat_at REAL,
              rule_cursor_time REAL,
              rule_cursor_event_id TEXT,
              rule_catalog_version INTEGER,
              provider_not_before REAL,
              credential_status TEXT,
              last_provider_success_at REAL,
              last_error_code TEXT,
              updated_at REAL NOT NULL
            );
            CREATE TABLE message_rule_matches(
              event_id TEXT NOT NULL,
              rule_id TEXT NOT NULL,
              priority INTEGER NOT NULL,
              severity TEXT,
              tags_json TEXT NOT NULL,
              matched_terms_json TEXT NOT NULL,
              created_at REAL NOT NULL
            );
            CREATE TABLE rule_alerts(
              alert_id INTEGER PRIMARY KEY,
              event_id TEXT NOT NULL,
              rule_id TEXT NOT NULL,
              severity TEXT NOT NULL,
              title TEXT NOT NULL,
              occurrence_count INTEGER NOT NULL,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL
            );
            CREATE TABLE analysis_jobs(
              job_id TEXT PRIMARY KEY,
              cadence TEXT NOT NULL,
              window_start REAL NOT NULL,
              window_end REAL NOT NULL,
              state TEXT NOT NULL,
              source_event_ids_json TEXT NOT NULL,
              attempt INTEGER NOT NULL,
              maximum_attempts INTEGER NOT NULL,
              next_attempt_at REAL,
              error_code TEXT,
              credential_file_revision TEXT,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL
            );
            CREATE TABLE analysis_results(
              analysis_id INTEGER PRIMARY KEY,
              job_id TEXT NOT NULL,
              result_json TEXT NOT NULL,
              model TEXT,
              provider_request_id TEXT,
              input_tokens INTEGER,
              output_tokens INTEGER,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL
            );
            """
        )
        connection.execute(
            "INSERT INTO analysis_worker_state VALUES (1, ?, ?, ?, ?, 1, NULL, ?, ?, NULL, ?)",
            (
                "11111111-1111-4111-8111-111111111111",
                time.time(),
                1725256800,
                "event-c",
                "configured",
                1725256810,
                time.time(),
            ),
        )
        connection.execute(
            "INSERT INTO message_rule_matches VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                "event-c",
                "recommended.risk.contract-liquidity",
                50,
                "critical",
                '["\u9ad8\u98ce\u9669"]',
                '["rug"]',
                1725256800,
            ),
        )
        connection.execute(
            "INSERT INTO rule_alerts VALUES (1, ?, ?, ?, ?, 1, ?, ?)",
            (
                "event-c",
                "recommended.risk.contract-liquidity",
                "critical",
                "\u98ce\u9669\uff5c\u5408\u7ea6\u4e0e\u6d41\u52a8\u6027\u5371\u9669",
                1725256800,
                1725256810,
            ),
        )
        connection.execute(
            "INSERT INTO analysis_jobs VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?)",
            (
                "job-analysis-1",
                "two_hour",
                1725249600,
                1725256800,
                "succeeded",
                '["event-c"]',
                1,
                5,
                "1:2:3:4",
                1725256800,
                1725256810,
            ),
        )
        connection.execute(
            "INSERT INTO analysis_results VALUES (1, ?, ?, ?, ?, 10, 20, ?, ?)",
            (
                "job-analysis-1",
                json.dumps(
                    {
                        "summary": "Safe LAN summary",
                        "summarySourceMessageIDs": ["event-c"],
                        "topics": [{
                            "topicID": "topic-1",
                            "title": "Risk topic",
                            "summary": "Risk increased",
                            "sourceMessageIDs": ["event-c"],
                        }],
                        "findings": [{
                            "findingID": "finding-1",
                            "category": "risk",
                            "text": "Review liquidity",
                            "epistemicStatus": "fact",
                            "sourceMessageIDs": ["event-c"],
                        }],
                        "cryptoAddresses": [{
                            "address": "0xSafe",
                            "normalizedAddress": "0xsafe",
                            "contextSummary": "Mentioned in risk report",
                            "epistemicStatus": "fact",
                            "sourceMessageIDs": ["event-c"],
                        }],
                        "credentialRevision": "NEVER_EXPOSE_REVISION",
                        "credential": "dummy-plan-key",
                    }
                ),
                "MiniMax-M2.7",
                "provider-request-1",
                1725256800,
                1725256810,
            ),
        )
        connection.commit()
        connection.close()

    def test_configured_lan_analysis_populates_read_only_endpoints(self):
        analysis_path = os.path.join(
            self.temporary_directory.name, "analysis.sqlite3"
        )
        self.create_analysis_fixture(analysis_path)
        options = ServerOptions(
            host="127.0.0.1",
            port=0,
            token="test-token",
            static_root=self.static_root,
            message_database=self.message_database,
            group_config_path=self.group_config_path,
            workspace_database=os.path.join(
                self.temporary_directory.name, "missing-workspace.sqlite3"
            ),
            configuration_path=os.path.join(
                self.temporary_directory.name, "must-not-open-credentials.json"
            ),
            analysis_database=analysis_path,
        )
        analysis_server = create_server(options)
        analysis_thread = threading.Thread(target=analysis_server.serve_forever)
        analysis_thread.start()
        self.addCleanup(analysis_thread.join)
        self.addCleanup(analysis_server.server_close)
        self.addCleanup(analysis_server.shutdown)

        def payload(path):
            status, _, body = self.request_from_server(
                analysis_server,
                "GET",
                path,
                {"Authorization": "Bearer test-token"},
            )
            self.assertEqual(status, 200)
            return json.loads(body)

        message = payload("/api/messages?limit=1")["items"][0]
        self.assertEqual(message["eventId"], "event-c")
        self.assertEqual(message.get("tags"), ["高风险"])
        self.assertEqual(message.get("severity"), "critical")
        self.assertEqual(message.get("priority"), 50)
        self.assertEqual(message.get("matchedTerms"), ["rug"])
        self.assertEqual(
            message.get("matchedRules"),
            [{
                "ruleId": "recommended.risk.contract-liquidity",
                "name": "风险｜合约与流动性危险",
                "priority": 50,
            }],
        )
        rule = payload("/api/rules")["items"][0]
        self.assertEqual(rule["priority"], 50)
        self.assertEqual(rule.get("id"), rule["ruleId"])
        self.assertIn("updatedAt", rule)
        self.assertIsNone(rule["updatedAt"])
        alert = payload("/api/alerts")["items"][0]
        self.assertEqual(alert["sourceMessages"][0]["eventId"], "event-c")
        self.assertEqual(alert["sourceMessages"][0]["tags"], ["高风险"])
        self.assertEqual(payload("/api/priority")["items"][0]["priority"], 50)
        analysis = payload("/api/analyses")["items"][0]
        self.assertEqual(analysis["cadence"], "two_hour")
        self.assertEqual(analysis.get("mode"), "digest")
        self.assertEqual(analysis["summarySourceMessageIDs"], ["event-c"])
        self.assertEqual(analysis.get("sourceReferences"), ["event-c"])
        self.assertEqual(analysis.get("uncertainties"), [])
        self.assertEqual(analysis["topics"][0]["sourceMessageIDs"], ["event-c"])
        self.assertEqual(analysis["topics"][0].get("topicID"), "topic-1")
        self.assertEqual(analysis["topics"][0].get("topicId"), "topic-1")
        self.assertEqual(
            analysis["topics"][0].get("sourceReferences"), ["event-c"]
        )
        self.assertEqual(analysis["findings"][0]["category"], "risk")
        self.assertEqual(analysis["findings"][0].get("findingID"), "finding-1")
        self.assertEqual(analysis["findings"][0].get("findingId"), "finding-1")
        self.assertEqual(
            analysis["findings"][0].get("sourceReferences"), ["event-c"]
        )
        self.assertEqual(
            analysis["cryptoAddresses"][0]["normalizedAddress"], "0xsafe"
        )
        self.assertEqual(analysis["cryptoAddresses"][0].get("address"), "0xSafe")
        self.assertEqual(analysis["sourceMessages"][0]["tags"], ["高风险"])
        diagnostics = payload("/api/diagnostics")
        self.assertEqual(
            diagnostics.get("ruleEvaluation"),
            {"messageCount": 1, "cursorTime": "2024-09-02T06:00:00Z", "cursorEventId": "event-c"},
        )
        self.assertEqual(
            diagnostics.get("jobCounts"),
            {
                "queued": 0,
                "running": 0,
                "retryWait": 0,
                "credentialRequired": 0,
                "failed": 0,
                "succeeded": 1,
                "skippedEmpty": 0,
            },
        )

        serialized = json.dumps(
            {
                path: payload(path)
                for path in (
                    "/api/messages",
                    "/api/analyses",
                    "/api/settings/status",
                    "/api/diagnostics",
                )
            }
        )
        self.assertNotIn("dummy-plan-key", serialized)
        self.assertNotIn("credentialRevision", serialized)

    def test_unavailable_analysis_never_hides_or_fabricates_messages(self):
        cases = []
        missing = os.path.join(self.temporary_directory.name, "missing-analysis.sqlite3")
        cases.append(("missing", missing, "source_unavailable", None))

        corrupt = os.path.join(self.temporary_directory.name, "corrupt-analysis.sqlite3")
        with open(corrupt, "wb") as stream:
            stream.write(b"not a sqlite database")
        cases.append(("corrupt", corrupt, "source_corrupt", None))

        incompatible = os.path.join(
            self.temporary_directory.name, "incompatible-analysis.sqlite3"
        )
        connection = sqlite3.connect(incompatible)
        connection.execute("CREATE TABLE unrelated(value INTEGER)")
        connection.close()
        cases.append(("schema", incompatible, "schema_incompatible", None))

        denied_directory = os.path.join(self.temporary_directory.name, "analysis-denied")
        os.mkdir(denied_directory, 0o700)
        denied = os.path.join(denied_directory, "analysis.sqlite3")
        connection = sqlite3.connect(denied)
        connection.execute("CREATE TABLE unrelated(value INTEGER)")
        connection.close()
        os.chmod(denied_directory, 0o000)
        self.addCleanup(os.chmod, denied_directory, 0o700)
        cases.append(("permission", denied, "source_permission_denied", None))

        locked = os.path.join(self.temporary_directory.name, "locked-analysis.sqlite3")
        self.create_analysis_fixture(locked)
        lock = sqlite3.connect(locked, timeout=0)
        lock.execute("PRAGMA locking_mode=EXCLUSIVE")
        lock.execute("BEGIN EXCLUSIVE")
        self.addCleanup(lock.close)
        cases.append(("locked", locked, "source_locked", lock))

        for label, analysis_path, expected_reason, held_lock in cases:
            with self.subTest(label=label):
                options = ServerOptions(
                    host="127.0.0.1",
                    port=0,
                    token="test-token",
                    static_root=self.static_root,
                    message_database=self.message_database,
                    group_config_path=self.group_config_path,
                    workspace_database=os.path.join(
                        self.temporary_directory.name, "missing-workspace.sqlite3"
                    ),
                    configuration_path=os.path.join(
                        self.temporary_directory.name, "must-not-open.json"
                    ),
                    analysis_database=analysis_path,
                )
                temporary_server = create_server(options)
                temporary_thread = threading.Thread(
                    target=temporary_server.serve_forever
                )
                temporary_thread.start()
                try:
                    status, _, body = self.request_from_server(
                        temporary_server,
                        "GET",
                        "/api/messages?limit=1",
                        {"Authorization": "Bearer test-token"},
                    )
                    self.assertEqual(status, 200)
                    message = json.loads(body)["items"][0]
                    for field in (
                        "tags", "matchedRules", "priority", "severity",
                        "matchedTerms",
                    ):
                        self.assertNotIn(field, message)
                    status, _, body = self.request_from_server(
                        temporary_server,
                        "GET",
                        "/api/alerts",
                        {"Authorization": "Bearer test-token"},
                    )
                    self.assertEqual(status, 200)
                    self.assertEqual(json.loads(body)["reason"], expected_reason)
                finally:
                    temporary_server.shutdown()
                    temporary_server.server_close()
                    temporary_thread.join()
        lock.rollback()

    def test_annotation_merge_is_pure_and_only_adds_persisted_fields(self):
        source = [{"eventId": "event-a", "content": "safe"}]
        annotations = {
            "event-a": {
                "tags": ["高风险"],
                "matchedRules": [{"ruleId": "rule-1", "priority": 50}],
                "priority": 50,
                "severity": "critical",
                "matchedTerms": ["rug"],
            }
        }

        merged = merge_message_annotations(source, annotations)

        self.assertEqual(merged[0]["tags"], ["高风险"])
        self.assertNotIn("tags", source[0])
        merged[0]["tags"].append("changed")
        merged[0]["matchedRules"][0]["priority"] = 0
        self.assertEqual(annotations["event-a"]["tags"], ["高风险"])
        self.assertEqual(
            annotations["event-a"]["matchedRules"][0]["priority"], 50
        )
        self.assertEqual(
            merge_message_annotations(source, {})[0], source[0]
        )

    def test_analysis_repository_connection_is_query_only(self):
        analysis_path = os.path.join(
            self.temporary_directory.name, "query-only-analysis.sqlite3"
        )
        self.create_analysis_fixture(analysis_path)
        connection = AnalysisRepository(analysis_path)._open()
        self.addCleanup(connection.close)

        self.assertEqual(connection.execute("PRAGMA query_only").fetchone()[0], 1)
        with self.assertRaises(sqlite3.OperationalError):
            connection.execute("DELETE FROM rule_alerts")

    def test_settings_validate_only_needed_state_and_never_open_credentials(self):
        analysis_path = os.path.join(
            self.temporary_directory.name, "settings-only-analysis.sqlite3"
        )
        connection = sqlite3.connect(analysis_path)
        connection.execute(
            """
            CREATE TABLE analysis_worker_state(
              singleton_id INTEGER PRIMARY KEY,
              rule_catalog_version INTEGER,
              credential_status TEXT,
              last_provider_success_at REAL,
              last_error_code TEXT
            )
            """
        )
        connection.execute(
            "INSERT INTO analysis_worker_state VALUES (1, 1, 'configured', ?, NULL)",
            (1725256810,),
        )
        connection.commit()
        connection.close()
        credentials_path = os.path.join(
            self.temporary_directory.name, "credentials-must-not-open.json"
        )
        with open(credentials_path, "w", encoding="utf-8") as stream:
            stream.write('{"apiKey":"dummy-plan-key"}')
        options = ServerOptions(
            host="127.0.0.1",
            port=0,
            token="test-token",
            static_root=self.static_root,
            message_database=self.message_database,
            group_config_path=self.group_config_path,
            workspace_database=os.path.join(
                self.temporary_directory.name, "missing-native.sqlite3"
            ),
            configuration_path=credentials_path,
            analysis_database=analysis_path,
        )
        temporary_server = create_server(options)
        temporary_thread = threading.Thread(target=temporary_server.serve_forever)
        temporary_thread.start()
        try:
            with mock.patch("builtins.open", side_effect=AssertionError("opened credentials")):
                status, _, body = self.request_from_server(
                    temporary_server,
                    "GET",
                    "/api/settings/status",
                    {"Authorization": "Bearer test-token"},
                )
                self.assertEqual(status, 200)
                settings = json.loads(body)
                self.assertEqual(settings["available"], True)
                self.assertEqual(settings["aiConfigured"], True)
                self.assertEqual(settings["providerNames"], ["MiniMax-M2.7"])
                status, _, body = self.request_from_server(
                    temporary_server,
                    "GET",
                    "/api/diagnostics",
                    {"Authorization": "Bearer test-token"},
                )
                self.assertEqual(status, 200)
                diagnostics = json.loads(body)
                self.assertEqual(
                    diagnostics["sources"]["analysis"]["reason"],
                    "schema_incompatible",
                )
            self.assertNotIn("dummy-plan-key", json.dumps((settings, diagnostics)))
        finally:
            temporary_server.shutdown()
            temporary_server.server_close()
            temporary_thread.join()

    def test_invalid_analysis_rows_are_bounded_and_isolated_by_endpoint(self):
        analysis_path = os.path.join(
            self.temporary_directory.name, "invalid-analysis.sqlite3"
        )
        self.create_analysis_fixture(analysis_path)
        connection = sqlite3.connect(analysis_path)
        connection.execute(
            "INSERT INTO message_rule_matches VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                "event-b", "recommended.signal.exit", 40, "warning",
                "{not-json", '["\u6e05\u4ed3"]', 1725256801,
            ),
        )
        connection.execute(
            "UPDATE analysis_results SET result_json = ?",
            (json.dumps({"summary": "x" * (64 * 1024)}),),
        )
        connection.execute(
            "INSERT INTO rule_alerts VALUES (2, ?, ?, ?, ?, 1, ?, ?)",
            (
                "event-b",
                "recommended.signal.exit",
                "warning",
                "unsafe\u202etitle",
                1725256801,
                1725256811,
            ),
        )
        connection.commit()
        connection.close()
        options = ServerOptions(
            host="127.0.0.1",
            port=0,
            token="test-token",
            static_root=self.static_root,
            message_database=self.message_database,
            group_config_path=self.group_config_path,
            workspace_database="",
            configuration_path="",
            analysis_database=analysis_path,
        )
        temporary_server = create_server(options)
        temporary_thread = threading.Thread(target=temporary_server.serve_forever)
        temporary_thread.start()
        try:
            def payload(path):
                status, _, body = self.request_from_server(
                    temporary_server,
                    "GET",
                    path,
                    {"Authorization": "Bearer test-token"},
                )
                self.assertEqual(status, 200)
                return json.loads(body)

            priority = payload("/api/priority")
            self.assertEqual(
                [item["eventId"] for item in priority["items"]], ["event-c"]
            )
            self.assertEqual(priority.get("invalidRows"), 1)
            analyses = payload("/api/analyses")
            self.assertEqual(analyses["items"], [])
            self.assertEqual(analyses.get("invalidRows"), 1)
            alerts = payload("/api/alerts")
            self.assertEqual(alerts["available"], True)
            self.assertEqual(len(alerts["items"]), 1)
            self.assertEqual(alerts.get("invalidRows"), 1)
        finally:
            temporary_server.shutdown()
            temporary_server.server_close()
            temporary_thread.join()

    def test_analysis_large_frozen_windows_remain_visible_with_bounded_sources(self):
        analysis_path = os.path.join(self.temporary_directory.name, "large-analysis.sqlite3")
        self.create_analysis_fixture(analysis_path)
        frozen_ids = ["event-window-{:05d}".format(index) for index in range(8366)]
        frozen_ids.append("event-c")
        frozen_json = json.dumps(frozen_ids)
        self.assertGreater(len(frozen_json.encode("utf-8")), 64 * 1024)
        connection = sqlite3.connect(analysis_path)
        connection.execute(
            "UPDATE analysis_jobs SET source_event_ids_json = ?", (frozen_json,)
        )
        for job_id, state, source_json in (
            ("job-queued-686", "queued", json.dumps(frozen_ids[:686])),
            ("job-retry-8367", "retry_waiting", frozen_json),
        ):
            connection.execute(
                "INSERT INTO analysis_jobs SELECT ?, cadence, window_start, "
                "window_end, ?, ?, attempt, maximum_attempts, next_attempt_at, "
                "error_code, credential_file_revision, created_at, updated_at "
                "FROM analysis_jobs WHERE job_id = 'job-analysis-1'",
                (job_id, state, source_json),
            )
        connection.commit()
        connection.close()
        connection = sqlite3.connect(self.message_database)
        connection.executemany(
            "INSERT INTO messages(event_id, conversation_id, group_name, "
            "content, message_type, observed_at) VALUES (?, 1, 'fixture', "
            "'Offline source message', 'text', 1725256800)",
            [(event_id,) for event_id in frozen_ids[:-1]],
        )
        connection.commit()
        connection.close()
        analysis_server = create_server(ServerOptions(
            host="127.0.0.1", port=0, token="test-token",
            static_root=self.static_root, message_database=self.message_database,
            group_config_path=self.group_config_path, workspace_database="",
            configuration_path="", analysis_database=analysis_path,
        ))
        analysis_thread = threading.Thread(target=analysis_server.serve_forever)
        analysis_thread.start()
        self.addCleanup(analysis_thread.join)
        self.addCleanup(analysis_server.server_close)
        self.addCleanup(analysis_server.shutdown)

        status, _, body = self.request_from_server(
            analysis_server, "GET", "/api/analyses",
            {"Authorization": "Bearer test-token"},
        )

        self.assertEqual(status, 200)
        payload = json.loads(body)
        self.assertTrue(payload["available"])
        self.assertEqual(payload.get("invalidRows", 0), 0)
        jobs = {item["jobId"]: item for item in payload["items"]}
        self.assertEqual(set(jobs), {
            "job-analysis-1", "job-queued-686", "job-retry-8367",
        })
        succeeded = jobs["job-analysis-1"]
        self.assertEqual(succeeded["sourceReferences"], ["event-c"])
        self.assertEqual(len(succeeded["sourceMessages"]), 1000)
        self.assertEqual(succeeded["sourceMessages"][0]["eventId"], "event-c")
        self.assertEqual(succeeded["sourceMessages"][0]["tags"], ["高风险"])
        self.assertEqual(jobs["job-queued-686"]["state"], "queued")
        self.assertEqual(len(jobs["job-queued-686"]["sourceMessages"]), 686)
        self.assertEqual(jobs["job-retry-8367"]["state"], "retry_wait")
        self.assertEqual(len(jobs["job-retry-8367"]["sourceMessages"]), 1000)
        connection = sqlite3.connect(analysis_path)
        stored = connection.execute(
            "SELECT source_event_ids_json FROM analysis_jobs "
            "WHERE job_id = 'job-analysis-1'"
        ).fetchone()[0]
        connection.close()
        self.assertEqual(stored, frozen_json)

    def test_analysis_diagnostics_combine_persisted_and_legacy_retry_states(self):
        analysis_path = os.path.join(self.temporary_directory.name, "retry-analysis.sqlite3")
        self.create_analysis_fixture(analysis_path)
        connection = sqlite3.connect(analysis_path)
        connection.execute("UPDATE analysis_jobs SET state = 'retry_waiting'")
        for job_id, state in (
            ("job-retry-current", "retry_waiting"),
            ("job-retry-legacy", "retry_wait"),
        ):
            connection.execute(
                "INSERT INTO analysis_jobs SELECT ?, cadence, window_start, "
                "window_end, ?, source_event_ids_json, attempt, maximum_attempts, "
                "next_attempt_at, error_code, credential_file_revision, created_at, "
                "updated_at FROM analysis_jobs WHERE job_id = 'job-analysis-1'",
                (job_id, state),
            )
        connection.commit()
        connection.close()

        payload = AnalysisRepository(analysis_path).diagnostics()

        self.assertTrue(payload["sources"]["analysisJobs"]["available"])
        self.assertEqual(payload["jobCounts"]["retryWait"], 3)
        self.assertEqual(payload["jobCounts"]["succeeded"], 0)

    def test_analysis_large_windows_still_validate_all_frozen_ids_and_references(self):
        analysis_path = os.path.join(self.temporary_directory.name, "invalid-large-analysis.sqlite3")
        self.create_analysis_fixture(analysis_path)
        frozen_ids = ["event-window-{:05d}".format(index) for index in range(8366)]
        frozen_ids.append("event-c")
        connection = sqlite3.connect(analysis_path)
        original = json.loads(connection.execute(
            "SELECT result_json FROM analysis_results"
        ).fetchone()[0])
        repository = AnalysisRepository(analysis_path)
        messages = MessageRepository(self.message_database, self.group_config_path)
        for section in ("summary", "topics", "findings", "cryptoAddresses", "frozen_ids"):
            with self.subTest(section=section):
                result = json.loads(json.dumps(original))
                source_ids = list(frozen_ids)
                if section == "summary":
                    result["summarySourceMessageIDs"] = ["event-a"]
                elif section == "frozen_ids":
                    source_ids[-1] = "invalid\u202esource"
                else:
                    result[section][0]["sourceMessageIDs"] = ["event-a"]
                connection.execute(
                    "UPDATE analysis_jobs SET source_event_ids_json = ?",
                    (json.dumps(source_ids),),
                )
                connection.execute(
                    "UPDATE analysis_results SET result_json = ?", (json.dumps(result),)
                )
                connection.commit()

                payload = repository.analyses(messages)

                self.assertEqual(payload["items"], [])
                self.assertEqual(payload.get("invalidRows"), 1)
        connection.close()

    def test_priority_uses_message_time_after_rule_priority(self):
        analysis_path = os.path.join(
            self.temporary_directory.name, "priority-analysis.sqlite3"
        )
        self.create_analysis_fixture(analysis_path)
        connection = sqlite3.connect(analysis_path)
        connection.execute(
            "UPDATE message_rule_matches SET created_at = 9999999999 "
            "WHERE event_id = 'event-c'"
        )
        connection.execute(
            "INSERT INTO message_rule_matches VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                "event-a", "recommended.risk.contract-liquidity", 50,
                "critical", '["\u9ad8\u98ce\u9669"]', '["rug"]', 1,
            ),
        )
        connection.commit()
        connection.close()
        connection = sqlite3.connect(self.message_database)
        connection.execute(
            "UPDATE messages SET observed_at = 1725256900 WHERE event_id = 'event-a'"
        )
        connection.commit()
        connection.close()
        repository = AnalysisRepository(analysis_path)

        payload = repository.priority(
            MessageRepository(self.message_database, self.group_config_path)
        )

        self.assertEqual(
            [item["eventId"] for item in payload["items"]],
            ["event-a", "event-c"],
        )

    def test_api_requires_bearer_token(self):
        status, _, _ = self.request("GET", "/api/bootstrap")
        self.assertEqual(status, 401)

    def test_authorized_get_reaches_api(self):
        status, _, body = self.request(
            "GET", "/api/bootstrap", {"Authorization": "Bearer test-token"}
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["readOnly"], True)

    def test_bootstrap_returns_groups_counts_and_source_status(self):
        payload = self.authorized_json("/api/bootstrap")
        self.assertEqual(payload["readOnly"], True)
        self.assertEqual(payload["messageSource"]["available"], True)
        self.assertEqual([group["name"] for group in payload["groups"]], ["甲群", "乙群"])
        self.assertEqual(payload["counts"]["inbox"], 3)

    def test_bootstrap_uses_listener_snapshot_and_reports_fresh_heartbeat(self):
        connection = sqlite3.connect(self.message_database)
        connection.execute(
            """
            CREATE TABLE listener_state(
              singleton_id INTEGER PRIMARY KEY CHECK(singleton_id = 1),
              instance_id TEXT NOT NULL,
              group_names_json TEXT NOT NULL,
              started_at REAL NOT NULL,
              heartbeat_at REAL NOT NULL,
              cursor_timestamp REAL,
              cursor_record_id INTEGER,
              updated_at REAL NOT NULL
            )
            """
        )
        connection.execute(
            """
            INSERT INTO listener_state(
              singleton_id, instance_id, group_names_json, started_at, heartbeat_at,
              cursor_timestamp, cursor_record_id, updated_at
            ) VALUES (1, '11111111-1111-4111-8111-111111111111', '["snapshot-group","甲群"]',
                      strftime('%s','now'), strftime('%s','now'), 1, 1, strftime('%s','now'))
            """
        )
        connection.commit()
        connection.close()
        with open(self.group_config_path, "w", encoding="utf-8") as stream:
            stream.write("已更改但未重启的群\n")

        payload = self.authorized_json("/api/bootstrap")

        self.assertEqual(
            payload["groups"],
            [
                {"name": "snapshot-group", "count": 0},
                {"name": "甲群", "count": 2},
                {"name": "乙群", "count": 1},
            ],
        )
        self.assertEqual(payload["messageSource"]["listenerState"], "active")
        self.assertEqual(
            payload["messageSource"]["instanceId"],
            "11111111-1111-4111-8111-111111111111",
        )
        self.assertIn("startedAt", payload["messageSource"])
        self.assertEqual(payload["listenerState"], "active")
        self.assertNotIn("已更改但未重启的群", json.dumps(payload, ensure_ascii=False))

    def test_bootstrap_classifies_stale_malformed_future_and_missing_listener_state(self):
        connection = sqlite3.connect(self.message_database)
        connection.execute(
            """
            CREATE TABLE listener_state(
              singleton_id INTEGER PRIMARY KEY CHECK(singleton_id = 1),
              instance_id TEXT NOT NULL,
              group_names_json TEXT NOT NULL,
              started_at REAL NOT NULL,
              heartbeat_at,
              cursor_timestamp REAL,
              cursor_record_id INTEGER,
              updated_at REAL NOT NULL
            )
            """
        )
        connection.execute(
            """
            INSERT INTO listener_state(
              singleton_id, instance_id, group_names_json, started_at, heartbeat_at, updated_at
            ) VALUES (1, 'fixture', '["snapshot"]', 1, ?, 1)
            """,
            (time.time() - 30,),
        )
        connection.commit()
        connection.close()

        stale = self.authorized_json("/api/bootstrap")
        self.assertEqual(stale["listenerState"], "inactive")
        self.assertEqual(stale["messageSource"]["listenerState"], "inactive")

        connection = sqlite3.connect(self.message_database)
        connection.execute(
            "UPDATE listener_state SET group_names_json = ?, heartbeat_at = ? WHERE singleton_id = 1",
            ('{"not":"a list","secret":"NEVER_EXPOSE_STATE"}', "not-a-number"),
        )
        connection.commit()
        connection.close()
        malformed = self.authorized_json("/api/bootstrap")
        self.assertEqual(malformed["listenerState"], "unknown")
        self.assertNotIn("NEVER_EXPOSE_STATE", json.dumps(malformed))

        connection = sqlite3.connect(self.message_database)
        connection.execute(
            "UPDATE listener_state SET heartbeat_at = ? WHERE singleton_id = 1",
            (time.time() + 60,),
        )
        connection.commit()
        connection.close()
        future = self.authorized_json("/api/bootstrap")
        self.assertEqual(future["listenerState"], "inactive")

        connection = sqlite3.connect(self.message_database)
        connection.execute("DROP TABLE listener_state")
        connection.commit()
        connection.close()
        missing = self.authorized_json("/api/bootstrap")
        self.assertEqual(missing["listenerState"], "unknown")

    def test_extreme_listener_timestamps_degrade_to_unknown_without_disconnect(self):
        connection = sqlite3.connect(self.message_database)
        connection.execute(
            """
            CREATE TABLE listener_state(
              singleton_id INTEGER PRIMARY KEY CHECK(singleton_id = 1),
              instance_id TEXT NOT NULL,
              group_names_json TEXT NOT NULL,
              started_at REAL NOT NULL,
              heartbeat_at REAL NOT NULL,
              cursor_timestamp REAL,
              cursor_record_id INTEGER,
              updated_at REAL NOT NULL
            )
            """
        )
        connection.execute(
            """
            INSERT INTO listener_state(
              singleton_id, instance_id, group_names_json, started_at, heartbeat_at,
              updated_at
            ) VALUES (1, '11111111-1111-4111-8111-111111111111', '["safe-group"]',
                      ?, ?, ?)
            """,
            (time.time(), time.time(), time.time()),
        )
        connection.commit()

        for column in ("started_at", "heartbeat_at"):
            with self.subTest(column=column):
                now = time.time()
                connection.execute(
                    "UPDATE listener_state SET started_at = ?, heartbeat_at = ? WHERE singleton_id = 1",
                    (1e300 if column == "started_at" else now,
                     1e300 if column == "heartbeat_at" else now),
                )
                connection.commit()

                status, _, body = self.request(
                    "GET", "/api/bootstrap", {"Authorization": "Bearer test-token"}
                )

                self.assertEqual(status, 200)
                payload = json.loads(body)
                self.assertEqual(payload["listenerState"], "unknown")
                self.assertEqual(payload["messageSource"]["listenerState"], "unknown")
                if column == "started_at":
                    self.assertNotIn("startedAt", payload["messageSource"])
                else:
                    self.assertNotIn("heartbeatAt", payload["messageSource"])
        connection.close()

    def test_bootstrap_prioritizes_six_configured_groups_and_zero_fills_unobserved(self):
        connection = sqlite3.connect(self.message_database)
        self.addCleanup(connection.close)
        connection.execute(
            "INSERT INTO conversations(id, group_name, message_count) VALUES (3, '丙群', 4)"
        )
        connection.commit()
        with open(self.group_config_path, "w", encoding="utf-8") as stream:
            stream.write(
                "  # 注释，不是群名\n甲群\n乙群\n丙群\n\n丁群\n乙群\n# 另一条注释\n戊群\n己群\n"
            )

        payload = self.authorized_json("/api/bootstrap")

        self.assertEqual(
            payload["groups"],
            [
                {"name": "甲群", "count": 2},
                {"name": "乙群", "count": 1},
                {"name": "丙群", "count": 4},
                {"name": "丁群", "count": 0},
                {"name": "戊群", "count": 0},
                {"name": "己群", "count": 0},
            ],
        )
        self.assertNotIn("groupConfig", payload)

    def test_bootstrap_appends_historical_groups_after_current_configuration(self):
        with open(self.group_config_path, "w", encoding="utf-8") as stream:
            stream.write("乙群\n新群\n")

        payload = self.authorized_json("/api/bootstrap")

        self.assertEqual(
            payload["groups"],
            [
                {"name": "乙群", "count": 1},
                {"name": "新群", "count": 0},
                {"name": "甲群", "count": 2},
            ],
        )

    def test_missing_group_config_falls_back_without_creating_or_exposing_path(self):
        status, _, body = self.request(
            "GET", "/api/bootstrap", {"Authorization": "Bearer test-token"}
        )

        self.assertEqual(status, 200)
        self.assertEqual(
            json.loads(body)["groups"],
            [{"name": "甲群", "count": 2}, {"name": "乙群", "count": 1}],
        )
        self.assertFalse(os.path.exists(self.group_config_path))
        self.assertNotIn(self.group_config_path, body)

    def test_invalid_group_config_falls_back_without_exposing_path(self):
        with open(self.group_config_path, "wb") as stream:
            stream.write(b"\xff\xfe\x00")

        status, _, body = self.request(
            "GET", "/api/bootstrap", {"Authorization": "Bearer test-token"}
        )

        self.assertEqual(status, 200)
        self.assertEqual(
            json.loads(body)["groups"],
            [{"name": "甲群", "count": 2}, {"name": "乙群", "count": 1}],
        )
        self.assertNotIn(self.group_config_path, body)
        self.assertNotIn("Unicode", body)

    def test_unreadable_group_config_falls_back_without_exposing_path(self):
        with open(self.group_config_path, "w", encoding="utf-8") as stream:
            stream.write("不应暴露的群\n")
        os.chmod(self.group_config_path, 0o000)
        self.addCleanup(os.chmod, self.group_config_path, 0o600)

        status, _, body = self.request(
            "GET", "/api/bootstrap", {"Authorization": "Bearer test-token"}
        )

        self.assertEqual(status, 200)
        self.assertEqual(
            json.loads(body)["groups"],
            [{"name": "甲群", "count": 2}, {"name": "乙群", "count": 1}],
        )
        self.assertNotIn(self.group_config_path, body)
        self.assertNotIn("不应暴露的群", body)

    def test_symlink_group_config_falls_back_without_following_target(self):
        target = os.path.join(self.temporary_directory.name, "group-config-target")
        with open(target, "w", encoding="utf-8") as stream:
            stream.write("不应跟随的群\n")
        os.symlink(target, self.group_config_path)

        status, _, body = self.request(
            "GET", "/api/bootstrap", {"Authorization": "Bearer test-token"}
        )

        self.assertEqual(status, 200)
        self.assertEqual(
            json.loads(body)["groups"],
            [{"name": "甲群", "count": 2}, {"name": "乙群", "count": 1}],
        )
        self.assertNotIn(self.group_config_path, body)
        self.assertNotIn("不应跟随的群", body)

    def test_non_regular_group_config_falls_back_without_exposing_path(self):
        os.mkdir(self.group_config_path)

        status, _, body = self.request(
            "GET", "/api/bootstrap", {"Authorization": "Bearer test-token"}
        )

        self.assertEqual(status, 200)
        self.assertEqual(
            json.loads(body)["groups"],
            [{"name": "甲群", "count": 2}, {"name": "乙群", "count": 1}],
        )
        self.assertNotIn(self.group_config_path, body)

    def test_messages_filter_by_exact_group_and_keyword(self):
        payload = self.authorized_json(
            "/api/messages?group=%E7%94%B2%E7%BE%A4&q=alpha&limit=50"
        )
        self.assertEqual([item["content"] for item in payload["items"]], ["alpha message"])
        self.assertEqual(
            payload["items"][0],
            {
                "eventId": "event-b",
                "group": "甲群",
                "sender": "阿乙",
                "content": "alpha message",
                "messageType": "text",
                "observedAt": "2024-09-02T06:00:00Z",
                "sourceSequence": 40,
            },
        )

    def test_messages_expose_only_explicit_public_credential_free_https_links(self):
        connection = sqlite3.connect(self.message_database)
        self.addCleanup(connection.close)
        content = " ".join(
            [
                "link-safety",
                "https://dexscreener.com/base/0xsafe",
                "https://www.geckoterminal.com/solana/pools/safe",
                "https://router/admin",
                "https://nas/private",
                "https://home.arpa/admin",
                "https://service.home.arpa/admin",
                "https://public.example/path",
                "https://example.invalid/path",
                "https://example.test/path",
                "https://name.example/path",
                "https://example.com/path",
                "https://example.net/path",
                "https://example.org/path",
                "https://sub.dexscreener.com/base/0xsafe",
                "https://dexscreener.com./base/0xsafe",
                "https://8.8.8.8/path",
                "https://dexscreener.com/path?view=chart",
                "https://dexscreener.com/path#session",
                "http://dexscreener.com/plaintext",
                "https://user:password@dexscreener.com/private",
                "https://dexscreener.com:8443/private",
                "https://localhost/private",
                "https://127.0.0.1/private",
                "https://10.0.0.8/private",
                "https://[::1]/private",
                "https://dexscreener.com/path?api_key=NEVER_EXPOSE_THIS",
                "https://dexscreener.com/path?access_token=NEVER_EXPOSE_THIS",
                "https://dexscreener.com/path?code=NEVER_EXPOSE_THIS",
                "https://dexscreener.com/path?jwt=NEVER_EXPOSE_THIS",
                "https://dexscreener.com/path?sig=NEVER_EXPOSE_THIS",
                "https://dexscreener.com/path?x=Bearer%20NEVER_EXPOSE_THIS",
                "https://dexscreener.com/Authorization/Bearer-secret",
                "https://dexscreener.com/%E0%A4%A",
            ]
        )
        connection.execute(
            """
            INSERT INTO messages(
              event_id, conversation_id, group_name, sender_display_name, content,
              message_type, observed_at, source_sequence
            ) VALUES (?, 1, '甲群', '阿甲', ?, 'text', 1725256801, 42)
            """,
            ("event-link-safety", content),
        )
        connection.commit()

        payload = self.authorized_json("/api/messages?q=link-safety")

        self.assertEqual(
            payload["items"][0]["links"],
            [
                "https://dexscreener.com/base/0xsafe",
                "https://www.geckoterminal.com/solana/pools/safe",
            ],
        )

    def test_public_source_host_allowlist_matches_the_documented_contract(self):
        expected = frozenset(
            {
                "arbiscan.io",
                "basescan.org",
                "birdeye.so",
                "bscscan.com",
                "dexscreener.com",
                "etherscan.io",
                "fomo.family",
                "geckoterminal.com",
                "gmgn.ai",
                "optimistic.etherscan.io",
                "polygonscan.com",
                "pump.fun",
                "snowtrace.io",
                "solscan.io",
                "www.birdeye.so",
                "www.geckoterminal.com",
            }
        )
        self.assertEqual(security.PUBLIC_SOURCE_HOSTS, expected)
        pages_path = os.path.join(
            os.path.dirname(__file__), "..", "web", "wxfomo-lan", "pages.mjs"
        )
        with open(pages_path, "r", encoding="utf-8") as stream:
            source = stream.read()
        match = re.search(
            r"export const PUBLIC_SOURCE_HOSTS = Object\.freeze\(\[(.*?)\]\);",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(match)
        self.assertEqual(frozenset(re.findall(r'"([^"]+)"', match.group(1))), expected)

    def test_cursor_paginates_equal_timestamps_without_duplicate_or_gap(self):
        first = self.authorized_json("/api/messages?limit=2")
        self.assertEqual(decode_cursor(first["latestCursor"]), (1725256800, "event-c"))
        self.assertEqual(decode_cursor(first["nextBefore"]), (1725256800, "event-b"))
        second = self.authorized_json(
            "/api/messages?limit=2&before="
            + urllib.parse.quote(first["nextBefore"])
        )
        self.assertEqual(decode_cursor(second["latestCursor"]), (1725256800, "event-a"))
        self.assertEqual(decode_cursor(second["nextBefore"]), (1725256800, "event-a"))
        ids = [item["eventId"] for item in first["items"] + second["items"]]
        self.assertEqual(ids, ["event-c", "event-b", "event-a"])

    def test_latest_cursor_preserves_sqlite_real_microseconds(self):
        timestamp = 1725256800.123456
        connection = sqlite3.connect(self.message_database)
        self.addCleanup(connection.close)
        connection.execute(
            """
            INSERT INTO messages(
              event_id, conversation_id, group_name, sender_display_name, content,
              message_type, observed_at, source_sequence
            ) VALUES ('event-microsecond', 1, '甲群', '阿甲', 'microsecond', 'text', ?, 42)
            """,
            (timestamp,),
        )
        connection.commit()

        payload = self.authorized_json("/api/messages?limit=1")

        self.assertEqual(payload["items"][0]["eventId"], "event-microsecond")
        self.assertEqual(
            decode_cursor(payload["latestCursor"]),
            (timestamp, "event-microsecond"),
        )

    def test_after_returns_only_messages_newer_than_cursor_in_ascending_order(self):
        first = self.authorized_json("/api/messages?limit=1")
        payload = self.authorized_json(
            "/api/messages?after=" + urllib.parse.quote(first["nextBefore"])
        )
        self.assertEqual([item["eventId"] for item in payload["items"]], [])
        oldest = self.authorized_json("/api/messages?limit=3")["items"][-1]
        cursor = urllib.parse.quote("eyJ0IjoxNzI1MjU2ODAwLCJlIjoiZXZlbnQtYSJ9")
        payload = self.authorized_json("/api/messages?after=" + cursor)
        self.assertEqual([item["eventId"] for item in payload["items"]], ["event-b", "event-c"])
        self.assertEqual(decode_cursor(payload["nextBefore"]), (1725256800, "event-b"))
        self.assertEqual(decode_cursor(payload["latestCursor"]), (1725256800, "event-c"))
        self.assertEqual(oldest["eventId"], "event-a")

        empty = self.authorized_json(
            "/api/messages?after=" + urllib.parse.quote(payload["latestCursor"])
        )
        self.assertEqual(empty["items"], [])
        self.assertIsNone(empty["nextBefore"])
        self.assertEqual(empty["latestCursor"], payload["latestCursor"])

    def test_after_cursor_advances_through_more_than_one_limit_without_starvation(self):
        timestamp = 1725256800
        connection = sqlite3.connect(self.message_database)
        self.addCleanup(connection.close)
        connection.executemany(
            """
            INSERT INTO messages(
              event_id, conversation_id, group_name, sender_display_name, content,
              message_type, observed_at, source_sequence
            ) VALUES (?, 1, '甲群', '阿甲', 'burst', 'text', ?, ?)
            """,
            [
                (
                    "event-burst-{:03d}".format(index),
                    timestamp + (index + 1) / 1000000.0,
                    1000 + index,
                )
                for index in range(205)
            ],
        )
        connection.commit()

        cursor = encode_cursor(timestamp, "event-c")
        received = []
        while True:
            payload = self.authorized_json(
                "/api/messages?limit=50&after=" + urllib.parse.quote(cursor)
            )
            if not payload["items"]:
                self.assertEqual(payload["latestCursor"], cursor)
                break
            self.assertNotEqual(payload["latestCursor"], cursor)
            received.extend(item["eventId"] for item in payload["items"])
            cursor = payload["latestCursor"]

        self.assertEqual(
            received,
            ["event-burst-{:03d}".format(index) for index in range(205)],
        )

    def test_query_terms_are_bound_and_wildcards_are_escaped(self):
        payload = self.authorized_json(
            "/api/messages?group=%E7%94%B2%E7%BE%A4%27%20OR%201%3D1--&q=alpha"
        )
        self.assertEqual(payload["items"], [])
        payload = self.authorized_json("/api/messages?q=%25")
        self.assertEqual(payload["items"], [])

    def test_malformed_cursor_returns_a_redacted_bad_request(self):
        raw_cursor = "not-a-cursor"
        status, _, body = self.request(
            "GET",
            "/api/messages?before=" + raw_cursor,
            {"Authorization": "Bearer test-token"},
        )
        self.assertEqual(status, 400)
        self.assertEqual(json.loads(body), {"error": "invalid_cursor"})
        self.assertNotIn(raw_cursor, body)

    def test_cursor_rejects_non_finite_timestamps(self):
        status, _, body = self.request(
            "GET",
            "/api/messages?before=eyJ0IjpOYU4sImUiOiJldmVudC1hIn0",
            {"Authorization": "Bearer test-token"},
        )
        self.assertEqual(status, 400)
        self.assertEqual(json.loads(body), {"error": "invalid_cursor"})

    def test_limit_is_clamped_to_200(self):
        connection = sqlite3.connect(self.message_database)
        self.addCleanup(connection.close)
        connection.executemany(
            """
            INSERT INTO messages(
              event_id, conversation_id, group_name, sender_display_name, content,
              message_type, observed_at, source_sequence
            ) VALUES (?, 1, '甲群', '阿甲', 'many', 'text', ?, ?)
            """,
            [("event-extra-{}".format(index), 1725256801 + index, index) for index in range(205)],
        )
        connection.commit()
        payload = self.authorized_json("/api/messages?limit=999")
        self.assertEqual(len(payload["items"]), 200)

    def test_missing_database_reports_unavailable_without_creating_file(self):
        os.unlink(self.message_database)
        payload = self.authorized_json("/api/bootstrap")
        self.assertEqual(payload["messageSource"]["available"], False)
        self.assertFalse(os.path.exists(self.message_database))

    def test_messages_missing_database_returns_a_redacted_unavailable_response(self):
        os.unlink(self.message_database)
        query = "not-visible"
        status, _, body = self.request(
            "GET",
            "/api/messages?q=" + query,
            {"Authorization": "Bearer test-token"},
        )
        self.assertEqual(status, 503)
        self.assertEqual(
            json.loads(body),
            {
                "error": "message_source_unavailable",
                "reason": "source_unavailable",
            },
        )
        self.assertNotIn(self.message_database, body)
        self.assertNotIn(query, body)
        self.assertFalse(os.path.exists(self.message_database))

    def test_message_lock_reports_reason_retains_read_contract_and_recovers(self):
        lock = sqlite3.connect(self.message_database, timeout=0)
        lock.execute("PRAGMA locking_mode=EXCLUSIVE")
        lock.execute("BEGIN EXCLUSIVE")
        self.addCleanup(lock.close)

        bootstrap = self.authorized_json("/api/bootstrap")
        self.assertEqual(bootstrap["messageSource"]["available"], False)
        self.assertEqual(bootstrap["messageSource"]["reason"], "source_locked")
        status, _, body = self.request(
            "GET", "/api/messages", {"Authorization": "Bearer test-token"}
        )
        self.assertEqual(status, 503)
        self.assertEqual(
            json.loads(body),
            {"error": "message_source_unavailable", "reason": "source_locked"},
        )

        lock.rollback()
        lock.close()
        recovered = self.authorized_json("/api/bootstrap")
        self.assertEqual(recovered["messageSource"]["available"], True)
        self.assertNotIn("reason", recovered["messageSource"])

    def test_message_source_schema_corruption_and_permission_reasons_are_distinct(self):
        schema_path = os.path.join(self.temporary_directory.name, "message-schema.sqlite3")
        connection = sqlite3.connect(schema_path)
        connection.executescript(
            """
            CREATE TABLE conversations(id INTEGER PRIMARY KEY, group_name TEXT NOT NULL);
            CREATE TABLE messages(event_id TEXT PRIMARY KEY, observed_at REAL NOT NULL);
            """
        )
        connection.close()

        corrupt_path = os.path.join(self.temporary_directory.name, "message-corrupt.sqlite3")
        with open(corrupt_path, "wb") as stream:
            stream.write(b"not a sqlite database")

        denied_path = os.path.join(self.temporary_directory.name, "message-denied.sqlite3")
        connection = sqlite3.connect(denied_path)
        connection.execute("CREATE TABLE unrelated(value INTEGER)")
        connection.close()
        os.chmod(denied_path, 0o000)
        self.addCleanup(os.chmod, denied_path, 0o600)

        cases = (
            (schema_path, "schema_incompatible"),
            (corrupt_path, "source_corrupt"),
            (denied_path, "source_permission_denied"),
        )
        for path, reason in cases:
            with self.subTest(reason=reason):
                repository = MessageRepository(path, self.group_config_path)
                bootstrap = repository.bootstrap()
                self.assertEqual(bootstrap["messageSource"]["available"], False)
                self.assertEqual(bootstrap["messageSource"]["reason"], reason)
                with self.assertRaises(MessageSourceUnavailable) as context:
                    repository.query({})
                self.assertEqual(context.exception.reason, reason)

    def test_message_source_detects_an_inaccessible_ancestor_through_direct_and_symlink_paths(self):
        denied_directory = os.path.join(
            self.temporary_directory.name, "message-denied-ancestor"
        )
        nested_directory = os.path.join(denied_directory, "nested")
        os.makedirs(nested_directory, mode=0o700)
        denied_path = os.path.join(nested_directory, "messages.sqlite3")
        self.create_message_fixture(denied_path)
        alias_path = os.path.join(self.temporary_directory.name, "message-denied-alias")
        os.symlink(denied_path, alias_path)

        os.chmod(denied_directory, 0o000)
        self.addCleanup(os.chmod, denied_directory, 0o700)
        for path in (denied_path, alias_path):
            with self.subTest(path_kind="alias" if path == alias_path else "direct"):
                repository = MessageRepository(path, self.group_config_path)
                bootstrap = repository.bootstrap()
                self.assertEqual(
                    bootstrap["messageSource"]["reason"],
                    "source_permission_denied",
                )
                with self.assertRaises(MessageSourceUnavailable) as context:
                    repository.query({})
                self.assertEqual(
                    context.exception.reason,
                    "source_permission_denied",
                )

    def test_post_is_never_allowed(self):
        status, headers, _ = self.request(
            "POST", "/api/bootstrap", {"Authorization": "Bearer test-token"}
        )
        self.assertEqual(status, 405)
        self.assertEqual(headers["Allow"], "GET, HEAD")

    def test_other_non_read_methods_are_never_allowed(self):
        for method in ("OPTIONS", "TRACE", "CONNECT", "PROPFIND"):
            with self.subTest(method=method):
                status, headers, _ = self.request(method, "/api/bootstrap")
                self.assertEqual(status, 405)
                self.assertEqual(headers["Allow"], "GET, HEAD")

    def test_generated_token_file_is_private(self):
        token = security.ensure_access_token(self.token_path)
        self.assertGreaterEqual(len(token), 43)
        self.assertEqual(stat.S_IMODE(os.stat(self.token_path).st_mode), 0o600)
        self.assertEqual(
            stat.S_IMODE(os.stat(os.path.dirname(self.token_path)).st_mode), 0o700
        )

    def test_existing_token_in_private_parent_is_reused_and_file_is_tightened(self):
        directory = os.path.dirname(self.token_path)
        os.makedirs(directory, mode=0o700)
        with open(self.token_path, "w", encoding="utf-8") as stream:
            stream.write("existing-safe-token\n")
        os.chmod(directory, 0o700)
        os.chmod(self.token_path, 0o644)

        token = security.ensure_access_token(self.token_path)

        self.assertEqual(token, "existing-safe-token")
        self.assertEqual(stat.S_IMODE(os.stat(directory).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(self.token_path).st_mode), 0o600)

    def test_valid_token_in_shared_parent_is_rejected_without_chmod(self):
        directory = os.path.dirname(self.token_path)
        os.makedirs(directory, mode=0o755)
        with open(self.token_path, "w", encoding="utf-8") as stream:
            stream.write("existing-safe-token\n")
        os.chmod(directory, 0o755)
        os.chmod(self.token_path, 0o644)

        with self.assertRaises(ValueError):
            security.ensure_access_token(self.token_path)

        self.assertEqual(stat.S_IMODE(os.stat(directory).st_mode), 0o755)
        self.assertEqual(stat.S_IMODE(os.stat(self.token_path).st_mode), 0o644)

    def test_empty_token_in_shared_parent_is_rejected_without_chmod(self):
        directory = os.path.dirname(self.token_path)
        os.makedirs(directory, mode=0o755)
        with open(self.token_path, "w", encoding="utf-8") as stream:
            stream.write(" \n\t")
        os.chmod(directory, 0o755)
        os.chmod(self.token_path, 0o644)

        with self.assertRaises(ValueError):
            security.ensure_access_token(self.token_path)

        self.assertEqual(stat.S_IMODE(os.stat(directory).st_mode), 0o755)
        self.assertEqual(stat.S_IMODE(os.stat(self.token_path).st_mode), 0o644)

    def test_symlink_token_in_shared_parent_is_rejected_without_chmod(self):
        directory = os.path.dirname(self.token_path)
        os.makedirs(directory, mode=0o755)
        target = os.path.join(self.temporary_directory.name, "uncontrolled-target")
        with open(target, "w", encoding="utf-8") as stream:
            stream.write("target-secret\n")
        os.chmod(directory, 0o755)
        os.chmod(target, 0o644)
        os.symlink(target, self.token_path)

        with self.assertRaises(ValueError):
            security.ensure_access_token(self.token_path)

        with open(target, "r", encoding="utf-8") as stream:
            self.assertEqual(stream.read(), "target-secret\n")
        self.assertEqual(stat.S_IMODE(os.stat(directory).st_mode), 0o755)
        self.assertEqual(stat.S_IMODE(os.stat(target).st_mode), 0o644)

    def test_empty_token_in_private_parent_is_rejected_before_file_chmod(self):
        directory = os.path.dirname(self.token_path)
        os.makedirs(directory, mode=0o700)
        with open(self.token_path, "w", encoding="utf-8") as stream:
            stream.write(" \n\t")
        os.chmod(directory, 0o700)
        os.chmod(self.token_path, 0o644)

        with self.assertRaises(ValueError):
            security.ensure_access_token(self.token_path)

        self.assertEqual(stat.S_IMODE(os.stat(self.token_path).st_mode), 0o644)

    def test_symlink_token_in_private_parent_is_rejected_without_target_chmod(self):
        directory = os.path.dirname(self.token_path)
        os.makedirs(directory, mode=0o700)
        target = os.path.join(self.temporary_directory.name, "private-target")
        with open(target, "w", encoding="utf-8") as stream:
            stream.write("target-secret\n")
        os.chmod(directory, 0o700)
        os.chmod(target, 0o644)
        os.symlink(target, self.token_path)

        with self.assertRaises(ValueError):
            security.ensure_access_token(self.token_path)

        self.assertEqual(stat.S_IMODE(os.stat(target).st_mode), 0o644)

    def test_hardlinked_token_is_rejected_before_file_chmod(self):
        directory = os.path.dirname(self.token_path)
        os.makedirs(directory, mode=0o700)
        target = os.path.join(self.temporary_directory.name, "hardlink-target")
        with open(target, "w", encoding="utf-8") as stream:
            stream.write("target-secret\n")
        os.chmod(directory, 0o700)
        os.chmod(target, 0o644)
        os.link(target, self.token_path)

        with self.assertRaises(ValueError):
            security.ensure_access_token(self.token_path)

        self.assertEqual(stat.S_IMODE(os.stat(target).st_mode), 0o644)

    def test_special_token_is_rejected_before_file_chmod(self):
        directory = os.path.dirname(self.token_path)
        os.makedirs(directory, mode=0o700)
        os.chmod(directory, 0o700)
        os.mkfifo(self.token_path, mode=0o644)

        with self.assertRaises(ValueError):
            security.ensure_access_token(self.token_path)

        self.assertEqual(stat.S_IMODE(os.stat(self.token_path).st_mode), 0o644)

    def test_missing_parent_does_not_recursively_create_ancestors(self):
        missing_ancestor = os.path.join(self.temporary_directory.name, "missing")
        nested_token = os.path.join(missing_ancestor, "dedicated", "token")

        with self.assertRaises(ValueError):
            security.ensure_access_token(nested_token)

        self.assertFalse(os.path.lexists(missing_ancestor))

    def test_symlink_parent_is_rejected_without_following_it(self):
        real_directory = os.path.join(self.temporary_directory.name, "real-private")
        os.mkdir(real_directory, mode=0o700)
        os.chmod(real_directory, 0o700)
        os.symlink(real_directory, os.path.dirname(self.token_path))

        with self.assertRaises(ValueError):
            security.ensure_access_token(self.token_path)

        self.assertFalse(os.path.lexists(os.path.join(real_directory, "token")))
        self.assertEqual(stat.S_IMODE(os.stat(real_directory).st_mode), 0o700)

    def test_static_root_serves_index_with_security_headers(self):
        status, headers, body = self.request("GET", "/")
        self.assertEqual(status, 200)
        self.assertIn("wxFomo · 群消息总结", body)
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertEqual(headers["Referrer-Policy"], "no-referrer")
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(
            headers["Content-Security-Policy"],
            "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
            "connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
        )

    def test_login_page_asks_for_a_password_without_token_file_instructions(self):
        status, _, body = self.request("GET", "/")

        self.assertEqual(status, 200)
        self.assertIn("访问密码", body)
        self.assertNotIn("访问令牌", body)
        self.assertNotIn("token-file", body)
        self.assertIn('type="password"', body)

    def test_frontend_assets_have_safe_mime_types_and_security_headers(self):
        expected_types = {
            "/": "text/html",
            "/styles.css": "text/css",
            "/app.mjs": "application/javascript",
        }
        for path, expected_type in expected_types.items():
            with self.subTest(path=path):
                status, headers, _ = self.request("GET", path)
                self.assertEqual(status, 200)
                self.assertEqual(headers["Content-Type"].split(";", 1)[0], expected_type)
                self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
                self.assertEqual(headers["Referrer-Policy"], "no-referrer")
                self.assertEqual(headers["Cache-Control"], "no-store")
                self.assertIn("default-src 'self'", headers["Content-Security-Policy"])

    def test_static_server_rejects_regular_files_outside_the_public_asset_allowlist(self):
        static_root = os.path.join(self.temporary_directory.name, "isolated-static")
        os.mkdir(static_root)
        with open(os.path.join(static_root, "index.html"), "w", encoding="utf-8") as stream:
            stream.write("public index")
        with open(os.path.join(static_root, "private-token.txt"), "w", encoding="utf-8") as stream:
            stream.write("STATIC_SECRET_SENTINEL")
        server = create_server(
            ServerOptions(
                host="127.0.0.1",
                port=0,
                token="test-token",
                static_root=static_root,
                message_database=self.message_database,
                group_config_path=self.group_config_path,
                workspace_database=os.path.join(self.temporary_directory.name, "workspace.sqlite3"),
                configuration_path=os.path.join(self.temporary_directory.name, "configuration.json"),
            )
        )
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

        status, _, body = self.request_from_server(server, "GET", "/private-token.txt")

        self.assertEqual(status, 404)
        self.assertNotIn("STATIC_SECRET_SENTINEL", body)

    def test_static_server_does_not_follow_an_allowlisted_asset_symlink(self):
        static_root = os.path.join(self.temporary_directory.name, "symlink-static")
        os.mkdir(static_root)
        secret = os.path.join(static_root, "secret.txt")
        with open(secret, "w", encoding="utf-8") as stream:
            stream.write("SYMLINK_SECRET_SENTINEL")
        os.symlink(secret, os.path.join(static_root, "app.mjs"))
        server = create_server(
            ServerOptions(
                host="127.0.0.1",
                port=0,
                token="test-token",
                static_root=static_root,
                message_database=self.message_database,
                group_config_path=self.group_config_path,
                workspace_database=os.path.join(self.temporary_directory.name, "workspace.sqlite3"),
                configuration_path=os.path.join(self.temporary_directory.name, "configuration.json"),
            )
        )
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

        status, _, body = self.request_from_server(server, "GET", "/app.mjs")

        self.assertEqual(status, 404)
        self.assertNotIn("SYMLINK_SECRET_SENTINEL", body)

    def test_static_server_never_serves_allowlisted_hardlinks_to_sensitive_files(self):
        sensitive_names = (
            "notification.sqlite3",
            "messages.sqlite3",
            "workspace.sqlite3",
            "configuration.json",
            "groups.txt",
            "access-token",
            "private-key.pem",
        )
        for sensitive_name in sensitive_names:
            with self.subTest(sensitive_name=sensitive_name):
                with tempfile.TemporaryDirectory() as directory:
                    static_root = os.path.join(directory, "static")
                    os.mkdir(static_root)
                    sensitive_path = os.path.join(directory, sensitive_name)
                    sentinel = "HARDLINK_{}_SENTINEL".format(sensitive_name)
                    with open(sensitive_path, "w", encoding="utf-8") as stream:
                        stream.write(sentinel)
                    os.link(sensitive_path, os.path.join(static_root, "app.mjs"))
                    server = create_server(
                        ServerOptions(
                            host="127.0.0.1",
                            port=0,
                            token="test-token",
                            static_root=static_root,
                            message_database=sensitive_path,
                            group_config_path=sensitive_path,
                            workspace_database=sensitive_path,
                            configuration_path=sensitive_path,
                        )
                    )
                    thread = threading.Thread(target=server.serve_forever)
                    thread.start()
                    try:
                        status, _, body = self.request_from_server(
                            server, "GET", "/app.mjs"
                        )
                    finally:
                        server.shutdown()
                        server.server_close()
                        thread.join()

                    self.assertEqual(status, 404)
                    self.assertNotIn(sentinel, body)

    def test_static_server_rejects_a_notification_database_at_an_allowlisted_path(self):
        with tempfile.TemporaryDirectory() as directory:
            static_root = os.path.join(directory, "static")
            os.mkdir(static_root)
            notification_database = os.path.join(static_root, "app.mjs")
            connection = sqlite3.connect(notification_database)
            connection.execute("CREATE TABLE record(rec_id INTEGER PRIMARY KEY)")
            connection.commit()
            connection.close()
            server = create_server(
                ServerOptions(
                    host="127.0.0.1",
                    port=0,
                    token="test-token",
                    static_root=static_root,
                    message_database=os.path.join(directory, "messages.sqlite3"),
                    group_config_path=os.path.join(directory, "groups.txt"),
                    workspace_database=os.path.join(directory, "workspace.sqlite3"),
                    configuration_path=os.path.join(directory, "configuration.json"),
                    notification_database=notification_database,
                )
            )
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            try:
                http_connection = http.client.HTTPConnection(
                    "127.0.0.1", server.server_port
                )
                http_connection.request("GET", "/app.mjs")
                response = http_connection.getresponse()
                status = response.status
                body = response.read()
                http_connection.close()
            finally:
                server.shutdown()
                server.server_close()
                thread.join()

            self.assertEqual(status, 404)
            self.assertNotIn(b"SQLite format", body)

    def test_each_sensitive_custom_filename_is_not_downloadable_without_auth(self):
        static_root = os.path.join(self.temporary_directory.name, "sensitive-static")
        os.mkdir(static_root)
        with open(os.path.join(static_root, "index.html"), "w", encoding="utf-8") as stream:
            stream.write("public index")
        sensitive_filenames = (
            "access-token",
            "private-key.pem",
            "messages.sqlite3",
            "workspace.sqlite3",
            "configuration.json",
            "groups.txt",
        )
        for filename in sensitive_filenames:
            with open(os.path.join(static_root, filename), "w", encoding="utf-8") as stream:
                stream.write("SENSITIVE_{}_SENTINEL".format(filename))
        server = create_server(
            ServerOptions(
                host="127.0.0.1",
                port=0,
                token="test-token",
                static_root=static_root,
                message_database=os.path.join(static_root, "messages.sqlite3"),
                group_config_path=os.path.join(static_root, "groups.txt"),
                workspace_database=os.path.join(static_root, "workspace.sqlite3"),
                configuration_path=os.path.join(static_root, "configuration.json"),
            )
        )
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

        for filename in sensitive_filenames:
            with self.subTest(filename=filename):
                status, _, body = self.request_from_server(
                    server, "GET", "/" + filename
                )
                self.assertEqual(status, 404)
                self.assertNotIn("SENSITIVE_", body)

    def test_frontend_html_has_no_external_assets_or_enabled_write_actions(self):
        status, _, body = self.request("GET", "/")
        self.assertEqual(status, 200)
        parser = FrontendSecurityParser()
        parser.feed(body)
        self.assertEqual(parser.external_assets, [])
        self.assertEqual(parser.enabled_write_actions, [])

    def test_static_path_traversal_is_rejected(self):
        status, _, _ = self.request("GET", "/%2e%2e/secret.txt")
        self.assertEqual(status, 400)

    def test_decoded_nul_path_is_rejected_without_reaching_the_filesystem(self):
        status, _, body = self.request("GET", "/asset%00name.js")

        self.assertEqual(status, 400)
        self.assertEqual(json.loads(body), {"error": "invalid_path"})

        authorization = {"Authorization": "Bearer test-token"}
        status, _, body = self.request("GET", "/api/%00", authorization)
        self.assertEqual(status, 400)
        self.assertEqual(json.loads(body), {"error": "invalid_path"})

        status, _, body = self.request("HEAD", "/api/%00", authorization)
        self.assertEqual(status, 400)
        self.assertEqual(body, "")


class LanServerCliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cli = load_cli_module()

    def parse_options(self, arguments):
        with redirect_stderr(io.StringIO()):
            return self.cli.parse_options(arguments)

    def test_native_configuration_defaults_to_unused(self):
        options = self.parse_options([])
        self.assertEqual(options.configuration, "")
        self.assertEqual(options.workspace_database, "")

    def test_configuration_accepts_an_explicit_path(self):
        options = self.parse_options(["--configuration", "/tmp/test-configuration.json"])
        self.assertEqual(options.configuration, "/tmp/test-configuration.json")

    def test_notification_database_accepts_an_external_path(self):
        options = self.parse_options(
            ["--notification-database", "/tmp/test-notification.sqlite3"]
        )
        self.assertEqual(
            options.notification_database, "/tmp/test-notification.sqlite3"
        )

    def test_analysis_database_has_a_private_default_and_accepts_an_explicit_path(self):
        self.assertEqual(self.parse_options([]).analysis_database, self.cli.ANALYSIS_DATABASE)
        options = self.parse_options(
            ["--analysis-database", "/tmp/test-analysis.sqlite3"]
        )
        self.assertEqual(options.analysis_database, "/tmp/test-analysis.sqlite3")

    def test_group_config_defaults_to_the_listener_default(self):
        options = self.parse_options([])
        self.assertEqual(
            options.group_config,
            os.path.expanduser("~/.config/wxfomo/wecom-groups.txt"),
        )

    def test_group_config_accepts_only_the_explicit_path(self):
        options = self.parse_options(["--group-config", "/tmp/custom-wecom-groups.txt"])
        self.assertEqual(options.group_config, "/tmp/custom-wecom-groups.txt")

    def test_every_non_loopback_binding_requires_explicit_opt_in(self):
        for host in ("", "0.0.0.0", "192.168.50.9"):
            with self.subTest(host=host):
                with self.assertRaises(SystemExit) as context:
                    self.parse_options(["--host", host])
                self.assertEqual(context.exception.code, 2)

        loopback = self.parse_options(["--host", "127.0.0.2"])
        self.assertEqual(loopback.host, "127.0.0.2")
        allowed = self.parse_options(["--allow-lan", "--host", "192.168.50.9"])
        self.assertEqual(allowed.host, "192.168.50.9")

    def test_hostname_is_authorized_from_its_resolved_bind_address(self):
        non_loopback = [(2, 1, 6, "", ("192.168.50.10", 0))]
        with mock.patch.object(self.cli.socket, "getaddrinfo", return_value=non_loopback):
            with self.assertRaises(SystemExit) as context:
                self.parse_options(["--host", "lan-name.invalid"])
            self.assertEqual(context.exception.code, 2)

        loopback = [(2, 1, 6, "", ("127.0.0.1", 0))]
        with mock.patch.object(self.cli.socket, "getaddrinfo", return_value=loopback):
            options = self.parse_options(["--host", "local-name.invalid"])
        self.assertEqual(options.host, "127.0.0.1")

    def test_tls_certificate_and_key_are_required_together(self):
        for arguments in (("--tls-cert", "certificate.pem"), ("--tls-key", "key.pem")):
            with self.subTest(arguments=arguments):
                with self.assertRaises(SystemExit) as context:
                    self.parse_options(arguments)
                self.assertEqual(context.exception.code, 2)
        options = self.parse_options(["--tls-cert", "certificate.pem", "--tls-key", "key.pem"])
        self.assertEqual(options.tls_cert, "certificate.pem")
        self.assertEqual(options.tls_key, "key.pem")

    def test_sensitive_custom_paths_inside_static_root_are_rejected(self):
        cases = (
            ("--notification-database", "notification.sqlite3"),
            ("--analysis-database", "analysis.sqlite3"),
            ("--database", "messages.sqlite3"),
            ("--workspace-database", "workspace.sqlite3"),
            ("--configuration", "configuration.json"),
            ("--group-config", "groups.txt"),
            ("--token-file", "access-token"),
        )
        for option, filename in cases:
            with self.subTest(option=option):
                with self.assertRaises(SystemExit) as context:
                    self.parse_options(
                        [option, os.path.join(self.cli.STATIC_ROOT, filename)]
                    )
                self.assertEqual(context.exception.code, 2)

        with self.assertRaises(SystemExit) as context:
            self.parse_options(
                [
                    "--tls-cert",
                    "/tmp/test-certificate.pem",
                    "--tls-key",
                    os.path.join(self.cli.STATIC_ROOT, "private-key.pem"),
                ]
            )
        self.assertEqual(context.exception.code, 2)

    def test_sensitive_hardlinks_to_allowlisted_assets_are_rejected(self):
        cases = (
            ("notification", ("--notification-database",)),
            ("analysis", ("--analysis-database",)),
            ("messages", ("--database",)),
            ("workspace", ("--workspace-database",)),
            ("configuration", ("--configuration",)),
            ("groups", ("--group-config",)),
            ("token", ("--token-file",)),
            ("tls-key", ("--tls-cert", "/tmp/certificate.pem", "--tls-key")),
        )
        for label, option_prefix in cases:
            with self.subTest(label=label):
                with tempfile.TemporaryDirectory() as directory:
                    static_root = os.path.join(directory, "static")
                    os.mkdir(static_root)
                    sensitive_path = os.path.join(directory, label + ".secret")
                    with open(sensitive_path, "w", encoding="utf-8") as stream:
                        stream.write("CLI_HARDLINK_{}_SENTINEL".format(label))
                    os.link(sensitive_path, os.path.join(static_root, "app.mjs"))
                    arguments = list(option_prefix) + [sensitive_path]
                    with mock.patch.object(self.cli, "STATIC_ROOT", static_root):
                        with self.assertRaises(SystemExit) as context:
                            self.parse_options(arguments)
                    self.assertEqual(context.exception.code, 2)

    def test_sensitive_path_rejects_a_case_alias_of_the_static_root(self):
        alias_root = None
        for index, character in enumerate(self.cli.STATIC_ROOT):
            if not character.isalpha():
                continue
            replacement = character.swapcase()
            candidate = (
                self.cli.STATIC_ROOT[:index]
                + replacement
                + self.cli.STATIC_ROOT[index + 1:]
            )
            try:
                if candidate != self.cli.STATIC_ROOT and os.path.samefile(
                    candidate, self.cli.STATIC_ROOT
                ):
                    alias_root = candidate
                    break
            except OSError:
                continue
        if alias_root is None:
            self.skipTest("fixture volume has no case-insensitive path alias")

        self.assertFalse(os.path.commonpath((self.cli.STATIC_ROOT, alias_root)) == self.cli.STATIC_ROOT)
        with self.assertRaises(SystemExit) as context:
            self.parse_options(
                ["--token-file", os.path.join(alias_root, "index.html")]
            )
        self.assertEqual(context.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
