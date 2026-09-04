#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
listener="$script_dir/wecom-group-listener.swift"
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/wxfomo-wecom-listener-test.XXXXXX")
export WXFOMO_LAN_DATABASE="$fixture_dir/messages.sqlite3"
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
  [[ "$output" != *"$forbidden"* ]] || fail "unexpected output: $forbidden"
}

source_key_for() {
  local database=$1
  local normalized=$(/usr/bin/python3 -c \
    'import os, sys; print(os.path.normpath(sys.argv[1]))' "$database")
  print -r -- "$normalized|$(stat -f %d "$database")|$(stat -f %i "$database")"
}

make_database() {
  local database=$1
  export WXFOMO_LAN_DATABASE="${database:r}-messages.sqlite3"
  sqlite3 "$database" >/dev/null <<'SQL'
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
INSERT INTO app(app_id, identifier, badge) VALUES(2, 'com.tencent.xinWeChat', 0);
SQL
}

payload_hex() {
  local title=$1
  local subtitle=$2
  local body=$3
  local conversation_type=${4:-1}
  local user_data
  case "$conversation_type" in
    0) user_data='YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGlCwwVFhdVJG51bGzTDQ4PEBIUV05TLmtleXNaTlMub2JqZWN0c1YkY2xhc3OhEYACoROAA4AEUmN0EADSGBkaG1okY2xhc3NuYW1lWCRjbGFzc2VzXE5TRGljdGlvbmFyeaIaHFhOU09iamVjdAgRGiQpMjdJTFFTWV9mbnmAgoSGiIqNj5SfqLW4AAAAAAAAAQEAAAAAAAAAHQAAAAAAAAAAAAAAAAAAAME=' ;;
    1) user_data='YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGlCwwVFhdVJG51bGzTDQ4PEBIUV05TLmtleXNaTlMub2JqZWN0c1YkY2xhc3OhEYACoROAA4AEUmN0EAHSGBkaG1okY2xhc3NuYW1lWCRjbGFzc2VzXE5TRGljdGlvbmFyeaIaHFhOU09iamVjdAgRGiQpMjdJTFFTWV9mbnmAgoSGiIqNj5SfqLW4AAAAAAAAAQEAAAAAAAAAHQAAAAAAAAAAAAAAAAAAAME=' ;;
    *) fail "unsupported conversation type fixture: $conversation_type" ;;
  esac
  local payload="$fixture_dir/payload-$RANDOM.plist"
  /bin/cat > "$payload" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>req</key><dict>
<key>titl</key><string>TITLE_VALUE</string>
<key>subt</key><string>SUBTITLE_VALUE</string>
<key>body</key><string>BODY_VALUE</string>
<key>usda</key><data>USER_DATA_VALUE</data>
</dict></dict></plist>
PLIST
  /usr/libexec/PlistBuddy -c "Set :req:titl $title" "$payload"
  /usr/libexec/PlistBuddy -c "Set :req:subt $subtitle" "$payload"
  /usr/libexec/PlistBuddy -c "Set :req:body $body" "$payload"
  plutil -replace req.usda -data "$user_data" "$payload"
  plutil -convert binary1 "$payload"
  xxd -p -c 1000000 "$payload"
}

insert_notification() {
  local database=$1
  local record_id=$2
  local app_id=$3
  local delivered=$4
  local title=$5
  local subtitle=$6
  local body=$7
  local conversation_type=${8:-1}
  local payload=$(payload_hex "$title" "$subtitle" "$body" "$conversation_type")
  local uuid=$(printf '%016x' "$record_id")
  sqlite3 "$database" "INSERT INTO record(rec_id,app_id,uuid,data,request_date,request_last_date,delivered_date,presented,style) VALUES($record_id,$app_id,X'$uuid',X'$payload',$delivered,$delivered,$delivered,1,1);"
}

insert_notification_with_text_uuid() {
  local database=$1
  local record_id=$2
  local delivered=$3
  local title=$4
  local subtitle=$5
  local body=$6
  local payload=$(payload_hex "$title" "$subtitle" "$body" 1)
  local uuid=$(printf '%016x' "$record_id")
  sqlite3 "$database" "INSERT INTO record(rec_id,app_id,uuid,data,request_date,request_last_date,delivered_date,presented,style) VALUES($record_id,1,'$uuid',X'$payload',$delivered,$delivered,$delivered,1,1);"
}

insert_notification_with_custom_text_uuid() {
  local database=$1
  local record_id=$2
  local uuid=$3
  local delivered=$4
  local title=$5
  local subtitle=$6
  local body=$7
  local payload=$(payload_hex "$title" "$subtitle" "$body" 1)
  local uuid_hex=$(print -rn -- "$uuid" | xxd -p -c 1000000)
  sqlite3 "$database" "INSERT INTO record(rec_id,app_id,uuid,data,request_date,request_last_date,delivered_date,presented,style) VALUES($record_id,1,CAST(X'$uuid_hex' AS TEXT),X'$payload',$delivered,$delivered,$delivered,1,1);"
}

make_fake_getconf() {
  local executable=$1
  mkdir -p "${executable:h}"
  /bin/cat > "$executable" <<'SH'
#!/bin/zsh
print -- invocation >> "$WXFOMO_TEST_GETCONF_COUNT_FILE"
print -r -- "$WXFOMO_TEST_GETCONF_RESULT"
SH
  chmod 700 "$executable"
}

insert_notification_without_uuid() {
  local database=$1
  local record_id=$2
  local delivered=$3
  local title=$4
  local subtitle=$5
  local body=$6
  local payload=$(payload_hex "$title" "$subtitle" "$body" 1)
  sqlite3 "$database" \
    "INSERT INTO record(rec_id,app_id,uuid,data,request_date,request_last_date,delivered_date,presented,style) VALUES($record_id,1,NULL,X'$payload',$delivered,$delivered,$delivered,1,1);"
}

write_config() {
  local config_path=$1
  shift
  mkdir -p "${config_path:h}"
  print -l -- "$@" > "$config_path"
  chmod 700 "${config_path:h}"
  chmod 600 "$config_path"
}

test_rejects_cross_candidate_prefix_alias_ambiguity_before_writes() {
  local database="$fixture_dir/prefix-owner-preflight-source.db"
  local config="$fixture_dir/prefix-owner-preflight/groups.txt"
  local store="$fixture_dir/prefix-owner-preflight/messages.sqlite3"
  make_database "$database"
  write_config "$config" "目标群"
  local output
  output=$(WXFOMO_TEST_PREFIX_ALIAS_PREFLIGHT=1 swift "$listener" \
    --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.2 --poll-interval 0.05 2>&1) \
    || fail "prefix alias owner preflight self-test failed: $output"
  require_contains "$output" "PASS: 旧原生前缀 alias 全局预检"
}

test_waits_for_every_prefix_owner_before_writing_recovered_aliases() {
  local old_listener="$fixture_dir/prefix-owner-set-old-listener.swift"
  local intermediate_listener="$fixture_dir/prefix-owner-set-intermediate-listener.swift"
  local database="$fixture_dir/prefix-owner-set-source.db"
  local config="$fixture_dir/prefix-owner-set/groups.txt"
  local store="$fixture_dir/prefix-owner-set/messages.sqlite3"
  local group_a="甲"
  local group_b="乙"
  local uuid_a="seed"
  local uuid_b="seed|前"
  local historical_sender_a="成员一"
  local historical_sender_b="成员二"
  local current_sender_a="前|乙"
  local current_sender_b="甲"
  local current_content="所有权碰撞"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical owner-set listener"
  git show baa877b:scripts/wecom-group-listener.swift > "$intermediate_listener" \
    || fail "could not materialize the intermediate owner-set listener"
  make_database "$database"
  write_config "$config" "$group_a" "$group_b"

  # Seed two genuinely distinct historical owners first.  Their current
  # revisions below will expose the legacy delimiter ambiguity only after the
  # intermediate version-1 migration has completed.
  insert_notification_with_custom_text_uuid \
    "$database" 71 "$uuid_a" 100 "$group_a" "$historical_sender_a" "历史一"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed owner A"
  local old_event_a=$(sqlite3 "$store" "SELECT event_id FROM messages WHERE group_name='$group_a';")
  sqlite3 "$database" "DELETE FROM record WHERE rec_id=71;"
  insert_notification_with_custom_text_uuid \
    "$database" 72 "$uuid_b" 200 "$group_b" "$historical_sender_b" "历史二"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed owner B"
  local old_event_b=$(sqlite3 "$store" "SELECT event_id FROM messages WHERE group_name='$group_b';")
  insert_notification_with_custom_text_uuid \
    "$database" 71 "$uuid_a" 100 "$group_a" "$historical_sender_a" "历史一"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "2" ]] \
    || fail "pre-canonical owner-set fixture did not create two owners"

  local intermediate_exit=0
  local intermediate_output
  intermediate_output=$(swift "$intermediate_listener" --database "$database" \
    --config "$config" --store "$store" --once --timeout 0.6 \
    --poll-interval 0.05 2>&1) || intermediate_exit=$?
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" ]] \
    || fail "intermediate owner-set fixture did not complete version 1: exit=$intermediate_exit output=$intermediate_output"

  # The legacy hash did not escape field separators.  The compatibility set's
  # A-reversed and B-normal direct layouts now serialize to the same old input
  # despite distinct UUIDs, groups, and canonical event IDs.  The actual source
  # uses A-normal/B-reversed, so this shared ID is not added by normal persistence.
  local payload_a=$(payload_hex "$group_a" "$current_sender_a" "$current_content")
  sqlite3 "$database" \
    "UPDATE record SET data=X'$payload_a',request_last_date=300,delivered_date=300 WHERE rec_id=71;"
  sqlite3 "$database" "DELETE FROM record WHERE rec_id=72;"

  local aliases_a_output aliases_b_output
  aliases_a_output=$(WXFOMO_PREFIX_EVENT_SEED="$uuid_a" \
    WXFOMO_PREFIX_GROUP="$group_a" WXFOMO_PREFIX_SENDER="$current_sender_a" \
    WXFOMO_PREFIX_CONTENT="$current_content" WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not enumerate owner A aliases"
  aliases_b_output=$(WXFOMO_PREFIX_EVENT_SEED="$uuid_b" \
    WXFOMO_PREFIX_GROUP="$group_b" WXFOMO_PREFIX_SENDER="$current_sender_b" \
    WXFOMO_PREFIX_CONTENT="$current_content" WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not enumerate owner B aliases"
  local -a aliases_a aliases_b
  aliases_a=("${(@f)aliases_a_output}")
  aliases_b=("${(@f)aliases_b_output}")
  local current_raw_a=${aliases_a[1]}
  local current_raw_b=${aliases_b[2]}
  local shared_alias=""
  local candidate_alias other_alias
  for candidate_alias in "${aliases_a[@]}"; do
    [[ "$candidate_alias" != "$old_event_a" && "$candidate_alias" != "$old_event_b" \
      && "$candidate_alias" != "$current_raw_a" && "$candidate_alias" != "$current_raw_b" ]] \
      || continue
    for other_alias in "${aliases_b[@]}"; do
      if [[ "$candidate_alias" == "$other_alias" ]]; then
        shared_alias=$candidate_alias
        break 2
      fi
    done
  done
  [[ -n "$shared_alias" ]] || fail "real old oracle did not expose an unmaterialized shared alias"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM messages WHERE event_id='$shared_alias';")" == "0" ]] \
    || fail "shared recovered alias was already a canonical event ID"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$shared_alias';")" == "0" ]] \
    || fail "shared recovered alias was already materialized by version 1"

  # A source is available while B is temporarily absent.  Version 2 must not
  # write any recovered alias until its complete owner set can be preflighted.
  local output
  local exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.4 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "incomplete owner-set upgrade unexpectedly emitted"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "0" ]] \
    || fail "incomplete owner-set upgrade recorded version 2"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$shared_alias';")" == "0" ]] \
    || fail "incomplete owner set wrote an alias before global preflight: $output"

  # Once B returns, the real collision is visible.  Both owners remain
  # unbound and the migration remains pending rather than preserving A's
  # earlier partial claim.
  insert_notification_with_custom_text_uuid \
    "$database" 72 "$uuid_b" 300 "$current_sender_b" "$group_b" "$current_content"
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.4 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "ambiguous complete owner-set upgrade unexpectedly emitted"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "0" ]] \
    || fail "ambiguous complete owner set recorded version 2"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$shared_alias';")" == "0" ]] \
    || fail "ambiguous recovered alias was assigned to one owner"
}

test_preflights_every_version1_owner_before_any_consolidation_write() {
  local old_listener="$fixture_dir/version1-owner-preflight-old-listener.swift"
  local database="$fixture_dir/version1-owner-preflight-source.db"
  local config="$fixture_dir/version1-owner-preflight/groups.txt"
  local store="$fixture_dir/version1-owner-preflight/messages.sqlite3"
  local group_a="乙|丙"
  local group_b="乙"
  local uuid_a="seed"
  local uuid_b="seed|前"
  local sender_a="前"
  local sender_b="丙"
  local content="version1 所有权碰撞"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical version-1 owner listener"
  make_database "$database"
  write_config "$config" "$group_a" "$group_b"

  # Persist two real pre-canonical owners using non-colliding source layouts.
  # A's reversed compatibility layout and B's normal compatibility layout
  # nevertheless serialize to the same unescaped legacy hash input.
  insert_notification_with_custom_text_uuid \
    "$database" 71 "$uuid_a" 100 "$group_a" "$sender_a" "$content"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed version-1 owner A"
  local old_event_a=$(sqlite3 "$store" "SELECT event_id FROM messages WHERE group_name='$group_a';")
  sqlite3 "$database" "DELETE FROM record WHERE rec_id=71;"
  insert_notification_with_custom_text_uuid \
    "$database" 72 "$uuid_b" 200 "$sender_b" "$group_b" "$content"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed version-1 owner B"
  local old_event_b=$(sqlite3 "$store" "SELECT event_id FROM messages WHERE group_name='$group_b';")
  insert_notification_with_custom_text_uuid \
    "$database" 71 "$uuid_a" 100 "$group_a" "$sender_a" "$content"
  [[ -n "$old_event_a" && -n "$old_event_b" && "$old_event_a" != "$old_event_b" ]] \
    || fail "version-1 owner fixture did not retain two distinct standalone IDs"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "2" ]] \
    || fail "version-1 owner fixture did not create two historical owners"

  local aliases_a_output aliases_b_output
  aliases_a_output=$(WXFOMO_PREFIX_EVENT_SEED="$uuid_a" \
    WXFOMO_PREFIX_GROUP="$group_a" WXFOMO_PREFIX_SENDER="$sender_a" \
    WXFOMO_PREFIX_CONTENT="$content" WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not enumerate version-1 owner A aliases"
  aliases_b_output=$(WXFOMO_PREFIX_EVENT_SEED="$uuid_b" \
    WXFOMO_PREFIX_GROUP="$group_b" WXFOMO_PREFIX_SENDER="$sender_b" \
    WXFOMO_PREFIX_CONTENT="$content" WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not enumerate version-1 owner B aliases"
  local -a aliases_a aliases_b
  aliases_a=("${(@f)aliases_a_output}")
  aliases_b=("${(@f)aliases_b_output}")
  local current_raw_a=${aliases_a[1]}
  local current_raw_b=${aliases_b[2]}
  [[ "$current_raw_a" != "$current_raw_b" \
    && "$current_raw_a" != "$old_event_a" && "$current_raw_a" != "$old_event_b" \
    && "$current_raw_b" != "$old_event_a" && "$current_raw_b" != "$old_event_b" ]] \
    || fail "version-1 fixture did not expose distinct standalone and raw identities"
  local shared_alias=""
  local candidate_alias other_alias
  for candidate_alias in "${aliases_a[@]}"; do
    [[ "$candidate_alias" != "$old_event_a" && "$candidate_alias" != "$old_event_b" \
      && "$candidate_alias" != "$current_raw_a" && "$candidate_alias" != "$current_raw_b" ]] \
      || continue
    for other_alias in "${aliases_b[@]}"; do
      if [[ "$candidate_alias" == "$other_alias" ]]; then
        shared_alias=$candidate_alias
        break 2
      fi
    done
  done
  [[ -n "$shared_alias" ]] \
    || fail "real old oracle did not expose a pure historical version-1 alias collision"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM messages WHERE event_id='$shared_alias';")" == "0" \
    && "$(sqlite3 "$store" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='message_event_aliases';")" == "0" ]] \
    || fail "version-1 shared historical alias was materialized before HEAD"

  # After the migration audit, stop the safety replay at its first attempt to
  # insert a current canonical row.  This preserves the migration transaction's
  # exact post-state for inspection: the buggy implementation has already
  # committed owner A, while a correct global preflight has changed neither
  # pre-canonical message.
  sqlite3 "$store" <<'SQL'
CREATE TRIGGER stop_after_version1_audit
BEFORE INSERT ON messages
BEGIN
  SELECT RAISE(ABORT, 'stop after version1 audit fixture');
END;
SQL

  local output
  local exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.5 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "ambiguous version-1 migration unexpectedly emitted"
  require_contains "$output" "兼容 ID 迁移保持待完成"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "0" ]] \
    || fail "ambiguous version-1 owner set recorded marker 301"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_legacy_alias_provenance WHERE version=2026090305;')" == "0" ]] \
    || fail "one version-1 owner wrote provenance before the global preflight"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$shared_alias';")" == "0" ]] \
    || fail "one version-1 owner claimed a shared alias before the global preflight"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM messages WHERE event_id IN ('$old_event_a','$old_event_b');")" == "2" ]] \
    || fail "one version-1 owner was canonicalized before the global preflight"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "2" ]] \
    || fail "ambiguous version-1 migration changed message cardinality"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM conversations c WHERE c.message_count != (SELECT COUNT(*) FROM messages m WHERE m.conversation_id=c.id);')" == "0" ]] \
    || fail "ambiguous version-1 migration drifted conversation counts"
}

