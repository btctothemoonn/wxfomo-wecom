#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
probe="$script_dir/wecom-notification-probe.swift"
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/wxfomo-wecom-probe-test.XXXXXX")
trap 'rm -rf "$fixture_dir"' EXIT

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

require_contains() {
  local output=$1
  local expected=$2
  [[ "$output" == *"$expected"* ]] || fail "missing output: $expected"
}

require_absent() {
  local output=$1
  local forbidden=$2
  [[ "$output" != *"$forbidden"* ]] || fail "plaintext leaked: $forbidden"
}

wait_for_file_text() {
  local file=$1
  local expected=$2
  local process_id=$3
  local attempt
  for attempt in {1..200}; do
    [[ -f "$file" ]] && rg -q --fixed-strings "$expected" "$file" && return 0
    kill -0 "$process_id" 2>/dev/null || return 1
    sleep 0.02
  done
  return 1
}

make_payload() {
  local payload="$fixture_dir/payload.plist"

  /bin/cat > "$payload" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>req</key>
  <dict>
    <key>titl</key>
    <string>TEST_GROUP_PRIVATE</string>
    <key>subt</key>
    <string>TEST_SENDER_PRIVATE</string>
    <key>body</key>
    <string>TEST_BODY_PRIVATE</string>
    <key>iden</key>
    <string>synthetic-notification</string>
    <key>atta</key>
    <array>
      <dict>
        <key>fileURL</key>
        <string>file:///Users/TEST_ATTACHMENT_PRIVATE/secret-image.png</string>
        <key>type</key>
        <string>public.png</string>
      </dict>
    </array>
  </dict>
</dict>
</plist>
PLIST
  plutil -convert binary1 "$payload"
  print -r -- "$payload"
}

make_large_payload() {
  local payload="$fixture_dir/large-payload.plist"
  {
    print -r -- '<?xml version="1.0" encoding="UTF-8"?>'
    print -r -- '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    print -r -- '<plist version="1.0"><dict><key>req</key><dict>'
    print -r -- '<key>titl</key><string>TEST_GROUP_PRIVATE</string>'
    print -r -- '<key>subt</key><string>TEST_SENDER_PRIVATE</string>'
    print -nr -- '<key>body</key><string>'
    dd if=/dev/zero bs=262144 count=1 2>/dev/null | tr '\0' X
    print -r -- '</string></dict></dict></plist>'
  } > "$payload"
  plutil -convert binary1 "$payload"
  print -r -- "$payload"
}

make_empty_database() {
  local database=$1
  sqlite3 "$database" <<'SQL'
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
INSERT INTO app(app_id, identifier, badge)
VALUES(1, 'com.tencent.WeWorkMac', 0);
SQL
}

insert_fixture_notification() {
  local database=$1
  local record_id=${2:-42}
  local payload
  payload=$(make_payload)
  local payload_hex
  payload_hex=$(xxd -p -c 1000000 "$payload")

  sqlite3 "$database" <<SQL
INSERT INTO record(rec_id, app_id, uuid, data, delivered_date, presented, style)
VALUES($record_id, 1, X'01020304', X'$payload_hex', 812345678, 1, 1);
SQL
}

make_fixture_database() {
  local database=$1
  make_empty_database "$database"
  insert_fixture_notification "$database"
}

test_reports_structure_without_plaintext() {
  local database="$fixture_dir/notifications.db"
  make_fixture_database "$database"

  local output
  output=$(swift "$probe" \
    --database "$database" \
    --include-existing \
    --once \
    --non-interactive 2>&1) || fail "probe command failed: $output"

  require_contains "$output" "source.identifier=com.tencent.WeWorkMac"
  require_contains "$output" "payload.top_level_keys=req"
  require_contains "$output" "payload.request_keys=atta,body,iden,subt,titl"
  require_contains "$output" "payload.title.type=string length=18"
  require_contains "$output" "payload.subtitle.type=string length=19"
  require_contains "$output" "payload.body.type=string length=17"
  require_contains "$output" "payload.attachments.count=1"
  require_contains "$output" "payload.attachments.kinds=image"
  require_absent "$output" "TEST_GROUP_PRIVATE"
  require_absent "$output" "TEST_SENDER_PRIVATE"
  require_absent "$output" "TEST_BODY_PRIVATE"
  require_absent "$output" "TEST_ATTACHMENT_PRIVATE"
}

