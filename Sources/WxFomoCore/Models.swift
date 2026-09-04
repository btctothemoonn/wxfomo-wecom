import Foundation

public struct ElementFrame: Codable, Equatable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public struct RawMessageRow: Equatable, Sendable {
  public let labels: [String]
  public let frame: ElementFrame?

  public init(labels: [String], frame: ElementFrame? = nil) {
    self.labels = labels
    self.frame = frame
  }

  public var signature: String {
    labels
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\u{1f}")
  }
}

public enum SenderConfidence: String, Codable, Sendable {
  case localizedLabel = "localized_label"
  case structuredFragments = "structured_fragments"
  case notificationPayload = "notification_payload"
  case unavailable
}

public enum MessageKind: String, Codable, Hashable, Sendable {
  case text
  case media
  case system
  case unknown
}

public enum MessageAttachmentKind: String, Codable, Sendable {
  case image
  case video
  case audio
  case file
  case unknown
}

public struct MessageAttachment: Codable, Equatable, Sendable {
  public let identifier: String?
  public let fileURL: URL
  public let typeHint: String?
  public let kind: MessageAttachmentKind

  public init(
    identifier: String? = nil,
    fileURL: URL,
    typeHint: String? = nil,
    kind: MessageAttachmentKind = .unknown
  ) {
    self.identifier = identifier
    self.fileURL = fileURL
    self.typeHint = typeHint
    self.kind = kind
  }
}

public struct ParsedMessage: Equatable, Sendable {
  public let senderDisplayName: String?
  public let content: String
  public let kind: MessageKind
  public let senderConfidence: SenderConfidence
  public let isFromSelf: Bool

  public init(
    senderDisplayName: String?,
    content: String,
    kind: MessageKind,
    senderConfidence: SenderConfidence,
    isFromSelf: Bool
  ) {
    self.senderDisplayName = senderDisplayName
    self.content = content
    self.kind = kind
    self.senderConfidence = senderConfidence
    self.isFromSelf = isFromSelf
  }
}

public struct MessageEvent: Codable, Equatable, Sendable {
  public let eventID: String
  public let group: String
  public let senderDisplayName: String?
  public let senderStableID: String?
  public let content: String
  public let messageType: MessageKind
  public let observedAt: Date
  public let sourceSequence: Int64?
  public let attachments: [MessageAttachment]
  public let senderConfidence: SenderConfidence
  public let isFromSelf: Bool

  public init(
    eventID: String,
    group: String,
    senderDisplayName: String?,
    senderStableID: String? = nil,
    content: String,
    messageType: MessageKind,
    observedAt: Date,
    sourceSequence: Int64? = nil,
    attachments: [MessageAttachment] = [],
    senderConfidence: SenderConfidence,
    isFromSelf: Bool
  ) {
    self.eventID = eventID
    self.group = group
    self.senderDisplayName = senderDisplayName
    self.senderStableID = senderStableID
    self.content = content
    self.messageType = messageType
    self.observedAt = observedAt
    self.sourceSequence = sourceSequence
    self.attachments = attachments
    self.senderConfidence = senderConfidence
    self.isFromSelf = isFromSelf
  }
}

public enum SnapshotConfidence: String, Codable, Sendable {
  case exactWindowTitle = "exact_window_title"
  case nearbyGroupLabel = "nearby_group_label"
  case singleGroupFallback = "single_group_fallback"
}

public struct GroupSnapshot: Equatable, Sendable {
  public let group: String
  public let bindingKey: String
  public let confidence: SnapshotConfidence
  public let rows: [RawMessageRow]

  public init(
    group: String,
    bindingKey: String,
    confidence: SnapshotConfidence,
    rows: [RawMessageRow]
  ) {
    self.group = group
    self.bindingKey = bindingKey
    self.confidence = confidence
    self.rows = rows
  }
}

public struct DoctorReport: Equatable, Sendable {
  public let accessibilityTrusted: Bool
  public let screenCaptureTrusted: Bool
  public let notificationDatabaseReadable: Bool
  public let weChatInstalled: Bool
  public let weChatRunning: Bool
  public let weChatVersion: String?

