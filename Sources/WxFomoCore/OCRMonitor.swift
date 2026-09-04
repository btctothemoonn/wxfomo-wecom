import CoreGraphics
import Foundation

private struct OCRGroupState {
  var windowID: UInt32
  var bindingKey: String
  var signatures: [String]
  var sequence: UInt64
}

public final class WeChatOCRMonitor {
  public typealias EventSink = (MessageEvent) -> Void
  public typealias LogSink = (String) -> Void

  private let reader: WeChatOCRReader
  private let parser: MessageParser
  private let options: MonitorOptions
  private let onEvent: EventSink
  private let onLog: LogSink
  private var states: [String: OCRGroupState] = [:]
  private var lastErrorLogAt: [String: Date] = [:]

  public init(
    reader: WeChatOCRReader = WeChatOCRReader(),
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

  public func run() async throws {
    guard !options.groups.isEmpty else { throw MonitorError.noGroups }
    guard options.interval >= 0.5 else { throw MonitorError.intervalTooShort }
    guard CGPreflightScreenCaptureAccess() else {
      throw OCRReaderError.screenCapturePermissionMissing
    }

    onLog("OCR 监听启动；只捕获白名单群窗口，不会操作微信")
    while !Task.isCancelled {
      await pollOnce()
      try await Task.sleep(for: .seconds(options.interval))
    }
  }

  private func pollOnce() async {
    for group in options.groups {
      do {
        let snapshot = try await reader.snapshot(
          group: group,
          boundWindowID: states[group]?.windowID
        )
        process(snapshot)
      } catch {
        logThrottled("\(group): \(error.localizedDescription)", key: group)
      }
    }
  }

  private func process(_ snapshot: OCRGroupSnapshot) {
    let current = snapshot.rows.map(\.signature).filter { !$0.isEmpty }
    guard var state = states[snapshot.group] else {
      let baselineSequence = options.includeExisting ? UInt64(snapshot.rows.count) : 0
      states[snapshot.group] = OCRGroupState(
        windowID: snapshot.windowID,
        bindingKey: snapshot.bindingKey,
        signatures: current,
        sequence: baselineSequence
      )
      onLog("已绑定群聊“\(snapshot.group)”窗口 \(snapshot.windowID)（\(snapshot.confidence.rawValue)）")
      if options.includeExisting {
        emit(rows: snapshot.rows, group: snapshot.group, sequenceEnd: baselineSequence)
      }
      return
    }

    guard state.bindingKey == snapshot.bindingKey else {
      states[snapshot.group] = OCRGroupState(
        windowID: snapshot.windowID,
        bindingKey: snapshot.bindingKey,
        signatures: current,
        sequence: state.sequence
      )
      onLog("群聊“\(snapshot.group)”绑定窗口变化，已重建基线")
      return
    }

    let delta = SequenceDelta.appended(previous: state.signatures, current: current)
    if !delta.hadContinuity, !state.signatures.isEmpty, !current.isEmpty {
      onLog("群聊“\(snapshot.group)”OCR 序列失去连续性；当前帧可能包含重复")
    }
    if !delta.newItems.isEmpty {
      let start = max(0, snapshot.rows.count - delta.newItems.count)
      let rows = Array(snapshot.rows.dropFirst(start))
      state.sequence &+= UInt64(rows.count)
      emit(rows: rows, group: snapshot.group, sequenceEnd: state.sequence)
    }
    state.windowID = snapshot.windowID
    state.signatures = current
    states[snapshot.group] = state
  }

  private func emit(rows: [RawMessageRow], group: String, sequenceEnd: UInt64) {
    let first =
      sequenceEnd >= UInt64(rows.count)
      ? sequenceEnd - UInt64(rows.count) + 1
      : 1
    for (offset, row) in rows.enumerated() {
      guard let parsed = parser.parse(row: row, group: group) else { continue }
      let sequence = first + UInt64(offset)
      onEvent(
        MessageEvent(
          eventID: StableHash.hex("ocr|\(group)|\(sequence)|\(row.signature)"),
          group: group,
          senderDisplayName: parsed.senderDisplayName,
          content: parsed.content,
          messageType: parsed.kind,
          observedAt: Date(),
          senderConfidence: parsed.senderConfidence,
          isFromSelf: parsed.isFromSelf
        ))
    }
  }

  private func logThrottled(_ message: String, key: String) {
    let now = Date()
    if let last = lastErrorLogAt[key], now.timeIntervalSince(last) < 30 { return }
    lastErrorLogAt[key] = now
    onLog(message)
  }
}