test_handles_payload_larger_than_process_pipe_capacity() {
  local database="$fixture_dir/large-notifications.db"
  local output_file="$fixture_dir/large-output.txt"
  make_empty_database "$database"
  local payload=$(make_large_payload)
  local payload_hex=$(xxd -p -c 1000000 "$payload")
  sqlite3 "$database" <<SQL
INSERT INTO record(rec_id, app_id, uuid, data, delivered_date, presented, style)
VALUES(42, 1, X'01020304', X'$payload_hex', 812345678, 1, 1);
SQL

  swift "$probe" \
    --database "$database" \
    --include-existing \
    --once \
    --non-interactive > "$output_file" 2>&1 &
  local probe_pid=$!
  local finished=0
  local attempt
  for attempt in {1..100}; do
    if ! kill -0 "$probe_pid" 2>/dev/null; then
      finished=1
      break
    fi
    sleep 0.05
  done
  if (( finished == 0 )); then
    kill "$probe_pid" 2>/dev/null || true
    wait "$probe_pid" 2>/dev/null || true
    fail "probe deadlocked while reading a payload larger than its process pipe"
  fi

  local exit_code=0
  wait "$probe_pid" || exit_code=$?
  local output=$(<"$output_file")
  (( exit_code == 0 )) || fail "large-payload probe command failed: $output"
  require_contains "$output" "payload.body.type=string length=262144"
  require_absent "$output" "TEST_GROUP_PRIVATE"
  require_absent "$output" "TEST_SENDER_PRIVATE"
}

test_handles_attachment_keys_that_differ_only_by_case() {
  local database="$fixture_dir/case-collision-notifications.db"
  make_empty_database "$database"
  local payload=$(make_payload)
  /usr/libexec/PlistBuddy -c \
    "Add :req:atta:0:URL string file:///Users/TEST_ATTACHMENT_PRIVATE/secret-image.png" "$payload"
  /usr/libexec/PlistBuddy -c \
    "Add :req:atta:0:url string file:///Users/TEST_ATTACHMENT_PRIVATE/secret-image.png" "$payload"
  local payload_hex=$(xxd -p -c 1000000 "$payload")
  sqlite3 "$database" <<SQL
INSERT INTO record(rec_id, app_id, uuid, data, delivered_date, presented, style)
VALUES(42, 1, X'01020304', X'$payload_hex', 812345678, 1, 1);
SQL

  local output
  output=$(swift "$probe" \
    --database "$database" \
    --include-existing \
    --once \
    --non-interactive 2>&1) || fail "case-collision probe command failed: $output"

  require_contains "$output" "payload.attachments.count=1"
  require_contains "$output" "payload.attachments.kinds=image"
  require_absent "$output" "TEST_ATTACHMENT_PRIVATE"
}

test_matches_expected_values_without_echoing_them() {
  local database="$fixture_dir/interactive-notifications.db"
  make_fixture_database "$database"

  local output
  output=$(printf '%s\n' \
    'TEST_GROUP_PRIVATE' \
    'TEST_SENDER_PRIVATE' \
    'TEST_BODY_PRIVATE' | swift "$probe" \
      --database "$database" \
      --include-existing \
      --once \
      --interactive 2>&1) || fail "interactive probe command failed: $output"

  require_contains "$output" "match.group=title"
  require_contains "$output" "match.sender=subtitle"
  require_contains "$output" "match.body=body"
  require_absent "$output" "TEST_GROUP_PRIVATE"
  require_absent "$output" "TEST_SENDER_PRIVATE"
  require_absent "$output" "TEST_BODY_PRIVATE"
}

