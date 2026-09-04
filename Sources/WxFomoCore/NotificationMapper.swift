import Foundation

public struct NotificationMapper: Sendable {
  private static let ignoredGroupNameCharacters = CharacterSet.whitespacesAndNewlines.union(
    CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{2066}\u{2067}\u{2068}\u{2069}\u{FEFF}")
  )

  public init() {}

  public func event(from record: NotificationRecord, groups: [String]) -> MessageEvent? {
    guard let group = bestMatchingGroup(groups, record: record) else {
      return nil
    }

    var sender: String?
    var content = record.body
    if normalized(record.title).contains(normalized(group)) {
      sender = nonGroupValue(record.subtitle, group: group)
    } else if normalized(record.subtitle).contains(normalized(group)) {
      sender = nonGroupValue(record.title, group: group)
    }

    if let split = splitSenderPrefix(record.body) {
      if sender == nil { sender = split.sender }
      if sender.map(normalized) == normalized(split.sender) {
        content = split.content
      }
    }
    if sender == nil {
      sender = senderFromMentionNotice(record.body)
    }
    if content.isEmpty {
      content =
        [record.subtitle, record.title]
        .first { !$0.isEmpty && normalized($0) != normalized(group) } ?? ""
    }
    guard !content.isEmpty else { return nil }

    let eventSeed = record.uuid ?? String(record.rowID)
    let attachmentSeed = record.attachments.map(\.fileURL.absoluteString).joined(separator: "|")
    return MessageEvent(
      eventID: StableHash.hex(
        "notification|\(eventSeed)|\(record.title)|\(record.subtitle)|\(record.body)|\(attachmentSeed)"
      ),
      group: group,
      senderDisplayName: sender,
      content: content,
      messageType: record.attachments.isEmpty ? inferKind(content) : .media,
      observedAt: record.deliveredAt,
      sourceSequence: record.rowID,
      attachments: record.attachments,
      senderConfidence: sender == nil ? .unavailable : .notificationPayload,
      isFromSelf: false
    )
  }

  private func matchesGroup(_ group: String, record: NotificationRecord) -> Bool {
    let target = normalized(group)
    return [record.title, record.subtitle].contains {
      let candidate = normalized($0)
      return candidate == target || candidate.contains(target)
    }
  }

  private func bestMatchingGroup(_ groups: [String], record: NotificationRecord) -> String? {
    let values = [record.title, record.subtitle].map(normalized)
    let normalizedGroups = groups.map { (original: $0, normalized: normalized($0)) }
      .filter { !$0.normalized.isEmpty }
    if let exact = normalizedGroups.first(where: { values.contains($0.normalized) }) {
      return exact.original
    }
    return normalizedGroups
      .filter { group in values.contains { $0.contains(group.normalized) } }
      .max {
        if $0.normalized.count != $1.normalized.count {
          return $0.normalized.count < $1.normalized.count
        }
        return groups.firstIndex(of: $0.original)! > groups.firstIndex(of: $1.original)!
      }?.original
  }

  private func nonGroupValue(_ value: String, group: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !normalized(trimmed).contains(normalized(group)) else {
      return nil
    }
    return trimmed
  }

  private func splitSenderPrefix(_ value: String) -> (sender: String, content: String)? {
    for separator in ["：", ":"] {
      guard let range = value.range(of: separator) else { continue }
      let sender = String(value[..<range.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let content = String(value[range.upperBound...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !sender.isEmpty, sender.count <= 80, !content.isEmpty {
        return (sender, content)
      }
    }
    return nil
  }

  private func senderFromMentionNotice(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let suffixes = [
      "在群聊中@了你",
      "在群聊中提到了你",
      " mentioned you in a group chat",
    ]
    for suffix in suffixes {
      guard
        let range = trimmed.range(of: suffix, options: [.caseInsensitive, .backwards]),
        range.upperBound == trimmed.endIndex
      else { continue }
      let sender = trimmed[..<range.lowerBound]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !sender.isEmpty, sender.count <= 80 {
        return sender
      }
    }
    return nil
  }

  private func inferKind(_ content: String) -> MessageKind {
    let media = ["[图片]", "[视频]", "[语音]", "[文件]", "[Photo]", "[Video]", "[File]"]
    return media.contains(where: { content.localizedCaseInsensitiveContains($0) }) ? .media : .text
  }

  private func normalized(_ value: String) -> String {
    let folded = value.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: .current
    )
    return String(folded.unicodeScalars.filter {
      !Self.ignoredGroupNameCharacters.contains($0)
    })
  }
}
