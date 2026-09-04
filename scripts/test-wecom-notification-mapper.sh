#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/wxfomo-wecom-mapper-test.XXXXXX")
trap 'rm -rf "$fixture_dir"' EXIT

/bin/cat > "$fixture_dir/main.swift" <<'SWIFT'
import Foundation

public protocol Sendable {}
public enum MessageKind { case text, media }
public enum SenderConfidence { case unavailable, notificationPayload }
public enum MessageAttachmentKind { case image }

public struct MessageAttachment {
  public let fileURL: URL
  public init(fileURL: URL) { self.fileURL = fileURL }
}

public struct NotificationRecord {
  public let rowID: Int64
  public let uuid: String?
  public let sourceIdentity: String?
  public let deliveredAt: Date
  public let title: String
  public let subtitle: String
  public let body: String
  public let identifier: String
  public let attachments: [MessageAttachment]
  public let conversationType: Int?

  public init(
    rowID: Int64,
    uuid: String? = nil,
    sourceIdentity: String? = "fixture-source",
    conversationType: Int?,
    title: String,
    subtitle: String,
    body: String
  ) {
    self.rowID = rowID
    self.uuid = uuid
    self.sourceIdentity = sourceIdentity
    self.deliveredAt = Date(timeIntervalSince1970: 1_800_000_000)
    self.title = title
    self.subtitle = subtitle
    self.body = body
    self.identifier = "fixture"
    self.attachments = []
    self.conversationType = conversationType
  }
}

public struct MessageEvent {
  public let eventID: String
  public let group: String
  public let senderDisplayName: String?
  public let content: String
  public let messageType: MessageKind
  public let observedAt: Date
  public let sourceSequence: Int64
  public let attachments: [MessageAttachment]
  public let senderConfidence: SenderConfidence
  public let isFromSelf: Bool
}

private var failures: [String] = []
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { failures.append(message) }
}

let mapper = NotificationMapper()
let group = NotificationRecord(
  rowID: 1,
  uuid: "000000000000002c",
  conversationType: 1,
  title: "项目群",
  subtitle: "",
  body: "张三：测试消息"
)
let event = mapper.event(from: group, groups: ["项目群"])
check(event?.group == "项目群", "configured group")
check(event?.senderDisplayName == "张三", "group sender")
check(event?.content == "测试消息", "group body")
check(event?.eventID == "ed90e2ba579eb7e5", "canonical event ID")
check(
  mapper.legacyEventID(from: group) == "463c24d1546721c0",
  "pre-canonical native event ID compatibility"
)

let updated = NotificationRecord(
  rowID: 99,
  uuid: "000000000000002c",
  conversationType: 1,
  title: "项目群",
  subtitle: "",
  body: "张三：更新后内容"
)
check(
  mapper.event(from: updated, groups: ["项目群"])?.eventID == event?.eventID,
  "content and row updates must not change canonical event ID"
)

let firstSourceWithoutUUID = NotificationRecord(
  rowID: 7,
  uuid: nil,
  sourceIdentity: "/tmp/source-a|1|101",
  conversationType: 1,
  title: "项目群",
  subtitle: "张三",
  body: "第一个库"
)
let secondSourceWithoutUUID = NotificationRecord(
  rowID: 7,
  uuid: nil,
  sourceIdentity: "/tmp/source-b|1|202",
  conversationType: 1,
  title: "项目群",
  subtitle: "张三",
  body: "第二个库"
)
check(
  mapper.event(from: firstSourceWithoutUUID, groups: ["项目群"])?.eventID
    == "a9c8a0eb7c56a485",
  "UUID-less event ID must include the first source identity"
)
check(
  mapper.event(from: secondSourceWithoutUUID, groups: ["项目群"])?.eventID
    == "7c2376ab4dbbe504",
  "UUID-less event ID must include the second source identity"
)
let sameContentFromSecondSource = NotificationRecord(
  rowID: 7,
  uuid: nil,
  sourceIdentity: "/tmp/source-b|1|202",
  conversationType: 1,
  title: "项目群",
  subtitle: "张三",
  body: "第一个库"
)
check(
  StableHash.notificationRecordFingerprint(firstSourceWithoutUUID)
    != StableHash.notificationRecordFingerprint(sameContentFromSecondSource),
  "monitor record fingerprints must include notification source identity"
)

let compatibilityFixture = NotificationRecord(
  rowID: 44,
  uuid: "000000000000002c",
  conversationType: 1,
  title: "目标群",
  subtitle: "王五",
  body: "初始内容"
)