test_recovers_real_65f_partial_version1_collision_atomically() {
  local old_listener="$fixture_dir/version1-partial-old-listener.swift"
  local partial_listener="$fixture_dir/version1-partial-65f-listener.swift"
  local database="$fixture_dir/version1-partial-source.db"
  local config="$fixture_dir/version1-partial/groups.txt"
  local store="$fixture_dir/version1-partial/messages.sqlite3"
  local config_drift_store="$fixture_dir/version1-partial/messages-config-drift.sqlite3"
  local abort_store="$fixture_dir/version1-partial/messages-abort.sqlite3"
  local replay_store="$fixture_dir/version1-partial/messages-after-replay.sqlite3"
  local tampered_store="$fixture_dir/version1-partial/messages-tampered.sqlite3"
  local scale_store="$fixture_dir/version1-partial/messages-many-standalone.sqlite3"
  local exact_conflict_store="$fixture_dir/version1-partial/messages-exact-conflict.sqlite3"
  local group_a="乙|丙"
  local group_b="乙"
  local uuid_a="seed"
  local uuid_b="seed|前"
  local sender_a="前"
  local sender_b="丙"
  local content="65f 半完成所有权碰撞"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical partial-upgrade listener"
  git show 65f495d:scripts/wecom-group-listener.swift > "$partial_listener" \
    || fail "could not materialize the real per-owner partial-upgrade listener"
  make_database "$database"
  write_config "$config" "$group_a" "$group_b"

  insert_notification_with_custom_text_uuid \
    "$database" 71 "$uuid_a" 100 "$group_a" "$sender_a" "$content"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed partial-upgrade owner A"
  local old_event_a=$(sqlite3 "$store" "SELECT event_id FROM messages WHERE group_name='$group_a';")
  sqlite3 "$database" "DELETE FROM record WHERE rec_id=71;"
  insert_notification_with_custom_text_uuid \
    "$database" 72 "$uuid_b" 200 "$sender_b" "$group_b" "$content"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed partial-upgrade owner B"
  local old_event_b=$(sqlite3 "$store" "SELECT event_id FROM messages WHERE group_name='$group_b';")
  insert_notification_with_custom_text_uuid \
    "$database" 71 "$uuid_a" 100 "$group_a" "$sender_a" "$content"

  local aliases_a_output aliases_b_output
  aliases_a_output=$(WXFOMO_PREFIX_EVENT_SEED="$uuid_a" \
    WXFOMO_PREFIX_GROUP="$group_a" WXFOMO_PREFIX_SENDER="$sender_a" \
    WXFOMO_PREFIX_CONTENT="$content" WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not enumerate partial-upgrade owner A aliases"
  aliases_b_output=$(WXFOMO_PREFIX_EVENT_SEED="$uuid_b" \
    WXFOMO_PREFIX_GROUP="$group_b" WXFOMO_PREFIX_SENDER="$sender_b" \
    WXFOMO_PREFIX_CONTENT="$content" WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not enumerate partial-upgrade owner B aliases"
  local -a aliases_a aliases_b
  aliases_a=("${(@f)aliases_a_output}")
  aliases_b=("${(@f)aliases_b_output}")
  local current_raw_a=${aliases_a[1]}
  local current_raw_b=${aliases_b[2]}
  local shared_alias=""
  local candidate_alias other_alias
  for candidate_alias in "${aliases_a[@]}"; do
    [[ "$candidate_alias" != "$old_event_a" && "$candidate_alias" != "$old_event_b" \
      && "$candidate_alias" != "$current_raw_a" && "$candidate_alias" != "$current_raw_b" ]] \
      || continue
    for other_alias in "${aliases_b[@]}"; do
      if [[ "$candidate_alias" == "$other_alias" ]]; then
        shared_alias=$candidate_alias
        break 2
      fi
    done
  done
  [[ -n "$shared_alias" ]] \
    || fail "real old oracle did not expose the 65f pure compatibility collision"

  # 65f495d commits each owner separately.  Stop its later safety replay so the
  # fixture preserves the real production half-state: A committed with 303 and
  # the shared alias, B rolled back, and the global marker still absent.
  sqlite3 "$store" <<'SQL'
CREATE TRIGGER stop_after_real_65f_partial
BEFORE INSERT ON messages
BEGIN
  SELECT RAISE(ABORT, 'stop after real 65f partial migration');
END;
SQL
  local partial_output
  local partial_exit=0
  partial_output=$(swift "$partial_listener" --database "$database" --config "$config" \
    --store "$store" --once --timeout 0.8 --poll-interval 0.05 2>&1) || partial_exit=$?
  (( partial_exit != 0 )) || fail "real 65f partial fixture unexpectedly emitted"
  sqlite3 "$store" 'DROP TRIGGER stop_after_real_65f_partial; PRAGMA wal_checkpoint(TRUNCATE);' \
    >/dev/null
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "0" ]] \
    || fail "real 65f partial fixture unexpectedly recorded marker 301"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_legacy_alias_provenance WHERE version=2026090303;')" == "1" ]] \
    || fail "real 65f partial fixture did not commit exactly owner A provenance"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM messages WHERE event_id='$old_event_a';")" == "0" \
    && "$(sqlite3 "$store" "SELECT COUNT(*) FROM messages WHERE event_id='$old_event_b';")" == "1" ]] \
    || fail "real 65f fixture did not preserve its canonical-A/precanonical-B half-state"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$shared_alias' AND message_id=(SELECT message_id FROM message_legacy_alias_provenance WHERE version=2026090303);")" == "1" ]] \
    || fail "real 65f fixture did not leave the ambiguous alias incorrectly owned by A"

  /bin/cp -p "$store" "$abort_store"
  /bin/cp -p "$store" "$config_drift_store"
  /bin/cp -p "$store" "$replay_store"
  /bin/cp -p "$store" "$tampered_store"
  /bin/cp -p "$store" "$scale_store"
  /bin/cp -p "$store" "$exact_conflict_store"

  # Recovery ownership comes from the old store plus the source identity, not
  # today's configured watch list.  A has been removed while B remains; both
  # historical owners must still be verified against their own exact group and
  # committed as one complete owner set.  Otherwise safety replay emits a new
  # canonical B beside the still-pending old rows.
  local config_drift_identity_before=$(sqlite3 "$config_drift_store" \
    "SELECT id || ':' || hex(group_name) FROM messages ORDER BY id;")
  write_config "$config" "$group_b"
  local output
  local exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" \
    --store "$config_drift_store" --once --timeout 1.5 \
    --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "config-drift recovery unexpectedly emitted"
  require_contains "$output" "等待指定企业微信群消息超时"
  require_absent "$output" "兼容 ID 迁移保持待完成"
  require_absent "$output" "[$group_b]"
  [[ "$(sqlite3 "$config_drift_store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" \
    && "$(sqlite3 "$config_drift_store" 'SELECT COUNT(*) FROM message_legacy_alias_provenance WHERE version=2026090305;')" == "2" \
    && "$(sqlite3 "$config_drift_store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090306;')" == "1" \
    && "$(sqlite3 "$config_drift_store" "SELECT COUNT(*) FROM message_event_alias_quarantine WHERE alias_event_id='$shared_alias';")" == "1" \
    && "$(sqlite3 "$config_drift_store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$shared_alias';")" == "0" \
    && "$(sqlite3 "$config_drift_store" 'SELECT COUNT(*) FROM messages;')" == "2" \
    && "$(sqlite3 "$config_drift_store" "SELECT id || ':' || hex(group_name) FROM messages ORDER BY id;")" == "$config_drift_identity_before" \
    && "$(sqlite3 "$config_drift_store" 'SELECT COUNT(*) FROM conversations c WHERE c.message_count != (SELECT COUNT(*) FROM messages m WHERE m.conversation_id=c.id);')" == "0" ]] \
    || fail "historical A/B groups removed from config prevented complete partial recovery: $output"
  write_config "$config" "$group_a" "$group_b"

  local partial_owner_id=$(sqlite3 "$tampered_store" \
    'SELECT message_id FROM message_legacy_alias_provenance WHERE version=2026090303;')
  local tampered_canonical="tampered-old303-canonical"
  sqlite3 "$tampered_store" \
    "UPDATE messages SET event_id='$tampered_canonical' WHERE id=$partial_owner_id;"
  sqlite3 "$tampered_store" <<'SQL'
CREATE TRIGGER stop_after_tampered_recovery_audit
BEFORE INSERT ON messages
BEGIN
  SELECT RAISE(ABORT, 'stop after tampered recovery audit');
END;
SQL
  output=""
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" \
    --store "$tampered_store" --once --timeout 0.8 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "tampered old303 canonical fixture unexpectedly emitted"
  require_contains "$output" "兼容 ID 迁移保持待完成"
  sqlite3 "$tampered_store" 'DROP TRIGGER stop_after_tampered_recovery_audit;'
  [[ "$(sqlite3 "$tampered_store" 'SELECT COUNT(*) FROM schema_migrations WHERE version IN (2026090301,2026090306);')" == "0" \
    && "$(sqlite3 "$tampered_store" 'SELECT COUNT(*) FROM message_legacy_alias_provenance WHERE version=2026090305;')" == "0" \
    && "$(sqlite3 "$tampered_store" 'SELECT COUNT(*) FROM message_event_alias_quarantine;')" == "0" \
    && "$(sqlite3 "$tampered_store" "SELECT COUNT(*) FROM messages WHERE id=$partial_owner_id AND event_id='$tampered_canonical';")" == "1" \
    && "$(sqlite3 "$tampered_store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$shared_alias' AND message_id=$partial_owner_id;")" == "1" ]] \
    || fail "old303 canonical drift was rewritten instead of failing closed"

  local -a old_event_parts
  old_event_parts=("${(@s/:/)old_event_a}")
  local identity_prefix="${old_event_parts[1]}:${old_event_parts[2]}"
  {
    local index fingerprint
    for index in {1..600}; do
      fingerprint=$(printf '%016x' "$index")
      print -- "INSERT INTO message_event_aliases(alias_event_id,message_id,created_at) VALUES('$identity_prefix:$fingerprint:$fingerprint:$fingerprint:$fingerprint',$partial_owner_id,1);"
    done
  } | sqlite3 "$scale_store"
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" \
    --store "$scale_store" --once --timeout 1 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "many-standalone recovery fixture unexpectedly emitted"
  [[ "$(sqlite3 "$scale_store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" \
    && "$(sqlite3 "$scale_store" 'SELECT COUNT(*) FROM message_legacy_alias_provenance WHERE version=2026090305;')" == "2" ]] \
    || fail "old303 recovery exceeded its linear deadline with many standalone aliases"

  sqlite3 "$exact_conflict_store" <<SQL
INSERT INTO messages(
  event_id, conversation_id, group_name, sender_display_name, content,
  message_type, observed_at, source_sequence, inserted_at
) VALUES(
  '$shared_alias', (SELECT id FROM conversations ORDER BY id LIMIT 1),
  '隔离保护群', '精确所有者', '不可隔离的精确 ID',
  'text', 1, 999, 1
);
CREATE TRIGGER stop_after_protected_collision_audit
BEFORE INSERT ON messages
BEGIN
  SELECT RAISE(ABORT, 'stop after protected collision audit');
END;
SQL
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" \
    --store "$exact_conflict_store" --once --timeout 0.8 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "protected exact-ID partial recovery unexpectedly emitted"
  require_contains "$output" "兼容 ID 迁移保持待完成"
  sqlite3 "$exact_conflict_store" 'DROP TRIGGER stop_after_protected_collision_audit;'
  [[ "$(sqlite3 "$exact_conflict_store" 'SELECT COUNT(*) FROM schema_migrations WHERE version IN (2026090301,2026090306);')" == "0" \
    && "$(sqlite3 "$exact_conflict_store" 'SELECT COUNT(*) FROM message_legacy_alias_provenance WHERE version=2026090305;')" == "0" \
    && "$(sqlite3 "$exact_conflict_store" 'SELECT COUNT(*) FROM message_event_alias_quarantine;')" == "0" \
    && "$(sqlite3 "$exact_conflict_store" "SELECT COUNT(*) FROM messages WHERE event_id='$shared_alias';")" == "1" \
    && "$(sqlite3 "$exact_conflict_store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$shared_alias' AND message_id=$partial_owner_id;")" == "1" ]] \
    || fail "protected exact-ID collision was quarantined or partially rewritten"

  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 1.5 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "recovered 65f partial fixture unexpectedly emitted"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" ]] \
    || fail "HEAD did not atomically complete marker 301 for the real 65f partial store: $output"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_legacy_alias_provenance WHERE version=2026090305;')" == "2" ]] \
    || fail "HEAD did not replace both partial owners with provenance 305"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090306;')" == "1" ]] \
    || fail "HEAD did not atomically record the partial-recovery audit marker"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version IN (2026090302,2026090304);')" == "2" ]] \
    || fail "quarantine-aware prefix upgrade did not complete after partial recovery"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_alias_quarantine WHERE alias_event_id='$shared_alias' AND version=2026090305;")" == "1" ]] \
    || fail "HEAD did not durably quarantine the ambiguous compatibility alias"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$shared_alias';")" == "0" \
    && "$(sqlite3 "$store" "SELECT COUNT(*) FROM messages WHERE event_id='$shared_alias';")" == "0" ]] \
    || fail "quarantined compatibility alias still resolved through the SQLite lookup namespace"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "2" ]] \
    || fail "65f partial recovery changed owner cardinality"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM conversations c WHERE c.message_count != (SELECT COUNT(*) FROM messages m WHERE m.conversation_id=c.id);')" == "0" ]] \
    || fail "65f partial recovery drifted conversation counts"
  [[ "$(PYTHONPATH="$script_dir" /usr/bin/python3 - "$store" "$config" "$shared_alias" <<'PY'
import sys
from wxfomo_lan.messages import MessageRepository
print(len(MessageRepository(sys.argv[1], sys.argv[2]).by_event_ids([sys.argv[3]])))
PY
)" == "0" ]] || fail "read-only message repository still resolved the quarantined alias"
  local recovered_alias_count=$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_event_aliases;')
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.3 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "completed partial recovery unexpectedly emitted on restart"
  require_absent "$output" "迁移保持待完成"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_event_aliases;')" == "$recovered_alias_count" \
    && "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_alias_quarantine WHERE alias_event_id='$shared_alias';")" == "1" \
    && "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$shared_alias';")" == "0" ]] \
    || fail "completed partial recovery was not idempotent across restart"

  # Abort at the final 301 insert on a byte-for-byte copy of the real half-state.
  # Quarantine deletion, both owner rewrites, 305, 306 and 301 must all roll back
  # together, after which an unmodified restart must fully recover.
  sqlite3 "$abort_store" <<'SQL'
CREATE TRIGGER abort_round8_before_marker301
BEFORE INSERT ON schema_migrations
WHEN NEW.version = 2026090301
BEGIN
  SELECT RAISE(ABORT, 'abort round8 marker 301');
END;
SQL
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" \
    --store "$abort_store" --once --timeout 0.8 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "round8 transaction interruption unexpectedly emitted"
  [[ "$(sqlite3 "$abort_store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "0" \
    && "$(sqlite3 "$abort_store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090306;')" == "0" \
    && "$(sqlite3 "$abort_store" 'SELECT COUNT(*) FROM message_legacy_alias_provenance WHERE version=2026090305;')" == "0" \
    && "$(sqlite3 "$abort_store" 'SELECT COUNT(*) FROM message_event_alias_quarantine;')" == "0" ]] \
    || fail "round8 interruption exposed a partial new migration state"
  [[ "$(sqlite3 "$abort_store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$shared_alias';")" == "1" \
    && "$(sqlite3 "$abort_store" "SELECT COUNT(*) FROM messages WHERE event_id='$old_event_b';")" == "1" \
    && "$(sqlite3 "$abort_store" 'SELECT COUNT(*) FROM messages;')" == "2" \
    && "$(sqlite3 "$abort_store" 'SELECT COUNT(*) FROM message_legacy_alias_provenance WHERE version=2026090303;')" == "1" ]] \
    || fail "round8 interruption did not restore the exact old 65f half-state"

  sqlite3 "$abort_store" 'DROP TRIGGER abort_round8_before_marker301;'
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" \
    --store "$abort_store" --once --timeout 1.5 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "round8 restart fixture unexpectedly emitted"
  [[ "$(sqlite3 "$abort_store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" \
    && "$(sqlite3 "$abort_store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090306;')" == "1" \
    && "$(sqlite3 "$abort_store" 'SELECT COUNT(*) FROM message_legacy_alias_provenance WHERE version=2026090305;')" == "2" \
    && "$(sqlite3 "$abort_store" 'SELECT COUNT(*) FROM messages;')" == "2" \
    && "$(sqlite3 "$abort_store" "SELECT COUNT(*) FROM message_event_alias_quarantine WHERE alias_event_id='$shared_alias';")" == "1" \
    && "$(sqlite3 "$abort_store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$shared_alias';")" == "0" ]] \
    || fail "round8 restart did not converge from the exact interrupted old state"

  # Also cover the continuous-listener path where 65f reaches safety replay
  # after its partial owner commits and inserts B's canonical row beside B's
  # untouched pre-canonical row.
  exit_code=0
  output=$(swift "$partial_listener" --database "$database" --config "$config" \
    --store "$replay_store" --once --timeout 1 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code == 0 )) || fail "real 65f safety replay variant did not emit B: $output"
  [[ "$(sqlite3 "$replay_store" 'SELECT COUNT(*) FROM messages;')" == "3" \
    && "$(sqlite3 "$replay_store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "0" ]] \
    || fail "real 65f safety replay variant did not retain old B plus canonical B"
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" \
    --store "$replay_store" --once --timeout 1.5 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "recovered 65f safety replay fixture unexpectedly emitted"
  [[ "$(sqlite3 "$replay_store" 'SELECT COUNT(*) FROM messages;')" == "2" \
    && "$(sqlite3 "$replay_store" 'SELECT COUNT(*) FROM message_legacy_alias_provenance WHERE version=2026090305;')" == "2" \
    && "$(sqlite3 "$replay_store" "SELECT COUNT(*) FROM message_event_alias_quarantine WHERE alias_event_id='$shared_alias';")" == "1" \
    && "$(sqlite3 "$replay_store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$shared_alias';")" == "0" ]] \
    || fail "HEAD did not fold the real post-replay duplicate into atomic recovery"

  # The shared historical alias can later be the real raw native ID of B's
  # normal title/subtitle layout.  Exact canonical lookup must still win, the
  # quarantined alias must remain inactive, and normal persistence must commit
  # its checkpoint instead of surfacing a permanent storage error.
  [[ "$shared_alias" == "${aliases_b[1]}" ]] \
    || fail "partial recovery fixture did not identify B's future raw alias"
  local future_raw_message_id=$(sqlite3 "$store" \
    "SELECT id FROM messages WHERE group_name='$group_b';")
  local future_raw_canonical=$(sqlite3 "$store" \
    "SELECT event_id FROM messages WHERE id=$future_raw_message_id;")
  local future_raw_alias_count=$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_event_aliases;')
  local future_raw_expected_alias_count=$(( future_raw_alias_count + 1 ))
  local quarantine_snapshot=$(sqlite3 "$store" \
    "SELECT version || ':' || hex(claimant_message_ids_json) FROM message_event_alias_quarantine WHERE alias_event_id='$shared_alias';")
  local future_raw_payload=$(payload_hex "$group_b" "$sender_b" "$content")
  sqlite3 "$database" \
    "UPDATE record SET data=X'$future_raw_payload',request_last_date=900,delivered_date=900 WHERE rec_id=72;"
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.4 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "future-raw quarantine fixture unexpectedly emitted"
  [[ "$output" == *"等待指定企业微信群消息超时"* ]] \
    || fail "future raw alias prevented normal persistence: $output"
  require_absent "$output" "拒绝重新绑定已隔离的历史兼容 ID"
  [[ "$(sqlite3 "$store" 'SELECT cursor_timestamp=900 AND cursor_record_id=72 FROM listener_state WHERE singleton_id=1;')" == "1" \
    && "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_alias_quarantine WHERE alias_event_id='$shared_alias';")" == "1" \
    && "$(sqlite3 "$store" "SELECT version || ':' || hex(claimant_message_ids_json) FROM message_event_alias_quarantine WHERE alias_event_id='$shared_alias';")" == "$quarantine_snapshot" \
    && "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$shared_alias';")" == "0" \
    && "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_event_aliases;')" == "$future_raw_expected_alias_count" \
    && "$(sqlite3 "$store" "SELECT COUNT(*) FROM messages WHERE id=$future_raw_message_id AND event_id='$future_raw_canonical';")" == "1" \
    && "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "2" \
    && "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version IN (2026090301,2026090302,2026090304,2026090306);')" == "4" \
    && "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_legacy_alias_provenance WHERE version=2026090305;')" == "2" ]] \
    || fail "normal persistence rolled back its checkpoint or rebound a quarantined raw alias"
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.25 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "future-raw restart fixture unexpectedly emitted"
  [[ "$output" == *"等待指定企业微信群消息超时"* ]] \
    || fail "future raw alias was retried after restart: $output"
  require_absent "$output" "拒绝重新绑定已隔离的历史兼容 ID"
  [[ "$(sqlite3 "$store" 'SELECT cursor_timestamp=900 AND cursor_record_id=72 FROM listener_state WHERE singleton_id=1;')" == "1" \
    && "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_alias_quarantine WHERE alias_event_id='$shared_alias';")" == "1" \
    && "$(sqlite3 "$store" "SELECT version || ':' || hex(claimant_message_ids_json) FROM message_event_alias_quarantine WHERE alias_event_id='$shared_alias';")" == "$quarantine_snapshot" \
    && "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$shared_alias';")" == "0" \
    && "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_event_aliases;')" == "$future_raw_expected_alias_count" \
    && "$(sqlite3 "$store" "SELECT COUNT(*) FROM messages WHERE id=$future_raw_message_id AND event_id='$future_raw_canonical';")" == "1" \
    && "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "2" ]] \
    || fail "future-raw restart retried or rebound the quarantined alias"
}

test_keeps_a_completed_65f_provenance_store_compatible() {
  local old_listener="$fixture_dir/version1-complete-old-listener.swift"
  local complete_listener="$fixture_dir/version1-complete-65f-listener.swift"
  local database="$fixture_dir/version1-complete-source.db"
  local config="$fixture_dir/version1-complete/groups.txt"
  local store="$fixture_dir/version1-complete/messages.sqlite3"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical completed-65f listener"
  git show 65f495d:scripts/wecom-group-listener.swift > "$complete_listener" \
    || fail "could not materialize the completed-65f listener"
  make_database "$database"
  write_config "$config" "目标群"
  insert_notification "$database" 44 1 100 "目标群" "成员" "已完成65f"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed completed-65f store"
  local output
  local exit_code=0
  output=$(swift "$complete_listener" --database "$database" --config "$config" \
    --store "$store" --once --timeout 0.5 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "completed-65f fixture unexpectedly emitted"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" \
    && "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_legacy_alias_provenance WHERE version=2026090303;')" == "1" ]] \
    || fail "real 65f producer did not create its completed old-provenance state: $output"
  local event_id=$(sqlite3 "$store" 'SELECT event_id FROM messages;')
  local alias_count=$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_event_aliases;')

  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.3 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "HEAD replayed a completed-65f store"
  require_absent "$output" "迁移保持待完成"
  [[ "$(sqlite3 "$store" 'SELECT event_id FROM messages;')" == "$event_id" \
    && "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_event_aliases;')" == "$alias_count" \
    && "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_legacy_alias_provenance WHERE version=2026090303;')" == "1" \
    && "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_legacy_alias_provenance WHERE version=2026090305;')" == "0" \
    && "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090306;')" == "0" ]] \
    || fail "HEAD unnecessarily rewrote a completed 301+303 store"
}

test_interrupts_a_large_version1_owner_at_the_once_deadline() {
  local old_listener="$fixture_dir/version1-deadline-old-listener.swift"
  local database="$fixture_dir/version1-deadline-source.db"
  local config="$fixture_dir/version1-deadline/groups.txt"
  local store="$fixture_dir/version1-deadline/messages.sqlite3"
  local deadline_listener="$fixture_dir/version1-deadline-listener"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical version-1 deadline listener"
  make_database "$database"
  write_config "$config" "目标群"
  insert_notification "$database" 88 1 100 "目标群" "成员" "deadline fixture"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed the version-1 deadline owner"
  local old_event=$(sqlite3 "$store" 'SELECT event_id FROM messages LIMIT 1;')

  # Materialize the exact HEAD alias schema early so a trigger can make every
  # non-standalone alias insert observably slow.  Standalone prebinding remains
  # fast; the deadline is crossed only inside the atomic consolidation loop.
  sqlite3 "$store" <<'SQL'
CREATE TABLE message_event_aliases(
  alias_event_id TEXT PRIMARY KEY,
  message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  created_at REAL NOT NULL
);
CREATE INDEX message_event_aliases_message_idx
  ON message_event_aliases(message_id);
CREATE TRIGGER slow_version1_alias_insert
BEFORE INSERT ON message_event_aliases
WHEN instr(NEW.alias_event_id, ':') = 0
BEGIN
  SELECT length(randomblob(100000000));
END;
SQL
  swiftc -swift-version 5 "$listener" -lsqlite3 -o "$deadline_listener" \
    || fail "could not compile the version-1 deadline listener"

  local started_at=$(/usr/bin/python3 -c 'import time; print(time.time())')
  local output
  local exit_code=0
  output=$("$deadline_listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 3 --poll-interval 0.05 2>&1) || exit_code=$?
  local elapsed=$(/usr/bin/python3 -c \
    'import sys, time; print(time.time() - float(sys.argv[1]))' "$started_at")
  (( exit_code != 0 )) || fail "expired version-1 deadline fixture unexpectedly emitted"
  require_contains "$output" "等待指定企业微信群消息超时"
  /usr/bin/python3 -c \
    'import sys; assert float(sys.argv[1]) < 5.0, sys.argv[1]' "$elapsed" \
    || fail "version-1 owner kept the write transaction past its deadline: ${elapsed}s"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "0" ]] \
    || fail "expired version-1 batch committed marker 301"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_legacy_alias_provenance WHERE version=2026090305;')" == "0" ]] \
    || fail "expired version-1 batch committed provenance"
  [[ "$(sqlite3 "$store" "SELECT event_id FROM messages LIMIT 1;")" == "$old_event" ]] \
    || fail "expired version-1 batch did not roll back the survivor update"
}

test_interrupts_the_full_legacy_alias_scan_at_the_once_deadline() {
  local old_listener="$fixture_dir/version1-scan-deadline-old-listener.swift"
  local database="$fixture_dir/version1-scan-deadline-source.db"
  local config="$fixture_dir/version1-scan-deadline/groups.txt"
  local store="$fixture_dir/version1-scan-deadline/messages.sqlite3"
  local deadline_listener="$fixture_dir/version1-scan-deadline-listener"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical scan-deadline listener"
  make_database "$database"
  write_config "$config" "目标群"
  insert_notification "$database" 89 1 100 "目标群" "成员" "scan deadline fixture"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed the scan-deadline owner"
  local old_event=$(sqlite3 "$store" 'SELECT event_id FROM messages LIMIT 1;')
  sqlite3 "$store" <<'SQL'
CREATE TABLE message_event_aliases(
  alias_event_id TEXT PRIMARY KEY,
  message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  created_at REAL NOT NULL
);
CREATE INDEX message_event_aliases_message_idx
  ON message_event_aliases(message_id);
WITH RECURSIVE sequence(value) AS(
  SELECT 1 UNION ALL SELECT value + 1 FROM sequence WHERE value < 32
)
INSERT INTO message_event_aliases(alias_event_id, message_id, created_at)
SELECT 'scan-deadline-alias-' || value, (SELECT id FROM messages LIMIT 1), 1
FROM sequence;
SQL
  swiftc -swift-version 5 "$listener" -lsqlite3 -o "$deadline_listener" \
    || fail "could not compile the legacy alias scan deadline listener"

  local started_at=$(/usr/bin/python3 -c 'import time; print(time.time())')
  local output
  local exit_code=0
  output=$(WXFOMO_TEST_LEGACY_ALIAS_SCAN_ROW_DELAY=0.05 \
    "$deadline_listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.2 --poll-interval 0.05 2>&1) || exit_code=$?
  local elapsed=$(/usr/bin/python3 -c \
    'import sys, time; print(time.time() - float(sys.argv[1]))' "$started_at")
  (( exit_code != 0 )) || fail "expired legacy alias scan unexpectedly emitted"
  require_contains "$output" "等待指定企业微信群消息超时"
  /usr/bin/python3 -c \
    'import sys; assert float(sys.argv[1]) < 1.5, sys.argv[1]' "$elapsed" \
    || fail "legacy alias scan ignored its once deadline: ${elapsed}s"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "0" \
    && "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_legacy_alias_provenance WHERE version=2026090305;')" == "0" \
    && "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090306;')" == "0" \
    && "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_event_alias_quarantine;')" == "0" \
    && "$(sqlite3 "$store" 'SELECT source_key IS NULL FROM listener_state WHERE singleton_id=1;')" == "1" \
    && "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "1" \
    && "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_event_aliases;')" == "32" \
    && "$(sqlite3 "$store" 'SELECT event_id FROM messages LIMIT 1;')" == "$old_event" ]] \
    || fail "expired legacy alias scan committed partial migration state"

  exit_code=0
  output=$("$deadline_listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 1 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "scan-deadline restart unexpectedly emitted"
  require_contains "$output" "等待指定企业微信群消息超时"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" \
    && "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_legacy_alias_provenance WHERE version=2026090305;')" == "1" \
    && "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "1" \
    && "$(sqlite3 "$store" "SELECT COUNT(*) FROM messages WHERE event_id='$old_event';")" == "0" ]] \
    || fail "scan-deadline fixture did not converge without the slow hook"
}

test_reads_config_and_outputs_only_an_exact_group() {
  local database="$fixture_dir/exact.db"
  local config="$fixture_dir/exact/groups.txt"
  make_database "$database"
  write_config "$config" "目标群"
  insert_notification "$database" 1 1 100 "目标群" "张三" "配置命中消息"

  local output
  output=$(swift "$listener" --database "$database" --config "$config" \
    --include-existing --once --timeout 1 2>&1) || fail "exact group command failed: $output"
  require_contains "$output" "[目标群] 张三：配置命中消息"
}

test_rejects_direct_chat_and_group_name_substrings() {
  local database="$fixture_dir/direct.db"
  local config="$fixture_dir/direct/groups.txt"
  make_database "$database"
  write_config "$config" "目标群"
  insert_notification "$database" 1 1 100 "目标群客服" "" "张三：DIRECT_PRIVATE"

  local output
  local exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" \
    --include-existing --once --timeout 0.2 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "direct chat unexpectedly matched"
  require_contains "$output" "等待指定企业微信群消息超时"
  require_absent "$output" "DIRECT_PRIVATE"

  local collision_database="$fixture_dir/direct-collision.db"
  make_database "$collision_database"
  insert_notification "$collision_database" 1 1 100 "目标群" "" "张三：EXACT_TITLE_PRIVATE" 0

  exit_code=0
  output=$(swift "$listener" --database "$collision_database" --config "$config" \
    --include-existing --once --timeout 0.2 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "same-title direct chat unexpectedly matched"
  require_contains "$output" "等待指定企业微信群消息超时"
  require_absent "$output" "EXACT_TITLE_PRIVATE"
}

test_rejects_personal_wechat_source() {
  local database="$fixture_dir/personal-wechat.db"
  local config="$fixture_dir/personal-wechat/groups.txt"
  make_database "$database"
  write_config "$config" "目标群"
  insert_notification "$database" 1 2 100 "目标群" "张三" "PERSONAL_WECHAT_PRIVATE"

  local output
  local exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" \
    --include-existing --once --timeout 0.2 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "personal WeChat notification unexpectedly matched"
  require_absent "$output" "PERSONAL_WECHAT_PRIVATE"
}

test_saves_and_reuses_cli_groups() {
  local database="$fixture_dir/save.db"
  local config="$fixture_dir/saved/groups.txt"
  make_database "$database"
  insert_notification "$database" 1 1 100 "保存群" "李四" "保存配置消息"

  local first_output
  first_output=$(swift "$listener" --database "$database" --config "$config" \
    --group "保存群" --save-groups --include-existing --once --timeout 1 2>&1) \
    || fail "save groups command failed: $first_output"
  [[ "$(<"$config")" == "保存群" ]] || fail "saved group configuration mismatch"
  [[ "$(stat -f %Lp "${config:h}")" == "700" ]] || fail "config directory mode is not 0700"
  [[ "$(stat -f %Lp "$config")" == "600" ]] || fail "config file mode is not 0600"

  local second_output
  second_output=$(swift "$listener" --database "$database" --config "$config" \
    --store "$fixture_dir/saved-reuse.sqlite3" --include-existing --once --timeout 1 2>&1) \
    || fail "saved config was not reused: $second_output"
  require_contains "$second_output" "[保存群] 李四：保存配置消息"
}

test_rejects_conflicting_sender_fields() {
  local database="$fixture_dir/sender-conflict.db"
  local config="$fixture_dir/sender-conflict/groups.txt"
  make_database "$database"
  write_config "$config" "目标群"
  insert_notification "$database" 1 1 100 "目标群" "李四" "张三：CONFLICT_PRIVATE"

  local output
  local exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" \
    --include-existing --once --timeout 0.2 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "conflicting sender fields unexpectedly matched"
  require_absent "$output" "CONFLICT_PRIVATE"
}

test_paginates_large_same_timestamp_history_without_replay() {
  local database="$fixture_dir/large-history.db"
  local config="$fixture_dir/large-history/groups.txt"
  local output_file="$fixture_dir/large-history-output.txt"
  make_database "$database"
  write_config "$config" "目标群"
  local target_payload=$(payload_hex "目标群" "历史成员" "HISTORICAL_REPLAY")
  local other_payload=$(payload_hex "其他群" "成员" "历史消息")
  sqlite3 "$database" <<SQL
INSERT INTO record(rec_id,app_id,uuid,data,request_date,request_last_date,delivered_date,presented,style)
VALUES(1,1,X'0000000000000001',X'$target_payload',1,1,1,1,1);
WITH RECURSIVE sequence(value) AS (
  SELECT 2
  UNION ALL
  SELECT value + 1 FROM sequence WHERE value < 50101
)
INSERT INTO record(rec_id,app_id,uuid,data,request_date,request_last_date,delivered_date,presented,style)
SELECT value,1,randomblob(16),X'$other_payload',1,1,1,1,1 FROM sequence;
SQL

  swift "$listener" --database "$database" --config "$config" --once \
    --timeout 8 --poll-interval 0.05 > "$output_file" 2>&1 &
  local listener_pid=$!
  local ready=0
  local attempt
  for attempt in {1..200}; do
    if [[ -f "$output_file" ]] && rg -q --fixed-strings "监听已启动" "$output_file"; then
      ready=1
      break
    fi
    kill -0 "$listener_pid" 2>/dev/null || break
    sleep 0.05
  done
  (( ready == 1 )) || fail "large-history listener did not report readiness"

  insert_notification "$database" 0 1 100000 "目标群" "新成员" "大历史库后的新消息"
  local exit_code=0
  wait "$listener_pid" || exit_code=$?
  local output=$(<"$output_file")
  (( exit_code == 0 )) || fail "large-history listener missed new message: $output"
  require_contains "$output" "[目标群] 新成员：大历史库后的新消息"
  require_absent "$output" "HISTORICAL_REPLAY"
}

test_exits_on_permanent_database_errors() {
  local database="$fixture_dir/invalid-schema.db"
  local config="$fixture_dir/invalid-schema/groups.txt"
  sqlite3 "$database" "CREATE TABLE unrelated(value INTEGER);"
  write_config "$config" "目标群"

  local output
  local exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" \
    --once --timeout 2 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "invalid notification database unexpectedly succeeded"
  require_contains "$output" "通知数据库读取失败"
  require_absent "$output" "将继续重试"
  require_absent "$output" "等待指定企业微信群消息超时"
}

test_persists_verified_messages_idempotently() {
  local database="$fixture_dir/persist-source.db"
  local config="$fixture_dir/persist/groups.txt"
  local store="$fixture_dir/persist/messages.sqlite3"
  make_database "$database"
  write_config "$config" "目标群"
  insert_notification "$database" 41 1 100 "目标群" "张三" "持久化消息"

  swift "$listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1
  swift "$listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 0.2 >/dev/null 2>&1 || true

  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "1" ]] \
    || fail "persisted message was not idempotent"
  [[ "$(sqlite3 "$store" 'SELECT group_name||char(9)||sender_display_name||char(9)||content FROM messages;')" \
    == $'目标群\t张三\t持久化消息' ]] || fail "persisted message fields mismatch"
  [[ "$(stat -f %Lp "${store:h}")" == "700" ]] || fail "store directory mode is not 0700"
  [[ "$(stat -f %Lp "$store")" == "600" ]] || fail "store file mode is not 0600"
  [[ "$(sqlite3 "$store" "SELECT group_names_json FROM listener_state WHERE singleton_id=1;")" \
    == '["目标群"]' ]] || fail "listener group snapshot mismatch"
  [[ "$(sqlite3 "$store" "SELECT heartbeat_at > 0 FROM listener_state WHERE singleton_id=1;")" == "1" ]] \
    || fail "listener heartbeat was not persisted"
  [[ "$(sqlite3 "$store" "SELECT cursor_timestamp=100 AND cursor_record_id=41 FROM listener_state WHERE singleton_id=1;")" == "1" ]] \
    || fail "listener cursor checkpoint mismatch"
}

test_retries_temporary_persistence_locks_without_losing_the_notification() {
  local database="$fixture_dir/persist-locked-source.db"
  local config="$fixture_dir/persist-locked/groups.txt"
  local store="$fixture_dir/persist-locked/messages.sqlite3"
  local output_file="$fixture_dir/persist-locked-output.txt"
  make_database "$database"
  write_config "$config" "目标群"

  swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 4 --poll-interval 0.05 > "$output_file" 2>&1 &
  local listener_pid=$!
  local ready=0
  local attempt
  for attempt in {1..100}; do
    if [[ -f "$output_file" ]] && rg -q --fixed-strings "监听已启动" "$output_file"; then
      ready=1
      break
    fi
    kill -0 "$listener_pid" 2>/dev/null || break
    sleep 0.05
  done
  (( ready == 1 )) || fail "persistence-error listener did not report readiness"

  { print -- "BEGIN EXCLUSIVE;"; sleep 1.5; print -- "COMMIT;"; } | sqlite3 "$store" >/dev/null &
  local lock_pid=$!
  sleep 0.1
  insert_notification "$database" 42 1 101 "目标群" "张三" "锁定消息库"

  local exit_code=0
  wait "$listener_pid" || exit_code=$?
  wait "$lock_pid"
  (( exit_code == 0 )) || fail "temporary message-store lock lost the notification: $(<"$output_file")"
  require_contains "$(<"$output_file")" "[目标群] 张三：锁定消息库"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM messages WHERE content='锁定消息库';")" == "1" ]] \
    || fail "retried notification was not persisted exactly once"
}

test_retries_a_store_lock_during_listener_startup() {
  local database="$fixture_dir/startup-locked-source.db"
  local config="$fixture_dir/startup-locked/groups.txt"
  local store="$fixture_dir/startup-locked/messages.sqlite3"
  make_database "$database"
  write_config "$config" "目标群"

  swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.2 --poll-interval 0.05 >/dev/null 2>&1 || true
  [[ -f "$store" ]] || fail "startup-lock fixture store was not initialized"

  { print -- "BEGIN EXCLUSIVE;"; sleep 4; print -- "COMMIT;"; } \
    | sqlite3 "$store" >/dev/null &
  local lock_pid=$!
  sleep 0.1
  insert_notification "$database" 81 1 501 "目标群" "启动成员" "启动锁恢复消息"

  local output
  local exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 8 --poll-interval 0.05 2>&1) || exit_code=$?
  wait "$lock_pid"
  (( exit_code == 0 )) || fail "listener did not retry its locked startup writes: $output"
  require_contains "$output" "[目标群] 启动成员：启动锁恢复消息"
}

test_resets_the_checkpoint_when_the_notification_source_changes() {
  local first_database="$fixture_dir/source-identity-first.db"
  local second_database="$fixture_dir/source-identity-second.db"
  local config="$fixture_dir/source-identity/groups.txt"
  local store="$fixture_dir/source-identity/messages.sqlite3"
  local output_file="$fixture_dir/source-identity-output.txt"
  make_database "$first_database"
  make_database "$second_database"
  write_config "$config" "目标群"
  insert_notification "$first_database" 90 1 900 "目标群" "旧源成员" "旧源基线"

  swift "$listener" --database "$first_database" --config "$config" --store "$store" \
    --once --timeout 0.2 --poll-interval 0.05 >/dev/null 2>&1 || true
  [[ "$(sqlite3 "$store" "SELECT cursor_timestamp=900 AND cursor_record_id=90 FROM listener_state WHERE singleton_id=1;")" == "1" ]] \
    || fail "source-identity fixture did not establish a high checkpoint"

  swift "$listener" --database "$second_database" --config "$config" --store "$store" \
    --once --timeout 3 --poll-interval 0.05 > "$output_file" 2>&1 &
  local listener_pid=$!
  local ready=0
  local attempt
  for attempt in {1..100}; do
    if [[ -f "$output_file" ]] && rg -q --fixed-strings "监听已启动" "$output_file"; then
      ready=1
      break
    fi
    kill -0 "$listener_pid" 2>/dev/null || break
    sleep 0.05
  done
  if (( ready != 1 )); then
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
    fail "source-change listener did not report readiness: $(<"$output_file")"
  fi
  insert_notification "$second_database" 1 1 100 "目标群" "新源成员" "低时间戳新源消息"
  local exit_code=0
  wait "$listener_pid" || exit_code=$?
  (( exit_code == 0 )) || fail "source-specific checkpoint skipped the new source: $(<"$output_file")"
  require_contains "$(<"$output_file")" "[目标群] 新源成员：低时间戳新源消息"
  [[ "$(sqlite3 "$store" "SELECT source_key IS NOT NULL AND cursor_timestamp=100 AND cursor_record_id=1 FROM listener_state WHERE singleton_id=1;")" == "1" ]] \
    || fail "new notification source identity/checkpoint was not persisted"
}

test_rebinds_a_live_listener_after_atomic_source_replacement() {
  local database="$fixture_dir/live-source.db"
  local old_database="$fixture_dir/live-source-old.db"
  local replacement="$fixture_dir/live-source-replacement.db"
  local atomic_replacement="$fixture_dir/live-source-atomic-replacement.db"
  local config="$fixture_dir/live-source/groups.txt"
  local store="$fixture_dir/live-source/messages.sqlite3"
  local output_file="$fixture_dir/live-source-output.txt"
  make_database "$database"
  make_database "$replacement"
  make_database "$atomic_replacement"
  write_config "$config" "目标群"
  insert_notification_without_uuid "$database" 7 900 "其他群" "旧源成员" "旧源基线"
  insert_notification_without_uuid "$replacement" 7 100 "其他群" "中间源成员" "缺失后恢复"
  insert_notification_without_uuid "$atomic_replacement" 7 50 "目标群" "新源成员" "原子替换消息"

  swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 5 --poll-interval 0.05 > "$output_file" 2>&1 &
  local listener_pid=$!
  local ready=0
  local attempt
  for attempt in {1..100}; do
    if [[ -f "$output_file" ]] && rg -q --fixed-strings "监听已启动" "$output_file"; then
      ready=1
      break
    fi
    kill -0 "$listener_pid" 2>/dev/null || break
    sleep 0.05
  done
  if (( ready != 1 )); then
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
    fail "live-replacement listener did not report readiness: $(<"$output_file")"
  fi
  local old_source_key=$(sqlite3 "$store" \
    'SELECT source_key FROM listener_state WHERE singleton_id=1;')

  mv "$database" "$old_database"
  local inactive=0
  for attempt in {1..40}; do
    if [[ "$(sqlite3 "$store" 'SELECT heartbeat_at=0 FROM listener_state WHERE singleton_id=1;')" == "1" ]]; then
      inactive=1
      break
    fi
    kill -0 "$listener_pid" 2>/dev/null || break
    sleep 0.05
  done
  if (( inactive != 1 )); then
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
    fail "listener kept reporting an active heartbeat while its source was missing"
  fi

  mv "$replacement" "$database"
  local replacement_source_key=""
  local rebound=0
  for attempt in {1..100}; do
    replacement_source_key=$(sqlite3 "$store" \
      'SELECT source_key FROM listener_state WHERE singleton_id=1;')
    if [[ "$replacement_source_key" != "$old_source_key" ]] \
      && [[ "$(sqlite3 "$store" 'SELECT heartbeat_at>0 AND cursor_timestamp=100 AND cursor_record_id=7 FROM listener_state WHERE singleton_id=1;')" == "1" ]]; then
      rebound=1
      break
    fi
    kill -0 "$listener_pid" 2>/dev/null || break
    sleep 0.05
  done
  if (( rebound != 1 )); then
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
    fail "listener did not recover and rebind after its source was missing: $(<"$output_file")"
  fi

  mv -f "$atomic_replacement" "$database"
  local exit_code=0
  wait "$listener_pid" || exit_code=$?
  (( exit_code == 0 )) \
    || fail "listener did not recover from live atomic source replacement: $(<"$output_file")"
  require_contains "$(<"$output_file")" "[目标群] 新源成员：原子替换消息"
  [[ "$(sqlite3 "$store" "SELECT source_key <> '$replacement_source_key' AND cursor_timestamp=50 AND cursor_record_id=7 FROM listener_state WHERE singleton_id=1;")" == "1" ]] \
    || fail "rename-over replacement did not atomically rebind its source and low checkpoint"
}

test_rebinds_when_atomic_replace_lands_between_validation_and_fetch() {
  local database="$fixture_dir/validation-fetch-source.db"
  local replacement="$fixture_dir/validation-fetch-replacement.db"
  local config="$fixture_dir/validation-fetch/groups.txt"
  local store="$fixture_dir/validation-fetch/messages.sqlite3"
  local output_file="$fixture_dir/validation-fetch-output.txt"
  make_database "$database"
  make_database "$replacement"
  write_config "$config" "目标群"
  insert_notification_without_uuid "$database" 7 900 "其他群" "旧源成员" "旧源基线"
  insert_notification_without_uuid "$replacement" 7 50 "目标群" "新源成员" "验证与读取之间替换"

  WXFOMO_TEST_STOP_AFTER_SOURCE_VALIDATION=1 swift "$listener" \
    --database "$database" --config "$config" --store "$store" \
    --once --timeout 8 --poll-interval 0.05 > "$output_file" 2>&1 &
  local listener_pid=$!
  local stopped=0
  local attempt
  for attempt in {1..200}; do
    local state=$(ps -o state= -p "$listener_pid" 2>/dev/null || true)
    if [[ "$state" == *T* ]]; then
      stopped=1
      break
    fi
    kill -0 "$listener_pid" 2>/dev/null || break
    sleep 0.05
  done
  if (( stopped != 1 )); then
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
    fail "listener did not stop at the deterministic validation/fetch race point: $(<"$output_file")"
  fi

  mv -f "$replacement" "$database"
  kill -CONT "$listener_pid"
  local exit_code=0
  while true; do
    exit_code=0
    wait "$listener_pid" || exit_code=$?
    (( exit_code == 145 || exit_code == 19 )) || break
  done
  (( exit_code == 0 )) \
    || fail "listener exited on validation/fetch source race: $(<"$output_file")"
  require_contains "$(<"$output_file")" "[目标群] 新源成员：验证与读取之间替换"
  [[ "$(sqlite3 "$store" 'SELECT heartbeat_at>0 AND cursor_timestamp=50 AND cursor_record_id=7 FROM listener_state WHERE singleton_id=1;')" == "1" ]] \
    || fail "listener did not rebind/checkpoint after validation/fetch source race"
}

test_retries_initial_source_validation_after_atomic_replacement() {
  local database="$fixture_dir/source-validation-source.db"
  local replacement="$fixture_dir/source-validation-replacement.db"
  local config="$fixture_dir/source-validation/groups.txt"
  local store="$fixture_dir/source-validation/messages.sqlite3"
  local output_file="$fixture_dir/source-validation-output.txt"
  make_database "$database"
  make_database "$replacement"
  write_config "$config" "目标群"

  WXFOMO_TEST_STOP_BEFORE_SOURCE_VALIDATION_CONFIRMATION=1 swift "$listener" \
    --database "$database" --config "$config" --store "$store" \
    --once --timeout 8 --poll-interval 0.05 > "$output_file" 2>&1 &
  local listener_pid=$!
  local stopped=0
  local attempt
  for attempt in {1..200}; do
    local state=$(ps -o state= -p "$listener_pid" 2>/dev/null || true)
    if [[ "$state" == *T* ]]; then
      stopped=1
      break
    fi
    kill -0 "$listener_pid" 2>/dev/null || break
    sleep 0.05
  done
  if (( stopped != 1 )); then
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
    fail "listener did not stop before source validation confirmation: $(<"$output_file")"
  fi

  mv -f "$replacement" "$database"
  kill -CONT "$listener_pid"
  local ready=0
  for attempt in {1..200}; do
    if [[ -f "$output_file" ]] && rg -q --fixed-strings "监听已启动" "$output_file"; then
      ready=1
      break
    fi
    kill -0 "$listener_pid" 2>/dev/null || break
    sleep 0.05
  done
  if (( ready != 1 )); then
    wait "$listener_pid" 2>/dev/null || true
    fail "listener exited during initial source validation race: $(<"$output_file")"
  fi

  insert_notification_without_uuid "$database" 8 50 "目标群" "新源成员" "验证确认后消息"
  local exit_code=0
  while true; do
    exit_code=0
    wait "$listener_pid" || exit_code=$?
    (( exit_code == 145 || exit_code == 19 )) || break
  done
  (( exit_code == 0 )) \
    || fail "listener failed after retrying initial source validation: $(<"$output_file")"
  require_contains "$(<"$output_file")" "[目标群] 新源成员：验证确认后消息"
  [[ "$(sqlite3 "$store" 'SELECT heartbeat_at>0 AND cursor_timestamp=50 AND cursor_record_id=8 FROM listener_state WHERE singleton_id=1;')" == "1" ]] \
    || fail "retried source validation did not checkpoint the replacement source"
}

test_rebinds_when_atomic_replace_lands_during_startup() {
  local database="$fixture_dir/startup-race-source.db"
  local replacement="$fixture_dir/startup-race-replacement.db"
  local config="$fixture_dir/startup-race/groups.txt"
  local store="$fixture_dir/startup-race/messages.sqlite3"
  local output_file="$fixture_dir/startup-race-output.txt"
  make_database "$database"
  make_database "$replacement"
  write_config "$config" "目标群"
  insert_notification_without_uuid "$database" 7 900 "其他群" "旧源成员" "启动旧源"
  insert_notification_without_uuid "$replacement" 7 50 "目标群" "新源成员" "启动绑定后替换"

  WXFOMO_TEST_STOP_AFTER_STARTUP_BINDING=1 swift "$listener" \
    --database "$database" --config "$config" --store "$store" \
    --once --timeout 8 --poll-interval 0.05 > "$output_file" 2>&1 &
  local listener_pid=$!
  local stopped=0
  local attempt
  for attempt in {1..200}; do
    local state=$(ps -o state= -p "$listener_pid" 2>/dev/null || true)
    if [[ "$state" == *T* ]]; then
      stopped=1
      break
    fi
    kill -0 "$listener_pid" 2>/dev/null || break
    sleep 0.05
  done
  if (( stopped != 1 )); then
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
    fail "listener did not stop at the startup source-race point: $(<"$output_file")"
  fi

  mv -f "$replacement" "$database"
  kill -CONT "$listener_pid"
  local exit_code=0
  while true; do
    exit_code=0
    wait "$listener_pid" || exit_code=$?
    (( exit_code == 145 || exit_code == 19 )) || break
  done
  (( exit_code == 0 )) \
    || fail "listener exited after a startup atomic replacement: $(<"$output_file")"
  require_contains "$(<"$output_file")" "[目标群] 新源成员：启动绑定后替换"
  [[ "$(sqlite3 "$store" 'SELECT heartbeat_at>0 AND cursor_timestamp=50 AND cursor_record_id=7 FROM listener_state WHERE singleton_id=1;')" == "1" ]] \
    || fail "startup atomic replacement was not rebound and checkpointed"
}

test_uses_source_identity_for_uuidless_rows_in_different_databases() {
  local first_database="$fixture_dir/uuidless-first.db"
  local second_database="$fixture_dir/uuidless-second.db"
  local config="$fixture_dir/uuidless/groups.txt"
  local store="$fixture_dir/uuidless/messages.sqlite3"
  make_database "$first_database"
  make_database "$second_database"
  write_config "$config" "目标群"
  insert_notification_without_uuid "$first_database" 7 100 "目标群" "张三" "第一个无 UUID 库"
  insert_notification_without_uuid "$second_database" 7 100 "目标群" "李四" "第二个无 UUID 库"

  local first_source_key=$(source_key_for "$first_database")
  local second_source_key=$(source_key_for "$second_database")
  local expected_first=$(WXFOMO_PRINT_UUIDLESS_SOURCE_IDENTITY="$first_source_key" \
    WXFOMO_PRINT_UUIDLESS_ROW_ID=7 zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "native mapper could not map the first UUID-less source"
  local expected_second=$(WXFOMO_PRINT_UUIDLESS_SOURCE_IDENTITY="$second_source_key" \
    WXFOMO_PRINT_UUIDLESS_ROW_ID=7 zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "native mapper could not map the second UUID-less source"

  swift "$listener" --database "$first_database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "first UUID-less source was not persisted"
  swift "$listener" --database "$second_database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "second UUID-less source collided with the first"

  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "2" ]] \
    || fail "same rowID from two UUID-less sources collided"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(DISTINCT event_id) FROM messages;')" == "2" ]] \
    || fail "UUID-less source identities did not produce distinct event IDs"
  [[ "$(sqlite3 "$store" "SELECT event_id FROM messages WHERE content='第一个无 UUID 库';")" == "$expected_first" ]] \
    || fail "standalone and native mappers disagreed for the first UUID-less source"
  [[ "$(sqlite3 "$store" "SELECT event_id FROM messages WHERE content='第二个无 UUID 库';")" == "$expected_second" ]] \
    || fail "standalone and native mappers disagreed for the second UUID-less source"
}

test_fences_an_old_listener_after_a_new_instance_takes_ownership() {
  local database="$fixture_dir/instance-fence-source.db"
  local config="$fixture_dir/instance-fence/groups.txt"
  local store="$fixture_dir/instance-fence/messages.sqlite3"
  local first_output="$fixture_dir/instance-fence-first.txt"
  make_database "$database"
  write_config "$config" "目标群"

  swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 15 --poll-interval 0.05 > "$first_output" 2>&1 &
  local first_pid=$!
  local ready=0
  local attempt
  for attempt in {1..100}; do
    if [[ -f "$first_output" ]] && rg -q --fixed-strings "监听已启动" "$first_output"; then
      ready=1
      break
    fi
    kill -0 "$first_pid" 2>/dev/null || break
    sleep 0.05
  done
  if (( ready != 1 )); then
    kill "$first_pid" 2>/dev/null || true
    wait "$first_pid" 2>/dev/null || true
    fail "first ownership listener did not report readiness"
  fi

  swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.3 --poll-interval 0.05 >/dev/null 2>&1 || true
  local fenced=0
  for attempt in {1..40}; do
    if ! kill -0 "$first_pid" 2>/dev/null; then
      fenced=1
      break
    fi
    sleep 0.05
  done
  if (( fenced != 1 )); then
    kill "$first_pid" 2>/dev/null || true
    wait "$first_pid" 2>/dev/null || true
    fail "old listener kept heartbeating after a new instance took ownership"
  fi
  wait "$first_pid" 2>/dev/null || true
  require_contains "$(<"$first_output")" "监听实例已被替换"
}

test_recovers_an_uncheckpointed_notification_after_restart() {
  local database="$fixture_dir/recovery-source.db"
  local config="$fixture_dir/recovery/groups.txt"
  local store="$fixture_dir/recovery/messages.sqlite3"
  local first_output="$fixture_dir/recovery-first-output.txt"
  make_database "$database"
  write_config "$config" "目标群"

  swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 5 --poll-interval 0.05 > "$first_output" 2>&1 &
  local listener_pid=$!
  local ready=0
  local attempt
  for attempt in {1..100}; do
    if [[ -f "$first_output" ]] && rg -q --fixed-strings "监听已启动" "$first_output"; then
      ready=1
      break
    fi
    kill -0 "$listener_pid" 2>/dev/null || break
    sleep 0.05
  done
  (( ready == 1 )) || fail "recovery listener did not report readiness"

  { print -- "BEGIN EXCLUSIVE;"; sleep 1.5; print -- "COMMIT;"; } | sqlite3 "$store" >/dev/null &
  local lock_pid=$!
  sleep 0.1
  insert_notification "$database" 43 1 102 "目标群" "李四" "重启恢复消息"
  sleep 0.2
  kill "$listener_pid" 2>/dev/null || true
  wait "$listener_pid" 2>/dev/null || true
  wait "$lock_pid"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "0" ]] \
    || fail "message committed while its checkpoint was locked"
  [[ "$(sqlite3 "$store" "SELECT cursor_timestamp=0 AND cursor_record_id=-9223372036854775808 FROM listener_state WHERE singleton_id=1;")" == "1" ]] \
    || fail "checkpoint advanced before the message transaction committed"

  local output
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 2 --poll-interval 0.05 2>&1) \
    || fail "restart did not recover uncheckpointed notification: $output"
  require_contains "$output" "[目标群] 李四：重启恢复消息"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM messages WHERE content='重启恢复消息';")" == "1" ]] \
    || fail "recovered notification was not persisted exactly once"
}