test_disables_echo_for_interactive_terminal_input() {
  local database="$fixture_dir/tty-interactive-notifications.db"
  local executable="$fixture_dir/wecom-notification-probe"
  local transcript="$fixture_dir/tty-transcript.txt"
  local input_pipe="$fixture_dir/tty-input.pipe"
  make_fixture_database "$database"
  swiftc "$probe" -o "$executable"
  mkfifo "$input_pipe"

  script -q -t 0 "$transcript" "$executable" \
    --database "$database" \
    --include-existing \
    --once \
    --interactive < "$input_pipe" >/dev/null 2>&1 &
  local script_pid=$!
  exec 8>"$input_pipe"
  wait_for_file_text "$transcript" "请输入测试群名" "$script_pid" \
    || fail "pseudo-terminal probe did not request the group name"
  print -u8 -- 'TEST_GROUP_PRIVATE'
  wait_for_file_text "$transcript" "请输入测试发送者" "$script_pid" \
    || fail "pseudo-terminal probe did not request the sender"
  print -u8 -- 'TEST_SENDER_PRIVATE'
  wait_for_file_text "$transcript" "请输入测试正文" "$script_pid" \
    || fail "pseudo-terminal probe did not request the body"
  print -u8 -- 'TEST_BODY_PRIVATE'
  exec 8>&-
  wait "$script_pid" || fail "pseudo-terminal probe command failed"

  local output=$(<"$transcript")
  require_contains "$output" "match.group=title"
  require_contains "$output" "match.sender=subtitle"
  require_contains "$output" "match.body=body"
  require_absent "$output" "TEST_GROUP_PRIVATE"
  require_absent "$output" "TEST_SENDER_PRIVATE"
  require_absent "$output" "TEST_BODY_PRIVATE"
}

test_restores_terminal_echo_when_interrupted() {
  local database="$fixture_dir/interrupted-tty-notifications.db"
  local executable="$fixture_dir/interrupted-tty-probe"
  local transcript="$fixture_dir/interrupted-tty-transcript.txt"
  local input_pipe="$fixture_dir/interrupted-tty-input.pipe"
  make_fixture_database "$database"
  swiftc "$probe" -o "$executable"
  mkfifo "$input_pipe"

  script -q -t 0 "$transcript" "$executable" \
    --database "$database" \
    --include-existing \
    --once \
    --interactive < "$input_pipe" >/dev/null 2>&1 &
  local script_pid=$!
  exec 6>"$input_pipe"
  wait_for_file_text "$transcript" "请输入测试群名" "$script_pid" \
    || fail "interrupt test probe did not reach hidden terminal input"
  local probe_pid=$(pgrep -P "$script_pid" | head -1)
  [[ -n "$probe_pid" ]] || fail "interrupt test could not identify the probe process"
  local tty_name=$(ps -o tty= -p "$probe_pid" | tr -d ' ')
  local tty_device="/dev/$tty_name"
  [[ -c "$tty_device" ]] || fail "interrupt test could not identify the pseudo-terminal"
  local hidden_settings=$(stty -a -f "$tty_device")
  [[ " $hidden_settings " == *" -echo "* ]] \
    || fail "probe did not disable echo before the interrupt test"
  kill -STOP "$script_pid"
  kill -INT "$probe_pid"
  sleep 0.1
  local restored_settings=$(stty -a -f "$tty_device")
  kill -CONT "$script_pid"
  exec 6>&-
  wait "$script_pid" || true

  [[ " $restored_settings " != *" -echo "* ]] \
    || fail "terminal echo settings were not restored after SIGINT"
  local output=$(<"$transcript")
  require_absent "$output" "TEST_GROUP_PRIVATE"
  require_absent "$output" "TEST_SENDER_PRIVATE"
  require_absent "$output" "TEST_BODY_PRIVATE"
}

test_auto_detects_group_container_database() {
  local fake_home="$fixture_dir/fake-home"
  local database="$fake_home/Library/Group Containers/group.com.apple.usernoted/db2/db"
  mkdir -p "${database:h}"
  make_fixture_database "$database"

  local output
  output=$(HOME="$fake_home" swift "$probe" \
    --include-existing \
    --once \
    --non-interactive 2>&1) || fail "auto-detect probe command failed: $output"

  require_contains "$output" "database.path=$database"
  require_contains "$output" "source.identifier=com.tencent.WeWorkMac"
  require_absent "$output" "TEST_GROUP_PRIVATE"
  require_absent "$output" "TEST_SENDER_PRIVATE"
  require_absent "$output" "TEST_BODY_PRIVATE"
}