let compatibilityRevisionA = NotificationRecord(
  rowID: 44,
  uuid: "000000000000002c",
  conversationType: 1,
  title: "目标群",
  subtitle: "",
  body: "王五：初始内容"
)

let compatibilityRevisionB = NotificationRecord(
  rowID: 44,
  uuid: "000000000000002c",
  conversationType: 1,
  title: "目标群",
  subtitle: "",
  body: "赵六：版本 B"
)

let compatibilityRevisionC = NotificationRecord(
  rowID: 44,
  uuid: "000000000000002c",
  conversationType: 1,
  title: "目标群",
  subtitle: "",
  body: "孙七：版本 C"
)

let sameTitleDirect = NotificationRecord(
  rowID: 4,
  conversationType: 0,
  title: "项目群",
  subtitle: "",
  body: "张三：DIRECT_PRIVATE"
)
check(
  mapper.event(from: sameTitleDirect, groups: ["项目群"]) == nil,
  "same-title direct chat must fail closed"
)

let missingConversationType = NotificationRecord(
  rowID: 5,
  conversationType: nil,
  title: "项目群",
  subtitle: "",
  body: "张三：MISSING_CT_PRIVATE"
)
check(
  mapper.event(from: missingConversationType, groups: ["项目群"]) == nil,
  "missing conversation type must fail closed"
)

let direct = NotificationRecord(
  rowID: 2,
  conversationType: 1,
  title: "联系人张三",
  subtitle: "",
  body: "单聊消息"
)
check(mapper.event(from: direct, groups: ["项目群"]) == nil, "direct chat rejection")

let ambiguous = NotificationRecord(
  rowID: 3,
  conversationType: 1,
  title: "项目群",
  subtitle: "",
  body: "缺少发送者前缀"
)
check(mapper.event(from: ambiguous, groups: ["项目群"]) == nil, "fail-closed mapping")

if failures.isEmpty {
  if let sourceIdentity = ProcessInfo.processInfo.environment[
    "WXFOMO_PRINT_UUIDLESS_SOURCE_IDENTITY"
  ] {
    let rowID = Int64(
      ProcessInfo.processInfo.environment["WXFOMO_PRINT_UUIDLESS_ROW_ID"] ?? "7"
    ) ?? 7
    let sourceFixture = NotificationRecord(
      rowID: rowID,
      uuid: nil,
      sourceIdentity: sourceIdentity,
      conversationType: 1,
      title: "项目群",
      subtitle: "张三",
      body: "源身份比对"
    )
    print(mapper.event(from: sourceFixture, groups: ["项目群"])?.eventID ?? "")
  } else if ProcessInfo.processInfo.environment["WXFOMO_PRINT_COMPATIBILITY_EVENT_IDS"] == "1" {
    print(mapper.event(from: compatibilityFixture, groups: ["目标群"])?.eventID ?? "")
    print(mapper.legacyEventID(from: compatibilityFixture))
  } else if ProcessInfo.processInfo.environment["WXFOMO_PRINT_REVISION_COMPATIBILITY_IDS"] == "1" {
    print(mapper.event(from: compatibilityRevisionA, groups: ["目标群"])?.eventID ?? "")
    print(mapper.legacyEventID(from: compatibilityRevisionA))
    print(mapper.legacyEventID(from: compatibilityRevisionB))
    print(mapper.legacyEventID(from: compatibilityRevisionC))
  } else if ProcessInfo.processInfo.environment["WXFOMO_PRINT_CANONICAL_EVENT_ID"] == "1" {
    print(event?.eventID ?? "")
  } else {
    print("PASS: WeCom notification mapper")
  }
} else {
  for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
  exit(1)
}
SWIFT

old_oracle_dir="$fixture_dir/precanonical-native-oracle"
mkdir -p "$old_oracle_dir"
git show 'c0c20ed^:Sources/WxFomoCore/NotificationMapper.swift' \
  > "$old_oracle_dir/NotificationMapper.swift"
git show 'c0c20ed^:Sources/WxFomoCore/WeComNotificationPolicy.swift' \
  > "$old_oracle_dir/WeComNotificationPolicy.swift"
git show 'c0c20ed^:Sources/WxFomoCore/StableHash.swift' \
  > "$old_oracle_dir/StableHash.swift"

/bin/cat > "$old_oracle_dir/main.swift" <<'SWIFT'
import Foundation