test_replays_a_bound_source_with_a_null_cursor_after_interruption() {
  local database="$fixture_dir/pending-source-replay.db"
  local config="$fixture_dir/pending-source-replay/groups.txt"
  local store="$fixture_dir/pending-source-replay/messages.sqlite3"
  make_database "$database"
  write_config "$config" "目标群"

  local initial_exit=0
  swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.2 --poll-interval 0.05 >/dev/null 2>&1 || initial_exit=$?
  (( initial_exit != 0 )) || fail "empty source unexpectedly emitted during crash-state setup"
  [[ "$(sqlite3 "$store" 'SELECT source_key IS NOT NULL AND cursor_timestamp IS NOT NULL AND cursor_record_id IS NOT NULL FROM listener_state WHERE singleton_id=1;')" == "1" ]] \
    || fail "crash-state setup did not bind and baseline the source"

  sqlite3 "$store" \
    'UPDATE listener_state SET cursor_timestamp=NULL,cursor_record_id=NULL WHERE singleton_id=1;'
  insert_notification_without_uuid "$database" 7 50 "目标群" "恢复成员" "绑定后重放前崩溃"
  local output
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 1 --poll-interval 0.05 2>&1) \
    || fail "bound source with a NULL cursor was baselined after restart: $output"
  require_contains "$output" "[目标群] 恢复成员：绑定后重放前崩溃"
  [[ "$(sqlite3 "$store" 'SELECT cursor_timestamp=50 AND cursor_record_id=7 FROM listener_state WHERE singleton_id=1;')" == "1" ]] \
    || fail "pending source replay did not restore the durable checkpoint"
}

