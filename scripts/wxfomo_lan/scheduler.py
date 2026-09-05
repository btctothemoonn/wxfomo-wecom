"""UTC+08:00-aligned analysis windows."""

import math
from collections import namedtuple


SHANGHAI_OFFSET = 8 * 3600
CADENCES = {
    "two_hour": (2 * 3600, 5 * 60),
    "six_hour": (6 * 3600, 10 * 60),
    "daily": (24 * 3600, 15 * 60),
}
CADENCE_ORDER = ("two_hour", "six_hour", "daily")

AnalysisWindow = namedtuple("AnalysisWindow", ("cadence", "start", "end", "due_at"))


def _timestamp(value):
    if isinstance(value, bool):
        raise ValueError("timestamp must be finite")
    try:
        value = float(value)
    except (TypeError, ValueError):
        raise ValueError("timestamp must be finite")
    if not math.isfinite(value):
        raise ValueError("timestamp must be finite")
    return value


def latest_due_window(cadence, now):
    """Return the newest completed fixed-UTC+08:00 window for *cadence*."""
    try:
        duration, grace = CADENCES[cadence]
    except (KeyError, TypeError):
        raise ValueError("unknown cadence")
    now = _timestamp(now)
    local_now = now + SHANGHAI_OFFSET
    latest_end = int((local_now - grace) // duration) * duration
    end = float(latest_end - SHANGHAI_OFFSET)
    return AnalysisWindow(cadence, end - duration, end, end + grace)


def latest_due_windows(now):
    """Return one latest due window for each cadence in queue priority order."""
    now = _timestamp(now)
    return tuple(latest_due_window(cadence, now) for cadence in CADENCE_ORDER)