public protocol Sendable {}
public enum MessageKind { case text, media }
public enum SenderConfidence { case unavailable, notificationPayload }

public struct MessageAttachment {
  public let fileURL: URL
  public init(fileURL: URL) { self.fileURL = fileURL }
}

public struct NotificationRecord {
  public let rowID: Int64
  public let uuid: String?
  public let deliveredAt: Date
  public let title: String
  public let subtitle: String
  public let body: String
  public let identifier: String
  public let attachments: [MessageAttachment]

  public init(rowID: Int64, uuid: String, title: String, subtitle: String, body: String) {
    self.rowID = rowID
    self.uuid = uuid
    self.deliveredAt = Date(timeIntervalSince1970: 1_800_000_000)
    self.title = title
    self.subtitle = subtitle
    self.body = body
    self.identifier = "fixture"
    self.attachments = []
  }
}

public struct MessageEvent {
  public let eventID: String
  public let group: String
  public let senderDisplayName: String?
  public let content: String
  public let messageType: MessageKind
  public let observedAt: Date
  public let sourceSequence: Int64
  public let attachments: [MessageAttachment]
  public let senderConfidence: SenderConfidence
  public let isFromSelf: Bool
}

private var failures: [String] = []
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { failures.append(message) }
}

let environment = ProcessInfo.processInfo.environment
let group = environment["WXFOMO_PREFIX_GROUP"] ?? "目标群"
let eventSeed = environment["WXFOMO_PREFIX_EVENT_SEED"] ?? "000000000000002c"
let sender = environment["WXFOMO_PREFIX_SENDER"] ?? "王五"
let content = environment["WXFOMO_PREFIX_CONTENT"] ?? "初始内容"
let expectedValidity = [true, true, true, true, false, true, false, true]
let mapper = NotificationMapper()

typealias OracleResult = (event: MessageEvent?, rawEventID: String)

