import Foundation

public enum NotificationSoundEventKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case newMessage = "new_message"
  case capturedSignal = "captured_signal"
  case cryptoAddress = "crypto_address"
  case crossGroupAddress = "cross_group_address"
  case alertInformation = "alert_information"
  case alertWarning = "alert_warning"
  case alertCritical = "alert_critical"
  case analysisCompleted = "analysis_completed"
  case listenerIssue = "listener_issue"

  public var id: String { rawValue }

  public var defaultSpeechText: String {
    switch self {
    case .newMessage: return "收到新消息"
    case .capturedSignal: return "发现重点信号"
    case .cryptoAddress: return "发送者与代币"
    case .crossGroupAddress: return "跨群代币信息"
    case .alertInformation: return "收到提示提醒"
    case .alertWarning: return "收到警告提醒"
    case .alertCritical: return "收到严重提醒"
    case .analysisCompleted: return "分析完成"
    case .listenerIssue: return "监听出现异常"
    }
  }
}

public enum NotificationSoundOutputMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case sound
  case speech
  case soundAndSpeech = "sound_and_speech"

  public var id: String { rawValue }

  public var includesSound: Bool {
    self == .sound || self == .soundAndSpeech
  }

  public var includesSpeech: Bool {
    self == .speech || self == .soundAndSpeech
  }
}

public struct NotificationSpeechAnnouncement: Codable, Equatable, Sendable {
  public var text: String
  /// Playback speed multiplier. 1.0 is the provider's normal speed.
  public var rate: Double
  public var volume: Double

  public init(text: String, rate: Double = 1, volume: Double = 0.85) {
    self.text = text
    self.rate = rate
    self.volume = volume
  }

  public var normalized: NotificationSpeechAnnouncement {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return NotificationSpeechAnnouncement(
      text: String(trimmed.prefix(120)),
      rate: min(max(rate.isFinite ? rate : 1, 0.5), 2),
      volume: min(max(volume.isFinite ? volume : 0.85, 0), 1)
    )
  }
}

public enum NotificationSpeechProvider: String, Codable, CaseIterable, Identifiable, Sendable {
  case volcengineSeed = "volcengine_seed"
  case system

  public var id: String { rawValue }
}

public enum NotificationSpeechConfigurationError: Error, Equatable, Sendable {
  case invalidEndpoint
  case invalidStreamEndpoint
  case emptyModel
  case emptyStreamModel
  case emptyResourceID
  case unsupportedAudioFormat
  case invalidSampleRate
  case invalidMaximumCharacters
  case invalidCacheTTL
  case invalidTimeout
}

extension NotificationSpeechConfigurationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint: return "语音创建接口地址无效"
    case .invalidStreamEndpoint: return "语音流式接口地址无效"
    case .emptyModel: return "语音创建模型不能为空"
    case .emptyStreamModel: return "语音流式模型不能为空"
    case .emptyResourceID: return "语音 Resource ID 不能为空"
    case .unsupportedAudioFormat: return "当前仅支持 MP3 或 WAV 语音"
    case .invalidSampleRate: return "语音采样率必须在 8000 到 48000 之间"
    case .invalidMaximumCharacters: return "单次朗读字数必须在 1 到 10000 之间"
    case .invalidCacheTTL: return "语音缓存时间必须在 0 到 86400 秒之间"
    case .invalidTimeout: return "语音请求超时必须在 1 到 120 秒之间"
    }
  }
}

public struct NotificationSpeechConfiguration: Codable, Equatable, Sendable {
  public static let sophieVoiceID = "zh_female_sophie_uranus_bigtts"
  public static let defaultSeedEndpoint = "https://openspeech.bytedance.com/api/v3/tts/create"
  public static let defaultSeedStreamEndpoint =
    "https://openspeech.bytedance.com/api/v3/tts/unidirectional"
  public static let defaultSeedModel = "seed-audio-1.0"
  public static let defaultSeedStreamModel = "seed-tts-2.0-expressive"
  public static let defaultSeedResourceID = "seed-tts-2.0"

