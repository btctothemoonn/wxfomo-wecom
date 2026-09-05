import json
import os
import sqlite3
import tempfile
import unittest

from scripts.wxfomo_lan.messages import MessageRepository
from scripts.wxfomo_lan.analysis_source import MessageSource
from scripts.wxfomo_lan.minimax import chunk_messages


class RelayMessageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = os.path.join(self.directory.name, "messages.sqlite3")
        self.connection = sqlite3.connect(self.path)
        self.addCleanup(self.connection.close)
        self.connection.executescript("""
            CREATE TABLE messages(
              id INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT UNIQUE,
              group_name TEXT, sender_display_name TEXT, content TEXT,
              message_type TEXT, observed_at REAL, source_sequence INTEGER);
            CREATE TABLE message_event_aliases(alias_event_id TEXT, message_id INTEGER);
            INSERT INTO messages VALUES(1, 'old', '甲群', 'sun', '猫: 旧消息', 'text', 100, 1);
            INSERT INTO messages VALUES(2, 'new', '乙群', 'robot', '猫: 新消息', 'text', 50, 2);
            INSERT INTO message_event_aliases VALUES('new-alias', 2);
        """)
        self.connection.commit()
        self.settings = self.path + ".relay.json"
        with open(self.settings, "w") as stream:
            json.dump({"version": 1, "afterRowId": 1}, stream)

    def repository(self):
        return MessageRepository(self.path, os.path.join(self.directory.name, "groups.txt"))

    def test_only_new_insertions_change_and_raw_storage_stays_intact(self):
        repo = self.repository()
        old, new = repo.by_event_ids(["old", "new"])
        self.assertEqual((old["sender"], old["content"]), ("sun", "猫: 旧消息"))
        self.assertNotIn("relaySender", old)
        self.assertEqual((new["sender"], new["content"]), ("猫", "新消息"))
        self.assertEqual((new["relaySender"], new["originalContent"]), ("robot", "猫: 新消息"))
        self.assertEqual(self.connection.execute(
            "SELECT sender_display_name,content FROM messages WHERE id=2"
        ).fetchone(), ("robot", "猫: 新消息"))
        self.assertEqual(self.repository().by_event_ids(["new"])[0], new)

    def test_list_search_alias_and_ai_agree_on_actual_author(self):
        listed = self.repository().query({"q": "猫"})["items"]
        self.assertEqual({m["eventId"]: m["sender"] for m in listed}, {"old": "sun", "new": "猫"})
        alias = self.repository().by_event_ids(["new-alias"])[0]
        self.assertEqual((alias["sender"], alias["content"]), ("猫", "新消息"))
        source = MessageSource(self.path)
        for messages in (source.by_event_ids(["old", "new"]), source.after(None, 10),
                         [m for _, m in source.after_row_id(0, 10)]):
            by_id = {m["eventId"]: m for m in messages}
            self.assertEqual(by_id["old"]["senderDisplayName"], "sun")
            self.assertEqual(by_id["new"]["senderDisplayName"], "猫")
            self.assertEqual(by_id["new"]["content"], "新消息")
            self.assertNotIn("id", by_id["new"])
        chunks = chunk_messages(source.by_event_ids(["new"]), 10000)
        self.assertEqual(chunks[0][0]["senderDisplayName"], "猫")
        self.assertEqual(chunks[0][0]["content"], "新消息")
        self.assertNotIn("originalContent", chunks[0][0])

    def test_prefixes_split_once_and_ordinary_messages_remain_unchanged(self):
        cases = [
            ("一只浪迹天涯的猫: 感觉像是熟人作案", "一只浪迹天涯的猫", "感觉像是熟人作案"),
            ("黄心源：黑吃黑", "黄心源", "黑吃黑"),
            ("Z h[u+1F354]: 被同伙拿走了", "Z h[u+1F354]", "被同伙拿走了"),
            ("猫: Mu: 引用别人的话\n下一行", "猫", "Mu: 引用别人的话\n下一行"),
            ("Mu: https://example.com/path", "Mu", "https://example.com/path"),
            ("https://example.com/path", "robot", "https://example.com/path"),
            ("12:30 开始", "robot", "12:30 开始"),
            ("12：30 开始", "robot", "12：30 开始"),
            ("价格：$0.002", "robot", "价格：$0.002"),
            ("Market Cap: $2m", "robot", "Market Cap: $2m"),
            ("MC: $2m\nLP: $100k", "robot", "MC: $2m\nLP: $100k"),
            ("CA：0x" + "a" * 40, "robot", "CA：0x" + "a" * 40),
            ("没有姓名前缀", "robot", "没有姓名前缀"),
            ("猫：   ", "robot", "猫：   "),
            ("正文\n猫: 不是开头", "robot", "正文\n猫: 不是开头"),
        ]
        for raw, author, body in cases:
            with self.subTest(raw=raw):
                self.connection.execute("UPDATE messages SET content=? WHERE id=2", (raw,))
                self.connection.commit()
                item = self.repository().by_event_ids(["new"])[0]
                self.assertEqual((item["sender"], item["content"]), (author, body))

    def test_missing_invalid_or_symlinked_activation_keeps_all_messages_original(self):
        for value in ({"version": 1, "afterRowId": True}, {"version": 1, "afterRowId": -1},
                      {"version": 2, "afterRowId": 0}, {}):
            with open(self.settings, "w") as stream:
                json.dump(value, stream)
            self.assertEqual(self.repository().by_event_ids(["new"])[0]["sender"], "robot")
        os.unlink(self.settings)
        self.assertEqual(self.repository().by_event_ids(["new"])[0]["sender"], "robot")
        os.symlink(self.path, self.settings)
        self.assertEqual(self.repository().by_event_ids(["new"])[0]["sender"], "robot")


if __name__ == "__main__":
    unittest.main()
