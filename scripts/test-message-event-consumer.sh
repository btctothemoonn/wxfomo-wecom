#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/wxfomo-message-consumer-test.XXXXXX")
trap 'rm -rf "$fixture_dir"' EXIT

/bin/cat > "$fixture_dir/compatibility.swift" <<'SWIFT'
import Foundation

public protocol Sendable {}

public enum MessageInsertResult: Equatable, Sendable {
  case inserted
  case updated
  case existing
}

public struct MessageEvent: Equatable, Sendable {
  public let eventID: String
  public let group: String
  public let content: String
  public let observedAt: Date
  public let sourceSequence: Int64?

  public init(
    eventID: String,
    group: String,
    content: String,
    observedAt: Date,
    sourceSequence: Int64?
  ) {
    self.eventID = eventID
    self.group = group
    self.content = content
    self.observedAt = observedAt
    self.sourceSequence = sourceSequence
  }
}
SWIFT

/bin/cat > "$fixture_dir/main.swift" <<'SWIFT'
import Foundation

private var failures: [String] = []

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { failures.append(message) }
}

private func event(
  id: String = "same-id",
  group: String = "测试群",
  content: String,
  observedAt: TimeInterval,
  sequence: Int64
) -> MessageEvent {
  MessageEvent(
    eventID: id,
    group: group,
    content: content,
    observedAt: Date(timeIntervalSince1970: observedAt),
    sourceSequence: sequence
  )
}

let original = event(content: "原消息", observedAt: 100, sequence: 10)
let updated = event(content: "更新消息", observedAt: 110, sequence: 11)
let update = MessageEventConsumer.withoutStore(updated, displayedMessages: [original])
check(update.displayUpdate == .replaceInMemory([updated]), "newer same-group update")
check(!update.shouldRunNewMessageSideEffects, "update side effects")
check(update.representsMessageUpdate, "update activity")

let equalTimeEvent = event(content: "同时间更新", observedAt: 100, sequence: 11)
let equalTime = MessageEventConsumer.withoutStore(
  equalTimeEvent,
  displayedMessages: [original]
)
check(equalTime.displayUpdate == .replaceInMemory([equalTimeEvent]), "equal-time update")
check(!equalTime.shouldRunNewMessageSideEffects, "equal-time update side effects")
check(equalTime.representsMessageUpdate, "equal-time update activity")

let identical = MessageEventConsumer.withoutStore(original, displayedMessages: [original])
check(identical.displayUpdate == .unchanged, "identical event guard")
check(!identical.shouldRunNewMessageSideEffects, "identical side effects")
check(!identical.representsMessageUpdate, "identical activity")

let olderEvent = event(content: "旧消息", observedAt: 90, sequence: 9)
let older = MessageEventConsumer.withoutStore(olderEvent, displayedMessages: [original])
check(older.displayUpdate == .unchanged, "older event guard")
check(!older.shouldRunNewMessageSideEffects, "older side effects")
check(!older.representsMessageUpdate, "older activity")

let crossGroupEvent = event(
  group: "其他群",
  content: "跨群更新",
  observedAt: 120,
  sequence: 12
)
let crossGroup = MessageEventConsumer.withoutStore(
  crossGroupEvent,
  displayedMessages: [original]
)
check(crossGroup.displayUpdate == .unchanged, "cross-group guard")
check(!crossGroup.shouldRunNewMessageSideEffects, "cross-group side effects")
check(!crossGroup.representsMessageUpdate, "cross-group activity")

let newEvent = event(
  id: "new-id",
  content: "新消息",
  observedAt: 120,
  sequence: 12
)
let inserted = MessageEventConsumer.withoutStore(newEvent, displayedMessages: [updated])
check(inserted.displayUpdate == .replaceInMemory([newEvent, updated]), "new event merge")
check(inserted.shouldRunNewMessageSideEffects, "new event side effects")
check(!inserted.representsMessageUpdate, "new event activity")

check(MessageEventConsumer.persisted(.updated).representsMessageUpdate, "persisted update activity")
check(!MessageEventConsumer.persisted(.existing).representsMessageUpdate, "persisted existing activity")

if failures.isEmpty {
  print("PASS: MessageEventConsumer no-store guards")
} else {
  for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
  exit(1)
}
SWIFT

swiftc -swift-version 5 \
  "$fixture_dir/compatibility.swift" \
  "$repo_root/Sources/WxFomoCore/MessageEventOrder.swift" \
  "$repo_root/Sources/WxFomoCore/MessageEventConsumer.swift" \
  "$fixture_dir/main.swift" \
  -o "$fixture_dir/message-event-consumer-test"
"$fixture_dir/message-event-consumer-test"
