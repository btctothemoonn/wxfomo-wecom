import Darwin
import Foundation

public enum GMGNChain: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
  case sol
  case eth
  case base
  case bsc
  case robinhood

  public var id: String { rawValue }

  public var localizedTitle: String {
    switch self {
    case .sol: return "Solana"
    case .eth: return "Ethereum"
    case .base: return "Base"
    case .bsc: return "BSC"
    case .robinhood: return "Robinhood"
    }
  }

  public var addressFamily: CryptoAddressFamily {
    self == .sol ? .solana : .evm
  }

  public var cryptoAddressNetwork: CryptoAddressNetwork {
    switch self {
    case .sol: return .solana
    case .eth: return .ethereum
    case .base: return .base
    case .bsc: return .bsc
    case .robinhood: return .robinhood
    }
  }
}

/// GMGN's market rank endpoint currently exposes 1h and 6h windows.
/// Keep the API's actual interval visible to callers instead of presenting 6h as 5h.
public enum GMGNMarketInterval: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
  case oneHour = "1h"
  case sixHours = "6h"

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .oneHour: return "1h"
    case .sixHours: return "6h 参考"
    }
  }
}

/// Sort keys accepted by `gmgn-cli market trending`.
/// `default` is GMGN's own hot-ranking algorithm and should remain the
/// workspace default; it is not equivalent to price change.
public enum GMGNMarketOrderBy: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
  case `default`
  case swaps
  case marketCap = "marketcap"
  case historyHighestMarketCap = "history_highest_market_cap"
  case liquidity
  case volume
  case holderCount = "holder_count"
  case smartDegenCount = "smart_degen_count"
  case renownedCount = "renowned_count"
  case gasFee = "gas_fee"
  case price
  case change1m
  case change5m
  case change1h
  case creationTimestamp = "creation_timestamp"

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .default: return "热门"
    case .swaps: return "交易笔数"
    case .marketCap: return "市值"
    case .historyHighestMarketCap: return "历史最高市值"
    case .liquidity: return "流动性"
    case .volume: return "成交量"
    case .holderCount: return "持有人"
    case .smartDegenCount: return "Smart Money"
    case .renownedCount: return "KOL"
    case .gasFee: return "Gas"
    case .price: return "价格"
    case .change1m: return "1m 涨跌幅"
    case .change5m: return "5m 涨跌幅"
    case .change1h: return "1h 涨跌幅"
    case .creationTimestamp: return "最新上线"
    }
  }
}

public enum GMGNMarketDirection: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
  case descending = "desc"
  case ascending = "asc"

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .descending: return "降序"
    case .ascending: return "升序"
    }
  }

  public var symbol: String {
    switch self {
    case .descending: return "arrow.down"
    case .ascending: return "arrow.up"
    }
  }

  public mutating func toggle() {
    self = self == .descending ? .ascending : .descending
  }
}

public struct GMGNTrendingToken: Codable, Equatable, Identifiable, Sendable {
  public let chain: GMGNChain
  public let address: String
  public let name: String
  public let symbol: String
  public let logoURL: String?
  public let priceUSD: Double?
  public let marketCapUSD: Double?
  public let liquidityUSD: Double?
  public let volumeUSD: Double?
  public let priceChangePercent: Double?
  public let priceChange1mPercent: Double?
  public let priceChange5mPercent: Double?
  public let holderCount: Int?
  public let swapCount: Int?
  public let smartWalletCount: Int?
  public let renownedWalletCount: Int?
  public let rugRatio: Double?
  public let isHoneypot: Bool?
  public let launchpadPlatform: String?
  public let rank: Int
  public let interval: GMGNMarketInterval

  public var id: String { "\(chain.rawValue):\(address):\(interval.rawValue)" }

  public init(
    chain: GMGNChain,
    address: String,
    name: String,
    symbol: String,
    logoURL: String?,
    priceUSD: Double?,
    marketCapUSD: Double?,
    liquidityUSD: Double?,
    volumeUSD: Double?,
    priceChangePercent: Double?,
    priceChange1mPercent: Double?,
    priceChange5mPercent: Double?,
    holderCount: Int?,
    swapCount: Int?,
    smartWalletCount: Int?,
    renownedWalletCount: Int?,
    rugRatio: Double?,
    isHoneypot: Bool?,
    launchpadPlatform: String?,
    rank: Int,
    interval: GMGNMarketInterval
  ) {
    self.chain = chain
    self.address = address
    self.name = name
    self.symbol = symbol
    self.logoURL = logoURL
    self.priceUSD = priceUSD
    self.marketCapUSD = marketCapUSD
    self.liquidityUSD = liquidityUSD
    self.volumeUSD = volumeUSD
    self.priceChangePercent = priceChangePercent
    self.priceChange1mPercent = priceChange1mPercent
    self.priceChange5mPercent = priceChange5mPercent
    self.holderCount = holderCount
    self.swapCount = swapCount
    self.smartWalletCount = smartWalletCount
    self.renownedWalletCount = renownedWalletCount
    self.rugRatio = rugRatio
    self.isHoneypot = isHoneypot
    self.launchpadPlatform = launchpadPlatform
    self.rank = rank
    self.interval = interval
  }
}

