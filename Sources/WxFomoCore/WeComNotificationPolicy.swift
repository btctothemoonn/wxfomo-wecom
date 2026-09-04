import Foundation

public struct WeComGroupNotification: Equatable {
  public let group: String
  public let sender: String
  public let content: String

  public init(group: String, sender: String, content: String) {
    self.group = group
    self.sender = sender
    self.content = content
  }
}

public struct WeComNotificationPolicy {
  public static let applicationBundleIdentifier = "com.tencent.WeWorkMac"
  public static let bundleIdentifier = "com.tencent.weworkmac"
  public static let teamIdentifier = "88l2q4487u"
  public static let notificationIdentifiers = [
    bundleIdentifier,
    "\(teamIdentifier).\(bundleIdentifier)",
  ]

  public init() {}

  public static func isNotificationIdentifier(_ identifier: String) -> Bool {
    let normalized = identifier
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return notificationIdentifiers.contains(normalized)
  }

  public func groupMessage(
    title: String,
    subtitle: String,
    body: String,
    configuredGroups: [String]
  ) -> WeComGroupNotification? {
    guard let group = bestMatchingGroup(
      configuredGroups,
      title: title,
      subtitle: subtitle
    ) else {
      return nil
    }

    let titleContainsGroup = normalized(title) == normalized(group)
    let senderFromField = titleContainsGroup
      ? nonGroupValue(subtitle, group: group)
      : nonGroupValue(title, group: group)
    let prefixed = splitSenderPrefix(body)
    if let senderFromField = senderFromField,
      let prefixed = prefixed,
      normalized(senderFromField) != normalized(prefixed.sender)
    {
      return nil
    }
    let sender = senderFromField ?? prefixed?.sender
    guard let resolvedSender = sender, !resolvedSender.isEmpty else { return nil }

    let content: String
    if let prefixed = prefixed,
      normalized(prefixed.sender) == normalized(resolvedSender)
    {
      content = prefixed.content
    } else {
      content = body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !content.isEmpty else { return nil }

    return WeComGroupNotification(
      group: group,
      sender: resolvedSender,
      content: content
    )
  }

  private func bestMatchingGroup(
    _ groups: [String],
    title: String,
    subtitle: String
  ) -> String? {
    let values = Set([title, subtitle].map(normalized).filter { !$0.isEmpty })
    var seen = Set<String>()
    let normalizedGroups = groups.compactMap { value -> (original: String, normalized: String)? in
      let original = value.trimmingCharacters(in: .whitespacesAndNewlines)
      let key = normalized(original)
      guard !key.isEmpty, seen.insert(key).inserted else { return nil }
      return (original: original, normalized: key)
    }

    let matching = normalizedGroups.filter { values.contains($0.normalized) }
    let distinctNormalized = Set(matching.map { $0.normalized })
    guard distinctNormalized.count == 1 else {
      return nil
    }
    return matching.first?.original
  }

  private func nonGroupValue(_ value: String, group: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, normalized(trimmed) != normalized(group) else {
      return nil
    }
    return trimmed
  }

  private func splitSenderPrefix(_ value: String) -> (sender: String, content: String)? {
    for separator in ["：", ":"] {
      guard let range = value.range(of: separator) else { continue }
      if separator == ":",
        range.upperBound < value.endIndex,
        !value[range.upperBound].isWhitespace
      {
        continue
      }
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

  private func normalized(_ value: String) -> String {
    return value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
  }
}