test_auto_detects_darwin_user_database() {
  local fake_home="$fixture_dir/darwin-fake-home"
  local darwin_user_dir="$fixture_dir/darwin-user/"
  local database="${darwin_user_dir}com.apple.notificationcenter/db2/db"
  mkdir -p "$fake_home" "${database:h}"
  make_fixture_database "$database"

  local output
  output=$(HOME="$fake_home" DARWIN_USER_DIR="$darwin_user_dir" swift "$probe" \
    --include-existing \
    --once \
    --non-interactive 2>&1) || fail "Darwin path probe command failed: $output"

  require_contains "$output" "database.path=$database"
  require_contains "$output" "source.identifier=com.tencent.WeWorkMac"
  require_absent "$output" "TEST_GROUP_PRIVATE"
  require_absent "$output" "TEST_SENDER_PRIVATE"
  require_absent "$output" "TEST_BODY_PRIVATE"
}

test_auto_detection_skips_unusable_database_candidate() {
  local fake_home="$fixture_dir/fallback-fake-home"
  local unusable="$fake_home/Library/Group Containers/group.com.apple.usernoted/db2/db"
  local darwin_user_dir="$fixture_dir/fallback-darwin-user/"
  local database="${darwin_user_dir}com.apple.notificationcenter/db2/db"
  mkdir -p "${unusable:h}" "${database:h}"
  touch "$unusable"
  make_fixture_database "$database"

  local output
  output=$(HOME="$fake_home" DARWIN_USER_DIR="$darwin_user_dir" swift "$probe" \
    --include-existing \
    --once \
    --non-interactive 2>&1) || fail "fallback auto-detect probe command failed: $output"

  require_contains "$output" "database.path=$database"
  require_contains "$output" "source.identifier=com.tencent.WeWorkMac"
  require_absent "$output" "TEST_GROUP_PRIVATE"
  require_absent "$output" "TEST_SENDER_PRIVATE"
  require_absent "$output" "TEST_BODY_PRIVATE"
}

test_auto_detection_tolerates_temporarily_locked_database() {
  local fake_home="$fixture_dir/locked-auto-fake-home"
  local database="$fake_home/Library/Group Containers/group.com.apple.usernoted/db2/db"
  local executable="$fixture_dir/locked-auto-probe"
  local output_file="$fixture_dir/locked-auto-output.txt"
  local lock_pipe="$fixture_dir/locked-auto.pipe"
  local lock_ready="$fixture_dir/locked-auto-ready"
  local lock_output="$fixture_dir/locked-auto-locker.txt"
  mkdir -p "${database:h}"
  make_fixture_database "$database"
  swiftc "$probe" -o "$executable"

  mkfifo "$lock_pipe"
  sqlite3 "$database" < "$lock_pipe" > "$lock_output" 2>&1 &
  local locker_pid=$!
  exec 7>"$lock_pipe"
  print -u7 -- "BEGIN EXCLUSIVE;"
  print -u7 -- ".shell /usr/bin/touch '$lock_ready'"
  local ready=0
  local attempt
  for attempt in {1..100}; do
    if [[ -f "$lock_ready" ]]; then
      ready=1
      break
    fi
    kill -0 "$locker_pid" 2>/dev/null || break
    sleep 0.02
  done
  (( ready == 1 )) || fail "could not lock the auto-detected database"

  HOME="$fake_home" DARWIN_USER_DIR="$fixture_dir/missing-darwin/" "$executable" \
    --include-existing \
    --once \
    --non-interactive \
    --timeout 3 \
    --poll-interval 0.05 > "$output_file" 2>&1 &
  local probe_pid=$!
  sleep 1
  print -u7 -- "COMMIT;"
  exec 7>&-
  wait "$locker_pid" || fail "auto-detect SQLite locker failed: $(<"$lock_output")"

  local exit_code=0
  wait "$probe_pid" || exit_code=$?
  local output=$(<"$output_file")
  (( exit_code == 0 )) || fail "auto-detect did not recover from SQLite lock: $output"
  require_contains "$output" "database.path=$database"
  require_contains "$output" "record.id=42"
  require_absent "$output" "TEST_GROUP_PRIVATE"
  require_absent "$output" "TEST_SENDER_PRIVATE"
  require_absent "$output" "TEST_BODY_PRIVATE"
}

