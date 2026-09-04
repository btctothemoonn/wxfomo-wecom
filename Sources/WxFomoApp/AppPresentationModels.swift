import Foundation
import WxFomoCore

enum ManualBuyMode: String, CaseIterable, Identifiable {
  case standard
  case quick

  var id: String { rawValue }

  var title: String {
    switch self {
    case .standard: return "普通"
    case .quick: return "快速"
    }
  }
}

enum ManualBuyAuthorization: Equatable {
  case standardConfirmation
  case quickBuyButton
}

enum ManualSellAuthorization: Equatable {
  case standardConfirmation
  case quickSellButton
}

struct ManualBuyPreparation: Equatable {
  let report: GMGNTokenReport
  let quote: GMGNTradeQuote
  let safety: GMGNTradeSafetyAssessment
}

struct ManualBuyInspection: Equatable {
  let report: GMGNTokenReport
  let safety: GMGNTradeSafetyAssessment
}

struct ManualSellPreparation: Equatable {
  let balance: GMGNTokenBalanceSnapshot
  let tokenDecimals: Int
  let inputAmountSmallestUnit: String
  let quote: GMGNTradeQuote
}

struct ManualSellContext: Identifiable, Equatable {
  let id: UUID
  let sourceIntentID: String
  let chain: GMGNChain
  let tokenAddress: String
  let tokenSymbol: String?
  let tokenName: String?
  let tokenLogoURL: String?
  let walletAddress: String?
  let suggestedSlippagePercent: Int
  let mode: ManualBuyMode

  init(
    sourceIntentID: String,
    chain: GMGNChain,
    tokenAddress: String,
    tokenSymbol: String?,
    tokenName: String?,
    tokenLogoURL: String?,
    walletAddress: String? = nil,
    suggestedSlippagePercent: Int = 12,
    mode: ManualBuyMode = .quick
  ) {
    self.id = UUID()
    self.sourceIntentID = sourceIntentID
    self.chain = chain
    self.tokenAddress = tokenAddress
    self.tokenSymbol = tokenSymbol
    self.tokenName = tokenName
    self.tokenLogoURL = tokenLogoURL
    self.walletAddress = walletAddress
    self.suggestedSlippagePercent = suggestedSlippagePercent
    self.mode = mode
  }
}

struct ManualBuyContext: Identifiable, Equatable {
  let id: UUID
  /// Existing automation intent to update instead of creating a detached audit row.
  let intentID: String?
  let address: String
  let suggestedChain: GMGNChain?
  let suggestedAmountNative: Double?
  let suggestedSlippagePercent: Int?
  let symbol: String?
  let name: String?
  let tokenDecimals: Int?
  let logoURL: String?
  let marketCapUSD: Double?
  let liquidityUSD: Double?
  let sourceTitle: String?
  let mentionSummary: String?
  let sourceEventIDs: [String]
  let sourceGroups: [String]
  let mode: ManualBuyMode
  let chainCandidates: [DexScreenerChainCandidate]
  let chainDetectionMessage: String?

  init(
    address: String,
    suggestedChain: GMGNChain?,
    intentID: String? = nil,
    suggestedAmountNative: Double? = nil,
    suggestedSlippagePercent: Int? = nil,
    symbol: String? = nil,
    name: String? = nil,
    tokenDecimals: Int? = nil,
    logoURL: String? = nil,
    marketCapUSD: Double? = nil,
    liquidityUSD: Double? = nil,
    sourceTitle: String? = nil,
    mentionSummary: String? = nil,
    sourceEventIDs: [String] = [],
    sourceGroups: [String] = [],
    mode: ManualBuyMode = .quick,
    chainCandidates: [DexScreenerChainCandidate] = [],
    chainDetectionMessage: String? = nil
  ) {
    self.id = UUID()
    self.intentID = intentID
    self.address = address
    self.suggestedChain = suggestedChain
    self.suggestedAmountNative = suggestedAmountNative
    self.suggestedSlippagePercent = suggestedSlippagePercent
    self.symbol = symbol
    self.name = name
    self.tokenDecimals = tokenDecimals
    self.logoURL = logoURL
    self.marketCapUSD = marketCapUSD
    self.liquidityUSD = liquidityUSD
    self.sourceTitle = sourceTitle
    self.mentionSummary = mentionSummary
    self.sourceEventIDs = sourceEventIDs
    self.sourceGroups = sourceGroups
    self.mode = mode
    self.chainCandidates = chainCandidates
    self.chainDetectionMessage = chainDetectionMessage
  }
}

enum WorkspaceSelection: Hashable {
  case inbox
  case captured
  case group(String)
  case analyses
  case alerts
  case meme
  case market
  case rules
  case trading
  case automations
  case sounds
  case providers
  case diagnostics

  var isMessageFeed: Bool {
    switch self {
    case .inbox, .captured, .group:
      return true
    case .analyses, .alerts, .meme, .market, .rules, .trading, .automations, .sounds, .providers,
      .diagnostics:
      return false
    }
  }
}

