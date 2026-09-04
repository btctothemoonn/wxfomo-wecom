import Foundation

public enum CAMarketDataSource: String, Codable, Equatable, Sendable {
  case gmgn
  case dexScreener = "dexscreener"

  public var localizedTitle: String {
    switch self {
    case .gmgn: return "GMGN"
    case .dexScreener: return "DexScreener"
    }
  }
}

public struct CATokenMarketSnapshot: Codable, Equatable, Sendable {
  public let chain: GMGNChain
  public let address: String
  public let symbol: String
  public let name: String
  public let priceUSD: Double?
  public let marketCapUSD: Double?
  public let liquidityUSD: Double?
  public let logoURL: String?
  public let capturedAt: Date
  public let source: CAMarketDataSource

  public init(
    chain: GMGNChain,
    address: String,
    symbol: String,
    name: String,
    priceUSD: Double?,
    marketCapUSD: Double?,
    liquidityUSD: Double?,
    logoURL: String?,
    capturedAt: Date,
    source: CAMarketDataSource = .gmgn
  ) {
    self.chain = chain
    self.address = address
    self.symbol = symbol
    self.name = name
    self.priceUSD = priceUSD
    self.marketCapUSD = marketCapUSD
    self.liquidityUSD = liquidityUSD
    self.logoURL = logoURL
    self.capturedAt = capturedAt
    self.source = source
  }

  public init(
    token: GMGNTokenSnapshot,
    capturedAt: Date = Date(),
    source: CAMarketDataSource = .gmgn
  ) {
    self.init(
      chain: token.chain,
      address: token.address,
      symbol: token.symbol,
      name: token.name,
      priceUSD: token.priceUSD,
      marketCapUSD: token.marketCapUSD,
      liquidityUSD: token.liquidityUSD,
      logoURL: token.logoURL,
      capturedAt: capturedAt,
      source: source
    )
  }
}

public enum CASignalEnrichmentState: String, Codable, Equatable, Sendable {
  case pending
  case resolved
  case failed
}

public struct CASignalEnrichment: Codable, Equatable, Identifiable, Sendable {
  public let eventID: String
  public let family: CryptoAddressFamily
  /// The concrete network when locally resolved; nil keeps legacy unknown-EVM records readable.
  public var network: CryptoAddressNetwork?
  public let normalizedAddress: String
  public var state: CASignalEnrichmentState
  public var snapshot: CATokenMarketSnapshot?
  public var attemptCount: Int
  public var lastErrorCode: String?
  public let createdAt: Date
  public var updatedAt: Date

  public var id: String {
    "\(eventID):\(network?.rawValue ?? (family == .solana ? "solana" : "evm")):\(normalizedAddress)"
  }

  public init(
    eventID: String,
    family: CryptoAddressFamily,
    network: CryptoAddressNetwork? = nil,
    normalizedAddress: String,
    state: CASignalEnrichmentState = .pending,
    snapshot: CATokenMarketSnapshot? = nil,
    attemptCount: Int = 0,
    lastErrorCode: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.eventID = eventID
    self.family = family
    self.network = network
    self.normalizedAddress = normalizedAddress
    self.state = state
    self.snapshot = snapshot
    self.attemptCount = attemptCount
    self.lastErrorCode = lastErrorCode
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum CAWatchPoolItemState: String, Codable, Equatable, Sendable {
  case pending
  case watching
  case removed
}

public struct CAWatchPoolItem: Codable, Equatable, Identifiable, Sendable {
  public let family: CryptoAddressFamily
  public var network: CryptoAddressNetwork?
  public let normalizedAddress: String
  public var chain: GMGNChain?
  public var state: CAWatchPoolItemState
  public var entrySnapshot: CATokenMarketSnapshot?
  public var currentSnapshot: CATokenMarketSnapshot?
  public var isPinned: Bool
  public var mentionCount: Int
  public var groupNames: [String]
  public let firstSeenAt: Date
  public var latestSeenAt: Date
  public var lastCheckedAt: Date?
  public var consecutiveFailures: Int
  public var belowThresholdCount: Int
  public var removalReason: String?
  public var updatedAt: Date

  public var id: String {
    "\(family.rawValue):\(network?.rawValue ?? (family == .solana ? "solana" : "evm")):\(normalizedAddress)"
  }

  public init(
    family: CryptoAddressFamily,
    network: CryptoAddressNetwork? = nil,
    normalizedAddress: String,
    chain: GMGNChain? = nil,
    state: CAWatchPoolItemState = .pending,
    entrySnapshot: CATokenMarketSnapshot? = nil,
    currentSnapshot: CATokenMarketSnapshot? = nil,
    isPinned: Bool = false,
    mentionCount: Int = 1,
    groupNames: [String],
    firstSeenAt: Date,
    latestSeenAt: Date,
    lastCheckedAt: Date? = nil,
    consecutiveFailures: Int = 0,
    belowThresholdCount: Int = 0,
    removalReason: String? = nil,
    updatedAt: Date = Date()
  ) {
    self.family = family
    self.network = network
    self.normalizedAddress = normalizedAddress
    self.chain = chain
    self.state = state
    self.entrySnapshot = entrySnapshot
    self.currentSnapshot = currentSnapshot
    self.isPinned = isPinned
    self.mentionCount = mentionCount
    self.groupNames = groupNames
    self.firstSeenAt = firstSeenAt
    self.latestSeenAt = latestSeenAt
    self.lastCheckedAt = lastCheckedAt
    self.consecutiveFailures = consecutiveFailures
    self.belowThresholdCount = belowThresholdCount
    self.removalReason = removalReason
    self.updatedAt = updatedAt
  }
}

public struct CAWatchPoolConfiguration: Codable, Equatable, Sendable {
  public var isEnabled: Bool
  public var capacity: Int
  public var minimumMarketCapUSD: Double
  public var refreshIntervalSeconds: TimeInterval
  public var graceAttemptCount: Int

  public init(
    isEnabled: Bool = true,
    capacity: Int = 10,
    minimumMarketCapUSD: Double = 500_000,
    refreshIntervalSeconds: TimeInterval = 120,
    graceAttemptCount: Int = 2
  ) {
    self.isEnabled = isEnabled
    self.capacity = capacity
    self.minimumMarketCapUSD = minimumMarketCapUSD
    self.refreshIntervalSeconds = refreshIntervalSeconds
    self.graceAttemptCount = graceAttemptCount
  }

  public var normalized: CAWatchPoolConfiguration {
    CAWatchPoolConfiguration(
      isEnabled: isEnabled,
      capacity: min(max(capacity, 1), 50),
      minimumMarketCapUSD: min(max(minimumMarketCapUSD, 0), 100_000_000_000),
      refreshIntervalSeconds: min(max(refreshIntervalSeconds, 60), 3_600),
      graceAttemptCount: min(max(graceAttemptCount, 1), 10)
    )
  }
}
