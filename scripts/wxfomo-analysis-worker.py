#!/usr/bin/env python3
"""Run the durable local wxFomo analysis worker."""

import argparse
import logging
import math
import os
import signal
import sqlite3
import sys
import threading
import time
import uuid

from wxfomo_lan.analysis_source import MessageSource
from wxfomo_lan.analysis_store import AnalysisStore
from wxfomo_lan.analysis_worker import AnalysisWorker


APPLICATION_SUPPORT = os.path.expanduser("~/Library/Application Support/wxFomo LAN")
DEFAULT_MESSAGE_DATABASE = os.path.join(APPLICATION_SUPPORT, "messages.sqlite3")
DEFAULT_ANALYSIS_DATABASE = os.path.join(APPLICATION_SUPPORT, "analysis.sqlite3")
DEFAULT_CREDENTIALS = os.path.join(APPLICATION_SUPPORT, "ai-credentials.json")


def _uuid(value):
    try:
        parsed = uuid.UUID(value)
    except (AttributeError, TypeError, ValueError):
        raise argparse.ArgumentTypeError("must be a UUID")
    return str(parsed)


def _positive_interval(value):
    try:
        interval = float(value)
    except (TypeError, ValueError):
        raise argparse.ArgumentTypeError("must be a positive finite number")
    if not math.isfinite(interval) or interval <= 0:
        raise argparse.ArgumentTypeError("must be a positive finite number")
    return interval


def _parser():
    parser = argparse.ArgumentParser(description="Run scheduled local message analysis.")
    parser.add_argument(
        "--message-database", default=DEFAULT_MESSAGE_DATABASE, metavar="PATH"
    )
    parser.add_argument(
        "--analysis-database", default=DEFAULT_ANALYSIS_DATABASE, metavar="PATH"
    )
    parser.add_argument("--credentials", default=DEFAULT_CREDENTIALS, metavar="PATH")
    parser.add_argument("--instance-id", required=True, type=_uuid, metavar="UUID")
    parser.add_argument(
        "--poll-interval", default=1.0, type=_positive_interval, metavar="SECONDS"
    )
    parser.add_argument("--once", action="store_true", help=argparse.SUPPRESS)
    return parser


def parse_options(arguments=None):
    return _parser().parse_args(arguments)


def install_signal_handlers(stop_event):
    def request_stop(unused_signum, unused_frame):
        stop_event.set()

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)


def main(arguments=None):
    options = parse_options(arguments)
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    logger = logging.getLogger("wxfomo.analysis.worker")
    stop_event = threading.Event()
    install_signal_handlers(stop_event)
    store = None
    try:
        store = AnalysisStore(options.analysis_database, options.instance_id, time.time)
        worker = AnalysisWorker(
            MessageSource(options.message_database),
            store,
            options.credentials,
            clock=time.time,
            logger=logger,
            stop_event=stop_event,
        )
        if options.once:
            worker.run_once()
        else:
            worker.run_forever(options.poll_interval)
    except (OSError, RuntimeError, ValueError, sqlite3.Error):
        logger.error('{"event":"worker_stopped","error_code":"worker_unavailable"}')
        return 1
    finally:
        if store is not None:
            store.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
