import Foundation

public protocol AICredentialStoring: Sendable {
  func storeAPIKey(_ apiKey: String, for configuration: AIProviderConfiguration) throws
  func apiKey(for configuration: AIProviderConfiguration) throws -> String
  func deleteAPIKey(for configuration: AIProviderConfiguration) throws
}

public enum AICredentialStoreError: Error, Equatable, Sendable {
  case emptyReference
  case emptyAPIKey
  case credentialNotFound
  case invalidCredentialData
  case invalidConfiguration
  case invalidConfigurationDocument
  case unsupportedConfigurationVersion(Int)
}

extension AICredentialStoreError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .emptyReference: return "凭据引用无效"
    case .emptyAPIKey: return "API Key 不能为空"
    case .credentialNotFound: return "尚未配置 API Key"
    case .invalidCredentialData: return "API Key 格式无效"
    case .invalidConfiguration: return "服务配置无效"
    case .invalidConfigurationDocument: return "本地配置中心文件无效"
    case .unsupportedConfigurationVersion(let version):
      return "不支持配置中心文件版本 \(version)"
    }
  }
}

/// Stores only values explicitly configured for wxFomo. It never discovers
/// credentials from Keychain, environment variables, or unrelated files.
public final class FileConfigurationCenterStore: AICredentialStoring, @unchecked Sendable {
  public static let currentVersion = 1
  public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/wxFomo", isDirectory: true)
    .appendingPathComponent("configuration-center.json", isDirectory: false)

  private static let fileLock = NSLock()

  public let fileURL: URL

  public init(fileURL: URL = FileConfigurationCenterStore.defaultURL) {
    self.fileURL = fileURL
  }

  public var configurationFileExists: Bool {
    Self.fileLock.withLock {
      FileManager.default.fileExists(atPath: fileURL.path)
    }
  }

  public func storeAPIKey(_ apiKey: String, for configuration: AIProviderConfiguration) throws {
    let account = try account(for: configuration)
    let key = try validatedAPIKey(apiKey)
    try Self.fileLock.withLock {
      var document = try loadDocument()
      document.aiProviderAPIKeys[account] = key
      try write(document)
    }
  }

  public func apiKey(for configuration: AIProviderConfiguration) throws -> String {
    let account = try account(for: configuration)
    return try Self.fileLock.withLock {
      let document = try loadDocument()
      guard let key = document.aiProviderAPIKeys[account] else {
        throw AICredentialStoreError.credentialNotFound
      }
      return try validatedAPIKey(key)
    }
  }

  public func deleteAPIKey(for configuration: AIProviderConfiguration) throws {
    let account = try account(for: configuration)
    try Self.fileLock.withLock {
      guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
      var document = try loadDocument()
      document.aiProviderAPIKeys.removeValue(forKey: account)
      try write(document)
    }
  }

  public func speechConfiguration() throws -> NotificationSpeechConfiguration {
    try Self.fileLock.withLock {
      let configuration = try loadDocument().speech.configuration.normalized
      try configuration.validate()
      return configuration
    }
  }

  public func storeSpeechConfiguration(
    _ configuration: NotificationSpeechConfiguration,
    updatingAPIKey apiKey: String? = nil
  ) throws {
    let normalized = configuration.normalized
    try normalized.validate()
    let normalizedKey = try apiKey.map(validatedAPIKey)
    try Self.fileLock.withLock {
      var document = try loadDocument()
      document.speech.configuration = normalized
      if let normalizedKey {
        document.speech.volcengineSeedAPIKey = normalizedKey
      }
      try write(document)
    }
  }

  public func storeSpeechAPIKey(_ apiKey: String) throws {
    let key = try validatedAPIKey(apiKey)
    try Self.fileLock.withLock {
      var document = try loadDocument()
      document.speech.volcengineSeedAPIKey = key
      try write(document)
    }
  }

