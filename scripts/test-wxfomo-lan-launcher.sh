#!/bin/zsh

set -euo pipefail
zmodload zsh/datetime

script_dir=${0:A:h}
launcher="$script_dir/start-wxfomo-lan.sh"
fixture_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/wxfomo-lan-launcher-test.XXXXXX")
launcher_pids=()
stopped_child_pids=()

cleanup() {
  local pid
  for pid in "${launcher_pids[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  for pid in "${stopped_child_pids[@]:-}"; do
    [[ -n "$pid" ]] && kill -CONT "$pid" 2>/dev/null || true
  done
  for pid in "${launcher_pids[@]:-}"; do
    [[ -n "$pid" ]] && wait "$pid" 2>/dev/null || true
  done
  if [[ -n "${fixture_dir:-}" && -d "$fixture_dir" ]]; then
    /bin/rm -rf -- "$fixture_dir"
  fi
}
trap cleanup EXIT INT TERM

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

[[ -x "$launcher" ]] || fail "launcher file missing: $launcher"
help_output=$("$launcher" --help)
[[ "$help_output" == *"只绑定检测到的 RFC1918 私网地址"* ]] \
  || fail "launcher help did not describe its specific RFC1918 binding"
[[ "$help_output" != *"绑定所有本机网络接口"* ]] \
  || fail "launcher help still claimed it binds all interfaces"