  public init(
    accessibilityTrusted: Bool,
    screenCaptureTrusted: Bool,
    notificationDatabaseReadable: Bool,
    weChatInstalled: Bool,
    weChatRunning: Bool,
    weChatVersion: String?
  ) {
    self.accessibilityTrusted = accessibilityTrusted
    self.screenCaptureTrusted = screenCaptureTrusted
    self.notificationDatabaseReadable = notificationDatabaseReadable
    self.weChatInstalled = weChatInstalled
    self.weChatRunning = weChatRunning
    self.weChatVersion = weChatVersion
  }
}

public struct NotificationRecord: Equatable, Sendable {
  public let rowID: Int64
  public let uuid: String?
  public let deliveredAt: Date
  public let title: String
  public let subtitle: String
  public let body: String
  public let identifier: String
  public let attachments: [MessageAttachment]

  public init(
    rowID: Int64,
    uuid: String?,
    deliveredAt: Date,
    title: String,
    subtitle: String,
    body: String,
    identifier: String,
    attachments: [MessageAttachment] = []
  ) {
    self.rowID = rowID
    self.uuid = uuid
    self.deliveredAt = deliveredAt
    self.title = title
    self.subtitle = subtitle
    self.body = body
    self.identifier = identifier
    self.attachments = attachments
  }
}

public struct NotificationRecordBatch: Equatable, Sendable {
  public let records: [NotificationRecord]
  public let lastScannedRowID: Int64
  public let scannedCount: Int
  public let weChatRecordCount: Int
  public let payloadDecodeFailureCount: Int

  public init(
    records: [NotificationRecord],
    lastScannedRowID: Int64,
    scannedCount: Int,
    weChatRecordCount: Int? = nil,
    payloadDecodeFailureCount: Int = 0
  ) {
    self.records = records
    self.lastScannedRowID = lastScannedRowID
    self.scannedCount = scannedCount
    self.weChatRecordCount = weChatRecordCount ?? records.count
    self.payloadDecodeFailureCount = payloadDecodeFailureCount
  }
}

public enum NotificationFlowActivity: String, Codable, Equatable, Sendable {
  case waitingForNewRecords = "waiting_for_new_records"
  case nonWeChatNotifications = "non_wechat_notifications"
  case payloadDecodeFailed = "payload_decode_failed"
  case groupNotMonitored = "group_not_monitored"
  case matchedGroup = "matched_group"
}

public struct NotificationMonitorHealth: Equatable, Sendable {
  public let startedAt: Date
  public let lastSuccessfulScanAt: Date?
  public let lastDatabaseActivityAt: Date?
  public let latestActivity: NotificationFlowActivity
  public let lastRowID: Int64
  public let scannedRecordCount: Int
  public let identifiedWeChatNotificationCount: Int
  public let decodedNotificationCount: Int
  public let groupMatchedNotificationCount: Int
  public let unmatchedGroupNotificationCount: Int
  public let matchedEventCount: Int
  public let updatedNotificationRecoveryCount: Int
  public let recoveryCount: Int
  public let databaseResetCount: Int
  public let lastError: String?

  public init(
    startedAt: Date,
    lastSuccessfulScanAt: Date?,
    lastDatabaseActivityAt: Date?,
    latestActivity: NotificationFlowActivity,
    lastRowID: Int64,
    scannedRecordCount: Int,
    identifiedWeChatNotificationCount: Int,
    decodedNotificationCount: Int,
    groupMatchedNotificationCount: Int,
    unmatchedGroupNotificationCount: Int,
    matchedEventCount: Int,
    updatedNotificationRecoveryCount: Int,
    recoveryCount: Int,
    databaseResetCount: Int,
    lastError: String?
  ) {
    self.startedAt = startedAt
    self.lastSuccessfulScanAt = lastSuccessfulScanAt
    self.lastDatabaseActivityAt = lastDatabaseActivityAt
    self.latestActivity = latestActivity
    self.lastRowID = lastRowID
    self.scannedRecordCount = scannedRecordCount
    self.identifiedWeChatNotificationCount = identifiedWeChatNotificationCount
    self.decodedNotificationCount = decodedNotificationCount
    self.groupMatchedNotificationCount = groupMatchedNotificationCount
    self.unmatchedGroupNotificationCount = unmatchedGroupNotificationCount
    self.matchedEventCount = matchedEventCount
    self.updatedNotificationRecoveryCount = updatedNotificationRecoveryCount
    self.recoveryCount = recoveryCount
    self.databaseResetCount = databaseResetCount
    self.lastError = lastError
  }
}

