#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/wxfomo-wecom-decoder-test.XXXXXX")
trap 'rm -rf "$fixture_dir"' EXIT

/bin/cat > "$fixture_dir/Compatibility.swift" <<'SWIFT'
public protocol Sendable {}
SWIFT

/bin/cat > "$fixture_dir/main.swift" <<'SWIFT'
import Foundation

private var failures: [String] = []

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { failures.append(message) }
}

private func payload(userData: Any?) -> Data {
  var request: [String: Any] = [
    "titl": "项目群",
    "subt": "张三",
    "body": "消息",
  ]
  if let userData = userData { request["usda"] = userData }
  return try! PropertyListSerialization.data(
    fromPropertyList: ["req": request],
    format: .binary,
    options: 0
  )
}

private func archive(_ value: Any) -> Data {
  return try! NSKeyedArchiver.archivedData(
    withRootObject: value,
    requiringSecureCoding: false
  )
}

let decoder = NotificationPayloadDecoder()
let date = Date(timeIntervalSince1970: 1_800_000_000)
let group = decoder.decode(
  data: payload(userData: archive(["ct": NSNumber(value: 1)])),
  rowID: 1,
  deliveredAt: date,
  uuid: "group",
  sourceIdentity: "/tmp/native-notification.db|1|101"
)
check(group?.conversationType == 1, "ct=1 decode")
check(
  group?.sourceIdentity == "/tmp/native-notification.db|1|101",
  "notification source identity propagation"
)

let direct = decoder.decode(
  data: payload(userData: archive(["ct": NSNumber(value: 0)])),
  rowID: 2,
  deliveredAt: date,
  uuid: "direct"
)
check(direct?.conversationType == 0, "ct=0 decode")

let missing = decoder.decode(
  data: payload(userData: nil),
  rowID: 3,
  deliveredAt: date,
  uuid: "missing"
)
check(missing?.conversationType == nil, "missing usda must remain unknown")

let malformed = decoder.decode(
  data: payload(userData: Data("not an archive".utf8)),
  rowID: 4,
  deliveredAt: date,
  uuid: "malformed"
)
check(malformed?.conversationType == nil, "malformed usda must remain unknown")

let missingCT = decoder.decode(
  data: payload(userData: archive(["other": NSNumber(value: 1)])),
  rowID: 5,
  deliveredAt: date,
  uuid: "missing-ct"
)
check(missingCT?.conversationType == nil, "missing ct must remain unknown")

if failures.isEmpty {
  print("PASS: WeCom notification payload conversation type")
} else {
  for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
  exit(1)
}
SWIFT

swiftc \
  "$fixture_dir/Compatibility.swift" \
  "$repo_root/Sources/WxFomoCore/Models.swift" \
  "$repo_root/Sources/WxFomoCore/NotificationPayloadDecoder.swift" \
  "$fixture_dir/main.swift" \
  -o "$fixture_dir/wecom-decoder-test"
"$fixture_dir/wecom-decoder-test"

reader_database="$fixture_dir/native-reader.db"
reader_database=$(/usr/bin/python3 -c 'import os, sys; print(os.path.normpath(sys.argv[1]))' \
  "$reader_database")
reader_payload="$fixture_dir/native-reader.plist"
/bin/cat > "$reader_payload" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>req</key><dict>
<key>titl</key><string>项目群</string>
<key>subt</key><string>张三</string>
<key>body</key><string>读取器源身份</string>
<key>usda</key><data>YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGlCwwVFhdVJG51bGzTDQ4PEBIUV05TLmtleXNaTlMub2JqZWN0c1YkY2xhc3OhEYACoROAA4AEUmN0EAHSGBkaG1okY2xhc3NuYW1lWCRjbGFzc2VzXE5TRGljdGlvbmFyeaIaHFhOU09iamVjdAgRGiQpMjdJTFFTWV9mbnmAgoSGiIqNj5SfqLW4AAAAAAAAAQEAAAAAAAAAHQAAAAAAAAAAAAAAAAAAAME=</data>
</dict></dict></plist>
PLIST
plutil -convert binary1 "$reader_payload"
reader_payload_hex=$(xxd -p -c 1000000 "$reader_payload")
sqlite3 "$reader_database" <<SQL
CREATE TABLE app(app_id INTEGER PRIMARY KEY, identifier TEXT);
CREATE TABLE record(
  rec_id INTEGER PRIMARY KEY,
  app_id INTEGER,
  uuid BLOB,
  data BLOB,
  request_date REAL,
  request_last_date REAL,
  delivered_date REAL
);
INSERT INTO app VALUES(1, 'com.tencent.WeWorkMac');
INSERT INTO record VALUES(7, 1, NULL, X'$reader_payload_hex', 100, 100, 100);
SQL
mkdir "$fixture_dir/reader"
/bin/cat > "$fixture_dir/reader/main.swift" <<'SWIFT'
import Foundation

