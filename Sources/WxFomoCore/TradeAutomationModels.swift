import Foundation

public enum TradeAutomationMode: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
  case off
  case simulation
  case approvalRequired = "approval_required"

  public var id: String { rawValue }

  public var localizedTitle: String {
    switch self {
    case .off: return "关闭"
    case .simulation: return "模拟"
    case .approvalRequired: return "实盘待确认"
    }
  }
}

public struct TradeAutomationConfiguration: Codable, Equatable, Sendable {
  public var mode: TradeAutomationMode
  public var emergencyStopped: Bool
  public var walletAddress: String?
  public var maximumDailySpendUSD: Double
  public var maximumDailyIntents: Int
  public var maximumOpenPositions: Int
  public var maximumConsecutiveFailures: Int

  public init(
    mode: TradeAutomationMode = .simulation,
    emergencyStopped: Bool = false,
    walletAddress: String? = nil,
    maximumDailySpendUSD: Double = 0,
    maximumDailyIntents: Int = 4,
    maximumOpenPositions: Int = 3,
    maximumConsecutiveFailures: Int = 3
  ) {
    self.mode = mode
    self.emergencyStopped = emergencyStopped
    self.walletAddress = walletAddress
    self.maximumDailySpendUSD = maximumDailySpendUSD
    self.maximumDailyIntents = maximumDailyIntents
    self.maximumOpenPositions = maximumOpenPositions
    self.maximumConsecutiveFailures = maximumConsecutiveFailures
  }

  public var normalized: TradeAutomationConfiguration {
    TradeAutomationConfiguration(
      mode: mode,
      emergencyStopped: emergencyStopped,
      walletAddress: walletAddress.flatMap {
        let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value.prefix(128))
      },
      maximumDailySpendUSD: min(max(maximumDailySpendUSD, 0), 10_000_000),
      maximumDailyIntents: min(max(maximumDailyIntents, 1), 1_000),
      maximumOpenPositions: min(max(maximumOpenPositions, 1), 1_000),
      maximumConsecutiveFailures: min(max(maximumConsecutiveFailures, 1), 100)
    )
  }
}

public struct TradeProtectionOrder: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, CaseIterable, Equatable, Sendable {
    case takeProfit = "take_profit"
    case stopLoss = "stop_loss"

    public var localizedTitle: String {
      switch self {
      case .takeProfit: return "止盈"
      case .stopLoss: return "止损"
      }
    }
  }

  public var id: String
  public var kind: Kind
  public var triggerPercent: Double
  public var sellPercent: Double

  public init(
    id: String = UUID().uuidString,
    kind: Kind,
    triggerPercent: Double,
    sellPercent: Double
  ) {
    self.id = id
    self.kind = kind
    self.triggerPercent = triggerPercent
    self.sellPercent = sellPercent
  }

  public var normalized: TradeProtectionOrder {
    let normalizedTrigger: Double
    switch kind {
    case .takeProfit:
      normalizedTrigger = min(max(triggerPercent, 1), 10_000)
    case .stopLoss:
      // A 100% drawdown means no position remains. Keep the input below 100%
      // so a stop-loss cannot be confused with a zero-price trigger.
      normalizedTrigger = min(max(triggerPercent, 1), 99)
    }
    return TradeProtectionOrder(
      id: id,
      kind: kind,
      triggerPercent: normalizedTrigger,
      sellPercent: min(max(sellPercent, 1), 100)
    )
  }

  public var validationIssues: [String] {
    var issues: [String] = []
    if !triggerPercent.isFinite {
      issues.append("触发比例必须是有效数字")
    } else {
      switch kind {
      case .takeProfit where !(1...10_000).contains(triggerPercent):
        issues.append("止盈上涨比例必须在 1% 到 10,000% 之间")
      case .stopLoss where !(1..<100).contains(triggerPercent):
        issues.append("止损下跌比例必须在 1% 到 99% 之间")
      default:
        break
      }
    }
    if !sellPercent.isFinite || !(1...100).contains(sellPercent) {
      issues.append("卖出比例必须在 1% 到 100% 之间")
    }
    return issues
  }

  public var triggerDescription: String {
    let value = triggerPercent.formatted(.number.precision(.fractionLength(0...2)))
    return kind == .takeProfit ? "上涨 \(value)%" : "下跌 \(value)%"
  }
}

