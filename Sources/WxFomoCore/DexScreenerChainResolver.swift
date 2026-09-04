import Foundation

public struct DexScreenerChainCandidate: Codable, Equatable, Identifiable, Sendable {
  public let chain: GMGNChain
  public let pairCount: Int
  public let maxLiquidityUSD: Double?
  public let maxVolume24hUSD: Double?

  public var id: String { chain.rawValue }

  public init(
    chain: GMGNChain,
    pairCount: Int,
    maxLiquidityUSD: Double?,
    maxVolume24hUSD: Double?
  ) {
    self.chain = chain
    self.pairCount = pairCount
    self.maxLiquidityUSD = maxLiquidityUSD
    self.maxVolume24hUSD = maxVolume24hUSD
  }
}

public enum DexScreenerChainResolutionSource: String, Codable, Equatable, Sendable {
  case network
  case memoryCache
  case persistentCache
}

public struct DexScreenerChainResolution: Codable, Equatable, Sendable {
  public let address: String
  public let selectedChain: GMGNChain?
  public let candidates: [DexScreenerChainCandidate]
  public let resolvedAt: Date
  public let source: DexScreenerChainResolutionSource

  public var isAmbiguous: Bool {
    selectedChain == nil && candidates.count > 1
  }

  public init(
    address: String,
    selectedChain: GMGNChain?,
    candidates: [DexScreenerChainCandidate],
    resolvedAt: Date = Date(),
    source: DexScreenerChainResolutionSource = .network
  ) {
    self.address = address
    self.selectedChain = selectedChain
    self.candidates = candidates
    self.resolvedAt = resolvedAt
    self.source = source
  }

  public func markingSource(_ source: DexScreenerChainResolutionSource) -> Self {
    Self(
      address: address,
      selectedChain: selectedChain,
      candidates: candidates,
      resolvedAt: resolvedAt,
      source: source
    )
  }
}

public enum DexScreenerChainResolverError: LocalizedError, Equatable, Sendable {
  case invalidEVMAddress
  case invalidTokenAddress
  case rateLimited
  case serviceUnavailable
  case invalidResponse
  case tokenUnavailable(chain: GMGNChain)

  public var errorDescription: String? {
    switch self {
    case .invalidEVMAddress:
      return "请输入完整的 0x 地址。"
    case .invalidTokenAddress:
      return "请输入完整的代币地址。"
    case .rateLimited:
      return "DexScreener 请求过于频繁，请稍后重试或手动选择网络。"
    case .serviceUnavailable:
      return "DexScreener 暂时不可用，可手动选择网络继续查询。"
    case .invalidResponse:
      return "DexScreener 返回了无法解析的数据，可手动选择网络继续查询。"
    case .tokenUnavailable(let chain):
      return "DexScreener 没有返回该地址在 \(chain.localizedTitle) 的基础行情。"
    }
  }
}