  public func speechAPIKey() throws -> String {
    try Self.fileLock.withLock {
      guard let key = try loadDocument().speech.volcengineSeedAPIKey else {
        throw AICredentialStoreError.credentialNotFound
      }
      return try validatedAPIKey(key)
    }
  }

  public func deleteSpeechAPIKey() throws {
    try Self.fileLock.withLock {
      guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
      var document = try loadDocument()
      document.speech.volcengineSeedAPIKey = nil
      try write(document)
    }
  }

  private struct Document: Codable {
    var version: Int
    var aiProviderAPIKeys: [String: String]
    var speech: StoredSpeechConfiguration

    init(
      version: Int = FileConfigurationCenterStore.currentVersion,
      aiProviderAPIKeys: [String: String] = [:],
      speech: StoredSpeechConfiguration = StoredSpeechConfiguration()
    ) {
      self.version = version
      self.aiProviderAPIKeys = aiProviderAPIKeys
      self.speech = speech
    }

    private enum CodingKeys: String, CodingKey {
      case version
      case aiProviderAPIKeys
      case speech
    }

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
      aiProviderAPIKeys = try values.decodeIfPresent(
        [String: String].self,
        forKey: .aiProviderAPIKeys
      ) ?? [:]
      speech = try values.decodeIfPresent(
        StoredSpeechConfiguration.self,
        forKey: .speech
      ) ?? StoredSpeechConfiguration()
    }
  }

  private struct StoredSpeechConfiguration: Codable {
    var configuration: NotificationSpeechConfiguration
    var volcengineSeedAPIKey: String?

    init(
      configuration: NotificationSpeechConfiguration = NotificationSpeechConfiguration(),
      volcengineSeedAPIKey: String? = nil
    ) {
      self.configuration = configuration
      self.volcengineSeedAPIKey = volcengineSeedAPIKey
    }
  }

  private func loadDocument() throws -> Document {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return Document()
    }
    let document: Document
    do {
      document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
    } catch {
      throw AICredentialStoreError.invalidConfigurationDocument
    }
    guard document.version == Self.currentVersion else {
      throw AICredentialStoreError.unsupportedConfigurationVersion(document.version)
    }
    do {
      try document.speech.configuration.validate()
      for (reference, key) in document.aiProviderAPIKeys {
        guard !reference.isEmpty, reference.count <= 1_024 else {
          throw AICredentialStoreError.invalidConfigurationDocument
        }
        _ = try validatedAPIKey(key)
      }
      if let speechKey = document.speech.volcengineSeedAPIKey {
        _ = try validatedAPIKey(speechKey)
      }
    } catch let error as AICredentialStoreError {
      throw error
    } catch {
      throw AICredentialStoreError.invalidConfigurationDocument
    }
    return document
  }

  private func write(_ document: Document) throws {
    let fileManager = FileManager.default
    let directoryURL = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directoryURL.path
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(document)
    try data.write(to: fileURL, options: .atomic)
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fileURL.path
    )
  }

  private func account(for configuration: AIProviderConfiguration) throws -> String {
    do {
      try configuration.validate()
    } catch {
      throw AICredentialStoreError.invalidConfiguration
    }
    let reference = configuration.credentialReference
    guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      reference.count <= 256,
      !reference.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      let components = URLComponents(
        url: configuration.baseURL,
        resolvingAgainstBaseURL: false
      ),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased()
    else {
      throw AICredentialStoreError.emptyReference
    }
    let port = components.port.map { ":\($0)" } ?? ""
    return "\(reference)\u{1f}\(configuration.kind.rawValue)\u{1f}\(scheme)://\(host)\(port)"
  }

  private func validatedAPIKey(_ apiKey: String) throws -> String {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty,
      key == apiKey,
      key.count <= 8_192,
      !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? AICredentialStoreError.emptyAPIKey
        : AICredentialStoreError.invalidCredentialData
    }
    return key
  }
}
