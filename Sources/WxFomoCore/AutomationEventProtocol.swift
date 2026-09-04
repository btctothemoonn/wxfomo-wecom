import Foundation

public enum AutomationEventSchema {
  public static let currentVersion = 1
}

public enum AutomationEventType: String, Codable, Sendable {
  case message
}

public struct AutomationMessageAttachmentV1: Codable, Equatable, Sendable {
  public let identifier: String?
  public let fileURL: String
  public let typeHint: String?
  public let kind: String

  private enum CodingKeys: String, CodingKey {
    case identifier
    case fileURL
    case typeHint
    case kind
  }

  public init(attachment: MessageAttachment) {
    self.identifier = attachment.identifier
    self.fileURL = attachment.fileURL.absoluteString
    self.typeHint = attachment.typeHint
    self.kind = attachment.kind.rawValue
  }
}

public struct AutomationMessagePayloadV1: Codable, Equatable, Sendable {
  public let eventID: String
  public let group: String
  public let senderDisplayName: String?
  public let senderStableID: String?
  public let content: String
  public let messageType: String
  public let observedAt: Date
  public let sourceSequence: String?
  public let attachments: [AutomationMessageAttachmentV1]
  public let senderConfidence: String
  public let isFromSelf: Bool

  private enum CodingKeys: String, CodingKey {
    case eventID
    case group
    case senderDisplayName
    case senderStableID
    case content
    case messageType
    case observedAt
    case sourceSequence
    case attachments
    case senderConfidence
    case isFromSelf
  }

  public init(message: MessageEvent) {
    self.eventID = message.eventID
    self.group = message.group
    self.senderDisplayName = message.senderDisplayName
    self.senderStableID = message.senderStableID
    self.content = message.content
    self.messageType = message.messageType.rawValue
    self.observedAt = message.observedAt
    self.sourceSequence = message.sourceSequence.map(String.init)
    self.attachments = message.attachments.map(AutomationMessageAttachmentV1.init)
    self.senderConfidence = message.senderConfidence.rawValue
    self.isFromSelf = message.isFromSelf
  }
}

public struct AutomationEventEnvelope: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let type: AutomationEventType
  public let streamID: String
  public let sequence: String
  public let emittedAt: Date
  public let payload: AutomationMessagePayloadV1

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case type
    case streamID
    case sequence
    case emittedAt
    case payload
  }

  public init(
    schemaVersion: Int = AutomationEventSchema.currentVersion,
    type: AutomationEventType = .message,
    streamID: String,
    sequence: String,
    emittedAt: Date,
    payload: AutomationMessagePayloadV1
  ) {
    self.schemaVersion = schemaVersion
    self.type = type
    self.streamID = streamID
    self.sequence = sequence
    self.emittedAt = emittedAt
    self.payload = payload
  }
}

public enum AutomationEventEncodingError: LocalizedError, Sendable {
  case invalidSequence(Int64)
  case frameTooLarge(actualBytes: Int, maximumBytes: Int)
  case unexpectedLineBreak

  public var errorDescription: String? {
    switch self {
    case .invalidSequence(let sequence):
      return "Automation event sequence must be positive; received \(sequence)."
    case .frameTooLarge(let actualBytes, let maximumBytes):
      return "Automation event is \(actualBytes) bytes; the maximum is \(maximumBytes) bytes."
    case .unexpectedLineBreak:
      return "Automation event encoder produced an invalid physical NDJSON line."
    }
  }
}

public struct AutomationEventNDJSONCodec: Sendable {
  public static let defaultMaximumLineBytes = 1_048_576

  public let maximumLineBytes: Int

  public init(maximumLineBytes: Int = Self.defaultMaximumLineBytes) {
    self.maximumLineBytes = max(1, maximumLineBytes)
  }

  public func encodeMessage(
    _ event: MessageEvent,
    streamID: UUID,
    sequence: Int64,
    emittedAt: Date = Date()
  ) throws -> Data {
    guard sequence > 0 else {
      throw AutomationEventEncodingError.invalidSequence(sequence)
    }

    let envelope = AutomationEventEnvelope(
      streamID: streamID.uuidString.lowercased(),
      sequence: String(sequence),
      emittedAt: emittedAt,
      payload: AutomationMessagePayloadV1(message: event)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(envelope)

    // JSONEncoder escapes newlines inside strings. A physical LF here would split one event.
    guard !data.contains(0x0A), !data.contains(0x0D) else {
      throw AutomationEventEncodingError.unexpectedLineBreak
    }
    guard data.count <= maximumLineBytes else {
      throw AutomationEventEncodingError.frameTooLarge(
        actualBytes: data.count,
        maximumBytes: maximumLineBytes
      )
    }
    data.append(0x0A)
    return data
  }
}