let databaseURL = URL(fileURLWithPath: CommandLine.arguments[1])
let expectedIdentity = CommandLine.arguments[2]
let expectsSourceChange = CommandLine.arguments.count > 3
  && CommandLine.arguments[3] == "reject-source-change"
do {
  let records = try NotificationDatabaseReader(databaseURL: databaseURL).recentRecords(limit: 1)
  if expectsSourceChange {
    fputs("FAIL: native reader returned a batch after its source changed\n", stderr)
    exit(1)
  }
  guard records.count == 1 else {
    fputs("FAIL: native reader did not decode fixture\n", stderr)
    exit(1)
  }
  guard records[0].sourceIdentity == expectedIdentity else {
    let actualIdentity = records[0].sourceIdentity ?? "nil"
    fputs(
      "FAIL: native reader source identity mismatch: \(actualIdentity)\n",
      stderr
    )
    exit(1)
  }
  print("PASS: native notification reader source identity")
} catch {
  if expectsSourceChange {
    if case NotificationDatabaseError.queryFailed(let message) = error,
      message.contains("通知数据库在读取期间已更改")
    {
      print("PASS: native notification reader discards a replaced-source batch")
      exit(0)
    }
    fputs("FAIL: native reader threw the wrong replacement error: \(error)\n", stderr)
    exit(1)
  }
  fputs("FAIL: native reader threw: \(error)\n", stderr)
  exit(1)
}
SWIFT
swiftc \
  "$fixture_dir/Compatibility.swift" \
  "$repo_root/Sources/WxFomoCore/Models.swift" \
  "$repo_root/Sources/WxFomoCore/WeComNotificationPolicy.swift" \
  "$repo_root/Sources/WxFomoCore/NotificationPayloadDecoder.swift" \
  "$repo_root/Sources/WxFomoCore/NotificationDatabaseLocation.swift" \
  "$repo_root/Sources/WxFomoCore/NotificationDatabaseReader.swift" \
  "$fixture_dir/reader/main.swift" \
  -lsqlite3 \
  -o "$fixture_dir/native-reader-test"
reader_identity="$reader_database|$(stat -f %d "$reader_database")|$(stat -f %i "$reader_database")"
"$fixture_dir/native-reader-test" "$reader_database" "$reader_identity"

reader_old_database="$fixture_dir/native-reader-old.db"
reader_replacement_database="$fixture_dir/native-reader-replacement.db"
reader_lock_marker="$fixture_dir/native-reader.locked"
reader_race_output="$fixture_dir/native-reader-race.txt"
cp "$reader_database" "$reader_replacement_database"
sqlite3 "$reader_replacement_database" \
  "UPDATE record SET data=X'$reader_payload_hex', request_date=50, request_last_date=50, delivered_date=50 WHERE rec_id=7;"
(
  print -- 'BEGIN EXCLUSIVE;'
  print -- ".shell touch '$reader_lock_marker'"
  sleep 0.5
  print -- 'COMMIT;'
) | sqlite3 "$reader_database" &
reader_lock_pid=$!
for _ in {1..100}; do
  [[ -e "$reader_lock_marker" ]] && break
  sleep 0.01
done
[[ -e "$reader_lock_marker" ]] \
  || { kill "$reader_lock_pid" 2>/dev/null || true; wait "$reader_lock_pid" 2>/dev/null || true; print -u2 -- 'FAIL: could not lock native reader fixture'; exit 1; }
"$fixture_dir/native-reader-test" "$reader_database" "$reader_identity" \
  reject-source-change > "$reader_race_output" 2>&1 &
reader_race_pid=$!
sleep 0.1
mv "$reader_database" "$reader_old_database"
mv "$reader_replacement_database" "$reader_database"
wait "$reader_lock_pid"
reader_race_exit=0
wait "$reader_race_pid" || reader_race_exit=$?
(( reader_race_exit == 0 )) || { /bin/cat "$reader_race_output" >&2; exit "$reader_race_exit"; }
/bin/cat "$reader_race_output"