public struct TradeAutomationRule: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var isEnabled: Bool
  public var allowedChains: Set<GMGNChain>
  public var groups: [String]
  public var senders: [String]
  public var aggregationWindowSeconds: TimeInterval
  public var minimumMentions: Int
  public var minimumDistinctGroups: Int
  public var minimumMarketCapUSD: Double
  public var maximumMarketCapUSD: Double
  public var minimumLiquidityUSD: Double
  public var minimumHolderCount: Int
  public var maximumRugRatio: Double
  public var requireSecurityData: Bool
  public var inputAmountNative: Double
  public var maximumSlippagePercent: Int
  public var antiMEV: Bool
  public var maximumTradesPerDay: Int
  public var tokenCooldownSeconds: TimeInterval
  public var protectionOrders: [TradeProtectionOrder]
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: String = UUID().uuidString,
    name: String = "多群 CA 模拟策略",
    isEnabled: Bool = true,
    allowedChains: Set<GMGNChain> = [.sol],
    groups: [String] = [],
    senders: [String] = [],
    aggregationWindowSeconds: TimeInterval = 10 * 60,
    minimumMentions: Int = 2,
    minimumDistinctGroups: Int = 2,
    minimumMarketCapUSD: Double = 500_000,
    maximumMarketCapUSD: Double = 20_000_000,
    minimumLiquidityUSD: Double = 100_000,
    minimumHolderCount: Int = 0,
    maximumRugRatio: Double = 0.1,
    requireSecurityData: Bool = true,
    inputAmountNative: Double = 0.01,
    maximumSlippagePercent: Int = 12,
    antiMEV: Bool = true,
    maximumTradesPerDay: Int = 2,
    tokenCooldownSeconds: TimeInterval = 24 * 60 * 60,
    protectionOrders: [TradeProtectionOrder] = [
      TradeProtectionOrder(kind: .takeProfit, triggerPercent: 100, sellPercent: 50),
      TradeProtectionOrder(kind: .takeProfit, triggerPercent: 200, sellPercent: 50),
      TradeProtectionOrder(kind: .stopLoss, triggerPercent: 50, sellPercent: 100),
    ],
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.isEnabled = isEnabled
    self.allowedChains = allowedChains
    self.groups = groups
    self.senders = senders
    self.aggregationWindowSeconds = aggregationWindowSeconds
    self.minimumMentions = minimumMentions
    self.minimumDistinctGroups = minimumDistinctGroups
    self.minimumMarketCapUSD = minimumMarketCapUSD
    self.maximumMarketCapUSD = maximumMarketCapUSD
    self.minimumLiquidityUSD = minimumLiquidityUSD
    self.minimumHolderCount = minimumHolderCount
    self.maximumRugRatio = maximumRugRatio
    self.requireSecurityData = requireSecurityData
    self.inputAmountNative = inputAmountNative
    self.maximumSlippagePercent = maximumSlippagePercent
    self.antiMEV = antiMEV
    self.maximumTradesPerDay = maximumTradesPerDay
    self.tokenCooldownSeconds = tokenCooldownSeconds
    self.protectionOrders = protectionOrders
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var normalized: TradeAutomationRule {
    let cleanedGroups = Self.uniqueNonempty(groups)
    let cleanedSenders = Self.uniqueNonempty(senders)
    let lowerCap = min(max(minimumMarketCapUSD, 0), 100_000_000_000)
    let upperCap = min(max(maximumMarketCapUSD, lowerCap), 100_000_000_000)
    return TradeAutomationRule(
      id: id.trimmingCharacters(in: .whitespacesAndNewlines),
      name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)),
      isEnabled: isEnabled,
      allowedChains: allowedChains.intersection([.sol, .eth, .base, .bsc]),
      groups: cleanedGroups,
      senders: cleanedSenders,
      aggregationWindowSeconds: min(max(aggregationWindowSeconds, 60), 24 * 60 * 60),
      minimumMentions: min(max(minimumMentions, 1), 1_000),
      minimumDistinctGroups: min(max(minimumDistinctGroups, 1), 1_000),
      minimumMarketCapUSD: lowerCap,
      maximumMarketCapUSD: upperCap,
      minimumLiquidityUSD: min(max(minimumLiquidityUSD, 0), 100_000_000_000),
      minimumHolderCount: min(max(minimumHolderCount, 0), 1_000_000_000),
      maximumRugRatio: min(max(maximumRugRatio, 0), 1),
      requireSecurityData: requireSecurityData,
      inputAmountNative: min(max(inputAmountNative, 0.000_001), 1_000_000),
      maximumSlippagePercent: min(max(maximumSlippagePercent, 1), 100),
      antiMEV: antiMEV,
      maximumTradesPerDay: min(max(maximumTradesPerDay, 1), 1_000),
      tokenCooldownSeconds: min(max(tokenCooldownSeconds, 60), 365 * 24 * 60 * 60),
      protectionOrders: Array(protectionOrders.prefix(10)).map(\.normalized),
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }

  public var validationIssues: [String] {
    var issues: [String] = []
    if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append("规则 ID 不能为空")
    }
    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append("规则名称不能为空")
    }
    if allowedChains.intersection([.sol, .eth, .base, .bsc]).count != 1 {
      issues.append("每条交易规则必须只选择一个网络；不同原生资产请拆分规则")
    }
    if !inputAmountNative.isFinite || inputAmountNative <= 0 {
      issues.append("买入数量必须大于 0")
    }
    if !minimumMarketCapUSD.isFinite || minimumMarketCapUSD < 0
      || !maximumMarketCapUSD.isFinite || maximumMarketCapUSD < 0
    {
      issues.append("市值范围必须是有效的非负数")
    } else if maximumMarketCapUSD < minimumMarketCapUSD {
      issues.append("最高市值不能低于最低市值")
    }
    if !minimumLiquidityUSD.isFinite || minimumLiquidityUSD < 0 {
      issues.append("最低流动性必须是有效的非负数")
    }
    if !maximumRugRatio.isFinite || !(0...1).contains(maximumRugRatio) {
      issues.append("Rug 比例必须在 0 到 1 之间")
    }
    if !aggregationWindowSeconds.isFinite || aggregationWindowSeconds < 60 {
      issues.append("统计窗口不能少于 1 分钟")
    }
    if !tokenCooldownSeconds.isFinite || tokenCooldownSeconds < 60 {
      issues.append("同币冷却不能少于 1 分钟")
    }
    let stopLossCount = protectionOrders.filter { $0.kind == .stopLoss }.count
    if stopLossCount > 1 { issues.append("每条规则最多设置一个止损") }
    issues.append(contentsOf: protectionOrders.flatMap { order in
      order.validationIssues.map { "保护单：\($0)" }
    })
    let takeProfitSellTotal = protectionOrders
      .filter { $0.kind == .takeProfit }
      .reduce(0) { $0 + $1.sellPercent }
    if takeProfitSellTotal > 100 {
      issues.append("止盈卖出比例合计不能超过 100%")
    }
    return issues
  }

  private static func uniqueNonempty(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
      let cleaned = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
      guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { return nil }
      return cleaned
    }
  }
}