public struct GMGNTokenSnapshot: Codable, Equatable, Sendable {
  public let chain: GMGNChain
  public let address: String
  public let symbol: String
  public let name: String
  public let priceUSD: Double?
  public let marketCapUSD: Double?
  public let liquidityUSD: Double?
  public let volume1hUSD: Double?
  public let priceChange1hPercent: Double?
  public let holderCount: Int?
  public let smartWalletCount: Int?
  public let renownedWalletCount: Int?
  public let logoURL: String?
  public let website: String?
  public let twitterUsername: String?
  public let gmgnURL: String?
  public let geckoTerminalURL: String?
  public let decimals: Int?

  public init(
    chain: GMGNChain,
    address: String,
    symbol: String,
    name: String,
    priceUSD: Double?,
    marketCapUSD: Double?,
    liquidityUSD: Double?,
    volume1hUSD: Double?,
    priceChange1hPercent: Double?,
    holderCount: Int?,
    smartWalletCount: Int?,
    renownedWalletCount: Int?,
    logoURL: String?,
    website: String?,
    twitterUsername: String?,
    gmgnURL: String?,
    geckoTerminalURL: String?,
    decimals: Int? = nil
  ) {
    self.chain = chain
    self.address = address
    self.symbol = symbol
    self.name = name
    self.priceUSD = priceUSD
    self.marketCapUSD = marketCapUSD
    self.liquidityUSD = liquidityUSD
    self.volume1hUSD = volume1hUSD
    self.priceChange1hPercent = priceChange1hPercent
    self.holderCount = holderCount
    self.smartWalletCount = smartWalletCount
    self.renownedWalletCount = renownedWalletCount
    self.logoURL = logoURL
    self.website = website
    self.twitterUsername = twitterUsername
    self.gmgnURL = gmgnURL
    self.geckoTerminalURL = geckoTerminalURL
    self.decimals = decimals
  }
}

public struct GMGNTokenSecuritySnapshot: Codable, Equatable, Sendable {
  public let openSource: String?
  public let ownerRenounced: String?
  public let isHoneypot: String?
  public let mintRenounced: Bool?
  public let freezeRenounced: Bool?
  public let rugRatio: Double?
  public let top10HolderRate: Double?
  public let devTeamHoldRate: Double?
  public let suspectedInsiderHoldRate: Double?
  public let washTrading: Bool?
  public let buyTax: Double?
  public let sellTax: Double?

  public init(
    openSource: String?,
    ownerRenounced: String?,
    isHoneypot: String?,
    mintRenounced: Bool?,
    freezeRenounced: Bool?,
    rugRatio: Double?,
    top10HolderRate: Double?,
    devTeamHoldRate: Double?,
    suspectedInsiderHoldRate: Double?,
    washTrading: Bool?,
    buyTax: Double?,
    sellTax: Double?
  ) {
    self.openSource = openSource
    self.ownerRenounced = ownerRenounced
    self.isHoneypot = isHoneypot
    self.mintRenounced = mintRenounced
    self.freezeRenounced = freezeRenounced
    self.rugRatio = rugRatio
    self.top10HolderRate = top10HolderRate
    self.devTeamHoldRate = devTeamHoldRate
    self.suspectedInsiderHoldRate = suspectedInsiderHoldRate
    self.washTrading = washTrading
    self.buyTax = buyTax
    self.sellTax = sellTax
  }
}

public struct GMGNTokenReport: Codable, Equatable, Identifiable, Sendable {
  public let token: GMGNTokenSnapshot
  public let security: GMGNTokenSecuritySnapshot?
  public let securityError: String?
  public let fetchedAt: Date
  public let isCached: Bool
  public let marketDataSource: CAMarketDataSource

  public var id: String { "\(token.chain.rawValue):\(token.address)" }

  public init(
    token: GMGNTokenSnapshot,
    security: GMGNTokenSecuritySnapshot?,
    securityError: String?,
    fetchedAt: Date,
    isCached: Bool,
    marketDataSource: CAMarketDataSource = .gmgn
  ) {
    self.token = token
    self.security = security
    self.securityError = securityError
    self.fetchedAt = fetchedAt
    self.isCached = isCached
    self.marketDataSource = marketDataSource
  }
}

