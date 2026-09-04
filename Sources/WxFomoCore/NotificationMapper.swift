import Foundation

public struct NotificationMapper: Sendable {
  public init() {}

  public func event(from record: NotificationRecord, groups: [String]) -> MessageEvent? {
    guard record.conversationType == 1 else { return nil }
    guard let groupMessage = WeComNotificationPolicy().groupMessage(
      title: record.title,
      subtitle: record.subtitle,
      body: record.body,
      configuredGroups: groups
    ) else {
      return nil
    }

    guard let eventID = canonicalEventID(from: record) else { return nil }
    return MessageEvent(
      eventID: eventID,
      group: groupMessage.group,
      senderDisplayName: groupMessage.sender,
      content: groupMessage.content,
      messageType: record.attachments.isEmpty ? inferKind(groupMessage.content) : .media,
      observedAt: record.deliveredAt,
      sourceSequence: record.rowID,
      attachments: record.attachments,
      senderConfidence: .notificationPayload,
      isFromSelf: false
    )
  }

  public func canonicalEventID(from record: NotificationRecord) -> String? {
    if let uuid = record.uuid, !uuid.isEmpty {
      return StableHash.hex("notification|\(uuid)")
    }
    guard let sourceIdentity = record.sourceIdentity, !sourceIdentity.isEmpty else { return nil }
    return StableHash.hex(
      "notification|source:\(sourceIdentity)|row:\(record.rowID)"
    )
  }

  public func legacyEventID(from record: NotificationRecord) -> String {
    let eventSeed = record.uuid ?? String(record.rowID)
    let attachmentSeed = record.attachments.map(\.fileURL.absoluteString).joined(separator: "|")
    return StableHash.hex(
      "notification|\(eventSeed)|\(record.title)|\(record.subtitle)|\(record.body)|\(attachmentSeed)"
    )
  }

  private func inferKind(_ content: String) -> MessageKind {
    let media = ["[图片]", "[视频]", "[语音]", "[文件]", "[Photo]", "[Video]", "[File]"]
    return media.contains(where: { content.localizedCaseInsensitiveContains($0) }) ? .media : .text
  }

}