test_waits_for_a_new_notification_after_startup() {
  local database="$fixture_dir/waiting-notifications.db"
  local output_file="$fixture_dir/waiting-output.txt"
  make_fixture_database "$database"

  swift "$probe" \
    --database "$database" \
    --once \
    --non-interactive \
    --timeout 3 \
    --poll-interval 0.1 > "$output_file" 2>&1 &
  local probe_pid=$!
  local ready=0
  local attempt
  for attempt in {1..100}; do
    if [[ -f "$output_file" ]] && rg -q '^monitor\.baseline_record_id=42$' "$output_file"; then
      ready=1
      break
    fi
    kill -0 "$probe_pid" 2>/dev/null || break
    sleep 0.05
  done
  (( ready == 1 )) || fail "probe did not report a ready baseline"
  insert_fixture_notification "$database" 43

  local exit_code=0
  wait "$probe_pid" || exit_code=$?
  local output=$(<"$output_file")
  (( exit_code == 0 )) || fail "waiting probe command failed: $output"

  require_contains "$output" "monitor.baseline_record_id=42"
  require_contains "$output" "record.id=43"
  require_contains "$output" "payload.body.type=string length=17"
  require_absent "$output" "TEST_GROUP_PRIVATE"
  require_absent "$output" "TEST_SENDER_PRIVATE"
  require_absent "$output" "TEST_BODY_PRIVATE"
}

test_detects_new_notification_after_record_ids_move_backwards() {
  local database="$fixture_dir/reused-record-id-notifications.db"
  local output_file="$fixture_dir/reused-record-id-output.txt"
  make_empty_database "$database"
  insert_fixture_notification "$database" 45

  swift "$probe" \
    --database "$database" \
    --once \
    --non-interactive \
    --timeout 2 \
    --poll-interval 0.05 > "$output_file" 2>&1 &
  local probe_pid=$!
  local ready=0
  local attempt
  for attempt in {1..100}; do
    if [[ -f "$output_file" ]] && rg -q '^monitor\.baseline_record_id=45$' "$output_file"; then
      ready=1
      break
    fi
    kill -0 "$probe_pid" 2>/dev/null || break
    sleep 0.05
  done
  (( ready == 1 )) || fail "record-reuse probe did not report a ready baseline"

  sqlite3 "$database" "DELETE FROM record WHERE rec_id=45;"
  insert_fixture_notification "$database" 37

  local exit_code=0
  wait "$probe_pid" || exit_code=$?
  local output=$(<"$output_file")
  (( exit_code == 0 )) || fail "probe missed a new notification with a lower record ID: $output"
  require_contains "$output" "monitor.baseline_record_id=45"
  require_contains "$output" "record.id=37"
  require_absent "$output" "TEST_GROUP_PRIVATE"
  require_absent "$output" "TEST_SENDER_PRIVATE"
  require_absent "$output" "TEST_BODY_PRIVATE"
}

test_retries_while_notification_database_is_locked() {
  local database="$fixture_dir/locked-notifications.db"
  local output_file="$fixture_dir/locked-output.txt"
  local lock_pipe="$fixture_dir/sqlite-lock.pipe"
  local lock_output="$fixture_dir/sqlite-lock-output.txt"
  local lock_ready="$fixture_dir/sqlite-lock-ready"
  make_fixture_database "$database"

  swift "$probe" \
    --database "$database" \
    --once \
    --non-interactive \
    --timeout 4 \
    --poll-interval 0.05 > "$output_file" 2>&1 &
  local probe_pid=$!
  local ready=0
  local attempt
  for attempt in {1..100}; do
    if [[ -f "$output_file" ]] && rg -q '^monitor\.baseline_record_id=42$' "$output_file"; then
      ready=1
      break
    fi
    kill -0 "$probe_pid" 2>/dev/null || break
    sleep 0.05
  done
  (( ready == 1 )) || fail "locked-database probe did not report a ready baseline"

  local payload=$(make_payload)
  local payload_hex=$(xxd -p -c 1000000 "$payload")
  mkfifo "$lock_pipe"
  sqlite3 "$database" < "$lock_pipe" > "$lock_output" 2>&1 &
  local locker_pid=$!
  exec 9>"$lock_pipe"
  print -u9 -- "BEGIN EXCLUSIVE;"
  print -u9 -- "INSERT INTO record(rec_id, app_id, uuid, data, delivered_date, presented, style) VALUES(43, 1, X'01020304', X'$payload_hex', 812345679, 1, 1);"
  print -u9 -- ".shell /usr/bin/touch '$lock_ready'"

  ready=0
  for attempt in {1..100}; do
    if [[ -f "$lock_ready" ]]; then
      ready=1
      break
    fi
    kill -0 "$locker_pid" 2>/dev/null || break
    sleep 0.02
  done
  (( ready == 1 )) || fail "could not acquire the synthetic SQLite lock"
  sleep 0.4
  print -u9 -- "COMMIT;"
  exec 9>&-
  wait "$locker_pid" || fail "synthetic SQLite locker failed: $(<"$lock_output")"

  local exit_code=0
  wait "$probe_pid" || exit_code=$?
  local output=$(<"$output_file")
  (( exit_code == 0 )) || fail "probe did not recover from SQLite lock: $output"
  require_contains "$output" "monitor.baseline_record_id=42"
  require_contains "$output" "record.id=43"
  require_absent "$output" "TEST_GROUP_PRIVATE"
  require_absent "$output" "TEST_SENDER_PRIVATE"
  require_absent "$output" "TEST_BODY_PRIVATE"
}