public enum GMGNCLIError: LocalizedError, Equatable, Sendable {
  case executableUnavailable
  case notConfigured
  case invalidAddress(chain: GMGNChain)
  case tokenUnavailable(chain: GMGNChain)
  case timedOut
  case rateLimited(retryAt: Date?)
  case trustedIPRejected
  case authenticationFailed
  case networkUnavailable(String)
  case submissionUncertain(String)
  case commandFailed(String)
  case invalidResponse

  public var errorDescription: String? {
    switch self {
    case .executableUnavailable:
      return "未找到 gmgn-cli。请先安装 gmgn-cli，或确认 NVM 目录可访问。"
    case .notConfigured:
      return "gmgn-cli 尚未配置 API Key。请先在终端完成 gmgn-cli config。"
    case .invalidAddress(let chain):
      return "地址格式与 \(chain.localizedTitle) 不匹配。"
    case .tokenUnavailable(let chain):
      return "GMGN 没有返回该地址在 \(chain.localizedTitle) 的有效代币数据。"
    case .timedOut:
      return "GMGN 查询超过 20 秒，已停止。"
    case .rateLimited(let retryAt):
      if let retryAt {
        return "GMGN 请求已限流，可在 \(retryAt.formatted(date: .omitted, time: .standard)) 后重试。"
      }
      return "GMGN 请求已限流，请稍后重试。"
    case .trustedIPRejected:
      return "当前 IPv4 出口未加入 GMGN API Key 的可信 IP，请在 GMGN API 管理中添加后重试。"
    case .authenticationFailed:
      return "GMGN 鉴权失败，请检查 API Key、签名公钥和绑定钱包配置。"
    case .networkUnavailable(let message):
      let upper = message.uppercased()
      if upper.contains("TIMEOUT") || upper.contains("TIMED OUT")
        || upper.contains("ETIMEDOUT")
      {
        return "GMGN 连接超时，请稍后重试。"
      }
      return "无法连接 GMGN，请检查网络或代理路由后重试。"
    case .submissionUncertain(let message):
      return message.isEmpty
        ? "交易提交结果暂时无法确认，请先核对订单记录，避免重复交易。"
        : "交易提交结果暂时无法确认：\(message)。请先核对订单记录，避免重复交易。"
    case .commandFailed(let message):
      return message
    case .invalidResponse:
      return "GMGN 返回了无法解析的数据。"
    }
  }
}

