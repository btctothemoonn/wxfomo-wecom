import math
import unittest
from datetime import datetime, timezone

from scripts.wxfomo_lan.scheduler import latest_due_window, latest_due_windows


def utc_timestamp(year, month, day, hour, minute):
    return datetime(year, month, day, hour, minute, tzinfo=timezone.utc).timestamp()


class SchedulerTests(unittest.TestCase):
    def test_midnight_grace_staggers_three_windows(self):
        # This catches a scheduler that applies one grace period to every cadence.
        now = utc_timestamp(2026, 9, 3, 16, 16)
        windows = latest_due_windows(now)
        self.assertEqual(
            [window.cadence for window in windows],
            ["two_hour", "six_hour", "daily"],
        )
        self.assertEqual([window.due_at - window.end for window in windows], [300, 600, 900])

    def test_wake_returns_only_latest_window_per_cadence(self):
        # This catches a backfill loop that emits every missed aligned window.
        windows = latest_due_windows(utc_timestamp(2026, 9, 4, 8, 30))
        self.assertEqual(len(windows), 3)
        self.assertEqual(windows[0].end - windows[0].start, 2 * 3600)
        self.assertEqual(windows[1].end - windows[1].start, 6 * 3600)
        self.assertEqual(windows[2].end - windows[2].start, 24 * 3600)

    def test_windows_are_aligned_to_fixed_utc_plus_eight_boundaries(self):
        # This catches accidentally aligning windows to UTC rather than Beijing time.
        window = latest_due_window("daily", utc_timestamp(2026, 9, 4, 8, 30))
        self.assertEqual(window.start, utc_timestamp(2026, 9, 2, 16, 0))
        self.assertEqual(window.end, utc_timestamp(2026, 9, 3, 16, 0))
        self.assertEqual(window.due_at, utc_timestamp(2026, 9, 3, 16, 15))

    def test_invalid_cadence_and_timestamp_are_rejected(self):
        # This catches accepting inputs that cannot produce a durable window key.
        with self.assertRaises(ValueError):
            latest_due_window("weekly", 0.0)
        for value in (math.inf, -math.inf, math.nan):
            with self.assertRaises(ValueError):
                latest_due_window("daily", value)


if __name__ == "__main__":
    unittest.main()
