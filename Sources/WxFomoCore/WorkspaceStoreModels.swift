import Foundation

public struct WorkspaceStoreCapabilities: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let journalMode: String
  public let recoveredRunningJobCount: Int

  public init(
    schemaVersion: Int,
    journalMode: String,
    recoveredRunningJobCount: Int
  ) {
    self.schemaVersion = schemaVersion
    self.journalMode = journalMode
    self.recoveredRunningJobCount = recoveredRunningJobCount
  }
}

public enum AIAnalysisJobState: String, Codable, CaseIterable, Equatable, Sendable {
  case pending
  case running
  case retryWait = "retry_wait"
  case succeeded
  case failed
  case cancelled

  public var isTerminal: Bool {
    switch self {
    case .succeeded, .failed, .cancelled:
      return true
    case .pending, .running, .retryWait:
      return false
    }
  }
}

public struct AIAnalysisJob: Codable, Equatable, Identifiable, Sendable {
  public let jobID: String
  public let frozenRangeID: String
  public let providerID: String
  public let mode: AIAnalysisMode
  public let customInstructions: String?
  public let state: AIAnalysisJobState
  /// Number of execution attempts that have been claimed by a worker.
  public let attempt: Int
  public let maximumAttempts: Int
  public let nextAttemptAt: Date?
  public let idempotencyKey: String
  public let promptVersion: Int
  /// Sanitized diagnostic text. This field must never contain request bodies or credentials.
  public let lastError: String?
  public let createdAt: Date
  public let updatedAt: Date

  public var id: String { jobID }

