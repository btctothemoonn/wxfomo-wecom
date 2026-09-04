import Foundation

public enum AIAnalysisMode: String, Codable, CaseIterable, Sendable {
  case digest
  case importantInformation = "important_information"
  case actionItems = "action_items"
  case risksAndOpportunities = "risks_and_opportunities"
  case custom
}

public struct AIAnalysisSourceMessage: Codable, Equatable, Sendable, Identifiable {
  public let messageID: String
  public let group: String
  public let senderDisplayName: String?
  public let observedAt: Date
  public let content: String
  public let messageType: MessageKind

  public var id: String { messageID }

  public init(
    messageID: String,
    group: String,
    senderDisplayName: String?,
    observedAt: Date,
    content: String,
    messageType: MessageKind
  ) {
    self.messageID = messageID
    self.group = group
    self.senderDisplayName = senderDisplayName
    self.observedAt = observedAt
    self.content = content
    self.messageType = messageType
  }

  public init(event: MessageEvent) {
    self.init(
      messageID: event.eventID,
      group: event.group,
      senderDisplayName: event.senderDisplayName,
      observedAt: event.observedAt,
      content: event.content,
      messageType: event.messageType
    )
  }
}

public struct AIAnalysisRequest: Codable, Equatable, Sendable, Identifiable {
  public static let currentSchemaVersion = 1

  public let requestID: String
  public let createdAt: Date
  public let rangeStart: Date
  public let rangeEnd: Date
  public let mode: AIAnalysisMode
  public let localeIdentifier: String
  public let customInstructions: String?
  public let messages: [AIAnalysisSourceMessage]
  public let schemaVersion: Int

  public var id: String { requestID }

  public init(
    requestID: String = UUID().uuidString,
    createdAt: Date = Date(),
    rangeStart: Date,
    rangeEnd: Date,
    mode: AIAnalysisMode,
    localeIdentifier: String = Locale.current.identifier,
    customInstructions: String? = nil,
    messages: [AIAnalysisSourceMessage],
    schemaVersion: Int = AIAnalysisRequest.currentSchemaVersion
  ) {
    self.requestID = requestID
    self.createdAt = createdAt
    self.rangeStart = rangeStart
    self.rangeEnd = rangeEnd
    self.mode = mode
    self.localeIdentifier = localeIdentifier
    self.customInstructions = customInstructions
    self.messages = messages
    self.schemaVersion = schemaVersion
  }
}

public enum AIAnalysisRequestValidationError: Error, Equatable, Sendable {
  case emptyRequestID
  case invalidDateRange
  case unsupportedSchemaVersion(Int)
  case noMessages
  case tooManyMessages(limit: Int)
  case emptyMessageID(index: Int)
  case messageIDHasSurroundingWhitespace(index: Int)
  case duplicateMessageID(String)
  case messageOutsideDateRange(messageID: String)
  case messageContentTooLarge(messageID: String, limit: Int)
  case totalContentTooLarge(limitBytes: Int)
  case instructionsTooLarge(limit: Int)
  case customModeRequiresInstructions
}

extension AIAnalysisRequest {
  public static let maximumMessageCount = 10_000
  public static let maximumMessageContentCharacters = 200_000
  public static let maximumTotalContentBytes = 4 * 1_024 * 1_024
  public static let maximumCustomInstructionCharacters = 20_000

  public func validate() throws {
    guard !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AIAnalysisRequestValidationError.emptyRequestID
    }
    guard rangeStart <= rangeEnd else {
      throw AIAnalysisRequestValidationError.invalidDateRange
    }
    guard schemaVersion == Self.currentSchemaVersion else {
      throw AIAnalysisRequestValidationError.unsupportedSchemaVersion(schemaVersion)
    }
    guard !messages.isEmpty else {
      throw AIAnalysisRequestValidationError.noMessages
    }
    guard messages.count <= Self.maximumMessageCount else {
      throw AIAnalysisRequestValidationError.tooManyMessages(limit: Self.maximumMessageCount)
    }

