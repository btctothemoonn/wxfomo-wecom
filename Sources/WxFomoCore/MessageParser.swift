import Foundation

public struct MessageParser: Sendable {
  private static let englishSaid = try! NSRegularExpression(
    pattern: #"^\s*(.+?)\s+Said:\s*(.*)$"#,
    options: [.caseInsensitive]
  )
  private static let chineseSaid = try! NSRegularExpression(
    pattern: #"^\s*(.+?)\s*(?:说|說)\s*[:：]\s*(.*)$"#
  )
  private static let englishMedia = try! NSRegularExpression(
    pattern: #"^\s*(.+?)\s*:\s*Sent an?\s+(.+)$"#,
    options: [.caseInsensitive]
  )
  private static let chineseMedia = try! NSRegularExpression(
    pattern: #"^\s*(.+?)\s*(?:发送了|傳送了)\s*(.+)$"#
  )

  public init() {}

  public func parse(row: RawMessageRow, group: String) -> ParsedMessage? {
    let labels = normalizedLabels(row.labels, excluding: group)
    guard !labels.isEmpty else { return nil }

    if labels.count == 1, isTimestamp(labels[0]) {
      return nil
    }

    for label in labels {
      if let parts = captures(Self.englishSaid, in: label) ?? captures(Self.chineseSaid, in: label)
      {
        return makeMessage(
          sender: parts.0,
          content: parts.1,
          kind: inferKind(parts.1),
          confidence: .localizedLabel
        )
      }
      if let parts = captures(Self.englishMedia, in: label)
        ?? captures(Self.chineseMedia, in: label)
      {
        return makeMessage(
          sender: parts.0,
          content: "[\(parts.1)]",
          kind: .media,
          confidence: .localizedLabel
        )
      }
    }

    let useful = labels.filter { !isTimestamp($0) }
    if useful.count >= 2,
      let sender = plausibleSender(in: useful),
      let content = plausibleContent(in: useful, sender: sender)
    {
      return makeMessage(
        sender: sender,
        content: content,
        kind: inferKind(content),
        confidence: .structuredFragments
      )
    }

    guard let content = useful.last, !content.isEmpty else { return nil }
    return ParsedMessage(
      senderDisplayName: nil,
      content: content,
      kind: inferKind(content),
      senderConfidence: .unavailable,
      isFromSelf: false
    )
  }

  private func normalizedLabels(_ labels: [String], excluding group: String) -> [String] {
    var result: [String] = []
    var seen = Set<String>()

    for raw in labels {
      let value =
        raw
        .replacingOccurrences(of: "\u{00a0}", with: " ")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty, value != group, !seen.contains(value) else { continue }
      seen.insert(value)
      result.append(value)
    }
    return result
  }

  private func captures(_ regex: NSRegularExpression, in value: String) -> (String, String)? {
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    guard let match = regex.firstMatch(in: value, range: range), match.numberOfRanges == 3,
      let senderRange = Range(match.range(at: 1), in: value),
      let contentRange = Range(match.range(at: 2), in: value)
    else {
      return nil
    }
    let sender = String(value[senderRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    let content = String(value[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sender.isEmpty, !content.isEmpty else { return nil }
    return (sender, content)
  }

  private func plausibleSender(in labels: [String]) -> String? {
    labels.first { value in
      value.count <= 80 && !value.contains("\n") && !isTimestamp(value)
        && !looksLikeSystemMessage(value)
    }
  }

  private func plausibleContent(in labels: [String], sender: String) -> String? {
    labels.reversed().first { value in
      value != sender && !isTimestamp(value)
    }
  }

  private func makeMessage(
    sender: String,
    content: String,
    kind: MessageKind,
    confidence: SenderConfidence
  ) -> ParsedMessage {
    let selfNames = Set(["Me", "You", "我", "自己"])
    return ParsedMessage(
      senderDisplayName: sender,
      content: content,
      kind: kind,
      senderConfidence: confidence,
      isFromSelf: selfNames.contains(sender)
    )
  }

  private func inferKind(_ content: String) -> MessageKind {
    let mediaMarkers = ["[Photo]", "[Image]", "[Video]", "[File]", "[图片]", "[视频]", "[文件]", "[语音]"]
    if mediaMarkers.contains(where: { content.localizedCaseInsensitiveContains($0) }) {
      return .media
    }
    if looksLikeSystemMessage(content) {
      return .system
    }
    return .text
  }

  private func looksLikeSystemMessage(_ value: String) -> Bool {
    let markers = [
      "加入了群聊", "退出了群聊", "撤回了一条消息", "拍了拍",
      "joined the group", "left the group", "recalled a message",
    ]
    return markers.contains { value.localizedCaseInsensitiveContains($0) }
  }

  private func isTimestamp(_ value: String) -> Bool {
    let patterns = [
      #"^\d{1,2}:\d{2}$"#,
      #"^\d{4}[/-]\d{1,2}[/-]\d{1,2}"#,
      #"^(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)"#,
      #"^(Yesterday|Today)$"#,
      #"^(星期|周)[一二三四五六日天]"#,
      #"^(昨天|今天)$"#,
    ]
    return patterns.contains {
      value.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
    }
  }
}