func oracleClean(_ value: String) -> String {
  return value
    .replacingOccurrences(of: "\r", with: " ")
    .replacingOccurrences(of: "\n", with: " ")
    .replacingOccurrences(of: "\t", with: " ")
    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

func oracleResult(title: String, subtitle: String, body: String) -> OracleResult {
  let cleanTitle = oracleClean(title)
  let cleanSubtitle = oracleClean(subtitle)
  let cleanBody = oracleClean(body)
  let record = NotificationRecord(
    rowID: 44,
    uuid: eventSeed,
    title: cleanTitle,
    subtitle: cleanSubtitle,
    body: cleanBody
  )
  return (
    event: mapper.event(from: record, groups: [group]),
    rawEventID: StableHash.hex(
      "notification|\(eventSeed)|\(cleanTitle)|\(cleanSubtitle)|\(cleanBody)|"
    )
  )
}

func prefixBodies(sender: String, content: String) -> [String] {
  return [
    "\(sender)：\(content)",
    "\(sender)： \(content)",
    "\(sender) ：\(content)",
    "\(sender) ： \(content)",
    "\(sender):\(content)",
    "\(sender): \(content)",
    "\(sender) :\(content)",
    "\(sender) : \(content)",
  ]
}

func bodyOnlyPrefixResults(
  sender: String,
  content: String
) -> [OracleResult] {
  return prefixBodies(sender: sender, content: content).map {
    oracleResult(title: group, subtitle: "", body: $0)
  }
}

func prefixResults(sender: String, content: String) -> [OracleResult] {
  return prefixBodies(sender: sender, content: content).flatMap { body in
    return [
      oracleResult(title: group, subtitle: "", body: body),
      oracleResult(title: "", subtitle: group, body: body),
      oracleResult(title: group, subtitle: sender, body: body),
      oracleResult(title: sender, subtitle: group, body: body),
      oracleResult(title: group, subtitle: group, body: body),
    ]
  }
}

func directResults(sender: String, content: String) -> [OracleResult] {
  return [
    oracleResult(title: group, subtitle: sender, body: content),
    oracleResult(title: sender, subtitle: group, body: content),
  ]
}

func semanticallyMatchingEventIDs(
  _ results: [OracleResult],
  sender: String,
  content: String
) -> [String] {
  return results.compactMap { result in
    guard let event = result.event,
      oracleClean(event.senderDisplayName ?? "") == oracleClean(sender),
      oracleClean(event.content) == oracleClean(content)
    else {
      return nil
    }
    return event.eventID
  }
}

let defaultResults = bodyOnlyPrefixResults(sender: "王五", content: "初始内容")
for (index, result) in defaultResults.enumerated() {
  check(
    (result.event != nil) == expectedValidity[index],
    "pre-canonical event(from:) validity mismatch for prefix layout \(index + 1)"
  )
}
check(
  semanticallyMatchingEventIDs(
    prefixResults(sender: "王五", content: "初始内容"),
    sender: "王五",
    content: "初始内容"
  ).count == 30,
  "pre-canonical oracle must produce all 30 compatible prefix-layout IDs"
)
let longSender = String(repeating: "丙", count: 81)
check(
  semanticallyMatchingEventIDs(
    prefixResults(sender: longSender, content: "初始内容"),
    sender: longSender,
    content: "初始内容"
  ).isEmpty,
  "pre-canonical prefix policy must reject senders longer than 80 characters"
)
check(
  semanticallyMatchingEventIDs(
    prefixResults(sender: "王：五", content: "初始内容"),
    sender: "王：五",
    content: "初始内容"
  ).isEmpty,
  "pre-canonical prefix policy must not reinterpret an embedded sender colon"
)
check(
  semanticallyMatchingEventIDs(
    directResults(sender: longSender, content: "初始内容"),
    sender: longSender,
    content: "初始内容"
  ).count == 2,
  "pre-canonical direct-field policy must retain a long sender"
)
check(
  semanticallyMatchingEventIDs(
    directResults(sender: "王：五", content: "初始内容"),
    sender: "王：五",
    content: "初始内容"
  ).count == 2,
  "pre-canonical direct-field policy must retain an embedded sender colon"
)
let whitespaceHeavySender = "丙" + String(repeating: "  ", count: 50) + "丁"
check(
  semanticallyMatchingEventIDs(
    prefixResults(sender: whitespaceHeavySender, content: "初始内容"),
    sender: whitespaceHeavySender,
    content: "初始内容"
  ).count == 30,
  "pre-canonical decoder must clean whitespace before the sender-length policy"
)

let requestedResults = prefixResults(sender: sender, content: content)
let validPrefixEventIDs = semanticallyMatchingEventIDs(
  requestedResults,
  sender: sender,
  content: content
)
let validEventIDSet = Set(validPrefixEventIDs)
let invalidRawHashIDs = requestedResults.compactMap { result in
  return validEventIDSet.contains(result.rawEventID) ? nil : result.rawEventID
}
let fullCompatibilityEventIDs = semanticallyMatchingEventIDs(
  directResults(sender: sender, content: content) + requestedResults,
  sender: sender,
  content: content
)

if failures.isEmpty {
  if environment["WXFOMO_PRINT_PREFIX_COMPATIBILITY_IDS"] == "1" {
    validPrefixEventIDs.forEach { print($0) }
  } else if environment["WXFOMO_PRINT_FULL_COMPATIBILITY_IDS"] == "1" {
    fullCompatibilityEventIDs.forEach { print($0) }
  } else if environment["WXFOMO_PRINT_INVALID_PREFIX_HASH_IDS"] == "1" {
    invalidRawHashIDs.forEach { print($0) }
  }
} else {
  for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
  exit(1)
}
SWIFT

swiftc \
  "$old_oracle_dir/WeComNotificationPolicy.swift" \
  "$old_oracle_dir/NotificationMapper.swift" \
  "$old_oracle_dir/StableHash.swift" \
  "$old_oracle_dir/main.swift" \
  -o "$old_oracle_dir/precanonical-native-oracle"

if [[ "${WXFOMO_PRINT_PREFIX_COMPATIBILITY_IDS:-0}" == "1" \
   || "${WXFOMO_PRINT_FULL_COMPATIBILITY_IDS:-0}" == "1" \
   || "${WXFOMO_PRINT_INVALID_PREFIX_HASH_IDS:-0}" == "1" ]]; then
  "$old_oracle_dir/precanonical-native-oracle"
  exit 0
fi
"$old_oracle_dir/precanonical-native-oracle"

swiftc \
  "$repo_root/Sources/WxFomoCore/WeComNotificationPolicy.swift" \
  "$repo_root/Sources/WxFomoCore/NotificationMapper.swift" \
  "$repo_root/Sources/WxFomoCore/StableHash.swift" \
  "$fixture_dir/main.swift" \
  -o "$fixture_dir/wecom-mapper-test"
"$fixture_dir/wecom-mapper-test"