    var messageIDs = Set<String>()
    var totalContentBytes = 0
    for (index, message) in messages.enumerated() {
      let trimmedID = message.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedID.isEmpty else {
        throw AIAnalysisRequestValidationError.emptyMessageID(index: index)
      }
      guard trimmedID == message.messageID else {
        throw AIAnalysisRequestValidationError.messageIDHasSurroundingWhitespace(index: index)
      }
      guard messageIDs.insert(trimmedID).inserted else {
        throw AIAnalysisRequestValidationError.duplicateMessageID(trimmedID)
      }
      guard message.observedAt >= rangeStart, message.observedAt <= rangeEnd else {
        throw AIAnalysisRequestValidationError.messageOutsideDateRange(messageID: message.messageID)
      }
      guard message.content.count <= Self.maximumMessageContentCharacters else {
        throw AIAnalysisRequestValidationError.messageContentTooLarge(
          messageID: message.messageID,
          limit: Self.maximumMessageContentCharacters
        )
      }
      totalContentBytes += message.content.utf8.count
      guard totalContentBytes <= Self.maximumTotalContentBytes else {
        throw AIAnalysisRequestValidationError.totalContentTooLarge(
          limitBytes: Self.maximumTotalContentBytes
        )
      }
    }

    if let customInstructions {
      guard customInstructions.count <= Self.maximumCustomInstructionCharacters else {
        throw AIAnalysisRequestValidationError.instructionsTooLarge(
          limit: Self.maximumCustomInstructionCharacters
        )
      }
    }
    if mode == .custom {
      guard let customInstructions,
            !customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AIAnalysisRequestValidationError.customModeRequiresInstructions
      }
    }
  }
}

public enum AIEpistemicStatus: String, Codable, CaseIterable, Sendable {
  case fact
  case inference
  case uncertain
}

public enum AIAnalysisFindingCategory: String, Codable, CaseIterable, Sendable {
  case keyClaim = "key_claim"
  case actionItem = "action_item"
  case deadline
  case risk
  case opportunity
  case disagreement
  case openQuestion = "open_question"
}

public struct AIAnalysisFinding: Codable, Equatable, Sendable, Identifiable {
  public let findingID: String
  public let category: AIAnalysisFindingCategory
  public let text: String
  public let epistemicStatus: AIEpistemicStatus
  public let sourceMessageIDs: [String]

  public var id: String { findingID }

  public init(
    findingID: String,
    category: AIAnalysisFindingCategory,
    text: String,
    epistemicStatus: AIEpistemicStatus,
    sourceMessageIDs: [String]
  ) {
    self.findingID = findingID
    self.category = category
    self.text = text
    self.epistemicStatus = epistemicStatus
    self.sourceMessageIDs = sourceMessageIDs
  }
}

public struct AIAnalysisTopic: Codable, Equatable, Sendable, Identifiable {
  public let topicID: String
  public let title: String
  public let summary: String
  public let sourceMessageIDs: [String]

  public var id: String { topicID }

  public init(
    topicID: String,
    title: String,
    summary: String,
    sourceMessageIDs: [String]
  ) {
    self.topicID = topicID
    self.title = title
    self.summary = summary
    self.sourceMessageIDs = sourceMessageIDs
  }
}

public struct AIAnalysisCryptoAddress: Codable, Equatable, Sendable, Identifiable {
  public let address: String
  public let normalizedAddress: String
  public let network: CryptoAddressNetwork
  public let roleHint: CryptoAddressRoleHint
  public let occurrenceCount: Int
  public let contextSummary: String
  public let epistemicStatus: AIEpistemicStatus
  public let sourceMessageIDs: [String]

  public var id: String { "\(network.rawValue):\(normalizedAddress)" }

  public init(
    address: String,
    normalizedAddress: String,
    network: CryptoAddressNetwork,
    roleHint: CryptoAddressRoleHint,
    occurrenceCount: Int,
    contextSummary: String,
    epistemicStatus: AIEpistemicStatus,
    sourceMessageIDs: [String]
  ) {
    self.address = address
    self.normalizedAddress = normalizedAddress
    self.network = network
    self.roleHint = roleHint
    self.occurrenceCount = occurrenceCount
    self.contextSummary = contextSummary
    self.epistemicStatus = epistemicStatus
    self.sourceMessageIDs = sourceMessageIDs
  }
}

public struct AIAnalysisUsage: Codable, Equatable, Sendable {
  public let inputTokens: Int?
  public let outputTokens: Int?

  public init(inputTokens: Int?, outputTokens: Int?) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
  }
}

public enum AIAnalysisValidationWarning: String, Codable, CaseIterable, Equatable, Sendable {
  case unknownSourceReferenceRemoved = "unknown_source_reference_removed"
  case uncitedClaimDowngraded = "uncited_claim_downgraded"
  case uncitedSummary = "uncited_summary"
  case uncitedTopic = "uncited_topic"
  case unknownCryptoAddressRemoved = "unknown_crypto_address_removed"
  case uncitedCryptoContext = "uncited_crypto_context"
  case missingCryptoContext = "missing_crypto_context"
}

