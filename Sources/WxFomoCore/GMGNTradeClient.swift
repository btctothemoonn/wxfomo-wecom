import Darwin
import Foundation

public enum GMGNTradeConfigurationState: String, Codable, Equatable, Sendable {
  case ready
  case executableUnavailable = "executable_unavailable"
  case notConfigured = "not_configured"

  public var localizedTitle: String {
    switch self {
    case .ready: return "GMGN 已配置"
    case .executableUnavailable: return "未找到 gmgn-cli"
    case .notConfigured: return "GMGN 尚未配置"
    }
  }
}

public struct GMGNTradeQuoteRequest: Equatable, Sendable {
  public let chain: GMGNChain
  public let walletAddress: String
  public let inputToken: String
  public let outputToken: String
  public let inputAmountSmallestUnit: String
  public let slippagePercent: Int

  public init(
    chain: GMGNChain,
    walletAddress: String,
    inputToken: String,
    outputToken: String,
    inputAmountSmallestUnit: String,
    slippagePercent: Int
  ) {
    self.chain = chain
    self.walletAddress = walletAddress
    self.inputToken = inputToken
    self.outputToken = outputToken
    self.inputAmountSmallestUnit = inputAmountSmallestUnit
    self.slippagePercent = slippagePercent
  }
}

/// A single user-authorized swap request. `inputPercent` is used only when selling
/// a non-currency token; `inputAmountSmallestUnit` remains the amount used for the quote.
public struct GMGNTradeSwapRequest: Equatable, Sendable {
  public let chain: GMGNChain
  public let walletAddress: String
  public let inputToken: String
  public let outputToken: String
  public let inputAmountSmallestUnit: String
  public let inputPercent: Int?
  public let slippagePercent: Int
  public let antiMEV: Bool

  public init(
    chain: GMGNChain,
    walletAddress: String,
    inputToken: String,
    outputToken: String,
    inputAmountSmallestUnit: String,
    inputPercent: Int? = nil,
    slippagePercent: Int,
    antiMEV: Bool = true
  ) {
    self.chain = chain
    self.walletAddress = walletAddress
    self.inputToken = inputToken
    self.outputToken = outputToken
    self.inputAmountSmallestUnit = inputAmountSmallestUnit
    self.inputPercent = inputPercent
    self.slippagePercent = slippagePercent
    self.antiMEV = antiMEV
  }
}

public struct GMGNTokenBalanceSnapshot: Equatable, Sendable {
  public let walletAddress: String
  public let tokenAddress: String
  /// GMGN returns this value in human-readable token units.
  public let balance: String
  public let reportedDecimals: Int?
  public let height: Int64?
  public let fetchedAt: Date

  public init(
    walletAddress: String,
    tokenAddress: String,
    balance: String,
    reportedDecimals: Int? = nil,
    height: Int64? = nil,
    fetchedAt: Date = Date()
  ) {
    self.walletAddress = walletAddress
    self.tokenAddress = tokenAddress
    self.balance = balance
    self.reportedDecimals = reportedDecimals
    self.height = height
    self.fetchedAt = fetchedAt
  }
}

public enum GMGNTokenAmount {
  public static func smallestUnit(
    humanBalance: String,
    percent: Int,
    decimals: Int
  ) -> String? {
    guard (1...100).contains(percent), (0...36).contains(decimals),
      let balance = Decimal(
        string: humanBalance.trimmingCharacters(in: .whitespacesAndNewlines),
        locale: Locale(identifier: "en_US_POSIX")
      ), balance > 0
    else { return nil }
    var multiplier = Decimal(1)
    for _ in 0..<decimals { multiplier *= 10 }
    var raw = balance * Decimal(percent) / 100 * multiplier
    var rounded = Decimal()
    NSDecimalRound(&rounded, &raw, 0, .down)
    guard rounded > 0 else { return nil }
    return NSDecimalNumber(decimal: rounded).stringValue
  }
}

public struct GMGNTradeExecutionReport: Codable, Equatable, Sendable {
  public let inputToken: String?
  public let inputTokenDecimals: Int?
  public let swapMode: String?
  public let inputAmount: String?
  public let outputToken: String?
  public let outputTokenDecimals: Int?
  public let outputAmount: String?
  public let quoteToken: String?
  public let quoteDecimals: Int?
  public let quoteAmount: String?
  public let baseToken: String?
  public let baseDecimals: Int?
  public let baseAmount: String?
  public let price: String?
  public let priceUSD: String?
  public let height: Int64?
  public let orderHeight: Int64?
  public let gasNative: String?
  public let gasUSD: String?

  private enum DecodeKeys: String, CodingKey {
    case inputToken, inputTokenDecimals, inputDecimals, swapMode, inputAmount
    case outputToken, outputTokenDecimals, outputDecimals, outputAmount
    case quoteToken, quoteDecimals, quoteAmount, baseToken, baseDecimals, baseAmount
    case price, priceUSD, height, blockHeight, orderHeight, orderBlockHeight
    case gasNative, gasUSD
  }

