"""Read-only access to listener-owned messages for the analysis worker."""

from contextlib import closing
import os
import sqlite3
import urllib.parse

from .relay import attribute_message, load_boundary


_MESSAGE_COLUMNS = (
    "id", "event_id", "group_name", "sender_display_name", "content", "message_type",
    "observed_at",
)


class MessageSource(object):
    """Fetch the minimal message fields without ever writing the listener database."""

    def __init__(self, path):
        self.path = path
        self.relay_boundary = load_boundary(path)

    def _open(self):
        uri = "file:{}?mode=ro".format(urllib.parse.quote(os.path.abspath(self.path)))
        connection = sqlite3.connect(uri, uri=True, timeout=0.25)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA query_only=ON")
        return connection

    def _message(self, row):
        return attribute_message({
            "eventId": row["event_id"],
            "groupName": row["group_name"],
            "senderDisplayName": row["sender_display_name"],
            "content": row["content"],
            "messageType": row["message_type"],
            "observedAt": row["observed_at"],
        }, row["id"], self.relay_boundary, "senderDisplayName")

    def after(self, cursor, limit):
        if not isinstance(limit, int) or isinstance(limit, bool) or limit <= 0:
            raise ValueError("limit must be a positive integer")
        if cursor is None:
            with closing(self._open()) as connection:
                rows = connection.execute(
                    "SELECT {} FROM messages ORDER BY observed_at, event_id LIMIT ?".format(
                        ", ".join(_MESSAGE_COLUMNS)
                    ),
                    (limit,),
                ).fetchall()
            return [self._message(row) for row in rows]
        if (
            not isinstance(cursor, tuple) or len(cursor) != 2
            or not isinstance(cursor[0], (int, float)) or isinstance(cursor[0], bool)
            or not isinstance(cursor[1], str) or not cursor[1]
        ):
            raise ValueError("cursor must be an observed time and event ID")
        with closing(self._open()) as connection:
            rows = connection.execute(
                "SELECT {} FROM messages WHERE (observed_at > ?) OR "
                "(observed_at = ? AND event_id > ?) "
                "ORDER BY observed_at, event_id LIMIT ?".format(
                    ", ".join(_MESSAGE_COLUMNS)
                ),
                (cursor[0], cursor[0], cursor[1], limit),
            ).fetchall()
        return [self._message(row) for row in rows]

    def event_ids_in_window(self, start, end):
        with closing(self._open()) as connection:
            rows = connection.execute(
                "SELECT event_id FROM messages WHERE observed_at >= ? "
                "AND observed_at < ? ORDER BY observed_at, event_id",
                (start, end),
            ).fetchall()
        return [row["event_id"] for row in rows]

    def after_row_id(self, row_id, limit):
        """Return insertion progress separately from the public message projection."""
        if not isinstance(row_id, int) or isinstance(row_id, bool) or row_id < 0:
            raise ValueError("row ID cursor must be a non-negative integer")
        if not isinstance(limit, int) or isinstance(limit, bool) or limit <= 0:
            raise ValueError("limit must be a positive integer")
        with closing(self._open()) as connection:
            rows = connection.execute(
                "SELECT {} FROM messages WHERE id > ? ORDER BY id LIMIT ?".format(
                    ", ".join(_MESSAGE_COLUMNS)
                ),
                (row_id, limit),
            ).fetchall()
        return [(row["id"], self._message(row)) for row in rows]

    def by_event_ids(self, ids):
        if not isinstance(ids, (list, tuple)) or any(
            not isinstance(event_id, str) or not event_id for event_id in ids
        ):
            raise ValueError("event IDs must be non-empty strings")
        if not ids:
            return []
        placeholders = ", ".join("?" for _ in ids)
        with closing(self._open()) as connection:
            rows = connection.execute(
                "SELECT {} FROM messages WHERE event_id IN ({})".format(
                    ", ".join(_MESSAGE_COLUMNS), placeholders
                ),
                tuple(ids),
            ).fetchall()
        by_id = {row["event_id"]: self._message(row) for row in rows}
        return [by_id[event_id] for event_id in ids if event_id in by_id]