public enum TradeSide: String, Codable, CaseIterable, Equatable, Sendable {
  case buy
  case sell

  public var localizedTitle: String {
    switch self {
    case .buy: return "买入"
    case .sell: return "卖出"
    }
  }
}

public enum TradeIntentState: String, Codable, CaseIterable, Equatable, Sendable {
  case detected
  case rejected
  case eligible
  case simulated
  case awaitingConfirmation = "awaiting_confirmation"
  case quoted
  case submitting
  case pending
  case confirmed
  case failed
  case unprotectedPosition = "unprotected_position"

  public var localizedTitle: String {
    switch self {
    case .detected: return "已捕捉"
    case .rejected: return "已拦截"
    case .eligible: return "符合规则"
    case .simulated: return "模拟成交"
    case .awaitingConfirmation: return "等待确认"
    case .quoted: return "已报价"
    case .submitting: return "提交中"
    case .pending: return "链上处理中"
    case .confirmed: return "已确认"
    case .failed: return "失败"
    case .unprotectedPosition: return "成交但保护单失败"
    }
  }
}

public struct GMGNTradeQuote: Codable, Equatable, Sendable {
  public static let maximumAge: TimeInterval = 30

  /// Request metadata is optional for backwards-compatible decoding of old local records.
  /// New quotes always populate every field and are rejected for trading when metadata is absent.
  public let chain: GMGNChain?
  public let walletAddress: String?
  public let inputToken: String
  public let outputToken: String
  public let inputAmount: String
  public let outputAmount: String
  public let minimumOutputAmount: String?
  public let slippagePercent: Double?
  public let requestedSlippagePercent: Int?
  public let requestFingerprint: String?
  public let quotedAt: Date

  private enum CodingKeys: String, CodingKey {
    case chain, walletAddress, inputToken, outputToken, inputAmount, outputAmount
    case minimumOutputAmount, slippagePercent, requestedSlippagePercent
    case requestFingerprint, quotedAt
  }

  public init(
    chain: GMGNChain? = nil,
    walletAddress: String? = nil,
    inputToken: String,
    outputToken: String,
    inputAmount: String,
    outputAmount: String,
    minimumOutputAmount: String?,
    slippagePercent: Double?,
    requestedSlippagePercent: Int? = nil,
    requestFingerprint: String? = nil,
    quotedAt: Date = Date()
  ) {
    self.chain = chain
    self.walletAddress = walletAddress
    self.inputToken = inputToken
    self.outputToken = outputToken
    self.inputAmount = inputAmount
    self.outputAmount = outputAmount
    self.minimumOutputAmount = minimumOutputAmount
    self.slippagePercent = slippagePercent
    self.requestedSlippagePercent = requestedSlippagePercent
    self.requestFingerprint = requestFingerprint
    self.quotedAt = quotedAt
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    chain = try values.decodeIfPresent(GMGNChain.self, forKey: .chain)
    walletAddress = try values.decodeIfPresent(String.self, forKey: .walletAddress)
    inputToken = try values.decodeIfPresent(String.self, forKey: .inputToken) ?? ""
    outputToken = try values.decodeIfPresent(String.self, forKey: .outputToken) ?? ""
    inputAmount = try values.decodeIfPresent(String.self, forKey: .inputAmount) ?? ""
    outputAmount = try values.decodeIfPresent(String.self, forKey: .outputAmount) ?? ""
    minimumOutputAmount = try values.decodeIfPresent(String.self, forKey: .minimumOutputAmount)
    slippagePercent = try values.decodeIfPresent(Double.self, forKey: .slippagePercent)
    requestedSlippagePercent = try values.decodeIfPresent(
      Int.self,
      forKey: .requestedSlippagePercent
    )
    requestFingerprint = try values.decodeIfPresent(String.self, forKey: .requestFingerprint)
    quotedAt = try values.decodeIfPresent(Date.self, forKey: .quotedAt)
      ?? Date(timeIntervalSince1970: 0)
  }

  public var isLegacy: Bool {
    chain == nil || walletAddress == nil || requestedSlippagePercent == nil
      || requestFingerprint == nil
  }

  public func matches(
    _ request: GMGNTradeQuoteRequest,
    now: Date = Date(),
    maxAge: TimeInterval = Self.maximumAge
  ) -> Bool {
    guard !isLegacy,
      let chain,
      let walletAddress,
      let requestedSlippagePercent,
      let requestFingerprint,
      now.timeIntervalSince(quotedAt) >= 0,
      now.timeIntervalSince(quotedAt) <= maxAge,
      chain == request.chain,
      normalizedAddress(walletAddress, chain: request.chain) == normalizedAddress(request.walletAddress, chain: request.chain),
      normalizedAddress(inputToken, chain: request.chain) == normalizedAddress(request.inputToken, chain: request.chain),
      normalizedAddress(outputToken, chain: request.chain) == normalizedAddress(request.outputToken, chain: request.chain),
      inputAmount == request.inputAmountSmallestUnit,
      requestedSlippagePercent == request.slippagePercent,
      requestFingerprint == Self.fingerprint(for: request)
    else { return false }
    return true
  }