  public init(
    inputToken: String? = nil,
    inputTokenDecimals: Int? = nil,
    swapMode: String? = nil,
    inputAmount: String? = nil,
    outputToken: String? = nil,
    outputTokenDecimals: Int? = nil,
    outputAmount: String? = nil,
    quoteToken: String? = nil,
    quoteDecimals: Int? = nil,
    quoteAmount: String? = nil,
    baseToken: String? = nil,
    baseDecimals: Int? = nil,
    baseAmount: String? = nil,
    price: String? = nil,
    priceUSD: String? = nil,
    height: Int64? = nil,
    orderHeight: Int64? = nil,
    gasNative: String? = nil,
    gasUSD: String? = nil
  ) {
    self.inputToken = inputToken
    self.inputTokenDecimals = inputTokenDecimals
    self.swapMode = swapMode
    self.inputAmount = inputAmount
    self.outputToken = outputToken
    self.outputTokenDecimals = outputTokenDecimals
    self.outputAmount = outputAmount
    self.quoteToken = quoteToken
    self.quoteDecimals = quoteDecimals
    self.quoteAmount = quoteAmount
    self.baseToken = baseToken
    self.baseDecimals = baseDecimals
    self.baseAmount = baseAmount
    self.price = price
    self.priceUSD = priceUSD
    self.height = height
    self.orderHeight = orderHeight
    self.gasNative = gasNative
    self.gasUSD = gasUSD
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: DecodeKeys.self)
    inputToken = try values.decodeIfPresent(String.self, forKey: .inputToken)
    inputTokenDecimals = try values.decodeIfPresent(Int.self, forKey: .inputTokenDecimals)
      ?? values.decodeIfPresent(Int.self, forKey: .inputDecimals)
    swapMode = try values.decodeIfPresent(String.self, forKey: .swapMode)
    inputAmount = try values.decodeIfPresent(String.self, forKey: .inputAmount)
    outputToken = try values.decodeIfPresent(String.self, forKey: .outputToken)
    outputTokenDecimals = try values.decodeIfPresent(Int.self, forKey: .outputTokenDecimals)
      ?? values.decodeIfPresent(Int.self, forKey: .outputDecimals)
    outputAmount = try values.decodeIfPresent(String.self, forKey: .outputAmount)
    quoteToken = try values.decodeIfPresent(String.self, forKey: .quoteToken)
    quoteDecimals = try values.decodeIfPresent(Int.self, forKey: .quoteDecimals)
    quoteAmount = try values.decodeIfPresent(String.self, forKey: .quoteAmount)
    baseToken = try values.decodeIfPresent(String.self, forKey: .baseToken)
    baseDecimals = try values.decodeIfPresent(Int.self, forKey: .baseDecimals)
    baseAmount = try values.decodeIfPresent(String.self, forKey: .baseAmount)
    price = try values.decodeIfPresent(String.self, forKey: .price)
    priceUSD = try values.decodeIfPresent(String.self, forKey: .priceUSD)
    height = try values.decodeIfPresent(Int64.self, forKey: .height)
      ?? values.decodeIfPresent(Int64.self, forKey: .blockHeight)
    orderHeight = try values.decodeIfPresent(Int64.self, forKey: .orderHeight)
      ?? values.decodeIfPresent(Int64.self, forKey: .orderBlockHeight)
    gasNative = try values.decodeIfPresent(String.self, forKey: .gasNative)
    gasUSD = try values.decodeIfPresent(String.self, forKey: .gasUSD)
  }

  public var inputAmountNative: String? {
    Self.humanAmount(inputAmount, decimals: inputTokenDecimals)
  }

  public var outputAmountNative: String? {
    Self.humanAmount(outputAmount, decimals: outputTokenDecimals)
  }

  private static func humanAmount(_ value: String?, decimals: Int?) -> String? {
    guard let value, let decimals, (0...36).contains(decimals),
      var amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
    else { return nil }
    var divisor = Decimal(1)
    for _ in 0..<decimals { divisor *= 10 }
    amount /= divisor
    return NSDecimalNumber(decimal: amount).stringValue
  }
}

public struct GMGNTradeOrderSnapshot: Codable, Equatable, Sendable {
  public let orderID: String
  public let status: String
  public let transactionHash: String?
  public let strategyOrderID: String?
  public let errorCode: String?
  public let errorStatus: String?
  public let report: GMGNTradeExecutionReport?
  public let fetchedAt: Date

  public init(
    orderID: String,
    status: String,
    transactionHash: String?,
    strategyOrderID: String?,
    errorCode: String?,
    errorStatus: String?,
    report: GMGNTradeExecutionReport? = nil,
    fetchedAt: Date = Date()
  ) {
    self.orderID = orderID
    self.status = status
    self.transactionHash = transactionHash
    self.strategyOrderID = strategyOrderID
    self.errorCode = errorCode
    self.errorStatus = errorStatus
    self.report = report
    self.fetchedAt = fetchedAt
  }

  public var isConfirmed: Bool {
    ["confirmed", "successful", "success"].contains(status.lowercased())
  }

  public var isTerminal: Bool {
    isConfirmed || ["failed", "expired"].contains(status.lowercased())
  }
}

public struct GMGNPortfolioField: Codable, Equatable, Identifiable, Sendable {
  public let path: String
  public let value: String

  public var id: String { path }

  public init(path: String, value: String) {
    self.path = path
    self.value = value
  }
}

