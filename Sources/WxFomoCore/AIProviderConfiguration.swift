import Foundation

public enum AIProviderKind: String, Codable, CaseIterable, Sendable {
  case openAIResponses = "openai_responses"
  case openAIChatCompletions = "openai_chat_completions"
  case openAICompatibleChatCompletions = "openai_compatible_chat_completions"
  case anthropicMessages = "anthropic_messages"

  public var defaultBaseURL: URL? {
    switch self {
    case .openAIResponses, .openAIChatCompletions:
      return URL(string: "https://api.openai.com/v1")
    case .openAICompatibleChatCompletions:
      return nil
    case .anthropicMessages:
      return URL(string: "https://api.anthropic.com/v1")
    }
  }

  public var endpointPath: String {
    switch self {
    case .openAIResponses:
      return "responses"
    case .openAIChatCompletions, .openAICompatibleChatCompletions:
      return "chat/completions"
    case .anthropicMessages:
      return "messages"
    }
  }
}

public enum AIStructuredOutputMode: String, Codable, CaseIterable, Sendable {
  case jsonSchema = "json_schema"
  case jsonObject = "json_object"
  case promptOnly = "prompt_only"
}

public enum AIBaseURLValidationError: Error, Equatable, Sendable {
  case notAbsolute
  case unsupportedScheme
  case missingHost
  case credentialsNotAllowed
  case queryNotAllowed
  case fragmentNotAllowed
  case insecureNonLoopbackHTTP
}

public enum AIProviderConfigurationError: Error, Equatable, Sendable {
  case emptyIdentifier
  case emptyDisplayName
  case emptyModel
  case missingBaseURL
  case invalidBaseURL(AIBaseURLValidationError)
  case emptyCredentialReference
  case invalidTimeout
  case invalidMaximumOutputTokens
  case unsupportedStructuredOutputMode
  case officialProviderRequiresOfficialEndpoint
}

public enum AIBaseURLValidator {
  public static func validate(_ url: URL) throws {
    guard url.baseURL == nil,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.scheme != nil else {
      throw AIBaseURLValidationError.notAbsolute
    }

    let scheme = components.scheme?.lowercased()
    guard scheme == "https" || scheme == "http" else {
      throw AIBaseURLValidationError.unsupportedScheme
    }
    guard let host = components.host, !host.isEmpty else {
      throw AIBaseURLValidationError.missingHost
    }
    guard components.user == nil, components.password == nil else {
      throw AIBaseURLValidationError.credentialsNotAllowed
    }
    guard components.query == nil else {
      throw AIBaseURLValidationError.queryNotAllowed
    }
    guard components.fragment == nil else {
      throw AIBaseURLValidationError.fragmentNotAllowed
    }
    if scheme == "http" && !isLoopbackHost(host) {
      throw AIBaseURLValidationError.insecureNonLoopbackHTTP
    }
  }

  public static func isLoopbackHost(_ host: String) -> Bool {
    var normalized = host.lowercased()
    if normalized.hasPrefix("[") && normalized.hasSuffix("]") {
      normalized.removeFirst()
      normalized.removeLast()
    }
    if normalized == "localhost" || normalized == "::1" || normalized == "0:0:0:0:0:0:0:1" {
      return true
    }

    let octets = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4,
          octets.allSatisfy({ octet in
            guard !octet.isEmpty,
                  octet.allSatisfy(\.isNumber),
                  let value = Int(octet) else { return false }
            return value >= 0 && value <= 255
          }),
          Int(octets[0]) == 127 else {
      return false
    }
    return true
  }
}

public struct AIProviderConfiguration: Codable, Equatable, Sendable, Identifiable {
  public static let defaultTimeoutSeconds = 90.0
  public static let defaultMaximumOutputTokens = 4_096

  public let configurationID: String
  public let displayName: String
  public let kind: AIProviderKind
  public let baseURL: URL
  public let model: String
  public let credentialReference: String
  public let timeoutSeconds: Double
  public let maximumOutputTokens: Int
  public let structuredOutputMode: AIStructuredOutputMode

  public var id: String { configurationID }

  public init(
    configurationID: String = UUID().uuidString,
    displayName: String,
    kind: AIProviderKind,
    baseURL: URL? = nil,
    model: String,
    credentialReference: String,
    timeoutSeconds: Double = AIProviderConfiguration.defaultTimeoutSeconds,
    maximumOutputTokens: Int = AIProviderConfiguration.defaultMaximumOutputTokens,
    structuredOutputMode: AIStructuredOutputMode? = nil
  ) throws {
    guard let resolvedBaseURL = baseURL ?? kind.defaultBaseURL else {
      throw AIProviderConfigurationError.missingBaseURL
    }
    let resolvedOutputMode = structuredOutputMode ?? Self.defaultOutputMode(for: kind)

    self.configurationID = configurationID
    self.displayName = displayName
    self.kind = kind
    self.baseURL = resolvedBaseURL
    self.model = model
    self.credentialReference = credentialReference
    self.timeoutSeconds = timeoutSeconds
    self.maximumOutputTokens = maximumOutputTokens
    self.structuredOutputMode = resolvedOutputMode

    try validate()
  }