  public static func fingerprint(for request: GMGNTradeQuoteRequest) -> String {
    let fields = [
      request.chain.rawValue,
      normalizedAddress(request.walletAddress, chain: request.chain),
      normalizedAddress(request.inputToken, chain: request.chain),
      normalizedAddress(request.outputToken, chain: request.chain),
      request.inputAmountSmallestUnit,
      String(request.slippagePercent),
    ]
    return StableHash.hex(fields.joined(separator: "|"))
  }

  private static func normalizedAddress(_ value: String, chain: GMGNChain) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return chain == .sol ? trimmed : trimmed.lowercased()
  }

  private func normalizedAddress(_ value: String, chain: GMGNChain) -> String {
    Self.normalizedAddress(value, chain: chain)
  }
}

public enum GMGNTradeSafetyLevel: String, Equatable, Sendable {
  case low
  case medium
  case high
  case blocked
}

public struct GMGNTradeSafetyAssessment: Equatable, Sendable {
  public let level: GMGNTradeSafetyLevel
  public let title: String
  public let detail: String
  public let rugRatio: Double?

  public var allowsStandardBuy: Bool { level != .blocked }
  public var allowsQuickBuy: Bool { level == .low || level == .medium }
  public var requiresAdditionalConfirmation: Bool { level == .high }

  public init(
    level: GMGNTradeSafetyLevel,
    title: String,
    detail: String,
    rugRatio: Double?
  ) {
    self.level = level
    self.title = title
    self.detail = detail
    self.rugRatio = rugRatio
  }
}

public enum GMGNTradeSafetyEvaluator {
  public static let highRiskThreshold = 0.3
  public static let mediumRiskThreshold = 0.1

  public static func assess(
    security: GMGNTokenSecuritySnapshot?,
    securityError: String? = nil
  ) -> GMGNTradeSafetyAssessment {
    guard let security else {
      return GMGNTradeSafetyAssessment(
        level: .blocked,
        title: "安全检查失败",
        detail: securityError ?? "未取得 GMGN 安全检查结果",
        rugRatio: nil
      )
    }

    guard let honeypot = security.isHoneypot?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased(),
      !honeypot.isEmpty
    else {
      return GMGNTradeSafetyAssessment(
        level: .blocked,
        title: "安全数据不完整",
        detail: "缺少蜜罐检测结果，不能提交真实交易",
        rugRatio: security.rugRatio
      )
    }
    if honeypot == "yes" || honeypot == "true" || honeypot == "1" {
      return GMGNTradeSafetyAssessment(
        level: .blocked,
        title: "检测到蜜罐",
        detail: "已阻止买入",
        rugRatio: security.rugRatio
      )
    }
    guard honeypot == "no" || honeypot == "false" || honeypot == "0" else {
      return GMGNTradeSafetyAssessment(
        level: .blocked,
        title: "安全数据异常",
        detail: "无法识别蜜罐检测结果，不能提交真实交易",
        rugRatio: security.rugRatio
      )
    }

    guard let rugRatio = security.rugRatio, rugRatio.isFinite, rugRatio >= 0 else {
      return GMGNTradeSafetyAssessment(
        level: .blocked,
        title: "安全数据不完整",
        detail: "缺少 Rug 比例，不能提交真实交易",
        rugRatio: nil
      )
    }

    let percentage = (rugRatio * 100).formatted(
      .number.precision(.fractionLength(0...1))
    )
    if rugRatio > highRiskThreshold {
      return GMGNTradeSafetyAssessment(
        level: .high,
        title: "高风险",
        detail: "Rug \(percentage)%；快速模式已禁用",
        rugRatio: rugRatio
      )
    }
    if rugRatio >= mediumRiskThreshold {
      return GMGNTradeSafetyAssessment(
        level: .medium,
        title: "中等风险",
        detail: "Rug \(percentage)%",
        rugRatio: rugRatio
      )
    }
    return GMGNTradeSafetyAssessment(
      level: .low,
      title: "风险较低",
      detail: "Rug \(percentage)%",
      rugRatio: rugRatio
    )
  }

  /// Quick buy deliberately ignores the Rug score but still refuses a known or unknown honeypot.
  public static func assessQuickBuy(
    security: GMGNTokenSecuritySnapshot?,
    securityError: String? = nil
  ) -> GMGNTradeSafetyAssessment {
    guard let security else {
      return GMGNTradeSafetyAssessment(
        level: .blocked,
        title: "蜜罐检查失败",
        detail: securityError ?? "未取得 GMGN 蜜罐检查结果",
        rugRatio: nil
      )
    }
    guard let honeypot = security.isHoneypot?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased(),
      !honeypot.isEmpty
    else {
      return GMGNTradeSafetyAssessment(
        level: .blocked,
        title: "蜜罐数据缺失",
        detail: "快速模式仍需取得蜜罐结果；Rug 评分不参与判断",
        rugRatio: security.rugRatio
      )
    }
    if honeypot == "yes" || honeypot == "true" || honeypot == "1" {
      return GMGNTradeSafetyAssessment(
        level: .blocked,
        title: "检测到蜜罐",
        detail: "已阻止买入；Rug 评分不参与判断",
        rugRatio: security.rugRatio
      )
    }
    guard honeypot == "no" || honeypot == "false" || honeypot == "0" else {
      return GMGNTradeSafetyAssessment(
        level: .blocked,
        title: "蜜罐数据异常",
        detail: "无法识别 GMGN 蜜罐结果；Rug 评分不参与判断",
        rugRatio: security.rugRatio
      )
    }
    return GMGNTradeSafetyAssessment(
      level: .low,
      title: "可快速买入",
      detail: "蜜罐检查通过；已按快速模式跳过 Rug 评分",
      rugRatio: security.rugRatio
    )
  }
}