public struct GMGNPortfolioBalanceSnapshot: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let symbol: String
  public let tokenAddress: String?
  public let balance: String
  public let usdValue: String?

  public init(
    id: String,
    symbol: String,
    tokenAddress: String?,
    balance: String,
    usdValue: String?
  ) {
    self.id = id
    self.symbol = symbol
    self.tokenAddress = tokenAddress
    self.balance = balance
    self.usdValue = usdValue
  }
}

public struct GMGNLinkedWalletSnapshot: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let primaryAddress: String?
  public let chainID: String?
  public let chain: GMGNChain?
  public let balances: [GMGNPortfolioBalanceSnapshot]
  public let fields: [GMGNPortfolioField]

  public var localizedChainTitle: String {
    switch chainID?.lowercased() {
    case "sol", "solana": return "Solana"
    case "eth", "ethereum": return "Ethereum"
    case "base": return "Base"
    case "bsc", "bnb": return "BSC"
    case "robinhood": return "Robinhood"
    case "arc": return "Arc"
    case "stable": return "Stable"
    case .some(let value): return value.capitalized
    case nil: return chain?.localizedTitle ?? "未知网络"
    }
  }

  public init(
    id: String,
    primaryAddress: String?,
    chainID: String? = nil,
    chain: GMGNChain?,
    balances: [GMGNPortfolioBalanceSnapshot] = [],
    fields: [GMGNPortfolioField]
  ) {
    self.id = id
    self.primaryAddress = primaryAddress
    self.chainID = chainID
    self.chain = chain
    self.balances = balances
    self.fields = fields
  }
}

public struct GMGNPortfolioInfoSnapshot: Codable, Equatable, Sendable {
  public let wallets: [GMGNLinkedWalletSnapshot]
  public let fetchedAt: Date

  public init(wallets: [GMGNLinkedWalletSnapshot], fetchedAt: Date = Date()) {
    self.wallets = wallets
    self.fetchedAt = fetchedAt
  }

  public var linkedAddresses: [String] {
    wallets.compactMap(\.primaryAddress)
  }
}