  public var provider: NotificationSpeechProvider
  public var voiceID: String
  public var fallbackToSystemVoice: Bool
  public var seedEndpoint: String
  public var seedStreamEndpoint: String
  public var seedModel: String
  public var seedStreamModel: String
  public var seedResourceID: String
  public var fallbackToCreateEndpoint: Bool
  public var audioFormat: String
  public var sampleRate: Int
  public var maximumCharacters: Int
  public var cacheTTLSeconds: Int
  public var requestTimeoutSeconds: Double

  public init(
    provider: NotificationSpeechProvider = .volcengineSeed,
    voiceID: String = NotificationSpeechConfiguration.sophieVoiceID,
    fallbackToSystemVoice: Bool = false,
    seedEndpoint: String = NotificationSpeechConfiguration.defaultSeedEndpoint,
    seedStreamEndpoint: String = NotificationSpeechConfiguration.defaultSeedStreamEndpoint,
    seedModel: String = NotificationSpeechConfiguration.defaultSeedModel,
    seedStreamModel: String = NotificationSpeechConfiguration.defaultSeedStreamModel,
    seedResourceID: String = NotificationSpeechConfiguration.defaultSeedResourceID,
    fallbackToCreateEndpoint: Bool = false,
    audioFormat: String = "mp3",
    sampleRate: Int = 24_000,
    maximumCharacters: Int = 1_200,
    cacheTTLSeconds: Int = 300,
    requestTimeoutSeconds: Double = 30
  ) {
    self.provider = provider
    self.voiceID = voiceID
    self.fallbackToSystemVoice = fallbackToSystemVoice
    self.seedEndpoint = seedEndpoint
    self.seedStreamEndpoint = seedStreamEndpoint
    self.seedModel = seedModel
    self.seedStreamModel = seedStreamModel
    self.seedResourceID = seedResourceID
    self.fallbackToCreateEndpoint = fallbackToCreateEndpoint
    self.audioFormat = audioFormat
    self.sampleRate = sampleRate
    self.maximumCharacters = maximumCharacters
    self.cacheTTLSeconds = cacheTTLSeconds
    self.requestTimeoutSeconds = requestTimeoutSeconds
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case voiceID
    case fallbackToSystemVoice
    case seedEndpoint
    case seedStreamEndpoint
    case seedModel
    case seedStreamModel
    case seedResourceID
    case fallbackToCreateEndpoint
    case audioFormat
    case sampleRate
    case maximumCharacters
    case cacheTTLSeconds
    case requestTimeoutSeconds
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    provider = try values.decodeIfPresent(NotificationSpeechProvider.self, forKey: .provider)
      ?? .volcengineSeed
    voiceID = try values.decodeIfPresent(String.self, forKey: .voiceID) ?? Self.sophieVoiceID
    fallbackToSystemVoice = try values.decodeIfPresent(
      Bool.self,
      forKey: .fallbackToSystemVoice
    ) ?? false
    seedEndpoint = try values.decodeIfPresent(String.self, forKey: .seedEndpoint)
      ?? Self.defaultSeedEndpoint
    seedStreamEndpoint = try values.decodeIfPresent(String.self, forKey: .seedStreamEndpoint)
      ?? Self.defaultSeedStreamEndpoint
    seedModel = try values.decodeIfPresent(String.self, forKey: .seedModel)
      ?? Self.defaultSeedModel
    seedStreamModel = try values.decodeIfPresent(String.self, forKey: .seedStreamModel)
      ?? Self.defaultSeedStreamModel
    seedResourceID = try values.decodeIfPresent(String.self, forKey: .seedResourceID)
      ?? Self.defaultSeedResourceID
    fallbackToCreateEndpoint = try values.decodeIfPresent(
      Bool.self,
      forKey: .fallbackToCreateEndpoint
    ) ?? false
    audioFormat = try values.decodeIfPresent(String.self, forKey: .audioFormat) ?? "mp3"
    sampleRate = try values.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 24_000
    maximumCharacters = try values.decodeIfPresent(Int.self, forKey: .maximumCharacters) ?? 1_200
    cacheTTLSeconds = try values.decodeIfPresent(Int.self, forKey: .cacheTTLSeconds) ?? 300
    requestTimeoutSeconds = try values.decodeIfPresent(
      Double.self,
      forKey: .requestTimeoutSeconds
    ) ?? 30
  }

