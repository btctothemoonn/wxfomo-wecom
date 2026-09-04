import Foundation

public enum AIProviderConnectionTestStatus: String, Codable, Equatable, Sendable {
  case success
  case warning
  case failure
}

public enum AIProviderConnectionTestCode: String, Codable, Equatable, Sendable {
  case catalogVerified = "catalog_verified"
  case catalogUnavailable = "catalog_unavailable"
  case catalogEmpty = "catalog_empty"
  case modelNotFound = "model_not_found"
  case authenticationFailed = "authentication_failed"
  case httpFailure = "http_failure"
  case credentialUnavailable = "credential_unavailable"
  case invalidConfiguration = "invalid_configuration"
  case transportFailure = "transport_failure"
  case responseTooLarge = "response_too_large"
  case invalidResponse = "invalid_response"
}

/// Result of a read-only model-catalog probe. No generation request is made.
public struct AIProviderConnectionTestResult: Codable, Equatable, Sendable {
  public let status: AIProviderConnectionTestStatus
  public let code: AIProviderConnectionTestCode
  public let testedAt: Date
  public let httpStatusCode: Int?
  public let availableModelCount: Int?

  public init(
    status: AIProviderConnectionTestStatus,
    code: AIProviderConnectionTestCode,
    testedAt: Date = Date(),
    httpStatusCode: Int? = nil,
    availableModelCount: Int? = nil
  ) {
    self.status = status
    self.code = code
    self.testedAt = testedAt
    self.httpStatusCode = httpStatusCode
    self.availableModelCount = availableModelCount
  }
}

public struct AIProviderConnectionTester: Sendable {
  public static let maximumCatalogResponseBytes = 2 * 1_024 * 1_024

  private let credentialStore: any AICredentialStoring
  private let transport: any AIHTTPTransporting

  public init(
    credentialStore: any AICredentialStoring = FileConfigurationCenterStore(),
    transport: any AIHTTPTransporting = URLSessionAIHTTPTransport(
      maximumResponseBytes: AIProviderConnectionTester.maximumCatalogResponseBytes
    )
  ) {
    self.credentialStore = credentialStore
    self.transport = transport
  }

  public func test(
    _ configuration: AIProviderConfiguration,
    now: Date = Date()
  ) async -> AIProviderConnectionTestResult {
    let catalogURL: URL
    do {
      catalogURL = try configuration.modelCatalogURL()
    } catch {
      return result(.failure, .invalidConfiguration, now: now)
    }

    let apiKey: String
    do {
      apiKey = try credentialStore.apiKey(for: configuration)
    } catch {
      return result(.failure, .credentialUnavailable, now: now)
    }

    var request = URLRequest(
      url: catalogURL,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: min(configuration.timeoutSeconds, 30)
    )
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    switch configuration.kind {
    case .openAIResponses, .openAIChatCompletions, .openAICompatibleChatCompletions:
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    case .anthropicMessages:
      request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }

    let response: AIHTTPResponse
    do {
      response = try await transport.send(request)
    } catch let error as AITransportError where error.kind == .responseTooLarge {
      return result(.failure, .responseTooLarge, now: now)
    } catch {
      return result(.failure, .transportFailure, now: now)
    }

    if response.statusCode == 401 || response.statusCode == 403 {
      return result(
        .failure,
        .authenticationFailed,
        now: now,
        httpStatusCode: response.statusCode
      )
    }
    if [404, 405, 501].contains(response.statusCode) {
      return result(
        .warning,
        .catalogUnavailable,
        now: now,
        httpStatusCode: response.statusCode
      )
    }
    guard (200..<300).contains(response.statusCode) else {
      return result(
        .failure,
        .httpFailure,
        now: now,
        httpStatusCode: response.statusCode
      )
    }
    guard response.data.count <= Self.maximumCatalogResponseBytes else {
      return result(.failure, .responseTooLarge, now: now)
    }

    guard let modelIDs = Self.modelIDs(from: response.data) else {
      return result(
        .warning,
        .invalidResponse,
        now: now,
        httpStatusCode: response.statusCode
      )
    }
    guard !modelIDs.isEmpty else {
      return result(
        .warning,
        .catalogEmpty,
        now: now,
        httpStatusCode: response.statusCode,
        availableModelCount: 0
      )
    }
    let configuredModel = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard modelIDs.contains(where: {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
        .caseInsensitiveCompare(configuredModel) == .orderedSame
    }) else {
      return result(
        .failure,
        .modelNotFound,
        now: now,
        httpStatusCode: response.statusCode,
        availableModelCount: modelIDs.count
      )
    }
    return result(
      .success,
      .catalogVerified,
      now: now,
      httpStatusCode: response.statusCode,
      availableModelCount: modelIDs.count
    )
  }

  private static func modelIDs(from data: Data) -> [String]? {
    guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
    let entries: [Any]
    if let object = json as? [String: Any] {
      if let dataEntries = object["data"] as? [Any] {
        entries = dataEntries
      } else if let modelEntries = object["models"] as? [Any] {
        entries = modelEntries
      } else {
        return []
      }
    } else if let array = json as? [Any] {
      entries = array
    } else {
      return nil
    }

    var seen = Set<String>()
    return entries.compactMap { entry in
      let identifier: String?
      if let value = entry as? String {
        identifier = value
      } else if let object = entry as? [String: Any] {
        identifier = (object["id"] as? String)
          ?? (object["name"] as? String)
          ?? (object["model"] as? String)
      } else {
        identifier = nil
      }
      guard let identifier else { return nil }
      let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
      return trimmed
    }
  }

  private func result(
    _ status: AIProviderConnectionTestStatus,
    _ code: AIProviderConnectionTestCode,
    now: Date,
    httpStatusCode: Int? = nil,
    availableModelCount: Int? = nil
  ) -> AIProviderConnectionTestResult {
    AIProviderConnectionTestResult(
      status: status,
      code: code,
      testedAt: now,
      httpStatusCode: httpStatusCode,
      availableModelCount: availableModelCount
    )
  }
}