make_database() {
  local database=$1
  /usr/bin/sqlite3 "$database" >/dev/null <<'SQL'
PRAGMA journal_mode=WAL;
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

payload_hex() {
  local payload="$fixture_dir/payload-$RANDOM.plist"
  /bin/cp "$fixture_dir/payload-template.plist" "$payload"
  /usr/libexec/PlistBuddy -c "Set :req:titl 目标群" "$payload"
  /usr/libexec/PlistBuddy -c "Set :req:subt 测试成员" "$payload"
  /usr/libexec/PlistBuddy -c "Set :req:body LAUNCHER_MESSAGE_BODY_SENTINEL" "$payload"
  /usr/bin/plutil -convert binary1 "$payload"
  /usr/bin/xxd -p -c 1000000 "$payload"
}

insert_notification() {
  local database=$1
  local payload
  payload=$(payload_hex)
  /usr/bin/sqlite3 "$database" \
    "INSERT INTO record(rec_id,app_id,uuid,data,request_date,request_last_date,delivered_date,presented,style) VALUES(41,1,X'0000000000000029',X'$payload',100,100,100,1,1);"
}

random_port() {
  /usr/bin/python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

child_pid() {
  local parent_pid=$1
  local marker=$2
  /bin/ps -axo pid=,ppid=,command= | /usr/bin/awk \
    -v parent="$parent_pid" -v marker="$marker" \
    '$2 == parent && index($0, marker) && !found { print $1; found=1 }'
}

wait_for_log() {
  local pid=$1
  local log=$2
  local expected=$3
  local attempt
  for attempt in {1..300}; do
    if [[ -f "$log" ]] && /usr/bin/grep -Fq -- "$expected" "$log"; then
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || return 1
    /bin/sleep 0.1
  done
  return 1
}

wait_for_child() {
  local parent_pid=$1
  local marker=$2
  local attempt
  local pid
  for attempt in {1..200}; do
    pid=$(child_pid "$parent_pid" "$marker")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      print -- "$pid"
      return 0
    fi
    kill -0 "$parent_pid" 2>/dev/null || return 1
    /bin/sleep 0.1
  done
  return 1
}

wait_for_restarted_child() {
  local launcher_pid=$1
  local previous_pid=$2
  local marker=$3
  local label=$4
  local minimum_seconds=$5
  local maximum_seconds=$6
  local candidate
  local -F 3 started_at=$EPOCHREALTIME
  local -F 3 elapsed=0
  while (( elapsed <= maximum_seconds )); do
    candidate=$(child_pid "$launcher_pid" "$marker")
    if [[ -n "$candidate" && "$candidate" != "$previous_pid" ]] && kill -0 "$candidate" 2>/dev/null; then
      (( elapsed >= minimum_seconds )) \
        || fail "$label restarted too early after ${elapsed}s (minimum ${minimum_seconds}s)"
      restarted_child_pid=$candidate
      return 0
    fi
    kill -0 "$launcher_pid" 2>/dev/null || fail "launcher exited while restarting $label"
    /bin/sleep 0.1
    elapsed=$(( EPOCHREALTIME - started_at ))
  done
  fail "$label did not restart within ${maximum_seconds}s"
}

wait_for_restarted_server() {
  wait_for_restarted_child "$1" "$2" "wxfomo-lan-server.py" "web server" "$3" "$4"
  restarted_server_pid=$restarted_child_pid
}

wait_for_restarted_worker() {
  wait_for_restarted_child "$1" "$2" "wxfomo-analysis-worker.py" "analysis worker" "$3" "$4"
  restarted_worker_pid=$restarted_child_pid
}

wait_for_message() {
  local database=$1
  local attempt
  for attempt in {1..200}; do
    if [[ -f "$database" ]] && \
      [[ "$(/usr/bin/sqlite3 "$database" 'SELECT COUNT(*) FROM messages;' 2>/dev/null || true)" == "1" ]]; then
      return 0
    fi
    /bin/sleep 0.1
  done
  return 1
}

assert_api() {
  local host=$1
  local port=$2
  local token_file=$3
  local expected_count=$4
  WXFOMO_TEST_HOST="$host" WXFOMO_TEST_PORT="$port" WXFOMO_TEST_TOKEN_FILE="$token_file" \
    WXFOMO_TEST_EXPECTED_COUNT="$expected_count" /usr/bin/python3 - <<'PY'
import http.client
import json
import os
import uuid

with open(os.environ["WXFOMO_TEST_TOKEN_FILE"], "r", encoding="utf-8") as handle:
    token = handle.read().strip()
connection = http.client.HTTPConnection(os.environ["WXFOMO_TEST_HOST"], int(os.environ["WXFOMO_TEST_PORT"]), timeout=2)
connection.request("GET", "/api/bootstrap", headers={"Authorization": "Bearer " + token})
response = connection.getresponse()
payload = json.loads(response.read().decode("utf-8"))
assert response.status == 200, response.status
assert payload["readOnly"] is True, payload
assert payload["messageSource"]["available"] is True, payload
assert payload["listenerState"] == "active", payload
uuid.UUID(payload["messageSource"]["instanceId"])
assert payload["counts"]["inbox"] == int(os.environ["WXFOMO_TEST_EXPECTED_COUNT"]), payload
assert payload["groups"] == [
    {"name": "目标群", "count": int(os.environ["WXFOMO_TEST_EXPECTED_COUNT"])}
], payload
connection.close()
PY
}

assert_group_rows() {
  local host=$1
  local port=$2
  local token_file=$3
  local expected_json=$4
  WXFOMO_TEST_HOST="$host" WXFOMO_TEST_PORT="$port" WXFOMO_TEST_TOKEN_FILE="$token_file" \
    WXFOMO_TEST_EXPECTED_GROUPS="$expected_json" /usr/bin/python3 - <<'PY'
import http.client
import json
import os

with open(os.environ["WXFOMO_TEST_TOKEN_FILE"], "r", encoding="utf-8") as handle:
    token = handle.read().strip()
connection = http.client.HTTPConnection(
    os.environ["WXFOMO_TEST_HOST"],
    int(os.environ["WXFOMO_TEST_PORT"]),
    timeout=2,
)
connection.request("GET", "/api/bootstrap", headers={"Authorization": "Bearer " + token})
response = connection.getresponse()
payload = json.loads(response.read().decode("utf-8"))
connection.close()
assert response.status == 200, response.status
assert payload["messageSource"]["available"] is True, payload
assert payload["listenerState"] == "active", payload
assert payload["groups"] == json.loads(os.environ["WXFOMO_TEST_EXPECTED_GROUPS"]), payload
PY
}

assert_analysis_status() {
  local host=$1
  local port=$2
  local token_file=$3
  local expected_configured=$4
  WXFOMO_TEST_HOST="$host" WXFOMO_TEST_PORT="$port" WXFOMO_TEST_TOKEN_FILE="$token_file" \
    WXFOMO_TEST_EXPECTED_CONFIGURED="$expected_configured" /usr/bin/python3 - <<'PY'
import http.client
import json
import os

with open(os.environ["WXFOMO_TEST_TOKEN_FILE"], "r", encoding="utf-8") as handle:
    token = handle.read().strip()

payloads = {}
for path in ("/api/settings/status", "/api/diagnostics", "/api/rules"):
    connection = http.client.HTTPConnection(
        os.environ["WXFOMO_TEST_HOST"],
        int(os.environ["WXFOMO_TEST_PORT"]),
        timeout=2,
    )
    connection.request("GET", path, headers={"Authorization": "Bearer " + token})
    response = connection.getresponse()
    payloads[path] = json.loads(response.read().decode("utf-8"))
    connection.close()
    assert response.status == 200, (path, response.status)

expected = os.environ["WXFOMO_TEST_EXPECTED_CONFIGURED"] == "true"
assert payloads["/api/settings/status"]["aiConfigured"] is expected, payloads
assert payloads["/api/diagnostics"]["analysisWorker"]["active"] is True, payloads
assert payloads["/api/diagnostics"]["sources"]["analysis"]["available"] is True, payloads
assert payloads["/api/rules"]["available"] is True, payloads
PY
}

wait_for_analysis_status() {
  local host=$1
  local port=$2
  local token_file=$3
  local expected_configured=$4
  local attempt
  for attempt in {1..50}; do
    if assert_analysis_status "$host" "$port" "$token_file" "$expected_configured" \
      2>/dev/null; then
      return 0
    fi
    /bin/sleep 0.1
  done
  return 1
}

wait_for_api() {
  local host=$1
  local port=$2
  local token_file=$3
  local expected_count=$4
  local attempt
  for attempt in {1..50}; do
    if assert_api "$host" "$port" "$token_file" "$expected_count" 2>/dev/null; then
      return 0
    fi
    /bin/sleep 0.1
  done
  return 1
}

wait_for_continuous_api_health() {
  local host=$1
  local port=$2
  local token_file=$3
  local expected_count=$4
  local minimum_seconds=$5
  local maximum_seconds=$6
  local -F 3 started_at=$EPOCHREALTIME
  local -F 3 elapsed=0
  while (( elapsed < minimum_seconds )); do
    assert_api "$host" "$port" "$token_file" "$expected_count" \
      || return 1
    elapsed=$(( EPOCHREALTIME - started_at ))
    (( elapsed <= maximum_seconds )) || return 1
    /bin/sleep 0.2
    elapsed=$(( EPOCHREALTIME - started_at ))
  done
  (( elapsed <= maximum_seconds ))
}

wait_until_exited() {
  local pid=$1
  local attempt
  for attempt in {1..100}; do
    kill -0 "$pid" 2>/dev/null || return 0
    /bin/sleep 0.1
  done
  return 1
}

assert_invalid_token_rejected() {
  local case_name=$1
  local token_path=$2
  local source_path="$fixture_dir/$case_name-source.sqlite3"
  local store_path="$fixture_dir/$case_name-messages.sqlite3"
  local log_path="$fixture_dir/$case_name-launcher.log"
  local case_port
  local case_pid
  local case_exit=0
  case_port=$(random_port)
  make_database "$source_path"

  "$launcher" \
    --notification-database "$source_path" \
    --group-config "$group_config" \
    --message-database "$store_path" \
    --workspace-database "$workspace_database" \
    --configuration "$configuration" \
    --token-file "$token_path" \
    --port "$case_port" \
    --allow-lan > "$log_path" 2>&1 &
  case_pid=$!
  launcher_pids+=("$case_pid")
  if ! wait_until_exited "$case_pid"; then
    fail "launcher accepted $case_name token path"
  fi
  wait "$case_pid" || case_exit=$?
  launcher_pids=(${launcher_pids:#$case_pid})
  (( case_exit != 0 )) || fail "launcher succeeded with $case_name token path"
  [[ "$(<"$log_path")" != *"LAUNCHER_MESSAGE_BODY_SENTINEL"* ]] \
    || fail "invalid-token launcher printed a message body"
}

/bin/cat > "$fixture_dir/payload-template.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>req</key><dict>
<key>titl</key><string>TITLE_VALUE</string>
<key>subt</key><string>SUBTITLE_VALUE</string>
<key>body</key><string>BODY_VALUE</string>
<key>usda</key><data>YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGlCwwVFhdVJG51bGzTDQ4PEBIUV05TLmtleXNaTlMub2JqZWN0c1YkY2xhc3OhEYACoROAA4AEUmN0EAHSGBkaG1okY2xhc3NuYW1lWCRjbGFzc2VzXE5TRGljdGlvbmFyeaIaHFhOU09iamVjdAgRGiQpMjdJTFFTWV9mbnmAgoSGiIqNj5SfqLW4AAAAAAAAAQEAAAAAAAAAHQAAAAAAAAAAAAAAAAAAAME=</data>
</dict></dict></plist>
PLIST

source_database="$fixture_dir/source.sqlite3"
group_config="$fixture_dir/groups.txt"
message_database="$fixture_dir/messages.sqlite3"
analysis_database="$fixture_dir/analysis.sqlite3"
ai_credentials="$fixture_dir/missing-ai-credentials.json"
workspace_database="$fixture_dir/missing-workspace.sqlite3"
configuration="$fixture_dir/missing-configuration.json"
token_file="$fixture_dir/private/access-token"
launcher_log="$fixture_dir/launcher.log"
port=0
make_database "$source_database"
print -r -- "目标群" > "$group_config"
/bin/chmod 0600 "$group_config"

/bin/mkdir -m 0755 "$fixture_dir/shared-valid"
print -r -- "SHARED_VALID_TOKEN_SENTINEL" > "$fixture_dir/shared-valid/access-token"
/bin/chmod 0644 "$fixture_dir/shared-valid/access-token"
assert_invalid_token_rejected "shared-valid" "$fixture_dir/shared-valid/access-token"
[[ "$(/usr/bin/stat -f '%Lp' "$fixture_dir/shared-valid")" == "755" ]] \
  || fail "launcher changed a shared valid-token parent"
[[ "$(/usr/bin/stat -f '%Lp' "$fixture_dir/shared-valid/access-token")" == "644" ]] \
  || fail "launcher changed a token after rejecting its shared parent"

/bin/mkdir -m 0755 "$fixture_dir/empty-private"
: > "$fixture_dir/empty-private/access-token"
/bin/chmod 0644 "$fixture_dir/empty-private/access-token"
assert_invalid_token_rejected "empty" "$fixture_dir/empty-private/access-token"
[[ "$(/usr/bin/stat -f '%Lp' "$fixture_dir/empty-private")" == "755" ]] \
  || fail "launcher changed a shared empty-token parent"
[[ "$(/usr/bin/stat -f '%Lp' "$fixture_dir/empty-private/access-token")" == "644" ]] \
  || fail "launcher changed an empty token before rejecting it"

symlink_target="$fixture_dir/uncontrolled-token-target"
print -r -- "UNCONTROLLED_TOKEN_SENTINEL" > "$symlink_target"
/bin/chmod 0644 "$symlink_target"
/bin/mkdir -m 0755 "$fixture_dir/symlink-private"
/bin/ln -s "$symlink_target" "$fixture_dir/symlink-private/access-token"
assert_invalid_token_rejected "symlink" "$fixture_dir/symlink-private/access-token"
[[ "$(<"$symlink_target")" == "UNCONTROLLED_TOKEN_SENTINEL" ]] \
  || fail "launcher changed a symlink target"
[[ "$(/usr/bin/stat -f '%Lp' "$symlink_target")" == "644" ]] \
  || fail "launcher changed symlink-target permissions"
[[ "$(/usr/bin/stat -f '%Lp' "$fixture_dir/symlink-private")" == "755" ]] \
  || fail "launcher changed a shared symlink-token parent"
[[ "$(<"$fixture_dir/symlink-launcher.log")" != *"UNCONTROLLED_TOKEN_SENTINEL"* ]] \
  || fail "invalid-token launcher printed a symlink-target token"

/bin/mkdir -m 0700 "${token_file:h}"
print -r -- "EXISTING_SAFE_TOKEN_SENTINEL" > "$token_file"
/bin/chmod 0644 "$token_file"

"$script_dir/wecom-group-listener.swift" \
  --database "$source_database" \
  --config "$group_config" \
  --store "$message_database" \
  --once --timeout 0.2 --poll-interval 0.05 >/dev/null 2>&1 || true
old_listener_instance_id=$(/usr/bin/sqlite3 "$message_database" \
  "SELECT instance_id FROM listener_state WHERE singleton_id=1 AND strftime('%s','now') - heartbeat_at <= 1;")
[[ "$old_listener_instance_id" == ????????-????-????-????-???????????? ]] \
  || fail "could not seed a current previous-launcher heartbeat"

/usr/bin/env \
  http_proxy=http://127.0.0.1:1 \
  https_proxy=http://127.0.0.1:1 \
  ALL_PROXY=http://127.0.0.1:1 \
  HTTP_PROXY=http://127.0.0.1:1 \
  HTTPS_PROXY=http://127.0.0.1:1 \
  NO_PROXY= \
  no_proxy= \
  "$launcher" \
  --notification-database "$source_database" \
  --group-config "$group_config" \
  --message-database "$message_database" \
  --analysis-database "$analysis_database" \
  --ai-credentials "$ai_credentials" \
  --workspace-database "$workspace_database" \
  --configuration "$configuration" \
  --token-file "$token_file" \
  --port "$port" \
  --allow-lan > "$launcher_log" 2>&1 &
launcher_pid=$!
launcher_pids+=("$launcher_pid")

wait_for_log "$launcher_pid" "$launcher_log" "wxFomo LAN 已启动" \
  || fail "launcher did not report readiness: $(<"$launcher_log")"
wait_for_log "$launcher_pid" "$launcher_log" "监听已启动" \
  || fail "listener did not report readiness: $(<"$launcher_log")"
[[ "$(<"$launcher_log")" == *"使用已配置的访问密码"* ]] \
  || fail "launcher did not direct the user to the configured password"
[[ "$(<"$launcher_log")" != *"访问令牌文件"* ]] \
  || fail "launcher still required the user to retrieve a token file"
listener_ready_line=$(/usr/bin/grep -n -m 1 -- "监听已启动" "$launcher_log" | /usr/bin/cut -d: -f1)
launcher_ready_line=$(/usr/bin/grep -n -m 1 -- "wxFomo LAN 已启动" "$launcher_log" | /usr/bin/cut -d: -f1)
(( listener_ready_line < launcher_ready_line )) \
  || fail "launcher accepted a previous instance's fresh heartbeat before current readiness"
current_listener_instance_id=$(/usr/bin/sqlite3 "$message_database" \
  'SELECT instance_id FROM listener_state WHERE singleton_id=1;')
[[ "$current_listener_instance_id" == ????????-????-????-????-???????????? \
  && "$current_listener_instance_id" != "$old_listener_instance_id" ]] \
  || fail "launcher did not replace the previous listener instance before readiness"
lan_host=$(/usr/bin/sed -nE 's#.*https?://([0-9.]+):[0-9]+/.*#\1#p' "$launcher_log" \
  | /usr/bin/awk 'NR == 1 { first=$0 } END { print first }')
port=$(/usr/bin/sed -nE 's#.*https?://[0-9.]+:([0-9]+)/.*#\1#p' "$launcher_log" \
  | /usr/bin/awk 'NR == 1 { first=$0 } END { print first }')
[[ "$lan_host" == 10.* || "$lan_host" == 192.168.* || "$lan_host" == 172.<16-31>.* ]] \
  || fail "launcher did not print an RFC1918 LAN host"
[[ "$port" == <1-65535> ]] || fail "launcher did not print its actual auto-selected port"
[[ -s "$token_file" ]] || fail "launcher did not create the token file"
token=$(<"$token_file")
[[ "$token" == "EXISTING_SAFE_TOKEN_SENTINEL" ]] || fail "launcher did not reuse the existing token"
[[ "$(/usr/bin/stat -f '%Lp' "${token_file:h}")" == "700" ]] \
  || fail "launcher changed the private token directory"
[[ "$(/usr/bin/stat -f '%Lp' "$token_file")" == "600" ]] \
  || fail "launcher did not tighten the token file"
[[ "$(<"$launcher_log")" != *"$token"* ]] || fail "launcher printed the access token"

listener_pid=$(wait_for_child "$launcher_pid" "wecom-group-listener.swift") \
  || fail "listener child was not running"
worker_pid=$(wait_for_child "$launcher_pid" "wxfomo-analysis-worker.py") \
  || fail "analysis worker did not start"
kill -0 "$worker_pid" 2>/dev/null || fail "analysis worker is not running"
server_pid=$(wait_for_child "$launcher_pid" "wxfomo-lan-server.py") \
  || fail "web server child was not running"
worker_command=$(/bin/ps -o command= -p "$worker_pid")
[[ "$worker_command" == *"--message-database $message_database"* ]] \
  || fail "analysis worker did not receive the custom message database"
[[ "$worker_command" == *"--analysis-database $analysis_database"* ]] \
  || fail "analysis worker did not receive the custom analysis database"
[[ "$worker_command" == *"--credentials $ai_credentials"* ]] \
  || fail "analysis worker did not receive the custom credentials path"
server_command=$(/bin/ps -o command= -p "$server_pid")
[[ "$server_command" == *"--host $lan_host"* ]] \
  || fail "web server did not bind the printed private LAN host"
[[ "$server_command" != *"--host 0.0.0.0"* ]] \
  || fail "web server bound all IPv4 interfaces"
[[ "$server_command" == *"--group-config $group_config"* ]] \
  || fail "web server did not receive the listener's custom group config"
[[ "$server_command" == *"--notification-database $source_database"* ]] \
  || fail "web server did not receive the listener's notification database for safety validation"
[[ "$server_command" == *"--analysis-database $analysis_database"* ]] \
  || fail "web server did not receive the analysis database"
assert_api "$lan_host" "$port" "$token_file" 0 || fail "bootstrap was unavailable"
assert_analysis_status "$lan_host" "$port" "$token_file" "false" \
  || fail "analysis and rules were unavailable without AI credentials"

insert_notification "$source_database"
wait_for_message "$message_database" || fail "listener did not store the new fixture message"
assert_api "$lan_host" "$port" "$token_file" 1 || fail "stored message was not visible through bootstrap"
assert_analysis_status "$lan_host" "$port" "$token_file" "false" \
  || fail "raw message monitoring or rules failed while AI was unconfigured"
[[ "$(<"$launcher_log")" != *"LAUNCHER_MESSAGE_BODY_SENTINEL"* ]] \
  || fail "launcher printed a message body"

print -r -- "新配置群" > "$group_config"
/bin/chmod 0600 "$group_config"
assert_group_rows \
  "$lan_host" "$port" "$token_file" \
  '[{"name":"目标群","count":1}]' \
  || fail "running launcher abandoned the listener group snapshot after config edit"

local_minimum_seconds=(0.7 1.7 3.7 7.7)
local_maximum_seconds=(3 5 7 12)
local_index=1
for local_index in {1..4}; do
  kill -TERM "$server_pid" || fail "could not stop exact web server PID $server_pid"
  wait_for_restarted_server \
    "$launcher_pid" "$server_pid" \
    "$local_minimum_seconds[$local_index]" "$local_maximum_seconds[$local_index]"
  server_pid=$restarted_server_pid
  if (( local_index == 1 )); then
    server_command=$(/bin/ps -o command= -p "$server_pid")
    [[ "$server_command" == *"--port $port"* ]] \
      || fail "restarted web server did not keep the printed auto-selected port"
  fi
  kill -0 "$listener_pid" 2>/dev/null || fail "listener stopped during web server restart"
  wait_for_api "$lan_host" "$port" "$token_file" 1 || fail "bootstrap failed after web server restart"
done

local_index=1
for local_index in {1..4}; do
  kill -TERM "$worker_pid" || fail "could not stop exact analysis worker PID $worker_pid"
  wait_for_restarted_worker \
    "$launcher_pid" "$worker_pid" \
    "$local_minimum_seconds[$local_index]" "$local_maximum_seconds[$local_index]"
  worker_pid=$restarted_worker_pid
  kill -0 "$listener_pid" 2>/dev/null || fail "listener stopped during analysis worker restart"
  kill -0 "$server_pid" 2>/dev/null || fail "web server stopped during analysis worker restart"
  wait_for_analysis_status "$lan_host" "$port" "$token_file" "false" \
    || fail "analysis status did not recover after worker restart"
done

/bin/sleep 2
kill -STOP "$server_pid" || fail "could not pause exact web server PID $server_pid"
stopped_child_pids+=("$server_pid")
/bin/sleep 31
kill -CONT "$server_pid" || fail "could not resume exact web server PID $server_pid"
stopped_child_pids=(${stopped_child_pids:#$server_pid})
wait_for_api "$lan_host" "$port" "$token_file" 1 \
  || fail "bootstrap did not recover after exact web server resume"
kill -TERM "$server_pid" || fail "could not stop web server after interrupted health window"
wait_for_restarted_server "$launcher_pid" "$server_pid" 7.7 12
server_pid=$restarted_server_pid
wait_for_api "$lan_host" "$port" "$token_file" 1 \
  || fail "bootstrap failed after interrupted-health restart"
wait_for_continuous_api_health "$lan_host" "$port" "$token_file" 1 32 35 \
  || fail "bootstrap was not continuously healthy before the backoff-reset check"
kill -TERM "$server_pid" || fail "could not stop healthy web server PID $server_pid"
wait_for_restarted_server "$launcher_pid" "$server_pid" 0.7 3
server_pid=$restarted_server_pid
wait_for_api "$lan_host" "$port" "$token_file" 1 || fail "bootstrap failed after healthy backoff reset"

/bin/kill -STOP "$server_pid" || fail "could not pause web server for shutdown cleanup"
stopped_child_pids+=("$server_pid")
/bin/kill -STOP "$worker_pid" || fail "could not pause analysis worker for shutdown cleanup"
stopped_child_pids+=("$worker_pid")
kill -TERM "$launcher_pid" || fail "could not stop launcher with a paused web server"
wait_until_exited "$launcher_pid" \
  || fail "launcher cleanup hung on a paused exact web server PID"
wait "$launcher_pid" 2>/dev/null || true
launcher_pids=(${launcher_pids:#$launcher_pid})
wait_until_exited "$listener_pid" || fail "listener child survived launcher shutdown"
wait_until_exited "$worker_pid" || fail "analysis worker child survived launcher shutdown"
wait_until_exited "$server_pid" || fail "web server child survived launcher shutdown"
stopped_child_pids=(${stopped_child_pids:#$server_pid})
stopped_child_pids=(${stopped_child_pids:#$worker_pid})
[[ "$(<"$launcher_log")" != *"$token"* ]] || fail "complete launcher log contained the access token"
[[ "$(<"$launcher_log")" != *"LAUNCHER_MESSAGE_BODY_SENTINEL"* ]] \
  || fail "complete launcher log contained a message body"

failure_source="$fixture_dir/failure-source.sqlite3"
failure_store="$fixture_dir/failure-messages.sqlite3"
failure_analysis="$fixture_dir/failure-analysis.sqlite3"
failure_credentials="$fixture_dir/failure-missing-credentials.json"
failure_token="$fixture_dir/failure-private/access-token"
failure_log="$fixture_dir/failure-launcher.log"
failure_port=0
make_database "$failure_source"

"$launcher" \
  --notification-database "$failure_source" \
  --group-config "$group_config" \
  --message-database "$failure_store" \
  --analysis-database "$failure_analysis" \
  --ai-credentials "$failure_credentials" \
  --workspace-database "$workspace_database" \
  --configuration "$configuration" \
  --token-file "$failure_token" \
  --port "$failure_port" \
  --allow-lan > "$failure_log" 2>&1 &
failure_launcher_pid=$!
launcher_pids+=("$failure_launcher_pid")
wait_for_log "$failure_launcher_pid" "$failure_log" "wxFomo LAN 已启动" \
  || fail "failure-path launcher did not report readiness"
[[ "$(/usr/bin/stat -f '%Lp' "${failure_token:h}")" == "700" ]] \
  || fail "launcher did not create a dedicated token directory as 0700"
[[ "$(/usr/bin/stat -f '%Lp' "$failure_token")" == "600" ]] \
  || fail "launcher did not create a dedicated token file as 0600"
failure_listener_pid=$(wait_for_child "$failure_launcher_pid" "wecom-group-listener.swift") \
  || fail "failure-path listener child was not running"
failure_worker_pid=$(wait_for_child "$failure_launcher_pid" "wxfomo-analysis-worker.py") \
  || fail "failure-path analysis worker child was not running"
failure_server_pid=$(wait_for_child "$failure_launcher_pid" "wxfomo-lan-server.py") \
  || fail "failure-path web server child was not running"
failure_host=$(/usr/bin/sed -nE 's#.*https?://([0-9.]+):[0-9]+/.*#\1#p' "$failure_log" \
  | /usr/bin/awk 'NR == 1 { first=$0 } END { print first }')
failure_port=$(/usr/bin/sed -nE 's#.*https?://[0-9.]+:([0-9]+)/.*#\1#p' "$failure_log" \
  | /usr/bin/awk 'NR == 1 { first=$0 } END { print first }')
assert_group_rows \
  "$failure_host" "$failure_port" "$failure_token" \
  '[{"name":"新配置群","count":0}]' \
  || fail "whole-launcher restart did not adopt the edited group config snapshot"
kill -TERM "$failure_listener_pid" || fail "could not stop exact listener PID $failure_listener_pid"
wait_until_exited "$failure_launcher_pid" || fail "launcher stayed alive after listener exit"
local_exit=0
wait "$failure_launcher_pid" || local_exit=$?
(( local_exit != 0 )) || fail "launcher succeeded after listener exit"
launcher_pids=(${launcher_pids:#$failure_launcher_pid})
wait_until_exited "$failure_server_pid" || fail "web server survived listener failure"
wait_until_exited "$failure_worker_pid" || fail "analysis worker survived listener failure"

print -- "PASS: wxFomo LAN launcher supervision"