  public var normalized: NotificationSpeechConfiguration {
    var result = self
    result.voiceID = String(
      voiceID.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
    )
    if result.voiceID.isEmpty {
      result.voiceID = Self.sophieVoiceID
    }
    result.seedEndpoint = String(
      seedEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_048)
    )
    result.seedStreamEndpoint = String(
      seedStreamEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_048)
    )
    result.seedModel = String(
      seedModel.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
    )
    result.seedStreamModel = String(
      seedStreamModel.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
    )
    result.seedResourceID = String(
      seedResourceID.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
    )
    result.audioFormat = audioFormat
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    result.sampleRate = min(max(sampleRate, 8_000), 48_000)
    result.maximumCharacters = min(max(maximumCharacters, 1), 10_000)
    result.cacheTTLSeconds = min(max(cacheTTLSeconds, 0), 86_400)
    result.requestTimeoutSeconds = min(
      max(requestTimeoutSeconds.isFinite ? requestTimeoutSeconds : 30, 1),
      120
    )
    return result
  }

  public func validate() throws {
    guard let endpointURL = URL(string: seedEndpoint) else {
      throw NotificationSpeechConfigurationError.invalidEndpoint
    }
    do {
      try AIBaseURLValidator.validate(endpointURL)
    } catch {
      throw NotificationSpeechConfigurationError.invalidEndpoint
    }
    guard let streamEndpointURL = URL(string: seedStreamEndpoint) else {
      throw NotificationSpeechConfigurationError.invalidStreamEndpoint
    }
    do {
      try AIBaseURLValidator.validate(streamEndpointURL)
    } catch {
      throw NotificationSpeechConfigurationError.invalidStreamEndpoint
    }
    guard !seedModel.isEmpty else { throw NotificationSpeechConfigurationError.emptyModel }
    guard !seedStreamModel.isEmpty else {
      throw NotificationSpeechConfigurationError.emptyStreamModel
    }
    guard !seedResourceID.isEmpty else {
      throw NotificationSpeechConfigurationError.emptyResourceID
    }
    guard ["mp3", "wav"].contains(audioFormat) else {
      throw NotificationSpeechConfigurationError.unsupportedAudioFormat
    }
    guard (8_000...48_000).contains(sampleRate) else {
      throw NotificationSpeechConfigurationError.invalidSampleRate
    }
    guard (1...10_000).contains(maximumCharacters) else {
      throw NotificationSpeechConfigurationError.invalidMaximumCharacters
    }
    guard (0...86_400).contains(cacheTTLSeconds) else {
      throw NotificationSpeechConfigurationError.invalidCacheTTL
    }
    guard requestTimeoutSeconds.isFinite, (1...120).contains(requestTimeoutSeconds) else {
      throw NotificationSpeechConfigurationError.invalidTimeout
    }
  }
}

public struct NotificationSoundEvent: Equatable, Sendable {
  public let kind: NotificationSoundEventKind
  public let eventID: String
  public let group: String?
  public let senderStableID: String?
  public let senderDisplayName: String?
  /// A stable rule, address, or subsystem identifier used for cooldowns.
  public let subjectID: String
  /// Optional runtime detail appended to a configured speech announcement.
  public let speechDetail: String?

  public init(
    kind: NotificationSoundEventKind,
    eventID: String,
    group: String? = nil,
    senderStableID: String? = nil,
    senderDisplayName: String? = nil,
    subjectID: String,
    speechDetail: String? = nil
  ) {
    self.kind = kind
    self.eventID = eventID
    self.group = group
    self.senderStableID = senderStableID
    self.senderDisplayName = senderDisplayName
    self.subjectID = subjectID
    self.speechDetail = speechDetail
  }
}