public struct TradeIntent: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var idempotencyKey: String
  public var ruleID: String
  /// Optional so records written before trade-side support continue to decode as buys.
  public var side: TradeSide?
  public var state: TradeIntentState
  public var chain: GMGNChain?
  public var family: CryptoAddressFamily
  public var tokenAddress: String
  public var tokenSymbol: String?
  public var tokenName: String?
  public var tokenLogoURL: String?
  public var sourceEventIDs: [String]
  public var sourceGroups: [String]
  public var mentionCount: Int
  public var distinctGroupCount: Int
  public var marketSnapshot: CATokenMarketSnapshot?
  public var securitySnapshot: GMGNTokenSecuritySnapshot?
  public var inputToken: String?
  public var outputToken: String?
  public var sellPercent: Int?
  public var parentIntentID: String?
  public var inputAmountNative: Double
  public var inputAmountSmallestUnit: String?
  public var estimatedSpendUSD: Double?
  public var quote: GMGNTradeQuote?
  public var orderID: String?
  public var transactionHash: String?
  public var strategyOrderID: String?
  public var executionReport: GMGNTradeExecutionReport?
  public var rejectionReasons: [String]
  public var failureReason: String?
  public var submittedAt: Date?
  public var confirmedAt: Date?
  public var createdAt: Date
  public var updatedAt: Date

  private enum CodingKeys: String, CodingKey {
    case id, idempotencyKey, ruleID, side, state, chain, family, tokenAddress
    case tokenSymbol, tokenName, tokenLogoURL, sourceEventIDs, sourceGroups
    case mentionCount, distinctGroupCount, marketSnapshot, securitySnapshot
    case inputToken, outputToken, sellPercent, parentIntentID, inputAmountNative
    case inputAmountSmallestUnit, estimatedSpendUSD, quote, orderID, transactionHash
    case strategyOrderID, executionReport, rejectionReasons, failureReason
    case submittedAt, confirmedAt, createdAt, updatedAt
  }

  public init(
    id: String = UUID().uuidString,
    idempotencyKey: String,
    ruleID: String,
    side: TradeSide = .buy,
    state: TradeIntentState = .detected,
    chain: GMGNChain?,
    family: CryptoAddressFamily,
    tokenAddress: String,
    tokenSymbol: String? = nil,
    tokenName: String? = nil,
    tokenLogoURL: String? = nil,
    sourceEventIDs: [String],
    sourceGroups: [String],
    mentionCount: Int,
    distinctGroupCount: Int,
    marketSnapshot: CATokenMarketSnapshot? = nil,
    securitySnapshot: GMGNTokenSecuritySnapshot? = nil,
    inputToken: String? = nil,
    outputToken: String? = nil,
    sellPercent: Int? = nil,
    parentIntentID: String? = nil,
    inputAmountNative: Double,
    inputAmountSmallestUnit: String? = nil,
    estimatedSpendUSD: Double? = nil,
    quote: GMGNTradeQuote? = nil,
    orderID: String? = nil,
    transactionHash: String? = nil,
    strategyOrderID: String? = nil,
    executionReport: GMGNTradeExecutionReport? = nil,
    rejectionReasons: [String] = [],
    failureReason: String? = nil,
    submittedAt: Date? = nil,
    confirmedAt: Date? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.idempotencyKey = idempotencyKey
    self.ruleID = ruleID
    self.side = side
    self.state = state
    self.chain = chain
    self.family = family
    self.tokenAddress = tokenAddress
    self.tokenSymbol = tokenSymbol
    self.tokenName = tokenName
    self.tokenLogoURL = tokenLogoURL
    self.sourceEventIDs = sourceEventIDs
    self.sourceGroups = sourceGroups
    self.mentionCount = mentionCount
    self.distinctGroupCount = distinctGroupCount
    self.marketSnapshot = marketSnapshot
    self.securitySnapshot = securitySnapshot
    self.inputToken = inputToken
    self.outputToken = outputToken
    self.sellPercent = sellPercent
    self.parentIntentID = parentIntentID
    self.inputAmountNative = inputAmountNative
    self.inputAmountSmallestUnit = inputAmountSmallestUnit
    self.estimatedSpendUSD = estimatedSpendUSD
    self.quote = quote
    self.orderID = orderID
    self.transactionHash = transactionHash
    self.strategyOrderID = strategyOrderID
    self.executionReport = executionReport
    self.rejectionReasons = rejectionReasons
    self.failureReason = failureReason
    self.submittedAt = submittedAt
    self.confirmedAt = confirmedAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var resolvedSide: TradeSide { side ?? .buy }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    idempotencyKey = try values.decode(String.self, forKey: .idempotencyKey)
    ruleID = try values.decode(String.self, forKey: .ruleID)
    side = try values.decodeIfPresent(TradeSide.self, forKey: .side)
    state = try values.decodeIfPresent(TradeIntentState.self, forKey: .state) ?? .detected
    chain = try values.decodeIfPresent(GMGNChain.self, forKey: .chain)
    family = try values.decode(CryptoAddressFamily.self, forKey: .family)
    tokenAddress = try values.decode(String.self, forKey: .tokenAddress)
    tokenSymbol = try values.decodeIfPresent(String.self, forKey: .tokenSymbol)
    tokenName = try values.decodeIfPresent(String.self, forKey: .tokenName)
    tokenLogoURL = try values.decodeIfPresent(String.self, forKey: .tokenLogoURL)
    sourceEventIDs = try values.decodeIfPresent([String].self, forKey: .sourceEventIDs) ?? []
    sourceGroups = try values.decodeIfPresent([String].self, forKey: .sourceGroups) ?? []
    mentionCount = try values.decodeIfPresent(Int.self, forKey: .mentionCount) ?? 1
    distinctGroupCount = try values.decodeIfPresent(Int.self, forKey: .distinctGroupCount) ?? 1
    marketSnapshot = try values.decodeIfPresent(CATokenMarketSnapshot.self, forKey: .marketSnapshot)
    securitySnapshot = try values.decodeIfPresent(
      GMGNTokenSecuritySnapshot.self,
      forKey: .securitySnapshot
    )
    inputToken = try values.decodeIfPresent(String.self, forKey: .inputToken)
    outputToken = try values.decodeIfPresent(String.self, forKey: .outputToken)
    sellPercent = try values.decodeIfPresent(Int.self, forKey: .sellPercent)
    parentIntentID = try values.decodeIfPresent(String.self, forKey: .parentIntentID)
    inputAmountNative = try values.decodeIfPresent(Double.self, forKey: .inputAmountNative)
      ?? 0.000_001
    inputAmountSmallestUnit = try values.decodeIfPresent(
      String.self,
      forKey: .inputAmountSmallestUnit
    )
    estimatedSpendUSD = try values.decodeIfPresent(Double.self, forKey: .estimatedSpendUSD)
    quote = try values.decodeIfPresent(GMGNTradeQuote.self, forKey: .quote)
    orderID = try values.decodeIfPresent(String.self, forKey: .orderID)
    transactionHash = try values.decodeIfPresent(String.self, forKey: .transactionHash)
    strategyOrderID = try values.decodeIfPresent(String.self, forKey: .strategyOrderID)
    executionReport = try values.decodeIfPresent(
      GMGNTradeExecutionReport.self,
      forKey: .executionReport
    )
    rejectionReasons = try values.decodeIfPresent([String].self, forKey: .rejectionReasons) ?? []
    failureReason = try values.decodeIfPresent(String.self, forKey: .failureReason)
    submittedAt = try values.decodeIfPresent(Date.self, forKey: .submittedAt)
    confirmedAt = try values.decodeIfPresent(Date.self, forKey: .confirmedAt)
    createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt)
      ?? Date(timeIntervalSince1970: 0)
    updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
  }

  public static func idempotencyKey(
    ruleID: String,
    family: CryptoAddressFamily,
    chain: GMGNChain? = nil,
    address: String,
    windowStart: Date
  ) -> String {
    let bucket = Int64(windowStart.timeIntervalSince1970.rounded(.down))
    return "trade:\(StableHash.hex("\(ruleID)|\(family.rawValue)|\(chain?.rawValue ?? "unknown")|\(address.lowercased())|\(bucket)"))"
  }
}

