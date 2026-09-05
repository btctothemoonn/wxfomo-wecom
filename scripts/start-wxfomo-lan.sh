#!/bin/zsh

set -euo pipefail
zmodload zsh/datetime

script_dir=${0:A:h}
repository_root=${script_dir:h}
listener="$script_dir/wecom-group-listener.swift"
worker="$script_dir/wxfomo-analysis-worker.py"
server="$script_dir/wxfomo-lan-server.py"
user_home=${HOME:-}

[[ -n "$user_home" ]] || {
  print -u2 -- "错误：无法确定当前用户目录"
  exit 2
}

notification_database=""
group_config="$user_home/.config/wxfomo/wecom-groups.txt"
message_database=${WXFOMO_LAN_DATABASE:-"$user_home/Library/Application Support/wxFomo LAN/messages.sqlite3"}
analysis_database="$user_home/Library/Application Support/wxFomo LAN/analysis.sqlite3"
ai_credentials="$user_home/Library/Application Support/wxFomo LAN/ai-credentials.json"
workspace_database=""
configuration=""
token_file="$user_home/Library/Application Support/wxFomo LAN/access-token"
port=8765
allow_lan=0
tls_cert=""
tls_key=""

usage() {
  /bin/cat <<'USAGE'
用法：
  scripts/start-wxfomo-lan.sh [--allow-lan] [选项]

选项：
  --allow-lan                    只绑定检测到的 RFC1918 私网地址（必须显式启用）
  --notification-database PATH  指定 Notification Center 数据库
  --group-config PATH           指定监听群配置
  --message-database PATH       指定私有消息数据库
  --analysis-database PATH      指定私有分析数据库
  --ai-credentials PATH         指定本机 AI 凭据文件
  --workspace-database PATH     旧版兼容参数，精简版不读取
  --configuration PATH          旧版兼容参数，精简版不读取
  --token-file PATH             指定本机访问密码文件（兼容选项名）
  --port PORT                   HTTP(S) 端口；0 表示自动选择（默认 8765）
  --tls-cert PATH               可选 TLS 证书，必须与 --tls-key 同时使用
  --tls-key PATH                可选 TLS 私钥，必须与 --tls-cert 同时使用
USAGE
}

require_value() {
  local option=$1
  local count=$2
  (( count >= 2 )) || {
    print -u2 -- "错误：$option 需要参数"
    exit 2
  }
}

while (( $# > 0 )); do
  case "$1" in
    --allow-lan)
      allow_lan=1
      shift
      ;;
    --notification-database)
      require_value "$1" "$#"
      notification_database=$2
      shift 2
      ;;
    --group-config)
      require_value "$1" "$#"
      group_config=$2
      shift 2
      ;;
    --message-database)
      require_value "$1" "$#"
      message_database=$2
      shift 2
      ;;
    --analysis-database)
      require_value "$1" "$#"
      analysis_database=$2
      shift 2
      ;;
    --ai-credentials)
      require_value "$1" "$#"
      ai_credentials=$2
      shift 2
      ;;
    --workspace-database)
      require_value "$1" "$#"
      workspace_database=$2
      shift 2
      ;;
    --configuration)
      require_value "$1" "$#"
      configuration=$2
      shift 2
      ;;
    --token-file)
      require_value "$1" "$#"
      token_file=$2
      shift 2
      ;;
    --port)
      require_value "$1" "$#"
      port=$2
      shift 2
      ;;
    --tls-cert)
      require_value "$1" "$#"
      tls_cert=$2
      shift 2
      ;;
    --tls-key)
      require_value "$1" "$#"
      tls_key=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      print -u2 -- "错误：未知参数 $1"
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$port" == <0-65535> ]] || {
  print -u2 -- "错误：--port 必须是 0 到 65535 的整数"
  exit 2
}
[[ -x "$listener" && -f "$worker" && -f "$server" \
  && -d "$repository_root/web/wxfomo-lan" ]] || {
  print -u2 -- "错误：项目启动文件不完整"
  exit 2
}
[[ -z "$tls_cert" && -z "$tls_key" || -n "$tls_cert" && -n "$tls_key" ]] || {
  print -u2 -- "错误：--tls-cert 和 --tls-key 必须同时提供"
  exit 2
}

