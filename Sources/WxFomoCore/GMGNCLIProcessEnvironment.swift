import Foundation

/// Shared process policy for every gmgn-cli invocation in wxFomo.
public enum GMGNCLIProcessEnvironment {
  public static func nodeOptions(merging existing: String?) -> String {
    let current = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let pattern = #"--dns-result-order(?:=|\s+)(?:ipv4first|ipv6first|verbatim)"#
    if current.range(of: pattern, options: .regularExpression) != nil {
      return current.replacingOccurrences(
        of: pattern,
        with: "--dns-result-order=ipv4first",
        options: .regularExpression
      )
    }
    return current.isEmpty
      ? "--dns-result-order=ipv4first"
      : "\(current) --dns-result-order=ipv4first"
  }
}

extension GMGNCLIProcessEnvironment {
  static func make(
    executable: URL,
    allowAutomatedTrade: Bool = false
  ) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment.filter {
      !isCredentialEnvironmentVariable($0.key)
    }
    environment["PATH"] = "\(executable.deletingLastPathComponent().path):\(environment["PATH"] ?? "/usr/bin:/bin")"
    environment["NODE_OPTIONS"] = nodeOptions(merging: environment["NODE_OPTIONS"])
    environment["GMGN_RATE_LIMIT_AUTO_RETRY_MAX_WAIT_MS"] = "1500"
    if allowAutomatedTrade {
      environment["GMGN_ALLOW_AUTOMATED_TRADES"] = "1"
    }
    return environment
  }

  static func rateLimitResetDate(in message: String) -> Date? {
    if let range = message.range(
      of: #"reset_at[\"'=: ]+(\d{10,13})"#,
      options: [.regularExpression, .caseInsensitive]
    ) {
      let digits = message[range].filter(\.isNumber)
      if let raw = Double(digits) {
        return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
      }
    }

    guard let range = message.range(
      of: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} GMT[+-]\d{2}:\d{2}"#,
      options: .regularExpression
    ) else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'GMT'XXXXX"
    return formatter.date(from: String(message[range]))
  }

  static func commandError(message: String) -> GMGNCLIError {
    let upper = message.uppercased()
    if upper.contains("HTTP 429") || upper.contains("CODE=429")
      || upper.contains("RATE_LIMIT_BANNED") || upper.contains("RATE_LIMIT_EXCEEDED")
    {
      return .rateLimited(retryAt: rateLimitResetDate(in: message))
    }
    if upper.contains("AUTH_IP_NOT_SUPPORTED") || upper.contains("IP NOT SUPPORTED") {
      return .trustedIPRejected
    }
    if upper.contains("HTTP 401") || upper.contains("HTTP 403")
      || upper.contains("INVALID_API_KEY") || upper.contains("AUTH_FAILED")
    {
      return .authenticationFailed
    }
    if isTransportFailure(message) {
      return .networkUnavailable(message)
    }
    return .commandFailed(message)
  }

  static func isTransportFailure(_ message: String) -> Bool {
    let upper = message.uppercased()
    return [
      "ETIMEDOUT", "ECONNRESET", "ECONNREFUSED", "ENETUNREACH", "EHOSTUNREACH",
      "ENOTFOUND", "SOCKET HANG UP", "NETWORK REQUEST FAILED", "FETCH FAILED",
      "CONNECTION TIMED OUT", "CONNECTION RESET", "CONNECTTIMEOUTERROR",
      "CONNECT_TIMEOUT", "UND_ERR_CONNECT_TIMEOUT",
    ].contains { upper.contains($0) }
  }

  private static func isCredentialEnvironmentVariable(_ name: String) -> Bool {
    let normalized = name.uppercased()
    let exactNames: Set<String> = [
      "API_KEY", "GMGN_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY",
      "PRIVATE_KEY", "WALLET_PRIVATE_KEY", "MNEMONIC", "SEED_PHRASE",
    ]
    return exactNames.contains(normalized)
      || normalized.hasSuffix("_API_KEY")
      || normalized.contains("PRIVATE_KEY")
      || normalized.contains("MNEMONIC")
      || normalized.contains("SEED_PHRASE")
      || normalized.hasSuffix("_SECRET")
      || normalized.hasSuffix("_TOKEN")
      || normalized.contains("PASSWORD")
      || normalized.contains("WALLET")
  }
}
