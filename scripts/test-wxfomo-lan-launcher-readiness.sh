#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repository_root=${script_dir:h}
fixture_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/wxfomo-launcher-readiness.XXXXXX")
managed_pids=()

cleanup() {
  local pid
  for pid in "${managed_pids[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      kill -CONT "$pid" 2>/dev/null || true
    fi
  done
  for pid in "${managed_pids[@]:-}"; do
    [[ -n "$pid" ]] && wait "$pid" 2>/dev/null || true
  done
  [[ -d "$fixture_dir" ]] && /bin/rm -rf -- "$fixture_dir"
}
trap cleanup EXIT INT TERM

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

random_port() {
  /usr/bin/python3 - <<'PY'
import socket

with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

make_source_database() {
  local path=$1
  /usr/bin/sqlite3 "$path" >/dev/null <<'SQL'
CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR, badge INTEGER NULL);
CREATE TABLE record (
  rec_id INTEGER PRIMARY KEY,
  app_id INTEGER,
  uuid BLOB,
  data BLOB,
  request_date REAL,
  request_last_date REAL,
  delivered_date REAL,
  presented Bool,
  style INTEGER,
  snooze_fire_date REAL
);
INSERT INTO app(app_id, identifier, badge) VALUES(1, 'com.tencent.WeWorkMac', 0);
SQL
}

wait_for_owned_port() {
  local pid=$1
  local port=$2
  local attempt
  for attempt in {1..100}; do
    if /usr/sbin/lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null \
      | /usr/bin/grep -q .; then
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || return 1
    /bin/sleep 0.1
  done
  return 1
}

wait_for_listener_instance() {
  local launcher_pid=$1
  local store=$2
  local attempt
  local instance_id
  for attempt in {1..200}; do
    instance_id=""
    if [[ -f "$store" ]]; then
      instance_id=$(/usr/bin/sqlite3 "file:$store?mode=ro" \
        "SELECT instance_id FROM listener_state WHERE singleton_id=1 AND heartbeat_at >= strftime('%s','now') - 2;" \
        2>/dev/null || true)
    fi
    if [[ "$instance_id" == ????????-????-????-????-???????????? ]]; then
      return 0
    fi
    kill -0 "$launcher_pid" 2>/dev/null || return 1
    /bin/sleep 0.1
  done
  return 1
}

stop_managed_pid() {
  local pid=$1
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    kill -CONT "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  managed_pids=(${managed_pids:#$pid})
}

prepare_common_fixture() {
  local prefix=$1
  source_database="$fixture_dir/$prefix-source.sqlite3"
  message_database="$fixture_dir/$prefix-messages.sqlite3"
  group_config="$fixture_dir/$prefix-groups.txt"
  workspace_database="$fixture_dir/$prefix-missing-workspace.sqlite3"
  configuration="$fixture_dir/$prefix-missing-configuration.json"
  token_directory="$fixture_dir/$prefix-token"
  token_file="$token_directory/access-token"
  launcher_log="$fixture_dir/$prefix-launcher.log"
  make_source_database "$source_database"
  print -r -- "目标群" > "$group_config"
  /bin/chmod 0600 "$group_config"
  /bin/mkdir -m 0700 "$token_directory"
  print -r -- "${prefix}-private-test-token" > "$token_file"
  /bin/chmod 0600 "$token_file"
}

copy_launcher_layout() {
  local target=$1
  /bin/mkdir -m 0700 -p "$target/scripts" "$target/web/wxfomo-lan"
  /bin/cp "$script_dir/start-wxfomo-lan.sh" "$target/scripts/"
  /bin/cp "$script_dir/wecom-group-listener.swift" "$target/scripts/"
  /bin/cp -R "$script_dir/wxfomo_lan" "$target/scripts/"
  /bin/chmod 0700 \
    "$target/scripts/start-wxfomo-lan.sh" \
    "$target/scripts/wecom-group-listener.swift"
}

assert_launcher_does_not_report_ready() {
  local launcher=$1
  local label=$2
  local port=$3
  local launcher_pid
  "$launcher" \
    --notification-database "$source_database" \
    --group-config "$group_config" \
    --message-database "$message_database" \
    --workspace-database "$workspace_database" \
    --configuration "$configuration" \
    --token-file "$token_file" \
    --port "$port" > "$launcher_log" 2>&1 &
  launcher_pid=$!
  managed_pids+=("$launcher_pid")

  wait_for_listener_instance "$launcher_pid" "$message_database" \
    || fail "$label launcher did not establish its listener instance: $(<"$launcher_log")"
  /bin/sleep 3
  kill -0 "$launcher_pid" 2>/dev/null \
    || fail "$label launcher exited instead of supervising the unhealthy server"
  if /usr/bin/grep -Fq -- "wxFomo LAN 已启动" "$launcher_log"; then
    fail "$label launcher reported readiness for an unusable web child"
  fi
  stop_managed_pid "$launcher_pid"
}

case_to_run=${1:-all}
[[ "$case_to_run" == all || "$case_to_run" == foreign || "$case_to_run" == static ]] \
  || fail "unknown readiness test case: $case_to_run"

if [[ "$case_to_run" == all || "$case_to_run" == foreign ]]; then
  prepare_common_fixture foreign
  port=$(random_port)
  foreign_layout="$fixture_dir/foreign-layout"
  copy_launcher_layout "$foreign_layout"
  /bin/cat > "$foreign_layout/scripts/wxfomo-lan-server.py" <<'PY'
import time

time.sleep(30)
PY

  /usr/bin/python3 "$script_dir/wxfomo-lan-server.py" \
    --host 127.0.0.1 \
    --port "$port" \
    --database "$message_database" \
    --group-config "$group_config" \
    --workspace-database "$workspace_database" \
    --configuration "$configuration" \
    --token-file "$token_file" > "$fixture_dir/foreign-owner.log" 2>&1 &
  foreign_owner_pid=$!
  managed_pids+=("$foreign_owner_pid")
  wait_for_owned_port "$foreign_owner_pid" "$port" \
    || fail "foreign fixture server did not bind its port"

  assert_launcher_does_not_report_ready \
    "$foreign_layout/scripts/start-wxfomo-lan.sh" "foreign-port" "$port"
  stop_managed_pid "$foreign_owner_pid"
  print -- "PASS: launcher rejects readiness served by a foreign PID"
fi

if [[ "$case_to_run" == all || "$case_to_run" == static ]]; then
  prepare_common_fixture static
  port=$(random_port)
  static_layout="$fixture_dir/static-layout"
  copy_launcher_layout "$static_layout"
  /bin/cp "$script_dir/wxfomo-lan-server.py" "$static_layout/scripts/"

  assert_launcher_does_not_report_ready \
    "$static_layout/scripts/start-wxfomo-lan.sh" "missing-index" "$port"
  print -- "PASS: launcher requires the workbench index before readiness"
fi
