import Foundation

public struct AIHTTPResponse: Sendable {
  public let statusCode: Int
  public let headers: [String: String]
  public let data: Data

  public init(statusCode: Int, headers: [String: String], data: Data) {
    self.statusCode = statusCode
    self.headers = headers
    self.data = data
  }

  public func header(named name: String) -> String? {
    headers[name.lowercased()]
  }
}

public enum AITransportFailureKind: String, Codable, Equatable, Sendable {
  case timedOut = "timed_out"
  case connectivity
  case cancelled
  case responseTooLarge = "response_too_large"
  case invalidResponse = "invalid_response"
  case other
}

public struct AITransportError: Error, Equatable, Sendable {
  public let kind: AITransportFailureKind
  public let systemCode: Int?
  public let isRetryable: Bool

  public init(kind: AITransportFailureKind, systemCode: Int? = nil, isRetryable: Bool) {
    self.kind = kind
    self.systemCode = systemCode
    self.isRetryable = isRetryable
  }
}

public protocol AIHTTPTransporting: Sendable {
  func send(_ request: URLRequest) async throws -> AIHTTPResponse
}

public final class URLSessionAIHTTPTransport: AIHTTPTransporting, @unchecked Sendable {
  public static let defaultMaximumResponseBytes = 8 * 1_024 * 1_024

  public let session: URLSession
  public let maximumResponseBytes: Int

  public init(maximumResponseBytes: Int = URLSessionAIHTTPTransport.defaultMaximumResponseBytes) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.waitsForConnectivity = false
    session = URLSession(
      configuration: configuration,
      delegate: AIRejectRedirectDelegate(),
      delegateQueue: nil
    )
    self.maximumResponseBytes = maximumResponseBytes
  }

  public init(
    session: URLSession,
    maximumResponseBytes: Int = URLSessionAIHTTPTransport.defaultMaximumResponseBytes
  ) {
    self.session = session
    self.maximumResponseBytes = maximumResponseBytes
  }

  public func send(_ request: URLRequest) async throws -> AIHTTPResponse {
    do {
      let (bytes, response) = try await session.bytes(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        throw AITransportError(kind: .invalidResponse, isRetryable: false)
      }
      if httpResponse.expectedContentLength > Int64(maximumResponseBytes) {
        throw AITransportError(kind: .responseTooLarge, isRetryable: false)
      }
      var data = Data()
      if httpResponse.expectedContentLength > 0 {
        data.reserveCapacity(min(Int(httpResponse.expectedContentLength), maximumResponseBytes))
      }
      for try await byte in bytes {
        guard data.count < maximumResponseBytes else {
          throw AITransportError(kind: .responseTooLarge, isRetryable: false)
        }
        data.append(byte)
      }
      var headers: [String: String] = [:]
      for (key, value) in httpResponse.allHeaderFields {
        guard let key = key as? String else { continue }
        headers[key.lowercased()] = String(describing: value)
      }
      return AIHTTPResponse(
        statusCode: httpResponse.statusCode,
        headers: headers,
        data: data
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as AITransportError {
      throw error
    } catch let error as URLError {
      if error.code == .cancelled, Task.isCancelled {
        throw CancellationError()
      }
      throw Self.map(error)
    } catch {
      throw AITransportError(kind: .other, isRetryable: false)
    }
  }

  private static func map(_ error: URLError) -> AITransportError {
    switch error.code {
    case .cancelled:
      return AITransportError(
        kind: .cancelled,
        systemCode: error.errorCode,
        isRetryable: false
      )
    case .timedOut:
      return AITransportError(
        kind: .timedOut,
        systemCode: error.errorCode,
        isRetryable: true
      )
    case .cannotFindHost,
         .cannotConnectToHost,
         .dnsLookupFailed,
         .networkConnectionLost,
         .notConnectedToInternet,
         .internationalRoamingOff,
         .callIsActive,
         .dataNotAllowed:
      return AITransportError(
        kind: .connectivity,
        systemCode: error.errorCode,
        isRetryable: true
      )
    default:
      return AITransportError(
        kind: .other,
        systemCode: error.errorCode,
        isRetryable: false
      )
    }
  }
}

private final class AIRejectRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
