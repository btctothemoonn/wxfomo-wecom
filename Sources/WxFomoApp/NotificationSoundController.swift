import AppKit
import AVFoundation
import Foundation
import WxFomoCore

enum NotificationSoundChoice: String, CaseIterable, Identifiable {
  case basso = "Basso"
  case blow = "Blow"
  case bottle = "Bottle"
  case funk = "Funk"
  case glass = "Glass"
  case hero = "Hero"
  case morse = "Morse"
  case ping = "Ping"
  case pop = "Pop"
  case purr = "Purr"
  case sosumi = "Sosumi"
  case submarine = "Submarine"
  case tink = "Tink"

  var id: String { rawValue }

  var localizedTitle: String {
    switch self {
    case .basso: return "低沉警示"
    case .blow: return "短促气音"
    case .bottle: return "清脆瓶音"
    case .funk: return "强提醒"
    case .glass: return "玻璃脉冲"
    case .hero: return "完成"
    case .morse: return "电码"
    case .ping: return "雷达"
    case .pop: return "数字点击"
    case .purr: return "柔和震动"
    case .sosumi: return "警告"
    case .submarine: return "系统异常"
    case .tink: return "轻提示"
    }
  }
}

enum NotificationSpeechVoiceChoice: String, CaseIterable, Identifiable {
  case vivi = "zh_female_vv_uranus_bigtts"
  case sophie = "zh_female_sophie_uranus_bigtts"
  case cheerfulSister = "zh_female_kailangjiejie_uranus_bigtts"
  case intellectual = "zh_female_zhixingnv_uranus_bigtts"

  var id: String { rawValue }

  var localizedTitle: String {
    switch self {
    case .vivi: return "Vivi 2.0"
    case .sophie: return "魅力苏菲 2.0"
    case .cheerfulSister: return "开朗姐姐 2.0"
    case .intellectual: return "知性女声 2.0"
    }
  }
}

private enum VolcengineSpeechError: LocalizedError {
  case invalidRequest
  case requestFailed(Int, String)
  case compatibilityFallbackFailed(String)
  case emptyAudio

  var errorDescription: String? {
    switch self {
    case .invalidRequest: return "火山语音请求无效"
    case .requestFailed(let status, let message):
      return "火山语音请求失败（\(status)）：\(message)"
    case .compatibilityFallbackFailed(let message):
      return "火山流式语音和创建接口均失败：\(message)"
    case .emptyAudio: return "火山语音没有返回音频"
    }
  }
}