public actor DexScreenerChainResolver {
  public static let cacheTTL: TimeInterval = 120
  public static let persistentCacheTTL: TimeInterval = 24 * 60 * 60
  public static let timeout: TimeInterval = 8

  private struct CacheEntry: Sendable {
    let resolution: DexScreenerChainResolution
    let storedAt: Date
  }

  private struct PairCacheEntry: Sendable {
    let pairs: [Pair]
    let storedAt: Date
  }

  private struct Response: Decodable, Sendable {
    let pairs: [Pair]?
  }

  private struct Pair: Decodable, Sendable {
    let chainID: String?
    let baseToken: Token?
    let quoteToken: Token?
    let liquidity: Liquidity?
    let volume: Volume?
    let priceUSD: String?
    let priceChange: PriceChange?
    let marketCap: Double?
    let fullyDilutedValuation: Double?
    let info: Info?

    enum CodingKeys: String, CodingKey {
      case chainID = "chainId"
      case baseToken
      case quoteToken
      case liquidity
      case volume
      case priceUSD = "priceUsd"
      case priceChange
      case marketCap
      case fullyDilutedValuation = "fdv"
      case info
    }
  }

  private struct Token: Decodable, Sendable {
    let address: String?
    let name: String?
    let symbol: String?
  }

  private struct Liquidity: Decodable, Sendable {
    let usd: Double?
  }

  private struct Volume: Decodable, Sendable {
    let h24: Double?
    let h1: Double?
  }

  private struct PriceChange: Decodable, Sendable {
    let h1: Double?
  }

  private struct Info: Decodable, Sendable {
    let imageURL: String?
    let websites: [Website]?
    let socials: [Social]?

    enum CodingKeys: String, CodingKey {
      case imageURL = "imageUrl"
      case websites
      case socials
    }
  }

  private struct Website: Decodable, Sendable {
    let url: String?
  }

  private struct Social: Decodable, Sendable {
    let type: String?
    let url: String?
  }

  private struct Aggregate {
    var pairCount = 0
    var maxLiquidityUSD: Double?
    var maxVolume24hUSD: Double?
  }

  private let transport: any AIHTTPTransporting
  private var cache: [String: CacheEntry] = [:]
  private var pairCache: [String: PairCacheEntry] = [:]
  private var inFlightPairRequests: [String: Task<[Pair], Error>] = [:]

  public init(
    transport: any AIHTTPTransporting = URLSessionAIHTTPTransport(
      maximumResponseBytes: 2 * 1_024 * 1_024
    )
  ) {
    self.transport = transport
  }

  public func resolve(
    address rawAddress: String,
    now: Date = Date()
  ) async throws -> DexScreenerChainResolution {
    let address = try Self.validatedEVMAddress(rawAddress)
    if let cached = cache[address], now.timeIntervalSince(cached.storedAt) < Self.cacheTTL {
      return cached.resolution.markingSource(.memoryCache)
    }

    let pairs = try await pairs(for: address, now: now)

    var aggregates: [GMGNChain: Aggregate] = [:]
    for pair in pairs {
      guard Self.pair(pair, contains: address),
        let chain = Self.gmgnChain(for: pair.chainID)
      else { continue }

      var aggregate = aggregates[chain] ?? Aggregate()
      aggregate.pairCount += 1
      aggregate.maxLiquidityUSD = Self.maximum(
        aggregate.maxLiquidityUSD,
        Self.nonnegativeFinite(pair.liquidity?.usd)
      )
      aggregate.maxVolume24hUSD = Self.maximum(
        aggregate.maxVolume24hUSD,
        Self.nonnegativeFinite(pair.volume?.h24)
      )
      aggregates[chain] = aggregate
    }

    let candidates = aggregates.map { chain, aggregate in
      DexScreenerChainCandidate(
        chain: chain,
        pairCount: aggregate.pairCount,
        maxLiquidityUSD: aggregate.maxLiquidityUSD,
        maxVolume24hUSD: aggregate.maxVolume24hUSD
      )
    }.sorted(by: Self.isHigherSignal)

    let resolution = DexScreenerChainResolution(
      address: address,
      selectedChain: Self.selectedChain(from: candidates),
      candidates: candidates,
      resolvedAt: now
    )
    cache[address] = CacheEntry(resolution: resolution, storedAt: now)
    if cache.count > 200, let oldest = cache.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
      cache.removeValue(forKey: oldest)
    }
    return resolution
  }

  public func tokenSnapshot(
    chain: GMGNChain,
    address rawAddress: String,
    now: Date = Date()
  ) async throws -> GMGNTokenSnapshot {
    let address = try Self.validatedTokenAddress(rawAddress, chain: chain)
    let pairs = try await pairs(for: address, now: now)
    guard let pair = pairs
      .filter({
        Self.gmgnChain(for: $0.chainID) == chain
          && Self.address($0.baseToken?.address, matches: address)
      })
      .sorted(by: Self.isHigherSignalPair)
      .first,
      let token = pair.baseToken
    else {
      throw DexScreenerChainResolverError.tokenUnavailable(chain: chain)
    }

    return GMGNTokenSnapshot(
      chain: chain,
      address: address,
      symbol: token.symbol?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      name: token.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      priceUSD: Self.nonnegativeNumber(pair.priceUSD),
      marketCapUSD: Self.nonnegativeFinite(pair.marketCap ?? pair.fullyDilutedValuation),
      liquidityUSD: Self.nonnegativeFinite(pair.liquidity?.usd),
      volume1hUSD: Self.nonnegativeFinite(pair.volume?.h1),
      priceChange1hPercent: Self.finite(pair.priceChange?.h1),
      holderCount: nil,
      smartWalletCount: nil,
      renownedWalletCount: nil,
      logoURL: Self.nonempty(pair.info?.imageURL),
      website: pair.info?.websites?.compactMap(\.url).first.flatMap(Self.nonempty),
      twitterUsername: Self.twitterUsername(from: pair.info?.socials),
      gmgnURL: nil,
      geckoTerminalURL: nil
    )
  }

  private func pairs(for address: String, now: Date) async throws -> [Pair] {
    if let cached = pairCache[address], now.timeIntervalSince(cached.storedAt) < Self.cacheTTL {
      return cached.pairs
    }
    let requestTask: Task<[Pair], Error>
    if let inFlight = inFlightPairRequests[address] {
      requestTask = inFlight
    } else {
      let transport = transport
      requestTask = Task.detached(priority: .utility) {
        try await Self.fetchPairs(address: address, transport: transport)
      }
      inFlightPairRequests[address] = requestTask
    }

    do {
      let pairs = try await requestTask.value
      pairCache[address] = PairCacheEntry(pairs: pairs, storedAt: now)
      inFlightPairRequests[address] = nil
      if pairCache.count > 200,
        let oldest = pairCache.min(by: { $0.value.storedAt < $1.value.storedAt })?.key
      {
        pairCache.removeValue(forKey: oldest)
      }
      return pairs
    } catch {
      inFlightPairRequests[address] = nil
      throw error
    }
  }

  private nonisolated static func fetchPairs(
    address: String,
    transport: any AIHTTPTransporting
  ) async throws -> [Pair] {
    guard let url = URL(
      string: "https://api.dexscreener.com/latest/dex/tokens/\(address)"
    ) else {
      throw DexScreenerChainResolverError.invalidTokenAddress
    }
    var request = URLRequest(url: url, timeoutInterval: Self.timeout)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let response: AIHTTPResponse
    do {
      response = try await transport.send(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw DexScreenerChainResolverError.serviceUnavailable
    }
    if response.statusCode == 429 { throw DexScreenerChainResolverError.rateLimited }
    guard (200..<300).contains(response.statusCode) else {
      throw DexScreenerChainResolverError.serviceUnavailable
    }

    let decoded: Response
    do {
      decoded = try JSONDecoder().decode(Response.self, from: response.data)
    } catch {
      throw DexScreenerChainResolverError.invalidResponse
    }
    let pairs = decoded.pairs ?? []
    return pairs
  }
}