public actor GMGNCLIClient {
  public static let cacheTTL: TimeInterval = 45
  public static let chainIdentificationCacheTTL: TimeInterval = 120
  public static let timeout: TimeInterval = 20

  private struct CacheEntry: Sendable {
    let report: GMGNTokenReport
    let storedAt: Date
  }

  private struct TokenCacheEntry: Sendable {
    let token: GMGNTokenSnapshot
    let storedAt: Date
  }

  private struct ChainIdentificationCacheEntry: Sendable {
    let tokens: [GMGNTokenSnapshot]
    let storedAt: Date
  }

  private struct TrendingCacheEntry: Sendable {
    let tokens: [GMGNTrendingToken]
    let storedAt: Date
  }

  private enum TokenProbeOutcome: Sendable {
    case found(GMGNTokenSnapshot)
    case failed(GMGNChain, GMGNCLIError)
  }

  private var cache: [String: CacheEntry] = [:]
  private var tokenCache: [String: TokenCacheEntry] = [:]
  private var chainIdentificationCache: [String: ChainIdentificationCacheEntry] = [:]
  private var trendingCache: [String: TrendingCacheEntry] = [:]
  private var inFlightChainIdentifications: [String: Task<[GMGNTokenSnapshot], Error>] = [:]
  private var inFlightTokenReports: [String: Task<GMGNTokenReport, Error>] = [:]
  private var configurationChecked = false
  private var configurationCheckTask: Task<Void, Error>?
  private var rateLimitedUntil: Date?
  private let executableOverride: URL?

  public init(executableURL: URL? = nil) {
    executableOverride = executableURL
  }

  public func identifyEVMToken(
    address rawAddress: String,
    now: Date = Date()
  ) async throws -> [GMGNTokenSnapshot] {
    let address = try Self.validatedAddress(rawAddress, chain: .eth)
    if let cached = chainIdentificationCache[address],
      now.timeIntervalSince(cached.storedAt) < Self.chainIdentificationCacheTTL
    {
      return cached.tokens
    }
    if let inFlight = inFlightChainIdentifications[address] {
      return try await inFlight.value
    }

    let task = Task { try await probeEVMToken(address: address, now: now) }
    inFlightChainIdentifications[address] = task
    do {
      let tokens = try await task.value
      inFlightChainIdentifications[address] = nil
      chainIdentificationCache[address] = ChainIdentificationCacheEntry(
        tokens: tokens,
        storedAt: now
      )
      if chainIdentificationCache.count > 200,
        let oldest = chainIdentificationCache.min(by: {
          $0.value.storedAt < $1.value.storedAt
        })?.key
      {
        chainIdentificationCache.removeValue(forKey: oldest)
      }
      return tokens
    } catch {
      inFlightChainIdentifications[address] = nil
      throw error
    }
  }

  public func tokenSnapshot(
    chain: GMGNChain,
    address: String,
    now: Date = Date()
  ) async throws -> GMGNTokenSnapshot {
    let address = try Self.validatedAddress(address, chain: chain)
    let cacheKey = "\(chain.rawValue):\(address)"
    if let cached = tokenCache[cacheKey],
      now.timeIntervalSince(cached.storedAt) < Self.cacheTTL
    {
      return cached.token
    }
    if let cached = cache[cacheKey],
      now.timeIntervalSince(cached.storedAt) < Self.cacheTTL
    {
      return cached.report.token
    }
    if let rateLimitedUntil, now < rateLimitedUntil {
      throw GMGNCLIError.rateLimited(retryAt: rateLimitedUntil)
    }
    rateLimitedUntil = nil

    let executable = try executableOverride ?? Self.locateExecutable()
    try await ensureConfigured(executable: executable)

    let infoOutput = try await Self.run(
      executable: executable,
      arguments: ["token", "info", "--chain", chain.rawValue, "--address", address, "--raw"]
    )
    guard infoOutput.status == 0 else {
      let error = Self.commandError(stderr: infoOutput.stderr, stdout: infoOutput.stdout)
      rememberRateLimit(from: error, now: now)
      throw error
    }
    let token = try Self.parseToken(
      Self.jsonObject(from: infoOutput.stdout),
      chain: chain,
      fallbackAddress: address
    )
    guard Self.hasIdentityEvidence(token) else {
      throw GMGNCLIError.tokenUnavailable(chain: chain)
    }
    tokenCache[cacheKey] = TokenCacheEntry(token: token, storedAt: now)
    if tokenCache.count > 200,
      let oldest = tokenCache.min(by: { $0.value.storedAt < $1.value.storedAt })?.key
    {
      tokenCache.removeValue(forKey: oldest)
    }
    return token
  }

  public func trendingTokens(
    chain: GMGNChain,
    interval: GMGNMarketInterval,
    orderBy: GMGNMarketOrderBy = .default,
    direction: GMGNMarketDirection = .descending,
    limit: Int = 10,
    now: Date = Date(),
    forceRefresh: Bool = false
  ) async throws -> [GMGNTrendingToken] {
    let boundedLimit = min(max(limit, 1), 100)
    let cacheKey = "\(chain.rawValue):\(interval.rawValue):\(orderBy.rawValue):\(direction.rawValue):\(boundedLimit)"
    if !forceRefresh,
      let cached = trendingCache[cacheKey],
      now.timeIntervalSince(cached.storedAt) < Self.cacheTTL
    {
      return cached.tokens
    }
    if let rateLimitedUntil, now < rateLimitedUntil {
      throw GMGNCLIError.rateLimited(retryAt: rateLimitedUntil)
    }
    rateLimitedUntil = nil

    let executable = try executableOverride ?? Self.locateExecutable()
    try await ensureConfigured(executable: executable)

    let output = try await Self.run(
      executable: executable,
      arguments: [
        "market", "trending",
        "--chain", chain.rawValue,
        "--interval", interval.rawValue,
        "--order-by", orderBy.rawValue,
        "--direction", direction.rawValue,
        "--limit", String(boundedLimit),
        "--raw",
      ]
    )
    guard output.status == 0 else {
      let error = Self.commandError(stderr: output.stderr, stdout: output.stdout)
      rememberRateLimit(from: error, now: now)
      throw error
    }
    let tokens = try Self.parseTrending(
      Self.jsonObject(from: output.stdout),
      chain: chain,
      interval: interval
    )
    trendingCache[cacheKey] = TrendingCacheEntry(tokens: tokens, storedAt: now)
    if trendingCache.count > 40,
      let oldest = trendingCache.min(by: { $0.value.storedAt < $1.value.storedAt })?.key
    {
      trendingCache.removeValue(forKey: oldest)
    }
    return tokens
  }

  private func probeEVMToken(
    address: String,
    now: Date
  ) async throws -> [GMGNTokenSnapshot] {
    if let rateLimitedUntil, now < rateLimitedUntil {
      throw GMGNCLIError.rateLimited(retryAt: rateLimitedUntil)
    }
    rateLimitedUntil = nil

    let executable = try executableOverride ?? Self.locateExecutable()
    try await ensureConfigured(executable: executable)

    var tokens: [GMGNTokenSnapshot] = []
    var chainsToProbe: [GMGNChain] = []
    for chain in Self.evmIdentificationChains {
      let cacheKey = "\(chain.rawValue):\(address)"
      if let cached = tokenCache[cacheKey],
        now.timeIntervalSince(cached.storedAt) < Self.cacheTTL
      {
        tokens.append(cached.token)
      } else {
        chainsToProbe.append(chain)
      }
    }

    var firstFailure: GMGNCLIError?
    await withTaskGroup(of: TokenProbeOutcome.self) { group in
      for chain in chainsToProbe {
        group.addTask {
          do {
            return .found(
              try await Self.fetchTokenSnapshot(
                executable: executable,
                chain: chain,
                address: address
              )
            )
          } catch let error as GMGNCLIError {
            return .failed(chain, error)
          } catch {
            return .failed(chain, .invalidResponse)
          }
        }
      }

      for await outcome in group {
        switch outcome {
        case .found(let token):
          tokens.append(token)
        case .failed(_, .tokenUnavailable):
          break
        case .failed(_, let error):
          if firstFailure == nil { firstFailure = error }
        }
      }
    }

    if tokens.isEmpty, let firstFailure {
      rememberRateLimit(from: firstFailure, now: now)
      throw firstFailure
    }
    for token in tokens {
      tokenCache["\(token.chain.rawValue):\(token.address)"] = TokenCacheEntry(
        token: token,
        storedAt: now
      )
    }
    return tokens.sorted { lhs, rhs in
      let left = Self.evmIdentificationChains.firstIndex(of: lhs.chain) ?? .max
      let right = Self.evmIdentificationChains.firstIndex(of: rhs.chain) ?? .max
      return left < right
    }
  }

  public func tokenReport(
    chain: GMGNChain,
    address: String,
    now: Date = Date(),
    forceRefresh: Bool = false
  ) async throws -> GMGNTokenReport {
    let address = try Self.validatedAddress(address, chain: chain)
    let cacheKey = "\(chain.rawValue):\(address)"
    if !forceRefresh,
      let cached = cache[cacheKey],
      now.timeIntervalSince(cached.storedAt) < Self.cacheTTL
    {
      return GMGNTokenReport(
        token: cached.report.token,
        security: cached.report.security,
        securityError: cached.report.securityError,
        fetchedAt: cached.report.fetchedAt,
        isCached: true
      )
    }
    if let inFlight = inFlightTokenReports[cacheKey] {
      return try await inFlight.value
    }

    let executable = try executableOverride ?? Self.locateExecutable()
    let task = Task {
      try await ensureConfigured(executable: executable)
      return try await fetchFreshTokenReport(
        executable: executable,
        chain: chain,
        address: address,
        now: now
      )
    }
    inFlightTokenReports[cacheKey] = task
    let report: GMGNTokenReport
    do {
      report = try await task.value
      inFlightTokenReports[cacheKey] = nil
    } catch {
      inFlightTokenReports[cacheKey] = nil
      throw error
    }

    cache[cacheKey] = CacheEntry(report: report, storedAt: now)
    if cache.count > 200, let oldest = cache.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
      cache.removeValue(forKey: oldest)
    }
    return report
  }

  private func ensureConfigured(executable: URL) async throws {
    if configurationChecked { return }
    if let configurationCheckTask {
      try await configurationCheckTask.value
      return
    }

    let task = Task<Void, Error> {
      let output = try await Self.run(
        executable: executable,
        arguments: ["config", "--check"]
      )
      guard output.status == 0 else { throw GMGNCLIError.notConfigured }
    }
    configurationCheckTask = task
    do {
      try await task.value
      configurationChecked = true
      configurationCheckTask = nil
    } catch {
      configurationCheckTask = nil
      throw error
    }
  }

  private func fetchFreshTokenReport(
    executable: URL,
    chain: GMGNChain,
    address: String,
    now: Date
  ) async throws -> GMGNTokenReport {
    async let tokenRequest = tokenSnapshot(chain: chain, address: address, now: now)
    async let securityRequest = Self.run(
      executable: executable,
      arguments: [
        "token", "security", "--chain", chain.rawValue,
        "--address", address, "--raw",
      ]
    )
    let token = try await tokenRequest

    let security: GMGNTokenSecuritySnapshot?
    let securityError: String?
    do {
      let securityOutput = try await securityRequest
      guard securityOutput.status == 0 else {
        let error = Self.commandError(stderr: securityOutput.stderr, stdout: securityOutput.stdout)
        rememberRateLimit(from: error, now: now)
        throw error
      }
      security = Self.parseSecurity(
        try Self.jsonObject(from: securityOutput.stdout),
        chain: chain
      )
      securityError = nil
    } catch {
      security = nil
      securityError = Self.sanitizedError(error.localizedDescription)
    }

    return GMGNTokenReport(
      token: token,
      security: security,
      securityError: securityError,
      fetchedAt: now,
      isCached: false
    )
  }
}