public struct NotificationSoundRule: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var isEnabled: Bool
  public var eventKind: NotificationSoundEventKind
  public var groups: [String]
  public var senders: [String]
  /// Optional so configurations written before speech support remain decodable.
  public var outputMode: NotificationSoundOutputMode?
  public var soundName: String
  public var volume: Double
  /// Optional so configurations written before speech support remain decodable.
  public var speechAnnouncement: NotificationSpeechAnnouncement?
  public var priority: Int
  public var cooldownInterval: TimeInterval

  public init(
    id: String,
    name: String,
    isEnabled: Bool = true,
    eventKind: NotificationSoundEventKind,
    groups: [String] = [],
    senders: [String] = [],
    outputMode: NotificationSoundOutputMode? = .sound,
    soundName: String,
    volume: Double = 0.8,
    speechAnnouncement: NotificationSpeechAnnouncement? = nil,
    priority: Int = 50,
    cooldownInterval: TimeInterval = 0
  ) {
    self.id = id
    self.name = name
    self.isEnabled = isEnabled
    self.eventKind = eventKind
    self.groups = groups
    self.senders = senders
    self.outputMode = outputMode
    self.soundName = soundName
    self.volume = volume
    self.speechAnnouncement = speechAnnouncement
    self.priority = priority
    self.cooldownInterval = cooldownInterval
  }

  public var specificity: Int {
    (groups.isEmpty ? 0 : 1) + (senders.isEmpty ? 0 : 2)
  }

  public var effectiveOutputMode: NotificationSoundOutputMode {
    outputMode ?? .sound
  }

  public var effectiveSpeechAnnouncement: NotificationSpeechAnnouncement {
    (speechAnnouncement ?? NotificationSpeechAnnouncement(text: eventKind.defaultSpeechText))
      .normalized
  }

  public var normalized: NotificationSoundRule {
    var result = self
    result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    result.soundName = soundName.trimmingCharacters(in: .whitespacesAndNewlines)
    result.groups = Self.normalizedValues(groups)
    result.senders = Self.normalizedValues(senders)
    result.outputMode = effectiveOutputMode
    result.volume = min(max(volume.isFinite ? volume : 0.8, 0), 1)
    result.speechAnnouncement = effectiveSpeechAnnouncement
    result.priority = min(max(priority, 0), 1_000)
    result.cooldownInterval = min(
      max(cooldownInterval.isFinite ? cooldownInterval : 0, 0),
      30 * 24 * 60 * 60
    )
    return result
  }

  private static func normalizedValues(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      let key = trimmed.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
      return seen.insert(key).inserted ? trimmed : nil
    }
  }
}

public struct NotificationSoundConfiguration: Codable, Equatable, Sendable {
  public var isEnabled: Bool
  public var playWhileAppIsActive: Bool
  public var masterVolume: Double
  public var minimumInterval: TimeInterval
  public var mutedUntil: Date?
  public var speech: NotificationSpeechConfiguration
  public var rules: [NotificationSoundRule]

  public init(
    isEnabled: Bool = true,
    playWhileAppIsActive: Bool = true,
    masterVolume: Double = 0.8,
    minimumInterval: TimeInterval = 1.5,
    mutedUntil: Date? = nil,
    speech: NotificationSpeechConfiguration = NotificationSpeechConfiguration(),
    rules: [NotificationSoundRule] = NotificationSoundConfiguration.defaultRules
  ) {
    self.isEnabled = isEnabled
    self.playWhileAppIsActive = playWhileAppIsActive
    self.masterVolume = masterVolume
    self.minimumInterval = minimumInterval
    self.mutedUntil = mutedUntil
    self.speech = speech
    self.rules = rules
  }