  public init(
    jobID: String,
    frozenRangeID: String,
    providerID: String,
    mode: AIAnalysisMode,
    customInstructions: String?,
    state: AIAnalysisJobState,
    attempt: Int,
    maximumAttempts: Int,
    nextAttemptAt: Date?,
    idempotencyKey: String,
    promptVersion: Int,
    lastError: String?,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.jobID = jobID
    self.frozenRangeID = frozenRangeID
    self.providerID = providerID
    self.mode = mode
    self.customInstructions = customInstructions
    self.state = state
    self.attempt = attempt
    self.maximumAttempts = maximumAttempts
    self.nextAttemptAt = nextAttemptAt
    self.idempotencyKey = idempotencyKey
    self.promptVersion = promptVersion
    self.lastError = lastError
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct StoredAIAnalysisResult: Codable, Equatable, Identifiable, Sendable {
  public let jobID: String
  public let frozenRangeID: String
  public let result: AIAnalysisResult
  public let createdAt: Date
  public let updatedAt: Date

  public var id: String { result.analysisID }

  public init(
    jobID: String,
    frozenRangeID: String,
    result: AIAnalysisResult,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.jobID = jobID
    self.frozenRangeID = frozenRangeID
    self.result = result
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct WorkspaceAlert: Codable, Equatable, Identifiable, Sendable {
  public let alertID: String
  public let severity: MessageRuleAlertSeverity
  public let title: String
  /// Optional operator-authored context. Message bodies are not persisted here by default.
  public let body: String?
  public let sourceEventIDs: [String]
  public let deduplicationKey: String
  public let cooldownUntil: Date?
  public let occurrenceCount: Int
  public let ruleID: String?
  public let acknowledgedAt: Date?
  public let createdAt: Date
  public let updatedAt: Date

  public var id: String { alertID }
  public var isAcknowledged: Bool { acknowledgedAt != nil }

  public init(
    alertID: String,
    severity: MessageRuleAlertSeverity,
    title: String,
    body: String? = nil,
    sourceEventIDs: [String],
    deduplicationKey: String,
    cooldownUntil: Date?,
    occurrenceCount: Int = 1,
    ruleID: String? = nil,
    acknowledgedAt: Date? = nil,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.alertID = alertID
    self.severity = severity
    self.title = title
    self.body = body
    self.sourceEventIDs = sourceEventIDs
    self.deduplicationKey = deduplicationKey
    self.cooldownUntil = cooldownUntil
    self.occurrenceCount = occurrenceCount
    self.ruleID = ruleID
    self.acknowledgedAt = acknowledgedAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum WorkspaceAlertRecordingDisposition: String, Codable, Equatable, Sendable {
  case created
  case coalesced
}

public struct WorkspaceAlertRecordingResult: Codable, Equatable, Sendable {
  public let disposition: WorkspaceAlertRecordingDisposition
  public let alert: WorkspaceAlert

  public init(disposition: WorkspaceAlertRecordingDisposition, alert: WorkspaceAlert) {
    self.disposition = disposition
    self.alert = alert
  }
}

public struct CryptoAddressMention: Codable, Equatable, Identifiable, Sendable {
  public let eventID: String
  public let family: CryptoAddressFamily
  public let network: CryptoAddressNetwork?
  public let normalizedAddress: String
  public let originalAddress: String
  public let groupName: String
  public let senderKey: String?
  public let observedAt: Date
  public let detectorVersion: Int
  public let createdAt: Date

  public var id: String {
    "\(eventID):\(network?.rawValue ?? (family == .solana ? "solana" : "evm")):\(normalizedAddress)"
  }

  public init(
    eventID: String,
    family: CryptoAddressFamily,
    network: CryptoAddressNetwork? = nil,
    normalizedAddress: String,
    originalAddress: String,
    groupName: String,
    senderKey: String?,
    observedAt: Date,
    detectorVersion: Int,
    createdAt: Date
  ) {
    self.eventID = eventID
    self.family = family
    self.network = network
    self.normalizedAddress = normalizedAddress
    self.originalAddress = originalAddress
    self.groupName = groupName
    self.senderKey = senderKey
    self.observedAt = observedAt
    self.detectorVersion = detectorVersion
    self.createdAt = createdAt
  }
}

public struct CryptoAddressMentionSummary: Codable, Equatable, Sendable {
  public let family: CryptoAddressFamily
  public let network: CryptoAddressNetwork?
  public let normalizedAddress: String
  public let originalAddress: String
  public let firstSeenAt: Date
  public let latestSeenAt: Date
  public let mentionCount: Int
  public let groupNames: [String]

  public var groupCount: Int { groupNames.count }

  public init(
    family: CryptoAddressFamily,
    network: CryptoAddressNetwork? = nil,
    normalizedAddress: String,
    originalAddress: String,
    firstSeenAt: Date,
    latestSeenAt: Date,
    mentionCount: Int,
    groupNames: [String]
  ) {
    self.family = family
    self.network = network
    self.normalizedAddress = normalizedAddress
    self.originalAddress = originalAddress
    self.firstSeenAt = firstSeenAt
    self.latestSeenAt = latestSeenAt
    self.mentionCount = mentionCount
    self.groupNames = groupNames
  }
}

public enum CrossGroupAddressIncidentStatus: String, Codable, Equatable, Sendable {
  case active
  case closed
}

public struct CrossGroupAddressIncident: Codable, Equatable, Identifiable, Sendable {
  public let incidentID: String
  public let family: CryptoAddressFamily
  public let network: CryptoAddressNetwork?
  public let normalizedAddress: String
  public let originalAddress: String
  public let firstSeenAt: Date
  public let latestSeenAt: Date
  public let mentionCount: Int
  public let groupNames: [String]
  public let sourceEventIDs: [String]
  public let alertID: String
  public let status: CrossGroupAddressIncidentStatus
  public let createdAt: Date
  public let updatedAt: Date

  public var id: String { incidentID }
  public var groupCount: Int { groupNames.count }

  public init(
    incidentID: String,
    family: CryptoAddressFamily,
    network: CryptoAddressNetwork? = nil,
    normalizedAddress: String,
    originalAddress: String,
    firstSeenAt: Date,
    latestSeenAt: Date,
    mentionCount: Int,
    groupNames: [String],
    sourceEventIDs: [String],
    alertID: String,
    status: CrossGroupAddressIncidentStatus,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.incidentID = incidentID
    self.family = family
    self.network = network
    self.normalizedAddress = normalizedAddress
    self.originalAddress = originalAddress
    self.firstSeenAt = firstSeenAt
    self.latestSeenAt = latestSeenAt
    self.mentionCount = mentionCount
    self.groupNames = groupNames
    self.sourceEventIDs = sourceEventIDs
    self.alertID = alertID
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum CryptoAddressMentionRecordingDisposition: String, Codable, Equatable, Sendable {
  case duplicate
  case recorded
  case incidentCreated = "incident_created"
  case incidentUpdated = "incident_updated"
}

public struct CryptoAddressMentionRecordingResult: Codable, Equatable, Sendable {
  public let disposition: CryptoAddressMentionRecordingDisposition
  public let incident: CrossGroupAddressIncident?
  public let alert: WorkspaceAlert?

  public init(
    disposition: CryptoAddressMentionRecordingDisposition,
    incident: CrossGroupAddressIncident? = nil,
    alert: WorkspaceAlert? = nil
  ) {
    self.disposition = disposition
    self.incident = incident
    self.alert = alert
  }
}

public enum WorkspaceStoreError: LocalizedError, Equatable, Sendable {
  case cannotOpenDatabase(String)
  case databaseAlreadyInUse(String)
  case databaseLockFailed(String)
  case configurationFailed(String)
  case schemaTooNew(Int)
  case migrationFailed(version: Int, reason: String)
  case queryFailed(operation: String, reason: String)
  case invalidArgument(String)
  case invalidProviderConfiguration(configurationID: String, reason: String)
  case providerConfigurationNotFound(String)
  case providerConfigurationEncodingFailed(configurationID: String, reason: String)
  case providerConfigurationDecodingFailed(configurationID: String, reason: String)
  case messageRuleNotFound(String)
  case messageRuleEncodingFailed(ruleID: String, reason: String)
  case messageRuleDecodingFailed(ruleID: String, reason: String)
  case analysisJobNotFound(String)
  case idempotencyConflict(String)
  case invalidJobTransition(jobID: String, from: AIAnalysisJobState, to: AIAnalysisJobState)
  case analysisResultNotFound(String)
  case analysisResultEncodingFailed(analysisID: String, reason: String)
  case analysisResultDecodingFailed(analysisID: String, reason: String)
  case analysisResultJobMismatch(analysisID: String)
  case analysisResultProviderMismatch(analysisID: String)
  case analysisResultMutationNotAllowed(analysisID: String, jobState: AIAnalysisJobState)
  case alertNotFound(String)
  case alertSourceEncodingFailed(String)
  case alertSourceDecodingFailed(String)

  public var errorDescription: String? {
    switch self {
    case .cannotOpenDatabase(let path):
      return "无法打开工作区数据库：\(path)"
    case .databaseAlreadyInUse(let path):
      return "工作区数据库已被另一个 wxFomo 实例使用：\(path)"
    case .databaseLockFailed(let path):
      return "无法锁定工作区数据库：\(path)"
    case .configurationFailed(let reason):
      return "工作区数据库配置失败：\(reason)"
    case .schemaTooNew(let version):
      return "工作区数据库版本 \(version) 高于当前应用支持的版本"
    case .migrationFailed(let version, let reason):
      return "工作区数据库迁移到版本 \(version) 失败：\(reason)"
    case .queryFailed(let operation, let reason):
      return "工作区数据库操作 \(operation) 失败：\(reason)"
    case .invalidArgument(let field):
      return "工作区数据库参数无效：\(field)"
    case .invalidProviderConfiguration(let identifier, let reason):
      return "AI Provider 配置 \(identifier) 无效：\(reason)"
    case .providerConfigurationNotFound(let identifier):
      return "AI Provider 配置不存在：\(identifier)"
    case .providerConfigurationEncodingFailed(let identifier, let reason):
      return "AI Provider 配置 \(identifier) 无法编码：\(reason)"
    case .providerConfigurationDecodingFailed(let identifier, let reason):
      return "AI Provider 配置 \(identifier) 无法解码：\(reason)"
    case .messageRuleNotFound(let identifier):
      return "消息规则不存在：\(identifier)"
    case .messageRuleEncodingFailed(let identifier, let reason):
      return "消息规则 \(identifier) 无法编码：\(reason)"
    case .messageRuleDecodingFailed(let identifier, let reason):
      return "消息规则 \(identifier) 无法解码：\(reason)"
    case .analysisJobNotFound(let identifier):
      return "AI 分析任务不存在：\(identifier)"
    case .idempotencyConflict(let key):
      return "AI 分析任务幂等键与已有任务参数冲突：\(key)"
    case .invalidJobTransition(let identifier, let from, let to):
      return "AI 分析任务 \(identifier) 不能从 \(from.rawValue) 转为 \(to.rawValue)"
    case .analysisResultNotFound(let identifier):
      return "AI 分析结果不存在：\(identifier)"
    case .analysisResultEncodingFailed(let identifier, let reason):
      return "AI 分析结果 \(identifier) 无法编码：\(reason)"
    case .analysisResultDecodingFailed(let identifier, let reason):
      return "AI 分析结果 \(identifier) 无法解码：\(reason)"
    case .analysisResultJobMismatch(let identifier):
      return "AI 分析结果 \(identifier) 与任务范围不一致"
    case .analysisResultProviderMismatch(let identifier):
      return "AI 分析结果 \(identifier) 与任务 Provider 不一致"
    case .analysisResultMutationNotAllowed(let identifier, let state):
      return "AI 分析结果 \(identifier) 在任务状态 \(state.rawValue) 下不可修改"
    case .alertNotFound(let identifier):
      return "监控告警不存在：\(identifier)"
    case .alertSourceEncodingFailed(let identifier):
      return "监控告警 \(identifier) 的来源 ID 无法编码"
    case .alertSourceDecodingFailed(let identifier):
      return "监控告警 \(identifier) 的来源 ID 无法解码"
    }
  }
}