test_waits_for_initial_source_schema_before_reporting_ready() {
  local isolated_home="$fixture_dir/delayed-source-home"
  local darwin_user_dir="$fixture_dir/delayed-source-darwin"
  local database="$darwin_user_dir/com.apple.notificationcenter/db2/db"
  local config="$fixture_dir/delayed-source/groups.txt"
  local store="$fixture_dir/delayed-source/messages.sqlite3"
  local output_file="$fixture_dir/delayed-source-output.txt"
  local getconf="$fixture_dir/delayed-source-bin/getconf"
  local getconf_count="$fixture_dir/delayed-source-getconf-count.txt"
  write_config "$config" "目标群"
  mkdir -p "$isolated_home" "${database:h}"
  make_fake_getconf "$getconf"

  env -u DARWIN_USER_DIR HOME="$isolated_home" \
    WXFOMO_TEST_GETCONF_EXECUTABLE="$getconf" \
    WXFOMO_TEST_GETCONF_RESULT="$darwin_user_dir" \
    WXFOMO_TEST_GETCONF_COUNT_FILE="$getconf_count" \
    swift "$listener" --config "$config" --store "$store" \
    --include-existing --once --timeout 6 --poll-interval 0.05 > "$output_file" 2>&1 &
  local listener_pid=$!
  sleep 2.5
  kill -0 "$listener_pid" 2>/dev/null || fail "listener exited before delayed source schema appeared"
  require_absent "$(<"$output_file")" "监听已启动"

  make_database "$database"
  insert_notification "$database" 71 1 401 "目标群" "延迟成员" "延迟数据源消息"
  local exit_code=0
  wait "$listener_pid" || exit_code=$?
  (( exit_code == 0 )) || fail "listener did not recover when source schema appeared: $(<"$output_file")"
  require_contains "$(<"$output_file")" "[目标群] 延迟成员：延迟数据源消息"
  [[ "$(wc -l < "$getconf_count" | tr -d ' ')" == "1" ]] \
    || fail "default discovery spawned getconf more than once while waiting for a missing source"
}

test_default_discovery_retries_an_existing_partial_schema_at_one_hertz() {
  local isolated_home="$fixture_dir/partial-source-home"
  local darwin_user_dir="$fixture_dir/partial-source-darwin"
  local database="$isolated_home/Library/Group Containers/group.com.apple.usernoted/db2/db"
  local config="$fixture_dir/partial-source/groups.txt"
  local store="$fixture_dir/partial-source/messages.sqlite3"
  local output_file="$fixture_dir/partial-source-output.txt"
  local getconf="$fixture_dir/partial-source-bin/getconf"
  local getconf_count="$fixture_dir/partial-source-getconf-count.txt"
  mkdir -p "${database:h}" "$darwin_user_dir"
  write_config "$config" "目标群"
  make_fake_getconf "$getconf"
  sqlite3 "$database" 'VACUUM;'

  env -u DARWIN_USER_DIR HOME="$isolated_home" \
    WXFOMO_TEST_GETCONF_EXECUTABLE="$getconf" \
    WXFOMO_TEST_GETCONF_RESULT="$darwin_user_dir" \
    WXFOMO_TEST_GETCONF_COUNT_FILE="$getconf_count" \
    swift "$listener" --config "$config" --store "$store" \
    --include-existing --once --timeout 7 --poll-interval 0.05 > "$output_file" 2>&1 &
  local listener_pid=$!
  local attempt
  for attempt in {1..100}; do
    [[ -f "$getconf_count" ]] && break
    kill -0 "$listener_pid" 2>/dev/null || break
    sleep 0.05
  done
  [[ -f "$getconf_count" ]] || fail "partial-schema fixture never reached default discovery"
  kill -0 "$listener_pid" 2>/dev/null \
    || fail "default discovery treated an empty existing SQLite source as permanent"
  require_absent "$(<"$output_file")" "监听已启动"
  sleep 1.2
  kill -0 "$listener_pid" 2>/dev/null \
    || fail "default discovery did not retain an empty source across one retry interval"

  sqlite3 "$database" \
    'CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR, badge INTEGER NULL); INSERT INTO app(app_id,identifier,badge) VALUES(1,"com.tencent.WeWorkMac",0);'
  sleep 1.3
  kill -0 "$listener_pid" 2>/dev/null \
    || fail "default discovery treated a one-table source schema as permanent"
  require_absent "$(<"$output_file")" "监听已启动"

  sqlite3 "$database" <<'SQL'
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
SQL
  insert_notification "$database" 72 1 402 "目标群" "分段成员" "分段数据源消息"
  local exit_code=0
  wait "$listener_pid" || exit_code=$?
  (( exit_code == 0 )) \
    || fail "default discovery did not recover after partial schema completion: $(<"$output_file")"
  require_contains "$(<"$output_file")" "[目标群] 分段成员：分段数据源消息"
  [[ "$(wc -l < "$getconf_count" | tr -d ' ')" == "1" ]] \
    || fail "partial-schema discovery spawned getconf more than once"
}

test_default_discovery_reports_an_inaccessible_ancestor_without_missing_retry() {
  local isolated_home="$fixture_dir/ancestor-permission-home"
  local darwin_user_dir="$fixture_dir/ancestor-permission-darwin"
  local database="$isolated_home/Library/Group Containers/group.com.apple.usernoted/db2/db"
  local inaccessible_ancestor="$isolated_home/Library"
  local config="$fixture_dir/ancestor-permission/groups.txt"
  local store="$fixture_dir/ancestor-permission/messages.sqlite3"
  local getconf="$fixture_dir/ancestor-permission-bin/getconf"
  local getconf_count="$fixture_dir/ancestor-permission-getconf-count.txt"
  mkdir -p "${database:h}" "$darwin_user_dir"
  write_config "$config" "目标群"
  make_fake_getconf "$getconf"
  make_database "$database"
  chmod 000 "$inaccessible_ancestor"

  local output
  local exit_code=0
  output=$(env -u DARWIN_USER_DIR HOME="$isolated_home" \
    WXFOMO_TEST_GETCONF_EXECUTABLE="$getconf" \
    WXFOMO_TEST_GETCONF_RESULT="$darwin_user_dir" \
    WXFOMO_TEST_GETCONF_COUNT_FILE="$getconf_count" \
    swift "$listener" --config "$config" --store "$store" \
    --once --timeout 2 --poll-interval 0.05 2>&1) || exit_code=$?
  chmod 700 "$inaccessible_ancestor"
  (( exit_code != 0 )) || fail "inaccessible default source ancestor unexpectedly succeeded"
  require_contains "$output" "Notification Center 数据库路径权限不足"
  require_absent "$output" "等待指定企业微信群消息超时"
  require_absent "$output" "$isolated_home"
  [[ "$(wc -l < "$getconf_count" | tr -d ' ')" == "1" ]] \
    || fail "ancestor-permission discovery repeatedly spawned getconf"
}

test_default_discovery_fails_existing_unusable_sources_without_process_churn() {
  local kind
  local output
  for kind in permission corrupt incompatible; do
    local isolated_home="$fixture_dir/permanent-$kind-home"
    local darwin_user_dir="$fixture_dir/permanent-$kind-darwin"
    local database="$isolated_home/Library/Group Containers/group.com.apple.usernoted/db2/db"
    local config="$fixture_dir/permanent-$kind/groups.txt"
    local store="$fixture_dir/permanent-$kind/messages.sqlite3"
    local getconf="$fixture_dir/permanent-$kind-bin/getconf"
    local getconf_count="$fixture_dir/permanent-$kind-getconf-count.txt"
    mkdir -p "${database:h}" "$darwin_user_dir"
    write_config "$config" "目标群"
    make_fake_getconf "$getconf"
    case "$kind" in
      permission)
        sqlite3 "$database" 'CREATE TABLE denied(value INTEGER);'
        chmod 000 "$database"
        ;;
      corrupt)
        print -rn -- 'not-a-sqlite-database' > "$database"
        ;;
      incompatible)
        sqlite3 "$database" 'CREATE TABLE unrelated(value INTEGER);'
        ;;
    esac

    local exit_code=0
    output=$(env -u DARWIN_USER_DIR HOME="$isolated_home" \
      WXFOMO_TEST_GETCONF_EXECUTABLE="$getconf" \
      WXFOMO_TEST_GETCONF_RESULT="$darwin_user_dir" \
      WXFOMO_TEST_GETCONF_COUNT_FILE="$getconf_count" \
      swift "$listener" --config "$config" --store "$store" \
      --once --timeout 2 --poll-interval 0.05 2>&1) || exit_code=$?
    chmod 600 "$database" 2>/dev/null || true
    (( exit_code != 0 )) || fail "$kind default source unexpectedly succeeded"
    require_contains "$output" "Notification Center 数据库"
    require_absent "$output" "等待指定企业微信群消息超时"
    [[ "$(wc -l < "$getconf_count" | tr -d ' ')" == "1" ]] \
      || fail "$kind default source repeatedly spawned getconf"
  done
}

test_checkpoints_undecodable_rows_and_refreshes_heartbeat() {
  local database="$fixture_dir/checkpoint-only-source.db"
  local config="$fixture_dir/checkpoint-only/groups.txt"
  local store="$fixture_dir/checkpoint-only/messages.sqlite3"
  local output_file="$fixture_dir/checkpoint-only-output.txt"
  make_database "$database"
  write_config "$config" "目标群"

  swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 2 --poll-interval 0.05 > "$output_file" 2>&1 &
  local listener_pid=$!
  local ready=0
  local attempt
  for attempt in {1..100}; do
    if [[ -f "$output_file" ]] && rg -q --fixed-strings "监听已启动" "$output_file"; then
      ready=1
      break
    fi
    kill -0 "$listener_pid" 2>/dev/null || break
    sleep 0.05
  done
  (( ready == 1 )) || fail "checkpoint-only listener did not report readiness"
  local first_heartbeat=$(sqlite3 "$store" 'SELECT heartbeat_at FROM listener_state WHERE singleton_id=1;')
  sqlite3 "$database" \
    "INSERT INTO record(rec_id,app_id,uuid,data,request_date,request_last_date,delivered_date,presented,style) VALUES(72,1,X'0000000000000048',X'',402,402,402,1,1);"
  sleep 1.2
  local second_heartbeat=$(sqlite3 "$store" 'SELECT heartbeat_at FROM listener_state WHERE singleton_id=1;')
  [[ "$(sqlite3 "$store" "SELECT cursor_timestamp=402 AND cursor_record_id=72 FROM listener_state WHERE singleton_id=1;")" == "1" ]] \
    || fail "undecodable row was not checkpointed"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "0" ]] \
    || fail "undecodable row created a message"
  python3 - "$first_heartbeat" "$second_heartbeat" <<'PY' \
    || fail "listener heartbeat did not advance"
import sys
raise SystemExit(0 if float(sys.argv[2]) > float(sys.argv[1]) else 1)
PY
  kill "$listener_pid" 2>/dev/null || true
  wait "$listener_pid" 2>/dev/null || true
}

test_uses_one_stable_canonical_event_id_for_notification_updates() {
  local database="$fixture_dir/canonical-source.db"
  local config="$fixture_dir/canonical/groups.txt"
  local store="$fixture_dir/canonical/messages.sqlite3"
  make_database "$database"
  write_config "$config" "目标群"
  insert_notification "$database" 44 1 103 "目标群" "王五" "初始内容"
  local event_seed=$(sqlite3 "$database" "SELECT lower(hex(uuid)) FROM record WHERE rec_id=44;")
  [[ "$event_seed" == "000000000000002c" ]] || fail "canonical UUID fixture changed"
  local expected
  expected=$(WXFOMO_PRINT_CANONICAL_EVENT_ID=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "native mapper could not produce the cross-layer canonical event ID"

  swift "$listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1
  local updated_payload=$(payload_hex "目标群" "王五" "更新后内容")
  sqlite3 "$database" "UPDATE record SET data=X'$updated_payload',request_last_date=104,delivered_date=104 WHERE rec_id=44;"
  local exit_code=0
  swift "$listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 0.2 >/dev/null 2>&1 || exit_code=$?
  (( exit_code != 0 )) || fail "duplicate canonical notification unexpectedly emitted twice"

  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "1" ]] \
    || fail "notification update created a duplicate message"
  [[ "$(sqlite3 "$store" 'SELECT event_id FROM messages;')" == "$expected" ]] \
    || fail "native mapper and standalone listener produced different canonical event IDs"
  [[ "$(sqlite3 "$store" "SELECT cursor_timestamp=104 AND cursor_record_id=44 FROM listener_state WHERE singleton_id=1;")" == "1" ]] \
    || fail "duplicate notification update did not advance the durable checkpoint"
}