private extension DexScreenerChainResolver {
  static func validatedEVMAddress(_ value: String) throws -> String {
    let address = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard address.count == 42,
      address.hasPrefix("0x"),
      address.dropFirst(2).allSatisfy(\.isHexDigit)
    else {
      throw DexScreenerChainResolverError.invalidEVMAddress
    }
    return address
  }

  static func validatedTokenAddress(_ value: String, chain: GMGNChain) throws -> String {
    let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if chain != .sol {
      do {
        return try validatedEVMAddress(address)
      } catch {
        throw DexScreenerChainResolverError.invalidTokenAddress
      }
    }
    guard CryptoAddressDetector.matches(in: "SOL CA \(address)").contains(where: {
      $0.family == .solana && $0.address == address
    }) else {
      throw DexScreenerChainResolverError.invalidTokenAddress
    }
    return address
  }

  private static func pair(_ pair: Pair, contains address: String) -> Bool {
    Self.address(pair.baseToken?.address, matches: address)
      || Self.address(pair.quoteToken?.address, matches: address)
  }

  static func address(_ candidate: String?, matches address: String) -> Bool {
    guard let candidate else { return false }
    if address.lowercased().hasPrefix("0x") {
      return candidate.lowercased() == address.lowercased()
    }
    return candidate == address
  }

