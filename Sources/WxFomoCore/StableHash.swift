import Foundation

public enum StableHash {
  public static func hex(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
  }

  public static func notificationRecordFingerprint(_ record: NotificationRecord) -> String {
    let attachmentSeed = record.attachments.map(\.fileURL.absoluteString).joined(separator: "|")
    return hex(
      "notification-record|\(record.sourceIdentity ?? "")|\(record.rowID)|"
        + "\(record.uuid ?? "")|\(record.deliveredAt.timeIntervalSinceReferenceDate)|"
        + "\(record.title)|\(record.subtitle)|\(record.body)|\(attachmentSeed)"
    )
  }
}