test_migrates_actual_precanonical_store_and_preserves_event_aliases() {
  local old_listener="$fixture_dir/precanonical-listener.swift"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the actual pre-c0c20ed listener"
  local compatibility_ids
  compatibility_ids=$(WXFOMO_PRINT_COMPATIBILITY_EVENT_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "production native mapper could not produce compatibility IDs"
  local canonical_event_id=${${(f)compatibility_ids}[1]}
  local legacy_native_event_id=${${(f)compatibility_ids}[2]}
  [[ -n "$canonical_event_id" && -n "$legacy_native_event_id" ]] \
    || fail "production native mapper returned incomplete compatibility IDs"
  local prefix_compatibility_ids
  prefix_compatibility_ids=$(WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "production native mapper could not produce sender-prefix compatibility IDs"
  local -a legacy_prefix_native_event_ids
  legacy_prefix_native_event_ids=("${(@f)prefix_compatibility_ids}")
  (( ${#legacy_prefix_native_event_ids[@]} == 32 )) \
    || fail "old native mapper did not return all policy-valid field/prefix layout IDs"

  local storage_class
  local prefix_alias
  local output
  for storage_class in blob text; do
    local database="$fixture_dir/precanonical-$storage_class-source.db"
    local config="$fixture_dir/precanonical-$storage_class/groups.txt"
    local store="$fixture_dir/precanonical-$storage_class/messages.sqlite3"
    make_database "$database"
    write_config "$config" "目标群"
    if [[ "$storage_class" == "blob" ]]; then
      insert_notification "$database" 44 1 103 "目标群" "王五" "初始内容"
    else
      insert_notification_with_text_uuid "$database" 44 103 "目标群" "王五" "初始内容"
    fi
    swift "$old_listener" --database "$database" --config "$config" --store "$store" \
      --include-existing --once --timeout 1 >/dev/null 2>&1 \
      || fail "pre-c0c20ed listener could not construct the $storage_class UUID store"
    local legacy_lan_event_id=$(sqlite3 "$store" 'SELECT event_id FROM messages;')
    if [[ "$storage_class" == "blob" ]]; then
      [[ "$legacy_lan_event_id" == 44:000000000000002c:* ]] \
        || fail "BLOB UUID legacy fingerprint did not preserve raw bytes"
    else
      [[ "$legacy_lan_event_id" == 44:30303030303030303030303030303263:* ]] \
        || fail "TEXT UUID legacy fingerprint did not preserve the ASCII bytes as hex"
    fi

    # The Notification Center row may have changed before the first canonical-aware launch.
    local updated_payload=$(payload_hex "目标群" "王五" "升级前已更新")
    sqlite3 "$database" \
      "UPDATE record SET data=X'$updated_payload',request_last_date=2000,delivered_date=2000 WHERE rec_id=44;"
    local noise_payload=$(payload_hex "噪声群" "噪声成员" "迁移噪声")
    sqlite3 "$database" <<SQL
WITH RECURSIVE noise(record_id) AS (
  SELECT 1000
  UNION ALL
  SELECT record_id + 1 FROM noise WHERE record_id < 1500
)
INSERT INTO record(
  rec_id, app_id, uuid, data, request_date, request_last_date,
  delivered_date, presented, style
)
SELECT record_id, 1, NULL, X'$noise_payload', record_id - 800,
  record_id - 800, record_id - 800, 1, 1
FROM noise;
SQL
    local exit_code=0
    output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
      --once --timeout 0.3 --poll-interval 0.05 2>&1) || exit_code=$?
    (( exit_code != 0 )) || fail "$storage_class legacy notification was emitted during migration: $output"
    require_contains "$output" "等待指定企业微信群消息超时"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "1" ]] \
      || fail "$storage_class migration inserted a duplicate"
    [[ "$(sqlite3 "$store" 'SELECT event_id FROM messages;')" == "$canonical_event_id" ]] \
      || fail "$storage_class migration did not upgrade the survivor to the canonical event ID"
    [[ "$(sqlite3 "$store" 'SELECT content FROM messages;')" == "升级前已更新" ]] \
      || fail "$storage_class migration did not refresh the survivor from the verified source row"
    [[ "$(sqlite3 "$store" 'SELECT message_count FROM conversations WHERE group_name="目标群";')" == "1" ]] \
      || fail "$storage_class sender-prefix migration drifted the conversation count"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM conversations c WHERE c.message_count != (SELECT COUNT(*) FROM messages m WHERE m.conversation_id=c.id);')" == "0" ]] \
      || fail "$storage_class sender-prefix migration left a conversation count mismatch"
    [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id IN ('$legacy_lan_event_id','$legacy_native_event_id');")" == "2" ]] \
      || fail "$storage_class migration did not preserve old standalone and native aliases"
    [[ "$(sqlite3 "$store" "SELECT m.event_id FROM message_event_aliases a JOIN messages m ON m.id=a.message_id WHERE a.alias_event_id='$legacy_native_event_id';")" == "$canonical_event_id" ]] \
      || fail "$storage_class old native alert ID did not resolve the canonical survivor"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" ]] \
      || fail "$storage_class migration remained pending after source verification"
    for prefix_alias in "${legacy_prefix_native_event_ids[@]}"; do
      [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$prefix_alias' AND message_id=(SELECT id FROM messages LIMIT 1);")" == "1" ]] \
        || fail "$storage_class migration did not preserve sender-prefix alias $prefix_alias"
    done
    PYTHONPATH="$script_dir" /usr/bin/python3 - "$store" "$config" \
      "$legacy_lan_event_id" "${legacy_prefix_native_event_ids[@]}" <<'PY' \
      || fail "$storage_class legacy alias was not readable through the production repository"
import sys

from wxfomo_lan.messages import MessageRepository

aliases = sys.argv[3:]
items = MessageRepository(sys.argv[1], sys.argv[2]).by_event_ids(aliases)
assert len(items) == len(aliases)
assert [item["eventId"] for item in items] == aliases
assert all(item["content"] == "升级前已更新" for item in items)
PY
  done
}

test_upgrades_intermediate_alias_migration_with_historical_and_current_prefixes() {
  local old_listener="$fixture_dir/intermediate-prefix-old-listener.swift"
  local intermediate_listener="$fixture_dir/intermediate-prefix-listener.swift"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the actual pre-c0c20ed listener"
  git show baa877b:scripts/wecom-group-listener.swift > "$intermediate_listener" \
    || fail "could not materialize the intermediate alias listener"

  local prefix_a_output
  prefix_a_output=$(WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not produce revision A prefix IDs"
  local prefix_b_output
  prefix_b_output=$(WXFOMO_PREFIX_SENDER="赵六" WXFOMO_PREFIX_CONTENT="版本 B" \
    WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not produce revision B prefix IDs"
  local -a prefix_a_ids prefix_b_ids all_prefix_ids
  prefix_a_ids=("${(@f)prefix_a_output}")
  prefix_b_ids=("${(@f)prefix_b_output}")
  all_prefix_ids=("${prefix_a_ids[@]}" "${prefix_b_ids[@]}")
  (( ${#prefix_a_ids[@]} == 32 && ${#prefix_b_ids[@]} == 32 )) \
    || fail "old native oracle did not return every valid layout for both revisions"

  local storage_class
  local alias
  local intermediate_exit intermediate_output output exit_code
  for storage_class in blob text; do
    local database="$fixture_dir/intermediate-prefix-$storage_class-source.db"
    local config="$fixture_dir/intermediate-prefix-$storage_class/groups.txt"
    local store="$fixture_dir/intermediate-prefix-$storage_class/messages.sqlite3"
    make_database "$database"
    write_config "$config" "目标群"
    if [[ "$storage_class" == "blob" ]]; then
      insert_notification "$database" 44 1 100 "目标群" "" "王五：初始内容"
    else
      insert_notification_with_text_uuid \
        "$database" 44 100 "目标群" "" "王五：初始内容"
    fi
    swift "$old_listener" --database "$database" --config "$config" --store "$store" \
      --include-existing --once --timeout 1 >/dev/null 2>&1 \
      || fail "pre-canonical listener could not seed $storage_class intermediate fixture"
    local standalone_a=$(sqlite3 "$store" 'SELECT event_id FROM messages LIMIT 1;')

    intermediate_exit=0
    intermediate_output=$(swift "$intermediate_listener" --database "$database" \
      --config "$config" --store "$store" --once --timeout 0.3 \
      --poll-interval 0.05 2>&1) || intermediate_exit=$?
    (( intermediate_exit != 0 )) \
      || fail "$storage_class intermediate listener unexpectedly emitted a duplicate"
    require_contains "$intermediate_output" "等待指定企业微信群消息超时"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" ]] \
      || fail "$storage_class intermediate store did not contain migration marker 2026090301"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "0" ]] \
      || fail "$storage_class intermediate fixture unexpectedly contained the upgrade marker"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "1" ]] \
      || fail "$storage_class intermediate migration did not retain one canonical survivor"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM conversations WHERE message_count=1;')" == "1" ]] \
      || fail "$storage_class intermediate migration drifted the conversation count"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_event_aliases a JOIN messages m ON m.id=a.message_id WHERE a.alias_event_id LIKE printf("%d:%%",m.source_sequence);')" == "1" ]] \
      || fail "$storage_class single-revision fast path did not have exactly one standalone fingerprint"
    local missing_a=0
    for alias in "${prefix_a_ids[@]}"; do
      if [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$alias';")" == "0" ]]; then
        (( missing_a += 1 ))
      fi
    done
    (( missing_a > 0 )) \
      || fail "$storage_class intermediate fixture already contained every new prefix alias"

    local payload_b=$(payload_hex "目标群" "" "赵六 ： 版本 B")
    sqlite3 "$database" \
      "UPDATE record SET data=X'$payload_b',request_last_date=200,delivered_date=200 WHERE rec_id=44;"

    exit_code=0
    output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
      --once --timeout 0.4 --poll-interval 0.05 2>&1) || exit_code=$?
    (( exit_code != 0 )) \
      || fail "$storage_class upgraded store unexpectedly replayed the canonical notification"
    require_contains "$output" "等待指定企业微信群消息超时"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "1" ]] \
      || fail "$storage_class intermediate store did not run the independent prefix upgrade"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090304;')" == "1" ]] \
      || fail "$storage_class intermediate store did not complete the provenance audit"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "1" ]] \
      || fail "$storage_class prefix upgrade created a duplicate message"
    [[ "$(sqlite3 "$store" 'SELECT message_count FROM conversations WHERE group_name="目标群";')" == "1" ]] \
      || fail "$storage_class prefix upgrade drifted the conversation count"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM conversations c WHERE c.message_count != (SELECT COUNT(*) FROM messages m WHERE m.conversation_id=c.id);')" == "0" ]] \
      || fail "$storage_class prefix upgrade left a conversation count mismatch"
    [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$standalone_a' AND message_id=(SELECT id FROM messages LIMIT 1);")" == "1" ]] \
      || fail "$storage_class prefix upgrade lost the stored standalone provenance alias"
    for alias in "${all_prefix_ids[@]}"; do
      [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$alias' AND message_id=(SELECT id FROM messages LIMIT 1);")" == "1" ]] \
        || fail "$storage_class prefix upgrade did not attach historical/current alias $alias"
    done
    PYTHONPATH="$script_dir" /usr/bin/python3 - "$store" "$config" \
      "$standalone_a" "${all_prefix_ids[@]}" <<'PY' \
      || fail "$storage_class upgraded aliases were not readable through the repository"
import sys

from wxfomo_lan.messages import MessageRepository

aliases = sys.argv[3:]
items = MessageRepository(sys.argv[1], sys.argv[2]).by_event_ids(aliases)
assert len(items) == len(aliases)
assert [item["eventId"] for item in items] == aliases
assert all(item["content"] == "初始内容" for item in items)
PY
    local alias_count=$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_event_aliases;')
    exit_code=0
    output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
      --once --timeout 0.2 --poll-interval 0.05 2>&1) || exit_code=$?
    (( exit_code != 0 )) || fail "$storage_class completed upgrade unexpectedly emitted"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "1" ]] \
      || fail "$storage_class upgrade marker was not idempotent"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_event_aliases;')" == "$alias_count" ]] \
      || fail "$storage_class upgrade was not alias-idempotent"
  done
}

test_keeps_prefix_upgrade_pending_after_intermediate_folds_multiple_revisions() {
  local old_listener="$fixture_dir/folded-prefix-old-listener.swift"
  local intermediate_listener="$fixture_dir/folded-prefix-intermediate-listener.swift"
  local round5_listener="$fixture_dir/folded-prefix-round5-listener.swift"
  local database="$fixture_dir/folded-prefix-source.db"
  local config="$fixture_dir/folded-prefix/groups.txt"
  local store="$fixture_dir/folded-prefix/messages.sqlite3"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical folded-revision listener"
  git show baa877b:scripts/wecom-group-listener.swift > "$intermediate_listener" \
    || fail "could not materialize the intermediate folded-revision listener"
  git show 1c5dbff:scripts/wecom-group-listener.swift > "$round5_listener" \
    || fail "could not materialize the round-5 folded-revision listener"

  local prefix_a_output prefix_b_output prefix_c_output
  prefix_a_output=$(WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not enumerate folded revision A"
  prefix_b_output=$(WXFOMO_PREFIX_SENDER="赵六" WXFOMO_PREFIX_CONTENT="版本 B" \
    WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not enumerate folded revision B"
  prefix_c_output=$(WXFOMO_PREFIX_SENDER="孙七" WXFOMO_PREFIX_CONTENT="版本 C" \
    WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not enumerate folded revision C"
  local -a prefix_a_ids prefix_b_ids prefix_c_ids
  prefix_a_ids=("${(@f)prefix_a_output}")
  prefix_b_ids=("${(@f)prefix_b_output}")
  prefix_c_ids=("${(@f)prefix_c_output}")
  (( ${#prefix_a_ids[@]} == 32 && ${#prefix_b_ids[@]} == 32 \
    && ${#prefix_c_ids[@]} == 32 )) \
    || fail "old native oracle did not return complete A/B/C prefix sets"

  make_database "$database"
  write_config "$config" "目标群"
  insert_notification "$database" 44 1 100 "目标群" "" "王五：初始内容"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not persist folded revision A"
  local standalone_a=$(sqlite3 "$store" 'SELECT event_id FROM messages ORDER BY id LIMIT 1;')

  local payload_b=$(payload_hex "目标群" "" "赵六：版本 B")
  sqlite3 "$database" \
    "UPDATE record SET data=X'$payload_b',request_last_date=200,delivered_date=200 WHERE rec_id=44;"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not persist folded revision B"
  local standalone_b=$(sqlite3 "$store" 'SELECT event_id FROM messages ORDER BY id DESC LIMIT 1;')
  [[ "$standalone_a" != "$standalone_b" ]] \
    || fail "folded A/B revisions did not retain distinct standalone IDs"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "2" ]] \
    || fail "folded fixture did not contain two pre-canonical revisions"

  # This ordering is the contract under review: source C already exists when
  # the intermediate build runs marker 301 and overwrites the survivor fields.
  local payload_c=$(payload_hex "目标群" "" "孙七：版本 C")
  sqlite3 "$database" \
    "UPDATE record SET data=X'$payload_c',request_last_date=300,delivered_date=300 WHERE rec_id=44;"
  local intermediate_output
  local intermediate_exit=0
  intermediate_output=$(swift "$intermediate_listener" --database "$database" \
    --config "$config" --store "$store" --once --timeout 0.5 \
    --poll-interval 0.05 2>&1) || intermediate_exit=$?
  (( intermediate_exit != 0 )) \
    || fail "intermediate folded-revision migration unexpectedly emitted: $intermediate_output"
  require_contains "$intermediate_output" "等待指定企业微信群消息超时"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" ]] \
    || fail "intermediate folded-revision fixture did not complete marker 301"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "0" ]] \
    || fail "intermediate folded-revision fixture unexpectedly contained marker 302"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "1" ]] \
    || fail "intermediate marker 301 did not consolidate A/B"
  [[ "$(sqlite3 "$store" 'SELECT sender_display_name || "|" || content FROM messages;')" == "孙七|版本 C" ]] \
    || fail "intermediate marker 301 did not replace survivor fields with C"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id LIKE '44:%';")" == "3" ]] \
    || fail "intermediate store did not retain the A/B/C standalone provenance fingerprints"

  local lost_a=""
  local lost_b=""
  local lost_c=""
  local alias other_alias overlaps
  for alias in "${prefix_a_ids[@]}"; do
    [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$alias';")" == "0" ]] \
      || continue
    overlaps=0
    for other_alias in "${prefix_c_ids[@]}"; do
      [[ "$alias" == "$other_alias" ]] && overlaps=1 && break
    done
    (( overlaps == 0 )) && lost_a=$alias && break
  done
  for alias in "${prefix_b_ids[@]}"; do
    [[ "$alias" != "$lost_a" ]] || continue
    [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$alias';")" == "0" ]] \
      || continue
    overlaps=0
    for other_alias in "${prefix_c_ids[@]}"; do
      [[ "$alias" == "$other_alias" ]] && overlaps=1 && break
    done
    (( overlaps == 0 )) && lost_b=$alias && break
  done
  for alias in "${prefix_c_ids[@]}"; do
    if [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$alias';")" == "0" ]]; then
      lost_c=$alias
      break
    fi
  done
  [[ -n "$lost_a" && -n "$lost_b" && -n "$lost_c" ]] \
    || fail "intermediate marker 301 did not expose distinct lost A/B/C prefix aliases"

  # A lost historical claim must participate in any future owner preflight.
  # Materialize an unrelated exact owner for one such ID; HEAD may not mark
  # the migration complete by expanding C alone and silently ignoring A/B.
  sqlite3 "$store" <<SQL
INSERT INTO messages(
  event_id, conversation_id, group_name, sender_display_name, sender_stable_id,
  content, message_type, observed_at, source_sequence, attachments_json,
  attachment_count, sender_confidence, is_from_self, inserted_at, record_version
)
SELECT '$lost_a', conversation_id, group_name, sender_display_name,
  sender_stable_id, '折叠历史 alias 冲突', message_type, observed_at, 999,
  attachments_json, attachment_count, sender_confidence, is_from_self,
  inserted_at, record_version
FROM messages
ORDER BY id
LIMIT 1;
UPDATE conversations SET message_count=2;
SQL

  local output
  local exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.5 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "folded-provenance prefix upgrade unexpectedly emitted"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "0" ]] \
    || fail "folded A/B provenance was discarded behind marker 302"
  require_contains "$output" "旧原生前缀 ID 升级，迁移保持待完成"
  [[ "$(sqlite3 "$store" "SELECT content FROM messages WHERE event_id='$lost_a';")" == "折叠历史 alias 冲突" ]] \
    || fail "folded historical alias conflict lost exact precedence"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM messages WHERE event_id='$lost_b';")" == "0" \
    && "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$lost_b';")" == "0" ]] \
    || fail "unknown folded revision B aliases were guessed from survivor C"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM messages WHERE event_id='$lost_c';")" == "0" \
    && "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$lost_c';")" == "0" ]] \
    || fail "unresolved folded provenance allowed a partial survivor-C alias write"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM conversations c WHERE c.message_count != (SELECT COUNT(*) FROM messages m WHERE m.conversation_id=c.id);')" == "0" ]] \
    || fail "folded-provenance fail-closed path drifted conversation counts"

  # A round-5 build could already have trusted the folded survivor and written
  # marker 302.  HEAD must supersede that marker with a new provenance audit;
  # otherwise upgrading the application would permanently skip this store.
  local round5_exit=0
  output=$(swift "$round5_listener" --database "$database" --config "$config" \
    --store "$store" --once --timeout 0.5 --poll-interval 0.05 2>&1) \
    || round5_exit=$?
  (( round5_exit != 0 )) || fail "round-5 folded fixture unexpectedly emitted"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "1" ]] \
    || fail "round-5 fixture did not reproduce the stale marker 302"

  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.5 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "superseding provenance audit unexpectedly emitted"
  require_contains "$output" "旧原生前缀 ID 升级，迁移保持待完成"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090304;')" == "0" ]] \
    || fail "superseding audit completed over a stale unsafe marker 302"
  [[ "$(sqlite3 "$store" "SELECT content FROM messages WHERE event_id='$lost_a';")" == "折叠历史 alias 冲突" ]] \
    || fail "superseding audit changed the historical exact owner"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$lost_b';")" == "0" ]] \
    || fail "superseding audit guessed a missing folded-B alias"
}

test_keeps_prefix_upgrade_pending_without_a_version1_semantic_witness() {
  local old_listener="$fixture_dir/version1-witness-old-listener.swift"
  local early_version1_listener="$fixture_dir/version1-witness-early-listener.swift"
  local round5_listener="$fixture_dir/version1-witness-round5-listener.swift"
  local database="$fixture_dir/version1-witness-source.db"
  local config="$fixture_dir/version1-witness/groups.txt"
  local store="$fixture_dir/version1-witness/messages.sqlite3"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical witness listener"
  git show 8089608:scripts/wecom-group-listener.swift > "$early_version1_listener" \
    || fail "could not materialize the early version-1 listener"
  git show 1c5dbff:scripts/wecom-group-listener.swift > "$round5_listener" \
    || fail "could not materialize the round-5 witness-polluting listener"
  make_database "$database"
  write_config "$config" "目标群"
  insert_notification "$database" 44 1 100 "目标群" "" "王五：初始内容"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed the semantic-witness store"

  local intermediate_output
  local intermediate_exit=0
  intermediate_output=$(swift "$early_version1_listener" --database "$database" \
    --config "$config" --store "$store" --once --timeout 0.4 \
    --poll-interval 0.05 2>&1) || intermediate_exit=$?
  (( intermediate_exit != 0 )) || fail "early version-1 witness fixture emitted"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" ]] \
    || fail "early version-1 fixture did not complete marker 301: $intermediate_output"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "0" ]] \
    || fail "early version-1 fixture unexpectedly contained marker 302"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_event_aliases a JOIN messages m ON m.id=a.message_id WHERE a.alias_event_id LIKE printf("%d:%%",m.source_sequence);')" == "1" ]] \
    || fail "early version-1 fixture did not retain exactly one standalone fingerprint"

  local output
  local exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.4 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "witness-less prefix upgrade unexpectedly emitted"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "0" ]] \
    || fail "prefix upgrade trusted marker 301 without a complete semantic witness"
  require_contains "$output" "旧原生前缀 ID 升级，迁移保持待完成"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "1" ]] \
    || fail "witness-less fail-closed upgrade changed message cardinality"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM conversations c WHERE c.message_count != (SELECT COUNT(*) FROM messages m WHERE m.conversation_id=c.id);')" == "0" ]] \
    || fail "witness-less fail-closed upgrade drifted conversation counts"

  local full_output
  full_output=$(WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not enumerate the polluted witness set"
  local -a full_aliases
  full_aliases=("${(@f)full_output}")
  (( ${#full_aliases[@]} == 32 )) \
    || fail "old native oracle did not return the complete polluted witness set"
  local round5_exit=0
  output=$(swift "$round5_listener" --database "$database" --config "$config" \
    --store "$store" --once --timeout 0.4 --poll-interval 0.05 2>&1) \
    || round5_exit=$?
  (( round5_exit != 0 )) || fail "round-5 witness-pollution fixture emitted"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "1" ]] \
    || fail "round-5 fixture did not write its stale marker 302"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_event_aliases a JOIN messages m ON m.id=a.message_id WHERE a.alias_event_id LIKE printf("%d:%%",m.source_sequence);')" == "1" ]] \
    || fail "round-5 witness pollution changed the single standalone fingerprint"
  local alias
  for alias in "${full_aliases[@]}"; do
    [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$alias';")" == "1" ]] \
      || fail "round-5 fixture did not materialize polluted witness alias $alias"
  done

  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.4 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "polluted-witness audit unexpectedly emitted"
  require_contains "$output" "旧原生前缀 ID 升级，迁移保持待完成"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090304;')" == "0" ]] \
    || fail "prefix audit trusted aliases manufactured after marker 301"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "1" ]] \
    || fail "polluted-witness fail-closed audit changed message cardinality"
}

test_rejects_round5_witnesses_committed_after_marker301() {
  local old_listener="$fixture_dir/round5-crash-old-listener.swift"
  local early_version1_listener="$fixture_dir/round5-crash-version1-listener.swift"
  local round5_listener="$fixture_dir/round5-crash-prefix-listener.swift"
  local database="$fixture_dir/round5-crash-source.db"
  local config="$fixture_dir/round5-crash/groups.txt"
  local store="$fixture_dir/round5-crash/messages.sqlite3"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical round-5 crash listener"
  git show 8089608:scripts/wecom-group-listener.swift > "$early_version1_listener" \
    || fail "could not materialize the early version-1 round-5 crash listener"
  git show 1c5dbff:scripts/wecom-group-listener.swift > "$round5_listener" \
    || fail "could not materialize the real round-5 crash listener"
  make_database "$database"
  write_config "$config" "目标群"
  insert_notification "$database" 44 1 100 "目标群" "" "王五：初始内容"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed the round-5 crash store"

  local output
  local exit_code=0
  output=$(swift "$early_version1_listener" --database "$database" \
    --config "$config" --store "$store" --once --timeout 0.4 \
    --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "early version-1 crash fixture unexpectedly emitted"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" ]] \
    || fail "early version-1 crash fixture did not complete marker 301: $output"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "0" ]] \
    || fail "early version-1 crash fixture unexpectedly contained marker 302"

  local full_output
  full_output=$(WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not enumerate round-5 crash aliases"
  local -a full_aliases
  full_aliases=("${(@f)full_output}")
  (( ${#full_aliases[@]} == 32 )) \
    || fail "old native oracle did not return the complete round-5 alias set"

  # Use the real round-5 implementation and interrupt exactly at its marker
  # transaction.  Its per-owner alias transaction remains committed while the
  # BEFORE INSERT trigger aborts 302, reproducing the production crash window
  # without copying or hand-writing the aliases under review.
  sqlite3 "$store" <<'SQL'
CREATE TRIGGER abort_round5_marker302
BEFORE INSERT ON schema_migrations
WHEN NEW.version = 2026090302
BEGIN
  SELECT RAISE(ABORT, 'round5 marker interruption fixture');
END;
SQL
  exit_code=0
  output=$(swift "$round5_listener" --database "$database" --config "$config" \
    --store "$store" --once --timeout 0.4 --poll-interval 0.05 2>&1) \
    || exit_code=$?
  (( exit_code != 0 )) || fail "round-5 marker interruption fixture unexpectedly emitted"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "0" ]] \
    || fail "round-5 interruption trigger did not stop marker 302"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='message_legacy_alias_provenance';")" == "0" ]] \
    || fail "real round-5 fixture unexpectedly created HEAD provenance storage"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_event_aliases a JOIN messages m ON m.id=a.message_id WHERE a.alias_event_id LIKE printf("%d:%%",m.source_sequence);')" == "1" ]] \
    || fail "round-5 interruption changed the single standalone fingerprint"
  local alias
  local late_witness_count=0
  local witness_index
  for alias in "${full_aliases[@]}"; do
    [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$alias';")" == "1" ]] \
      || fail "round-5 did not commit alias $alias before its marker failed"
  done
  # The real oracle's version-1 witness is direct layouts 1...2, the first
  # full-width-prefix layouts 3...7, and ASCII-colon-space layouts 23...27.
  # At least one of those aliases must have been introduced after marker 301;
  # otherwise this fixture would not exercise the false witness path.
  for witness_index in 1 2 3 4 5 6 7 23 24 25 26 27; do
    alias=${full_aliases[$witness_index]}
    if [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$alias' AND created_at > (SELECT applied_at FROM schema_migrations WHERE version=2026090301);")" == "1" ]]; then
      (( late_witness_count += 1 ))
    fi
  done
  (( late_witness_count > 0 )) \
    || fail "round-5 interruption did not create any post-301 semantic witness"
  sqlite3 "$store" 'DROP TRIGGER abort_round5_marker302;'

  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.4 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "post-301 witness fixture unexpectedly emitted"
  require_contains "$output" "旧原生前缀 ID 升级，迁移保持待完成"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version IN (2026090302,2026090304);')" == "0" ]] \
    || fail "HEAD trusted round-5 aliases committed after marker 301"

  # A wall-clock rollback can make every later alias appear older than marker
  # 301.  The later producer's expanded alias shape must still keep the audit
  # pending.
  local marker301_at=$(sqlite3 "$store" \
    'SELECT applied_at FROM schema_migrations WHERE version=2026090301;')
  sqlite3 "$store" \
    "UPDATE message_event_aliases SET created_at=($marker301_at - 1) WHERE alias_event_id IN ($(printf "'%s'," "${full_aliases[@]}" | sed 's/,$//'));"
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.4 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "backdated round-5 witness fixture unexpectedly emitted"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version IN (2026090302,2026090304);')" == "0" ]] \
    || fail "HEAD trusted a clock-rollback copy of round-5 witness aliases"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "1" ]] \
    || fail "clock-rollback fail-closed audit changed message cardinality"
}

test_rejects_early301_direct_witness_plus_backdated_round5_aliases() {
  local old_listener="$fixture_dir/round5-mixed-witness-old-listener.swift"
  local early_version1_listener="$fixture_dir/round5-mixed-witness-version1-listener.swift"
  local round5_listener="$fixture_dir/round5-mixed-witness-prefix-listener.swift"
  local database="$fixture_dir/round5-mixed-witness-source.db"
  local config="$fixture_dir/round5-mixed-witness/groups.txt"
  local store="$fixture_dir/round5-mixed-witness/messages.sqlite3"
  local group="目标群"
  local content="初始内容"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical mixed-witness listener"
  git show 8089608:scripts/wecom-group-listener.swift > "$early_version1_listener" \
    || fail "could not materialize the early version-1 mixed-witness listener"
  git show 1c5dbff:scripts/wecom-group-listener.swift > "$round5_listener" \
    || fail "could not materialize the real round-5 mixed-witness listener"
  make_database "$database"
  write_config "$config" "$group"

  # This real raw layout decodes with group == sender.  The old policy rejects
  # its deduplicated direct compatibility layout, but 808's migration inserted
  # that direct ID without the policy filter before writing marker 301.
  insert_notification "$database" 44 1 100 "$group" "" "$group：$content"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed the mixed-witness store"
  [[ "$(sqlite3 "$store" 'SELECT group_name || "|" || sender_display_name || "|" || content FROM messages;')" == "$group|$group|$content" ]] \
    || fail "mixed-witness raw layout did not decode to the intended semantic tuple"

  local output
  local exit_code=0
  output=$(swift "$early_version1_listener" --database "$database" \
    --config "$config" --store "$store" --once --timeout 0.4 \
    --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "early version-1 mixed-witness fixture unexpectedly emitted"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" ]] \
    || fail "early version-1 mixed-witness fixture did not complete marker 301: $output"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "0" ]] \
    || fail "early version-1 mixed-witness fixture unexpectedly contained marker 302"

  local full_output
  full_output=$(WXFOMO_PREFIX_GROUP="$group" WXFOMO_PREFIX_SENDER="$group" \
    WXFOMO_PREFIX_CONTENT="$content" WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not enumerate mixed-witness round-5 aliases"
  local -a full_aliases
  full_aliases=("${(@f)full_output}")
  (( ${#full_aliases[@]} > 1 )) \
    || fail "old native oracle did not return an expanded mixed-witness alias set"

  # Reproduce the later producer's non-atomic crash window with production
  # round-5 code: aliases commit, then marker 302 aborts in its own transaction.
  sqlite3 "$store" <<'SQL'
CREATE TRIGGER abort_mixed_witness_marker302
BEFORE INSERT ON schema_migrations
WHEN NEW.version = 2026090302
BEGIN
  SELECT RAISE(ABORT, 'mixed witness marker interruption fixture');
END;
SQL
  exit_code=0
  output=$(swift "$round5_listener" --database "$database" --config "$config" \
    --store "$store" --once --timeout 0.4 --poll-interval 0.05 2>&1) \
    || exit_code=$?
  (( exit_code != 0 )) || fail "round-5 mixed-witness interruption unexpectedly emitted"
  sqlite3 "$store" 'DROP TRIGGER abort_mixed_witness_marker302;'
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "0" ]] \
    || fail "round-5 mixed-witness interruption did not stop marker 302"
  local alias
  for alias in "${full_aliases[@]}"; do
    [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$alias';")" == "1" ]] \
      || fail "round-5 mixed-witness producer did not commit alias $alias"
  done

  # Simulate a system-clock rollback during the later transaction.  Timestamp
  # ordering alone now makes both the 808 direct ID and every round-5 policy ID
  # appear older than marker 301, but their combined producer shape is unsafe.
  local marker301_at=$(sqlite3 "$store" \
    'SELECT applied_at FROM schema_migrations WHERE version=2026090301;')
  sqlite3 "$store" \
    "UPDATE message_event_aliases SET created_at=($marker301_at - 1);"
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.4 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "backdated mixed-witness fixture unexpectedly emitted"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version IN (2026090302,2026090304);')" == "0" ]] \
    || fail "HEAD trusted a combined 808 and backdated round-5 witness set"
  require_contains "$output" "旧原生前缀 ID 升级，迁移保持待完成"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "1" ]] \
    || fail "mixed-witness fail-closed audit changed message cardinality"
}

test_upgrades_a_legitimate_baa_store_when_group_equals_sender() {
  local old_listener="$fixture_dir/baa-group-sender-old-listener.swift"
  local baa_listener="$fixture_dir/baa-group-sender-version1-listener.swift"
  local database="$fixture_dir/baa-group-sender-source.db"
  local config="$fixture_dir/baa-group-sender/groups.txt"
  local store="$fixture_dir/baa-group-sender/messages.sqlite3"
  local group="目标群"
  local content="初始内容"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical baa group/sender listener"
  git show baa877b:scripts/wecom-group-listener.swift > "$baa_listener" \
    || fail "could not materialize the real baa group/sender listener"
  make_database "$database"
  write_config "$config" "$group"
  insert_notification "$database" 44 1 100 "$group" "" "$group：$content"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed the baa group/sender store"

  local output
  local exit_code=0
  output=$(swift "$baa_listener" --database "$database" --config "$config" \
    --store "$store" --once --timeout 0.4 --poll-interval 0.05 2>&1) \
    || exit_code=$?
  (( exit_code != 0 )) || fail "baa group/sender fixture unexpectedly emitted"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" ]] \
    || fail "real baa group/sender fixture did not complete marker 301: $output"
  [[ "$(sqlite3 "$store" 'SELECT group_name || "|" || sender_display_name || "|" || content FROM messages;')" == "$group|$group|$content" ]] \
    || fail "baa group/sender fixture lost its verified semantic tuple"

  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.4 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "upgraded baa group/sender fixture unexpectedly emitted"
  require_absent "$output" "旧原生前缀 ID 升级，迁移保持待完成"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version IN (2026090302,2026090304);')" == "2" ]] \
    || fail "HEAD rejected a legitimate baa group/sender producer shape: $output"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "1" \
    && "$(sqlite3 "$store" 'SELECT COUNT(*) FROM conversations c WHERE c.message_count != (SELECT COUNT(*) FROM messages m WHERE m.conversation_id=c.id);')" == "0" ]] \
    || fail "baa group/sender upgrade changed message or conversation cardinality"
}

test_rejects_nonfinite_version1_times_on_a_legitimate_baa_store() {
  local old_listener="$fixture_dir/nonfinite-version1-old-listener.swift"
  local baa_listener="$fixture_dir/nonfinite-version1-baa-listener.swift"
  local database="$fixture_dir/nonfinite-version1-source.db"
  local config="$fixture_dir/nonfinite-version1/groups.txt"
  local store="$fixture_dir/nonfinite-version1/messages.sqlite3"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical non-finite-time listener"
  git show baa877b:scripts/wecom-group-listener.swift > "$baa_listener" \
    || fail "could not materialize the real baa version-1 listener"
  make_database "$database"
  write_config "$config" "目标群"
  insert_notification "$database" 44 1 100 "目标群" "" "王五：初始内容"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed the non-finite-time store"

  local output
  local exit_code=0
  output=$(swift "$baa_listener" --database "$database" --config "$config" \
    --store "$store" --once --timeout 0.4 --poll-interval 0.05 2>&1) \
    || exit_code=$?
  (( exit_code != 0 )) || fail "baa non-finite-time fixture unexpectedly emitted"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" ]] \
    || fail "real baa fixture did not complete marker 301: $output"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "0" ]] \
    || fail "real baa fixture unexpectedly contained marker 302"

  local full_output
  full_output=$(WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not enumerate baa witness aliases"
  local -a full_aliases
  full_aliases=("${(@f)full_output}")
  (( ${#full_aliases[@]} == 32 )) \
    || fail "old native oracle did not return the complete baa alias set"
  local required_witness=${full_aliases[1]}
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$required_witness';")" == "1" ]] \
    || fail "real baa fixture did not persist the direct-layout witness"
  local marker301_at=$(sqlite3 "$store" \
    'SELECT applied_at FROM schema_migrations WHERE version=2026090301;')

  # This is a legitimate baa producer shape, so only the non-finite required
  # witness timestamp can keep the first audit pending.
  sqlite3 "$store" \
    "UPDATE message_event_aliases SET created_at=1e999 WHERE alias_event_id='$required_witness';"
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.4 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "non-finite baa witness fixture unexpectedly emitted"
  require_contains "$output" "旧原生前缀 ID 升级，迁移保持待完成"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version IN (2026090302,2026090304);')" == "0" ]] \
    || fail "HEAD trusted a non-finite witness timestamp on a legitimate baa store"

  # Restore that witness, then isolate a non-finite marker timestamp.  No
  # round-5 expanded signature is present to reject this store first.
  sqlite3 "$store" \
    "UPDATE message_event_aliases SET created_at=($marker301_at - 1) WHERE alias_event_id='$required_witness';"
  sqlite3 "$store" \
    'UPDATE schema_migrations SET applied_at=1e999 WHERE version=2026090301;'
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.4 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "non-finite baa marker fixture unexpectedly emitted"
  require_contains "$output" "旧原生前缀 ID 升级，迁移保持待完成"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version IN (2026090302,2026090304);')" == "0" ]] \
    || fail "HEAD trusted a non-finite marker timestamp on a legitimate baa store"

  # Restoring the finite marker must make this same store eligible.  This
  # proves neither preceding assertion was satisfied by an unrelated shape
  # rejection.
  sqlite3 "$store" \
    "UPDATE schema_migrations SET applied_at=$marker301_at WHERE version=2026090301;"
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.4 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "restored baa fixture unexpectedly emitted"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version IN (2026090302,2026090304);')" == "2" ]] \
    || fail "restored legitimate baa fixture did not complete the prefix audit: $output"
}

test_keeps_intermediate_prefix_upgrade_pending_on_a_historical_only_collision() {
  local old_listener="$fixture_dir/intermediate-prefix-conflict-old-listener.swift"
  local intermediate_listener="$fixture_dir/intermediate-prefix-conflict-listener.swift"
  local database="$fixture_dir/intermediate-prefix-conflict-source.db"
  local config="$fixture_dir/intermediate-prefix-conflict/groups.txt"
  local store="$fixture_dir/intermediate-prefix-conflict/messages.sqlite3"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical prefix-conflict listener"
  git show baa877b:scripts/wecom-group-listener.swift > "$intermediate_listener" \
    || fail "could not materialize the intermediate prefix-conflict listener"
  make_database "$database"
  write_config "$config" "目标群"
  insert_notification "$database" 44 1 100 "目标群" "" "王五：初始内容"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed the prefix-conflict store"
  local intermediate_exit=0
  local intermediate_output
  intermediate_output=$(swift "$intermediate_listener" --database "$database" \
    --config "$config" --store "$store" --once --timeout 0.3 \
    --poll-interval 0.05 2>&1) || intermediate_exit=$?
  (( intermediate_exit != 0 )) || fail "intermediate prefix-conflict fixture emitted"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" ]] \
    || fail "intermediate prefix-conflict fixture did not complete version 1"

  local prefix_a_output
  prefix_a_output=$(WXFOMO_PRINT_PREFIX_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not produce historical collision IDs"
  local historical_collision_id=""
  local historical_candidate
  for historical_candidate in "${(@f)prefix_a_output}"; do
    if [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$historical_candidate';")" == "0" ]]; then
      historical_collision_id="$historical_candidate"
      break
    fi
  done
  [[ -n "$historical_collision_id" ]] \
    || fail "intermediate store already contained every historical prefix alias"
  sqlite3 "$store" <<SQL
INSERT INTO messages(
  event_id, conversation_id, group_name, sender_display_name, sender_stable_id,
  content, message_type, observed_at, source_sequence, attachments_json,
  attachment_count, sender_confidence, is_from_self, inserted_at, record_version
)
SELECT '$historical_collision_id', conversation_id, group_name, sender_display_name,
  sender_stable_id, '仅历史 alias 冲突', message_type, observed_at, 999,
  attachments_json, attachment_count, sender_confidence, is_from_self,
  inserted_at, record_version
FROM messages
ORDER BY id
LIMIT 1;
UPDATE conversations SET message_count=2;
SQL

  local prefix_b_output
  prefix_b_output=$(WXFOMO_PREFIX_SENDER="赵六" WXFOMO_PREFIX_CONTENT="版本 B" \
    WXFOMO_PRINT_PREFIX_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not produce current prefix IDs"
  local current_alias
  for current_alias in "${(@f)prefix_b_output}"; do
    [[ "$current_alias" != "$historical_collision_id" ]] \
      || fail "historical collision ID also belonged to current revision B"
  done
  local payload_b=$(payload_hex "目标群" "" "赵六 : 版本 B")
  sqlite3 "$database" \
    "UPDATE record SET data=X'$payload_b',request_last_date=200,delivered_date=200 WHERE rec_id=44;"

  local output
  local exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.4 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "historical-only prefix conflict unexpectedly emitted"
  require_contains "$output" "旧原生前缀 ID 升级，迁移保持待完成"
  require_contains "$output" "等待指定企业微信群消息超时"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" ]] \
    || fail "historical-only collision disturbed the completed version 1 marker"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "0" ]] \
    || fail "prefix upgrade completed despite a historical-only exact-ID collision"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "2" ]] \
    || fail "historical-only prefix conflict created or lost a message"
  [[ "$(sqlite3 "$store" "SELECT content FROM messages WHERE event_id='$historical_collision_id';")" == "仅历史 alias 冲突" ]] \
    || fail "historical-only exact event row lost lookup precedence"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages WHERE content="初始内容";')" == "1" ]] \
    || fail "prefix conflict mutated the intermediate canonical survivor"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM conversations c WHERE c.message_count != (SELECT COUNT(*) FROM messages m WHERE m.conversation_id=c.id);')" == "0" ]] \
    || fail "historical-only prefix conflict drifted conversation counts"
}

test_filters_prefix_aliases_through_the_real_old_policy_projector() {
  local old_listener="$fixture_dir/intermediate-projector-old-listener.swift"
  local intermediate_listener="$fixture_dir/intermediate-projector-listener.swift"
  local database="$fixture_dir/intermediate-projector-source.db"
  local config="$fixture_dir/intermediate-projector/groups.txt"
  local store="$fixture_dir/intermediate-projector/messages.sqlite3"
  local long_sender=$(printf '甲%.0s' {1..81})
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical projector listener"
  git show baa877b:scripts/wecom-group-listener.swift > "$intermediate_listener" \
    || fail "could not materialize the intermediate projector listener"
  make_database "$database"
  write_config "$config" "目标群"
  insert_notification "$database" 44 1 100 "目标群" "$long_sender" "初始内容"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener rejected a valid direct-field long sender"
  local intermediate_exit=0
  local intermediate_output
  intermediate_output=$(swift "$intermediate_listener" --database "$database" \
    --config "$config" --store "$store" --once --timeout 0.3 \
    --poll-interval 0.05 2>&1) || intermediate_exit=$?
  (( intermediate_exit != 0 )) || fail "intermediate projector fixture emitted"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" ]] \
    || fail "intermediate projector fixture did not complete version 1"

  local valid_output
  valid_output=$(WXFOMO_PREFIX_SENDER="$long_sender" \
    WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native projector could not enumerate direct-field aliases"
  local -a valid_ids
  valid_ids=("${(@f)valid_output}")
  (( ${#valid_ids[@]} == 2 )) \
    || fail "old native projector accepted a long sender in a body prefix"
  local invalid_output
  invalid_output=$(WXFOMO_PREFIX_SENDER="$long_sender" \
    WXFOMO_PRINT_INVALID_PREFIX_HASH_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native projector could not enumerate rejected long-sender prefixes"
  local -a invalid_ids
  invalid_ids=("${(@f)invalid_output}")
  (( ${#invalid_ids[@]} == 40 )) \
    || fail "old native projector did not reject every long-sender prefix arrangement"
  local invalid_alias_count_before=0
  local rejected_collision_id=""
  local invalid_id
  for invalid_id in "${invalid_ids[@]}"; do
    if [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$invalid_id';")" == "1" ]]; then
      (( invalid_alias_count_before += 1 ))
    elif [[ -z "$rejected_collision_id" ]]; then
      rejected_collision_id="$invalid_id"
    fi
  done
  [[ -n "$rejected_collision_id" ]] \
    || fail "intermediate fixture left no rejected prefix for the upgrade preflight"
  sqlite3 "$store" <<SQL
INSERT INTO messages(
  event_id, conversation_id, group_name, sender_display_name, sender_stable_id,
  content, message_type, observed_at, source_sequence, attachments_json,
  attachment_count, sender_confidence, is_from_self, inserted_at, record_version
)
SELECT '$rejected_collision_id', conversation_id, group_name, sender_display_name,
  sender_stable_id, '旧 policy 拒绝的长发送者前缀', message_type, observed_at, 999,
  attachments_json, attachment_count, sender_confidence, is_from_self,
  inserted_at, record_version
FROM messages
ORDER BY id
LIMIT 1;
UPDATE conversations SET message_count=2;
SQL

  local output
  local exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.4 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "old-policy projector fixture unexpectedly emitted"
  require_contains "$output" "等待指定企业微信群消息超时"
  require_absent "$output" "旧原生前缀 ID 升级，迁移保持待完成"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "1" ]] \
    || fail "a prefix rejected by the real old policy blocked the upgrade"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "2" ]] \
    || fail "old-policy projector migration created or lost a message"
  [[ "$(sqlite3 "$store" "SELECT content FROM messages WHERE event_id='$rejected_collision_id';")" == "旧 policy 拒绝的长发送者前缀" ]] \
    || fail "rejected-prefix exact event row lost precedence"
  local invalid_alias_count_after=0
  for invalid_id in "${invalid_ids[@]}"; do
    if [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$invalid_id';")" == "1" ]]; then
      (( invalid_alias_count_after += 1 ))
    fi
  done
  [[ "$invalid_alias_count_after" == "$invalid_alias_count_before" ]] \
    || fail "upgrade attached an alias rejected by the real old policy"
  local valid_id
  for valid_id in "${valid_ids[@]}"; do
    [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$valid_id' AND message_id=(SELECT id FROM messages WHERE content='初始内容');")" == "1" ]] \
      || fail "old-policy projector dropped a valid direct-field alias"
  done
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM conversations c WHERE c.message_count != (SELECT COUNT(*) FROM messages m WHERE m.conversation_id=c.id);')" == "0" ]] \
    || fail "old-policy projector migration drifted conversation counts"
}

test_matches_old_decoder_and_policy_for_embedded_colons_and_whitespace() {
  local old_listener="$fixture_dir/intermediate-projector-values-old-listener.swift"
  local intermediate_listener="$fixture_dir/intermediate-projector-values-listener.swift"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical projector-values listener"
  git show baa877b:scripts/wecom-group-listener.swift > "$intermediate_listener" \
    || fail "could not materialize the intermediate projector-values listener"

  local projector_case sender expected_valid database config store output exit_code
  local valid_output invalid_output valid_id invalid_id
  local -a valid_ids invalid_ids
  for projector_case in embedded-colon decoder-whitespace; do
    if [[ "$projector_case" == "embedded-colon" ]]; then
      sender="王：五"
      expected_valid=2
    else
      sender="甲$(printf '  %.0s' {1..50})乙"
      expected_valid=32
    fi
    database="$fixture_dir/intermediate-projector-$projector_case-source.db"
    config="$fixture_dir/intermediate-projector-$projector_case/groups.txt"
    store="$fixture_dir/intermediate-projector-$projector_case/messages.sqlite3"
    make_database "$database"
    write_config "$config" "目标群"
    insert_notification "$database" 44 1 100 "目标群" "$sender" "初始内容"
    swift "$old_listener" --database "$database" --config "$config" --store "$store" \
      --include-existing --once --timeout 1 >/dev/null 2>&1 \
      || fail "pre-canonical listener rejected projector case $projector_case"
    exit_code=0
    output=$(swift "$intermediate_listener" --database "$database" --config "$config" \
      --store "$store" --once --timeout 0.3 --poll-interval 0.05 2>&1) \
      || exit_code=$?
    (( exit_code != 0 )) || fail "intermediate projector case $projector_case emitted"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" ]] \
      || fail "intermediate projector case $projector_case did not complete version 1"

    valid_output=$(WXFOMO_PREFIX_SENDER="$sender" \
      WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
      zsh "$script_dir/test-wecom-notification-mapper.sh") \
      || fail "old native oracle failed projector case $projector_case"
    invalid_output=$(WXFOMO_PREFIX_SENDER="$sender" \
      WXFOMO_PRINT_INVALID_PREFIX_HASH_IDS=1 \
      zsh "$script_dir/test-wecom-notification-mapper.sh") \
      || fail "old native oracle could not enumerate incompatible case $projector_case"
    valid_ids=("${(@f)valid_output}")
    invalid_ids=("${(@f)invalid_output}")
    (( ${#valid_ids[@]} == expected_valid )) \
      || fail "old native oracle validity mismatch for $projector_case"
    local invalid_before=0
    for invalid_id in "${invalid_ids[@]}"; do
      if [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$invalid_id';")" == "1" ]]; then
        (( invalid_before += 1 ))
      fi
    done

    exit_code=0
    output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
      --once --timeout 0.4 --poll-interval 0.05 2>&1) || exit_code=$?
    (( exit_code != 0 )) || fail "projector case $projector_case unexpectedly emitted"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "1" ]] \
      || fail "projector case $projector_case did not complete version 2"
    for valid_id in "${valid_ids[@]}"; do
      [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$valid_id' AND message_id=(SELECT id FROM messages LIMIT 1);")" == "1" ]] \
        || fail "projector case $projector_case missed a real old native alias"
    done
    local invalid_after=0
    for invalid_id in "${invalid_ids[@]}"; do
      if [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$invalid_id';")" == "1" ]]; then
        (( invalid_after += 1 ))
      fi
    done
    [[ "$invalid_after" == "$invalid_before" ]] \
      || fail "projector case $projector_case attached a semantically incompatible alias"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "1" ]] \
      || fail "projector case $projector_case changed message cardinality"
  done
}

test_completes_prefix_upgrade_after_the_historical_group_leaves_config() {
  local old_listener="$fixture_dir/intermediate-config-drift-old-listener.swift"
  local intermediate_listener="$fixture_dir/intermediate-config-drift-listener.swift"
  local database="$fixture_dir/intermediate-config-drift-source.db"
  local config="$fixture_dir/intermediate-config-drift/groups.txt"
  local store="$fixture_dir/intermediate-config-drift/messages.sqlite3"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical config-drift listener"
  git show baa877b:scripts/wecom-group-listener.swift > "$intermediate_listener" \
    || fail "could not materialize the intermediate config-drift listener"
  make_database "$database"
  write_config "$config" "目标群"
  insert_notification "$database" 44 1 100 "目标群" "" "王五：初始内容"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed the config-drift store"
  local intermediate_exit=0
  local intermediate_output
  intermediate_output=$(swift "$intermediate_listener" --database "$database" \
    --config "$config" --store "$store" --once --timeout 0.3 \
    --poll-interval 0.05 2>&1) || intermediate_exit=$?
  (( intermediate_exit != 0 )) || fail "intermediate config-drift fixture emitted"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" ]] \
    || fail "intermediate config-drift fixture did not complete version 1"

  local compatibility_output
  compatibility_output=$(WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not enumerate config-drift aliases"
  local current_compatibility_output
  current_compatibility_output=$(WXFOMO_PREFIX_SENDER="赵六" \
    WXFOMO_PREFIX_CONTENT="版本 B" WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not enumerate current config-drift aliases"
  local -a compatibility_ids current_compatibility_ids all_compatibility_ids
  compatibility_ids=("${(@f)compatibility_output}")
  current_compatibility_ids=("${(@f)current_compatibility_output}")
  all_compatibility_ids=("${compatibility_ids[@]}" "${current_compatibility_ids[@]}")
  (( ${#compatibility_ids[@]} == 32 && ${#current_compatibility_ids[@]} == 32 )) \
    || fail "config-drift oracle did not enumerate both complete old layout sets"
  local payload_b=$(payload_hex "目标群" "" "赵六：版本 B")
  sqlite3 "$database" \
    "UPDATE record SET data=X'$payload_b',request_last_date=200,delivered_date=200 WHERE rec_id=44;"
  write_config "$config" "另一个群"

  local output
  local exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.4 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "config-drift prefix upgrade unexpectedly emitted"
  require_contains "$output" "等待指定企业微信群消息超时"
  require_absent "$output" "旧原生前缀 ID 升级，迁移保持待完成"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "1" ]] \
    || fail "current config drift left a source-verifiable prefix upgrade pending"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "1" ]] \
    || fail "config-drift prefix upgrade changed the historical message count"
  local compatibility_id
  for compatibility_id in "${all_compatibility_ids[@]}"; do
    [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$compatibility_id' AND message_id=(SELECT id FROM messages LIMIT 1);")" == "1" ]] \
      || fail "config-drift prefix upgrade lost historical alias $compatibility_id"
  done
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM conversations c WHERE c.message_count != (SELECT COUNT(*) FROM messages m WHERE m.conversation_id=c.id);')" == "0" ]] \
    || fail "config-drift prefix upgrade drifted conversation counts"
}

test_prefix_upgrade_work_scales_linearly_with_distinct_candidates() {
  local old_listener="$fixture_dir/intermediate-scale-old-listener.swift"
  local intermediate_listener="$fixture_dir/intermediate-scale-listener.swift"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical scale listener"
  git show baa877b:scripts/wecom-group-listener.swift > "$intermediate_listener" \
    || fail "could not materialize the intermediate scale listener"

  local size index record_id database config store output exit_code expected_work
  for size in 4 8; do
    database="$fixture_dir/intermediate-scale-$size-source.db"
    config="$fixture_dir/intermediate-scale-$size/groups.txt"
    store="$fixture_dir/intermediate-scale-$size/messages.sqlite3"
    make_database "$database"
    write_config "$config" "目标群"
    for (( index = 1; index <= size; index += 1 )); do
      record_id=$((100 + index))
      insert_notification "$database" "$record_id" 1 "$record_id" \
        "目标群" "成员 $index" "线性迁移 $index"
      swift "$old_listener" --database "$database" --config "$config" --store "$store" \
        --include-existing --once --timeout 1 >/dev/null 2>&1 \
        || fail "pre-canonical listener could not seed scale fixture $size/$index"
      sqlite3 "$database" "DELETE FROM record WHERE rec_id=$record_id;"
    done
    # Restore the exact source rows after the old one-row-at-a-time fixture has
    # materialized every pre-canonical store row.
    for (( index = 1; index <= size; index += 1 )); do
      record_id=$((100 + index))
      insert_notification "$database" "$record_id" 1 "$record_id" \
        "目标群" "成员 $index" "线性迁移 $index"
    done
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "$size" ]] \
      || fail "pre-canonical scale fixture did not contain $size messages"

    exit_code=0
    output=$(swift "$intermediate_listener" --database "$database" --config "$config" \
      --store "$store" --once --timeout 0.6 --poll-interval 0.05 2>&1) \
      || exit_code=$?
    (( exit_code != 0 )) || fail "intermediate scale fixture $size unexpectedly emitted"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" ]] \
      || fail "intermediate scale fixture $size did not complete version 1"

    exit_code=0
    output=$(WXFOMO_TEST_REPORT_PREFIX_MIGRATION_WORK=1 \
      swift "$listener" --database "$database" --config "$config" --store "$store" \
      --once --timeout 0.6 --poll-interval 0.05 2>&1) || exit_code=$?
    (( exit_code != 0 )) || fail "prefix scale fixture $size unexpectedly emitted"
    expected_work=$((size * 2))
    require_contains "$output" "旧原生前缀迁移工作量：$expected_work"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "1" ]] \
      || fail "prefix scale fixture $size did not complete version 2"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "$size" ]] \
      || fail "prefix scale fixture $size changed message cardinality"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM conversations c WHERE c.message_count != (SELECT COUNT(*) FROM messages m WHERE m.conversation_id=c.id);')" == "0" ]] \
      || fail "prefix scale fixture $size drifted conversation counts"
  done
}

test_consolidates_multiple_stable_uuid_revisions_during_precanonical_migration() {
  local old_listener="$fixture_dir/precanonical-revisions-listener.swift"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the actual pre-c0c20ed revision listener"
  local compatibility_ids
  compatibility_ids=$(WXFOMO_PRINT_REVISION_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "production native mapper could not produce revision compatibility IDs"
  local canonical_event_id=${${(f)compatibility_ids}[1]}
  local native_a=${${(f)compatibility_ids}[2]}
  local native_b=${${(f)compatibility_ids}[3]}
  local native_c=${${(f)compatibility_ids}[4]}
  [[ -n "$canonical_event_id" && -n "$native_a" && -n "$native_b" && -n "$native_c" ]] \
    || fail "production native mapper returned incomplete revision IDs"
  local full_a_output full_b_output full_c_output
  full_a_output=$(WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not enumerate revision A aliases"
  full_b_output=$(WXFOMO_PREFIX_SENDER="赵六" WXFOMO_PREFIX_CONTENT="版本 B" \
    WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not enumerate revision B aliases"
  full_c_output=$(WXFOMO_PREFIX_SENDER="孙七" WXFOMO_PREFIX_CONTENT="版本 C" \
    WXFOMO_PRINT_FULL_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not enumerate revision C aliases"
  local -a full_a_aliases full_b_aliases full_c_aliases
  full_a_aliases=("${(@f)full_a_output}")
  full_b_aliases=("${(@f)full_b_output}")
  full_c_aliases=("${(@f)full_c_output}")
  (( ${#full_a_aliases[@]} == 32 && ${#full_b_aliases[@]} == 32 \
    && ${#full_c_aliases[@]} == 32 )) \
    || fail "old native oracle did not enumerate every multi-revision layout"

  local storage_class
  local output
  local exit_code
  local alias
  local -a aliases
  for storage_class in blob text; do
    local database="$fixture_dir/precanonical-revisions-$storage_class-source.db"
    local config="$fixture_dir/precanonical-revisions-$storage_class/groups.txt"
    local store="$fixture_dir/precanonical-revisions-$storage_class/messages.sqlite3"
    make_database "$database"
    write_config "$config" "目标群"
    if [[ "$storage_class" == "blob" ]]; then
      insert_notification "$database" 44 1 100 "目标群" "" "王五：初始内容"
    else
      insert_notification_with_text_uuid "$database" 44 100 "目标群" "" "王五：初始内容"
    fi
    swift "$old_listener" --database "$database" --config "$config" --store "$store" \
      --include-existing --once --timeout 1 >/dev/null 2>&1 \
      || fail "pre-c0 listener could not persist $storage_class revision A"

    local payload_b=$(payload_hex "目标群" "" "赵六：版本 B")
    sqlite3 "$database" \
      "UPDATE record SET data=X'$payload_b',request_last_date=200,delivered_date=200 WHERE rec_id=44;"
    swift "$old_listener" --database "$database" --config "$config" --store "$store" \
      --include-existing --once --timeout 1 >/dev/null 2>&1 \
      || fail "pre-c0 listener could not persist $storage_class revision B"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "2" ]] \
      || fail "$storage_class revision fixture did not contain A and B"
    [[ "$(sqlite3 "$store" 'SELECT message_count FROM conversations WHERE group_name="目标群";')" == "2" ]] \
      || fail "$storage_class revision fixture conversation count was not two"
    local survivor_id=$(sqlite3 "$store" 'SELECT MIN(id) FROM messages;')
    local standalone_a=$(sqlite3 "$store" 'SELECT event_id FROM messages ORDER BY id LIMIT 1;')
    local standalone_b=$(sqlite3 "$store" 'SELECT event_id FROM messages ORDER BY id DESC LIMIT 1;')

    local payload_c=$(payload_hex "目标群" "" "孙七：版本 C")
    sqlite3 "$database" \
      "UPDATE record SET data=X'$payload_c',request_last_date=300,delivered_date=300 WHERE rec_id=44;"
    exit_code=0
    output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
      --once --timeout 0.3 --poll-interval 0.05 2>&1) || exit_code=$?
    (( exit_code != 0 )) || fail "$storage_class migration replayed revision C as a new message: $output"
    require_contains "$output" "等待指定企业微信群消息超时"

    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "1" ]] \
      || fail "$storage_class revisions were not consolidated to one message"
    [[ "$(sqlite3 "$store" 'SELECT id FROM messages;')" == "$survivor_id" ]] \
      || fail "$storage_class migration did not choose the deterministic oldest survivor"
    [[ "$(sqlite3 "$store" 'SELECT event_id FROM messages;')" == "$canonical_event_id" ]] \
      || fail "$storage_class survivor did not use the canonical current event ID"
    [[ "$(sqlite3 "$store" 'SELECT sender_display_name || "|" || content FROM messages;')" == "孙七|版本 C" ]] \
      || fail "$storage_class survivor did not contain current revision C"
    [[ "$(sqlite3 "$store" 'SELECT message_count FROM conversations WHERE group_name="目标群";')" == "1" ]] \
      || fail "$storage_class conversation count was not repaired after consolidation"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM conversations c WHERE c.message_count != (SELECT COUNT(*) FROM messages m WHERE m.conversation_id=c.id);')" == "0" ]] \
      || fail "$storage_class migration left a conversation count mismatch"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" ]] \
      || fail "$storage_class multi-revision migration was not marked complete"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_legacy_alias_provenance WHERE version=2026090305;')" == "1" ]] \
      || fail "$storage_class complete per-survivor multi-revision provenance was not recorded"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "1" ]] \
      || fail "$storage_class complete multi-revision provenance could not finish prefix aliases"
    [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090304;')" == "1" ]] \
      || fail "$storage_class complete multi-revision provenance was not audited"

    aliases=("$standalone_a" "$standalone_b" "$native_a" "$native_b" "$native_c")
    for alias in "${aliases[@]}"; do
      [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$alias' AND message_id=$survivor_id;")" == "1" ]] \
        || fail "$storage_class migration did not preserve revision alias $alias"
    done
    for alias in "${full_a_aliases[@]}" "${full_b_aliases[@]}" "${full_c_aliases[@]}"; do
      [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$alias' AND message_id=$survivor_id;")" == "1" ]] \
        || fail "$storage_class complete provenance did not preserve prefix alias $alias"
    done
    PYTHONPATH="$script_dir" /usr/bin/python3 - "$store" "$config" \
      "$standalone_a" "$standalone_b" "$native_a" "$native_b" <<'PY' \
      || fail "$storage_class revision aliases were not readable through the production repository"
import sys

from wxfomo_lan.messages import MessageRepository

aliases = sys.argv[3:]
items = MessageRepository(sys.argv[1], sys.argv[2]).by_event_ids(aliases)
assert [item["eventId"] for item in items] == aliases
assert all(item["content"] == "版本 C" for item in items)
PY
  done
}

test_does_not_prebind_the_wrong_uuid_storage_class_alias() {
  local database="$fixture_dir/precanonical-storage-collision-source.db"
  local config="$fixture_dir/precanonical-storage-collision/groups.txt"
  local store="$fixture_dir/precanonical-storage-collision/messages.sqlite3"
  local old_listener="$fixture_dir/precanonical-storage-collision-listener.swift"
  make_database "$database"
  write_config "$config" "目标群"
  insert_notification_with_text_uuid "$database" 44 100 "目标群" "文本成员" "TEXT 旧消息"

  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical storage-collision listener"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed the TEXT UUID row"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "1" ]] \
    || fail "storage-collision fixture did not start with one legacy row"

  # These BLOB bytes are the UTF-8 bytes of the old TEXT UUID. They are a different,
  # legitimate canonical UUID and must not resolve through the TEXT row's migration.
  local blob_payload=$(payload_hex "目标群" "BLOB 成员" "BLOB 新消息")
  sqlite3 "$database" \
    "INSERT INTO record(rec_id,app_id,uuid,data,request_date,request_last_date,delivered_date,presented,style) VALUES(45,1,X'30303030303030303030303030303263',X'$blob_payload',200,200,200,1,1);"

  local output
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 1 --poll-interval 0.05 2>&1) \
    || fail "legitimate BLOB UUID was swallowed by a guessed TEXT migration alias: $output"
  require_contains "$output" "[目标群] BLOB 成员：BLOB 新消息"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "2" ]] \
    || fail "TEXT/BLOB UUID storage collision merged two canonical notifications"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(DISTINCT event_id) FROM messages;')" == "2" ]] \
    || fail "TEXT/BLOB UUID storage collision did not retain distinct canonical IDs"
}

test_does_not_alias_a_precanonical_uuidless_row_to_a_new_source() {
  local old_database="$fixture_dir/precanonical-uuidless-old.db"
  local new_database="$fixture_dir/precanonical-uuidless-new.db"
  local config="$fixture_dir/precanonical-uuidless/groups.txt"
  local store="$fixture_dir/precanonical-uuidless/messages.sqlite3"
  local old_listener="$fixture_dir/precanonical-uuidless-listener.swift"
  make_database "$old_database"
  make_database "$new_database"
  write_config "$config" "目标群"
  insert_notification_without_uuid "$old_database" 7 100 "目标群" "旧源成员" "旧源无 UUID 消息"
  insert_notification_without_uuid "$new_database" 7 50 "目标群" "新源成员" "新源同 rowID 消息"

  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical UUID-less listener"
  swift "$old_listener" --database "$old_database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed a UUID-less row"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "1" ]] \
    || fail "pre-canonical UUID-less fixture did not contain one old row"

  local new_source_key=$(source_key_for "$new_database")
  local expected_new_event_id=$(WXFOMO_PRINT_UUIDLESS_SOURCE_IDENTITY="$new_source_key" \
    WXFOMO_PRINT_UUIDLESS_ROW_ID=7 zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "native mapper could not map the replacement UUID-less source"
  local output
  output=$(swift "$listener" --database "$new_database" --config "$config" --store "$store" \
    --once --timeout 1 --poll-interval 0.05 2>&1) \
    || fail "new UUID-less source was swallowed by old migration aliases: $output"
  require_contains "$output" "[目标群] 新源成员：新源同 rowID 消息"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "2" ]] \
    || fail "same rowID from a new UUID-less source was merged into the old LAN row"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM messages WHERE event_id='$expected_new_event_id' AND content='新源同 rowID 消息';")" == "1" ]] \
    || fail "new UUID-less source did not retain its source-bound canonical ID"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "0" ]] \
    || fail "migration was marked complete without the old UUID-less fingerprint"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "0" ]] \
    || fail "prefix upgrade hid a pending UUID-less version 1 migration"
}

test_keeps_byte_identical_precanonical_uuidless_rows_distinct_across_sources() {
  local old_database="$fixture_dir/precanonical-identical-old.db"
  local new_database="$fixture_dir/precanonical-identical-new.db"
  local config="$fixture_dir/precanonical-identical/groups.txt"
  local store="$fixture_dir/precanonical-identical/messages.sqlite3"
  local old_listener="$fixture_dir/precanonical-identical-listener.swift"
  make_database "$old_database"
  make_database "$new_database"
  write_config "$config" "目标群"
  insert_notification_without_uuid \
    "$old_database" 7 100 "目标群" "相同成员" "跨源完全相同消息"
  sqlite3 "$new_database" <<SQL
ATTACH DATABASE '$old_database' AS old_source;
INSERT INTO record(
  rec_id, app_id, uuid, data, request_date, request_last_date,
  delivered_date, presented, style
)
SELECT rec_id, app_id, uuid, data, request_date, request_last_date,
  delivered_date, presented, style
FROM old_source.record
WHERE rec_id = 7;
DETACH DATABASE old_source;
SQL
  local old_record=$(sqlite3 "$old_database" \
    "SELECT rec_id,quote(uuid),hex(data),quote(request_date),quote(request_last_date),quote(delivered_date),presented,style FROM record WHERE rec_id=7;")
  local new_record=$(sqlite3 "$new_database" \
    "SELECT rec_id,quote(uuid),hex(data),quote(request_date),quote(request_last_date),quote(delivered_date),presented,style FROM record WHERE rec_id=7;")
  [[ "$old_record" == "$new_record" ]] \
    || fail "UUID-less cross-source fixture records were not byte-identical"

  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical UUID-less listener"
  swift "$old_listener" --database "$old_database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed the byte-identical old row"

  local new_source_key=$(source_key_for "$new_database")
  local expected_new_event_id=$(WXFOMO_PRINT_UUIDLESS_SOURCE_IDENTITY="$new_source_key" \
    WXFOMO_PRINT_UUIDLESS_ROW_ID=7 zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "native mapper could not map the byte-identical replacement source"
  local output
  output=$(swift "$listener" --database "$new_database" --config "$config" --store "$store" \
    --once --timeout 1 --poll-interval 0.05 2>&1) \
    || fail "byte-identical UUID-less replacement was swallowed by an old fingerprint: $output"
  require_contains "$output" "[目标群] 相同成员：跨源完全相同消息"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "2" ]] \
    || fail "byte-identical UUID-less rows from different sources were merged"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM messages WHERE event_id='$expected_new_event_id';")" == "1" ]] \
    || fail "byte-identical replacement did not retain its source-bound canonical ID"

  write_config "$config" "升级后其他群"
  local retry_exit_code=0
  output=$(swift "$listener" --database "$new_database" --config "$config" --store "$store" \
    --once --timeout 0.3 --poll-interval 0.05 2>&1) || retry_exit_code=$?
  (( retry_exit_code != 0 )) \
    || fail "UUID-less pending migration unexpectedly emitted a message: $output"
  require_contains "$output" "兼容 ID 迁移保持待完成"
  require_contains "$output" "等待指定企业微信群消息超时"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "0" ]] \
    || fail "UUID-less alias migration completed without source provenance"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "0" ]] \
    || fail "prefix upgrade hid a pending cross-source provenance migration"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_event_aliases;')" == "0" ]] \
    || fail "UUID-less migration created an alias without source provenance"
}

test_keeps_migration_pending_for_multiple_precanonical_fingerprints_at_one_row_id() {
  local database="$fixture_dir/precanonical-multiple-fingerprints.db"
  local config="$fixture_dir/precanonical-multiple-fingerprints/groups.txt"
  local store="$fixture_dir/precanonical-multiple-fingerprints/messages.sqlite3"
  local old_listener="$fixture_dir/precanonical-multiple-fingerprints-listener.swift"
  make_database "$database"
  write_config "$config" "目标群"
  insert_notification_without_uuid "$database" 7 100 "目标群" "成员" "旧版本一"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical multiple-fingerprint listener"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed the first fingerprint"

  local updated_payload=$(payload_hex "目标群" "成员" "旧版本二")
  sqlite3 "$database" \
    "UPDATE record SET data=X'$updated_payload',request_last_date=200,delivered_date=200 WHERE rec_id=7;"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed the second fingerprint"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages WHERE source_sequence=7;')" == "2" ]] \
    || fail "pre-canonical fixture did not retain both fingerprints for one row ID"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(DISTINCT event_id) FROM messages WHERE source_sequence=7;')" == "2" ]] \
    || fail "pre-canonical fixture fingerprints were not distinct"

  write_config "$config" "升级后其他群"
  local output
  local exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.3 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) \
    || fail "multiple-fingerprint migration unexpectedly emitted a message: $output"
  require_contains "$output" "兼容 ID 迁移保持待完成"
  require_contains "$output" "等待指定企业微信群消息超时"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "2" ]] \
    || fail "multiple-fingerprint migration inserted or merged a historical row"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "0" ]] \
    || fail "multiple fingerprints at one row ID incorrectly completed migration"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "0" ]] \
    || fail "prefix upgrade hid ambiguous pre-canonical fingerprints"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM message_event_aliases;')" == "0" ]] \
    || fail "multiple UUID-less fingerprints acquired an ambiguous alias"
}