private actor VolcengineSeedSpeechClient {
  enum Delivery: Sendable {
    case chunkedStream
    case createCompatibility
  }

  struct SpeechAudio: Sendable {
    let data: Data
    let delivery: Delivery
  }

  private struct CachedAudio {
    let speechAudio: SpeechAudio
    let storedAt: Date
  }

  private let transport = URLSessionAIHTTPTransport(maximumResponseBytes: 4 * 1_024 * 1_024)
  private var audioCache: [String: CachedAudio] = [:]
  private var cacheOrder: [String] = []

  func synthesize(
    text: String,
    voiceID: String,
    rate: Double,
    apiKey: String,
    configuration: NotificationSpeechConfiguration
  ) async throws -> SpeechAudio {
    let service = configuration.normalized
    try service.validate()
    guard URL(string: service.seedStreamEndpoint) != nil else {
      throw VolcengineSpeechError.invalidRequest
    }
    let normalizedText = String(
      text.trimmingCharacters(in: .whitespacesAndNewlines)
        .prefix(service.maximumCharacters)
    )
    let normalizedVoice = String(voiceID.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedText.isEmpty, !normalizedVoice.isEmpty, !normalizedKey.isEmpty else {
      throw VolcengineSpeechError.invalidRequest
    }

    let speechRate = min(max(Int(((rate - 1) * 100).rounded()), -50), 100)
    let cacheKey = [
      service.seedStreamEndpoint,
      service.seedStreamModel,
      service.seedResourceID,
      service.audioFormat,
      String(service.sampleRate),
      normalizedVoice,
      String(speechRate),
      normalizedText,
    ].joined(separator: "|")
    if let cached = audioCache[cacheKey],
      Date().timeIntervalSince(cached.storedAt) <= Double(service.cacheTTLSeconds)
    {
      return cached.speechAudio
    }
    audioCache.removeValue(forKey: cacheKey)

    let speechAudio: SpeechAudio
    do {
      speechAudio = try await synthesizeStream(
        text: normalizedText,
        voiceID: normalizedVoice,
        speechRate: speechRate,
        apiKey: normalizedKey,
        configuration: service
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
      guard service.fallbackToCreateEndpoint else { throw error }
      do {
        let data = try await synthesizeCreate(
          text: normalizedText,
          voiceID: normalizedVoice,
          speechRate: speechRate,
          apiKey: normalizedKey,
          configuration: service
        )
        speechAudio = SpeechAudio(data: data, delivery: .createCompatibility)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw VolcengineSpeechError.compatibilityFallbackFailed(error.localizedDescription)
      }
    }
    if service.cacheTTLSeconds > 0 {
      cache(speechAudio, for: cacheKey)
    }
    return speechAudio
  }

  private func synthesizeStream(
    text: String,
    voiceID: String,
    speechRate: Int,
    apiKey: String,
    configuration: NotificationSpeechConfiguration
  ) async throws -> SpeechAudio {
    guard let endpoint = URL(string: configuration.seedStreamEndpoint) else {
      throw VolcengineSpeechError.invalidRequest
    }
    let additions: [String: Any] = [
      "disable_markdown_filter": true,
      "cache_config": [
        "text_type": 1,
        "use_cache": configuration.cacheTTLSeconds > 0,
      ],
    ]
    guard let additionsData = try? JSONSerialization.data(withJSONObject: additions),
      let additionsText = String(data: additionsData, encoding: .utf8)
    else { throw VolcengineSpeechError.invalidRequest }

    let body: [String: Any] = [
      "user": ["uid": "wxFomo"],
      "req_params": [
        "text": text,
        "speaker": voiceID,
        "model": configuration.seedStreamModel,
        "audio_params": [
          "format": configuration.audioFormat,
          "sample_rate": configuration.sampleRate,
          "speech_rate": speechRate,
        ],
        "additions": additionsText,
      ],
    ]
    guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
      throw VolcengineSpeechError.invalidRequest
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = configuration.requestTimeoutSeconds
    request.httpBody = bodyData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/plain", forHTTPHeaderField: "Accept")
    request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
    request.setValue(configuration.seedResourceID, forHTTPHeaderField: "X-Api-Resource-Id")
    request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")

    let (bytes, response) = try await transport.session.bytes(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw VolcengineSpeechError.invalidRequest
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      var errorData = Data()
      for try await byte in bytes {
        guard errorData.count < 64 * 1_024 else { break }
        errorData.append(byte)
      }
      throw VolcengineSpeechError.requestFailed(
        httpResponse.statusCode,
        Self.errorMessage(from: errorData)
      )
    }

    var parser = VolcengineSeedStreamParser()
    var networkChunk = Data()
    networkChunk.reserveCapacity(16 * 1_024)
    for try await byte in bytes {
      try Task.checkCancellation()
      networkChunk.append(byte)
      if byte == 0x0A || networkChunk.count >= 16 * 1_024 {
        _ = try parser.consume(networkChunk)
        networkChunk.removeAll(keepingCapacity: true)
      }
    }
    if !networkChunk.isEmpty {
      _ = try parser.consume(networkChunk)
    }
    let audio = try parser.finish()
    return SpeechAudio(data: audio, delivery: .chunkedStream)
  }

  private func synthesizeCreate(
    text: String,
    voiceID: String,
    speechRate: Int,
    apiKey: String,
    configuration: NotificationSpeechConfiguration
  ) async throws -> Data {
    guard let endpoint = URL(string: configuration.seedEndpoint) else {
      throw VolcengineSpeechError.invalidRequest
    }
    let body: [String: Any] = [
      "model": configuration.seedModel,
      "text_prompt": text,
      "speaker": voiceID,
      "audio_config": [
        "format": configuration.audioFormat,
        "sample_rate": configuration.sampleRate,
        "speech_rate": speechRate,
      ],
    ]
    guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
      throw VolcengineSpeechError.invalidRequest
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = configuration.requestTimeoutSeconds
    request.httpBody = bodyData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
    request.setValue(configuration.seedResourceID, forHTTPHeaderField: "X-Api-Resource-Id")
    request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")

    let response = try await transport.send(request)
    guard (200..<300).contains(response.statusCode) else {
      throw VolcengineSpeechError.requestFailed(
        response.statusCode,
        Self.errorMessage(from: response.data)
      )
    }
    return try Self.audioData(from: response)
  }

  private func cache(_ speechAudio: SpeechAudio, for key: String) {
    audioCache[key] = CachedAudio(speechAudio: speechAudio, storedAt: Date())
    cacheOrder.removeAll { $0 == key }
    cacheOrder.append(key)
    while cacheOrder.count > 32 {
      audioCache.removeValue(forKey: cacheOrder.removeFirst())
    }
  }

  private static func audioData(from response: AIHTTPResponse) throws -> Data {
    if response.header(named: "content-type")?.lowercased().hasPrefix("audio/") == true,
      !response.data.isEmpty
    {
      return response.data
    }
    guard let object = try? JSONSerialization.jsonObject(with: response.data),
      let payload = object as? [String: Any]
    else { throw VolcengineSpeechError.emptyAudio }

    let values: [Any?] = [
      payload["audio"],
      (payload["data"] as? [String: Any])?["audio"],
      payload["data"],
      (payload["result"] as? [String: Any])?["audio"],
      ((payload["result"] as? [String: Any])?["data"] as? [String: Any])?["audio"],
      (payload["result"] as? [String: Any])?["data"],
    ]
    for case let value as String in values {
      if let audio = Data(base64Encoded: value), !audio.isEmpty { return audio }
    }
    throw VolcengineSpeechError.emptyAudio
  }

  private static func errorMessage(from data: Data) -> String {
    guard let object = try? JSONSerialization.jsonObject(with: data),
      let payload = object as? [String: Any]
    else { return "未知错误" }
    return String(
      describing: payload["message"] ?? payload["error"] ?? payload["err_msg"] ?? "未知错误"
    )
    .prefix(160)
    .description
  }
}

@MainActor
final class NotificationSoundController {
  private var lastPlayedAtByKey: [String: Date] = [:]
  private var lastPlaybackAt: Date?
  private var lastPlaybackPriority = 0
  private var currentEffectSound: NSSound?
  private var currentSpeechPlayer: AVAudioPlayer?
  private let systemSpeechSynthesizer = AVSpeechSynthesizer()
  private var speechTask: Task<Void, Never>?
  private let speechClient = VolcengineSeedSpeechClient()

  @discardableResult
  func playBest(
    events: [NotificationSoundEvent],
    configuration: NotificationSoundConfiguration,
    appIsActive: Bool,
    speechAPIKey: String?,
    speechStatus: (@MainActor (String) -> Void)? = nil,
    now: Date = Date()
  ) -> NotificationSoundResolution? {
    guard configuration.playWhileAppIsActive || !appIsActive,
      let resolution = NotificationSoundPolicy.resolve(
        events: events,
        configuration: configuration,
        lastPlayedAtByKey: lastPlayedAtByKey,
        now: now
      )
    else { return nil }

    if let lastPlaybackAt,
      now.timeIntervalSince(lastPlaybackAt) < configuration.minimumInterval,
      resolution.rule.priority <= lastPlaybackPriority
    {
      return nil
    }

    var rule = resolution.rule
    if let speechDetail = resolution.event.speechDetail,
      !speechDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      var announcement = rule.effectiveSpeechAnnouncement
      let isLegacyDefault = announcement.text == "发现 CA"
        || announcement.text == "发现跨群 CA"
      if announcement.text == resolution.event.kind.defaultSpeechText
        || isLegacyDefault
      {
        announcement.text = speechDetail
      } else {
        announcement.text = "\(announcement.text)，\(speechDetail)"
      }
      rule.speechAnnouncement = announcement
    }

    guard play(
      rule: rule,
      configuration: configuration,
      speechAPIKey: speechAPIKey,
      speechStatus: speechStatus
    ) else { return nil }
    lastPlayedAtByKey[resolution.cooldownKey] = now
    self.lastPlaybackAt = now
    lastPlaybackPriority = resolution.rule.priority
    prunePlaybackHistory(now: now)
    return resolution
  }

  @discardableResult
  func preview(
    rule: NotificationSoundRule,
    configuration: NotificationSoundConfiguration,
    speechAPIKey: String?,
    speechStatus: (@MainActor (String) -> Void)? = nil
  ) -> Bool {
    play(
      rule: rule.normalized,
      configuration: configuration.normalized,
      speechAPIKey: speechAPIKey,
      speechStatus: speechStatus
    )
  }

  private func play(
    rule: NotificationSoundRule,
    configuration: NotificationSoundConfiguration,
    speechAPIKey: String?,
    speechStatus: (@MainActor (String) -> Void)?
  ) -> Bool {
    let mode = rule.effectiveOutputMode
    let soundStarted = mode.includesSound && playEffect(
      soundName: rule.soundName,
      volume: configuration.masterVolume * rule.volume
    )
    let speechStarted = mode.includesSpeech && playSpeech(
      rule.effectiveSpeechAnnouncement,
      configuration: configuration.speech,
      masterVolume: configuration.masterVolume,
      apiKey: speechAPIKey,
      status: speechStatus
    )
    return soundStarted || speechStarted
  }

  private func playEffect(soundName: String, volume: Double) -> Bool {
    guard let sound = NSSound(named: NSSound.Name(soundName)) else {
      NSSound.beep()
      return false
    }
    currentEffectSound?.stop()
    sound.volume = Float(min(max(volume, 0), 1))
    currentEffectSound = sound
    return sound.play()
  }

  private func playSpeech(
    _ announcement: NotificationSpeechAnnouncement,
    configuration: NotificationSpeechConfiguration,
    masterVolume: Double,
    apiKey: String?,
    status: (@MainActor (String) -> Void)?
  ) -> Bool {
    let announcement = announcement.normalized
    guard !announcement.text.isEmpty else { return false }
    let volume = min(max(masterVolume * announcement.volume, 0), 1)
    speechTask?.cancel()
    systemSpeechSynthesizer.stopSpeaking(at: .immediate)
    currentSpeechPlayer?.stop()

    if configuration.provider == .system {
      let started = playSystemSpeech(announcement, volume: volume)
      if started { status?("正在使用系统中文语音播报") }
      return started
    }

    guard let apiKey, !apiKey.isEmpty else {
      guard configuration.fallbackToSystemVoice else {
        status?("火山语音尚未配置 API Key")
        return false
      }
      let started = playSystemSpeech(announcement, volume: volume)
      if started { status?("火山语音未配置，已使用系统中文语音") }
      return started
    }

    let voiceID = configuration.voiceID
    let fallback = configuration.fallbackToSystemVoice
    speechTask = Task { [weak self, speechClient] in
      do {
        let speechAudio = try await speechClient.synthesize(
          text: announcement.text,
          voiceID: voiceID,
          rate: announcement.rate,
          apiKey: apiKey,
          configuration: configuration
        )
        guard !Task.isCancelled, let self else { return }
        let player = try AVAudioPlayer(data: speechAudio.data)
        player.volume = Float(volume)
        guard player.prepareToPlay() else { throw VolcengineSpeechError.emptyAudio }
        self.currentSpeechPlayer = player
        if player.play() {
          let voice = NotificationSpeechVoiceChoice(rawValue: voiceID)?.localizedTitle ?? "火山语音"
          switch speechAudio.delivery {
          case .chunkedStream:
            status?("正在使用流式 \(voice) 播报")
          case .createCompatibility:
            status?("流式接口失败，正在使用创建接口兼容播放 \(voice)")
          }
        } else {
          throw VolcengineSpeechError.emptyAudio
        }
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, let self else { return }
        if fallback, self.playSystemSpeech(announcement, volume: volume) {
          status?("火山语音失败：\(error.localizedDescription)；已使用系统中文语音")
        } else {
          status?(error.localizedDescription)
        }
      }
    }
    return true
  }

  private func playSystemSpeech(
    _ announcement: NotificationSpeechAnnouncement,
    volume: Double
  ) -> Bool {
    let utterance = AVSpeechUtterance(string: announcement.text)
    utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
      ?? AVSpeechSynthesisVoice.speechVoices().first {
        $0.language.lowercased().hasPrefix("zh")
      }
    utterance.volume = Float(volume)
    utterance.rate = min(
      max(AVSpeechUtteranceDefaultSpeechRate * Float(announcement.rate), 0.1),
      1
    )
    systemSpeechSynthesizer.speak(utterance)
    return true
  }

  private func prunePlaybackHistory(now: Date) {
    guard lastPlayedAtByKey.count > 1_000 else { return }
    lastPlayedAtByKey = lastPlayedAtByKey.filter {
      now.timeIntervalSince($0.value) < 30 * 24 * 60 * 60
    }
  }
}