public struct AIAnalysisProvenance: Codable, Equatable, Sendable {
  public let providerConfigurationID: String
  public let providerKind: AIProviderKind
  public let model: String
  public let remoteRequestID: String?
  public let remoteResponseID: String?
  public let sourceMessageIDs: [String]
  public let requestSchemaVersion: Int
  public let resultSchemaVersion: Int
  public let generatedAt: Date

  public init(
    providerConfigurationID: String,
    providerKind: AIProviderKind,
    model: String,
    remoteRequestID: String?,
    remoteResponseID: String?,
    sourceMessageIDs: [String],
    requestSchemaVersion: Int,
    resultSchemaVersion: Int,
    generatedAt: Date
  ) {
    self.providerConfigurationID = providerConfigurationID
    self.providerKind = providerKind
    self.model = model
    self.remoteRequestID = remoteRequestID
    self.remoteResponseID = remoteResponseID
    self.sourceMessageIDs = sourceMessageIDs
    self.requestSchemaVersion = requestSchemaVersion
    self.resultSchemaVersion = resultSchemaVersion
    self.generatedAt = generatedAt
  }
}

public struct AIAnalysisResult: Codable, Equatable, Sendable, Identifiable {
  public static let currentSchemaVersion = 1

  public let analysisID: String
  public let requestID: String
  public let schemaVersion: Int
  public let summary: String
  public let summarySourceMessageIDs: [String]
  public let topics: [AIAnalysisTopic]
  public let findings: [AIAnalysisFinding]
  public let cryptoAddresses: [AIAnalysisCryptoAddress]
  public let usage: AIAnalysisUsage?
  public let provenance: AIAnalysisProvenance
  public let validationWarnings: [AIAnalysisValidationWarning]

  public var id: String { analysisID }

  public init(
    analysisID: String,
    requestID: String,
    schemaVersion: Int = AIAnalysisResult.currentSchemaVersion,
    summary: String,
    summarySourceMessageIDs: [String],
    topics: [AIAnalysisTopic],
    findings: [AIAnalysisFinding],
    cryptoAddresses: [AIAnalysisCryptoAddress] = [],
    usage: AIAnalysisUsage?,
    provenance: AIAnalysisProvenance,
    validationWarnings: [AIAnalysisValidationWarning]
  ) {
    self.analysisID = analysisID
    self.requestID = requestID
    self.schemaVersion = schemaVersion
    self.summary = summary
    self.summarySourceMessageIDs = summarySourceMessageIDs
    self.topics = topics
    self.findings = findings
    self.cryptoAddresses = cryptoAddresses
    self.usage = usage
    self.provenance = provenance
    self.validationWarnings = validationWarnings
  }

  private enum CodingKeys: String, CodingKey {
    case analysisID
    case requestID
    case schemaVersion
    case summary
    case summarySourceMessageIDs
    case topics
    case findings
    case cryptoAddresses
    case usage
    case provenance
    case validationWarnings
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedSchemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    guard decodedSchemaVersion == Self.currentSchemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "Unsupported AI analysis result schema version"
      )
    }

    let decodedProvenance = try container.decode(
      AIAnalysisProvenance.self,
      forKey: .provenance
    )
    guard decodedProvenance.resultSchemaVersion == decodedSchemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .provenance,
        in: container,
        debugDescription: "AI analysis result schema version does not match provenance"
      )
    }

    analysisID = try container.decode(String.self, forKey: .analysisID)
    requestID = try container.decode(String.self, forKey: .requestID)
    schemaVersion = decodedSchemaVersion
    summary = try container.decode(String.self, forKey: .summary)
    summarySourceMessageIDs = try container.decode(
      [String].self,
      forKey: .summarySourceMessageIDs
    )
    topics = try container.decode([AIAnalysisTopic].self, forKey: .topics)
    findings = try container.decode([AIAnalysisFinding].self, forKey: .findings)
    cryptoAddresses = try container.decodeIfPresent(
      [AIAnalysisCryptoAddress].self,
      forKey: .cryptoAddresses
    ) ?? []
    usage = try container.decodeIfPresent(AIAnalysisUsage.self, forKey: .usage)
    provenance = decodedProvenance
    validationWarnings = try container.decode(
      [AIAnalysisValidationWarning].self,
      forKey: .validationWarnings
    )
  }
}

public protocol AIAnalysisProviding: Sendable {
  var configuration: AIProviderConfiguration { get }

  func analyze(_ request: AIAnalysisRequest) async throws -> AIAnalysisResult
}
