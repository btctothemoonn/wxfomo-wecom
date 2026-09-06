#!/usr/bin/env python3
"""Exercise the real idle listener against empty synthetic databases on macOS."""
import pathlib
import re
import sqlite3
import subprocess
import tempfile
import time


def footprint(pid):
    result = subprocess.run(
        ["/usr/bin/top", "-l", "1", "-pid", str(pid), "-stats", "pid,mem"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
        timeout=10, check=True,
    )
    match = re.search(r"^\s*" + str(pid) + r"\s+([0-9.]+)([BKMGT])", result.stdout, re.M)
    if not match:
        raise AssertionError("test listener has no memory sample")
    return float(match[1]) * 1024 ** "BKMGT".index(match[2])


def main():
    listener = pathlib.Path(__file__).resolve().with_name("wecom-group-listener.swift")
    with tempfile.TemporaryDirectory(prefix="wecom-memory-regression-", dir="/private/tmp") as directory:
        root = pathlib.Path(directory)
        binary = root / "listener"
        subprocess.run(["/usr/bin/swiftc", str(listener), "-o", str(binary)],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90, check=True)
        source = root / "notifications.sqlite3"
        with sqlite3.connect(str(source)) as db:
            db.executescript("""
              CREATE TABLE app(app_id INTEGER PRIMARY KEY,identifier TEXT);
              CREATE TABLE record(rec_id INTEGER PRIMARY KEY,app_id INTEGER,uuid BLOB,
                data BLOB,request_date REAL,request_last_date REAL,delivered_date REAL);
              INSERT INTO app VALUES(1,'com.tencent.WeWorkMac');
            """)
        # Use synthetic environment values only. Re-reading an entire environment
        # on every poll must not retain all those temporary Foundation objects.
        environment = {"PATH": "/usr/bin:/bin"}
        environment.update({"WXFOMO_MEMORY_SYNTHETIC_" + str(i): "synthetic-only-" + "x" * 80
                            for i in range(128)})
        log_path = root / "listener.log"
        with log_path.open("wb") as log:
            process = subprocess.Popen(
                [str(binary), "--database", str(source),
                 "--store", str(root / "messages.sqlite3"), "--config", str(root / "unused-config"),
                 "--group", "synthetic-memory-test", "--poll-interval", "0.05"],
                env=environment, stdout=subprocess.DEVNULL, stderr=log,
            )
            try:
                deadline = time.monotonic() + 30
                while "监听已启动" not in log_path.read_text(errors="replace"):
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise AssertionError("synthetic listener did not become ready: " +
                                             log_path.read_text(errors="replace")[-1500:])
                    time.sleep(0.05)
                time.sleep(2)
                before = footprint(process.pid)
                time.sleep(15)
                assert process.poll() is None, "synthetic listener exited"
                after = footprint(process.pid)
                growth = after - before
                print("idle_15s_footprint: before={:.1f}MiB after={:.1f}MiB growth={:.1f}MiB".format(
                    before / 1048576, after / 1048576, growth / 1048576), flush=True)
                assert growth < 8 * 1048576, "idle polling retains temporary objects"
                with sqlite3.connect(str(root / "messages.sqlite3")) as db:
                    assert db.execute("SELECT COUNT(*) FROM messages").fetchone()[0] == 0
                    heartbeat = db.execute("SELECT heartbeat_at FROM listener_state").fetchone()[0]
                    assert 0 <= time.time() - heartbeat < 5, "idle heartbeat stopped"
                print("PASS bounded idle memory, no synthetic messages, live heartbeat")
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


if __name__ == "__main__":
    main()