public actor GMGNTradeClient {
  public static let timeout: TimeInterval = 20
  public static let confirmationTimeout: TimeInterval = 45
  public static let portfolioCacheTTL: TimeInterval = 30
  public static let quoteReuseTTL: TimeInterval = 3
  public static let robinhoodNativeTokenAddress = "0x0000000000000000000000000000000000000000"

  private struct ProcessOutput: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
  }

  private struct PortfolioCacheEntry: Sendable {
    let snapshot: GMGNPortfolioInfoSnapshot
    let storedAt: Date
  }

  private struct QuoteCacheEntry: Sendable {
    let quote: GMGNTradeQuote
    let storedAt: Date
  }

  private let executableOverride: URL?
  private var configurationChecked = false
  private var configurationCheckTask: Task<Void, Error>?
  private var supportsExplicitYesFlag: Bool?
  private var portfolioCache: PortfolioCacheEntry?
  private var quoteCache: [String: QuoteCacheEntry] = [:]
  private var inFlightQuotes: [String: Task<GMGNTradeQuote, Error>] = [:]

  public init(executableURL: URL? = nil) {
    executableOverride = executableURL
  }

  public func configurationState() async -> GMGNTradeConfigurationState {
    do {
      let executable = try executableOverride ?? Self.locateExecutable()
      try await ensureConfigured(executable: executable)
      return .ready
    } catch GMGNCLIError.executableUnavailable {
      return .executableUnavailable
    } catch {
      return .notConfigured
    }
  }

  public func portfolioInfo(
    now: Date = Date(),
    forceRefresh: Bool = false
  ) async throws -> GMGNPortfolioInfoSnapshot {
    if !forceRefresh, let portfolioCache,
      now.timeIntervalSince(portfolioCache.storedAt) < Self.portfolioCacheTTL
    {
      return portfolioCache.snapshot
    }
    let executable = try executableOverride ?? Self.locateExecutable()
    try await ensureConfigured(executable: executable)
    let output = try await Self.run(
      executable: executable,
      arguments: Self.portfolioInfoArguments
    )
    guard output.status == 0 else {
      throw Self.commandError(stderr: output.stderr, stdout: output.stdout)
    }
    let root = try Self.jsonObject(from: output.stdout)
    guard let rawWallets = root["wallets"] as? [Any] else {
      throw GMGNCLIError.invalidResponse
    }
    let parsedWallets = try rawWallets.enumerated().map { index, value in
      guard let object = value as? [String: Any] else {
        throw GMGNCLIError.invalidResponse
      }
      return Self.linkedWallet(from: object, index: index)
    }
    let wallets = await enrichingRobinhoodNativeBalance(
      in: parsedWallets,
      executable: executable
    )
    let snapshot = GMGNPortfolioInfoSnapshot(wallets: wallets, fetchedAt: now)
    portfolioCache = PortfolioCacheEntry(snapshot: snapshot, storedAt: now)
    return snapshot
  }

  public func quote(
    _ request: GMGNTradeQuoteRequest,
    now: Date = Date()
  ) async throws -> GMGNTradeQuote {
    let validated = try Self.validated(request)
    let cacheKey = GMGNTradeQuote.fingerprint(for: validated)
    if let cached = quoteCache[cacheKey],
      now.timeIntervalSince(cached.storedAt) >= 0,
      now.timeIntervalSince(cached.storedAt) <= Self.quoteReuseTTL,
      cached.quote.matches(validated, now: now)
    {
      return cached.quote
    }
    if let inFlight = inFlightQuotes[cacheKey] {
      return try await inFlight.value
    }

    let executable = try executableOverride ?? Self.locateExecutable()
    let task = Task {
      try await ensureConfigured(executable: executable)
      return try await Self.fetchQuote(
        executable: executable,
        request: validated,
        now: now
      )
    }
    inFlightQuotes[cacheKey] = task
    do {
      let quote = try await task.value
      inFlightQuotes[cacheKey] = nil
      quoteCache[cacheKey] = QuoteCacheEntry(quote: quote, storedAt: now)
      if quoteCache.count > 100,
        let oldest = quoteCache.min(by: { $0.value.storedAt < $1.value.storedAt })?.key
      {
        quoteCache.removeValue(forKey: oldest)
      }
      return quote
    } catch {
      inFlightQuotes[cacheKey] = nil
      throw error
    }
  }

  private static func fetchQuote(
    executable: URL,
    request: GMGNTradeQuoteRequest,
    now: Date
  ) async throws -> GMGNTradeQuote {
    let output = try await Self.run(
      executable: executable,
      arguments: Self.quoteArguments(request)
    )
    guard output.status == 0 else {
      throw Self.commandError(stderr: output.stderr, stdout: output.stdout)
    }
    let root = try Self.jsonObject(from: output.stdout)
    guard let inputToken = Self.string(root["input_token"]),
      let outputToken = Self.string(root["output_token"]),
      let inputAmount = Self.string(root["input_amount"]),
      let outputAmount = Self.string(root["output_amount"])
    else {
      throw GMGNCLIError.invalidResponse
    }
    return GMGNTradeQuote(
      chain: request.chain,
      walletAddress: request.walletAddress,
      inputToken: inputToken,
      outputToken: outputToken,
      inputAmount: inputAmount,
      outputAmount: outputAmount,
      minimumOutputAmount: Self.string(root["min_output_amount"]),
      slippagePercent: Self.number(root["slippage"]),
      requestedSlippagePercent: request.slippagePercent,
      requestFingerprint: GMGNTradeQuote.fingerprint(
        for: request
      ),
      quotedAt: now
    )
  }

  public func tokenBalance(
    chain: GMGNChain,
    walletAddress rawWalletAddress: String,
    tokenAddress rawTokenAddress: String,
    now: Date = Date()
  ) async throws -> GMGNTokenBalanceSnapshot {
    let walletAddress = try Self.validatedAddress(rawWalletAddress, chain: chain)
    let tokenAddress = try Self.validatedAddress(rawTokenAddress, chain: chain)
    let executable = try executableOverride ?? Self.locateExecutable()
    try await ensureConfigured(executable: executable)
    let output = try await Self.run(
      executable: executable,
      arguments: Self.tokenBalanceArguments(
        chain: chain,
        walletAddress: walletAddress,
        tokenAddress: tokenAddress
      )
    )
    guard output.status == 0 else {
      throw Self.commandError(stderr: output.stderr, stdout: output.stdout)
    }
    let root = try Self.jsonObject(from: output.stdout)
    let nested = (root["data"] as? [String: Any]) ?? root
    guard let balances = nested["balances"] as? [Any],
      let object = balances.compactMap({ $0 as? [String: Any] }).first,
      let balance = Self.string(object["balance"])
    else {
      throw GMGNCLIError.commandFailed("GMGN 未返回该代币余额。")
    }
    return GMGNTokenBalanceSnapshot(
      walletAddress: Self.string(object["wallet_address"]) ?? walletAddress,
      tokenAddress: Self.string(object["token_address"]) ?? tokenAddress,
      balance: balance,
      reportedDecimals: Self.integer(object["decimal"] ?? object["decimals"]),
      height: Self.int64(object["height"]),
      fetchedAt: now
    )
  }

  public func order(
    id rawOrderID: String,
    chain: GMGNChain,
    now: Date = Date()
  ) async throws -> GMGNTradeOrderSnapshot {
    let orderID = rawOrderID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isSafeIdentifier(orderID) else {
      throw GMGNCLIError.commandFailed("GMGN 订单 ID 无效。")
    }
    let executable = try executableOverride ?? Self.locateExecutable()
    try await ensureConfigured(executable: executable)
    let output = try await Self.run(
      executable: executable,
      arguments: ["order", "get", "--chain", chain.rawValue, "--order-id", orderID, "--raw"]
    )
    guard output.status == 0 else {
      throw Self.commandError(stderr: output.stderr, stdout: output.stdout)
    }
    let root = try Self.jsonObject(from: output.stdout)
    return Self.orderSnapshot(from: root, fallbackOrderID: orderID, now: now)
  }

  /// Submits exactly one user-authorized swap and returns as soon as GMGN gives
  /// wxFomo an order identifier. Confirmation polling is deliberately separate
  /// so the caller can persist the order before any read-only network retries.
  public func submitSwap(
    _ request: GMGNTradeSwapRequest,
    confirmedByUser: Bool,
    now: Date = Date()
  ) async throws -> GMGNTradeOrderSnapshot {
    guard confirmedByUser else {
      throw GMGNCLIError.commandFailed("交易必须经过用户确认。")
    }
    let validated = try Self.validated(request)
    let executable = try executableOverride ?? Self.locateExecutable()
    try await ensureConfigured(executable: executable)
    let includeYes = await detectsExplicitYesFlag(executable: executable)
    let output: ProcessOutput
    do {
      output = try await Self.run(
        executable: executable,
        arguments: Self.swapArguments(validated, includeYes: includeYes),
        allowAutomatedTrade: true
      )
    } catch GMGNCLIError.timedOut {
      throw GMGNCLIError.submissionUncertain("GMGN 提交请求超时")
    }
    guard output.status == 0 else {
      let error = Self.commandError(stderr: output.stderr, stdout: output.stdout)
      if case .networkUnavailable(let message) = error {
        throw GMGNCLIError.submissionUncertain(message)
      }
      throw error
    }
    let root: [String: Any]
    do {
      root = try Self.jsonObject(from: output.stdout)
    } catch {
      throw GMGNCLIError.submissionUncertain("GMGN 已响应，但订单回执无法解析")
    }
    let initial = Self.orderSnapshot(from: root, fallbackOrderID: "", now: now)
    if !initial.orderID.isEmpty || initial.isTerminal { return initial }
    throw GMGNCLIError.submissionUncertain("GMGN 回执未包含订单 ID")
  }

  /// Submit one confirmed manual buy and poll GMGN until the order reaches a
  /// terminal state. The GUI confirmation is the human confirmation required by
  /// wxFomo; the CLI receives its explicit trade opt-in through the environment.
  public func swap(
    _ request: GMGNTradeSwapRequest,
    confirmedByUser: Bool,
    now: Date = Date()
  ) async throws -> GMGNTradeOrderSnapshot {
    let initial = try await submitSwap(request, confirmedByUser: confirmedByUser, now: now)
    guard !initial.orderID.isEmpty, !initial.isTerminal else { return initial }
    return try await waitForConfirmation(
      orderID: initial.orderID,
      chain: request.chain,
      initial: initial,
      deadline: Date().addingTimeInterval(Self.confirmationTimeout)
    )
  }

  /// Polls a known order. Individual read failures consume the bounded retry
  /// budget but never erase the last known server state.
  public func waitForConfirmation(
    orderID: String,
    chain: GMGNChain,
    initial: GMGNTradeOrderSnapshot,
    deadline: Date
  ) async throws -> GMGNTradeOrderSnapshot {
    var latest = initial
    for _ in 0..<3 {
      if latest.isTerminal { return latest }
      guard Date() < deadline else { break }
      try await Task.sleep(for: .seconds(5))
      do {
        latest = try await order(id: orderID, chain: chain)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        continue
      }
    }
    return latest
  }

  public nonisolated static func quoteArguments(
    _ request: GMGNTradeQuoteRequest
  ) -> [String] {
    [
      "order", "quote", "--chain", request.chain.rawValue,
      "--from", request.walletAddress,
      "--input-token", request.inputToken,
      "--output-token", request.outputToken,
      "--amount", request.inputAmountSmallestUnit,
      "--slippage", String(request.slippagePercent),
      "--raw",
    ]
  }

  public nonisolated static var portfolioInfoArguments: [String] {
    ["portfolio", "info", "--raw"]
  }

  public nonisolated static func robinhoodNativeBalanceArguments(
    walletAddress: String
  ) -> [String] {
    [
      "portfolio", "token-balance",
      "--chain", GMGNChain.robinhood.rawValue,
      "--wallet", walletAddress.lowercased(),
      "--token", robinhoodNativeTokenAddress,
      "--raw",
    ]
  }

  public nonisolated static func tokenBalanceArguments(
    chain: GMGNChain,
    walletAddress: String,
    tokenAddress: String
  ) -> [String] {
    let wallet = chain == .sol ? walletAddress : walletAddress.lowercased()
    let token = chain == .sol ? tokenAddress : tokenAddress.lowercased()
    return [
      "portfolio", "token-balance", "--chain", chain.rawValue,
      "--wallet", wallet, "--token", token, "--raw",
    ]
  }

  public nonisolated static func swapArguments(
    _ request: GMGNTradeSwapRequest,
    includeYes: Bool = false
  ) -> [String] {
    var arguments = [
      "swap", "--chain", request.chain.rawValue,
      "--from", request.walletAddress,
      "--input-token", request.inputToken,
      "--output-token", request.outputToken,
    ]
    if let percent = request.inputPercent {
      arguments.append(contentsOf: ["--percent", String(percent)])
    } else {
      arguments.append(contentsOf: ["--amount", request.inputAmountSmallestUnit])
    }
    arguments.append(contentsOf: ["--slippage", String(request.slippagePercent)])
    if request.antiMEV, [.sol, .bsc, .eth].contains(request.chain) {
      arguments.append("--anti-mev")
    }
    if includeYes {
      arguments.append("--yes")
    }
    arguments.append("--raw")
    return arguments
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

  private func enrichingRobinhoodNativeBalance(
    in wallets: [GMGNLinkedWalletSnapshot],
    executable: URL
  ) async -> [GMGNLinkedWalletSnapshot] {
    var enriched = wallets
    for index in enriched.indices {
      let wallet = enriched[index]
      guard wallet.chain == .robinhood,
        wallet.balances.isEmpty,
        let address = wallet.primaryAddress,
        Self.isSupportedWalletAddress(address)
      else { continue }

      guard let output = try? await Self.run(
        executable: executable,
        arguments: Self.robinhoodNativeBalanceArguments(walletAddress: address)
      ), output.status == 0,
        let root = try? Self.jsonObject(from: output.stdout),
        let balance = Self.robinhoodNativeBalance(from: root)
      else { continue }

      enriched[index] = GMGNLinkedWalletSnapshot(
        id: wallet.id,
        primaryAddress: wallet.primaryAddress,
        chainID: wallet.chainID,
        chain: wallet.chain,
        balances: [balance],
        fields: wallet.fields
      )
    }
    return enriched
  }

  private func detectsExplicitYesFlag(executable: URL) async -> Bool {
    if let supportsExplicitYesFlag { return supportsExplicitYesFlag }
    guard let output = try? await Self.run(
      executable: executable,
      arguments: ["swap", "--help"]
    ) else {
      supportsExplicitYesFlag = false
      return false
    }
    let help = String(decoding: output.stdout, as: UTF8.self)
      + String(decoding: output.stderr, as: UTF8.self)
    let supported = help.contains("--yes")
    supportsExplicitYesFlag = supported
    return supported
  }
}