public struct TradeAutomationMetrics: Codable, Equatable, Sendable {
  public let dailyIntentCount: Int
  public let dailyEstimatedSpendUSD: Double
  public let openPositionCount: Int
  public let consecutiveFailureCount: Int

  public init(
    dailyIntentCount: Int = 0,
    dailyEstimatedSpendUSD: Double = 0,
    openPositionCount: Int = 0,
    consecutiveFailureCount: Int = 0
  ) {
    self.dailyIntentCount = dailyIntentCount
    self.dailyEstimatedSpendUSD = dailyEstimatedSpendUSD
    self.openPositionCount = openPositionCount
    self.consecutiveFailureCount = consecutiveFailureCount
  }
}

public struct TradeRiskContext: Equatable, Sendable {
  public var configuration: TradeAutomationConfiguration
  public var rule: TradeAutomationRule
  public var family: CryptoAddressFamily
  public var chain: GMGNChain?
  public var triggeringGroup: String?
  public var triggeringSender: String?
  public var mentionCount: Int
  public var distinctGroupCount: Int
  public var groupNames: [String]
  public var market: CATokenMarketSnapshot?
  public var security: GMGNTokenSecuritySnapshot?
  public var holderCount: Int?
  public var dailyIntentCount: Int
  public var ruleDailyIntentCount: Int
  public var openPositionCount: Int
  public var consecutiveFailureCount: Int
  public var currentDailySpendUSD: Double
  public var estimatedSpendUSD: Double?
  public var lastIntentForTokenAt: Date?
  public var now: Date

  public init(
    configuration: TradeAutomationConfiguration,
    rule: TradeAutomationRule,
    family: CryptoAddressFamily,
    chain: GMGNChain?,
    triggeringGroup: String? = nil,
    triggeringSender: String? = nil,
    mentionCount: Int,
    distinctGroupCount: Int,
    groupNames: [String],
    market: CATokenMarketSnapshot?,
    security: GMGNTokenSecuritySnapshot?,
    holderCount: Int? = nil,
    dailyIntentCount: Int = 0,
    ruleDailyIntentCount: Int = 0,
    openPositionCount: Int = 0,
    consecutiveFailureCount: Int = 0,
    currentDailySpendUSD: Double = 0,
    estimatedSpendUSD: Double? = nil,
    lastIntentForTokenAt: Date? = nil,
    now: Date = Date()
  ) {
    self.configuration = configuration
    self.rule = rule
    self.family = family
    self.chain = chain
    self.triggeringGroup = triggeringGroup
    self.triggeringSender = triggeringSender
    self.mentionCount = mentionCount
    self.distinctGroupCount = distinctGroupCount
    self.groupNames = groupNames
    self.market = market
    self.security = security
    self.holderCount = holderCount
    self.dailyIntentCount = dailyIntentCount
    self.ruleDailyIntentCount = ruleDailyIntentCount
    self.openPositionCount = openPositionCount
    self.consecutiveFailureCount = consecutiveFailureCount
    self.currentDailySpendUSD = currentDailySpendUSD
    self.estimatedSpendUSD = estimatedSpendUSD
    self.lastIntentForTokenAt = lastIntentForTokenAt
    self.now = now
  }
}