private extension GMGNCLIClient {
  static let evmIdentificationChains: [GMGNChain] = [.base, .bsc, .eth, .robinhood]

  struct ProcessOutput: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
  }

  static func validatedAddress(_ value: String, chain: GMGNChain) throws -> String {
    let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let valid: Bool
    if chain == .sol {
      valid = CryptoAddressDetector.matches(in: "CA \(address)").contains {
        $0.family == .solana && $0.address == address
      }
    } else {
      valid = address.count == 42
        && address.lowercased().hasPrefix("0x")
        && address.dropFirst(2).allSatisfy { $0.isHexDigit }
    }
    guard valid else { throw GMGNCLIError.invalidAddress(chain: chain) }
    return chain == .sol ? address : address.lowercased()
  }

  static func fetchTokenSnapshot(
    executable: URL,
    chain: GMGNChain,
    address: String
  ) async throws -> GMGNTokenSnapshot {
    let output = try await run(
      executable: executable,
      arguments: ["token", "info", "--chain", chain.rawValue, "--address", address, "--raw"]
    )
    guard output.status == 0 else {
      throw commandError(stderr: output.stderr, stdout: output.stdout)
    }
    let root: [String: Any]
    do {
      root = try jsonObject(from: output.stdout)
    } catch {
      throw GMGNCLIError.invalidResponse
    }
    let token = try parseToken(root, chain: chain, fallbackAddress: address)
    guard hasIdentityEvidence(token) else {
      throw GMGNCLIError.tokenUnavailable(chain: chain)
    }
    return token
  }

  static func hasIdentityEvidence(_ token: GMGNTokenSnapshot) -> Bool {
    !token.symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !token.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || (token.priceUSD ?? 0) > 0
      || (token.marketCapUSD ?? 0) > 0
      || (token.liquidityUSD ?? 0) > 0
      || (token.holderCount ?? 0) > 0
  }

  static func locateExecutable() throws -> URL {
    let fileManager = FileManager.default
    let environment = ProcessInfo.processInfo.environment
    let pathDirectories = (environment["PATH"] ?? "")
      .split(separator: ":")
      .map(String.init)
    let home = fileManager.homeDirectoryForCurrentUser
    var candidates = pathDirectories.map {
      URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("gmgn-cli")
    }
    candidates.append(home.appendingPathComponent(".local/bin/gmgn-cli"))
    candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/gmgn-cli"))
    candidates.append(URL(fileURLWithPath: "/usr/local/bin/gmgn-cli"))

    let nvmVersions = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
    if let versions = try? fileManager.contentsOfDirectory(
      at: nvmVersions,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) {
      candidates.append(contentsOf: versions.sorted { $0.lastPathComponent > $1.lastPathComponent }.map {
        $0.appendingPathComponent("bin/gmgn-cli")
      })
    }
    guard let executable = candidates.first(where: {
      fileManager.isExecutableFile(atPath: $0.path)
    }) else {
      throw GMGNCLIError.executableUnavailable
    }
    return executable
  }

  static func run(executable: URL, arguments: [String]) async throws -> ProcessOutput {
    try await Task.detached(priority: .utility) {
      try runBlocking(executable: executable, arguments: arguments)
    }.value
  }

  static func runBlocking(executable: URL, arguments: [String]) throws -> ProcessOutput {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("wxfomo-gmgn-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? fileManager.removeItem(at: temporaryDirectory) }
    let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
    let stderrURL = temporaryDirectory.appendingPathComponent("stderr")
    guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
      fileManager.createFile(atPath: stderrURL.path, contents: nil)
    else {
      throw GMGNCLIError.commandFailed("无法创建 GMGN 临时输出文件。")
    }
    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)
    defer {
      try? stdoutHandle.close()
      try? stderrHandle.close()
    }

    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    // GMGN authentication must remain owned by gmgn-cli's explicit configuration.
    // Do not leak API keys, private keys, wallet material, or other credentials
    // from the parent app environment into the child process.
    process.environment = GMGNCLIProcessEnvironment.make(executable: executable)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle
    do {
      try process.run()
    } catch {
      throw GMGNCLIError.executableUnavailable
    }

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
      process.terminate()
      let terminationDeadline = Date().addingTimeInterval(0.5)
      while process.isRunning, Date() < terminationDeadline {
        Thread.sleep(forTimeInterval: 0.02)
      }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      throw GMGNCLIError.timedOut
    }
    process.waitUntilExit()
    try? stdoutHandle.synchronize()
    try? stderrHandle.synchronize()
    let outputLimit = 4 * 1_024 * 1_024
    let stdout = try limitedData(contentsOf: stdoutURL, limit: outputLimit)
    let stderr = try limitedData(contentsOf: stderrURL, limit: 64 * 1_024)
    return ProcessOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr)
  }

  static func limitedData(contentsOf url: URL, limit: Int) throws -> Data {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    guard size <= limit else {
      throw GMGNCLIError.commandFailed("GMGN 返回数据超过本地限制。")
    }
    return try Data(contentsOf: url)
  }

  static func commandError(stderr: Data, stdout: Data) -> GMGNCLIError {
    let source = stderr.isEmpty ? stdout : stderr
    let message = sanitizedError(String(decoding: source, as: UTF8.self))
    return GMGNCLIProcessEnvironment.commandError(message: message)
  }

  func rememberRateLimit(from error: GMGNCLIError, now: Date) {
    guard case .rateLimited(let retryAt) = error else { return }
    rateLimitedUntil = max(retryAt ?? now.addingTimeInterval(5 * 60), now.addingTimeInterval(1))
  }

  static func rateLimitResetDate(in message: String) -> Date? {
    GMGNCLIProcessEnvironment.rateLimitResetDate(in: message)
  }

  static func sanitizedError(_ value: String) -> String {
    var result = value
      .replacingOccurrences(
        of: #"GMGN_API_KEY=\S+"#,
        with: "GMGN_API_KEY=[redacted]",
        options: .regularExpression
      )
      .replacingOccurrences(
        of: #"gmgn_[A-Za-z0-9_=-]+"#,
        with: "gmgn_[redacted]",
        options: .regularExpression
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if result.count > 600 { result = String(result.prefix(600)) }
    return result.isEmpty ? "GMGN 查询失败。" : result
  }

  static func jsonObject(from data: Data) throws -> [String: Any] {
    guard !data.isEmpty else { throw GMGNCLIError.invalidResponse }
    let object = try JSONSerialization.jsonObject(with: data)
    guard let root = object as? [String: Any] else { throw GMGNCLIError.invalidResponse }
    if let wrapped = root["data"] as? [String: Any], wrapped["address"] != nil {
      return wrapped
    }
    return root
  }

  static func parseToken(
    _ root: [String: Any],
    chain: GMGNChain,
    fallbackAddress: String
  ) throws -> GMGNTokenSnapshot {
    let address = string(root["address"]) ?? fallbackAddress
    guard !address.isEmpty else { throw GMGNCLIError.invalidResponse }
    let priceObject = dictionary(root["price"])
    let stat = dictionary(root["stat"])
    let walletTags = dictionary(root["wallet_tags_stat"])
    let link = dictionary(root["link"])
    let currentPrice = number(priceObject["price"])
    let oneHourPrice = number(priceObject["price_1h"])
    let priceChange: Double?
    if let currentPrice, let oneHourPrice, oneHourPrice != 0 {
      priceChange = (currentPrice / oneHourPrice - 1) * 100
    } else {
      priceChange = nil
    }
    let supply = number(root["circulating_supply"])
    let marketCap = currentPrice.flatMap { price in
      supply.flatMap { supply in
        let value = price * supply
        return value.isFinite ? value : nil
      }
    }
    return GMGNTokenSnapshot(
      chain: chain,
      address: address,
      symbol: string(root["symbol"]) ?? "",
      name: string(root["name"]) ?? "",
      priceUSD: currentPrice,
      marketCapUSD: marketCap,
      liquidityUSD: number(root["liquidity"]),
      volume1hUSD: number(priceObject["volume_1h"]),
      priceChange1hPercent: priceChange,
      holderCount: integer(root["holder_count"] ?? stat["holder_count"]),
      smartWalletCount: integer(walletTags["smart_wallets"]),
      renownedWalletCount: integer(walletTags["renowned_wallets"]),
      logoURL: nonemptyString(root["logo"]),
      website: nonemptyString(link["website"]),
      twitterUsername: nonemptyString(link["twitter_username"]),
      gmgnURL: nonemptyString(link["gmgn"]),
      geckoTerminalURL: nonemptyString(link["geckoterminal"]),
      decimals: integer(root["decimals"] ?? root["decimal"])
    )
  }

  static func parseTrending(
    _ root: [String: Any],
    chain: GMGNChain,
    interval: GMGNMarketInterval
  ) throws -> [GMGNTrendingToken] {
    guard let data = root["data"] as? [String: Any],
      let rows = data["rank"] as? [[String: Any]]
    else {
      throw GMGNCLIError.invalidResponse
    }

    let tokens = rows.enumerated().compactMap { offset, row -> GMGNTrendingToken? in
      guard let address = nonemptyString(row["address"]) else { return nil }
      let change = number(row["price_change_percent1h"])
        ?? number(row["price_change_percent"])
      return GMGNTrendingToken(
        chain: chain,
        address: address,
        name: nonemptyString(row["name"]) ?? "",
        symbol: nonemptyString(row["symbol"]) ?? "",
        logoURL: nonemptyString(row["logo"]),
        priceUSD: number(row["price"]),
        marketCapUSD: number(row["market_cap"]),
        liquidityUSD: number(row["liquidity"]),
        volumeUSD: number(row["volume"]),
        priceChangePercent: change,
        priceChange1mPercent: number(row["price_change_percent1m"]),
        priceChange5mPercent: number(row["price_change_percent5m"]),
        holderCount: integer(row["holder_count"]),
        swapCount: integer(row["swaps"] ?? row["swap_count"]),
        smartWalletCount: integer(row["smart_degen_count"]),
        renownedWalletCount: integer(row["renowned_count"]),
        rugRatio: number(row["rug_ratio"]),
        isHoneypot: boolean(row["is_honeypot"]),
        launchpadPlatform: nonemptyString(row["launchpad_platform"]),
        rank: integer(row["rank"]) ?? offset + 1,
        interval: interval
      )
    }
    guard !tokens.isEmpty || rows.isEmpty else { throw GMGNCLIError.invalidResponse }
    // The rank endpoint has already applied the requested order. Preserve
    // that response order; sorting here by price change would corrupt market
    // cap, volume, swaps, and GMGN's default hot ranking.
    return tokens
  }

  static func parseSecurity(
    _ root: [String: Any],
    chain: GMGNChain
  ) -> GMGNTokenSecuritySnapshot {
    GMGNTokenSecuritySnapshot(
      openSource: statusString(root["open_source"] ?? root["is_open_source"]),
      ownerRenounced: statusString(
        root["owner_renounced"] ?? root["renounced"] ?? root["is_renounced"]
      ),
      isHoneypot: chain == .sol
        ? nil
        : statusString(root["is_honeypot"] ?? root["honeypot"]),
      mintRenounced: boolean(root["renounced_mint"]),
      freezeRenounced: boolean(root["renounced_freeze_account"]),
      rugRatio: number(root["rug_ratio"]),
      top10HolderRate: number(root["top_10_holder_rate"]),
      devTeamHoldRate: number(root["dev_team_hold_rate"]),
      suspectedInsiderHoldRate: number(root["suspected_insider_hold_rate"]),
      washTrading: boolean(root["is_wash_trading"]),
      buyTax: number(root["buy_tax"]),
      sellTax: number(root["sell_tax"])
    )
  }

  static func dictionary(_ value: Any?) -> [String: Any] {
    value as? [String: Any] ?? [:]
  }

  static func string(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
  }

  static func nonemptyString(_ value: Any?) -> String? {
    guard let value = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return nil }
    return value
  }

  static func statusString(_ value: Any?) -> String? {
    if let value = value as? String {
      let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard !normalized.isEmpty else { return nil }
      switch normalized {
      case "1", "true", "yes": return "yes"
      case "0", "false", "no": return "no"
      default: return normalized
      }
    }
    if let value = value as? NSNumber {
      return value.boolValue ? "yes" : "no"
    }
    return nil
  }

  static func number(_ value: Any?) -> Double? {
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
  }

  static func integer(_ value: Any?) -> Int? {
    guard let value = number(value), value.isFinite else { return nil }
    return Int(value)
  }

  static func boolean(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.intValue != 0 }
    if let value = value as? String {
      switch value.lowercased() {
      case "true", "yes", "1": return true
      case "false", "no", "0": return false
      default: return nil
      }
    }
    return nil
  }
}