enum MessageTimePreset: String, CaseIterable, Identifiable {
  case sinceLastReview = "since_last_review"
  case last30Minutes = "last_30_minutes"
  case last2Hours = "last_2_hours"
  case today
  case all
  case custom

  var id: String { rawValue }

  var title: String {
    switch self {
    case .sinceLastReview: return "自上次查看后"
    case .last30Minutes: return "最近 30 分钟"
    case .last2Hours: return "最近 2 小时"
    case .today: return "今天"
    case .all: return "全部时间"
    case .custom: return "自定义区间"
    }
  }

  func fixedRange(
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> MessageDateRange? {
    switch self {
    case .last30Minutes:
      return MessageDateRange(start: now.addingTimeInterval(-30 * 60), end: now)
    case .last2Hours:
      return MessageDateRange(start: now.addingTimeInterval(-2 * 60 * 60), end: now)
    case .today:
      return MessageDateRange(start: calendar.startOfDay(for: now), end: now)
    case .all, .sinceLastReview, .custom:
      return nil
    }
  }
}

struct MessageContextFocus: Equatable, Identifiable {
  let eventID: String
  let group: String
  let observedAt: Date
  let beforeMessageLimit: Int
  let afterMessageLimit: Int
  let returnSelection: WorkspaceSelection
  let returnTimePreset: MessageTimePreset
  let returnCustomStart: Date
  let returnCustomEnd: Date

  var id: String { eventID }
}

struct MessageDateRange: Equatable, Sendable {
  var start: Date
  var end: Date

  var normalized: MessageDateRange {
    start <= end ? self : MessageDateRange(start: end, end: start)
  }
}

enum MessageKindFilter: String, CaseIterable, Identifiable {
  case all
  case text
  case media
  case system

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: return "全部"
    case .text: return "文字"
    case .media: return "媒体"
    case .system: return "系统"
    }
  }

  var messageTypes: Set<MessageKind> {
    switch self {
    case .all: return []
    case .text: return [.text]
    case .media: return [.media]
    case .system: return [.system]
    }
  }
}

extension AIAnalysisMode {
  var localizedTitle: String {
    switch self {
    case .digest: return "快速摘要"
    case .importantInformation: return "重要信息"
    case .actionItems: return "待办与时间点"
    case .risksAndOpportunities: return "风险与机会"
    case .custom: return "自定义分析"
    }
  }

  var systemImage: String {
    switch self {
    case .digest: return "text.alignleft"
    case .importantInformation: return "scope"
    case .actionItems: return "checklist"
    case .risksAndOpportunities: return "exclamationmark.magnifyingglass"
    case .custom: return "slider.horizontal.3"
    }
  }
}

extension AIProviderKind {
  var localizedTitle: String {
    switch self {
    case .openAIResponses: return "OpenAI Responses"
    case .openAIChatCompletions: return "OpenAI Chat Completions"
    case .openAICompatibleChatCompletions: return "OpenAI 兼容接口"
    case .anthropicMessages: return "Anthropic Messages"
    }
  }
}

struct ProviderDraft: Equatable {
  var configurationID: String?
  var displayName = ""
  var kind: AIProviderKind = .openAIResponses
  var baseURL = AIProviderKind.openAIResponses.defaultBaseURL?.absoluteString ?? ""
  var model = ""
  var apiKey = ""
  var makeDefault = true

  init(configuration: AIProviderConfiguration? = nil) {
    guard let configuration else { return }
    configurationID = configuration.configurationID
    displayName = configuration.displayName
    kind = configuration.kind
    baseURL = configuration.baseURL.absoluteString
    model = configuration.model
    makeDefault = false
  }

  mutating func applyKindDefaults() {
    if let defaultURL = kind.defaultBaseURL {
      baseURL = defaultURL.absoluteString
    } else if !AIProviderKind.allCases.compactMap(\.defaultBaseURL)
      .map(\.absoluteString).contains(baseURL)
    {
      return
    } else {
      baseURL = ""
    }
  }

  mutating func apply(_ preset: ProviderPreset) {
    switch preset {
    case .manual:
      break
    case .supertokenGPT56:
      displayName = "Supertoken GPT 5.6"
      kind = .openAICompatibleChatCompletions
      baseURL = "https://api.supertoken.cc/v1"
      model = "gpt-5.6-sol"
    }
  }
}

enum ProviderPreset: String, CaseIterable, Identifiable {
  case supertokenGPT56 = "supertoken_gpt_5_6"
  case manual

  var id: String { rawValue }

  var title: String {
    switch self {
    case .supertokenGPT56: return "Supertoken · GPT 5.6"
    case .manual: return "手动配置"
    }
  }
}

struct MessageRuleDraft: Equatable {
  var name = ""
  var priority = 0
  var isEnabled = true
  var groups = ""
  var senders = ""
  var includeKeywords = ""
  var excludeKeywords = ""
  var regularExpressions = ""
  var capture = true
  var suppress = false
  var tagName = ""
  var alertSeverity: MessageRuleAlertSeverity?
}

extension MessageRuleAlertSeverity {
  var localizedTitle: String {
    switch self {
    case .information: return "提示"
    case .warning: return "警告"
    case .critical: return "严重"
    }
  }
}