test_keeps_alias_migration_pending_on_an_exact_event_id_conflict() {
  local database="$fixture_dir/precanonical-conflict-source.db"
  local config="$fixture_dir/precanonical-conflict/groups.txt"
  local store="$fixture_dir/precanonical-conflict/messages.sqlite3"
  local old_listener="$fixture_dir/precanonical-conflict-listener.swift"
  make_database "$database"
  write_config "$config" "目标群"
  insert_notification "$database" 44 1 103 "目标群" "王五" "初始内容"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical conflict listener"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed the conflict store"

  local compatibility_ids
  compatibility_ids=$(WXFOMO_PRINT_PREFIX_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not produce historical conflict IDs"
  local legacy_native_event_id=${${(f)compatibility_ids}[2]}
  [[ -n "$legacy_native_event_id" ]] \
    || fail "old native oracle did not produce the spaced-prefix conflict ID"
  sqlite3 "$store" <<SQL
INSERT INTO messages(
  event_id, conversation_id, group_name, sender_display_name, sender_stable_id,
  content, message_type, observed_at, source_sequence, attachments_json,
  attachment_count, sender_confidence, is_from_self, inserted_at, record_version
)
SELECT '$legacy_native_event_id', conversation_id, group_name, sender_display_name,
  sender_stable_id, '精确 ID 冲突行', message_type, observed_at, 999,
  attachments_json, attachment_count, sender_confidence, is_from_self,
  inserted_at, record_version
FROM messages
ORDER BY id
LIMIT 1;
UPDATE conversations SET message_count=2;
SQL
  local current_compatibility_ids
  current_compatibility_ids=$(WXFOMO_PREFIX_SENDER="孙七" WXFOMO_PREFIX_CONTENT="版本 C" \
    WXFOMO_PRINT_PREFIX_COMPATIBILITY_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not produce current revision IDs"
  local current_alias
  for current_alias in "${(@f)current_compatibility_ids}"; do
    [[ "$current_alias" != "$legacy_native_event_id" ]] \
      || fail "historical collision ID also belonged to the current source revision"
  done
  local prefixed_payload=$(payload_hex "目标群" "" "孙七 : 版本 C")
  sqlite3 "$database" \
    "UPDATE record SET data=X'$prefixed_payload',request_last_date=104,delivered_date=104 WHERE rec_id=44;"
  local output
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 1 --poll-interval 0.05 2>&1) \
    || fail "conflict migration failed before preserving the current message: $output"
  require_contains "$output" "兼容 ID 迁移保持待完成"
  require_contains "$output" "[目标群] 孙七：版本 C"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "0" ]] \
    || fail "alias migration completed despite an exact event_id lookup conflict"
  [[ "$(sqlite3 "$store" "SELECT content FROM messages WHERE event_id='$legacy_native_event_id';")" == "精确 ID 冲突行" ]] \
    || fail "conflict fixture did not retain exact-ID lookup precedence"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM messages WHERE event_id LIKE '44:%' AND content='初始内容';")" == "1" ]] \
    || fail "alias conflict mutated the pre-canonical candidate before preflight completed"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM messages WHERE content='版本 C';")" == "1" ]] \
    || fail "historical-only collision did not retain the different current revision"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "3" ]] \
    || fail "alias conflict lost a historical or current message"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM conversations c WHERE c.message_count != (SELECT COUNT(*) FROM messages m WHERE m.conversation_id=c.id);')" == "0" ]] \
    || fail "alias conflict left conversation counts inconsistent"
}

