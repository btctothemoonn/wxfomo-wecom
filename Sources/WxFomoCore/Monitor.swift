import Foundation

public struct MonitorOptions: Sendable {
  public let groups: [String]
  public let interval: TimeInterval
  public let includeExisting: Bool
  public let allowSingleGroupFallback: Bool

  public init(
    groups: [String],
    interval: TimeInterval = 0.75,
    includeExisting: Bool = false,
    allowSingleGroupFallback: Bool = false
  ) {
    self.groups = groups
    self.interval = interval
    self.includeExisting = includeExisting
    self.allowSingleGroupFallback = allowSingleGroupFallback
  }
}

private struct GroupState {
  var bindingKey: String
  var signatures: [String]
  var sequence: UInt64
}

public final class WeChatMonitor {
  public typealias EventSink = (MessageEvent) -> Void
  public typealias LogSink = (String) -> Void

  private let reader: WeChatAccessibilityReader
  private let parser: MessageParser
  private let options: MonitorOptions
  private let onEvent: EventSink
  private let onLog: LogSink
  private var states: [String: GroupState] = [:]
  private var lastErrorLogAt: [String: Date] = [:]

  public init(
    reader: WeChatAccessibilityReader = WeChatAccessibilityReader(),
    parser: MessageParser = MessageParser(),
    options: MonitorOptions,
    onEvent: @escaping EventSink,
    onLog: @escaping LogSink = { _ in }
  ) {
    self.reader = reader
    self.parser = parser
    self.options = options
    self.onEvent = onEvent
    self.onLog = onLog
  }

  public func run() throws {
    guard !options.groups.isEmpty else {
      throw MonitorError.noGroups
    }
    guard options.interval >= 0.25 else {
      throw MonitorError.intervalTooShort
    }

    let report = reader.doctor()
    guard report.accessibilityTrusted else {
      throw WeChatReaderError.accessibilityPermissionMissing
    }
    guard report.weChatRunning else {
      throw WeChatReaderError.weChatNotRunning
    }

    onLog("监听启动；仅读取已经打开的群聊窗口，不会操作微信")
    while true {
      autoreleasepool {
        pollOnce()
      }
      Thread.sleep(forTimeInterval: options.interval)
    }
  }

  private func pollOnce() {
    for group in options.groups {
      do {
        let snapshot = try reader.readSnapshot(
          group: group,
          allowSingleGroupFallback: options.allowSingleGroupFallback
        )
        process(snapshot)
      } catch {
        logThrottled("\(group): \(error.localizedDescription)", key: group)
      }
    }
  }

  private func process(_ snapshot: GroupSnapshot) {
    let current = snapshot.rows.map(\.signature).filter { !$0.isEmpty }
    guard var state = states[snapshot.group] else {
      let baselineSequence = options.includeExisting ? UInt64(snapshot.rows.count) : 0
      states[snapshot.group] = GroupState(
        bindingKey: snapshot.bindingKey,
        signatures: current,
        sequence: baselineSequence
      )
      onLog("已绑定群聊“\(snapshot.group)”（\(snapshot.confidence.rawValue)），当前可见消息作为基线")
      if options.includeExisting {
        emit(
          rows: snapshot.rows,
          group: snapshot.group,
          sequenceEnd: baselineSequence
        )
      }
      return
    }

    guard state.bindingKey == snapshot.bindingKey else {
      state.bindingKey = snapshot.bindingKey
      state.signatures = current
      states[snapshot.group] = state
      onLog("群聊“\(snapshot.group)”窗口发生变化，已重建基线且未回放旧消息")
      return
    }

    let delta = SequenceDelta.appended(previous: state.signatures, current: current)
    if !delta.hadContinuity, !state.signatures.isEmpty, !current.isEmpty {
      onLog("群聊“\(snapshot.group)”可见消息序列失去连续性；将当前内容视为新增，可能包含重复")
    }

    if !delta.newItems.isEmpty {
      let start = max(0, snapshot.rows.count - delta.newItems.count)
      let newRows = Array(snapshot.rows.dropFirst(start))
      state.sequence &+= UInt64(newRows.count)
      emit(rows: newRows, group: snapshot.group, sequenceEnd: state.sequence)
    }
    state.signatures = current
    states[snapshot.group] = state
  }

  private func emit(rows: [RawMessageRow], group: String, sequenceEnd: UInt64? = nil) {
    let finalSequence = sequenceEnd ?? UInt64(rows.count)
    let firstSequence =
      finalSequence >= UInt64(rows.count)
      ? finalSequence - UInt64(rows.count) + 1
      : 1

    for (offset, row) in rows.enumerated() {
      guard let parsed = parser.parse(row: row, group: group) else { continue }
      let sequence = firstSequence + UInt64(offset)
      let event = MessageEvent(
        eventID: StableHash.hex("\(group)|\(sequence)|\(row.signature)"),
        group: group,
        senderDisplayName: parsed.senderDisplayName,
        content: parsed.content,
        messageType: parsed.kind,
        observedAt: Date(),
        senderConfidence: parsed.senderConfidence,
        isFromSelf: parsed.isFromSelf
      )
      onEvent(event)
    }
  }

  private func logThrottled(_ message: String, key: String) {
    let now = Date()
    if let last = lastErrorLogAt[key], now.timeIntervalSince(last) < 30 {
      return
    }
    lastErrorLogAt[key] = now
    onLog(message)
  }
}

public enum MonitorError: LocalizedError {
  case noGroups
  case intervalTooShort

  public var errorDescription: String? {
    switch self {
    case .noGroups:
      return "至少需要一个 --group"
    case .intervalTooShort:
      return "轮询间隔不能小于当前监听模式允许的最小值"
    }
  }
}