  static func gmgnChain(for rawChainID: String?) -> GMGNChain? {
    let chainID = rawChainID?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    switch chainID {
    case "sol", "solana": return .sol
    case "eth", "ethereum": return .eth
    case "base": return .base
    case "bsc", "bnb", "binance-smart-chain": return .bsc
    case "robinhood", "robinhood-chain", "robinhood_chain", "robinhood-l2", "robinhood_l2",
      "robinhoodl2": return .robinhood
    default: return nil
    }
  }

  static func nonnegativeFinite(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return value
  }

  static func finite(_ value: Double?) -> Double? {
    guard let value, value.isFinite else { return nil }
    return value
  }

  static func nonnegativeNumber(_ value: String?) -> Double? {
    guard let value, let number = Double(value), number.isFinite, number >= 0 else {
      return nil
    }
    return number
  }

  static func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func twitterUsername(from socials: [Social]?) -> String? {
    guard let value = socials?.first(where: {
      $0.type?.localizedCaseInsensitiveCompare("twitter") == .orderedSame
        || $0.type?.localizedCaseInsensitiveCompare("x") == .orderedSame
    })?.url.flatMap(nonempty) else { return nil }
    if let url = URL(string: value), let component = url.pathComponents.last,
      component != "/"
    {
      return component.replacingOccurrences(of: "@", with: "")
    }
    return value.replacingOccurrences(of: "@", with: "")
  }

  private static func isHigherSignalPair(_ lhs: Pair, _ rhs: Pair) -> Bool {
    let liquidityDelta = (lhs.liquidity?.usd ?? 0) - (rhs.liquidity?.usd ?? 0)
    if liquidityDelta != 0 { return liquidityDelta > 0 }
    return (lhs.volume?.h24 ?? 0) > (rhs.volume?.h24 ?? 0)
  }

  static func maximum(_ lhs: Double?, _ rhs: Double?) -> Double? {
    switch (lhs, rhs) {
    case (.some(let lhs), .some(let rhs)): return max(lhs, rhs)
    case (.some(let lhs), .none): return lhs
    case (.none, .some(let rhs)): return rhs
    case (.none, .none): return nil
    }
  }

  static func isHigherSignal(
    _ lhs: DexScreenerChainCandidate,
    _ rhs: DexScreenerChainCandidate
  ) -> Bool {
    let liquidityDelta = (lhs.maxLiquidityUSD ?? 0) - (rhs.maxLiquidityUSD ?? 0)
    if liquidityDelta != 0 { return liquidityDelta > 0 }
    let volumeDelta = (lhs.maxVolume24hUSD ?? 0) - (rhs.maxVolume24hUSD ?? 0)
    if volumeDelta != 0 { return volumeDelta > 0 }
    return lhs.chain.rawValue < rhs.chain.rawValue
  }

  static func selectedChain(
    from candidates: [DexScreenerChainCandidate]
  ) -> GMGNChain? {
    guard let first = candidates.first else { return nil }
    guard candidates.count > 1 else { return first.chain }
    let second = candidates[1]

    let firstLiquidity = first.maxLiquidityUSD ?? 0
    let secondLiquidity = second.maxLiquidityUSD ?? 0
    if firstLiquidity >= 10_000,
      firstLiquidity >= secondLiquidity * 3
    {
      return first.chain
    }

    let firstVolume = first.maxVolume24hUSD ?? 0
    let secondVolume = second.maxVolume24hUSD ?? 0
    if firstVolume >= 10_000,
      firstVolume >= secondVolume * 3,
      firstLiquidity >= secondLiquidity
    {
      return first.chain
    }
    return nil
  }
}