test_ignores_prefix_hashes_rejected_by_the_old_native_policy() {
  local database="$fixture_dir/precanonical-invalid-prefix-source.db"
  local config="$fixture_dir/precanonical-invalid-prefix/groups.txt"
  local store="$fixture_dir/precanonical-invalid-prefix/messages.sqlite3"
  local old_listener="$fixture_dir/precanonical-invalid-prefix-listener.swift"
  make_database "$database"
  write_config "$config" "目标群"
  insert_notification "$database" 44 1 103 "目标群" "" "王五：初始内容"
  git show c0c20ed^:scripts/wecom-group-listener.swift > "$old_listener" \
    || fail "could not materialize the pre-canonical invalid-prefix listener"
  swift "$old_listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1 \
    || fail "pre-canonical listener could not seed the invalid-prefix fixture"
  local standalone_event_id=$(sqlite3 "$store" 'SELECT event_id FROM messages LIMIT 1;')

  local invalid_hashes
  invalid_hashes=$(WXFOMO_PRINT_INVALID_PREFIX_HASH_IDS=1 \
    zsh "$script_dir/test-wecom-notification-mapper.sh") \
    || fail "old native oracle could not identify rejected prefix hashes"
  local invalid_event_id=${${(f)invalid_hashes}[1]}
  [[ -n "$invalid_event_id" ]] || fail "old native oracle returned no rejected hash"
  sqlite3 "$store" <<SQL
INSERT INTO messages(
  event_id, conversation_id, group_name, sender_display_name, sender_stable_id,
  content, message_type, observed_at, source_sequence, attachments_json,
  attachment_count, sender_confidence, is_from_self, inserted_at, record_version
)
SELECT '$invalid_event_id', conversation_id, group_name, sender_display_name,
  sender_stable_id, '旧 policy 不可能产生的哈希', message_type, observed_at, 999,
  attachments_json, attachment_count, sender_confidence, is_from_self,
  inserted_at, record_version
FROM messages
ORDER BY id
LIMIT 1;
UPDATE conversations SET message_count=2;
SQL
  local payload_c=$(payload_hex "目标群" "" "孙七：版本 C")
  sqlite3 "$database" \
    "UPDATE record SET data=X'$payload_c',request_last_date=300,delivered_date=300 WHERE rec_id=44;"

  local output
  local exit_code=0
  output=$(swift "$listener" --database "$database" --config "$config" --store "$store" \
    --once --timeout 0.4 --poll-interval 0.05 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "invalid-prefix fixture unexpectedly emitted a duplicate"
  require_contains "$output" "等待指定企业微信群消息超时"
  require_absent "$output" "兼容 ID 迁移保持待完成"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090301;')" == "1" ]] \
    || fail "an impossible native prefix hash blocked the original migration"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM schema_migrations WHERE version=2026090302;')" == "1" ]] \
    || fail "an impossible native prefix hash blocked the upgrade migration"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "2" ]] \
    || fail "invalid-prefix collision created or lost a message"
  [[ "$(sqlite3 "$store" "SELECT content FROM messages WHERE event_id='$invalid_event_id';")" == "旧 policy 不可能产生的哈希" ]] \
    || fail "invalid-prefix collision row was not preserved"
  [[ "$(sqlite3 "$store" "SELECT COUNT(*) FROM message_event_aliases WHERE alias_event_id='$standalone_event_id';")" == "1" ]] \
    || fail "valid standalone provenance alias was lost"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages WHERE content="版本 C";')" == "1" ]] \
    || fail "verified current revision did not become the canonical survivor"
  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM conversations c WHERE c.message_count != (SELECT COUNT(*) FROM messages m WHERE m.conversation_id=c.id);')" == "0" ]] \
    || fail "invalid-prefix migration left conversation counts inconsistent"
}

