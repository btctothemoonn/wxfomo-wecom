#!/usr/bin/env python3
"""Explicit entry point for the opt-in Signal sync service."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from wxfomo_lan.signal_sync import main


if __name__ == "__main__":
    sys.exit(main())