is_private_ipv4() {
  local address=$1
  local first second remainder
  if [[ "$address" == 10.* || "$address" == 192.168.* ]]; then
    return 0
  fi
  if [[ "$address" == 172.* ]]; then
    remainder=${address#172.}
    second=${remainder%%.*}
    [[ "$second" == <16-31> ]] && return 0
  fi
  return 1
}

private_lan_ipv4() {
  local interface address
  interface=$(/sbin/route -n get default 2>/dev/null \
    | /usr/bin/awk '/interface:/{print $2; exit}')
  if [[ -n "$interface" ]]; then
    address=$(/usr/sbin/ipconfig getifaddr "$interface" 2>/dev/null || true)
    if [[ -n "$address" ]] && is_private_ipv4 "$address"; then
      print -r -- "$address"
      return 0
    fi
  fi
  while read -r address; do
    if is_private_ipv4 "$address"; then
      print -r -- "$address"
      return 0
    fi
  done < <(/sbin/ifconfig | /usr/bin/awk '/inet / {print $2}')
  return 1
}

display_host=127.0.0.1
if (( allow_lan == 1 )); then
  display_host=$(private_lan_ipv4) || {
    print -u2 -- "错误：未找到可用的私有局域网 IPv4 地址"
    exit 2
  }
fi
host=$display_host

if ! /usr/bin/python3 - "$script_dir" "$token_file" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from wxfomo_lan.security import ensure_access_token

try:
    ensure_access_token(sys.argv[2])
except (OSError, ValueError):
    raise SystemExit(1)
PY
then
  print -u2 -- "错误：访问密码文件必须是私有、非空的普通文件"
  exit 2
fi

listener_pid=""
worker_pid=""
server_pid=""
listener_instance_id=$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')
[[ "$listener_instance_id" == ????????-????-????-????-???????????? ]] || {
  print -u2 -- "错误：无法生成 listener 实例标识"
  exit 2
}
analysis_instance_id=$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')
[[ "$analysis_instance_id" == ????????-????-????-????-???????????? ]] || {
  print -u2 -- "错误：无法生成 analysis worker 实例标识"
  exit 2
}

cleanup() {
  local listener_to_stop=${listener_pid:-}
  local worker_to_stop=${worker_pid:-}
  local server_to_stop=${server_pid:-}
  listener_pid=""
  worker_pid=""
  server_pid=""
  [[ -n "$listener_to_stop" ]] && kill -TERM "$listener_to_stop" 2>/dev/null || true
  [[ -n "$worker_to_stop" ]] && kill -TERM "$worker_to_stop" 2>/dev/null || true
  [[ -n "$server_to_stop" ]] && kill -TERM "$server_to_stop" 2>/dev/null || true
  [[ -n "$listener_to_stop" ]] && kill -CONT "$listener_to_stop" 2>/dev/null || true
  [[ -n "$worker_to_stop" ]] && kill -CONT "$worker_to_stop" 2>/dev/null || true
  [[ -n "$server_to_stop" ]] && kill -CONT "$server_to_stop" 2>/dev/null || true
  [[ -n "$listener_to_stop" ]] && wait "$listener_to_stop" 2>/dev/null || true
  [[ -n "$worker_to_stop" ]] && wait "$worker_to_stop" 2>/dev/null || true
  [[ -n "$server_to_stop" ]] && wait "$server_to_stop" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

listener_command=(
  /usr/bin/swift "$listener"
  --config "$group_config"
  --store "$message_database"
  --instance-id "$listener_instance_id"
)
if [[ -n "$notification_database" ]]; then
  listener_command+=(--database "$notification_database")
fi

worker_command=(
  /usr/bin/python3 "$worker"
  --message-database "$message_database"
  --analysis-database "$analysis_database"
  --credentials "$ai_credentials"
  --instance-id "$analysis_instance_id"
)

server_command=()
build_server_command() {
  server_command=(
    /usr/bin/python3 "$server"
    --host "$host"
    --port "$port"
    --database "$message_database"
    --analysis-database "$analysis_database"
    --group-config "$group_config"
    --workspace-database "$workspace_database"
    --configuration "$configuration"
    --token-file "$token_file"
  )
  if [[ -n "$notification_database" ]]; then
    server_command+=(--notification-database "$notification_database")
  fi
  if (( allow_lan == 1 )); then
    server_command+=(--allow-lan)
  fi
  if [[ -n "$tls_cert" ]]; then
    server_command+=(--tls-cert "$tls_cert" --tls-key "$tls_key")
  fi
}
build_server_command

"${listener_command[@]}" >/dev/null &
listener_pid=$!

start_worker() {
  "${worker_command[@]}" &
  worker_pid=$!
  worker_healthy_at=0
}

start_server() {
  "${server_command[@]}" &
  server_pid=$!
  server_healthy_at=0
  server_health_check_ticks=0
}

server_is_healthy() {
  local scheme=http
  local owned_port
  owned_port=$(bound_server_port "$server_pid" || true)
  [[ "$owned_port" == "$port" ]] || return 1
  if [[ -n "$tls_cert" ]]; then
    scheme=https
  fi
  /usr/bin/python3 - \
    "$scheme" "$display_host" "$port" "$token_file" "$listener_instance_id" \
    <<'PY' >/dev/null 2>&1
import http.client
import json
import ssl
import sys

scheme, host, raw_port, token_path, expected_instance_id = sys.argv[1:]
with open(token_path, "r", encoding="utf-8") as handle:
    token = handle.read().strip()


def open_connection():
    if scheme == "https":
        return http.client.HTTPSConnection(
            host,
            int(raw_port),
            timeout=1,
            context=ssl._create_unverified_context(),
        )
    return http.client.HTTPConnection(host, int(raw_port), timeout=1)


connection = open_connection()
connection.request(
    "GET",
    "/api/bootstrap",
    headers={"Authorization": "Bearer " + token},
)
response = connection.getresponse()
payload = json.loads(response.read().decode("utf-8"))
connection.close()
if response.status != 200:
    raise SystemExit(1)
source = payload.get("messageSource") or {}
if (
    source.get("available") is not True
    or payload.get("listenerState") != "active"
    or source.get("instanceId") != expected_instance_id
):
    raise SystemExit(1)

connection = open_connection()
connection.request("GET", "/", headers={"Authorization": "Bearer " + token})
response = connection.getresponse()
response.read()
connection.close()
if response.status != 200:
    raise SystemExit(1)
PY
}

analysis_api_is_ready() {
  local scheme=http
  [[ -n "$tls_cert" ]] && scheme=https
  /usr/bin/python3 - "$scheme" "$display_host" "$port" "$token_file" \
    <<'PY' >/dev/null 2>&1
import http.client
import json
import ssl
import sys

scheme, host, raw_port, token_path = sys.argv[1:]
with open(token_path, "r", encoding="utf-8") as handle:
    token = handle.read().strip()
if scheme == "https":
    connection = http.client.HTTPSConnection(
        host,
        int(raw_port),
        timeout=1,
        context=ssl._create_unverified_context(),
    )
else:
    connection = http.client.HTTPConnection(host, int(raw_port), timeout=1)
connection.request(
    "GET",
    "/api/diagnostics",
    headers={"Authorization": "Bearer " + token},
)
response = connection.getresponse()
payload = json.loads(response.read().decode("utf-8"))
connection.close()
worker = payload.get("analysisWorker") or {}
analysis = (payload.get("sources") or {}).get("analysis") or {}
if response.status != 200 or worker.get("active") is not True or analysis.get("available") is not True:
    raise SystemExit(1)
PY
}

worker_is_healthy() {
  /usr/bin/python3 - "$analysis_database" "$analysis_instance_id" <<'PY' >/dev/null 2>&1
import os
import sqlite3
import sys
import time
import urllib.parse

path, expected_instance_id = sys.argv[1:]
uri = "file:{}?mode=ro".format(urllib.parse.quote(os.path.abspath(path)))
connection = sqlite3.connect(uri, uri=True, timeout=0.25)
try:
    row = connection.execute(
        "SELECT instance_id, heartbeat_at FROM analysis_worker_state WHERE singleton_id=1"
    ).fetchone()
finally:
    connection.close()
if row is None or row[0] != expected_instance_id or row[1] is None:
    raise SystemExit(1)
age = time.time() - float(row[1])
if age < -1.0 or age > 15.0:
    raise SystemExit(1)
PY
}

bound_server_port() {
  local pid=$1
  local line endpoint candidate
  while IFS= read -r line; do
    [[ "$line" == n* ]] || continue
    endpoint=${line#n}
    candidate=${endpoint##*:}
    if [[ "$candidate" == <1-65535> ]]; then
      print -r -- "$candidate"
      return 0
    fi
  done < <(/usr/sbin/lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN -Fn 2>/dev/null || true)
  return 1
}

process_is_running() {
  local pid=$1
  local state
  kill -0 "$pid" 2>/dev/null || return 1
  state=$(/bin/ps -o stat= -p "$pid" 2>/dev/null || true)
  [[ -n "$state" && "$state" != Z* ]]
}

sleep_with_listener_guard() {
  local remaining_tenths=$1
  while (( remaining_tenths > 0 )); do
    process_is_running "$listener_pid" || return 1
    /bin/sleep 0.1
    remaining_tenths=$(( remaining_tenths - 1 ))
  done
}

backoffs=(1 2 4 8)
server_backoff_index=1
worker_backoff_index=1
worker_healthy_at=0
server_healthy_at=0
server_health_check_ticks=0
ready=0
start_worker
start_server

while true; do
  process_is_running "$listener_pid" || {
    wait "$listener_pid" 2>/dev/null || true
    listener_pid=""
    print -u2 -- "错误：企业微信通知监听器已退出"
    exit 1
  }

  if process_is_running "$worker_pid"; then
    if (( worker_healthy_at == 0 )) && worker_is_healthy; then
      worker_healthy_at=$EPOCHREALTIME
    fi
  else
    wait "$worker_pid" 2>/dev/null || true
    worker_pid=""
    now=$EPOCHREALTIME
    healthy_uptime=0
    if (( worker_healthy_at > 0 )); then
      healthy_uptime=$(( now - worker_healthy_at ))
    fi
    if (( healthy_uptime >= 30 )); then
      worker_backoff_index=1
    fi
    delay=${backoffs[$worker_backoff_index]}
    (( worker_backoff_index < ${#backoffs[@]} )) && (( worker_backoff_index += 1 ))
    sleep_with_listener_guard $(( delay * 10 )) || {
      print -u2 -- "错误：企业微信通知监听器已退出"
      exit 1
    }
    start_worker
    continue
  fi

  if process_is_running "$server_pid"; then
    if (( port == 0 )); then
      actual_port=$(bound_server_port "$server_pid" || true)
      if [[ "$actual_port" == <1-65535> ]]; then
        port=$actual_port
        build_server_command
      else
        /bin/sleep 0.1
        continue
      fi
    fi
    if (( server_health_check_ticks <= 0 )); then
      server_health_check_ticks=10
      if server_is_healthy; then
        if (( server_healthy_at == 0 )); then
          server_healthy_at=$EPOCHREALTIME
        fi
        if (( ready == 0 )) && worker_is_healthy && analysis_api_is_ready; then
          ready=1
          scheme=http
          [[ -n "$tls_cert" ]] && scheme=https
          print -- "wxFomo LAN 已启动：$scheme://$display_host:$port/"
          print -- "Windows 登录：使用已配置的访问密码"
        fi
      else
        server_healthy_at=0
      fi
    else
      server_health_check_ticks=$(( server_health_check_ticks - 1 ))
    fi
    /bin/sleep 0.1
    continue
  fi

  wait "$server_pid" 2>/dev/null || true
  server_pid=""
  now=$EPOCHREALTIME
  healthy_uptime=0
  if (( server_healthy_at > 0 )); then
    healthy_uptime=$(( now - server_healthy_at ))
  fi
  if (( healthy_uptime >= 30 )); then
    server_backoff_index=1
  fi
  delay=${backoffs[$server_backoff_index]}
  (( server_backoff_index < ${#backoffs[@]} )) && (( server_backoff_index += 1 ))
  sleep_with_listener_guard $(( delay * 10 )) || {
    print -u2 -- "错误：企业微信通知监听器已退出"
    exit 1
  }
  start_server
done