test_matches_only_conservative_canonical_group_names() {
  local config="$fixture_dir/canonical-groups/groups.txt"
  write_config "$config" "Alpha" "Café" "项目 群"
  local database="$fixture_dir/canonical-groups.db"
  make_database "$database"
  insert_notification "$database" 51 1 201 " alpha " "张三" "CASE_PRIVATE"
  insert_notification "$database" 52 1 202 "Cafe" "张三" "DIACRITIC_PRIVATE"
  insert_notification "$database" 53 1 203 "项目群" "张三" "SPACE_PRIVATE"
  insert_notification "$database" 54 1 204 "项目​ 群" "张三" "ZERO_WIDTH_PRIVATE"
  insert_notification "$database" 55 1 205 "  Café  " "李四" "CANONICAL_MATCH"

  local output
  output=$(swift "$listener" --database "$database" --config "$config" \
    --include-existing --once --timeout 1 2>&1) \
    || fail "canonically equivalent group name did not match: $output"
  require_contains "$output" "[Café] 李四：CANONICAL_MATCH"
  require_absent "$output" "CASE_PRIVATE"
  require_absent "$output" "DIACRITIC_PRIVATE"
  require_absent "$output" "SPACE_PRIVATE"
  require_absent "$output" "ZERO_WIDTH_PRIVATE"
}

test_rejects_unsafe_config_and_store_paths_without_mutating_targets() {
  local database="$fixture_dir/path-safety-source.db"
  make_database "$database"
  insert_notification "$database" 61 1 301 "目标群" "张三" "PATH_PRIVATE"

  local shared_parent="$fixture_dir/shared-parent"
  local shared_config="$shared_parent/groups.txt"
  mkdir "$shared_parent"
  chmod 755 "$shared_parent"
  print -- "目标群" > "$shared_config"
  chmod 644 "$shared_config"
  local output exit_code=0
  output=$(swift "$listener" --database "$database" --config "$shared_config" \
    --include-existing --once --timeout 0.2 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "config in shared parent was accepted"
  [[ "$(stat -f %Lp "$shared_parent")" == "755" ]] || fail "shared config parent was mutated"
  [[ "$(stat -f %Lp "$shared_config")" == "644" ]] || fail "shared config file was mutated"

  local safe_parent="$fixture_dir/path-safe-config"
  local target="$fixture_dir/config-target.txt"
  local linked_config="$safe_parent/groups.txt"
  mkdir "$safe_parent"
  chmod 700 "$safe_parent"
  print -- "ORIGINAL_TARGET" > "$target"
  chmod 644 "$target"
  ln -s "$target" "$linked_config"
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$linked_config" \
    --group "目标群" --save-groups --once --timeout 0.2 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "symlink config was accepted"
  [[ "$(<"$target")" == "ORIGINAL_TARGET" ]] || fail "config symlink target was overwritten"
  [[ "$(stat -f %Lp "$target")" == "644" ]] || fail "config symlink target mode was mutated"

  rm "$linked_config"
  chmod 600 "$target"
  ln "$target" "$linked_config"
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$linked_config" \
    --group "目标群" --save-groups --once --timeout 0.2 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "hardlinked config was accepted"
  [[ "$(<"$target")" == "ORIGINAL_TARGET" ]] || fail "config hardlink target was overwritten"
  [[ "$(stat -f %Lp "$target")" == "600" ]] || fail "config hardlink target mode was mutated"

  rm "$linked_config"
  mkfifo "$linked_config"
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$linked_config" \
    --group "目标群" --save-groups --once --timeout 0.2 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "FIFO config was accepted"
  [[ -p "$linked_config" ]] || fail "FIFO config was replaced"

  local store_parent="$fixture_dir/path-safe-store"
  local store_target="$fixture_dir/store-target.sqlite3"
  local linked_store="$store_parent/messages.sqlite3"
  mkdir "$store_parent"
  chmod 700 "$store_parent"
  sqlite3 "$store_target" 'CREATE TABLE sentinel(value TEXT); INSERT INTO sentinel VALUES("KEEP");'
  chmod 644 "$store_target"
  ln "$store_target" "$linked_store"
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$shared_config" \
    --group "目标群" --store "$linked_store" --once --timeout 0.2 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "hardlinked message store was accepted"
  [[ "$(stat -f %Lp "$store_target")" == "644" ]] || fail "hardlinked store target mode was mutated"
  [[ "$(sqlite3 "$store_target" 'SELECT value FROM sentinel;')" == "KEEP" ]] \
    || fail "hardlinked store target was mutated"

  rm "$linked_store"
  chmod 600 "$store_target"
  ln -s "$store_target" "$linked_store"
  exit_code=0
  output=$(swift "$listener" --database "$database" --group "目标群" \
    --store "$linked_store" --once --timeout 0.2 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "symlink message store was accepted"
  [[ "$(stat -f %Lp "$store_target")" == "600" ]] || fail "symlink store target mode was mutated"
  [[ "$(sqlite3 "$store_target" 'SELECT value FROM sentinel;')" == "KEEP" ]] \
    || fail "symlink store target was mutated"

  rm "$linked_store"
  mkfifo "$linked_store"
  exit_code=0
  output=$(swift "$listener" --database "$database" --group "目标群" \
    --store "$linked_store" --once --timeout 0.2 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "FIFO message store was accepted"
  [[ -p "$linked_store" ]] || fail "FIFO message store was replaced"

  rm "$linked_store"
  : > "$linked_store"
  chmod 644 "$linked_store"
  exit_code=0
  output=$(swift "$listener" --database "$database" --group "目标群" \
    --store "$linked_store" --once --timeout 0.2 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "overly broad message store was accepted"
  [[ "$(stat -f %Lp "$linked_store")" == "644" ]] || fail "broad store mode was mutated"

  local missing_config="$fixture_dir/one-new-parent/groups.txt"
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$missing_config" \
    --group "目标群" --save-groups --include-existing --once --timeout 1 2>&1) || exit_code=$?
  (( exit_code == 0 )) || fail "one missing direct parent was not safely created: $output"
  [[ "$(stat -f %Lp "${missing_config:h}")" == "700" ]] || fail "created parent is not private"

  local nested_config="$fixture_dir/missing/ancestor/groups.txt"
  exit_code=0
  output=$(swift "$listener" --database "$database" --config "$nested_config" \
    --group "目标群" --save-groups --once --timeout 0.2 2>&1) || exit_code=$?
  (( exit_code != 0 )) || fail "multiple missing ancestors were recursively created"
  [[ ! -e "$fixture_dir/missing" ]] || fail "missing ancestors were created"
}

test_detects_new_low_record_id_in_a_crowded_database() {
  local database="$fixture_dir/lower-id.db"
  local config="$fixture_dir/lower-id/groups.txt"
  local output_file="$fixture_dir/lower-id-output.txt"
  make_database "$database"
  write_config "$config" "目标群"
  local baseline_payload=$(payload_hex "其他群" "成员" "历史消息")
  local record_id
  for record_id in {100..200}; do
    local uuid=$(printf '%016x' "$record_id")
    sqlite3 "$database" "INSERT INTO record(rec_id,app_id,uuid,data,request_date,request_last_date,delivered_date,presented,style) VALUES($record_id,1,X'$uuid',X'$baseline_payload',$record_id,$record_id,$record_id,1,1);"
  done

  swift "$listener" --database "$database" --config "$config" --once \
    --timeout 2 --poll-interval 0.05 > "$output_file" 2>&1 &
  local listener_pid=$!
  local ready=0
  local attempt
  for attempt in {1..100}; do
    if [[ -f "$output_file" ]] && rg -q --fixed-strings "监听已启动" "$output_file"; then
      ready=1
      break
    fi
    kill -0 "$listener_pid" 2>/dev/null || break
    sleep 0.05
  done
  (( ready == 1 )) || fail "listener did not report readiness"

  insert_notification "$database" 2 1 1000 "目标群" "王五" "低序号新消息"
  local exit_code=0
  wait "$listener_pid" || exit_code=$?
  local output=$(<"$output_file")
  (( exit_code == 0 )) || fail "listener missed lower record ID: $output"
  require_contains "$output" "[目标群] 王五：低序号新消息"
  require_absent "$output" "历史消息"
}

if [[ -n "${WXFOMO_TEST_FILTER:-}" ]]; then
  "$WXFOMO_TEST_FILTER"
  print -- "PASS: $WXFOMO_TEST_FILTER"
  exit 0
fi

test_rejects_cross_candidate_prefix_alias_ambiguity_before_writes
print -- "PASS: rejects cross-candidate prefix alias ambiguity before writes"
test_waits_for_every_prefix_owner_before_writing_recovered_aliases
print -- "PASS: waits for every prefix owner before writing recovered aliases"
test_preflights_every_version1_owner_before_any_consolidation_write
print -- "PASS: preflights every version-1 owner before consolidation writes"
test_recovers_real_65f_partial_version1_collision_atomically
print -- "PASS: recovers real 65f partial version-1 collisions atomically"
test_keeps_a_completed_65f_provenance_store_compatible
print -- "PASS: keeps completed 65f provenance stores compatible"
test_interrupts_a_large_version1_owner_at_the_once_deadline
print -- "PASS: interrupts a large version-1 owner at the once deadline"
test_interrupts_the_full_legacy_alias_scan_at_the_once_deadline
print -- "PASS: interrupts the full legacy alias scan at the once deadline"
test_reads_config_and_outputs_only_an_exact_group
print -- "PASS: reads config and outputs an exact configured group"
test_rejects_direct_chat_and_group_name_substrings
print -- "PASS: rejects direct chats and group-name substrings"
test_rejects_personal_wechat_source
print -- "PASS: rejects personal WeChat notifications"
test_saves_and_reuses_cli_groups
print -- "PASS: saves and reuses CLI group configuration"
test_rejects_conflicting_sender_fields
print -- "PASS: rejects conflicting sender fields"
test_detects_new_low_record_id_in_a_crowded_database
print -- "PASS: detects a new lower record ID in a crowded database"
test_paginates_large_same_timestamp_history_without_replay
print -- "PASS: paginates 50,000 same-timestamp history rows without replay"
test_exits_on_permanent_database_errors
print -- "PASS: exits on permanent database errors"
test_persists_verified_messages_idempotently
print -- "PASS: persists verified messages idempotently"
test_retries_temporary_persistence_locks_without_losing_the_notification
print -- "PASS: retries temporary persistence locks without data loss"
test_retries_a_store_lock_during_listener_startup
print -- "PASS: retries a store lock during listener startup"
test_resets_the_checkpoint_when_the_notification_source_changes
print -- "PASS: resets checkpoint when notification source changes"
test_rebinds_a_live_listener_after_atomic_source_replacement
print -- "PASS: rebinds a live listener after atomic source replacement"
test_rebinds_when_atomic_replace_lands_between_validation_and_fetch
print -- "PASS: rebinds across the validation/fetch atomic-replace race"
test_retries_initial_source_validation_after_atomic_replacement
print -- "PASS: retries an initial source-validation atomic replacement"
test_rebinds_when_atomic_replace_lands_during_startup
print -- "PASS: rebinds across a startup atomic-replace race"
test_uses_source_identity_for_uuidless_rows_in_different_databases
print -- "PASS: uses source identity for UUID-less rows in different databases"
test_fences_an_old_listener_after_a_new_instance_takes_ownership
print -- "PASS: fences an old listener after ownership changes"
test_recovers_an_uncheckpointed_notification_after_restart
print -- "PASS: recovers an uncheckpointed notification after restart"
test_replays_a_bound_source_with_a_null_cursor_after_interruption
print -- "PASS: replays a bound source whose cursor was left NULL"
test_waits_for_initial_source_schema_before_reporting_ready
print -- "PASS: waits for initial source schema before reporting ready"
test_default_discovery_retries_an_existing_partial_schema_at_one_hertz
print -- "PASS: default discovery retries an existing partial schema at one hertz"
test_default_discovery_reports_an_inaccessible_ancestor_without_missing_retry
print -- "PASS: default discovery reports inaccessible ancestor permissions"
test_default_discovery_fails_existing_unusable_sources_without_process_churn
print -- "PASS: default discovery fails unusable sources without process churn"
test_checkpoints_undecodable_rows_and_refreshes_heartbeat
print -- "PASS: checkpoints undecodable rows and refreshes heartbeat"
test_uses_one_stable_canonical_event_id_for_notification_updates
print -- "PASS: uses one stable canonical event ID for notification updates"
test_migrates_actual_precanonical_store_and_preserves_event_aliases
print -- "PASS: migrates actual pre-canonical rows and preserves event aliases"
test_upgrades_intermediate_alias_migration_with_historical_and_current_prefixes
print -- "PASS: upgrades intermediate stores with historical and current prefix aliases"
test_keeps_prefix_upgrade_pending_after_intermediate_folds_multiple_revisions
print -- "PASS: keeps prefix upgrade pending after intermediate folds multiple revisions"
test_keeps_prefix_upgrade_pending_without_a_version1_semantic_witness
print -- "PASS: keeps prefix upgrade pending without a version-1 semantic witness"
test_rejects_round5_witnesses_committed_after_marker301
print -- "PASS: rejects round-5 witnesses committed after marker 301"
test_rejects_early301_direct_witness_plus_backdated_round5_aliases
print -- "PASS: rejects an 808 direct witness mixed with backdated round-5 aliases"
test_upgrades_a_legitimate_baa_store_when_group_equals_sender
print -- "PASS: upgrades a legitimate baa store when group equals sender"
test_rejects_nonfinite_version1_times_on_a_legitimate_baa_store
print -- "PASS: rejects non-finite version-1 times on a legitimate baa store"
test_keeps_intermediate_prefix_upgrade_pending_on_a_historical_only_collision
print -- "PASS: keeps intermediate prefix upgrade pending on historical-only collisions"
test_filters_prefix_aliases_through_the_real_old_policy_projector
print -- "PASS: filters compatibility aliases through the real old policy projector"
test_matches_old_decoder_and_policy_for_embedded_colons_and_whitespace
print -- "PASS: matches old decoder and policy for sender edge cases"
test_completes_prefix_upgrade_after_the_historical_group_leaves_config
print -- "PASS: completes prefix upgrade after historical group config drift"
test_prefix_upgrade_work_scales_linearly_with_distinct_candidates
print -- "PASS: keeps prefix upgrade candidate work linear"
test_consolidates_multiple_stable_uuid_revisions_during_precanonical_migration
print -- "PASS: consolidates multiple stable-UUID pre-canonical revisions"
test_does_not_prebind_the_wrong_uuid_storage_class_alias
print -- "PASS: does not prebind the wrong UUID storage-class alias"
test_does_not_alias_a_precanonical_uuidless_row_to_a_new_source
print -- "PASS: keeps pre-canonical UUID-less rows distinct across sources"
test_keeps_byte_identical_precanonical_uuidless_rows_distinct_across_sources
print -- "PASS: keeps byte-identical UUID-less rows distinct across sources"
test_keeps_migration_pending_for_multiple_precanonical_fingerprints_at_one_row_id
print -- "PASS: keeps migration pending for multiple fingerprints at one row ID"
test_keeps_alias_migration_pending_on_an_exact_event_id_conflict
print -- "PASS: keeps alias migration pending on exact-ID conflicts"
test_ignores_prefix_hashes_rejected_by_the_old_native_policy
print -- "PASS: ignores prefix hashes rejected by the old native policy"
test_matches_only_conservative_canonical_group_names
print -- "PASS: matches only conservative canonical group names"
test_rejects_unsafe_config_and_store_paths_without_mutating_targets
print -- "PASS: rejects unsafe config and store paths without mutation"
