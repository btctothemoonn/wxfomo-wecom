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
from scripts.wxfomo_lan.messages import (
    MessageRepository,
    MessageSourceUnavailable,
    decode_cursor,
    encode_cursor,
)
from scripts.wxfomo_lan.server import ServerOptions, create_server
from scripts.wxfomo_lan.workspace import WorkspaceRepository


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
    def setUp(self):
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
        self.assertIn("wxFomo LAN", body)
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


class WorkspaceEndpointTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.static_root = os.path.join(self.temporary_directory.name, "static")
        os.mkdir(self.static_root)
        with open(os.path.join(self.static_root, "index.html"), "w", encoding="utf-8") as stream:
            stream.write("<!doctype html><title>wxFomo LAN</title>")
        self.message_database = os.path.join(self.temporary_directory.name, "messages.sqlite3")
        self.workspace_path = os.path.join(self.temporary_directory.name, "workspace.sqlite3")
        self.configuration_path = os.path.join(
            self.temporary_directory.name, "configuration-center.json"
        )
        self.create_message_fixture()
        self.create_workspace_fixture()
        with open(self.configuration_path, "w", encoding="utf-8") as stream:
            json.dump(
                {
                    "version": 1,
                    "aiProviderAPIKeys": {"provider-reference": "NEVER_EXPOSE_THIS"},
                    "speech": {"volcengineSeedAPIKey": None},
                },
                stream,
            )
        self.start_server()

    def create_message_fixture(self):
        connection = sqlite3.connect(self.message_database)
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
        connection.execute(
            """
            INSERT INTO messages(
              event_id, conversation_id, group_name, sender_display_name, content,
              message_type, observed_at, source_sequence
            ) VALUES (?, 1, ?, ?, ?, 'text', ?, ?)
            """,
            (
                "event-a", "safe-group", "safe-sender",
                "真实来源 https://dexscreener.com/base/0xsafe", 1725256800, 1,
            ),
        )
        connection.commit()
        connection.close()

    def create_workspace_fixture(self):
        connection = sqlite3.connect(self.workspace_path)
        connection.executescript(
            """
            CREATE TABLE workspace_schema_migrations(
              version INTEGER PRIMARY KEY,
              applied_at REAL NOT NULL
            );
            CREATE TABLE workspace_alerts(
              alert_id TEXT PRIMARY KEY,
              severity TEXT NOT NULL,
              title TEXT NOT NULL,
              body TEXT,
              source_event_ids_json BLOB NOT NULL,
              occurrence_count INTEGER NOT NULL,
              rule_id TEXT,
              acknowledged_at REAL,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL
            );
            CREATE TABLE crypto_address_incidents(
              incident_id TEXT PRIMARY KEY,
              family TEXT NOT NULL,
              network TEXT NOT NULL,
              normalized_address TEXT NOT NULL,
              original_address TEXT NOT NULL,
              first_seen_at REAL NOT NULL,
              latest_seen_at REAL NOT NULL,
              mention_count INTEGER NOT NULL,
              group_names_json BLOB NOT NULL,
              source_event_ids_json BLOB NOT NULL,
              alert_id TEXT NOT NULL UNIQUE,
              status TEXT NOT NULL,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL
            );
            CREATE TABLE analysis_jobs(
              job_id TEXT PRIMARY KEY,
              frozen_range_id TEXT NOT NULL,
              provider_id TEXT NOT NULL,
              mode TEXT NOT NULL,
              state TEXT NOT NULL,
              attempt INTEGER NOT NULL,
              maximum_attempts INTEGER NOT NULL,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL
            );
            CREATE TABLE analysis_results(
              analysis_id TEXT PRIMARY KEY,
              job_id TEXT NOT NULL,
              result_json BLOB NOT NULL,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL
            );
            CREATE TABLE message_rules(
              rule_id TEXT PRIMARY KEY,
              rule_json BLOB NOT NULL,
              priority INTEGER NOT NULL,
              is_enabled INTEGER NOT NULL,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL
            );
            CREATE TABLE ca_watch_pool_items(
              family TEXT NOT NULL,
              network TEXT NOT NULL,
              normalized_address TEXT NOT NULL,
              item_json BLOB NOT NULL,
              state TEXT NOT NULL,
              is_pinned INTEGER NOT NULL,
              latest_seen_at REAL NOT NULL,
              updated_at REAL NOT NULL
            );
            CREATE TABLE trade_automation_rules(
              rule_id TEXT PRIMARY KEY,
              rule_json BLOB NOT NULL,
              is_enabled INTEGER NOT NULL,
              updated_at REAL NOT NULL
            );
            CREATE TABLE trade_automation_configuration(
              singleton_id INTEGER PRIMARY KEY,
              configuration_json BLOB NOT NULL,
              updated_at REAL NOT NULL
            );
            CREATE TABLE trade_intents(
              intent_id TEXT PRIMARY KEY,
              rule_id TEXT NOT NULL,
              state TEXT NOT NULL,
              chain TEXT,
              family TEXT NOT NULL,
              token_address TEXT NOT NULL,
              estimated_spend_usd REAL,
              order_id TEXT,
              intent_json BLOB NOT NULL,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL
            );
            CREATE TABLE ai_provider_configurations(
              configuration_id TEXT PRIMARY KEY,
              configuration_json BLOB NOT NULL,
              is_default INTEGER NOT NULL,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL
            );
            """
        )
        connection.execute(
            "INSERT INTO workspace_schema_migrations(version, applied_at) VALUES (1, ?)",
            (1725256800,),
        )
        connection.execute(
            """
            INSERT INTO workspace_alerts(
              alert_id, severity, title, body, source_event_ids_json, occurrence_count,
              rule_id, acknowledged_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                "alert-1", "warning", "Price moved", "Check the token", '["event-a"]',
                2, "rule-1", None, 1725256800, 1725256810,
            ),
        )
        connection.execute(
            """
            INSERT INTO crypto_address_incidents(
              incident_id, family, network, normalized_address, original_address,
              first_seen_at, latest_seen_at, mention_count, group_names_json,
              source_event_ids_json, alert_id, status, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                "incident-1", "evm", "base", "0xsafe", "0xSafe", 1725256700,
                1725256810, 3, '["safe-group"]', '["event-a"]', "alert-1",
                "active", 1725256800, 1725256810,
            ),
        )
        connection.execute(
            """
            INSERT INTO analysis_jobs(
              job_id, frozen_range_id, provider_id, mode, state, attempt,
              maximum_attempts, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            ("job-1", "range-1", "provider-1", "digest", "succeeded", 1, 3, 1725256800, 1725256810),
        )
        connection.executemany(
            """
            INSERT INTO analysis_jobs(
              job_id, frozen_range_id, provider_id, mode, state, attempt,
              maximum_attempts, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                ("job-pending", "range-2", "provider-1", "action_items", "pending", 0, 3, 1725256820, 1725256820),
                ("job-running", "range-3", "provider-1", "digest", "running", 1, 3, 1725256830, 1725256830),
                ("job-retry", "range-4", "provider-1", "digest", "retry_wait", 1, 3, 1725256840, 1725256840),
                ("job-failed", "range-5", "provider-1", "digest", "failed", 3, 3, 1725256850, 1725256850),
                ("job-cancelled", "range-6", "provider-1", "digest", "cancelled", 0, 3, 1725256860, 1725256860),
            ],
        )
        connection.execute(
            """
            INSERT INTO analysis_results(
              analysis_id, job_id, result_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?)
            """,
            (
                "analysis-1",
                "job-1",
                json.dumps(
                    {
                        "analysisID": "analysis-1",
                        "requestID": "request-1",
                        "schemaVersion": 1,
                        "summary": "Safe summary",
                        "summarySourceMessageIDs": ["event-a"],
                        "topics": [
                            {
                                "topicID": "topic-1",
                                "title": "Token momentum",
                                "summary": "Volume increased",
                                "sourceMessageIDs": ["event-a"],
                                "requestHeaders": {
                                    "Authorization": "Bearer NEVER_EXPOSE_THIS"
                                },
                            },
                        ],
                        "findings": [
                            {
                                "findingID": "finding-1",
                                "category": "risk",
                                "text": "Liquidity is limited",
                                "epistemicStatus": "inference",
                                "sourceMessageIDs": ["event-a"],
                                "signatureValue": "NEVER_EXPOSE_ANALYSIS_SIGNATURE",
                            },
                        ],
                        "cryptoAddresses": [],
                        "usage": {"inputTokens": 50, "outputTokens": 20},
                        "provenance": {
                            "providerConfigurationID": "provider-1",
                            "providerKind": "openai_compatible_chat_completions",
                            "model": "NEVER_EXPOSE_MODEL_SECRET",
                            "remoteRequestID": None,
                            "remoteResponseID": None,
                            "sourceMessageIDs": ["event-a"],
                            "requestSchemaVersion": 1,
                            "resultSchemaVersion": 1,
                            "generatedAt": 1725256810,
                        },
                        "validationWarnings": ["uncited_summary"],
                    }
                ),
                1725256810,
                1725256810,
            ),
        )
        connection.executemany(
            """
            INSERT INTO message_rules(
              rule_id, rule_json, priority, is_enabled, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                (
                    "rule-1",
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "revision": 1,
                            "id": "rule-display-1",
                            "name": "Momentum",
                            "priority": 8,
                            "isEnabled": True,
                            "condition": {
                                "groups": ["safe-group", "项目/交易群"],
                                "senders": ["safe-sender"],
                                "includeKeywords": ["up"],
                                "includeKeywordMode": "all",
                                "excludeKeywords": ["spam"],
                                "regularExpressions": ["OPAQUE_ONE", "OPAQUE_TWO"],
                                "regularExpressionMode": "any",
                                "messageTypes": ["text"],
                                "timeWindows": [
                                    {
                                        "startMinuteOfDay": 60,
                                        "endMinuteOfDay": 120,
                                        "weekdays": [2],
                                        "timeZoneIdentifier": "Asia/Shanghai",
                                        "credentialPath": "/Users/secret/key.pem",
                                    }
                                ],
                                "caseSensitive": False,
                                "requestHeaders": {
                                    "Authorization": "Bearer NEVER_EXPOSE_THIS"
                                },
                            },
                            "actions": [
                                {
                                    "type": "local_alert",
                                    "severity": "warning",
                                    "title": "Safe alert",
                                    "webhookUrl": "https://secret.example.invalid/hook",
                                    "requestHeaders": {
                                        "Authorization": "Bearer NEVER_EXPOSE_THIS"
                                    },
                                },
                                {
                                    "type": "enqueue_summary",
                                    "configuration_id": "provider-safe",
                                    "prompt": "NEVER_EXPOSE_SUMMARY_PROMPT",
                                },
                                {
                                    "type": "invoke_script",
                                    "script_id": "safe-script",
                                    "arguments": [
                                        "--safe",
                                        "/Users/secret/private-key.pem",
                                        "Authorization: NEVER_EXPOSE_THIS",
                                        "X-aUtH-tOkEn: abc123",
                                        "COOKIE: SESSION=ABC123",
                                        "../CONFIG/PROD.TOML",
                                        "SSH://USER@HOST/REPO",
                                    ],
                                    "signatureValue": "NEVER_EXPOSE_RULE_SIGNATURE",
                                },
                            ],
                        }
                    ),
                    8,
                    1,
                    1725256800,
                    1725256810,
                ),
                ("rule-invalid", "{NEVER_EXPOSE_INVALID_RULE", 1, 1, 1725256800, 1725256810),
            ],
        )
        connection.execute(
            """
            INSERT INTO ca_watch_pool_items(
              family, network, normalized_address, item_json, state, is_pinned,
              latest_seen_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                "evm",
                "base",
                "0xsafe",
                json.dumps(
                    {
                        "family": "evm",
                        "network": "base",
                        "normalizedAddress": "0xsafe",
                        "chain": "base",
                        "state": "watching",
                        "entrySnapshot": {
                            "chain": "base",
                            "address": "0xsafe",
                            "symbol": "SAFE",
                            "name": "Safe Coin",
                            "priceUSD": 1.0,
                            "marketCapUSD": 400000,
                            "liquidityUSD": 60000,
                            "logoURL": "https://secret.example.invalid/logo.png",
                            "capturedAt": 1725256800,
                            "source": "gmgn",
                        },
                        "currentSnapshot": {
                            "chain": "base",
                            "address": "0xsafe",
                            "symbol": "SAFE",
                            "name": "Safe Coin",
                            "priceUSD": 1.25,
                            "marketCapUSD": 500000,
                            "liquidityUSD": 75000,
                            "logoURL": "https://secret.example.invalid/logo.png",
                            "capturedAt": 1725256810,
                            "source": "gmgn",
                            "requestHeaders": {
                                "Authorization": "Bearer NEVER_EXPOSE_THIS"
                            },
                        },
                        "isPinned": True,
                        "mentionCount": 3,
                        "groupNames": ["safe-group"],
                        "firstSeenAt": 1725256700,
                        "latestSeenAt": 1725256810,
                        "lastCheckedAt": 1725256810,
                        "consecutiveFailures": 0,
                        "belowThresholdCount": 0,
                        "removalReason": None,
                        "updatedAt": 1725256810,
                    }
                ),
                "watching",
                1,
                1725256810,
                1725256810,
            ),
        )
        connection.execute(
            """
            INSERT INTO trade_automation_rules(rule_id, rule_json, is_enabled, updated_at)
            VALUES (?, ?, ?, ?)
            """,
            (
                "automation-1",
                json.dumps(
                    {
                        "id": "automation-display-1",
                        "name": "Paper buy",
                        "isEnabled": True,
                        "allowedChains": ["base"],
                        "groups": ["safe-group"],
                        "senders": ["safe-sender"],
                        "aggregationWindowSeconds": 600,
                        "minimumMentions": 2,
                        "minimumDistinctGroups": 2,
                        "minimumMarketCapUSD": 500000,
                        "maximumMarketCapUSD": 20000000,
                        "minimumLiquidityUSD": 100000,
                        "minimumHolderCount": 100,
                        "maximumRugRatio": 0.1,
                        "requireSecurityData": True,
                        "inputAmountNative": 0.01,
                        "maximumSlippagePercent": 12,
                        "antiMEV": True,
                        "maximumTradesPerDay": 2,
                        "tokenCooldownSeconds": 86400,
                        "protectionOrders": [
                            {
                                "id": "protection-1",
                                "kind": "stop_loss",
                                "triggerPercent": 50,
                                "sellPercent": 100,
                                "webhookUrl": "https://secret.example.invalid/risk",
                                "signatureValue": "NEVER_EXPOSE_RISK_SIGNATURE",
                            }
                        ],
                        "createdAt": 1725256800,
                        "updatedAt": 1725256810,
                    }
                ),
                1,
                1725256810,
            ),
        )
        connection.execute(
            """
            INSERT INTO trade_intents(
              intent_id, rule_id, state, chain, family, token_address,
              estimated_spend_usd, order_id, intent_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                "intent-1",
                "automation-1",
                "simulated",
                "base",
                "evm",
                "0xsafe",
                25.0,
                None,
                json.dumps(
                    {
                        "id": "intent-1",
                        "idempotencyKey": "intent-safe-key",
                        "ruleID": "automation-1",
                        "side": "buy",
                        "state": "simulated",
                        "chain": "base",
                        "family": "evm",
                        "tokenAddress": "0xsafe",
                        "tokenSymbol": "SAFE",
                        "tokenName": "Safe Coin",
                        "tokenLogoURL": "https://secret.example.invalid/logo.png",
                        "sourceEventIDs": ["event-a"],
                        "sourceGroups": ["safe-group"],
                        "mentionCount": 2,
                        "distinctGroupCount": 2,
                        "marketSnapshot": None,
                        "securitySnapshot": {
                            "openSource": "yes",
                            "ownerRenounced": "yes",
                            "isHoneypot": "no",
                            "mintRenounced": True,
                            "freezeRenounced": True,
                            "rugRatio": 0.05,
                            "top10HolderRate": 0.2,
                            "devTeamHoldRate": 0.01,
                            "suspectedInsiderHoldRate": 0.02,
                            "washTrading": False,
                            "buyTax": 0.01,
                            "sellTax": 0.02,
                            "requestHeaders": {
                                "Authorization": "Bearer NEVER_EXPOSE_THIS"
                            },
                        },
                        "inputToken": "ETH",
                        "outputToken": "SAFE",
                        "inputAmountNative": 0.01,
                        "estimatedSpendUSD": 25.0,
                        "quote": {
                            "signatureValue": "NEVER_EXPOSE_QUOTE_SIGNATURE",
                            "webhookUrl": "https://secret.example.invalid/quote",
                        },
                        "rejectionReasons": [],
                        "failureReason": None,
                        "createdAt": 1725256810,
                        "updatedAt": 1725256810,
                    }
                ),
                1725256810,
                1725256810,
            ),
        )
        connection.execute(
            """
            INSERT INTO ai_provider_configurations(
              configuration_id, configuration_json, is_default, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?)
            """,
            (
                "provider-1",
                json.dumps(
                    {
                        "displayName": "OpenAI Compatible",
                        "baseURL": "https://user:password@example.invalid/v1",
                        "model": "NEVER_EXPOSE_MODEL_SECRET",
                        "headers": {"X-API-Key": "NEVER_EXPOSE_HEADER"},
                    }
                ),
                1,
                1725256800,
                1725256810,
            ),
        )
        connection.commit()
        connection.close()

    def start_server(self):
        self.server = create_server(
            ServerOptions(
                host="127.0.0.1",
                port=0,
                token="test-token",
                static_root=self.static_root,
                message_database=self.message_database,
                group_config_path=os.path.join(
                    self.temporary_directory.name, "missing-wecom-groups.txt"
                ),
                workspace_database=self.workspace_path,
                configuration_path=self.configuration_path,
            )
        )
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()
        self.addCleanup(self.stop_server)

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, path):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port)
        connection.request("GET", path, headers={"Authorization": "Bearer test-token"})
        response = connection.getresponse()
        body = response.read().decode("utf-8")
        result = response.status, json.loads(body)
        connection.close()
        return result

    def test_workspace_endpoints_return_only_display_safe_dtos(self):
        payloads = {}
        for endpoint in (
            "alerts", "analyses", "meme", "market", "rules", "automations", "trades",
            "settings/status", "diagnostics",
        ):
            with self.subTest(endpoint=endpoint):
                status, payloads[endpoint] = self.request("/api/" + endpoint)
                self.assertEqual(status, 200)

        self.assertEqual(
            payloads["alerts"]["items"][0],
            {
                "alertId": "alert-1",
                "severity": "warning",
                "title": "Price moved",
                "body": "Check the token",
                "sourceEventIds": ["event-a"],
                "occurrenceCount": 2,
                "ruleId": "rule-1",
                "acknowledgedAt": None,
                "createdAt": "2024-09-02T06:00:00Z",
                "updatedAt": "2024-09-02T06:00:10Z",
                "tokenContext": {
                    "family": "evm",
                    "network": "base",
                    "address": "0xsafe",
                    "mentionCount": 3,
                    "groupNames": ["safe-group"],
                },
                "sourceMessages": [
                    {
                        "eventId": "event-a",
                        "group": "safe-group",
                        "sender": "safe-sender",
                        "content": "真实来源 https://dexscreener.com/base/0xsafe",
                        "messageType": "text",
                        "observedAt": "2024-09-02T06:00:00Z",
                        "sourceSequence": 1,
                        "links": ["https://dexscreener.com/base/0xsafe"],
                    }
                ],
            },
        )
        analyses_by_job = {
            item["jobId"]: item for item in payloads["analyses"]["items"]
        }
        self.assertEqual(
            set(analyses_by_job),
            {
                "job-1", "job-pending", "job-running", "job-retry",
                "job-failed", "job-cancelled",
            },
        )
        self.assertEqual(analyses_by_job["job-1"]["summary"], "Safe summary")
        self.assertEqual(
            analyses_by_job["job-1"]["sourceReferences"], ["event-a"]
        )
        self.assertEqual(
            analyses_by_job["job-1"]["topics"],
            [
                {
                    "topicId": "topic-1",
                    "title": "Token momentum",
                    "summary": "Volume increased",
                    "sourceReferences": ["event-a"],
                }
            ],
        )
        self.assertEqual(analyses_by_job["job-pending"]["state"], "pending")
        self.assertEqual(analyses_by_job["job-pending"]["analysisId"], None)
        self.assertNotIn("summary", analyses_by_job["job-pending"])
        self.assertEqual(payloads["meme"]["items"][0]["symbol"], "SAFE")
        self.assertEqual(payloads["meme"]["items"][0]["priceUsd"], 1.25)
        self.assertEqual(payloads["meme"]["items"][0]["marketCapUsd"], 500000)
        self.assertEqual(payloads["meme"]["items"][0]["liquidityUsd"], 75000)
        self.assertEqual(payloads["meme"]["items"][0]["isPinned"], True)
        self.assertEqual(payloads["meme"]["items"][0]["mentionCount"], 3)
        self.assertEqual(payloads["meme"]["items"][0]["groupNames"], ["safe-group"])
        self.assertEqual(payloads["market"]["available"], False)
        self.assertEqual(payloads["market"]["reason"], "schema_incompatible")
        self.assertEqual(payloads["rules"]["items"][0]["name"], "Momentum")
        self.assertEqual(
            payloads["rules"]["items"][0]["condition"]["groups"],
            ["safe-group", "项目/交易群"],
        )
        self.assertEqual(
            payloads["rules"]["items"][0]["condition"],
            {
                "groups": ["safe-group", "项目/交易群"],
                "senders": ["safe-sender"],
                "includeKeywords": ["up"],
                "excludeKeywords": ["spam"],
                "messageTypes": ["text"],
                "regularExpressionCount": 2,
                "includeKeywordMode": "all",
                "regularExpressionMode": "any",
                "timeWindows": [
                    {
                        "startMinuteOfDay": 60,
                        "endMinuteOfDay": 120,
                        "weekdays": [2],
                        "timeZoneIdentifier": "Asia/Shanghai",
                    }
                ],
                "caseSensitive": False,
            },
        )
        self.assertEqual(
            payloads["rules"]["items"][0]["actions"],
            [
                {"type": "local_alert", "severity": "warning", "title": "Safe alert"},
                {"type": "enqueue_summary", "configurationId": "provider-safe"},
                {
                    "type": "invoke_script",
                    "scriptId": "safe-script",
                },
            ],
        )
        self.assertEqual(payloads["rules"]["invalidRows"], 1)
        self.assertEqual(payloads["automations"]["items"][0]["name"], "Paper buy")
        self.assertEqual(
            payloads["automations"]["items"][0]["condition"],
            {
                "allowedChains": ["base"],
                "groups": ["safe-group"],
                "senders": ["safe-sender"],
                "aggregationWindowSeconds": 600,
                "minimumMentions": 2,
                "minimumDistinctGroups": 2,
                "minimumMarketCapUSD": 500000,
                "maximumMarketCapUSD": 20000000,
                "minimumLiquidityUSD": 100000,
                "minimumHolderCount": 100,
                "maximumRugRatio": 0.1,
                "requireSecurityData": True,
            },
        )
        self.assertEqual(
            payloads["automations"]["items"][0]["actions"],
            [
                {
                    "type": "trade",
                    "inputAmountNative": 0.01,
                    "maximumSlippagePercent": 12,
                    "maximumTradesPerDay": 2,
                    "tokenCooldownSeconds": 86400,
                    "antiMEV": True,
                    "protectionOrders": [
                        {
                            "id": "protection-1",
                            "kind": "stop_loss",
                            "triggerPercent": 50,
                            "sellPercent": 100,
                        }
                    ],
                }
            ],
        )
        self.assertEqual(payloads["trades"]["items"][0]["symbol"], "SAFE")
        self.assertEqual(payloads["trades"]["items"][0]["state"], "simulated")
        self.assertEqual(payloads["trades"]["items"][0]["network"], "base")
        self.assertEqual(
            payloads["trades"]["items"][0]["riskSummary"]["rugRatio"], 0.05
        )
        self.assertEqual(
            payloads["settings/status"],
            {
                "available": True,
                "reason": None,
                "aiConfigured": True,
                "speechConfigured": False,
                "providerNames": ["OpenAI Compatible"],
                "tradingConfigured": False,
            },
        )
        self.assertEqual(payloads["diagnostics"]["available"], True)
        self.assertEqual(payloads["diagnostics"]["sources"]["workspace"]["available"], True)
        self.assertEqual(payloads["diagnostics"]["sources"]["configuration"]["available"], True)

        combined = json.dumps(payloads, ensure_ascii=False)
        for forbidden in (
            "NEVER_EXPOSE_THIS",
            "NEVER_EXPOSE",
            "configuration_json",
            "intent_json",
            "Authorization",
            "Bearer ",
            "www.",
            "/Users/secret",
            "/Users/public",
            "requestHeaders",
            "signatureValue",
            "credentialPath",
            "webhookUrl",
            self.workspace_path,
            self.configuration_path,
        ):
            self.assertNotIn(forbidden, combined)
        lowered = combined.lower()
        for forbidden in (
            "x-auth-token",
            "cookie",
            "session=",
            "../config/prod.toml",
            "ssh://user@host/repo",
        ):
            self.assertNotIn(forbidden, lowered)

        self.assertIn("Safe summary", combined)
        self.assertIn("https://dexscreener.com/base/0xsafe", combined)
        self.assertIn("Safe Coin", combined)
        self.assertIn('"symbol": "SAFE"', combined)
        invoke_action = payloads["rules"]["items"][0]["actions"][2]
        self.assertEqual(invoke_action["scriptId"], "safe-script")
        self.assertNotIn("arguments", invoke_action)

    def test_missing_workspace_database_returns_available_false_without_creating_it(self):
        os.unlink(self.workspace_path)
        for endpoint in ("alerts", "analyses", "meme", "rules", "automations", "trades"):
            with self.subTest(endpoint=endpoint):
                status, payload = self.request("/api/" + endpoint)
                self.assertEqual(status, 200)
                self.assertEqual(payload["available"], False)
                self.assertEqual(payload["reason"], "source_unavailable")
                self.assertEqual(payload["items"], [])
        status, settings = self.request("/api/settings/status")
        self.assertEqual(status, 200)
        self.assertEqual(settings["available"], False)
        self.assertEqual(settings["reason"], "source_unavailable")
        self.assertEqual(settings["providerNames"], [])
        self.assertEqual(settings["tradingConfigured"], False)
        self.assertFalse(os.path.exists(self.workspace_path))

    def test_missing_workspace_parent_is_unavailable_not_permission_denied(self):
        missing_path = os.path.join(
            self.temporary_directory.name, "missing-parent", "workspace.sqlite3"
        )
        repository = WorkspaceRepository(missing_path, self.configuration_path)

        self.assertEqual(repository.alerts()["reason"], "source_unavailable")
        self.assertEqual(
            repository.diagnostics()["sources"]["workspace"],
            {"available": False, "reason": "source_unavailable"},
        )
        self.assertFalse(os.path.exists(os.path.dirname(missing_path)))

    def test_settings_and_diagnostics_classify_configuration_source_failures(self):
        missing_path = os.path.join(
            self.temporary_directory.name, "missing-configuration.json"
        )
        corrupt_path = os.path.join(
            self.temporary_directory.name, "corrupt-configuration.json"
        )
        with open(corrupt_path, "w", encoding="utf-8") as stream:
            stream.write('{"apiKey":"NEVER_EXPOSE_CONFIGURATION"')
        denied_path = os.path.join(
            self.temporary_directory.name, "denied-configuration.json"
        )
        with open(denied_path, "w", encoding="utf-8") as stream:
            stream.write("{}")
        os.chmod(denied_path, 0o000)
        self.addCleanup(os.chmod, denied_path, 0o600)

        for path, reason in (
            (missing_path, "source_unavailable"),
            (corrupt_path, "source_corrupt"),
            (denied_path, "source_permission_denied"),
        ):
            with self.subTest(reason=reason):
                repository = WorkspaceRepository(self.workspace_path, path)
                settings = repository.settings_status()
                diagnostics = repository.diagnostics()
                self.assertEqual(settings["available"], False)
                self.assertEqual(settings["reason"], reason)
                self.assertEqual(
                    diagnostics["sources"]["configuration"],
                    {"available": False, "reason": reason},
                )
                combined = json.dumps((settings, diagnostics), ensure_ascii=False)
                self.assertNotIn("NEVER_EXPOSE_CONFIGURATION", combined)
                self.assertNotIn(path, combined)

    def test_unreadable_workspace_file_is_permission_denied(self):
        os.chmod(self.workspace_path, 0o000)
        try:
            repository = WorkspaceRepository(
                self.workspace_path, self.configuration_path
            )

            self.assertEqual(
                repository.alerts()["reason"], "source_permission_denied"
            )
            self.assertEqual(
                repository.diagnostics()["sources"]["workspace"],
                {"available": False, "reason": "source_permission_denied"},
            )
        finally:
            os.chmod(self.workspace_path, 0o600)

    def test_workspace_and_configuration_detect_inaccessible_ancestors_through_aliases(self):
        denied_directory = os.path.join(
            self.temporary_directory.name, "workspace-denied-ancestor"
        )
        nested_directory = os.path.join(denied_directory, "nested")
        os.makedirs(nested_directory, mode=0o700)
        denied_workspace = os.path.join(nested_directory, "workspace.sqlite3")
        denied_configuration = os.path.join(
            nested_directory, "configuration-center.json"
        )
        os.rename(self.workspace_path, denied_workspace)
        os.rename(self.configuration_path, denied_configuration)
        workspace_alias = os.path.join(
            self.temporary_directory.name, "workspace-denied-alias"
        )
        configuration_alias = os.path.join(
            self.temporary_directory.name, "configuration-denied-alias"
        )
        os.symlink(denied_workspace, workspace_alias)
        os.symlink(denied_configuration, configuration_alias)

        os.chmod(denied_directory, 0o000)
        self.addCleanup(os.chmod, denied_directory, 0o700)
        for path in (denied_workspace, workspace_alias):
            with self.subTest(source="workspace", alias=path == workspace_alias):
                repository = WorkspaceRepository(path, configuration_alias)
                self.assertEqual(
                    repository.alerts()["reason"],
                    "source_permission_denied",
                )
                self.assertEqual(
                    repository.diagnostics()["sources"]["workspace"],
                    {"available": False, "reason": "source_permission_denied"},
                )
        for path in (denied_configuration, configuration_alias):
            with self.subTest(source="configuration", alias=path == configuration_alias):
                repository = WorkspaceRepository(workspace_alias, path)
                self.assertEqual(
                    repository.settings_status()["reason"],
                    "source_permission_denied",
                )
                self.assertEqual(
                    repository.diagnostics()["sources"]["configuration"],
                    {"available": False, "reason": "source_permission_denied"},
                )

    def test_priority_endpoint_is_read_only_and_truthfully_unavailable(self):
        status, payload = self.request("/api/priority")

        self.assertEqual(status, 200)
        self.assertEqual(
            payload,
            {"available": False, "reason": "source_unavailable", "items": []},
        )

    def test_display_text_preserves_normal_unicode_punctuation_newlines_and_slashes(self):
        title = "价格·节点…：Base/上涨 👩‍💻"
        body = "第一行/路径\n第二行：保留原文 👨‍👩‍👧"
        connection = sqlite3.connect(self.workspace_path)
        connection.execute(
            "UPDATE workspace_alerts SET title = ?, body = ? WHERE alert_id = 'alert-1'",
            (title, body),
        )
        connection.commit()
        connection.close()

        status, payload = self.request("/api/alerts")

        self.assertEqual(status, 200)
        self.assertEqual(payload["items"][0]["title"], title)
        self.assertEqual(payload["items"][0]["body"], body)

    def test_display_text_rejects_bidi_controls_without_rejecting_emoji_joiners(self):
        connection = sqlite3.connect(self.workspace_path)
        connection.execute(
            "UPDATE workspace_alerts SET title = ?, body = ? WHERE alert_id = 'alert-1'",
            ("safe\u202eevil", "emoji family 👨‍👩‍👧"),
        )
        connection.commit()
        connection.close()

        status, payload = self.request("/api/alerts")

        self.assertEqual(status, 200)
        self.assertIsNone(payload["items"][0]["title"])
        self.assertEqual(payload["items"][0]["body"], "emoji family 👨‍👩‍👧")

    def test_colon_event_ids_survive_projection_and_resolve_exact_source_messages(self):
        event_id = "41:0000000000000029:legacy-payload"
        connection = sqlite3.connect(self.workspace_path)
        connection.execute(
            "UPDATE workspace_alerts SET source_event_ids_json = ? WHERE alert_id = 'alert-1'",
            (json.dumps([event_id]),),
        )
        connection.commit()
        connection.close()
        connection = sqlite3.connect(self.message_database)
        connection.execute(
            """
            INSERT INTO messages(
              event_id, conversation_id, group_name, sender_display_name, content,
              message_type, observed_at, source_sequence
            ) VALUES (?, 1, '安全群', '来源成员', '带冒号 ID 的真实来源', 'text', 1725256801, 41)
            """,
            (event_id,),
        )
        connection.commit()
        connection.close()

        status, payload = self.request("/api/alerts")

        self.assertEqual(status, 200)
        self.assertEqual(payload["items"][0]["sourceEventIds"], [event_id])
        self.assertEqual(
            [item["eventId"] for item in payload["items"][0]["sourceMessages"]],
            [event_id],
        )

    def test_alert_source_alias_resolves_a_distinct_persisted_message_row(self):
        alias_event_id = "legacy-native-event-id"
        connection = sqlite3.connect(self.message_database)
        connection.executescript(
            """
            CREATE TABLE message_event_aliases(
              alias_event_id TEXT PRIMARY KEY,
              message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
              created_at REAL NOT NULL
            );
            CREATE INDEX message_event_aliases_message_idx
              ON message_event_aliases(message_id);
            """
        )
        message_id = connection.execute(
            "SELECT id FROM messages WHERE event_id = 'event-a'"
        ).fetchone()[0]
        connection.execute(
            "INSERT INTO message_event_aliases(alias_event_id, message_id, created_at) "
            "VALUES (?, ?, ?)",
            (alias_event_id, message_id, time.time()),
        )
        connection.commit()
        connection.close()
        connection = sqlite3.connect(self.workspace_path)
        connection.execute(
            "UPDATE workspace_alerts SET source_event_ids_json = ? WHERE alert_id = 'alert-1'",
            (json.dumps([alias_event_id]),),
        )
        connection.commit()
        connection.close()

        status, payload = self.request("/api/alerts")

        self.assertEqual(status, 200)
        alert = payload["items"][0]
        self.assertEqual(alert["sourceEventIds"], [alias_event_id])
        self.assertEqual(len(alert["sourceMessages"]), 1)
        self.assertEqual(alert["sourceMessages"][0]["eventId"], alias_event_id)
        self.assertEqual(
            alert["sourceMessages"][0]["content"],
            "真实来源 https://dexscreener.com/base/0xsafe",
        )

    def test_alert_source_quarantine_overrides_a_stale_active_alias_row(self):
        alias_event_id = "ambiguous-legacy-compatibility-id"
        connection = sqlite3.connect(self.message_database)
        connection.executescript(
            """
            CREATE TABLE message_event_aliases(
              alias_event_id TEXT PRIMARY KEY,
              message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
              created_at REAL NOT NULL
            );
            CREATE TABLE message_event_alias_quarantine(
              alias_event_id TEXT PRIMARY KEY,
              version INTEGER NOT NULL,
              claimant_message_ids_json TEXT NOT NULL,
              quarantined_at REAL NOT NULL
            );
            """
        )
        message_id = connection.execute(
            "SELECT id FROM messages WHERE event_id = 'event-a'"
        ).fetchone()[0]
        connection.execute(
            "INSERT INTO message_event_aliases(alias_event_id, message_id, created_at) "
            "VALUES (?, ?, ?)",
            (alias_event_id, message_id, time.time()),
        )
        connection.execute(
            "INSERT INTO message_event_alias_quarantine("
            "alias_event_id, version, claimant_message_ids_json, quarantined_at"
            ") VALUES (?, 2026090305, '[1,2]', ?)",
            (alias_event_id, time.time()),
        )
        connection.commit()
        connection.close()
        connection = sqlite3.connect(self.workspace_path)
        connection.execute(
            "UPDATE workspace_alerts SET source_event_ids_json = ? WHERE alert_id = 'alert-1'",
            (json.dumps([alias_event_id]),),
        )
        connection.commit()
        connection.close()

        status, payload = self.request("/api/alerts")

        self.assertEqual(status, 200)
        alert = payload["items"][0]
        self.assertEqual(alert["sourceEventIds"], [alias_event_id])
        self.assertEqual(alert["sourceMessages"], [])

    def test_alert_source_quarantine_does_not_hide_an_exact_event_row(self):
        event_id = "event-a"
        connection = sqlite3.connect(self.message_database)
        connection.executescript(
            """
            CREATE TABLE message_event_alias_quarantine(
              alias_event_id TEXT PRIMARY KEY,
              version INTEGER NOT NULL,
              claimant_message_ids_json TEXT NOT NULL,
              quarantined_at REAL NOT NULL
            );
            """
        )
        connection.execute(
            "INSERT INTO message_event_alias_quarantine("
            "alias_event_id, version, claimant_message_ids_json, quarantined_at"
            ") VALUES (?, 2026090305, '[1,2]', ?)",
            (event_id, time.time()),
        )
        connection.commit()
        connection.close()
        connection = sqlite3.connect(self.workspace_path)
        connection.execute(
            "UPDATE workspace_alerts SET source_event_ids_json = ? WHERE alert_id = 'alert-1'",
            (json.dumps([event_id]),),
        )
        connection.commit()
        connection.close()

        status, payload = self.request("/api/alerts")

        self.assertEqual(status, 200)
        self.assertEqual(payload["items"][0]["sourceMessages"][0]["eventId"], event_id)
        self.assertEqual(
            payload["items"][0]["sourceMessages"][0]["content"],
            "真实来源 https://dexscreener.com/base/0xsafe",
        )

    def test_workspace_lock_is_reported_as_retriable_source_locked(self):
        lock = sqlite3.connect(self.workspace_path, timeout=0)
        lock.execute("BEGIN EXCLUSIVE")
        self.addCleanup(lock.close)

        status, payload = self.request("/api/alerts")

        settings_status, settings = self.request("/api/settings/status")

        lock.rollback()
        self.assertEqual(status, 200)
        self.assertEqual(payload["available"], False)
        self.assertEqual(payload["reason"], "source_locked")
        self.assertEqual(settings_status, 200)
        self.assertEqual(settings["available"], False)
        self.assertEqual(settings["reason"], "source_locked")
        self.assertEqual(settings["providerNames"], [])
        self.assertEqual(settings["tradingConfigured"], False)

        lock.execute("BEGIN EXCLUSIVE")
        diagnostics = WorkspaceRepository(
            self.workspace_path, self.configuration_path
        ).diagnostics()
        lock.rollback()
        self.assertEqual(
            diagnostics["sources"]["workspace"],
            {"available": False, "reason": "source_locked"},
        )

    def test_workspace_health_validates_columns_consumed_by_native_endpoints(self):
        incomplete_path = os.path.join(
            self.temporary_directory.name, "missing-alert-severity.sqlite3"
        )
        source = sqlite3.connect(self.workspace_path)
        incomplete = sqlite3.connect(incomplete_path)
        source.backup(incomplete)
        source.close()
        columns = [
            row[1]
            for row in incomplete.execute("PRAGMA table_info(workspace_alerts)").fetchall()
            if row[1] != "severity"
        ]
        selection = ", ".join(columns)
        incomplete.executescript(
            """
            ALTER TABLE workspace_alerts RENAME TO workspace_alerts_complete;
            CREATE TABLE workspace_alerts AS
              SELECT {selection} FROM workspace_alerts_complete;
            DROP TABLE workspace_alerts_complete;
            """.format(selection=selection)
        )
        incomplete.commit()
        incomplete.close()

        repository = WorkspaceRepository(incomplete_path, self.configuration_path)

        self.assertEqual(
            repository.diagnostics()["sources"]["workspace"],
            {"available": False, "reason": "schema_incompatible"},
        )
        self.assertEqual(repository.alerts()["reason"], "schema_incompatible")
        self.assertEqual(repository.settings_status()["available"], False)
        self.assertEqual(repository.settings_status()["reason"], "schema_incompatible")

    def test_workspace_schema_corruption_and_permission_states_are_distinct(self):
        schema_path = os.path.join(self.temporary_directory.name, "schema-only.sqlite3")
        connection = sqlite3.connect(schema_path)
        connection.execute("CREATE TABLE unrelated(value INTEGER)")
        connection.close()
        schema_repository = WorkspaceRepository(schema_path, self.configuration_path)
        self.assertEqual(schema_repository.alerts()["reason"], "schema_incompatible")
        self.assertEqual(
            schema_repository.diagnostics()["sources"]["workspace"],
            {"available": False, "reason": "schema_incompatible"},
        )

        for missing_table in (
            "crypto_address_incidents",
            "trade_automation_configuration",
        ):
            with self.subTest(missing_table=missing_table):
                incomplete_path = os.path.join(
                    self.temporary_directory.name,
                    "missing-{}.sqlite3".format(missing_table),
                )
                source = sqlite3.connect(self.workspace_path)
                incomplete = sqlite3.connect(incomplete_path)
                source.backup(incomplete)
                source.close()
                incomplete.execute("DROP TABLE {}".format(missing_table))
                incomplete.commit()
                incomplete.close()
                repository = WorkspaceRepository(
                    incomplete_path, self.configuration_path
                )
                self.assertEqual(
                    repository.diagnostics()["sources"]["workspace"],
                    {"available": False, "reason": "schema_incompatible"},
                )

        corrupt_path = os.path.join(self.temporary_directory.name, "corrupt.sqlite3")
        with open(corrupt_path, "wb") as stream:
            stream.write(b"not a sqlite database")
        corrupt_repository = WorkspaceRepository(corrupt_path, self.configuration_path)
        self.assertEqual(corrupt_repository.alerts()["reason"], "source_corrupt")
        self.assertEqual(
            corrupt_repository.diagnostics()["sources"]["workspace"],
            {"available": False, "reason": "source_corrupt"},
        )

        denied_directory = os.path.join(self.temporary_directory.name, "denied")
        os.mkdir(denied_directory, 0o700)
        denied_path = os.path.join(denied_directory, "workspace.sqlite3")
        connection = sqlite3.connect(denied_path)
        connection.execute("CREATE TABLE unrelated(value INTEGER)")
        connection.close()
        os.chmod(denied_directory, 0o000)
        try:
            denied_repository = WorkspaceRepository(denied_path, self.configuration_path)
            self.assertEqual(denied_repository.alerts()["reason"], "source_permission_denied")
            self.assertEqual(
                denied_repository.diagnostics()["sources"]["workspace"],
                {"available": False, "reason": "source_permission_denied"},
            )
        finally:
            os.chmod(denied_directory, 0o700)

    def test_analyses_include_jobs_that_do_not_have_results(self):
        status, payload = self.request("/api/analyses")
        self.assertEqual(status, 200)
        by_job = {item["jobId"]: item for item in payload["items"]}
        expected_states = {
            "job-pending": "pending",
            "job-running": "running",
            "job-retry": "retry_wait",
            "job-failed": "failed",
            "job-cancelled": "cancelled",
        }
        self.assertEqual(set(by_job), {"job-1"} | set(expected_states))
        for job_id, state in expected_states.items():
            with self.subTest(job_id=job_id):
                self.assertEqual(by_job[job_id]["state"], state)
                self.assertEqual(by_job[job_id]["analysisId"], None)
                self.assertNotIn("summary", by_job[job_id])

    def test_alert_sources_are_looked_up_by_exact_event_id_beyond_latest_page(self):
        connection = sqlite3.connect(self.message_database)
        connection.executemany(
            """
            INSERT INTO messages(
              event_id, conversation_id, group_name, sender_display_name, content,
              message_type, observed_at, source_sequence
            ) VALUES (?, 1, 'noise-group', 'noise-sender', 'newer noise', 'text', ?, ?)
            """,
            [
                ("event-noise-{:03d}".format(index), 1725256801 + index, index + 2)
                for index in range(205)
            ],
        )
        connection.commit()
        connection.close()

        status, payload = self.request("/api/alerts")

        self.assertEqual(status, 200)
        self.assertEqual(
            [item["eventId"] for item in payload["items"][0]["sourceMessages"]],
            ["event-a"],
        )

    def test_native_codable_workspace_blobs_are_projected_to_safe_dtos(self):
        _, meme = self.request("/api/meme")
        _, automations = self.request("/api/automations")
        _, trades = self.request("/api/trades")

        self.assertEqual(meme["items"][0]["symbol"], "SAFE")
        self.assertEqual(meme["items"][0]["priceUsd"], 1.25)
        self.assertEqual(meme["items"][0]["marketCapUsd"], 500000)
        self.assertEqual(
            automations["items"][0]["condition"]["maximumRugRatio"], 0.1
        )
        self.assertEqual(
            automations["items"][0]["actions"][0]["protectionOrders"][0]["kind"],
            "stop_loss",
        )
        self.assertEqual(trades["items"][0]["symbol"], "SAFE")
        self.assertEqual(trades["items"][0]["network"], "base")
        self.assertEqual(trades["items"][0]["riskSummary"]["rugRatio"], 0.05)

    def test_unknown_nested_fields_never_return_secret_material(self):
        payloads = [
            self.request("/api/analyses")[1],
            self.request("/api/rules")[1],
            self.request("/api/meme")[1],
            self.request("/api/automations")[1],
            self.request("/api/trades")[1],
        ]
        combined = json.dumps(payloads, ensure_ascii=False)
        for forbidden in (
            "NEVER_EXPOSE",
            "Authorization",
            "Bearer ",
            "/Users/secret",
            "requestHeaders",
            "signatureValue",
            "credentialPath",
            "webhookUrl",
        ):
            self.assertNotIn(forbidden, combined)

    def test_nonstandard_json_constant_is_an_invalid_row(self):
        connection = sqlite3.connect(self.workspace_path)
        connection.execute(
            "UPDATE ca_watch_pool_items SET item_json = ?",
            ('{"symbol":"bad","priceUsd":NaN}',),
        )
        connection.commit()
        connection.close()

        status, payload = self.request("/api/meme")
        self.assertEqual(status, 200)
        self.assertEqual(payload["items"], [])
        self.assertEqual(payload["invalidRows"], 1)


class LanServerCliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cli = load_cli_module()

    def parse_options(self, arguments):
        with redirect_stderr(io.StringIO()):
            return self.cli.parse_options(arguments)

    def test_configuration_defaults_to_the_explicit_configuration_center(self):
        options = self.parse_options([])
        self.assertEqual(
            options.configuration,
            os.path.expanduser("~/Library/Application Support/wxFomo/configuration-center.json"),
        )

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
