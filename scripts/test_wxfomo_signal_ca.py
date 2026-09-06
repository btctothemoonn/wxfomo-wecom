import json
import os
import sqlite3
import tempfile
import unittest

from scripts.wxfomo_lan.signal_contract import SyncError, validate_payload


ADDRESS = "0x" + "Ab" * 20


def message(row_id, group, timestamp, sender="合成昵称", content=None,
            event_id=None, record_version=1, inserted_at=None):
    return {
        "row_id": row_id,
        "event_id": event_id or "fixture-" + str(row_id),
        "record_version": record_version,
        "group": group,
        "sender": sender,
        "content": content if content is not None else "Base CA: " + ADDRESS,
        "observed_at": timestamp,
        "inserted_at": timestamp if inserted_at is None else inserted_at,
    }


class SignalCATests(unittest.TestCase):
    def test_two_groups_trigger_without_ai_and_keep_address_case(self):
        from scripts.wxfomo_lan.signal_ca import advance_ca
        result = advance_ca({}, [message(1, "合成甲群", 1000),
                                 message(2, "合成乙群", 1010)], 1010, 0,
                            "fixture-device", "00000000-0000-4000-8000-000000000001")
        alert = result["alerts"][0]["alert"]
        self.assertEqual(alert["groupCount"], 2)
        self.assertEqual(alert["address"], ADDRESS)
        self.assertEqual(alert["duplicateCount"], 1)
        self.assertEqual(alert["notificationVersion"], 1)
        self.assertNotIn("content", str(result["state"]))
        validate_payload(result["alerts"][0])

    def test_window_is_open_on_the_left_and_expiry_uses_second_newest_group(self):
        from scripts.wxfomo_lan.signal_ca import advance_ca
        state = advance_ca({}, [message(1, "甲群", 1000), message(2, "乙群", 1010)],
                           1010, 0, "d", "s")["state"]
        unchanged = advance_ca(state, [], 4599, 0, "d", "s")
        self.assertEqual(unchanged["alerts"], [])
        expired = advance_ca(unchanged["state"], [], 4600, 0, "d", "s")
        self.assertEqual(expired["alerts"][0]["alert"]["status"], "expired")
        self.assertEqual(expired["alerts"][0]["alert"]["expiresAt"],
                         "1970-01-01T01:16:40Z")

    def test_same_group_unknown_chain_and_different_chains_do_not_trigger(self):
        from scripts.wxfomo_lan.signal_ca import advance_ca
        cases = [
            [message(1, "甲群", 1000), message(2, "甲群", 1010)],
            [message(1, "甲群", 1000, content=ADDRESS),
             message(2, "乙群", 1010, content=ADDRESS)],
            [message(1, "甲群", 1000, content="Base: " + ADDRESS),
             message(2, "乙群", 1010, content="BSC: " + ADDRESS)],
        ]
        for rows in cases:
            with self.subTest(rows=rows):
                self.assertEqual(advance_ca({}, rows, 1010, 0, "d", "s")["alerts"], [])

    def test_relay_duplicates_and_anonymous_statements_have_safe_counting(self):
        from scripts.wxfomo_lan.signal_ca import advance_ca
        copied = [message(1, "甲群", 1000), message(2, "乙群", 1010)]
        alert = advance_ca({}, copied, 1010, 0, "d", "s")["alerts"][0]["alert"]
        self.assertEqual((alert["mentionCount"], alert["uniqueStatementCount"],
                          alert["duplicateCount"]), (2, 1, 1))
        anonymous = [message(1, "甲群", 1000, sender=""),
                     message(2, "乙群", 1010, sender="")]
        alert = advance_ca({}, anonymous, 1010, 0, "d", "s")["alerts"][0]["alert"]
        self.assertEqual((alert["uniqueStatementCount"], alert["duplicateCount"]), (2, 0))

    def test_unknown_and_future_times_are_tracked_as_gaps_not_counted(self):
        from scripts.wxfomo_lan.signal_ca import advance_ca
        rows = [message(1, "甲群", None, inserted_at=1000),
                message(2, "乙群", 2000, inserted_at=1000)]
        result = advance_ca({}, rows, 1000, 0, "d", "s")
        self.assertEqual(result["alerts"], [])
        self.assertEqual(result["state"]["meta"]["unknown_time_count"], 1)
        self.assertEqual(result["state"]["meta"]["future_time_count"], 1)

        later = advance_ca(result["state"], [message(3, "甲群", 2000)],
                           2000, 0, "d", "s")
        self.assertEqual(later["alerts"], [])
        self.assertEqual(later["state"]["meta"]["future_time_count"], 1)

    def test_identical_future_source_version_stays_isolated_after_wall_time_arrives(self):
        from scripts.wxfomo_lan.signal_ca import advance_ca, reconcile_ca
        future = message(2, "乙群", 2000, inserted_at=1000)
        state = advance_ca({}, [message(1, "甲群", 1000), future],
                           1000, 0, "d", "s")["state"]
        self.assertEqual(state["mentions"]["row:2"]["time_status"], "future")
        state = reconcile_ca(state, [future], 2000)
        result = advance_ca(state, [], 2000, 0, "d", "s")
        self.assertEqual(result["state"]["mentions"]["row:2"]["time_status"], "future")
        self.assertEqual(result["alerts"], [])

    def test_invalid_record_version_is_a_fixed_error_not_silent_cursor_progress(self):
        from scripts.wxfomo_lan.signal_ca import advance_ca
        with self.assertRaises(SyncError) as caught:
            advance_ca({}, [message(1, "甲群", 1000, record_version=0)],
                       1000, 0, "d", "s")
        self.assertEqual(caught.exception.code, "ca_row_invalid")

    def test_late_insert_in_window_triggers_catchup_without_notification(self):
        from scripts.wxfomo_lan.signal_ca import advance_ca
        rows = [message(1, "甲群", 1900, inserted_at=1900),
                message(2, "乙群", 1910, inserted_at=1910)]
        alert = advance_ca({}, rows, 2000, 0, "d", "s")["alerts"][0]["alert"]
        self.assertTrue(alert["catchup"])
        self.assertEqual(alert["notificationVersion"], 0)

    def test_restart_catchup_skips_expired_but_keeps_current_rows(self):
        from scripts.wxfomo_lan.signal_ca import advance_ca
        old = [message(1, "甲群", 1000), message(2, "乙群", 1010)]
        result = advance_ca({}, old, 5000, 2, "d", "s")
        self.assertEqual((result["alerts"], result["skipped_expired"],
                          result["last_row_id"]), ([], 2, 2))
        current = [message(3, "甲群", 4900), message(4, "乙群", 4910)]
        result = advance_ca(result["state"], current, 5000, 4, "d", "s")
        self.assertTrue(result["alerts"][0]["alert"]["catchup"])
        self.assertEqual(result["alerts"][0]["alert"]["notificationVersion"], 0)

    def test_material_update_reuses_episode_and_idle_tick_does_not_revise(self):
        from scripts.wxfomo_lan.signal_ca import advance_ca
        first = advance_ca({}, [message(1, "甲群", 1000), message(2, "乙群", 1010)],
                           1010, 0, "d", "s")
        idle = advance_ca(first["state"], [], 1020, 0, "d", "s")
        self.assertEqual(idle["alerts"], [])
        update = advance_ca(idle["state"], [message(3, "丙群", 1030)], 1030, 0, "d", "s")
        self.assertEqual(update["alerts"][0]["alert"]["id"],
                         first["alerts"][0]["alert"]["id"])
        self.assertEqual(update["alerts"][0]["alert"]["revision"], 2)
        self.assertEqual(update["alerts"][0]["alert"]["notificationVersion"], 1)

    def test_reaching_threshold_again_creates_new_episode_and_honors_cooldown(self):
        from scripts.wxfomo_lan.signal_ca import advance_ca, reconcile_ca
        first = advance_ca({}, [message(1, "甲群", 1000), message(2, "乙群", 1010)],
                           1010, 0, "d", "s")
        removed = reconcile_ca(first["state"], [{
            "event_id": "fixture-2", "source_status": "missing"
        }], 1020)
        expired = advance_ca(removed, [], 1020, 0, "d", "s")
        second = advance_ca(expired["state"], [message(3, "乙群", 1030)],
                            1030, 0, "d", "s")
        self.assertNotEqual(second["alerts"][0]["alert"]["id"],
                            first["alerts"][0]["alert"]["id"])
        self.assertEqual(second["alerts"][0]["alert"]["notificationVersion"], 0)
        self.assertEqual(second["alerts"][0]["alert"]["revision"], 1)

    def test_reconcile_version_change_can_add_ca_and_alias_merge_collapses_rows(self):
        from scripts.wxfomo_lan.signal_ca import advance_ca, reconcile_ca
        initial = advance_ca({}, [message(1, "甲群", 1000, content="plain"),
                                  message(2, "乙群", 1010)], 1010, 0, "d", "s")
        changed = reconcile_ca(initial["state"], [message(
            1, "甲群", 1000, content="Base: " + ADDRESS, record_version=2
        )], 1020)
        triggered = advance_ca(changed, [], 1020, 0, "d", "s")
        self.assertEqual(triggered["alerts"][0]["alert"]["groupCount"], 2)

        aliased = reconcile_ca(triggered["state"], [dict(
            message(1, "甲群", 1000, event_id="canonical", record_version=3),
            requested_event_id="fixture-1", source_status="current")], 1030)
        self.assertEqual(len(aliased["mentions"]), 2)
        self.assertIn("canonical", {row["event_id"] for row in aliased["mentions"].values()})

    def test_reconcile_group_change_delete_and_alias_merge_end_false_cross_group(self):
        from scripts.wxfomo_lan.signal_ca import advance_ca, reconcile_ca
        first = advance_ca({}, [message(1, "甲群", 1000), message(2, "乙群", 1010)],
                           1010, 0, "d", "s")
        moved = reconcile_ca(first["state"], [message(
            2, "甲群", 1010, record_version=2
        )], 1020)
        expired = advance_ca(moved, [], 1020, 0, "d", "s")
        self.assertEqual(expired["alerts"][0]["alert"]["status"], "expired")

        first = advance_ca({}, [message(1, "甲群", 1000), message(2, "乙群", 1010)],
                           1010, 0, "d", "s")
        deleted = reconcile_ca(first["state"], [{
            "event_id": "fixture-2", "source_status": "missing"
        }], 1020)
        self.assertEqual(advance_ca(deleted, [], 1020, 0, "d", "s")
                         ["alerts"][0]["alert"]["status"], "expired")

        merged = reconcile_ca(first["state"], [
            dict(message(1, "甲群", 1000, event_id="canonical", record_version=2),
                 requested_event_id="fixture-1", source_status="current"),
            dict(message(1, "甲群", 1000, event_id="canonical", record_version=2),
                 requested_event_id="fixture-2", source_status="current"),
        ], 1020)
        self.assertEqual(len(merged["mentions"]), 1)
        self.assertEqual(advance_ca(merged, [], 1020, 0, "d", "s")
                         ["alerts"][0]["alert"]["status"], "expired")

    def test_new_episode_after_cooldown_notifies_and_serialized_restart_is_stable(self):
        from scripts.wxfomo_lan.signal_ca import advance_ca, reconcile_ca
        first = advance_ca({}, [message(1, "甲群", 1000), message(2, "乙群", 1010)],
                           1010, 0, "d", "s")
        restarted = json.loads(json.dumps(first["state"], ensure_ascii=False))
        idle = advance_ca(restarted, [], 1100, 0, "d", "s")
        self.assertEqual(idle["alerts"], [])
        episode = next(iter(idle["state"]["episodes"].values()))
        self.assertEqual((episode["sequence"], episode["revision"]), (1, 1))

        removed = reconcile_ca(idle["state"], [{
            "event_id": "fixture-2", "source_status": "missing"
        }], 2900)
        expired = advance_ca(removed, [], 2900, 0, "d", "s")
        regained = advance_ca(expired["state"], [
            message(3, "甲群", 2890), message(4, "乙群", 2900)
        ], 2900, 0, "d", "s")
        self.assertEqual(regained["alerts"][0]["alert"]["notificationVersion"], 1)

    def test_more_than_fifty_active_cards_are_all_maintained(self):
        from scripts.wxfomo_lan.signal_ca import advance_ca
        rows = []
        for index in range(51):
            address = "0x{:040x}".format(index + 1)
            rows.extend([message(index * 2 + 1, "甲群", 1000,
                                 content="Base: " + address),
                         message(index * 2 + 2, "乙群", 1010,
                                 content="Base: " + address)])
        result = advance_ca({}, rows, 1010, 0, "d", "s")
        self.assertEqual(len(result["alerts"]), 51)
        self.assertEqual(len(result["state"]["episodes"]), 51)

    def test_state_changes_are_minimal_and_use_only_allowed_operations(self):
        from scripts.wxfomo_lan.signal_ca import advance_ca, ca_state_changes
        new = advance_ca({}, [message(1, "甲群", 1000), message(2, "乙群", 1010)],
                         1010, 0, "d", "s")["state"]
        changes = ca_state_changes({}, new)
        self.assertEqual({item["op"] for item in changes},
                         {"upsert_mention", "upsert_episode", "set_ca_meta"})
        self.assertEqual(ca_state_changes(new, new), [])
        without_one = dict(new, mentions=dict(new["mentions"]))
        without_one["mentions"].pop(next(iter(without_one["mentions"])))
        self.assertEqual(ca_state_changes(new, without_one)[0]["op"], "delete_mention")


class CAReaderTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = os.path.join(self.directory.name, "messages.sqlite3")
        connection = sqlite3.connect(self.path)
        connection.executescript("""
          CREATE TABLE messages(
            id INTEGER PRIMARY KEY, event_id TEXT UNIQUE, record_version INTEGER,
            group_name TEXT, sender_display_name TEXT, content TEXT,
            observed_at REAL, inserted_at REAL);
          CREATE TABLE message_event_aliases(alias_event_id TEXT, message_id INTEGER);
          CREATE TABLE message_event_alias_quarantine(alias_event_id TEXT);
          INSERT INTO messages VALUES(1,'canonical',2,'甲群','猫','Base CA: 0xabababababababababababababababababababab',1000,1001);
          INSERT INTO message_event_aliases VALUES('old-event',1);
          INSERT INTO message_event_alias_quarantine VALUES('bad-event');
        """)
        connection.commit()
        connection.close()

    def test_reader_is_bounded_read_only_and_reports_alias_source_states(self):
        from scripts.wxfomo_lan.signal_ca import CAReader
        reader = CAReader(self.path)
        self.assertEqual(reader.after_row_id(0, 1)[0]["record_version"], 2)
        rows = reader.current_rows(["old-event", "missing", "bad-event"])
        self.assertEqual([row["source_status"] for row in rows],
                         ["current", "missing", "quarantined"])
        self.assertEqual(rows[0]["requested_event_id"], "old-event")
        self.assertEqual(rows[0]["event_id"], "canonical")
        with self.assertRaises(SyncError):
            reader.after_row_id(0, 501)

    def test_unreadable_source_raises_fixed_error_instead_of_empty_rows(self):
        from scripts.wxfomo_lan.signal_ca import CAReader
        with self.assertRaises(SyncError) as caught:
            CAReader(self.path + ".missing").after_row_id(0, 10)
        self.assertEqual(caught.exception.code, "source_unavailable")


if __name__ == "__main__":
    unittest.main()