public struct OCRLine: Equatable, Sendable {
  public let text: String
  public let frame: ElementFrame
  public let confidence: Float

  public init(text: String, frame: ElementFrame, confidence: Float) {
    self.text = text
    self.frame = frame
    self.confidence = confidence
  }

  public var signature: String {
    let position = [frame.x, frame.y, frame.width, frame.height]
      .map { String(Int(($0 * 1_000).rounded())) }
      .joined(separator: ":")
    return "\(position)|\(text)"
  }
}

public struct OCRWindowProbe: Sendable {
  public let windowID: UInt32
  public let title: ProbeLabel?
  public let frame: ElementFrame
  public let lines: [OCRLine]

  public init(
    windowID: UInt32,
    title: ProbeLabel?,
    frame: ElementFrame,
    lines: [OCRLine]
  ) {
    self.windowID = windowID
    self.title = title
    self.frame = frame
    self.lines = lines
  }
}

public struct OCRGroupSnapshot: Equatable, Sendable {
  public let group: String
  public let windowID: UInt32
  public let bindingKey: String
  public let confidence: SnapshotConfidence
  public let rows: [RawMessageRow]
  public let recognizedLines: [OCRLine]

  public init(
    group: String,
    windowID: UInt32,
    bindingKey: String,
    confidence: SnapshotConfidence,
    rows: [RawMessageRow],
    recognizedLines: [OCRLine]
  ) {
    self.group = group
    self.windowID = windowID
    self.bindingKey = bindingKey
    self.confidence = confidence
    self.rows = rows
    self.recognizedLines = recognizedLines
  }
}

public struct InspectionRow: Sendable {
  public let frame: ElementFrame?
  public let labels: [String]

  public init(frame: ElementFrame?, labels: [String]) {
    self.frame = frame
    self.labels = labels
  }
}

public struct InspectionReport: Sendable {
  public let group: String
  public let windowTitle: String
  public let tableFrame: ElementFrame?
  public let confidence: SnapshotConfidence
  public let rows: [InspectionRow]

  public init(
    group: String,
    windowTitle: String,
    tableFrame: ElementFrame?,
    confidence: SnapshotConfidence,
    rows: [InspectionRow]
  ) {
    self.group = group
    self.windowTitle = windowTitle
    self.tableFrame = tableFrame
    self.confidence = confidence
    self.rows = rows
  }
}

public struct ProbeLabel: Sendable {
  public let length: Int
  public let digest: String

  public init(length: Int, digest: String) {
    self.length = length
    self.digest = digest
  }
}

public struct ProbeNode: Sendable {
  public let depth: Int
  public let role: String
  public let frame: ElementFrame?
  public let childCount: Int
  public let labels: [ProbeLabel]

  public init(
    depth: Int,
    role: String,
    frame: ElementFrame?,
    childCount: Int,
    labels: [ProbeLabel]
  ) {
    self.depth = depth
    self.role = role
    self.frame = frame
    self.childCount = childCount
    self.labels = labels
  }
}

public struct ProbeWindow: Sendable {
  public let title: ProbeLabel?
  public let nodes: [ProbeNode]

  public init(title: ProbeLabel?, nodes: [ProbeNode]) {
    self.title = title
    self.nodes = nodes
  }
}