private extension GMGNTradeClient {
  static func validated(_ request: GMGNTradeQuoteRequest) throws -> GMGNTradeQuoteRequest {
    guard (1...100).contains(request.slippagePercent),
      request.inputAmountSmallestUnit.range(of: #"^[1-9][0-9]*$"#, options: .regularExpression)
        != nil,
      request.inputAmountSmallestUnit.count <= 80
    else {
      throw GMGNCLIError.commandFailed("GMGN 报价参数无效。")
    }
    let wallet = try validatedAddress(request.walletAddress, chain: request.chain)
    let input = try validatedAddress(request.inputToken, chain: request.chain)
    let output = try validatedAddress(request.outputToken, chain: request.chain)
    return GMGNTradeQuoteRequest(
      chain: request.chain,
      walletAddress: wallet,
      inputToken: input,
      outputToken: output,
      inputAmountSmallestUnit: request.inputAmountSmallestUnit,
      slippagePercent: request.slippagePercent
    )
  }

  static func validated(_ request: GMGNTradeSwapRequest) throws -> GMGNTradeSwapRequest {
    guard (1...100).contains(request.slippagePercent),
      request.inputPercent.map({ (1...100).contains($0) }) ?? true,
      request.inputAmountSmallestUnit.range(of: #"^[1-9][0-9]*$"#, options: .regularExpression)
        != nil,
      request.inputAmountSmallestUnit.count <= 80
    else {
      throw GMGNCLIError.commandFailed("GMGN 交易参数无效。")
    }
    let wallet = try validatedAddress(request.walletAddress, chain: request.chain)
    let input = try validatedAddress(request.inputToken, chain: request.chain)
    let output = try validatedAddress(request.outputToken, chain: request.chain)
    guard request.inputPercent == nil || !isCurrencyToken(input, chain: request.chain) else {
      throw GMGNCLIError.commandFailed("原生资产或稳定币不能按余额百分比提交，请使用明确数量。")
    }
    return GMGNTradeSwapRequest(
      chain: request.chain,
      walletAddress: wallet,
      inputToken: input,
      outputToken: output,
      inputAmountSmallestUnit: request.inputAmountSmallestUnit,
      inputPercent: request.inputPercent,
      slippagePercent: request.slippagePercent,
      antiMEV: request.antiMEV
    )
  }

  static func orderSnapshot(
    from root: [String: Any],
    fallbackOrderID: String,
    now: Date
  ) -> GMGNTradeOrderSnapshot {
    let nested = (root["result"] as? [String: Any]) ?? root
    let report = (nested["report"] as? [String: Any]).map(executionReport(from:))
    return GMGNTradeOrderSnapshot(
      orderID: string(nested["order_id"]) ?? fallbackOrderID,
      status: string(nested["status"]) ?? "unknown",
      transactionHash: string(nested["hash"]),
      strategyOrderID: string(nested["strategy_order_id"]),
      errorCode: string(nested["error_code"]),
      errorStatus: string(nested["error_status"]),
      report: report,
      fetchedAt: now
    )
  }

  static func executionReport(from object: [String: Any]) -> GMGNTradeExecutionReport {
    GMGNTradeExecutionReport(
      inputToken: string(object["input_token"]),
      inputTokenDecimals: integer(object["input_token_decimals"]),
      swapMode: string(object["swap_mode"]),
      inputAmount: string(object["input_amount"]),
      outputToken: string(object["output_token"]),
      outputTokenDecimals: integer(object["output_token_decimals"]),
      outputAmount: string(object["output_amount"]),
      quoteToken: string(object["quote_token"]),
      quoteDecimals: integer(object["quote_decimals"]),
      quoteAmount: string(object["quote_amount"]),
      baseToken: string(object["base_token"]),
      baseDecimals: integer(object["base_decimals"]),
      baseAmount: string(object["base_amount"]),
      price: string(object["price"]),
      priceUSD: string(object["price_usd"]),
      height: int64(object["height"]),
      orderHeight: int64(object["order_height"]),
      gasNative: string(object["gas_native"]),
      gasUSD: string(object["gas_usd"])
    )
  }

  static func validatedAddress(_ value: String, chain: GMGNChain) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let pattern = chain == .sol ? #"^[1-9A-HJ-NP-Za-km-z]{32,44}$"# : #"^0x[0-9A-Fa-f]{40}$"#
    guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
      throw GMGNCLIError.invalidAddress(chain: chain)
    }
    return chain == .sol ? trimmed : trimmed.lowercased()
  }