public struct TradeRiskDecision: Equatable, Sendable {
  public let isEligible: Bool
  public let reasons: [String]

  public init(isEligible: Bool, reasons: [String]) {
    self.isEligible = isEligible
    self.reasons = reasons
  }
}

public enum TradeRiskEngine {
  public static func evaluate(_ context: TradeRiskContext) -> TradeRiskDecision {
    let configuration = context.configuration.normalized
    let rule = context.rule.normalized
    var reasons = rule.validationIssues

    if configuration.mode == .off { reasons.append("交易自动化已关闭") }
    if configuration.emergencyStopped { reasons.append("全局紧急停止已启用") }
    if !rule.isEnabled { reasons.append("规则未启用") }
    guard let chain = context.chain else {
      return TradeRiskDecision(isEligible: false, reasons: reasons + ["网络无法唯一识别"])
    }
    if !rule.allowedChains.contains(chain) { reasons.append("网络不在规则允许范围") }
    if chain.addressFamily != context.family { reasons.append("地址格式与网络不匹配") }

    if context.mentionCount < rule.minimumMentions { reasons.append("提及次数不足") }
    if context.distinctGroupCount < rule.minimumDistinctGroups { reasons.append("独立群数量不足") }
    if !rule.groups.isEmpty && Set(rule.groups).isDisjoint(with: context.groupNames) {
      reasons.append("来源群不在允许范围")
    }
    if !rule.senders.isEmpty {
      guard let sender = context.triggeringSender, rule.senders.contains(sender) else {
        reasons.append("触发者不在允许范围")
        return TradeRiskDecision(isEligible: false, reasons: reasons)
      }
    }

    if let marketCap = context.market?.marketCapUSD {
      if marketCap < rule.minimumMarketCapUSD { reasons.append("市值低于下限") }
      if marketCap > rule.maximumMarketCapUSD { reasons.append("市值高于上限") }
    } else {
      reasons.append("缺少市值数据")
    }
    if let liquidity = context.market?.liquidityUSD {
      if liquidity < rule.minimumLiquidityUSD { reasons.append("流动性低于下限") }
    } else {
      reasons.append("缺少流动性数据")
    }

    if context.holderCount == nil && rule.minimumHolderCount > 0 {
      reasons.append("缺少持有人数量数据")
    } else if let holderCount = context.holderCount,
      holderCount < rule.minimumHolderCount
    {
      reasons.append("持有人数量低于下限")
    }

    if rule.requireSecurityData {
      guard let security = context.security else {
        reasons.append("缺少安全检查数据")
        return TradeRiskDecision(isEligible: false, reasons: reasons)
      }
      let missingSecurityFields = [
        security.openSource == nil ? "开源状态" : nil,
        security.ownerRenounced == nil ? "权限放弃状态" : nil,
        security.isHoneypot == nil ? "蜜罐检查" : nil,
        security.mintRenounced == nil ? "增发权限" : nil,
        security.freezeRenounced == nil ? "冻结权限" : nil,
        security.rugRatio == nil ? "Rug 比例" : nil,
      ].compactMap { $0 }
      if !missingSecurityFields.isEmpty {
        reasons.append("安全检查数据不完整：" + missingSecurityFields.joined(separator: "、"))
      }
    }
    if let isHoneypot = context.security?.isHoneypot?.lowercased(),
      isHoneypot == "yes" || isHoneypot == "true"
    { reasons.append("检测为蜜罐") }
    if let rugRatio = context.security?.rugRatio {
      if rugRatio > rule.maximumRugRatio { reasons.append("Rug 比例超过规则上限") }
    }

    if context.dailyIntentCount >= configuration.maximumDailyIntents {
      reasons.append("已达到全局每日次数上限")
    }
    if context.ruleDailyIntentCount >= rule.maximumTradesPerDay {
      reasons.append("已达到规则每日次数上限")
    }
    if context.openPositionCount >= configuration.maximumOpenPositions {
      reasons.append("已达到最大持仓数量")
    }
    if context.consecutiveFailureCount >= configuration.maximumConsecutiveFailures {
      reasons.append("连续失败次数已触发熔断")
    }
    if configuration.maximumDailySpendUSD > 0 {
      if let estimate = context.estimatedSpendUSD {
        if context.currentDailySpendUSD + estimate > configuration.maximumDailySpendUSD {
          reasons.append("预计支出超过每日金额上限")
        }
      } else {
        reasons.append("无法估算美元成本，不能校验每日金额上限")
      }
    }
    if let lastIntentForTokenAt = context.lastIntentForTokenAt,
      context.now.timeIntervalSince(lastIntentForTokenAt) < rule.tokenCooldownSeconds
    {
      reasons.append("同一代币仍在冷却期")
    }

    return TradeRiskDecision(isEligible: reasons.isEmpty, reasons: reasons)
  }
}

