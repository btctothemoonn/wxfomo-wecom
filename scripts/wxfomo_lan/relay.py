"""Opt-in relay attribution for messages inserted after a fixed local boundary."""

import json
import os
import re
import stat
import unicodedata


_PREFIX = re.compile(r"\A[ \t]*([^:\r\n：]{1,80})[:：][ \t]*([\s\S]+)\Z")
_TIME = re.compile(r"\A\s*\d{1,2}[:：]\d{2}(?:\D|$)")
_NON_NAMES = frozenset((
    "http", "https", "ftp", "mailto", "tel", "mc", "lp", "ca",
    "地址", "链", "体重", "血量", "深度", "流动", "池子", "副本",
    "价格", "市值", "流动性", "成交量", "交易量", "涨幅", "跌幅",
    "price", "market cap", "liquidity", "volume", "fdv",
))


def load_boundary(database_path):
    """Missing or malformed activation never changes existing message display."""
    descriptor = None
    try:
        descriptor = os.open(
            os.fspath(database_path) + ".relay.json",
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0),
        )
        information = os.fstat(descriptor)
        if not stat.S_ISREG(information.st_mode) or information.st_size > 4096:
            return None
        with os.fdopen(descriptor, "r", encoding="utf-8") as stream:
            descriptor = None
            value = json.loads(stream.read(4097))
        if not isinstance(value, dict) or value.get("version") != 1:
            return None
        boundary = value.get("afterRowId")
        if isinstance(boundary, bool) or not isinstance(boundary, int) or boundary < 0:
            return None
        return boundary
    except (OSError, ValueError, TypeError):
        return None
    finally:
        if descriptor is not None:
            os.close(descriptor)


def attribute_message(item, row_id, boundary, sender_field):
    """Project exactly one author prefix; never overwrite the listener-owned row."""
    if boundary is None or row_id <= boundary:
        return item
    raw = item.get("content")
    if not isinstance(raw, str) or _TIME.match(raw):
        return item
    matched = _PREFIX.match(raw)
    if matched is None:
        return item
    author = matched.group(1).strip()
    body = matched.group(2)
    if (not author or not body.strip() or author.casefold() in _NON_NAMES
            or any(unicodedata.category(c) in ("Cc", "Cs") for c in author)):
        return item
    return dict(item, **{
        sender_field: author,
        "content": body,
        "relaySender": item.get(sender_field) or "",
        "originalContent": raw,
    })