  private enum CodingKeys: String, CodingKey {
    case isEnabled
    case playWhileAppIsActive
    case masterVolume
    case minimumInterval
    case mutedUntil
    case speech
    case rules
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    playWhileAppIsActive = try values.decodeIfPresent(Bool.self, forKey: .playWhileAppIsActive) ?? true
    masterVolume = try values.decodeIfPresent(Double.self, forKey: .masterVolume) ?? 0.8
    minimumInterval = try values.decodeIfPresent(TimeInterval.self, forKey: .minimumInterval) ?? 1.5
    mutedUntil = try values.decodeIfPresent(Date.self, forKey: .mutedUntil)
    speech = try values.decodeIfPresent(NotificationSpeechConfiguration.self, forKey: .speech)
      ?? NotificationSpeechConfiguration()
    rules = try values.decodeIfPresent([NotificationSoundRule].self, forKey: .rules)
      ?? Self.defaultRules
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(isEnabled, forKey: .isEnabled)
    try values.encode(playWhileAppIsActive, forKey: .playWhileAppIsActive)
    try values.encode(masterVolume, forKey: .masterVolume)
    try values.encode(minimumInterval, forKey: .minimumInterval)
    try values.encodeIfPresent(mutedUntil, forKey: .mutedUntil)
    try values.encode(rules, forKey: .rules)
  }

  public var normalized: NotificationSoundConfiguration {
    var result = self
    result.masterVolume = min(max(masterVolume.isFinite ? masterVolume : 0.8, 0), 1)
    result.minimumInterval = min(max(minimumInterval.isFinite ? minimumInterval : 1.5, 0), 60)
    result.speech = speech.normalized
    result.rules = rules.map(\.normalized)
    return result
  }

  /// Upgrades only built-in CA rules. User-created speech text is preserved.
  public var migratedForSpeechAnnouncements: NotificationSoundConfiguration {
    var result = self
    for index in result.rules.indices {
      switch result.rules[index].id {
      case "default.crypto-address":
        if result.rules[index].outputMode == nil { result.rules[index].outputMode = .speech }
      case "default.cross-group-address":
        if result.rules[index].outputMode == nil { result.rules[index].outputMode = .speech }
      default:
        if result.rules[index].outputMode == nil { result.rules[index].outputMode = .sound }
      }
      var announcement = result.rules[index].effectiveSpeechAnnouncement
      if result.rules[index].eventKind == .cryptoAddress,
        announcement.text == "发现 CA"
      {
        announcement.text = NotificationSoundEventKind.cryptoAddress.defaultSpeechText
        result.rules[index].speechAnnouncement = announcement
      } else if result.rules[index].eventKind == .crossGroupAddress,
        announcement.text == "发现跨群 CA"
      {
        announcement.text = NotificationSoundEventKind.crossGroupAddress.defaultSpeechText
        result.rules[index].speechAnnouncement = announcement
      }
    }
    return result.normalized
  }

  public static let defaultRules: [NotificationSoundRule] = [
    NotificationSoundRule(
      id: "default.new-message",
      name: "普通新消息",
      isEnabled: false,
      eventKind: .newMessage,
      soundName: "Pop",
      volume: 0.55,
      priority: 10,
      cooldownInterval: 2
    ),
    NotificationSoundRule(
      id: "default.captured-signal",
      name: "重点信号",
      eventKind: .capturedSignal,
      soundName: "Glass",
      volume: 0.72,
      priority: 40,
      cooldownInterval: 20
    ),
    NotificationSoundRule(
      id: "default.crypto-address",
      name: "CA 出现",
      eventKind: .cryptoAddress,
      outputMode: .speech,
      soundName: "Pop",
      volume: 0.72,
      speechAnnouncement: NotificationSpeechAnnouncement(
        text: NotificationSoundEventKind.cryptoAddress.defaultSpeechText
      ),
      priority: 50,
      cooldownInterval: 10 * 60
    ),
    NotificationSoundRule(
      id: "default.cross-group-address",
      name: "跨群 CA",
      eventKind: .crossGroupAddress,
      outputMode: .speech,
      soundName: "Ping",
      volume: 0.85,
      speechAnnouncement: NotificationSpeechAnnouncement(
        text: NotificationSoundEventKind.crossGroupAddress.defaultSpeechText
      ),
      priority: 80,
      cooldownInterval: 5 * 60
    ),
    NotificationSoundRule(
      id: "default.alert-information",
      name: "提示提醒",
      eventKind: .alertInformation,
      soundName: "Tink",
      volume: 0.55,
      priority: 60,
      cooldownInterval: 5 * 60
    ),
    NotificationSoundRule(
      id: "default.alert-warning",
      name: "警告提醒",
      eventKind: .alertWarning,
      soundName: "Sosumi",
      volume: 0.78,
      priority: 90,
      cooldownInterval: 5 * 60
    ),
    NotificationSoundRule(
      id: "default.alert-critical",
      name: "严重提醒",
      eventKind: .alertCritical,
      soundName: "Basso",
      volume: 0.92,
      priority: 100,
      cooldownInterval: 60
    ),
    NotificationSoundRule(
      id: "default.analysis-completed",
      name: "分析完成",
      isEnabled: false,
      eventKind: .analysisCompleted,
      soundName: "Hero",
      volume: 0.5,
      priority: 20
    ),
    NotificationSoundRule(
      id: "default.listener-issue",
      name: "监听异常",
      eventKind: .listenerIssue,
      soundName: "Submarine",
      volume: 0.68,
      priority: 70,
      cooldownInterval: 5 * 60
    ),
  ]
}