public struct TradeAutomationSimulationResult: Equatable, Identifiable, Sendable {
  public let id: String
  public let ruleID: String
  public let ruleName: String
  public let chain: GMGNChain?
  public let isEligible: Bool
  public let reasons: [String]
  public let sampleMarketCapUSD: Double?
  public let sampleLiquidityUSD: Double?
  public let sampleEstimatedSpendUSD: Double
  public let protectionOrders: [TradeProtectionOrder]
  public let evaluatedAt: Date

  public init(
    id: String = UUID().uuidString,
    ruleID: String,
    ruleName: String,
    chain: GMGNChain?,
    isEligible: Bool,
    reasons: [String],
    sampleMarketCapUSD: Double?,
    sampleLiquidityUSD: Double?,
    sampleEstimatedSpendUSD: Double = 25,
    protectionOrders: [TradeProtectionOrder],
    evaluatedAt: Date = Date()
  ) {
    self.id = id
    self.ruleID = ruleID
    self.ruleName = ruleName
    self.chain = chain
    self.isEligible = isEligible
    self.reasons = reasons
    self.sampleMarketCapUSD = sampleMarketCapUSD
    self.sampleLiquidityUSD = sampleLiquidityUSD
    self.sampleEstimatedSpendUSD = sampleEstimatedSpendUSD
    self.protectionOrders = protectionOrders
    self.evaluatedAt = evaluatedAt
  }
}

public enum TradeAutomationSimulator {
  private static let sampleEstimatedSpendUSD = 25.0

  /// Runs the same eligibility checks as live signal handling against a deterministic fixture.
  /// It never calls GMGN, persists a trade intent, or submits an order.
  public static func run(
    configuration: TradeAutomationConfiguration,
    rule: TradeAutomationRule,
    now: Date = Date()
  ) -> TradeAutomationSimulationResult {
    let normalizedRule = rule.normalized
    let chain = normalizedRule.allowedChains.first
    let family = chain?.addressFamily ?? .evm
    let sampleAddress = chain == .sol
      ? "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
      : "0x1111111111111111111111111111111111111111"
    let marketCap: Double? = normalizedRule.minimumMarketCapUSD <= normalizedRule.maximumMarketCapUSD
      ? max(normalizedRule.minimumMarketCapUSD, min(normalizedRule.maximumMarketCapUSD, 1_000_000))
      : normalizedRule.minimumMarketCapUSD
    let liquidity: Double? = max(normalizedRule.minimumLiquidityUSD, 250_000)
    let market = chain.map {
      CATokenMarketSnapshot(
        chain: $0,
        address: sampleAddress,
        symbol: "SIM",
        name: "wxFomo Simulation",
        priceUSD: 1,
        marketCapUSD: marketCap,
        liquidityUSD: liquidity,
        logoURL: nil,
        capturedAt: now
      )
    }
    let security = GMGNTokenSecuritySnapshot(
      openSource: "yes",
      ownerRenounced: "yes",
      isHoneypot: "no",
      mintRenounced: true,
      freezeRenounced: true,
      rugRatio: min(normalizedRule.maximumRugRatio, 0.01),
      top10HolderRate: 0.2,
      devTeamHoldRate: 0,
      suspectedInsiderHoldRate: 0,
      washTrading: false,
      buyTax: 0,
      sellTax: 0
    )
    let decision = TradeRiskEngine.evaluate(
      TradeRiskContext(
        configuration: configuration,
        rule: normalizedRule,
        family: family,
        chain: chain,
        triggeringGroup: "模拟群",
        triggeringSender: "模拟成员",
        mentionCount: normalizedRule.minimumMentions,
        distinctGroupCount: normalizedRule.minimumDistinctGroups,
        groupNames: (0..<normalizedRule.minimumDistinctGroups).map { "模拟群 \($0 + 1)" },
        market: market,
        security: security,
        estimatedSpendUSD: sampleEstimatedSpendUSD,
        now: now
      )
    )
    return TradeAutomationSimulationResult(
      id: normalizedRule.id,
      ruleID: normalizedRule.id,
      ruleName: normalizedRule.name,
      chain: chain,
      isEligible: decision.isEligible,
      reasons: decision.reasons,
      sampleMarketCapUSD: marketCap,
      sampleLiquidityUSD: liquidity,
      sampleEstimatedSpendUSD: sampleEstimatedSpendUSD,
      protectionOrders: normalizedRule.protectionOrders,
      evaluatedAt: now
    )
  }
}

public enum GMGNNativeAsset {
  public static func address(for chain: GMGNChain) -> String? {
    switch chain {
    case .sol: return "So11111111111111111111111111111111111111112"
    case .bsc, .base, .eth, .robinhood:
      return "0x0000000000000000000000000000000000000000"
    }
  }

  public static func symbol(for chain: GMGNChain) -> String {
    switch chain {
    case .sol: return "SOL"
    case .bsc: return "BNB"
    case .base, .eth, .robinhood: return "ETH"
    }
  }

  public static func supportsAntiMEV(on chain: GMGNChain) -> Bool {
    [.sol, .bsc, .eth].contains(chain)
  }

  public static func smallestUnitAmount(_ amount: Double, chain: GMGNChain) -> String? {
    guard amount.isFinite, amount > 0 else { return nil }
    let decimals: Int16 = chain == .sol ? 9 : 18
    let source = Decimal(amount)
    var multiplier = Decimal(1)
    for _ in 0..<decimals { multiplier *= 10 }
    var raw = source * multiplier
    var rounded = Decimal()
    NSDecimalRound(&rounded, &raw, 0, .down)
    guard rounded > 0 else { return nil }
    return NSDecimalNumber(decimal: rounded).stringValue
  }
}