  static func isSafeIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 160
      && value.range(of: #"^[A-Za-z0-9._:-]+$"#, options: .regularExpression) != nil
  }

  static func isCurrencyToken(_ value: String, chain: GMGNChain) -> Bool {
    let normalized = chain == .sol ? value : value.lowercased()
    switch chain {
    case .sol:
      return [
        "So11111111111111111111111111111111111111112",
        "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
      ].contains(normalized)
    case .bsc:
      return [
        robinhoodNativeTokenAddress,
        "0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d",
      ].contains(normalized)
    case .base:
      return [
        robinhoodNativeTokenAddress,
        "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      ].contains(normalized)
    case .eth, .robinhood:
      return normalized == robinhoodNativeTokenAddress
    }
  }

  static func locateExecutable() throws -> URL {
    let fileManager = FileManager.default
    let environment = ProcessInfo.processInfo.environment
    var candidates: [URL] = []
    for directory in (environment["PATH"] ?? "").split(separator: ":") {
      candidates.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("gmgn-cli"))
    }
    candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/gmgn-cli"))
    candidates.append(URL(fileURLWithPath: "/usr/local/bin/gmgn-cli"))
    let nvmRoot = fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent(".nvm/versions/node", isDirectory: true)
    if let versions = try? fileManager.contentsOfDirectory(
      at: nvmRoot,
      includingPropertiesForKeys: nil
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

  private static func run(
    executable: URL,
    arguments: [String],
    allowAutomatedTrade: Bool = false
  ) async throws -> ProcessOutput {
    try await Task.detached(priority: .utility) {
      try runBlocking(
        executable: executable,
        arguments: arguments,
        allowAutomatedTrade: allowAutomatedTrade
      )
    }.value
  }

  private static func runBlocking(
    executable: URL,
    arguments: [String],
    allowAutomatedTrade: Bool = false
  ) throws -> ProcessOutput {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("wxfomo-gmgn-trade-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let stdoutURL = directory.appendingPathComponent("stdout")
    let stderrURL = directory.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let stdout = try FileHandle(forWritingTo: stdoutURL)
    let stderr = try FileHandle(forWritingTo: stderrURL)
    defer {
      try? stdout.close()
      try? stderr.close()
    }

    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdout
    process.standardError = stderr
    process.environment = GMGNCLIProcessEnvironment.make(
      executable: executable,
      allowAutomatedTrade: allowAutomatedTrade
    )
    do {
      try process.run()
    } catch {
      throw GMGNCLIError.executableUnavailable
    }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if process.isRunning {
      process.terminate()
      Thread.sleep(forTimeInterval: 0.1)
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      throw GMGNCLIError.timedOut
    }
    process.waitUntilExit()
    try? stdout.synchronize()
    try? stderr.synchronize()
    return ProcessOutput(
      status: process.terminationStatus,
      stdout: try limitedData(contentsOf: stdoutURL, limit: 4 * 1_024 * 1_024),
      stderr: try limitedData(contentsOf: stderrURL, limit: 64 * 1_024)
    )
  }

  static func limitedData(contentsOf url: URL, limit: Int) throws -> Data {
    let size = ((try FileManager.default.attributesOfItem(atPath: url.path))[.size] as? NSNumber)?
      .intValue ?? 0
    guard size <= limit else { throw GMGNCLIError.commandFailed("GMGN 返回数据超过本地限制。") }
    return try Data(contentsOf: url)
  }

  static func jsonObject(from data: Data) throws -> [String: Any] {
    guard !data.isEmpty,
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw GMGNCLIError.invalidResponse
    }
    return (root["data"] as? [String: Any]) ?? root
  }

  static func commandError(stderr: Data, stdout: Data) -> GMGNCLIError {
    let source = stderr.isEmpty ? stdout : stderr
    let message = sanitized(String(decoding: source, as: UTF8.self))
    return GMGNCLIProcessEnvironment.commandError(message: message)
  }

  static func sanitized(_ value: String) -> String {
    var output = value
      .replacingOccurrences(
        of: #"GMGN_[A-Z_]*(KEY|TOKEN|SECRET)=\S+"#,
        with: "GMGN_CREDENTIAL=[redacted]",
        options: .regularExpression
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if output.count > 600 { output = String(output.prefix(600)) }
    return output.isEmpty ? "GMGN 命令执行失败。" : output
  }

  static func string(_ value: Any?) -> String? {
    if let value = value as? String, !value.isEmpty { return value }
    if let value = value as? NSNumber { return value.stringValue }
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

  static func int64(_ value: Any?) -> Int64? {
    if let value = value as? NSNumber { return value.int64Value }
    if let value = value as? String { return Int64(value) }
    return nil
  }

  static func linkedWallet(
    from object: [String: Any],
    index: Int
  ) -> GMGNLinkedWalletSnapshot {
    let fields = flattenedPortfolioFields(object)
    let directAddress = object["address"].flatMap(portfolioDisplayValue)
    let addressFields = fields.filter {
      !$0.path.lowercased().hasPrefix("balances[") && isSupportedWalletAddress($0.value)
    }
    let primaryAddress = directAddress.flatMap { isSupportedWalletAddress($0) ? $0 : nil }
      ?? addressFields.first(where: {
      let key = $0.path.lowercased()
      return key.contains("address") || key.contains("wallet") || key.contains("account")
    })?.value ?? addressFields.first?.value
    let chainID = object["chain"].flatMap(portfolioDisplayValue)?.lowercased()
    let chain = chainID.flatMap(GMGNChain.init(rawValue:)) ?? inferredChain(from: primaryAddress)
    let rawBalances = object["balances"] as? [Any] ?? []
    let balances = rawBalances.enumerated().compactMap { balance(from: $0.element, index: $0.offset) }
    return GMGNLinkedWalletSnapshot(
      id: "\(chainID ?? "wallet"):\(primaryAddress?.lowercased() ?? String(index))",
      primaryAddress: primaryAddress,
      chainID: chainID,
      chain: chain,
      balances: balances,
      fields: fields
    )
  }

  static func balance(from value: Any, index: Int) -> GMGNPortfolioBalanceSnapshot? {
    guard let object = value as? [String: Any] else { return nil }
    let symbol = object["symbol"].flatMap(portfolioDisplayValue) ?? "未知资产"
    let tokenAddress = object["token_address"].flatMap(portfolioDisplayValue)
    let balance = object["balance"].flatMap(portfolioDisplayValue) ?? "未返回"
    let usdValue = object["usd_value"].flatMap(portfolioDisplayValue)
    guard symbol != "未知资产" || tokenAddress != nil || balance != "未返回" else { return nil }
    return GMGNPortfolioBalanceSnapshot(
      id: "\(index):\(tokenAddress?.lowercased() ?? symbol.lowercased())",
      symbol: symbol,
      tokenAddress: tokenAddress,
      balance: balance,
      usdValue: usdValue
    )
  }

  static func robinhoodNativeBalance(
    from root: [String: Any]
  ) -> GMGNPortfolioBalanceSnapshot? {
    guard let values = root["balances"] as? [Any] else { return nil }
    for value in values {
      guard let object = value as? [String: Any],
        let balance = string(object["balance"])
      else { continue }
      let tokenAddress = string(object["token_address"])?.lowercased()
        ?? robinhoodNativeTokenAddress
      guard tokenAddress == robinhoodNativeTokenAddress else { continue }
      return GMGNPortfolioBalanceSnapshot(
        id: "native:\(robinhoodNativeTokenAddress)",
        symbol: "ETH",
        tokenAddress: robinhoodNativeTokenAddress,
        balance: balance,
        usdValue: nil
      )
    }
    return nil
  }

  static func flattenedPortfolioFields(_ object: [String: Any]) -> [GMGNPortfolioField] {
    var fields: [GMGNPortfolioField] = []

    func append(value: Any, path: String, depth: Int) {
      guard depth <= 4, fields.count < 80, !isCredentialField(path) else { return }
      if let dictionary = value as? [String: Any] {
        for key in dictionary.keys.sorted() {
          guard let nested = dictionary[key] else { continue }
          append(value: nested, path: path.isEmpty ? key : "\(path).\(key)", depth: depth + 1)
        }
      } else if let array = value as? [Any] {
        for (index, nested) in array.prefix(20).enumerated() {
          append(value: nested, path: "\(path)[\(index)]", depth: depth + 1)
        }
      } else if !(value is NSNull), let display = portfolioDisplayValue(value) {
        fields.append(GMGNPortfolioField(path: path, value: display))
      }
    }

    append(value: object, path: "", depth: 0)
    return fields
  }

  static func portfolioDisplayValue(_ value: Any) -> String? {
    let raw: String
    if let string = value as? String {
      raw = string
    } else if let number = value as? NSNumber {
      raw = number.stringValue
    } else {
      return nil
    }
    let sanitized = raw.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0) || $0 == "\n"
    }
    let trimmed = String(String.UnicodeScalarView(sanitized))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return String(trimmed.prefix(240))
  }

  static func isCredentialField(_ path: String) -> Bool {
    let key = path.lowercased()
    return key.contains("private_key") || key.contains("apikey") || key.contains("api_key")
      || key.contains("mnemonic") || key.contains("seed_phrase") || key.contains("password")
      || key.contains("secret")
  }

  static func isSupportedWalletAddress(_ value: String) -> Bool {
    value.range(of: #"^[1-9A-HJ-NP-Za-km-z]{32,44}$"#, options: .regularExpression) != nil
      || value.range(of: #"^0x[0-9A-Fa-f]{40}$"#, options: .regularExpression) != nil
  }

  static func inferredChain(from address: String?) -> GMGNChain? {
    guard let address else { return nil }
    return address.lowercased().hasPrefix("0x") ? nil : .sol
  }
}