  public func validate() throws {
    guard !configurationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AIProviderConfigurationError.emptyIdentifier
    }
    guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AIProviderConfigurationError.emptyDisplayName
    }
    guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AIProviderConfigurationError.emptyModel
    }
    guard !credentialReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AIProviderConfigurationError.emptyCredentialReference
    }
    guard timeoutSeconds.isFinite, timeoutSeconds >= 1, timeoutSeconds <= 600 else {
      throw AIProviderConfigurationError.invalidTimeout
    }
    guard maximumOutputTokens >= 1, maximumOutputTokens <= 200_000 else {
      throw AIProviderConfigurationError.invalidMaximumOutputTokens
    }
    do {
      try AIBaseURLValidator.validate(baseURL)
    } catch let error as AIBaseURLValidationError {
      throw AIProviderConfigurationError.invalidBaseURL(error)
    }

    switch kind {
    case .openAIResponses, .openAIChatCompletions:
      guard Self.matchesOfficialEndpoint(
        baseURL,
        scheme: "https",
        host: "api.openai.com",
        path: "/v1"
      ) else {
        throw AIProviderConfigurationError.officialProviderRequiresOfficialEndpoint
      }
    case .anthropicMessages:
      guard Self.matchesOfficialEndpoint(
        baseURL,
        scheme: "https",
        host: "api.anthropic.com",
        path: "/v1"
      ) else {
        throw AIProviderConfigurationError.officialProviderRequiresOfficialEndpoint
      }
    case .openAICompatibleChatCompletions:
      break
    }

    switch (kind, structuredOutputMode) {
    case (.anthropicMessages, .jsonObject):
      throw AIProviderConfigurationError.unsupportedStructuredOutputMode
    default:
      break
    }
  }

  public func endpointURL() throws -> URL {
    try validate()
    if kind == .openAICompatibleChatCompletions {
      return try Self.openAICompatibleEndpointURL(from: baseURL)
    }
    return baseURL.appending(path: kind.endpointPath)
  }

  public func modelCatalogURL() throws -> URL {
    try validate()
    guard var components = URLComponents(
      url: baseURL,
      resolvingAgainstBaseURL: false
    ) else {
      throw AIProviderConfigurationError.invalidBaseURL(.notAbsolute)
    }

    var path = Self.normalizedPath(components.path)
    if kind == .openAICompatibleChatCompletions,
      path.lowercased().hasSuffix("/chat/completions")
    {
      path.removeLast("/chat/completions".count)
    }
    path = Self.normalizedPath(path)
    if path.isEmpty {
      path = "/v1"
    }
    if !path.lowercased().hasSuffix("/models") {
      path += "/models"
    }
    components.path = path
    guard let url = components.url else {
      throw AIProviderConfigurationError.invalidBaseURL(.notAbsolute)
    }
    return url
  }

  private static func defaultOutputMode(for kind: AIProviderKind) -> AIStructuredOutputMode {
    switch kind {
    case .openAIResponses, .openAIChatCompletions, .anthropicMessages:
      return .jsonSchema
    case .openAICompatibleChatCompletions:
      return .jsonObject
    }
  }

  private static func matchesOfficialEndpoint(
    _ url: URL,
    scheme: String,
    host: String,
    path: String
  ) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return false
    }
    let normalizedPath = components.path.hasSuffix("/")
      ? String(components.path.dropLast())
      : components.path
    return components.scheme?.lowercased() == scheme
      && components.host?.lowercased() == host
      && components.port == nil
      && normalizedPath == path
  }

  private static func openAICompatibleEndpointURL(from baseURL: URL) throws -> URL {
    guard var components = URLComponents(
      url: baseURL,
      resolvingAgainstBaseURL: false
    ) else {
      throw AIProviderConfigurationError.invalidBaseURL(.notAbsolute)
    }
    var path = normalizedPath(components.path)
    if path.lowercased().hasSuffix("/chat/completions") {
      components.path = path
    } else {
      if path.isEmpty { path = "/v1" }
      components.path = path + "/chat/completions"
    }
    guard let url = components.url else {
      throw AIProviderConfigurationError.invalidBaseURL(.notAbsolute)
    }
    return url
  }

  private static func normalizedPath(_ path: String) -> String {
    guard !path.isEmpty, path != "/" else { return "" }
    var normalized = path.hasPrefix("/") ? path : "/" + path
    while normalized.count > 1, normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    return normalized
  }

  private enum CodingKeys: String, CodingKey {
    case configurationID
    case displayName
    case kind
    case baseURL
    case model
    case credentialReference
    case timeoutSeconds
    case maximumOutputTokens
    case structuredOutputMode
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    configurationID = try container.decode(String.self, forKey: .configurationID)
    displayName = try container.decode(String.self, forKey: .displayName)
    kind = try container.decode(AIProviderKind.self, forKey: .kind)
    baseURL = try container.decode(URL.self, forKey: .baseURL)
    model = try container.decode(String.self, forKey: .model)
    credentialReference = try container.decode(String.self, forKey: .credentialReference)
    timeoutSeconds = try container.decode(Double.self, forKey: .timeoutSeconds)
    maximumOutputTokens = try container.decode(Int.self, forKey: .maximumOutputTokens)
    structuredOutputMode = try container.decode(AIStructuredOutputMode.self, forKey: .structuredOutputMode)
    try validate()
  }
}