test_accepts_team_prefixed_wecom_identifier() {
  local database="$fixture_dir/team-prefixed-notifications.db"
  make_fixture_database "$database"
  sqlite3 "$database" \
    "UPDATE app SET identifier='88L2Q4487U.com.tencent.WeWorkMac' WHERE app_id=1;"

  local output
  output=$(swift "$probe" \
    --database "$database" \
    --include-existing \
    --once \
    --non-interactive 2>&1) || fail "team-prefixed probe command failed: $output"

  require_contains "$output" "source.identifier=88L2Q4487U.com.tencent.WeWorkMac"
  require_contains "$output" "record.id=42"
  require_absent "$output" "TEST_GROUP_PRIVATE"
  require_absent "$output" "TEST_SENDER_PRIVATE"
  require_absent "$output" "TEST_BODY_PRIVATE"
  require_absent "$output" "TEST_ATTACHMENT_PRIVATE"
}

test_rejects_similar_non_wecom_identifier() {
  local database="$fixture_dir/non-wecom-notifications.db"
  make_fixture_database "$database"
  sqlite3 "$database" \
    "UPDATE app SET identifier='com.tencent.WeWorkMac.untrusted' WHERE app_id=1;"

  local output
  if output=$(swift "$probe" \
    --database "$database" \
    --include-existing \
    --once \
    --non-interactive 2>&1); then
    fail "probe accepted a similar but non-WeCom identifier"
  fi

  require_contains "$output" "没有找到企业微信通知记录"
  require_absent "$output" "TEST_GROUP_PRIVATE"
  require_absent "$output" "TEST_SENDER_PRIVATE"
  require_absent "$output" "TEST_BODY_PRIVATE"
  require_absent "$output" "TEST_ATTACHMENT_PRIVATE"
}

test_reports_structure_without_plaintext
print -- "PASS: reports notification structure without plaintext"
test_handles_payload_larger_than_process_pipe_capacity
print -- "PASS: handles payloads larger than process pipe capacity"
test_handles_attachment_keys_that_differ_only_by_case
print -- "PASS: handles attachment keys that differ only by case"
test_matches_expected_values_without_echoing_them
print -- "PASS: matches expected values without echoing them"
test_disables_echo_for_interactive_terminal_input
print -- "PASS: disables echo for interactive terminal input"
test_restores_terminal_echo_when_interrupted
print -- "PASS: restores terminal echo when interrupted"
test_auto_detects_group_container_database
print -- "PASS: auto-detects the group container database"
test_auto_detects_darwin_user_database
print -- "PASS: auto-detects the Darwin user database"
test_auto_detection_skips_unusable_database_candidate
print -- "PASS: skips unusable auto-detected database candidates"
test_auto_detection_tolerates_temporarily_locked_database
print -- "PASS: tolerates a temporarily locked auto-detected database"
test_waits_for_a_new_notification_after_startup
print -- "PASS: waits for a new notification after startup"
test_detects_new_notification_after_record_ids_move_backwards
print -- "PASS: detects new notifications after record IDs move backwards"
test_retries_while_notification_database_is_locked
print -- "PASS: retries while the notification database is locked"
test_accepts_team_prefixed_wecom_identifier
print -- "PASS: accepts the Team ID-prefixed WeCom identifier"
test_rejects_similar_non_wecom_identifier
print -- "PASS: rejects similar non-WeCom identifiers"