public struct NotificationSoundResolution: Equatable, Sendable {
  public let rule: NotificationSoundRule
  public let event: NotificationSoundEvent
  public let cooldownKey: String

  public init(rule: NotificationSoundRule, event: NotificationSoundEvent, cooldownKey: String) {
    self.rule = rule
    self.event = event
    self.cooldownKey = cooldownKey
  }
}

public enum NotificationSoundPolicy {
  public static func resolve(
    events: [NotificationSoundEvent],
    configuration: NotificationSoundConfiguration,
    lastPlayedAtByKey: [String: Date] = [:],
    now: Date = Date()
  ) -> NotificationSoundResolution? {
    let configuration = configuration.normalized
    guard configuration.isEnabled,
      configuration.mutedUntil.map({ $0 <= now }) ?? true
    else { return nil }

    var candidates: [(resolution: NotificationSoundResolution, ruleIndex: Int)] = []
    for (ruleIndex, rule) in configuration.rules.enumerated() where rule.isEnabled {
      for event in events where event.kind == rule.eventKind && matches(rule: rule, event: event) {
        let cooldownKey = "\(rule.id)|\(event.kind.rawValue)|\(event.subjectID)"
        candidates.append(
          (
            NotificationSoundResolution(
              rule: rule,
              event: event,
              cooldownKey: cooldownKey
            ),
            ruleIndex
          )
        )
      }
    }

    guard let winner = candidates.sorted(by: { lhs, rhs in
      if lhs.resolution.rule.priority != rhs.resolution.rule.priority {
        return lhs.resolution.rule.priority > rhs.resolution.rule.priority
      }
      if lhs.resolution.rule.specificity != rhs.resolution.rule.specificity {
        return lhs.resolution.rule.specificity > rhs.resolution.rule.specificity
      }
      return lhs.ruleIndex < rhs.ruleIndex
    }).first?.resolution else { return nil }

    if let lastPlayedAt = lastPlayedAtByKey[winner.cooldownKey],
      now.timeIntervalSince(lastPlayedAt) < winner.rule.cooldownInterval
    {
      return nil
    }
    return winner
  }

  private static func matches(
    rule: NotificationSoundRule,
    event: NotificationSoundEvent
  ) -> Bool {
    if !rule.groups.isEmpty {
      guard let group = event.group,
        rule.groups.contains(where: { equals($0, group) })
      else { return false }
    }
    if !rule.senders.isEmpty {
      let candidates = [event.senderStableID, event.senderDisplayName].compactMap { $0 }
      guard rule.senders.contains(where: { sender in
        candidates.contains(where: { equals(sender, $0) })
      }) else { return false }
    }
    return true
  }

  private static func equals(_ lhs: String, _ rhs: String) -> Bool {
    lhs.compare(rhs, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
  }
}
